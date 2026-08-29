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
