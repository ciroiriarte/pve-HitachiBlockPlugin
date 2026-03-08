# PVE Hitachi Block Storage Plugin

Proxmox VE storage plugin for Hitachi FC-based block storage systems (VSP G series and VSP One Block).

Provides **1 LUN per virtual disk** with storage services offloaded to the array, similar to VMware VVols.

## Features

- **Thin provisioning** via Hitachi DP pools
- **Snapshots** using Thin Image (array-offloaded, per-LDEV)
- **Linked and full clones** via Thin Image / ShadowImage
- **Clone from snapshot** support
- **Online volume resize** with array-side verification and host-side multipath resize
- **QoS** per-LDEV IOPS and throughput limits
- **Active-node-only LUN mapping** for scalability
- **Capacity monitoring** reported to PVE UI
- **Session auto-reconnect** on expiry
- **Orphan detection** and registry cleanup
- **Partial failure recovery** during volume allocation
- **Replication CLI tool** for TrueCopy, Universal Replicator, and Global-Active Device (GAD)
- **Snapshot metadata tracking** in cluster-replicated registry

## Supported Platforms

| Platform | API Provider | Default Port |
|----------|-------------|--------------|
| VSP G series | Ops Center API Configuration Manager | 23451 |
| VSP One Block | Native REST API (built into controller) | 443 |

Both platforms use the same Configuration Manager REST API endpoints.

## Quick Start

```bash
# Install
make install
systemctl restart pvedaemon

# Or build Debian package
make deb
dpkg -i ../pve-storage-hitachiblock_1.1.0-1_all.deb
```

Configure in `/etc/pve/storage.cfg`:

```
hitachiblock: myarray
    mgmt_ip 10.0.1.100
    storage_id 836000123456
    pool_id 0
    snap_pool_id 1
    target_ports CL1-A,CL2-A
    host_mode LINUX
    platform vsp_one
    shared 1
    content images
    nodes node1,node2,node3
```

Store credentials:

```bash
pvesm set myarray --username admin --password secret
```

## Documentation

- [Architecture](docs/architecture.md) - Component design and data flows
- [Installation](docs/installation.md) - Host and array prerequisites, install steps
- [Configuration](docs/configuration.md) - Plugin parameters, credentials, platform differences
- [Operations](docs/operations.md) - Storage services, replication CLI, troubleshooting
- [Storage Appliance Prerequisites](docs/prerequisites.md) - What must be configured on the Hitachi array

## Testing

```bash
make test   # Run unit tests
```

## License

AGPL-3.0 - See [LICENSE](LICENSE)
