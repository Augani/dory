#!/bin/bash
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$VENDOR_DIR/../../../.." && pwd)"
CONTAINER_PATCH="$ROOT/patches/fex-container-fd-isolation.patch"
PROCESSOR_ID_PATCH="$ROOT/patches/fex-processor-id-stack-fix.patch"
SIGNAL_CONTEXT_PATCH="$ROOT/patches/fex-restore-complete-signal-context.patch"
SOURCE_COMMIT=1cc4b93e7a71c883ec021b71359f136394dc1f3c
CONTAINER_PATCH_SHA256=374eb59a207c0356f548295552f235c0eeadcdbac360a64b01535933a1af8f8a
PROCESSOR_ID_PATCH_SHA256=e1da91d76caf48ed30183486abcc9a0eb768d28fd5d041a8b4cbe1c7b75df35c
SIGNAL_CONTEXT_PATCH_SHA256=e405db087203d5f22d50b54820b6a2120d013c0cdd33d1db343f4fac4c1d1e22
FEX_SHA256=01921fa471efc53c955b1d6263f7df4ad0f08f082669a3a7adb6f1e1d5ac0c28
FEXSERVER_SHA256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597
BUILD_PACKAGES_SHA256=ad3b0e4ab4e53ac328b0209f592a6f86100f5ca2c17715f2b40ee9b130b0f0b1
DOCKER_BIN="${DORY_FEX_DOCKER:-docker}"

if [ "$#" -ne 1 ] || [[ "$1" != /* ]]; then
  echo "usage: $0 /absolute/output/directory" >&2
  exit 64
fi
OUT_DIR="$1"

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
[ -x "$DOCKER_BIN" ] || command -v "$DOCKER_BIN" >/dev/null 2>&1 || {
  echo "Docker CLI not found: $DOCKER_BIN" >&2
  exit 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

[ "$(sha256_file "$CONTAINER_PATCH")" = "$CONTAINER_PATCH_SHA256" ] || {
  echo "Dory FEX container patch hash mismatch" >&2
  exit 1
}
[ "$(sha256_file "$PROCESSOR_ID_PATCH")" = "$PROCESSOR_ID_PATCH_SHA256" ] || {
  echo "Dory FEX ProcessorID patch hash mismatch" >&2
  exit 1
}
[ "$(sha256_file "$SIGNAL_CONTEXT_PATCH")" = "$SIGNAL_CONTEXT_PATCH_SHA256" ] || {
  echo "Dory FEX signal-context patch hash mismatch" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-fex-2607.XXXXXX")"
SOURCE="$TMP_ROOT/FEX"
IMAGE="dory-fex-2607-dory1-build:$$"
CID=""
cleanup() {
  [ -z "$CID" ] || "$DOCKER_BIN" rm -f "$CID" >/dev/null 2>&1 || true
  "$DOCKER_BIN" image rm -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

git clone --filter=blob:none --no-checkout https://github.com/FEX-Emu/FEX.git "$SOURCE"
git -C "$SOURCE" checkout --detach "$SOURCE_COMMIT"
git -C "$SOURCE" submodule update --init --depth 1 -- \
  External/drm-headers \
  External/fmt \
  External/jemalloc_glibc \
  External/range-v3 \
  External/rpmalloc \
  External/unordered_dense \
  External/xxhash \
  Source/Common/cpp-optparse
git -C "$SOURCE" apply --check "$CONTAINER_PATCH"
git -C "$SOURCE" apply "$CONTAINER_PATCH"
git -C "$SOURCE" apply --check --unidiff-zero "$PROCESSOR_ID_PATCH"
git -C "$SOURCE" apply --unidiff-zero "$PROCESSOR_ID_PATCH"
git -C "$SOURCE" apply --check --unidiff-zero "$SIGNAL_CONTEXT_PATCH"
git -C "$SOURCE" apply --unidiff-zero "$SIGNAL_CONTEXT_PATCH"

"$DOCKER_BIN" build --progress=plain --no-cache-filter builder --platform linux/arm64 \
  -f "$VENDOR_DIR/Dockerfile" -t "$IMAGE" "$SOURCE"
CID="$("$DOCKER_BIN" create "$IMAGE" /FEX --version)"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/FEX" "$OUT_DIR/FEXServer" "$OUT_DIR/BUILD_PACKAGES.txt"
"$DOCKER_BIN" cp "$CID:/FEX" "$OUT_DIR/FEX"
"$DOCKER_BIN" cp "$CID:/FEXServer" "$OUT_DIR/FEXServer"
"$DOCKER_BIN" cp "$CID:/build-packages.txt" "$OUT_DIR/BUILD_PACKAGES.txt"
chmod 0755 "$OUT_DIR/FEX" "$OUT_DIR/FEXServer"

actual_fex_sha256="$(sha256_file "$OUT_DIR/FEX")"
actual_fexserver_sha256="$(sha256_file "$OUT_DIR/FEXServer")"
actual_build_packages_sha256="$(sha256_file "$OUT_DIR/BUILD_PACKAGES.txt")"

[ "$actual_fex_sha256" = "$FEX_SHA256" ] || {
  echo "rebuilt FEX hash does not match the shipped artifact: expected $FEX_SHA256 got $actual_fex_sha256" >&2
  exit 1
}
[ "$actual_fexserver_sha256" = "$FEXSERVER_SHA256" ] || {
  echo "rebuilt FEXServer hash does not match the shipped artifact: expected $FEXSERVER_SHA256 got $actual_fexserver_sha256" >&2
  exit 1
}
[ "$actual_build_packages_sha256" = "$BUILD_PACKAGES_SHA256" ] || {
  echo "rebuilt FEX package-manifest hash does not match the shipped artifact: expected $BUILD_PACKAGES_SHA256 got $actual_build_packages_sha256" >&2
  exit 1
}

cmp "$OUT_DIR/FEX" "$VENDOR_DIR/FEX"
cmp "$OUT_DIR/FEXServer" "$VENDOR_DIR/FEXServer"
cmp "$OUT_DIR/BUILD_PACKAGES.txt" "$VENDOR_DIR/BUILD_PACKAGES.txt"
echo "verified reproducible Dory FEX-2607 binary pair in $OUT_DIR"
