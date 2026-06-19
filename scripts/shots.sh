#!/bin/bash
# Build once, then capture every screen via DORY_SECTION env into /tmp/dory_<name>.png
export DEVELOPER_DIR="/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer"
cd "$(dirname "$0")/.."
BIN="build/Build/Products/Debug/Dory.app/Contents/MacOS/Dory"

pkill -f "Dory.app/Contents/MacOS/Dory" 2>/dev/null
xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath build build > /tmp/dory_signed.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then echo "BUILD FAILED"; grep -E 'error:' /tmp/dory_signed.log | head -20; exit $rc; fi
echo "BUILD SUCCEEDED"

find_window() {
python3 - <<'PY'
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    if w.get('kCGWindowOwnerName')=='Dory' and w.get('kCGWindowLayer')==0:
        b=w['kCGWindowBounds']
        if b['Width']>500:
            print(w.get('kCGWindowNumber')); break
PY
}

capture() { # name env...
  local name="$1"; shift
  pkill -f "Dory.app/Contents/MacOS/Dory" 2>/dev/null
  osascript -e 'delay 0.6' >/dev/null 2>&1
  env "$@" "$BIN" >/dev/null 2>&1 &
  osascript -e 'delay 3' -e 'tell application "Dory" to activate' -e 'delay 0.8' >/dev/null 2>&1
  local wid; wid=$(find_window)
  if [ -n "$wid" ]; then screencapture -o -l "$wid" "/tmp/dory_$name.png"; echo "shot dory_$name ($wid)"; else echo "no window for $name"; fi
}

capture containers DORY_SECTION=containers
capture images DORY_SECTION=images
capture volumes DORY_SECTION=volumes
capture networks DORY_SECTION=networks
capture kubernetes DORY_SECTION=kubernetes
capture machines DORY_SECTION=machines
capture settings DORY_SECTION=settings
capture settings_resources DORY_SECTION=settings DORY_SETTINGS_TAB=resources
capture onboarding DORY_ONBOARDING=1
capture stats DORY_SECTION=containers DORY_DETAIL_TAB=stats
capture logs DORY_SECTION=containers DORY_DETAIL_TAB=logs
capture light DORY_SECTION=containers DORY_APPEARANCE=light
pkill -f "Dory.app/Contents/MacOS/Dory" 2>/dev/null
echo "done"
