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
FREE_SPACE_MB="${DORY_DESKTOP_FREE_SPACE_MB:-$DESKTOP_FREE_SPACE_MB}"
case "$IMAGE_SIZE_MB" in
  ''|*[!0-9]*) echo "DORY_DESKTOP_IMAGE_SIZE_MB must be an integer" >&2; exit 64 ;;
esac
[ "$IMAGE_SIZE_MB" -ge 4096 ] || { echo "desktop build image must be at least 4096 MB" >&2; exit 64; }
case "$FREE_SPACE_MB" in
  ''|*[!0-9]*) echo "DORY_DESKTOP_FREE_SPACE_MB must be an integer" >&2; exit 64 ;;
esac
[ "$FREE_SPACE_MB" -ge 1024 ] || { echo "desktop image must retain at least 1024 MB free" >&2; exit 64; }

DOCKER_BIN="${DORY_DESKTOP_DOCKER_BIN:-$(command -v docker || true)}"
[ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || { echo "docker CLI not found" >&2; exit 1; }
DOCKER_ENDPOINT="$(dory_kernel_resolve_docker_endpoint "$DOCKER_BIN" "${DORY_DESKTOP_DOCKER_HOST:-}")"
docker_cmd() {
  dory_kernel_docker "$DOCKER_BIN" "$DOCKER_ENDPOINT" "$@"
}
ZSTD_BIN="${DORY_ZSTD:-$(command -v zstd || true)}"
[ -n "$ZSTD_BIN" ] && [ -x "$ZSTD_BIN" ] || { echo "zstd is required" >&2; exit 1; }

guest/mesa/build.sh arm64
VENUS_RUNTIME="$OUT/dory-mesa-venus-arm64.tar.zst"
guest/mesa/verify-build.sh arm64

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

COMMON_PACKAGES="systemd-sysv,dbus,dbus-user-session,dconf-cli,udev,kmod,network-manager,openssh-server,sudo,ca-certificates,curl,git,vim-tiny,less,man-db,bash-completion,binutils,xserver-xorg-core,xserver-xorg-input-libinput,x11-xserver-utils,x11-utils,xterm,libgl1-mesa-dri,libxcb-keysyms1,mesa-vulkan-drivers,mesa-utils,vulkan-tools,spice-vdagent,wl-clipboard,xclip,pipewire-audio,wireplumber,polkitd,pkexec,fonts-dejavu-core,fonts-noto-core,locales,util-linux,e2fsprogs,iproute2,iputils-ping,dnsutils,netcat-openbsd,procps,rsync,tar,gzip,xz-utils,zstd,fuse3,gvfs,gvfs-backends,binfmt-support"
XFCE_PACKAGES="xfce4,xfce4-terminal,xfce4-notifyd,xfce4-power-manager,lightdm,lightdm-gtk-greeter,mate-polkit,mousepad,ristretto,file-roller"
case "$DISTRO" in
  debian) PACKAGES="$COMMON_PACKAGES,$XFCE_PACKAGES,network-manager-gnome,desktop-base,firefox-esr,evince,galculator" ;;
  ubuntu)
    # Ubuntu is intentionally its real Canonical GNOME session, not an Ubuntu rootfs wearing
    # Dory's shared Xfce profile. Hardware-only recommendations (printing, Bluetooth, firmware,
    # laptop sensors) stay out of the VM, while the normal shell, dock, settings, files, themes,
    # utilities are explicit so the image is complete offline. Firefox is installed below from
    # Mozilla's signed ARM64 APT repository; Ubuntu's `firefox` package is only a Snap transition,
    # and WebKitGTK saturated the software-rendered desktop during real browser use.
    PACKAGES="$COMMON_PACKAGES,ubuntu-minimal,ubuntu-desktop-minimal,network-manager-gnome,appstream,baobab,eog,evince,file-roller,fonts-liberation,fonts-noto-color-emoji,fonts-ubuntu,gnome-calculator,gnome-characters,gnome-clocks,gnome-disk-utility,gnome-keyring,gnome-system-monitor,gnome-terminal,gnome-text-editor,gsettings-ubuntu-schemas,gvfs-fuse,libglib2.0-bin,libnss-mdns,libpam-gnome-keyring,nautilus-sendto,network-manager-config-connectivity-ubuntu,packagekit,policykit-desktop-privileges,seahorse,ubuntu-wallpapers,xcursor-themes,xdg-desktop-portal-gnome,xdg-utils,yaru-theme-gnome-shell,yaru-theme-gtk,yaru-theme-icon,yaru-theme-sound"
    ;;
  kali) PACKAGES="$COMMON_PACKAGES,$XFCE_PACKAGES,network-manager-applet,nm-connection-editor,kali-desktop-xfce,kali-defaults,kali-menu" ;;
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
  -e DORY_DESKTOP_FREE_SPACE_MB="$FREE_SPACE_MB" \
  -e DORY_MOZILLA_APT_KEY_FINGERPRINT="$MOZILLA_APT_KEY_FINGERPRINT" \
  -e DORY_MOZILLA_APT_KEY_SHA256="$MOZILLA_APT_KEY_SHA256" \
  -w /build \
  "$BUILDER_IMAGE" bash -euc '
    find /etc/apt -type f \( -name "*.list" -o -name "*.sources" \) \
      -exec sed -i "s|http://|https://|g" {} +
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
      # The pinned minimal builder may not contain a CA bundle yet. APT still verifies signed
      # repository metadata while ca-certificates is bootstrapped over the encrypted connection.
      apt-get -o Acquire::Retries=5 -o Acquire::https::Verify-Peer=false update
      apt-get -o Acquire::Retries=5 -o Acquire::https::Verify-Peer=false install -y \
        --no-install-recommends ca-certificates
    fi
    apt-get -o Acquire::Retries=5 update
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      ca-certificates e2fsprogs gnupg mmdebstrap zstd

    mmdebstrap \
      --mode=root \
      --variant=minbase \
      --architectures=arm64 \
      --components="$DORY_DESKTOP_COMPONENTS" \
      --include="$DORY_DESKTOP_PACKAGES" \
      --aptopt="Acquire::Retries 5" \
      --aptopt="Acquire::Check-Valid-Until false" \
      --aptopt="APT::Install-Recommends false" \
      "$DORY_DESKTOP_SUITE" /rootfs "$DORY_DESKTOP_MIRROR"

    cp -a --no-preserve=ownership /tmp/rootfs-overlay/. /rootfs/
    # Git records only the executable bit, so a tracked NetworkManager profile arrives as 0644.
    # NetworkManager requires system connection profiles to be root-private, and the image must
    # establish that boundary before mke2fs captures the tree.
    chmod 0600 \
      /rootfs/etc/NetworkManager/system-connections/dory-wired.nmconnection
    /tmp/install-graphics-pack.sh /tmp/dory-mesa-venus-arm64.tar.zst /rootfs 0
    install -m0755 /tmp/dory-agent /rootfs/usr/bin/dory-agent
    chmod 0755 /rootfs/usr/lib/dory/clipboard /rootfs/usr/lib/dory/configure-machine /rootfs/usr/lib/dory/first-boot \
      /rootfs/usr/lib/dory/start-agent /rootfs/usr/lib/dory/wait-host-configuration \
      /rootfs/usr/lib/dory/configure-display /rootfs/usr/lib/dory/configure-zram \
      /rootfs/usr/lib/dory/configure-graphics-backend \
      /rootfs/usr/lib/dory/preflight-graphics-pack \
      /rootfs/usr/lib/dory/resolve-graphics-backend \
      /rootfs/usr/lib/dory/configure-intel-translation

    if [ "$DORY_DESKTOP_DISTRO" = ubuntu ]; then
      key=/rootfs/etc/apt/keyrings/packages.mozilla.org.asc
      actual_sha256="$(sha256sum "$key")"
      actual_sha256="${actual_sha256%% *}"
      [ "$actual_sha256" = "$DORY_MOZILLA_APT_KEY_SHA256" ] || {
        echo "Mozilla APT key digest mismatch" >&2
        exit 1
      }
      actual_fingerprint="$(gpg --show-keys --with-colons --fingerprint "$key" 2>/dev/null \
        | sed -n "s/^fpr:::::::::\\([^:]*\\):$/\\1/p" | head -1)"
      [ "$actual_fingerprint" = "$DORY_MOZILLA_APT_KEY_FINGERPRINT" ] || {
        echo "Mozilla APT key fingerprint mismatch" >&2
        exit 1
      }
      chroot /rootfs apt-get -o Acquire::Retries=5 update
      chroot /rootfs apt-get -o Acquire::Retries=5 install -y --no-install-recommends firefox
      # The ubuntu-desktop vendor favorite points at the Snap-only desktop ID. Dory deliberately
      # installs the signed Mozilla APT package, whose launcher is firefox.desktop.
      sed -i "s/firefox_firefox\.desktop/firefox.desktop/g" \
        /rootfs/usr/share/glib-2.0/schemas/10_ubuntu-settings.gschema.override
      chroot /rootfs glib-compile-schemas /usr/share/glib-2.0/schemas
    fi

    printf "dory\n" > /rootfs/etc/hostname
    cat > /rootfs/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 dory
::1 localhost ip6-localhost ip6-loopback
EOF
    printf "en_US.UTF-8 UTF-8\n" > /rootfs/etc/locale.gen
    chroot /rootfs locale-gen
    printf "LANG=en_US.UTF-8\n" > /rootfs/etc/default/locale
    # The rootfs is assembled inside Docker, whose generated resolv.conf points at the build
    # engine. At runtime the desktop VM receives different DHCP details, so NetworkManager must
    # own the guest resolver file instead of inheriting the build-container nameserver.
    rm -f /rootfs/etc/resolv.conf
    ln -s ../run/NetworkManager/resolv.conf /rootfs/etc/resolv.conf

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
    chmod 0644 /rootfs/etc/polkit-1/rules.d/49-dory-passwordless-admin.rules
    # The managed account has no password and is entered through display-manager autologin.
    # Compile the system dconf policy that prevents GNOME from creating an impossible-to-unlock
    # password prompt after the session has been idle.
    chroot /rootfs dconf update

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
URIs: https://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        ;;
      kali)
        cat > /rootfs/etc/apt/sources.list <<EOF
deb https://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF
        ;;
    esac

    chroot /rootfs systemctl enable NetworkManager.service NetworkManager-wait-online.service
    case "$DORY_DESKTOP_DISTRO" in
      ubuntu)
        rm -rf /rootfs/etc/lightdm
        chroot /rootfs systemctl enable gdm3.service
        ;;
      *)
        rm -rf /rootfs/etc/gdm3
        chroot /rootfs systemctl enable lightdm.service
        ;;
    esac
    chroot /rootfs systemctl enable ssh.service dory-first-boot.service \
      dory-boot.service dory-desktop-ready.service dory-zram.service \
      dory-graphics-backend.service dory-intel-translation.service
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
    extra_blocks="$((DORY_DESKTOP_FREE_SPACE_MB * 1024 * 1024 / block_size))"
    final_blocks="$((block_count + extra_blocks))"
    resize2fs "$image" "$final_blocks"
    truncate -s "$((final_blocks * block_size))" "$image"
    zstd -19 -T0 -f "$image" -o "$image.zst"
  ')"

docker_cmd cp "$AGENT" "$CID:/tmp/dory-agent"
docker_cmd cp guest/desktop/rootfs-overlay "$CID:/tmp/rootfs-overlay"
docker_cmd cp "$VENUS_RUNTIME" "$CID:/tmp/dory-mesa-venus-arm64.tar.zst"
docker_cmd cp guest/desktop/install-graphics-pack.sh "$CID:/tmp/install-graphics-pack.sh"
docker_cmd start -a "$CID"
docker_cmd cp "$CID:/out/$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" "$STAGING/"
docker_cmd cp "$CID:/out/$ARTIFACT_PREFIX-packages-arm64.txt" "$STAGING/"
docker_cmd rm "$CID" >/dev/null
CID=""
python3 guest/desktop/build-update-bundle.py \
  --distro "$DISTRO" \
  --fingerprint "$INPUT_FINGERPRINT" \
  --packages "$STAGING/$ARTIFACT_PREFIX-packages-arm64.txt" \
  --overlay guest/desktop/rootfs-overlay \
  --agent "$AGENT" \
  --venus-runtime "$VENUS_RUNTIME" \
  --graphics-installer guest/desktop/install-graphics-pack.sh \
  --apply guest/desktop/apply-update.sh \
  --output "$STAGING/$ARTIFACT_PREFIX-update-arm64.tar"
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
  printf 'update_sha256=%s\n' "$(shasum -a 256 "$STAGING/$ARTIFACT_PREFIX-update-arm64.tar" | awk '{print $1}')"
} > "$STAMP"

DORY_DESKTOP_OUT_DIR="$STAGING" guest/desktop/verify-build.sh arm64 "$DISTRO"
for artifact in \
  "$ARTIFACT_PREFIX-rootfs-arm64.ext4" \
  "$ARTIFACT_PREFIX-rootfs-arm64.ext4.zst" \
  "$ARTIFACT_PREFIX-packages-arm64.txt" \
  "$ARTIFACT_PREFIX-update-arm64.tar"; do
  mv -f "$STAGING/$artifact" "$OUT/$artifact"
done
mv -f "$STAMP" "$OUT/$ARTIFACT_PREFIX-build-arm64.stamp"
rmdir "$STAGING"
STAGING=""
trap - EXIT

guest/desktop/verify-build.sh arm64 "$DISTRO"
echo "built $OUT/$ARTIFACT_PREFIX-rootfs-arm64.ext4"
