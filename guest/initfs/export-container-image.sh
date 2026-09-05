#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
usage: guest/initfs/export-container-image.sh arm64 --output <rootfs.tar> [--docker-host unix:///path.sock --tag name:tag]

Exports the verified Dory initfs as a Docker rootfs tar for Dory-supported GPU containers.
The command validates the initfs stamp before export and preserves filesystem modes and symlinks
from the ext4 image. If --docker-host and --tag are supplied, it imports the tar into only that
explicit Docker endpoint. It never reads Docker's default context.
EOF
  exit 64
}

case "${1:-}" in
  arm64|aarch64) ARCH=arm64; shift ;;
  *) usage ;;
esac

OUTPUT=""
DOCKER_HOST_VALUE=""
TAG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT="$2"
      shift 2
      ;;
    --docker-host)
      [ "$#" -ge 2 ] || usage
      DOCKER_HOST_VALUE="$2"
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || usage
      TAG="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$OUTPUT" ] || usage
if { [ -n "$DOCKER_HOST_VALUE" ] && [ -z "$TAG" ]; } || { [ -z "$DOCKER_HOST_VALUE" ] && [ -n "$TAG" ]; }; then
  echo "--docker-host and --tag must be supplied together" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "--output must be an absolute path" >&2; exit 64 ;;
esac
case "$OUTPUT" in
  *$'\n'*|*$'\r'*|*$'\t'*) echo "--output contains a control character" >&2; exit 64 ;;
esac
mkdir -p "$(dirname "$OUTPUT")"

find_debugfs() {
  local candidate
  for candidate in \
    "$(command -v debugfs 2>/dev/null || true)" \
    /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
    /usr/local/opt/e2fsprogs/sbin/debugfs; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

IMAGE="guest/out/initfs-$ARCH.ext4"
STAMP="guest/out/initfs-build-$ARCH.stamp"
IMAGE_SHA256_BEFORE="$(shasum -a 256 "$IMAGE" | awk '{print $1}')"
STAMP_CONTENTS_BEFORE="$(cat "$STAMP")"
STAMP_IMAGE_SHA256="$(
  printf '%s\n' "$STAMP_CONTENTS_BEFORE" \
    | awk -F= '$1 == "image_sha256" { print $2; exit }'
)"
[ "$IMAGE_SHA256_BEFORE" = "$STAMP_IMAGE_SHA256" ] || {
  echo "initfs image does not match its captured stamp" >&2
  exit 1
}
"$ROOT/guest/initfs/verify-build.sh" "$ARCH" >/dev/null
DEBUGFS="$(find_debugfs)" || { echo "debugfs is required to export the initfs rootfs" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dory-initfs-container-export.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"
"$DEBUGFS" -R "rdump / $ROOTFS" "$IMAGE" > "$WORK/rdump.log" 2>&1 || {
  cat "$WORK/rdump.log" >&2
  exit 1
}
awk '
  /^debugfs / { next }
  /^(rdump|dump_file): Operation not permitted while changing ownership of / { next }
  { print > "/dev/stderr"; bad = 1 }
  END { exit bad ? 1 : 0 }
' "$WORK/rdump.log" || {
  echo "debugfs reported an unexpected extraction diagnostic" >&2
  exit 1
}
find "$ROOTFS" -name '._*' -print -quit | grep -q . && {
  echo "exported rootfs unexpectedly contains AppleDouble sidecar files" >&2
  exit 1
}
for required in \
  bin/busybox \
  bin/sh \
  sbin/init \
  usr/local/bin/dockerd \
  opt/dory/mesa/lib/libvulkan_virtio.so \
  etc/vulkan/icd.d/dory-virtio_icd.aarch64.json; do
  [ -e "$ROOTFS/$required" ] || [ -L "$ROOTFS/$required" ] \
    || { echo "exported rootfs is missing $required" >&2; exit 1; }
done

[ "$(shasum -a 256 "$IMAGE" | awk '{print $1}')" = "$IMAGE_SHA256_BEFORE" ] || {
  echo "initfs image changed during export" >&2
  exit 1
}
[ "$(cat "$STAMP")" = "$STAMP_CONTENTS_BEFORE" ] || {
  echo "initfs stamp changed during export" >&2
  exit 1
}

tmp_output="$OUTPUT.tmp.$$"
rm -f "$tmp_output"
cleanup_output() { rm -f "$tmp_output"; }
trap 'cleanup_output; cleanup' EXIT INT TERM
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root \
  -C "$ROOTFS" -cf "$tmp_output" .
if tar -tf "$tmp_output" | grep -Eq '(^|/)\._'; then
  echo "container rootfs tar unexpectedly contains AppleDouble sidecar files" >&2
  rm -f "$tmp_output"
  exit 1
fi
mv -f "$tmp_output" "$OUTPUT"
trap cleanup EXIT INT TERM

INITFS_SHA256="$IMAGE_SHA256_BEFORE"
INPUT_SHA256="$(
  printf '%s\n' "$STAMP_CONTENTS_BEFORE" \
    | awk -F= '$1 == "input_sha256" { print $2; exit }'
)"

printf 'container_rootfs_tar=%s\n' "$OUTPUT"
printf 'initfs_image=%s\n' "$IMAGE"
printf 'initfs_image_sha256=%s\n' "$INITFS_SHA256"
printf 'initfs_input_sha256=%s\n' "$INPUT_SHA256"
printf 'initfs_stamp=%s\n' "$(printf '%s\n' "$STAMP_CONTENTS_BEFORE" | tr '\n' ';')"
printf 'container_vulkan_icd=/etc/vulkan/icd.d/dory-virtio_icd.aarch64.json\n'

if [ -n "$DOCKER_HOST_VALUE" ]; then
  case "$DOCKER_HOST_VALUE" in
    unix:///*) ;;
    *) echo "--docker-host must be an explicit unix:// socket" >&2; exit 64 ;;
  esac
  docker -H "$DOCKER_HOST_VALUE" import \
    --platform linux/arm64 \
    --change "LABEL org.dory.initfs.arch=$ARCH" \
    --change "LABEL org.dory.initfs.sha256=$INITFS_SHA256" \
    --change "LABEL org.dory.initfs.input-sha256=$INPUT_SHA256" \
    --change "LABEL org.dory.container-vulkan-icd=/etc/vulkan/icd.d/dory-virtio_icd.aarch64.json" \
    "$OUTPUT" "$TAG"
  printf 'imported_image=%s\n' "$TAG"
fi
