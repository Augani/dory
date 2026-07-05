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
  archs="$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ')"
  case " $archs " in
    *" arm64 "*" x86_64 "*) ;;
    *) echo "release error: $binary is not universal (archs: ${archs:-none})" >&2; exit 1 ;;
  esac
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

# Engine bundling is off by default. The app pulls the engine on first run. Set DORY_BUNDLE_ENGINE=1
# for a self-contained app (needs the engine assets present locally).
if [ "${DORY_BUNDLE_ENGINE:-0}" = "1" ]; then
  echo "==> Bundling the engine for a self-contained app..."
  scripts/bundle-engine.sh "$APP"
fi

echo "==> Signing (Developer ID + hardened runtime)..."
codesign --force --deep --options runtime --timestamp --sign "Developer ID Application" "$APP"

ZIP="$BUILD_DIR/Dory-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Notarizing..."
# CI passes credentials directly (NOTARY_APPLE_ID/_TEAM_ID/_PASSWORD); locally we use a stored
# notarytool keychain profile created once with `xcrun notarytool store-credentials`.
if [ -n "${NOTARY_APPLE_ID:-}" ]; then
  xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" --wait
else
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

notarize() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

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
# Expose outputs to a GitHub Actions step when running in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "zip=$ZIP"; echo "sha256=$SHA256"; echo "version=$VERSION"; echo "build=$BUILD"; echo "dmg=$DMG"; } >> "$GITHUB_OUTPUT"
fi
