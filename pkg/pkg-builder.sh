#!/bin/bash

set -euo pipefail  # Exit on error and treat unset variables as errors

# Configuration variables

readonly SSH_PRIVATE_KEY="${1:-${SSH_PRIVATE_KEY}}"
readonly GPG_PASSPHRASE="${2:-${GPG_PASSPHRASE}}"
readonly GPG_PRIVATE_KEY="${3:-${GPG_PRIVATE_KEY}}"
readonly PKGBUILD_REPO_URL="https://github.com/shani8dev/shani-pkgbuilds.git"
readonly PUBLIC_REPO_URL="git@github.com:shani8dev/shani-repo.git"
readonly BASE_LOGFILE="build_process.log"  # Initialize base log file

# Check essential environment variables
for var in SSH_PRIVATE_KEY GPG_PASSPHRASE GPG_PRIVATE_KEY; do
    if [[ -z "${!var}" ]]; then
        echo "Error: $var is not set."
        exit 1
    fi
done

# Determine architecture and set ARCH_DIR
readonly ARCH=$(uname -m)

case "$ARCH" in
    x86_64)
        ARCH_DIR="public-repo/x86_64"
        ;;
    armv7l|aarch64)
        ARCH_DIR="public-repo/arm"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Logging function
log() {
    local log_file="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "$timestamp - $message" | sudo tee -a "$log_file"
}

# Function to install Docker if not already installed
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "$BASE_LOGFILE" "Docker not found, installing..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian) sudo apt-get update && sudo apt-get install -y docker.io ;;
                arch) sudo pacman -S --noconfirm docker ;;
                fedora|centos|rhel) sudo dnf install -y docker ;;
                *) log "$BASE_LOGFILE" "Error: Unsupported OS for Docker installation."; exit 1 ;;
            esac
            log "$BASE_LOGFILE" "Docker installed successfully."
        else
            log "$BASE_LOGFILE" "Error: Unknown OS, cannot install Docker."
            exit 1
        fi
    else
        log "$BASE_LOGFILE" "Docker is already installed."
    fi
}

# Function to setup SSH for Git
setup_ssh() {
    log "$BASE_LOGFILE" "Setting up SSH..."
    mkdir -p ~/.ssh
    echo "$SSH_PRIVATE_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa

    cat <<EOF > ~/.ssh/config
Host github.com
  IdentityFile ~/.ssh/id_rsa
  StrictHostKeyChecking no
EOF
}

# Function to clone or update a repository
clone_or_update_repo() {
    local repo_url="$1"
    local dir_name="$2"

    if [ -d "$dir_name" ]; then
        log "$BASE_LOGFILE" "$dir_name exists, resetting to match remote..."
        cd "$dir_name" || exit
        git fetch origin
        git reset --hard origin/main
        git clean -fdx
        cd .. || exit
    else
        log "$BASE_LOGFILE" "Cloning $dir_name..."
        git clone "$repo_url" "$dir_name"
    fi
}

# Function to remove older versions of a package, keeping the current version
remove_old_versions() {
    local pkgname="$1"
    local ARCH_DIR="$2"
    local current_pkgver="$3"
    local current_pkgrel="$4"

    # Find all package files and signatures matching the package name
    local pkg_files=("$ARCH_DIR/$pkgname"-*.pkg.tar.zst)
    local sig_files=("$ARCH_DIR/$pkgname"-*.pkg.tar.zst.sig)

    # Check if any package files were found
    if [[ ${#pkg_files[@]} -gt 0 ]]; then
        for pkg in "${pkg_files[@]}"; do
            # Extract pkgver and pkgrel from the filename
            [[ "$pkg" =~ $pkgname-([0-9]+)-([0-9]+).* ]] || continue
            local pkgver="${BASH_REMATCH[1]}"
            local pkgrel="${BASH_REMATCH[2]}"

            # Remove package if it's not the current version
            if [[ "$pkgver" != "$current_pkgver" || "$pkgrel" != "$current_pkgrel" ]]; then
                echo "Removing older package: $pkg"
                rm -f "$pkg"
            fi
        done
    fi

    # Check if any signature files were found
    if [[ ${#sig_files[@]} -gt 0 ]]; then
        for sig in "${sig_files[@]}"; do
            # Extract pkgver and pkgrel from the filename
            [[ "$sig" =~ $pkgname-([0-9]+)-([0-9]+).*\.sig$ ]] || continue
            local pkgver="${BASH_REMATCH[1]}"
            local pkgrel="${BASH_REMATCH[2]}"

            # Remove signature if it's not the current version
            if [[ "$pkgver" != "$current_pkgver" || "$pkgrel" != "$current_pkgrel" ]]; then
                echo "Removing older signature: $sig"
                rm -f "$sig"
            fi
        done
    fi
}


# Function to build packages
build_package() {
    local PKGBUILD_DIR="$1"
    local pkgname pkgver pkgrel arch
    source "$PKGBUILD_DIR/PKGBUILD"
    local PKG_FILE="${pkgname}-${pkgver}-${pkgrel}-${arch}.pkg.tar.zst"
    local PKG_SIG="${PKG_FILE}.sig"
    local package_log_file="build_${pkgname}.log"

    # Check if package already exists in public repo with matching version
    if [ -f "$ARCH_DIR/$PKG_FILE" ] && [ -f "$ARCH_DIR/$PKG_SIG" ]; then
        log "$package_log_file" "Package $PKG_FILE and $PKG_SIG already exists, skipping build..."
        return
    fi

    # Remove older versions while keeping the current version
    remove_old_versions "$pkgname" "$ARCH_DIR" "$pkgver" "$pkgrel"

    log "$package_log_file" "Building new package: $pkgname version $pkgver"
    # Change ownership of PKGBUILD_DIR before running Docker
    sudo chown -R "$(whoami):$(whoami)" "$PKGBUILD_DIR"
    echo "$GPG_PRIVATE_KEY" > gpg-private.key
    sudo docker run --rm \
        -v "$(pwd):/pkg" \
        -v "$(pwd)/gpg-private.key:/home/builduser/.gnupg/temp-private.asc" \
        -e PKGBUILD_DIR="$(basename "$PKGBUILD_DIR")" \
        -e GPG_PASSPHRASE="$GPG_PASSPHRASE" \
        -e PKG_FILE="$PKG_FILE" \
        archlinux/archlinux:base-devel bash -c "
        useradd -m builduser || true
        mkdir -p /home/builduser/.gnupg
        chown -R builduser:builduser /home/builduser/.gnupg
        chown -R builduser:builduser /pkg  # Change ownership of the /pkg directory
        su - builduser -c \"
            echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /home/builduser/.gnupg/temp-private.asc || { echo 'GPG private key import failed'; exit 1; }
            cd /pkg/$PKGBUILD_DIR || { echo 'Failed to change directory'; exit 1; }
            makepkg -sc --noconfirm || { echo 'Package build failed'; exit 1; }
            echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --detach-sign --output \"${PKG_FILE}.sig\" --sign \"${PKG_FILE}\" || { echo 'Signing failed for ${PKG_FILE}'; exit 1; }
        \"
    "

    # Move the built package and signature to the public repo
    if [ -f "$PKGBUILD_DIR/$PKG_FILE" ]; then
        sudo mv "$PKGBUILD_DIR/$PKG_FILE" "$ARCH_DIR/" || log "$BASE_LOGFILE" "Warning: Failed to move $PKG_FILE."
    else
        log "$BASE_LOGFILE" "Warning: Package file not found."
    fi

    if [ -f "$PKGBUILD_DIR/$PKG_SIG" ]; then
        sudo mv "$PKGBUILD_DIR/$PKG_SIG" "$ARCH_DIR/" || log "$BASE_LOGFILE" "Warning: Failed to move $PKG_SIG."
    else
        log "$BASE_LOGFILE" "Warning: Signature file not found."
    fi

    # Clean up build directories
    rm -rf "$PKGBUILD_DIR/pkg" "$PKGBUILD_DIR/src"
}

# Function to update the repository database
update_repo_database() {
    log "$BASE_LOGFILE" "Updating package repository database..."
    sudo docker run --rm -v "$(pwd)/$ARCH_DIR:/repo" archlinux/archlinux:base-devel /bin/bash -c "
      cd /repo || { echo 'Failed to change directory'; exit 1; }
      rm -f shani.db* shani.files*
      repo-add shani.db.tar.gz *.pkg.tar.zst
    "
}

# Function to commit and push changes to the public repository
commit_and_push() {
    cd "public-repo" || exit 1
    log "$BASE_LOGFILE" "Committing and pushing changes to public repository..."
    git config --global user.name "Shrinivas Kumbhar"
    git config --global user.email "shrinivas.v.kumbhar@gmail.com"
    git add .
    git commit -m "Update package repository with new builds" || log "$BASE_LOGFILE" "No changes to commit."
    if ! git push; then
        log "$BASE_LOGFILE" "Error: Failed to push changes to the public repository."
        exit 1
    fi
    log "$BASE_LOGFILE" "Changes pushed to the public repository successfully."
}

# Main script execution
log "$BASE_LOGFILE" "Starting build process..."

# Step 1: Install Docker if not already installed
install_docker

# Step 2: Setup SSH
setup_ssh

# Step 3: Clone or update the PKGBUILD repository
log "$BASE_LOGFILE" "Handling PKGBUILD repository..."
clone_or_update_repo "$PKGBUILD_REPO_URL" "PKGBUILD-repo"

# Step 4: Clone or update the public repository
log "$BASE_LOGFILE" "Handling public repository..."
clone_or_update_repo "$PUBLIC_REPO_URL" "public-repo"

# Step 5: Ensure architecture directory exists in the public repo
log "$BASE_LOGFILE" "Ensuring architecture directory exists in public repo..."
mkdir -p "$ARCH_DIR"

# Step 6: Build packages
log "$BASE_LOGFILE" "Building and signing packages..."
for PKGBUILD_DIR in PKGBUILD-repo/*; do
    if [ -d "$PKGBUILD_DIR" ] && [ -f "$PKGBUILD_DIR/PKGBUILD" ]; then
        build_package "$PKGBUILD_DIR"
    fi
done

# Step 7: Update repository database
update_repo_database

# Step 8: Commit and push changes
commit_and_push

log "$BASE_LOGFILE" "Build process completed successfully."
