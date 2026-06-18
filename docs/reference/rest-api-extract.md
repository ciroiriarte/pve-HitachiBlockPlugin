# Hitachi VSP REST API — Implementation Extract

Source: **Hitachi Virtual Storage Platform 5000 / E series / G130, G/F350, G/F370, G/F700, G/F900 — REST API Reference Guide**, MK-98RD9014-13, February 2022 (SVOS RF 9, VSP E series = SVOS RF 9.8.1). Target hardware: **VSP E590H**.

All "page" citations below are **PDF page indices** (this document's printed page number equals the PDF page index 1:1, verified by spot-reads).

This is a focused, implementation-oriented extract — not a full reproduction. Exact field names are quoted from the source. Items not directly confirmed in the read pages are marked **(re-verify)**.

---

## 0. Fundamentals (Chapter 1)

### Base URL, domains, methods (pp. 22–29)

- **Base URL:** `protocol://host-name:port-number/ConfigurationManager`
- Objects domain: `<base>/v1/objects/...`
- Services domain (batch / locking): `<base>/v1/services/...`
- Configuration domain (version only): `<base>/ConfigurationManager/configuration/version`
- **Object operations can also be scoped to a storage device** (recommended for the plugin so the request is unambiguous):
  `protocol://host-name:port-number/ConfigurationManager/v1/objects/storages/{storageDeviceId}/{object-type}...`
  (p. 24, Tip)
- **protocol:** `https` (recommended) or `http`.
- **host-name:** IP address or hostname of the GUM/SVP.
- **port:** default **443** for SSL, **80** for non-SSL. Can be omitted if default. (p. 23)
- **version:** only `v1` is valid. (p. 23)

### storageDeviceId (12 digits) (p. 24)

12-digit value = model fixed value + 6-digit serial (serial left-padded with zeros to 6 digits).

| Storage system | Fixed value |
|---|---|
| VSP 5100/5500/5100H/5500H, 5200/5600/5200H/5600H | `900000` (#1: pad zeros after this value, before serial) |
| **VSP E590, E790, E590H, E790H** | **`934000`** |
| VSP E990 | `936000` |
| VSP E1090, E1090H | `938000` |
| VSP F370/F700/F900, G370/G700/G900 | `886000` |
| VSP F350, G350 | `882000` |
| VSP G130 | `880000` |

**Plugin note:** For a VSP E590H with serial e.g. `400123`, `storageDeviceId` = `934000400123`. Compose object URLs as `…/v1/objects/storages/934000XXXXXX/ldevs` etc.

### Supported HTTP methods (pp. 29–30)

| Method | Use | Processing |
|---|---|---|
| GET | get object / list | Synchronous |
| POST | create object / run action | **Asynchronous** (exceptions, synchronous: Generating sessions, uploading init files, external-storage iSCSI target get/login test, backing up encryption keys) |
| PATCH | change attribute / state | Asynchronous (exception synchronous: setting system date/time) |
| DELETE | delete object | Asynchronous (exception synchronous: Discarding sessions) |

- Async: returns **HTTP 202** + a **job object**. (p. 30)
- Request header `Response-Job-Status: Completed` → response returned only after job complete. (p. 30)
- For pair ops, `Job-Mode-Wait-Configuration-Change: NoWait` makes status change to `Completed` without waiting for data copy to finish. (p. 30)

### Capacity units / conventions (pp. 17–18) — CRITICAL

- **Logical capacity (LDEV/cache/pool) is base-1024:** `1 KB = 1024 bytes`, `1 MB = 1024² bytes`, `1 GB = 1024³ bytes`, `1 TB = 1024⁴ bytes`.
- **1 block = 512 bytes** (logical).
- Physical capacity (drive) is base-1000 (1 KB = 1000 bytes) — applies to drive/parity-group descriptions, not LDEV sizing.

**Plugin note:** `byteFormatCapacity` for LDEVs/pools follows the **logical (base-1024 / GiB-MiB)** convention. For an **exact-size** volume use `blockCapacity` (count of 512-byte blocks) — see §6.

### Data types (pp. 43–44)

- `long` = 64-bit signed int; `int` = 32-bit; `ISO8601string` = `YYYY-MM-DDThh:mm:ssZ` (UTC only); `link` = a relative URL path (e.g. `/ConfigurationManager/v1/objects/ldevs/100`).

---

## 1. Sessions & authentication (Chapter 2; Ch.1 pp. 30–33)

### Auth model (pp. 30–33)

- **Session generation** authenticates with **`Authorization: Basic <base64(userid:password)>`** (user ID + password).
- **All other requests** authenticate with the session token:
  **`Authorization: Session <token>`** (example: `Authorization: Session d7b673af189048468c5af9bcf3bbbb6f`). (p. 32–33)
- Max **64 sessions per storage system**; exceeding returns HTTP 503. (p. 78)
- User ID 1–63 chars; password 6–63 chars. (p. 32)

### Generate session — POST (p. 78–79)

- **Method/path:** `POST <base-URL>/v1/objects/sessions`
- Object ID: none. Query params: none.
- **Request body** (all optional):

| Field | Type | Notes |
|---|---|---|
| `aliveTime` | long | Session timeout seconds, 1–300 (default 300). For **remote copy**, use ≥ 60 s (p. 78 note). |
| `authenticationTimeout` | long | Auth processing timeout secs, 1–900 (default 120); for external auth servers. |

- **Response body:**

| Field | Type | Notes |
|---|---|---|
| `token` | string | Use in `Authorization: Session <token>`. |
| `sessionId` | int | Used as object-ID to discard the session. |

- Execution permission: Storage Administrator (View Only).

### Discard session — DELETE (p. 80)

- **Method/path:** `DELETE <base-URL>/v1/objects/sessions/{sessionId}` (object-ID = `sessionId`, required int).
- **Request body:** `{ "force": true }` (optional; force-discard).
- Discarding a session also releases locks held in it.
- PATCH on sessions **(re-verify** — TOC lists generate/discard/get/list; a PATCH to extend session lifetime exists in some firmware but was not located in read pages**)**.

**Plugin note:** Generate one session at start, reuse the token across all requests, DELETE it at the end. Watch the 64-session cap.

---

## 2. Async job object (pp. 45–49) — CRITICAL

- Async POST/PATCH/DELETE return **HTTP 202 + a job object**. The job runs in the background; poll it.
- **The job URL is the `self` link** (`/ConfigurationManager/v1/objects/jobs/{jobId}`). There is **no separate `Location`/`statusResource` header in the documented model** — you take `jobId`/`self` from the 202 body and GET it. **(re-verify** any Location-header behavior — not documented in read pages**)**

### Job object fields (pp. 46–47)

| Field | Type | Notes |
|---|---|---|
| `jobId` | long | Job ID. |
| `self` | link | URL of the job info: `/ConfigurationManager/v1/objects/jobs/{jobId}`. |
| `userId` | string | User who issued the request. |
| `status` | string | `Initializing` / `Running` / `Completed`. (lifecycle) |
| `state` | string | `Queued` / `Started` / `StorageAccepted` / **`Succeeded`** / **`Failed`** / `Unknown`. (`StorageAccepted` only for remote-copy-pair create) |
| `createdTime`/`updatedTime`/`completedTime` | ISO8601string | timestamps |
| `request` | Request Object | `requestUrl`, `requestMethod`, `requestBody`. |
| `affectedResources` | link[] | **URLs of the resources created/changed.** This is where the new resource ID is. |
| `error` | Error Object | present on failure. |

- **Terminal detection:** `status` == `Completed`; success vs failure by **`state`** == `Succeeded` vs `Failed`.
- **Created-resource ID location:** **`affectedResources[0]`** — e.g. creating an LDEV yields `"affectedResources": ["/ConfigurationManager/v1/objects/ldevs/112"]` (p. 48). Parse the last path segment for the new ldevId. There is **no** `operationDetails[].resourceId` in this model — use `affectedResources`.
- Job retention: VSP E series max **3,000** job records (oldest createdTime dropped first); VSP 5000 = 100,000. (p. 47)

### Error object (p. 49)

`errorSource` (link), `messageId` (e.g. `KART30000-E`), `message`, `cause`, `solution`, `solutionType` (`RETRY` → safe to retry; `SEE_ERROR_DETAIL` → manual action), `errorCode` { `SSB1`, `SSB2` }, `detailCode`.

**Plugin note:** Poll `GET /v1/objects/jobs/{jobId}` until `status=Completed`; treat `state=Succeeded` as success and read the new object ID from `affectedResources[0]`. On failure inspect `error.solutionType` — only retry when `RETRY`.

---

## 3. Thin Image (snapshots) — TOP PRIORITY (Chapter 9, pp. 508–574)

Thin Image stores only **differential data** of the P-VOL as **snapshot data** in a Thin Image pool or HDP pool (copy-on-write). A pair may be created **with or without an S-VOL**; an S-VOL can be assigned later. (pp. 508–510)

### 3.1 Pair status values (pp. 513–515)

| status | Meaning | P-VOL access | S-VOL access |
|---|---|---|---|
| `SMPL` | Unpaired | – | – |
| `SMPP` | Deleted, differential data being deleted | R/W | (varies) |
| `COPY` | Pair being created | R/W | Not enabled |
| `PAIR` | Paired | R/W | Not enabled |
| `PFUL` | Paired, pool threshold exceeded | R/W | Not enabled |
| **`PSUS`** | **The pair has been split** | **R/W enabled** | **R/W enabled** |
| `PFUS` | Split + pool threshold exceeded | R/W | R/W |
| `RCPY` | Restore in progress (S-VOL → P-VOL) | R/W | Not enabled |
| `PSUE` | Pairing suspended | R/W | Not enabled |
| `PSUP` | Pair is being split (transitional, cloning path) | R/W | R/W |

Key fact: **only in `PSUS`/`PFUS` is the S-VOL host R/W-accessible.** While `PSUS`, the S-VOL is a point-in-time view that still **shares unchanged blocks with the P-VOL via the pool** (copy-on-write differential) — i.e. a space-sharing linked snapshot/clone.

### 3.2 Create Thin Image pair — POST `/v1/objects/snapshots` (pp. 543–547) — CRITICAL

- **Method/path:** `POST <base-URL>/v1/objects/snapshots`
- Execution permission: Storage Administrator (Local Copy). Object ID: none. Query: none.
- **Request body fields:**

| Field | Type | Req? | Notes |
|---|---|---|---|
| `snapshotGroupName` | string | **Required** | 1–32 chars, case-sensitive. New name auto-creates the snapshot group. |
| `snapshotPoolId` | int | **Required** | Pool ID where snapshot data is created. Thin Image pool or HDP pool, decimal ≥ 0. |
| `pvolLdevId` | int | **Required** | LDEV number of the P-VOL, decimal ≥ 0. |
| `svolLdevId` | int | Optional | LDEV number of the S-VOL. **Required when `isClone=true`** (and for `canCascade=true`, must be a DP volume). If omitted, a pair **without** an S-VOL is created. |
| `isConsistencyGroup` | boolean | Optional | `true` = create snapshot group in CTG (consistency-group) mode. Default `false`. |
| `autoSplit` | boolean | Optional | `true` = split the pair right after creation → snapshot data stored, pair goes to **`PSUS`**. **Cannot be `true` if `isClone=true`.** Default `false`. |
| `canCascade` | boolean | Optional | `true` = pair can be cascaded. **Must be `true` when `isClone=true`.** Defaults to same value as `isClone`. |
| `isClone` | boolean | Optional | `true` = create pair with the **clone attribute**. When `true`: do NOT set `autoSplit`; MUST set `canCascade=true`; MUST supply `svolLdevId`. Default `false`. |
| `clonesAutomation` | boolean | Optional | Only when `isClone=true`. `true` = clone the pair after creation (kick off full copy). Default `false`. |
| `copySpeed` | string | Optional | Only when `isClone=true` AND `clonesAutomation=true`. `slower`/`medium`/`faster` (default `medium`). |
| `isDataReductionForceCopy` | boolean | Optional | `true` = force-create a pair on a **capacity-saving (dedupe/compression) enabled** volume. **Must be `true`** for such volumes. Default `false`. |
| `muNumber` | int | Optional | MU number of the P-VOL, 0–1023. If omitted, an available MU is assigned. |

- **Response:** job object; `affectedResources` = URL of the created Thin Image pair (p. 548). New pair's object ID is the `snapshotId` (`pvolLdevId,muNumber`).

#### `autoSplit` vs `isClone` — THE VERDICT

- **`autoSplit=true` (and `isClone` false/unset)** → creates the pair and **SPLITS** it so the **S-VOL becomes R/W host-accessible (status `PSUS`)** while it **STILL shares unchanged blocks with the P-VOL via the pool** (copy-on-write differential snapshot). This is the **PERSISTENT SPACE-SHARING LINKED CLONE / snapshot**. The S-VOL only consumes pool space for differential (changed) blocks. The pair persists; you manage it with split/resync/restore/delete.
- **`isClone=true`** (requires `svolLdevId` + `canCascade=true`, and typically `clonesAutomation=true`) → creates a pair with the clone attribute and, when cloned, performs a **full background copy of ALL P-VOL data to the S-VOL**, after which **the pair is automatically DELETED** (p. 513: "After all the data of the primary volume … is copied to the secondary volume, the pair is deleted"). Result: a **FULL, INDEPENDENT clone** (the former S-VOL is now a standalone DP volume that no longer shares blocks with the P-VOL). `copySpeed` controls the copy rate.
- They are **mutually exclusive** (`autoSplit=true` forbidden with `isClone=true`).

**Plugin note (VVol-like linked clone vs full clone):**
- For a **PVE linked clone / fast snapshot** that shares space with the parent: create an LDEV for the S-VOL (or omit it), then `POST /snapshots` with `autoSplit=true`, `isClone` unset. The S-VOL ends in `PSUS` and is immediately host-usable while sharing blocks (thin/copy-on-write).
- For a **PVE full clone** (independent volume): create the S-VOL as a DP volume of equal size, then `POST /snapshots` with `isClone=true`, `canCascade=true`, `clonesAutomation=true`, `svolLdevId=<new>`. Poll the job; the pair self-deletes when copy completes; the S-VOL is a standalone full copy. Use `copySpeed` to tune.
- For capacity-saving (dedupe/compress) source volumes, set `isDataReductionForceCopy=true`.

### 3.3 Get Thin Image pairs (list/specific) — GET `/v1/objects/snapshots` (pp. 528–535)

- **List:** `GET <base-URL>/v1/objects/snapshots?<filter>` — at least one filter required, else error.
  - Filters (query params): `snapshotGroupName` (string), `pvolLdevId` (int), `svolLdevId` (int), `muNumber` (int 0–1023). Valid combos: P-VOL ldevId + group name; P-VOL ldevId + muNumber; P-VOL ldevId only; or S-VOL ldevId only.
  - Example: `GET …/v1/objects/snapshots?pvolLdevId=100&muNumber=3`
- **Specific pair:** `GET <base-URL>/v1/objects/snapshots/{snapshotId}` where `snapshotId` = `pvolLdevId,muNumber` (object ID).
- **Response fields per pair (pp. 533–535):**

| Field | Type | Notes |
|---|---|---|
| `snapshotGroupName` | string | Snapshot group name. |
| `primaryOrSecondary` | string | `P-VOL` / `S-VOL` (the LDEV's role). |
| `status` | string | Pair status (see §3.1; e.g. `PSUS`). |
| `pvolLdevId` | int | P-VOL LDEV number. |
| `muNumber` | int | MU number of the P-VOL. |
| `svolLdevId` | int | S-VOL LDEV number (if S-VOL exists). |
| `snapshotPoolId` | int | Pool holding snapshot data. |
| `concordanceRate` | int | Concordance (match) rate %. |
| `progressRate` | int | Copy progress % (output for clone/cascade during COPY/RCPY/etc). |
| `isConsistencyGroup` | boolean | Created in CTG mode. |
| `isWrittenInSvol` | boolean | Whether host wrote to S-VOL while PSUS/PFUS. |
| `isClone` | boolean | Pair has clone attribute. |
| `canCascade` | boolean | Pair can be cascaded. |
| `splitTime` | string | `YYYY-MM-DDThh:mm:ss`, time snapshot data was created. |
| **`snapshotId`** | string | **Object ID of the pair = `pvolLdevId,muNumber`** (comma-joined). |
| `pvolProcessingStatus` | string | `E`/`N` expansion in progress (output when role=P-VOL). |
| `svolProcessingStatus` | string | `E`/`N` expansion in progress (output when role=S-VOL). |
| `snapshotDataReadOnly` | boolean | Snapshot data has read-only attribute. |

### 3.4 Snapshot actions — split / resync / restore / clone / delete

| Action | Method / path | Notes |
|---|---|---|
| Store snapshot data (split) per group | `POST <base>/v1/objects/snapshot-groups/{snapshotGroupId}/actions/split/invoke` | Object ID = `snapshotGroupId`. Splits all pairs in group → PSUS. (p. 548) |
| Store snapshot data (split) single pair | `POST <base>/v1/objects/snapshots/{snapshotId}/actions/split/invoke` | (re-verify exact body; per-pair split, p. 550 TOC) |
| Resync (delete old snapshot data) per group | `POST <base>/v1/objects/snapshot-groups/{snapshotGroupId}/actions/resync/invoke` | Resync allowed when status `PSUS`. (p. 551 TOC) |
| Resync single pair | `POST <base>/v1/objects/snapshots/{snapshotId}/actions/resync/invoke` | (p. 554 TOC) |
| Restore (S-VOL→P-VOL) per group | `POST <base>/v1/objects/snapshot-groups/{snapshotGroupId}/actions/restore/invoke` | Restore allowed when status `PSUS`; status → `RCPY`. (p. 556 TOC) |
| Restore single pair | `POST <base>/v1/objects/snapshots/{snapshotId}/actions/restore/invoke` | (p. 558 TOC) |
| Assign S-VOL to snapshot data | `POST <base>/v1/objects/snapshots/{snapshotId}/actions/assign-volume/invoke` | (re-verify action name; p. 560 TOC) |
| **Clone pairs per group** | `POST <base>/v1/objects/snapshot-groups/{snapshotGroupId}/actions/clone/invoke` | Body `{ "parameters": { "copySpeed": "medium" } }`. Action template GET `/snapshot-groups/{id}/actions/clone`. (pp. 570–571) |
| **Clone single pair** | `POST <base>/v1/objects/snapshots/{snapshotId}/actions/clone/invoke` | Object ID = `snapshotId` (`pvolLdevId,muNumber`). Required body: `pvolLdevId` (int ≥0), `muNumber` (int 0–1023) implied via object-ID; `copySpeed` optional. After full copy the pair is **deleted**, leaving an independent clone. (pp. 572–574) |
| Delete pair | `DELETE <base>/v1/objects/snapshots/{snapshotId}` | Deletes pair; snapshot data is freed. If last pair in group, group is deleted. Can delete in any status. (p. 565 TOC) |

**Plugin note:** The pair's object ID for actions is `snapshotId` = `"<pvolLdevId>,<muNumber>"` (the comma must be URL-encoded as `%2C` if generating the ID per §0 object-ID rules; example in doc uses `snapshots/100,3`). List pairs by P-VOL with `?pvolLdevId=<n>`. To enumerate all snapshots of a base volume, query `snapshots?pvolLdevId=<parentLdev>`.

---

## 4. LDEVs / volumes (Chapter 5)

### 4.1 Create volume — POST `/v1/objects/ldevs` (pp. 220–225)

- **Method/path:** `POST <base-URL>/v1/objects/ldevs`. Execution permission: Storage Administrator (Provisioning). Object ID/query: none.
- **Request body fields:**

| Field | Type | Notes |
|---|---|---|
| `ldevId` | int | Optional. LDEV number to create (decimal). If omitted, lowest unused number is assigned. Cannot combine with `isParallelExecutionEnabled`. |
| `isParallelExecutionEnabled` | boolean | Optional, DP volumes only. `true` = parallel job execution + auto-assign LDEV number. Mutually exclusive with `ldevId`/`parityGroupId`/`externalParityGroupId`. |
| `startLdevId` / `endLdevId` | int | Optional. Range for auto-assignment when parallel. |
| `parityGroupId` | string | Required for a **basic volume**. e.g. `"1-1"`, concatenated `"1-3"`. |
| `externalParityGroupId` | string | Required for an **external volume**. |
| `poolId` | int | Required for a **virtual volume from a pool**. DP volume: pool number ≥ 0. **Thin Image virtual volume: specify `-1`.** |
| `dataReductionMode` | string | Optional. `compression` / `compression_deduplication` / `disabled` (default `disabled`). Enables capacity-saving on a DP volume. |
| `isCompressionAccelerationEnabled` | boolean | Optional. Enable compression accelerator. |
| **`byteFormatCapacity`** | string | **Capacity + unit.** Units: `T`/`t`, `G`/`g`, `M`/`m`, `K`/`k`. `"all"` = all free space. Example `"1G"`. Specify either this OR `blockCapacity`. |
| **`blockCapacity`** | long | **Capacity in 512-byte blocks** (1 block = 512 bytes). Example `2097152` = 1 GiB. Specify either this OR `byteFormatCapacity`. |

- **Response:** job object; `affectedResources` = URL of created volume (`…/ldevs/{ldevId}`). New ldevId from the last path segment.

**Plugin note (exact sizing):** `byteFormatCapacity` uses **base-1024** (`"1G"` = 1 GiB = 1073741824 bytes); `blockCapacity` = exact 512-byte block count (1 GiB = 2097152 blocks). **For an exact-size LDEV matching a Proxmox request in bytes, use `blockCapacity` = bytes / 512** (round up to block boundary) — this avoids rounding ambiguity. For Thin Image S-VOLs create as DP volume with `poolId` of the data pool (or `-1` for a TI virtual volume).

### 4.2 Format volume — POST `/v1/objects/ldevs/{ldevId}/actions/format/invoke` (pp. 226–228)

- Object ID = `ldevId` (int, required). Body `{ "parameters": { "operationType": "FMT" | "QFMT" } }` (FMT = normal, QFMT = quick). For capacity-saving DP volume must use `FMT` + `isDataReductionForceFormat: true`. Action template: `GET …/ldevs/{id}/actions/format`.

### 4.3 Expand volume — POST `/v1/objects/ldevs/{ldevId}/actions/expand/invoke` (pp. 229–231)

- DP volumes only (412 "not a DP volume" otherwise). Object ID = `ldevId`.
- Body: `{ "parameters": { "additionalByteFormatCapacity": "1G" } }` OR `{ "parameters": { "additionalBlockCapacity": 2097152 } }`.

| Field | Type | Notes |
|---|---|---|
| `additionalByteFormatCapacity` | string | Capacity to add + unit (`T`/`G`/`M`/`K`). |
| `additionalBlockCapacity` | long | Capacity to add in 512-byte blocks. |
| `enhancedExpansion` | boolean | `true` = also expand volumes used by the copy pair (pair must be PSUS/SSUS). Default `false`. |

**Plugin note:** Resize maps cleanly to `additionalBlockCapacity` (bytes-to-add / 512). For replicated/snapshot volumes set `enhancedExpansion: true` (pair must be split).

### 4.4 Change volume settings (incl. label, QoS-adjacent) — PATCH `/v1/objects/ldevs/{ldevId}` (pp. 231–237)

- **Method/path:** `PATCH <base-URL>/v1/objects/ldevs/{ldevId}`. Object ID = `ldevId` (int, required).
- Key body fields:

| Field | Type | Notes |
|---|---|---|
| **`label`** | string | **0–32 characters.** Alphanumerics + `! # $ % & ' ( ) + , - . : = @ [ ] ^ _ \` { } ~ / \`; may start with hyphen; cannot start/end with a space. |
| `dataReductionMode` | string | `compression`/`compression_deduplication`/`disabled`. |
| `dataReductionProcessMode` | string | `post_process` / `inline`. Cannot combine with other attributes. |
| `isCompressionAccelerationEnabled` | boolean | enable/disable accelerator. |
| `isRelocationEnabled` | boolean | HDT tier relocation. |
| `tieringPolicy` | object | `{ tierLevel, tier1AllocationRateMin/Max, tier3AllocationRateMin/Max }`. |
| `tierLevelForNewPageAllocation` | string | `H`/`M`/`L`. |
| `isFullAllocationEnabled` | boolean | page reservation for DP volume. |
| `isAluaEnabled` | boolean | enable ALUA (for GAD cross-path FC). |

**Plugin note:** Set the per-disk label (e.g. `vm-<vmid>-disk-<n>`) via this PATCH; label max length is **32**. Note: QoS is NOT set here — see §5.

### 4.5 Delete volume — DELETE `/v1/objects/ldevs/{ldevId}` (p. 248, TOC)

- `DELETE <base-URL>/v1/objects/ldevs/{ldevId}`. Async job; `affectedResources` returns the (now-404) deleted URL. **(re-verify** body options like `isDataReductionDeleteForceExecute`**)**.

### 4.6 Get volume / list — GET `/v1/objects/ldevs` and `/v1/objects/ldevs/{ldevId}` (pp. 185–220)

- **List:** `GET <base-URL>/v1/objects/ldevs?<filters>`. Default 100 LDEVs; `count` 1–16384. For >16,384 use `headLdevId` paging.
- **Filter query params (pp. 186–190):** `count` (int 1–16384), `headLdevId` (int, start LDEV, paging), `ldevOption` (string: `defined`/`undefined`/**`dpVolume`**/`luMapped`/`luUnmapped`/`externalVolume`), `poolId` (int), `resourceGroupId` (int), `journalId` (int), `parityGroupId` (string), `detailInfoType` (string, comma-sep: `FMC`,`externalVolume`,`virtualSerialNumber`,`savingInfo`,`class`,**`qos`**). Combination matrix on p. 189.
- **Specific volume:** `GET <base-URL>/v1/objects/ldevs/{ldevId}` (object ID = ldevId).
- **Selected response fields (example p. 220):** `ldevId`, `label`, `status` (`NML` = normal), `attributes[]` (e.g. `CVS`, `HDP`), `poolId`, `numOfUsedBlock` (512-byte blocks), `byteFormatCapacity` (re-verify presence on specific GET), `blockCapacity`, `mpBladeId`, `ssid`, `isFullAllocationEnabled`, `resourceGroupId`, `dataReductionStatus`, `dataReductionMode`, `dataReductionProcessMode`, `isAluaEnabled`, and **`naaId`** (see §8).

**Plugin note:** Use `ldevOption=dpVolume` + `poolId=<n>` to enumerate the plugin's volumes in a pool; use `count`/`headLdevId` to page. `numOfUsedBlock` (×512) gives used bytes.

---

## 5. QoS — POST `/v1/objects/ldevs/{ldevId}/actions/set-qos/invoke` (pp. 439–442) — EXACT PATH

**It is an ACTION on the LDEV, not a PATCH and not a separate qos-settings resource.**

- **Method/path:** `POST <base-URL>/v1/objects/ldevs/{ldevId}/actions/set-qos/invoke`
- Object ID = `ldevId` (int, required). Execution permission: Storage Administrator (System Resource Management).
- Supported on VSP 5000 series, VSP G350/G370/G700/G900, VSP F350/F370/F700/F900. **(VSP E-series support: re-verify** — this note lists only those models; VSP E series is not named here, so QoS-set support on E590H needs confirmation against E-series-specific docs**)**.
- **Body:** `{ "parameters": { "<attr>": <value> } }` — **exactly ONE attribute per request**.

| Field | Type | Notes |
|---|---|---|
| `upperIops` | long | Upper IOPS limit, 100–2147483647; `0` disables. Must be > `lowerIops` if both set. |
| `upperTransferRate` | int | Upper transfer limit **in MB/s**, 1–2097151; `0` disables. |
| `upperAlertAllowableTime` | int | Seconds 1–600 before alert when upper limit exceeded; `0` disables. Only if upper limit set. |
| `lowerIops` | long | Lower IOPS limit, 10–2147483647; `0` disables. (G/F models only.) |
| `lowerTransferRate` | int | Lower transfer limit MB/s, 1–2097151; `0` disables. (G/F models only.) |
| `lowerAlertAllowableTime` | int | Seconds 1–600; `0` disables. (G/F models only.) |
| `responsePriority` | int | I/O priority 1–3 (higher = more priority); `0` disables. (G/F models only.) |
| `responseAlertAllowableTime` | int | Seconds 1–600; `0` disables. (G/F models only.) |

- **Response:** job object; `affectedResources` = URL of the LDEV for which QoS was configured.
- **QoS performance read:** `GET <base-URL>/v1/objects/qos-monitor-ldevs/{ldevId}` → `ldevId`, `receivedCommands`, `transferRateOfReceivedCommands`, `iops`, `transferRate`, `responseTime` (µs), `monitorTime`.

**Plugin note:** QoS confirmed as `set-qos` action (one attribute per call), NOT a `PATCH /ldevs/{id}` and NOT a separate resource. To set both an IOPS cap and a transfer cap you must issue multiple sequential POSTs. The desired-field names from the task (`upperIops`/`upperTransferRate`/`lowerIops`/`lowerTransferRate`/`responsePriority`) are correct; transfer rates are in **MB/s**.

---

## 6. LU paths (luns) — GET/POST/DELETE `/v1/objects/luns` (pp. 318–330) — incl. naaId question

### 6.1 Get LU paths (list) — GET `/v1/objects/luns` (pp. 318–321)

- **Method/path:** `GET <base-URL>/v1/objects/luns?<filters>`
- **Query params:** `portId` (string, **required**), `hostGroupNumber` (int, required unless `hostGroupNumberList` given; for iSCSI = target ID), `isBasicLunInformation` (boolean), `lunOption` (string: `ALUA`), `hostGroupNumberList` (string, comma-sep).
- **Response fields per LU path (pp. 320–321):**

| Field | Type | Notes |
|---|---|---|
| `lunId` | string | Object ID of the LUN = `portId,hostGroupNumber,lun` (e.g. `"CL1-A,1,1"`). |
| `portId` | string | Port number (e.g. `CL1-A`). |
| `hostGroupNumber` | int | Host group number (iSCSI: target ID). |
| `hostMode` | string | Host mode (e.g. `LINUX/IRIX`). |
| `lun` | int | LUN between host group and mapped LDEV. |
| `ldevId` | int | LDEV number. |
| `isCommandDevice` | boolean | Whether device is a command device. |
| `luHostReserve` | object | `{ openSystem, persistent, pgrKey, mainframe, acaReserve }` (when `isBasicLunInformation=false`). |
| `hostModeOptions` | int[] | Host mode option numbers. |
| `isAluaEnabled` | boolean | Only when `lunOption=ALUA`. |
| `asymmetricAccessState` | string | ALUA path priority: `Active/Optimized` / `Active/Non-Optimized` / `Not Supported`. Only when `lunOption=ALUA`. |

### 6.2 Get specific LU path — GET `/v1/objects/luns/{lunId}` (pp. 322–324)

- Object ID `lunId` = `portId,hostGroupNumber,lun`. Same fields as above plus `ldevId`, `luHostReserve`, `hostModeOptions`.

### naaId question — VERDICT

**The LU-path (luns) GET response does NOT contain a `naaId` / WWID field per path.** Per-path fields are only those in §6.1 above (`lunId`, `portId`, `hostGroupNumber`, `hostMode`, `lun`, `ldevId`, `isCommandDevice`, `luHostReserve`, `hostModeOptions`, `isAluaEnabled`, `asymmetricAccessState`).

The **`naaId`** field is instead returned by the **LDEV GET** (`GET /v1/objects/ldevs/{ldevId}`, §4.6). The doc states (p. 220): *"`naaId` (string): The NAA ID of the volume **whose LU path was specified** is output."* Example value: **`"60060e8006cf2e000000cf2e00000000"`** (a 32-hex-char NAA Identifier). This field is output in addition to the standard volume-info attributes, i.e. it appears for an LDEV that has an LU path defined.

**Plugin note (multipath/WWID mapping):** To get the SCSI device WWID/NAA for a provisioned LUN, read it from the **LDEV** object (`GET /ldevs/{ldevId}` → `naaId`), NOT from `/luns`. The Linux multipath WWID is `3` + the naaId (NAA-format identifier), i.e. `/dev/disk/by-id/wwn-0x<naaId>` and multipath `3<naaId>`. Map host-visible LUN ↔ LDEV via the `/luns` path (`lun` ↔ `ldevId`), then resolve the WWID via `/ldevs/{ldevId}.naaId`.

### 6.3 Set LU path — POST `/v1/objects/luns` (pp. 327–328)

- **Method/path:** `POST <base-URL>/v1/objects/luns`. Object ID/query: none. Permission: Provisioning.
- **Body:**

| Field | Type | Notes |
|---|---|---|
| `portId` | string | Optional. Single port. Mutually exclusive with `portIds`; specify one of the two. |
| `portIds` | string[] | Optional. Up to **6** ports (sets multiple LU paths at once). |
| `hostGroupNumber` | int | **Required.** Host group / iSCSI target ID. |
| `lun` | int | Optional. If omitted, auto-assigned. Cannot reuse same LUN for multiple LDEVs. |
| `ldevId` | int | **Required.** LDEV number. Cannot map an LDEV to another LUN in the same host group. |

- Example: `{ "portIds": ["CL1-A","CL2-A"], "hostGroupNumber": 1, "ldevId": 64, "lun": 12 }`
- **Response:** job object; `affectedResources` = URL of created LU path.

### 6.4 Delete LU path — DELETE `/v1/objects/luns/{lunId}` (p. 330, TOC)

- Object ID `lunId` = `portId,hostGroupNumber,lun`. Async job.

### 6.5 Set ALUA path priority — POST `/v1/services/lun-service/actions/change-asymmetric-access-state/invoke` (pp. 329–330)

- Body `{ "parameters": { "portId": "CL1-A", "hostGroupNumber": 1, "asymmetricAccessState": "Active/Optimized" } }` (`Active/Optimized` = higher priority, `Active/Non-Optimized` = lower). For GAD cross-path FC.

**Plugin note:** Map a volume to a host by POSTing `/luns` with the target host group's `hostGroupNumber` and the `ldevId`; specify `portIds[]` (≤6) for multipath across front-end ports in one call. To present to multiple host groups (multiple hosts), issue one POST per host group.

---

## 7. Pools (Chapter 6, pp. 342–382)

### 7.1 List pools — GET `/v1/objects/pools` (pp. 342–344)

- **Method/path:** `GET <base-URL>/v1/objects/pools?<filters>`
- Query: `poolType` (string: `DP` / `HTI`); `detailInfoType` (string, comma-sep: `FMC`,`tierPhysicalCapacity`,`efficiency`,`formattedCapacity`,`class`).

### 7.2 Specific pool — GET `/v1/objects/pools/{poolId}` (pp. 378–382)

- Object ID = `poolId` (int). Key response fields:

| Field | Type | Notes |
|---|---|---|
| `poolId` | int | Pool number. |
| `poolName` | string | Pool name. |
| `poolType` | string | `HDP` / `HDT` / `RT` (active flash) / `DM`. |
| `poolStatus` | string | `POLN` (normal) / `POLF` (full) / `POLS` (suspended-full) / `POLE` (failure). |
| `usedCapacityRate` | int | Logical usage rate (%). |
| `usedPhysicalCapacityRate` | int | Physical usage rate (%). |
| **`availableVolumeCapacity`** | long | **Free logical capacity in MB (MiB).** |
| `availablePhysicalVolumeCapacity` | long | Free physical capacity in MB; **1 MB = 1024² bytes**. |
| **`totalPoolCapacity`** | long | **Total logical capacity in MB (MiB).** |
| `totalPhysicalCapacity` | long | Total physical capacity in MB; **1 MB = 1024² bytes**. |
| `numOfLdevs` | int | LDEVs in pool. |
| `firstLdevId` | int | First LDEV number. |
| `warningThreshold`/`depletionThreshold` | int | Threshold %. |
| `virtualVolumeCapacityRate` | int | Max subscription %; `-1` = unlimited (or invalid on G/F). |
| `locatedVolumeCount` | int | DP volumes mapped to pool. |
| `totalLocatedCapacity` | long | Total mapped DP-volume capacity (MB). |
| `snapshotCount` | int | snapshot data items mapped. |
| `snapshotUsedCapacity` | long | Snapshot data size (MB). |
| `blockingMode` | string | `PF`/`PB`/`FB`/`NB`. |
| `dataReductionRate` etc. | int | capacity-saving ratios. |

**Plugin note (UNITS):** `totalPoolCapacity` and `usedCapacity`-equivalent (`totalPoolCapacity - availableVolumeCapacity`) are in **MB = MiB (1024² bytes)**, i.e. base-1024. For Proxmox `status` reporting multiply by `1024*1024` to get bytes. `usedCapacityRate` is a percentage. Used logical capacity = `totalPoolCapacity - availableVolumeCapacity` (both MiB).

---

## 8. Host groups, host-wwns, ports (Chapter 5)

### 8.1 Create host group / iSCSI target — POST `/v1/objects/host-groups` (pp. 283–285)

| Field | Type | Notes |
|---|---|---|
| `portId` | string | **Required.** Port (e.g. `CL1-A`). |
| `hostGroupNumber` | int | Optional, 0–254. iSCSI: target ID. Auto-assigned if omitted. |
| `hostGroupName` | string | **Required.** Host group name 1–64 chars (iSCSI target name 1–32). |
| `iscsiName` | string | Optional. iqn/eui format (iSCSI target only). |
| `hostMode` | string | Optional. `HP-UX`/`SOLARIS`/`AIX`/`WIN`/`LINUX/IRIX`/`TRU64`/`OVMS`/`NETWARE`/`VMWARE`/`VMWARE_EX`/`WIN_EX`. Default `LINUX/IRIX`. |
| `hostModeOptions` | int[] | Host mode option numbers. |
| `isQuickCreating` | boolean | skip existence check / overwrite. |

- `affectedResources` = URL of created host group/iSCSI target. **Object ID = `hostGroupId` = `portId,hostGroupNumber`** (e.g. `CL1-A,0`).

### 8.2 Change host group settings — PATCH `/v1/objects/host-groups/{hostGroupId}` (pp. 286–288)

- Object ID = `portId,hostGroupNumber`. Body: `hostMode`, `hostModeOptions[]` (`[-1]` resets), and for iSCSI `authenticationMode` (`CHAP`/`NONE`/`BOTH`), `iscsiTargetDirection` (`S`/`D`).

### 8.3 Delete host group — DELETE `/v1/objects/host-groups/{hostGroupId}` (p. 289)

- Object ID = `portId,hostGroupNumber`.

### 8.4 host-wwns — GET / POST / PATCH (pp. 290–296)

- **List:** `GET <base-URL>/v1/objects/host-wwns?portId=<p>&hostGroupNumber=<n>` (or `hostGroupName` / `hostGroupNumberList`). Response per WWN: `hostWwnId` (object ID = `portId,hostGroupNumber,hostWwn`), `portId`, `hostGroupNumber`, `hostGroupName`, **`hostWwn`** (WWN of the HBA, e.g. `000000102ccecc9`), `wwnNickname`.
- **Specific:** `GET <base-URL>/v1/objects/host-wwns/{hostWwnId}`.
- **Register WWN:** `POST <base-URL>/v1/objects/host-wwns` — body `{ "hostWwn": "210003e08b0256f9", "portId": "CL1-A", "hostGroupNumber": 5 }` (`hostWwn` = 16-hex-char WWN, colons allowed; `portId` + `hostGroupNumber` required).
- **Set nickname:** `PATCH <base-URL>/v1/objects/host-wwns/{hostWwnId}` body `{ "wwnNickname": "..." }`.

### 8.5 Ports — GET `/v1/objects/ports` (pp. 250–253)

- **List:** `GET <base-URL>/v1/objects/ports?<filters>`. Query: `portType` (`FIBRE`/`SCSI`/`ISCSI`/`ENAS`/`ESCON`/`FICON`), `portAttributes` (`TAR`/`MCU`/`RCU`/`ELUN`), `portId` (string), `detailInfoType` (`logins`/`portMode`).
- Response per port: `portId` (e.g. `CL1-A`), `portType`, `portAttributes[]` (`TAR`/`MCU`/`RCU`/`ELUN`), `portSpeed`, `loopId`, `fabricMode`, `portConnection` (`PtoP`), `lunSecuritySetting`, **`wwn`** (port WWN, e.g. `50060e80124e3b00`).
- **Specific port:** `GET <base-URL>/v1/objects/ports/{portId}` (p. 258).

**Plugin note:** For FC, enumerate target ports with `?portType=FIBRE&portAttributes=TAR`; the port's own `wwn` is the storage-side target WWN (for zoning). Register the Proxmox host HBA WWNs into the host group via `POST /host-wwns`. The LUN's device WWID comes from the LDEV `naaId` (§6), not the port wwn.

---

## 9. Remote replication — remote-storages, remote-mirror-copypairs (Chapters 10–12)

### 9.1 remote-storages (pp. 578–586)

- **List:** `GET <base-URL>/v1/objects/remote-storages` (no params).
- **Specific:** `GET <base-URL>/v1/objects/remote-storages/{storageDeviceId}`.
- **Response fields:** `storageDeviceId` (string), `dkcType` (`Local`/`Remote`), `restServerIp`, `restServerPort` (int), `model`, `serialNumber` (int), `ctl1Ip`/`ctl2Ip` (output for VSP E series + G/F), `communicationModes[]` (`{ communicationMode: proxyMode | lanConnectionMode, proxies[]{proxyIp,proxyPort} }`).
- **Register:** `POST <base-URL>/v1/objects/remote-storages` — body `{ "storageDeviceId": "...", "restServerIp": "...", "restServerPort": 443, "isMutualDiscovery": true }`. Requires `Remote-Authorization: Session <remoteToken>` header (token from a session on the remote array). `affectedResources` = URL of registered remote storage.
- **Delete:** `DELETE <base-URL>/v1/objects/remote-storages/{storageDeviceId}`.

### 9.2 TrueCopy / Universal Replicator / GAD pairs — `/v1/objects/remote-mirror-copypairs` (pp. 683–686, Ch. 11–12)

- **Specific pair:** `GET <base-URL>/v1/objects/remote-mirror-copypairs/{remoteMirrorCopyPairId}` where the object ID is `remoteStorageDeviceId,copyGroupName,localDeviceGroupName,remoteDeviceGroupName,copyPairName` (comma-joined; encode commas). Most ops require a `Remote-Authorization: Session <remoteToken>` header.
- Copy-group object ID (`/remote-mirror-copygroups/{id}`) = `remoteStorageDeviceId,copyGroupName,localDeviceGroupName,remoteDeviceGroupName`.
- **Create pair:** `POST <base-URL>/v1/objects/remote-mirror-copypairs` (p. 700, body fields incl. `copyGroupName`, `copyPairName`, `replicationType` TC/UR/GAD, `pvolLdevId`, `svolLdevId`, `pvolStorageDeviceId`, `svolStorageDeviceId`, journals/quorum — **re-verify** exact create body, not fully read).
- **Common pair response fields:**

| Field | Type | Notes |
|---|---|---|
| `copyGroupName` | string | Copy group (1–31 chars). |
| `copyPairName` | string | Copy pair (1–31 chars). |
| `replicationType` | string | `TC` / `UR` / `GAD`. (Absent when status SMPL.) |
| `remoteMirrorCopyPairId` | string | Object ID. |
| `pvolLdevId` / `svolLdevId` | int | P/S-VOL LDEV numbers. |
| `pvolStorageDeviceId` / `svolStorageDeviceId` | string | storageDeviceIds. |
| `pvolStatus` / `svolStatus` | string | Pair status (e.g. `PAIR`). |
| `fenceLevel` | string | `DATA` / `STATUS` / `NEVER` / `ASYNC` (TC/UR). |
| `consistencyGroupId` | int | UR (and CTG). |
| `pvolJournalId` / `svolJournalId` | int | UR journals. |
| `quorumDiskId` | int | **GAD only.** |
| `pvolIOMode` / `svolIOMode` | string | **GAD only**, e.g. `L/M` (Local/Mirror). |
| `pvolDifferenceDataManagement` / `svolDifferenceDataManagement` | string | e.g. `S`. |
| `pvolProcessingStatus` / `svolProcessingStatus` | string | `E`/`N` expansion. |

**Plugin note:** Replication is out of the primary single-LUN-per-disk provisioning path. If implemented, register the peer with `/remote-storages` first; all pair ops need a session on BOTH arrays (local `Authorization: Session` + `Remote-Authorization: Session`). GAD distinguishes itself via `quorumDiskId` + `pvolIOMode`/`svolIOMode`; UR via journals + `consistencyGroupId`; TC via `fenceLevel`.

---

## 10. VSP E-series-specific limits / notes

- **storageDeviceId fixed value for VSP E590H = `934000`** → 12-digit ID `934000` + 6-digit serial (§0).
- **Job retention:** VSP E series keeps max **3,000** job records (oldest `createdTime` dropped first); VSP 5000 = 100,000 (p. 47). Don't rely on old jobs persisting.
- **Volume label length:** **0–32 characters** (PATCH `/ldevs/{id}` `label`, §4.4; create not labelable directly — set label via PATCH after create).
- **LDEV list:** default 100, `count` max 16,384 per call; use `headLdevId` paging for >16,384 (§4.6).
- **iSCSI target name:** 1–32 chars; host group name 1–64 chars (§8.1).
- **MU number:** 0–1023 (Thin Image, §3).
- **Host group number:** 0–254 (§8.1).
- **Sessions:** max 64 per storage system (§1).
- **TLS:** VSP E series supports **TLS 1.2** only, cipher suites listed p. 22 (e.g. `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`). Self-signed GUM cert by default → client must trust it or disable verification (e.g. Python `verify=False`).
- **QoS set-qos:** the model note (p. 439) lists VSP 5000 / G350–G900 / F350–F900 but **does NOT list VSP E series** → **QoS-set support on E590H must be re-verified** against E-series docs.
- **Concurrent-execution caution (VSP E series & G/F):** `GET /ldevs` (with detail), `GET /ports?detailInfoType=logins` warn about concurrency limits — implement retry/backoff (p. 186, p. 250).
- **`Job-Mode-Wait-Configuration-Change` / `Response-Job-Status` headers** available to make async calls block until complete (§0) — simplifies plugin sync flows.

---

## Appendix: object-ID quick reference

| Resource | Object ID format | Example |
|---|---|---|
| ldevs | `{ldevId}` | `ldevs/100` |
| pools | `{poolId}` | `pools/0` |
| snapshots (TI pair) | `{pvolLdevId},{muNumber}` | `snapshots/100,3` |
| snapshot-groups | `{snapshotGroupId}` (= name) | `snapshot-groups/snapshotGroup` |
| luns (LU path) | `{portId},{hostGroupNumber},{lun}` | `luns/CL1-A,1,1` |
| host-groups | `{portId},{hostGroupNumber}` | `host-groups/CL1-A,0` |
| host-wwns | `{portId},{hostGroupNumber},{hostWwn}` | `host-wwns/CL1-A,0,000000102ccecc9` |
| ports | `{portId}` | `ports/CL1-A` |
| sessions | `{sessionId}` | `sessions/3` |
| jobs | `{jobId}` | `jobs/111111` |
| remote-storages | `{storageDeviceId}` | `remote-storages/886000123457` |
| remote-mirror-copypairs | `{remoteStorageDeviceId},{copyGroupName},{localDeviceGroupName},{remoteDeviceGroupName},{copyPairName}` | — |

Commas in generated object IDs must be URL-encoded as `%2C` per RFC 3986 (§0). Object IDs obtained via GET are already encoded — use them as-is.
