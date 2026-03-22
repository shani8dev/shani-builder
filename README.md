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
├── .github/
│   └── workflows/
│       ├── build-docker.yaml   # Rebuilds and pushes the Docker image on changes
│       └── build.yaml          # Builds and publishes packages daily
├── LICENSE                     # GNU GPL v3
└── README.md
```

---

## Part 1: Docker Build Image

### What it contains

The Docker image (`shrinivasvkumbhar/shani-builder`) is built on `archlinux:base-devel` and pre-installs everything needed to build Shani OS images and ISOs:

| Category | Packages |
|----------|----------|
| Image & ISO assembly | `archiso`, `arch-install-scripts`, `btrfs-progs` |
| Secure Boot | `shim-signed`, `sbsigntools`, `mokutil`, `mtools` |
| App images | `flatpak`, `snapd`, `squashfuse` |
| Uploads | `rclone`, `rsync`, `openssh` |
| Release files | `mktorrent`, `zsync` |
| Package management | `git`, `pacman-contrib` |
| Container runtime | `systemd`, `dbus` |

The image also:
- Initialises the pacman keyring, imports the Shani OS signing key (`7B927BFFD4A9EAAA8B666B77DE217F3DA8014792`) from `keys.openpgp.org`, and locally signs it
- Adds the `[shani]` custom pacman repository at `https://repo.shani.dev/x86_64` to `/etc/pacman.conf`
- Installs `shani-keyring` and populates the Shani pacman keyring
- Creates a `builduser` account (`/home/builduser`) with passwordless sudo for non-root build steps
- Imports the Shani signing public key into `/home/builduser/.gnupg` **as `builduser`** — this ensures build scripts that call `gpg --homedir /home/builduser/.gnupg` actually find the key
- Sets `GNUPGHOME=/home/builduser/.gnupg` and `WORKDIR /home/builduser/build`

The entire setup is done in two `RUN` layers (keyring+packages, then user+key) to avoid intermediate layers with a half-updated package database, which can cause pacman signature verification errors on cache hits.

### Building and pushing the image

```bash
cd docker/
./build-docker-image.sh
```

This pulls the latest `archlinux:base-devel`, builds with `--no-cache`, and tags + pushes three variants to Docker Hub:

```bash
DOCKER_USERNAME=yourusername ./build-docker-image.sh
```

| Tag | Source |
|-----|--------|
| `:latest` | Always |
| `:<YYYYMMDD>` | Today's date |
| `:<short-sha>` | `git rev-parse --short HEAD` (falls back to date if not in a repo) |

### Automated rebuild (GitHub Actions)

The workflow at `.github/workflows/build-docker.yaml` triggers on any push to `main` that touches `docker/Dockerfile`, `docker/build-docker-image.sh`, or the workflow file itself. It uses `docker/build-push-action` with registry-based layer caching to avoid re-downloading Arch packages on every rebuild.

The image is tagged three ways on each push:

| Tag | Example | Purpose |
|-----|---------|---------|
| `:latest` | `shani-builder:latest` | Always points to the most recent build |
| `:<YYYYMMDD>` | `shani-builder:20260320` | Date-stamped — pull any historical build |
| `:<short-sha>` | `shani-builder:a1b2c3d4` | Commit-pinned — reproducible rollback |

```yaml
# Requires these repository secrets:
# DOCKER_USERNAME  — Docker Hub username
# DOCKER_PASSWORD  — Docker Hub password or access token
```

---

## Part 1b: Install Media Build Workflow (`build-image.yml`)

This repository also hosts the GitHub Actions workflow that drives [shani-install-media](https://github.com/shani8dev/shani-install-media) builds. It lives at `.github/workflows/build-image.yml` and runs on a schedule (every Friday at 20:30 UTC) or via manual `workflow_dispatch`.

### What the workflow does

1. Frees disk space on the runner (removes Android SDK, .NET, GHC, etc.)
2. Checks out `shani-install-media`
3. **Writes MOK keys** to `shani-install-media/keys/mok/` from secrets:
   ```yaml
   - name: Setup MOK keys
     run: |
       mkdir -p shani-install-media/keys/mok
       echo "${{ secrets.MOK_KEY }}"                    > shani-install-media/keys/mok/MOK.key
       echo "${{ secrets.MOK_CRT }}"                    > shani-install-media/keys/mok/MOK.crt
       echo "${{ secrets.MOK_DER_B64 }}" | base64 --decode > shani-install-media/keys/mok/MOK.der
   ```
4. In `image` mode (default + scheduled): runs `image` → `release latest` → `upload image`
5. In `full` mode (manual only): runs `build.sh full` — the complete pipeline including ISO, repack, and `upload all`
6. **Verifies the uploaded artifact** on SourceForge — fetches the `.sha256`, checks it matches the local file. The job fails if verification fails.
7. Optionally runs `promote-stable` if `promote_stable` input is `true`

### `workflow_dispatch` inputs

| Input | Default | Description |
|-------|---------|-------------|
| `profile` | _(empty — builds all)_ | Override to build a single profile, e.g. `gnome` |
| `build_mode` | `image` | `image` = base image only; `full` = image + flatpak + iso + repack |
| `promote_stable` | `false` | If `true`, runs `promote-stable` after upload |

### Required secrets for `build-image.yml`

| Secret | Purpose |
|--------|---------|
| `MOK_KEY` | RSA-2048 PEM private key for Secure Boot EFI signing |
| `MOK_CRT` | X.509 PEM certificate paired with `MOK_KEY` |
| `MOK_DER_B64` | Base64-encoded DER certificate — embedded in the ISO for end-user enrollment |
| `GPG_PRIVATE_KEY` | Armored GPG private key for signing `.zst` and ISO artifacts |
| `GPG_PASSPHRASE` | Passphrase to unlock the GPG key |
| `GPG_KEY_ID` | Full 40-char GPG fingerprint |
| `SSH_PRIVATE_KEY` | ED25519 key for `rsync` uploads to SourceForge |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key ID _(optional)_ |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret access key _(optional)_ |
| `R2_ACCOUNT_ID` | Cloudflare account ID, 32-char hex _(optional)_ |
| `R2_BUCKET` | R2 bucket name _(optional)_ |

MOK and GPG keys are generated by the scripts in [shani-install-media/keys/](https://github.com/shani8dev/shani-install-media/tree/main/keys). See the [shani-install-media README](https://github.com/shani8dev/shani-install-media#key-management) for generation instructions.

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
11. Reports all failed packages at the end and exits non-zero so CI shows a red run — individual build failures do not abort the remaining packages

Supported architectures: `x86_64` → `./shani-repo/x86_64/`, `armv7l`/`aarch64` → `./shani-repo/arm/`.

### Usage

Credentials are read exclusively from environment variables — **do not pass them as positional arguments**, as those appear in `ps aux` output and the runner process list:

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

A `trap ... EXIT` at the top of the script ensures `gpg-private.key` and the temporary SSH key file are always removed — even if the script exits mid-build due to an error — so private key material is never left on disk.

### Automated builds (GitHub Actions)

The workflow at `.github/workflows/build.yaml` runs daily at midnight UTC and on every push to `main`. It downloads `pkg-builder.sh` fresh from this repository on each run so the latest version of the script is always used — no stale cached copy. Secrets are passed via an `env:` block and `sudo --preserve-env` rather than as positional shell arguments.

```yaml
# Requires these repository secrets:
# SSH_PRIVATE_KEY  — SSH key with write access to shani-pkgbuilds and shani-repo
# GPG_PASSPHRASE   — Passphrase for the GPG signing key
# GPG_PRIVATE_KEY  — Armored GPG private key for package signing
```

---

## GitHub Actions Secrets Summary

| Secret | Workflow | Purpose |
|--------|----------|---------|
| `DOCKER_USERNAME` | `build-docker.yaml` | Docker Hub login username |
| `DOCKER_PASSWORD` | `build-docker.yaml` | Docker Hub password or access token |
| `SSH_PRIVATE_KEY` | `build.yaml`, `build-image.yml` | Package repo git push; SourceForge rsync uploads |
| `GPG_PASSPHRASE` | `build.yaml`, `build-image.yml` | Unlock GPG key for signing |
| `GPG_PRIVATE_KEY` | `build.yaml`, `build-image.yml` | Armored GPG private key for signing |
| `GPG_KEY_ID` | `build-image.yml` | Full 40-char GPG fingerprint for artifact signing |
| `MOK_KEY` | `build-image.yml` | RSA-2048 PEM private key for Secure Boot EFI signing |
| `MOK_CRT` | `build-image.yml` | X.509 PEM certificate for Secure Boot |
| `MOK_DER_B64` | `build-image.yml` | Base64 DER certificate embedded in the ISO |
| `R2_ACCESS_KEY_ID` | `build-image.yml` | Cloudflare R2 access key _(optional)_ |
| `R2_SECRET_ACCESS_KEY` | `build-image.yml` | Cloudflare R2 secret key _(optional)_ |
| `R2_ACCOUNT_ID` | `build-image.yml` | Cloudflare account ID _(optional)_ |
| `R2_BUCKET` | `build-image.yml` | R2 bucket name _(optional)_ |

---

## Related Repositories

| Repository | Description |
|------------|-------------|
| [shani-install-media](https://github.com/shani8dev/shani-install-media) | ISO and system image build pipeline — consumes this Docker image |
| [shani-pkgbuilds](https://github.com/shani8dev/shani-pkgbuilds) | PKGBUILD sources for Shani OS custom packages |
| [shani-repo](https://github.com/shani8dev/shani-repo) | Published Arch-compatible package repository (`https://repo.shani.dev`) |

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
