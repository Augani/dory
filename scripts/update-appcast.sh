#!/bin/bash
# Prepend a release entry to docs/appcast.xml (the Sparkle feed served on GitHub Pages).
# Usage: scripts/update-appcast.sh VERSION BUILD URL EDSIGNATURE LENGTH [MIN_MACOS]
set -euo pipefail
cd "$(dirname "$0")/.."

V="$1"; BUILD="$2"; URL="$3"; SIG="$4"; LEN="$5"; MINOS="${6:-26.0}"

if grep -q "<sparkle:shortVersionString>$V</sparkle:shortVersionString>" docs/appcast.xml; then
  echo "appcast already has $V — nothing to do"; exit 0
fi

DATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')" \
V="$V" BUILD="$BUILD" URL="$URL" SIG="$SIG" LEN="$LEN" MINOS="$MINOS" \
python3 - <<'PY'
import os
v, build, url, sig, length, minos, date = (os.environ[k] for k in
    ("V", "BUILD", "URL", "SIG", "LEN", "MINOS", "DATE"))
item = f'''    <item>
      <title>{v}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minos}</sparkle:minimumSystemVersion>
      <enclosure url="{url}" sparkle:edSignature="{sig}" length="{length}" type="application/octet-stream" />
    </item>
'''
path = "docs/appcast.xml"
marker = "<language>en</language>\n"
text = open(path).read()
if marker not in text:
    raise SystemExit("appcast marker not found")
open(path, "w").write(text.replace(marker, marker + item, 1))
print(f"appcast updated with {v}")
PY
