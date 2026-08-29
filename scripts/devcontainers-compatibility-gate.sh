#!/bin/bash
# Runs the official Dev Containers CLI against an explicitly empty, disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
VERSION="${DORY_RELEASE_DEVCONTAINERS_VERSION:-0.87.0}"
WORKROOT=""
CONFIRM=""
IMAGE=""

usage() {
  cat <<'EOF'
Usage: scripts/devcontainers-compatibility-gate.sh [required options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate runtime
  --version VERSION   Exact @devcontainers/cli npm version
  --image IMAGE       Exact digest-pinned Alpine fixture already present in Dory
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
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-DEVCONTAINERS ] \
  || die "requires --confirm ISOLATED-ENGINE-DEVCONTAINERS"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' \
  || die "--version must be an exact npm semver"
printf '%s\n' "$IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--image must be an exact digest reference"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
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
docker_e image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "required offline fixture image is missing: $IMAGE"

npm view --json "@devcontainers/cli@$VERSION" dist.integrity dist.tarball \
  > "$EVIDENCE/npm-package.json"
python3 - "$EVIDENCE/npm-package.json" "$VERSION" <<'PY'
import base64
import json
import re
import sys
import urllib.parse

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)
if not isinstance(package, dict) or set(package) != {"dist.integrity", "dist.tarball"}:
    raise SystemExit("Dev Containers npm package metadata has an unexpected shape")
integrity = package["dist.integrity"]
if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
    raise SystemExit("Dev Containers npm package has no SHA-512 integrity")
try:
    digest = base64.b64decode(integrity.removeprefix("sha512-"), validate=True)
except ValueError as error:
    raise SystemExit(f"Dev Containers npm integrity is invalid: {error}")
if len(digest) != 64:
    raise SystemExit("Dev Containers npm integrity is not SHA-512")
url = urllib.parse.urlparse(package["dist.tarball"])
expected = f"/@devcontainers/cli/-/cli-{sys.argv[2]}.tgz"
if url.scheme != "https" or url.netloc != "registry.npmjs.org" or url.path != expected \
        or url.params or url.query or url.fragment:
    raise SystemExit("Dev Containers npm tarball URL is not canonical")
PY

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

cat > "$WORKSPACE/.devcontainer/devcontainer.json" <<JSON
{
  "name": "Dory release compatibility gate",
  "image": "$IMAGE",
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export NPM_CONFIG_CACHE="$WORKROOT/.npm-cache"
npm exec --yes --package "@devcontainers/cli@$VERSION" -- devcontainer --version \
  > "$EVIDENCE/cli-version.txt"
grep -Fxq "$VERSION" "$EVIDENCE/cli-version.txt" \
  || die "executed Dev Containers CLI version does not match $VERSION"
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
fixture_image=$IMAGE
npm_package_integrity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dist.integrity"])' "$EVIDENCE/npm-package.json")
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
node_sha256=$(shasum -a 256 "$(command -v node)" | awk '{print $1}')
npm_sha256=$(shasum -a 256 "$(command -v npm)" | awk '{print $1}')
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
