#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS
source ./profile.sh

ARCH="${1:-arm64}"
PROFILE="$(dory_kernel_resolve_profile)"
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

case "$PROFILE" in
  headless) ;;
  venus) CONFIGS+=(dory-virtual-display.fragment dory-gpu.fragment) ;;
  desktop) CONFIGS+=(dory-virtual-display.fragment dory-desktop.fragment) ;;
esac
if [ "$PROFILE" = "desktop" ] && [ "$ARCH" != "arm64" ]; then
  echo "the desktop kernel profile currently supports arm64 only" >&2
  exit 64
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
  printf 'schema=3\narch=%s\nprofile=%s\nkernel_version=%s\nkernel_url=%s\nkernel_sha256=%s\nbuilder_image=%s\n' \
    "$ARCH" "$PROFILE" "$KERNEL_VERSION" "$KERNEL_URL" "$KERNEL_SHA256" "$KERNEL_BUILDER_IMAGE"
  for input in build.sh docker-endpoint.sh profile.sh PINS "${CONFIGS[@]}" "${PATCHES[@]}"; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
