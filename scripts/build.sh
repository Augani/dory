#!/bin/bash
# Build Dory with a full Xcode toolchain from the command line.
# The project is saved in Xcode 16 format (objectVersion 77); building from the CLI never
# re-bumps that format, so both stable Xcode 26.x and Xcode 27 are safe here (only the Xcode
# GUI re-bumps it). Override the toolchain explicitly with
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -u
cd "$(dirname "$0")/.."

find_xcode() {
  local dev app found
  for app in /Applications/Xcode.app /Applications/Xcode-*.app \
             "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
    dev="$app/Contents/Developer"
    [ -x "$dev/usr/bin/xcodebuild" ] && { printf '%s' "$dev"; return 0; }
  done
  found="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
  [ -n "$found" ] && [ -x "$found/Contents/Developer/usr/bin/xcodebuild" ] \
    && { printf '%s' "$found/Contents/Developer"; return 0; }
  return 1
}

# Respect an explicit DEVELOPER_DIR; otherwise fall back to a discovered full Xcode when the
# active `xcode-select` path is Command Line Tools (which ships no xcodebuild).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  active="$(xcode-select -p 2>/dev/null || true)"
  need_fallback=0
  case "$active" in
    ""|*CommandLineTools*) need_fallback=1 ;;
  esac
  [ -x "$active/usr/bin/xcodebuild" ] || need_fallback=1
  if [ "$need_fallback" -eq 1 ]; then
    if DEVELOPER_DIR="$(find_xcode)"; then
      export DEVELOPER_DIR
      echo "note: active xcode-select ('${active:-unset}') has no xcodebuild; using DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    else
      echo "error: no full Xcode found. Install Xcode.app or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
      exit 1
    fi
  fi
fi

LOG=/tmp/dory_build.log
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1
status=$?

# Xcode 27 intermittently re-serializes the project to objectVersion 110 (breaks stable Xcode + CI);
# pin it back to 77. Only rewrites that one line, so intended pbxproj edits are preserved.
sed -i '' 's/objectVersion = 110;/objectVersion = 77;/' Dory.xcodeproj/project.pbxproj 2>/dev/null || true

# macOS 27 can stamp DerivedData app products with provenance metadata that leaves the debug
# bundle launchable-looking but stuck before main/dyld. Clear it from this target's debug product.
for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
  [ -d "$app" ] || continue
  xattr -cr "$app" 2>/dev/null || true
  xattr -dr com.apple.provenance "$app" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
done

grep -E '(error:|warning:.*\.swift|BUILD SUCCEEDED|BUILD FAILED)' "$LOG" | tail -60 || true
echo "xcodebuild_exit=$status"
exit "$status"
