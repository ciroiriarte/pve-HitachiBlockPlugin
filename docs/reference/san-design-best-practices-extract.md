# Brocade SAN Design & Best Practices — extract for this project

Distilled from the **Broadcom *SAN Design and Best Practices — Brocade Fibre Channel
Platforms*** Design Guide (`53-1004781-07`, Nov 18 2025). Only the guidance that affects
**this plugin's design decisions and FC bring-up/testing** is kept; cites are to that guide.

## Why this is here (scope)

The plugin provisions LUNs on a Hitachi array and drives Linux multipath; it does not design
the SAN. But its **data path** rides a Brocade FC fabric, and several design/monitoring rules
directly shape how we **zone, map LUNs, choose target ports, and diagnose path problems**
during testing. This complements:
- [`fos-rest-api-extract.md`](fos-rest-api-extract.md) — *how* to zone via the FOS REST API;
- [`prerequisites.md`](../prerequisites.md) §4 (FC) and the [test plan](../test-plan.md) — the
  bring-up steps this informs.

---

## 1. Fabric redundancy & MPIO (Ch 4.3) — validates our multipath design

Best practice = **two completely separate mirrored fabrics (A/B)** sharing no components, with
hosts and storage **dual-attached to both** and **MPIO** doing active/active or active/passive
failover; identical switch platforms in each fabric (pp. 18–19). This is exactly the
plugin's assumption: redundant target ports across controllers, Linux `multipath` over all
paths, and the active-node-only LUN-mapping model. Implications:
- Configure `target_ports` with **at least one port per fabric** (one per controller/CHA).
- The shipped `multipath.conf.d/hitachiblock-vsp.conf` ALUA stanza is what turns those paths
  into a single `dm-multipath` device — verify it matches the array `INQUIRY` strings
  (IC §3.4).

## 2. Zoning best practices (Ch 15.1) — the *why* behind the FOS zoning recipe

- **Single-initiator, single-target zones** are the baseline: a zone change only RSCNs the
  devices in that zone, so one flaky HBA can't disrupt others, and the zone DB stays sane
  (p57). → one zone per PVE-node-HBA per fabric, paired with the array target port(s).
- **Default zoning = `No Access`** (disabled default zone) is recommended (p57). With an
  effective cfg active, unzoned devices can't see each other — which is why our nodes show up
  in the name server yet see no LUNs until zoned.
- **Define zones by device PWWN**, not switch port (p57) — a device keeps its zone if it moves
  ports. (The FOS extract's examples use WWPNs for this reason.)
- **Peer zoning (15.1.1)** scales single-initiator semantics: one *principal* (the storage
  target port) + many *non-principals* (initiators); non-principals talk only to the principal,
  never each other. Smaller DB and easier management than N discrete zones, at the cost of more
  RSCN traffic. → a clean option for zoning several PVE nodes to one array port.
- **Target-driven zoning (15.1.2)** is peer zoning defined by the *array* via a third-party
  interface — only if the Hitachi side supports it; otherwise drive zoning from the switch
  (our approach).
- **Duplicate WWNs (15.1.3):** virtualized initiators (NPIV / virtual HBAs, VMware-style) can
  transiently present duplicate WWNs → unpredictable name-server answers and a RASLog warning
  (it's a recovery, not prevention, mechanism). Mitigation set: *always enable zoning, use
  peer/single-initiator zoning, define zones by PWWN, set default zoning to No Access.* Relevant
  if PVE ever fronts VMs with virtual HBAs; our nodes use **physical** HBAs, so not a concern today.

## 3. Fan-in / oversubscription (Ch 5, 8.7) — affects LUN/port placement & cluster polling

- **Fan-in ≤ 10:1** (initiators per target port) for transaction-based workloads (p36). Keep an
  eye on how many node HBAs share each array target port.
- **VMs change the math:** many low-bandwidth VM disks can oversubscribe a target port more than
  physical servers do; spread LUNs across array ports/pools, and put a few high-capacity hosts
  per storage port rather than many (p25).
- **⚠️ Cluster caveat (8.7, "Clusters"):** *"A cluster inundating a fabric and storage array with
  LUN status queries and other requests can cause fabric congestion and stress array
  controllers."* This is **directly about a PVE cluster** — every node periodically runs the
  plugin's `status()`/`list_images()` against the array. Design consequences to respect:
  - keep REST polling lean (session reuse, avoid per-volume hammering on `status`);
  - the active-node-only LUN-mapping model already limits per-port LUN counts and logins;
  - watch array controller load during the multi-node concurrency tests (test plan G5).
- **Isolate initiator vs target ports** (separate switches/where possible) so a misbehaving host
  port is easier to fence than a storage port that serves everyone (p35–36).

## 4. Monitoring & diagnostics to use during bring-up (Ch 8)

Fabric-side instrumentation that helps **validate the data path and diagnose I/O problems** in
test-plan Phases C–F (use via the switch CLI/SANnav, independent of the plugin):
- **MAPS** (Monitoring and Alerting Policy Suite, 8.1.1): threshold monitoring with predefined
  conservative/moderate/aggressive policies — enable before load tests to catch CRC errors,
  congestion, and over-utilized ports early.
- **FPI + SDDQ** (8.1.2–8.1.3): auto-detect latency/slow-drain devices and quarantine the
  offending flow to a low-priority VC so it can't backpressure the fabric. Watch for this if a
  node's HBA misbehaves during testing.
- **Flow Vision / IO Insight / VM Insight** (8.1.4–8.1.6): per initiator→target→**LUN** latency,
  IOPS, first-/completion-response time, and pending-IO (≈ HBA queue depth). IO Insight is on by
  default (FOS 9.0+). → the most useful cross-check for the `fio` results in Phases C4/D4 — if
  in-guest numbers look wrong, compare against the fabric's per-LUN flow metrics to localize the
  problem (array vs fabric vs host).
- **ClearLink / D_Port (8.3.1):** offline transceiver/cable validation (power, errors, distance)
  — the fabric-side counterpart to the test plan's predeployment optics check; run on a port
  before trusting it, or when CRC errors appear.
- **FEC (8.3.3):** forward error correction, on by default at 32G/64G/128G — expect it enabled;
  its absence on a link hints at a marginal optic/cable.
- **Buffer-credit-loss recovery (8.3.4)** and **RASLog severities 1–4 / Audit log (8.3.5–8.3.6):**
  RASLog/Audit are where link flaps, credit loss, and **zoning changes** are recorded — the first
  place to look when a path drops mid-test. Audit captures who changed zoning and when (useful
  after our REST zoning edits).

## 5. Access Gateway / NPIV (Ch 14) — mostly N/A for us

Our PVE nodes attach with **physical HBAs in native fabric mode** (they appear as direct
`FCP-Initiator`s in the name server), **not** through an Access Gateway, so AG port/device
mapping does not apply. Keep in mind only if the topology changes: AG/NPIV present many virtual
F_Ports behind one physical N_Port (max **254** NPIV logins/port), don't consume a domain, and
inherit fabric zoning — and reintroduce the duplicate-WWN caution from §2.

---

## What this means for our bring-up (summary)
- Zone **single-initiator (or peer), by PWWN, one HBA↔array-port per fabric**, default **No
  Access** — execute via the [FOS REST recipe](fos-rest-api-extract.md) (blocker B4).
- Spread test LUNs across array target ports; keep fan-in modest; **keep the plugin's status
  polling lean** to avoid stressing the array controllers from a multi-node cluster.
- During the `fio` phases, watch **IO Insight / MAPS / RASLog** on the switch to localize any
  performance or path anomaly between array, fabric, and host.
- Treat **D_Port/ClearLink + FEC state** as the optics/cable pre-check before trusting a path.
