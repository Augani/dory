#!/bin/bash
# Xcode Dory phase: reject stale ARM64 kernels before a Release app can be packaged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL_OUT="$ROOT/guest/out"
VERIFY="$ROOT/guest/kernel/verify-build.sh"
CONFIGURATION_NAME="${CONFIGURATION:?Xcode did not provide CONFIGURATION}"

case "$CONFIGURATION_NAME" in
  Debug)
    echo "note: Debug build does not enforce release guest-kernel provenance"
    exit 0
    ;;
  Release) ;;
  *)
    echo "error: unsupported Xcode configuration for guest-kernel verification: $CONFIGURATION_NAME" >&2
    exit 64
    ;;
esac

HELPERS_ENABLED="${DORY_BUILD_DEBUG_HELPERS:-1}"
REQUIRE_CORE="${DORY_REQUIRE_CORE_ASSETS:-1}"
DESKTOP_MODE="${DORY_DESKTOP_BUNDLE_MODE:-none}"
VENUS_REQUIRED="${DORY_BUNDLE_VENUS_REQUIRED:-${DORY_BUNDLE_RENDERER_REQUIRED:-0}}"
PUBLIC_RELEASE="${DORY_PUBLIC_RELEASE:-0}"

for boolean_contract in \
  "DORY_BUILD_DEBUG_HELPERS:$HELPERS_ENABLED" \
  "DORY_REQUIRE_CORE_ASSETS:$REQUIRE_CORE" \
  "DORY_BUNDLE_VENUS_REQUIRED:$VENUS_REQUIRED" \
  "DORY_PUBLIC_RELEASE:$PUBLIC_RELEASE"; do
  boolean_name="${boolean_contract%%:*}"
  boolean_value="${boolean_contract#*:}"
  case "$boolean_value" in
    0|1) ;;
    *)
      echo "error: $boolean_name must be 0 or 1" >&2
      exit 64
      ;;
  esac
done
case "$DESKTOP_MODE" in
  none|debian|ubuntu|kali|all) ;;
  *)
    echo "error: DORY_DESKTOP_BUNDLE_MODE must be none, debian, ubuntu, kali, or all" >&2
    exit 64
    ;;
esac

if [ "$HELPERS_ENABLED" = 0 ]; then
  [ "$DESKTOP_MODE" = none ] || {
    echo "error: a desktop-enabled Release build cannot disable guest-asset bundling" >&2
    exit 64
  }
  echo "note: Release guest-kernel verification skipped because guest assets are disabled"
  exit 0
fi

[ -f "$VERIFY" ] && [ ! -L "$VERIFY" ] || {
  echo "error: release guest-kernel verifier is missing or indirect: $VERIFY" >&2
  exit 1
}

verify_profile() {
  local profile="$1" artifact="$2"
  echo "note: verifying $profile ARM64 kernel before Release packaging ($artifact)"
  DORY_KERNEL_PROFILE="$profile" \
    DORY_EXPERIMENTAL_GPU=0 \
    DORY_KERNEL_OUT_DIR="$KERNEL_OUT" \
    /bin/bash "$VERIFY" arm64
}

# The normal build helper always copies guest/out/Image when present. A Release build that
# requires Docker Core must also reject a missing kernel here rather than relying on a later copy.
if [ "$REQUIRE_CORE" = 1 ] || [ -e "$KERNEL_OUT/Image" ]; then
  verify_profile headless Image
else
  echo "note: optional headless ARM64 kernel is absent and will not be packaged"
fi

# The helper currently packages Image-gpu whenever it exists, independently of renderer UI
# controls. Therefore any present artifact must carry current Venus provenance. Explicit/public
# Venus requirements additionally turn absence into a verifier failure.
if [ -e "$KERNEL_OUT/Image-gpu" ] \
    || [ "$VENUS_REQUIRED" = 1 ] \
    || [ "$PUBLIC_RELEASE" = 1 ]; then
  verify_profile venus Image-gpu
else
  echo "note: optional Venus ARM64 kernel is absent and will not be packaged"
fi

if [ "$DESKTOP_MODE" != none ]; then
  verify_profile accelerated-desktop Image-desktop
fi

echo "verified Release guest-kernel provenance"
