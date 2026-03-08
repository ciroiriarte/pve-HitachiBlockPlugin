# Architecture

## Component Overview

```
+------------------------------------------------------------------+
|                    Proxmox VE (PVE) Framework                     |
|  storage.cfg  |  PVE::Storage::Plugin base  |  QEMU / LXC        |
+------------------------------------------------------------------+
        |                       |                        |
        v                       v                        v
+------------------------------------------------------------------+
|     PVE::Storage::Custom::HitachiBlockPlugin  (Plugin Entry Point)|
|  Implements PVE::Storage::Plugin interface                        |
|  Orchestrates all storage lifecycle operations                    |
+------------------------------------------------------------------+
        |                   |                       |
        v                   v                       v
+------------------+ +------------------+ +--------------------+
| HitachiBlock::   | | HitachiBlock::   | | HitachiBlock::     |
| RestClient       | | Multipath        | | Config             |
|                  | |                  | |                    |
| Session mgmt    | | SCSI rescan      | | Credential store   |
| LDEV CRUD       | | Device path      | | LDEV-volname map   |
| Pool queries    |   resolution     | | Snapshot registry  |
| Host group ops  | | WWN discovery    | | Platform defaults  |
| LUN mapping     | | Multipath mgmt   | | Param validation   |
| Snapshot ops    | | Buffer flush     | |                    |
| QoS ops         | |                  | |                    |
| Replication ops | |                  | |                    |
+------------------+ +------------------+ +--------------------+
        |
        v
+------------------------------------------------------------------+
|          Hitachi Configuration Manager REST API                   |
|  /ConfigurationManager/v1/objects/storages/{id}/...              |
+------------------------------------------------------------------+
        |
        v
+------------------------------------------------------------------+
|      Hitachi VSP G series   /   VSP One Block   (FC SAN)         |
+------------------------------------------------------------------+
```

Additionally, a standalone CLI tool exists for replication management:

```
+------------------------------------------------------------------+
|  bin/hitachiblock-repl  (Replication CLI Tool)                   |
|  TrueCopy / Universal Replicator / GAD pair management           |
|  Uses RestClient + Config directly                               |
+------------------------------------------------------------------+
```

## Module Responsibilities

### HitachiBlockPlugin

- Extends `PVE::Storage::Plugin`
- Translates PVE lifecycle calls into orchestrated operations across RestClient, Multipath, and Config
- Active-node-only LUN mapping for scalability
- Session management with auto-reconnect on keepalive failure
- Partial failure recovery (cleans up LDEV on label-set failure during allocation)
- QoS enforcement on newly allocated volumes
- Snapshot metadata tracking (S-VOL LDEV ID, WWID, array snapshot ID)
- Snapshot-aware volume activation, deactivation, and path resolution
- Clone-from-snapshot support
- Volume resize with array-side size verification and buffer flush
- Orphan detection and registry cleanup

### RestClient

- Pure HTTP client for Hitachi Configuration Manager API (`LWP::UserAgent` + `JSON`)
- Session lifecycle: login, logout, keepalive with token-based auth
- LDEV operations: create, delete, get, list, expand, set label
- Pool operations: get, list
- Host group operations: create, list, get, add WWN, find by WWN
- LUN path operations: map, unmap, list
- Snapshot operations: create, delete, restore, split, get, list, clone to LDEV
- QoS operations: set per-LDEV IOPS/throughput limits, get current limits
- Replication operations: create/delete/get/list/split/resync remote copy pairs
- Remote storage operations: register, list
- Async job polling with configurable timeout
- Retry on 5xx/409 (resource lock), re-auth on 401

### Multipath

- Linux-side SCSI rescan (full and targeted by HCTL)
- Multipath device lifecycle: wait for appearance, remove, resize
- Buffer flush before resize on running VMs
- FC WWN discovery from `/sys/class/fc_host/host*/port_name`
- WWID computation from storage serial + LDEV ID (NAA format: `60060e80<serial_hex><ldev_hex><padding>`)

### Config

- Credentials in `/etc/pve/priv/hitachiblock/<storeid>.creds`
- LDEV registry in `/etc/pve/priv/hitachiblock/<storeid>.json` (cluster-replicated via pmxcfs)
- Snapshot metadata nested within LDEV registry entries
- Platform-specific defaults (VSP G: port 23451, VSP One: port 443)
- Label format: `pve:<storeid>:<volname>`
- Configuration validation

## Volume Naming

- PVE volname: `vm-<VMID>-disk-<SEQ>`
- LDEV label on array: `pve:<storeid>:vm-<VMID>-disk-<SEQ>`
- The LDEV registry maps volname to LDEV ID and WWID for fast lookup

## LUN Scaling Strategy

**Problem**: 1 LUN per virtual disk can create thousands of LUNs. SCSI hosts have practical limits (~2,048 LUNs per host group).

**Solution**: Active-node-only LUN mapping.

- Each LUN is mapped **only to the host group of the node currently running the VM**
- On VM migration: map LUN to target node first, then unmap from source after migration completes
- Per-host LUN count = number of VMs on that node (not total cluster VMs)
- Example: 3,000 VMs across 10 nodes = ~300 LUNs per host, well within limits

## State Management

All persistent state is stored under `/etc/pve/priv/hitachiblock/` which is automatically cluster-replicated via pmxcfs:

| File | Purpose |
|------|---------|
| `<storeid>.creds` | API username and password |
| `<storeid>.json` | LDEV registry (volname-to-LDEV mapping, snapshot metadata, parent tracking) |

## Data Flows

### Allocate Disk (`alloc_image`)

1. Generate volname `vm-<VMID>-disk-<N>`
2. Create LDEV (async) on DP pool with requested size
3. Set LDEV label `pve:<storeid>:<volname>`
4. If label-set fails, delete the LDEV (partial failure recovery)
5. Register volname/LDEV/WWID in registry
6. Apply QoS limits if `qos_upper_iops` or `qos_upper_mbps` configured
7. Get local FC WWNs, find/create host group on target ports
8. Map LUN to local node's host group
9. SCSI rescan + wait for `/dev/mapper/<wwid>`

### Free Disk (`free_image`)

1. Look up LDEV ID from registry
2. Delete any snapshot pairs associated with the volume
3. Unmap all LUN paths from all host groups
4. Remove multipath device + SCSI paths from host
5. Delete LDEV (async)
6. Unregister from LDEV map

### VM Migration

1. `activate_volume()` on target node: check LUN mapping, create if missing, SCSI rescan, wait for device
2. VM runs on target node
3. `deactivate_volume()` on source node: flush buffers, remove multipath device, unmap LUN

### Snapshot

1. Look up P-VOL LDEV ID from registry
2. Create Thin Image pair (auto-split) via API
3. Retrieve S-VOL metadata (LDEV ID, WWID, array snapshot ID)
4. Store snapshot metadata in registry

### Clone (Linked)

1. Look up source LDEV (or S-VOL if cloning from snapshot)
2. Create Thin Image pair; S-VOL shares blocks via CoW
3. Set label on S-VOL LDEV
4. Register new volume with parent tracking
5. Map LUN, rescan, wait for device

### Clone (Full)

1. Create Thin Image snapshot of source
2. Create new independent LDEV
3. Array-side copy from snapshot to new LDEV
4. Delete temporary snapshot
5. Register, map, rescan

### Volume Resize

1. Verify current size from array (`byteFormatCapacity` parsing: M/G/T formats)
2. If VM is running, flush device buffers
3. Expand LDEV on array (async)
4. Rescan SCSI paths + multipathd resize on host
5. Update registry with new size
