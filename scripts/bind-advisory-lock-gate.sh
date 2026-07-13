#!/bin/bash
# Prove Linux POSIX and BSD advisory locks coordinate across containers on one Dory bind mount.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET=""
DOCKER="docker"
IMAGE=""
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-bind-lock-gate"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/bind-advisory-lock-gate.sh --socket PATH --image REF --confirm TOKEN [options]

Required:
  --socket PATH       Exact isolated Dory Docker socket
  --image REF         Digest-pinned image containing python3
  --confirm TOKEN     Must be ISOLATED-DORY-BIND-LOCKS

Options:
  --docker PATH       Exact Docker CLI (default: docker)
  --workroot DIR      Evidence directory (default: $WORKROOT)
  --help              Show this help

The gate creates a temporary bind fixture beneath the current user's home, labels every owned
container, and never removes unrelated containers or data.
EOF
}

fail() { echo "bind advisory lock gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || fail "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-DORY-BIND-LOCKS ] \
  || fail "requires --confirm ISOLATED-DORY-BIND-LOCKS"
[ -S "$SOCKET" ] || fail "Dory socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || command -v "$DOCKER" >/dev/null || fail "Docker CLI is unavailable: $DOCKER"
case "$DOCKER" in
  */*) ;;
  *) DOCKER="$(command -v "$DOCKER")" ;;
esac
[ -x "$DOCKER" ] || fail "resolved Docker CLI is not executable: $DOCKER"
printf '%s\n' "$IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || fail "--image must be digest-pinned"
for command in cp curl date mkdir mktemp rm shasum sleep; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null \
  || fail "Dory Docker API is not ready"

RUN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LABEL="dev.dory.bind-advisory-lock-gate=$RUN"
BIND_ROOT="$HOME/.dory-bind-lock-gate-$RUN"
EVIDENCE="$WORKROOT/$RUN"
mkdir -p "$BIND_ROOT" "$EVIDENCE"
cp "$ROOT/scripts/bind-advisory-lock-probe.py" "$BIND_ROOT/probe.py"

docker_e() { "$DOCKER" -H "unix://$SOCKET" "$@"; }
container_name() { printf 'dory-bind-lock-%s-%s' "$RUN" "$1"; }
cleanup() {
  set +e
  docker_e ps -aq --filter "label=$LABEL" | while IFS= read -r container; do
    [ -n "$container" ] && docker_e rm -f "$container" >/dev/null 2>&1 || true
  done
  rm -rf "$BIND_ROOT"
}
trap cleanup EXIT INT TERM

run_probe() {
  docker_e run --rm --label "$LABEL" -v "$BIND_ROOT:/shared" "$IMAGE" \
    python3 /shared/probe.py "$@"
}

start_probe() {
  local name="$1"
  shift
  docker_e run -d --name "$(container_name "$name")" --label "$LABEL" \
    -v "$BIND_ROOT:/shared" "$IMAGE" python3 /shared/probe.py "$@" >/dev/null
}

wait_marker() {
  local marker="$1" i
  # The first Python container can still be unpacking immediately after a clean engine boot.
  # Give fixture startup 30 seconds while retaining the 20 ms polling needed by lock handoffs.
  for i in $(seq 1 1500); do
    [ -s "$BIND_ROOT/$marker" ] && return 0
    sleep 0.02
  done
  return 1
}

finish_probe() {
  local name="$1" token="$2" id status
  : > "$BIND_ROOT/$token.release"
  id="$(container_name "$name")"
  status="$(docker_e wait "$id")"
  [ "$status" = 0 ] || fail "$name exited with status $status"
  docker_e rm "$id" >/dev/null
}

expect_blocked() {
  local rc
  set +e
  run_probe "$@" >/dev/null 2>"$EVIDENCE/expected-blocked.stderr"
  rc=$?
  set -e
  [ "$rc" -eq 73 ] || fail "expected lock contention exit 73, got $rc for: $*"
}

# Reproduce Lima's VirtioFS orphan: the creating O_RDONLY descriptor must remain valid even though
# the requested mode is 0000, and unlink must depend on the writable parent rather than file mode.
mkdir -p "$BIND_ROOT/mode-zero"
chmod 0777 "$BIND_ROOT/mode-zero"
docker_e run --rm --user 1000:1000 --label "$LABEL" -v "$BIND_ROOT:/shared" "$IMAGE" \
  python3 /shared/probe.py create-mode-zero
[ ! -e "$BIND_ROOT/mode-zero/create-excl.lock" ] \
  || fail "O_CREAT|O_EXCL mode-0000 probe left an inaccessible orphan"

# BSD flock: exclusive exclusion, shared compatibility, explicit unlock, crash release, and a
# failed shared→exclusive upgrade followed by a successful retry. Linux explicitly does not
# guarantee atomic conversion: the original lock may be removed before the contended replacement
# fails, so the gate must not require a stronger post-failure lock state than native flock(2).
start_probe flock-exclusive holder flock flock.bin exclusive 0 0 flock-exclusive
wait_marker flock-exclusive.ready || fail "exclusive flock holder did not become ready"
expect_blocked try flock flock.bin exclusive 0 0 flock-exclusive-contender
finish_probe flock-exclusive flock-exclusive
run_probe try flock flock.bin exclusive 0 0 flock-after-release

start_probe flock-shared holder flock flock.bin shared 0 0 flock-shared
wait_marker flock-shared.ready || fail "shared flock holder did not become ready"
run_probe try flock flock.bin shared 0 0 flock-shared-peer
expect_blocked try flock flock.bin exclusive 0 0 flock-shared-exclusive
finish_probe flock-shared flock-shared

start_probe flock-unlocked unlocked-holder flock flock.bin exclusive 0 0 flock-unlocked
wait_marker flock-unlocked.ready || fail "explicit-unlock holder did not become ready"
run_probe try flock flock.bin exclusive 0 0 flock-unlocked-peer
finish_probe flock-unlocked flock-unlocked

start_probe flock-crash holder flock flock.bin exclusive 0 0 flock-crash
wait_marker flock-crash.ready || fail "crash-release flock holder did not become ready"
docker_e rm -f "$(container_name flock-crash)" >/dev/null
run_probe try flock flock.bin exclusive 0 0 flock-after-crash

start_probe flock-upgrade upgrade-holder flock flock.bin shared 0 0 flock-upgrade
wait_marker flock-upgrade.ready || fail "upgrade holder did not become ready"
start_probe flock-upgrade-peer holder flock flock.bin shared 0 0 flock-upgrade-peer
wait_marker flock-upgrade-peer.ready || fail "upgrade peer did not become ready"
: > "$BIND_ROOT/flock-upgrade.upgrade"
wait_marker flock-upgrade.blocked || fail "contended flock upgrade did not report blocking"
finish_probe flock-upgrade-peer flock-upgrade-peer
: > "$BIND_ROOT/flock-upgrade.retry"
wait_marker flock-upgrade.upgraded || fail "flock upgrade did not succeed after peer release"
finish_probe flock-upgrade flock-upgrade

# POSIX record locks: same-range exclusion, non-overlapping range independence, blocking SETLKW,
# explicit unlock while the process remains alive, and forced-container crash cleanup.
start_probe record-holder holder record record.bin exclusive 0 8 record-holder
wait_marker record-holder.ready || fail "record-lock holder did not become ready"
expect_blocked try record record.bin exclusive 0 8 record-contender
run_probe try record record.bin exclusive 8 8 record-nonoverlap
start_probe record-waiter waiter record record.bin exclusive 0 8 record-waiter
sleep 0.25
[ ! -e "$BIND_ROOT/record-waiter.acquired" ] \
  || fail "blocking record-lock waiter acquired before owner release"
finish_probe record-holder record-holder
wait_marker record-waiter.acquired || fail "blocking record-lock waiter did not acquire after release"
status="$(docker_e wait "$(container_name record-waiter)")"
[ "$status" = 0 ] || fail "record-lock waiter exited with status $status"
docker_e rm "$(container_name record-waiter)" >/dev/null

start_probe record-unlocked unlocked-holder record record.bin exclusive 0 8 record-unlocked
wait_marker record-unlocked.ready || fail "record explicit-unlock holder did not become ready"
run_probe try record record.bin exclusive 0 8 record-unlocked-peer
finish_probe record-unlocked record-unlocked

start_probe record-crash holder record record.bin exclusive 0 8 record-crash
wait_marker record-crash.ready || fail "record crash-release holder did not become ready"
docker_e rm -f "$(container_name record-crash)" >/dev/null
run_probe try record record.bin exclusive 0 8 record-after-crash

docker_e image inspect "$IMAGE" > "$EVIDENCE/image-inspect.json"
docker_cli_sha256="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
printf '%s\n' "$docker_cli_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "could not hash the exact Docker CLI: $DOCKER"
{
  printf 'status=PASS\n'
  printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'image=%s\n' "$IMAGE"
  printf 'docker_cli_sha256=%s\n' "$docker_cli_sha256"
  printf 'create_excl_readonly_mode0000_unlink=PASS\n'
  printf 'bsd_flock_exclusive_shared_unlock_upgrade_crash=PASS\n'
  printf 'posix_range_nonoverlap_blocking_unlock_crash=PASS\n'
  printf 'cross_container_bind_mount=PASS\n'
} > "$EVIDENCE/manifest.txt"

echo "bind advisory lock gate: PASS ($EVIDENCE)"
