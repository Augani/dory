#!/bin/bash
# Destructive clean-account exact-candidate performance campaign. Runs isolated/default and
# matched/interleaved comparisons, verifies every raw result, cleans all selected engine state, and
# produces the stable release evidence ZIP described by PERFORMANCE_QUALIFICATION.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_DIR=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-release-performance"
ALPINE_IMAGE="${DORY_BENCH_ALPINE_IMAGE:-}"
IPERF_IMAGE="${DORY_BENCH_IPERF_IMAGE:-}"
NODE_IMAGE="${DORY_BENCH_NODE_IMAGE:-}"
POSTGRES_IMAGE="${DORY_BENCH_POSTGRES_IMAGE:-}"
REDIS_IMAGE="${DORY_BENCH_REDIS_IMAGE:-}"
RUBY_IMAGE="${DORY_BENCH_RUBY_IMAGE:-}"
COMPOSER_IMAGE="${DORY_BENCH_COMPOSER_IMAGE:-}"
CURL_IMAGE="${DORY_BENCH_CURL_IMAGE:-}"
PROBE_URL="${DORY_BENCH_PROBE_URL:-}"
DOWNLOAD_URL="${DORY_BENCH_DOWNLOAD_URL:-}"
DOWNLOAD_BYTES="${DORY_BENCH_DOWNLOAD_BYTES:-}"
ROUNDS=9
CPUS=6
MEMORY_GB=6
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/qualify-release-performance.sh [required options]

Candidate:
  --candidate-dir DIR      Downloaded immutable release artifacts
  --version VERSION        Exact marketing version
  --build BUILD            Exact CFBundleVersion
  --source-commit SHA      Exact full source commit

Immutable fixtures (each must contain @sha256:<64 hex>):
  --alpine-image REF       Basic CPU/memory/filesystem fixture
  --iperf-image REF        Container network fixture
  --node-image REF         npm/pnpm fixture
  --postgres-image REF     Compose stack fixture
  --redis-image REF        Compose stack fixture
  --ruby-image REF         Rails/Bundler fixture
  --composer-image REF     Composer/PHP fixture
  --curl-image REF         Controlled external-network fixture

Controlled network:
  --probe-url URL          Credential-free small HTTPS endpoint
  --download-url URL       Credential-free fixed-size HTTPS endpoint
  --download-bytes N       Exact response size

Safety and output:
  --workroot DIR           New private work/evidence root
  --rounds N               Interleaved rounds, multiple of 3 and at least 9
  --confirm TOKEN          CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA
  --help                   Show this help

Live execution also requires DORY_RELEASE_CLEAN_USER=1 and DORY_RELEASE_BENCHMARK_USER=1. It must
run in a dedicated physical Apple-silicon account with no Dory, OrbStack, or Colima state. It
installs and completely purges OrbStack and Colima, deletes all Dory benchmark state, and restores
the prior Docker context. The retained output is Dory-VERSION-performance-evidence.zip.
EOF
}

die() { echo "release performance qualification: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-dir) need_value "$1" "$#"; CANDIDATE_DIR="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --alpine-image) need_value "$1" "$#"; ALPINE_IMAGE="$2"; shift 2 ;;
    --iperf-image) need_value "$1" "$#"; IPERF_IMAGE="$2"; shift 2 ;;
    --node-image) need_value "$1" "$#"; NODE_IMAGE="$2"; shift 2 ;;
    --postgres-image) need_value "$1" "$#"; POSTGRES_IMAGE="$2"; shift 2 ;;
    --redis-image) need_value "$1" "$#"; REDIS_IMAGE="$2"; shift 2 ;;
    --ruby-image) need_value "$1" "$#"; RUBY_IMAGE="$2"; shift 2 ;;
    --composer-image) need_value "$1" "$#"; COMPOSER_IMAGE="$2"; shift 2 ;;
    --curl-image) need_value "$1" "$#"; CURL_IMAGE="$2"; shift 2 ;;
    --probe-url) need_value "$1" "$#"; PROBE_URL="$2"; shift 2 ;;
    --download-url) need_value "$1" "$#"; DOWNLOAD_URL="$2"; shift 2 ;;
    --download-bytes) need_value "$1" "$#"; DOWNLOAD_BYTES="$2"; shift 2 ;;
    --rounds) need_value "$1" "$#"; ROUNDS="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA ] \
  || die "--confirm CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA is required"
[ "${DORY_RELEASE_CLEAN_USER:-0}" = 1 ] || die "DORY_RELEASE_CLEAN_USER=1 is required"
[ "${DORY_RELEASE_BENCHMARK_USER:-0}" = 1 ] || die "DORY_RELEASE_BENCHMARK_USER=1 is required"
[ -n "$CANDIDATE_DIR" ] && [ -n "$VERSION" ] && [ -n "$SOURCE_COMMIT" ] \
  || die "candidate directory, version, build, and source commit are required"
case "$BUILD" in ''|*[!0-9]*) die "build must be a positive integer" ;; esac
[ "$BUILD" -gt 0 ] || die "build must be a positive integer"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "source commit must be a full lowercase Git SHA"
case "$ROUNDS" in ''|*[!0-9]*) die "rounds must be a positive integer" ;; esac
[ "$ROUNDS" -ge 9 ] && [ $((ROUNDS % 3)) -eq 0 ] \
  || die "rounds must be at least 9 and a multiple of 3"
case "$DOWNLOAD_BYTES" in ''|*[!0-9]*) die "download bytes must be a positive integer" ;; esac
[ "$DOWNLOAD_BYTES" -gt 0 ] || die "download bytes must be a positive integer"
for pair in \
  "alpine:$ALPINE_IMAGE" "iperf:$IPERF_IMAGE" "node:$NODE_IMAGE" \
  "postgres:$POSTGRES_IMAGE" "redis:$REDIS_IMAGE" "ruby:$RUBY_IMAGE" \
  "composer:$COMPOSER_IMAGE" "curl:$CURL_IMAGE"; do
  printf '%s\n' "${pair#*:}" | grep -Eq '^.+@sha256:[0-9a-fA-F]{64}$' \
    || die "${pair%%:*} image must be immutable by sha256 digest"
done
for pair in "probe:$PROBE_URL" "download:$DOWNLOAD_URL"; do
  case "${pair#*:}" in https://*) ;; *) die "${pair%%:*} URL must use HTTPS" ;; esac
  case "${pair#*:}" in *[[:space:]@]*) die "${pair%%:*} URL must not contain whitespace, credentials, or userinfo" ;; esac
done

case "$CANDIDATE_DIR" in /*) ;; *) CANDIDATE_DIR="$ROOT/$CANDIDATE_DIR" ;; esac
[ -d "$CANDIDATE_DIR" ] && [ ! -L "$CANDIDATE_DIR" ] \
  || die "candidate directory must be direct and available"
CANDIDATE_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' \
  "$CANDIDATE_DIR")"
CANDIDATE_DIR="$(cd "$CANDIDATE_DIR" && pwd -P)"
[ "$CANDIDATE_DIR" = "$CANDIDATE_LOGICAL" ] \
  || die "candidate directory cannot have an indirect ancestor"
case "$WORKROOT" in /*) ;; *) die "workroot must be absolute" ;; esac
case "$WORKROOT" in *[[:space:]]*) die "workroot must not contain whitespace" ;; esac
WORKROOT_PARENT="$(dirname "$WORKROOT")"
WORKROOT_NAME="$(basename "$WORKROOT")"
[ "$WORKROOT_NAME" = dory-release-performance ] \
  || die "workroot must use the dedicated dory-release-performance name"
[ -d "$WORKROOT_PARENT" ] && [ ! -L "$WORKROOT_PARENT" ] \
  || die "workroot parent must be a direct directory"
WORKROOT_PARENT="$(cd "$WORKROOT_PARENT" && pwd -P)"
WORKROOT="$WORKROOT_PARENT/$WORKROOT_NAME"
TEMP_AUTHORITY="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[ -d "$TEMP_AUTHORITY" ] || die "temporary authority root is unavailable"
TEMP_AUTHORITY="$(cd "$TEMP_AUTHORITY" && pwd -P)"
case "$TEMP_AUTHORITY" in
  /|"$HOME"|"$ROOT"|"$CANDIDATE_DIR") die "unsafe temporary authority root: $TEMP_AUTHORITY" ;;
esac
case "$WORKROOT" in "$TEMP_AUTHORITY"/*) ;; *) die "workroot must be inside runner temporary storage" ;; esac
case "$WORKROOT" in /|"$HOME"|"$ROOT"|"$CANDIDATE_DIR") die "unsafe workroot: $WORKROOT" ;; esac
case "$WORKROOT/" in "$CANDIDATE_DIR/"*) die "workroot cannot be inside the candidate" ;; esac
case "$CANDIDATE_DIR/" in "$WORKROOT/"*) die "workroot cannot contain the candidate" ;; esac
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] \
  || die "physical Apple-silicon macOS is required"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested virtualization does not qualify"
case "$(sysctl -n hw.model 2>/dev/null || true)" in VirtualMac*) die "a physical Mac is required" ;; esac
for command in brew codesign ditto perl plutil python3 shasum unzip zip; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

UPDATE_ZIP="$CANDIDATE_DIR/Dory-$VERSION-app-update.zip"
SBOM="$CANDIDATE_DIR/Dory-$VERSION.cdx.json"
RELEASE_MANIFEST="$CANDIDATE_DIR/release-manifest.json"
[ -s "$UPDATE_ZIP" ] && [ -s "$SBOM" ] && [ -s "$RELEASE_MANIFEST" ] \
  || die "candidate update, SBOM, or release manifest is missing"
manifest_commit="$(python3 "$ROOT/scripts/validate-release-metadata.py" \
  "$CANDIDATE_DIR" "$VERSION" "$BUILD")" || die "candidate metadata is invalid"
[ "$manifest_commit" = "$SOURCE_COMMIT" ] || die "candidate source commit mismatch"

STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/Dory"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
PREF_DOMAIN="com.pythonxi.Dory"
ORBSTACK_STATE="$HOME/.orbstack"
COLIMA_STATE="$HOME/.colima"
LIMA_COLIMA_STATE="$HOME/.lima/colima"
for path in /Applications/Dory.app "$STATE" "$APP_SUPPORT" "$PLIST" "$ORBSTACK_STATE" \
  "$COLIMA_STATE" "$LIMA_COLIMA_STATE"; do
  [ ! -e "$path" ] || die "existing state would be destroyed: $path"
done
if brew list --cask orbstack >/dev/null 2>&1; then
  die "an existing OrbStack installation would be removed"
fi
if brew list --formula colima >/dev/null 2>&1; then
  die "an existing Colima installation would be removed"
fi
for process in Dory doryd dory-hv dory-vmm OrbStack colima limactl; do
  ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
    || die "$process is already running; use the dedicated clean benchmark account"
done
! launchctl print "gui/$(id -u)/dev.dory.doryd" >/dev/null 2>&1 \
  || die "Dory's LaunchAgent is already loaded"
! defaults read "$PREF_DOMAIN" >/dev/null 2>&1 || die "existing Dory preferences would be changed"
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  [ ! -f "$profile" ] || ! grep -Fq '# >>> dory cli >>>' "$profile" \
    || die "existing Dory shell integration would be changed: $profile"
done

mkdir -p "$WORKROOT/install" "$WORKROOT/package/raw" "$WORKROOT/logs"
chmod 700 "$WORKROOT" "$WORKROOT/install" "$WORKROOT/package" "$WORKROOT/package/raw" "$WORKROOT/logs"
APP="$WORKROOT/install/Dory.app"
ditto -x -k "$UPDATE_ZIP" "$WORKROOT/install"
[ -d "$APP" ] || die "candidate did not extract as Dory.app"
codesign --verify --strict --deep "$APP" || die "candidate signature is invalid"
xcrun stapler validate "$APP" >/dev/null || die "candidate has no notarization ticket"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || die "candidate marketing version mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] \
  || die "candidate build mismatch"

CANDIDATE_DOCKER="$APP/Contents/Helpers/docker"
[ -x "$CANDIDATE_DOCKER" ] || die "candidate Docker CLI is missing"
export PATH="$APP/Contents/Helpers:$PATH"
[ "$(command -v docker)" = "$CANDIDATE_DOCKER" ] \
  || die "benchmark Docker CLI is not bound to the exact candidate"
PREVIOUS_CONTEXT="$("$CANDIDATE_DOCKER" context show 2>/dev/null || printf default)"
[ -n "$PREVIOUS_CONTEXT" ] || PREVIOUS_CONTEXT=default
! "$CANDIDATE_DOCKER" context inspect dory >/dev/null 2>&1 \
  || die "existing Docker context dory would be changed"

ENVIRONMENT_ARMED=1
cleanup_environment() {
  local cli="$APP/Contents/Helpers/dory"
  set +e
  /usr/bin/pkill -u "$(id -u)" -x Dory >/dev/null 2>&1
  [ -x "$cli" ] && "$cli" engine sleep >/dev/null 2>&1
  [ -x "$cli" ] && "$cli" uninstall >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/dev.dory.doryd" >/dev/null 2>&1
  orb stop >/dev/null 2>&1
  orb delete-data -y >/dev/null 2>&1
  colima stop >/dev/null 2>&1
  colima delete -f >/dev/null 2>&1
  brew uninstall --cask --zap orbstack >/dev/null 2>&1 || brew uninstall --cask orbstack >/dev/null 2>&1
  brew uninstall colima >/dev/null 2>&1
  "$CANDIDATE_DOCKER" context use "$PREVIOUS_CONTEXT" >/dev/null 2>&1
  "$CANDIDATE_DOCKER" context rm -f dory >/dev/null 2>&1
  rm -rf "$STATE" "$APP_SUPPORT" "$ORBSTACK_STATE" "$COLIMA_STATE" "$LIMA_COLIMA_STATE"
  rm -f "$PLIST"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1
  /usr/bin/killall -u "$(id -un)" cfprefsd >/dev/null 2>&1
  set -e
}
on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "${ENVIRONMENT_ARMED:-0}" = 1 ]; then cleanup_environment; fi
  exit "$rc"
}
trap on_exit EXIT INT TERM

RAW="$WORKROOT/package/raw"
STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_BOOT="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')"

CAMPAIGN_PINNED_CPUS="$CPUS" CAMPAIGN_PINNED_MEM_GB="$MEMORY_GB" \
BENCH_ALPINE_IMAGE="$ALPINE_IMAGE" BENCH_IPERF_IMAGE="$IPERF_IMAGE" \
  "$ROOT/scripts/benchmark-campaign.sh" \
    --engines orbstack,colima,dory \
    --profiles pinned,default \
    --dory-app "$APP" \
    --metrics memory,cpu,network,fs \
    --runs 9 \
    --memory-count 3 \
    --work "$RAW/isolated" \
    --confirm-destructive-purge DELETE-SELECTED-ENGINE-DATA \
    > "$WORKROOT/logs/isolated.log" 2>&1
awk -F '\t' 'NR > 1 && $3 != "OK" { bad=1 } END { exit bad }' \
  "$RAW/isolated/campaign-results.tsv" || die "isolated campaign contains a failed row"
status_count="$(find "$RAW/isolated" -name status.tsv -type f -print | wc -l | tr -d ' ')"
[ "$status_count" -eq 6 ] || die "isolated campaign did not retain all six metric status files"
if find "$RAW/isolated" -name status.tsv -type f -exec awk -F '\t' '
  NR > 1 && ($1 == "FAIL" || $1 == "SKIP") { bad=1 } END { exit bad }' {} \;; then :; else
  die "isolated campaign contains a failed or skipped metric"
fi

brew install --cask orbstack > "$WORKROOT/logs/orbstack-install.log" 2>&1
brew install colima > "$WORKROOT/logs/colima-install.log" 2>&1
orb config set cpu "$CPUS" >/dev/null
orb config set memory_mib "$((MEMORY_GB * 1024))" >/dev/null
orb config set machine.docker.cpu "$CPUS" >/dev/null 2>&1 || true
orb config set machine.docker.memory_mib "$((MEMORY_GB * 1024))" >/dev/null 2>&1 || true
orb start > "$WORKROOT/logs/orbstack-start.log" 2>&1
colima start --cpu "$CPUS" --memory "$MEMORY_GB" --disk 30 \
  > "$WORKROOT/logs/colima-start.log" 2>&1
defaults write "$PREF_DOMAIN" dory.engineCPUCount -int "$CPUS"
defaults write "$PREF_DOMAIN" dory.engineMemoryMB -int "$((MEMORY_GB * 1024))"
defaults write "$PREF_DOMAIN" dory.enginePreference -string dory
open "$APP"

wait_socket() {
  local socket="$1" label="$2" waited=0
  while [ "$waited" -lt 180 ]; do
    if [ -S "$socket" ] && docker -H "unix://$socket" version >/dev/null 2>&1; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  die "$label did not become ready"
}
DORY_SOCKET="$HOME/.dory/dory.sock"
ORB_SOCKET="$HOME/.orbstack/run/docker.sock"
COLIMA_SOCKET="$HOME/.colima/default/docker.sock"
wait_socket "$DORY_SOCKET" Dory
wait_socket "$ORB_SOCKET" OrbStack
wait_socket "$COLIMA_SOCKET" Colima

for socket in "$DORY_SOCKET" "$ORB_SOCKET" "$COLIMA_SOCKET"; do
  for image in "$ALPINE_IMAGE" "$IPERF_IMAGE" "$NODE_IMAGE" "$POSTGRES_IMAGE" \
    "$REDIS_IMAGE" "$RUBY_IMAGE" "$COMPOSER_IMAGE" "$CURL_IMAGE"; do
    docker -H "unix://$socket" pull "$image" >/dev/null
    docker -H "unix://$socket" image inspect "$image" --format '{{json .RepoDigests}}' \
      | grep -Fq '"'"${image##*@}"'"' || die "an engine pulled the wrong digest for $image"
  done
done

DORY_BENCH_APP="$APP" DORY_PROCESS_PATTERN='Dory[.]app/Contents/(MacOS/Dory|Helpers/(doryd|dory-hv|dory-vmm|gvproxy))' \
BENCH_WORK="$RAW/user-workflows" BENCH_NODE_IMAGE="$NODE_IMAGE" \
BENCH_ALPINE_IMAGE="$ALPINE_IMAGE" BENCH_PG_IMAGE="$POSTGRES_IMAGE" BENCH_REDIS_IMAGE="$REDIS_IMAGE" \
  "$ROOT/scripts/benchmark-user-workflows.sh" --engines dory,orbstack,colima --rounds "$ROUNDS" \
  > "$WORKROOT/logs/user-workflows.log" 2>&1
grep -qx $'exit_code\t0' "$RAW/user-workflows/run-status.tsv" \
  || die "user workflow campaign is not PASS"

BENCH_DEV_WORK="$RAW/developer-workflows" \
  "$ROOT/scripts/benchmark-developer-workflows.sh" \
    --engines dory,orbstack,colima --rounds "$ROUNDS" \
    --ruby-image "$RUBY_IMAGE" --node-image "$NODE_IMAGE" --composer-image "$COMPOSER_IMAGE" \
  > "$WORKROOT/logs/developer-workflows.log" 2>&1
grep -qx $'status\tPASS' "$RAW/developer-workflows/run-status.tsv" \
  || die "developer workflow campaign is not PASS"

"$ROOT/scripts/benchmark-registry-npm.sh" \
  --engines dory,orbstack,colima --rounds "$ROUNDS" --image "$NODE_IMAGE" \
  --fixture "$ROOT/website" --work "$RAW/registry-npm" \
  > "$WORKROOT/logs/registry-npm.log" 2>&1
awk -F '\t' 'NR > 1 { rows++; if ($6 != "ok") bad=1 } END { exit bad || rows == 0 }' \
  "$RAW/registry-npm/samples.tsv" || die "registry npm campaign is not PASS"
[ "$(awk -F '\t' 'NR > 1 { rows++ } END { print rows + 0 }' \
  "$RAW/registry-npm/run-status.tsv")" -eq 3 ] \
  || die "registry npm campaign does not contain all three engine summaries"

"$ROOT/scripts/benchmark-external-network.sh" \
  --engines dory,orbstack,colima --rounds "$ROUNDS" --image "$CURL_IMAGE" \
  --probe-url "$PROBE_URL" --download-url "$DOWNLOAD_URL" --download-bytes "$DOWNLOAD_BYTES" \
  --work "$RAW/external-network" \
  > "$WORKROOT/logs/external-network.log" 2>&1
grep -qx $'status\tpass' "$RAW/external-network/run-status.tsv" \
  || die "external network campaign is not PASS"

cleanup_environment
ENVIRONMENT_ARMED=0
for path in "$STATE" "$APP_SUPPORT" "$PLIST" "$ORBSTACK_STATE" "$COLIMA_STATE" \
  "$LIMA_COLIMA_STATE"; do
  [ ! -e "$path" ] || die "benchmark cleanup left state behind: $path"
done
for process in Dory doryd dory-hv dory-vmm OrbStack colima limactl; do
  ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 || die "benchmark cleanup left $process running"
done
for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  [ ! -f "$profile" ] || ! grep -Fq '# >>> dory cli >>>' "$profile" \
    || die "benchmark cleanup left Dory shell integration in $profile"
done
printf 'status=PASS\nprior_docker_context=%s\nengine_state_removed=PASS\nprocesses_stopped=PASS\nprofiles_clean=PASS\n' \
  "$PREVIOUS_CONTEXT" > "$RAW/cleanup.txt"

FINISHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_BOOT_AFTER="$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')"
[ "$HOST_BOOT_AFTER" = "$HOST_BOOT" ] || die "host rebooted during the performance campaign"
RELEASE_MANIFEST_SHA="$(shasum -a 256 "$RELEASE_MANIFEST" | awk '{print $1}')"
UPDATE_SHA="$(shasum -a 256 "$UPDATE_ZIP" | awk '{print $1}')"
SBOM_SHA="$(shasum -a 256 "$SBOM" | awk '{print $1}')"
APP_TREE_SHA="$(python3 - "$SBOM" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
values = [row["value"] for row in payload["metadata"]["component"]["properties"]
          if row["name"] == "dev.dory.app.tree.sha256"]
if len(values) != 1:
    raise SystemExit("SBOM must contain exactly one app-tree digest")
print(values[0])
PY
)"

python3 - "$WORKROOT/package/manifest.json" "$VERSION" "$BUILD" "$SOURCE_COMMIT" \
  "$RELEASE_MANIFEST_SHA" "$UPDATE_SHA" "$SBOM_SHA" "$APP_TREE_SHA" \
  "$STARTED_UTC" "$FINISHED_UTC" "$HOST_BOOT" "$ROUNDS" "$CPUS" "$MEMORY_GB" <<'PY'
import json, os, platform, subprocess, sys
(path, version, build, commit, release_manifest_sha, update_sha, sbom_sha, tree_sha,
 started, finished, boot, rounds, cpus, memory_gb) = sys.argv[1:]
def output(*command):
    return subprocess.check_output(command, text=True).strip()
manifest = {
    "schemaVersion": 1,
    "kind": "dev.dory.performance-qualification",
    "status": "PASS",
    "releaseQualifying": True,
    "candidate": {
        "version": version, "build": build, "sourceCommit": commit,
        "releaseManifestSHA256": release_manifest_sha,
        "appUpdateSHA256": update_sha, "sbomSHA256": sbom_sha,
        "appTreeSHA256": tree_sha,
    },
    "host": {
        "model": output("sysctl", "-n", "hw.model"),
        "architecture": output("uname", "-m"),
        "memoryBytes": int(output("sysctl", "-n", "hw.memsize")),
        "macOSVersion": output("sw_vers", "-productVersion"),
        "macOSBuild": output("sw_vers", "-buildVersion"),
        "bootEpoch": int(boot),
        "power": output("pmset", "-g", "batt").splitlines()[0],
    },
    "configuration": {
        "engines": ["dory", "orbstack", "colima"],
        "interleavedRounds": int(rounds), "matchedVCPUs": int(cpus),
        "matchedMemoryGiB": int(memory_gb),
    },
    "campaigns": [
        "isolated", "user-workflows", "developer-workflows", "registry-npm", "external-network"
    ],
    "startedUTC": started,
    "finishedUTC": finished,
    "cleanup": "PASS",
    "methodology": "PERFORMANCE_QUALIFICATION.md",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

cp "$ROOT/PERFORMANCE_QUALIFICATION.md" "$WORKROOT/package/"
cp "$WORKROOT/logs/"*.log "$RAW/"
(cd "$WORKROOT/package" && find . -type f ! -name sha256.txt -print | LC_ALL=C sort \
  | while IFS= read -r path; do shasum -a 256 "${path#./}"; done > sha256.txt)
(cd "$WORKROOT/package" && shasum -a 256 -c sha256.txt)
PACKAGE_NAME="Dory-$VERSION-performance-evidence"
PACKAGE_ROOT="$WORKROOT/$PACKAGE_NAME"
mv "$WORKROOT/package" "$PACKAGE_ROOT"
OUTPUT="$WORKROOT/$PACKAGE_NAME.zip"
(cd "$WORKROOT" && zip -X -q -r "$OUTPUT" "$PACKAGE_NAME")
unzip -t "$OUTPUT" >/dev/null
OUTPUT_SHA="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
printf 'performance_evidence=%s\nperformance_evidence_sha256=%s\n' "$OUTPUT" "$OUTPUT_SHA"
echo "release performance qualification PASS: $OUTPUT"
