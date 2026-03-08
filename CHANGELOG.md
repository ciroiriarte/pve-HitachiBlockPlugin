# Changelog

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
