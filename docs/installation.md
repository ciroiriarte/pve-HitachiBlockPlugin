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

Install `multipath-tools` on every node and copy the recommended device settings
for Hitachi VSP:

```bash
sudo apt-get install -y multipath-tools
sudo cp conf/multipath.conf.d/hitachiblock-vsp.conf /etc/multipath/conf.d/
sudo systemctl reload multipathd
```

This configures optimal I/O scheduling (ALUA, `group_by_prio`), path grouping, and
failover for Hitachi `OPEN-V` devices.

### WWID whitelisting (`find_multipaths`)

PVE ships multipath with `find_multipaths strict` by default: only WWIDs listed in
`/etc/multipath/wwids` are assembled into `/dev/mapper` devices. **The plugin handles
this automatically** — on map/activate it runs `multipath -a <wwid>` to whitelist the
LUN before waiting for its device, and `multipath -w <wwid>` on free to drop the
entry. No manual `multipath -a` per volume is required.

If you prefer not to rely on the per-volume whitelist, you may instead set a broader
policy in `/etc/multipath.conf` (e.g. `find_multipaths "yes"`, which also multipaths
any device that has ≥2 paths), but the automatic whitelisting works under the strict
default and is the recommended path. Verify with:

```bash
multipath -ll          # should list the 3<wwid> map with all FC paths active
multipath -v3          # detailed path discovery diagnostics
```

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
