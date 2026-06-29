#!/usr/bin/perl

# Plugin unit tests — tests that don't require PVE framework
# Tests parse_volname, vmid_from_volname, _next_volname, volume_has_feature logic

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(ceil);

use lib 'src';

# We can't load the full plugin without PVE libs, so test the helper functions
# by extracting their logic. For integration, test on a PVE node.

# ── Volume Name Parsing ──

subtest 'parse_volname_valid' => sub {
    # Simulate parse_volname logic
    my $volname = 'vm-100-disk-1';
    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        is($1, 100, 'vmid extracted');
        is($2, 1, 'disk seq extracted');
    } else {
        fail('pattern should match');
    }
};

subtest 'parse_volname_invalid' => sub {
    my $volname = 'invalid-name';
    ok($volname !~ /^vm-(\d+)-disk-(\d+)$/, 'invalid name does not match');
};

subtest 'parse_volname_base' => sub {
    # Base (template) volume parsing — added with create_base support.
    my $parse = sub {
        my ($v) = @_;
        return ('images', $v, $1, undef, undef, 1, 'raw')
            if $v =~ /^base-(\d+)-disk-(\d+)$/;
        return ('images', $v, $1, undef, undef, undef, 'raw')
            if $v =~ /^vm-(\d+)-disk-(\d+)$/;
        return;
    };

    my @base = $parse->('base-100-disk-1');
    is($base[2], 100, 'base vmid extracted');
    is($base[5], 1, 'base isBase flag set');

    my @vm = $parse->('vm-100-disk-1');
    is($vm[2], 100, 'vm vmid extracted');
    is($vm[5], undef, 'vm isBase flag unset');

    # vmid_from_volname accepts both prefixes.
    my $vmid_from = sub { ($_[0] =~ /^(?:vm|base)-(\d+)-/) ? $1 : 0 };
    is($vmid_from->('base-200-disk-3'), 200, 'vmid from base name');
    is($vmid_from->('vm-300-disk-1'), 300, 'vmid from vm name');
};

subtest 'parse_volname_cloudinit' => sub {
    # Faithful mirror of parse_volname, including the cloud-init branch (GitHub #6).
    # PVE allocates a tiny raw LUN named vm-<vmid>-cloudinit; alloc_image must be able
    # to create it AND parse/free must accept it, or the array LDEV leaks.
    my $parse = sub {
        my ($v) = @_;
        return ('images', $v, $1, undef, undef, 1, 'raw')
            if $v =~ /^base-(\d+)-disk-(\d+)$/;
        return ('images', $v, $1, undef, undef, undef, 'raw')
            if $v =~ /^vm-(\d+)-disk-(\d+)$/;
        return ('images', $v, $1, undef, undef, undef, 'raw')
            if $v =~ /^vm-(\d+)-cloudinit$/;
        die "unable to parse volume name '$v'\n";
    };

    my @ci = $parse->('vm-9100-cloudinit');
    is($ci[0], 'images', 'cloudinit vtype is images');
    is($ci[1], 'vm-9100-cloudinit', 'cloudinit name preserved');
    is($ci[2], 9100, 'cloudinit vmid extracted');
    is($ci[5], undef, 'cloudinit isBase flag unset');
    is($ci[6], 'raw', 'cloudinit format is raw');

    # vmid_from_volname / list_images evmid regex must also key off the cloudinit name.
    my $vmid_from = sub { ($_[0] =~ /^(?:vm|base)-(\d+)-/) ? $1 : 0 };
    is($vmid_from->('vm-9100-cloudinit'), 9100, 'vmid from cloudinit name');

    # Names that must still be rejected (no silent accept-anything).
    eval { $parse->('vm-100-cloudinit-extra') };
    ok($@, 'trailing junk after cloudinit rejected');
    eval { $parse->('vm-cloudinit') };
    ok($@, 'cloudinit without vmid rejected');
};

subtest 'ldev_size_mb_logic' => sub {
    # Mirrors _ldev_size_mb: prefer exact block count over formatted string.
    my $size = sub {
        my ($ldev) = @_;
        for my $f (qw(blockCapacity numOfBlocks)) {
            return int($ldev->{$f} * 512 / (1024 * 1024))
                if defined $ldev->{$f} && $ldev->{$f} =~ /^\d+$/;
        }
        my $cap = $ldev->{byteFormatCapacity};
        if (defined $cap) {
            return int($1 * 1024 * 1024) if $cap =~ /^([\d.]+)\s*T/i;
            return int($1 * 1024)        if $cap =~ /^([\d.]+)\s*G/i;
            return int($1)               if $cap =~ /^([\d.]+)\s*M/i;
        }
        return 0;
    };

    is($size->({ blockCapacity => 2097152 }), 1024, '2097152 blocks = 1024 MB');
    is($size->({ byteFormatCapacity => '1.00 G' }), 1024, '1G string = 1024 MB');
    is($size->({ byteFormatCapacity => '2.00 T' }), 2097152, '2T string = 2097152 MB');
    is($size->({ byteFormatCapacity => '512.00 M' }), 512, '512M string = 512 MB');
    # Block count takes precedence over the formatted string when both present.
    is($size->({ blockCapacity => 2097152, byteFormatCapacity => '999.00 G' }), 1024,
       'block count wins over byteFormatCapacity');
};

subtest 'ldev_range_cu_alignment' => sub {
    # Mirrors _ldev_range_cu_info: an LDEV id is CU:LDEV, 256 ids per CU. A range
    # is CU-aligned when it starts on a CU boundary and ends one id below one.
    my $LDEVS_PER_CU = 256;
    my $cu_info = sub {
        my ($min, $max) = @_;
        my $aligned = (($min % $LDEVS_PER_CU) == 0)
            && ((($max + 1) % $LDEVS_PER_CU) == 0);
        return ($aligned, int($min / $LDEVS_PER_CU), int($max / $LDEVS_PER_CU));
    };
    is_deeply([$cu_info->(0, 255)],    [1, 0, 0], '0-255 = whole CU 0 (aligned)');
    is_deeply([$cu_info->(256, 511)],  [1, 1, 1], '256-511 = whole CU 1 (aligned)');
    is_deeply([$cu_info->(256, 2303)], [1, 1, 8], '256-2303 = CU 1-8 (aligned)');
    is((($cu_info->(300, 500))[0]), '', '300-500 is not CU-aligned');
    is((($cu_info->(256, 510))[0]), '', '256-510 (ends mid-CU) is not aligned');
    is((($cu_info->(1, 511))[0]),   '', '1-511 (starts mid-CU) is not aligned');
};

subtest 'alloc_size_mb_floor' => sub {
    # Mirrors _alloc_size_mb: KiB -> MiB (round up), floored to the array minimum.
    # The E590H rejects DP-VOLs <= 46 MiB ("capacity is invalid."); keep this in
    # sync with $MIN_LDEV_MB in the plugin.
    my $MIN_LDEV_MB = 48;
    my $alloc_mb = sub {
        my ($kib) = @_;
        my $mb = POSIX::ceil(($kib || 0) / 1024);
        $mb = $MIN_LDEV_MB if $mb < $MIN_LDEV_MB;
        return $mb;
    };
    is($alloc_mb->(4096), 48,   'PVE vTPM (4 MiB) floored to the array minimum');
    is($alloc_mb->(528),  48,   'sub-MiB EFI vars floored to the array minimum');
    is($alloc_mb->(0),    48,   'zero/undef floored to the array minimum');
    is($alloc_mb->(48 * 1024), 48,      '48 MiB stays 48 (at the floor)');
    is($alloc_mb->(49 * 1024), 49,      '49 MiB passes through exactly (no rounding up)');
    is($alloc_mb->(8 * 1024 * 1024), 8192, '8 GiB passes through exactly');
    is($alloc_mb->(100 * 1024 + 512), 101, 'non-MiB-aligned size above floor rounds up to whole MiB');
};

subtest 'plugindata_content_types' => sub {
    # The plugin must advertise both images (VM disks) and rootdir (LXC rootfs),
    # with images as the default, so containers can live on the storage.
    my $src = do {
        local $/;
        open my $fh, '<', 'src/PVE/Storage/Custom/HitachiBlockPlugin.pm'
            or die "cannot open plugin source: $!";
        <$fh>;
    };
    my ($pd) = $src =~ /sub\s+plugindata\s*\{(.*?)\n\}/s;
    ok(defined $pd, 'found plugindata() body');
    my ($content) = $pd =~ /content\s*=>\s*\[(.*?)\]\s*,/s;
    ok(defined $content, 'found content declaration');
    like($content, qr/images\s*=>\s*1/,  'advertises images');
    like($content, qr/rootdir\s*=>\s*1/, 'advertises rootdir (LXC container rootfs)');
};

subtest 'no_duplicate_pve_common_properties' => sub {
    # Regression guard: PVE common properties (username/password, defined by the
    # base/CIFS/PBS plugins) must NOT be redefined in our properties(), or
    # PVE::SectionConfig dies "duplicate property ..." and breaks pvesm + the PVE
    # daemons. They may only be *referenced* in options(). (Found in live Phase B.)
    my $src = do {
        local $/;
        open my $fh, '<', 'src/PVE/Storage/Custom/HitachiBlockPlugin.pm'
            or die "cannot open plugin source: $!";
        <$fh>;
    };
    my ($props) = $src =~ /sub\s+properties\s*\{(.*?)\n\}/s;
    ok(defined $props, 'found properties() body');
    for my $reserved (qw(username password)) {
        unlike($props, qr/^\s*\Q$reserved\E\s*=>\s*\{/m,
            "properties() does not redefine reserved PVE property '$reserved'");
    }
    # And confirm they are still accepted as input via options().
    my ($opts) = $src =~ /sub\s+options\s*\{(.*?)\n\}/s;
    for my $reserved (qw(username password)) {
        like($opts, qr/^\s*\Q$reserved\E\s*=>/m,
            "options() still references '$reserved'");
    }

    # Modern API: password must be declared sensitive in plugindata, and the
    # add/update hooks must read it from %sensitive (NOT from $scfg, which PVE
    # never populates for sensitive properties).
    my ($pd) = $src =~ /sub\s+plugindata\s*\{(.*?)\n\}/s;
    like($pd, qr/sensitive-properties.*password/s,
        "plugindata declares 'password' as a sensitive-property");
    unlike($src, qr/delete\s+\$scfg->\{password\}/,
        "hooks do not read password from \$scfg (it is sensitive)");
    like($src, qr/sub\s+on_update_hook\b/,
        "on_update_hook is implemented (credential updates)");
};

subtest 'ldev_range_fence' => sub {
    # Mirrors _ldev_in_range: destructive ops (unmap/delete) must refuse any LDEV
    # outside the configured ldev_range. This is the backstop that would have
    # prevented unmapping production LDEV 27 while it shares a port with our range.
    my $in_range = sub {
        my ($range, $id) = @_;
        return 1 unless defined $range && length $range;
        return 0 unless defined $id;
        my ($min, $max);
        if ($range =~ /^(0x[0-9a-f]+)-(0x[0-9a-f]+)$/i) { $min = hex($1); $max = hex($2); }
        elsif ($range =~ /^(\d+)-(\d+)$/)               { $min = int($1); $max = int($2); }
        else { die "bad range\n"; }
        return ($id >= $min && $id <= $max) ? 1 : 0;
    };
    ok($in_range->('256-511', 256), 'min boundary in range');
    ok($in_range->('256-511', 511), 'max boundary in range');
    ok($in_range->('256-511', 300), 'middle in range');
    ok(!$in_range->('256-511', 255), 'just below excluded');
    ok(!$in_range->('256-511', 512), 'just above excluded');
    ok(!$in_range->('256-511', 27),  'production LDEV 27 excluded (the incident)');
    ok($in_range->('0x100-0x1ff', 256),   'hex range min');
    ok(!$in_range->('0x100-0x1ff', 0x200),'hex range above excluded');
    ok($in_range->(undef, 27), 'no range configured => no fence');
};

subtest 'status_pool_used_logic' => sub {
    # Mirrors status(): derive used/free (bytes) from a pool object whose MB
    # fields may or may not include usedPoolCapacity. Confirmed on a VSP E590H
    # that usedPoolCapacity is null while availableVolumeCapacity is populated.
    my $mb = 1024 * 1024;
    my $derive = sub {
        my ($pool) = @_;
        my $total = ($pool->{totalPoolCapacity} || 0) * $mb;
        my $used;
        if (defined $pool->{usedPoolCapacity}) {
            $used = $pool->{usedPoolCapacity} * $mb;
        } elsif (defined $pool->{availableVolumeCapacity}) {
            $used = $total - $pool->{availableVolumeCapacity} * $mb;
        } elsif (defined $pool->{usedCapacityRate}) {
            $used = int($total * $pool->{usedCapacityRate} / 100);
        } else {
            $used = 0;
        }
        $used = 0      if $used < 0;
        $used = $total if $used > $total;
        my $free = $total - $used;
        $free = 0 if $free < 0;
        return ($total, $free, $used);
    };

    # 1. usedPoolCapacity present -> used directly from it.
    my @r = $derive->({ totalPoolCapacity => 10240, usedPoolCapacity => 2048 });
    is($r[0], 10240 * $mb, 'total');
    is($r[2], 2048 * $mb,  'used from usedPoolCapacity');
    is($r[1], 8192 * $mb,  'free = total - used');

    # 2. E590H case: usedPoolCapacity null -> derive from availableVolumeCapacity.
    @r = $derive->({ totalPoolCapacity => 22210482, usedPoolCapacity => undef,
                     availableVolumeCapacity => 21576282, usedCapacityRate => 2 });
    is($r[2], (22210482 - 21576282) * $mb, 'used = total - availableVolumeCapacity');
    is($r[1], 21576282 * $mb, 'free = availableVolumeCapacity');
    ok($r[2] > 0, 'pool is NOT reported as 0%-used (the bug this guards)');

    # 3. last resort: only usedCapacityRate present.
    @r = $derive->({ totalPoolCapacity => 1000, usedCapacityRate => 25 });
    is($r[2], int(1000 * $mb * 25 / 100), 'used from usedCapacityRate');

    # clamp: nonsense available > total must not yield negative used.
    @r = $derive->({ totalPoolCapacity => 100, availableVolumeCapacity => 999 });
    is($r[2], 0, 'used clamped to >= 0');
    is($r[1], 100 * $mb, 'free clamped to total');
};

subtest 'vmid_from_volname' => sub {
    my $extract = sub {
        my ($v) = @_;
        return ($v =~ /^vm-(\d+)-/) ? $1 : 0;
    };

    is($extract->('vm-100-disk-1'), 100, 'vmid 100');
    is($extract->('vm-999-disk-5'), 999, 'vmid 999');
    is($extract->('invalid'), 0, 'no vmid');
};

# ── Next Volume Name Generation ──

subtest 'next_volname_logic' => sub {
    my %registry = (
        'vm-100-disk-1' => { ldev_id => 1 },
        'vm-100-disk-2' => { ldev_id => 2 },
        'vm-100-disk-5' => { ldev_id => 5 },
        'vm-200-disk-1' => { ldev_id => 10 },
    );

    my $vmid = 100;
    my $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }

    is($max_seq, 5, 'max seq for vm-100 is 5');
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-100-disk-6', 'next is disk-6');

    # For vm-200
    $vmid = 200;
    $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-200-disk-2', 'next is disk-2');

    # For new vmid
    $vmid = 300;
    $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-300-disk-1', 'first disk for new vm');
};

# ── Feature Matrix ──

subtest 'volume_has_feature_logic' => sub {
    # Mirrors volume_has_feature: keyed by base/current/snap (LVM-thin model).
    my $features = {
        snapshot   => { current => 1 },
        clone      => { base => 1, snap => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        template   => { current => 1 },
        rename     => { current => 1 },
        resize     => { current => 1 },
    };

    my $check = sub {
        my ($feature, $isBase, $snapname) = @_;
        my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');
        return ($features->{$feature} && $features->{$feature}{$key}) ? 1 : 0;
    };

    # Linked clones are CoW: offered only from a base image or a snapshot.
    is($check->('clone', 0, undef),   0, 'no linked clone of a live volume');
    is($check->('clone', 1, undef),   1, 'linked clone of a base image');
    is($check->('clone', 0, 'snap1'), 1, 'linked clone from a snapshot');

    is($check->('snapshot', 0, undef),   1, 'snapshot a live volume');
    is($check->('snapshot', 0, 'snap1'), 0, 'no snapshot of a snapshot');

    is($check->('template', 0, undef), 1, 'template from a live volume');
    is($check->('rename',   0, undef), 1, 'rename a live volume');
    is($check->('resize',   0, undef), 1, 'resize a live volume');
    is($check->('resize', 0, 'snap1'), 0, 'no resize of a snapshot');

    is($check->('copy', 0, undef), 1, 'copy a live volume');
    is($check->('copy', 1, undef), 1, 'copy a base image');

    is($check->('unknown', 0, undef), 0, 'unknown feature');
};

# ── LDEV Range Parsing ──

subtest 'ldev_range_parsing' => sub {
    # Decimal range
    my $range = '1000-1999';
    if ($range =~ /^(\d+)-(\d+)$/) {
        is($1, 1000, 'decimal min');
        is($2, 1999, 'decimal max');
    } else {
        fail('should match decimal');
    }

    # Hex range
    $range = '0x3E8-0x7CF';
    if ($range =~ /^(0x[0-9a-f]+)-(0x[0-9a-f]+)$/i) {
        is(hex($1), 1000, 'hex min');
        is(hex($2), 1999, 'hex max');
    } else {
        fail('should match hex');
    }

    # Invalid range
    $range = 'invalid';
    ok($range !~ /^(0x[0-9a-fA-F]+|\d+)-(0x[0-9a-fA-F]+|\d+)$/, 'invalid range rejected');
};

# ── Port Scheduler Logic ──

subtest 'port_scheduler_deterministic_by_ldev' => sub {
    # Mirrors _select_ports: a given LDEV always maps to the same two ports
    # (stable across processes/nodes), giving multipath redundancy without an
    # in-memory counter that resets every pvesm invocation.
    my @all_ports = ('CL1-A', 'CL2-A', 'CL3-A', 'CL4-A');

    my $select = sub {
        my ($ldev_id) = @_;
        my $n = scalar(@all_ports);
        my $idx = defined $ldev_id ? ($ldev_id % $n) : 0;
        my $next = ($idx + 1) % $n;
        return ($all_ports[$idx], $all_ports[$next]);
    };

    is_deeply([$select->(0)], ['CL1-A', 'CL2-A'], 'ldev 0 -> ports 0,1');
    is_deeply([$select->(1)], ['CL2-A', 'CL3-A'], 'ldev 1 -> ports 1,2');
    is_deeply([$select->(3)], ['CL4-A', 'CL1-A'], 'ldev 3 -> ports 3,0 (wraps)');

    # Same LDEV is stable across repeated calls (map/unmap symmetry).
    is_deeply([$select->(42)], [$select->(42)], 'selection is stable per LDEV');
};

# ── Manage/Unmanage Volume Name Logic ──

subtest 'manage_generates_volname' => sub {
    # When managing an existing LDEV, a new volname is generated
    my %registry = (
        'vm-100-disk-1' => { ldev_id => 1 },
        'vm-100-disk-2' => { ldev_id => 2 },
    );

    my $vmid = 100;
    my $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-100-disk-3',
       'managed LDEV gets next available volname');
};

# ── Volume Export/Import Format Gating ──

subtest 'volume_import_formats_logic' => sub {
    # Mirrors volume_import_formats / volume_export_formats: only a non-snapshot,
    # non-incremental raw stream is offered (array snapshots are not streamed).
    my $formats = sub {
        my (%o) = @_;
        return () if $o{with_snapshots};
        return () if defined($o{base_snapshot});
        return () if defined($o{snapshot});
        return ('raw+size');
    };

    is_deeply([$formats->()], ['raw+size'], 'plain volume offers raw+size');
    is_deeply([$formats->(with_snapshots => 1)], [], 'no stream with snapshots');
    is_deeply([$formats->(base_snapshot => 'b')], [], 'no incremental stream');
    is_deeply([$formats->(snapshot => 's')], [], 'no snapshot-specific stream');
};

subtest 'volume_export_streams_whole_device' => sub {
    # Regression guard (incident 2026-06-20): a copy onto the storage must stream the
    # ENTIRE device. Assert volume_export writes the size header and runs dd over the
    # whole device with NO count=/skip=/seek= that would short-stream/truncate it.
    my $src = do {
        local $/;
        open my $fh, '<', 'src/PVE/Storage/Custom/HitachiBlockPlugin.pm'
            or die "cannot open plugin source: $!";
        <$fh>;
    };
    my ($body) = $src =~ /sub\s+volume_export\s*\{(.*?)\n\}/s;
    ok(defined $body, 'found volume_export() body');
    like($body, qr/write_common_header\s*\(\s*\$fh\s*,\s*\$size\s*\)/,
        'writes the raw+size header with the full volume size');
    my ($dd) = $body =~ /run_command\s*\(\s*(\[.*?\])/s;
    ok(defined $dd, 'volume_export runs dd via run_command');
    like($dd, qr/if=\$path/, 'dd reads the whole device path');
    unlike($dd, qr/\bcount=/,  'no count= (would truncate the stream)');
    unlike($dd, qr/\bskip=/,   'no skip= (would drop the head)');
    unlike($dd, qr/\bseek=/,   'no seek=');
};

# ── snap_pool Thin Image capability validation (#21) ──

# Replicate the bad-pool decision in _assert_snap_pool_supports_ti so the
# classification is covered without loading the full plugin (needs PVE libs).
subtest 'snap_pool_ti_capability_logic' => sub {
    my $is_bad = sub {
        my ($pool) = @_;
        my $type = $pool->{poolType} // '';
        return 1 if $type eq 'HDT';
        return 1 if ref $pool->{tiers} eq 'ARRAY' && @{ $pool->{tiers} } > 1;
        return 1 if $pool->{dataDirectMappingEnabled};
        return 1 if $pool->{isMainframe};
        return 0;
    };

    ok($is_bad->({ poolType => 'HDT', tiers => [ {}, {} ] }), 'HDT multi-tier pool rejected');
    ok($is_bad->({ poolType => 'HDP', tiers => [ {}, {} ] }), 'multi-tier pool rejected even if type not HDT');
    ok($is_bad->({ poolType => 'HDP', dataDirectMappingEnabled => 1 }), 'data-direct-mapping pool rejected');
    ok($is_bad->({ poolType => 'HDP', isMainframe => 1 }), 'mainframe pool rejected');
    ok(!$is_bad->({ poolType => 'HDP' }), 'plain single-tier HDP pool accepted');
    ok(!$is_bad->({ poolType => 'HDP', tiers => [ {} ] }), 'single-tier HDP (one tier) accepted');
};

# The validation must run at every Thin Image entry point so the array's cryptic
# mid-operation error never leaks. Assert the call sites in the source.
subtest 'snap_pool_validation_call_sites' => sub {
    my $src = do {
        local $/;
        open my $fh, '<', 'src/PVE/Storage/Custom/HitachiBlockPlugin.pm'
            or die "open plugin: $!";
        <$fh>;
    };
    ok($src =~ /sub _assert_snap_pool_supports_ti/, 'helper is defined');
    for my $sub (qw(volume_snapshot clone_image volume_snapshot_consistency_group)) {
        my ($body) = $src =~ /\nsub \Q$sub\E\s*\{(.*?)\n\}/s;
        ok(defined $body && $body =~ /_assert_snap_pool_supports_ti/,
            "$sub calls _assert_snap_pool_supports_ti");
    }
    my ($h) = $src =~ /sub _assert_snap_pool_supports_ti\s*\{(.*?)\n\}/s;
    like($h, qr/single-tier HDP/, 'error message states the HDP requirement');
};

# ── Cluster-lock timeout override (#10) ──

# Replicate _resolve_lock_timeout precedence (caller > configured > default)
# without loading the PVE cluster stack.
subtest 'lock_timeout_resolution_logic' => sub {
    my $DEFAULT = 120;
    my $resolve = sub {
        my ($caller, $configured) = @_;
        return $caller     if defined $caller;
        return $configured if defined $configured;
        return $DEFAULT;
    };
    is($resolve->(30, 90),    30,  'explicit caller timeout wins');
    is($resolve->(undef, 90), 90,  'configured lock_timeout used when caller is undef');
    is($resolve->(undef, undef), 120, 'falls back to the default when neither is set');
    is($resolve->(0, 90),     0,   'an explicit 0 (no wait) is honoured, not overridden');
};

subtest 'cluster_lock_storage_override' => sub {
    my $src = do {
        local $/;
        open my $fh, '<', 'src/PVE/Storage/Custom/HitachiBlockPlugin.pm'
            or die "open plugin: $!";
        <$fh>;
    };
    ok($src =~ /sub cluster_lock_storage/, 'overrides cluster_lock_storage');
    my ($body) = $src =~ /\nsub cluster_lock_storage\s*\{(.*?)\n\}/s;
    like($body, qr/_resolve_lock_timeout/, 'uses the resolver to pick the timeout');
    like($body, qr/SUPER::cluster_lock_storage/, 'delegates to the PVE base lock');
    like($body, qr/lock_timeout/, 'reads the configured lock_timeout');
    like($src, qr/\$DEFAULT_LOCK_TIMEOUT\s*=\s*120/, 'default lock timeout is 120s');
};

done_testing();
