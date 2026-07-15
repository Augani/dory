#!/bin/bash
# Copy the exact DMG app into /Applications, apply the normal quarantine launch boundary, and run
# the existing physical candidate smoke against that installed tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG=""
SBOM=""
RELEASE_MANIFEST=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-release-direct-dmg"
CONFIRM=""
INSTALL_ONLY=0

usage() {
  cat <<EOF
Usage: scripts/direct-dmg-install-gate.sh [required options]

  --dmg PATH              Exact notarized public DMG
  --sbom PATH             Exact candidate CycloneDX SBOM
  --release-manifest PATH Schema-2 immutable release manifest
  --version VERSION       Candidate marketing version
  --build BUILD           Candidate CFBundleVersion
  --source-commit SHA     Candidate's full Git commit
  --workroot DIR          Retained evidence root
  --confirm TOKEN         Must be CLEAN-RELEASE-USER-DMG-INSTALL
  --install-only          Certify install/launch/uninstall without the physical release campaign
EOF
}

die() { echo "Direct DMG install gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dmg) need_value "$1" "$#"; DMG="$2"; shift 2 ;;
    --sbom) need_value "$1" "$#"; SBOM="$2"; shift 2 ;;
    --release-manifest) need_value "$1" "$#"; RELEASE_MANIFEST="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for pair in dmg:"$DMG" sbom:"$SBOM" release-manifest:"$RELEASE_MANIFEST" \
  version:"$VERSION" build:"$BUILD" source-commit:"$SOURCE_COMMIT"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$BUILD" in ''|*[!0-9]*) die "--build must be a positive integer" ;; esac
[ "$BUILD" -gt 0 ] || die "--build must be a positive integer"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
[ "$CONFIRM" = CLEAN-RELEASE-USER-DMG-INSTALL ] \
  || die "--confirm CLEAN-RELEASE-USER-DMG-INSTALL is required"
[ "${DORY_RELEASE_CLEAN_USER:-0}" = 1 ] || die "DORY_RELEASE_CLEAN_USER=1 is required"

absolute_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ROOT/$1" ;; esac
}
DMG="$(absolute_path "$DMG")"
SBOM="$(absolute_path "$SBOM")"
RELEASE_MANIFEST="$(absolute_path "$RELEASE_MANIFEST")"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$ROOT") die "unsafe --workroot: $WORKROOT" ;; esac
[ -s "$DMG" ] || die "DMG is missing"
[ -s "$SBOM" ] || die "SBOM is missing"
[ -s "$RELEASE_MANIFEST" ] || die "release manifest is missing"

BUILD_DIR="$(cd "$(dirname "$RELEASE_MANIFEST")" && pwd)"
manifest_commit="$(python3 "$ROOT/scripts/validate-release-metadata.py" "$BUILD_DIR" "$VERSION" "$BUILD")" \
  || die "candidate metadata is invalid"
[ "$manifest_commit" = "$SOURCE_COMMIT" ] || die "candidate source commit mismatch"
DMG_NAME="$(basename "$DMG")"
DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
python3 - "$RELEASE_MANIFEST" "$DMG_NAME" "$DMG_SHA" <<'PY'
import json, pathlib, sys
manifest, name, digest = sys.argv[1:]
records = {row["name"]: row for row in json.loads(pathlib.Path(manifest).read_text(encoding="utf-8"))["artifacts"]}
assert records[name]["sha256"] == digest, "DMG differs from the immutable release manifest"
PY

APP="/Applications/Dory.app"
PREF_DOMAIN="com.pythonxi.Dory"
PREF_PLIST="$HOME/Library/Preferences/$PREF_DOMAIN.plist"
STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/Dory"
DRIVE="$APP_SUPPORT/Dory.dorydrive"
SELECTION="$APP_SUPPORT/data-drive-selection.json"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
[ ! -e "$APP" ] || die "$APP already exists"
[ ! -e "$STATE" ] || die "existing Dory state would be touched: $STATE"
[ ! -e "$APP_SUPPORT" ] || die "existing Dory application state would be touched: $APP_SUPPORT"
[ ! -e "$PLIST" ] || die "existing Dory LaunchAgent would be touched: $PLIST"
defaults read "$PREF_DOMAIN" >/dev/null 2>&1 \
  && die "existing Dory preferences would be touched; use a clean dedicated release user"
launchctl print "$SERVICE" >/dev/null 2>&1 \
  && die "Dory service is already loaded; use a clean dedicated release user"
for process in Dory doryd dory-hv dory-vmm; do
  ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
    || die "$process is already running; use a clean dedicated release user"
done
rm -rf "$WORKROOT"
mkdir -p "$WORKROOT/evidence"
EVIDENCE="$WORKROOT/evidence"
MOUNT=""

cleanup() {
  set +e
  [ -z "$MOUNT" ] || hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  osascript -e 'tell application id "com.pythonxi.Dory" to quit' >/dev/null 2>&1 || true
  if [ -x "$APP/Contents/Helpers/dory" ]; then
    "$APP/Contents/Helpers/dory" engine sleep >/dev/null 2>&1 || true
    "$APP/Contents/Helpers/dory" uninstall >/dev/null 2>&1 || true
  fi
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  rm -rf "$STATE" "$APP_SUPPORT"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$PREF_PLIST"
  /usr/bin/killall -u "$(/usr/bin/id -un)" cfprefsd >/dev/null 2>&1 || true
  rm -f "$PREF_PLIST"
  if [ -d "$APP" ] && [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$PREF_DOMAIN" ]; then
    rm -rf "$APP"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

quarantine="0081;$(printf '%x' "$(date +%s)");dev.dory.release-gate;"
xattr -w com.apple.quarantine "$quarantine" "$DMG"
xattr -p com.apple.quarantine "$DMG" > "$EVIDENCE/dmg-quarantine.txt"
diskutil image attach --readOnly --nobrowse --plist "$DMG" > "$EVIDENCE/image-attach.plist"
MOUNT="$(python3 - "$EVIDENCE/image-attach.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    data = plistlib.load(handle)
mounts = [entry["mount-point"] for entry in data["system-entities"] if entry.get("mount-point")]
assert len(mounts) == 1, f"expected one DMG mount, found {mounts}"
print(mounts[0])
PY
)"
[ -d "$MOUNT/Dory.app" ] || die "DMG does not contain Dory.app"
[ -L "$MOUNT/Applications" ] || die "DMG does not contain its Applications link"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || die "DMG Applications link is invalid"
[ "$(find "$MOUNT" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')" = 1 ] \
  || die "DMG contains an unexpected app layout"
/usr/bin/ditto "$MOUNT/Dory.app" "$APP"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

xattr -w com.apple.quarantine "$quarantine" "$APP"
xattr -p com.apple.quarantine "$APP" > "$EVIDENCE/quarantine.txt"
codesign --verify --deep --strict "$APP" > "$EVIDENCE/codesign.log" 2>&1
xcrun stapler validate "$APP" > "$EVIDENCE/stapler.log" 2>&1
spctl --assess --type execute --verbose=4 "$APP" > "$EVIDENCE/gatekeeper.log" 2>&1
"$ROOT/scripts/verify-release-sbom.py" --sbom "$SBOM" --app "$APP" \
  --version "$VERSION" --source-commit "$SOURCE_COMMIT" > "$EVIDENCE/sbom.log"

if [ "$INSTALL_ONLY" -eq 1 ]; then
  defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
  defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool false
  open -n "$APP"
  ready=0
  for _ in $(seq 1 360); do
    if [ -S "$STATE/dory.sock" ] \
       && curl -fsS --max-time 2 --unix-socket "$STATE/dory.sock" http://d/_ping >/dev/null 2>&1; then
      ready=1
      break
    fi
    pgrep -u "$(id -u)" -x Dory >/dev/null 2>&1 \
      || die "DMG-installed Dory exited during first launch"
    sleep 0.5
  done
  [ "$ready" -eq 1 ] || die "DMG-installed Dory did not become ready"
  "$APP/Contents/Helpers/docker" -H "unix://$STATE/dory.sock" version \
    > "$EVIDENCE/docker-version.txt"
  [ -s "$DRIVE/drive.json" ] || die "DMG first launch did not create the durable Dory drive"
  [ -s "$SELECTION" ] || die "DMG first launch did not record the selected Dory drive"
  sentinel="$DRIVE/direct-dmg-uninstall-preservation.txt"
  printf 'source_commit=%s\ndmg_sha256=%s\n' "$SOURCE_COMMIT" "$DMG_SHA" > "$sentinel"

  osascript -e 'tell application id "com.pythonxi.Dory" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 120); do
    pgrep -u "$(id -u)" -x Dory >/dev/null 2>&1 || break
    sleep 0.25
  done
  "$APP/Contents/Helpers/dory" uninstall > "$EVIDENCE/uninstall.log" 2>&1
  for _ in $(seq 1 120); do
    remaining=0
    for process in Dory doryd dory-hv dory-vmm; do
      pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 && remaining=1
    done
    [ "$remaining" -eq 1 ] || break
    sleep 0.25
  done
  for process in Dory doryd dory-hv dory-vmm; do
    ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
      || die "DMG uninstall left $process running"
  done
  launchctl print "$SERVICE" >/dev/null 2>&1 && die "DMG uninstall left doryd loaded"
  [ ! -e "$PLIST" ] || die "DMG uninstall left the doryd LaunchAgent"
  [ -f "$sentinel" ] || die "DMG uninstall removed the durable Dory drive"
  grep -qx "source_commit=$SOURCE_COMMIT" "$sentinel"
  grep -qx "dmg_sha256=$DMG_SHA" "$sentinel"

  cleanup
  set -e
  [ ! -e "$APP" ] && [ ! -e "$STATE" ] && [ ! -e "$APP_SUPPORT" ] && [ ! -e "$PLIST" ] \
    || die "DMG install-only gate did not restore the clean user state"
  defaults read "$PREF_DOMAIN" >/dev/null 2>&1 \
    && die "DMG install-only gate left Dory preferences"

  {
    printf 'source_commit=%s\n' "$SOURCE_COMMIT"
    printf 'run_id=%s\n' "${GITHUB_RUN_ID:-local}"
    printf 'run_attempt=%s\n' "${GITHUB_RUN_ATTEMPT:-local}"
    printf 'version=%s\n' "$VERSION"
    printf 'build=%s\n' "$BUILD"
    printf 'dmg_sha256=%s\n' "$DMG_SHA"
    printf 'normal_quarantine=PASS\n'
    printf 'gatekeeper=PASS\n'
    printf 'sbom=PASS\n'
    printf 'first_launch=PASS\n'
    printf 'docker_ready=PASS\n'
    printf 'uninstall_preserved_data=PASS\n'
    printf 'initial_clean_user_state_restored=PASS\n'
    printf 'release_qualifying=false\n'
    printf 'status=PASS\n'
  } > "$EVIDENCE/install-manifest.txt"

  echo "Direct DMG install-only gate: PASS ($EVIDENCE/install-manifest.txt)"
  exit 0
fi

"$ROOT/scripts/release-candidate-live-smoke.sh" "$APP"
[ ! -e "$HOME/.dory" ] || die "physical smoke did not restore the clean runtime state"
[ ! -e "$HOME/Library/Application Support/Dory" ] \
  || die "physical smoke did not restore the clean durable-data state"
launchctl print "$SERVICE" >/dev/null 2>&1 \
  && die "physical smoke left doryd loaded"

{
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'run_id=%s\n' "${GITHUB_RUN_ID:-local}"
  printf 'run_attempt=%s\n' "${GITHUB_RUN_ATTEMPT:-local}"
  printf 'version=%s\n' "$VERSION"
  printf 'build=%s\n' "$BUILD"
  printf 'dmg_sha256=%s\n' "$DMG_SHA"
  printf 'normal_quarantine=PASS\n'
  printf 'gatekeeper=PASS\n'
  printf 'sbom=PASS\n'
  printf 'live_smoke=PASS\n'
  printf 'initial_clean_user_state_restored=PASS\n'
  printf 'status=PASS\n'
} > "$EVIDENCE/manifest.txt"

echo "Direct DMG install gate: PASS ($EVIDENCE/manifest.txt)"
