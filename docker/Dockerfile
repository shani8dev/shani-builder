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
    pacman --noconfirm -S --needed archiso git pacman-contrib btrfs-progs arch-install-scripts shim-signed sbsigntools mokutil mtools zsync rsync openssh flatpak && \
    pacman -Scc --noconfirm  # Clean package cache

# Create build user and configure environment
RUN useradd -m builduser || true && \
    mkdir -p /home/builduser/.gnupg && \
    chmod 700 /home/builduser/.gnupg && \
    chown -R builduser:builduser /home/builduser/.gnupg && \
    echo 'builduser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Set working directory to builduser's home directory
WORKDIR /home/builduser/build

# Set environment variables (using builduser's GNUPGHOME)
ENV BUILD_USER "builduser"
ENV GNUPGHOME "/home/builduser/.gnupg"
RUN gpg --keyserver keys.openpgp.org --recv-key 7B927BFFD4A9EAAA8B666B77DE217F3DA8014792
