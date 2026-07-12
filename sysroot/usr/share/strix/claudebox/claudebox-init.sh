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

echo "claudebox-init: bridges + managed settings applied."
