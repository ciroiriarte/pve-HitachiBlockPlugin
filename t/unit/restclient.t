#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::HitachiBlock::RestClient;

# Test RestClient construction and parameter validation

subtest 'constructor_requires_params' => sub {
    eval { PVE::Storage::HitachiBlock::RestClient->new() };
    like($@, qr/mgmt_ip is required/, 'missing mgmt_ip');

    eval { PVE::Storage::HitachiBlock::RestClient->new(mgmt_ip => '1.2.3.4') };
    like($@, qr/storage_id is required/, 'missing storage_id');

    eval {
        PVE::Storage::HitachiBlock::RestClient->new(
            mgmt_ip    => '1.2.3.4',
            storage_id => '123',
        );
    };
    like($@, qr/username is required/, 'missing username');

    eval {
        PVE::Storage::HitachiBlock::RestClient->new(
            mgmt_ip    => '1.2.3.4',
            storage_id => '123',
            username   => 'admin',
        );
    };
    like($@, qr/password is required/, 'missing password');
};

subtest 'constructor_success' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '836000123456',
        username   => 'admin',
        password   => 'secret',
        port       => 443,
    );

    isa_ok($client, 'PVE::Storage::HitachiBlock::RestClient');
    is($client->{mgmt_ip}, '10.0.1.100', 'mgmt_ip set');
    is($client->{port}, 443, 'port set');
    like($client->{base_url}, qr{ConfigurationManager/v1/objects/storages/836000123456}, 'base_url');
};

subtest 'constructor_default_port' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    is($client->{port}, 443, 'default port is 443');
};

subtest 'ldev_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->create_ldev() };
    like($@, qr/pool_id is required/, 'create_ldev needs pool_id');

    eval { $client->create_ldev(pool_id => 0) };
    like($@, qr/size_mb is required/, 'create_ldev needs size_mb');

    eval { $client->delete_ldev() };
    like($@, qr/ldev_id is required/, 'delete_ldev needs ldev_id');

    eval { $client->get_ldev() };
    like($@, qr/ldev_id is required/, 'get_ldev needs ldev_id');

    eval { $client->set_ldev_label() };
    like($@, qr/ldev_id is required/, 'set_ldev_label needs ldev_id');

    eval { $client->expand_ldev() };
    like($@, qr/ldev_id is required/, 'expand_ldev needs ldev_id');
};

subtest 'pool_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->get_pool() };
    like($@, qr/pool_id is required/, 'get_pool needs pool_id');
};

subtest 'host_group_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->create_host_group() };
    like($@, qr/port_id is required/, 'create_host_group needs port_id');

    eval { $client->add_wwn_to_host_group() };
    like($@, qr/host_group_id is required/, 'add_wwn needs host_group_id');
};

subtest 'lun_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->map_lun() };
    like($@, qr/port_id is required/, 'map_lun needs port_id');

    eval { $client->unmap_lun() };
    like($@, qr/lun_id is required/, 'unmap_lun needs lun_id');
};

subtest 'snapshot_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->create_snapshot() };
    like($@, qr/pvol_ldev_id is required/, 'create_snapshot needs pvol');

    eval { $client->delete_snapshot() };
    like($@, qr/snapshot_id is required/, 'delete_snapshot needs id');

    eval { $client->restore_snapshot() };
    like($@, qr/snapshot_id is required/, 'restore_snapshot needs id');
};

done_testing();
