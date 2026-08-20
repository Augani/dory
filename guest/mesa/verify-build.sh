#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the Dory Venus runtime currently supports arm64 only" >&2; exit 64 ;;
esac

OUT="${DORY_MESA_OUT_DIR:-$ROOT/guest/out}"
RUNTIME="$OUT/dory-mesa-venus-arm64.tar.zst"
STAMP="$OUT/dory-mesa-venus-build-arm64.stamp"
fail() {
  echo "Dory Venus runtime verification failed: $*" >&2
  exit 1
}

[ -s "$RUNTIME" ] || fail "missing $RUNTIME"
[ -s "$STAMP" ] || fail "missing $STAMP"
stamp_value() { sed -n "s/^$1=//p" "$STAMP"; }
[ "$(stamp_value schema)" = 1 ] || fail "unsupported stamp schema"
[ "$(stamp_value arch)" = arm64 ] || fail "runtime was built for another architecture"
[ "$(stamp_value mesa_version)" = "$MESA_VERSION" ] || fail "Mesa version is stale"
[ "$(stamp_value mesa_source_sha256)" = "$MESA_SOURCE_SHA256" ] \
  || fail "Mesa source pin is stale"
[ "$(stamp_value input_sha256)" = "$(guest/mesa/input-fingerprint.sh arm64)" ] \
  || fail "runtime inputs are stale"
[ "$(stamp_value runtime_sha256)" = "$(shasum -a 256 "$RUNTIME" | awk '{print $1}')" ] \
  || fail "runtime digest does not match its stamp"

ZSTD="${DORY_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
[ -n "$ZSTD" ] || fail "zstd is required"
"$ZSTD" -q -t "$RUNTIME" || fail "runtime archive is corrupt"

EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/dory-mesa-verify.XXXXXX")"
trap 'rm -rf "$EXTRACT"' EXIT
"$ZSTD" -q -d -c "$RUNTIME" | tar -xf - -C "$EXTRACT"
ICD="$EXTRACT/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json"
LIBRARY="$EXTRACT/opt/dory/mesa/lib/libvulkan_virtio.so"
PROBE="$EXTRACT/usr/lib/dory/dory-vulkan-probe"
MANIFEST="$EXTRACT/opt/dory/mesa/share/dory/runtime.env"
for path in "$ICD" "$LIBRARY" "$PROBE" "$MANIFEST"; do
  [ -s "$path" ] || fail "runtime archive is missing ${path#$EXTRACT}"
done
[ -L "$EXTRACT/opt/dory/mesa/lib/libxcb-keysyms.so.1" ] \
  || fail "runtime archive is missing its XCB keysyms ABI link"
grep -Fq '"api_version": "1.4.' "$ICD" || fail "ICD API version is invalid"
grep -Fq '"library_path": "/opt/dory/mesa/lib/libvulkan_virtio.so"' "$ICD" \
  || fail "ICD does not select the isolated Dory library"
grep -Fqx "mesa_version=$MESA_VERSION" "$MANIFEST" || fail "runtime manifest is stale"
grep -Fqx "mesa_source_sha256=$MESA_SOURCE_SHA256" "$MANIFEST" \
  || fail "runtime manifest source digest is stale"
file "$LIBRARY" | grep -Fq 'ELF 64-bit LSB shared object, ARM aarch64' \
  || fail "Venus ICD is not an ARM64 ELF shared library"
file "$PROBE" | grep -Fq 'ELF 64-bit LSB pie executable, ARM aarch64' \
  || fail "Vulkan probe is not an ARM64 ELF executable"
grep -aFq 'VK_KHR_swapchain' "$LIBRARY" \
  || fail "Venus ICD does not contain swapchain support"
if grep -aFq 'llvmpipe' "$LIBRARY"; then
  fail "isolated Venus ICD unexpectedly contains the software renderer"
fi

echo "verified Dory Mesa $MESA_VERSION Venus runtime"
