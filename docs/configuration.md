# Configuration

## Storage Configuration

Add to `/etc/pve/storage.cfg`:

```
hitachiblock: <storeid>
    mgmt_ip <ip_or_hostname>
    storage_id <serial_number>
    pool_id <dp_pool_id>
    snap_pool_id <snapshot_pool_id>
    target_ports <port1>,<port2>
    host_mode LINUX/IRIX
    platform <vsp_g|vsp_one>
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
| `mgmt_ip` | Management IP or hostname of the Configuration Manager REST API endpoint |
| `storage_id` | Storage system serial number (e.g., `836000123456`) |
| `pool_id` | DP pool ID for LDEV allocation (numeric) |
| `target_ports` | Comma-separated FC port IDs for LUN mapping (e.g., `CL1-A,CL2-A`) |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `snap_pool_id` | Same as `pool_id` | Separate DP pool for snapshot S-VOLs |
| `host_mode` | `LINUX/IRIX` | Host mode for auto-created host groups |
| `platform` | `vsp_one` | Platform type: `vsp_g` or `vsp_one`. Controls default API port. |
| `mgmt_port` | Auto-detected | API port override. Auto: 443 for `vsp_one`, 23451 for `vsp_g`. |
| `qos_upper_iops` | None | Maximum IOPS limit applied to every new LDEV |
| `qos_upper_mbps` | None | Maximum throughput (MB/s) limit applied to every new LDEV |
| `qos_lower_iops` | None | Minimum guaranteed IOPS per LDEV (lower bound, min 0) |
| `qos_lower_mbps` | None | Minimum guaranteed throughput (MB/s) per LDEV (lower bound, min 0) |
| `qos_priority` | None | QoS priority level: `1` = high, `2` = medium, `3` = low |
| `ldev_range` | None | Restrict LDEV allocation to a numeric range (e.g., `1000-1999` or `0x3E8-0x7CF`) |
| `discard_zero_page` | `0` | When enabled (`1`), reclaims zero pages on `deactivate_volume` |
| `port_scheduler` | `0` | When enabled (`1`), uses round-robin port selection for LUN mapping |
| `copy_speed` | None | Array-side copy speed for clone/migration operations (integer, 1-15) |
| `group_delete` | `0` | When enabled (`1`), automatically deletes empty host groups on deactivate |

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

The credential file format is:

```
username=<api_user>
password=<api_password>
```

## Platform Differences

| Aspect | VSP G series | VSP One Block |
|--------|-------------|---------------|
| API Provider | Ops Center API Configuration Manager (external appliance or SVP) | Built-in REST API (native to controller) |
| Default Port | 23451 | 443 |
| API Endpoints | Identical | Identical |
| LDEV/Pool/Snapshot/QoS/Replication ops | Identical | Identical |

The plugin uses a single code path for both platforms. The only difference is the management endpoint (IP + port).

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
