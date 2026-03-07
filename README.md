# PVE Hitachi Block Storage Plugin

Proxmox VE storage plugin for Hitachi FC-based block storage systems (VSP G series and VSP One Block).

Provides **1 LUN per virtual disk** with storage services offloaded to the array, similar to VMware VVols.

## Features

- **Thin provisioning** via Hitachi DP pools
- **Snapshots** using Thin Image (array-offloaded)
- **Linked and full clones** via Thin Image / ShadowImage
- **Online volume resize** with host-side multipath resize
- **Active-node-only LUN mapping** for scalability
- **Capacity monitoring** reported to PVE UI

## Supported Platforms

| Platform | API Provider | Default Port |
|----------|-------------|--------------|
| VSP G series | Ops Center API Configuration Manager | 23451 |
| VSP One Block | Native REST API (built into controller) | 443 |

Both platforms use the same Configuration Manager REST API endpoints.

## Installation

```bash
# From source
make install

# Or build and install Debian package
make deb
dpkg -i ../pve-storage-hitachiblock_0.1.0-1_all.deb
```

## Configuration

Add to `/etc/pve/storage.cfg`:

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

- [Architecture](docs/architecture.md)
- [Installation](docs/installation.md)
- [Configuration](docs/configuration.md)
- [Operations](docs/operations.md)

## License

AGPL-3.0 - See [LICENSE](LICENSE)
