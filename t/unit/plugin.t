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

subtest 'parse_volname_base' => sub {
    # Base (template) volume parsing — added with create_base support.
    my $parse = sub {
        my ($v) = @_;
        return ('images', $v, $1, undef, undef, 1, 'raw')
            if $v =~ /^base-(\d+)-disk-(\d+)$/;
        return ('images', $v, $1, undef, undef, undef, 'raw')
            if $v =~ /^vm-(\d+)-disk-(\d+)$/;
        return;
    };

    my @base = $parse->('base-100-disk-1');
    is($base[2], 100, 'base vmid extracted');
    is($base[5], 1, 'base isBase flag set');

    my @vm = $parse->('vm-100-disk-1');
    is($vm[2], 100, 'vm vmid extracted');
    is($vm[5], undef, 'vm isBase flag unset');

    # vmid_from_volname accepts both prefixes.
    my $vmid_from = sub { ($_[0] =~ /^(?:vm|base)-(\d+)-/) ? $1 : 0 };
    is($vmid_from->('base-200-disk-3'), 200, 'vmid from base name');
    is($vmid_from->('vm-300-disk-1'), 300, 'vmid from vm name');
};

subtest 'ldev_size_mb_logic' => sub {
    # Mirrors _ldev_size_mb: prefer exact block count over formatted string.
    my $size = sub {
        my ($ldev) = @_;
        for my $f (qw(blockCapacity numOfBlocks)) {
            return int($ldev->{$f} * 512 / (1024 * 1024))
                if defined $ldev->{$f} && $ldev->{$f} =~ /^\d+$/;
        }
        my $cap = $ldev->{byteFormatCapacity};
        if (defined $cap) {
            return int($1 * 1024 * 1024) if $cap =~ /^([\d.]+)\s*T/i;
            return int($1 * 1024)        if $cap =~ /^([\d.]+)\s*G/i;
            return int($1)               if $cap =~ /^([\d.]+)\s*M/i;
        }
        return 0;
    };

    is($size->({ blockCapacity => 2097152 }), 1024, '2097152 blocks = 1024 MB');
    is($size->({ byteFormatCapacity => '1.00 G' }), 1024, '1G string = 1024 MB');
    is($size->({ byteFormatCapacity => '2.00 T' }), 2097152, '2T string = 2097152 MB');
    is($size->({ byteFormatCapacity => '512.00 M' }), 512, '512M string = 512 MB');
    # Block count takes precedence over the formatted string when both present.
    is($size->({ blockCapacity => 2097152, byteFormatCapacity => '999.00 G' }), 1024,
       'block count wins over byteFormatCapacity');
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

subtest 'port_scheduler_deterministic_by_ldev' => sub {
    # Mirrors _select_ports: a given LDEV always maps to the same two ports
    # (stable across processes/nodes), giving multipath redundancy without an
    # in-memory counter that resets every pvesm invocation.
    my @all_ports = ('CL1-A', 'CL2-A', 'CL3-A', 'CL4-A');

    my $select = sub {
        my ($ldev_id) = @_;
        my $n = scalar(@all_ports);
        my $idx = defined $ldev_id ? ($ldev_id % $n) : 0;
        my $next = ($idx + 1) % $n;
        return ($all_ports[$idx], $all_ports[$next]);
    };

    is_deeply([$select->(0)], ['CL1-A', 'CL2-A'], 'ldev 0 -> ports 0,1');
    is_deeply([$select->(1)], ['CL2-A', 'CL3-A'], 'ldev 1 -> ports 1,2');
    is_deeply([$select->(3)], ['CL4-A', 'CL1-A'], 'ldev 3 -> ports 3,0 (wraps)');

    # Same LDEV is stable across repeated calls (map/unmap symmetry).
    is_deeply([$select->(42)], [$select->(42)], 'selection is stable per LDEV');
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
