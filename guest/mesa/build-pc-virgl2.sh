#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS
source guest/kernel/docker-endpoint.sh

case "${1:-x86_64}" in
  amd64|x86_64) ;;
  *) echo "the Dory PC VirGL2 runtime supports x86_64 only" >&2; exit 64 ;;
esac

OUT="$ROOT/guest/out"
mkdir -p "$OUT"
RUNTIME="$OUT/dory-mesa-virgl2-x86_64.tar.zst"
STAMP="$OUT/dory-mesa-virgl2-build-x86_64.stamp"
INPUT_SHA256="$(guest/mesa/input-pc-virgl2-fingerprint.sh x86_64)"
BUILD_JOBS="${DORY_MESA_BUILD_JOBS:-3}"
case "$BUILD_JOBS" in
  ''|*[!0-9]*|0) echo "DORY_MESA_BUILD_JOBS must be a positive integer" >&2; exit 64 ;;
esac

if [ -s "$RUNTIME" ] && [ -s "$STAMP" ] \
  && grep -Fqx "input_sha256=$INPUT_SHA256" "$STAMP" \
  && guest/mesa/verify-pc-virgl2-build.sh x86_64 >/dev/null 2>&1; then
  echo "using current $RUNTIME"
  exit 0
fi

DOCKER_BIN="${DORY_MESA_DOCKER_BIN:-$(command -v docker || true)}"
[ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || { echo "docker CLI not found" >&2; exit 1; }
DOCKER_ENDPOINT="$(dory_kernel_resolve_docker_endpoint "$DOCKER_BIN" "${DORY_MESA_DOCKER_HOST:-}")"
docker_cmd() {
  dory_kernel_docker "$DOCKER_BIN" "$DOCKER_ENDPOINT" "$@"
}

STAGING="$(mktemp -d "$OUT/.mesa-virgl2-build-x86_64.XXXXXX")"
CID=""
cleanup() {
  status=$?
  if [ "$status" -eq 0 ] || [ "${DORY_MESA_PRESERVE_FAILED_CANDIDATE:-1}" = 0 ]; then
    [ -z "$CID" ] || docker_cmd rm -f "$CID" >/dev/null 2>&1 || true
    [ -z "$STAGING" ] || rm -rf "$STAGING"
  else
    [ -z "$STAGING" ] || echo "preserving failed PC VirGL2 runtime candidate in $STAGING" >&2
    [ -z "$CID" ] || echo "preserving failed PC VirGL2 build container $CID" >&2
  fi
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
  -e DORY_MESA_RUNTIME_LIBC_FAMILY="$MESA_RUNTIME_LIBC_FAMILY" \
  -e DORY_MESA_RUNTIME_MAX_GLIBC_SYMBOL="$MESA_RUNTIME_MAX_GLIBC_SYMBOL" \
  -e DORY_MESON_VERSION="$MESON_VERSION" \
  -e DORY_MESON_WHEEL_SHA256="$MESON_WHEEL_SHA256" \
  -w /build "$MESA_BUILDER_IMAGE" sleep infinity)"
docker_cmd start "$CID" >/dev/null

docker_cmd exec "$CID" bash -euo pipefail -c '
  printf "deb [check-valid-until=no] %s bullseye main
deb [check-valid-until=no] %s bullseye-security main
" \
    "$DORY_MESA_DEBIAN_SNAPSHOT_URL" "$DORY_MESA_DEBIAN_SECURITY_SNAPSHOT_URL" \
    > /etc/apt/sources.list
  find /etc/apt/sources.list.d -type f -delete 2>/dev/null || true
  if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get -o Acquire::https::Verify-Peer=false -o Acquire::Retries=3 update -qq
    apt-get -o Acquire::https::Verify-Peer=false install -y -qq \
      --no-install-recommends ca-certificates
  fi
  apt-get -o Acquire::Retries=3 update -qq
  dpkg --add-architecture amd64
  apt-get -o Acquire::Retries=3 update -qq
  apt-get install -y -qq --no-install-recommends \
    bison build-essential ca-certificates curl flex g++-x86-64-linux-gnu \
    gcc-x86-64-linux-gnu git libdrm-dev:amd64 libexpat1-dev:amd64 \
    libx11-xcb-dev:amd64 libxcb-dri2-0-dev:amd64 libxcb-dri3-dev:amd64 \
    libxcb-glx0-dev:amd64 libxcb-present-dev:amd64 libxcb-randr0-dev:amd64 \
    libxcb-shm0-dev:amd64 libxcb-sync-dev:amd64 libxcb-xfixes0-dev:amd64 \
    libxdamage-dev:amd64 libxext-dev:amd64 \
    libxfixes-dev:amd64 libxrandr-dev:amd64 libxshmfence-dev:amd64 \
    libxxf86vm-dev:amd64 libzstd-dev:amd64 ninja-build patch pkg-config python3-mako \
    python3-packaging python3-pip python3-ply python3-yaml xz-utils \
    zlib1g-dev:amd64 zstd

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

  cat >/build/x86_64-linux-gnu.cross <<EOF
[binaries]
c = '\''x86_64-linux-gnu-gcc'\''
cpp = '\''x86_64-linux-gnu-g++'\''
ar = '\''x86_64-linux-gnu-gcc-ar'\''
strip = '\''x86_64-linux-gnu-strip'\''
readelf = '\''x86_64-linux-gnu-readelf'\''
pkgconfig = '\''pkg-config'\''

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['\''/usr/lib/x86_64-linux-gnu/pkgconfig'\'', '\''/usr/share/pkgconfig'\'']

[host_machine]
system = '\''linux'\''
cpu_family = '\''x86_64'\''
cpu = '\''x86_64'\''
endian = '\''little'\''
EOF
  export PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig

  meson setup --cross-file /build/x86_64-linux-gnu.cross --wrap-mode=nodownload /build/mesa-build "$source_dir" \
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
    -Dplatforms=x11 \
    -Dgallium-drivers=virgl \
    -Dvulkan-drivers= \
    -Dvulkan-layers= \
    -Dglx=dri \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dopengl=true \
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

  driver=/stage/opt/dory/mesa/lib/dri/virtio_gpu_dri.so
  if [ ! -s "$driver" ]; then
    gallium_megadriver="$(find /stage/opt/dory/mesa/lib -maxdepth 1 -type f \
      -name "libgallium-*.so" -print -quit)"
    [ -n "$gallium_megadriver" ] || {
      echo "Mesa install did not produce a VirGL DRI driver or gallium megadriver" >&2
      exit 1
    }
    install -d -m0755 "$(dirname "$driver")"
    install -m0644 "$gallium_megadriver" "$driver"
  fi
  [ -s "$driver" ]
  gl_loader_source="$(find /stage/opt/dory/mesa/lib -maxdepth 1 -type f \
    -name "libGL.so.*" | LC_ALL=C sort -V | tail -n 1)"
  [ -n "$gl_loader_source" ] || {
    echo "Mesa install did not produce a matching GLX loader" >&2
    exit 1
  }
  copy_regular_runtime_file() {
    if [ "$1" != "$2" ]; then
      install -m0644 "$1" "$2"
    else
      chmod 0644 "$2"
    fi
  }
  copy_regular_runtime_file "$gl_loader_source" /stage/opt/dory/mesa/lib/libGL.so.1.2.0
  copy_regular_runtime_file "$gl_loader_source" /stage/opt/dory/mesa/lib/libGL.so.1
  copy_regular_runtime_file "$gl_loader_source" /stage/opt/dory/mesa/lib/libGL.so
  copy_regular_runtime_file "$driver" "/stage/opt/dory/mesa/lib/libgallium-${DORY_MESA_VERSION}.so"
  grep -aFq "virtio_gpu_driver_descriptor" "$driver" || {
    echo "DRI driver does not bind the virtio-gpu DRM descriptor" >&2
    exit 1
  }
  grep -aFq "pipe_virtio_gpu_create_screen" "$driver" || {
    echo "DRI driver does not bind the virtio-gpu VirGL screen factory" >&2
    exit 1
  }
  find /stage/opt/dory/mesa -mindepth 1 -maxdepth 1 ! -name lib -exec rm -rf {} +
  find /stage/opt/dory/mesa/lib -maxdepth 1 -type l -delete
  find /stage/opt/dory/mesa/lib -mindepth 1 -maxdepth 1 \
    ! -name dri \
    ! -name libGL.so \
    ! -name libGL.so.1 \
    ! -name libGL.so.1.2.0 \
    ! -name "libgallium-${DORY_MESA_VERSION}.so" \
    -exec rm -rf {} +
  find /stage/opt/dory/mesa/lib/dri -type f ! -name virtio_gpu_dri.so -delete
  find /stage/opt/dory/mesa/lib/dri -type l -delete
  install -d -m0755 /stage/opt/dory/mesa/share/dory

  driver_dynamic="$(x86_64-linux-gnu-readelf -d --wide "$driver")"
  gl_loader=/stage/opt/dory/mesa/lib/libGL.so.1
  gallium=/stage/opt/dory/mesa/lib/libgallium-${DORY_MESA_VERSION}.so
  gl_loader_dynamic="$(x86_64-linux-gnu-readelf -d --wide "$gl_loader")"
  gallium_dynamic="$(x86_64-linux-gnu-readelf -d --wide "$gallium")"
  for dynamic_section in "$driver_dynamic" "$gl_loader_dynamic" "$gallium_dynamic"; do
    if printf "%s\n" "$dynamic_section" | grep -Eq "\((RPATH|RUNPATH)\)"; then
      echo "PC VirGL2 runtime unexpectedly carries an ambient loader search path" >&2
      exit 1
    fi
  done
  runtime_dyn_symbols="$(
    for runtime_elf in "$driver" "$gl_loader" "$gallium"; do
      x86_64-linux-gnu-readelf --dyn-syms --wide "$runtime_elf"
    done
  )"
  max_glibc_symbol="$(printf "%s\n" "$runtime_dyn_symbols" \
    | sed -n \
        -e "s/.*@\(GLIBC_[0-9][0-9.]*\).*/\1/p" \
        -e "s/.*@@\(GLIBC_[0-9][0-9.]*\).*/\1/p" \
        -e "s/.*\[\(GLIBC_[0-9][0-9.]*\)\].*/\1/p" \
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
  driver_needed_sonames="$(printf "%s\n" "$driver_dynamic" \
    | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
    | LC_ALL=C sort | paste -sd, -)"
  gl_loader_needed_sonames="$(printf "%s\n" "$gl_loader_dynamic" \
    | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
    | LC_ALL=C sort | paste -sd, -)"
  gallium_needed_sonames="$(printf "%s\n" "$gallium_dynamic" \
    | sed -n "s/.*Shared library: \[\([^]]*\)\].*/\1/p" \
    | LC_ALL=C sort | paste -sd, -)"
  build_packages="$(dpkg-query -W -f="\${binary:Package}=\${Version}\n" \
    | LC_ALL=C sort | sha256sum | cut -d " " -f 1)"
  printf "schema=2\nprofile=pc-virgl2\narchitecture=x86_64\nlibc_family=%s\nmax_glibc_symbol=%s\ngallium_driver=virgl\ndri_driver=virtio_gpu_dri.so\ngl_loader=libGL.so.1\ngallium_library=libgallium-%s.so\nrequired_guest_ld_library_path=/opt/dory/mesa/lib\nrequired_guest_libgl_drivers_path=/opt/dory/mesa/lib/dri\ndriver_needed_sonames=%s\ngl_loader_needed_sonames=%s\ngallium_needed_sonames=%s\nbuild_packages_sha256=%s\nmesa_version=%s\nmesa_source_commit=%s\nmesa_source_tree=%s\nmesa_source_date_epoch=%s\nbuilder_snapshot=%s\n" \
    "$DORY_MESA_RUNTIME_LIBC_FAMILY" "$max_glibc_symbol" \
    "$DORY_MESA_VERSION" "$driver_needed_sonames" \
    "$gl_loader_needed_sonames" "$gallium_needed_sonames" \
    "$build_packages" "$DORY_MESA_VERSION" \
    "$DORY_MESA_SOURCE_COMMIT" "$DORY_MESA_SOURCE_TREE" \
    "$SOURCE_DATE_EPOCH" "$DORY_MESA_DEBIAN_SNAPSHOT" \
    > /stage/opt/dory/mesa/share/dory/runtime.env
  dpkg-query -W -f="\${binary:Package}=\${Version}\n" | LC_ALL=C sort \
    > /stage/opt/dory/mesa/share/dory/build-packages.txt
  find /stage/opt/dory/mesa -type d -exec chmod 0755 {} +
  find /stage/opt/dory/mesa -type f -exec chmod go-w {} +
  if find /stage/opt/dory/mesa -type l -print -quit | grep -q .; then
    echo "runtime pack unexpectedly contains a symlink" >&2
    exit 1
  fi

  mkdir -p /out
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C /stage -cf - . | zstd -19 -T"$DORY_MESA_BUILD_JOBS" \
      -o /out/dory-mesa-virgl2-x86_64.tar.zst
'

docker_cmd cp "$CID:/out/dory-mesa-virgl2-x86_64.tar.zst" "$STAGING/"
chmod 0644 "$STAGING/dory-mesa-virgl2-x86_64.tar.zst"

TEMP_STAMP="$STAGING/dory-mesa-virgl2-build-x86_64.stamp"
{
  printf 'schema=2\narch=x86_64\nprofile=pc-virgl2\ninput_sha256=%s\n' "$INPUT_SHA256"
  printf 'runtime_sha256=%s\n' \
    "$(shasum -a 256 "$STAGING/dory-mesa-virgl2-x86_64.tar.zst" | awk '{print $1}')"
  printf 'mesa_version=%s\nmesa_source_commit=%s\nmesa_source_tree=%s\nmesa_source_date_epoch=%s\n' \
    "$MESA_VERSION" "$MESA_SOURCE_COMMIT" "$MESA_SOURCE_TREE" "$MESA_SOURCE_DATE_EPOCH"
  printf 'libc_family=%s\nglibc_symbol_ceiling=%s\n' \
    "$MESA_RUNTIME_LIBC_FAMILY" "$MESA_RUNTIME_MAX_GLIBC_SYMBOL"
} > "$TEMP_STAMP"

DORY_MESA_OUT_DIR="$STAGING" guest/mesa/verify-pc-virgl2-build.sh x86_64 \
  >"$STAGING/verify-pc-virgl2-build.log" 2>&1 || {
    cat "$STAGING/verify-pc-virgl2-build.log" >&2
    exit 1
  }
docker_cmd rm -f "$CID" >/dev/null
CID=""
mv -f "$STAGING/dory-mesa-virgl2-x86_64.tar.zst" "$RUNTIME"
mv -f "$TEMP_STAMP" "$STAMP"
rm -f "$STAGING/verify-pc-virgl2-build.log"
rmdir "$STAGING"
STAGING=""
trap - EXIT

guest/mesa/verify-pc-virgl2-build.sh x86_64
echo "built $RUNTIME"
