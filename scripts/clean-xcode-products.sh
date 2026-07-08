#!/bin/bash
# Scrub transient Xcode products that macOS may reject as "damaged" after
# DerivedData provenance/quarantine metadata is stamped onto test host bundles.
set -euo pipefail

strip_test_products=0
root="$HOME/Library/Developer/Xcode/DerivedData"

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

[ -d "$root" ] || exit 0

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

strip_test_payloads() {
  local app="$1"
  [ "$strip_test_products" -eq 1 ] || return 0
  [ -d "$app" ] || return 0
  rm -rf "$(dirname "$app")/DoryUITests-Runner.app"
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
    Dory.app) strip_test_payloads "$app" ;;
  esac
done < <(find "$root" -path '*/Build/Products/*' \( -name 'Dory.app' -o -name 'DoryUITests-Runner.app' \) -type d -prune -print0)
