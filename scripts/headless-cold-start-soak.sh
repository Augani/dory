#!/bin/bash
# CI cold-start regression gate. Each cycle uses a brand-new HOME, starts the exact extracted
# release runtime under a hard outer deadline, probes Docker, stops under a hard deadline, captures
# diagnostics, and proves no owned VMM survives. It never touches ~/.dory or the active app engine.
set -euo pipefail

RUNTIME="${DORY_COLD_START_RUNTIME:-}"
WORKROOT="${DORY_COLD_START_WORKROOT:-$HOME/.dory-cold-start}"
CYCLES="${DORY_COLD_START_CYCLES:-20}"
START_TIMEOUT="${DORY_COLD_START_TIMEOUT:-180}"
STOP_TIMEOUT="${DORY_COLD_STOP_TIMEOUT:-40}"
MEMORY_MB="${DORY_COLD_START_MEMORY_MB:-2048}"
CPUS="${DORY_COLD_START_CPUS:-2}"

usage() {
  cat <<EOF
Usage: scripts/headless-cold-start-soak.sh --runtime DIR [options]

Options:
  --runtime DIR       Extracted dory-engine release directory (required)
  --cycles N          Fresh-home start/stop cycles (default: $CYCLES)
  --start-timeout SEC Outer start deadline (default: $START_TIMEOUT)
  --stop-timeout SEC  Outer graceful-stop deadline (default: $STOP_TIMEOUT)
  --memory-mb N       VM memory ceiling (default: $MEMORY_MB)
  --cpus N            VM vCPUs (default: $CPUS)
  --workroot DIR      Evidence root (default: ~/.dory-cold-start)
  -h, --help

The release gate uses the exact signed runtime extracted from the final release archive. A source
tree or hand-assembled directory is useful development evidence but is not release-qualifying.
EOF
}

die() { echo "cold-start-soak: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) need_value "$1" "$#"; RUNTIME="$2"; shift 2 ;;
    --cycles) need_value "$1" "$#"; CYCLES="$2"; shift 2 ;;
    --start-timeout) need_value "$1" "$#"; START_TIMEOUT="$2"; shift 2 ;;
    --stop-timeout) need_value "$1" "$#"; STOP_TIMEOUT="$2"; shift 2 ;;
    --memory-mb) need_value "$1" "$#"; MEMORY_MB="$2"; shift 2 ;;
    --cpus) need_value "$1" "$#"; CPUS="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
for pair in "cycles:$CYCLES" "start-timeout:$START_TIMEOUT" "stop-timeout:$STOP_TIMEOUT" "memory-mb:$MEMORY_MB" "cpus:$CPUS"; do
  case "${pair#*:}" in ''|*[!0-9]*) die "${pair%%:*} must be a positive integer" ;; esac
  [ "${pair#*:}" -gt 0 ] || die "${pair%%:*} must be positive"
done
[ -n "$RUNTIME" ] || die "--runtime is required"
RUNTIME="$(cd "$RUNTIME" 2>/dev/null && pwd)" || die "runtime directory not found: $RUNTIME"
[ -x "$RUNTIME/dory-engine" ] || die "missing executable: $RUNTIME/dory-engine"
[ -x "$RUNTIME/bin/dory-hv" ] || die "missing executable: $RUNTIME/bin/dory-hv"
[ -x "$RUNTIME/bin/gvproxy" ] || die "missing executable: $RUNTIME/bin/gvproxy"
[ -f "$RUNTIME/share/dory/dory-hv-kernel-arm64.lzfse" ] || die "missing arm64 kernel asset"

if [ "${DORY_COLD_START_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

for command in curl codesign ps lsof python3 vm_stat; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
codesign --verify --strict --verbose=2 "$RUNTIME/bin/dory-hv" >/dev/null 2>&1 \
  || die "dory-hv does not pass strict code-signature verification"
codesign --verify --strict --verbose=2 "$RUNTIME/bin/gvproxy" >/dev/null 2>&1 \
  || die "gvproxy does not pass strict code-signature verification"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
mkdir -p "$WORKDIR"
printf 'cycle\tstatus\tstart_seconds\tstop_seconds\tdetail\n' > "$RESULTS"

run_bounded() {
  local timeout="$1" log="$2"
  shift 2
  "$@" > "$log" 2>&1 &
  local pid=$! deadline=$(( $(date +%s) + timeout )) rc
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}

capture_diagnostics() {
  local home="$1" dir="$2"
  mkdir -p "$dir"
  cp "$home/.dory/engine.log" "$dir/engine.log" 2>/dev/null || true
  cp "$home/.dory/engine-cli.pid" "$dir/engine-cli.pid" 2>/dev/null || true
  ps -axo pid,ppid,state,%cpu,rss,etime,command > "$dir/processes.txt" 2>&1 || true
  vm_stat > "$dir/vm-stat.txt" 2>&1 || true
  df -h > "$dir/df.txt" 2>&1 || true
  if [ -f "$home/.dory/engine-cli.pid" ]; then
    pid="$(cat "$home/.dory/engine-cli.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && lsof -n -P -p "$pid" > "$dir/lsof.txt" 2>&1 || true
  fi
  find "$home/.dory" -ls > "$dir/state-tree.txt" 2>&1 || true
}

force_owned_stop() {
  local home="$1" pid=""
  HOME="$home" "$RUNTIME/dory-engine" stop >/dev/null 2>&1 || true
  if [ -f "$home/.dory/engine-cli.pid" ]; then
    pid="$(cat "$home/.dory/engine-cli.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  fi
}

cleanup_home=""
cleanup() {
  if [ -n "$cleanup_home" ]; then
    force_owned_stop "$cleanup_home"
    rm -rf "$cleanup_home"
  fi
}
trap cleanup EXIT INT TERM

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  home="$HOME/.dcs-$$-$cycle"
  diag="$WORKDIR/cycle-$cycle"
  [ ! -e "$home" ] || die "isolated cycle HOME already exists: $home"
  mkdir -p "$home" "$diag"
  cleanup_home="$home"
  python3 - "$home/.dory/engine.sock" "$home/.dory/hv/docker-backend.sock" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    length = len(os.fsencode(path))
    if length > 103:
        raise SystemExit(f"cold-start Unix socket path is {length} bytes (limit 103): {path}")
PY
  started="$(date +%s)"
  if run_bounded "$START_TIMEOUT" "$diag/start.log" \
      env HOME="$home" "$RUNTIME/dory-engine" start --mem-mb "$MEMORY_MB" --cpus "$CPUS"; then
    :
  else
    rc=$?
    capture_diagnostics "$home" "$diag"
    force_owned_stop "$home"
    printf '%s\tFAIL\t%s\t0\tstart exit=%s\n' "$cycle" "$(( $(date +%s) - started ))" "$rc" >> "$RESULTS"
    die "cycle $cycle did not start; diagnostics: $diag"
  fi
  start_seconds=$(( $(date +%s) - started ))
  socket="$home/.dory/engine.sock"
  curl -fsS --max-time 5 --unix-socket "$socket" http://d/_ping | grep -q OK
  curl -fsS --max-time 5 --unix-socket "$socket" http://d/version > "$diag-version.json"
  curl -fsS --max-time 5 --unix-socket "$socket" http://d/info > "$diag-info.json"

  pid="$(cat "$home/.dory/engine-cli.pid")"
  kill -0 "$pid"
  stopped="$(date +%s)"
  if run_bounded "$STOP_TIMEOUT" "$diag/stop.log" env HOME="$home" "$RUNTIME/dory-engine" stop; then
    :
  else
    rc=$?
    capture_diagnostics "$home" "$diag"
    force_owned_stop "$home"
    printf '%s\tFAIL\t%s\t%s\tstop exit=%s\n' "$cycle" "$start_seconds" "$(( $(date +%s) - stopped ))" "$rc" >> "$RESULTS"
    die "cycle $cycle did not stop; diagnostics: $diag"
  fi
  stop_seconds=$(( $(date +%s) - stopped ))
  if kill -0 "$pid" 2>/dev/null; then
    capture_diagnostics "$home" "$diag"
    force_owned_stop "$home"
    printf '%s\tFAIL\t%s\t%s\towned VMM survived stop\n' "$cycle" "$start_seconds" "$stop_seconds" >> "$RESULTS"
    die "cycle $cycle left VMM pid $pid running"
  fi
  capture_diagnostics "$home" "$diag"
  printf '%s\tPASS\t%s\t%s\tok\n' "$cycle" "$start_seconds" "$stop_seconds" >> "$RESULTS"
  cleanup_home=""
  rm -rf "$home"
  cycle=$((cycle + 1))
done

{
  echo "run_id=$RUN_ID"
  echo "runtime=$RUNTIME"
  echo "cycles=$CYCLES"
  echo "start_timeout=$START_TIMEOUT"
  echo "stop_timeout=$STOP_TIMEOUT"
  echo "release_qualifying=false"
  echo "qualification_note=validate this runtime path against the immutable final release archive manifest"
} > "$WORKDIR/manifest.txt"
echo "headless cold-start soak PASS: $CYCLES cycles; evidence: $WORKDIR"
