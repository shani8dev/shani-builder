# Security Policy

## Trust Model

`shani-builder` is the shared Docker build environment and package publisher for
Shanios. It signs every package and OS image the ecosystem ships. The trust
model is:

- **GPG passphrase never enters process argv.** The passphrase is passed into
  the container as a bare `-e GPG_PASSPHRASE` env var name (no `=value`), with
  the value exported beforehand. The container runtime forwards the already-
  exported value without ever writing it into its own command line.
- **Key files are restrictive.** Private key files are `chmod 600`; containing
  directories are `chmod 700`.
- **Runtime detection.** `run_in_container.sh` detects Docker vs Podman before
  passing runtime-specific flags (e.g., `--userns=keep-id` is Podman-only).

## Key Security Mechanisms

| Mechanism | Implementation |
|-----------|----------------|
| Passphrase handling | Bare `-e GPG_PASSPHRASE` to container; value exported in parent shell (`pkg/pkg-builder.sh:25-28,249-266`) |
| Key file permissions | `chmod 600` on private keys; `chmod 700` on `.gnupg` |
| Container runtime check | Detects Docker vs Podman before passing `--userns=keep-id` |

## Known Limitations

- **Outer `docker run` argv verification.** The AGENTS.md documents that secret
  leakage via `docker run -e VAR="$VAR"` was found **twice** (inner `su -c`
  argv, then outer `docker run` argv). The current fix addresses the inner path;
  the outer path must be verified with a `ps`/`/proc` polling loop during a
  real build to confirm the literal passphrase never appears in any process's
  cmdline.
- **`builduser` has unrestricted passwordless root via sudo.**
  `docker/Dockerfile`'s `builduser ALL=(ALL) NOPASSWD: ALL` means a
  compromised PKGBUILD (this repo's `eval source` of PKGBUILD content is
  otherwise unavoidable — see `AGENTS.md`) isn't actually contained by
  running as an unprivileged user. Investigated in depth and deliberately
  **not** fixed with a scoped sudoers allowlist — `chroot` and `pacman`
  are both genuinely required and each independently equivalent to
  unrestricted root regardless of allowlisting. See `AGENTS.md`'s
  "Audit-verified known issues" and `AUDIT-HISTORY.md` for the full
  reasoning; a real fix needs VM-level isolation or a mediating
  privileged helper, not a code patch.

**Already fixed, kept here only so this file doesn't silently drift from
reality** (see `AGENTS.md`/`AUDIT-HISTORY.md` for verification detail):
`StrictHostKeyChecking no` now pins GitHub's real host keys and uses
`StrictHostKeyChecking yes`; `rebuild_database()` now signs the package
database using the same mechanism as individual packages; every
GPG-signing-key temp file used inside a `docker run` (both in
`build_package()` and `rebuild_database()`) is a fresh `mktemp` per call,
never shared across container invocations, after a shared file proved
intermittently unwritable following a bind-mounted `chown -R`.

## Reporting a Vulnerability

If you discover a security vulnerability in any Shanios project, please report it
responsibly by opening a private security advisory on GitHub.

Please include:
- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 72 hours and provide a detailed response
within 7 days. Thank you for helping keep Shanios secure.
