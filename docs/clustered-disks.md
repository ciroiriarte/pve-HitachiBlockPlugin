# Clustered Shared Disks and SCSI-3 Persistent Reservations

This runbook covers presenting a Hitachi LUN to multiple cluster nodes simultaneously
and enabling SCSI-3 Persistent Reservation (PR) support for clustered-guest fencing.

## What the plugin provides — and does not

**Multi-node presentation works out of the box.** Each cluster node has its own host
group per target port. `activate_volume` maps the LUN into the local node's host group
independently; `deactivate_volume` unmaps from the local node only. Other nodes are
unaffected. No extra configuration beyond adding each node to the `nodes=` list is
required.

**The plugin does not arbitrate writes.** Presenting a LUN to two nodes simultaneously
with no write coordination **corrupts the data**. Plain ext4, XFS, or NTFS mounted
read-write on two nodes at the same time **will corrupt**. Write safety is entirely
the guest-cluster layer's responsibility:

- Cluster filesystems: OCFS2, GFS2
- Database cluster: Oracle RAC / ASM
- Windows cluster: Windows Failover Clustering (with SCSI-3 PR fencing)

For multi-writer architecture guidance and shared-storage design patterns, see
[GitHub #3](https://github.com/ciroiriarte/pve-HitachiBlockPlugin/issues/3).

**SCSI-3 PR is LU-wide.** A reservation registered on one path applies to the LDEV
across *all* its ports and paths. Nodes do not need to share FC ports — only the LDEV.
A shared LUN multiplies its LU-path footprint by the number of attached nodes; account
for that explicitly in the per-port budget (see
[Capacity Planning — Shared LUNs & SCSI-3 PR](capacity-planning.md#shared-luns--scsi-3-persistent-reservations)).

**Plugin scope for PR (validate-and-warn only).** When `persistent_reservations 1` is
set in `storage.cfg`, `activate_volume` validates this node's host-side PR plumbing and
emits a warning if it is not ready. The plugin never modifies `multipath.conf`, never
registers PR keys, and never blocks activation.

---

## Host prerequisites (once per node)

Both prerequisites are node-level — they cover all PR-enabled disks on the node.

### 1. qemu-pr-helper

QEMU intercepts a guest's `PERSISTENT RESERVE IN/OUT` commands and forwards them to
`qemu-pr-helper`, which executes them against the real block device on the host.

Enable the socket unit:

```bash
systemctl enable --now qemu-pr-helper.socket
```

Verify the socket is listening:

```bash
ls -la /run/qemu-pr-helper.sock
# Expected: srwxrwxrwx ... /run/qemu-pr-helper.sock
```

### 2. Multipath reservation_key

A SCSI-3 PR key must be registered on every path so the reservation survives path
failover. `multipathd` propagates the configured key to new paths automatically when
`reservation_key` is set in `multipath.conf`.

Create `/etc/multipath/conf.d/hitachiblock-pr.conf` (or add to the existing
`hitachiblock-vsp.conf`):

```
# Option A — global default, applies to every multipath device on this node
defaults {
    reservation_key   0x0000000000000001   # node-unique — choose a different value per node
}
```

Or scope to Hitachi devices only:

```
# Option B — vendor/product-specific
devices {
    device {
        vendor          "HITACHI"
        product         "OPEN-V"
        reservation_key 0x0000000000000001
    }
}
```

Use a **different key value on each cluster node** — the key identifies the registrant;
sharing a key across nodes defeats fencing. A common convention is to derive the key
from the node's management IP (e.g., node at `10.0.0.1` → key `0x000000000a000001`)
or its position in the cluster.

After editing, reload multipathd:

```bash
systemctl reload multipathd
```

Confirm the key is active in the running config:

```bash
multipathd show config | grep reservation_key
# Expected: the non-zero key you configured
```

> The plugin reads `multipathd show config` during the `activate_volume` PR check and
> warns if no non-zero `reservation_key` is found. It never writes to `multipath.conf`.

---

## Enable the plugin toggle

Add `persistent_reservations 1` to the storage section in `/etc/pve/storage.cfg`:

```
hitachiblock: myarray
    mgmt_ip 10.0.1.100
    storage_id 836000123456
    pool_id 0
    target_ports CL1-A,CL2-A
    persistent_reservations 1
    ...
```

With this flag set, every `activate_volume` call for this storage validates:

1. The `qemu-pr-helper` socket is present at `/run/qemu-pr-helper.sock`.
2. `multipathd show config` reports a non-zero `reservation_key`.

If either check fails, a warning is logged (tag `HitachiBlock`; view with
`journalctl -t HitachiBlock`) and activation continues — the disk is always presented.
Without this flag (the default), no PR checks run and there is no performance impact
on ordinary single-owner volumes.

---

## Guest-side per-disk PR opt-in

SCSI-3 PR requires a disk interface that passes `PERSISTENT RESERVE IN/OUT` to the
host. **virtio-blk cannot do this** — it does not expose a SCSI command set.

### Controller requirement

Attach the disk to a **virtio-scsi** controller:

```
Hardware → Add → SCSI Hard Disk → SCSI Controller: VirtIO SCSI
```

### Disk type: scsi-hd vs scsi-block

| Type | PR mechanism | Notes |
|------|-------------|-------|
| `scsi-hd` (emulated) | QEMU emulates SCSI; PR commands forwarded to `qemu-pr-helper` | Default for virtio-scsi in PVE; no raw SG_IO needed |
| `scsi-block` (passthrough) | Guest sends `SG_IO` directly via the helper to the block device | Full SCSI passthrough; requires manual QEMU args |

`scsi-hd` with `pr-manager-helper` is the standard approach for most cluster stacks.

### Binding pr-manager-helper to a disk

PVE has no native `pr-manager` configuration key yet. Use the VM's `args:` line in
`/etc/pve/qemu-server/<vmid>.conf` to inject the QEMU object and bind it to the drive:

```
args: -object pr-manager-helper,id=pr0,path=/run/qemu-pr-helper.sock
```

Then add `pr-manager=pr0` to the generated drive argument for the disk in question.
Because PVE auto-generates most `-drive` and `-device` arguments, the cleanest way to
inject `pr-manager=pr0` per-disk without duplicating PVE's argument generation is a
**hookscript** (PVE `pre-start` phase) that appends the `-object` line and patches the
relevant drive argument before QEMU starts.

> The `args:` stanza replaces PVE's argument generation for the affected lines and is
> fragile across VM config changes. Validate the full QEMU command line after any disk
> add/remove/resize.

---

## Verify

### Node readiness (before starting a VM)

The quickest check is the bundled diagnostic — it runs both prerequisite checks
(the same read-only `check_pr_ready` the plugin uses on `activate_volume`) and
prints `READY` / `NOT READY` with the actionable messages, without touching the
array or starting a VM:

```bash
hitachiblock-repl pr-check
hitachiblock-repl pr-check --json   # machine-readable { node, ok, issues }
```

The equivalent manual checks:

```bash
# 1. qemu-pr-helper socket present?
ls -la /run/qemu-pr-helper.sock
# Expected: socket file (type 's')

# 2. multipath reservation_key configured?
multipathd show config | grep reservation_key
# Expected: a non-zero key value

# 3. Activate a volume and inspect warnings:
journalctl -t HitachiBlock -n 50
# If persistent_reservations is enabled and either check above fails,
# look for: "SCSI-3 PR not ready for '<volname>' (<wwid>): ..."
```

### Inspect PR registrations from a running guest

Once a clustered guest has issued `PERSISTENT RESERVE OUT REGISTER`:

```bash
# List all registered keys on the LUN:
mpathpersist --in --read-keys /dev/mapper/<wwid>

# Show the active reservation holder (if any):
mpathpersist --in --read-reservation /dev/mapper/<wwid>
```

Both commands are read-only and safe to run while the guest is running.

---

## Scope and safety

- **Opt-in, default off.** `persistent_reservations` defaults to `0`; no PR logic
  runs unless explicitly enabled. Single-owner volumes are unaffected.
- **Validate-and-warn only.** The plugin checks and warns; it never mutates PR state
  or multipath configuration.
- **Per-node masking unchanged.** Each node's host group maps and unmaps LUN paths
  independently regardless of PR state.
- **Multi-writer DATA safety is the guest cluster's responsibility.** The plugin
  presents the LUN; OCFS2, GFS2, Windows Failover Clustering, Oracle RAC, or the
  application must provide write ordering and fencing.
