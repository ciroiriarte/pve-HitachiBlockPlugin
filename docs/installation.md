# Installation

## PVE Host Prerequisites

### Proxmox VE

- Proxmox VE 8.0 or later

### Fibre Channel

- FC HBA installed in each PVE cluster node
- FC link must be online:
  ```bash
  cat /sys/class/fc_host/host*/port_state
  # Expected: Online
  ```

### Multipath

Install and configure `multipath-tools`:

```bash
apt-get install multipath-tools
systemctl enable multipathd
systemctl start multipathd
```

### Perl Dependencies

The following Perl modules are required (typically pre-installed on PVE):

- `LWP::UserAgent` (libwww-perl)
- `JSON` (libjson-perl)
- `IO::Socket::SSL` (libio-socket-ssl-perl)
- `Getopt::Long` (core module)

Install any missing dependencies:

```bash
apt-get install libwww-perl libjson-perl libio-socket-ssl-perl
```

### SAN Zoning

Fibre Channel zoning must be configured between:
- PVE node FC HBA ports (initiator WWNs)
- Hitachi storage target FC ports

See [Storage Appliance Prerequisites](prerequisites.md) for details.

---

## Storage Appliance Prerequisites

See [prerequisites.md](prerequisites.md) for the complete list of what must be configured on the Hitachi array before installing the plugin:

- Configuration Manager REST API enabled/installed
- API user account with appropriate roles
- DP pools created
- FC target ports configured
- SAN zoning
- Licenses (Dynamic Provisioning, Thin Image, etc.)

---

## Install from Source

```bash
cd pve-HitachiBlockPlugin
sudo make install
sudo systemctl restart pvedaemon
```

This installs:
- Plugin module: `/usr/share/perl5/PVE/Storage/Custom/HitachiBlockPlugin.pm`
- Helper modules: `/usr/share/perl5/PVE/Storage/HitachiBlock/{RestClient,Multipath,Config}.pm`
- Replication CLI: `/usr/bin/hitachiblock-repl`
- Example configs: `/usr/share/doc/pve-storage-hitachiblock/`

## Install from Debian Package

```bash
make deb
sudo dpkg -i ../pve-storage-hitachiblock_1.0.0-1_all.deb
sudo systemctl restart pvedaemon
```

## Multipath Configuration

Copy the recommended multipath settings for Hitachi VSP:

```bash
sudo cp conf/multipath.conf.d/hitachiblock-vsp.conf /etc/multipath/conf.d/
sudo systemctl reload multipathd
```

This configures optimal I/O scheduling, path grouping, and failover for Hitachi devices.

## Verify Installation

```bash
# Plugin should be recognized by PVE
pvesm status
# If no hitachiblock storage is configured yet, the type won't appear,
# but pvedaemon should start without errors in the journal.

# Check for load errors
journalctl -u pvedaemon --no-pager | tail -20
```

## Uninstall

```bash
# If installed via dpkg
sudo dpkg -r pve-storage-hitachiblock

# If installed from source
sudo rm /usr/share/perl5/PVE/Storage/Custom/HitachiBlockPlugin.pm
sudo rm -r /usr/share/perl5/PVE/Storage/HitachiBlock/
sudo rm /usr/bin/hitachiblock-repl
sudo systemctl restart pvedaemon
```

**Note**: Uninstalling the plugin does not remove storage configuration from `storage.cfg` or state files from `/etc/pve/priv/hitachiblock/`. Remove those manually if the storage is no longer needed.
