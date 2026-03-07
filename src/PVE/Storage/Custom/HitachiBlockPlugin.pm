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

# ── Plugin Identity ──

sub api {
    return 1;
}

sub type {
    return 'hitachiblock';
}

sub plugindata {
    return {
        content => [ { images => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }  , 'raw' ],
    };
}

# ── Configuration Schema ──

sub properties {
    return {
        mgmt_ip => {
            description => "Management IP or hostname of the Hitachi Configuration Manager.",
            type        => 'string',
        },
        storage_id => {
            description => "Storage system serial number / device ID.",
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
        platform => {
            description => "Storage platform type: vsp_g or vsp_one.",
            type        => 'string',
            enum        => ['vsp_g', 'vsp_one'],
            default     => 'vsp_one',
            optional    => 1,
        },
        mgmt_port => {
            description => "Management API port (auto-detected from platform if omitted).",
            type        => 'integer',
            optional    => 1,
        },
        username => {
            description => "API username (stored in credential file, not in storage.cfg).",
            type        => 'string',
            optional    => 1,
        },
        password => {
            description => "API password (stored in credential file, not in storage.cfg).",
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
        platform     => { optional => 1 },
        mgmt_port    => { optional => 1 },
        nodes        => { optional => 1 },
        shared       => { optional => 1 },
        disable      => { optional => 1 },
        content      => { optional => 1 },
        username     => { optional => 1 },
        password     => { optional => 1 },
    };
}

# ── Hooks ──

sub on_add_hook {
    my ($class, $storeid, $scfg, %params) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    # Store credentials if provided
    my $username = delete $scfg->{username};
    my $password = delete $scfg->{password};

    if ($username && $password) {
        $config->store_credentials($username, $password);
    }

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

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    $config->delete_credentials();

    return;
}

# ── Storage Lifecycle ──

my %_clients;  # cache: storeid -> RestClient

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

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
        eval { $client->logout() };
    }

    return 1;
}

# ── Status ──

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $client = $class->_client($storeid);
    my $pool = $client->get_pool($scfg->{pool_id});

    # Pool capacities are in bytes (or block count depending on API version)
    my $total = ($pool->{totalPoolCapacity}  || 0);
    my $used  = ($pool->{usedPoolCapacity}   || 0);
    my $free  = $total - $used;

    # Convert from MB to bytes if needed (API returns MB)
    if ($total < 1_000_000_000 && $total > 0) {
        $total *= 1024 * 1024;
        $used  *= 1024 * 1024;
        $free  *= 1024 * 1024;
    }

    return ($total, $free, $used, 1);
}

# ── Image Lifecycle ──

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'\n" if $fmt && $fmt ne 'raw';

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    # Generate volume name
    $name = $class->_next_volname($config, $vmid) unless $name;

    # Size is in KiB from PVE, convert to MB for Hitachi API
    my $size_mb = ceil($size / 1024);
    $size_mb = 1 if $size_mb < 1;

    # Create LDEV
    my $result = $client->create_ldev(
        pool_id => $scfg->{pool_id},
        size_mb => $size_mb,
    );
    my $ldev_id = $result->{resourceId}
        or die "Failed to get LDEV ID from create response\n";

    # Set label for identification
    my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $name);
    eval { $client->set_ldev_label($ldev_id, $label) };
    warn "Failed to set LDEV label: $@" if $@;

    # Register in local map
    my $ldev_info = $client->get_ldev($ldev_id);
    my $wwid = $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);

    $config->register_ldev($name, $ldev_id,
        wwid     => $wwid,
        size_mb  => $size_mb,
        pool_id  => $scfg->{pool_id},
    );

    # Map LUN to local host groups on all target ports
    eval { $class->_map_lun_to_local($storeid, $scfg, $client, $ldev_id) };
    if ($@) {
        warn "LUN mapping failed: $@";
    }

    # Rescan SCSI bus to discover new device
    eval {
        $multipath->rescan_scsi_hosts();
        $multipath->wait_for_device($wwid);
    };
    warn "Device discovery warning: $@" if $@;

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    # Delete any snapshot pairs first
    eval {
        my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
        for my $snap (@$snaps) {
            $client->delete_snapshot($snap->{snapshotId}) if $snap->{snapshotId};
        }
    };
    warn "Snapshot cleanup warning: $@" if $@;

    # Unmap LUN from all host groups
    eval {
        my $luns = $client->list_luns(ldev_id => $ldev_id);
        for my $lun (@$luns) {
            $client->unmap_lun($lun->{lunId}) if $lun->{lunId};
        }
    };
    warn "LUN unmap warning: $@" if $@;

    # Remove multipath device from host
    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    eval { $multipath->remove_device($wwid) };
    warn "Device removal warning: $@" if $@;

    # Delete LDEV
    $client->delete_ldev($ldev_id);

    # Unregister
    $config->unregister_ldev($volname);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $registry = $config->list_registered();

    my @res;
    my $label_prefix = "pve:${storeid}:";

    for my $volname (sort keys %$registry) {
        my $entry = $registry->{$volname};

        # Filter by vmid if specified
        if ($vmid) {
            next unless $volname =~ /^vm-(\d+)-/ && $1 == $vmid;
        }

        # Filter by vollist if specified
        if ($vollist) {
            my $full = "$storeid:$volname";
            next unless grep { $_ eq $full } @$vollist;
        }

        my $size = ($entry->{size_mb} || 0) * 1024 * 1024;

        push @res, {
            volid  => "$storeid:$volname",
            format => 'raw',
            size   => $size,
            vmid   => ($volname =~ /^vm-(\d+)-/) ? $1 : 0,
            parent => undef,
        };
    }

    return \@res;
}

# ── Volume Lifecycle ──

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    my $client = $class->_client($storeid);
    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);

    # Ensure LUN is mapped to this node (handles post-migration case)
    eval { $class->_map_lun_to_local($storeid, $scfg, $client, $ldev_id) };
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

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    return 1 unless defined $ldev_id;

    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);

    # Flush and remove multipath device
    eval { $multipath->remove_device($wwid) };
    warn "Device deactivation warning: $@" if $@;

    # Unmap LUN from this node's host group
    eval {
        my $client = $class->_client($storeid);
        $class->_unmap_lun_from_local($storeid, $scfg, $client, $ldev_id);
    };
    warn "LUN unmap warning: $@" if $@;

    return 1;
}

sub filesystem_path {
    my ($class, $scfg, $volname, $storeid) = @_;

    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found in registry\n" unless defined $ldev_id;

    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    my $path = $multipath->get_device_path($wwid);

    return wantarray ? ($path, vmid_from_volname($volname), 'raw') : $path;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    return $class->filesystem_path($scfg, $volname, $storeid);
}

# ── Snapshots ──

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    my $snap_pool_id = $scfg->{snap_pool_id} // $scfg->{pool_id};

    my $result = $client->create_snapshot(
        pvol_ldev_id   => $ldev_id,
        snap_pool_id   => $snap_pool_id,
        snapshot_group => "pve_${storeid}_${snap}",
    );

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Find the matching snapshot pair
    my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
    my $target_group = "pve_${storeid}_${snap}";

    for my $s (@$snaps) {
        if (($s->{snapshotGroupName} || '') eq $target_group) {
            $client->delete_snapshot($s->{snapshotId});
            return 1;
        }
    }

    die "Snapshot '$snap' not found for volume '$volname'\n";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);

    my ($ldev_id) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    my $snaps = $client->list_snapshots(pvol_ldev_id => $ldev_id);
    my $target_group = "pve_${storeid}_${snap}";

    for my $s (@$snaps) {
        if (($s->{snapshotGroupName} || '') eq $target_group) {
            $client->restore_snapshot($s->{snapshotId});
            return 1;
        }
    }

    die "Snapshot '$snap' not found for volume '$volname'\n";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my %features = (
        snapshot => { current => 1 },
        clone    => { current => 1, snap => 1 },
        copy     => { current => 1, snap => 1 },
    );

    my $opts = $features{$feature} || return 0;
    return $snapname ? ($opts->{snap} ? 1 : 0) : ($opts->{current} ? 1 : 0);
}

# ── Clone ──

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap, $running, $target) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($src_ldev_id, $src_meta) = $config->lookup_ldev($volname);
    die "Source volume '$volname' not found\n" unless defined $src_ldev_id;

    my $new_name = $class->_next_volname($config, $vmid);
    my $snap_pool_id = $scfg->{snap_pool_id} // $scfg->{pool_id};

    # Get source size for new LDEV
    my $src_ldev = $client->get_ldev($src_ldev_id);
    my $size_mb = $src_meta->{size_mb} || 1;

    # Determine if linked (thin) or full clone
    my $is_full = ($target && $target eq 'full') ? 1 : 0;

    my $new_ldev_id;

    if ($is_full) {
        # Full clone: create new LDEV, then copy via snapshot
        my $result = $client->create_ldev(
            pool_id => $scfg->{pool_id},
            size_mb => $size_mb,
        );
        $new_ldev_id = $result->{resourceId}
            or die "Failed to create target LDEV for full clone\n";

        $client->clone_snapshot_to_ldev(
            pvol_ldev_id   => $src_ldev_id,
            svol_ldev_id   => $new_ldev_id,
            snap_pool_id   => $snap_pool_id,
            snapshot_group => "pve_clone_${storeid}",
        );
    } else {
        # Linked clone: create Thin Image pair (S-VOL shares blocks via CoW)
        my $result = $client->create_ldev(
            pool_id => $snap_pool_id,
            size_mb => $size_mb,
        );
        $new_ldev_id = $result->{resourceId}
            or die "Failed to create S-VOL for linked clone\n";

        $client->clone_snapshot_to_ldev(
            pvol_ldev_id   => $src_ldev_id,
            svol_ldev_id   => $new_ldev_id,
            snap_pool_id   => $snap_pool_id,
            snapshot_group => "pve_lclone_${storeid}",
        );
    }

    # Label and register new LDEV
    my $label = PVE::Storage::HitachiBlock::Config->make_label($storeid, $new_name);
    eval { $client->set_ldev_label($new_ldev_id, $label) };
    warn "Failed to set clone label: $@" if $@;

    my $wwid = $multipath->ldev_to_wwid($scfg->{storage_id}, $new_ldev_id);
    $config->register_ldev($new_name, $new_ldev_id,
        wwid     => $wwid,
        size_mb  => $size_mb,
        pool_id  => $is_full ? $scfg->{pool_id} : $snap_pool_id,
    );

    # Map and discover
    eval { $class->_map_lun_to_local($storeid, $scfg, $client, $new_ldev_id) };
    warn "Clone LUN mapping: $@" if $@;

    eval {
        $multipath->rescan_scsi_hosts();
        $multipath->wait_for_device($wwid);
    };
    warn "Clone device discovery: $@" if $@;

    return $new_name;
}

# ── Resize ──

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $client = $class->_client($storeid);
    my $config = PVE::Storage::HitachiBlock::Config->new(storeid => $storeid);
    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();

    my ($ldev_id, $meta) = $config->lookup_ldev($volname);
    die "Volume '$volname' not found\n" unless defined $ldev_id;

    # Size is in bytes from PVE, convert to MB
    my $new_size_mb = ceil($size / (1024 * 1024));
    my $current_mb  = $meta->{size_mb} || 0;
    my $additional   = $new_size_mb - $current_mb;

    die "Cannot shrink volume (requested ${new_size_mb}MB, current ${current_mb}MB)\n"
        if $additional <= 0;

    # Expand LDEV on array
    $client->expand_ldev($ldev_id, $additional);

    # Update registry
    $config->register_ldev($volname, $ldev_id,
        %$meta,
        size_mb => $new_size_mb,
    );

    # Resize multipath device on host
    my $wwid = $meta->{wwid} || $multipath->ldev_to_wwid($scfg->{storage_id}, $ldev_id);
    eval { $multipath->resize_device($wwid) };
    warn "Host-side resize warning: $@" if $@;

    return 1;
}

# ── Internal Helpers ──

sub _client {
    my ($class, $storeid) = @_;

    my $client = $_clients{$storeid};
    croak "Storage '$storeid' is not activated" unless $client;

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
        mgmt_ip    => $scfg->{mgmt_ip},
        port       => $port,
        storage_id => $scfg->{storage_id},
        username   => $username,
        password   => $password,
    );
}

sub _ensure_host_groups {
    my ($class, $storeid, $scfg, $client) = @_;

    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $wwns = $multipath->get_local_wwns();

    return unless @$wwns;

    my @ports = split(/,/, $scfg->{target_ports} || '');
    my $host_mode = $scfg->{host_mode} || 'LINUX/IRIX';
    my $hostname = `hostname -s`;
    chomp($hostname);

    for my $port_id (@ports) {
        $port_id =~ s/^\s+|\s+$//g;

        # Check if a host group with our WWNs already exists
        my $existing_hg;
        for my $wwn (@$wwns) {
            $existing_hg = $client->find_host_group_by_wwn($port_id, $wwn);
            last if $existing_hg;
        }

        unless ($existing_hg) {
            # Create new host group
            my $hg_name = "PVE_${hostname}";
            my $result = $client->create_host_group(
                port_id         => $port_id,
                host_group_name => $hg_name,
                host_mode       => $host_mode,
            );

            my $hg_id = $result->{resourceId};
            # Add all local WWNs
            for my $wwn (@$wwns) {
                eval {
                    $client->add_wwn_to_host_group(
                        host_group_id => "${port_id},${hg_id}",
                        port_id       => $port_id,
                        wwn           => $wwn,
                        nickname      => "PVE_${hostname}_${wwn}",
                    );
                };
                warn "WWN add warning: $@" if $@;
            }
        }
    }

    return 1;
}

sub _map_lun_to_local {
    my ($class, $storeid, $scfg, $client, $ldev_id) = @_;

    my $multipath = PVE::Storage::HitachiBlock::Multipath->new();
    my $wwns = $multipath->get_local_wwns();

    return unless @$wwns;

    my @ports = split(/,/, $scfg->{target_ports} || '');

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

sub _next_volname {
    my ($class, $config, $vmid) = @_;

    my $registry = $config->list_registered();
    my $max_seq = 0;

    for my $name (keys %$registry) {
        if ($name =~ /^vm-${vmid}-disk-(\d+)$/) {
            $max_seq = $1 if $1 > $max_seq;
        }
    }

    return "vm-${vmid}-disk-" . ($max_seq + 1);
}

sub vmid_from_volname {
    my ($volname) = @_;

    return ($volname =~ /^vm-(\d+)-/) ? $1 : 0;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return ('images', $volname, $1, undef, undef, undef, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

1;
