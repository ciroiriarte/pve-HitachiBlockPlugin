#!/usr/bin/perl

# Array-sourced value validation tests (issue #19).
#
# WWIDs, LDEV ids, and the device paths derived from them flow into host tools
# (multipath, multipathd, blockdev) and sysfs. These tests exercise the REAL
# Multipath validation helpers (the module loads standalone) and assert that
# valid forms are accepted/normalised and malformed ones are rejected with an
# actionable error rather than passed through.

use strict;
use warnings;

use Test::More;

use lib 'src';
require_ok('PVE::Storage::HitachiBlock::Multipath');

my $mp = PVE::Storage::HitachiBlock::Multipath->new();

my $NAA = '60060e8021a789005060a78900000104';   # a real-shape Hitachi NAA-6 id

# ── _dm_wwid: normalise + validate to '3<hex>' ──
subtest '_dm_wwid accepts valid WWIDs' => sub {
    is($mp->_dm_wwid($NAA), "3$NAA", 'bare NAA gets the 3-prefix');
    is($mp->_dm_wwid("3$NAA"), "3$NAA", 'already-prefixed passes through');
    is($mp->_dm_wwid('60060E80ABCDEF'), '360060E80ABCDEF', 'uppercase hex accepted');
};

subtest '_dm_wwid rejects malformed WWIDs' => sub {
    my @bad = (
        ['undef'            => undef],
        ['empty'            => ''],
        ['non-hex letters'  => '60060e80zzzz'],
        ['shell metachars'  => '60060e80; rm -rf /'],
        ['path traversal'   => '../../etc/passwd'],
        ['spaces'           => '60060e80 0104'],
    );
    for my $case (@bad) {
        my ($name, $val) = @$case;
        eval { $mp->_dm_wwid($val) };
        like($@, qr/wwid is required|invalid device WWID/, "rejects $name");
    }
};

# ── _assert_ldev_id: non-negative integer ──
subtest '_assert_ldev_id accepts/rejects' => sub {
    is($mp->_assert_ldev_id(0), 0, 'zero accepted');
    is($mp->_assert_ldev_id(262), 262, 'positive integer accepted');
    is($mp->_assert_ldev_id('00256'), 256, 'leading zeros normalised to int');

    for my $bad (undef, '', '-1', '1.5', '0xFF', 'abc', '12; reboot') {
        my $shown = defined($bad) ? "'$bad'" : 'undef';
        eval { $mp->_assert_ldev_id($bad) };
        like($@, qr/ldev_id is required|invalid LDEV id/, "rejects $shown");
    }
};

# ── get_device_path: built from a validated WWID ──
subtest 'get_device_path' => sub {
    is($mp->get_device_path($NAA), "/dev/mapper/3$NAA", 'valid WWID -> mapper path');
    eval { $mp->get_device_path('bad;wwid') };
    like($@, qr/invalid device WWID/, 'malformed WWID rejected before building a path');
};

# ── get_device_size: only our multipath device paths ──
subtest 'get_device_size path guard' => sub {
    for my $bad ('/etc/passwd', '/dev/sda', '/dev/mapper/notawwid', "/dev/mapper/3$NAA; id") {
        eval { $mp->get_device_size($bad) };
        like($@, qr/refusing to query non-multipath device path/, "rejects '$bad'");
    }
    # A well-formed mapper path passes validation and then fails on non-existence
    # (proves the guard ran first, not the -e check).
    eval { $mp->get_device_size("/dev/mapper/3$NAA") };
    like($@, qr/not found/, 'well-formed path passes the guard, fails on missing device');
};

# ── ldev_to_wwid: validates the LDEV id ──
subtest 'ldev_to_wwid validates ldev_id' => sub {
    my $wwid = $mp->ldev_to_wwid('836000123456', 262);
    like($wwid, qr/^[0-9a-f]+$/, 'valid inputs yield a hex WWID');
    eval { $mp->ldev_to_wwid('836000123456', 'bad') };
    like($@, qr/invalid LDEV id/, 'non-numeric ldev_id rejected');
};

done_testing();
