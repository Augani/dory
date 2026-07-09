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
# Engines: dory, orbstack, docker-desktop by default; apple-container can be requested explicitly
# as a competitor on macOS 26+ hosts. Docker-API engines are driven over their unix socket (selected
# via DORY_SOCK / ORBSTACK_SOCK / DOCKER_DESKTOP_SOCK, mirroring readiness.sh). Apple Container is
# driven via its own `container` CLI. Any engine whose socket or CLI is absent is reported [SKIP]
# and never fails the run. Every resource created carries a run-scoped label
# (dev.dory.bench=<runId>) or a run-scoped name prefix, and cleanup removes only those.
#
# This measures; it does not market. Output is measurements + this methodology comment only.
#
# Examples:
#   scripts/benchmark-compare.sh --engines dory
#   scripts/benchmark-compare.sh --engines dory,orbstack,apple-container --memory-count 4 --runs 5
#   scripts/benchmark-compare.sh --engines dory --metrics memory,cpu,fs
#   scripts/benchmark-compare.sh --dory-app /Applications/Dory.app --engines dory,orbstack,docker-desktop
#   scripts/benchmark-compare.sh --dry-run --engines dory,orbstack,docker-desktop
#   scripts/benchmark-compare.sh --engines dory,orbstack,docker-desktop,apple-container
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
ENGINES="${ENGINES:-dory,orbstack,docker-desktop}"
METRICS="${METRICS:-memory,cpu,network,fs}"
ALPINE_IMAGE="${BENCH_ALPINE_IMAGE:-alpine:latest}"
IPERF_IMAGE="${BENCH_IPERF_IMAGE:-taoyou/iperf3-alpine:latest}"
MEMORY_COUNT="${BENCH_MEMORY_COUNT:-3}"
MEMORY_COUNTS="${BENCH_MEMORY_COUNTS:-$MEMORY_COUNT}"
RUNS="${BENCH_RUNS:-3}"
CPU_MB="${BENCH_CPU_MB:-256}"
FS_FILES="${BENCH_FS_FILES:-2000}"
SETTLE="${BENCH_SETTLE:-12}"
# Compile workload (the `build` metric). A small Alpine toolchain image (busybox wget+tar built in,
# ~10 MiB) compiles a pinned Redis source. Setup (image pull, apk toolchain, source download+extract)
# is UNTIMED; only `make` is timed, so the number is pure compile wall-clock, comparable across
# engines. BUILD_MEM_SAMPLE samples host memory during the compile for the peak-under-load figure.
BUILD_IMAGE="${BENCH_BUILD_IMAGE:-alpine:3.20}"
BUILD_JOBS="${BENCH_BUILD_JOBS:-8}"
BUILD_SRC_URL="${BENCH_BUILD_SRC_URL:-https://github.com/redis/redis/archive/refs/tags/7.4.1.tar.gz}"
BUILD_SRC_DIR="${BENCH_BUILD_SRC_DIR:-redis-7.4.1}"
BUILD_MAKE_ARGS="${BENCH_BUILD_MAKE_ARGS:-MALLOC=libc}"
BUILD_MEM_SAMPLE="${BENCH_BUILD_MEM_SAMPLE:-2}"
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
BUILD_TSV="$WORKDIR/build.tsv"
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
  --engines LIST       Comma-separated: dory,orbstack,docker-desktop,apple-container (default: $ENGINES)
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
    colima) echo "Colima" ;;
    podman) echo "Podman" ;;
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
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    # Podman's docker-compatible socket path is instance-specific; the campaign resolves it via
    # `podman machine inspect` and exports PODMAN_SOCK, so there is no static default here.
    podman) echo "${PODMAN_SOCK:-}" ;;
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

engine_process_pattern() {
  case "$1" in
    dory) printf '%s' "${DORY_PROCESS_PATTERN:-Dory|doryd|dory-hv|dory-vmm|gvproxy}" ;;
    orbstack) printf '%s' "${ORBSTACK_PROCESS_PATTERN:-OrbStack|orbstack-helper|xbin/vmgr}" ;;
    colima) printf '%s' "${COLIMA_PROCESS_PATTERN:-colima|limactl|lima-guestagent|socket_vmnet}" ;;
    podman) printf '%s' "${PODMAN_PROCESS_PATTERN:-podman|vfkit|gvproxy}" ;;
    docker-desktop|desktop) printf '%s' "${DOCKER_DESKTOP_PROCESS_PATTERN:-Docker|com.docker}" ;;
    apple|apple-container|container) printf '%s' "${APPLE_CONTAINER_PROCESS_PATTERN:-container-runtime-linux|container-network-vmnet|containerization|com.apple.container}" ;;
    *) printf '%s' "${GENERIC_ENGINE_PROCESS_PATTERN:-$1}" ;;
  esac
}

process_rss_bytes() {
  local pattern; pattern="$(engine_process_pattern "$1")"
  ps -axo rss,args | awk -v pat="$pattern" '$0 ~ pat && $0 !~ /awk/ { sum += $1 } END { printf "%.0f", sum * 1024 }'
}

# Sum phys_footprint across the whole engine process tree. phys_footprint (resident + compressed +
# other charged memory) is the figure reviewers screenshot; RSS materially undercounts it (dory-hv
# measured 205MB RSS vs 645MB footprint). Falls back to RSS if footprint(1) is unavailable.
process_footprint_bytes() {
  local engine="$1" pattern pid val unit bytes total=0 got=0
  pattern="$(engine_process_pattern "$engine")"
  for pid in $(ps -axo pid,args | awk -v pat="$pattern" '$0 ~ pat && $0 !~ /awk/ { print $1 }'); do
    set -- $(/usr/bin/footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }')
    val="${1:-}"; unit="${2:-}"
    [ -n "$val" ] || continue
    got=1
    case "$unit" in
      KB|K) bytes="$(awk -v v="$val" 'BEGIN { printf "%.0f", v * 1024 }')" ;;
      MB|M) bytes="$(awk -v v="$val" 'BEGIN { printf "%.0f", v * 1048576 }')" ;;
      GB|G) bytes="$(awk -v v="$val" 'BEGIN { printf "%.0f", v * 1073741824 }')" ;;
      *)    bytes="$(awk -v v="$val" 'BEGIN { printf "%.0f", v }')" ;;
    esac
    total=$((total + bytes))
  done
  [ "$got" = "1" ] && printf '%s' "$total" || process_rss_bytes "$engine"
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

# Coefficient of variation (%) over the numeric args: 100 * sample_stddev / mean. This is the
# reproducibility signal for a metric — competitor bind/fs numbers that swing run-to-run (OrbStack
# 0.222->0.501s, Colima 0.159->0.917s in the research) show up as a high CV. Returns 0 for n<2.
cv_pct() {
  [ "$#" -gt 1 ] || { printf '0'; return; }
  printf '%s\n' "$@" | awk '
    { v[n++] = $1 + 0; sum += $1 + 0 }
    END {
      if (n < 2 || sum == 0) { printf "0"; exit }
      mean = sum / n
      for (i = 0; i < n; i++) { d = v[i] - mean; ss += d * d }
      printf "%.1f", 100 * sqrt(ss / (n - 1)) / mean
    }'
}

# CV threshold above which a metric row is flagged unstable in the status/summary.
CV_WARN_PCT="${BENCH_CV_WARN_PCT:-15}"

# Emits " cv=X%" plus an UNSTABLE marker when the coefficient of variation exceeds the threshold, for
# appending to a PASS status detail. Empty-safe.
cv_detail() {
  awk -v cv="${1:-0}" -v t="$CV_WARN_PCT" 'BEGIN {
    printf " cv=%s%%", cv
    if (cv + 0 > t + 0) printf " UNSTABLE(>%s%%)", t
  }'
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

# Best-effort per-engine VM profile: which VMM the engine runs and, for VZ-family engines, the
# Rosetta state. This is the P0.5 stamp that lets a reader trust (or distrust) a competitor multiplier
# without re-running: a Colima "vz+virtiofs" number is a different beast from "qemu+sshfs", and Docker
# Desktop's VMM-vs-Virtualization.framework toggle changes everything. Echoes `vm_type<TAB>vmm<TAB>rosetta`.
detect_engine_vm_profile() {
  local engine="$1" vm_type="unknown" vmm="unknown" rosetta="unknown" store
  case "$engine" in
    dory|dory-*)
      vm_type="dory-hv"; vmm="dory-hv-custom-hvf"; rosetta="no" ;;
    orbstack)
      vm_type="orbstack"; vmm="orbstack-custom"; rosetta="rosetta" ;;
    colima)
      if command -v colima >/dev/null 2>&1; then
        vm_type="$(colima list -j 2>/dev/null | grep -o '"vmType":"[^"]*"' | head -1 | cut -d'"' -f4)"
        [ -n "$vm_type" ] || vm_type="unknown"
        vmm="$vm_type"
        rosetta="$(colima list -j 2>/dev/null | grep -o '"rosetta":[a-z]*' | head -1 | cut -d: -f2)"
        [ -n "$rosetta" ] || rosetta="unknown"
      fi ;;
    docker-desktop)
      for store in "$HOME/Library/Group Containers/group.com.docker/settings-store.json" \
                   "$HOME/Library/Group Containers/group.com.docker/settings.json"; do
        [ -f "$store" ] || continue
        if grep -q '"useVirtualizationFramework"[[:space:]]*:[[:space:]]*true' "$store" 2>/dev/null; then
          vm_type="vz"; vmm="apple-virtualization"
        elif grep -q '"useVirtualizationFramework"[[:space:]]*:[[:space:]]*false' "$store" 2>/dev/null; then
          vm_type="docker-vmm"; vmm="docker-vmm"
        fi
        if grep -qi '"rosetta"[[:space:]]*:[[:space:]]*true\|"useRosetta"[[:space:]]*:[[:space:]]*true' "$store" 2>/dev/null; then
          rosetta="rosetta"
        else
          rosetta="no"
        fi
        break
      done ;;
    apple-container|container)
      vm_type="apple-vz"; vmm="apple-virtualization" ;;
  esac
  printf '%s\t%s\t%s' "$vm_type" "$vmm" "$rosetta"
}

record_engine_version() {
  local engine="$CURRENT_ENGINE" label endpoint version name os kernel arch interface vm_profile
  vm_profile="$(detect_engine_vm_profile "$engine")"
  label="$(engine_label "$engine")"
  if is_apple_container "$engine"; then
    interface="container-cli"
    endpoint="$CONTAINER_BIN"
    if [ "$DRY_RUN" = "1" ]; then
      version="dry-run-not-queried"
    else
      version="$("$CONTAINER_BIN" --version 2>/dev/null | head -1 || true)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$engine" "$label" "$interface" "$endpoint" "$(sanitize "${version:-unknown}")" "" "" "$(uname -m)" "$vm_profile" >> "$ENGINE_VERSIONS_TSV"
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$label" "$interface" "$endpoint" "$(sanitize "${version:-unknown}")" \
    "$(sanitize "$name")" "$(sanitize "$os $kernel")" "$(sanitize "$arch")" "$vm_profile" >> "$ENGINE_VERSIONS_TSV"
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
  local base rss_base fp_base peak rss_peak fp_peak sys_delta rss_delta i
  sleep "$SETTLE"
  base="$(used_mem)"
  rss_base="$(process_rss_bytes "$engine")"
  fp_base="$(process_footprint_bytes "$engine")"
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
  fp_peak="$(process_footprint_bytes "$engine")"
  sys_delta=$((peak - base))
  rss_delta=$((rss_peak - rss_base))
  # Reclaim curve (opt-in via BENCH_RECLAIM_CURVE=1): stop the containers, then sample phys_footprint
  # at intervals. Dory's free-page reporting drops footprint over time; VZ-backed engines (Docker VMM,
  # Colima/Lima, Apple container) cannot return guest memory so their curve stays flat — the §5 moat.
  local curve="" t prev=0
  if [ "${BENCH_RECLAIM_CURVE:-0}" = "1" ] && [ "$count" -gt 0 ]; then
    cleanup_docker_engine
    for t in ${RECLAIM_CURVE_SECONDS:-0 30 120 300}; do
      [ "$t" -gt "$prev" ] && sleep $((t - prev))
      prev="$t"
      curve="${curve:+$curve,}${t}s=$(mb "$(process_footprint_bytes "$engine")")MB"
    done
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$count" "$ALPINE_IMAGE" "$sys_delta" "$(mb "$sys_delta")" "$rss_delta" "$(mb "$rss_delta")" \
    "$(mb "$fp_base")" "$(mb "$fp_peak")" "$(sanitize "${curve:-n/a}")" >> "$MEMORY_TSV"
  cleanup_docker_engine
  record_status PASS "$engine" "memory" "sys_delta=$(mb "$sys_delta")MB footprint=$(mb "$fp_base")->$(mb "$fp_peak")MB (${count} idle)${curve:+ reclaim[$curve]}"
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
  local base rss_base fp_base peak rss_peak fp_peak sys_delta rss_delta i
  sleep "$SETTLE"
  base="$(used_mem)"
  rss_base="$(process_rss_bytes "$engine")"
  fp_base="$(process_footprint_bytes "$engine")"
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
  fp_peak="$(process_footprint_bytes "$engine")"
  sys_delta=$((peak - base))
  rss_delta=$((rss_peak - rss_base))
  # Reclaim curve: Apple container is per-container-VM on Virtualization.framework, which cannot
  # return guest memory to the host, so this curve is expected to stay flat (the contrast §5 sells).
  local curve="" t prev=0
  if [ "${BENCH_RECLAIM_CURVE:-0}" = "1" ] && [ "$count" -gt 0 ]; then
    cleanup_apple_container
    for t in ${RECLAIM_CURVE_SECONDS:-0 30 120 300}; do
      [ "$t" -gt "$prev" ] && sleep $((t - prev))
      prev="$t"
      curve="${curve:+$curve,}${t}s=$(mb "$(process_footprint_bytes "$engine")")MB"
    done
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$count" "$ALPINE_IMAGE" "$sys_delta" "$(mb "$sys_delta")" "$rss_delta" "$(mb "$rss_delta")" \
    "$(mb "$fp_base")" "$(mb "$fp_peak")" "$(sanitize "${curve:-n/a}")" >> "$MEMORY_TSV"
  cleanup_apple_container
  record_status PASS "$engine" "memory" "sys_delta=$(mb "$sys_delta")MB footprint=$(mb "$fp_base")->$(mb "$fp_peak")MB (${count} idle)${curve:+ reclaim[$curve]}"
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
  timed_real_seconds docker_e run --rm --label "$LABEL_KEY=$RUN_ID" \
      "$ALPINE_IMAGE" sh -c "$cmd"
}

time_apple_cpu() {
  local cmd
  cmd="$(cpu_workload_cmd)"
  timed_real_seconds "$CONTAINER_BIN" run --rm --name "$PREFIX-cpu-$RANDOM" \
      "$ALPINE_IMAGE" sh -c "$cmd"
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
  # shellcheck disable=SC2086
  local cpu_cv; cpu_cv="$(cv_pct $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$ALPINE_IMAGE" "$RUNS" "$CPU_MB" "$med" "$(sanitize "$samples")" "$cpu_cv" >> "$CPU_TSV"
  record_status PASS "$engine" "cpu" "median=${med}s over $RUNS run(s), ${CPU_MB} MiB$(cv_detail "$cpu_cv")"
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
  # shellcheck disable=SC2086
  local cpu_cv; cpu_cv="$(cv_pct $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$ALPINE_IMAGE" "$RUNS" "$CPU_MB" "$med" "$(sanitize "$samples")" "$cpu_cv" >> "$CPU_TSV"
  record_status PASS "$engine" "cpu" "median=${med}s over $RUNS run(s), ${CPU_MB} MiB$(cv_detail "$cpu_cv")"
}

# --------------------------------------------------------------------------------------------------
# Metric: bounded real compile (wall time + peak host memory under load)
# --------------------------------------------------------------------------------------------------

# The in-container script: fetch + extract the pinned source (untimed), then time only `make`. The
# container prints BUILD_SECONDS=<n> so the host reads a pure compile time free of pull/download cost.
build_workload_script() {
  cat <<SH
set -e
apk add --no-cache build-base linux-headers >/dev/null 2>&1
cd /tmp
wget -q -O src.tar.gz "$BUILD_SRC_URL"
tar xzf src.tar.gz
cd "$BUILD_SRC_DIR"
S=\$(date +%s.%N)
make -j$BUILD_JOBS $BUILD_MAKE_ARGS >/dev/null 2>&1
E=\$(date +%s.%N)
awk -v s=\$S -v e=\$E 'BEGIN { printf "BUILD_SECONDS=%.3f\n", e - s }'
SH
}

# Sample system-used and engine-RSS memory every BUILD_MEM_SAMPLE seconds until the marker file is
# removed; write the observed maxima to $1. Baseline deltas are computed by the caller.
build_memory_sampler() {
  local out="$1" marker="$2" engine="$CURRENT_ENGINE" sys peak_sys=0 rss peak_rss=0
  while [ -f "$marker" ]; do
    sys="$(used_mem)"
    rss="$(process_rss_bytes "$engine")"
    awk -v a="$sys" -v b="$peak_sys" 'BEGIN { exit !(a+0 > b+0) }' && peak_sys="$sys"
    awk -v a="$rss" -v b="$peak_rss" 'BEGIN { exit !(a+0 > b+0) }' && peak_rss="$rss"
    sleep "$BUILD_MEM_SAMPLE"
  done
  printf '%s\t%s\n' "$peak_sys" "$peak_rss" > "$out"
}

metric_build() {
  local engine="$CURRENT_ENGINE"
  if is_apple_container "$engine"; then
    metric_build_apple
  else
    metric_build_docker
  fi
}

# Run the compile once, streaming BUILD_SECONDS from the container while a background sampler tracks
# peak host memory. Returns via the build TSV: median compile seconds + peak memory deltas over the
# pre-build baseline (settled). Peak-under-load is the figure a shared-VM engine is expected to win.
metric_build_docker() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_docker "$BUILD_IMAGE"; then
    record_status SKIP "$engine" "build" "cannot pull $BUILD_IMAGE"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] compile %s (make -j%s %s) x%s; sample peak memory\n' "$BUILD_SRC_DIR" "$BUILD_JOBS" "$BUILD_MAKE_ARGS" "$RUNS"
    record_status PASS "$engine" "build" "dry-run"
    return
  fi
  local run_i samples="" peak_sys_max=0 peak_rss_max=0 base_sys base_rss
  local script marker sampler_out t line
  script="$(build_workload_script)"
  for run_i in $(seq 1 "$RUNS"); do
    sleep "$SETTLE"
    base_sys="$(used_mem)"
    base_rss="$(process_rss_bytes "$engine")"
    marker="$(mktemp "${TMPDIR:-/tmp}/dorybench-build.XXXXXX")"
    sampler_out="$(mktemp "${TMPDIR:-/tmp}/dorybench-buildmem.XXXXXX")"
    build_memory_sampler "$sampler_out" "$marker" &
    local sampler_pid=$!
    t=""
    while IFS= read -r line; do
      case "$line" in BUILD_SECONDS=*) t="${line#BUILD_SECONDS=}" ;; esac
    done < <(docker_e run --rm --label "$LABEL_KEY=$RUN_ID" "$BUILD_IMAGE" sh -c "$script" 2>/dev/null)
    rm -f "$marker"
    wait "$sampler_pid" 2>/dev/null
    local psys prss
    psys="$(awk -F'\t' 'NR==1{print $1}' "$sampler_out" 2>/dev/null)"
    prss="$(awk -F'\t' 'NR==1{print $2}' "$sampler_out" 2>/dev/null)"
    rm -f "$sampler_out"
    [ -n "$t" ] && samples="$samples $t"
    local d_sys d_rss
    d_sys="$(awk -v p="${psys:-0}" -v b="$base_sys" 'BEGIN { d=p-b; printf "%.0f", d>0?d:0 }')"
    d_rss="$(awk -v p="${prss:-0}" -v b="$base_rss" 'BEGIN { d=p-b; printf "%.0f", d>0?d:0 }')"
    awk -v a="$d_sys" -v b="$peak_sys_max" 'BEGIN { exit !(a+0 > b+0) }' && peak_sys_max="$d_sys"
    awk -v a="$d_rss" -v b="$peak_rss_max" 'BEGIN { exit !(a+0 > b+0) }' && peak_rss_max="$d_rss"
  done
  cleanup_docker_engine
  if [ -z "$samples" ]; then
    record_status FAIL "$engine" "build" "no compile-time samples captured"
    return
  fi
  # shellcheck disable=SC2086
  local med; med="$(median $samples)"
  # shellcheck disable=SC2086
  local build_cv; build_cv="$(cv_pct $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$BUILD_SRC_DIR" "$BUILD_JOBS" "$RUNS" "$med" "$(mb "$peak_sys_max")" "$(mb "$peak_rss_max")" "$(sanitize "$samples")" "$build_cv" >> "$BUILD_TSV"
  record_status PASS "$engine" "build" "median=${med}s over $RUNS run(s), peak_sys=$(mb "$peak_sys_max")MB peak_rss=$(mb "$peak_rss_max")MB$(cv_detail "$build_cv")"
}

metric_build_apple() {
  local engine="$CURRENT_ENGINE"
  if ! ensure_image_apple "$BUILD_IMAGE"; then
    record_status SKIP "$engine" "build" "cannot pull $BUILD_IMAGE"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] apple compile %s (make -j%s) x%s\n' "$BUILD_SRC_DIR" "$BUILD_JOBS" "$RUNS"
    record_status PASS "$engine" "build" "dry-run"
    return
  fi
  local run_i samples="" peak_sys_max=0 peak_rss_max=0 base_sys base_rss script marker sampler_out t line
  script="$(build_workload_script)"
  for run_i in $(seq 1 "$RUNS"); do
    sleep "$SETTLE"
    base_sys="$(used_mem)"
    base_rss="$(process_rss_bytes "$engine")"
    marker="$(mktemp "${TMPDIR:-/tmp}/dorybench-build.XXXXXX")"
    sampler_out="$(mktemp "${TMPDIR:-/tmp}/dorybench-buildmem.XXXXXX")"
    build_memory_sampler "$sampler_out" "$marker" &
    local sampler_pid=$!
    t=""
    while IFS= read -r line; do
      case "$line" in BUILD_SECONDS=*) t="${line#BUILD_SECONDS=}" ;; esac
    done < <("$CONTAINER_BIN" run --rm --name "$PREFIX-build-$RANDOM" "$BUILD_IMAGE" sh -c "$script" 2>/dev/null)
    rm -f "$marker"
    wait "$sampler_pid" 2>/dev/null
    local psys prss
    psys="$(awk -F'\t' 'NR==1{print $1}' "$sampler_out" 2>/dev/null)"
    prss="$(awk -F'\t' 'NR==1{print $2}' "$sampler_out" 2>/dev/null)"
    rm -f "$sampler_out"
    [ -n "$t" ] && samples="$samples $t"
    local d_sys d_rss
    d_sys="$(awk -v p="${psys:-0}" -v b="$base_sys" 'BEGIN { d=p-b; printf "%.0f", d>0?d:0 }')"
    d_rss="$(awk -v p="${prss:-0}" -v b="$base_rss" 'BEGIN { d=p-b; printf "%.0f", d>0?d:0 }')"
    awk -v a="$d_sys" -v b="$peak_sys_max" 'BEGIN { exit !(a+0 > b+0) }' && peak_sys_max="$d_sys"
    awk -v a="$d_rss" -v b="$peak_rss_max" 'BEGIN { exit !(a+0 > b+0) }' && peak_rss_max="$d_rss"
  done
  cleanup_apple_container
  if [ -z "$samples" ]; then
    record_status FAIL "$engine" "build" "no compile-time samples captured"
    return
  fi
  # shellcheck disable=SC2086
  local med; med="$(median $samples)"
  # shellcheck disable=SC2086
  local build_cv; build_cv="$(cv_pct $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$BUILD_SRC_DIR" "$BUILD_JOBS" "$RUNS" "$med" "$(mb "$peak_sys_max")" "$(mb "$peak_rss_max")" "$(sanitize "$samples")" "$build_cv" >> "$BUILD_TSV"
  record_status PASS "$engine" "build" "median=${med}s over $RUNS run(s), peak_sys=$(mb "$peak_sys_max")MB peak_rss=$(mb "$peak_rss_max")MB$(cv_detail "$build_cv")"
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
  local med net_cv
  # shellcheck disable=SC2086
  med="$(median $samples)"
  # shellcheck disable=SC2086
  net_cv="$(cv_pct $samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$IPERF_IMAGE" "$RUNS" "$med" "$(sanitize "$samples")" "$net_cv" >> "$NETWORK_TSV"
  record_status PASS "$engine" "network" "median=${med} Gbps over $RUNS run(s)$(cv_detail "$net_cv")"
}

# --------------------------------------------------------------------------------------------------
# Metric 4: bind-mount filesystem vs in-container filesystem
# --------------------------------------------------------------------------------------------------

# Workload: create FS_FILES tiny files in $target, timed with `time`, wall seconds parsed from stderr.
fs_workload_cmd() {
  printf 'target=%s/bench && rm -rf "$target" && mkdir -p "$target" && for i in $(seq 1 %s); do echo x > "$target/f$i"; done' \
    "$1" "$FS_FILES"
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

timed_real_seconds() {
  local timing status seconds
  timing="$(mktemp "${TMPDIR:-/tmp}/dorybench-time.XXXXXX")" || return 1
  { time "$@" >/dev/null 2>&1; } 2>"$timing"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$timing"
    return "$status"
  fi
  seconds="$(parse_real_seconds < "$timing")"
  rm -f "$timing"
  [ -n "$seconds" ] || return 1
  printf '%s' "$seconds"
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
  timed_real_seconds docker_e run --rm --label "$LABEL_KEY=$RUN_ID" -v "$hostdir:/mnt/work" \
      "$ALPINE_IMAGE" sh -c "$cmd"
}

time_docker_incontainer() {
  local cmd
  cmd="$(fs_workload_cmd /work)"
  timed_real_seconds docker_e run --rm --label "$LABEL_KEY=$RUN_ID" \
      "$ALPINE_IMAGE" sh -c "$cmd"
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
  local bind_cv cont_cv
  # shellcheck disable=SC2086
  bind_cv="$(cv_pct $host_samples)"
  # shellcheck disable=SC2086
  cont_cv="$(cv_pct $cont_samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$FS_FILES" "$RUNS" "$host_med" "$cont_med" "$rat" "$bind_cv" "$cont_cv" >> "$FS_TSV"
  record_status PASS "$engine" "fs" "bind=${host_med}s in-container=${cont_med}s ratio=${rat}x (${FS_FILES} files)$(cv_detail "$bind_cv")"
}

time_apple_host() {
  local hostdir="$1" cmd
  cmd="$(fs_workload_cmd /mnt/work)"
  timed_real_seconds "$CONTAINER_BIN" run --rm --name "$PREFIX-fs-$RANDOM" -v "$hostdir:/mnt/work" \
      "$ALPINE_IMAGE" sh -c "$cmd"
}

time_apple_incontainer() {
  local cmd
  cmd="$(fs_workload_cmd /work)"
  timed_real_seconds "$CONTAINER_BIN" run --rm --name "$PREFIX-fs-$RANDOM" \
      "$ALPINE_IMAGE" sh -c "$cmd"
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
  local bind_cv cont_cv
  # shellcheck disable=SC2086
  bind_cv="$(cv_pct $host_samples)"
  # shellcheck disable=SC2086
  cont_cv="$(cv_pct $cont_samples)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$engine" "$FS_FILES" "$RUNS" "$host_med" "$cont_med" "$rat" "$bind_cv" "$cont_cv" >> "$FS_TSV"
  record_status PASS "$engine" "fs" "bind=${host_med}s in-container=${cont_med}s ratio=${rat}x (${FS_FILES} files)$(cv_detail "$bind_cv")"
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
  if metric_enabled build; then metric_build; else record_status SKIP "$CURRENT_ENGINE" "build" "disabled via --metrics"; fi
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
  if metric_enabled build && [ -s "$BUILD_TSV" ]; then
    echo "COMPILE WORKLOAD ($BUILD_SRC_DIR, make -j$BUILD_JOBS, median of $RUNS)"
    printf '  %-16s %12s %16s %18s\n' "engine" "compile_s" "peak_sys_MB" "peak_engine_rss_MB"
    awk -F'\t' 'NR>1 { printf "  %-16s %12s %16s %18s\n", $1, $5, $6, $7 }' "$BUILD_TSV"
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
    if metric_enabled build && [ -s "$BUILD_TSV" ]; then
      echo ""
      echo "## Compile ($BUILD_SRC_DIR, make -j$BUILD_JOBS)"
      echo ""
      echo '| Engine | Compile seconds | Peak system MB | Peak engine RSS MB | Samples |'
      echo '|---|---:|---:|---:|---|'
      awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %s | `%s` |\n", $1, $5, $6, $7, $8 }' "$BUILD_TSV"
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
  build_json="$(tsv_to_json_array "$BUILD_TSV")"
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
  "build": $build_json,
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
printf 'engine\tcontainers\timage\tsystem_delta_bytes\tsystem_delta_mb\tprocess_delta_bytes\tprocess_delta_mb\tfootprint_base_mb\tfootprint_peak_mb\treclaim_curve\n' > "$MEMORY_TSV"
printf 'engine\timage\truns\tworkload_mib\tmedian_seconds\tsamples_seconds\tcv_pct\n' > "$CPU_TSV"
printf 'engine\tsource\tjobs\truns\tmedian_seconds\tpeak_system_mb\tpeak_engine_rss_mb\tsamples_seconds\tcv_pct\n' > "$BUILD_TSV"
printf 'engine\timage\truns\tmedian_gbps\tsamples_gbps\tcv_pct\n' > "$NETWORK_TSV"
printf 'engine\tfiles\truns\tbind_seconds\tincontainer_seconds\tratio\tbind_cv_pct\tincontainer_cv_pct\n' > "$FS_TSV"
printf 'engine\tlabel\tinterface\tendpoint\tversion\tname\tos_kernel\tarchitecture\tvm_type\tvmm\trosetta\n' > "$ENGINE_VERSIONS_TSV"

trap '{ [ -n "${CURRENT_ENGINE:-}" ] && cleanup_engine; write_summary; } >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

note "benchmark run $RUN_ID"
note "engines: $ENGINES"
note "metrics: $METRICS"
[ "$DRY_RUN" = "1" ] && note "DRY RUN -- no engine commands are executed"
note "results dir: $WORKDIR"

capture_machine_spec

# Engines run sequentially (all of A, then all of B). Each metric already records its coefficient of
# variation (cv_pct column + status detail) and each engine records its VMM/vmType/rosetta profile, so
# run-to-run instability (the OrbStack 0.222<->0.501s / Colima 0.159<->0.917s swings) is now visible and
# attributable without interleaving. True A/B/A/B interleaving (one rep of each metric per engine per
# round, medians aggregated across rounds) needs every metric refactored to defer its median/CV to a
# shared per-round ledger; that lands with a live multi-engine session to validate the aggregation.
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
