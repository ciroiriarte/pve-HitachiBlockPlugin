package PVE::Storage::HitachiBlock::Multipath;

use strict;
use warnings;

use POSIX ();
use Carp qw(croak);

my $RESCAN_TIMEOUT  = 30;
my $DEVICE_TIMEOUT  = 60;
my $POLL_INTERVAL   = 2;

sub new {
    my ($class, %opts) = @_;

    return bless {
        timeout => $opts{timeout} || $DEVICE_TIMEOUT,
    }, $class;
}

# ── FC WWN Discovery ──

sub get_local_wwns {
    my ($self) = @_;

    my @wwns;
    my @hosts = glob('/sys/class/fc_host/host*');

    for my $host_path (@hosts) {
        my $port_name_file = "$host_path/port_name";
        next unless -r $port_name_file;

        open(my $fh, '<', $port_name_file) or next;
        my $wwn = <$fh>;
        close($fh);

        chomp($wwn);
        # port_name is typically "0x50060b0000c26040" - strip 0x prefix
        $wwn =~ s/^0x//i;
        push @wwns, lc($wwn) if $wwn;
    }

    return \@wwns;
}

# ── SCSI Rescan ──

sub rescan_scsi_hosts {
    my ($self, %opts) = @_;

    my @hosts = glob('/sys/class/scsi_host/host*');
    croak "No SCSI hosts found" unless @hosts;

    for my $host_path (@hosts) {
        # glob() returns TAINTED paths; pct runs in taint mode (-T), which forbids
        # write-open on tainted data. Untaint by validating the sysfs shape.
        next unless $host_path =~ m{^(/sys/class/scsi_host/host\d+)\z};
        my $scan_file = "$1/scan";
        next unless -w $scan_file;

        open(my $fh, '>', $scan_file) or next;
        print $fh "- - -\n";
        close($fh);
    }

    # Allow udev to settle
    _run_cmd('udevadm', 'settle', '--timeout=10');

    return 1;
}

sub rescan_scsi_targeted {
    my ($self, $hctl) = @_;

    # hctl format: "host:channel:target:lun" e.g. "3:0:0:5"
    croak "hctl is required" unless $hctl;

    my ($host, $channel, $target, $lun) = split(/:/, $hctl);
    # Untaint the host number (taint mode forbids write-open with tainted data).
    ($host) = ($host // '') =~ /^(\d+)$/
        or croak "invalid host in hctl '$hctl'";
    my $scan_file = "/sys/class/scsi_host/host${host}/scan";

    if (-w $scan_file) {
        open(my $fh, '>', $scan_file) or croak "Cannot write to $scan_file: $!";
        print $fh "$channel $target $lun\n";
        close($fh);
    }

    _run_cmd('udevadm', 'settle', '--timeout=10');

    return 1;
}

# ── Device Path Resolution ──

sub wait_for_device {
    my ($self, $wwid, $timeout) = @_;

    $timeout //= $self->{timeout};
    my $path = $self->get_device_path($wwid);

    # Whitelist the WWID and (re)assemble the map up front. PVE ships multipath
    # with `find_multipaths strict` by default, where ONLY WWIDs explicitly listed
    # in /etc/multipath/wwids are turned into /dev/mapper devices — so without this
    # the device would never appear, even with all paths present.
    $self->whitelist_wwid($wwid);
    eval { _run_cmd('multipath', '-r') };

    my $elapsed = 0;
    while ($elapsed < $timeout) {
        if (-e $path) {
            # Ensure multipath has assembled the device
            eval { _run_cmd('multipathd', 'reconfigure') };
            if (-e $path) {
                return $path;
            }
        }

        sleep($POLL_INTERVAL);
        $elapsed += $POLL_INTERVAL;

        # Trigger multipath re-evaluation
        eval { _run_cmd('multipath', '-r') } if $elapsed % 6 == 0;
    }

    croak "Device $path did not appear within ${timeout}s";
}

# Whitelist a device WWID with multipath-tools (append to /etc/multipath/wwids)
# so it is assembled into a /dev/mapper device even under `find_multipaths strict`.
# Idempotent and best-effort: `multipath -a` can exit non-zero when the entry
# already exists or the device is not yet visible, which must not be fatal.
sub whitelist_wwid {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless $wwid;

    my $dm_wwid = $wwid;
    $dm_wwid = "3$wwid" unless $dm_wwid =~ /^3/;

    eval { _run_cmd('multipath', '-a', $dm_wwid) };
    warn "multipath -a $dm_wwid warning: $@" if $@;

    return $dm_wwid;
}

sub get_device_path {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless $wwid;

    # Normalize: multipath uses 3<naa_id> format for SCSI devices
    my $dm_wwid = $wwid;
    $dm_wwid = "3$wwid" unless $dm_wwid =~ /^3/;

    # Untaint: the wwid comes from the registry file / sysfs (tainted). PVE runs
    # mkfs/mount on this path via exec, which dies "Insecure dependency" under
    # pct's taint mode if the path is tainted. A WWID is hex only.
    $dm_wwid =~ /^(3[0-9a-fA-F]+)$/
        or croak "invalid multipath wwid '$wwid'";

    return "/dev/mapper/$1";
}

sub get_device_size {
    my ($self, $path) = @_;

    croak "path is required"      unless $path;
    croak "Device $path not found" unless -e $path;

    my $size = _run_cmd('blockdev', '--getsize64', $path);
    chomp($size);

    return int($size);
}

# ── Device Lifecycle ──

sub remove_device {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless $wwid;

    my $dm_wwid = $wwid;
    $dm_wwid = "3$wwid" unless $dm_wwid =~ /^3/;

    # Flush multipath map
    eval { _run_cmd('multipath', '-f', $dm_wwid) };

    # Drop the WWID from /etc/multipath/wwids so the whitelist does not accumulate
    # stale entries (best-effort: -w is unavailable on older multipath-tools).
    # `multipath -w` only COMMENTS the entry, and repeated activate/free cycles
    # leave accumulating duplicate "#<wwid>" lines — prune them (the LUN is gone).
    eval { _run_cmd('multipath', '-w', $dm_wwid) };
    eval { $self->_prune_wwid_entries($dm_wwid) };

    # Find and remove underlying SCSI devices
    my @sd_devs = glob("/sys/block/sd*/device/wwid");
    for my $wwid_file (@sd_devs) {
        open(my $fh, '<', $wwid_file) or next;
        my $dev_wwid = <$fh>;
        close($fh);
        chomp($dev_wwid);

        # Match NAA identifier
        if ($dev_wwid =~ /\Q$wwid\E/i) {
            my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
            next unless $sd_name;

            my $delete_file = "/sys/block/$sd_name/device/delete";
            if (-w $delete_file) {
                open(my $dfh, '>', $delete_file) or next;
                print $dfh "1\n";
                close($dfh);
            }
        }
    }

    # Let the kernel finish tearing the paths down before the caller unmaps on the
    # array: while the SCSI devices are still draining, the array reports "the LU
    # is executing host I/O" and refuses the unmap. Settling here shrinks that
    # window so the unmap retry loop succeeds sooner (or first try with HMO 91).
    eval { _run_cmd('udevadm', 'settle', '--timeout=10') };

    return 1;
}

# Remove every /etc/multipath/wwids line referencing $wwid (commented or active).
# `multipath -w` comments the entry instead of deleting it, so repeated
# activate/free cycles pile up duplicate "#<wwid>/" lines; once the LUN is freed
# the entry is pure cruft. Best-effort, atomic, taint-safe (the path is a
# constant and the wwid is validated to hex before use).
sub _prune_wwid_entries {
    my ($self, $wwid, $file) = @_;

    $file //= '/etc/multipath/wwids';
    return unless defined $wwid && $wwid =~ /^3?([0-9a-fA-F]+)$/;
    my $bare = $1;
    return unless -f $file && -w $file;

    open(my $in, '<', $file) or return;
    my @keep = grep { !/\Q$bare\E/ } <$in>;
    close($in);

    my $tmp = "$file.tmp.$$";
    open(my $out, '>', $tmp) or return;
    print $out @keep;
    close($out);
    rename($tmp, $file) or unlink($tmp);

    return 1;
}

sub resize_device {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless $wwid;

    my $dm_wwid = $wwid;
    $dm_wwid = "3$wwid" unless $dm_wwid =~ /^3/;

    # Rescan all SCSI paths for this device to pick up new size
    my @sd_devs = glob("/sys/block/sd*/device/wwid");
    for my $wwid_file (@sd_devs) {
        open(my $fh, '<', $wwid_file) or next;
        my $dev_wwid = <$fh>;
        close($fh);
        chomp($dev_wwid);

        if ($dev_wwid =~ /\Q$wwid\E/i) {
            my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
            next unless $sd_name;

            my $rescan_file = "/sys/block/$sd_name/device/rescan";
            if (-w $rescan_file) {
                open(my $rfh, '>', $rescan_file) or next;
                print $rfh "1\n";
                close($rfh);
            }
        }
    }

    # Tell multipathd to resize the DM device
    _run_cmd('multipathd', 'resize', 'map', $dm_wwid);

    return 1;
}

sub flush_device {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless $wwid;

    my $dm_wwid = $wwid;
    $dm_wwid = "3$wwid" unless $dm_wwid =~ /^3/;

    my $path = "/dev/mapper/$dm_wwid";
    if (-e $path) {
        eval { _run_cmd('blockdev', '--flushbufs', $path) };
        warn "blockdev flush warning: $@" if $@;
    }

    return 1;
}

# ── WWID Helpers ──

sub ldev_to_wwid {
    my ($self, $storage_serial, $ldev_id) = @_;

    croak "storage_serial is required" unless $storage_serial;
    croak "ldev_id is required"        unless defined $ldev_id;

    # Hitachi NAA format: 60060e80<serial_hex><ldev_hex>
    # The exact format depends on the array model; this is the common VSP pattern
    # NAA 6: 6006 0e80 <8-char serial> <4-char ldev_hex> <pad>
    my $ldev_hex = sprintf("%04x", $ldev_id);

    # Normalize serial to expected hex format (lowercase, no colons)
    my $serial_clean = lc($storage_serial);
    $serial_clean =~ s/[^0-9a-f]//g;

    # Untaint: $storage_serial comes from storage.cfg (tainted) and this value is
    # used to build device paths PVE execs on. The result is hex only.
    my ($wwid) = lc("60060e80${serial_clean}${ldev_hex}0000000000000000") =~ /^([0-9a-f]+)$/;
    return $wwid;
}

# Discover the REAL WWID of a just-mapped LDEV by scanning syssfs, rather than
# trusting the synthesized NAA (whose exact byte layout varies across VSP models).
# Returns the normalized lowercase WWID (no 'naa.'/'0x' prefix) of a HITACHI
# device whose page-83 identifier encodes the given LDEV id, or undef if none is
# found yet. Used as a self-correcting fallback when the synthesized WWID does
# not resolve to a device.
sub discover_wwid {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;
    my $ldev_hex = sprintf("%04x", $ldev_id);

    my %seen;
    my @candidates;
    for my $wwid_file (glob('/sys/block/sd*/device/wwid')) {
        my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
        next unless $sd_name;

        my $wwid = _read_first_line($wwid_file);
        next unless defined $wwid;
        $wwid =~ s/^naa\.//i;
        $wwid =~ s/^0x//i;
        $wwid = lc($wwid);

        # Hitachi exports NAA-6 identifiers under the IEEE OUI 0x006 0e80.
        next unless $wwid =~ /^60060e80/;

        my $vendor = _read_first_line("/sys/block/$sd_name/device/vendor") // '';
        next unless $vendor eq '' || $vendor =~ /HITACHI/i;

        # The LDEV id is encoded within the identifier.
        next unless $wwid =~ /\Q$ldev_hex\E/;

        push @candidates, $wwid unless $seen{$wwid}++;
    }

    return $candidates[0];   # undef if nothing matched yet
}

# ── Internal Helpers ──

sub _read_first_line {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless defined $line;
    chomp($line);
    return $line;
}

sub _run_cmd {
    my (@cmd) = @_;

    # Taint safety: pct runs the storage layer in taint mode (-T), which refuses
    # exec with a tainted $ENV{PATH} or tainted argv. Use a known-good PATH and
    # untaint each argument against a conservative charset. These are internal
    # command names, flags, device paths and WWIDs we construct — never user
    # free-text — so validating the shape is sufficient.
    local $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
    @cmd = map {
        $_ =~ /^([\w\@%+=:,.\/-]+)$/
            ? $1
            : croak "refusing to exec invalid/tainted argument: $_";
    } @cmd;

    # Execute without a shell (list form) to avoid quoting/injection issues and
    # to capture combined stdout/stderr reliably.
    my $pid = open(my $fh, '-|');
    croak "Cannot fork for '@cmd': $!" unless defined $pid;

    my $output = '';
    if ($pid) {
        local $/;
        my $data = <$fh>;
        $output = $data if defined $data;
        close($fh);
    } else {
        open(STDERR, '>&', \*STDOUT);
        # _exit (not die/exit) avoids running parent destructors if exec fails.
        { exec { $cmd[0] } @cmd };
        print "exec '$cmd[0]' failed: $!";
        POSIX::_exit(127);
    }

    my $rc = $? >> 8;
    croak "Command '@cmd' failed (rc=$rc): $output" if $rc != 0;

    return $output;
}

1;
