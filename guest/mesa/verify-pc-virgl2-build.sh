#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS

case "${1:-x86_64}" in
  amd64|x86_64) ;;
  *) echo "the Dory PC VirGL2 runtime supports x86_64 only" >&2; exit 64 ;;
esac

OUT="${DORY_MESA_OUT_DIR:-$ROOT/guest/out}"
RUNTIME="$OUT/dory-mesa-virgl2-x86_64.tar.zst"
STAMP="$OUT/dory-mesa-virgl2-build-x86_64.stamp"
fail() {
  echo "Dory PC VirGL2 runtime verification failed: $*" >&2
  exit 1
}

[ -s "$RUNTIME" ] || fail "missing $RUNTIME"
[ -s "$STAMP" ] || fail "missing $STAMP"
stamp_value() { sed -n "s/^$1=//p" "$STAMP"; }
[ "$(stamp_value schema)" = 2 ] || fail "unsupported stamp schema"
[ "$(stamp_value arch)" = x86_64 ] || fail "runtime was built for another architecture"
[ "$(stamp_value profile)" = pc-virgl2 ] || fail "runtime was built for another profile"
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
[ "$(stamp_value input_sha256)" = "$(guest/mesa/input-pc-virgl2-fingerprint.sh x86_64)" ] \
  || fail "runtime inputs are stale"
[ "$(stamp_value runtime_sha256)" = "$(shasum -a 256 "$RUNTIME" | awk '{print $1}')" ] \
  || fail "runtime digest does not match its stamp"

ZSTD="${DORY_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
[ -n "$ZSTD" ] || fail "zstd is required"
READELF="${DORY_X86_64_READELF:-$(command -v x86_64-elf-readelf 2>/dev/null || command -v llvm-readelf 2>/dev/null || command -v aarch64-elf-readelf 2>/dev/null || command -v readelf 2>/dev/null || true)}"
OBJDUMP="${DORY_X86_64_OBJDUMP:-$(command -v llvm-objdump 2>/dev/null || xcrun --find llvm-objdump 2>/dev/null || true)}"
if [ -n "$READELF" ]; then
  elf_dynamic() { "$READELF" --dynamic --wide "$1"; }
  elf_dynsyms() { "$READELF" --dyn-syms --wide "$1"; }
elif [ -n "$OBJDUMP" ]; then
  elf_dynamic() { "$OBJDUMP" --private-headers "$1"; }
  elf_dynsyms() { "$OBJDUMP" --dynamic-syms "$1"; }
else
  fail "x86_64 readelf or llvm-objdump is required for exact ELF verification"
fi
"$ZSTD" -q -t "$RUNTIME" || fail "runtime archive is corrupt"

EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/dory-mesa-pc-virgl2-verify.XXXXXX")"
trap 'rm -rf "$EXTRACT"' EXIT
"$ZSTD" -q -d -c "$RUNTIME" | tar -xf - -C "$EXTRACT"
DRIVER="$EXTRACT/opt/dory/mesa/lib/dri/virtio_gpu_dri.so"
GL_LOADER="$EXTRACT/opt/dory/mesa/lib/libGL.so.1"
GALLIUM="$EXTRACT/opt/dory/mesa/lib/libgallium-$MESA_VERSION.so"
MANIFEST="$EXTRACT/opt/dory/mesa/share/dory/runtime.env"
BUILD_PACKAGES="$EXTRACT/opt/dory/mesa/share/dory/build-packages.txt"
for path in "$DRIVER" "$GL_LOADER" "$GALLIUM" "$MANIFEST" "$BUILD_PACKAGES"; do
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
actual_files="$(find "$EXTRACT/opt/dory/mesa" -type f -print \
  | sed "s#^$EXTRACT/opt/dory/mesa/##" | LC_ALL=C sort)"
expected_files='lib/dri/virtio_gpu_dri.so
lib/libGL.so
lib/libGL.so.1
lib/libGL.so.1.2.0
lib/libgallium-26.0.0-devel.so
share/dory/build-packages.txt
share/dory/runtime.env'
[ "$actual_files" = "$expected_files" ] || fail "runtime pack file allowlist differs"

cmp -s "$EXTRACT/opt/dory/mesa/lib/libGL.so.1.2.0" "$GL_LOADER" \
  || fail "runtime GL loader aliases are not byte-identical"
cmp -s "$EXTRACT/opt/dory/mesa/lib/libGL.so" "$GL_LOADER" \
  || fail "runtime GL loader development alias is not byte-identical"
cmp -s "$GALLIUM" "$DRIVER" \
  || fail "runtime DRI driver is not byte-identical to the packaged Gallium SONAME library"

grep -Fqx 'schema=2' "$MANIFEST" || fail "runtime manifest schema is stale"
grep -Fqx 'profile=pc-virgl2' "$MANIFEST" || fail "runtime manifest profile is stale"
grep -Fqx 'architecture=x86_64' "$MANIFEST" || fail "runtime manifest architecture is stale"
grep -Fqx "libc_family=$MESA_RUNTIME_LIBC_FAMILY" "$MANIFEST" \
  || fail "runtime manifest libc family is stale"
grep -Fqx "mesa_version=$MESA_VERSION" "$MANIFEST" || fail "runtime manifest Mesa version is stale"
grep -Fqx "mesa_source_commit=$MESA_SOURCE_COMMIT" "$MANIFEST" \
  || fail "runtime manifest source commit is stale"
grep -Fqx "mesa_source_tree=$MESA_SOURCE_TREE" "$MANIFEST" \
  || fail "runtime manifest source tree is stale"
grep -Fqx "mesa_source_date_epoch=$MESA_SOURCE_DATE_EPOCH" "$MANIFEST" \
  || fail "runtime manifest source epoch is stale"
grep -Fqx "builder_snapshot=$MESA_DEBIAN_SNAPSHOT" "$MANIFEST" \
  || fail "runtime manifest builder snapshot is stale"
grep -Fqx 'gallium_driver=virgl' "$MANIFEST" \
  || fail "runtime manifest does not bind the VirGL Gallium driver"
grep -Fqx 'dri_driver=virtio_gpu_dri.so' "$MANIFEST" \
  || fail "runtime manifest does not bind the exact DRI driver"
grep -Fqx 'gl_loader=libGL.so.1' "$MANIFEST" \
  || fail "runtime manifest does not bind the matching GL loader"
grep -Fqx "gallium_library=libgallium-$MESA_VERSION.so" "$MANIFEST" \
  || fail "runtime manifest does not bind the matching Gallium SONAME library"
grep -Fqx 'required_guest_ld_library_path=/opt/dory/mesa/lib' "$MANIFEST" \
  || fail "runtime manifest does not declare the required GL loader path"
grep -Fqx 'required_guest_libgl_drivers_path=/opt/dory/mesa/lib/dri' "$MANIFEST" \
  || fail "runtime manifest does not declare the required DRI search path"

for runtime_elf in "$DRIVER" "$GL_LOADER" "$GALLIUM"; do
  file "$runtime_elf" | grep -Eq 'ELF 64-bit.*x86-64|ELF 64-bit.*x86_64' \
    || fail "${runtime_elf#$EXTRACT} is not an x86_64 ELF shared object"
done
grep -aFq 'virgl' "$DRIVER" || fail "DRI driver does not contain the VirGL driver identity"
grep -aFq 'virtio_gpu_driver_descriptor' "$DRIVER" \
  || fail "DRI driver does not bind the virtio-gpu DRM descriptor"
grep -aFq 'pipe_virtio_gpu_create_screen' "$DRIVER" \
  || fail "DRI driver does not bind the virtio-gpu VirGL screen factory"
if grep -aFq 'llvmpipe' "$DRIVER"; then
  fail "PC VirGL2 runtime unexpectedly contains llvmpipe"
fi
driver_dynamic="$(elf_dynamic "$DRIVER")"
gl_loader_dynamic="$(elf_dynamic "$GL_LOADER")"
gallium_dynamic="$(elf_dynamic "$GALLIUM")"
# readelf prints dynamic tags as `(RUNPATH)`, while llvm-objdump prints bare `RUNPATH`/`RPATH`
# table labels. Check both spellings so the fallback verifier does not miss ambient search paths.
for dynamic_section in "$driver_dynamic" "$gl_loader_dynamic" "$gallium_dynamic"; do
  if grep -Eq '\((RPATH|RUNPATH)\)|^[[:space:]]*(RPATH|RUNPATH)[[:space:]]' <<<"$dynamic_section"; then
    fail "PC VirGL2 runtime carries an ambient dynamic-loader search path"
  fi
done
driver_needed="$(sed -n -e 's/.*Shared library: \[\([^]]*\)\].*/\1/p' \
  -e 's/^[[:space:]]*NEEDED[[:space:]]*//p' <<<"$driver_dynamic" \
  | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "driver_needed_sonames=$driver_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the driver direct dependencies"
gl_loader_needed="$(sed -n -e 's/.*Shared library: \[\([^]]*\)\].*/\1/p' \
  -e 's/^[[:space:]]*NEEDED[[:space:]]*//p' <<<"$gl_loader_dynamic" \
  | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "gl_loader_needed_sonames=$gl_loader_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the GL loader direct dependencies"
gallium_needed="$(sed -n -e 's/.*Shared library: \[\([^]]*\)\].*/\1/p' \
  -e 's/^[[:space:]]*NEEDED[[:space:]]*//p' <<<"$gallium_dynamic" \
  | LC_ALL=C sort | paste -sd, -)"
grep -Fqx "gallium_needed_sonames=$gallium_needed" "$MANIFEST" \
  || fail "runtime manifest does not exactly bind the Gallium direct dependencies"
runtime_dyn_symbols="$(
  for runtime_elf in "$DRIVER" "$GL_LOADER" "$GALLIUM"; do
    elf_dynsyms "$runtime_elf"
  done
)"
if grep -Fq 'GLIBC_PRIVATE' <<<"$runtime_dyn_symbols"; then
  fail "runtime references the non-public GLIBC_PRIVATE ABI"
fi
glibc_symbols="$(sed -n \
  -e 's/.*@\(GLIBC_[0-9][0-9.]*\).*/\1/p' \
  -e 's/.*@@\(GLIBC_[0-9][0-9.]*\).*/\1/p' \
  -e 's/.*\[\(GLIBC_[0-9][0-9.]*\)\].*/\1/p' \
  -e 's/.*(\(GLIBC_[0-9][0-9.]*\)).*/\1/p' \
  <<<"$runtime_dyn_symbols")"
actual_max_glibc="$(LC_ALL=C sort -Vu <<<"$glibc_symbols" | tail -n 1)"
grep -Eq '^GLIBC_[0-9]+(\.[0-9]+)+$' <<<"$actual_max_glibc" \
  || fail "runtime ELF does not declare a valid public GNU-libc symbol floor"
grep -Fqx "max_glibc_symbol=$actual_max_glibc" "$MANIFEST" \
  || fail "runtime manifest GNU-libc floor does not match its ELF closure"
[ "$(printf '%s\n%s\n' "$actual_max_glibc" "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" \
    | LC_ALL=C sort -Vu | tail -n 1)" = "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" ] \
  || fail "runtime ELF GNU-libc floor $actual_max_glibc exceeds $MESA_RUNTIME_MAX_GLIBC_SYMBOL"
build_packages_sha256="$(shasum -a 256 "$BUILD_PACKAGES" | awk '{print $1}')"
grep -Fqx "build_packages_sha256=$build_packages_sha256" "$MANIFEST" \
  || fail "runtime package provenance digest is invalid"

echo "verified Dory Mesa $MESA_VERSION PC VirGL2 runtime"
