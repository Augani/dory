#!/bin/bash
# Destructive prune contract for an explicitly empty, dedicated Dory engine.
set -euo pipefail
umask 077

SOCKET="${DORY_SOCK:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
BASE_IMAGE="${DORY_PRUNE_BASE_IMAGE:-}"
SOURCE_COMMIT="${DORY_PRUNE_SOURCE_COMMIT:-}"
WORKROOT="${DORY_PRUNE_WORKROOT:-$HOME/.dory-prune-safety}"
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/prune-safety-gate.sh --confirm ISOLATED-ENGINE-PRUNE [options]

Options:
  --socket PATH      Dedicated Dory Docker socket
  --docker PATH      Docker CLI
  --base-image REF   Digest-pinned, already-local base image
  --source-commit SHA Exact 40-character source commit
  --workroot PATH    Evidence root (default: ~/.dory-prune-safety)
  -h, --help

This runs unfiltered container/image/network/volume/system/builder prune commands. It refuses to
start unless the engine has zero containers, volumes, and custom networks. Never point it at a
user engine. The exact confirmation token is mandatory.
EOF
}
die() { echo "prune-safety: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$CONFIRM" = "ISOLATED-ENGINE-PRUNE" ] \
  || die "destructive prune requires --confirm ISOLATED-ENGINE-PRUNE"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect"
printf '%s\n' "$BASE_IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
case "$SOCKET" in /*) ;; *) die "socket must be absolute" ;; esac
case "$WORKROOT" in /*) ;; *) die "workroot must be absolute" ;; esac
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
for command in curl python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

docker_e() { "$DOCKER" -H "unix://$SOCKET" "$@"; }
docker_e version >/dev/null 2>&1 || die "Docker API is unreachable"
[ "$(docker_e ps -aq | wc -l | tr -d ' ')" = 0 ] || die "dedicated engine must have zero containers"
[ "$(docker_e volume ls -q | wc -l | tr -d ' ')" = 0 ] || die "dedicated engine must have zero volumes"
[ "$(docker_e network ls --filter type=custom -q | wc -l | tr -d ' ')" = 0 ] \
  || die "dedicated engine must have zero custom networks"
docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1 || die "base image must already be local: $BASE_IMAGE"
base_image_id="$(docker_e image inspect "$BASE_IMAGE" --format '{{.Id}}')"
printf '%s\n' "$base_image_id" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  || die "base image has an invalid local content ID"
local_image_ids="$(docker_e image ls -aq --no-trunc | sort -u)"
[ "$local_image_ids" = "$base_image_id" ] \
  || die "dedicated engine must contain exactly the qualified base image"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SLUG="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]')"
mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
RUN_DIR="$WORKROOT/$RUN_ID"
mkdir "$RUN_DIR"
PROTECTED_IMAGE="dory-prune-protected:$SLUG"
VICTIM_IMAGE="dory-prune-victim:$SLUG"
PROTECTED_CONTAINER="dory-prune-protected-$SLUG"
VICTIM_CONTAINER="dory-prune-victim-$SLUG"
PROTECTED_VOLUME="dory-prune-protected-$SLUG"
VICTIM_VOLUME="dory-prune-victim-$SLUG"
PROTECTED_NETWORK="dory-prune-protected-$SLUG"
VICTIM_NETWORK="dory-prune-victim-$SLUG"
LABEL="dev.dory.prune-safety=$RUN_ID"
curl -fsS --max-time 5 --unix-socket "$SOCKET" http://d/v1.41/system/df \
  > "$RUN_DIR/system-df-initial.json"
python3 - "$RUN_DIR/system-df-initial.json" "$base_image_id" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(document, dict):
    raise SystemExit("initial system-df response is not an object")
images = document.get("Images") or []
if not isinstance(images, list) or len(images) != 1 or images[0].get("Id") != sys.argv[2]:
    raise SystemExit("initial system-df does not contain exactly the qualified base image")
for key in ("Containers", "Volumes", "BuildCache"):
    records = document.get(key) or []
    if not isinstance(records, list) or records:
        raise SystemExit(f"initial system-df contains pre-existing {key}")
PY

cleanup() {
  set +e
  docker_e rm -f "$PROTECTED_CONTAINER" "$VICTIM_CONTAINER" >/dev/null 2>&1 || true
  docker_e network rm "$PROTECTED_NETWORK" "$VICTIM_NETWORK" >/dev/null 2>&1 || true
  docker_e volume rm -f "$PROTECTED_VOLUME" "$VICTIM_VOLUME" >/dev/null 2>&1 || true
  docker_e image rm -f "$PROTECTED_IMAGE" "$VICTIM_IMAGE" >/dev/null 2>&1 || true
  set -e
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

protected_image_id="$(printf 'FROM %s\nLABEL %s\nRUN printf protected-image >/image-marker\n' \
  "$BASE_IMAGE" "$LABEL" | docker_e build --network none --pull=false -q -t "$PROTECTED_IMAGE" -)"
victim_image_id="$(printf 'FROM %s\nLABEL %s\nRUN printf victim-image >/image-marker\n' \
  "$BASE_IMAGE" "$LABEL" | docker_e build --network none --pull=false -q -t "$VICTIM_IMAGE" -)"
printf '%s\n' "$protected_image_id" > "$RUN_DIR/protected-build.id"
printf '%s\n' "$victim_image_id" > "$RUN_DIR/victim-build.id"
for fixture_image_id in "$protected_image_id" "$victim_image_id"; do
  printf '%s\n' "$fixture_image_id" | grep -Eq '^sha256:[0-9a-f]{64}$' \
    || die "prune fixture build returned an invalid image ID"
done
[ "$protected_image_id" != "$victim_image_id" ] \
  || die "protected and victim fixture images unexpectedly share an ID"
[ "$(docker_e volume create --label "$LABEL" "$PROTECTED_VOLUME")" = "$PROTECTED_VOLUME" ] \
  || die "protected volume creation returned the wrong name"
[ "$(docker_e volume create --label "$LABEL" "$VICTIM_VOLUME")" = "$VICTIM_VOLUME" ] \
  || die "victim volume creation returned the wrong name"
protected_network_id="$(docker_e network create --label "$LABEL" "$PROTECTED_NETWORK")"
victim_network_id="$(docker_e network create --label "$LABEL" "$VICTIM_NETWORK")"
for fixture_network_id in "$protected_network_id" "$victim_network_id"; do
  printf '%s\n' "$fixture_network_id" | grep -Eq '^[0-9a-f]{64}$' \
    || die "prune fixture network creation returned an invalid ID"
done
protected_container_id="$(docker_e run -d --pull=never --name "$PROTECTED_CONTAINER" \
  --label "$LABEL" --network "$PROTECTED_NETWORK" \
  --mount "type=volume,src=$PROTECTED_VOLUME,dst=/state" "$PROTECTED_IMAGE" sh -c \
  'printf protected-volume >/state/marker; exec tail -f /dev/null')"
victim_container_id="$(docker_e create --pull=never --name "$VICTIM_CONTAINER" \
  --label "$LABEL" "$VICTIM_IMAGE" true)"
for fixture_container_id in "$protected_container_id" "$victim_container_id"; do
  printf '%s\n' "$fixture_container_id" | grep -Eq '^[0-9a-f]{64}$' \
    || die "prune fixture launch returned an invalid container ID"
done
docker_e inspect "$protected_container_id" "$victim_container_id" \
  > "$RUN_DIR/fixture-containers.json"
docker_e image inspect "$protected_image_id" "$victim_image_id" \
  > "$RUN_DIR/fixture-images.json"
python3 - "$RUN_DIR/fixture-containers.json" "$RUN_DIR/fixture-images.json" \
  "$LABEL" "$protected_image_id" "$victim_image_id" <<'PY'
import json
import pathlib
import sys

containers = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
images = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
label_key, label_value = sys.argv[3].split("=", 1)
if not isinstance(containers, list) or len(containers) != 2:
    raise SystemExit("prune fixture does not contain exactly two containers")
if not isinstance(images, list) or len(images) != 2:
    raise SystemExit("prune fixture does not contain exactly two images")
for item in containers + images:
    config = item.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    if not isinstance(labels, dict) or labels.get(label_key) != label_value:
        raise SystemExit("prune fixture is missing its exact ownership label")
actual_image_ids = {item.get("Image") for item in containers}
if actual_image_ids != {sys.argv[4], sys.argv[5]}:
    raise SystemExit("prune fixture containers do not bind the exact built images")
PY
[ "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] \
  || die "fixture engine contains containers outside the exact prune scenario"
[ "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] \
  || die "fixture engine contains volumes outside the exact prune scenario"
[ "$(docker_e network ls --filter type=custom -q | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] \
  || die "fixture engine contains custom networks outside the exact prune scenario"
fixture_image_ids="$(docker_e image ls -aq --no-trunc | sort -u)"
expected_fixture_image_ids="$(printf '%s\n' \
  "$base_image_id" "$protected_image_id" "$victim_image_id" | sort -u)"
[ "$fixture_image_ids" = "$expected_fixture_image_ids" ] \
  || die "fixture engine contains images outside the exact prune scenario"

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

python3 - "$RUN_DIR/system-df-after.json" "$protected_image_id" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(report, dict):
    raise SystemExit("post-prune system-df response is not an object")
cache = report.get("BuildCache") or []
if not isinstance(cache, list) or cache:
    raise SystemExit(f"builder cache survived prune: {len(cache)} records")
images = report.get("Images") or []
if not isinstance(images, list) or {item.get("Id") for item in images} != {sys.argv[2]}:
    raise SystemExit("post-prune images differ from the protected fixture image")
PY

cat > "$RUN_DIR/manifest.txt.partial" <<EOF
source_commit=$SOURCE_COMMIT
base_image=$BASE_IMAGE
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
empty_engine_precondition=PASS
exact_base_image_precondition=PASS
exact_owned_fixture=PASS
unfiltered_system_prune=PASS
unfiltered_container_prune=PASS
unfiltered_image_prune=PASS
unfiltered_network_prune=PASS
unfiltered_volume_prune=PASS
unfiltered_builder_prune=PASS
active_container_survived=PASS
active_image_survived=PASS
active_volume_survived=PASS
active_network_survived=PASS
active_volume_bytes_preserved=PASS
unused_container_removed=PASS
unused_image_removed=PASS
unused_volume_removed=PASS
unused_network_removed=PASS
build_cache_removed=PASS
EOF

cleanup
[ -z "$(docker_e ps -aq --filter "label=$LABEL")" ] \
  || die "prune gate cleanup left run-owned containers"
[ -z "$(docker_e volume ls -q --filter "label=$LABEL")" ] \
  || die "prune gate cleanup left run-owned volumes"
[ -z "$(docker_e network ls -q --filter "label=$LABEL")" ] \
  || die "prune gate cleanup left run-owned networks"
if docker_e image inspect "$PROTECTED_IMAGE" >/dev/null 2>&1 \
    || docker_e image inspect "$VICTIM_IMAGE" >/dev/null 2>&1; then
  die "prune gate cleanup left run-owned image tags"
fi
cat >> "$RUN_DIR/manifest.txt.partial" <<EOF
owned_cleanup=PASS
status=PASS
EOF
mv "$RUN_DIR/manifest.txt.partial" "$RUN_DIR/manifest.txt"
trap - EXIT INT TERM
cat "$RUN_DIR/manifest.txt"
printf 'prune safety gate PASS; evidence: %s\n' "$RUN_DIR"
