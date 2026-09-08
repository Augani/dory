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
STAMP="$ART/.dory-ffi-input.sha256"
OUTPUT_STAMP="$ART/.dory-ffi-output.sha256"
DEPLOYMENT_TARGET="${DORY_FFI_MACOSX_DEPLOYMENT_TARGET:-14.0}"
DEPLOYMENT_RECEIPT="$ART/DoryFFI.xcframework/deployment-targets.json"

usage() {
  echo "usage: build-dory-ffi-xcframework.sh [--if-needed]" >&2
  exit 2
}

mode="force"
case "${1:-}" in
  "") ;;
  --if-needed) mode="if-needed" ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

input_fingerprint() {
  (
    cd "$ROOT"
    {
      printf 'rustc=%s\n' "$(rustc --version)"
      printf 'macosDeploymentTarget=%s\n' "$DEPLOYMENT_TARGET"
      shasum -a 256 dory-core/Cargo.toml dory-core/Cargo.lock \
        scripts/build-dory-ffi-xcframework.sh scripts/verify-dory-ffi-deployment-targets.py
      find dory-core/proto dory-core/pb dory-core/dataplane dory-core/remote \
           dory-core/ffi dory-core/sync \
        -type f \( -name '*.rs' -o -name '*.proto' -o -name 'Cargo.toml' -o -name 'build.rs' \) \
        -not -path '*/target/*' -print | LC_ALL=C sort | while IFS= read -r file; do
          shasum -a 256 "$file"
        done
    } | shasum -a 256 | awk '{print $1}'
  )
}

output_fingerprint() {
  (
    cd "$SWIFT"
    shasum -a 256 \
      artifacts/DoryFFI.xcframework/Info.plist \
      artifacts/DoryFFI.xcframework/macos-arm64_x86_64/libdory_ffi.a \
      artifacts/DoryFFI.xcframework/macos-arm64_x86_64/Headers/dory_ffiFFI.h \
      artifacts/DoryFFI.xcframework/macos-arm64_x86_64/Headers/module.modulemap \
      artifacts/DoryFFI.xcframework/deployment-targets.json \
      Sources/DoryCore/generated/dory_ffi.swift \
      | shasum -a 256 | awk '{print $1}'
  )
}

INPUT_FINGERPRINT="$(input_fingerprint)"
if [ "$mode" = "if-needed" ] \
   && [ -f "$ART/DoryFFI.xcframework/macos-arm64_x86_64/libdory_ffi.a" ] \
   && [ -f "$ART/DoryFFI.xcframework/macos-arm64_x86_64/Headers/dory_ffiFFI.h" ] \
   && [ -f "$GEN/dory_ffi.swift" ] \
   && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$INPUT_FINGERPRINT" ] \
   && [ -f "$OUTPUT_STAMP" ] \
   && OUTPUT_FINGERPRINT="$(output_fingerprint 2>/dev/null)" \
   && [ "$(cat "$OUTPUT_STAMP")" = "$OUTPUT_FINGERPRINT" ]; then
  echo "DoryFFI.xcframework is current ($INPUT_FINGERPRINT)"
  exit 0
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi
case "$DEPLOYMENT_TARGET" in
  14|14.0|14.0.0) DEPLOYMENT_TARGET=14.0 ;;
  *) echo "error: DORY_FFI_MACOSX_DEPLOYMENT_TARGET must be the supported floor 14.0" >&2; exit 64 ;;
esac
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
# C/C++ build-script output is keyed to Cargo's target directory rather than every relevant
# environment variable. A private target root makes an FFI rebuild independent of previously
# cached objects made against a newer SDK/deployment target.
export CARGO_TARGET_DIR="$WORK/cargo-target"

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
  "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libdory_ffi.a" \
  "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libdory_ffi.a" \
  -output "$WORK/lib/libdory_ffi.a"

echo "generating Swift bindings..."
# Bindgen reads UniFFI metadata from the unstripped cdylib.
(
  cd "$CORE"
  cargo build -p dory-ffi --release --config 'profile.release.strip=false' \
    --target aarch64-apple-darwin >/dev/null
  cargo run -p dory-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libdory_ffi.dylib" \
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

VTOOL="$(xcrun --find vtool)"
python3 "$ROOT/scripts/verify-dory-ffi-deployment-targets.py" \
  --library "$ART/DoryFFI.xcframework/macos-arm64_x86_64/libdory_ffi.a" \
  --maximum-macos "$DEPLOYMENT_TARGET" \
  --vtool "$VTOOL" \
  --output "$DEPLOYMENT_RECEIPT"

echo "installing generated Swift into DoryCore..."
mkdir -p "$GEN"
cp "$WORK/gen/dory_ffi.swift" "$GEN/dory_ffi.swift"
# UniFFI emits this as `var`, which Swift 6 treats as unsafe global
# mutable state. The value is initialized once and never mutated.
perl -0pi -e 's/private var initializationResult: InitializationResult = \{/private let initializationResult: InitializationResult = \{/' \
  "$GEN/dory_ffi.swift"

# Publish the cache receipts only after both the framework and Swift bindings are installed.
output_fingerprint > "$OUTPUT_STAMP"
printf '%s\n' "$INPUT_FINGERPRINT" > "$STAMP"

echo "done: $ART/DoryFFI.xcframework"
