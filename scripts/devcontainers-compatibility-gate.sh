#!/bin/bash
# Runs the official Dev Containers CLI against an explicitly empty, disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
VERSION="${DORY_RELEASE_DEVCONTAINERS_VERSION:-0.87.0}"
WORKROOT=""
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/devcontainers-compatibility-gate.sh [required options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate runtime
  --version VERSION   Exact @devcontainers/cli npm version
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-DEVCONTAINERS

The gate refuses an engine with any existing container, named volume, or custom network. It creates
one Dev Container, proves host-to-container and container-to-host workspace coherence plus exec,
then returns the engine to the exact empty object baseline. It never uses a user's default socket.
EOF
}

die() { echo "devcontainers gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-DEVCONTAINERS ] \
  || die "requires --confirm ISOLATED-ENGINE-DEVCONTAINERS"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' \
  || die "--version must be an exact npm semver"
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in curl node npm python3; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace/.devcontainer"
WORKROOT="$(cd "$WORKROOT" && pwd)"
WORKSPACE="$WORKROOT/workspace"
EVIDENCE="$WORKROOT/evidence"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT

docker_e() { "$DOCKER" "$@"; }
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
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

cat > "$WORKSPACE/.devcontainer/devcontainer.json" <<'JSON'
{
  "name": "Dory release compatibility gate",
  "image": "alpine:3.22",
  "overrideCommand": true,
  "remoteUser": "root"
}
JSON
printf 'host-to-container:%s\n' "$VERSION" > "$WORKSPACE/host-sentinel.txt"

container_id=""
cleanup() {
  set +e
  if [ -n "$container_id" ]; then
    docker_e rm -f "$container_id" > "$EVIDENCE/container-remove.log" 2>&1 || true
  fi
  # A failed CLI invocation may have created a labeled container before its ID reached stdout.
  docker_e ps -aq --filter "label=devcontainer.local_folder=$WORKSPACE" \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f "$id" >> "$EVIDENCE/container-remove.log" 2>&1 || true
      done
  rm -rf "$WORKROOT/.npm-cache"
}
trap cleanup EXIT INT TERM

export NPM_CONFIG_CACHE="$WORKROOT/.npm-cache"
npm exec --yes --package "@devcontainers/cli@$VERSION" -- \
  devcontainer up \
    --workspace-folder "$WORKSPACE" \
    --remove-existing-container \
    --log-format json \
    > "$EVIDENCE/up.jsonl" 2> "$EVIDENCE/up.stderr"

container_id="$(docker_e ps -q | sed '/^$/d')"
[ -n "$container_id" ] || die "Dev Containers CLI created no running container"
[ "$(printf '%s\n' "$container_id" | wc -l | tr -d ' ')" = 1 ] \
  || die "Dev Containers CLI created more than one running container"
docker_e inspect "$container_id" > "$EVIDENCE/container-inspect.json"

npm exec --yes --package "@devcontainers/cli@$VERSION" -- \
  devcontainer exec --workspace-folder "$WORKSPACE" \
    sh -lc \
      "grep -qx 'host-to-container:$VERSION' host-sentinel.txt && printf 'container-to-host:%s\\n' '$VERSION' > container-sentinel.txt && printf 'exec=PASS\\n'" \
    > "$EVIDENCE/exec.txt" 2> "$EVIDENCE/exec.stderr"
grep -qx 'exec=PASS' "$EVIDENCE/exec.txt" || die "Dev Containers exec proof is missing"
grep -qx "container-to-host:$VERSION" "$WORKSPACE/container-sentinel.txt" \
  || die "container-to-host workspace write was not visible on macOS"

docker_e rm -f "$container_id" > "$EVIDENCE/container-remove.log"
container_id=""
rm -rf "$WORKROOT/.npm-cache"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Dev Containers gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
devcontainers_cli=$VERSION
official_cli_invocation=PASS
host_to_container_workspace=PASS
container_to_host_workspace=PASS
container_exec=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "Dev Containers compatibility gate: PASS ($VERSION)"
