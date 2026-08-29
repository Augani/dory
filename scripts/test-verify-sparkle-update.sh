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
<plist version="1.0"><dict>
<key>SUPublicEDKey</key><string>$key</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>12</string>
</dict></plist>
PLIST
}

cat > "$APPCAST" <<'XML'
<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<item><title>0.3.0</title><sparkle:version>12</sparkle:version>
<sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
<enclosure url="https://github.com/Augani/dory/releases/download/v0.3.0/Dory-0.3.0-app-update.zip"
sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
length="15" /></item>
<item><title>0.2.9</title><sparkle:version>11</sparkle:version>
<sparkle:shortVersionString>0.2.9</sparkle:shortVersionString>
<enclosure url="https://github.com/Augani/dory/releases/download/v0.2.9/Dory-0.2.9-app-update.zip"
sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
length="14" /></item>
</channel></rss>
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

python3 - "$APPCAST" "$TMP/duplicate-current-appcast.xml" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
current = source[source.index("<item><title>0.3.0"):source.index("<item><title>0.2.9")]
pathlib.Path(sys.argv[2]).write_text(
    source.replace("<item><title>0.2.9", current + "<item><title>0.2.9", 1),
    encoding="utf-8",
)
PY
if scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$TMP/duplicate-current-appcast.xml" \
    >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted duplicate current release items" >&2
  exit 1
fi

python3 - "$APPCAST" "$TMP/wrong-build-appcast.xml" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pathlib.Path(sys.argv[2]).write_text(
    source.replace(
        "<sparkle:version>12</sparkle:version>",
        "<sparkle:version>13</sparkle:version>",
        1,
    ),
    encoding="utf-8",
)
PY
if scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$TMP/wrong-build-appcast.xml" \
    >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted the wrong current build" >&2
  exit 1
fi

sed 's#https://github.com/Augani/dory#https://example.invalid/Augani/dory#' \
  "$APPCAST" > "$TMP/wrong-host-appcast.xml"
if scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$TMP/wrong-host-appcast.xml" \
    >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted an appcast on an untrusted host" >&2
  exit 1
fi

sed 's/length="15"/length="14"/' "$APPCAST" > "$TMP/wrong-length-appcast.xml"
if scripts/verify-sparkle-update.sh "$APP" "$ZIP" "$TMP/wrong-length-appcast.xml" \
    >/dev/null 2>&1; then
  echo "test-verify-sparkle-update: accepted a mismatched enclosure length" >&2
  exit 1
fi

bash -n scripts/verify-sparkle-update.sh
echo "test-verify-sparkle-update: PASS"
