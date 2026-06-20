#!/usr/bin/perl -T

# Taint-safety regression tests. `pct` (LXC) runs the storage layer in taint mode
# (-T); the plugin must not die "Insecure dependency" on tainted sysfs paths /
# argv. This file runs under -T so loading the modules and exercising the
# untaint logic is itself the guard. (Found live: a CT could not be created
# because Multipath used a tainted glob() path in a write-open.)

use strict;
use warnings;
use Test::More;
use lib 'src';

# The module must compile and load under taint mode.
require_ok('PVE::Storage::HitachiBlock::Multipath');

# Mirror of _run_cmd's argv untaint: internal command names, flags, device paths
# and WWIDs are allowed; shell metacharacters / spaces are rejected.
my $untaint_arg = sub {
    my ($a) = @_;
    return $a =~ /^([\w\@%+=:,.\/-]+)$/ ? $1 : undef;
};
for my $ok ('multipath', '-r', '--getsize64', '/dev/mapper/360060e8021a789005060a78900000100',
            '360060e8021a789005060a78900000100', 'resize', 'map', '--timeout=10') {
    ok(defined $untaint_arg->($ok), "argv accepts '$ok'");
}
for my $bad ('foo; rm -rf /', 'a b', '$(whoami)', 'x|y', "a\nb") {
    ok(!defined $untaint_arg->($bad), "argv rejects unsafe '$bad'");
}

# Mirror of the sysfs scan-path untaint (rescan_scsi_hosts): only the expected
# /sys/class/scsi_host/hostN shape is accepted from a tainted glob().
my $untaint_host = sub {
    my ($p) = @_;
    return $p =~ m{^(/sys/class/scsi_host/host\d+)\z} ? $1 : undef;
};
ok(defined $untaint_host->('/sys/class/scsi_host/host18'), 'scan path accepts a real host');
ok(!defined $untaint_host->('/sys/class/scsi_host/host18/../../../etc'), 'scan path rejects traversal');

done_testing();
