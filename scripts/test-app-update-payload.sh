#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-update-payload.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Dory.app"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
NETWORK_DAEMON_DIR="$APP/Contents/Library/LaunchDaemons"
NETWORK_DAEMON_PLIST="$NETWORK_DAEMON_DIR/dev.dory.network-helper.plist"
mkdir -p "$RESOURCES" "$HELPERS" "$NETWORK_DAEMON_DIR"
cp Config/dev.dory.network-helper.plist "$NETWORK_DAEMON_PLIST"

ASSETS=(
  dory-agent-linux-arm64
  dory-hv-kernel-arm64
  dory-hv-kernel-arm64.lzfse
  dory-engine-rootfs-arm64.ext4.lzfse
  dory-machine-rootfs-arm64.ext4
  dory-vm-kernel-arm64.lzfse
  dory-vm-initfs-arm64.ext4.lzfse
  dory-desktop-kernel-arm64.lzfse
  kernel-build-arm64-desktop.stamp
  dory-desktop-debian-rootfs-arm64.ext4.lzfse
  dory-desktop-debian-build-arm64.stamp
  dory-desktop-debian-packages-arm64.txt
  dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse
  dory-desktop-ubuntu-build-arm64.stamp
  dory-desktop-ubuntu-packages-arm64.txt
  dory-desktop-kali-rootfs-arm64.ext4.lzfse
  dory-desktop-kali-build-arm64.stamp
  dory-desktop-kali-packages-arm64.txt
)
for asset in "${ASSETS[@]}"; do
  printf 'fixture\n' > "$RESOURCES/$asset"
done

HELPER_ASSETS=(
  doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv
  gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor
)
for helper in "${HELPER_ASSETS[@]}"; do
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done

scripts/validate-app-update-payload.sh "$APP" arm64 desktop >/dev/null
for asset in "${ASSETS[@]}"; do
  rm "$RESOURCES/$asset"
  if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >/dev/null 2>&1; then
    echo "app-update payload test failed: missing $asset was accepted" >&2
    exit 1
  fi
  printf 'fixture\n' > "$RESOURCES/$asset"
done
for helper in "${HELPER_ASSETS[@]}"; do
  rm "$HELPERS/$helper"
  if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >/dev/null 2>&1; then
    echo "app-update payload test failed: missing $helper was accepted" >&2
    exit 1
  fi
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done

rm "$NETWORK_DAEMON_PLIST"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >/dev/null 2>&1; then
  echo "app-update payload test failed: missing privileged network daemon plist was accepted" >&2
  exit 1
fi
cp Config/dev.dory.network-helper.plist "$NETWORK_DAEMON_PLIST"

cp "$NETWORK_DAEMON_PLIST" "$TMP/network-helper.plist"
/usr/libexec/PlistBuddy -c 'Set :BundleProgram Contents/Helpers/not-dory-network-helper' "$NETWORK_DAEMON_PLIST"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >/dev/null 2>&1; then
  echo "app-update payload test failed: invalid privileged network daemon BundleProgram was accepted" >&2
  exit 1
fi
cp "$TMP/network-helper.plist" "$NETWORK_DAEMON_PLIST"

if scripts/validate-app-update-payload.sh "$APP" '../unsafe' desktop \
  >"$TMP/architecture.out" 2>&1; then
  echo "app-update payload test failed: unsafe architecture input was accepted" >&2
  exit 1
fi
grep -F 'unsupported guest architecture' "$TMP/architecture.out" >/dev/null

APP_LINK="$TMP/linked-Dory.app"
ln -s "$APP" "$APP_LINK"
if scripts/validate-app-update-payload.sh "$APP_LINK" arm64 desktop \
  >"$TMP/indirect.out" 2>&1; then
  echo "app-update payload test failed: indirect candidate app was accepted" >&2
  exit 1
fi
grep -F 'input must be a direct Dory.app directory' "$TMP/indirect.out" >/dev/null

echo "app-update payload tests passed"
