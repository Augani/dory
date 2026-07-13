#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64)
    ARCH=arm64
    TARGET=aarch64-unknown-linux-musl
    CROSS_CC="${DORY_AARCH64_LINUX_MUSL_CC:-}"
    DEFAULT_CROSS_CC=aarch64-linux-musl-gcc
    ;;
  amd64|x86_64)
    ARCH=amd64
    TARGET=x86_64-unknown-linux-musl
    CROSS_CC="${DORY_X86_64_LINUX_MUSL_CC:-}"
    DEFAULT_CROSS_CC=x86_64-linux-musl-gcc
    ;;
  *) echo "usage: $0 [arm64|amd64]" >&2; exit 64 ;;
esac

INPUTS=(
  guest/initfs/build.sh
  guest/initfs/init
  guest/initfs/PINS
  dory-core/Cargo.lock
  dory-core/Cargo.toml
)

# Only the guest Rust packages and their local transitive dependencies affect these binaries. Hashing
# unrelated workspace crates made a UI/FFI-only change invalidate a perfectly current initfs, while
# omitting protobuf sources let a protocol change falsely pass verification.
for package in agent pb proto runc-wrapper sync; do
  [ -d "dory-core/$package" ] || {
    echo "missing required guest Rust package: dory-core/$package" >&2
    exit 1
  }
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

for optional in \
  .cargo/config .cargo/config.toml rust-toolchain rust-toolchain.toml \
  dory-core/.cargo/config dory-core/.cargo/config.toml \
  dory-core/rust-toolchain dory-core/rust-toolchain.toml; do
  [ ! -f "$optional" ] || INPUTS+=("$optional")
done

if [ "$ARCH" = arm64 ]; then
  INPUTS+=(
    guest/initfs/vendor/fex-2607-dory1/Dockerfile
    guest/initfs/vendor/fex-2607-dory1/Dockerfile.dockerignore
    guest/initfs/vendor/fex-2607-dory1/FEX
    guest/initfs/vendor/fex-2607-dory1/FEXServer
    guest/initfs/vendor/fex-2607-dory1/BUILD_PACKAGES.txt
    guest/initfs/vendor/fex-2607-dory1/LICENSE.FEX
    guest/initfs/vendor/fex-2607-dory1/README.md
    guest/initfs/vendor/fex-2607-dory1/rebuild.sh
    patches/fex-container-fd-isolation.patch
  )
fi

if command -v rust-lld >/dev/null 2>&1; then
  LINKER="$(command -v rust-lld)"
elif [ -n "$CROSS_CC" ] && command -v "$CROSS_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$CROSS_CC")"
elif command -v "$DEFAULT_CROSS_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$DEFAULT_CROSS_CC")"
else
  echo "no linker found for $TARGET; install rust-lld or $DEFAULT_CROSS_CC" >&2
  exit 1
fi

EFFECTIVE_RUSTFLAGS="${RUSTFLAGS:-}"
if [ "$(basename "$LINKER")" = rust-lld ]; then
  EFFECTIVE_RUSTFLAGS="$EFFECTIVE_RUSTFLAGS -C linker-flavor=ld.lld"
fi

# Include the Rust toolchain and effective build flags because both can change the static guest
# binary without changing source. Paths are relative to the repository so clones hash identically.
{
  printf 'schema=2\narch=%s\ntarget=%s\nsize_mb=%s\nrustflags=%s\n' \
    "$ARCH" "$TARGET" "${DORY_INITFS_SIZE_MB:-1024}" "$EFFECTIVE_RUSTFLAGS"
  rustc -Vv
  cargo -V
  printf 'linker_sha256=%s\n' "$(shasum -a 256 "$LINKER" | awk '{print $1}')"
  for input in "${INPUTS[@]}"; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
