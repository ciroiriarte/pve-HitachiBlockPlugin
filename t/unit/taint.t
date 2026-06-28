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

# Functional: get_device_path must return an UNTAINTED path, since PVE runs
# mkfs/mount on it via exec under taint mode (found live: CT mkfs.ext4 died
# "Insecure dependency in exec" because the returned device path was tainted).
my $is_tainted = sub {
    # Canonical Perl taint-detection idiom (no CPAN dep): under -T, building an
    # eval-string from tainted data dies. substr($v,0,0) is ALWAYS the empty
    # string, so the eval-string is only ever the literal "#" (a comment) — no
    # arbitrary code can execute; only the taintedness of $v is probed.
    return !eval { eval('#' . substr($_[0], 0, 0)); 1 };
};
my $tainted_suffix = substr($ENV{PATH} // '', 0, 0);   # tainted empty string
my $tainted_wwid   = '60060e8021a789005060a78900000100' . $tainted_suffix;
ok($is_tainted->($tainted_wwid), 'test wwid is tainted to start');

my $mp = PVE::Storage::HitachiBlock::Multipath->new();
my $path = $mp->get_device_path($tainted_wwid);
is($path, '/dev/mapper/360060e8021a789005060a78900000100', 'get_device_path builds the 3<wwid> path');
ok(!$is_tainted->($path), 'get_device_path returns an UNTAINTED path (safe for exec)');
eval { $mp->get_device_path('not-a-wwid!') };
like($@, qr/invalid device WWID/, 'get_device_path rejects a non-hex wwid');

done_testing();
