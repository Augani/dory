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
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/private-registry-auth-gate.sh [options]

Required:
  --base-image REF       Digest-pinned, already-local build fixture
  --source-commit SHA    Exact 40-character source commit
  --confirm TOKEN        Must be ISOLATED-ENGINE-PRIVATE-REGISTRY

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

die() { echo "private-registry-auth: $*" >&2; exit 2; }
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
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-PRIVATE-REGISTRY ] \
  || die "requires --confirm ISOLATED-ENGINE-PRIVATE-REGISTRY"
case "$SOCKET:$WORKROOT" in /*:/*) ;; *) die "socket and workroot must be absolute" ;; esac
case "$PORT" in ''|*[!0-9]*) die "port must be an integer" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be between 1024 and 65535"
printf '%s\n' "$BASE_IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
printf '%s\n' "$REGISTRY_IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--registry-image must be digest-pinned"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect"
DOCKER="$(cd "$(dirname "$DOCKER")" && pwd -P)/$(basename "$DOCKER")"
command -v htpasswd >/dev/null || die "htpasswd is required for the disposable bcrypt credential"
command -v openssl >/dev/null || die "openssl is required"
command -v shasum >/dev/null || die "shasum is required"
command -v tar >/dev/null || die "tar is required"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"

if [ -z "$BUILDX" ]; then
  docker_dir="$(cd "$(dirname "$DOCKER")" && pwd -P)"
  for candidate in "$docker_dir/docker-buildx"; do
    if [ -x "$candidate" ]; then BUILDX="$candidate"; break; fi
  done
fi
case "$BUILDX" in /*) ;; *) die "Docker Buildx plugin must be an absolute path" ;; esac
[ -f "$BUILDX" ] && [ ! -L "$BUILDX" ] && [ -x "$BUILDX" ] \
  || die "Docker Buildx plugin is unavailable or indirect"
BUILDX="$(cd "$(dirname "$BUILDX")" && pwd -P)/$(basename "$BUILDX")"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
WORKDIR="$WORKROOT/$RUN_ID"
CONFIG="$WORKDIR/docker-config"
UNAUTH_CONFIG="$WORKDIR/unauth-config"
AUTH="$WORKDIR/auth"
CONTEXT="$WORKDIR/context"
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
mkdir -p "$CONFIG/cli-plugins" "$UNAUTH_CONFIG" "$AUTH" "$CONTEXT"
cp "$BUILDX" "$CONFIG/cli-plugins/docker-buildx"
chmod 0755 "$CONFIG/cli-plugins/docker-buildx"
[ -f "$CONFIG/cli-plugins/docker-buildx" ] \
  && [ ! -L "$CONFIG/cli-plugins/docker-buildx" ] \
  && [ "$(shasum -a 256 "$CONFIG/cli-plugins/docker-buildx" | awk '{print $1}')" \
       = "$(shasum -a 256 "$BUILDX" | awk '{print $1}')" ] \
  || die "isolated Buildx copy differs from the candidate plugin"
container_id=""

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
    running="$(docker_e inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)"
    [ "$running" = true ] || die "$phase registry exited before binding guest port $PORT"
    if docker_e logs "$container_id" 2>&1 | grep -Fq "listening on 127.0.0.1:$PORT"; then
      return
    fi
    sleep 0.1
  done
  die "$phase registry did not bind guest port $PORT within 10 seconds"
}
cleanup() {
  local images_absent=1
  set +e
  [ -z "$container_id" ] || docker_e logs "$container_id" >> "$WORKDIR/registry.log" 2>&1
  docker_e logout "localhost:$PORT" >/dev/null 2>&1
  [ -z "$container_id" ] || docker_e rm -f "$container_id" >/dev/null 2>&1
  docker_e ps -aq --filter "label=dev.dory.private-registry=$RUN_ID" 2>/dev/null \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f "$id" >/dev/null 2>&1 || true
      done
  docker_e volume rm -f "$VOLUME" >/dev/null 2>&1
  for reference in "$SOURCE_REF" "$BUILT_REF" "$LOADED_REF"; do
    docker_e image rm -f "$reference" >/dev/null 2>&1
  done
  for reference in "$SOURCE_REF" "$BUILT_REF" "$LOADED_REF"; do
    if docker_e image inspect "$reference" >/dev/null 2>&1; then images_absent=0; fi
  done
  if [ -z "$(docker_e ps -aq --filter "label=dev.dory.private-registry=$RUN_ID")" ] \
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
python3 - "$WORKDIR/base-image-inspect.json" "$BASE_IMAGE" \
  "$WORKDIR/registry-image-inspect.json" "$REGISTRY_IMAGE" <<'PY'
import json
import pathlib
import sys

def validate(path, reference):
    document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if not isinstance(document, list) or len(document) != 1 or not isinstance(document[0], dict):
        raise SystemExit("qualified image inspect is not one exact image")
    requested_name, requested_digest = reference.rsplit("@", 1)
    accepted_names = {requested_name}
    first = requested_name.split("/", 1)[0]
    if "/" not in requested_name:
        accepted_names.add("docker.io/library/" + requested_name)
    elif first != "localhost" and "." not in first and ":" not in first:
        accepted_names.add("docker.io/" + requested_name)
    repo_digests = document[0].get("RepoDigests")
    if not isinstance(repo_digests, list) or not any(
        value == name + "@" + requested_digest
        for name in accepted_names
        for value in repo_digests
    ):
        raise SystemExit("qualified image does not retain its exact registry authority")

validate(sys.argv[1], sys.argv[2])
validate(sys.argv[3], sys.argv[4])
PY
[ "$(docker_e volume create --label "dev.dory.private-registry=$RUN_ID" "$VOLUME")" = "$VOLUME" ] \
  || die "registry volume creation returned the wrong authority"
[ "$(docker_e volume inspect --format \
    '{{index .Labels "dev.dory.private-registry"}}' "$VOLUME")" = "$RUN_ID" ] \
  || die "registry volume is missing its exact run authority"

# Seed one private tag before restarting the same run-owned registry with authentication.
container_id="$(docker_e run -d --pull=never --name "$NAME" \
  --label "dev.dory.private-registry=$RUN_ID" --network host \
  --mount "type=volume,src=$VOLUME,dst=/var/lib/registry" \
  -e "REGISTRY_HTTP_ADDR=127.0.0.1:$PORT" "$REGISTRY_IMAGE")"
printf '%s\n' "$container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die "seed registry launch returned an invalid container ID"
wait_registry_ready seed
docker_e tag "$BASE_IMAGE" "$SOURCE_REF"
docker_e push "$SOURCE_REF" > "$WORKDIR/seed-push.out"
docker_e image rm "$SOURCE_REF" >/dev/null
docker_e rm -f "$container_id" >/dev/null
container_id=""

htpasswd -Bbn "$USER_NAME" "$PASSWORD" > "$AUTH/htpasswd"
# Distribution 2.8 opens the existing htpasswd file with write-capable flags. This directory is
# run-scoped, mode 0700 via umask, and deleted after the gate, so keep this bind writable.
container_id="$(docker_e run -d --pull=never --name "$NAME" \
  --label "dev.dory.private-registry=$RUN_ID" --network host \
  --mount "type=volume,src=$VOLUME,dst=/var/lib/registry" \
  --mount "type=bind,src=$AUTH,dst=/auth" \
  -e "REGISTRY_HTTP_ADDR=127.0.0.1:$PORT" \
  -e REGISTRY_AUTH=htpasswd -e 'REGISTRY_AUTH_HTPASSWD_REALM=Dory candidate gate' \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd "$REGISTRY_IMAGE")"
printf '%s\n' "$container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die "authenticated registry launch returned an invalid container ID"
wait_registry_ready authenticated
docker_e inspect "$container_id" > "$WORKDIR/authenticated-registry-inspect.json"
python3 - "$WORKDIR/authenticated-registry-inspect.json" "$REGISTRY_IMAGE" \
  "$RUN_ID" "$VOLUME" "$AUTH" "$PORT" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(document, list) or len(document) != 1 or not isinstance(document[0], dict):
    raise SystemExit("authenticated registry inspect is not one exact container")
container = document[0]
config = container.get("Config")
host = container.get("HostConfig")
mounts = container.get("Mounts")
if not isinstance(config, dict) or not isinstance(host, dict) or not isinstance(mounts, list):
    raise SystemExit("authenticated registry inspect omits runtime authority")
if config.get("Image") != sys.argv[2] or host.get("NetworkMode") != "host":
    raise SystemExit("authenticated registry runtime binding differs from the qualified image/network")
labels = config.get("Labels")
if not isinstance(labels, dict) or labels.get("dev.dory.private-registry") != sys.argv[3]:
    raise SystemExit("authenticated registry omits its exact run label")
expected_mounts = {
    ("volume", sys.argv[4], "/var/lib/registry", True),
    ("bind", sys.argv[5], "/auth", True),
}
actual_mounts = {
    (item.get("Type"), item.get("Name") if item.get("Type") == "volume" else item.get("Source"),
     item.get("Destination"), item.get("RW"))
    for item in mounts if isinstance(item, dict)
}
if actual_mounts != expected_mounts:
    raise SystemExit("authenticated registry mount graph differs from its exact authorities")
environment = config.get("Env")
required_environment = {
    f"REGISTRY_HTTP_ADDR=127.0.0.1:{sys.argv[6]}",
    "REGISTRY_AUTH=htpasswd",
    "REGISTRY_AUTH_HTPASSWD_REALM=Dory candidate gate",
    "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd",
}
if not isinstance(environment, list) or not required_environment.issubset(environment):
    raise SystemExit("authenticated registry environment omits its loopback/auth contract")
PY

if env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_CONFIG="$UNAUTH_CONFIG" \
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull "$SOURCE_REF" \
    > "$WORKDIR/unauth.out" 2>&1; then
  die "unauthenticated pull unexpectedly succeeded"
fi
grep -Eiq 'unauthorized|authentication required|no basic auth credentials' "$WORKDIR/unauth.out" \
  || die "unauthenticated pull failed without an authentication rejection"
printf '%s' "$PASSWORD" | docker_e login "localhost:$PORT" \
  --username "$USER_NAME" --password-stdin > "$WORKDIR/login.out"
docker_e pull "$SOURCE_REF" > "$WORKDIR/pull-source.out"
docker_e run --rm --pull=never --network none \
  --label "dev.dory.private-registry=$RUN_ID" "$SOURCE_REF" true

SECRET_VALUE="$(openssl rand -hex 24)"
SECRET_SHA="$(printf '%s' "$SECRET_VALUE" | shasum -a 256 | awk '{print $1}')"
printf '%s' "$SECRET_VALUE" > "$WORKDIR/secret.txt"
{
  printf 'FROM %s\n' "$SOURCE_REF"
  printf 'LABEL dev.dory.private-registry=%s\n' "$RUN_ID"
  printf 'RUN --mount=type=secret,id=probe test "$(sha256sum /run/secrets/probe | awk '\''{print $1}'\'')" = %s\n' "$SECRET_SHA"
  printf 'RUN test ! -e /run/secrets/probe\n'
} > "$CONTEXT/Dockerfile"
[ "$(find "$CONTEXT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" = 1 ] \
  && [ -f "$CONTEXT/Dockerfile" ] && [ ! -L "$CONTEXT/Dockerfile" ] \
  || die "BuildKit context is not the exact Dockerfile-only authority"
buildx_e build --progress plain --pull --network none \
  --secret "id=probe,src=$WORKDIR/secret.txt" \
  --cache-to "type=registry,ref=$CACHE_REF,mode=max" --load \
  -t "$BUILT_REF" -- "$CONTEXT" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err"
docker_e image rm "$BUILT_REF" >/dev/null
buildx_e build --progress plain --pull --network none \
  --secret "id=probe,src=$WORKDIR/secret.txt" \
  --cache-from "type=registry,ref=$CACHE_REF" --load \
  -t "$BUILT_REF" -- "$CONTEXT" \
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
python3 - "$WORKDIR/built-image.tar" "$SECRET_VALUE" "$PASSWORD" <<'PY'
import pathlib
import sys

archive = pathlib.Path(sys.argv[1]).read_bytes()
for value in sys.argv[2:]:
    if value.encode("utf-8") in archive:
        raise SystemExit("private registry credential or BuildKit secret leaked into the image archive")
PY
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
docker_e run --rm --pull=never --network none \
  --label "dev.dory.private-registry=$RUN_ID" "$LOADED_REF" true

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
python3 - "$WORKDIR" "$SECRET_VALUE" "$PASSWORD" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
needles = [value.encode("utf-8") for value in sys.argv[2:]]
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    content = path.read_bytes()
    if any(needle in content for needle in needles):
        raise SystemExit(f"private registry evidence retained secret bytes: {path.name}")
PY
cat >> "$WORKDIR/manifest.txt.partial" <<EOF
owned_cleanup=PASS
isolated_credential_cleanup=PASS
dockerfile_only_build_context=PASS
archive_secret_nonleak=PASS
secret_free_evidence=PASS
status=PASS
EOF
mv "$WORKDIR/manifest.txt.partial" "$WORKDIR/manifest.txt"
trap - EXIT INT TERM
cat "$WORKDIR/manifest.txt"
echo "private registry auth gate PASS; evidence: $WORKDIR"
