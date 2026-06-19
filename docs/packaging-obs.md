# Packaging on the openSUSE Build Service (OBS)

The plugin is packaged for **Proxmox VE 9** (Debian 13 "Trixie" base) on
[obs.opensuse.org](https://build.opensuse.org) under the project
**`home:ciriarte:pve-HitachiBlockPlugin`**.

> **ALPHA software.** The built `.deb` is for lab/test use only until the plugin
> has been validated against a live array — see
> [`INTEGRATION_CHECKLIST.md`](INTEGRATION_CHECKLIST.md).

## Layout

| OBS object | Value |
|------------|-------|
| Project    | `home:ciriarte:pve-HitachiBlockPlugin` |
| Package    | `pve-storage-hitachiblock` |
| Repository | `PVE_9` (named after the PVE release, not the Debian base, to avoid confusion) |
| Build base | `Debian:13/standard` |
| Arch       | `x86_64` (Debian `amd64`) |

The repository is deliberately named `PVE_9` rather than `Debian_13`: users pick it
by the Proxmox release they run, even though the underlying base is Debian 13.

## Building the source package

OBS builds Debian packages from a `3.0 (quilt)` source package (orig tarball +
debian tarball + `.dsc`). This repo generates those without needing `dpkg-dev`:

```sh
tools/make-obs-source.sh        # writes build/obs/*.{orig.tar.gz,debian.tar.xz,dsc}
```

Versions come from `debian/changelog`. Always commit your changes first — the
script packages from `git HEAD`.

## Publishing to OBS

```sh
# one-time: create the project + repository (PVE_9 -> Debian:13/standard)
osc meta prj   home:ciriarte:pve-HitachiBlockPlugin -F packaging/obs/_meta
osc meta prjconf home:ciriarte:pve-HitachiBlockPlugin -F packaging/obs/_config

# per release
tools/make-obs-source.sh
osc co home:ciriarte:pve-HitachiBlockPlugin pve-storage-hitachiblock
cp build/obs/* home:ciriarte:pve-HitachiBlockPlugin/pve-storage-hitachiblock/
cd home:ciriarte:pve-HitachiBlockPlugin/pve-storage-hitachiblock/
osc addremove
osc commit -m "pve-storage-hitachiblock <version>"
```

OBS rebuilds on every commit. Watch progress with:

```sh
osc results home:ciriarte:pve-HitachiBlockPlugin
osc buildlog home:ciriarte:pve-HitachiBlockPlugin PVE_9 x86_64
```

## Installing the built package (on a PVE 9 node)

Once the build succeeds and the repository publishes:

```sh
echo 'deb http://download.opensuse.org/repositories/home:/ciriarte:/pve-HitachiBlockPlugin/PVE_9/ /' \
  > /etc/apt/sources.list.d/hitachiblock.list
curl -fsSL https://download.opensuse.org/repositories/home:/ciriarte:/pve-HitachiBlockPlugin/PVE_9/Release.key \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/home_ciriarte_hitachiblock.gpg
apt update
apt install pve-storage-hitachiblock
```
