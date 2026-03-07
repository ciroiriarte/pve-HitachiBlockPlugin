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

done_testing();
