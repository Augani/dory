#!/bin/bash
# Authenticated private-registry release gate: 401 without credentials, login, pull/push,
# BuildKit registry auth + secret handling, and save/load. All Docker objects are run-scoped.
set -euo pipefail
umask 077

SOCKET="${DORY_REGISTRY_AUTH_SOCKET:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
BUILDX="${DORY_BUILDX_BIN:-}"
BASE_IMAGE="${DORY_REGISTRY_AUTH_BASE_IMAGE:-alpine:latest}"
REGISTRY_IMAGE="${DORY_REGISTRY_AUTH_IMAGE:-registry:2}"
PORT="${DORY_REGISTRY_AUTH_PORT:-$((55000 + $$ % 400))}"
WORKROOT="${DORY_REGISTRY_AUTH_WORKROOT:-$HOME/.dory-private-registry-auth}"

usage() {
  cat <<EOF
Usage: scripts/private-registry-auth-gate.sh [options]

Options:
  --socket PATH          Dedicated Dory Docker socket
  --docker PATH          Docker CLI
  --buildx PATH          Docker Buildx plugin (default: adjacent to Docker or user plugin)
  --base-image REF       Already-local build image (default: $BASE_IMAGE)
  --registry-image REF   Already-local registry image (default: $REGISTRY_IMAGE)
  --port PORT            Guest-loopback registry port (default: $PORT)
  --workroot PATH        Shared evidence directory (default: $WORKROOT)
  -h, --help

The workroot must be visible through Dory's host share. The gate never prunes and never removes
pre-existing images; it deletes only its unique containers, volume, and tags.
EOF
}

die() { echo "private-registry-auth: $*" >&2; exit 1; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --buildx) need_value "$1" "$#"; BUILDX="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --registry-image) need_value "$1" "$#"; REGISTRY_IMAGE="$2"; shift 2 ;;
    --port) need_value "$1" "$#"; PORT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

case "$SOCKET:$WORKROOT" in /*:/*) ;; *) die "socket and workroot must be absolute" ;; esac
case "$PORT" in ''|*[!0-9]*) die "port must be an integer" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be between 1024 and 65535"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable"
command -v htpasswd >/dev/null || die "htpasswd is required for the disposable bcrypt credential"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"

if [ -z "$BUILDX" ]; then
  docker_dir="$(cd "$(dirname "$DOCKER")" && pwd)"
  for candidate in "$docker_dir/docker-buildx" "$HOME/.docker/cli-plugins/docker-buildx"; do
    if [ -x "$candidate" ]; then BUILDX="$candidate"; break; fi
  done
fi
[ -x "$BUILDX" ] || die "Docker Buildx plugin is unavailable"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$WORKROOT/$RUN_ID"
CONFIG="$WORKDIR/docker-config"
UNAUTH_CONFIG="$WORKDIR/unauth-config"
AUTH="$WORKDIR/auth"
RESULTS="$WORKDIR/results.tsv"
NAME="dory-private-registry-$RUN_ID"
VOLUME="dory-private-registry-data-$RUN_ID"
SOURCE_REF="localhost:$PORT/dory-auth-probe:source"
BUILT_REF="localhost:$PORT/dory-auth-probe:built"
LOADED_REF="dory-auth-probe:$RUN_ID"
USER_NAME=doryprobe
PASSWORD="$(openssl rand -hex 16)"
mkdir -p "$CONFIG/cli-plugins" "$UNAUTH_CONFIG" "$AUTH"
ln -s "$BUILDX" "$CONFIG/cli-plugins/docker-buildx"
printf 'status\ttest\tdetail\n' > "$RESULTS"

docker_e() { DOCKER_CONFIG="$CONFIG" DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
cleanup() {
  set +e
  docker_e logs "$NAME" >> "$WORKDIR/registry.log" 2>&1
  docker_e rm -f "$NAME" >/dev/null 2>&1
  docker_e volume rm -f "$VOLUME" >/dev/null 2>&1
  for reference in "$SOURCE_REF" "$BUILT_REF" "$LOADED_REF"; do
    docker_e image rm -f "$reference" >/dev/null 2>&1
  done
  rm -f "$WORKDIR/secret.txt" "$AUTH/htpasswd" "$CONFIG/config.json"
}
trap cleanup EXIT INT TERM

docker_e version >/dev/null || die "Docker API is unreachable"
docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1 || die "missing local image: $BASE_IMAGE"
docker_e image inspect "$REGISTRY_IMAGE" >/dev/null 2>&1 || die "missing local image: $REGISTRY_IMAGE"
docker_e volume create --label "dev.dory.private-registry=$RUN_ID" "$VOLUME" >/dev/null

# Seed the registry before enabling auth. This makes the first request after the authenticated
# restart a meaningful pull of an existing manifest, not a misleading unknown-tag failure.
docker_e run -d --name "$NAME" --network host -v "$VOLUME:/var/lib/registry" \
  -e "REGISTRY_HTTP_ADDR=127.0.0.1:$PORT" "$REGISTRY_IMAGE" >/dev/null
sleep 2
[ "$(docker_e inspect --format '{{.State.Running}}' "$NAME")" = true ] \
  || die "seed registry did not bind guest port $PORT"
docker_e tag "$BASE_IMAGE" "$SOURCE_REF"
docker_e push "$SOURCE_REF" > "$WORKDIR/seed-push.out"
docker_e image rm "$SOURCE_REF" >/dev/null
docker_e rm -f "$NAME" >/dev/null

htpasswd -Bbn "$USER_NAME" "$PASSWORD" > "$AUTH/htpasswd"
docker_e run -d --name "$NAME" --network host \
  -v "$VOLUME:/var/lib/registry" -v "$AUTH:/auth:ro" \
  -e "REGISTRY_HTTP_ADDR=127.0.0.1:$PORT" \
  -e REGISTRY_AUTH=htpasswd -e 'REGISTRY_AUTH_HTPASSWD_REALM=Dory candidate gate' \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd "$REGISTRY_IMAGE" >/dev/null
sleep 2
[ "$(docker_e inspect --format '{{.State.Running}}' "$NAME")" = true ] \
  || die "authenticated registry did not bind guest port $PORT"

if DOCKER_CONFIG="$UNAUTH_CONFIG" DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull "$SOURCE_REF" \
    > "$WORKDIR/unauth.out" 2>&1; then
  die "unauthenticated pull unexpectedly succeeded"
fi
printf 'PASS\tunauthenticated pull rejected\tregistry required credentials\n' >> "$RESULTS"
printf '%s' "$PASSWORD" | docker_e login "localhost:$PORT" --username "$USER_NAME" --password-stdin >/dev/null
printf 'PASS\tauthenticated login\tDocker auth API accepted credentials\n' >> "$RESULTS"
docker_e pull "$SOURCE_REF" > "$WORKDIR/pull-source.out"
docker_e run --rm "$SOURCE_REF" true
printf 'PASS\tauthenticated pull\tprivate image ran\n' >> "$RESULTS"

SECRET_VALUE="$(openssl rand -hex 24)"
SECRET_SHA="$(printf '%s' "$SECRET_VALUE" | shasum -a 256 | awk '{print $1}')"
printf '%s' "$SECRET_VALUE" > "$WORKDIR/secret.txt"
{
  printf 'FROM %s\n' "$SOURCE_REF"
  printf 'RUN --mount=type=secret,id=probe test "$(sha256sum /run/secrets/probe | awk '\''{print $1}'\'')" = %s\n' "$SECRET_SHA"
  printf 'RUN test ! -e /run/secrets/probe\n'
} > "$WORKDIR/Dockerfile"
docker_e buildx version > "$WORKDIR/buildx-version.txt"
DOCKER_BUILDKIT=1 docker_e build --pull --secret "id=probe,src=$WORKDIR/secret.txt" \
  -t "$BUILT_REF" "$WORKDIR" > "$WORKDIR/build.out"
docker_e push "$BUILT_REF" > "$WORKDIR/push-built.out"
if docker_e history --no-trunc "$BUILT_REF" | grep -Fq "$SECRET_VALUE"; then
  die "BuildKit secret leaked into image history"
fi
printf 'PASS\tBuildKit auth and secret\tauthenticated FROM/push succeeded; secret absent from history\n' >> "$RESULTS"

docker_e save -o "$WORKDIR/built-image.tar" "$BUILT_REF"
docker_e image rm "$BUILT_REF" >/dev/null
docker_e load -i "$WORKDIR/built-image.tar" > "$WORKDIR/load.out"
docker_e tag "$BUILT_REF" "$LOADED_REF"
docker_e run --rm "$LOADED_REF" true
printf 'PASS\tsave and load\tprivate-derived image survived archive round-trip\n' >> "$RESULTS"

cleanup
trap - EXIT INT TERM
cat "$RESULTS"
echo "private registry auth gate PASS; evidence: $WORKDIR"
