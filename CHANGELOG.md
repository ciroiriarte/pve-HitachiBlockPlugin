# Changelog

## [1.2.0~alpha12] - 2026-06-20

> **Alpha pre-release** — web UI integration so the storage type is consistent
> across the cluster and creatable from the GUI.

### Added
- **Web UI (manager6) integration.** Ships a JS module
  (`/usr/share/pve-manager/js/pve-storage-hitachiblock.js`) that registers the
  `hitachiblock` type with the PVE manager UI. The type now renders as
  **"Hitachi Block"** in *Datacenter → Storage* (instead of the raw
  `hitachiblock` token) and appears in the **Add** storage drop-down with a full
  create/edit dialog: management endpoint, storage device ID, DP pool, target FC
  ports, credentials and content, plus advanced platform / management port /
  snapshot pool / host-mode / LDEV range / clone speed / QoS / port-scheduler /
  zero-page reclaim / host-group cleanup / TLS options. The Debian package
  injects the `<script>` include into `index.html.tpl` via a dpkg **trigger**, so
  it is re-applied automatically when `pve-manager` is upgraded; `make install`
  does the same for source installs.

### Documentation
- **Install the plugin on *all* cluster nodes**, not only SAN-connected ones:
  `storage.cfg` is cluster-wide, so a node without the module silently drops the
  storage from its GUI view and `pvesm status`. Use `nodes=` to scope activation
  to nodes with FC connectivity. Documented in `installation.md` /
  `configuration.md`, with a troubleshooting note and a `pvesm add hitachiblock`
  CLI example. (GitHub issue #5)

## [1.2.0~alpha11] - 2026-06-20

> **Alpha pre-release** — optional LUN-path teardown optimization (HMO 91).

### Added
- **`skip_unmap_io_check` storage option** (boolean, default off). When enabled,
  adds Hitachi **HMO 91** (*[OpenStack/OpenShift(K8s)] Skip I/O check when LUN
  path is deleted*) to the plugin's host groups, so the array unmaps a LUN path
  immediately instead of returning "the LU is executing host I/O" while
  `multipathd`'s path checker still probes the just-removed device. Safe because
  the plugin already tears the host side down first (flush + remove the
  multipath/SCSI device before unmapping); HMO 91 only drops the now-redundant
  array interlock and skips `free_image`'s retry/backoff. Off by default;
  available for host mode 00 on VSP One Block 20 / VSP E series.

## [1.2.0~alpha10] - 2026-06-20

> **Alpha pre-release** — adopt Hitachi's best-practice host mode options on
> auto-created host groups.

### Changed
- **Default `host_mode_options` is now `2,22,25,68`** (was `68`), the Hitachi
  best-practice set for the `LINUX/IRIX` (`00 Standard`) host mode, verified
  against the *Open-Systems Host Attachment Guide for VSP Family* (A3-04-2x,
  v10.4.x) for both VSP One Block 20 and VSP E series. `68` is *WRITE SAME / SCSI
  ANSI v5 support* (Page Reclamation for Linux — SCSI UNMAP/discard). `2`/`22`/`25`
  (VERITAS DB-Adv Cluster / Veritas Cluster Server / SPC-3 Persistent Reservation)
  are already default-on on VSP One Block but are set explicitly to cover older
  arrays (VSP E series, VSP 5000) where they are not. Added idempotently to
  existing groups on activation (never removed). See #7.
- Corrected the HMO 68 name in code/docs to its current designation ("WRITE SAME
  command support and SCSI ANSI Version 5 support").

## [1.2.0~alpha9] - 2026-06-20

> **Alpha pre-release** — completes taint-mode safety; LXC containers now boot
> with their rootfs on an array LUN.

### Fixed
- **Container mkfs still failed after alpha8** ("Insecure dependency in exec").
  The device path the plugin returns to PVE was tainted, so PVE's `mkfs.ext4`/
  `mount` (run via `exec` under `pct`'s taint mode) died. Fixes: `get_device_path`
  untaints the `/dev/mapper/3<wwid>` path (and rejects a non-hex wwid);
  `ldev_to_wwid` untaints the synthesized WWID. Verified live: an Alpine CT
  provisions and runs with its ext4 rootfs on a multipath array LUN.

## [1.2.0~alpha8] - 2026-06-20

> **Alpha pre-release** — taint-mode safety; fixes LXC container provisioning.

### Fixed
- **Containers could not be created** ("Insecure dependency in open while running
  with -T switch"). `pct` runs the storage layer in Perl **taint mode**; the
  Multipath module passed tainted data to write-`open`/`exec`. (VMs via `qm` are
  not taint-mode, so this only affected CTs.) Fixes: untaint the glob-derived
  `/sys/class/scsi_host/hostN` scan path and the `hctl` host number before
  write-open; in `_run_cmd` set a known-good `$ENV{PATH}`, drop
  `IFS`/`CDPATH`/`ENV`/`BASH_ENV`, and untaint argv before `exec`. Added a
  taint-mode regression test (`t/unit/taint.t`).

## [1.2.0~alpha7] - 2026-06-20

> **Alpha pre-release** — container support.

### Added
- **`rootdir` content type** (alongside `images`): LXC containers can now live on
  the storage — PVE formats and mounts the raw LUN for the container rootfs, like
  the LVM-thin block model. Default content stays `images`.

## [1.2.0~alpha6] - 2026-06-20

> **Alpha pre-release** — live VSP E590H bring-up (Phase D, thin provisioning /
> discard). Enables SCSI UNMAP so thin pools reclaim on in-guest `fstrim`.

### Fixed
- **Discard/UNMAP not advertised → thin pools never reclaimed.** The plugin
  created host groups with no host mode options, so the array reported `lbpme=0`
  and the host saw `discard_max_bytes=0`; `blkdiscard`/`fstrim` failed with
  "Operation not supported" and freed space was never returned to the pool.
  Hitachi gates Linux page reclamation behind **Host Mode Option 68 ("Support
  Page Reclamation for Linux")**. New `host_mode_options` storage option
  (default `68`): `create_host_group` sends `hostModeOptions`, and
  `_ensure_host_groups` idempotently **adds** the configured options to existing
  groups on activation (`set_host_group_mode` PATCHes with `hostMode`, which the
  CM REST requires alongside the options). Verified live: with HMO 68 the LUN
  reports `lbpme=1` / `discard_max=256 MiB` (42 MiB granularity), and after
  writing 4 GiB then `blkdiscard` the LDEV's `numOfUsedBlock` returned to 0.

## [1.2.0~alpha5] - 2026-06-20

> **Alpha pre-release** — live VSP E590H bring-up (Phase D, PVE functional
> acceptance). Two bugs that only a real array + real guest creation surfaced.

### Fixed
- **Tiny-volume allocation (vTPM/EFI) failed "capacity is invalid":** PVE
  allocates a vTPM state drive as a fixed 4 MiB volume, but the array refuses to
  create a DP-VOL below a hard minimum. Probed live on the E590H: `POST /ldevs`
  with `byteFormatCapacity` ≤ 46 MiB fails the async job, ≥ 47 MiB succeeds.
  `alloc_image` now floors sub-minimum requests to 48 MiB (`_alloc_size_mb`).
  DP-VOLs are thin, so the floored logical size consumes pool pages only on
  write. Volumes ≥ 48 MiB are unchanged and still sized exactly.
- **`list_ldevs()` only saw LDEV slots 0–99 (critical for orphan detection):**
  `GET /ldevs` returns a 100-slot window from `headLdevId` (default 0), and a
  full-space request (`count=16384`) makes the GUM return 503. So a scan of any
  high `ldev_range` saw *zero* of the plugin's own LDEVs. This (a) broke array
  orphan detection for the configured range and (b) made
  `hitachiblock-repl orphans --auto-cleanup` capable of unregistering a *live*
  in-range volume (its id was absent from the 0–99 window). Added
  `RestClient::list_defined_ldevs_in_range` which pages the range in safe chunks
  and drops empty (`NOT DEFINED`) slots; `_next_ldev_in_range` and the orphan
  scan now use it (the scan is scoped to `ldev_range`).

### Added
- **Per-CU `ldev_range` awareness + faster allocation.** An LDEV id is a CU:LDEV
  pair (256 LDEVs per Control Unit); `ldev_range 256-511` is exactly CU 0x01.
  `_next_ldev_in_range` now scans the range one CU-sized window at a time and
  returns the first free id (early termination) instead of paging the whole
  range — allocation is ~1 REST call when the low end is free, which matters for
  wide multi-CU ranges. `on_add_hook`/`on_update_hook` emit a non-fatal hint when
  `ldev_range` is not CU-aligned (clean per-CU reservation pages optimally).

### Verified live (E590H, PVE 9.2)
- Size-unit gate (IC §2.1): an 8 GiB disk is exactly 8589934592 bytes on the
  array (`blockCapacity` 16777216 × 512); a 32-char label round-trips.
- Online resize (D7): `qm resize +4G` grows the LDEV and the multipath map to
  exactly 12 GiB. LDEV id is CU:LDEV (CU = id>>8); the id space pages valid
  through CU 0x7F on this microcode.

## [1.2.0~alpha4] - 2026-06-19

> **Alpha pre-release** — live VSP E590H bring-up (Phase C). First successful
> end-to-end provisioning on hardware: alloc → LDEV in `ldev_range` → host-group
> LUN map → multipath over both fabrics → free with clean teardown.

### Fixed
- **Host-group / WWN provisioning** (none catchable by mocks): resolve the host
  group by name with idempotent reuse (the create response's resource id is a
  composite `portId,num`); `add_wwn_to_host_group` now sends `hostGroupNumber`;
  drop `hostWwnNickname` (rejected by the VSP E REST, `KART40038-E`);
  `list_host_wwns` uses `/host-wwns?portId=…&hostGroupNumber=…` (the
  `/host-groups/<id>/host-wwns` subresource 404s).
- **Cluster-lock self-deadlock (critical):** the registry lock used
  `cfs_lock_storage($storeid)` — the same corosync lock PVE core already holds
  around `vdisk_alloc`/`vdisk_free`/`activate`. Re-acquiring it self-deadlocked,
  so every alloc/free and even browsing the storage in the GUI hung for the lock
  timeout. Now uses a dedicated `cfs_lock_domain`.
- **LDEV create:** don't send `isParallelExecutionEnabled` with an explicit
  `ldevId` (`KART40046-E`).
- **Free/teardown:** remove the host-side multipath/SCSI paths *before* the array
  unmap (otherwise "executing host I/O"); unmap via the LDEV's own
  `GET /ldevs/<id>.ports[]` rather than scanning host groups.

### Security / Safety
- **`GET /luns` ignores the `ldevId` selector** (verified live — a bogus value
  still returns every LUN in the host group). `list_luns` now filters by `ldevId`
  **client-side**, and an **`ldev_range` fence** (`_ldev_in_range`) refuses to
  unmap or delete any LDEV outside the configured range — the plugin can no longer
  act on LDEVs it does not own.

## [1.2.0~alpha3] - 2026-06-19

> **Alpha pre-release** — adopt the current PVE storage plugin API (APIVER 14),
> verified live on a PVE 9.2 cluster.

### Changed
- **Storage API → 14.** `api()` now returns 14 (was 10); the "older storage API,
  upgrade recommended" advisory no longer fires (api == node APIVER).
- **Credentials via sensitive properties.** `plugindata` declares `password` as a
  sensitive property; `on_add_hook`/`on_update_hook` receive it through `%sensitive`
  rather than `$scfg`. PVE keeps the password out of `storage.cfg` (the plugin
  persists it to the cluster-private credential file). `username` remains a normal
  property. Set/update with `pvesm set <storeid> --username u --password p`.

### Fixed
- **Credential capture on PVE 9.** Because `password` is sensitive-by-default in
  PVE 9, it never arrived in `$scfg`, so the old `delete $scfg->{password}` captured
  nothing. Reading it from `%sensitive` fixes credential storage.
- **Added `on_update_hook`** (was missing) so `pvesm set` can change or clear the
  stored credentials.

### Added
- `volume_qemu_snapshot_method` returns `'storage'` — array-side Thin Image
  snapshots are transparent to a running guest.

## [1.2.0~alpha2] - 2026-06-19

> **Alpha pre-release** — bring-up fixes from first live install on a PVE 9.2
> cluster against a VSP E590H.

### Fixed
- **Critical (plugin load):** stopped redefining the `username`/`password`
  storage properties. PVE's base/CIFS/PBS plugins already define them, so
  `PVE::SectionConfig` aborted with `duplicate property 'username'`, which broke
  `pvesm` and the PVE daemons the moment the plugin was installed. They are now
  only referenced in `options()`. Regression-guarded in `t/unit/plugin.t`.
- **Pool capacity reporting:** `status()` now derives used capacity when the array
  returns a null `usedPoolCapacity` (confirmed on the E590H microcode) from
  `total - availableVolumeCapacity` (or `usedCapacityRate`); it previously reported
  the DP pool as 0% used / all-free.

## [1.2.0~alpha1] - 2026-06-17

> **Alpha pre-release** — not yet validated against a live array or cluster.
> The `~alpha1` suffix sorts below a future stable `1.2.0`. Not for production
> data until verified on hardware (see `docs/INTEGRATION_CHECKLIST.md`).


Hardening release addressing a multi-model review (correctness, data-safety, and
PVE plugin-contract findings). No features were removed.

### Fixed
- **Registry data-loss race (critical):** registry mutations now run under a
  genuinely cluster-wide lock. On a PVE node (registry on pmxcfs) the lock is the
  corosync-backed `PVE::Cluster::cfs_lock_storage` (the canonical storage-plugin
  lock), which serializes the full read-modify-write across nodes; a plain `flock`
  on a pmxcfs file is only local to one node's kernel and would NOT prevent
  cross-node lost updates. Off cluster
  (unit tests / non-pmxcfs paths) it degrades to a local `flock`. The commit itself
  stays atomic (temp file + fsync + rename), and a corrupt registry is detected and
  reported instead of being silently treated as empty.
- **Linked-clone destruction (critical):** `free_image` and `create_base` refuse to
  delete/convert a volume while linked clones (Thin Image children) depend on it,
  and `volume_snapshot_delete` now refuses to delete a snapshot while clones created
  from that snapshot still depend on it — clones record their `parent_snap` so the
  dependency is tracked.
- **Registry identity (critical):** a committed `volname` can no longer be silently
  retargeted to a different LDEV (`register_ldev` rejects the conflict),
  `manage_volume` refuses to import an LDEV already tracked under another name, and
  `alloc_image` rejects an explicit name that already exists — preventing two volids
  from pointing at one LDEV or one volid at the wrong data.
- **Orphan detection scope (critical):** `list_orphans` now scans every pool the
  storage uses (data pool, snapshot pool, and any pool referenced by a registry
  entry) instead of only `pool_id`, so `cleanup_registry_orphans` can no longer
  unregister live volumes that live in another pool (snapshots, migrated, imported).
- **Ghost volumes (critical):** `alloc_image`, `clone_image`, and `manage_volume`
  now treat LUN mapping and device discovery as prerequisites — on failure they
  roll back array-side resources and the name reservation and fail loudly, and the
  registry entry is committed last. QoS application remains best-effort.
- **PVE contract:** `filesystem_path` now returns the volume type (`images`) as its
  third element instead of the format; `api()` now reports `10` (was `1`) so PVE
  does not disable the v10-era methods this plugin implements (`rename_volume`,
  `volume_has_feature`, `volume_snapshot_info`). Reconcile with the deployment's
  `pve-storage` APIVER/APIAGE before raising it further.
- **Non-idempotent retries:** the REST client no longer resends `POST`
  create/map/expand requests on `5xx`/`409` (a lost response could double-create an
  LDEV/LUN or double-apply an expand). Only `429` (rejected before processing) is
  retried for `POST`; idempotent `GET`/`PUT`/`DELETE` still retry on `5xx`/`409`.
  `login()` is now on the same retry path (previously bypassed it entirely).
- **Consistency-group snapshots:** `volume_snapshot_consistency_group` now rolls
  back any pairs it created in the group if a later pair fails, instead of leaving a
  half-built, non-crash-consistent group behind.
- **Multipath WWID whitelisting (functional):** the plugin now runs `multipath -a
  <wwid>` when activating a LUN and `multipath -w <wwid>` on free. Under PVE's
  default `find_multipaths strict`, only whitelisted WWIDs are assembled into
  `/dev/mapper`, so without this a freshly mapped LUN's device could never appear
  and `alloc_image`/`activate_volume` would time out. `multipath -r`/`reconfigure`
  calls are now best-effort (no longer abort the wait loop on transient failure).
- **Async jobs:** `_wait_for_job` now polls async operations that return only a
  `Location` header (previously treated as already complete).
- **LDEV allocation race:** `_next_ldev_in_range` now scans all array LDEVs
  (storage-wide, not just the configured pool) plus registry/reservations.
- **status():** pool capacity is now converted from documented MB units instead of
  guessing MB-vs-bytes by magnitude.
- **Size parsing:** LDEV size now prefers the exact block count over the
  human-formatted `byteFormatCapacity` string.
- **Snapshot lookup:** snapshot group names now encode the volume's LDEV id so the
  array-side fallback search cannot resolve another volume's pair (legacy names
  still accepted for upgrade compatibility).
- **Port scheduler:** replaced the ineffective in-memory round-robin counter (reset
  every `pvesm` process) with stable per-LDEV deterministic port selection, making
  map/unmap symmetric across nodes.
- **Shell safety:** `Multipath` command execution no longer uses a shell
  (list-form exec), removing quoting/injection exposure.

### Added
- **Base/template images:** implemented `create_base`, `parse_volname` base-volume
  syntax, and base-aware name handling — the long-advertised `template` feature now
  works end to end.
- **`volume_size_info`:** reports size directly from the registry/array for raw
  block volumes (no `qemu-img` shelling).
- **TLS verification:** opt-in `tls_verify` and `tls_ca_file` storage properties.
- **True CoW linked clones:** `clone_image` now creates a copy-on-write Thin Image
  S-VOL that shares blocks with its source, instead of a full physical copy. Per the
  REST API guide the pair is created **split** (`autoSplit=true`, `isClone` unset) so
  the S-VOL is host R/W (status `PSUS`) while still sharing unchanged blocks via the
  pool; `isClone=true` would full-copy then auto-delete the pair (a full clone).
  Sources are restricted to base images and snapshots (`volume_has_feature('clone')`
  => `base`/`snap`), matching the block storage model; full copies are handled by PVE
  core via the device path. The source/snapshot cannot be deleted while a clone
  depends on it.
- **Authoritative device WWID:** `_resolve_wwid` now reads the array-reported `naaId`
  from `GET /ldevs/{id}` and uses `3<naaId>` for the multipath device, instead of
  relying on a model-dependent synthesized NAA (synthesis + sysfs discovery remain as
  fallbacks).
- **`volume_has_feature` block model:** reworked to the LVM-thin `base`/`current`/`snap`
  key model so PVE offers linked-clone only where it is valid and exposes `rename`.
- **`map_volume`/`unmap_volume`:** implemented the PVE 8 explicit map/unmap hooks
  (delegate to activate/deactivate; return the `/dev/mapper` path).
- **Management-plane controller redundancy:** `mgmt_ip` now accepts a
  comma-separated list of per-controller REST endpoints (e.g. each VSP controller's
  GUM). The client keeps a sticky current endpoint and, on a transport-level failure,
  fails over to the next one and re-authenticates there (sessions are per-controller).
  A single IP / floating VIP is just a one-element list and behaves as before. (The
  data plane was already redundant via multipath over `target_ports` on both
  controllers.)
- **Disk reassignment:** implemented the PVE `rename_volume` method (GUI "Reassign",
  `qm disk reassign`) — relabels the LDEV and renames the registry entry atomically,
  refusing when linked clones still depend on the source.
- **Volume export/import:** implemented `volume_export`/`volume_import` and their
  format helpers (`raw+size`, streamed via `dd` on the block device, like RBD), so
  the storage now participates in PVE's `storage_migrate` path — offline `qm migrate`
  to a non-shared target, `qm remote-migrate`, and `pvesm export`/`import`. (Same-node
  "Move Storage"/`qm move-disk` already worked via the device path.) Snapshots and
  incremental streams are not transferred. See docs/operations.md for the matrix.
- **VSP E series support:** new `vsp_e` platform (e.g. VSP E590H) defaulting to the
  direct/embedded Configuration Manager REST API on port 443; `storage_id` and
  `mgmt_ip` descriptions clarified (storageDeviceId vs. serial; embedded GUM vs.
  dedicated Ops Center CM server).
- **REST retry hardening:** retries on HTTP 429 and honors `Retry-After`.
- **Self-correcting WWID:** if the synthesized NAA does not resolve, the plugin
  discovers and persists the device's real page-83 WWID from sysfs.
- **Long-storeid labels:** LDEV labels that would exceed the 32-char array limit
  fall back to a stable hashed prefix, kept consistent with orphan detection.
- **Replication CLI:** auto-detects connection parameters from `/etc/pve/storage.cfg`
  (env vars now a fallback), adds an `orphans` command with an `--auto-cleanup` flag
  that prunes stale registry entries (safe: it scans all array LDEVs, not one pool),
  and accepts `--volume <volname>` to resolve `--pvol` from the registry.
- Config: `reserve_volname`, `rename_volume`, `find_dependents`,
  `find_snapshot_dependents`, `find_volname_by_ldev`, `label_prefix`.
- Tests: registry concurrency (fork) and corruption, name reservation, rename,
  dependents, snapshot-dependent and ldev-owner lookups, registry identity conflict,
  label hashing, base-volume parsing, block-count sizing, deterministic port
  selection, async `Location` polling, `vsp_e` port default, and the retry matrix
  (GET retried on 5xx, POST not retried on 5xx, POST retried on 429, login on 429,
  401 re-auth).

### Documentation
- Documentation completeness pass: rewrote `README.md` (honest pre-production /
  not-yet-hardware-validated status banner, current feature list, VSP E series,
  fixed install version drift); added a `docs/README.md` index, `CONTRIBUTING.md`,
  and `SECURITY.md`; and corrected stale flows in `architecture.md` (CoW linked vs
  PVE-core full clone, register-last + rollback in `alloc_image`, deterministic port
  selection).
- Added `docs/reference/` Markdown extracts of the vendor PDFs in `reference/`
  (REST API Reference Guide, VSP 5000 User Guide, Ops Center Common Services),
  focused on the resources/semantics this plugin uses. These confirmed several
  assumptions from the spec (linked-clone `autoSplit`/`isClone`, base-1024 capacity
  units, 32-char LDEV labels, `naaId` source, async job format) and drove the
  `clone_image` and WWID corrections above.
- Added `docs/INTEGRATION_CHECKLIST.md`: a phased hardware bring-up checklist (VSP
  E590H) enumerating every array/host assumption, where it lives in the code, how to
  verify it, and what to change if wrong — plus a `t/integration/` README tying the
  test dir to it. Flags clone CoW behavior and disk-size units as the top unverified
  items.
- Corrected the multi-attach description (no cluster-wide refcount; per-node host
  groups), the full-clone mechanism, and the replication CLI flags to match the
  actual implementation; documented the new options, commands, and behaviors.

## [1.1.0] - 2026-03-07

### Added
- Manage/unmanage volumes: `manage_volume` imports existing array LDEVs into PVE,
  `unmanage_volume` releases a volume without deleting the LDEV
- Zero page reclamation: `discard_zero_page` property triggers array-side zero page
  discard on volume deactivation for thin pool space recovery
- QoS lower bounds and I/O priority: `qos_lower_iops`, `qos_lower_mbps` minimum
  guarantees and `qos_priority` (1=high, 2=medium, 3=low) response priority
- LDEV range restriction: `ldev_range` property limits LDEV ID allocation to a
  specific range (decimal or hex), preventing collisions in shared arrays
- Storage-assisted volume migration: `volume_migrate_pool` moves an LDEV between
  DP pools using array-side copy (no host I/O required)
- Consistency group snapshots: `volume_snapshot_consistency_group` creates atomic
  snapshots across multiple volumes using Hitachi consistency groups
- Port scheduler: `port_scheduler` property enables round-robin target port selection
  for LUN mappings, distributing I/O across FC ports (minimum 2 ports per volume)
- Copy speed control: `copy_speed` property (1-15) throttles array-side copy
  operations during snapshots and clones
- Host group auto-delete: `group_delete` property removes empty host groups on
  storage deactivation
- Multi-attach: activate/deactivate correctly handle concurrent LUN mappings to
  multiple nodes (each node maps/unmaps independently)
- RestClient: `reclaim_zero_pages`, `migrate_ldev`, `delete_host_group` methods
- RestClient: `responsePriority` support in `set_ldev_qos`
- RestClient: `copySpeed` support in `create_snapshot` and `clone_snapshot_to_ldev`
- RestClient: `isConsistencyGroup` flag now configurable in `create_snapshot`
- `volume_has_feature` now reports `resize` capability
- Config: `ldev_range` validation in `validate_config`
- Tests for all new RestClient methods and plugin logic

## [1.0.0] - 2026-03-07

### Added
- Replication CLI tool (`bin/hitachiblock-repl`)
  - TrueCopy (synchronous replication) pair management
  - Universal Replicator (asynchronous replication) pair management
  - Global-Active Device (GAD) pair management with quorum disk support
  - Remote storage system registration
  - Commands: list, create-tc, create-ur, create-gad, status, split, resync, delete
- RestClient: replication operations
  - `create_remote_copy_pair`, `delete_remote_copy_pair`, `get_remote_copy_pair`
  - `list_remote_copy_pairs`, `split_remote_copy_pair`, `resync_remote_copy_pair`
  - `register_remote_storage`, `list_remote_storages`
- Full mocked test suite (`t/unit/restclient_mock.t`)
  - HTTP response mocking for all RestClient operations
  - LDEV, pool, host-group, LUN, snapshot, QoS, and replication tests
- Plugin logic unit tests (`t/unit/plugin.t`)
  - Volume name parsing, generation, feature matrix validation
- GitHub Actions CI/CD pipeline (`.github/workflows/ci.yml`)
  - Perl syntax checking, unit tests, install target verification

## [0.3.0] - 2026-03-07

### Added
- QoS support: `qos_upper_iops` and `qos_upper_mbps` storage properties
  - Automatically applied to new LDEVs during `alloc_image`
  - RestClient: `set_ldev_qos` and `get_ldev_qos` methods
- `check_connection` method for lightweight connectivity verification
- Orphan detection: `list_orphans` and `cleanup_registry_orphans` methods
  - Identifies LDEVs on array not in registry and vice versa
- Multipath: `flush_device` for safe buffer flush before resize

### Changed
- `_client` now auto-reconnects on session expiry (keepalive + re-login)
- `alloc_image` cleans up LDEV on label-set failure (partial failure recovery)
- `volume_resize` verifies current size from array before expanding
  - Parses `byteFormatCapacity` from LDEV info (M/G/T formats)
  - Flushes device buffers before resize on running VMs

## [0.2.0] - 2026-03-07

### Added
- Snapshot metadata tracking in Config registry
  - `register_snapshot` / `unregister_snapshot` / `lookup_snapshot` / `list_snapshots`
  - Snapshot S-VOL LDEV ID, WWID, and array snapshot ID stored per volume
- `volume_snapshot_info` method for PVE UI snapshot tree display
- Snapshot-aware `activate_volume` / `deactivate_volume` — handles S-VOL LUN mapping
- Snapshot-aware `filesystem_path` / `path` — resolves S-VOL device paths
- Clone from snapshot support — `clone_image` uses `$snap` parameter to clone from S-VOL
- Parent volume tracking — linked clones record `parent_volname` in registry
- `list_images` returns `parent` field for linked clones
- `volume_has_feature` now reports `sparseinit` and `template` capabilities
- RestClient: `get_snapshot` and `split_snapshot` methods

### Changed
- `volume_snapshot` now retrieves and stores S-VOL metadata after creation
- `volume_snapshot_delete` and `volume_snapshot_rollback` use registry for fast lookup
  with fallback to array-side search
- `clone_image` full/linked distinction based on target storeid match (not arbitrary string)

## [0.1.0] - 2026-03-07

### Added
- Initial MVP implementation
- `HitachiBlockPlugin.pm` - PVE storage plugin entry point
  - Core lifecycle: alloc_image, free_image, list_images, activate/deactivate volume/storage
  - Storage status reporting (pool capacity)
  - Snapshot, clone, and resize operations
- `RestClient.pm` - Hitachi Configuration Manager REST API client
  - Session management with token-based auth
  - LDEV, pool, host group, LUN path, and snapshot operations
  - Async job polling with configurable timeout
  - Retry logic for transient errors and re-auth on 401
- `Multipath.pm` - Linux FC/SCSI multipath management
  - SCSI bus rescan (full and targeted)
  - Multipath device lifecycle (wait, remove, resize)
  - FC WWN discovery from sysfs
- `Config.pm` - Configuration and state management
  - Credential storage in `/etc/pve/priv/`
  - LDEV-to-volname registry (cluster-replicated via pmxcfs)
  - Platform-specific defaults (VSP G vs VSP One Block)
- Example storage.cfg and multipath.conf configurations
- Debian packaging
