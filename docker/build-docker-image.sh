#!/bin/bash
set -euo pipefail

work_dir="$(dirname "$(realpath "$0")")"
dockerfile="${work_dir}/Dockerfile"
DOCKER_USERNAME="${DOCKER_USERNAME:-shrinivasvkumbhar}"

DATE=$(date +%Y%m%d)
# Use the current git commit SHA if inside a repo, otherwise fall back to the date
SHA=$(git -C "$work_dir" rev-parse --short=8 HEAD 2>/dev/null || echo "$DATE")

echo "Building shani-builder..."
echo "  Username : ${DOCKER_USERNAME}"
echo "  Tags     : latest, ${DATE}, ${SHA}"
echo ""

docker pull archlinux:base-devel

docker build --no-cache -f "${dockerfile}" -t shani-builder "${work_dir}"

for tag in latest "${DATE}" "${SHA}"; do
    docker tag shani-builder "${DOCKER_USERNAME}/shani-builder:${tag}"
done

for tag in latest "${DATE}" "${SHA}"; do
    docker push "${DOCKER_USERNAME}/shani-builder:${tag}"
done

echo ""
echo "✅ Pushed:"
for tag in latest "${DATE}" "${SHA}"; do
    echo "   ${DOCKER_USERNAME}/shani-builder:${tag}"
done
