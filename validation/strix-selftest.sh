#!/bin/bash
# strix-selftest — on-hardware validation of the running strix box against the
# frozen requirements (R1–R15), objective, and amendments. Read-only: it probes
# and reports, it never mutates the host. Pull-and-run from the public repo:
#
#   curl -fsSL https://raw.githubusercontent.com/oso-gato/strix-ms-s1-bootc/main/validation/strix-selftest.sh | sudo bash
#   # add the deep GPU/AI container probes (pulls images, needs network):
#   curl -fsSL https://raw.githubusercontent.com/oso-gato/strix-ms-s1-bootc/main/validation/strix-selftest.sh | sudo bash -s -- --deep
#
# PASS = verified working. FAIL = a requirement is not met. WARN = optional/
# not-yet-configured/needs-a-manual-eyeball (not a spec violation). SKIP = a
# deep probe not run. Exit 0 iff zero FAILs.
export LC_ALL=C
DEEP=0; [ "${1:-}" = "--deep" ] && DEEP=1

P=0; F=0; W=0; S=0
FAILS=(); WARNS=(); SKIPS=()
ok()   { printf '  PASS  %s\n' "$*"; P=$((P+1)); }
no()   { printf '  FAIL  %s\n' "$*"; F=$((F+1)); FAILS+=("$*"); }
warn() { printf '  WARN  %s\n' "$*"; W=$((W+1)); WARNS+=("$*"); }
skip() { printf '  SKIP  %s\n' "$*"; S=$((S+1)); SKIPS+=("$*"); }
sec()  { printf '\n=== %s ===\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "strix-selftest must run as root — pipe to: | sudo bash" >&2; exit 1
fi
CUID=$(id -u core 2>/dev/null || echo 1000)
asuser() { runuser -u core -- env XDG_RUNTIME_DIR="/run/user/$CUID" "$@"; }
UUID_HOME=e3b1c7a5-2f4d-4b8e-9c6a-1d5f7e9b3a21
UUID_CONT=f4c2d8b6-3a5e-4c9f-8d7b-2e6a8f0c4b32
UUID_VM=a5d3e9c7-4b6f-4d0a-9e8c-3f7b9a1d5c43
UUID_LOG=b6e4f0d8-5c7a-4e1b-8f9d-4a8c0b2e6d54

printf 'strix-selftest — %s — hostname=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" "$(hostname)"
printf 'booted image: %s\n' "$(bootc status --format json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["booted"]["image"]["image"]["image"])' 2>/dev/null || echo '?')"

# ── R1 — bare-metal bootc, immutable, SELinux, minimalism ────────────────────
sec "R1 — base & mutation discipline"
[ "$(hostname)" = strix ] && ok "hostname = strix" || no "hostname is $(hostname), expected strix"
bootc status 2>/dev/null | grep -q 'oso-gato/strix-ms-s1-bootc' && ok "bootc booted from the strix image" || warn "could not confirm bootc image ref"
[ "$(getenforce 2>/dev/null)" = Enforcing ] && ok "SELinux enforcing" || no "SELinux not enforcing ($(getenforce 2>/dev/null))"
rpm-ostree status --booted 2>/dev/null | grep -q 'LayeredPackages:' && no "runtime package layering present (R1 violation)" || ok "zero layered packages (host immutable)"
rpm -q smartmontools >/dev/null 2>&1 && warn "smartmontools present (A16 removed it)" || ok "smartmontools absent (A16 minimalism)"
if command -v mokutil >/dev/null 2>&1; then
  mokutil --sb-state 2>/dev/null | grep -qi enabled && ok "Secure Boot enabled" || warn "Secure Boot NOT enabled (check BIOS)"
elif [ -d /sys/firmware/efi ]; then warn "EFI-booted; install mokutil or check BIOS to confirm Secure Boot"
else warn "not EFI-booted — Secure Boot unverifiable"; fi

# ── R2 — wired bond (LACP) + Wi-Fi ───────────────────────────────────────────
sec "R2 — networking (bond0 LACP + Wi-Fi)"
if ip link show bond0 >/dev/null 2>&1; then
  ok "bond0 exists"
  for n in enp97s0 enp98s0; do
    ip link show "$n" master bond0 >/dev/null 2>&1 && ok "$n enslaved to bond0" || no "$n NOT enslaved to bond0"
  done
  if [ -r /proc/net/bonding/bond0 ]; then
    grep -qi '802.3ad' /proc/net/bonding/bond0 && ok "bond mode 802.3ad (LACP)" || no "bond not in 802.3ad mode"
    PARTNER=$(awk '/Partner Mac Address/{print $NF; exit}' /proc/net/bonding/bond0)
    if [ -n "$PARTNER" ] && [ "$PARTNER" != "00:00:00:00:00:00" ]; then ok "LACP partner negotiated with switch ($PARTNER)"
    else no "LACP NOT negotiated — partner MAC is $PARTNER (switch not configured for LACP on these ports?)"; fi
  else no "/proc/net/bonding/bond0 unreadable"; fi
  ip -4 addr show bond0 2>/dev/null | grep -q 'inet ' && ok "bond0 has an IPv4 address" || warn "bond0 has no IPv4 (DHCP not served?)"
else no "bond0 missing"; fi
if nmcli -g GENERAL.STATE device show wlp99s0 >/dev/null 2>&1; then
  st=$(nmcli -g GENERAL.STATE device show wlp99s0 2>/dev/null | head -1)
  case "$st" in *unavailable*|*unmanaged*|"") no "wlp99s0 in bad state: ${st:-absent}";; *) ok "Wi-Fi wlp99s0 managed ($st)";; esac
else no "wlp99s0 not present (MT7925 driver/firmware?)"; fi
[ -f /lib/firmware/regulatory.db ] && ok "regulatory.db present" || no "regulatory.db missing"

# ── R3 — Tailscale subnet router ─────────────────────────────────────────────
sec "R3 — Tailscale subnet router"
systemctl is-active --quiet tailscaled && ok "tailscaled active" || no "tailscaled not active"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && ok "IPv4 forwarding on" || no "IPv4 forwarding off"
[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" = 1 ] && ok "IPv6 forwarding on" || no "IPv6 forwarding off"
BS=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)
if [ "$BS" = Running ]; then
  ok "tailscale BackendState=Running"
  PREFS=$(tailscale debug prefs 2>/dev/null)
  echo "$PREFS" | grep -A3 -i 'AdvertiseRoutes' | grep -q '10.0.50.0/24' && ok "advertising 10.0.50.0/24" || warn "10.0.50.0/24 not advertised (or route not yet approved in admin console)"
  echo "$PREFS" | grep -qi '"RunSSH": *true' && ok "Tailscale SSH (--ssh) enabled (A13)" || warn "Tailscale SSH not enabled"
else warn "tailscale not Running (BackendState=${BS:-unknown}) — run 'sudo strix-setup'"; fi
ip rule 2>/dev/null | grep -q 'lookup 100\|table 100' && ip route show table 100 2>/dev/null | grep -q . && ok "policy routing table 100 populated (strix-table100)" || warn "table-100 underlay route not present (set after tailscale onboard)"

# ── R4/R5 — accounts, key-only SSH, sudo flip ────────────────────────────────
sec "R4/R5 — accounts & auth"
id core >/dev/null 2>&1 && ok "core account exists" || no "core account missing"
case "$(passwd -S root 2>/dev/null | awk '{print $2}')" in L|LK) ok "root password locked";; *) warn "root not shown as locked";; esac
SSHD=$(sshd -T 2>/dev/null)
echo "$SSHD" | grep -qi '^passwordauthentication no' && ok "SSH password auth disabled (key-only)" || no "SSH password auth NOT disabled"
echo "$SSHD" | grep -qi '^permitrootlogin no' && ok "SSH root login disabled" || warn "PermitRootLogin not 'no'"
if [ -f /var/home/.strix-secrets/.setup-done ]; then
  ok "first-boot setup completed (.setup-done)"
  [ -f /etc/sudoers.d/strix-bootstrap ] && no "bootstrap NOPASSWD still present after setup (R5 flip failed)" || ok "sudo flip enforced (bootstrap NOPASSWD gone)"
else warn "first-boot setup not done yet — run 'sudo strix-setup'"; fi
[ -s /var/home/core/.ssh/authorized_keys ] && ok "core authorized_keys present (GitHub-synced)" || warn "no authorized_keys for core yet (strix-keys-sync)"

# ── R6 — Cockpit web console ─────────────────────────────────────────────────
sec "R6 — Cockpit"
systemctl is-active --quiet cockpit.socket && ok "cockpit.socket active" || no "cockpit.socket not active"
ss -tlnH 'sport = :9090' 2>/dev/null | grep -Eq ':9090' && ok "Cockpit listening on :9090" || no "nothing listening on :9090"
grep -Eq '^[[:space:]]*LoginTo[[:space:]]*=[[:space:]]*false' /etc/cockpit/cockpit.conf 2>/dev/null && ok "cockpit LoginTo=false" || warn "cockpit.conf LoginTo=false not found"

# ── R7 — KVM/libvirt virtualization ──────────────────────────────────────────
sec "R7 — virtualization"
[ -e /dev/kvm ] && ok "/dev/kvm present (hardware virt)" || no "/dev/kvm missing (enable SVM in BIOS)"
for s in virtqemud virtnetworkd virtstoraged virtnodedevd virtlogd; do
  systemctl is-active --quiet "$s.socket" && ok "$s.socket active" || no "$s.socket not active"
done
virsh -c qemu:///system list --all >/dev/null 2>&1 && ok "libvirt responds (virsh list)" || no "libvirt not responding"
virsh -c qemu:///system capabilities 2>/dev/null | grep -q "domain type='kvm'" && ok "libvirt reports KVM acceleration" || warn "could not confirm KVM guest capability"
findmnt -no SOURCE /etc/libvirt >/dev/null 2>&1 && ok "/etc/libvirt bind mounted (VM defs on data drive)" || no "/etc/libvirt bind not mounted"

# ── R9 — storage layout (data mounts by UUID) ────────────────────────────────
sec "R9 — storage layout"
chk_mnt() { [ "$(findmnt -no UUID "$1" 2>/dev/null)" = "$2" ] && ok "$1 on $3" || no "$1 NOT on $3 (wrong/absent mount)"; }
chk_mnt /var/home            "$UUID_HOME" strix-home
chk_mnt /var/lib/containers  "$UUID_CONT" strix-containers
chk_mnt /var/lib/libvirt     "$UUID_VM"   strix-vm
chk_mnt /var/log             "$UUID_LOG"  strix-log

# ── R11 — auto-update + key-sync timers ──────────────────────────────────────
sec "R11 — auto-update & key sync"
systemctl is-active --quiet bootc-fetch-apply-updates.timer && ok "bootc auto-update timer armed" || no "bootc-fetch-apply-updates.timer not active"
systemctl is-active --quiet strix-keys-sync.timer && ok "key-sync timer armed" || no "strix-keys-sync.timer not active"

# ── R15 — shared GPU: containers + VM stack + dynamic unified memory ──────────
sec "R15 — shared GPU & AI (P1 containers + P2 memory)"
(lsmod 2>/dev/null | grep -q '^amdgpu' || [ -d /sys/module/amdgpu ]) && ok "amdgpu driver loaded" || no "amdgpu NOT loaded (real GPU absent/failed)"
[ -e /dev/dri/renderD128 ] && ok "/dev/dri/renderD128 present" || no "/dev/dri render node missing"
[ -e /dev/kfd ] && ok "/dev/kfd present (ROCm compute node)" || no "/dev/kfd missing (amdkfd)"
ls -l /dev/dri/renderD128 2>/dev/null | grep -q ' render ' && ok "render node group = render" || warn "render node not group 'render'"
getsebool container_use_devices 2>/dev/null | grep -q ' on$' && ok "container_use_devices on (containers can reach GPU)" || no "container_use_devices off (R15)"
# gfx1151 in the KFD topology (print the target version for the operator)
GFX=""; for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
  [ -r "$f" ] || continue
  simd=$(awk '/^simd_count/{print $2}' "$f"); gtv=$(awk '/^gfx_target_version/{print $2}' "$f")
  [ "${simd:-0}" -gt 0 ] 2>/dev/null && GFX="$gtv"
done
if [ -n "$GFX" ]; then
  [ "$GFX" = 110501 ] && ok "KFD GPU node = gfx1151 (gfx_target_version 110501)" || warn "KFD GPU node present, gfx_target_version=$GFX (expected 110501 for gfx1151)"
else warn "no KFD GPU compute node found (ROCm may not see the iGPU)"; fi
# VM-accel host stack (baked)
[ -f /usr/lib64/qemu/hw-display-virtio-gpu-gl.so ] && ok "virtio-gpu-gl module baked (VM accel)" || no "virtio-gpu-gl module missing"
[ -f /usr/lib64/libvulkan_radeon.so ] && ok "RADV (amdgpu Vulkan) baked" || no "RADV missing"
# P2 — dynamic unified-memory ceiling (120 GiB), live on the kernel
LIM=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null)
[ "$LIM" = 31457280 ] && ok "unified-memory ceiling live: ttm.pages_limit=31457280 (120 GiB)" || no "ttm.pages_limit=$LIM (expected 31457280 = 120 GiB)"
# EMPIRICAL: a rootless container opens the real GPU render node under SELinux
if asuser podman run --rm --device /dev/dri registry.fedoraproject.org/fedora-minimal:44 sh -c 'ls /dev/dri/renderD128' >/dev/null 2>&1; then
  ok "rootless container accesses /dev/dri on real GPU (R15 container half)"
else warn "rootless container GPU access unproven (image pull failed? run once with network)"; fi

# ── A6 — ops: metrics + drive health ─────────────────────────────────────────
sec "A6 — ops (pcp metrics, NVMe SMART)"
for d in pmcd pmlogger pmproxy; do
  systemctl is-active --quiet "$d.service" && ok "$d active" || no "$d not active (no metrics history)"
done
if command -v nvme >/dev/null 2>&1; then
  for dev in /dev/nvme0 /dev/nvme1; do
    [ -e "$dev" ] || continue
    if nvme smart-log "$dev" >/dev/null 2>&1; then
      cw=$(nvme smart-log "$dev" 2>/dev/null | awk -F: '/critical_warning/{gsub(/ /,"",$2);print $2;exit}')
      [ "${cw:-0}" = 0 ] && ok "$dev SMART health OK (critical_warning=0)" || no "$dev SMART critical_warning=$cw"
    else warn "$dev SMART read failed"; fi
  done
else warn "nvme-cli absent (expected in base)"; fi

# ── R8 — claudebox workbench + GitHub App authority ──────────────────────────
sec "R8 — claudebox + GitHub App"
for t in mosh-server tmux fastfetch distrobox gh; do
  command -v "$t" >/dev/null 2>&1 && ok "$t present" || no "$t missing"
done
command -v strix-gh-renew >/dev/null 2>&1 && ok "strix-gh-renew present (A20)" || no "strix-gh-renew missing"
systemctl is-active --quiet strix-gh-app-token.timer && ok "GitHub App token timer armed (A19)" || no "strix-gh-app-token.timer not active"
if asuser distrobox list 2>/dev/null | grep -q claudebox; then
  ok "claudebox exists"
  asuser distrobox enter claudebox -- claude --version >/dev/null 2>&1 && ok "Claude Code runs in claudebox" || warn "claude --version failed in box"
else warn "claudebox not built yet — run 'claudebox-rebuild' (or wait for the daily timer)"; fi
if [ -d /var/home/.strix-secrets/github-app ]; then
  if [ -f /run/strix/gh-token ] && find /run/strix/gh-token -mmin -65 >/dev/null 2>&1; then
    ok "GitHub App token minted & fresh (A19)"
    asuser distrobox enter claudebox -- gh auth status >/dev/null 2>&1 && ok "in-box gh authed as the App" || warn "in-box gh auth status not confirmed (box built?)"
  else no "App configured but token missing/stale — run 'sudo strix-gh-renew'"; fi
else warn "GitHub App not configured (optional github_app block) — claudebox has no standing GitHub identity"; fi

# ── Deep probes (container-based; --deep) ────────────────────────────────────
sec "Deep GPU/AI probes (--deep)"
if [ "$DEEP" = 1 ]; then
  if asuser podman run --rm --device /dev/kfd --device /dev/dri --security-opt seccomp=unconfined \
       docker.io/rocm/dev-ubuntu-24.04:latest rocminfo >/tmp/_rocm.$$ 2>/dev/null; then
    grep -qi 'gfx1151' /tmp/_rocm.$$ && ok "ROCm rocminfo sees gfx1151" || warn "rocminfo ran but gfx1151 not found (HSA_OVERRIDE may be needed)"
  else warn "ROCm container probe failed (image pull / kfd access)"; fi
  rm -f /tmp/_rocm.$$
  if asuser podman run --rm --device /dev/dri docker.io/jrottenberg/ffmpeg:latest -hide_banner -hwaccels 2>/dev/null | grep -qi vaapi; then
    ok "VA-API available to a container (media transcode path)"
  else warn "VA-API container probe inconclusive"; fi
else
  skip "ROCm gfx1151 memory probe (re-run with --deep)"
  skip "VA-API transcode probe (re-run with --deep)"
fi

# ── R13 — the box's own boot-time verifier ───────────────────────────────────
sec "R13 — on-box verifier verdict"
if journalctl -t strix-verify -b >/dev/null 2>&1; then
  V=$(journalctl -t strix-verify -b --no-pager 2>/dev/null | tail -1)
  echo "$V" | grep -q 'all invariants verified' && ok "strix-postinstall-verify: all invariants verified" || warn "verifier last line: ${V:-<none>}"
else warn "no strix-verify journal this boot"; fi

# ── Summary — grouped, actionable punch-list ─────────────────────────────────
sec "SUMMARY"
if [ "$F" -gt 0 ]; then
  printf '\nFAILURES (%d) — requirements NOT met, fix these:\n' "$F"
  for x in "${FAILS[@]}"; do printf '  [FAIL] %s\n' "$x"; done
fi
if [ "$W" -gt 0 ]; then
  printf '\nWARNINGS (%d) — optional / not-yet-configured / manual eyeball:\n' "$W"
  for x in "${WARNS[@]}"; do printf '  [WARN] %s\n' "$x"; done
fi
if [ "$S" -gt 0 ]; then
  printf '\nSKIPPED (%d) — re-run with --deep to cover:\n' "$S"
  for x in "${SKIPS[@]}"; do printf '  [SKIP] %s\n' "$x"; done
fi
printf '\n════════════════════════════════════════════════════════\n'
printf '  strix-selftest:  %d PASS   %d FAIL   %d WARN   %d SKIP\n' "$P" "$F" "$W" "$S"
printf '════════════════════════════════════════════════════════\n'
if [ "$F" -gt 0 ]; then
  echo "RESULT: FAIL — $F requirement(s) not met (listed under FAILURES above)."
  exit 1
fi
echo "RESULT: PASS — no requirement failures. Review the WARNINGS list for optional items."
[ "$DEEP" = 0 ] && echo "Tip: re-run with --deep for the ROCm gfx1151 + VA-API container probes."
exit 0
