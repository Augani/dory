#!/bin/bash
# Rebuild, relaunch, and screenshot just the Dory window. Usage: scripts/shot.sh [out.png]
export DEVELOPER_DIR="/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer"
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/dory_shot.png}"
pkill -f "Dory.app/Contents/MacOS/Dory" 2>/dev/null
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath build build > /tmp/dory_signed.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "BUILD FAILED ($rc)"; grep -E 'error:' /tmp/dory_signed.log | head -20; exit $rc
fi
echo "BUILD SUCCEEDED"
open build/Build/Products/Debug/Dory.app
osascript -e 'delay 4' -e 'tell application "Dory" to activate' -e 'delay 1.2' >/dev/null 2>&1
WID=$(python3 - <<'PY'
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    if w.get('kCGWindowOwnerName')=='Dory' and w.get('kCGWindowLayer')==0:
        b=w['kCGWindowBounds']
        if b['Width']>500:
            print(w.get('kCGWindowNumber')); break
PY
)
if [ -z "$WID" ]; then echo "no Dory window found"; exit 1; fi
screencapture -o -l "$WID" "$OUT" 2>/dev/null
echo "shot: $OUT (window $WID)"
