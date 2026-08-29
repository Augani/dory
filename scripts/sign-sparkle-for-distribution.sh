#!/bin/bash
# Sparkle's prebuilt helpers are intentionally ad-hoc signed. A custom Developer ID export must
# re-sign them inside-out before the framework and containing app are signed.
set -euo pipefail

APP="${1:?usage: sign-sparkle-for-distribution.sh <Dory.app> <signing-identity>}"
SIGN_IDENTITY="${2:?usage: sign-sparkle-for-distribution.sh <Dory.app> <signing-identity>}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
VERSION="$FRAMEWORK/Versions/Current"

fail() {
  echo "Sparkle signing error: $*" >&2
  exit 1
}

[ -d "$APP" ] && [ ! -L "$APP" ] || fail "application is missing or indirect: $APP"
APP_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$APP")"
APP_PHYSICAL="$(cd "$APP" && pwd -P)"
[ "$APP_LOGICAL" = "$APP_PHYSICAL" ] || fail "application has an indirect ancestor"
[ -d "$FRAMEWORK" ] && [ ! -L "$FRAMEWORK" ] || fail "framework is missing or indirect: $FRAMEWORK"
[ -d "$VERSION" ] || fail "current framework version is missing: $VERSION"
FRAMEWORK_PHYSICAL="$(cd "$FRAMEWORK" && pwd -P)"
VERSION_PHYSICAL="$(cd "$VERSION" && pwd -P)"
case "$VERSION_PHYSICAL" in
  "$FRAMEWORK_PHYSICAL"/Versions/*) ;;
  *) fail "current framework version escapes Sparkle.framework" ;;
esac

INSTALLER="$VERSION/XPCServices/Installer.xpc"
DOWNLOADER="$VERSION/XPCServices/Downloader.xpc"
AUTOUPDATE="$VERSION/Autoupdate"
UPDATER="$VERSION/Updater.app"

for path in "$INSTALLER" "$DOWNLOADER" "$AUTOUPDATE" "$UPDATER"; do
  [ -e "$path" ] || fail "required nested code is missing: $path"
  nested_physical="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  case "$nested_physical" in
    "$VERSION_PHYSICAL"/*) ;;
    *) fail "nested code escapes the current Sparkle version: $path" ;;
  esac
done

sign_args=(--force --options runtime)
if [ "$SIGN_IDENTITY" != "-" ]; then
  sign_args+=(--timestamp)
fi

# This order and Downloader entitlement preservation follow Sparkle's distribution guidance.
# Do not use --deep: different nested targets can require different entitlements.
codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$INSTALLER"
codesign "${sign_args[@]}" --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$DOWNLOADER"
codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$AUTOUPDATE"
codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$UPDATER"
codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$FRAMEWORK"

echo "Sparkle distribution signing: PASS"
