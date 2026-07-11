#!/bin/bash
# Sparkle replaces Dory.app; an update must therefore remain bootable before the first engine boot
# and retain every asset needed to create a new machine after the old bundle is gone.
set -euo pipefail

APP="${1:?usage: validate-app-update-payload.sh <Dory.app> [guest-architectures]}"
ARCHES="${2:-arm64 amd64}"
RESOURCES="$APP/Contents/Resources"

fail() {
  echo "app-update payload error: $*" >&2
  exit 1
}

[ -d "$RESOURCES" ] || fail "missing $RESOURCES"
for arch in $ARCHES; do
  for relative in \
    "dory-agent-linux-$arch" \
    "dory-hv-kernel-$arch" \
    "dory-hv-kernel-$arch.lzfse" \
    "dory-engine-rootfs-$arch.ext4.lzfse" \
    "dory-machine-rootfs-$arch.ext4" \
    "dory-vm-kernel-$arch.lzfse" \
    "dory-vm-initfs-$arch.ext4.lzfse"; do
    [ -s "$RESOURCES/$relative" ] || fail "missing $relative for $arch"
  done
done

echo "verified self-contained app-update payload for:$ARCHES"
