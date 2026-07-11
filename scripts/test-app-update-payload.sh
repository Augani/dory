#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-update-payload.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Dory.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$RESOURCES"

ASSETS=(
  dory-agent-linux-arm64
  dory-hv-kernel-arm64
  dory-hv-kernel-arm64.lzfse
  dory-engine-rootfs-arm64.ext4.lzfse
  dory-machine-rootfs-arm64.ext4
  dory-vm-kernel-arm64.lzfse
  dory-vm-initfs-arm64.ext4.lzfse
)
for asset in "${ASSETS[@]}"; do
  printf 'fixture\n' > "$RESOURCES/$asset"
done

scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null
for asset in "${ASSETS[@]}"; do
  rm "$RESOURCES/$asset"
  if scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null 2>&1; then
    echo "app-update payload test failed: missing $asset was accepted" >&2
    exit 1
  fi
  printf 'fixture\n' > "$RESOURCES/$asset"
done

echo "app-update payload tests passed"
