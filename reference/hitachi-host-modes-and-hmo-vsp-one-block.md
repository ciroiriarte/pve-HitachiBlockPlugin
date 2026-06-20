# Hitachi Host Modes & HMOs — VSP One Block 20 (current)

> **Source:** *Open-Systems Host Attachment Guide for Virtual Storage Platform Family*,
> document **A3-04-2x, version 10.4.x** (last updated 2025-09-02), Hitachi Vantara.
> Section: *Host modes and host mode options for VSP One Block 20*.
> Retrieved from the Hitachi Vantara documentation portal print API.
>
> This is the **authoritative, current** reference for this project's target array.
> It **supersedes** the older VSP Gen1 extract in
> [`hitachi-host-modes-and-hmo.md`](hitachi-host-modes-and-hmo.md) (MK-90RD7022-14,
> 2014) wherever they differ — and they **do** differ in important ways (see
> [Corrections](#corrections-vs-the-gen1-guide)).

---

## The host mode this plugin uses: `00 [Standard]`

> "When registering Red Hat **Linux** server hosts or IRIX server hosts in the host group."

| Field | Value (from the guide) |
|-------|------------------------|
| **HMOs specific to this host mode** | 68, 88, 91, 122, 131 |
| **HMOs available to this host mode** | 2, 7, 13, 22, 25, 39, 68, 71, 78, 80, 88, 91, 96, 97, 113, 122, 131 |
| **HMO best practice** | **2, 22, 25, 68** |

This is exactly the technician's note — it is a verbatim copy of the `00 [Standard]`
row of this guide. CM REST exposes host mode 0 "Standard" as **`LINUX/IRIX`**, which is
the plugin's default (`host_mode => 'LINUX/IRIX'`).

> **Why Standard/Linux and not VMware mode:** the guide warns that VMware host mode
> speaks SCSI-4 protocol, whereas Windows/Linux use SCSI-3. A host that manages the
> LUN's I/O stack directly (which is exactly what PVE does — one LUN per virtual disk,
> RDM-like) **must** use the host mode matching its own OS (Linux → `00 Standard`), not
> VMware mode, or "unreliable access, errors, and performance problems will result."

---

## Best-practice set `2, 22, 25, 68` — what each one actually does on VSP One Block 20

| HMO | Function (One Block 20 name) | On One Block 20 | Meaning |
|-----|------------------------------|-----------------|---------|
| **2** | VERITAS Database Edition/Advanced Cluster | **Works by default** | Returns *Good Status* (instead of Reservation Conflict) for `TEST UNIT READY` issued without a Persistent Group Reservation key. Active regardless of the setting. |
| **22** | Veritas Cluster Server | **Works by default** | Returns *Good Status* for `MODE SENSE` from a node not holding the reservation. Active regardless of the setting. |
| **25** | Support SPC-3 behavior on Persistent Reservation | **Works by default** | Returns *Good Status* (SPC-3 response) for `PERSISTENT RESERVE OUT` (REGISTER AND IGNORE EXISTING KEY) when there is no key to delete. Active regardless of the setting. |
| **68** | WRITE SAME command support and SCSI ANSI Version 5 support | **Must be set** | "Use this HMO when using the **Page Reclamation** function with a Linux host." This is the UNMAP/discard / thin-reclaim enabler. Requires host re-scan (reissue INQUIRY) after change. |

### ⚠️ Key insight for this project

On **VSP One Block 20**, HMOs **2, 22, and 25 are effectively no-ops** — the guide
states for each that *"this HMO works by default … regardless of whether this HMO is
set."* The reservation-compatibility behavior they describe is **always on**. The only
member of the best-practice bundle that genuinely changes array behavior on One Block 20
is **HMO 68** — which the plugin already sets.

Implications:
- Applying `2,22,25,68` on a **One Block 20** is **harmless and best-practice-compliant**,
  but functionally identical to just `68`.
- The `2,22,25` entries matter mainly for **best-practice alignment / auditing** and for
  **portability to other models** (VSP E series, VSP 5000) where they may *not* be
  default-on. Confirm per model before assuming.
- HMO 68 still needs a host re-scan to take effect; it does not change live I/O instantly.

---

## Full HMO table available to host mode `00 [Standard]`

Verbatim function + description, VSP One Block 20 (rows 97 & 131 sourced from the VSP
5000 table in the same guide, as One Block 20 lists them available but tabulates them
under 5000):

| HMO | Function | Description (condensed, verbatim phrasing) |
|-----|----------|--------------------------------------------|
| **2** | VERITAS Database Edition/Advanced Cluster | Default-on. Good Status for `TEST UNIT READY` without PGR key. |
| **7** | Automatic recognition function of LUN | Returns Unit Attention on LUN add / SCSI path change (`REPORTED LUNS DATA HAS CHANGED`). For SUN StorEdge SAN FS 4.2+ or to get UA on device add/remove. Frequent UA can overload the host. |
| **13** | SIM report at link failure | Issue SIMs when port link-failure count exceeds threshold. *Enable only when requested.* Per-port; set on host group 00 of the port. |
| **22** | Veritas Cluster Server | Default-on. Good Status for `MODE SENSE` from a non-reserving node. |
| **25** | Support SPC-3 behavior on Persistent Reservation | Default-on. Good Status (SPC-3) for `PERSISTENT RESERVE OUT` REGISTER AND IGNORE EXISTING KEY with no key to delete. |
| **39** | Change the nexus specified in the SCSI Target Reset | Apply Target-Reset job-reset / UA ranges to **all** initiators in the host group, not just the issuer (e.g. IBM SVC). |
| **68** | WRITE SAME command support and SCSI ANSI Version 5 support | **Page Reclamation with a Linux host** (UNMAP/discard, thin reclaim). Re-scan host after setting. |
| **71** | Change the Unit Attention for Blocked Pool-VOLs | Change UA from NOT READY → MEDIUM ERROR while a DP pool is blocked. |
| **78** | [HDLM/GAD] non-preferred path option | GAD Metro + HDLM multipath; mark this host group as the non-optimized HDLM path to avoid I/O perf degradation. Wrong host group → load-balance/perf issues. |
| **80** | Multi Text OFF Mode | iSCSI hosts whose OS lacks Multi Text support (e.g. RHEL 5.0). |
| **88** | [GAD] LUN path definition of multiple VSM | GAD migration: converge multiple source target-ports onto one host group with paths to LDEVs of multiple virtual storage machines. **Not supported with HDLM or VxVM DMP multipath.** |
| **91** | [OpenStack/OpenShift(K8s)] Skip I/O check when LUN path is deleted | Host mode 00 only. "Use when manually creating host groups or iSCSI targets used as I/O data paths for OpenStack." (Dynamic LUN-path create/delete — conceptually similar to what this plugin does.) |
| **96** | Change the nexus specified in the SCSI Logical Unit Reset | Apply LU-Reset job-reset / UA ranges to all initiators in the host group (e.g. IBM SVC). |
| **97** | Proprietary ANCHOR command support | **Do NOT enable.** Intended for HNAS but never implemented; unsupported. |
| **113** | SCSI CHAP Authentication Log | iSCSI: output CHAP auth result to the DKC audit log. Per-port; set on iSCSI target 00. |
| **122** | [QoS] Task Set Full response when QoS upper limit is reached | Return TASK SET FULL to a Windows/Linux/VMware host at QoS ceiling instead of holding I/O internally. Setting it for a non-Win/Linux/VMware host may stall I/O. |
| **131** | WCE bit OFF mode | Force `WCE` (Write Cache Enable) bit OFF in MODE SENSE Cache Mode page (08h). For Oracle ASM I/O-perf problems on Linux only; behavior elsewhere not guaranteed. Outside I/F only — internal cache (battery-backed) unchanged. |

---

## Best-practice HMO sets per host mode (VSP One Block 20)

| Host mode | Best practice HMOs |
|-----------|--------------------|
| `00 [Standard]` (Linux/IRIX — **this plugin**) | **2, 22, 25, 68** |
| `03 [HP]` | 2, 12, 22, 25, 60 |
| `09 [Solaris]` | 2, 22, 25 |
| `0F [AIX]` | 2, 15, 22, 25 |
| `21 [VMware Extension]` | 2, 22, 25, 54, 63, 68, 110 |
| `2C [Windows Extension]` | 2, 22, 25, 40, 110 |

Note `2, 22, 25` recur across nearly every host mode — consistent with them being the
default-on reservation-compatibility trio on this platform.

---

## Corrections vs. the Gen1 guide

Differences found against the older extract (`hitachi-host-modes-and-hmo.md`,
MK-90RD7022-14, 2014) — **the current values below win**:

| Item | Gen1 guide (2014) | VSP One Block 20 (current) | Impact |
|------|-------------------|----------------------------|--------|
| **HMO 68 name** | "Support Page Reclamation for Linux" | **"WRITE SAME command support and SCSI ANSI Version 5 support"** | Same intent (Linux page reclamation / UNMAP), but the plugin's option description uses the old name. Cosmetic, worth aligning. |
| **HMO 2 / 22 / 25 behavior** | Set them when Veritas / clustering used | **Work by default on One Block 20** regardless of setting | Best-practice bundle's reservation options are already active; only 68 changes behavior here. |
| **HMO 25 existence** | Not in Gen1 table | **Confirmed: "Support SPC-3 behavior on Persistent Reservation"** | My earlier "pending verification" note is now resolved — confirmed. |
| **HMO 6 name** | "TPRLO" | "TPRLO response change" | Cosmetic. |
| **HMO 15 name** | "HACMP" | "AIX Reservation Conflict response change option" | Cosmetic. |
| **Host-mode-specific HMOs (88, 91, 122, 131, 78, 80, 96, 97, 113)** | Absent (table stopped at 73) | **All now defined** (see table above) | Resolves the prior gap entirely. |

### Net effect on plugin understanding
- The plugin's default `host_mode_options => '68'` is **correct and sufficient** for
  thin reclaim on VSP One Block 20.
- Adopting the technician's `2,22,25,68` is **best-practice-compliant and safe**, but on
  One Block 20 adds no functional change beyond 68 (2/22/25 are default-on).
- The earlier worry that auto-adding **HMO 25** to live host groups would "change
  persistent-reservation semantics" is **overstated for One Block 20**, because the SPC-3
  PR behavior is already on by default. (Still verify for E series / 5000.)
- **HMO 91** ([OpenStack/OpenShift] skip I/O check on LUN-path delete, host mode 00) is
  newly visible and conceptually relevant to a plugin that dynamically deletes LUN paths
  — a candidate to evaluate, not part of the quoted best-practice set.
