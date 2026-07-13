#!/bin/bash
# Isolated reproduction campaign for engine wedges under automatic restart churn plus guest memory
# pressure. Requires a disposable standalone Dory HOME with zero pre-existing containers.
set -euo pipefail

SOCKET="${DORY_PRESSURE_SOCKET:-$HOME/.dory/engine.sock}"
STATE_DIR="${DORY_PRESSURE_STATE_DIR:-$(dirname "$SOCKET")}"
RUNTIME="${DORY_PRESSURE_RUNTIME:-}"
RUNTIME_HOME="${DORY_PRESSURE_RUNTIME_HOME:-$(dirname "$STATE_DIR")}"
DOCKER_BIN="${DORY_PRESSURE_DOCKER_BIN:-docker}"
ALPINE_IMAGE="${DORY_PRESSURE_IMAGE:-alpine:latest}"
WORKROOT="${DORY_PRESSURE_WORKROOT:-$HOME/.dory-restart-pressure}"
DURATION="${DORY_PRESSURE_DURATION:-1800}"
CHURN_CONTAINERS="${DORY_PRESSURE_CHURN_CONTAINERS:-4}"
PRESSURE_CONTAINERS="${DORY_PRESSURE_CONTAINERS:-3}"
PRESSURE_MB="${DORY_PRESSURE_MB:-192}"
PROBE_INTERVAL="${DORY_PRESSURE_PROBE_INTERVAL:-2}"

usage() {
  cat <<EOF
Usage: scripts/restart-pressure-soak.sh [options]

Options:
  --socket PATH          Disposable Dory Docker socket
  --state-dir PATH       State path used to identify exact engine processes
  --runtime PATH         Required standalone dory-engine launcher
  --runtime-home PATH    Disposable HOME owned by the launcher
  --docker PATH          Docker CLI to qualify (default: docker from PATH)
  --image REF            Existing offline Alpine image (default: alpine:latest)
  --workroot PATH        Evidence root (default: ~/.dory-restart-pressure)
  --duration SECONDS     Campaign duration (default: $DURATION)
  --churn N              Auto-restarting containers (default: $CHURN_CONTAINERS)
  --pressure N           tmpfs pressure containers (default: $PRESSURE_CONTAINERS)
  --pressure-mb N        Allocated tmpfs MiB per pressure container (default: $PRESSURE_MB)
  --probe-interval N     Seconds between bounded API sweeps (default: $PROBE_INTERVAL)
  -h, --help

The default campaign holds approximately $((PRESSURE_CONTAINERS * PRESSURE_MB)) MiB in guest
tmpfs while containers repeatedly exit under restart=always. Every inspect/logs/stats/ps call has
a deadline. The launcher is used only for bounded recovery if the isolated engine wedges.
EOF
}

die() { echo "restart-pressure-soak: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --state-dir) need_value "$1" "$#"; STATE_DIR="$2"; shift 2 ;;
    --runtime) need_value "$1" "$#"; RUNTIME="$2"; shift 2 ;;
    --runtime-home) need_value "$1" "$#"; RUNTIME_HOME="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER_BIN="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; ALPINE_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --duration) need_value "$1" "$#"; DURATION="$2"; shift 2 ;;
    --churn) need_value "$1" "$#"; CHURN_CONTAINERS="$2"; shift 2 ;;
    --pressure) need_value "$1" "$#"; PRESSURE_CONTAINERS="$2"; shift 2 ;;
    --pressure-mb) need_value "$1" "$#"; PRESSURE_MB="$2"; shift 2 ;;
    --probe-interval) need_value "$1" "$#"; PROBE_INTERVAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}
positive_integer duration "$DURATION"
positive_integer churn "$CHURN_CONTAINERS"
positive_integer pressure "$PRESSURE_CONTAINERS"
positive_integer pressure-mb "$PRESSURE_MB"
positive_integer probe-interval "$PROBE_INTERVAL"
[ -n "$RUNTIME" ] || die "--runtime is required for bounded recovery"
[ -x "$RUNTIME" ] || die "standalone runtime is not executable: $RUNTIME"
[ -d "$RUNTIME_HOME" ] || die "standalone runtime HOME is unavailable: $RUNTIME_HOME"
[ -d "$STATE_DIR" ] || die "Dory state directory is unavailable: $STATE_DIR"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
for command in curl lsof ps python3; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
if [[ "$DOCKER_BIN" == */* ]]; then
  [ -x "$DOCKER_BIN" ] || die "Docker CLI is not executable: $DOCKER_BIN"
else
  command -v "$DOCKER_BIN" >/dev/null || die "Docker CLI is unavailable: $DOCKER_BIN"
fi

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
docker_e image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 \
  || die "required offline image is missing: $ALPINE_IMAGE"
[ -z "$(docker_e ps -aq)" ] \
  || die "pressure campaign requires an isolated engine with zero pre-existing containers"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-pressure-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/probes.tsv"
RESOURCES="$WORKDIR/resources.tsv"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"
printf 'sweep\tepoch\telapsed\trestarts\tstatus\n' > "$RESULTS"
printf 'phase\tepoch\tpid_count\tfd_total\trss_kb\tcpu_percent\n' > "$RESOURCES"
{
  echo "run_id=$RUN_ID"
  echo "socket=$SOCKET"
  echo "state_dir=$STATE_DIR"
  echo "runtime=$RUNTIME"
  echo "runtime_home=$RUNTIME_HOME"
  echo "image=$ALPINE_IMAGE"
  echo "duration_seconds=$DURATION"
  echo "churn_containers=$CHURN_CONTAINERS"
  echo "pressure_containers=$PRESSURE_CONTAINERS"
  echo "pressure_mb_each=$PRESSURE_MB"
  echo "pressure_mb_total=$((PRESSURE_CONTAINERS * PRESSURE_MB))"
  echo "probe_interval=$PROBE_INTERVAL"
  echo "started_epoch=$(date +%s)"
} > "$MANIFEST"

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

engine_ready() {
  [ -S "$SOCKET" ] \
    && curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null 2>&1
}

recover_engine() {
  bounded_capture 30 "$WORKDIR/recovery-stop.out" "$WORKDIR/recovery-stop.err" \
    env HOME="$RUNTIME_HOME" "$RUNTIME" stop || true
  bounded_capture 60 "$WORKDIR/recovery-start.out" "$WORKDIR/recovery-start.err" \
    env HOME="$RUNTIME_HOME" "$RUNTIME" start || return 1
  local attempts=100
  while [ "$attempts" -gt 0 ]; do
    engine_ready && return 0
    attempts=$((attempts - 1))
    sleep 0.2
  done
  return 1
}

cleanup_owned() {
  local id index=0
  engine_ready || recover_engine || return 0
  docker_e ps -aq --filter "label=dev.dory.pressure=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] || continue
    index=$((index + 1))
    bounded_capture 10 "$WORKDIR/cleanup-$index.out" "$WORKDIR/cleanup-$index.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" rm -f -v "$id" || true
  done
}
cleanup() {
  # A partially responsive daemon may answer /_ping while hanging container endpoints. Restarting
  # the disposable engine first gives signal/error cleanup a bounded path back to owned objects.
  recover_engine || true
  cleanup_owned
}
trap cleanup EXIT INT TERM

candidate_pids() {
  ps axww -o pid=,command= | awk -v state="$STATE_DIR" -v socket="$SOCKET" '
    (index($0, state) || index($0, socket)) &&
    ($0 ~ /\/dory-hv / || $0 ~ /\/gvproxy / || $0 ~ /\/dory-dataplane-proxy /) { print $1 }
  '
}

sample_resources() {
  local phase="$1" pid count=0 pids=0 fd=0 rss=0 cpu=0 one
  for pid in $(candidate_pids); do
    kill -0 "$pid" 2>/dev/null || continue
    pids=$((pids + 1))
    one="$(lsof -n -P -p "$pid" 2>/dev/null | awk 'NR > 1 {n++} END {print n+0}')"
    fd=$((fd + one))
    one="$(ps -p "$pid" -o rss= 2>/dev/null | awk 'NF {print $1; exit}')"
    rss=$((rss + ${one:-0}))
    one="$(ps -p "$pid" -o %cpu= 2>/dev/null | awk 'NF {print $1; exit}')"
    cpu="$(awk -v a="$cpu" -v b="${one:-0}" 'BEGIN {printf "%.2f", a+b}')"
  done
  [ "$pids" -gt 0 ] || die "no exact Dory engine processes matched $STATE_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$(date +%s)" "$pids" "$fd" "$rss" "$cpu" >> "$RESOURCES"
}

i=1
while [ "$i" -le "$PRESSURE_CONTAINERS" ]; do
  name="$OWNER-memory-$i"
  docker_e run -d --name "$name" --label "dev.dory.pressure=$OWNER" \
    --tmpfs "/pressure:rw,size=${PRESSURE_MB}m" "$ALPINE_IMAGE" sh -ec \
    "dd if=/dev/zero of=/pressure/blob bs=1048576 count=$PRESSURE_MB 2>/dev/null; exec sleep 3600" >/dev/null
  i=$((i + 1))
done

i=1
while [ "$i" -le "$CHURN_CONTAINERS" ]; do
  name="$OWNER-churn-$i"
  docker_e run -d --name "$name" --label "dev.dory.pressure=$OWNER" --restart always \
    "$ALPINE_IMAGE" sh -c 'sleep 11; exit 23' >/dev/null
  i=$((i + 1))
done

attempts=120
while [ "$attempts" -gt 0 ]; do
  ready=1
  i=1
  while [ "$i" -le "$PRESSURE_CONTAINERS" ]; do
    name="$OWNER-memory-$i"
    [ "$(docker_e inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" = true ] || ready=0
    [ "$(docker_e exec "$name" sh -c 'wc -c < /pressure/blob' 2>/dev/null | tr -d ' ')" = "$((PRESSURE_MB * 1024 * 1024))" ] || ready=0
    i=$((i + 1))
  done
  [ "$ready" -eq 1 ] && break
  attempts=$((attempts - 1))
  sleep 0.5
done
[ "$attempts" -gt 0 ] || die "guest memory-pressure fixtures did not become ready"

sample_resources baseline
STARTED="$(date +%s)"
sweep=0
while :; do
  now="$(date +%s)"
  elapsed=$((now - STARTED))
  [ "$elapsed" -lt "$DURATION" ] || break
  sweep=$((sweep + 1))
  prefix="$WORKDIR/sweep-$sweep"
  bounded_capture 5 "$prefix-ps.out" "$prefix-ps.err" \
    env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" ps -a \
    || die "docker ps failed or wedged at sweep $sweep"
  total_restarts=0
  i=1
  while [ "$i" -le "$CHURN_CONTAINERS" ]; do
    name="$OWNER-churn-$i"
    bounded_capture 5 "$prefix-churn-$i-inspect.out" "$prefix-churn-$i-inspect.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" inspect "$name" \
      || die "inspect failed or wedged for $name at sweep $sweep"
    restarts="$(docker_e inspect -f '{{.RestartCount}}' "$name")"
    total_restarts=$((total_restarts + restarts))
    set +e
    bounded_capture 5 "$prefix-churn-$i-logs.out" "$prefix-churn-$i-logs.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" logs "$name"
    rc=$?
    set -e
    [ "$rc" -ne 124 ] || die "logs wedged for $name at sweep $sweep"
    set +e
    bounded_capture 5 "$prefix-churn-$i-stats.out" "$prefix-churn-$i-stats.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER_BIN" stats --no-stream "$name"
    rc=$?
    set -e
    [ "$rc" -ne 124 ] || die "stats wedged for $name at sweep $sweep"
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\t%s\tPASS\n' "$sweep" "$now" "$elapsed" "$total_restarts" >> "$RESULTS"
  [ $((sweep % 15)) -ne 0 ] || sample_resources "sweep-$sweep"
  sleep "$PROBE_INTERVAL"
done

final_restarts=0
i=1
while [ "$i" -le "$CHURN_CONTAINERS" ]; do
  name="$OWNER-churn-$i"
  restarts="$(docker_e inspect -f '{{.RestartCount}}' "$name")"
  [ "$restarts" -gt 0 ] || die "$name never completed a restart cycle"
  final_restarts=$((final_restarts + restarts))
  i=$((i + 1))
done
sample_resources final

cleanup_owned
leftovers="$(docker_e ps -aq --filter "label=dev.dory.pressure=$OWNER" 2>/dev/null || true)"
[ -z "$leftovers" ] || die "owned container cleanup failed: $leftovers"

# Recreate every former name after cleanup. A phantom name reservation is a release failure even
# if `docker ps` no longer exposes the original object.
i=1
while [ "$i" -le "$CHURN_CONTAINERS" ]; do
  name="$OWNER-churn-$i"
  docker_e create --name "$name" --label "dev.dory.pressure=$OWNER" "$ALPINE_IMAGE" true >/dev/null \
    || die "phantom reservation prevented reuse of $name"
  docker_e rm "$name" >/dev/null
  i=$((i + 1))
done

trap - EXIT INT TERM
echo "completed_epoch=$(date +%s)" >> "$MANIFEST"
echo "restart pressure soak PASS: sweeps=$sweep restarts=$final_restarts; evidence: $WORKDIR"
