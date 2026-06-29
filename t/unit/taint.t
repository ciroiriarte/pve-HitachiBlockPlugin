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

# Exercise the REAL argv untaint in _run_cmd (not a local copy of its regex):
# internal command names, flags, device paths and WWIDs are accepted; shell
# metacharacters / spaces croak BEFORE any exec. Calling the real sub means this
# fails if the allowed charset ever drifts.
my $run_cmd = \&PVE::Storage::HitachiBlock::Multipath::_run_cmd;

# Accept: a device path argument survives untaint and is exec'd (echo is on
# _run_cmd's hardened PATH); the echoed output proves the arg was accepted.
my $devpath = '/dev/mapper/360060e8021a789005060a78900000100';
is($run_cmd->('echo', $devpath), "$devpath\n",
   'argv untaint accepts a device path (real _run_cmd execs echo)');
# `true` ignores its args and exits 0 — no croak means a flag and a bare wwid
# both passed untaint.
is($run_cmd->('true', '--getsize64', '360060e8021a789005060a78900000100'), '',
   'argv untaint accepts a flag and a bare wwid (real _run_cmd)');

# Reject: unsafe arguments croak before exec.
for my $bad ('foo; rm -rf /', 'a b', '$(whoami)', 'x|y', "a\nb") {
    eval { $run_cmd->('echo', $bad) };
    like($@, qr/refusing to exec invalid\/tainted argument/,
         "argv untaint rejects unsafe '$bad' (real _run_cmd)");
}

# Exercise the REAL host-number untaint in rescan_scsi_targeted: a non-numeric
# host croaks before any sysfs write. (rescan_scsi_hosts' glob-path untaint
# cannot be driven without a udevadm exec side-effect, so its pattern is covered
# by a source drift-alarm below rather than a re-encoded regex.)
my $mp_taint = PVE::Storage::HitachiBlock::Multipath->new();
eval { $mp_taint->rescan_scsi_targeted('bad:0:0:5') };
like($@, qr/invalid host in hctl/, 'rescan_scsi_targeted untaints the host number (real)');

# Drift alarm (tracks the real source, not a copy of its logic): rescan_scsi_hosts
# must keep untainting the tainted glob() path against the exact sysfs host shape.
my $mp_src = do {
    local $/;
    open my $fh, '<', 'src/PVE/Storage/HitachiBlock/Multipath.pm'
        or die "open Multipath.pm: $!";
    <$fh>;
};
like($mp_src, qr{scsi_host/host\\d\+\)\\z},
     'rescan_scsi_hosts untaints the glob path to the /sys/class/scsi_host/hostN shape');

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
