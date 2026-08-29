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
- **`StrictHostKeyChecking no`.** `pkg/pkg-builder.sh:113` disables SSH host key
  checking in the generated SSH config, exposing package publish to SSH MITM.
  Use `accept-new` instead.

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
