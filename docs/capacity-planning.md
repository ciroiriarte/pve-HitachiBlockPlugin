# Capacity Planning & Scalability

This plugin provisions **one array LUN (LDEV) per virtual disk** — the VMware-VVols
model, on FC. That design has hard ceilings on the array's front-end ports and on each
host's SCSI/multipath stack. This page is the single place that explains those ceilings,
the levers the plugin uses to stay under them, and how to size a cluster before you hit a
wall.

> TL;DR — the binding limits are **LU paths per front-end port** (2,048 midrange / 4,096
> high-end) and **device/path count per node** (the `sd` + `dm-multipath` explosion). The
> plugin keeps both bounded with **late binding** (per-node lever) and **port-group
> sharding** (per-port lever). Measure your live headroom with
> [`hitachiblock-repl lun-paths`](operations.md#report-lu-path-headroom).

## The unit of accounting: the LU path

A **LU path** is one `LDEV × host-group × port` binding — i.e. one way a host can reach one
LDEV through one front-end (FE) port. It is *not* the same as an LDEV or a volume:

- One LDEV mapped to one host group on **two** FC ports = **2** LU paths (the usual HA case).
- The array counts LU paths **per physical FE port**, aggregated across every host group on
  that port. This is the number that hits the cap.

### Per-port caps

| Limit | Midrange (VSP E / One Block) | High-end (VSP 5000) |
|------|------|------|
| **LU paths per FE port** | **2,048** | **4,096** |
| **Host groups per FE port** | **255** | **255** |

The plugin's tooling uses **2,048** as the default per-port LU-path budget
(`DEFAULT_LUN_PATH_BUDGET` in `bin/hitachiblock-repl`) and **255** as the host-groups/port
cap (`HOST_GROUPS_PER_PORT_CAP`); override the budget for a high-end array with
`hitachiblock-repl lun-paths --lun-path-budget 4096`.

## Per-node host-side ceiling

The array port budget is one wall; the **Linux host** is the other. The real per-node limit
is **not** `scsi_mod.max_luns` (that's a discovery filter, easily raised) — it is **device
and path explosion**:

- Each mapped LDEV becomes a `dm-multipath` device backed by one `sd` device **per path**
  (per FE port the LUN is mapped on). N volumes × P paths = N×P `sd` devices + N `dm`
  devices, each with sysfs, udev, and `multipathd` bookkeeping.
- This drives **SCSI rescan time, udev settle time, and boot-time discovery** — the
  practical pain is felt as slow `multipath -ll`, slow rescans, and longer boots long before
  any hard kernel limit.

The lever for this is the same one that protects the port budget: **map fewer LUNs per
node, simultaneously.**

## Lever 1 — Late binding (per-*node*)

The plugin maps an LDEV's LU paths **only on the node currently running the VM**, and unmaps
on stop/migrate (`activate_volume` / `deactivate_volume` →
`_map_lun_to_local` / `_unmap_lun_from_local`). On migration it maps the target first, then
unmaps the source after the move completes; concurrent mappings are reference-counted so a
shared LUN is only unmapped when the **last** node deactivates it.

Consequence — **per-node LU paths ≈ (running-VM disks on that node) × (ports in the group)**,
*not* the cluster-wide disk count:

- 3,000 VM disks across 10 nodes ≈ **300 LDEVs/node**; on a 2-port group that's ~600 LU
  paths/node — comfortably inside the per-port budget once spread (see sharding below).

**What late binding does NOT relieve:** the **per-port aggregate**. Every node whose host
group lives on a given FE port contributes its live LU paths to that port's 2,048/4,096
budget. Late binding bounds *each node*; it does not stop many nodes from piling onto the
*same port*. That is what Lever 2 is for.

## Lever 2 — Port-group sharding (per-*port*)

To keep any single FE port under budget, shard nodes across **target-port groups** so not
every node maps onto the same ports. This is tracked as a dedicated enhancement
(**[GitHub #27](https://github.com/ciroiriarte/pve-HitachiBlockPlugin/issues/27)**); the
capacity math it governs is:

```
LU paths on a port  ≈  (nodes whose group uses that port)
                       × (avg running-VM disks/node)
                       × 1            # this port contributes 1 path per mapped LDEV
```

Design rules:

- **≥ 2 ports per group (HA):** every group must span at least two FE ports so a port/SFP/
  fabric failure never severs a node's only path. So sharding trades port-budget headroom
  against the 2× path multiplier — size accordingly.
- **Zoning is a prerequisite:** a node can only use a port its HBAs are zoned to. Sharding is
  a *fabric* design as much as an array one (cross-link the optional zoning automation,
  **[GitHub #1](https://github.com/ciroiriarte/pve-HitachiBlockPlugin/issues/1)**).
- The plugin's `port_scheduler` option spreads each LDEV deterministically across the
  configured `target_ports` (see [configuration.md](configuration.md)); it does not yet do
  per-node port-group assignment (that is #27).

## Why there is no VVols/Protocol-Endpoint equivalent here

On VMware, VVols bind many virtual volumes behind a small number of **Protocol Endpoints**
(PEs) via VASA + the PSA second-level-LUN (SLLID) mechanism, so per-VM-disk does **not** mean
per-host-LUN. **Linux/Proxmox has no equivalent:**

- No VASA provider / no PSA, so there is no array-coordinated PE abstraction.
- `sd`/`dm-multipath` have no SCSI **second-level LUN** bind — every addressable LUN is a
  first-class device.

Therefore **per-disk = per-host-LUN is unavoidable** on this stack. The only levers are
*which* LUNs and *how many* are **simultaneously mapped** — exactly Levers 1 and 2. NPIV was
also considered and **rejected**: it virtualizes the *initiator* (more WWPNs), which would
multiply host groups and LU paths rather than reduce them, and adds fabric/driver complexity
without addressing the device-count ceiling. It does not provide a PE-style fan-in.

## Clones and the host data path

- **Linked clone** (`qm clone` of a template/snapshot) is **array-offloaded**: a Thin Image
  copy-on-write S-VOL that shares blocks with its source — instant, space-efficient, no host
  data movement.
- **Full clone** (`qm clone --full`) is a **host-side copy** (`qemu-img convert` offline or
  `drive-mirror` online) — the data traverses the PVE host (host CPU/IO + double SAN
  traffic). The array **cannot** offload a full clone through the PVE plugin API; this is a
  property of PVE core, not the plugin, and is recorded in
  [ADR 0002 — Full-clone offload](adr/0002-full-clone-offload.md). Prefer linked clones from
  a template for fan-out.

## Shared LUNs & SCSI-3 Persistent Reservations

A LUN shared by clustered guests (or briefly during live-migration overlap) is mapped on
**every** participating node's host group. **SCSI-3 PR is LU-wide** — a reservation applies
to the LDEV across *all* its ports/paths, not to a single port — so clustered-guest fencing
works regardless of which ports each node uses; the nodes do **not** need to share ports,
only the LDEV. Opt-in PR support for shared/clustered disks is tracked as
**[GitHub #2](https://github.com/ciroiriarte/pve-HitachiBlockPlugin/issues/2)**. Note that a
shared LUN multiplies its LU-path footprint by the number of attached nodes — account for it
explicitly in the per-port budget.

## Control-plane (management) session scaling

This is a separate ceiling from the FC data path. All control-plane calls go through the
Hitachi **Configuration Manager (CM) REST API**, which enforces a hard cap of **64
concurrent sessions, shared by every CM client** (this plugin on every node, plus Ops
Center, Storage Navigator, monitoring, the Maintenance Utility, your scripts).

**The plugin defaults to session-less auth** (HTTP basic auth per request; the array opens
and immediately releases a transient session per call), so steady-state session use is
bounded by *in-flight requests* (≈ a couple), **not** by node count. This is what makes the
1-LUN-per-disk model viable on large clusters. Setting `rest_keepalive 1` reverts to the
legacy model of **one persistent session per worker process per node**
(`O(workers × nodes × storages)` — every `pvedaemon`/`pveproxy`/`pvestatd` worker on every
node holds one, far above `nodes × storages`), which does **not** fit a 128-node cluster
against the 64-session cap. The topologies for
scaling the *legacy* model past the cap (ephemeral leases, an active-active broker, rejected
alternatives) are analysed in
[ADR 0001 — Control-plane REST session scaling](adr/0001-control-plane-session-scaling.md)
(see also **[GitHub #4](https://github.com/ciroiriarte/pve-HitachiBlockPlugin/issues/4)**).

## Measuring real headroom

Don't plan on theory alone — the plugin exposes the live counts (issue #28 tooling):

```bash
# Per-node LU-path / host-group counts with headroom vs the caps:
hitachiblock-repl lun-paths --storeid <storeid>
hitachiblock-repl lun-paths --storeid <storeid> --lun-path-budget 4096   # high-end array

# Same counts inside the full support bundle:
hitachiblock-repl diagnostics --storeid <storeid>
```

For **this node's** host group on each target port it reports the LU-path count (with
headroom vs the budget), host-groups-on-port (vs 255), the node's total mapped LU paths, any
**orphan LU paths** (mapped here but whose LDEV left the registry — a leaked unmap), and a
soft warning when a port crosses 80% of its budget. Run it per node (counts are per-node).
See [operations.md](operations.md#lu-path--host-group-accounting-and-orphan-map-reconcile).

## Worked sizing example

Target: **3,000 running VMs, ~2 disks each = 6,000 live VM disks**, on a **20-node** cluster,
midrange array (2,048 LU paths/port).

1. **Per-node LDEVs (late binding):** 6,000 / 20 ≈ **300 live LDEVs/node**.
2. **Per-node LU paths (2-port HA group):** 300 × 2 = **600 LU paths/node** — fine for the
   host stack.
3. **Per-port aggregate (no sharding):** if all 20 nodes share one 2-port group, each port
   carries 20 × 300 = **6,000 LU paths** → **2.9× over the 2,048 budget**. ❌
4. **With port-group sharding (Lever 2):** split the 20 nodes across **4 groups** of 5 nodes,
   each group on its own 2-port pair (8 FE ports total). Each port now carries 5 × 300 =
   **1,500 LU paths** → **73% of budget**, with headroom. ✅ Host groups/port = 5 (well under
   255).
5. **Verify, don't trust:** run `hitachiblock-repl lun-paths` on a representative busy node
   and confirm the per-port counts and the 80%-budget warning behave as the model predicts.

The takeaway: late binding makes *per-node* counts tractable; **port-group sharding is what
keeps the busiest FE port under its LU-path budget** as node count grows. Size the number of
port groups (and the FE ports behind them) to your `nodes × disks/VM`, keep ≥2 ports/group
for HA, and measure.

## See also

- [Architecture](architecture.md) — component design and the per-operation data flows.
- [Operations § LU-path accounting](operations.md#lu-path--host-group-accounting-and-orphan-map-reconcile)
  — the `lun-paths` / `reconcile-maps` commands.
- [Configuration](configuration.md) — `target_ports`, `port_scheduler`, `rest_keepalive`.
- [ADR 0001 — Control-plane REST session scaling](adr/0001-control-plane-session-scaling.md).
- [ADR 0002 — Full-clone offload is not possible](adr/0002-full-clone-offload.md).
