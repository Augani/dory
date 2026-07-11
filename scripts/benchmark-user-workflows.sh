#!/usr/bin/env bash
# Workflow-oriented container-engine comparison: verified dependency installation over a bind mount,
# warm-engine container lifecycle, host-edit visibility, a synthetic image build, and process footprint.
# Engines run in a rotating round-robin order so first/last-position drift is shared across engines.
# Timed metrics report medians and coefficient of variation; correctness gates are never timed.
#
# Usage: scripts/benchmark-user-workflows.sh [--engines dory,orbstack,colima] [--rounds 9]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ENGINES_CSV="${BENCH_ENGINES:-dory,orbstack,colima}"
ROUNDS="${BENCH_ROUNDS:-9}"
# Preserve every default run. An explicit BENCH_WORK remains an exact-path override for compatibility;
# callers that reuse it are responsible for choosing a fresh directory when they want immutable runs.
WORK="${BENCH_WORK:-$HOME/.dory-user-bench/$RUN_ID}"
NODE_IMAGE="${BENCH_NODE_IMAGE:-node:22-alpine}"
ALPINE_IMAGE="${BENCH_ALPINE_IMAGE:-alpine:3.21}"
PG_IMAGE="${BENCH_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${BENCH_REDIS_IMAGE:-redis:7-alpine}"
CV_WARN="${BENCH_CV_WARN_PCT:-15}"
NPM_MIN_FILES="${BENCH_NPM_MIN_FILES:-6000}"
NPM_CPUS="${BENCH_NPM_CPUS:-2}"
NPM_MEMORY="${BENCH_NPM_MEMORY:-1800m}"
NPM_ABSENCE_TIMEOUT_MS="${BENCH_NPM_ABSENCE_TIMEOUT_MS:-15000}"
ENGINE_MEMORY_TOLERANCE_PCT="${BENCH_ENGINE_MEMORY_TOLERANCE_PCT:-5}"
CACHE_PREFIX="dory-workflow-npm-$RUN_ID"
CONTAINER_PREFIX="dory-workflow-$RUN_ID"
BUILD_IMAGE_REPOSITORY="dory-workflow-build"
DORY_APP="${DORY_BENCH_APP:-/Applications/Dory.app}"
CLI_ARGS="$*"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines)
      [ "$#" -ge 2 ] || { echo "--engines requires a value" >&2; exit 2; }
      ENGINES_CSV="$2"; shift 2 ;;
    --rounds)
      [ "$#" -ge 2 ] || { echo "--rounds requires a value" >&2; exit 2; }
      ROUNDS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
IFS=',' read -r -a ENGINES <<< "$ENGINES_CSV"
[ "${#ENGINES[@]}" -gt 0 ] || { echo "at least one engine is required" >&2; exit 2; }
VALIDATED_ENGINES=()
for e in "${ENGINES[@]}"; do
  case "$e" in
    dory|orbstack|colima|docker-desktop) ;;
    *) echo "unsupported engine: ${e:-<empty>}" >&2; exit 2 ;;
  esac
  for seen in "${VALIDATED_ENGINES[@]:-}"; do
    [ "$e" != "$seen" ] || { echo "duplicate engine: $e" >&2; exit 2; }
  done
  VALIDATED_ENGINES+=("$e")
done
case "$ROUNDS" in
  ''|*[!0-9]*) echo "rounds must be a positive integer" >&2; exit 2 ;;
esac
[ "$ROUNDS" -gt 0 ] || { echo "rounds must be a positive integer" >&2; exit 2; }
case "$NPM_ABSENCE_TIMEOUT_MS" in
  ''|*[!0-9]*) echo "BENCH_NPM_ABSENCE_TIMEOUT_MS must be a positive integer" >&2; exit 2 ;;
esac
[ "$NPM_ABSENCE_TIMEOUT_MS" -gt 0 ] || {
  echo "BENCH_NPM_ABSENCE_TIMEOUT_MS must be a positive integer" >&2
  exit 2
}
awk -v value="$ENGINE_MEMORY_TOLERANCE_PCT" \
  'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }' || {
  echo "BENCH_ENGINE_MEMORY_TOLERANCE_PCT must be a non-negative number" >&2
  exit 2
}
mkdir -p "$WORK"
RUN_STATUS="$WORK/run-status.tsv"
BENCH_RESOURCES_CREATED=0
printf 'key\tvalue\nstarted_utc\t%s\nrun_id\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" > "$RUN_STATUS"

# ---- engine plumbing ----------------------------------------------------------------------------
sock_for() {
  case "$1" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    docker-desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
    *) echo "" ;;
  esac
}
proc_pattern() {
  case "$1" in
    dory) echo "${DORY_PROCESS_PATTERN:-/Applications/Dory[.]app/Contents/(MacOS/Dory|Helpers/(doryd|dory-hv|dory-vmm|gvproxy))}" ;;
    orbstack) echo "${ORBSTACK_PROCESS_PATTERN:-/Applications/OrbStack[.]app/|/Library/PrivilegedHelperTools/dev[.]orbstack[.]|/xbin/vmgr}" ;;
    colima) echo "${COLIMA_PROCESS_PATTERN:-[.]colima/|/(opt/homebrew|usr/local)/bin/(colima|limactl)|lima-guestagent|socket_vmnet|qemu-system|com[.]apple[.]Virtualization[.]VirtualMachine}" ;;
    *) echo "$1" ;;
  esac
}
de() { local e="$1"; shift; docker -H "unix://$(sock_for "$e")" "$@"; }
# Deadlines use a monotonic clock so a wall-clock adjustment cannot lengthen or truncate a gate.
now_ms() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f\n", 1000 * clock_gettime(CLOCK_MONOTONIC)'
}
npm_cache_for() { printf '%s-%s\n' "$CACHE_PREFIX" "$1"; }
container_name() { printf '%s-%s-%s\n' "$CONTAINER_PREFIX" "$1" "$2"; }
build_image_for() { printf '%s:%s-%s\n' "$BUILD_IMAGE_REPOSITORY" "$RUN_ID" "$1"; }
tsv_field() { printf '%s' "${1:-}" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
normal_image_arch() {
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
  # The ordered diff-ID list is stable across classic and containerd image stores; `.Id` is not.
  printf '%s\n' "$1" | LC_ALL=C grep -Eq \
    '^\["sha256:[0-9a-fA-F]{64}"(,"sha256:[0-9a-fA-F]{64}")*\]$'
}
unique_repo_digest() {
  # RepoDigests can contain aliases. Accept them only when every retained alias identifies the same
  # immutable manifest; otherwise the requested tag's provenance is ambiguous and the run fails.
  printf '%s\n' "$1" | tr ',' '\n' | awk -F '@' '
    {
      digest=$NF
      if (length(digest) == 71 && digest ~ /^sha256:[0-9a-fA-F]+$/) seen[tolower(digest)]=1
    }
    END {
      for (digest in seen) { count++; value=digest }
      if (count != 1) exit 1
      print value
    }
  '
}

# Time only the child command, using a monotonic high-resolution clock. The Perl interpreter starts
# before t0, so timer-process startup is not charged to short lifecycle/host-edit samples.
timed_command() {
  local timing_file="$1" log_file="$2"
  shift 2
  rm -f "$timing_file"
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
timed_de() {
  local e="$1" timing_file="$2" log_file="$3"
  shift 3
  timed_command "$timing_file" "$log_file" docker -H "unix://$(sock_for "$e")" "$@"
}
timing_seconds() {
  local timing_file="$1"
  awk 'NR == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { value=$1; ok=1 }
       END { if (!ok || NR != 1) exit 1; printf "%.6f\n", value }' "$timing_file"
}

capture_run_provenance() {
  local manifest="$WORK/run-manifest.tsv" app_manifest="$WORK/dory-app-files.tsv"
  local git_dirty="clean" app_version="unavailable" app_build="unavailable"
  local app_bundle="unavailable" app_identifier="unavailable" app_team="unavailable"
  local rel path sha size key value tuning=""

  if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then git_dirty="dirty"; fi
  if [ -f "$DORY_APP/Contents/Info.plist" ]; then
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DORY_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
    app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DORY_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
    app_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DORY_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
    app_identifier="$(codesign -dv --verbose=4 "$DORY_APP" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}' || true)"
    app_team="$(codesign -dv --verbose=4 "$DORY_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}' || true)"
  fi
  for key in DORYD_CPUS DORYD_MEMORY_MB DORY_FUSE_ENTRY_TIMEOUT DORY_FUSE_ATTR_TIMEOUT \
             DORY_FUSE_NEGATIVE_TIMEOUT DORY_FUSE_KEEP_CACHE DORY_FUSE_WRITEBACK_CACHE; do
    if [ -n "${!key+x}" ]; then
      value="${!key}"
      tuning="${tuning}${tuning:+;}${key}=$(tsv_field "$value")"
    fi
  done
  [ -n "$tuning" ] || tuning="none"

  {
    printf 'key\tvalue\n'
    printf 'run_id\t%s\n' "$(tsv_field "$RUN_ID")"
    printf 'captured_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'result_root\t%s\n' "$(tsv_field "$WORK")"
    printf 'repo_root\t%s\n' "$(tsv_field "$REPO_ROOT")"
    printf 'cli_args\t%s\n' "$(tsv_field "$CLI_ARGS")"
    printf 'git_head\t%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'git_branch\t%s\n' "$(tsv_field "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)")"
    printf 'git_worktree\t%s\n' "$git_dirty"
    printf 'git_diff_sha256\t%s\n' "$(git -C "$REPO_ROOT" diff HEAD --binary 2>/dev/null | shasum -a 256 | awk '{print $1}' || echo unknown)"
    printf 'benchmark_script_sha256\t%s\n' "$(shasum -a 256 "$REPO_ROOT/scripts/benchmark-user-workflows.sh" | awk '{print $1}')"
    printf 'engines\t%s\n' "$(tsv_field "$ENGINES_CSV")"
    printf 'rounds\t%s\n' "$ROUNDS"
    printf 'node_image\t%s\n' "$(tsv_field "$NODE_IMAGE")"
    printf 'alpine_image\t%s\n' "$(tsv_field "$ALPINE_IMAGE")"
    printf 'postgres_image\t%s\n' "$(tsv_field "$PG_IMAGE")"
    printf 'redis_image\t%s\n' "$(tsv_field "$REDIS_IMAGE")"
    printf 'npm_cpu_limit\t%s\n' "$(tsv_field "$NPM_CPUS")"
    printf 'npm_memory_limit\t%s\n' "$(tsv_field "$NPM_MEMORY")"
    printf 'npm_absence_timeout_ms\t%s\n' "$(tsv_field "$NPM_ABSENCE_TIMEOUT_MS")"
    printf 'engine_memory_tolerance_pct\t%s\n' "$(tsv_field "$ENGINE_MEMORY_TOLERANCE_PCT")"
    printf 'timer\t%s\n' "Time::HiRes CLOCK_MONOTONIC around the child command"
    printf 'hw_model\t%s\n' "$(tsv_field "$(sysctl -n hw.model 2>/dev/null || echo unknown)")"
    printf 'hw_ncpu\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
    printf 'hw_memsize_bytes\t%s\n' "$(sysctl -n hw.memsize 2>/dev/null || echo unknown)"
    printf 'cpu_brand\t%s\n' "$(tsv_field "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)")"
    printf 'macos_version\t%s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    printf 'macos_build\t%s\n' "$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    printf 'uname\t%s\n' "$(tsv_field "$(uname -mrs 2>/dev/null || echo unknown)")"
    printf 'power_source\t%s\n' "$(tsv_field "$(pmset -g batt 2>/dev/null | head -n 1 || echo unknown)")"
    printf 'dory_app_path\t%s\n' "$(tsv_field "$DORY_APP")"
    printf 'dory_app_version\t%s\n' "$(tsv_field "$app_version")"
    printf 'dory_app_build\t%s\n' "$(tsv_field "$app_build")"
    printf 'dory_app_bundle\t%s\n' "$(tsv_field "$app_bundle")"
    printf 'dory_codesign_identifier\t%s\n' "$(tsv_field "${app_identifier:-unknown}")"
    printf 'dory_codesign_team\t%s\n' "$(tsv_field "${app_team:-unknown}")"
    printf 'safe_tuning_overrides\t%s\n' "$(tsv_field "$tuning")"
  } > "$manifest"

  printf 'relative_path\tbytes\tsha256\n' > "$app_manifest"
  for rel in \
    Contents/MacOS/Dory \
    Contents/Helpers/dory-hv \
    Contents/Helpers/doryd \
    Contents/Resources/dory-hv-kernel-arm64 \
    Contents/Resources/dory-hv-kernel-arm64.lzfse \
    Contents/Resources/dory-agent-linux-arm64 \
    Contents/Resources/dory-engine-rootfs-arm64.ext4 \
    Contents/Resources/dory-engine-rootfs-arm64.ext4.lzfse; do
    path="$DORY_APP/$rel"
    [ -f "$path" ] || continue
    sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    size="$(stat -f '%z' "$path" 2>/dev/null || echo unknown)"
    printf '%s\t%s\t%s\n' "$(tsv_field "$rel")" "$size" "$sha" >> "$app_manifest"
  done
}

capture_engine_provenance() {
  local out="$WORK/engine-provenance.tsv" e sock status server api os kernel arch ncpu mem
  local driver cgroup manager vm_type mount_type config cfg cpu memory docker_cpu docker_memory
  printf 'engine\tstatus\tsocket\tmanager_version\tserver_version\tapi_version\tos\tkernel\tarch\tncpu\tmemory_bytes\tstorage_driver\tcgroup_driver\tvm_type\tmount_type\tconfig\n' > "$out"
  for e in "${ENGINES[@]}"; do
    sock="$(sock_for "$e")"
    status="unavailable"; server=""; api=""; os=""; kernel=""; arch=""; ncpu=""; mem=""
    driver=""; cgroup=""; manager=""; vm_type="unknown"; mount_type="unknown"; config=""
    case "$e" in
      dory)
        manager="dory-app"
        vm_type="dory-hv"
        mount_type="virtio-fs"
        config="installed_app=$(tsv_field "$DORY_APP")" ;;
      orbstack)
        manager="$(orb version 2>/dev/null | head -n 1 || true)"
        vm_type="orbstack"
        if command -v orb >/dev/null 2>&1; then
          cpu="$(orb config get cpu 2>/dev/null | tail -n 1 || true)"
          memory="$(orb config get memory_mib 2>/dev/null | tail -n 1 || true)"
          docker_cpu="$(orb config get machine.docker.cpu 2>/dev/null | tail -n 1 || true)"
          docker_memory="$(orb config get machine.docker.memory_mib 2>/dev/null | tail -n 1 || true)"
          config="cpu=$(tsv_field "$cpu");memory_mib=$(tsv_field "$memory");machine.docker.cpu=$(tsv_field "$docker_cpu");machine.docker.memory_mib=$(tsv_field "$docker_memory")"
        fi ;;
      colima)
        manager="$(colima version 2>/dev/null | head -n 1 || true)"
        cfg="$HOME/.colima/default/colima.yaml"
        if [ -f "$cfg" ]; then
          vm_type="$(awk -F: '/^[[:space:]]*vmType:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$cfg")"
          mount_type="$(awk -F: '/^[[:space:]]*mountType:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$cfg")"
          config="$(awk -F: '
            /^[[:space:]]*(cpu|memory|disk|arch|runtime|rosetta):/ {
              key=$1; val=substr($0,index($0,":")+1)
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
              if (out != "") out=out ";"
              out=out key "=" val
            }
            END { print out }' "$cfg")"
        fi
        [ -n "$vm_type" ] || vm_type="unknown"
        [ -n "$mount_type" ] || mount_type="unknown" ;;
      docker-desktop)
        manager="docker-desktop" ;;
    esac
    if [ -n "$sock" ] && [ -S "$sock" ] && docker -H "unix://$sock" version >/dev/null 2>&1; then
      status="ready"
      server="$(docker -H "unix://$sock" version --format '{{.Server.Version}}' 2>/dev/null || true)"
      api="$(docker -H "unix://$sock" version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
      os="$(docker -H "unix://$sock" info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
      kernel="$(docker -H "unix://$sock" info --format '{{.KernelVersion}}' 2>/dev/null || true)"
      arch="$(docker -H "unix://$sock" info --format '{{.Architecture}}' 2>/dev/null || true)"
      ncpu="$(docker -H "unix://$sock" info --format '{{.NCPU}}' 2>/dev/null || true)"
      mem="$(docker -H "unix://$sock" info --format '{{.MemTotal}}' 2>/dev/null || true)"
      driver="$(docker -H "unix://$sock" info --format '{{.Driver}}' 2>/dev/null || true)"
      cgroup="$(docker -H "unix://$sock" info --format '{{.CgroupDriver}}' 2>/dev/null || true)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(tsv_field "$e")" "$status" "$(tsv_field "$sock")" "$(tsv_field "$manager")" \
      "$(tsv_field "$server")" "$(tsv_field "$api")" "$(tsv_field "$os")" \
      "$(tsv_field "$kernel")" "$(tsv_field "$arch")" "$(tsv_field "$ncpu")" \
      "$(tsv_field "$mem")" "$(tsv_field "$driver")" "$(tsv_field "$cgroup")" \
      "$(tsv_field "$vm_type")" "$(tsv_field "$mount_type")" "$(tsv_field "$config")" >> "$out"
  done
}

validate_engine_fairness() {
  local source="$WORK/engine-provenance.tsv" audit="$WORK/resource-fairness.tsv"
  awk -F '\t' 'BEGIN { OFS="\t"; print "engine", "status", "arch", "ncpu", "memory_bytes" }
    NR > 1 { print $1, $2, $9, $10, $11 }' "$source" > "$audit"
  awk -F '\t' -v expected="$engine_count" -v tolerance="$ENGINE_MEMORY_TOLERANCE_PCT" '
    function normalized_arch(value) {
      if (value == "arm64") return "aarch64"
      if (value == "amd64") return "x86_64"
      return value
    }
    NR == 1 { next }
    {
      rows++
      if (NF != 16) {
        printf "error: malformed engine provenance row for %s (expected 16 fields, got %d)\n", $1, NF > "/dev/stderr"
        bad=1
        next
      }
      if ($2 != "ready") {
        printf "error: engine %s is not ready (%s)\n", $1, $2 > "/dev/stderr"
        bad=1
      }
      arch=normalized_arch($9)
      if (arch == "") {
        printf "error: engine %s did not report an architecture\n", $1 > "/dev/stderr"
        bad=1
      }
      if ($10 !~ /^[0-9]+$/ || $10 <= 0) {
        printf "error: engine %s reported invalid CPU capacity: %s\n", $1, $10 > "/dev/stderr"
        bad=1
      }
      if ($11 !~ /^[0-9]+$/ || $11 <= 0) {
        printf "error: engine %s reported invalid memory capacity: %s\n", $1, $11 > "/dev/stderr"
        bad=1
      }
      if (rows == 1) {
        reference_engine=$1
        reference_arch=arch
        reference_cpu=$10
        min_memory=max_memory=$11
      } else {
        if (arch != reference_arch) {
          printf "error: architecture mismatch: %s=%s, %s=%s\n", reference_engine, reference_arch, $1, arch > "/dev/stderr"
          bad=1
        }
        if ($10 != reference_cpu) {
          printf "error: CPU-capacity mismatch: %s=%s, %s=%s\n", reference_engine, reference_cpu, $1, $10 > "/dev/stderr"
          bad=1
        }
        if ($11 < min_memory) min_memory=$11
        if ($11 > max_memory) max_memory=$11
      }
    }
    END {
      if (rows != expected) {
        printf "error: engine provenance has %d rows; expected %d\n", rows, expected > "/dev/stderr"
        bad=1
      }
      if (min_memory > 0) {
        delta=100 * (max_memory-min_memory) / min_memory
        if (delta > tolerance) {
          printf "error: engine memory differs by %.2f%% (allowed %.2f%%; min=%s max=%s bytes)\n", delta, tolerance, min_memory, max_memory > "/dev/stderr"
          bad=1
        }
      }
      exit bad
    }' "$source" || {
      echo "error: engine CPU/memory/architecture fairness gate failed; normalize VM resources before benchmarking" >&2
      echo "resource evidence: $audit" >&2
      return 1
    }
}

capture_image_provenance() {
  local out="$WORK/image-provenance.tsv" e img id digests resolved_digest os arch
  local variant_raw variant created size rootfs_layers rootfs_fingerprint
  printf 'engine\trequested_image\tresolved_repo_digest\timage_id\trepo_digests\tos\tarch\tvariant\tcreated\tbytes\trootfs_layers\trootfs_fingerprint_sha256\n' > "$out"
  for e in "${ENGINES[@]}"; do
    for img in "$NODE_IMAGE" "$ALPINE_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE"; do
      id="$(de "$e" image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)"
      digests="$(de "$e" image inspect --format '{{join .RepoDigests ","}}' "$img" 2>/dev/null || true)"
      resolved_digest="$(unique_repo_digest "$digests" 2>/dev/null || true)"
      os="$(de "$e" image inspect --format '{{.Os}}' "$img" 2>/dev/null || true)"
      arch="$(normal_image_arch "$(de "$e" image inspect --format '{{.Architecture}}' "$img" 2>/dev/null || true)")"
      variant_raw="$(de "$e" image inspect --format '{{.Variant}}' "$img" 2>/dev/null || true)"
      variant="$(normal_image_variant "$arch" "$variant_raw" 2>/dev/null || true)"
      created="$(de "$e" image inspect --format '{{.Created}}' "$img" 2>/dev/null || true)"
      size="$(de "$e" image inspect --format '{{.Size}}' "$img" 2>/dev/null || true)"
      rootfs_layers="$(de "$e" image inspect --format '{{json .RootFS.Layers}}' "$img" 2>/dev/null || true)"
      rootfs_fingerprint=""
      if valid_rootfs_layers "$rootfs_layers"; then
        rootfs_fingerprint="$(printf '%s' "$rootfs_layers" | shasum -a 256 | awk '{print $1}')"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(tsv_field "$e")" "$(tsv_field "$img")" "$(tsv_field "$resolved_digest")" \
        "$(tsv_field "$id")" "$(tsv_field "$digests")" "$(tsv_field "$os")" \
        "$(tsv_field "$arch")" "$(tsv_field "$variant")" "$(tsv_field "$created")" \
        "$(tsv_field "$size")" "$(tsv_field "$rootfs_layers")" \
        "$(tsv_field "$rootfs_fingerprint")" >> "$out"
    done
  done
}

validate_image_fairness() {
  local source="$WORK/image-provenance.tsv"
  awk -F '\t' -v expected="$engine_count" '
    NR == 1 { next }
    {
      image=$2
      digest=$3
      os=$6
      arch=$7
      variant=$8
      rootfs=$12
      if (NF != 12 || image == "" || digest == "" || os == "" || arch == "" || \
          variant == "" || rootfs == "") {
        printf "error: missing or malformed image provenance for engine=%s image=%s\n", $1, image > "/dev/stderr"
        bad=1
        next
      }
      if (length(digest) != 71 || digest !~ /^sha256:[0-9a-fA-F]+$/ || \
          length(rootfs) != 64 || rootfs !~ /^[0-9a-fA-F]+$/) {
        printf "error: invalid immutable image identity for engine=%s image=%s\n", $1, image > "/dev/stderr"
        bad=1
        next
      }
      platform=os "/" arch "/" variant
      if (image in canonical_digest && canonical_digest[image] != digest) {
        printf "error: RepoDigest mismatch for %s: %s used %s, canonical is %s\n", image, $1, digest, canonical_digest[image] > "/dev/stderr"
        bad=1
      } else if (!(image in canonical_digest)) {
        canonical_digest[image]=digest
      }
      if (image in canonical_platform && canonical_platform[image] != platform) {
        printf "error: platform mismatch for %s: %s used %s, canonical is %s\n", image, $1, platform, canonical_platform[image] > "/dev/stderr"
        bad=1
      } else if (!(image in canonical_platform)) {
        canonical_platform[image]=platform
      }
      if (image in canonical_rootfs && canonical_rootfs[image] != rootfs) {
        printf "error: ordered RootFS mismatch for %s: %s used %s, canonical is %s\n", image, $1, rootfs, canonical_rootfs[image] > "/dev/stderr"
        bad=1
      } else if (!(image in canonical_rootfs)) {
        canonical_rootfs[image]=rootfs
      }
      count[image]++
    }
    END {
      images=0
      for (image in count) {
        images++
        if (count[image] != expected) {
          printf "error: image %s has %d provenance rows; expected %d\n", image, count[image], expected > "/dev/stderr"
          bad=1
        }
      }
      if (images != 4) {
        printf "error: image provenance has %d distinct requested images; expected 4\n", images > "/dev/stderr"
        bad=1
      }
      exit bad
    }' "$source" || {
      echo "error: engines did not use the same immutable RepoDigest, platform, and ordered RootFS layers; performance results would not be comparable" >&2
      return 1
    }
}

cleanup_benchmark_containers() {
  local e
  for e in "${ENGINES[@]}"; do
    de "$e" rm -f \
      "$(container_name hotwatch "$e")" "$(container_name watchgate "$e")" \
      "$(container_name postgres "$e")" "$(container_name redis "$e")" \
      >/dev/null 2>&1 || true
    de "$e" volume rm -f "$(npm_cache_for "$e")" "$(npm_cache_for "lock-$e")" \
      >/dev/null 2>&1 || true
    de "$e" image rm -f "$(build_image_for "$e")" >/dev/null 2>&1 || true
  done
}
finalize_benchmark() {
  local rc=$?
  printf 'finished_utc\t%s\nexit_code\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$RUN_STATUS"
  if [ "$BENCH_RESOURCES_CREATED" -eq 1 ]; then
    cleanup_benchmark_containers
  fi
}
trap finalize_benchmark EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Per-engine phys_footprint (MB) summed over the engine's process tree — the RAM the engine actually
# charges, isolated from unrelated system churn. footprint(1) works on the current user's processes.
footprint_mb() {
  local e="$1" stage="${2:-sample}" pat pid v u tot=0 command status ledger
  pat="$(proc_pattern "$e")"
  ledger="$WORK/footprint-processes.tsv"
  if [ ! -f "$ledger" ]; then
    printf 'stage\tengine\tpid\tstatus\tphys_footprint_mb\tcommand\n' > "$ledger"
  fi
  for pid in $(ps -axo pid,args | awk -v p="$pat" -v self="$$" \
      '$1 != self && $0 ~ p && $0 !~ /awk/ { print $1 }'); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    set -- $(/usr/bin/footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }')
    v="${1:-}"; u="${2:-}"
    status="measured"
    if [ -z "$v" ]; then
      status="unreadable"
      printf '%s\t%s\t%s\t%s\t\t%s\n' "$stage" "$e" "$pid" "$status" \
        "$(tsv_field "$command")" >> "$ledger"
      continue
    fi
    tot=$(awk -v t="$tot" -v v="$v" -v u="$u" 'BEGIN{ m=(u=="KB"||u=="K")?v/1024:(u=="GB"||u=="G")?v*1024:v; printf "%.0f", t+m }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$stage" "$e" "$pid" "$status" \
      "$(awk -v v="$v" -v u="$u" 'BEGIN{printf "%.3f",(u=="KB"||u=="K")?v/1024:(u=="GB"||u=="G")?v*1024:v}')" \
      "$(tsv_field "$command")" >> "$ledger"
  done
  echo "$tot"
}

# ---- stats --------------------------------------------------------------------------------------
median() { printf '%s\n' "$@" | awk '{v[n++]=$1+0} END{if(!n){print 0;exit} for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t} printf (n%2)?"%.3f":"%.3f", (n%2)?v[(n-1)/2]:(v[n/2-1]+v[n/2])/2}'; }
cvpct()  { [ "$#" -gt 1 ] || { printf 0; return; }; printf '%s\n' "$@" | awk '{v[n++]=$1+0;s+=$1+0} END{if(n<2||s==0){print 0;exit} m=s/n;for(i=0;i<n;i++){d=v[i]-m;ss+=d*d} printf "%.1f",100*sqrt(ss/(n-1))/m}'; }

# ---- fixtures -----------------------------------------------------------------------------------
setup_fixtures() {
  local npm="$WORK/npm-fixture" build="$WORK/build" e
  mkdir -p "$npm" "$build"
  cat > "$npm/package.json" <<'JSON'
{ "name":"dory-bench","version":"1.0.0","private":true,
  "dependencies":{
    "express":"4.19.2","lodash":"4.17.21","axios":"1.6.8","chalk":"4.1.2",
    "react":"18.3.1","react-dom":"18.3.1","typescript":"5.4.5","commander":"12.1.0",
    "date-fns":"3.6.0","zod":"3.23.8"
  } }
JSON
  cat > "$npm/verify-install.js" <<'JS'
const fs = require('fs')
const path = require('path')

const expected = {
  express: '4.19.2',
  lodash: '4.17.21',
  axios: '1.6.8',
  chalk: '4.1.2',
  react: '18.3.1',
  'react-dom': '18.3.1',
  typescript: '5.4.5',
  commander: '12.1.0',
  'date-fns': '3.6.0',
  zod: '3.23.8',
}

for (const [name, version] of Object.entries(expected)) {
  const packageJSON = JSON.parse(
    fs.readFileSync(path.join('/app/node_modules', name, 'package.json'), 'utf8'),
  )
  if (packageJSON.version !== version) {
    throw new Error(`${name}: expected ${version}, got ${packageJSON.version}`)
  }
}

// Exercise representative CommonJS entry points instead of accepting a tree that only has names.
require('express')
require('lodash')
require('react')
JS
  # Keep each engine's bind mount independent. npm caches are separate daemon-local named volumes,
  # so cache I/O does not accidentally add a second host-share workload to the timed install.
  for e in "${ENGINES[@]}"; do
    rm -rf "$WORK/npm-$e"
    mkdir -p "$WORK/npm-$e" "$WORK/hot-$e"
    cp "$npm/package.json" "$WORK/npm-$e/package.json"
    cp "$npm/verify-install.js" "$WORK/npm-$e/verify-install.js"
  done
  # I/O-heavy build with NO network so it measures the snapshotter/overlay, not apt/apk downloads.
  cat > "$build/Dockerfile" <<DOCKER
FROM $ALPINE_IMAGE
RUN mkdir -p /w && cd /w \\
 && for i in \$(seq 1 3000); do printf 'content line %s\\n' "\$i" > "f\$i.txt"; done \\
 && test "\$(cat /w/f*.txt | wc -l | tr -d ' ')" -eq 3000 \\
 && for i in \$(seq 1 3000); do rm -f "/w/f\$i.txt"; done
CMD ["true"]
DOCKER
}

# ---- metrics ------------------------------------------------------------------------------------
# 1) npm ci over a HOST bind mount — the decade-old #1 Docker-on-Mac file-sharing pain. Every
# engine gets the same lockfile and a separately warmed VM-local cache; timed installs are offline.
prepare_npm_lock() {
  local e base="$WORK/npm-fixture" project cache log sha canonical_sha="" canonical_engine=""
  rm -f "$base/package-lock.json" "$WORK/npm-lock.sha256"
  for e in "${ENGINES[@]}"; do
    project="$WORK/npm-lock-$e"
    cache="$(npm_cache_for "lock-$e")"
    log="$WORK/npm-lock-$e.log"
    rm -rf "$project"
    mkdir -p "$project"
    cp "$base/package.json" "$project/package.json"
    de "$e" volume create "$cache" >/dev/null
    if ! de "$e" run --rm --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
        -v "$project:/app" -v "$cache:/root/.npm" -w /app "$NODE_IMAGE" \
        npm install --package-lock-only --ignore-scripts --no-audit --no-fund --loglevel=error \
        >"$log" 2>&1; then
      echo "error: could not generate comparison lockfile with $e (see $log)" >&2
      sed -n '1,160p' "$log" >&2
      return 1
    fi
    [ -s "$project/package-lock.json" ] || {
      echo "error: npm did not create a lockfile with $e" >&2
      return 1
    }
    sha="$(shasum -a 256 "$project/package-lock.json" | awk '{ print $1 }')"
    if [ -z "$canonical_sha" ]; then
      canonical_sha="$sha"
      canonical_engine="$e"
      cp "$project/package-lock.json" "$base/package-lock.json"
    elif [ "$sha" != "$canonical_sha" ]; then
      echo "error: npm lock mismatch: $canonical_engine=$canonical_sha, $e=$sha" >&2
      return 1
    fi
  done
  printf '%s\n' "$canonical_sha" > "$WORK/npm-lock.sha256"
  for e in "${ENGINES[@]}"; do
    cp "$base/package-lock.json" "$WORK/npm-$e/package-lock.json"
  done
}
npm_install() {
  local e="$1" offline="$2" timing_file="${3:-}"
  local project="$WORK/npm-$1" cache log="$WORK/npm-$1-install.log"
  local -a args
  cache="$(npm_cache_for "$e")"
  args=(run --rm --cpus "$NPM_CPUS" --memory "$NPM_MEMORY")
  [ -z "$offline" ] || args+=(--network none)
  args+=(-v "$project:/app" -v "$cache:/root/.npm" -w /app "$NODE_IMAGE" npm ci)
  [ -z "$offline" ] || args+=(--offline)
  args+=(--no-audit --no-fund --loglevel=error)
  if [ -n "$timing_file" ]; then
    timed_de "$e" "$timing_file" "$log" "${args[@]}" || {
      echo "error: npm ci failed on $e (see $log)" >&2
      sed -n '1,160p' "$log" >&2
      return 1
    }
  elif ! de "$e" "${args[@]}" >"$log" 2>&1; then
    echo "error: npm ci failed on $e (see $log)" >&2
    sed -n '1,160p' "$log" >&2
    return 1
  fi
}
npm_verify() {
  local e="$1" project="$WORK/npm-$1" expected lock_sha node_lock_sha
  local host_files host_dirs host_links host_link_sha guest_report
  local guest_files guest_dirs guest_links guest_link_sha tree_shape
  host_files="$(find "$project/node_modules" -type f 2>/dev/null | wc -l | tr -d ' ')"
  host_dirs="$(find "$project/node_modules" -type d 2>/dev/null | wc -l | tr -d ' ')"
  host_links="$(find "$project/node_modules" -type l 2>/dev/null | wc -l | tr -d ' ')"
  host_link_sha="$(
    cd "$project"
    find node_modules -type l -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s\t%s\n' "$path" "$(readlink "$path")"
    done | shasum -a 256 | awk '{print $1}'
  )"
  guest_report="$(de "$e" run --rm --network none --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    -v "$project:/app" -w /app "$NODE_IMAGE" sh -ec '
      files=$(find node_modules -type f | wc -l | tr -d " ")
      dirs=$(find node_modules -type d | wc -l | tr -d " ")
      links=$(find node_modules -type l | wc -l | tr -d " ")
      link_sha=$(find node_modules -type l -print | LC_ALL=C sort | while IFS= read -r path; do
        printf "%s\t%s\n" "$path" "$(readlink "$path")"
      done | sha256sum | cut -d" " -f1)
      npm ls --offline --all --json >/dev/null 2>&1
      node /app/verify-install.js
      test -L /app/node_modules/.bin/tsc
      test -x /app/node_modules/.bin/tsc
      /app/node_modules/.bin/tsc --version >/dev/null
      printf "%s\t%s\t%s\t%s\n" "$files" "$dirs" "$links" "$link_sha"
    ')"
  IFS=$'\t' read -r guest_files guest_dirs guest_links guest_link_sha <<< "$guest_report"
  if [ "${host_files:-0}" -lt "$NPM_MIN_FILES" ] || \
     [ "$host_files" != "$guest_files" ] || [ "$host_dirs" != "$guest_dirs" ] || \
     [ "$host_links" != "$guest_links" ] || [ "$host_link_sha" != "$guest_link_sha" ]; then
    echo "error: npm ci tree mismatch on $e: host=${host_files}f/${host_dirs}d/${host_links}l guest=${guest_files}f/${guest_dirs}d/${guest_links}l (expected matching files >= $NPM_MIN_FILES)" >&2
    return 1
  fi
  tree_shape="$(printf '%s\t%s\t%s\t%s' "$host_files" "$host_dirs" "$host_links" "$host_link_sha")"
  if [ -s "$WORK/npm-expected-tree.tsv" ]; then
    expected="$(< "$WORK/npm-expected-tree.tsv")"
    [ "$tree_shape" = "$expected" ] || {
      echo "error: npm ci on $e produced a different file/directory/symlink tree from the canonical warm install" >&2
      return 1
    }
  else
    printf '%s\n' "$tree_shape" > "$WORK/npm-expected-tree.tsv"
  fi
  lock_sha="$(shasum -a 256 "$project/package-lock.json" | awk '{ print $1 }')"
  [ "$lock_sha" = "$(< "$WORK/npm-lock.sha256")" ] || {
    echo "error: npm ci changed or replaced the canonical lockfile for $e" >&2
    return 1
  }
  [ -s "$project/node_modules/.package-lock.json" ] || {
    echo "error: npm ci on $e did not produce node_modules/.package-lock.json" >&2
    return 1
  }
  node_lock_sha="$(shasum -a 256 "$project/node_modules/.package-lock.json" | awk '{ print $1 }')"
  if [ -s "$WORK/npm-expected-node-lock.sha256" ]; then
    [ "$node_lock_sha" = "$(< "$WORK/npm-expected-node-lock.sha256")" ] || {
      echo "error: npm ci on $e produced a different node_modules lock from the canonical warm install" >&2
      return 1
    }
  else
    printf '%s\n' "$node_lock_sha" > "$WORK/npm-expected-node-lock.sha256"
  fi
}
npm_absence_barrier() {
  local e="$1" project="$WORK/npm-$1" deadline
  [ ! -e "$project/node_modules" ] || {
    echo "error: host still has node_modules after cleanup for $e" >&2
    return 1
  }
  deadline=$(( $(now_ms) + NPM_ABSENCE_TIMEOUT_MS ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    if de "$e" run --rm --network none --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
        -v "$project:/app" "$NODE_IMAGE" sh -ec 'test -f /app/package.json && test ! -e /app/node_modules' \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  echo "error: guest on $e still observed node_modules after cleanup (${NPM_ABSENCE_TIMEOUT_MS}ms barrier)" >&2
  return 1
}
npm_clear_bind_tree() {
  local e="$1" project="$WORK/npm-$1"
  # Clear through the engine that owns the bind mount. A host-side recursive unlink creates one
  # FSEvent per package path while the engine is live, which is a different workload: it can
  # intentionally trip Dory's loss-aware host-edit recovery before the timed npm command begins.
  # This untimed container still proves that node_modules is absent on both sides of the same bind
  # mount, without injecting that external-change storm into just one competitor's setup. Node's
  # retrying remover handles directories that receive a late close while package-manager workers
  # unwind; BusyBox rm can otherwise return ENOTEMPTY on this exact large tree.
  de "$e" run --rm --network none --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    -v "$project:/app" -w /app "$NODE_IMAGE" node -e '
      const fs = require("node:fs");
      fs.rmSync("/app/node_modules", { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
      if (fs.existsSync("/app/node_modules")) process.exit(1);
    ' \
    >/dev/null || {
      echo "error: could not clear npm bind tree through $e" >&2
      return 1
    }
  npm_absence_barrier "$e"
}
warm_npm() {
  local e="$1" project="$WORK/npm-$1"
  de "$e" volume create "$(npm_cache_for "$e")" >/dev/null || return 1
  npm_clear_bind_tree "$e" || return 1
  npm_install "$e" "" || return 1
  npm_verify "$e" || return 1
  npm_clear_bind_tree "$e"
}
m_npm() {
  local e="$1" project="$WORK/npm-$1" timing_file="$WORK/npm-$1.time"
  npm_clear_bind_tree "$e" || return 1
  npm_install "$e" "--offline" "$timing_file" || return 1
  npm_verify "$e" || return 1
  timing_seconds "$timing_file" || {
    echo "error: missing or malformed npm timing for $e" >&2
    return 1
  }
}

# 2) Warm-engine container lifecycle — create+start+teardown of a trivial container. This is not an
#    engine cold boot and must not be presented as one.
m_lifecycle() {
  local e="$1" timing_file="$WORK/lifecycle-$1.time" log="$WORK/lifecycle-$1.log" seconds
  timed_de "$e" "$timing_file" "$log" run --rm --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    "$ALPINE_IMAGE" true || {
      echo "error: warm container lifecycle failed on $e (see $log)" >&2
      return 1
    }
  seconds="$(timing_seconds "$timing_file")" || {
    echo "error: missing or malformed lifecycle timing for $e" >&2
    return 1
  }
  awk -v seconds="$seconds" 'BEGIN { printf "%.3f\n", 1000 * seconds }'
}

# 3a) File-watch correctness gate. Node's fs.watch uses inotify in the Linux guest, the same class of
#     event source used by common JS development servers. The host changes an already-watched file;
#     the container must receive an event and read the sentinel before any timings are accepted.
#     This validates the watcher path, but is not an end-to-end browser/framework HMR measurement.
watch_event_gate() {
  local e="$1" hot="$WORK/hot-$1" name
  name="$(container_name watchgate "$1")"
  local sentinel="watch-$(now_ms)-$RANDOM" deadline status log="$WORK/watch-$1.log"
  rm -f "$hot/watch-input.txt" "$hot/watch-ready.txt" "$hot/watch-event.txt"
  printf 'INIT\n' > "$hot/watch-input.txt"
  : > "$log"
  de "$e" rm -f "$name" >/dev/null 2>&1 || true
  if ! de "$e" run -d --name "$name" --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
      -e "BENCH_SENTINEL=$sentinel" -v "$hot:/w" "$NODE_IMAGE" \
      node -e '
        const fs = require("fs");
        const input = "/w/watch-input.txt";
        const sentinel = process.env.BENCH_SENTINEL;
        const watcher = fs.watch(input, (eventType) => {
          let contents;
          try { contents = fs.readFileSync(input, "utf8"); } catch (_) { return; }
          if (!contents.includes(sentinel)) return;
          fs.writeFileSync("/w/watch-event.txt", `${eventType}\n${sentinel}\n`);
          clearTimeout(timer);
          watcher.close();
          process.exit(0);
        });
        const timer = setTimeout(() => {
          watcher.close();
          console.error("timed out waiting for host edit event");
          process.exit(2);
        }, 10000);
        fs.writeFileSync("/w/watch-ready.txt", "ready\n");
      ' >/dev/null; then
    echo "error: could not start file-watch gate on $e" >&2
    return 1
  fi

  deadline=$(( $(now_ms) + 15000 ))
  while [ "$(now_ms)" -lt "$deadline" ] && [ ! -s "$hot/watch-ready.txt" ]; do sleep 0.05; done
  if [ ! -s "$hot/watch-ready.txt" ]; then
    de "$e" logs "$name" > "$log" 2>&1 || true
    de "$e" rm -f "$name" >/dev/null 2>&1 || true
    echo "error: file watcher did not become ready on $e (see $log)" >&2
    return 1
  fi

  printf '%s\n' "$sentinel" >> "$hot/watch-input.txt"
  if ! status="$(de "$e" wait "$name" 2>>"$log")"; then
    de "$e" logs "$name" >> "$log" 2>&1 || true
    de "$e" rm -f "$name" >/dev/null 2>&1 || true
    echo "error: could not wait for file-watch gate on $e (see $log)" >&2
    return 1
  fi
  de "$e" logs "$name" >> "$log" 2>&1 || true
  de "$e" rm -f "$name" >/dev/null 2>&1 || true
  status="$(printf '%s\n' "$status" | tail -n 1 | tr -d '[:space:]')"
  if [ "$status" != 0 ] || ! grep -q "$sentinel" "$hot/watch-event.txt" 2>/dev/null; then
    echo "error: host edit did not produce a readable fs.watch/inotify event on $e (see $log)" >&2
    return 1
  fi
}

# 3b) Host-edit polling visibility — how long after a HOST edit does a process in the container see it? A
#    persistent container tight-copies /w/a -> /w/b; we write a sentinel to a and wait for it in b.
#    Round-trips the mount twice, so it captures content-cache coherence. This does NOT prove that
#    framework HMR works; the separate gate above covers Linux watcher-event delivery.
hot_start() {
  local e="$1" hot="$WORK/hot-$1" name
  name="$(container_name hotwatch "$e")"
  de "$e" rm -f "$name" >/dev/null 2>&1 || true
  echo INIT > "$hot/a"
  : > "$hot/b"
  de "$e" run -d --name "$name" --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    -v "$hot:/w" "$ALPINE_IMAGE" \
    sh -c 'while true; do cp /w/a /w/b 2>/dev/null; sleep 0.01; done' >/dev/null 2>&1
}
hot_stop() {
  local e="$1"
  de "$e" rm -f "$(container_name hotwatch "$e")" >/dev/null 2>&1 || true
}
m_hotreload() {
  local e="$1" hot="$WORK/hot-$1" sentinel
  sentinel="s$(now_ms)$RANDOM"
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,usleep -e '
    use strict;
    use warnings;
    my ($input, $output, $sentinel) = @ARGV;
    my $start = clock_gettime(CLOCK_MONOTONIC);
    open my $input_handle, ">", $input or die "open $input: $!\n";
    print {$input_handle} "$sentinel\n" or die "write $input: $!\n";
    close $input_handle or die "close $input: $!\n";
    my $deadline = $start + 5;
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      if (open my $output_handle, "<", $output) {
        local $/;
        my $contents = <$output_handle>;
        close $output_handle;
        if (defined $contents && index($contents, $sentinel) >= 0) {
          printf "%.3f\n", 1000 * (clock_gettime(CLOCK_MONOTONIC) - $start);
          exit 0;
        }
      }
      usleep(1000);
    }
    die "host edit was not visible through polling within 5s\n";
  ' "$hot/a" "$hot/b" "$sentinel" || {
    echo "error: host edit was not visible through polling on $e within 5s" >&2
    return 1
  }
}

# 4a) Uncached synthetic image build (no network) — snapshotter/overlay write path. This is not an
#     application build and does not represent build-cache performance.
m_build() {
  local e="$1" timing_file="$WORK/build-$1.time" log="$WORK/build-$1.log"
  timed_de "$e" "$timing_file" "$log" build --no-cache -q -t "$(build_image_for "$e")" \
    "$WORK/build" || {
      echo "error: synthetic image build failed on $e (see $log)" >&2
      return 1
    }
  timing_seconds "$timing_file" || {
    echo "error: missing or malformed build timing for $e" >&2
    return 1
  }
}

# 4b) Engine process footprint with two idle service containers (postgres+redis). Measured once, not
#     per round: absolute process footprint after a fixed settle, then its change 25s after teardown.
#     This is not an application-load memory test and the reclaim value is a single observation.
mem_stack() {
  local e="$1" up after deadline pg_name redis_name
  pg_name="$(container_name postgres "$e")"
  redis_name="$(container_name redis "$e")"
  de "$e" rm -f "$pg_name" "$redis_name" >/dev/null 2>&1 || true
  sleep 5
  de "$e" run -d --name "$pg_name" --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    -e POSTGRES_PASSWORD=bench "$PG_IMAGE" >/dev/null 2>&1
  de "$e" run -d --name "$redis_name" --cpus "$NPM_CPUS" --memory "$NPM_MEMORY" \
    "$REDIS_IMAGE" >/dev/null 2>&1
  deadline=$(( $(now_ms) + 15000 ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    if de "$e" exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 && \
       [ "$(de "$e" exec "$redis_name" redis-cli ping 2>/dev/null)" = PONG ]; then
      break
    fi
    sleep 0.25
  done
  de "$e" exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 && \
    [ "$(de "$e" exec "$redis_name" redis-cli ping 2>/dev/null)" = PONG ] || {
      echo "error: service stack did not become ready on $e" >&2
      return 1
    }
  sleep 15
  up="$(footprint_mb "$e" stack_up)"
  de "$e" rm -f "$pg_name" "$redis_name" >/dev/null 2>&1
  sleep 25; after=$(footprint_mb "$e" post_teardown)
  # absolute footprint with the stack up, and MB reclaimed 25s after teardown (free-page reporting)
  echo "$up $((up-after))"
}

# ---- run ----------------------------------------------------------------------------------------
engine_count="${#ENGINES[@]}"
if [ $((ROUNDS % engine_count)) -ne 0 ]; then
  echo "error: $ROUNDS rounds is not position-balanced across $engine_count engines; use a multiple of $engine_count" >&2
  exit 2
fi
capture_run_provenance
capture_engine_provenance
validate_engine_fairness
echo "== workflow-oriented engine comparison =="
echo "engines: ${ENGINES[*]}   rounds: $ROUNDS   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "npm limits: ${NPM_CPUS} CPU, ${NPM_MEMORY}; identical lockfile, VM-local cache, timed offline ci"
echo "results: $WORK"
setup_fixtures

# Samples are accumulated to files (bash 3.2 has no associative arrays): $SAMP/<metric>-<engine>
SAMP="$WORK/samples"; rm -rf "$SAMP"; mkdir -p "$SAMP"
RAW_SAMPLES="$WORK/samples.tsv"
ROUND_ORDER="$WORK/round-order.tsv"
printf 'round\tposition\tengine\tmetric\tvalue\tunit\n' > "$RAW_SAMPLES"
printf 'round\tengine_order\n' > "$ROUND_ORDER"

# Pre-pull images, generate one canonical lockfile, then warm independent caches per engine
# (untimed) so the timed rounds measure the workload, not resolution or one-time downloads.
for e in "${ENGINES[@]}"; do
  echo "-- prepare $e --"
  for img in "$NODE_IMAGE" "$ALPINE_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE"; do de "$e" pull -q "$img" >/dev/null 2>&1; done
done
capture_image_provenance
validate_image_fairness
rm -f "$WORK/npm-expected-files" "$WORK/npm-expected-tree.tsv" "$WORK/npm-expected-node-lock.sha256"
BENCH_RESOURCES_CREATED=1
prepare_npm_lock
printf 'npm_lock_sha256\t%s\n' "$(< "$WORK/npm-lock.sha256")" >> "$WORK/run-manifest.tsv"
echo "canonical npm lock: $(< "$WORK/npm-lock.sha256")"
for e in "${ENGINES[@]}"; do
  warm_npm "$e"
  de "$e" build --no-cache -q -t "$(build_image_for "$e")" "$WORK/build" >/dev/null 2>&1
done

# Run the watcher-event correctness gates before collecting any competitive timings. Record every
# engine's result, then fail the whole run if any engine cannot deliver a host edit to Linux fs.watch.
watch_gate_failed=0
echo "-- file-watch correctness gates (untimed) --"
for e in "${ENGINES[@]}"; do
  if watch_event_gate "$e"; then
    echo "PASS" > "$SAMP/watch-$e"
    printf '  %-12s PASS\n' "$e"
  else
    echo "FAIL" > "$SAMP/watch-$e"
    printf '  %-12s FAIL\n' "$e"
    watch_gate_failed=1
  fi
done
if [ "$watch_gate_failed" -ne 0 ]; then
  echo "error: watcher-event correctness gate failed; no performance timings were collected" >&2
  exit 1
fi

# Rotate the first engine every round. A complete cycle is a balanced Latin-square order for this
# one-factor comparison, avoiding a permanent first/last engine advantage.
for r in $(seq 1 "$ROUNDS"); do
  step=0
  round_order=""
  while [ "$step" -lt "$engine_count" ]; do
    idx=$(( (r - 1 + step) % engine_count ))
    e="${ENGINES[$idx]}"
    round_order="${round_order}${round_order:+,}$e"
    if ! value="$(m_npm "$e")"; then
      echo "error: npm metric failed for $e in round $r" >&2
      exit 1
    fi
    printf '%s\n' "$value" >> "$SAMP/npm-$e"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$((step + 1))" "$e" npm "$value" seconds >> "$RAW_SAMPLES"
    if ! value="$(m_lifecycle "$e")"; then
      echo "error: lifecycle metric failed for $e in round $r" >&2
      exit 1
    fi
    printf '%s\n' "$value" >> "$SAMP/lifecycle-$e"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$((step + 1))" "$e" lifecycle "$value" milliseconds >> "$RAW_SAMPLES"
    if ! value="$(m_build "$e")"; then
      echo "error: build metric failed for $e in round $r" >&2
      exit 1
    fi
    printf '%s\n' "$value" >> "$SAMP/build-$e"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$((step + 1))" "$e" build "$value" seconds >> "$RAW_SAMPLES"
    # The polling helper deliberately exists only around its own sample so its continuous bind I/O
    # and CPU use cannot contaminate npm, lifecycle, build, or another engine's sample.
    hot_start "$e"
    if ! value="$(m_hotreload "$e")"; then
      echo "error: host-edit polling metric failed for $e in round $r" >&2
      exit 1
    fi
    printf '%s\n' "$value" >> "$SAMP/hot-$e"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$((step + 1))" "$e" host_edit_poll "$value" milliseconds >> "$RAW_SAMPLES"
    hot_stop "$e"
    printf '  round %s/%s %-9s done\n' "$r" "$ROUNDS" "$e"
    step=$((step + 1))
  done
  printf '%s\t%s\n' "$r" "$round_order" >> "$ROUND_ORDER"
  printf '  round %s/%s order: %s\n' "$r" "$ROUNDS" "$round_order"
done

# memory stack (sequential — starting a stack in one engine perturbs system-wide memory)
for e in "${ENGINES[@]}"; do mem_stack "$e" > "$SAMP/mem-$e"; done

# Fail closed on incomplete, malformed, or silently dropped repetitions. No report is produced unless
# every engine has exactly the requested number of valid scalar samples for every timed metric.
validate_scalar_samples() {
  local key="$1" e file count
  for e in "${ENGINES[@]}"; do
    file="$SAMP/$key-$e"
    [ -s "$file" ] || { echo "error: missing samples: $file" >&2; return 1; }
    count="$(awk 'END { print NR + 0 }' "$file")"
    [ "$count" -eq "$ROUNDS" ] || {
      echo "error: $file has $count samples; expected $ROUNDS" >&2
      return 1
    }
    awk 'NF != 1 || $1 !~ /^[0-9]+([.][0-9]+)?$/ { exit 1 }' "$file" || {
      echo "error: malformed numeric sample in $file" >&2
      return 1
    }
  done
}
for key in npm lifecycle hot build; do validate_scalar_samples "$key"; done
for e in "${ENGINES[@]}"; do
  grep -qx 'PASS' "$SAMP/watch-$e" || { echo "error: missing PASS gate for $e" >&2; exit 1; }
  awk 'NR == 1 && NF == 2 && $1 ~ /^[0-9]+$/ && $1 > 0 && $2 ~ /^-?[0-9]+$/ { ok=1 }
       END { exit !(NR == 1 && ok) }' "$SAMP/mem-$e" || {
    echo "error: malformed or unattributed footprint sample in $SAMP/mem-$e" >&2
    exit 1
  }
done
raw_count="$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$RAW_SAMPLES")"
expected_raw_count=$((ROUNDS * engine_count * 4))
[ "$raw_count" -eq "$expected_raw_count" ] || {
  echo "error: raw sample ledger has $raw_count rows; expected $expected_raw_count" >&2
  exit 1
}
[ "$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$ROUND_ORDER")" -eq "$ROUNDS" ] || {
  echo "error: round-order ledger is incomplete" >&2
  exit 1
}

# ---- report -----------------------------------------------------------------------------------
line() { printf '%s\n' "--------------------------------------------------------------------------------"; }
{
echo; line; echo "CORRECTNESS GATE (untimed; required before performance results)"; line
printf '%-30s' "gate"; for e in "${ENGINES[@]}"; do printf '%-18s' "$e"; done; echo
printf '%-30s' "host edit -> Linux fs.watch"; for e in "${ENGINES[@]}"; do printf '%-18s' "$(< "$SAMP/watch-$e")"; done; echo
line
echo; line; echo "TIMED RESULTS (median; cv% in parens; exact $ROUNDS samples per engine)"; line
printf '%-24s' "metric"; for e in "${ENGINES[@]}"; do printf '%-18s' "$e"; done; echo
report_row() {
  local label="$1" unit="$2" key="$3" e med cv vals
  printf '%-24s' "$label"
  for e in "${ENGINES[@]}"; do
    vals="$(tr '\n' ' ' < "$SAMP/$key-$e" 2>/dev/null)"
    # shellcheck disable=SC2086
    med=$(median $vals); cv=$(cvpct $vals)
    if awk -v c="$cv" -v w="$CV_WARN" 'BEGIN { exit !(c > w) }'; then
      UNSTABLE="${UNSTABLE}${UNSTABLE:+; }$label/$e=${cv}%"
    fi
    printf '%-18s' "$(awk -v m="$med" -v c="$cv" -v u="$unit" 'BEGIN{printf "%.3g%s(%s%%)", m, u, c}')"
  done; echo
}
UNSTABLE=""
report_row "offline npm ci (bind)"    "s"  npm
report_row "warm container lifecycle" "ms" lifecycle
report_row "host-edit polling"        "ms" hot
report_row "uncached synthetic build" "s"  build
line
echo; line; echo "DIAGNOSTIC FOOTPRINT (one fixed-order sample; not a rankable result)"; line
printf '%-24s' "metric"; for e in "${ENGINES[@]}"; do printf '%-18s' "$e"; done; echo
printf '%-24s' "footprint, 2 svc(MB)"; for e in "${ENGINES[@]}"; do printf '%-18s' "$(awk '{print $1}' "$SAMP/mem-$e")"; done; echo
printf '%-24s' "footprint drop 25s(MB)"; for e in "${ENGINES[@]}"; do printf '%-18s' "$(awk '{print $2}' "$SAMP/mem-$e")"; done; echo
line
[ -z "$UNSTABLE" ] || echo "warning: CV exceeds ${CV_WARN}%: $UNSTABLE"
echo "notes: lower is better for timed metrics. footprint drop is a single post-teardown observation;"
echo "       it is not reported as a median and may include ordinary engine process churn. Footprint PID"
echo "       attribution is regex-based, can omit privileged processes, and cannot reliably assign a"
echo "       generic Virtualization.framework XPC process when several VMs run. Treat it as diagnostic,"
echo "       not as a memory winner. Included PIDs are recorded in $WORK/footprint-processes.tsv."
echo "       npm uses byte-identical locks independently generated by every engine, separately warmed"
echo "       VM-local named-volume caches, fresh node_modules, and offline npm ci with Docker networking"
echo "       disabled at ${NPM_CPUS} CPU/${NPM_MEMORY}. The timer includes docker run/create/remove."
echo "       Exact host/guest file-count and lock-hash checks run outside the timer. Projects, caches,"
echo "       and polling directories are isolated per engine. 'Warm container lifecycle' is"
echo "       docker run/create/start/remove with the engine and image already warm, not engine boot."
echo "       Child commands use CLOCK_MONOTONIC timing. The synthetic build is uncached, offline layer I/O,"
echo "       not a real application build or cache benchmark. Linux fs.watch validates watcher-event"
echo "       delivery for one in-place host content edit; it does not cover create/delete/atomic-save"
echo "       semantics or claim browser/framework HMR latency. Engine architecture/CPU and near-equal"
echo "       reported memory, plus immutable RepoDigest/platform/ordered-RootFS identity, are fail-closed"
echo "       preflight gates. Store-dependent Docker image IDs remain provenance-only diagnostics."
echo "       Raw round/position samples: $RAW_SAMPLES. Provenance: $WORK/run-manifest.tsv,"
echo "       $WORK/engine-provenance.tsv, $WORK/resource-fairness.tsv, and $WORK/image-provenance.tsv."
} | tee "$WORK/summary.txt"
