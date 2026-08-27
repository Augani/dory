#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/desktop/PINS
source guest/mesa/PINS

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the desktop image currently supports arm64 only" >&2; exit 64 ;;
esac
DISTRO="${2:-debian}"
case "$DISTRO" in
  debian|ubuntu|kali) ;;
  *) echo "unsupported desktop distribution: $DISTRO" >&2; exit 64 ;;
esac
ARTIFACT_PREFIX="dory-desktop-$DISTRO"

OUT="${DORY_DESKTOP_OUT_DIR:-$ROOT/guest/out}"
IMAGE="$OUT/$ARTIFACT_PREFIX-rootfs-arm64.ext4"
COMPRESSED="$IMAGE.zst"
PACKAGES="$OUT/$ARTIFACT_PREFIX-packages-arm64.txt"
UPDATE="$OUT/$ARTIFACT_PREFIX-update-arm64.tar"
STAMP="$OUT/$ARTIFACT_PREFIX-build-arm64.stamp"
VENUS_RUNTIME="$ROOT/guest/out/dory-mesa-venus-arm64.tar.zst"

fail() {
  echo "desktop image verification failed: $*" >&2
  exit 1
}

for path in "$IMAGE" "$COMPRESSED" "$PACKAGES" "$UPDATE" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path"
done

stamp_value() {
  sed -n "s/^$1=//p" "$STAMP"
}

require_arm64_package() {
  local package="$1"
  local failure="$2"
  awk -v expected="$package" \
    '$1 == expected || $1 == expected ":arm64" { found = 1 } END { exit !found }' \
    "$PACKAGES" || fail "$failure"
}

[ "$(stamp_value schema)" = 2 ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = arm64 ] || fail "$STAMP was built for another architecture"
[ "$(stamp_value distro)" = "$DISTRO" ] || fail "$STAMP was built for another distribution"
EXPECTED_INPUT="$(guest/desktop/input-fingerprint.sh arm64 "$DISTRO")"
[ "$(stamp_value input_sha256)" = "$EXPECTED_INPUT" ] || fail "$IMAGE is stale"
[ "$(stamp_value image_sha256)" = "$(shasum -a 256 "$IMAGE" | awk '{print $1}')" ] \
  || fail "$IMAGE digest does not match its stamp"
[ "$(stamp_value compressed_sha256)" = "$(shasum -a 256 "$COMPRESSED" | awk '{print $1}')" ] \
  || fail "$COMPRESSED digest does not match its stamp"
[ "$(stamp_value packages_sha256)" = "$(shasum -a 256 "$PACKAGES" | awk '{print $1}')" ] \
  || fail "$PACKAGES digest does not match its stamp"
[ "$(stamp_value update_sha256)" = "$(shasum -a 256 "$UPDATE" | awk '{print $1}')" ] \
  || fail "$UPDATE digest does not match its stamp"

UPDATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dory-desktop-update-verify.XXXXXX")"
trap 'rm -rf "$UPDATE_DIR"' EXIT
tar -xf "$UPDATE" -C "$UPDATE_DIR"
guest/mesa/verify-build.sh arm64 >/dev/null
for path in apply.sh dory-agent dory-mesa-venus-arm64.tar.zst install-graphics-pack.sh manifest.env packages.txt rootfs-overlay.tar SHA256SUMS; do
  [ -s "$UPDATE_DIR/$path" ] || fail "$UPDATE is missing $path"
done
(cd "$UPDATE_DIR" && shasum -a 256 -c SHA256SUMS) \
  || fail "$UPDATE payload digests do not match"
grep -Fqx 'schema=2' "$UPDATE_DIR/manifest.env" || fail "$UPDATE has an unsupported schema"
grep -Fqx 'arch=arm64' "$UPDATE_DIR/manifest.env" || fail "$UPDATE has the wrong architecture"
grep -Fqx "distro=$DISTRO" "$UPDATE_DIR/manifest.env" || fail "$UPDATE has the wrong distribution"
grep -Fqx "input_sha256=$EXPECTED_INPUT" "$UPDATE_DIR/manifest.env" \
  || fail "$UPDATE has a stale input fingerprint"
cmp -s "$PACKAGES" "$UPDATE_DIR/packages.txt" || fail "$UPDATE package manifest is stale"
cmp -s "$VENUS_RUNTIME" "$UPDATE_DIR/dory-mesa-venus-arm64.tar.zst" \
  || fail "$UPDATE contains a stale Dory Venus runtime"
grep -Fq 'packages.txt is the signed package provenance' "$UPDATE_DIR/apply.sh" \
  || fail "$UPDATE does not keep package provenance separate from guest-tools installation"
grep -Fq 'dory-mesa-venus-arm64.tar.zst' "$UPDATE_DIR/apply.sh" \
  || fail "$UPDATE does not install the Dory Venus runtime"
grep -Fq 'install-graphics-pack.sh' "$UPDATE_DIR/apply.sh" \
  || fail "$UPDATE does not replace the Dory graphics pack transactionally"
cmp -s guest/desktop/install-graphics-pack.sh "$UPDATE_DIR/install-graphics-pack.sh" \
  || fail "$UPDATE contains a stale graphics-pack installer"
grep -Fq 'dconf update' "$UPDATE_DIR/apply.sh" \
  || fail "$UPDATE does not compile the managed desktop session policy"
if grep -Eq 'apt-get|with-new-pkgs|xargs .*install' "$UPDATE_DIR/apply.sh"; then
  fail "$UPDATE performs a network-dependent distribution package mutation"
fi

DEBUGFS="${DORY_DEBUGFS:-}"
if [ -z "$DEBUGFS" ]; then
  for candidate in \
    "$(command -v debugfs 2>/dev/null || true)" \
    /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
    /usr/local/opt/e2fsprogs/sbin/debugfs; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      DEBUGFS="$candidate"
      break
    fi
  done
fi
[ -n "$DEBUGFS" ] || fail "debugfs is required"

for guest_path in \
  /sbin/init \
  /usr/bin/dory-agent \
  /usr/lib/dory/clipboard \
  /usr/lib/dory/configure-machine \
  /usr/lib/dory/configure-display \
  /usr/lib/dory/configure-graphics-backend \
  /usr/lib/dory/preflight-graphics-pack \
  /usr/lib/dory/resolve-graphics-backend \
  /usr/lib/aarch64-linux-gnu/dri/virtio_gpu_dri.so \
  /opt/dory/mesa/libexec/dory-vulkan-compositor-probe \
  /opt/dory/mesa/libexec/dory-vulkan-probe \
  /usr/lib/dory/configure-zram \
  /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent \
  /usr/lib/dory/wait-host-configuration \
  /etc/systemd/system/dory-first-boot.service \
  /etc/systemd/system/dory-boot.service \
  /etc/systemd/system/dory-desktop-ready.service \
  /etc/systemd/system/dory-graphics-backend.service \
  /etc/systemd/system/display-manager.service.d/10-dory-graphics.conf \
  /etc/systemd/system/dory-zram.service \
  /etc/NetworkManager/conf.d/10-dory.conf \
  /etc/NetworkManager/conf.d/10-globally-managed-devices.conf \
  /etc/NetworkManager/system-connections/dory-wired.nmconnection \
  /etc/dconf/profile/user \
  /etc/dconf/db/dory.d/00-managed-session \
  /etc/dconf/db/dory.d/locks/00-managed-session \
  /etc/dconf/db/dory \
  /etc/polkit-1/rules.d/49-dory-passwordless-admin.rules \
  /etc/wireplumber/main.lua.d/60-dory-virtio-sound.lua \
  /etc/xdg/autostart/dory-display.desktop \
  /home/dory/.profile \
  /usr/bin/spice-vdagent \
  /usr/bin/pipewire; do
  "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
    || fail "$IMAGE is missing $guest_path"
done

for guest_path in \
  /opt/dory/mesa/lib/libvulkan_virtio.so \
  /opt/dory/mesa/libexec/dory-vulkan-compositor-probe \
  /opt/dory/mesa/libexec/dory-vulkan-probe \
  /opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json \
  /opt/dory/mesa/share/dory/runtime.env \
  /opt/dory/mesa/share/dory/build-packages.txt; do
  "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
    || fail "$IMAGE is missing $guest_path"
done

VENUS_ICD="$($DEBUGFS -R \
  'cat /opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json' "$IMAGE" 2>/dev/null)"
grep -Fq '"library_path": "../../../lib/libvulkan_virtio.so"' <<<"$VENUS_ICD" \
  || fail "the desktop image Venus ICD is not relocatable within its signed pack"
VENUS_MANIFEST="$($DEBUGFS -R \
  'cat /opt/dory/mesa/share/dory/runtime.env' "$IMAGE" 2>/dev/null)"
grep -Fqx "mesa_version=$MESA_VERSION" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Mesa Venus version"
grep -Fqx 'schema=6' <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Venus ABI schema"
grep -Fqx "architecture=$MESA_RUNTIME_ARCH" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Venus architecture"
grep -Fqx "libc_family=$MESA_RUNTIME_LIBC_FAMILY" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Venus libc family"
grep -Fqx "vulkan_api=$MESA_RUNTIME_VULKAN_API" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan API contract"
grep -Fqx "vulkan13_features=$MESA_RUNTIME_VULKAN13_FEATURES" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan 1.3 feature contract"
grep -Fqx "vulkan_device_extensions=$MESA_RUNTIME_VULKAN_DEVICE_EXTENSIONS" \
  <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan device-extension contract"
grep -Fqx "vulkan_instance_extensions=$MESA_RUNTIME_VULKAN_INSTANCE_EXTENSIONS" \
  <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan instance-extension contract"
grep -Fqx "wsi_surface_gate=$MESA_RUNTIME_WSI_SURFACE_GATE" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan native-surface contract"
grep -Fqx "compositor_profile=$MESA_RUNTIME_COMPOSITOR_PROFILE" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan compositor profile"
grep -Fqx "compositor_profile_source_commit=$WLROOTS_VULKAN_PROFILE_SOURCE_COMMIT" \
  <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan compositor-profile commit"
grep -Fqx "compositor_profile_source_tree=$WLROOTS_VULKAN_PROFILE_SOURCE_TREE" \
  <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains the wrong Vulkan compositor-profile tree"
VENUS_MAX_GLIBC_SYMBOL="$(sed -n 's/^max_glibc_symbol=//p' <<<"$VENUS_MANIFEST")"
grep -Eq '^GLIBC_[0-9]+(\.[0-9]+)+$' <<<"$VENUS_MAX_GLIBC_SYMBOL" \
  || fail "the desktop image contains an invalid Venus GNU-libc floor"
[ "$(printf '%s\n%s\n' "$VENUS_MAX_GLIBC_SYMBOL" "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" \
    | LC_ALL=C sort -Vu | tail -n 1)" = "$MESA_RUNTIME_MAX_GLIBC_SYMBOL" ] \
  || fail "the desktop image Venus GNU-libc floor exceeds the admitted ceiling"
grep -Fqx "mesa_source_commit=$MESA_SOURCE_COMMIT" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains an unpinned Mesa source commit"
grep -Fqx "mesa_source_tree=$MESA_SOURCE_TREE" <<<"$VENUS_MANIFEST" \
  || fail "the desktop image contains an unpinned Mesa source tree"
grep -Fq 'icd_needed_sonames=' <<<"$VENUS_MANIFEST" \
  || fail "the desktop image Venus ABI does not declare its ICD DSO closure"
grep -Fq 'probe_needed_sonames=' <<<"$VENUS_MANIFEST" \
  || fail "the desktop image Venus ABI does not declare its probe DSO closure"
grep -Fq 'compositor_probe_needed_sonames=' <<<"$VENUS_MANIFEST" \
  || fail "the desktop image Venus ABI does not declare its compositor-probe DSO closure"
grep -Fqx 'libdrm_linkage=static-hidden' <<<"$VENUS_MANIFEST" \
  || fail "the desktop image Venus ABI does not isolate libdrm"

CLIPBOARD_HELPER="$($DEBUGFS -R 'cat /usr/lib/dory/clipboard' "$IMAGE" 2>/dev/null)"
grep -Fq 'wl-copy --type "$mime"' <<<"$CLIPBOARD_HELPER" \
  || fail "clipboard helper does not provide Wayland writes"
grep -Fq 'xclip -selection clipboard -out' <<<"$CLIPBOARD_HELPER" \
  || fail "clipboard helper does not provide X11 reads"

WIREPLUMBER_SOUND_RULE="$($DEBUGFS -R \
  'cat /etc/wireplumber/main.lua.d/60-dory-virtio-sound.lua' "$IMAGE" 2>/dev/null)"
grep -Fq '["device.profile"] = "pro-audio"' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber does not activate Dory's virtio sound profile"
grep -Fq '{ "device.vendor.id", "matches", "0x1af4" }' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber sound policy is not scoped to the virtio vendor"
grep -Fq '{ "device.product.id", "matches", "0x1059" }' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber sound policy is not scoped to virtio-snd"
grep -Fq 'alsa_output.platform-*' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber does not configure Dory playback"
grep -Fq 'alsa_input.platform-*' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber does not configure Dory capture"
[ "$(grep -Fc '["node.pause-on-idle"] = true' <<<"$WIREPLUMBER_SOUND_RULE")" -eq 2 ] \
  || fail "WirePlumber does not suspend both idle Dory audio directions"
grep -Fq '["node.group"] = "dory-playback"' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber does not isolate Dory playback lifecycle"
grep -Fq '["node.group"] = "dory-capture"' <<<"$WIREPLUMBER_SOUND_RULE" \
  || fail "WirePlumber does not isolate Dory capture lifecycle"
[ "$(grep -Fc '["audio.position"] = "FL,FR"' <<<"$WIREPLUMBER_SOUND_RULE")" -eq 2 ] \
  || fail "WirePlumber does not expose conventional stereo channel positions"
[ "$(grep -Fc '["priority.session"] = 2500' <<<"$WIREPLUMBER_SOUND_RULE")" -eq 2 ] \
  || fail "WirePlumber does not prioritize both real Dory audio directions"

DESKTOP_COMPATIBILITY_ENV="$($DEBUGFS -R \
  'cat /etc/environment.d/60-dory-desktop.conf' "$IMAGE" 2>/dev/null)"
grep -Fqx 'MOZ_ENABLE_WAYLAND=0' <<<"$DESKTOP_COMPATIBILITY_ENV" \
  || fail "Firefox is not pinned to the qualified XWayland presentation path"
BROWSER_POLICY="$($DEBUGFS -R \
  'cat /usr/lib/firefox/distribution/policies.json' "$IMAGE" 2>/dev/null)"
grep -Fq '"gfx.webrender.software"' <<<"$BROWSER_POLICY" \
  || fail "Firefox does not select its qualified software WebRender path"
grep -Fq '"widget.dmabuf.enabled"' <<<"$BROWSER_POLICY" \
  || fail "Firefox does not disable the unqualified DMA-BUF presentation path"

for user_owned_path in /home/dory /home/dory/.profile; do
  "$DEBUGFS" -R "stat $user_owned_path" "$IMAGE" 2>/dev/null \
    | grep -Eq 'User:[[:space:]]+1000[[:space:]]+Group:[[:space:]]+1000' \
    || fail "$user_owned_path is not owned by the dory user in $IMAGE"
done

for root_owned_path in \
  /usr/lib/dory/configure-machine \
  /usr/lib/dory/configure-display \
  /usr/lib/dory/configure-graphics-backend \
  /usr/lib/dory/preflight-graphics-pack \
  /usr/lib/dory/resolve-graphics-backend \
  /usr/lib/dory/configure-zram \
  /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent \
  /usr/lib/dory/wait-host-configuration \
  /etc/systemd/system/dory-boot.service \
  /etc/systemd/system/dory-desktop-ready.service \
  /etc/systemd/system/dory-graphics-backend.service \
  /etc/systemd/system/display-manager.service.d/10-dory-graphics.conf \
  /etc/systemd/system/dory-zram.service; do
  "$DEBUGFS" -R "stat $root_owned_path" "$IMAGE" 2>/dev/null \
    | grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' \
    || fail "$root_owned_path is not owned by root in $IMAGE"
done

DISPLAY_GRAPHICS_ORDER="$($DEBUGFS -R \
  'cat /etc/systemd/system/display-manager.service.d/10-dory-graphics.conf' "$IMAGE" 2>/dev/null)"
grep -Fq 'Wants=dory-graphics-backend.service' <<<"$DISPLAY_GRAPHICS_ORDER" \
  || fail "the display manager does not order the optional graphics activation"
if grep -Fq 'Requires=dory-graphics-backend.service' <<<"$DISPLAY_GRAPHICS_ORDER"; then
  fail "optional graphics activation can still prevent the display manager from starting"
fi

# /etc/os-release is normally a relative symlink. debugfs does not follow it,
# so read the canonical file directly when verifying the offline image.
OS_RELEASE="$($DEBUGFS -R 'cat /usr/lib/os-release' "$IMAGE" 2>/dev/null | tr -d '\r')"
case "$DISTRO" in
  debian)
    grep -Fqx 'ID=debian' <<<"$OS_RELEASE" || fail "$IMAGE is not Debian"
    DEBIAN_VERSION="$($DEBUGFS -R 'cat /etc/debian_version' "$IMAGE" 2>/dev/null | tr -d '\r\n')"
    case "$DEBIAN_VERSION" in 13.*) ;; *) fail "$IMAGE contains unexpected Debian version $DEBIAN_VERSION" ;; esac
    for guest_path in \
      /etc/lightdm/lightdm.conf.d/50-dory.conf \
      /usr/bin/startxfce4 \
      /usr/bin/firefox-esr \
      /usr/bin/evince \
      /usr/bin/galculator; do
      "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
        || fail "$IMAGE is missing $guest_path"
    done
    ;;
  ubuntu)
    grep -Fqx 'ID=ubuntu' <<<"$OS_RELEASE" || fail "$IMAGE is not Ubuntu"
    grep -Fqx 'VERSION_ID="24.04"' <<<"$OS_RELEASE" || fail "$IMAGE is not Ubuntu 24.04 LTS"
    "$DEBUGFS" -R 'cat /etc/apt/sources.list.d/ubuntu.sources' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'URIs: https://ports.ubuntu.com/ubuntu-ports' \
      || fail "$IMAGE does not use the official Ubuntu HTTPS repository"
    for guest_path in \
      /etc/gdm3/custom.conf \
      /usr/bin/gnome-shell \
      /usr/bin/gnome-terminal \
      /usr/bin/firefox \
      /usr/share/xsessions/ubuntu.desktop; do
      "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
        || fail "$IMAGE is missing $guest_path"
    done
    ;;
  kali)
    grep -Fqx 'ID=kali' <<<"$OS_RELEASE" || fail "$IMAGE is not Kali Linux"
    for guest_path in /etc/lightdm/lightdm.conf.d/50-dory.conf /usr/bin/startxfce4; do
      "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
        || fail "$IMAGE is missing $guest_path"
    done
    "$DEBUGFS" -R 'stat /home/dory/.config/xfce4/panel' "$IMAGE" 2>&1 \
      | grep -Fq 'Inode:' || fail "$IMAGE is missing the Kali Xfce user defaults"
    "$DEBUGFS" -R 'cat /etc/apt/sources.list' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'deb https://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware' \
      || fail "$IMAGE does not use the official Kali rolling repository"
    ;;
esac
"$DEBUGFS" -R 'cat /etc/ssh/sshd_config.d/50-dory.conf' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'PasswordAuthentication no' || fail "SSH password login is not disabled"
case "$DISTRO" in
  ubuntu)
    "$DEBUGFS" -R 'cat /etc/gdm3/custom.conf' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'AutomaticLogin=dory' || fail "Ubuntu GNOME autologin is not configured"
    "$DEBUGFS" -R 'cat /etc/gdm3/custom.conf' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'WaylandEnable=false' \
      || fail "Ubuntu GNOME does not select the qualified Xorg compatibility cell"
    "$DEBUGFS" -R 'cat /etc/gdm3/custom.conf' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'DefaultSession=ubuntu-xorg.desktop' \
      || fail "Ubuntu GNOME does not default to the qualified Xorg session"
    DCONF_SESSION="$($DEBUGFS -R \
      'cat /etc/dconf/db/dory.d/00-managed-session' "$IMAGE" 2>/dev/null)"
    grep -Fqx 'lock-enabled=false' <<<"$DCONF_SESSION" \
      || fail "Ubuntu GNOME can lock its passwordless managed account"
    grep -Fqx 'idle-delay=uint32 0' <<<"$DCONF_SESSION" \
      || fail "Ubuntu GNOME can idle into an impossible password prompt"
    DCONF_LOCKS="$($DEBUGFS -R \
      'cat /etc/dconf/db/dory.d/locks/00-managed-session' "$IMAGE" 2>/dev/null)"
    grep -Fqx '/org/gnome/desktop/screensaver/lock-enabled' <<<"$DCONF_LOCKS" \
      || fail "Ubuntu GNOME screen-lock policy is not immutable"
    ;;
  *)
    "$DEBUGFS" -R 'cat /etc/lightdm/lightdm.conf.d/50-dory.conf' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'autologin-user=dory' || fail "Xfce autologin is not configured"
    ;;
esac
"$DEBUGFS" -R 'cat /etc/NetworkManager/conf.d/10-globally-managed-devices.conf' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'unmanaged-devices=' || fail "virtio Ethernet is not opted into NetworkManager"
"$DEBUGFS" -R 'cat /etc/NetworkManager/system-connections/dory-wired.nmconnection' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'type=ethernet' || fail "the Dory wired connection is not an Ethernet profile"
if "$DEBUGFS" -R 'cat /etc/NetworkManager/system-connections/dory-wired.nmconnection' "$IMAGE" 2>/dev/null \
  | grep -q '^interface-name='; then
  fail "the Dory wired connection is pinned to a distro-specific interface name"
fi
"$DEBUGFS" -R 'stat /etc/NetworkManager/system-connections/dory-wired.nmconnection' "$IMAGE" 2>/dev/null \
  | grep -Eq 'Mode:[[:space:]]+0600' || fail "the Dory wired connection is not private"
"$DEBUGFS" -R 'cat /etc/NetworkManager/conf.d/10-dory.conf' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'rc-manager=file' || fail "NetworkManager does not own the guest resolver file"
RESOLV_LINK="$($DEBUGFS -R 'stat /etc/resolv.conf' "$IMAGE" 2>/dev/null \
  | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p')"
[ "$RESOLV_LINK" = '../run/NetworkManager/resolv.conf' ] \
  || fail "resolv.conf does not follow NetworkManager: $RESOLV_LINK"
DISPLAY_CONFIGURATION="$($DEBUGFS -R 'cat /usr/lib/dory/configure-display' "$IMAGE" 2>/dev/null)"
grep -Fq 'xrandr --output "$output_name" --mode "$preferred_mode"' <<<"$DISPLAY_CONFIGURATION" \
  || fail "dynamic desktop resizing is not configured"
case "$DISTRO" in
  ubuntu)
    grep -Fq 'gsettings set org.gnome.desktop.interface scaling-factor "$scale"' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME Retina scaling is not configured"
    grep -Fq '/run/dory/graphics-backend' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME does not select effects based on the active graphics backend"
    grep -Fq 'gsettings set org.gnome.desktop.interface enable-animations true' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME accelerated animations are not configured"
    grep -Fq 'gsettings set org.gnome.desktop.interface enable-animations false' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME software-rendering fallback mode is not configured"
    grep -Fq 'xdg-settings set default-web-browser firefox.desktop' <<<"$DISPLAY_CONFIGURATION" \
      || fail "Firefox is not configured as the default Ubuntu browser"
    grep -Fq 'firefox_firefox.desktop/firefox.desktop' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME does not repair Ubuntu's stale Snap Firefox favorite"
    grep -Fq 'gnome-control-center.desktop/org.gnome.Settings.desktop' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME does not repair Ubuntu's stale Settings favorite"
    grep -Fq 'org.gnome.Settings.desktop' <<<"$DISPLAY_CONFIGURATION" \
      || fail "GNOME does not install Ubuntu's real Settings favorite"
    UBUNTU_SCHEMA_OVERRIDE="$($DEBUGFS -R \
      'cat /usr/share/glib-2.0/schemas/10_ubuntu-settings.gschema.override' \
      "$IMAGE" 2>/dev/null)"
    grep -Fq "'firefox.desktop'" <<<"$UBUNTU_SCHEMA_OVERRIDE" \
      || fail "Ubuntu's dock default does not point at the installed Firefox launcher"
    if grep -Fq 'firefox_firefox.desktop' <<<"$UBUNTU_SCHEMA_OVERRIDE"; then
      fail "Ubuntu's dock default still points at the absent Firefox Snap launcher"
    fi
    for package in ubuntu-desktop-minimal ubuntu-session gdm3 firefox yaru-theme-gtk; do
      require_arm64_package "$package" "$package provenance is missing"
    done
    "$DEBUGFS" -R 'cat /etc/apt/keyrings/packages.mozilla.org.asc' "$IMAGE" 2>/dev/null \
      | shasum -a 256 | grep -Fq "$MOZILLA_APT_KEY_SHA256" \
      || fail "the Mozilla APT key is not the pinned key"
    if grep -Eq '^(xfce4|lightdm)[[:space:]]' "$PACKAGES"; then
      fail "the Ubuntu image still contains the retired Xfce/LightDM session"
    fi
    ;;
  *)
    grep -Fq 'apply_xfce_scale "$(guest_ui_scale)"' <<<"$DISPLAY_CONFIGURATION" \
      || fail "Xfce Retina scaling is not configured"
    require_arm64_package xfce4 "Xfce package provenance is missing"
    require_arm64_package lightdm "LightDM package provenance is missing"
    if [ "$DISTRO" = debian ]; then
      for package in firefox-esr evince galculator; do
        require_arm64_package "$package" "$package provenance is missing"
      done
    fi
    ;;
esac
grep -Fq '/var/lib/dory/guest-ui-scale' <<<"$DISPLAY_CONFIGURATION" \
  || fail "the resolved guest UI scale is not consumed"
grep -Fq 'apply_xfce_scale "$scale"' <<<"$DISPLAY_CONFIGURATION" \
  || fail "Xfce does not refresh the resolved guest UI scale"
require_arm64_package spice-vdagent "SPICE package provenance is missing"
require_arm64_package libgl1-mesa-dri \
  "the distro Mesa VirGL DRI package provenance is missing"
require_arm64_package libxcb-keysyms1 "the isolated Venus ICD runtime dependency is missing"
require_arm64_package x11-utils "X11 window qualification tools are missing"
require_arm64_package wl-clipboard "Wayland clipboard package provenance is missing"
require_arm64_package xclip "X11 clipboard package provenance is missing"
require_arm64_package pipewire-audio "PipeWire package provenance is missing"
require_arm64_package binfmt-support \
  "Intel application translation registration support is missing"
for package in mesa-vulkan-drivers vulkan-tools; do
  require_arm64_package "$package" "$package provenance is missing"
done

INTEL_TRANSLATION_CONFIGURATION="$($DEBUGFS -R \
  'cat /usr/lib/dory/configure-intel-translation' "$IMAGE" 2>/dev/null)"
grep -Fq 'mount -t virtiofs -o ro rosetta "$mountpoint"' \
  <<<"$INTEL_TRANSLATION_CONFIGURATION" \
  || fail "Intel application translation does not mount the resolved Rosetta share"
grep -Fq '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
  <<<"$INTEL_TRANSLATION_CONFIGURATION" \
  || fail "Intel application translation has the wrong x86_64 ELF signature"
grep -Fq -- '--credentials yes --preserve yes --fix-binary yes' \
  <<<"$INTEL_TRANSLATION_CONFIGURATION" \
  || fail "Intel application translation registration is incomplete"

GRAPHICS_CONFIGURATION="$($DEBUGFS -R 'cat /usr/lib/dory/configure-graphics-backend' "$IMAGE" 2>/dev/null)"
GRAPHICS_PREFLIGHT="$($DEBUGFS -R 'cat /usr/lib/dory/preflight-graphics-pack' "$IMAGE" 2>/dev/null)"
GRAPHICS_RESOLVER="$($DEBUGFS -R 'cat /usr/lib/dory/resolve-graphics-backend' "$IMAGE" 2>/dev/null)"
PREFLIGHT_EXPECTED_MANIFEST_KEYS="$(
  sed -n "/^expected_manifest_keys='/,/^actual_manifest_keys=/p" \
    <<<"$GRAPHICS_PREFLIGHT" \
    | sed '/^actual_manifest_keys=/d' \
    | sed "1s/^expected_manifest_keys='//; \$s/'\$//"
)"
VENUS_MANIFEST_KEYS="$(
  sed -n 's/^\([^=]*\)=.*$/\1/p' <<<"$VENUS_MANIFEST" | LC_ALL=C sort
)"
[ "$PREFLIGHT_EXPECTED_MANIFEST_KEYS" = "$VENUS_MANIFEST_KEYS" ] \
  || fail "Venus preflight manifest whitelist differs from the shipped graphics pack"
grep -Fq "dory.graphics=virgl-venus" <<<"$GRAPHICS_RESOLVER" \
  || fail "graphics backend configuration does not recognize VirGL plus Venus"
grep -Fq "dory.graphics=virgl" <<<"$GRAPHICS_RESOLVER" \
  || fail "graphics backend configuration does not recognize stable VirGL"
grep -Fq "dory.graphics=software" <<<"$GRAPHICS_RESOLVER" \
  || fail "graphics backend configuration does not recognize software fallback"
grep -Fq 'backend_resolver=/usr/lib/dory/resolve-graphics-backend' \
  <<<"$GRAPHICS_CONFIGURATION" \
  || fail "graphics activation bypasses the authoritative backend resolver"
grep -Fq 'requested_file=/run/dory/graphics-requested-backend' \
  <<<"$GRAPHICS_CONFIGURATION" \
  || fail "graphics activation does not preserve the requested backend"
grep -Fq 'effective_file=/run/dory/graphics-backend' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "graphics activation does not keep requested and effective state separate"
grep -Fq 'mv -f "$effective_temp" "$effective_file"' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "graphics activation does not publish its effective backend transactionally"
grep -Fq 'VK_DRIVER_FILES=$venus_icd' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "Venus applications do not select Dory's isolated Vulkan ICD"
grep -Fq 'VK_ICD_FILENAMES=$venus_icd' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "older compatible Vulkan loaders do not select Dory's isolated ICD"
grep -Fq '"$venus_preflight" 2>&1' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "Venus is enabled without the ABI/DSO/render-node preflight"
grep -Fq 'timeout 10 "$probe"' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus is enabled without a bounded hardware capability probe"
grep -Fq 'graphics pack file inventory differs from schema 6' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not enforce the exact graphics-pack inventory"
grep -Fq 'getconf GNU_LIBC_VERSION' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not enforce the GNU-libc ABI floor"
grep -Fq 'readelf --dynamic --wide' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not validate exact ELF dynamic tags"
grep -Fq 'LD_BIND_NOW=1 ldd -r "$elf_object"' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not eagerly resolve the declared DSO closure"
grep -Fq '[ "$(manifest_value schema)" = 6 ]' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not require the current graphics-pack schema"
grep -Fq '[ "$(manifest_value libdrm_linkage)" = static-hidden ]' \
  <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not enforce isolated static libdrm linkage"
grep -Fq 'virtio_gpu' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not bind the virtio-gpu render node"
grep -Fq '"$render_device"/virtio*/driver' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not resolve virtio-gpu through raw-HV virtio-mmio"
grep -Fq 'VK_ICD_FILENAMES="$icd_manifest"' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight cannot qualify older admitted Vulkan loaders"
for proof in contract=vulkan-1.3-application hardware-device=yes robust-buffer-access=yes \
  dynamic-rendering=yes synchronization2=yes maintenance4=yes \
  color-atlas-texture-binding=yes color-atlas-copy-dst=yes \
  external-sync-fd=yes import-signaled-fd=yes export-sync-fd=yes \
  queue-submit2=yes fence-signal=yes \
  wsi-instance=xcb,wayland wsi-surface=not-requested; do
  grep -Fq "$proof" <<<"$GRAPHICS_PREFLIGHT" \
    || fail "Venus preflight does not require probe evidence $proof"
done
grep -Fq 'color-atlas-format=(bgra8|rgba8)-unorm' <<<"$GRAPHICS_PREFLIGHT" \
  || fail "Venus preflight does not require an exact color-atlas format"
grep -Fq 'venus-ready:' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "Venus readiness is not recorded for support diagnostics"
grep -Fq '/etc/X11/Xsession.d/70dory-graphics' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "desktop sessions do not receive the qualified graphics environment"
grep -Fq 'export VK_DRIVER_FILES=$venus_icd' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "GDM and LightDM sessions do not select Dory's Venus ICD"
grep -Fq 'export VK_ICD_FILENAMES=$venus_icd' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "desktop sessions do not select Venus on older admitted Vulkan loaders"
grep -Fq "'GSK_RENDERER=gl'" <<<"$GRAPHICS_CONFIGURATION" \
  || fail "managed GTK4 applications do not select the qualified GL renderer"
grep -Fq 'fallback=virgl2' <<<"$GRAPHICS_CONFIGURATION" \
  || fail "a failed Venus preflight cannot retain the VirGL desktop backend"
if grep -Fq 'venus_implicit_fencing' \
    <<<"$GRAPHICS_CONFIGURATION$GRAPHICS_PREFLIGHT$GRAPHICS_RESOLVER"; then
  fail "graphics activation still enables the retired racy implicit-fencing path"
fi
if grep -Fq 'ZED_ALLOW_EMULATED_GPU' <<<"$GRAPHICS_CONFIGURATION"; then
  fail "graphics configuration masks Zed's hardware-GPU requirement"
fi
if grep -Eq 'MOZ_ENABLE_WAYLAND|LD_LIBRARY_PATH|gfx\.webrender|widget\.dmabuf' \
  <<<"$GRAPHICS_CONFIGURATION"; then
  fail "graphics backend contains an unrelated browser or shared-library override"
fi
if grep -Fq 'LD_LIBRARY_PATH=' <<<"$GRAPHICS_PREFLIGHT"; then
  fail "graphics preflight injects an ambient shared-library search path"
fi
if grep -Eq 'MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER|LIBGL_KOPPER_DRI2' <<<"$GRAPHICS_CONFIGURATION"; then
  fail "graphics backend globally overrides Mesa instead of allowing API-native driver selection"
fi
if grep -Fq "grep -qw 'dory.gpu=venus' /proc/cmdline" <<<"$GRAPHICS_CONFIGURATION"; then
  fail "graphics backend still relies only on the legacy Venus token"
fi

ZSTD="${DORY_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
[ -n "$ZSTD" ] || fail "zstd is required"
"$ZSTD" -q -t "$COMPRESSED" || fail "$COMPRESSED is corrupt"

echo "verified arm64 $DISTRO desktop image input fingerprint $EXPECTED_INPUT"
