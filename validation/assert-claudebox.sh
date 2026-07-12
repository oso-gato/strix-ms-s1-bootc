#!/bin/bash
# assert-claudebox.sh — integration test for the "container half" (R8/D11/A3):
# actually BUILD the claudebox and prove Claude Code runs inside it while the
# host stays immutable. Runs as `core` (rootless) over SSH — NOT root. This
# surface was never exercised before (the battery only checked the manifest
# file existed). Distinguishes a real claudebox defect from a network flake by
# dumping the rebuild journal on failure.
set -uo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

FAILS=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "── prerequisites for rootless podman as core ──"
chk "user D-Bus / manager up (linger)"   test -S "/run/user/$(id -u)/bus"
chk "subuid range for core"              grep -q '^core:' /etc/subuid
chk "subgid range for core"              grep -q '^core:' /etc/subgid
chk "user podman.socket enabled"         systemctl --user is-enabled podman.socket
chk "claude wrapper present on host"     test -x /usr/bin/claude
# R8 host-immutability: the claude-code CLI must live ONLY in the box.
chk "host immutability: claude-code NOT rpm-installed on host"  sh -c '! rpm -q claude-code'

echo "── build the claudebox (pull toolbox:44 + dnf claude-code; minutes) ──"
if /usr/bin/claudebox-rebuild; then
  ok "claudebox-rebuild completed"
else
  bad "claudebox-rebuild FAILED — journal below (network flake vs real defect)"
  journalctl --user -u claudebox-rebuild-run.service --no-pager 2>/dev/null | tail -50
fi

echo "── in-box: Claude Code actually present + launchable ──"
chk "claudebox container exists"         podman container exists claudebox
chk "claude-code rpm installed in box"   distrobox enter claudebox -- rpm -q claude-code
chk "claude on PATH in box"              distrobox enter claudebox -- sh -lc 'command -v claude'
chk "claude --version runs in box"       sh -c 'timeout 40 distrobox enter claudebox -- sh -lc "claude --version"'
chk "CONTAINER_HOST bridge wired"        sh -c 'distrobox enter claudebox -- sh -lc "echo \$CONTAINER_HOST" | grep -q "podman/podman.sock"'
chk "managed-settings.json in box"       distrobox enter claudebox -- test -f /etc/claude-code/managed-settings.json
chk "managed-settings: auto mode"        sh -c 'distrobox enter claudebox -- cat /etc/claude-code/managed-settings.json | grep -q "\"defaultMode\": \"auto\""'

echo
if [ "$FAILS" -gt 0 ]; then
  echo "ASSERT-CLAUDEBOX: $FAILS FAILURE(S)"
  exit 1
fi
echo "ASSERT-CLAUDEBOX: all passed — the container half builds and runs Claude Code; host untouched"
