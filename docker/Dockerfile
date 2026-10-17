FROM archlinux:base-devel

LABEL org.opencontainers.image.title="shani-builder" \
      org.opencontainers.image.description="Privileged Arch Linux build environment for Shani OS image and ISO assembly" \
      org.opencontainers.image.source="https://github.com/shani8dev/shani-builder" \
      org.opencontainers.image.licenses="GPL-3.0"

# ── Keyring + custom repo + full system upgrade + all tooling in one layer ──
# Combining into a single RUN avoids intermediate layers with a half-updated
# package database, which causes pacman signature errors on cache hits.
# Cache is purged at the end to keep the image lean.
RUN pacman-key --init && \
    pacman-key --recv-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792 \
               --keyserver keys.openpgp.org && \
    pacman-key --lsign-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792 && \
    echo -e "[shani]\nServer = https://repo.shani.dev/x86_64" >> /etc/pacman.conf && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm shani-keyring && \
    pacman-key --populate shani && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm --ask=4 iptables-nft && \
    pacman -S --noconfirm --needed \
        archiso git pacman-contrib btrfs-progs arch-install-scripts \
        shim-signed sbsigntools mokutil mtools \
        zsync zsync2 rsync rclone openssh \
        flatpak systemd dbus squashfuse snapd \
        qemu-base edk2-ovmf swtpm \
        mktorrent && \
    pacman -Scc --noconfirm

# ── Why qemu-base / edk2-ovmf / swtpm are baked in rather than installed on demand ──
# shani-testbed boots real UEFI firmware in this container: `iso-install` (the only
# way to run a command against the image's OWN kernel, since systemd-nspawn shares
# the host's), plus `qemu` and `gui`. All three need qemu-system-x86_64, the OVMF
# firmware and a software TPM, and none of them were here.
#
# The absence failed in three different ways, none of them loud:
#   * `iso-install` worked, but only because it runs `pacman -Sy` for the missing
#     tools on every invocation. The builder container is `--rm`, so the install is
#     thrown away each time: every run re-downloads and re-installs, and a run with
#     no network fails at the last minute of a boot that takes minutes.
#   * `qemu` and `gui` have no such preflight at all. `lib/qemu.sh` exits 1 and
#     prints `apt install qemu-system-x86 ovmf   (Debian/Ubuntu)` — Debian
#     instructions, on an Arch image, for a command that cannot work.
#   * so a firmware-boot capability looked present (the commands exist, the docs
#     describe them, `iso-install` is even documented with real transcripts) while
#     being unreachable, and the only evidence was a missing binary.
#
# `qemu-base` depends on `qemu-img`, which the harness also needs: `vmspawn` boots
# a qcow2 overlay backed by the image and (with `--commit`) writes the guest's
# changes back with `qemu-img commit`. That path was previously only exercisable
# from inside vmspawn's own throwaway container, which installs its own qemu.

# ── Build user + GPG home + import Shani signing key as builduser ───────────
# gpg --recv-key must run as builduser so the key lands in
# /home/builduser/.gnupg — not the root keyring. The previous version ran
# this as root, meaning builduser never had the key available when build
# scripts called gpg --homedir /home/builduser/.gnupg.
RUN useradd -m builduser || true && \
    mkdir -p /home/builduser/.gnupg && \
    chmod 700 /home/builduser/.gnupg && \
    chown -R builduser:builduser /home/builduser/.gnupg && \
    echo 'builduser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers && \
    su - builduser -c \
        'gpg --homedir /home/builduser/.gnupg \
             --keyserver keys.openpgp.org \
             --recv-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792'

ENV BUILD_USER="builduser"
ENV GNUPGHOME="/home/builduser/.gnupg"

WORKDIR /home/builduser/build
