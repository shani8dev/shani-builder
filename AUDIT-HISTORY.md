# shani-builder — audit/fix history

This file is the full narrative behind every entry in `AGENTS.md`'s
"Audit-verified known issues" section — the verification methodology,
before/after evidence, and reasoning for each fix. **Read `AGENTS.md`
first** — that file is the current-state summary; this one is why and how.

This file is append-only in spirit: when `AGENTS.md`'s summary is updated
for a new fix, the full narrative for that fix should land here, not
inflate the main file back to unreadable length.

---

- **`rebuild_database()` never signed the package database — FIXED, root
  cause of `shani-repo`'s "unsigned package database" Critical finding.**
  Was: `pkg/pkg-builder.sh:372` ran bare `repo-add shani.db.tar.gz
  *.pkg.tar.zst` with no `-s`/signing step and no GPG key material even
  bind-mounted into that specific `docker run` — meaning every real
  publish run regenerated an unsigned database, even though
  `build_package()` (a few functions above, in the same file) already
  signs every individual package correctly. Found while actually fixing
  the symptom in `shani-repo` (locally signed the existing `shani.db`/
  `shani.files` there with the real key, then realized the automated
  pipeline would just regenerate an unsigned one on the next run — see
  that repo's `AGENTS.md`). Fixed by mirroring `build_package()`'s exact
  GPG-import mechanism in `rebuild_database()`: writes `GPG_PRIVATE_KEY`
  to `GPG_KEY_FILE` explicitly (not relying on a prior `build_package()`
  call having populated it this run — `rebuild_database()` can run even
  when every package was already built and skipped), bind-mounts it in,
  imports via `--batch --pinentry-mode loopback --passphrase-fd 0`, then
  binary-detached-signs `shani.db.tar.gz`/`shani.files.tar.gz` the same
  way individual packages are signed, and copies the resulting `.sig`
  files alongside the `shani.db`/`shani.files` copies this function
  already creates. **Verified for real, end-to-end**: this session
  correctly never had access to the real CI `GPG_PRIVATE_KEY`/
  `GPG_PASSPHRASE` secrets and didn't try to obtain them — instead
  generated a disposable throwaway GPG key with a known passphrase,
  substituted it for the real secrets, and ran the actual (fixed)
  `rebuild_database()` function against a scratch copy of every real
  `.pkg.tar.zst` currently in `shani-repo`. The full real code path ran
  clean end-to-end (`repo-add` → GPG import → sign → copy), and the
  resulting `.sig` files verified as "Good signature" against the test
  key. This exercises the exact mechanism that will run with the real
  secrets in CI, without this session ever touching them.
- **`StrictHostKeyChecking no` — FIXED.** `pkg/pkg-builder.sh`'s
  `setup_ssh()` disabled host-key verification entirely for
  `github.com` — real MITM risk on a script that clones/pushes with a
  private deploy key. Fixed by pinning github.com's real, currently-published
  host keys (fetched live from GitHub's own `https://api.github.com/meta`
  `ssh_keys` field, not hand-copied) into a `known_hosts` file and switching
  to `StrictHostKeyChecking yes`. Verified both directions live: connecting
  with the pinned keys gets exactly as far as "Permission denied
  (publickey)" — proving the host key itself was accepted, not that
  checking was silently skipped — while connecting with a deliberately
  wrong key correctly fails closed with "Host key verification failed."
  before authentication is even attempted.
- **`eval source` of PKGBUILD (Med) — investigated, accepted as inherent
  to the Arch packaging model.** `pkg/pkg-builder.sh:~158,~226` sources a
  PKGBUILD's content directly (inside `bash -c`) to read `pkgname`/
  `pkgver`/`pkgrel`/`arch` — there's no way to extract these fields from a
  PKGBUILD without executing it as a shell script (`makepkg` itself, and
  `makepkg --printsrcinfo`, do the exact same thing — there is no
  non-executing PKGBUILD parser). Both call sites already use the one
  actually-avoidable injection-prevention pattern: the untrusted piece
  (the PKGBUILD's *directory name*) is passed as a real positional
  argument (`bash -c '...' _ "${pkgbuild_dir}"`), never interpolated into
  the script string — confirmed by reading both sites; a malicious
  directory *name* can't break out. The residual risk is genuinely
  different: a compromised **PKGBUILD's content** (a supply-chain
  compromise of `shani-pkgbuilds`) runs arbitrary code as `builduser` when
  sourced. No fix applied here (there's no non-executing alternative to
  offer), but see the next entry — the real blast radius of that residual
  risk turned out to be much larger than "just builduser."
- **`builduser` has unrestricted passwordless root via sudo — new finding,
  not previously documented, not fixed here (needs a human decision).**
  `docker/Dockerfile:40`: `echo 'builduser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers`.
  This means the "eval source of PKGBUILD" risk above isn't actually
  contained by running as an unprivileged user at all — any code that runs
  as `builduser` (a malicious PKGBUILD included) can trivially `sudo` to
  full root with no password, inside a container that (per this file's own
  secret-handling rules above) also handles `GPG_PASSPHRASE`/
  `SSH_PRIVATE_KEY`. A real fix would scope sudoers to the specific
  commands the pipeline actually needs (`pacman -Sy`, mount operations,
  etc. — `shani-pkgbuilds/make_pkg.sh` alone calls `sudo pacman -Sy
  --noconfirm`), but that requires enumerating every legitimate `sudo`
  call site across this repo AND its consumers
  (`shani-pkgbuilds`/`shani-install-media`'s `run_in_container.sh`
  invocations) to build a safe allowlist — a cross-repo behavioral change
  risking silently breaking a currently-working pipeline if the allowlist
  is incomplete, not something to narrow unilaterally in one pass.
  **Actually did that enumeration in a later pass** (grepped every real
  `sudo <cmd>` call site across `shani-pkgbuilds`, `shani-install-media`,
  and `os-installer-config` — the ~20 binaries genuinely invoked are
  `btrfs`, `chattr`, `chmod`, `chroot`, `cryptsetup`, `efibootmgr`,
  `mkdir`, `mkfs.btrfs`, `mkfs.fat`, `mount`, `pacman`, `parted`,
  `partprobe`, `sfdisk`, `swapon`, `tee`, `udevadm`, `umount`, `zstd`,
  `blockdev`, `losetup`) — and concluded a scoped-by-binary-path sudoers
  allowlist would **not** actually contain this threat model, so
  deliberately didn't implement one. Confirmed live in this exact
  container: `chroot` is genuinely required (`configure.sh`'s whole job
  is chrooting into the target as root), but `sudo chroot / bash` with
  that binary NOPASSWD-allowed is just a full root shell — chrooting to
  `/` changes nothing. `pacman` is also genuinely required
  (`make_pkg.sh`'s `sudo pacman -Sy`), but pacman's `.install` scriptlets
  run arbitrary code as root by design during `-U`/`-S` — a well-known,
  intentional Arch packaging feature, not a bug to work around. Both
  binaries are independently equivalent to unrestricted root regardless
  of sudoers scoping, and both are things this pipeline legitimately
  cannot function without. A binary-name allowlist would look like a
  real fix in the diff while providing false confidence — it would block
  `sudo bash` directly but do nothing against `sudo chroot / bash` or a
  malicious PKGBUILD's `.install` hook, which is exactly the scenario
  this finding is about. A real fix needs something structurally
  different — genuine VM-level isolation instead of a shared-kernel
  container, or moving privileged operations to a separate mediating
  helper process that validates exact arguments rather than trusting
  whatever `builduser` asks `sudo` to run — which is a real architecture
  decision, not a code patch to attempt blind. Still flagging for a
  deliberate human follow-up, now with the concrete reason a "just scope
  sudoers" fix wouldn't actually work.
- **iptables-nft.** `docker/Dockerfile:22` installs `iptables-nft`.
- **CI status.** 4 CI workflows: `build-docker.yaml`, `build.yaml`,
  `build-image.yml`, `promote-stable.yml` with concurrency groups and
  timeouts (60/120/360/15 min).
- **`rebuild_database()` "Permission denied" on its GPG key temp file —
  FIXED, found live in a real CI run.** Triggered by a real production
  incident: a `git merge` of `shani-repo` had put a mismatched database
  signature into the live repo (see `shani-repo/AGENTS.md` for that side
  of the story), so `pkg-builder.sh` needed to actually run
  `rebuild_database()` for real to regenerate it. That run failed after
  25 successful package builds with "Permission denied" writing to
  `GPG_KEY_FILE` — the same global temp file `build_package()` had
  already bind-mounted into 25 prior `docker run` invocations, each of
  which runs `chown -R builduser:builduser /home/builduser` inside the
  container. Since the bind mount means that `chown -R` changes the
  REAL HOST FILE's ownership (not a container-local copy), the file ended
  up owned by `builduser`'s host-mapped UID, unwritable by the actual
  script process. Fixed by giving `rebuild_database()` its own dedicated
  `DB_GPG_KEY_FILE` (`mktemp`'d fresh, `chmod 600`, shredded via the
  existing `cleanup()` trap), never touched by any `build_package()`
  container run.
- **The same class of bug recurring intermittently inside
  `build_package()` itself — FIXED.** After the fix above, a subsequent
  real run (28 packages) hit the *identical* "Permission denied" on
  `build_package()`'s *own* per-function `GPG_KEY_FILE` write — but only
  for 3 of the 28 builds; the other 25 reused the same file successfully.
  This proved the failure is racy/non-deterministic, not a one-time
  mutation from a single earlier call — a shared file reused across many
  sequential privileged container invocations was never actually safe,
  it just usually got lucky. Fixed by giving *every single*
  `build_package()` call its own fresh, `mktemp`'d, never-before-touched
  file (`pkg_gpg_key_file`), removing the old shared global entirely
  (confirmed dead via `grep`), cleaned up via a `trap ... RETURN` covering
  every return path (including the two early `return 1`s), plus a
  catch-all `find /tmp -maxdepth 1 -name 'shani-gpg-pkg-*.asc'` sweep in
  `cleanup()` for defense in depth. Verified by a subsequent real,
  complete CI run (`33265684214`) with **zero** "Permission denied"
  errors across every package built, proving both fixes fully closed the
  issue before moving on to unrelated PKGBUILD-level failures.
- **`validpgpkeys` never pre-imported before `makepkg` — FIXED.** The same
  clean run above still had 3 unrelated failures, one of which
  (`game-devices-udev`) failed with "unknown public key
  D6A4F386B4881229" even though `game-devices-udev/PKGBUILD`'s
  `validpgpkeys=('6E58E886A8E07538A2485FAED6A4F386B4881229')` already
  listed exactly that fingerprint (confirmed: the CI error's 16 trailing
  hex chars match the tail of the listed 40-char fingerprint exactly) —
  the problem was never the PKGBUILD, it was that nothing in
  `pkg-builder.sh` or `docker/Dockerfile` ever imports a PKGBUILD's
  `validpgpkeys` into the builder's keyring; only the one Shanios
  project-signing key is pre-imported at image-build time. Fixed
  generally rather than special-casing this one package: `build_package()`
  now also extracts `validpgpkeys[*]` from the sourced PKGBUILD (same
  `bash -c` metadata pull used for `pkgname`/`pkgver`/etc.), passes it
  into the container as `-e PGP_KEYS`, and imports each listed key from
  `keyserver.ubuntu.com` (falling back to `hkps://keys.openpgp.org`)
  before `makepkg` runs. Verified the tricky nested quoting (the
  container script is itself embedded in a host-level single-quoted
  string, and further passes a sub-script to `su -c` as a *second*
  layer of quoting) by reconstructing the exact same nesting locally
  with stubbed `pacman`/`chown` and dummy env vars, capturing what the
  constructed inner script actually evaluates to, and confirming it
  parses as valid bash with `$PGP_KEYS`/`$key` correctly deferred to the
  `su`-spawned shell rather than expanded too early — a plain top-level
  `bash -n` on the outer script would not have caught an escaping bug at
  that depth. **All three fixes confirmed together in one real CI run**
  (`33266570244`, triggered on the push containing this fix plus the
  `foo2zjs-nightly`/`shani-desktop-cosmic` PKGBUILD fixes in
  `shani-pkgbuilds` — see that repo's `AGENTS.md`): completed green in
  3m50s (short because every already-built package was correctly
  skipped, leaving only the 3 previously-failing ones to build), and
  `shani-repo` now has real, signed artifacts for all three
  (`foo2zjs-nightly-20201127-2`, `game-devices-udev-1.0-1`,
  `shani-desktop-cosmic-1.0-6`).
