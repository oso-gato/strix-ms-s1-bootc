#!/bin/bash
# build-iso.sh — build the strix install ISO(s) via bootc-image-builder (R10).
#
#   ./build-iso.sh                 → strix-preserve.iso AND strix-wipe.iso
#   ./build-iso.sh --preserve      → preserve only
#   ./build-iso.sh --wipe          → wipe only
#   ./build-iso.sh --local [...]   → podman-build the image from ./Containerfile
#                                    first (tagged as IMAGE_REF) instead of
#                                    pulling IMAGE_REF from the registry
#
# IMAGE_REF (env-overridable) is the canonical registry reference. It matters
# twice: BIB embeds the image in the ISO (offline install), and BIB's injected
# `%post bootc switch --transport registry <ref>` makes the installed system
# TRACK this exact ref for `bootc upgrade` — so it must be the canonical
# ghcr.io tag even for --local builds (build-tag locally AS that ref).
#
# SSH keys (R4d/R10): fetched at BUILD time from github.com/oso-gato.keys and
# rendered into kickstart `sshkey` lines, each tagged by a short SHA256
# fingerprint prefix. HARD-FAILS on zero keys — a keyless ISO is a brick
# (passwordless core + key-only SSH).
#
# Requirements: rootful podman (Linux: sudo; macOS: `podman machine set
# --rootful` once). BIB runs --privileged with the host container storage
# mounted (upstream-documented invocation).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

IMAGE_REF="${IMAGE_REF:-ghcr.io/oso-gato/strix-ms-s1-bootc:stable}"
# BIB pinned by digest (R1 posture; :latest is mutable and `anaconda-iso` is
# flagged legacy upstream — see BUILD-SPEC watch-items for the bootc-installer
# migration). Digest = :latest as of 2026-07-11; bump deliberately.
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b}"
KEYS_URL="https://github.com/oso-gato.keys"
KEYS_OWNER="oso-gato"
# SHA256 fingerprint-prefix → friendly tag (hashes only, never key material).
KEY_TAGS_JSON='{"lzwcN0O7rzVy":"oSo","ozn1vY4/uPFX":"Alchemist","Kc4nBP37wttj":"Fatima"}'

# ─── Flags ───────────────────────────────────────────────────────────────────
BUILD_PRESERVE=1; BUILD_WIPE=1; LOCAL_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --wipe)     BUILD_PRESERVE=0; BUILD_WIPE=1 ;;
    --preserve) BUILD_PRESERVE=1; BUILD_WIPE=0 ;;
    --local)    LOCAL_BUILD=1 ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "build-iso: unknown flag '$arg' (see --help)" >&2; exit 1 ;;
  esac
done
VARIANTS=()
[ "$BUILD_PRESERVE" = 1 ] && VARIANTS+=(preserve)
[ "$BUILD_WIPE" = 1 ] && VARIANTS+=(wipe)
echo "build-iso: will build → ${VARIANTS[*]}  (image: $IMAGE_REF)"

# ─── Rootful podman front-end ────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
  echo "build-iso: podman not on PATH." >&2; exit 1
fi
if [ "$(uname)" = "Darwin" ]; then
  PODMAN=(podman)   # macOS: the machine itself must be rootful
  if ! podman machine inspect 2>/dev/null | grep -q '"Rootful": true'; then
    echo "build-iso: FAIL — podman machine is not rootful (bootc-image-builder needs it)." >&2
    echo "  fix: podman machine stop && podman machine set --rootful && podman machine start" >&2
    exit 1
  fi
else
  PODMAN=(sudo podman)
fi

# ─── SSH keys: fetch, validate, render kickstart sshkey lines ────────────────
echo "build-iso: fetching SSH public keys from $KEYS_URL"
KEYS_RAW="$(mktemp)"; SSHKEY_LINES="$(mktemp)"
trap 'rm -f "$KEYS_RAW" "$SSHKEY_LINES"' EXIT
curl -fsSL --retry 3 "$KEYS_URL" -o "$KEYS_RAW" || {
  echo "build-iso: FAIL — could not fetch $KEYS_URL" >&2; exit 1; }

KEY_TAGS_JSON="$KEY_TAGS_JSON" KEYS_OWNER="$KEYS_OWNER" \
python3 - "$KEYS_RAW" > "$SSHKEY_LINES" <<'PY'
import base64, hashlib, json, os, re, sys

tag_map = json.loads(os.environ["KEY_TAGS_JSON"])
owner = os.environ["KEYS_OWNER"]
# @-suffixed sk- forms are the REAL FIDO algorithm names (the predecessor's
# regex silently dropped hardware-backed keys — inherited bug, fixed here).
pat = re.compile(r'^(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*')

def tag_for(body):
    fp = base64.b64encode(hashlib.sha256(base64.b64decode(body)).digest()).decode().rstrip("=")
    for prefix, name in tag_map.items():
        if fp.startswith(prefix):
            return name
    return owner + "@github"

n = 0
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln or not pat.match(ln):
        continue
    algo, body = ln.split()[:2]
    print(f'sshkey --username=core "{algo} {body} {tag_for(body)}"')
    n += 1
if n < 1:
    sys.exit("ZERO_KEYS")
print(f"build-iso: rendered {n} sshkey line(s)", file=sys.stderr)
PY
KEY_COUNT="$(grep -c '^sshkey ' "$SSHKEY_LINES" || echo 0)"
if [ "${KEY_COUNT:-0}" -lt 1 ]; then
  echo "build-iso: FAIL — fetched 0 valid SSH keys. core is passwordless and SSH" >&2
  echo "  is key-only; a keyless ISO is a brick. Refusing to build." >&2
  exit 1
fi
echo "build-iso: [OK] $KEY_COUNT SSH key(s) from $KEYS_OWNER"

# ─── Image: pull the canonical ref, or build locally AS that ref ─────────────
if [ "$LOCAL_BUILD" = 1 ]; then
  echo "build-iso: building $IMAGE_REF from ./Containerfile (local)"
  "${PODMAN[@]}" build -t "$IMAGE_REF" "$HERE"
else
  echo "build-iso: pulling $IMAGE_REF"
  "${PODMAN[@]}" pull "$IMAGE_REF"
fi

# ─── Render kickstart + config.toml, then BIB, per variant ───────────────────
mkdir -p "$HERE/output"
for VARIANT in "${VARIANTS[@]}"; do
  echo ""
  echo "==================================================================="
  echo "  Building strix-${VARIANT}.iso"
  echo "==================================================================="
  WIPE=0; [ "$VARIANT" = "wipe" ] && WIPE=1

  KS="$HERE/output/kickstart-${VARIANT}.ks"
  CFG="$HERE/output/config-${VARIANT}.toml"
  WIPE="$WIPE" KSTPL="$HERE/installer/kickstart.ks.tpl" SSHKEY_LINES="$SSHKEY_LINES" \
    python3 - "$KS" "$CFG" <<'PY'
import os, sys

ks_path, cfg_path = sys.argv[1], sys.argv[2]
tpl = open(os.environ["KSTPL"]).read()
keys = open(os.environ["SSHKEY_LINES"]).read().strip()
ks = tpl.replace("@WIPE@", os.environ["WIPE"]).replace("@SSHKEYS@", keys)
open(ks_path, "w").write(ks)

# TOML literal multi-line string: no escape processing, so the kickstart body
# passes through verbatim — guarded against the one impossible substring.
assert "'''" not in ks, "kickstart must not contain triple single-quotes"
with open(cfg_path, "w") as f:
    f.write("[customizations.installer.kickstart]\ncontents = '''\n")
    f.write(ks)
    f.write("\n'''\n")
print(f"rendered {ks_path} + {cfg_path}", file=sys.stderr)
PY

  OUT="$HERE/output/$VARIANT"
  mkdir -p "$OUT"
  "${PODMAN[@]}" run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "$CFG":/config.toml:ro \
    -v "$OUT":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$BIB_IMAGE" \
    --type anaconda-iso \
    --rootfs xfs \
    --config /config.toml \
    --chown "$(id -u):$(id -g)" \
    "$IMAGE_REF"
  # --rootfs xfs: fedora-bootc images declare no default root fs type (CI run
  # 2: "no default root filesystem type specified in container"); matches the
  # kickstart's `part / --fstype=xfs`.
  # --chown: BIB runs as root; without it the ISO lands root-owned and the
  # un-sudo'd mv below fails with EACCES after the whole build.

  mv "$OUT/bootiso/install.iso" "$HERE/strix-${VARIANT}.iso"
  echo "build-iso: [OK] strix-${VARIANT}.iso"
done

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==================================================================="
echo "  DONE"
echo "==================================================================="
for VARIANT in "${VARIANTS[@]}"; do
  printf "  %-22s  %s\n" "strix-${VARIANT}.iso" "$HERE/strix-${VARIANT}.iso"
done
echo ""
[ "$BUILD_WIPE" = 1 ] && {
  echo "[WARN]  strix-wipe.iso RECREATES the 4 TB data drive (the one-time"
  echo "        migration path from the noir/FCOS layout). Label the USB loudly."; }
[ "$BUILD_PRESERVE" = 1 ] && {
  echo "[OK]    strix-preserve.iso keeps the data drive (match-or-halt)."; }
echo ""
echo "Flash:  sudo dd if=<ISO> of=/dev/rdiskN bs=4m status=progress conv=sync"
echo "First boot: ssh core@strix && sudo strix-setup"
