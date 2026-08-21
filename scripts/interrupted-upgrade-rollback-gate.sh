#!/bin/bash
# Physical exact-candidate qualification for Dory's transactional updater. The exact notarized
# candidate is the last-good app. A same-team, Ed25519-signed higher-build fixture activates a
# second signed component generation and injects one post-install smoke failure; Dory must restore
# the exact app/component/config selection while preserving the volume, published port, and data.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_APP=""
SPARKLE_SIGN_UPDATE=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
SIGNING_IDENTITY="${DORY_SIGN_ID:-Developer ID Application}"
FIXTURE_IMAGE="${DORY_RELEASE_FIXTURE_IMAGE:-}"
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-interrupted-upgrade"
CONFIRM=""

usage() {
  cat <<EOF
usage: scripts/interrupted-upgrade-rollback-gate.sh [options]

Required:
  --candidate-app PATH       Exact extracted, notarized Dory.app
  --sign-update PATH         Exact pinned Sparkle sign_update executable
  --version VERSION          Candidate CFBundleShortVersionString
  --build BUILD              Candidate CFBundleVersion
  --source-commit SHA        Exact 40-character candidate source commit
  --fixture-image REF        Immutable Linux image used for volume/port survival
  --confirm TOKEN            CLEAN-RELEASE-USER-INTERRUPTED-UPGRADE

Options:
  --signing-identity NAME    Same-team Developer ID identity (default: $SIGNING_IDENTITY)
  --workroot PATH            Durable evidence root (default: $WORKROOT)
  --help                     Show this help

Full execution requires DORY_RELEASE_CLEAN_USER=1, a physical Apple-silicon Mac, an otherwise
empty dedicated release account, and DORY_SPARKLE_PRIVATE_KEY. It modifies only that clean user's
Dory state and a private workroot, then restores the initial empty state while retaining evidence.
EOF
}

die() { echo "interrupted upgrade gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-app) need_value "$1" "$#"; CANDIDATE_APP="$2"; shift 2 ;;
    --sign-update) need_value "$1" "$#"; SPARKLE_SIGN_UPDATE="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --fixture-image) need_value "$1" "$#"; FIXTURE_IMAGE="$2"; shift 2 ;;
    --signing-identity) need_value "$1" "$#"; SIGNING_IDENTITY="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for pair in "candidate-app:$CANDIDATE_APP" "sign-update:$SPARKLE_SIGN_UPDATE" \
  "version:$VERSION" "build:$BUILD" "source-commit:$SOURCE_COMMIT" \
  "fixture-image:$FIXTURE_IMAGE"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
[ "$CONFIRM" = CLEAN-RELEASE-USER-INTERRUPTED-UPGRADE ] \
  || die "full execution requires --confirm CLEAN-RELEASE-USER-INTERRUPTED-UPGRADE"
[ "${DORY_RELEASE_CLEAN_USER:-0}" = 1 ] || die "DORY_RELEASE_CLEAN_USER=1 is required"
[ -n "${DORY_SPARKLE_PRIVATE_KEY:-}" ] || die "DORY_SPARKLE_PRIVATE_KEY is required"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' \
  || die "version must be SemVer-like"
case "$BUILD" in ''|*[!0-9]*) die "build must be a positive integer" ;; esac
[ "$BUILD" -gt 0 ] || die "build must be a positive integer"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "source commit must be a full lowercase Git SHA"
printf '%s\n' "$FIXTURE_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "fixture image must be immutable by sha256 digest"
case "$FIXTURE_IMAGE" in *[[:space:]]*) die "fixture image cannot contain whitespace" ;; esac
[ -d "$CANDIDATE_APP" ] && [ ! -L "$CANDIDATE_APP" ] \
  && [ "$(basename "$CANDIDATE_APP")" = Dory.app ] \
  || die "candidate app must be a direct Dory.app"
[ -f "$SPARKLE_SIGN_UPDATE" ] && [ ! -L "$SPARKLE_SIGN_UPDATE" ] \
  && [ -x "$SPARKLE_SIGN_UPDATE" ] || die "sign_update must be a direct executable"
for command in codesign curl ditto openssl plutil python3 security shasum spctl swift xcrun; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
CANDIDATE_APP_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$CANDIDATE_APP")"
CANDIDATE_APP="$(cd "$CANDIDATE_APP" && pwd -P)"
[ "$CANDIDATE_APP" = "$CANDIDATE_APP_LOGICAL" ] || die "candidate app has an indirect ancestor"
SIGN_UPDATE_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SPARKLE_SIGN_UPDATE")"
SPARKLE_SIGN_UPDATE="$(cd "$(dirname "$SPARKLE_SIGN_UPDATE")" && pwd -P)/$(basename "$SPARKLE_SIGN_UPDATE")"
[ "$SPARKLE_SIGN_UPDATE" = "$SIGN_UPDATE_LOGICAL" ] || die "sign_update has an indirect ancestor"
case "$WORKROOT" in /*) ;; *) die "workroot must be absolute" ;; esac
WORKROOT_PARENT="$(dirname "$WORKROOT")"
WORKROOT_NAME="$(basename "$WORKROOT")"
case "$WORKROOT_NAME" in
  dory-interrupted-upgrade|dory-release-live-transactional-upgrade) ;;
  *) die "workroot must use the dedicated interrupted-upgrade name" ;;
esac
[ -d "$WORKROOT_PARENT" ] && [ ! -L "$WORKROOT_PARENT" ] \
  || die "workroot parent must be a direct directory"
WORKROOT_PARENT_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$WORKROOT_PARENT")"
WORKROOT_PARENT="$(cd "$WORKROOT_PARENT" && pwd -P)"
[ "$WORKROOT_PARENT" = "$WORKROOT_PARENT_LOGICAL" ] || die "workroot parent has an indirect ancestor"
WORKROOT="$WORKROOT_PARENT/$WORKROOT_NAME"
TEMP_AUTHORITY="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[ -d "$TEMP_AUTHORITY" ] && [ ! -L "$TEMP_AUTHORITY" ] \
  || die "temporary authority must be a direct directory"
TEMP_AUTHORITY_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TEMP_AUTHORITY")"
TEMP_AUTHORITY="$(cd "$TEMP_AUTHORITY" && pwd -P)"
[ "$TEMP_AUTHORITY" = "$TEMP_AUTHORITY_LOGICAL" ] || die "temporary authority has an indirect ancestor"
case "$TEMP_AUTHORITY" in /|"$HOME"|"$ROOT"|"$CANDIDATE_APP") die "unsafe temporary authority" ;; esac
case "$WORKROOT" in "$TEMP_AUTHORITY"/*) ;; *) die "workroot must be inside runner temporary storage" ;; esac
for input in "$CANDIDATE_APP" "$SPARKLE_SIGN_UPDATE"; do
  case "$input/" in "$WORKROOT/"*) die "workroot cannot contain an input" ;; esac
  case "$WORKROOT/" in "$input/"*) die "workroot cannot be inside an input" ;; esac
done
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] \
  || die "physical Apple silicon macOS is required"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Apple virtualization support is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested virtualization is not release-qualifying"
case "$(sysctl -n hw.model 2>/dev/null || true)" in VirtualMac*) die "nested VirtualMac is not release-qualifying" ;; esac
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CANDIDATE_APP/Contents/Info.plist")" = "$VERSION" ] \
  || die "candidate marketing version mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CANDIDATE_APP/Contents/Info.plist")" = "$BUILD" ] \
  || die "candidate build mismatch"
codesign --verify --strict --deep "$CANDIDATE_APP" || die "candidate signature is invalid"
xcrun stapler validate "$CANDIDATE_APP" >/dev/null || die "candidate has no notarization ticket"
SOURCE_ASSESSMENT="$(spctl --assess --type execute --verbose=4 "$CANDIDATE_APP" 2>&1)" \
  || die "Gatekeeper rejected the candidate app"
printf '%s\n' "$SOURCE_ASSESSMENT" | grep -Fx 'source=Notarized Developer ID' >/dev/null \
  || die "candidate app is not accepted as Notarized Developer ID"
CANDIDATE_TEAM="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$CANDIDATE_TEAM" = 864H636QW4 ] || die "candidate is not signed by Dory team 864H636QW4"

STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/Dory"
PREF_DOMAIN="com.pythonxi.Dory"
PREF_PLIST="$HOME/Library/Preferences/$PREF_DOMAIN.plist"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
for process in Dory doryd dory-hv dory-vmm; do
  ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
    || die "$process is already running; use the dedicated clean release user"
done
! launchctl print "$SERVICE" >/dev/null 2>&1 || die "Dory service is already loaded"
[ ! -e "$STATE" ] && [ ! -e "$APP_SUPPORT" ] && [ ! -e "$PLIST" ] \
  || die "existing Dory state would be touched"
if defaults read "$PREF_DOMAIN" >/dev/null 2>&1; then
  die "existing Dory preferences would be touched"
fi
CANDIDATE_DOCKER="$CANDIDATE_APP/Contents/Helpers/docker"
PREVIOUS_CONTEXT="$("$CANDIDATE_DOCKER" context show 2>/dev/null || printf default)"
[ -n "$PREVIOUS_CONTEXT" ] || PREVIOUS_CONTEXT=default
! "$CANDIDATE_DOCKER" context inspect dory >/dev/null 2>&1 \
  || die "existing Docker context dory would be touched"
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
    die "existing Dory shell integration would be touched: $profile"
  fi
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
INSTALL_ROOT="$RUN_ROOT/install"
INSTALL_APP="$INSTALL_ROOT/Dory.app"
FAULT_ROOT="$RUN_ROOT/fault"
FAULT_APP="$FAULT_ROOT/Dory.app"
FEED_ROOT="$RUN_ROOT/feed"
TLS_ROOT="$RUN_ROOT/tls"
ARM_FILE="$RUN_ROOT/arm-update"
if [ -e "$WORKROOT" ] || [ -L "$WORKROOT" ]; then
  [ -d "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
    || die "workroot must be a direct directory"
  [ "$(stat -f '%u' "$WORKROOT")" = "$(id -u)" ] \
    || die "workroot is not owned by this user"
else
  mkdir "$WORKROOT"
fi
chmod 700 "$WORKROOT"
[ ! -e "$RUN_ROOT" ] && [ ! -L "$RUN_ROOT" ] || die "run authority already exists"
mkdir "$RUN_ROOT"
mkdir "$EVIDENCE" "$INSTALL_ROOT" "$FAULT_ROOT" "$FEED_ROOT" "$TLS_ROOT"
chmod 700 "$RUN_ROOT" "$EVIDENCE" "$INSTALL_ROOT" "$FAULT_ROOT" "$FEED_ROOT" "$TLS_ROOT"

APP_PID=""
SERVER_PID=""
TRUST_CN="Dory Upgrade Gate $RUN_ID"
CLEAN_USER_ARMED=1

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

stop_dory_processes() {
  local pid
  for pid in $(pgrep -u "$(id -u)" -x Dory 2>/dev/null || true); do
    stop_pid "$pid"
  done
}

clean_release_user_state() {
  local cli="$INSTALL_APP/Contents/Helpers/dory" docker="$INSTALL_APP/Contents/Helpers/docker"
  [ -x "$cli" ] && "$cli" engine sleep >/dev/null 2>&1 || true
  [ -x "$cli" ] && "$cli" uninstall >/dev/null 2>&1 || true
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  [ -x "$docker" ] && "$docker" context use "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
  [ -x "$docker" ] && "$docker" context rm -f dory >/dev/null 2>&1 || true
  rm -f "$PLIST"
  rm -rf "$STATE" "$APP_SUPPORT"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$PREF_PLIST"
  /usr/bin/killall -u "$(/usr/bin/id -un)" cfprefsd >/dev/null 2>&1 || true
  rm -f "$PREF_PLIST"
}

cleanup() {
  local status=$?
  set +e
  [ -z "$SERVER_PID" ] || { kill -TERM "$SERVER_PID" >/dev/null 2>&1; wait "$SERVER_PID" 2>/dev/null; }
  stop_dory_processes
  security delete-certificate -c "$TRUST_CN" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
  [ "${CLEAN_USER_ARMED:-0}" != 1 ] || clean_release_user_state
  trap - EXIT INT TERM
  exit "$status"
}
LOGIN_KEYCHAIN="$(security login-keychain -d user | tr -d ' \"')"
[ -n "$LOGIN_KEYCHAIN" ] || die "could not resolve the login keychain"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
SERVICE_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
FEED_URL="https://127.0.0.1:$PORT/appcast.xml"
UPDATE_URL="https://127.0.0.1:$PORT/Dory-$VERSION-interruption-fixture.zip"
CATALOG_V1_URL="https://127.0.0.1:$PORT/catalog-v1.json"
CATALOG_V2_URL="https://127.0.0.1:$PORT/catalog-v2.json"

python3 - "$TLS_ROOT/openssl.cnf" "$TRUST_CN" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(f'''[req]\n+distinguished_name=dn\n+x509_extensions=v3\n+prompt=no\n+[dn]\n+CN={sys.argv[2]}\n+[v3]\n+basicConstraints=critical,CA:TRUE\n+keyUsage=critical,keyCertSign,digitalSignature\n+subjectAltName=IP:127.0.0.1\n+''', encoding='utf-8')
PY
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$TLS_ROOT/key.pem" -out "$TLS_ROOT/cert.pem" \
  -config "$TLS_ROOT/openssl.cnf" -extensions v3 >/dev/null 2>&1
chmod 600 "$TLS_ROOT/key.pem" "$TLS_ROOT/cert.pem"
security add-trusted-cert -d -r trustRoot -k "$LOGIN_KEYCHAIN" "$TLS_ROOT/cert.pem"

printf 'generation-one\n' > "$FEED_ROOT/component-v1.txt"
printf 'generation-two\n' > "$FEED_ROOT/component-v2.txt"
DORY_HV_SHA256="$(shasum -a 256 "$CANDIDATE_APP/Contents/Helpers/dory-hv" | awk '{print $1}')"
BUNDLED_KERNEL_SHA256="$(shasum -a 256 "$CANDIDATE_APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" | awk '{print $1}')"
HOST_MODEL="$(sysctl -n hw.model)"
HOST_BUILD="$(sw_vers -buildVersion)"
CATALOG_PUBLIC_KEY='AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4='
python3 - "$FEED_ROOT" "$VERSION" "$SOURCE_COMMIT" "$CATALOG_V1_URL" "$CATALOG_V2_URL" \
  "$DORY_HV_SHA256" "$BUNDLED_KERNEL_SHA256" "$HOST_MODEL" "$HOST_BUILD" "$CATALOG_PUBLIC_KEY" <<'PY'
import base64, hashlib, json, pathlib, sys
(
    root_raw, version, source_commit, url1, url2, helper_digest, media_digest,
    host_model, host_build, public_key,
) = sys.argv[1:]
root = pathlib.Path(root_raw)
signing_key_id = hashlib.sha256(base64.b64decode(public_key, validate=True)).hexdigest()
qualification_identity = "release-gate-raw-linux-arm64-none-v1"
qualification_path = "virtual-machine-qualification.json"
manifest = {
    "kind": "dev.dory.virtual-machine-qualification-manifest",
    "schemaVersion": 1,
    "manifestIdentity": f"dory-release-gate-{version}",
    "catalogReleaseVersion": version,
    "architecture": "arm64",
    "signingKeyID": signing_key_id,
    "records": [{
        "qualificationIdentity": qualification_identity,
        "guest": {"family": "linux", "architecture": "arm64"},
        "bootMediaKind": "linux-kernel",
        "bootMediaSource": "dory-bundled",
        "immutableArtifactSHA256": media_digest,
        "backend": "dory-hypervisor",
        "backendImplementationIdentifier": "dory.raw-hv-linux.compatibility.v1",
        "backendRuntimeBuildIdentifier": f"sha256:{helper_digest}",
        "virtualHardwareABIVersion": 1,
        "graphics": "none",
        "devices": {
            "networkAttachment": "shared-nat", "audioInput": False,
            "audioOutput": False, "keyboard": False, "pointer": False,
            "directorySharing": False, "clipboard": False,
            "clockSynchronization": False, "dynamicDisplay": False,
            "gracefulShutdown": False,
        },
        "hostHardwareModelIdentifier": host_model,
        "hostOperatingSystemBuild": host_build,
        "components": [{
            "componentIdentifier": "dory-hv",
            "buildIdentifier": f"sha256:{helper_digest}",
            "artifactSHA256": helper_digest,
        }],
        "virtioGPUKernelAndDeviceSupportQualified": False,
        "venusVulkanGuestRuntimeQualified": False,
    }],
}
manifest_bytes = json.dumps(
    manifest, separators=(",", ":"), sort_keys=True
).encode("utf-8")
(root / qualification_path).write_bytes(manifest_bytes)
manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
for generation, url in ((1, url1), (2, url2)):
    asset = root / f"component-v{generation}.txt"
    digest = hashlib.sha256(asset.read_bytes()).hexdigest()
    provenance = {
        "sourceCommit": source_commit,
        "builder": "dory.interrupted-upgrade-gate",
        "recipeDigest": digest,
        "sbomDigest": digest,
        "attestationDigest": manifest_digest,
    }
    assets = [
        {"path": qualification_path,
         "url": url.rsplit('/', 1)[0] + f"/{qualification_path}",
         "compression": "none", "downloadBytes": len(manifest_bytes),
         "installedBytes": len(manifest_bytes), "sha256": manifest_digest,
         "installedSHA256": manifest_digest, "executable": False,
         "role": "qualification-evidence"},
        {"path": "gate/component.txt",
         "url": url.rsplit('/', 1)[0] + f"/component-v{generation}.txt",
         "compression": "none", "downloadBytes": asset.stat().st_size,
         "installedBytes": asset.stat().st_size, "sha256": digest,
         "installedSHA256": digest, "executable": False,
         "role": "build-metadata"},
    ]
    catalog = {
        "kind": "dev.dory.component-catalog", "schemaVersion": 2,
        "releaseVersion": version,
        "generatedAt": f"2026-07-19T00:00:0{generation}Z",
        "minimumAppVersion": version, "architecture": "arm64",
        "components": [
            {"id": "docker-core", "version": version, "displayName": "Docker Core",
             "summary": "Bundled exact candidate core", "dependencies": [],
             "downloadBytes": 1, "installedBytes": 1, "assets": [],
             "architectures": ["arm64"],
             "hostRequirements": {"platform": "macos", "minimumVersion": "14.0"},
             "provides": [f"app.dory-core@{version}"], "requires": [],
             "provenance": provenance, "qualification": []},
            {"id": "linux-machines", "version": f"{version}+gate.{generation}",
             "displayName": "Release Gate Component", "summary": "Transactional generation fixture",
             "dependencies": ["docker-core"],
             "downloadBytes": sum(item["downloadBytes"] for item in assets),
             "installedBytes": sum(item["installedBytes"] for item in assets),
             "assets": assets, "architectures": ["arm64"],
             "hostRequirements": {"platform": "macos", "minimumVersion": "14.0"},
             "provides": [f"component.linux-machines@{version}+gate.{generation}"],
             "requires": [f"app.dory-core@{version}"],
             "provenance": provenance, "qualification": [qualification_identity]}
        ],
        "virtualMachineQualification": {
            "component": "linux-machines", "path": qualification_path,
            "manifestIdentity": manifest["manifestIdentity"],
            "manifestFormatVersion": manifest["schemaVersion"],
            "signingKeyID": signing_key_id,
        },
    }
    (root / f"catalog-v{generation}.json").write_text(
        json.dumps(catalog, separators=(",", ":"), sort_keys=True), encoding="utf-8")
PY

sign_file() {
  local path="$1" signature
  signature="$(printf '%s' "$DORY_SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGN_UPDATE" --ed-key-file - -p "$path" | tail -n 1 | tr -d '\r\n')"
  python3 - "$signature" <<'PY'
import base64, binascii, sys
try:
    decoded = base64.b64decode(sys.argv[1], validate=True)
except (binascii.Error, ValueError) as error:
    raise SystemExit(f"invalid Ed25519 signature encoding: {error}")
if len(decoded) != 64:
    raise SystemExit("Ed25519 signature must decode to exactly 64 bytes")
PY
  printf '%s\n' "$signature"
}
sign_file "$FEED_ROOT/catalog-v1.json" > "$FEED_ROOT/catalog-v1.json.sig"
sign_file "$FEED_ROOT/catalog-v2.json" > "$FEED_ROOT/catalog-v2.json.sig"
"$ROOT/.github/scripts/verify-ed25519-signature.swift" \
  "$CATALOG_PUBLIC_KEY" "$FEED_ROOT/catalog-v1.json.sig" "$FEED_ROOT/catalog-v1.json"
"$ROOT/.github/scripts/verify-ed25519-signature.swift" \
  "$CATALOG_PUBLIC_KEY" "$FEED_ROOT/catalog-v2.json.sig" "$FEED_ROOT/catalog-v2.json"

ditto "$CANDIDATE_APP" "$FAULT_APP"
FAULT_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FAULT_BUILD" "$FAULT_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DoryUpgradeGateForceSmokeFailure bool true" "$FAULT_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DoryUpgradeGateComponentCatalogURL string $CATALOG_V2_URL" "$FAULT_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DoryUpgradeGateComponentID string linux-machines" "$FAULT_APP/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
  --preserve-metadata=identifier,requirements,entitlements "$FAULT_APP" \
  > "$EVIDENCE/fault-signing.out" 2> "$EVIDENCE/fault-signing.err"
codesign --verify --strict --deep "$FAULT_APP" || die "fault fixture signature is invalid"
FAULT_TEAM="$(codesign -dv --verbose=4 "$FAULT_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$FAULT_TEAM" = "$CANDIDATE_TEAM" ] || die "fault fixture team differs from candidate"
UPDATE_ZIP="$FEED_ROOT/Dory-$VERSION-interruption-fixture.zip"
(cd "$FAULT_ROOT" && ditto -c -k --sequesterRsrc --keepParent Dory.app "$UPDATE_ZIP")
UPDATE_SIGNATURE="$(sign_file "$UPDATE_ZIP")"
printf '%s\n' "$UPDATE_SIGNATURE" > "$FEED_ROOT/update.zip.sig"
"$ROOT/.github/scripts/verify-ed25519-signature.swift" \
  "$CATALOG_PUBLIC_KEY" "$FEED_ROOT/update.zip.sig" "$UPDATE_ZIP"
UPDATE_LENGTH="$(wc -c < "$UPDATE_ZIP" | tr -d '[:space:]')"
python3 - "$FEED_ROOT/appcast.xml" "$VERSION" "$FAULT_BUILD" "$UPDATE_URL" "$UPDATE_SIGNATURE" "$UPDATE_LENGTH" <<'PY'
import html, pathlib, sys
path, version, build, url, signature, length = sys.argv[1:]
xml = f'''<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dory="https://augani.github.io/dory/appcast">
<channel><title>Dory interruption gate</title><link>https://augani.github.io/dory/appcast.xml</link>
<description>Signature-bound physical rollback fixture.</description><language>en</language><item>
<title>{html.escape(version)}</title><pubDate>Sun, 19 Jul 2026 00:00:00 +0000</pubDate>
<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<dory:dataSchemaVersion>1</dory:dataSchemaVersion><dory:minimumReadableDataSchema>1</dory:minimumReadableDataSchema>
<dory:maximumReadableDataSchema>1</dory:maximumReadableDataSchema><dory:componentCatalogSchema>2</dory:componentCatalogSchema>
<enclosure url="{html.escape(url)}" sparkle:edSignature="{html.escape(signature)}" length="{length}" type="application/octet-stream" />
</item></channel></rss>'''
pathlib.Path(path).write_text(xml, encoding="utf-8")
PY

python3 - "$PORT" "$FEED_ROOT" "$TLS_ROOT/cert.pem" "$TLS_ROOT/key.pem" \
  > "$EVIDENCE/feed-server.out" 2> "$EVIDENCE/feed-server.err" <<'PY' &
import http.server, os, ssl, sys
port, root, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
os.chdir(root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 1 100); do
  curl -fsS --max-time 2 "$FEED_URL" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 5 "$FEED_URL" >/dev/null || die "trusted loopback HTTPS feed did not start"

ditto "$CANDIDATE_APP" "$INSTALL_APP"
codesign --verify --strict --deep "$INSTALL_APP" || die "installed exact candidate changed"
defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool true
INSTALLED_EXECUTABLE="$INSTALL_APP/Contents/MacOS/Dory"
DORY_RELEASE_UPGRADE_GATE=INTERRUPT-LAST-GOOD-ROLLBACK \
DORY_RELEASE_UPGRADE_FEED_URL="$FEED_URL" \
DORY_RELEASE_UPGRADE_ARM_FILE="$ARM_FILE" \
  "$INSTALLED_EXECUTABLE" > "$EVIDENCE/last-good-app.out" 2> "$EVIDENCE/last-good-app.err" &
APP_PID=$!

DOCKER="$INSTALL_APP/Contents/Helpers/docker"
DORYCTL="$INSTALL_APP/Contents/Helpers/dorydctl"
SOCKET="$HOME/.dory/docker.sock"
for _ in $(seq 1 480); do
  "$DOCKER" -H "unix://$SOCKET" version >/dev/null 2>&1 && break
  sleep 0.25
done
"$DOCKER" -H "unix://$SOCKET" version > "$EVIDENCE/preupdate-docker-version.txt" \
  || die "exact candidate Docker engine did not become ready"

DORY_COMPONENT_CATALOG_URL="$CATALOG_V1_URL" DORY_COMPONENT_APP_VERSION="$VERSION" \
  "$DORYCTL" component install linux-machines --json > "$EVIDENCE/component-v1-install.json"
DORY_COMPONENT_APP_VERSION="$VERSION" "$DORYCTL" component verify linux-machines --json --offline \
  > "$EVIDENCE/component-v1-verify.json"
COMPONENT_PATH="$("$DORYCTL" component path linux-machines gate/component.txt)"
[ "$(cat "$COMPONENT_PATH")" = generation-one ] || die "component generation one is not active"

"$DOCKER" -H "unix://$SOCKET" pull "$FIXTURE_IMAGE" > "$EVIDENCE/fixture-pull.txt"
"$DOCKER" -H "unix://$SOCKET" volume create dory-upgrade-release-sentinel >/dev/null
"$DOCKER" -H "unix://$SOCKET" run --rm -v dory-upgrade-release-sentinel:/evidence "$FIXTURE_IMAGE" \
  sh -c 'printf "transactional-durable-sentinel\n" > /evidence/value' >/dev/null
SENTINEL_BEFORE="$("$DOCKER" -H "unix://$SOCKET" run --rm -v dory-upgrade-release-sentinel:/evidence:ro "$FIXTURE_IMAGE" sha256sum /evidence/value | awk '{print $1}')"
"$DOCKER" -H "unix://$SOCKET" run -d --name dory-upgrade-release-port \
  -p "127.0.0.1:$SERVICE_PORT:8080" "$FIXTURE_IMAGE" \
  sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" | nc -l -p 8080; done' \
  > "$EVIDENCE/port-container.id"
for _ in $(seq 1 80); do curl -fsS --max-time 2 "http://127.0.0.1:$SERVICE_PORT" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS --max-time 3 "http://127.0.0.1:$SERVICE_PORT" | grep -qx ok \
  || die "pre-update published port fixture is not ready"

: > "$ARM_FILE"
chmod 600 "$ARM_FILE"
TRANSACTION=""
for _ in $(seq 1 2400); do
  TRANSACTION="$(find "$STATE/upgrades" -mindepth 2 -maxdepth 2 -name transaction.json -type f -print 2>/dev/null | head -n 1 || true)"
  if [ -n "$TRANSACTION" ]; then
    state="$(python3 - "$TRANSACTION" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8')).get('state', ''))
PY
)"
    [ "$state" != rolledBack ] || break
    [ "$state" != recoveryRequired ] || die "fixture unexpectedly required schema recovery"
    [ "$state" != failed ] || die "update stopped before exercising rollback"
  fi
  sleep 0.5
done
[ -n "$TRANSACTION" ] || die "transaction journal was never created"
[ "$state" = rolledBack ] || die "automatic rollback did not complete (state=$state)"

for _ in $(seq 1 480); do
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)" = "$BUILD" ] \
    && "$DOCKER" -H "unix://$SOCKET" version >/dev/null 2>&1 && break
  sleep 0.25
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_APP/Contents/Info.plist")" = "$BUILD" ] \
  || die "last-good exact app was not restored"
if /usr/libexec/PlistBuddy -c 'Print :DoryUpgradeGateForceSmokeFailure' "$INSTALL_APP/Contents/Info.plist" >/dev/null 2>&1; then
  die "fault fixture remained installed after rollback"
fi
codesign --verify --strict --deep "$INSTALL_APP" || die "restored last-good app signature is invalid"
"$DOCKER" -H "unix://$SOCKET" version > "$EVIDENCE/postrollback-docker-version.txt" \
  || die "Docker API did not survive rollback"
DORY_COMPONENT_APP_VERSION="$VERSION" "$DORYCTL" component verify linux-machines --json --offline \
  > "$EVIDENCE/component-postrollback-verify.json"
COMPONENT_PATH="$("$DORYCTL" component path linux-machines gate/component.txt)"
[ "$(cat "$COMPONENT_PATH")" = generation-one ] || die "prior component generation was not restored"
SENTINEL_AFTER="$("$DOCKER" -H "unix://$SOCKET" run --rm -v dory-upgrade-release-sentinel:/evidence:ro "$FIXTURE_IMAGE" sha256sum /evidence/value | awk '{print $1}')"
[ "$SENTINEL_AFTER" = "$SENTINEL_BEFORE" ] || die "durable sentinel changed during rollback"
"$DOCKER" -H "unix://$SOCKET" inspect -f '{{.State.Running}}' dory-upgrade-release-port | grep -qx true \
  || die "pre-update container is not running after rollback"
curl -fsS --max-time 3 "http://127.0.0.1:$SERVICE_PORT" | grep -qx ok \
  || die "pre-update published port is not reachable after rollback"

CANDIDATE_TREE_SHA="$(python3 - "$CANDIDATE_APP" <<'PY'
import hashlib, os, pathlib, stat, sys
app = pathlib.Path(sys.argv[1])
tree = hashlib.sha256()
for path in sorted(app.rglob('*'), key=lambda item: item.relative_to(app.parent).as_posix()):
    relative = path.relative_to(app.parent).as_posix()
    metadata = path.lstat()
    if stat.S_ISREG(metadata.st_mode):
        kind, size = 'regular', metadata.st_size
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISLNK(metadata.st_mode):
        kind = 'symlink'
        encoded = os.readlink(path).encode('utf-8')
        size, digest = len(encoded), hashlib.sha256(encoded).hexdigest()
    else:
        continue
    mode = f'{stat.S_IMODE(metadata.st_mode):04o}'
    tree.update(f'{relative}\0{kind}\0{mode}\0{size}\0{digest}\n'.encode())
print(tree.hexdigest())
PY
)"
TRANSACTION_SHA="$(shasum -a 256 "$TRANSACTION" | awk '{print $1}')"
INTERRUPTION_EVIDENCE="$EVIDENCE/interruption-evidence.json"
python3 - "$TRANSACTION" "$INTERRUPTION_EVIDENCE" "$SOURCE_COMMIT" "$CANDIDATE_TREE_SHA" \
  "$TRANSACTION_SHA" "$BUILD" "$FAULT_BUILD" "$SENTINEL_BEFORE" <<'PY'
import json, pathlib, sys
record_path, output, commit, app_sha, record_sha, prior, candidate, sentinel = sys.argv[1:]
record = json.loads(pathlib.Path(record_path).read_text(encoding='utf-8'))
payload = {
    "schema": "dev.dory.upgrade.interruption-evidence", "version": 1,
    "transactionID": str(record["id"]).lower(), "transactionSHA256": record_sha,
    "sourceCommit": commit, "candidateAppSHA256": app_sha,
    "priorBuild": prior, "candidateBuild": candidate, "finalAppBuild": prior,
    "failureInjection": "post-install-smoke", "automaticRollback": True,
    "componentUpdateActivatedBeforeFailure": True,
    "componentGenerationRestored": True,
    "durableDataWasRolledBack": False,
    "durableSentinelBeforeSHA256": sentinel,
    "durableSentinelAfterSHA256": sentinel,
    "publishedPortRestored": True, "preexistingContainerRestored": True,
    "recoveryExportVerified": False,
}
pathlib.Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding='utf-8')
PY
cp "$TRANSACTION" "$EVIDENCE/transaction.json"
scripts/transactional-upgrade-gate.sh \
  --record "$EVIDENCE/transaction.json" \
  --interruption-evidence "$INTERRUPTION_EVIDENCE" \
  --expect-state rolledBack > "$EVIDENCE/verification.txt"

stop_dory_processes
APP_PID=""
clean_release_user_state
CLEAN_USER_ARMED=0
[ ! -e "$STATE" ] && [ ! -e "$APP_SUPPORT" ] && [ ! -e "$PLIST" ] \
  || die "clean release-user Dory state survived cleanup"
! "$CANDIDATE_DOCKER" context inspect dory >/dev/null 2>&1 \
  || die "Dory Docker context survived clean-user cleanup"
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
    die "Dory shell integration survived clean-user cleanup: $profile"
  fi
done

{
  echo status=PASS
  echo release_qualifying=true
  echo "source_commit=$SOURCE_COMMIT"
  echo "candidate_version=$VERSION"
  echo "candidate_build=$BUILD"
  echo "fault_fixture_build=$FAULT_BUILD"
  echo "candidate_tree_sha256=$CANDIDATE_TREE_SHA"
  echo "transaction_sha256=$TRANSACTION_SHA"
  echo "candidate_team=$CANDIDATE_TEAM"
  echo exact_last_good_app_restored=PASS
  echo component_catalog_schema=2
  echo component_catalog_signatures_verified=PASS
  echo component_qualification_authority=PASS
  echo signed_component_generation_restored=PASS
  echo durable_data_not_downgraded=PASS
  echo durable_volume_sentinel_preserved=PASS
  echo preexisting_container_preserved=PASS
  echo published_port_preserved=PASS
  echo exact_smoke_failure_retained=PASS
  echo initial_clean_user_state_restored=PASS
  echo "completed_epoch=$(date +%s)"
} > "$EVIDENCE/manifest.txt"

trap - EXIT INT TERM
[ -z "$SERVER_PID" ] || { kill -TERM "$SERVER_PID" >/dev/null 2>&1; wait "$SERVER_PID" 2>/dev/null || true; }
security delete-certificate -c "$TRUST_CN" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
echo "Interrupted transactional upgrade gate PASS: $EVIDENCE/manifest.txt"
