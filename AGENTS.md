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

## Empirical verification (mandatory)

**Reading code is analysis; running code is verification.** A change is not
verified by reading the diff, running `bash -n`, or confirming it "looks
correct." It is verified by observing the actual behavior of the real
thing in the real environment — built, served, deployed, signed, running.
If you haven't seen it work (or fail) for real, it isn't verified.

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
- **A single temp file shared across many sequential `docker run` calls for
  secret material is not reliably reusable, even for reads.** Bit this repo
  twice: `rebuild_database()` originally reused `build_package()`'s
  `GPG_KEY_FILE`, and a container-side `chown -R builduser:builduser
  /home/builduser` (a real bind mount — this changes the actual host file's
  ownership, not a container-local copy) left it unreadable by the next
  writer. After giving `rebuild_database()` its own file, `build_package()`
  itself still intermittently failed the *same* way — 25 of 28 builds in
  one real run reused its own per-call file fine, 3 didn't — proving even a
  single function's own temp file isn't safe to treat as reusable across
  container invocations. The only fix that held: a genuinely fresh
  `mktemp`'d file on every single call, never touched by more than one
  `docker run`, cleaned up via a `RETURN` trap. If you're adding a new
  bind-mounted secret file, give it its own `mktemp` call per use — don't
  hoist it to a shared variable "for efficiency."

## Boundaries

- ✅ **Always**: give any new bind-mounted secret file its own fresh
  `mktemp` call per use, cleaned up via a `RETURN` trap — a shared/reused
  temp file has broken builds twice for reasons that looked unrelated on
  the surface (see "Things that have bitten this repo specifically").
- ⚠️ **Ask first**: scoping `builduser`'s passwordless sudo down to an
  allowlist — already investigated and found to provide false confidence
  (`chroot`/`pacman` are each independently equivalent to full root); a
  real fix needs a genuine architecture decision (VM isolation or a
  mediating privileged helper), not a quick sudoers patch.
- 🚫 **Never**: pass a secret as `-e VAR="$VAR"` to `docker run`/`podman
  run`, and never assume "the passphrase isn't in the command string
  anymore" is proof it doesn't leak — verify with the real `ps`/`/proc`
  polling harness above, every time, both the outer container-launch
  command and anything executed inside it.

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
- **CI status.** 8 workflow files: 5 build/publish — `build-docker.yaml`, `build.yaml`,
  `build-image.yml`, `promote-stable.yml` with concurrency groups and
  timeouts (60/120/360/15 min), and `build.yml` (docker-image build via
  `shani-ci-commons` `build.yml`) — plus 3 auxiliary helpers: `ai-ci-fixer.yml`
  (auto-retry on failed builds), `notify-telegram.yml` (manual-dispatch
  notification via `shani-ci-commons` `notify-telegram.yml`), and
  `metrics.yaml` (exports `pkg/build-metrics.sh` Prometheus metrics after
  the Build and Package run, daily cron, and manual dispatch). `build.yaml`
  also has `workflow_dispatch`
  now, so it can be triggered on demand (`gh workflow run "Build and
  Package"`), not just via the daily cron or a path-filtered push.
- **Shared temp GPG key file across sequential `docker run` calls — FIXED
  (twice).** `rebuild_database()` originally reused `build_package()`'s
  `GPG_KEY_FILE`; a bind-mounted `chown -R` inside one container run
  changed the real host file's ownership, breaking the next writer.
  Giving `rebuild_database()` its own file wasn't enough either —
  `build_package()`'s *own* per-call file still failed intermittently
  (25/28 real builds succeeded, 3/28 hit "Permission denied" on the exact
  same write). Fixed for real by making every `build_package()` call
  `mktemp` a brand-new file, never shared or reused, shredded via a
  `RETURN` trap. See `AUDIT-HISTORY.md` and the "Things that have bitten
  this repo" section above for the full detail.
- **`validpgpkeys` never imported before `makepkg` — FIXED.**
  `build_package()` had no mechanism to pre-import a PKGBUILD's
  `validpgpkeys` before running `makepkg`, so any package needing
  upstream GPG source verification (e.g. `game-devices-udev`) failed CI
  with "unknown public key" even when the PKGBUILD's `validpgpkeys` was
  completely correct — the builder image simply never had that key.
  Fixed by extracting `validpgpkeys` alongside the existing
  `pkgname`/`pkgver`/etc. metadata pull and importing each listed key from
  a keyserver before `makepkg` runs, generalized across any current or
  future package rather than special-cased to one.

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

## Garuda Cross-Reference Findings (added 2026-09-17)

Based on a full scan of 29 garuda-linux repos (see `../garuda-catalog.md`) mapped against shani (see `../shani-catalog.md`). Chaotic Manager (garuda) is the most directly comparable repo — both manage package building.

### 🟡 HIGH: Build pipeline gaps vs Chaotic Manager

Chaotic Manager has build orchestration features shani-builder lacks:

1. **Add build timeout wrapper** (estimated 2 hours).
   - Wrap `makepkg` calls with `timeout "${BUILD_TIMEOUT:-3600}"` to prevent hung builds from running indefinitely.
   - Chaotic Manager's builder has an `idle_timeout` watchdog that kills builds that become idle too long.
   - **Where**: `pkg/pkg-builder.sh` where makepkg is invoked.

2. **Add build metrics & observability** (estimated 1-2 days).
   - Chaotic Manager's `metrics.service.ts` tracks 15+ metrics: builds total/success/failed, build times (histogram), active/idle builders, queue depth.
   - Shani-builder has no build metrics, no build time tracking, no queue monitoring.
   - **Where**: New file `pkg/metrics.sh` or SQLite DB. Even simple tracking of builds attempted/succeeded/failed/times is an improvement.

3. **Add dependency-aware job scheduling** (estimated 1-2 days, future enhancement).
   - Chaotic Manager's coordinator uses a dependency graph (`constructDependencyGraph()`) to schedule packages after their dependencies, matches `build_class` to node capability, and auto-requeues on node disconnect.
   - Shani-builder processes sequentially or via CI triggers — no dependency graph.
   - **Where**: `pkg/pkg-builder.sh` or a new queue manager. Even a file-based queue (`/var/spool/shani-builder/queue.json`) with dependency checking would help.

4. **Activity watchdog for builds** (estimated 1 day).
   - Chaotic Manager collects container CPU/memory stats during builds and cancels builds that are idle too long. Stats are attached to build results for post-analysis.
   - **Where**: Around `makepkg` calls in `pkg-builder.sh`.

### 🟢 MEDIUM: CI/CD gap

5. **Shared CI templates** (estimated 2-3 days, affects ALL repos).
   - Garuda's `gitlab-ci-commons` provides reusable templates (commitizen, flake-check, pre-commit, tag-to-release). Each garuda repo `include:`s from it.
   - Shani repos run on GitHub Actions (no `.gitlab-ci.yml` anywhere) — 8 repos (blog, builder, docs, fleet, insights, install-media, pkgbuilds, platform) carry hand-written `.github/workflows/*.yml` with duplicated patterns.
   - **Action**: Create `shani-ci-commons` (GitHub Actions reusable workflows / composite actions) with templates for lint, test, build, security scan. Each repo references them via `uses: shani8dev/shani-ci-commons/...` instead of copy-pasting.
   - **Affects**: All 15 shani repos.

### ✅ What shani-builder already does better than Chaotic Manager

- Direct package signing and publishing to shani-repo (simpler than Chaotic Manager's SFTP upload pipeline)
- Real test harness via shani-install-media/test-env
- Security-conscious secret handling documentation (argv leak vectors documented)

### 🔍 Re-Scan Findings (2026-09-17)

Re-scanned against `../garuda-catalog.md` (29 actual garuda repos — garuda-builder, garuda-repo, garuda-pkgbuilds and others from the original 34-repo mapping do NOT exist).

**Confirmed mapping**: **chaotic-manager** (`garuda-clones/chaotic-manager/`) remains the primary counterpart — both manage package building — and the reference above is valid. Two additional actual repos are directly comparable: **chaotic-portable-builder** (`garuda-clones/chaotic-portable-builder/` — local/test builder using podman + Nix dev shell) and **buildiso-docker** (`garuda-clones/buildiso-docker/` — Docker image for building ISOs, mirrors shani-builder's `docker/` role).

**New gaps discovered** (chaotic-manager/buildiso-docker features shani-builder lacks):
1. **No Telegram/chat notifications** — chaotic-manager ships `telegram-bot.ts`; shani-builder has no build-result notification channel.
2. **No Redis-backed queue** — chaotic-manager uses BullMQ/Redis (`redis-connection-manager.ts`); shani-builder builds sequentially with no queue primitive.
3. **No automated PKGBUILD update checks** — chaotic-manager's CI runs half-hourly tag checks and auto-updates PKGBUILDs from AUR/GitLab; shani-builder has no source-drift detection.
4. **No Nix dev shell** — chaotic-portable-builder uses `shell.nix`/`nix develop` for a reproducible dev environment; shani-builder is Docker-only.
5. **No web UI/API** — chaotic-manager exposes an Express API on port 8080 with xterm terminal; shani-builder has no management interface.

**Shani advantages**:
1. **Direct package signing + publishing** — `pkg/pkg-builder.sh` signs every package and the database (`repo-add -s`) and pushes straight to `shani-repo`; simpler than chaotic-manager's SFTP upload pipeline.
2. **`validpgpkeys` pre-import** — builder imports each PKGBUILD's declared keys before `makepkg`; chaotic-manager doesn't document this.
3. **Per-call `mktemp` secret files** — every `build_package()` call gets a fresh temp file, shredded via `RETURN` trap; documented argv-leak verification methodology (see `AUDIT-HISTORY.md`).

### 📋 Implementation Roadmap (2026-09-17)

Implementation priorities are per `../IMPLEMENTATION-ROADMAP.md` (master roadmap for the whole shani ecosystem).

~~1. **Build Timeout Wrapper** (P0, ~2 hours) — Wrap `makepkg` calls with `timeout "${BUILD_TIMEOUT:-3600}"` in `pkg/pkg-builder.sh` to prevent hung builds from running indefinitely.~~ **DONE — closed 2026-09-17.** Installed `timeout "${BUILD_TIMEOUT:-3600}" makepkg -sc --noconfirm` at the single makepkg site in `pkg/pkg-builder.sh`, with exit-code-aware logging (`makepkg timed out after … (set BUILD_TIMEOUT)` on timeout exit 124; `makepkg failed (exit N)` otherwise) and `exit 1` to halt the build. GPG/SSH secret-handling paths (passphrase-via-stdin `--passphrase-fd 0`, `--detach-sign`) left byte-intact. Verified: `bash -n` clean; `bash tests/test-build-timeout.sh` 5/5 green (hung stub makepkg killed at 2s→exit 124 + timed-out log); source diff touches only the makepkg line. Chaotic Manager's `idle_timeout` watchdog parity confirmed.

2. **Activity Watchdog** (P1, ~1 day) — Kill builds that produce no stdout/stderr output for a configurable number of seconds, combining with the timeout wrapper above. Chaotic Manager collects container CPU/memory stats and cancels idle builds; a simpler `timeout`-based activity check on the makepkg output achieves the same practical result without Redis or a metrics backend. Source: IMPLEMENTATION-ROADMAP.md #4.

3. **Build Metrics & Observability** (P1, ~1-2 days) — Create `pkg/build-metrics.sh` writing to a SQLite database: `(pkgbase, status, start_time, end_time, error, commit_sha)`. Chaotic Manager's `metrics.service.ts` tracks 15+ metrics; even basic build-time/success/failure tracking answers "which package fails most" and "average build time" — questions currently unanswerable. Source: IMPLEMENTATION-ROADMAP.md #10.

4. **checkpkg Equivalent** (P1, ~1 day) — Create `pkg/checkpkg.sh` to verify a package build produces a working artifact before publishing to `shani-repo`. Builds a temp copy, downloads the previous version from the repo, compares file lists and sonames (`bsdtar tf` + `sdiff`). Adapts `garuda-tools/bin/checkpkg.in`'s pattern to shani's `pkg-builder.sh` pipeline. Source: IMPLEMENTATION-ROADMAP.md #11.

5. **Dependency-Aware Job Scheduling** (P2, ~1-2 weeks) — File-based queue at `/var/spool/shani-builder/queue.json` with a dependency graph parsed from PKGBUILD `depends=/makedepends=`. Captures ~30% of chaotic-manager's orchestration value at ~5% of the effort, using bash + jq only — no Redis, no TypeScript, no event bus. Source: IMPLEMENTATION-ROADMAP.md #14.

6. **Shared CI Templates, Renovate, Conventional Commits** (P1, cross-repo) — Create `shani-ci-commons` with reusable GitHub Actions workflow templates (lint, test, build, security scan). Add fleet-wide Renovate for automated dependency updates and commitizen for conventional commit enforcement. These affect all 15 shani repos; this repo's CI workflows (`build-docker.yaml`, `build.yaml`, `build-image.yml`, `promote-stable.yml`) would be the first consumers. Source: IMPLEMENTATION-ROADMAP.md #7, #8, #9.

7. **Docker Environment Secrets — ✅ AUDIT-VERIFIED CLEAN, CI grep step fixed (2026-09-18, closes master-roadmap #5)**. The pkg-builder Dockerfile was audited: `ENV` exposes only `BUILD_USER` + `GNUPGHOME`; the signing passphrase is passed via `-e` at `docker run` time and never baked into the image — no env-var→argv leak path found. **Keep** the `-e`-at-runtime pattern. Full argv-path audit of `pkg/pkg-builder.sh` (this repo has no separate `upload.sh` — `mirror_releases()` in `pkg-builder.sh` is the actual upload/release-mirror logic) found no new leak: `mirror_releases()`'s `SHANI_GH_REPO="$SHANI_GH_REPO" SHANI_GH_TOKEN="$SHANI_GH_TOKEN" python3 ...` is a bash `VAR=value` env-prefix, not a `docker -e VAR="$VAR"` argv leak — **verified live** via `/proc/<pid>/cmdline` that this shape never reaches any process's argv (only `/proc/<pid>/environ`, same-UID/root-only, same exposure as an already-exported var). **The CI grep step itself had a live, reproducible bug, found and fixed this pass**: `build.yaml`'s guard piped `grep -vE '^#' pkg/*.sh | grep -nE "$PAT"` (backreference pattern reading from a **pipe**), which false-positived on that exact `mirror_releases()` line — reproducibly, 5/5 runs, confirmed byte-content-identical input does NOT false-positive when the same backreference grep reads from a **file argument** instead of a pipe (a real GNU grep 3.11 backreference-matching quirk tied to input source, not to the file's content). This meant the "regression guard" would have failed every single real CI run once merged. Fixed by reordering: the backreference grep now runs directly on `pkg/*.sh` as file arguments first, with comment-filtering as a second, backreference-free stage on the (small) match output — verified by extracting and running both step scripts verbatim (via `python3 -c "import yaml; ..."` on the actual `build.yaml`) with real `/usr/bin/grep`, both before (reproducibly fails) and after (passes) the fix, plus a new regression-test line in the proof-hit step covering this exact false-positive shape.
