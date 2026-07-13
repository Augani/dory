#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64) ARCH=arm64 ;;
  amd64|x86_64) ARCH=amd64 ;;
  *) echo "usage: $0 [arm64|amd64]" >&2; exit 64 ;;
esac

OUT="${DORY_INITFS_OUT_DIR:-guest/out}"
AGENT="$OUT/dory-agent-$ARCH"
IMAGE="$OUT/initfs-$ARCH.ext4"
STAMP="$OUT/initfs-build-$ARCH.stamp"

fail() {
  echo "initfs verification failed: $*" >&2
  exit 1
}

stamp_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STAMP"
}

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

for path in "$AGENT" "$IMAGE" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path; rebuild with guest/initfs/build.sh $ARCH"
done

EXPECTED_INPUT="$(guest/initfs/input-fingerprint.sh "$ARCH")"
[ "$(stamp_value schema)" = "2" ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = "$ARCH" ] || fail "$STAMP was built for another architecture"
[ "$(stamp_value input_sha256)" = "$EXPECTED_INPUT" ] \
  || fail "$IMAGE is stale relative to the current initfs/guest-agent sources"
[ "$(stamp_value agent_sha256)" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$AGENT does not match its build stamp"
[ "$(stamp_value image_sha256)" = "$(shasum -a 256 "$IMAGE" | awk '{print $1}')" ] \
  || fail "$IMAGE does not match its build stamp"

file "$AGENT" | grep -q 'ELF 64-bit' || fail "$AGENT is not a 64-bit Linux ELF binary"
case "$ARCH" in
  arm64) file "$AGENT" | grep -Eq 'ARM aarch64|arm64' || fail "$AGENT is not arm64" ;;
  amd64) file "$AGENT" | grep -Eq 'x86-64|x86_64' || fail "$AGENT is not amd64" ;;
esac

DEBUGFS="$(find_debugfs)" || fail "debugfs is required to validate the initfs contents (install e2fsprogs)"
for required in \
  /bin/sh \
  /sbin/init \
  /sbin/e2fsck \
  /sbin/fstrim \
  /usr/sbin/dumpe2fs \
  /usr/sbin/resize2fs \
  /usr/bin/dory-agent \
  /usr/local/bin/containerd \
  /usr/local/bin/crun \
  /usr/local/bin/docker \
  /usr/local/bin/dockerd \
  /usr/local/bin/runc \
  /usr/sbin/iptables; do
  "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
    || fail "$IMAGE is missing required guest path $required"
done

if [ "$ARCH" = arm64 ]; then
  for required in \
    /usr/local/bin/dory-runc \
    /usr/local/bin/runc.real \
    /usr/lib/dory/fex/FEX \
    /usr/lib/dory/fex/FEXServer \
    /usr/lib/dory/fex/ld-linux-aarch64.so.1 \
    /usr/lib/dory/fex/lib/libc.so.6 \
    /usr/lib/dory/fex/lib/libgcc_s.so.1 \
    /usr/lib/dory/fex/lib/libm.so.6 \
    /usr/lib/dory/fex/lib/libstdc++.so.6 \
    /usr/lib/dory/fex/licenses/FEX-Emu.copyright \
    /usr/lib/dory/fex/licenses/libc6.copyright \
    /usr/lib/dory/fex/licenses/gcc-14-base.copyright; do
    "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
      || fail "$IMAGE is missing required Apple Silicon FEX path $required"
  done
fi

AGENT_DUMP="$(mktemp /tmp/dory-agent-verify.XXXXXX)"
FEX_DUMP=""
FEX_SERVER_DUMP=""
DORY_RUNC_DUMP=""
RUNC_REAL_DUMP=""
cleanup() {
  rm -f "$AGENT_DUMP" "$FEX_DUMP" "$FEX_SERVER_DUMP" "$DORY_RUNC_DUMP" "$RUNC_REAL_DUMP"
}
trap cleanup EXIT
"$DEBUGFS" -R "dump /usr/bin/dory-agent $AGENT_DUMP" "$IMAGE" >/dev/null 2>&1 \
  || fail "could not extract /usr/bin/dory-agent from $IMAGE"
[ "$(shasum -a 256 "$AGENT_DUMP" | awk '{print $1}')" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$IMAGE embeds a different dory-agent than $AGENT"

if [ "$ARCH" = arm64 ]; then
  "$DEBUGFS" -R 'stat /usr/local/bin/runc' "$IMAGE" 2>&1 \
    | grep -q 'Fast link dest: "dory-runc"' \
    || fail "$IMAGE does not route BuildKit's conventional runc path through dory-runc"
  FEX_DUMP="$(mktemp /tmp/dory-fex-verify.XXXXXX)"
  FEX_SERVER_DUMP="$(mktemp /tmp/dory-fex-server-verify.XXXXXX)"
  DORY_RUNC_DUMP="$(mktemp /tmp/dory-runc-verify.XXXXXX)"
  RUNC_REAL_DUMP="$(mktemp /tmp/dory-runc-real-verify.XXXXXX)"
  "$DEBUGFS" -R "dump /usr/lib/dory/fex/FEX $FEX_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract the FEX interpreter"
  "$DEBUGFS" -R "dump /usr/lib/dory/fex/FEXServer $FEX_SERVER_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract FEXServer"
  "$DEBUGFS" -R "dump /usr/local/bin/dory-runc $DORY_RUNC_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract dory-runc"
  "$DEBUGFS" -R "dump /usr/local/bin/runc.real $RUNC_REAL_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract runc.real"
  FEX_PAIR="$(shasum -a 256 "$FEX_DUMP" | awk '{print $1}'):$(shasum -a 256 "$FEX_SERVER_DUMP" | awk '{print $1}')"
  case "$FEX_PAIR" in
    385c2495a46f00450ffa62e641552b7f18928aa18f3d0a8b621c526ccf79e009:9a4b098f004a5e9e1759ead38795f48bbc900e654d51e3bcf20d9921f00b2ef4) ;;
    *) fail "$IMAGE contains an unverified relocated FEX binary pair" ;;
  esac
  [ "$(patchelf --print-interpreter "$FEX_DUMP")" = /usr/lib/dory/fex/ld-linux-aarch64.so.1 ] \
    || fail "$IMAGE FEX interpreter does not use Dory's private loader"
  [ "$(patchelf --print-rpath "$FEX_DUMP")" = /usr/lib/dory/fex/lib ] \
    || fail "$IMAGE FEX interpreter does not use Dory's private library path"
  [ "$(patchelf --print-interpreter "$FEX_SERVER_DUMP")" = /usr/lib/dory/fex/ld-linux-aarch64.so.1 ] \
    || fail "$IMAGE FEXServer does not use Dory's private loader"
  [ "$(patchelf --print-rpath "$FEX_SERVER_DUMP")" = /usr/lib/dory/fex/lib ] \
    || fail "$IMAGE FEXServer does not use Dory's private library path"
  file "$DORY_RUNC_DUMP" | grep -Eq 'ELF 64-bit.*(ARM aarch64|arm64).*(static-pie|statically) linked' \
    || fail "$IMAGE dory-runc is not a static arm64 Linux binary"
  file "$RUNC_REAL_DUMP" | grep -Eq 'ELF 64-bit.*(ARM aarch64|arm64).*(static-pie|statically) linked' \
    || fail "$IMAGE runc.real is not Docker's static arm64 runtime"
fi

echo "verified $ARCH initfs input fingerprint $EXPECTED_INPUT"
