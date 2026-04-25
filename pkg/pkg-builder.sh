#!/bin/bash
# pkg-builder.sh — Build, sign, and publish Shani OS custom packages to shani-repo.
#
# Credentials are read exclusively from environment variables:
#   SSH_PRIVATE_KEY   — ED25519/RSA private key with write access to shani-pkgbuilds and shani-repo
#   GPG_PASSPHRASE    — Passphrase for the GPG signing key
#   GPG_PRIVATE_KEY   — Armored GPG private key for package signing
#
# Never pass secrets as positional arguments — they appear in ps aux output.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PKGBUILD_REPO_URL="git@github.com:shani8dev/shani-pkgbuilds.git"
readonly PUBLIC_REPO_URL="git@github.com:shani8dev/shani-repo.git"
readonly BUILDER_IMAGE="shrinivasvkumbhar/shani-builder:latest"

# Temporary paths — all under /tmp so they never land inside the repo dirs
readonly SSH_DIR="$(mktemp -d /tmp/shani-ssh-XXXXXX)"
readonly GPG_KEY_FILE="$(mktemp /tmp/shani-gpg-XXXXXX.asc)"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit, even on error
# ---------------------------------------------------------------------------
cleanup() {
    # Shred the GPG key before removing it so key material is not recoverable
    command -v shred &>/dev/null && shred -u "${GPG_KEY_FILE}" 2>/dev/null || rm -f "${GPG_KEY_FILE}"
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
    if [[ -z "${!var:-}" ]]; then
        echo "Error: ${var} is not set." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Architecture → repo subdirectory
# ---------------------------------------------------------------------------
readonly ARCH
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)         ARCH_DIR="./shani-repo/x86_64" ;;
    armv7l|aarch64) ARCH_DIR="./shani-repo/arm"    ;;
    *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Docker — already present on GitHub runners; this is a safety net for local use
# ---------------------------------------------------------------------------
install_docker() {
    command -v docker &>/dev/null && { log "Docker is already installed."; return 0; }
    log "Docker not found, installing..."
    if [[ ! -f /etc/os-release ]]; then
        log "Error: Unknown OS, cannot install Docker." >&2; exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        ubuntu|debian) apt-get update -qq && apt-get install -y docker.io ;;
        arch)          pacman -S --noconfirm docker ;;
        fedora|centos|rhel) dnf install -y docker ;;
        *) log "Error: Unsupported OS for Docker installation." >&2; exit 1 ;;
    esac
    log "Docker installed."
}

# ---------------------------------------------------------------------------
# SSH setup — key written to /tmp, never into any repo directory
# ---------------------------------------------------------------------------
setup_ssh() {
    log "Setting up SSH..."
    local key_file="${SSH_DIR}/id_rsa"
    # printf '%s\n' is safer than echo — does not misinterpret backslashes or
    # -n/-e flags that might appear in certain key formats.
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
# Remove package files whose name-version-release no longer matches any
# current PKGBUILD. Runs in a subshell per PKGBUILD so sourcing one never
# pollutes the next iteration's variables.
# ---------------------------------------------------------------------------
cleanup_old_versions() {
    local arch_dir="$1"
    [[ -d "${arch_dir}" ]] || return 0

    log "Scanning for stale package versions in ${arch_dir}..."

    # Build a set of current package base-names (name-ver-rel-arch) from PKGBUILDs
    local -A current_packages=()
    for pkgbuild_dir in shani-pkgbuilds/*/; do
        [[ -f "${pkgbuild_dir}/PKGBUILD" ]] || continue
        # Source in a subshell to avoid variable bleed between iterations
        local entry
        entry=$(bash -c '
            source "'"${pkgbuild_dir}"'/PKGBUILD"
            # pkgname and arch may be arrays; iterate all combinations
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

    # Remove any .pkg.tar.zst (and matching .sig) not in the current set
    for file in "${arch_dir}"/*.pkg.tar.zst "${arch_dir}"/*.pkg.tar.zst.sig; do
        [[ -e "$file" ]] || continue
        local base="${file%.sig}"
        base="${base%.pkg.tar.zst}"
        # basename without directory prefix
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
# Returns non-zero on failure so the caller can collect FAILED_PACKAGES.
# ---------------------------------------------------------------------------
build_package() {
    local pkgbuild_dir="$1"

    # Source PKGBUILD in a subshell to read metadata without polluting this shell
    local pkgname pkgver pkgrel pkg_arch
    eval "$(bash -c '
        source "'"${pkgbuild_dir}"'/PKGBUILD"
        # Use first element of each array for the primary artifact name
        echo "pkgname=${pkgname[0]}"
        echo "pkgver=${pkgver}"
        echo "pkgrel=${pkgrel}"
        echo "pkg_arch=${arch[0]}"
    ')"

    local pkg_file="${pkgname}-${pkgver}-${pkgrel}-${pkg_arch}.pkg.tar.zst"
    local pkg_sig="${pkg_file}.sig"

    # Skip if both artifact and signature already exist
    if [[ -f "${ARCH_DIR}/${pkg_file}" && -f "${ARCH_DIR}/${pkg_sig}" ]]; then
        log "Package ${pkg_file} already exists — skipping build."
        return 0
    fi

    log "Building: ${pkgname} ${pkgver}-${pkgrel}"

    # Write GPG key to temp file with correct permissions for the container's builduser (uid 1000)
    printf '%s\n' "$GPG_PRIVATE_KEY" > "${GPG_KEY_FILE}"
    chmod 644 "${GPG_KEY_FILE}"  # readable by builduser inside the container

    docker run --rm \
        -v "$(pwd):/pkg" \
        -v "${GPG_KEY_FILE}:/tmp/gpg-private.asc:ro" \
        -e PKGBUILD_DIR="$(basename "${pkgbuild_dir}")" \
        -e GPG_PASSPHRASE \
        -e PKG_FILE="${pkg_file}" \
        "${BUILDER_IMAGE}" bash -c '
            set -euo pipefail

            # Fix ownership of the build directory — do NOT touch all of /pkg
            chown -R builduser:builduser "/pkg/${PKGBUILD_DIR}"

            su - builduser -c "
                set -euo pipefail
                export GNUPGHOME=/home/builduser/.gnupg

                # Import the signing key
                gpg --batch --pinentry-mode loopback \
                    --passphrase \"\${GPG_PASSPHRASE}\" \
                    --import /tmp/gpg-private.asc \
                    || { echo \"GPG import failed\"; exit 1; }

                cd \"/pkg/\${PKGBUILD_DIR}\" || exit 1

                # Build the package (downloads sources, compiles, packages)
                makepkg -sc --noconfirm \
                    || { echo \"makepkg failed for \${PKGBUILD_DIR}\"; exit 1; }

                # Detached armored signature
                gpg --batch --pinentry-mode loopback \
                    --passphrase \"\${GPG_PASSPHRASE}\" \
                    --detach-sign --armor \
                    --output \"\${PKG_FILE}.sig\" \
                    \"\${PKG_FILE}\" \
                    || { echo \"GPG sign failed for \${PKG_FILE}\"; exit 1; }
            "
        '

    # Move artifacts to the arch directory
    local built=false
    for artifact in "${pkg_file}" "${pkg_sig}"; do
        if [[ -f "${pkgbuild_dir}/${artifact}" ]]; then
            mv "${pkgbuild_dir}/${artifact}" "${ARCH_DIR}/"
            built=true
        else
            log "Warning: expected artifact not found: ${pkgbuild_dir}/${artifact}"
        fi
    done

    # Clean up makepkg working directories
    rm -rf "${pkgbuild_dir}/pkg" "${pkgbuild_dir}/src"

    if [[ "$built" == false ]]; then
        log "Error: no artifacts produced for ${pkgname}" >&2
        return 1
    fi

    # Record that this package needs a DB update
    PACKAGES_NEEDING_DB_UPDATE+=("${ARCH_DIR}/${pkg_file}")
    return 0
}

# ---------------------------------------------------------------------------
# Rebuild the repo database from scratch using all current packages.
# Called once after all packages have been built, not once per package.
# ---------------------------------------------------------------------------
rebuild_database() {
    local arch_dir="$1"

    log "Rebuilding package database in ${arch_dir}..."

    # Verify there is something to add
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

            # Remove stale db symlinks/tarballs before regenerating
            rm -f shani.db shani.db.tar.gz shani.db.tar.gz.old \
                  shani.files shani.files.tar.gz shani.files.tar.gz.old

            # Build fresh database from all packages in the directory
            repo-add shani.db.tar.gz *.pkg.tar.zst

            # Create the expected un-suffixed symlink names
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

    # Use --local to avoid polluting the runner's global git config
    git -C "${repo_dir}" config --local user.name  "Shrinivas Kumbhar"
    git -C "${repo_dir}" config --local user.email "shrinivas.v.kumbhar@gmail.com"

    git -C "${repo_dir}" add .

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

# Track packages that were actually built so we rebuild the DB only when needed
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

# Rebuild the database once if any package was newly built
if [[ ${#PACKAGES_NEEDING_DB_UPDATE[@]} -gt 0 ]]; then
    log "${#PACKAGES_NEEDING_DB_UPDATE[@]} new package(s) built — rebuilding database..."
    rebuild_database "${ARCH_DIR}"
else
    log "No new packages built — database unchanged."
fi

commit_and_push "shani-repo" "Update package repository with new builds"

# Report failures and exit non-zero so CI shows a red run
if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    log "ERROR: The following packages failed to build:"
    for pkg in "${FAILED_PACKAGES[@]}"; do
        log "  - ${pkg}"
    done
    exit 1
fi

log "Build process completed successfully."
