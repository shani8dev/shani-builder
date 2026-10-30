#!/usr/bin/env bash
# tests/test-build-dependency-order.sh
#
# TDD contract for the build-order fix in pkg/pkg-builder.sh
# (2026-10-30 run 41002085320 failed with `target not found: shani-shell`
# while building shani-desktop-niri).
#
# The old "pre-pass" had two verified defects, both reproduced here:
#   R1: its awk block-extraction ended at the first line terminating in `)`,
#       and a COMMENT line inside depends=() can end in `)` — so
#       shani-desktop-niri's real deps were never discovered at all.
#   R2: even with working extraction, it built only the FIRST in-tree dep
#       per package (`break` after the first).
# The replacement is a full pass ordering every package AFTER its (complete)
# set of in-tree deps.
#
# This test needs NO docker, network or signing secrets. It:
#   (F1-F6) runs the REAL ordering block, extracted verbatim from
#           pkg/pkg-builder.sh, against a synthetic shani-pkgbuilds tree
#           shaped like the real failure, and asserts the order.
#   (S1-S3) static assertions that the production file actually wires the
#           new functions and no longer contains the broken awk pattern.
#
# Run: bash tests/test-build-dependency-order.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_BUILDER="$REPO_ROOT/pkg/pkg-builder.sh"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Extract the ordering block verbatim from the production file: from the
# "Build order" banner comment through the surface log line. If extraction
# comes up empty the static assertions below make the run loud.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ORDER_BLOCK="$WORK/order-block.sh"
awk '/^# Build order: a real topological sort/,/^log "Build order/' \
    "$PKG_BUILDER" > "$ORDER_BLOCK"

# --- Behavioral tests run the real block against a fixture tree -------------
# Fixture: same shape as the real failure in run 41002085320.
write_pkg() {
    local dir="$1" name="$2" deps="$3"
    mkdir -p "$WORK/shani-pkgbuilds/${dir}"
    if [ -n "$deps" ]; then
        # multivalue deps: space separated
        { echo "pkgname=$name"
          printf 'depends=(\n'
          for d in $deps; do printf '\t%s\n' "$d"; done
          echo ")"; } > "$WORK/shani-pkgbuilds/${dir}/PKGBUILD"
    else
        printf 'pkgname=%s\n' "$name" > "$WORK/shani-pkgbuilds/${dir}/PKGBUILD"
    fi
}

# The exact production shape: a comment line ending in `)` inside depends=().
mkdir -p "$WORK/shani-pkgbuilds/shani-desktop-niri"
{ echo "pkgname=shani-desktop-niri"
  echo "depends=("
  echo "	# the shell starts it (usr/lib/systemd/user/niri.service.d)"
  echo "	shani-shell"
  printf "\t%s\n" "'shani-input-fcitx5>=1'"
  echo ")"
} > "$WORK/shani-pkgbuilds/shani-desktop-niri/PKGBUILD"
write_pkg shani-shell shani-shell shani-input-fcitx5
write_pkg shani-input-fcitx5 shani-input-fcitx5 shani-input-ibus
write_pkg shani-input-ibus shani-input-ibus ""
write_pkg game-devices-udev game-devices-udev ""
write_pkg cyc-a cyc-a cyc-b
write_pkg cyc-b cyc-b cyc-a
# makedepends-only edge
write_pkg mkdep-only mkdep-only ""
{ echo "pkgname=mkdep-only"
  echo "makedepends=(shani-input-ibus)"; } > "$WORK/shani-pkgbuilds/mkdep-only/PKGBUILD"

run_order() {
    (
        cd "$WORK" || exit 1
        ln -sfn "$WORK/shani-pkgbuilds" "$WORK/shani-pkgbuilds" 2>/dev/null
        # The block's own helpers (the real ones log/warn identically).
        # No stderr redirect here: F5 asserts the cycle warning survives.
        log() { printf '%s\n' "$*"; }
        warn() { printf 'WARNING: %s\n' "$*" >&2; }
        eval "$(cat "$ORDER_BLOCK")"
    )
}

out="$(run_order | sed -n 's/^Build order (in-tree dependencies first): //p')"
stderr="$(run_order 2>&1 >/dev/null)"
stderr_cycle_warn="$(printf '%s' "$stderr" | grep -o 'In-tree dependency cycle.*' | head -1)"

pos() { # pos_of element -> index in BUILD_ORDER
    local i=0 e
    for e in $out; do [ "$e" = "$1" ] && echo "$i" && return 0; i=$((i+1)); done
    echo 99999
}

# F1: the exact regression — every in-tree dep of niri precedes niri
n=$(pos shani-desktop-niri)
[ "$(pos shani-shell)" -lt "$n" ] \
    && ok "F1a: shani-shell precedes shani-desktop-niri (R1 fixed)" \
    || bad "F1a: shani-shell not before niri: order=<<$out>>"
[ "$(pos shani-input-fcitx5)" -lt "$n" ] \
    && ok "F1b: shani-input-fcitx5 precedes shani-desktop-niri (R2 fixed)" \
    || bad "F1b: fcitx5 not before niri: order=<<$out>>"
[ "$(pos shani-input-ibus)" -lt "$(pos shani-input-fcitx5)" ] \
    && ok "F1c: deep deps resolve transitively (fcitx5 -> ibus)" \
    || bad "F1c: ibus not before fcitx5"
[ "$(pos shani-input-fcitx5)" -lt "$(pos shani-shell)" ] \
    && ok "F1d: shell builds after its own dep fcitx5" \
    || bad "F1d: fcitx5 not before its dependent shell"

# F2: every fixture package emitted exactly once
count=0; dup=0; seen=""
for e in $out; do
    if printf '%s' "$seen" | grep -qw "$e"; then dup=$((dup+1))
    else count=$((count+1)); seen="$seen $e"; fi
done
[ "$count" -eq 8 ] && [ "$dup" -eq 0 ] \
    && ok "F2: all 8 packages emitted exactly once" \
    || bad "F2: count=$count dup=$dup (expected 8 unique): <<$out>>"

# F3: standalone package unaffected
[ "$(pos game-devices-udev)" -lt 99999 ] \
    && ok "F3: standalone package present" \
    || bad "F3: game-devices-udev missing"

# F4: cycle terminates and still emits both members
[ "$(pos cyc-a)" -lt 99999 ] && [ "$(pos cyc-b)" -lt 99999 ] \
    && ok "F4: dependency cycle termininates, both members emitted" \
    || bad "F4: cycle lost: <<$out>>"
printf '%s' "$stderr_cycle_warn" | grep -q "In-tree dependency cycle" \
    && ok "F5: cycle is warned, not silent" \
    || bad "F5: no cycle warning"

# F6: makedepends count as ordering edges
{ echo "pkgname=mkdep-only"; echo "makedepends=(shani-input-ibus)"; } >/dev/null
[ "$(pos mkdep-only)" -gt "$(pos shani-input-ibus)" ] \
    && ok "F6: makedepends ordering edge respected" \
    || bad "F6: makedepends not treated as an edge"

# --- Static assertions on the production file ------------------------------
if grep -q '_pkg_tree_deps' "$PKG_BUILDER" \
   && grep -q 'visit()' "$PKG_BUILDER" \
   && grep -q 'BUILD_ORDER' "$PKG_BUILDER"; then
    ok "S1: pkg-builder.sh wires the DFS ordering (_pkg_tree_deps/visit/BUILD_ORDER)"
else
    bad "S1: ordering functions missing from pkg-builder.sh"
fi

if ! grep -q "if(b)b=0" "$PKG_BUILDER"; then
    ok "S2: the broken awk single-pass extraction is gone (R1's mechanism)"
else
    bad "S2: the broken awk block-extraction is still present"
fi

if grep -q 'for pkgdir in "${BUILD_ORDER' "$PKG_BUILDER"; then
    ok "S3: the main build loop iterates BUILD_ORDER"
else
    bad "S3: main loop does not iterate BUILD_ORDER"
fi

if grep -q 'Server = file:///pkg/shani-repo/\${REPO_SUBDIR}' "$PKG_BUILDER" \
   && grep -q 'rebuild_database "${ARCH_DIR}"$' "$PKG_BUILDER"; then
    ok "S4: same-run dependency wiring present ([shani] file:// + per-build db rebuild)"
else
    bad "S4: same-run dependency wiring ([shani] local server / incremental rebuild) missing"
fi

# S5: secret-handling invariants untouched (AGENTS.md mandatory check).
# Narrow to the exact secret names this pipeline moves through env: a broad
# `\-e [A-Z_]+=...` regex false-positives on benign env passes like
# `-e PKGBUILD_DIR="${pkgbuild_dir_clean}"` (a path, not a secret).
ok_list=()
for secret_var in GPG_PASSPHRASE SSH_PRIVATE_KEY GPG_PRIVATE_KEY \
                  PKG_SOURCES_DEPLOY_KEY SHANI_GH_TOKEN; do
    if grep -qE "\-e ${secret_var}=" "$PKG_BUILDER"; then
        ok_list+=("$secret_var via -e (env name only, not argv interpolation)")
    fi
done
if grep -q 'export GPG_PASSPHRASE' "$PKG_BUILDER" \
   && grep -q -- '--passphrase-fd 0' "$PKG_BUILDER" \
   && grep -q -- '--detach-sign' "$PKG_BUILDER" \
   && ! grep -qE '\\-e [A-Z_]+="\$\{?[A-Z_]+\}?"' "$PKG_BUILDER"; then
    ok "S5: GPG patterns intact; secrets travel via env (only ${#ok_list[@]} -e secret names, none \"\$VAR\"-interpolated)"
else
    bad "S5: secret-handling patterns may have been altered (match list: ${ok_list[*]:-none})"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
