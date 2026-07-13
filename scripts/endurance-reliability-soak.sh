#!/bin/bash
# Eight-hour release gate for the user-visible failure modes behind intermittent shares, leaked
# descriptors, high idle CPU/memory, and unbounded engine-state growth. Every Docker object is
# run-scoped and labeled; the gate never pulls workload images implicitly.
set -euo pipefail

SOCKET="${DORY_ENDURANCE_SOCKET:-$HOME/.dory/dory.sock}"
STATE_DIR="${DORY_ENDURANCE_STATE_DIR:-$HOME/.dory}"
ALPINE_IMAGE="${DORY_ENDURANCE_ALPINE_IMAGE:-alpine:latest}"
WORKROOT="${DORY_ENDURANCE_WORKROOT:-$HOME/.dory-reliability}"
DURATION_SECONDS="${DORY_ENDURANCE_DURATION_SECONDS:-28800}"
CYCLES="${DORY_ENDURANCE_CYCLES:-0}"
FILES_PER_CYCLE="${DORY_ENDURANCE_FILES_PER_CYCLE:-100}"
COMPOSE_EVERY="${DORY_ENDURANCE_COMPOSE_EVERY:-5}"
SETTLE_SECONDS="${DORY_ENDURANCE_SETTLE_SECONDS:-2}"
FD_GROWTH_BUDGET="${DORY_ENDURANCE_FD_GROWTH_BUDGET:-16}"
RSS_GROWTH_MB="${DORY_ENDURANCE_RSS_GROWTH_MB:-384}"
DISK_GROWTH_MB="${DORY_ENDURANCE_DISK_GROWTH_MB:-256}"
IDLE_CPU_PERCENT="${DORY_ENDURANCE_IDLE_CPU_PERCENT:-25}"
FSEVENTSD_RSS_GROWTH_MB="${DORY_ENDURANCE_FSEVENTSD_RSS_GROWTH_MB:-128}"
FSEVENTSD_CPU_PERCENT="${DORY_ENDURANCE_FSEVENTSD_CPU_PERCENT:-25}"
MIN_FREE_GB="${DORY_ENDURANCE_MIN_FREE_GB:-2}"
PROCESS_PATTERN="${DORY_ENDURANCE_PROCESS_PATTERN:-(^|/)(Dory|doryd|dory-hv|dory-vmm|dory-dataplane-proxy|gvproxy)( |$)}"

usage() {
  cat <<EOF
Usage: scripts/endurance-reliability-soak.sh [options]

Options:
  --socket PATH         Dory Docker socket (default: ~/.dory/dory.sock)
  --state-dir PATH      Dory state measured for disk growth (default: ~/.dory)
  --duration SECONDS    Minimum wall duration; default 28800 (8 hours)
  --cycles N            Exact cycle count; overrides --duration when greater than zero
  --files N             Host/guest create-delete files per cycle (default: $FILES_PER_CYCLE)
  --compose-every N     Run Compose every N cycles (default: $COMPOSE_EVERY)
  --settle SECONDS      Idle settle after each cleaned cycle (default: $SETTLE_SECONDS)
  --workroot PATH       Result root (default: ~/.dory-reliability)
  --fd-growth N         Aggregate Dory FD growth budget (default: $FD_GROWTH_BUDGET)
  --rss-growth-mb N     Aggregate Dory RSS growth budget (default: $RSS_GROWTH_MB)
  --disk-growth-mb N    Dory state growth budget after cleanup (default: $DISK_GROWTH_MB)
  --idle-cpu PERCENT    Final aggregate idle CPU ceiling (default: $IDLE_CPU_PERCENT)
  --fseventsd-rss-growth-mb N
                        Host fseventsd RSS growth budget (default: $FSEVENTSD_RSS_GROWTH_MB)
  --fseventsd-cpu PERCENT
                        Final host fseventsd CPU ceiling (default: $FSEVENTSD_CPU_PERCENT)
  --min-free-gb N       Abort before logs become unwritable below N GiB free (default: $MIN_FREE_GB)
  --process-pattern RE  pgrep -f regex used to attribute candidate processes
  -h, --help

The release gate uses the default 8-hour duration. --cycles is intended only for regression and
preflight runs and is recorded in the manifest so it cannot be mistaken for overnight evidence.
EOF
}

die() { echo "endurance-soak: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --state-dir) need_value "$1" "$#"; STATE_DIR="$2"; shift 2 ;;
    --duration) need_value "$1" "$#"; DURATION_SECONDS="$2"; shift 2 ;;
    --cycles) need_value "$1" "$#"; CYCLES="$2"; shift 2 ;;
    --files) need_value "$1" "$#"; FILES_PER_CYCLE="$2"; shift 2 ;;
    --compose-every) need_value "$1" "$#"; COMPOSE_EVERY="$2"; shift 2 ;;
    --settle) need_value "$1" "$#"; SETTLE_SECONDS="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --fd-growth) need_value "$1" "$#"; FD_GROWTH_BUDGET="$2"; shift 2 ;;
    --rss-growth-mb) need_value "$1" "$#"; RSS_GROWTH_MB="$2"; shift 2 ;;
    --disk-growth-mb) need_value "$1" "$#"; DISK_GROWTH_MB="$2"; shift 2 ;;
    --idle-cpu) need_value "$1" "$#"; IDLE_CPU_PERCENT="$2"; shift 2 ;;
    --fseventsd-rss-growth-mb) need_value "$1" "$#"; FSEVENTSD_RSS_GROWTH_MB="$2"; shift 2 ;;
    --fseventsd-cpu) need_value "$1" "$#"; FSEVENTSD_CPU_PERCENT="$2"; shift 2 ;;
    --min-free-gb) need_value "$1" "$#"; MIN_FREE_GB="$2"; shift 2 ;;
    --process-pattern) need_value "$1" "$#"; PROCESS_PATTERN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

nonnegative_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer" ;; esac
}
for pair in \
  "duration:$DURATION_SECONDS" "cycles:$CYCLES" "files:$FILES_PER_CYCLE" \
  "compose-every:$COMPOSE_EVERY" "settle:$SETTLE_SECONDS" \
  "fd-growth:$FD_GROWTH_BUDGET" "rss-growth-mb:$RSS_GROWTH_MB" \
  "disk-growth-mb:$DISK_GROWTH_MB" "idle-cpu:$IDLE_CPU_PERCENT" \
  "fseventsd-rss-growth-mb:$FSEVENTSD_RSS_GROWTH_MB" \
  "fseventsd-cpu:$FSEVENTSD_CPU_PERCENT" \
  "min-free-gb:$MIN_FREE_GB"; do
  nonnegative_integer "${pair%%:*}" "${pair#*:}"
done
[ "$CYCLES" -gt 0 ] || [ "$DURATION_SECONDS" -gt 0 ] || die "duration or cycles must be positive"
[ "$FILES_PER_CYCLE" -gt 0 ] || die "files must be positive"
[ "$COMPOSE_EVERY" -gt 0 ] || die "compose-every must be positive"
[ "$MIN_FREE_GB" -gt 0 ] || die "min-free-gb must be positive"

if [ "${DORY_ENDURANCE_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

for command in docker curl python3 lsof ps du shasum; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -d "$STATE_DIR" ] || die "Dory state directory is unavailable: $STATE_DIR"

docker_e() { DOCKER_HOST="unix://$SOCKET" docker "$@"; }
docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
docker_e image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 \
  || die "required offline image is missing: $ALPINE_IMAGE"
docker_e compose version >/dev/null 2>&1 || die "docker compose plugin is unavailable"

disk_probe_path="$WORKROOT"
while [ ! -e "$disk_probe_path" ] && [ "$disk_probe_path" != "/" ]; do
  disk_probe_path="$(dirname "$disk_probe_path")"
done
available_disk_kb() {
  df -Pk "$disk_probe_path" | awk 'NR == 2 {print $4}'
}
MIN_FREE_KB=$((MIN_FREE_GB * 1024 * 1024))
initial_free_kb="$(available_disk_kb)"
[ "$initial_free_kb" -ge "$MIN_FREE_KB" ] \
  || die "host disk headroom is ${initial_free_kb} KiB; at least ${MIN_FREE_KB} KiB is required"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-endurance-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
BIND_DIR="$WORKDIR/share"
RESULTS="$WORKDIR/cycles.tsv"
RESOURCES="$WORKDIR/resources.tsv"
MANIFEST="$WORKDIR/manifest.txt"
START_EPOCH="$(date +%s)"
mkdir -p "$BIND_DIR"
printf 'cycle\tstarted_epoch\telapsed_seconds\tstatus\tdetail\n' > "$RESULTS"
printf 'phase\tcycle\tepoch\tpid_count\tfd_total\trss_kb\tcpu_percent\tstate_kb\tfseventsd_pid_count\tfseventsd_rss_kb\tfseventsd_cpu_percent\n' > "$RESOURCES"
{
  echo "run_id=$RUN_ID"
  echo "socket=$SOCKET"
  echo "duration_seconds=$DURATION_SECONDS"
  echo "cycles=$CYCLES"
  echo "files_per_cycle=$FILES_PER_CYCLE"
  echo "compose_every=$COMPOSE_EVERY"
  echo "process_pattern=$PROCESS_PATTERN"
  echo "min_free_gb=$MIN_FREE_GB"
  echo "initial_free_kb=$initial_free_kb"
  echo "fseventsd_rss_growth_mb=$FSEVENTSD_RSS_GROWTH_MB"
  echo "fseventsd_cpu_percent=$FSEVENTSD_CPU_PERCENT"
  echo "started_epoch=$START_EPOCH"
  echo "release_qualifying=$([ "$CYCLES" -eq 0 ] && [ "$DURATION_SECONDS" -ge 28800 ] && echo true || echo false)"
} > "$MANIFEST"

cleanup_owned() {
  local id
  docker_e ps -aq --filter "label=dev.dory.endurance=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
  docker_e network ls -q --filter "label=dev.dory.endurance=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e network rm "$id" >/dev/null 2>&1 || true
  done
  docker_e volume ls -q --filter "label=dev.dory.endurance=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e volume rm -f "$id" >/dev/null 2>&1 || true
  done
}
cleanup() {
  cleanup_owned
}
trap cleanup EXIT INT TERM

dory_pids() {
  pgrep -f "$PROCESS_PATTERN" 2>/dev/null || true
}

sample_resources() {
  local phase="$1" cycle="$2" pids pid pid_count=0 fd_total=0 rss_kb=0 cpu=0 state_kb
  local fd_sample rss_sample cpu_sample fseventsd_pids fseventsd_pid_count=0
  local fseventsd_rss_kb=0 fseventsd_cpu=0
  pids="$(dory_pids)"
  [ -n "$pids" ] || { echo "no Dory processes found" >&2; return 1; }
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || continue
    pid_count=$((pid_count + 1))
    fd_sample="$(lsof -n -P -p "$pid" 2>/dev/null | awk 'NR > 1 {n++} END {print n+0}')"
    rss_sample="$(ps -p "$pid" -o rss= 2>/dev/null | awk 'NF {sum += $1} END {print sum+0}')"
    cpu_sample="$(ps -p "$pid" -o %cpu= 2>/dev/null | awk 'NF {sum += $1} END {printf "%.2f", sum+0}')"
    fd_total=$((fd_total + fd_sample))
    rss_kb=$((rss_kb + rss_sample))
    cpu="$(awk -v total="$cpu" -v sample="$cpu_sample" 'BEGIN {printf "%.2f", total+sample}')"
  done
  state_kb="$(du -sk "$STATE_DIR" 2>/dev/null | awk 'NF {sum += $1} END {print sum+0}')"
  fseventsd_pids="$(pgrep -x fseventsd 2>/dev/null || true)"
  [ -n "$fseventsd_pids" ] || { echo "no host fseventsd process found" >&2; return 1; }
  for pid in $fseventsd_pids; do
    kill -0 "$pid" 2>/dev/null || continue
    fseventsd_pid_count=$((fseventsd_pid_count + 1))
    rss_sample="$(ps -p "$pid" -o rss= 2>/dev/null | awk 'NF {sum += $1} END {print sum+0}')"
    cpu_sample="$(ps -p "$pid" -o %cpu= 2>/dev/null | awk 'NF {sum += $1} END {printf "%.2f", sum+0}')"
    fseventsd_rss_kb=$((fseventsd_rss_kb + rss_sample))
    fseventsd_cpu="$(awk -v total="$fseventsd_cpu" -v sample="$cpu_sample" 'BEGIN {printf "%.2f", total+sample}')"
  done
  [ "$fseventsd_pid_count" -gt 0 ] || { echo "host fseventsd exited during sampling" >&2; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$cycle" "$(date +%s)" "$pid_count" "$fd_total" "$rss_kb" "$cpu" "$state_kb" \
    "$fseventsd_pid_count" "$fseventsd_rss_kb" "$fseventsd_cpu" >> "$RESOURCES"
}

wait_file() {
  local path="$1" attempts="${2:-100}"
  while [ "$attempts" -gt 0 ]; do
    [ -s "$path" ] && return 0
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

run_compose_cycle() {
  local cycle="$1" dir="$WORKDIR/compose-$cycle" project
  project="$(printf 'doryendurance%s%s' "$RUN_ID" "$cycle" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c 1-48)"
  mkdir -p "$dir"
  cat > "$dir/compose.yaml" <<EOF
services:
  worker:
    image: $ALPINE_IMAGE
    labels:
      dev.dory.endurance: "$OWNER"
    command: ["sh", "-c", "echo compose-$cycle; sleep 30"]
    volumes:
      - cache:/cache
volumes:
  cache:
    labels:
      dev.dory.endurance: "$OWNER"
EOF
  docker_e compose -p "$project" -f "$dir/compose.yaml" up -d >/dev/null
  docker_e compose -p "$project" -f "$dir/compose.yaml" exec -T worker sh -c 'echo exec-ok > /cache/exec'
  docker_e compose -p "$project" -f "$dir/compose.yaml" logs worker | grep -q "compose-$cycle"
  docker_e compose -p "$project" -f "$dir/compose.yaml" down -v --remove-orphans >/dev/null
}

run_cycle() {
  local cycle="$1" dir="$BIND_DIR/cycle-$cycle" name="$OWNER-$cycle" vol="$OWNER-vol-$cycle"
  local i marker expected copied watcher="$OWNER-watch-$cycle"
  rm -rf "$dir"
  mkdir -p "$dir/host" "$dir/guest" "$dir/watch"
  marker="cycle-$cycle-$(date +%s)-$$"
  printf '%s\n' "$marker" > "$dir/host/input.txt"

  docker_e volume create --label "dev.dory.endurance=$OWNER" "$vol" >/dev/null
  docker_e run -d --name "$name" --label "dev.dory.endurance=$OWNER" \
    -v "$dir:/share" -v "$vol:/volume" "$ALPINE_IMAGE" sleep 300 >/dev/null
  docker_e exec "$name" grep -qx "$marker" /share/host/input.txt
  docker_e exec "$name" sh -c 'printf "%s\n" "$1" > /share/guest/output.txt; printf "%s\n" "$1" > /volume/state.txt' sh "$marker"
  grep -qx "$marker" "$dir/guest/output.txt"
  docker_e exec "$name" grep -qx "$marker" /volume/state.txt
  # Database images commonly chown bind-mounted data before dropping from root to a service UID.
  # The host tree must stay owned by the macOS user, but the Linux ownership request must succeed.
  docker_e exec "$name" sh -ec 'touch /share/guest/chown-probe; chown 999:999 /share/guest/chown-probe; chmod 600 /share/guest/chown-probe'

  printf 'copy-%s\n' "$marker" > "$dir/copy-in.txt"
  docker_e cp "$dir/copy-in.txt" "$name:/tmp/copy-in.txt"
  docker_e exec "$name" grep -qx "copy-$marker" /tmp/copy-in.txt
  docker_e exec "$name" sh -c 'printf "copy-out-%s\n" "$1" > /tmp/copy-out.txt' sh "$marker"
  docker_e cp "$name:/tmp/copy-out.txt" "$dir/copy-out.txt"
  grep -qx "copy-out-$marker" "$dir/copy-out.txt"

  printf 'watch-before-%s\n' "$marker" > "$dir/watch/input.txt"
  cat > "$dir/watch/handler.sh" <<'EOF'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "${3:-}" > /watch/event.txt
EOF
  chmod 0755 "$dir/watch/handler.sh"
  docker_e run -d --name "$watcher" --label "dev.dory.endurance=$OWNER" \
    -v "$dir/watch:/watch" "$ALPINE_IMAGE" sh -c \
    'test -f /watch/input.txt; printf ready > /watch/ready; exec inotifyd /watch/handler.sh /watch/input.txt:cewDx'
  wait_file "$dir/watch/ready"
  # `ready` proves the container started, but the following exec still needs a scheduling turn to
  # install its inotify watch. Without this barrier a very fast host create can win that race.
  sleep 1
  printf 'watch-after-%s\n' "$marker" >> "$dir/watch/input.txt"
  wait_file "$dir/watch/event.txt"
  grep -Eq '^[cewDx]+' "$dir/watch/event.txt"
  docker_e rm -f "$watcher" >/dev/null

  i=1
  while [ "$i" -le "$FILES_PER_CYCLE" ]; do
    printf '%s-%s\n' "$marker" "$i" > "$dir/host/file-$i"
    i=$((i + 1))
  done
  expected="$(find "$dir/host" -type f | LC_ALL=C sort | xargs cat | shasum -a 256 | awk '{print $1}')"
  copied="$(docker_e exec "$name" sh -c \
    'find /share/host -type f | LC_ALL=C sort | xargs cat | sha256sum' | awk '{print $1}')"
  [ "$expected" = "$copied" ] || { echo "host/guest exact tree digest mismatch" >&2; return 1; }
  docker_e exec "$name" sh -c 'rm -f /share/host/file-*'
  [ -z "$(find "$dir/host" -name 'file-*' -print -quit)" ]

  docker_e logs "$name" >/dev/null
  docker_e stats --no-stream "$name" >/dev/null
  docker_e inspect "$name" >/dev/null
  docker_e rm -f "$name" >/dev/null
  docker_e run --rm --label "dev.dory.endurance=$OWNER" -v "$vol:/volume" "$ALPINE_IMAGE" \
    grep -qx "$marker" /volume/state.txt
  docker_e volume rm "$vol" >/dev/null

  if [ $((cycle % COMPOSE_EVERY)) -eq 0 ]; then
    run_compose_cycle "$cycle"
  fi
  rm -rf "$dir"
}

sample_resources baseline 0
cycle=0
while :; do
  now="$(date +%s)"
  elapsed=$((now - START_EPOCH))
  if [ "$CYCLES" -gt 0 ]; then
    [ "$cycle" -lt "$CYCLES" ] || break
  elif [ "$cycle" -gt 0 ] && [ "$elapsed" -ge "$DURATION_SECONDS" ]; then
    break
  fi
  cycle=$((cycle + 1))
  cycle_started="$(date +%s)"
  free_kb="$(available_disk_kb)"
  if [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
    printf '%s\t%s\t%s\tFAIL\thost_free_kb=%s_below_reserve=%s\n' \
      "$cycle" "$cycle_started" "$(( $(date +%s) - START_EPOCH ))" "$free_kb" "$MIN_FREE_KB" >> "$RESULTS"
    die "host disk headroom fell to ${free_kb} KiB below the ${MIN_FREE_KB} KiB reserve"
  fi
  set +e
  ( set -e; run_cycle "$cycle" ) >> "$WORKDIR/cycle-$cycle.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '%s\t%s\t%s\tPASS\tok\n' "$cycle" "$cycle_started" "$(( $(date +%s) - START_EPOCH ))" >> "$RESULTS"
  else
    printf '%s\t%s\t%s\tFAIL\texit=%s\n' "$cycle" "$cycle_started" "$(( $(date +%s) - START_EPOCH ))" "$rc" >> "$RESULTS"
    tail -60 "$WORKDIR/cycle-$cycle.log" >&2 || true
    exit "$rc"
  fi
  cleanup_owned
  sleep "$SETTLE_SECONDS"
  sample_resources cleaned "$cycle"
done

cleanup_owned
sleep "$SETTLE_SECONDS"
sample_resources final "$cycle"

python3 scripts/analyze-endurance-resources.py "$RESOURCES" \
  --fd-growth "$FD_GROWTH_BUDGET" \
  --rss-growth-mb "$RSS_GROWTH_MB" \
  --disk-growth-mb "$DISK_GROWTH_MB" \
  --idle-cpu "$IDLE_CPU_PERCENT" \
  --fseventsd-rss-growth-mb "$FSEVENTSD_RSS_GROWTH_MB" \
  --fseventsd-cpu "$FSEVENTSD_CPU_PERCENT"

grep -q $'\tFAIL\t' "$RESULTS" && die "one or more cycles failed"
echo "endurance reliability soak PASS: $cycle cycles; evidence: $WORKDIR"
