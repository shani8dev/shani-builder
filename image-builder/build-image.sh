#!/bin/bash

set -euo pipefail

# Configuration variables
PROFILE=""
OUTPUT_DIR="./output"
VERSION="$(date +%Y%m%d)"
ROOTLABEL="shani-root"
WORK_DIR="./cache/temp"
TARGET_SUBVOL="roota"
IMAGE_NAME=""

# OSDN & SSH Details for upload
OSDN_URL="https://osdn.net/projects/your-project/releases/download"
FILE_NAME="your-file.btrfs"
OSDN_FILE_URL="${OSDN_URL}/${FILE_NAME}"
SERVER_USER="your-username"
SERVER_HOST="your-server.com"
REMOTE_PATH="/path/to/your-server/zsync-files"

# Parse command-line arguments
while getopts "p:u" opt; do
  case ${opt} in
    p)
      PROFILE=$OPTARG
      ;;
    u)
      UPLOAD=true
      ;;
    *)
      echo "Usage: $0 -p <profile> [-u]"
      exit 1
      ;;
  esac
done

# Validate profile argument
if [[ -z "$PROFILE" ]]; then
  echo "Error: Profile must be specified with -p"
  exit 1
fi

PACMAN_CONF="./profiles/$PROFILE/pacman.conf"
IMAGE_NAME="shani-os-${VERSION}-${PROFILE}.btrfs"

# Check for required tools
check_tools() {
  for tool in btrfs pacstrap; do
    if ! command -v "$tool" >/dev/null; then
      echo "Error: $tool is required but not installed."
      exit 1
    fi
  done
}

# Prepare the environment: Create necessary directories, subvolumes, and mounts
prepare_environment() {
  echo "Preparing environment in $WORK_DIR..."
  mkdir -p "$WORK_DIR"
  
  # Ensure the working directory is on a btrfs filesystem
  if ! stat -f --format=%T "$WORK_DIR" | grep -q btrfs; then
    echo "The working directory is not on a btrfs filesystem. Creating a btrfs loopback device..."
    dd if=/dev/zero of="$WORK_DIR.img" bs=1G count=5
    mkfs.btrfs "$WORK_DIR.img"
    mount -o loop "$WORK_DIR.img" "$WORK_DIR"
  fi

  mkdir -p "$WORK_DIR/mnt"
  if ! btrfs subvolume list "$WORK_DIR" | grep -q "$TARGET_SUBVOL"; then
    btrfs subvolume create "$WORK_DIR/$TARGET_SUBVOL"
  fi
  mount -o compress=zstd "$WORK_DIR/$TARGET_SUBVOL" "$WORK_DIR/mnt"
}

# Install the base system and apply profile-specific configurations
build_system() {
  echo "Building system..."
  pacstrap -C "$PACMAN_CONF" "$WORK_DIR/mnt" $(< "./profiles/$PROFILE/package-list.txt")
  
  # Apply overlay files if they exist
  if [[ -d "./profiles/$PROFILE/overlay/rootfs" ]]; then
    cp -r ./profiles/$PROFILE/overlay/rootfs/* "$WORK_DIR/mnt/"
    chown -R root:root "$WORK_DIR/mnt/*"
  fi

  # Run profile-specific customizations if they exist
  if [[ -f "./profiles/$PROFILE/overlay/${PROFILE}-customizations.sh" ]]; then
    bash "./profiles/$PROFILE/overlay/${PROFILE}-customizations.sh" "$WORK_DIR/mnt"
  fi

  # Configure the system inside chroot
  arch-chroot "$WORK_DIR/mnt" /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
locale-gen
echo "shani-os" > /etc/hostname
EOF
}

# Finalize the image creation
finalize_image() {
  echo "Finalizing image..."
  genfstab -U "$WORK_DIR/mnt" > "$WORK_DIR/mnt/etc/fstab"
  umount -R "$WORK_DIR/mnt"
  btrfs filesystem defragment -czstd "$IMAGE_FILE"
  btrfs subvolume snapshot "$WORK_DIR/$TARGET_SUBVOL" "$WORK_DIR/snapshot"
  btrfs send "$WORK_DIR/snapshot" > "$OUTPUT_DIR/$IMAGE_NAME"
}

# Cleanup temporary files
cleanup() {
  echo "Cleaning up..."
  btrfs subvolume delete "$WORK_DIR/$TARGET_SUBVOL" || true
  btrfs subvolume delete "$WORK_DIR/snapshot" || true
  umount -R "$WORK_DIR" || true
  rm -rf "$WORK_DIR/mnt" "$WORK_DIR.img"
}

# Generate zsync file
generate_zsync() {
  echo "Generating zsync file..."
  zsyncmake -o "$OUTPUT_DIR/${IMAGE_NAME}.zsync" "$OUTPUT_DIR/$IMAGE_NAME"
}

# Upload files
upload_files() {
  echo "Uploading files..."
  rsync -avz "$OUTPUT_DIR/${IMAGE_NAME}.zsync" "${SERVER_USER}@${SERVER_HOST}:${REMOTE_PATH}/"
  rsync -avz "$OUTPUT_DIR/$IMAGE_NAME" "${SERVER_USER}@${SERVER_HOST}:${REMOTE_PATH}/"
}

# Print final message
final_message() {
  echo "Build complete. You can now download the image using zsync:"
  echo "zsync ${SERVER_HOST}:${REMOTE_PATH}/${IMAGE_NAME}.zsync"
}

# Main function
main() {
  check_tools
  prepare_environment
  build_system
  finalize_image
  cleanup
  generate_zsync

  if [[ "${UPLOAD:-}" == true ]]; then
    upload_files
    final_message
  else
    echo "Build complete. To upload, use the -u flag."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
