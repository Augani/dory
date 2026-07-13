#!/bin/bash
# Runs checksum-pinned Tilt CI against a Docker Compose resource on an empty disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
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
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-TILT

Options:
  --version VERSION   Exact Tilt version (default: 0.37.5)
  --sha256 HASH       Archive SHA-256 (defaults to published 0.37.5 checksum for this Mac)

The gate uses Tilt CI plus Docker Compose, proves service health and two-way workspace coherence,
then runs Tilt down and returns containers, named volumes, and custom networks to zero.
EOF
}

die() { echo "Tilt compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
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
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--version must be an exact semantic version"
case "$(uname -m)" in
  arm64) ARCHIVE_ARCH=arm64; DEFAULT_SHA=d8c701ada9d3ee29c983651a8f344d8a4c13363e6c25a843b478aa4444ee6f30 ;;
  x86_64) ARCHIVE_ARCH=x86_64; DEFAULT_SHA=5db0bd3a690db4d12ddf22afbe14df5a56f0d6351731694c2e1e59158b3eb00c ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$SHA256" ]; then
  [ "$VERSION" = 0.37.5 ] || die "--sha256 is required for a non-default Tilt version"
  SHA256="$DEFAULT_SHA"
fi
printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 is invalid"
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in curl shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
WORKSPACE="$WORKROOT/workspace"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
export PATH="$(dirname "$DOCKER"):$PATH"
docker_e() { "$DOCKER" "$@"; }
custom_network_ids() { docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'; }
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
cleanup_objects() {
  local ids
  ids="$(docker_e ps -aq)"; [ -z "$ids" ] || docker_e rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker_e volume ls -q)"; [ -z "$ids" ] || docker_e volume rm -f $ids >/dev/null 2>&1 || true
  ids="$(custom_network_ids)"; [ -z "$ids" ] || docker_e network rm $ids >/dev/null 2>&1 || true
}
cleanup() {
  set +e
  if [ -x "$DOWNLOAD/tilt" ]; then
    (cd "$WORKSPACE" && "$DOWNLOAD/tilt" down --file Tiltfile) >/dev/null 2>&1 || true
  fi
  cleanup_objects
  rm -rf "$DOWNLOAD"
}
trap cleanup EXIT INT TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

archive="$DOWNLOAD/tilt.tgz"
url="https://github.com/tilt-dev/tilt/releases/download/v$VERSION/tilt.$VERSION.mac.$ARCHIVE_ARCH.tar.gz"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$archive"
printf '%s  %s\n' "$SHA256" "$archive" | shasum -a 256 -c - > "$EVIDENCE/archive-checksum.txt"
tar -xzf "$archive" -C "$DOWNLOAD" tilt
[ -x "$DOWNLOAD/tilt" ] || die "verified Tilt archive did not contain an executable"
"$DOWNLOAD/tilt" version > "$EVIDENCE/tilt-version.txt"
grep -F "$VERSION" "$EVIDENCE/tilt-version.txt" >/dev/null \
  || die "Tilt binary version differs from the requested release"

cat > "$WORKSPACE/Tiltfile" <<'TILT'
docker_compose('docker-compose.yml')
dc_resource('smoke')
TILT
cat > "$WORKSPACE/docker-compose.yml" <<'YAML'
services:
  smoke:
    image: alpine:3.22
    command:
      - sh
      - -lc
      - |
        grep -qx host-to-tilt /workspace/host-sentinel.txt
        printf 'tilt-to-host\n' > /workspace/tilt-sentinel.txt
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
container_id="$(docker_e ps -q | sed -n '1p')"
[ -n "$container_id" ] || die "Tilt CI left no healthy Compose service to inspect"
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

(cd "$WORKSPACE" && "$DOWNLOAD/tilt" down --file Tiltfile) \
  > "$EVIDENCE/tilt-down.log" 2> "$EVIDENCE/tilt-down.stderr"
cleanup_objects
rm -rf "$DOWNLOAD"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Tilt gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
tilt_version=$VERSION
tilt_archive_sha256=$SHA256
tilt_ci=PASS
docker_compose_resource=PASS
compose_health=PASS
host_to_service_workspace=PASS
service_to_host_workspace=PASS
tilt_down=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "Tilt Compose compatibility gate: PASS ($VERSION)"
