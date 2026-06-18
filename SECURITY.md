# Security Policy

## Status

This plugin is pre-production and not yet validated on hardware (see the
[README](README.md)). It is provided under the [AGPL-3.0](LICENSE) with no warranty.
Do not deploy it against production data until you have validated it on your own
array per [`docs/INTEGRATION_CHECKLIST.md`](docs/INTEGRATION_CHECKLIST.md).

## Reporting a vulnerability

Please report security-sensitive issues **privately**, not as a public GitHub issue:

- Email: **ciro.iriarte+software@gmail.com**
- Include affected version, impact, and reproduction steps.

You'll get an acknowledgement; please allow time for a fix before public disclosure.

## How the plugin handles sensitive data

- **API credentials** are stored separately from `storage.cfg`, in
  `/etc/pve/priv/hitachiblock/<storeid>.creds` — a JSON file, mode `0600`,
  root-readable only, on the cluster-replicated pmxcfs. They are **stored in
  plaintext** (relying on the root-only permissions of `/etc/pve/priv`), not
  encrypted at rest. Restrict root access accordingly.
- **The LDEV/snapshot registry** (`/etc/pve/priv/hitachiblock/<storeid>.json`) also
  lives under root-only `/etc/pve/priv`.
- **REST session tokens** are held in memory for the life of the process and released
  on logout/deactivate.

## TLS

TLS certificate verification is **opt-in and off by default**, because Hitachi
management endpoints typically ship a self-signed certificate. For any
security-sensitive deployment, enable it and pin a CA bundle:

```
tls_verify 1
tls_ca_file /etc/pve/priv/hitachiblock/ca.pem
```

With verification off, the management connection is encrypted but **not
authenticated** (vulnerable to an active man-in-the-middle on the management
network). Keep the management network trusted/segmented, and prefer enabling
`tls_verify`.

## Other notes

- External command execution (multipath, device tools) uses list-form `exec` (no
  shell), avoiding shell-quoting/injection exposure.
- The plugin issues privileged array operations (create/delete LDEVs, map LUNs,
  snapshot/clone). Use a dedicated API account scoped to the resource groups it needs
  rather than a full-admin account where your array supports it.
