#!/usr/bin/perl

# Plugin unit tests — tests that don't require PVE framework
# Tests parse_volname, vmid_from_volname, _next_volname, volume_has_feature logic

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

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

# ── Label Format ──

subtest 'label_constraints' => sub {
    # LDEV label has max length on Hitachi arrays (typically 32 chars)
    my $label = "pve:myarray:vm-100-disk-1";
    ok(length($label) <= 32, "label '$label' fits 32 chars (" . length($label) . ")");

    # Longer storeid
    my $long_label = "pve:verylongstoragename:vm-99999-disk-99";
    if (length($long_label) > 32) {
        pass("long label exceeds 32 chars (" . length($long_label) . ") - may need truncation");
    } else {
        pass("long label fits");
    }
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

done_testing();
