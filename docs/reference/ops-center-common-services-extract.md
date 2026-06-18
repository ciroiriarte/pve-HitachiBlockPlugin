# Ops Center Common Services REST API — Authentication & Access Extract

**Source:** *Hitachi Ops Center Common Services REST API Reference Guide*,
Part No. MK-99OPS003-08, April 2024, applies to Hitachi Ops Center version 11.0.1
(107 pages). Local copy: `reference/K1J60300.pdf`.

> **Scope note.** This document covers the **Ops Center Common Services**
> management plane (a centralized identity/user/portal layer that sits in
> *front of* Ops Center products). It is almost certainly **NOT** the path our
> Proxmox plugin uses by default. Our plugin talks **directly to the array
> controller's embedded REST API** (Configuration Manager,
> `https://<array>:443/ConfigurationManager/v1/...`, or the VSP One Block
> `/object/...` REST API). This guide is only relevant if a customer fronts the
> array with a full **Ops Center** deployment and wants to route through Common
> Services for SSO/identity.
>
> **The vast majority of this PDF is irrelevant to our direct-to-array model.**
> The only material that could ever matter to us is the authentication model
> (token issuance) and the product-registry/brokering behavior, summarized
> below. Everything else (managing users, user groups, password policy,
> identity providers, data centers, linked-product CRUD) is Common Services
> administration and out of scope for a storage plugin.

---

## 1. Base URL / port structure (p. 9)

Common Services resources hang off this base URL:

```
https://<host-name-or-IP-address>:<port-number>/portal
```

- Host = a host that can reach Common Services (the Ops Center server), **not**
  the array controller.
- Default port = **443**.
- The `/portal` path prefix is the distinguishing marker of Common Services.
- API sub-paths seen in this guide: `/portal/auth/v1/...`,
  `/portal/security/v1/...`, `/portal/app/v1/...`.
- Note: CORS is **not** supported (p. 9).

### How this differs from the Configuration Manager / array REST API

| | Common Services (this guide) | Direct array REST API (what our plugin uses) |
|---|---|---|
| Host | Ops Center server | Array controller (or CM REST server) |
| Port | 443 (default) | 443 (default) |
| Base path | `/portal/...` (e.g. `/portal/auth/v1/...`) | `/ConfigurationManager/v1/...` (CM) or `/object/...` (VSP One Block) |
| Auth model | **OAuth-style Bearer access token** | CM/array **Session** (`Authorization: Session <token>`) obtained via `POST .../sessions` |
| Purpose | Identity/portal/product registry | Direct storage provisioning |

Both happen to default to port 443, so they are distinguished by the path
prefix and the auth scheme, not the port.

---

## 2. Authentication model (pp. 9-15)

### Token type: Bearer (OAuth-style), NOT array Session

This is the key difference from the direct array path. Common Services issues an
**OAuth-style access token** that is presented as a standard **Bearer** token:

```
Authorization: Bearer <access-token>
```

Example (p. 9): `Authorization: Bearer eyJhbxxx` (a JWT).

Contrast: the embedded Configuration Manager / VSP One Block REST API that our
plugin targets uses `Authorization: Session <token>` obtained from a
`POST .../v1/objects/sessions` (or equivalent) call. **The schemes are not
interchangeable.**

### Obtaining an access token (pp. 13-14)

- **Endpoint:** `POST <base-URL>/auth/v1/providers/builtin/token`
  (i.e. `https://<host>:443/portal/auth/v1/providers/builtin/token`)
- **Execution permission:** None (anyone with valid credentials).
- **Request body (JSON):**
  ```json
  { "username": "TestUser", "password": "password" }
  ```
  Both `username` and `password` are required strings.
- **Response body (JSON):**
  ```json
  { "access_token": "access token", "expires_in": 300, "token_type": "bearer" }
  ```
  - `access_token` (string) — the bearer token.
  - `expires_in` (int) — validity period in **seconds** (300 = 5 minutes).
  - `token_type` (string) — fixed string `bearer`.
- **curl example (p. 14):**
  ```
  curl -v -X POST -H "Content-Type:application/json" -s \
    "https://example.com:443/portal/auth/v1/providers/builtin/token" \
    -d @./request.json
  ```

### Token lifetime / refresh (pp. 10, 14)

- **Access token validity = 5 minutes** (300 s); stated explicitly on p. 10
  ("The validity period of an access token expires five minutes") and in the
  `expires_in: 300` response field.
- There is **no token-refresh endpoint in this guide** — you re-POST credentials
  to the token endpoint to get a new token. (The `userinfo` response on p. 15
  lists an `offline_access` role, hinting OAuth refresh tokens exist at the IdP
  level, but no refresh API is documented here.)
- **Identity-provider (external/federated) users CANNOT obtain an access token**
  via this API and therefore cannot call the Common Services REST API
  (pp. 10, 13). Only built-in users can.
- Separately, a **session idle timeout** setting exists
  (`GET <base-URL>/security/v1/session-settings`, p. 105) returning
  `idleTimeout` (seconds, e.g. 1200) and `autoRefreshWithoutTimeout` (boolean).
  This is UI/session housekeeping, distinct from the 5-minute access-token TTL.

### Operational flow (p. 9)

1. `POST .../auth/v1/providers/builtin/token` with username/password → get
   `access_token`.
2. Put `Authorization: Bearer <access-token>` on every subsequent Common
   Services request **or on a request to a REST API of another product linked
   with Common Services**.

### TLS

All requests are HTTPS. The guide repeatedly tips (pp. 14, 83, 105) to either
supply the CS server's root cert via curl `--cacert` or use `-k` to ignore SSL
errors — same TLS posture our plugin already handles for the array.

### Info about the token holder (p. 15)

`GET <base-URL>/auth/v1/providers/builtin/userinfo` returns OIDC-style claims:
`sub`, `name`, `email`, `https://opscenter/user_groups`,
`https://opscenter/roles` (e.g. `opscenter-user`, `offline_access`,
`uma_authorization`), etc.

---

## 3. Roles / permissions (general observations)

This guide is built around Common Services RBAC, but the roles are
**Common-Services-platform roles**, not storage-array provisioning roles:

- Roles surfaced in `userinfo` (p. 15): `opscenter-user`, `offline_access`,
  `uma_authorization`.
- User/user-group/role management APIs exist (TOC pp. 45-79) but govern access
  to Common Services and linked products — they do **not** map to array-side
  privileges (LDEV create, host-group edit, etc.) that our plugin needs.
- A few admin APIs require "system administrator or security administrator"
  (e.g. session-settings, p. 105). Token issuance itself requires no role.

**Conclusion:** No storage-operation-specific roles/permissions are defined in
this document.

---

## 4. Brokering access to underlying storage REST APIs (pp. 9, 80-83)

This is the most relevant section for understanding whether Common Services is a
storage gateway. **It is essentially a registry + SSO broker, not a proxy.**

- Common Services keeps a registry of "linked products"
  (`GET <base-URL>/app/v1/application-services`, p. 80). Returned product types
  include `AUTOMATOR`, `STORAGE_NAVIGATOR` (Device Manager - Storage Navigator),
  and **`VSP_ONE_BLOCK_ADMINISTRATOR`** (pp. 81-82).
- Each registry entry stores **connection metadata only**: `scheme`, `hostname`,
  `port`, `baseUri`, `loginScreenUri`, `oidcEnabled`, `oidcRedirectUris`,
  `attributes` (e.g. storage `serial` + `model` like "VSP 5600", "VSP One B28").
  Example: a `VSP_ONE_BLOCK_ADMINISTRATOR` entry with `scheme: https`,
  `port: 443`, `attributes: { serial, model }` (p. 82).
- Common Services does **not** expose or proxy storage provisioning calls. The
  only "brokering" is:
  - The same **Bearer access token** can be presented to *a linked product's own
    REST API* (p. 9, step 2) — i.e. SSO via a shared token, not a request proxy.
  - `oidcEnabled` (p. 83) flags whether **single sign-on** can be used with that
    product (`true`/`false`).
  - `statusCheckDisabled` (p. 83) controls whether CS health-checks the product.
- Notably, the VSP One Block Administrator entry in the example shows
  `oidcEnabled: false` (p. 82), and Storage Navigator uses an `sdlauncher://`
  scheme — meaning even the SSO brokering does not uniformly cover the storage
  array REST endpoints.

**Conclusion:** Common Services provides identity/SSO and a product directory.
It does not front, translate, or proxy the array's Configuration Manager /
VSP One Block storage REST API. Storage provisioning calls still go to the
product/array endpoint directly; CS at most supplies a shared bearer token for
SSO if the product has `oidcEnabled: true`.

---

## 5. Bottom line for our plugin

- Our plugin's direct-to-array model (`/ConfigurationManager/v1/...` or VSP One
  Block `/object/...` on port 443, `Authorization: Session ...`) is a
  **different auth model** from Common Services (`/portal/auth/v1/...`,
  `Authorization: Bearer ...`).
- **Nothing in this document needs to be implemented** for the default
  direct-to-array configuration.
- The only scenario where this matters: a customer mandates routing through Ops
  Center Common Services for centralized identity. Even then, CS issues a
  5-minute Bearer token and does **not** proxy storage calls — so the plugin
  would still hit the array/product REST API directly, only swapping the auth
  header to `Bearer` and adding a token-refresh-every-5-minutes loop against
  `POST /portal/auth/v1/providers/builtin/token`. That is a hypothetical future
  feature, not a current requirement.
