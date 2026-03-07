# Installation

## Prerequisites

- Proxmox VE 8.0+
- Hitachi VSP G series or VSP One Block with Configuration Manager REST API
- FC HBA with zoning configured between PVE nodes and storage ports
- `multipath-tools` installed and configured

## Install from Source

```bash
cd pve-HitachiBlockPlugin
make install
systemctl restart pvedaemon
```

## Install from Debian Package

```bash
make deb
dpkg -i ../pve-storage-hitachiblock_0.1.0-1_all.deb
systemctl restart pvedaemon
```

## Multipath Configuration

Copy the recommended multipath settings:

```bash
cp conf/multipath.conf.d/hitachiblock-vsp.conf /etc/multipath/conf.d/
systemctl reload multipathd
```

## Verify Installation

```bash
pvesm status
# Should list 'hitachiblock' as an available storage type
```
