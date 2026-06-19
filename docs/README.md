# Documentation

Documentation for the PVE Hitachi Block Storage Plugin. New here? Start with the
[project README](../README.md) and **note the pre-production status warning** before
using the plugin against any real array.

## Reading order

1. **[Storage Appliance Prerequisites](prerequisites.md)** — what must already be
   configured on the Hitachi array (pools, FC ports, API user, licensing, zoning).
2. **[Installation](installation.md)** — host prerequisites, installing the plugin,
   and multipath setup.
3. **[Configuration](configuration.md)** — every `storage.cfg` parameter, credential
   storage, platform differences, multi-controller management endpoints, TLS, QoS.
4. **[Operations](operations.md)** — day-to-day storage services (allocate, snapshot,
   clone, resize, migrate), the `hitachiblock-repl` replication CLI, orphan handling,
   and troubleshooting.
5. **[Hardware Integration Checklist](INTEGRATION_CHECKLIST.md)** — **read before
   trusting the plugin on hardware.** A phased bring-up checklist enumerating every
   array/host assumption, how to verify it, and what to change if it is wrong.
6. **[Test Plan](test-plan.md)** — environment-specific runbook for the VSP E590H lab
   bring-up: PVE acceptance steps + the checklist assumptions + the safety controls for
   testing against a shared production array.

## Reference

- **[Architecture](architecture.md)** — component design, module responsibilities,
  volume naming, state management, and per-operation data flows.
- **[Vendor reference extracts](reference/)** — implementation-relevant Markdown
  distillations of the Hitachi PDFs (with page citations):
  - [`rest-api-extract.md`](reference/rest-api-extract.md) — Configuration Manager
    REST API: sessions, jobs, ldevs, pools, host groups, LUN paths, Thin Image,
    QoS, replication.
  - [`vsp-user-guide-extract.md`](reference/vsp-user-guide-extract.md) — DP pools,
    LDEV/labels, Thin Image CoW/clone semantics, NAA/WWID, dual-controller/ALUA.
  - [`ops-center-common-services-extract.md`](reference/ops-center-common-services-extract.md)
    — Ops Center auth (mostly *not* our direct-to-array path).
  - [`fos-rest-api-extract.md`](reference/fos-rest-api-extract.md) — Brocade Fabric OS
    REST API: login/sessions, Virtual Fabrics (`vf-id`), name-server, and the **FC zoning**
    transaction model — for scripting/verifying the zoning prerequisite during bring-up
    (the SAN switch, *not* the array).

## Project files

- [CHANGELOG](../CHANGELOG.md) — release history.
- [CONTRIBUTING](../CONTRIBUTING.md) — how to build, test, and submit changes.
- [SECURITY](../SECURITY.md) — credential handling, TLS, and how to report issues.
- [`conf/storage.cfg.example`](../conf/storage.cfg.example) — per-platform config examples.
