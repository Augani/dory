#!/bin/bash
# Scrub transient Xcode products that macOS may reject as "damaged" after
# DerivedData quarantine metadata is stamped onto test host bundles.
set -euo pipefail

strip_test_products=0
remove_app_products=0
root="$HOME/Library/Developer/Xcode/DerivedData"
lsregister="${DORY_LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strip-test-products)
      strip_test_products=1
      shift
      ;;
    --remove-app-products)
      remove_app_products=1
      shift
      ;;
    --root)
      root="${2:?--root requires a path}"
      shift 2
      ;;
    *)
      echo "usage: scripts/clean-xcode-products.sh [--strip-test-products] [--remove-app-products] [--root PATH]" >&2
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

has_quarantine_xattrs() {
  local app="$1" item
  while IFS= read -r -d '' item; do
    if xattr -p com.apple.quarantine "$item" >/dev/null 2>&1; then
      return 0
    fi
  done < <(find "$app" -print0)
  return 1
}

scrub_xattrs_once() {
  local app="$1" item
  xattr -cr "$app" 2>/dev/null || true
  xattr -dr com.apple.provenance "$app" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.quarantine "$item" 2>/dev/null || true
  done < <(find "$app" -print0)
}

clear_xattrs() {
  local app="$1" attempt item
  [ -d "$app" ] || return 0
  for attempt in $(seq 1 5); do
    scrub_xattrs_once "$app"
    if ! has_quarantine_xattrs "$app"; then
      # Require quarantine to remain clear across a short quiescence window before handing the
      # bundle back to LaunchServices. com.apple.provenance is system-managed and may remain
      # protected by SIP, so its deletion is deliberately best-effort rather than a launch gate.
      sleep 0.05
      has_quarantine_xattrs "$app" || return 0
    fi
    sleep 0.05
  done
  echo "clean-xcode-products: could not clear quarantine metadata from $app" >&2
  while IFS= read -r -d '' item; do
    if xattr -p com.apple.quarantine "$item" >/dev/null 2>&1; then
      echo "clean-xcode-products: quarantine persisted on $item" >&2
      xattr -d com.apple.quarantine "$item" >&2 || true
    fi
  done < <(find "$app" -print0)
  return 1
}

remove_product_bundle() {
  local app="$1"
  case "$app" in
    "$root"/*/Build/Products/*/Dory.app|"$root"/*/Build/Products/*/DoryUITests-Runner.app)
      find "$app" -depth -delete
      ;;
    *)
      echo "clean-xcode-products: refusing to remove unexpected bundle path: $app" >&2
      return 1
      ;;
  esac
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
    DoryUITests-Runner.app)
      unregister_launchservices "$app"
      [ "$remove_app_products" -eq 0 ] || remove_product_bundle "$app"
      ;;
    Dory.app)
      # Xcode registers the test host before this scrub. macOS can retain the original provenance
      # assessment in LaunchServices even after the xattrs are gone, yielding the misleading
      # “damaged” dialog / IDELaunchErrorDomain Code 20. Dropping that cached registration is
      # sufficient; xcodebuild launches the cleaned test host directly and may register it afresh.
      unregister_launchservices "$app"
      strip_test_payloads "$app"
      [ "$remove_app_products" -eq 0 ] || remove_product_bundle "$app"
      ;;
  esac
done < <(find "$root" -path '*/Build/Products/*' \( -name 'Dory.app' -o -name 'DoryUITests-Runner.app' \) -type d -prune -print0)
