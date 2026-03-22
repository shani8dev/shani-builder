# shani-builder

The shared Docker build environment and package builder for [Shani OS](https://github.com/shani8dev). This repository serves two distinct purposes:

1. **`docker/`** — A privileged Arch Linux–based Docker image used as the build container by [shani-install-media](https://github.com/shani8dev/shani-install-media) for assembling system images and ISOs.
2. **`pkg/`** — An automated script that builds, signs, and publishes custom Arch packages to the [shani-repo](https://github.com/shani8dev/shani-repo) package repository.

## Repository Structure

```
├── docker/
│   ├── Dockerfile              # Build environment image definition
│   └── build-docker-image.sh   # Builds and pushes the image to Docker Hub
├── pkg/
│   └── pkg-builder.sh          # Automated package builder and publisher
├── LICENSE                     # GNU GPL v3
└── README.md
```

---

## Part 1: Docker Build Image

### What it contains

The Docker image (`shrinivasvkumbhar/shani-builder`) is built on `archlinux:base-devel` and pre-installs everything needed to build Shani OS images and ISOs:

- `archiso`, `arch-install-scripts`, `btrfs-progs` — base image and ISO assembly
- `shim-signed`, `sbsigntools`, `mokutil`, `mtools` — Secure Boot signing and EFI image manipulation
- `flatpak`, `snapd`, `squashfuse` — app image building
- `rclone`, `rsync`, `openssh` — artifact uploading
- `mktorrent`, `zsync` — torrent and zsync file generation
- `git`, `pacman-contrib` — package management
- `systemd`, `dbus` — required for Flatpak and chroot operations

It also:
- Imports the Shani OS signing key (`7B927BFFD4A9EAAA8B666B77DE217F3DA8014792`) from `keys.openpgp.org` and locally signs it
- Configures the custom `[shani]` pacman repository at `https://repo.shani.dev/x86_64`
- Installs `shani-keyring` and populates the Shani pacman keyring
- Creates a `builduser` account (`/home/builduser`) with passwordless sudo for non-root build steps
- Sets `GNUPGHOME=/home/builduser/.gnupg` and `WORKDIR /home/builduser/build`

### Building and pushing the image

```bash
cd docker/
./build-docker-image.sh
```

This pulls the latest `archlinux:base-devel`, builds with `--no-cache`, tags as `shrinivasvkumbhar/shani-builder:latest`, and pushes to Docker Hub.

Override the Docker Hub username if needed:

```bash
DOCKER_USERNAME=yourusername ./build-docker-image.sh
```

### Automated rebuild (GitHub Actions)

The workflow at `.github/workflows/build-docker.yaml` rebuilds and pushes the image on every push to `main`:

```yaml
# Requires these repository secrets:
# DOCKER_USERNAME  — Docker Hub username
# DOCKER_PASSWORD  — Docker Hub password or access token
```

---

## Part 2: Package Builder (`pkg-builder.sh`)

### What it does

`pkg-builder.sh` is a fully automated pipeline that:

1. Installs Docker on the host if not already present (supports Ubuntu/Debian, Arch, Fedora/RHEL)
2. Sets up a temporary SSH configuration from the provided private key
3. Clones (or hard-resets) [shani-pkgbuilds](https://github.com/shani8dev/shani-pkgbuilds) — the PKGBUILD sources
4. Clones (or hard-resets) [shani-repo](https://github.com/shani8dev/shani-repo) — the published package database
5. For each `PKGBUILD` found, checks whether the built package + signature already exist in the repo; skips if they do, otherwise builds inside the `shani-builder` Docker container
6. Signs each package with the provided GPG key using `gpg --detach-sign`
7. Moves the built `.pkg.tar.zst` and `.sig` files into the architecture directory
8. Removes old package versions whose name/version/release no longer match current PKGBUILDs
9. Runs `repo-add` to regenerate `shani.db` and `shani.files`
10. Commits and pushes all changes back to `shani-repo` via SSH

Supported architectures: `x86_64` → `./shani-repo/x86_64/`, `armv7l`/`aarch64` → `./shani-repo/arm/`.

### Usage

```bash
./pkg/pkg-builder.sh "$SSH_PRIVATE_KEY" "$GPG_PASSPHRASE" "$GPG_PRIVATE_KEY"
```

Or via environment variables (all three are required — the script exits immediately if any are unset):

```bash
export SSH_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----"
export GPG_PASSPHRASE="your-passphrase"
export GPG_PRIVATE_KEY="-----BEGIN PGP PRIVATE KEY BLOCK-----
...
-----END PGP PRIVATE KEY BLOCK-----"
./pkg/pkg-builder.sh
```

### Automated builds (GitHub Actions)

The workflow at `.github/workflows/build.yaml` runs daily at midnight UTC and on every push to `main`. It downloads `pkg-builder.sh` fresh from this repository on each run:

```yaml
# Requires these repository secrets:
# SSH_PRIVATE_KEY  — SSH key with write access to shani-pkgbuilds and shani-repo
# GPG_PASSPHRASE   — Passphrase for the GPG signing key
# GPG_PRIVATE_KEY  — Armored GPG private key for package signing
```

---

## GitHub Actions Secrets Summary

| Secret | Used by | Purpose |
|--------|---------|---------|
| `DOCKER_USERNAME` | `build-docker.yaml` | Docker Hub login |
| `DOCKER_PASSWORD` | `build-docker.yaml` | Docker Hub login |
| `SSH_PRIVATE_KEY` | `build.yaml` | Git push access to package repos |
| `GPG_PASSPHRASE` | `build.yaml` | Unlock GPG key for signing |
| `GPG_PRIVATE_KEY` | `build.yaml` | Armored GPG private key |

---

## Related Repositories

| Repository | Description |
|------------|-------------|
| [shani-install-media](https://github.com/shani8dev/shani-install-media) | ISO and system image build pipeline — consumes this Docker image |
| [shani-pkgbuilds](https://github.com/shani8dev/shani-pkgbuilds) | PKGBUILD sources for Shani OS custom packages |
| [shani-repo](https://github.com/shani8dev/shani-repo) | Published Arch-compatible package repository |

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
