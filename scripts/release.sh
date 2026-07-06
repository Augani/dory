#!/bin/bash
# Dory release pipeline: archive + Developer ID sign -> notarize -> staple -> zip.
#
# Requires (one-time, your Apple Developer account -- the external gate):
#   * A "Developer ID Application" certificate in your keychain.
#   * A notarytool keychain profile:  xcrun notarytool store-credentials dory-notary \
#         --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#
# Then:  scripts/release.sh 1.0.0
set -euo pipefail
# Prefer an explicit DEVELOPER_DIR; otherwise pick up a local Xcode install, else fall back to
# the Xcode already selected by xcode-select (CI runners set this themselves).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for app in /Applications/Xcode.app /Applications/Xcode-*.app "$HOME"/Applications/Xcode*.app; do
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$app/Contents/Developer"; break; }
  done
fi
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# Monotonic build number (CFBundleVersion). Sparkle compares this to detect updates. CI passes
# the run number; locally it defaults to 1.
BUILD="${2:-${DORY_BUILD:-1}}"
BUILD_DIR="release-build"
ARCHIVE="$BUILD_DIR/Dory.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
NOTARY_PROFILE="${DORY_NOTARY_PROFILE:-dory-notary}"

assert_universal_app_binary() {
  local binary="$1"
  local archs
  archs="$(lipo -archs "$binary")"
  case " $archs " in *" arm64 "*) ;; *) echo "release error: $binary missing arm64 (archs: ${archs:-none})" >&2; exit 1 ;; esac
  case " $archs " in *" x86_64 "*) ;; *) echo "release error: $binary missing x86_64 (archs: ${archs:-none})" >&2; exit 1 ;; esac
  echo "==> Verified universal app binary: $archs"
}

TEAM="${NOTARY_TEAM_ID:-864H636QW4}"
echo "==> Archiving + signing Dory $VERSION (Developer ID, team $TEAM)..."
# Manual Developer ID signing. Automatic signing needs developer-portal access that CI lacks, and
# there is no entitlements file requiring a provisioning profile.
xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM" \
  archive

mkdir -p "$EXPORT_DIR"
rm -rf "$EXPORT_DIR/Dory.app"
cp -R "$ARCHIVE/Products/Applications/Dory.app" "$EXPORT_DIR/"
APP="$EXPORT_DIR/Dory.app"
assert_universal_app_binary "$APP/Contents/MacOS/Dory"

# Engine bundling is the release default: users should be able to install Dory.app on a clean Mac
# without Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container`. Set DORY_BUNDLE_ENGINE=0
# only for tiny development artifacts.
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
  echo "==> Bundling the engine for a self-contained app..."
  scripts/bundle-engine.sh "$APP"
else
  echo "==> WARNING: producing a development app without bundled engine assets."
fi

echo "==> Signing (Developer ID + hardened runtime)..."
# NOT --deep: bundle-engine.sh already signed the nested helpers with their own entitlements
# (dory-hv needs com.apple.security.hypervisor, dory-vm needs com.apple.security.virtualization),
# and --deep would re-sign them WITHOUT entitlements, breaking the engine with HV_DENIED. A
# non-deep sign re-seals the bundle and re-signs the main app with its entitlements, leaving the
# already-signed helpers intact.
codesign --force --options runtime --timestamp --entitlements Dory/Dory.entitlements --sign "Developer ID Application" "$APP"

ZIP="$BUILD_DIR/Dory-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# ---- Release flavors (Colima-style tiering) ------------------------------------------------
# lite  : the app with NO engine payload (~6 MB) — for users who already run Colima, Docker
#         Desktop, OrbStack, Rancher, or Podman and want Dory as the GUI/CLI front end.
# runtime: the headless engine (dory-hv + gvproxy + kernel + guest agent + `dory-engine`
#         launcher) — for users who want Dory's runtime with no GUI, like Colima itself.
LITE_ZIP=""
RUNTIME_TAR=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
  echo "==> Building lite app (no bundled engine)..."
  LITE_DIR="$BUILD_DIR/export-lite"
  rm -rf "$LITE_DIR"; mkdir -p "$LITE_DIR"
  cp -R "$ARCHIVE/Products/Applications/Dory.app" "$LITE_DIR/"
  LITE_APP="$LITE_DIR/Dory.app"
  codesign --force --options runtime --timestamp --entitlements Dory/Dory.entitlements --sign "Developer ID Application" "$LITE_APP"
  LITE_ZIP="$BUILD_DIR/Dory-$VERSION-lite.zip"
  ditto -c -k --keepParent "$LITE_APP" "$LITE_ZIP"

  echo "==> Packaging standalone engine runtime..."
  RUNTIME_NAME="dory-engine-$VERSION-arm64"
  RUNTIME_DIR="$BUILD_DIR/runtime/$RUNTIME_NAME"
  rm -rf "$BUILD_DIR/runtime"; mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/share/dory"
  # Reuse the full app's already-built, already-signed payload so the runtime matches the release.
  cp "$APP/Contents/Helpers/dory-hv" "$RUNTIME_DIR/bin/"
  cp "$APP/Contents/Helpers/gvproxy" "$RUNTIME_DIR/bin/"
  cp "$APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" "$RUNTIME_DIR/share/dory/"
  [ -f "$APP/Contents/Resources/dory-agent-linux-arm64" ] && cp "$APP/Contents/Resources/dory-agent-linux-arm64" "$RUNTIME_DIR/share/dory/"
  cp scripts/runtime/dory-engine "$RUNTIME_DIR/dory-engine"
  chmod 0755 "$RUNTIME_DIR/dory-engine"
  cat > "$RUNTIME_DIR/README.md" <<EOF
# dory-engine $VERSION (arm64)

Dory's container engine as a standalone, Colima-style runtime: one shared Linux VM running
dockerd, with memory returned to macOS as workloads idle.

    ./dory-engine start          # boots the engine, publishes ~/.dory/engine.sock
    ./dory-engine start --amd64  # also enable x86/amd64 images via QEMU emulation
    docker context use dory-engine
    docker run --rm alpine echo hello

\`dory-engine stop|status|env\` manage it. Requires macOS 15+ on Apple silicon.
EOF
  tar -czf "$BUILD_DIR/$RUNTIME_NAME.tar.gz" -C "$BUILD_DIR/runtime" "$RUNTIME_NAME"
  RUNTIME_TAR="$BUILD_DIR/$RUNTIME_NAME.tar.gz"
fi

# DORY_SKIP_NOTARIZE=1 produces a signed, engine-bundled app without the Apple notary round-trip,
# for fast local verification. Notarize once the build is confirmed working.
if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> Skipping notarization (DORY_SKIP_NOTARIZE=1); signed app at $APP"
  SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  echo "==> Done (signed, not notarized): $ZIP  (sha256: $SHA256)"
  [ -n "$LITE_ZIP" ] && echo "==> Done (signed, not notarized): $LITE_ZIP  (sha256: $(shasum -a 256 "$LITE_ZIP" | awk '{print $1}'))"
  [ -n "$RUNTIME_TAR" ] && echo "==> Done: $RUNTIME_TAR  (sha256: $(shasum -a 256 "$RUNTIME_TAR" | awk '{print $1}'))"
  exit 0
fi

notarize() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

echo "==> Notarizing..."
# CI passes credentials directly (NOTARY_APPLE_ID/_TEAM_ID/_PASSWORD); locally we use a stored
# notarytool keychain profile created once with `xcrun notarytool store-credentials`.
notarize "$ZIP"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "$LITE_ZIP" ]; then
  echo "==> Notarizing lite app..."
  notarize "$LITE_ZIP"
  xcrun stapler staple "$LITE_APP"
  ditto -c -k --keepParent "$LITE_APP" "$LITE_ZIP"
fi
# The runtime tarball is not notarized (notarytool takes zip/dmg/pkg, not tar.gz); its binaries
# are Developer ID signed + timestamped, which is what CLI users and Homebrew care about.

# A styled .dmg for direct download (the .zip remains the cask's artifact). Notarize + staple it
# too so Gatekeeper is happy on a fresh download.
DMG=""
if [ "${DORY_MAKE_DMG:-1}" = "1" ]; then
  echo "==> Building DMG..."
  DMG="$BUILD_DIR/Dory-$VERSION.dmg"
  scripts/make-dmg.sh "$APP" "$VERSION" "$DMG"
  echo "==> Notarizing DMG..."
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> Done: $ZIP  (sha256: $SHA256)"
[ -n "$DMG" ] && echo "==> Done: $DMG  (sha256: $(shasum -a 256 "$DMG" | awk '{print $1}'))"
[ -n "$LITE_ZIP" ] && echo "==> Done: $LITE_ZIP  (sha256: $(shasum -a 256 "$LITE_ZIP" | awk '{print $1}'))"
[ -n "$RUNTIME_TAR" ] && echo "==> Done: $RUNTIME_TAR  (sha256: $(shasum -a 256 "$RUNTIME_TAR" | awk '{print $1}'))"
# Expose outputs to a GitHub Actions step when running in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "zip=$ZIP"; echo "sha256=$SHA256"; echo "version=$VERSION"; echo "build=$BUILD"; echo "dmg=$DMG"
    echo "lite=$LITE_ZIP"; echo "runtime=$RUNTIME_TAR"
  } >> "$GITHUB_OUTPUT"
fi
