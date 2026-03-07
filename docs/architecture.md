# Architecture

## Component Overview

```
PVE Framework
    |
HitachiBlockPlugin (Plugin Entry Point)
    |
    +-- RestClient    (Hitachi Configuration Manager REST API)
    +-- Multipath     (Linux FC/SCSI multipath)
    +-- Config        (Credentials, LDEV registry, validation)
```

## Module Responsibilities

### HitachiBlockPlugin
- Extends `PVE::Storage::Plugin`
- Translates PVE lifecycle calls into orchestrated operations
- Active-node-only LUN mapping for scalability

### RestClient
- Pure HTTP client for Hitachi Configuration Manager API
- Session lifecycle, LDEV/pool/host-group/LUN/snapshot operations
- Async job polling, retry on 5xx/409, re-auth on 401

### Multipath
- Linux-side SCSI rescan and multipath device management
- FC WWN discovery from sysfs
- WWID computation from storage serial + LDEV ID

### Config
- Credentials in `/etc/pve/priv/hitachiblock/<storeid>.creds`
- LDEV registry in `/etc/pve/priv/hitachiblock/<storeid>.json`
- Cluster-replicated via pmxcfs

## Volume Naming

- PVE volname: `vm-<VMID>-disk-<SEQ>`
- LDEV label: `pve:<storeid>:vm-<VMID>-disk-<SEQ>`

## LUN Scaling Strategy

Each LUN is mapped only to the host group of the node running the VM.
On migration: map to target first, then unmap from source.
Per-host LUN count = VMs on that node, not total cluster VMs.
