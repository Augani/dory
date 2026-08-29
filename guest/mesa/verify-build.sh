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
[ "$(stamp_value schema)" = 6 ] || fail "unsupported stamp schema"
[ "$(stamp_value arch)" = arm64 ] || fail "runtime was built for another architecture"
[ "$(stamp_value mesa_version)" = "$MESA_VERSION" ] || fail "Mesa version is stale"
[ "$(stamp_value mesa_source_commit)" = "$MESA_SOURCE_COMMIT" ] \
  || fail "Mesa source commit is stale"
[ "$(stamp_value mesa_source_tree)" = "$MESA_SOURCE_TREE" ] \
  || fail "Mesa source tree is stale"
[ "$(stamp_value mesa_source_date_epoch)" = "$MESA_SOURCE_DATE_EPOCH" ] \
  || fail "Mesa source epoch is stale"
[ "$(stamp_value libc_family)" = "$MESA_RUNTIME_LIBC_FAMILY" ] \
  || fail "runtime libc family is stale"
[ "$(stamp_value glibc_symbol_ceiling)" = "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" ] \
  || fail "runtime GNU-libc ceiling is stale"
[ "$(stamp_value input_sha256)" = "$(guest/mesa/input-fingerprint.sh arm64)" ] \
  || fail "runtime inputs are stale"
[ "$(stamp_value runtime_sha256)" = "$(shasum -a 256 "$RUNTIME" | awk '{print $1}')" ] \
  || fail "runtime digest does not match its stamp"

ZSTD="${DORY_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
[ -n "$ZSTD" ] || fail "zstd is required"
READELF="${DORY_AARCH64_READELF:-$(command -v aarch64-elf-readelf 2>/dev/null || true)}"
[ -n "$READELF" ] || fail "aarch64-elf-readelf is required for exact ELF verification"
"$ZSTD" -q -t "$RUNTIME" || fail "runtime archive is corrupt"

EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/dory-mesa-verify.XXXXXX")"
trap 'rm -rf "$EXTRACT"' EXIT
"$ZSTD" -q -d -c "$RUNTIME" | tar -xf - -C "$EXTRACT"
ICD="$EXTRACT/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json"
LIBRARY="$EXTRACT/opt/dory/mesa/lib/libvulkan_virtio.so"
PROBE="$EXTRACT/opt/dory/mesa/libexec/dory-vulkan-probe"
COMPOSITOR_PROBE="$EXTRACT/opt/dory/mesa/libexec/dory-vulkan-compositor-probe"
MANIFEST="$EXTRACT/opt/dory/mesa/share/dory/runtime.env"
BUILD_PACKAGES="$EXTRACT/opt/dory/mesa/share/dory/build-packages.txt"
for path in "$ICD" "$LIBRARY" "$PROBE" "$COMPOSITOR_PROBE" "$MANIFEST" \
    "$BUILD_PACKAGES"; do
  [ -s "$path" ] || fail "runtime archive is missing ${path#$EXTRACT}"
done
[ -z "$(find "$EXTRACT" -mindepth 1 -maxdepth 1 ! -name opt -print -quit)" ] \
  || fail "runtime archive writes outside its Dory-owned /opt tree"
[ -z "$(find "$EXTRACT/opt" -mindepth 1 -maxdepth 1 ! -name dory -print -quit)" ] \
  || fail "runtime archive writes outside /opt/dory"
[ -z "$(find "$EXTRACT/opt/dory" -mindepth 1 -maxdepth 1 ! -name mesa -print -quit)" ] \
  || fail "runtime archive contains a second Dory-owned component tree"
if find "$EXTRACT/opt/dory/mesa" \( -type f -o -type d \) \
    \( -perm -020 -o -perm -002 \) -print -quit | grep -q .; then
  fail "runtime archive contains a group- or world-writable path"
fi
if find "$EXTRACT/opt/dory/mesa" -type l -print -quit | grep -q .; then
  fail "runtime archive contains an indirect path"
fi
grep -Fq '"api_version": "1.4.' "$ICD" || fail "ICD API version is invalid"
grep -Fq '"library_path": "../../../lib/libvulkan_virtio.so"' "$ICD" \
  || fail "ICD is not relocatable within the signed Dory pack"
grep -Fqx "mesa_version=$MESA_VERSION" "$MANIFEST" || fail "runtime manifest is stale"
grep -Fqx 'schema=6' "$MANIFEST" || fail "runtime manifest schema is stale"
grep -Fqx "architecture=$MESA_RUNTIME_ARCH" "$MANIFEST" \
  || fail "runtime manifest architecture is stale"
grep -Fqx "libc_family=$MESA_RUNTIME_LIBC_FAMILY" "$MANIFEST" \
  || fail "runtime manifest libc family is stale"
grep -Fqx "vulkan_api=$MESA_RUNTIME_VULKAN_API" "$MANIFEST" \
  || fail "runtime manifest Vulkan API is stale"
grep -Fqx "vulkan13_features=$MESA_RUNTIME_VULKAN13_FEATURES" "$MANIFEST" \
  || fail "runtime manifest Vulkan 1.3 feature set is stale"
grep -Fqx "vulkan_device_extensions=$MESA_RUNTIME_VULKAN_DEVICE_EXTENSIONS" "$MANIFEST" \
  || fail "runtime manifest Vulkan device extensions are stale"
grep -Fqx "vulkan_instance_extensions=$MESA_RUNTIME_VULKAN_INSTANCE_EXTENSIONS" "$MANIFEST" \
  || fail "runtime manifest Vulkan instance extensions are stale"
grep -Fqx "wsi=$MESA_RUNTIME_WSI" "$MANIFEST" \
  || fail "runtime manifest WSI set is stale"
grep -Fqx "wsi_surface_gate=$MESA_RUNTIME_WSI_SURFACE_GATE" "$MANIFEST" \
  || fail "runtime manifest WSI surface gate is stale"
grep -Fqx "compositor_profile=$MESA_RUNTIME_COMPOSITOR_PROFILE" "$MANIFEST" \
  || fail "runtime manifest compositor profile is stale"
grep -Fqx "compositor_profile_source_commit=$WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT" \
  "$MANIFEST" || fail "runtime manifest compositor-profile commit is stale"
grep -Fqx "compositor_profile_source_tree=$WLROOTS_VULKAN_PROFILE_SOURCE_TREE" \
  "$MANIFEST" || fail "runtime manifest compositor-profile tree is stale"
grep -Fqx 'manifest_library_path=../../../lib/libvulkan_virtio.so' "$MANIFEST" \
  || fail "runtime manifest does not bind its relocatable ICD path"
grep -Fqx 'pack_layout=single-tree' "$MANIFEST" \
  || fail "runtime manifest does not bind its single-tree layout"
grep -Fqx 'libdrm_linkage=static-hidden' "$MANIFEST" \
  || fail "runtime manifest does not bind its isolated libdrm linkage"
grep -Fqx "builder_snapshot=$MESA_DEBIAN_SNAPSHOT" "$MANIFEST" \
  || fail "runtime manifest builder snapshot is stale"
grep -Fqx "mesa_source_commit=$MESA_SOURCE_COMMIT" "$MANIFEST" \
  || fail "runtime manifest source commit is stale"
grep -Fqx "mesa_source_tree=$MESA_SOURCE_TREE" "$MANIFEST" \
  || fail "runtime manifest source tree is stale"
grep -Fqx "mesa_source_date_epoch=$MESA_SOURCE_DATE_EPOCH" "$MANIFEST" \
  || fail "runtime manifest source epoch is stale"
file "$LIBRARY" | grep -Fq 'ELF 64-bit LSB shared object, ARM aarch64' \
  || fail "Venus ICD is not an ARM64 ELF shared library"
file "$PROBE" | grep -Fq 'ELF 64-bit LSB pie executable, ARM aarch64' \
  || fail "Vulkan probe is not an ARM64 ELF executable"
file "$COMPOSITOR_PROBE" | grep -Fq 'ELF 64-bit LSB pie executable, ARM aarch64' \
  || fail "Vulkan compositor probe is not an ARM64 ELF executable"
grep -aFq 'VK_KHR_swapchain' "$LIBRARY" \
  || fail "Venus ICD does not contain swapchain support"
if grep -aFq 'llvmpipe' "$LIBRARY"; then
  fail "isolated Venus ICD unexpectedly contains the software renderer"
fi
icd_dynamic="$($READELF --dynamic --wide "$LIBRARY")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$icd_dynamic"; then
  fail "Venus ICD carries an ambient dynamic-loader search path"
fi
icd_needed="$({
  sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$icd_dynamic"
} | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "icd_needed_sonames=$icd_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the ICD direct dependencies"
case ",$icd_needed," in
  *,libdrm.so.*|*,libdorydrm.so.*) fail "Venus ICD dynamically depends on libdrm" ;;
esac
if "$READELF" --dyn-syms --wide "$LIBRARY" \
    | awk '$5 == "GLOBAL" && $6 == "DEFAULT" && $8 ~ /^drm/ { found = 1 } END { exit !found }'; then
  fail "Venus ICD exports an interposable libdrm symbol"
fi
probe_dynamic="$($READELF --dynamic --wide "$PROBE")"
probe_needed="$({
  sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$probe_dynamic"
} | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "probe_needed_sonames=$probe_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the probe direct dependencies"
compositor_probe_dynamic="$($READELF --dynamic --wide "$COMPOSITOR_PROBE")"
compositor_probe_needed="$({
  sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$compositor_probe_dynamic"
} | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "compositor_probe_needed_sonames=$compositor_probe_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the compositor-probe dependencies"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$compositor_probe_dynamic"; then
  fail "Vulkan compositor probe carries an ambient dynamic-loader search path"
fi
case ",$compositor_probe_needed," in
  *,libdrm.so.*|*,libdorydrm.so.*) fail "Vulkan compositor probe dynamically depends on libdrm" ;;
esac
"$READELF" --program-headers --wide "$PROBE" \
  | grep -Fq 'Requesting program interpreter: /lib/ld-linux-aarch64.so.1' \
  || fail "Vulkan probe requests an unexpected runtime loader"
"$READELF" --program-headers --wide "$COMPOSITOR_PROBE" \
  | grep -Fq 'Requesting program interpreter: /lib/ld-linux-aarch64.so.1' \
  || fail "Vulkan compositor probe requests an unexpected runtime loader"
runtime_dyn_symbols="$({
  "$READELF" --dyn-syms --wide "$LIBRARY"
  "$READELF" --dyn-syms --wide "$PROBE"
  "$READELF" --dyn-syms --wide "$COMPOSITOR_PROBE"
})"
if grep -Fq 'GLIBC_PRIVATE' <<<"$runtime_dyn_symbols"; then
  fail "runtime references the non-public GLIBC_PRIVATE ABI"
fi
glibc_symbols="$(sed -n 's/.*@\(GLIBC_[0-9][0-9.]*\).*/\1/p' <<<"$runtime_dyn_symbols")"
actual_max_glibc="$(LC_ALL=C sort -Vu <<<"$glibc_symbols" | tail -n 1)"
grep -Eq '^GLIBC_[0-9]+(\.[0-9]+)+$' <<<"$actual_max_glibc" \
  || fail "runtime ELF does not declare a valid public GNU-libc symbol floor"
manifest_max_glibc="$(sed -n 's/^max_glibc_symbol=//p' "$MANIFEST")"
[ "$manifest_max_glibc" = "$actual_max_glibc" ] \
  || fail "runtime manifest GNU-libc floor does not match its ELF closure"
[ "$(printf '%s\n%s\n' "$actual_max_glibc" "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" \
    | LC_ALL=C sort -Vu | tail -n 1)" = "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" ] \
  || fail "runtime ELF GNU-libc floor $actual_max_glibc exceeds $MESA_RUNTIME_MAX_GLIBC_SYMBOL"
build_packages_sha256="$(shasum -a 256 "$BUILD_PACKAGES" | awk '{print $1}')"
grep -Fqx "build_packages_sha256=$build_packages_sha256" "$MANIFEST" \
  || fail "runtime package provenance digest is invalid"

echo "verified Dory Mesa $MESA_VERSION Venus runtime"
