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

- Configured at the storage level via `qos_upper_iops` and `qos_upper_mbps`
- Automatically applied to every new LDEV during `alloc_image`
- Both limits can be set simultaneously
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
