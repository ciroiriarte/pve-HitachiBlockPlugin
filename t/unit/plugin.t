#!/usr/bin/perl

# Plugin unit tests.
#
# These exercise the REAL plugin subs (parse_volname, vmid_from_volname,
# _alloc_size_mb, _ldev_size_mb, _ldev_range_cu_info, _ldev_in_range,
# _select_ports, volume_has_feature, volume_import/export_formats,
# _resolve_lock_timeout, status, _assert_snap_pool_supports_ti). The plugin
# module can't be loaded without the PVE framework, so we stub the three PVE
# modules it imports at compile time (base class + the two exporters), exactly
# as t/unit/blockdev.t and t/unit/attributes.t do, then load the real plugin.
#
# A few subtests still assert plugin behaviour by reading the source (drift
# alarms with no callable seam) or mirror an inline algorithm that can't be
# extracted without a live array — those are clearly labelled below.

use strict;
use warnings;

use Test::More;

# ── Minimal PVE stubs so HitachiBlockPlugin.pm compiles standalone ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }                # overridden by the real plugin
}
BEGIN {
    $INC{'PVE/JSONSchema.pm'} = 1;
    package PVE::JSONSchema;
    require Exporter;
    our @ISA       = ('Exporter');
    our @EXPORT_OK = ('get_standard_option');
    sub get_standard_option { return {} }
}
BEGIN {
    $INC{'PVE/Tools.pm'} = 1;
    package PVE::Tools;
    require Exporter;
    our @ISA       = ('Exporter');
    our @EXPORT_OK = ('run_command');
    sub run_command { die "run_command stub should not be called in this test\n" }
}

use lib 'src';
require_ok('PVE::Storage::Custom::HitachiBlockPlugin');

my $CLASS = 'PVE::Storage::Custom::HitachiBlockPlugin';

# Tiny fake REST client: get_pool($id) returns a fixed pool hash (or undef), so
# subs that go through $client->get_pool can be unit-tested without an array.
{
    package T::FakeClient;
    sub new     { my ($c, $pool) = @_; bless { pool => $pool }, $c }
    sub get_pool { return $_[0]->{pool} }
}

# ── Volume Name Parsing ──

subtest 'parse_volname_valid' => sub {
    my @r = $CLASS->parse_volname('vm-100-disk-1');
    is($r[0], 'images', 'vtype is images');
    is($r[1], 'vm-100-disk-1', 'name preserved');
    is($r[2], 100, 'vmid extracted');
    is($r[5], undef, 'isBase flag unset for a live volume');
    is($r[6], 'raw', 'format is raw');
};

subtest 'parse_volname_invalid' => sub {
    eval { $CLASS->parse_volname('invalid-name') };
    like($@, qr/unable to parse volume name/, 'invalid name dies');
};

subtest 'parse_volname_base' => sub {
    my @base = $CLASS->parse_volname('base-100-disk-1');
    is($base[2], 100, 'base vmid extracted');
    is($base[5], 1, 'base isBase flag set');

    my @vm = $CLASS->parse_volname('vm-100-disk-1');
    is($vm[2], 100, 'vm vmid extracted');
    is($vm[5], undef, 'vm isBase flag unset');

    # vmid_from_volname accepts both prefixes (plain function, no $class arg).
    is(PVE::Storage::Custom::HitachiBlockPlugin::vmid_from_volname('base-200-disk-3'),
        200, 'vmid from base name');
    is(PVE::Storage::Custom::HitachiBlockPlugin::vmid_from_volname('vm-300-disk-1'),
        300, 'vmid from vm name');
};

subtest 'parse_volname_cloudinit' => sub {
    # parse_volname must accept the cloud-init drive PVE allocates as a tiny raw
    # LUN named vm-<vmid>-cloudinit, or the array LDEV leaks (GitHub #6).
    my @ci = $CLASS->parse_volname('vm-9100-cloudinit');
    is($ci[0], 'images', 'cloudinit vtype is images');
    is($ci[1], 'vm-9100-cloudinit', 'cloudinit name preserved');
    is($ci[2], 9100, 'cloudinit vmid extracted');
    is($ci[5], undef, 'cloudinit isBase flag unset');
    is($ci[6], 'raw', 'cloudinit format is raw');

    # vmid_from_volname must also key off the cloudinit name.
    is(PVE::Storage::Custom::HitachiBlockPlugin::vmid_from_volname('vm-9100-cloudinit'),
        9100, 'vmid from cloudinit name');

    # Names that must still be rejected (no silent accept-anything).
    eval { $CLASS->parse_volname('vm-100-cloudinit-extra') };
    like($@, qr/unable to parse volume name/, 'trailing junk after cloudinit rejected');
    eval { $CLASS->parse_volname('vm-cloudinit') };
    like($@, qr/unable to parse volume name/, 'cloudinit without vmid rejected');
};

subtest 'vmid_from_volname' => sub {
    # Plain function (no $class): fully-qualified call so the volname is $_[0].
    my $f = \&PVE::Storage::Custom::HitachiBlockPlugin::vmid_from_volname;
    is($f->('vm-100-disk-1'), 100, 'vmid 100');
    is($f->('vm-999-disk-5'), 999, 'vmid 999');
    is($f->('invalid'), 0, 'no vmid');
};

subtest 'ldev_size_mb_logic' => sub {
    # _ldev_size_mb: prefer exact block count over the formatted string.
    is($CLASS->_ldev_size_mb({ blockCapacity => 2097152 }), 1024,
        '2097152 blocks = 1024 MB');
    is($CLASS->_ldev_size_mb({ byteFormatCapacity => '1.00 G' }), 1024,
        '1G string = 1024 MB');
    is($CLASS->_ldev_size_mb({ byteFormatCapacity => '2.00 T' }), 2097152,
        '2T string = 2097152 MB');
    is($CLASS->_ldev_size_mb({ byteFormatCapacity => '512.00 M' }), 512,
        '512M string = 512 MB');
    # Block count takes precedence over the formatted string when both present.
    is($CLASS->_ldev_size_mb({ blockCapacity => 2097152, byteFormatCapacity => '999.00 G' }),
        1024, 'block count wins over byteFormatCapacity');
};

subtest 'ldev_range_cu_alignment' => sub {
    # _ldev_range_cu_info($min,$max) returns ($aligned, $first_cu, $last_cu);
    # $aligned is a boolean (1 / '') from a && of two modulo checks.
    is_deeply([$CLASS->_ldev_range_cu_info(0, 255)],    [1, 0, 0],
        '0-255 = whole CU 0 (aligned)');
    is_deeply([$CLASS->_ldev_range_cu_info(256, 511)],  [1, 1, 1],
        '256-511 = whole CU 1 (aligned)');
    is_deeply([$CLASS->_ldev_range_cu_info(256, 2303)], [1, 1, 8],
        '256-2303 = CU 1-8 (aligned)');
    is(($CLASS->_ldev_range_cu_info(300, 500))[0], '', '300-500 is not CU-aligned');
    is(($CLASS->_ldev_range_cu_info(256, 510))[0], '', '256-510 (ends mid-CU) is not aligned');
    is(($CLASS->_ldev_range_cu_info(1, 511))[0],   '', '1-511 (starts mid-CU) is not aligned');
};

subtest 'alloc_size_mb_floor' => sub {
    # _alloc_size_mb: KiB -> MiB (round up), floored to the array minimum
    # ($MIN_LDEV_MB = 48; the E590H rejects DP-VOLs <= 46 MiB).
    is($CLASS->_alloc_size_mb(4096), 48,   'PVE vTPM (4 MiB) floored to the array minimum');
    is($CLASS->_alloc_size_mb(528),  48,   'sub-MiB EFI vars floored to the array minimum');
    is($CLASS->_alloc_size_mb(0),    48,   'zero/undef floored to the array minimum');
    is($CLASS->_alloc_size_mb(48 * 1024), 48,      '48 MiB stays 48 (at the floor)');
    is($CLASS->_alloc_size_mb(49 * 1024), 49,      '49 MiB passes through exactly (no rounding up)');
    is($CLASS->_alloc_size_mb(8 * 1024 * 1024), 8192, '8 GiB passes through exactly');
    is($CLASS->_alloc_size_mb(100 * 1024 + 512), 101, 'non-MiB-aligned size above floor rounds up to whole MiB');
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
    # _ldev_in_range($scfg,$ldev_id): destructive ops (unmap/delete) must refuse
    # any LDEV outside the configured ldev_range. This is the backstop that would
    # have prevented unmapping production LDEV 27 while it shares a port with our
    # range. Also folds in ldev_range_parsing (decimal + hex range forms).
    ok($CLASS->_ldev_in_range({ ldev_range => '256-511' }, 256), 'min boundary in range');
    ok($CLASS->_ldev_in_range({ ldev_range => '256-511' }, 511), 'max boundary in range');
    ok($CLASS->_ldev_in_range({ ldev_range => '256-511' }, 300), 'middle in range');
    ok(!$CLASS->_ldev_in_range({ ldev_range => '256-511' }, 255), 'just below excluded');
    ok(!$CLASS->_ldev_in_range({ ldev_range => '256-511' }, 512), 'just above excluded');
    ok(!$CLASS->_ldev_in_range({ ldev_range => '256-511' }, 27),
        'production LDEV 27 excluded (the incident)');

    # Hex range form is parsed the same as decimal (folds in ldev_range_parsing).
    ok($CLASS->_ldev_in_range({ ldev_range => '0x100-0x1ff' }, 256), 'hex range min');
    ok(!$CLASS->_ldev_in_range({ ldev_range => '0x100-0x1ff' }, 0x200),
        'hex range above excluded');
    ok($CLASS->_ldev_in_range({ ldev_range => '1000-1999' }, 1000), 'decimal range min');
    ok($CLASS->_ldev_in_range({ ldev_range => '1000-1999' }, 1999), 'decimal range max');

    # No range configured => no fence (always in range).
    ok($CLASS->_ldev_in_range({}, 27), 'no range configured => no fence');

    # A malformed range dies rather than silently accepting.
    eval { $CLASS->_ldev_in_range({ ldev_range => 'invalid' }, 27) };
    like($@, qr/Invalid ldev_range/, 'malformed range rejected');
};

subtest 'status_pool_used_logic' => sub {
    # status() derives ($total,$free,$used) from the pool object get_pool returns.
    # Drive it through a fake _client so no array is needed. Confirmed on a VSP
    # E590H that usedPoolCapacity is null while availableVolumeCapacity is set.
    my $mb = 1024 * 1024;
    my $scfg = { pool_id => 1 };
    my $fake_pool;
    no warnings 'redefine';
    local *PVE::Storage::Custom::HitachiBlockPlugin::_client = sub {
        return T::FakeClient->new($fake_pool);
    };

    # 1. usedPoolCapacity present -> used directly from it.
    $fake_pool = { totalPoolCapacity => 10240, usedPoolCapacity => 2048 };
    my ($total, $free, $used) = $CLASS->status('store', $scfg, {});
    is($total, 10240 * $mb, 'total');
    is($used,  2048 * $mb,  'used from usedPoolCapacity');
    is($free,  8192 * $mb,  'free = total - used');

    # 2. E590H case: usedPoolCapacity null -> derive from availableVolumeCapacity.
    $fake_pool = { totalPoolCapacity => 22210482, usedPoolCapacity => undef,
                   availableVolumeCapacity => 21576282, usedCapacityRate => 2 };
    ($total, $free, $used) = $CLASS->status('store', $scfg, {});
    is($used, (22210482 - 21576282) * $mb, 'used = total - availableVolumeCapacity');
    is($free, 21576282 * $mb, 'free = availableVolumeCapacity');
    ok($used > 0, 'pool is NOT reported as 0%-used (the bug this guards)');

    # 3. last resort: only usedCapacityRate present.
    $fake_pool = { totalPoolCapacity => 1000, usedCapacityRate => 25 };
    ($total, $free, $used) = $CLASS->status('store', $scfg, {});
    is($used, int(1000 * $mb * 25 / 100), 'used from usedCapacityRate');

    # clamp: nonsense available > total must not yield negative used.
    $fake_pool = { totalPoolCapacity => 100, availableVolumeCapacity => 999 };
    ($total, $free, $used) = $CLASS->status('store', $scfg, {});
    is($used, 0, 'used clamped to >= 0');
    is($free, 100 * $mb, 'free clamped to total');
};

# ── Next Volume Name Generation (DOCUMENTED MIRROR) ──

subtest 'next_volname_logic' => sub {
    # DOCUMENTED DEFERRAL: there is no _next_volname/find_free_volname seam — the
    # next-name logic lives inline in alloc_image/manage_volume and needs a live
    # registry/array to exercise. This subtest asserts the Perl idiom only; it is
    # not a call into the real sub. (Kept as a low-value drift note.)
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
    # volume_has_feature parses $volname internally to decide base/current/snap,
    # so drive base with 'base-100-disk-1', current with 'vm-100-disk-1', and a
    # snapshot by passing $snapname. Returns 1 (offered) or undef (not offered).
    my $scfg = {};
    my $has = sub {
        my ($feature, $volname, $snapname) = @_;
        return $CLASS->volume_has_feature($scfg, $feature, 'store', $volname, $snapname, 0);
    };

    # Linked clones are CoW: offered only from a base image or a snapshot.
    is($has->('clone', 'vm-100-disk-1', undef),    undef, 'no linked clone of a live volume');
    is($has->('clone', 'base-100-disk-1', undef),  1,     'linked clone of a base image');
    is($has->('clone', 'vm-100-disk-1', 'snap1'),  1,     'linked clone from a snapshot');

    is($has->('snapshot', 'vm-100-disk-1', undef),   1,     'snapshot a live volume');
    is($has->('snapshot', 'vm-100-disk-1', 'snap1'), undef, 'no snapshot of a snapshot');

    is($has->('template', 'vm-100-disk-1', undef), 1, 'template from a live volume');
    is($has->('rename',   'vm-100-disk-1', undef), 1, 'rename a live volume');
    is($has->('resize',   'vm-100-disk-1', undef), 1, 'resize a live volume');
    is($has->('resize',   'vm-100-disk-1', 'snap1'), undef, 'no resize of a snapshot');

    is($has->('copy', 'vm-100-disk-1', undef),   1, 'copy a live volume');
    is($has->('copy', 'base-100-disk-1', undef), 1, 'copy a base image');

    is($has->('unknown', 'vm-100-disk-1', undef), undef, 'unknown feature');
};

# ── Port Scheduler Logic ──

subtest 'port_scheduler_deterministic_by_ldev' => sub {
    # _select_ports: with port_scheduler enabled and >2 ports, a given LDEV always
    # maps to the same two ports (stable across processes/nodes), giving multipath
    # redundancy without an in-memory counter that resets every pvesm invocation.
    my $scfg = { target_ports => 'CL1-A,CL2-A,CL3-A,CL4-A', port_scheduler => 1 };
    my $select = sub { [ $CLASS->_select_ports('store', $scfg, $_[0]) ] };

    is_deeply($select->(0), ['CL1-A', 'CL2-A'], 'ldev 0 -> ports 0,1');
    is_deeply($select->(1), ['CL2-A', 'CL3-A'], 'ldev 1 -> ports 1,2');
    is_deeply($select->(3), ['CL4-A', 'CL1-A'], 'ldev 3 -> ports 3,0 (wraps)');

    # Same LDEV is stable across repeated calls (map/unmap symmetry).
    is_deeply($select->(42), $select->(42), 'selection is stable per LDEV');
};

# ── Manage/Unmanage Volume Name Logic (DOCUMENTED MIRROR) ──

subtest 'manage_generates_volname' => sub {
    # DOCUMENTED DEFERRAL: like next_volname_logic, the managed-LDEV naming lives
    # inline in manage_volume with no extractable seam (needs a live array). This
    # asserts the Perl idiom only, not a real sub call.
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
    # volume_import_formats / volume_export_formats: only a non-snapshot,
    # non-incremental raw stream is offered (array snapshots are not streamed).
    my $scfg = {};
    my $vol  = 'vm-100-disk-1';

    is_deeply([$CLASS->volume_import_formats($scfg, 'store', $vol, undef, undef, undef)],
        ['raw+size'], 'plain volume offers raw+size');
    is_deeply([$CLASS->volume_import_formats($scfg, 'store', $vol, undef, undef, 1)],
        [], 'no stream with snapshots');
    is_deeply([$CLASS->volume_import_formats($scfg, 'store', $vol, undef, 'b', undef)],
        [], 'no incremental stream');
    is_deeply([$CLASS->volume_import_formats($scfg, 'store', $vol, 's', undef, undef)],
        [], 'no snapshot-specific stream');

    # volume_export_formats delegates to volume_import_formats (same gating).
    is_deeply([$CLASS->volume_export_formats($scfg, 'store', $vol, undef, undef, undef)],
        ['raw+size'], 'export_formats matches import_formats for a plain volume');
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

subtest 'snap_pool_ti_capability_logic' => sub {
    # _assert_snap_pool_supports_ti($storeid,$scfg,$client) dies on an
    # HDT/multi-tier/data-direct-mapping/mainframe snap pool and returns quietly
    # otherwise (and quietly if get_pool returns undef). Drive it with a fake
    # client whose get_pool returns the pool under test.
    my $scfg = { snap_pool_id => 7 };
    my $assert = sub {
        my ($pool) = @_;
        my $client = T::FakeClient->new($pool);
        eval { $CLASS->_assert_snap_pool_supports_ti('store', $scfg, $client) };
        return $@;
    };

    like($assert->({ poolType => 'HDT', tiers => [ {}, {} ] }), qr/single-tier HDP/,
        'HDT multi-tier pool rejected');
    like($assert->({ poolType => 'HDP', tiers => [ {}, {} ] }), qr/single-tier HDP/,
        'multi-tier pool rejected even if type not HDT');
    like($assert->({ poolType => 'HDP', dataDirectMappingEnabled => 1 }), qr/single-tier HDP/,
        'data-direct-mapping pool rejected');
    like($assert->({ poolType => 'HDP', isMainframe => 1 }), qr/single-tier HDP/,
        'mainframe pool rejected');
    is($assert->({ poolType => 'HDP' }), '', 'plain single-tier HDP pool accepted');
    is($assert->({ poolType => 'HDP', tiers => [ {} ] }), '',
        'single-tier HDP (one tier) accepted');
    is($assert->(undef), '', 'unreadable pool (get_pool undef) does not block the op');
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

subtest 'lock_timeout_resolution_logic' => sub {
    # _resolve_lock_timeout precedence: caller > configured > default (120).
    is($CLASS->_resolve_lock_timeout(30, 90),    30,  'explicit caller timeout wins');
    is($CLASS->_resolve_lock_timeout(undef, 90), 90,  'configured lock_timeout used when caller is undef');
    is($CLASS->_resolve_lock_timeout(undef, undef), 120, 'falls back to the default when neither is set');
    is($CLASS->_resolve_lock_timeout(0, 90),     0,   'an explicit 0 (no wait) is honoured, not overridden');
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
