#!/usr/bin/env bash
# tests/test-multi-package.sh
#
# TDD contract for split PKGBUILDs: one PKGBUILD can declare several packages
# in its pkgname array (shani-chronoa-engine/-gtk/-tui). pkg-builder.sh and
# checkpkg.sh used to read only pkgname[0], so only the first artifact was
# published / compared.
#
# NO docker, network or secrets. This test:
#   (B1) runs the REAL metadata-extraction block from pkg-builder.sh against
#        a three-name PKGBUILD and asserts all names survive;
#   (B2-B4) runs the REAL artifact/skip-if-published block with synthetic
#        repo state (none/all/one published) and asserts filenames, metrics,
#        DB-update entries and the all-published decision;
#   (C1-C4) runs a path-adjusted copy of the REAL checkpkg.sh with stubbed
#        bsdtar against old+new artifacts for every name and asserts each
#        package is compared against ITS OWN previous version;
#   (S1-S3) static assertions the production files still wire the loops.
#
# Run: bash tests/test-multi-package.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_BUILDER="$REPO_ROOT/pkg/pkg-builder.sh"
CHECKPKG="$REPO_ROOT/pkg/checkpkg.sh"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCH_DIR="$WORK/shani-repo/x86_64"
mkdir -p "$ARCH_DIR" "$WORK/shani-pkgbuilds/shani-chronoa" "$WORK/bin"

cat > "$WORK/shani-pkgbuilds/shani-chronoa/PKGBUILD" <<'EOF'
pkgname=('shani-chronoa-engine' 'shani-chronoa-gtk' 'shani-chronoa-tui')
pkgver=0.1.0
pkgrel=1
arch=('any')
EOF

# --- B1: the production metadata block yields every pkgname ----------------
awk '/^    local pkgver pkgrel epoch arch_list pgp_keys$/,/_ \"\$\{pkgbuild_dir\}/' \
    "$PKG_BUILDER" > "$WORK/meta-block.sh"
read_meta() (
    pkgbuild_dir="$1"
    eval "$(cat "$WORK/meta-block.sh")"
    printf 'META %s\n' "${pkgnames[*]}"
    printf 'VER %s-%s\n' "$pkgver" "$pkgrel"
)
meta="$(read_meta "$WORK/shani-pkgbuilds/shani-chronoa")"
if printf '%s\n' "$meta" | grep -q '^META shani-chronoa-engine shani-chronoa-gtk shani-chronoa-tui$' \
   && printf '%s\n' "$meta" | grep -q '^VER 0.1.0-1$'; then
    ok "B1: metadata block yields all three pkgnames (not just [0])"
else
    bad "B1: metadata block output: <<$meta>>"
fi

# --- B2-B4: the production artifact/skip block -----------------------------
awk '
/^    # makepkg builds every package in a split PKGBUILD/ { on=1 }
on { print }
/^    if \[\[ "\$all_published" == "true" \]\]; then$/ {
    getline; print; getline; print; on=0
}
' "$PKG_BUILDER" > "$WORK/skip-block.sh"
if [ ! -s "$WORK/skip-block.sh" ]; then
    bad "B2: artifact/skip block not found in pkg-builder.sh (extraction drifted?)"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

probe() {
    ARCH_DIR="$1"
    pkgnames=(shani-chronoa-engine shani-chronoa-gtk shani-chronoa-tui)
    ver=0.1.0; pkgrel=1; pkg_arch=any
    PACKAGES_NEEDING_DB_UPDATE=()
    log() { :; }
    warn() { :; }
    _record_build_metric() { printf 'METRIC %s %s\n' "$1" "$2"; }
    # "raw" keeps the block's early `return 0`; otherwise neutralise it so the
    # post-block state assertions below are reachable.
    local block="$WORK/skip-block.sh"
    if [[ "${2:-}" != "raw" ]]; then
        block="$WORK/skip-block-noreturn.sh"
        sed 's/^        return 0$/        :/' "$WORK/skip-block.sh" > "$block"
    fi
    eval "$(cat "$block")"
    printf 'FILES %s\n' "${pkg_files[*]}"
    printf 'ALLPUBLISHED %s\n' "$all_published"
    printf 'DBUPD %s\n' "${PACKAGES_NEEDING_DB_UPDATE[*]}"
}

# B2: nothing published -> three filenames, not skipped
out="$(probe "$ARCH_DIR")"
expected_files="shani-chronoa-engine-0.1.0-1-any.pkg.tar.zst shani-chronoa-gtk-0.1.0-1-any.pkg.tar.zst shani-chronoa-tui-0.1.0-1-any.pkg.tar.zst"
if printf '%s\n' "$out" | grep -qF "FILES $expected_files" \
   && printf '%s\n' "$out" | grep -q '^ALLPUBLISHED false$'; then
    ok "B2: all three artifacts derived; build not skipped"
else
    bad "B2: output: <<$out>>"
fi

# B3: all published+signed -> skipped, each recorded + queued for DB update
for n in engine gtk tui; do
    for ext in "" ".sig"; do
        : > "$ARCH_DIR/shani-chronoa-${n}-0.1.0-1-any.pkg.tar.zst${ext}"
    done
done
out="$(probe "$ARCH_DIR")"
flow="$(probe "$ARCH_DIR" raw)"
if printf '%s\n' "$out" | grep -q '^ALLPUBLISHED true$' \
   && [ "$(printf '%s\n' "$out" | grep -c '^METRIC .* alreadyBuilt$')" -eq 3 ] \
   && [ "$(printf '%s\n' "$out" | grep '^DBUPD ' | tr ' ' '\n' | grep -c 'pkg.tar.zst$')" -eq 3 ] \
   && ! printf '%s\n' "$flow" | grep -q '^FILES '; then
    ok "B3: all published -> skip, 3 alreadyBuilt metrics, 3 DB-update entries"
else
    bad "B3: output: <<$out>>"
fi

# B4: one published -> build still needed; only published one queued
rm -f "$ARCH_DIR"/shani-chronoa-gtk-* "$ARCH_DIR"/shani-chronoa-tui-*
out="$(probe "$ARCH_DIR")"
if printf '%s\n' "$out" | grep -q '^ALLPUBLISHED false$' \
   && [ "$(printf '%s\n' "$out" | grep '^DBUPD ' | tr ' ' '\n' | grep -c 'pkg.tar.zst$')" -eq 1 ]; then
    ok "B4: partially published -> build needed, only published artifact queued"
else
    bad "B4: output: <<$out>>"
fi

# --- C: run the real checkpkg.sh against a synthetic split package --------
# Only absolute-path assumptions are adjusted for the test workspace:
# /pkg/shani-repo -> WORK, and the /pkg/ prefix added to a relative PKGDIR.
sed -e "s#/pkg/shani-repo/#${ARCH_DIR%/x86_64}/#g" \
    -e 's#PKGDIR="/pkg/${PKGDIR}"#PKGDIR="${PKGDIR}"#' \
    "$CHECKPKG" > "$WORK/checkpkg.sh"

cat > "$WORK/bin/bsdtar" <<'EOF'
#!/usr/bin/env bash
# usage: bsdtar tf <file> — print the sidecar <file>.files
f="${@: -1}"
cat "${f}.files"
EOF
chmod +x "$WORK/bin/bsdtar"

for n in engine gtk tui; do
    new="shani-chronoa-${n}-0.1.0-1-any.pkg.tar.zst"
    old="shani-chronoa-${n}-0.0.9-1-any.pkg.tar.zst"
    : > "$ARCH_DIR/$new"; printf '/usr/bin/%s-new\n' "$n" > "$ARCH_DIR/$new.files"
    : > "$ARCH_DIR/$old"; printf '/usr/bin/%s-old\n' "$n" > "$ARCH_DIR/$old.files"
done

check_one() {
    IS_IN_CONTAINER=true \
    PKGBUILD_DIR="$WORK/shani-pkgbuilds/shani-chronoa" \
    PKG_FILE="$1" \
    PATH="$WORK/bin:$PATH" \
    bash "$WORK/checkpkg.sh" 2>&1
}

for n in engine gtk tui; do
    file="shani-chronoa-${n}-0.1.0-1-any.pkg.tar.zst"
    out="$(check_one "$file")"; rc=$?
    if [ "$rc" -eq 1 ] \
       && printf '%s\n' "$out" | grep -qF "Comparing $file against shani-chronoa-${n}-0.0.9-1-any.pkg.tar.zst" \
       && printf '%s\n' "$out" | grep -q 'FILE LIST DIFFERENCES'; then
        ok "C-${n}: checkpkg compares ${n} against its own previous version"
    else
        bad "C-${n}: rc=$rc output: <<$out>>"
    fi
done

# C-single: scalar pkgname still behaves identically
mkdir -p "$WORK/shani-pkgbuilds/shani-single"
printf 'pkgname=shani-single\npkgver=1.0\npkgrel=1\narch=(%s)\n' "$(uname -m)" \
    > "$WORK/shani-pkgbuilds/shani-single/PKGBUILD"
single_new="shani-single-1.0-1-$(uname -m).pkg.tar.zst"
single_old="shani-single-0.9-1-$(uname -m).pkg.tar.zst"
: > "$ARCH_DIR/$single_new"; printf '/usr/bin/single-new\n' > "$ARCH_DIR/$single_new.files"
: > "$ARCH_DIR/$single_old"; printf '/usr/bin/single-old\n' > "$ARCH_DIR/$single_old.files"
out="$(IS_IN_CONTAINER=true PKGBUILD_DIR="$WORK/shani-pkgbuilds/shani-single" \
       PKG_FILE="$single_new" PATH="$WORK/bin:$PATH" bash "$WORK/checkpkg.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s\n' "$out" | grep -qF "Comparing $single_new against $single_old"; then
    ok "C-single: scalar pkgname still compared against its own version"
else
    bad "C-single: rc=$rc output: <<$out>>"
fi

# --- S: static wiring in the production files ------------------------------
if grep -q 'pkgnames+=(%q)' "$PKG_BUILDER" \
   && grep -q 'for f in \./\*\.pkg\.tar\.zst' "$PKG_BUILDER" \
   && grep -q 'PACKAGES_NEEDING_DB_UPDATE+=("${ARCH_DIR}/${pf}")' "$PKG_BUILDER"; then
    ok "S1: pkg-builder.sh loops over pkgnames for metadata, signing and DB updates"
else
    bad "S1: pkg-builder.sh split-package wiring missing"
fi

if grep -q 'for pn in "${pkgname\[@\]}"' "$CHECKPKG" \
   && ! grep -q 'PKGNAME="${pkgname\[0\]' "$CHECKPKG"; then
    ok "S2: checkpkg.sh selects the pkgname from the array, not [0]"
else
    bad "S2: checkpkg.sh still assumes pkgname[0]"
fi

if grep -qE 'for pn in "\$\{pkgnames\[@\]\}"' "$PKG_BUILDER"; then
    ok "S3: metrics loop over every package name"
else
    bad "S3: per-package metrics loop missing"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
