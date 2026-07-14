#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-sparkle-signing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

APP="$TMP/Dory.app"
VERSION="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$VERSION/XPCServices/Installer.xpc/Contents/MacOS" \
  "$VERSION/XPCServices/Downloader.xpc/Contents/MacOS" \
  "$VERSION/Updater.app/Contents/MacOS"
ln -s B "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
touch \
  "$APP/Contents/MacOS/Dory" \
  "$VERSION/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$VERSION/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$VERSION/Autoupdate" \
  "$VERSION/Updater.app/Contents/MacOS/Updater" \
  "$VERSION/Sparkle"

BIN="$TMP/bin"
LOG="$TMP/codesign.log"
mkdir -p "$BIN"

cat > "$BIN/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-d" ]; then
  path="${!#}"
  if [ "${DORY_TEST_ADHOC_BASENAME:-}" = "$(basename "$path")" ]; then
    printf '%s\n' \
      'CodeDirectory v=20500 size=100 flags=0x10002(adhoc,runtime) hashes=1+2 location=embedded' \
      'TeamIdentifier=not set' >&2
  else
    printf '%s\n' \
      'CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+2 location=embedded' \
      'Authority=Developer ID Application: Test (TESTTEAM)' \
      'Timestamp=14 Jul 2026 at 1:00:00 AM' \
      'TeamIdentifier=TESTTEAM' >&2
  fi
  exit 0
fi
if [ -n "${DORY_TEST_CODESIGN_LOG:-}" ]; then
  printf '%q ' "$@" >> "$DORY_TEST_CODESIGN_LOG"
  printf '\n' >> "$DORY_TEST_CODESIGN_LOG"
fi
exit 0
SH

cat > "$BIN/file" <<'SH'
#!/bin/bash
printf '%s\n' 'Mach-O 64-bit executable arm64'
SH
chmod 0755 "$BIN/codesign" "$BIN/file"

PATH="$BIN:$PATH" DORY_TEST_CODESIGN_LOG="$LOG" \
  scripts/sign-sparkle-for-distribution.sh "$APP" 'Developer ID Application'

[ "$(wc -l < "$LOG" | tr -d ' ')" = 5 ] \
  || { echo "test-sparkle-distribution-signing: expected five inside-out signatures" >&2; exit 1; }
sed -n '1p' "$LOG" | grep -F 'Installer.xpc' >/dev/null
sed -n '2p' "$LOG" | grep -F -- '--preserve-metadata=entitlements' >/dev/null
sed -n '2p' "$LOG" | grep -F 'Downloader.xpc' >/dev/null
sed -n '3p' "$LOG" | grep -F 'Autoupdate' >/dev/null
sed -n '4p' "$LOG" | grep -F 'Updater.app' >/dev/null
sed -n '5p' "$LOG" | grep -F 'Sparkle.framework' >/dev/null
grep -F -- '--timestamp' "$LOG" >/dev/null
if grep -F -- '--deep' "$LOG" >/dev/null; then
  echo "test-sparkle-distribution-signing: unsafe --deep signing returned" >&2
  exit 1
fi

PATH="$BIN:$PATH" scripts/verify-distribution-signatures.sh "$APP" TESTTEAM >/dev/null
if PATH="$BIN:$PATH" DORY_TEST_ADHOC_BASENAME=Autoupdate \
  scripts/verify-distribution-signatures.sh "$APP" TESTTEAM >"$TMP/adhoc.out" 2>&1; then
  echo "test-sparkle-distribution-signing: ad-hoc nested code was accepted" >&2
  exit 1
fi
grep -F 'Autoupdate' "$TMP/adhoc.out" >/dev/null \
  || { echo "test-sparkle-distribution-signing: rejection did not identify nested code" >&2; exit 1; }

rm -rf "$VERSION/XPCServices/Installer.xpc"
if PATH="$BIN:$PATH" scripts/sign-sparkle-for-distribution.sh "$APP" 'Developer ID Application' \
  >"$TMP/missing.out" 2>&1; then
  echo "test-sparkle-distribution-signing: missing Sparkle helper was accepted" >&2
  exit 1
fi

bash -n scripts/sign-sparkle-for-distribution.sh scripts/verify-distribution-signatures.sh
echo "test-sparkle-distribution-signing: PASS"
