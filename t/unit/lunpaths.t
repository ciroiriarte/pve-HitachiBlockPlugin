#!/usr/bin/perl

# LU-path / host-group accounting + orphan-unmap reconcile (issue #28).
# Exercises the real PVE::Storage::HitachiBlock::LunPaths logic with a fake client
# (no array): per-node host-group discovery, LU-path counts, orphan detection,
# budget threshold, and the dry-run-by-default guarded reconcile.

use strict;
use warnings;

use Test::More;

use lib 'src';
require_ok('PVE::Storage::HitachiBlock::LunPaths');

my $C = 'PVE::Storage::HitachiBlock::LunPaths';

# ── Fake client ──
# Models two target ports. This node's WWN ('aa') belongs to host group 1 on each
# port (named PVE_node). list_luns returns the LU paths in a host group. Records
# unmap_lun calls so we can assert dry-run vs apply.
package FakeClient;
sub new {
    my ($c, %o) = @_;
    return bless { %o, unmapped => [] }, $c;
}
sub list_host_groups {
    my ($self, %f) = @_;
    return $self->{host_groups}{ $f{port_id} } || [];
}
sub find_host_group_by_wwn {
    my ($self, $port, $wwn) = @_;
    for my $hg (@{ $self->{host_groups}{$port} || [] }) {
        return $hg if grep { lc($_) eq lc($wwn) } @{ $hg->{wwns} || [] };
    }
    return undef;
}
sub list_luns {
    my ($self, %f) = @_;
    return $self->{luns}{ "$f{port_id},$f{host_group_number}" } || [];
}
sub unmap_lun {
    my ($self, $lun_id) = @_;
    die "boom on $lun_id\n" if $self->{fail_unmap} && $self->{fail_unmap}{$lun_id};
    push @{ $self->{unmapped} }, $lun_id;
    return 1;
}

package main;

sub make_client {
    return FakeClient->new(
        host_groups => {
            'CL1-A' => [ { hostGroupNumber => 1, wwns => ['aa'] },
                         { hostGroupNumber => 7, wwns => ['bb'] } ],   # other host
            'CL2-A' => [ { hostGroupNumber => 1, wwns => ['aa'] } ],
        },
        luns => {
            # CL1-A / HG1 (ours): 256/257 live, 300 in-range ORPHAN, 5000 out-of-range orphan
            'CL1-A,1' => [ { lunId => 'CL1-A,1,0', ldevId => 256 },
                           { lunId => 'CL1-A,1,1', ldevId => 257 },
                           { lunId => 'CL1-A,1,2', ldevId => 300 },
                           { lunId => 'CL1-A,1,3', ldevId => 5000 } ],
            # CL2-A / HG1 (ours): ldev 256 (live)
            'CL2-A,1' => [ { lunId => 'CL2-A,1,0', ldevId => 256 } ],
        },
        @_,
    );
}

my %registered = ( 256 => 1, 257 => 1 );   # 999 and 5000 are NOT registered -> orphans

# ── scan ──
subtest 'scan: per-port counts, total, host-groups-on-port' => sub {
    my $rep = $C->scan(
        client => make_client(), wwns => ['AA'],   # case-insensitive match
        target_ports => ['CL1-A', 'CL2-A'],
        registered_ldevs => \%registered,
    );
    is($rep->{ports}{'CL1-A'}{lun_path_count}, 4, 'CL1-A LU-path count');
    is($rep->{ports}{'CL1-A'}{host_group_number}, 1, 'our HG on CL1-A');
    is($rep->{ports}{'CL1-A'}{host_groups_on_port}, 2, 'host groups on CL1-A (incl other host)');
    is($rep->{ports}{'CL2-A'}{lun_path_count}, 1, 'CL2-A LU-path count');
    is($rep->{total_lun_paths}, 5, 'total LU paths this node');
};

subtest 'scan: orphan detection (unregistered ldev only)' => sub {
    my $rep = $C->scan(
        client => make_client(), wwns => ['aa'],
        target_ports => ['CL1-A', 'CL2-A'],
        registered_ldevs => \%registered,
    );
    my @orphan_ldevs = sort { $a <=> $b } map { $_->{ldev_id} } @{ $rep->{orphans} };
    is_deeply(\@orphan_ldevs, [300, 5000], 'only unregistered LDEVs are orphans');
    ok(!(grep { $_->{ldev_id} == 256 } @{ $rep->{orphans} }), 'registered live LDEV never an orphan');
    is($rep->{orphans}[0]{port}, 'CL1-A', 'orphan carries its port');
};

subtest 'scan: budget threshold' => sub {
    # budget 5, threshold 0.8 -> flag at >=4. CL1-A has 4 -> over; CL2-A has 1 -> not.
    my $rep = $C->scan(
        client => make_client(), wwns => ['aa'],
        target_ports => ['CL1-A', 'CL2-A'],
        registered_ldevs => \%registered,
        per_port_budget => 5,
    );
    is(scalar @{ $rep->{over_budget} }, 1, 'one port over budget');
    is($rep->{over_budget}[0]{port}, 'CL1-A', 'CL1-A flagged');
    is($rep->{over_budget}[0]{pct}, 80, 'percent of budget reported');
};

subtest 'scan: node with no host group on a port' => sub {
    my $rep = $C->scan(
        client => make_client(), wwns => ['zz'],   # matches no host group
        target_ports => ['CL1-A'],
        registered_ldevs => \%registered,
    );
    is($rep->{ports}{'CL1-A'}{lun_path_count}, 0, 'no HG -> zero paths');
    is($rep->{total_lun_paths}, 0, 'nothing counted');
    is_deeply($rep->{orphans}, [], 'no orphans when we own no HG');
};

# ── reconcile ──
subtest 'reconcile: dry-run is default, no unmap' => sub {
    my $cli = make_client();
    my $rep = $C->scan(client => $cli, wwns => ['aa'], target_ports => ['CL1-A'],
        registered_ldevs => \%registered);
    my $res = $C->reconcile($cli, $rep, ldev_range => [256, 511]);   # no apply
    is($res->{applied}, 0, 'dry-run');
    is(scalar @{ $cli->{unmapped} }, 0, 'no unmap_lun calls in dry-run');
    my @w = sort { $a <=> $b } map { $_->{ldev_id} } @{ $res->{would_unmap} };
    is_deeply(\@w, [300], 'would unmap only the in-range orphan (300)');
    is(scalar(grep { $_->{ldev_id} == 5000 } @{ $res->{skipped} }), 1,
        'out-of-range orphan (5000) skipped');
    like($res->{skipped}[0]{reason}, qr/outside ldev_range/, 'skip reason given');
};

subtest 'reconcile: apply unmaps only in-range orphans' => sub {
    my $cli = make_client();
    my $rep = $C->scan(client => $cli, wwns => ['aa'], target_ports => ['CL1-A'],
        registered_ldevs => \%registered);
    my $res = $C->reconcile($cli, $rep, ldev_range => [256, 511], apply => 1);
    is($res->{applied}, 1, 'apply mode');
    is_deeply($cli->{unmapped}, ['CL1-A,1,2'], 'only the in-range orphan LU path unmapped');
    is_deeply([ map { $_->{ldev_id} } @{ $res->{unmapped} } ], [300], 'reports unmapped 300');
    ok(!(grep { $_->{ldev_id} == 256 } (@{$res->{unmapped}}, @{$res->{would_unmap}})),
        'live registered LDEV never unmapped');
    is(scalar(grep { $_->{ldev_id} == 5000 } @{ $res->{skipped} }), 1, '5000 still skipped (out of range)');
};

subtest 'reconcile: unmap failure is captured as skipped' => sub {
    my $cli = make_client(fail_unmap => { 'CL1-A,1,2' => 1 });
    my $rep = $C->scan(client => $cli, wwns => ['aa'], target_ports => ['CL1-A'],
        registered_ldevs => \%registered);
    my $res = $C->reconcile($cli, $rep, ldev_range => [256, 511], apply => 1);
    is(scalar @{ $res->{unmapped} }, 0, 'nothing reported unmapped');
    my ($f) = grep { $_->{ldev_id} == 300 } @{ $res->{skipped} };
    ok($f, '300 captured as skipped');
    like($f->{reason}, qr/unmap failed/, 'failure reason recorded');
};

# ── parse_ldev_range: decimal AND hex (#28 fence must not fail open on hex) ──
subtest 'parse_ldev_range decimal/hex/invalid' => sub {
    is_deeply($C->parse_ldev_range('256-511'), [256, 511], 'decimal range');
    is_deeply($C->parse_ldev_range(' 256 - 511 '), [256, 511], 'whitespace tolerated');
    is_deeply($C->parse_ldev_range('0x100-0x1FF'), [256, 511], 'hex range parsed to ints');
    is_deeply($C->parse_ldev_range('0x3E8-0x7CF'), [1000, 1999], 'hex range (doc example)');
    is($C->parse_ldev_range(undef), undef, 'undef -> undef');
    is($C->parse_ldev_range(''), undef, 'empty -> undef');
    is($C->parse_ldev_range('garbage'), undef, 'malformed -> undef');
    is($C->parse_ldev_range('256'), undef, 'single value -> undef');
    is($C->parse_ldev_range('511-256'), undef, 'reversed range -> undef (fails closed)');
};

subtest 'reconcile honours a hex-derived range' => sub {
    # ldev 300 is inside 0x100-0x1FF (256-511); 5000 is outside.
    my $cli = make_client();
    my $rep = $C->scan(client => $cli, wwns => ['aa'], target_ports => ['CL1-A'],
        registered_ldevs => \%registered);
    my $range = $C->parse_ldev_range('0x100-0x1FF');
    my $res = $C->reconcile($cli, $rep, ldev_range => $range, apply => 1);
    is_deeply([ map { $_->{ldev_id} } @{ $res->{unmapped} } ], [300],
        'in-range orphan unmapped via a hex-derived fence');
    is(scalar(grep { $_->{ldev_id} == 5000 } @{ $res->{skipped} }), 1,
        'out-of-range orphan still skipped under a hex fence');
};

done_testing();
