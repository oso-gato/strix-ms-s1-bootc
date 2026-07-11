# strix — hardware reference (Minisforum MS-S1 MAX, AMD Strix Halo)

> What strix physically is, and why the image contains what it contains.
> Verified June–July 2026 against Minisforum's spec page, ServeTheHome's
> review, AMD/NotebookCheck/TechPowerUp, and kernel.org. This is uniquely the
> strix hardware — a different chassis would change the package set.

## Identity
- **Model:** Minisforum **MS-S1 MAX** (Strix Halo mini-workstation).
- **Platform:** AMD **Strix Halo** — multi-chip APU (Zen 5 CCDs + I/O die with
  GPU/NPU/memory controllers). **No discrete chipset** — all I/O on-package.

## Core spec
| Component | Spec | Build implication |
|---|---|---|
| APU | **Ryzen AI Max+ 395** — 16C/32T Zen 5, 3.0/5.1 GHz | KVM host capacity (R7) |
| iGPU | Radeon 8060S — 40 RDNA 3.5 CUs | no passthrough in v1.0 |
| NPU | XDNA 2 — 50 TOPS | needs BIOS IOMMU on (SVA) |
| Memory | **128 GB LPDDR5X-8000**, soldered, 256-bit, ~215 GB/s measured, UMA | VM headroom |
| Power | 130 W sustained / 160 W peak PPT; 320 W PSU | |
| System drive | 2 TB WD_BLACK SN850X, serial `25281F806642` | install target — serial-pinned + `%pre`-guarded |
| Data drive | 4 TB WD_BLACK SN850X, serial `25278B803296` | permanent: home/containers/vm/log (R9) |
| BIOS | AMI Aptio; **IOMMU enabled by default** | required by NPU SVA **and** libvirt/KVM — never disable |

### Storage slots — IMPORTANT asymmetry
Two M.2 2280 slots, not equal: **slot 1 = PCIe 4.0 x4** (~7 GB/s), **slot 2 =
PCIe 4.0 x1** (~2 GB/s). One drive is throttled to ~¼ speed. The I/O-heavier
role (data drive: containers + VM images) belongs in the **x4** slot — confirm
physically.

## Networking silicon → what the image must carry
| | Chipset | Driver | Kernel floor | strix consequence |
|---|---|---|---|---|
| Wired | 2× **Realtek RTL8127A** 10 GbE | `r8169` (in-tree) | 6.16 (suspend fix 6.18) | nothing layered; Ethernet+SSH live from boot 1; Secure Boot stays ON (no dkms) |
| Wireless | **MediaTek MT7925** Wi-Fi 7 (`wlp99s0`) | `mt7925e` (in-tree) | 6.7 | driver in-tree but **firmware/NM-plugin/supplicant/regdb are not in the base** → baked into the image at build (`mt7xxx-firmware`, `NetworkManager-wifi`, `wpa_supplicant`, `wireless-regdb`). Under bootc this kills the FCOS-era two-boot first-run: Wi-Fi exists on boot 1. |
| Bluetooth | 5.4 (same MT7925 module) | `btmtk` | — | **watch-item resolved**: the 7.0.7-stable regression (dead BT on MT7925/22) was fixed in 7.0.10 upstream / Fedora 7.0.8-200.fc44; F44 now ships 7.1.x, unaffected. Do not roll back to a 7.0.7-era image digest. |

Fedora 44 (current kernel 7.1.3) satisfies every floor.

## Ports (abridged)
Rear: 2× USB4 V2 (80 Gbps), 1× USB-A 10 Gbps, 2× USB-A 2.0, 2× 10 GbE, HDMI
2.1 FRL. Front: 2× USB4 (40 Gbps), USB-A 10 Gbps, audio. Internal: PCIe 4.0
x4 slot (x16 mechanical). No Thunderbolt branding anywhere — the USB4 ports
cover that use class.

## Why the install is serial-pinned
Dual NVMe + the x1/x4 slot asymmetry mean `/dev/nvme*` ordering is not stable.
The kickstart pins the install target by `/dev/disk/by-id` serial and the
`%pre --erroronfail` guard re-verifies serial + size + model of BOTH drives
before any write — flashing the wrong machine or a swapped drive aborts the
install instead of destroying data.
