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

# Simple logging function to output directly to shell
log() {
    local message="$1"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "$timestamp - $message"
}

# Function to install Docker if not already installed
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "Docker not found, installing..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian) apt-get update && apt-get install -y docker.io ;;
                arch) pacman -S --noconfirm docker ;;
                fedora|centos|rhel) dnf install -y docker ;;
                *) log "Error: Unsupported OS for Docker installation."; exit 1 ;;
            esac
            log "Docker installed successfully."
        else
            log "Error: Unknown OS, cannot install Docker."
            exit 1
        fi
    else
        log "Docker is already installed."
    fi
}

# Function to setup SSH for Git
setup_ssh() {
    log "Setting up SSH..."
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
        log "$dir_name exists, resetting to match remote..."
        cd "$dir_name" || exit
        git fetch origin
        git reset --hard origin/main
        git clean -fdx
        cd .. || exit
    else
        log "Cloning $dir_name..."
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -i ./ssh-config/id_rsa' git clone "$repo_url" "$dir_name"
    fi
}

# Function to clean up old versions of packages
cleanup_old_versions() {
    local ARCH_DIR="$1"  # Directory containing the packages

    # Ensure the architecture directory exists
    if [[ ! -d "$ARCH_DIR" ]]; then
        echo "Directory $ARCH_DIR does not exist."
        return
    fi

    # Create an array to hold the names of current packages
    local current_packages=()

    # Loop through the PKGBUILD files to build a list of current package names
    for PKGBUILD_DIR in shani-pkgbuilds/*/; do
        if [ -f "$PKGBUILD_DIR/PKGBUILD" ]; then
            source "$PKGBUILD_DIR/PKGBUILD"
            # Construct full package name for each architecture
            for arch_current in "${arch[@]}"; do
                current_packages+=("${pkgname}-${pkgver}-${pkgrel}-${arch_current}")
            done
        fi
    done

    # Debug: List current packages for verification
    echo "Current packages:"
    printf '%s\n' "${current_packages[@]}"

    # Loop through both .pkg.tar.zst and .pkg.tar.zst.sig files in the architecture directory
    for file in "$ARCH_DIR/"*.pkg.tar.zst "$ARCH_DIR/"*.pkg.tar.zst.sig; do
        [[ -e $file ]] || continue  # Skip if no files match

        # Extract the package name, version, release, and architecture from the filename
        if [[ "$file" =~ (.*)/(.*)-(.*)-(.*)-(.*)\.pkg\.tar\.zst(\.sig)? ]]; then
            local pkgname="${BASH_REMATCH[2]}"
            local pkgver="${BASH_REMATCH[3]}"
            local pkgrel="${BASH_REMATCH[4]}"
            local arch="${BASH_REMATCH[5]}"

            local full_name="${pkgname}-${pkgver}-${pkgrel}-${arch}"
            local is_current=0

            # Check if the full package name exists in the current packages array
            for current in "${current_packages[@]}"; do
                if [[ "$full_name" == "$current" ]]; then
                    is_current=1
                    break  # No need to check further if found
                fi
            done

            # Debug: Display the full package name being processed
            echo "Processed package: $full_name"

            # Remove old version if not found in current packages
            if [[ $is_current -eq 0 ]]; then
                log "Removing old version: $file"
                rm -f "$file"
            else
                log "Keeping current version: $file"
            fi
        else
            log "Skipping unrecognized file format: $file"
        fi
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
        shrinivasvkumbhar/shani-builder:latest bash -c "
        # Create GnuPG directory and set ownership for builduser
        mkdir -p /home/builduser/.gnupg && \
        chown -R builduser:builduser /home/builduser/.gnupg
        chown -R builduser:builduser /pkg  # Change ownership of the /pkg directory
        
        # Update the package database
        pacman -Sy --noconfirm git || { echo 'Failed to update package database'; exit 1; }
        
        su - builduser -c \"
        		# Import the GPG private key
            echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /home/builduser/.gnupg/temp-private.asc || { echo 'GPG private key import failed'; exit 1; }
            cd /pkg/$PKGBUILD_DIR || { echo 'Failed to change directory'; exit 1; }
            
            # Attempt to build the package
            if ! makepkg -sc --noconfirm; then
                echo 'Package build failed for $PKGBUILD_DIR'
            fi

            # Attempt to sign the package
            if ! echo \"$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --detach-sign --output \"${PKG_FILE}.sig\" --sign \"${PKG_FILE}\"; then
                echo 'Signing failed for ${PKG_FILE}'
            fi
        \"
    "

    # Move the built package and signature to the public repo
    for file in "$PKG_FILE" "$PKG_SIG"; do
        if [ -f "$PKGBUILD_DIR/$file" ]; then
            mv "$PKGBUILD_DIR/$file" "$ARCH_DIR/" || log "Warning: Failed to move $file."
            db_update_required=true  # Mark for database update
        else
            log "Warning: $file not found."
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
        log "No changes detected for $pkgname, skipping database update."
    else
        log "Updating database for $pkgname..."
        echo "$pkgname" >> "$DB_UPDATE_FILE"  # Append to the database
        docker run --rm -v "$(pwd)/$ARCH_DIR:/repo" shrinivasvkumbhar/shani-builder:latest /bin/bash -c "
          cd /repo || { echo 'Failed to change directory'; exit 1; }
          rm -f shani.db* shani.files*
          # Add packages to the repo database
          repo-add shani.db.tar.gz *.pkg.tar.zst
          
          rm -f shani.db shani.files
          
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

    log "Committing changes to the repository..."
    cd "$repo_dir" || exit

    if ! git diff --quiet; then
        git config --global user.name "Shrinivas Kumbhar"
        git config --global user.email "shrinivas.v.kumbhar@gmail.com"
        git add .
        git commit -m "$commit_msg"
        log "Changes committed successfully."
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -i ../ssh-config/id_rsa' git push origin main
        log "Changes pushed to the remote repository."
    else
        log "No changes to commit."
    fi
}

# Function to clean up temporary SSH configuration
cleanup_ssh() {
    log "Cleaning up temporary SSH configuration..."
    rm -rf ./ssh-config
}

# Install Docker if not present
install_docker

# Setup SSH configuration
setup_ssh

# Clone or update pkgbuild repository
log "Handling PKGBUILD repository..."
clone_or_update_repo "$PKGBUILD_REPO_URL" "shani-pkgbuilds"

# Clone or update the public repository
log "Handling public repository..."
clone_or_update_repo "$PUBLIC_REPO_URL" "shani-repo"

# Ensure architecture directory exists in the public repo
log "Ensuring architecture directory exists in public repo..."
mkdir -p "$ARCH_DIR"

# Cleanup old versions based on current PKGBUILD files
cleanup_old_versions "$ARCH_DIR"

# Loop through each PKGBUILD in the PKGBUILD repository and build packages
log "Building and signing packages..."
for PKGBUILD_DIR in shani-pkgbuilds/*/; do
    if [ -f "$PKGBUILD_DIR/PKGBUILD" ]; then
        build_package "$PKGBUILD_DIR"
    else
        log "Skipping $PKGBUILD_DIR, no PKGBUILD found."
    fi
done

# Commit and push changes to the public repository
commit_and_push "shani-repo" "Update package repository with new builds"

cleanup_ssh  # Cleanup SSH after repository cloning

log "Build process completed successfully."

