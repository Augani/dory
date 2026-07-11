#!/bin/bash
# Destructive, installed-engine integration gate for Dory's production host-share path.
#
# This suite intentionally provokes one fail-stop VM restart.  It refuses to run without --run,
# refuses to run while any unrelated container is active, never pulls an image, and confines host
# file mutations to fresh test-owned directories.  Raw evidence is retained even on failure.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_PROBE_SOURCE="$ROOT/scripts/fixtures/hostshare_guest_probe.py"
NONPING_PROBE_SOURCE="$ROOT/scripts/fixtures/hostshare_nonping_probe.py"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_SLUG="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_.-')"
DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
DOCKER_BIN="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
DORYDCTL_BIN="${DORY_DORYDCTL_BIN:-}"
IMAGE="${DORY_HOSTSHARE_IMAGE:-python:3.12-alpine}"
EVIDENCE="${DORY_HOSTSHARE_EVIDENCE:-$HOME/.dory-test-evidence/hostshare/$RUN_ID}"
WORK_PARENT="${DORY_HOSTSHARE_WORK_PARENT:-$HOME/.dory-hostshare-tests}"
OUTSIDE_PARENT="${DORY_HOSTSHARE_OUTSIDE_PARENT:-${TMPDIR:-/private/tmp}}"
FAILSTOP_TIMEOUT_MS="${DORY_HOSTSHARE_FAILSTOP_TIMEOUT_MS:-5000}"
RESTART_TIMEOUT_SECONDS="${DORY_HOSTSHARE_RESTART_TIMEOUT_SECONDS:-120}"
NONPING_TIMEOUT_SECONDS="${DORY_HOSTSHARE_NONPING_TIMEOUT_SECONDS:-5}"
REPLACE_COUNT="${DORY_HOSTSHARE_REPLACE_COUNT:-300}"
HV_LOG="${DORY_HOSTSHARE_HV_LOG:-$HOME/.dory/hv/dory-hv.log}"
HV_STATE_DIR="${DORY_HOSTSHARE_STATE_DIR:-$HOME/.dory/hv}"
LABEL_KEY="dev.dory.hostshare-integration"
ROOT_OWNERSHIP_FILE=".dory-hostshare-run-id"
RUN_REQUESTED=0
LIST_CASES=0
WORK_ROOT=""
OUTSIDE_ROOT=""
SHARE=""
LOCK_DIR=""
LOCK_OWNED=0
CREATED_CONTAINERS=""
RESOURCES_STARTED=0
FINAL_STATUS="fail"
FAIL_REASON="unexpected_exit"
RESULTS=""
NONPING_PROBE_PID=""
RECOVERY_PROBE_PID=""

usage() {
  cat <<'EOF'
Usage: scripts/live-hostshare-integration.sh --run [options]

This is an intentionally disruptive installed-Dory test.  Its dirty MAP_SHARED case must crash and
restart Dory's Docker VM, interrupting containers.  The harness aborts unless Dory has zero running
containers before it starts and checks again immediately before the restart case.

Options:
  --run                       Required explicit opt-in; without it no engine is contacted.
  --socket PATH               Dory Docker socket (default: ~/.dory/dory.sock).
  --image REF                 Already-local Python 3 Linux image (default: python:3.12-alpine).
  --evidence-dir DIR          New evidence directory retained after the run.
  --dorydctl PATH             Installed dorydctl used to verify the dory-hv PID transition.
  --hv-log PATH               Installed dory-hv log used to attribute the fail-stop reason.
  --failstop-timeout-ms N     Maximum old-helper exit latency (default: 5000).
  --restart-timeout-seconds N Maximum time for a new healthy helper (default: 120).
  --nonping-timeout-seconds N Independent bound for a Docker request across fail-stop (default: 5).
  --replace-count N           Atomic-replacement race iterations (default: 300).
  --state-dir PATH            Installed raw-HV state directory (default: ~/.dory/hv).
  --list-cases                Print the case inventory without touching files or the engine.
  -h, --help                  Show this help without touching files or the engine.

The live path always uses `docker --pull never`.  Host mutations are limited to fresh roots under
~/.dory-hostshare-tests and a same-filesystem outside-$HOME containment sentinel.  Once container
cleanup is confirmed, logs, health snapshots, guest JSON, and final host trees are copied into the
evidence dir.  If cleanup cannot be confirmed, the roots and lock are retained and recorded there.
EOF
}

print_cases() {
  cat <<'EOF'
clean-same-inode-overwrite
dirty-old-mmap-atomic-replacement
repeated-atomic-replacement
hardlink-lifetime
symlink-and-moved-parent-containment
stdin-passthrough
watcher-matrix-round-1
watcher-matrix-round-2
dirty-mmap-failstop-and-restart (intentionally restarts Dory's Docker VM)
EOF
}

die_usage() {
  echo "live-hostshare-integration: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run) RUN_REQUESTED=1; shift ;;
    --socket) [ "$#" -ge 2 ] || die_usage "--socket requires a value"; DORY_SOCK="$2"; shift 2 ;;
    --image) [ "$#" -ge 2 ] || die_usage "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --evidence-dir) [ "$#" -ge 2 ] || die_usage "--evidence-dir requires a value"; EVIDENCE="$2"; shift 2 ;;
    --dorydctl) [ "$#" -ge 2 ] || die_usage "--dorydctl requires a value"; DORYDCTL_BIN="$2"; shift 2 ;;
    --hv-log) [ "$#" -ge 2 ] || die_usage "--hv-log requires a value"; HV_LOG="$2"; shift 2 ;;
    --failstop-timeout-ms)
      [ "$#" -ge 2 ] || die_usage "--failstop-timeout-ms requires a value"
      FAILSTOP_TIMEOUT_MS="$2"; shift 2 ;;
    --restart-timeout-seconds)
      [ "$#" -ge 2 ] || die_usage "--restart-timeout-seconds requires a value"
      RESTART_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --nonping-timeout-seconds)
      [ "$#" -ge 2 ] || die_usage "--nonping-timeout-seconds requires a value"
      NONPING_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --replace-count)
      [ "$#" -ge 2 ] || die_usage "--replace-count requires a value"
      REPLACE_COUNT="$2"; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || die_usage "--state-dir requires a value"; HV_STATE_DIR="$2"; shift 2 ;;
    --list-cases) LIST_CASES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [ "$LIST_CASES" -eq 1 ]; then
  [ "$RUN_REQUESTED" -eq 0 ] || die_usage "--list-cases cannot be combined with --run"
  print_cases
  exit 0
fi
[ "$RUN_REQUESTED" -eq 1 ] || die_usage "refusing to contact Dory without the explicit --run flag"
case "${PYTHONOPTIMIZE:-0}" in
  ''|0) ;;
  *) die_usage "PYTHONOPTIMIZE must be unset or 0; optimized Python disables release-gate assertions" ;;
esac

bounded_positive_integer() {
  case "$2" in ''|*[!0-9]*) die_usage "$1 must be a positive integer" ;; esac
  [ "${#2}" -le 9 ] || die_usage "$1 exceeds the supported maximum of $3"
  [ "$2" -gt 0 ] || die_usage "$1 must be a positive integer"
  [ "$2" -le "$3" ] || die_usage "$1 exceeds the supported maximum of $3"
}
bounded_positive_integer "fail-stop timeout" "$FAILSTOP_TIMEOUT_MS" 60000
bounded_positive_integer "restart timeout" "$RESTART_TIMEOUT_SECONDS" 600
bounded_positive_integer "non-ping timeout" "$NONPING_TIMEOUT_SECONDS" 30
bounded_positive_integer "replace count" "$REPLACE_COUNT" 10000
[ -n "$IMAGE" ] || die_usage "image must not be empty"
[ -n "$DORY_SOCK" ] || die_usage "socket must not be empty"
[ -n "$EVIDENCE" ] || die_usage "evidence directory must not be empty"
case "$DORY_SOCK" in /*) ;; *) die_usage "socket path must be absolute" ;; esac
case "$EVIDENCE" in /*) ;; *) die_usage "evidence directory must be absolute" ;; esac
case "$WORK_PARENT" in /*) ;; *) die_usage "work parent must be absolute" ;; esac
case "$OUTSIDE_PARENT" in /*) ;; *) die_usage "outside parent must be absolute" ;; esac
case "$HV_LOG" in /*) ;; *) die_usage "dory-hv log path must be absolute" ;; esac
case "$HV_STATE_DIR" in /*) ;; *) die_usage "dory-hv state directory must be absolute" ;; esac
[ ! -e "$EVIDENCE" ] || die_usage "evidence directory already exists: $EVIDENCE"
FORWARD_SOCK="$HV_STATE_DIR/agent-vsock-forward.sock"
ACTIVITY_SOCK="$HV_STATE_DIR/dataplane-activity.sock"

# Validate configurable parents before creating or chmod'ing anything. In particular, the work
# parent must remain inside the production home export, must not be HOME itself, and must not live
# below the evidence directory (which would make the final-tree snapshot recursively copy itself).
command -v python3 >/dev/null 2>&1 || die_usage "host python3 is required"
python3 - <<'PY' || exit 2
import sys
if sys.flags.optimize != 0:
    raise SystemExit(
        "live-hostshare-integration: host python3 has optimization enabled; assertions would be disabled"
    )
PY
python3 - "$HOME" "$WORK_PARENT" "$OUTSIDE_PARENT" "$EVIDENCE" "$HV_STATE_DIR" "$DORY_SOCK" <<'PY' || exit 2
import os
import sys

home, work_parent, outside_parent, evidence, hv_state, socket_path = map(os.path.realpath, sys.argv[1:7])
if os.path.commonpath([home, work_parent]) != home or work_parent == home:
    raise SystemExit("live-hostshare-integration: work parent must be a child of HOME")
if not os.path.isdir(outside_parent):
    raise SystemExit("live-hostshare-integration: outside parent must already be a directory")
if os.path.commonpath([home, outside_parent]) == home:
    raise SystemExit("live-hostshare-integration: outside parent must be outside HOME")
if os.path.commonpath([evidence, work_parent]) == evidence:
    raise SystemExit("live-hostshare-integration: work parent must not be inside the evidence directory")
if os.path.commonpath([evidence, outside_parent]) == evidence:
    raise SystemExit("live-hostshare-integration: outside parent must not be inside the evidence directory")
if any("\n" in value or "\r" in value for value in sys.argv[1:7]):
    raise SystemExit("live-hostshare-integration: configured paths must not contain newlines")
if ":" in work_parent:
    raise SystemExit("live-hostshare-integration: work parent must not contain ':' (Docker mount separator)")
PY

resolve_dorydctl() {
  local candidate
  if [ -n "$DORYDCTL_BIN" ]; then
    [ -x "$DORYDCTL_BIN" ] || return 1
    printf '%s\n' "$DORYDCTL_BIN"
    return 0
  fi
  for candidate in \
    "/Applications/Dory.app/Contents/Helpers/dorydctl" \
    "$HOME/.dory/bin/dorydctl" \
    "$ROOT/dory-core-swift/.build/arm64-apple-macosx/release/dorydctl" \
    "$ROOT/dory-core-swift/.build/x86_64-apple-macosx/release/dorydctl" \
    "$ROOT/dory-core-swift/.build/release/dorydctl"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

tsv_field() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

now_ms() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f\n", 1000 * clock_gettime(CLOCK_MONOTONIC)'
}

pause_ms() {
  /usr/bin/perl -MTime::HiRes=usleep -e 'usleep(1000 * shift)' "$1"
}

docker_e() {
  DOCKER_CLIENT_TIMEOUT=10 DOCKER_HTTP_TIMEOUT=10 \
    "$DOCKER_BIN" -H "unix://$DORY_SOCK" "$@"
}

bounded_docker_version() {
  local label="$1" gate result runner_log
  gate="$EVIDENCE/bounded-docker-version-$label.gate"
  result="$EVIDENCE/bounded-docker-version-$label.json"
  runner_log="$EVIDENCE/bounded-docker-version-$label.runner.log"
  : > "$gate"
  if ! python3 "$NONPING_PROBE_SOURCE" "$gate" "$DOCKER_BIN" "$DORY_SOCK" \
    "$NONPING_TIMEOUT_SECONDS" 1 "$result" > "$runner_log" 2>&1; then
    return 1
  fi
  python3 - "$result" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding="utf-8"))
if result.get("timed_out") is not False or result.get("returncode") != 0:
    raise SystemExit(1)
if not str(result.get("stdout", "")).strip():
    raise SystemExit(1)
PY
}

write_run_status() {
  local status="$1" reason="$2" code="$3" temporary="$EVIDENCE/run-status.tsv.tmp"
  {
    printf 'key\tvalue\n'
    printf 'status\t%s\n' "$(tsv_field "$status")"
    printf 'reason\t%s\n' "$(tsv_field "$reason")"
    printf 'exit_code\t%s\n' "$code"
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'updated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'evidence_dir\t%s\n' "$(tsv_field "$EVIDENCE")"
  } > "$temporary"
  mv "$temporary" "$EVIDENCE/run-status.tsv"
}

snapshot_final_trees() {
  local failed=0
  mkdir -p "$EVIDENCE/final-host-trees"
  if [ -n "$WORK_ROOT" ] && [ -d "$WORK_ROOT" ]; then
    cp -pR "$WORK_ROOT" "$EVIDENCE/final-host-trees/work-root" 2>/dev/null || failed=1
  fi
  if [ -n "$OUTSIDE_ROOT" ] && [ -d "$OUTSIDE_ROOT" ]; then
    cp -pR "$OUTSIDE_ROOT" "$EVIDENCE/final-host-trees/outside-root" 2>/dev/null || failed=1
  fi
  return "$failed"
}

capture_container_log() {
  local name="$1" destination inspect_destination log_code
  # Bash 3.2 expands every assignment in one `local` command before publishing any of them.
  # Derive paths only after `name` exists, or `set -u` aborts before the first live case runs.
  destination="$EVIDENCE/containers/$name.log"
  inspect_destination="$EVIDENCE/containers/$name.inspect.json"
  mkdir -p "$EVIDENCE/containers"
  container_is_owned "$name" || return 1
  if docker_e inspect "$name" > "$inspect_destination.tmp" 2>/dev/null; then
    mv "$inspect_destination.tmp" "$inspect_destination"
    if docker_e logs "$name" > "$destination.tmp" 2>&1; then
      log_code=0
    else
      log_code=$?
    fi
    mv "$destination.tmp" "$destination"
    printf '%s\n' "$log_code" > "$destination.exit-code"
  else
    rm -f "$inspect_destination.tmp"
    return 1
  fi
}

container_is_owned() {
  local name="$1" owner
  owner="$(docker_e inspect --format '{{ index .Config.Labels "dev.dory.hostshare-integration" }}' \
    "$name" 2>/dev/null || true)"
  [ "$owner" = "$RUN_ID" ]
}

root_is_owned() {
  local root="$1" owner
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  owner="$(cat "$root/$ROOT_OWNERSHIP_FILE" 2>/dev/null || true)"
  [ "$owner" = "$RUN_ID" ]
}

lock_is_owned() {
  local owner
  [ "$LOCK_OWNED" -eq 1 ] && [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ] && \
    [ ! -L "$LOCK_DIR" ] || return 1
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [ "$owner" = "$$" ]
}

cleanup() {
  local code="$?" cleanup_safe=1 container_id owned_ids list_code
  trap - EXIT INT TERM HUP
  set +e
  if [ "$RESOURCES_STARTED" -eq 1 ] && [ -n "$DOCKER_BIN" ] && \
     [ -f "$EVIDENCE/created-containers.txt" ]; then
    if bounded_docker_version cleanup-initial; then
      owned_ids="$(docker_e ps -aq --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null)"
      list_code=$?
      if [ "$list_code" -ne 0 ]; then
        cleanup_safe=0
      else
        for container_id in $owned_ids; do
          case "$container_id" in ''|*[!0-9a-fA-F]*) cleanup_safe=0; continue ;; esac
          if ! container_is_owned "$container_id"; then
            cleanup_safe=0
            continue
          fi
          capture_container_log "$container_id" || true
          if docker_e rm -f "$container_id" >/dev/null 2>&1; then
            if docker_e inspect "$container_id" >/dev/null 2>&1; then cleanup_safe=0; fi
          else
            if docker_e inspect "$container_id" >/dev/null 2>&1 || \
               ! bounded_docker_version cleanup-after-remove; then
              cleanup_safe=0
            fi
          fi
        done
      fi
    else
      cleanup_safe=0
    fi
  fi
  if [ "$cleanup_safe" -eq 1 ]; then
    snapshot_final_trees || cleanup_safe=0
  fi
  if [ "$cleanup_safe" -eq 1 ]; then
    if [ -n "$WORK_ROOT" ] && { [ -e "$WORK_ROOT" ] || [ -L "$WORK_ROOT" ]; }; then
      if root_is_owned "$WORK_ROOT"; then rm -rf "$WORK_ROOT" || cleanup_safe=0; else cleanup_safe=0; fi
    fi
    if [ -n "$OUTSIDE_ROOT" ] && { [ -e "$OUTSIDE_ROOT" ] || [ -L "$OUTSIDE_ROOT" ]; }; then
      if root_is_owned "$OUTSIDE_ROOT"; then rm -rf "$OUTSIDE_ROOT" || cleanup_safe=0; else cleanup_safe=0; fi
    fi
    if [ "$cleanup_safe" -eq 1 ] && [ "$LOCK_OWNED" -eq 1 ]; then
      if lock_is_owned; then rm -rf "$LOCK_DIR" || cleanup_safe=0; else cleanup_safe=0; fi
    fi
  fi
  if [ "$cleanup_safe" -ne 1 ]; then
    FAIL_REASON="${FAIL_REASON};cleanup_unconfirmed"
    {
      echo "Container or root cleanup could not be confirmed; any remaining roots and lock were retained."
      echo "work_root=$WORK_ROOT"
      echo "outside_root=$OUTSIDE_ROOT"
      echo "lock_dir=$LOCK_DIR"
    } > "$EVIDENCE/cleanup-incomplete.txt"
    code=1
  fi
  # Bash 3.2 can report status 0 to EXIT after an unbound-variable expansion inside a compound
  # `local` declaration. Never let an incomplete run become a successful process exit merely
  # because the shell supplied that misleading status.
  if [ "$FINAL_STATUS" != "pass" ] && [ "$code" -eq 0 ]; then
    code=1
  fi
  if [ "$FINAL_STATUS" = "pass" ] && [ "$code" -eq 0 ]; then
    write_run_status pass complete 0
  else
    write_run_status fail "$FAIL_REASON" "$code"
  fi
  exit "$code"
}

mkdir -p "$(dirname "$EVIDENCE")"
mkdir "$EVIDENCE"
chmod 700 "$EVIDENCE"
RESULTS="$EVIDENCE/results.tsv"
printf 'status\tcase\tdetail\n' > "$RESULTS"
write_run_status running in_progress 0
trap cleanup EXIT
trap 'FAIL_REASON=interrupted; exit 130' INT
trap 'FAIL_REASON=terminated; exit 143' TERM
trap 'FAIL_REASON=hangup; exit 129' HUP

record_result() {
  local status="$1" case_name="$2" detail="$3"
  printf '%s\t%s\t%s\n' "$status" "$case_name" "$(tsv_field "$detail")" >> "$RESULTS"
  printf '  [%s] %s%s\n' "$status" "$case_name" "${detail:+ -- $detail}"
}

run_case() {
  local case_name="$1" function_name="$2" log code
  log="$EVIDENCE/cases/$case_name.log"
  mkdir -p "$EVIDENCE/cases"
  echo "==> $case_name"
  set +e
  ( set -e; "$function_name" ) > "$log" 2>&1
  code=$?
  set -e
  if [ "$code" -eq 0 ]; then
    record_result PASS "$case_name" "raw log: $log"
    return 0
  fi
  FAIL_REASON="case_failed:$case_name"
  record_result FAIL "$case_name" "exit $code; raw log: $log"
  sed -n '1,200p' "$log" >&2
  return "$code"
}

register_container() {
  local name="$1"
  CREATED_CONTAINERS="$CREATED_CONTAINERS $name"
  printf '%s\n' "$name" >> "$EVIDENCE/created-containers.txt"
}

remove_container() {
  local name="$1"
  container_is_owned "$name" || {
    echo "refusing to remove unowned or missing container: $name" >&2
    return 1
  }
  capture_container_log "$name"
  docker_e rm -f "$name" >/dev/null
  ! docker_e inspect "$name" >/dev/null 2>&1
}

wait_for_log() {
  local name="$1" needle="$2" timeout_seconds="$3" log
  local deadline state
  log="$EVIDENCE/containers/$name.log"
  mkdir -p "$EVIDENCE/containers"
  deadline=$(( $(now_ms) + timeout_seconds * 1000 ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    docker_e logs "$name" > "$log" 2>&1 || true
    if grep -Fq "$needle" "$log"; then return 0; fi
    state="$(docker_e inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)"
    [ "$state" = "true" ] || {
      echo "container $name exited before logging: $needle" >&2
      return 1
    }
    pause_ms 25
  done
  echo "timed out waiting for $needle from $name" >&2
  return 1
}

wait_for_container_exit() {
  local name="$1" timeout_seconds="$2" deadline running code
  deadline=$(( $(now_ms) + timeout_seconds * 1000 ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    running="$(docker_e inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)"
    if [ "$running" = "false" ]; then
      code="$(docker_e inspect --format '{{.State.ExitCode}}' "$name")"
      [ "$code" = "0" ] || {
        echo "container $name exited with status $code" >&2
        return 1
      }
      return 0
    fi
    [ "$running" = "true" ] || { echo "container $name disappeared" >&2; return 1; }
    pause_ms 50
  done
  echo "container $name did not exit within ${timeout_seconds}s" >&2
  return 1
}

capture_health() {
  local label="$1" destination
  destination="$EVIDENCE/health/$label.json"
  mkdir -p "$EVIDENCE/health"
  "$DORYDCTL_BIN" --timeout 5 health > "$destination"
  python3 - "$destination" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
engine = next((item for item in report.get("results", []) if item.get("id") == "engine.status"), None)
if engine is None:
    raise SystemExit("health report has no engine.status result")
data = engine.get("data", {})
if data.get("state") != "running" or not str(data.get("hv_pid", "")).isdigit():
    raise SystemExit(f"engine is not a running managed dory-hv: {engine}")
print(data["hv_pid"])
PY
}

health_daemon_pid() {
  python3 - "$1" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
memory = next((item for item in report.get("results", []) if item.get("id") == "memory.footprint"), None)
daemon_pid = "" if memory is None else str(memory.get("data", {}).get("daemon_pid", ""))
if not daemon_pid.isdigit() or int(daemon_pid) <= 1:
    raise SystemExit("health report has no valid memory.footprint daemon_pid")
print(daemon_pid)
PY
}

socket_identity() {
  [ -S "$1" ] || return 1
  stat -f '%d:%i' "$1"
}

wait_for_old_endpoint_cleanup() {
  local start_ms="$1" old_dory="$2" old_forward="$3" old_activity="$4"
  local deadline now dory_state forward_state activity_state
  local dory_clean=0 forward_clean=0 activity_clean=0
  local dory_transition="" forward_transition="" activity_transition=""
  local dory_transition_ms="" forward_transition_ms="" activity_transition_ms=""
  deadline=$(( start_ms + 3000 ))
  printf 'monotonic_ms\tdory_socket\tforward_socket\tactivity_socket\n' \
    > "$EVIDENCE/endpoint-cleanup-trace.tsv"
  while [ "$(now_ms)" -lt "$deadline" ]; do
    now="$(now_ms)"
    dory_state="$(socket_identity "$DORY_SOCK" 2>/dev/null || echo absent)"
    forward_state="$(socket_identity "$FORWARD_SOCK" 2>/dev/null || echo absent)"
    activity_state="$(socket_identity "$ACTIVITY_SOCK" 2>/dev/null || echo absent)"
    if [ "$dory_clean" -eq 0 ] && { [ "$dory_state" = "absent" ] || [ "$dory_state" != "$old_dory" ]; }; then
      dory_clean=1; dory_transition="$dory_state"; dory_transition_ms="$now"
    fi
    if [ "$forward_clean" -eq 0 ] && { [ "$forward_state" = "absent" ] || [ "$forward_state" != "$old_forward" ]; }; then
      forward_clean=1; forward_transition="$forward_state"; forward_transition_ms="$now"
    fi
    if [ "$activity_clean" -eq 0 ] && { [ "$activity_state" = "absent" ] || [ "$activity_state" != "$old_activity" ]; }; then
      activity_clean=1; activity_transition="$activity_state"; activity_transition_ms="$now"
    fi
    printf '%s\t%s\t%s\t%s\n' "$now" "$dory_state" "$forward_state" "$activity_state" \
      >> "$EVIDENCE/endpoint-cleanup-trace.tsv"
    if [ "$dory_clean" -eq 1 ] && [ "$forward_clean" -eq 1 ] && [ "$activity_clean" -eq 1 ]; then
      {
        printf 'endpoint\told_identity\ttransition_identity\ttransition_monotonic_ms\n'
        printf 'dory\t%s\t%s\t%s\n' "$old_dory" "$dory_transition" "$dory_transition_ms"
        printf 'forward\t%s\t%s\t%s\n' "$old_forward" "$forward_transition" "$forward_transition_ms"
        printf 'activity\t%s\t%s\t%s\n' "$old_activity" "$activity_transition" "$activity_transition_ms"
      } > "$EVIDENCE/endpoint-cleanup-proof.tsv"
      return 0
    fi
    pause_ms 5
  done
  echo "supervisor did not retire every pre-fail-stop endpoint identity within 3000ms" >&2
  return 1
}

assert_recovered_endpoints_are_fresh() {
  local old_dory="$1" old_forward="$2" old_activity="$3"
  local new_dory new_forward new_activity
  new_dory="$(socket_identity "$DORY_SOCK")"
  new_forward="$(socket_identity "$FORWARD_SOCK")"
  new_activity="$(socket_identity "$ACTIVITY_SOCK")"
  {
    printf 'endpoint\told_identity\tnew_identity\n'
    printf 'dory\t%s\t%s\n' "$old_dory" "$new_dory"
    printf 'forward\t%s\t%s\n' "$old_forward" "$new_forward"
    printf 'activity\t%s\t%s\n' "$old_activity" "$new_activity"
  } > "$EVIDENCE/recovered-endpoint-identities.tsv"
  # st_ino is unique only while an object exists; APFS may reuse it after unlink. Freshness is
  # therefore proven by the transition captured while recovery was in progress, not by requiring
  # the final socket number to differ forever from its predecessor.
  python3 - "$EVIDENCE/endpoint-cleanup-proof.tsv" \
    "$old_dory" "$old_forward" "$old_activity" <<'PY'
import csv, re, sys
proof_path = sys.argv[1]
expected = dict(zip(("dory", "forward", "activity"), sys.argv[2:5]))
with open(proof_path, encoding="utf-8", newline="") as handle:
    rows = {row["endpoint"]: row for row in csv.DictReader(handle, delimiter="\t")}
if set(rows) != set(expected):
    raise SystemExit(f"endpoint cleanup proof is incomplete: {rows}")
for endpoint, old_identity in expected.items():
    row = rows[endpoint]
    transition = row.get("transition_identity", "")
    timestamp = row.get("transition_monotonic_ms", "")
    if row.get("old_identity") != old_identity:
        raise SystemExit(f"endpoint cleanup proof changed old identity for {endpoint}: {row}")
    if not transition:
        raise SystemExit(f"endpoint cleanup proof has empty transition for {endpoint}: {row}")
    if transition != "absent" and not re.fullmatch(r"[0-9]+:[0-9]+", transition):
        raise SystemExit(f"endpoint cleanup proof has invalid identity for {endpoint}: {row}")
    if transition != "absent" and transition == old_identity:
        raise SystemExit(f"endpoint cleanup proof has no retirement transition for {endpoint}: {row}")
    if not timestamp.isdigit():
        raise SystemExit(f"endpoint cleanup proof has invalid time for {endpoint}: {row}")
PY
}

require_unchanged_hv() {
  local before="$1" label="$2" after
  after="$(capture_health "$label")"
  [ "$before" = "$after" ] || {
    echo "dory-hv changed unexpectedly during $label: $before -> $after" >&2
    return 1
  }
}

is_raw_hv_pid() {
  local pid="$1" command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    */dory-hv\ engine|*/dory-hv\ engine\ *) return 0 ;;
    *) return 1 ;;
  esac
}

helper_pid_is_live() {
  local pid="$1" state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  case "$state" in Z*|*' Z'*) return 1 ;; *) return 0 ;; esac
}

cleanup_nonping_probe() {
  if [ -n "$NONPING_PROBE_PID" ] && kill -0 "$NONPING_PROBE_PID" 2>/dev/null; then
    kill -TERM "$NONPING_PROBE_PID" 2>/dev/null || true
  fi
  if [ -n "$NONPING_PROBE_PID" ]; then
    wait "$NONPING_PROBE_PID" 2>/dev/null || true
    NONPING_PROBE_PID=""
  fi
}

cleanup_recovery_probe() {
  if [ -n "$RECOVERY_PROBE_PID" ] && kill -0 "$RECOVERY_PROBE_PID" 2>/dev/null; then
    local child_deadline
    # The recovery subshell may currently be waiting on dorydctl or the independently bounded
    # Python/Docker probe. Terminate that direct child first; the Python probe reaps its own process
    # group, preventing cleanup from orphaning a Docker CLI behind the subshell.
    /usr/bin/pkill -TERM -P "$RECOVERY_PROBE_PID" 2>/dev/null || true
    child_deadline=$(( $(now_ms) + 2000 ))
    while /usr/bin/pgrep -P "$RECOVERY_PROBE_PID" >/dev/null 2>&1 && \
          [ "$(now_ms)" -lt "$child_deadline" ]; do
      pause_ms 10
    done
    /usr/bin/pkill -KILL -P "$RECOVERY_PROBE_PID" 2>/dev/null || true
    kill -TERM "$RECOVERY_PROBE_PID" 2>/dev/null || true
  fi
  if [ -n "$RECOVERY_PROBE_PID" ]; then
    wait "$RECOVERY_PROBE_PID" 2>/dev/null || true
    RECOVERY_PROBE_PID=""
  fi
}

cleanup_failstop_probes() {
  cleanup_nonping_probe
  cleanup_recovery_probe
}

validate_nonping_window() {
  local result_path="$1" event_ms="$2" exit_ms="$3" recovery_ms="$4"
  local handshake_ms="$5" timeout_seconds="$6"
  python3 - "$result_path" "$event_ms" "$exit_ms" "$recovery_ms" \
    "$handshake_ms" "$timeout_seconds" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding="utf-8"))
event_ms,exit_ms,recovery_ms,handshake_ms,timeout_ms=map(int,sys.argv[2:7])
timeout_ms*=1000
def require(condition, message):
    if not condition:
        raise SystemExit(f"{message}: {result}")
require(result.get("gate_observed") is True, "non-ping gate was not observed")
require(result.get("timed_out") is False, "non-ping request exceeded outer watchdog")
command=result.get("command", "")
require(command.startswith("docker version ") and "/_ping" not in command, "request was not non-ping")
monitor_started=result.get("monitor_started_monotonic_ms")
request_started=result.get("request_started_monotonic_ms")
require(isinstance(monitor_started, int) and monitor_started <= event_ms, "monitor armed after host edit")
require(isinstance(request_started, int) and request_started >= exit_ms, "request started before old helper exit")
require(request_started == handshake_ms, "request-start handshake disagrees with result")
require(request_started < recovery_ms, "request did not start before independent recovery proof")
require(isinstance(result.get("elapsed_ms"), int), "request elapsed time is missing")
require(result["elapsed_ms"] <= timeout_ms + 1500, "request exceeded bounded latency allowance")
require(isinstance(result.get("returncode"), int), "Docker process return code is missing")
PY
}

raw_hv_children_of() {
  ps -axo pid=,ppid=,command= | awk -v parent="$1" \
    '$2 == parent && $0 ~ /\/dory-hv engine([[:space:]]|$)/ { print $1 }'
}

is_doryd_pid() {
  local command
  helper_pid_is_live "$1" || return 1
  command="$(ps -p "$1" -o command= 2>/dev/null || true)"
  case "$command" in */doryd|*/doryd\ *) return 0 ;; *) return 1 ;; esac
}

assert_engine_status_not_false_running() {
  local label="$1" daemon_pid="$2" destination
  local state children child_count
  destination="$EVIDENCE/health/$label.json"
  is_doryd_pid "$daemon_pid" || {
    echo "doryd pid $daemon_pid is not live while capturing $label" >&2
    return 1
  }
  "$DORYDCTL_BIN" --timeout 2 engine status > "$destination"
  state="$(python3 - "$destination" <<'PY'
import json,sys
value=json.load(open(sys.argv[1], encoding="utf-8")).get("state", "unknown")
print(value if isinstance(value, str) else "invalid")
PY
)"
  [ "$state" = "running" ] || return 0
  children="$(raw_hv_children_of "$daemon_pid")"
  child_count="$(printf '%s\n' "$children" | awk 'NF { count++ } END { print count+0 }')"
  if [ "$child_count" -ne 1 ]; then
    {
      printf 'expected_daemon_pid\t%s\n' "$daemon_pid"
      printf 'direct_dory_hv_child_count\t%s\n' "$child_count"
      printf 'direct_dory_hv_child_pids\t%s\n' "$(tsv_field "$children")"
    } > "$EVIDENCE/health/$label-false-running.tsv"
    echo "engine status falsely reported running with $child_count direct dory-hv helpers" >&2
    return 1
  fi
  helper_pid_is_live "$children" && is_raw_hv_pid "$children" || {
    echo "engine status reported running with an invalid dory-hv helper pid $children" >&2
    return 1
  }
}

assert_no_running_containers() {
  local output
  output="$(docker_e ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}')"
  if [ -n "$output" ]; then
    printf '%s\n' "$output" > "$EVIDENCE/unrelated-running-containers.tsv"
    echo "Dory has running containers; refusing a VM-restart test. Stop them and rerun." >&2
    return 1
  fi
}

assert_only_running_container() {
  local expected="$1" output
  output="$(docker_e ps --format '{{.Names}}')"
  [ "$output" = "$expected" ] || {
    printf '%s\n' "$output" > "$EVIDENCE/unexpected-running-containers.txt"
    echo "expected only $expected to be running immediately before fail-stop; saw: $output" >&2
    return 1
  }
}

write_manifest() {
  {
    printf 'key\tvalue\n'
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'started_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'socket\t%s\n' "$(tsv_field "$DORY_SOCK")"
    printf 'image\t%s\n' "$(tsv_field "$IMAGE")"
    printf 'docker_bin\t%s\n' "$(tsv_field "$DOCKER_BIN")"
    printf 'dorydctl_bin\t%s\n' "$(tsv_field "$DORYDCTL_BIN")"
    printf 'work_root\t%s\n' "$(tsv_field "$WORK_ROOT")"
    printf 'outside_root\t%s\n' "$(tsv_field "$OUTSIDE_ROOT")"
    printf 'failstop_timeout_ms\t%s\n' "$FAILSTOP_TIMEOUT_MS"
    printf 'restart_timeout_seconds\t%s\n' "$RESTART_TIMEOUT_SECONDS"
    printf 'nonping_timeout_seconds\t%s\n' "$NONPING_TIMEOUT_SECONDS"
    printf 'replace_count\t%s\n' "$REPLACE_COUNT"
    printf 'hv_log\t%s\n' "$(tsv_field "$HV_LOG")"
    printf 'hv_state_dir\t%s\n' "$(tsv_field "$HV_STATE_DIR")"
    printf 'script_sha256\t%s\n' "$(shasum -a 256 "$0" | awk '{print $1}')"
    printf 'guest_probe_sha256\t%s\n' "$(shasum -a 256 "$GUEST_PROBE_SOURCE" | awk '{print $1}')"
    printf 'nonping_probe_sha256\t%s\n' "$(shasum -a 256 "$NONPING_PROBE_SOURCE" | awk '{print $1}')"
    printf 'git_head\t%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unavailable)"
    printf 'git_worktree\t%s\n' "$([ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && echo dirty || echo clean)"
    printf 'host_uname\t%s\n' "$(tsv_field "$(uname -a)")"
    printf 'host_macos\t%s\n' "$(tsv_field "$(sw_vers 2>/dev/null | tr '\n' ';' || true)")"
  } > "$EVIDENCE/run-manifest.tsv"
}

preflight() {
  local os_name engine_name kernel_name driver_name python_output helper_pid helper_command
  local probe_name="dory-hs-$RUN_SLUG-preflight"
  [ "$(uname -s)" = "Darwin" ] || { echo "this integration harness requires macOS" >&2; return 1; }
  [ -x "$DOCKER_BIN" ] || { echo "docker CLI not found; set DORY_DOCKER_BIN" >&2; return 1; }
  [ -x "$DORYDCTL_BIN" ] || { echo "installed dorydctl not found; pass --dorydctl" >&2; return 1; }
  [ -f "$GUEST_PROBE_SOURCE" ] || { echo "missing guest probe: $GUEST_PROBE_SOURCE" >&2; return 1; }
  [ -f "$NONPING_PROBE_SOURCE" ] || { echo "missing non-ping probe: $NONPING_PROBE_SOURCE" >&2; return 1; }
  [ -S "$DORY_SOCK" ] || { echo "Dory socket is not a Unix socket: $DORY_SOCK" >&2; return 1; }
  [ -S "$FORWARD_SOCK" ] || { echo "raw-HV forward socket is unavailable: $FORWARD_SOCK" >&2; return 1; }
  [ -S "$ACTIVITY_SOCK" ] || { echo "doryd activity socket is unavailable: $ACTIVITY_SOCK" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "host python3 is required" >&2; return 1; }
  [ -x /usr/bin/perl ] || { echo "/usr/bin/perl is required for monotonic deadlines" >&2; return 1; }

  bounded_docker_version preflight || {
    echo "Dory did not answer a bounded non-ping Docker version request" >&2
    return 1
  }
  docker_e version > "$EVIDENCE/docker-version.txt"
  docker_e info > "$EVIDENCE/docker-info.txt"
  docker_e info --format '{{json .}}' > "$EVIDENCE/docker-info.json"
  os_name="$(docker_e info --format '{{.OperatingSystem}}')"
  engine_name="$(docker_e info --format '{{.Name}}')"
  kernel_name="$(docker_e info --format '{{.KernelVersion}}')"
  driver_name="$(docker_e info --format '{{.Driver}}')"
  case "$os_name:$engine_name:$kernel_name:$driver_name" in
    Dory:dory:*:dory|*:*:*dory*:*) ;;
    *)
    echo "socket does not identify as Dory (OS=$os_name name=$engine_name kernel=$kernel_name driver=$driver_name)" >&2
    return 1
    ;;
  esac
  assert_no_running_containers
  docker_e image inspect "$IMAGE" > "$EVIDENCE/image-inspect.json"
  register_container "$probe_name"
  python_output="$(docker_e run --rm --network none --name "$probe_name" --pull never \
    --label "$LABEL_KEY=$RUN_ID" \
    "$IMAGE" python3 -c 'import mmap,sys; print(sys.platform); print("python-probe-ok"); print(f"python-optimize={sys.flags.optimize}"); raise SystemExit(0 if sys.flags.optimize == 0 else 86)')"
  printf '%s\n' "$python_output" > "$EVIDENCE/image-python-preflight.txt"
  printf '%s\n' "$python_output" | grep -q '^linux$'
  printf '%s\n' "$python_output" | grep -q '^python-probe-ok$'
  printf '%s\n' "$python_output" | grep -q '^python-optimize=0$'
  helper_pid="$(capture_health preflight)"
  helper_command="$(ps -p "$helper_pid" -o command= 2>/dev/null || true)"
  printf '%s\n' "$helper_command" > "$EVIDENCE/preflight-helper-command.txt"
  is_raw_hv_pid "$helper_pid" || {
    echo "managed helper pid $helper_pid is not the raw dory-hv tier; this fail-stop suite cannot test dory-vmm" >&2
    return 1
  }
}

prepare_roots() {
  local work_parent_parent
  work_parent_parent="$(dirname "$WORK_PARENT")"
  mkdir -p "$work_parent_parent"
  if [ -L "$WORK_PARENT" ]; then
    echo "work parent must not be a symbolic link: $WORK_PARENT" >&2
    return 1
  fi
  if [ ! -e "$WORK_PARENT" ]; then
    mkdir "$WORK_PARENT"
    chmod 700 "$WORK_PARENT"
  fi
  [ -d "$WORK_PARENT" ] || { echo "work parent is not a directory: $WORK_PARENT" >&2; return 1; }
  LOCK_DIR="$WORK_PARENT/.live-integration-lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "another live host-share run (or a stale lock) exists at $LOCK_DIR" >&2
    return 1
  fi
  LOCK_OWNED=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  WORK_ROOT="$(mktemp -d "$WORK_PARENT/run.XXXXXX")"
  printf '%s\n' "$RUN_ID" > "$WORK_ROOT/$ROOT_OWNERSHIP_FILE"
  OUTSIDE_ROOT="$(mktemp -d "$OUTSIDE_PARENT/dory-hostshare-outside.XXXXXX")"
  printf '%s\n' "$RUN_ID" > "$OUTSIDE_ROOT/$ROOT_OWNERSHIP_FILE"
  SHARE="$WORK_ROOT/share"
  mkdir -p "$SHARE"
  chmod 700 "$WORK_ROOT" "$OUTSIDE_ROOT" "$SHARE"
  cp "$GUEST_PROBE_SOURCE" "$SHARE/.dory-guest-probe.py"
  chmod 500 "$SHARE/.dory-guest-probe.py"
  python3 - "$HOME" "$WORK_ROOT" "$OUTSIDE_ROOT" <<'PY'
import os, sys
home, work, outside = map(os.path.realpath, sys.argv[1:4])
if os.path.commonpath([home, work]) != home:
    raise SystemExit(f"work root is not inside the production home share: {work}")
if os.path.commonpath([home, outside]) == home:
    raise SystemExit(f"containment sentinel must be outside the production home share: {outside}")
if os.stat(work).st_dev != os.stat(outside).st_dev:
    raise SystemExit("work and outside roots are on different filesystems; moved-parent rename would not be atomic")
PY
}

start_probe() {
  local name="$1" mode="$2"
  shift 2
  register_container "$name"
  docker_e run -d --network none --name "$name" --pull never --label "$LABEL_KEY=$RUN_ID" \
    -v "$SHARE:/work" -e DORY_PROBE_ROOT=/work "$@" \
    "$IMAGE" python3 /work/.dory-guest-probe.py "$mode" >/dev/null
}

test_clean_same_inode() {
  local name="dory-hs-$RUN_SLUG-clean" before
  mkdir -p "$SHARE/clean"
  python3 - "$SHARE/clean/value.bin" <<'PY'
import sys
from pathlib import Path
def payload(label, size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
Path(sys.argv[1]).write_bytes(payload("CLEAN-OLD"))
PY
  before="$(capture_health clean-before)"
  start_probe "$name" clean \
    -e DORY_INITIAL_LABEL=CLEAN-OLD -e DORY_EXPECTED_LABEL=CLEAN-NEW -e DORY_PROBE_TIMEOUT=15
  wait_for_log "$name" "DORY_PROBE_READY clean" 10
  python3 - "$SHARE/clean/value.bin" "$EVIDENCE/clean-host-write.json" <<'PY'
import hashlib, json, os, sys
path, evidence = sys.argv[1:3]
def payload(label, size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
before=os.stat(path)
data=payload("CLEAN-NEW")
fd=os.open(path, os.O_WRONLY)
try:
    written=os.pwrite(fd, data, 0)
    os.fsync(fd)
finally:
    os.close(fd)
after=os.stat(path)
assert written == len(data)
assert before.st_ino == after.st_ino
json.dump({"inode_before":before.st_ino,"inode_after":after.st_ino,"sha256":hashlib.sha256(data).hexdigest()},open(evidence,"w"),sort_keys=True,indent=2)
PY
  wait_for_container_exit "$name" 20
  cp "$SHARE/clean/result.json" "$EVIDENCE/clean-guest-result.json"
  python3 - "$SHARE/clean/value.bin" "$EVIDENCE/clean-host-write.json" "$EVIDENCE/clean-guest-result.json" <<'PY'
import hashlib, json, sys
path, host_path, guest_path=sys.argv[1:4]
host=json.load(open(host_path)); guest=json.load(open(guest_path))
data=open(path,"rb").read()
assert hashlib.sha256(data).hexdigest() == host["sha256"] == guest["observed_sha256"]
# FUSE inode numbers are server-assigned node identities, not host st_ino values. Prove stable
# identity independently in each namespace; numeric equality across host and guest is meaningless.
assert host["inode_before"] == host["inode_after"]
assert guest["inode_before"] == guest["inode_after"]
assert guest["samples"] > 0
PY
  require_unchanged_hv "$before" clean-after
  remove_container "$name"
}

test_atomic_old_mmap() {
  local name="dory-hs-$RUN_SLUG-atomic" before
  mkdir -p "$SHARE/atomic"
  rm -f "$SHARE/atomic/go" "$SHARE/atomic/result.json"
  python3 - "$SHARE/atomic/value.bin" <<'PY'
import sys
from pathlib import Path
def payload(label, size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
Path(sys.argv[1]).write_bytes(payload("ATOMIC-OLD"))
PY
  before="$(capture_health atomic-before)"
  start_probe "$name" atomic \
    -e DORY_ORIGINAL_LABEL=ATOMIC-OLD -e DORY_DIRTY_PREFIX=DORY-GUEST-DIRTY-OLD \
    -e DORY_REPLACEMENT_LABEL=ATOMIC-NEW -e DORY_PROBE_TIMEOUT=15
  wait_for_log "$name" "DORY_PROBE_READY atomic" 10
  python3 - "$SHARE/atomic/value.bin" "$EVIDENCE/atomic-host-replacement.json" <<'PY'
import hashlib, json, os, sys
path, evidence=sys.argv[1:3]
def payload(label, size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
old=os.stat(path)
data=payload("ATOMIC-NEW")
temporary=path+".host-replacement"
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
    assert os.write(fd,data)==len(data); os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary,path)
new=os.stat(path)
assert old.st_ino != new.st_ino
json.dump({"old_inode":old.st_ino,"new_inode":new.st_ino,"new_sha256":hashlib.sha256(data).hexdigest()},open(evidence,"w"),sort_keys=True,indent=2)
PY
  : > "$SHARE/atomic/go"
  wait_for_container_exit "$name" 20
  cp "$SHARE/atomic/result.json" "$EVIDENCE/atomic-guest-result.json"
  python3 - "$SHARE/atomic/value.bin" "$EVIDENCE/atomic-host-replacement.json" "$EVIDENCE/atomic-guest-result.json" <<'PY'
import hashlib, json, sys
path, host_path, guest_path=sys.argv[1:4]
host=json.load(open(host_path)); guest=json.load(open(guest_path))
assert guest["old_fd_sha256"] == guest["old_mmap_sha256"] == guest["expected_old_sha256"]
assert guest["fresh_sha256"] == guest["expected_fresh_sha256"] == host["new_sha256"]
assert host["old_inode"] != host["new_inode"]
assert guest["old_inode"] == guest["old_inode_after"]
assert guest["fresh_inode"] != guest["old_inode"]
assert guest["old_nlink"] == 0
assert guest["samples"] > 0 and guest["convergence_ms"] >= 0
assert hashlib.sha256(open(path,"rb").read()).hexdigest() == host["new_sha256"]
PY
  require_unchanged_hv "$before" atomic-after
  remove_container "$name"
}

test_repeated_atomic_replace() {
  local name="dory-hs-$RUN_SLUG-repeated" before
  local probe_timeout_seconds
  # Host replacement pacing is 2ms plus filesystem overhead. Four milliseconds per accepted
  # iteration and a 20s startup/stop margin keeps the guest deadline feasible at the CLI maximum.
  probe_timeout_seconds=$(( 20 + (REPLACE_COUNT + 249) / 250 ))
  mkdir -p "$SHARE/repeated"
  rm -f "$SHARE/repeated/stop" "$SHARE/repeated/result.json"
  printf 'value-000000\n' > "$SHARE/repeated/value.txt"
  before="$(capture_health repeated-before)"
  start_probe "$name" repeated -e "DORY_PROBE_TIMEOUT=$probe_timeout_seconds" \
    -e "DORY_EXPECTED_FINAL_VERSION=$REPLACE_COUNT"
  wait_for_log "$name" "DORY_PROBE_READY repeated" 10
  python3 - "$SHARE/repeated/value.txt" "$REPLACE_COUNT" "$EVIDENCE/repeated-host-replacements.tsv" <<'PY'
import os, sys, time
path, count, evidence=sys.argv[1],int(sys.argv[2]),sys.argv[3]
with open(evidence,"w",encoding="utf-8") as log:
    log.write("iteration\told_inode\tnew_inode\n")
    for index in range(1,count+1):
        old=os.stat(path).st_ino
        temporary=f"{path}.replacement-{index:06d}"
        data=f"value-{index:06d}\n".encode()
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        try:
            assert os.write(fd,data)==len(data)
        finally:
            os.close(fd)
        os.replace(temporary,path)
        new=os.stat(path).st_ino
        if old == new: raise RuntimeError("atomic replacement retained the inode")
        log.write(f"{index}\t{old}\t{new}\n")
        log.flush()
        time.sleep(0.002)
PY
  pause_ms 200
  : > "$SHARE/repeated/stop"
  wait_for_container_exit "$name" "$probe_timeout_seconds"
  cp "$SHARE/repeated/result.json" "$EVIDENCE/repeated-guest-result.json"
  python3 - "$SHARE/repeated/value.txt" "$REPLACE_COUNT" "$EVIDENCE/repeated-guest-result.json" <<'PY'
import json, sys
path, count, result_path=sys.argv[1],int(sys.argv[2]),sys.argv[3]
result=json.load(open(result_path))
expected_payload=f"value-{count:06d}"
def require(condition, message):
    if not condition:
        raise SystemExit(f"{message}: {result}")
require(result.get("stopped") is True, "guest did not observe stop barrier")
require(result.get("samples", 0) >= 50, "too few guest replacement samples")
require(result.get("unique_inode_count", 0) >= 2, "guest never observed replacement identity")
require(result.get("errors") == [], "guest observed filesystem errors")
require(result.get("invalid_payloads") == [], "guest observed a mixed/invalid payload")
require(result.get("violations") == [], "guest observed node reuse or version regression")
require(result.get("expected_final_payload") == expected_payload, "guest expectation mismatch")
require(result.get("final_payload") == expected_payload, "guest did not read exact final value")
require(result.get("final_version") == count, "guest final version mismatch")
observations=result.get("observations", [])
require(bool(observations), "guest recorded no identity/payload observations")
require(observations[0].get("version") == 0, "guest missed the initial version")
versions=[item.get("version") for item in observations]
require(all(isinstance(value, int) for value in versions), "invalid observation version")
require(versions == sorted(versions), "guest replacement versions regressed")
inode_payloads={}
for item in observations:
    inode=item.get("inode"); version=item.get("version")
    require(isinstance(inode, int), "invalid observation inode")
    if inode in inode_payloads and inode_payloads[inode] != version:
        raise SystemExit(f"guest reused inode {inode} for versions {inode_payloads[inode]} and {version}")
    inode_payloads[inode]=version
require(open(path,"rb").read() == f"{expected_payload}\n".encode(), "host final value mismatch")
PY
  require_unchanged_hv "$before" repeated-after
  remove_container "$name"
}

test_hardlink_lifetime() {
  local name="dory-hs-$RUN_SLUG-hardlink" before
  mkdir -p "$SHARE/hardlink"
  rm -f "$SHARE/hardlink/a.txt" "$SHARE/hardlink/b.txt" "$SHARE/hardlink/go1" \
    "$SHARE/hardlink/go2" "$SHARE/hardlink/result.json"
  printf 'DORY-HARDLINK-SENTINEL\n' > "$SHARE/hardlink/a.txt"
  before="$(capture_health hardlink-before)"
  start_probe "$name" hardlink -e DORY_PROBE_TIMEOUT=15
  wait_for_log "$name" "DORY_PROBE_READY hardlink-phase1" 10
  python3 - "$SHARE/hardlink/a.txt" "$SHARE/hardlink/b.txt" "$EVIDENCE/hardlink-phase1.json" <<'PY'
import json, os, sys
a,b,evidence=sys.argv[1:4]
sa,sb=os.stat(a),os.stat(b)
assert sa.st_ino == sb.st_ino and sa.st_nlink == sb.st_nlink == 2
json.dump({"inode":sa.st_ino,"nlink":sa.st_nlink},open(evidence,"w"),sort_keys=True,indent=2)
os.unlink(a)
assert os.stat(b).st_nlink == 1
PY
  : > "$SHARE/hardlink/go1"
  wait_for_log "$name" "DORY_PROBE_READY hardlink-phase2" 10
  rm "$SHARE/hardlink/b.txt"
  : > "$SHARE/hardlink/go2"
  wait_for_container_exit "$name" 20
  cp "$SHARE/hardlink/result.json" "$EVIDENCE/hardlink-guest-result.json"
  python3 - "$EVIDENCE/hardlink-phase1.json" "$EVIDENCE/hardlink-guest-result.json" <<'PY'
import hashlib, json, sys
host=json.load(open(sys.argv[1])); guest=json.load(open(sys.argv[2]))
expected=hashlib.sha256(b"DORY-HARDLINK-SENTINEL\n").hexdigest()
assert host["nlink"] == 2
assert guest["initial_first_inode"] == guest["initial_second_inode"]
assert guest["initial_first_nlink"] == guest["initial_second_nlink"] == 2
assert guest["after_first_unlink_nlink"] == 1
assert guest["survivor_sha256"] == guest["old_fd_after_first_sha256"] == expected
assert guest["old_fd_after_final_sha256"] == expected
assert guest["final_fd_inode"] == guest["initial_first_inode"] and guest["final_fd_nlink"] == 0
assert guest["first_exists"] is False and guest["second_exists"] is False
PY
  require_unchanged_hv "$before" hardlink-after
  remove_container "$name"
}

create_containment_fixtures() {
  python3 - "$SHARE/containment" "$OUTSIDE_ROOT" "$EVIDENCE/containment-expected.json" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
share, outside, evidence=map(Path,sys.argv[1:4])
share.mkdir(parents=True)

def populate(root):
    root.mkdir(parents=True)
    for name in ["read.txt","write.txt","truncate.txt","unlink.txt","rename-out.txt","link-out.txt"]:
        (root/name).write_text(f"SAFE-{name}\n",encoding="utf-8")
    (root/"empty").mkdir()
    os.symlink("read.txt",root/"target-link")

intermediate=outside/"intermediate"
moved=share/"moved"
populate(intermediate); populate(moved)
os.symlink(str(intermediate),share/"intermediate")
for group in ["intermediate","moved"]:
    (share/f"{group}-link-source.txt").write_text(f"LINK-SOURCE-{group}\n",encoding="utf-8")
    (share/f"{group}-rename-source.txt").write_text(f"RENAME-SOURCE-{group}\n",encoding="utf-8")

def manifest(root):
    result=[]
    def visit(base,relative=""):
        for entry in sorted(os.scandir(base),key=lambda item:item.name):
            rel=f"{relative}/{entry.name}".lstrip("/")
            status=entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(status.st_mode):
                result.append({"path":rel,"type":"symlink","target":os.readlink(entry.path)})
            elif stat.S_ISDIR(status.st_mode):
                result.append({"path":rel,"type":"directory"}); visit(entry.path,rel)
            elif stat.S_ISREG(status.st_mode):
                result.append({"path":rel,"type":"file","sha256":hashlib.sha256(Path(entry.path).read_bytes()).hexdigest()})
            else:
                result.append({"path":rel,"type":"other","mode":status.st_mode})
    visit(root)
    return result

json.dump({"intermediate":manifest(intermediate),"moved":manifest(moved)},open(evidence,"w"),sort_keys=True,indent=2)
PY
}

verify_containment() {
  python3 - "$SHARE/containment" "$OUTSIDE_ROOT" "$EVIDENCE/containment-expected.json" \
    "$EVIDENCE/containment-guest-result.json" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
share,outside,expected_path,result_path=map(Path,sys.argv[1:5])
expected=json.load(open(expected_path)); result=json.load(open(result_path))
operations=result.get("operations",[])
required={f"{group}.{op}" for group in ["intermediate","moved"] for op in [
    "read","write","truncate","create","mkdir","symlink","link_into","rename_into",
    "rename_out","link_out","unlink","rmdir","readlink","readdir"]}
keys=[item.get("key") for item in operations]
assert len(keys)==len(required) and set(keys)==required and len(keys)==len(set(keys)), keys
assert all(item.get("outcome") == "os_error" for item in operations), operations
assert all(item.get("expected_denial") is True for item in operations), operations

def manifest(root):
    items=[]
    def visit(base,relative=""):
        for entry in sorted(os.scandir(base),key=lambda item:item.name):
            rel=f"{relative}/{entry.name}".lstrip("/")
            status=entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(status.st_mode): items.append({"path":rel,"type":"symlink","target":os.readlink(entry.path)})
            elif stat.S_ISDIR(status.st_mode): items.append({"path":rel,"type":"directory"}); visit(entry.path,rel)
            elif stat.S_ISREG(status.st_mode): items.append({"path":rel,"type":"file","sha256":hashlib.sha256(Path(entry.path).read_bytes()).hexdigest()})
            else: items.append({"path":rel,"type":"other","mode":status.st_mode})
    visit(root); return items

assert manifest(outside/"intermediate")==expected["intermediate"]
assert manifest(outside/"moved-parent")==expected["moved"]
for group in ["intermediate","moved"]:
    assert (share/f"{group}-link-source.txt").read_text()==f"LINK-SOURCE-{group}\n"
    assert (share/f"{group}-rename-source.txt").read_text()==f"RENAME-SOURCE-{group}\n"
    assert not (share/f"{group}-escaped.txt").exists()
    assert not (share/f"{group}-escaped-link.txt").exists()
assert os.path.islink(share/"moved")
assert os.path.realpath(share/"moved")==str((outside/"moved-parent").resolve())
assert not any(path.name.startswith(".dory-hostfs-stage-") for path in share.rglob("*"))
PY
}

test_containment() {
  local name="dory-hs-$RUN_SLUG-containment" before
  [ ! -e "$SHARE/containment" ] && [ ! -L "$SHARE/containment" ] || {
    echo "unexpected pre-existing containment fixture" >&2
    return 1
  }
  [ ! -e "$OUTSIDE_ROOT/intermediate" ] && [ ! -L "$OUTSIDE_ROOT/intermediate" ] && \
    [ ! -e "$OUTSIDE_ROOT/moved-parent" ] && [ ! -L "$OUTSIDE_ROOT/moved-parent" ] || {
    echo "unexpected pre-existing outside containment fixture" >&2
    return 1
  }
  create_containment_fixtures
  before="$(capture_health containment-before)"
  start_probe "$name" containment -e DORY_PROBE_TIMEOUT=20
  wait_for_log "$name" "DORY_PROBE_READY containment-moved" 15
  python3 - "$SHARE/containment/moved" "$OUTSIDE_ROOT/moved-parent" <<'PY'
import os, sys
source,destination=sys.argv[1:3]
os.rename(source,destination)
os.symlink(destination,source)
PY
  docker_e exec "$name" touch /tmp/dory-containment-go
  wait_for_container_exit "$name" 25
  cp "$SHARE/containment/result.json" "$EVIDENCE/containment-guest-result.json"
  verify_containment
  require_unchanged_hv "$before" containment-after
  remove_container "$name"
}

test_stdin_passthrough() {
  local sentinel="dory-stdin-$RUN_SLUG" output name="dory-hs-$RUN_SLUG-stdin"
  register_container "$name"
  output="$(printf '%s\n' "$sentinel" | docker_e run --rm -i --network none --name "$name" --pull never \
    --label "$LABEL_KEY=$RUN_ID" "$IMAGE" cat)"
  [ "$output" = "$sentinel" ] || {
    echo "stdin round trip mismatch: expected $sentinel, got $output" >&2
    return 1
  }
  printf '%s\n' "$output" > "$EVIDENCE/stdin-result.txt"
}

run_watcher_round() {
  local round="$1" name="dory-hs-$RUN_SLUG-watch-$1" directory="watch-$1"
  local sentinel="DORY-WATCH-$RUN_SLUG-$1" result="watch-result-$1.json" before
  before="$(capture_health "watcher-$round-before")"
  mkdir -p "$SHARE/$directory"
  printf 'old-modify\n' > "$SHARE/$directory/modify.txt"
  printf 'delete-me\n' > "$SHARE/$directory/delete.txt"
  printf '%s\n' "$sentinel" > "$SHARE/$directory/rename-source.txt"
  printf 'old-atomic\n' > "$SHARE/$directory/atomic.txt"
  rm -f "$SHARE/$directory/created.txt" "$SHARE/$directory/rename-destination.txt" "$SHARE/$result"
  start_probe "$name" watcher -e "DORY_WATCH_DIRECTORY=$directory" \
    -e "DORY_WATCH_RESULT=$result" -e "DORY_WATCH_SENTINEL=$sentinel" -e DORY_PROBE_TIMEOUT=20
  wait_for_log "$name" "DORY_PROBE_READY watcher" 10
  python3 - "$SHARE/$directory" "$sentinel" "$EVIDENCE/watcher-$round-host-operations.tsv" <<'PY'
import os, sys, time
root,sentinel,evidence=sys.argv[1:4]
data=(sentinel+"\n").encode()
with open(evidence,"w",encoding="utf-8") as log:
    log.write("operation\tpath\n")
    fd=os.open(os.path.join(root,"modify.txt"),os.O_WRONLY|os.O_TRUNC)
    try: assert os.write(fd,data)==len(data); os.fsync(fd)
    finally: os.close(fd)
    log.write("same-inode-modify\tmodify.txt\n"); log.flush(); time.sleep(0.1)
    fd=os.open(os.path.join(root,"created.txt"),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try: assert os.write(fd,data)==len(data); os.fsync(fd)
    finally: os.close(fd)
    log.write("create\tcreated.txt\n"); log.flush(); time.sleep(0.1)
    os.unlink(os.path.join(root,"delete.txt"))
    log.write("delete\tdelete.txt\n"); log.flush(); time.sleep(0.1)
    os.rename(os.path.join(root,"rename-source.txt"),os.path.join(root,"rename-destination.txt"))
    log.write("rename\trename-source.txt -> rename-destination.txt\n"); log.flush(); time.sleep(0.1)
    temporary=os.path.join(root,".atomic-host-save")
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try: assert os.write(fd,data)==len(data); os.fsync(fd)
    finally: os.close(fd)
    os.replace(temporary,os.path.join(root,"atomic.txt"))
    log.write("atomic-save\tatomic.txt\n"); log.flush()
PY
  wait_for_container_exit "$name" 30
  cp "$SHARE/$result" "$EVIDENCE/watcher-$round-guest-result.json"
  python3 - "$EVIDENCE/watcher-$round-guest-result.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1]))
assert result["complete"] is True, result
assert result["semantics"] and all(result["semantics"].values()), result
assert result["coverage"] and all(result["coverage"].values()), result
assert len(result["events"]) >= 6, result
PY
  require_unchanged_hv "$before" "watcher-$round-after"
  remove_container "$name"
}

test_watcher_round_one() { run_watcher_round 1; }
test_watcher_round_two() { run_watcher_round 2; }

wait_for_old_helper_exit() {
  local pid="$1" start_ms="$2" deadline
  deadline=$(( start_ms + FAILSTOP_TIMEOUT_MS ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    if ! helper_pid_is_live "$pid"; then
      now_ms
      return 0
    fi
    pause_ms 10
  done
  echo "old dory-hv pid $pid remained alive beyond ${FAILSTOP_TIMEOUT_MS}ms" >&2
  return 1
}

poll_recovered_helper() {
  local old_pid="$1" start_ms="$2" expected_daemon_pid="$3" deadline
  local current="$EVIDENCE/health/recovery-engine-status-current.json"
  local state pid now status_code docker_ping children child_count official_pid official_daemon recovered_at
  deadline=$(( start_ms + RESTART_TIMEOUT_SECONDS * 1000 ))
  printf 'monotonic_ms\tstate\thv_pid\tdaemon_pid\tengine_status_exit\tdocker_ping\n' \
    > "$EVIDENCE/recovery-trace.tsv"
  while [ "$(now_ms)" -lt "$deadline" ]; do
    now="$(now_ms)"
    if ! is_doryd_pid "$expected_daemon_pid"; then
      echo "doryd pid $expected_daemon_pid exited during helper recovery" >&2
      return 1
    fi
    set +e
    "$DORYDCTL_BIN" --timeout 2 engine status > "$current" \
      2> "$EVIDENCE/health/recovery-engine-status-current.stderr"
    status_code=$?
    set -e
    state="unavailable"; pid=""
    if [ "$status_code" -eq 0 ]; then
      state="$(python3 - "$current" <<'PY' 2>/dev/null || true
import json,sys
value=json.load(open(sys.argv[1], encoding="utf-8")).get("state", "unknown")
print(value if isinstance(value, str) else "invalid")
PY
)"
      if [ "$state" = "running" ]; then
        children="$(raw_hv_children_of "$expected_daemon_pid")"
        child_count="$(printf '%s\n' "$children" | awk 'NF { count++ } END { print count+0 }')"
        if [ "$child_count" -ne 1 ]; then
          cp "$current" "$EVIDENCE/health/false-running-without-helper.json"
          {
            printf 'expected_daemon_pid\t%s\n' "$expected_daemon_pid"
            printf 'direct_dory_hv_child_count\t%s\n' "$child_count"
            printf 'direct_dory_hv_child_pids\t%s\n' "$(tsv_field "$children")"
          } > "$EVIDENCE/health/false-running-processes.tsv"
          echo "engine status falsely reported running with $child_count direct dory-hv helpers" >&2
          return 1
        fi
        pid="$children"
        if ! helper_pid_is_live "$pid" || ! is_raw_hv_pid "$pid"; then
          cp "$current" "$EVIDENCE/health/false-running-with-dead-helper.json"
          echo "engine status falsely reported running with an invalid dory-hv helper pid $pid" >&2
          return 1
        fi
      fi
    fi
    docker_ping=fail
    if [ "$state" = "running" ] && [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && \
       is_raw_hv_pid "$pid" && \
       bounded_docker_version recovery; then
      docker_ping=pass
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$now" "$state" "$pid" "$expected_daemon_pid" "$status_code" "$docker_ping" \
      >> "$EVIDENCE/recovery-trace.tsv"
    if [ "$docker_ping" = "pass" ]; then
      cp "$current" "$EVIDENCE/health/recovery-engine-status-success.json"
      official_pid="$(capture_health recovery-success)"
      official_daemon="$(health_daemon_pid "$EVIDENCE/health/recovery-success.json")"
      [ "$official_pid" = "$pid" ] && [ "$official_daemon" = "$expected_daemon_pid" ] || {
        echo "full health disagreed with the recovered process tree" >&2
        return 1
      }
      recovered_at="$(now_ms)"
      printf '%s\t%s\n' "$pid" "$recovered_at"
      return 0
    fi
    pause_ms 100
  done
  echo "Dory did not recover a new healthy helper within ${RESTART_TIMEOUT_SECONDS}s" >&2
  return 1
}

test_dirty_failstop() {
  local name="dory-hs-$RUN_SLUG-dirty" old_pid new_pid event_ms exit_ms recovery_ms
  local recovered log_path="$HV_LOG" log_bytes=0 post_name="dory-hs-$RUN_SLUG-post-restart"
  local daemon_pid daemon_after old_dory_identity old_forward_identity old_activity_identity
  local nonping_gate="$EVIDENCE/nonping-request.gate" nonping_result="$EVIDENCE/nonping-request.json"
  local nonping_ready="$EVIDENCE/nonping-request.json.ready" nonping_started="$EVIDENCE/nonping-request.json.started"
  local nonping_code ready_deadline request_start_deadline request_start_ms
  local recovery_result="$EVIDENCE/recovery-probe-result.tsv" recovery_code
  local gate_timeout_seconds=$(( (FAILSTOP_TIMEOUT_MS + 999) / 1000 + 10 ))

  assert_no_running_containers
  mkdir -p "$SHARE/dirty"
  python3 - "$SHARE/dirty/value.bin" <<'PY'
import sys
from pathlib import Path
def payload(label,size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
Path(sys.argv[1]).write_bytes(payload("DIRTY-ORIGINAL"))
PY
  old_pid="$(capture_health dirty-before)"
  daemon_pid="$(health_daemon_pid "$EVIDENCE/health/dirty-before.json")"
  is_raw_hv_pid "$old_pid" || {
    echo "dirty fail-stop case requires a managed raw dory-hv helper" >&2
    return 1
  }
  if [ -f "$log_path" ]; then
    log_bytes="$(wc -c < "$log_path" | tr -d '[:space:]')"
    tail -c 1048576 "$log_path" > "$EVIDENCE/dory-hv-before-dirty.tail.log"
  fi
  start_probe "$name" dirty -e DORY_ORIGINAL_LABEL=DIRTY-ORIGINAL -e DORY_DIRTY_LIFETIME=180
  wait_for_log "$name" "DORY_PROBE_READY dirty-mmap" 10
  assert_only_running_container "$name"
  old_dory_identity="$(socket_identity "$DORY_SOCK")"
  old_forward_identity="$(socket_identity "$FORWARD_SOCK")"
  old_activity_identity="$(socket_identity "$ACTIVITY_SOCK")"
  {
    printf 'endpoint\tidentity\n'
    printf 'dory\t%s\n' "$old_dory_identity"
    printf 'forward\t%s\n' "$old_forward_identity"
    printf 'activity\t%s\n' "$old_activity_identity"
  } > "$EVIDENCE/pre-failstop-endpoint-identities.tsv"
  rm -f "$nonping_gate" "$nonping_result" "$nonping_ready" "$nonping_started"
  python3 "$NONPING_PROBE_SOURCE" "$nonping_gate" "$DOCKER_BIN" "$DORY_SOCK" \
    "$NONPING_TIMEOUT_SECONDS" "$gate_timeout_seconds" "$nonping_result" &
  NONPING_PROBE_PID=$!
  trap cleanup_failstop_probes EXIT
  ready_deadline=$(( $(now_ms) + 3000 ))
  while [ ! -f "$nonping_ready" ] && [ "$(now_ms)" -lt "$ready_deadline" ]; do
    kill -0 "$NONPING_PROBE_PID" 2>/dev/null || {
      wait "$NONPING_PROBE_PID" 2>/dev/null || true
      NONPING_PROBE_PID=""
      echo "bounded non-ping monitor exited before arming" >&2
      return 1
    }
    pause_ms 5
  done
  [ -f "$nonping_ready" ] || {
    echo "bounded non-ping monitor did not arm within 3000ms" >&2
    return 1
  }
  python3 - "$SHARE/dirty/value.bin" "$EVIDENCE/dirty-host-write.json" <<'PY'
import hashlib,json,os,sys,time
path,evidence=sys.argv[1:3]
def payload(label,size=4096):
    seed=(label+"\n").encode(); return (seed*((size+len(seed)-1)//len(seed)))[:size]
data=payload("DIRTY-HOST-WINS")
before=os.stat(path)
fd=os.open(path,os.O_WRONLY)
try:
    # Python's time.monotonic() maps to mach_continuous_time() on macOS, while the shell's
    # deadline helper uses POSIX CLOCK_MONOTONIC. Record this timestamp in the latter domain so
    # the fail-stop and recovery latency proofs compare like with like.
    event_monotonic_ms=time.clock_gettime_ns(time.CLOCK_MONOTONIC)//1_000_000
    assert os.pwrite(fd,data,0)==len(data); os.fsync(fd)
finally: os.close(fd)
after=os.stat(path)
assert before.st_ino==after.st_ino
json.dump({"event_monotonic_ms":event_monotonic_ms,"inode_before":before.st_ino,"inode_after":after.st_ino,"sha256":hashlib.sha256(data).hexdigest()},open(evidence,"w"),sort_keys=True,indent=2)
PY
  event_ms="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["event_monotonic_ms"])' \
    "$EVIDENCE/dirty-host-write.json")"
  exit_ms="$(wait_for_old_helper_exit "$old_pid" "$event_ms")"
  rm -f "$recovery_result"
  poll_recovered_helper "$old_pid" "$event_ms" "$daemon_pid" > "$recovery_result" &
  RECOVERY_PROBE_PID=$!
  : > "$nonping_gate"
  request_start_deadline=$(( $(now_ms) + 3000 ))
  while [ ! -f "$nonping_started" ] && [ "$(now_ms)" -lt "$request_start_deadline" ]; do
    kill -0 "$NONPING_PROBE_PID" 2>/dev/null || {
      wait "$NONPING_PROBE_PID" 2>/dev/null || true
      NONPING_PROBE_PID=""
      echo "bounded non-ping monitor exited before starting its Docker request" >&2
      return 1
    }
    pause_ms 5
  done
  [ -f "$nonping_started" ] || {
    echo "bounded non-ping Docker request did not start within 3000ms of helper exit" >&2
    return 1
  }
  request_start_ms="$(tr -d '[:space:]' < "$nonping_started")"
  case "$request_start_ms" in ''|*[!0-9]*) echo "invalid non-ping request-start handshake" >&2; return 1 ;; esac
  [ "$request_start_ms" -ge "$exit_ms" ] || {
    echo "non-ping Docker request started before the old helper exited" >&2
    return 1
  }
  assert_engine_status_not_false_running post-failstop-engine-status "$daemon_pid"
  wait_for_old_endpoint_cleanup "$exit_ms" "$old_dory_identity" "$old_forward_identity" \
    "$old_activity_identity"
  python3 - "$SHARE/dirty/value.bin" "$EVIDENCE/dirty-host-write.json" <<'PY'
import hashlib,json,sys
expected=json.load(open(sys.argv[2]))
assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==expected["sha256"]
PY
  set +e
  wait "$NONPING_PROBE_PID"
  nonping_code=$?
  set -e
  NONPING_PROBE_PID=""
  [ "$nonping_code" -eq 0 ] || {
    echo "bounded non-ping request failed its outer watchdog (exit $nonping_code)" >&2
    return 1
  }
  set +e
  wait "$RECOVERY_PROBE_PID"
  recovery_code=$?
  set -e
  RECOVERY_PROBE_PID=""
  [ "$recovery_code" -eq 0 ] || {
    echo "independent helper recovery monitor failed (exit $recovery_code)" >&2
    return 1
  }
  recovered="$(cat "$recovery_result")"
  new_pid="$(printf '%s' "$recovered" | awk -F '\t' '{print $1}')"
  recovery_ms="$(printf '%s' "$recovered" | awk -F '\t' '{print $2}')"
  case "$new_pid:$recovery_ms" in *[!0-9:]*|:*|*:|*:*:*) echo "invalid independent recovery result: $recovered" >&2; return 1 ;; esac
  [ "$new_pid" != "$old_pid" ]
  assert_recovered_endpoints_are_fresh "$old_dory_identity" "$old_forward_identity" \
    "$old_activity_identity"
  daemon_after="$(health_daemon_pid "$EVIDENCE/health/recovery-success.json")"
  [ "$daemon_after" = "$daemon_pid" ] || {
    echo "doryd PID changed across helper fail-stop: $daemon_pid -> $daemon_after" >&2
    return 1
  }
  trap - EXIT
  validate_nonping_window "$nonping_result" "$event_ms" "$exit_ms" "$recovery_ms" \
    "$request_start_ms" "$NONPING_TIMEOUT_SECONDS"
  pause_ms 200
  if [ -f "$log_path" ]; then
    tail -c 4194304 "$log_path" > "$EVIDENCE/dory-hv-after-dirty.tail.log"
    python3 - "$log_path" "$log_bytes" "$EVIDENCE/dory-hv-dirty-delta.log" \
      "$EVIDENCE/dory-hv-dirty-delta-metadata.json" <<'PY'
import json,os,sys
source,offset,destination,metadata=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
limit=16*1024*1024
size=os.path.getsize(source)
reset=size < offset
if reset: offset=0
with open(source,"rb") as handle:
    handle.seek(offset)
    data=handle.read(limit+1)
truncated=len(data)>limit
with open(destination,"wb") as handle:
    handle.write(data[:limit])
with open(metadata,"w",encoding="utf-8") as handle:
    json.dump({"initial_offset":int(sys.argv[2]),"effective_offset":offset,"log_size":size,
               "copied_bytes":min(len(data),limit),"limit_bytes":limit,
               "log_reset":reset,"delta_truncated":truncated},handle,sort_keys=True,indent=2)
    handle.write("\n")
PY
    grep -Fq 'host-share coherence requires VM restart' "$EVIDENCE/dory-hv-dirty-delta.log" || {
      echo "helper PID changed, but the dory-hv log lacks the host-share fail-stop reason" >&2
      return 1
    }
  else
    echo "missing expected installed helper log: $log_path" >&2
    return 1
  fi
  python3 - "$SHARE/dirty/value.bin" "$EVIDENCE/dirty-host-write.json" <<'PY'
import hashlib,json,sys
expected=json.load(open(sys.argv[2]))
data=open(sys.argv[1],"rb").read()
assert hashlib.sha256(data).hexdigest()==expected["sha256"]
assert expected["inode_before"]==expected["inode_after"]
PY
  register_container "$post_name"
  docker_e run --rm --network none --name "$post_name" --pull never \
    --label "$LABEL_KEY=$RUN_ID" -v "$SHARE:/work" \
    -e DORY_EXPECTED_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$EVIDENCE/dirty-host-write.json")" \
    "$IMAGE" python3 -c 'import hashlib,os,sys; sys.flags.optimize == 0 or sys.exit("optimized Python is forbidden"); data=open("/work/dirty/value.bin","rb").read(); actual=hashlib.sha256(data).hexdigest(); actual == os.environ["DORY_EXPECTED_SHA"] or sys.exit("guest digest mismatch"); print(actual)' \
    > "$EVIDENCE/dirty-post-restart-guest-read.txt"
  python3 - "$SHARE/dirty/value.bin" "$EVIDENCE/dirty-host-write.json" <<'PY'
import hashlib,json,sys
expected=json.load(open(sys.argv[2]))
assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==expected["sha256"]
PY
  {
    printf 'metric\tvalue\n'
    printf 'old_hv_pid\t%s\n' "$old_pid"
    printf 'new_hv_pid\t%s\n' "$new_pid"
    printf 'doryd_pid_before\t%s\n' "$daemon_pid"
    printf 'doryd_pid_after\t%s\n' "$daemon_after"
    printf 'host_event_monotonic_ms\t%s\n' "$event_ms"
    printf 'old_helper_exit_monotonic_ms\t%s\n' "$exit_ms"
    printf 'new_helper_ready_monotonic_ms\t%s\n' "$recovery_ms"
    printf 'failstop_latency_ms\t%s\n' "$((exit_ms - event_ms))"
    printf 'recovery_latency_ms\t%s\n' "$((recovery_ms - event_ms))"
  } > "$EVIDENCE/dirty-restart-timing.tsv"
  remove_container "$name" || true
}

echo "Preparing isolated live-test roots and immutable evidence…"
DORYDCTL_BIN="$(resolve_dorydctl)" || { FAIL_REASON=missing_dorydctl; echo "installed dorydctl not found; pass --dorydctl" >&2; exit 1; }
FAIL_REASON=prepare_failed
prepare_roots
FAIL_REASON=unexpected_exit
write_manifest
RESOURCES_STARTED=1
run_case preflight preflight
run_case clean-same-inode-overwrite test_clean_same_inode
run_case dirty-old-mmap-atomic-replacement test_atomic_old_mmap
run_case repeated-atomic-replacement test_repeated_atomic_replace
run_case hardlink-lifetime test_hardlink_lifetime
run_case symlink-and-moved-parent-containment test_containment
run_case stdin-passthrough test_stdin_passthrough
run_case watcher-matrix-round-1 test_watcher_round_one
run_case watcher-matrix-round-2 test_watcher_round_two
run_case dirty-mmap-failstop-and-restart test_dirty_failstop

FINAL_STATUS=pass
FAIL_REASON=complete
echo "live-hostshare-integration: PASS"
echo "raw evidence: $EVIDENCE"
