#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS
source ./docker-endpoint.sh
source ./profile.sh

ARCH="${1:-arm64}"
OUT="$(pwd)/../out"
mkdir -p "$OUT"
PROFILE="$(dory_kernel_resolve_profile)"
PROFILE_SUFFIX="$(dory_kernel_profile_suffix "$PROFILE")"
BUILD_JOBS="${DORY_KERNEL_BUILD_JOBS:-4}"
case "$BUILD_JOBS" in
  ''|*[!0-9]*|0) echo "DORY_KERNEL_BUILD_JOBS must be a positive integer" >&2; exit 64 ;;
esac
BUILD_PLATFORM=""
CROSS_COMPILE_PREFIX=""
TOOLCHAIN_PACKAGES=""

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
    BUILD_PLATFORM="linux/arm64"
    MAKE_ARCH="arm64"
    CONFIGS="dory.config dory-arm.config"
    TARGETS="Image"
    ;;
  amd64|x86_64)
    ARCH="amd64"
    BUILD_PLATFORM="linux/arm64"
    MAKE_ARCH="x86_64"
    CROSS_COMPILE_PREFIX="x86_64-linux-gnu-"
    TOOLCHAIN_PACKAGES="gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu"
    CONFIGS="dory.config dory-x86.config"
    TARGETS="vmlinux bzImage"
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac

case "$PROFILE" in
  headless) CONFIGS="$CONFIGS dory-headless.fragment" ;;
  venus) CONFIGS="$CONFIGS dory-virtual-display.fragment dory-gpu.fragment" ;;
  pc-virgl2) CONFIGS="$CONFIGS dory-virtual-display.fragment dory-pc-virgl2.fragment" ;;
  desktop) CONFIGS="$CONFIGS dory-virtual-display.fragment dory-desktop.fragment" ;;
  accelerated-desktop) CONFIGS="$CONFIGS dory-virtual-display.fragment dory-gpu.fragment dory-desktop.fragment dory-accelerated-desktop.fragment" ;;
esac
if { [ "$PROFILE" = "desktop" ] || [ "$PROFILE" = "accelerated-desktop" ]; } && [ "$ARCH" != "arm64" ]; then
  echo "desktop kernel profiles currently support arm64 only" >&2
  exit 64
fi
if [ "$PROFILE" = "pc-virgl2" ] && [ "$ARCH" != "amd64" ]; then
  echo "pc-virgl2 kernel profile currently supports amd64 only" >&2
  exit 64
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
INPUT_FINGERPRINT="$(DORY_KERNEL_PROFILE="$PROFILE" ./input-fingerprint.sh "$ARCH")"
# shellcheck disable=SC2086
CONFIG_TARB64="$(COPYFILE_DISABLE=1 tar --no-xattrs -czf - $CONFIGS "${PATCHES[@]}" | base64 | tr -d '\n')"
PATCH_LIST="${PATCHES[*]}"
FINAL_INPUT_FINGERPRINT="$(DORY_KERNEL_PROFILE="$PROFILE" ./input-fingerprint.sh "$ARCH")"
[ "$FINAL_INPUT_FINGERPRINT" = "$INPUT_FINGERPRINT" ] || {
  echo "kernel inputs changed while capturing configs/patches; refusing to build a mixed-source kernel" >&2
  exit 1
}

CID=""
STAGING=""
cleanup() {
  status=$?
  if [ "$status" -eq 0 ] || [ "${DORY_KERNEL_PRESERVE_FAILED_CANDIDATE:-1}" = 0 ]; then
    if [ -n "$CID" ]; then
      docker_cmd rm -f "$CID" >/dev/null 2>&1 || true
    fi
    if [ -n "$STAGING" ]; then
      rm -rf "$STAGING"
    fi
  else
    [ -z "$STAGING" ] || echo "preserving failed kernel candidate in $STAGING" >&2
    [ -z "$CID" ] || echo "preserving failed kernel build container $CID" >&2
  fi
}
trap cleanup EXIT

CID="$(docker_cmd create --platform "$BUILD_PLATFORM" \
  -e ARCH="$MAKE_ARCH" \
  -e CROSS_COMPILE="$CROSS_COMPILE_PREFIX" \
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
  -e DORY_KERNEL_BUILD_JOBS="$BUILD_JOBS" \
  -e DORY_KERNEL_TOOLCHAIN_PACKAGES="$TOOLCHAIN_PACKAGES" \
  -e DORY_KERNEL_DEBIAN_SNAPSHOT="$KERNEL_DEBIAN_SNAPSHOT" \
  -e DORY_KERNEL_DEBIAN_SNAPSHOT_URL="$KERNEL_DEBIAN_SNAPSHOT_URL" \
  -e DORY_KERNEL_DEBIAN_SECURITY_SNAPSHOT_URL="$KERNEL_DEBIAN_SECURITY_SNAPSHOT_URL" \
  -e DORY_KERNEL_PROFILE="$PROFILE" \
  -e DORY_KERNEL_SUFFIX="$PROFILE_SUFFIX" \
  -e DORY_KERNEL_INPUT_SHA256="$INPUT_FINGERPRINT" \
  -w /build \
  "$KERNEL_BUILDER_IMAGE" bash -euxc '
  set +x
  mkdir -p /tmp/dory-kernel-config
  printf "%s" "$DORY_KERNEL_CONFIG_TARB64" | base64 -d | tar -xzf - -C /tmp/dory-kernel-config
  set -x
  mkdir -p /out
  printf "deb [check-valid-until=no] %s bookworm main\ndeb [check-valid-until=no] %s bookworm-security main\n" \
    "$DORY_KERNEL_DEBIAN_SNAPSHOT_URL" "$DORY_KERNEL_DEBIAN_SECURITY_SNAPSHOT_URL" \
    > /etc/apt/sources.list
  find /etc/apt/sources.list.d -type f -delete 2>/dev/null || true
  apt-get -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false update
  apt-get -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl python3 patch $DORY_KERNEL_TOOLCHAIN_PACKAGES
  dpkg-query -W -f="\${binary:Package}=\${Version}\n" | LC_ALL=C sort > "/out/build-packages-$DORY_KERNEL_ARCH$DORY_KERNEL_SUFFIX.txt"
  {
    printf "builder_snapshot=%s\n" "$DORY_KERNEL_DEBIAN_SNAPSHOT"
    printf "build_platform=%s\n" "$(uname -m)"
    printf "make_arch=%s\n" "$ARCH"
    printf "cross_compile=%s\n" "$CROSS_COMPILE"
    ${CROSS_COMPILE}gcc --version | sed "s/^/cc_version=/" | head -n 1
    ${CROSS_COMPILE}ld --version | sed "s/^/ld_version=/" | head -n 1
  } > "/out/toolchain-$DORY_KERNEL_ARCH$DORY_KERNEL_SUFFIX.txt"
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  for kernel_patch in $DORY_KERNEL_PATCHES; do
    echo "Applying $kernel_patch"
    # Kernel artifacts are release inputs. Never let GNU patch silently repair a stale
    # context: an offset or fuzzy hunk could produce a bootable but unqualified kernel.
    patch --batch --forward --fuzz=0 -p1 < "/tmp/dory-kernel-config/$kernel_patch"
  done
  make defconfig
  CONFIG_PATHS=""
  for config in $DORY_KERNEL_CONFIGS; do
    CONFIG_PATHS="$CONFIG_PATHS /tmp/dory-kernel-config/$config"
  done
  scripts/kconfig/merge_config.sh -m .config $CONFIG_PATHS
  make olddefconfig
  KSUFFIX="$DORY_KERNEL_SUFFIX"
  cp .config "/out/config-$DORY_KERNEL_ARCH$KSUFFIX"
  make -j"$DORY_KERNEL_BUILD_JOBS" $DORY_KERNEL_TARGETS
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
    printf "schema=4\narch=%s\nprofile=%s\ninput_sha256=%s\n" "$DORY_KERNEL_ARCH" "$DORY_KERNEL_PROFILE" "$DORY_KERNEL_INPUT_SHA256"
    printf "builder_snapshot=%s\n" "$DORY_KERNEL_DEBIAN_SNAPSHOT"
    printf "build_packages_sha256=%s\n" "$(sha256sum "/out/build-packages-$DORY_KERNEL_ARCH$KSUFFIX.txt" | awk "{print \$1}")"
    printf "toolchain_sha256=%s\n" "$(sha256sum "/out/toolchain-$DORY_KERNEL_ARCH$KSUFFIX.txt" | awk "{print \$1}")"
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

DORY_KERNEL_PROFILE="$PROFILE" DORY_KERNEL_OUT_DIR="$STAGING" ./verify-build.sh "$ARCH"

if [ "$ARCH" = arm64 ]; then
  PUBLISH=("config-arm64$PROFILE_SUFFIX" "Image$PROFILE_SUFFIX" "Image$PROFILE_SUFFIX.zst" "build-packages-arm64$PROFILE_SUFFIX.txt" "toolchain-arm64$PROFILE_SUFFIX.txt")
  STAMP_NAME="kernel-build-arm64$PROFILE_SUFFIX.stamp"
else
  PUBLISH=("config-amd64$PROFILE_SUFFIX" "vmlinux-x86$PROFILE_SUFFIX" "vmlinux-x86$PROFILE_SUFFIX.zst" "bzImage-x86$PROFILE_SUFFIX" "build-packages-amd64$PROFILE_SUFFIX.txt" "toolchain-amd64$PROFILE_SUFFIX.txt")
  STAMP_NAME="kernel-build-amd64$PROFILE_SUFFIX.stamp"
fi
for artifact in "${PUBLISH[@]}"; do
  mv -f "$STAGING/$artifact" "$OUT/$artifact"
done
# The stamp is the commit record for the artifact set and is always the final atomic rename.
mv -f "$STAGING/$STAMP_NAME" "$OUT/$STAMP_NAME"
rmdir "$STAGING"
STAGING=""
trap - EXIT

DORY_KERNEL_PROFILE="$PROFILE" ./verify-build.sh "$ARCH"
