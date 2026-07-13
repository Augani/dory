#!/bin/bash
# Reproducibly build the static Linux/arm64 helper used for exact named-volume transfer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/dory-core"
TARGET="aarch64-unknown-linux-musl"
OUTPUT=""
IMAGE_OUTPUT=""
IMAGE_METADATA_OUTPUT=""

usage() {
  echo "usage: scripts/build-transfer-helper.sh [--output PATH] [--image-output PATH [--image-metadata-output PATH]]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT="$2"
      shift 2
      ;;
    --image-output)
      [ "$#" -ge 2 ] || usage
      IMAGE_OUTPUT="$2"
      shift 2
      ;;
    --image-metadata-output)
      [ "$#" -ge 2 ] || usage
      IMAGE_METADATA_OUTPUT="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -z "$IMAGE_METADATA_OUTPUT" ] || [ -n "$IMAGE_OUTPUT" ] || usage

command -v cargo >/dev/null 2>&1 || { echo "transfer helper build: cargo is required" >&2; exit 2; }
command -v rustc >/dev/null 2>&1 || { echo "transfer helper build: rustc is required" >&2; exit 2; }
command -v rustup >/dev/null 2>&1 || { echo "transfer helper build: rustup is required" >&2; exit 2; }

host="$(rustc -vV | awk '/^host: / { print $2 }')"
sysroot="$(rustc --print sysroot)"
linker="$sysroot/lib/rustlib/$host/bin/rust-lld"
[ -x "$linker" ] || {
  echo "transfer helper build: rust-lld is unavailable in toolchain $sysroot" >&2
  exit 2
}

if ! rustc --print target-libdir --target "$TARGET" >/dev/null 2>&1; then
  echo "transfer helper build: install $TARGET with: rustup target add $TARGET" >&2
  exit 2
fi

target_dir="${CARGO_TARGET_DIR:-$CORE/target}"
binary="$target_dir/$TARGET/release/dory-transfer-helper"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$linker"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C linker-flavor=ld.lld --remap-path-prefix=$ROOT=/usr/src/dory"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}"

(
  cd "$CORE"
  cargo build --locked -p dory-transfer-helper --release --target "$TARGET"
)

file "$binary" | grep -Eq 'ELF 64-bit.*(ARM aarch64|ARM64).*statically linked' || {
  echo "transfer helper build: output is not a static Linux/arm64 ELF" >&2
  exit 1
}

if [ -n "$OUTPUT" ]; then
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$binary" "$OUTPUT"
  chmod 0755 "$OUTPUT"
  binary="$OUTPUT"
fi

digest="$(shasum -a 256 "$binary" | awk '{print $1}')"
size="$(stat -f %z "$binary" 2>/dev/null || stat -c %s "$binary")"
if [ -n "$IMAGE_OUTPUT" ]; then
  image_arguments=(--helper "$binary" --output "$IMAGE_OUTPUT")
  if [ -n "$IMAGE_METADATA_OUTPUT" ]; then
    image_arguments+=(--metadata-output "$IMAGE_METADATA_OUTPUT")
  fi
  python3 "$ROOT/scripts/build-transfer-helper-image.py" "${image_arguments[@]}"
else
  printf '{"schemaVersion":1,"platform":"linux/arm64","sha256":"%s","bytes":%s,"path":"%s"}\n' \
    "$digest" "$size" "$binary"
fi
