#!/bin/bash
# Build Dory's pinned ANGLE Metal, static libepoxy, and static MoltenVK dependency closure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFINITION="$ROOT/Config/DoryRendererProductionTuple.json"
VERIFIER="$ROOT/scripts/renderer-production-tuple.py"
PREFIX=""
INVENTORY=""
JOBS=3

usage() {
  echo "usage: $0 --prefix PATH [--inventory PATH] [--jobs COUNT]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?missing prefix path}"; shift 2 ;;
    --inventory) INVENTORY="${2:?missing inventory path}"; shift 2 ;;
    --jobs) JOBS="${2:?missing job count}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build-renderer-production-dependencies: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PREFIX" ] || { usage; exit 2; }
case "$PREFIX" in
  /|"$HOME"|"$ROOT")
    echo "build-renderer-production-dependencies: refusing broad output path $PREFIX" >&2
    exit 2 ;;
esac
case "$JOBS" in
  ''|*[!0-9]*) echo "build-renderer-production-dependencies: jobs must be an integer" >&2; exit 2 ;;
esac
[ "$JOBS" -gt 0 ] || {
  echo "build-renderer-production-dependencies: jobs must be positive" >&2
  exit 2
}
[ "$JOBS" -le 3 ] || {
  echo "build-renderer-production-dependencies: jobs must not exceed the live-host ceiling of 3" >&2
  exit 2
}

for command in ditto git install install_name_tool lipo make meson ninja nm otool python3 ranlib strings xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "build-renderer-production-dependencies: missing $command" >&2
    exit 1
  }
done
[ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ] || {
  echo "build-renderer-production-dependencies: set DEVELOPER_DIR to the reviewed full Xcode" >&2
  exit 1
}
REAL_XCODEBUILD="$(command -v xcodebuild)"
XCODEBUILD_WRAPPER_DIR="$ROOT/scripts/renderer-build-tools"
XCODEBUILD_WRAPPER="$XCODEBUILD_WRAPPER_DIR/xcodebuild"
[ -x "$XCODEBUILD_WRAPPER" ] || {
  echo "build-renderer-production-dependencies: missing executable $XCODEBUILD_WRAPPER" >&2
  exit 1
}
python3 "$VERIFIER" --definition "$DEFINITION" verify-definition --repo-root "$ROOT"
python3 "$VERIFIER" --definition "$DEFINITION" verify-toolchain

export DORY_XCODEBUILD_REAL="$REAL_XCODEBUILD"
export DORY_XCODEBUILD_JOBS="$JOBS"
export PATH="$XCODEBUILD_WRAPPER_DIR:$PATH"
[ "$(command -v xcodebuild)" = "$XCODEBUILD_WRAPPER" ] || {
  echo "build-renderer-production-dependencies: xcodebuild concurrency wrapper is not active" >&2
  exit 1
}

if [ -e "$PREFIX" ]; then
  [ -d "$PREFIX" ] || {
    echo "build-renderer-production-dependencies: prefix is not a directory: $PREFIX" >&2
    exit 1
  }
  [ -z "$(find "$PREFIX" -mindepth 1 -print -quit)" ] || {
    echo "build-renderer-production-dependencies: prefix must be absent or empty: $PREFIX" >&2
    exit 1
  }
fi
[ -n "$INVENTORY" ] || INVENTORY="$PREFIX/renderer-static-dependencies.json"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dory-renderer-static-dependencies.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SOURCES="$WORK/sources"
BUILDS="$WORK/builds"
STAGE="$WORK/stage"
mkdir -p "$SOURCES" "$BUILDS" "$STAGE/Frameworks" "$STAGE/include" "$STAGE/lib"

clone_exact() {
  local name="$1" destination="$2" repository revision
  repository="$(source_value "$name" repository)"
  revision="$(source_value "$name" revision)"
  git clone --filter=tree:0 --no-checkout "$repository" "$destination"
  git -C "$destination" fetch --depth=1 origin "$revision"
  git -C "$destination" checkout --detach "$revision"
  git -C "$destination" submodule update --init --recursive --depth=1
  python3 "$VERIFIER" --definition "$DEFINITION" verify-checkout \
    --source "$name" --checkout "$destination"
}

clone_exact_angle() {
  local destination="$1" repository revision
  repository="$(source_value angle repository)"
  revision="$(source_value angle revision)"
  git clone --filter=tree:0 --no-checkout "$repository" "$destination"
  git -C "$destination" sparse-checkout init
  git -C "$destination" sparse-checkout set \
    Source/ThirdParty/ANGLE Configurations Tools/ccache
  git -C "$destination" fetch --depth=1 origin "$revision"
  git -C "$destination" checkout --detach "$revision"
  python3 "$VERIFIER" --definition "$DEFINITION" verify-checkout \
    --source angle --checkout "$destination"
}

verify_dependency_checkout() {
  local owner="$1" dependency="$2" checkout="$3"
  [ -d "$checkout/.git" ] || {
    echo "build-renderer-production-dependencies: dependency checkout is missing Git identity: $checkout" >&2
    exit 1
  }
  python3 "$VERIFIER" --definition "$DEFINITION" verify-dependency-checkout \
    --owner "$owner" --dependency "$dependency" --checkout "$checkout"
}

apply_compatibility_patches() {
  local source_name="$1" checkout="$2" patch_count=0 relative_patch absolute_patch
  python3 "$VERIFIER" --definition "$DEFINITION" verify-dependency-build-checkout \
    --source "$source_name" --checkout "$checkout" --state source
  while IFS= read -r relative_patch; do
    [ -n "$relative_patch" ] || continue
    absolute_patch="$ROOT/$relative_patch"
    git -C "$checkout" apply --check --whitespace=error-all "$absolute_patch"
    git -C "$checkout" apply --whitespace=error-all "$absolute_patch"
    patch_count=$((patch_count + 1))
  done < <(
    python3 "$VERIFIER" --definition "$DEFINITION" dependency-build-patch-paths \
      --source "$source_name" --repo-root "$ROOT"
  )
  expected_patch_count="$(python3 - "$DEFINITION" "$source_name" <<'PY'
import json
import pathlib
import sys

definition = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(sum(
    patch["source"] == sys.argv[2]
    for patch in definition["dependencyBuildPolicy"]["compatibilityPatches"]
))
PY
)"
  [ "$patch_count" -eq "$expected_patch_count" ] && [ "$patch_count" -gt 0 ] || {
    echo "build-renderer-production-dependencies: reviewed patch count differs for $source_name" >&2
    exit 1
  }
  python3 "$VERIFIER" --definition "$DEFINITION" verify-dependency-build-checkout \
    --source "$source_name" --checkout "$checkout" --state applied
}

verify_angle_runtime_library() {
  local path="$1" expected_id="$2" dependency
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "build-renderer-production-dependencies: ANGLE runtime library is unavailable: $path" >&2
    exit 1
  }
  [ "$(lipo -archs "$path")" = arm64 ] || {
    echo "build-renderer-production-dependencies: ANGLE runtime library is not exactly arm64" >&2
    exit 1
  }
  [ "$(otool -D "$path" | sed -n '2p')" = "$expected_id" ] || {
    echo "build-renderer-production-dependencies: ANGLE install name differs for $path" >&2
    exit 1
  }
  ! otool -l "$path" | grep -q 'cmd LC_RPATH' || {
    echo "build-renderer-production-dependencies: ANGLE runtime library contains LC_RPATH" >&2
    exit 1
  }
  while IFS= read -r dependency; do
    [ "$dependency" = "$expected_id" ] && continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *) echo "build-renderer-production-dependencies: ANGLE has non-system dependency $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$path" | awk 'NR > 1 { print $1 }')
}

clone_exact_angle "$SOURCES/WebKit"
apply_compatibility_patches angle "$SOURCES/WebKit"
ANGLE_ROOT="$SOURCES/WebKit/Source/ThirdParty/ANGLE"
ANGLE_ARCHIVE="$BUILDS/ANGLE"
env -i \
  DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
  DORY_XCODEBUILD_JOBS="$DORY_XCODEBUILD_JOBS" \
  DORY_XCODEBUILD_REAL="$DORY_XCODEBUILD_REAL" \
  HOME="$HOME" \
  LANG=en_US.UTF-8 \
  PATH="$PATH" \
  xcodebuild archive -quiet \
    -project "$ANGLE_ROOT/ANGLE.xcodeproj" \
    -archivePath "$ANGLE_ARCHIVE" \
    -derivedDataPath "$BUILDS/angle-derived-data" \
    -scheme ANGLE \
    -sdk macosx \
    -arch arm64 \
    -configuration Release \
    WEBCORE_LIBRARY_DIR=/usr/local/lib \
    NORMAL_UMBRELLA_FRAMEWORKS_DIR= \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    WK_LIBCPP_ASSERTIONS_CFLAGS_MACOS_SINCE_1400=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE

for angle_name in libEGL.dylib libGLESv2.dylib; do
  source_library="$ANGLE_ARCHIVE.xcarchive/Products/usr/local/lib/$angle_name"
  destination_library="$STAGE/Frameworks/$angle_name"
  install -m0755 "$source_library" "$destination_library"
  install_name_tool -id "@loader_path/$angle_name" "$destination_library"
  verify_angle_runtime_library "$destination_library" "@loader_path/$angle_name"
done
for angle_header in EGL/egl.h EGL/eglext.h EGL/eglplatform.h KHR/khrplatform.h; do
  mkdir -p "$STAGE/include/ANGLE/$(dirname "$angle_header")"
  install -m0644 "$ANGLE_ROOT/include/$angle_header" "$STAGE/include/ANGLE/$angle_header"
done

clone_exact libepoxy "$SOURCES/libepoxy"
apply_compatibility_patches libepoxy "$SOURCES/libepoxy"
EPOXY_BUILD="$BUILDS/libepoxy"
EPOXY_INSTALL="$BUILDS/libepoxy-install"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
env -i \
  CC="$CLANG" \
  CFLAGS="-arch arm64 -isysroot $SDKROOT -mmacosx-version-min=15.0 -I$ANGLE_ROOT/include" \
  HOME="$HOME" \
  LANG=en_US.UTF-8 \
  PATH="$PATH" \
  meson setup "$EPOXY_BUILD" "$SOURCES/libepoxy" \
    --buildtype release \
    --default-library static \
    --prefix "$EPOXY_INSTALL" \
    -Degl=yes \
    -Dglx=no \
    -Dtests=false \
    -Dx11=false
meson compile -C "$EPOXY_BUILD" -j "$JOBS"
meson install -C "$EPOXY_BUILD"
mkdir -p "$STAGE/include/epoxy"
for epoxy_header in common.h egl.h egl_angle_ext_generated.h egl_generated.h gl.h gl_generated.h; do
  install -m0644 "$EPOXY_INSTALL/include/epoxy/$epoxy_header" \
    "$STAGE/include/epoxy/$epoxy_header"
done
install -m0644 "$EPOXY_INSTALL/lib/libepoxy.a" "$STAGE/lib/libepoxy.a"
ranlib "$STAGE/lib/libepoxy.a"
[ "$(lipo -archs "$STAGE/lib/libepoxy.a")" = arm64 ] || {
  echo "build-renderer-production-dependencies: static libepoxy is not exactly arm64" >&2
  exit 1
}
for fixed_resolver in \
  '@loader_path/../Frameworks/libEGL.dylib' \
  '@loader_path/../Frameworks/libGLESv2.dylib'; do
  strings -a "$STAGE/lib/libepoxy.a" | grep -Fx "$fixed_resolver" >/dev/null || {
    echo "build-renderer-production-dependencies: static libepoxy lacks fixed ANGLE resolver $fixed_resolver" >&2
    exit 1
  }
done

clone_exact moltenVK "$SOURCES/MoltenVK"
apply_compatibility_patches moltenVK "$SOURCES/MoltenVK"
MOLTEN_BUILD_ROOT="$BUILDS/moltenvk"

(
  cd "$SOURCES/MoltenVK"
  env -i \
    DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    DORY_XCODEBUILD_JOBS="$DORY_XCODEBUILD_JOBS" \
    DORY_XCODEBUILD_REAL="$DORY_XCODEBUILD_REAL" \
    HOME="$HOME" \
    LANG=en_US.UTF-8 \
    PATH="$PATH" \
    ./fetchDependencies --macos
  verify_dependency_checkout moltenVK cereal External/cereal
  verify_dependency_checkout moltenVK vulkanHeaders External/Vulkan-Headers
  verify_dependency_checkout moltenVK spirvCross External/SPIRV-Cross
  verify_dependency_checkout moltenVK spirvTools External/SPIRV-Tools
  verify_dependency_checkout moltenVK spirvHeaders \
    External/SPIRV-Tools/external/spirv-headers
  verify_dependency_checkout moltenVK vulkanTools External/Vulkan-Tools
  verify_dependency_checkout moltenVK volk External/Volk
  env -i \
    DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    DORY_XCODEBUILD_JOBS="$DORY_XCODEBUILD_JOBS" \
    DORY_XCODEBUILD_REAL="$DORY_XCODEBUILD_REAL" \
    HOME="$HOME" \
    LANG=en_US.UTF-8 \
    PATH="$PATH" \
    xcodebuild build \
      -quiet \
      -project MoltenVK/MoltenVK.xcodeproj \
      -target MoltenVK-macOS-static \
      -configuration Release \
      -sdk macosx \
      "GCC_PREPROCESSOR_DEFINITIONS=\${inherited} MVK_HIDE_VULKAN_SYMBOLS=1" \
      SYMROOT="$MOLTEN_BUILD_ROOT"
)

MOLTEN_SOURCE_ARCHIVE="$MOLTEN_BUILD_ROOT/Release/libMoltenVK.a"
[ -f "$MOLTEN_SOURCE_ARCHIVE" ] && [ ! -L "$MOLTEN_SOURCE_ARCHIVE" ] || {
  echo "build-renderer-production-dependencies: exact static MoltenVK target did not produce its archive" >&2
  exit 1
}
MOLTEN_ARCHIVE="$STAGE/lib/libMoltenVK.a"
install -m0644 "$MOLTEN_SOURCE_ARCHIVE" "$MOLTEN_ARCHIVE"
ranlib "$MOLTEN_ARCHIVE"
[ "$(lipo -archs "$MOLTEN_ARCHIVE")" = arm64 ] || {
  echo "build-renderer-production-dependencies: MoltenVK archive is not exactly arm64" >&2
  exit 1
}
if nm -u "$MOLTEN_ARCHIVE" | grep -E '_vk[A-Z][A-Za-z0-9_]*$' \
    >"$BUILDS/undefined-vulkan-symbols.txt"; then
  echo "build-renderer-production-dependencies: static MoltenVK retains loader-owned Vulkan symbols" >&2
  cat "$BUILDS/undefined-vulkan-symbols.txt" >&2
  exit 1
fi

MOLTEN_SYMBOLS="$BUILDS/moltenvk-defined-symbols.txt"
nm -gU "$MOLTEN_ARCHIVE" >"$MOLTEN_SYMBOLS"
grep '_vkGetInstanceProcAddr$' "$MOLTEN_SYMBOLS" >/dev/null || {
  echo "build-renderer-production-dependencies: static MoltenVK lacks vkGetInstanceProcAddr" >&2
  exit 1
}
if awk '$NF ~ /^_vk/ && $NF != "_vkGetInstanceProcAddr" { print; found=1 } END { exit found ? 0 : 1 }' \
    "$MOLTEN_SYMBOLS" >"$BUILDS/unexpected-vulkan-symbols.txt"; then
  echo "build-renderer-production-dependencies: static MoltenVK exposes Vulkan symbols beyond vkGetInstanceProcAddr" >&2
  cat "$BUILDS/unexpected-vulkan-symbols.txt" >&2
  exit 1
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANGXX="$(xcrun --sdk macosx --find clang++)"
VULKAN_HEADERS_INCLUDE="$SOURCES/MoltenVK/External/Vulkan-Headers/include"
[ -f "$VULKAN_HEADERS_INCLUDE/vulkan/vulkan.h" ] || {
  echo "build-renderer-production-dependencies: verified Vulkan headers are unavailable" >&2
  exit 1
}
MOLTENVK_SEMAPHORE_PROBE="$BUILDS/dory-moltenvk-semaphore-probe"
"$CLANGXX" \
  -arch arm64 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=15.0 \
  -fobjc-arc \
  -pthread \
  -Wall \
  -Wextra \
  -Werror \
  -I"$VULKAN_HEADERS_INCLUDE" \
  "$ROOT/scripts/renderer-moltenvk-semaphore-probe.m" \
  "$MOLTEN_ARCHIVE" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Foundation \
  -framework IOKit \
  -framework IOSurface \
  -framework Metal \
  -framework QuartzCore \
  -o "$MOLTENVK_SEMAPHORE_PROBE"
env -i \
  MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE=2 \
  PATH="$PATH" \
  "$MOLTENVK_SEMAPHORE_PROBE"

MOLTENVK_SCANOUT_COPY_PROBE="$BUILDS/dory-moltenvk-scanout-copy-probe"
"$CLANGXX" \
  -arch arm64 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=15.0 \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -I"$VULKAN_HEADERS_INCLUDE" \
  "$ROOT/scripts/renderer-moltenvk-scanout-copy-probe.m" \
  "$MOLTEN_ARCHIVE" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Foundation \
  -framework IOKit \
  -framework IOSurface \
  -framework Metal \
  -framework QuartzCore \
  -o "$MOLTENVK_SCANOUT_COPY_PROBE"
env -i \
  MVK_CONFIG_LOG_LEVEL=1 \
  PATH="$PATH" \
  "$MOLTENVK_SCANOUT_COPY_PROBE"

mkdir -p "$PREFIX"
ditto "$STAGE" "$PREFIX"
python3 "$VERIFIER" --definition "$DEFINITION" create-inventory \
  --profile staticDependencies --root "$PREFIX" --output "$INVENTORY"
python3 "$VERIFIER" --definition "$DEFINITION" verify-inventory \
  --profile staticDependencies --root "$PREFIX" --inventory "$INVENTORY"
echo "built exact ANGLE Metal + static libepoxy + static MoltenVK dependency prefix $PREFIX"
