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

done_testing();
