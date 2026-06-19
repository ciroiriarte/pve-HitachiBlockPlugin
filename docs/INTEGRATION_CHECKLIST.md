# Hardware Integration Checklist (VSP E590H bring-up)

This plugin was developed against the Hitachi Configuration Manager REST API
**specification**, not against a live array. Every array- and host-facing behavior
below is therefore an *assumption* that must be validated on real hardware before the
plugin is trusted in production. The unit suite (`make test`) proves internal logic
and PVE contracts; it mocks the array, the REST client, and the multipath/sysfs layer,
so it cannot catch a wrong API field, a model-specific WWID layout, or a Thin Image
behaviour that differs from the docs.

Target test system: **VSP E590H** (embedded Configuration Manager REST API on the
controller GUM) with a Proxmox VE cluster.

For each item: the **assumption**, **where it lives** in the code, **how to verify**,
the **expected** result, and **if wrong** what to change. Work top-to-bottom — later
phases depend on earlier ones passing.

Convention for the manual `curl` checks below:

```bash
MGMT=10.0.1.210            # controller GUM management IP
SID=716000123456           # storageDeviceId (NOT the bare serial)
BASE="https://$MGMT/ConfigurationManager/v1/objects/storages/$SID"
# Log in (self-signed cert -> -k); capture the session token:
TOK=$(curl -sk -u USER:PASS -X POST \
  https://$MGMT/ConfigurationManager/v1/objects/sessions \
  -H 'Content-Type: application/json' -d '{}' | jq -r .token)
AUTH="Authorization: Session $TOK"
```

---

## Reference-doc findings (spec-confirmed, still verify behaviour on hardware)

Extracted from the vendor docs under `reference/` (see `docs/reference/*.md`). These
move several assumptions from "guess" to "confirmed by spec" — but spec ≠ the specific
E590H microcode, so the hardware checks below still apply.

- **CoW linked clone = `autoSplit=true`, `isClone` unset** (REST API guide pp. 508–513).
  A split Thin Image pair leaves the S-VOL in `PSUS`: **host R/W and still sharing
  unchanged blocks** with the P-VOL via the pool. `isClone=true` is the opposite (full
  copy then auto-delete the pair). **Code corrected** (`clone_image` now uses
  `auto_split => 1`; an earlier commit wrongly used `0`, which leaves an un-split,
  non-R/W S-VOL). → Phase 4.2.
- **`byteFormatCapacity` is base-1024** (`"1G"` = 1 GiB); `blockCapacity` = 512-byte
  block count for exact sizing. Our `"<MB>M"` is therefore MiB and round-trips
  correctly — but switching create/expand to `blockCapacity`/`additionalBlockCapacity`
  would remove rounding ambiguity (recommended improvement). → Phase 2.1.
- **Pool capacities are in MB = MiB (base-1024)** — `status()`'s `*1024*1024` is correct.
  **CONFIRMED on the E590H (2026-06-19 discovery):** `usedPoolCapacity` is **null**; only
  `totalPoolCapacity`, `availableVolumeCapacity`, and `usedCapacityRate` are populated.
  `status()` **fixed** to derive `used` = `usedPoolCapacity` when present, else
  `total - availableVolumeCapacity`, else `total * usedCapacityRate/100`. → Phase 2.4.
- **LDEV `label` max = 32 chars** (confirmed) → our `$MAX_LABEL_LEN = 32` is right.
- **WWID/NAA:** the array returns the real `naaId` on **`GET /ldevs/{id}`** (not on
  `/luns`); the Linux multipath WWID is `3` + `naaId`. **Code improved** to read
  `naaId` from the array (with the synth/sysfs path as fallback). → Phase 3.2.
- **Async jobs:** `jobId` + `self` link in the 202 body; poll `GET /jobs/{id}`;
  `state` ∈ Queued/Started/StorageAccepted/Succeeded/Failed/Unknown; new resource id in
  `affectedResources[0]` (no `operationDetails[].resourceId`). Our `_wait_for_job`
  matches; the speculative `Location`-header branch is harmless (doc shows body `jobId`).
- **Snapshot S-VOL allocation:** a Thin Image pair may be created **without** an S-VOL
  (snapshot-data-only); an S-VOL is assigned later for read access. Our
  `volume_snapshot` creates a pair without an explicit S-VOL and then reads
  `svolLdevId` from it — verify the array returns/allocates one, or allocate the S-VOL
  explicitly. → Phase 4.1.

---

## Phase 0 — API reachability & identity

### 0.1 REST API base path / version
- **Assumption:** the array serves `/ConfigurationManager/v1/objects/storages/<storageDeviceId>/…` on the embedded GUM (NOT the `/ConfigurationManager/simple/v1/…` "Storage Advisor Embedded" object model).
- **Code:** `RestClient::_build_base_url`, `RestClient::new`.
- **Verify:** `curl -sk -H "$AUTH" "$BASE/pools" | jq .` returns a `data` array.
- **Expected:** HTTP 200 with pool objects.
- **If wrong:** if only the `simple/v1` API exists on the E590H, the object model differs (volumes/servers instead of ldevs/host-groups/luns) and a larger rework is needed — escalate before proceeding.

### 0.2 storageDeviceId format
- **Assumption:** `storage_id` is the 12-digit `storageDeviceId`, not the bare serial.
- **Code:** `storage_id` config property; `RestClient::new`.
- **Verify:** `curl -sk -H "$AUTH" https://$MGMT/ConfigurationManager/v1/objects/storages | jq '.data[].storageDeviceId'`.
- **Expected:** a 12-digit id; matches what you configured.
- **If wrong:** correct `storage_id` in `storage.cfg`; update the docs example.

### 0.3 Port & connection mode
- **Assumption:** embedded/direct REST API on **443** (`platform vsp_e`); a dedicated Ops Center CM server would use 23451 (`platform vsp_g` or explicit `mgmt_port`).
- **Code:** `Config::%PLATFORM_DEFAULTS`, `HitachiBlockPlugin::_get_client`.
- **Verify:** the `curl` in Phase 0 succeeds on 443.
- **If wrong:** set `mgmt_port`, or pick the platform whose default matches.

### 0.4 Session token format & keepalive
- **Assumption:** login returns `{token, sessionId}`; subsequent calls use `Authorization: Session <token>`; keepalive is `PATCH /sessions/<id>`.
- **Code:** `RestClient::login`, `RestClient::keepalive`, `RestClient::_request`.
- **Verify:** the `$TOK` login above works and a `PATCH` on the session returns 200.
- **If wrong:** adjust the auth header scheme / field names.

---

## Phase 1 — Multi-controller redundancy

### 1.1 Per-controller management endpoints
- **Assumption:** each controller exposes its own GUM management IP; `mgmt_ip` accepts a comma-separated list, OR a single floating VIP fails over array-side.
- **Code:** `RestClient::new` (endpoint list), `Config::validate_config`.
- **Verify:** confirm both controller IPs answer the Phase-0 `curl`. Determine whether your array uses two IPs or one VIP.
- **If wrong:** N/A — config-only.

### 1.2 Transport-failure detection & failover
- **Assumption:** LWP marks a connect/timeout failure with `Client-Warning: Internal response`, which the client uses to fail over to the next endpoint and re-authenticate.
- **Code:** `RestClient::_is_transport_error`, `_switch_endpoint`, `login`, `_request`.
- **Verify:** with two endpoints configured, block/҂down CTL1's management IP (firewall rule or pull the cable), then run any `pvesm`/`qm` operation. It should transparently use CTL2.
- **Expected:** operation succeeds via the survivor; re-login happens on CTL2.
- **If wrong:** adjust `_is_transport_error` to match how LWP surfaces the failure on this stack (check `$res->code`, `$res->message`, `$res->header('Client-Warning')`).

### 1.3 Async job on a dead controller
- **Assumption:** an async job lives on the controller that started it; if that controller dies mid-op the operation fails loudly and rolls back (rather than polling a controller that never had the job).
- **Code:** `RestClient::_wait_for_job`, the rollback blocks in `alloc_image`/`clone_image`/etc.
- **Verify:** start a long array op (large clone) and fail the controller mid-flight; confirm the operation errors and leaves no ghost LDEV (check `hitachiblock-repl orphans`).
- **If wrong:** revisit job-affinity handling.

---

## Phase 2 — Provisioning (alloc / size / label)

### 2.1 LDEV create body & size unit (`byteFormatCapacity`)
- **Assumption:** `POST /ldevs` with `byteFormatCapacity: "<MB>M"` is interpreted in **base-1024 (MiB)**, round-tripping consistently with how the plugin reports size back (`size_mb * 1024 * 1024`).
- **Code:** `RestClient::create_ldev`, `HitachiBlockPlugin::alloc_image`, `_ldev_size_mb`, `volume_size_info`.
- **Verify:** allocate a 1 GiB disk; `curl -sk -H "$AUTH" "$BASE/ldevs/<id>" | jq '{blockCapacity, byteFormatCapacity}'`. Compute `blockCapacity*512` and compare to 1 GiB exactly.
- **Expected:** exactly 1073741824 bytes (or the documented rounding).
- **If wrong (off by 1.024×):** the array treats `M` as base-1000. Switch `create_ldev`/`expand_ldev` to send `blockCapacity` (512-byte blocks) for exact sizing, and re-run the unit test expectations in `restclient_mock.t`.

### 2.2 LDEV id allocation range
- **Assumption:** `ldev_range` scan + explicit `ldevId` on create; the array rejects a duplicate explicit id.
- **Code:** `_next_ldev_in_range`, `RestClient::create_ldev`.
- **Verify:** configure a small `ldev_range`, allocate concurrently from two nodes, confirm no collision and a clean error when the range is exhausted.

### 2.3 LDEV label & 32-char limit
- **Assumption:** labels are set via `PATCH /ldevs/<id>` `{label}`, limited to 32 chars; long storeids fall back to a hashed prefix.
- **Code:** `Config::make_label`/`label_prefix`, `RestClient::set_ldev_label`.
- **Verify:** set a 32-char label and a 33-char one; confirm the array's real limit and that orphan detection still matches hashed labels.
- **If wrong:** adjust `$MAX_LABEL_LEN` in `Config.pm`.

### 2.4 status() pool capacity units — ✅ CONFIRMED & FIXED (E590H, 2026-06-19)
- **Assumption:** `totalPoolCapacity`/`usedPoolCapacity` are in **MB**.
- **Finding:** units are MB (correct), **but `usedPoolCapacity` is returned as `null`** on the
  E590H microcode — only `totalPoolCapacity`, `availableVolumeCapacity`, and `usedCapacityRate`
  are populated. The old code read `usedPoolCapacity` directly, so it reported the pool as
  **0% used / all-free** (hides over-provisioning and capacity alarms).
- **Code:** `HitachiBlockPlugin::status` — now derives `used` = `usedPoolCapacity` when present,
  else `total - availableVolumeCapacity`, else `total * usedCapacityRate/100` (clamped 0..total).
  Covered by `plugin.t` `status_pool_used_logic` and `restclient_mock.t`.
- **Verify:** `curl -sk -H "$AUTH" "$BASE/pools/<id>" | jq '{totalPoolCapacity, usedPoolCapacity, availableVolumeCapacity, usedCapacityRate}'`; confirm `pvesm status` used/free match the array GUI.

---

## Phase 3 — Data path (mapping, multipath, WWID)

### 3.1 Host group + WWN + LUN mapping
- **Assumption:** `host-groups`, `host-wwns`, `luns` resources; host mode `LINUX/IRIX`; `hostGroupNumber`/`portId` shapes as coded.
- **Code:** `RestClient::create_host_group`/`add_wwn_to_host_group`/`map_lun`/`list_luns`, `HitachiBlockPlugin::_ensure_host_groups`/`_map_lun_to_local`.
- **Verify:** on `activate_storage`, confirm a `PVE_<host>` host group appears on each target port with the node's FC WWNs; allocate a disk and confirm the LUN path is created.
- **If wrong:** adjust resource bodies / host-mode value for the E590H.

### 3.2 WWID synthesis vs real page-83
- **Assumption:** the device WWID is `naa.60060e80<serial><ldev>…`; if the synthesized value doesn't resolve, `discover_wwid` reads the real page-83 id from sysfs.
- **Code:** `Multipath::ldev_to_wwid`, `discover_wwid`, `HitachiBlockPlugin::_resolve_wwid`.
- **Verify:** allocate a disk, then `multipath -ll` and `/lib/udev/scsi_id -g -u -d /dev/sdX`; compare to the synthesized WWID.
- **Expected:** synthesized == real, OR `discover_wwid` self-corrects and the volume still activates.
- **If wrong:** fix the NAA byte layout in `ldev_to_wwid` for this model (the self-correcting path is the safety net, but a correct synth avoids an extra rescan).

### 3.3 find_multipaths strict / WWID whitelisting
- **Assumption:** PVE default `find_multipaths strict` requires `multipath -a <wwid>`; the plugin does this on activate and `multipath -w` on free.
- **Code:** `Multipath::whitelist_wwid`, `wait_for_device`, `remove_device`.
- **Verify:** with the stock multipath config, allocate a disk and confirm `/dev/mapper/3<wwid>` appears and is listed in `/etc/multipath/wwids`; free it and confirm the entry is removed.
- **If wrong:** confirm `multipath -a/-w` flags on this multipath-tools version; adjust the shipped `multipath.conf.d/hitachiblock-vsp.conf` device stanza (vendor/product strings must match `INQUIRY`).

### 3.4 Device stanza match
- **Assumption:** the array reports `vendor HITACHI`, `product OPEN-V`.
- **Code:** `conf/multipath.conf.d/hitachiblock-vsp.conf`.
- **Verify:** `multipath -v3` / `sg_inq /dev/sdX`; confirm vendor/product.
- **If wrong:** update the stanza so ALUA/path settings apply.

### 3.5 Resize (array + host)
- **Assumption:** `expand_ldev` with `additionalByteFormatCapacity`; host picks it up via SCSI rescan + `multipathd resize map`.
- **Code:** `RestClient::expand_ldev`, `Multipath::resize_device`, `HitachiBlockPlugin::volume_resize`.
- **Verify:** grow a disk online; confirm the guest sees the new size after `qm resize`.

---

## Phase 4 — Snapshots & CoW linked clones (highest-risk new behaviour)

### 4.1 Thin Image snapshot create/restore/delete
- **Assumption:** `POST /snapshots` creates a TI pair; `actions/restore` rolls back; `DELETE /snapshots/<id>` removes it. Snapshot group naming `pve_<storeid>_<ldev>_<snap>`.
- **Code:** `RestClient::create_snapshot`/`restore_snapshot`/`delete_snapshot`, `HitachiBlockPlugin::volume_snapshot*`.
- **Verify:** `qm snapshot`, write data, `qm rollback`, confirm the data reverts; `qm delsnapshot`.

### 4.2 **CoW linked clone (autoSplit=true)** — confirm it is actually CoW
- **Assumption:** a Thin Image pair created **split** (`autoSplit=true`, `isClone` unset) leaves the S-VOL in `PSUS` — host-R/W yet still sharing unchanged blocks with the P-VOL via the pool (copy-on-write) — a persistent, space-efficient clone that stays usable indefinitely while sharing blocks with its base.
- **Code:** `HitachiBlockPlugin::clone_image` (`auto_split => 1`), `RestClient::create_snapshot`.
- **Verify:** linked-clone a template; immediately check pool usage (should NOT jump by the full disk size); `curl -sk -H "$AUTH" "$BASE/snapshots?pvolLdevId=<base>" | jq` and confirm the pair is a live **split** CoW pair (S-VOL in `PSUS`, sharing blocks) — NOT a full `isClone` copy that auto-deletes the pair. Run the clone for an extended period and confirm it stays valid.
- **Expected:** instant clone, minimal space, S-VOL persists in `PSUS` and is host-readable/writable while sharing unwritten blocks.
- **If wrong (array full-copies, deletes the pair, or the S-VOL becomes invalid / not host-R/W):** the E590H may require a different primitive for persistent CoW clones (e.g. a TI "cascade"/clone attribute, or it may only support snapshot-style pairs). Re-map `clone_image` to whatever the array's true thin-clone primitive is, and revisit the dependency model.

### 4.3 Clone/snapshot dependency guards
- **Assumption:** deleting a base/source or its snapshot while a linked clone exists must be refused.
- **Code:** `Config::find_dependents`/`find_snapshot_dependents`; guards in `free_image`/`create_base`/`rename_volume`/`volume_snapshot_delete`.
- **Verify:** create a linked clone, then attempt to delete the base and the source snapshot — both must fail with a clear error; delete the clone, then the source succeeds.

### 4.4 Consistency-group snapshot + rollback
- **Assumption:** shared snapshot group + `isConsistencyGroup` makes a CG; partial failures roll back.
- **Code:** `HitachiBlockPlugin::volume_snapshot_consistency_group`.
- **Verify:** snapshot a multi-disk VM as a group; induce a mid-group failure (e.g. invalid pool) and confirm the already-created pairs are removed.

---

## Phase 5 — Advanced services

### 5.1 QoS
- **Assumption:** `PATCH /ldevs/<id>` with `upperIops`/`upperTransferRate`/`lowerIops`/`lowerTransferRate`/`responsePriority`.
- **Code:** `RestClient::set_ldev_qos`, `HitachiBlockPlugin::_qos_from_scfg`.
- **Verify:** set `qos_upper_iops`, allocate a disk, confirm the limit appears on the LDEV in the GUI and is enforced.
- **If wrong:** QoS may be a separate resource/path on this microcode — adjust `set_ldev_qos`.

### 5.2 Replication (TC / UR / GAD)
- **Assumption:** `remote-mirror-copypairs`, `remote-storages` resources.
- **Code:** `RestClient::*_remote_copy_pair`, `register_remote_storage`; `bin/hitachiblock-repl`.
- **Verify:** with a second array, `hitachiblock-repl create-tc …`, check pair status, split/resync/delete. Confirm these resources exist on the embedded API (they may require Ops Center CM rather than the embedded GUM).
- **If wrong:** document that replication needs Ops Center CM; gate the CLI accordingly.

### 5.3 Zero-page reclaim / pool migration
- **Assumption:** `actions/discard-zero-page`, `actions/change-pool`.
- **Code:** `RestClient::reclaim_zero_pages`/`migrate_ldev`.
- **Verify:** enable `discard_zero_page`, deactivate a volume, confirm pool usage drops; migrate an LDEV between pools.

---

## Phase 6 — PVE integration & migration

### 6.1 api() version vs target PVE — ✅ CONFIRMED (PVE 9.2, 2026-06-19)
- **Status:** `api()` returns **14**, matching PVE 9.2's `APIVER 14` (`APIAGE 5`, window 9..14).
  The plugin loads with **no advisory**; `PVE::Storage::Plugin::sensitive_properties("hitachiblock")`
  reports `password`. The authoritative API contract is the in-tree `PVE::Storage::Plugin`
  perldoc — the public wiki is high-level/stale (documents no APIVER, none of the v11–14 methods).
- **Code:** `HitachiBlockPlugin::api` (=14), `plugindata` (`sensitive-properties`),
  `on_add_hook`/`on_update_hook` (`%sensitive`), `volume_qemu_snapshot_method` ('storage').
  `qemu_blockdev_options` uses the base default (driver=host_device for `/dev/mapper/<wwid>`).
- **Verify on a node:** `perl -e 'use PVE::Storage::Plugin; print PVE::Storage::Plugin::APIVER, "/", PVE::Storage::Plugin::APIAGE, "\n"'`
  and `journalctl -u pvedaemon` — no "older/unsupported storage API" line after a reload.
- **If a future PVE raises APIVER:** re-verify overridden method signatures against the new
  perldoc, then bump `api()` in lockstep (it must stay within `APIVER-APIAGE .. APIVER`).

### 6.2 Cluster registry lock on real pmxcfs
- **Assumption:** `cfs_lock_storage` serializes registry writes cluster-wide.
- **Code:** `Config::_run_locked`/`_use_cluster_lock`.
- **Verify:** allocate disks concurrently from two nodes; confirm no lost registry updates (count entries vs. allocations).

### 6.3 Disk migration matrix
- **Assumption:** Move Storage (path-based) both directions hot/cold; `storage_migrate` (export/import) for offline cross-node.
- **Code:** `volume_export`/`volume_import`; see `docs/operations.md` § Disk Migration.
- **Verify:** move a qcow2 disk onto a LUN (online + offline), and a LUN disk to a file store; offline-migrate a VM to a node without the storage.

### 6.4 map_volume / rename_volume
- **Assumption:** PVE-8 map hooks and disk reassignment work.
- **Code:** `map_volume`/`unmap_volume`/`rename_volume`.
- **Verify:** `qm disk reassign` between two VMs; confirm the LDEV is relabelled and the registry entry renamed.

---

## Sign-off

A phase is "passed" only when verified on the E590H, not by `make test`. Record results
(date, microcode/DKCMAIN version, PVE version, pass/fail, deviations) alongside this file
or in `t/integration/`. Until Phase 4.2 (CoW linked clone) and Phase 2.1 (size unit) are
confirmed, treat clone space-efficiency and exact disk sizing as unverified.
