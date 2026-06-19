#!/bin/bash
# Test Dory using the Xcode 27 toolchain.
set -euo pipefail
export DEVELOPER_DIR="/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer"
cd "$(dirname "$0")/.."
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  test "$@"
