package PVE::Storage::Custom::HitachiBlockPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use PVE::Storage::HitachiBlock::RestClient;
use PVE::Storage::HitachiBlock::Multipath;
use PVE::Storage::HitachiBlock::Config;

use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command);

use POSIX qw(ceil);

# Minimum DP-VOL capacity the array will create. Verified live on a VSP E590H:
# `POST /ldevs` with byteFormatCapacity <= 46 MiB fails the async job with
# "It cannot create because the capacity is invalid."; >= 47 MiB succeeds. We
# floor sub-minimum allocations (PVE vTPM state = 4 MiB, EFI vars, tiny disks)
# to 48 MiB for margin. DP-VOLs are thin, so the floored logical size consumes
# pool pages only on write — the floor costs ~0 real capacity.
my $MIN_LDEV_MB = 48;

# An LDEV id is a CU:LDEV pair: CU = id >> 8, ldev-in-CU = id & 0xFF, so each
# Control Unit spans exactly 256 LDEV ids. A CU-aligned ldev_range reserves
# whole CUs (clean multi-tenant separation) and pages optimally — the array's
# GET /ldevs window is one CU wide, so each CU costs exactly one REST call.
my $LDEVS_PER_CU = 256;

# On free, after the host-side device is torn down the array can still report
# "the LU is executing host I/O" for a while (multipathd's path checker drains),
# refusing the unmap. Retry the unmap this many times (×3s backoff ≈ 45s) before
# giving up — long enough to cover a just-stopped, recently-busy guest. With the
# skip_unmap_io_check option (HMO 91) the first attempt succeeds and this is moot.
my $UNMAP_IO_RETRIES = 15;

# ── Plugin Identity ──

sub api {
    # Storage plugin API version this module targets. PVE 9.x is at APIVER 14
    # (APIAGE 5, so it accepts 9..14); claiming the current APIVER silences the
    # "older storage API" advisory. We conform to 14 by: handling credentials via
    # sensitive properties (plugindata 'sensitive-properties' + %sensitive in the
    # add/update hooks), declaring volume_qemu_snapshot_method, and relying on the
    # base qemu_blockdev_options() default (correct for our /dev/mapper block path).
    # The authoritative contract is the in-tree PVE::Storage::Plugin perldoc, not
    # the wiki. Bump in lockstep after verifying overridden method signatures.
    return 14;
}

sub type {
    return 'hitachiblock';
}

sub plugindata {
    return {
        # images = VM disks; rootdir = LXC container rootfs (PVE formats and mounts
        # the raw LUN, like the LVM-thin block model). Default content = images.
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }  , 'raw' ],
        # `password` is a sensitive property: PVE never writes it to storage.cfg
        # and passes it to the add/update hooks via %sensitive. (username is a
        # normal property kept in storage.cfg.)
        'sensitive-properties' => { password => 1 },
    };
}

# ── Configuration Schema ──

sub properties {
    return {
        mgmt_ip => {
            description => "Management IP/hostname of the Configuration Manager REST API"
                . " endpoint — the array's embedded/GUM controller (direct connection) or a"
                . " dedicated Ops Center Configuration Manager server. May be a"
                . " comma-separated list of per-controller endpoints (e.g. 'CTL1,CTL2') for"
                . " management-plane failover; a single floating VIP needs only one entry.",
            type        => 'string',
        },
        storage_id => {
            description => "Storage device ID (storageDeviceId) of the array, e.g. the"
                . " 12-digit model+serial id returned by GET /v1/objects/storages — not"
                . " the bare serial number.",
            type        => 'string',
        },
        pool_id => {
            description => "DP pool ID for LDEV allocation.",
            type        => 'integer',
            minimum     => 0,
        },
        snap_pool_id => {
            description => "Pool ID for snapshot S-VOL allocation (defaults to pool_id).",
            type        => 'integer',
            minimum     => 0,
            optional    => 1,
        },
        target_ports => {
            description => "Comma-separated list of target FC port IDs (e.g. CL1-A,CL2-A).",
            type        => 'string',
        },
        host_mode => {
            description => "Host mode for host group creation.",
            type        => 'string',
            default     => 'LINUX/IRIX',
            optional    => 1,
        },
        host_mode_options => {
            description => "Comma-separated Hitachi host mode option numbers set on the"
                . " host groups the plugin creates. Default '2,22,25,68' is Hitachi's"
                . " best-practice set for the LINUX/IRIX (00 Standard) host mode:"
                . " 68 = WRITE SAME / SCSI ANSI v5 support (Page Reclamation for Linux,"
                . " advertises SCSI UNMAP so thin pools reclaim on in-guest fstrim);"
                . " 2/22/25 = VERITAS Database Edition-Advanced Cluster / Veritas Cluster"
                . " Server / SPC-3 Persistent Reservation reservation-compatibility. On"
                . " VSP One Block 2/22/25 are already default-on (no-ops), but they are"
                . " set explicitly to cover older arrays (VSP E series, VSP 5000) where"
                . " they are not. Set to '' to disable. Options are added idempotently to"
                . " existing groups on activation (never removed).",
            type        => 'string',
            default     => '2,22,25,68',
            optional    => 1,
        },
        skip_unmap_io_check => {
            description => "Teardown optimization: add Hitachi HMO 91 (\"[OpenStack/"
                . "OpenShift(K8s)] Skip I/O check when LUN path is deleted\") to the"
                . " plugin's host groups. By default the array refuses to unmap a LUN"
                . " path while it still detects host I/O on the LU, so free_image must"
                . " retry with backoff after the host-side device is removed; HMO 91"
                . " skips that check so the unmap succeeds immediately. Safe because the"
                . " plugin always tears the host side down first (flush + remove the"
                . " multipath/SCSI device before unmapping), so no live writes remain by"
                . " then; HMO 91 only removes the array's now-redundant interlock. Off by"
                . " default. Available for host mode 00 on VSP One Block 20 / E series.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        platform => {
            description => "Storage platform type. Sets the default API port: 'vsp_one'"
                . " and 'vsp_e' (e.g. VSP E590H, direct/embedded REST API) use 443;"
                . " 'vsp_g' uses 23451 (Ops Center Configuration Manager server). Override"
                . " with mgmt_port when fronting any model with a CM server or vice versa.",
            type        => 'string',
            enum        => ['vsp_g', 'vsp_e', 'vsp_one'],
            default     => 'vsp_one',
            optional    => 1,
        },
        mgmt_port => {
            description => "Management API port (auto-detected from platform if omitted:"
                . " 443 for direct/embedded REST, 23451 for an Ops Center CM server).",
            type        => 'integer',
            optional    => 1,
        },
        # NOTE: `username` and `password` are intentionally NOT defined here.
        # They are common properties already defined by PVE's base/other storage
        # plugins (e.g. CIFS/PBS); redefining them makes PVE::SectionConfig die with
        # "duplicate property 'username'", which breaks pvesm and the PVE daemons.
        # We only reference them in options() (like nodes/content/shared/disable).
        qos_upper_iops => {
            description => "Default upper IOPS limit per LDEV (0 = unlimited).",
            type        => 'integer',
            minimum     => 0,
            optional    => 1,
        },
        qos_upper_mbps => {
            description => "Default upper throughput limit per LDEV in MB/s (0 = unlimited).",
            type        => 'integer',
            minimum     => 0,
            optional    => 1,
        },
        qos_lower_iops => {
            description => "Default lower IOPS guarantee per LDEV.",
            type        => 'integer',
            minimum     => 0,
            optional    => 1,
        },
        qos_lower_mbps => {
            description => "Default lower throughput guarantee per LDEV in MB/s.",
            type        => 'integer',
            minimum     => 0,
            optional    => 1,
        },
        qos_priority => {
            description => "Default QoS I/O response priority (1=high, 2=medium, 3=low).",
            type        => 'integer',
            minimum     => 1,
            maximum     => 3,
            optional    => 1,
        },
        ldev_range => {
            description => "Restrict LDEV ID allocation to a range (e.g. '1000-1999' or '0x3E8-0x7CF').",
            type        => 'string',
            optional    => 1,
        },
        discard_zero_page => {
            description => "Reclaim zero-filled pages on volume deactivation (thin pool space recovery).",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        port_scheduler => {
            description => "Spread LUN mappings across target ports using stable, deterministic"
                . " per-LDEV port selection (a volume always maps to the same port pair on every node).",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        copy_speed => {
            description => "Array-side copy speed for clone operations (1-15, default 3).",
            type        => 'integer',
            minimum     => 1,
            maximum     => 15,
            optional    => 1,
        },
        group_delete => {
            description => "Auto-delete empty host groups on storage deactivation.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        tls_verify => {
            description => "Verify the Configuration Manager TLS certificate (default off for self-signed certs).",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        tls_ca_file => {
            description => "Path to a CA bundle used to verify the API certificate when tls_verify is enabled.",
            type        => 'string',
            optional    => 1,
        },
    };
}

sub options {
    return {
        mgmt_ip      => { fixed => 1 },
        storage_id   => { fixed => 1 },
        pool_id      => { fixed => 1 },
        snap_pool_id => { optional => 1 },
        target_ports => { fixed => 1 },
        host_mode    => { optional => 1 },
        host_mode_options => { optional => 1 },
        skip_unmap_io_check => { optional => 1 },
        platform     => { optional => 1 },
        mgmt_port    => { optional => 1 },
        nodes        => { optional => 1 },
        shared       => { optional => 1 },
        disable      => { optional => 1 },
        content      => { optional => 1 },
        username       => { optional => 1 },
        password       => { optional => 1 },
        qos_upper_iops    => { optional => 1 },
        qos_upper_mbps    => { optional => 1 },
        qos_lower_iops    => { optional => 1 },
        qos_lower_mbps    => { optional => 1 },
        qos_priority      => { optional => 1 },
        ldev_range        => { optional => 1 },
        discard_zero_page => { optional => 1 },
        port_scheduler    => { optional => 1 },
        copy_speed        => { optional => 1 },
        group_delete      => { optional => 1 },
        tls_verify        => { optional => 1 },
        tls_ca_file       => { optional => 1 },
    };
}

# ── Hooks ──

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    # `username` is a normal property (in $scfg); `password` is sensitive and
    # arrives via %sensitive (never in storage.cfg). Persist both to the
    # cluster-private credential file for runtime REST auth.
    my $username = $scfg->{username};
    my $password = $sensitive{password};
    die "hitachiblock: 'username' and 'password' are required\n"
        if !defined $username || !defined $password;
    $config->store_credentials($username, $password);

    $class->_warn_if_ldev_range_misaligned($scfg->{ldev_range});

    # Validate connectivity
    eval {
        my $client = $class->_get_client($storeid, $scfg);
        $client->login();
        $client->get_pool($scfg->{pool_id});
        $client->logout();
    };
    if ($@) {
        die "Storage validation failed: $@\n";
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    # Explicit password clear (`pvesm set --delete password`) removes creds.
    if (exists $sensitive{password} && !defined $sensitive{password}) {
        $config->delete_credentials();
        return;
    }

    my $username = $scfg->{username};
    # Use the new password when (re)set, else keep the stored one so a username
    # change alone still rewrites a complete credential file.
    my $password = $sensitive{password};
    if (!defined $password) {
        $password = eval { (($config->read_credentials())[1]) };
    }

    $config->store_credentials($username, $password)
        if defined $username && defined $password;

    $class->_warn_if_ldev_range_misaligned($scfg->{ldev_range});

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    $config->delete_credentials();

    return;
}

# Our volumes are raw block LUNs and snapshots are taken array-side (Thin
# Image), transparently to a running guest — qemu does not snapshot the disk
# itself. (The base default also returns 'storage' for raw; declared explicitly.)
sub volume_qemu_snapshot_method {
    my ($class, $storeid, $scfg, $volname) = @_;
    return 'storage';
}

# ── Storage Lifecycle ──

my %_clients;        # cache: storeid -> RestClient (live session, per process)
my %_client_scfg;    # cache: storeid -> scfg, so _client can re-establish a
                     # session when %_clients was cleared mid-process. PVE tracks
                     # activation in its own $cache->{activated}; if an
                     # intermediate deactivate_storage clears our client (e.g.
                     # cloud-init ISO generation activates then deactivates the
                     # storage at VM start) while PVE still thinks it is
                     # activated, PVE skips re-activation and a later
                     # activate_volume would find no client. Remembering the scfg
                     # lets _client lazily re-login instead of dying. (GitHub #13)

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Remember scfg so _client can re-establish a session if our cached client
    # is later cleared while PVE still considers the storage activated (#13).
    $_client_scfg{$storeid} = $scfg;

    my $client = $class->_get_client($storeid, $scfg);
    $client->login();
    $_clients{$storeid} = $client;

    # Verify pool accessibility
    $client->get_pool($scfg->{pool_id});

    # Ensure host groups exist for local WWNs on all target ports
    eval { $class->_ensure_host_groups($storeid, $scfg, $client) };
    warn "Host group setup warning: $@" if $@;

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    if (my $client = delete $_clients{$storeid}) {
        # Auto-delete empty host groups if configured
        if ($scfg->{group_delete}) {
            eval { $class->_cleanup_empty_host_groups($storeid, $scfg, $client) };
            warn "Host group cleanup warning: $@" if $@;
        }

        eval { $client->logout() };
    }

    return 1;
}

# ── Status ──

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $pool = $client->get_pool($scfg->{pool_id});

    # Hitachi Configuration Manager reports DP pool capacities in MB; convert to
    # bytes for PVE. (Documented unit — no value-magnitude guessing.)
    my $mb = 1024 * 1024;
    my $total = ($pool->{totalPoolCapacity} || 0) * $mb;

    # `usedPoolCapacity` is NOT populated on every microcode: the VSP E590H
    # (and other embedded-REST E-series) returns it as null while reporting
    # `availableVolumeCapacity` and `usedCapacityRate`. Reading usedPoolCapacity
    # blindly made status() report the pool as 0% used (all-free), which hides
    # over-provisioning and capacity alarms. Derive `used` from whatever the
    # array actually returns, in order of accuracy:
    #   1. usedPoolCapacity            (direct, when present)
    #   2. total - availableVolumeCapacity  (documented free field; E590H path)
    #   3. total * usedCapacityRate/100     (percentage, last resort)
    my $used;
    if (defined $pool->{usedPoolCapacity}) {
        $used = $pool->{usedPoolCapacity} * $mb;
    } elsif (defined $pool->{availableVolumeCapacity}) {
        $used = $total - $pool->{availableVolumeCapacity} * $mb;
    } elsif (defined $pool->{usedCapacityRate}) {
        $used = int($total * $pool->{usedCapacityRate} / 100);
    } else {
        $used = 0;
    }
    $used = 0      if $used < 0;
    $used = $total if $used > $total;

    my $free = $total - $used;
    $free = 0 if $free < 0;

    return ($total, $free, $used, 1);
}

# ── Image Lifecycle ──

# Convert a PVE size (KiB) to the LDEV size in MiB the array should create.
# Rounds up to whole MiB and floors to the array minimum so sub-minimum PVE
# volumes (vTPM = 4 MiB, EFI vars) don't fail with "capacity is invalid".
# Sizes at/above the minimum are passed through exactly (no rounding).
sub _alloc_size_mb {
    my ($class, $size_kib) = @_;
    my $mb = ceil(($size_kib || 0) / 1024);
    $mb = $MIN_LDEV_MB if $mb < $MIN_LDEV_MB;
    return $mb;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'\n" if $fmt && $fmt ne 'raw';

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    # Reserve a unique volume name under the cluster lock unless PVE supplied one.
    # When PVE supplies an explicit name, reject it if it already maps to an LDEV
    # so we never create a second array volume behind an existing volid.
    my $reserved = 0;
    unless ($name) {
        $name = $config->reserve_volname($vmid);
        $reserved = 1;
    } else {
        my ($existing_id) = $config->lookup_ldev($name);
        die "Volume '$name' already exists in registry (LDEV $existing_id)\n"
            if defined $existing_id;
    }

    # Size is in KiB from PVE; convert to MiB for the Hitachi API and floor tiny
    # allocations (vTPM/EFI) to the array's minimum DP-VOL size.
    my $size_mb = $class->_alloc_size_mb($size);

    # Create LDEV (with optional LDEV range restriction)
    my %create_opts = (
        pool_id => $scfg->{pool_id},
        size_mb => $size_mb,
    );
    if ($scfg->{ldev_range}) {
        $create_opts{ldev_id} = $class->_next_ldev_in_range($client, $scfg, $config);
    }

    my $ldev_id;
    my $committed = 0;

    eval {
        my $result = $client->create_ldev(%create_opts);
        $ldev_id = $result->{resourceId}
            or die "Failed to get LDEV ID from create response\n";

        # Label for identification (prerequisite for orphan detection)
        my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $name);
        $client->set_ldev_label($ldev_id, $label);

        # QoS is best-effort: a limit-set failure must not fail provisioning.
        my %qos = $class->_qos_from_scfg($scfg);
        if (%qos) {
            eval { $client->set_ldev_qos($ldev_id, %qos) };
            warn "QoS application warning: $@" if $@;
        }

        # Mapping + device discovery are prerequisites for a usable volume:
        # failure here is fatal (no silent "ghost" volumes).
        $class->_map_lun_to_local($storeid, $scfg, $client, $ldev_id);

        my $synth = $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
        my ($wwid) = $class->_resolve_wwid($client, $multipath, $ldev_id, $synth);

        # Commit to the registry LAST, once the volume is real and discoverable.
        $config->register_ldev($name, $ldev_id,
            wwid    => $wwid,
            size_mb => $size_mb,
            pool_id => $scfg->{pool_id},
        );
        $committed = 1;
    };
    if (my $err = $@) {
        # Roll back array-side resources and the name reservation.
        if (defined $ldev_id) {
            eval { $class->_unmap_lun_from_local($storeid, $scfg, $client, $ldev_id) };
            eval { $client->delete_ldev($ldev_id) };
        }
        eval { $config->unregister_ldev($name) } if $reserved && !$committed;
        die "Failed to allocate volume '$name': $err";
    }

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    # Refuse deletion while linked clones (Thin Image children) still depend on
    # this volume as their P-VOL — deleting it would corrupt those clones.
    my $deps = $config->find_dependents($volname);
    if (@$deps) {
        die "Cannot delete '$volname': linked clone(s) depend on it: "
            . join(', ', sort @$deps) . "\n";
    }

    # Delete any snapshot pairs first
    eval {
        my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
        for my $snap (@$snaps) {
            $client->delete_snapshot($snap->{snapshotId}) if $snap->{snapshotId};
        }
    };
    warn "Snapshot cleanup warning: $@" if $@;

    # Tear down the HOST side FIRST: flush the multipath map, de-whitelist, and
    # delete the underlying SCSI paths. This must happen before the array unmap —
    # otherwise the array refuses the unmap with "the LU is executing host I/O"
    # (multipathd's path checker keeps the paths active).
    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    eval { $multipath->remove_device($wwid) };
    warn "Device removal warning: $@" if $@;

    # SAFETY FENCE: never unmap/delete an LDEV outside our configured range. The
    # LDEV here comes from our own registry so it is normally in range; if it is
    # not, refuse rather than risk touching a foreign volume.
    die "refusing to free LDEV $ldev_id: outside ldev_range"
        . ($scfg->{ldev_range} ? " '$scfg->{ldev_range}'" : '') . "\n"
        unless $class->_ldev_in_range($scfg, $ldev_id);

    # Unmap THIS LDEV's own LUN paths. Ask the LDEV for its paths via
    # GET /ldevs/<id> -> ports[] (each entry is portId/hostGroupNumber/lun) instead
    # of scanning host groups: the array IGNORES the ldevId selector on GET /luns
    # (verified live on the E590H), so a host-group-wide scan could see and unmap
    # OTHER hosts' LUN paths. ports[] is inherently scoped to this LDEV. If any
    # path is left, the LDEV delete below fails with "A path is defined".
    eval {
        my $ldev = $client->get_ldev($ldev_id);
        for my $pe (@{ $ldev->{ports} || [] }) {
            next unless defined $pe->{portId}
                && defined $pe->{hostGroupNumber} && defined $pe->{lun};
            my $lun_id = join(',', $pe->{portId}, $pe->{hostGroupNumber}, $pe->{lun});
            # Right after the host paths are deleted the array can still report
            # "the LU is executing host I/O" for a few seconds; retry with backoff.
            # (With the skip_unmap_io_check option / HMO 91 set on the host group the
            # array skips this check and the first attempt succeeds immediately.)
            my $ok = 0;
            for my $try (1 .. $UNMAP_IO_RETRIES) {
                $ok = eval { $client->unmap_lun($lun_id); 1 };
                last if $ok;
                die $@ unless ($@ // '') =~ /host I\/?O/i;
                sleep 3;
            }
            die "LUN $lun_id unmap blocked by host I/O after retries\n" unless $ok;
        }
    };
    warn "LUN unmap warning: $@" if $@;

    # Delete LDEV (fence already checked above)
    $client->delete_ldev($ldev_id);

    # Unregister (snapshots are nested inside the registry entry, cleaned up automatically)
    $config->unregister_ldev($volname);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $registry = $config->list_registered();

    my @res;

    for my $volname (sort keys %$registry) {
        my $entry = $registry->{$volname};

        # Skip name reservations (no LDEV committed yet).
        next unless ref $entry eq 'HASH' && defined $entry->{ldev_id};

        my $evmid = ($volname =~ /^(?:vm|base)-(\d+)-/) ? $1 : 0;

        # Filter by vmid if specified
        if ($vmid) {
            next unless $evmid == $vmid;
        }

        # Filter by vollist if specified
        if ($vollist) {
            my $full = "$storeid:$volname";
            next unless grep { $_ eq $full } @$vollist;
        }

        my $size = ($entry->{size_mb} || 0) * 1024 * 1024;

        my $parent = $entry->{parent_volname}
            ? "$storeid:$entry->{parent_volname}" : undef;

        push @res, {
            volid  => "$storeid:$volname",
            format => 'raw',
            size   => $size,
            vmid   => $evmid,
            parent => $parent,
        };
    }

    return \@res;
}

# ── Volume Lifecycle ──

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $client = $class->_client($storeid, $scfg);

    my $target_ldev_id;
    my $wwid;

    if ($snapname) {
        # Activate a snapshot's S-VOL
        my $snap_meta = $config->lookup_snapshot($volname, $snapname);
        die "Snapshot '$snapname' not found for volume '$volname'\n" unless $snap_meta;
        die "Snapshot '$snapname' has no S-VOL LDEV\n" unless defined $snap_meta->{svol_ldev_id};

        $target_ldev_id = $snap_meta->{svol_ldev_id};
        $wwid = $snap_meta->{svol_wwid}
            || $multipath->ldev_to_wwid($scfg->{storage_id}, $target_ldev_id);
    } else {
        my ($ldev_id, $meta) = $config->lookup_ldev($volname);
        die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

        $target_ldev_id = $ldev_id;
        $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    }

    # Ensure LUN is mapped to this node (handles post-migration case)
    eval { $class->_map_lun_to_local($storeid, $scfg, $client, $target_ldev_id) };
    warn "LUN mapping check warning: $@" if $@;

    # Rescan and wait for device
    $multipath->rescan_scsi_hosts();
    my $path = $multipath->wait_for_device($wwid);

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my $target_ldev_id;
    my $wwid;

    if ($snapname) {
        my $snap_meta = $config->lookup_snapshot($volname, $snapname);
        return 1 unless $snap_meta && defined $snap_meta->{svol_ldev_id};

        $target_ldev_id = $snap_meta->{svol_ldev_id};
        $wwid = $snap_meta->{svol_wwid}
            || $multipath->ldev_to_wwid($scfg->{storage_id}, $target_ldev_id);
    } else {
        my ($ldev_id, $meta) = $config->lookup_ldev($volname);
        return 1 unless defined $ldev_id;

        $target_ldev_id = $ldev_id;
        $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    }

    # Flush and remove multipath device
    eval { $multipath->remove_device($wwid) };
    warn "Device deactivation warning: $@" if $@;

    # Unmap LUN from this node's host group
    eval {
        my $client = $class->_client($storeid, $scfg);
        $class->_unmap_lun_from_local($storeid, $scfg, $client, $target_ldev_id);

        # Reclaim zero-filled pages for thin pool space recovery
        if ($scfg->{discard_zero_page}) {
            eval { $client->reclaim_zero_pages($target_ldev_id) };
            warn "Zero page reclamation warning: $@" if $@;
        }
    };
    warn "LUN unmap warning: $@" if $@;

    return 1;
}

# Explicit map/unmap hooks (PVE 8+). The volume is backed by a real block device,
# so mapping = ensure the LUN is mapped to this node and its multipath device is
# present (activate_volume), and the path is the dm device. Idempotent.
sub map_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $hints) = @_;

    $class->activate_volume($storeid, $scfg, $volname, $snapname);
    my ($path) = $class->filesystem_path($scfg, $volname, $storeid, $snapname);
    return $path;
}

sub unmap_volume {
    my ($class, $storeid, $scfg, $volname, $snapname) = @_;

    $class->deactivate_volume($storeid, $scfg, $volname, $snapname);
    return 1;
}

sub filesystem_path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my $wwid;

    if ($snapname) {
        my $snap_meta = $config->lookup_snapshot($volname, $snapname);
        die "Snapshot '$snapname' not found for volume '$volname'\n" unless $snap_meta;
        die "Snapshot '$snapname' has no S-VOL LDEV\n" unless defined $snap_meta->{svol_ldev_id};

        $wwid = $snap_meta->{svol_wwid}
            || $multipath->ldev_to_wwid($scfg->{storage_id}, $snap_meta->{svol_ldev_id});
    } else {
        my ($ldev_id, $meta) = $config->lookup_ldev($volname);
        die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

        $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    }

    my $path = $multipath->get_device_path($wwid);

    # PVE contract: the third element is the volume TYPE (vtype), not the format.
    return wantarray ? ($path, vmid_from_volname($volname), 'images') : $path;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    return $class->filesystem_path($scfg, $volname, $storeid, $snapname);
}

# Override the inherited (path-based) implementation: report size straight from
# the registry/array instead of shelling out to qemu-img on a raw block device.
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    my $size = ($meta->{size_mb} || 0) * 1024 * 1024;
    my $parent = $meta->{parent_volname}
        ? "$storeid:$meta->{parent_volname}" : undef;

    # raw block volumes are fully provisioned from PVE's perspective: used == size
    return wantarray ? ($size, 'raw', $size, $parent) : $size;
}

# ── Snapshots ──

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    my $snap_pool_id = $scfg->{snap_pool_id} // $scfg->{pool_id};
    # Encode the volume's LDEV id into the group name so the array-side fallback
    # search cannot resolve to another volume's pair with the same snapshot name.
    my $snap_group = "pve_${storeid}_${ldev_id}_${snap}";

    my %snap_opts = (
        pvol_ldev_id   => $ldev_id,
        snap_pool_id   => $snap_pool_id,
        snapshot_group => $snap_group,
    );
    $snap_opts{copy_speed} = $scfg->{copy_speed} if $scfg->{copy_speed};

    my $result = $client->create_snapshot(%snap_opts);

    # Retrieve S-VOL details from the created snapshot pair
    my $svol_ldev_id;
    my $snapshot_id;

    eval {
        my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
        for my $s (@$snaps) {
            if (($s->{snapshotGroupName} || '') eq $snap_group) {
                $svol_ldev_id = $s->{svolLdevId};
                $snapshot_id  = $s->{snapshotId};
                last;
            }
        }
    };

    # Register snapshot metadata
    my %snap_meta = (
        snapshot_group => $snap_group,
        pvol_ldev_id   => $ldev_id,
    );

    if (defined $svol_ldev_id) {
        $snap_meta{svol_ldev_id} = $svol_ldev_id;
        $snap_meta{svol_wwid} = $multipath->ldev_to_wwid($scfg->{storage_id}, $svol_ldev_id);
    }
    $snap_meta{snapshot_id} = $snapshot_id if defined $snapshot_id;

    $config->register_snapshot($volname, $snap, %snap_meta);

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Refuse deletion while linked clones were created from THIS snapshot — their
    # S-VOL still shares blocks with the snapshot pair, so deleting it would
    # corrupt those clones. Promote/remove the clones first.
    my $snap_deps = $config->find_snapshot_dependents($volname, $snap);
    if (@$snap_deps) {
        die "Cannot delete snapshot '$snap' of '$volname': linked clone(s) depend"
            . " on it: " . join(', ', sort @$snap_deps) . "\n";
    }

    # Try registry first for fast lookup
    my $snap_meta = $config->lookup_snapshot($volname, $snap);

    if ($snap_meta && defined $snap_meta->{snapshot_id}) {
        eval { $client->delete_snapshot($snap_meta->{snapshot_id}) };
        if ($@) {
            warn "Direct snapshot delete failed, falling back to search: $@";
        } else {
            $config->unregister_snapshot($volname, $snap);
            return 1;
        }
    }

    # Fallback: search by snapshot group name on the array. Accept both the
    # volume-specific name and the legacy name (for pairs created by older
    # versions) so existing snapshots remain manageable after upgrade.
    my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
    my %target_groups = (
        "pve_${storeid}_${ldev_id}_${snap}" => 1,
        "pve_${storeid}_${snap}"            => 1,
    );

    for my $s (@$snaps) {
        if ($target_groups{ $s->{snapshotGroupName} || '' }) {
            $client->delete_snapshot($s->{snapshotId});
            $config->unregister_snapshot($volname, $snap);
            return 1;
        }
    }

    die "Snapshot '$snap' not found for volume '$volname'\n";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Try registry first
    my $snap_meta = $config->lookup_snapshot($volname, $snap);
    if ($snap_meta && defined $snap_meta->{snapshot_id}) {
        eval {
            $client->restore_snapshot($snap_meta->{snapshot_id});
            return 1;
        };
        warn "Direct snapshot restore failed, falling back to search: $@" if $@;
    }

    # Fallback: search by group name (volume-specific or legacy).
    my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
    my %target_groups = (
        "pve_${storeid}_${ldev_id}_${snap}" => 1,
        "pve_${storeid}_${snap}"            => 1,
    );

    for my $s (@$snaps) {
        if ($target_groups{ $s->{snapshotGroupName} || '' }) {
            $client->restore_snapshot($s->{snapshotId});
            return 1;
        }
    }

    die "Snapshot '$snap' not found for volume '$volname'\n";
}

sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $snaps = $config->list_snapshots($volname);

    my $info = {
        'current' => {
            description => '',
            parent => undef,
        },
    };

    # Build snapshot chain (linear — each snap's parent is the previous one)
    my @ordered = sort { ($snaps->{$a}{timestamp} || 0) <=> ($snaps->{$b}{timestamp} || 0) } keys %$snaps;

    my $prev = 'current';
    for my $snapname (@ordered) {
        $info->{$snapname} = {
            description => '',
            parent      => undef,
            timestamp   => $snaps->{$snapname}{timestamp},
        };

        # Chain: current -> snap1 -> snap2 -> ...
        # PVE convention: parent points to the older snapshot
        $info->{$snapname}{parent} = $prev eq 'current' ? undef : $prev;
        $prev = $snapname;
    }

    # Current's parent is the most recent snapshot
    $info->{'current'}{parent} = $prev eq 'current' ? undef : $prev;

    return $info;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # Keyed by the volume's role, following the block-storage (LVM-thin) model:
    #   base    = a template/base image
    #   current = a regular live volume
    #   snap    = operating on a snapshot of the volume
    # Linked clones are CoW Thin Image S-VOLs, so 'clone' is offered only from a
    # base image or a snapshot (not an arbitrary live volume); full copies use
    # 'copy'. Matches PVE::Storage::LvmThinPlugin.
    my $features = {
        snapshot   => { current => 1 },
        clone      => { base => 1, snap => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        template   => { current => 1 },
        rename     => { current => 1 },
        resize     => { current => 1 },
    };

    my $isBase = ($class->parse_volname($volname))[5];

    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return undef;
}

# ── Clone ──

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap, $running, $target) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    # clone_image is PVE's LINKED-clone primitive: the result is a CoW Thin Image
    # S-VOL that shares blocks with its source. Full copies do not come through here
    # (PVE copies via alloc_image + the device path). The source must therefore be a
    # base image or a snapshot — matching volume_has_feature('clone') => base/snap.
    my $isBase = ($class->parse_volname($volname))[5];
    die "clone_image only supports a base image or a snapshot as the source\n"
        if !$isBase && !$snap;

    # Use the caller-supplied volname as the registry/dependency key throughout, so
    # the keys recorded here match exactly what the deletion guards (free_image,
    # create_base, rename_volume, volume_snapshot_delete) compare against.
    my ($src_ldev_id, $src_meta) = $config->lookup_ldev($volname);
    die "Source volume '$volname' not found\n" unless defined $src_ldev_id;

    # The P-VOL of the CoW pair: the snapshot's S-VOL when cloning from a snapshot,
    # otherwise the (base) volume's own LDEV.
    my $clone_source_ldev = $src_ldev_id;
    if ($snap) {
        my $snap_meta = $config->lookup_snapshot($volname, $snap);
        die "Snapshot '$snap' not found for volume '$volname'\n" unless $snap_meta;
        die "Snapshot '$snap' has no S-VOL LDEV\n" unless defined $snap_meta->{svol_ldev_id};
        $clone_source_ldev = $snap_meta->{svol_ldev_id};
    }

    my $new_name = $config->reserve_volname($vmid);
    my $snap_pool_id = $scfg->{snap_pool_id} // $scfg->{pool_id};
    my $size_mb = $src_meta->{size_mb} || 1;

    my $new_ldev_id;
    my $committed = 0;

    eval {
        # Thin S-VOL to back the linked clone.
        my $result = $client->create_ldev(
            pool_id => $snap_pool_id,
            size_mb => $size_mb,
        );
        $new_ldev_id = $result->{resourceId}
            or die "Failed to create S-VOL for linked clone\n";

        # Split Thin Image pair (autoSplit=true): the pair is created and split so the
        # S-VOL becomes host R/W-accessible (status PSUS) while STILL sharing unchanged
        # blocks with the source via the pool — a persistent copy-on-write linked
        # clone. Per the REST API guide, `isClone` (which we never set) is the opposite:
        # it full-copies then auto-deletes the pair, yielding a standalone full clone.
        # An *un-split* pair's S-VOL is only "reference available", not host R/W.
        $client->create_snapshot(
            pvol_ldev_id   => $clone_source_ldev,
            svol_ldev_id   => $new_ldev_id,
            snap_pool_id   => $snap_pool_id,
            snapshot_group => "pve_lclone_${storeid}_${new_ldev_id}",
            auto_split     => 1,
        );

        # Label (prerequisite for orphan detection)
        my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $new_name);
        $client->set_ldev_label($new_ldev_id, $label);

        # Map + discover are prerequisites for a usable clone: failure is fatal.
        $class->_map_lun_to_local($storeid, $scfg, $client, $new_ldev_id);

        my $synth = $multipath->ldev_to_wwid($scfg->{storage_id}, $new_ldev_id);
        my ($wwid) = $class->_resolve_wwid($client, $multipath, $new_ldev_id, $synth);

        # Commit LAST. Record the source volume (and snapshot, when applicable) so the
        # source cannot be deleted while this linked clone still shares its blocks.
        $config->register_ldev($new_name, $new_ldev_id,
            wwid           => $wwid,
            size_mb        => $size_mb,
            pool_id        => $snap_pool_id,
            parent_volname => $volname,
            parent_snap    => ($snap ? $snap : undef),
        );
        $committed = 1;
    };
    if (my $err = $@) {
        if (defined $new_ldev_id) {
            eval { $class->_unmap_lun_from_local($storeid, $scfg, $client, $new_ldev_id) };
            eval { $client->delete_ldev($new_ldev_id) };
        }
        eval { $config->unregister_ldev($new_name) } unless $committed;
        die "Failed to clone '$volname' to '$new_name': $err";
    }

    return $new_name;
}

# ── Storage Migration (volume export / import) ──
#
# These let the volume participate in PVE's `storage_migrate` path — offline
# `qm migrate` to a node where this storage is not shared, cross-cluster
# `qm remote-migrate`, and `pvesm export`/`import`. They stream the raw block
# device (`raw+size`), exactly like the RBD plugin. (Same-node/cluster "Move
# Storage" / `qm move-disk` does NOT use these — it copies through qemu over the
# device path returned by filesystem_path.)
#
# Array-offloaded snapshots are NOT part of the stream: only the active volume
# state is transferred, so `with_snapshots`/incremental streams are unsupported.

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    return $class->volume_import_formats(
        $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots);
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    return () if $with_snapshots;          # array snapshots are not streamed
    return () if defined($base_snapshot);  # no incremental streams
    return () if defined($snapshot);       # no snapshot-specific export over the stream
    return ('raw+size');
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots)
        = @_;

    die "volume export format '$format' not available for $class\n" if $format ne 'raw+size';
    die "cannot export volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot export a snapshot in $class\n"            if defined($snapshot);
    die "cannot export an incremental stream in $class\n" if defined($base_snapshot);

    # The LUN must already be mapped and its multipath device present on this node
    # (the migration framework activates source volumes before export).
    my $path = $class->filesystem_path($scfg, $volname, $storeid);
    my ($size) = $class->volume_size_info($scfg, $storeid, $volname);

    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command(
        ['dd', "if=$path", 'bs=4k', 'status=progress'],
        output  => '>&' . fileno($fh),
        # dd uses carriage returns for progress; split into individual log lines
        errfunc => sub { print STDERR "$_[0]\n" },
    );

    return;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot,
        $with_snapshots, $allow_rename) = @_;

    die "volume import format '$format' not available for $class\n" if $format ne 'raw+size';
    die "cannot import volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot import an incremental stream in $class\n" if defined($base_snapshot);

    my (undef, $name, $vmid, undef, undef, undef, $file_format) = $class->parse_volname($volname);
    die "cannot import format $format into a volume of format $file_format\n"
        if $file_format ne 'raw';

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    if (defined($config->lookup_ldev($volname))) {
        die "volume '$volname' already exists\n" if !$allow_rename;
        warn "volume '$volname' already exists - importing with a different name\n";
        $name = undef;   # let alloc_image reserve a fresh name under the cluster lock
    }

    # Header size is in bytes; alloc_image expects KiB.
    my ($size) = PVE::Storage::Plugin::read_common_header($fh);
    my $size_kb = ceil($size / 1024);

    my $new_volname;
    eval {
        # alloc_image creates the LDEV, maps it, discovers the device, and registers
        # it last — so on success $new_volname has a usable device path.
        $new_volname = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $name, $size_kb);
        my $path = $class->filesystem_path($scfg, $new_volname, $storeid)
            or die "failed to resolve path for newly allocated volume '$new_volname'\n";
        run_command(
            ['dd', "of=$path", 'conv=sparse', 'bs=64k'],
            input => '<&' . fileno($fh),
        );
    };
    if (my $err = $@) {
        eval { $class->free_image($storeid, $scfg, $new_volname, 0, 'raw') }
            if defined($new_volname);
        warn $@ if $@;
        die $err;
    }

    return "$storeid:$new_volname";
}

# ── Resize ──

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Verify current size from array to avoid stale registry data
    my $ldev_info = eval { $client->get_ldev($ldev_id) };
    my $current_mb = $class->_ldev_size_mb($ldev_info) || $meta->{size_mb} || 0;

    # Size is in bytes from PVE, convert to MB
    my $new_size_mb = ceil($size / (1024 * 1024));
    my $additional = $new_size_mb - $current_mb;

    die "Cannot shrink volume (requested ${new_size_mb}MB, current ${current_mb}MB)\n"
        if $additional <= 0;

    # Flush host buffers before expand (safety for running VMs)
    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    if ($running) {
        eval { $multipath->flush_device($wwid) };
        warn "Pre-resize flush warning: $@" if $@;
    }

    # Expand LDEV on array
    $client->expand_ldev($ldev_id, $additional);

    # Resize multipath device on host
    eval { $multipath->resize_device($wwid) };
    warn "Host-side resize warning: $@" if $@;

    # Commit the new size to the registry after the array expansion succeeded.
    $config->register_ldev($volname, $ldev_id,
        %$meta,
        size_mb => $new_size_mb,
    );

    return 1;
}

# ── Internal Helpers ──

sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    # Remember scfg for a possible lazy re-establish later in this process (#13).
    $_client_scfg{$storeid} = $scfg;

    eval {
        my $client = $class->_get_client($storeid, $scfg);
        $client->login();
        $client->get_pool($scfg->{pool_id});
        $client->logout();
    };
    if ($@) {
        return 0;
    }
    return 1;
}

sub _client {
    my ($class, $storeid, $scfg) = @_;

    $_client_scfg{$storeid} = $scfg if $scfg;

    my $client = $_clients{$storeid};

    # Lazily (re)establish a session if we have none cached. This happens when
    # PVE skips re-activation (its $cache->{activated} is still set) after an
    # intermediate deactivate_storage cleared our client — e.g. cloud-init ISO
    # generation activates then deactivates the storage during VM start. We can
    # rebuild from the remembered scfg instead of failing the operation. (#13)
    if (!$client) {
        my $sc = $scfg || $_client_scfg{$storeid};
        die "Storage '$storeid' is not activated\n" unless $sc;
        $client = $class->_get_client($storeid, $sc);
        $client->login();
        $_clients{$storeid} = $client;
        return $client;
    }

    # Verify session is alive; reconnect if needed
    eval { $client->keepalive() };
    if ($@) {
        eval { $client->login() };
        die "Storage '$storeid' session lost and reconnect failed: $@\n" if $@;
    }

    return $client;
}

sub _get_client {
    my ($class, $storeid, $scfg) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my ($username, $password) = $config->read_credentials();

    my $platform = $scfg->{platform} || 'vsp_one';
    my $defaults = PVE::Storage::HitachiBlock::Config->platform_defaults($platform);
    my $port = $scfg->{mgmt_port} || $defaults->{port};

    return PVE::Storage::HitachiBlock::RestClient->new(
        mgmt_ip     => $scfg->{mgmt_ip},
        port        => $port,
        storage_id  => $scfg->{storage_id},
        username    => $username,
        password    => $password,
        tls_verify  => $scfg->{tls_verify},
        tls_ca_file => $scfg->{tls_ca_file},
    );
}

sub _ensure_host_groups {
    my ($class, $storeid, $scfg, $client) = @_;

    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $wwns = $multipath->get_local_wwns();

    return unless @$wwns;

    my @ports = split(/,/, $scfg->{target_ports} || '');
    my $host_mode = $scfg->{host_mode} || 'LINUX/IRIX';
    # Host mode options. Default '2,22,25,68' is Hitachi's best-practice set for the
    # LINUX/IRIX host mode: 68 (WRITE SAME / SCSI ANSI v5 = Page Reclamation for Linux)
    # makes the array advertise SCSI UNMAP so thin pools reclaim on discard/fstrim;
    # 2/22/25 (Veritas DB-Adv Cluster / Veritas Cluster Server / SPC-3 Persistent
    # Reservation) are default-on on VSP One Block but set explicitly for older arrays.
    my $hmo_cfg = defined $scfg->{host_mode_options} ? $scfg->{host_mode_options} : '2,22,25,68';
    my @hmo = grep { /^\d+$/ } map { s/^\s+|\s+$//gr } split(/,/, $hmo_cfg);
    # Optional teardown optimization: HMO 91 ([OpenStack/OpenShift] skip I/O check
    # when a LUN path is deleted) lets the array unmap immediately instead of
    # returning "the LU is executing host I/O" while multipathd's path checker
    # still probes the just-removed device (see free_image's unmap retry loop).
    push @hmo, 91 if $scfg->{skip_unmap_io_check} && !grep { $_ == 91 } @hmo;
    my $hostname = `hostname -s`;
    chomp($hostname);

    my $hg_name = "PVE_${hostname}";

    for my $port_id (@ports) {
        $port_id =~ s/^\s+|\s+$//g;
        next unless length $port_id;

        # Idempotent: reuse an existing host group (by our name first, else by any
        # of our WWNs); only create when truly absent. We re-look-up after create
        # to get the array-assigned hostGroupNumber, because the create response's
        # resource id is a composite "portId,number" we don't parse.
        my $hg = $client->find_host_group_by_name($port_id, $hg_name);
        if (!$hg) {
            for my $wwn (@$wwns) {
                $hg = $client->find_host_group_by_wwn($port_id, $wwn);
                last if $hg;
            }
        }
        if (!$hg) {
            $client->create_host_group(
                port_id           => $port_id,
                host_group_name   => $hg_name,
                host_mode         => $host_mode,
                host_mode_options => \@hmo,
            );
            $hg = $client->find_host_group_by_name($port_id, $hg_name);
            die "host group '$hg_name' not found on $port_id after creation\n"
                unless $hg;
        }

        my $hg_num = $hg->{hostGroupNumber};

        # Reconcile host mode options on the (possibly pre-existing) group: add any
        # configured option that is missing. Only ADDS — never removes options set
        # out-of-band. Needed so groups created before host_mode_options existed
        # still get UNMAP/discard. Best-effort: a failure must not block activation.
        if (@hmo) {
            eval {
                my $info    = $client->get_host_group("$port_id,$hg_num");
                my @current = @{ $info->{hostModeOptions} || [] };
                my %have    = map { $_ => 1 } @current;
                my @missing = grep { !$have{$_} } @hmo;
                if (@missing) {
                    my @union = sort { $a <=> $b } keys %{{ map { $_ => 1 } (@current, @hmo) }};
                    $client->set_host_group_mode(
                        host_group_id     => "$port_id,$hg_num",
                        host_mode         => $host_mode,
                        host_mode_options => \@union,
                    );
                }
            };
            warn "Host mode option reconcile warning ($port_id,$hg_num): $@" if $@;
        }

        # Register any of our WWNs not already present (idempotent).
        my $existing_wwns = eval {
            $client->list_host_wwns(port_id => $port_id, host_group_number => $hg_num);
        } || [];
        my %present = map { lc($_->{hostWwn}) => 1 } @$existing_wwns;
        for my $wwn (@$wwns) {
            next if $present{lc($wwn)};
            eval {
                $client->add_wwn_to_host_group(
                    port_id           => $port_id,
                    host_group_number => $hg_num,
                    wwn               => $wwn,
                );
            };
            warn "WWN add warning ($port_id $wwn): $@" if $@;
        }
    }

    return 1;
}

sub _map_lun_to_local {
    my ($class, $storeid, $scfg, $client, $ldev_id) = @_;

    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $wwns = $multipath->get_local_wwns();

    return unless @$wwns;

    my @ports = $class->_select_ports($storeid, $scfg, $ldev_id);

    for my $port_id (@ports) {
        $port_id =~ s/^\s+|\s+$//g;

        # Find host group containing our WWN on this port
        my $hg;
        for my $wwn (@$wwns) {
            $hg = $client->find_host_group_by_wwn($port_id, $wwn);
            last if $hg;
        }
        next unless $hg;

        # Check if already mapped
        my $luns = $client->list_luns(
            port_id           => $port_id,
            host_group_number => $hg->{hostGroupNumber},
            ldev_id           => $ldev_id,
        );

        unless (@$luns) {
            $client->map_lun(
                port_id           => $port_id,
                host_group_number => $hg->{hostGroupNumber},
                ldev_id           => $ldev_id,
            );
        }
    }

    return 1;
}

sub _unmap_lun_from_local {
    my ($class, $storeid, $scfg, $client, $ldev_id) = @_;

    # SAFETY FENCE: refuse to unmap an LDEV outside our configured range.
    die "refusing to unmap LDEV $ldev_id: outside ldev_range"
        . ($scfg->{ldev_range} ? " '$scfg->{ldev_range}'" : '') . "\n"
        unless $class->_ldev_in_range($scfg, $ldev_id);

    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $wwns = $multipath->get_local_wwns();

    return unless @$wwns;

    my @ports = split(/,/, $scfg->{target_ports} || '');

    for my $port_id (@ports) {
        $port_id =~ s/^\s+|\s+$//g;

        my $hg;
        for my $wwn (@$wwns) {
            $hg = $client->find_host_group_by_wwn($port_id, $wwn);
            last if $hg;
        }
        next unless $hg;

        my $luns = $client->list_luns(
            port_id           => $port_id,
            host_group_number => $hg->{hostGroupNumber},
            ldev_id           => $ldev_id,
        );

        for my $lun (@$luns) {
            eval { $client->unmap_lun($lun->{lunId}) };
            warn "Unmap LUN warning: $@" if $@;
        }
    }

    return 1;
}

sub _qos_from_scfg {
    my ($class, $scfg) = @_;

    my %qos;
    $qos{upper_iops}        = $scfg->{qos_upper_iops} if $scfg->{qos_upper_iops};
    $qos{upper_mbps}        = $scfg->{qos_upper_mbps} if $scfg->{qos_upper_mbps};
    $qos{lower_iops}        = $scfg->{qos_lower_iops} if $scfg->{qos_lower_iops};
    $qos{lower_mbps}        = $scfg->{qos_lower_mbps} if $scfg->{qos_lower_mbps};
    $qos{response_priority} = $scfg->{qos_priority}   if $scfg->{qos_priority};
    return %qos;
}

# Derive an LDEV's size in MB, preferring the exact block count (512-byte blocks)
# over the human-formatted byteFormatCapacity string.
sub _ldev_size_mb {
    my ($class, $ldev) = @_;

    return 0 unless $ldev && ref $ldev eq 'HASH';

    for my $field (qw(blockCapacity numOfBlocks)) {
        my $blocks = $ldev->{$field};
        if (defined $blocks && $blocks =~ /^\d+$/) {
            return int($blocks * 512 / (1024 * 1024));
        }
    }

    my $cap = $ldev->{byteFormatCapacity};
    if (defined $cap) {
        return int($1 * 1024 * 1024) if $cap =~ /^([\d.]+)\s*T/i;
        return int($1 * 1024)        if $cap =~ /^([\d.]+)\s*G/i;
        return int($1)               if $cap =~ /^([\d.]+)\s*M/i;
    }

    return 0;
}

# Discover the volume's real WWID and wait for its multipath device. Tries the
# synthesized NAA first (fast path / correct on matching models); if that does
# not resolve, self-corrects by reading the actual page-83 identifier from sysfs.
# Returns ($wwid, $path); croaks if no device appears (fatal for the caller).
sub _resolve_wwid {
    my ($class, $client, $multipath, $ldev_id, $synth_wwid) = @_;

    $multipath->rescan_scsi_hosts();

    # Authoritative: once the LDEV has an LU path, the array reports its real NAA id
    # (GET /ldevs/{id} -> naaId). Prefer it over the synthesized WWID, whose exact
    # byte layout is model-dependent. Best-effort — fall back if absent/unmapped.
    my $array_wwid = eval {
        my $ldev = $client->get_ldev($ldev_id);
        my $naa = $ldev->{naaId};
        return undef unless defined $naa && length $naa;
        $naa =~ s/^naa\.//i;
        $naa =~ s/^0x//i;
        return lc($naa);
    };
    if ($array_wwid) {
        my $apath = eval { $multipath->wait_for_device($array_wwid) };
        return ($array_wwid, $apath) if $apath;
    }

    # Fallback 1: synthesized NAA (fast path on matching models).
    my $path = eval { $multipath->wait_for_device($synth_wwid, 20) };
    return ($synth_wwid, $path) if $path;

    # Fallback 2: discover the real page-83 id from sysfs.
    my $real = $multipath->discover_wwid($ldev_id);
    if ($real && $real ne $synth_wwid) {
        my $rpath = $multipath->wait_for_device($real);
        return ($real, $rpath);
    }

    # Last resort: full-timeout wait on the synthesized WWID (croaks on failure).
    my $fpath = $multipath->wait_for_device($synth_wwid);
    return ($synth_wwid, $fpath);
}

sub _select_ports {
    my ($class, $storeid, $scfg, $ldev_id) = @_;

    my @all_ports = split(/,/, $scfg->{target_ports} || '');
    @all_ports = map { my $p = $_; $p =~ s/^\s+|\s+$//g; $p } @all_ports;

    return @all_ports unless $scfg->{port_scheduler} && @all_ports > 2;

    # Deterministic per-LDEV selection: a given volume always maps to the same
    # two ports (stable across processes and cluster nodes — no in-memory counter
    # to reset), providing multipath redundancy while spreading volumes across
    # ports. Falls back to ports 0/1 when no LDEV context is available.
    my $n = scalar(@all_ports);
    my $idx = defined $ldev_id ? ($ldev_id % $n) : 0;
    my $next_idx = ($idx + 1) % $n;

    return ($all_ports[$idx], $all_ports[$next_idx]);
}

# Parse an ldev_range ("256-511" or "0x100-0x1ff") into ($min, $max); dies on a
# malformed range.
sub _parse_ldev_range {
    my ($class, $range) = @_;

    my ($min, $max);
    if ($range =~ /^(0x[0-9a-f]+)-(0x[0-9a-f]+)$/i) {
        $min = hex($1);
        $max = hex($2);
    } elsif ($range =~ /^(\d+)-(\d+)$/) {
        $min = int($1);
        $max = int($2);
    } else {
        die "Invalid ldev_range format '$range' (expected 'min-max')\n";
    }

    die "Invalid ldev_range: min ($min) > max ($max)\n" if $min > $max;
    return ($min, $max);
}

# Describe an ldev_range in CU terms. Returns ($aligned, $first_cu, $last_cu):
# $aligned is true when the range starts on a CU boundary and ends one id below
# one (i.e. covers whole CUs). Pure function — no array access.
sub _ldev_range_cu_info {
    my ($class, $min, $max) = @_;
    my $aligned = (($min % $LDEVS_PER_CU) == 0)
        && ((($max + 1) % $LDEVS_PER_CU) == 0);
    return ($aligned, int($min / $LDEVS_PER_CU), int($max / $LDEVS_PER_CU));
}

# Emit an informational hint (never fatal) if ldev_range is not CU-aligned, so
# operators get clean per-CU reservations and optimal paging. No-op when unset.
sub _warn_if_ldev_range_misaligned {
    my ($class, $range) = @_;
    return unless defined $range && length $range;
    my ($min, $max) = $class->_parse_ldev_range($range);
    my ($aligned, $first_cu, $last_cu) = $class->_ldev_range_cu_info($min, $max);
    return if $aligned;
    warn sprintf(
        "hitachiblock: ldev_range %s is not CU-aligned (spans CU 0x%02X-0x%02X "
      . "partially). For clean per-CU reservation and optimal paging, align to "
      . "256-LDEV CU boundaries, e.g. CU N = %d-%d.\n",
        $range, $first_cu, $last_cu,
        $first_cu * $LDEVS_PER_CU, $first_cu * $LDEVS_PER_CU + $LDEVS_PER_CU - 1,
    );
    return;
}

# SAFETY GUARD: true if $ldev_id is inside the configured ldev_range. With no
# range configured there is no fence (returns true). Call before ANY destructive
# op (unmap/delete) so the plugin can never act on an LDEV it does not own — e.g.
# another host's production volumes that merely share a target port. The array
# does NOT filter LUN queries by ldevId (verified on the E590H), so this fence is
# the backstop that keeps us off foreign LUNs.
sub _ldev_in_range {
    my ($class, $scfg, $ldev_id) = @_;

    my $range = $scfg->{ldev_range};
    return 1 unless defined $range && length $range;
    return 0 unless defined $ldev_id;

    my ($min, $max) = $class->_parse_ldev_range($range);
    return ($ldev_id >= $min && $ldev_id <= $max) ? 1 : 0;
}

sub _next_ldev_in_range {
    my ($class, $client, $scfg, $config) = @_;

    my $range = $scfg->{ldev_range}
        or die "ldev_range is not configured\n";

    my ($min, $max) = $class->_parse_ldev_range($range);

    # IDs reserved cluster-wide by the local registry — a cheap local read, always
    # excluded. (A residual cross-node race is backstopped by the array rejecting a
    # duplicate explicit ldevId on create.)
    my %reserved;
    if ($config) {
        my $registry = $config->list_registered();
        for my $entry (values %$registry) {
            next unless ref $entry eq 'HASH';
            $reserved{$entry->{ldev_id}} = 1 if defined $entry->{ldev_id};
        }
    }

    # Scan the range one CU-sized window at a time and return the first free id.
    # The default list_ldevs() only returns slots 0-99, so a high range must be
    # paged (and only DEFINED LDEVs count as used — a foreign LDEV in-range must
    # never be overwritten). Early termination keeps allocation at ~1 REST call
    # when the low end of the range is free, instead of paging the whole range —
    # important for wide multi-CU ranges.
    for (my $head = $min; $head <= $max; $head += $LDEVS_PER_CU) {
        my $end = $head + $LDEVS_PER_CU - 1;
        $end = $max if $end > $max;

        my %used = %reserved;
        my $batch = $client->list_ldevs(head_ldev_id => $head, count => $end - $head + 1);
        for my $ldev (@$batch) {
            my $id = $ldev->{ldevId};
            next unless defined $id;
            next if ($ldev->{emulationType} // '') eq 'NOT DEFINED';
            $used{$id} = 1;
        }

        for my $id ($head .. $end) {
            return $id unless $used{$id};
        }
    }

    die "No available LDEV IDs in range $range ($min-$max)\n";
}

sub _cleanup_empty_host_groups {
    my ($class, $storeid, $scfg, $client) = @_;

    my @ports = split(/,/, $scfg->{target_ports} || '');
    my $hostname = `hostname -s`;
    chomp($hostname);
    my $hg_prefix = "PVE_${hostname}";

    for my $port_id (@ports) {
        $port_id =~ s/^\s+|\s+$//g;
        my $groups = $client->list_host_groups(port_id => $port_id);

        for my $hg (@$groups) {
            next unless ($hg->{hostGroupName} || '') =~ /^\Q$hg_prefix\E/;

            # Check if host group has any LUN mappings
            my $luns = eval {
                $client->list_luns(
                    port_id           => $port_id,
                    host_group_number => $hg->{hostGroupNumber},
                );
            } || [];

            if (!@$luns) {
                eval { $client->delete_host_group($hg->{hostGroupId}) };
                warn "Delete host group $hg->{hostGroupId}: $@" if $@;
            }
        }
    }

    return 1;
}

sub vmid_from_volname {
    my ($volname) = @_;

    return ($volname =~ /^(?:vm|base)-(\d+)-/) ? $1 : 0;
}

sub parse_volname {
    my ($class, $volname) = @_;

    # Returns: ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    if ($volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return ('images', $volname, $1, undef, undef, 1, 'raw');
    }

    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return ('images', $volname, $1, undef, undef, undef, 'raw');
    }

    # Cloud-init drive: PVE allocates a tiny raw LUN named vm-<vmid>-cloudinit and
    # writes an ISO9660 config image to the block device. It is a regular raw volume
    # (size floored to the array minimum by _alloc_size_mb); only the name differs from
    # a data disk, so the rest of the lifecycle (alloc/map/path/free) needs no special
    # casing once the name parses. Without this branch alloc_image creates an LDEV that
    # parse_volname later rejects, leaking the array volume (GitHub #6).
    if ($volname =~ /^vm-(\d+)-cloudinit$/) {
        return ('images', $volname, $1, undef, undef, undef, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

# ── Base / Template Images ──

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my (undef, $name, $vmid, undef, undef, $isBase) = $class->parse_volname($volname);
    die "create_base not possible for base image '$volname'\n" if $isBase;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    my $deps = $config->find_dependents($volname);
    die "Cannot convert '$volname' to a base image: linked clone(s) depend on it: "
        . join(', ', sort @$deps) . "\n" if @$deps;

    my ($disk) = $name =~ /-disk-(\d+)$/;
    my $base_name = "base-${vmid}-disk-${disk}";

    # Relabel the LDEV and atomically rename the registry entry.
    my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $base_name);
    $client->set_ldev_label($ldev_id, $label);

    $config->rename_volume($volname, $base_name);

    return $base_name;
}

# Reassign a volume to another VMID / name (PVE "Reassign disk", qm disk reassign).
# Relabels the LDEV on the array and atomically renames the registry entry.
sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my ($ldev_id) = $config->lookup_ldev($source_volname);
    die "Volume '$source_volname' not found in registry\n" unless defined $ldev_id;

    # Renaming a parent would dangle its linked clones' parent_volname reference.
    my $deps = $config->find_dependents($source_volname);
    die "Cannot rename '$source_volname': linked clone(s) depend on it: "
        . join(', ', sort @$deps) . "\n" if @$deps;

    my $format = ($class->parse_volname($source_volname))[6];
    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, $format)
        if !$target_volname;

    my $client = $class->_client($storeid, $scfg);
    my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $target_volname);
    $client->set_ldev_label($ldev_id, $label);

    $config->rename_volume($source_volname, $target_volname);

    return "${storeid}:${target_volname}";
}

# ── Manage / Unmanage Volumes (LDEV Import) ──

sub manage_volume {
    my ($class, $storeid, $scfg, $ldev_id, $vmid) = @_;

    die "ldev_id is required\n" unless defined $ldev_id;
    die "vmid is required\n"    unless defined $vmid;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    # Verify LDEV exists on the array
    my $ldev = $client->get_ldev($ldev_id);
    die "LDEV $ldev_id not found on array\n" unless $ldev;

    # Refuse to import an LDEV that is already tracked under another volname —
    # otherwise two volids would point at one LDEV.
    if (my $existing = $config->find_volname_by_ldev($ldev_id)) {
        die "LDEV $ldev_id is already managed as '$existing'\n";
    }

    # Current size from the array (prefer exact block count).
    my $size_mb = $class->_ldev_size_mb($ldev);

    # Reserve a unique volume name under the cluster lock.
    my $name = $config->reserve_volname($vmid);
    my $committed = 0;

    eval {
        my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $name);
        $client->set_ldev_label($ldev_id, $label);

        # Map + discover are prerequisites: failure is fatal.
        $class->_map_lun_to_local($storeid, $scfg, $client, $ldev_id);

        my $synth = $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
        my ($wwid) = $class->_resolve_wwid($client, $multipath, $ldev_id, $synth);

        # Commit to the registry LAST.
        $config->register_ldev($name, $ldev_id,
            wwid    => $wwid,
            size_mb => $size_mb,
            pool_id => $ldev->{poolId} // $scfg->{pool_id},
        );
        $committed = 1;
    };
    if (my $err = $@) {
        # Roll back the mapping/label but NEVER delete the imported LDEV.
        eval { $class->_unmap_lun_from_local($storeid, $scfg, $client, $ldev_id) };
        eval { $client->set_ldev_label($ldev_id, '') };
        eval { $config->unregister_ldev($name) } unless $committed;
        die "Failed to manage LDEV $ldev_id as '$name': $err";
    }

    return $name;
}

sub unmanage_volume {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "volname is required\n" unless $volname;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    # Remove device and unmap from local node
    eval {
        my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
        $multipath->remove_device($wwid);
        $class->_unmap_lun_from_local($storeid, $scfg, $client, $ldev_id);
    };
    warn "Unmanage cleanup warning: $@" if $@;

    # Clear the PVE label from the LDEV (LDEV itself is NOT deleted)
    eval { $client->set_ldev_label($ldev_id, '') };
    warn "Label clear warning: $@" if $@;

    # Remove from registry
    $config->unregister_ldev($volname);

    return $ldev_id;
}

# ── Consistency Group Snapshots ──

sub volume_snapshot_consistency_group {
    my ($class, $scfg, $storeid, $volnames, $snap) = @_;

    die "volnames arrayref is required\n" unless ref $volnames eq 'ARRAY' && @$volnames;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my $snap_pool_id = $scfg->{snap_pool_id} // $scfg->{pool_id};
    my $snap_group = "pve_cg_${storeid}_${snap}";

    # Resolve all LDEV ids up front so a missing volume fails before we create any
    # pairs at all.
    my @members;
    for my $volname (@$volnames) {
        my ($ldev_id) = $config->lookup_ldev($volname);
        die "Volume '$volname' not found\n" unless defined $ldev_id;
        push @members, { volname => $volname, ldev_id => $ldev_id };
    }

    # Create one Thin Image pair per volume, all sharing $snap_group with
    # isConsistencyGroup set so the array treats them as a single CG. This is the
    # array's CG primitive, but pairs are still added one call at a time, so if any
    # call fails we roll back the pairs already created in this group rather than
    # leaving a half-built, non-crash-consistent group behind.
    my @created;
    eval {
        for my $m (@members) {
            my %snap_opts = (
                pvol_ldev_id         => $m->{ldev_id},
                snap_pool_id         => $snap_pool_id,
                snapshot_group       => $snap_group,
                is_consistency_group => 1,
            );
            $snap_opts{copy_speed} = $scfg->{copy_speed} if $scfg->{copy_speed};

            $client->create_snapshot(%snap_opts);
            push @created, $m->{ldev_id};
        }
    };
    if (my $err = $@) {
        for my $ldev_id (@created) {
            eval {
                my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
                for my $s (@$snaps) {
                    next unless ($s->{snapshotGroupName} || '') eq $snap_group;
                    $client->delete_snapshot($s->{snapshotId}) if $s->{snapshotId};
                }
            };
            warn "CG rollback warning for LDEV $ldev_id: $@" if $@;
        }
        die "Consistency group snapshot '$snap' failed and was rolled back: $err";
    }

    # Register snapshot metadata for each volume
    for my $volname (@$volnames) {
        my ($ldev_id) = $config->lookup_ldev($volname);

        eval {
            my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
            for my $s (@$snaps) {
                if (($s->{snapshotGroupName} || '') eq $snap_group) {
                    my %snap_meta = (
                        snapshot_group    => $snap_group,
                        pvol_ldev_id      => $ldev_id,
                        consistency_group => 1,
                    );
                    if (defined $s->{svolLdevId}) {
                        $snap_meta{svol_ldev_id} = $s->{svolLdevId};
                        $snap_meta{svol_wwid} = $multipath->ldev_to_wwid(
                            $scfg->{storage_id}, $s->{svolLdevId});
                    }
                    $snap_meta{snapshot_id} = $s->{snapshotId} if defined $s->{snapshotId};
                    $config->register_snapshot($volname, $snap, %snap_meta);
                    last;
                }
            }
        };
        warn "Consistency group snapshot metadata warning for '$volname': $@" if $@;
    }

    return undef;
}

# ── Storage-Assisted Volume Migration ──

sub volume_migrate_pool {
    my ($class, $storeid, $scfg, $volname, $target_pool_id) = @_;

    die "volname is required\n"        unless $volname;
    die "target_pool_id is required\n" unless defined $target_pool_id;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Migrate LDEV to the target pool (array-side, no host I/O)
    $client->migrate_ldev($ldev_id, $target_pool_id);

    # Update registry with new pool
    $config->register_ldev($volname, $ldev_id, %$meta, pool_id => $target_pool_id);

    return 1;
}

# ── Orphan Detection ──

sub list_orphans {
    my ($class, $storeid, $scfg) = @_;

    my $client = $class->_client($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $registry = $config->list_registered();
    my $label_prefix = PVE::Storage::HitachiBlock::Config->label_prefix($storeid);

    # Scan every pool this storage could place volumes in — the data pool, the
    # snapshot S-VOL pool, and any pool referenced by a registry entry (volumes
    # imported or migrated from other pools). Scanning only pool_id would make
    # those volumes look "missing on-array" and let cleanup unregister live data.
    my %pools;
    $pools{$scfg->{pool_id}}      = 1 if defined $scfg->{pool_id};
    $pools{$scfg->{snap_pool_id}} = 1 if defined $scfg->{snap_pool_id};
    for my $entry (values %$registry) {
        next unless ref $entry eq 'HASH';
        $pools{$entry->{pool_id}} = 1 if defined $entry->{pool_id};
    }

    my %seen_ldev;
    my $ldevs = [];
    for my $pid (sort { $a <=> $b } keys %pools) {
        my $pool_ldevs = $client->list_ldevs(pool_id => $pid);
        for my $ldev (@$pool_ldevs) {
            next unless defined $ldev->{ldevId};
            next if $seen_ldev{$ldev->{ldevId}}++;
            push @$ldevs, $ldev;
        }
    }

    my %registered_ldevs;
    for my $entry (values %$registry) {
        next unless ref $entry eq 'HASH';
        $registered_ldevs{$entry->{ldev_id}} = 1 if defined $entry->{ldev_id};
    }

    my @orphans_on_array;   # LDEVs on array not in registry
    my @orphans_in_registry; # registry entries whose LDEV doesn't exist

    # Find array-side orphans
    for my $ldev (@$ldevs) {
        my $label = $ldev->{label} || '';
        next unless $label =~ /^\Q$label_prefix\E/;

        my $ldev_id = $ldev->{ldevId};
        next if defined $ldev_id && $registered_ldevs{$ldev_id};

        push @orphans_on_array, {
            ldev_id => $ldev_id,
            label   => $label,
        };
    }

    # Find registry-side orphans (LDEV no longer exists on array)
    my %array_ldev_ids;
    for my $ldev (@$ldevs) {
        $array_ldev_ids{$ldev->{ldevId}} = 1 if defined $ldev->{ldevId};
    }

    for my $volname (keys %$registry) {
        my $entry = $registry->{$volname};
        my $ldev_id = $entry->{ldev_id};
        next unless defined $ldev_id;

        unless ($array_ldev_ids{$ldev_id}) {
            push @orphans_in_registry, {
                volname => $volname,
                ldev_id => $ldev_id,
            };
        }
    }

    return {
        array_orphans    => \@orphans_on_array,
        registry_orphans => \@orphans_in_registry,
    };
}

sub cleanup_registry_orphans {
    my ($class, $storeid, $scfg) = @_;

    my $orphans = $class->list_orphans($storeid, $scfg);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my $cleaned = 0;
    for my $orphan (@{$orphans->{registry_orphans}}) {
        $config->unregister_ldev($orphan->{volname});
        $cleaned++;
    }

    return $cleaned;
}

1;
