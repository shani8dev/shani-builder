#!/bin/bash
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root."
    exit 1
fi

# Configuration Variables
SECUREBOOT_DIR="/usr/share/secureboot/keys"
ESP=$(findmnt -no TARGET /boot/efi 2>/dev/null || findmnt -no TARGET /efi 2>/dev/null || echo "/boot/efi")
EFI_DIR="$ESP/EFI/shanios"
BOOT_DIR="$ESP/EFI/BOOT"
MOK_KEY="$SECUREBOOT_DIR/MOK.key"
MOK_CRT="$SECUREBOOT_DIR/MOK.crt"
MOK_DER="$SECUREBOOT_DIR/MOK.der"
SYSTEMD_BOOT="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
SHIM_BINARY="/usr/share/shim-signed/shimx64.efi"
MOK_MANAGER="/usr/share/shim-signed/mmx64.efi"
FWUPD_EFI="/usr/lib/fwupd/efi/fwupdx64.efi"

# Ensure required directories exist
ensure_directories() {
    for dir in "$SECUREBOOT_DIR" "$EFI_DIR" "$BOOT_DIR"; do
        [[ ! -d "$dir" ]] && mkdir -p "$dir" && echo "Created directory: $dir"
    done
}

# Check if required files are present
check_required_files() {
    local files=("$SYSTEMD_BOOT" "$SHIM_BINARY" "$MOK_MANAGER")
    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo "❌ Missing required file: $file. Ensure packages are installed."
            exit 1
        fi
    done
}

# Generate MOK keys if they don't exist
generate_keys() {
    if [[ ! -f "$MOK_KEY" || ! -f "$MOK_CRT" ]]; then
        echo "🔑 Generating new MOK keys..."
        openssl req -newkey rsa:4096 -nodes -keyout "$MOK_KEY" \
            -new -x509 -sha256 -days 3650 -out "$MOK_CRT" \
            -subj "/CN=Shani OS Secure Boot Key/"
        openssl x509 -in "$MOK_CRT" -outform DER -out "$MOK_DER"
    else
        echo "🔑 Using existing MOK keys..."
    fi
}

# Sign a file (EFI binary or kernel module)
sign_files() {
    local file="$1"
    local signed_file="${file}.signed"
    
    echo "🔏 Signing ${file}..."
    if ! sbsign --key "$MOK_KEY" --cert "$MOK_CRT" --output "$signed_file" "$file"; then
        echo "❌ Failed to sign ${file}."
        exit 1
    fi
    mv -f "$signed_file" "$file"
}

# Sign all kernel modules for the current kernel
sign_kernel_modules() {
    echo "🔏 Signing kernel modules..."
    find /usr/lib/modules/"$(uname -r)" -type f -name '*.ko*' -exec sign_files {} \;
}

# Enroll MOK key if not already enrolled
enroll_mok() {
    if mokutil --test-key "$MOK_DER" &>/dev/null; then
        echo "✅ MOK key already enrolled."
    else
        echo "🔑 Enrolling MOK key..."
        if mokutil --import "$MOK_DER" --root-pw; then
            echo -e "\n⚠️ REBOOT REQUIRED! Complete enrollment via the UEFI boot menu."
        else
            echo "❌ Failed to enroll MOK key."
            exit 1
        fi
    fi
}

# Bypass MOK prompt on reboot (if already enrolled)
bypass_mok_prompt() {
    echo "Bypassing MOK prompt on reboot..."
    if [[ -f "$MOK_CRT" ]]; then
        local mok_der_temp="${MOK_CRT}.der"
        openssl x509 -in "$MOK_CRT" -outform DER -out "$mok_der_temp"
        if efivar -n MOKList -w -d "$mok_der_temp"; then
            echo "✅ MOK prompt bypassed."
        else
            echo "❌ Failed to bypass MOK prompt."
        fi
        rm -f "$mok_der_temp"
    else
        echo "⚠️ MOK certificate not found. Skipping MOK prompt bypass."
    fi

    # Disable Secure Boot validation if required
    echo "🚫 Disabling Secure Boot validation..."
    if mokutil --disable-validation; then
        echo -e "\n⚠️ REBOOT REQUIRED! Complete the process in MokManager on next boot."
    else
        echo "❌ Failed to disable Secure Boot validation." >&2
        exit 1
    fi
}

# Get root filesystem UUID and encryption type (if any)
get_root_info() {
    local root_device
    root_device=$(findmnt -n -o SOURCE /)
    local uuid encryption

    if [[ "$root_device" =~ /dev/mapper/ ]]; then
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
generate_uki() {
    local subvol="$1"
    read -r uuid encryption <<< "$(get_root_info)"
    
    local cmdline="quiet splash root=UUID=${uuid} ro rootflags=subvol=${subvol},ro"
    [[ "$encryption" == "luks" ]] && cmdline+=" rd.luks.uuid=${uuid} rd.luks.options=${uuid}=tpm2-device=auto"
    
    [[ -f "/swapfile" ]] && cmdline+=" resume=UUID=$(findmnt -no UUID /) resume_offset=$(filefrag -v "/swapfile" 2>/dev/null | awk 'NR==4 {print $4}' | sed 's/\.$//')"
    
    local uki_path="$EFI_DIR/shanios-${subvol}.efi"
    echo "🔧 Generating UKI: ${uki_path}"
    dracut --force --uefi --kver "$(uname -r)" --cmdline "$cmdline" "$uki_path"
    sign_files "$uki_path"
}

# Install Secure Boot loader components (Shim, systemd-boot, FWUPD and MEMTEST EFI binaries)
install_secureboot_loader() {
    echo "🚀 Installing Secure Boot components..."
    
    # Install Shim, MokManager, and MOK DER key
    install -Dm0644 "$SHIM_BINARY" "$BOOT_DIR/BOOTX64.EFI"
    install -m0644 "$MOK_MANAGER" "$BOOT_DIR/mmx64.efi"
    install -m0644 "$MOK_DER" "$BOOT_DIR/MOK.der"
    
    # Install systemd bootloader
    install -m0644 "$SYSTEMD_BOOT" "$BOOT_DIR/grubx64.efi"
    sign_files "$BOOT_DIR/grubx64.efi"

    # Install FWUPD EFI if it exists
    [[ -f "$FWUPD_EFI" ]] && install -m0644 "$FWUPD_EFI" "$BOOT_DIR/fwupdx64.efi" && sign_files "$BOOT_DIR/fwupdx64.efi"

}

# Main function to process command-line arguments and execute steps
main() {
    ensure_directories
    check_required_files

    case "${1:-}" in
        configure)
            if [[ -z "${2:-}" ]]; then
                echo "❌ Missing subvolume name. Usage: $0 configure <subvol>"
                exit 1
            fi
            generate_keys
            generate_uki "$2"
            sign_kernel_modules
            install_secureboot_loader
            enroll_mok
            bypass_mok_prompt
            echo -e "\n✅ Secure Boot setup complete! Reboot to enroll the MOK key."
            ;;
        *)
            echo "Usage: $0 configure <subvol>"
            exit 1
            ;;
    esac
}

main "$@"

