#!/bin/bash
# Build Dory with the toolchain from `xcode-select` (stable Xcode 26.5).
# The project is saved in Xcode 16 format (objectVersion 77), so stable Xcode can open it.
# Override the toolchain with DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
cd "$(dirname "$0")/.."
LOG=/tmp/dory_build.log
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1
status=$?
grep -E '(error:|warning:.*\.swift|BUILD SUCCEEDED|BUILD FAILED)' "$LOG" | tail -60 || true
echo "xcodebuild_exit=$status"
