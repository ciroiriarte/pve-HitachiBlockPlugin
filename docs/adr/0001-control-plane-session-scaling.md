# ADR 0001 — Control-plane REST session scaling beyond the CM session cap

- **Status:** Proposed — **decision undecided** (options enumerated, not yet selected)
- **Date:** 2026-06-20
- **Deciders:** Ciro Iriarte
- **Tracking issue:** see the "control-plane session scaling" enhancement issue on GitHub
- **Related:** `docs/operations.md` §"REST session limits (capacity planning)",
  `docs/architecture.md`

## Context

The plugin drives all control-plane operations (create/delete/expand/label LDEVs,
host-group + LUN-path mapping, Thin Image snapshots, QoS, replication, pool/status reads)
through the Hitachi **Configuration Manager (CM) REST API** — either array-embedded
(GUM) or an Ops Center CM server. The FC **data path** (multipath I/O) is unaffected by
any of this; only the management plane is in scope.

### Current session model

Each PVE node opens **one persistent CM REST session per `hitachiblock` storage** in
`activate_storage` (`HitachiBlockPlugin.pm`: `login()` → cache in `%_clients`), keeps it
alive with periodic `keepalive` (PATCH) in `_client()`, reuses it for every control-plane
call, and `logout()`s in `deactivate_storage`. So:

```
sessions in use ≈ (nodes with the storage active) × (number of hitachiblock storages)
```

A short-lived extra session is also opened during `pvesm add/set` connectivity checks.

### The constraint

The CM REST API enforces a hard cap of **64 concurrent sessions**, **shared by every
client of that API** — this plugin on every node, plus Ops Center, Storage Navigator,
monitoring, the Maintenance Utility, and the operator's own scripts. The current 1
session/node model does not fit a **128-node** cluster (128 > 64) and leaves zero
headroom for the other CM clients.

**Goal:** a control-plane topology where a 128-node PVE cluster (with room to grow)
operates within the 64-session cap with comfortable headroom, preserving correctness
(no lost updates / allocation races), availability (no single point of failure that
blocks all provisioning), and low operational complexity for the Proxmox admin.

### Decisive insight — node-local *identity* vs node-local *execution*

These two do **not** coincide, and that is what makes the session count separable from
the node count:

| Operation | Needs node's identity (WWNs) | Must execute on the node | Needs a CM session |
|---|---|---|---|
| LDEV create/delete/expand/label | no | no | **yes** |
| QoS, snapshots, replication, pool/status | no | no | **yes** |
| Host-group create / add-WWN / map-unmap LUN **for node X** | **yes** (X's WWNs + name) | **no** | **yes** |
| FC WWN discovery on node X | yes | **yes** | no |
| SCSI rescan / multipath wait / flush / resize | no | **yes** | no |

Read the bottom two rows against the top three: **every operation that needs a CM
session can be centralized, and every operation that must run on the node needs no CM
session** (it is local sysfs/multipath shell work). Host-group/LUN mapping is only
*context*-bound, not *execution*-bound — any node or daemon can issue it on X's behalf if
it knows X's WWNs, which the plugin can publish into pmxcfs. Decoupling these is the
prerequisite for every option below.

### Existing platform constraints that any redesign must respect

- **PVE already serializes mutating ops cluster-wide per storage.** PVE core wraps
  `vdisk_alloc` / `vdisk_free` / `activate_storage` in `cluster_lock_storage()` (the
  cluster-wide `storage-<storeid>` corosync lock). Consequence: per-storage mutating
  throughput is already 1-at-a-time regardless of session topology.
- **Coordination locks must use a dedicated lock domain.** Commit `0b2f70e` moved the
  registry lock off `cfs_lock_storage($storeid)` to a dedicated
  `cfs_lock_domain("hitachiblock-registry-<storeid>")` after a live deadlock: re-acquiring
  PVE's own non-reentrant storage lock from inside alloc/free self-deadlocks. **Any
  session-lease or broker-coordination lock introduced here MUST live in its own domain**,
  never PVE's storage lock.
- **`status()` is the real scaling pressure point.** It is polled by `pvestatd` on every
  node and is **not** under the storage lock. In the current model it reuses the
  persistent session, so it costs nothing extra — but in any *ephemeral* design, naive
  per-node `status()` becomes a 128-node login storm and must be de-amplified.
- **Correctness foundation already exists.** Registry mutations and LDEV-ID allocation run
  under the dedicated registry domain lock; state replicates via `/etc/pve/priv` (pmxcfs).
  The redesign is about *who holds sessions*, not about re-solving locking.

## Decision

**Undecided.** This ADR records the problem, the constraints, and the full option set so a
choice can be made deliberately. The two finalists are **Option A (ephemeral + lease
budget)** and **Option B (active-active broker)**; the choice between them is a
complexity-vs-throughput trade-off driven by expected provisioning rate and the operator's
appetite for running an extra daemon. This ADR will be updated to "Accepted" once an
option is selected, with the rejected options moved to Consequences.

## Options considered

### Option A — Ephemeral sessions + cluster-wide lease budget

No persistent sessions. A node logs in only to perform a mutating control-plane op, then
logs out. A pmxcfs-backed **lease/semaphore in a dedicated lock domain** (e.g. budget =
16) caps concurrent logins cluster-wide regardless of node count.

- **Session math:** idle = **0**; peak plugin sessions = **16**; headroom = **64 − 16 = 48**.
- **Where logic runs:** unchanged — distributed on every node. No new daemon, no leader
  election, no RPC protocol. Best fit for PVE's "no control node" model.
- **PVE mapping:** `activate_storage` no longer logs in/keepalives; each mutating hook
  acquires a lease → login → work → logout → release. `status()` **must** be de-amplified
  (cache pool capacity in pmxcfs, refreshed by a single elected updater every 30–60 s) or
  it becomes a login storm.
- **Refinement — *lazy ephemeral*:** hold a session for a short idle grace window before
  releasing the lease, so bursts amortize login cost without holding idle sessions.
- **HA:** any node can act; lease entries need TTL/owner heartbeat so a crashed node does
  not strand capacity.
- **Cost:** higher per-op latency (login/logout). Burst contention is largely already
  bounded by PVE's own per-storage alloc serialization.

### Option B — Active-active cluster broker

2–3 small broker daemons (systemd, on fixed nodes), each holding a fixed pool of 2–4 CM
sessions. The plugin calls a broker over local RPC; brokers do all array-facing work.
Nodes keep only WWN-discovery + multipath locally.

- **Session math:** 3 brokers × 4 = **12** sessions, constant forever; headroom **52**.
- **Where logic runs:** array-facing control plane in the broker; host-side SCSI/multipath
  on the node.
- **HA:** broker list in `storage.cfg`/pmxcfs, client-side failover; brokers stateless
  except the session pool; losing one broker does not block the cluster.
- **Cost:** highest implementation + packaging complexity (daemon, RPC protocol, broker
  membership/discovery, monitoring) — the most for a Proxmox admin to operate. Per-storage
  alloc parallelism upside is limited by PVE's own serialization; the broker still wins on
  bounded session *count* and parallelism *across* storages.

### Option C — Leader/coordinator node + hot standby

One elected node owns a small session pool; others RPC to it. Simpler than active-active,
but the control plane has a **full-stop during failover** (data path unaffected). A logical
SPOF for forward progress. Workable, not preferred as primary.

### Option D — Per-node broker daemon (rejected as a standalone answer)

Pools sessions per node but does **not** solve the cap: even 1 session/node is already too
many at 128 nodes. Only useful combined with Option A's cluster-wide lease budget, at which
point it is an implementation detail of A.

### Option E — Separate Ops Center CM tier instead of embedded GUM (not a topology answer)

An infrastructure optimization. Do **not** assume it raises the effective cap; the budget
is typically still shared across all CM clients. Fine as a complement to A or B, not a
substitute for the topology redesign.

## Correctness pitfalls (apply to whichever option is chosen)

1. **LDEV-ID allocation race** — keep "choose ID → create LDEV" serialized (registry
   domain lock); prefer array auto-assign unless an explicit `ldev_range` is required. The
   explicit-range path is already fenced (`ldev_range` guard, per-CU awareness, paged
   `list_ldevs`).
2. **Concurrent host-group creation** — idempotent lookup-by-name → by-WWN → create →
   re-read, serialized per `hostgroup:<storeid>:<node>:<port>`. A broker makes "create-once"
   naturally safe.
3. **LUN map/unmap** — refcount per-volume attachments in pmxcfs; `activate_volume` =
   "ensure mapped to X" (idempotent); `deactivate_volume` unmaps only on last detach.
4. **Snapshot-group naming** — include stable uniqueness (storeid + source LDEV + epoch/
   UUID); register the chosen name before the array call if multiple writers can create CG
   snapshots concurrently.
5. **Mid-flight failure after the array accepted a mutation** — treat create/map/snapshot
   as *maybe-committed* after a transport failure; reconcile by reading array + registry
   state before retrying. Centralizing (broker) makes idempotency-key ownership easier.
6. **Keepalive vs idle expiry** — only the broker pool (or active lease holders) keepalive;
   never couple correctness to keepalive success — always be able to re-login and reconcile.

## Consequences

- **Common prerequisite (do first, independent of the option):** publish each node's FC
  WWNs into pmxcfs, and split array-facing control-plane work (centralizable, needs a
  session) from host-side SCSI/multipath work (must run on the node, needs no session).
  This is required by every option and is independently valuable.
- Once the prerequisite lands, the session count becomes independent of node count and the
  64-cap stops being a scaling ceiling.
- The choice between A and B is reversible at moderate cost: both share the
  decouple-first prerequisite and the same correctness rules, so a cluster can ship A first
  and graduate to B if throughput demands it.
- Until a decision is made, the current 1-session/node model remains and the documented
  capacity-planning guidance in `docs/operations.md` continues to apply (clusters must stay
  under the cap manually).
