package PVE::Storage::HitachiBlock::Config;

use strict;
use warnings;

use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);
use IO::Handle;
use Digest::MD5 qw(md5_hex);
use Carp qw(croak);

# Hitachi LDEV labels are limited to 32 characters on most VSP models.
my $MAX_LABEL_LEN = 32;

my $CREDS_DIR    = '/etc/pve/priv/hitachiblock';
my $REGISTRY_DIR = '/etc/pve/priv/hitachiblock';

# Seconds to wait for the cluster registry lock before giving up.
my $REGISTRY_LOCK_TIMEOUT = 10;

# Platform defaults. Ports reflect the documented Configuration Manager REST API
# endpoints: 443 for the array's embedded/direct REST server (VSP One and the
# VSP E/G midrange GUM), 23451 for a dedicated Ops Center Configuration Manager
# server fronting the array.
my %PLATFORM_DEFAULTS = (
    vsp_g   => { port => 23451 },
    vsp_e   => { port => 443 },
    vsp_one => { port => 443 },
);

sub new {
    my ($class, %opts) = @_;

    croak "storeid is required" unless $opts{storeid};

    return bless {
        storeid => $opts{storeid},
    }, $class;
}

# ── Credential Management ──

sub store_credentials {
    my ($self, $username, $password) = @_;

    croak "username is required" unless $username;
    croak "password is required" unless $password;

    my $file = $self->_creds_file();
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;
    open(my $fh, '>', $file) or croak "Cannot write credentials to $file: $!";
    chmod(0600, $file);
    print $fh encode_json({ username => $username, password => $password });
    close($fh);

    return 1;
}

sub read_credentials {
    my ($self) = @_;

    my $file = $self->_creds_file();
    croak "Credentials file not found: $file" unless -f $file;

    open(my $fh, '<', $file) or croak "Cannot read credentials from $file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    my $creds = decode_json($content);
    croak "Invalid credentials file: missing username" unless $creds->{username};
    croak "Invalid credentials file: missing password" unless $creds->{password};

    return ($creds->{username}, $creds->{password});
}

sub delete_credentials {
    my ($self) = @_;

    my $file = $self->_creds_file();
    unlink($file) if -f $file;

    return 1;
}

# ── LDEV Registry ──
# Maps volname -> ldev_id for quick lookup without querying the array

sub _read_registry_unlocked {
    my ($self) = @_;

    my $file = $self->_registry_file();
    return {} unless -f $file;

    open(my $fh, '<', $file) or croak "Cannot read registry $file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    return {} unless $content && length($content) > 0;

    my $data = eval { decode_json($content) };
    croak "Registry $file is corrupt: $@" if $@;
    return $data;
}

sub _write_registry_atomic {
    my ($self, $registry) = @_;

    my $file = $self->_registry_file();
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;

    # Write to a temp file, fsync, then atomically rename into place so a crash
    # mid-write can never truncate or corrupt the live registry.
    my $tmp = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or croak "Cannot write registry $tmp: $!";
    print $fh encode_json($registry);
    $fh->flush;
    eval { $fh->sync };   # best-effort fsync
    close($fh);

    unless (rename($tmp, $file)) {
        my $err = $!;
        unlink($tmp);
        croak "Cannot commit registry $file: $err";
    }

    return 1;
}

# Run $code under an exclusive, cluster-wide lock with a freshly-loaded registry.
# $code receives the registry hashref, mutates it in place, and may return a value.
# The lock spans the entire read-modify-write so concurrent operations cannot lose
# updates. On a real PVE node the registry lives on pmxcfs and the lock is the
# corosync-backed PVE::Cluster::cfs_lock_file, which DOES serialize across nodes
# (a plain flock on a pmxcfs file would only be local to one node's kernel). Off
# cluster (unit tests / non-pmxcfs paths) it degrades to a local flock.
sub _with_registry_lock {
    my ($self, $code) = @_;

    croak "code must be a coderef" unless ref $code eq 'CODE';

    my $critical = sub {
        my $registry = $self->_read_registry_unlocked();
        my @result = $code->($registry);
        $self->_write_registry_atomic($registry);
        return [@result];
    };

    my $res = $self->_run_locked($critical);
    return wantarray ? @$res : $res->[0];
}

# Acquire the registry mutex (cluster-wide where possible) and run $critical,
# returning its (arrayref) result. Used by every read-modify-write helper.
sub _run_locked {
    my ($self, $critical) = @_;

    if ($self->_use_cluster_lock()) {
        # Use a DEDICATED corosync lock domain for the registry —
        # "domain-hitachiblock-registry-<storeid>" — NOT cfs_lock_storage($storeid).
        # PVE core already wraps vdisk_alloc/vdisk_free/activate_storage and content
        # listing in cluster_lock_storage() == cfs_lock_storage("storage-<storeid>").
        # Re-acquiring that SAME (non-reentrant) lock from inside those operations
        # self-deadlocks, stalling every alloc/free — and even browsing the storage in
        # the GUI — for the full lock timeout. A separate domain still serializes
        # registry mutations cluster-wide (including the hitachiblock-repl CLI, which
        # runs outside any PVE storage lock) without colliding. cfs_lock_* sets $@ and
        # returns undef on in-code failure; returns the coderef's value on success.
        my $res = PVE::Cluster::cfs_lock_domain(
            "hitachiblock-registry-$self->{storeid}", $REGISTRY_LOCK_TIMEOUT, $critical);
        croak "Cannot acquire cluster registry lock: $@" if $@;
        return $res;
    }

    my $lockfile = $self->_lock_file();
    my $dir = dirname($lockfile);
    make_path($dir) unless -d $dir;

    open(my $lock_fh, '>', $lockfile)
        or croak "Cannot open registry lock $lockfile: $!";
    flock($lock_fh, LOCK_EX)
        or croak "Cannot acquire registry lock $lockfile: $!";

    my $res;
    my $ok = eval { $res = $critical->(); 1 };
    my $err = $@;
    close($lock_fh);   # releases the lock
    croak $err unless $ok;

    return $res;
}

# True when the registry is backed by pmxcfs and PVE::Cluster is loadable, so we
# can use the corosync-coordinated cluster lock. Cached after first probe. Unit
# tests redirect the registry to a tempdir, so they always take the flock path.
my $CLUSTER_LOCK_OK;
sub _use_cluster_lock {
    my ($self) = @_;

    return 0 unless $self->_registry_file() =~ m{^/etc/pve/};

    return $CLUSTER_LOCK_OK if defined $CLUSTER_LOCK_OK;
    $CLUSTER_LOCK_OK = eval {
        require PVE::Cluster;
        PVE::Cluster->can('cfs_lock_domain') ? 1 : 0;
    } || 0;
    return $CLUSTER_LOCK_OK;
}

sub load_registry {
    my ($self) = @_;

    my $file = $self->_registry_file();
    return {} unless -f $file;

    open(my $fh, '<', $file) or croak "Cannot read registry $file: $!";
    flock($fh, LOCK_SH);
    local $/;
    my $content = <$fh>;
    close($fh);

    return {} unless $content && length($content) > 0;
    my $data = eval { decode_json($content) };
    croak "Registry $file is corrupt: $@" if $@;
    return $data;
}

sub register_ldev {
    my ($self, $volname, $ldev_id, %meta) = @_;

    croak "volname is required"  unless $volname;
    croak "ldev_id is required"  unless defined $ldev_id;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        my $existing = (ref $reg->{$volname} eq 'HASH') ? $reg->{$volname} : {};
        # Enforce a stable volname <-> ldev_id identity: a committed entry must
        # never be silently retargeted to a different LDEV (that would orphan the
        # old one and point the volid at the wrong data). Re-registering the same
        # ldev_id (resize, pool change) is fine.
        if (defined $existing->{ldev_id} && !$existing->{reserved}
            && int($existing->{ldev_id}) != int($ldev_id)) {
            croak "Registry conflict: '$volname' already maps to LDEV "
                . "$existing->{ldev_id}; refusing to retarget to $ldev_id";
        }
        # Merge over any existing entry (preserves snapshots / parent links unless
        # overridden) and clear the reservation marker now that the LDEV is real.
        my %entry = (%$existing, ldev_id => int($ldev_id), %meta);
        delete $entry{reserved};
        $reg->{$volname} = \%entry;
        return;
    });

    return 1;
}

# Merge arbitrary metadata keys into an existing volume's registry entry without
# touching its ldev_id — used for per-volume attributes like `protected`/`notes`
# (#15). A key whose value is undef is removed. Croaks if the volume is unknown.
# Runs under the registry lock so it is cluster-safe and replicates across nodes.
sub update_meta {
    my ($self, $volname, %meta) = @_;

    croak "volname is required" unless $volname;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        my $entry = $reg->{$volname};
        croak "Volume '$volname' not in registry" unless ref $entry eq 'HASH';
        for my $k (keys %meta) {
            if (defined $meta{$k}) {
                $entry->{$k} = $meta{$k};
            } else {
                delete $entry->{$k};
            }
        }
        return;
    });

    return 1;
}

# Return the volname currently mapped to $ldev_id, or undef. Used to reject
# importing/managing an LDEV that is already tracked under another name.
sub find_volname_by_ldev {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $reg = $self->load_registry();
    for my $name (keys %$reg) {
        my $e = $reg->{$name};
        next unless ref $e eq 'HASH' && defined $e->{ldev_id};
        return $name if int($e->{ldev_id}) == int($ldev_id);
    }
    return undef;
}

sub unregister_ldev {
    my ($self, $volname) = @_;

    croak "volname is required" unless $volname;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        delete $reg->{$volname};
        return;
    });

    return 1;
}

# Atomically reserve the next free volume name for a VMID and insert a placeholder
# entry so concurrent allocations (same or other node) cannot pick the same name.
# Pass base => 1 to reserve a base-volume name. The reservation is finalized by a
# later register_ldev() or released by unregister_ldev() on failure.
sub reserve_volname {
    my ($self, $vmid, %opts) = @_;

    croak "vmid is required" unless defined $vmid;
    my $prefix = $opts{base} ? 'base' : 'vm';

    return $self->_with_registry_lock(sub {
        my ($reg) = @_;
        my $max = 0;
        for my $name (keys %$reg) {
            if ($name =~ /^(?:vm|base)-${vmid}-disk-(\d+)$/) {
                $max = $1 if $1 > $max;
            }
        }
        my $name = "${prefix}-${vmid}-disk-" . ($max + 1);
        $reg->{$name} = { reserved => 1, timestamp => time() };
        return $name;
    });
}

# Atomically rename a registry entry (used by create_base: vm-... -> base-...).
sub rename_volume {
    my ($self, $old_volname, $new_volname) = @_;

    croak "old_volname is required" unless $old_volname;
    croak "new_volname is required" unless $new_volname;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        croak "Volume '$old_volname' not in registry" unless $reg->{$old_volname};
        croak "Volume '$new_volname' already exists"   if $reg->{$new_volname};
        $reg->{$new_volname} = delete $reg->{$old_volname};
        return;
    });

    return 1;
}

# Return an arrayref of volnames that list $volname as their parent (linked clones).
sub find_dependents {
    my ($self, $volname) = @_;

    my $reg = $self->load_registry();
    my @deps;
    for my $name (keys %$reg) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless ref $entry eq 'HASH';
        push @deps, $name if defined $entry->{parent_volname}
            && $entry->{parent_volname} eq $volname;
    }
    return \@deps;
}

# Return an arrayref of volnames that were cloned from a specific snapshot of
# $volname (they record parent_volname + parent_snap). Used to refuse deletion
# of a snapshot whose S-VOL still backs linked clones.
sub find_snapshot_dependents {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    my $reg = $self->load_registry();
    my @deps;
    for my $name (keys %$reg) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless ref $entry eq 'HASH';
        push @deps, $name
            if defined $entry->{parent_volname} && $entry->{parent_volname} eq $volname
            && defined $entry->{parent_snap}    && $entry->{parent_snap}    eq $snapname;
    }
    return \@deps;
}

sub lookup_ldev {
    my ($self, $volname) = @_;

    my $registry = $self->load_registry();
    my $entry = $registry->{$volname};
    return undef unless $entry;

    return wantarray ? ($entry->{ldev_id}, $entry) : $entry->{ldev_id};
}

sub list_registered {
    my ($self) = @_;

    return $self->load_registry();
}

# ── Snapshot Registry ──
# Stores snapshot metadata per volume: volname -> { snapname -> { svol_ldev_id, timestamp, ... } }

sub register_snapshot {
    my ($self, $volname, $snapname, %meta) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        croak "Volume '$volname' not in registry" unless $reg->{$volname};

        $reg->{$volname}{snapshots} //= {};
        $reg->{$volname}{snapshots}{$snapname} = {
            timestamp => time(),
            %meta,
        };
        return;
    });

    return 1;
}

# Rename a snapshot's registry key, preserving its metadata (#34). Croaks if the
# source is missing or the target already exists. Runs under the registry lock so
# it is cluster-safe.
sub rename_snapshot {
    my ($self, $volname, $source, $target) = @_;

    croak "volname is required"        unless $volname;
    croak "source snapname is required" unless $source;
    croak "target snapname is required" unless $target;
    return 1 if $source eq $target;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        my $snaps = $reg->{$volname} && $reg->{$volname}{snapshots};
        croak "snapshot '$source' not found for '$volname'"
            unless $snaps && $snaps->{$source};
        croak "target snapshot '$target' already exists for '$volname'"
            if $snaps->{$target};
        $snaps->{$target} = delete $snaps->{$source};
        return;
    });

    return 1;
}

sub unregister_snapshot {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    $self->_with_registry_lock(sub {
        my ($reg) = @_;
        if ($reg->{$volname} && $reg->{$volname}{snapshots}) {
            delete $reg->{$volname}{snapshots}{$snapname};
            # Clean up empty snapshots hash
            delete $reg->{$volname}{snapshots}
                unless %{$reg->{$volname}{snapshots}};
        }
        return;
    });

    return 1;
}

sub lookup_snapshot {
    my ($self, $volname, $snapname) = @_;

    my $registry = $self->load_registry();
    my $entry = $registry->{$volname} or return undef;
    my $snaps = $entry->{snapshots}   or return undef;

    return $snaps->{$snapname};
}

sub list_snapshots {
    my ($self, $volname) = @_;

    my $registry = $self->load_registry();
    my $entry = $registry->{$volname} or return {};

    return $entry->{snapshots} || {};
}

# ── Platform Defaults ──

sub platform_defaults {
    my ($class, $platform) = @_;

    $platform //= 'vsp_one';
    return $PLATFORM_DEFAULTS{$platform} || $PLATFORM_DEFAULTS{vsp_one};
}

# ── Validation ──

sub validate_config {
    my ($class, $config) = @_;

    my @errors;

    push @errors, "mgmt_ip is required"    unless $config->{mgmt_ip};
    push @errors, "storage_id is required" unless $config->{storage_id};
    push @errors, "pool_id is required"    unless defined $config->{pool_id};
    push @errors, "target_ports is required" unless $config->{target_ports};

    # mgmt_ip may be a comma-separated list of per-controller endpoints; validate
    # each entry as an IP address or hostname.
    if ($config->{mgmt_ip}) {
        my @hosts = grep { length } map { s/^\s+|\s+$//gr } split(/,/, $config->{mgmt_ip});
        push @errors, "mgmt_ip must contain at least one IP address or hostname"
            unless @hosts;
        for my $h (@hosts) {
            next if $h =~ /^[\d.]+$/ || $h =~ /^[a-zA-Z0-9._-]+$/;
            push @errors, "mgmt_ip entry '$h' is not a valid IP address or hostname";
        }
    }

    if (defined $config->{pool_id} && $config->{pool_id} !~ /^\d+$/) {
        push @errors, "pool_id must be a non-negative integer";
    }

    if ($config->{platform} && !exists $PLATFORM_DEFAULTS{$config->{platform}}) {
        push @errors, "platform must be one of: " . join(', ', sort keys %PLATFORM_DEFAULTS);
    }

    if ($config->{ldev_range}) {
        my $r = $config->{ldev_range};
        unless ($r =~ /^(0x[0-9a-fA-F]+|\d+)-(0x[0-9a-fA-F]+|\d+)$/) {
            push @errors, "ldev_range must be 'min-max' (decimal or 0x hex), got '$r'";
        }
    }

    croak "Configuration errors: " . join('; ', @errors) if @errors;

    return 1;
}

# ── Volume Name Helpers ──

# The label prefix used to tag and discover LDEVs owned by a given storage.
# When "pve:<storeid>:" plus a typical volname would exceed the array's 32-char
# label limit, the storeid is replaced by a stable 8-char hash so labels stay
# unique, within bounds, and consistently matchable by orphan detection.
sub label_prefix {
    my ($class, $storeid) = @_;

    my $full = "pve:${storeid}:";
    # Reserve room for the volume name (e.g. "vm-999999999-disk-99" ~ 20 chars).
    return $full if length($full) + 20 <= $MAX_LABEL_LEN;

    my $hash = substr(md5_hex($storeid), 0, 8);
    return "pve:${hash}:";
}

sub make_label {
    my ($class, $storeid, $volname) = @_;

    my $label = $class->label_prefix($storeid) . $volname;
    # Final safety clamp; volnames are short so this is effectively never hit.
    $label = substr($label, 0, $MAX_LABEL_LEN) if length($label) > $MAX_LABEL_LEN;
    return $label;
}

sub parse_label {
    my ($class, $label) = @_;

    return undef unless $label;

    if ($label =~ /^pve:([^:]+):(.+)$/) {
        return { storeid => $1, volname => $2 };
    }

    return undef;
}

# ── Internal ──

sub _creds_file {
    my ($self) = @_;
    return "$CREDS_DIR/$self->{storeid}.creds";
}

sub _registry_file {
    my ($self) = @_;
    return "$REGISTRY_DIR/$self->{storeid}.json";
}

sub _lock_file {
    my ($self) = @_;
    return $self->_registry_file() . '.lock';
}

1;
