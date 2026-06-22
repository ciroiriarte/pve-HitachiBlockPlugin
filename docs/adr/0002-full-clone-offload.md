# ADR 0002 — Full-clone offload to the array is not possible via the PVE plugin API

- **Status:** Accepted (factual constraint; revisit only if upstream PVE adds a hook)
- **Date:** 2026-06-22
- **Deciders:** Ciro Iriarte
- **Related:** `src/PVE/Storage/Custom/HitachiBlockPlugin.pm` (`clone_image`,
  `volume_has_feature`), `docs/operations.md` §clone/snapshot,
  `docs/architecture.md`
- **Source reviewed:** PVE `qemu-server` 9.1.17 (`PVE::QemuServer::clone_disk`)
  and `pve-storage` 9.1.6 (`PVE::Storage`, `PVE::Storage::Plugin`), git tip
  mid-June 2026.

## Context

A natural goal for a VVols-like Hitachi plugin is to **offload a full VM disk
clone to the array** (ShadowImage / Thin Image full-copy, or a SCSI
`EXTENDED COPY`/XCOPY/ODX token copy) so the data never traverses the PVE host.
This ADR records whether `qm clone --full` can be wired to such an offload
through the storage-plugin API. **It cannot** — and that conclusion is a
property of PVE core, not of this plugin.

### How PVE dispatches a clone

`qm clone` / the clone API ultimately call **`PVE::QemuServer::clone_disk()`**
(`qemu-server/src/PVE/QemuServer.pm:7899`). It branches on `$full`:

**Linked clone (`!$full`)** — `clone_disk:7931`:

```perl
$newvolid = PVE::Storage::vdisk_clone($storecfg, $drive->{file}, $newvmid, $snapname);
```

`vdisk_clone` (`pve-storage/src/PVE/Storage.pm`) dispatches to the plugin:

```perl
my $volname = $plugin->clone_image($scfg, $storeid, $volname, $vmid, $snap);
```

This **is** a storage-offload hook. This plugin already implements `clone_image`
as a Thin Image copy-on-write S-VOL (`HitachiBlockPlugin.pm:1018`), advertised
via `volume_has_feature('clone')` for `base`/`snap` sources
(`HitachiBlockPlugin.pm:1000`). **This is the only offloaded clone path PVE
exposes.**

**Full clone (`$full`)** — `clone_disk:7934-8037`. The sequence is hardcoded and
host-side:

1. `PVE::Storage::vdisk_alloc(...)` (`:7961`) — allocate a **blank** target
   volume (this plugin's `alloc_image`). The plugin is handed **no reference to
   the source volume**, so it cannot even recognize the allocation as part of a
   clone.
2. `PVE::Storage::activate_volumes(...)` (`:7973`).
3. Copy the bytes via one of three **host-side** mechanisms, with **no plugin
   callback** in any of them:
   - **Running VM** → QEMU `drive-mirror` block job
     (`BlockJob::mirror`, `:7996`) — QEMU on the host reads source / writes dest.
   - **efidisk0** → `qemu-img dd` (`:8016`).
   - **Otherwise** → `PVE::QemuServer::QemuImage::convert(...)` (`:8035`), which
     is literally `/usr/bin/qemu-img convert -p -n ...`
     (`qemu-server/src/PVE/QemuServer/QemuImage.pm:143`).

For an FC/iSCSI **block** plugin like this one, `qemu-img convert` reads the
source LUN's device path and writes the target LUN's device path — exactly the
host-side `dd`-equivalent we want to avoid: every block crosses the SAN twice
(host read + host write) and consumes PVE node CPU/IO.

### Why offload is structurally impossible for full clones

- **There is no full-copy offload method anywhere in the plugin API.** Grepping
  `pve-storage` `Storage.pm` / `Plugin.pm` for `copy_image`, `offload`, `xcopy`,
  `odx`, `token` returns nothing. The plugin surface for copying is
  `clone_image` (CoW/linked only), `alloc_image`, `path`, `activate_volumes`,
  `volume_has_feature`, and `volume_import` / `volume_export`. None of these
  hand the backend **both** the source and the destination of a full copy in a
  single call it could satisfy array-side.
- **`clone_disk` never consults the plugin about *how* to copy** in the full
  path. The copy mechanism is selected purely from VM running-state and drive
  type (efidisk/tpmstate/cloudinit/normal), then executed with QEMU tooling.
  The plugin only participates by allocating a blank target and resolving device
  paths.

## Decision

1. **Accept that `qm clone --full` always copies on the host.** Do not attempt
   to fake array offload from inside `alloc_image`/`path` — the plugin lacks the
   source→dest relationship and the copy is driven by QEMU, not the plugin.
2. **Keep `clone_image` (Thin Image CoW linked clone) as the supported offload
   path.** It is the only array-offloaded clone PVE sanctions, and it already
   works. Continue advertising `clone` only for `base`/`snap` sources via
   `volume_has_feature`.
3. **Treat true full-clone offload as an upstream-dependent future item**, not a
   plugin bug or a near-term deliverable.

## Options for a future array-offloaded full clone (none currently viable in-tree)

- **Option A — Propose an upstream `pve-storage` hook.** Add an optional plugin
  method (e.g. `copy_image($scfg, $src_volid, $dst_volid, $opts)`) that
  `clone_disk` calls in the full, non-running path before falling back to
  `qemu-img convert`, with QEMU remaining the fallback when the plugin returns
  "unsupported". This is the clean fix but requires Proxmox to accept the API
  change; until then it does not exist.
- **Option B — Out-of-band array clone via `hitachiblock-repl`.** Drive a
  ShadowImage/Thin Image full copy through the plugin's own CLI/tooling outside
  the `qm clone` flow. Functional for operators, but it does **not** integrate
  with the `qm clone --full` UX and bypasses PVE's volume bookkeeping, so it
  must be reconciled into the registry manually.
- **Option C — Lean on linked clones + later promotion.** Use the supported
  CoW `clone_image` path for instant clones and, if an independent full copy is
  later required, perform an array-side background copy/split. Still needs a
  mechanism to detach the CoW dependency, which has no PVE hook today.

These remain **not viable in-tree** without either upstream changes (A) or
out-of-band orchestration (B/C). No option is selected; this section exists so a
future effort starts from the known constraints.

## Consequences

- **`qm clone --full` on Hitachi storage performs a host-side copy**
  (`qemu-img convert`, or `drive-mirror` for a running VM). Plan for PVE node
  CPU/IO and double SAN traffic; throughput is bounded by the host and the
  network, not the array's internal copy engines.
- **Instant, space-efficient clones are available only as linked clones**
  (Thin Image CoW) from a **template/base image or a snapshot** — not from an
  arbitrary live volume. This matches `volume_has_feature('clone')` returning
  true only for `base`/`snap`. Document this expectation for operators in
  `docs/operations.md`.
- **No code change is warranted now.** The current `clone_image` implementation
  is already the correct and only sanctioned offload path. Revisit this ADR only
  if upstream PVE introduces a full-copy plugin hook (Option A), at which point
  the plugin can implement array-side `EXTENDED COPY`/ShadowImage offload and
  this ADR moves to "Superseded".
