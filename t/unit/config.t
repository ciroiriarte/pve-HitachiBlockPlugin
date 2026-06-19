#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use JSON qw(decode_json);
use POSIX ();

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
    is($vsp_g->{port}, 23451, 'VSP G default port (Ops Center CM server)');

    my $vsp_e = PVE::Storage::HitachiBlock::Config->platform_defaults('vsp_e');
    is($vsp_e->{port}, 443, 'VSP E (e.g. E590H) direct/embedded REST port');

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

    # mgmt_ip accepts a comma-separated list of per-controller endpoints.
    ok(PVE::Storage::HitachiBlock::Config->validate_config(
        { %$valid, mgmt_ip => '10.0.1.100, 10.0.1.101' }),
       'comma-separated mgmt_ip list is valid');

    eval { PVE::Storage::HitachiBlock::Config->validate_config(
        { %$valid, mgmt_ip => '10.0.1.100, bad host!' }) };
    like($@, qr/is not a valid IP address or hostname/, 'invalid endpoint in list caught');
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

# ── Label Length Safety ──

subtest 'label_prefix_and_length' => sub {
    # Short storeid keeps the readable prefix.
    is(PVE::Storage::HitachiBlock::Config->label_prefix('myarray'),
       'pve:myarray:', 'short storeid keeps readable prefix');

    # Long storeid is hashed so labels stay within the 32-char array limit.
    my $long = 'hitachi-vsp-prod-datacenter-01';
    my $prefix = PVE::Storage::HitachiBlock::Config->label_prefix($long);
    like($prefix, qr/^pve:[0-9a-f]{8}:$/, 'long storeid hashed into prefix');

    my $label = PVE::Storage::HitachiBlock::Config->make_label($long, 'vm-999999999-disk-99');
    ok(length($label) <= 32, "label fits 32 chars (got " . length($label) . ")");

    # Prefix is stable for the same storeid (orphan detection relies on this).
    is(PVE::Storage::HitachiBlock::Config->label_prefix($long), $prefix,
       'hashed prefix is stable');
};

# ── Name Reservation / Rename / Dependents ──

subtest 'reserve_rename_dependents' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/r.json" };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');

    my $n1 = $config->reserve_volname(100);
    is($n1, 'vm-100-disk-1', 'first reservation');
    my $n2 = $config->reserve_volname(100);
    is($n2, 'vm-100-disk-2', 'second reservation is unique (not reusing reserved name)');

    # Reservations are placeholders without an ldev_id.
    my $entry = $config->lookup_ldev($n1);
    is($entry, undef, 'reservation has no ldev_id');

    # Base reservation shares the disk-index space with vm- names.
    my $b = $config->reserve_volname(100, base => 1);
    is($b, 'base-100-disk-3', 'base reservation continues the disk sequence');

    # Finalize one reservation, then test dependents.
    $config->register_ldev('vm-100-disk-1', 42, size_mb => 1024);
    $config->register_ldev('vm-100-disk-9', 50, size_mb => 1024, parent_volname => 'vm-100-disk-1');

    my $deps = $config->find_dependents('vm-100-disk-1');
    is_deeply([sort @$deps], ['vm-100-disk-9'], 'linked clone listed as dependent');
    is_deeply($config->find_dependents('vm-100-disk-9'), [], 'leaf has no dependents');

    # Rename (create_base path).
    $config->rename_volume('vm-100-disk-1', 'base-100-disk-1');
    is($config->lookup_ldev('base-100-disk-1'), 42, 'renamed entry keeps ldev_id');
    is($config->lookup_ldev('vm-100-disk-1'), undef, 'old name gone after rename');

    eval { $config->rename_volume('does-not-exist', 'x') };
    like($@, qr/not in registry/, 'rename of missing volume fails');
};

# ── Register Merge Preserves Snapshots ──

subtest 'register_preserves_snapshots' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/m.json" };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    $config->register_ldev('vm-1-disk-1', 10, size_mb => 100);
    $config->register_snapshot('vm-1-disk-1', 'snap1', svol_ldev_id => 11);

    # Re-register (e.g. resize) must not drop snapshot metadata.
    $config->register_ldev('vm-1-disk-1', 10, size_mb => 200);
    my $snap = $config->lookup_snapshot('vm-1-disk-1', 'snap1');
    ok($snap, 'snapshot survives re-register');
    is($snap->{svol_ldev_id}, 11, 'snapshot data intact');
    my (undef, $meta) = $config->lookup_ldev('vm-1-disk-1');
    is($meta->{size_mb}, 200, 'size updated by re-register');
};

# ── Corruption Handling ──

subtest 'corrupt_registry_croaks' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/c.json" };

    open(my $fh, '>', "$tmpdir/c.json") or die;
    print $fh "{ this is not valid json ";
    close($fh);

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    eval { $config->load_registry() };
    like($@, qr/corrupt/, 'corrupt registry is detected, not silently treated as empty');
};

# ── Concurrency: no lost updates ──

subtest 'concurrent_registration_no_lost_updates' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $regfile = "$tmpdir/conc.json";
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { $regfile };

    my $workers = 8;
    my $per     = 25;
    my @pids;
    for my $w (0 .. $workers - 1) {
        my $pid = fork();
        die "fork failed" unless defined $pid;
        if ($pid == 0) {
            # Child: register a disjoint set of volumes.
            my $cfg = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
            for my $i (0 .. $per - 1) {
                my $id = $w * $per + $i;
                $cfg->register_ldev("vm-$w-disk-$i", $id, size_mb => 1);
            }
            POSIX::_exit(0);
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    my $reg = $config->load_registry();
    is(scalar(keys %$reg), $workers * $per,
       "all " . ($workers * $per) . " concurrent registrations survived (no lost updates)");
};

# ── Registry Identity Enforcement ──

subtest 'register_ldev_rejects_retarget' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/id.json" };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    $config->register_ldev('vm-1-disk-1', 10, size_mb => 100);

    # Re-registering the same ldev_id (resize/pool change) is allowed.
    ok(eval { $config->register_ldev('vm-1-disk-1', 10, size_mb => 200); 1 },
       'same ldev_id re-register allowed');

    # Retargeting a committed volname to a different LDEV is refused.
    eval { $config->register_ldev('vm-1-disk-1', 99, size_mb => 200) };
    like($@, qr/Registry conflict/, 'retarget to different LDEV refused');

    my ($id) = $config->lookup_ldev('vm-1-disk-1');
    is($id, 10, 'original ldev_id preserved after refused retarget');
};

subtest 'find_volname_by_ldev' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/byldev.json" };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    $config->register_ldev('vm-1-disk-1', 10, size_mb => 100);
    $config->register_ldev('vm-2-disk-1', 20, size_mb => 100);

    is($config->find_volname_by_ldev(20), 'vm-2-disk-1', 'finds volname owning an LDEV');
    is($config->find_volname_by_ldev(999), undef, 'unmapped LDEV returns undef');
};

subtest 'find_snapshot_dependents' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/snapdep.json" };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'test');
    $config->register_ldev('vm-1-disk-1', 10, size_mb => 100);
    # Linked clone created from snapshot 'snap1' of vm-1-disk-1.
    $config->register_ldev('vm-2-disk-1', 20, size_mb => 100,
        parent_volname => 'vm-1-disk-1', parent_snap => 'snap1');
    # Linked clone from the live volume (no snapshot ancestry).
    $config->register_ldev('vm-3-disk-1', 30, size_mb => 100,
        parent_volname => 'vm-1-disk-1');

    is_deeply($config->find_snapshot_dependents('vm-1-disk-1', 'snap1'),
        ['vm-2-disk-1'], 'clone from snap1 is a dependent');
    is_deeply($config->find_snapshot_dependents('vm-1-disk-1', 'snap2'),
        [], 'no dependents for an unrelated snapshot');
    # The volume-level dependent (vm-3) is found by find_dependents, not by snap.
    is_deeply([sort @{$config->find_dependents('vm-1-disk-1')}],
        ['vm-2-disk-1', 'vm-3-disk-1'], 'find_dependents still lists all clones');
};

# ── Cluster lock branch wiring ──
# The cluster path is normally skipped in tests because the registry lives in a
# tempdir. Force it on and stub PVE::Cluster to prove the registry uses a DEDICATED
# lock domain (cfs_lock_domain), NOT cfs_lock_storage — the latter would self-deadlock
# against PVE core's own storage lock around vdisk_alloc/free/activate.

subtest 'cluster_lock_uses_dedicated_domain' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my @lock_calls;
    no warnings 'redefine', 'once';
    # Stub the upstream primitive: record the lock domain and run the critical
    # section, mirroring cfs_lock_domain (returns the coderef's value, $@ clear).
    local *PVE::Cluster::cfs_lock_domain = sub {
        my ($domain, $timeout, $code, @param) = @_;
        push @lock_calls, $domain;
        return $code->(@param);
    };
    local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/cl.json" };
    # Force the cluster branch regardless of the tempdir path.
    local *PVE::Storage::HitachiBlock::Config::_use_cluster_lock = sub { 1 };

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => 'clstore');
    $config->register_ldev('vm-7-disk-1', 71, size_mb => 64);

    is_deeply(\@lock_calls, ['hitachiblock-registry-clstore'],
        'registry uses a dedicated lock domain, not the PVE storage lock');

    # The write inside the critical section persisted, and a scalar-context lookup
    # through the same locked path returns correctly (arrayref unwrap works).
    my ($id) = $config->lookup_ldev('vm-7-disk-1');
    is($id, 71, 'cluster-locked read-modify-write persisted the entry');
};

done_testing();
