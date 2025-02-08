#!/bin/bash

set -euo pipefail

# Configuration Variables
PROFILE=""
OUTPUT_DIR="./output"
BUILD_VERSION="$(date +%Y%m%d)"
ROOT_SUBVOL="shani_root"
BUILD_DIR="./cache/temp"
LOOP_DEVICE=""
IMAGE_FILE="$BUILD_DIR.img"

OSDN_URL="https://osdn.net/projects/your-project/releases/download"
REMOTE_USER="librewish"
REMOTE_HOST="frs.sourceforge.net"
REMOTE_DIR="/home/librewish/shanios/image/"
GPG_KEY_ID="your-gpg-key-id"

DEBUG=false
UPLOAD=false

# Logging Functions
log() { echo -e "[\e[1;32mINFO\e[0m] $1"; }
error() { echo -e "[\e[1;31mERROR\e[0m] $1" >&2; exit 1; }
debug() { $DEBUG && echo -e "[\e[1;34mDEBUG\e[0m] $1"; }

# Parse Arguments
while getopts "p:ud" opt; do
  case ${opt} in
    p) PROFILE=$OPTARG ;;
    u) UPLOAD=true ;;
    d) DEBUG=true ;;
    *) error "Usage: $0 -p <profile> [-u] [-d]";;
  esac
done

[[ -z "$PROFILE" ]] && error "Profile must be specified with -p"

PACMAN_CONFIG="./profiles/$PROFILE/pacman.conf"
IMAGE_NAME="shani-os-${BUILD_VERSION}-${PROFILE}.zst"
LATEST_FILE="$OUTPUT_DIR/latest.txt"

check_dependencies() {
  local deps=("btrfs" "pacstrap" "losetup" "mount" "umount" "arch-chroot" "rsync" "genfstab" "zsyncmake" "gpg" "sha256sum" "zstd")
  for tool in "${deps[@]}"; do
    command -v "$tool" &>/dev/null || error "$tool is required but not installed."
  done
}

cleanup() {
  log "Cleaning up..."

  # Unmount subvolumes first, then the main mountpoint
  if mountpoint -q "$BUILD_DIR/$ROOT_SUBVOL"; then
    log "Unmounting subvolume: $BUILD_DIR/$ROOT_SUBVOL..."
    umount "$BUILD_DIR/$ROOT_SUBVOL" || error "Failed to unmount $BUILD_DIR/$ROOT_SUBVOL"
  fi

  if mountpoint -q "$BUILD_DIR"; then
    log "Unmounting build directory: $BUILD_DIR..."
    umount "$BUILD_DIR" || error "Failed to unmount $BUILD_DIR"
  fi

  # Ensure no leftover mounts exist
  if mount | grep -q "$BUILD_DIR"; then
    log "Force unmounting all remaining mounts under $BUILD_DIR..."
    umount -l "$BUILD_DIR" || error "Failed to force unmount $BUILD_DIR"
  fi

  # Detach the loop device if it exists
  if [[ -n "${LOOP_DEVICE:-}" && -b "$LOOP_DEVICE" ]]; then
    log "Detaching loop device: $LOOP_DEVICE"
    losetup -d "$LOOP_DEVICE" || error "Failed to detach loop device $LOOP_DEVICE"
  fi

  # Ensure all loop devices associated with the image file are detached
  while read -r loopdev; do
    [[ -z "$loopdev" ]] && continue
    log "Force detaching $loopdev..."
    losetup -d "$loopdev" || error "Failed to detach loop device $loopdev"
  done < <(losetup -j "$IMAGE_FILE" | cut -d':' -f1 || true)

  # Kill any lingering processes using the directory
  log "Checking for active processes using $BUILD_DIR..."
  fuser -k "$BUILD_DIR" || log "No active processes found."

  # Remove image file and temporary directories
  [[ -f "$IMAGE_FILE" ]] && rm -f "$IMAGE_FILE"
  [[ -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
}



trap cleanup EXIT

setup_environment() {
  log "Setting up environment..."
  mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
  losetup -D  # Ensure no stale loop devices

  # Remove existing image file if it exists
  if [[ -f "$IMAGE_FILE" ]]; then
    log "Removing existing image file..."
    rm -f "$IMAGE_FILE"
  fi

  log "Creating Btrfs image..."
  fallocate -l 10G "$IMAGE_FILE"
  #dd if=/dev/zero of="$IMAGE_FILE" bs=1G count=10 status=progress
  mkfs.btrfs -f "$IMAGE_FILE"

  LOOP_DEVICE=$(losetup --find --show "$IMAGE_FILE")
  log "Using loop device: $LOOP_DEVICE"

  log "Mounting Btrfs filesystem..."
  mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$BUILD_DIR"

  log "Verifying Btrfs mount..."
  mount | grep "$BUILD_DIR" || error "Failed to mount Btrfs filesystem."

  if btrfs subvolume list "$BUILD_DIR" | grep -q "$ROOT_SUBVOL"; then
    log "Deleting existing subvolume..."
    btrfs subvolume delete "$BUILD_DIR/$ROOT_SUBVOL" || error "Failed to delete existing subvolume."
  fi

  log "Creating new subvolume: $ROOT_SUBVOL"
  btrfs subvolume create "$BUILD_DIR/$ROOT_SUBVOL" || error "Failed to create subvolume."

  sync  # Ensure changes are flushed to disk

  log "Remounting subvolume..."
  umount "$BUILD_DIR"
  mkdir -p "$BUILD_DIR/$ROOT_SUBVOL"
  mount -o subvol=$ROOT_SUBVOL,compress-force=zstd:19 "$LOOP_DEVICE" "$BUILD_DIR/$ROOT_SUBVOL"

  if ! mountpoint -q "$BUILD_DIR/$ROOT_SUBVOL"; then
    error "$BUILD_DIR/$ROOT_SUBVOL is not a mountpoint!"
  fi
}

install_base_system() {
  log "Installing base system..."
  local package_list="./profiles/$PROFILE/package-list.txt"

  [[ -f "$package_list" ]] || error "Missing package list for profile $PROFILE."

  pacstrap -cC "$PACMAN_CONFIG" "$BUILD_DIR/$ROOT_SUBVOL" $(< "$package_list") || error "pacstrap failed!"

  if [[ -d "./profiles/$PROFILE/overlay/rootfs" ]]; then
    cp -r ./profiles/$PROFILE/overlay/rootfs/* "$BUILD_DIR/$ROOT_SUBVOL/"
  fi

  if [[ -f "./profiles/$PROFILE/overlay/${PROFILE}-customizations.sh" ]]; then
    bash "./profiles/$PROFILE/overlay/${PROFILE}-customizations.sh" "$BUILD_DIR/$ROOT_SUBVOL"
  fi

  [[ -f "$BUILD_DIR/$ROOT_SUBVOL/bin/bash" ]] || error "chroot setup failed."

  arch-chroot "$BUILD_DIR/$ROOT_SUBVOL" /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
locale-gen
echo "shani-os" > /etc/hostname
EOF
}

finalize_build() {
  log "Finalizing build..."
  genfstab -U "$BUILD_DIR/$ROOT_SUBVOL" > "$BUILD_DIR/$ROOT_SUBVOL/etc/fstab"
  
  log "Setting subvolume as read-only..."
  btrfs property set -ts "$BUILD_DIR/$ROOT_SUBVOL" ro true || error "Failed to set subvolume read-only"
  
  log "Estimating subvolume size..."
  SUBVOL_SIZE=$(btrfs subvolume show "$BUILD_DIR/$ROOT_SUBVOL" | grep "Referenced" | awk '{print $2}')

  log "Compressing and storing snapshot..."
  btrfs send "$BUILD_DIR/${ROOT_SUBVOL}" | pv -s "$SUBVOL_SIZE" | zstd --ultra --long=31 -T0 -22 -v > "$OUTPUT_DIR/$IMAGE_NAME"
}

sign_image() {
  if gpg --list-keys "$GPG_KEY_ID" &>/dev/null; then
    log "Signing image..."
    gpg --default-key "$GPG_KEY_ID" --detach-sign --armor "$OUTPUT_DIR/$IMAGE_NAME"
  else
    error "GPG key not found. Cannot sign the image."
  fi
}

generate_checksums() {
  log "Generating SHA256 checksum..."
  sha256sum "$OUTPUT_DIR/$IMAGE_NAME" > "$OUTPUT_DIR/${IMAGE_NAME}.sha256"
}

generate_zsync_file() {
  log "Generating zsync file..."
  zsyncmake -o "$OUTPUT_DIR/${IMAGE_NAME}.zsync" "$OUTPUT_DIR/$IMAGE_NAME"
}

update_latest_file() {
  log "Updating latest.txt..."
  echo "$IMAGE_NAME" > "$LATEST_FILE"
}

upload_build() {
  log "Uploading build files..."
  rsync -avz --progress "$OUTPUT_DIR/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
}

main() {
  check_dependencies
  setup_environment
  install_base_system
  finalize_build
  sign_image
  generate_checksums
  generate_zsync_file
  update_latest_file

  [[ "$UPLOAD" == true ]] && upload_build
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

