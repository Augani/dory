#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-dmg-signing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
LOG="$TMP/codesign.log"
DMG="$TMP/Dory.dmg"
mkdir -p "$BIN"
touch "$DMG"

cat > "$BIN/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-d" ]; then
  if [ "${DORY_TEST_BAD_DMG_SIGNATURE:-0}" = 1 ]; then
    printf '%s\n' 'TeamIdentifier=not set' >&2
  else
    printf '%s\n' \
      'Authority=Developer ID Application: Test (TESTTEAM)' \
      'Timestamp=14 Jul 2026 at 1:00:00 AM' \
      'TeamIdentifier=TESTTEAM' >&2
  fi
  exit 0
fi
printf '%q ' "$@" >> "${DORY_TEST_CODESIGN_LOG:?}"
printf '\n' >> "$DORY_TEST_CODESIGN_LOG"
SH

cat > "$BIN/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
[ "$1" = stapler ] && [ "$2" = validate ]
SH

cat > "$BIN/spctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "${DORY_TEST_SPCTL_SOURCE:-source=Notarized Developer ID}" >&2
SH
chmod 0755 "$BIN/codesign" "$BIN/xcrun" "$BIN/spctl"

(
  export PATH="$BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  export DORY_SIGN_ID='Developer ID Application' DORY_TEST_CODESIGN_LOG="$LOG"
  source scripts/release.sh 0.3.0 18
  TEAM=TESTTEAM
  sign_dmg "$DMG"
  verify_dmg_signature "$DMG"
  validate_stapled_dmg "$DMG"
)

grep -F -- '--force --timestamp --sign Developer\ ID\ Application' "$LOG" >/dev/null \
  || { echo "test-dmg-distribution-signing: Developer ID timestamp signing missing" >&2; exit 1; }

if (
  export PATH="$BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  export DORY_SIGN_ID='Developer ID Application' DORY_TEST_CODESIGN_LOG="$LOG"
  export DORY_TEST_BAD_DMG_SIGNATURE=1
  source scripts/release.sh 0.3.0 18
  TEAM=TESTTEAM
  verify_dmg_signature "$DMG"
) >"$TMP/bad-signature.out" 2>&1; then
  echo "test-dmg-distribution-signing: invalid DMG signature was accepted" >&2
  exit 1
fi

if (
  export PATH="$BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  export DORY_SIGN_ID='Developer ID Application' DORY_TEST_CODESIGN_LOG="$LOG"
  export DORY_TEST_SPCTL_SOURCE='source=no usable signature'
  source scripts/release.sh 0.3.0 18
  TEAM=TESTTEAM
  validate_stapled_dmg "$DMG"
) >"$TMP/bad-gatekeeper.out" 2>&1; then
  echo "test-dmg-distribution-signing: unusable Gatekeeper source was accepted" >&2
  exit 1
fi

bash -n scripts/test-dmg-distribution-signing.sh
echo "test-dmg-distribution-signing: PASS"
