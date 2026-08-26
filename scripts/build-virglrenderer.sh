#!/bin/bash
# Build Dory's exact static VirGL2 + Venus renderer with its XPC-local ANGLE Metal pair.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFINITION="$ROOT/Config/DoryRendererProductionTuple.json"
VERIFIER="$ROOT/scripts/renderer-production-tuple.py"
OUTPUT_ROOT=""
INVENTORY=""
DEPENDENCY_PREFIX="${DORY_RENDERER_DEPENDENCY_PREFIX:-}"
DEPENDENCY_INVENTORY="${DORY_RENDERER_DEPENDENCY_INVENTORY:-}"
SOURCE_SEED="${DORY_VIRGLRENDERER_SOURCE_CHECKOUT:-}"
VULKAN_HEADERS_SEED="${DORY_VULKAN_HEADERS_SOURCE_CHECKOUT:-}"
JOBS=3

usage() {
  echo "usage: $0 --output-root PATH --inventory PATH --dependency-prefix PATH --dependency-inventory PATH [--source-seed PATH] [--vulkan-headers-seed PATH] [--jobs COUNT]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-root) OUTPUT_ROOT="${2:?missing output root}"; shift 2 ;;
    --inventory) INVENTORY="${2:?missing inventory path}"; shift 2 ;;
    --dependency-prefix) DEPENDENCY_PREFIX="${2:?missing dependency prefix}"; shift 2 ;;
    --dependency-inventory) DEPENDENCY_INVENTORY="${2:?missing dependency inventory}"; shift 2 ;;
    --source-seed) SOURCE_SEED="${2:?missing source seed}"; shift 2 ;;
    --vulkan-headers-seed) VULKAN_HEADERS_SEED="${2:?missing Vulkan-Headers seed}"; shift 2 ;;
    --jobs) JOBS="${2:?missing job count}"; shift 2 ;;
    --skip-tests)
      echo "build-virglrenderer: structural production gates cannot be skipped" >&2
      exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build-virglrenderer: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$OUTPUT_ROOT" ] && [ -n "$INVENTORY" ] \
  && [ -n "$DEPENDENCY_PREFIX" ] && [ -n "$DEPENDENCY_INVENTORY" ] \
  || { usage; exit 2; }
case "$OUTPUT_ROOT" in
  /|"$HOME"|"$ROOT") echo "build-virglrenderer: refusing broad output path $OUTPUT_ROOT" >&2; exit 2 ;;
esac
[ "$(dirname "$INVENTORY")" = "$OUTPUT_ROOT" ] || {
  echo "build-virglrenderer: inventory must be a direct child of the output root" >&2
  exit 2
}
case "$JOBS" in
  ''|*[!0-9]*) echo "build-virglrenderer: jobs must be an integer" >&2; exit 2 ;;
esac
[ "$JOBS" -gt 0 ] || { echo "build-virglrenderer: jobs must be positive" >&2; exit 2; }
[ "$JOBS" -le 3 ] || {
  echo "build-virglrenderer: jobs must not exceed the live-host ceiling of 3" >&2
  exit 2
}

for command in ar git install lipo meson ninja nm otool pkg-config python3 ranlib xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "build-virglrenderer: missing $command" >&2
    exit 1
  }
done
[ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ] || {
  echo "build-virglrenderer: set DEVELOPER_DIR to the reviewed full Xcode" >&2
  exit 1
}
python3 "$VERIFIER" --definition "$DEFINITION" verify-definition --repo-root "$ROOT"
python3 "$VERIFIER" --definition "$DEFINITION" verify-toolchain
python3 "$VERIFIER" --definition "$DEFINITION" verify-inventory \
  --profile staticDependencies \
  --root "$DEPENDENCY_PREFIX" \
  --inventory "$DEPENDENCY_INVENTORY"

if [ -e "$OUTPUT_ROOT" ]; then
  [ -d "$OUTPUT_ROOT" ] || {
    echo "build-virglrenderer: output root is not a directory: $OUTPUT_ROOT" >&2
    exit 1
  }
  [ -z "$(find "$OUTPUT_ROOT" -mindepth 1 -print -quit)" ] || {
    echo "build-virglrenderer: output root must be absent or empty: $OUTPUT_ROOT" >&2
    exit 1
  }
fi

source_value() {
  local source_name="$1" field="$2"
  python3 - "$DEFINITION" "$source_name" "$field" <<'PY'
import json
import pathlib
import sys

definition = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value = definition["sources"][sys.argv[2]][sys.argv[3]]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

dependency_value() {
  local owner="$1" dependency="$2" field="$3"
  python3 - "$DEFINITION" "$owner" "$dependency" "$field" <<'PY'
import json
import pathlib
import sys

definition = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value = definition["dependencySources"][sys.argv[2]][sys.argv[3]][sys.argv[4]]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dory-virglrenderer-static.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SOURCE_CHECKOUT="$WORK/virglrenderer"
if [ -n "$SOURCE_SEED" ]; then
  python3 "$VERIFIER" --definition "$DEFINITION" verify-checkout \
    --source virglrenderer --checkout "$SOURCE_SEED"
  mkdir "$SOURCE_CHECKOUT"
  git -C "$SOURCE_CHECKOUT" init --quiet
  git -C "$SOURCE_CHECKOUT" remote add origin "$(source_value virglrenderer repository)"
  git -C "$SOURCE_CHECKOUT" fetch --quiet --depth=1 \
    "$SOURCE_SEED" "$(source_value virglrenderer revision)"
  git -C "$SOURCE_CHECKOUT" checkout --quiet --detach FETCH_HEAD
else
  git clone --filter=tree:0 --no-checkout \
    "$(source_value virglrenderer repository)" "$SOURCE_CHECKOUT"
  git -C "$SOURCE_CHECKOUT" fetch --depth=1 origin "$(source_value virglrenderer revision)"
  git -C "$SOURCE_CHECKOUT" checkout --detach "$(source_value virglrenderer revision)"
fi
python3 "$VERIFIER" --definition "$DEFINITION" verify-virgl-build-checkout \
  --checkout "$SOURCE_CHECKOUT" --state source
while IFS= read -r virgl_patch_relative; do
  [ -n "$virgl_patch_relative" ] || continue
  git -C "$SOURCE_CHECKOUT" apply --check --whitespace=error-all \
    "$ROOT/$virgl_patch_relative"
  git -C "$SOURCE_CHECKOUT" apply --whitespace=error-all \
    "$ROOT/$virgl_patch_relative"
done < <(
  python3 "$VERIFIER" --definition "$DEFINITION" \
    virgl-build-patch-paths --repo-root "$ROOT"
)
python3 "$VERIFIER" --definition "$DEFINITION" verify-virgl-build-checkout \
  --checkout "$SOURCE_CHECKOUT" --state applied

VULKAN_HEADERS="$WORK/Vulkan-Headers"
if [ -n "$VULKAN_HEADERS_SEED" ]; then
  python3 "$VERIFIER" --definition "$DEFINITION" verify-dependency-checkout \
    --owner moltenVK --dependency vulkanHeaders --checkout "$VULKAN_HEADERS_SEED"
  mkdir "$VULKAN_HEADERS"
  git -C "$VULKAN_HEADERS" init --quiet
  git -C "$VULKAN_HEADERS" remote add origin \
    "$(dependency_value moltenVK vulkanHeaders repository)"
  git -C "$VULKAN_HEADERS" fetch --quiet --depth=1 \
    "$VULKAN_HEADERS_SEED" "$(dependency_value moltenVK vulkanHeaders revision)"
  git -C "$VULKAN_HEADERS" checkout --quiet --detach FETCH_HEAD
else
  git clone --filter=tree:0 --no-checkout \
    "$(dependency_value moltenVK vulkanHeaders repository)" "$VULKAN_HEADERS"
  git -C "$VULKAN_HEADERS" fetch --depth=1 origin \
    "$(dependency_value moltenVK vulkanHeaders revision)"
  git -C "$VULKAN_HEADERS" checkout --detach \
    "$(dependency_value moltenVK vulkanHeaders revision)"
fi
python3 "$VERIFIER" --definition "$DEFINITION" verify-dependency-checkout \
  --owner moltenVK --dependency vulkanHeaders --checkout "$VULKAN_HEADERS"

BUILD="$WORK/build"
PKGCONFIG_ROOT="$WORK/pkgconfig"
mkdir -p "$PKGCONFIG_ROOT"
python3 - "$PKGCONFIG_ROOT/epoxy.pc" "$DEPENDENCY_PREFIX" <<'PY'
import pathlib
import sys

destination = pathlib.Path(sys.argv[1])
prefix = pathlib.Path(sys.argv[2]).resolve(strict=True)
archive = prefix / "lib/libepoxy.a"
if not archive.is_file() or archive.is_symlink():
    raise SystemExit("static libepoxy pkg-config: archive is unavailable")
destination.write_text(
    "\n".join(
        (
            f"prefix={prefix}",
            "libdir=${prefix}/lib",
            "includedir=${prefix}/include",
            "",
            "Name: epoxy",
            "Description: Dory pinned static ANGLE resolver",
            "Version: 1.5.11",
            "Libs: ${libdir}/libepoxy.a",
            "Cflags: -I${includedir} -I${includedir}/ANGLE",
            "epoxy_has_egl=1",
            "epoxy_has_glx=0",
            "",
        )
    ),
    encoding="utf-8",
)
PY
python3 - "$PKGCONFIG_ROOT/vulkan.pc" "$DEPENDENCY_PREFIX" "$VULKAN_HEADERS/include" <<'PY'
import pathlib
import sys

destination = pathlib.Path(sys.argv[1])
prefix = pathlib.Path(sys.argv[2]).resolve(strict=True)
include = pathlib.Path(sys.argv[3]).resolve(strict=True)
archive = prefix / "lib/libMoltenVK.a"
if not archive.is_file() or archive.is_symlink():
    raise SystemExit("static Vulkan pkg-config: MoltenVK archive is unavailable")
destination.write_text(
    "\n".join(
        (
            f"prefix={prefix}",
            "libdir=${prefix}/lib",
            f"includedir={include}",
            "",
            "Name: Vulkan",
            "Description: Dory pinned static MoltenVK entrypoint",
            "Version: 1.4.0",
            "Libs: ${libdir}/libMoltenVK.a",
            "Cflags: -I${includedir}",
            "",
        )
    ),
    encoding="utf-8",
)
PY

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
CLANGXX="$(xcrun --sdk macosx --find clang++)"
HOST_COMPILE_FLAGS=(
  -arch arm64
  -isysroot "$SDKROOT"
  -mmacosx-version-min=15.0
)
export CC="$CLANG"
export CXX="$CLANGXX"
export CFLAGS="${HOST_COMPILE_FLAGS[*]}"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="$CFLAGS"
export PKG_CONFIG_PATH="$PKGCONFIG_ROOT"

meson setup "$BUILD" "$SOURCE_CHECKOUT" \
  --buildtype release \
  --default-library static \
  -Dcheck-gl-errors=false \
  -Ddrm-renderers=[] \
  -Dfuzzer=false \
  -Dminigbm_allocation=false \
  -Dneptune=false \
  -Dplatforms=egl \
  -Drender-server-mode=thread \
  -Drender-server-worker=thread \
  -Dtests=false \
  -Dunstable-apis=true \
  -Dvenus=true \
  -Dvenus-only=false \
  -Dvideo=false \
  -Dvtest=false \
  -Dvulkan-dload=false \
  -Dvulkan-preload=false

# vrend_metal.m includes Gallium's generated u_format_gen.h through p_state.h.  The physical
# allocator probe deliberately compiles that production source directly, before the full archive
# build, so materialize its declared Meson generator first instead of relying on a stale header
# from another build directory.
meson compile -C "$BUILD" -j "$JOBS" u_format_gen.h

# Prove the exact patched native VirGL2 allocator on the build host. The probe renders into the
# original private shareable scanout, exports/imports its MTLSharedTextureHandle, then GPU-blits the
# imported texture to mapped readback. An ordinary process-local texture or a copy-based bridge
# fails this gate before the renderer archive can be published.
METAL_SHARED_TEXTURE_PROBE="$WORK/renderer-virgl-metal-shared-texture-probe"
"$CLANG" "${HOST_COMPILE_FLAGS[@]}" \
  -fblocks \
  -fno-objc-arc \
  -imacros "$BUILD/config.h" \
  -DHAVE_CONFIG_H=1 \
  -Werror \
  -Wall \
  -Wextra \
  -I"$BUILD" \
  -I"$BUILD/src" \
  -I"$BUILD/src/mesa" \
  -I"$BUILD/src/gallium" \
  -I"$SOURCE_CHECKOUT/src" \
  -I"$SOURCE_CHECKOUT/src/gallium/include" \
  -I"$SOURCE_CHECKOUT/src/gallium/auxiliary" \
  -I"$SOURCE_CHECKOUT/src/gallium/auxiliary/util" \
  -I"$SOURCE_CHECKOUT/src/mesa" \
  -I"$SOURCE_CHECKOUT/src/mesa/compat" \
  -I"$SOURCE_CHECKOUT/src/mesa/pipe" \
  -I"$SOURCE_CHECKOUT/src/mesa/util" \
  -I"$SOURCE_CHECKOUT/src/drm/drm-uapi" \
  "$SOURCE_CHECKOUT/src/vrend/vrend_metal.m" \
  "$ROOT/scripts/renderer-virgl-metal-shared-texture-probe.m" \
  -framework Foundation \
  -framework Metal \
  -o "$METAL_SHARED_TEXTURE_PROBE"
"$METAL_SHARED_TEXTURE_PROBE"

# Compile every imported aggregate and direct API signature against this exact generated/upstream
# header set, then compile the actual production shim with static authority enabled. Together these
# gates make source drift a publication failure before either archive reaches the link stage.
"$CLANG" "${HOST_COMPILE_FLAGS[@]}" \
  -std=c11 -Werror -DVIRGL_RENDERER_UNSTABLE_APIS -fsyntax-only \
  -I"$BUILD/src" \
  -I"$SOURCE_CHECKOUT/src" \
  -I"$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/include" \
  "$ROOT/scripts/verify-virgl-resource-info-abi.c"
"$CLANG" "${HOST_COMPILE_FLAGS[@]}" \
  -std=c11 -Werror \
  -DDORY_VIRGL_RENDERER_STATIC_LINKED \
  -DDORY_VIRGL_RENDERER_DUAL_METAL \
  -fsyntax-only \
  -I"$BUILD/src" \
  -I"$SOURCE_CHECKOUT/src" \
  -I"$DEPENDENCY_PREFIX/include" \
  -I"$DEPENDENCY_PREFIX/include/ANGLE" \
  -I"$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/include" \
  "$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/DoryVirglRendererSession.c"

meson compile -C "$BUILD" -j "$JOBS"
meson test -C "$BUILD" --no-rebuild --print-errorlogs
python3 "$VERIFIER" --definition "$DEFINITION" verify-meson --build-dir "$BUILD"

BUILT="$BUILD/src/libvirglrenderer.a"
[ -f "$BUILT" ] && [ ! -L "$BUILT" ] || {
  echo "build-virglrenderer: maintained static build did not produce $BUILT" >&2
  exit 1
}
ranlib "$BUILT"
[ "$(lipo -archs "$BUILT")" = arm64 ] || {
  echo "build-virglrenderer: static renderer is not exactly arm64" >&2
  exit 1
}

REQUIRED_VIRGL_SYMBOLS=(
  virgl_renderer_cleanup
  virgl_renderer_context_create_fence
  virgl_renderer_context_create_with_flags
  virgl_renderer_context_destroy
  virgl_renderer_ctx_attach_resource
  virgl_renderer_ctx_detach_resource
  virgl_renderer_fill_caps
  virgl_renderer_get_cap_set
  virgl_renderer_init
  virgl_renderer_poll
  virgl_renderer_resource_attach_iov
  virgl_renderer_resource_create_blob
  virgl_renderer_resource_detach_iov
  virgl_renderer_resource_export_blob
  virgl_renderer_resource_get_info
  virgl_renderer_resource_get_map_info
  virgl_renderer_resource_unref
  virgl_renderer_submit_cmd2
  virgl_renderer_transfer_read_iov
  virgl_renderer_transfer_write_iov
)
VIRGL_SYMBOLS="$WORK/virglrenderer-symbols.txt"
nm -gU "$BUILT" >"$VIRGL_SYMBOLS"
for symbol in "${REQUIRED_VIRGL_SYMBOLS[@]}"; do
  grep "_$symbol$" "$VIRGL_SYMBOLS" >/dev/null || {
    echo "build-virglrenderer: static renderer is missing $symbol" >&2
    exit 1
  }
done

ARCHIVE_MEMBERS="$WORK/virglrenderer-members.txt"
ar -t "$BUILT" >"$ARCHIVE_MEMBERS"
REQUIRED_ARCHIVE_MEMBERS=(
  vrend_vrend_renderer.c.o
  vrend_vrend_winsys.c.o
  vrend_vrend_winsys_egl.c.o
  venus_vkr_renderer.c.o
  proxy_proxy_renderer.c.o
  proxy_proxy_server.c.o
  .._server_render_server.c.o
  .._server_render_worker.c.o
)
for member in "${REQUIRED_ARCHIVE_MEMBERS[@]}"; do
  grep -Fx "$member" "$ARCHIVE_MEMBERS" >/dev/null || {
    echo "build-virglrenderer: static archive is missing required Venus thread member $member" >&2
    exit 1
  }
done
if grep -E '(^|/)(vtest_|drm_|neptune_)[^/]*$' "$ARCHIVE_MEMBERS" >/dev/null; then
  echo "build-virglrenderer: static archive contains a forbidden vtest/DRM/Neptune object" >&2
  exit 1
fi
ALL_VIRGL_SYMBOLS="$WORK/virglrenderer-all-symbols.txt"
nm "$BUILT" >"$ALL_VIRGL_SYMBOLS"
for classic_symbol in vrend_renderer_init vrend_renderer_context_create; do
  awk '{ print $NF }' "$ALL_VIRGL_SYMBOLS" | grep -Fx "_$classic_symbol" >/dev/null || {
    echo "build-virglrenderer: static archive is missing classic renderer symbol $classic_symbol" >&2
    exit 1
  }
done
if awk '{ print $NF }' "$ALL_VIRGL_SYMBOLS" \
    | grep -E '^_(CGL|vtest)[A-Za-z0-9_]*$' \
    >"$WORK/forbidden-virgl-symbols.txt"; then
  echo "build-virglrenderer: static archive contains forbidden CGL/vtest symbols" >&2
  cat "$WORK/forbidden-virgl-symbols.txt" >&2
  exit 1
fi

SHIM_OBJECT="$WORK/DoryVirglRendererSession.o"
PROBE_OBJECT="$WORK/verify-virgl-static-link.o"
LINK_PROBE="$WORK/dory-virgl-static-link-probe"
"$CLANG" "${HOST_COMPILE_FLAGS[@]}" \
  -std=c11 -O2 -Werror \
  -DDORY_VIRGL_RENDERER_STATIC_LINKED \
  -DDORY_VIRGL_RENDERER_DUAL_METAL \
  -c \
  -I"$DEPENDENCY_PREFIX/include" \
  -I"$DEPENDENCY_PREFIX/include/ANGLE" \
  -I"$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/include" \
  "$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/DoryVirglRendererSession.c" \
  -o "$SHIM_OBJECT"
"$CLANG" "${HOST_COMPILE_FLAGS[@]}" -std=c11 -O2 -Werror -c \
  -I"$ROOT/Packages/ContainerizationEngine/Sources/DoryVirglRendererShim/include" \
  "$ROOT/scripts/verify-virgl-static-link.c" \
  -o "$PROBE_OBJECT"
"$CLANGXX" "${HOST_COMPILE_FLAGS[@]}" \
  "$SHIM_OBJECT" \
  "$PROBE_OBJECT" \
  -Wl,-force_load,"$BUILT" \
  -Wl,-force_load,"$DEPENDENCY_PREFIX/lib/libepoxy.a" \
  -Wl,-force_load,"$DEPENDENCY_PREFIX/lib/libMoltenVK.a" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Foundation \
  -framework IOKit \
  -framework IOSurface \
  -framework Metal \
  -framework QuartzCore \
  -o "$LINK_PROBE"

if otool -l "$LINK_PROBE" | grep -q 'cmd LC_RPATH'; then
  echo "build-virglrenderer: static link probe contains forbidden LC_RPATH authority" >&2
  exit 1
fi
while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *) echo "build-virglrenderer: static link probe has non-system dependency $dependency" >&2; exit 1 ;;
  esac
done < <(otool -L "$LINK_PROBE" | awk 'NR > 1 { print $1 }')
if nm -u "$LINK_PROBE" | awk '{ print $NF }' \
    | grep -E '^_(virgl_renderer_[A-Za-z0-9_]*|vkGetInstanceProcAddr|CGL[A-Za-z0-9_]*|egl[A-Za-z0-9_]*|epoxy[A-Za-z0-9_]*|gl[A-Z][A-Za-z0-9_]*|vrend[A-Za-z0-9_]*|vtest[A-Za-z0-9_]*)$' \
    >"$WORK/forbidden-link-undefined.txt"; then
  echo "build-virglrenderer: static link probe retains forbidden renderer/GL/loader undefined symbols" >&2
  cat "$WORK/forbidden-link-undefined.txt" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT/Frameworks" "$OUTPUT_ROOT/include/ANGLE" \
  "$OUTPUT_ROOT/include/epoxy" "$OUTPUT_ROOT/lib"
install -m0644 "$BUILT" "$OUTPUT_ROOT/lib/libvirglrenderer.a"
install -m0644 "$DEPENDENCY_PREFIX/lib/libepoxy.a" "$OUTPUT_ROOT/lib/libepoxy.a"
install -m0644 "$DEPENDENCY_PREFIX/lib/libMoltenVK.a" "$OUTPUT_ROOT/lib/libMoltenVK.a"
install -m0755 "$DEPENDENCY_PREFIX/Frameworks/libEGL.dylib" \
  "$OUTPUT_ROOT/Frameworks/libEGL.dylib"
install -m0755 "$DEPENDENCY_PREFIX/Frameworks/libGLESv2.dylib" \
  "$OUTPUT_ROOT/Frameworks/libGLESv2.dylib"
for angle_header in EGL/egl.h EGL/eglext.h EGL/eglplatform.h KHR/khrplatform.h; do
  mkdir -p "$OUTPUT_ROOT/include/ANGLE/$(dirname "$angle_header")"
  install -m0644 "$DEPENDENCY_PREFIX/include/ANGLE/$angle_header" \
    "$OUTPUT_ROOT/include/ANGLE/$angle_header"
done
for epoxy_header in common.h egl.h egl_angle_ext_generated.h egl_generated.h gl.h gl_generated.h; do
  install -m0644 "$DEPENDENCY_PREFIX/include/epoxy/$epoxy_header" \
    "$OUTPUT_ROOT/include/epoxy/$epoxy_header"
done
ranlib "$OUTPUT_ROOT/lib/libvirglrenderer.a"
ranlib "$OUTPUT_ROOT/lib/libepoxy.a"
ranlib "$OUTPUT_ROOT/lib/libMoltenVK.a"
python3 - "$OUTPUT_ROOT" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
archive_paths = ["lib/libvirglrenderer.a", "lib/libepoxy.a", "lib/libMoltenVK.a"]
archives = [
    {
        "path": relative,
        "sha256": hashlib.sha256((root / relative).read_bytes()).hexdigest(),
    }
    for relative in archive_paths
]
runtime_paths = ["Frameworks/libEGL.dylib", "Frameworks/libGLESv2.dylib"]
runtime_libraries = [
    {
        "installName": f"@loader_path/{pathlib.PurePosixPath(relative).name}",
        "path": relative,
        "sha256": hashlib.sha256((root / relative).read_bytes()).hexdigest(),
    }
    for relative in runtime_paths
]
contract = {
    "appleFrameworks": [
        "AppKit",
        "CoreGraphics",
        "Foundation",
        "IOKit",
        "IOSurface",
        "Metal",
        "QuartzCore",
    ],
    "architecture": "arm64",
    "archives": archives,
    "cxxRuntime": "c++",
    "forceLoadArchives": archive_paths,
    "kind": "dev.dory.renderer-static-link-contract",
    "requiredCompileDefinitions": [
        "DORY_VIRGL_RENDERER_DUAL_METAL",
        "DORY_VIRGL_RENDERER_STATIC_LINKED",
    ],
    "requiredVirGLCapsets": [2, 4],
    "runtimeLibraries": runtime_libraries,
    "schemaVersion": 2,
}
(root / "renderer-static-link.json").write_text(
    json.dumps(contract, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

python3 "$VERIFIER" --definition "$DEFINITION" create-inventory \
  --profile staticLinkClosure --root "$OUTPUT_ROOT" --output "$INVENTORY"
python3 "$VERIFIER" --definition "$DEFINITION" verify-inventory \
  --profile staticLinkClosure --root "$OUTPUT_ROOT" --inventory "$INVENTORY"
echo "built maintained dual VirGL2 + Venus Metal renderer closure at $OUTPUT_ROOT"
