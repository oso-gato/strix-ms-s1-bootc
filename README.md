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
- **Install**: two USB installers built from the same image:
  - `strix-wipe.iso` — first install / migration: recreates the 4 TB data
    drive (home 2000 GiB · containers 825 GiB · vm 825 GiB · log rest ≈ 75 GiB).
  - `strix-preserve.iso` — reinstall: keeps the data drive (match-or-halt);
    the box comes back with homes, containers, **VMs**, credentials, and
    tailnet identity intact.
  Both refuse the wrong disk: a `%pre` guard verifies drive serial + size +
  model before anything is written. Three ways to get a whole ISO — see
  **Getting the ISO** below.

## Getting the ISO

Each ISO is ~2.2 GiB. Pick whichever suits you — all three yield an identical
whole `strix-wipe.iso`:

1. **From ghcr as a single file (no cap, no reassembly)** — the installer is
   published alongside the container image as an OCI artifact:
   ```bash
   oras pull ghcr.io/oso-gato/strix-ms-s1-bootc:installer   # → strix-wipe.iso + strix-preserve.iso, whole
   ```
   (needs the `oras` CLI; the ghcr package must be public — see maintainer step A.)
2. **From a GitHub Release** — assets are **split** at GitHub's 2 GiB cap:
   download the two `strix-wipe.iso.part*` + `SHA256SUMS`, then
   `cat strix-wipe.iso.part* > strix-wipe.iso` and verify against `SHA256SUMS`.
3. **Build it locally** — `./build-iso.sh` (rootful podman) pulls `:stable`
   from ghcr and writes whole ISOs; `--local` builds the image from the tree first.

## Quick start

1. **Get `strix-wipe.iso`** by any method above.
2. **Flash**: `sudo dd if=strix-wipe.iso of=/dev/rdiskN bs=4m status=progress`.
3. **Boot it** — fully unattended install, auto-reboot, up on Ethernet with
   key-only SSH (keys = whatever `github.com/oso-gato.keys` published at build).
4. **First boot, one step**: `ssh core@strix && sudo strix-setup` — pick
   **pull mode** (approve one GitHub device-flow code; credentials come from
   `oso-gato/ak-private:strix/firstboot.yaml`) or answer prompts. Sets the
   core password (sudo + Cockpit only — never SSH), Wi-Fi slots, Tailscale.
   Everything persists to the data drive; setup ends by removing the
   bootstrap `NOPASSWD` (the **sudo flip**).

## One-time maintainer setup (human, not automated)

These are the only steps a person performs by hand. They are **account/tailnet
level**, done once, and deliberately live outside the image: the box ships no
credentials and hand-edits no config. Nothing here is a file on the host.

**A. GitHub — make auto-updates possible.** The installed box pulls image
updates from `ghcr.io/oso-gato/strix-ms-s1-bootc:stable` **unauthenticated**,
so the package must be public or `bootc` upgrades silently no-op. One click:
*github.com/users/oso-gato → Packages → `strix-ms-s1-bootc` → Package settings
→ Change visibility → Public.* (The repo being public does not make the
package public — they are separate.) This one toggle also serves the ISO OCI
artifact (`:installer`), which lives in the same package.

**B. ak-private — the only secrets.** Fill
`oso-gato/ak-private:strix/firstboot.yaml` (template already committed there):
`core_password_hash` (yescrypt — `mkpasswd -m yescrypt`), Wi-Fi SSIDs/PSKs, and
an optional **pre-approved, tagged** Tailscale auth key. This is the *only*
place any secret lives; `strix-setup` pulls it on first boot after one
device-flow approval.

**C. Tailscale admin console (web) — `login.tailscale.com/admin`.** Not host
config; the same web console you already use.
- **DNS → MagicDNS**: enable (almost certainly already on). Gives the box the
  name `strix.<tailnet>.ts.net` and makes `ssh core@strix` resolve over the
  tailnet. *Required for name-based access.*
- **DNS → HTTPS Certificates**: enable. Lets `tailscale serve` obtain a real
  TLS cert for the `https://strix.<tailnet>.ts.net` Cockpit door (amendment
  A4). **Optional** — skip it and Cockpit is still reachable at
  `https://strix:9090` on the LAN; A4 simply retries until it's on.
- **Access controls (the tailnet policy file — control-plane, not on the box)**:
  add the two entries below. Both are **optional with working fallbacks**, so
  you can skip the ACL entirely if you prefer. Put `autoApprovers` in place
  **before** first boot — route approval is not retroactive.

  ```jsonc
  // Auto-approve the advertised subnet route (else you click "approve" once).
  // Assumes the auth key in firstboot.yaml is tagged tag:router; otherwise use
  // your user email or an autogroup in place of ["tag:router"].
  "autoApprovers": { "routes": { "10.0.50.0/24": ["tag:router"] } },

  // Keyless Tailscale SSH into core (amendment A13). Skip this and
  // `ssh core@strix` over the tailnet still works via your GitHub key + OpenSSH.
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"],
      "dst": ["tag:router"], "users": ["core"] }
  ]
  ```

**D. Live-host validation (once, on the real MS-S1 MAX).** VM validation covers
everything except three hardware invariants — after first boot, confirm
`journalctl -t strix-verify` is clean (or shows only what you expect): the
`bond0` LACP link over both 10 GbE NICs, the MT7925 Wi-Fi (`wlp99s0`), and NVMe
SMART (`smartctl`). These can only be checked on the hardware.

## Daily driving

| Surface | How |
|---|---|
| Web console | `https://strix.<tailnet>.ts.net` (real cert, via tailscale serve) or `https://strix:9090` / `https://strix.local:9090` on the LAN — system, containers, **VMs**, **SELinux**, files, updates/rollback. By-name only once the tailnet serve applies (raw-IP URLs are rejected by the Origins allow-list). Prereq: MagicDNS + HTTPS Certificates enabled on the tailnet. |
| Shell | `ssh core@strix` (LAN: GitHub keys via OpenSSH · tailnet: **Tailscale SSH**, keyless by tailnet identity) or `mosh strix` — every login lands in the shared tmux workspace `main`; devices of different sizes co-exist garble-free. Tailnet prereq: an `ssh` rule in the policy (`src: autogroup:member → dst: tag:router, users: [core]`) |
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
