# Configuration

## Storage Configuration

Add to `/etc/pve/storage.cfg`:

```
hitachiblock: <storeid>
    mgmt_ip <ip_or_hostname>
    storage_id <storage_device_id>
    pool_id <dp_pool_id>
    snap_pool_id <snapshot_pool_id>
    target_ports <port1>,<port2>
    host_mode LINUX/IRIX
    platform <vsp_g|vsp_e|vsp_one>
    shared 1
    content images
    nodes <node1>,<node2>
```

### Example

```
hitachiblock: myarray
    mgmt_ip 10.0.1.100
    storage_id 836000123456
    pool_id 0
    snap_pool_id 1
    target_ports CL1-A,CL2-A,CL3-A,CL4-A
    host_mode LINUX
    platform vsp_one
    shared 1
    content images
    nodes pve1,pve2,pve3
    qos_upper_iops 5000
    qos_upper_mbps 200
    qos_lower_iops 500
    qos_lower_mbps 50
    qos_priority 2
    ldev_range 1000-1999
    discard_zero_page 1
    port_scheduler 1
    copy_speed 5
    group_delete 1
```

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `mgmt_ip` | Management IP/hostname of the Configuration Manager REST API endpoint — the array's embedded/GUM controller (direct connection) or a dedicated Ops Center Configuration Manager server. May be a **comma-separated list** of per-controller endpoints for management-plane failover (see [Management Endpoint Redundancy](#management-endpoint-redundancy)) |
| `storage_id` | Storage device ID (`storageDeviceId`), e.g. the 12-digit model+serial id returned by `GET /v1/objects/storages` (e.g., `836000123456`) — not the bare serial number |
| `pool_id` | DP pool ID for LDEV allocation (numeric) |
| `target_ports` | Comma-separated FC port IDs for LUN mapping (e.g., `CL1-A,CL2-A`) |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `snap_pool_id` | Same as `pool_id` | Separate DP pool for snapshot S-VOLs |
| `host_mode` | `LINUX/IRIX` | Host mode for auto-created host groups |
| `platform` | `vsp_one` | Platform type: `vsp_g`, `vsp_e`, or `vsp_one`. Controls default API port. Use `vsp_e` for VSP E series (e.g. E590H) talking to the embedded/direct REST API. |
| `mgmt_port` | Auto-detected | API port override. Auto: 443 for `vsp_one`/`vsp_e` (direct/embedded REST), 23451 for `vsp_g` (Ops Center CM server). |
| `qos_upper_iops` | None | Maximum IOPS limit applied to every new LDEV |
| `qos_upper_mbps` | None | Maximum throughput (MB/s) limit applied to every new LDEV |
| `qos_lower_iops` | None | Minimum guaranteed IOPS per LDEV (lower bound, min 0) |
| `qos_lower_mbps` | None | Minimum guaranteed throughput (MB/s) per LDEV (lower bound, min 0) |
| `qos_priority` | None | QoS priority level: `1` = high, `2` = medium, `3` = low |
| `ldev_range` | None | Restrict LDEV allocation to a numeric range (e.g., `1000-1999` or `0x3E8-0x7CF`) |
| `discard_zero_page` | `0` | When enabled (`1`), reclaims zero pages on `deactivate_volume` |
| `port_scheduler` | `0` | When enabled (`1`) and more than two `target_ports` are configured, each volume is mapped to a stable pair of ports chosen deterministically from its LDEV ID, spreading volumes across FC ports while preserving multipath redundancy |
| `copy_speed` | None | Array-side copy speed for clone/migration operations (integer, 1-15) |
| `group_delete` | `0` | When enabled (`1`), automatically deletes empty host groups on deactivate |
| `tls_verify` | `0` | When enabled (`1`), verifies the Configuration Manager TLS certificate. Off by default for the appliance's self-signed cert. |
| `tls_ca_file` | None | Path to a CA bundle used to verify the API certificate when `tls_verify` is enabled |

### Standard PVE Parameters

| Parameter | Typical Value | Description |
|-----------|---------------|-------------|
| `shared` | `1` | Must be `1` for clustered operation |
| `content` | `images` | Content types (always `images` for block storage) |
| `nodes` | All nodes | Restrict to specific cluster nodes |

## Credentials

API credentials are stored securely in `/etc/pve/priv/hitachiblock/<storeid>.creds` (cluster-replicated, only readable by root).

Set credentials via the PVE storage manager (they are configured during `on_add_hook` or can be updated):

```bash
pvesm set <storeid> --username <api_user> --password <api_password>
```

The credential file is JSON, mode `0600`, readable only by root:

```json
{"username":"<api_user>","password":"<api_password>"}
```

### Storage ID length and LDEV labels

The plugin tags each LDEV with a label of the form `pve:<storeid>:<volname>`.
Hitachi LDEV labels are limited to 32 characters on most VSP models. When a
`<storeid>` is long enough that this would overflow, the plugin automatically
substitutes a stable 8-character hash of the storeid (`pve:<hash>:<volname>`) so
labels stay within the limit and remain consistently matchable by orphan
detection. Volume identity is always authoritative in the registry, not the
label, so this substitution is transparent.

## Platform Differences

| Aspect | VSP G series (`vsp_g`) | VSP E series (`vsp_e`) | VSP One Block (`vsp_one`) |
|--------|------------------------|------------------------|---------------------------|
| API Provider | Ops Center API Configuration Manager (external appliance or SVP) | Embedded Configuration Manager REST API on the controller (GUM), direct connection | Built-in REST API (native to controller) |
| Default Port | 23451 | 443 | 443 |
| API Endpoints | Identical (`/ConfigurationManager/v1/objects/storages/<storageDeviceId>/…`) | Identical | Identical |
| LDEV/Pool/Snapshot/QoS/Replication ops | Identical | Identical | Identical |

The plugin uses a single code path for all platforms. The only difference is the
management endpoint (IP + port). All three speak the standard Ops Center
Configuration Manager REST API object model.

> **VSP E series (e.g. E590H) note:** the E series exposes this same Configuration
> Manager REST API both via a dedicated Ops Center CM server (port 23451 — use
> `platform vsp_g` or set `mgmt_port`) and directly/embedded on the controller GUM
> (port 443 — `platform vsp_e`). It *also* offers a separate, simplified "Storage
> Advisor Embedded" REST API (`/ConfigurationManager/simple/v1/…`, volumes/servers
> model) which this plugin does **not** use. Confirm that QoS, Thin Image, and
> remote replication are enabled on the array's microcode before relying on them.

## QoS Configuration

QoS limits are applied automatically to every new LDEV created by the plugin. Set at the storage level:

**Upper bounds (caps)**:
- `qos_upper_iops` - Maximum IOPS limit per LDEV
- `qos_upper_mbps` - Maximum throughput (MB/s) limit per LDEV

**Lower bounds (guarantees)**:
- `qos_lower_iops` - Minimum guaranteed IOPS per LDEV
- `qos_lower_mbps` - Minimum guaranteed throughput (MB/s) per LDEV

**Priority**:
- `qos_priority` - Scheduling priority when the array is under contention: `1` = high, `2` = medium, `3` = low

Upper bounds, lower bounds, and priority can all be combined. QoS is applied during `alloc_image` after LDEV creation. Existing LDEVs are not retroactively modified.

To change QoS for existing volumes, use the Hitachi Configuration Manager UI or API directly.

## Host Group Management

The plugin **automatically manages host groups** on the configured target ports:

1. On `activate_storage()`, the plugin discovers the local node's FC WWNs
2. For each target port, it searches for an existing host group containing the node's WWN
3. If none found, it creates a new host group named `PVE-<hostname>` and registers the WWNs
4. LUNs are mapped to the host group of the node running the VM

By default, host groups are not deleted when the storage is deactivated; they persist for reuse. If the `group_delete` option is enabled, the plugin automatically deletes host groups that become empty (no remaining LUN mappings) during `deactivate_volume`.

## Session Management

The plugin maintains a REST API session with the Configuration Manager:

- A session is created on `activate_storage()` (login with username/password, receive session token)
- The session is kept alive via periodic keepalive calls
- If a keepalive fails (session expired), the plugin automatically re-authenticates
- The session is released on `deactivate_storage()` (logout)

## Management Endpoint Redundancy

VSP arrays have two controllers for redundancy. This affects two independent
planes:

- **Data plane (I/O):** already redundant. List target ports from *both*
  controllers in `target_ports` (e.g. `CL1-A` on CTL1 and `CL2-A` on CTL2); the
  host's multipath stack fails over between paths automatically. No special
  configuration beyond listing the ports.
- **Management plane (REST API):** depends on how your array exposes management.
  - **Single floating management VIP** (the array fails the IP over between
    controllers internally): set `mgmt_ip` to that one VIP — failover is handled by
    the array, nothing else to do.
  - **Per-controller management IPs** (typical for VSP E series embedded GUM, where
    each controller serves its own REST endpoint): set `mgmt_ip` to a
    **comma-separated list**, e.g. `mgmt_ip 10.0.1.100,10.0.1.101`.

When `mgmt_ip` lists multiple endpoints, the plugin keeps a *current* endpoint and,
on a transport-level failure (controller/GUM unreachable, connection timeout), fails
over to the next one and **re-authenticates** there (REST sessions are
per-controller). It stays on the working endpoint ("sticky") until that one fails.
A single management call that is in-flight when a controller dies will fail and is
retried by the normal operation path against the survivor.

> **Note:** an async array job (LDEV create, snapshot, etc.) lives on the controller
> that started it. If that controller dies mid-operation the job is lost; the plugin
> surfaces the failure (and rolls back any partial array-side resources) rather than
> silently polling a controller that never had the job. Re-running the operation
> proceeds on the surviving controller.

## File Locations

| File | Purpose |
|------|---------|
| `/usr/share/perl5/PVE/Storage/Custom/HitachiBlockPlugin.pm` | Plugin entry point |
| `/usr/share/perl5/PVE/Storage/HitachiBlock/RestClient.pm` | REST API client |
| `/usr/share/perl5/PVE/Storage/HitachiBlock/Multipath.pm` | Multipath management |
| `/usr/share/perl5/PVE/Storage/HitachiBlock/Config.pm` | Configuration/state management |
| `/usr/bin/hitachiblock-repl` | Replication CLI tool |
| `/etc/pve/priv/hitachiblock/<storeid>.creds` | API credentials |
| `/etc/pve/priv/hitachiblock/<storeid>.json` | LDEV registry and snapshot metadata |
| `/etc/pve/storage.cfg` | PVE storage configuration |
