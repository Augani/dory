#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS

ARCH="${1:-arm64}"
GPU="${DORY_EXPERIMENTAL_GPU:-0}"
case "$GPU" in
  0|1) ;;
  *) echo "DORY_EXPERIMENTAL_GPU must be 0 or 1" >&2; exit 64 ;;
esac
case "$ARCH" in
  arm64)
    CONFIGS=(dory.config dory-arm.config)
    ;;
  amd64|x86_64)
    ARCH="amd64"
    CONFIGS=(dory.config dory-x86.config)
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac

if [ "$GPU" = "1" ]; then
  CONFIGS+=(dory-gpu.fragment)
fi

PATCH_DIR="patches/$KERNEL_VERSION"
PATCHES=()
if [ -d "$PATCH_DIR" ]; then
  while IFS= read -r kernel_patch; do
    PATCHES+=("$kernel_patch")
  done < <(find "$PATCH_DIR" -type f -name '*.patch' | LC_ALL=C sort)
fi

# Hash names as well as contents so adding, removing, reordering, or replacing an input invalidates
# every previously built kernel. The schema marker makes future fingerprint changes explicit.
{
  printf 'schema=2\narch=%s\ngpu=%s\nkernel_version=%s\nkernel_url=%s\nkernel_sha256=%s\nbuilder_image=%s\n' \
    "$ARCH" "$GPU" "$KERNEL_VERSION" "$KERNEL_URL" "$KERNEL_SHA256" "$KERNEL_BUILDER_IMAGE"
  for input in build.sh docker-endpoint.sh PINS "${CONFIGS[@]}" "${PATCHES[@]}"; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
