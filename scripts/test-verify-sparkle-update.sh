#!/bin/bash
# Offline orchestration/key-compatibility regressions for verify-sparkle-update.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-sparkle-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PRIVATE_KEY='nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A='
PUBLIC_KEY='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
APP="$TMP/Dory.app"
ZIP="$TMP/Dory-0.3.0-app-update.zip"
APPCAST="$TMP/appcast.xml"
mkdir -p "$APP/Contents"
printf 'fixture update\n' > "$ZIP"

write_plist() {
  local key="$1"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>SUPublicEDKey</key><string>$key</string></dict></plist>
PLIST
}

cat > "$APPCAST" <<'XML'
<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><enclosure url="https://example.invalid/Dory-0.3.0-app-update.zip"
sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
length="15" /></item></channel></rss>
XML

sed -i '' \
  's#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==#tH/4Ma4fh3Sbj27irBE0mHHJ6HbQzFfEZAjFP3GvxgEY7cv6mP1I5AI9d01WdVE9Pfmt9pPbGUaAxFfbOPo/Cg==#' \
  "$APPCAST"

cat > "$TMP/sign_update" <<'SH'
#!/bin/bash
set -euo pipefail
[ "$1" = --verify ]
[ "$2" = --ed-key-file ]
[ "$3" = - ]
[ "$4" = "$EXPECTED_ZIP" ]
[ -n "$5" ]
[ "$(cat)" = "$EXPECTED_PRIVATE_KEY" ]
SH
chmod +x "$TMP/sign_update"

write_plist "$PUBLIC_KEY"
scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$APPCAST" >/dev/null

EXPECTED_ZIP="$ZIP" EXPECTED_PRIVATE_KEY="$PRIVATE_KEY" \
DORY_SPARKLE_SIGN_UPDATE="$TMP/sign_update" DORY_SPARKLE_PRIVATE_KEY="$PRIVATE_KEY" \
  scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$APPCAST" >/dev/null

write_plist 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
if EXPECTED_ZIP="$ZIP" EXPECTED_PRIVATE_KEY="$PRIVATE_KEY" \
  DORY_SPARKLE_SIGN_UPDATE="$TMP/sign_update" DORY_SPARKLE_PRIVATE_KEY="$PRIVATE_KEY" \
  scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$APPCAST" >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted a private/public key mismatch" >&2
  exit 1
fi

printf 'tampered update\n' >> "$ZIP"
if scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$APPCAST" >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted a tampered update ZIP" >&2
  exit 1
fi
printf 'fixture update\n' > "$ZIP"

sed 's/Dory-0.3.0-app-update.zip/wrong.zip/' "$APPCAST" > "$TMP/wrong-appcast.xml"
write_plist "$PUBLIC_KEY"
if EXPECTED_ZIP="$ZIP" EXPECTED_PRIVATE_KEY="$PRIVATE_KEY" \
  DORY_SPARKLE_SIGN_UPDATE="$TMP/sign_update" DORY_SPARKLE_PRIVATE_KEY="$PRIVATE_KEY" \
  scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$TMP/wrong-appcast.xml" >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted an appcast pointing at another artifact" >&2
  exit 1
fi

bash -n scripts/verify-sparkle-update.sh
echo "test-verify-sparkle-update: PASS"
