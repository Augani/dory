#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS
source guest/kernel/docker-endpoint.sh

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the Dory Venus runtime currently supports arm64 only" >&2; exit 64 ;;
esac

OUT="$ROOT/guest/out"
mkdir -p "$OUT"
RUNTIME="$OUT/dory-mesa-venus-arm64.tar.zst"
STAMP="$OUT/dory-mesa-venus-build-arm64.stamp"
INPUT_SHA256="$(guest/mesa/input-fingerprint.sh arm64)"
BUILD_JOBS="${DORY_MESA_BUILD_JOBS:-3}"
case "$BUILD_JOBS" in
  ''|*[!0-9]*|0) echo "DORY_MESA_BUILD_JOBS must be a positive integer" >&2; exit 64 ;;
esac

if [ -s "$RUNTIME" ] && [ -s "$STAMP" ] \
  && grep -Fqx "input_sha256=$INPUT_SHA256" "$STAMP" \
  && guest/mesa/verify-build.sh arm64 >/dev/null 2>&1; then
  echo "using current $RUNTIME"
  exit 0
fi

DOCKER_BIN="${DORY_MESA_DOCKER_BIN:-$(command -v docker || true)}"
[ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || { echo "docker CLI not found" >&2; exit 1; }
DOCKER_ENDPOINT="$(dory_kernel_resolve_docker_endpoint "$DOCKER_BIN" "${DORY_MESA_DOCKER_HOST:-}")"
docker_cmd() {
  dory_kernel_docker "$DOCKER_BIN" "$DOCKER_ENDPOINT" "$@"
}

STAGING="$(mktemp -d "$OUT/.mesa-venus-build-arm64.XXXXXX")"
CID=""
cleanup() {
  [ -z "$CID" ] || docker_cmd rm -f "$CID" >/dev/null 2>&1 || true
  rm -rf "$STAGING"
}
trap cleanup EXIT

CID="$(docker_cmd create --platform linux/arm64 \
  -e DEBIAN_FRONTEND=noninteractive \
  -e LC_ALL=C \
  -e TZ=UTC \
  -e PYTHONHASHSEED=0 \
  -e ZERO_AR_DATE=1 \
  -e SOURCE_DATE_EPOCH="$MESA_SOURCE_DATE_EPOCH" \
  -e DORY_MESA_VERSION="$MESA_VERSION" \
  -e DORY_MESA_SOURCE_REPO="$MESA_SOURCE_REPO" \
  -e DORY_MESA_SOURCE_COMMIT="$MESA_SOURCE_COMMIT" \
  -e DORY_MESA_SOURCE_TREE="$MESA_SOURCE_TREE" \
  -e DORY_MESA_BUILD_JOBS="$BUILD_JOBS" \
  -e DORY_MESA_DEBIAN_SNAPSHOT="$MESA_DEBIAN_SNAPSHOT" \
  -e DORY_MESA_DEBIAN_SNAPSHOT_URL="$MESA_DEBIAN_SNAPSHOT_URL" \
  -e DORY_MESA_DEBIAN_SECURITY_SNAPSHOT_URL="$MESA_DEBIAN_SECURITY_SNAPSHOT_URL" \
  -e DORY_MESA_LIBDRM_VERSION="$MESA_LIBDRM_VERSION" \
  -e DORY_MESA_LIBDRM_SOURCE_URL="$MESA_LIBDRM_SOURCE_URL" \
  -e DORY_MESA_LIBDRM_SOURCE_SHA256="$MESA_LIBDRM_SOURCE_SHA256" \
  -e DORY_MESA_WAYLAND_PROTOCOLS_VERSION="$MESA_WAYLAND_PROTOCOLS_VERSION" \
  -e DORY_MESA_WAYLAND_PROTOCOLS_SOURCE_URL="$MESA_WAYLAND_PROTOCOLS_SOURCE_URL" \
  -e DORY_MESA_WAYLAND_PROTOCOLS_SOURCE_SHA256="$MESA_WAYLAND_PROTOCOLS_SOURCE_SHA256" \
  -e DORY_MESA_WAYLAND_VERSION="$MESA_WAYLAND_VERSION" \
  -e DORY_MESA_WAYLAND_SOURCE_URL="$MESA_WAYLAND_SOURCE_URL" \
  -e DORY_MESA_WAYLAND_SOURCE_SHA256="$MESA_WAYLAND_SOURCE_SHA256" \
  -e DORY_MESA_RUNTIME_ARCH="$MESA_RUNTIME_ARCH" \
  -e DORY_MESA_RUNTIME_LIBC_FAMILY="$MESA_RUNTIME_LIBC_FAMILY" \
  -e DORY_MESA_RUNTIME_MAX_GLIBC_SYMBOL="$MESA_RUNTIME_MAX_GLIBC_SYMBOL" \
  -e DORY_MESA_RUNTIME_VULKAN_API="$MESA_RUNTIME_VULKAN_API" \
  -e DORY_MESA_RUNTIME_VULKAN13_FEATURES="$MESA_RUNTIME_VULKAN13_FEATURES" \
  -e DORY_MESA_RUNTIME_VULKAN_DEVICE_EXTENSIONS="$MESA_RUNTIME_VULKAN_DEVICE_EXTENSIONS" \
  -e DORY_MESA_RUNTIME_VULKAN_INSTANCE_EXTENSIONS="$MESA_RUNTIME_VULKAN_INSTANCE_EXTENSIONS" \
  -e DORY_MESA_RUNTIME_WSI="$MESA_RUNTIME_WSI" \
  -e DORY_MESA_RUNTIME_WSI_SURFACE_GATE="$MESA_RUNTIME_WSI_SURFACE_GATE" \
  -e DORY_MESA_RUNTIME_COMPOSITOR_PROFILE="$MESA_RUNTIME_COMPOSITOR_PROFILE" \
  -e DORY_WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT="$WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT" \
  -e DORY_WLROOTS_VULKAN_PROFILE_SOURCE_TREE="$WLROOTS_VULKAN_PROFILE_SOURCE_TREE" \
  -e DORY_MESON_VERSION="$MESON_VERSION" \
  -e DORY_MESON_WHEEL_SHA256="$MESON_WHEEL_SHA256" \
  -w /build "$MESA_BUILDER_IMAGE" sleep infinity)"
docker_cmd start "$CID" >/dev/null
docker_cmd cp guest/mesa/dory-vulkan-compositor-probe.c \
  "$CID:/tmp/dory-vulkan-compositor-probe.c"
docker_cmd cp guest/mesa/dory-vulkan-probe.c "$CID:/tmp/dory-vulkan-probe.c"

docker_cmd exec "$CID" bash -euo pipefail -c '
  printf "deb [check-valid-until=no] %s bullseye main\ndeb [check-valid-until=no] %s bullseye-security main\n" \
    "$DORY_MESA_DEBIAN_SNAPSHOT_URL" "$DORY_MESA_DEBIAN_SECURITY_SNAPSHOT_URL" \
    > /etc/apt/sources.list
  find /etc/apt/sources.list.d -type f -delete 2>/dev/null || true
  if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    # The pinned slim base has APT archive keys but no TLS roots. APT authenticates the signed
    # Release metadata and package digest while bootstrapping CA roots, then every remaining fetch
    # is repeated with normal certificate validation.
    apt-get -o Acquire::https::Verify-Peer=false update -qq
    apt-get -o Acquire::https::Verify-Peer=false install -y -qq \
      --no-install-recommends ca-certificates
  fi
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential bison ca-certificates curl flex git libdrm-dev libexpat1-dev \
    libvulkan-dev libwayland-dev libx11-xcb-dev libxcb-dri3-dev \
    libxcb-keysyms1-dev libxcb-present-dev libxcb-randr0-dev libxcb-shm0-dev \
    libxcb-sync-dev libxcb-xfixes0-dev libxrandr-dev libxshmfence-dev \
    libzstd-dev ninja-build patch pkg-config python3-mako python3-packaging \
    python3-pip python3-ply python3-yaml wayland-protocols xz-utils zlib1g-dev zstd

  source_dir=/build/mesa
  git init -q "$source_dir"
  git -C "$source_dir" remote add origin "$DORY_MESA_SOURCE_REPO"
  git -C "$source_dir" fetch --depth=1 --filter=blob:none origin "$DORY_MESA_SOURCE_COMMIT"
  git -C "$source_dir" checkout --detach FETCH_HEAD
  [ "$(git -C "$source_dir" rev-parse HEAD)" = "$DORY_MESA_SOURCE_COMMIT" ]
  [ "$(git -C "$source_dir" rev-parse HEAD^{tree})" = "$DORY_MESA_SOURCE_TREE" ]
  [ "$(git -C "$source_dir" show -s --format=%ct HEAD)" = "$SOURCE_DATE_EPOCH" ]
  libdrm_cache="$source_dir/subprojects/packagecache/libdrm-${DORY_MESA_LIBDRM_VERSION}.tar.xz"
  install -d -m0755 "${libdrm_cache%/*}"
  curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
    --output "$libdrm_cache" "$DORY_MESA_LIBDRM_SOURCE_URL"
  printf "%s  %s\n" "$DORY_MESA_LIBDRM_SOURCE_SHA256" "$libdrm_cache" | sha256sum -c -
  grep -Fqx "directory = libdrm-${DORY_MESA_LIBDRM_VERSION}" \
    "$source_dir/subprojects/libdrm.wrap"
  grep -Fqx "source_hash = ${DORY_MESA_LIBDRM_SOURCE_SHA256}" \
    "$source_dir/subprojects/libdrm.wrap"

  wayland_protocols_cache="$source_dir/subprojects/packagecache/wayland-protocols-${DORY_MESA_WAYLAND_PROTOCOLS_VERSION}.tar.xz"
  curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
    --output "$wayland_protocols_cache" "$DORY_MESA_WAYLAND_PROTOCOLS_SOURCE_URL"
  printf "%s  %s\n" "$DORY_MESA_WAYLAND_PROTOCOLS_SOURCE_SHA256" \
    "$wayland_protocols_cache" | sha256sum -c -
  grep -Fqx "directory = wayland-protocols-${DORY_MESA_WAYLAND_PROTOCOLS_VERSION}" \
    "$source_dir/subprojects/wayland-protocols.wrap"
  grep -Fqx "source_hash = ${DORY_MESA_WAYLAND_PROTOCOLS_SOURCE_SHA256}" \
    "$source_dir/subprojects/wayland-protocols.wrap"

  wayland_cache="$source_dir/subprojects/packagecache/wayland-${DORY_MESA_WAYLAND_VERSION}.tar.xz"
  curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
    --output "$wayland_cache" "$DORY_MESA_WAYLAND_SOURCE_URL"
  printf "%s  %s\n" "$DORY_MESA_WAYLAND_SOURCE_SHA256" "$wayland_cache" | sha256sum -c -

  python3 -m pip download --disable-pip-version-check --no-deps \
    --dest /build "meson==${DORY_MESON_VERSION}" >/dev/null
  meson_wheel="$(find /build -maxdepth 1 -type f -name "meson-${DORY_MESON_VERSION}-*.whl" -print -quit)"
  [ -n "$meson_wheel" ]
  printf "%s  %s\n" "$DORY_MESON_WHEEL_SHA256" "$meson_wheel" | sha256sum -c -
  pip_system_flag=
  if python3 -m pip install --help 2>&1 | grep -q -- --break-system-packages; then
    pip_system_flag=--break-system-packages
  fi
  python3 -m pip install $pip_system_flag --disable-pip-version-check \
    --no-index "$meson_wheel" >/dev/null

  # wayland-protocols 1.41 generates the wl_proxy_marshal_flags ABI introduced by Wayland 1.20.
  # Bullseye 1.18 headers cannot describe that interface. Build an exact 1.20 compile sysroot;
  # only its public SONAME remains a guest interface and no toolchain DSO enters the runtime pack.
  tar -xJf "$wayland_cache" -C /build
  meson setup /build/wayland-build "/build/wayland-${DORY_MESA_WAYLAND_VERSION}" \
    --prefix=/toolchain \
    --libdir=lib \
    --buildtype=release \
    -Ddocumentation=false \
    -Ddtd_validation=false \
    -Dtests=false
  ninja -j "$DORY_MESA_BUILD_JOBS" -C /build/wayland-build
  ninja -j "$DORY_MESA_BUILD_JOBS" -C /build/wayland-build install
  export PATH="/toolchain/bin:$PATH"
  export PKG_CONFIG_PATH=/toolchain/lib/pkgconfig
  [ "$(pkg-config --modversion wayland-client)" = "$DORY_MESA_WAYLAND_VERSION" ]
  [ "$(pkg-config --modversion wayland-server)" = "$DORY_MESA_WAYLAND_VERSION" ]
  wayland_scanner_version="$(wayland-scanner --version 2>&1)"
  case "$wayland_scanner_version" in
    *" $DORY_MESA_WAYLAND_VERSION") ;;
    *) echo "unexpected Wayland scanner: $wayland_scanner_version" >&2; exit 1 ;;
  esac

  meson setup --wrap-mode=nodownload /build/mesa-build "$source_dir" \
    --prefix=/opt/dory/mesa \
    --libdir=lib \
    --buildtype=release \
    -Dc_link_args=-Wl,--exclude-libs,ALL \
    -Dlibdrm:default_library=static \
    -Dlibdrm:intel=disabled \
    -Dlibdrm:radeon=disabled \
    -Dlibdrm:amdgpu=disabled \
    -Dlibdrm:nouveau=disabled \
    -Dlibdrm:vmwgfx=disabled \
    -Dlibdrm:omap=disabled \
    -Dlibdrm:exynos=disabled \
    -Dlibdrm:freedreno=disabled \
    -Dlibdrm:tegra=disabled \
    -Dlibdrm:vc4=disabled \
    -Dlibdrm:etnaviv=disabled \
    -Dlibdrm:cairo-tests=disabled \
    -Dlibdrm:man-pages=disabled \
    -Dlibdrm:valgrind=disabled \
    -Dlibdrm:tests=false \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers= \
    -Dvulkan-drivers=virtio \
    -Dvulkan-layers= \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dopengl=false \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dllvm=disabled \
    -Dvideo-codecs= \
    -Dvalgrind=disabled \
    -Dlibunwind=disabled \
    -Dlmsensors=disabled \
    -Dzstd=enabled \
    -Dxmlconfig=disabled \
    -Dallow-fallback-for=libdrm \
    -Dbuild-tests=false
  ninja -j "$DORY_MESA_BUILD_JOBS" -C /build/mesa-build
  DESTDIR=/stage ninja -j "$DORY_MESA_BUILD_JOBS" -C /build/mesa-build install

  # libdrm is linked into the ICD and hidden from its dynamic symbol surface. A renamed private
  # DSO is still vulnerable to ELF global-scope interposition when applications load their distro
  # libdrm first, so no libdrm DSO, archive, header, or pkg-config file enters the runtime pack.
  rm -rf /stage/opt/dory/mesa/bin /stage/opt/dory/mesa/include \
    /stage/opt/dory/mesa/lib/pkgconfig /stage/opt/dory/mesa/share/aclocal \
    /stage/opt/dory/mesa/share/libdrm /stage/opt/dory/mesa/share/pkgconfig \
    /stage/opt/dory/mesa/share/wayland /stage/opt/dory/mesa/share/wayland-protocols
  find /stage/opt/dory/mesa/lib -maxdepth 1 -type f -name "*.a" -delete

  install -d -m0755 /stage/opt/dory/mesa/libexec /stage/opt/dory/mesa/share/dory
  # The Bullseye loader is a valid public runtime interface, but its development headers predate
  # Vulkan 1.3. Compile the probe against the exact Vulkan headers in the pinned Mesa tree. The
  # probe also creates real XCB/Wayland native surfaces, so those public client SONAMEs are part of
  # its explicit, manifest-bound guest interface rather than ambient application dependencies.
  cc -O2 -Wall -Wextra -Werror -I"$source_dir/include" /tmp/dory-vulkan-probe.c \
    -o /stage/opt/dory/mesa/libexec/dory-vulkan-probe \
    -lvulkan -lxcb -lwayland-client
  cc -O2 -Wall -Wextra -Werror -I"$source_dir/include" \
    $(pkg-config --cflags libdrm) \
    -DDORY_COMPOSITOR_SOURCE_COMMIT=\"$DORY_WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT\" \
    /tmp/dory-vulkan-compositor-probe.c \
    -o /stage/opt/dory/mesa/libexec/dory-vulkan-compositor-probe \
    -lvulkan
  chmod 0755 /stage/opt/dory/mesa/libexec/dory-vulkan-probe
  chmod 0755 /stage/opt/dory/mesa/libexec/dory-vulkan-compositor-probe

  icd=/stage/opt/dory/mesa/lib/libvulkan_virtio.so
  probe=/stage/opt/dory/mesa/libexec/dory-vulkan-probe
  compositor_probe=/stage/opt/dory/mesa/libexec/dory-vulkan-compositor-probe
  icd_manifest=/stage/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json
  grep -Fq "\"library_path\": \"/opt/dory/mesa/lib/libvulkan_virtio.so\"" "$icd_manifest"
  sed -i "s#\"/opt/dory/mesa/lib/libvulkan_virtio.so\"#\"../../../lib/libvulkan_virtio.so\"#" \
    "$icd_manifest"

  icd_dynamic="$(readelf -d --wide "$icd")"
  if printf "%s\n" "$icd_dynamic" | grep -Eq "\((RPATH|RUNPATH)\)"; then
    echo "Venus ICD unexpectedly carries an ambient loader search path" >&2
    exit 1
  fi
  if printf "%s\n" "$icd_dynamic" | grep -Eq "Shared library: \[(libdrm|libdorydrm)\.so"; then
    echo "Venus ICD did not statically isolate libdrm" >&2
    exit 1
  fi
  if readelf --dyn-syms --wide "$icd" \
      | awk "\$5 == \"GLOBAL\" && \$6 == \"DEFAULT\" && \$8 ~ /^drm/ { found = 1 } END { exit !found }"; then
    echo "Venus ICD exports an interposable libdrm symbol" >&2
    exit 1
  fi

  runtime_dyn_symbols="$(
    readelf --dyn-syms --wide "$icd"
    readelf --dyn-syms --wide "$probe"
    readelf --dyn-syms --wide "$compositor_probe"
  )"
  max_glibc_symbol="$(printf "%s\n" "$runtime_dyn_symbols" \
    | sed -n "s/.*@\(GLIBC_[0-9][0-9.]*\).*/\1/p" \
    | sort -Vu | tail -n 1)"
  printf "%s\n" "$max_glibc_symbol" | grep -Eq "^GLIBC_[0-9]+(\.[0-9]+)+$" || {
    echo "runtime does not declare a valid public GNU-libc symbol floor" >&2
    exit 1
  }
  [ "$(printf "%s\n%s\n" "$max_glibc_symbol" \
      "$DORY_MESA_RUNTIME_MAX_GLIBC_SYMBOL" | sort -Vu | tail -n 1)" \
      = "$DORY_MESA_RUNTIME_MAX_GLIBC_SYMBOL" ] || {
    echo "runtime requires $max_glibc_symbol above $DORY_MESA_RUNTIME_MAX_GLIBC_SYMBOL" >&2
    exit 1
  }
  if printf "%s\n" "$runtime_dyn_symbols" | grep -Fq "GLIBC_PRIVATE"; then
    echo "runtime references the non-public GLIBC_PRIVATE ABI" >&2
    exit 1
  fi
  icd_needed_sonames="$(
    printf "%s\n" "$icd_dynamic" \
      | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
      | LC_ALL=C sort | paste -sd, -
  )"
  probe_needed_sonames="$(
    readelf -d "$probe" \
      | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
      | LC_ALL=C sort | paste -sd, -
  )"
  compositor_probe_needed_sonames="$(
    readelf -d "$compositor_probe" \
      | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
      | LC_ALL=C sort | paste -sd, -
  )"
  build_packages="$(dpkg-query -W -f="\${binary:Package}=\${Version}\n" \
    | LC_ALL=C sort | sha256sum | cut -d " " -f 1)"
  printf "schema=6\narchitecture=%s\nlibc_family=%s\nmax_glibc_symbol=%s\nvulkan_api=%s\nvulkan13_features=%s\nvulkan_device_extensions=%s\nvulkan_instance_extensions=%s\nwsi=%s\nwsi_surface_gate=%s\ncompositor_profile=%s\ncompositor_profile_source_commit=%s\ncompositor_profile_source_tree=%s\npack_layout=single-tree\nmanifest_library_path=../../../lib/libvulkan_virtio.so\nlibdrm_linkage=static-hidden\nicd_needed_sonames=%s\nprobe_needed_sonames=%s\ncompositor_probe_needed_sonames=%s\nbuild_packages_sha256=%s\nmesa_version=%s\nmesa_source_commit=%s\nmesa_source_tree=%s\nmesa_source_date_epoch=%s\nbuilder_snapshot=%s\n" \
    "$DORY_MESA_RUNTIME_ARCH" "$DORY_MESA_RUNTIME_LIBC_FAMILY" \
    "$max_glibc_symbol" "$DORY_MESA_RUNTIME_VULKAN_API" \
    "$DORY_MESA_RUNTIME_VULKAN13_FEATURES" \
    "$DORY_MESA_RUNTIME_VULKAN_DEVICE_EXTENSIONS" \
    "$DORY_MESA_RUNTIME_VULKAN_INSTANCE_EXTENSIONS" \
    "$DORY_MESA_RUNTIME_WSI" "$DORY_MESA_RUNTIME_WSI_SURFACE_GATE" \
    "$DORY_MESA_RUNTIME_COMPOSITOR_PROFILE" \
    "$DORY_WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT" \
    "$DORY_WLROOTS_VULKAN_PROFILE_SOURCE_TREE" \
    "$icd_needed_sonames" "$probe_needed_sonames" \
    "$compositor_probe_needed_sonames" "$build_packages" "$DORY_MESA_VERSION" \
    "$DORY_MESA_SOURCE_COMMIT" "$DORY_MESA_SOURCE_TREE" "$SOURCE_DATE_EPOCH" \
    "$DORY_MESA_DEBIAN_SNAPSHOT" \
    > /stage/opt/dory/mesa/share/dory/runtime.env
  dpkg-query -W -f="\${binary:Package}=\${Version}\n" | LC_ALL=C sort \
    > /stage/opt/dory/mesa/share/dory/build-packages.txt
  find /stage/opt/dory/mesa -type d -exec chmod 0755 {} +
  find /stage/opt/dory/mesa -type f -exec chmod go-w {} +
  unexpected_runtime_files="$(
    find /stage/opt/dory/mesa -type f -print \
      | sed "s#^/stage/opt/dory/mesa/##" \
      | grep -Ev "^(lib/libvulkan_virtio\.so|libexec/dory-vulkan-(compositor-)?probe|share/dory/(build-packages\.txt|runtime\.env)|share/vulkan/icd\.d/virtio_icd\.aarch64\.json)$" \
      || true
  )"
  [ -z "$unexpected_runtime_files" ] || {
    printf "unexpected runtime-pack files:\n%s\n" "$unexpected_runtime_files" >&2
    exit 1
  }
  if find /stage/opt/dory/mesa -type l -print -quit | grep -q .; then
    echo "runtime pack unexpectedly contains a symlink" >&2
    exit 1
  fi

  mkdir -p /out
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C /stage -cf - . | zstd -19 -T"$DORY_MESA_BUILD_JOBS" \
      -o /out/dory-mesa-venus-arm64.tar.zst
'

docker_cmd cp "$CID:/out/dory-mesa-venus-arm64.tar.zst" "$STAGING/"
docker_cmd rm -f "$CID" >/dev/null
CID=""
chmod 0644 "$STAGING/dory-mesa-venus-arm64.tar.zst"

TEMP_STAMP="$STAGING/dory-mesa-venus-build-arm64.stamp"
{
  printf 'schema=6\narch=arm64\ninput_sha256=%s\n' "$INPUT_SHA256"
  printf 'runtime_sha256=%s\n' \
    "$(shasum -a 256 "$STAGING/dory-mesa-venus-arm64.tar.zst" | awk '{print $1}')"
  printf 'mesa_version=%s\nmesa_source_commit=%s\nmesa_source_tree=%s\nmesa_source_date_epoch=%s\n' \
    "$MESA_VERSION" "$MESA_SOURCE_COMMIT" "$MESA_SOURCE_TREE" "$MESA_SOURCE_DATE_EPOCH"
  printf 'libc_family=%s\nglibc_symbol_ceiling=%s\n' \
    "$MESA_RUNTIME_LIBC_FAMILY" "$MESA_RUNTIME_MAX_GLIBC_SYMBOL"
} > "$TEMP_STAMP"

DORY_MESA_OUT_DIR="$STAGING" guest/mesa/verify-build.sh arm64
mv -f "$STAGING/dory-mesa-venus-arm64.tar.zst" "$RUNTIME"
mv -f "$TEMP_STAMP" "$STAMP"
rmdir "$STAGING"
STAGING=""
trap - EXIT

guest/mesa/verify-build.sh arm64
echo "built $RUNTIME"
