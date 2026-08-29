#!/bin/bash
# Build a distributable .dmg from a built Dory.app.
# Usage: scripts/make-dmg.sh <path/to/Dory.app> <version> [out.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/make-dmg.sh <path/to/Dory.app> <version> [out.dmg]}"
VERSION="${2:?usage: scripts/make-dmg.sh <path/to/Dory.app> <version> [out.dmg]}"
OUT="${3:-release-build/Dory-$VERSION.dmg}"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' \
  || { echo "make-dmg: version must be SemVer-like" >&2; exit 64; }
[ -d "$APP" ] && [ ! -L "$APP" ] && [ "$(basename "$APP")" = Dory.app ] \
  || { echo "make-dmg: input must be a direct Dory.app directory" >&2; exit 66; }
APP_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$APP")"
APP_PHYSICAL="$(cd "$APP" && pwd -P)"
[ "$APP_LOGICAL" = "$APP_PHYSICAL" ] \
  || { echo "make-dmg: input app has an indirect ancestor" >&2; exit 66; }
[ ! -L "$OUT" ] || { echo "make-dmg: output cannot be a symlink" >&2; exit 66; }
VOL="Dory $VERSION"
WORK="$(mktemp -d)"; STAGE="$WORK/stage"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE"
cp -R "$APP_PHYSICAL" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Volume icon from the app's icon set (best-effort — DMG is still valid without it).
ICONSET="$WORK/Dory.iconset"; mkdir -p "$ICONSET"
if cp Dory/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/" 2>/dev/null \
   && iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns" 2>/dev/null; then
  SetFile -a C "$STAGE" 2>/dev/null || true
fi

mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
if command -v diskutil >/dev/null 2>&1 \
  && diskutil image create from --help >/dev/null 2>&1; then
  # macOS 27 deprecates hdiutil's folder-image path. Its replacement also avoids the
  # misleading ENOSPC failure hdiutil can return on large sparse VM payloads.
  diskutil image create from --format UDZO --volumeName "$VOL" "$STAGE" "$OUT" >/dev/null
else
  # Keep release builders on older supported macOS versions working until diskutil's
  # image subcommand is available there.
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
fi
echo "$OUT"
