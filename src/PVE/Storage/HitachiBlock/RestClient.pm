package PVE::Storage::HitachiBlock::RestClient;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON qw(encode_json decode_json);
use Carp qw(croak);

# Default timeouts and retry settings
my $DEFAULT_TIMEOUT     = 30;
my $JOB_POLL_INTERVAL   = 2;
my $JOB_POLL_TIMEOUT    = 300;
my $MAX_RETRIES         = 3;
my $RETRY_DELAY         = 2;

sub new {
    my ($class, %opts) = @_;

    croak "mgmt_ip is required"    unless $opts{mgmt_ip};
    croak "storage_id is required" unless $opts{storage_id};
    croak "username is required"   unless $opts{username};
    croak "password is required"   unless $opts{password};

    # mgmt_ip may be a comma-separated list of per-controller management endpoints
    # (e.g. each VSP controller's GUM). We keep a "current" endpoint and fail over
    # to the next one on a transport-level failure, re-authenticating there. A
    # single IP (or a floating management VIP) is just a one-element list.
    my @endpoints =
        grep { length } map { my $h = $_; $h =~ s/^\s+|\s+$//g; $h } split(/,/, $opts{mgmt_ip});
    croak "mgmt_ip is required" unless @endpoints;

    my $port = $opts{port} || 443;

    # TLS verification is opt-in: Configuration Manager ships a self-signed cert by
    # default, so verification is disabled unless the caller explicitly enables it
    # (optionally pinning a CA bundle).
    my %ssl_opts = ( verify_hostname => 0, SSL_verify_mode => 0 );
    if ($opts{tls_verify}) {
        $ssl_opts{verify_hostname} = 1;
        $ssl_opts{SSL_verify_mode} = 0x01;   # SSL_VERIFY_PEER
        $ssl_opts{SSL_ca_file}     = $opts{tls_ca_file} if $opts{tls_ca_file};
    }

    my $ua = LWP::UserAgent->new(
        timeout  => $opts{timeout} || $DEFAULT_TIMEOUT,
        ssl_opts => \%ssl_opts,
    );

    my $self = bless {
        endpoints  => \@endpoints,
        ep_idx     => 0,
        mgmt_ip    => $endpoints[0],   # current active endpoint
        port       => $port,
        storage_id => $opts{storage_id},
        username   => $opts{username},
        password   => $opts{password},
        ua         => $ua,
        token      => undef,
        session_id => undef,
    }, $class;

    $self->{base_url} = $self->_build_base_url();

    return $self;
}

sub _build_base_url {
    my ($self) = @_;
    return "https://$self->{mgmt_ip}:$self->{port}"
        . "/ConfigurationManager/v1/objects/storages/$self->{storage_id}";
}

# Advance to the next management endpoint (controller). Returns false when there is
# only one endpoint (nothing to fail over to). The session token is per-controller,
# so it is dropped — the caller must re-authenticate against the new endpoint.
sub _switch_endpoint {
    my ($self) = @_;

    my $n = scalar(@{$self->{endpoints}});
    return 0 if $n < 2;

    $self->{ep_idx}     = ($self->{ep_idx} + 1) % $n;
    $self->{mgmt_ip}    = $self->{endpoints}[$self->{ep_idx}];
    $self->{base_url}   = $self->_build_base_url();
    $self->{token}      = undef;
    $self->{session_id} = undef;

    return 1;
}

# A response LWP synthesized for a connect/timeout/DNS failure (vs. a real HTTP
# status from the controller) is marked "Client-Warning: Internal response".
sub _is_transport_error {
    my ($self, $res) = @_;
    return 0 unless $res;
    return ($res->header('Client-Warning') // '') eq 'Internal response' ? 1 : 0;
}

# Rewrite the scheme+authority of an absolute URL to the current endpoint, so a
# request built for a now-failed controller is re-targeted at the survivor.
sub _rewrite_host {
    my ($self, $url) = @_;
    $url =~ s{^https?://[^/]+}{https://$self->{mgmt_ip}:$self->{port}};
    return $url;
}

sub _sessions_url {
    my ($self) = @_;
    return "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/sessions";
}

# ── Session Management ──

sub login {
    my ($self) = @_;

    # Session creation is on the critical path for activate_storage/on_add_hook, so
    # it gets the same transient-error handling as _request: retry on rate limits
    # (429) and 5xx, honoring Retry-After. These codes mean the request was not
    # processed, so retrying cannot create duplicate sessions. A transport-level
    # failure (controller unreachable) fails over to the next endpoint and retries
    # there, so login succeeds as long as any controller's GUM is up.
    my $retries  = 0;
    my $tried    = 0;
    my $max_ep   = scalar(@{$self->{endpoints}});
    my $last_err = '';

    while (1) {
        my $req = HTTP::Request->new('POST', $self->_sessions_url());
        $req->header('Content-Type'  => 'application/json');
        $req->header('Accept'        => 'application/json');
        $req->authorization_basic($self->{username}, $self->{password});
        $req->content(encode_json({}));

        my $res = $self->{ua}->request($req);

        if ($res->is_success) {
            my $data = decode_json($res->content);
            $self->{token}      = $data->{token};
            $self->{session_id} = $data->{sessionId};
            return $self->{token};
        }

        $last_err = $res->status_line . " " . ($res->content || '');

        # Controller unreachable → try the next endpoint (bounded by endpoint count).
        if ($self->_is_transport_error($res) && ++$tried < $max_ep && $self->_switch_endpoint()) {
            next;
        }

        my $code = $res->code;
        if (($code == 429 || $code >= 500) && $retries < $MAX_RETRIES) {
            $retries++;
            my $delay = $RETRY_DELAY * $retries;
            if (my $retry_after = $res->header('Retry-After')) {
                $delay = $retry_after if $retry_after =~ /^\d+$/ && $retry_after > $delay;
            }
            sleep($delay);
            next;
        }

        last;
    }

    croak "Login failed (endpoints: " . join(',', @{$self->{endpoints}}) . "): $last_err";
}

sub logout {
    my ($self) = @_;
    return unless $self->{session_id};

    my $url = "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/sessions/$self->{session_id}";
    eval {
        $self->_request('DELETE', $url, undef, 1);
    };
    $self->{token}      = undef;
    $self->{session_id} = undef;

    return;
}

sub keepalive {
    my ($self) = @_;
    return unless $self->{session_id};

    my $url = "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/sessions/$self->{session_id}";
    my $res = $self->_request('PATCH', $url);
    return 1;
}

# ── LDEV Operations ──

sub create_ldev {
    my ($self, %opts) = @_;

    croak "pool_id is required"   unless defined $opts{pool_id};
    croak "size_mb is required"   unless defined $opts{size_mb};

    my $body = {
        poolId       => int($opts{pool_id}),
        byteFormatCapacity => $opts{size_mb} . "M",
        isParallelExecutionEnabled => JSON::true,
    };

    $body->{ldevId} = int($opts{ldev_id}) if defined $opts{ldev_id};

    my $res = $self->_request('POST', $self->_url('/ldevs'), $body);

    return $self->_wait_for_job($res);
}

sub delete_ldev {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $res = $self->_request('DELETE', $self->_url("/ldevs/$ldev_id"));
    return $self->_wait_for_job($res);
}

sub get_ldev {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    return $self->_request('GET', $self->_url("/ldevs/$ldev_id"));
}

sub list_ldevs {
    my ($self, %filter) = @_;

    my @params;
    push @params, "poolId=$filter{pool_id}"  if defined $filter{pool_id};
    push @params, "count=$filter{count}"     if defined $filter{count};
    push @params, "ldevOption=dpVolume"      if $filter{dp_only};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/ldevs$query"));

    return $data->{data} || [];
}

sub set_ldev_label {
    my ($self, $ldev_id, $label) = @_;

    croak "ldev_id is required" unless defined $ldev_id;
    croak "label is required"   unless defined $label;

    my $body = { label => $label };
    my $res = $self->_request('PATCH', $self->_url("/ldevs/$ldev_id"), $body);
    return $self->_wait_for_job($res);
}

sub expand_ldev {
    my ($self, $ldev_id, $additional_mb) = @_;

    croak "ldev_id is required"       unless defined $ldev_id;
    croak "additional_mb is required" unless defined $additional_mb;

    my $body = {
        parameters => {
            additionalByteFormatCapacity => $additional_mb . "M",
        },
    };

    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/expand/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Pool Operations ──

sub get_pool {
    my ($self, $pool_id) = @_;

    croak "pool_id is required" unless defined $pool_id;

    return $self->_request('GET', $self->_url("/pools/$pool_id"));
}

sub list_pools {
    my ($self) = @_;

    my $data = $self->_request('GET', $self->_url('/pools'));
    return $data->{data} || [];
}

# ── Host Group Operations ──

sub create_host_group {
    my ($self, %opts) = @_;

    croak "port_id is required"         unless $opts{port_id};
    croak "host_group_name is required" unless $opts{host_group_name};

    my $body = {
        portId        => $opts{port_id},
        hostGroupName => $opts{host_group_name},
        hostMode      => $opts{host_mode} || 'LINUX/IRIX',
    };

    my $res = $self->_request('POST', $self->_url('/host-groups'), $body);
    return $self->_wait_for_job($res);
}

sub list_host_groups {
    my ($self, %filter) = @_;

    my @params;
    push @params, "portId=$filter{port_id}" if $filter{port_id};
    my $query = @params ? '?' . join('&', @params) : '';

    my $data = $self->_request('GET', $self->_url("/host-groups$query"));
    return $data->{data} || [];
}

sub get_host_group {
    my ($self, $host_group_id) = @_;

    croak "host_group_id is required" unless defined $host_group_id;

    return $self->_request('GET', $self->_url("/host-groups/$host_group_id"));
}

sub add_wwn_to_host_group {
    my ($self, %opts) = @_;

    croak "host_group_id is required" unless $opts{host_group_id};
    croak "wwn is required"           unless $opts{wwn};

    my $body = {
        hostWwn  => $opts{wwn},
        portId   => $opts{port_id},
    };
    $body->{hostWwnNickname} = $opts{nickname} if $opts{nickname};

    my $res = $self->_request('POST', $self->_url("/host-wwns"), $body);
    return $self->_wait_for_job($res);
}

sub list_host_wwns {
    my ($self, $host_group_id) = @_;

    croak "host_group_id is required" unless defined $host_group_id;

    my $data = $self->_request('GET', $self->_url("/host-groups/$host_group_id/host-wwns"));
    return $data->{data} || [];
}

sub find_host_group_by_wwn {
    my ($self, $port_id, $wwn) = @_;

    my $groups = $self->list_host_groups(port_id => $port_id);
    for my $hg (@$groups) {
        my $hg_id = $hg->{hostGroupId};
        my $wwns = eval { $self->list_host_wwns($hg_id) } || [];
        for my $w (@$wwns) {
            if (lc($w->{hostWwn}) eq lc($wwn)) {
                return $hg;
            }
        }
    }
    return undef;
}

# ── LUN Path Operations ──

sub map_lun {
    my ($self, %opts) = @_;

    croak "port_id is required"       unless $opts{port_id};
    croak "host_group_number is required" unless defined $opts{host_group_number};
    croak "ldev_id is required"       unless defined $opts{ldev_id};

    my $body = {
        portId          => $opts{port_id},
        hostGroupNumber => int($opts{host_group_number}),
        ldevId          => int($opts{ldev_id}),
    };
    $body->{lun} = int($opts{lun}) if defined $opts{lun};

    my $res = $self->_request('POST', $self->_url('/luns'), $body);
    return $self->_wait_for_job($res);
}

sub unmap_lun {
    my ($self, $lun_id) = @_;

    croak "lun_id is required" unless defined $lun_id;

    my $res = $self->_request('DELETE', $self->_url("/luns/$lun_id"));
    return $self->_wait_for_job($res);
}

sub list_luns {
    my ($self, %filter) = @_;

    my @params;
    push @params, "portId=$filter{port_id}"                     if $filter{port_id};
    push @params, "hostGroupNumber=$filter{host_group_number}"  if defined $filter{host_group_number};
    push @params, "ldevId=$filter{ldev_id}"                     if defined $filter{ldev_id};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/luns$query"));
    return $data->{data} || [];
}

# ── Snapshot Operations (Thin Image) ──

sub create_snapshot {
    my ($self, %opts) = @_;

    croak "pvol_ldev_id is required"   unless defined $opts{pvol_ldev_id};
    croak "snap_pool_id is required"   unless defined $opts{snap_pool_id};

    # autoSplit defaults on (snapshots), but a CoW linked clone must keep the pair
    # un-split so the S-VOL shares blocks with the P-VOL via copy-on-write.
    my $auto_split = (exists $opts{auto_split} && !$opts{auto_split}) ? JSON::false : JSON::true;

    my $body = {
        snapshotGroupName  => $opts{snapshot_group} || 'pve_snap',
        snapshotPoolId     => int($opts{snap_pool_id}),
        pvolLdevId         => int($opts{pvol_ldev_id}),
        isConsistencyGroup => $opts{is_consistency_group} ? JSON::true : JSON::false,
        autoSplit          => $auto_split,
    };

    $body->{svolLdevId} = int($opts{svol_ldev_id}) if defined $opts{svol_ldev_id};
    $body->{copySpeed}  = int($opts{copy_speed})   if defined $opts{copy_speed};

    my $res = $self->_request('POST', $self->_url('/snapshots'), $body);
    return $self->_wait_for_job($res);
}

sub delete_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    my $res = $self->_request('DELETE', $self->_url("/snapshots/$snapshot_id"));
    return $self->_wait_for_job($res);
}

sub list_snapshots {
    my ($self, %filter) = @_;

    my @params;
    push @params, "pvolLdevId=$filter{pvol_ldev_id}" if defined $filter{pvol_ldev_id};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/snapshots$query"));
    return $data->{data} || [];
}

sub get_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    return $self->_request('GET', $self->_url("/snapshots/$snapshot_id"));
}

sub split_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    my $body = {
        parameters => {
            operationType => 'split',
        },
    };

    my $res = $self->_request('POST', $self->_url("/snapshots/$snapshot_id/actions/split/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub restore_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    my $body = {
        parameters => {
            operationType => 'restore',
        },
    };

    my $res = $self->_request('POST', $self->_url("/snapshots/$snapshot_id/actions/restore/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub clone_snapshot_to_ldev {
    my ($self, %opts) = @_;

    croak "pvol_ldev_id is required"  unless defined $opts{pvol_ldev_id};
    croak "svol_ldev_id is required"  unless defined $opts{svol_ldev_id};
    croak "snap_pool_id is required"  unless defined $opts{snap_pool_id};

    my $body = {
        snapshotGroupName  => $opts{snapshot_group} || 'pve_clone',
        snapshotPoolId     => int($opts{snap_pool_id}),
        pvolLdevId         => int($opts{pvol_ldev_id}),
        svolLdevId         => int($opts{svol_ldev_id}),
        isClone            => JSON::true,
        isConsistencyGroup => JSON::false,
        autoSplit          => JSON::true,
    };

    $body->{copySpeed} = int($opts{copy_speed}) if defined $opts{copy_speed};

    my $res = $self->_request('POST', $self->_url('/snapshots'), $body);
    return $self->_wait_for_job($res);
}

# ── QoS Operations ──

sub set_ldev_qos {
    my ($self, $ldev_id, %opts) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $body = {};
    $body->{upperIops} = int($opts{upper_iops})                   if defined $opts{upper_iops};
    $body->{upperTransferRate} = int($opts{upper_mbps})           if defined $opts{upper_mbps};
    $body->{lowerIops} = int($opts{lower_iops})                   if defined $opts{lower_iops};
    $body->{lowerTransferRate} = int($opts{lower_mbps})           if defined $opts{lower_mbps};
    $body->{responsePriority} = int($opts{response_priority})     if defined $opts{response_priority};

    croak "At least one QoS parameter is required" unless keys %$body;

    my $res = $self->_request('PATCH', $self->_url("/ldevs/$ldev_id"), $body);
    return $self->_wait_for_job($res);
}

sub get_ldev_qos {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $ldev = $self->get_ldev($ldev_id);
    return {
        upper_iops        => $ldev->{upperIops},
        upper_mbps        => $ldev->{upperTransferRate},
        lower_iops        => $ldev->{lowerIops},
        lower_mbps        => $ldev->{lowerTransferRate},
        response_priority => $ldev->{responsePriority},
    };
}

# ── Replication Operations (TrueCopy / Universal Replicator / GAD) ──

sub create_remote_copy_pair {
    my ($self, %opts) = @_;

    croak "copy_group_name is required" unless $opts{copy_group_name};
    croak "pvol_ldev_id is required"    unless defined $opts{pvol_ldev_id};
    croak "svol_ldev_id is required"    unless defined $opts{svol_ldev_id};
    croak "remote_storage_id is required" unless $opts{remote_storage_id};
    croak "copy_pace is required"       unless $opts{copy_pace};

    my $body = {
        copyGroupName        => $opts{copy_group_name},
        copyPairName         => $opts{copy_pair_name} || "pair_$opts{pvol_ldev_id}_$opts{svol_ldev_id}",
        replicationType      => $opts{replication_type} || 'TC',  # TC, UR, GAD
        pvolLdevId           => int($opts{pvol_ldev_id}),
        svolLdevId           => int($opts{svol_ldev_id}),
        remoteStorageDeviceId => $opts{remote_storage_id},
        copyPace             => int($opts{copy_pace}),
        isConsistencyGroup   => $opts{consistency_group} ? JSON::true : JSON::false,
    };

    # GAD-specific options
    if (($opts{replication_type} || '') eq 'GAD') {
        $body->{quorumDiskId} = int($opts{quorum_disk_id}) if defined $opts{quorum_disk_id};
    }

    # UR-specific options
    if (($opts{replication_type} || '') eq 'UR') {
        $body->{journalId} = int($opts{journal_id}) if defined $opts{journal_id};
    }

    my $res = $self->_request('POST', $self->_url('/remote-mirror-copypairs'), $body);
    return $self->_wait_for_job($res);
}

sub delete_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $res = $self->_request('DELETE', $self->_url("/remote-mirror-copypairs/$pair_id"));
    return $self->_wait_for_job($res);
}

sub get_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    return $self->_request('GET', $self->_url("/remote-mirror-copypairs/$pair_id"));
}

sub list_remote_copy_pairs {
    my ($self, %filter) = @_;

    my @params;
    push @params, "replicationType=$filter{replication_type}" if $filter{replication_type};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/remote-mirror-copypairs$query"));
    return $data->{data} || [];
}

sub split_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $body = {
        parameters => {
            operationType => 'split',
        },
    };

    my $res = $self->_request('POST', $self->_url("/remote-mirror-copypairs/$pair_id/actions/split/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub resync_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $body = {
        parameters => {
            operationType => 'resync',
        },
    };

    my $res = $self->_request('POST', $self->_url("/remote-mirror-copypairs/$pair_id/actions/resync/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Remote Storage Registration ──

sub register_remote_storage {
    my ($self, %opts) = @_;

    croak "remote_storage_id is required" unless $opts{remote_storage_id};
    croak "remote_ip is required"         unless $opts{remote_ip};

    my $body = {
        remoteStorageDeviceId => $opts{remote_storage_id},
        pathGroupId           => int($opts{path_group_id} || 0),
        remoteIpAddress       => $opts{remote_ip},
    };

    my $res = $self->_request('POST', $self->_url('/remote-storages'), $body);
    return $self->_wait_for_job($res);
}

sub list_remote_storages {
    my ($self) = @_;

    my $data = $self->_request('GET', $self->_url('/remote-storages'));
    return $data->{data} || [];
}

# ── Zero Page Reclamation ──

sub reclaim_zero_pages {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $body = { parameters => {} };
    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/discard-zero-page/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Storage-Assisted LDEV Migration ──

sub migrate_ldev {
    my ($self, $ldev_id, $target_pool_id) = @_;

    croak "ldev_id is required"        unless defined $ldev_id;
    croak "target_pool_id is required" unless defined $target_pool_id;

    my $body = {
        parameters => {
            poolId => int($target_pool_id),
        },
    };

    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/change-pool/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Host Group Deletion ──

sub delete_host_group {
    my ($self, $host_group_id) = @_;

    croak "host_group_id is required" unless defined $host_group_id;

    my $res = $self->_request('DELETE', $self->_url("/host-groups/$host_group_id"));
    return $self->_wait_for_job($res);
}

# ── Internal HTTP / Job Helpers ──

sub _url {
    my ($self, $path) = @_;
    return $self->{base_url} . $path;
}

sub _request {
    my ($self, $method, $url, $body, $skip_reauth) = @_;

    my $req = HTTP::Request->new($method, $url);
    $req->header('Content-Type' => 'application/json');
    $req->header('Accept'       => 'application/json');

    if ($self->{token}) {
        $req->header('Authorization' => "Session $self->{token}");
    }

    if ($body) {
        $req->content(encode_json($body));
    }

    my $res;
    my $retries   = 0;
    my $failovers = 0;

    while ($retries <= $MAX_RETRIES) {
        $res = $self->{ua}->request($req);

        if ($res->is_success) {
            my $content = $res->content;
            if ($content && length($content) > 0) {
                return decode_json($content);
            }

            # For async operations, extract job URL from Location or response headers
            my $job_id = $res->header('Job-Id');
            my $location = $res->header('Location');
            if ($job_id) {
                return { jobId => $job_id };
            }
            if ($location) {
                return { location => $location };
            }
            return {};
        }

        my $code = $res->code;

        # Transport-level failure (controller/GUM unreachable) → fail over to the
        # next management endpoint, re-authenticate there, re-target the request at
        # the survivor, and retry. Bounded by the number of endpoints. Skipped for
        # single-endpoint configs and for best-effort calls that opt out of reauth
        # (e.g. logout).
        if ($self->_is_transport_error($res)
            && $self->{username} && !$skip_reauth
            && $failovers < scalar(@{$self->{endpoints}})
            && $self->_switch_endpoint()) {
            $failovers++;
            $self->login();   # croaks only if NO controller is reachable
            $url = $self->_rewrite_host($url);
            $req->uri($url);
            $req->header('Authorization' => "Session $self->{token}") if $self->{token};
            next;
        }

        # 401 Unauthorized - re-authenticate once
        if ($code == 401 && !$skip_reauth && $self->{username}) {
            $self->login();
            $req->header('Authorization' => "Session $self->{token}");
            $retries++;
            next;
        }

        # Decide whether this failure is safe to retry. A 429 means the request was
        # rate-limited *before* being processed, so it is always safe to resend —
        # even a POST. For 5xx and 409 the server may have already applied a
        # non-idempotent POST (create LDEV / map LUN / expand), and resending would
        # double-create or double-apply, so those are only retried for idempotent
        # methods (GET/PUT/DELETE/HEAD).
        my $idempotent = $method =~ /^(?:GET|PUT|DELETE|HEAD)$/i;
        my $retriable  = ($code == 429)
            || ($idempotent && ($code >= 500 || $code == 409));

        if ($retriable && $retries < $MAX_RETRIES) {
            $retries++;
            my $delay = $RETRY_DELAY * $retries;
            if (my $retry_after = $res->header('Retry-After')) {
                $delay = $retry_after if $retry_after =~ /^\d+$/ && $retry_after > $delay;
            }
            sleep($delay);
            next;
        }

        last;
    }

    croak "API request failed: $method $url -> " . $res->status_line . " " . ($res->content || '');
}

sub _wait_for_job {
    my ($self, $res) = @_;

    return $res unless ref $res eq 'HASH';

    my $job_id = $res->{jobId};

    # Some async operations return only a Location header pointing at the job
    # resource instead of a jobId in the body. Derive the job URL from either.
    my $url;
    if ($job_id) {
        $url = "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/jobs/$job_id";
    } elsif ($res->{location}) {
        my $loc = $res->{location};
        # Location may be absolute or relative to the API root.
        $url = $loc =~ m{^https?://}
            ? $loc
            : "https://$self->{mgmt_ip}:$self->{port}$loc";
        ($job_id) = $loc =~ m{/jobs/([^/]+)} ;
        $job_id //= $loc;
    } else {
        return $res;
    }

    my $elapsed = 0;
    while ($elapsed < $JOB_POLL_TIMEOUT) {
        sleep($JOB_POLL_INTERVAL);
        $elapsed += $JOB_POLL_INTERVAL;

        my $job = $self->_request('GET', $url);
        my $state = $job->{state} || '';

        if ($state eq 'Succeeded') {
            my $affected = $job->{affectedResources} || [];
            if (@$affected) {
                # Extract resource ID from the last path segment
                my $resource_url = $affected->[0];
                if ($resource_url =~ m{/(\d+)$}) {
                    return { resourceId => int($1), jobId => $job_id };
                }
                return { resourceUrl => $resource_url, jobId => $job_id };
            }
            return { jobId => $job_id };
        }

        if ($state eq 'Failed' || $state eq 'Unknown') {
            my $error = $job->{error} || {};
            croak "Job $job_id failed: " . ($error->{message} || $state);
        }
    }

    croak "Job $job_id timed out after ${JOB_POLL_TIMEOUT}s";
}

1;
