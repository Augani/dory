#!/bin/bash
# Exercise Sparkle's real feed/download/Ed25519/install/terminate/relaunch path against the exact
# public Dory app-update archive. Full execution is destructive only inside a clean release user;
# --build-only validates and builds the exact pinned Sparkle CLI without launching or replacing an app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_APP=""
UPDATE_ZIP=""
APPCAST=""
RELEASE_MANIFEST=""
SBOM=""
SPARKLE_SOURCE=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
SIGNING_IDENTITY="${DORY_SIGN_ID:-Developer ID Application}"
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-release-live-sparkle"
CONFIRM=""
BUILD_ONLY=0

usage() {
  cat <<EOF
Usage: scripts/sparkle-install-relaunch-gate.sh [required options] [options]

Required:
  --candidate-app PATH       Exact extracted notarized Dory.app
  --update-zip PATH          Exact signed app-update ZIP
  --appcast PATH             Exact signed release appcast
  --release-manifest PATH    Schema-2 immutable release manifest
  --sbom PATH                Exact candidate CycloneDX SBOM
  --sparkle-source DIR       Exact Package.resolved-pinned Sparkle checkout
  --version VERSION          Exact candidate marketing version
  --build BUILD              Exact candidate CFBundleVersion
  --source-commit SHA        Exact 40-character candidate source commit

Full live gate:
  --signing-identity NAME    Developer ID identity for the lower-build fixture
  --confirm TOKEN            Must be CLEAN-RELEASE-USER-SPARKLE-INSTALL

Options:
  --workroot DIR             Durable evidence root (default: $WORKROOT)
  --build-only               Build/verify the pinned Sparkle CLI; do not launch an app
  --help                     Show this help

Full execution also requires DORY_RELEASE_CLEAN_USER=1, physical Apple Silicon, Gatekeeper
assessments enabled, and an account with no Dory process, state, preferences, service, or Docker
context. The gate creates a lower-build Developer-ID-signed fixture from the exact candidate,
serves the byte-identical signed archive on loopback, installs it through Sparkle 2.9.4's official
CLI, proves termination and relaunch with a different PID, verifies the exact SBOM tree and
Gatekeeper result, restores the fixture, and returns the release account to its initial empty state.
EOF
}

die() { echo "Sparkle install gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-app) need_value "$1" "$#"; CANDIDATE_APP="$2"; shift 2 ;;
    --update-zip) need_value "$1" "$#"; UPDATE_ZIP="$2"; shift 2 ;;
    --appcast) need_value "$1" "$#"; APPCAST="$2"; shift 2 ;;
    --release-manifest) need_value "$1" "$#"; RELEASE_MANIFEST="$2"; shift 2 ;;
    --sbom) need_value "$1" "$#"; SBOM="$2"; shift 2 ;;
    --sparkle-source) need_value "$1" "$#"; SPARKLE_SOURCE="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --signing-identity) need_value "$1" "$#"; SIGNING_IDENTITY="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for pair in \
  "candidate-app:$CANDIDATE_APP" "update-zip:$UPDATE_ZIP" "appcast:$APPCAST" \
  "release-manifest:$RELEASE_MANIFEST" "sbom:$SBOM" "sparkle-source:$SPARKLE_SOURCE" \
  "version:$VERSION" "build:$BUILD" "source-commit:$SOURCE_COMMIT"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$BUILD" in ''|*[!0-9]*) die "build must be a positive integer" ;; esac
[ "$BUILD" -gt 0 ] || die "build must be a positive integer"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "source commit must be a full lowercase Git SHA"
if [ "$BUILD_ONLY" -eq 0 ]; then
  [ "$CONFIRM" = CLEAN-RELEASE-USER-SPARKLE-INSTALL ] \
    || die "full execution requires --confirm CLEAN-RELEASE-USER-SPARKLE-INSTALL"
  [ "${DORY_RELEASE_CLEAN_USER:-0}" = 1 ] \
    || die "full execution requires DORY_RELEASE_CLEAN_USER=1"
fi

absolute_existing() {
  local path="$1"
  [ -e "$path" ] || die "required path is unavailable: $path"
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}
CANDIDATE_APP="$(absolute_existing "$CANDIDATE_APP")"
UPDATE_ZIP="$(absolute_existing "$UPDATE_ZIP")"
APPCAST="$(absolute_existing "$APPCAST")"
RELEASE_MANIFEST="$(absolute_existing "$RELEASE_MANIFEST")"
SBOM="$(absolute_existing "$SBOM")"
SPARKLE_SOURCE="$(absolute_existing "$SPARKLE_SOURCE")"
[ -d "$CANDIDATE_APP" ] && [ "$(basename "$CANDIDATE_APP")" = Dory.app ] \
  || die "candidate app must be an exact Dory.app directory"
git -C "$SPARKLE_SOURCE" rev-parse --is-inside-work-tree 2>/dev/null | grep -qx true \
  || die "Sparkle source is not a Git checkout"
for command in codesign curl ditto git plutil python3 security shasum spctl xcodebuild xcrun; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

PIN_FILE="$ROOT/Dory.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -s "$PIN_FILE" ] || die "Dory Package.resolved is missing"
pin_values="$(python3 - "$PIN_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
rows = [row for row in payload.get("pins", []) if row.get("identity") == "sparkle"]
assert len(rows) == 1, "Package.resolved must contain one Sparkle pin"
state = rows[0].get("state", {})
print(state.get("version", ""))
print(state.get("revision", ""))
PY
)" || die "could not parse the Sparkle pin"
SPARKLE_VERSION="$(printf '%s\n' "$pin_values" | sed -n '1p')"
SPARKLE_REVISION="$(printf '%s\n' "$pin_values" | sed -n '2p')"
[ "$SPARKLE_VERSION" = 2.9.4 ] || die "release requires pinned Sparkle 2.9.4"
printf '%s\n' "$SPARKLE_REVISION" | grep -Eq '^[0-9a-f]{40}$' \
  || die "Sparkle revision pin is invalid"
[ "$(git -C "$SPARKLE_SOURCE" rev-parse HEAD)" = "$SPARKLE_REVISION" ] \
  || die "Sparkle source checkout differs from Package.resolved"
[ -z "$(git -C "$SPARKLE_SOURCE" status --porcelain --untracked-files=no)" ] \
  || die "Sparkle source checkout has tracked changes"

EXPECTED_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$CANDIDATE_APP/Contents/Info.plist")"
EXPECTED_APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$CANDIDATE_APP/Contents/Info.plist")"
[ "$EXPECTED_APP_VERSION" = "$VERSION" ] || die "candidate marketing version mismatch"
[ "$EXPECTED_APP_BUILD" = "$BUILD" ] || die "candidate build mismatch"
python3 - "$RELEASE_MANIFEST" "$UPDATE_ZIP" "$APPCAST" "$SBOM" \
  "$VERSION" "$BUILD" "$SOURCE_COMMIT" <<'PY'
import hashlib, json, os, pathlib, sys
manifest_path, update, appcast, sbom, version, build, source = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
assert manifest.get("schemaVersion") == 2
assert manifest.get("version") == version
assert str(manifest.get("build")) == build
assert manifest.get("sourceCommit") == source
assert manifest.get("publicRelease") is True and manifest.get("notarized") is True
assert manifest.get("variants") == "arm64"
records = {row.get("name"): row for row in manifest.get("artifacts", [])}
for path in (update, appcast, sbom):
    name = pathlib.Path(path).name
    assert name in records, f"release manifest omits {name}"
    digest = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    assert records[name].get("sha256") == digest, f"release manifest digest mismatch: {name}"
    assert records[name].get("bytes") == os.path.getsize(path), f"release manifest size mismatch: {name}"
PY
codesign --verify --strict --deep "$CANDIDATE_APP" \
  || die "candidate app signature is invalid"
xcrun stapler validate "$CANDIDATE_APP" >/dev/null \
  || die "candidate app has no valid notarization ticket"
"$ROOT/scripts/verify-sparkle-update.sh" "$CANDIDATE_APP" "$UPDATE_ZIP" "$APPCAST" \
  > /dev/null || die "candidate Sparkle signature/key verification failed"
"$ROOT/scripts/verify-release-sbom.py" --sbom "$SBOM" --app "$CANDIDATE_APP" \
  --version "$VERSION" --source-commit "$SOURCE_COMMIT" >/dev/null \
  || die "candidate SBOM does not match the exact app tree"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
DERIVED_DATA="$RUN_ROOT/DerivedData"
mkdir -p "$EVIDENCE"
BUILD_LOG="$EVIDENCE/sparkle-cli-build.log"
DEVELOPER_DIR_VALUE="${DEVELOPER_DIR:-$(xcode-select -p)}"
DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" xcodebuild \
  -project "$SPARKLE_SOURCE/Sparkle.xcodeproj" \
  -scheme sparkle-cli \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build > "$BUILD_LOG" 2>&1 \
  || die "pinned Sparkle CLI build failed; see $BUILD_LOG"
SPARKLE_CLI_APP="$DERIVED_DATA/Build/Products/Release/sparkle.app"
SPARKLE_CLI="$SPARKLE_CLI_APP/Contents/MacOS/sparkle"
[ -x "$SPARKLE_CLI" ] || die "pinned Sparkle CLI product is missing"
codesign --verify --strict --deep "$SPARKLE_CLI_APP" \
  || die "pinned Sparkle CLI product has an invalid local signature"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SPARKLE_CLI_APP/Contents/Info.plist")" = "$SPARKLE_VERSION" ] \
  || die "built Sparkle CLI version differs from Package.resolved"
SPARKLE_CLI_SHA="$(shasum -a 256 "$SPARKLE_CLI" | awk '{print $1}')"
SPARKLE_FRAMEWORK_SHA="$(shasum -a 256 \
  "$SPARKLE_CLI_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" | awk '{print $1}')"
CANDIDATE_TREE_SHA="$(python3 - "$SBOM" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
rows = payload["metadata"]["component"]["properties"]
values = [row["value"] for row in rows if row["name"] == "dev.dory.app.tree.sha256"]
assert len(values) == 1
print(values[0])
PY
)"

if [ "$BUILD_ONLY" -eq 1 ]; then
  {
    echo status=PASS
    echo release_qualifying=false
    echo build_only=PASS
    echo "source_commit=$SOURCE_COMMIT"
    echo "candidate_version=$VERSION"
    echo "candidate_build=$BUILD"
    echo "candidate_tree_sha256=$CANDIDATE_TREE_SHA"
    echo "sparkle_version=$SPARKLE_VERSION"
    echo "sparkle_revision=$SPARKLE_REVISION"
    echo "sparkle_cli_sha256=$SPARKLE_CLI_SHA"
    echo "sparkle_framework_sha256=$SPARKLE_FRAMEWORK_SHA"
    echo "completed_epoch=$(date +%s)"
  } > "$EVIDENCE/manifest.txt"
  rm -rf "$DERIVED_DATA"
  echo "Sparkle install gate build-only PASS: $EVIDENCE/manifest.txt"
  exit 0
fi

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] \
  || die "full execution requires physical Apple Silicon"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested macOS cannot qualify the Sparkle install"
[ "$(spctl --status 2>&1)" = "assessments enabled" ] \
  || die "Gatekeeper assessments must be enabled"
[ "$BUILD" -gt 1 ] || die "a lower-build update fixture requires build greater than one"
security find-identity -v -p codesigning \
  | grep -F "$SIGNING_IDENTITY" >/dev/null \
  || die "Developer ID signing identity is unavailable: $SIGNING_IDENTITY"

STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/com.pythonxi.Dory"
PREF_DOMAIN="com.pythonxi.Dory"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
for process in Dory doryd dory-hv dory-vmm; do
  ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
    || die "$process is already running; use a clean dedicated release user"
done
! launchctl print "$SERVICE" >/dev/null 2>&1 \
  || die "Dory service is already loaded; use a clean dedicated release user"
[ ! -e "$STATE" ] || die "existing Dory state would be touched: $STATE"
[ ! -e "$APP_SUPPORT" ] || die "existing Dory application state would be touched: $APP_SUPPORT"
[ ! -e "$PLIST" ] || die "existing Dory LaunchAgent would be touched: $PLIST"
if defaults export "$PREF_DOMAIN" - >/dev/null 2>&1; then
  die "existing Dory preferences would be touched; use a clean dedicated release user"
fi
CANDIDATE_DOCKER="$CANDIDATE_APP/Contents/Helpers/docker"
PREVIOUS_CONTEXT="$($CANDIDATE_DOCKER context show 2>/dev/null || printf default)"
[ -n "$PREVIOUS_CONTEXT" ] || PREVIOUS_CONTEXT=default
! "$CANDIDATE_DOCKER" context inspect dory >/dev/null 2>&1 \
  || die "existing Docker context dory would be touched"
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
    die "existing Dory shell integration would be touched: $profile"
  fi
done

INSTALL_ROOT="$RUN_ROOT/install"
INSTALL_APP="$INSTALL_ROOT/Dory.app"
PREVIOUS_BACKUP="$RUN_ROOT/previous/Dory.app"
FEED_ROOT="$RUN_ROOT/feed"
UPDATED_BACKUP="$RUN_ROOT/updated/Dory.app"
OLD_PID=""
NEW_PID=""
SERVER_PID=""
SPARKLE_PID=""
CLEAN_USER_ARMED=1

processes_for_executable() {
  ps -ww -axo pid=,command= | awk -v executable="$1" '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "")
      if ($0 == executable || index($0, executable " ") == 1) print pid
    }
  '
}

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

clean_release_user_state() {
  local cli="$INSTALL_APP/Contents/Helpers/dory" docker="$INSTALL_APP/Contents/Helpers/docker"
  if [ -x "$cli" ]; then
    "$cli" engine sleep >/dev/null 2>&1 || true
    "$cli" uninstall >/dev/null 2>&1 || true
  fi
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  if [ -x "$docker" ]; then
    "$docker" context use "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
    "$docker" context rm -f dory >/dev/null 2>&1 || true
  fi
  rm -f "$PLIST"
  rm -rf "$STATE" "$APP_SUPPORT"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
}

cleanup() {
  status=$?
  set +e
  stop_pid "$SPARKLE_PID"
  SPARKLE_PID=""
  [ -z "$SERVER_PID" ] || { kill -TERM "$SERVER_PID" >/dev/null 2>&1; wait "$SERVER_PID" 2>/dev/null; }
  stop_pid "$NEW_PID"
  stop_pid "$OLD_PID"
  [ "${CLEAN_USER_ARMED:-0}" != 1 ] || clean_release_user_state
  if [ "$status" -eq 0 ] || [ "${DORY_SPARKLE_KEEP_FAILURE_PAYLOAD:-0}" != 1 ]; then
    rm -rf "$DERIVED_DATA" "$INSTALL_ROOT" "$RUN_ROOT/previous" "$RUN_ROOT/updated" "$FEED_ROOT"
  fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

mkdir -p "$INSTALL_ROOT" "$(dirname "$PREVIOUS_BACKUP")" "$FEED_ROOT"
ditto "$CANDIDATE_APP" "$INSTALL_APP"
PREVIOUS_BUILD=$((BUILD - 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PREVIOUS_BUILD" \
  "$INSTALL_APP/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
  --preserve-metadata=identifier,requirements,entitlements "$INSTALL_APP" \
  > "$EVIDENCE/previous-signing.out" 2> "$EVIDENCE/previous-signing.err" \
  || die "could not sign the lower-build update fixture"
codesign --verify --strict --deep "$INSTALL_APP" \
  || die "lower-build update fixture signature is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$INSTALL_APP/Contents/Info.plist")" = "$PREVIOUS_BUILD" ] \
  || die "lower-build fixture version did not change"
CANDIDATE_TEAM="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 \
  | sed -n 's/^TeamIdentifier=//p')"
PREVIOUS_TEAM="$(codesign -dv --verbose=4 "$INSTALL_APP" 2>&1 \
  | sed -n 's/^TeamIdentifier=//p')"
[ -n "$CANDIDATE_TEAM" ] && [ "$PREVIOUS_TEAM" = "$CANDIDATE_TEAM" ] \
  || die "lower-build fixture is not signed by the candidate team"
ditto "$INSTALL_APP" "$PREVIOUS_BACKUP"

mkdir -p "$APP_SUPPORT"
SENTINEL="$APP_SUPPORT/release-update-sentinel-$RUN_ID"
printf '%s\n' "$RUN_ID" > "$SENTINEL"
defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool false
defaults write "$PREF_DOMAIN" dory.releaseUpdateSentinel "$RUN_ID"

UPDATE_NAME="$(basename "$UPDATE_ZIP")"
ditto "$UPDATE_ZIP" "$FEED_ROOT/$UPDATE_NAME"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
LOCAL_FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
LOCAL_UPDATE_URL="http://127.0.0.1:$PORT/$UPDATE_NAME"
python3 - "$APPCAST" "$FEED_ROOT/appcast.xml" "$LOCAL_UPDATE_URL" \
  "$BUILD" "$VERSION" "$UPDATE_ZIP" <<'PY'
import base64, os, sys, xml.etree.ElementTree as ET
source, output, update_url, build, version, archive = sys.argv[1:]
uri = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", uri)
root = ET.parse(source).getroot()
item = root.find("./channel/item")
assert item is not None
assert item.findtext(f"{{{uri}}}version") == build
assert item.findtext(f"{{{uri}}}shortVersionString") == version
enclosure = item.find("enclosure")
assert enclosure is not None
signature = enclosure.attrib[f"{{{uri}}}edSignature"]
assert len(base64.b64decode(signature, validate=True)) == 64
assert int(enclosure.attrib["length"]) == os.path.getsize(archive)
enclosure.set("url", update_url)
ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)
PY
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_ROOT" \
  > "$EVIDENCE/feed-server.out" 2> "$EVIDENCE/feed-server.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS --max-time 2 "$LOCAL_FEED_URL" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 5 "$LOCAL_FEED_URL" >/dev/null \
  || die "loopback Sparkle feed did not become ready"

INSTALLED_EXECUTABLE="$INSTALL_APP/Contents/MacOS/Dory"
DORY_UI_TEST=1 "$INSTALLED_EXECUTABLE" \
  > "$EVIDENCE/previous-app.out" 2> "$EVIDENCE/previous-app.err" &
OLD_PID=$!
sleep 2
kill -0 "$OLD_PID" 2>/dev/null || die "lower-build fixture exited before the update"
[ "$(processes_for_executable "$INSTALLED_EXECUTABLE" | awk 'NF {count++} END {print count+0}')" -eq 1 ] \
  || die "lower-build fixture process identity is ambiguous"
printf '%s\n' "$OLD_PID" > "$EVIDENCE/previous.pid"
ps -ww -p "$OLD_PID" -o command= > "$EVIDENCE/previous-command.txt"

"$SPARKLE_CLI" \
  --application "$INSTALL_APP" \
  --feed-url "$LOCAL_FEED_URL" \
  --user-agent-name "Dory release qualification" \
  --check-immediately \
  --grant-automatic-checks \
  --verbose \
  "$INSTALL_APP" \
  > "$EVIDENCE/sparkle-install.out" 2> "$EVIDENCE/sparkle-install.err" &
SPARKLE_PID=$!
sparkle_started=$SECONDS
while kill -0 "$SPARKLE_PID" 2>/dev/null; do
  if [ $((SECONDS - sparkle_started)) -ge 600 ]; then
    kill -TERM "$SPARKLE_PID" 2>/dev/null || true
    wait "$SPARKLE_PID" 2>/dev/null || true
    die "Sparkle install exceeded 600 seconds"
  fi
  sleep 0.25
done
if wait "$SPARKLE_PID"; then SPARKLE_RC=0; else SPARKLE_RC=$?; fi
[ "$SPARKLE_RC" -eq 0 ] || die "Sparkle CLI install failed with exit $SPARKLE_RC"

for _ in $(seq 1 120); do
  candidate_pids="$(processes_for_executable "$INSTALLED_EXECUTABLE")"
  NEW_PID="$(printf '%s\n' "$candidate_pids" | awk -v old="$OLD_PID" '$1 != old {print; exit}')"
  [ -n "$NEW_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null && break
  sleep 0.5
done
[ -n "$NEW_PID" ] || die "Sparkle did not relaunch the installed candidate"
[ "$NEW_PID" != "$OLD_PID" ] || die "Sparkle relaunch reused the previous PID"
! kill -0 "$OLD_PID" 2>/dev/null || die "previous app process survived the Sparkle install"
[ "$(processes_for_executable "$INSTALLED_EXECUTABLE" | awk 'NF {count++} END {print count+0}')" -eq 1 ] \
  || die "Sparkle relaunch produced an ambiguous candidate process"
printf '%s\n' "$NEW_PID" > "$EVIDENCE/relaunched.pid"
ps -ww -p "$NEW_PID" -o command= > "$EVIDENCE/relaunched-command.txt"
sleep 2
kill -0 "$NEW_PID" 2>/dev/null || die "relaunched candidate exited during verification"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$INSTALL_APP/Contents/Info.plist")" = "$VERSION" ] \
  || die "Sparkle installed the wrong marketing version"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$INSTALL_APP/Contents/Info.plist")" = "$BUILD" ] \
  || die "Sparkle installed the wrong build"
"$ROOT/scripts/verify-release-sbom.py" --sbom "$SBOM" --app "$INSTALL_APP" \
  --version "$VERSION" --source-commit "$SOURCE_COMMIT" \
  > "$EVIDENCE/installed-sbom-verification.txt" \
  || die "Sparkle-installed app differs from the exact candidate tree"
codesign --verify --strict --deep "$INSTALL_APP" \
  || die "Sparkle-installed app signature is invalid"
xcrun stapler validate "$INSTALL_APP" > "$EVIDENCE/installed-stapler.txt" 2>&1 \
  || die "Sparkle-installed app lost its notarization ticket"
spctl -a -vv --type execute "$INSTALL_APP" \
  > "$EVIDENCE/installed-gatekeeper.txt" 2>&1 \
  || die "Gatekeeper rejected the Sparkle-installed app"
grep -F 'source=Notarized Developer ID' "$EVIDENCE/installed-gatekeeper.txt" >/dev/null \
  || die "Gatekeeper did not identify the Sparkle-installed app as Notarized Developer ID"
[ "$(cat "$SENTINEL")" = "$RUN_ID" ] \
  || die "application-support sentinel changed during the update"
[ "$(defaults read "$PREF_DOMAIN" dory.releaseUpdateSentinel)" = "$RUN_ID" ] \
  || die "preference sentinel changed during the update"
grep -F 'GET /appcast.xml ' "$EVIDENCE/feed-server.err" >/dev/null \
  || die "Sparkle did not fetch the loopback appcast"
grep -F "GET /$UPDATE_NAME " "$EVIDENCE/feed-server.err" >/dev/null \
  || die "Sparkle did not fetch the exact update archive"
for message in 'Downloading Update' 'Extracting Update' 'Installing Update' 'Installation Finished'; do
  grep -F "$message" "$EVIDENCE/sparkle-install.err" >/dev/null \
    || die "Sparkle CLI did not report required phase: $message"
done

stop_pid "$NEW_PID"
NEW_PID=""
wait "$OLD_PID" 2>/dev/null || true
OLD_PID=""
clean_release_user_state
mkdir -p "$(dirname "$UPDATED_BACKUP")"
mv "$INSTALL_APP" "$UPDATED_BACKUP"
ditto "$PREVIOUS_BACKUP" "$INSTALL_APP"
codesign --verify --strict --deep "$INSTALL_APP" \
  || die "rollback fixture signature is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$INSTALL_APP/Contents/Info.plist")" = "$PREVIOUS_BUILD" ] \
  || die "rollback did not restore the lower-build fixture"
rm -rf "$INSTALL_ROOT" "$RUN_ROOT/previous" "$RUN_ROOT/updated"
[ ! -e "$STATE" ] && [ ! -e "$APP_SUPPORT" ] && [ ! -e "$PLIST" ] \
  || die "clean release-user Dory state survived cleanup"
if defaults export "$PREF_DOMAIN" - >/dev/null 2>&1; then
  die "clean release-user preferences survived cleanup"
fi
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
    die "Dory shell integration survived clean-user cleanup: $profile"
  fi
done
CLEAN_USER_ARMED=0

{
  echo status=PASS
  echo release_qualifying=true
  echo "run_id=$RUN_ID"
  echo "source_commit=$SOURCE_COMMIT"
  echo "candidate_version=$VERSION"
  echo "candidate_build=$BUILD"
  echo "previous_fixture_build=$PREVIOUS_BUILD"
  echo "candidate_tree_sha256=$CANDIDATE_TREE_SHA"
  echo "update_zip_sha256=$(shasum -a 256 "$UPDATE_ZIP" | awk '{print $1}')"
  echo "appcast_sha256=$(shasum -a 256 "$APPCAST" | awk '{print $1}')"
  echo "sparkle_version=$SPARKLE_VERSION"
  echo "sparkle_revision=$SPARKLE_REVISION"
  echo "sparkle_cli_sha256=$SPARKLE_CLI_SHA"
  echo "sparkle_framework_sha256=$SPARKLE_FRAMEWORK_SHA"
  echo "old_pid=$(cat "$EVIDENCE/previous.pid")"
  echo "relaunched_pid=$(cat "$EVIDENCE/relaunched.pid")"
  echo old_process_terminated=PASS
  echo different_relaunch_pid=PASS
  echo loopback_appcast_fetched=PASS
  echo exact_update_archive_fetched=PASS
  echo ed25519_archive_verified=PASS
  echo installed_tree_exact=PASS
  echo installed_notarization_ticket=PASS
  echo installed_gatekeeper=PASS
  echo application_support_preserved=PASS
  echo preferences_preserved=PASS
  echo rollback_fixture_restored=PASS
  echo initial_clean_user_state_restored=PASS
  echo "completed_epoch=$(date +%s)"
} > "$EVIDENCE/manifest.txt"

rm -rf "$DERIVED_DATA" "$FEED_ROOT"
trap - EXIT INT TERM
echo "Sparkle install/relaunch gate PASS: $EVIDENCE/manifest.txt"
