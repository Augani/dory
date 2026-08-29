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
RUNNER_APP="$HELPERS/DoryHVRunner.app"
RUNNER="$RUNNER_APP/Contents/MacOS/dory-hv"
NETWORK_DAEMON_DIR="$APP/Contents/Library/LaunchDaemons"
NETWORK_DAEMON_PLIST="$NETWORK_DAEMON_DIR/dev.dory.network-helper.plist"
mkdir -p "$RESOURCES" "$HELPERS" "$RUNNER_APP/Contents/MacOS" "$NETWORK_DAEMON_DIR"
cp Config/dev.dory.network-helper.plist "$NETWORK_DAEMON_PLIST"
cat > "$RUNNER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>dory-hv</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.HVRunner</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$RUNNER"
chmod 0755 "$RUNNER"

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
  doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy
  gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor
)
for helper in "${HELPER_ASSETS[@]}"; do
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done

mv "$RUNNER" "$TMP/dory-hv"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >"$TMP/missing-runner.out" 2>&1; then
  echo "app-update payload test failed: missing nested dory-hv was accepted" >&2
  exit 1
fi
grep -F 'missing direct DoryHVRunner executable dory-hv' "$TMP/missing-runner.out" >/dev/null
mv "$TMP/dory-hv" "$RUNNER"

ln -s "$RUNNER" "$HELPERS/dory-hv"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >"$TMP/parallel-runner.out" 2>&1; then
  echo "app-update payload test failed: obsolete parallel dory-hv was accepted" >&2
  exit 1
fi
grep -F 'obsolete parallel executable helper dory-hv is present' "$TMP/parallel-runner.out" >/dev/null
rm "$HELPERS/dory-hv"

mv "$RUNNER_APP" "$TMP/DoryHVRunner.app"
ln -s "$TMP/DoryHVRunner.app" "$RUNNER_APP"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >"$TMP/indirect-runner.out" 2>&1; then
  echo "app-update payload test failed: indirect DoryHVRunner.app was accepted" >&2
  exit 1
fi
grep -F 'missing direct DoryHVRunner.app' "$TMP/indirect-runner.out" >/dev/null
rm "$RUNNER_APP"
mv "$TMP/DoryHVRunner.app" "$RUNNER_APP"

cp "$RUNNER_APP/Contents/Info.plist" "$TMP/runner-info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable not-dory-hv' "$RUNNER_APP/Contents/Info.plist"
if scripts/validate-app-update-payload.sh "$APP" arm64 desktop >"$TMP/runner-metadata.out" 2>&1; then
  echo "app-update payload test failed: invalid runner metadata was accepted" >&2
  exit 1
fi
grep -F 'DoryHVRunner.app CFBundleExecutable is not dory-hv' "$TMP/runner-metadata.out" >/dev/null
cp "$TMP/runner-info.plist" "$RUNNER_APP/Contents/Info.plist"

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
