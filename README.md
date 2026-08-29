# shani-builder

The shared Docker build environment and package builder for [Shanios](https://github.com/shani8dev). This repository serves two distinct purposes:

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
│       ├── build.yaml          # Builds and publishes packages daily
│       ├── build-image.yml     # Builds/releases/uploads shani-install-media OS images and ISOs
│       └── promote-stable.yml  # Promotes the latest build to the stable channel
├── LICENSE                     # GNU GPL v3
└── README.md
```

---

## Part 1: Docker Build Image

### What it contains

The Docker image (`shrinivasvkumbhar/shani-builder`) is built on `archlinux:base-devel` and pre-installs everything needed to build Shanios images and ISOs:

| Category | Packages |
|----------|----------|
| Image & ISO assembly | `archiso`, `arch-install-scripts`, `btrfs-progs` |
| Secure Boot | `shim-signed`, `sbsigntools`, `mokutil`, `mtools` |
| App images | `flatpak`, `snapd`, `squashfuse` |
| Uploads | `rclone`, `rsync`, `openssh` |
| Release files | `mktorrent`, `zsync`, `zsync2` (generates `.zsync` control files for differential updates — see shani-deploy) |
| Package management | `git`, `pacman-contrib` |
| Container runtime | `systemd`, `dbus` |
| Firewall / networking | `iptables-nft` |

The image also:
- Initialises the pacman keyring, imports the Shanios signing key (`7B927BFFD4A9EAAA8B666B77DE217F3DA8014792`) from `keys.openpgp.org`, and locally signs it
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

The workflow at `.github/workflows/build-docker.yaml` triggers on any push to `main` that touches anything under `docker/` or the workflow file itself. It uses `docker/build-push-action` with registry-based layer caching to avoid re-downloading Arch packages on every rebuild.

Concurrency group: `docker-build` (in-progress runs are not cancelled, so a half-built image is never pushed). Job timeout: 60 minutes.

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

Concurrency group: `image-build` (in-progress runs are not cancelled). Job timeout: 360 minutes.

### What the workflow does

1. Frees disk space on the runner (removes Android SDK, .NET, GHC, etc.)
2. Checks out `shani-install-media`
3. **Writes MOK keys** to `shani-install-media/keys/mok/` from secrets:
   ```yaml
   - name: Setup MOK keys
     run: |
       mkdir -p shani-install-media/keys/mok
       printf '%s\n' "${{ secrets.MOK_KEY }}"  > shani-install-media/keys/mok/MOK.key
       printf '%s\n' "${{ secrets.MOK_CRT }}"  > shani-install-media/keys/mok/MOK.crt
       printf '%s\n' "${{ secrets.MOK_DER_B64 }}" | base64 --decode > shani-install-media/keys/mok/MOK.der
   ```
4. **Exports the GPG public key** into an isolated `GNUPGHOME`, so `run_in_container.sh` can copy it into the image/ISO at build time — the import never touches the runner's own keyring and is discarded when the step exits.
5. In `all` mode (default + scheduled): runs `run_in_container.sh build.sh all -p <profile>` — image + release + upload in one step.
6. In `full` mode (manual only): runs `build.sh full` — the complete pipeline including ISO, repack, and `upload all`.
7. **Verifies the uploaded artifact** — the job fails if verification fails.

Promotion to the stable channel is a **separate workflow**
(`promote-stable.yml`), not a step of this one — see below.

### `workflow_dispatch` inputs

| Input | Default | Description |
|-------|---------|-------------|
| `profile` | _(empty — builds all)_ | Override to build a single profile, e.g. `gnome` |
| `build_mode` | `all` | `all` = image + release + upload; `full` = all + iso + repack + upload all |

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

## Part 1c: Stable Promotion (`promote-stable.yml`)

A separate workflow from `build-image.yml` — promoting a build to the
stable channel is a distinct action, not an automatic step after a build
finishes. Runs on a schedule (Saturday 20:30 UTC — one day after
`build-image.yml`'s Friday build) or via manual `workflow_dispatch`.

Concurrency group: `promote-stable` (in-progress runs are not cancelled). Job timeout: 15 minutes.

### `workflow_dispatch` inputs

| Input | Default | Description |
|-------|---------|-------------|
| `profile` | _(required)_ | `all` (= gnome + plasma), `gnome`, `plasma`, or `cosmic` |

### What it does

Checks out `shani-install-media` and runs
`run_in_container.sh build.sh promote-stable -p <profile>` for each
profile in the resolved matrix (the scheduled trigger always promotes
`gnome` + `plasma`; manual dispatch honors the `profile` input).

### Required secrets

| Secret | Purpose |
|--------|---------|
| `SSH_PRIVATE_KEY` | ED25519 key for `rsync`/upload operations |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key ID |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret access key |
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_BUCKET` | R2 bucket name |

Unlike `build-image.yml`, this workflow doesn't need the MOK/GPG signing
secrets — it promotes an already-built, already-signed artifact rather
than producing a new one.

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

Credits are read exclusively from environment variables — **do not pass them as positional arguments**, as those appear in `ps aux` output and the runner process list. Also: do **not** pass secrets via `docker run -e VAR="$VAR"` or `podman run -e VAR="$VAR"` — the literal value enters the container runtime's own argv. Pass the bare `-e VAR` (no `=value`) with the value exported beforehand.

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

A `trap ... EXIT` at the top of the script ensures the randomized temp GPG key file (`shred`-deleted, `mktemp /tmp/shani-gpg-XXXXXX.asc`) and the temporary SSH key directory are always removed — even if the script exits mid-build due to an error — so private key material is never left on disk.

### Automated builds (GitHub Actions)

The workflow at `.github/workflows/build.yaml` runs daily at midnight UTC, on any push to `main` that touches `pkg/pkg-builder.sh` or the workflow file itself, and on demand via `workflow_dispatch` (`gh workflow run "Build and Package"` or the Actions tab's "Run workflow" button) — useful for verifying a fix without waiting for the next cron tick or a qualifying push. It checks out this repository fresh on each run (`actions/checkout@v4`) so the latest version of the script is always used — no stale cached copy. Secrets are passed via an `env:` block and `sudo --preserve-env` rather than as positional shell arguments.

Concurrency group: `pkg-build` (in-progress runs are not cancelled, preventing two builds from writing to shani-repo simultaneously). Job timeout: 120 minutes.

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
| [shani-pkgbuilds](https://github.com/shani8dev/shani-pkgbuilds) | PKGBUILD sources for Shanios custom packages |
| [shani-repo](https://github.com/shani8dev/shani-repo) | Published Arch-compatible package repository (`https://repo.shani.dev`) |

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
