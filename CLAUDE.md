# Purpose

This project consists in deploying a Proxmox VE (PVE) Storage plugin to command Hitachi FC based storage systems to provide storage services for Virtual Machines.
Expected functionality is similar to VMware VVols implementation.

This scope should include:
- provisioning of 1 LUN per virtual disk.
- Advanced storage services offloaded to the storage box.

# References
- PVE Storage plugin development guidelines
  https://pve.proxmox.com/wiki/Storage_Plugin_Development
- Hitachi vs VVols implementation
  * https://docs.broadcom.com/doc/reference_architecture
  * https://www.hitachivantara.com/en-us/pdf/architecture-guide/vmware-vsphere-virtual-volumes-with-virtual-storage-platform.pdf
  * https://docs.hitachivantara.com/v/u/en-us/application-optimized-solutions/mk-as-608
- VSP One Block: RST API Reference Guide
  * https://docs.hitachivantara.com/r/en-us/virtual-storage-platform-one-block/a3-03-0x/mk-23vsp1b002
- Ops Center API Reference Guide
  * https://docs.hitachivantara.com/r/en-us/ops-center-api-configuration-manager/11.0.x/mk-99cfm000/configuring-a-rest-api-environment/installing-and-upgrading-the-rest-api/rest-api-installation-destination

# Coding
- Seek modularity to simplify maintenance
- Use symver varsioning convention
- Keep documentation always in sync
