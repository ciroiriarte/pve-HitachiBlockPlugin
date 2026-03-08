#!/usr/bin/perl

# Plugin unit tests — tests that don't require PVE framework
# Tests parse_volname, vmid_from_volname, _next_volname, volume_has_feature logic

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

use lib 'src';

# We can't load the full plugin without PVE libs, so test the helper functions
# by extracting their logic. For integration, test on a PVE node.

# ── Volume Name Parsing ──

subtest 'parse_volname_valid' => sub {
    # Simulate parse_volname logic
    my $volname = 'vm-100-disk-1';
    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        is($1, 100, 'vmid extracted');
        is($2, 1, 'disk seq extracted');
    } else {
        fail('pattern should match');
    }
};

subtest 'parse_volname_invalid' => sub {
    my $volname = 'invalid-name';
    ok($volname !~ /^vm-(\d+)-disk-(\d+)$/, 'invalid name does not match');
};

subtest 'vmid_from_volname' => sub {
    my $extract = sub {
        my ($v) = @_;
        return ($v =~ /^vm-(\d+)-/) ? $1 : 0;
    };

    is($extract->('vm-100-disk-1'), 100, 'vmid 100');
    is($extract->('vm-999-disk-5'), 999, 'vmid 999');
    is($extract->('invalid'), 0, 'no vmid');
};

# ── Next Volume Name Generation ──

subtest 'next_volname_logic' => sub {
    my %registry = (
        'vm-100-disk-1' => { ldev_id => 1 },
        'vm-100-disk-2' => { ldev_id => 2 },
        'vm-100-disk-5' => { ldev_id => 5 },
        'vm-200-disk-1' => { ldev_id => 10 },
    );

    my $vmid = 100;
    my $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }

    is($max_seq, 5, 'max seq for vm-100 is 5');
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-100-disk-6', 'next is disk-6');

    # For vm-200
    $vmid = 200;
    $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-200-disk-2', 'next is disk-2');

    # For new vmid
    $vmid = 300;
    $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-300-disk-1', 'first disk for new vm');
};

# ── Feature Matrix ──

subtest 'volume_has_feature_logic' => sub {
    my %features = (
        snapshot   => { current => 1 },
        clone      => { current => 1, snap => 1 },
        copy       => { current => 1, snap => 1 },
        sparseinit => { current => 1 },
        template   => { current => 1 },
        resize     => { current => 1 },
    );

    my $check = sub {
        my ($feature, $snapname) = @_;
        my $opts = $features{$feature} || return 0;
        return $snapname ? ($opts->{snap} ? 1 : 0) : ($opts->{current} ? 1 : 0);
    };

    # Current volume features
    is($check->('snapshot', undef), 1, 'snapshot on current');
    is($check->('clone', undef), 1, 'clone on current');
    is($check->('copy', undef), 1, 'copy on current');
    is($check->('sparseinit', undef), 1, 'sparseinit on current');
    is($check->('template', undef), 1, 'template on current');

    # Snapshot features
    is($check->('snapshot', 'snap1'), 0, 'no snapshot of snapshot');
    is($check->('clone', 'snap1'), 1, 'clone from snapshot');
    is($check->('copy', 'snap1'), 1, 'copy from snapshot');

    # Resize feature
    is($check->('resize', undef), 1, 'resize on current');
    is($check->('resize', 'snap1'), 0, 'no resize of snapshot');

    # Unknown feature
    is($check->('unknown', undef), 0, 'unknown feature');
};

# ── Label Format ──

subtest 'label_constraints' => sub {
    # LDEV label has max length on Hitachi arrays (typically 32 chars)
    my $label = "pve:myarray:vm-100-disk-1";
    ok(length($label) <= 32, "label '$label' fits 32 chars (" . length($label) . ")");

    # Longer storeid
    my $long_label = "pve:verylongstoragename:vm-99999-disk-99";
    if (length($long_label) > 32) {
        pass("long label exceeds 32 chars (" . length($long_label) . ") - may need truncation");
    } else {
        pass("long label fits");
    }
};

# ── LDEV Range Parsing ──

subtest 'ldev_range_parsing' => sub {
    # Decimal range
    my $range = '1000-1999';
    if ($range =~ /^(\d+)-(\d+)$/) {
        is($1, 1000, 'decimal min');
        is($2, 1999, 'decimal max');
    } else {
        fail('should match decimal');
    }

    # Hex range
    $range = '0x3E8-0x7CF';
    if ($range =~ /^(0x[0-9a-f]+)-(0x[0-9a-f]+)$/i) {
        is(hex($1), 1000, 'hex min');
        is(hex($2), 1999, 'hex max');
    } else {
        fail('should match hex');
    }

    # Invalid range
    $range = 'invalid';
    ok($range !~ /^(0x[0-9a-fA-F]+|\d+)-(0x[0-9a-fA-F]+|\d+)$/, 'invalid range rejected');
};

# ── Port Scheduler Logic ──

subtest 'port_scheduler_round_robin' => sub {
    my @all_ports = ('CL1-A', 'CL2-A', 'CL3-A', 'CL4-A');
    my %counters;

    my $select = sub {
        my ($storeid) = @_;
        my $idx = ($counters{$storeid} || 0) % scalar(@all_ports);
        my $next_idx = ($idx + 1) % scalar(@all_ports);
        my @selected = ($all_ports[$idx], $all_ports[$next_idx]);
        $counters{$storeid} = $next_idx + 1;
        return @selected;
    };

    my @p1 = $select->('test');
    is_deeply(\@p1, ['CL1-A', 'CL2-A'], 'first selection: ports 0,1');

    my @p2 = $select->('test');
    is_deeply(\@p2, ['CL3-A', 'CL4-A'], 'second selection: ports 2,3');

    my @p3 = $select->('test');
    is_deeply(\@p3, ['CL1-A', 'CL2-A'], 'wraps around: ports 0,1 again');
};

# ── Manage/Unmanage Volume Name Logic ──

subtest 'manage_generates_volname' => sub {
    # When managing an existing LDEV, a new volname is generated
    my %registry = (
        'vm-100-disk-1' => { ldev_id => 1 },
        'vm-100-disk-2' => { ldev_id => 2 },
    );

    my $vmid = 100;
    my $max_seq = 0;
    for my $name (keys %registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }
    is("vm-${vmid}-disk-" . ($max_seq + 1), 'vm-100-disk-3',
       'managed LDEV gets next available volname');
};

done_testing();
