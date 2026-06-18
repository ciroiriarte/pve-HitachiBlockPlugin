# VSP Concepts Extract (for the PVE HitachiBlockPlugin)

**IMPORTANT — source document note.** The PDF that was provided
(`reference/8636a7c4b11896ed23329d361ca9a8d9723d6ff485cdd3b9d6b6841ead8a60b3_optim.pdf`)
is **not** the "5000 Series Virtual Storage Platform User Guide". It is the
**Hitachi VSP 5000 / E series / G/F series — REST API Reference Guide**
(MK-98RD9014-21, SVOS RF 9, November 2023). The API *syntax* is covered by a
separate API extract, but this document's chapter **Overview / Workflow /
"Getting information"** sections contain substantial **conceptual** material
that directly answers the open implementation questions (Thin Image
clone/snapshot semantics, LDEV label length, NAA/WWID layout, host
groups/modes, pools, QoS, ALUA/redundancy). This extract pulls that conceptual
content. It explicitly applies to the **VSP E series** (firmware 93-07-22+),
which is our target (E590H).

Page numbers below are **PDF page indices** (they equal the printed page
numbers in this document — front-matter cover/copyright are PDF pages 1–3, and
printed page *N* == PDF page *N*).

Where a specific number/limit is not stated in this document, that is noted
explicitly; some hard maxima (max LDEVs, max pools, max snapshots-per-volume)
live in the *Provisioning Guide* / *Thin Image User Guide*, which this document
repeatedly defers to and are **not** quantified here.

---

## 1. Dynamic Provisioning (DP) pools / HDP

(Chapter 7 "Pool management", pp. 397–415)

- **A pool is a virtual area created by integrating multiple LDEVs** (the
  "pool volumes" / "LDEV (pool volumes)"). You create **virtual volumes** from
  a pool and then allocate/pair them. A virtual volume can have a capacity
  **larger than the physical drives** (thin provisioning); it can be expanded
  or reduced. Data is striped across multiple pool drives. (p. 397)
- **Pool types** created/managed via REST (p. 398, p. 403 `poolType`):
  - `HDP` — HDP pool (Dynamic Provisioning, thin)
  - `HDT` — HDT pool (Dynamic Tiering)
  - `RT` — active flash pool
  - `DM` — Data Direct Mapping HDP pool
  - In this manual, **HDP and HDT pools are collectively "DP pools"**. There are
    also **Thin Image pools** used to store snapshot data (Thin Image snapshot
    data can also be stored in an HDP pool). (p. 397–398)
- **Pool operations** available: create, change settings (incl. change HDP→HDT,
  change usage-rate threshold, change virtual-volume subscription limit),
  expand (add LDEVs), shrink (remove LDEVs), restore (unblock after failure),
  performance monitoring, tier relocation, delete. (p. 398)

### Pool capacity reporting (`GET .../pools`, pp. 401–415)
Key attributes for a DP pool (p. 403–404):
- `poolStatus`: `POLN` (Normal), `POLF` (overflow over threshold / Pool Full),
  `POLS` (overflow + suspended), `POLE` (failure — pool info cannot be obtained).
- `usedCapacityRate` (%) logical; `usedPhysicalCapacityRate` (%) physical.
- `availableVolumeCapacity` (MB, logical free); `totalPoolCapacity` (MB,
  logical total).
- `availablePhysicalVolumeCapacity` / `totalPhysicalCapacity` (MB physical;
  **for these two, 1 MB = 1024² bytes**). (p. 403)
- `numOfLdevs`, `firstLdevId` — count and first LDEV number of pool volumes.
- `warningThreshold`, `depletionThreshold` (% thresholds).
- `virtualVolumeCapacityRate` — max subscription (over-provisioning) limit of a
  virtual volume relative to pool capacity; `-1` = unlimited (and `-1` is also
  output as "invalid" for VSP G/F midrange). (p. 404)
- `locatedVolumeCount` / `totalLocatedCapacity` — DP volumes mapped to the pool.
- `snapshotCount` / `snapshotUsedCapacity` — Thin Image snapshot data mapped to
  the pool. (p. 404)
- `blockingMode` (p. 405): behaviour when pool is full / pool-vol blocked — `PF`
  (Pool Full), `PB` (Pool vol Blockade), `FB` (Full or Blockade), `NB`
  (No Blocking — R/W still possible).
- Data-reduction / efficiency attributes: `dataReductionRate`,
  `compressionRate`, `duplicationRate`, `dataReductionCapacity` (in **blocks**),
  `capacitiesExcludingSystemData.{usedVirtualVolumeCapacity, compressedCapacity,
  dedupedCapacity, reclaimedCapacity, ...}` (all in **blocks**). (pp. 410–415)

### Zero-page reclaim / discard
- **"Reclaiming zero pages of a DP volume"** is a first-class operation
  (TOC p. 247; API `POST .../ldevs/{id}/actions/discard-zero-page/invoke` per
  the API extract). The LDEV `operationType` value **`ZPD` = "Pages are being
  released"** confirms zero-page reclaim is the mechanism. (LDEV attr table
  p. 196, p. 199, p. 204)
- LDEV attribute **`ESE`** = "Virtual volume capable of page release by the
  **User Directed Space Release** function" — i.e. host-driven UNMAP/discard
  support is a per-volume attribute. (p. 195, p. 203)

---

## 2. LDEV / virtual volumes (DP-VOLs)

(Chapter 5 "Volume allocation", pp. 177–250)

### What an LDEV is / how identified
- An **LDEV** is the logical device. A **basic volume** is an LDEV created from
  a parity group; a **virtual volume (DP-VOL)** is an LDEV created from a pool.
  Thin Image S-VOLs are "virtual volume for Thin Image" (also a DP-VOL). (p. 178,
  p. 221)
- LDEVs are identified by **`ldevId`** — an integer, specified as a **decimal
  (base-10) number** in the API. (p. 219, `GET .../ldevs/{ldevId}`)
- There is also a **`virtualLdevId`** (virtual LDEV number, used by virtual
  storage machines / GAD). If unset → `65534` (FF:FE); GAD-reserved → `65535`
  (FF:FF). (pp. 193, 197, 201)
- `ssid` (subsystem ID) is output only if set (e.g. `"0012"`). (p. 192, p. 196)

### ldevId numbering / ranges (capacity & count limits)
- **`GET .../ldevs` returns 100 LDEVs by default**, up to **16,384 LDEVs** via
  the `count` parameter (`count` valid range **1–16384**). To enumerate **more
  than 16,384** (i.e. 16,385+) LDEVs, page with `headLdevId` + `ldevOption`/
  `poolId`. (pp. 186, 187)
- On **create** (`POST .../ldevs`), if `ldevId` is omitted the **minimum unused
  LDEV number** is auto-assigned; you can constrain the auto-assignment range
  with `startLdevId`/`endLdevId`. (pp. 222–223)
- The document does **not** state the absolute maximum LDEV count for the box
  (deferred to the Provisioning Guide). The 16,384 figure is an *API paging*
  granularity, not the device maximum.

### Capacity / granularity
- Capacity can be specified on create as `byteFormatCapacity` (units `T/G/M/K`,
  or `"all"`) **or** `blockCapacity` (in **blocks; 1 block = 512 bytes**).
  Example: 1 GB = `blockCapacity 2097152`. (p. 226)
- Logical capacity conventions (front matter, pp. 18–19): 1 block = 512 bytes;
  OPEN-V cylinder = 960 KB; logical KB/MB/GB = base-2 (1024ⁿ). Physical
  capacity units are base-10 (1000ⁿ). (pp. 18–19)

### LDEV label / name and MAXIMUM LENGTH  ★ (resolves open question)
- The LDEV has a **`label`** attribute ("Label of the LDEV"). (p. 196, p. 199,
  p. 204)
- **The label maximum length is 32 characters.** Set via
  `PATCH .../ldevs/{id}` "Changing the volume settings":
  > **`label`** (string, optional): "Specify a label consisting of **0 to 32
  > characters**." (p. 235)
- **Allowed characters** for the label (p. 235):
  - Alphanumeric characters.
  - Symbols: `! # $ % & ' ( ) + , - . : = @ [ ] ^ _ ` { } ~ / \`
  - A hyphen `-` **may** be the first character.
  - Spaces allowed, but **the label cannot start or end with a space**.
  - (Note: this is the LDEV-label rule. The *host-group name* rule is different —
    see §4.)
- Example real-world label seen in sample output: `"JH-26216_DP"`,
  `"REST_API_10GVolume"`. (pp. 192, 234)

### LDEV `attributes` (type tags) of interest (pp. 195, 199, 203)
`HDP` (HDP / DP volume), `HDT` (HDT volume), `VVOL` (virtual volume),
`HTI` (**Thin Image** volume, P-VOL or S-VOL), `MRCF` (ShadowImage),
`HORC` (TrueCopy/UR), `GAD` (global-active device), `POOL`, `CMD` (command
device), `CVS`, `DRS` (data-reduction shared volume), `ESE` (User-Directed
Space Release capable), `T10PI`. `emulationType` for OPEN systems is typically
`OPEN-V` / `OPEN-V-CVS`.

### LDEV status / operation states (pp. 196, 199)
- `status`: `NML` (normal), `BLK` (blocked), `BSY` (changing), `Unknown`.
- `operationType` in-progress states: `FMT`/`QFMT` (formatting), `SHRD`
  (shredding), **`ZPD` (zero pages being released)**, `SHRPL` (pool deletion),
  `RLC`/`RBL` (pool reallocation/rebalance), etc.

---

## 3. Thin Image — snapshots & clones  ★ (resolves the central open question)

(Chapter 10 "Managing Thin Image pairs", pp. 564–636)

### Model overview (pp. 564–566)
- **Thin Image creates a copy of a primary volume (P-VOL) by storing only the
  differential data** for the P-VOL. The naming in this manual: "Thin Image
  (CAW/CoW)" and "Thin Image Advanced" are both called "Thin Image". For our
  target this is the **copy-on-write / copy-after-write** snapshot mechanism.
  (p. 564)
- On P-VOL update, **differential data is stored in a Thin Image pool or an HDP
  pool as snapshot data**. (p. 565)
- **A Thin Image pair can be created WITHOUT a secondary volume (S-VOL).** In
  that case only snapshot data exists; the P-VOL can be restored from it, and an
  S-VOL can be **allocated later** when read access to the snapshot is needed.
  (pp. 565, 568)
- **A Thin Image pair WITH a secondary volume:** the S-VOL presents a view of
  the P-VOL as of the snapshot time. The S-VOL is "Reference available" — it
  **shares blocks with the P-VOL via the pool** (it is not a full copy). (p. 566)
- To store snapshot data you create a Thin Image pair where the **P-VOL is an
  LDEV or a DP volume** and the **S-VOL is a "virtual volume for Thin Image" or a
  DP volume**. Pairs can be registered to a **snapshot group** or a
  **consistency group (CTG)** so operations apply per-group; with a CTG the
  snapshot is crash-consistent across all P-VOLs in that group. (p. 566)
- **Cascade**: you can create a Thin Image pair *for another Thin Image pair*
  (snapshot tree / cascade). (p. 566)
- **Clone**: "You can also create a **clone** of a Thin Image pair (but you
  cannot create a clone for **Thin Image Advanced**) and use the created clone as
  **DP volumes**." (p. 566) — i.e. cloning is supported on classic Thin Image
  (CAW/CoW), and the clone result is an independent DP volume.

### Snapshot vs. CoW-clone vs. auto-split — verdict for our "linked clone" approach  ★
The **`isClone` / `autoSplit` / `canCascade`** attributes of *Create pair*
(`POST .../snapshots`, pp. 603–607) are the key:

- **`autoSplit`** (bool, default false): "Specify whether the Thin Image pair is
  to be **split after it is created**. `true`: the pair is split and **snapshot
  data is stored**." A split pair (status **PSUS**) gives an S-VOL that is
  **R/W-accessible and keeps sharing unchanged blocks with the P-VOL through the
  pool** — this is the persistent **copy-on-write thin clone** behaviour.
  *You cannot set `autoSplit=true` together with `isClone=true`.* (p. 605)
- **`isClone`** (bool, default false): "Specify whether to create a pair that has
  the **clone attribute**." When the clone attribute is set, **after ALL P-VOL
  data is copied to the S-VOL, the pair is deleted** (see "Cloning", p. 569 and
  pp. 632–636) — i.e. `isClone` produces an **independent full copy** (a real
  clone, not a space-sharing snapshot), and the relationship is then torn down.
  Requires `canCascade=true`, the S-VOL must be a **DP volume**, and you **cannot
  use `isClone` for Thin Image Advanced**. (pp. 604–606)
- **`canCascade`** (bool): the pair can be cascaded (snapshot tree). Defaults to
  the same value as `isClone`. Required `true` when `isClone=true`. Also must be
  `true` if `snapshotPoolId` points at the pool of a data-reduction shared
  volume. **Thin Image (CAW/CoW) and Thin Image Advanced pairs cannot coexist in
  the same snapshot tree.** (p. 606)
- `clonesAutomation` / `copySpeed` (`slower`/`medium`/`faster`, default
  `medium`): clone the pair automatically after creation, at a chosen speed.
  (pp. 606–607)
- `muNumber` (MU number of the P-VOL): **range 0–1023**; if omitted an available
  MU is assigned. This is the per-P-VOL snapshot/mirror slot. (p. 607, p. 611)

**Conclusion for the plugin's "linked clone without auto-split":** A
**copy-on-write thin clone that persists and keeps sharing blocks with the
P-VOL is valid and is exactly what a *split Thin Image pair with an S-VOL*
gives you** — create the pair with `isClone=false` (and, if you want it split
immediately so it is host-readable, `autoSplit=true`; once `autoSplit=true` you
**must not** set `isClone=true`). The S-VOL persists in **PSUS** as an
independent addressable LDEV that only consumes pool space for divergent
blocks. **`isClone=true` is the opposite of what we want** — it forces a full
background copy and then **auto-deletes the pair**, yielding a standalone DP
volume (a true clone), not a space-sharing linked clone. So: for linked clones,
do **not** set the clone attribute; rely on the split-snapshot S-VOL semantics.
(Synthesised from pp. 566, 569, 604–607, 632–636.)

### Pair status (Thin Image) (pp. 569–574)
State machine: `SMPL` (unpaired) → `COPY` (creating) → `PAIR`/`PFUL` (paired;
PFUL = pool threshold exceeded) → split → `PSUS`/`PFUS` (split; snapshot data
stored). `RCPY` = restore in progress. `PSUE` = suspended (failure).
`SMPP` = pair deleted, differential data being deleted. For cloning the path is
`PAIR` → `PSUP` (pair being split / "Cloning") → ... → `SMPP` (pair deleted
after clone completes). (pp. 570–573)

**Access during status** (critical for the plugin — when is the S-VOL usable):
- `PAIR`: P-VOL **R/W enabled**, S-VOL **not** enabled (cannot read the S-VOL).
- `PSUS`/`PFUS` (split): **both P-VOL and S-VOL R/W enabled** ← the usable
  linked-clone state.
- `COPY`, `RCPY`, `PSUE`, `SMPP`: S-VOL **not** R/W enabled. (pp. 570–574)

### Other Thin Image operations & limits
- **Create pair** in a **snapshot group**; if the group name is new it is
  auto-created. `snapshotGroupName`: **1–32 characters, case sensitive**.
  `snapshotPoolId`: ID of a Thin Image pool or HDP pool (≥ 0). `pvolLdevId`:
  P-VOL LDEV (≥ 0). `svolLdevId`: optional — if omitted, a pair **without an
  S-VOL** is created. `isConsistencyGroup` selects CTG mode. (pp. 603–605)
- **Store snapshot data** = split the pair (`.../snapshots/{id}/actions/split`).
  Resync deletes old snapshot data; restore copies S-VOL→P-VOL (`RCPY`). Assign/
  unassign an S-VOL to existing snapshot data is supported. (pp. 567–568, 611)
- **Cloning a pair** (`.../snapshots/{id}/actions/clone`, pp. 634–636) — needs
  `pvolLdevId` + `muNumber` (0–1023); optional `copySpeed`. **Not available for
  Thin Image Advanced.** Cloning a whole snapshot group is also supported
  (pp. 632–633).
- **Snapshot-tree maintenance:** delete all pairs in a snapshot tree
  (`/services/snapshot-tree/actions/delete`), and **delete garbage data /
  defragment** the snapshot data area (`.../delete-garbage-data`, VSP 5000 only;
  auto-stops when remaining garbage < 1 GB). (pp. 628–631)
- **Pool dependency:** snapshot data lives in a **Thin Image pool or an HDP
  pool**; pool `suspendSnapshot=true` means Thin Image pairs are suspended when
  the pool depletion threshold is exceeded. (pool attr, p. 404)
- **Maximum snapshots/clones per volume:** **NOT stated in this document**
  (deferred to the Thin Image / Thin Image Advanced User Guide). The only hard
  numeric per-P-VOL limit given is the **MU-number range 0–1023** (p. 607).

---

## 4. Host groups, host modes, LUN paths, FC ports

(Chapter 5, pp. 274–336)

### Host group → WWN → LUN mapping model (pp. 177–178)
- **Volume allocation = (1) create LDEV, (2) configure a port's host group (or
  iSCSI target) and register the host's WWN(s) there, (3) set the LU path
  between the LDEV and the host group/target.** Setting the LU path is what makes
  the LDEV accessible to the host. (p. 177)
- A **host group** maps one or more **host WWNs** on a **port** to LDEVs via LU
  paths. **Registering multiple WWNs in one host group applies the same LUN
  mapping to multiple hosts simultaneously.** (p. 178, figure)

### Host group object (`GET .../host-groups/{portId},{hgNum}`, pp. 282–285)
- Object ID = `portId,hostGroupNumber` (e.g. `CL1-A,0`). Attributes: `portId`,
  `hostGroupNumber`, `hostGroupName`, `hostMode`, `hostModeOptions` (int[]).
- For iSCSI targets, the same object also carries `iscsiName`,
  `authenticationMode` (`CHAP`/`NONE`/`BOTH`), `iscsiTargetDirection`.
- **Host-group name length differs from LDEV label:** `GET .../ldevs` only
  returns host-group names **≤ 16 characters**; to get longer names use the
  host-group API. (p. 194)

### Host modes & host mode options (`GET .../supported-host-modes`, pp. 285–290)
- Each host mode has `hostModeId`, `hostModeName`, `hostModeDisplay` (the value
  used to set it). **Examples returned: id 0 → `"Standard"` → display
  `"LINUX/IRIX"`; id 1 → "(Deprecated) VMware" → `"VMWARE"`.** (p. 286)
- **Settable `hostMode` values** (Create / Change host group, pp. 290, 292):
  `HP-UX, SOLARIS, AIX, WIN, LINUX/IRIX, TRU64, OVMS, NETWARE, VMWARE,
  VMWARE_EX, WIN_EX`. **If `hostMode` is omitted, `LINUX/IRIX` is the
  default.** → For our Linux/PVE FC hosts, use host mode **`LINUX/IRIX`**.
- **Host mode options** are a separate int[] (e.g. `[12,33]`, or `2` = "VERITAS
  Database Edition/Advanced Cluster", `6` = "TPRLO"); set with `-1` to reset.
  Specific recommended numbers are deferred to the Provisioning Guide.
  (pp. 286, 292)

### Creating a host group (`POST .../host-groups`, pp. 287–290)
- `portId` (required), `hostGroupNumber` (optional, **0–254**, auto-assigned if
  omitted; for iSCSI ports this number is the "target ID"), `hostGroupName`
  (required), `hostMode`, `hostModeOptions`, `isQuickCreating`.
- **Host-group name rule:** **1 to 64 characters** (iSCSI target name: 1–32).
  Allowed: alphanumeric + symbols `. @ _ : -`; the name **cannot start with a
  hyphen**; names must be unique per port. (p. 289)
  - Note: this 1–64 char host-group-name rule is **distinct** from the 0–32 char
    LDEV-label rule in §2.

### WWN registration (pp. 295–300)
- `GET .../host-wwns` returns per-host-group WWN entries: `hostWwnId` (object ID,
  format `portId,hostGroupNumber,hostWwn` e.g. `CL1-A,0,000000102cceccc9`),
  `portId`, `hostGroupNumber`, `hostGroupName`, **`hostWwn`** (the HBA WWN, no
  colons), `wwnNickname`. (pp. 296–297)
- **Register a WWN** (`POST .../host-wwns`): `hostWwn` is a **16-character
  hexadecimal** value (colons `:` allowed as separators), plus `portId` +
  `hostGroupNumber`. Example body `{"hostWwn":"210003e08b0256f9", ...}`. (p. 300)

### LU paths (`GET/POST/DELETE .../luns`, pp. 323–336)
- LU path object: `lunId` = `portId,hostGroupNumber,lun` (e.g. `CL1-A,1,1`).
  Attributes: `portId`, `hostGroupNumber`, **`lun`** (the LUN between the host
  group and the mapped LDEV), `ldevId`, `hostMode`, `isCommandDevice`,
  `luHostReserve` (SCSI reservation state: openSystem/persistent/pgrKey/
  mainframe/acaReserve). (pp. 325, 329)
- **Set LU path** (`POST .../luns`, pp. 332–333):
  - Single port: `portId` + `hostGroupNumber` + `ldevId` (+ optional `lun`).
  - **Multi-port (for multipath/redundancy):** specify **`portIds` (array, up to
    6 ports)** to set the LU path on **several ports at once**. (p. 333)
  - `lun` is optional; if omitted it is auto-assigned. **You cannot reuse the
    same LUN for multiple LDEVs in the same host group**, and **an LDEV cannot be
    mapped to more than one LUN in the same host group**. (p. 333)
- A single LDEV is typically mapped through **two ports** (e.g. `CL1-A` and
  `CL2-A`, one per controller) — see the sample volume output `numOfPorts: 2`
  with ports on `CL1-A` and `CL2-A`. (p. 191, p. 220) This is the basis for FC
  multipath / controller redundancy.

---

## 5. WWN / LU identification / NAA (page-83)  ★ (resolves open question)

(p. 220, "Getting information about a specific volume")

- The per-LDEV API `GET .../ldevs/{ldevId}` returns an extra attribute beyond
  the generic volume info:
  - **`naaId`** (string): "The **NAA ID** of the volume whose LU path was
    specified is output." (p. 220)
- **Observed example value:** `"naaId": "60060e8006cf2e000000cf2e00000000"`
  (32 hex chars = 16 bytes, i.e. an **NAA IEEE Registered Extended, type 6**
  identifier — leading nibble `6`). (p. 220)
- **Byte-layout interpretation** (derived from the example; the document gives
  the value but does **not** spell out the field breakdown):
  - `6` — NAA type 6 (IEEE Registered Extended).
  - `0060e8` — Hitachi IEEE company OUI (00:60:E8).
  - Remaining bytes encode a **vendor-specific identifier derived from the
    storage serial number and the LDEV number**. In the example the serial-ish
    field `cf2e` (= 53038 dec) and the LDEV field `cf2e` repeat — consistent with
    Hitachi's scheme of embedding the array serial and the LDEV id. The exact
    bit-packing is **not documented in this PDF**; treat `naaId` as the
    authoritative device identifier and read it from the API rather than
    computing it.
- For **external (virtualized) volumes**, the SCSI device identity is exposed
  separately as `externalVolumeId` (hex) / `externalVolumeIdString` (ASCII),
  with `externalVendorId` / `externalProductId`. (p. 200)
- Practical takeaway for the plugin: the **NAA/WWID the Linux host sees
  (`/dev/disk/by-id/wwn-0x...` / scsi_id page-83)** is the `naaId` returned per
  LDEV — use it to correlate the host device to the storage LDEV after the LU
  path is set.

---

## 6. Controllers / redundancy / ALUA / path failover

- **Dual-controller architecture:** the management agent **GUM (Gateway for
  Unified Management) exists in each controller, CTL1 and CTL2** (VSP E series /
  G/F midrange). I/O survives a controller outage because volumes are mapped
  through ports on **both** controllers (see §4 multi-port LU paths). (p. 20)
- **MP blade / ownership:** each LDEV/journal has an `mpBladeId` (the owning
  microprocessor blade); it can be reassigned. (LDEV attr `mpBladeId`, p. 196;
  "Changing the MP blade assigned to a volume", TOC p. 249.)
- **ALUA (Asymmetric Logical Unit Access):**
  - Per-LDEV flag **`isAluaEnabled`** (true/false). Set it on a volume used for a
    **global-active device in a cross-path FC configuration**. (LDEV attr p. 197;
    change-volume-settings p. 239.)
  - Per LU path, querying with `lunOption=ALUA` returns `isAluaEnabled` and
    **`asymmetricAccessState`** = **`Active/Optimized` (higher priority)**,
    **`Active/Non-Optimized` (lower priority)**, or `Not Supported`. (pp. 326,
    327)
  - **Set the ALUA path priority** with
    `POST .../services/lun-service/actions/change-asymmetric-access-state/invoke`
    (`portId` + `hostGroupNumber` + `asymmetricAccessState`
    `Active/Optimized`|`Active/Non-Optimized`). This sets the priority levels of
    paths between a host and the storage system for a GAD cross-path FC config.
    (pp. 334–335)
- Note: full ALUA/optimized-path semantics for a single (non-GAD) E-series box
  are not elaborated in this API doc; the plugin should still rely on Linux
  `multipath`/ALUA path grouping using the two controller ports.

---

## 7. QoS — per-LDEV I/O control

(Chapter 8, "Configuring QoS settings for a volume",
`POST .../ldevs/{ldevId}/actions/set-qos/invoke`, pp. 495–500)

- **QoS controls I/O between a host and a volume**, and is configured **per
  volume (per LDEV)**, only for volumes **directly connected to the host**.
  **You may set only ONE attribute per API call.** (p. 495–496)
- Limits / attributes (pp. 496–499):
  - **`upperIops`** — upper IOPS limit; range **100–2,147,483,647**; `0`
    disables. If `lowerIops` is set, `upperIops` must be greater.
  - **`upperTransferRate`** — upper throughput (MB/s); range **1–2,097,151**;
    `0` disables.
  - **`upperAlertAllowableTime`** — seconds (1–600) to wait before alerting on
    upper-limit breach; needs an upper limit set; `0` disables.
  - **`lowerIops`** — lower IOPS limit; range **10–2,147,483,647**; `0`
    disables. **Available on VSP E series / G/F midrange.**
  - **`lowerTransferRate`** — lower throughput (MB/s); range **1–2,097,151**;
    `0` disables. **Available on VSP E series / G/F midrange.**
  - **`lowerAlertAllowableTime`** — seconds (1–600); E-series/midrange.
  - **`responsePriority`** — I/O priority **1–3** (higher = higher priority;
    sets a target response time); `0` disables. E-series/midrange.
  - **`responseAlertAllowableTime`** — seconds (1–600); E-series/midrange.
- **Read back QoS performance** per LDEV: `GET .../qos-monitor-ldevs/{ldevId}`
  returns `iops`, `transferRate`, `responseTime`, `receivedCommands`,
  `monitorTime` (1-second averages). (p. 500)
- QoS settings can also be added to `GET .../ldevs` output via
  `detailInfoType=qos`. (p. 190)
- **Server Priority Manager** and **QoS groups** are separate, related
  mechanisms (TOC pp. 501–512; Appendix C QoS-group ops pp. 1244–1250) — not
  detailed here.

---

## 8. Capacity units & system limits (as stated in this document)

- **1 block = 512 bytes**; many capacity attributes are in **blocks** or **MB**.
  For pool *physical* capacity, **1 MB = 1024² bytes**. Logical capacity uses
  base-2 KB/MB/GB; physical drive capacity uses base-10. (pp. 18–19, 403)
- **Storage-system total capacity:** `GET .../total-capacities/instance` returns
  `internal`/`external`/`total` each with `freeSpace` and `totalCapacity` in
  **KB**. Note: these exclude unusable boundary areas, so the value can change
  after create/delete. (pp. 178–180)
- **Total efficiency:** `GET .../total-efficiencies/instance` returns
  `totalRatio`, `compressionRatio`, `snapshotRatio`, `provisioningRate` (DP
  thin-provisioning saving %), plus `dedupeAndCompression` / `acceleratedCompression`
  breakdowns. After a volume is created from a pool but before data is written,
  `totalRatio` shows the max value `92233720368547758.07`. (pp. 181–184)
- **LDEV enumeration:** default 100, max **16,384** per `count`; page beyond with
  `headLdevId`. (pp. 186–187)
- **MU number per Thin Image P-VOL:** **0–1023**. (p. 607)
- **Host group number:** **0–254** per port. (p. 288)
- **LU path multi-port set:** up to **6 ports** at once. (p. 333)
- **NOT stated in this document** (deferred to Provisioning / Thin Image
  Guides): absolute **maximum number of LDEVs**, **maximum number of pools**,
  **maximum pool capacity**, **DP page/allocation granularity (42 MB)**, and
  **maximum snapshots/clones per volume**. Do not invent these — look them up in
  the VSP E series Provisioning Guide / Thin Image User Guide if needed.
