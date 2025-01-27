#!/bin/bash

set -euo pipefail

# Constants
WORKDIR="/mnt/shani-root"
BOOTLABEL="SHANI_BOOT"
ROOTLABEL="SHANI_ROOT"
BTRFS_SUBVOLS=("deployment/shared/roota" "deployment/shared/rootb" "deployment/shared/home" "deployment/shared/flatpak")
EFI_MOUNT="/boot/efi"
EFI_PATH="/boot/efi/EFI/Linux"
ZSYNC_CACHE_DIR="/deployment/shared/zsync_cache"
DOWNLOAD_DIR="/deployment/shared/downloads"
IMAGE_URL="https://example.com/path/to/image.btrfs.zsync"  # Replace with actual URL
IMAGE_NAME="image.btrfs"
ZSYNC_FILE="$IMAGE_NAME.zsync"

# Utility function to handle errors
quit_on_err() {
    echo "Error: $1" >&2
    exit 1
}

# Ensure required directories exist
prepare_environment() {
    echo "Preparing environment..."
    [[ ! -d "$WORKDIR" ]] && quit_on_err "Work directory $WORKDIR does not exist."
    for subvol in "${BTRFS_SUBVOLS[@]}"; do
        if [[ ! -d "$WORKDIR/$subvol" ]]; then
            sudo btrfs subvolume create "$WORKDIR/$subvol" || echo "Subvolume $subvol already exists."
        fi
    done
}

# Download image using zsync
download_image() {
    echo "Downloading image using zsync..."

    # Ensure the cache directory exists
    [[ ! -d "$ZSYNC_CACHE_DIR" ]] && mkdir -p "$ZSYNC_CACHE_DIR"

    # Navigate to the download directory
    cd "$DOWNLOAD_DIR"

    # Use zsync to download the image with cache
    if [[ -f "$ZSYNC_CACHE_DIR/$IMAGE_NAME" ]]; then
        echo "Using cached image: $IMAGE_NAME"
    else
        echo "Downloading image: $IMAGE_NAME"
        zsync --cache-dir="$ZSYNC_CACHE_DIR" "$IMAGE_URL"
    fi
}

# Deploy image after checking if the target is properly mounted
deploy_image() {
    IMAGE_PATH="$DOWNLOAD_DIR/$IMAGE_NAME"
    DEPLOYMENT_DIR="/deployment/shared"
    TARGET_MOUNT="/mnt"
    ROOTLABEL="shani-root"

    if [[ -z "$IMAGE_PATH" ]]; then
        echo "Usage: $0 <path-to-image.btrfs>"
        exit 1
    fi

    if [[ ! -d "$DEPLOYMENT_DIR/roota" || ! -d "$DEPLOYMENT_DIR/rootb" ]]; then
        echo "Error: Both roota and rootb must exist."
        exit 1
    fi

    ACTIVE_ROOT=$(findmnt -n -o SOURCE / | grep -oE 'roota|rootb')
    TARGET_SUBVOL=$([[ "$ACTIVE_ROOT" == "roota" ]] && echo "rootb" || echo "roota")

    echo "Deploying to $TARGET_SUBVOL..."
    mkdir -p "$TARGET_MOUNT"
    mount -o subvol=$TARGET_SUBVOL "$DEPLOYMENT_DIR" "$TARGET_MOUNT"

    echo "Cleaning $TARGET_SUBVOL..."
    btrfs subvolume delete "$TARGET_MOUNT"/* || echo "Failed to clean target subvolume, skipping."

    echo "Deploying image..."
    btrfs receive "$TARGET_MOUNT" < "$IMAGE_PATH"

    echo "Unmounting $TARGET_SUBVOL..."
    umount -R "$TARGET_MOUNT"

    echo "Deployment complete!"
}

# Rollback function (optional: rollback to the previous root subvolume)
rollback() {
    echo "Rolling back to the previous root subvolume..."

    ACTIVE_ROOT=$(findmnt -n -o SOURCE / | grep -oE 'roota|rootb')
    TARGET_SUBVOL=$([[ "$ACTIVE_ROOT" == "roota" ]] && echo "rootb" || echo "roota")

    # Logic for switching back to the previous root subvolume
    echo "Rolling back to $TARGET_SUBVOL"
    mount -o subvol=$TARGET_SUBVOL "$WORKDIR" "$TARGET_MOUNT"
    umount -R "$TARGET_MOUNT"
    echo "Rollback complete!"
}

# Main function
main() {
    prepare_environment
    download_image
    deploy_image "$DOWNLOAD_DIR/$IMAGE_NAME"
}

# Run deployment
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
