# Brocade Fabric OS REST API — extract for FC zoning during bring-up

Distilled from the **Broadcom *Brocade Fabric OS REST API Reference Manual, 10.0.x***
(`FOS-100x-REST-API-RM101`, Dec 04 2025; page cites below). Only the parts relevant to
**this project's testing/bring-up** are kept.

## Why this is here (scope)

The plugin manages the **Hitachi array**, not the SAN switch. But the plugin's data path
depends on **FC zoning** between each PVE node's HBA WWPNs and the array's target ports —
an *external* prerequisite (see `prerequisites.md` §4, the test plan's safety control S4,
and bring-up blocker B4: "nodes logged into the fabric but not yet zoned to the array").

The lab's SAN switch is a **Brocade** FC switch running **Fabric OS** with **Virtual
Fabrics** enabled (dual fabric = two logical switches). Its **FOS REST API** lets us
**script and verify that zoning** instead of doing it by hand on the CLI — which is the
value of this manual to the bring-up. (Automated zoning is *not* in the plugin's scope
today; this is an operator/test aid.)

**Applicability / version:** the REST model (`/rest/running/brocade-*`, YANG-modelled) is
stable across **FOS 9.x and 10.x**. Session-less GET requires **FOS 9.1+** (p34). The lab
switch runs an older FOS than this 10.0.x manual, so treat newer-only modules/fields as
"verify on the switch"; the **login + zoning** model documented here is identical on both.

---

## 1. Authentication & sessions (pp. 32–35)

**Login** — `POST https://<switch>/rest/login` with HTTP Basic auth (no body). On success
the **session token is returned in the `Authorization` *response* header** as
`Custom_Basic <token>`; reuse it on every subsequent call.

```bash
# capture the Authorization response header
curl -sk -D - -o /dev/null -u 'USER:PASS' \
  -H 'Accept: application/yang-data+json' \
  -X POST https://<switch>/rest/login
# -> Authorization: Custom_Basic Tk0ZmY2Zjg3...
```

**Logout** — `POST https://<switch>/rest/logout` with the token (frees the session; 204).

**Session limit (p34, p52):** default **3** concurrent REST sessions, configurable **1–10**,
shared across *all* REST clients of the switch (SANnav, monitoring, scripts). Exceeding it
returns HTTP 403 `"Max limit for REST sessions reached"` (error-code 14). Always log out;
sessions are scarce and an open one also holds any zone transaction (below). Leaked sessions
(scripts that abort before logout) block everyone until they age out.

**Managing sessions from the switch CLI** (`mgmtapp`, p50–52) — for when the cap is exhausted:

```
mgmtapp --showsessions                 # list active REST sessions: time, source IP, user, app, session-id
mgmtapp --terminate <session_id>       # kill one stale session (use the id from --showsessions)
mgmtapp --show                         # REST config incl. configured "Session Count" (the max)
mgmtapp --config -maxrestsession 10    # raise the cap (1..10, default 3) — recommended for clusters/automation
```

**Session-less GET (pp. 34–36):** FOS 9.1+ allows a one-shot authenticated GET (login +
GET + logout in one request) — handy for read-only discovery:

```bash
curl -sk -u 'USER:PASS' -H 'Accept: application/yang-data+json' \
  https://<switch>/rest/running/brocade-chassis/chassis
```

**Expired password (p34):** can be changed with a `PATCH` *before* login.

## 2. Request basics (pp. 32, 39–40)

- **Base URIs:** `…/rest/running/<module>/<container>` for config/state;
  `…/rest/operations/<rpc>` for RPC-style actions.
- **Media types:** default is `application/yang-data+xml`. **For JSON you must send both**
  `Accept: application/yang-data+json` **and** `Content-Type: application/yang-data+json`.
- **Naming:** add header `Camel-Case-Mode: on` for `camelCase` field names; omit (or `off`)
  for `kebab-case` (the default the examples use).
- **Methods:** GET, HEAD, OPTIONS, POST, PATCH, DELETE.
- **Status codes (p40):** 200 OK / 201 Created / 204 No Content (success); 400 bad request,
  403 forbidden, 404 not found, 415 unsupported media, 500 operation failed (body carries
  the FOS error), 502/503 busy.
- **RBAC (pp. 36–37):** zoning calls belong to the **`Zoning`** MOF class and run in the
  **VF (Virtual Fabric) context**; chassis-level calls need chassis permissions.

## 3. Virtual Fabrics — pick the logical switch with `?vf-id=<FID>`

With VF enabled, each **logical switch = one fabric**, identified by a **Fabric ID (FID)**.
Zoning and name-server are **per logical switch**, so append a **`?vf-id=<FID>` query
parameter** to the URL on *every* VF-scoped call (GET, POST, PATCH, DELETE) to target the
right fabric — e.g. `…/effective-configuration?vf-id=2`.

> **Important (verified on FOS 9.2.1b):** use the **`?vf-id=` query parameter**, not a
> `vf-id:` *header*. The header is silently ignored — all calls return the *home* VF, so a
> header-based "FID 2" query returns FID 1's data. The manual shows the query-param form
> (`…/fabric-switch?vf-id=10`). Omitting it entirely also targets the home VF.

```
GET /rest/running/brocade-fibrechannel-logical-switch/fibrechannel-logical-switch   # lists all FIDs (chassis-wide)
```

## 4. Verify fabric logins (name server) — do this before zoning

The name server lists every device **currently logged into a fabric** (HBA initiators and
array targets), so you can confirm cabling/link before zoning and grab exact WWPNs:

```
GET /rest/running/brocade-name-server/fibrechannel-name-server?vf-id=<FID>
```

Key fields per entry: `port-id` (FCID), `port-name` (the **WWPN**), `node-symbolic-name`
(HBA model/host hint), `fc4-features` (`FCP-Initiator` vs `FCP-Target`). A node WWPN
appearing here means the link is up; it still needs a **zone** with the array target ports
before the host can see LUNs (when an effective cfg is active, default-zone access is off).

## 5. Zoning model (pp. 37–39)

Two resources under **`brocade-zone`**:

- **`defined-configuration`** — the saved zone DB you edit: `zone`, `alias`, `cfg`
  (a cfg is a named set of `member-zone`s).
- **`effective-configuration`** — the currently enforced cfg, plus the **`checksum`**,
  `cfg-name` (active cfg), `default-zone-access`, `transaction-token`, and DB size counters.

A standard zone: `zone-type-string: "zone"`, `member-entry.entry-name[]` = a list of
**WWPNs** (`10:00:…` colon-separated), domain,index pairs, or alias names.

### Transaction rules (pp. 38–39) — read before editing
- **Checksum gate:** `save` and `enable` require the current **MD5 zone-DB `checksum`**;
  a stale checksum makes the commit fail (prevents overwriting newer changes).
- **Max transaction size:** 4 MB zone DB.
- **`PATCH` replaces the *entire* leaf-list** it targets — to edit a zone's members or a
  cfg's member-zones you must resend the **full** desired list (existing + new).
- **5-minute transaction timer, tied to the REST session ID.** Logging out, or another
  client/CLI (`cfgtransabort`) grabbing the lock, **cancels** your open transaction.
- **Concurrency:** a second opener gets `error-code -3`, `"There is an outstanding admin
  transaction, and you are not the owner …"` (pp. 90–91).

## 6. Zoning workflow (worked, from pp. 77–89)

All URIs are `…/rest/running/brocade-zone/…`; append **`?vf-id=<FID>`** to each for the
target fabric. Writes (POST/PATCH/DELETE) need a **real session** (session-less is GET-only),
so log in for the token and reuse it. Two gotchas verified on FOS 9.2.1b:
- **Quote the token header.** The login returns `Authorization: Custom_Basic <hash>` — the
  value contains a space, so pass it as one quoted arg: `-H "Authorization: $TOK"`. Unquoted,
  the shell word-splits it and FOS replies `"Invalid auth-type"` (error-code 20).
- **`cfgadd` semantics via PATCH replaces the whole `member-zone` leaf-list** — GET the cfg's
  current `zone-name` list first and PATCH the *union* (existing + new), or you drop the
  existing zones. (Add your new single-initiator zones while preserving every pre-existing
  production zone in the cfg.)

**a. Record the current checksum** (needed to commit later):
```
GET …/effective-configuration/checksum        -> { "effective-configuration": { "checksum": "<md5>" } }
```

**b. Create a zone** (`POST …/defined-configuration/zone`, 201):
```json
{ "zone": [ {
    "zone-name": "pve03_arrayA",
    "zone-type-string": "zone",
    "member-entry": { "entry-name": [
      "10:00:00:10:9b:00:00:01",   // node HBA WWPN (initiator)
      "50:06:0e:80:00:00:00:00"    // array target port WWPN
    ] } } ] }
```

**c. Add the zone to a cfg** — `PATCH …/defined-configuration/cfg` (overwrites the whole
`member-zone` list → include all zones already in the cfg plus the new one):
```json
{ "cfg": [ { "cfg-name": "FabricA_cfg",
             "member-zone": { "zone-name": [ "zoneA", "zoneB", "pve03_arrayA" ] } } ] }
```
(Use `POST …/defined-configuration/cfg` to create a new cfg; `PATCH …/defined-configuration/zone`
to edit a zone's members — again, full member list.)

**d. Save the defined config** — `PATCH …/effective-configuration/cfg-action-v2/save`
with the checksum from step a (204):
```json
{ "checksum": "<md5 from step a>" }
```

**e. Re-read the checksum** (it changed after save): `GET …/effective-configuration/checksum`.

**f. Enable (cfgenable) the cfg** — `PATCH …/effective-configuration/cfg-name/<cfg>` with
the **new** checksum (204):
```json
{ "checksum": "<md5 from step e>" }
```

**g. Verify** — `GET …/effective-configuration/enabled-zone/zone-name/<zone>` or
`GET …/effective-configuration`.

**Other actions**
- **Delete a zone:** `DELETE …/defined-configuration/zone/zone-name/<name>` then `save`.
- **Abort pending edits:** `PATCH …/effective-configuration/cfg-action-v2/transaction-abort`.
- **Who holds the lock / is a txn open:** `GET …/effective-configuration/transaction-token`
  (`0` = none).

## 7. Practical guidance for the bring-up

- **Single-initiator zoning** (one HBA initiator + its array target ports per zone) — matches
  `prerequisites.md` §4 and keeps the DB clean. One zone per node-HBA per fabric.
- **Per fabric:** run steps b–f **twice**, once per logical switch (`vf-id` A, then B), zoning
  that fabric's node WWPN(s) to that fabric's array target ports.
- **Safety:** zoning is fabric-wide and production-shared — only ADD zones for the PVE nodes;
  never edit/remove existing zones; always commit with the freshly-read checksum; abort on any
  doubt. Coordinate with the SAN admin and do it in the agreed change window (test plan S4/S6).
- After zoning, install `multipath-tools` + the plugin on the nodes; the array LUNs appear once
  the plugin creates host groups and maps LUNs.
