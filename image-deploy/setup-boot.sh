#!/bin/bash -e

# Define paths for the files
SHANI_BOOT_DIR="/usr/lib/shani-boot"
EFI_BOOT_DIR="/boot/efi/EFI/BOOT"
BOOT_ENTRY_DIR="/boot/efi/EFI/loader/entries"  # Fixed the path for systemd-boot entries
SHIM_BINARY="/usr/share/shim-signed/shimx64.efi"   # Path to the shim binary
MOK_MANAGER="/usr/share/shim-signed/mmx64.efi"     # Path to the MOK manager binary
MOK_DER="/usr/share/secureboot/keys/MOK.der"          # Path to the MOK DER certificate
SYSTEMD_BOOT="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"  # Path to systemd-boot binary
FWUPD_EFI="/usr/lib/fwupd/efi/fwupdx64.efi"   # Path to fwupd EFI binary
KERNEL_IMAGE="vmlinuz"
INITRAMFS_IMAGE="initramfs.img"
INITRAMFS_FALLBACK_IMAGE="initramfs-fallback.img"

# Ensure necessary directories exist
mkdir -p "$EFI_BOOT_DIR"
mkdir -p "$BOOT_ENTRY_DIR"

# Helper function to install files with check for existence
install_file() {
    local source_file="$1"
    local destination_file="$2"
    
    if [[ ! -f "$source_file" ]]; then
        echo "❌ Error: $source_file not found."
        exit 1
    fi

    install -m0644 "$source_file" "$destination_file"
    echo "✅ Installed $source_file to $destination_file"
}

# Install shim, MOK manager, and MOK certificate to the boot directory
install_shim_and_mok() {
    echo "🔄 Installing shim, MOK manager, and MOK certificate..."
    
    install_file "$SHIM_BINARY" "$EFI_BOOT_DIR/BOOTX64.EFI"
    install_file "$MOK_MANAGER" "$EFI_BOOT_DIR/mmx64.efi"
    install_file "$MOK_DER" "$EFI_BOOT_DIR/MOK.der"
}

# Copy bootloader and kernel/initramfs images to EFI
copy_files_to_efi() {
    echo "🔄 Copying bootloader and kernel/initramfs files to EFI..."
    
    # Install systemd-boot and kernel/initramfs images
    install_file "$SYSTEMD_BOOT" "$EFI_BOOT_DIR/systemd-bootx64.efi"
    install_file "$SHANI_BOOT_DIR/$KERNEL_IMAGE" "$EFI_BOOT_DIR/$KERNEL_IMAGE"
    install_file "$SHANI_BOOT_DIR/$INITRAMFS_IMAGE" "$EFI_BOOT_DIR/$INITRAMFS_IMAGE"
    install_file "$SHANI_BOOT_DIR/$INITRAMFS_FALLBACK_IMAGE" "$EFI_BOOT_DIR/$INITRAMFS_FALLBACK_IMAGE"
}

# Install fwupd EFI binary for firmware updates
install_fwupd() {
    echo "🔄 Installing fwupd EFI binary..."
    install_file "$FWUPD_EFI" "$EFI_BOOT_DIR/fwupdx64.efi"
}

# Get root filesystem UUID and encryption type (if any)
get_root_info() {
    local root_device
    root_device=$(findmnt -n -o SOURCE /)
    local uuid encryption

    if [[ "$root_device" =~ /dev/mapper/ ]]; then
        # For encrypted LUKS devices
        if uuid=$(cryptsetup luksUUID "$root_device" 2>/dev/null); then
            encryption="luks"
        else
            uuid=$(blkid -s UUID -o value "$root_device")
            encryption="lvm"
        fi
    else
        uuid=$(blkid -s UUID -o value "$root_device")
        encryption="plain"
    fi
    echo "$uuid $encryption"
}

# Generate Unified Kernel Image (UKI) for Secure Boot
generate_cmdline() {
    local subvol="$1"
    read -r uuid encryption <<< "$(get_root_info)"
    
    local cmdline="quiet splash root=UUID=${uuid} ro rootflags=subvol=${subvol},ro"
    
    # Add options for encrypted disks if applicable
    if [[ "$encryption" == "luks" ]]; then
        cmdline+=" rd.luks.uuid=${uuid} rd.luks.options=${uuid}=tpm2-device=auto"
    fi

    # Add swapfile resume option if available
    if [[ -f "/swapfile" ]]; then
        cmdline+=" resume=UUID=$(findmnt -no UUID /) resume_offset=$(filefrag -v "/swapfile" 2>/dev/null | awk 'NR==4 {print $4}' | sed 's/\.$//')"
    fi

    echo "$cmdline"
}

# Create systemd-boot entry for both Root A and Root B
create_systemd_boot_entry() {
    echo "🔧 Creating systemd-boot entry..."

    local cmdline_root_a=$(generate_cmdline "deployment/shared/roota")
    local cmdline_root_b=$(generate_cmdline "deployment/shared/rootb")

    # Check if the entries already exist before creating new ones
    if [[ -f "$BOOT_ENTRY_DIR/shani-os-roota.conf" && -f "$BOOT_ENTRY_DIR/shani-os-rootb.conf" ]]; then
        echo "info: systemd-boot entries already exist, nothing to do"
        return 0
    fi

    # Ensure the files are properly created in the bootloader entries
    cat <<EOF > "$BOOT_ENTRY_DIR/shani-os-roota.conf"
title   Shani OS (Root A)
linux   /$KERNEL_IMAGE
initrd  /$INITRAMFS_IMAGE
options $cmdline_root_a
EOF

    cat <<EOF > "$BOOT_ENTRY_DIR/shani-os-rootb.conf"
title   Shani OS (Root B)
linux   /$KERNEL_IMAGE
initrd  /$INITRAMFS_IMAGE
options $cmdline_root_b
EOF

    echo "✅ Created systemd-boot entries."
}

# Main execution
install_shim_and_mok
copy_files_to_efi
install_fwupd
create_systemd_boot_entry

echo "✅ Systemd-boot entry and boot files for Secure Boot setup have been completed."

