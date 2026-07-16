#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/desktop/PINS
source guest/kernel/docker-endpoint.sh

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the desktop image currently supports arm64 only" >&2; exit 64 ;;
esac
DISTRO="${2:-debian}"
case "$DISTRO" in
  debian)
    BUILDER_IMAGE="$DEBIAN_BUILDER_IMAGE"
    SUITE="$DEBIAN_SUITE"
    MIRROR="$DEBIAN_SNAPSHOT_URL"
    COMPONENTS="main"
    ;;
  ubuntu)
    BUILDER_IMAGE="$UBUNTU_BUILDER_IMAGE"
    SUITE="$UBUNTU_SUITE"
    MIRROR="$UBUNTU_MIRROR"
    COMPONENTS="main,universe,restricted,multiverse"
    ;;
  kali)
    BUILDER_IMAGE="$KALI_BUILDER_IMAGE"
    SUITE="$KALI_SUITE"
    MIRROR="$KALI_MIRROR"
    COMPONENTS="main,contrib,non-free,non-free-firmware"
    ;;
  *) echo "unsupported desktop distribution: $DISTRO" >&2; exit 64 ;;
esac
ARTIFACT_PREFIX="dory-desktop-$DISTRO"

OUT="$ROOT/guest/out"
mkdir -p "$OUT"
IMAGE_SIZE_MB="${DORY_DESKTOP_IMAGE_SIZE_MB:-$DESKTOP_IMAGE_SIZE_MB}"
case "$IMAGE_SIZE_MB" in
  ''|*[!0-9]*) echo "DORY_DESKTOP_IMAGE_SIZE_MB must be an integer" >&2; exit 64 ;;
esac
[ "$IMAGE_SIZE_MB" -ge 4096 ] || { echo "desktop build image must be at least 4096 MB" >&2; exit 64; }

DOCKER_BIN="${DORY_DESKTOP_DOCKER_BIN:-$(command -v docker || true)}"
[ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || { echo "docker CLI not found" >&2; exit 1; }
DOCKER_ENDPOINT="$(dory_kernel_resolve_docker_endpoint "$DOCKER_BIN" "${DORY_DESKTOP_DOCKER_HOST:-}")"
docker_cmd() {
  dory_kernel_docker "$DOCKER_BIN" "$DOCKER_ENDPOINT" "$@"
}
ZSTD_BIN="${DORY_ZSTD:-$(command -v zstd || true)}"
[ -n "$ZSTD_BIN" ] && [ -x "$ZSTD_BIN" ] || { echo "zstd is required" >&2; exit 1; }

TARGET=aarch64-unknown-linux-musl
if command -v rust-lld >/dev/null 2>&1; then
  LINKER="$(command -v rust-lld)"
elif [ -n "${DORY_AARCH64_LINUX_MUSL_CC:-}" ] && command -v "$DORY_AARCH64_LINUX_MUSL_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$DORY_AARCH64_LINUX_MUSL_CC")"
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
  LINKER="$(command -v aarch64-linux-musl-gcc)"
else
  echo "no linker found for $TARGET; install rust-lld or an aarch64 musl cross compiler" >&2
  exit 1
fi
LINKER_ENV=CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
RUSTFLAGS_EFFECTIVE="${RUSTFLAGS:-}"
if [ "$(basename "$LINKER")" = rust-lld ]; then
  RUSTFLAGS_EFFECTIVE="$RUSTFLAGS_EFFECTIVE -C linker-flavor=ld.lld"
fi

STAGING="$(mktemp -d "$OUT/.desktop-build-arm64.XXXXXX")"
CID=""
cleanup() {
  [ -z "$CID" ] || docker_cmd rm -f "$CID" >/dev/null 2>&1 || true
  rm -rf "$STAGING"
}
trap cleanup EXIT

INPUT_FINGERPRINT="$(guest/desktop/input-fingerprint.sh arm64 "$DISTRO")"
rustup target add "$TARGET" >/dev/null
( cd dory-core && env "$LINKER_ENV=$LINKER" RUSTFLAGS="$RUSTFLAGS_EFFECTIVE" \
    cargo build --locked -p dory-agent --release --target "$TARGET" )
AGENT="$ROOT/dory-core/target/$TARGET/release/dory-agent"
[ -x "$AGENT" ] || { echo "dory-agent was not produced for $TARGET" >&2; exit 1; }

COMMON_PACKAGES="systemd-sysv,dbus,dbus-user-session,udev,kmod,network-manager,network-manager-gnome,openssh-server,sudo,ca-certificates,curl,git,vim-tiny,less,man-db,bash-completion,xfce4,xfce4-terminal,xfce4-notifyd,xfce4-power-manager,lightdm,lightdm-gtk-greeter,xserver-xorg-core,xserver-xorg-input-libinput,x11-xserver-utils,xterm,libgl1-mesa-dri,mesa-utils,spice-vdagent,pipewire-audio,wireplumber,polkitd,pkexec,mate-polkit,fonts-dejavu-core,fonts-noto-core,locales,util-linux,e2fsprogs,iproute2,iputils-ping,dnsutils,netcat-openbsd,procps,rsync,tar,gzip,xz-utils,zstd,fuse3,gvfs,gvfs-backends,mousepad,ristretto,file-roller"
case "$DISTRO" in
  debian) PACKAGES="$COMMON_PACKAGES,desktop-base" ;;
  ubuntu) PACKAGES="$COMMON_PACKAGES,ubuntu-minimal,xubuntu-default-settings" ;;
  kali) PACKAGES="$COMMON_PACKAGES,kali-desktop-xfce,kali-defaults,kali-menu" ;;
esac

# systemd's package scripts need proc/sys mounts while the rootfs is assembled.
# The builder is disposable and every base image is pinned above.
CID="$(docker_cmd create --privileged --platform linux/arm64 \
  -e DEBIAN_FRONTEND=noninteractive \
  -e DORY_DESKTOP_DISTRO="$DISTRO" \
  -e DORY_DESKTOP_SUITE="$SUITE" \
  -e DORY_DESKTOP_MIRROR="$MIRROR" \
  -e DORY_DESKTOP_COMPONENTS="$COMPONENTS" \
  -e DORY_DESKTOP_ARTIFACT_PREFIX="$ARTIFACT_PREFIX" \
  -e DORY_DESKTOP_PACKAGES="$PACKAGES" \
  -e DORY_DESKTOP_IMAGE_SIZE_MB="$IMAGE_SIZE_MB" \
  -w /build \
  "$BUILDER_IMAGE" bash -euc '
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates e2fsprogs mmdebstrap zstd

    mmdebstrap \
      --mode=root \
      --variant=minbase \
      --architectures=arm64 \
      --components="$DORY_DESKTOP_COMPONENTS" \
      --include="$DORY_DESKTOP_PACKAGES" \
      --aptopt="Acquire::Check-Valid-Until false" \
      --aptopt="APT::Install-Recommends false" \
      "$DORY_DESKTOP_SUITE" /rootfs "$DORY_DESKTOP_MIRROR"

    cp -a --no-preserve=ownership /tmp/rootfs-overlay/. /rootfs/
    install -m0755 /tmp/dory-agent /rootfs/usr/bin/dory-agent
    chmod 0755 /rootfs/usr/lib/dory/configure-machine /rootfs/usr/lib/dory/first-boot \
      /rootfs/usr/lib/dory/start-agent /rootfs/usr/lib/dory/wait-host-configuration \
      /rootfs/usr/lib/dory/configure-display

    printf "dory\n" > /rootfs/etc/hostname
    cat > /rootfs/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 dory
::1 localhost ip6-localhost ip6-loopback
EOF
    printf "en_US.UTF-8 UTF-8\n" > /rootfs/etc/locale.gen
    chroot /rootfs locale-gen
    printf "LANG=en_US.UTF-8\n" > /rootfs/etc/default/locale

    for group in sudo audio video render input; do
      chroot /rootfs getent group "$group" >/dev/null || chroot /rootfs groupadd "$group"
    done
    chroot /rootfs useradd --no-create-home --shell /bin/bash --groups sudo,audio,video,render,input dory
    chroot /rootfs install -d -m0700 -o dory -g dory /home/dory
    cp -a /rootfs/etc/skel/. /rootfs/home/dory/
    chroot /rootfs chown -R dory:dory /home/dory
    chroot /rootfs passwd --lock dory
    printf "dory ALL=(ALL:ALL) NOPASSWD: ALL\n" > /rootfs/etc/sudoers.d/dory
    chmod 0440 /rootfs/etc/sudoers.d/dory

    rm -f /rootfs/etc/apt/sources.list /rootfs/etc/apt/sources.list.d/*.list \
      /rootfs/etc/apt/sources.list.d/*.sources
    case "$DORY_DESKTOP_DISTRO" in
      debian)
        cat > /rootfs/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        ;;
      ubuntu)
        cat > /rootfs/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        ;;
      kali)
        cat > /rootfs/etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF
        ;;
    esac

    chroot /rootfs systemctl enable NetworkManager.service NetworkManager-wait-online.service
    chroot /rootfs systemctl enable lightdm.service ssh.service dory-first-boot.service \
      dory-boot.service dory-desktop-ready.service
    chroot /rootfs systemctl set-default graphical.target

    rm -f /rootfs/etc/machine-id /rootfs/var/lib/dbus/machine-id /rootfs/etc/ssh/ssh_host_*
    : > /rootfs/etc/machine-id
    rm -f /rootfs/var/lib/systemd/random-seed
    rm -rf /rootfs/var/lib/apt/lists/* /rootfs/var/cache/apt/archives/*.deb /rootfs/tmp/*
    mkdir -p /rootfs/var/lib/dory /out
    chroot /rootfs dpkg-query -W -f="\${binary:Package}\t\${Version}\n" | LC_ALL=C sort \
      > "/out/${DORY_DESKTOP_ARTIFACT_PREFIX}-packages-arm64.txt"

    image="/out/${DORY_DESKTOP_ARTIFACT_PREFIX}-rootfs-arm64.ext4"
    truncate -s "${DORY_DESKTOP_IMAGE_SIZE_MB}M" "$image"
    mke2fs -q -F -t ext4 -L "dory-${DORY_DESKTOP_DISTRO}" -U random -d /rootfs "$image"
    e2fsck -fy "$image"
    resize2fs -M "$image"
    block_count="$(dumpe2fs -h "$image" 2>/dev/null | awk "/^Block count:/{print \$3}")"
    block_size="$(dumpe2fs -h "$image" 2>/dev/null | awk "/^Block size:/{print \$3}")"
    extra_blocks="$((512 * 1024 * 1024 / block_size))"
    final_blocks="$((block_count + extra_blocks))"
    resize2fs "$image" "$final_blocks"
    truncate -s "$((final_blocks * block_size))" "$image"
    zstd -19 -T0 -f "$image" -o "$image.zst"
  ')"

docker_cmd cp "$AGENT" "$CID:/tmp/dory-agent"
docker_cmd cp guest/desktop/rootfs-overlay "$CID:/tmp/rootfs-overlay"
docker_cmd start -a "$CID"
docker_cmd cp "$CID:/out/$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" "$STAGING/"
docker_cmd cp "$CID:/out/$ARTIFACT_PREFIX-packages-arm64.txt" "$STAGING/"
docker_cmd rm "$CID" >/dev/null
CID=""
"$ZSTD_BIN" -q -d --sparse -f "$STAGING/$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" \
  -o "$STAGING/$ARTIFACT_PREFIX-rootfs-arm64.ext4"

FINAL_FINGERPRINT="$(guest/desktop/input-fingerprint.sh arm64 "$DISTRO")"
[ "$FINAL_FINGERPRINT" = "$INPUT_FINGERPRINT" ] || {
  echo "desktop inputs changed while the image was building" >&2
  exit 1
}
STAMP="$STAGING/$ARTIFACT_PREFIX-build-arm64.stamp"
{
  printf 'schema=2\narch=arm64\ndistro=%s\ninput_sha256=%s\n' "$DISTRO" "$INPUT_FINGERPRINT"
  printf 'image_sha256=%s\n' "$(shasum -a 256 "$STAGING/$ARTIFACT_PREFIX-rootfs-arm64.ext4" | awk '{print $1}')"
  printf 'compressed_sha256=%s\n' "$(shasum -a 256 "$STAGING/$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" | awk '{print $1}')"
  printf 'packages_sha256=%s\n' "$(shasum -a 256 "$STAGING/$ARTIFACT_PREFIX-packages-arm64.txt" | awk '{print $1}')"
} > "$STAMP"

DORY_DESKTOP_OUT_DIR="$STAGING" guest/desktop/verify-build.sh arm64 "$DISTRO"
for artifact in \
  "$ARTIFACT_PREFIX-rootfs-arm64.ext4" \
  "$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" \
  "$ARTIFACT_PREFIX-packages-arm64.txt"; do
  mv -f "$STAGING/$artifact" "$OUT/$artifact"
done
mv -f "$STAMP" "$OUT/$ARTIFACT_PREFIX-build-arm64.stamp"
rmdir "$STAGING"
STAGING=""
trap - EXIT

guest/desktop/verify-build.sh arm64 "$DISTRO"
echo "built $OUT/$ARTIFACT_PREFIX-rootfs-arm64.ext4"
