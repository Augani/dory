#!/bin/bash
# Sparkle replaces Dory.app; an update must therefore remain bootable before the first engine boot
# and retain every asset needed to create a new machine after the old bundle is gone.
set -euo pipefail

APP="${1:?usage: validate-app-update-payload.sh <Dory.app> [guest-architectures] [core|lean|desktop]}"
ARCHES="${2:-arm64 amd64}"
EDITION="${3:-lean}"
[ -d "$APP" ] && [ ! -L "$APP" ] && [ "$(basename "$APP")" = Dory.app ] \
  || { echo "app-update payload error: input must be a direct Dory.app directory" >&2; exit 66; }
APP_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$APP")"
APP="$(cd "$APP" && pwd -P)"
[ "$APP" = "$APP_LOGICAL" ] \
  || { echo "app-update payload error: input app has an indirect ancestor" >&2; exit 66; }
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
NETWORK_DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"

fail() {
  echo "app-update payload error: $*" >&2
  exit 1
}

case "$EDITION" in
  core|lean|desktop) ;;
  *) fail "edition must be core, lean, or desktop" ;;
esac
for arch in $ARCHES; do
  case "$arch" in arm64|amd64) ;; *) fail "unsupported guest architecture: $arch" ;; esac
done

[ -d "$RESOURCES" ] || fail "missing $RESOURCES"
[ -d "$HELPERS" ] || fail "missing $HELPERS"
for helper in \
  doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv \
  gvproxy docker docker-buildx docker-compose dory dory-doctor; do
  [ -x "$HELPERS/$helper" ] || fail "missing executable helper $helper"
done
if [ "$EDITION" = core ]; then
  [ ! -e "$HELPERS/kubectl" ] || fail "Core update unexpectedly contains kubectl"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :DoryBundledComponents' "$APP/Contents/Info.plist" 2>/dev/null || true)" = $'Array {\n    docker-core\n}' ] \
    || fail "Core update must declare only docker-core"
else
  [ -x "$HELPERS/kubectl" ] || fail "missing executable helper kubectl"
fi
[ -s "$NETWORK_DAEMON_PLIST" ] || fail "missing privileged network daemon plist"
plutil -lint "$NETWORK_DAEMON_PLIST" >/dev/null \
  || fail "privileged network daemon plist is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "Contents/Helpers/dory-network-helper" ] \
  || fail "privileged network daemon BundleProgram does not reference the bundled helper"
[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:dev.dory.network-helper' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "true" ] \
  || fail "privileged network daemon Mach service is missing"
for arch in $ARCHES; do
  for relative in \
    "dory-agent-linux-$arch" \
    "dory-hv-kernel-$arch.lzfse" \
    "dory-engine-rootfs-$arch.ext4.lzfse" \
    "dory-vm-kernel-$arch.lzfse" \
    "dory-vm-initfs-$arch.ext4.lzfse"; do
    [ -s "$RESOURCES/$relative" ] || fail "missing $relative for $arch"
  done
  if [ "$EDITION" = core ]; then
    for relative in "dory-hv-kernel-$arch" "dory-machine-rootfs-$arch.ext4"; do
      [ ! -e "$RESOURCES/$relative" ] || fail "Core update unexpectedly contains $relative"
    done
  else
    for relative in "dory-hv-kernel-$arch" "dory-machine-rootfs-$arch.ext4"; do
      [ -s "$RESOURCES/$relative" ] || fail "missing $relative for $arch"
    done
  fi
done
case " $ARCHES " in
  *" arm64 "*)
    if [ "$EDITION" = desktop ]; then
    for relative in \
      dory-desktop-kernel-arm64.lzfse \
      kernel-build-arm64-desktop.stamp \
      dory-desktop-debian-rootfs-arm64.ext4.lzfse \
      dory-desktop-debian-build-arm64.stamp \
      dory-desktop-debian-packages-arm64.txt \
      dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
      dory-desktop-ubuntu-build-arm64.stamp \
      dory-desktop-ubuntu-packages-arm64.txt \
      dory-desktop-kali-rootfs-arm64.ext4.lzfse \
      dory-desktop-kali-build-arm64.stamp \
      dory-desktop-kali-packages-arm64.txt; do
      [ -s "$RESOURCES/$relative" ] || fail "missing Apple Silicon Desktop Linux asset $relative"
    done
    else
    for relative in \
      dory-desktop-kernel-arm64.lzfse \
      kernel-build-arm64-desktop.stamp \
      dory-desktop-debian-rootfs-arm64.ext4.lzfse \
      dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
      dory-desktop-kali-rootfs-arm64.ext4.lzfse; do
      [ ! -e "$RESOURCES/$relative" ] || fail "lean update unexpectedly contains $relative"
    done
    fi
    ;;
esac

echo "verified self-contained $EDITION app-update payload for:$ARCHES"
