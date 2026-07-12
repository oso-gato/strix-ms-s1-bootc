# Changelog

## v0.10.0 — 2026-07-12

Verified milestone (pre-ship — still tidying under this version; not yet
deployed on hardware).

**Hardware-invariant cross-check vs noir** (the FCOS predecessor running on the
SAME physical MS-S1 MAX — L3-proven): strix's bond0/LACP, MT7925 Wi-Fi, and
NVMe-drive config is **byte-exact to noir's proven settings — zero gaps**; an
ultra-verify fan-out refuted every FCOS→bootc mechanism concern (interface
names come from systemd/udev not the kernel; the 6.19→7.1.3 change touched only
Bluetooth, not the mt7925e Wi-Fi driver; drives mount by UUID).

**Shared GPU & AI infrastructure (A17 — R15 new, R1 refined, objective augmented):**
the single iGPU is shared, never VFIO-assigned: containers get direct GPU access
(`/dev/dri` + `/dev/kfd`; `container_use_devices` enabled at first boot), VMs get
paravirtualized virtio-gpu/Venus acceleration (host stack baked: virtio-gpu-gl
leaf module, virglrenderer with Venus verified in the F44 `.so`, mesa RADV/GL —
none pulled by qemu-kvm-core). R1 rewritten to the bootc mutation model: the
Containerfile is the sole mutation channel; runtime layering/overlays forbidden
(verify unit now asserts zero layered packages); leaf-not-metapackage +
capability-relative minimum imported from the fleet principle. CI empirically
exercises the container-GPU path (virtio-gpu node in the harness VM + a rootless
container opening `/dev/dri` under SELinux); Venus-on-amdgpu, ROCm, and VA-API
remain live-host checks. Phase 2 (dynamic unified-memory ceiling) follows.

**Dynamic unified memory (A18 — R15 Phase 2, operator ceiling = 120 GiB):**
`ttm.pages_limit=31457280` via a bootc kargs.d drop-in raises the GPU-mappable
share of the 128 GB from the kernel's ~50% default (~64 GiB) to a 120 GiB
ceiling — dynamic/reclaimable, never a reservation; ~7.5 GiB stays un-pinnable
so the host + a light VM survive a max-size model load. BIOS UMA note added
(512 MB minimum). `amd_iommu=off`, `amdgpu.gttsize` (deprecated), and
`ttm.page_pool_size` deliberately excluded. Karg asserted on the booted
cmdline by the verify unit and CI.

**Pre-ship minimalism corrections:**
- **A16**: removed smartmontools/smartd — redundant. `cockpit-storaged` (via
  udisks2 2.11 + libblockdev-nvme) already surfaces NVMe SMART/health with no
  smartmontools dependency, and `nvme-cli` (base) covers the CLI; smartd's only
  extra was journal-logging whose alerts dead-ended (no MTA). `cockpit-storaged`
  stays as the health surface.
- **A15**: a proposed `%pre` `udevadm settle` was reconsidered and withdrawn —
  not required (R10 is the guard; every prior run resolved by-id without it; a
  race fails safe).
- GPU/unified-memory (AI) support remains research, not built — no written
  requirement yet.

Passed an ultra-verify pass (6 Opus dimensions +
adversarial) measuring build+design against the full requirement set, plus
two empirical layers now standing in CI:

- **Unit tests** (`validation/unit-tests.sh`, 30 cases): extract each pure
  function from the shipped scripts and exercise it — shadow-lock classifier,
  tailnet-identity guard, Wi-Fi slot logic, gateway parser, firstboot.yaml
  parser (incl. malformed→fallback), FIDO-aware key regex, A14 patterns.
  shellcheck across shipped scripts: zero error-level issues.
- **Host-environment integration** (`validation/vm-validate.sh`): installs +
  boots both ISOs in real KVM and asserts the full requirement set; the
  claudebox build runs as non-fatal bonus signal.

Ultra-verify verdict: well-built AND fit-for-purpose; zero confirmed code
defects (R1–R14 / A1–A13 traceability closes). One improvement applied:

- **A14**: `strix-postinstall-verify` now checks tailscale FUNCTION, not just
  presence — once setup has onboarded (`.setup-done`), it asserts tailscaled
  Running + `10.0.50.0/24` advertised + `--ssh` on. Closes the "a logged-out
  box passes verification" gap.

Everything else the pass flagged is verification-depth deferred to the live
MS-S1 MAX (bond0/LACP, MT7925 Wi-Fi, SMART, tailnet-dependent units).

## v0.1.0 — 2026-07-12

Pre-validation series (operator re-designation: nothing has booted on the
live host yet, so the version says so — 0.9.x implied maturity the build
had not earned; the v0.9.x and v1.0.0 tags were withdrawn). Graduates
toward 1.0 only through VM validation (validation/) and then live-host
validation.
Adds A1: fastfetch banner on every ssh/mosh login. Adds A3:
flatpak-session-helper (host) + bubblewrap/socat (claudebox) — box→host
bridge + sandbox groundwork for the future apparatus role. Adds A4:
cockpit-tailnet-serve — Cockpit at https://strix.<tailnet>.ts.net with a
real TLS cert (LAN :9090 path unchanged; by-name access only once applied).
Adds A6 (ops batch): smartmontools/smartd, tcpdump+mtr, pcp (pmcd/pmlogger/pmproxy),
cockpit-storaged, rsync, bash-completion, semanage. A7 records the declined
set; restic backup pending a target decision.

Built to the frozen spec (REQUIREMENTS.md v1.0, R1–R14 / D1–D14).

- bootc image on `quay.io/fedora/fedora-bootc:44` (standard set), additive only;
  single source of truth = `Containerfile`.
- Everything the noir FCOS host did, single-boot (Wi-Fi stack baked — the
  two-boot first-run dance is gone): bond0 LACP, three Wi-Fi slots +
  `strix-wifi`, Tailscale subnet router (10.0.50.0/24) with bond0 underlay pin
  (`strix-table100`), Cockpit on :9090, Podman host, credential-free artifacts.
- New: KVM/libvirt with ALL state persistent on the data drive
  (`/var/lib/libvirt` partition + `/etc/libvirt` bind), Cockpit **Machines** +
  **SELinux** modules.
- New: mosh + shared-`main` tmux workspace (multi-device geometry policy —
  garble-free across Mac/iPad/web terminals).
- New: claudebox — Claude Code `@latest` in a daily-rebuilt distrobox
  (recommended-model alias, auto mode, ultracode/xhigh); host never mutated.
- New: three-path first boot — preserve-restore → ak-private pull (GitHub
  device flow, single approval) → interactive; sudo flip on completion.
- Data drive re-carved (one-time wipe migration from noir; A12 final sizing):
  home 2000 GiB / containers 825 GiB / vm 825 GiB / log remainder (~75 GiB).
- Installers: bootc-image-builder anaconda ISOs, serial-pinned `%pre
  --erroronfail` guard, build-time key injection (anti-brick), offline install,
  installed system tracks ghcr.io `:stable`.
