#!/usr/bin/env bash
# Compare the cold-registry npm workflow inside engine-local storage. This intentionally excludes
# bind mounts: benchmark-user-workflows.sh owns host-share performance, while this harness isolates
# DNS/TCP/TLS, registry transfer, Docker bridge networking, and guest-local package extraction.
set -euo pipefail

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ENGINES_CSV="${BENCH_REGISTRY_ENGINES:-dory,colima}"
ROUNDS="${BENCH_REGISTRY_ROUNDS:-6}"
IMAGE="${BENCH_REGISTRY_IMAGE:-}"
FIXTURE="${BENCH_REGISTRY_FIXTURE:-}"
CONTAINER_CPUS="${BENCH_REGISTRY_CONTAINER_CPUS:-2}"
CONTAINER_MEMORY="${BENCH_REGISTRY_CONTAINER_MEMORY:-1800m}"
WORK="${BENCH_REGISTRY_WORK:-$PWD/.codex-bench/registry-npm-$RUN_ID}"
DRY_RUN=0
CURRENT_ENGINE=""
CURRENT_CONTAINER=""

usage() {
  cat <<'EOF'
Usage:
  scripts/benchmark-registry-npm.sh --image REF --fixture DIR [options]

Required:
  --image REF       Node image pinned with @sha256:<64 hex>; it must already exist in every engine.
  --fixture DIR     Directory containing package.json and package-lock.json.

Options:
  --engines CSV     dory,orbstack,colima[,docker-desktop] (default: dory,colima)
  --rounds N        Multiple of engine count (default: 6)
  --cpus N          Identical per-container CPU limit (default: 2)
  --memory SIZE     Identical per-container memory limit (default: 1800m)
  --work DIR        Fresh raw-result directory
  --dry-run         Validate static inputs and print the balanced schedule only
  -h, --help        Show this help

Each sample gets a new container and therefore a fresh npm cache. The fixture is copied into the
container's local writable layer before timing. The harness uses --pull never and never starts,
stops, or reconfigures an engine.
EOF
}

die() { echo "benchmark-registry-npm: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) [ "$#" -ge 2 ] || die "--engines requires a value"; ENGINES_CSV="$2"; shift 2 ;;
    --rounds) [ "$#" -ge 2 ] || die "--rounds requires a value"; ROUNDS="$2"; shift 2 ;;
    --image) [ "$#" -ge 2 ] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --fixture) [ "$#" -ge 2 ] || die "--fixture requires a value"; FIXTURE="$2"; shift 2 ;;
    --cpus) [ "$#" -ge 2 ] || die "--cpus requires a value"; CONTAINER_CPUS="$2"; shift 2 ;;
    --memory) [ "$#" -ge 2 ] || die "--memory requires a value"; CONTAINER_MEMORY="$2"; shift 2 ;;
    --work) [ "$#" -ge 2 ] || die "--work requires a value"; WORK="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$ROUNDS" in ''|*[!0-9]*) die "rounds must be a positive integer" ;; esac
[ "$ROUNDS" -gt 0 ] || die "rounds must be a positive integer"
awk -v value="$CONTAINER_CPUS" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' || \
  die "cpus must be a positive number"
[ -n "$CONTAINER_MEMORY" ] || die "memory must not be empty"
[ -n "$IMAGE" ] || die "--image is required"
case "$IMAGE" in *@sha256:*) ;; *) die "--image must include an immutable @sha256 digest" ;; esac
IMAGE_DIGEST="${IMAGE##*@sha256:}"
[ "${#IMAGE_DIGEST}" -eq 64 ] || die "image digest must contain 64 hex characters"
case "$IMAGE_DIGEST" in *[!0-9a-fA-F]*) die "image digest is not hexadecimal" ;; esac
[ -d "$FIXTURE" ] || die "fixture directory does not exist: $FIXTURE"
[ -f "$FIXTURE/package.json" ] || die "fixture is missing package.json"
[ -f "$FIXTURE/package-lock.json" ] || die "fixture is missing package-lock.json"

IFS=',' read -r -a ENGINES <<< "$ENGINES_CSV"
[ "${#ENGINES[@]}" -gt 0 ] || die "at least one engine is required"
VALIDATED=()
for engine in "${ENGINES[@]}"; do
  case "$engine" in dory|orbstack|colima|docker-desktop) ;; *) die "unsupported engine: $engine" ;; esac
  for seen in "${VALIDATED[@]:-}"; do [ "$engine" != "$seen" ] || die "duplicate engine: $engine"; done
  VALIDATED+=("$engine")
done
[ $((ROUNDS % ${#ENGINES[@]})) -eq 0 ] || die "rounds must be a multiple of engine count"

sock_for() {
  case "$1" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    docker-desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
  esac
}
de() { local engine="$1"; shift; docker -H "unix://$(sock_for "$engine")" "$@"; }

print_schedule() {
  local round position engine_index
  printf 'round\tposition\tengine\n'
  for ((round = 1; round <= ROUNDS; round++)); do
    for ((position = 1; position <= ${#ENGINES[@]}; position++)); do
      engine_index=$(((round - 1 + position - 1) % ${#ENGINES[@]}))
      printf '%s\t%s\t%s\n' "$round" "$position" "${ENGINES[$engine_index]}"
    done
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run only: no engine, image, container, or network endpoint was accessed" >&2
  print_schedule
  exit 0
fi

[ ! -e "$WORK" ] || die "result path already exists: $WORK"
mkdir -p "$WORK/logs"
MANIFEST="$WORK/run-manifest.tsv"
PROVENANCE="$WORK/engine-provenance.tsv"
SAMPLES="$WORK/samples.tsv"
STATUS="$WORK/run-status.tsv"

cleanup_current() {
  if [ -n "$CURRENT_ENGINE" ] && [ -n "$CURRENT_CONTAINER" ]; then
    de "$CURRENT_ENGINE" rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
  fi
  CURRENT_ENGINE=""
  CURRENT_CONTAINER=""
}
trap cleanup_current EXIT INT TERM

timed_command() {
  local timing_file="$1" log_file="$2"
  shift 2
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
    close $out;
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit($status >> 8);
  ' "$timing_file" "$log_file" "$@"
}

printf 'key\tvalue\n' > "$MANIFEST"
printf 'run_id\t%s\n' "$RUN_ID" >> "$MANIFEST"
printf 'started_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST"
printf 'engines\t%s\n' "$ENGINES_CSV" >> "$MANIFEST"
printf 'rounds\t%s\n' "$ROUNDS" >> "$MANIFEST"
printf 'image\t%s\n' "$IMAGE" >> "$MANIFEST"
printf 'fixture\t%s\n' "$FIXTURE" >> "$MANIFEST"
printf 'package_lock_sha256\t%s\n' "$(shasum -a 256 "$FIXTURE/package-lock.json" | awk '{print $1}')" >> "$MANIFEST"
printf 'container_cpus\t%s\n' "$CONTAINER_CPUS" >> "$MANIFEST"
printf 'container_memory\t%s\n' "$CONTAINER_MEMORY" >> "$MANIFEST"

printf 'engine\tserver_version\tarch\tncpu\tmemory_bytes\timage_id\trepo_digests\timage_os\timage_arch\timage_variant\trootfs_layers\n' > "$PROVENANCE"
for engine in "${ENGINES[@]}"; do
  [ -S "$(sock_for "$engine")" ] || die "$engine socket is absent"
  de "$engine" version >/dev/null 2>&1 || die "$engine Docker API is unavailable"
  de "$engine" network inspect bridge >/dev/null 2>&1 || die "$engine bridge network is unavailable"
  repo_digests="$(de "$engine" image inspect "$IMAGE" --format '{{json .RepoDigests}}' 2>/dev/null)" || \
    die "$engine does not already contain $IMAGE"
  case "$repo_digests" in *"sha256:$IMAGE_DIGEST"*) ;; *) die "$engine image digest does not match request" ;; esac
  image_os="$(de "$engine" image inspect "$IMAGE" --format '{{.Os}}')"
  image_arch="$(de "$engine" image inspect "$IMAGE" --format '{{.Architecture}}')"
  image_variant="$(de "$engine" image inspect "$IMAGE" --format '{{.Variant}}')"
  rootfs_layers="$(de "$engine" image inspect "$IMAGE" --format '{{json .RootFS.Layers}}')"
  [ -n "$image_os" ] && [ -n "$image_arch" ] || die "$engine image platform metadata is incomplete"
  case "$rootfs_layers" in \[*\]) ;; *) die "$engine ordered RootFS layer metadata is malformed" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" \
    "$(de "$engine" version --format '{{.Server.Version}}')" \
    "$(de "$engine" version --format '{{.Server.Arch}}')" \
    "$(de "$engine" info --format '{{.NCPU}}')" \
    "$(de "$engine" info --format '{{.MemTotal}}')" \
    "$(de "$engine" image inspect "$IMAGE" --format '{{.Id}}')" \
    "$repo_digests" \
    "$image_os" \
    "$image_arch" \
    "$image_variant" \
    "$rootfs_layers" >> "$PROVENANCE"
done

if [ "$(awk -F '\t' 'NR > 1 { print $3 }' "$PROVENANCE" | sort -u | wc -l | tr -d ' ')" -ne 1 ]; then
  die "engine architectures differ"
fi
if [ "$(awk -F '\t' 'NR > 1 { print $8 FS $9 FS $10 FS $11 }' "$PROVENANCE" | sort -u | wc -l | tr -d ' ')" -ne 1 ]; then
  die "image platform or ordered RootFS layers differ"
fi

printf 'round\tposition\tengine\tseconds\tfile_count\tstatus\n' > "$SAMPLES"
sample=0
for ((round = 1; round <= ROUNDS; round++)); do
  for ((position = 1; position <= ${#ENGINES[@]}; position++)); do
    engine_index=$(((round - 1 + position - 1) % ${#ENGINES[@]}))
    engine="${ENGINES[$engine_index]}"
    sample=$((sample + 1))
    CURRENT_ENGINE="$engine"
    CURRENT_CONTAINER="dory-registry-npm-$RUN_ID-$sample"
    timing="$WORK/logs/$sample-$engine.time"
    log="$WORK/logs/$sample-$engine.log"

    de "$engine" create --pull never --name "$CURRENT_CONTAINER" --cpus "$CONTAINER_CPUS" \
      --memory "$CONTAINER_MEMORY" --network bridge "$IMAGE" sleep 600 >/dev/null
    de "$engine" start "$CURRENT_CONTAINER" >/dev/null
    de "$engine" exec "$CURRENT_CONTAINER" mkdir -p /work
    de "$engine" cp "$FIXTURE/package.json" "$CURRENT_CONTAINER:/work/package.json"
    de "$engine" cp "$FIXTURE/package-lock.json" "$CURRENT_CONTAINER:/work/package-lock.json"

    set +e
    timed_command "$timing" "$log" docker -H "unix://$(sock_for "$engine")" exec \
      "$CURRENT_CONTAINER" sh -lc \
      'cd /work && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error'
    command_status=$?
    set -e
    seconds="$(awk 'NR == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { print $1 }' "$timing")"
    files="$(de "$engine" exec "$CURRENT_CONTAINER" sh -lc \
      'find /work/node_modules -type f 2>/dev/null | wc -l' | tr -d ' ')"
    verification=0
    de "$engine" exec "$CURRENT_CONTAINER" sh -lc 'cd /work && npm ls --all >/dev/null' || verification=$?
    sample_status=ok
    if [ "$command_status" -ne 0 ] || [ "$verification" -ne 0 ] || [ -z "$seconds" ]; then
      sample_status=failed
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$round" "$position" "$engine" "${seconds:-NA}" "${files:-NA}" "$sample_status" >> "$SAMPLES"
    cleanup_current
    [ "$sample_status" = ok ] || die "sample $sample failed; see $log"
  done
done

printf 'engine\tmedian_seconds\tsamples\n' > "$STATUS"
for engine in "${ENGINES[@]}"; do
  values="$WORK/$engine.values"
  awk -F '\t' -v wanted="$engine" 'NR > 1 && $3 == wanted && $6 == "ok" { print $4 }' "$SAMPLES" | sort -n > "$values"
  count="$(wc -l < "$values" | tr -d ' ')"
  median="$(awk '{ values[NR]=$1 } END {
    if (NR == 0) exit 1;
    if (NR % 2) printf "%.6f", values[(NR + 1) / 2];
    else printf "%.6f", (values[NR / 2] + values[NR / 2 + 1]) / 2;
  }' "$values")"
  printf '%s\t%s\t%s\n' "$engine" "$median" "$count" >> "$STATUS"
done
printf 'completed_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST"
printf 'raw results: %s\n' "$WORK"
column -t -s $'\t' "$STATUS" 2>/dev/null || cat "$STATUS"
