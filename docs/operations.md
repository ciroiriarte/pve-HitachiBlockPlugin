# Operations

## Core Storage Lifecycle

### Allocate a VM Disk

Disks are allocated automatically when creating a VM or adding a disk in the PVE UI. The plugin:

1. Creates a thin-provisioned LDEV on the configured DP pool
2. Labels it with `pve:<storeid>:vm-<VMID>-disk-<N>`
3. Applies QoS limits if configured
4. Maps the LUN to the local node's host group
5. Triggers SCSI rescan and waits for the multipath device to appear

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

### Linked Clone

- Created when the clone target uses the same storage
- Uses Thin Image pair: S-VOL shares blocks with P-VOL via copy-on-write
- Fast creation, space-efficient
- **Dependency**: S-VOL depends on P-VOL; the source volume cannot be deleted while linked clones exist
- Parent volume is tracked in the registry

### Full Clone

- Created when the clone target uses a different storage or a full copy is requested
- Creates a temporary snapshot, copies data to a new independent LDEV, then deletes the temporary snapshot
- Slower but produces a fully independent volume
- No dependency on the source volume after creation
- The `copy_speed` parameter (1-15) controls the array-side copy rate; higher values complete faster but consume more array resources

### Clone from Snapshot

```bash
qm clone <vmid> <newvmid> --snapname <snapname>
```

When cloning from a named snapshot, the plugin uses the S-VOL (snapshot secondary volume) as the clone source instead of the current P-VOL state.

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

`volume_snapshot_consistency_group(scfg, storeid, volnames_arrayref, snap)` creates an atomic, crash-consistent snapshot across multiple volumes simultaneously. All volumes in the group are snapshotted at the same array-side point in time.

Use cases:

- Multi-disk VMs that require consistent state across all disks (e.g., database data + log volumes)
- Coordinated snapshots across related VMs

The plugin:

1. Accepts an array reference of volume names to snapshot together
2. Issues a single consistency group snapshot request to the array
3. Stores snapshot metadata (S-VOL LDEV IDs, WWIDs, snapshot IDs) for each volume in the registry
4. All volumes in the group share the same snapshot name

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

### Environment Variables

```bash
export HITACHI_MGMT_IP=10.0.1.100      # Configuration Manager API IP
export HITACHI_STORAGE_ID=836000123456  # Local storage serial number
export HITACHI_MGMT_PORT=443            # API port (optional, default 443)
```

Credentials are read from the plugin's credential store (`/etc/pve/priv/hitachiblock/`). The tool finds credentials for the matching storage ID.

### Remote Storage Management

```bash
# List registered remote storage systems
hitachiblock-repl remote-list --storeid <storeid>

# Register a new remote storage system
hitachiblock-repl remote-add --storeid <storeid> \
    --remote-serial 836000654321 \
    --remote-ip 10.0.2.100 \
    --remote-port 443 \
    --remote-model M8 \
    --path-group 0
```

### TrueCopy (Synchronous Replication)

Synchronous replication for zero RPO. Every write is committed to both local and remote arrays before acknowledgment.

```bash
# Create a TrueCopy pair
hitachiblock-repl create-tc --storeid <storeid> \
    --ldev-id 1024 \
    --remote-serial 836000654321 \
    --remote-ldev-id 2048 \
    --copy-group mygroup \
    --copy-pair mypair

# Check pair status
hitachiblock-repl status --storeid <storeid> \
    --copy-group mygroup --copy-pair mypair

# Split pair (suspend replication)
hitachiblock-repl split --storeid <storeid> \
    --copy-group mygroup --copy-pair mypair

# Resync pair (resume replication)
hitachiblock-repl resync --storeid <storeid> \
    --copy-group mygroup --copy-pair mypair

# Delete pair
hitachiblock-repl delete --storeid <storeid> \
    --copy-group mygroup --copy-pair mypair
```

### Universal Replicator (Asynchronous Replication)

Asynchronous replication with journal-based write ordering. Provides RPO measured in seconds.

```bash
# Create a Universal Replicator pair
hitachiblock-repl create-ur --storeid <storeid> \
    --ldev-id 1024 \
    --remote-serial 836000654321 \
    --remote-ldev-id 2048 \
    --copy-group mygroup \
    --copy-pair mypair \
    --journal-id 0 \
    --remote-journal-id 0
```

**Note**: Journal volumes must be pre-created on both arrays. See [prerequisites.md](prerequisites.md).

### Global-Active Device (GAD)

Active-active replication where both copies are simultaneously accessible. Provides continuous availability.

```bash
# Create a GAD pair
hitachiblock-repl create-gad --storeid <storeid> \
    --ldev-id 1024 \
    --remote-serial 836000654321 \
    --remote-ldev-id 2048 \
    --copy-group mygroup \
    --copy-pair mypair \
    --quorum-id 0
```

**Note**: A quorum disk must be configured. See [prerequisites.md](prerequisites.md).

### List Replication Pairs

```bash
# List all remote copy pairs
hitachiblock-repl list --storeid <storeid>

# JSON output
hitachiblock-repl list --storeid <storeid> --json
```

### Common Operations

All pair operations (status, split, resync, delete) use the same syntax regardless of replication type (TC/UR/GAD):

```bash
hitachiblock-repl <command> --storeid <storeid> \
    --copy-group <group> --copy-pair <pair>
```

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

### Multi-Attach

The `activate_volume` and `deactivate_volume` operations handle concurrent multi-node mappings for scenarios where a volume needs to be accessible from multiple nodes simultaneously (e.g., during live migration overlap or shared-disk clusters). The plugin tracks the set of active nodes per volume and only unmaps the LUN when the last node deactivates it.

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
```

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
