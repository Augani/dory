#!/bin/bash
# Runs checksum-pinned Tilt CI with the exact candidate Docker/Compose pair on a disposable engine.
set -euo pipefail

SOCKET=""
DOCKER=""
COMPOSE=""
IMAGE=""
VERSION="${DORY_RELEASE_TILT_VERSION:-0.37.5}"
SHA256=""
WORKROOT=""
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/tilt-compose-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate app
  --compose PATH      Exact Docker Compose plugin from the candidate app
  --image REF         Digest-pinned workload fixture already present in Dory
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-TILT

Options:
  --version VERSION   Exact Tilt version (default: 0.37.5)
  --sha256 HASH       Archive SHA-256 (defaults to the published 0.37.5 checksum for this Mac)

The gate verifies Tilt's release archive, installs only the supplied Compose plugin into a private
Docker config, runs Tilt CI against a preloaded image, proves service health and two-way workspace
coherence, then returns the engine to its exact empty container/volume/custom-network baseline.
EOF
}

die() { echo "Tilt compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --compose) need_value "$1" "$#"; COMPOSE="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --sha256) need_value "$1" "$#"; SHA256="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-TILT ] || die "requires --confirm ISOLATED-ENGINE-TILT"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
for helper_name in DOCKER COMPOSE; do
  helper_path="${!helper_name}"
  case "$helper_path" in /*) ;; *) die "$helper_name helper must be an absolute path" ;; esac
  [ -f "$helper_path" ] && [ ! -L "$helper_path" ] && [ -x "$helper_path" ] \
    || die "$helper_name helper is unavailable or indirect: $helper_path"
done
[ "$(basename "$DOCKER")" = docker ] \
  || die "candidate Docker CLI must be named docker for Tilt discovery"
[ "$(basename "$COMPOSE")" = docker-compose ] \
  || die "candidate Compose helper must be named docker-compose for Tilt discovery"
printf '%s\n' "$IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--image must be an exact digest reference"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--version must be an exact semantic version"
case "$(uname -m)" in
  arm64)
    ARCHIVE_ARCH=arm64
    DEFAULT_SHA=d8c701ada9d3ee29c983651a8f344d8a4c13363e6c25a843b478aa4444ee6f30
    ;;
  x86_64)
    ARCHIVE_ARCH=x86_64
    DEFAULT_SHA=5db0bd3a690db4d12ddf22afbe14df5a56f0d6351731694c2e1e59158b3eb00c
    ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$SHA256" ]; then
  [ "$VERSION" = 0.37.5 ] || die "--sha256 is required for a non-default Tilt version"
  SHA256="$DEFAULT_SHA"
fi
printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 is invalid"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
for command in curl python3 shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace" "$WORKROOT/download" \
  "$WORKROOT/docker-config/cli-plugins"
WORKROOT="$(cd "$WORKROOT" && pwd)"
WORKSPACE="$WORKROOT/workspace"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
PRIVATE_COMPOSE="$WORKROOT/docker-config/cli-plugins/docker-compose"
cp "$COMPOSE" "$PRIVATE_COMPOSE"
chmod 755 "$PRIVATE_COMPOSE"
[ "$(shasum -a 256 "$PRIVATE_COMPOSE" | awk '{print $1}')" = \
  "$(shasum -a 256 "$COMPOSE" | awk '{print $1}')" ] \
  || die "private Compose plugin differs from the candidate helper"
export DOCKER_CONFIG="$WORKROOT/docker-config"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
export PATH="$(dirname "$DOCKER"):/usr/bin:/bin:/usr/sbin:/sbin"
[ "$(command -v docker)" = "$DOCKER" ] || die "Tilt would not discover the exact candidate Docker CLI"
[ "$(command -v docker-compose)" = "$COMPOSE" ] \
  || die "Tilt would not discover the exact candidate Compose helper"
docker_e() { "$DOCKER" "$@"; }
docker_e version > "$EVIDENCE/docker-version.txt" || die "Docker API is not ready"
docker_e compose version > "$EVIDENCE/compose-version.txt" \
  || die "exact candidate Compose plugin is not loadable"
docker_e image inspect "$IMAGE" > "$EVIDENCE/image-inspect.json" 2>&1 \
  || die "required offline Tilt workload image is missing: $IMAGE"

custom_network_ids() {
  docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'
}
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" \
  || die "engine has pre-existing custom networks"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
PROJECT_NAME="dory_tilt_$$"
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
cleanup_project() {
  local ids
  ids="$(docker_e ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME")"
  [ -z "$ids" ] || docker_e rm -f -v $ids > "$EVIDENCE/container-cleanup.log" 2>&1 || true
  ids="$(docker_e volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME")"
  [ -z "$ids" ] || docker_e volume rm -f $ids > "$EVIDENCE/volume-cleanup.log" 2>&1 || true
  ids="$(docker_e network ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME")"
  [ -z "$ids" ] || docker_e network rm $ids > "$EVIDENCE/network-cleanup.log" 2>&1 || true
}
cleanup() {
  set +e
  if [ -x "$DOWNLOAD/tilt" ]; then
    (cd "$WORKSPACE" && "$DOWNLOAD/tilt" down --file Tiltfile) \
      > "$EVIDENCE/tilt-down-cleanup.log" 2>&1 || true
  fi
  cleanup_project
  rm -rf "$DOWNLOAD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

archive="$DOWNLOAD/tilt.tgz"
url="https://github.com/tilt-dev/tilt/releases/download/v$VERSION/tilt.$VERSION.mac.$ARCHIVE_ARCH.tar.gz"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$archive"
printf '%s  %s\n' "$SHA256" "$archive" \
  | shasum -a 256 -c - > "$EVIDENCE/archive-checksum.txt"
tar -xzf "$archive" -C "$DOWNLOAD" tilt
[ -f "$DOWNLOAD/tilt" ] && [ ! -L "$DOWNLOAD/tilt" ] && [ -x "$DOWNLOAD/tilt" ] \
  || die "verified Tilt archive did not contain a direct executable"
"$DOWNLOAD/tilt" version > "$EVIDENCE/tilt-version.txt"
python3 - "$EVIDENCE/tilt-version.txt" "$VERSION" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    output = handle.read()
pattern = rf"(?<![0-9])v?{re.escape(sys.argv[2])}(?![0-9])"
if re.search(pattern, output) is None:
    raise SystemExit("Tilt binary version differs from the requested release")
PY

cat > "$WORKSPACE/Tiltfile" <<'TILT'
docker_compose('docker-compose.yml')
dc_resource('smoke')
TILT
cat > "$WORKSPACE/docker-compose.yml" <<YAML
services:
  smoke:
    image: $IMAGE
    pull_policy: never
    command:
      - sh
      - -lc
      - |
        grep -qx host-to-tilt /workspace/host-sentinel.txt
        printf 'tilt-to-host\\n' > /workspace/tilt-sentinel.txt
        while :; do sleep 60; done
    volumes:
      - ./:/workspace
    healthcheck:
      test: ["CMD-SHELL", "grep -qx tilt-to-host /workspace/tilt-sentinel.txt"]
      interval: 1s
      timeout: 2s
      retries: 30
YAML
printf 'host-to-tilt\n' > "$WORKSPACE/host-sentinel.txt"

(cd "$WORKSPACE" && "$DOWNLOAD/tilt" ci \
  --file Tiltfile --host localhost --port 0 --timeout 5m \
  --output-snapshot-on-exit "$EVIDENCE/tilt-snapshot.json") \
  > "$EVIDENCE/tilt-ci.log" 2> "$EVIDENCE/tilt-ci.stderr"
grep -qx 'tilt-to-host' "$WORKSPACE/tilt-sentinel.txt" \
  || die "Tilt service write was not visible in the macOS workspace"
container_ids="$(docker_e ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME")"
[ "$(printf '%s\n' "$container_ids" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] \
  || die "Tilt CI did not leave exactly one owned Compose service"
container_id="$container_ids"
compose_health=""
for _ in $(seq 1 120); do
  compose_health="$(docker_e inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id")"
  [ "$compose_health" = healthy ] && break
  [ "$(docker_e inspect --format '{{.State.Running}}' "$container_id")" = true ] \
    || die "Tilt Compose service exited before health convergence"
  sleep 0.5
done
[ "$compose_health" = healthy ] || die "Tilt Compose service did not become healthy"
docker_e inspect "$container_id" > "$EVIDENCE/container-inspect.json"
python3 - "$EVIDENCE/container-inspect.json" "$IMAGE" "$PROJECT_NAME" "$WORKSPACE" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    documents = json.load(handle)
if not isinstance(documents, list) or len(documents) != 1 or not isinstance(documents[0], dict):
    raise SystemExit("Tilt Compose inspect result has an unexpected shape")
document = documents[0]
config = document.get("Config")
if not isinstance(config, dict) or config.get("Image") != sys.argv[2]:
    raise SystemExit("Tilt Compose service did not use the exact workload image")
labels = config.get("Labels")
if not isinstance(labels, dict) or labels.get("com.docker.compose.project") != sys.argv[3] \
        or labels.get("com.docker.compose.service") != "smoke":
    raise SystemExit("Tilt Compose service authority labels are not exact")
mounts = document.get("Mounts")
workspace = os.path.realpath(sys.argv[4])
matches = [mount for mount in mounts if isinstance(mount, dict) and mount.get("Destination") == "/workspace"] \
    if isinstance(mounts, list) else []
if len(matches) != 1 or matches[0].get("Type") != "bind" \
        or os.path.realpath(matches[0].get("Source", "")) != workspace \
        or matches[0].get("RW") is not True:
    raise SystemExit("Tilt Compose workspace bind is not exact and writable")
PY

(cd "$WORKSPACE" && "$DOWNLOAD/tilt" down --file Tiltfile) \
  > "$EVIDENCE/tilt-down.log" 2> "$EVIDENCE/tilt-down.stderr"
cleanup_project
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Tilt gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
tilt_version=$VERSION
tilt_archive_sha256=$SHA256
tilt_binary_sha256=$(shasum -a 256 "$DOWNLOAD/tilt" | awk '{print $1}')
workload_image=$IMAGE
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
compose_plugin_sha256=$(shasum -a 256 "$COMPOSE" | awk '{print $1}')
exact_candidate_compose=PASS
offline_workload_image=PASS
tilt_ci=PASS
docker_compose_resource=PASS
compose_health=PASS
host_to_service_workspace=PASS
service_to_host_workspace=PASS
exact_workspace_bind=PASS
tilt_down=PASS
owned_project_cleanup=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
rm -rf "$DOWNLOAD"
trap - EXIT INT TERM
echo "Tilt Compose compatibility gate: PASS ($VERSION)"
