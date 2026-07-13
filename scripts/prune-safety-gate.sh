#!/bin/bash
# Destructive prune contract for an explicitly empty, dedicated Dory engine.
set -euo pipefail
umask 077

SOCKET="${DORY_SOCK:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
BASE_IMAGE="${DORY_PRUNE_BASE_IMAGE:-alpine:latest}"
WORKROOT="${DORY_PRUNE_WORKROOT:-$HOME/.dory-prune-safety}"
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/prune-safety-gate.sh --confirm ISOLATED-ENGINE-PRUNE [options]

Options:
  --socket PATH      Dedicated Dory Docker socket
  --docker PATH      Docker CLI
  --base-image REF   Already-local base image (default: alpine:latest)
  --workroot PATH    Evidence root (default: ~/.dory-prune-safety)
  -h, --help

This runs unfiltered container/image/network/volume/system/builder prune commands. It refuses to
start unless the engine has zero containers, volumes, and custom networks. Never point it at a
user engine. The exact confirmation token is mandatory.
EOF
}
die() { echo "prune-safety: $*" >&2; exit 1; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$CONFIRM" = "ISOLATED-ENGINE-PRUNE" ] \
  || die "destructive prune requires --confirm ISOLATED-ENGINE-PRUNE"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable"
case "$SOCKET" in /*) ;; *) die "socket must be absolute" ;; esac
case "$WORKROOT" in /*) ;; *) die "workroot must be absolute" ;; esac
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"

docker_e() { "$DOCKER" -H "unix://$SOCKET" "$@"; }
docker_e version >/dev/null 2>&1 || die "Docker API is unreachable"
[ "$(docker_e ps -aq | wc -l | tr -d ' ')" = 0 ] || die "dedicated engine must have zero containers"
[ "$(docker_e volume ls -q | wc -l | tr -d ' ')" = 0 ] || die "dedicated engine must have zero volumes"
[ "$(docker_e network ls --filter type=custom -q | wc -l | tr -d ' ')" = 0 ] \
  || die "dedicated engine must have zero custom networks"
docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1 || die "base image must already be local: $BASE_IMAGE"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SLUG="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]')"
RUN_DIR="$WORKROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
PROTECTED_IMAGE="dory-prune-protected:$SLUG"
VICTIM_IMAGE="dory-prune-victim:$SLUG"
PROTECTED_CONTAINER="dory-prune-protected-$SLUG"
VICTIM_CONTAINER="dory-prune-victim-$SLUG"
PROTECTED_VOLUME="dory-prune-protected-$SLUG"
VICTIM_VOLUME="dory-prune-victim-$SLUG"
PROTECTED_NETWORK="dory-prune-protected-$SLUG"
VICTIM_NETWORK="dory-prune-victim-$SLUG"
LABEL="dev.dory.prune-safety=$RUN_ID"

cleanup() {
  docker_e rm -f "$PROTECTED_CONTAINER" "$VICTIM_CONTAINER" >/dev/null 2>&1 || true
  docker_e network rm "$PROTECTED_NETWORK" "$VICTIM_NETWORK" >/dev/null 2>&1 || true
  docker_e volume rm -f "$PROTECTED_VOLUME" "$VICTIM_VOLUME" >/dev/null 2>&1 || true
  docker_e image rm -f "$PROTECTED_IMAGE" "$VICTIM_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

printf 'FROM %s\nLABEL %s\nRUN printf protected-image >/image-marker\n' "$BASE_IMAGE" "$LABEL" \
  | docker_e build -q -t "$PROTECTED_IMAGE" - > "$RUN_DIR/protected-build.id"
printf 'FROM %s\nLABEL %s\nRUN printf victim-image >/image-marker\n' "$BASE_IMAGE" "$LABEL" \
  | docker_e build -q -t "$VICTIM_IMAGE" - > "$RUN_DIR/victim-build.id"
docker_e volume create --label "$LABEL" "$PROTECTED_VOLUME" >/dev/null
docker_e volume create --label "$LABEL" "$VICTIM_VOLUME" >/dev/null
docker_e network create --label "$LABEL" "$PROTECTED_NETWORK" >/dev/null
docker_e network create --label "$LABEL" "$VICTIM_NETWORK" >/dev/null
docker_e run -d --name "$PROTECTED_CONTAINER" --label "$LABEL" --network "$PROTECTED_NETWORK" \
  -v "$PROTECTED_VOLUME:/state" "$PROTECTED_IMAGE" sh -c \
  'printf protected-volume >/state/marker; exec tail -f /dev/null' >/dev/null
docker_e create --name "$VICTIM_CONTAINER" --label "$LABEL" "$VICTIM_IMAGE" true >/dev/null

curl -fsS --max-time 5 --unix-socket "$SOCKET" http://d/v1.41/system/df > "$RUN_DIR/system-df-before.json"
docker_e system prune -af --volumes > "$RUN_DIR/system-prune.txt"
docker_e container prune -f > "$RUN_DIR/container-prune.txt"
docker_e image prune -af > "$RUN_DIR/image-prune.txt"
docker_e network prune -f > "$RUN_DIR/network-prune.txt"
docker_e volume prune -af > "$RUN_DIR/volume-prune.txt"
docker_e builder prune -af > "$RUN_DIR/builder-prune.txt"
curl -fsS --max-time 5 --unix-socket "$SOCKET" http://d/v1.41/system/df > "$RUN_DIR/system-df-after.json"

docker_e inspect "$PROTECTED_CONTAINER" >/dev/null
docker_e image inspect "$PROTECTED_IMAGE" >/dev/null
docker_e volume inspect "$PROTECTED_VOLUME" >/dev/null
docker_e network inspect "$PROTECTED_NETWORK" >/dev/null
[ "$(docker_e exec "$PROTECTED_CONTAINER" cat /state/marker)" = protected-volume ] \
  || die "protected volume data changed during prune"

! docker_e inspect "$VICTIM_CONTAINER" >/dev/null 2>&1 || die "stopped victim container survived prune"
! docker_e image inspect "$VICTIM_IMAGE" >/dev/null 2>&1 || die "unused victim image survived prune"
! docker_e volume inspect "$VICTIM_VOLUME" >/dev/null 2>&1 || die "unused victim volume survived prune"
! docker_e network inspect "$VICTIM_NETWORK" >/dev/null 2>&1 || die "unused victim network survived prune"

python3 - "$RUN_DIR/system-df-after.json" <<'PY'
import json, sys
report=json.load(open(sys.argv[1], encoding="utf-8"))
cache=report.get("BuildCache") or []
if cache:
    raise SystemExit(f"builder cache survived prune: {len(cache)} records")
PY

cleanup
trap - EXIT INT TERM
printf 'prune safety gate PASS; evidence: %s\n' "$RUN_DIR"
