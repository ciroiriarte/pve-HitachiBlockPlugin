#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
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

    # On a host with no matching Hitachi device this returns undef rather than
    # dying — the caller then falls back to the synthesized WWID.
    my $res = $mp->discover_wwid(99999);
    ok(!defined $res || $res =~ /^60060e80/, 'returns undef or a Hitachi NAA wwid');
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

done_testing();
