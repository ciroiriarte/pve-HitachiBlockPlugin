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

    my $port = $opts{port} || 443;
    my $base = "https://$opts{mgmt_ip}:$port/ConfigurationManager/v1/objects/storages/$opts{storage_id}";

    my $ua = LWP::UserAgent->new(
        timeout  => $opts{timeout} || $DEFAULT_TIMEOUT,
        ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 },
    );

    my $self = bless {
        base_url   => $base,
        mgmt_ip    => $opts{mgmt_ip},
        port       => $port,
        storage_id => $opts{storage_id},
        username   => $opts{username},
        password   => $opts{password},
        ua         => $ua,
        token      => undef,
        session_id => undef,
    }, $class;

    return $self;
}

# ── Session Management ──

sub login {
    my ($self) = @_;

    my $url = "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/sessions";
    my $req = HTTP::Request->new('POST', $url);
    $req->header('Content-Type'  => 'application/json');
    $req->header('Accept'        => 'application/json');
    $req->authorization_basic($self->{username}, $self->{password});
    $req->content(encode_json({}));

    my $res = $self->{ua}->request($req);

    if (!$res->is_success) {
        croak "Login failed: " . $res->status_line . " " . $res->content;
    }

    my $data = decode_json($res->content);
    $self->{token}      = $data->{token};
    $self->{session_id} = $data->{sessionId};

    return $self->{token};
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

    my $body = {
        snapshotGroupName  => $opts{snapshot_group} || 'pve_snap',
        snapshotPoolId     => int($opts{snap_pool_id}),
        pvolLdevId         => int($opts{pvol_ldev_id}),
        isConsistencyGroup => JSON::false,
        autoSplit          => JSON::true,
    };

    $body->{svolLdevId} = int($opts{svol_ldev_id}) if defined $opts{svol_ldev_id};

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

    my $res = $self->_request('POST', $self->_url('/snapshots'), $body);
    return $self->_wait_for_job($res);
}

# ── QoS Operations ──

sub set_ldev_qos {
    my ($self, $ldev_id, %opts) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $body = {};
    $body->{upperIops} = int($opts{upper_iops})           if defined $opts{upper_iops};
    $body->{upperTransferRate} = int($opts{upper_mbps})   if defined $opts{upper_mbps};
    $body->{lowerIops} = int($opts{lower_iops})           if defined $opts{lower_iops};
    $body->{lowerTransferRate} = int($opts{lower_mbps})   if defined $opts{lower_mbps};

    croak "At least one QoS parameter is required" unless keys %$body;

    my $res = $self->_request('PATCH', $self->_url("/ldevs/$ldev_id"), $body);
    return $self->_wait_for_job($res);
}

sub get_ldev_qos {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $ldev = $self->get_ldev($ldev_id);
    return {
        upper_iops => $ldev->{upperIops},
        upper_mbps => $ldev->{upperTransferRate},
        lower_iops => $ldev->{lowerIops},
        lower_mbps => $ldev->{lowerTransferRate},
    };
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
    my $retries = 0;

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

        # 401 Unauthorized - re-authenticate once
        if ($code == 401 && !$skip_reauth && $self->{username}) {
            $self->login();
            $req->header('Authorization' => "Session $self->{token}");
            $retries++;
            next;
        }

        # 5xx or 409 (resource locked) - retry with backoff
        if (($code >= 500 || $code == 409) && $retries < $MAX_RETRIES) {
            $retries++;
            sleep($RETRY_DELAY * $retries);
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
    return $res unless $job_id;

    my $url = "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/jobs/$job_id";

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
