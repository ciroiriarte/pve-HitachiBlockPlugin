#!/usr/bin/perl

# Drift guard for the shipped qemu-pr-helper systemd units (issue #2).
#
# The plugin's check_pr_ready keys off the socket PATH ($PR_HELPER_SOCK in
# Multipath.pm). We ship the qemu-pr-helper.socket unit ourselves (Proxmox's
# pve-qemu-kvm provides the binary but not the units). This test keeps the unit's
# ListenStream, the code's socket path, the Makefile install, and the
# ship-disabled packaging in sync so they can't silently drift apart.

use strict;
use warnings;
use Test::More;

sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "cannot open $f: $!";
    local $/;
    return <$fh>;
}

my $socket_unit  = 'conf/systemd/qemu-pr-helper.socket';
my $service_unit = 'conf/systemd/qemu-pr-helper.service';

ok(-f $socket_unit,  'qemu-pr-helper.socket unit is shipped in the repo');
ok(-f $service_unit, 'qemu-pr-helper.service unit is shipped in the repo');

my $sock_src = slurp($socket_unit);
my ($listen) = $sock_src =~ /^\s*ListenStream\s*=\s*(\S+)/m;
is($listen, '/run/qemu-pr-helper.sock', 'socket ListenStream is the qemu default path');
like($sock_src, qr/^\s*WantedBy\s*=\s*sockets\.target/m, 'socket installs into sockets.target');

# The code's readiness check must look at exactly the path the unit listens on.
my $mp_src = slurp('src/PVE/Storage/HitachiBlock/Multipath.pm');
my ($code_sock) = $mp_src =~ /\$PR_HELPER_SOCK\s*=\s*'([^']+)'/;
is($code_sock, $listen,
    'Multipath $PR_HELPER_SOCK matches the unit ListenStream (no drift)');

my $svc_src = slurp($service_unit);
like($svc_src, qr{^\s*ExecStart\s*=\s*/usr/bin/qemu-pr-helper}m,
    'service ExecStarts the pve-qemu-kvm helper binary');

# Packaging: the units are shipped (Makefile) but installed DISABLED (rules).
my $mk = slurp('Makefile');
like($mk, qr/SYSTEMD_UNITS\s*=.*qemu-pr-helper\.socket/,
    'Makefile installs the qemu-pr-helper units');
like($mk, qr{install .*\$\(SYSTEMD_UNITS\) \$\(DESTDIR\)\$\(SYSTEMD_UNIT_DIR\)},
    'Makefile install target copies the units into the systemd unit dir');

my $rules = slurp('debian/rules');
like($rules, qr/dh_installsystemd\s+--no-enable\s+--no-start/,
    'debian/rules ships the units DISABLED (opt-in: no auto enable/start)');

done_testing();
