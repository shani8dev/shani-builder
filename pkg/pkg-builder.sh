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
# Explicitly exported (readonly does not imply exported) so that `docker run
# -e GPG_PASSPHRASE` (bare name, below) can forward it from THIS process's
# own environment into the container — without ever writing the literal
# value into docker's argv, where `ps aux` / `/proc/<pid>/cmdline` could see it.
export GPG_PASSPHRASE

# Temp files live in /tmp — never inside any repo directory.
# Declare and assign separately so mktemp failures are not masked by readonly.
SSH_DIR="$(mktemp -d /tmp/shani-ssh-XXXXXX)"
readonly SSH_DIR
GPG_KEY_FILE="$(mktemp /tmp/shani-gpg-XXXXXX.asc)"
readonly GPG_KEY_FILE
# mktemp already creates this at 0600, but pin it explicitly — private key
# material must never be world- or group-readable, even momentarily.
chmod 600 "${GPG_KEY_FILE}"

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

    # Pin github.com's real host keys instead of disabling verification.
    # These are GitHub's own currently-published keys (github.blog/2023-03-23
    # -we-updated-our-rsa-ssh-host-key / docs.github.com's "About SSH" page),
    # fetched live from GitHub's own /meta API rather than hand-copied, so
    # there's no trust-on-first-connect gap and no MITM window: a clone still
    # fails closed if whatever answers as github.com doesn't hold one of
    # these three key types.
    local known_hosts="${SSH_DIR}/known_hosts"
    cat > "${known_hosts}" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
    chmod 600 "${known_hosts}"

    cat > "${SSH_DIR}/config" <<EOF
Host github.com
  IdentityFile ${key_file}
  UserKnownHostsFile ${known_hosts}
  StrictHostKeyChecking yes
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
        # pkgbuild_dir comes from a directory name in shani-pkgbuilds — not
        # necessarily trusted (a malicious or malformed name containing a
        # quote could break out of the source "..." string below and run
        # arbitrary code). Pass it as a real positional argument ($1) rather
        # than interpolating it into the script string.
        entry=$(bash -c '
            source "$1/PKGBUILD"
            for pn in "${pkgname[@]}"; do
                for pa in "${arch[@]}"; do
                    echo "${pn}-${pkgver}-${pkgrel}-${pa}"
                done
            done
        ' _ "${pkgbuild_dir}")
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
# GPG_PASSPHRASE is passed into the container as a BARE `-e GPG_PASSPHRASE`
# (no `=value`) — this tells docker to forward the variable's value straight
# from THIS process's own (already-exported, see above) environment into the
# container's environment. Critically, the literal secret value is never
# written into `docker`'s own argv this way, so it can't show up in `ps aux` /
# `/proc/<pid>/cmdline` for the `docker run` process itself on the host.
# (An earlier version of this fix used `-e GPG_PASSPHRASE="${GPG_PASSPHRASE}"`,
# which looks equally safe but is NOT: the shell expands `${GPG_PASSPHRASE}`
# before exec, so the plaintext value ends up as a literal argument to the
# `docker` binary — visible in `ps aux`/cmdline for the whole build, exactly
# the class of leak this was supposed to fix. Real-verified via `ps auxww`
# and `/proc/<pid>/cmdline` polling during an actual build — see pkg-builder
# test notes.)
#
# Inside the container, the passphrase is read back out of the environment
# by name (\$GPG_PASSPHRASE, escaped below so it is NOT expanded by the outer
# `bash -c` while constructing `inner`). `su --preserve-environment` (no
# `-`/login option, which would otherwise reset the environment) carries
# GPG_PASSPHRASE through to builduser's shell. The literal passphrase value
# is therefore never baked into the `su -c` argv string either, so it never
# shows up in `ps aux` / `/proc/<pid>/cmdline` at any layer — unlike the
# original version of this script, which interpolated the passphrase
# directly into the `su -c` command line.
#
# PKGBUILD_DIR/PKG_FILE are NOT secrets, just untrusted path/filename
# strings, so they are still shell-escaped via printf %q and inlined
# directly — a directory name or package filename containing a quote or
# shell metacharacter can't break out and run arbitrary code.
#
# GPG sign uses a binary detached sig — NO --armor.
# pacman and repo-add both reject ASCII-armored .sig files.
# ---------------------------------------------------------------------------
build_package() {
    local pkgbuild_dir="$1"
    local pkgbuild_dir_clean="${pkgbuild_dir%/}"

    # Read PKGBUILD metadata in a subshell — does not pollute this shell's env.
    # Falls back to scalar syntax for PKGBUILDs that don't use arrays.
    # pkgbuild_dir is passed as a positional argument ($1), not interpolated
    # into the script string, so a directory name containing a quote can't
    # break out and inject commands that then get eval'd below.
    local pkgname pkgver pkgrel pkg_arch
    eval "$(bash -c '
        source "$1/PKGBUILD"
        echo "pkgname=${pkgname[0]:-${pkgname}}"
        echo "pkgver=${pkgver}"
        echo "pkgrel=${pkgrel}"
        echo "pkg_arch=${arch[0]:-${arch}}"
    ' _ "${pkgbuild_dir}")"

    local pkg_file="${pkgname}-${pkgver}-${pkgrel}-${pkg_arch}.pkg.tar.zst"
    local pkg_sig="${pkg_file}.sig"

    # Skip if both package and signature already exist in the repo.
    if [[ -f "${ARCH_DIR}/${pkg_file}" && -f "${ARCH_DIR}/${pkg_sig}" ]]; then
        log "Package ${pkg_file} already exists — skipping build."
        return 0
    fi

    log "Building: ${pkgname} ${pkgver}-${pkgrel}"

    # Write GPG private key to temp file — bind-mounted into the container.
    # Keep it 0600 (owner-only): this holds real signing key material.
    printf '%s\n' "$GPG_PRIVATE_KEY" > "${GPG_KEY_FILE}"
    chmod 600 "${GPG_KEY_FILE}"

    # PKGBUILD_DIR/PKG_FILE/GPG_PASSPHRASE are passed into the container only
    # via `-e` (never interpolated into a command string) since docker's -e
    # never re-parses a value as shell syntax. The outer bash -c below is a
    # fixed, static script — it does NOT interpolate any of these values
    # itself. `su -` still strips the environment before builduser's shell
    # runs, so that inner script is built via printf %q, which shell-escapes
    # each value so a PKGBUILD directory name or package filename containing
    # a quote or shell metacharacter can't break out and run arbitrary code
    # with access to the imported GPG signing key.
    docker run --rm \
        -v "$(pwd):/pkg" \
        -v "${GPG_KEY_FILE}:/home/builduser/.gnupg/temp-private.asc" \
        -e PKGBUILD_DIR="${pkgbuild_dir_clean}" \
        -e GPG_PASSPHRASE \
        -e PKG_FILE="${pkg_file}" \
        "${BUILDER_IMAGE}" bash -c '
            set -euo pipefail

            # Refresh pacman db and ensure git is available for makepkg --syncdeps.
            pacman -Sy --noconfirm git || { echo "pacman -Sy failed"; exit 1; }

            # builduser must own /pkg to write build artifacts.
            chown -R builduser:builduser /pkg

            # GPG refuses to run if ~/.gnupg is missing or not chmod 700.
            mkdir -p /home/builduser/.gnupg
            chown -R builduser:builduser /home/builduser
            chmod 700 /home/builduser/.gnupg

            q_dir=$(printf %q "$PKGBUILD_DIR")
            q_file=$(printf %q "$PKG_FILE")

            # GPG_PASSPHRASE is deliberately NOT expanded here (\$ is escaped
            # below) — it stays as the literal text "$GPG_PASSPHRASE" in the
            # inner script and is only resolved from builduser'"'"'s own
            # preserved environment when su runs it below. This keeps the
            # secret out of this command string entirely.
            inner="export GNUPGHOME=/home/builduser/.gnupg

# Import GPG key — passphrase read from the environment, piped via stdin.
echo \"\$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /home/builduser/.gnupg/temp-private.asc || { echo '"'"'GPG import failed'"'"'; exit 1; }

cd /pkg/$q_dir || { echo '"'"'cd failed'"'"'; exit 1; }

makepkg -sc --noconfirm || { echo '"'"'makepkg failed'"'"'; exit 1; }

# Sign — binary detached sig, NO --armor (pacman rejects ASCII sigs).
echo \"\$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --detach-sign --output ${q_file}.sig $q_file || { echo '"'"'GPG sign failed'"'"'; exit 1; }"

            # --preserve-environment (no "-"/login option, which would reset
            # the environment) carries GPG_PASSPHRASE from this process'"'"'
            # environment into builduser'"'"'s shell without ever placing the
            # secret value in an argv visible to ps/procfs.
            su --preserve-environment builduser -c "$inner"
        '

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

    # Write GPG private key to temp file — bind-mounted into the container,
    # same mechanism build_package() uses above. Written here explicitly
    # (not relying on a prior build_package() call having populated it this
    # run) because rebuild_database() can still run even when every package
    # this run was already built+signed and skipped.
    printf '%s\n' "$GPG_PRIVATE_KEY" > "${GPG_KEY_FILE}"
    chmod 600 "${GPG_KEY_FILE}"

    docker run --rm \
        -v "$(realpath "${arch_dir}"):/repo" \
        -v "${GPG_KEY_FILE}:/home/builduser/.gnupg/temp-private.asc" \
        -e GPG_PASSPHRASE \
        "${BUILDER_IMAGE}" bash -c '
            set -euo pipefail
            cd /repo
            # Remove old db files, symlinks, and signatures before rebuilding —
            # a stale .sig next to a freshly rebuilt (differently-hashed) .db
            # would fail verification, which is worse than no .sig at all.
            rm -f shani.db shani.db.tar.gz shani.db.tar.gz.old shani.db.sig shani.db.tar.gz.sig \
                  shani.files shani.files.tar.gz shani.files.tar.gz.old shani.files.sig shani.files.tar.gz.sig
            repo-add shani.db.tar.gz *.pkg.tar.zst

            # GPG refuses to run if ~/.gnupg is missing or not chmod 700.
            mkdir -p /home/builduser/.gnupg
            chown -R builduser:builduser /home/builduser /repo
            chmod 700 /home/builduser/.gnupg

            inner="export GNUPGHOME=/home/builduser/.gnupg
echo \"\$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /home/builduser/.gnupg/temp-private.asc || { echo '"'"'GPG import failed'"'"'; exit 1; }
cd /repo || exit 1
# Binary detached sigs, NO --armor (pacman rejects ASCII sigs) — same
# convention build_package() uses for individual package signatures.
for f in shani.db.tar.gz shani.files.tar.gz; do
  echo \"\$GPG_PASSPHRASE\" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --detach-sign --output \"\${f}.sig\" \"\$f\" || { echo '"'"'GPG sign failed'"'"'; exit 1; }
done"
            su --preserve-environment builduser -c "$inner"

            # repo-add creates shani.db/shani.files as symlinks — remove them
            # so the following cp creates real files instead, matching this
            # repo'"'"'s existing convention; copy their signatures alongside.
            rm -f shani.db shani.files
            cp shani.db.tar.gz shani.db
            cp shani.files.tar.gz shani.files
            cp shani.db.tar.gz.sig shani.db.sig
            cp shani.files.tar.gz.sig shani.files.sig
        '

    log "Database rebuilt and signed successfully."
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
