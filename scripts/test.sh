#!/bin/bash
# Test Dory with a full Xcode toolchain. Building/testing from the CLI never re-bumps the
# project's objectVersion 77 (only the Xcode GUI does). Override explicitly with
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -euo pipefail
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

if [ -z "${DEVELOPER_DIR:-}" ]; then
  active="$(xcode-select -p 2>/dev/null || true)"
  need_fallback=0
  case "$active" in ""|*CommandLineTools*) need_fallback=1 ;; esac
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

xcode_args=(-project Dory.xcodeproj -scheme Dory -destination 'platform=macOS')
if [ -n "${CI:-}" ]; then
  xcode_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi

xcodebuild "${xcode_args[@]}" build-for-testing

# Xcode 27 intermittently re-serializes the project to objectVersion 110 (breaks stable Xcode + CI);
# pin it back to 77 before the test phase. Only rewrites that one line.
sed -i '' 's/objectVersion = 110;/objectVersion = 77;/' Dory.xcodeproj/project.pbxproj 2>/dev/null || true

# macOS 27 stamps DerivedData products with provenance metadata that syspolicyd rejects
# once XCTest injects its test-host libraries. Clearing it from the transient build products
# keeps the hosted unit-test host (Dory.app) and the UI-test runner (DoryUITests-Runner.app)
# launchable without changing source files.
while IFS= read -r app; do
  xattr -cr "$app" 2>/dev/null || true
  xattr -dr com.apple.provenance "$app" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.quarantine "$item" 2>/dev/null || true
  done < <(find "$app" -print0)
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/*' -name 'Dory*.app' -type d -prune -print)

xcodebuild "${xcode_args[@]}" test-without-building "$@"
