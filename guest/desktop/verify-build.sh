#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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
STAMP="$OUT/$ARTIFACT_PREFIX-build-arm64.stamp"

fail() {
  echo "desktop image verification failed: $*" >&2
  exit 1
}

for path in "$IMAGE" "$COMPRESSED" "$PACKAGES" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path"
done

stamp_value() {
  sed -n "s/^$1=//p" "$STAMP"
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
  /usr/lib/dory/configure-machine \
  /usr/lib/dory/configure-display \
  /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent \
  /usr/lib/dory/wait-host-configuration \
  /etc/systemd/system/dory-first-boot.service \
  /etc/systemd/system/dory-boot.service \
  /etc/systemd/system/dory-desktop-ready.service \
  /etc/lightdm/lightdm.conf.d/50-dory.conf \
  /etc/xdg/autostart/dory-display.desktop \
  /home/dory/.profile \
  /usr/bin/startxfce4 \
  /usr/bin/spice-vdagent \
  /usr/bin/pipewire; do
  "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
    || fail "$IMAGE is missing $guest_path"
done

for user_owned_path in /home/dory /home/dory/.profile; do
  "$DEBUGFS" -R "stat $user_owned_path" "$IMAGE" 2>/dev/null \
    | grep -Eq 'User:[[:space:]]+1000[[:space:]]+Group:[[:space:]]+1000' \
    || fail "$user_owned_path is not owned by the dory user in $IMAGE"
done

for root_owned_path in \
  /usr/lib/dory/configure-machine \
  /usr/lib/dory/configure-display \
  /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent \
  /usr/lib/dory/wait-host-configuration \
  /etc/systemd/system/dory-boot.service \
  /etc/systemd/system/dory-desktop-ready.service; do
  "$DEBUGFS" -R "stat $root_owned_path" "$IMAGE" 2>/dev/null \
    | grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' \
    || fail "$root_owned_path is not owned by root in $IMAGE"
done

# /etc/os-release is normally a relative symlink. debugfs does not follow it,
# so read the canonical file directly when verifying the offline image.
OS_RELEASE="$($DEBUGFS -R 'cat /usr/lib/os-release' "$IMAGE" 2>/dev/null | tr -d '\r')"
case "$DISTRO" in
  debian)
    grep -Fqx 'ID=debian' <<<"$OS_RELEASE" || fail "$IMAGE is not Debian"
    DEBIAN_VERSION="$($DEBUGFS -R 'cat /etc/debian_version' "$IMAGE" 2>/dev/null | tr -d '\r\n')"
    case "$DEBIAN_VERSION" in 13.*) ;; *) fail "$IMAGE contains unexpected Debian version $DEBIAN_VERSION" ;; esac
    ;;
  ubuntu)
    grep -Fqx 'ID=ubuntu' <<<"$OS_RELEASE" || fail "$IMAGE is not Ubuntu"
    grep -Fqx 'VERSION_ID="24.04"' <<<"$OS_RELEASE" || fail "$IMAGE is not Ubuntu 24.04 LTS"
    ;;
  kali)
    grep -Fqx 'ID=kali' <<<"$OS_RELEASE" || fail "$IMAGE is not Kali Linux"
    "$DEBUGFS" -R 'stat /home/dory/.config/xfce4/panel' "$IMAGE" 2>&1 \
      | grep -Fq 'Inode:' || fail "$IMAGE is missing the Kali Xfce user defaults"
    "$DEBUGFS" -R 'cat /etc/apt/sources.list' "$IMAGE" 2>/dev/null \
      | grep -Fqx 'deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware' \
      || fail "$IMAGE does not use the official Kali rolling repository"
    ;;
esac
"$DEBUGFS" -R 'cat /etc/ssh/sshd_config.d/50-dory.conf' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'PasswordAuthentication no' || fail "SSH password login is not disabled"
"$DEBUGFS" -R 'cat /etc/lightdm/lightdm.conf.d/50-dory.conf' "$IMAGE" 2>/dev/null \
  | grep -Fqx 'autologin-user=dory' || fail "desktop autologin is not configured"
grep -q $'^xfce4\t' "$PACKAGES" || fail "Xfce package provenance is missing"
grep -q $'^lightdm\t' "$PACKAGES" || fail "LightDM package provenance is missing"
grep -q $'^spice-vdagent\t' "$PACKAGES" || fail "SPICE package provenance is missing"
grep -q $'^pipewire-audio\t' "$PACKAGES" || fail "PipeWire package provenance is missing"

ZSTD="${DORY_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
[ -n "$ZSTD" ] || fail "zstd is required"
"$ZSTD" -q -t "$COMPRESSED" || fail "$COMPRESSED is corrupt"

echo "verified arm64 $DISTRO desktop image input fingerprint $EXPECTED_INPUT"
