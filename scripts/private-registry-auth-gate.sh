#!/bin/bash
# Qualify authenticated registry and image lifecycle behavior on an isolated Dory engine.
set -euo pipefail
umask 077

SOCKET="${DORY_REGISTRY_AUTH_SOCKET:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
BUILDX="${DORY_BUILDX_BIN:-}"
BASE_IMAGE="${DORY_REGISTRY_AUTH_BASE_IMAGE:-}"
REGISTRY_IMAGE="${DORY_REGISTRY_AUTH_IMAGE:-registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373}"
SOURCE_COMMIT="${DORY_REGISTRY_AUTH_SOURCE_COMMIT:-}"
PORT="${DORY_REGISTRY_AUTH_PORT:-$((55000 + $$ % 400))}"
WORKROOT="${DORY_REGISTRY_AUTH_WORKROOT:-$HOME/.dory-private-registry-auth}"

usage() {
  cat <<EOF
Usage: scripts/private-registry-auth-gate.sh [options]

Required:
  --base-image REF       Digest-pinned, already-local build fixture
  --source-commit SHA    Exact 40-character source commit

Options:
  --socket PATH          Dedicated Dory Docker socket
  --docker PATH          Docker CLI
  --buildx PATH          Docker Buildx plugin (default: adjacent to Docker or user plugin)
  --registry-image REF   Digest-pinned registry fixture (default: $REGISTRY_IMAGE)
  --port PORT            Guest-loopback registry port (default: $PORT)
  --workroot PATH        Shared evidence directory (default: $WORKROOT)
  -h, --help

The gate pulls only its digest-pinned registry fixture. It removes only run-owned containers,
volume, tags, derived image, and isolated credentials. The base and registry images are retained.
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
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --port) need_value "$1" "$#"; PORT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

case "$SOCKET:$WORKROOT" in /*:/*) ;; *) die "socket and workroot must be absolute" ;; esac
case "$PORT" in ''|*[!0-9]*) die "port must be an integer" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be between 1024 and 65535"
printf '%s\n' "$BASE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
printf '%s\n' "$REGISTRY_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--registry-image must be digest-pinned"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable"
command -v htpasswd >/dev/null || die "htpasswd is required for the disposable bcrypt credential"
command -v openssl >/dev/null || die "openssl is required"
command -v shasum >/dev/null || die "shasum is required"
command -v tar >/dev/null || die "tar is required"
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
NAME="dory-private-registry-$RUN_ID"
VOLUME="dory-private-registry-data-$RUN_ID"
SOURCE_REF="localhost:$PORT/dory-auth-probe:source"
BUILT_REF="localhost:$PORT/dory-auth-probe:built"
CACHE_REF="localhost:$PORT/dory-auth-probe:cache-$RUN_ID"
LOADED_REF="dory-auth-probe:$RUN_ID"
USER_NAME=doryprobe
PASSWORD="$(openssl rand -hex 16)"
OWNED_CLEANUP=FAIL
ISOLATED_CREDENTIAL_CLEANUP=FAIL
mkdir -p "$CONFIG/cli-plugins" "$UNAUTH_CONFIG" "$AUTH"
ln -s "$BUILDX" "$CONFIG/cli-plugins/docker-buildx"

docker_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_CONFIG="$CONFIG" \
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"
}
buildx_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u BUILDKIT_HOST -u BUILDX_BUILDER -u BUILDX_CONFIG \
    DOCKER_CONFIG="$CONFIG" DOCKER_HOST="unix://$SOCKET" BUILDKIT_PROGRESS=plain \
    NO_COLOR=1 "$BUILDX" --builder default "$@"
}
wait_registry_ready() {
  local phase="$1" running
  for _ in $(seq 1 100); do
    running="$(docker_e inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null || true)"
    [ "$running" = true ] || die "$phase registry exited before binding guest port $PORT"
    if docker_e logs "$NAME" 2>&1 | grep -Fq "listening on 127.0.0.1:$PORT"; then
      return
    fi
    sleep 0.1
  done
  die "$phase registry did not bind guest port $PORT within 10 seconds"
}
cleanup() {
  local images_absent=1
  set +e
  docker_e logs "$NAME" >> "$WORKDIR/registry.log" 2>&1
  docker_e logout "localhost:$PORT" >/dev/null 2>&1
  docker_e rm -f "$NAME" >/dev/null 2>&1
  docker_e volume rm -f "$VOLUME" >/dev/null 2>&1
  for reference in "$SOURCE_REF" "$BUILT_REF" "$LOADED_REF"; do
    docker_e image rm -f "$reference" >/dev/null 2>&1
  done
  for reference in "$SOURCE_REF" "$BUILT_REF" "$LOADED_REF"; do
    if docker_e image inspect "$reference" >/dev/null 2>&1; then images_absent=0; fi
  done
  if ! docker_e inspect "$NAME" >/dev/null 2>&1 \
      && ! docker_e volume inspect "$VOLUME" >/dev/null 2>&1 \
      && [ "$images_absent" -eq 1 ]; then
    OWNED_CLEANUP=PASS
  fi
  rm -rf "$CONFIG" "$UNAUTH_CONFIG" "$AUTH" "$WORKDIR/secret.txt"
  if [ ! -e "$CONFIG" ] && [ ! -e "$UNAUTH_CONFIG" ] && [ ! -e "$AUTH" ] \
      && [ ! -e "$WORKDIR/secret.txt" ]; then
    ISOLATED_CREDENTIAL_CLEANUP=PASS
  fi
  set -e
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker_e version > "$WORKDIR/docker-version.txt" || die "Docker API is unreachable"
DOCKER_SHA256="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
BUILDX_SHA256="$(shasum -a 256 "$BUILDX" | awk '{print $1}')"
docker_e buildx version > "$WORKDIR/buildx-version.txt"
docker_e image inspect "$BASE_IMAGE" > "$WORKDIR/base-image-inspect.json" 2>&1 \
  || die "missing local image: $BASE_IMAGE"
docker_e pull --platform linux/arm64 "$REGISTRY_IMAGE" > "$WORKDIR/registry-image-pull.out"
docker_e image inspect "$REGISTRY_IMAGE" > "$WORKDIR/registry-image-inspect.json"
[ "$(docker_e image inspect --format '{{.Os}}/{{.Architecture}}' "$REGISTRY_IMAGE")" = \
    linux/arm64 ] || die "registry fixture did not resolve to linux/arm64"
docker_e volume create --label "dev.dory.private-registry=$RUN_ID" "$VOLUME" >/dev/null

# Seed one private tag before restarting the same run-owned registry with authentication.
docker_e run -d --name "$NAME" --network host -v "$VOLUME:/var/lib/registry" \
  -e "REGISTRY_HTTP_ADDR=127.0.0.1:$PORT" "$REGISTRY_IMAGE" >/dev/null
wait_registry_ready seed
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
wait_registry_ready authenticated

if env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_CONFIG="$UNAUTH_CONFIG" \
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull "$SOURCE_REF" \
    > "$WORKDIR/unauth.out" 2>&1; then
  die "unauthenticated pull unexpectedly succeeded"
fi
printf '%s' "$PASSWORD" | docker_e login "localhost:$PORT" \
  --username "$USER_NAME" --password-stdin > "$WORKDIR/login.out"
docker_e pull "$SOURCE_REF" > "$WORKDIR/pull-source.out"
docker_e run --rm "$SOURCE_REF" true

SECRET_VALUE="$(openssl rand -hex 24)"
SECRET_SHA="$(printf '%s' "$SECRET_VALUE" | shasum -a 256 | awk '{print $1}')"
printf '%s' "$SECRET_VALUE" > "$WORKDIR/secret.txt"
{
  printf 'FROM %s\n' "$SOURCE_REF"
  printf 'LABEL dev.dory.private-registry=%s\n' "$RUN_ID"
  printf 'RUN --mount=type=secret,id=probe test "$(sha256sum /run/secrets/probe | awk '\''{print $1}'\'')" = %s\n' "$SECRET_SHA"
  printf 'RUN test ! -e /run/secrets/probe\n'
} > "$WORKDIR/Dockerfile"
buildx_e build --progress plain --pull --secret "id=probe,src=$WORKDIR/secret.txt" \
  --cache-to "type=registry,ref=$CACHE_REF,mode=max" --load \
  -t "$BUILT_REF" -- "$WORKDIR" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err"
docker_e image rm "$BUILT_REF" >/dev/null
buildx_e build --progress plain --pull --secret "id=probe,src=$WORKDIR/secret.txt" \
  --cache-from "type=registry,ref=$CACHE_REF" --load \
  -t "$BUILT_REF" -- "$WORKDIR" \
  > "$WORKDIR/cache-import-build.out" 2> "$WORKDIR/cache-import-build.err"
grep -q 'CACHED' "$WORKDIR/cache-import-build.out" "$WORKDIR/cache-import-build.err" \
  || die "authenticated registry cache import did not reuse the exported result"
docker_e push "$BUILT_REF" > "$WORKDIR/push-built.out"
docker_e image inspect "$BUILT_REF" > "$WORKDIR/built-image-inspect.json"
docker_e history --no-trunc "$BUILT_REF" > "$WORKDIR/built-image-history.txt"
if grep -Fq "$SECRET_VALUE" "$WORKDIR/built-image-history.txt"; then
  die "BuildKit secret leaked into image history"
fi

IMAGE_ID_BEFORE="$(docker_e image inspect --format '{{.Id}}' "$BUILT_REF")"
docker_e save -o "$WORKDIR/built-image.tar" "$BUILT_REF"
ARCHIVE_SHA256="$(shasum -a 256 "$WORKDIR/built-image.tar" | awk '{print $1}')"
tar -tf "$WORKDIR/built-image.tar" > "$WORKDIR/built-image-tar-list.txt"
grep -qx 'manifest.json' "$WORKDIR/built-image-tar-list.txt" \
  || die "saved image archive has no manifest.json"
docker_e image rm "$BUILT_REF" > "$WORKDIR/remove-before-load.out"
if docker_e image inspect "$BUILT_REF" >/dev/null 2>&1; then
  die "removed image tag remained inspectable"
fi
docker_e load -i "$WORKDIR/built-image.tar" > "$WORKDIR/load.out"
IMAGE_ID_AFTER="$(docker_e image inspect --format '{{.Id}}' "$BUILT_REF")"
[ "$IMAGE_ID_AFTER" = "$IMAGE_ID_BEFORE" ] || die "save/load changed the image identity"
docker_e tag "$BUILT_REF" "$LOADED_REF"
docker_e image inspect "$LOADED_REF" > "$WORKDIR/loaded-image-inspect.json"
docker_e history --no-trunc "$LOADED_REF" > "$WORKDIR/loaded-image-history.txt"
if grep -Fq "$SECRET_VALUE" "$WORKDIR/loaded-image-history.txt"; then
  die "BuildKit secret appeared after image load"
fi
docker_e run --rm "$LOADED_REF" true

# Make only the uniquely labeled derived image dangling, then prove filtered prune removes it.
docker_e image rm "$LOADED_REF" >/dev/null
docker_e image rm "$BUILT_REF" >/dev/null
docker_e image prune --force --filter "label=dev.dory.private-registry=$RUN_ID" \
  > "$WORKDIR/image-prune.out"
if docker_e image inspect "$IMAGE_ID_BEFORE" >/dev/null 2>&1; then
  die "filtered image prune retained the run-owned derived image"
fi

cat > "$WORKDIR/manifest.txt.partial" <<EOF
source_commit=$SOURCE_COMMIT
base_image=$BASE_IMAGE
registry_image=$REGISTRY_IMAGE
docker_cli_sha256=$DOCKER_SHA256
buildx_cli_sha256=$BUILDX_SHA256
archive_sha256=$ARCHIVE_SHA256
image_id_before=$IMAGE_ID_BEFORE
image_id_after=$IMAGE_ID_AFTER
registry_fixture_arm64=PASS
unauthenticated_pull_rejected=PASS
authenticated_login=PASS
authenticated_pull_run=PASS
buildkit_registry_auth=PASS
buildkit_secret_nonleak=PASS
buildkit_registry_cache_export=PASS
buildkit_registry_cache_import=PASS
registry_push=PASS
image_inspect_history=PASS
image_save_load_identity=PASS
image_tag_remove=PASS
filtered_image_prune=PASS
EOF

cleanup
[ "$OWNED_CLEANUP" = PASS ] || die "run-owned Docker object cleanup failed"
[ "$ISOLATED_CREDENTIAL_CLEANUP" = PASS ] || die "isolated credential cleanup failed"
cat >> "$WORKDIR/manifest.txt.partial" <<EOF
owned_cleanup=PASS
isolated_credential_cleanup=PASS
status=PASS
EOF
mv "$WORKDIR/manifest.txt.partial" "$WORKDIR/manifest.txt"
trap - EXIT INT TERM
cat "$WORKDIR/manifest.txt"
echo "private registry auth gate PASS; evidence: $WORKDIR"
