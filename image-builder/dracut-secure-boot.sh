#!/bin/bash

# Check if the script is running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." 
    exit 1
fi

# Function to create Dracut configuration file
create_dracut_config() {
    local mok_key="/usr/share/secureboot/keys/MOK.key"
    local mok_cert="/usr/share/secureboot/keys/MOK.crt"
    local splash_image="/usr/share/systemd/bootctl/splash-arch.bmp"
    local uefi_stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    local dracut_conf_dir="/etc/dracut.conf.d"

    echo "Creating Dracut configuration at ${dracut_conf_dir}/shani.conf"

    if [[ ! -f "$mok_key" || ! -f "$mok_cert" || ! -f "$splash_image" ]]; then
        echo "Error: Missing required files." >&2
        return 1
    fi

    # Ensure the directory exists
    mkdir -p "$dracut_conf_dir"

    cat <<'EOF' > "${dracut_conf_dir}/shani.conf"
compress="zstd"
add_drivers+="i915 amdgpu xe radeon nouveau"
add_dracutmodules+="btrfs lvm mdraid crypt network plymouth uefi resume"
omit_dracutmodules+="brltty"
early_microcode=yes
use_fstab=yes
hostonly=yes
hostonly_cmdline=no
uefi=yes
uefi_secureboot_cert="$mok_cert"
uefi_secureboot_key="$mok_key"
uefi_splash_image="$splash_image"
uefi_stub="$uefi_stub"
resume='"/swapfile"'
EOF
}

# Function to get the UUID and encryption status
get_uuid_and_encryption() {
    # Get the root device from the mount information
    local root_device
    root_device=$(findmnt / -o SOURCE -n)

    # Check if the root device is part of LVM (i.e., /dev/mapper/)
    if [[ "$root_device" =~ /dev/mapper/ ]]; then
        # Check if it's a LUKS encrypted device using cryptsetup
        local luks_device
        luks_device=$(lsblk -no NAME,TYPE "$root_device" | grep -w "crypt" | awk '{print $1}')
        
        if [[ -n "$luks_device" ]]; then
            # If it's a LUKS device, get the LUKS UUID
            local luks_uuid
            luks_uuid=$(cryptsetup luksUUID "/dev/$luks_device")
            echo "$luks_uuid" "luks"
        else
            # If it's LVM but not encrypted, treat it as a plain LVM device
            # Use blkid to get the UUID of the LVM device
            local lvm_uuid
            lvm_uuid=$(blkid "$root_device" | awk -F'UUID=' '{ print $2 }' | awk '{ print $1 }' | tr -d '"')
            echo "$lvm_uuid" "lvm"
        fi
    else
        # For non-LVM, non-LUKS devices, just directly get the UUID
        local uuid
        uuid=$(blkid "$root_device" | awk -F'UUID=' '{ print $2 }' | awk '{ print $1 }' | tr -d '"')
        echo "$uuid" "plain"
    fi
}



# Function to generate kernel command line
generate_cmdline() {
    local root_name="$1"
    local subvol="$2"
    local uuid_and_encryption
    uuid_and_encryption=$(get_uuid_and_encryption)
    local uuid
    uuid=$(echo "$uuid_and_encryption" | awk '{ print $1 }')
    local encryption_type
    encryption_type=$(echo "$uuid_and_encryption" | awk '{ print $2 }')

    local cmdline="quiet splash root=UUID=${uuid} ro rootflags=subvol=${subvol},ro"

    if [[ "$encryption_type" == "luks" ]]; then
        # For LUKS, add rd.luks.uuid and other necessary options
        cmdline+=" rd.luks.uuid=${uuid} rd.luks.options=${uuid}=tpm2-device=auto"
    elif [[ "$encryption_type" == "lvm" ]]; then
        # For LVM, append the LVM logical volume (lv) configuration
        cmdline+=" rd.lvm.lv=${uuid}"
    fi

    # Ensure the dracut config directory exists
    mkdir -p "/etc/dracut.conf.d"
    echo "kernel_cmdline=\"${cmdline}\"" | tee "/etc/dracut.conf.d/dracut-cmdline-${root_name}.conf" > /dev/null
}

# Function to generate UEFI image
generate_uefi_image() {
    local root_name="$1"
    local subvol="$2"
    local image_name="shanios-${root_name,,}.efi"
    local cmdline
    local efi_path="/boot/efi/EFI/Linux"

    cmdline=$(bash -c "source /etc/dracut.conf.d/dracut-cmdline-${root_name}.conf && echo \$kernel_cmdline")

    # Ensure the EFI path exists
    mkdir -p "$efi_path"

    dracut -q -f --uefi --cmdline "${cmdline}" "$efi_path/${image_name}"
}

# Function to install the systemd-boot bootloader
install_bootloader() {
    local mok_key="/usr/share/secureboot/keys/MOK.key"
    local mok_cert="/usr/share/secureboot/keys/MOK.crt"
    local mok_cer="/usr/share/secureboot/keys/MOK.cer"
    local efi_path

    # Ensure bootloader directory exists
    mkdir -p /boot/loader

    # Create loader.conf
    cat <<'EOF' > /boot/loader/loader.conf
default shanios-roota.efi
timeout 5
console-mode max
EOF

    bootctl install

    efi_path=$(bootctl -p)
    BOOT_LOADER_EFI="${efi_path}/EFI/systemd/systemd-bootx64.efi"
    SHIM_TARGET_EFI="${efi_path}/EFI/BOOT/grubx64.efi"

    if diff -q "$BOOT_LOADER_EFI" "$SHIM_TARGET_EFI"; then
        echo 'info: no changes, nothing to do'
        exit 0
    fi

    cp "$BOOT_LOADER_EFI" "$SHIM_TARGET_EFI"
    cp /usr/share/shim-signed/{shim,mm}x64.efi "$efi_path"
    cp "$mok_cer" "$efi_path"

    if [[ -f "${efi_path}/EFI/BOOT/grubx64.efi" ]]; then
        sbsign --key "$mok_key" --cert "$mok_cert" --output "${efi_path}/EFI/BOOT/grubx64.efi" "${efi_path}/EFI/BOOT/grubx64.efi"
    fi

    efi_binaries=("EFI/Linux/shanios-roota.efi" "EFI/Linux/shanios-rootb.efi")

    for efi_binary in "${efi_binaries[@]}"; do
        sbsign --key "$mok_key" --cert "$mok_cert" --output "$efi_path/$efi_binary" "$efi_path/$efi_binary"
    done

    mokutil --import "$mok_cer"
    mokutil --disable-validation
}

# Function to remove UEFI images
remove_uefi_images() {
    local efi_path
    local images=("shanios-roota.efi" "shanios-rootb.efi")

    efi_path=$(bootctl -p)

    for image in "${images[@]}"; do
        if [[ -e "${efi_path}/EFI/Linux/${image}" ]]; then
            rm -f "${efi_path}/EFI/Linux/${image}"
            echo "Removed: ${image}"
        else
            echo "Image not found: ${image}"
        fi
    done
}

# Function to create initramfs with dracut
create_initramfs() {
    generate_uefi_image "roota" "deployment/shared/roota"
    generate_uefi_image "rootb" "deployment/shared/rootb"
}

# Main logic to handle function execution based on arguments
case "$1" in
    create_dracut_config)
        create_dracut_config
        ;;
    get_uuid_and_encryption)
        get_uuid_and_encryption
        ;;
    generate_cmdline)
        if [[ -z "$2" || -z "$3" ]]; then
            echo "Usage: $0 generate_cmdline <root_name> <subvol>"
            exit 1
        fi
        generate_cmdline "$2" "$3"
        ;;
    generate_uefi_image)
        if [[ -z "$2" || -z "$3" ]]; then
            echo "Usage: $0 generate_uefi_image <root_name> <subvol>"
            exit 1
        fi
        generate_uefi_image "$2" "$3"
        ;;
    install_bootloader)
        install_bootloader
        ;;
    remove_uefi_images)
        remove_uefi_images
        ;;
    create_initramfs)
        create_initramfs
        ;;
    *)
        echo "Usage: $0 {create_dracut_config|get_uuid_and_encryption|generate_cmdline|generate_uefi_image|install_bootloader|remove_uefi_images|create_initramfs}"
        exit 1
        ;;
esac

