#!/bin/bash
# Scrub transient Xcode products that macOS may reject as "damaged" after
# DerivedData provenance/quarantine metadata is stamped onto test host bundles.
set -euo pipefail

strip_test_products=0
root="$HOME/Library/Developer/Xcode/DerivedData"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strip-test-products)
      strip_test_products=1
      shift
      ;;
    --root)
      root="${2:?--root requires a path}"
      shift 2
      ;;
    *)
      echo "usage: scripts/clean-xcode-products.sh [--strip-test-products] [--root PATH]" >&2
      exit 2
      ;;
  esac
done

unregister_launchservices() {
  local app="$1"
  [ -n "$app" ] || return 0
  [ -x "$lsregister" ] || return 0
  "$lsregister" -u "$app" >/dev/null 2>&1 || true
}

clear_xattrs() {
  local app="$1"
  [ -d "$app" ] || return 0
  xattr -cr "$app" 2>/dev/null || true
  xattr -dr com.apple.provenance "$app" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.quarantine "$item" 2>/dev/null || true
  done < <(find "$app" -print0)
}

registered_test_runners() {
  [ -x "$lsregister" ] || return 0
  "$lsregister" -dump 2>/dev/null | awk '
    BEGIN { RS = ""; FS = "\n" }
    /DoryUITests-Runner|com\.pythonxi\.DoryUITests\.xctrunner/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[[:space:]]*path:[[:space:]]*/) {
          path = $i
          sub(/^[[:space:]]*path:[[:space:]]*/, "", path)
          sub(/[[:space:]]+\(0x[0-9A-Fa-f]+\).*$/, "", path)
          print path
        }
      }
    }'
}

purge_registered_test_runners() {
  local app
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    case "$app" in
      *DoryUITests-Runner.app)
        unregister_launchservices "$app"
        clear_xattrs "$app"
        rm -rf "$app"
        ;;
    esac
  done < <(registered_test_runners | sort -u)
}

purge_registered_test_runners

[ -d "$root" ] || exit 0

strip_test_payloads() {
  local app="$1" runner
  [ "$strip_test_products" -eq 1 ] || return 0
  [ -d "$app" ] || return 0
  runner="$(dirname "$app")/DoryUITests-Runner.app"
  unregister_launchservices "$runner"
  clear_xattrs "$runner"
  rm -rf "$runner"
  rm -rf "$app/Contents/PlugIns/DoryTests.xctest"
  rm -rf "$app/Contents/Frameworks/XCTest.framework" \
         "$app/Contents/Frameworks/XCTestCore.framework" \
         "$app/Contents/Frameworks/XCTestSupport.framework" \
         "$app/Contents/Frameworks/XCTAutomationSupport.framework" \
         "$app/Contents/Frameworks/XCUIAutomation.framework" \
         "$app/Contents/Frameworks/XCUnit.framework" \
         "$app/Contents/Frameworks/Testing.framework" \
         "$app/Contents/Frameworks/libXCTestBundleInject.dylib" \
         "$app/Contents/Frameworks/libXCTestSwiftSupport.dylib"
}

while IFS= read -r -d '' app; do
  clear_xattrs "$app"
  case "$(basename "$app")" in
    DoryUITests-Runner.app) unregister_launchservices "$app" ;;
    Dory.app) strip_test_payloads "$app" ;;
  esac
done < <(find "$root" -path '*/Build/Products/*' \( -name 'Dory.app' -o -name 'DoryUITests-Runner.app' \) -type d -prune -print0)
