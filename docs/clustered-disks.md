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

## Cache mode and write safety

A shared LUN is only safe if **every node reads and writes the array directly** — the host
page cache must be **out of the path**. The QEMU disk cache mode controls this, and it is
easy to get wrong.

- **Use `cache=none`** (O_DIRECT) for any shared/clustered disk. Writes bypass the host
  page cache and go straight to the array; reads come from the array. This is what makes
  the disk **coherent across nodes**.
- **Never use `cache=writeback` or `cache=writethrough`** on a shared LUN. Both stage data
  in the **host** page cache, which is **per host** — node A's cached writes are invisible
  to node B → stale reads, lost updates, **corruption**. This holds **even with a cluster
  filesystem or SCSI-3 PR**: those coordinate *who may write*, but they assume the
  underlying storage is coherent, which host write-back breaks.
- **`cache=directsync`** (O_DIRECT + O_SYNC) is the strongest option — every write is also
  flushed to stable storage — for cluster stacks that need synchronous write durability.
- A PR disk attached via **`scsi-block` is always direct** (raw SG_IO bypasses the QEMU
  block layer), so cache mode does not apply to it. The concern is for any **other** shared
  data disk attached as a normal PVE disk (e.g. an OCFS2/GFS2 data LUN that does not use
  PR): set `cache=none` on it explicitly.
- Do **not** disable write barriers / FUA in the guest filesystem; the cluster FS relies on
  ordered flushes for crash consistency.

Rule of thumb: **`cache=none` (or `directsync`) on every shared disk; `writeback` on a
shared LUN is a data-corruption bug waiting to happen.**

---

## Host prerequisites (once per node)

Both prerequisites are node-level — they cover all PR-enabled disks on the node.

### 1. qemu-pr-helper

QEMU intercepts a guest's `PERSISTENT RESERVE IN/OUT` commands and forwards them to
`qemu-pr-helper`, which executes them against the real block device on the host.

The `qemu-pr-helper` **binary** ships with `pve-qemu-kvm` (always present on a PVE
node), but Proxmox does **not** package its systemd units. This plugin therefore ships
them itself — `qemu-pr-helper.socket` and `qemu-pr-helper.service`, installed to
`/lib/systemd/system/` but **disabled** (PR is opt-in). Enable the socket per node
only when you use `persistent_reservations`:

```bash
systemctl enable --now qemu-pr-helper.socket
```

Enabling the socket makes `/run/qemu-pr-helper.sock` listen immediately; the service
is socket-activated on the first connection from QEMU. Verify:

```bash
ls -la /run/qemu-pr-helper.sock
# Expected: srw------- ... /run/qemu-pr-helper.sock   (SocketMode=0600)
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

### Disk type: use `scsi-block` (not `scsi-hd`)

| Type | PR mechanism | Result, live-validated on a VSP E590H |
|------|-------------|---------------------------------------|
| `scsi-block` (passthrough) | Guest SG_IO; the privileged PR commands are routed via `pr-manager` → `qemu-pr-helper` to the real device | **Works.** PR register/reserve reach the array, and the guest sees the **real Hitachi WWID** (VPD page 83, `60060e80…`), so every cluster node identifies the shared disk identically. |
| `scsi-hd` (emulated) | QEMU emulates the disk and is *meant* to forward PR to the helper | **Did not work.** The emulated disk rejected `PERSISTENT RESERVE OUT` with *Illegal Request / Invalid command operation code*. |

**Use `scsi-block`.** It was the only frontend that serviced PR on this QEMU build, and
its passthrough gives every cluster node the *same* SCSI page-83 identity (the real
`60060e80…` NAA) — which clustered software (e.g. Windows Failover Clustering) relies on
to recognise one shared disk across nodes. (With `scsi-hd`, QEMU synthesises the identity;
if you must use it, pin an identical `serial=`/`wwn=` in **every** node's VM config — and
note QEMU's `wwn=` is only a 64-bit NAA and cannot carry the 128-bit Hitachi WWID.)

#### `scsi-block` still needs `qemu-pr-helper`

Passthrough does **not** mean PR bypasses the helper. QEMU passes the ordinary commands
(READ/WRITE/INQUIRY and PR **IN**) straight through via `SG_IO`, but it **special-cases
`PERSISTENT RESERVE OUT`** (register/reserve/release/preempt) and routes it to the
`pr-manager` (`qemu-pr-helper`) — never inline. Why: (1) a verbatim PR OUT to
`/dev/mapper/3…` only hits **one** path, so the reservation registers on a single I_T
nexus and a subsequent RESERVE conflicts; the helper registers on **all** paths via
`libmpathpersist`. (2) privilege separation — PR OUT is privileged and is delegated to the
dedicated root helper. With `scsi-block` and **no** `pr-manager`, PR OUT simply fails. So
the helper is required, not redundant.

#### What you trade away with `scsi-block` (and what our array offloads recover)

`scsi-block` bypasses QEMU's block layer **for this disk**, so the block-layer features are
unavailable on it. Most are recovered by the plugin's array-offloaded operations or are
not meaningful for a shared disk; the table maps each:

| Block-layer feature (per shared disk) | Recovered by our array offloads? / permanent gap |
|---|---|
| **IO throttling** (`mbps`/`iops`) | **Recovered — array QoS** (`qos_upper/lower_iops`, `qos_*_mbps`, `qos_priority`): enforced on the LDEV by the array, host-independent. |
| **Snapshot** of the disk | **Recovered (offloaded) — Thin Image** (`volume_snapshot`) and **consistency-group** snapshots across the cluster's LUNs. Array-side / out-of-band; only the per-VM `qm snapshot` UX is lost (and is semantically wrong for a shared disk anyway). |
| **Clone** | **Recovered — array linked clone (Thin Image CoW) / full clone.** |
| **Online resize** | **Recovered — array `volume_resize`** (the guest re-reads capacity). |
| **Cache modes** (writeback/through) | **Not a loss — always-direct SG_IO is exactly what a shared clustered disk needs** (see Cache mode below). |
| **qcow2 / image formats** | **N/A by design** — the plugin is strictly 1-LUN-per-disk **raw**. |
| **PVE `vzdump` backup** of the disk | **Permanent gap (within the plugin).** No offloaded VM-backup of a passthrough disk; protect the LDEV via an array snapshot + external copy (array replication would cover it but is not implemented). |
| **PVE hot `move-disk`** (storage live-migration) of the disk | **N/A by design for a *shared* disk;** array-side pool relocation exists (`volume_migrate_pool`) for the LDEV. |
| Real device VPD/**WWID** to the guest | **Gained**, not lost (required for clustered identity). |

The one genuine permanent loss is per-VM `vzdump` of the passthrough disk. Everything else
is either recovered by an array offload (QoS, snapshot/CG-snapshot, clone, resize) or N/A
for a shared LUN.

#### This is not exposed in the PVE web UI

There is **no GUI control** for the device model (`scsi-hd` vs `scsi-block`) or for
`pr-manager`; the web "Add SCSI Hard Disk" always creates an emulated `scsi-hd`. Set it on
the VM (stopped; effective next start) via `qm set <vmid> --args '…'`, by editing
`/etc/pve/qemu-server/<vmid>.conf`, or a hookscript — see below. (The `persistent_reservations`
checkbox in the storage GUI is the storage-level **readiness toggle**, not a per-disk model
control.) Because the shared LUN is attached as a raw passthrough through `args:`, it does
**not** appear as a normal disk row in the GUI either.

### Binding it via `args:` (validated recipe)

PVE has no native `pr-manager`/`scsi-block` key yet, so inject it through the VM's `args:`
line in `/etc/pve/qemu-server/<vmid>.conf`. This exact form was validated live (the LUN's
host multipath device is `/dev/mapper/3<wwid>`):

```
args: -object pr-manager-helper,id=pr0,path=/run/qemu-pr-helper.sock -drive file=/dev/mapper/3<wwid>,if=none,id=prd0,format=raw,file.locking=off,file.pr-manager=pr0 -device virtio-scsi-pci,id=prscsi0 -device scsi-block,bus=prscsi0.0,drive=prd0
```

Live-testing notes:
- `pr-manager` must be on the **file child** — `file.pr-manager=pr0` — *not* the top-level
  `-drive` (a top-level `pr-manager=` fails with *"Block format 'raw' does not support the
  option 'pr-manager'"*).
- The shared LUN here is **not** a PVE-managed disk of the VM, so PVE will not map it: the
  node must already have `/dev/mapper/3<wwid>` present (mapped/activated) **before** the
  guest starts, on **every** node the guest can run on.
- `file.locking=off` lets the same block device back guests on different nodes.

> The `args:` stanza is fragile across VM config changes — validate the full QEMU command
> line after any disk add/remove/resize. A `pre-start` hookscript is the more robust way to
> assemble it.

### Multipath: register with ALL_TG_PT

On a **multipathed** LUN (the normal case — e.g. two FC paths), a plain PR registration
lands on each path's I_T nexus *separately*, and the subsequent RESERVE is then rejected
with a **reservation conflict**. Register with the **ALL_TG_PT** flag so the key applies
across all target ports as a single registration:

```
# inside the guest:
sg_persist --out --register --param-sark=0x<key> --param-alltgpt /dev/<disk>
sg_persist --out --reserve  --param-rk=0x<key> --prout-type=1 /dev/<disk>
```

Multipath-aware cluster software sets ALL_TG_PT itself. Validated on the VSP E590H:
**without** ALL_TG_PT the multipath RESERVE returns *reservation conflict*; **with** it,
register → reserve → fence → preempt all succeed. (Single-path PR works either way.)

---

## Live migration of a PR-holding guest

A persistent reservation is bound to the **I_T nexus** (the host's HBA WWPNs), not to the
VM. Live migration moves the guest to a host with a **different** nexus, so the reservation
does **not** automatically follow:

- `qemu-pr-helper` **must be enabled on every node** the guest can migrate to (the units
  ship disabled — run `systemctl enable --now qemu-pr-helper.socket` per node).
- QEMU's `pr-manager` must re-establish the guest's registrations over the destination
  nexus on arrival. Whether PR survives a live migration cleanly depends on the QEMU
  version's pr-manager migration support and **must be validated in your environment** —
  it is not guaranteed.
- During migration the LUN is briefly mapped on both nodes (late binding), so the array
  transiently holds the registration on both the source and destination nexus until the
  source unmaps.

If you cannot confirm clean PR-across-migration on your stack, **pin PR-using clustered
guests to HA restart** rather than live migration.

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
