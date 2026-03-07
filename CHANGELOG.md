# Changelog

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
