#!/usr/bin/env bash
# Compare the real guest -> internet path used by each desktop container engine.
# This is intentionally separate from benchmark-compare.sh's container-to-container fast path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ENGINES_CSV="${BENCH_NET_ENGINES:-dory,orbstack,colima}"
ROUNDS="${BENCH_NET_ROUNDS:-9}"
IMAGE="${BENCH_NET_IMAGE:-}"
PROBE_URL="${BENCH_NET_PROBE_URL:-}"
DOWNLOAD_URL="${BENCH_NET_DOWNLOAD_URL:-}"
DOWNLOAD_BYTES="${BENCH_NET_DOWNLOAD_BYTES:-}"
PROBE_HTTP_CODE="${BENCH_NET_PROBE_HTTP_CODE:-200}"
DOWNLOAD_HTTP_CODE="${BENCH_NET_DOWNLOAD_HTTP_CODE:-200}"
CONNECT_TIMEOUT="${BENCH_NET_CONNECT_TIMEOUT:-10}"
MAX_TIME="${BENCH_NET_MAX_TIME:-60}"
CONTAINER_CPUS="${BENCH_NET_CONTAINER_CPUS:-2}"
CONTAINER_MEMORY="${BENCH_NET_CONTAINER_MEMORY:-512m}"
MEMORY_TOLERANCE_PCT="${BENCH_NET_MEMORY_TOLERANCE_PCT:-5}"
WORK="${BENCH_NET_WORK:-$HOME/.dory-network-bench/$RUN_ID}"
DRY_RUN=0
CLI_ARGS="$*"
WORKLOADS=(handshake download-c1 download-c8 download-c32)

usage() {
  cat <<'EOF'
Usage:
  scripts/benchmark-external-network.sh [options]

Required:
  --image REF              Curl-capable Linux image pinned with @sha256:<64 hex>.
  --probe-url URL          Small HTTPS URL used for DNS/TCP/TLS phase timing.
  --download-url URL       HTTPS URL whose response body has an exact known size.
  --download-bytes N       Exact response bytes expected from --download-url.

Options:
  --engines CSV            dory,orbstack,colima[,docker-desktop] (default: all first three)
  --rounds N               Must be a multiple of the engine count (default: 9)
  --probe-http-code N      Required probe HTTP status (default: 200)
  --download-http-code N   Required download HTTP status (default: 200)
  --connect-timeout SEC    curl connection deadline (default: 10)
  --max-time SEC           curl per-request deadline (default: 60)
  --container-cpus N       Identical per-container CPU limit (default: 2)
  --container-memory SIZE  Identical per-container memory limit (default: 512m)
  --memory-tolerance PCT   Maximum guest-memory spread (default: 5)
  --work DIR               Unique raw-result directory
  --dry-run                Validate arguments and print the balanced schedule only
  -h, --help               Show this help

The image must already exist in every engine. The live benchmark always uses --pull never,
never invokes an engine start/stop/config command, and never mounts a host directory. Payloads
go to /dev/null; per-request curl records use a small guest-local tmpfs. Do not put credentials
or signed secrets in URLs because the exact endpoints are retained in run provenance.
EOF
}

die() { echo "benchmark-external-network: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) [ "$#" -ge 2 ] || die "--engines requires a value"; ENGINES_CSV="$2"; shift 2 ;;
    --rounds) [ "$#" -ge 2 ] || die "--rounds requires a value"; ROUNDS="$2"; shift 2 ;;
    --image) [ "$#" -ge 2 ] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --probe-url) [ "$#" -ge 2 ] || die "--probe-url requires a value"; PROBE_URL="$2"; shift 2 ;;
    --download-url) [ "$#" -ge 2 ] || die "--download-url requires a value"; DOWNLOAD_URL="$2"; shift 2 ;;
    --download-bytes) [ "$#" -ge 2 ] || die "--download-bytes requires a value"; DOWNLOAD_BYTES="$2"; shift 2 ;;
    --probe-http-code) [ "$#" -ge 2 ] || die "--probe-http-code requires a value"; PROBE_HTTP_CODE="$2"; shift 2 ;;
    --download-http-code) [ "$#" -ge 2 ] || die "--download-http-code requires a value"; DOWNLOAD_HTTP_CODE="$2"; shift 2 ;;
    --connect-timeout) [ "$#" -ge 2 ] || die "--connect-timeout requires a value"; CONNECT_TIMEOUT="$2"; shift 2 ;;
    --max-time) [ "$#" -ge 2 ] || die "--max-time requires a value"; MAX_TIME="$2"; shift 2 ;;
    --container-cpus) [ "$#" -ge 2 ] || die "--container-cpus requires a value"; CONTAINER_CPUS="$2"; shift 2 ;;
    --container-memory) [ "$#" -ge 2 ] || die "--container-memory requires a value"; CONTAINER_MEMORY="$2"; shift 2 ;;
    --memory-tolerance) [ "$#" -ge 2 ] || die "--memory-tolerance requires a value"; MEMORY_TOLERANCE_PCT="$2"; shift 2 ;;
    --work) [ "$#" -ge 2 ] || die "--work requires a value"; WORK="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

IFS=',' read -r -a ENGINES <<< "$ENGINES_CSV"
[ "${#ENGINES[@]}" -gt 0 ] || die "at least one engine is required"
VALIDATED_ENGINES=()
for engine in "${ENGINES[@]}"; do
  [ -n "$engine" ] || die "empty engine name"
  case "$engine" in
    dory|orbstack|colima|docker-desktop) ;;
    *) die "unsupported engine: $engine" ;;
  esac
  for seen in "${VALIDATED_ENGINES[@]:-}"; do
    [ "$engine" != "$seen" ] || die "duplicate engine: $engine"
  done
  VALIDATED_ENGINES+=("$engine")
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}
nonnegative_number() {
  awk -v value="$2" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }' || \
    die "$1 must be a non-negative number"
}
positive_number() {
  awk -v value="$2" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' || \
    die "$1 must be a positive number"
}
validate_url() {
  local label="$1" value="$2"
  [ -n "$value" ] || die "$label is required"
  case "$value" in https://*) ;; *) die "$label must be an https:// URL" ;; esac
  case "$value" in *[[:space:]]*) die "$label must not contain whitespace" ;; esac
  case "$value" in *'|'*) die "$label must not contain a literal pipe character" ;; esac
  case "$value" in *'@'*) die "$label must not contain a literal @ or URL userinfo" ;; esac
}

positive_integer "rounds" "$ROUNDS"
[ $((ROUNDS % ${#ENGINES[@]})) -eq 0 ] || \
  die "rounds must be a multiple of the engine count for position balance"
[ -n "$IMAGE" ] || die "--image is required"
case "$IMAGE" in *@sha256:*) ;; *) die "--image must include an immutable @sha256 digest" ;; esac
IMAGE_DIGEST="${IMAGE##*@sha256:}"
[ "${#IMAGE_DIGEST}" -eq 64 ] || die "--image digest must contain exactly 64 hex characters"
case "$IMAGE_DIGEST" in *[!0-9a-fA-F]*) die "--image digest is not hexadecimal" ;; esac
IMAGE_DIGEST="$(printf '%s' "$IMAGE_DIGEST" | tr '[:upper:]' '[:lower:]')"
validate_url "--probe-url" "$PROBE_URL"
validate_url "--download-url" "$DOWNLOAD_URL"
positive_integer "download bytes" "$DOWNLOAD_BYTES"
for code in "$PROBE_HTTP_CODE" "$DOWNLOAD_HTTP_CODE"; do
  case "$code" in [1-5][0-9][0-9]) ;; *) die "HTTP codes must be three digits from 100 through 599" ;; esac
done
positive_number "connect timeout" "$CONNECT_TIMEOUT"
positive_number "max time" "$MAX_TIME"
positive_number "container CPUs" "$CONTAINER_CPUS"
nonnegative_number "memory tolerance" "$MEMORY_TOLERANCE_PCT"
[ -n "$CONTAINER_MEMORY" ] || die "container memory must not be empty"
PLANNED_FIXED_BYTES_PER_ENGINE="$(awk -v rounds="$ROUNDS" -v bytes="$DOWNLOAD_BYTES" \
  'BEGIN { printf "%.0f", rounds * (1 + 8 + 32) * bytes }')"

sock_for() {
  case "$1" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    docker-desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
  esac
}
de() { local engine="$1"; shift; docker -H "unix://$(sock_for "$engine")" "$@"; }
tsv_field() { printf '%s' "${1:-}" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
normal_arch() {
  case "$1" in aarch64) echo arm64 ;; x86_64) echo amd64 ;; *) echo "$1" ;; esac
}
normal_image_variant() {
  local arch="$1" variant="${2:-}"
  [ "$variant" != '<no value>' ] || variant=""
  if [ -n "$variant" ]; then
    printf '%s\n' "$variant"
  elif [ "$arch" = amd64 ]; then
    # OCI descriptors commonly omit a variant for amd64. Keep that absence explicit in provenance.
    printf '%s\n' none
  else
    return 1
  fi
}
valid_rootfs_layers() {
  # Compare the ordered diff-ID list, not Docker's store-dependent image ID. Empty/scratch images are
  # deliberately unsupported here because the curl fixture must contain a userspace and CA bundle.
  printf '%s\n' "$1" | LC_ALL=C grep -Eq \
    '^\["sha256:[0-9a-fA-F]{64}"(,"sha256:[0-9a-fA-F]{64}")*\]$'
}
resolved_requested_repo_digest() {
  local repo_digests="$1" requested_digest="$2"
  printf '%s\n' "$repo_digests" | tr ',' '\n' | awk -F '@' -v wanted="$requested_digest" '
    $NF == wanted { found=1 }
    END { if (!found) exit 1; print wanted }
  '
}

# Start timing after Perl itself is resident. CLOCK_MONOTONIC prevents wall-clock corrections from
# changing a sample. Logs and timing are separate so a failed curl/container remains auditable.
timed_command() {
  local timing_file="$1" log_file="$2"
  shift 2
  rm -f "$timing_file" "$log_file"
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '
    use strict;
    use warnings;
    my ($timing, $log, @command) = @ARGV;
    open STDOUT, ">", $log or die "open $log: $!\n";
    open STDERR, ">&", STDOUT or die "dup stderr: $!\n";
    my $start = clock_gettime(CLOCK_MONOTONIC);
    my $status = system { $command[0] } @command;
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    open my $out, ">", $timing or die "open $timing: $!\n";
    printf {$out} "%.6f\n", $elapsed;
    close $out or die "close $timing: $!\n";
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit($status >> 8);
  ' "$timing_file" "$log_file" "$@"
}
timing_seconds() {
  awk 'NR == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { value=$1; ok=1 }
       END { if (!ok || NR != 1) exit 1; printf "%.6f\n", value }' "$1"
}

print_schedule() {
  local round slot workload_index workload engine_index position
  printf 'round\tworkload\tposition\tengine\tconcurrency\n'
  round=1
  while [ "$round" -le "$ROUNDS" ]; do
    slot=0
    while [ "$slot" -lt "${#WORKLOADS[@]}" ]; do
      workload_index=$(((round - 1 + slot) % ${#WORKLOADS[@]}))
      workload="${WORKLOADS[$workload_index]}"
      position=1
      while [ "$position" -le "${#ENGINES[@]}" ]; do
        engine_index=$(((round - 1 + workload_index + position - 1) % ${#ENGINES[@]}))
        case "$workload" in
          handshake) concurrency=1 ;;
          download-c1) concurrency=1 ;;
          download-c8) concurrency=8 ;;
          download-c32) concurrency=32 ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$round" "$workload" "$position" \
          "${ENGINES[$engine_index]}" "$concurrency"
        position=$((position + 1))
      done
      slot=$((slot + 1))
    done
    round=$((round + 1))
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run only: no engine, Docker API, image, or network endpoint was accessed" >&2
  echo "image=$IMAGE" >&2
  echo "probe_url=$PROBE_URL" >&2
  echo "download_url=$DOWNLOAD_URL expected_bytes=$DOWNLOAD_BYTES" >&2
  echo "planned_fixed_download_bytes_per_engine=$PLANNED_FIXED_BYTES_PER_ENGINE" >&2
  print_schedule
  exit 0
fi

[ ! -e "$WORK" ] || die "result path already exists; choose a fresh --work directory: $WORK"
mkdir -p "$WORK/logs"
MANIFEST="$WORK/run-manifest.tsv"
ENGINE_PROVENANCE="$WORK/engine-provenance.tsv"
IMAGE_PROVENANCE="$WORK/image-provenance.tsv"
SAMPLES="$WORK/samples.tsv"
CURL_RAW="$WORK/curl-raw.tsv"
METRICS="$WORK/metrics.tsv"
RUN_STATUS="$WORK/run-status.tsv"
RUN_STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_FINALIZED=0
CURRENT_ENGINE=""
CURRENT_CONTAINER=""

write_terminal_status() {
  local status="$1" reason="$2" cleanup_status="$3" exit_code="$4"
  {
    printf 'key\tvalue\n'
    printf 'started_utc\t%s\n' "$RUN_STARTED_UTC"
    printf 'finished_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status\t%s\n' "$status"
    printf 'reason\t%s\n' "$(tsv_field "$reason")"
    printf 'exit_code\t%s\n' "$exit_code"
    printf 'cleanup\t%s\n' "$(tsv_field "$cleanup_status")"
    printf 'result_root\t%s\n' "$(tsv_field "$WORK")"
  } > "$RUN_STATUS.tmp.$$"
  mv "$RUN_STATUS.tmp.$$" "$RUN_STATUS"
}

finish_on_exit() {
  local exit_code=$? cleanup_status=not_needed reason terminal_status=fail
  trap - EXIT INT TERM
  set +e
  if [ -n "$CURRENT_ENGINE" ] && [ -n "$CURRENT_CONTAINER" ]; then
    if docker -H "unix://$(sock_for "$CURRENT_ENGINE")" rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1; then
      cleanup_status=removed_current_benchmark_container
    else
      cleanup_status=benchmark_container_not_found_or_cleanup_failed
    fi
  fi
  if [ "$RUN_FINALIZED" -ne 1 ]; then
    case "$exit_code" in
      130) reason=interrupted_sigint; terminal_status=interrupted ;;
      143) reason=interrupted_sigterm; terminal_status=interrupted ;;
      *) reason="unexpected_exit_$exit_code" ;;
    esac
    write_terminal_status "$terminal_status" "$reason" "$cleanup_status" "$exit_code" || true
  fi
  exit "$exit_code"
}

printf 'key\tvalue\nstarted_utc\t%s\nstatus\trunning\n' "$RUN_STARTED_UTC" > "$RUN_STATUS"
trap 'exit 130' INT
trap 'exit 143' TERM
trap finish_on_exit EXIT

{
  printf 'key\tvalue\n'
  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'started_utc\t%s\n' "$RUN_STARTED_UTC"
  printf 'repo_root\t%s\n' "$(tsv_field "$REPO_ROOT")"
  printf 'result_root\t%s\n' "$(tsv_field "$WORK")"
  printf 'cli_args\t%s\n' "$(tsv_field "$CLI_ARGS")"
  printf 'git_head\t%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'git_worktree\t%s\n' "$([ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ] && echo dirty || echo clean)"
  printf 'git_diff_sha256\t%s\n' "$(git -C "$REPO_ROOT" diff HEAD --binary 2>/dev/null | shasum -a 256 | awk '{print $1}' || echo unknown)"
  printf 'script_sha256\t%s\n' "$(shasum -a 256 "$REPO_ROOT/scripts/benchmark-external-network.sh" | awk '{print $1}')"
  printf 'engines\t%s\n' "$(tsv_field "$ENGINES_CSV")"
  printf 'rounds\t%s\n' "$ROUNDS"
  printf 'image\t%s\n' "$(tsv_field "$IMAGE")"
  printf 'image_digest\tsha256:%s\n' "$IMAGE_DIGEST"
  printf 'probe_url\t%s\n' "$(tsv_field "$PROBE_URL")"
  printf 'probe_http_code\t%s\n' "$PROBE_HTTP_CODE"
  printf 'download_url\t%s\n' "$(tsv_field "$DOWNLOAD_URL")"
  printf 'download_http_code\t%s\n' "$DOWNLOAD_HTTP_CODE"
  printf 'download_bytes\t%s\n' "$DOWNLOAD_BYTES"
  printf 'planned_fixed_download_bytes_per_engine\t%s\n' "$PLANNED_FIXED_BYTES_PER_ENGINE"
  printf 'concurrency\t1,8,32\n'
  printf 'connect_timeout_seconds\t%s\n' "$CONNECT_TIMEOUT"
  printf 'max_time_seconds\t%s\n' "$MAX_TIME"
  printf 'container_cpus\t%s\n' "$CONTAINER_CPUS"
  printf 'container_memory\t%s\n' "$(tsv_field "$CONTAINER_MEMORY")"
  printf 'engine_memory_tolerance_pct\t%s\n' "$MEMORY_TOLERANCE_PCT"
  printf 'container_network\tbridge\n'
  printf 'proxy_policy\tdisabled; direct guest network path only\n'
  printf 'payload_destination\t/dev/null\n'
  printf 'metadata_destination\tguest-local /tmp tmpfs (16 MiB)\n'
  printf 'image_pull_policy\tnever\n'
  printf 'host_timer\tPerl Time::HiRes CLOCK_MONOTONIC around docker run\n'
  printf 'phase_method\tcurl time_namelookup; time_connect-name; time_appconnect-connect\n'
  printf 'docker_client_version\t%s\n' "$(tsv_field "$(docker --version 2>/dev/null || echo unknown)")"
  printf 'macos_version\t%s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  printf 'macos_build\t%s\n' "$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  printf 'hw_model\t%s\n' "$(sysctl -n hw.model 2>/dev/null || echo unknown)"
  printf 'hw_ncpu\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
  printf 'hw_memsize_bytes\t%s\n' "$(sysctl -n hw.memsize 2>/dev/null || echo unknown)"
  printf 'uname\t%s\n' "$(tsv_field "$(uname -mrs 2>/dev/null || echo unknown)")"
} > "$MANIFEST"

printf 'engine\tstatus\tsocket\tserver_version\tos\tkernel\tarch\tncpu\tmemory_bytes\tbridge_driver\tbridge_ipv6\n' > "$ENGINE_PROVENANCE"
printf 'engine\trequested_ref\tresolved_repo_digest\timage_id\trepo_digests\tos\tarch\tvariant\tcreated\trootfs_layers\trootfs_fingerprint_sha256\n' > "$IMAGE_PROVENANCE"

BASE_ARCH=""
BASE_CPUS=""
BASE_IMAGE_REPO_DIGEST=""
BASE_IMAGE_OS=""
BASE_IMAGE_ARCH=""
BASE_IMAGE_VARIANT=""
BASE_IMAGE_ROOTFS_FINGERPRINT=""
MIN_MEMORY=""
MAX_MEMORY=""
for engine in "${ENGINES[@]}"; do
  socket="$(sock_for "$engine")"
  [ -S "$socket" ] || die "$engine socket is not ready: $socket (the harness does not start engines)"
  de "$engine" version >/dev/null 2>&1 || die "$engine Docker API is not ready (the harness does not start engines)"
  server="$(de "$engine" version --format '{{.Server.Version}}' 2>/dev/null)"
  os_name="$(de "$engine" info --format '{{.OperatingSystem}}' 2>/dev/null)"
  kernel="$(de "$engine" info --format '{{.KernelVersion}}' 2>/dev/null)"
  arch="$(normal_arch "$(de "$engine" info --format '{{.Architecture}}' 2>/dev/null)")"
  cpus="$(de "$engine" info --format '{{.NCPU}}' 2>/dev/null)"
  memory="$(de "$engine" info --format '{{.MemTotal}}' 2>/dev/null)"
  case "$cpus" in ''|*[!0-9]*) die "$engine returned an invalid CPU count: $cpus" ;; esac
  case "$memory" in ''|*[!0-9]*) die "$engine returned an invalid memory total: $memory" ;; esac
  [ "$cpus" -gt 0 ] || die "$engine returned a non-positive CPU count: $cpus"
  [ "$memory" -gt 0 ] || die "$engine returned a non-positive memory total: $memory"
  bridge_driver="$(de "$engine" network inspect bridge --format '{{.Driver}}' 2>/dev/null)" || \
    die "$engine has no inspectable bridge network"
  [ "$bridge_driver" = "bridge" ] || die "$engine's bridge network uses unexpected driver: $bridge_driver"
  bridge_ipv6="$(de "$engine" network inspect bridge --format '{{.EnableIPv6}}' 2>/dev/null || echo unknown)"
  printf '%s\tready\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$(tsv_field "$socket")" "$(tsv_field "$server")" "$(tsv_field "$os_name")" \
    "$(tsv_field "$kernel")" "$arch" "$cpus" "$memory" "$bridge_driver" "$bridge_ipv6" \
    >> "$ENGINE_PROVENANCE"

  [ -z "$BASE_ARCH" ] && BASE_ARCH="$arch"
  [ "$arch" = "$BASE_ARCH" ] || die "architecture mismatch: $engine=$arch, expected $BASE_ARCH"
  [ -z "$BASE_CPUS" ] && BASE_CPUS="$cpus"
  [ "$cpus" = "$BASE_CPUS" ] || die "CPU-count mismatch: $engine=$cpus, expected $BASE_CPUS"
  [ -z "$MIN_MEMORY" ] || [ "$memory" -ge "$MIN_MEMORY" ] || MIN_MEMORY="$memory"
  [ -n "$MIN_MEMORY" ] || MIN_MEMORY="$memory"
  [ -z "$MAX_MEMORY" ] || [ "$memory" -le "$MAX_MEMORY" ] || MAX_MEMORY="$memory"
  [ -n "$MAX_MEMORY" ] || MAX_MEMORY="$memory"

  image_id="$(de "$engine" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine does not already contain $IMAGE (--pull never is mandatory)"
  repo_digests="$(de "$engine" image inspect --format '{{join .RepoDigests ","}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine image digest metadata is unreadable"
  image_os="$(de "$engine" image inspect --format '{{.Os}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine image OS metadata is unreadable"
  image_arch="$(de "$engine" image inspect --format '{{.Architecture}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine image architecture metadata is unreadable"
  image_variant_raw="$(de "$engine" image inspect --format '{{.Variant}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine image variant metadata is unreadable"
  image_created="$(de "$engine" image inspect --format '{{.Created}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine image creation metadata is unreadable"
  rootfs_layers="$(de "$engine" image inspect --format '{{json .RootFS.Layers}}' "$IMAGE" 2>/dev/null)" || \
    die "$engine ordered RootFS layer metadata is unreadable"
  [ "$image_os" = "linux" ] || die "$engine image OS is $image_os, expected linux"

  # Image metadata alone cannot prove that the selected platform snapshot was materialized. A
  # corrupt/empty snapshot or unresolved named Config.User otherwise exits almost instantly and can
  # look like a spectacular network result. Exercise the configured entrypoint and user without a
  # network before collecting any timed samples.
  de "$engine" run --rm --pull never --network none "$IMAGE" --version >/dev/null 2>&1 || \
    die "$engine cannot execute the benchmark image under its configured user"

  image_arch="$(normal_arch "$image_arch")"
  [ "$image_arch" = "$BASE_ARCH" ] || die "$engine image arch is $image_arch, engine arch is $BASE_ARCH"
  image_variant="$(normal_image_variant "$image_arch" "$image_variant_raw")" || \
    die "$engine image variant is missing for architecture $image_arch"
  resolved_repo_digest="$(resolved_requested_repo_digest "$repo_digests" "sha256:$IMAGE_DIGEST")" || \
    die "$engine image metadata does not retain the exact requested RepoDigest"
  valid_rootfs_layers "$rootfs_layers" || \
    die "$engine image has missing or malformed ordered RootFS layer metadata"
  rootfs_fingerprint="$(printf '%s' "$rootfs_layers" | shasum -a 256 | awk '{print $1}')"
  [ -n "$rootfs_fingerprint" ] || die "$engine RootFS fingerprint is missing"

  if [ -z "$BASE_IMAGE_REPO_DIGEST" ]; then
    BASE_IMAGE_REPO_DIGEST="$resolved_repo_digest"
    BASE_IMAGE_OS="$image_os"
    BASE_IMAGE_ARCH="$image_arch"
    BASE_IMAGE_VARIANT="$image_variant"
    BASE_IMAGE_ROOTFS_FINGERPRINT="$rootfs_fingerprint"
  else
    [ "$resolved_repo_digest" = "$BASE_IMAGE_REPO_DIGEST" ] || \
      die "resolved RepoDigest mismatch: $engine=$resolved_repo_digest, expected $BASE_IMAGE_REPO_DIGEST"
    [ "$image_os" = "$BASE_IMAGE_OS" ] && [ "$image_arch" = "$BASE_IMAGE_ARCH" ] && \
      [ "$image_variant" = "$BASE_IMAGE_VARIANT" ] || \
      die "resolved image-platform mismatch: $engine=$image_os/$image_arch/$image_variant, expected $BASE_IMAGE_OS/$BASE_IMAGE_ARCH/$BASE_IMAGE_VARIANT"
    [ "$rootfs_fingerprint" = "$BASE_IMAGE_ROOTFS_FINGERPRINT" ] || \
      die "ordered RootFS layer mismatch: $engine=$rootfs_fingerprint, expected $BASE_IMAGE_ROOTFS_FINGERPRINT"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$(tsv_field "$IMAGE")" "$resolved_repo_digest" "$image_id" \
    "$(tsv_field "$repo_digests")" "$image_os" "$image_arch" "$image_variant" \
    "$(tsv_field "$image_created")" "$(tsv_field "$rootfs_layers")" "$rootfs_fingerprint" \
    >> "$IMAGE_PROVENANCE"
done

awk -v min="$MIN_MEMORY" -v max="$MAX_MEMORY" -v tolerance="$MEMORY_TOLERANCE_PCT" \
  'BEGIN { spread=(max-min)*100/min; exit !(spread <= tolerance + 0.0000001) }' || \
  die "guest-memory spread exceeds ${MEMORY_TOLERANCE_PCT}%: min=$MIN_MEMORY max=$MAX_MEMORY"

printf 'round\tworkload\tposition\tengine\tconcurrency\thost_seconds\tcontainer_exit\texpected_rows\tobserved_rows\tvalid_rows\toutcome\tlog\n' > "$SAMPLES"
printf 'round\tworkload\tposition\tengine\tconcurrency\thost_seconds\tcontainer_exit\trequest_index\tcurl_exit\tvalidation\tfailure\tcurl_stderr\turl_effective\tremote_ip\thttp_code\thttp_version\tnum_connects\tsize_download\tspeed_download_bytes_per_second\ttime_namelookup\ttime_connect\ttime_appconnect\ttime_pretransfer\ttime_starttransfer\ttime_total\tssl_verify_result\n' > "$CURL_RAW"
printf 'round\tworkload\tposition\tengine\tconcurrency\tmetric\trequest_index\tvalue\tunit\tsource\n' > "$METRICS"

# Every curl writes its metadata to a distinct tmpfs file. Payload bytes are always discarded.
# The CURL-prefixed lines are a transport format consumed verbatim by the host-side recorder.
GUEST_SCRIPT='
set -u
kind=$1
url=$2
expected_bytes=$3
expected_code=$4
count=$5
connect_timeout=$6
max_time=$7
format="%{url_effective}|%{remote_ip}|%{http_code}|%{http_version}|%{num_connects}|%{size_download}|%{speed_download}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{ssl_verify_result}\n"
run_one() {
  index=$1
  raw=/tmp/dory-net-raw.$index
  error=/tmp/dory-net-error.$index
  rc_file=/tmp/dory-net-rc.$index
  validation_file=/tmp/dory-net-validation.$index
  curl --disable --silent --show-error --globoff --no-keepalive --noproxy "*" \
    --output /dev/null --proto "=https" \
    --connect-timeout "$connect_timeout" --max-time "$max_time" --write-out "$format" \
    "$url" >"$raw" 2>"$error"
  curl_rc=$?
  url_effective=- remote_ip=- http_code=- http_version=- num_connects=- size_download=-
  speed_download=- time_namelookup=- time_connect=- time_appconnect=- time_pretransfer=-
  time_starttransfer=- time_total=- ssl_verify_result=-
  IFS="|" read -r url_effective remote_ip http_code http_version num_connects size_download \
    speed_download time_namelookup time_connect time_appconnect time_pretransfer \
    time_starttransfer time_total ssl_verify_result <"$raw" || true
  validation=pass
  failure=-
  if [ "$curl_rc" -ne 0 ]; then validation=fail; failure=curl_exit; fi
  if [ "$http_code" != "$expected_code" ]; then validation=fail; failure=http_code; fi
  if ! awk -v n="$time_namelookup" -v c="$time_connect" -v a="$time_appconnect" \
      -v t="$time_total" \
      "BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && c >= n && a >= c && a > 0 && t >= a && t > 0) }"; then
    validation=fail; failure=invalid_phase_timing
  fi
  if [ "$kind" = download ] && ! awk -v got="$size_download" -v want="$expected_bytes" \
      "BEGIN { exit !(got ~ /^[0-9]+([.][0-9]+)?$/ && got == want) }"; then
    validation=fail; failure=byte_count
  fi
  stderr_text=$(tr "\t\r\n" "   " <"$error" | sed "s/  */ /g; s/^ //; s/ $//")
  [ -n "$stderr_text" ] || stderr_text=-
  printf "%s\n" "$curl_rc" >"$rc_file"
  printf "%s\n" "$validation" >"$validation_file"
  printf "CURL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$index" "$curl_rc" "$validation" "$failure" "$stderr_text" "$url_effective" \
    "$remote_ip" "$http_code" "$http_version" "$num_connects" "$size_download" \
    "$speed_download" "$time_namelookup" "$time_connect" "$time_appconnect" \
    "$time_pretransfer" "$time_starttransfer" "$time_total" "$ssl_verify_result" \
    >"/tmp/dory-net-row.$index"
  return 0
}
i=1
pids=""
while [ "$i" -le "$count" ]; do
  run_one "$i" &
  pids="$pids $!"
  i=$((i + 1))
done
for pid in $pids; do wait "$pid" || true; done
overall=0
i=1
while [ "$i" -le "$count" ]; do
  cat "/tmp/dory-net-row.$i"
  [ "$(cat "/tmp/dory-net-rc.$i")" -eq 0 ] || overall=1
  [ "$(cat "/tmp/dory-net-validation.$i")" = pass ] || overall=1
  i=$((i + 1))
done
exit "$overall"
'

OVERALL=pass
round=1
while [ "$round" -le "$ROUNDS" ]; do
  slot=0
  while [ "$slot" -lt "${#WORKLOADS[@]}" ]; do
    workload_index=$(((round - 1 + slot) % ${#WORKLOADS[@]}))
    workload="${WORKLOADS[$workload_index]}"
    case "$workload" in
      handshake) kind=handshake; url="$PROBE_URL"; expected_bytes=0; expected_code="$PROBE_HTTP_CODE"; concurrency=1 ;;
      download-c1) kind=download; url="$DOWNLOAD_URL"; expected_bytes="$DOWNLOAD_BYTES"; expected_code="$DOWNLOAD_HTTP_CODE"; concurrency=1 ;;
      download-c8) kind=download; url="$DOWNLOAD_URL"; expected_bytes="$DOWNLOAD_BYTES"; expected_code="$DOWNLOAD_HTTP_CODE"; concurrency=8 ;;
      download-c32) kind=download; url="$DOWNLOAD_URL"; expected_bytes="$DOWNLOAD_BYTES"; expected_code="$DOWNLOAD_HTTP_CODE"; concurrency=32 ;;
    esac
    position=1
    while [ "$position" -le "${#ENGINES[@]}" ]; do
      engine_index=$(((round - 1 + workload_index + position - 1) % ${#ENGINES[@]}))
      engine="${ENGINES[$engine_index]}"
      sample="r${round}-${workload}-p${position}-${engine}"
      log="$WORK/logs/$sample.log"
      timing="$WORK/logs/$sample.seconds"
      container_name="dory-net-${RUN_ID}-${sample}"
      container_name="$(printf '%s' "$container_name" | tr '[:upper:]' '[:lower:]')"
      CURRENT_ENGINE="$engine"
      CURRENT_CONTAINER="$container_name"
      set +e
      timed_command "$timing" "$log" docker -H "unix://$(sock_for "$engine")" run \
        --name "$container_name" --rm --pull never --network bridge --read-only \
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m --cpus "$CONTAINER_CPUS" \
        --memory "$CONTAINER_MEMORY" --env http_proxy= --env https_proxy= --env all_proxy= \
        --env HTTP_PROXY= --env HTTPS_PROXY= --env ALL_PROXY= \
        --env no_proxy='*' --env NO_PROXY='*' \
        --entrypoint /bin/sh "$IMAGE" -c "$GUEST_SCRIPT" -- \
        "$kind" "$url" "$expected_bytes" "$expected_code" "$concurrency" \
        "$CONNECT_TIMEOUT" "$MAX_TIME"
      container_exit=$?
      if [ "$container_exit" -ne 0 ]; then
        docker -H "unix://$(sock_for "$engine")" rm -f "$container_name" >/dev/null 2>&1 || true
      fi
      CURRENT_ENGINE=""
      CURRENT_CONTAINER=""
      set -e
      host_seconds="$(timing_seconds "$timing" 2>/dev/null || echo -)"
      observed_rows="$(awk -F '\t' '$1 == "CURL" { count++ } END { print count + 0 }' "$log")"
      valid_rows="$(awk -F '\t' '$1 == "CURL" && $4 == "pass" { count++ } END { print count + 0 }' "$log")"
      outcome=pass
      if [ "$container_exit" -ne 0 ] || [ "$observed_rows" -ne "$concurrency" ] || \
         [ "$valid_rows" -ne "$concurrency" ] || [ "$host_seconds" = - ]; then
        outcome=fail
        OVERALL=fail
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$round" "$workload" "$position" "$engine" "$concurrency" "$host_seconds" \
        "$container_exit" "$concurrency" "$observed_rows" "$valid_rows" "$outcome" \
        "$(tsv_field "$log")" >> "$SAMPLES"
      awk -F '\t' -v OFS='\t' -v round="$round" -v workload="$workload" \
        -v position="$position" -v engine="$engine" -v concurrency="$concurrency" \
        -v host="$host_seconds" -v exit_code="$container_exit" '$1 == "CURL" {
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s", round, workload, position, engine, concurrency, host, exit_code
          for (i = 2; i <= NF; i++) printf "\t%s", $i
          printf "\n"
        }' "$log" >> "$CURL_RAW"
      if [ "$outcome" = pass ]; then
        awk -F '\t' -v OFS='\t' -v round="$round" -v workload="$workload" \
          -v position="$position" -v engine="$engine" -v concurrency="$concurrency" \
          '$1 == "CURL" && $4 == "pass" {
            if (workload == "handshake") {
              print round, workload, position, engine, concurrency, "dns", $2, $14, "seconds", "curl_time_namelookup"
              print round, workload, position, engine, concurrency, "tcp", $2, $15-$14, "seconds", "curl_time_connect_minus_namelookup"
              print round, workload, position, engine, concurrency, "tls", $2, $16-$15, "seconds", "curl_time_appconnect_minus_connect"
            } else {
              print round, workload, position, engine, concurrency, "https_request", $2, $19, "seconds", "curl_time_total"
              print round, workload, position, engine, concurrency, "https_request_rate", $2, ($12*8/$19/1000000), "Mbit/s", "verified_bytes_over_curl_time_total"
            }
          }' "$log" >> "$METRICS"
        if [ "$kind" = download ]; then
          aggregate_mbps="$(awk -v bytes="$DOWNLOAD_BYTES" -v count="$concurrency" -v elapsed="$host_seconds" \
            'BEGIN { printf "%.6f", bytes * count * 8 / elapsed / 1000000 }')"
          printf '%s\t%s\t%s\t%s\t%s\tbatch_host_wall\t-\t%s\tseconds\tCLOCK_MONOTONIC_around_docker_run\n' \
            "$round" "$workload" "$position" "$engine" "$concurrency" "$host_seconds" >> "$METRICS"
          printf '%s\t%s\t%s\t%s\t%s\tbatch_effective_rate\t-\t%s\tMbit/s\tverified_bytes_over_host_wall\n' \
            "$round" "$workload" "$position" "$engine" "$concurrency" "$aggregate_mbps" >> "$METRICS"
        fi
      fi
      position=$((position + 1))
    done
    slot=$((slot + 1))
  done
  round=$((round + 1))
done

write_terminal_status "$OVERALL" completed not_needed "$([ "$OVERALL" = pass ] && echo 0 || echo 1)"
RUN_FINALIZED=1

echo "external-network benchmark: $OVERALL ($WORK)"
[ "$OVERALL" = pass ]
