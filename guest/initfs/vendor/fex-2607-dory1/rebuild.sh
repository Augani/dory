#!/bin/bash
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$VENDOR_DIR/../../../.." && pwd)"
PATCH="$ROOT/patches/fex-container-fd-isolation.patch"
SOURCE_COMMIT=1cc4b93e7a71c883ec021b71359f136394dc1f3c
PATCH_SHA256=ce4b0d955a1c982b071c3d34b34f58e350526cd0b55b28980fbe0594abe1dc9b
FEX_SHA256=385c2495a46f00450ffa62e641552b7f18928aa18f3d0a8b621c526ccf79e009
FEXSERVER_SHA256=9a4b098f004a5e9e1759ead38795f48bbc900e654d51e3bcf20d9921f00b2ef4
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

[ "$(sha256_file "$PATCH")" = "$PATCH_SHA256" ] || {
  echo "Dory FEX patch hash mismatch" >&2
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
git -C "$SOURCE" submodule update --init --recursive --depth 1
git -C "$SOURCE" apply --check "$PATCH"
git -C "$SOURCE" apply "$PATCH"

"$DOCKER_BIN" build --platform linux/arm64 -f "$VENDOR_DIR/Dockerfile" -t "$IMAGE" "$SOURCE"
CID="$("$DOCKER_BIN" create "$IMAGE" /FEX --version)"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/FEX" "$OUT_DIR/FEXServer"
"$DOCKER_BIN" cp "$CID:/FEX" "$OUT_DIR/FEX"
"$DOCKER_BIN" cp "$CID:/FEXServer" "$OUT_DIR/FEXServer"
chmod 0755 "$OUT_DIR/FEX" "$OUT_DIR/FEXServer"

[ "$(sha256_file "$OUT_DIR/FEX")" = "$FEX_SHA256" ] || {
  echo "rebuilt FEX hash does not match the shipped artifact" >&2
  exit 1
}
[ "$(sha256_file "$OUT_DIR/FEXServer")" = "$FEXSERVER_SHA256" ] || {
  echo "rebuilt FEXServer hash does not match the shipped artifact" >&2
  exit 1
}

cmp "$OUT_DIR/FEX" "$VENDOR_DIR/FEX"
cmp "$OUT_DIR/FEXServer" "$VENDOR_DIR/FEXServer"
echo "verified reproducible Dory FEX-2607 binary pair in $OUT_DIR"
