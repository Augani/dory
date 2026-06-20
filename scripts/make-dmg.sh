#!/bin/bash
# Build a distributable .dmg from a built Dory.app.
# Usage: scripts/make-dmg.sh <path/to/Dory.app> <version> [out.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"; VERSION="$2"; OUT="${3:-release-build/Dory-$VERSION.dmg}"
VOL="Dory $VERSION"
WORK="$(mktemp -d)"; STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Volume icon from the app's icon set (best-effort — DMG is still valid without it).
ICONSET="$WORK/Dory.iconset"; mkdir -p "$ICONSET"
if cp Dory/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/" 2>/dev/null \
   && iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns" 2>/dev/null; then
  SetFile -a C "$STAGE" 2>/dev/null || true
fi

mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$WORK"
echo "$OUT"
