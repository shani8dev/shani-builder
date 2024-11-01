#!/bin/bash

set -euo pipefail  # Exit on error and treat unset variables as errors

# Configuration variables
readonly SSH_PRIVATE_KEY="${1:-${SSH_PRIVATE_KEY}}"
readonly GPG_PASSPHRASE="${2:-${GPG_PASSPHRASE}}"
readonly GPG_PRIVATE_KEY="${3:-${GPG_PRIVATE_KEY}}"
readonly PKGBUILD_REPO_URL="git@github.com:shani8dev/shani-pkgbuilds.git"
readonly PUBLIC_REPO_URL="git@github.com:shani8dev/shani-repo.git"
readonly DB_UPDATE_FILE="./db_update.txt"  # File to track package updates
readonly BASE_LOGFILE="./build_process.log"  # Initialize base log file

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
        ARCH_DIR="./shani-repo/x86_64"
        ;;
    armv7l|aarch64)
        ARCH_DIR="./shani-repo/arm"
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
    echo "$timestamp - $message" >> "$log_file"
}

# Function to install Docker if not already installed
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "$BASE_LOGFILE" "Docker not found, installing..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian) apt-get update && apt-get install -y docker.io ;;
                arch) pacman -S --noconfirm docker ;;
                fedora|centos|rhel) dnf install -y docker ;;
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
    mkdir -p ./ssh-config
    echo "$SSH_PRIVATE_KEY" | tr -d '\r' > ./ssh-config/id_rsa
    chmod 600 ./ssh-config/id_rsa

    cat <<EOF > ./ssh-config/config
Host github.com
  IdentityFile ./ssh-config/id_rsa
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
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -i ./ssh-config/id_rsa' git clone "$repo_url" "$dir_name"
    fi
}

# Function to remove older versions of a package, keeping the current version
remove_old_versions() {
    local pkgname="$1"
    local ARCH_DIR="$2"
    local current_pkgver="$3"
    local current_pkgrel="$4"

    # Find and remove old package and signature files
    for file_type in pkg.tar.zst pkg.tar.zst.sig; do
        for file in "$ARCH_DIR/$pkgname"-*.$file_type; do
            [[ -e $file ]] || continue  # Skip if file does not exist
            [[ "$file" =~ $pkgname-([^-.]+)-([^-]+)\.$file_type ]] || continue
            local pkgver="${BASH_REMATCH[1]}"
            local pkgrel="${BASH_REMATCH[2]}"

            # Remove package or signature if it's not the current version
            if [[ "$pkgver" != "$current_pkgver" || "$pkgrel" != "$current_pkgrel" ]]; then
                log "$BASE_LOGFILE" "Removing older ${file_type}: $file"
                rm -f "$file"
            fi
        done
    done
}

# Function to build packages
build_package() {
    local PKGBUILD_DIR="$1"
    local pkgname pkgver pkgrel arch
    source "$PKGBUILD_DIR/PKGBUILD"
    local PKG_FILE="${pkgname}-${pkgver}-${pkgrel}-${arch}.pkg.tar.zst"
    local PKG_SIG="${PKG_FILE}.sig"
    local package_log_file="./build_${pkgname}.log"
    local db_update_required=false

    # Check if package already exists in public repo with matching version
    if [[ -f "$ARCH_DIR/$PKG_FILE" && -f "$ARCH_DIR/$PKG_SIG" ]]; then
        log "$package_log_file" "Package $PKG_FILE and $PKG_SIG already exists, skipping build..."
        return
    fi

    # Remove older versions while keeping the current version
    remove_old_versions "$pkgname" "$ARCH_DIR" "$pkgver" "$pkgrel"

    log "$package_log_file" "Building new package: $pkgname version $pkgver"
    # Change ownership of PKGBUILD_DIR before running Docker
    chown -R "$(whoami):$(whoami)" "$PKGBUILD_DIR"
    
    # Create temporary GPG key file
    echo "$GPG_PRIVATE_KEY" > ./gpg-private.key

    # Run Docker to build the package
    docker run --rm \
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
        
        # Update the package database
        pacman -Sy --noconfirm || { echo 'Failed to update package database'; exit 1; }
        
        su - builduser -c \"
            echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /home/builduser/.gnupg/temp-private.asc || { echo 'GPG private key import failed'; exit 1; }
            cd /pkg/$PKGBUILD_DIR || { echo 'Failed to change directory'; exit 1; }
            makepkg -sc --noconfirm || { echo 'Package build failed'; exit 1; }
            echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --detach-sign --output \"${PKG_FILE}.sig\" --sign \"${PKG_FILE}\" || { echo 'Signing failed for ${PKG_FILE}'; exit 1; }
        \"
    "

    # Move the built package and signature to the public repo
    for file in "$PKG_FILE" "$PKG_SIG"; do
        if [ -f "$PKGBUILD_DIR/$file" ]; then
            mv "$PKGBUILD_DIR/$file" "$ARCH_DIR/" || log "$BASE_LOGFILE" "Warning: Failed to move $file."
            db_update_required=true  # Mark for database update
        else
            log "$BASE_LOGFILE" "Warning: $file not found."
        fi
    done

    # Clean up build directories
    rm -rf "$PKGBUILD_DIR/pkg" "$PKGBUILD_DIR/src"

    # Clean up the temporary GPG key
    rm -f ./gpg-private.key

    if [ "$db_update_required" = true ]; then
        update_database "$pkgname" "$ARCH_DIR"
    fi
}

# Function to update the database only if there are changes
update_database() {
    local pkgname="$1"
    local ARCH_DIR="$2"

    # Check if the database update file exists
    if [[ ! -f "$DB_UPDATE_FILE" ]]; then
        touch "$DB_UPDATE_FILE"
        chown $(whoami):$(whoami) "$DB_UPDATE_FILE"
    fi

    # Check if the package version is already in the database update file
    if grep -q "$pkgname" "$DB_UPDATE_FILE"; then
        log "$BASE_LOGFILE" "No changes detected for $pkgname, skipping database update."
    else
        log "$BASE_LOGFILE" "Updating database for $pkgname..."
        echo "$pkgname" >> "$DB_UPDATE_FILE"  # Append to the database
        docker run --rm -v "$(pwd)/$ARCH_DIR:/repo" archlinux/archlinux:base-devel /bin/bash -c "
          cd /repo || { echo 'Failed to change directory'; exit 1; }
          rm -f shani.db* shani.files*
          # Add packages to the repo database
          repo-add shani.db.tar.gz *.pkg.tar.zst
          
          # Copy the generated database files
          cp shani.db.tar.gz shani.db
          cp shani.files.tar.gz shani.files
        "
    fi
}

# Function to commit and push changes to the public repo
commit_and_push() {
    local repo_dir="$1"
    local commit_msg="$2"

    log "$BASE_LOGFILE" "Committing changes to the repository..."
    cd "$repo_dir" || exit

    if ! git diff --quiet; then
        git config --global user.name "Shrinivas Kumbhar"
        git config --global user.email "shrinivas.v.kumbhar@gmail.com"
        git add .
        git commit -m "$commit_msg"
        log "$BASE_LOGFILE" "Changes committed successfully."
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -i ./ssh-config/id_rsa' git push origin main
        log "$BASE_LOGFILE" "Changes pushed to the remote repository."
    else
        log "$BASE_LOGFILE" "No changes to commit."
    fi
}

# Function to clean up temporary SSH configuration
cleanup_ssh() {
    log "$BASE_LOGFILE" "Cleaning up temporary SSH configuration..."
    rm -rf ./ssh-config
}

# Install Docker if not present
install_docker

# Setup SSH configuration
setup_ssh

# Clone or update pkgbuild repository
log "$BASE_LOGFILE" "Handling PKGBUILD repository..."
clone_or_update_repo "$PKGBUILD_REPO_URL" "shani-pkgbuilds"

# Clone or update the public repository
log "$BASE_LOGFILE" "Handling public repository..."
clone_or_update_repo "$PUBLIC_REPO_URL" "shani-repo"

# Ensure architecture directory exists in the public repo
log "$BASE_LOGFILE" "Ensuring architecture directory exists in public repo..."
mkdir -p "$ARCH_DIR"

# Loop through each PKGBUILD in the PKGBUILD repository and build packages
log "$BASE_LOGFILE" "Building and signing packages..."
for PKGBUILD_DIR in shani-pkgbuilds/*/; do
    if [ -f "$PKGBUILD_DIR/PKGBUILD" ]; then
        build_package "$PKGBUILD_DIR"
    else
        log "$BASE_LOGFILE" "Skipping $PKGBUILD_DIR, no PKGBUILD found."
    fi
done

# Commit and push changes to the public repository
commit_and_push "shani-repo" "Update package repository with new builds"

cleanup_ssh  # Cleanup SSH after repository cloning

log "$BASE_LOGFILE" "Build process completed successfully."

