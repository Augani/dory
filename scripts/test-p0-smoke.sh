#!/bin/bash
# Offline regression tests for p0-smoke's release-candidate CLI selection and wake ordering.
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TEST_ROOT"

DORY_P0_SMOKE_SOURCE_ONLY=1
# shellcheck source=p0-smoke.sh
source scripts/p0-smoke.sh

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PATH_BIN="$TMP_ROOT/path-bin"
APP="$TMP_ROOT/Dory Candidate.app"
EXPLICIT_DOCKER="$TMP_ROOT/explicit-docker"
mkdir -p "$PATH_BIN" "$APP/Contents/Helpers"

for cli in "$PATH_BIN/docker" "$APP/Contents/Helpers/docker" "$APP/Contents/Helpers/dory" "$EXPLICIT_DOCKER"; do
  cat > "$cli" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$cli"
done

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "test-p0-smoke: $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

resolved="$(DORY_DOCKER_BIN= DORY_APP= PATH="$PATH_BIN:/usr/bin:/bin" resolve_docker_bin)"
assert_eq "$PATH_BIN/docker" "$resolved" "PATH fallback"

resolved="$(DORY_DOCKER_BIN= DORY_APP="$APP" PATH="$PATH_BIN:/usr/bin:/bin" resolve_docker_bin)"
assert_eq "$APP/Contents/Helpers/docker" "$resolved" "DORY_APP bundled CLI"

resolved="$(DORY_DOCKER_BIN="$EXPLICIT_DOCKER" DORY_APP="$APP" PATH="$PATH_BIN:/usr/bin:/bin" resolve_docker_bin)"
assert_eq "$EXPLICIT_DOCKER" "$resolved" "explicit DORY_DOCKER_BIN precedence"

MISSING_APP="$TMP_ROOT/Missing.app"
mkdir -p "$MISSING_APP/Contents/Helpers"
if DORY_DOCKER_BIN= DORY_APP="$MISSING_APP" PATH="$PATH_BIN:/usr/bin:/bin" resolve_docker_bin > /dev/null 2> "$TMP_ROOT/missing.err"; then
  echo "test-p0-smoke: DORY_APP without a bundled Docker CLI unexpectedly fell back to PATH" >&2
  exit 1
fi
grep -q 'has no executable bundled Docker CLI' "$TMP_ROOT/missing.err"

resolved="$(DORY_CLI_BIN= DORY_APP="$APP" resolve_dory_cli)"
assert_eq "$APP/Contents/Helpers/dory" "$resolved" "DORY_APP bundled Dory CLI"
if DORY_CLI_BIN= DORY_APP="$MISSING_APP" resolve_dory_cli > /dev/null 2> "$TMP_ROOT/missing-dory.err"; then
  echo "test-p0-smoke: DORY_APP without a bundled Dory CLI unexpectedly used the source CLI" >&2
  exit 1
fi
grep -q 'Dory CLI is not executable' "$TMP_ROOT/missing-dory.err"

WAKE_STATE="$TMP_ROOT/wake-state"
WAKE_LOG="$TMP_ROOT/wake.log"
FAKE_DORY="$TMP_ROOT/fake-dory"
cat > "$FAKE_DORY" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$DORY_FAKE_WAKE_LOG"
case "$*" in
  'engine wake')
    : > "$DORY_FAKE_WAKE_STATE"
    printf '{"ok":true}\n'
    ;;
  'engine sleep --json')
    printf '{"ok":true,"message":"sleep requested"}\n'
    ;;
  'engine status --json')
    if [ -f "$DORY_FAKE_WAKE_STATE" ]; then
      printf '{"state":"running"}\n'
    else
      printf '{"state":"sleeping"}\n'
    fi
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$FAKE_DORY"

DORY_CLI_BIN="$FAKE_DORY" \
  DORY_FAKE_WAKE_STATE="$WAKE_STATE" \
  DORY_FAKE_WAKE_LOG="$WAKE_LOG" \
  wake_engine_and_capture_status "$TMP_ROOT/engine-status.json"

expected_calls="$(printf 'engine wake\nengine status --json')"
assert_eq "$expected_calls" "$(cat "$WAKE_LOG")" "wake/status order"
python3 - "$TMP_ROOT/engine-status.json" <<'PY'
import json
import sys

assert json.load(open(sys.argv[1], encoding="utf-8"))["state"] == "running"
PY

# Exercise the destructive release-only tier entirely against fakes: it must preserve the stopped
# container identity, perform sleep before wake, and demand a healthy /system/df response.
WORKDIR="$TMP_ROOT/stop-wake"
mkdir -p "$WORKDIR"
DORY_CLI_BIN="$FAKE_DORY"
DORY_FAKE_WAKE_STATE="$WAKE_STATE"
DORY_FAKE_WAKE_LOG="$WAKE_LOG"
DORY_SOCK="$TMP_ROOT/dory.sock"
PROJECT="dory-p0-smoke-fixture"
PERSISTENT_CONTAINER=""
STOP_WAKE_STARTED=0
export DORY_FAKE_WAKE_STATE DORY_FAKE_WAKE_LOG
: > "$WAKE_LOG"

docker_e() {
  case "$*" in
    'ps -q') return 0 ;;
    create\ --name\ dory-p0-persist-* ) printf '%s\n' fixture-container-id ;;
    "inspect --format {{.Id}} dory-p0-persist-"*) printf '%s\n' fixture-container-id ;;
    "inspect --format {{ index .Config.Labels \"dev.dory.p0-smoke\" }} dory-p0-persist-"*) printf '%s\n' "$PROJECT" ;;
    "rm dory-p0-persist-"*) return 0 ;;
    *) echo "unexpected fake docker call: $*" >&2; return 1 ;;
  esac
}
curl() {
  local output="" previous=""
  for argument in "$@"; do
    if [ "$previous" = "-o" ]; then output="$argument"; fi
    previous="$argument"
  done
  printf '{"Containers":[{"Id":"fixture-container-id"}]}\n' > "$output"
  printf '200'
}

stop_wake_storage_smoke
expected_calls="$(printf 'engine sleep --json\nengine wake\nengine status --json')"
assert_eq "$expected_calls" "$(cat "$WAKE_LOG")" "release stop/wake order"
[ -z "$PERSISTENT_CONTAINER" ] || { echo "test-p0-smoke: persistent fixture was not cleaned" >&2; exit 1; }

echo "test-p0-smoke: PASS"
