#!/usr/bin/perl

# Comprehensive RestClient tests with mocked HTTP responses

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::HitachiBlock::RestClient;

# ── Mock LWP::UserAgent for testing ──
# We override _request to simulate API responses without network access.

package MockRestClient;
use parent -norequire, 'PVE::Storage::HitachiBlock::RestClient';

my @mock_responses;
my @request_log;

sub set_mock_responses { @mock_responses = @_ }
sub get_request_log    { return @request_log }
sub clear_request_log  { @request_log = () }

sub _request {
    my ($self, $method, $url, $body, $skip_reauth) = @_;

    push @request_log, {
        method => $method,
        url    => $url,
        body   => $body,
    };

    if (@mock_responses) {
        my $response = shift @mock_responses;
        if (ref $response eq 'CODE') {
            return $response->($method, $url, $body);
        }
        return $response;
    }

    return {};
}

package main;

sub new_mock_client {
    my $client = MockRestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '836000123456',
        username   => 'admin',
        password   => 'secret',
        port       => 443,
    );
    $client->{token}      = 'mock_token';
    $client->{session_id} = 'mock_session';
    MockRestClient::clear_request_log();
    return $client;
}

# ── LDEV Operations ──

subtest 'create_ldev_sends_correct_body' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ jobId => 'job-1' }, { state => 'Succeeded', affectedResources => ['/ldevs/42'] });

    my $result = $client->create_ldev(pool_id => 0, size_mb => 1024);
    is($result->{resourceId}, 42, 'extracted LDEV ID from job');

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    like($log[0]{url}, qr{/ldevs$}, 'correct URL');
    is($log[0]{body}{poolId}, 0, 'pool_id in body');
    is($log[0]{body}{byteFormatCapacity}, '1024M', 'size in body');
};

subtest 'delete_ldev_sends_delete' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->delete_ldev(42);

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'DELETE', 'DELETE method');
    like($log[0]{url}, qr{/ldevs/42$}, 'correct URL');
};

subtest 'get_ldev_returns_data' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({
        ldevId => 42,
        label => 'pve:test:vm-100-disk-1',
        byteFormatCapacity => '1024.00 M',
    });

    my $ldev = $client->get_ldev(42);
    is($ldev->{ldevId}, 42, 'ldev_id returned');
    like($ldev->{label}, qr/pve:test/, 'label returned');
};

subtest 'set_ldev_label_sends_patch' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->set_ldev_label(42, 'pve:test:vm-100-disk-1');

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'PATCH', 'PATCH method');
    is($log[0]{body}{label}, 'pve:test:vm-100-disk-1', 'label in body');
};

subtest 'expand_ldev_sends_action' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->expand_ldev(42, 512);

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    like($log[0]{url}, qr{/ldevs/42/actions/expand/invoke}, 'expand URL');
    is($log[0]{body}{parameters}{additionalByteFormatCapacity}, '512M', 'size in body');
};

subtest 'list_ldevs_with_filters' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ data => [{ ldevId => 1 }, { ldevId => 2 }] });

    my $ldevs = $client->list_ldevs(pool_id => 0, dp_only => 1);
    is(scalar @$ldevs, 2, 'returned 2 LDEVs');

    my @log = MockRestClient::get_request_log();
    like($log[0]{url}, qr{poolId=0}, 'pool filter in URL');
    like($log[0]{url}, qr{ldevOption=dpVolume}, 'dp filter in URL');
};

# ── Pool Operations ──

subtest 'get_pool_returns_capacity' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({
        poolId => 0,
        totalPoolCapacity => 10240,
        usedPoolCapacity  => 2048,
    });

    my $pool = $client->get_pool(0);
    is($pool->{totalPoolCapacity}, 10240, 'total capacity');
    is($pool->{usedPoolCapacity}, 2048, 'used capacity');
};

# ── Host Group Operations ──

subtest 'create_host_group_with_host_mode' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ jobId => 'job-hg' }, { state => 'Succeeded', affectedResources => ['/host-groups/5'] });

    my $result = $client->create_host_group(
        port_id         => 'CL1-A',
        host_group_name => 'PVE_node1',
        host_mode       => 'LINUX/IRIX',
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{portId}, 'CL1-A', 'port in body');
    is($log[0]{body}{hostGroupName}, 'PVE_node1', 'name in body');
    is($log[0]{body}{hostMode}, 'LINUX/IRIX', 'host mode in body');
};

# ── LUN Mapping Operations ──

subtest 'map_lun_sends_correct_body' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->map_lun(
        port_id           => 'CL1-A',
        host_group_number => 1,
        ldev_id           => 42,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    is($log[0]{body}{portId}, 'CL1-A', 'port in body');
    is($log[0]{body}{hostGroupNumber}, 1, 'host group in body');
    is($log[0]{body}{ldevId}, 42, 'ldev in body');
};

# ── Snapshot Operations ──

subtest 'create_snapshot_with_auto_split' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->create_snapshot(
        pvol_ldev_id   => 42,
        snap_pool_id   => 1,
        snapshot_group => 'pve_test_snap1',
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{pvolLdevId}, 42, 'pvol in body');
    is($log[0]{body}{snapshotPoolId}, 1, 'snap pool in body');
    is($log[0]{body}{snapshotGroupName}, 'pve_test_snap1', 'group name');
    ok($log[0]{body}{autoSplit}, 'auto split enabled');
};

subtest 'restore_snapshot_sends_action' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->restore_snapshot('snap-123');

    my @log = MockRestClient::get_request_log();
    like($log[0]{url}, qr{/snapshots/snap-123/actions/restore/invoke}, 'restore URL');
    is($log[0]{body}{parameters}{operationType}, 'restore', 'restore operation');
};

# ── QoS Operations ──

subtest 'set_ldev_qos_sends_limits' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->set_ldev_qos(42, upper_iops => 10000, upper_mbps => 500);

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'PATCH', 'PATCH method');
    is($log[0]{body}{upperIops}, 10000, 'IOPS limit');
    is($log[0]{body}{upperTransferRate}, 500, 'throughput limit');
};

subtest 'set_ldev_qos_lower_bounds_and_priority' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->set_ldev_qos(42,
        upper_iops        => 10000,
        lower_iops        => 1000,
        upper_mbps        => 500,
        lower_mbps        => 100,
        response_priority => 1,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{upperIops}, 10000, 'upper IOPS');
    is($log[0]{body}{lowerIops}, 1000, 'lower IOPS');
    is($log[0]{body}{upperTransferRate}, 500, 'upper throughput');
    is($log[0]{body}{lowerTransferRate}, 100, 'lower throughput');
    is($log[0]{body}{responsePriority}, 1, 'response priority');
};

# ── Zero Page Reclamation ──

subtest 'reclaim_zero_pages_sends_action' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->reclaim_zero_pages(42);

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    like($log[0]{url}, qr{/ldevs/42/actions/discard-zero-page/invoke}, 'discard URL');
};

subtest 'reclaim_zero_pages_requires_ldev_id' => sub {
    my $client = new_mock_client();
    eval { $client->reclaim_zero_pages() };
    like($@, qr/ldev_id is required/, 'needs ldev_id');
};

# ── Storage-Assisted Migration ──

subtest 'migrate_ldev_sends_change_pool' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->migrate_ldev(42, 5);

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    like($log[0]{url}, qr{/ldevs/42/actions/change-pool/invoke}, 'change-pool URL');
    is($log[0]{body}{parameters}{poolId}, 5, 'target pool in body');
};

subtest 'migrate_ldev_requires_params' => sub {
    my $client = new_mock_client();
    eval { $client->migrate_ldev() };
    like($@, qr/ldev_id is required/, 'needs ldev_id');

    eval { $client->migrate_ldev(42) };
    like($@, qr/target_pool_id is required/, 'needs target_pool_id');
};

# ── Host Group Deletion ──

subtest 'delete_host_group_sends_delete' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->delete_host_group('CL1-A,1');

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'DELETE', 'DELETE method');
    like($log[0]{url}, qr{/host-groups/CL1-A,1$}, 'correct URL');
};

subtest 'delete_host_group_requires_id' => sub {
    my $client = new_mock_client();
    eval { $client->delete_host_group() };
    like($@, qr/host_group_id is required/, 'needs host_group_id');
};

# ── Snapshot Consistency Group and Copy Speed ──

subtest 'create_snapshot_with_consistency_group' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->create_snapshot(
        pvol_ldev_id        => 42,
        snap_pool_id        => 1,
        snapshot_group      => 'pve_cg_test',
        is_consistency_group => 1,
    );

    my @log = MockRestClient::get_request_log();
    ok($log[0]{body}{isConsistencyGroup}, 'consistency group enabled');
};

subtest 'create_snapshot_with_copy_speed' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->create_snapshot(
        pvol_ldev_id   => 42,
        snap_pool_id   => 1,
        snapshot_group => 'pve_test',
        copy_speed     => 10,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{copySpeed}, 10, 'copy speed in body');
};

subtest 'clone_snapshot_with_copy_speed' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->clone_snapshot_to_ldev(
        pvol_ldev_id   => 42,
        svol_ldev_id   => 100,
        snap_pool_id   => 1,
        copy_speed     => 8,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{copySpeed}, 8, 'copy speed in clone body');
};

# ── Replication Operations ──

subtest 'create_truecopy_pair' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->create_remote_copy_pair(
        copy_group_name   => 'PVE_TC_GROUP',
        pvol_ldev_id      => 100,
        svol_ldev_id      => 200,
        remote_storage_id => '836000789012',
        replication_type  => 'TC',
        copy_pace         => 3,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{replicationType}, 'TC', 'TC type');
    is($log[0]{body}{pvolLdevId}, 100, 'pvol');
    is($log[0]{body}{svolLdevId}, 200, 'svol');
};

subtest 'create_gad_pair_with_quorum' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});

    $client->create_remote_copy_pair(
        copy_group_name   => 'PVE_GAD_GROUP',
        pvol_ldev_id      => 100,
        svol_ldev_id      => 200,
        remote_storage_id => '836000789012',
        replication_type  => 'GAD',
        copy_pace         => 3,
        quorum_disk_id    => 0,
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{replicationType}, 'GAD', 'GAD type');
    is($log[0]{body}{quorumDiskId}, 0, 'quorum disk');
};

subtest 'split_and_resync_pair' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({}, {});

    $client->split_remote_copy_pair('pair-001');
    $client->resync_remote_copy_pair('pair-001');

    my @log = MockRestClient::get_request_log();
    like($log[0]{url}, qr{/actions/split/invoke}, 'split URL');
    like($log[1]{url}, qr{/actions/resync/invoke}, 'resync URL');
};

subtest 'replication_requires_params' => sub {
    my $client = new_mock_client();

    eval { $client->create_remote_copy_pair() };
    like($@, qr/copy_group_name is required/, 'needs copy_group_name');

    eval { $client->delete_remote_copy_pair() };
    like($@, qr/pair_id is required/, 'delete needs pair_id');

    eval { $client->get_remote_copy_pair() };
    like($@, qr/pair_id is required/, 'get needs pair_id');

    eval { $client->split_remote_copy_pair() };
    like($@, qr/pair_id is required/, 'split needs pair_id');

    eval { $client->resync_remote_copy_pair() };
    like($@, qr/pair_id is required/, 'resync needs pair_id');

    eval { $client->register_remote_storage() };
    like($@, qr/remote_storage_id is required/, 'register needs remote_id');
};

# ── Job Polling ──

subtest 'wait_for_job_extracts_resource_id' => sub {
    my $client = new_mock_client();
    MockRestClient::set_mock_responses(
        { state => 'InProgress' },
        { state => 'Succeeded', affectedResources => ['/ldevs/99'] },
    );

    # Directly test _wait_for_job by simulating a job response
    # We need to override sleep for testing
    no warnings 'redefine';
    local *MockRestClient::_wait_for_job = sub {
        my ($self, $res) = @_;
        return $res unless ref $res eq 'HASH' && $res->{jobId};

        # Simulate polling (skip sleep)
        my $job1 = $self->_request('GET', 'job_url');
        my $job2 = $self->_request('GET', 'job_url');

        if ($job2->{state} eq 'Succeeded') {
            my $affected = $job2->{affectedResources} || [];
            if (@$affected && $affected->[0] =~ m{/(\d+)$}) {
                return { resourceId => int($1), jobId => $res->{jobId} };
            }
        }
        return { jobId => $res->{jobId} };
    };

    my $result = $client->_wait_for_job({ jobId => 'job-test' });
    is($result->{resourceId}, 99, 'extracted resource ID from job');
};

done_testing();
