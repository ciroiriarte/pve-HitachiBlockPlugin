#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';

# Install the CORE::GLOBAL::glob override BEFORE the module is compiled so
# that discover_wwid's internal glob('/sys/block/sd*/device/wwid') call is
# interceptable on a per-test basis without touching production code.
our $glob_override;
BEGIN {
    *CORE::GLOBAL::glob = sub {
        return $glob_override->(@_) if defined $glob_override;
        return CORE::glob($_[0]);
    };
}

use PVE::Storage::HitachiBlock::Multipath;

subtest 'constructor' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();
    isa_ok($mp, 'PVE::Storage::HitachiBlock::Multipath');

    my $mp2 = PVE::Storage::HitachiBlock::Multipath->new(timeout => 120);
    is($mp2->{timeout}, 120, 'custom timeout');
};

subtest 'get_device_path' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    my $path = $mp->get_device_path('60060e80123456780001000000000000');
    is($path, '/dev/mapper/360060e80123456780001000000000000', 'prefixes 3 to wwid');

    my $path2 = $mp->get_device_path('360060e80123456780001000000000000');
    is($path2, '/dev/mapper/360060e80123456780001000000000000', 'already prefixed');

    eval { $mp->get_device_path() };
    like($@, qr/wwid is required/, 'requires wwid');
};

subtest 'ldev_to_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    my $wwid = $mp->ldev_to_wwid('00123456', 1);
    like($wwid, qr/^60060e80/, 'starts with NAA prefix');
    like($wwid, qr/00123456/, 'contains serial');
    like($wwid, qr/0001/, 'contains ldev hex');

    my $wwid2 = $mp->ldev_to_wwid('00123456', 255);
    like($wwid2, qr/00ff/, 'ldev 255 as hex');

    eval { $mp->ldev_to_wwid() };
    like($@, qr/storage_serial is required/, 'requires serial');
};

subtest 'flush_device_requires_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->flush_device() };
    like($@, qr/wwid is required/, 'flush_device requires wwid');
};

subtest 'remove_device_requires_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->remove_device() };
    like($@, qr/wwid is required/, 'remove_device requires wwid');
};

subtest 'resize_device_requires_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->resize_device() };
    like($@, qr/wwid is required/, 'resize_device requires wwid');
};

subtest 'get_device_size_requires_path' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->get_device_size() };
    like($@, qr/path is required/, 'get_device_size requires path');
};

subtest 'discover_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->discover_wwid() };
    like($@, qr/ldev_id is required/, 'discover_wwid requires ldev_id');

    # Drive the REAL discover_wwid against a faked sysfs: $glob_override feeds the
    # /sys/block/sd*/device/wwid list and a local _read_first_line returns each
    # file's contents. This exercises the page-83 prefix strip, the 60060e80
    # Hitachi-OUI filter, the HITACHI vendor gate, the ldev-hex substring match
    # and the dedup — every assertion can FAIL if that logic regresses.
    my $run = sub {
        my ($ldev, %fs) = @_;   # %fs: full sysfs path => file contents
        no warnings 'redefine';
        local $glob_override = sub {
            return grep { m{/sys/block/sd\w+/device/wwid$} } sort keys %fs;
        };
        local *PVE::Storage::HitachiBlock::Multipath::_read_first_line = sub {
            my ($path) = @_;
            return exists $fs{$path} ? $fs{$path} : undef;
        };
        return $mp->discover_wwid($ldev);
    };

    # LDEV 262 -> hex 0106. A HITACHI device whose NAA-6 carries OUI + ldev hex;
    # the 0x page-83 prefix must be stripped and the result lower-cased.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '0x60060E8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    ), '60060e8000000000000000000106',
       'matches OUI + ldev hex on a HITACHI device (0x stripped, lower-cased)');

    # The naa. page-83 prefix is also stripped before matching.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => 'naa.60060e8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    ), '60060e8000000000000000000106',
       'naa. prefix stripped before matching');

    # Wrong OUI (not the Hitachi 60060e80) -> skipped even though it carries 0106.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '50060e8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    ), undef, 'non-60060e80 OUI is skipped');

    # Right OUI but a non-HITACHI vendor -> skipped.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '60060e8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'NETAPP',
    ), undef, 'non-HITACHI vendor is skipped');

    # Right device, but the ldev hex (0106) is absent -> no match.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '60060e8000000000000000009999',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    ), undef, 'ldev hex not present -> no match');

    # Two paths to the same LUN -> deduped to a single candidate.
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '60060e8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'HITACHI',
        '/sys/block/sdb/device/wwid'   => '60060e8000000000000000000106',
        '/sys/block/sdb/device/vendor' => 'HITACHI',
    ), '60060e8000000000000000000106',
       'duplicate paths to the same wwid are deduped');

    # An empty vendor file is allowed (the gate is "empty OR HITACHI").
    is($run->(262,
        '/sys/block/sda/device/wwid'   => '60060e8000000000000000000106',
        '/sys/block/sda/device/vendor' => '',
    ), '60060e8000000000000000000106',
       'empty vendor string is accepted');
};

subtest 'whitelist_wwid' => sub {
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    eval { $mp->whitelist_wwid() };
    like($@, qr/wwid is required/, 'requires wwid');

    my @calls;
    no warnings 'redefine';
    local *PVE::Storage::HitachiBlock::Multipath::_run_cmd = sub { push @calls, [@_]; return ''; };

    my $dm = $mp->whitelist_wwid('60060e80123456780001000000000000');
    is($dm, '360060e80123456780001000000000000', 'returns 3-prefixed dm wwid');
    is_deeply($calls[0], ['multipath', '-a', '360060e80123456780001000000000000'],
        'runs multipath -a with the 3-prefixed wwid (find_multipaths strict)');

    @calls = ();
    my $dm2 = $mp->whitelist_wwid('360060e80123456780001000000000000');
    is($dm2, '360060e80123456780001000000000000', 'already-prefixed wwid is not double-prefixed');

    # Best-effort: a failing `multipath -a` (already present / not yet visible) must
    # not be fatal — it only warns.
    local *PVE::Storage::HitachiBlock::Multipath::_run_cmd = sub { die "rc=1\n" };
    local $SIG{__WARN__} = sub {};
    my $ok = eval { $mp->whitelist_wwid('60060e80aa'); 1 };
    ok($ok, 'whitelist_wwid does not die when multipath -a fails');
};

subtest 'prune_wwid_entries' => sub {
    use File::Temp qw(tempfile);
    my $mp = PVE::Storage::HitachiBlock::Multipath->new();

    # A wwids file that has accumulated commented duplicates for the freed wwid
    # plus an ACTIVE entry for a different, still-in-use LUN.
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh <<'WWIDS';
# Multipath wwids, Version : 1.0
#360060e8021a789005060a78900000104/
#360060e8021a789005060a78900000104/
/360060e8021a789005060a78900000104/
#360060e8021a789005060a78900000104/
/360060e8021a789005060a78900000107/
WWIDS
    close($fh);

    $mp->_prune_wwid_entries('360060e8021a789005060a78900000104', $path);

    open(my $rd, '<', $path) or die "reopen: $!";
    my @lines = <$rd>;
    close($rd);
    my $content = join('', @lines);
    unlike($content, qr/00000104/, 'all freed-wwid lines removed (commented + active + dups)');
    like($content, qr{/360060e8021a789005060a78900000107/}, 'other LUN\'s active entry preserved');
    like($content, qr/Version/, 'header preserved');

    # Safe no-ops: missing file / bad wwid must not die.
    my $ok1 = eval { $mp->_prune_wwid_entries('360060e80abc', '/nonexistent/wwids'); 1 };
    ok($ok1, 'missing file is a no-op (no die)');
    my $ok2 = eval { $mp->_prune_wwid_entries('not-hex!', $path); 1 };
    ok($ok2, 'invalid wwid is a no-op (no die)');
};

done_testing();
