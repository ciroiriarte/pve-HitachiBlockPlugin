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
    like($@, qr/port_id is required/, 'add_wwn needs port_id');
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

    eval { $client->get_snapshot() };
    like($@, qr/snapshot_id is required/, 'get_snapshot needs id');

    eval { $client->split_snapshot() };
    like($@, qr/snapshot_id is required/, 'split_snapshot needs id');

    eval { $client->clone_snapshot_to_ldev() };
    like($@, qr/pvol_ldev_id is required/, 'clone_snapshot needs pvol');

    eval { $client->clone_snapshot_to_ldev(pvol_ldev_id => 1) };
    like($@, qr/svol_ldev_id is required/, 'clone_snapshot needs svol');

    eval { $client->clone_snapshot_to_ldev(pvol_ldev_id => 1, svol_ldev_id => 2) };
    like($@, qr/snap_pool_id is required/, 'clone_snapshot needs snap_pool_id');
};

subtest 'qos_operations_require_params' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );

    eval { $client->set_ldev_qos() };
    like($@, qr/ldev_id is required/, 'set_ldev_qos needs ldev_id');

    eval { $client->set_ldev_qos(42) };
    like($@, qr/At least one QoS parameter/, 'set_ldev_qos needs at least one param');

    eval { $client->get_ldev_qos() };
    like($@, qr/ldev_id is required/, 'get_ldev_qos needs ldev_id');
};

subtest 'url_construction' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '836000123456',
        username   => 'admin',
        password   => 'secret',
        port       => 23451,
    );

    my $url = $client->_url('/ldevs/42');
    like($url, qr{https://10\.0\.1\.100:23451/ConfigurationManager/v1/objects/storages/836000123456/ldevs/42}, 'URL constructed correctly');
};

# ── Session-less auth (GitHub #26) ──
# A fake UserAgent records each HTTP::Request and replies with a canned response,
# so we can assert HOW a request authenticates without touching the network.
{
    package FakeUA;
    sub new { bless { reqs => [] }, shift }
    sub request {
        my ($self, $req) = @_;
        push @{ $self->{reqs} }, $req;
        return HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'application/json' ], '{"ok":1}');
    }
}
use HTTP::Response;

subtest 'sessionless_uses_basic_auth_and_creates_no_session' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '836000123456',
        username => 'maint', password => 'pw', sessionless => 1,
    );
    my $ua = FakeUA->new;
    $client->{ua} = $ua;

    # login() must be a no-op in session-less mode (nothing created server-side)
    is($client->login(), undef, 'login() is a no-op in session-less mode');
    is(scalar(@{ $ua->{reqs} }), 0, 'login() issued no HTTP request (no POST /sessions)');

    # an ordinary request authenticates with HTTP basic auth, not a session token
    $client->get_ldev(42);
    is(scalar(@{ $ua->{reqs} }), 1, 'one request issued');
    my $auth = $ua->{reqs}[0]->header('Authorization') // '';
    like($auth, qr/^Basic /, 'request uses HTTP basic auth');
    unlike($auth, qr/Session/, 'no Session token header');
    is($client->{token}, undef, 'no session token stored');
    is($client->{session_id}, undef, 'no session id stored');

    # logout()/keepalive() are also no-ops with no session
    is($client->logout(), undef, 'logout() is a no-op');
    is($client->keepalive(), undef, 'keepalive() is a no-op');
};

subtest 'session_mode_uses_session_token' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '836000123456',
        username => 'maint', password => 'pw',    # sessionless omitted => session mode
    );
    ok(!$client->{sessionless}, 'session mode is off by default at the client layer');
    my $ua = FakeUA->new;
    $client->{ua} = $ua;
    $client->{token} = 'TOK123';                  # simulate an established session

    $client->get_ldev(42);
    is($ua->{reqs}[0]->header('Authorization'), 'Session TOK123',
        'session mode authenticates with the Session token');
};

done_testing();
