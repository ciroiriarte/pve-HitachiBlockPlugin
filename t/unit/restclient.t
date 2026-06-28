#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use JSON qw(decode_json);

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

# ── Retry backoff jitter (#11) ──
# Minimal response stub exposing header('Retry-After').
{
    package FakeResp;
    sub new { my ($c, $ra) = @_; return bless { ra => $ra }, $c }
    sub header { my ($self, $h) = @_; return $h eq 'Retry-After' ? $self->{ra} : undef }
}

subtest 'retry_delay_jitter' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret',
    );

    my $RETRY_DELAY = 2;   # mirrors the module constant

    # Jitter: many samples at the same attempt must NOT all be equal, and each must
    # fall within [base, base + RETRY_DELAY) — base + a random fraction of the interval.
    for my $attempt (1, 2, 3) {
        my $base = $RETRY_DELAY * $attempt;
        my %seen;
        my $within = 1;
        for (1 .. 200) {
            my $d = $client->_retry_delay($attempt, undef);
            $seen{$d} = 1;
            $within = 0 if $d < $base || $d >= $base + $RETRY_DELAY;
        }
        ok($within, "attempt $attempt: every delay in [$base, " . ($base + $RETRY_DELAY) . ")");
        ok(scalar(keys %seen) > 1, "attempt $attempt: delays are non-constant (jitter present)");
    }

    # Monotonic base across attempts: later attempts wait at least as long (minus
    # jitter overlap) — the floor of attempt N+1 >= floor of attempt N.
    # Retry-After (numeric) takes precedence and is honored exactly, no jitter.
    is($client->_retry_delay(1, FakeResp->new('17')), 17,
        'numeric Retry-After is honored exactly (takes precedence over jitter)');
    is($client->_retry_delay(3, FakeResp->new('5')), 5,
        'Retry-After wins even when smaller than the computed backoff');

    # Non-numeric / absent Retry-After falls through to jittered backoff (bounded).
    my $d = $client->_retry_delay(1, FakeResp->new('Wed, 21 Oct 2026 07:28:00 GMT'));
    ok($d >= 2 && $d < 4, 'non-numeric Retry-After ignored -> jittered backoff used');

    # Cap: a very high attempt is clamped to the max.
    ok($client->_retry_delay(1000, undef) <= 30, 'delay is capped at RETRY_MAX_DELAY');
};

# ── REST response-time accumulation (#18 diag bundle) ──
subtest 'rest_timing_stats' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret',
    );

    is($client->rest_timing_stats(), undef, 'no stats before any request');

    $client->_record_rest_timing('GET', 'https://x/v1/objects/pools/0', 0.10);
    $client->_record_rest_timing('POST', 'https://x/v1/objects/ldevs',  0.50);
    $client->_record_rest_timing('GET', 'https://x/v1/objects/pools/1', 0.20);

    my $s = $client->rest_timing_stats();
    is($s->{count}, 3, 'counts every request');
    cmp_ok(abs($s->{avg} - 0.2666667), '<', 0.0001, 'average across calls');
    cmp_ok($s->{max}, '==', 0.50, 'tracks the slowest call');
    is($s->{slowest}, 'POST /ldevs', 'slowest records method + bare API path');
    is($s->{last}, 0.20, 'last records the most recent call');
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
    like($@, qr/size_mb or block_capacity is required/, 'create_ldev needs a size');

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

# ── Linked-clone workflow primitives (GitHub #24/#20) ──

subtest 'create_ldev_thin_image_vvol_and_block_capacity' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '836000123456',
        username => 'maint', password => 'pw', sessionless => 1,
    );
    $client->{ua} = FakeUA->new;

    # Thin Image S-VOL: poolId -1, exact block count, explicit in-range id.
    $client->create_ldev(pool_id => -1, block_capacity => 98304, ldev_id => 262);
    my $body = decode_json($client->{ua}{reqs}[-1]->content);
    is($body->{poolId}, -1, 'poolId -1 = Thin Image virtual volume');
    is($body->{blockCapacity}, 98304, 'exact blockCapacity sent');
    is($body->{ldevId}, 262, 'explicit in-range ldevId (so the teardown fence accepts it)');
    ok(!exists $body->{byteFormatCapacity}, 'no byteFormatCapacity when block_capacity given');
    ok(!exists $body->{isParallelExecutionEnabled}, 'no auto-assign when ldevId is explicit');

    # Regular DP volume path still uses byteFormatCapacity.
    $client->create_ldev(pool_id => 1, size_mb => 60);
    my $b2 = decode_json($client->{ua}{reqs}[-1]->content);
    is($b2->{byteFormatCapacity}, '60M', 'byteFormatCapacity used without block_capacity');
};

subtest 'assign_snapshot_volume' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '836000123456',
        username => 'maint', password => 'pw', sessionless => 1,
    );
    $client->{ua} = FakeUA->new;

    eval { $client->assign_snapshot_volume() };
    like($@, qr/snapshot_id is required/, 'needs snapshot_id');
    eval { $client->assign_snapshot_volume('256,3') };
    like($@, qr/svol_ldev_id is required/, 'needs svol_ldev_id');

    $client->assign_snapshot_volume('256,3', 262);
    my $req = $client->{ua}{reqs}[-1];
    like($req->uri, qr{/snapshots/256,3/actions/assign-volume/invoke},
        'assign-volume action on the literal-comma snapshotId');
    is(decode_json($req->content)->{parameters}{svolLdevId}, 262,
        'svolLdevId in parameters');
};

done_testing();
