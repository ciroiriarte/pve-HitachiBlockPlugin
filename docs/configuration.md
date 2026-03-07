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

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `mgmt_ip` | Yes | Management IP/hostname of Configuration Manager API |
| `storage_id` | Yes | Storage system serial number |
| `pool_id` | Yes | DP pool ID for LDEV allocation |
| `snap_pool_id` | No | Pool for snapshot S-VOLs (defaults to pool_id) |
| `target_ports` | Yes | Comma-separated FC port IDs (e.g. CL1-A,CL2-A) |
| `host_mode` | No | Host mode for host groups (default: LINUX/IRIX) |
| `platform` | No | `vsp_g` or `vsp_one` (default: vsp_one) |
| `mgmt_port` | No | API port (auto-detected: 443 for vsp_one, 23451 for vsp_g) |

## Credentials

Stored securely in `/etc/pve/priv/hitachiblock/<storeid>.creds`:

```bash
pvesm set <storeid> --username <api_user> --password <api_password>
```

## Platform Differences

| Aspect | VSP G series | VSP One Block |
|--------|-------------|---------------|
| API Provider | Ops Center API Config Manager | Built-in REST API |
| Default Port | 23451 | 443 |
| API Endpoints | Identical | Identical |
