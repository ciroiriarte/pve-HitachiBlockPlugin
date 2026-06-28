#!/usr/bin/perl

# Snapshot behavior tests (issue #12 sibling-preserving rollback + #34 parity).
#
# Loads the REAL plugin via minimal PVE stubs (as blockdev.t) with the LDEV
# registry redirected to a tempdir, and exercises the parts that don't need a
# live array: the rollback-feasibility predicate, volume_snapshot_info ordering,
# rename_snapshot, the `none` content type, and the registry/array reconcile +
# snapshot-id resolver (driven by a fake REST client).

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

# ── Minimal PVE stubs ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }
}
BEGIN {
    $INC{'PVE/JSONSchema.pm'} = 1;
    package PVE::JSONSchema;
    require Exporter;
    our @ISA = ('Exporter'); our @EXPORT_OK = ('get_standard_option');
    sub get_standard_option { return {} }
}
BEGIN {
    $INC{'PVE/Tools.pm'} = 1;
    package PVE::Tools;
    require Exporter;
    our @ISA = ('Exporter'); our @EXPORT_OK = ('run_command');
    sub run_command { die "run_command stub should not be called\n" }
}

# Fake REST client: list_snapshots returns whatever array we seed.
package FakeClient;
sub new { my ($c, @s) = @_; return bless { snaps => [@s] }, $c }
sub list_snapshots { my ($self, %o) = @_; return $self->{snaps} }

# Stateful fake: returns one pair (id 267,4) whose status walks a sequence across
# successive list_snapshots calls (then sticks on the last). For _wait_snapshot_status.
package SeqClient;
sub new { my ($c, @seq) = @_; return bless { seq => [@seq], i => 0 }, $c }
sub list_snapshots {
    my ($self, %o) = @_;
    my $st = $self->{seq}[$self->{i}] // $self->{seq}[-1];
    $self->{i}++;
    return [ { snapshotId => '267,4', muNumber => 4, status => $st,
               snapshotGroupName => 'pve_mystore_267_snap2' } ];
}

package main;

use lib 'src';
require_ok('PVE::Storage::Custom::HitachiBlockPlugin');
require_ok('PVE::Storage::HitachiBlock::Config');

my $CLASS = 'PVE::Storage::Custom::HitachiBlockPlugin';
my $tmpdir = tempdir(CLEANUP => 1);
no warnings 'redefine';
local *PVE::Storage::HitachiBlock::Config::_registry_file = sub { "$tmpdir/reg.json" };

my $scfg  = { type => 'hitachiblock', storage_id => '836000123456' };
my $store = 'mystore';
my $vol   = 'vm-100-disk-1';

my $cfg = PVE::Storage::HitachiBlock::Config->new(storeid => $store);
$cfg->register_ldev($vol, 256, size_mb => 1024);
$cfg->register_snapshot($vol, 'snap1', svol_ldev_id => 300, snapshot_id => '256,3', timestamp => 100);
$cfg->register_snapshot($vol, 'snap2', svol_ldev_id => 301, snapshot_id => '256,4', timestamp => 200);

# ── `none` content type (#34) ──
subtest 'plugindata advertises none content type' => sub {
    my $pd = $CLASS->plugindata();
    ok($pd->{content}[0]{none}, "'none' content type is offered");
    ok($pd->{content}[0]{images}, 'images still offered');
    ok($pd->{content}[0]{rootdir}, 'rootdir still offered');
};

# ── volume_snapshot_info: order + parent chain ──
subtest 'volume_snapshot_info order and parent' => sub {
    my $info = $CLASS->volume_snapshot_info($scfg, $store, $vol);
    is($info->{snap1}{order}, 0, 'oldest snapshot has order 0');
    is($info->{snap2}{order}, 1, 'next snapshot has order 1');
    is($info->{current}{order}, 2, 'current sorts after all snapshots');
    is($info->{snap1}{parent}, undef, 'oldest has no parent');
    is($info->{snap2}{parent}, 'snap1', 'snap2 parent is snap1');
    is($info->{current}{parent}, 'snap2', 'current parent is the newest snapshot');
};

# ── Sibling-preserving rollback predicate (#12) ──
subtest 'volume_rollback_is_possible' => sub {
    my $blockers = [];
    ok($CLASS->volume_rollback_is_possible($scfg, $store, $vol, 'snap1', $blockers),
        'rollback to non-latest snap1 is allowed (sibling-preserving)');
    is_deeply($blockers, [], 'no blockers for a newer-snapshot-present rollback');

    ok($CLASS->volume_rollback_is_possible($scfg, $store, $vol, 'snap2'),
        'rollback to latest snap2 is allowed');

    eval { $CLASS->volume_rollback_is_possible($scfg, $store, $vol, 'ghost') };
    like($@, qr/does not exist/, 'rollback to a missing snapshot is refused');
};

subtest 'rollback blocked when a linked clone depends on the snapshot' => sub {
    # A linked clone derived from snap1 of $vol.
    $cfg->register_ldev('vm-200-disk-1', 400, size_mb => 1024,
        parent_volname => $vol, parent_snap => 'snap1');
    my $blockers = [];
    eval { $CLASS->volume_rollback_is_possible($scfg, $store, $vol, 'snap1', $blockers) };
    like($@, qr/linked clone\(s\) depend/, 'rollback blocked by dependent clone');
    is_deeply($blockers, ['vm-200-disk-1'], 'dependent clone reported as blocker');
    $cfg->unregister_ldev('vm-200-disk-1');   # clean up for later subtests
};

# ── rename_snapshot (#34) via the plugin entry point ──
subtest 'rename_snapshot' => sub {
    $CLASS->rename_snapshot($scfg, $store, $vol, 'snap2', 'renamed');
    my $snaps = $cfg->list_snapshots($vol);
    ok(exists $snaps->{renamed} && !exists $snaps->{snap2}, 'snap2 renamed to renamed');
    is($snaps->{renamed}{snapshot_id}, '256,4', 'snapshot_id preserved');
    # rename back so the reconcile subtest below has predictable names
    $CLASS->rename_snapshot($scfg, $store, $vol, 'renamed', 'snap2');
};

# ── _resolve_snapshot_id: registry hit, then array fallback ──
subtest '_resolve_snapshot_id' => sub {
    my $client = FakeClient->new(
        { snapshotId => '256,9', snapshotGroupName => "pve_${store}_256_legacyonly" },
    );
    is($CLASS->_resolve_snapshot_id($client, $cfg, $store, 256, $vol, 'snap1'), '256,3',
        'resolves from the registry when present');
    # Not in registry -> fall back to a group-name match on the array.
    is($CLASS->_resolve_snapshot_id($client, $cfg, $store, 256, $vol, 'legacyonly'), '256,9',
        'falls back to array group-name search');
    is($CLASS->_resolve_snapshot_id($client, $cfg, $store, 256, $vol, 'nope'), undef,
        'returns undef when unresolvable');
};

# ── _reconcile_snapshots: prune registry entries the array no longer has ──
subtest '_reconcile_snapshots prunes stale entries' => sub {
    # Array reports only snap1's pair; snap2's (256,4) is gone.
    my $client = FakeClient->new({ snapshotId => '256,3' });
    $CLASS->_reconcile_snapshots($client, $cfg, 256, $vol);
    my $snaps = $cfg->list_snapshots($vol);
    ok(exists $snaps->{snap1}, 'snap1 (still on array) retained');
    ok(!exists $snaps->{snap2}, 'snap2 (absent from array) pruned');
};

# ── _wait_snapshot_status: the #12 RCPY-settle fix ──
subtest '_wait_snapshot_status waits for the pair to settle' => sub {
    # Restore runs RCPY twice, then settles to PAIR — wait must return PAIR.
    my $seq = SeqClient->new('RCPY', 'RCPY', 'PAIR');
    is($CLASS->_wait_snapshot_status($seq, 267, '267,4', 'PAIR', 10), 'PAIR',
        'returns PAIR once the restore copy completes (after RCPY)');

    # Already at target on first poll -> returns immediately (no waiting).
    my $now = SeqClient->new('PSUS');
    is($CLASS->_wait_snapshot_status($now, 267, '267,4', 'PSUS', 10), 'PSUS',
        'returns immediately when already at the target status');

    # Never reaches target within the timeout -> undef (caller warns, non-fatal).
    my $stuck = SeqClient->new('RCPY');
    is($CLASS->_wait_snapshot_status($stuck, 267, '267,4', 'PSUS', 1), undef,
        'times out to undef when the pair never reaches the target');
};

done_testing();
