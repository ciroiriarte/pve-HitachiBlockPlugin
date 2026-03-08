#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use JSON qw(decode_json);

# Override config paths for testing
BEGIN {
    no warnings 'redefine';
    $ENV{HITACHI_TEST_MODE} = 1;
}

use lib 'src';
use PVE::Storage::HitachiBlock::Config;

# ── Label Helpers ──

subtest 'make_label' => sub {
    my $label = PVE::Storage::HitachiBlock::Config->make_label('myarray', 'vm-100-disk-1');
    is($label, 'pve:myarray:vm-100-disk-1', 'label format correct');
};

subtest 'parse_label' => sub {
    my $parsed = PVE::Storage::HitachiBlock::Config->parse_label('pve:myarray:vm-100-disk-1');
    is($parsed->{storeid}, 'myarray', 'parsed storeid');
    is($parsed->{volname}, 'vm-100-disk-1', 'parsed volname');

    my $invalid = PVE::Storage::HitachiBlock::Config->parse_label('garbage');
    is($invalid, undef, 'invalid label returns undef');
};

# ── Platform Defaults ──

subtest 'platform_defaults' => sub {
    my $vsp_one = PVE::Storage::HitachiBlock::Config->platform_defaults('vsp_one');
    is($vsp_one->{port}, 443, 'VSP One default port');

    my $vsp_g = PVE::Storage::HitachiBlock::Config->platform_defaults('vsp_g');
    is($vsp_g->{port}, 23451, 'VSP G default port');

    my $unknown = PVE::Storage::HitachiBlock::Config->platform_defaults('unknown');
    is($unknown->{port}, 443, 'Unknown platform falls back to VSP One');
};

# ── Validation ──

subtest 'validate_config' => sub {
    my $valid = {
        mgmt_ip      => '10.0.1.100',
        storage_id   => '836000123456',
        pool_id      => 0,
        target_ports => 'CL1-A,CL2-A',
    };

    ok(PVE::Storage::HitachiBlock::Config->validate_config($valid), 'valid config passes');

    eval { PVE::Storage::HitachiBlock::Config->validate_config({}) };
    like($@, qr/mgmt_ip is required/, 'missing mgmt_ip caught');

    eval { PVE::Storage::HitachiBlock::Config->validate_config({ %$valid, platform => 'invalid' }) };
    like($@, qr/platform must be/, 'invalid platform caught');

    # LDEV range validation
    ok(PVE::Storage::HitachiBlock::Config->validate_config({ %$valid, ldev_range => '1000-1999' }),
       'decimal ldev_range valid');
    ok(PVE::Storage::HitachiBlock::Config->validate_config({ %$valid, ldev_range => '0x3E8-0x7CF' }),
       'hex ldev_range valid');

    eval { PVE::Storage::HitachiBlock::Config->validate_config({ %$valid, ldev_range => 'bad' }) };
    like($@, qr/ldev_range must be/, 'invalid ldev_range caught');
};

# ── Registry Operations (with temp dir) ──

subtest 'registry_operations' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Monkey-patch paths for testing
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub {
        return "$tmpdir/test.json";
    };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');

    # Empty registry
    my $reg = $config->load_registry();
    is_deeply($reg, {}, 'empty registry');

    # Register LDEV
    $config->register_ldev('vm-100-disk-1', 42, wwid => 'abc123', size_mb => 1024);
    my ($ldev_id, $meta) = $config->lookup_ldev('vm-100-disk-1');
    is($ldev_id, 42, 'registered ldev_id');
    is($meta->{wwid}, 'abc123', 'registered wwid');
    is($meta->{size_mb}, 1024, 'registered size');

    # List registered
    my $all = $config->list_registered();
    ok(exists $all->{'vm-100-disk-1'}, 'volume in list');

    # Unregister
    $config->unregister_ldev('vm-100-disk-1');
    my $gone = $config->lookup_ldev('vm-100-disk-1');
    is($gone, undef, 'unregistered volume');
};

# ── Credential Operations (with temp dir) ──

subtest 'credential_operations' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_creds_file = sub {
        return "$tmpdir/test.creds";
    };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');

    $config->store_credentials('admin', 'secret');
    my ($user, $pass) = $config->read_credentials();
    is($user, 'admin', 'username stored');
    is($pass, 'secret', 'password stored');

    $config->delete_credentials();
    eval { $config->read_credentials() };
    like($@, qr/not found/, 'deleted credentials');
};

# ── Snapshot Registry Operations ──

subtest 'snapshot_registry' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub {
        return "$tmpdir/test_snap.json";
    };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');

    # Register base volume first
    $config->register_ldev('vm-100-disk-1', 42, wwid => 'abc123', size_mb => 1024);

    # Register snapshot
    $config->register_snapshot('vm-100-disk-1', 'snap1',
        svol_ldev_id   => 100,
        svol_wwid      => 'def456',
        snapshot_id    => 'snap-pair-1',
        snapshot_group => 'pve_test_snap1',
        pvol_ldev_id   => 42,
    );

    # Lookup snapshot
    my $snap_meta = $config->lookup_snapshot('vm-100-disk-1', 'snap1');
    ok($snap_meta, 'snapshot found');
    is($snap_meta->{svol_ldev_id}, 100, 'svol_ldev_id correct');
    is($snap_meta->{svol_wwid}, 'def456', 'svol_wwid correct');
    is($snap_meta->{snapshot_id}, 'snap-pair-1', 'snapshot_id correct');
    ok($snap_meta->{timestamp}, 'timestamp set');

    # List snapshots
    my $snaps = $config->list_snapshots('vm-100-disk-1');
    ok(exists $snaps->{snap1}, 'snap1 in list');

    # Register second snapshot
    $config->register_snapshot('vm-100-disk-1', 'snap2',
        svol_ldev_id   => 101,
        svol_wwid      => 'ghi789',
        snapshot_id    => 'snap-pair-2',
        pvol_ldev_id   => 42,
    );

    $snaps = $config->list_snapshots('vm-100-disk-1');
    is(scalar keys %$snaps, 2, 'two snapshots');

    # Unregister first snapshot
    $config->unregister_snapshot('vm-100-disk-1', 'snap1');
    my $gone = $config->lookup_snapshot('vm-100-disk-1', 'snap1');
    is($gone, undef, 'snap1 unregistered');

    my $still_there = $config->lookup_snapshot('vm-100-disk-1', 'snap2');
    ok($still_there, 'snap2 still exists');

    # Unregister second snapshot — snapshots hash should be cleaned up
    $config->unregister_snapshot('vm-100-disk-1', 'snap2');
    $snaps = $config->list_snapshots('vm-100-disk-1');
    is_deeply($snaps, {}, 'no snapshots remain');

    # Lookup on nonexistent volume
    my $nope = $config->lookup_snapshot('vm-999-disk-1', 'snap1');
    is($nope, undef, 'nonexistent volume returns undef');

    # Error: register snapshot on nonexistent volume
    eval { $config->register_snapshot('vm-999-disk-1', 'snap1', svol_ldev_id => 200) };
    like($@, qr/not in registry/, 'cannot snapshot nonexistent volume');
};

done_testing();
