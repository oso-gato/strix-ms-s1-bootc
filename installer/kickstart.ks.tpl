# ─────────────────────────────────────────────────────────────────────────────
# strix kickstart TEMPLATE (R10) — rendered by build-iso.sh into the two
# variants (@WIPE@ → 0 = preserve, 1 = wipe) with @SSHKEYS@ replaced by the
# build-time-fetched sshkey lines (anti-brick: build fails on zero keys).
#
# bootc-image-builder supplies ONLY the ostreecontainer payload line (embedded
# OCI image — fully offline install) and a %post `bootc switch --transport
# registry <ref>` so the installed system tracks ghcr.io. EVERYTHING else is
# this file's responsibility (verified against BIB docs/source 2026-07-11).
#
# Two drives, two fates (R9/R10):
#   SYSTEM 2 TB (serial 25281F806642): always wiped + reinstalled. Anaconda
#     only ever sees this drive (ignoredisk --only-use).
#   DATA 4 TB (serial 25278B803296): invisible to Anaconda. %pre either
#     verifies its strix layout (preserve: match-or-halt) or recreates it
#     (wipe). Runtime mount units in the image adopt it by UUID.
# ─────────────────────────────────────────────────────────────────────────────
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# R5/D3: root locked (no password ever); core UID 1000, wheel (sudo) +
# libvirt (virsh/cockpit-machines system connection). Password field locked
# until strix-setup sets it — SSH is key-only regardless (sshd_config.d).
rootpw --lock
user --name=core --uid=1000 --gid=1000 --groups=wheel,libvirt --shell=/bin/bash --lock
@SSHKEYS@

# Anaconda may only touch the system drive; %pre re-verifies identity first.
ignoredisk --only-use=/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25281F806642
zerombr
clearpart --all --initlabel --drives=/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25281F806642
reqpart --add-boot
part / --fstype=xfs --grow --ondisk=/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25281F806642

reboot

# ─── %pre: identity guard + data-drive handling ──────────────────────────────
# --erroronfail is LOAD-BEARING: a plain %pre that fails is silently ignored
# and the install proceeds (pykickstart default errorOnFail=False).
%pre --erroronfail --interpreter=/bin/bash
set -eu
export LC_ALL=C

WIPE=@WIPE@

TARGET="/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25281F806642"
TARGET_EXPECTED_SIZE_GB=1862
TARGET_EXPECTED_MODEL="SN850X 2000GB"
DATA="/dev/disk/by-id/nvme-WD_BLACK_SN850X_4000GB_25278B803296"
DATA_EXPECTED_SIZE_GB=3725
DATA_EXPECTED_MODEL="SN850X 4000GB"
SIZE_TOLERANCE_GB=50

# strix data layout (R9/D7): sizes in MiB; log takes the remainder.
UUID_HOME="e3b1c7a5-2f4d-4b8e-9c6a-1d5f7e9b3a21"
UUID_CTR="f4c2d8b6-3a5e-4c9f-8d7b-2e6a8f0c4b32"
UUID_VM="a5d3e9c7-4b6f-4d0a-9e8c-3f7b9a1d5c43"
UUID_LOG="b6e4f0d8-5c7a-4e1b-8f9d-4a8c0b2e6d54"
MIB_HOME=2048000     # 2000 GiB
MIB_CTR=768000       # 750 GiB
MIB_VM=768000        # 750 GiB

fail() {
    echo "STRIX GUARD: FAIL — $*" >&2
    echo "STRIX GUARD: available NVMe by-id symlinks:" >&2
    ls -la /dev/disk/by-id/ 2>/dev/null | grep nvme >&2 || true
    exit 1
}

check_drive() {
    # Args: SYMLINK EXPECTED_SIZE_GB EXPECTED_MODEL_SUBSTR LABEL
    local symlink="$1" exp_gb="$2" exp_model="$3" label="$4"
    [ -e "$symlink" ] || fail "$label symlink $symlink does not resolve."
    local real base size_bytes size_gb lo hi model_path model
    real=$(readlink -f "$symlink")
    base=$(basename "$real")
    echo "STRIX GUARD:   $label symlink → $real"
    size_bytes=$(blockdev --getsize64 "$real")
    size_gb=$((size_bytes / 1024 / 1024 / 1024))
    lo=$((exp_gb - SIZE_TOLERANCE_GB)); hi=$((exp_gb + SIZE_TOLERANCE_GB))
    if [ "$size_gb" -lt "$lo" ] || [ "$size_gb" -gt "$hi" ]; then
        fail "$label size ${size_gb} GiB outside expected [${lo}, ${hi}] GiB."
    fi
    model_path="/sys/block/${base}/device/model"
    [ -r "$model_path" ] || fail "$label model file unreadable: $model_path"
    model=$(tr -d '\n' < "$model_path" | sed 's/[[:space:]]*$//')
    echo "$model" | grep -qF "$exp_model" || fail "$label model '$model' lacks '$exp_model'."
    echo "STRIX GUARD:   $label OK: ${size_gb} GiB, '$model'"
}

echo "STRIX GUARD: verifying install target (system drive)…"
check_drive "$TARGET" "$TARGET_EXPECTED_SIZE_GB" "$TARGET_EXPECTED_MODEL" "TARGET"
echo "STRIX GUARD: verifying data drive identity…"
check_drive "$DATA" "$DATA_EXPECTED_SIZE_GB" "$DATA_EXPECTED_MODEL" "DATA"
DATA_REAL=$(readlink -f "$DATA")

if [ "$WIPE" = "1" ]; then
    echo "STRIX WIPE: recreating the data drive layout (R9)…"
    # Belt-and-suspenders: refuse to wipe the drive Anaconda installs onto.
    [ "$DATA_REAL" != "$(readlink -f "$TARGET")" ] || fail "DATA resolves to TARGET — refusing."
    wipefs -a "$DATA_REAL"
    parted -s "$DATA_REAL" -- \
        mklabel gpt \
        mkpart strix-home xfs 1MiB $((1 + MIB_HOME))MiB \
        mkpart strix-containers xfs $((1 + MIB_HOME))MiB $((1 + MIB_HOME + MIB_CTR))MiB \
        mkpart strix-vm xfs $((1 + MIB_HOME + MIB_CTR))MiB $((1 + MIB_HOME + MIB_CTR + MIB_VM))MiB \
        mkpart strix-log xfs $((1 + MIB_HOME + MIB_CTR + MIB_VM))MiB 100%
    udevadm settle || sleep 3
    P="${DATA_REAL}p"
    mkfs.xfs -f -m uuid="$UUID_HOME" -L strix-home       "${P}1"
    mkfs.xfs -f -m uuid="$UUID_CTR"  -L strix-ctr        "${P}2"
    mkfs.xfs -f -m uuid="$UUID_VM"   -L strix-vm         "${P}3"
    mkfs.xfs -f -m uuid="$UUID_LOG"  -L strix-log        "${P}4"
    udevadm settle || sleep 3
    echo "STRIX WIPE: data drive recreated (home/containers/vm/log)."
else
    echo "STRIX PRESERVE: verifying existing data-drive layout (match-or-halt)…"
    for u in "$UUID_HOME" "$UUID_CTR" "$UUID_VM" "$UUID_LOG"; do
        blkid -U "$u" >/dev/null 2>&1 || fail \
            "expected filesystem UUID $u not found on the data drive.
STRIX GUARD: this drive does not carry the strix v1 layout (a first install,
STRIX GUARD: or a noir/FCOS-era drive). Use strix-wipe.iso for the one-time
STRIX GUARD: migration — preserve mode refuses to guess."
    done
    echo "STRIX PRESERVE: all four strix filesystems present. Proceeding."
fi

echo "STRIX GUARD: all checks passed. Proceeding with install onto $TARGET."
%end

# ─── %post: seed the data-drive home (closes the shadowed-home trap) ─────────
# Anaconda created core + authorized_keys under the SYSTEM drive's /var/home;
# at runtime var-home.mount shadows it with the data drive. Seed the data
# drive here (wipe installs — fresh fs; preserve installs already carry a
# home and are left untouched). strix-home-seed.service in the image is the
# self-healing runtime fallback for the same trap.
%post --erroronfail
set -eu
export LC_ALL=C

SEED_MNT=/mnt/strix-home-seed
mkdir -p "$SEED_MNT"
if mount -U "e3b1c7a5-2f4d-4b8e-9c6a-1d5f7e9b3a21" "$SEED_MNT"; then
    if [ ! -d "$SEED_MNT/core" ] && [ -d /var/home/core ]; then
        # cp -a preserves the security.selinux xattrs Anaconda applied to
        # /var/home/core — that IS the labeling mechanism here (restorecon
        # under /mnt is a file_contexts <<none>> no-op; the runtime
        # strix-home-seed unit relabels at the real path as backstop).
        cp -a /var/home/core "$SEED_MNT/core"
        chown -R 1000:1000 "$SEED_MNT/core"
        echo "strix %post: seeded core home onto the data drive."
    else
        echo "strix %post: data-drive home already present (preserve) — untouched."
    fi
    umount "$SEED_MNT"
else
    echo "strix %post: WARN — could not mount strix-home; runtime seed unit will retry." >&2
fi
%end
