#!/bin/bash
# Offline regression tests for the disk-image tool transition and failure-safe staging cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-make-dmg.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
APP="$TMP/Dory.app"
mkdir -p "$BIN" "$APP/Contents/MacOS"
printf 'fixture\n' > "$APP/Contents/MacOS/Dory"

cat > "$BIN/diskutil" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$DORY_TEST_DISKUTIL_LOG"
if [ "${4:-}" = "--help" ]; then
  [ "${DORY_TEST_DISKUTIL_SUPPORTED:-0}" = "1" ]
  exit
fi
last=""
for argument in "$@"; do last="$argument"; done
printf 'diskutil image\n' > "$last"
SH
chmod 0755 "$BIN/diskutil"

cat > "$BIN/hdiutil" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$DORY_TEST_HDIUTIL_LOG"
[ "${DORY_TEST_HDIUTIL_FAIL:-0}" != "1" ] || exit 70
last=""
for argument in "$@"; do last="$argument"; done
printf 'hdiutil image\n' > "$last"
SH
chmod 0755 "$BIN/hdiutil"

DISKUTIL_LOG="$TMP/diskutil.log"
HDIUTIL_LOG="$TMP/hdiutil.log"
NEW_DMG="$TMP/new.dmg"
DORY_TEST_DISKUTIL_SUPPORTED=1 \
DORY_TEST_DISKUTIL_LOG="$DISKUTIL_LOG" \
DORY_TEST_HDIUTIL_LOG="$HDIUTIL_LOG" \
PATH="$BIN:/usr/bin:/bin" \
  "$ROOT/scripts/make-dmg.sh" "$APP" 0.3.0 "$NEW_DMG" >/dev/null
grep -Fq 'image create from --format UDZO --volumeName Dory 0.3.0' "$DISKUTIL_LOG"
[ -f "$NEW_DMG" ] || { echo "test-make-dmg: diskutil path produced no image" >&2; exit 1; }
[ ! -e "$HDIUTIL_LOG" ] || { echo "test-make-dmg: diskutil path invoked hdiutil" >&2; exit 1; }

: > "$DISKUTIL_LOG"
OLD_DMG="$TMP/old.dmg"
DORY_TEST_DISKUTIL_SUPPORTED=0 \
DORY_TEST_DISKUTIL_LOG="$DISKUTIL_LOG" \
DORY_TEST_HDIUTIL_LOG="$HDIUTIL_LOG" \
PATH="$BIN:/usr/bin:/bin" \
  "$ROOT/scripts/make-dmg.sh" "$APP" 0.3.0 "$OLD_DMG" >/dev/null
grep -Fq 'create -volname Dory 0.3.0 -srcfolder' "$HDIUTIL_LOG"
[ -f "$OLD_DMG" ] || { echo "test-make-dmg: hdiutil fallback produced no image" >&2; exit 1; }

FAIL_TMP="$TMP/failure-tmp"
mkdir -p "$FAIL_TMP"
if DORY_TEST_DISKUTIL_SUPPORTED=0 \
  DORY_TEST_HDIUTIL_FAIL=1 \
  DORY_TEST_DISKUTIL_LOG="$DISKUTIL_LOG" \
  DORY_TEST_HDIUTIL_LOG="$HDIUTIL_LOG" \
  TMPDIR="$FAIL_TMP" \
  PATH="$BIN:/usr/bin:/bin" \
    "$ROOT/scripts/make-dmg.sh" "$APP" 0.3.0 "$TMP/failure.dmg" >/dev/null 2>&1; then
  echo "test-make-dmg: accepted a disk-image tool failure" >&2
  exit 1
fi
[ -z "$(find "$FAIL_TMP" -mindepth 1 -print -quit)" ] \
  || { echo "test-make-dmg: retained staging data after failure" >&2; exit 1; }

echo "test-make-dmg: PASS"
