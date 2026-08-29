#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME="$(mktemp -d /tmp/dory-data-capacity-gate.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT
BIN="$TMP_HOME/bin"
LOG="$TMP_HOME/calls.log"
mkdir -p "$BIN"

cat > "$BIN/dory-hv" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'helper %s\n' "$*" >> "$DORY_TEST_LOG"
[ "${1:-}" = data-drive ] || exit 64
capacity_file="$HOME/.capacity"
capacity="$(cat "$capacity_file" 2>/dev/null || printf 128)"
case "${2:-}" in
  capacity)
    cat <<JSON
{"allocatedBytes":1073741824,"capacityGiB":$capacity,"initialized":true,"logicalBytes":$((capacity * 1024 * 1024 * 1024)),"maximumCapacityGiB":2048,"minimumCapacityGiB":128}
JSON
    ;;
  grow)
    [ "${DORY_TEST_HELPER_FAIL:-0}" != 1 ] || {
      echo "injected capacity growth failure" >&2
      exit 73
    }
    printf '%s\n' "$3" > "$capacity_file"
    capacity="$3"
    cat <<JSON
{"allocatedBytes":1073741824,"capacityGiB":$capacity,"initialized":true,"logicalBytes":$((capacity * 1024 * 1024 * 1024)),"maximumCapacityGiB":2048,"minimumCapacityGiB":128}
JSON
    ;;
  *) exit 64 ;;
esac
SH

cat > "$BIN/dorydctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'ctl %s\n' "$*" >> "$DORY_TEST_LOG"
state_file="$HOME/.engine-state"
state="$(cat "$state_file" 2>/dev/null || printf stopped)"
command="${*: -2:1}"
argument="${*: -1}"
if [ "$command" != engine ]; then exit 64; fi
case "$argument" in
  status) printf '{"state":"%s","detail":"test"}\n' "$state" ;;
  stop) printf 'stopped\n' > "$state_file"; printf '{"ok":true}\n' ;;
  start)
    [ "${DORY_TEST_START_FAIL:-0}" != 1 ] || exit 74
    printf 'running\n' > "$state_file"
    printf '{"ok":true}\n'
    ;;
  *) exit 64 ;;
esac
SH

cat > "$BIN/docker" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$DORY_TEST_LOG"
shift 2
case "${1:-}" in
  ps)
    [ "${DORY_TEST_DOCKER_PS_FAIL:-0}" != 1 ] || exit 75
    printf 'abc123\ndef456\n'
    ;;
  start)
    case "${2:-}" in
      abc123|def456) printf '%s\n' "$2" ;;
      *) exit 76 ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$BIN/dory-hv" "$BIN/dorydctl" "$BIN/docker"

run_dory() {
  HOME="$TMP_HOME" \
    DORY_HV_BIN="$BIN/dory-hv" \
    DORYDCTL_BIN="$BIN/dorydctl" \
    DORY_DOCKER_BIN="$BIN/docker" \
    DORY_SOCK="$TMP_HOME/dory.sock" \
    DORY_TEST_LOG="$LOG" \
    "$REPO_ROOT/scripts/dory" "$@"
}

reset_fixture() {
  printf '128\n' > "$TMP_HOME/.capacity"
  printf '%s\n' "${1:-running}" > "$TMP_HOME/.engine-state"
  : > "$LOG"
}

reset_fixture
run_dory data capacity --json | python3 -c '
import json, sys
record = json.load(sys.stdin)
assert record["capacityGiB"] == 128
assert record["allocatedBytes"] == 1073741824
'
human="$(run_dory data capacity)"
printf '%s\n' "$human" | grep -Fq '128 GiB logical capacity'
printf '%s\n' "$human" | grep -Fq '1.00 GiB physically allocated'

reset_fixture
run_dory data grow 128 --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["capacityGiB"] == 128'
grep -Fxq 'helper data-drive capacity' "$LOG"
[ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
[ "$(cat "$TMP_HOME/.engine-state")" = running ]

reset_fixture
if run_dory data grow 64 >/dev/null 2>"$TMP_HOME/range.err"; then
  echo "capacity gate: below-minimum growth unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'between 128 and 2048 GiB' "$TMP_HOME/range.err"
! grep -q '^ctl ' "$LOG"

reset_fixture
printf '256\n' > "$TMP_HOME/.capacity"
if run_dory data grow 128 >/dev/null 2>"$TMP_HOME/shrink.err"; then
  echo "capacity gate: shrink unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'shrinking is not supported' "$TMP_HOME/shrink.err"
! grep -q '^ctl ' "$LOG"
[ "$(cat "$TMP_HOME/.capacity")" -eq 256 ]

reset_fixture
run_dory data grow 256 --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["capacityGiB"] == 256'
[ "$(cat "$TMP_HOME/.capacity")" -eq 256 ]
[ "$(cat "$TMP_HOME/.engine-state")" = running ]
expected_success="$TMP_HOME/expected-success.log"
cat > "$expected_success" <<'LOG'
helper data-drive capacity
ctl --timeout 5 engine status
docker -H unix://DORY_SOCKET ps -q
ctl --timeout 250 engine stop
helper data-drive grow 256
ctl --timeout 250 engine start
docker -H unix://DORY_SOCKET start abc123
docker -H unix://DORY_SOCKET start def456
LOG
sed "s|$TMP_HOME/dory.sock|DORY_SOCKET|g" "$LOG" > "$TMP_HOME/normalized.log"
cmp "$expected_success" "$TMP_HOME/normalized.log"

reset_fixture
if DORY_TEST_HELPER_FAIL=1 run_dory data grow 256 >/dev/null 2>"$TMP_HOME/grow-failure.err"; then
  echo "capacity gate: injected growth failure unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'injected capacity growth failure' "$TMP_HOME/grow-failure.err"
[ "$(cat "$TMP_HOME/.capacity")" -eq 128 ]
[ "$(cat "$TMP_HOME/.engine-state")" = running ]
grep -Fxq 'ctl --timeout 250 engine start' "$LOG"
grep -Fq 'docker -H ' "$LOG"
grep -Fq ' start abc123' "$LOG"
grep -Fq ' start def456' "$LOG"

for preserved_state in stopped sleeping failed; do
  reset_fixture "$preserved_state"
  run_dory data grow 256 --json >/dev/null
  [ "$(cat "$TMP_HOME/.capacity")" -eq 256 ]
  [ "$(cat "$TMP_HOME/.engine-state")" = "$preserved_state" ]
  grep -Fxq 'ctl --timeout 5 engine status' "$LOG"
  ! grep -q 'engine stop\|engine start\|docker ' "$LOG"
done

reset_fixture starting
if run_dory data grow 256 >/dev/null 2>"$TMP_HOME/starting.err"; then
  echo "capacity gate: transient starting state unexpectedly allowed growth" >&2
  exit 1
fi
grep -Fq 'engine is still starting' "$TMP_HOME/starting.err"
[ "$(cat "$TMP_HOME/.capacity")" -eq 128 ]
[ "$(cat "$TMP_HOME/.engine-state")" = starting ]
! grep -q 'engine stop\|data-drive grow' "$LOG"

reset_fixture
if DORY_TEST_DOCKER_PS_FAIL=1 run_dory data grow 256 >/dev/null 2>"$TMP_HOME/ps-failure.err"; then
  echo "capacity gate: unverifiable running set unexpectedly allowed growth" >&2
  exit 1
fi
grep -Fq 'could not verify running containers' "$TMP_HOME/ps-failure.err"
[ "$(cat "$TMP_HOME/.capacity")" -eq 128 ]
[ "$(cat "$TMP_HOME/.engine-state")" = running ]
! grep -q 'engine stop' "$LOG"

reset_fixture unknown
if run_dory data grow 256 >/dev/null 2>"$TMP_HOME/state-failure.err"; then
  echo "capacity gate: unknown engine state unexpectedly allowed growth" >&2
  exit 1
fi
grep -Fq 'unrecognized engine state' "$TMP_HOME/state-failure.err"
[ "$(cat "$TMP_HOME/.capacity")" -eq 128 ]
[ "$(cat "$TMP_HOME/.engine-state")" = unknown ]
! grep -q 'engine stop\|data-drive grow' "$LOG"

echo "Dory data-drive capacity lifecycle gate passed."
