#!/bin/bash
# Reproducible cross-engine benchmark for Dory vs incumbent macOS container runtimes.
#
# METHODOLOGY
# -----------
# This script measures three things that Dory's shared-engine architecture is expected to win on,
# with the SAME probe against every engine so numbers are directly comparable:
#
#   1. IDLE MEMORY   Start N idle `alpine sleep` containers. Report the delta in (a) system memory
#                    in use -- active + wired + compressed pages * page size, via vm_stat, the same
#                    math scripts/readiness.sh uses -- and (b) aggregate RSS of the engine's own
#                    host-side processes, before vs after. A settle window brackets each sample so
#                    lazy allocation and page compression stabilise. No container internals are read;
#                    this is the cost the containers + their VM impose on the host.
#
#   2. C2C NETWORK   Put two containers on a user-defined bridge network, run an iperf3 server in one
#                    and an iperf3 client in the other addressing it by network alias, and report the
#                    measured throughput in Gbps (median of BENCH_RUNS runs). This isolates the
#                    container-to-container path; per-container-VM engines (Apple Container) pay a
#                    cross-VM tax here that a shared-engine design avoids. Skips cleanly if the
#                    iperf3 image cannot be pulled.
#
#   3. CPU WORKLOAD  Run the same CPU-bound sha256 workload in each engine and report median wall
#                    time. This is not a synthetic "engine score"; it catches runtime overhead,
#                    startup overhead, and CPU scheduling differences for a simple replicated task.
#
#   4. BIND-MOUNT FS Run a file-heavy workload (create BENCH_FS_FILES small files) twice: once writing
#                    into a HOST bind mount (crosses the VM<->host filesystem boundary) and once
#                    writing into a plain in-container path (no host mount). Report both wall times
#                    and the host/in-container ratio -- the ratio is the VM-boundary tax, independent
#                    of raw disk speed. Median of BENCH_RUNS runs each.
#
# Engines: dory, orbstack, docker-desktop, apple-container. Docker-API engines are driven over their
# unix socket (selected via DORY_SOCK / ORBSTACK_SOCK / DOCKER_DESKTOP_SOCK, mirroring readiness.sh).
# Apple Container is driven via its own `container` CLI. Any engine whose socket or CLI is absent is
# reported [SKIP] and never fails the run. Every resource created carries a run-scoped label
# (dev.dory.bench=<runId>) or a run-scoped name prefix, and cleanup removes only those.
#
# This measures; it does not market. Output is measurements + this methodology comment only.
#
# Examples:
#   scripts/benchmark-compare.sh --engines dory
#   scripts/benchmark-compare.sh --engines dory,orbstack,apple-container --memory-count 4 --runs 5
#   scripts/benchmark-compare.sh --engines dory --metrics memory,cpu,fs
#   scripts/benchmark-compare.sh --dory-app /Applications/Dory.app --engines dory,orbstack,docker-desktop
#   scripts/benchmark-compare.sh --dry-run --engines dory,orbstack,docker-desktop,apple-container
#
# Environment knobs:
#   DORY_SOCK, ORBSTACK_SOCK, DOCKER_DESKTOP_SOCK   engine socket overrides
#   BENCH_CONTAINER_BIN                             path to Apple's `container` CLI
#   BENCH_ALPINE_IMAGE, BENCH_IPERF_IMAGE           images used for the probes
#                                                   (must have manifests for the host guest arch:
#                                                    arm64 on Apple silicon, amd64 on Intel; prefer
#                                                    multi-arch images such as taoyou/iperf3-alpine)
#   BENCH_WORKDIR                                   results root (default ~/.dory-benchmark)
#   DORY_BENCH_APP                                  path to released Dory.app to launch/record
#   DORY_BENCH_APP_WAIT                             seconds to wait for Dory's socket (default 90)
#   BENCH_SETTLE, BENCH_MEMORY_COUNT, BENCH_RUNS, BENCH_CPU_MB, BENCH_FS_FILES
#   *_PROCESS_PATTERN                               override per-engine host-process match
set -u

# --------------------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINES="${ENGINES:-dory,orbstack,docker-desktop,apple-container}"
METRICS="${METRICS:-memory,cpu,network,fs}"
ALPINE_IMAGE="${BENCH_ALPINE_IMAGE:-alpine:latest}"
IPERF_IMAGE="${BENCH_IPERF_IMAGE:-taoyou/iperf3-alpine:latest}"
MEMORY_COUNT="${BENCH_MEMORY_COUNT:-3}"
MEMORY_COUNTS="${BENCH_MEMORY_COUNTS:-$MEMORY_COUNT}"
RUNS="${BENCH_RUNS:-3}"
CPU_MB="${BENCH_CPU_MB:-256}"
FS_FILES="${BENCH_FS_FILES:-2000}"
SETTLE="${BENCH_SETTLE:-12}"
CONTAINER_BIN="${BENCH_CONTAINER_BIN:-$(command -v container 2>/dev/null || echo /opt/homebrew/bin/container)}"
DORY_BENCH_APP="${DORY_BENCH_APP:-}"
DORY_BENCH_APP_WAIT="${DORY_BENCH_APP_WAIT:-90}"
DRY_RUN="${DRY_RUN:-0}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_SLUG="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
WORKROOT="${BENCH_WORKDIR:-$HOME/.dory-benchmark}"
WORKDIR="$WORKROOT/$RUN_ID"
MEMORY_TSV="$WORKDIR/memory.tsv"
NETWORK_TSV="$WORKDIR/network.tsv"
FS_TSV="$WORKDIR/filesystem.tsv"
CPU_TSV="$WORKDIR/cpu.tsv"
STATUS_TSV="$WORKDIR/status.tsv"
SUMMARY_JSON="$WORKDIR/summary.json"
SUMMARY_MD="$WORKDIR/summary.md"
MACHINE_SPEC="$WORKDIR/machine-spec.tsv"
ENGINE_VERSIONS_TSV="$WORKDIR/engine-versions.tsv"
LABEL_KEY="dev.dory.bench"

CURRENT_ENGINE=""
ENGINE_ID=""
ENGINE_SOCK=""
PREFIX=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<EOF
Usage: scripts/benchmark-compare.sh [options]

Options:
  --engines LIST       Comma-separated: dory,orbstack,docker-desktop,apple-container (default: all)
  --metrics LIST       Comma-separated subset of: memory,cpu,network,fs (default: all)
  --memory-count N     Idle containers for the memory metric (default: $MEMORY_COUNT)
  --memory-counts LIST Comma-separated idle-container counts for memory sweeps
  --runs N             Repetitions per timed metric; median reported (default: $RUNS)
  --cpu-mb N           MiB streamed through sha256sum for the CPU metric (default: $CPU_MB)
  --fs-files N         Files created by the filesystem workload (default: $FS_FILES)
  --settle SECONDS     Settle window around memory samples (default: $SETTLE)
  --dory-app PATH      Launch and record this released Dory.app before Dory metrics
  --dory-app-wait N    Seconds to wait for the Dory socket after launching --dory-app (default: $DORY_BENCH_APP_WAIT)
  --dry-run            Print the commands each metric would run; take no measurements
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="${2:-}"; shift 2 ;;
    --metrics) METRICS="${2:-}"; shift 2 ;;
    --memory-count) MEMORY_COUNT="${2:-}"; MEMORY_COUNTS="$MEMORY_COUNT"; shift 2 ;;
    --memory-counts) MEMORY_COUNTS="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --cpu-mb) CPU_MB="${2:-}"; shift 2 ;;
    --fs-files) FS_FILES="${2:-}"; shift 2 ;;
    --settle) SETTLE="${2:-}"; shift 2 ;;
    --dory-app) DORY_BENCH_APP="${2:-}"; shift 2 ;;
    --dory-app-wait) DORY_BENCH_APP_WAIT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------------------------------
# Logging + result recording
# --------------------------------------------------------------------------------------------------

note() {
  printf '==> %s\n' "$*"
}

sanitize() {
  printf '%s' "$*" | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c 1-500
}

record_status() {
  local status="$1" engine="$2" metric="$3" detail="$4"
  printf '%s\t%s\t%s\t%s\n' "$status" "$engine" "$metric" "$(sanitize "$detail")" >> "$STATUS_TSV"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)); printf '  [PASS] %s / %s -- %s\n' "$engine" "$metric" "$(sanitize "$detail")" ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  [FAIL] %s / %s -- %s\n' "$engine" "$metric" "$(sanitize "$detail")" ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  [SKIP] %s / %s -- %s\n' "$engine" "$metric" "$(sanitize "$detail")" ;;
  esac
}

# Echo a command (dry-run) or execute it. Every state-changing engine call goes through this so a
# --dry-run pass is fully auditable and never touches a real engine.
run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# --------------------------------------------------------------------------------------------------
# Engine identity + wrappers (mirrors scripts/readiness.sh socket selection)
# --------------------------------------------------------------------------------------------------

is_apple_container() {
  case "$1" in
    apple|apple-container|container) return 0 ;;
    *) return 1 ;;
  esac
}

engine_id() {
  local engine="$1" base
  base="$(basename "$engine" 2>/dev/null | sed 's/\.sock$//')"
  [ -n "$base" ] || base="$engine"
  printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

engine_label() {
  case "$1" in
    dory) echo "Dory" ;;
    orbstack) echo "OrbStack" ;;
    docker-desktop|desktop) echo "Docker Desktop" ;;
    apple|apple-container|container) echo "Apple Container" ;;
    *) echo "$1" ;;
  esac
}

engine_socket() {
  local engine="$1"
  case "$engine" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    docker-desktop|desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
    *) echo "" ;;
  esac
}

docker_e() {
  docker -H "unix://$ENGINE_SOCK" "$@"
}

docker_er() {
  run_cmd docker -H "unix://$ENGINE_SOCK" "$@"
}

container_c() {
  run_cmd "$CONTAINER_BIN" "$@"
}

# Availability without side effects. Dry-run treats every engine as available so the full structure
# is exercised and printed.
engine_available() {
  local engine="$1" sock
  [ "$DRY_RUN" = "1" ] && return 0
  if is_apple_container "$engine"; then
    [ -x "$CONTAINER_BIN" ] || command -v "$CONTAINER_BIN" >/dev/null 2>&1
    return
  fi
  command -v docker >/dev/null 2>&1 || return 1
  sock="$(engine_socket "$engine")"
  [ -n "$sock" ] && [ -S "$sock" ]
}

dory_app_version_value() {
  local key="$1"
  [ -n "$DORY_BENCH_APP" ] || { echo ""; return; }
  /usr/bin/defaults read "$DORY_BENCH_APP/Contents/Info" "$key" 2>/dev/null || echo ""
}

prepare_dory_release_app() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 0
  [ -n "$DORY_BENCH_APP" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] open %s and wait up to %ss for %s\n' "$DORY_BENCH_APP" "$DORY_BENCH_APP_WAIT" "$ENGINE_SOCK"
    return 0
  fi
  [ -d "$DORY_BENCH_APP" ] || {
    record_status SKIP "$CURRENT_ENGINE" "all metrics" "Dory app not found: $DORY_BENCH_APP"
    return 1
  }
  /usr/bin/open "$DORY_BENCH_APP" >/dev/null 2>&1 || {
    record_status FAIL "$CURRENT_ENGINE" "all metrics" "could not launch Dory app: $DORY_BENCH_APP"
    return 1
  }
  local waited=0
  while [ "$waited" -lt "$DORY_BENCH_APP_WAIT" ]; do
    if [ -S "$ENGINE_SOCK" ] && docker -H "unix://$ENGINE_SOCK" version >/dev/null 2>&1; then
      record_status PASS "$CURRENT_ENGINE" "release-app" "using $(dory_app_version_value CFBundleShortVersionString) ($(dory_app_version_value CFBundleVersion)) at $DORY_BENCH_APP"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  record_status SKIP "$CURRENT_ENGINE" "all metrics" "Dory app did not expose a Docker socket at $ENGINE_SOCK within ${DORY_BENCH_APP_WAIT}s"
  return 1
}

# --------------------------------------------------------------------------------------------------
# Cleanup (only resources this run created)
# --------------------------------------------------------------------------------------------------

cleanup_docker_engine() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ -n "${ENGINE_SOCK:-}" ] && [ -S "$ENGINE_SOCK" ] || return 0
  local id
  docker_e ps -aq --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f "$id" >/dev/null 2>&1
  done
  docker_e network ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e network rm "$id" >/dev/null 2>&1
  done
  docker_e volume ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e volume rm -f "$id" >/dev/null 2>&1
  done
}

# Apple Container has no Docker label filter; remove by our run-scoped name prefix instead.
cleanup_apple_container() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ -x "$CONTAINER_BIN" ] || return 0
  "$CONTAINER_BIN" ls -aq 2>/dev/null | grep "^$PREFIX" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && "$CONTAINER_BIN" rm -f "$id" >/dev/null 2>&1
  done
}

cleanup_engine() {
  if is_apple_container "$CURRENT_ENGINE"; then
    cleanup_apple_container
  else
    cleanup_docker_engine
  fi
}

# --------------------------------------------------------------------------------------------------
# Host memory + per-engine RSS (identical math to readiness.sh)
# --------------------------------------------------------------------------------------------------

used_mem() {
  vm_stat | awk '
    /page size of/ { for (i=1;i<=NF;i++) if ($i+0>0) ps=$i }
    /Pages active/ { gsub(/\./,"",$3); a=$3 }
    /Pages wired down/ { gsub(/\./,"",$4); w=$4 }
    /Pages occupied by compressor/ { gsub(/\./,"",$5); c=$5 }
    END { printf "%.0f", (a+w+c)*ps }'
}

process_rss_bytes() {
  local engine="$1" pattern
  case "$engine" in
    dory) pattern="${DORY_PROCESS_PATTERN:-Dory|dory-vm|dory-vmboot|containermanagerd}" ;;
    orbstack) pattern="${ORBSTACK_PROCESS_PATTERN:-OrbStack}" ;;
    docker-desktop|desktop) pattern="${DOCKER_DESKTOP_PROCESS_PATTERN:-Docker|com.docker}" ;;
    apple|apple-container|container) pattern="${APPLE_CONTAINER_PROCESS_PATTERN:-container-runtime-linux|container-network-vmnet|containerization|com.apple.container}" ;;
    *) pattern="${GENERIC_ENGINE_PROCESS_PATTERN:-$engine}" ;;
  esac
  ps -axo rss,args | awk -v pat="$pattern" '$0 ~ pat && $0 !~ /awk/ { sum += $1 } END { printf "%.0f", sum * 1024 }'
}

# --------------------------------------------------------------------------------------------------
# Numeric helpers
# --------------------------------------------------------------------------------------------------

mb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1048576 }'
}

median() {
  [ "$#" -gt 0 ] || { printf '0'; return; }
  printf '%s\n' "$@" | awk '
    { v[n++] = $1 + 0 }
    END {
      if (n == 0) { printf "0"; exit }
      for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
          if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
      if (n % 2) printf "%.4f", v[(n-1)/2]
      else       printf "%.4f", (v[n/2 - 1] + v[n/2]) / 2
    }'
}

ratio() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b+0==0) printf "0"; else printf "%.2f", (a+0)/(b+0) }'
}

# --------------------------------------------------------------------------------------------------
# Machine spec capture
# --------------------------------------------------------------------------------------------------

capture_machine_spec() {
  {
    printf 'captured_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'hw.model\t%s\n' "$(sysctl -n hw.model 2>/dev/null || echo unknown)"
    printf 'hw.memsize_gb\t%s\n' "$(awk -v b="$(sysctl -n hw.memsize 2>/dev/null || echo 0)" 'BEGIN { printf "%.0f", b/1073741824 }')"
    printf 'hw.ncpu\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
    printf 'cpu.brand\t%s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    printf 'sw.productVersion\t%s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    printf 'sw.buildVersion\t%s\n' "$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    printf 'uname\t%s\n' "$(uname -mrs 2>/dev/null || echo unknown)"
    printf 'docker.client\t%s\n' "$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo none)"
    printf 'container.cli\t%s\n' "$( ("$CONTAINER_BIN" --version 2>/dev/null | head -1) || echo none)"
    if [ -n "$DORY_BENCH_APP" ]; then
      printf 'dory.app.path\t%s\n' "$DORY_BENCH_APP"
      printf 'dory.app.version\t%s\n' "$(dory_app_version_value CFBundleShortVersionString)"
      printf 'dory.app.build\t%s\n' "$(dory_app_version_value CFBundleVersion)"
      printf 'dory.app.bundleIdentifier\t%s\n' "$(dory_app_version_value CFBundleIdentifier)"
      printf 'dory.app.codesign\t%s\n' "$(codesign -dv "$DORY_BENCH_APP" 2>&1 | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c 1-500)"
    fi
  } > "$MACHINE_SPEC"
}

record_engine_version() {
  local engine="$CURRENT_ENGINE" label endpoint version name os kernel arch interface
  label="$(engine_label "$engine")"
  if is_apple_container "$engine"; then
    interface="container-cli"
    endpoint="$CONTAINER_BIN"
    if [ "$DRY_RUN" = "1" ]; then
      version="dry-run-not-queried"
    else
      version="$("$CONTAINER_BIN" --version 2>/dev/null | head -1 || true)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$engine" "$label" "$interface" "$endpoint" "$(sanitize "${version:-unknown}")" "" "" "$(uname -m)" >> "$ENGINE_VERSIONS_TSV"
    return
  fi

  interface="docker-api"
  endpoint="$ENGINE_SOCK"
  if [ "$DRY_RUN" = "1" ]; then
    version="dry-run-not-queried"
    name=""
    os=""
    kernel=""
    arch="$(uname -m)"
  else
    version="$(docker_e version --format '{{.Server.Version}}' 2>/dev/null || true)"
    name="$(docker_e info --format '{{.Name}}' 2>/dev/null || true)"
    os="$(docker_e info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
    kernel="$(docker_e info --format '{{.KernelVersion}}' 2>/dev/null || true)"
    arch="$(docker_e info --format '{{.Architecture}}' 2>/dev/null || true)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$label" "$interface" "$endpoint" "$(sanitize "${version:-unknown}")" \
    "$(sanitize "$name")" "$(sanitize "$os $kernel")" "$(sanitize "$arch")" >> "$ENGINE_VERSIONS_TSV"
}

# --------------------------------------------------------------------------------------------------
# Metric selection
# --------------------------------------------------------------------------------------------------

metric_enabled() {
  case ",$METRICS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------------------------------
# Image pull helpers (return 0 if usable, non-zero to trigger a clean SKIP)
# --------------------------------------------------------------------------------------------------

ensure_image_docker() {
  local image="$1"
  [ "$DRY_RUN" = "1" ] && { printf '    [dry-run] docker pull %s\n' "$image"; return 0; }
  docker_e image inspect "$image" >/dev/null 2>&1 && return 0
  docker_e pull "$image" >/dev/null 2>&1
}

ensure_image_apple() {
  local image="$1"
  [ "$DRY_RUN" = "1" ] && { printf '    [dry-run] %s images pull %s\n' "$CONTAINER_BIN" "$image"; return 0; }
  "$CONTAINER_BIN" images inspect "$image" >/dev/null 2>&1 && return 0
  "$CONTAINER_BIN" images pull "$image" >/dev/null 2>&1
}

# --------------------------------------------------------------------------------------------------
# Metric 1: idle memory
# --------------------------------------------------------------------------------------------------

metric_memory() {
  local engine="$CURRENT_ENGINE"
  if is_apple_container "$engine"; then
    metric_memory_apple
  else
    metric_memory_docker
  fi
}

metric_memory_docker() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_docker "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "memory" "cannot pull $ALPINE_IMAGE"
    return
  fi
  local old_ifs="$IFS" count
  IFS=','
  for count in $MEMORY_COUNTS; do
    IFS="$old_ifs"
    count="$(printf '%s' "$count" | sed 's/^ *//;s/ *$//')"
    [ -n "$count" ] && metric_memory_docker_count "$count"
    IFS=','
  done
  IFS="$old_ifs"
}

metric_memory_docker_count() {
  local count="$1" engine="$CURRENT_ENGINE"
  case "$count" in
    ''|*[!0-9]*) record_status FAIL "$engine" "memory" "invalid memory count: $count"; return ;;
  esac
  cleanup_docker_engine
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] sample used_mem + rss, run %s idle containers, resample\n' "$count"
    if [ "$count" -gt 0 ]; then
      for i in $(seq 1 "$count"); do
        docker_er run -d --name "$PREFIX-mem-$count-$i" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sleep 600
      done
    fi
    record_status PASS "$engine" "memory" "dry-run (${count} idle)"
    return
  fi
  local base rss_base peak rss_peak sys_delta rss_delta i
  sleep "$SETTLE"
  base="$(used_mem)"
  rss_base="$(process_rss_bytes "$engine")"
  if [ "$count" -gt 0 ]; then
    for i in $(seq 1 "$count"); do
      if ! docker_e run -d --name "$PREFIX-mem-$count-$i" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sleep 600 >/dev/null 2>&1; then
        record_status FAIL "$engine" "memory" "run container $i failed"
        cleanup_docker_engine
        return
      fi
    done
  fi
  sleep "$SETTLE"
  peak="$(used_mem)"
  rss_peak="$(process_rss_bytes "$engine")"
  sys_delta=$((peak - base))
  rss_delta=$((rss_peak - rss_base))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$count" "$ALPINE_IMAGE" "$sys_delta" "$(mb "$sys_delta")" "$rss_delta" "$(mb "$rss_delta")" >> "$MEMORY_TSV"
  cleanup_docker_engine
  record_status PASS "$engine" "memory" "system_delta=$(mb "$sys_delta")MB rss_delta=$(mb "$rss_delta")MB (${count} idle)"
}

metric_memory_apple() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_apple "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "memory" "cannot pull $ALPINE_IMAGE"
    return
  fi
  local old_ifs="$IFS" count
  IFS=','
  for count in $MEMORY_COUNTS; do
    IFS="$old_ifs"
    count="$(printf '%s' "$count" | sed 's/^ *//;s/ *$//')"
    [ -n "$count" ] && metric_memory_apple_count "$count"
    IFS=','
  done
  IFS="$old_ifs"
}

metric_memory_apple_count() {
  local count="$1" engine="$CURRENT_ENGINE"
  case "$count" in
    ''|*[!0-9]*) record_status FAIL "$engine" "memory" "invalid memory count: $count"; return ;;
  esac
  cleanup_apple_container
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] sample used_mem + rss, run %s idle apple containers, resample\n' "$count"
    if [ "$count" -gt 0 ]; then
      for i in $(seq 1 "$count"); do
        container_c run -d --name "$PREFIX-mem-$count-$i" "$ALPINE_IMAGE" sleep 600
      done
    fi
    record_status PASS "$engine" "memory" "dry-run (${count} idle)"
    return
  fi
  local base rss_base peak rss_peak sys_delta rss_delta i
  sleep "$SETTLE"
  base="$(used_mem)"
  rss_base="$(process_rss_bytes "$engine")"
  if [ "$count" -gt 0 ]; then
    for i in $(seq 1 "$count"); do
      if ! "$CONTAINER_BIN" run -d --name "$PREFIX-mem-$count-$i" "$ALPINE_IMAGE" sleep 600 >/dev/null 2>&1; then
        record_status FAIL "$engine" "memory" "run container $i failed"
        cleanup_apple_container
        return
      fi
    done
  fi
  sleep "$SETTLE"
  peak="$(used_mem)"
  rss_peak="$(process_rss_bytes "$engine")"
  sys_delta=$((peak - base))
  rss_delta=$((rss_peak - rss_base))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$count" "$ALPINE_IMAGE" "$sys_delta" "$(mb "$sys_delta")" "$rss_delta" "$(mb "$rss_delta")" >> "$MEMORY_TSV"
  cleanup_apple_container
  record_status PASS "$engine" "memory" "system_delta=$(mb "$sys_delta")MB rss_delta=$(mb "$rss_delta")MB (${count} idle)"
}

# --------------------------------------------------------------------------------------------------
# Metric 2: CPU-bound workload
# --------------------------------------------------------------------------------------------------

cpu_workload_cmd() {
  printf 'dd if=/dev/zero bs=1M count=%s 2>/dev/null | sha256sum >/dev/null' "$CPU_MB"
}

time_docker_cpu() {
  local cmd
  cmd="$(cpu_workload_cmd)"
  { time docker_e run --rm --label "$LABEL_KEY=$RUN_ID" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

time_apple_cpu() {
  local cmd
  cmd="$(cpu_workload_cmd)"
  { time "$CONTAINER_BIN" run --rm --name "$PREFIX-cpu-$RANDOM" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

metric_cpu() {
  local engine="$CURRENT_ENGINE"
  if is_apple_container "$engine"; then
    metric_cpu_apple
  else
    metric_cpu_docker
  fi
}

metric_cpu_docker() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_docker "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "cpu" "cannot pull $ALPINE_IMAGE"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] time CPU sha256 workload x%s (%s MiB each)\n' "$RUNS" "$CPU_MB"
    docker_er run --rm --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sh -c "$(cpu_workload_cmd)"
    record_status PASS "$engine" "cpu" "dry-run"
    return
  fi
  local run_i samples="" t med
  for run_i in $(seq 1 "$RUNS"); do
    t="$(time_docker_cpu)"
    [ -n "$t" ] && samples="$samples $t"
  done
  cleanup_docker_engine
  if [ -z "$samples" ]; then
    record_status FAIL "$engine" "cpu" "no timing samples captured"
    return
  fi
  # shellcheck disable=SC2086
  med="$(median $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$ALPINE_IMAGE" "$RUNS" "$CPU_MB" "$med" "$(sanitize "$samples")" >> "$CPU_TSV"
  record_status PASS "$engine" "cpu" "median=${med}s over $RUNS run(s), ${CPU_MB} MiB"
}

metric_cpu_apple() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_apple "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "cpu" "cannot pull $ALPINE_IMAGE"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] time apple CPU sha256 workload x%s (%s MiB each)\n' "$RUNS" "$CPU_MB"
    container_c run --rm "$ALPINE_IMAGE" sh -c "$(cpu_workload_cmd)"
    record_status PASS "$engine" "cpu" "dry-run"
    return
  fi
  local run_i samples="" t med
  for run_i in $(seq 1 "$RUNS"); do
    t="$(time_apple_cpu)"
    [ -n "$t" ] && samples="$samples $t"
  done
  cleanup_apple_container
  if [ -z "$samples" ]; then
    record_status FAIL "$engine" "cpu" "no timing samples captured"
    return
  fi
  # shellcheck disable=SC2086
  med="$(median $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$ALPINE_IMAGE" "$RUNS" "$CPU_MB" "$med" "$(sanitize "$samples")" >> "$CPU_TSV"
  record_status PASS "$engine" "cpu" "median=${med}s over $RUNS run(s), ${CPU_MB} MiB"
}

# --------------------------------------------------------------------------------------------------
# Metric 3: container-to-container network throughput
# --------------------------------------------------------------------------------------------------

metric_network() {
  local engine="$CURRENT_ENGINE"
  if is_apple_container "$engine"; then
    record_status SKIP "$engine" "network" "user-network C2C probe requires the Docker API (Apple Container unsupported)"
    return
  fi
  if ! ensure_image_docker "$IPERF_IMAGE"; then
    record_status SKIP "$engine" "network" "cannot pull $IPERF_IMAGE"
    return
  fi
  local net="$PREFIX-net" server="$PREFIX-iperf-srv"
  cleanup_docker_engine
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] network create %s; run iperf3 -s (alias iperf-server); client x%s runs\n' "$net" "$RUNS"
    docker_er network create --label "$LABEL_KEY=$RUN_ID" "$net"
    docker_er run -d --name "$server" --label "$LABEL_KEY=$RUN_ID" --network "$net" --network-alias iperf-server "$IPERF_IMAGE" -s
    docker_er run --rm --label "$LABEL_KEY=$RUN_ID" --network "$net" "$IPERF_IMAGE" -c iperf-server -f g -t 5 -J
    record_status PASS "$engine" "network" "dry-run"
    return
  fi
  if ! docker_e network create --label "$LABEL_KEY=$RUN_ID" "$net" >/dev/null 2>&1; then
    record_status FAIL "$engine" "network" "network create failed"
    cleanup_docker_engine
    return
  fi
  if ! docker_e run -d --name "$server" --label "$LABEL_KEY=$RUN_ID" --network "$net" \
       --network-alias iperf-server "$IPERF_IMAGE" -s >/dev/null 2>&1; then
    record_status FAIL "$engine" "network" "iperf3 server start failed"
    cleanup_docker_engine
    return
  fi
  sleep 2
  local run_i out gbps samples=""
  for run_i in $(seq 1 "$RUNS"); do
    out="$(docker_e run --rm --label "$LABEL_KEY=$RUN_ID" --network "$net" "$IPERF_IMAGE" \
           -c iperf-server -f g -t 5 -J 2>/dev/null)"
    gbps="$(printf '%s' "$out" | awk -F'[:,]' '/bits_per_second/ { v=$2 } END { if (v+0>0) printf "%.4f", v/1e9 }')"
    [ -n "$gbps" ] && samples="$samples $gbps"
  done
  cleanup_docker_engine
  if [ -z "$samples" ]; then
    record_status FAIL "$engine" "network" "no throughput samples parsed from iperf3 JSON"
    return
  fi
  local med
  # shellcheck disable=SC2086
  med="$(median $samples)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$engine" "$IPERF_IMAGE" "$RUNS" "$med" "$(sanitize "$samples")" >> "$NETWORK_TSV"
  record_status PASS "$engine" "network" "median=${med} Gbps over $RUNS run(s)"
}

# --------------------------------------------------------------------------------------------------
# Metric 4: bind-mount filesystem vs in-container filesystem
# --------------------------------------------------------------------------------------------------

# Workload: create FS_FILES tiny files in $target, timed with `time`, wall seconds parsed from stderr.
fs_workload_cmd() {
  printf 'rm -rf %s && mkdir -p %s && for i in $(seq 1 %s); do echo x > %s/f$i; done' \
    "$1" "$1" "$FS_FILES" "$1"
}

parse_real_seconds() {
  awk '
    /real/ {
      for (i=1;i<=NF;i++) {
        if ($i ~ /m/ && $i ~ /s/) { split($i,p,"m"); sub("s","",p[2]); printf "%.4f", p[1]*60 + p[2]; exit }
        if ($i ~ /^[0-9.]+$/) { printf "%.4f", $i; exit }
      }
    }'
}

metric_fs() {
  local engine="$CURRENT_ENGINE"
  if is_apple_container "$engine"; then
    metric_fs_apple
  else
    metric_fs_docker
  fi
}

time_docker_host() {
  local hostdir="$1" cmd
  cmd="$(fs_workload_cmd /mnt/work)"
  { time docker_e run --rm --label "$LABEL_KEY=$RUN_ID" -v "$hostdir:/mnt/work" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

time_docker_incontainer() {
  local cmd
  cmd="$(fs_workload_cmd /work)"
  { time docker_e run --rm --label "$LABEL_KEY=$RUN_ID" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

metric_fs_docker() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_docker "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "fs" "cannot pull $ALPINE_IMAGE"
    return
  fi
  local hostdir="$WORKDIR/${ENGINE_ID}-fsmount"
  mkdir -p "$hostdir"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] time bind-mount write x%s vs in-container write x%s (%s files each)\n' "$RUNS" "$RUNS" "$FS_FILES"
    docker_er run --rm --label "$LABEL_KEY=$RUN_ID" -v "$hostdir:/mnt/work" "$ALPINE_IMAGE" sh -c "$(fs_workload_cmd /mnt/work)"
    docker_er run --rm --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sh -c "$(fs_workload_cmd /work)"
    record_status PASS "$engine" "fs" "dry-run"
    return
  fi
  local run_i host_samples="" cont_samples="" t
  for run_i in $(seq 1 "$RUNS"); do
    t="$(time_docker_host "$hostdir")"
    [ -n "$t" ] && host_samples="$host_samples $t"
    t="$(time_docker_incontainer)"
    [ -n "$t" ] && cont_samples="$cont_samples $t"
  done
  rm -rf "$hostdir"
  cleanup_docker_engine
  if [ -z "$host_samples" ] || [ -z "$cont_samples" ]; then
    record_status FAIL "$engine" "fs" "no timing samples captured"
    return
  fi
  local host_med cont_med rat
  # shellcheck disable=SC2086
  host_med="$(median $host_samples)"
  # shellcheck disable=SC2086
  cont_med="$(median $cont_samples)"
  rat="$(ratio "$host_med" "$cont_med")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$FS_FILES" "$RUNS" "$host_med" "$cont_med" "$rat" >> "$FS_TSV"
  record_status PASS "$engine" "fs" "bind=${host_med}s in-container=${cont_med}s ratio=${rat}x (${FS_FILES} files)"
}

time_apple_host() {
  local hostdir="$1" cmd
  cmd="$(fs_workload_cmd /mnt/work)"
  { time "$CONTAINER_BIN" run --rm --name "$PREFIX-fs-$RANDOM" -v "$hostdir:/mnt/work" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

time_apple_incontainer() {
  local cmd
  cmd="$(fs_workload_cmd /work)"
  { time "$CONTAINER_BIN" run --rm --name "$PREFIX-fs-$RANDOM" \
      "$ALPINE_IMAGE" sh -c "$cmd" >/dev/null 2>&1 ; } 2>&1 | parse_real_seconds
}

metric_fs_apple() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_apple "$ALPINE_IMAGE"; then
    record_status SKIP "$engine" "fs" "cannot pull $ALPINE_IMAGE"
    return
  fi
  local hostdir="$WORKDIR/${ENGINE_ID}-fsmount"
  mkdir -p "$hostdir"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] time apple bind-mount write vs in-container write (%s files)\n' "$FS_FILES"
    container_c run --rm -v "$hostdir:/mnt/work" "$ALPINE_IMAGE" sh -c "$(fs_workload_cmd /mnt/work)"
    container_c run --rm "$ALPINE_IMAGE" sh -c "$(fs_workload_cmd /work)"
    record_status PASS "$engine" "fs" "dry-run"
    return
  fi
  local run_i host_samples="" cont_samples="" t
  for run_i in $(seq 1 "$RUNS"); do
    t="$(time_apple_host "$hostdir")"
    [ -n "$t" ] && host_samples="$host_samples $t"
    t="$(time_apple_incontainer)"
    [ -n "$t" ] && cont_samples="$cont_samples $t"
  done
  rm -rf "$hostdir"
  cleanup_apple_container
  if [ -z "$host_samples" ] || [ -z "$cont_samples" ]; then
    record_status FAIL "$engine" "fs" "no timing samples captured (bind mounts may be unsupported)"
    return
  fi
  local host_med cont_med rat
  # shellcheck disable=SC2086
  host_med="$(median $host_samples)"
  # shellcheck disable=SC2086
  cont_med="$(median $cont_samples)"
  rat="$(ratio "$host_med" "$cont_med")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$FS_FILES" "$RUNS" "$host_med" "$cont_med" "$rat" >> "$FS_TSV"
  record_status PASS "$engine" "fs" "bind=${host_med}s in-container=${cont_med}s ratio=${rat}x (${FS_FILES} files)"
}

# --------------------------------------------------------------------------------------------------
# Per-engine driver
# --------------------------------------------------------------------------------------------------

run_engine() {
  CURRENT_ENGINE="$1"
  ENGINE_ID="$(engine_id "$CURRENT_ENGINE")"
  PREFIX="dorybench${ENGINE_ID}${RUN_SLUG}"
  if is_apple_container "$CURRENT_ENGINE"; then
    ENGINE_SOCK=""
    note "$(engine_label "$CURRENT_ENGINE") (CLI: $CONTAINER_BIN)"
  else
    ENGINE_SOCK="$(engine_socket "$CURRENT_ENGINE")"
    note "$(engine_label "$CURRENT_ENGINE") ($ENGINE_SOCK)"
  fi

  if ! prepare_dory_release_app; then
    return
  fi

  if ! engine_available "$CURRENT_ENGINE"; then
    if is_apple_container "$CURRENT_ENGINE"; then
      record_status SKIP "$CURRENT_ENGINE" "all metrics" "container CLI not found: $CONTAINER_BIN"
    else
      record_status SKIP "$CURRENT_ENGINE" "all metrics" "socket not found: $ENGINE_SOCK"
    fi
    return
  fi

  record_engine_version
  cleanup_engine

  if metric_enabled memory; then metric_memory; else record_status SKIP "$CURRENT_ENGINE" "memory" "disabled via --metrics"; fi
  if metric_enabled cpu; then metric_cpu; else record_status SKIP "$CURRENT_ENGINE" "cpu" "disabled via --metrics"; fi
  if metric_enabled network; then metric_network; else record_status SKIP "$CURRENT_ENGINE" "network" "disabled via --metrics"; fi
  if metric_enabled fs; then metric_fs; else record_status SKIP "$CURRENT_ENGINE" "fs" "disabled via --metrics"; fi

  cleanup_engine
}

# --------------------------------------------------------------------------------------------------
# Summary table + machine-readable results
# --------------------------------------------------------------------------------------------------

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Convert a TSV (with header) into a JSON array of objects keyed by the header row.
tsv_to_json_array() {
  local file="$1"
  [ -f "$file" ] || { printf '[]'; return; }
  awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) keys[i] = $i; nkeys = NF; next }
    {
      if (out != "") out = out ",";
      out = out "{";
      for (i = 1; i <= nkeys; i++) {
        val = $i;
        gsub(/\\/, "\\\\", val);
        gsub(/"/, "\\\"", val);
        out = out "\"" keys[i] "\":\"" val "\"";
        if (i < nkeys) out = out ",";
      }
      out = out "}";
    }
    END { printf "[%s]", out }
  ' "$file"
}

print_table() {
  note "results table"
  echo ""
  if metric_enabled memory && [ -s "$MEMORY_TSV" ]; then
    echo "IDLE MEMORY ($ALPINE_IMAGE containers; counts: $MEMORY_COUNTS)"
    printf '  %-16s %10s %14s %14s\n' "engine" "count" "system_MB" "engine_rss_MB"
    awk -F'\t' 'NR>1 { printf "  %-16s %10s %14s %14s\n", $1, $2, $5, $7 }' "$MEMORY_TSV"
    echo ""
  fi
  if metric_enabled cpu && [ -s "$CPU_TSV" ]; then
    echo "CPU WORKLOAD ($CPU_MB MiB sha256, median of $RUNS)"
    printf '  %-16s %14s\n' "engine" "seconds"
    awk -F'\t' 'NR>1 { printf "  %-16s %14s\n", $1, $5 }' "$CPU_TSV"
    echo ""
  fi
  if metric_enabled network && [ -s "$NETWORK_TSV" ]; then
    echo "CONTAINER-TO-CONTAINER NETWORK (iperf3, median of $RUNS)"
    printf '  %-16s %14s\n' "engine" "Gbps"
    awk -F'\t' 'NR>1 { printf "  %-16s %14s\n", $1, $4 }' "$NETWORK_TSV"
    echo ""
  fi
  if metric_enabled fs && [ -s "$FS_TSV" ]; then
    echo "BIND-MOUNT FILESYSTEM ($FS_FILES files, median of $RUNS)"
    printf '  %-16s %12s %14s %10s\n' "engine" "bind_s" "in_cont_s" "ratio"
    awk -F'\t' 'NR>1 { printf "  %-16s %12s %14s %9sx\n", $1, $4, $5, $6 }' "$FS_TSV"
    echo ""
  fi
}

write_summary_md() {
  {
    echo "# Dory Benchmark Run"
    echo ""
    echo "- Run ID: \`$RUN_ID\`"
    echo "- Engines: \`$ENGINES\`"
    echo "- Metrics: \`$METRICS\`"
    echo "- Memory counts: \`$MEMORY_COUNTS\`"
    echo "- Runs per timed metric: \`$RUNS\`"
    echo "- Result directory: \`$WORKDIR\`"
    echo ""
    echo "## Raw Files"
    echo ""
    echo "- Machine spec: \`machine-spec.tsv\`"
    echo "- Engine versions: \`engine-versions.tsv\`"
    echo "- Status: \`status.tsv\`"
    echo "- Memory: \`memory.tsv\`"
    echo "- CPU: \`cpu.tsv\`"
    echo "- Network: \`network.tsv\`"
    echo "- Filesystem: \`filesystem.tsv\`"
    echo "- JSON summary: \`summary.json\`"
    echo ""
    echo "## Machine"
    echo ""
    echo '```tsv'
    cat "$MACHINE_SPEC"
    echo '```'
    echo ""
    echo "## Engine Versions"
    echo ""
    echo '```tsv'
    cat "$ENGINE_VERSIONS_TSV"
    echo '```'
    echo ""
    echo "## Status"
    echo ""
    echo '```tsv'
    cat "$STATUS_TSV"
    echo '```'
    if metric_enabled memory && [ -s "$MEMORY_TSV" ]; then
      echo ""
      echo "## Idle Memory"
      echo ""
      echo '| Engine | Idle containers | System delta MB | Engine process RSS delta MB |'
      echo '|---|---:|---:|---:|'
      awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %s |\n", $1, $2, $5, $7 }' "$MEMORY_TSV"
    fi
    if metric_enabled cpu && [ -s "$CPU_TSV" ]; then
      echo ""
      echo "## CPU"
      echo ""
      echo '| Engine | Median seconds | Samples |'
      echo '|---|---:|---|'
      awk -F'\t' 'NR>1 { printf "| %s | %s | `%s` |\n", $1, $5, $6 }' "$CPU_TSV"
    fi
    if metric_enabled network && [ -s "$NETWORK_TSV" ]; then
      echo ""
      echo "## Network"
      echo ""
      echo '| Engine | Median Gbps | Samples |'
      echo '|---|---:|---|'
      awk -F'\t' 'NR>1 { printf "| %s | %s | `%s` |\n", $1, $4, $5 }' "$NETWORK_TSV"
    fi
    if metric_enabled fs && [ -s "$FS_TSV" ]; then
      echo ""
      echo "## Filesystem"
      echo ""
      echo '| Engine | Bind mount seconds | In-container seconds | Ratio |'
      echo '|---|---:|---:|---:|'
      awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %sx |\n", $1, $4, $5, $6 }' "$FS_TSV"
    fi
    echo ""
    echo "## Publication Guardrail"
    echo ""
    echo "Publish this run only with the raw directory intact. Do not combine these medians with numbers from a different Mac, date, or engine version."
  } > "$SUMMARY_MD"
}

write_summary() {
  local mem_json cpu_json net_json fs_json status_json versions_json
  mem_json="$(tsv_to_json_array "$MEMORY_TSV")"
  cpu_json="$(tsv_to_json_array "$CPU_TSV")"
  net_json="$(tsv_to_json_array "$NETWORK_TSV")"
  fs_json="$(tsv_to_json_array "$FS_TSV")"
  status_json="$(tsv_to_json_array "$STATUS_TSV")"
  versions_json="$(tsv_to_json_array "$ENGINE_VERSIONS_TSV")"
  cat > "$SUMMARY_JSON" <<EOF
{
  "runId": "$RUN_ID",
  "engines": "$(json_escape "$ENGINES")",
  "metrics": "$(json_escape "$METRICS")",
  "dryRun": $( [ "$DRY_RUN" = "1" ] && echo true || echo false ),
  "memoryCount": $MEMORY_COUNT,
  "memoryCounts": "$(json_escape "$MEMORY_COUNTS")",
  "runs": $RUNS,
  "cpuMB": $CPU_MB,
  "fsFiles": $FS_FILES,
  "settle": $SETTLE,
  "pass": $PASS_COUNT,
  "fail": $FAIL_COUNT,
  "skip": $SKIP_COUNT,
  "memory": $mem_json,
  "cpu": $cpu_json,
  "network": $net_json,
  "filesystem": $fs_json,
  "engineVersions": $versions_json,
  "status": $status_json,
  "files": {
    "memory": "$MEMORY_TSV",
    "cpu": "$CPU_TSV",
    "network": "$NETWORK_TSV",
    "filesystem": "$FS_TSV",
    "engineVersions": "$ENGINE_VERSIONS_TSV",
    "status": "$STATUS_TSV",
    "machineSpec": "$MACHINE_SPEC",
    "summaryMarkdown": "$SUMMARY_MD"
  }
}
EOF
  write_summary_md
}

# --------------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------------

mkdir -p "$WORKDIR"
printf 'status\tengine\tmetric\tdetail\n' > "$STATUS_TSV"
printf 'engine\tcontainers\timage\tsystem_delta_bytes\tsystem_delta_mb\tprocess_delta_bytes\tprocess_delta_mb\n' > "$MEMORY_TSV"
printf 'engine\timage\truns\tworkload_mib\tmedian_seconds\tsamples_seconds\n' > "$CPU_TSV"
printf 'engine\timage\truns\tmedian_gbps\tsamples_gbps\n' > "$NETWORK_TSV"
printf 'engine\tfiles\truns\tbind_seconds\tincontainer_seconds\tratio\n' > "$FS_TSV"
printf 'engine\tlabel\tinterface\tendpoint\tversion\tname\tos_kernel\tarchitecture\n' > "$ENGINE_VERSIONS_TSV"

trap '{ [ -n "${CURRENT_ENGINE:-}" ] && cleanup_engine; write_summary; } >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

note "benchmark run $RUN_ID"
note "engines: $ENGINES"
note "metrics: $METRICS"
[ "$DRY_RUN" = "1" ] && note "DRY RUN -- no engine commands are executed"
note "results dir: $WORKDIR"

capture_machine_spec

OLD_IFS="$IFS"
IFS=','
for engine in $ENGINES; do
  IFS="$OLD_IFS"
  engine="$(printf '%s' "$engine" | sed 's/^ *//;s/ *$//')"
  [ -n "$engine" ] && run_engine "$engine"
  IFS=','
done
IFS="$OLD_IFS"

print_table
write_summary

note "summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
note "summary json: $SUMMARY_JSON"
note "summary markdown: $SUMMARY_MD"

[ "$FAIL_COUNT" -eq 0 ]
