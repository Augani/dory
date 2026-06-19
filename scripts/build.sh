#!/bin/bash
# Build Dory using the Xcode 27 toolchain that supports project format 110.
export DEVELOPER_DIR="/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer"
cd "$(dirname "$0")/.."
LOG=/tmp/dory_build.log
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1
status=$?
grep -E '(error:|warning:.*\.swift|BUILD SUCCEEDED|BUILD FAILED)' "$LOG" | tail -60 || true
echo "xcodebuild_exit=$status"
