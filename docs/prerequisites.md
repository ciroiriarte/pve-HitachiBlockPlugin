# Storage Appliance Prerequisites

This document describes everything that must be configured on the Hitachi storage array and infrastructure side before the PVE Hitachi Block Storage Plugin can operate.

## 1. Storage System Requirements

### Supported Platforms

- **Hitachi VSP G series** (G200, G350, G370, G700, G900, etc.)
- **Hitachi VSP One Block** (all models)
- Any Hitachi storage system exposing the Configuration Manager REST API (`/ConfigurationManager/v1/`)

### Firmware

Ensure the storage system firmware is at a version that supports the Configuration Manager REST API. Consult Hitachi documentation for minimum firmware levels.

---

## 2. Configuration Manager REST API

### VSP G Series

The REST API is provided by **Ops Center API Configuration Manager**, which runs as an external appliance or on the SVP (Storage Virtualization Platform).

- Install and configure Ops Center API Configuration Manager
- Default API port: **23451**
- The appliance must have network connectivity to the storage system
- The API endpoint must be reachable from all PVE cluster nodes on the configured port

### VSP One Block

The REST API is **built into the storage controller** (no external appliance needed).

- Enable the REST API via the controller management interface
- Default API port: **443**
- The controller management IP must be reachable from all PVE cluster nodes

### API User Account

Create a dedicated API user account on the Configuration Manager with the following permissions:

- **Storage Administrator (Provisioning)** - Required for LDEV, host group, LUN path, and pool operations
- **Storage Administrator (Local Copy)** - Required for Thin Image (snapshot) operations
- **Storage Administrator (Remote Copy)** - Required for TrueCopy, Universal Replicator, and GAD replication operations (only if using the replication CLI tool)

The username and password are stored securely on the PVE cluster at `/etc/pve/priv/hitachiblock/<storeid>.creds`.

---

## 3. Storage Pools (DP Pools)

### Primary Data Pool

At least one **Dynamic Provisioning (DP) pool** must exist on the array for LDEV allocation.

- Note the **pool ID** (numeric) - this is configured as `pool_id` in the plugin
- The pool should have sufficient free capacity for the expected VM workloads
- LDEVs created by the plugin are thin-provisioned from this pool

### Snapshot Pool (Optional)

A separate DP pool can be used for snapshot S-VOL (secondary volume) allocation.

- Configured as `snap_pool_id` in the plugin
- If not specified, the primary `pool_id` is used for snapshots as well
- Separating snapshot and data pools prevents snapshot space from impacting primary VM storage

### Pool Sizing Considerations

- **Thin provisioning**: LDEVs are thin by default in DP pools; allocate pool capacity based on expected actual usage, not provisioned size
- **Snapshots**: Each snapshot creates an S-VOL that consumes space as data diverges from the P-VOL (copy-on-write)
- **Clones**: Linked clones share blocks with the source (space-efficient); full clones consume the full LDEV size
- Monitor pool utilization via the PVE UI (the plugin reports pool capacity) or the array management interface

---

## 4. Fibre Channel Configuration

### FC Ports

Identify the storage FC ports that will serve LUN paths to the PVE cluster nodes.

- Note the **port IDs** (e.g., `CL1-A`, `CL2-A`, `CL3-A`, `CL4-A`) - configured as `target_ports` in the plugin
- Use at least 2 ports across different controllers/CHAs for multipath redundancy
- Ports must be configured in **Target** mode (not Initiator)

### SAN Zoning

Configure SAN zoning between:
- Each PVE node's FC HBA port(s) (initiator WWNs)
- The designated storage target ports

**Recommendation**: Use single-initiator zoning (one initiator per zone, one or more targets per zone) for security and isolation.

### Host Groups

The plugin **automatically creates and manages host groups** on the configured target ports. However:

- The target ports must allow host group creation via the API
- **Host mode**: The plugin creates host groups with the configured `host_mode` (default: `LINUX/IRIX`). For PVE/Linux hosts, `LINUX/IRIX` is the correct setting.
- **Host mode options**: No special host mode options are required for basic operation
- The plugin discovers the local node's FC WWNs from sysfs and registers them in the appropriate host groups

**Note**: If host groups are pre-created manually on the array, the plugin will find them by matching the local node's WWNs and reuse them. It does not require exclusive ownership of host groups.

---

## 5. Licensing

The following Hitachi software licenses must be active on the storage system, depending on the features used:

| Feature | Required License | Plugin Functionality |
|---------|-----------------|---------------------|
| Dynamic Provisioning | Thin Provisioning | Core LDEV allocation (required) |
| Thin Image (Snapshot) | Thin Image | Snapshots, linked clones |
| ShadowImage | ShadowImage | Full clones (array-side copy) |
| TrueCopy | TrueCopy | Synchronous replication (replication CLI) |
| Universal Replicator | Universal Replicator | Asynchronous replication (replication CLI) |
| Global-Active Device | Global-Active Device | Active-active replication (replication CLI) |

**Minimum for basic operation**: Dynamic Provisioning + Thin Image.

---

## 6. Replication Prerequisites (Optional)

Only required if using the `hitachiblock-repl` CLI tool for remote replication.

### TrueCopy (Synchronous Replication)

- TrueCopy license active on both local and remote arrays
- FC or IP connectivity between the arrays (Remote Copy paths)
- Remote storage registered via `hitachiblock-repl remote-add`

### Universal Replicator (Asynchronous Replication)

- Universal Replicator license active on both arrays
- **Journal volumes** created on both local and remote arrays
  - Journal volumes are used as write buffers for async replication
  - Note the journal IDs for pair creation
- Remote storage registered via `hitachiblock-repl remote-add`

### Global-Active Device (GAD)

- GAD license active on both arrays
- **Quorum disk** configured on a third storage system or external quorum server
  - Note the quorum disk ID for pair creation
- FC connectivity between arrays
- Remote storage registered via `hitachiblock-repl remote-add`

### Remote Storage Registration

Before creating replication pairs, the remote array must be registered:

```bash
export HITACHI_MGMT_IP=10.0.1.100
export HITACHI_STORAGE_ID=836000123456
hitachiblock-repl remote-add \
    --remote-serial 836000654321 \
    --remote-ip 10.0.2.100 \
    --remote-port 443 \
    --remote-model M8 \
    --path-group 0
```

---

## 7. Network Requirements

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| PVE nodes | Configuration Manager API | 443 or 23451 | HTTPS | REST API calls |
| PVE nodes | Storage FC ports | N/A | FC | Data I/O (LUN access) |

- All PVE cluster nodes must have network access to the Configuration Manager API endpoint
- HTTPS (TLS) is used for all API communication; the plugin accepts self-signed certificates
- No inbound connectivity from the array to PVE nodes is required

---

## 8. Array-Side Features (Transparent to Plugin)

The following features are configured at the array or pool level and operate transparently without plugin involvement:

| Feature | Configuration Level | Notes |
|---------|-------------------|-------|
| Deduplication | Pool | Adaptive Data Reduction - enabled per DP pool |
| Compression | Pool | Adaptive Data Reduction - enabled per DP pool |
| Auto-tiering | Pool | Dynamic Tiering - transparent data movement between SSD/HDD tiers |
| Encryption | Controller | Controller-level encryption at rest |

These features are managed entirely through the array management interface and do not require any plugin configuration.

---

## 9. Pre-Flight Checklist

Before configuring the plugin, verify the following:

- [ ] Storage system firmware supports Configuration Manager REST API
- [ ] Configuration Manager REST API is installed/enabled and accessible from PVE nodes
- [ ] API user account created with Storage Administrator (Provisioning) and Storage Administrator (Local Copy) roles
- [ ] At least one DP pool exists with sufficient capacity
- [ ] FC target ports identified and configured in Target mode
- [ ] SAN zoning configured between PVE node HBAs and storage target ports
- [ ] FC link is up: `cat /sys/class/fc_host/host*/port_state` shows `Online` on PVE nodes
- [ ] Dynamic Provisioning and Thin Image licenses are active
- [ ] (Optional) Snapshot pool created if using separate pool for snapshots
- [ ] (Optional) Replication licenses, journal volumes, quorum disks configured if using replication
- [ ] (Optional) Remote storage systems registered if using replication

---

## 10. Validation

After array-side setup, validate connectivity from a PVE node:

```bash
# Verify API endpoint is reachable
curl -k https://<mgmt_ip>:<port>/ConfigurationManager/v1/objects/storages/<storage_id>/pools

# Verify FC connectivity
cat /sys/class/fc_host/host*/port_state
# Expected: Online

# Verify FC targets visible
cat /sys/class/fc_host/host*/fabric_name
# Should show non-zero fabric WWN

# Check multipath status
multipath -ll
# Should list any existing multipath devices
```
