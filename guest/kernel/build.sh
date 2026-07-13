#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS
source ./docker-endpoint.sh

ARCH="${1:-arm64}"
OUT="$(pwd)/../out"
mkdir -p "$OUT"
GPU="${DORY_EXPERIMENTAL_GPU:-0}"
case "$GPU" in
  0|1) ;;
  *) echo "DORY_EXPERIMENTAL_GPU must be 0 or 1" >&2; exit 64 ;;
esac

case "$KERNEL_SOURCE_DATE_EPOCH" in
  ''|*[!0-9]*) echo "KERNEL_SOURCE_DATE_EPOCH must be a non-negative integer" >&2; exit 64 ;;
esac
case "$KERNEL_BUILD_VERSION" in
  ''|*[!0-9]*) echo "KERNEL_BUILD_VERSION must be a non-negative integer" >&2; exit 64 ;;
esac
for build_identity in "$KERNEL_BUILD_USER" "$KERNEL_BUILD_HOST"; do
  case "$build_identity" in
    ''|*[!A-Za-z0-9._-]*)
      echo "kernel build user/host must contain only letters, digits, dot, underscore, or dash" >&2
      exit 64
      ;;
  esac
done

DOCKER_BIN="${DORY_KERNEL_DOCKER_BIN:-$(command -v docker || true)}"
[ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || {
  echo "docker CLI not found; set DORY_KERNEL_DOCKER_BIN to an executable" >&2
  exit 1
}
DOCKER_ENDPOINT="$(dory_kernel_resolve_docker_endpoint "$DOCKER_BIN" "${DORY_KERNEL_DOCKER_HOST:-}")" || {
  echo "could not resolve the selected Docker endpoint" >&2
  exit 1
}
docker_cmd() {
  dory_kernel_docker "$DOCKER_BIN" "$DOCKER_ENDPOINT" "$@"
}

case "$ARCH" in
  arm64)
    PLATFORM="linux/arm64"
    MAKE_ARCH="arm64"
    CONFIGS="dory.config dory-arm.config"
    TARGETS="Image"
    ;;
  amd64|x86_64)
    ARCH="amd64"
    PLATFORM="linux/amd64"
    MAKE_ARCH="x86_64"
    CONFIGS="dory.config dory-x86.config"
    TARGETS="vmlinux bzImage"
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac

if [ "$GPU" = "1" ]; then
  CONFIGS="$CONFIGS dory-gpu.fragment"
fi

PATCH_DIR="patches/$KERNEL_VERSION"
PATCHES=()
if [ -d "$PATCH_DIR" ]; then
  while IFS= read -r kernel_patch; do
    PATCHES+=("$kernel_patch")
  done < <(find "$PATCH_DIR" -type f -name '*.patch' | LC_ALL=C sort)
fi

# Ship configs and version-specific patches into the isolated build container together. Keeping the
# patch list explicit makes application order deterministic and makes a stale patch fail the build.
INPUT_FINGERPRINT="$(DORY_EXPERIMENTAL_GPU="$GPU" ./input-fingerprint.sh "$ARCH")"
# shellcheck disable=SC2086
CONFIG_TARB64="$(COPYFILE_DISABLE=1 tar --no-xattrs -czf - $CONFIGS "${PATCHES[@]}" | base64 | tr -d '\n')"
PATCH_LIST="${PATCHES[*]}"
FINAL_INPUT_FINGERPRINT="$(DORY_EXPERIMENTAL_GPU="$GPU" ./input-fingerprint.sh "$ARCH")"
[ "$FINAL_INPUT_FINGERPRINT" = "$INPUT_FINGERPRINT" ] || {
  echo "kernel inputs changed while capturing configs/patches; refusing to build a mixed-source kernel" >&2
  exit 1
}

CID=""
STAGING=""
cleanup() {
  if [ -n "$CID" ]; then
    docker_cmd rm -f "$CID" >/dev/null 2>&1 || true
  fi
  if [ -n "$STAGING" ]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

CID="$(docker_cmd create --platform "$PLATFORM" \
  -e ARCH="$MAKE_ARCH" \
  -e LC_ALL=C \
  -e TZ=UTC \
  -e SOURCE_DATE_EPOCH="$KERNEL_SOURCE_DATE_EPOCH" \
  -e KBUILD_BUILD_TIMESTAMP="@$KERNEL_SOURCE_DATE_EPOCH" \
  -e KBUILD_BUILD_USER="$KERNEL_BUILD_USER" \
  -e KBUILD_BUILD_HOST="$KERNEL_BUILD_HOST" \
  -e KBUILD_BUILD_VERSION="$KERNEL_BUILD_VERSION" \
  -e KCONFIG_NOTIMESTAMP=1 \
  -e ZERO_AR_DATE=1 \
  -e DORY_KERNEL_ARCH="$ARCH" \
  -e DORY_KERNEL_CONFIGS="$CONFIGS" \
  -e DORY_KERNEL_CONFIG_TARB64="$CONFIG_TARB64" \
  -e DORY_KERNEL_PATCHES="$PATCH_LIST" \
  -e DORY_KERNEL_TARGETS="$TARGETS" \
  -e DORY_KERNEL_GPU="$GPU" \
  -e DORY_KERNEL_INPUT_SHA256="$INPUT_FINGERPRINT" \
  -w /build \
  "$KERNEL_BUILDER_IMAGE" bash -euxc '
  set +x
  mkdir -p /tmp/dory-kernel-config
  printf "%s" "$DORY_KERNEL_CONFIG_TARB64" | base64 -d | tar -xzf - -C /tmp/dory-kernel-config
  set -x
  mkdir -p /out
  apt-get update
  apt-get install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl python3 patch
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  for kernel_patch in $DORY_KERNEL_PATCHES; do
    echo "Applying $kernel_patch"
    patch --batch --forward -p1 < "/tmp/dory-kernel-config/$kernel_patch"
  done
  make defconfig
  CONFIG_PATHS=""
  for config in $DORY_KERNEL_CONFIGS; do
    CONFIG_PATHS="$CONFIG_PATHS /tmp/dory-kernel-config/$config"
  done
  scripts/kconfig/merge_config.sh -m .config $CONFIG_PATHS
  make olddefconfig
  KSUFFIX=""; [ "$DORY_KERNEL_GPU" = 1 ] && KSUFFIX="-gpu"
  cp .config "/out/config-$DORY_KERNEL_ARCH$KSUFFIX"
  make -j$(nproc) $DORY_KERNEL_TARGETS
  if [ "$DORY_KERNEL_ARCH" = arm64 ]; then
    cp arch/arm64/boot/Image "/out/Image$KSUFFIX"
    zstd -19 -f "/out/Image$KSUFFIX" -o "/out/Image$KSUFFIX.zst"
    PRIMARY="/out/Image$KSUFFIX"
    COMPRESSED="/out/Image$KSUFFIX.zst"
    SECONDARY=""
    STAMP="/out/kernel-build-arm64$KSUFFIX.stamp"
  else
    cp vmlinux "/out/vmlinux-x86$KSUFFIX"
    zstd -19 -f "/out/vmlinux-x86$KSUFFIX" -o "/out/vmlinux-x86$KSUFFIX.zst"
    cp arch/x86/boot/bzImage "/out/bzImage-x86$KSUFFIX"
    PRIMARY="/out/vmlinux-x86$KSUFFIX"
    COMPRESSED="/out/vmlinux-x86$KSUFFIX.zst"
    SECONDARY="/out/bzImage-x86$KSUFFIX"
    STAMP="/out/kernel-build-amd64$KSUFFIX.stamp"
  fi
  STAMP_TMP="$STAMP.tmp"
  {
    printf "schema=2\narch=%s\ngpu=%s\ninput_sha256=%s\n" "$DORY_KERNEL_ARCH" "$DORY_KERNEL_GPU" "$DORY_KERNEL_INPUT_SHA256"
    printf "config_sha256=%s\n" "$(sha256sum "/out/config-$DORY_KERNEL_ARCH$KSUFFIX" | awk "{print \$1}")"
    printf "primary_sha256=%s\n" "$(sha256sum "$PRIMARY" | awk "{print \$1}")"
    printf "compressed_sha256=%s\n" "$(sha256sum "$COMPRESSED" | awk "{print \$1}")"
    if [ -n "$SECONDARY" ]; then
      printf "secondary_sha256=%s\n" "$(sha256sum "$SECONDARY" | awk "{print \$1}")"
    fi
  } > "$STAMP_TMP"
  mv "$STAMP_TMP" "$STAMP"
')"

docker_cmd start -a "$CID"
STAGING="$(mktemp -d "$OUT/.kernel-build-$ARCH.XXXXXX")"
docker_cmd cp "$CID:/out/." "$STAGING/"
docker_cmd rm "$CID" >/dev/null
CID=""

DORY_EXPERIMENTAL_GPU="$GPU" DORY_KERNEL_OUT_DIR="$STAGING" ./verify-build.sh "$ARCH"

GPU_SUFFIX=""
[ "$GPU" = 1 ] && GPU_SUFFIX="-gpu"
if [ "$ARCH" = arm64 ]; then
  PUBLISH=("config-arm64$GPU_SUFFIX" "Image$GPU_SUFFIX" "Image$GPU_SUFFIX.zst")
  STAMP_NAME="kernel-build-arm64$GPU_SUFFIX.stamp"
else
  PUBLISH=("config-amd64$GPU_SUFFIX" "vmlinux-x86$GPU_SUFFIX" "vmlinux-x86$GPU_SUFFIX.zst" "bzImage-x86$GPU_SUFFIX")
  STAMP_NAME="kernel-build-amd64$GPU_SUFFIX.stamp"
fi
for artifact in "${PUBLISH[@]}"; do
  mv -f "$STAGING/$artifact" "$OUT/$artifact"
done
# The stamp is the commit record for the artifact set and is always the final atomic rename.
mv -f "$STAGING/$STAMP_NAME" "$OUT/$STAMP_NAME"
rmdir "$STAGING"
STAGING=""
trap - EXIT

DORY_EXPERIMENTAL_GPU="$GPU" ./verify-build.sh "$ARCH"
