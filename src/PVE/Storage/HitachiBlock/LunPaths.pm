package PVE::Storage::HitachiBlock::LunPaths;

use strict;
use warnings;

use Carp qw(croak);

# LU-path / host-group accounting and orphan-map reconciliation (issue #28).
#
# Late binding maps a LUN only on the node currently running the VM and unmaps on
# stop/migrate, which keeps per-node host-side device count and per-port LU-path
# consumption bounded. Nothing observed or reconciled it, so a leaked unmap
# (failed teardown, crash mid-migration, the unmap-retry loop giving up) would
# silently drift the per-port LU-path budget toward the array cap with no signal.
#
# This module provides:
#   * scan()      — read-only: this node's LU-path/host-group counts per target
#                   port, plus orphan LU paths (mapped here but whose LDEV is no
#                   longer in the registry) and any port over its budget.
#   * reconcile() — guarded, dry-run-by-default unmap of those orphan paths.
#
# Both operate only on THIS node's host groups (resolved from the local WWNs), so
# another host's LU paths are never observed or touched. The client interface used
# is the same PVE::Storage::HitachiBlock::RestClient methods the plugin uses, so a
# fake client makes the logic unit-testable without an array.

# Default fraction of a port's LU-path budget at which scan() flags it.
our $BUDGET_THRESHOLD = 0.8;

# Parse an ldev_range string (decimal OR hex, e.g. '256-511' or '0x100-0x1FF')
# into [min,max], or undef if undefined/empty/malformed. Single source of truth
# for the reconcile() safety fence range; hex support mirrors the plugin's own
# ldev_range parser so a hex-configured range never silently disables the fence.
sub parse_ldev_range {
    my ($class, $str) = @_;
    return undef unless defined $str && length $str;
    my ($lo, $hi) = $str =~ /^\s*(0x[0-9a-fA-F]+|\d+)\s*-\s*(0x[0-9a-fA-F]+|\d+)\s*$/
        or return undef;
    my $min = $lo =~ /^0x/i ? hex($lo) : int($lo);
    my $max = $hi =~ /^0x/i ? hex($hi) : int($hi);
    return undef if $min > $max;   # reversed range is invalid -> fails closed
    return [ $min, $max ];
}

# scan(%args) — read-only per-node LU-path / host-group report.
#   client            (required) RestClient-like object
#   wwns              arrayref of this node's FC WWNs (lowercase, no 0x)
#   target_ports      arrayref of target FC port ids
#   registered_ldevs  hashref { ldev_id => 1 } of LDEVs known to the registry
#   per_port_budget   integer LU-path cap per port (0 = unknown, no budget check)
#   budget_threshold  fraction (default $BUDGET_THRESHOLD) to flag a port at
#
# Returns:
#   {
#     ports => { <port> => { host_group_number, lun_path_count,
#                            host_groups_on_port, lun_paths => [{lun_id,ldev_id}] } },
#     total_lun_paths => <int>,
#     orphans     => [ { port, host_group_number, lun_id, ldev_id } ],
#     over_budget => [ { port, count, budget, pct } ],
#   }
sub scan {
    my ($class, %args) = @_;

    my $client = $args{client} or croak "client is required";
    my $wwns       = $args{wwns}             || [];
    my $ports      = $args{target_ports}     || [];
    my $registered = $args{registered_ldevs} || {};
    my $budget     = $args{per_port_budget}  || 0;
    my $threshold  = defined $args{budget_threshold} ? $args{budget_threshold} : $BUDGET_THRESHOLD;

    my %ports_report;
    my @orphans;
    my @over_budget;
    my $total = 0;

    for my $port (@$ports) {
        $port =~ s/^\s+|\s+$//g;
        next unless length $port;

        # Total host groups on the port — for headroom against the per-port host
        # group cap (255). Best-effort: a query failure leaves it undef.
        my $hg_on_port = eval { scalar @{ $client->list_host_groups(port_id => $port) || [] } };

        # This node's host group on the port (matched by one of our WWNs).
        my $hg;
        for my $wwn (@$wwns) {
            $hg = eval { $client->find_host_group_by_wwn($port, $wwn) };
            last if $hg;
        }
        if (!$hg) {
            $ports_report{$port} = {
                host_group_number   => undef,
                lun_path_count      => 0,
                host_groups_on_port => $hg_on_port,
                lun_paths           => [],
            };
            next;
        }

        my $luns = eval {
            $client->list_luns(port_id => $port, host_group_number => $hg->{hostGroupNumber});
        } || [];
        my @paths = map { { lun_id => $_->{lunId}, ldev_id => $_->{ldevId} } } @$luns;
        my $count = scalar @paths;
        $total += $count;

        $ports_report{$port} = {
            host_group_number   => $hg->{hostGroupNumber},
            lun_path_count      => $count,
            host_groups_on_port => $hg_on_port,
            lun_paths           => \@paths,
        };

        for my $p (@paths) {
            next unless defined $p->{ldev_id};
            next if $registered->{ $p->{ldev_id} };
            push @orphans, {
                port              => $port,
                host_group_number => $hg->{hostGroupNumber},
                lun_id            => $p->{lun_id},
                ldev_id           => $p->{ldev_id},
            };
        }

        if ($budget > 0 && $count >= $budget * $threshold) {
            push @over_budget, {
                port   => $port,
                count  => $count,
                budget => $budget,
                pct    => int($count * 100 / $budget),
            };
        }
    }

    return {
        ports           => \%ports_report,
        total_lun_paths => $total,
        orphans         => \@orphans,
        over_budget     => \@over_budget,
    };
}

# reconcile($client, $report, %opts) — unmap orphan LU paths from a scan() report.
# DRY-RUN BY DEFAULT: only with apply => 1 are paths actually unmapped.
#   ldev_range  [min,max] arrayref — an orphan whose LDEV falls outside the range
#               is SKIPPED (never unmapped), mirroring the plugin's safety fence.
#               Omit to allow any orphan (matches _ldev_in_range when unset).
#   apply       1 to unmap; otherwise dry-run.
#
# Only paths flagged as orphans by scan() (mapped in THIS node's host group, LDEV
# absent from the registry) are ever candidates, so a live registered volume is
# never unmapped.
#
# Returns: { applied => 0|1, would_unmap => [...], unmapped => [...],
#            skipped => [ { ..., reason } ] }
sub reconcile {
    my ($class, $client, $report, %opts) = @_;

    croak "client is required"  unless $client;
    croak "report is required"  unless ref $report eq 'HASH';

    my $apply = $opts{apply} ? 1 : 0;
    my $range = $opts{ldev_range};   # [min,max] or undef

    my (@would, @unmapped, @skipped);

    for my $o (@{ $report->{orphans} || [] }) {
        my $id = $o->{ldev_id};

        if ($range && (!defined $id || $id < $range->[0] || $id > $range->[1])) {
            push @skipped, { %$o, reason => "outside ldev_range $range->[0]-$range->[1]" };
            next;
        }

        if (!$apply) {
            push @would, { %$o };
            next;
        }

        my $ok = eval { $client->unmap_lun($o->{lun_id}); 1 };
        if ($ok) {
            push @unmapped, { %$o };
        } else {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+/ /g;
            push @skipped, { %$o, reason => "unmap failed: $err" };
        }
    }

    return {
        applied     => $apply,
        would_unmap => \@would,
        unmapped    => \@unmapped,
        skipped     => \@skipped,
    };
}

1;
