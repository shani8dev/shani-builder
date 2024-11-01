#!/bin/bash

# Get the directory of this script
work_dir="$(dirname "$(realpath "$0")")"

# Configuration variables for the ISO
dockerfile="${work_dir}/Dockerfile"  # Ensure this points to the correct Dockerfile
DOCKER_USERNAME="${DOCKER_USERNAME:-shrinivasvkumbhar}"  # Use environment variable or default value

# Fetch the latest base Docker image
docker pull archlinux:base-devel

# Build the Docker container
docker build --no-cache -f "${dockerfile}" -t shani-builder "${work_dir}"

# Tag the Docker image for Docker Hub
docker tag shani-builder "${DOCKER_USERNAME}/shani-builder:latest"

# Push the image to Docker Hub
docker push "${DOCKER_USERNAME}/shani-builder:latest"

