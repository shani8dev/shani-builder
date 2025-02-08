#!/bin/bash
set -euo pipefail

### CONFIG ###
DOWNLOAD_DIR="/deployment/shared/downloads"
ZSYNC_CACHE_DIR="/deployment/shared/zsync_cache"
DEPLOYMENT_DIR="/deployment/shared"
MOUNT_DIR="/mnt"
SECUREBOOT_SCRIPT="/usr/local/bin/uefi-secureboot.sh"
MIN_FREE_SPACE_MB=10240   # Minimum required disk space (10GB)
MIN_METADATA_FREE_MB=512  # Minimum required Btrfs metadata space (512MB)
BUILD_VERSION="$(date +%Y%m%d)"
PROFILE="default"
IMAGE_NAME="shani-os-${BUILD_VERSION}-${PROFILE}.zst"
IMAGE_URL="https://example.com/path/to/${IMAGE_NAME}.zsync"

### Logging Functions ###
log() { echo -e "\e[34m📝 $1\e[0m"; }   # Blue for info
log_success() { echo -e "\e[32m✅ $1\e[0m"; }  # Green for success
log_error() { echo -e "\e[31m❌ $1\e[0m" >&2; exit 1; }  # Red for errors

trap 'log_error "Unexpected error occurred!"' ERR

check_storage() {
    log "📊 Checking storage availability..."

    # Check available disk space
    FREE_SPACE_MB=$(df --output=avail "$DEPLOYMENT_DIR" | tail -n 1 | awk '{print $1 / 1024}')
    if (( FREE_SPACE_MB < MIN_FREE_SPACE_MB )); then
        log_error "Not enough disk space! Required: ${MIN_FREE_SPACE_MB}MB, Available: ${FREE_SPACE_MB}MB"
    fi
    log_success "💾 Sufficient disk space: ${FREE_SPACE_MB}MB"

    # Check Btrfs metadata space
    METADATA_FREE_KB=$(btrfs filesystem usage "$DEPLOYMENT_DIR" | awk '/Metadata,.*free/ {print $NF}')
    METADATA_FREE_MB=$((METADATA_FREE_KB / 1024))
    if (( METADATA_FREE_MB < MIN_METADATA_FREE_MB )); then
        log_error "Not enough Btrfs metadata space! Required: ${MIN_METADATA_FREE_MB}MB, Available: ${METADATA_FREE_MB}MB"
    fi
    log_success "🗄️ Sufficient Btrfs metadata space: ${METADATA_FREE_MB}MB"
}

prepare_environment() {
    log "📁 Preparing environment..."
    mkdir -p "$DOWNLOAD_DIR" "$ZSYNC_CACHE_DIR"
}

download_image() {
    log "🌍 Downloading image..."
    cd "$DOWNLOAD_DIR"
    
    # Use zsync to download the latest image
    zsync --cache-dir="$ZSYNC_CACHE_DIR" "$IMAGE_URL"
    wget -q "${IMAGE_URL}.sha256" -O "${IMAGE_NAME}.sha256"
    wget -q "${IMAGE_URL}.asc" -O "${IMAGE_NAME}.asc"
}

verify_image() {
    log "🔍 Verifying image integrity..."

    sha256sum -c "${IMAGE_NAME}.sha256" || log_error "SHA256 checksum verification failed!"
    gpg --verify "${IMAGE_NAME}.asc" "$IMAGE_NAME" || log_error "PGP signature verification failed!"

    log_success "✅ Image verification successful!"
}

deploy_image() {
    log "🚀 Deploying image..."
    start_time=$(date +%s)

    # Detect the active and inactive subvolumes
    ACTIVE_SUBVOL=$(findmnt -n -o SOURCE / | grep -oE 'roota|rootb')
    TARGET_SUBVOL=$([[ "$ACTIVE_SUBVOL" == "roota" ]] && echo "rootb" || echo "roota")
    TEMP_SUBVOL="${TARGET_SUBVOL}.tmp"

    log "🛠 Target Subvolume: $TARGET_SUBVOL"

    # Mount deployment directory
    mkdir -p "$MOUNT_DIR"
    mount -o subvol=/ "$DEPLOYMENT_DIR" "$MOUNT_DIR"

    # Remove existing temporary subvolume if it exists
    if btrfs subvolume list "$MOUNT_DIR" | grep -q "$TEMP_SUBVOL"; then
        log "🧹 Removing stale temporary subvolume..."
        btrfs subvolume delete "$MOUNT_DIR/$TEMP_SUBVOL"
    fi

    # Create a new temporary subvolume
    log "📦 Creating temporary subvolume..."
    btrfs subvolume create "$MOUNT_DIR/$TEMP_SUBVOL"

    # Extract system image using zstd
    log "📦 Extracting image..."
    zstd -d --long -T0 "$DOWNLOAD_DIR/$IMAGE_NAME" -c | btrfs receive "$MOUNT_DIR/$TEMP_SUBVOL"
    log_success "✅ Image extracted successfully!"

    # Backup old subvolume before switching
    OLD_SUBVOL_BACKUP="${TARGET_SUBVOL}-backup-$(date +%Y%m%d%H%M)"
    if [[ -d "$MOUNT_DIR/$TARGET_SUBVOL" ]]; then
        log "📂 Backing up old subvolume as $OLD_SUBVOL_BACKUP..."
        btrfs subvolume snapshot "$MOUNT_DIR/$TARGET_SUBVOL" "$MOUNT_DIR/$OLD_SUBVOL_BACKUP"
    fi

    # Rename subvolumes safely
    log "🔄 Switching to new subvolume..."
    btrfs subvolume snapshot "$MOUNT_DIR/$TEMP_SUBVOL" "$MOUNT_DIR/$TARGET_SUBVOL"
    btrfs subvolume delete "$MOUNT_DIR/$TEMP_SUBVOL"

    # Clean up the old backup if needed
    if [[ -d "$MOUNT_DIR/${TARGET_SUBVOL}-old" ]]; then
        log "🧹 Cleaning up old subvolume..."
        btrfs subvolume delete "$MOUNT_DIR/${TARGET_SUBVOL}-old"
    fi

    umount -R "$MOUNT_DIR" || log_error "Unmount failed!"
    log_success "🚀 Deployment complete!"

    # Secure Boot Setup
    if [[ -x "$SECUREBOOT_SCRIPT" ]]; then
        log "🔐 Setting up Secure Boot..."
        "$SECUREBOOT_SCRIPT" configure "$TARGET_SUBVOL"
        log_success "🔏 Secure Boot configured!"
    else
        log "⚠️ Secure Boot script not found. Skipping."
    fi

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    log_success "⏳ Deployment finished in $elapsed seconds!"
}

main() {
    prepare_environment
    check_storage
    download_image
    verify_image
    deploy_image
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

