#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the Dory Venus runtime currently supports arm64 only" >&2; exit 64 ;;
esac

{
  printf 'schema=3\narch=arm64\nmesa_version=%s\nmeson_version=%s\nbuilder=%s\n' \
    "$MESA_VERSION" "$MESON_VERSION" "$MESA_BUILDER_IMAGE"
  for input in \
    guest/mesa/PINS \
    guest/mesa/build.sh \
    guest/mesa/dory-vulkan-compositor-probe.c \
    guest/mesa/dory-vulkan-probe.c \
    guest/mesa/input-fingerprint.sh \
    guest/mesa/verify-build.sh; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
