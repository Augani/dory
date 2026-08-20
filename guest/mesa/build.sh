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
  -e DORY_MESA_VERSION="$MESA_VERSION" \
  -e DORY_MESA_SOURCE_URL="$MESA_SOURCE_URL" \
  -e DORY_MESA_SOURCE_SHA256="$MESA_SOURCE_SHA256" \
  -e DORY_MESON_VERSION="$MESON_VERSION" \
  -e DORY_MESON_WHEEL_SHA256="$MESON_WHEEL_SHA256" \
  -w /build "$MESA_BUILDER_IMAGE" sleep infinity)"
docker_cmd start "$CID" >/dev/null
docker_cmd cp guest/mesa/patches/0001-venus-enable-dory-implicit-fencing-wsi.patch \
  "$CID:/tmp/dory-venus-implicit-fencing.patch"
docker_cmd cp guest/mesa/dory-vulkan-probe.c "$CID:/tmp/dory-vulkan-probe.c"

docker_cmd exec "$CID" bash -euo pipefail -c '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential bison ca-certificates curl flex libdrm-dev libexpat1-dev \
    libvulkan-dev libwayland-dev libx11-xcb-dev libxcb-dri3-dev \
    libxcb-keysyms1-dev libxcb-present-dev libxcb-randr0-dev libxcb-shm0-dev \
    libxcb-sync-dev libxcb-xfixes0-dev libxrandr-dev libxshmfence-dev \
    libzstd-dev ninja-build patch pkg-config python3-mako python3-packaging \
    python3-pip python3-ply python3-yaml wayland-protocols xz-utils zlib1g-dev zstd

  source_archive="/build/mesa-${DORY_MESA_VERSION}.tar.xz"
  curl --fail --location --retry 5 --output "$source_archive" "$DORY_MESA_SOURCE_URL"
  printf "%s  %s\n" "$DORY_MESA_SOURCE_SHA256" "$source_archive" | sha256sum -c -
  tar -xf "$source_archive" -C /build
  source_dir="/build/mesa-${DORY_MESA_VERSION}"
  patch -d "$source_dir" -p1 < /tmp/dory-venus-implicit-fencing.patch

  python3 -m pip download --disable-pip-version-check --no-deps \
    --dest /build "meson==${DORY_MESON_VERSION}" >/dev/null
  meson_wheel="$(find /build -maxdepth 1 -type f -name "meson-${DORY_MESON_VERSION}-*.whl" -print -quit)"
  [ -n "$meson_wheel" ]
  printf "%s  %s\n" "$DORY_MESON_WHEEL_SHA256" "$meson_wheel" | sha256sum -c -
  python3 -m pip install --break-system-packages --disable-pip-version-check \
    --no-index "$meson_wheel" >/dev/null

  meson setup /build/mesa-build "$source_dir" \
    --prefix=/opt/dory/mesa \
    --libdir=lib \
    --buildtype=release \
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
    -Dbuild-tests=false
  ninja -C /build/mesa-build
  DESTDIR=/stage ninja -C /build/mesa-build install

  install -d -m0755 /stage/usr/lib/dory /stage/opt/dory/mesa/share/dory
  cc -O2 -Wall -Wextra -Werror /tmp/dory-vulkan-probe.c \
    -o /stage/usr/lib/dory/dory-vulkan-probe -lvulkan
  install -m0644 /usr/lib/aarch64-linux-gnu/libxcb-keysyms.so.1.0.0 \
    /stage/opt/dory/mesa/lib/libxcb-keysyms.so.1.0.0
  ln -s libxcb-keysyms.so.1.0.0 /stage/opt/dory/mesa/lib/libxcb-keysyms.so.1
  xcb_version="$(dpkg-query -W -f="\${Version}" libxcb-keysyms1)"
  printf "schema=1\nmesa_version=%s\nmesa_source_sha256=%s\nxcb_keysyms_version=%s\n" \
    "$DORY_MESA_VERSION" "$DORY_MESA_SOURCE_SHA256" "$xcb_version" \
    > /stage/opt/dory/mesa/share/dory/runtime.env

  mkdir -p /out
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C /stage -cf - . | zstd -19 -T0 -o /out/dory-mesa-venus-arm64.tar.zst
'

docker_cmd cp "$CID:/out/dory-mesa-venus-arm64.tar.zst" "$STAGING/"
docker_cmd rm -f "$CID" >/dev/null
CID=""
chmod 0644 "$STAGING/dory-mesa-venus-arm64.tar.zst"

TEMP_STAMP="$STAGING/dory-mesa-venus-build-arm64.stamp"
{
  printf 'schema=1\narch=arm64\ninput_sha256=%s\n' "$INPUT_SHA256"
  printf 'runtime_sha256=%s\n' \
    "$(shasum -a 256 "$STAGING/dory-mesa-venus-arm64.tar.zst" | awk '{print $1}')"
  printf 'mesa_version=%s\nmesa_source_sha256=%s\n' "$MESA_VERSION" "$MESA_SOURCE_SHA256"
} > "$TEMP_STAMP"

DORY_MESA_OUT_DIR="$STAGING" guest/mesa/verify-build.sh arm64
mv -f "$STAGING/dory-mesa-venus-arm64.tar.zst" "$RUNTIME"
mv -f "$TEMP_STAMP" "$STAMP"
rmdir "$STAGING"
STAGING=""
trap - EXIT

guest/mesa/verify-build.sh arm64
echo "built $RUNTIME"
