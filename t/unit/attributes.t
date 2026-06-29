#!/usr/bin/perl

# Per-volume attribute tests: protected + notes (issue #15).
#
# These exercise the REAL plugin methods (get/update_volume_attribute,
# get/update_volume_notes) and the free_image protected guard. As in blockdev.t
# we stub the PVE modules the plugin imports at compile time so the real plugin
# loads; the LDEV registry is redirected to a tempdir so the registry-backed
# attributes round-trip without an array.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

# ── Minimal PVE stubs so HitachiBlockPlugin.pm compiles standalone ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }
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
    sub run_command { die "run_command stub should not be called\n" }
}

use lib 'src';
require_ok('PVE::Storage::Custom::HitachiBlockPlugin');
require_ok('PVE::Storage::HitachiBlock::Config');

my $CLASS = 'PVE::Storage::Custom::HitachiBlockPlugin';

# Redirect the registry to a tempdir for every Config instance the plugin builds.
my $tmpdir = tempdir(CLEANUP => 1);
no warnings 'redefine';
local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/reg.json" };

my $scfg = { type => 'hitachiblock', storage_id => '836000123456' };
my $store = 'mystore';
my $vol   = 'vm-100-disk-1';

# Seed a registered volume.
my $cfg = PVE::Storage::HitachiBlock::Config->new(storeid => $store);
$cfg->register_ldev($vol, 256, size_mb => 1024, wwid => '60060e80abc0100');

# ── protected attribute ──
subtest 'protected round-trip' => sub {
    is($CLASS->get_volume_attribute($scfg, $store, $vol, 'protected'), 0,
        'unset protected reads as 0');

    $CLASS->update_volume_attribute($scfg, $store, $vol, 'protected', 1);
    is($CLASS->get_volume_attribute($scfg, $store, $vol, 'protected'), 1,
        'protected set reads as 1');

    $CLASS->update_volume_attribute($scfg, $store, $vol, 'protected', 0);
    is($CLASS->get_volume_attribute($scfg, $store, $vol, 'protected'), 0,
        'protected cleared reads as 0');
};

# ── notes attribute + entry points ──
subtest 'notes round-trip' => sub {
    is($CLASS->get_volume_notes($scfg, $store, $vol), '', 'no notes -> empty string');

    $CLASS->update_volume_notes($scfg, $store, $vol, 'production DB disk');
    is($CLASS->get_volume_notes($scfg, $store, $vol), 'production DB disk',
        'notes survive a round-trip via the notes entry points');

    # Same value via the generic attribute API.
    is($CLASS->get_volume_attribute($scfg, $store, $vol, 'notes'), 'production DB disk',
        'get_volume_attribute(notes) delegates to get_volume_notes');
    $CLASS->update_volume_attribute($scfg, $store, $vol, 'notes', 'changed');
    is($CLASS->get_volume_notes($scfg, $store, $vol), 'changed',
        'update_volume_attribute(notes) delegates to update_volume_notes');

    $CLASS->update_volume_notes($scfg, $store, $vol, '');
    is($CLASS->get_volume_notes($scfg, $store, $vol), '', 'empty notes clear the field');
};

# ── unknown attribute / unknown volume ──
subtest 'error paths' => sub {
    is($CLASS->get_volume_attribute($scfg, $store, $vol, 'bogus'), undef,
        'unknown attribute reads as undef');
    eval { $CLASS->update_volume_attribute($scfg, $store, $vol, 'bogus', 1) };
    like($@, qr/attribute 'bogus' is not supported/, 'unknown attribute write dies');

    eval { $CLASS->update_volume_attribute($scfg, $store, 'vm-999-disk-1', 'protected', 1) };
    like($@, qr/not found in registry/, 'protected on unknown volume dies');
};

# ── free_image must refuse a protected volume ──
subtest 'free_image honours protected' => sub {
    $CLASS->update_volume_attribute($scfg, $store, $vol, 'protected', 1);
    # The protected check runs before any array session is opened, so this dies
    # with the protected error rather than a connection error.
    eval { $CLASS->free_image($store, $scfg, $vol, 0, 'raw') };
    like($@, qr/marked protected/, 'protected volume cannot be freed');

    # Confirm the volume is still registered (deletion was blocked).
    my ($id) = $cfg->lookup_ldev($vol);
    is($id, 256, 'protected volume survives the free attempt');
};

# ── Debug logging gate (#33) ──
subtest 'plugin _debug level gating' => sub {
    # _debug is a no-op unless $scfg->{debug} >= level, and never throws regardless
    # of syslog availability. We can't read syslog here, so assert the gate contract
    # (safe no-op below threshold, no exception at/above) holds for all levels.
    ok($CLASS->can('_debug'), 'plugin has _debug helper');

    my $off = { storage_id => 'x' };                 # debug unset -> off
    ok(eval { $CLASS->_debug($off, 1, 'should not emit'); 1 }, 'debug unset is a safe no-op');

    my $lvl2 = { storage_id => 'x', debug => 2 };
    ok(eval { $CLASS->_debug($lvl2, 1, 'basic'); 1 },  '_debug(1) at level 2 does not throw');
    ok(eval { $CLASS->_debug($lvl2, 3, 'trace'); 1 },  '_debug(3) at level 2 is a safe no-op');
    # A message containing % must not be treated as a format string.
    ok(eval { $CLASS->_debug($lvl2, 1, '100% used path=/dev/x'); 1 },
        'percent signs in the message are safe');
};

done_testing();
