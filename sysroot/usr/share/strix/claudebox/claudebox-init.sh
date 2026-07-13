#!/bin/bash
# claudebox-init — post-assemble bridge + policy application (R8). Runs on the
# HOST after `distrobox assemble`; applies everything that can't live in
# distrobox.ini hooks (assemble's double-eval detonates on quotes/redirects).
#   1. Host podman bridge: in-box podman talks to the HOST's rootless podman
#      socket via CONTAINER_HOST (the box's own /run/user/<uid> is the host's,
#      bind-mounted by distrobox with init=0).
#   2. Claude Code managed settings: auto mode + xhigh effort + autoupdater
#      off + the house package-discipline deny list (host immutability).
set -euo pipefail

BOX=claudebox
SRC=/usr/share/strix/claudebox

enter() { distrobox enter "$BOX" -- sudo "$@"; }

# (1) CONTAINER_HOST bridge for every in-box shell.
distrobox enter "$BOX" -- sudo sh -c \
  'printf "export CONTAINER_HOST=unix:///run/user/%s/podman/podman.sock\n" "$(id -u '"$USER"')" > /etc/profile.d/strix-container-host.sh' \
  || distrobox enter "$BOX" -- sudo sh -c \
  "printf 'export CONTAINER_HOST=unix:///run/user/\$(id -u)/podman/podman.sock\n' > /etc/profile.d/strix-container-host.sh"

# (2) Managed settings (read-only to the in-box user). $SRC is a HOST path;
# inside the box /usr is the toolbox's OWN filesystem, so a `cp $SRC/...`
# run in-box can't see it (VM integration test caught this). PIPE the host
# file into the box via stdin — the redirection is evaluated host-side where
# $SRC is valid, and cat writes it in-box.
distrobox enter "$BOX" -- sudo mkdir -p /etc/claude-code
distrobox enter "$BOX" -- sudo sh -c 'cat > /etc/claude-code/managed-settings.json' < "$SRC/managed-settings.json"
distrobox enter "$BOX" -- sudo chmod 0644 /etc/claude-code/managed-settings.json

# (3) GitHub App token bridge (R8/A19): export GH_TOKEN in every in-box shell
# from the host-minted, core-readable token file, so in-box gh/git operate as
# the box's per-box App identity. The host file (/run/strix/gh-token, tmpfs) is
# reachable in-box via distrobox's host mount (/run/host); re-read each shell so
# the ~hourly refresh is picked up live. No-ops (unset GH_TOKEN) when the App
# isn't configured. Redirection is host-side (matches the managed-settings pipe).
distrobox enter "$BOX" -- sudo sh -c 'cat > /etc/profile.d/strix-gh-token.sh' <<'EOF'
# strix: bridge the host-minted GitHub App token as GH_TOKEN (R8/A19)
for _t in /run/host/run/strix/gh-token /run/strix/gh-token; do
  if [ -r "$_t" ]; then
    GH_TOKEN="$(cat "$_t" 2>/dev/null)" && export GH_TOKEN GITHUB_TOKEN="$GH_TOKEN"
    break
  fi
done
unset _t
EOF
distrobox enter "$BOX" -- sudo chmod 0644 /etc/profile.d/strix-gh-token.sh

echo "claudebox-init: bridges + managed settings + GitHub App token applied."
