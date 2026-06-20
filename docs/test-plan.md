# Test Plan — VSP E590H bring-up on the lab PVE 9.2 cluster

Environment-specific runbook for the **first live validation** of the plugin. It
sequences three things into one ordered pass:

1. the **PVE-recommended storage-plugin acceptance steps**
   ([wiki](https://pve.proxmox.com/wiki/Storage_Plugin_Development)),
2. the plugin's **hardware-assumption checks** in
   [`INTEGRATION_CHECKLIST.md`](INTEGRATION_CHECKLIST.md) (referenced as **IC §x**,
   not duplicated here), and
3. the **safety controls** required because the test array is shared with production.

> **Status:** alpha, never run against live hardware. Treat every step as capable of
> destroying data until proven otherwise. A phase passes only when verified on the
> E590H — not by `make test`.

---

## 1. Environment

> Concrete node IPs, the SSH jump path, and credential locations live in the **local,
> untracked `TESTING.md`** (this repo is public — keep addressing and secrets out of it).

| Item | Value |
|------|-------|
| PVE cluster | 4 × PVE **9.2** nodes (root SSH) |
| **SAN-connected nodes** | only **2 of the 4** — *to be identified in Phase A* |
| Array | **Hitachi VSP E590H**, `platform vsp_e`, embedded CM REST on the controller GUM(s), port **443** |
| SAN | 1 physical FC switch, 2 virtual switches (dual fabric) |
| Test pool | **pool 0** (tiered; *also* the backup pool — **shared/production**, expect unmanaged LUNs) |
| Avoid | **pool 1** (object-storage — production) |
| Access path | via the lab jump host — see `TESTING.md` |

### Values to discover in Phase A (fill in before Phase C)

| Symbol | Meaning | Value |
|--------|---------|-------|
| `SAN_NODES` | the 2 nodes with FC HBAs online | _____ , _____ |
| `MGMT_IPS` | controller GUM management IP(s) (one VIP or two) | _____ |
| `SID` | 12-digit `storageDeviceId` (NOT the bare serial) | _____ |
| `TARGET_PORTS` | E590H FC target ports zoned to the SAN nodes | _____ |
| `LDEV_RANGE` | **reserved, currently-empty** LDEV window for the plugin | _____ |
| `API_USER` | dedicated REST user (Provisioning + Local Copy roles) | _____ |

---

## 2. Safety controls (mandatory — read before touching the array)

Pool 0 holds **unmanaged production LUNs** (a third-party backup product). The plugin can create, map,
delete, and *orphan-scan* LDEVs. To guarantee it can never touch production:

- **S1 — Fence with `ldev_range`.** Allocate the plugin a reserved, verified-empty
  LDEV window (`LDEV_RANGE`) and set it in `storage.cfg` **before any provisioning**.
  Confirm the window is unused on the array first (IC §2.2). No range ⇒ do not proceed.
- **S2 — No orphan auto-cleanup.** **Never** run
  `hitachiblock-repl orphans --auto-cleanup` against this array during the test. Without
  a range, every unmanaged production LUN looks like an orphan. Run orphan scans **read-only** only,
  and eyeball the list before acting (IC §1.3, §6.2).
- **S3 — Contain snapshots.** Use `snap_pool_id 0` (keep TI S-VOLs inside the test pool)
  rather than pool 1. Accept the pool-0 space impact; monitor it (S5).
- **S4 — Don't disturb existing zoning / host groups.** The plugin creates `PVE_<host>`
  host groups on the target ports; confirm it reuses/creates only those and leaves
  the existing production host groups and zones untouched (IC §3.1). Coordinate any zoning change
  with the SAN admin.
- **S5 — Capacity guardrail.** Before starting, record pool-0 free space. Keep total
  test allocation small (≤ a few hundred GiB thin) and watch `pvesm status` / the array
  GUI so the test never starves the production workload.
- **S6 — Change window.** Run provisioning/mapping phases in an agreed window; the array
  is production-adjacent.
- **S7 — Snapshot the plugin config.** Keep `storage.cfg` under version control on the
  nodes; record every value used in the results log (§Sign-off).
- **S8 — `ldev_range` is now a code-enforced fence (not just allocation).** The plugin
  refuses to unmap or delete any LDEV outside `ldev_range` (`_ldev_in_range` guard in
  `free_image`/`_unmap_lun_from_local`). This is a hard backstop against touching foreign
  LUNs — but still set a correct `ldev_range`, because with none configured the fence is open.
- **S9 — Never assume an array query selector filters server-side; prove it live.** Verified
  on the E590H that **`GET /luns` ignores `ldevId`** (a bogus `ldevId=99999` still returns
  every LUN in the host group). Destructive code must filter client-side and/or scope to a
  resource's own children (e.g. unmap via `GET /ldevs/<id>.ports[]`, the LDEV's *own* paths).
  Before relying on any `?filter=` selector for a destructive operation, test it with a
  matching value, a non-matching value, and a bogus value and confirm the counts differ.

> **Incident (2026-06-19, recorded for the lesson):** an early `free` relied on the (ignored)
> `ldevId` selector and scanned all host groups, unmapping several *production* fabric-A LUN
> paths from another host's host group before the array's "host I/O" guard halted it. No data
> was lost (no LDEV deleted; the fabric-B paths stayed up) and the paths were restored. Fixes:
> client-side `ldevId` filtering, unmap via `ports[]`, and the S8 fence. This is *why* S8/S9 exist.

---

## 3. Storage configuration for this environment

Add on the SAN-connected nodes only (set `nodes` to `SAN_NODES`). Fill placeholders
from Phase A:

```ini
hitachiblock: e590h-test
    mgmt_ip <MGMT_IPS>            # one VIP, or "ip1,ip2" for both controllers
    storage_id <SID>             # 12-digit storageDeviceId
    pool_id 0                    # test pool (shared w/ production backups — see S1/S5)
    snap_pool_id 0               # S3: contain snapshots in the test pool
    target_ports <TARGET_PORTS>  # e.g. CL1-A,CL2-A across both fabrics
    host_mode LINUX/IRIX
    platform vsp_e
    ldev_range <LDEV_RANGE>      # S1: REQUIRED fence — reserved empty window
    shared 1
    content images
    nodes <SAN_NODES>            # only the 2 FC-connected nodes
    # tls_verify off by default (self-signed GUM cert)
```

Credentials (kept out of `storage.cfg`):

```bash
pvesm set e590h-test --username <API_USER> --password '<...>'
```

---

## 4. Phased test sequence

Each phase: **goal → steps → expected → IC ref**. Record pass/fail per row in §Sign-off.
Stop and escalate on any **STOP-gate** failure before continuing.

### Phase A — Discovery & pre-flight (read-only, safe)
Goal: fill in §1 unknowns and confirm prerequisites without changing anything.
- A1. On each cluster node: `cat /sys/class/fc_host/host*/port_state` (→ `Online`)
  and `.../port_name` (WWNs). The nodes with online FC ports = `SAN_NODES`.
- A2. From a SAN node, log in to the REST API and enumerate identity:
  `curl -sk -u USER:PASS -XPOST https://<MGMT>/ConfigurationManager/v1/objects/sessions -d '{}'`
  then `GET .../objects/storages` → record `storageDeviceId` (`SID`). (IC §0.1–0.4)
- A3. `GET .../storages/<SID>/pools` → confirm pool 0 exists; record free capacity (S5).
  `GET .../storages/<SID>/ports` → list target ports; pick `TARGET_PORTS` (IC §3.1).
- A4. Find a free LDEV window: `GET .../ldevs?...` over a candidate range; confirm it is
  empty → `LDEV_RANGE` (S1, IC §2.2).
- A5. Confirm licenses: Dynamic Provisioning + Thin Image active (prerequisites §5).
- A6. Baseline `multipath -ll` and `/etc/multipath/wwids` on both SAN nodes (for later diff).
- **STOP-gate:** REST reachable on 443, `SID` known, pool 0 present, a verified-empty
  `LDEV_RANGE` chosen, licenses present, ≥2 nodes FC-online.

### Phase B — Install & register storage
Goal: plugin loads and the storage activates cleanly.
- B1. Install the plugin from the OBS `PVE_9` repo (README → Quick start) on **every node in
  the cluster — not only the SAN-connected ones**. `storage.cfg` is cluster-wide, so each
  node's `pvedaemon`/`pvestatd` parses the whole file; a node missing the
  `HitachiBlockPlugin.pm` module cannot resolve the `hitachiblock` type and **silently drops
  the storage from its view** (inconsistent rendering — see GitHub issue #5). Activation is
  scoped separately by `nodes=` (Phase A `SAN_NODES`); non-SAN nodes will show the storage as
  `disabled` and never try to activate it. Confirm `pvesm` loads the plugin and
  `journalctl -u pvedaemon` shows no "unsupported API" warning (IC §6.1). Verify on a non-SAN
  node that `pvesm status` lists `e590h-test` (as `disabled`) rather than omitting it.
- B2. Add the §3 stanza; `pvesm set` credentials. `systemctl reload-or-restart pvedaemon`.
- B3. `pvesm status` → `e590h-test` is `active`; capacity matches the array GUI (IC §2.4).
- B4. `pvesm scan` / activate; confirm `PVE_<host>` host groups appear **only** on the
  target ports with each node's WWNs, leaving existing groups intact (IC §3.1, S4).
- **STOP-gate:** storage `active`, capacity sane, host groups correct, production untouched.

### Phase C — Core provisioning & data path (one volume)
Goal: a single LUN allocates, maps, multipaths, and benchmarks. Highest-signal phase.
- C1. `pvesm alloc e590h-test 0 '' 16G` (or via UI). Confirm LDEV created **inside**
  `LDEV_RANGE` with a correct 32-char label (IC §2.1, §2.3).
- C2. Size check: array `blockCapacity*512` == exactly the requested bytes, or note the
  documented rounding (IC §2.1 — **size-unit gate**).
- C3. Data path: `multipath -ll` shows `3<wwid>` with multiple paths across both fabrics;
  entry added to `/etc/multipath/wwids`; synthesized WWID == real page-83 (IC §3.2–3.4).
- C4. `fio` raw write/read to `/dev/mapper/3<wwid>` (e.g. 4k randrw, 64k seq) — sane
  throughput/IOPS for the array, no path errors in `multipath -ll` / `dmesg`.
- C5. Free it: `pvesm free`; confirm LUN unmapped, multipath device gone, `wwids` entry
  removed, LDEV deleted (IC §3.3). Diff against the A6 baseline → no residue.
- **STOP-gate:** allocate→map→multipath→I/O→free is clean and leaves no orphan.

### Phase D — PVE functional acceptance (VM + CT)
Goal: the PVE-recommended matrix. Guests live on `e590h-test`, on the SAN nodes.
- D1. Create one **VM** and one **CT** with wizard defaults on `e590h-test` (PVE step 2).
- D2. Add a second **data disk** to each guest (PVE step 3).
- D3. Add a **vTPM** state drive to the VM (PVE step 4) — confirms tiny-LUN handling.
- D4. Inside the VM, run `fio`/CrystalDiskMark on the data disk for adequate
  performance (PVE step 5).
- D5. **Disk bus matrix** (VM): repeat attach/boot/IO with **VirtIO-Blk**, **SCSI
  (virtio-scsi)**, **SCSI (LSI)**, and **SATA/IDE** (PVE step 6).
- D6. **Thin provisioning + discard**: enable `Discard` on a SCSI/VirtIO disk; write then
  delete a large file in-guest with `fstrim`; confirm pool-0 usage drops (IC §5.3, S5).
- D7. **Online resize**: grow the data disk via `qm resize`; guest sees the new size
  without reboot (IC §3.5).
- D8. **Content**: download a CT template and an ISO directly onto the storage's allowed
  content types (PVE step 7) — *only if* `content` is extended beyond `images`; otherwise
  record as N/A (block storage typically serves `images`/`rootdir` only).
- D9. **Purge**: detach a disk, then remove the "unused disk" entry; confirm LDEV freed
  and no orphan (PVE step 7; IC §3.3).

### Phase E — Snapshots & CoW linked clones (highest-risk new behaviour)
Goal: prove Thin Image semantics match the code's assumptions.
- E1. `qm snapshot` a VM, write data, `qm rollback`, confirm revert; `qm delsnapshot`
  (IC §4.1).
- E2. **Linked clone** a template/base; confirm **instant + minimal pool growth** (NOT a
  full copy) and the S-VOL persists as a live CoW pair (IC §4.2 — **clone gate**).
- E3. Full clone (if ShadowImage licensed) handled via the device path by PVE core.
- E4. **Dependency guards:** attempt to delete a base/source snapshot while a clone
  exists → must fail clearly; delete the clone, then the source succeeds (IC §4.3).
- E5. Multi-disk VM consistency-group snapshot + induced mid-group failure rolls back
  (IC §4.4).

### Phase F — Migration matrix (limited to the 2 SAN nodes)
Goal: the storage_migrate / Move-Storage matrix. Shared LUN ⇒ live migration works
**only between the 2 SAN nodes**; a non-SAN node is offline/export-import only.
- F1. **CT** migrate between the two SAN nodes (offline) (IC §6.3).
- F2. **VM offline** migrate between the two SAN nodes.
- F3. **VM online (live)** migrate between the two SAN nodes (IC §6.3, §6.4).
- F4. Repeat F3 **with `fio` running inside the guest** to generate IO load during the
  live migration (PVE step 7, final) — no path drops, no corruption.
- F5. **Move Storage** a disk LUN→file store and qcow2→LUN, hot and cold (IC §6.3).
- F6. Offline-migrate a VM to a **non-SAN** node via export/import; confirm clean failure
  or successful relocation per the documented matrix (IC §6.3).
- **F7. DATA-INTEGRITY GATE (run after every F1–F6 copy onto `e590h-test`).** A copy that
  silently truncates passes "the VM booted" only by luck — verify the **bytes**, not just
  that it ran. After each Move-Storage / migrate / export-import onto the array:
  - Record the **source** allocated size first (`rbd du` / `qemu-img info`); a real OS disk
    is GiB, not ~100 MiB.
  - Compare source vs destination: `cmp` the two device paths, or
    `sha256sum` a fixed prefix (e.g. first 4 GiB:
    `dd if=<src> bs=1M count=4096 | sha256sum` vs the same on `/dev/mapper/3<wwid>`), **and**
    sanity-check the array LDEV's `numOfUsedBlock` is in the GiB range, not ~132 MiB.
  - For a boot disk, also `fsck`/mount the destination's root + ESP, or boot the guest.
  - **STOP-gate:** any mismatch (or `numOfUsedBlock` far below the source's allocated size)
    = a truncated copy — do **not** treat as "guest won't boot."

  > **Why this gate exists (incident 2026-06-20):** a `qm clone --full` (Ceph RBD) + `qm
  > move-disk` onto `e590h-test` delivered only **132 MiB** of a ~2.1 GiB openSUSE image
  > (ESP + root were zeros); the guest dropped to GRUB rescue and the failure masqueraded as
  > a boot/UEFI/network problem for a long time. A direct `qemu-img convert rbd:<src> ->
  > /dev/mapper/<LUN>` wrote the full image correctly, proving the **plugin** stores writes
  > intact — the loss was in the Ceph clone/flatten pipeline upstream. This gate catches such
  > truncation immediately, regardless of where it originates.

### Phase G — Advanced services (optional / time-permitting)
- G1. **QoS:** set `qos_upper_iops`, allocate, confirm the cap appears on the LDEV and is
  enforced (IC §5.1).
- G2. **Multi-controller failover:** with both GUM IPs configured, drop CTL1's management
  IP mid-operation; op completes via CTL2 (IC §1.1–1.3). *Coordinate with S6.*
- G3. **Zero-page reclaim:** enable `discard_zero_page`, deactivate a volume, confirm pool
  usage drops (IC §5.3).
- G4. **Replication:** likely **N/A** (needs a second array / Ops Center CM); record
  whether the embedded GUM exposes the remote-copy resources at all (IC §5.2).
- G5. **Concurrent registry lock:** allocate from both SAN nodes simultaneously; entry
  count == allocation count, no lost updates (IC §6.2).

### Phase H — Teardown & verification
- H1. Remove all test guests and disks; `pvesm free` any strays.
- H2. **Read-only** orphan scan (S2): `hitachiblock-repl orphans` (NO `--auto-cleanup`);
  confirm only test LDEVs (inside `LDEV_RANGE`) ever appeared, production LUNs never listed.
- H3. Confirm `PVE_<host>` host groups / `wwids` whitelist cleaned up; pool-0 usage back to
  the A3 baseline; remove the `storage.cfg` stanza if ending the campaign.

---

## 5. Sign-off & results log

Record per the convention in [`t/integration/README.md`](../t/integration/README.md):
**date, DKCMAIN/microcode version, PVE version, and per-phase pass/fail with deviations.**
Save results in `t/integration/` (e.g. `t/integration/e590h-<date>.md`). Until the
**size-unit gate (C2 / IC §2.1)** and **clone gate (E2 / IC §4.2)** pass, treat exact
sizing and clone space-efficiency as unverified.

| Phase | Result | Microcode / PVE | Notes / deviations |
|-------|--------|-----------------|--------------------|
| A Discovery | | | |
| B Install/register | | | |
| C Core provisioning | | | |
| D PVE acceptance | | | |
| E Snapshots/clones | | | |
| F Migration | | | |
| G Advanced | | | |
| H Teardown | | | |
```
