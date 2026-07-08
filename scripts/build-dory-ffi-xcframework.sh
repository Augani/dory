#!/usr/bin/env bash
# Build libdory_ffi.a (arm64 + x86_64), assemble a static DoryFFI.xcframework,
# and generate the Swift bindings. Idempotent. Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/dory-core"
SWIFT="$ROOT/dory-core-swift"
ART="$SWIFT/artifacts"
GEN="$SWIFT/Sources/DoryCore/generated"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null

echo "building staticlib (unstripped release) for both arches..."
# strip=false so the UniFFI extern "C" symbols survive for linking.
(
  cd "$CORE"
  cargo build -p dory-ffi --release --config 'profile.release.strip=false' \
    --target aarch64-apple-darwin --target x86_64-apple-darwin
)

echo "lipo -> universal static lib..."
mkdir -p "$WORK/lib"
lipo -create \
  "$CORE/target/aarch64-apple-darwin/release/libdory_ffi.a" \
  "$CORE/target/x86_64-apple-darwin/release/libdory_ffi.a" \
  -output "$WORK/lib/libdory_ffi.a"

echo "generating Swift bindings..."
# Bindgen reads UniFFI metadata from the unstripped cdylib.
(
  cd "$CORE"
  cargo build -p dory-ffi --release --config 'profile.release.strip=false' \
    --target aarch64-apple-darwin >/dev/null
  cargo run -p dory-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library "target/aarch64-apple-darwin/release/libdory_ffi.dylib" \
    --language swift --out-dir "$WORK/gen"
)

echo "assembling headers dir..."
mkdir -p "$WORK/headers"
cp "$WORK/gen/dory_ffiFFI.h" "$WORK/headers/dory_ffiFFI.h"
# xcodebuild expects module.modulemap in the headers dir; module name must be dory_ffiFFI.
cp "$WORK/gen/dory_ffiFFI.modulemap" "$WORK/headers/module.modulemap"

echo "creating xcframework..."
rm -rf "$ART/DoryFFI.xcframework"
mkdir -p "$ART"
xcodebuild -create-xcframework \
  -library "$WORK/lib/libdory_ffi.a" -headers "$WORK/headers" \
  -output "$ART/DoryFFI.xcframework"

echo "installing generated Swift into DoryCore..."
mkdir -p "$GEN"
cp "$WORK/gen/dory_ffi.swift" "$GEN/dory_ffi.swift"
# UniFFI 0.28 emits this as `var`, which Swift 6 treats as unsafe global
# mutable state. The value is initialized once and never mutated.
perl -0pi -e 's/private var initializationResult: InitializationResult = \{/private let initializationResult: InitializationResult = \{/' \
  "$GEN/dory_ffi.swift"

echo "done: $ART/DoryFFI.xcframework"
