# Operations

## Core Storage Lifecycle

### Allocate a VM Disk

Disks are allocated automatically when creating a VM or adding a disk in the PVE UI. The plugin:

1. Reserves a unique volume name under a cluster-wide lock
2. Creates a thin-provisioned LDEV on the configured DP pool
3. Labels it with `pve:<storeid>:vm-<VMID>-disk-<N>`
4. Applies QoS limits if configured (best-effort; a QoS failure does not fail the disk)
5. Maps the LUN to the local node's host group
6. Triggers SCSI rescan and waits for the multipath device to appear
7. Commits the volume to the registry **last**, only once it is real and discoverable

LUN mapping and device discovery are treated as prerequisites: if either fails the
operation **fails loudly and rolls back** the LDEV and mapping, rather than
leaving a registered-but-unusable "ghost" volume.

### Free a VM Disk

When a disk is removed or a VM is destroyed:

1. Any snapshot pairs on the LDEV are deleted first
2. All LUN mappings are removed
3. The multipath device and SCSI paths are cleaned up on the host
4. The LDEV is deleted from the array
5. The registry entry is removed

### List Images

```bash
pvesm list <storeid>
```

Lists all volumes registered in the LDEV registry for the storage. Returns volume name, size, VMID, and parent volume (for linked clones).

### Storage Status

```bash
pvesm status
```

Reports pool capacity (total, used, free) from the array to the PVE UI.

---

## Snapshots

Array-offloaded snapshots using Hitachi Thin Image. Each snapshot creates a P-VOL/S-VOL pair with copy-on-write semantics.

### Create Snapshot

```bash
qm snapshot <vmid> <snapname>
```

- Creates a Thin Image pair on the array
- S-VOL is allocated from `snap_pool_id` (or `pool_id`)
- Snapshot metadata (S-VOL LDEV ID, WWID, array snapshot ID) is stored in the cluster-replicated registry

### Delete Snapshot

```bash
qm delsnapshot <vmid> <snapname>
```

- Deletes the Thin Image pair
- S-VOL is released back to the snapshot pool
- Registry entry is removed
- **Refused** if a linked clone was created from this snapshot and still depends on
  it (the clone records its `parent_snap`); remove or fully-clone the dependent
  first to avoid corrupting it.

### Rollback Snapshot

```bash
qm rollback <vmid> <snapname>
```

- Restores the P-VOL to the state captured in the snapshot
- Uses the array-side restore operation

### Snapshot Info

The plugin implements `volume_snapshot_info` to provide snapshot tree information to the PVE UI. Snapshot metadata is read from the registry for fast access.

---

## Clones

### Linked Clone (`clone_image`)

`clone_image` is PVE's linked-clone primitive and is the only path that runs through
the plugin. It creates a **CoW Thin Image S-VOL** that shares blocks with its source:

- Source must be a **base image** (template) or a **snapshot** — matching
  `volume_has_feature('clone')` (`base`/`snap`). You cannot linked-clone an arbitrary
  live volume; use a full copy for that (see below).
- The Thin Image pair is created **without `autoSplit`**, so the S-VOL stays linked to
  the P-VOL via copy-on-write — instant and space-efficient (the VVols fast-deploy
  model). Multiple linked clones can share one base.
- **Dependency**: the S-VOL shares blocks with the source. The plugin records this
  (`parent_volname`, plus `parent_snap` when cloned from a snapshot) and **refuses to
  delete the source — or the source snapshot — while linked clones still depend on
  it** (clear error listing the dependents). Remove or full-copy the dependents first.

### Full Clone (handled by PVE core, not `clone_image`)

A full/independent copy is **not** produced by `clone_image`. PVE core copies the data
itself via the block-device path (`alloc_image` on the target + `qemu-img convert`
offline, or drive-mirror online) — the same machinery as "Move Storage". The result is
an independent volume with no dependency on the source.

### Clone from Snapshot

```bash
qm clone <vmid> <newvmid> --snapname <snapname>
```

When cloning from a named snapshot, the CoW pair's P-VOL is the snapshot's S-VOL
(the point-in-time secondary volume) rather than the source's current state, and the
clone records `parent_snap` so that snapshot cannot be deleted while the clone exists.
The optional `copy_speed` (1-15) tunes the array-side copy rate.

---

## Volume Resize

Online grow-only resize:

```bash
qm resize <vmid> <disk> +10G
```

The plugin:

1. Queries the current LDEV size from the array (not just the registry) and parses `byteFormatCapacity` (handles M/G/T unit formats)
2. If the VM is running, flushes device buffers before resize
3. Expands the LDEV on the array (async operation)
4. Rescans SCSI paths and triggers `multipathd resize map` on the host
5. Updates the registry with the new size

**Note**: Shrinking volumes is not supported (array limitation).

---

## QoS (Quality of Service)

Per-LDEV IOPS and throughput limits:

- **Upper bounds**: `qos_upper_iops` and `qos_upper_mbps` cap the maximum IOPS and throughput per LDEV
- **Lower bounds**: `qos_lower_iops` and `qos_lower_mbps` guarantee a minimum level of IOPS and throughput per LDEV, ensuring performance even under contention
- **Priority**: `qos_priority` sets the scheduling priority (`1` = high, `2` = medium, `3` = low) used by the array to arbitrate I/O when resources are contested
- All QoS parameters are automatically applied to every new LDEV during `alloc_image`
- Upper bounds, lower bounds, and priority can be combined as needed
- Existing volumes are not retroactively modified

To manage QoS on existing volumes, use the Hitachi Configuration Manager UI or the REST API directly.

---

## Orphan Detection and Cleanup

The plugin can identify inconsistencies between the LDEV registry and the actual array state.

### List Orphans

Detects:
- **Array orphans**: LDEVs on the array with `pve:<storeid>:` labels that are not in the local registry
- **Registry orphans**: Registry entries pointing to LDEV IDs that no longer exist on the array

### Cleanup Registry Orphans

Removes registry entries that reference non-existent array LDEVs. This is useful after manual array-side operations or recovery from failures.

**Note**: Array orphans (LDEVs without registry entries) are not automatically deleted to prevent data loss. They should be reviewed and handled manually.

---

## Manage / Unmanage Volumes

### Manage (Import Existing LDEV)

`manage_volume(storeid, scfg, ldev_id, vmid)` imports an existing LDEV into the plugin's registry without creating a new one. This is useful for adopting LDEVs that were pre-created on the array or that were previously unmanaged.

The plugin:

1. Reads the LDEV metadata (size, WWID) from the array
2. Assigns a PVE volume name (`vm-<VMID>-disk-<N>`) and sets the LDEV label
3. Registers the volume in the LDEV registry
4. Maps the LUN to the local node's host group

### Unmanage (Release Without Deletion)

`unmanage_volume(storeid, scfg, volname)` releases a volume from the plugin's management without deleting the LDEV on the array. The LDEV remains intact for potential re-import or external use.

The plugin:

1. Unmaps all LUN paths for the volume
2. Removes the multipath device and SCSI paths from the host
3. Clears the LDEV label on the array
4. Removes the registry entry

---

## Zero Page Reclamation

When the `discard_zero_page` configuration property is enabled (`1`), the plugin triggers zero page reclamation during `deactivate_volume`. This instructs the array to scan the LDEV for pages filled entirely with zeros and return them to the DP pool's free space.

**Benefits**:

- Recovers thin-provisioning capacity after large deletions within the guest filesystem
- Especially effective after VMs are migrated or workloads are rebalanced
- Operates at the array level with no guest-side agent required

**When it triggers**: Zero page reclamation runs every time `deactivate_volume` is called (VM shutdown, migration away from a node, etc.).

---

## Storage-Assisted Volume Migration

`volume_migrate_pool(storeid, scfg, volname, target_pool_id)` moves a volume's LDEV from its current DP pool to a different pool on the same array. The migration is performed entirely on the array side using an asynchronous copy operation.

The plugin:

1. Looks up the LDEV ID from the registry
2. Initiates an array-side pool migration to `target_pool_id`
3. The `copy_speed` parameter controls migration throughput (1-15)
4. The LDEV ID, WWID, and LUN mappings remain unchanged
5. Updates the registry after migration completes

This is useful for rebalancing storage pools, moving workloads between tiers (e.g., SSD to HDD), or evacuating a pool before maintenance.

---

## Consistency Group Snapshots

`volume_snapshot_consistency_group(scfg, storeid, volnames_arrayref, snap)` snapshots
multiple volumes as a single Hitachi consistency group, so the array holds them at a
common point in time.

Use cases:

- Multi-disk VMs that require consistent state across all disks (e.g., database data + log volumes)
- Coordinated snapshots across related VMs

The plugin:

1. Accepts an array reference of volume names to snapshot together (all resolved up
   front, so a missing volume fails before any pair is created)
2. Creates one Thin Image pair per volume, all sharing a single snapshot group with
   `isConsistencyGroup` set so the array treats them as one CG
3. **Rolls back** any pairs already created in the group if a later pair fails, so a
   partial, non-crash-consistent group is never left behind
4. Stores snapshot metadata (S-VOL LDEV IDs, WWIDs, snapshot IDs) for each volume in the registry
5. All volumes in the group share the same snapshot name

> **Note:** pairs are added to the group with one REST call each (the Configuration
> Manager API has no single multi-volume create), so crash consistency depends on
> the array's CG semantics for the shared group, not on a single atomic request.

Individual snapshot operations (delete, rollback) can still be performed per-volume after the group snapshot is created.

---

## Connectivity Check

```bash
# The plugin provides a lightweight connectivity check
# Used internally during activate_storage and available programmatically
```

`check_connection` verifies the API endpoint is reachable and the session is valid without performing heavy operations.

---

## Replication CLI Tool

The `hitachiblock-repl` command manages remote replication pairs for disaster recovery and active-active configurations.

### Connection Parameters

Credentials are read from the plugin's credential store
(`/etc/pve/priv/hitachiblock/<storeid>.creds`). The management IP, storage serial,
and port are resolved automatically in this order:

1. explicit flags: `--mgmt-ip`, `--storage-id`, `--mgmt-port`
2. the `hitachiblock: <storeid>` section of `/etc/pve/storage.cfg` (the same source
   the plugin uses — no extra configuration needed on a PVE node)
3. the legacy environment variables, as a fallback:

```bash
export HITACHI_MGMT_IP=10.0.1.100       # Configuration Manager API IP
export HITACHI_STORAGE_ID=836000123456  # Local storage serial number
export HITACHI_MGMT_PORT=443            # API port (optional)
```

On a normal PVE node you only need `--storeid`; everything else comes from
`storage.cfg`:

```bash
hitachiblock-repl list --storeid myarray
```

### Remote Storage Management

```bash
# List registered remote storage systems
hitachiblock-repl remote-list --storeid <storeid>

# Register a new remote storage system
hitachiblock-repl remote-add --storeid <storeid> \
    --remote-storage-id 836000654321 \
    --remote-ip 10.0.2.100
```

### TrueCopy (Synchronous Replication)

Synchronous replication for zero RPO. Every write is committed to both local and remote arrays before acknowledgment.

```bash
# Create a TrueCopy pair (use --volume vm-100-disk-1 to resolve --pvol automatically)
hitachiblock-repl create-tc --storeid <storeid> \
    --pvol 1024 \
    --svol 2048 \
    --remote-storage-id 836000654321 \
    --copy-group mygroup \
    --pair-name mypair
```

### Universal Replicator (Asynchronous Replication)

Asynchronous replication with journal-based write ordering. Provides RPO measured in seconds.

```bash
# Create a Universal Replicator pair
hitachiblock-repl create-ur --storeid <storeid> \
    --pvol 1024 \
    --svol 2048 \
    --remote-storage-id 836000654321 \
    --copy-group mygroup \
    --pair-name mypair \
    --journal-id 0
```

**Note**: Journal volumes must be pre-created on both arrays. See [prerequisites.md](prerequisites.md).

### Global-Active Device (GAD)

Active-active replication where both copies are simultaneously accessible. Provides continuous availability.

```bash
# Create a GAD pair
hitachiblock-repl create-gad --storeid <storeid> \
    --pvol 1024 \
    --svol 2048 \
    --remote-storage-id 836000654321 \
    --copy-group mygroup \
    --pair-name mypair \
    --quorum-disk-id 0
```

**Note**: A quorum disk must be configured. See [prerequisites.md](prerequisites.md).

### Pair Status and Lifecycle

`status`, `split`, `resync`, and `delete` operate on a pair by its `--pair-id`
(as shown in the `list` output), regardless of replication type:

```bash
hitachiblock-repl list   --storeid <storeid>            # find the PAIR_ID
hitachiblock-repl status --storeid <storeid> --pair-id <id>
hitachiblock-repl split  --storeid <storeid> --pair-id <id>   # suspend
hitachiblock-repl resync --storeid <storeid> --pair-id <id>   # resume
hitachiblock-repl delete --storeid <storeid> --pair-id <id>
```

`list` also accepts `--json` for scripting.

---

## Orphan Detection (CLI)

The `orphans` command surfaces inconsistencies between the LDEV registry and the
array — useful after manual array operations or recovery from a failure:

```bash
# Human-readable report
hitachiblock-repl orphans --storeid <storeid>

# Machine-readable
hitachiblock-repl orphans --storeid <storeid> --json

# Prune stale registry entries (registry orphans) after reviewing the report
hitachiblock-repl orphans --storeid <storeid> --auto-cleanup
```

It reports two categories:

- **Array orphans** — LDEVs on the array carrying this storage's label prefix that
  are not in the registry (review manually; they may hold data and are never
  auto-deleted).
- **Registry orphans** — registry entries whose LDEV no longer exists on the array.
  `--auto-cleanup` removes these stale entries. This is safe because the command
  scans **all** array LDEVs (not just one pool), so a live volume in any pool — a
  snapshot S-VOL pool, or a pool a volume was migrated/imported into — is never
  mistaken for an orphan.

---

## VM Migration

The plugin supports live and offline VM migration between PVE cluster nodes:

1. **Target node** calls `activate_volume()`:
   - Checks if the LUN is mapped to the target node's host group
   - If not (post-migration), creates the LUN mapping
   - Triggers SCSI rescan
   - Waits for the multipath device to appear

2. **VM runs on the target node**

3. **Source node** calls `deactivate_volume()`:
   - Flushes I/O buffers
   - Removes the multipath device and SCSI paths
   - Unmaps the LUN from the source node's host group

This ensures each LUN is mapped only to the active node, keeping the per-host LUN count low.

Each cluster node has its own host group (per target port), so `activate_volume`
maps the LUN into the local node's host group and `deactivate_volume` unmaps it
from the local node's host group only. A node's map/unmap therefore never affects
another node's access, which is what makes live migration safe: the target node
maps the LUN before the VM starts there, and the source node unmaps it afterwards.

> **Note:** the plugin does not maintain a cluster-wide active-node refcount; each
> node independently maps on activate and unmaps on deactivate against its own
> host group. During a live-migration overlap the volume is simply mapped on both
> the source and target nodes until the source deactivates.

---

## Disk Migration Between Storage Types

You can move a VM disk between a file-based store (`dir`/NFS holding `qcow2` or
`raw`) and a Hitachi LUN in **either direction**. PVE has **no in-place "retype"** —
moving between storage types is always a physical copy with format conversion.

There are two distinct PVE mechanisms, with different requirements:

### 1. Move Storage — same node/cluster (`qm disk move`, GUI "Move Storage")

Allocates a new volume on the target and copies the data through QEMU over the
device path (`filesystem_path`). It does **not** use the export/import API.

- **Online (VM running):** `qemu drive-mirror` → **hot**, live, source dropped after the mirror converges.
- **Offline (VM stopped):** `qemu-img convert` → **cold** copy.

The plugin provides `alloc_image` plus a real `/dev/mapper/<wwid>` path, so this
works both ways with on-the-fly format conversion.

| Direction | Supported | Format result |
|-----------|-----------|---------------|
| qcow2 file → Hitachi LUN | ✅ hot or cold | qcow2 → **raw** on the LUN |
| raw file → Hitachi LUN | ✅ hot or cold | raw (copied) |
| Hitachi LUN → qcow2 file | ✅ hot or cold | raw → **qcow2** |
| Hitachi LUN → raw file | ✅ hot or cold | raw (copied) |

### 2. storage_migrate — offline cross-node / cross-cluster / `pvesm`

Used by **offline** `qm migrate` to a node where this storage is *not* shared,
`qm remote-migrate`, and `pvesm export`/`import`. It streams the volume using the
`volume_export`/`volume_import` API (`raw+size`), which the plugin implements by
`dd`-ing the raw block device — the same approach as the Ceph/RBD plugin.

- Always a **cold** (offline) data copy. The source LUN must be mapped/active on the
  source node during export (the migration framework activates it).
- Only the **active volume state** is transferred — array-offloaded Thin Image
  snapshots are *not* part of the stream, so migrations with snapshots are refused.

> For a *running* VM whose disk is already on the Hitachi LUN, normal `qm migrate`
> needs **no disk copy** at all — the storage is `shared`, so the LUN is simply
> remapped to the target node (see [VM Migration](#vm-migration)). That is the
> "hottest" path, but it does not change storage type.

### Caveats (both mechanisms)

- **Snapshots are not carried over.** The copy takes the active state only; flatten
  or remove snapshots first. Thin Image snapshots are array-side, not part of a
  qcow2 chain.
- **The LUN side is always `raw`** (the only format this plugin advertises). qcow2
  features (internal snapshots) are replaced by array offloads after the move.
- **Thin reclaim:** after qcow2/raw → LUN, run `fstrim` in the guest (or enable
  `discard_zero_page`) so the DP pool reflects actual usage.

---

## Troubleshooting

### Device Not Appearing After Allocation

```bash
# Check FC link status
cat /sys/class/fc_host/host*/port_state
# Expected: Online

# Check multipath status
multipath -ll

# Manual SCSI rescan
echo "- - -" > /sys/class/scsi_host/host0/scan

# Check for the expected WWID
# WWID format: 60060e80<serial_hex><ldev_hex><zero_padding>
#
# The plugin first tries this synthesized WWID, and if it does not resolve it
# self-corrects by reading the device's real page-83 identifier from sysfs:
for d in /sys/block/sd*/device/wwid; do echo "$d: $(cat $d)"; done
```

If the synthesized and real WWIDs differ on your array model, the plugin persists
the real WWID it discovers in the registry, so subsequent activate/resize/free
operations use the correct device. A persistent mismatch usually indicates the
NAA layout assumed by `ldev_to_wwid` does not match your model — capture the real
WWID above and open an issue.

### LUN Mapping Issues

- Verify host group exists on the target ports via Configuration Manager UI
- Check that the node's FC WWNs are registered in the host group
- Verify SAN zoning allows the node to see the target ports

```bash
# Show local FC WWNs
cat /sys/class/fc_host/host*/port_name
```

### API Connection Failures

```bash
# Test API endpoint reachability
curl -k https://<mgmt_ip>:<port>/ConfigurationManager/v1/objects/storages/<storage_id>/pools

# Check credentials
cat /etc/pve/priv/hitachiblock/<storeid>.creds
```

### Stale Devices After Free

```bash
# Force flush multipath map
multipath -f <wwid>

# Remove individual SCSI path
echo 1 > /sys/block/sdX/device/delete
```

### Session Expired Errors

The plugin automatically re-authenticates on session expiry. If persistent session errors occur:

- Verify the API user account is not locked
- Check if maximum concurrent sessions limit is reached on the Configuration Manager
- Restart pvedaemon to force a fresh session: `systemctl restart pvedaemon`

### Registry Inconsistencies

If the LDEV registry becomes inconsistent with the array state (e.g., after manual array operations):

1. Use the orphan detection feature to identify mismatches
2. Review array orphans manually before taking action (they may contain data)
3. Use registry cleanup to remove stale registry entries

### QoS Not Applied

QoS is only applied to newly allocated volumes. If `qos_upper_iops` or `qos_upper_mbps` were added after volumes were created, use the Configuration Manager UI to set QoS on existing LDEVs.
