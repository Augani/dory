#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-deployment-targets.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
APP="$TMP/Dory.app"
mkdir -p "$BIN" "$APP/Contents/MacOS" "$APP/Contents/Helpers"

for executable in \
  MacOS/Dory Helpers/doryd Helpers/dorydctl Helpers/dory-vmm \
  Helpers/dory-network-helper Helpers/dory-dataplane-proxy Helpers/dory-hv; do
  printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/$executable"
  chmod 0755 "$APP/Contents/$executable"
done

cat > "$BIN/lipo" <<'SH'
#!/bin/sh
printf '%s\n' arm64
SH
cat > "$BIN/xcrun" <<'SH'
#!/bin/sh
[ "${1:-}" = --find ] || exit 64
case "${2:-}" in
  vtool) printf '%s\n' "$DORY_TEST_BIN/vtool" ;;
  otool) printf '%s\n' "$DORY_TEST_BIN/otool" ;;
  *) exit 1 ;;
esac
SH
cat > "$BIN/vtool" <<'SH'
#!/bin/sh
last=""
for argument in "$@"; do last="$argument"; done
minimum=14.0
case "$last" in *'/Helpers/dory-hv') minimum=15.0 ;; esac
case "$last" in
  *'/Helpers/dory-vmm') [ "${DORY_TEST_BAD_VMM_TARGET:-0}" != 1 ] || minimum=15.0 ;;
esac
printf 'platform MACOS\nminos %s\n' "$minimum"
SH
cat > "$BIN/otool" <<'SH'
#!/bin/sh
exit 1
SH
chmod 0755 "$BIN/lipo" "$BIN/xcrun" "$BIN/vtool" "$BIN/otool"

PATH="$BIN:/usr/bin:/bin" DORY_TEST_BIN="$BIN" \
  "$ROOT/scripts/verify-macos-deployment-targets.sh" "$APP" arm64 >/dev/null

if PATH="$BIN:/usr/bin:/bin" DORY_TEST_BIN="$BIN" DORY_TEST_BAD_VMM_TARGET=1 \
  "$ROOT/scripts/verify-macos-deployment-targets.sh" "$APP" arm64 \
  >"$TMP/bad-target.out" 2>&1; then
  echo "test-deployment-targets: accepted a mismatched helper deployment target" >&2
  exit 1
fi
grep -F 'dory-vmm (arm64) has minimum macOS 15.0; expected exactly 14.0' \
  "$TMP/bad-target.out" >/dev/null

LINK="$TMP/linked-Dory.app"
ln -s "$APP" "$LINK"
if PATH="$BIN:/usr/bin:/bin" DORY_TEST_BIN="$BIN" \
  "$ROOT/scripts/verify-macos-deployment-targets.sh" "$LINK" arm64 \
  >"$TMP/indirect.out" 2>&1; then
  echo "test-deployment-targets: accepted an indirect candidate app" >&2
  exit 1
fi
grep -F 'input must be a direct Dory.app directory' "$TMP/indirect.out" >/dev/null

echo "test-deployment-targets: PASS"
