#!/bin/bash
# Dory release pipeline: archive → export (Developer ID) → notarize → staple → zip.
#
# Requires (one-time, your Apple Developer account — the external gate):
#   * A "Developer ID Application" certificate in your keychain.
#   * A notarytool keychain profile:  xcrun notarytool store-credentials dory-notary \
#         --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#
# Then:  scripts/release.sh 1.0.0
set -euo pipefail
# Prefer an explicit DEVELOPER_DIR; otherwise use the local Xcode 27 beta if present, else the
# Xcode already selected by xcode-select (CI runners set this themselves).
LOCAL_XCODE="/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$LOCAL_XCODE" ]; then export DEVELOPER_DIR="$LOCAL_XCODE"; fi
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD_DIR="release-build"
ARCHIVE="$BUILD_DIR/Dory.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
NOTARY_PROFILE="${DORY_NOTARY_PROFILE:-dory-notary}"

echo "==> Archiving Dory $VERSION…"
xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" archive

cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "==> Exporting signed app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/Dory.app"

if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
  echo "==> Bundling the engine for a self-contained app (no extra downloads for users)…"
  scripts/bundle-engine.sh "$APP"
  codesign --force --deep --options runtime --sign "Developer ID Application" "$APP"
fi

ZIP="$BUILD_DIR/Dory-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Notarizing…"
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

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> Done: $ZIP  (sha256: $SHA256)"
# Expose outputs to a GitHub Actions step when running in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "zip=$ZIP"; echo "sha256=$SHA256"; echo "version=$VERSION"; } >> "$GITHUB_OUTPUT"
fi
