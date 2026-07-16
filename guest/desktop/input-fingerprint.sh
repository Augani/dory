#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/desktop/PINS

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the desktop image currently supports arm64 only" >&2; exit 64 ;;
esac
DISTRO="${2:-debian}"
case "$DISTRO" in
  debian|ubuntu|kali) ;;
  *) echo "unsupported desktop distribution: $DISTRO" >&2; exit 64 ;;
esac

TARGET=aarch64-unknown-linux-musl
if command -v rust-lld >/dev/null 2>&1; then
  LINKER="$(command -v rust-lld)"
elif [ -n "${DORY_AARCH64_LINUX_MUSL_CC:-}" ] && command -v "$DORY_AARCH64_LINUX_MUSL_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$DORY_AARCH64_LINUX_MUSL_CC")"
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
  LINKER="$(command -v aarch64-linux-musl-gcc)"
else
  echo "no linker found for $TARGET; install rust-lld or an aarch64 musl cross compiler" >&2
  exit 1
fi

RUSTFLAGS_EFFECTIVE="${RUSTFLAGS:-}"
if [ "$(basename "$LINKER")" = rust-lld ]; then
  RUSTFLAGS_EFFECTIVE="$RUSTFLAGS_EFFECTIVE -C linker-flavor=ld.lld"
fi

INPUTS=(
  guest/desktop/PINS
  guest/desktop/build.sh
  guest/desktop/input-fingerprint.sh
  guest/desktop/verify-build.sh
  dory-core/Cargo.lock
  dory-core/Cargo.toml
)
while IFS= read -r input; do
  INPUTS+=("$input")
done < <(find guest/desktop/rootfs-overlay -type f | LC_ALL=C sort)
for package in agent pb proto sync; do
  while IFS= read -r input; do
    INPUTS+=("$input")
  done < <(
    find "dory-core/$package" \
      -path '*/target' -prune -o \
      -path '*/tests' -prune -o \
      -path '*/examples' -prune -o \
      -path '*/benches' -prune -o \
      -type f \( -name '*.rs' -o -name '*.proto' -o -name Cargo.toml -o -name build.rs \) -print \
      | LC_ALL=C sort
  )
done

{
  printf 'schema=2\narch=arm64\ndistro=%s\ntarget=%s\nimage_size_mb=%s\nrustflags=%s\n' \
    "$DISTRO" "$TARGET" "${DORY_DESKTOP_IMAGE_SIZE_MB:-$DESKTOP_IMAGE_SIZE_MB}" "$RUSTFLAGS_EFFECTIVE"
  rustc -Vv
  cargo -V
  printf 'linker_sha256=%s\n' "$(shasum -a 256 "$LINKER" | awk '{print $1}')"
  for input in "${INPUTS[@]}"; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
