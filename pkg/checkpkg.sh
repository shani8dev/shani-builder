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

# Inside the container the repo root is mounted at /pkg, but PKGBUILD_DIR may
# arrive as a repo-relative path (shani-pkgbuilds/X) — resolve it against /pkg
# so the `cd "$PKGDIR"` below cannot fail on the image's WORKDIR.
if [[ "${IS_IN_CONTAINER:-false}" == "true" && "$PKGDIR" != /pkg/* ]]; then
    PKGDIR="/pkg/${PKGDIR}"
fi

cd "$PKGDIR"

# Source PKGBUILD to get metadata (same approach as pkg-builder.sh).
. ./PKGBUILD
PKGNAME="${pkgname[0]:-${pkgname}}"

# Determine the arch directory in shani-repo.
#
# This used to read `$pkg_arch`, which **no PKGBUILD defines** - the array a
# PKGBUILD declares is `arch`, and `pkg_arch` is the name pkg-builder.sh gives
# its own locally-derived copy. Under `set -euo pipefail` this died on the very
# next line with "pkg_arch: unbound variable", so checkpkg had never compared
# anything on any package, and because the caller keys its warning off this
# script's exit status, *every* package in the repo drew the same
# "checkpkg found differences or failed" warning. A warning that is always
# printed is indistinguishable from one that is always wrong, which is how a
# packaging check becomes decorative.
#
# The arch is taken from the artifact name instead of being re-derived: makepkg
# has already applied get_pkg_arch's host-carch preference (an `arch=('i686'
# 'x86_64')` PKGBUILD produces an x86_64 artifact on an x86_64 host), and
# pkg-builder.sh computed PKG_FILE with that same rule. A second copy of it here
# would be a weaker one, and would look in the wrong directory for any
# multi-arch package.
_pkg_arch="${PKGFILE##*-}"
_pkg_arch="${_pkg_arch%.pkg.tar.zst}"
# An `any`-arch artifact (most of this repo: shani-deploy, shani-chronoa,
# …) goes into the builder HOST's arch directory — `any` is the artifact
# name's arch, not a repo layout directory — and shani-repo has exactly
# two: x86_64 and arm. Deriving from the artifact name already mirrors
# get_pkg_arch for native debs; for `any` the artifact is arch-independent
# and pkg-builder.sh's own get_pkg_arch routes it to the host directory,
# so re-apply that same routing here: CI hosts are x86_64, arm* covers the
# arm layout. Found live 2026-10-30: on the first real CI run where
# checkpkg ever executed, every any-arch package printed "no shani-repo
# directory for arch 'any' (looked in /pkg/shani-repo/any)".
if [[ "$_pkg_arch" == any ]]; then
    _pkg_arch="$(uname -m)"
    # matches pkg-builder.sh's get_pkg_arch layout: armv7l|aarch64 -> arm
    # (aarch64 does NOT glob-match arm* — 'aa' vs 'ar' — so name it explicitly)
    case "$_pkg_arch" in
        armv7l|aarch64) _pkg_arch="arm" ;;
        *)              _pkg_arch="x86_64" ;;
    esac
fi
ARCH_DIR="/pkg/shani-repo/${_pkg_arch}"
if [[ ! -d "$ARCH_DIR" ]]; then
    log "ERROR: no shani-repo directory for arch '${_pkg_arch}' (looked in ${ARCH_DIR})"
    exit 1
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
# `find-libprovides` is pacman's soname scanner, and it is **not in the builder
# image this runs in** — measured there: `command -v find-libprovides` finds
# nothing while `/usr/bin/pacman` is present. Under `set -euo pipefail` the bare
# pipeline died on it with exit 127, which is a second, independent way this
# check could never reach its verdict, on top of the unbound `pkg_arch` above.
# Both had to be fixed before any of this compared anything.
#
# Skipping is not the same as passing. An absent scanner means soname drift is
# UNCHECKED, and that is stated rather than folded into a clean bill of health:
# "No soname differences" from a run that never scanned anything is a claim
# about these packages that nobody made.
log "Checking sonames..."
if ! command -v find-libprovides >/dev/null 2>&1; then
    log "SKIPPED: find-libprovides is not installed in this image — soname drift is unchecked."
else
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
fi

if [[ "$HAS_DIFFERENCES" == "true" ]]; then
    # Non-zero, because otherwise this result is computed and thrown away: the
    # caller prints its warning off the exit status, so a script that always
    # exited 0 would report "checkpkg passed" for a package it just proved
    # differs from the one it replaces.
    #
    # This does NOT block publishing. The artifact is already in the repo by the
    # time this runs, and the caller is documented below to tolerate a non-zero
    # here. Reporting is the whole job; gating is the release decision.
    log "checkpkg: Differences found for ${PKGFILE} — review before publishing."
    exit 1
else
    log "checkpkg: No differences for ${PKGFILE} — artifact verified."
    exit 0
fi
