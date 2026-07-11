# Changelog

## v1.0.0 — 2026-07-11

First release, built to the frozen spec (REQUIREMENTS.md v1.0, R1–R14 / D1–D14).

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
- Data drive re-carved (one-time wipe migration from noir): home 2000 GiB /
  containers 750 GiB / vm 750 GiB / log remainder.
- Installers: bootc-image-builder anaconda ISOs, serial-pinned `%pre
  --erroronfail` guard, build-time key injection (anti-brick), offline install,
  installed system tracks ghcr.io `:stable`.
