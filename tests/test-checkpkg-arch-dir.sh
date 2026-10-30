#!/usr/bin/env bash
# tests/test-checkpkg-arch-dir.sh
#
# TDD contract for checkpkg.sh's repo-directory mapping.
#
# 2026-10-30 was the first real CI run where pkg/checkpkg.sh ever executed
# (its caller only started checking its exit code after the "pkg_arch:
# unbound variable" fix). Every any-arch package — most of this repo —
# failed the check with
#     ERROR: no shani-repo directory for arch 'any' (looked in /pkg/shani-repo/any)
# because the mapping took the ARTIFACT name's arch (…-any) and used it as
# a repo LAYOUT directory, but shani-repo has exactly two: x86_64 and arm.
# An `any` artifact is arch-independent and lands in the builder host's
# arch directory (pkg-builder.sh's get_pkg_arch routes it there).
#
# NO docker, network or secrets: the mapping block is extracted from the
# production file and evaluated against representative PKGFILE values.
#
# Run: bash tests/test-checkpkg-arch-dir.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPKG="$REPO_ROOT/pkg/checkpkg.sh"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Extract the mapping block verbatim through the first `ARCH_DIR=` line.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
awk '/^_pkg_arch="\$\{PKGFILE##\*-\}"/,/^ARCH_DIR=/' "$CHECKPKG" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then
    bad "mapping block not found in checkpkg.sh (extraction regex drifted?)"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

resolve_arch_dir() {
    (
        PKGFILE="$1"
        # Any `any`-arch run needs a host arch: CI hosts are x86_64 and the
        # arm layout holds armv7l/aarch64. Stub uname -m per case below.
        eval "$(_printf_stub "$2")"
        log() { printf '%s\n' "$*" >&2; }
        cd "$WORK" || exit 1
        # The block ends by setting ARCH_DIR; adding `echo "$ARCH_DIR"`
        # surfaces it without re-evaluating the caller's shell.
        eval "$(cat "$WORK/block.sh"; echo 'echo "$ARCH_DIR"')"
    ) 2>/dev/null
}
_printf_stub() { # map stub uname -m value into a function override
    case "${1:-real}" in
        x86_64) echo "uname() { echo x86_64; }" ;;
        aarch64) echo "uname() { echo aarch64; }" ;;
        armv7l) echo "uname() { echo armv7l; }" ;;
        *) echo ":" ;;
    esac
}

# F1: the live regression — an any artifact maps to the HOST repo dir
d="$(resolve_arch_dir "shani-deploy-0.0.1-106-any.pkg.tar.zst" "real")"
if [ "$(uname -m)" = x86_64 ]; then
    [ "$d" = "/pkg/shani-repo/x86_64" ] && ok "F1a: any -> x86_64 on CI host" || bad "F1a: got '$d'"
else
    [ "$d" = "/pkg/shani-repo/arm" ] && ok "F1a: any -> arm on host $(uname -m)" || bad "F1a: got '$d'"
fi

# F2: native passthrough unchanged
d="$(resolve_arch_dir "os-installer-git-0.5.1-17-x86_64.pkg.tar.zst" "real")"
[ "$d" = "/pkg/shani-repo/x86_64" ] && ok "F2: native x86_64 artifact keeps x86_64" || bad "F2: got '$d'"

# F3: aarch64 host with any artifact -> arm layout
d="$(resolve_arch_dir "shani-chronoa-0.1.0-60-any.pkg.tar.zst" "aarch64")"
[ "$d" = "/pkg/shani-repo/arm" ] && ok "F3: any + aarch64 host -> arm" || bad "F3: got '$d'"

# F4: armv7l host with any artifact -> arm layout
d="$(resolve_arch_dir "shani-fleet-1.0-3-any.pkg.tar.zst" "armv7l")"
[ "$d" = "/pkg/shani-repo/arm" ] && ok "F4: any + armv7l host -> arm" || bad "F4: got '$d'"

# S1: the mapping still starts from the artifact name (multi-arch guard)
if grep -q 'PKGFILE##\*-' "$CHECKPKG"; then
    ok "S1: arch still derived from the artifact name"
else
    bad "S1: artifact-name derivation gone"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
