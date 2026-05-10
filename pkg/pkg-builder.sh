#!/bin/bash
# pkg-builder.sh — Build, sign, and publish Shani OS custom packages to shani-repo.
#
# Credentials are read exclusively from environment variables:
#   SSH_PRIVATE_KEY  — ED25519/RSA private key with write access to both repos
#   GPG_PASSPHRASE   — Passphrase for the GPG signing key
#   GPG_PRIVATE_KEY  — Armored GPG private key for package signing
#
# Never pass secrets as positional arguments — they appear in ps aux output.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PKGBUILD_REPO_URL="git@github.com:shani8dev/shani-pkgbuilds.git"
readonly PUBLIC_REPO_URL="git@github.com:shani8dev/shani-repo.git"
readonly BUILDER_IMAGE="shrinivasvkumbhar/shani-builder:latest"

# Credentials — read exclusively from environment variables.
readonly SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
readonly GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
readonly GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY:-}"

# Temp files live in /tmp — never inside any repo directory.
# Declare and assign separately so mktemp failures are not masked by readonly.
SSH_DIR="$(mktemp -d /tmp/shani-ssh-XXXXXX)"
readonly SSH_DIR
GPG_KEY_FILE="$(mktemp /tmp/shani-gpg-XXXXXX.asc)"
readonly GPG_KEY_FILE

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit, even on error
# ---------------------------------------------------------------------------
cleanup() {
    command -v shred &>/dev/null \
        && shred -u "${GPG_KEY_FILE}" 2>/dev/null \
        || rm -f "${GPG_KEY_FILE}"
    rm -rf "${SSH_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
for var in SSH_PRIVATE_KEY GPG_PASSPHRASE GPG_PRIVATE_KEY; do
    if [[ -z "${!var}" ]]; then
        echo "Error: ${var} is not set." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Architecture -> repo subdirectory
# Do NOT declare ARCH as readonly — sudo may inherit it as readonly from the
# runner environment, causing "readonly variable" errors on reassignment.
# ---------------------------------------------------------------------------
_ARCH="$(uname -m)"
case "$_ARCH" in
    x86_64)         readonly ARCH_DIR="./shani-repo/x86_64" ;;
    armv7l|aarch64) readonly ARCH_DIR="./shani-repo/arm"    ;;
    *) echo "Unsupported architecture: ${_ARCH}" >&2; exit 1 ;;
esac
unset _ARCH

# ---------------------------------------------------------------------------
# Docker — already present on GitHub runners; safety net for local use
# ---------------------------------------------------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker is already installed."
        return 0
    fi
    log "Docker not found, installing..."
    if [[ ! -f /etc/os-release ]]; then
        log "Error: Unknown OS, cannot install Docker." >&2; exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        ubuntu|debian)      apt-get update -qq && apt-get install -y docker.io ;;
        arch)               pacman -S --noconfirm docker ;;
        fedora|centos|rhel) dnf install -y docker ;;
        *) log "Error: Unsupported OS for Docker installation." >&2; exit 1 ;;
    esac
    log "Docker installed successfully."
}

# ---------------------------------------------------------------------------
# SSH setup — key written to /tmp, never into any repo directory
# ---------------------------------------------------------------------------
setup_ssh() {
    log "Setting up SSH..."
    local key_file="${SSH_DIR}/id_rsa"
    printf '%s\n' "$SSH_PRIVATE_KEY" | tr -d '\r' > "${key_file}"
    chmod 600 "${key_file}"
    cat > "${SSH_DIR}/config" <<EOF
Host github.com
  IdentityFile ${key_file}
  StrictHostKeyChecking no
  BatchMode yes
EOF
    chmod 600 "${SSH_DIR}/config"
    export GIT_SSH_COMMAND="ssh -F ${SSH_DIR}/config"
}

# ---------------------------------------------------------------------------
# Clone or hard-reset a repo to match its remote main branch
# ---------------------------------------------------------------------------
clone_or_update_repo() {
    local repo_url="$1"
    local dir_name="$2"

    if [[ -d "${dir_name}" ]]; then
        log "${dir_name} exists — resetting to remote main..."
        git -C "${dir_name}" fetch origin
        git -C "${dir_name}" reset --hard origin/main
        git -C "${dir_name}" clean -fdx
    else
        log "Cloning ${dir_name}..."
        git clone "${repo_url}" "${dir_name}"
    fi
}

# ---------------------------------------------------------------------------
# Remove stale package files whose version no longer matches any PKGBUILD.
# Sources each PKGBUILD in a subshell to avoid polluting this shell's env.
# ---------------------------------------------------------------------------
cleanup_old_versions() {
    local arch_dir="$1"
    [[ -d "${arch_dir}" ]] || return 0

    log "Scanning for stale package versions in ${arch_dir}..."

    local -A current_packages=()
    for pkgbuild_dir in shani-pkgbuilds/*/; do
        [[ -f "${pkgbuild_dir}/PKGBUILD" ]] || continue
        local entry
        entry=$(bash -c '
            source "'"${pkgbuild_dir}"'/PKGBUILD"
            for pn in "${pkgname[@]}"; do
                for pa in "${arch[@]}"; do
                    echo "${pn}-${pkgver}-${pkgrel}-${pa}"
                done
            done
        ')
        while IFS= read -r line; do
            [[ -n "$line" ]] && current_packages["$line"]=1
        done <<< "$entry"
    done

    for file in "${arch_dir}"/*.pkg.tar.zst "${arch_dir}"/*.pkg.tar.zst.sig; do
        [[ -e "$file" ]] || continue
        local base="${file%.sig}"
        base="${base%.pkg.tar.zst}"
        local fname
        fname="$(basename "$base")"
        if [[ -z "${current_packages[$fname]+x}" ]]; then
            log "Removing stale file: ${file}"
            rm -f "${file}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Build a single package inside the shani-builder container.
#
# The docker bash -c string is double-quoted so that $GPG_PASSPHRASE,
# $PKGBUILD_DIR, $PKG_FILE, and $GPG_PRIVATE_KEY expand HERE in the outer
# shell before docker runs — they are baked into the command string.
# This is exactly how the old working script injected secrets and is why
# su - (which strips the environment) is not a problem.
#
# GPG sign uses a binary detached sig — NO --armor.
# pacman and repo-add both reject ASCII-armored .sig files.
# ---------------------------------------------------------------------------
build_package() {
    local pkgbuild_dir="$1"
    local pkgbuild_dir_clean="${pkgbuild_dir%/}"

    # Read PKGBUILD metadata in a subshell — does not pollute this shell's env.
    # Falls back to scalar syntax for PKGBUILDs that don't use arrays.
    local pkgname pkgver pkgrel pkg_arch
    eval "$(bash -c '
        source "'"${pkgbuild_dir}"'/PKGBUILD"
        echo "pkgname=${pkgname[0]:-${pkgname}}"
        echo "pkgver=${pkgver}"
        echo "pkgrel=${pkgrel}"
        echo "pkg_arch=${arch[0]:-${arch}}"
    ')"

    local pkg_file="${pkgname}-${pkgver}-${pkgrel}-${pkg_arch}.pkg.tar.zst"
    local pkg_sig="${pkg_file}.sig"

    # Skip if both package and signature already exist in the repo.
    if [[ -f "${ARCH_DIR}/${pkg_file}" && -f "${ARCH_DIR}/${pkg_sig}" ]]; then
        log "Package ${pkg_file} already exists — skipping build."
        return 0
    fi

    log "Building: ${pkgname} ${pkgver}-${pkgrel}"

    # Write GPG private key to temp file — bind-mounted into the container.
    printf '%s\n' "$GPG_PRIVATE_KEY" > "${GPG_KEY_FILE}"
    chmod 644 "${GPG_KEY_FILE}"

    # The outer shell expands $GPG_PASSPHRASE, $pkgbuild_dir_clean, and
    # $pkg_file into the string before docker runs, so su - never needs to
    # propagate them. Inner escaped quotes \" delimit su - builduser -c "...".
    docker run --rm \
        -v "$(pwd):/pkg" \
        -v "${GPG_KEY_FILE}:/home/builduser/.gnupg/temp-private.asc" \
        -e PKGBUILD_DIR="${pkgbuild_dir_clean}" \
        -e GPG_PASSPHRASE="${GPG_PASSPHRASE}" \
        -e PKG_FILE="${pkg_file}" \
        "${BUILDER_IMAGE}" bash -c "
            set -euo pipefail

            # Refresh pacman db and ensure git is available for makepkg --syncdeps.
            pacman -Sy --noconfirm git || { echo 'pacman -Sy failed'; exit 1; }

            # builduser must own /pkg to write build artifacts.
            chown -R builduser:builduser /pkg

            # GPG refuses to run if ~/.gnupg is missing or not chmod 700.
            mkdir -p /home/builduser/.gnupg
            chown -R builduser:builduser /home/builduser
            chmod 700 /home/builduser/.gnupg

            su - builduser -c \"
                export GNUPGHOME=/home/builduser/.gnupg

                # Import GPG key — passphrase piped via stdin.
                echo '${GPG_PASSPHRASE}' | gpg --batch --pinentry-mode loopback \\
                    --passphrase-fd 0 \\
                    --import /home/builduser/.gnupg/temp-private.asc \\
                    || { echo 'GPG import failed'; exit 1; }

                cd /pkg/${pkgbuild_dir_clean} || { echo 'cd failed'; exit 1; }

                makepkg -sc --noconfirm \\
                    || { echo 'makepkg failed for ${pkgbuild_dir_clean}'; exit 1; }

                # Sign — binary detached sig, NO --armor (pacman rejects ASCII sigs).
                echo '${GPG_PASSPHRASE}' | gpg --batch --pinentry-mode loopback \\
                    --passphrase-fd 0 \\
                    --detach-sign \\
                    --output '${pkg_file}.sig' \\
                    '${pkg_file}' \\
                    || { echo 'GPG sign failed for ${pkg_file}'; exit 1; }
            \"
        "

    # Move built artifacts into the public repo directory.
    local built=false
    for artifact in "${pkg_file}" "${pkg_sig}"; do
        if [[ -f "${pkgbuild_dir_clean}/${artifact}" ]]; then
            mv "${pkgbuild_dir_clean}/${artifact}" "${ARCH_DIR}/"
            built=true
        else
            log "Warning: expected artifact not found: ${pkgbuild_dir_clean}/${artifact}"
        fi
    done

    # Clean up makepkg work directories.
    rm -rf "${pkgbuild_dir_clean}/pkg" "${pkgbuild_dir_clean}/src"

    if [[ "$built" == false ]]; then
        log "Error: no artifacts produced for ${pkgname}" >&2
        return 1
    fi

    PACKAGES_NEEDING_DB_UPDATE+=("${ARCH_DIR}/${pkg_file}")
    return 0
}

# ---------------------------------------------------------------------------
# Rebuild the pacman repo database from all packages currently in ARCH_DIR.
# Called once after all builds complete — not incrementally per-package.
# ---------------------------------------------------------------------------
rebuild_database() {
    local arch_dir="$1"

    log "Rebuilding package database in ${arch_dir}..."

    local pkg_count
    pkg_count=$(find "${arch_dir}" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l)
    if [[ "$pkg_count" -eq 0 ]]; then
        log "No packages found in ${arch_dir} — skipping database rebuild."
        return 0
    fi

    docker run --rm \
        -v "$(realpath "${arch_dir}"):/repo" \
        "${BUILDER_IMAGE}" bash -c '
            set -euo pipefail
            cd /repo
            rm -f shani.db shani.db.tar.gz shani.db.tar.gz.old \
                  shani.files shani.files.tar.gz shani.files.tar.gz.old
            repo-add shani.db.tar.gz *.pkg.tar.zst
            cp shani.db.tar.gz shani.db
            cp shani.files.tar.gz shani.files
        '

    log "Database rebuilt successfully."
}

# ---------------------------------------------------------------------------
# Commit and push changes back to shani-repo
# ---------------------------------------------------------------------------
commit_and_push() {
    local repo_dir="$1"
    local commit_msg="$2"

    log "Committing changes to ${repo_dir}..."

    git -C "${repo_dir}" config --local user.name  "Shrinivas Kumbhar"
    git -C "${repo_dir}" config --local user.email "shrinivas.v.kumbhar@gmail.com"
    git -C "${repo_dir}" add .

    # --cached checks what is actually staged, not working-tree diffs.
    if git -C "${repo_dir}" diff --cached --quiet; then
        log "No changes to commit."
        return 0
    fi

    git -C "${repo_dir}" commit -m "${commit_msg}"
    git -C "${repo_dir}" push origin main
    log "Changes pushed successfully."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

install_docker
setup_ssh

log "Cloning/updating PKGBUILD repository..."
clone_or_update_repo "${PKGBUILD_REPO_URL}" "shani-pkgbuilds"

log "Cloning/updating public package repository..."
clone_or_update_repo "${PUBLIC_REPO_URL}" "shani-repo"

mkdir -p "${ARCH_DIR}"

cleanup_old_versions "${ARCH_DIR}"

PACKAGES_NEEDING_DB_UPDATE=()
FAILED_PACKAGES=()

log "Building and signing packages..."
for pkgbuild_dir in shani-pkgbuilds/*/; do
    if [[ ! -f "${pkgbuild_dir}/PKGBUILD" ]]; then
        log "Skipping ${pkgbuild_dir} — no PKGBUILD found."
        continue
    fi

    if ! build_package "${pkgbuild_dir}"; then
        FAILED_PACKAGES+=("${pkgbuild_dir}")
        log "WARNING: build_package failed for ${pkgbuild_dir} — continuing with remaining packages."
    fi
done

if [[ ${#PACKAGES_NEEDING_DB_UPDATE[@]} -gt 0 ]]; then
    log "${#PACKAGES_NEEDING_DB_UPDATE[@]} new package(s) built — rebuilding database..."
    rebuild_database "${ARCH_DIR}"
else
    log "No new packages built — database unchanged."
fi

commit_and_push "shani-repo" "Update package repository with new builds"

# Report failures and exit non-zero so CI marks the run as failed.
if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    log "ERROR: The following packages failed to build:"
    for pkg in "${FAILED_PACKAGES[@]}"; do
        log "  - ${pkg}"
    done
    exit 1
fi

log "Build process completed successfully."
