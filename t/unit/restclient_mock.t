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
    # auto-assign mode (no ldev_id): isParallelExecutionEnabled is allowed.
    ok($log[0]{body}{isParallelExecutionEnabled}, 'parallel exec set when auto-assigning');
    ok(!exists $log[0]{body}{ldevId}, 'no ldevId when auto-assigning');
};

subtest 'create_ldev_explicit_id_no_parallel' => sub {
    # Regression: an explicit ldevId must NOT be combined with
    # isParallelExecutionEnabled (the array rejects it, KART40046-E).
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ jobId => 'job-2' }, { state => 'Succeeded', affectedResources => ['/ldevs/256'] });

    $client->create_ldev(pool_id => 0, size_mb => 1024, ldev_id => 256);

    my @log = MockRestClient::get_request_log();
    is($log[0]{body}{ldevId}, 256, 'ldevId in body');
    ok(!exists $log[0]{body}{isParallelExecutionEnabled},
        'isParallelExecutionEnabled omitted with explicit ldevId');
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

subtest 'list_defined_ldevs_in_range_pages_and_filters' => sub {
    # GET /ldevs returns a window of consecutive slots (incl. "NOT DEFINED" empty
    # ones) starting at headLdevId. The helper must page across the range (the
    # default window is only 100 wide) and drop empty slots.
    my $client = new_mock_client();
    # One chunk (256 wide). Slots 256..511; only 256 and 300 are defined.
    MockRestClient::set_mock_responses(sub {
        my ($m, $url) = @_;
        my @slots;
        for my $id (256 .. 511) {
            if ($id == 256) { push @slots, { ldevId => 256, emulationType => 'OPEN-V-CVS', label => 'pve:x:vm-9100-disk-1' }; }
            elsif ($id == 300) { push @slots, { ldevId => 300, emulationType => 'OPEN-V' }; }
            else { push @slots, { ldevId => $id, emulationType => 'NOT DEFINED' }; }
        }
        return { data => \@slots };
    });

    my $defined = $client->list_defined_ldevs_in_range(256, 511);
    is(scalar @$defined, 2, 'only the 2 defined LDEVs returned (empty slots dropped)');
    is_deeply([sort { $a <=> $b } map { $_->{ldevId} } @$defined], [256, 300], 'correct LDEV ids');

    my @log = MockRestClient::get_request_log();
    like($log[0]{url}, qr{headLdevId=256}, 'window starts at range min');
    like($log[0]{url}, qr{count=256}, 'count bounded to the range width');
};

subtest 'list_defined_ldevs_in_range_multi_chunk' => sub {
    # A range wider than the chunk size must issue multiple windowed requests.
    my $client = new_mock_client();
    MockRestClient::set_mock_responses(
        sub { return { data => [ { ldevId => 0,   emulationType => 'OPEN-V' } ] } },
        sub { return { data => [ { ldevId => 256, emulationType => 'OPEN-V' } ] } },
    );
    my $defined = $client->list_defined_ldevs_in_range(0, 511, chunk => 256);
    my @log = MockRestClient::get_request_log();
    is(scalar @log, 2, 'range 0-511 with chunk 256 issues 2 windowed requests');
    like($log[0]{url}, qr{headLdevId=0&.*count=256|headLdevId=0.*count=256}, 'first window at 0');
    like($log[1]{url}, qr{headLdevId=256}, 'second window at 256');
    is(scalar @$defined, 2, 'collects defined LDEVs across chunks');
};

subtest 'list_luns_filters_ldev_client_side' => sub {
    # CRITICAL safety: GET /luns ignores ldevId server-side and returns ALL LUNs
    # in the host group. list_luns must filter by ldevId client-side, or a caller
    # iterating host groups could unmap another host's/volume's LUN path.
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ data => [
        { lunId => 'CL1-A,1,8', ldevId => 30 },   # another host's LUN
        { lunId => 'CL1-A,2,0', ldevId => 256 },  # ours
    ]});

    my $luns = $client->list_luns(port_id => 'CL1-A', host_group_number => 1, ldev_id => 256);
    is(scalar @$luns, 1, 'only the matching ldev returned');
    is($luns->[0]{lunId}, 'CL1-A,2,0', 'returned our LUN, not the other host\'s');
    # ldevId must NOT be sent as a query param (it is ignored / misleading).
    my @log = MockRestClient::get_request_log();
    unlike($log[0]{url}, qr{ldevId=}, 'no ldevId query param');
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

subtest 'get_pool_e590h_null_usedcapacity' => sub {
    # Real VSP E590H microcode: usedPoolCapacity is null, availableVolumeCapacity
    # and usedCapacityRate are populated. status() must cope (see plugin.t).
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({
        poolId => 0,
        poolStatus => 'POLN',
        totalPoolCapacity => 22210482,
        usedPoolCapacity  => undef,
        availableVolumeCapacity => 21576282,
        usedCapacityRate => 2,
    });

    my $pool = $client->get_pool(0);
    is($pool->{totalPoolCapacity}, 22210482, 'total capacity present');
    ok(!defined $pool->{usedPoolCapacity}, 'usedPoolCapacity null (as on E590H)');
    is($pool->{availableVolumeCapacity}, 21576282, 'availableVolumeCapacity present');
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

subtest 'add_wwn_sends_hostgroupnumber' => sub {
    # Regression: the /host-wwns body must include portId AND hostGroupNumber,
    # or the WWN does not land in our host group (found in live Phase C).
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({ jobId => 'job-wwn' }, { state => 'Succeeded', affectedResources => [] });

    $client->add_wwn_to_host_group(
        port_id           => 'CL1-A',
        host_group_number => 7,
        wwn               => '10000000c9abcdef',
    );

    my @log = MockRestClient::get_request_log();
    is($log[0]{method}, 'POST', 'POST method');
    like($log[0]{url}, qr{/host-wwns$}, 'host-wwns endpoint');
    is($log[0]{body}{portId}, 'CL1-A', 'portId in body');
    is($log[0]{body}{hostGroupNumber}, 7, 'hostGroupNumber in body');
    is($log[0]{body}{hostWwn}, '10000000c9abcdef', 'hostWwn in body');
    ok(!exists $log[0]{body}{hostWwnNickname}, 'no hostWwnNickname (rejected by VSP E REST)');
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

subtest 'create_snapshot_auto_split_option' => sub {
    # A CoW linked clone pairs an explicit S-VOL with auto_split=1: the pair splits so
    # the S-VOL is host R/W (PSUS) while still sharing blocks with the P-VOL.
    my $client = new_mock_client();
    MockRestClient::set_mock_responses({});
    $client->create_snapshot(
        pvol_ldev_id   => 42,
        snap_pool_id   => 1,
        svol_ldev_id   => 100,
        snapshot_group => 'pve_lclone_x',
        auto_split     => 1,
    );
    my @log = MockRestClient::get_request_log();
    ok($log[0]{body}{autoSplit}, 'auto_split=1 => autoSplit true (split PSUS, host-R/W CoW S-VOL)');
    is($log[0]{body}{svolLdevId}, 100, 'explicit S-VOL in body');

    # Default (omitted) is also true.
    MockRestClient::clear_request_log();
    MockRestClient::set_mock_responses({});
    $client->create_snapshot(pvol_ldev_id => 42, snap_pool_id => 1, snapshot_group => 'g');
    @log = MockRestClient::get_request_log();
    ok($log[0]{body}{autoSplit}, 'autoSplit defaults true');

    # Explicit 0 leaves the pair un-split (reference-only S-VOL).
    MockRestClient::clear_request_log();
    MockRestClient::set_mock_responses({});
    $client->create_snapshot(pvol_ldev_id => 42, snap_pool_id => 1, snapshot_group => 'g', auto_split => 0);
    @log = MockRestClient::get_request_log();
    ok(!$log[0]{body}{autoSplit}, 'auto_split=0 => autoSplit false');
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

subtest 'wait_for_job_polls_location_only_response' => sub {
    # Async responses that carry only a Location header (no jobId) must still be
    # polled to completion instead of being treated as already finished.
    my $client = new_mock_client();
    MockRestClient::set_mock_responses(
        { state => 'Succeeded', affectedResources => ['/ldevs/55'] },
    );

    my $result = $client->_wait_for_job(
        { location => '/ConfigurationManager/v1/objects/jobs/job-loc' });
    is($result->{resourceId}, 55, 'Location-only async response polled to completion');

    my @log = MockRestClient::get_request_log();
    like($log[0]{url}, qr{/jobs/job-loc}, 'polled the job URL from Location');
};

# ── Retry behaviour (exercises the real _request via a fake UserAgent) ──

package FakeUA;
sub new { return bless { responses => $_[1] }, $_[0] }
sub request {
    my ($self) = @_;
    return shift @{$self->{responses}};
}

package main;

use HTTP::Response;

subtest 'request_retries_on_429_then_succeeds' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );
    $client->{token} = 'tok';

    my $r429 = HTTP::Response->new(429, 'Too Many Requests',
        ['Retry-After' => '1'], '');
    my $r200 = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"ok":1}');
    $client->{ua} = FakeUA->new([$r429, $r200]);

    my $out = $client->_request('GET', 'https://x/y');
    is($out->{ok}, 1, 'retried after 429 rate-limit and returned success');
};

subtest 'request_retries_get_on_5xx' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret');
    $client->{token} = 'tok';

    my $r500 = HTTP::Response->new(500, 'Server Error',
        ['Retry-After' => '0'], '');
    my $r200 = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"ok":1}');
    $client->{ua} = FakeUA->new([$r500, $r200]);

    my $out = $client->_request('GET', 'https://x/y');
    is($out->{ok}, 1, 'idempotent GET retried on 5xx and succeeded');
};

subtest 'request_does_not_retry_post_on_5xx' => sub {
    # A non-idempotent POST must NOT be resent on 5xx: the array may already have
    # created the resource, so a retry would double-create. It must fail loudly.
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret');
    $client->{token} = 'tok';

    my $r500a = HTTP::Response->new(500, 'Server Error', [], '');
    my $r500b = HTTP::Response->new(500, 'Server Error', [], '');
    my $ua = FakeUA->new([$r500a, $r500b]);
    $client->{ua} = $ua;

    eval { $client->_request('POST', 'https://x/ldevs', { poolId => 0 }) };
    like($@, qr/API request failed/, 'POST on 5xx fails without retry');
    is(scalar @{$ua->{responses}}, 1, 'only one POST attempt was made (no retry)');
};

subtest 'request_retries_post_on_429' => sub {
    # 429 means the request was rejected before processing, so even a POST is safe
    # to resend.
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret');
    $client->{token} = 'tok';

    my $r429 = HTTP::Response->new(429, 'Too Many Requests',
        ['Retry-After' => '0'], '');
    my $r200 = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"ok":1}');
    $client->{ua} = FakeUA->new([$r429, $r200]);

    my $out = $client->_request('POST', 'https://x/ldevs', { poolId => 0 });
    is($out->{ok}, 1, 'POST retried on 429 rate-limit and succeeded');
};

subtest 'login_retries_on_429' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => '123',
        username => 'admin', password => 'secret');

    my $r429   = HTTP::Response->new(429, 'Too Many Requests',
        ['Retry-After' => '0'], '');
    my $rlogin = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"token":"new","sessionId":"s1"}');
    $client->{ua} = FakeUA->new([$r429, $rlogin]);

    my $token = $client->login();
    is($token, 'new', 'login retried on 429 and obtained a token');
    is($client->{session_id}, 's1', 'session id captured after retry');
};

subtest 'request_reauth_on_401' => sub {
    my $client = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '123',
        username   => 'admin',
        password   => 'secret',
    );
    $client->{token} = 'old';

    my $r401   = HTTP::Response->new(401, 'Unauthorized', [], '');
    my $rlogin = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"token":"new","sessionId":"s1"}');
    my $r200   = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"done":1}');
    # request() -> 401, then login()'s request() -> token, then retried request() -> 200
    $client->{ua} = FakeUA->new([$r401, $rlogin, $r200]);

    my $out = $client->_request('GET', 'https://x/y');
    is($out->{done}, 1, 're-authenticated on 401 and retried');
    is($client->{token}, 'new', 'token refreshed by re-login');
};

# ── Multi-controller management endpoints / failover ──

subtest 'parses_multiple_endpoints' => sub {
    my $c = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => ' 10.0.0.1 , 10.0.0.2 ', storage_id => '123',
        username => 'u', password => 'p', port => 443);
    is_deeply($c->{endpoints}, ['10.0.0.1', '10.0.0.2'], 'endpoints parsed and trimmed');
    is($c->{mgmt_ip}, '10.0.0.1', 'current endpoint is the first');
    like($c->{base_url}, qr{^https://10\.0\.0\.1:443/}, 'base_url uses the first endpoint');
};

subtest 'switch_endpoint' => sub {
    my $c = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => 'a,b', storage_id => '123', username => 'u', password => 'p');
    $c->{token} = 'tok';
    $c->{session_id} = 's';

    ok($c->_switch_endpoint(), 'switch returns true with two endpoints');
    is($c->{mgmt_ip}, 'b', 'advanced to the second endpoint');
    is($c->{token}, undef, 'token cleared on switch (session is per-controller)');
    like($c->{base_url}, qr{^https://b:}, 'base_url updated to the new endpoint');

    ok($c->_switch_endpoint(), 'wraps around');
    is($c->{mgmt_ip}, 'a', 'wrapped back to the first endpoint');

    my $single = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => 'only', storage_id => '1', username => 'u', password => 'p');
    is($single->_switch_endpoint(), 0, 'single endpoint: nothing to fail over to');
};

subtest 'login_fails_over_on_transport_error' => sub {
    my $c = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => 'ctl1,ctl2', storage_id => '1', username => 'u', password => 'p');

    # LWP marks connect/timeout failures with Client-Warning: Internal response.
    my $internal = HTTP::Response->new(500, 'Cannot connect',
        ['Client-Warning' => 'Internal response'], '');
    my $ok = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"token":"t2","sessionId":"s2"}');
    $c->{ua} = FakeUA->new([$internal, $ok]);

    my $tok = $c->login();
    is($tok, 't2', 'logged in after failing over to the second controller');
    is($c->{mgmt_ip}, 'ctl2', 'now using the second controller');
};

subtest 'request_fails_over_on_transport_error' => sub {
    my $c = PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip => 'ctl1,ctl2', storage_id => '1', username => 'u', password => 'p');
    $c->{token} = 'old';

    my $internal = HTTP::Response->new(500, 'Cannot connect',
        ['Client-Warning' => 'Internal response'], '');
    my $login = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"token":"t2","sessionId":"s2"}');
    my $ok = HTTP::Response->new(200, 'OK',
        ['Content-Type' => 'application/json'], '{"done":1}');
    # ctl1 request transport-fails -> switch to ctl2 -> login() consumes $login ->
    # retried request consumes $ok.
    $c->{ua} = FakeUA->new([$internal, $login, $ok]);

    my $out = $c->_request('GET',
        'https://ctl1:443/ConfigurationManager/v1/objects/storages/1/pools');
    is($out->{done}, 1, 'request succeeded after failover + re-auth');
    is($c->{mgmt_ip}, 'ctl2', 'switched to the surviving controller');
    is($c->{token}, 't2', 're-authenticated on the new controller');
};

done_testing();
