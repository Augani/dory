#!/bin/bash
# Make a built Dory.app self-contained so users download ONLY the app — no `brew install container`.
#
# Default ("OrbStack model") injects the in-process engine and pulls the docker engine IMAGE on first
# launch (the image is NOT bundled), the way OrbStack ships an app and fetches engine bits on first
# run. Measured payload ≈ 134MB on disk / ~80MB in the download zip:
#   * Contents/Helpers/dory-vm                    — the signed in-process VM engine helper (~100MB,
#                                                   statically links the containerization framework).
#   * Contents/Helpers/zstd                       — decompresses the assets on first launch.
#   * Contents/Resources/dory-vm-kernel.zst       — compressed Linux kernel  (~15MB -> ~6MB).
#   * Contents/Resources/dory-vm-initfs.ext4.zst  — compressed VM initfs     (~165MB -> ~30MB).
#   The docker engine image (docker:dind) is NOT bundled — the helper pulls it on first boot.
#
# Set DORY_BUNDLE_LEGACY=1 to additionally inject the heavy offline payload (the docker:dind image
# tarball + Apple's `container` toolchain) for the legacy SharedVMProvisioner path — adds ~600MB.
#
# Run on an exported (pre-notarization) app so the payload is signed with the bundle:
#   scripts/bundle-engine.sh release-build/export/Dory.app
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

APP="${1:?usage: bundle-engine.sh <path/to/Dory.app>}"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
SUPPORT="$HOME/Library/Application Support/com.apple.container"

[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }
command -v zstd >/dev/null || { echo "zstd not found (brew install zstd)"; exit 1; }
mkdir -p "$RESOURCES" "$HELPERS"

echo "==> Building + signing the in-process VM engine helper (dory-vm)…"
PKG="$(dirname "$0")/../Packages/ContainerizationEngine"
if [ -d "$PKG" ]; then
  ( cd "$PKG" && swift build -c release --product dory-vmboot )
  # This package emits to .build/out/Products/<config>/ — NOT swift's --show-bin-path location.
  HELPER_BIN="$(find "$PKG/.build" -name dory-vmboot -type f -path '*Release*' 2>/dev/null | head -1)"
  [ -n "$HELPER_BIN" ] || HELPER_BIN="$(find "$PKG/.build" -name dory-vmboot -type f 2>/dev/null | head -1)"
  cat > /tmp/dory-vm.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
  cp "$HELPER_BIN" "$HELPERS/dory-vm"
  codesign --force --options runtime --entitlements /tmp/dory-vm.entitlements \
    -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/dory-vm" 2>/dev/null \
    || codesign --force --entitlements /tmp/dory-vm.entitlements -s - "$HELPERS/dory-vm"
  echo "    bundled Helpers/dory-vm (signed with com.apple.security.virtualization)"
fi

echo "==> Bundling zstd (decompresses the engine assets on first launch)…"
ZSTD_BIN="$(command -v zstd)"
cp "$ZSTD_BIN" "$HELPERS/zstd"
codesign --force --options runtime -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/zstd" 2>/dev/null \
  || codesign --force -s - "$HELPERS/zstd"
echo "    bundled Helpers/zstd"

echo "==> Bundling the VM kernel + initfs, compressed (so the engine needs no \`container\` install)…"
KERNEL_SRC="${DORY_KERNEL:-$(ls -t "$SUPPORT"/kernels/vmlinux-* 2>/dev/null | head -1)}"
INITFS_SRC="${DORY_INITFS:-$(ls -t "$SUPPORT"/containers/*/initfs.ext4 2>/dev/null | head -1)}"
if [ -n "$KERNEL_SRC" ] && [ -f "$KERNEL_SRC" ]; then
  zstd -19 -q -f "$KERNEL_SRC" -o "$RESOURCES/dory-vm-kernel.zst"
  echo "    bundled Resources/dory-vm-kernel.zst ($(du -h "$RESOURCES/dory-vm-kernel.zst" | awk '{print $1}'), from $(du -h "$KERNEL_SRC" | awk '{print $1}'))"
else
  echo "    WARNING: no kernel found under $SUPPORT/kernels — set DORY_KERNEL to a vmlinux"
fi
if [ -n "$INITFS_SRC" ] && [ -f "$INITFS_SRC" ]; then
  # --long catches the large zero-fill region in the sparse ext4 (512MB -> ~31MB).
  zstd -19 --long=27 -q -f "$INITFS_SRC" -o "$RESOURCES/dory-vm-initfs.ext4.zst"
  echo "    bundled Resources/dory-vm-initfs.ext4.zst ($(du -h "$RESOURCES/dory-vm-initfs.ext4.zst" | awk '{print $1}'), from $(du -h "$INITFS_SRC" | awk '{print $1}'))"
else
  echo "    WARNING: no initfs found — set DORY_INITFS to a built initfs.ext4"
fi

if [ "${DORY_BUNDLE_LEGACY:-0}" = "1" ]; then
  echo "==> DORY_BUNDLE_LEGACY=1: injecting the heavy offline payload (image tar + container toolchain)…"
  IMAGE="${DORY_ENGINE_IMAGE:-docker.io/library/docker:dind}"
  CONTAINER_BIN="$(command -v container || true)"
  [ -n "$CONTAINER_BIN" ] || { echo "container CLI not found; cannot bundle legacy payload"; exit 1; }
  container image save "$IMAGE" -o "$RESOURCES/dory-engine-image.tar"
  echo "    bundled Resources/dory-engine-image.tar ($(du -h "$RESOURCES/dory-engine-image.tar" | awk '{print $1}'))"
  CELLAR="$(dirname "$(dirname "$(readlink -f "$CONTAINER_BIN" || echo "$CONTAINER_BIN")")")"
  cp "$CONTAINER_BIN" "$HELPERS/container"
  [ -d "$CELLAR/libexec" ] && cp -R "$CELLAR/libexec" "$HELPERS/libexec"
  echo "    bundled Helpers/container + libexec"
fi

TOTAL="$(du -sh "$RESOURCES"/dory-vm-* "$HELPERS"/dory-vm 2>/dev/null | awk '{s+=$1} END{print s}')"
echo "==> Payload injected into $APP"
echo "    Engine payload ≈ $(du -ch "$RESOURCES"/dory-vm-*.zst "$HELPERS"/dory-vm 2>/dev/null | tail -1 | awk '{print $1}') on disk (engine image pulled on first launch)"
echo "    Re-sign the bundle (codesign --deep) before notarization so the payload is sealed."
