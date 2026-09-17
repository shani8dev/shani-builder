#!/bin/bash
# checkpkg.sh — Verify a package build produces a working artifact
# before publishing to shani-repo.
#
# Compares the built package against the previous version in shani-repo:
#   - File lists (bsdtar tf + sdiff)
#   - Sonames (find-libprovides + sdiff)
#
# Adapted from garuda-tools/bin/checkpkg.in for shani's pipeline.
#
# Must run inside the shani-builder container (needs bsdtar, find-libprovides).
# When run on the host, delegates to the container automatically.
#
# Usage (inside container):
#   PKGBUILD_DIR=/path/to/pkgbuild PKG_FILE=pkgname-pkgver-pkgrel-arch.pkg.tar.zst \
#       bash pkg/checkpkg.sh
#
# Usage (from host):
#   bash pkg/checkpkg.sh <pkgbuild_dir> <pkg_file>

set -euo pipefail

readonly SCRIPT_NAME="checkpkg"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

# ── Host-side delegation ──────────────────────────────────────
# If bsdtar or find-libprovides are not available, we are on the host
# and need to run inside the builder container (same convention as
# pkg-builder.sh — the comparison tools live in the container image).

if [[ "${IS_IN_CONTAINER:-false}" != "true" ]]; then
    if command -v bsdtar &>/dev/null && command -v find-libprovides &>/dev/null; then
        # Tools available — run directly.
        : # fall through to main logic below
    elif [[ $# -lt 2 ]]; then
        echo "Usage: bash pkg/checkpkg.sh <pkgbuild_dir> <pkg_file>" >&2
        exit 1
    else
        BUILDER_IMAGE="${BUILDER_IMAGE:-shrinivasvkumbhar/shani-builder:latest}"
        log "Delegating to builder container for checkpkg..."
        docker run --rm \
            -v "$(pwd):/pkg" \
            -e PKGBUILD_DIR="$1" \
            -e PKG_FILE="$2" \
            -e IS_IN_CONTAINER=true \
            "${BUILDER_IMAGE}" bash /pkg/pkg/checkpkg.sh
        exit $?
    fi
fi

# ── Main logic (runs inside the container) ────────────────────

PKGDIR="${PKGBUILD_DIR:?PKGBUILD_DIR not set}"
PKGFILE="${PKG_FILE:?PKG_FILE not set}"

cd "$PKGDIR"

# Source PKGBUILD to get metadata (same approach as pkg-builder.sh).
. ./PKGBUILD
PKGNAME="${pkgname[0]:-${pkgname}}"

# Determine the arch directory in shani-repo.
if [[ "$pkg_arch" == "any" ]]; then
    ARCH_DIR="/pkg/shani-repo/any"
else
    ARCH_DIR="/pkg/shani-repo/x86_64"
fi

# The built package is in ARCH_DIR on the host, mounted at /pkg.
BUILT_PKG="${ARCH_DIR}/${PKGFILE}"

if [[ ! -f "$BUILT_PKG" ]]; then
    log "ERROR: Built package not found: $BUILT_PKG"
    exit 1
fi

# Find the previous version of this package in shani-repo.
PREV_PKG=""
for f in "$ARCH_DIR"/*.pkg.tar.zst; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    # Same package name, different version (not the current build).
    if [[ "$fname" == "${PKGNAME}-"* ]] && [[ "$fname" != "$PKGFILE" ]]; then
        PREV_PKG="$f"
    fi
done

if [[ -z "$PREV_PKG" ]]; then
    log "No previous version found for ${PKGNAME} — first build, skipping comparison."
    exit 0
fi

log "Comparing ${PKGFILE} against $(basename "$PREV_PKG")..."

HAS_DIFFERENCES=false

# ── Compare file lists ─────────────────────────────────────────
log "Checking file lists..."
bsdtar tf "$PREV_PKG" | sort > /tmp/checkpkg-old-files
bsdtar tf "$BUILT_PKG" | sort > /tmp/checkpkg-new-files

FILE_DIFF="$(sdiff -s /tmp/checkpkg-old-files /tmp/checkpkg-new-files)" || true
if [[ -n "$FILE_DIFF" ]]; then
    HAS_DIFFERENCES=true
    echo "checkpkg: FILE LIST DIFFERENCES:"
    echo "$FILE_DIFF"
else
    log "File lists identical."
fi

# ── Compare sonames ────────────────────────────────────────────
log "Checking sonames..."
find-libprovides "$PREV_PKG" 2>/dev/null | sort > /tmp/checkpkg-old-sonames
find-libprovides "$BUILT_PKG" 2>/dev/null | sort > /tmp/checkpkg-new-sonames

SONAME_DIFF="$(sdiff -s /tmp/checkpkg-old-sonames /tmp/checkpkg-new-sonames)" || true
if [[ -n "$SONAME_DIFF" ]]; then
    HAS_DIFFERENCES=true
    echo "checkpkg: SONAME DIFFERENCES:"
    echo "$SONAME_DIFF"
else
    log "No soname differences."
fi

if [[ "$HAS_DIFFERENCES" == "true" ]]; then
    log "checkpkg: Differences found for ${PKGFILE} — review before publishing."
else
    log "checkpkg: No differences for ${PKGFILE} — artifact verified."
fi
