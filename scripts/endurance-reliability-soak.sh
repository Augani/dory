#!/bin/bash
# Eight-hour release gate for the user-visible failure modes behind intermittent shares, leaked
# descriptors, high idle CPU/memory, and unbounded engine-state growth. Every Docker object is
# run-scoped and labeled; the gate never pulls workload images implicitly.
set -euo pipefail
export LC_ALL=C LANG=C
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

SOCKET=""
STATE_DIR=""
DOCKER=""
ALPINE_IMAGE=""
WORKROOT="${TMPDIR:-/tmp}/dory-endurance-reliability"
DURATION_SECONDS=28800
CYCLES=0
FILES_PER_CYCLE=100
COMPOSE_EVERY=5
SETTLE_SECONDS=2
FD_GROWTH_BUDGET=16
RSS_GROWTH_MB=384
DISK_GROWTH_MB=256
IDLE_CPU_PERCENT=25
FSEVENTSD_RSS_GROWTH_MB=128
FSEVENTSD_CPU_PERCENT=25
MIN_FREE_GB=2
PROCESS_ROOT=""
CONFIRM=""
SOURCE_COMMIT=""
RELEASE_CANDIDATE=0

usage() {
  cat <<EOF
Usage: scripts/endurance-reliability-soak.sh --socket PATH --state-dir PATH --docker PATH \
  --image REF --process-root PATH --confirm TOKEN [options]

Required:
  --socket PATH         Exact isolated Dory Docker socket
  --state-dir PATH      Exact isolated Dory state directory measured for growth
  --docker PATH         Exact Docker CLI to qualify
  --image REF           Existing offline Alpine-compatible image
  --process-root PATH   Exact state-root token present in every attributed process command
  --confirm TOKEN       Must be ISOLATED-ENGINE-ENDURANCE-RELIABILITY

Options:
  --duration SECONDS    Minimum wall duration; default 28800 (8 hours)
  --cycles N            Exact cycle count; overrides --duration when greater than zero
  --files N             Host/guest create-delete files per cycle (default: $FILES_PER_CYCLE)
  --compose-every N     Run Compose every N cycles (default: $COMPOSE_EVERY)
  --settle SECONDS      Idle settle after each cleaned cycle (default: $SETTLE_SECONDS)
  --workroot PATH       New private result root (default: $WORKROOT)
  --fd-growth N         Aggregate Dory FD growth budget (default: $FD_GROWTH_BUDGET)
  --rss-growth-mb N     Aggregate Dory RSS growth budget (default: $RSS_GROWTH_MB)
  --disk-growth-mb N    Dory state growth budget after cleanup (default: $DISK_GROWTH_MB)
  --idle-cpu PERCENT    Final aggregate idle CPU ceiling (default: $IDLE_CPU_PERCENT)
  --fseventsd-rss-growth-mb N
                        Host fseventsd RSS growth budget (default: $FSEVENTSD_RSS_GROWTH_MB)
  --fseventsd-cpu PERCENT
                        Final host fseventsd CPU ceiling (default: $FSEVENTSD_CPU_PERCENT)
  --min-free-gb N       Abort before logs become unwritable below N GiB free (default: $MIN_FREE_GB)
  --source-commit SHA   Exact 40-character source commit for release evidence
  --release-candidate   Require the full eight-hour release contract
  -h, --help

The release gate uses the default 8-hour duration. --cycles is intended only for regression and
preflight runs and can never emit release-qualified evidence. The confirmation token is checked
before the socket, state directory, Docker CLI, or workroot are accessed.
EOF
}

die() { echo "endurance-soak: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --state-dir) need_value "$1" "$#"; STATE_DIR="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; ALPINE_IMAGE="$2"; shift 2 ;;
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
    --process-root) need_value "$1" "$#"; PROCESS_ROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --release-candidate) RELEASE_CANDIDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

nonnegative_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer" ;; esac
}
[ "$CONFIRM" = "ISOLATED-ENGINE-ENDURANCE-RELIABILITY" ] \
  || die "requires --confirm ISOLATED-ENGINE-ENDURANCE-RELIABILITY"
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

for command in id python3 lsof ps du shasum stat df awk grep find xargs; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
ANALYZER="$SCRIPT_DIR/analyze-endurance-resources.py"
[ -f "$ANALYZER" ] && [ ! -L "$ANALYZER" ] \
  || die "resource analyzer is unavailable or indirect"
ANALYZER_SHA256="$(shasum -a 256 "$ANALYZER" | awk '{print $1}')"
GATE_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
case "$SOCKET" in /*) ;; *) die "Dory socket must be an absolute path" ;; esac
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] || die "Dory socket is unavailable or indirect: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] || die "Dory socket is not owned by the release user"
case "$STATE_DIR" in /*) ;; *) die "state directory must be an absolute path" ;; esac
[ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die "state directory is unavailable or indirect"
[ "$(stat -f %u "$STATE_DIR")" = "$(id -u)" ] || die "state directory is not owned by the release user"
state_canonical="$(cd "$STATE_DIR" && pwd -P)"
[ "$state_canonical" = "$STATE_DIR" ] || die "state directory must be a direct canonical path"
case "$PROCESS_ROOT" in /*) ;; *) die "process root must be an absolute path" ;; esac
[ "$PROCESS_ROOT" = "$STATE_DIR" ] || die "process root must exactly equal the state directory"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -s "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
docker_canonical="$(cd "$(dirname "$DOCKER")" && pwd -P)/$(basename "$DOCKER")"
[ "$docker_canonical" = "$DOCKER" ] || die "Docker CLI must be a direct canonical path"
[ -n "$ALPINE_IMAGE" ] || die "--image is required"
if [ -n "$SOURCE_COMMIT" ]; then
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || die "source commit must be a full lowercase Git SHA"
fi
if [ "$RELEASE_CANDIDATE" -eq 1 ]; then
  [ -n "$SOURCE_COMMIT" ] || die "release candidate evidence requires --source-commit"
  [ "$CYCLES" -eq 0 ] || die "release candidate evidence cannot use --cycles"
  [ "$DURATION_SECONDS" -ge 28800 ] || die "release candidate duration must be at least eight hours"
  [ "$FILES_PER_CYCLE" -ge 100 ] || die "release candidate requires at least 100 files per cycle"
  [ "$COMPOSE_EVERY" -le 5 ] || die "release candidate must exercise Compose at least every five cycles"
  [ "$SETTLE_SECONDS" -ge 2 ] || die "release candidate settle interval must be at least two seconds"
  [ "$FD_GROWTH_BUDGET" -le 16 ] || die "release candidate FD growth budget is too permissive"
  [ "$RSS_GROWTH_MB" -le 384 ] || die "release candidate RSS growth budget is too permissive"
  [ "$DISK_GROWTH_MB" -le 256 ] || die "release candidate disk growth budget is too permissive"
  [ "$IDLE_CPU_PERCENT" -le 25 ] || die "release candidate idle CPU ceiling is too permissive"
  [ "$FSEVENTSD_RSS_GROWTH_MB" -le 128 ] \
    || die "release candidate fseventsd RSS growth budget is too permissive"
  [ "$FSEVENTSD_CPU_PERCENT" -le 25 ] \
    || die "release candidate fseventsd CPU ceiling is too permissive"
  [ "$MIN_FREE_GB" -ge 2 ] || die "release candidate disk reserve must be at least two GiB"
  printf '%s\n' "$ALPINE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || die "release candidate image must be digest-pinned"
fi
case "$WORKROOT" in /*) ;; *) die "workroot must be an absolute path" ;; esac
case "$WORKROOT" in /|"$HOME") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
workroot_parent="$(dirname "$WORKROOT")"
[ -d "$workroot_parent" ] && [ ! -L "$workroot_parent" ] \
  || die "workroot parent is unavailable or indirect"
[ "$(cd "$workroot_parent" && pwd -P)" = "$workroot_parent" ] \
  || die "workroot parent must be a direct canonical path"
mkdir "$WORKROOT"
chmod 0700 "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"

docker_raw() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME \
    -u COMPOSE_PROFILES DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"
}
bounded() {
  local limit="$1" pid started rc
  shift
  "$@" &
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
docker_e() {
  bounded 120 docker_raw "$@"
}
bounded 15 docker_raw version >/dev/null || die "Docker API is not ready at the isolated socket"
bounded 15 docker_raw image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 \
  || die "required offline image is missing: $ALPINE_IMAGE"
bounded 15 docker_raw compose version >/dev/null 2>&1 || die "docker compose plugin is unavailable"
image_id="$(docker_e image inspect -f '{{.Id}}' "$ALPINE_IMAGE")"
image_platform="$(docker_e image inspect -f '{{.Os}}/{{.Architecture}}' "$ALPINE_IMAGE")"
if [ "$RELEASE_CANDIDATE" -eq 1 ] && [ "$image_platform" != linux/arm64 ]; then
  die "release candidate fixture must resolve to linux/arm64"
fi
docker_cli_sha256="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"

disk_probe_path="$WORKROOT"
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
ANALYSIS="$WORKDIR/resource-analysis.txt"
COMPOSE_PROJECTS="$WORKDIR/compose-projects.tsv"
START_EPOCH="$(date +%s)"
SOCKET_IDENTITY="$(stat -f '%d:%i:%u' "$SOCKET")"
STATE_IDENTITY="$(stat -f '%d:%i:%u' "$STATE_DIR")"
SOCKET_IDENTITY_SHA256="$(printf '%s\n' "$SOCKET_IDENTITY" | shasum -a 256 | awk '{print $1}')"
STATE_AUTHORITY_SHA256="$(printf '%s\0%s\n' "$STATE_DIR" "$PROCESS_ROOT" | shasum -a 256 | awk '{print $1}')"
mkdir -p "$BIND_DIR"
printf 'cycle\tstarted_epoch\telapsed_seconds\tstatus\tdetail\n' > "$RESULTS"
printf 'phase\tcycle\tepoch\tpid_count\tfd_total\trss_kb\tcpu_percent\tstate_kb\tfseventsd_pid_count\tfseventsd_rss_kb\tfseventsd_cpu_percent\n' > "$RESOURCES"
printf 'project\tcompose_file\n' > "$COMPOSE_PROJECTS"
{
  echo "run_id=$RUN_ID"
  echo "owner=$OWNER"
  echo "source_commit=$SOURCE_COMMIT"
  echo "image=$ALPINE_IMAGE"
  echo "image_id=$image_id"
  echo "image_platform=$image_platform"
  echo "duration_seconds=$DURATION_SECONDS"
  echo "cycles=$CYCLES"
  echo "files_per_cycle=$FILES_PER_CYCLE"
  echo "compose_every=$COMPOSE_EVERY"
  echo "settle_seconds=$SETTLE_SECONDS"
  echo "min_free_gb=$MIN_FREE_GB"
  echo "initial_free_kb=$initial_free_kb"
  echo "fd_growth_budget=$FD_GROWTH_BUDGET"
  echo "rss_growth_mb=$RSS_GROWTH_MB"
  echo "disk_growth_mb=$DISK_GROWTH_MB"
  echo "idle_cpu_percent=$IDLE_CPU_PERCENT"
  echo "fseventsd_rss_growth_mb=$FSEVENTSD_RSS_GROWTH_MB"
  echo "fseventsd_cpu_percent=$FSEVENTSD_CPU_PERCENT"
  echo "socket_identity_sha256=$SOCKET_IDENTITY_SHA256"
  echo "state_authority_sha256=$STATE_AUTHORITY_SHA256"
  echo "docker_cli_sha256=$docker_cli_sha256"
  echo "gate_sha256=$GATE_SHA256"
  echo "analyzer_sha256=$ANALYZER_SHA256"
  echo "started_epoch=$START_EPOCH"
  echo "requested_release_candidate=$([ "$RELEASE_CANDIDATE" -eq 1 ] && echo true || echo false)"
} > "$MANIFEST"

cleanup_owned() {
  local id project compose_file
  if [ -f "$COMPOSE_PROJECTS" ]; then
    while IFS=$'\t' read -r project compose_file; do
      [ "$project" = project ] && continue
      [ -n "$project" ] && [ -n "$compose_file" ] || continue
      docker_e compose -p "$project" -f "$compose_file" down -v --remove-orphans \
        >/dev/null 2>&1 || true
    done < "$COMPOSE_PROJECTS"
  fi
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

dory_pids() {
  ps -axo pid=,uid=,command= | awk -v uid="$(id -u)" -v root="$PROCESS_ROOT" \
    '$2 == uid && index($0, root) > 0 && \
      $0 ~ /(^|[\/[[:space:]]])(Dory|doryd|dory-hv|dory-vmm|dory-dataplane-proxy|gvproxy)([[:space:]]|$)/ \
      {print $1}'
}

verify_owned_cleanup() {
  local project compose_file
  [ -z "$(docker_e ps -aq --filter "label=dev.dory.endurance=$OWNER")" ] \
    || die "owned containers survived cleanup"
  [ -z "$(docker_e network ls -q --filter "label=dev.dory.endurance=$OWNER")" ] \
    || die "owned networks survived cleanup"
  [ -z "$(docker_e volume ls -q --filter "label=dev.dory.endurance=$OWNER")" ] \
    || die "owned volumes survived cleanup"
  while IFS=$'\t' read -r project compose_file; do
    [ "$project" = project ] && continue
    [ -n "$project" ] || continue
    [ -z "$(docker_e ps -aq --filter "label=com.docker.compose.project=$project")" ] \
      || die "Compose project containers survived cleanup"
    [ -z "$(docker_e network ls -q --filter "label=com.docker.compose.project=$project")" ] \
      || die "Compose project networks survived cleanup"
    [ -z "$(docker_e volume ls -q --filter "label=com.docker.compose.project=$project")" ] \
      || die "Compose project volumes survived cleanup"
  done < "$COMPOSE_PROJECTS"
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
  printf '%s\t%s\n' "$project" "$dir/compose.yaml" >> "$COMPOSE_PROJECTS"
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
  [ "$(stat -f %u "$dir/guest/chown-probe")" = "$(id -u)" ] \
    || { echo "guest ownership request changed host bind ownership" >&2; return 1; }

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

[ "$(shasum -a 256 "$ANALYZER" | awk '{print $1}')" = "$ANALYZER_SHA256" ] \
  || die "resource analyzer changed during the soak"
python3 "$ANALYZER" "$RESOURCES" \
  --fd-growth "$FD_GROWTH_BUDGET" \
  --rss-growth-mb "$RSS_GROWTH_MB" \
  --disk-growth-mb "$DISK_GROWTH_MB" \
  --idle-cpu "$IDLE_CPU_PERCENT" \
  --fseventsd-rss-growth-mb "$FSEVENTSD_RSS_GROWTH_MB" \
  --fseventsd-cpu "$FSEVENTSD_CPU_PERCENT" > "$ANALYSIS"

grep -q $'\tFAIL\t' "$RESULTS" && die "one or more cycles failed"
pass_cycles="$(awk -F '\t' 'NR > 1 && $4 == "PASS" {count++} END {print count+0}' "$RESULTS")"
[ "$pass_cycles" -eq "$cycle" ] && [ "$cycle" -ge 1 ] \
  || die "cycle result count does not match completed cycles"
grep -q '^resource plateau PASS: ' "$ANALYSIS" || die "resource plateau proof is missing"
cleanup_owned
verify_owned_cleanup
[ "$(stat -f '%d:%i:%u' "$SOCKET")" = "$SOCKET_IDENTITY" ] \
  || die "isolated Docker socket identity changed during the soak"
[ "$(stat -f '%d:%i:%u' "$STATE_DIR")" = "$STATE_IDENTITY" ] \
  || die "isolated state authority changed during the soak"
[ "$(shasum -a 256 "$DOCKER" | awk '{print $1}')" = "$docker_cli_sha256" ] \
  || die "Docker CLI changed during the soak"
[ "$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')" = "$GATE_SHA256" ] \
  || die "endurance gate changed during the soak"
final_image_id="$(docker_e image inspect -f '{{.Id}}' "$ALPINE_IMAGE")"
final_image_platform="$(docker_e image inspect -f '{{.Os}}/{{.Architecture}}' "$ALPINE_IMAGE")"
[ "$final_image_id" = "$image_id" ] && [ "$final_image_platform" = "$image_platform" ] \
  || die "endurance soak changed the exact fixture image identity"
END_EPOCH="$(date +%s)"
ELAPSED_SECONDS=$((END_EPOCH - START_EPOCH))
if [ "$CYCLES" -eq 0 ]; then
  [ "$ELAPSED_SECONDS" -ge "$DURATION_SECONDS" ] \
    || die "duration-based soak ended before its requested wall time"
fi
release_qualifying=false
if [ "$RELEASE_CANDIDATE" -eq 1 ] \
  && [ "$CYCLES" -eq 0 ] \
  && [ "$DURATION_SECONDS" -ge 28800 ] \
  && [ "$ELAPSED_SECONDS" -ge "$DURATION_SECONDS" ]; then
  release_qualifying=true
fi
final_free_kb="$(available_disk_kb)"
{
  echo "completed_cycles=$cycle"
  echo "elapsed_seconds=$ELAPSED_SECONDS"
  echo "final_free_kb=$final_free_kb"
  echo "cycles_sha256=$(shasum -a 256 "$RESULTS" | awk '{print $1}')"
  echo "resources_sha256=$(shasum -a 256 "$RESOURCES" | awk '{print $1}')"
  echo "resource_analysis_sha256=$(shasum -a 256 "$ANALYSIS" | awk '{print $1}')"
  echo "same_user_socket=PASS"
  echo "exact_process_authority=PASS"
  echo "exact_image_identity=PASS"
  echo "resource_plateau=PASS"
  echo "owned_cleanup=PASS"
  echo "ended_epoch=$END_EPOCH"
  echo "release_qualifying=$release_qualifying"
  echo "status=PASS"
} >> "$MANIFEST"
echo "endurance reliability soak PASS: $cycle cycles; evidence: $WORKDIR"
