#!/bin/bash
# Test Dory with the toolchain from `xcode-select` (stable Xcode 26.5).
# Override the toolchain with DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -euo pipefail
cd "$(dirname "$0")/.."

xcode_args=(-project Dory.xcodeproj -scheme Dory -destination 'platform=macOS')

xcodebuild "${xcode_args[@]}" build-for-testing

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
