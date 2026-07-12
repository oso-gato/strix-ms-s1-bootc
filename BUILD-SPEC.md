# strix — build spec & runbook

> How the pieces fit and how to operate them. The **what/why** is frozen in
> [REQUIREMENTS.md](REQUIREMENTS.md); the hardware rationale is
> [HARDWARE.md](HARDWARE.md). This file is the **how**.

## 1. Artifact flow

```
Containerfile ──podman build──▶ ghcr.io/oso-gato/strix-ms-s1-bootc:stable
      │                                   │
      │                                   ├─ bootc-fetch-apply-updates.timer
      │                                   │  (on the box: pull → apply → reboot)
      └──build-iso.sh (BIB anaconda-iso)──┴─▶ strix-preserve.iso / strix-wipe.iso
                                              (image EMBEDDED — offline install;
                                               installed system tracks :stable)
```

- CI (`.github/workflows/build.yml`) runs fortnightly + on dispatch: image →
  ghcr (`:stable` + `:vX.Y.Z` from CHANGELOG) → both ISOs → GitHub Release.
- BIB injects `%post bootc switch --transport registry <ref>` with exactly the
  ref passed in — which is why `build-iso.sh` always uses the canonical
  ghcr.io ref, even for `--local` builds.

## 2. Image anatomy (sysroot/)

| Piece | Files | Notes |
|---|---|---|
| Data mounts (R9) | `var-home.mount`, `var-lib-containers.mount`, `var-lib-libvirt.mount`, `var-log.mount` | XFS by fixed UUID, `nofail`; races closed per-service via `RequiresMountsFor` drop-ins (sshd, podman, virt daemons) |
| libvirt persistence (R7) | `strix-libvirt-seed` → `etc-libvirt.mount` (bind) → `strix-libvirt-relabel` | seed copies image defaults into `<strix-vm>/etc-libvirt` once; bind lands over `/etc/libvirt`; relabel restores contexts (non-recursive over VM images — libvirt labels those itself) |
| Home seed | `strix-home-seed.service` + kickstart `%post` | closes the shadowed-home trap (installer writes to system-drive `/var/home`; data drive mounts over it) |
| First boot (R12) | `strix-firstboot-setup` (every boot: restore-or-publish + sudo-flip enforcement), `strix-setup` (3-path), `strix-setup-tty1` | sentinel: `/var/home/.strix-secrets/.setup-done` |
| Network (R2/R3) | `bond0(-slave).nmconnection`, `strix-wifi`, `strix-table100(.timer)`, `tailscale-udp-gro`, `99-tailscale.conf` sysctls | bond metric 100, Wi-Fi slots metric 50, fwmark table 100 pin |
| Shell (R4) | `tmux.conf`, `zz-tmux-attach.sh`, sshd drop-in `40-strix.conf`, `strix-keys-sync(.timer)` | shared `main` session group; key-only; GitHub trust root |
| Claudebox (R8) | `distrobox.ini`, `claudebox-init.sh`, `managed-settings.json`, `/usr/bin/claude`, `claudebox-rebuild`, `claudebox-daily`, user units | daily rebuild; defers while a session holds the shared flock; `--model default` + ultracode in the wrapper |
| Sudo model (R5) | `sudoers.d/strix-bootstrap` (NOPASSWD until setup) | removed by `strix-setup`; re-removed every boot post-sentinel; asserted by verify |
| Verification (R13) | `strix-postinstall-verify.service` | 20 assertions, journal tag `strix-verify`, every boot |

## 3. First-boot flows

**Wipe (first install / migration from noir):** boot `strix-wipe.iso` → `%pre`
guard verifies both drives → recreates the data layout → unattended install →
reboot → SSH in (keys already live) → `sudo strix-setup` → pull mode (device
flow against `oso-gato/ak-private:strix/firstboot.yaml`) or interactive →
password + Wi-Fi + `tailscale up` → persist → **sudo flip** → done.

**Preserve (reinstall):** boot `strix-preserve.iso` → `%pre` match-or-halt on
the four strix UUIDs (a noir-era drive halts with instructions) → install →
first boot: `strix-firstboot-setup` silently restores password hash, Wi-Fi
keyfiles, `tailscaled.state` (tailnet rejoin, no re-auth), re-enforces the
sudo flip. No prompts, no operator action.

**firstboot.yaml spec** (in ak-private, never in this repo):
```yaml
core_password_hash: "$y$j9T$..."      # mkpasswd -m yescrypt
wifi:
  primary:   { ssid: "...", psk: "..." }
  secondary: { ssid: "...", psk: "..." }   # optional
  tertiary:  { ssid: "...", psk: "..." }   # optional
tailscale_authkey: "tskey-auth-..."   # optional; pre-approved + tagged;
                                      # autoApprovers ACL for 10.0.50.0/24
                                      # must predate first advertisement
```

## 3b. Shared GPU (R15) — how to use it

The single Radeon 8060S is shared (never VFIO-passed-through — that would remove
it from the host and every GPU container). Three consumers, concurrently:

**Containers (direct device access; `container_use_devices` is enabled at first
boot by `strix-gpu-selinux`):**
```bash
# media transcode (VA-API — e.g. Plex/Jellyfin; the container brings its own libva)
podman run -d --device /dev/dri ... 
# AI / ROCm (llama.cpp, vLLM — ROCm userspace lives in the container;
# HSA_OVERRIDE_GFX_VERSION, if needed for gfx1151, is container-side)
podman run -d --device /dev/kfd --device /dev/dri ...
```

**VMs (paravirtualized virtio-gpu; GL via virgl, Vulkan via Venus):** add to the
domain XML (`virsh edit`, or Cockpit → edit; requires shared memfd memory):
```xml
<domain ... xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
  <memoryBacking><source type="memfd"/><access mode="shared"/></memoryBacking>
  <devices>
    <video><model type="virtio" heads="1" primary="yes">
      <acceleration accel3d="yes" rendernode="/dev/dri/renderD128"/>
    </model></video>
  </devices>
  <qemu:commandline>  <!-- Venus (Vulkan) — device props, not libvirt attrs -->
    <qemu:arg value="-set"/><qemu:arg value="device.video0.blob=on"/>
    <qemu:arg value="-set"/><qemu:arg value="device.video0.venus=on"/>
    <qemu:arg value="-set"/><qemu:arg value="device.video0.hostmem=8G"/>
  </qemu:commandline>
</domain>
```
The guest needs Mesa's virtio-gpu/Venus drivers (any current Linux guest);
libvirt grants the qemu process the render node itself (device ACL + svirt).
Headless-safe: Venus renders via RADV directly on the render node, no compositor.

**Unified memory (R15 Phase 2):** the GPU's share of the 128 GB is a dynamic
**ceiling** — `ttm.pages_limit=31457280` (120 GiB) via
`/usr/lib/bootc/kargs.d/10-strix-uma.toml`; pages pin only while a model holds
them and reclaim on release. Change the ceiling = edit that one line, rebuild,
`bootc upgrade`. BIOS: keep the iGPU/UMA frame buffer at 512 MB (a BIOS
carveout is the only *static* reservation). Live check:
`cat /sys/module/ttm/parameters/pages_limit` → `31457280`, and an AI container
reports ~120 GiB available GPU memory.

**Live-host checks (GPU items — CI proves stack + container device access +
the ceiling karg only):**
`vulkaninfo --summary | grep -i radv` (RADV sees gfx1151) · a VA-API transcode in a
container · ROCm device visible in an AI container (~120 GiB reported) · Venus
accel in a test VM.

## 4. Operating notes

- **Updates**: automatic (base-enabled `bootc-fetch-apply-updates.timer`,
  ~8 h check, auto-reboot). Manual: `sudo bootc upgrade --apply`. Rollback:
  `sudo bootc rollback` or Cockpit's deployments page (view/rollback only —
  image *switches* are CLI-only upstream as of 2026).
- **VMs ride through reinstalls**, not through unattended update reboots —
  running guests are shut down when the timer reboots. Acceptable for a
  homelab; pin the timer with a drop-in if a guest ever becomes precious.
- **Data drive absent = libvirt deliberately DOWN (fail-closed).** The box
  boots (mounts are `nofail`; sshd uses `WantsMountsFor` so SSH survives),
  but the libvirt daemons carry `RequiresMountsFor` on `/var/lib/libvirt` +
  `/etc/libvirt` and refuse to start — a daemon running against image config
  would write VM images/nvram onto the disposable system drive. Podman is
  fail-closed the same way.
- **ghcr visibility**: the box pulls `:stable` unauthenticated — the ghcr
  package must be public (or the box needs a pull secret; not shipped).
- **mosh** uses UDP 60001–60999 — no host firewall; over the tailnet, allow
  that range in the Tailscale ACL if it is restrictive.
- **cockpit-machines** talks to `qemu:///system` via libvirt-dbus; `core` is
  in the `libvirt` group and wheel — don't reconfigure libvirt's
  `access_driver` to polkit (documented libvirt-dbus conflict).
- **Local ISO build on macOS**: `podman machine set --rootful` once, then
  `./build-iso.sh --local`.

## 5. Known watch-items

- The `%post` home-seed runs in the Anaconda chroot; `strix-home-seed.service`
  is the runtime fallback if that environment misbehaves. If BOTH fail, the
  box is keyless on a wipe install (unreachable) — validate in a VM before
  hardware (see §6).
- SELinux label provenance when building the image on non-SELinux CI runners
  (GH ubuntu-24.04): upstream-proven path (BIB's own CI), plus `bootc
  container lint` gates the build. First on-box boot should still eyeball
  `sudo ausearch -m AVC -ts recent`.
- `etc-libvirt` bind content does not participate in bootc's `/etc` 3-way
  merge — new libvirt default configs arriving in future images won't appear
  in the persisted copy (libvirt configs are stable; revisit if a release
  note says otherwise).
- BIB's `--type anaconda-iso` is flagged legacy upstream (successor:
  `bootc-installer`). `build-iso.sh` pins the BIB image by digest; when
  bumping, re-verify the kickstart-injection contract or migrate types.
- XFS caps filesystem labels at 12 chars, so `strix-containers` exists only
  as the GPT partition name; the filesystem label is `strix-ctr`. Nothing
  operational keys on labels — mounts and verify use UUIDs.

## 6. Pre-hardware validation (two-disk VM)

Boot each ISO in a VM with two virtual NVMe disks sized ~2 TB/~4 TB and fake
serials matching the by-id pins (libvirt `<serial>`):
1. wipe ISO on empty disks → install completes; `lsblk -f` shows the four
   labeled filesystems; SSH by key works; `strix-verify` clean.
2. preserve ISO on the result → no prompts; creds restored; VMs defined.
3. preserve ISO on BLANK disks → `%pre` halts with the migration message.
4. wrong-size/wrong-model disks → `%pre` halts before any write.
