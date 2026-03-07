# Operations

## Storage Services

### Snapshots

Array-offloaded via Hitachi Thin Image:

```bash
# Create snapshot (via PVE UI or CLI)
qm snapshot <vmid> <snapname>

# Delete snapshot
qm delsnapshot <vmid> <snapname>

# Rollback
qm rollback <vmid> <snapname>
```

### Clones

- **Linked clone**: Fast, space-efficient (CoW). S-VOL depends on P-VOL.
- **Full clone**: Independent copy via snapshot + array-side copy. Slower but standalone.

### Volume Resize

Online grow-only. Triggers LDEV expand on array + host-side multipath resize.

```bash
qm resize <vmid> <disk> +10G
```

## Data Flows

### Allocate Disk
1. Generate volname `vm-<VMID>-disk-<N>`
2. Create LDEV (async) on DP pool
3. Set LDEV label `pve:<storeid>:<volname>`
4. Register in LDEV map
5. Find/create host group with local WWNs
6. Map LUN to host group
7. SCSI rescan + wait for `/dev/mapper/<wwid>`

### Free Disk
1. Delete snapshot pairs
2. Unmap all LUN paths
3. Remove multipath device + SCSI paths
4. Delete LDEV (async)
5. Unregister from LDEV map

### VM Migration
1. `activate_volume()` on target: map LUN, rescan, wait for device
2. VM runs on target
3. `deactivate_volume()` on source: flush, remove device, unmap LUN

## Troubleshooting

### Device not appearing after allocation
```bash
multipath -ll          # Check multipath status
cat /sys/class/fc_host/host*/port_state  # Verify FC links
```

### LUN mapping issues
Check host group and WWN registration on the array via Configuration Manager UI.

### Stale devices after free
```bash
multipath -f <wwid>    # Force flush
echo 1 > /sys/block/sdX/device/delete  # Remove SCSI path
```
