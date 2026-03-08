package PVE::Storage::HitachiBlock::Config;

use strict;
use warnings;

use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);
use Carp qw(croak);

my $CREDS_DIR    = '/etc/pve/priv/hitachiblock';
my $REGISTRY_DIR = '/etc/pve/priv/hitachiblock';

# Platform defaults
my %PLATFORM_DEFAULTS = (
    vsp_g   => { port => 23451 },
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
    return decode_json($content);
}

sub save_registry {
    my ($self, $registry) = @_;

    croak "registry must be a hashref" unless ref $registry eq 'HASH';

    my $file = $self->_registry_file();
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;

    open(my $fh, '>', $file) or croak "Cannot write registry $file: $!";
    flock($fh, LOCK_EX);
    print $fh encode_json($registry);
    close($fh);

    return 1;
}

sub register_ldev {
    my ($self, $volname, $ldev_id, %meta) = @_;

    croak "volname is required"  unless $volname;
    croak "ldev_id is required"  unless defined $ldev_id;

    my $registry = $self->load_registry();
    $registry->{$volname} = {
        ldev_id => int($ldev_id),
        %meta,
    };
    $self->save_registry($registry);

    return 1;
}

sub unregister_ldev {
    my ($self, $volname) = @_;

    croak "volname is required" unless $volname;

    my $registry = $self->load_registry();
    delete $registry->{$volname};
    $self->save_registry($registry);

    return 1;
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

    my $registry = $self->load_registry();
    croak "Volume '$volname' not in registry" unless $registry->{$volname};

    $registry->{$volname}{snapshots} //= {};
    $registry->{$volname}{snapshots}{$snapname} = {
        timestamp => time(),
        %meta,
    };
    $self->save_registry($registry);

    return 1;
}

sub unregister_snapshot {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    my $registry = $self->load_registry();
    if ($registry->{$volname} && $registry->{$volname}{snapshots}) {
        delete $registry->{$volname}{snapshots}{$snapname};
        # Clean up empty snapshots hash
        delete $registry->{$volname}{snapshots}
            unless %{$registry->{$volname}{snapshots}};
    }
    $self->save_registry($registry);

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

    if ($config->{mgmt_ip} && $config->{mgmt_ip} !~ /^[\d.]+$/ && $config->{mgmt_ip} !~ /^[a-zA-Z0-9._-]+$/) {
        push @errors, "mgmt_ip must be a valid IP address or hostname";
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

sub make_label {
    my ($class, $storeid, $volname) = @_;
    return "pve:${storeid}:${volname}";
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

1;
