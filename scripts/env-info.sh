#!/usr/bin/env bash
# Print the environment a runtime container runs in, to keep next to results: host kernel, image, Darling and Mesa package versions, the macOS version Darling reports,
# and `vulkaninfo --summary`.
#
# Usage: scripts/env-info.sh <container>
set -euo pipefail

container=${1:?usage: env-info.sh <container>}
image=$(docker container inspect -f "{{.Config.Image}}" "$container")
image_id=$(docker container inspect -f "{{.Image}}" "$container")

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host kernel: $(uname -srm)"
echo "host cpu: $(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -1)"
echo "image: $image $image_id (the container's, not necessarily the tag's current one)"
echo "release: $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image_id")"
docker exec "$container" dpkg-query -W -f 'package: ${Package} ${Version}\n' \
    darling-core mesa-vulkan-drivers libvulkan1 vulkan-tools
echo "darling reports: $(docker exec "$container" darling shell sw_vers -productVersion | tr -d '\r') ($(docker exec "$container" darling shell uname -rm | tr -d '\r'))"
echo
echo "\$ vulkaninfo --summary"
docker exec "$container" vulkaninfo --summary 2>&1
