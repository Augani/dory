#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64) ;;
  *) echo "the desktop image currently supports arm64 only" >&2; exit 64 ;;
esac

OUT="${DORY_DESKTOP_OUT_DIR:-$ROOT/guest/out}"
IMAGE="$OUT/dory-desktop-rootfs-arm64.ext4"
COMPRESSED="$IMAGE.zst"
PACKAGES="$OUT/dory-desktop-packages-arm64.txt"
STAMP="$OUT/dory-desktop-build-arm64.stamp"

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

[ "$(stamp_value schema)" = 1 ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = arm64 ] || fail "$STAMP was built for another architecture"
EXPECTED_INPUT="$(guest/desktop/input-fingerprint.sh arm64)"
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
  /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent \
  /etc/systemd/system/dory-first-boot.service \
  /etc/systemd/system/dory-boot.service \
  /etc/lightdm/lightdm.conf.d/50-dory.conf \
  /usr/bin/startxfce4 \
  /usr/bin/spice-vdagent \
  /usr/bin/pipewire; do
  "$DEBUGFS" -R "stat $guest_path" "$IMAGE" 2>&1 | grep -Fq 'Inode:' \
    || fail "$IMAGE is missing $guest_path"
done

DEBIAN_VERSION="$($DEBUGFS -R 'cat /etc/debian_version' "$IMAGE" 2>/dev/null | tr -d '\r\n')"
case "$DEBIAN_VERSION" in
  13.*) ;;
  *) fail "$IMAGE contains unexpected Debian version $DEBIAN_VERSION" ;;
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

echo "verified arm64 desktop image input fingerprint $EXPECTED_INPUT"
