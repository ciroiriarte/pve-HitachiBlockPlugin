# Hitachi Host Modes & Host Mode Options (HMO) — Reference

> ⚠️ **SUPERSEDED for the project's target array.** This is the VSP **Gen1** (2014)
> edition. For VSP One Block 20 — the array this plugin targets — use
> [`hitachi-host-modes-and-hmo-vsp-one-block.md`](hitachi-host-modes-and-hmo-vsp-one-block.md),
> which corrects HMO 68's name and shows that HMOs 2/22/25 are default-on there.
> Keep this file only as historical context for older VSP Gen1 arrays.

> **Source:** *Hitachi Virtual Storage Platform — Provisioning Guide for Open Systems*,
> document **MK-90RD7022-14**, © 2010–2014 Hitachi, Ltd. (local copy:
> `reference/rd702214.pdf`, chapter 7 "Managing logical volumes", pp. 7-9 – 7-13).
>
> **Scope caveat:** This is the **VSP Gen1** edition. Its HMO table covers numbers
> **2–73 only**. Newer options used by current arrays — e.g. **25, 78, 80, 88, 91,
> 96, 97, 113, 122, 131** — are **not defined in this PDF**; they require the
> **VSP One Block / SVOS RF** *Open-Systems Host Attachment Guide* (MK-90RD7037) or
> the *REST API / Provisioning Guide* for the specific platform. See
> [Gap vs. current arrays](#gap-vs-current-arrays) below.

Host modes and HMOs **must be set on the port/host group before the host is
connected**. Changing them after connection is not recognized by the host until it
re-scans.

---

## Host modes for host groups

| Mode | Name | When to select |
|------|------|----------------|
| `00` | Standard | Red Hat **Linux** server hosts or IRIX hosts. *(This is what the PVE plugin uses; CM REST displays mode 0 as `LINUX/IRIX`.)* |
| `01` | VMware | VMware server hosts (deprecated in newer REST; prefer 21). |
| `03` | HP | HP-UX server hosts. |
| `05` | OpenVMS | OpenVMS server hosts. |
| `07` | Tru64 | Tru64 server hosts. |
| `09` | Solaris | Solaris server hosts. |
| `0A` | NetWare | NetWare server hosts. |
| `0C` | Windows | Windows server hosts (no LUSE expansion). |
| `0F` | AIX | AIX server hosts. |
| `21` | VMware Extension | VMware hosts; includes `01` and allows LUSE expansion. Preferred for new VMware hosts. |
| `2C` | Windows Extension | Windows hosts; includes `0C` and allows LUSE expansion. Preferred for new Windows hosts. |
| `4C` | UVM | Another VSP mapped via Universal Volume Manager (external storage). |

**Cautions (paraphrased):**
- New Windows host → prefer `2C` (superset of `0C`, enables LUSE).
- New VMware host → prefer `21` (superset of `01`, enables LUSE).
- For VMware RDM, set the host mode matching the **guest OS**.

---

## Host mode options (HMO) — VSP Gen1 table (2–73)

Verbatim "When to select this option" text from MK-90RD7022-14.

| HMO | Name | When to select |
|-----|------|----------------|
| **2** | VERITAS Database Edition/Advanced Cluster | When VERITAS Database Edition/Advanced Cluster for Real Application Clusters **or VERITAS Cluster Server 4.0+ (I/O fencing function)** is used. |
| 6 | TPRLO | Host mode 0C/2C Windows + Emulex HBA + mini-port driver with `TPRLO=2`. |
| 7 | Automatic recognition function of LUN | Host mode 00 Standard or 09 Solaris + SUN StorEdge SAN Foundation SW 4.2+; auto-recognize device add/remove with genuine SUN HBA. |
| 12 | No display for ghost LUN | Host mode 03 HP; suppress device files for LUNs with no defined path. |
| 13 | SIM report at link failure¹ | Be informed by SIM when link-failure count between ports exceeds threshold. |
| 14 | HP TruCluster with TrueCopy | Host mode 07 Tru64; TruCluster sets a cluster on each P-VOL/S-VOL for TrueCopy/UR. |
| 15 | HACMP | Host mode 0F AIX; HACMP 5.1.0.4+ / 4.5.0.13+ / 5.2+. |
| **22** | Veritas Cluster Server | When Veritas Cluster Server is used. |
| 23 | REC Command Support¹ | Shorten host-side recovery time if data transfer failed. |
| 33 | Set/Report Device Identifier enable | Host mode 03 HP or 05 OpenVMS²; enable device-nickname commands / set UUID to identify a volume from the host. |
| 39 | Change the nexus specified in the SCSI Target Reset | Control, per host group on Target Reset: range of jobs reset, and range of UAs (Unit Attentions) defined. |
| 40 | V-VOL expansion | Host mode 0C/2C Windows; auto-recognize DP-VOL capacity after expansion. |
| 41 | Prioritized device recognition command | Execute commands to recognize the device preferentially. |
| 42 | Prevent "OHUB PCI retry" | IBM Z10 Linux. |
| 43 | Queue Full Response | HP-UX host; respond Queue Full instead of Busy when command queue is full. |
| 48 | HAM S-vol Read Option | Avoid MCU→RCU failover when apps issue Reads above threshold to a HAM-pair S-VOL. |
| 49 | BB Credit Set Up Option 1³ | Adjust buffer-to-buffer credits (long-distance TrueCopy, Point-to-Point). Use **with HMO 50**. |
| 50 | BB Credit Set Up Option 2³ | As above; use **with HMO 49**. |
| 51 | Round Trip Set Up Option³´⁴ | Adjust host-I/O response time (long-distance TrueCopy, Point-to-Point). Use **with HMO 65**. |
| 52 | HAM and Cluster software for SCSI-2 Reserve | Cluster software using SCSI-2 reserve in a HAM environment. |
| 54 | (VAAI) Support Option for EXTENDED COPY | VMware ESX/ESXi 4.1 VAAI. |
| 57 | HAM response change | Host mode 0C/2C/01/21 in a HAM environment. |
| 60 | LUN0 Change Guard | HP-UX 11.31; prevent add/delete of LUN0. |
| 61 | Expanded Persistent Reserve Key | When 128 reserve keys are insufficient for the host. |
| 63 | (VAAI) Support Option for vStorage APIs (T10) | VMware ESXi 5.0 VAAI for T10. |
| 65 | Round Trip extended set up option³ | Adjust host-I/O response time with HMO 51 (max processor-blade configs). Use **with HMO 51**. |
| 67 | Change of the ED_TOV value | OPEN FC port, FC direct connection, port type Target/RCU Target. |
| **68** | Support Page Reclamation for Linux | When using the **Page Reclamation** function from a Linux host (enables SCSI UNMAP / thin-pool reclaim). |
| 69 | Online LUSE expansion | Notify host of LUSE volume capacity expansion. |
| 71 | Change the Unit Attention for Blocked Pool-VOLs | Change UA from NOT READY to MEDIUM ERROR during pool-VOL blockade. |
| 72 | AIX GPFS Support | GPFS on an AIX host. |
| 73 | Support Option for WS2012 | Windows Server 2012 Thin Provisioning + ODX. |

**Footnotes (from the guide):**
1. Configure these options only when requested to do so (by Hitachi support).
2. Set the UUID when HMO 33 is used with host mode 05 OpenVMS.
3. HMOs 49, 50, 51, 65 are enabled only for the 8UFC/16UFC package.
4. Set HMO 51 on **both** ports of MCU and RCU.

---

## Gap vs. current arrays

The technician's note (for the `LINUX/IRIX` host mode on a current array) lists HMOs
not present in this Gen1 PDF. Confirmed mappings come from the matching items above;
the rest **must be verified against the VSP One Block / SVOS RF guide**:

| HMO | Confirmed here? | Notes |
|-----|-----------------|-------|
| 2  | ✅ | VERITAS Database Edition/Advanced Cluster. |
| 22 | ✅ | Veritas Cluster Server. |
| 25 | ❌ not in MK-90RD7022-14 | Per newer Hitachi docs: **Support SPC-3 behavior on Persistent Reservation** (SCSI-3 PR; matters for clustered shared LUNs). *Verify in VSP One Block guide.* |
| 68 | ✅ | Support Page Reclamation for Linux (UNMAP/discard). |
| 78, 80, 88, 91, 96, 97, 113, 122, 131 | ❌ not in this edition | Defined only in newer platform guides; confirm before relying on them. |

> **Best-practice set quoted by the technician for this host mode:** `2, 22, 25, 68`.
> The PVE plugin currently defaults `host_mode_options` to `68` only
> (`src/PVE/Storage/Custom/HitachiBlockPlugin.pm`).
