# Dockerfile for building ShaniOS install-media
# Based on Arch

FROM archlinux:base-devel

# Initialize and populate the keyring
RUN pacman-key --init && \
    pacman-key --recv-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792 --keyserver keys.openpgp.org && \
    pacman-key --lsign-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792

# Add custom repository to pacman.conf
RUN echo -e "[shani]\nServer = https://repo.shani.dev/x86_64" >> /etc/pacman.conf

# Update package database and install necessary packages
RUN pacman -Sy --noconfirm archlinux-keyring && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm shani-keyring && \
    pacman --noconfirm -Syu && \
    pacman --noconfirm -S --needed archiso git pacman-contrib shim-signed sbsigntools btrfs-progs arch-install-scripts && \
    pacman -Scc --noconfirm  # Clean package cache

# Create build user and configure environment
RUN useradd -m builduser || true && \
    mkdir -p /home/builduser/.gnupg && \
    chown -R builduser:builduser /home/builduser/.gnupg && \
    echo 'builduser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Set the working directory
WORKDIR /root/shanios

# Build pikaur packages as the 'build' user
ENV BUILD_USER "builduser"
ENV GNUPGHOME "/etc/pacman.d/gnupg"

