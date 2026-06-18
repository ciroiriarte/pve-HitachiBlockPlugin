# Changelog

## [1.2.0] - 2026-06-17

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
  S-VOL (Thin Image pair *without* `autoSplit`) that shares blocks with its source,
  instead of a full physical copy. Sources are restricted to base images and
  snapshots (`volume_has_feature('clone')` => `base`/`snap`), matching the block
  storage model; full copies are handled by PVE core via the device path. Linked
  clones are space-efficient and instant, and the source/snapshot cannot be deleted
  while a clone depends on it.
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
