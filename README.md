# strix — Minisforum MS-S1 MAX (AMD Strix Halo) home server, as a bootc image

**strix** is a headless home server defined entirely by one `Containerfile` and
booted directly as a container image (Fedora **bootc**). It is a **Tailscale
subnet router** (`10.0.50.0/24`), **Podman container host**, **KVM/libvirt VM
host**, and **Cockpit web console** — with a shared tmux workspace over
SSH/mosh and an on-box, daily-rebuilt **Claude Code workbench** (claudebox)
that never mutates the host. No artifact carries a credential.

The operator-signed spec is **[REQUIREMENTS.md](REQUIREMENTS.md)** (frozen
v1.0; R1–R14, D1–D14) — the build traces to it. Hardware rationale:
**[HARDWARE.md](HARDWARE.md)**. Design + runbook: **[BUILD-SPEC.md](BUILD-SPEC.md)**.
strix succeeds [`noir-strix-halo-fcos`](https://github.com/oso-gato/noir-strix-halo-fcos)
(same machine, FCOS/Ignition era — now reference-only).

## How the OS works

- **Source of truth**: `Containerfile` → CI builds fortnightly → pushes
  `ghcr.io/oso-gato/strix-ms-s1-bootc:stable`.
- **Updates**: the box auto-applies from the registry (`bootc`), reboots, and
  keeps the previous image for one-command rollback (`sudo bootc rollback`).
  Local config (`/etc`) survives updates; `/var` is never touched.
- **Install**: CI Releases carry two USB installers built from the same image:
  - `strix-wipe.iso` — first install / migration: recreates the 4 TB data
    drive (home 2000 GiB · containers 750 GiB · vm 750 GiB · log rest).
  - `strix-preserve.iso` — reinstall: keeps the data drive (match-or-halt);
    the box comes back with homes, containers, **VMs**, credentials, and
    tailnet identity intact.
  Both refuse the wrong disk: a `%pre` guard verifies drive serial + size +
  model before anything is written.

## Quick start

1. **Build** (or grab a Release): `./build-iso.sh` (rootful podman; `--local`
   to build the image from the working tree). Release assets come **split**
   (GitHub's 2 GiB cap): `cat strix-wipe.iso.part* > strix-wipe.iso`, then
   verify against `SHA256SUMS`.
2. **Flash**: `sudo dd if=strix-wipe.iso of=/dev/rdiskN bs=4m status=progress`.
3. **Boot it** — fully unattended install, auto-reboot, up on Ethernet with
   key-only SSH (keys = whatever `github.com/oso-gato.keys` published at build).
4. **First boot, one step**: `ssh core@strix && sudo strix-setup` — pick
   **pull mode** (approve one GitHub device-flow code; credentials come from
   `oso-gato/ak-private:strix/firstboot.yaml`) or answer prompts. Sets the
   core password (sudo + Cockpit only — never SSH), Wi-Fi slots, Tailscale.
   Everything persists to the data drive; setup ends by removing the
   bootstrap `NOPASSWD` (the **sudo flip**).

> **Tailnet prep for zero-touch**: put the `autoApprovers` ACL for
> `10.0.50.0/24` in place **before** first boot and use a pre-approved auth
> key in `firstboot.yaml` — route approval is not retroactive.

## Daily driving

| Surface | How |
|---|---|
| Web console | `https://strix:9090` — system, containers, **VMs**, **SELinux**, files, updates/rollback |
| Shell | `ssh core@strix` or `mosh strix` — every login lands in the shared tmux workspace `main`; devices of different sizes co-exist garble-free |
| Wi-Fi uplink | `sudo strix-wifi {on\|off\|switch\|status\|list\|set-primary}` (bond0 stays the tailnet underlay) |
| VMs | Cockpit → Virtual machines, or `virt-install`; all VM state lives on the data drive |
| Claude | `claude` — runs in the claudebox (rebuilt daily at Anthropic's `latest`, recommended-model alias, ultracode); `claudebox-rebuild` forces a refresh |
| OS | automatic; `sudo bootc status` / `sudo bootc rollback` |

## Keys, password, root — the whole security model in one paragraph

`github.com/oso-gato.keys` is the single trust root: those keys are authorized
for `core` at ISO build **and** re-synced daily on the box (rotate on GitHub,
done). Root is locked with SSH login disabled; `core` is the only account.
Nothing authenticates by password over the network — the one password (set at
first boot) gates `sudo` and the Cockpit login only. SELinux enforcing;
Secure Boot compatible (in-tree drivers only); Cockpit/VPN exposure is bounded
at the network layer.
