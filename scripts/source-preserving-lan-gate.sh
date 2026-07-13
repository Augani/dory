#!/bin/bash
# Exact-artifact physical-peer certification for Dory's source-preserving LAN publication path.
set -euo pipefail

APP=""
RUNTIME=""
DOCKER=""
HOST_ADDRESS=""
PEER_SSH=""
MODE=""
SERVER_IMAGE=""
WORKROOT=""
CONFIRM=""
PRIVILEGED_PORT="${DORY_SOURCE_LAN_PRIVILEGED_PORT:-80}"
SSH_OPTIONS=()

usage() {
  cat <<'EOF'
Usage: scripts/source-preserving-lan-gate.sh [required options]

  --app Dory.app               Exact signed/notarized candidate app
  --runtime DIR                Exact extracted dory-engine release directory
  --docker PATH                Exact Docker CLI
  --host-address IPv4          This Mac's physical-LAN or Tailscale IPv4 address
  --peer-ssh USER@HOST         Real remote peer reachable with noninteractive SSH
  --mode lan|tailscale         Physical path being certified
  --server-image REF@sha256:X  Digest-pinned image containing python3
  --privileged-port PORT       Free interface-specific TCP port below 1024 (default: 80)
  --workroot DIR               New evidence and isolated-engine root
  --ssh-option VALUE           Repeatable ssh option, such as StrictHostKeyChecking=yes
  --confirm PHYSICAL-SOURCE-PRESERVATION

The exact Dory app must have its embedded LaunchDaemon approved in System Settings. The runner
must allow `sudo -n` for launchctl/pfctl read/restart checks. The peer must have python3.
EOF
}

die() { echo "source-preserving LAN gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) need_value "$1" "$#"; APP="$2"; shift 2 ;;
    --runtime) need_value "$1" "$#"; RUNTIME="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --host-address) need_value "$1" "$#"; HOST_ADDRESS="$2"; shift 2 ;;
    --peer-ssh) need_value "$1" "$#"; PEER_SSH="$2"; shift 2 ;;
    --mode) need_value "$1" "$#"; MODE="$2"; shift 2 ;;
    --server-image) need_value "$1" "$#"; SERVER_IMAGE="$2"; shift 2 ;;
    --privileged-port) need_value "$1" "$#"; PRIVILEGED_PORT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --ssh-option) need_value "$1" "$#"; SSH_OPTIONS+=("-o" "$2"); shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = PHYSICAL-SOURCE-PRESERVATION ] || die "confirmation token is required"
for pair in app:"$APP" runtime:"$RUNTIME" docker:"$DOCKER" host-address:"$HOST_ADDRESS" \
  peer-ssh:"$PEER_SSH" mode:"$MODE" server-image:"$SERVER_IMAGE" workroot:"$WORKROOT"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$MODE" in lan|tailscale) ;; *) die "--mode must be lan or tailscale" ;; esac
case "$PRIVILEGED_PORT" in ''|*[!0-9]*) die "--privileged-port must be an integer" ;; esac
[ "$PRIVILEGED_PORT" -ge 1 ] && [ "$PRIVILEGED_PORT" -lt 1024 ] \
  || die "--privileged-port must be between 1 and 1023"
python3 - "$HOST_ADDRESS" <<'PY' || die "--host-address must be a valid unicast IPv4 address"
import ipaddress, sys
value = ipaddress.IPv4Address(sys.argv[1])
assert not value.is_unspecified and not value.is_multicast and not value.is_loopback
PY
printf '%s\n' "$SERVER_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--server-image must contain one exact lowercase sha256 digest"
case "$PEER_SSH" in -*|*[!A-Za-z0-9_.@:%+-]*) die "--peer-ssh contains unsafe characters" ;; esac
[ "$(uname -s)" = Darwin ] || die "physical certification requires macOS"
[ "$(uname -m)" = arm64 ] || die "physical certification requires Apple Silicon"
[ -d "$APP" ] || die "candidate app is missing: $APP"
APP="$(cd "$APP" && pwd)"
[ -x "$RUNTIME/dory-engine" ] || die "runtime launcher is missing"
RUNTIME="$(cd "$RUNTIME" && pwd)"
[ -x "$DOCKER" ] || die "Docker CLI is missing"
DOCKER="$(cd "$(dirname "$DOCKER")" && pwd)/$(basename "$DOCKER")"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in codesign curl lsof python3 shasum ssh sudo xcrun; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
sudo -n true >/dev/null 2>&1 || die "runner does not provide required noninteractive sudo"

umask 077
mkdir -p "$WORKROOT/evidence" "$WORKROOT/runtime-home"
ENGINE_HOME="$WORKROOT/runtime-home"
SOCKET="$ENGINE_HOME/.dory/engine.sock"
DATA_DRIVE="$ENGINE_HOME/Library/Application Support/Dory/Dory.dorydrive"
OWNER="dory-source-lan-$MODE-$$"
SERVER_NAME="$OWNER-server"
LOOPBACK_NAME="$OWNER-loopback"
PRIVILEGED_NAME="$OWNER-privileged"
PRESSURE_NAME="$OWNER-pressure"
PRESSURE_NETWORK="$OWNER-pressure-net"
PRESSURE_MIB=960
PRESSURE_ROUNDS=20
ENGINE_STARTED=0
HOST_BOOT_EPOCH_BEFORE="$(/usr/sbin/sysctl -n kern.boottime \
  | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
printf '%s\n' "$HOST_BOOT_EPOCH_BEFORE" | grep -Eq '^[0-9]+$' \
  || die "could not capture the host boot epoch"
PANIC_MARKER="$WORKROOT/evidence/host-panic-window-start"
touch "$PANIC_MARKER"
if sudo -n lsof -nP -iTCP@"$HOST_ADDRESS:$PRIVILEGED_PORT" -sTCP:LISTEN \
    > "$WORKROOT/evidence/privileged-port-owner-before.txt" 2>&1; then
  die "interface-specific privileged port is already owned: $HOST_ADDRESS:$PRIVILEGED_PORT"
fi

cleanup() {
  set +e
  if [ -S "$SOCKET" ]; then
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f \
      "$SERVER_NAME" "$LOOPBACK_NAME" "$PRIVILEGED_NAME" "$PRESSURE_NAME" >/dev/null 2>&1 || true
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" network rm "$PRESSURE_NETWORK" \
      >/dev/null 2>&1 || true
  fi
  if [ "$ENGINE_STARTED" -eq 1 ]; then
    HOME="$ENGINE_HOME" "$RUNTIME/dory-engine" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

codesign --verify --strict --deep "$APP"
xcrun stapler validate "$APP" >/dev/null
for helper in dory-hv dory-network-helper gvproxy; do
  codesign --verify --strict "$APP/Contents/Helpers/$helper"
done
codesign -dv --verbose=4 "$APP" 2> "$WORKROOT/evidence/app-signature.txt"
grep -q 'TeamIdentifier=864H636QW4' "$WORKROOT/evidence/app-signature.txt" \
  || die "candidate app has the wrong signing team"
[ -s "$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist" ] \
  || die "candidate app omits the privileged network LaunchDaemon"
cmp "$RUNTIME/bin/dory-hv" "$APP/Contents/Helpers/dory-hv" \
  || die "runtime dory-hv differs from the candidate app"
cmp "$RUNTIME/bin/gvproxy" "$APP/Contents/Helpers/gvproxy" \
  || die "runtime gvproxy differs from the candidate app"

"$APP/Contents/MacOS/Dory" --register-network-helper \
  > "$WORKROOT/evidence/network-helper-registration.txt" 2>&1 \
  || die "the exact app's privileged helper is not enabled/approved"
grep -qx 'network-helper=enabled' "$WORKROOT/evidence/network-helper-registration.txt" \
  || die "the exact app did not confirm its network helper"
sudo -n /sbin/pfctl -s References > "$WORKROOT/evidence/pf-references-before.txt" 2>&1 \
  || die "could not capture the baseline PF enable references"
/usr/sbin/sysctl -n net.inet.ip.forwarding \
  > "$WORKROOT/evidence/ipv4-forwarding-before.txt"

scripts/gvproxy-qemu-switch-gate.py "$APP/Contents/Helpers/gvproxy" \
  --evidence "$WORKROOT/evidence/gvproxy-switch.txt" \
  > "$WORKROOT/evidence/gvproxy-switch.log" 2>&1

python3 - "$WORKROOT/server.py" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(r'''
import socket, threading

def tcp():
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 8080)); server.listen(16)
    while True:
        connection, peer = server.accept()
        token = connection.recv(1024).decode().strip()
        print(f"tcp={peer[0]} token={token}", flush=True)
        connection.sendall((token + "\n").encode()); connection.close()

def udp():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("0.0.0.0", 8080))
    while True:
        payload, peer = server.recvfrom(2048)
        token = payload.decode().strip()
        print(f"udp={peer[0]} token={token}", flush=True)
        server.sendto((token + "\n").encode(), peer)

threading.Thread(target=tcp, daemon=True).start()
udp()
''', encoding="utf-8")
PY

python3 - "$WORKROOT/peer.py" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(r'''
import socket, sys
host, port, loop_port, privileged_port, token, operation = sys.argv[1:]
port = int(port); loop_port = int(loop_port); privileged_port = int(privileged_port)

def tcp_open(target_port, payload=None):
    connection = socket.create_connection((host, target_port), timeout=4)
    source = connection.getsockname()[0]
    if payload is not None:
        connection.sendall((payload + "\n").encode())
        assert connection.recv(1024).decode().strip() == payload
    connection.close()
    return source

if operation == "run":
    print("tcp_source=" + tcp_open(port, token))
    print("privileged_tcp_source=" + tcp_open(privileged_port, token + "-privileged"))
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.settimeout(4)
    udp.connect((host, port)); source = udp.getsockname()[0]
    udp.send((token + "\n").encode()); assert udp.recv(1024).decode().strip() == token
    udp.close(); print("udp_source=" + source)
    try:
        tcp_open(loop_port)
    except OSError:
        print("loopback_isolated=PASS")
    else:
        raise SystemExit("explicit loopback publication was reachable remotely")
elif operation == "closed":
    try:
        tcp_open(port)
    except OSError:
        print("tcp_unpublished=PASS")
    else:
        raise SystemExit("unpublished TCP port remains reachable")
    try:
        tcp_open(privileged_port)
    except OSError:
        print("privileged_tcp_unpublished=PASS")
    else:
        raise SystemExit("unpublished interface-specific privileged TCP port remains reachable")
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.settimeout(2)
    try:
        udp.sendto(b"closed", (host, port)); udp.recvfrom(1024)
    except OSError:
        print("udp_unpublished=PASS")
    else:
        raise SystemExit("unpublished UDP port remains reachable")
''', encoding="utf-8")
PY

pick_port() {
  python3 - <<'PY'
import socket
sock = socket.socket(); sock.bind(("0.0.0.0", 0)); print(sock.getsockname()[1]); sock.close()
PY
}
PORT="$(pick_port)"
LOOPBACK_PORT="$(pick_port)"
[ "$PORT" != "$LOOPBACK_PORT" ] || LOOPBACK_PORT="$(pick_port)"

start_engine() {
  HOME="$ENGINE_HOME" "$RUNTIME/dory-engine" start \
    --lan-visible --data-drive "$DATA_DRIVE" \
    > "$WORKROOT/evidence/runtime-start-$1.log" 2>&1
  ENGINE_STARTED=1
  [ -S "$SOCKET" ] || die "engine socket was not created"
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" version >/dev/null
}

create_fixtures() {
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" network create \
    --label "dev.dory.source-lan=$OWNER" "$PRESSURE_NETWORK" >/dev/null
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull "$SERVER_IMAGE" \
    > "$WORKROOT/evidence/image-pull-$1.txt"
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" run -d --name "$SERVER_NAME" \
    --label "dev.dory.source-lan=$OWNER" \
    --network "$PRESSURE_NETWORK" \
    -p "$PORT:8080/tcp" -p "$PORT:8080/udp" \
    -v "$WORKROOT/server.py:/server.py:ro" \
    "$SERVER_IMAGE" python3 /server.py >/dev/null
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" run -d --name "$LOOPBACK_NAME" \
    --label "dev.dory.source-lan=$OWNER" \
    --network "$PRESSURE_NETWORK" \
    -p "127.0.0.1:$LOOPBACK_PORT:8080/tcp" \
    -v "$WORKROOT/server.py:/server.py:ro" \
    "$SERVER_IMAGE" python3 /server.py >/dev/null
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" run -d --name "$PRIVILEGED_NAME" \
    --label "dev.dory.source-lan=$OWNER" \
    --network "$PRESSURE_NETWORK" \
    -p "$HOST_ADDRESS:$PRIVILEGED_PORT:8080/tcp" \
    -v "$WORKROOT/server.py:/server.py:ro" \
    "$SERVER_IMAGE" python3 /server.py >/dev/null
  sleep 4
}

bounded_capture() {
  local limit="$1" stdout="$2" stderr="$3" pid started rc
  shift 3
  "$@" > "$stdout" 2> "$stderr" &
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

run_memory_pressure_rounds() {
  local expected_source="$1" round observed state
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" run -d --name "$PRESSURE_NAME" \
    --label "dev.dory.source-lan=$OWNER" --network "$PRESSURE_NETWORK" \
    --memory 1280m "$SERVER_IMAGE" python3 -c '
import sys, time
blocks = []
for _ in range(60):
    block = bytearray(16 * 1024 * 1024)
    for offset in range(0, len(block), 4096):
        block[offset] = 1
    blocks.append(block)
print("pressure_ready_mib=960", flush=True)
time.sleep(300)
' >/dev/null
  for _ in $(seq 1 100); do
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" logs "$PRESSURE_NAME" 2>/dev/null \
      | grep -qx "pressure_ready_mib=$PRESSURE_MIB" && break
    sleep 0.2
  done
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" logs "$PRESSURE_NAME" \
    > "$WORKROOT/evidence/memory-pressure.log" 2>&1
  grep -qx "pressure_ready_mib=$PRESSURE_MIB" "$WORKROOT/evidence/memory-pressure.log" \
    || die "guest memory-pressure workload did not become ready"

  round=1
  while [ "$round" -le "$PRESSURE_ROUNDS" ]; do
    observed="$(run_peer_round "memory-pressure-$round")"
    [ "$observed" = "$expected_source" ] \
      || die "source identity changed under guest memory pressure in round $round"
    bounded_capture 5 "$WORKROOT/evidence/docker-version-pressure-$round.out" \
      "$WORKROOT/evidence/docker-version-pressure-$round.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER" version \
      || die "Docker API stalled under guest memory pressure in round $round"
    bounded_capture 5 "$WORKROOT/evidence/docker-dns-pressure-$round.out" \
      "$WORKROOT/evidence/docker-dns-pressure-$round.err" \
      env DOCKER_HOST="unix://$SOCKET" "$DOCKER" exec "$SERVER_NAME" \
        python3 -c 'import socket,sys; print(socket.getaddrinfo(sys.argv[1], 0, socket.AF_INET)[0][4][0])' \
        "$PRESSURE_NAME" \
      || die "Docker DNS stalled under guest memory pressure in round $round"
    bounded_capture 5 "$WORKROOT/evidence/configd-pressure-$round.out" \
      "$WORKROOT/evidence/configd-pressure-$round.err" /usr/sbin/scutil --dns \
      || die "macOS configd query stalled under guest memory pressure in round $round"
    sleep 3
    round=$((round + 1))
  done
  state="$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" inspect \
    -f '{{.State.Running}} {{.State.OOMKilled}}' "$PRESSURE_NAME")"
  [ "$state" = "true false" ] || die "memory-pressure workload was killed or stopped: $state"
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" stats --no-stream \
    "$PRESSURE_NAME" "$SERVER_NAME" > "$WORKROOT/evidence/memory-pressure-stats.txt"
  DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f "$PRESSURE_NAME" >/dev/null
}

run_peer_round() {
  local round="$1" token="$OWNER-$1" output tcp_source udp_source privileged_source logs privileged_logs
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_OPTIONS[@]}" "$PEER_SSH" \
    python3 - "$HOST_ADDRESS" "$PORT" "$LOOPBACK_PORT" "$PRIVILEGED_PORT" "$token" run \
    < "$WORKROOT/peer.py")" \
    || die "physical peer round $round failed"
  printf '%s\n' "$output" > "$WORKROOT/evidence/peer-$round.txt"
  grep -qx 'loopback_isolated=PASS' "$WORKROOT/evidence/peer-$round.txt" \
    || die "round $round did not prove loopback isolation"
  tcp_source="$(sed -n 's/^tcp_source=//p' "$WORKROOT/evidence/peer-$round.txt")"
  udp_source="$(sed -n 's/^udp_source=//p' "$WORKROOT/evidence/peer-$round.txt")"
  privileged_source="$(sed -n 's/^privileged_tcp_source=//p' "$WORKROOT/evidence/peer-$round.txt")"
  [ -n "$tcp_source" ] && [ "$tcp_source" = "$udp_source" ] \
    && [ "$tcp_source" = "$privileged_source" ] \
    || die "peer used inconsistent ordinary/privileged TCP or UDP source addresses"
  case "$tcp_source" in
    127.*|192.168.127.1|192.168.127.2|192.168.127.253|192.168.215.253|192.168.215.254|"")
      die "peer source is a Dory/loopback hop: $tcp_source" ;;
  esac
  for _ in $(seq 1 50); do
    logs="$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" logs "$SERVER_NAME" 2>&1)"
    printf '%s\n' "$logs" | grep -Fqx "tcp=$tcp_source token=$token" \
      && printf '%s\n' "$logs" | grep -Fqx "udp=$udp_source token=$token" && break
    sleep 0.2
  done
  printf '%s\n' "$logs" > "$WORKROOT/evidence/container-$round.log"
  grep -Fqx "tcp=$tcp_source token=$token" "$WORKROOT/evidence/container-$round.log" \
    || die "container did not observe exact physical TCP source $tcp_source"
  grep -Fqx "udp=$udp_source token=$token" "$WORKROOT/evidence/container-$round.log" \
    || die "container did not observe exact physical UDP source $udp_source"
  for _ in $(seq 1 50); do
    privileged_logs="$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" logs "$PRIVILEGED_NAME" 2>&1)"
    printf '%s\n' "$privileged_logs" \
      | grep -Fqx "tcp=$privileged_source token=$token-privileged" && break
    sleep 0.2
  done
  printf '%s\n' "$privileged_logs" > "$WORKROOT/evidence/privileged-container-$round.log"
  grep -Fqx "tcp=$privileged_source token=$token-privileged" \
    "$WORKROOT/evidence/privileged-container-$round.log" \
    || die "interface-specific privileged port did not preserve physical source $privileged_source"
  printf '%s\n' "$tcp_source"
}

start_engine fresh
create_fixtures fresh
SOURCE_IP="$(run_peer_round fresh)"

sudo -n /bin/launchctl kickstart -k system/dev.dory.network-helper \
  > "$WORKROOT/evidence/helper-restart.txt" 2>&1 \
  || die "could not restart the privileged network helper"
sleep 5
RECOVERED_SOURCE_IP="$(run_peer_round helper-restart)"
[ "$RECOVERED_SOURCE_IP" = "$SOURCE_IP" ] || die "source identity changed after helper restart"
run_memory_pressure_rounds "$SOURCE_IP"

DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f \
  "$SERVER_NAME" "$LOOPBACK_NAME" "$PRIVILEGED_NAME" >/dev/null
DOCKER_HOST="unix://$SOCKET" "$DOCKER" network rm "$PRESSURE_NETWORK" >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_OPTIONS[@]}" "$PEER_SSH" \
  python3 - "$HOST_ADDRESS" "$PORT" "$LOOPBACK_PORT" "$PRIVILEGED_PORT" "$OWNER" closed \
  < "$WORKROOT/peer.py" > "$WORKROOT/evidence/unpublish.txt" \
  || die "unpublish cleanup probe failed"
grep -qx 'tcp_unpublished=PASS' "$WORKROOT/evidence/unpublish.txt"
grep -qx 'udp_unpublished=PASS' "$WORKROOT/evidence/unpublish.txt"
grep -qx 'privileged_tcp_unpublished=PASS' "$WORKROOT/evidence/unpublish.txt"

HOME="$ENGINE_HOME" "$RUNTIME/dory-engine" stop > "$WORKROOT/evidence/runtime-stop-first.log" 2>&1
ENGINE_STARTED=0
start_engine restart
create_fixtures restart
RESTART_SOURCE_IP="$(run_peer_round engine-restart)"
[ "$RESTART_SOURCE_IP" = "$SOURCE_IP" ] || die "source identity changed after engine restart"
DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f "$SERVER_NAME" "$LOOPBACK_NAME" >/dev/null
DOCKER_HOST="unix://$SOCKET" "$DOCKER" network rm "$PRESSURE_NETWORK" >/dev/null
HOME="$ENGINE_HOME" "$RUNTIME/dory-engine" stop > "$WORKROOT/evidence/runtime-stop-final.log" 2>&1
ENGINE_STARTED=0

sudo -n /sbin/pfctl -a com.apple/dev.dory.lan -sn \
  > "$WORKROOT/evidence/pf-after.txt" 2>&1 || true
if grep -Eq '(^|[[:space:]])rdr([[:space:]]|$)' "$WORKROOT/evidence/pf-after.txt"; then
  die "Dory PF redirects survived final cleanup"
fi
if netstat -rn -f inet | awk '$1 == "192.168.215.254" { found=1 } END { exit !found }'; then
  die "Dory source-preserving host route survived final cleanup"
fi
sudo -n test ! -e /var/run/dev.dory/pf-enable-token \
  || die "Dory PF enable token survived final cleanup"
sudo -n test ! -e /var/run/dev.dory/ipv4-forwarding-owner \
  || die "Dory IPv4-forwarding ownership marker survived final cleanup"
sudo -n /sbin/pfctl -s References > "$WORKROOT/evidence/pf-references-after.txt" 2>&1 \
  || die "could not capture final PF enable references"
cmp "$WORKROOT/evidence/pf-references-before.txt" "$WORKROOT/evidence/pf-references-after.txt" \
  || die "Dory changed the host PF enable-reference set after final cleanup"
/usr/sbin/sysctl -n net.inet.ip.forwarding \
  > "$WORKROOT/evidence/ipv4-forwarding-after.txt"
cmp "$WORKROOT/evidence/ipv4-forwarding-before.txt" "$WORKROOT/evidence/ipv4-forwarding-after.txt" \
  || die "Dory did not restore the host IPv4-forwarding state"

HOST_BOOT_EPOCH_AFTER="$(/usr/sbin/sysctl -n kern.boottime \
  | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
[ "$HOST_BOOT_EPOCH_AFTER" = "$HOST_BOOT_EPOCH_BEFORE" ] \
  || die "the host boot session changed during physical network certification"
PANIC_REPORTS="$WORKROOT/evidence/new-host-panic-reports.txt"
: > "$PANIC_REPORTS"
for report_root in /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports"; do
  [ ! -d "$report_root" ] || find "$report_root" -type f -newer "$PANIC_MARKER" \
    \( -iname '*.panic' -o -iname '*panic*.ips' \) -print 2>/dev/null >> "$PANIC_REPORTS" \
    || true
done
[ ! -s "$PANIC_REPORTS" ] \
  || die "a new host panic report appeared during physical network certification"

APP_SHA="$(shasum -a 256 "$APP/Contents/MacOS/Dory" | awk '{print $1}')"
HV_SHA="$(shasum -a 256 "$RUNTIME/bin/dory-hv" | awk '{print $1}')"
GVPROXY_SHA="$(shasum -a 256 "$RUNTIME/bin/gvproxy" | awk '{print $1}')"
cat > "$WORKROOT/evidence/manifest.txt" <<EOF
schema=1
status=PASS
architecture=arm64
mode=$MODE
host_address=$HOST_ADDRESS
peer_transport=ssh
server_image=$SERVER_IMAGE
interface_specific_privileged_port=$PRIVILEGED_PORT
observed_source_ipv4=$SOURCE_IP
app_executable_sha256=$APP_SHA
dory_hv_sha256=$HV_SHA
gvproxy_sha256=$GVPROXY_SHA
tcp_source_preserved=PASS
udp_source_preserved=PASS
explicit_loopback_isolated=PASS
interface_specific_privileged_tcp=PASS
helper_restart_recovery=PASS
engine_restart_recovery=PASS
memory_pressure_source_preserved=PASS
docker_dns_pressure=PASS
configd_pressure_liveness=PASS
host_boot_epoch_before=$HOST_BOOT_EPOCH_BEFORE
host_boot_epoch_after=$HOST_BOOT_EPOCH_AFTER
host_boot_session_unchanged=PASS
host_panic_report_absence=PASS
memory_pressure_mib=$PRESSURE_MIB
memory_pressure_rounds=$PRESSURE_ROUNDS
tcp_unpublish_cleanup=PASS
udp_unpublish_cleanup=PASS
privileged_tcp_unpublish_cleanup=PASS
pf_cleanup=PASS
route_cleanup=PASS
pf_reference_cleanup=PASS
ipv4_forwarding_cleanup=PASS
release_qualifying=true
EOF

trap - EXIT INT TERM
echo "source-preserving LAN gate: PASS ($MODE source $SOURCE_IP)"
