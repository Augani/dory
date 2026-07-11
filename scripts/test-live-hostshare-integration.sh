#!/bin/bash
# Offline tests only: no Docker socket, installed Dory process, or engine is contacted.
set -euo pipefail

case "${PYTHONOPTIMIZE:-0}" in
  ''|0) ;;
  *) echo "live host-share offline tests require unoptimized Python" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/live-hostshare-integration.sh"
GUEST="$ROOT/scripts/fixtures/hostshare_guest_probe.py"
NONPING="$ROOT/scripts/fixtures/hostshare_nonping_probe.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-hostshare-harness-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
fail() { echo "live host-share harness offline test failed: $*" >&2; exit 1; }

bash -n "$HARNESS"
python3 - "$GUEST" <<'PY'
import errno
import importlib.util
import sys
sys.dont_write_bytecode = True
compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")
spec = importlib.util.spec_from_file_location("dory_hostshare_guest_probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

results = []
probe.attempt(results, "unit", "denied", lambda: (_ for _ in ()).throw(OSError(errno.EACCES, "denied")))
probe.attempt(results, "unit", "resource", lambda: (_ for _ in ()).throw(OSError(errno.EMFILE, "exhausted")))
probe.attempt(results, "unit", "bug", lambda: (_ for _ in ()).throw(RuntimeError("bug")))
probe.attempt(results, "unit", "success", lambda: "escaped")
assert results[0]["outcome"] == "os_error" and results[0]["expected_denial"] is True
assert results[1]["outcome"] == "os_error" and results[1]["expected_denial"] is False
assert results[2]["outcome"] == "unexpected_exception" and results[2]["expected_denial"] is False
assert results[3]["outcome"] == "succeeded" and results[3]["expected_denial"] is False
PY
python3 - "$NONPING" <<'PY'
import sys
compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")
PY

# The fixture builder owns creation of SHARE/containment. Pre-creating it in the case makes
# pathlib.Path.mkdir(parents=True) fail before any containment operation reaches Dory.
python3 - "$HARNESS" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("test_containment() {\n")
end = source.index("\n}\n", start)
case = source[start:end]
assert 'mkdir -p "$SHARE/containment"' not in case
PY

# The live case runs in a `set -euo` case subshell. Its EXIT cleanup must retain access to the
# monitor PID after the test function unwinds; a function-local PID becomes unbound on Bash 3.
python3 - "$HARNESS" "$TMP_ROOT/nonping-cleanup-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("cleanup_nonping_probe() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/nonping-cleanup-early-exit.sh" <<'SH'
#!/bin/bash
set -euo pipefail
NONPING_PROBE_PID=""
cleanup_source="$1"
pid_file="$2"
. "$cleanup_source"
exercise_early_exit() {
  sleep 30 &
  NONPING_PROBE_PID=$!
  printf '%s\n' "$NONPING_PROBE_PID" > "$pid_file"
  trap cleanup_nonping_probe EXIT
  return 1
}
exercise_early_exit
SH
set +e
/bin/bash "$TMP_ROOT/nonping-cleanup-early-exit.sh" \
  "$TMP_ROOT/nonping-cleanup-function.sh" "$TMP_ROOT/nonping-cleanup.pid"
nonping_cleanup_code=$?
set -e
[ "$nonping_cleanup_code" -eq 1 ] || fail "early-exit cleanup returned $nonping_cleanup_code"
nonping_cleanup_pid="$(cat "$TMP_ROOT/nonping-cleanup.pid")"
if kill -0 "$nonping_cleanup_pid" 2>/dev/null; then
  kill -TERM "$nonping_cleanup_pid" 2>/dev/null || true
  fail "early-exit cleanup left monitor pid $nonping_cleanup_pid alive"
fi

python3 - "$HARNESS" "$TMP_ROOT/recovery-cleanup-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("cleanup_recovery_probe() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/recovery-cleanup-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
RECOVERY_PROBE_PID=""
now_ms() { /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f\n", 1000 * clock_gettime(CLOCK_MONOTONIC)'; }
pause_ms() { /usr/bin/perl -MTime::HiRes=usleep -e 'usleep(1000 * shift)' "$1"; }
. "$1"
child_file="$2"
/bin/bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait "$child"' _ "$child_file" \
  > "$child_file.shell.log" 2>&1 &
RECOVERY_PROBE_PID=$!
recovery_pid="$RECOVERY_PROBE_PID"
for _attempt in {1..200}; do [ -f "$child_file" ] && break; sleep 0.01; done
[ -f "$child_file" ]
child_pid="$(cat "$child_file")"
cleanup_recovery_probe
! kill -0 "$recovery_pid" 2>/dev/null
! kill -0 "$child_pid" 2>/dev/null
SH
/bin/bash "$TMP_ROOT/recovery-cleanup-test.sh" "$TMP_ROOT/recovery-cleanup-function.sh" \
  "$TMP_ROOT/recovery-cleanup-child.pid"

# A case must run outside an `||`/`if` test context. Bash disables errexit throughout functions
# invoked from those contexts, even when run_case explicitly enables it in its case subshell.
python3 - "$HARNESS" "$TMP_ROOT/run-case-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("run_case() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/run-case-fail-fast.sh" <<'SH'
#!/bin/bash
set -euo pipefail
test_root="$1"
EVIDENCE="$test_root/evidence"
RESULTS="$EVIDENCE/results.tsv"
FAIL_REASON=""
mkdir -p "$EVIDENCE"
record_result() { :; }
. "$2"
failing_case() {
  : > "$test_root/entered-case"
  false
  : > "$test_root/continued-after-failure"
}
run_case offline-fail-fast failing_case
SH
set +e
/bin/bash "$TMP_ROOT/run-case-fail-fast.sh" "$TMP_ROOT/run-case-test" \
  "$TMP_ROOT/run-case-function.sh" > "$TMP_ROOT/run-case.out" 2> "$TMP_ROOT/run-case.err"
run_case_code=$?
set -e
[ "$run_case_code" -ne 0 ] || fail "run_case swallowed a failing command"
[ -e "$TMP_ROOT/run-case-test/entered-case" ] || \
  fail "run_case aborted in Bash-local setup before entering the requested case"
[ ! -e "$TMP_ROOT/run-case-test/continued-after-failure" ] || \
  fail "run_case continued after a failing command"

# Even if Bash 3.2 supplies a misleading zero status to EXIT after an expansion failure, an
# incomplete harness run must still return nonzero. Exercise the exact cleanup function with all
# external work stubbed so this remains offline.
python3 - "$HARNESS" "$TMP_ROOT/cleanup-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("cleanup() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/cleanup-fail-closed.sh" <<'SH'
#!/bin/bash
set -euo pipefail
EVIDENCE="$1"
RESOURCES_STARTED=0
DOCKER_BIN=""
CREATED_CONTAINERS=""
WORK_ROOT=""
OUTSIDE_ROOT=""
LOCK_OWNED=0
LOCK_DIR=""
FINAL_STATUS=fail
FAIL_REASON=unexpected_exit
snapshot_final_trees() { return 0; }
write_run_status() { printf '%s\n' "$1:$2:$3" > "$EVIDENCE/captured-status"; }
. "$2"
trap cleanup EXIT
true
SH
mkdir -p "$TMP_ROOT/cleanup-fail-closed-evidence"
set +e
/bin/bash "$TMP_ROOT/cleanup-fail-closed.sh" \
  "$TMP_ROOT/cleanup-fail-closed-evidence" "$TMP_ROOT/cleanup-function.sh"
cleanup_fail_closed_code=$?
set -e
[ "$cleanup_fail_closed_code" -eq 1 ] || \
  fail "incomplete zero-status cleanup returned $cleanup_fail_closed_code"
grep -Fxq 'fail:unexpected_exit:1' \
  "$TMP_ROOT/cleanup-fail-closed-evidence/captured-status" || \
  fail "cleanup did not record the forced nonzero incomplete-run status"

FAKE_DOCKER="$TMP_ROOT/fake-docker"
cat > "$FAKE_DOCKER" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DORY_FAKE_DOCKER_CALLS"
if [ -n "${DORY_FAKE_DOCKER_SLEEP:-}" ]; then sleep "$DORY_FAKE_DOCKER_SLEEP"; fi
exit "${DORY_FAKE_DOCKER_EXIT:-99}"
SH
chmod +x "$FAKE_DOCKER"
CALLS="$TMP_ROOT/docker-calls"

offline_harness() {
  DORY_FAKE_DOCKER_CALLS="$CALLS" DORY_DOCKER_BIN="$FAKE_DOCKER" HOME="$TMP_ROOT/home" \
    "$HARNESS" "$@"
}

offline_harness --help > "$TMP_ROOT/help.txt"
grep -q 'Required explicit opt-in' "$TMP_ROOT/help.txt"
grep -q 'intentionally disruptive' "$TMP_ROOT/help.txt"
grep -q -- '--pull never' "$TMP_ROOT/help.txt"
[ ! -e "$CALLS" ] || fail "--help contacted Docker"

offline_harness --list-cases > "$TMP_ROOT/cases.txt"
[ "$(wc -l < "$TMP_ROOT/cases.txt" | tr -d '[:space:]')" -eq 9 ] || fail "case inventory changed unexpectedly"
for expected in \
  clean-same-inode-overwrite \
  dirty-old-mmap-atomic-replacement \
  repeated-atomic-replacement \
  hardlink-lifetime \
  symlink-and-moved-parent-containment \
  stdin-passthrough \
  watcher-matrix-round-1 \
  watcher-matrix-round-2 \
  dirty-mmap-failstop-and-restart; do
  grep -q "$expected" "$TMP_ROOT/cases.txt" || fail "missing case $expected"
done
[ ! -e "$CALLS" ] || fail "--list-cases contacted Docker"

set +e
offline_harness > "$TMP_ROOT/no-run.out" 2> "$TMP_ROOT/no-run.err"
no_run_code=$?
offline_harness --run --list-cases > "$TMP_ROOT/conflict.out" 2> "$TMP_ROOT/conflict.err"
conflict_code=$?
offline_harness --run --failstop-timeout-ms nope > "$TMP_ROOT/number.out" 2> "$TMP_ROOT/number.err"
number_code=$?
offline_harness --run --nonping-timeout-seconds 31 > "$TMP_ROOT/nonping-number.out" 2> "$TMP_ROOT/nonping-number.err"
nonping_number_code=$?
offline_harness --run --replace-count 10001 > "$TMP_ROOT/replace-max.out" 2> "$TMP_ROOT/replace-max.err"
replace_max_code=$?
offline_harness --run --replace-count 999999999999999999 > "$TMP_ROOT/huge.out" 2> "$TMP_ROOT/huge.err"
huge_code=$?
PYTHONOPTIMIZE=1 offline_harness --run > "$TMP_ROOT/optimized.out" 2> "$TMP_ROOT/optimized.err"
optimized_code=$?
PYTHONOPTIMIZE=1 python3 "$GUEST" > "$TMP_ROOT/guest-optimized.out" 2> "$TMP_ROOT/guest-optimized.err"
guest_optimized_code=$?
PYTHONOPTIMIZE=1 python3 "$NONPING" > "$TMP_ROOT/nonping-optimized.out" 2> "$TMP_ROOT/nonping-optimized.err"
nonping_optimized_code=$?
set -e
[ "$no_run_code" -eq 2 ] || fail "missing --run returned $no_run_code"
[ "$conflict_code" -eq 2 ] || fail "--run/--list-cases conflict returned $conflict_code"
[ "$number_code" -eq 2 ] || fail "invalid numeric argument returned $number_code"
[ "$nonping_number_code" -eq 2 ] || fail "oversized non-ping timeout returned $nonping_number_code"
[ "$replace_max_code" -eq 2 ] || fail "oversized replace count returned $replace_max_code"
[ "$huge_code" -eq 2 ] || fail "oversized numeric argument returned $huge_code"
[ "$optimized_code" -eq 2 ] || fail "optimized host Python gate returned $optimized_code"
[ "$guest_optimized_code" -eq 2 ] || fail "optimized guest probe returned $guest_optimized_code"
[ "$nonping_optimized_code" -eq 2 ] || fail "optimized non-ping probe returned $nonping_optimized_code"
grep -q 'without the explicit --run flag' "$TMP_ROOT/no-run.err"
grep -q 'PYTHONOPTIMIZE must be unset or 0' "$TMP_ROOT/optimized.err"
grep -q 'refuses optimized Python' "$TMP_ROOT/guest-optimized.err"
grep -q 'refuses optimized Python' "$TMP_ROOT/nonping-optimized.err"
[ ! -e "$CALLS" ] || fail "an offline rejection contacted Docker"

grep -Fq 'DORY_SOCK:-$HOME/.dory/dory.sock' "$HARNESS" || fail "default Dory socket changed"
grep -Fq -- '--pull never' "$HARNESS" || fail "live runs no longer prohibit pulls"
grep -Fq 'assert_no_running_containers' "$HARNESS" || fail "running-container fail-closed gate missing"
grep -Fq 'host-share coherence requires VM restart' "$HARNESS" || fail "fail-stop attribution check missing"
grep -Fq 'health_daemon_pid' "$HARNESS" || fail "doryd PID continuity check missing"
grep -Fq 'false-running-without-helper.json' "$HARNESS" || fail "false-running health guard missing"
grep -Fq 'assert_engine_status_not_false_running post-failstop-engine-status' "$HARNESS" || \
  fail "immediate post-exit engine-state guard missing"
grep -Fq 'wait_for_old_endpoint_cleanup' "$HARNESS" || fail "stale endpoint cleanup guard missing"
grep -Fq 'hostshare_nonping_probe.py' "$HARNESS" || fail "bounded non-ping regression missing"
grep -Fq 'DORY_EXPECTED_FINAL_VERSION' "$HARNESS" || fail "exact repeated final-value guard missing"
grep -Fq 'endpoint-cleanup-proof.tsv' "$HARNESS" || fail "endpoint transition proof missing"
grep -Fq 'PYTHONOPTIMIZE must be unset or 0' "$HARNESS" || fail "optimized Python gate missing"
grep -Fq '20 + (REPLACE_COUNT + 249) / 250' "$HARNESS" || \
  fail "replace-count-derived guest timeout missing"
grep -Fq 'bounded_docker_version cleanup-initial' "$HARNESS" || \
  fail "cleanup can regress to an unbounded Docker request"
grep -Fq 'bounded_docker_version recovery' "$HARNESS" || \
  fail "recovery can regress to an unbounded Docker request"
if grep -Eq '^[[:space:]]*run_case[[:space:]].*\|\|' "$HARNESS"; then
  fail "run_case must not execute in Bash's errexit-ignored OR-list context"
fi
if grep -Eq '^[[:space:]]*prepare_roots[[:space:]].*\|\|' "$HARNESS"; then
  fail "prepare_roots must not execute in Bash's errexit-ignored OR-list context"
fi
if grep -Eq '^[[:space:]]*local[[:space:]].*NONPING_PROBE_PID' "$HARNESS"; then
  fail "non-ping monitor PID must outlive the dirty-case function for EXIT cleanup"
fi
if grep -Eq '^[[:space:]]*local[[:space:]].*RECOVERY_PROBE_PID' "$HARNESS"; then
  fail "recovery monitor PID must outlive the dirty-case function for EXIT cleanup"
fi
if grep -Eq 'host\["[^"]*inode[^"]*"\].*==.*guest\["[^"]*inode[^"]*"\]' "$HARNESS"; then
  fail "host st_ino must not be compared numerically with synthetic FUSE inode values"
fi
if grep -Eq 'declare[[:space:]]+-A|(^|[^[:alnum:]_])mapfile([^[:alnum:]_]|$)|(^|[^[:alnum:]_])readarray([^[:alnum:]_]|$)|\$\{[^}]+,,\}' "$HARNESS"; then
  fail "Bash 4-only syntax found"
fi
# Bash 3.2 expands a complete `local` command before publishing any variable declared by it.
# Reject declarations such as `local name="$1" log=".../$name"`, which become unbound under
# `set -u`; derived assignments must be placed on a following line.
python3 - "$HARNESS" <<'PY'
import re
import sys

for number, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    match = re.match(r"\s*local\s+(.*)$", line)
    if not match:
        continue
    declaration = match.group(1)
    assignments = list(re.finditer(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=", declaration))
    for assignment in assignments:
        name = assignment.group(1)
        if re.search(r"\$\{?" + re.escape(name) + r"(?:\}|\b)", declaration[assignment.end():]):
            raise SystemExit(
                f"Bash 3.2 local-order hazard at {sys.argv[1]}:{number}: {name}"
            )
PY
python3 - "$HARNESS" <<'PY'
import sys
source=open(sys.argv[1], encoding="utf-8").read().split("test_dirty_failstop()", 1)[1]
recovery_start=source.index('poll_recovered_helper "$old_pid" "$event_ms" "$daemon_pid" > "$recovery_result" &')
gate=source.index(': > "$nonping_gate"')
request_started=source.index('[ -f "$nonping_started" ]')
state=source.index("assert_engine_status_not_false_running post-failstop-engine-status")
cleanup=source.index("wait_for_old_endpoint_cleanup")
recovery_wait=source.index('wait "$RECOVERY_PROBE_PID"')
assert recovery_start < gate < request_started < state < cleanup < recovery_wait
assert source.count("poll_recovered_helper") == 1
PY

# Exercise the exact timing oracle: a request between helper exit and independent recovery proof
# passes, while a request observed after recovery or before old-helper exit fails closed.
python3 - "$HARNESS" "$TMP_ROOT/nonping-window-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("validate_nonping_window() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/nonping-window-result.json" <<'JSON'
{
  "command": "docker version --format {{.Server.Version}}",
  "elapsed_ms": 10,
  "gate_observed": true,
  "monitor_started_monotonic_ms": 90,
  "request_started_monotonic_ms": 120,
  "returncode": 1,
  "timed_out": false
}
JSON
. "$TMP_ROOT/nonping-window-function.sh"
validate_nonping_window "$TMP_ROOT/nonping-window-result.json" 100 110 130 120 5
set +e
validate_nonping_window "$TMP_ROOT/nonping-window-result.json" 100 110 119 120 5 \
  > "$TMP_ROOT/nonping-after-recovery.out" 2> "$TMP_ROOT/nonping-after-recovery.err"
after_recovery_code=$?
validate_nonping_window "$TMP_ROOT/nonping-window-result.json" 100 121 130 120 5 \
  > "$TMP_ROOT/nonping-before-exit.out" 2> "$TMP_ROOT/nonping-before-exit.err"
before_exit_code=$?
set -e
[ "$after_recovery_code" -ne 0 ] || fail "non-ping timing oracle accepted request after recovery"
[ "$before_exit_code" -ne 0 ] || fail "non-ping timing oracle accepted request before old-helper exit"

# A final socket may legitimately receive the same st_ino after the old socket was observed absent
# or replaced. Exercise the exact recovered-endpoint validator with reused final numbers, then prove
# it still rejects a proof that never left the old identity.
python3 - "$HARNESS" "$TMP_ROOT/recovered-endpoint-function.sh" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
start = source.index("assert_recovered_endpoints_are_fresh() {\n")
end = source.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write(source[start:end])
PY
cat > "$TMP_ROOT/recovered-endpoint-reuse.sh" <<'SH'
#!/bin/bash
set -euo pipefail
EVIDENCE="$1"
DORY_SOCK=dory
FORWARD_SOCK=forward
ACTIVITY_SOCK=activity
mkdir -p "$EVIDENCE"
socket_identity() {
  case "$1" in
    dory) echo '1:11' ;;
    forward) echo '1:22' ;;
    activity) echo '1:33' ;;
    *) return 1 ;;
  esac
}
. "$2"
cat > "$EVIDENCE/endpoint-cleanup-proof.tsv" <<'EOF'
endpoint	old_identity	transition_identity	transition_monotonic_ms
dory	1:11	absent	100
forward	1:22	1:222	101
activity	1:33	absent	102
EOF
assert_recovered_endpoints_are_fresh '1:11' '1:22' '1:33'
cat > "$EVIDENCE/endpoint-cleanup-proof.tsv" <<'EOF'
endpoint	old_identity	transition_identity	transition_monotonic_ms
dory	1:11	1:11	100
forward	1:22	1:222	101
activity	1:33	absent	102
EOF
set +e
assert_recovered_endpoints_are_fresh '1:11' '1:22' '1:33' >/dev/null 2>&1
invalid_proof_code=$?
set -e
[ "$invalid_proof_code" -ne 0 ]
SH
/bin/bash "$TMP_ROOT/recovered-endpoint-reuse.sh" "$TMP_ROOT/endpoint-evidence" \
  "$TMP_ROOT/recovered-endpoint-function.sh"

# Exercise the exact independently bounded non-ping probe without a Docker socket. A quick
# connection failure is acceptable; an old 210-second backend wait must trip the outer watchdog.
NONPING_GATE="$TMP_ROOT/nonping.gate"
NONPING_RESULT="$TMP_ROOT/nonping-result.json"
: > "$NONPING_GATE"
rm -f "$CALLS" "$NONPING_RESULT.started"
DORY_FAKE_DOCKER_CALLS="$CALLS" python3 "$NONPING" "$NONPING_GATE" "$FAKE_DOCKER" \
  "$TMP_ROOT/missing-dory.sock" 2 2 "$NONPING_RESULT"
python3 - "$NONPING_RESULT" "$NONPING_RESULT.started" "$CALLS" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding="utf-8"))
started=int(open(sys.argv[2], encoding="utf-8").read().strip())
calls=open(sys.argv[3], encoding="utf-8").read()
assert result["gate_observed"] is True and result["timed_out"] is False, result
assert result["command"].startswith("docker version ") and "/_ping" not in result["command"], result
assert result["returncode"] == 99, result
assert result["request_started_monotonic_ms"] == started, result
assert "version --format {{.Server.Version}}" in calls, calls
PY

# The request-start handshake must be causally downstream of the gate, not another copy of the
# monitor-ready marker. Hold the gate closed and observe the exact probe in the intermediate state.
DELAYED_GATE="$TMP_ROOT/nonping-delayed.gate"
DELAYED_RESULT="$TMP_ROOT/nonping-delayed-result.json"
rm -f "$DELAYED_GATE" "$DELAYED_RESULT" "$DELAYED_RESULT.ready" "$DELAYED_RESULT.started" "$CALLS"
DORY_FAKE_DOCKER_CALLS="$CALLS" python3 "$NONPING" "$DELAYED_GATE" "$FAKE_DOCKER" \
  "$TMP_ROOT/missing-dory.sock" 2 2 "$DELAYED_RESULT" &
delayed_probe_pid=$!
for _attempt in {1..200}; do
  [ -f "$DELAYED_RESULT.ready" ] && break
  kill -0 "$delayed_probe_pid" 2>/dev/null || break
  sleep 0.01
done
[ -f "$DELAYED_RESULT.ready" ] || { kill -TERM "$delayed_probe_pid" 2>/dev/null || true; wait "$delayed_probe_pid" 2>/dev/null || true; fail "non-ping probe never armed"; }
[ ! -e "$DELAYED_RESULT.started" ] || { kill -TERM "$delayed_probe_pid" 2>/dev/null || true; wait "$delayed_probe_pid" 2>/dev/null || true; fail "non-ping request started before gate"; }
: > "$DELAYED_GATE"
set +e
wait "$delayed_probe_pid"
delayed_probe_code=$?
set -e
[ "$delayed_probe_code" -eq 0 ] || fail "gated non-ping probe returned $delayed_probe_code"
[ -f "$DELAYED_RESULT.started" ] || fail "non-ping request-start handshake missing after gate"

rm -f "$CALLS" "$NONPING_RESULT"
set +e
DORY_FAKE_DOCKER_CALLS="$CALLS" DORY_FAKE_DOCKER_SLEEP=3 \
  python3 "$NONPING" "$NONPING_GATE" "$FAKE_DOCKER" "$TMP_ROOT/missing-dory.sock" \
  1 2 "$NONPING_RESULT"
nonping_probe_code=$?
set -e
[ "$nonping_probe_code" -eq 124 ] || fail "bounded non-ping timeout returned $nonping_probe_code"
python3 - "$NONPING_RESULT" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding="utf-8"))
assert result["gate_observed"] is True and result["timed_out"] is True, result
assert result["elapsed_ms"] < 3000, result
PY

# Exercise the exact guest fixture's four non-Linux-specific coordination modes on an isolated
# host directory.  Containment and inotify remain live-only because macOS does not implement the
# Linux VFS flags/events those cases are designed to validate.
python3 - "$GUEST" "$TMP_ROOT/guest-offline" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

guest = Path(sys.argv[1])
root = Path(sys.argv[2])
root.mkdir()

def payload(label, size=4096):
    seed = (label + "\n").encode()
    return (seed * ((size + len(seed) - 1) // len(seed)))[:size]

def start(mode, extra=None):
    env = os.environ.copy()
    env["DORY_PROBE_ROOT"] = str(root)
    env["DORY_PROBE_TIMEOUT"] = "5"
    if extra:
        env.update(extra)
    process = subprocess.Popen(
        [sys.executable, str(guest), mode],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    line = process.stdout.readline().strip()
    if "DORY_PROBE_READY" not in line:
        stdout, stderr = process.communicate(timeout=5)
        raise AssertionError((mode, line, stdout, stderr, process.returncode))
    return process

def finish(process):
    stdout, stderr = process.communicate(timeout=8)
    assert process.returncode == 0, (stdout, stderr, process.returncode)

clean = root / "clean"
clean.mkdir()
(clean / "value.bin").write_bytes(payload("CLEAN-OLD"))
process = start("clean", {"DORY_INITIAL_LABEL": "CLEAN-OLD", "DORY_EXPECTED_LABEL": "CLEAN-NEW"})
descriptor = os.open(clean / "value.bin", os.O_WRONLY)
try:
    assert os.pwrite(descriptor, payload("CLEAN-NEW"), 0) == 4096
finally:
    os.close(descriptor)
finish(process)
assert json.load(open(clean / "result.json"))["inode_before"] == os.stat(clean / "value.bin").st_ino

atomic = root / "atomic"
atomic.mkdir()
(atomic / "value.bin").write_bytes(payload("ATOMIC-OLD"))
process = start(
    "atomic",
    {
        "DORY_ORIGINAL_LABEL": "ATOMIC-OLD",
        "DORY_DIRTY_PREFIX": "DORY-GUEST-DIRTY-OLD",
        "DORY_REPLACEMENT_LABEL": "ATOMIC-NEW",
    },
)
temporary = atomic / "replacement"
temporary.write_bytes(payload("ATOMIC-NEW"))
os.replace(temporary, atomic / "value.bin")
(atomic / "go").touch()
finish(process)
atomic_result = json.load(open(atomic / "result.json"))
assert atomic_result["old_fd_sha256"] == atomic_result["expected_old_sha256"]
assert atomic_result["fresh_sha256"] == atomic_result["expected_fresh_sha256"]
assert atomic_result["old_inode"] != atomic_result["fresh_inode"]
assert atomic_result["old_nlink"] == 0 and atomic_result["samples"] > 0

repeated = root / "repeated"
repeated.mkdir()
(repeated / "value.txt").write_text("value-000000\n")
process = start("repeated", {"DORY_EXPECTED_FINAL_VERSION": "100"})
for index in range(1, 101):
    temporary = repeated / f"replacement-{index}"
    temporary.write_text(f"value-{index:06d}\n")
    os.replace(temporary, repeated / "value.txt")
    time.sleep(0.001)
time.sleep(0.05)
(repeated / "stop").touch()
finish(process)
repeated_result = json.load(open(repeated / "result.json"))
assert repeated_result["samples"] > 0 and repeated_result["errors"] == []
assert repeated_result["invalid_payloads"] == []
assert repeated_result["violations"] == []
assert repeated_result["final_payload"] == repeated_result["expected_final_payload"] == "value-000100"
assert repeated_result["final_version"] == 100
assert repeated_result["final_convergence_samples"] > 0
observations = repeated_result["observations"]
assert observations and observations[0]["version"] == 0
versions = [item["version"] for item in observations]
assert versions == sorted(versions)
inode_versions = {}
for item in observations:
    inode = item["inode"]
    assert inode_versions.setdefault(inode, item["version"]) == item["version"]

# Stop-barrier visibility can lead the final value's relay notification. The final oracle must poll
# through that bounded gap instead of taking one racy sample and rejecting a correct backend.
(repeated / "stop").unlink()
(repeated / "result.json").unlink()
(repeated / "value.txt").write_text("value-000000\n")
process = start(
    "repeated",
    {"DORY_EXPECTED_FINAL_VERSION": "1", "DORY_FINAL_CONVERGENCE_TIMEOUT": "1"},
)
(repeated / "stop").touch()
time.sleep(0.05)
temporary = repeated / "delayed-final"
temporary.write_text("value-000001\n")
os.replace(temporary, repeated / "value.txt")
finish(process)
delayed_final = json.load(open(repeated / "result.json"))
assert delayed_final["final_version"] == 1 and delayed_final["violations"] == []
assert delayed_final["final_convergence_samples"] > 1

# The guest must not bless the host's final value indirectly. Give it an unreachable expected final
# version and a short convergence window; the exact probe must fail and retain the mismatch evidence.
(repeated / "stop").unlink()
(repeated / "result.json").unlink()
(repeated / "value.txt").write_text("value-000000\n")
process = start(
    "repeated",
    {"DORY_EXPECTED_FINAL_VERSION": "101", "DORY_FINAL_CONVERGENCE_TIMEOUT": "0.05"},
)
(repeated / "stop").touch()
stdout, stderr = process.communicate(timeout=3)
assert process.returncode == 1, (stdout, stderr, process.returncode)
mismatch = json.load(open(repeated / "result.json"))
assert any(item["kind"] == "wrong_final_guest_payload" for item in mismatch["violations"])

hardlink = root / "hardlink"
hardlink.mkdir()
expected = b"DORY-HARDLINK-SENTINEL\n"
(hardlink / "a.txt").write_bytes(expected)
process = start("hardlink")
assert os.stat(hardlink / "a.txt").st_nlink == os.stat(hardlink / "b.txt").st_nlink == 2
os.unlink(hardlink / "a.txt")
(hardlink / "go1").touch()
line = process.stdout.readline().strip()
assert line == "DORY_PROBE_READY hardlink-phase2", line
os.unlink(hardlink / "b.txt")
(hardlink / "go2").touch()
finish(process)
hardlink_result = json.load(open(hardlink / "result.json"))
digest = hashlib.sha256(expected).hexdigest()
assert hardlink_result["old_fd_after_final_sha256"] == digest
assert hardlink_result["final_fd_nlink"] == 0
PY

echo "live host-share integration harness offline tests passed"
