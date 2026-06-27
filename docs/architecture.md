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
- Manage/unmanage volumes (import existing LDEVs, release without deletion)

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

PVE volnames recognised by `parse_volname` (all map to vtype `images`, format `raw`):

- `vm-<VMID>-disk-<SEQ>` — a VM/CT virtual disk
- `base-<VMID>-disk-<SEQ>` — a template/base image (linked-clone parent)
- `vm-<VMID>-cloudinit` — a VM's cloud-init drive (a tiny raw LUN holding the
  ISO9660 config image; size floored to the array minimum DP-VOL)

Other details:

- LDEV label on array: `pve:<storeid>:<volname>`
- The LDEV registry maps volname to LDEV ID and WWID for fast lookup

## LUN Scaling Strategy

**Problem**: 1 LUN per virtual disk can create thousands of LUNs. SCSI hosts have practical limits (~2,048 LUNs per host group).

**Solution**: Active-node-only LUN mapping.

- Each LUN is mapped **only to the host group of the node currently running the VM**
- On VM migration: map LUN to target node first, then unmap from source after migration completes
- Per-host LUN count = number of VMs on that node (not total cluster VMs)
- Example: 3,000 VMs across 10 nodes = ~300 LUNs per host, well within limits
- **Multi-attach**: When a volume must be accessible from multiple nodes simultaneously (e.g., during live migration overlap or shared-disk clusters), `activate_volume` and `deactivate_volume` track concurrent mappings and only unmap the LUN when the last node deactivates it

## Control-Plane Session Scaling

Each node holds **one persistent CM REST session per `hitachiblock` storage**, so session
usage scales with cluster size and is bounded by the array's shared CM session cap. This is
a scaling ceiling for large clusters (see `docs/operations.md` §"REST session limits"). The
candidate topologies for decoupling session count from node count — ephemeral sessions with
a cluster-wide lease budget, an active-active broker, and the rejected alternatives — are
analysed in [ADR 0001 — Control-plane REST session scaling](adr/0001-control-plane-session-scaling.md).

## State Management

All persistent state is stored under `/etc/pve/priv/hitachiblock/` which is automatically cluster-replicated via pmxcfs:

| File | Purpose |
|------|---------|
| `<storeid>.creds` | API username and password |
| `<storeid>.json` | LDEV registry (volname-to-LDEV mapping, snapshot metadata, parent tracking) |

## Data Flows

### Allocate Disk (`alloc_image`)

The registry entry is committed **last**, once the volume is fully provisioned and
discoverable; any failure before that rolls back the array-side resources and the
name reservation, so a failed allocation never leaves a "ghost" volume.

1. Reserve a unique volname `vm-<VMID>-disk-<N>` under the cluster lock
2. If `ldev_range` is configured, select an available LDEV ID within the range; otherwise let the array auto-assign
3. Create the LDEV (async) on the DP pool with the requested size
4. Set the LDEV label `pve:<storeid>:<volname>`
5. Apply QoS limits if configured (**best-effort** — a QoS failure does not fail the disk)
6. Find/create the host group for the local FC WWNs; if `port_scheduler` is enabled, select the target port pair deterministically from the LDEV ID
7. Map the LUN to the local node's host group (**prerequisite** — fatal on failure)
8. SCSI rescan; resolve the WWID (array `naaId`, else synthesized, else sysfs) and wait for `/dev/mapper/<wwid>`
9. **Commit** the volname/LDEV/WWID to the registry
10. On any failure in steps 2–9: unmap the LUN, delete the LDEV, and release the name reservation

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

### Clone (Linked) — `clone_image`

Linked clones are the only clone path that runs through the plugin. The source must
be a base image or a snapshot. The result is a persistent host-R/W copy-on-write
S-VOL (`PSUS`, `isClone` unset) that keeps sharing unchanged blocks with the source.

The order matters: VSP One Block / Thin Image Advanced **rejects an S-VOL supplied at
pair-creation time** and requires the S-VOL to be **mapped (have LU paths) before it
is assigned** to the snapshot data. So `clone_image` does:

1. Look up the source LDEV (or the snapshot's S-VOL if cloning from a snapshot)
2. Create the S-VOL as a **Thin Image virtual volume** (`poolId -1`) with an explicit
   in-range LDEV id (so the teardown fence accepts it) sized to the source's exact
   block count
3. Create a **data-only** split Thin Image pair on the source (`autoSplit=true`, **no**
   `svolLdevId`) → snapshot data stored, pair in `PSUS`
4. Label and **map** the S-VOL locally (gives it LU paths)
5. **Assign** the S-VOL to the snapshot data (`actions/assign-volume`) → the S-VOL
   becomes the host-R/W CoW view
6. Resolve WWID, wait for device, and register with parent tracking
   (`parent_volname`, `parent_snap`) **plus the backing pair's object id + P-VOL** so
   `free_image` can release the pair before deleting the S-VOL (the clone is the
   pair's S-VOL, not its P-VOL)

> Earlier microcode/array families may accept the simpler "create pair with
> `svolLdevId`" form, but the data-only-pair + assign-volume sequence is what the
> E590H (microcode 93-07-23) requires and was validated live.

### Clone (Full) — handled by Proxmox core, not the plugin

A full/independent copy does **not** go through `clone_image`. Proxmox allocates a new
volume (`alloc_image`) on the target and copies the data itself over the device path
(`qemu-img convert` offline, or drive-mirror online) — the same machinery as "Move
Storage". The result has no dependency on the source. **Array-side offload of a full
clone is not possible** — PVE exposes no plugin hook for it; see
[ADR 0002 — Full-clone offload](adr/0002-full-clone-offload.md) and
[Operations § Clones](operations.md#clones).

### Volume Resize

1. Verify current size from array (`byteFormatCapacity` parsing: M/G/T formats)
2. If VM is running, flush device buffers
3. Expand LDEV on array (async)
4. Rescan SCSI paths + multipathd resize on host
5. Update registry with new size

## Future direction: a multi-vendor framework

This plugin is single-vendor (Hitachi) by design today, but the architecture above —
a thin PVE plugin entry point over an array **Driver** (REST), a host **Connector**
(multipath/FC), and a shared **Registry/Capabilities** spine — was deliberately
factored so it can generalize. Once the plugin is **stable and hardware-validated**,
the intent is to refactor it into a vendor-neutral framework,
[**pve-FCLUPlugin**](https://github.com/ciroiriarte/pve-FCLUPlugin) ("FC LUN"), which
keeps the same per-virtual-disk LUN model (one LUN per disk, array-offloaded
snapshots/CoW clones/resize/QoS) while supporting additional arrays — e.g. Dell
PowerMax/PowerStore, Pure Storage, IBM FlashSystem, NetApp — through pluggable drivers
behind one stable internal driver contract (vendor-neutral internally, one thin PVE
plugin type per vendor).

This Hitachi plugin is the **reference implementation** for that framework, and the
findings captured in the ADRs feed directly into its driver contract — notably
[ADR 0001 — Control-plane REST session scaling](adr/0001-control-plane-session-scaling.md)
(how a driver should authenticate without exhausting array session limits) and
[ADR 0002 — Full-clone offload](adr/0002-full-clone-offload.md) (why a driver contract
needs an explicit clone/teardown pairing rather than re-deriving array state). The
migration is **staged**: this plugin remains the supported path until the framework is
ready, so nothing here is deprecated by the roadmap.
