# Contributing

Thanks for your interest in improving the PVE Hitachi Block Storage Plugin.
Contributions of all kinds are welcome — code, documentation, and especially
**hardware-validation reports** (this plugin is not yet validated on a live array,
so real-world results are the most valuable thing you can contribute).

## Ways to help

- **Validate on hardware.** Work through [`docs/INTEGRATION_CHECKLIST.md`](docs/INTEGRATION_CHECKLIST.md)
  on a lab array and report what passed, what differed, and your model/microcode and
  Proxmox version. Open an issue or PR with the results (and, ideally, executable
  tests under `t/integration/`).
- **Report bugs** with the storage config (credentials redacted), the operation you
  ran, relevant `journalctl -u pvedaemon` output, and `multipath -ll` where relevant.
- **Improve docs** — clarity, accuracy, and coverage.
- **Fix or extend code** — see below.

## Development setup

The plugin is plain Perl; no build step is needed to run the tests.

```bash
make test           # run the Perl unit test suite (prove -Isrc -r t/unit/)
make install        # install into /usr/share/perl5 on a PVE node
make deb            # build the Debian package
```

The unit tests **mock** the array, REST client, and multipath/sysfs layer — they
prove internal logic and PVE plugin contracts, not on-hardware behaviour. Keep them
green (`make test` must pass) and add tests for new logic. Anything that can only be
exercised against a real array belongs in `t/integration/` and in the integration
checklist, not in `t/unit/`.

### Code layout

- `src/PVE/Storage/Custom/HitachiBlockPlugin.pm` — the PVE `StoragePlugin` (entry point).
- `src/PVE/Storage/HitachiBlock/RestClient.pm` — Configuration Manager REST client.
- `src/PVE/Storage/HitachiBlock/Multipath.pm` — FC/multipath/device handling.
- `src/PVE/Storage/HitachiBlock/Config.pm` — credentials + the LDEV/snapshot registry.
- `bin/hitachiblock-repl` — replication CLI.
- `t/unit/` — unit tests · `docs/` — documentation · `conf/` — example configs.

### Code style

- Match the surrounding code: same idioms, comment density, and naming.
- Prefer clear, explicit error handling; fail loudly rather than leaving the array
  in an ambiguous state. Roll back array-side resources on partial failure.
- When you touch the REST API or multipath behaviour, cite the vendor docs
  (`docs/reference/`) and update the integration checklist if you change an assumption.
- Keep the documentation in sync with code in the same change.

## Commit conventions

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`):

- Subject line under 72 characters.
- Explain the *why* in the body, not just the *what*.
- Every commit must be signed off (Developer Certificate of Origin):

  ```
  Signed-off-by: Your Name <you@example.com>
  ```

- This project's content originates from AI prompting; commits include a
  `Generated-By:` trailer to reflect that provenance. Keep the `Co-Authored-By:`
  trailer when present.

Run `make test` before pushing, and update `CHANGELOG.md` and `debian/changelog`
for user-visible changes.

## Reporting security issues

Please do not file security-sensitive reports as public issues — see
[SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the project's
[AGPL-3.0](LICENSE) license.
