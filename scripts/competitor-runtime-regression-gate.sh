#!/bin/bash
# Live, run-scoped regressions for competitor failures involving published ports, forwarded-
# connection descriptor leaks, concurrent-proxy head-of-line blocking, wedged container operations,
# missing-source docker cp, complete Compose v2 lifecycle semantics, restrictive bind creates,
# healthchecks, named BuildKit contexts, BuildKit cache round-trips and cancellation recovery,
# resolver search leakage, network-scoped aliases/restart IP continuity, named-volume copy, clean
# image archive streams, missing-parent hard links, default BuildKit ARG expansion, exact Docker
# ignore precedence, and named volumes.
set -euo pipefail

SOCKET="${DORY_COMPAT_SOCKET:-$HOME/.dory/dory.sock}"
STATE_DIR="${DORY_COMPAT_STATE_DIR:-$(dirname "$SOCKET")}"
ALPINE_IMAGE="${DORY_COMPAT_ALPINE_IMAGE:-alpine:latest}"
WORKROOT="${DORY_COMPAT_WORKROOT:-$HOME/.dory-compatibility}"
CONNECTIONS="${DORY_COMPAT_CONNECTIONS:-2000}"
RESTARTS="${DORY_COMPAT_RESTARTS:-20}"
FD_GROWTH_BUDGET="${DORY_COMPAT_FD_GROWTH_BUDGET:-8}"
DOCKER_BIN="${DORY_COMPAT_DOCKER_BIN:-docker}"
COMPOSE_BIN="${DORY_COMPAT_COMPOSE_BIN:-}"
BUILDX_BIN="${DORY_COMPAT_BUILDX_BIN:-}"
RUNTIME="${DORY_COMPAT_RUNTIME:-}"
RUNTIME_HOME="${DORY_COMPAT_RUNTIME_HOME:-$(dirname "$STATE_DIR")}"
SOURCE_COMMIT="${DORY_COMPAT_SOURCE_COMMIT:-}"

usage() {
  cat <<EOF
Usage: scripts/competitor-runtime-regression-gate.sh [options]

Options:
  --socket PATH         Dory Docker socket (default: ~/.dory/dory.sock)
  --state-dir PATH      State path used to identify the exact engine processes
  --image REF           Existing offline Alpine image (default: alpine:latest)
  --workroot PATH       Evidence root (default: ~/.dory-compatibility)
  --connections N       Sequential published-port connections (default: $CONNECTIONS)
  --restarts N          Container restart-churn cycles (default: $RESTARTS)
  --fd-growth N         Aggregate post-connection FD budget (default: $FD_GROWTH_BUDGET)
  --docker PATH         Docker CLI to qualify (default: docker from PATH)
  --compose PATH        Compose v2 executable to qualify (default: Docker CLI plugin)
  --buildx PATH         Buildx executable to qualify (default: Docker CLI plugin)
  --runtime PATH        Optional standalone dory-engine launcher for an engine-restart test
  --runtime-home PATH   Isolated HOME owned by that launcher (default: parent of state dir)
  --source-commit SHA   Exact 40-character source commit for release-artifact evidence
  -h, --help

The gate never pulls an image. Every container, volume, Compose project, and built image is
uniquely named and cleaned by exact run ownership. It refuses to run without a live socket and
the requested offline image.
EOF
}

die() { echo "competitor-runtime-gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --state-dir) need_value "$1" "$#"; STATE_DIR="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; ALPINE_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --connections) need_value "$1" "$#"; CONNECTIONS="$2"; shift 2 ;;
    --restarts) need_value "$1" "$#"; RESTARTS="$2"; shift 2 ;;
    --fd-growth) need_value "$1" "$#"; FD_GROWTH_BUDGET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER_BIN="$2"; shift 2 ;;
    --compose) need_value "$1" "$#"; COMPOSE_BIN="$2"; shift 2 ;;
    --buildx) need_value "$1" "$#"; BUILDX_BIN="$2"; shift 2 ;;
    --runtime) need_value "$1" "$#"; RUNTIME="$2"; shift 2 ;;
    --runtime-home) need_value "$1" "$#"; RUNTIME_HOME="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}
nonnegative_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer" ;; esac
}
positive_integer connections "$CONNECTIONS"
positive_integer restarts "$RESTARTS"
nonnegative_integer fd-growth "$FD_GROWTH_BUDGET"
if [ -n "$SOURCE_COMMIT" ]; then
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || die "source commit must be a full lowercase Git SHA"
else
  SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
fi

for command in cmp curl lsof mkfifo ps python3 shasum stat tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
if [[ "$DOCKER_BIN" == */* ]]; then
  [ -x "$DOCKER_BIN" ] || die "Docker CLI is not executable: $DOCKER_BIN"
else
  command -v "$DOCKER_BIN" >/dev/null || die "Docker CLI is unavailable: $DOCKER_BIN"
fi
if [ -n "$COMPOSE_BIN" ]; then
  if [[ "$COMPOSE_BIN" == */* ]]; then
    [ -x "$COMPOSE_BIN" ] || die "Compose v2 helper is not executable: $COMPOSE_BIN"
  else
    command -v "$COMPOSE_BIN" >/dev/null || die "Compose v2 helper is unavailable: $COMPOSE_BIN"
  fi
fi
if [ -n "$BUILDX_BIN" ]; then
  if [[ "$BUILDX_BIN" == */* ]]; then
    [ -x "$BUILDX_BIN" ] || die "Buildx helper is not executable: $BUILDX_BIN"
  else
    command -v "$BUILDX_BIN" >/dev/null || die "Buildx helper is unavailable: $BUILDX_BIN"
  fi
fi
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -d "$STATE_DIR" ] || die "Dory state directory is unavailable: $STATE_DIR"
mkdir -p "$WORKROOT"

docker_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_HOST="unix://$SOCKET" \
    "$DOCKER_BIN" "$@"
}
compose_e() {
  if [ -n "$COMPOSE_BIN" ]; then
    env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
      -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
      -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u COMPOSE_FILE -u COMPOSE_PATH_SEPARATOR \
      DOCKER_HOST="unix://$SOCKET" COMPOSE_MENU=0 "$COMPOSE_BIN" "$@"
  else
    env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
      -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
      -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u COMPOSE_FILE -u COMPOSE_PATH_SEPARATOR \
      DOCKER_HOST="unix://$SOCKET" COMPOSE_MENU=0 "$DOCKER_BIN" compose "$@"
  fi
}
buildx_e() {
  local -a command
  if [ -n "$BUILDX_BIN" ]; then
    command=("$BUILDX_BIN")
  else
    command=("$DOCKER_BIN" buildx)
  fi
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u BUILDKIT_HOST -u BUILDKIT_COLORS -u BUILDX_BUILDER \
    -u BUILDX_CONFIG -u BUILDX_EXPERIMENTAL -u BUILDX_NO_DEFAULT_LOAD \
    DOCKER_HOST="unix://$SOCKET" BUILDKIT_PROGRESS=plain NO_COLOR=1 \
    "${command[@]}" "$@"
}
docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
docker_e image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 \
  || die "required offline image is missing: $ALPINE_IMAGE"
compose_e version >/dev/null 2>&1 || die "Docker Compose v2 is unavailable"
buildx_e version >/dev/null 2>&1 || die "Docker Buildx is unavailable"
if [ -n "$RUNTIME" ]; then
  [ -x "$RUNTIME" ] || die "standalone runtime is not executable: $RUNTIME"
  [ -d "$RUNTIME_HOME" ] || die "standalone runtime HOME is unavailable: $RUNTIME_HOME"
  runtime_home_real="$(cd "$RUNTIME_HOME" && pwd -P)"
  workroot_real="$(cd "$WORKROOT" && pwd -P)"
  # The standalone launcher exposes only its HOME to the Linux guest. A bind fixture outside that
  # root is silently just a guest-rootfs path from dockerd's point of view and cannot prove host
  # coherence, so reject the invalid qualification topology before creating Docker objects.
  case "$workroot_real/" in
    "$runtime_home_real/"*) ;;
    *) die "standalone bind fixture workroot must be inside runtime HOME: $RUNTIME_HOME" ;;
  esac
  preexisting_containers="$(docker_e ps -aq)"
  [ -z "$preexisting_containers" ] \
    || die "engine restart test requires an isolated engine with zero pre-existing containers"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]')"
OWNER="dory-compat-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
MANIFEST="$WORKDIR/manifest.txt"
SERVER_A="$OWNER-server-a"
SERVER_B="$OWNER-server-b"
BACKPRESSURE_CONTAINER="$OWNER-backpressure"
HEALTH_CONTAINER="$OWNER-health"
UNHEALTHY_CONTAINER="$OWNER-unhealthy"
NO_HEALTH_CONTAINER="$OWNER-no-health"
VOLUME="$OWNER-volume"
VOLUME_CP_CONTAINER="$OWNER-volume-cp"
VOLUME_METADATA="$OWNER-volume-metadata"
BUILD_TAG="dory-compatibility:$RUN_ID"
RELATIVE_BUILD_TAG="dory-relative-build:$RUN_ID"
DOCKERIGNORE_BUILD_TAG="dory-dockerignore-build:$RUN_ID"
LARGE_DOCKERFILE_BUILD_TAG="dory-large-dockerfile:$RUN_ID"
DEFAULT_ARG_BASE_REPOSITORY="dory-default-arg-base-$SAFE_RUN_ID"
DEFAULT_ARG_BUILD_TAG="dory-default-arg-build:$RUN_ID"
HARDLINK_IMPORT_TAG="dory-hardlink-import:$RUN_ID"
HARDLINK_IMPORT_CONTAINER="$OWNER-hardlink-import"
PARALLEL_BUILD_REPOSITORY="dory-parallel-build"
BUILDKIT_CACHE_TAG="dory-buildkit-cache:$RUN_ID"
BUILDKIT_RECOVERY_TAG="dory-buildkit-recovery:$RUN_ID"
BUILDKIT_CANCEL_TAG="dory-buildkit-cancel:$RUN_ID"
ROUTE_NETWORK="$OWNER-route"
CONFLICT_NETWORK="$OWNER-route-conflict"
ALIAS_NETWORK="$OWNER-alias"
NETWORK_METADATA="$OWNER-network-metadata"
NETWORK_METADATA_OCTET=$((($$ % 200) + 20))
NETWORK_METADATA_SUBNET="198.18.${NETWORK_METADATA_OCTET}.0/24"
NETWORK_METADATA_RANGE="198.18.${NETWORK_METADATA_OCTET}.128/25"
NETWORK_METADATA_GATEWAY="198.18.${NETWORK_METADATA_OCTET}.1"
NETWORK_METADATA_RESERVED="198.18.${NETWORK_METADATA_OCTET}.2"
NETWORK_METADATA_STATIC_IP="198.18.${NETWORK_METADATA_OCTET}.129"
ALIAS_CONTAINER="$OWNER-alias-server"
PORT_COLLISION_CONTAINER="$OWNER-port-collision"
SIGNAL_CONTAINER="$OWNER-signal"
LIFECYCLE_CONTAINER="$OWNER-lifecycle"
ATTACH_CONTAINER="$OWNER-attach-wait"
EXIT_CODE_CONTAINER="$OWNER-exit-code"
MOUNT_OPTION_CONTAINER="$OWNER-mount-option"
READ_ONLY_MOUNT_CONTAINER="$OWNER-mount-read-only"
HOST_COLLISION_PID=""
COMPOSE_PROJECT="$(printf 'dorycompat%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c 1-48)"
COMPOSE_EXTERNAL_NETWORK="$OWNER-compose-external"
mkdir -p "$WORKDIR"
GATE_COMPLETED=0
printf 'test\tstatus\tdetail\n' > "$RESULTS"
{
  echo "run_id=$RUN_ID"
  echo "owner=$OWNER"
  echo "socket=$SOCKET"
  echo "state_dir=$STATE_DIR"
  echo "image=$ALPINE_IMAGE"
  echo "connections=$CONNECTIONS"
  echo "restarts=$RESTARTS"
  echo "fd_growth_budget=$FD_GROWTH_BUDGET"
  echo "docker_bin=$DOCKER_BIN"
  echo "compose_bin=${COMPOSE_BIN:-docker-cli-plugin}"
  echo "buildx_bin=${BUILDX_BIN:-docker-cli-plugin}"
  echo "runtime=${RUNTIME:-none}"
  echo "runtime_home=$RUNTIME_HOME"
  [ -z "$SOURCE_COMMIT" ] || echo "source_commit=$SOURCE_COMMIT"
  echo "started_epoch=$(date +%s)"
} > "$MANIFEST"
docker_bin_resolved="$DOCKER_BIN"
case "$docker_bin_resolved" in
  */*) ;;
  *) docker_bin_resolved="$(command -v "$docker_bin_resolved")" ;;
esac
compose_bin_resolved="$COMPOSE_BIN"
if [ -n "$compose_bin_resolved" ]; then
  case "$compose_bin_resolved" in
    */*) ;;
    *) compose_bin_resolved="$(command -v "$compose_bin_resolved")" ;;
  esac
fi
buildx_bin_resolved="$BUILDX_BIN"
if [ -n "$buildx_bin_resolved" ]; then
  case "$buildx_bin_resolved" in
    */*) ;;
    *) buildx_bin_resolved="$(command -v "$buildx_bin_resolved")" ;;
  esac
fi
{
  echo "docker_bin_resolved=$docker_bin_resolved"
  echo "docker_bin_sha256=$(shasum -a 256 "$docker_bin_resolved" | awk '{print $1}')"
  if [ -n "$compose_bin_resolved" ]; then
    echo "compose_bin_resolved=$compose_bin_resolved"
    echo "compose_bin_sha256=$(shasum -a 256 "$compose_bin_resolved" | awk '{print $1}')"
  else
    echo "compose_bin_resolved=docker-cli-plugin"
  fi
  if [ -n "$buildx_bin_resolved" ]; then
    echo "buildx_bin_resolved=$buildx_bin_resolved"
    echo "buildx_bin_sha256=$(shasum -a 256 "$buildx_bin_resolved" | awk '{print $1}')"
  else
    echo "buildx_bin_resolved=docker-cli-plugin"
  fi
  if [ -n "$RUNTIME" ]; then
    runtime_dir="$(cd "$(dirname "$RUNTIME")" && pwd -P)"
    for runtime_file in \
      dory-engine \
      bin/dory-hv \
      bin/gvproxy \
      bin/dory-dataplane-proxy \
      share/dory/dory-hv-kernel-arm64.lzfse \
      share/dory/dory-engine-rootfs.ext4.lzfse \
      share/dory/dory-agent-linux-arm64; do
      [ -f "$runtime_dir/$runtime_file" ] || continue
      runtime_key="$(printf '%s' "$runtime_file" | tr '/.-' '___')_sha256"
      echo "$runtime_key=$(shasum -a 256 "$runtime_dir/$runtime_file" | awk '{print $1}')"
    done
  fi
} >> "$MANIFEST"

cleanup() {
  if [ -n "${CANCEL_BUILDX_PID:-}" ]; then
    kill -TERM "$CANCEL_BUILDX_PID" >/dev/null 2>&1 || true
    sleep 0.2
    kill -KILL "$CANCEL_BUILDX_PID" >/dev/null 2>&1 || true
    wait "$CANCEL_BUILDX_PID" 2>/dev/null || true
    CANCEL_BUILDX_PID=""
  fi
  if [ -n "${buildkit_cache_dir:-}" ]; then
    rm -rf "$buildkit_cache_dir"
  fi
  if [ -n "$HOST_COLLISION_PID" ]; then
    kill "$HOST_COLLISION_PID" >/dev/null 2>&1 || true
    wait "$HOST_COLLISION_PID" 2>/dev/null || true
    HOST_COLLISION_PID=""
  fi
  if [ "$GATE_COMPLETED" -eq 0 ] && [ -n "$RUNTIME" ]; then
    # A failed bounded API probe can leave /_ping alive while object endpoints are wedged. The
    # zero-preexisting-container guard makes a bounded isolated restart the safest cleanup path.
    bounded_capture 30 "$WORKDIR/failure-recovery-stop.out" "$WORKDIR/failure-recovery-stop.err" \
      env HOME="$RUNTIME_HOME" "$RUNTIME" stop || true
    bounded_capture 60 "$WORKDIR/failure-recovery-start.out" "$WORKDIR/failure-recovery-start.err" \
      env HOME="$RUNTIME_HOME" "$RUNTIME" start || true
  fi
  # If the gate is interrupted between its explicit stop/start operations, recover the isolated
  # engine before attempting object cleanup. The zero-preexisting-container guard above makes this
  # recovery path safe for the only mode in which the gate is allowed to control the runtime.
  if [ -n "$RUNTIME" ] && { [ ! -S "$SOCKET" ] \
      || ! curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null 2>&1; }; then
    HOME="$RUNTIME_HOME" "$RUNTIME" start >/dev/null 2>&1 || true
  fi
  [ -S "$SOCKET" ] \
    && curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null 2>&1 \
    || return 0
  compose_e --project-directory "$WORKDIR" --env-file "$WORKDIR/.env" \
    -p "$COMPOSE_PROJECT" -f "$WORKDIR/compose.yaml" -f "$WORKDIR/compose.override.yaml" \
    --profile '*' down -v --remove-orphans \
    >/dev/null 2>&1 || true
  local id
  docker_e ps -aq --filter "label=dev.dory.compatibility=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
  docker_e volume rm -f "$VOLUME" "$VOLUME_METADATA" >/dev/null 2>&1 || true
  docker_e volume ls -q --filter "label=dev.dory.compatibility=$OWNER" 2>/dev/null \
    | while IFS= read -r id; do
        [ -n "$id" ] && docker_e volume rm -f "$id" >/dev/null 2>&1 || true
      done
  docker_e network rm "$CONFLICT_NETWORK" >/dev/null 2>&1 || true
  docker_e network rm "$ROUTE_NETWORK" >/dev/null 2>&1 || true
  docker_e network rm "$ALIAS_NETWORK" >/dev/null 2>&1 || true
  docker_e network rm "$NETWORK_METADATA" >/dev/null 2>&1 || true
  docker_e network ls -q --filter "label=dev.dory.compatibility=$OWNER" 2>/dev/null \
    | while IFS= read -r id; do
        [ -n "$id" ] && docker_e network rm "$id" >/dev/null 2>&1 || true
      done
  docker_e image rm -f "$BUILD_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$RELATIVE_BUILD_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$DOCKERIGNORE_BUILD_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$LARGE_DOCKERFILE_BUILD_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$DEFAULT_ARG_BUILD_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$DEFAULT_ARG_BASE_REPOSITORY:latest" >/dev/null 2>&1 || true
  docker_e image rm -f "$HARDLINK_IMPORT_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$BUILDKIT_CACHE_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$BUILDKIT_RECOVERY_TAG" >/dev/null 2>&1 || true
  docker_e image rm -f "$BUILDKIT_CANCEL_TAG" >/dev/null 2>&1 || true
  local parallel_index
  for parallel_index in 1 2 3 4; do
    docker_e image rm -f "$PARALLEL_BUILD_REPOSITORY:$RUN_ID-$parallel_index" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

pass() { printf '%s\tPASS\t%s\n' "$1" "$2" >> "$RESULTS"; }

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_http() {
  local port="$1" expected="$2" attempts=100 body
  while [ "$attempts" -gt 0 ]; do
    body="$(curl -fsS --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null || true)"
    [ "$body" = "$expected" ] && return 0
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

bounded_capture() {
  local limit="$1" stdout="$2" stderr="$3" pid started rc
  shift 3
  "$@" > "$stdout" 2> "$stderr" &
  pid=$!
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}

candidate_pids() {
  ps axww -o pid=,command= | awk -v state="$STATE_DIR" -v socket="$SOCKET" '
    (index($0, state) || index($0, socket)) &&
    ($0 ~ /\/dory-hv / || $0 ~ /\/gvproxy / || $0 ~ /\/dory-dataplane-proxy /) { print $1 }
  '
}

sample_fds() {
  local output="$1" pid count=0 total=0
  : > "$output"
  for pid in $(candidate_pids); do
    kill -0 "$pid" 2>/dev/null || continue
    count="$(lsof -n -P -p "$pid" 2>/dev/null | awk 'NR > 1 {n++} END {print n+0}')"
    printf '%s\t%s\n' "$pid" "$count" >> "$output"
    total=$((total + count))
  done
  [ -s "$output" ] || die "no exact Dory engine processes matched $STATE_DIR"
  echo "$total"
}

# Alpine's BusyBox build does not guarantee the optional httpd applet. Its nc applet is part of the
# pinned runtime surface. Its `-lk -e` mode keeps the listening socket open while it starts one
# response helper per connection, avoiding a fixture-side relisten gap during the 2,000-connection
# burst that is meant to measure Dory rather than BusyBox scheduling.
server_command='export DORY_HTTP_BODY="$1"; printf "%s\n" "#!/bin/sh" "awk '\''length() <= 1 { exit }'\'' >/dev/null" "length=\$((\${#DORY_HTTP_BODY} + 1))" "printf \"HTTP/1.1 200 OK\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\n\\r\\n%s\\n\" \"\$length\" \"\$DORY_HTTP_BODY\"" > /tmp/dory-http; chmod 755 /tmp/dory-http; exec nc -lk -p 8080 -e /tmp/dory-http'
port="$(free_port)"
docker_e run -d --name "$SERVER_A" --label "dev.dory.compatibility=$OWNER" \
  -p "127.0.0.1:$port:8080" "$ALPINE_IMAGE" sh -c "$server_command" sh server-a >/dev/null
wait_http "$port" server-a || die "initial published port did not become reachable"
docker_e create --name "$SERVER_B" --label "dev.dory.compatibility=$OWNER" \
  -p "127.0.0.1:$port:8080" "$ALPINE_IMAGE" sh -c "$server_command" sh server-b >/dev/null
docker_e stop -t 2 "$SERVER_A" >/dev/null
docker_e start "$SERVER_B" >/dev/null
wait_http "$port" server-b || die "same-port handoff A -> B lost publishing"
docker_e stop -t 2 "$SERVER_B" >/dev/null
docker_e start "$SERVER_A" >/dev/null
wait_http "$port" server-a || die "same-port handoff B -> A lost publishing"
docker_e restart -t 2 "$SERVER_A" >/dev/null
wait_http "$port" server-a || die "published port disappeared after container restart"
pass published-port-handoff "port=$port A-B-A and restart remained reachable"

# OrbStack #2509 loops forever when a macOS service (notably AirPlay on port 5000) already owns a
# requested host port. Guest dockerd cannot see macOS listeners, so Dory's dataplane must reject the
# container start promptly, leave the container stopped, keep unrelated API calls live, and permit
# the same start after the real host owner releases the port.
collision_port_file="$WORKDIR/host-port-collision.port"
python3 - "$collision_port_file" <<'PY' &
import pathlib
import socket
import sys

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
pathlib.Path(sys.argv[1]).write_text(str(listener.getsockname()[1]), encoding="utf-8")
while True:
    connection, _ = listener.accept()
    connection.close()
PY
HOST_COLLISION_PID=$!
for _ in $(seq 1 100); do [ -s "$collision_port_file" ] && break; sleep 0.05; done
[ -s "$collision_port_file" ] || die "host port-collision fixture did not start"
collision_port="$(cat "$collision_port_file")"
docker_e create --name "$PORT_COLLISION_CONTAINER" \
  --label "dev.dory.compatibility=$OWNER" -p "127.0.0.1:$collision_port:8080" \
  "$ALPINE_IMAGE" sh -c "$server_command" sh collision-container >/dev/null
set +e
bounded_capture 8 "$WORKDIR/host-port-collision-start.out" \
  "$WORKDIR/host-port-collision-start.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" start "$PORT_COLLISION_CONTAINER"
collision_rc=$?
set -e
[ "$collision_rc" -ne 0 ] || die "container start silently accepted an occupied macOS host port"
[ "$collision_rc" -ne 124 ] || die "container start wedged on an occupied macOS host port"
[ "$(docker_e inspect -f '{{.State.Running}}' "$PORT_COLLISION_CONTAINER")" = false ] \
  || die "container remained running after host-port collision rejection"
bounded_capture 5 "$WORKDIR/post-host-port-collision-version.out" \
  "$WORKDIR/post-host-port-collision-version.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" version \
  || die "Docker API wedged after host-port collision rejection"
kill "$HOST_COLLISION_PID"
wait "$HOST_COLLISION_PID" 2>/dev/null || true
HOST_COLLISION_PID=""
docker_e start "$PORT_COLLISION_CONTAINER" >/dev/null
wait_http "$collision_port" collision-container \
  || die "host port did not recover after its external owner released it"
docker_e rm -f "$PORT_COLLISION_CONTAINER" >/dev/null
pass host-port-collision \
  "occupied port=$collision_port failed promptly rc=$collision_rc; API live; same start recovered"

# Apple container #1941 serializes a Darwin signal integer while its server expects a name. Keep
# Dory's Docker contract name-based across the host/Linux boundary and prove a detached exec
# process can independently receive the same Linux signal without stopping or wedging the init.
docker_e run -d --name "$SIGNAL_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  "$ALPINE_IMAGE" sh -c \
  'trap "printf container-usr1 > /container-signal" USR1; printf ready > /signal-ready; while :; do sleep 1; done' \
  >/dev/null
for _ in $(seq 1 50); do
  docker_e exec "$SIGNAL_CONTAINER" test -f /signal-ready >/dev/null 2>&1 && break
  sleep 0.1
done
docker_e exec "$SIGNAL_CONTAINER" test -f /signal-ready >/dev/null 2>&1 \
  || die "named-signal container did not become ready"
docker_e kill --signal USR1 "$SIGNAL_CONTAINER" > "$WORKDIR/container-signal.out"
for _ in $(seq 1 50); do
  [ "$(docker_e exec "$SIGNAL_CONTAINER" cat /container-signal 2>/dev/null || true)" = container-usr1 ] \
    && break
  sleep 0.1
done
[ "$(docker_e exec "$SIGNAL_CONTAINER" cat /container-signal 2>/dev/null || true)" = container-usr1 ] \
  || die "named USR1 did not reach container init"
[ "$(docker_e inspect -f '{{.State.Running}}' "$SIGNAL_CONTAINER")" = true ] \
  || die "nonterminating USR1 unexpectedly stopped container init"
docker_e exec -d "$SIGNAL_CONTAINER" sh -c \
  'trap "printf exec-usr1 > /exec-signal" USR1; echo $$ > /exec-pid; while :; do sleep 1; done'
for _ in $(seq 1 50); do
  docker_e exec "$SIGNAL_CONTAINER" test -s /exec-pid >/dev/null 2>&1 && break
  sleep 0.1
done
docker_e exec "$SIGNAL_CONTAINER" sh -ec 'test -s /exec-pid; kill -USR1 "$(cat /exec-pid)"'
for _ in $(seq 1 50); do
  [ "$(docker_e exec "$SIGNAL_CONTAINER" cat /exec-signal 2>/dev/null || true)" = exec-usr1 ] \
    && break
  sleep 0.1
done
[ "$(docker_e exec "$SIGNAL_CONTAINER" cat /exec-signal 2>/dev/null || true)" = exec-usr1 ] \
  || die "named USR1 did not reach detached exec process"
bounded_capture 5 "$WORKDIR/post-signal-version.out" "$WORKDIR/post-signal-version.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" version \
  || die "Docker API wedged after named signal delivery"
docker_e rm -f "$SIGNAL_CONTAINER" >/dev/null
pass named-signal-delivery \
  "named USR1 reached container init and detached exec process; init and Docker API remained live"

bounded_capture 10 "$WORKDIR/lifecycle-create.out" "$WORKDIR/lifecycle-create.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" create \
  --name "$LIFECYCLE_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  "$ALPINE_IMAGE" sh -c 'printf "lifecycle-started\n"; while :; do sleep 1; done' \
  || die "container lifecycle create failed or exceeded 10 seconds"
bounded_capture 10 "$WORKDIR/lifecycle-start.out" "$WORKDIR/lifecycle-start.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" start "$LIFECYCLE_CONTAINER" \
  || die "container lifecycle start failed or exceeded 10 seconds"
bounded_capture 10 "$WORKDIR/lifecycle-pause.out" "$WORKDIR/lifecycle-pause.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" pause "$LIFECYCLE_CONTAINER" \
  || die "container pause failed or exceeded 10 seconds"
[ "$(docker_e inspect -f '{{.State.Status}}' "$LIFECYCLE_CONTAINER")" = paused ] \
  || die "container did not enter paused state"
bounded_capture 10 "$WORKDIR/lifecycle-unpause.out" "$WORKDIR/lifecycle-unpause.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" unpause "$LIFECYCLE_CONTAINER" \
  || die "container unpause failed or exceeded 10 seconds"
[ "$(docker_e inspect -f '{{.State.Status}}' "$LIFECYCLE_CONTAINER")" = running ] \
  || die "container did not return to running state"
python3 - "$SOCKET" "$DOCKER_BIN" "$LIFECYCLE_CONTAINER" \
  "$WORKDIR/lifecycle-exec.out" "$WORKDIR/lifecycle-exec.err" <<'PY'
import os
import pathlib
import subprocess
import sys

socket_path, docker, container, stdout_path, stderr_path = sys.argv[1:]
environment = os.environ.copy()
environment["DOCKER_HOST"] = "unix://" + socket_path
completed = subprocess.run(
    [docker, "exec", "-i", container, "sh", "-c", 'read line; printf "exec:%s\\n" "$line"'],
    input=b"stdin-marker\n",
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=10,
    env=environment,
    check=False,
)
pathlib.Path(stdout_path).write_bytes(completed.stdout)
pathlib.Path(stderr_path).write_bytes(completed.stderr)
if completed.returncode != 0 or completed.stdout != b"exec:stdin-marker\n":
    raise SystemExit("interactive exec did not preserve stdin EOF and exact output")
PY
bounded_capture 10 "$WORKDIR/lifecycle-logs.out" "$WORKDIR/lifecycle-logs.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" logs "$LIFECYCLE_CONTAINER" \
  || die "container logs failed or exceeded 10 seconds"
grep -qx 'lifecycle-started' "$WORKDIR/lifecycle-logs.out" \
  || die "container logs lost exact stdout"
bounded_capture 10 "$WORKDIR/lifecycle-stats.out" "$WORKDIR/lifecycle-stats.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" stats --no-stream \
  --format '{{.Name}}' "$LIFECYCLE_CONTAINER" \
  || die "container stats failed or exceeded 10 seconds"
grep -qx "$LIFECYCLE_CONTAINER" "$WORKDIR/lifecycle-stats.out" \
  || die "container stats returned the wrong object"
bounded_capture 10 "$WORKDIR/lifecycle-restart.out" "$WORKDIR/lifecycle-restart.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" restart -t 2 "$LIFECYCLE_CONTAINER" \
  || die "container restart failed or exceeded 10 seconds"
bounded_capture 10 "$WORKDIR/lifecycle-stop.out" "$WORKDIR/lifecycle-stop.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" stop -t 2 "$LIFECYCLE_CONTAINER" \
  || die "container stop failed or exceeded 10 seconds"
[ "$(docker_e inspect -f '{{.State.Running}}' "$LIFECYCLE_CONTAINER")" = false ] \
  || die "container remained running after stop"
docker_e start "$LIFECYCLE_CONTAINER" >/dev/null
bounded_capture 10 "$WORKDIR/lifecycle-kill.out" "$WORKDIR/lifecycle-kill.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" kill --signal KILL "$LIFECYCLE_CONTAINER" \
  || die "container kill failed or exceeded 10 seconds"
[ "$(docker_e inspect -f '{{.State.Running}}' "$LIFECYCLE_CONTAINER")" = false ] \
  || die "container remained running after SIGKILL"

docker_e create --name "$ATTACH_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  "$ALPINE_IMAGE" sh -c 'printf "attach-output\n"' >/dev/null
bounded_capture 15 "$WORKDIR/lifecycle-wait.out" "$WORKDIR/lifecycle-wait.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" wait "$ATTACH_CONTAINER" &
wait_pid=$!
sleep 0.2
bounded_capture 10 "$WORKDIR/lifecycle-attach.out" "$WORKDIR/lifecycle-attach.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" start --attach "$ATTACH_CONTAINER" \
  || die "container attach failed or exceeded 10 seconds"
wait "$wait_pid" || die "container wait failed or exceeded 15 seconds"
grep -qx 'attach-output' "$WORKDIR/lifecycle-attach.out" \
  || die "container attach lost exact stdout"
grep -qx '0' "$WORKDIR/lifecycle-wait.out" \
  || die "container wait returned the wrong exit status"
docker_e create --name "$EXIT_CODE_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  "$ALPINE_IMAGE" sh -c 'exit 37' >/dev/null
docker_e start "$EXIT_CODE_CONTAINER" >/dev/null
bounded_capture 10 "$WORKDIR/lifecycle-exit-code-wait.out" \
  "$WORKDIR/lifecycle-exit-code-wait.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" wait "$EXIT_CODE_CONTAINER" \
  || die "nonzero container wait failed or exceeded 10 seconds"
grep -qx '37' "$WORKDIR/lifecycle-exit-code-wait.out" \
  || die "container wait did not surface the nonzero exit code"
[ "$(docker_e inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$EXIT_CODE_CONTAINER")" = \
    'exited:37' ] \
  || die "container inspect did not preserve the nonzero exit code"
docker_e ps -aq --no-trunc --filter 'exited=37' --filter "label=dev.dory.compatibility=$OWNER" \
  | grep -Fxq "$(docker_e inspect -f '{{.Id}}' "$EXIT_CODE_CONTAINER")" \
  || die "container list could not select the recorded nonzero exit code"
bounded_capture 10 "$WORKDIR/lifecycle-remove.out" "$WORKDIR/lifecycle-remove.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" rm \
  "$LIFECYCLE_CONTAINER" "$ATTACH_CONTAINER" "$EXIT_CODE_CONTAINER" \
  || die "container remove failed or exceeded 10 seconds"
docker_e inspect "$LIFECYCLE_CONTAINER" >/dev/null 2>&1 \
  && die "removed lifecycle container is still inspectable"
docker_e inspect "$ATTACH_CONTAINER" >/dev/null 2>&1 \
  && die "removed attach/wait container is still inspectable"
docker_e inspect "$EXIT_CODE_CONTAINER" >/dev/null 2>&1 \
  && die "removed exit-code container is still inspectable"
pass container-api-lifecycle \
  "create/start/pause/unpause/exec/logs/stats/restart/stop/kill/attach/wait/nonzero-exit/remove were exact and deadline bounded"

before_fd="$(sample_fds "$WORKDIR/fds-before.tsv")"
python3 - "$port" "$CONNECTIONS" <<'PY'
import socket, sys
port, count = map(int, sys.argv[1:])
for index in range(count):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    if b"server-a" not in b"".join(chunks):
        raise SystemExit(f"connection {index + 1} returned the wrong response")
PY
sleep 2
after_fd="$(sample_fds "$WORKDIR/fds-after.tsv")"
fd_growth=$((after_fd - before_fd))
[ "$fd_growth" -le "$FD_GROWTH_BUDGET" ] \
  || die "forwarded connections grew aggregate Dory FDs by $fd_growth (budget $FD_GROWTH_BUDGET)"
pass forwarded-connection-fds "connections=$CONNECTIONS before=$before_fd after=$after_fd growth=$fd_growth"

# Apple containerization #712 reproduced a permanent, process-wide proxy wedge when one of five
# concurrent relays filled its destination buffer. A sequential connection loop cannot expose that
# class. Retain enough stopped-container logs to fill several front-side Unix socket buffers, leave
# six log responses unread, then require unrelated requests to complete concurrently and promptly.
bounded_capture 60 "$WORKDIR/backpressure-fixture.out" "$WORKDIR/backpressure-fixture.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" run \
  -d --name "$BACKPRESSURE_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  "$ALPINE_IMAGE" sh -c 'head -c 8388608 /dev/zero | tr "\000" x' \
  || die "backpressure log fixture failed or exceeded 60 seconds"
bounded_capture 30 "$WORKDIR/backpressure-wait.out" "$WORKDIR/backpressure-wait.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" wait "$BACKPRESSURE_CONTAINER" \
  || die "backpressure log fixture did not finish within 30 seconds"
python3 - "$SOCKET" "$BACKPRESSURE_CONTAINER" <<'PY'
import concurrent.futures
import socket
import sys
import time

socket_path, container = sys.argv[1:]

def connect():
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    client.connect(socket_path)
    return client

stalled = []
try:
    request = (
        f"GET /containers/{container}/logs?stdout=1&stderr=1&tail=all HTTP/1.1\r\n"
        "Host: docker\r\nConnection: close\r\n\r\n"
    ).encode()
    for _ in range(6):
        client = connect()
        client.sendall(request)
        stalled.append(client)

    # Let every response exceed the host receive buffer while the clients deliberately do not
    # consume it. Isolation is proven only if new control requests still finish during that stall.
    time.sleep(1)

    def ping(index):
        client = connect()
        try:
            client.sendall(b"GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
            response = bytearray()
            while b"\r\n\r\n" not in response or not response.endswith(b"OK"):
                chunk = client.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
                if len(response) > 65536:
                    raise RuntimeError(f"ping {index} returned an oversized response")
            if b" 200 " not in response.split(b"\r\n", 1)[0] or not response.endswith(b"OK"):
                raise RuntimeError(f"ping {index} returned an invalid response")
            return index
        finally:
            client.close()

    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        completed = list(pool.map(ping, range(12)))
    elapsed = time.monotonic() - started
    if completed != list(range(12)):
        raise SystemExit("concurrent proxy probes did not all complete")
    if elapsed >= 5:
        raise SystemExit(f"concurrent proxy probes took {elapsed:.3f}s")
    print(f"stalled=6 probes=12 elapsed={elapsed:.3f}s")
finally:
    for client in stalled:
        client.close()
PY
docker_e inspect "$SERVER_A" >/dev/null
bounded_capture 10 "$WORKDIR/backpressure-remove.out" "$WORKDIR/backpressure-remove.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" rm "$BACKPRESSURE_CONTAINER" \
  || die "backpressure fixture cleanup failed or exceeded 10 seconds"
sleep 2
after_backpressure_fd="$(sample_fds "$WORKDIR/fds-after-backpressure.tsv")"
backpressure_fd_growth=$((after_backpressure_fd - before_fd))
[ "$backpressure_fd_growth" -le "$FD_GROWTH_BUDGET" ] \
  || die "concurrent stalled streams grew aggregate Dory FDs by $backpressure_fd_growth (budget $FD_GROWTH_BUDGET)"
pass concurrent-proxy-backpressure \
  "six unread 8MiB log streams did not block twelve concurrent control requests; fd-growth=$backpressure_fd_growth"

set +e
bounded_capture 5 "$WORKDIR/missing-cp.out" "$WORKDIR/missing-cp.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" cp \
  "$SERVER_A:/definitely-missing-$RUN_ID" "$WORKDIR/missing-copy"
cp_rc=$?
set -e
[ "$cp_rc" -ne 0 ] || die "docker cp unexpectedly succeeded for a missing source"
[ "$cp_rc" -ne 124 ] || die "docker cp hung for a missing source"
bounded_capture 5 "$WORKDIR/post-missing-cp-exec.out" "$WORKDIR/post-missing-cp-exec.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" exec "$SERVER_A" true \
  || die "exec failed or wedged after missing-source docker cp"
bounded_capture 5 "$WORKDIR/post-missing-cp-inspect.out" "$WORKDIR/post-missing-cp-inspect.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" inspect "$SERVER_A" \
  || die "inspect failed or wedged after missing-source docker cp"
bounded_capture 5 "$WORKDIR/post-missing-cp-stats.out" "$WORKDIR/post-missing-cp-stats.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" stats --no-stream "$SERVER_A" \
  || die "stats failed or wedged after missing-source docker cp"
pass missing-source-cp "failed promptly with exit=$cp_rc; exec/inspect/stats remained responsive"

i=1
while [ "$i" -le "$RESTARTS" ]; do
  bounded_capture 10 "$WORKDIR/restart-$i.out" "$WORKDIR/restart-$i.err" \
    env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" restart -t 1 "$SERVER_A" \
    || die "restart cycle $i failed or exceeded 10 seconds"
  wait_http "$port" server-a || die "published port failed after restart cycle $i"
  bounded_capture 5 "$WORKDIR/inspect-$i.out" "$WORKDIR/inspect-$i.err" \
    env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" inspect "$SERVER_A" \
    || die "inspect wedged after restart cycle $i"
  bounded_capture 5 "$WORKDIR/logs-$i.out" "$WORKDIR/logs-$i.err" \
    env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" logs "$SERVER_A" \
    || die "logs wedged after restart cycle $i"
  bounded_capture 5 "$WORKDIR/stats-$i.out" "$WORKDIR/stats-$i.err" \
    env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" stats --no-stream "$SERVER_A" \
    || die "stats wedged after restart cycle $i"
  i=$((i + 1))
done
docker_e rm -f "$SERVER_A" >/dev/null
docker_e run -d --name "$SERVER_A" --label "dev.dory.compatibility=$OWNER" \
  -p "127.0.0.1:$port:8080" "$ALPINE_IMAGE" sh -c "$server_command" sh server-a >/dev/null
wait_http "$port" server-a || die "container name/port could not be reused after churn cleanup"
pass restart-churn "restarts=$RESTARTS; restart/inspect/logs/stats bounded; name and port reusable"

compose_port="$(free_port)"
mkdir -p "$WORKDIR/compose-bind"
printf 'from-bind-%s\n' "$RUN_ID" > "$WORKDIR/compose-bind/message"
docker_e network create --label "dev.dory.compatibility=$OWNER" \
  "$COMPOSE_EXTERNAL_NETWORK" >/dev/null
cat > "$WORKDIR/.env" <<EOF
DORY_COMPOSE_TOKEN=compose-token-$RUN_ID
COMPOSE_PORT=$compose_port
COMPOSE_PROJECT_NAME=environment-must-not-override-explicit-project
EOF
cat > "$WORKDIR/compose.yaml" <<EOF
name: file-must-not-override-explicit-project
services:
  initializer:
    image: $ALPINE_IMAGE
    labels:
      dev.dory.compatibility: "$OWNER"
    environment:
      DORY_COMPOSE_TOKEN: \${DORY_COMPOSE_TOKEN:?DORY_COMPOSE_TOKEN is required}
    command: ["sh", "-ec", "printf '%s' \"\$\${DORY_COMPOSE_TOKEN}\" > /state/token"]
    volumes:
      - state:/state
    networks: [app]

  database:
    image: $ALPINE_IMAGE
    labels:
      dev.dory.compatibility: "$OWNER"
    command: ["sh", "-ec", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
    healthcheck:
      test: ["CMD-SHELL", "test -s /state/token"]
      interval: 250ms
      timeout: 1s
      retries: 40
    volumes:
      - state:/state
    networks:
      app:
        aliases: [database-alias]

  api:
    image: $ALPINE_IMAGE
    labels:
      dev.dory.compatibility: "$OWNER"
      dev.dory.compose-contract: base
    depends_on:
      initializer:
        condition: service_completed_successfully
      database:
        condition: service_healthy
    environment:
      DORY_COMPOSE_TOKEN: \${DORY_COMPOSE_TOKEN:?DORY_COMPOSE_TOKEN is required}
      MERGED_VALUE: base
    command:
      - sh
      - -ec
      - |
        test "\$\${MERGED_VALUE}" = override
        test "\$\$(cat /state/token)" = "\$\${DORY_COMPOSE_TOKEN}"
        test "\$\$(cat /input/message)" = "from-bind-$RUN_ID"
        ping -c 1 -W 2 database-alias >/dev/null
        printf '%s\\n' '#!/bin/sh' "awk 'length() <= 1 { exit }' >/dev/null" 'printf "HTTP/1.1 200 OK\\r\\nContent-Length: 8\\r\\nConnection: close\\r\\n\\r\\ncompose\\n"' > /tmp/dory-http
        chmod 755 /tmp/dory-http
        echo compose-ready
        exec nc -lk -p 8080 -e /tmp/dory-http
    ports:
      - "127.0.0.1:\${COMPOSE_PORT:?COMPOSE_PORT is required}:8080"
    volumes:
      - type: bind
        source: ./compose-bind
        target: /input
        read_only: true
      - state:/state
    networks: [app, external]
    cap_add: [CHOWN]
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: 1m
        max-file: "2"

  debug:
    image: $ALPINE_IMAGE
    profiles: [debug]
    labels:
      dev.dory.compatibility: "$OWNER"
    command: ["sh", "-ec", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
    networks: [app]

volumes:
  state:
    labels:
      dev.dory.compatibility: "$OWNER"

networks:
  app:
    labels:
      dev.dory.compatibility: "$OWNER"
  external:
    name: $COMPOSE_EXTERNAL_NETWORK
    external: true
EOF
cat > "$WORKDIR/compose.override.yaml" <<EOF
services:
  api:
    cap_add: !reset []
    environment:
      MERGED_VALUE: override
    labels:
      dev.dory.compose-contract: merged
  debug:
    environment:
      DORY_COMPOSE_TOKEN: \${DORY_COMPOSE_TOKEN:?DORY_COMPOSE_TOKEN is required}
EOF

compose_args=(
  --ansi never --progress plain
  --project-directory "$WORKDIR"
  --env-file "$WORKDIR/.env"
  --file "$WORKDIR/compose.yaml"
  --file "$WORKDIR/compose.override.yaml"
  --project-name "$COMPOSE_PROJECT"
)
# A caller's ambient Compose selectors must not replace the files, socket, or project selected by
# Dory. compose_e scrubs them exactly as the GUI runner does.
export DOCKER_CONTEXT=ambient-context-must-be-ignored
export COMPOSE_FILE="$WORKDIR/definitely-missing-ambient-compose.yaml"
export COMPOSE_PATH_SEPARATOR=';'
compose_e "${compose_args[@]}" --profile '*' config --format json \
  > "$WORKDIR/compose-config.json" 2> "$WORKDIR/compose-config.err"
unset DOCKER_CONTEXT COMPOSE_FILE COMPOSE_PATH_SEPARATOR
python3 - "$WORKDIR/compose-config.json" "$COMPOSE_PROJECT" "$RUN_ID" <<'PY'
import json
import sys

path, project, run_id = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    model = json.load(handle)
assert model["name"] == project, (model["name"], project)
assert set(model["services"]) == {"initializer", "database", "api", "debug"}
api = model["services"]["api"]
assert api["environment"]["MERGED_VALUE"] == "override"
assert api["environment"]["DORY_COMPOSE_TOKEN"] == f"compose-token-{run_id}"
assert api["labels"]["dev.dory.compose-contract"] == "merged"
assert api.get("cap_add", []) == []
assert set(model["volumes"]) == {"state"}
assert set(model["networks"]) == {"app", "external"}
PY

compose_e "${compose_args[@]}" up --detach --remove-orphans --yes \
  > "$WORKDIR/compose-up.out" 2> "$WORKDIR/compose-up.err"
wait_http "$compose_port" compose || die "Compose published port did not become reachable"
debug_id="$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=debug')"
[ -z "$debug_id" ] || die "default Compose up activated a profile-only service"
initializer_id="$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=initializer')"
database_id="$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=database')"
api_id="$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=api')"
[ -n "$initializer_id" ] && [ -n "$database_id" ] && [ -n "$api_id" ] \
  || die "Compose did not create every default-profile service"
[ "$(docker_e inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$initializer_id")" = 'exited:0' ] \
  || die "Compose completion dependency did not exit successfully"
[ "$(docker_e inspect -f '{{.State.Health.Status}}' "$database_id")" = healthy ] \
  || die "Compose health dependency was not healthy when the API became reachable"
[ "$(docker_e inspect -f '{{ index .Config.Labels "dev.dory.compose-contract" }}' "$api_id")" = merged ] \
  || die "Compose override labels were not merged into the service"

expected_config_files="$WORKDIR/compose.yaml,$WORKDIR/compose.override.yaml"
[ "$(docker_e inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$api_id")" = "$WORKDIR" ] \
  || die "Compose working-directory metadata is missing or not absolute"
[ "$(docker_e inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$api_id")" = "$expected_config_files" ] \
  || die "Compose config-file metadata is missing, unordered, or not absolute"
[ "$(docker_e inspect -f '{{ index .Config.Labels "com.docker.compose.project.environment_file" }}' "$api_id")" = "$WORKDIR/.env" ] \
  || die "Compose environment-file metadata is missing or not absolute"

compose_e "${compose_args[@]}" --profile debug up --detach --remove-orphans --yes \
  > "$WORKDIR/compose-profile-up.out" 2> "$WORKDIR/compose-profile-up.err"
debug_id="$(docker_e ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=debug')"
[ -n "$debug_id" ] || die "explicit Compose profile did not start its service"

cat > "$WORKDIR/compose.retired.yaml" <<EOF
services:
  retired:
    image: $ALPINE_IMAGE
    labels:
      dev.dory.compatibility: "$OWNER"
    command: ["sh", "-ec", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
    networks: [app]
EOF
compose_e "${compose_args[@]}" --file "$WORKDIR/compose.retired.yaml" --profile debug \
  up --detach --remove-orphans --yes \
  > "$WORKDIR/compose-retired-up.out" 2> "$WORKDIR/compose-retired-up.err"
retired_id="$(docker_e ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=retired')"
[ -n "$retired_id" ] || die "Compose did not create the retired-service orphan fixture"
compose_e "${compose_args[@]}" --profile debug up --detach --remove-orphans --yes \
  > "$WORKDIR/compose-orphan-up.out" 2> "$WORKDIR/compose-orphan-up.err"
! docker_e inspect "$retired_id" >/dev/null 2>&1 \
  || die "Compose --remove-orphans retained an exact-project retired service"
api_id="$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.service=api')"
[ -n "$api_id" ] || die "Compose orphan reconciliation lost the API service"

compose_e "${compose_args[@]}" --profile '*' stop -- api \
  > "$WORKDIR/compose-stop.out" 2> "$WORKDIR/compose-stop.err"
[ "$(docker_e inspect -f '{{.State.Running}}' "$api_id")" = false ] \
  || die "Compose stop did not stop the selected service"
compose_e "${compose_args[@]}" --profile '*' start -- api \
  > "$WORKDIR/compose-start.out" 2> "$WORKDIR/compose-start.err"
wait_http "$compose_port" compose || die "Compose published port disappeared after stop/start"
compose_e "${compose_args[@]}" --profile '*' restart -- api \
  > "$WORKDIR/compose-restart.out" 2> "$WORKDIR/compose-restart.err"
wait_http "$compose_port" compose || die "Compose published port disappeared after restart"
compose_e "${compose_args[@]}" --profile '*' logs --no-color api \
  > "$WORKDIR/compose-logs.out" 2> "$WORKDIR/compose-logs.err"
grep -q 'compose-ready' "$WORKDIR/compose-logs.out" \
  || die "Compose logs did not return the selected service output"

compose_volume="$(docker_e volume ls -q \
  --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.volume=state')"
compose_network="$(docker_e network ls -q \
  --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter 'label=com.docker.compose.network=app')"
[ -n "$compose_volume" ] && [ -n "$compose_network" ] \
  || die "Compose did not create its named volume and custom network"
compose_e "${compose_args[@]}" --profile '*' down --remove-orphans \
  > "$WORKDIR/compose-down.out" 2> "$WORKDIR/compose-down.err"
[ -z "$(docker_e ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT")" ] \
  || die "Compose down left project containers"
! docker_e network inspect "$compose_network" >/dev/null 2>&1 \
  || die "Compose down left its non-external project network"
docker_e network inspect "$COMPOSE_EXTERNAL_NETWORK" >/dev/null \
  || die "Compose down deleted an external network"
docker_e volume inspect "$compose_volume" >/dev/null \
  || die "Compose down deleted named user data without an explicit volume request"
[ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
    -v "$compose_volume:/state:ro" "$ALPINE_IMAGE" cat /state/token)" = \
    "compose-token-$RUN_ID" ] \
  || die "Compose named data did not survive down"
docker_e volume rm "$compose_volume" >/dev/null
docker_e network rm "$COMPOSE_EXTERNAL_NETWORK" >/dev/null
pass compose-port-restart "port=$compose_port reachable after restart and stop/start"
pass compose-v2-lifecycle \
  "multi-file/.env/!reset merge, dependencies, profile, bind/volume/network, external preservation, labels, orphan cleanup, logs, lifecycle, and data-safe down passed"

docker_e network create --label "dev.dory.compatibility=$OWNER" "$ROUTE_NETWORK" >/dev/null
docker_e network connect "$ROUTE_NETWORK" "$SERVER_A"
route_subnet="$(docker_e network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$ROUTE_NETWORK")"
[ -n "$route_subnet" ] || die "owned route-conflict fixture has no subnet"
set +e
bounded_capture 5 "$WORKDIR/network-conflict.out" "$WORKDIR/network-conflict.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" network create \
  --label "dev.dory.compatibility=$OWNER" --subnet "$route_subnet" "$CONFLICT_NETWORK"
network_rc=$?
set -e
[ "$network_rc" -ne 0 ] || die "Docker accepted an overlapping network subnet"
[ "$network_rc" -ne 124 ] || die "overlapping network creation wedged"
wait_http "$port" server-a || die "a failed network reconcile broke an unrelated published port"
bounded_capture 5 "$WORKDIR/network-post-conflict-inspect.out" "$WORKDIR/network-post-conflict-inspect.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" inspect "$SERVER_A" \
  || die "container inspect wedged after network conflict"
docker_e network disconnect "$ROUTE_NETWORK" "$SERVER_A"
docker_e network rm "$ROUTE_NETWORK" >/dev/null
pass network-route-conflict "overlap failed promptly; unrelated container API and port stayed healthy"

bounded_capture 10 "$WORKDIR/network-metadata-create.out" \
  "$WORKDIR/network-metadata-create.err" env DOCKER_HOST="unix://$SOCKET" \
  "$DOCKER_BIN" network create --driver bridge --internal --attachable \
  --subnet "$NETWORK_METADATA_SUBNET" --ip-range "$NETWORK_METADATA_RANGE" \
  --gateway "$NETWORK_METADATA_GATEWAY" \
  --aux-address "reserved=$NETWORK_METADATA_RESERVED" \
  --opt com.docker.network.bridge.enable_icc=true \
  --label "dev.dory.compatibility=$OWNER" \
  --label dev.dory.network-contract=original "$NETWORK_METADATA" \
  || die "custom network creation failed or exceeded ten seconds"
docker_e network inspect "$NETWORK_METADATA" > "$WORKDIR/network-metadata-before.json"
python3 - "$WORKDIR/network-metadata-before.json" "$NETWORK_METADATA" "$OWNER" \
  "$NETWORK_METADATA_SUBNET" "$NETWORK_METADATA_RANGE" "$NETWORK_METADATA_GATEWAY" \
  "$NETWORK_METADATA_RESERVED" <<'PY'
import json
import sys

path, expected_name, expected_owner, subnet, ip_range, gateway, reserved = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    networks = json.load(handle)
assert len(networks) == 1, f"expected one inspected network, got {len(networks)}"
network = networks[0]
assert network["Name"] == expected_name, network
assert network["Driver"] == "bridge" and network["Scope"] == "local", network
assert network["Internal"] is True and network["Attachable"] is True, network
assert network["Ingress"] is False, network
assert network["Labels"]["dev.dory.compatibility"] == expected_owner, network
assert network["Labels"]["dev.dory.network-contract"] == "original", network
assert network["Options"]["com.docker.network.bridge.enable_icc"] == "true", network
assert network["IPAM"]["Driver"] == "default", network
config = network["IPAM"]["Config"]
assert len(config) == 1, config
assert config[0]["Subnet"] == subnet, config
assert config[0]["IPRange"] == ip_range, config
assert config[0]["Gateway"] == gateway, config
assert config[0]["AuxiliaryAddresses"] == {"reserved": reserved}, config
PY
filtered_networks="$(docker_e network ls --format '{{.Name}}' \
  --filter "label=dev.dory.compatibility=$OWNER" \
  --filter label=dev.dory.network-contract=original)"
[ "$filtered_networks" = "$NETWORK_METADATA" ] \
  || die "filtered network listing returned unexpected objects: $filtered_networks"
set +e
bounded_capture 10 "$WORKDIR/network-duplicate-create.out" \
  "$WORKDIR/network-duplicate-create.err" env DOCKER_HOST="unix://$SOCKET" \
  "$DOCKER_BIN" network create --label dev.dory.network-contract=mutated "$NETWORK_METADATA"
network_duplicate_rc=$?
set -e
[ "$network_duplicate_rc" -ne 0 ] || die "duplicate network name was accepted"
[ "$network_duplicate_rc" -ne 124 ] || die "duplicate network creation wedged for ten seconds"
grep -Eiq 'already exists|conflict' \
  "$WORKDIR/network-duplicate-create.out" "$WORKDIR/network-duplicate-create.err" \
  || die "duplicate network rejection did not report the conflict"
docker_e network inspect "$NETWORK_METADATA" > "$WORKDIR/network-metadata-after.json"
python3 - "$WORKDIR/network-metadata-before.json" "$WORKDIR/network-metadata-after.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as before_handle:
    before = json.load(before_handle)
with open(sys.argv[2], encoding="utf-8") as after_handle:
    after = json.load(after_handle)
assert after == before, "duplicate create mutated existing network metadata"
PY
bounded_capture 10 "$WORKDIR/network-connect.out" "$WORKDIR/network-connect.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" network connect \
  --alias metadata-api --ip "$NETWORK_METADATA_STATIC_IP" "$NETWORK_METADATA" "$SERVER_A" \
  || die "network connect failed or exceeded ten seconds"
docker_e container inspect "$SERVER_A" > "$WORKDIR/network-connected-container.json"
python3 - "$WORKDIR/network-connected-container.json" "$NETWORK_METADATA" \
  "$NETWORK_METADATA_STATIC_IP" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    containers = json.load(handle)
endpoint = containers[0]["NetworkSettings"]["Networks"][sys.argv[2]]
assert endpoint["IPAddress"] == sys.argv[3], endpoint
assert "metadata-api" in endpoint["Aliases"], endpoint
PY
set +e
bounded_capture 10 "$WORKDIR/network-in-use-remove.out" "$WORKDIR/network-in-use-remove.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" network rm "$NETWORK_METADATA"
network_in_use_rc=$?
set -e
[ "$network_in_use_rc" -ne 0 ] || die "in-use network was removed"
[ "$network_in_use_rc" -ne 124 ] || die "in-use network removal wedged for ten seconds"
grep -Eiq 'active endpoints|in use' \
  "$WORKDIR/network-in-use-remove.out" "$WORKDIR/network-in-use-remove.err" \
  || die "in-use network rejection did not report active endpoints"
wait_http "$port" server-a || die "network lifecycle operations broke the published port"
bounded_capture 10 "$WORKDIR/network-disconnect.out" "$WORKDIR/network-disconnect.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" network disconnect \
  "$NETWORK_METADATA" "$SERVER_A" \
  || die "network disconnect failed or exceeded ten seconds"
[ -z "$(docker_e inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK_METADATA\"}}{{.NetworkID}}{{end}}" "$SERVER_A")" ] \
  || die "network disconnect left the container attached"
bounded_capture 10 "$WORKDIR/network-metadata-remove.out" \
  "$WORKDIR/network-metadata-remove.err" env DOCKER_HOST="unix://$SOCKET" \
  "$DOCKER_BIN" network rm "$NETWORK_METADATA" \
  || die "explicit network removal failed or exceeded ten seconds"
docker_e network inspect "$NETWORK_METADATA" >/dev/null 2>&1 \
  && die "explicitly removed network is still inspectable"
pass network-api-lifecycle \
  "IPAM/options/labels, filters, conflict safety, static-IP alias connect, in-use reject, disconnect, and remove matched Docker"

# Higher-level Compose/dev-environment tools depend on attachment-scoped aliases. Prove both aliases
# and the primary container name resolve only on the owned custom network, then preserve the exact
# endpoint IP and aliases across stop/start.
docker_e network create --label "dev.dory.compatibility=$OWNER" "$ALIAS_NETWORK" >/dev/null
docker_e run -d --name "$ALIAS_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  --network "$ALIAS_NETWORK" --network-alias db --network-alias database \
  "$ALPINE_IMAGE" sh -c "$server_command" sh alias-server >/dev/null
alias_ip_before="$(docker_e inspect -f "{{with index .NetworkSettings.Networks \"$ALIAS_NETWORK\"}}{{.IPAddress}}{{end}}" "$ALIAS_CONTAINER")"
[ -n "$alias_ip_before" ] || die "network alias fixture has no custom-network IP"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" --network "$ALIAS_NETWORK" \
  "$ALPINE_IMAGE" sh -ec '
    for name in "$@"; do
      [ "$(wget -qO- -T 3 "http://$name:8080/")" = alias-server ]
    done
  ' sh "$ALIAS_CONTAINER" db database
docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$ALPINE_IMAGE" sh -ec \
  'command -v nslookup >/dev/null; ! nslookup db >/dev/null 2>&1; ! nslookup database >/dev/null 2>&1'
docker_e stop -t 2 "$ALIAS_CONTAINER" >/dev/null
docker_e start "$ALIAS_CONTAINER" >/dev/null
alias_ip_after="$(docker_e inspect -f "{{with index .NetworkSettings.Networks \"$ALIAS_NETWORK\"}}{{.IPAddress}}{{end}}" "$ALIAS_CONTAINER")"
[ "$alias_ip_after" = "$alias_ip_before" ] \
  || die "custom-network IP changed across stop/start ($alias_ip_before -> $alias_ip_after)"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" --network "$ALIAS_NETWORK" \
  "$ALPINE_IMAGE" sh -ec '
    for name in "$@"; do
      [ "$(wget -qO- -T 3 "http://$name:8080/")" = alias-server ]
    done
  ' sh "$ALIAS_CONTAINER" db database
pass network-alias-restart-ip \
  "primary plus db/database aliases stayed network-scoped; IP=$alias_ip_before and names survived stop/start"

if [ -n "$RUNTIME" ]; then
  docker_e update --restart unless-stopped "$SERVER_A" >/dev/null
  server_id="$(docker_e inspect -f '{{.Id}}' "$SERVER_A")"
  bounded_capture 30 "$WORKDIR/engine-stop.out" "$WORKDIR/engine-stop.err" \
    env HOME="$RUNTIME_HOME" "$RUNTIME" stop \
    || die "standalone engine stop failed or exceeded 30 seconds"
  [ ! -S "$SOCKET" ] || die "engine socket survived a reported standalone stop"
  bounded_capture 60 "$WORKDIR/engine-start.out" "$WORKDIR/engine-start.err" \
    env HOME="$RUNTIME_HOME" "$RUNTIME" start \
    || die "standalone engine start failed or exceeded 60 seconds"
  attempts=100
  while [ "$attempts" -gt 0 ]; do
    docker_e version >/dev/null 2>&1 && break
    attempts=$((attempts - 1))
    sleep 0.2
  done
  [ "$attempts" -gt 0 ] || die "Docker API did not recover after standalone restart"
  # Dockerd publishes its API before the restart manager has necessarily recreated every
  # restart-policy task. Require bounded convergence instead of racing the first successful
  # /version response, while still pinning the exact container identity throughout.
  resume_attempts=100
  resumed_id=""
  resumed_running="false"
  while [ "$resume_attempts" -gt 0 ]; do
    resumed_id="$(docker_e inspect -f '{{.Id}}' "$SERVER_A" 2>/dev/null || true)"
    resumed_running="$(docker_e inspect -f '{{.State.Running}}' "$SERVER_A" 2>/dev/null || true)"
    if [ "$resumed_id" = "$server_id" ] && [ "$resumed_running" = true ]; then
      break
    fi
    resume_attempts=$((resume_attempts - 1))
    sleep 0.2
  done
  [ "$(docker_e inspect -f '{{.Id}}' "$SERVER_A")" = "$server_id" ] \
    || die "container identity changed across standalone restart"
  [ "$(docker_e inspect -f '{{.State.Running}}' "$SERVER_A")" = true ] \
    || die "restart-policy container did not resume within 20 seconds after standalone restart"
  wait_http "$port" server-a || die "published port did not recover after standalone restart"
  pass standalone-engine-restart "container identity/state and port=$port recovered after stop/start"
fi

docker_e volume create --label "dev.dory.compatibility=$OWNER" "$VOLUME" >/dev/null
docker_e volume create --driver local \
  --label "dev.dory.compatibility=$OWNER" \
  --label dev.dory.volume-contract=original \
  --opt type=tmpfs --opt device=tmpfs --opt o=size=4m \
  "$VOLUME_METADATA" >/dev/null
docker_e volume inspect "$VOLUME_METADATA" > "$WORKDIR/volume-metadata-before.json"
python3 - "$WORKDIR/volume-metadata-before.json" "$VOLUME_METADATA" "$OWNER" <<'PY'
import json
import sys

path, expected_name, expected_owner = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    volumes = json.load(handle)
assert len(volumes) == 1, f"expected one inspected volume, got {len(volumes)}"
volume = volumes[0]
assert volume["Name"] == expected_name, volume
assert volume["Driver"] == "local", volume
assert volume["Scope"] == "local", volume
assert volume["Labels"]["dev.dory.compatibility"] == expected_owner, volume
assert volume["Labels"]["dev.dory.volume-contract"] == "original", volume
assert volume["Options"] == {"type": "tmpfs", "device": "tmpfs", "o": "size=4m"}, volume
PY
filtered_volumes="$(docker_e volume ls -q \
  --filter "label=dev.dory.compatibility=$OWNER" \
  --filter label=dev.dory.volume-contract=original)"
[ "$filtered_volumes" = "$VOLUME_METADATA" ] \
  || die "filtered volume listing returned unexpected objects: $filtered_volumes"
same_volume="$(docker_e volume create --driver local \
  --label dev.dory.volume-contract=mutated \
  --opt type=none --opt device=/tmp --opt o=bind "$VOLUME_METADATA")"
[ "$same_volume" = "$VOLUME_METADATA" ] \
  || die "same-name volume creation returned the wrong identity: $same_volume"
docker_e volume inspect "$VOLUME_METADATA" > "$WORKDIR/volume-metadata-after.json"
python3 - "$WORKDIR/volume-metadata-before.json" "$WORKDIR/volume-metadata-after.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as before_handle:
    before = json.load(before_handle)
with open(sys.argv[2], encoding="utf-8") as after_handle:
    after = json.load(after_handle)
assert after == before, "same-name create mutated existing volume metadata"
PY
bounded_capture 10 "$WORKDIR/volume-metadata-remove.out" \
  "$WORKDIR/volume-metadata-remove.err" env DOCKER_HOST="unix://$SOCKET" \
  "$DOCKER_BIN" volume rm "$VOLUME_METADATA" \
  || die "explicit volume removal failed or exceeded ten seconds"
docker_e volume inspect "$VOLUME_METADATA" >/dev/null 2>&1 \
  && die "explicitly removed volume is still inspectable"
volume_initial_entries="$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$VOLUME:/data" "$ALPINE_IMAGE" \
  find /data -mindepth 1 -maxdepth 1 -print)"
[ -z "$volume_initial_entries" ] \
  || die "fresh named volume is not empty: $volume_initial_entries"
pass named-volume-empty "fresh volume root had no lost+found or other image-breaking entries"

marker="volume-$RUN_ID"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" -v "$VOLUME:/data" "$ALPINE_IMAGE" \
  sh -c 'printf "%s\n" "$1" > /data/marker' sh "$marker"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" -v "$VOLUME:/data" "$ALPINE_IMAGE" \
  grep -qx "$marker" /data/marker
pass named-volume "data survived removal and recreation of the consuming container"

# Copying through a mounted named volume is a distinct API/tar-stream path from ordinary volume
# reads. Require both directions to complete promptly, preserve exact bytes, and leave unrelated
# Docker control requests responsive.
volume_cp_in="$WORKDIR/volume-cp-in.bin"
volume_cp_out="$WORKDIR/volume-cp-out.bin"
python3 - "$volume_cp_in" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(bytes(range(256)) * 4096)
PY
docker_e run -d --name "$VOLUME_CP_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  -v "$VOLUME:/data" "$ALPINE_IMAGE" sleep 300 >/dev/null
set +e
bounded_capture 10 "$WORKDIR/volume-in-use-remove.out" "$WORKDIR/volume-in-use-remove.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" volume rm "$VOLUME"
volume_in_use_rc=$?
set -e
[ "$volume_in_use_rc" -ne 0 ] || die "in-use named volume was removed"
[ "$volume_in_use_rc" -ne 124 ] || die "in-use named-volume removal wedged for ten seconds"
grep -Eiq 'in use|is being used' \
  "$WORKDIR/volume-in-use-remove.out" "$WORKDIR/volume-in-use-remove.err" \
  || die "in-use volume rejection did not report the conflict"
docker_e volume inspect "$VOLUME" >/dev/null \
  || die "in-use volume rejection removed the volume metadata"
docker_e exec "$VOLUME_CP_CONTAINER" grep -qx "$marker" /data/marker \
  || die "in-use volume rejection damaged persisted bytes"
bounded_capture 10 "$WORKDIR/volume-cp-in.out" "$WORKDIR/volume-cp-in.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" cp \
  "$volume_cp_in" "$VOLUME_CP_CONTAINER:/data/from-host.bin" \
  || die "docker cp into a mounted named volume failed or wedged"
docker_e exec "$VOLUME_CP_CONTAINER" sh -ec \
  'test "$(wc -c < /data/from-host.bin | tr -d " ")" = 1048576'
docker_e exec "$VOLUME_CP_CONTAINER" cp /data/from-host.bin /data/from-volume.bin
bounded_capture 10 "$WORKDIR/volume-cp-out.out" "$WORKDIR/volume-cp-out.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" cp \
  "$VOLUME_CP_CONTAINER:/data/from-volume.bin" "$volume_cp_out" \
  || die "docker cp from a mounted named volume failed or wedged"
cmp "$volume_cp_in" "$volume_cp_out" || die "named-volume docker cp changed payload bytes"
bounded_capture 5 "$WORKDIR/volume-cp-version.out" "$WORKDIR/volume-cp-version.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" version \
  || die "Docker API wedged after named-volume copy"
docker_e rm -f "$VOLUME_CP_CONTAINER" >/dev/null
pass named-volume-cp "1MiB exact bytes copied host->mounted volume->host; Docker API remained responsive"
pass volume-api-lifecycle \
  "driver/labels/options, filtered list, same-name identity, in-use rejection, and explicit remove matched Docker"

docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  --security-opt label=disable "$ALPINE_IMAGE" true
pass security-opt-label "Docker-compatible label=disable security option accepted"

seccomp_profile="$WORKDIR/seccomp-profile.json"
python3 - "$seccomp_profile" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "defaultAction": "SCMP_ACT_ALLOW",
    "architectures": ["SCMP_ARCH_AARCH64"],
    "syscalls": [{
        "names": ["mkdir", "mkdirat"],
        "action": "SCMP_ACT_ERRNO",
        "errnoRet": 13,
    }],
}), encoding="utf-8")
PY
docker_e info --format '{{json .SecurityOptions}}' > "$WORKDIR/security-options.json"
grep -q 'name=seccomp' "$WORKDIR/security-options.json" \
  || die "Docker engine does not advertise seccomp support"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  --security-opt "seccomp=$seccomp_profile" "$ALPINE_IMAGE" sh -ec '
    test -r /etc/os-release
    if mkdir /seccomp-should-block 2>/dev/null; then exit 1; fi
    test ! -e /seccomp-should-block
  ' || die "custom seccomp profile did not execute or enforce the blocked syscall"
bounded_capture 5 "$WORKDIR/post-seccomp-version.out" "$WORKDIR/post-seccomp-version.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" version \
  || die "Docker API wedged after custom seccomp enforcement"
pass seccomp-profile "engine advertised seccomp; custom profile blocked mkdir/mkdirat and API stayed live"

bind_dir="$WORKDIR/bind"
mkdir -p "$bind_dir"
# Create the fixture directory through the bind itself. This proves the mount is writable and
# avoids relying on empty host directories being materialized before the first guest-side lookup.
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$bind_dir:/share" "$ALPINE_IMAGE" sh -ec 'mkdir -p /share/test; chmod 0777 /share/test'
docker_e run --rm --user 1000:1000 --label "dev.dory.compatibility=$OWNER" \
  -v "$bind_dir:/share" "$ALPINE_IMAGE" sh -ec \
  'umask 0577; : > /share/test/write-only; printf x >> /share/test/write-only; test "$(stat -c %a /share/test/write-only)" = 200; : > /tmp/native-write-only; test "$(stat -c %a /tmp/native-write-only)" = 200'
[ "$(stat -f '%Lp' "$bind_dir/test/write-only")" = 200 ] || die "host did not retain mode 0200"
[ "$(stat -f '%z' "$bind_dir/test/write-only")" = 1 ] || die "write-only bind file has the wrong size"
pass bind-open-create-0200 "non-root uid=1000 O_CREAT/write matched native fs; host mode=0200 size=1"

# Dory exposes Docker's mount contract, not Apple's undocumented host:guest:kernel-flags grammar.
# Unsupported flags must fail loudly instead of being silently discarded, while Docker's supported
# read-only mode must be visible in inspect and enforced by the kernel mount.
printf 'mount-option-%s\n' "$RUN_ID" > "$bind_dir/mount-option-marker"
set +e
bounded_capture 10 "$WORKDIR/mount-nosuid.out" "$WORKDIR/mount-nosuid.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" run --name "$MOUNT_OPTION_CONTAINER" \
  --label "dev.dory.compatibility=$OWNER" -v "$bind_dir:/share:nosuid" \
  "$ALPINE_IMAGE" true
nosuid_rc=$?
set -e
[ "$nosuid_rc" -ne 0 ] || die "unsupported nosuid bind option was silently accepted"
[ "$nosuid_rc" -ne 124 ] || die "unsupported nosuid bind option hung for ten seconds"
grep -Eiq 'invalid (mode|mount)|invalid.*nosuid|unknown.*nosuid' \
  "$WORKDIR/mount-nosuid.err" "$WORKDIR/mount-nosuid.out" \
  || die "unsupported nosuid bind option failed without an explicit validation error"
docker_e inspect "$MOUNT_OPTION_CONTAINER" >/dev/null 2>&1 \
  && die "unsupported nosuid bind option left a partial container"
docker_e run -d --name "$READ_ONLY_MOUNT_CONTAINER" \
  --label "dev.dory.compatibility=$OWNER" -v "$bind_dir:/share:ro" \
  "$ALPINE_IMAGE" sleep 300 >/dev/null
[ "$(docker_e inspect -f '{{range .Mounts}}{{if eq .Destination "/share"}}{{.RW}}{{end}}{{end}}' \
  "$READ_ONLY_MOUNT_CONTAINER")" = false ] \
  || die "Docker inspect did not retain the read-only bind contract"
docker_e exec "$READ_ONLY_MOUNT_CONTAINER" sh -ec '
  grep -q "^mount-option-" /share/mount-option-marker
  if touch /share/should-not-write 2>/dev/null; then exit 1; fi
' || die "read-only bind was unreadable or silently writable"
[ ! -e "$bind_dir/should-not-write" ] || die "read-only bind modified the host"
docker_e rm -f "$READ_ONLY_MOUNT_CONTAINER" >/dev/null
bounded_capture 5 "$WORKDIR/post-mount-option-version.out" \
  "$WORKDIR/post-mount-option-version.err" env DOCKER_HOST="unix://$SOCKET" \
  "$DOCKER_BIN" version || die "Docker API wedged after mount-option validation"
pass bind-mount-option-contract \
  "unsupported nosuid rejected explicitly without a partial container; ro retained and enforced"

# Nested bind precedence and anonymous sub-volumes have regressed independently in desktop
# VirtioFS implementations. The child bind must win at its mountpoint while its parent remains
# writable, and an anonymous child volume must not leak into the parent host directory.
nested_parent="$WORKDIR/nested-bind-parent"
nested_child="$WORKDIR/nested-bind-child"
mkdir -p "$nested_parent/nested" "$nested_parent/cache" "$nested_child"
printf parent > "$nested_parent/parent.txt"
printf child > "$nested_child/child.txt"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$nested_parent:/workspace" -v "$nested_child:/workspace/nested" \
  "$ALPINE_IMAGE" sh -ec '
    test "$(cat /workspace/parent.txt)" = parent
    test "$(cat /workspace/nested/child.txt)" = child
    printf parent-write > /workspace/from-container.txt
    printf child-write > /workspace/nested/from-container.txt
  '
[ "$(cat "$nested_parent/from-container.txt")" = parent-write ] \
  || die "nested bind corrupted the parent host mount"
[ "$(cat "$nested_child/from-container.txt")" = child-write ] \
  || die "nested child bind did not win at its mountpoint"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$nested_parent:/workspace" -v /workspace/cache \
  "$ALPINE_IMAGE" sh -ec '
    test "$(cat /workspace/parent.txt)" = parent
    printf anonymous-volume > /workspace/cache/volume.txt
  '
[ ! -e "$nested_parent/cache/volume.txt" ] \
  || die "anonymous child volume leaked through the parent host bind"
pass nested-bind-subvolume \
  "nested child precedence, parent/child writes, and anonymous child isolation passed"

# A host FIFO is the pathological case behind a competitor's whole-VM wedge: a synchronous host
# open without O_NONBLOCK can pin a vCPU forever. Dory's HostFS rejects unsupported special files
# during lookup (before Linux applies guest FIFO-open semantics), so the container operation must
# fail promptly and unrelated Docker control requests must remain live.
mkfifo "$bind_dir/test/host-fifo"
set +e
bounded_capture 5 "$WORKDIR/bind-fifo.out" "$WORKDIR/bind-fifo.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" run --rm \
  --label "dev.dory.compatibility=$OWNER" -v "$bind_dir:/share" "$ALPINE_IMAGE" \
  sh -ec 'exec dd if=/share/test/host-fifo of=/dev/null bs=1 count=1'
fifo_rc=$?
set -e
[ "$fifo_rc" -ne 0 ] || die "host FIFO unexpectedly opened as a regular bind file"
[ "$fifo_rc" -ne 124 ] || die "host FIFO open blocked the bind request for five seconds"
bounded_capture 5 "$WORKDIR/post-fifo-version.out" "$WORKDIR/post-fifo-version.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" version \
  || die "Docker API wedged after the host FIFO open attempt"
rm -f "$bind_dir/test/host-fifo"
pass bind-special-file-fail-fast "host FIFO failed promptly with exit=$fifo_rc; Docker API remained responsive"

# Exercise more opens than the observed ~8k external-volume leak threshold while touching one
# pathname. This catches a descriptor leaked per operation without turning expected identity pins
# for many distinct live dentries into noise.
bind_fd_before="$(sample_fds "$WORKDIR/fds-before-bind-churn.tsv")"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$bind_dir:/share" "$ALPINE_IMAGE" sh -ec '
    i=0
    while [ "$i" -lt 10000 ]; do
      printf "%s" "$i" > /share/test/fd-churn
      dd if=/share/test/fd-churn of=/dev/null bs=32 count=1 2>/dev/null
      i=$((i + 1))
    done
    rm -f /share/test/fd-churn
  '
sleep 2
bind_fd_after="$(sample_fds "$WORKDIR/fds-after-bind-churn.tsv")"
bind_fd_growth=$((bind_fd_after - bind_fd_before))
[ "$bind_fd_growth" -le "$FD_GROWTH_BUDGET" ] \
  || die "10,000 bind-file operations grew aggregate Dory FDs by $bind_fd_growth (budget $FD_GROWTH_BUDGET)"
pass bind-open-fd-stability \
  "operations=10000 before=$bind_fd_before after=$bind_fd_after growth=$bind_fd_growth"

# Read a restrictive hard-linked inode repeatedly through both aliases. This is the live Docker
# counterpart to HostFS's identity/virtual-ownership unit suite and catches intermittent alias
# permission failures under repeated lookup/open/forget churn.
docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  -v "$bind_dir:/share" "$ALPINE_IMAGE" sh -ec '
    printf hard-link-payload > /share/test/hard-a
    ln /share/test/hard-a /share/test/hard-b
    chmod 0400 /share/test/hard-a
    i=0
    while [ "$i" -lt 1000 ]; do
      test "$(cat /share/test/hard-a)" = hard-link-payload
      test "$(cat /share/test/hard-b)" = hard-link-payload
      i=$((i + 1))
    done
    rm -f /share/test/hard-a /share/test/hard-b
  '
pass bind-hardlink-permissions "1000 restrictive-mode reads succeeded through both hard-link aliases"

docker_e run -d --name "$HEALTH_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  --health-cmd 'test -f /tmp/ready' --health-interval 1s --health-timeout 1s \
  --health-start-period 1s --health-start-interval 250ms --health-retries 5 \
  "$ALPINE_IMAGE" sh -c 'sleep 2; touch /tmp/ready; sleep 300' >/dev/null
initial_health="$(docker_e inspect -f '{{.State.Health.Status}}' "$HEALTH_CONTAINER")"
[ "$initial_health" = starting ] || die "healthcheck did not begin in starting state (got $initial_health)"
attempts=20
health=""
while [ "$attempts" -gt 0 ]; do
  health="$(docker_e inspect -f '{{.State.Health.Status}}' "$HEALTH_CONTAINER")"
  [ "$health" = healthy ] && break
  attempts=$((attempts - 1))
  sleep 0.5
done
[ "$health" = healthy ] || die "healthcheck did not reach healthy (last=$health)"
docker_e inspect -f '{{json .Config.Healthcheck}}' "$HEALTH_CONTAINER" | grep -q 'test -f /tmp/ready' \
  || die "healthcheck configuration was not preserved"
[ "$(docker_e inspect -f '{{.State.Health.FailingStreak}}' "$HEALTH_CONTAINER")" = 0 ] \
  || die "successful healthcheck did not reset its failure streak"
[ "$(docker_e inspect -f '{{len .State.Health.Log}}' "$HEALTH_CONTAINER")" -gt 0 ] \
  || die "successful healthcheck retained no probe history"

docker_e run -d --name "$UNHEALTHY_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  --health-cmd 'false' --health-interval 500ms --health-timeout 1s --health-retries 2 \
  "$ALPINE_IMAGE" sleep 300 >/dev/null
attempts=20
unhealthy=""
while [ "$attempts" -gt 0 ]; do
  unhealthy="$(docker_e inspect -f '{{.State.Health.Status}}' "$UNHEALTHY_CONTAINER")"
  [ "$unhealthy" = unhealthy ] && break
  attempts=$((attempts - 1))
  sleep 0.5
done
[ "$unhealthy" = unhealthy ] || die "failing healthcheck did not reach unhealthy"
[ "$(docker_e inspect -f '{{.State.Health.FailingStreak}}' "$UNHEALTHY_CONTAINER")" -ge 2 ] \
  || die "unhealthy container did not retain its failure streak"
[ "$(docker_e inspect -f '{{len .State.Health.Log}}' "$UNHEALTHY_CONTAINER")" -ge 2 ] \
  || die "unhealthy container retained insufficient probe history"

docker_e run -d --name "$NO_HEALTH_CONTAINER" --label "dev.dory.compatibility=$OWNER" \
  --no-healthcheck "$ALPINE_IMAGE" sleep 300 >/dev/null
[ "$(docker_e inspect -f '{{json .Config.Healthcheck.Test}}' "$NO_HEALTH_CONTAINER")" = '["NONE"]' ] \
  || die "--no-healthcheck did not retain HEALTHCHECK NONE"
[ "$(docker_e inspect -f '{{if .State.Health}}present{{else}}none{{end}}' "$NO_HEALTH_CONTAINER")" = none ] \
  || die "HEALTHCHECK NONE unexpectedly created runtime health state"
pass healthcheck "starting->healthy, unhealthy streak/history, start interval, and NONE passed"

mkdir -p "$WORKDIR/build" "$WORKDIR/named-context"
printf '%s\n' "named-context-$RUN_ID" > "$WORKDIR/named-context/payload.txt"
cat > "$WORKDIR/build/Dockerfile" <<EOF
FROM base
COPY --from=fixture /payload.txt /payload.txt
RUN grep -qx 'named-context-$RUN_ID' /payload.txt
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/payload.txt"]
EOF
buildx_e --builder default build --progress plain --load \
  --build-context "fixture=$WORKDIR/named-context" \
  --build-context "base=docker-image://$ALPINE_IMAGE" \
  -t "$BUILD_TAG" "$WORKDIR/build" > "$WORKDIR/buildx.out" 2> "$WORKDIR/buildx.err"
[ "$(docker_e run --rm "$BUILD_TAG")" = "named-context-$RUN_ID" ] \
  || die "named BuildKit context built the wrong payload"
pass buildx-named-context "local plus docker-image named contexts built offline and ran"

# Dockerfile ARG defaults are frontend syntax, not shell syntax. Reproduce the exact nested default
# form that Apple container failed to resolve, while keeping the base image offline and digest-bound
# by assigning the already-qualified fixture a run-unique local repository name.
docker_e tag "$ALPINE_IMAGE" "$DEFAULT_ARG_BASE_REPOSITORY:latest"
default_arg_context="$WORKDIR/default-arg-build"
mkdir -p "$default_arg_context"
cat > "$default_arg_context/Dockerfile" <<EOF
ARG TAG="\${TAG:-latest}"
FROM $DEFAULT_ARG_BASE_REPOSITORY:\${TAG}
RUN printf '%s\\n' 'default-arg-$RUN_ID' > /marker
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/marker"]
EOF
DOCKER_BUILDKIT=1 docker_e build --progress plain --pull=false \
  -t "$DEFAULT_ARG_BUILD_TAG" "$default_arg_context" \
  > "$WORKDIR/default-arg-build.out" 2> "$WORKDIR/default-arg-build.err" \
  || die "BuildKit failed to expand ARG TAG=\"\${TAG:-latest}\""
[ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
    "$DEFAULT_ARG_BUILD_TAG")" = "default-arg-$RUN_ID" ] \
  || die "default ARG build produced the wrong image"
pass buildkit-default-arg \
  'ARG TAG="${TAG:-latest}" selected the run-local :latest base and produced exact output'

# When stdout is the archive, no status/reference text may follow the tar EOF records. Parse the
# stream ourselves because permissive tar readers can silently ignore precisely the trailing bytes
# that broke other OCI consumers.
image_save_tar="$WORKDIR/image-save-stdout.tar"
bounded_capture 30 "$image_save_tar" "$WORKDIR/image-save-stderr.txt" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" image save "$ALPINE_IMAGE" \
  || die "docker image save to stdout failed or exceeded 30 seconds"
tar -tf "$image_save_tar" > "$WORKDIR/image-save-members.txt" \
  || die "docker image save stdout is not a readable tar archive"
grep -qx 'manifest.json' "$WORKDIR/image-save-members.txt" \
  || die "docker image save stdout omitted manifest.json"
archive_end="$(python3 - "$image_save_tar" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
block = 512
offset = 0
zero = bytes(block)

def tar_number(field: bytes) -> int:
    if field and field[0] & 0x80:
        return int.from_bytes(field, "big") & ((1 << (len(field) * 8 - 1)) - 1)
    value = field.rstrip(b"\0 ").lstrip(b" ")
    return int(value or b"0", 8)

while offset + block <= len(data):
    header = data[offset:offset + block]
    if header == zero:
        if data[offset + block:offset + 2 * block] != zero:
            raise SystemExit("single zero block before nonzero archive data")
        if any(data[offset:]):
            raise SystemExit("nonzero bytes follow the tar EOF records")
        print(f"payload_end={offset} archive_bytes={len(data)} zero_tail={len(data)-offset}")
        break
    size = tar_number(header[124:136])
    offset += block + ((size + block - 1) // block) * block
else:
    raise SystemExit("archive has no complete two-block tar EOF marker")
PY
)" || die "docker image save stdout contains trailing non-archive bytes"
pass image-save-stdout "readable archive with manifest.json and zero-only EOF tail; $archive_end"

# Construct a layer containing a deep hard link but no explicit parent-directory records. Importing
# and exporting it must synthesize the parents and preserve the hard-link identity and exact bytes.
hardlink_root="$WORKDIR/hardlink-layer-root"
hardlink_layer="$WORKDIR/hardlink-missing-parent.tar"
hardlink_export="$WORKDIR/hardlink-import-export.tar"
hardlink_extract="$WORKDIR/hardlink-import-export"
mkdir -p "$hardlink_root/bin/app.runfiles/_main/app_" "$hardlink_extract"
printf 'hardlink-missing-parent-%s\n' "$RUN_ID" > "$hardlink_root/bin/app"
ln "$hardlink_root/bin/app" "$hardlink_root/bin/app.runfiles/_main/app_/app"
tar -cf "$hardlink_layer" -C "$hardlink_root" \
  bin/app bin/app.runfiles/_main/app_/app
tar -tf "$hardlink_layer" > "$WORKDIR/hardlink-layer-members.txt"
[ "$(wc -l < "$WORKDIR/hardlink-layer-members.txt" | tr -d '[:space:]')" = 2 ] \
  || die "hard-link fixture unexpectedly contains parent directory entries"
grep -qx 'bin/app' "$WORKDIR/hardlink-layer-members.txt" \
  || die "hard-link fixture omitted its source"
grep -qx 'bin/app.runfiles/_main/app_/app' "$WORKDIR/hardlink-layer-members.txt" \
  || die "hard-link fixture omitted its deep link"
tar -tvf "$hardlink_layer" > "$WORKDIR/hardlink-layer-verbose.txt"
grep -F 'link to bin/app' "$WORKDIR/hardlink-layer-verbose.txt" >/dev/null \
  || die "hard-link fixture did not encode its deep path as a hard link"
bounded_capture 30 "$WORKDIR/hardlink-import.out" "$WORKDIR/hardlink-import.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" import \
  "$hardlink_layer" "$HARDLINK_IMPORT_TAG" \
  || die "image import rejected a hard link whose parent has no explicit tar entry"
docker_e create --name "$HARDLINK_IMPORT_CONTAINER" \
  --label "dev.dory.compatibility=$OWNER" "$HARDLINK_IMPORT_TAG" /bin/app >/dev/null
bounded_capture 30 "$WORKDIR/hardlink-export.out" "$WORKDIR/hardlink-export.err" \
  env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" export \
  --output "$hardlink_export" "$HARDLINK_IMPORT_CONTAINER" \
  || die "export of the missing-parent hard-link image failed"
tar -xf "$hardlink_export" -C "$hardlink_extract" \
  bin/app bin/app.runfiles/_main/app_/app
cmp "$hardlink_extract/bin/app" "$hardlink_extract/bin/app.runfiles/_main/app_/app" \
  || die "imported hard-link bytes differ"
[ "$(stat -f '%i' "$hardlink_extract/bin/app")" = \
  "$(stat -f '%i' "$hardlink_extract/bin/app.runfiles/_main/app_/app")" ] \
  || die "import/export did not preserve the deep hard-link identity"
docker_e rm "$HARDLINK_IMPORT_CONTAINER" >/dev/null
pass image-hardlink-missing-parent \
  "import synthesized omitted parents and export preserved exact bytes plus hard-link identity"

large_context="$WORKDIR/large-dockerfile"
mkdir -p "$large_context"
python3 - "$large_context/Dockerfile" "$ALPINE_IMAGE" "$RUN_ID" <<'PY'
import pathlib
import sys

path, image, run_id = sys.argv[1:]
prefix = f"FROM {image}\n"
suffix = f"RUN printf '%s\\n' 'large-dockerfile-{run_id}' > /marker\nCMD [\"cat\", \"/marker\"]\n"
padding = "# dory-buildkit-large-header-regression-padding\n"
body = prefix
while len((body + suffix).encode()) < 65536:
    body += padding
body += suffix
pathlib.Path(path).write_text(body, encoding="utf-8")
assert pathlib.Path(path).stat().st_size >= 65536
PY
large_dockerfile_bytes="$(stat -f '%z' "$large_context/Dockerfile")"
[ "$large_dockerfile_bytes" -ge 65536 ] || die "large Dockerfile fixture is below 64 KiB"
DOCKER_BUILDKIT=1 docker_e build --progress=plain \
  --label "dev.dory.compatibility=$OWNER" \
  -t "$LARGE_DOCKERFILE_BUILD_TAG" "$large_context" \
  > "$WORKDIR/large-dockerfile-build.out" 2> "$WORKDIR/large-dockerfile-build.err" \
  || die "64 KiB Dockerfile build failed"
[ "$(docker_e run --rm "$LARGE_DOCKERFILE_BUILD_TAG")" = "large-dockerfile-$RUN_ID" ] \
  || die "64 KiB Dockerfile build produced the wrong image"
pass buildkit-large-dockerfile \
  "Dockerfile bytes=$large_dockerfile_bytes crossed the 16KiB transport edge and built exact output"

mkdir -p "$WORKDIR/relative-build/nested"
printf 'relative-context-%s\n' "$RUN_ID" > "$WORKDIR/relative-build/nested/payload.txt"
printf 'build-secret-%s\n' "$RUN_ID" > "$WORKDIR/relative-build/secret.txt"
chmod 0400 "$WORKDIR/relative-build/secret.txt"
printf 'secret.txt\n' > "$WORKDIR/relative-build/.dockerignore"
cat > "$WORKDIR/relative-build/Dockerfile" <<EOF
# syntax=docker/dockerfile:1
FROM $ALPINE_IMAGE
COPY nested/payload.txt /payload.txt
RUN grep -qx 'relative-context-$RUN_ID' /payload.txt
RUN --mount=type=secret,id=fixture,required=true \
    grep -qx 'build-secret-$RUN_ID' /run/secrets/fixture
RUN test ! -e /run/secrets/fixture
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/payload.txt"]
EOF
(cd "$WORKDIR/relative-build" && DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" build \
  --progress plain --secret id=fixture,src=secret.txt \
  -t "$RELATIVE_BUILD_TAG" -f Dockerfile .) \
  > "$WORKDIR/relative-build.out" 2> "$WORKDIR/relative-build.err"
[ "$(docker_e run --rm "$RELATIVE_BUILD_TAG")" = "relative-context-$RUN_ID" ] \
  || die "relative BuildKit context from a temporary directory produced the wrong payload"
pass buildkit-relative-temp-context \
  "relative dot context and required non-leaking mode-0400 secret under the temporary tree passed"

# Match Docker's layered ignore/unignore semantics used by Rails and other generated projects.
# Both nested .gitkeep files must re-enter the context without the excluded sibling payloads or an
# out-of-order context-stream failure.
dockerignore_context="$WORKDIR/dockerignore-context"
mkdir -p "$dockerignore_context/foo/bar"
printf keep-root > "$dockerignore_context/foo/.gitkeep"
printf drop-root > "$dockerignore_context/foo/drop.txt"
printf keep-nested > "$dockerignore_context/foo/bar/.gitkeep"
printf drop-nested > "$dockerignore_context/foo/bar/drop.txt"
cat > "$dockerignore_context/.dockerignore" <<'EOF'
/foo/*
!/foo/.gitkeep

/foo/bar/*
!/foo/bar/.gitkeep
EOF
cat > "$dockerignore_context/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
COPY . /context
RUN test "\$(cat /context/foo/.gitkeep)" = keep-root \
 && test "\$(cat /context/foo/bar/.gitkeep)" = keep-nested \
 && test ! -e /context/foo/drop.txt \
 && test ! -e /context/foo/bar/drop.txt
LABEL dev.dory.compatibility="$OWNER"
CMD ["true"]
EOF
docker_e build --progress plain -t "$DOCKERIGNORE_BUILD_TAG" "$dockerignore_context" \
  > "$WORKDIR/dockerignore-build.out" 2> "$WORKDIR/dockerignore-build.err" \
  || die "layered .dockerignore unignore build failed"
docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$DOCKERIGNORE_BUILD_TAG"
pass dockerignore-layered-unignore \
  "root/nested .gitkeep files included, excluded siblings absent, and context stream remained ordered"

# A successful single build does not prove that independent BuildKit session streams remain
# isolated. Run four required-secret builds at the same time, keep them overlapped in RUN, and
# require each resulting image to contain only its own context bytes.
parallel_pids=()
parallel_index=1
while [ "$parallel_index" -le 4 ]; do
  parallel_context="$WORKDIR/parallel-build-$parallel_index"
  mkdir -p "$parallel_context"
  printf 'parallel-%s\n' "$parallel_index" > "$parallel_context/payload.txt"
  printf 'secret-%s\n' "$parallel_index" > "$parallel_context/secret.txt"
  chmod 0400 "$parallel_context/secret.txt"
  printf 'secret.txt\n' > "$parallel_context/.dockerignore"
  cat > "$parallel_context/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
COPY payload.txt /payload.txt
RUN --mount=type=secret,id=fixture,required=true \
    test "\$(cat /run/secrets/fixture)" = secret-$parallel_index && sleep 2
RUN test "\$(cat /payload.txt)" = parallel-$parallel_index
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/payload.txt"]
EOF
  (
    docker_e build --progress plain \
      --secret "id=fixture,src=$parallel_context/secret.txt" \
      -t "$PARALLEL_BUILD_REPOSITORY:$RUN_ID-$parallel_index" "$parallel_context" \
      > "$WORKDIR/parallel-build-$parallel_index.out" \
      2> "$WORKDIR/parallel-build-$parallel_index.err"
  ) &
  parallel_pids+=("$!")
  parallel_index=$((parallel_index + 1))
done
parallel_failed=0
for parallel_pid in "${parallel_pids[@]}"; do
  if ! wait "$parallel_pid"; then
    parallel_failed=1
  fi
done
[ "$parallel_failed" -eq 0 ] || die "one or more concurrent BuildKit sessions failed"
parallel_index=1
while [ "$parallel_index" -le 4 ]; do
  [ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
      "$PARALLEL_BUILD_REPOSITORY:$RUN_ID-$parallel_index")" = "parallel-$parallel_index" ] \
    || die "concurrent BuildKit session $parallel_index produced the wrong context bytes"
  parallel_index=$((parallel_index + 1))
done
pass buildkit-concurrent-sessions \
  "four overlapping required-secret builds produced four isolated exact context payloads"

# BuildKit regressions have left cache exporters or cancelled solves alive while later clients hang.
# Prove the exact bundled Buildx can round-trip a local cache, cancel an active solve promptly, and
# complete a fresh solve plus Docker API probe without restarting the engine.
buildkit_cache_context="$WORKDIR/buildkit-cache-context"
buildkit_cache_dir="$WORKDIR/buildkit-local-cache"
mkdir -p "$buildkit_cache_context"
printf 'cache-roundtrip-%s\n' "$RUN_ID" > "$buildkit_cache_context/payload.txt"
cat > "$buildkit_cache_context/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
COPY payload.txt /payload.txt
RUN cp /payload.txt /marker
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/marker"]
EOF
bounded_capture 120 "$WORKDIR/buildkit-cache-export.out" \
  "$WORKDIR/buildkit-cache-export.err" buildx_e --builder default build \
  --progress plain --cache-to "type=local,dest=$buildkit_cache_dir,mode=max" \
  --load --tag "$BUILDKIT_CACHE_TAG" -- "$buildkit_cache_context" \
  || die "BuildKit local-cache export failed or exceeded 120 seconds"
[ -s "$buildkit_cache_dir/index.json" ] || die "BuildKit local-cache export omitted index.json"
[ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$BUILDKIT_CACHE_TAG")" = \
  "cache-roundtrip-$RUN_ID" ] || die "BuildKit cache-export image produced the wrong payload"
docker_e image rm "$BUILDKIT_CACHE_TAG" >/dev/null
bounded_capture 120 "$WORKDIR/buildkit-cache-import.out" \
  "$WORKDIR/buildkit-cache-import.err" buildx_e --builder default build \
  --progress plain --cache-from "type=local,src=$buildkit_cache_dir" \
  --load --tag "$BUILDKIT_CACHE_TAG" -- "$buildkit_cache_context" \
  || die "BuildKit local-cache import failed or exceeded 120 seconds"
grep -q 'CACHED' "$WORKDIR/buildkit-cache-import.out" "$WORKDIR/buildkit-cache-import.err" \
  || die "BuildKit local-cache import did not reuse an exported result"
[ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$BUILDKIT_CACHE_TAG")" = \
  "cache-roundtrip-$RUN_ID" ] || die "BuildKit cache-import image produced the wrong payload"
shasum -a 256 "$buildkit_cache_dir/index.json" > "$WORKDIR/buildkit-local-cache-index.sha256"
rm -rf "$buildkit_cache_dir"

buildkit_cancel_context="$WORKDIR/buildkit-cancel-context"
mkdir -p "$buildkit_cancel_context"
cat > "$buildkit_cancel_context/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
RUN echo buildkit-cancellation-started-$RUN_ID && sleep 300
LABEL dev.dory.compatibility="$OWNER"
EOF
buildx_e --builder default build --progress plain --load \
  --tag "$BUILDKIT_CANCEL_TAG" -- "$buildkit_cancel_context" \
  > "$WORKDIR/buildkit-cancel.out" 2> "$WORKDIR/buildkit-cancel.err" &
CANCEL_BUILDX_PID=$!
cancel_started=$SECONDS
while kill -0 "$CANCEL_BUILDX_PID" 2>/dev/null \
    && ! grep -q "buildkit-cancellation-started-$RUN_ID" \
      "$WORKDIR/buildkit-cancel.out" "$WORKDIR/buildkit-cancel.err"; do
  [ $((SECONDS - cancel_started)) -lt 60 ] || break
  sleep 0.1
done
grep -q "buildkit-cancellation-started-$RUN_ID" \
  "$WORKDIR/buildkit-cancel.out" "$WORKDIR/buildkit-cancel.err" \
  || die "BuildKit cancellation fixture did not enter its active solve"
kill -TERM "$CANCEL_BUILDX_PID"
cancel_deadline=$((SECONDS + 10))
while kill -0 "$CANCEL_BUILDX_PID" 2>/dev/null && [ "$SECONDS" -lt "$cancel_deadline" ]; do
  sleep 0.1
done
if kill -0 "$CANCEL_BUILDX_PID" 2>/dev/null; then
  kill -KILL "$CANCEL_BUILDX_PID" 2>/dev/null || true
  wait "$CANCEL_BUILDX_PID" 2>/dev/null || true
  CANCEL_BUILDX_PID=""
  die "Buildx client did not terminate within ten seconds of cancellation"
fi
set +e
wait "$CANCEL_BUILDX_PID"
cancel_rc=$?
set -e
CANCEL_BUILDX_PID=""
[ "$cancel_rc" -ne 0 ] || die "cancelled BuildKit solve unexpectedly succeeded"
! docker_e image inspect "$BUILDKIT_CANCEL_TAG" >/dev/null 2>&1 \
  || die "cancelled BuildKit solve published an image"

cat > "$buildkit_cancel_context/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
RUN printf '%s\n' 'post-cancel-$RUN_ID' > /marker
LABEL dev.dory.compatibility="$OWNER"
CMD ["cat", "/marker"]
EOF
bounded_capture 60 "$WORKDIR/buildkit-post-cancel.out" \
  "$WORKDIR/buildkit-post-cancel.err" buildx_e --builder default build \
  --progress plain --load --tag "$BUILDKIT_RECOVERY_TAG" -- "$buildkit_cancel_context" \
  || die "fresh BuildKit solve failed or exceeded 60 seconds after cancellation"
[ "$(docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$BUILDKIT_RECOVERY_TAG")" = \
  "post-cancel-$RUN_ID" ] || die "post-cancellation BuildKit solve produced the wrong payload"
bounded_capture 10 "$WORKDIR/buildkit-post-cancel-version.out" \
  "$WORKDIR/buildkit-post-cancel-version.err" docker_e version \
  || die "Docker API failed or exceeded ten seconds after BuildKit cancellation"
pass buildkit-cache-cancellation \
  "local cache export/import reused exact output; active solve cancelled within 10s; fresh solve and API recovered without restart"

docker_e run --rm --label "dev.dory.compatibility=$OWNER" "$ALPINE_IMAGE" sh -ec \
  'grep -q "^nameserver[[:space:]]" /etc/resolv.conf; ! grep -q "^search[[:space:]]" /etc/resolv.conf'
pass container-resolver-contract "nameserver present; no stale search directive"

docker_e run --rm --label "dev.dory.compatibility=$OWNER" \
  --dns-search dev.dory.test "$ALPINE_IMAGE" sh -ec \
  'grep -q "^nameserver[[:space:]]" /etc/resolv.conf; awk '\''$1 == "search" { for (i=2; i<=NF; i++) if ($i == "dev.dory.test") found=1 } END { exit !found }'\'' /etc/resolv.conf' \
  > "$WORKDIR/custom-dns-search.out" 2> "$WORKDIR/custom-dns-search.err" \
  || die "explicit Docker DNS search domain was not preserved"
pass container-dns-search "explicit --dns-search dev.dory.test present with a nameserver"

GATE_COMPLETED=1
cleanup
trap - EXIT INT TERM
leftovers="$(docker_e ps -aq --filter "label=dev.dory.compatibility=$OWNER" 2>/dev/null || true)"
[ -z "$leftovers" ] || die "owned container cleanup failed: $leftovers"
leftover_networks="$(docker_e network ls -q --filter "label=dev.dory.compatibility=$OWNER" 2>/dev/null || true)"
[ -z "$leftover_networks" ] || die "owned network cleanup failed: $leftover_networks"
docker_e volume inspect "$VOLUME" >/dev/null 2>&1 && die "owned volume cleanup failed"
docker_e volume inspect "$VOLUME_METADATA" >/dev/null 2>&1 \
  && die "owned metadata volume cleanup failed"
docker_e network inspect "$NETWORK_METADATA" >/dev/null 2>&1 \
  && die "owned metadata network cleanup failed"
docker_e image inspect "$BUILD_TAG" >/dev/null 2>&1 && die "owned build image cleanup failed"
docker_e image inspect "$DEFAULT_ARG_BUILD_TAG" >/dev/null 2>&1 \
  && die "owned default-ARG build image cleanup failed"
docker_e image inspect "$HARDLINK_IMPORT_TAG" >/dev/null 2>&1 \
  && die "owned hard-link import image cleanup failed"
docker_e image inspect "$BUILDKIT_CACHE_TAG" >/dev/null 2>&1 \
  && die "owned BuildKit cache-roundtrip image cleanup failed"
docker_e image inspect "$BUILDKIT_RECOVERY_TAG" >/dev/null 2>&1 \
  && die "owned BuildKit recovery image cleanup failed"
docker_e image inspect "$BUILDKIT_CANCEL_TAG" >/dev/null 2>&1 \
  && die "cancelled BuildKit image appeared during cleanup"
if [ -n "$RUNTIME" ]; then
  bounded_capture 30 "$WORKDIR/cleanup-persistence-stop.out" \
    "$WORKDIR/cleanup-persistence-stop.err" env HOME="$RUNTIME_HOME" "$RUNTIME" stop \
    || die "cleanup-persistence engine stop failed or exceeded 30 seconds"
  bounded_capture 60 "$WORKDIR/cleanup-persistence-start.out" \
    "$WORKDIR/cleanup-persistence-start.err" env HOME="$RUNTIME_HOME" "$RUNTIME" start \
    || die "cleanup-persistence engine start failed or exceeded 60 seconds"
  curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null \
    || die "engine did not recover for cleanup-persistence verification"
  [ -z "$(docker_e ps -aq --filter "label=dev.dory.compatibility=$OWNER")" ] \
    || die "owned containers reappeared after engine restart"
  [ -z "$(docker_e network ls -q --filter "label=dev.dory.compatibility=$OWNER")" ] \
    || die "owned networks reappeared after engine restart"
  docker_e volume inspect "$VOLUME" >/dev/null 2>&1 \
    && die "owned volume reappeared after engine restart"
  docker_e volume inspect "$VOLUME_METADATA" >/dev/null 2>&1 \
    && die "owned metadata volume reappeared after engine restart"
  docker_e network inspect "$NETWORK_METADATA" >/dev/null 2>&1 \
    && die "owned metadata network reappeared after engine restart"
  docker_e image inspect "$BUILD_TAG" >/dev/null 2>&1 \
    && die "owned build image reappeared after engine restart"
  docker_e image inspect "$BUILDKIT_CACHE_TAG" >/dev/null 2>&1 \
    && die "owned BuildKit cache-roundtrip image reappeared after engine restart"
  docker_e image inspect "$BUILDKIT_RECOVERY_TAG" >/dev/null 2>&1 \
    && die "owned BuildKit recovery image reappeared after engine restart"
  pass cleanup-restart-persistence \
    "owned containers, networks, volume, and build image stayed deleted after engine restart"
fi
if [ -s "$STATE_DIR/engine-settings" ]; then
  cp "$STATE_DIR/engine-settings" "$WORKDIR/engine-settings.txt"
  echo "engine_settings_sha256=$(shasum -a 256 "$WORKDIR/engine-settings.txt" | awk '{print $1}')" \
    >> "$MANIFEST"
fi
echo "completed_epoch=$(date +%s)" >> "$MANIFEST"
echo "competitor runtime regression gate PASS; evidence: $WORKDIR"
