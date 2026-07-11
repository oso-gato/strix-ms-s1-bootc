#!/bin/bash
# assert-in-vm.sh — the in-VM half of vm-validate.sh phase 2: asserts the
# booted system against REQUIREMENTS.md, run as root over SSH on the first
# boot after a wipe install. Hardware-dependent invariants (bond0 on
# enp97s0/enp98s0, MT7925 wlp99s0, NVMe SMART) CANNOT hold in a VM — those
# are asserted to fail EXACTLY as expected and are deferred to the live-host
# checklist; everything else must pass here.
set -uo pipefail
export LC_ALL=C

# $1 (optional): the ephemeral validation key BODY (base64 field only). The
# builder rewrites every key's COMMENT to a provenance tag, so we assert on
# the body, not the injected comment.
KEYBODY="${1:-}"

FAILS=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "── R9: data mounts by UUID + A12 sizes ──"
chk "/var/home on strix-home"            sh -c '[ "$(findmnt -no UUID /var/home)" = "e3b1c7a5-2f4d-4b8e-9c6a-1d5f7e9b3a21" ]'
chk "/var/lib/containers on strix-ctr"   sh -c '[ "$(findmnt -no UUID /var/lib/containers)" = "f4c2d8b6-3a5e-4c9f-8d7b-2e6a8f0c4b32" ]'
chk "/var/lib/libvirt on strix-vm"       sh -c '[ "$(findmnt -no UUID /var/lib/libvirt)" = "a5d3e9c7-4b6f-4d0a-9e8c-3f7b9a1d5c43" ]'
chk "/var/log on strix-log"              sh -c '[ "$(findmnt -no UUID /var/log)" = "b6e4f0d8-5c7a-4e1b-8f9d-4a8c0b2e6d54" ]'
chk "/etc/libvirt bind active"           sh -c 'findmnt -no SOURCE /etc/libvirt | grep -q .'
chk "libvirt config seeded (qemu.conf under bind)" test -s /etc/libvirt/qemu.conf
# A12: containers/vm = 825 GiB (844800 MiB) each; log = remainder ~75 GiB.
part_mib() { lsblk -bno SIZE "$(readlink -f "/dev/disk/by-uuid/$1")" | head -1 | awk '{printf "%d", $1/1048576}'; }
chk "strix-ctr size 825 GiB"  sh -c '[ "$(lsblk -bno SIZE $(readlink -f /dev/disk/by-uuid/f4c2d8b6-3a5e-4c9f-8d7b-2e6a8f0c4b32))" -ge 885000000000 ]'
chk "strix-vm size 825 GiB"   sh -c '[ "$(lsblk -bno SIZE $(readlink -f /dev/disk/by-uuid/a5d3e9c7-4b6f-4d0a-9e8c-3f7b9a1d5c43))" -ge 885000000000 ]'
chk "strix-log 60-90 GiB"     sh -c 's=$(lsblk -bno SIZE $(readlink -f /dev/disk/by-uuid/b6e4f0d8-5c7a-4e1b-8f9d-4a8c0b2e6d54)); [ "$s" -ge 64000000000 ] && [ "$s" -le 97000000000 ]'

echo "── R4/R5: identity, keys, sudo, sshd ──"
chk "core UID 1000 GID 1000"             sh -c '[ "$(id -u core)" = 1000 ] && [ "$(id -g core)" = 1000 ]'
chk "core in wheel+libvirt"              sh -c 'id -nG core | grep -q wheel && id -nG core | grep -q libvirt'
if [ -n "$KEYBODY" ]; then
  chk "authorized_keys carries the injected key (by body)" grep -qF "$KEYBODY" /var/home/core/.ssh/authorized_keys
else
  chk "authorized_keys has >=1 valid key" sh -c 'ssh-keygen -lf /var/home/core/.ssh/authorized_keys'
fi
chk "root password locked"               sh -c 'getent shadow root | cut -d: -f2 | grep -Eq "^[!*]"'
chk "bootstrap NOPASSWD present (pre-setup)" test -f /etc/sudoers.d/strix-bootstrap
chk "sshd: PasswordAuthentication no"    sh -c 'sshd -T 2>/dev/null | grep -qi "^passwordauthentication no"'
chk "sshd: PermitRootLogin no"           sh -c 'sshd -T 2>/dev/null | grep -qi "^permitrootlogin no"'
chk "setup MOTD published (fresh box)"   test -f /etc/motd.d/10-strix-setup

echo "── R6: cockpit ──"
chk "cockpit.socket active"              systemctl is-active --quiet cockpit.socket
chk ":9090 listening any-interface"      sh -c 'ss -tlnH "sport = :9090" | grep -Eq "(\*|0\.0\.0\.0|\[::\]):9090"'
chk "cockpit.conf LoginTo=false"         grep -Eq '^\s*LoginTo\s*=\s*false' /etc/cockpit/cockpit.conf
chk "cockpit modules installed"          rpm -q cockpit-machines cockpit-selinux cockpit-storaged

echo "── R7: virtualization ──"
for s in virtqemud virtnetworkd virtstoraged virtnodedevd virtlogd; do
  chk "$s.socket active" systemctl is-active --quiet "$s.socket"
done
chk "virsh reaches qemu:///system"       sh -c 'virsh -c qemu:///system version --daemon'

echo "── R8/R4: workbench + shell layer ──"
chk "tmux/mosh/fastfetch/distrobox/gh present" sh -c 'command -v tmux && command -v mosh-server && command -v fastfetch && command -v distrobox && command -v gh'
chk "claudebox manifest baked"           test -f /usr/share/strix/claudebox/distrobox.ini
chk "core linger enabled"                test -e /var/lib/systemd/linger/core
chk "tmux attach drop-in present"        test -f /etc/profile.d/zz-tmux-attach.sh
chk "fastfetch drop-in present (A1)"     test -f /etc/profile.d/zz-fastfetch.sh

echo "── R11/R13: updates + daemons ──"
chk "bootc tracks ghcr ref"              sh -c 'bootc status 2>/dev/null | grep -q "ghcr.io/oso-gato/strix-ms-s1-bootc"'
chk "bootc auto-update timer active"     systemctl is-active --quiet bootc-fetch-apply-updates.timer
chk "keys-sync timer active"             systemctl is-active --quiet strix-keys-sync.timer
chk "pmcd active"                        systemctl is-active --quiet pmcd.service
chk "pmlogger active"                    systemctl is-active --quiet pmlogger.service
chk "pmproxy active"                     systemctl is-active --quiet pmproxy.service
chk "tailscaled enabled"                 systemctl is-enabled --quiet tailscaled.service
chk "hostname strix"                     sh -c '[ "$(cat /etc/hostname)" = strix ]'
chk "ip forwarding sysctls live"         sh -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] && [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = 1 ]'

echo "── expected-in-VM divergences (hardware absent; live-host checklist) ──"
# strix-postinstall-verify SHOULD fail in a VM — at the bond0 assertion, with
# every earlier (non-hardware) assertion having passed. Wait for it to reach a
# terminal state first (it has a long After= chain; judging it mid-activation
# was a harness bug).
for _ in $(seq 1 30); do
  st=$(systemctl show -p ActiveState --value strix-postinstall-verify.service 2>/dev/null)
  [ "$st" = activating ] || [ "$st" = inactive ] || break
  sleep 4
done
if systemctl is-failed --quiet strix-postinstall-verify.service; then
  if journalctl -t strix-verify -b --no-pager 2>/dev/null | grep -q 'bond0 missing'; then
    ok "verify unit failed exactly at the bond0 hardware assertion (expected in VM)"
  else
    bad "verify unit failed BEFORE bond0 — non-hardware failure: $(journalctl -t strix-verify -b --no-pager | tail -3)"
  fi
else
  bad "verify unit not in failed state (ActiveState=$(systemctl show -p ActiveState --value strix-postinstall-verify.service)); recent strix-verify: $(journalctl -t strix-verify -b --no-pager | tail -2)"
fi
systemctl is-active --quiet smartd.service \
  && ok "smartd active (QEMU NVMe exposes SMART)" \
  || ok "smartd not active in VM (no SMART-capable device — live-host item, not a defect here)"

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "── diagnostics for the failing units (auto-dumped on any FAIL) ──"
  for u in pmcd pmlogger pmproxy strix-postinstall-verify smartd; do
    echo "### $u.service"
    systemctl --no-pager --full status "$u.service" 2>&1 | head -12 || true
    journalctl -u "$u.service" -b --no-pager 2>/dev/null | tail -8 || true
  done
  echo "### /etc/hostname = [$(cat /etc/hostname 2>/dev/null)]  hostnamectl=[$(hostnamectl --static 2>/dev/null)]"
  echo "### ls -la /var/log/pcp"; ls -la /var/log/pcp 2>&1 | head
  echo "ASSERT-IN-VM: $FAILS FAILURE(S)"
  exit 1
fi
echo "ASSERT-IN-VM: all assertions passed"
