# Agent instructions — shani-builder

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## What this repo is

The shared build environment for Shanios: `docker/` is a privileged
Arch-based Docker image used by `shani-install-media` to assemble system
images and ISOs; `pkg/` builds, GPG-signs, and publishes packages to
`shani-repo`. Every package and OS image Shanios ships passes through this
repo's signing key — secret-handling bugs here are supply-chain bugs, not
local mistakes.

## Rule: "the passphrase isn't in the command string anymore" is not proof it doesn't leak

This repo signs every package and OS image Shanios ships. A secret-handling
fix here has looked correct on a source read and still leaked in practice
**twice** — once via an inner `su -c` argv, and again (after that was
fixed) via the *outer* `docker run -e VAR="$VAR"` invocation, which puts
the literal value into `docker`'s own argv just as much as the original
bug did. Any change touching `GPG_PASSPHRASE`, `SSH_PRIVATE_KEY`, or
similar must be verified by actually watching for the leak while a real
build runs — not by reading the diff and confirming the old pattern is
gone.

## If you have Superpowers / oh-my-opencode / ultrawork / similar available

If your environment provides Claude Code's **Superpowers** plugin (TDD,
debugging, and verification-discipline skills), OpenCode's
**oh-my-opencode** (parallel/async subagents, LSP/AST tooling), an
**ultrawork**-style high-autonomy parallel execution mode, or an
equivalent skill/subagent framework in whatever tool you're running as —
use it to run the `ps`/`/proc` polling loop below *concurrently* with the
build itself, so you're not relying on lucky timing to catch a leak that
only exists for the process's short lifetime. Don't let a skill
framework's plan-and-report output substitute for actually running the
build and watching for the leak.

## Required verification for any secret-handling change

```bash
# Generate a real throwaway GPG key with a KNOWN passphrase in a scratch
# GNUPGHOME, then run a real build through pkg-builder.sh against it,
# while polling every process's cmdline for the entire build duration:

while true; do ps -eo pid,args; for p in /proc/[0-9]*/cmdline; do
  tr '\0' ' ' < "$p" 2>/dev/null; echo; done; sleep 0.05; done > /tmp/leak-check.log &
MONITOR_PID=$!
# ... run the real build here ...
kill "$MONITOR_PID"
grep -F "<the known test passphrase>" /tmp/leak-check.log   # MUST be empty
```

Check **both** the outer container-launch command (`docker run ...` /
`podman run ...`) and anything executed inside it (`su -c`, `sh -c`, a
`chroot`'d shell) — a fix that only closes one of those isn't done. Also
re-confirm the build still succeeds and the resulting package's signature
verifies against the test key — a secret-handling fix that breaks signing
isn't an acceptable trade.

## Things that have bitten this repo specifically

- Passing a secret as `-e VAR="$VAR"` to `docker run`/`podman run` puts
  the literal value in that process's own argv — pass the bare `-e VAR`
  (no `=value`) and `export VAR` beforehand instead, so the container
  runtime forwards the already-exported value without ever writing it
  into its own command line.
- `chown -R` on a directory containing a bind-mounted secret file (e.g. a
  private-key temp file) can silently change that file's ownership to
  whatever the container's UID maps to on the host, and a cleanup `shred`/`rm`
  can then fail with "Operation not permitted" — leaving key material
  behind in `/tmp`. If you add or move a bind mount, check what else lives
  in the same host directory that a broad `chown -R`/`chmod -R` might also
  touch.
- `run_in_container.sh`'s `--userns=keep-id` flag is Podman-specific and
  breaks under plain Docker — detect the runtime before passing
  runtime-specific flags.

## Audit-verified known issues (confirmed present)

**For the full narrative, verification methodology, and before/after
evidence behind every FIXED line below, see `AUDIT-HISTORY.md`.** This
section is deliberately just the current-state summary.

- **`rebuild_database()` never signed the package database — FIXED,
  root cause of `shani-repo`'s "unsigned package database" Critical
  finding.** `pkg/pkg-builder.sh`'s `rebuild_database()` ran bare
  `repo-add` with no signing step or GPG key material at all, even
  though `build_package()` already signs every individual package
  correctly — meaning every real publish silently regenerated an
  unsigned database. Fixed by mirroring `build_package()`'s exact
  GPG-import-then-sign mechanism. Verified end-to-end with a disposable
  test key standing in for the real CI secrets (never touched this
  session).
- **`StrictHostKeyChecking no` — FIXED.** `setup_ssh()` disabled
  GitHub host-key verification entirely. Now pins GitHub's real,
  currently-published host keys (fetched live from
  `api.github.com/meta`) and uses `StrictHostKeyChecking yes` — verified
  both a correct and a deliberately-wrong key behave as expected.
- **`eval source` of PKGBUILD (Med) — investigated, accepted as
  inherent to the Arch packaging model.** There is no way to read a
  PKGBUILD's `pkgname`/`pkgver`/etc. without executing it as shell
  (`makepkg`/`makepkg --printsrcinfo` do the same). The one avoidable
  injection vector (the PKGBUILD directory *name*) is already passed as
  a real positional argument, never interpolated. The residual risk is a
  compromised PKGBUILD's *content* running as `builduser` — see the next
  entry for why that residual risk is bigger than it looks.
- **`builduser` has unrestricted passwordless root via sudo — investigated
  in depth, deliberately NOT fixed with a scoped sudoers allowlist (needs
  a real architecture decision).** `docker/Dockerfile:40` grants
  `builduser ALL=(ALL) NOPASSWD: ALL`, so the "eval source of PKGBUILD"
  risk above isn't actually contained by running unprivileged — a
  malicious PKGBUILD can trivially `sudo` to full root. Enumerated every
  real `sudo <cmd>` call site across this repo and its consumers
  (`shani-pkgbuilds`, `shani-install-media`, `os-installer-config` — ~20
  binaries: `btrfs`, `chattr`, `chmod`, `chroot`, `cryptsetup`,
  `efibootmgr`, `mkdir`, `mkfs.btrfs`, `mkfs.fat`, `mount`, `pacman`,
  `parted`, `partprobe`, `sfdisk`, `swapon`, `tee`, `udevadm`, `umount`,
  `zstd`, `blockdev`, `losetup`) and confirmed **a scoped-by-binary-path
  sudoers allowlist would not actually contain this threat** — `chroot`
  and `pacman` are both genuinely required *and* each independently
  equivalent to unrestricted root (`sudo chroot / bash` is a root shell
  regardless of scoping; pacman's `.install` scriptlets run arbitrary
  code as root by design). Shipping a binary-name allowlist would look
  like a fix in the diff while providing false confidence. A real fix
  needs genuine VM-level isolation or a mediating privileged helper that
  validates exact arguments — a real architecture decision, not a code
  patch. See `AUDIT-HISTORY.md` for the full live-verification detail.
- **iptables-nft.** `docker/Dockerfile:22` installs `iptables-nft`.
- **CI status.** 4 CI workflows: `build-docker.yaml`, `build.yaml`,
  `build-image.yml`, `promote-stable.yml` with concurrency groups and
  timeouts (60/120/360/15 min).

## Cross-repo impact — check before calling a fix complete

This repo's Docker image is consumed by **two** other repos'
`run_in_container.sh` (`shani-install-media` and `shani-pkgbuilds` — those
are separate, duplicated copies of that script, not shared). A change here
— a new tool, a base-image bump, a permission change — can affect both
consumers differently; check both after any change, not just the one you
happened to be testing against.

## Where things are documented

`README.md` and `SECURITY.md` describe the intended secret-handling model
— if a change makes either untrue in practice (even if the code "looks"
like it matches), that's the regression to fix, not the documentation.
`AUDIT-HISTORY.md` has the full narrative behind every entry in
"Audit-verified known issues" above.
