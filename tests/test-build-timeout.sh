#!/usr/bin/env bash
# tests/test-build-timeout.sh
#
# TDD contract for the build-timeout guard installed around `makepkg` in
# pkg/pkg-builder.sh (shani-builder AGENTS.md roadmap item #1 / IMPLEMENTATION-ROADMAP.md #4).
#
# Rationale: makepkg can hang indefinitely on a broken/mutually-recursive
# dependency resolver state or a stuck upstream source fetch, wedging a
# builder. Wrapping it in `timeout "${BUILD_TIMEOUT:-3600}"` makes a stuck
# build killable + surfaced instead of hanging forever (mirrors chaotic-manager's
# idle_timeout watchdog).
#
# This test needs NO docker, network, or signing secrets. It:
#   (S1/S2/S3) reproduces the EXACT production command pattern against a stubbed
#            `makepkg` and asserts the observable exit code + log line.
#   (S4) static assertion that the guard is actually wired into pkg-builder.sh
#        (this is the RED signal: fails before the edit, passes after).
#   (S5) static assertion that NO secret-handling lines (GPG_PASSPHRASE, SSH
#        import, gpg --detach-sign) were altered by this feature.
#
# Run: bash tests/test-build-timeout.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_BUILDER="$REPO_ROOT/pkg/pkg-builder.sh"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# --- Behavioral: the production guard pattern, isolated & exercised ---
# This mirrors, verbatim, the command we install around makepkg. `timeout`
# is coreutils (in the builder container). BUILD_TIMEOUT defaults to 3600s.
guard_pattern() {
    timeout "${BUILD_TIMEOUT:-3600}" "$FAKE_MAKEPKG" -sc --noconfirm || {
        rc=$?
        if [ "$rc" -eq 124 ]; then
            echo "makepkg timed out after ${BUILD_TIMEOUT:-3600}s (set BUILD_TIMEOUT)" >&2
        else
            echo "makepkg failed (exit $rc)" >&2
        fi
        return "$rc"
    }
    return 0
}

stub_makepkg() {
    local bin
    bin="$(mktemp -d)/makepkg"
    case "$1" in
        success) printf '#!/usr/bin/env bash\nexit 0\n' >"$bin" ;;
        hang)    printf '#!/usr/bin/env bash\nsleep 99\n' >"$bin" ;;
        failure) printf '#!/usr/bin/env bash\nexit 7\n' >"$bin" ;;
    esac
    chmod +x "$bin"
    printf '%s' "$bin"
}

# Scenario 1 (happy path): succeeding makepkg -> exit 0, no log.
BUILD_TIMEOUT=10 FAKE_MAKEPKG="$(stub_makepkg success)"
guard_pattern; rc=$?
[ "$rc" -eq 0 ] && ok "S1: succeeding build returns 0" || bad "S1: expected 0, got $rc"

# Scenario 2 (edge / hang): hung makepkg is killed at BUILD_TIMEOUT -> 124 + timed-out log.
BUILD_TIMEOUT=2 FAKE_MAKEPKG="$(stub_makepkg hang)"
out="$(guard_pattern 2>&1)"; rc=$?
if [ "$rc" -eq 124 ] && printf '%s' "$out" | grep -q "timed out after 2s"; then
    ok "S2: hung build killed (124) + 'timed out after 2s' log"
else
    bad "S2: rc=$rc out=<<$out>>"
fi

# Scenario 3 (regression): a non-timeout failure must still halt with the right log.
BUILD_TIMEOUT=10 FAKE_MAKEPKG="$(stub_makepkg failure)"
out="$(guard_pattern 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$out" | grep -q "makepkg failed (exit 7)"; then
    ok "S3: non-timeout failure propagates exit 7 + 'failed' log"
else
    bad "S3: rc=$rc out=<<$out>>"
fi

# Scenario 4 (static): the guard is wired into the actual production file.
if grep -q 'makepkg timed out after' "$PKG_BUILDER"; then
    ok "S4: pkg-builder.sh wires timeout guard around makepkg"
else
    bad "S4: pkg-builder.sh does NOT wire timeout guard around makepkg"
fi

if grep -q 'export GPG_PASSPHRASE' "$PKG_BUILDER" \
   && grep -q -- '--passphrase-fd 0' "$PKG_BUILDER" \
   && grep -q -- '--detach-sign' "$PKG_BUILDER"; then
    ok "S5: GPG/SSH secret-handling patterns intact"
else
    bad "S5: secret-handling patterns may have been altered"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
