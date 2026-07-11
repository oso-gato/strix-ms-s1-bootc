# strix — Objective & Requirements (FROZEN v1.0)

> **Status: FROZEN 2026-07-11.** Signed off by the operator (oso-gato). The build must
> trace to these requirements; any change to this file is an explicit operator
> amendment, not a build-time convenience. Implementation facts (package names, unit
> names, tool capabilities) may be refined by verification; **function may not drift.**

---

# Objective

**Build `oso-gato/strix-ms-s1-bootc` — the complete definition of a home server named
`strix`, expressed as a single bootable container image.**

## The machine

strix is a headless home server — no monitor, no keyboard, administered entirely over
the network. The hardware is a Minisforum MS-S1 MAX mini-workstation: AMD Ryzen AI
Max+ 395 (16 cores / 32 threads), 128 GB of unified memory, two 10 GbE Ethernet
ports, Wi-Fi 7, a 2 TB NVMe system drive, and a 4 TB NVMe data drive.

## The operating-system model

The entire operating system is defined in one place: a `Containerfile` in this
repository. It is built like a container image, published to a registry, and the
machine **boots that image directly** — a technology called bootc (bootable
containers, Fedora's image-based OS model). Nothing is ever installed or configured
by hand on the running machine:

- **Change** = edit the Containerfile, rebuild, push. The machine pulls the new image
  and reboots into it.
- **Update** = automatic. CI rebuilds the image fortnightly on the current Fedora
  base; the machine applies it on a timer. Local settings survive every update.
- **Recovery** = every update keeps the previous image on disk; one command rolls back.

The image starts from Fedora's minimal bootc base and adds only what the machine's
jobs require. Everything below is baked into the image — the first boot is fully
functional, no post-install setup of software.

## What the machine does

1. **Network backbone.** The two 10 GbE ports run as one bonded link (LACP) to the
   switch — the machine's primary, always-on connection. Wi-Fi 7 is a switchable
   secondary uplink: an operator command (`strix-wifi`) can route internet traffic
   over any of three saved wireless networks and back, without touching the wired
   link's role.

2. **Private-network gateway.** The machine runs Tailscale, a mesh VPN that connects
   all of the owner's devices into one private network (a "tailnet"). strix serves as
   the **subnet router**: any device on the tailnet, anywhere in the world, can reach
   the whole home LAN (`10.0.50.0/24`) through it. VPN traffic is pinned to the wired
   bond, so wireless experiments never disturb it.

3. **Container host.** Runs services in Podman containers, with their storage on the
   data drive.

4. **Virtual-machine host.** Runs full virtual machines via KVM/libvirt, using the
   hardware's 16 cores and 128 GB of memory. Everything that defines a VM — disk
   images, machine definitions, firmware state — lives on the data drive, so VMs
   survive a complete reinstall of the operating system.

5. **Web administration.** A browser console (Cockpit, port 9090) covers the whole
   machine: system health, journal, network, containers, **virtual machines**,
   **SELinux**, file management, and OS updates/rollback.

6. **Shell access from anything.** SSH plus mosh (a roaming-friendly remote shell
   that survives sleep, IP changes, and flaky links). Authentication is by SSH key
   only — the keys are whatever the GitHub account `oso-gato` currently publishes,
   fetched when the installer is built and re-synced periodically while running, so
   rotating a key on GitHub is all the key management there is. Every login —
   laptop, tablet, phone, or a browser-based terminal — lands in one **persistent
   shared tmux workspace**: work survives disconnects, all devices see the same
   windows, and each device renders at its own screen size without garbling the
   others.

7. **AI maintenance workbench.** Claude Code runs on the box for host maintenance —
   but never *on* the host. It lives in a disposable container (distrobox) rebuilt
   **daily** from Anthropic's official package repository at the latest release, so
   the tooling is always current while the host image stays untouched. A rebuild
   never interrupts a live session; it waits for you to exit.

## Security posture

- **The repository and every built artifact contain zero secrets.** No passwords, no
  Wi-Fi credentials, no VPN keys, no SSH private material — ever.
- **One human account: `core`.** Root is locked, with SSH login disabled outright.
- **No password can log in over the network.** SSH/mosh are key-only. The single
  password that exists is set at first boot and gates exactly two things: `sudo` and
  the web console.
- SELinux enforcing; Secure Boot compatible (in-tree drivers only); the sensitive
  surfaces (web console, VPN) are bounded at the network layer.

## Storage contract

The **2 TB system drive is disposable** — the OS lives there and can be rewritten at
any time. The **4 TB data drive is permanent** and holds everything that matters.

## Installation

CI publishes two USB installers, built from the same image:

- **`strix-wipe.iso`** — first install: formats the data drive to the declared layout.
- **`strix-preserve.iso`** — reinstall: rewrites the OS, **keeps the data drive
  untouched**. The machine comes back with its homes, containers, VMs, credentials,
  and VPN identity intact — no reconfiguration, no re-authentication.

Both installers refuse to write to the wrong disk: a pre-install guard verifies the
target drive's serial number, size, and model before anything is touched.

## First boot

One interactive step, once: sign in over SSH (key), run `sudo strix-setup`, and
authorize — the box pulls its credentials from the operator's private repo after a
single device-flow approval (or falls back to interactive entry). Those are saved to
the data drive; a future preserve-mode reinstall restores them automatically.

---

# Hardware target

| Item | Part | Implication |
|---|---|---|
| Chassis/board | Minisforum **MS-S1 MAX** (Strix Halo platform — no discrete chipset; all I/O on-package) | |
| APU | AMD **Ryzen AI Max+ 395** — 16C/32T Zen 5, Radeon 8060S (40 CU), XDNA 2 NPU, 128 GB LPDDR5X-8000 soldered | KVM host capacity; BIOS IOMMU stays **Enabled** (NPU SVA + libvirt) |
| Wired NIC | 2× **Realtek RTL8127A** 10 GbE | in-tree `r8169` (≥ 6.16; suspend fix ≥ 6.18) — no dkms, Secure Boot stays ON |
| Wireless | **MediaTek MT7925** (Filogic 360) Wi-Fi 7 → `wlp99s0` | in-tree `mt7925e` (≥ 6.7) + firmware/regdb/NM-plugin/supplicant **baked into the image** |
| Bluetooth | 5.4, same MT7925 module | kernel 7.0 MT7925 BT regression = watch-item; base-image pin strategy per P0 verification |
| System drive | 2 TB WD_BLACK SN850X, serial `25281F806642` | install target, serial-pinned + guarded |
| Data drive | 4 TB WD_BLACK SN850X, serial `25278B803296` | permanent; preserve/wipe per ISO variant |
| Slots | M.2 #1 = PCIe 4.0 x4, #2 = PCIe 4.0 x1 (asymmetric) | I/O-heavy drive belongs in the x4 slot (physical check) |

---

# Functional requirements

## R1 — Base & build discipline
`quay.io/fedora/fedora-bootc:44` (or digest-pinned per the MT7925 watch-item),
**additive only**; the Containerfile is the single source of truth. Package tiers:
① Fedora official repos → ② the vendor's own official RPM repo (`.repo` verbatim,
`gpgcheck=1` — Tailscale, Anthropic) → ③ nothing else. Never `curl|sh`, no COPR, no
language-package-manager installs on the host. No credentials in the repo or any
built artifact. SELinux enforcing. Secure Boot compatible (in-tree drivers only).

## R2 — Wired/wireless networking
bond0 **802.3ad LACP** over both 10 GbE NICs (`enp97s0`+`enp98s0`), route metric 100.
Wi-Fi stack (mt7xxx-firmware, wireless-regdb, NetworkManager-wifi, wpa_supplicant)
**baked at image build** — `wlp99s0` exists on boot 1; no two-boot dance. Three
operator-managed Wi-Fi slots (primary/secondary/tertiary, metric 50 — any associated
Wi-Fi beats bond0 for the default route) controlled by `strix-wifi`
(on/off/switch/status/list/set-primary).

## R3 — Tailscale subnet router
Advertises `10.0.50.0/24`; **no exit node**. IPv4+IPv6 forwarding sysctls; UDP-GRO
forwarding tweak on bond0; Tailscale underlay **pinned to bond0** via fwmark policy
routing (table 100), kept current across DHCP/RA churn by `strix-table100` + timer
(also the v6 populator). Tailscale from the vendor's official Fedora repo.

## R4 — Shell access
(a) Every interactive ssh/mosh login lands in one persistent shared tmux workspace
(`main` session group); per-connection sessions self-destroy on disconnect; work
persists detached.
(b) **Garble-free multi-device rendering**: the device currently typing owns the
geometry (`window-size latest`); idle mismatched clients degrade cleanly (blank
fill, cursor-following crop — never artifacts); `aggressive-resize` for clients on
different windows; forced server-side repaint on every attach/resize so
non-self-redrawing clients (xterm.js / WebSSH / mosh) always get a clean frame.
(c) **mosh** alongside SSH: authenticates over SSH (same keys), then roams over UDP.
(d) **Keys**: `github.com/oso-gato.keys` is the single trust root — authorized for
**`core` only**, injected at build (zero keys fetched = build hard-fails, anti-brick)
and re-synced periodically at runtime (failure-safe: a failed fetch never wipes
existing keys). Root SSH login disabled outright.
(e) **fedora-desktop web access is a first-class path**: the fleet's browser
terminal (Guacamole/WebSSH) reaches strix with the same keys and the repaint policy
above.

## R5 — Identity & password model
One human account: **`core`, UID/GID 1000 pinned**, created at install time (the
image itself is account-free; root locked). **Password never authenticates
ssh/mosh** (`PasswordAuthentication no`). The core password gates exactly `sudo` and
Cockpit web login (PAM). Bootstrap window: sudo is passwordless **until
`strix-setup` completes**; setup sets the password, then **flips sudo to
password-required** and persists both the hash and the flipped state (a preserve
reinstall restores them — sudo is password-gated from restore onward).

## R6 — Web admin (Cockpit)
Socket-activated on `:9090`, all interfaces (access boundary at the network layer —
LAN segmentation + tailnet ACL; no host firewall). Modules: bridge, system, ws,
podman, networkmanager, files, **selinux**, **machines**, plus the image-based
OS-updates/rollback view. `/etc/cockpit/cockpit.conf`: `LoginTo=false`,
`AllowUnencrypted=false`, `MaxStartups=10`.

## R7 — Virtualization
qemu-kvm + libvirt modular daemons + libvirt-dbus + virt-install; `core` authorized
for the system libvirt connection; VMs managed via Cockpit → Virtual machines or
virt-install. **All libvirt image/config/state is persistent on the data drive**:
`/var/lib/libvirt` (disk images, nvram, snapshots, leases) mounts the `strix-vm`
partition; `/etc/libvirt` (domain/network/pool XML, daemon confs) bind-mounts from
that partition, ordered before the libvirt daemons; `/var/log/libvirt` rides
`/var/log`. A preserve reinstall boots with every VM defined and startable. No
VFIO/GPU passthrough in v1.0 (future).

## R8 — Claudebox (AI maintenance workbench)
distrobox on podman; box defined declaratively (rebuild = destroy + recreate from
the manifest); Claude Code from **Anthropic's official RPM repo, `latest` channel**.
**Daily rebuild cadence**: idle → rebuild now; session live → defer, fire on session
exit; on-demand rebuild always available. Host is never mutated by tooling.
Claude Code config: wrapper launches **`--model default` (the recommended alias —
never a fixed model pin)** with `ultracode: true` per session; settings:
`effortLevel: "xhigh"`, `permissions.defaultMode: "auto"`, autoupdater disabled (CLI
currency comes from the rebuild). A minimal deny list enforces the house package
discipline inside the box (no pip --user / npm -g / cargo install / COPR / etc.).
**Scope: clean workbench for host maintenance.** The fedora-bootstrap fleet-policy
layer (managed-only permission pinning, push-gate hooks, GitHub-App auth,
intervention loggers) is explicitly **out of scope — future**.

## R9 — Storage layout
4 TB data drive (`nvme-WD_BLACK_SN850X_4000GB_25278B803296`), GPT, XFS, deterministic
UUIDs, in this order:

| # | Label | Size | Mount |
|---|---|---|---|
| 1 | `strix-home` | 2000 GiB | `/var/home` |
| 2 | `strix-containers` | 825 GiB *(A12)* | `/var/lib/containers` |
| 3 | `strix-vm` | 825 GiB *(A12)* | `/var/lib/libvirt` (+ `etc-libvirt/` → `/etc/libvirt` bind) |
| 4 | `strix-log` | remainder (~75 GiB) *(A12)* | `/var/log` |

*(Implementation-fact refinement per the freeze header: "Label" = GPT
partition name; XFS caps filesystem labels at 12 chars, so partition 2's
filesystem label is `strix-ctr`. Mount units and verification key on UUIDs,
never labels.)*

Mounts are `nofail`; ordering races are closed per-service with mount
dependencies (sshd waits-for `/var/home` but still starts if the drive is
dead — the box must stay reachable; podman and the libvirt daemons are
fail-closed on their mounts so state can never land on the system drive). **Migration note:** this layout
differs from the predecessor FCOS box, so the first strix install is a one-time
`strix-wipe.iso` event; preserve semantics apply thereafter.

## R10 — Install artifacts
Two ISOs from one source via bootc-image-builder: **`strix-preserve.iso`** /
**`strix-wipe.iso`**. Kickstart embeds: `%pre` drive-identity guard (serial + size +
model of both NVMes; abort before any write on mismatch), install target pinned to
the 2 TB by-id path, `core` user + build-fetched SSH keys, and wipe-vs-preserve data
drive handling (preserve = match-or-halt; wipe = recreate per R9).

## R11 — Updates
CI rebuilds and pushes `ghcr.io/oso-gato/strix-ms-s1-bootc` fortnightly; the host
auto-applies via bootc's update timer with scheduled reboot. **Config-intact
guarantee**: updates never touch `/var` and three-way-merge `/etc` (local changes
win); the R13 verify set must pass after every update. Rollback: `bootc rollback` /
Cockpit.

## R12 — First-boot lifecycle
Single boot, fully functional. `sudo strix-setup` (tty1 unit or SSH; flock,
first-one-wins), three paths in precedence order:
1. **Preserve-restore** — persisted secrets on the data drive → silent restore
   (password hash, sudo-flip state, Wi-Fi keyfiles, `tailscaled.state` → rejoins the
   tailnet with no re-auth).
2. **Pull mode** — GitHub **device flow** (single human approval on another device;
   `gh`, minimal scopes) → fetch `strix/firstboot.yaml` from **`oso-gato/ak-private`**
   → apply (password **hash**, Wi-Fi slots, optional `tailscale up --authkey`) →
   persist → **token deleted from the box**. A pasted fine-grained PAT (read-only,
   single-repo) is accepted as the least-privilege alternative. Stale/absent
   authkey → browser-URL Tailscale onboarding for that step only.
3. **Interactive** — prompts, exactly as the predecessor's setup.

Secrets file spec (`strix/firstboot.yaml`): `core_password_hash` (yescrypt — never
plaintext), `wifi.{primary,secondary,tertiary}.{ssid,psk}`, `tailscale_authkey`
(optional; pre-authorized + ACL `autoApprovers` for `10.0.50.0/24` recommended for
zero-touch). SSH private keys never appear in it.

Eliminated from the predecessor (obsolete under bootc): the boot-1 package-layering
service + reboot, both post-layering enable services, the firstboot stamp machinery,
`transpile.py`/`sync_check.py` (no dual-source problem).

## R13 — Verification
`strix-postinstall-verify` (one-shot, journal tag `strix-verify`) asserts: all four
data mounts by UUID; `/etc/libvirt` bind active; bond0 enslaving both NICs;
`wlp99s0` managed; forwarding sysctls; tailscale binary + cockpit listening on
:9090; libvirt sockets live; mosh/tmux/distrobox present; claudebox manifest
present; key-sync timer armed; sudo-flip state consistent with setup state. CI
asserts: image builds, both ISOs build, ≥ 1 SSH key fetched (anti-brick).

## R14 — Docs & succession
README (this objective, quick start, access runbook), HARDWARE and BUILD-SPEC
equivalents, migration note (one-time wipe). On ship: a reference-only banner PR to
`noir-strix-halo-fcos`, which then freezes as the FCOS predecessor.

---

# Decisions log (operator sign-offs)

| # | Decision |
|---|---|
| D1 | Hostname `noir` → **`strix`**; scripts and ISOs renamed accordingly |
| D2 | Repo: **`oso-gato/strix-ms-s1-bootc`**; image: `ghcr.io/oso-gato/strix-ms-s1-bootc` |
| D3 | Login: **`core`** (UID 1000), identical to FCOS convention; root locked, no root SSH |
| D4 | Keys authorize `core` only |
| D5 | Password = sudo + Cockpit only; never ssh/mosh; set post-install over key-auth SSH; sudo passwordless only in the pre-setup bootstrap window |
| D6 | libvirt wholly persistent on the 4 TB drive (`/var/lib/libvirt` + `/etc/libvirt` bind + logs via `/var/log`) |
| D7 | Partitions: home 2000 GiB / containers 750 GiB / VM 750 GiB / log = balance |
| D8 | Auto-updates on, with the config-intact guarantee (R11) |
| D9 | `noir-strix-halo-fcos` goes reference-only when strix ships |
| D10 | Claudebox scope = clean host-maintenance workbench; fleet-policy layer deferred |
| D11 | Claudebox model = recommended alias (no fixed pin), auto mode, ultracode/xhigh |
| D12 | First-boot credentials from `oso-gato/ak-private` via device flow, single approval (R12) |
| D13 | Cockpit gains SELinux + Machines modules |
| D14 | mosh + tmux with the fedora-bootstrap multi-device geometry policy |

# Workplan

| Phase | Work |
|---|---|
| P0 | Verify platform facts (base image/kernel, BIB kickstart capabilities, cockpit-on-bootc, libvirt modular set, vendor repos) — adjust implementation choices, not requirements |
| P1 | Author the image: Containerfile + units + `strix-*` scripts + tmux/mosh/claudebox layers + docs |
| P2 | Installer path: kickstart pair, `%pre` guard, key injection, `build-iso.sh` (BIB) |
| P3 | CI: fortnightly image build→push + ISO build→Release; anti-brick gate |
| P4 | Adversarial multi-agent review (bootc correctness, systemd ordering, kickstart safety, credential audit, R1–R14 traceability) + fixes |
| P5 | Push the build, trigger first CI run, on-box validation checklist, reference-only PR to the FCOS repo |

# Amendments (operator-signed, post-freeze)

| # | Date | Amendment |
|---|---|---|
| A1 | 2026-07-11 | fastfetch runs on **every** interactive SSH/mosh login (banner before the tmux attach; suppressed inside tmux panes). Extends R4. |
| A2 | 2026-07-11 | **v1.0 is held**: further programs are to be added before the 1.0 designation. Releases continue on a v0.9.x pre-series; the published v1.0.0 release/tag was withdrawn. |
| A3 | 2026-07-11 | Host gains `flatpak-session-helper` (backs the box→host `host-spawn` bridge); claudebox gains `bubblewrap` (claude-code sandboxed-bash backend) + `socat` (host-bridge shims). Extends R8. Context: strix will eventually pair as the second autonomous dev-loop host + dev container; base-image groundwork only — the apparatus itself stays out of scope until its own frozen spec. |
| A4 | 2026-07-11 | `cockpit-tailnet-serve` (script + retrying oneshot): publishes Cockpit at `https://strix.<tailnet>.ts.net` via `tailscale serve`, proxying to Cockpit's OWN TLS on loopback (`https+insecure://` backend) so R6's `AllowUnencrypted=false` and the all-interfaces `:9090` LAN path both stay intact. Once applied, `Origins` covers the ts.net + `strix`/`strix.local` names — **raw-IP browser URLs stop working** (by-name access only). Prereqs: MagicDNS + HTTPS Certificates enabled on the tailnet. Extends R6. |
| A5 | 2026-07-11 | **DECLINED**: fedora-bootstrap's tmux `prefix+g` size-policy cycle (`latest → smallest → largest`). R4's automatic `latest`-wins policy stands alone; the manual override adds no resize improvement (tmux windows have exactly one size — every policy only picks who wins and how the loser degrades). |
| A6 | 2026-07-11 | Ops batch (operator picks from the criticality evaluation): **smartmontools** (smartd enabled — drive-health watch on both NVMes, journal alerts), **tcpdump + mtr** (router break-glass; real-root raw sockets), **pcp** (pmcd+pmlogger+pmproxy enabled — historical metrics in Cockpit; operator overrode the "defer" recommendation. *Implementation-fact refinement: Fedora 44 retired the `cockpit-pcp` package — the metrics-history page ships in `cockpit-system` and reads pmproxy's REST API; verified against F44 repos after CI run 5 caught the stale name*), **cockpit-storaged** (storage UI; operator overrode the "skip" recommendation — udisks2 weight accepted), **rsync**, **bash-completion**, **policycoreutils-python-utils** (semanage). Verify unit asserts smartd + pcp collectors. Extends R6/R13. |
| A7 | 2026-07-11 | **DECLINED** from the same evaluation: guestfs-tools (no matching VM pattern — Cockpit dialog drives baked virt-install; apparatus guests are CI-built qcow2 + COW clones), usbutils/pciutils, iperf3 (no 10 GbE peer yet), btop/htop, ncdu, lm_sensors (hwmon already exposed), radeontop (deferred to the inference amendment), jq/tree. |
| A8 | 2026-07-11 | **DECLINED**: a management desktop for strix in any form (host DE was already ruled out — R4d/R5 conflict; the recommended fedora-desktop-lineage container workload and the management-VM alternative were both declined). Cockpit + shell + the network KVM's console are the management surfaces. |
| A9 | 2026-07-11 | **DECLINED**: restic/borgbackup for the data drive. The operator accepts the recorded risk: smartd warns of drive failure, but there is NO backup — drive loss = loss of homes, secrets, container volumes, and VM state. Preserve reinstalls protect against OS loss only. Revisit is a one-line ask. |
| A10 | 2026-07-11 | Repo goes **PUBLIC**: git history rewritten to the `oso-gato` identity (personal name/hostnames removed from author fields; file contents verified clean); drive serials/subnet stay per the noir-established posture (hardware fingerprint, not credentials). ghcr package public so the box can pull auto-updates unauthenticated (R11). |
| A11 | 2026-07-12 | Delta adversarial review (post-P4 code: fix implementations + A1–A7) — 12 confirmed findings applied, 0 refuted. Headline: strix-firstboot-setup now runs **Before=tailscaled.service** (the daemon bootstraps an empty state file at startup, which would have defeated the restore gate and let the snapshot refresh destroy the preserved tailnet identity); parse-failure fallback in pull mode; lock-classifier and identity-bearing-state guards; atomic cockpit.conf writes + localhost origins + mDNS responder on bond0 (`strix.local` now actually resolves); tty1 getty ordering + console restore; claude session lock held wrapper-wide with the rebuild taking it exclusive; per-variant ISO reassembly instructions. |
| A12 | 2026-07-12 | **R9 layout amended** (pre-flash, so still a single wipe migration): containers 750→**825 GiB**, vm 750→**825 GiB**, log = remainder ≈ **75 GiB** (was ~225; steady-state need is ~4–8 GiB — journald self-caps, pcp culls at ~2 weeks). Home unchanged at 2000 GiB. UUIDs/labels/mounts unchanged. |
