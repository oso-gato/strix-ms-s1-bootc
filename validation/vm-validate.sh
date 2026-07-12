#!/bin/bash
# vm-validate.sh — BUILD-SPEC §6 as executable truth: install and boot the
# strix ISOs in KVM VMs and assert the result against REQUIREMENTS.md.
# Run by .github/workflows/validate.yml on a /dev/kvm-enabled runner (also
# runs on any Linux box with qemu-system-x86_64 + rootful podman).
#
# WHAT IS VALIDATED AS-SHIPPED: everything except four hardware constants.
# The kickstart template is rendered with the QEMU disk identity substituted
# for the WD_BLACK identity (by-id names + model strings; SIZES ARE KEPT —
# 2 TB / 4 TB sparse qcow2s satisfy the real guard windows), and the SSH
# trust root is an ephemeral validation keypair via KEYS_URL=file://. Every
# line of partitioning math, %pre/%post logic, systemd graph, seed/restore
# machinery, and package payload is the shipped artifact.
#
# Phases (each logs PASS/FAIL; the script fails on first FAIL):
#   1  wipe install    : unattended install completes (qemu -no-reboot exits)
#   2  first boot      : SSH by key; in-VM assertion battery (assert-in-vm.sh);
#                        write persistence marker; poweroff
#   3  preserve cycle  : preserve ISO reinstalls over the same disks (match-or-
#                        halt PASSES), boots, marker SURVIVED
#   4  preserve guard  : preserve ISO + BLANK data disk → %pre must HALT
#                        (no install completion; data disk stays untouched)
#   5  wipe guard      : wipe ISO + WRONG-SIZE data disk → %pre must HALT
#                        (both disks stay untouched)
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$HERE/output/validate}"
mkdir -p "$WORK"
cd "$WORK"

SYS_SERIAL=VALSYS01
DATA_SERIAL=VALDATA01
QEMU_MODEL="QEMU NVMe Ctrl"                      # QEMU's fixed NVMe model string
SYS_BYID="nvme-QEMU_NVMe_Ctrl_${SYS_SERIAL}"
DATA_BYID="nvme-QEMU_NVMe_Ctrl_${DATA_SERIAL}"
SSH_PORT=2222
# Resolve OVMF firmware without `ls` (a partial-match `ls` exits 2, which
# pipefail+set-e would turn into a silent early death). CODE + its matching
# VARS template, newest layout first.
OVMF_CODE=""; OVMF_VARS_TPL=""
for pair in \
  "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
  "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
  "/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd"; do
  c="${pair%%:*}"; v="${pair##*:}"
  if [ -e "$c" ] && [ -e "$v" ]; then OVMF_CODE="$c"; OVMF_VARS_TPL="$v"; break; fi
done
[ -n "$OVMF_CODE" ] || { echo "vm-validate: FAIL — no OVMF firmware found (install the 'ovmf' package)" >&2; exit 1; }
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-1800}"       # 30 min per install
HALT_WINDOW="${HALT_WINDOW:-480}"                # 8 min = "guard held" window

say()  { printf '\n═══ %s ═══\n' "$*"; }
pass() { printf 'VALIDATE PASS: %s\n' "$*"; }
fail() { printf 'VALIDATE FAIL: %s\n' "$*" >&2; exit 1; }

# ─── 0. Test-variant ISOs ────────────────────────────────────────────────────
say "phase 0: build test-variant ISOs (QEMU disk identity + ephemeral key)"
if [ ! -f "$WORK/strix-wipe.iso" ] || [ "${REBUILD:-1}" = 1 ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'strix-validation-ephemeral' -f "$WORK/valkey" <<<y >/dev/null 2>&1 || true
  cp "$HERE/installer/kickstart.ks.tpl" "$WORK/kickstart.ks.tpl.orig"
  sed -i \
    -e "s|nvme-WD_BLACK_SN850X_2000GB_25281F806642|$SYS_BYID|g" \
    -e "s|nvme-WD_BLACK_SN850X_4000GB_25278B803296|$DATA_BYID|g" \
    -e "s|SN850X 2000GB|$QEMU_MODEL|g" \
    -e "s|SN850X 4000GB|$QEMU_MODEL|g" \
    "$HERE/installer/kickstart.ks.tpl"
  echo "validate: kickstart hardware-constant delta (THE ONLY DELTA):"
  diff -u "$WORK/kickstart.ks.tpl.orig" "$HERE/installer/kickstart.ks.tpl" || true
  ( cd "$HERE" && KEYS_URL="file://$WORK/valkey.pub" ./build-iso.sh --local )
  mv "$HERE/strix-wipe.iso" "$HERE/strix-preserve.iso" "$WORK/"
  cp "$WORK/kickstart.ks.tpl.orig" "$HERE/installer/kickstart.ks.tpl"   # restore tree
fi
[ -f "$WORK/strix-wipe.iso" ] && [ -f "$WORK/strix-preserve.iso" ] || fail "test ISOs missing"
pass "phase 0: test-variant ISOs built"

# ─── VM plumbing ─────────────────────────────────────────────────────────────
new_disk() { qemu-img create -q -f qcow2 "$1" "$2"; }   # sparse

VM_SEQ=0
vm() {
  # vm <mode:install|run|halt> <sysdisk> <datadisk> [iso]
  local mode="$1" sys="$2" data="$3" iso="${4:-}"
  VM_SEQ=$((VM_SEQ + 1))   # per-invocation serial log (no $$ collisions across phases)
  local args=(
    -machine q35,accel=kvm -cpu host -smp 2 -m 4096
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$WORK/ovmf_vars.fd"
    -drive "file=$sys,if=none,id=d0,format=qcow2,discard=unmap"
    -device "nvme,drive=d0,serial=$SYS_SERIAL,bootindex=2"
    -drive "file=$data,if=none,id=d1,format=qcow2,discard=unmap"
    -device "nvme,drive=d1,serial=$DATA_SERIAL,bootindex=3"
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=n0"
    -display none -serial "file:$WORK/serial-${VM_SEQ}-$mode.log"
  )
  if [ -n "$iso" ]; then
    args+=( -drive "file=$iso,if=none,id=cd0,format=raw,media=cdrom,readonly=on"
            -device "ide-cd,drive=cd0,bootindex=1" -no-reboot )
  fi
  sudo qemu-system-x86_64 "${args[@]}" &
  QEMU_PID=$!
}

fresh_vars() { rm -f "$WORK/ovmf_vars.fd"; cp "$OVMF_VARS_TPL" "$WORK/ovmf_vars.fd"; chmod 666 "$WORK/ovmf_vars.fd"; }

wait_install_exit() {  # PASS = qemu exits (kickstart 'reboot' + -no-reboot) within timeout
  local t=0
  while kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 10; t=$((t + 10))
    [ "$t" -ge "$INSTALL_TIMEOUT" ] && { sudo kill -9 "$QEMU_PID" 2>/dev/null || true; return 1; }
  done
  wait "$QEMU_PID" 2>/dev/null || true
  return 0
}

settle_vm() {  # wait up to the window for the VM to exit on its own, else kill it.
  # NO pass/fail judgment here — Anaconda's post-%pre-error behavior (sit at a
  # prompt vs reboot) is version-dependent and an unreliable signal. The real
  # halt assertion is "were the disks written?" (disk_blank), checked by the
  # caller AFTER this returns. (Run-4 phase-5 taught this: qemu exited on a
  # correct halt, and the old qemu-liveness heuristic misread it as a proceed.)
  local t=0
  while [ "$t" -lt "$HALT_WINDOW" ]; do
    kill -0 "$QEMU_PID" 2>/dev/null || return 0
    sleep 10; t=$((t + 10))
  done
  sudo kill -9 "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
}

vssh() {
  ssh -p "$SSH_PORT" -i "$WORK/valkey" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
      core@127.0.0.1 "$@"
}

wait_ssh() {
  local t=0
  while [ "$t" -lt 600 ]; do
    if vssh true 2>/dev/null; then
      # The ephemeral validation key is NOT on github.com/oso-gato.keys, so
      # strix-keys-sync (OnBootSec=2min, working as designed) would replace
      # authorized_keys and evict our key mid-run. Stop it the instant SSH is
      # up — well inside the 2-min window — so validation stays deterministic
      # WITHOUT altering the shipped image.
      vssh 'sudo systemctl stop strix-keys-sync.timer strix-keys-sync.service' 2>/dev/null || true
      return 0
    fi
    sleep 10; t=$((t + 10))
  done
  return 1
}

disk_blank() {  # assert a qcow2 has NO partition table (guard aborted pre-storage)
  local img="$1"
  sudo modprobe nbd max_part=8
  sudo qemu-nbd -c /dev/nbd0 "$img"
  local out rc=0
  out=$(sudo sfdisk -l /dev/nbd0 2>&1) || true
  echo "$out" | grep -qiE 'type: (gpt|dos)' && rc=1
  sudo qemu-nbd -d /dev/nbd0 >/dev/null
  return $rc
}

# ─── 1. Wipe install ─────────────────────────────────────────────────────────
say "phase 1: wipe install onto blank 2TB+4TB"
new_disk sys.qcow2 2000000000000
new_disk data.qcow2 4000000000000
fresh_vars
vm install sys.qcow2 data.qcow2 "$WORK/strix-wipe.iso"
wait_install_exit || fail "phase 1: wipe install did not complete within $((INSTALL_TIMEOUT/60)) min"
pass "phase 1: unattended wipe install completed"

# ─── 2. First boot + assertion battery ───────────────────────────────────────
say "phase 2: first boot, SSH by ephemeral key, in-VM assertions"
vm run sys.qcow2 data.qcow2
wait_ssh || fail "phase 2: SSH by key never came up (home seed / sshd / keys broken)"
pass "phase 2: SSH by injected key works (home-seed + key path proven)"
scp -P "$SSH_PORT" -i "$WORK/valkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$HERE/validation/assert-in-vm.sh" core@127.0.0.1:/tmp/assert-in-vm.sh
KEYBODY=$(awk '{print $2}' "$WORK/valkey.pub")
vssh "sudo bash /tmp/assert-in-vm.sh '$KEYBODY'" || fail "phase 2: in-VM assertion battery failed (see output above)"
vssh 'touch ~/VALIDATION-MARKER && sync'

# ─── 2b. claudebox integration — the "container half" (R8), never run before ──
say "phase 2b: build + run the claudebox (Claude Code workbench), assert host immutability"
scp -P "$SSH_PORT" -i "$WORK/valkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$HERE/validation/assert-claudebox.sh" core@127.0.0.1:/tmp/assert-claudebox.sh
# Runs as core (rootless), NOT sudo. Network-dependent (pulls toolbox + claude-code).
vssh 'bash /tmp/assert-claudebox.sh' || fail "phase 2b: claudebox integration failed (see output above)"
pass "phase 2b: claudebox builds, Claude Code runs in it, host stayed immutable"

vssh 'sudo poweroff' 2>/dev/null || true
while kill -0 "$QEMU_PID" 2>/dev/null; do sleep 5; done
pass "phase 2: assertion battery green; persistence marker written"

# ─── 3. Preserve reinstall over the same disks ───────────────────────────────
say "phase 3: preserve reinstall (match-or-halt must PASS), data survives"
fresh_vars
vm install sys.qcow2 data.qcow2 "$WORK/strix-preserve.iso"
wait_install_exit || fail "phase 3: preserve install did not complete (match-or-halt wrongly halted?)"
vm run sys.qcow2 data.qcow2
wait_ssh || fail "phase 3: SSH down after preserve reinstall"
vssh 'test -f ~/VALIDATION-MARKER' || fail "phase 3: marker lost — preserve did not preserve"
vssh 'findmnt -no UUID /var/home | grep -q e3b1c7a5' || fail "phase 3: /var/home not on strix-home after preserve"
vssh 'sudo poweroff' 2>/dev/null || true
while kill -0 "$QEMU_PID" 2>/dev/null; do sleep 5; done
pass "phase 3: preserve reinstall kept the data drive (marker survived)"

# ─── 4. Preserve guard: blank data drive must HALT ───────────────────────────
say "phase 4: preserve ISO vs BLANK data drive → %pre must halt"
new_disk data-blank.qcow2 4000000000000
fresh_vars
vm halt sys.qcow2 data-blank.qcow2 "$WORK/strix-preserve.iso"
settle_vm
# Ground truth: a halted %pre never reaches storage, so the data disk has no
# partition table. (The system disk here already carries the phase-1 install,
# so only the data disk is a meaningful check.)
disk_blank data-blank.qcow2 || fail "phase 4: blank data drive was WRITTEN — preserve match-or-halt did not halt"
pass "phase 4: preserve halted on unknown layout; data drive untouched"

# ─── 5. Wipe guard: wrong-size data drive must HALT ──────────────────────────
say "phase 5: wipe ISO vs WRONG-SIZE (1TB) data drive → %pre must halt"
new_disk sys-fresh.qcow2 2000000000000
new_disk data-small.qcow2 1000000000000
fresh_vars
vm halt sys-fresh.qcow2 data-small.qcow2 "$WORK/strix-wipe.iso"
settle_vm
# Ground truth: neither disk is touched when the identity guard halts pre-storage.
disk_blank data-small.qcow2 || fail "phase 5: wrong-size data drive was WRITTEN — identity guard did not halt"
disk_blank sys-fresh.qcow2   || fail "phase 5: system drive was WRITTEN despite the guard halt"
pass "phase 5: guard held on wrong-size drive; neither disk written"

say "ALL PHASES PASSED — build validated against BUILD-SPEC §6 / REQUIREMENTS"
