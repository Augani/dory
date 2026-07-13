#!/bin/bash
# Proves one active published TCP connection survives beyond the competitor's 24-hour failure edge
# while a Dory-style managed machine repeatedly reaches a Docker service through
# host.docker.internal without developing the reported 200/400 ms protocol-latency plateau, and
# independently samples external TCP so VM-to-host packet loss cannot hide behind local success.
set -euo pipefail

SOCKET=""
DOCKER=""
IMAGE=""
DURATION=90000
INTERVAL=30
WORKROOT="${TMPDIR:-/tmp}/dory-long-lived-network"
CONFIRM=""
OUTBOUND_HOST="registry-1.docker.io"
OUTBOUND_PORT=443

usage() {
  cat <<EOF
Usage: scripts/long-lived-network-soak.sh --socket PATH --docker PATH --image REF [options]

Required:
  --socket PATH       Exact isolated Dory Docker socket
  --docker PATH       Exact Docker CLI to qualify
  --image REF         Existing offline Alpine-compatible image with BusyBox nc
  --confirm TOKEN     Must be ISOLATED-ENGINE-LONG-LIVED-TCP

Options:
  --duration SECONDS  Connection lifetime (default: $DURATION; 25 hours)
  --interval SECONDS  Active echo interval (default: $INTERVAL)
  --workroot DIR      Evidence root (default: $WORKROOT)
  --outbound-host HOST External TCP target (default: $OUTBOUND_HOST)
  --outbound-port PORT External TCP port (default: $OUTBOUND_PORT)
  --help              Show this help

The gate creates uniquely named and labeled service/machine containers, keeps one host TCP socket
open for the full duration, and never reconnects that measured connection after it is established.
In parallel, the machine performs repeated HTTP round trips to a second published service port via
host.docker.internal and repeated external TCP connections after fresh IPv4 DNS resolution. An
outer deadline bounds every connect; DNS/connect failures are retained and budgeted. The gate
refuses to run without the exact confirmation token so a 25-hour fixture is not planted on a user
engine by accident.
EOF
}

die() { echo "long-lived network soak: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --duration) need_value "$1" "$#"; DURATION="$2"; shift 2 ;;
    --interval) need_value "$1" "$#"; INTERVAL="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --outbound-host) need_value "$1" "$#"; OUTBOUND_HOST="$2"; shift 2 ;;
    --outbound-port) need_value "$1" "$#"; OUTBOUND_PORT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}

[ "$CONFIRM" = "ISOLATED-ENGINE-LONG-LIVED-TCP" ] \
  || die "requires --confirm ISOLATED-ENGINE-LONG-LIVED-TCP"
[ -n "$SOCKET" ] || die "--socket is required"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -n "$DOCKER" ] || die "--docker is required"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
[ -n "$IMAGE" ] || die "--image is required"
positive_integer duration "$DURATION"
positive_integer interval "$INTERVAL"
printf '%s\n' "$OUTBOUND_HOST" | grep -Eq '^[A-Za-z0-9.-]+$' \
  || die "--outbound-host is invalid"
positive_integer outbound-port "$OUTBOUND_PORT"
[ "$OUTBOUND_PORT" -le 65535 ] || die "--outbound-port must be at most 65535"
command -v python3 >/dev/null || die "python3 is required"

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
bounded() {
  local limit="$1" pid started rc
  shift
  "$@" &
  pid=$!
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}
bounded 10 docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
bounded 10 docker_e image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "required offline image is missing: $IMAGE"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-long-lived-$RUN_ID"
NAME="dory-long-lived-${RUN_ID//[^a-zA-Z0-9]/}"
MACHINE_NAME="$NAME-machine"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/heartbeats.tsv"
MACHINE_RESULTS="$WORKDIR/machine-to-docker-rtt.tsv"
OUTBOUND_RESULTS="$WORKDIR/machine-outbound-tcp.tsv"
MACHINE_FAILURE="$WORKDIR/machine-runner-failure.txt"
MACHINE_HEARTBEAT="$WORKDIR/machine-runner-heartbeat.txt"
MACHINE_COMPLETE="$WORKDIR/machine-runner-complete.txt"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"

cleanup() {
  bounded 15 docker_e rm -f "$MACHINE_NAME" >/dev/null 2>&1 || true
  bounded 15 docker_e rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

read -r free_port service_port <<EOF
$(python3 - <<'PY'
import socket
sockets = []
try:
    for _ in range(2):
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sockets.append(sock)
    print(*(sock.getsockname()[1] for sock in sockets))
finally:
    for sock in sockets:
        sock.close()
PY
)
EOF
service_marker="machine-to-docker-$RUN_ID"
service_marker_bytes="$((${#service_marker} + 1))"

{
  echo "run_id=$RUN_ID"
  echo "owner=$OWNER"
  echo "socket=$SOCKET"
  echo "docker=$DOCKER"
  echo "image=$IMAGE"
  echo "host_port=$free_port"
  echo "machine_service_host=host.docker.internal"
  echo "machine_service_port=$service_port"
  echo "machine_service_route=machine-container-to-published-docker-service"
  echo "machine_service_p99_budget_ms=100"
  echo "machine_service_sustained_budget_ms=150"
  echo "machine_service_sustained_sample_limit=3"
  echo "machine_outbound_host=$OUTBOUND_HOST"
  echo "machine_outbound_port=$OUTBOUND_PORT"
  echo "machine_outbound_failure_budget_per_mille=5"
  echo "machine_outbound_consecutive_failure_limit=2"
  echo "duration_seconds=$DURATION"
  echo "interval_seconds=$INTERVAL"
  echo "started_epoch=$(date +%s)"
} > "$MANIFEST"

# BusyBox nc execs cat for one client. The container loops only after a client closes so it remains
# inspectable at the end; the host measurement itself never reconnects, so any premature close is
# still a hard failure rather than a successful retry. A second published port serves a tiny exact
# HTTP response to the machine-side latency runner without disturbing that persistent connection.
bounded 30 docker_e run -d --name "$NAME" --label "dev.dory.long-lived=$OWNER" \
  -p "127.0.0.1:$free_port:8080" -p "$service_port:8081" "$IMAGE" \
  sh -ec '
    while :; do
      printf "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s\n" "$2" "$1" \
        | nc -l -p 8081
    done &
    while :; do nc -l -p 8080 -e /bin/cat; done
  ' sh "$service_marker" "$service_marker_bytes" > "$WORKDIR/container-id.txt" \
  || die "echo fixture creation failed or exceeded 30 seconds"

# Match the public MachineService runtime shape closely enough to exercise its real network path:
# privileged container, host cgroup namespace, machine label, persistent init process, and a
# detached command doing the protocol work. Dory's create-request rewrite supplies
# host.docker.internal:host-gateway exactly as it does for user machines.
bounded 30 docker_e run -d --name "$MACHINE_NAME" \
  --hostname dory-latency-machine \
  --label "dev.dory.long-lived=$OWNER" \
  --label "dory.machine=alpine" \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -v "$WORKDIR:/evidence" \
  "$IMAGE" tail -f /dev/null > "$WORKDIR/machine-container-id.txt" \
  || die "managed-machine fixture creation failed or exceeded 30 seconds"
bounded 10 docker_e exec "$MACHINE_NAME" sh -ec \
  'getent hosts host.docker.internal >/evidence/machine-service-hosts.txt 2>&1 || nslookup host.docker.internal >/evidence/machine-service-hosts.txt 2>&1' \
  || die "host.docker.internal did not resolve from the managed-machine fixture"
bounded 10 docker_e exec -d "$MACHINE_NAME" sh -ec '
  duration="$1"
  interval="$2"
  port="$3"
  expected="$4"
  outbound_host="$5"
  outbound_port="$6"
  monotonic_ms() { awk '\''{printf "%.0f\n", $1 * 1000}'\'' /proc/uptime; }
  printf "sequence\tepoch\telapsed_seconds\trtt_ms\tstatus\n" > /evidence/machine-to-docker-rtt.tsv
  printf "sequence\tepoch\telapsed_seconds\trtt_ms\tremote_ipv4\tstatus\n" > /evidence/machine-outbound-tcp.tsv
  started_ms="$(monotonic_ms)"
  deadline_ms=$((started_ms + duration * 1000))
  sequence=0
  while [ "$(monotonic_ms)" -lt "$deadline_ms" ]; do
    sequence=$((sequence + 1))
    request_started_ms="$(monotonic_ms)"
    if ! body="$(wget -qO- -T 2 "http://host.docker.internal:$port/health")"; then
      printf "request %s failed at epoch %s\n" "$sequence" "$(date +%s)" > /evidence/machine-runner-failure.txt
      exit 1
    fi
    request_finished_ms="$(monotonic_ms)"
    if [ "$body" != "$expected" ]; then
      printf "request %s returned unexpected bytes\n" "$sequence" > /evidence/machine-runner-failure.txt
      exit 1
    fi
    rtt_ms=$((request_finished_ms - request_started_ms))
    elapsed_ms=$((request_finished_ms - started_ms))
    printf "%s\t%s\t%s.%03d\t%s\tPASS\n" \
      "$sequence" "$(date +%s)" "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))" "$rtt_ms" \
      >> /evidence/machine-to-docker-rtt.tsv
    printf "%s\n" "$(date +%s)" > /evidence/machine-runner-heartbeat.txt.partial
    mv /evidence/machine-runner-heartbeat.txt.partial /evidence/machine-runner-heartbeat.txt
    outbound_started_ms="$(monotonic_ms)"
    outbound_ip="$(nslookup "$outbound_host" 2>/dev/null \
      | awk "/^Address: / && \$2 ~ /^[0-9]+([.][0-9]+){3}\$/{address=\$2} END{print address}")"
    if [ -n "$outbound_ip" ] \
       && timeout -s KILL 8 nc -z -w 5 "$outbound_ip" "$outbound_port" >/dev/null 2>&1; then
      outbound_status=PASS
    else
      outbound_status=FAIL
    fi
    outbound_finished_ms="$(monotonic_ms)"
    outbound_rtt_ms=$((outbound_finished_ms - outbound_started_ms))
    outbound_elapsed_ms=$((outbound_finished_ms - started_ms))
    printf "%s\t%s\t%s.%03d\t%s\t%s\t%s\n" \
      "$sequence" "$(date +%s)" "$((outbound_elapsed_ms / 1000))" \
      "$((outbound_elapsed_ms % 1000))" "$outbound_rtt_ms" "${outbound_ip:-NONE}" \
      "$outbound_status" >> /evidence/machine-outbound-tcp.tsv
    next_sample_ms=$((started_ms + sequence * interval * 1000))
    remaining_ms=$((next_sample_ms - $(monotonic_ms)))
    if [ "$remaining_ms" -gt 0 ]; then
      sleep "$((remaining_ms / 1000)).$((remaining_ms % 1000))"
    fi
  done
  finished_ms="$(monotonic_ms)"
  printf "%s.%03d\n" "$(((finished_ms - started_ms) / 1000))" "$(((finished_ms - started_ms) % 1000))" \
    > /evidence/machine-duration-seconds.txt
  printf "PASS\n" > /evidence/machine-runner-complete.txt
' sh "$DURATION" "$INTERVAL" "$service_port" "$service_marker" \
  "$OUTBOUND_HOST" "$OUTBOUND_PORT" \
  || die "managed-machine latency runner did not start"

python3 - "$free_port" "$DURATION" "$INTERVAL" "$RESULTS" \
  "$MACHINE_FAILURE" "$MACHINE_HEARTBEAT" <<'PY'
import pathlib
import socket
import sys
import time

port, duration, interval = map(int, sys.argv[1:4])
results_path = sys.argv[4]
machine_failure = pathlib.Path(sys.argv[5])
machine_heartbeat = pathlib.Path(sys.argv[6])

# Startup retries happen before measurement. Once this returns, `connection` is never replaced.
startup_deadline = time.monotonic() + 30
while True:
    try:
        connection = socket.create_connection(("127.0.0.1", port), timeout=2)
        break
    except OSError:
        if time.monotonic() >= startup_deadline:
            raise SystemExit("published echo server did not become reachable within 30 seconds")
        time.sleep(0.2)

connection.settimeout(max(2, min(10, interval)))
started_mono = time.monotonic()
started_epoch = int(time.time())
deadline = started_mono + duration
sequence = 0

with connection, open(results_path, "w", encoding="utf-8", buffering=1) as results:
    results.write("sequence\tepoch\telapsed_seconds\tlocal\tremote\tstatus\n")
    local = f"{connection.getsockname()[0]}:{connection.getsockname()[1]}"
    remote = f"{connection.getpeername()[0]}:{connection.getpeername()[1]}"
    while True:
        now = time.monotonic()
        if now >= deadline:
            break
        sequence += 1
        payload = f"dory-long-lived-{started_epoch}-{sequence}\n".encode()
        connection.sendall(payload)
        received = bytearray()
        while len(received) < len(payload):
            chunk = connection.recv(len(payload) - len(received))
            if not chunk:
                raise SystemExit(
                    f"measured TCP connection closed at sequence {sequence} after "
                    f"{time.monotonic() - started_mono:.3f}s"
                )
            received.extend(chunk)
        if received != payload:
            raise SystemExit(f"echo mismatch at sequence {sequence}")
        elapsed = time.monotonic() - started_mono
        results.write(f"{sequence}\t{int(time.time())}\t{elapsed:.3f}\t{local}\t{remote}\tPASS\n")
        if machine_failure.exists():
            raise SystemExit(
                "managed-machine protocol runner failed: "
                + machine_failure.read_text(encoding="utf-8", errors="replace").strip()
            )
        if elapsed > max(5, interval * 2):
            if not machine_heartbeat.exists():
                raise SystemExit("managed-machine protocol runner produced no heartbeat")
            heartbeat_age = time.time() - machine_heartbeat.stat().st_mtime
            if heartbeat_age > interval * 2 + 10:
                raise SystemExit(
                    f"managed-machine protocol runner heartbeat is stale by {heartbeat_age:.1f}s"
                )
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(interval, remaining))

elapsed = time.monotonic() - started_mono
if elapsed < duration:
    raise SystemExit(f"connection measurement ended early after {elapsed:.3f}s")
with open(results_path + ".duration-seconds", "w", encoding="utf-8") as duration_file:
    duration_file.write(f"{elapsed:.3f}\n")
print(f"same-connection active TCP PASS: duration={elapsed:.3f}s heartbeats={sequence}")
PY

wait_for_machine_completion() {
  while [ ! -s "$MACHINE_COMPLETE" ]; do
    [ ! -s "$MACHINE_FAILURE" ] || return 1
    sleep 0.1
  done
}
bounded $((INTERVAL + 30)) wait_for_machine_completion \
  || die "managed-machine protocol runner failed or did not complete after the duration"
grep -qx PASS "$MACHINE_COMPLETE" || die "managed-machine protocol runner did not record PASS"
bounded 10 docker_e inspect -f '{{.State.Running}}' "$MACHINE_NAME" | grep -qx true \
  || die "managed-machine fixture stopped during the latency soak"
bounded 10 docker_e exec "$MACHINE_NAME" true \
  || die "managed-machine exec failed after the latency soak"

bounded 10 docker_e inspect "$NAME" > "$WORKDIR/container-inspect.json" \
  || die "container inspect failed or exceeded 10 seconds after the connection soak"
bounded 10 docker_e exec "$NAME" true \
  || die "container exec failed or exceeded 10 seconds after the connection soak"
heartbeats="$(($(wc -l < "$RESULTS") - 1))"
actual_elapsed="$(cat "$RESULTS.duration-seconds")"
tuple_count="$(awk -F '\t' 'NR > 1 {print $4 "\t" $5}' "$RESULTS" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
[ "$heartbeats" -gt 0 ] || die "connection soak recorded no heartbeats"
[ "$tuple_count" -eq 1 ] || die "connection tuple changed during the measured soak"
beyond_24_hours="$(awk -v elapsed="$actual_elapsed" \
  'BEGIN {if (elapsed > 86400) print "PASS"; else print "NOT_PROVEN"}')"
machine_stats="$(python3 - "$MACHINE_RESULTS" "$OUTBOUND_RESULTS" \
  "$WORKDIR/machine-duration-seconds.txt" "$DURATION" "$INTERVAL" <<'PY'
import csv
import math
import pathlib
import sys

results_path = pathlib.Path(sys.argv[1])
outbound_path = pathlib.Path(sys.argv[2])
duration_path = pathlib.Path(sys.argv[3])
duration = int(sys.argv[4])
interval = int(sys.argv[5])
with results_path.open(newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
assert rows, "managed-machine latency evidence has no samples"
assert all(row.get("status") == "PASS" for row in rows), \
    "managed-machine latency evidence contains a failed sample"
values = [int(row["rtt_ms"]) for row in rows]
assert all(value >= 0 for value in values), "managed-machine latency evidence has a negative RTT"
expected_samples = max(1, duration // interval)
assert len(values) >= max(1, math.floor(expected_samples * 0.90)), \
    f"managed-machine latency evidence is too sparse: {len(values)} < 90% of {expected_samples}"
elapsed = float(duration_path.read_text(encoding="utf-8").strip())
assert elapsed >= duration, f"managed-machine latency measurement ended early after {elapsed:.3f}s"
ordered = sorted(values)
p99 = ordered[max(0, math.ceil(len(ordered) * 0.99) - 1)]
over_100 = sum(value > 100 for value in values)
at_least_200 = sum(value >= 200 for value in values)
allowed_over_100 = max(1, math.floor(len(values) * 0.01))
assert p99 <= 100, f"managed-machine p99 protocol RTT exceeded 100ms: {p99}ms"
assert over_100 <= allowed_over_100, \
    f"managed-machine protocol RTT exceeded 100ms too often: {over_100}/{len(values)}"
run = 0
max_run = 0
for value in values:
    run = run + 1 if value >= 150 else 0
    max_run = max(max_run, run)
assert max_run < 3, \
    f"managed-machine protocol RTT formed a sustained >=150ms plateau ({max_run} samples)"
with outbound_path.open(newline="", encoding="utf-8") as handle:
    outbound_rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(outbound_rows) == len(rows), \
    "managed-machine outbound evidence does not match the local-route sample count"
outbound_successes = sum(row.get("status") == "PASS" for row in outbound_rows)
outbound_failures = len(outbound_rows) - outbound_successes
allowed_outbound_failures = max(1, math.floor(len(outbound_rows) * 0.005))
assert outbound_failures <= allowed_outbound_failures, \
    f"managed-machine outbound TCP failed too often: {outbound_failures}/{len(outbound_rows)}"
failure_run = 0
max_failure_run = 0
for row in outbound_rows:
    failure_run = failure_run + 1 if row.get("status") != "PASS" else 0
    max_failure_run = max(max_failure_run, failure_run)
assert max_failure_run < 2, \
    f"managed-machine outbound TCP had consecutive failures ({max_failure_run})"
assert all(int(row["rtt_ms"]) >= 0 for row in outbound_rows), \
    "managed-machine outbound TCP has a negative RTT"
assert all(
    len(row["remote_ipv4"].split(".")) == 4
    and all(part.isdigit() and 0 <= int(part) <= 255 for part in row["remote_ipv4"].split("."))
    for row in outbound_rows if row.get("status") == "PASS"
), "managed-machine outbound PASS row lacks a valid IPv4 target"
print(f"machine_service_samples={len(values)}")
print(f"machine_service_actual_elapsed_seconds={elapsed:.3f}")
print(f"machine_service_p99_ms={p99}")
print(f"machine_service_max_ms={max(values)}")
print(f"machine_service_over_100ms_samples={over_100}")
print(f"machine_service_200ms_samples={at_least_200}")
print(f"machine_service_max_sustained_150ms_samples={max_run}")
print(f"machine_outbound_samples={len(outbound_rows)}")
print(f"machine_outbound_tcp_successes={outbound_successes}")
print(f"machine_outbound_timeout_samples={outbound_failures}")
print(f"machine_outbound_max_consecutive_failures={max_failure_run}")
PY
)" || die "managed-machine-to-Docker latency evidence failed semantic verification"
{
  echo "status=PASS"
  echo "completed_epoch=$(date +%s)"
  echo "heartbeats=$heartbeats"
  echo "actual_elapsed_seconds=$actual_elapsed"
  echo "unique_connection_tuples=$tuple_count"
  echo "same_tcp_connection=PASS"
  echo "duration_beyond_24_hours=$beyond_24_hours"
  echo "machine_to_docker_service=PASS"
  echo "machine_service_route=host.docker.internal"
  echo "machine_service_regular_200_400ms_plateau=ABSENT"
  echo "machine_outbound_tcp=PASS"
  echo "machine_outbound_failure_budget_per_mille=5"
  echo "machine_outbound_consecutive_failure_limit=2"
  printf '%s\n' "$machine_stats"
} > "$WORKDIR/summary.txt"
echo "long-lived network soak: PASS ($WORKDIR/summary.txt)"
