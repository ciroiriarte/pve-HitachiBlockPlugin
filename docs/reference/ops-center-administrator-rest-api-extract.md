# Ops Center Administrator REST API — Connector Extract

**Source:** *Hitachi Ops Center Administrator REST API Reference Guide*,
Part No. MK-99ADM002-23, applies to **Ops Center Administrator 11.0.x**
(last updated 2025-09-15; generated from docs.hitachivantara.com). No local PDF
copy is checked in yet — this extract was distilled from the HTML reference
guide. If a connector is built, drop the PDF under `reference/` and cite pages.

> **Why this document exists.** The plugin today talks **directly to each
> array's embedded Configuration Manager REST API**
> (`https://<array>:443/ConfigurationManager/v1/objects/storages/<id>/...`,
> `Authorization: Session <token>` — see
> [`rest-api-extract.md`](rest-api-extract.md) and
> `src/PVE/Storage/HitachiBlock/RestClient.pm`). The **Ops Center
> Administrator** API documented here is a *different*, higher-level management
> plane: a single management server that fronts **many** arrays, models compute
> **servers** (hosts) as first-class objects, automates **SAN zoning**, and
> exposes **one-call create+attach+protect** orchestration. A connector that
> speaks this API is **not yet implemented** — this file is the reference for
> building it. It is also distinct from **Ops Center Common Services** (the
> identity/SSO layer, see
> [`ops-center-common-services-extract.md`](ops-center-common-services-extract.md)).

---

## 1. Where this fits among the three Hitachi REST surfaces

| | **Configuration Manager** (current plugin) | **Ops Center Administrator** (this doc, future connector) | **Common Services** (identity only) |
|---|---|---|---|
| Host | Array controller / GUM, or a CM REST server | Ops Center **management server** (one VIP for many arrays) | Ops Center server |
| Base path | `/ConfigurationManager/v1/objects/...` | `https://<mgmt-server>/v1/...` (**no trailing slash, ever**) | `/portal/auth/v1/...` |
| Auth header | `Authorization: Session <token>` | `X-Auth-Token: <token>` (or `Authorization: Bearer` via Common Services) | `Authorization: Bearer <jwt>` |
| Token TTL | session-based | **1200 s sliding** (resets on each use) | 300 s fixed |
| Array selector | one array per base URL | `storageSystemId` path segment — multi-array | n/a |
| Host model | host groups + WWNs on the array | **`server` / `server-group`** objects + automated zoning | n/a |
| Granularity | low-level LDEV/host-group/LUN-path primitives | high-level orchestration (create-attach-protect in one POST) | none (registry/SSO) |
| Media types | `application/json` | `application/json`, `application/hal+json` (HAL `_links`) | `application/json` |

**Implication for a connector.** This is not a drop-in swap for `RestClient.pm`.
It is a genuinely different control model — array-by-`storageSystemId`,
server-centric host mapping, automated zoning, and an async job queue. A
connector would most likely be a sibling backend selected by config (e.g. a new
`api_type`/platform), reusing the plugin's volume-naming and registry logic but
with its own client module.

---

## 2. Base URL, media types, conventions

- **Root URI:** `https://<management-server>/v1`
  - `management-server` = the virtual IP or resolvable name of Ops Center
    Administrator.
  - Example: `https://172.17.35.70/v1/compute/servers`
- **Never append a trailing slash** to any URI (explicit rule in the guide).
- JSON only, request and response. Responses use HAL (`application/hal+json`)
  with `_links` / `links` blocks carrying `self` hrefs.
- TLS: self-signed certs are common; `curl -k` ignores cert errors (same posture
  the plugin already uses for the array).
- **VSP One Block terminology:** the API keeps legacy terms even for VSP One
  Block — "External Parity Groups" == External Volume Groups, "Storage Advisor
  Embedded" == VSP One Block Administrator, "GUM" == Embedded Storage Manager
  (ESM) / Storage Management Controller (SMC).

---

## 3. Security & authentication

Two token mechanisms; a connector needs only the first for standalone use.

### 3a. `X-Auth-Token` (default local user / registered Active Directory)

1. `POST https://<mgmt-server>/v1/security/tokens`
   with HTTP Basic auth: `Authorization: Basic base64(user:password)`.
2. Read the **`X-Auth-Token`** response **header** (the token is returned in the
   header, *not* the body).
3. Send `X-Auth-Token: <token>` on every subsequent request.

```
curl -k -I --basic https://<mgmt-server>/v1/security/tokens -X POST -u sysadmin:<password>
   → X-Auth-Token: 3a22e682-5023-4a54-9f99-70f264555569
```

- **Token lifetime: 1200 s, sliding** — "if not used, the token expires in 1200
  seconds; if it is used for a REST call the expiry timer resets." Re-`POST` to
  get a new one after expiry. (Contrast: Common Services = 300 s fixed.)
- `GET /v1/security/tokens` returns the current token's `issuedAt`, `expiresAt`,
  `tenantId`, and `user.roles` (e.g. `ROLE_SYSTEM_ADMIN`, `ROLE_SECURITY_ADMIN`,
  `ROLE_STORAGE_ADMIN`).
- `DELETE /v1/security/tokens` revokes a token before it expires.

### 3b. `Authorization: Bearer` (via Ops Center Common Services / OpenID Connect)

- Obtain a bearer token from Common Services (see that extract), then send
  `Authorization: Bearer <token>`.
- **Requires NTP-synchronized clocks** between the Common Services and Ops
  Center Administrator servers.
- The **Token management API itself is not available** under Bearer auth — token
  CRUD only works with `X-Auth-Token`.

---

## 4. Roles / privileges

Access is role-gated; a connector's service account needs **Storage
administrator** for day-to-day provisioning, and **System administrator** if it
must register arrays/servers/switches itself.

| Role | Grants (relevant subset) |
|---|---|
| **System administrator** | add/admin/delete **servers, storage systems, fabric switches**, SNMP, tiers, parity groups; register Ops Center Protector |
| **Storage administrator** | add/admin/delete **pools, volumes** (create, attach to hosts, data protection), **port** configs |
| **Security administrator** | account domains, user→group role assignment |
| **Monitoring** | read-only everything |

Rule of thumb stated in the guide: **all GET** APIs are open to every role;
**POST/PATCH/DELETE** generally require Storage administrator (data-protection
section) or System administrator (server/storage-system/switch lifecycle).

---

## 5. HTTP semantics & the async job model

- **GET** — synchronous; returns the resource(s). Supports filtering/sorting:
  `GET /v1/jobs?q=status:(IN_PROGRESS OR SUCCESS) AND startDate:[now-1d TO now]&sort=startDate:asc`
  (filters combine with `AND`/`OR`, numeric ranges via `TO`).
- **POST / PATCH / DELETE** — **asynchronous**: they return a **job** object
  (HTTP 202) unless the response is a bare status code. The connector must poll
  the job to completion.
- **Status codes:** 200 OK, 201 Created (operation started), 202 Accepted
  (processing), 204 No content; 400 bad header, 401 unauthorized, 403 auth
  failed, 404 not found, 409 type conflict, 412 precondition failed, 502 service
  starting (retry), 503/504 unavailable/timeout (retry).

### Job object (poll `GET /v1/jobs/<jobId>`)

```json
{
  "jobId": "", "title": { "text": "", "messageCode": "", "parameters": {} },
  "user": "", "status": "IN_PROGRESS | SUCCESS | SUCCESS_WITH_ERROR | ...",
  "createdDate": 0, "startDate": 0, "endDate": 0, "parentJobId": null,
  "reports": [], "links": [ { "rel": "_self", "href": "/v1/jobs/<jobId>" } ],
  "tags": [], "isSystem": false
}
```

Async POST/DELETE return this shape; a connector polls `status` until it leaves
`IN_PROGRESS` (mirrors how the plugin already polls Configuration Manager
`/jobs/<id>` — see `RestClient.pm`). `GET /v1/jobs` lists/searches jobs.

---

## 6. Resource catalog (method · URI · role) — plugin-relevant subset

All paths are relative to `https://<mgmt-server>/v1`. `…Id` segments are
placeholders. This is the orchestration surface a connector would drive; the
full guide also covers parity groups, disks, NVM subsystems, tiers, virtual
storage machines, volume migration, fabric switches, monitoring, SNMP, and
account/user admin (out of scope for first-pass provisioning).

### Storage system management (multi-array)
| Operation | Method | URI | Role |
|---|---|---|---|
| List storage systems | GET | `/storage-systems` | any |
| Get storage system | GET | `/storage-systems/{storageSystemId}` | any |
| Get summary | GET | `/storage-systems/summary` | any |
| Get license info | GET | `/storage-systems/{storageSystemId}/settings/licenses` | any |
| Add storage system | POST | `/storage-systems` | System admin |
| Update / Delete | POST / DELETE | `/storage-systems/{storageSystemId}` | System admin |
| Switch access point to GUM | POST | `/storage-systems/{storageSystemId}/switch-access-point` | System admin |
| Refresh (rescan) | POST | `/storage-systems/refresh` | Storage/System admin |

### Pool management
| Operation | Method | URI | Role |
|---|---|---|---|
| List / Get / Summary | GET | `/storage-systems/{id}/storage-pools[/{poolId}|/summary]` | any |
| Create / Update | POST | `/storage-systems/{id}/storage-pools[/{poolId}]` | Storage admin |
| Delete | DELETE | `/storage-systems/{id}/storage-pools/{poolId}` | Storage admin |

### Volume management (per-array primitives)
| Operation | Method | URI | Role |
|---|---|---|---|
| List / Get / Summary | GET | `/storage-systems/{id}/volumes[/{volumeId}|/summary]` | any |
| Create a volume | POST | `/storage-systems/{id}/volumes` | Storage admin |
| Update a volume | POST | `/storage-systems/{id}/volumes/{volumeId}` | Storage admin |
| Delete a volume | DELETE | `/storage-systems/{id}/volumes/{volumeId}` | Storage admin |
| Shred / interrupt shred | POST | `/volume-manager/shred[/interrupt]` | Storage admin |

### Volume orchestration (`volume-manager`, bulk/atomic — the high-value surface)
| Operation | Method | URI |
|---|---|---|
| Create multiple volumes | POST | `/volume-manager/create` |
| **Attach** volumes to servers | POST | `/volume-manager/attach` |
| Attach + protect | POST | `/volume-manager/attach-protect` |
| **Create + attach + protect** (one call) | POST | `/volume-manager/create-attach-protect` |
| Update volumes | POST | `/volume-manager/update` |
| Delete volumes (bulk) | POST | `/volume-manager/delete` |
| Detach | POST | `/volume-manager/detach` |
| Detach from multiple servers | POST | `/volume-manager/detach-from-multiple-servers` |
| Edit LUN paths | POST | `/volume-manager/edit-lun-paths` |
| Edit namespace paths (NVMe) | POST | `/volume-manager/edit-namespace-paths` |
| Auto-select paths | GET | `/volume-manager/auto-path-select` |

### Host group management
| Operation | Method | URI |
|---|---|---|
| Get / list host groups | GET | `/storage-systems/{id}/host-groups[/{hostGroupId}]` |
| Create host groups | POST | `/host-group-manager/create` |
| Edit a host group | PATCH | `/storage-systems/{id}/host-groups/{hostGroupId}` |
| Add / remove volumes | POST | `/host-group-manager/{add-volumes|remove-volumes}` |
| Delete host groups | POST | `/host-group-manager/delete` |
| CHAP user add/update/delete | PATCH | `/storage-systems/{id}/host-groups/{hostGroupId}` |

### Server & server-group management (hosts as first-class objects)
| Operation | Method | URI |
|---|---|---|
| List / Get / Summary servers | GET | `/compute/servers[/{serverId}|/summary]` |
| Add / Update / Delete server | POST/POST/DELETE | `/compute/servers[/{serverId}]` |
| Delete multiple servers | POST | `/compute/servers/delete` |
| Update WWPNs | POST | `/compute/servers/{serverId}/update-wwpns` |
| Update iSCSI settings / NQNs | POST | `/compute/servers/{serverId}/{update-iscsi-settings|update-nqns}` |
| List attached volumes | GET | `/compute/servers/attached-volumes/?q=serverId:{id} AND storageSystemId:{id}` |
| Scan host groups | POST | `/compute/servers/scan-host-groups` |
| Use existing LUN paths | POST | `/compute/servers/create-similar-paths` |
| Server groups (CRUD, add/remove servers) | GET/POST/DELETE | `/compute/server-groups[/{serverGroupId}/...]` |

### Port management
| Operation | Method | URI |
|---|---|---|
| List / Get ports | GET | `/storage-systems/{id}/storage-ports[/{portId}]` |
| Update a port | POST | `/storage-systems/{id}/storage-ports/{portId}` |
| Port login info | GET | `/storage-systems/{id}/ports-login-information` |

### Data protection (snapshots / clones / HA / remote)
| Operation | Method | URI |
|---|---|---|
| Summaries | GET | `/data-protection/summary`, `/data-protection/storage-systems/{id}/summary` |
| List / Get replication groups | GET | `/storage-systems/{id}/replication-groups[/{rgId}|/summary]` |
| Create replication group | POST | `/storage-systems/{id}/replication-groups` |
| Add / remove volumes | POST | `/storage-systems/{id}/replication-groups/{rgId}/{add-volumes|remove-volumes}` |
| **Restore** a volume from snapshot | POST | `/storage-systems/{id}/volumes/{volumeId}/restore` |
| Update (clone/snap/HA) | PATCH | `/storage-systems/{id}/replication-groups/{rgId}` |
| Suspend / Resume | POST | `/storage-systems/{id}/replication-groups/{rgId}/{suspend|resume}` |
| Delete replication group | DELETE | `/storage-systems/{id}/replication-groups/{rgId}` |
| List volume pairs (+ primary/secondary/failed) | GET | `/storage-systems/{id}/volume-pairs[?q=...]` |

---

## 7. Key request/response shapes for a connector

### Create a volume — `POST /storage-systems/{id}/volumes`
```json
{
  "capacityInBytes": 0,            // Long, required
  "poolId": "",                    // String, required
  "dkcDataSavingType": "",         // NONE | COMPRESSION | DEDUPLICATION_AND_COMPRESSION
                                   //   (NONE not allowed on VSP One Block)
  "label": "",                     // ≤32 chars  ← plugin volume-name lives here
  "virtualStorageMachineId": "",   // optional VSM
  "tieringPolicyId": 0,            // 0–31
  "commandDevice": { "commandDeviceEnabled": false, "securityEnabled": false,
                     "userAuthenticationEnabled": false, "deviceGroupSettingEnabled": false },
  "drsEnabled": false, "t10PiEnabled": false
}
```
Returns a **job** (async). `label` is the hook for the plugin's `vm-<vmid>-…`
naming (still ≤32 chars, matching `Config.pm`'s `$MAX_LABEL_LEN`).

### Attach volumes to servers — `POST /volume-manager/attach`
```json
{
  "storageSystemId": "",
  "intendedImageType": "",         // host mode, e.g. "LINUX", "VMWARE_EX"
  "hostModeOptions": [],           // HMO numbers, or null to auto-select
  "enableZoning": false,           // ← automated SAN zoning (vs manual zoning prereq today)
  "enableLunUnification": false,
  "shareHgByAllServers": false,
  "hostGroupName": null,
  "volumes": [ { "volumeId": 0, "lun": 0, "namespaceId": null,
                 "virtualIdRange": { "from": 0, "to": 0 } } ],
  "ports": [ { "serverId": 0, "serverWwns": [""], "iscsiInitiatorNames": [""],
               "portIds": ["CL8-C","CL6-D"] } ],
  "nvmSubsystemName": "", "nvmServers": { "ids": [] },
  "nvmSubsystemPortIds": [""], "nvmSubsystemHostMode": "", "nvmSubsystemHostModeOptions": []
}
```
`create-attach-protect` takes the union of create + attach + a protection block,
collapsing "1 LUN per virtual disk + map it + snapshot policy" into one job —
directly aligned with this project's "1 LUN per virtual disk" goal.

### Create a replication group (snapshots/clones) — `POST /storage-systems/{id}/replication-groups`
```json
{
  "name": "", "type": "",          // SNAP | SNAP_ON_SNAP | CLONE | HA | ASYNC_REMOTE_CLONE
  "consistent": false,
  "numberOfCopies": 1,             // SNAP only, 1–1024
  "schedule": { "recurringUnit": "HOURLY|DAILY|WEEKLY|MONTHLY",
                "recurringUnitInterval": 1, "hour": 0, "minute": 0,
                "dayOfWeek": null, "dayOfMonth": null },   // required for SNAP/SNAP_ON_SNAP
  "primaryVolumeIds": [], "targetPoolId": 0,
  "secondaryStorageSystemId": "", "secondaryVolumeLabel": "",
  "drsSetting": "", "capacitySavingSetting": "",
  "journal": { "primaryJournalPoolId": 0, "secondaryJournalPoolId": 0,
               "size": 0, "unit": "", "journalLabel": "" }
}
```
`type: SNAP` ≈ Thin Image snapshots (PVE snapshots); `type: CLONE` ≈ full clones
(PVE linked/full clone). Restore-from-snapshot is the separate
`POST /storage-systems/{id}/volumes/{volumeId}/restore`.

---

## 8. cURL pattern (for a connector / manual testing)

```
# 1. get token (header, not body)
curl -k -I --basic -X POST -u sysadmin:<pw> https://<mgmt>/v1/security/tokens

# 2. use it
curl -k 'https://<mgmt>/v1/volume-manager/attach' -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Auth-Token: 3a22e682-5023-4a54-9f99-70f264555569' \
  -d '{ "storageSystemId":"410395", "intendedImageType":"LINUX", "hostModeOptions":[],
        "volumes":[{"volumeId":649,"lun":1111}],
        "ports":[{"serverId":3,"serverWwns":[],"portIds":["CL8-C","CL6-D"]}],
        "enableZoning":false, "enableLunUnification":false }'
```

---

## 9. Bottom line for a future Ops Center connector

- **Different auth:** `POST /v1/security/tokens` (Basic) → read `X-Auth-Token`
  header → send `X-Auth-Token`; sliding **1200 s** TTL. Add a renew-on-expiry
  loop. Optional Bearer/OIDC path via Common Services (needs NTP sync).
- **Different addressing:** every storage call carries a `storageSystemId`; one
  endpoint manages many arrays. The connector would map a PVE storage to a
  `(management-server, storageSystemId)` pair instead of one array IP.
- **Different host model:** hosts are `server`/`server-group` objects with WWPNs;
  zoning can be **automated** (`enableZoning: true`) rather than relying on the
  manual zoning prerequisite the plugin documents today.
- **Higher-level orchestration:** `create-attach-protect` does in one async job
  what the plugin currently sequences across several Configuration Manager
  calls — potentially simpler, but with less fine-grained control and a
  hard dependency on an Ops Center Administrator deployment.
- **Async everywhere:** reuse the existing job-polling discipline (poll
  `/v1/jobs/<jobId>` until `status != IN_PROGRESS`).
- **Not a requirement today.** The default, validated path stays direct-to-array
  (Configuration Manager). This connector matters only when a customer
  standardizes on Ops Center Administrator as the central management plane and
  wants the plugin to route through it. Treat as a future, opt-in backend
  (`api_type`/platform selector) alongside the current client, not a
  replacement.
