#!/bin/bash

set -euo pipefail

# Get the directory of this script
work_dir="$(dirname "$(realpath "$0")")"

# Define your custom fast mirror
CUSTOM_MIRROR="https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch"

# Create volumes for pacman cache
CACHE_DIR="${work_dir}/cache/pacman_cache"

# Ensure the necessary directories exist
mkdir -p "$CACHE_DIR"

# Docker image for the builder
DOCKER_IMAGE="shrinivasvkumbhar/shani-builder"

# Run the build process inside the container
docker run -it --privileged --rm \
    -v "${work_dir}:/builduser/build" \
    -v "$CACHE_DIR:/var/cache/pacman" \
    "$DOCKER_IMAGE" bash -c "
        sed -i 's|^Server = .*|Server = $CUSTOM_MIRROR|' /etc/pacman.d/mirrorlist && \
        cd /builduser/build && \
        ./build-image.sh -p gnome
    "

