# ─────────────────────────────────────────────────────────────────────────────
# Containerfile — strix (Minisforum MS-S1 MAX / AMD Strix Halo) bootc image.
#
# Single source of truth for the strix OS (REQUIREMENTS.md R1). Built by CI,
# pushed to ghcr.io/oso-gato/strix-ms-s1-bootc, booted directly by the machine
# via bootc; installed initially from the BIB-built anaconda ISOs (build-iso.sh).
#
# Base: quay.io/fedora/fedora-bootc:44 — the "standard" content set (verified
# 2026-07-11): already contains podman, NetworkManager, openssh-server, dnf5,
# chrony, bootc, rpm-ostree; NO firewalld (by design — strix's access boundary
# is the network layer, R6); bootc-fetch-apply-updates.timer is pre-enabled by
# the base (8h check + auto-apply + reboot), which IS strix's R11 update
# posture — do not disable it.
#
# Pin :44, never :latest (:latest silently rebases to Fedora 45 at release).
# Kernel note: F44 currently ships 7.1.3 — the MT7925 btmtk Bluetooth
# regression (stable 7.0.7) is fixed since 7.0.10/Fedora 7.0.8; do not roll
# back to a 7.0.7-era image digest.
#
# Layering discipline (R1): Fedora repos + two vendor repos (Tailscale on the
# host; Anthropic inside the claudebox only — the host never installs
# claude-code). Additive only; no config file shipped by the base is replaced.
# ─────────────────────────────────────────────────────────────────────────────
FROM quay.io/fedora/fedora-bootc:44

# sysroot/ mirrors the filesystem: /etc configs, /usr/bin scripts, systemd
# units + drop-ins, tmpfiles.d, claudebox manifest. COPY before dnf so the
# Tailscale .repo file is in place for the install step.
COPY sysroot/ /

# ─── Packages (R2 Wi-Fi stack · R3 tailscale · R6 cockpit · R7 virt · R4/R8 shell+box) ───
# install_weak_deps=False keeps the image lean; everything needed is explicit:
#   Wi-Fi (baked at build — wlp99s0 exists on boot 1, no two-boot dance):
#     mt7xxx-firmware wireless-regdb NetworkManager-wifi wpa_supplicant
#   tailscale        : vendor repo (sysroot/etc/yum.repos.d/tailscale.repo,
#                      gpgcheck=1 + repo_gpgcheck=1, verified 2026-07-11)
#   cockpit          : 7 explicit subpackages + selinux + machines (R6/D13).
#                      cockpit-machines hard-requires the libvirt core it
#                      needs (libvirt-dbus, virt-install, qemu-kvm-core,
#                      driver-qemu/-network/-nodedev/-storage-core,
#                      daemon-config-network) — we list the load-bearing ones
#                      explicitly anyway so the manifest is self-documenting.
#   virt extras      : swtpm + edk2-ovmf (UEFI/TPM guests) + qemu-device-usb-
#                      host/-redirect (Cockpit's USB passthrough — Fedora
#                      Recommends, dropped by install_weak_deps=False, so
#                      explicit), libvirt-client (virsh).
#   shell            : tmux mosh (R4; mosh = UDP 60001-60999, no config on a
#                      firewall-less host) + fastfetch (amendment A1: banner
#                      on every ssh/mosh login, before the tmux attach)
#   claudebox        : distrobox (box runtime; claude-code lives IN the box)
#                      + flatpak-session-helper (A3: host-side helper backing
#                      host-spawn — the box→host command bridge for the
#                      workbench's host-maintenance role)
#   firstboot        : gh (device-flow pull of firstboot.yaml, R12),
#                      python3 + python3-pyyaml (parse firstboot.yaml)
#   net tooling      : ethtool (tailscale-udp-gro unit)
#   ops (A6)         : smartmontools (smartd — the only thing watching the
#                      "permanent" 4 TB drive's health; journal alerts),
#                      tcpdump+mtr (router 2am kit — real-root raw sockets,
#                      the class the rootless claudebox can't do),
#                      pcp (pmcd/pmlogger collectors + pmproxy REST API —
#                      Fedora 44 retired the cockpit-pcp package; the
#                      metrics-history page ships in cockpit-system and
#                      talks to pmproxy; verified against F44 repos),
#                      cockpit-storaged (storage UI incl. SMART readouts),
#                      rsync (data-drive plumbing), bash-completion,
#                      policycoreutils-python-utils (semanage — applying
#                      SELinux fixes that cockpit-selinux only reports)
RUN dnf -y --setopt=install_weak_deps=False install \
        mt7xxx-firmware wireless-regdb NetworkManager-wifi wpa_supplicant \
        tailscale \
        cockpit-bridge cockpit-system cockpit-ws cockpit-podman \
        cockpit-networkmanager cockpit-files cockpit-ostree \
        cockpit-selinux cockpit-machines cockpit-storaged \
        qemu-kvm-core libvirt-daemon-driver-qemu libvirt-daemon-driver-network \
        libvirt-daemon-driver-nodedev libvirt-daemon-driver-storage-core \
        libvirt-daemon-config-network libvirt-dbus libvirt-client virt-install \
        swtpm edk2-ovmf qemu-device-usb-host qemu-device-usb-redirect \
        tmux mosh fastfetch distrobox flatpak-session-helper gh \
        python3 python3-pyyaml ethtool \
        smartmontools tcpdump mtr pcp rsync bash-completion \
        policycoreutils-python-utils \
    && dnf clean all \
    && rm -rf /var/log/* /var/cache/* /var/lib/dnf

# ─── Permissions the COPY can't be trusted to carry ──────────────────────────
# NM keyfiles must be 0600 (NM refuses group/world-readable keyfiles);
# sudoers.d must be 0440; operator scripts executable.
RUN chmod 0600 /etc/NetworkManager/system-connections/*.nmconnection \
    && chmod 0440 /etc/sudoers.d/strix-bootstrap \
    && chmod 0755 /usr/bin/strix-wifi /usr/bin/strix-setup \
                  /usr/bin/strix-firstboot-setup /usr/bin/strix-table100 \
                  /usr/bin/strix-keys-sync /usr/bin/cockpit-tailnet-serve \
                  /usr/bin/claude \
                  /usr/bin/claudebox-rebuild /usr/bin/claudebox-daily \
                  /usr/share/strix/claudebox/claudebox-init.sh

# ─── Hostname ────────────────────────────────────────────────────────────────
RUN echo "strix" > /etc/hostname

# ─── Service enablement (offline [Install]-symlink creation; no --now) ───────
#   cockpit.socket    : socket-activated web console on :9090 (R6)
#   tailscaled        : VPN daemon; onboarding happens at strix-setup (R3/R12)
#   podman.socket     : /run/podman/podman.sock for cockpit-podman + claudebox
#   virt* sockets     : modular libvirt, socket-activated (R7). Fedora's
#                       90-default.preset would enable the full modular set
#                       anyway; this list is the PINNED subset the box
#                       actually depends on (incl. virtnodedevd — cockpit-
#                       machines' Host-devices UI needs its socket listening).
#   sshd              : enabled in base, re-enabled defensively
#   strix-* units     : mounts, seeds, firstboot, verify, timers (R9/R12/R13)
#   claudebox timer   : per-user (--global) daily rebuild decision (R8)
# bootc-fetch-apply-updates.timer: pre-enabled by the fedora-bootc base — R11.
RUN systemctl enable \
        sshd.service cockpit.socket podman.socket tailscaled.service \
        virtqemud.socket virtnetworkd.socket virtstoraged.socket \
        virtnodedevd.socket virtlogd.socket \
        var-home.mount var-lib-containers.mount var-lib-libvirt.mount \
        var-log.mount etc-libvirt.mount \
        strix-home-seed.service strix-libvirt-seed.service \
        strix-libvirt-relabel.service \
        strix-firstboot-setup.service strix-setup-tty1.service \
        strix-postinstall-verify.service tailscale-udp-gro.service \
        cockpit-tailnet-serve.service \
        strix-table100.timer strix-keys-sync.timer \
        smartd.service pmcd.service pmlogger.service pmproxy.service \
    && systemctl --global enable claudebox-rebuild-daily.timer podman.socket
# (--global podman.socket: every user gets a rootless podman API socket at
#  /run/user/<uid>/podman/podman.sock — the claudebox CONTAINER_HOST bridge.)

# ─── Build-time gate ─────────────────────────────────────────────────────────
# bootc's own linter: catches /var content that would never reach installed
# machines, missing tmpfiles coverage, and label problems (R1/R13 CI gate).
RUN bootc container lint
