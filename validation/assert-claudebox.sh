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

echo "── rootless-podman preflight (classify flake vs defect up front) ──"
podman info >/tmp/cb-podman.log 2>&1 \
  && ok "rootless podman works for core" \
  || { bad "rootless podman broken for core"; tail -15 /tmp/cb-podman.log; }

echo "── build the claudebox DIRECTLY (distrobox assemble; capture real output) ──"
# Direct assemble (not the detached user service) so the actual error is
# visible — the user-service path's journal was unreadable over SSH.
bc_rc=0
distrobox assemble create --file /usr/share/strix/claudebox/distrobox.ini >/tmp/cb-build.log 2>&1 || bc_rc=$?
if [ "$bc_rc" -eq 0 ]; then
  ok "distrobox assemble created the box"
  ic_rc=0
  /usr/share/strix/claudebox/claudebox-init.sh >/tmp/cb-init.log 2>&1 || ic_rc=$?
  [ "$ic_rc" -eq 0 ] && ok "claudebox-init applied bridges + settings" \
    || { bad "claudebox-init FAILED (rc=$ic_rc)"; echo "--- claudebox-init output ---"; tail -20 /tmp/cb-init.log; }
else
  bad "distrobox assemble FAILED (rc=$bc_rc) — real error below"
  echo "--- last 35 lines of assemble output ---"; tail -35 /tmp/cb-build.log
fi

echo "── in-box: Claude Code actually present + launchable ──"
chk "claudebox container exists"         podman container exists claudebox
chk "claude-code rpm installed in box"   distrobox enter claudebox -- rpm -q claude-code
chk "claude on PATH in box"              distrobox enter claudebox -- sh -lc 'command -v claude'
chk "claude --version runs in box"       sh -c 'timeout 40 distrobox enter claudebox -- sh -lc "claude --version"'
chk "CONTAINER_HOST bridge wired"        sh -c 'distrobox enter claudebox -- sh -lc "echo \$CONTAINER_HOST" | grep -q "podman/podman.sock"'
echo "── startup settings IN THE BUILT BOX: recommended model + ultracode + auto mode ──"
chk "managed-settings.json present in box"  distrobox enter claudebox -- test -f /etc/claude-code/managed-settings.json
chk "in-box managed: defaultMode=auto"      sh -c 'distrobox enter claudebox -- cat /etc/claude-code/managed-settings.json | grep -qE "\"defaultMode\":[[:space:]]*\"auto\""'
chk "in-box managed: effortLevel=xhigh"     sh -c 'distrobox enter claudebox -- cat /etc/claude-code/managed-settings.json | grep -qE "\"effortLevel\":[[:space:]]*\"xhigh\""'
chk "in-box managed: NO model override"     sh -c '! distrobox enter claudebox -- grep -qE "\"model\"[[:space:]]*:" /etc/claude-code/managed-settings.json'
chk "host wrapper passes --model default"   grep -q -- '--model default' /usr/bin/claude
chk "host wrapper injects ultracode"        grep -q 'ultracode' /usr/bin/claude

echo "── R8/A19: GitHub-App token bridge reaches INTO the box (empirical) ──"
# Prove the host-minted token file is readable in-box as GH_TOKEN via the
# distrobox host mount — put a sentinel on the host tmpfs, read it in-box.
chk "gh-token profile.d present in box"     distrobox enter claudebox -- test -f /etc/profile.d/strix-gh-token.sh
sudo install -d -m 0755 /run/strix
printf 'SENTINEL_TOKEN_%s\n' "$$" | sudo tee /run/strix/gh-token >/dev/null
sudo chown root:core /run/strix/gh-token 2>/dev/null || sudo chgrp core /run/strix/gh-token
sudo chmod 0640 /run/strix/gh-token
chk "in-box GH_TOKEN bridges from host tmpfs" \
  sh -c 'distrobox enter claudebox -- sh -lc "echo \$GH_TOKEN" | grep -q "SENTINEL_TOKEN_"'
sudo rm -f /run/strix/gh-token

echo
if [ "$FAILS" -gt 0 ]; then
  echo "ASSERT-CLAUDEBOX: $FAILS FAILURE(S)"
  exit 1
fi
echo "ASSERT-CLAUDEBOX: all passed — the container half builds and runs Claude Code; host untouched"
