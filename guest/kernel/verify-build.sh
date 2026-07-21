#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ./config-policy.sh
source ./profile.sh

ARCH="${1:-arm64}"
OUT="${DORY_KERNEL_OUT_DIR:-../out}"
PROFILE="$(dory_kernel_resolve_profile)"
PROFILE_SUFFIX="$(dory_kernel_profile_suffix "$PROFILE")"
case "$ARCH" in
  arm64)
    CONFIG="$OUT/config-arm64$PROFILE_SUFFIX"
    PRIMARY="$OUT/Image$PROFILE_SUFFIX"
    COMPRESSED="$OUT/Image$PROFILE_SUFFIX.zst"
    SECONDARY=""
    STAMP="$OUT/kernel-build-arm64$PROFILE_SUFFIX.stamp"
    ;;
  amd64|x86_64)
    ARCH="amd64"
    CONFIG="$OUT/config-amd64$PROFILE_SUFFIX"
    PRIMARY="$OUT/vmlinux-x86$PROFILE_SUFFIX"
    COMPRESSED="$OUT/vmlinux-x86$PROFILE_SUFFIX.zst"
    SECONDARY="$OUT/bzImage-x86$PROFILE_SUFFIX"
    STAMP="$OUT/kernel-build-amd64$PROFILE_SUFFIX.stamp"
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac
if [ "$PROFILE" = "desktop" ] && [ "$ARCH" != "arm64" ]; then
  echo "the desktop kernel profile currently supports arm64 only" >&2
  exit 64
fi

fail() {
  echo "kernel verification failed: $*" >&2
  exit 1
}

stamp_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STAMP"
}

for path in "$CONFIG" "$PRIMARY" "$COMPRESSED" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path; rebuild with guest/kernel/build.sh $ARCH"
done
if [ -n "$SECONDARY" ]; then
  [ -s "$SECONDARY" ] || fail "missing or empty $SECONDARY; rebuild with guest/kernel/build.sh $ARCH"
fi

EXPECTED_INPUT="$(./input-fingerprint.sh "$ARCH")"
[ "$(stamp_value schema)" = "3" ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = "$ARCH" ] || fail "$STAMP was built for another architecture"
[ "$(stamp_value profile)" = "$PROFILE" ] || fail "$STAMP was built for another kernel profile"
[ "$(stamp_value input_sha256)" = "$EXPECTED_INPUT" ] \
  || fail "$PRIMARY is stale relative to the current kernel configs/patches"
[ "$(stamp_value config_sha256)" = "$(shasum -a 256 "$CONFIG" | awk '{print $1}')" ] \
  || fail "$CONFIG does not match its build stamp"
[ "$(stamp_value primary_sha256)" = "$(shasum -a 256 "$PRIMARY" | awk '{print $1}')" ] \
  || fail "$PRIMARY does not match its build stamp"
[ "$(stamp_value compressed_sha256)" = "$(shasum -a 256 "$COMPRESSED" | awk '{print $1}')" ] \
  || fail "$COMPRESSED does not match its build stamp"
if [ -n "$SECONDARY" ]; then
  [ "$(stamp_value secondary_sha256)" = "$(shasum -a 256 "$SECONDARY" | awk '{print $1}')" ] \
    || fail "$SECONDARY does not match its build stamp"
fi

case "$ARCH" in
  arm64) file "$PRIMARY" | grep -q 'Linux kernel ARM64' || fail "$PRIMARY is not an arm64 Linux kernel" ;;
  amd64)
    file "$PRIMARY" | grep -Eq 'ELF 64-bit.*x86-64' || fail "$PRIMARY is not an amd64 ELF kernel"
    file "$SECONDARY" | grep -Eq 'Linux kernel x86 boot executable' || fail "$SECONDARY is not an amd64 boot kernel"
    ;;
esac

# Kconfig accepts assignments whose dependencies are unavailable, then silently rewrites them
# during olddefconfig. Verify every policy assignment from the shared and architecture fragments
# (last assignment wins, which matters for the optional GPU fragment) against the published config.
CONFIG_FRAGMENTS=(dory.config)
case "$ARCH" in
  arm64) CONFIG_FRAGMENTS+=(dory-arm.config) ;;
  amd64) CONFIG_FRAGMENTS+=(dory-x86.config) ;;
esac
case "$PROFILE" in
  headless) CONFIG_FRAGMENTS+=(dory-headless.fragment) ;;
  venus) CONFIG_FRAGMENTS+=(dory-virtual-display.fragment dory-gpu.fragment) ;;
  desktop) CONFIG_FRAGMENTS+=(dory-virtual-display.fragment dory-desktop.fragment) ;;
esac

REQUIRED_POLICIES="$({
  awk '
    /^CONFIG_[A-Za-z0-9_]+=/ {
      symbol = $0
      sub(/=.*/, "", symbol)
      if (!(symbol in seen)) {
        order[++count] = symbol
        seen[symbol] = 1
      }
      value[symbol] = substr($0, index($0, "=") + 1)
    }
    END {
      for (i = 1; i <= count; i++) {
        symbol = order[i]
        print symbol "=" value[symbol]
      }
    }
  ' "${CONFIG_FRAGMENTS[@]}"
})" || fail "could not resolve required kernel configuration policies"

while IFS= read -r expected; do
  symbol="${expected%%=*}"
  value="${expected#*=}"
  dory_kernel_config_honors_policy "$CONFIG" "$symbol" "$value" \
    || fail "$CONFIG does not honor required policy $expected"
done <<< "$REQUIRED_POLICIES"

echo "verified $ARCH kernel input fingerprint $EXPECTED_INPUT"
