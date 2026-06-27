#!/usr/bin/perl

# qemu_blockdev_options() unit tests (issue #14).
#
# PVE 9 attaches QEMU disks via the -blockdev interface and asks the storage
# plugin to describe the volume through qemu_blockdev_options(). Our volumes are
# raw block devices presented at /dev/mapper/<wwid>, so we attach them directly
# as a host_device and thread the snapshot name through to path().
#
# The plugin module can't be loaded without the PVE framework, so we stub the
# three PVE modules it imports at compile time (base class + the two exporters).
# This loads the REAL plugin and exercises the REAL qemu_blockdev_options() body;
# only path() is overridden, to feed it a deterministic device path without an
# array/registry behind it.

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

ok($CLASS->can('qemu_blockdev_options'),
    'plugin overrides qemu_blockdev_options (does not inherit the base default)');

# Record what the method passes to path() and return a deterministic device.
my @path_args;
no warnings 'redefine';
local *PVE::Storage::Custom::HitachiBlockPlugin::path = sub {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    @path_args = ($volname, $storeid, $snapname);
    my $wwid = $snapname ? 'snap_wwid' : 'live_wwid';
    return "/dev/mapper/$wwid";
};

my $scfg = { storage_id => '836000123456' };

# ── Live volume ──
subtest 'live volume -> host_device descriptor' => sub {
    @path_args = ();
    my $bd = $CLASS->qemu_blockdev_options($scfg, 'mystore', 'vm-100-disk-1', '9.2', {});

    is(ref($bd), 'HASH', 'returns a hashref');
    is($bd->{driver}, 'host_device', 'driver is host_device (raw block device)');
    is($bd->{filename}, '/dev/mapper/live_wwid', 'filename is the live mapper device');
    is(scalar(keys %$bd), 2, 'descriptor has exactly driver + filename');
    is_deeply([sort keys %$bd], [qw(driver filename)], 'exactly the expected keys');

    is_deeply(\@path_args, ['vm-100-disk-1', 'mystore', undef],
        'path() called with no snapshot name for a live volume');
};

# ── Snapshot ──
subtest 'snapshot -> S-VOL host_device descriptor' => sub {
    @path_args = ();
    my $bd = $CLASS->qemu_blockdev_options(
        $scfg, 'mystore', 'vm-100-disk-1', '9.2', { 'snapshot-name' => 'snap1' });

    is($bd->{driver}, 'host_device', 'snapshot driver is host_device');
    is($bd->{filename}, '/dev/mapper/snap_wwid', 'snapshot filename is the S-VOL mapper device');
    is_deeply(\@path_args, ['vm-100-disk-1', 'mystore', 'snap1'],
        'snapshot-name threaded through to path()');
};

# ── Defensive: a non-absolute path must be rejected, not silently attached ──
subtest 'non-device path is rejected' => sub {
    no warnings 'redefine';
    local *PVE::Storage::Custom::HitachiBlockPlugin::path = sub { return 'rbd:pool/img' };
    eval { $CLASS->qemu_blockdev_options($scfg, 'mystore', 'vm-100-disk-1', '9.2', {}) };
    like($@, qr/expected an absolute device path/, 'rejects a non-absolute path');

    local *PVE::Storage::Custom::HitachiBlockPlugin::path = sub { return undef };
    eval { $CLASS->qemu_blockdev_options($scfg, 'mystore', 'vm-100-disk-1', '9.2', {}) };
    like($@, qr/expected an absolute device path/, 'rejects an undef path');
};

done_testing();
