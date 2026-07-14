#!/bin/bash
# Proves the macOS 14 Virtualization.framework fallback has the same native IPv6 and published-port
# contract as dory-hv. Every mutable asset and Docker object is isolated under --workroot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VMM=""
HV=""
GVPROXY=""
GVPROXY_PROVENANCE=""
PAYLOAD_INVENTORY=""
KERNEL=""
ROOTFS=""
DOCKER=""
WORKROOT="${TMPDIR:-/tmp}/dory-vz-native-ipv6-evidence"
EXTERNAL_IPV6="2606:4700:4700::1111"
REQUIRE_EXTERNAL=0
REQUIRE_SONOMA=0
KEEP=0
FIXTURE_IMAGE="alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
SSH_CLIENT_IMAGE=""
SOURCE_APP=""
SOURCE_LAN_HOST=""
SOURCE_LAN_PEER=""
SOURCE_TAILSCALE_HOST=""
SOURCE_TAILSCALE_PEER=""
SOURCE_SERVER_IMAGE=""
SOURCE_CONFIRM=""
SOURCE_ENABLED=0
SOURCE_PRESSURE_MIB=960
SOURCE_PRESSURE_ROUNDS=10
SOURCE_PRIVILEGED_PORT="${DORY_VZ_SOURCE_PRIVILEGED_PORT:-80}"

usage() {
  cat <<'EOF'
Usage: scripts/vz-native-ipv6-gate.sh --dory-vmm PATH --gvproxy PATH --kernel PATH --rootfs PATH --docker PATH [options]

Options:
  --dory-hv PATH       Helper used only to decompress .lzfse kernel/rootfs inputs
  --workroot DIR       Durable evidence root
  --gvproxy-provenance PATH  Signed-app gvproxy build provenance
  --payload-inventory PATH   Signed-app payload digest inventory
  --external-ipv6 IP   Real IPv6 TCP endpoint used on a host with IPv6 routing
  --require-external   Fail unless the host and container reach the IPv6 endpoint
  --require-sonoma     Fail unless this is macOS 14.x (the fallback's release target)
  --keep-workload      Preserve disposable VM files as well as evidence
  --fixture-image REF  Digest-pinned Alpine-compatible IPv6 fixture
  --ssh-client-image REF Digest-pinned image containing sh and ssh-add

Exact physical source-IP certification (all options are required together):
  --app Dory.app                  Exact signed/notarized candidate app
  --lan-host-address IPv4         Candidate Mac's physical-LAN address
  --lan-peer-ssh USER@HOST        Real noninteractive physical-LAN peer
  --tailscale-host-address IPv4   Candidate Mac's Tailscale address
  --tailscale-peer-ssh USER@HOST  Real noninteractive Tailscale peer
  --source-server-image REF       Digest-pinned image containing python3
  --source-privileged-port PORT   Free interface-specific TCP port below 1024 (default: 80)
  --source-confirm TOKEN          PHYSICAL-VZ-SOURCE-PRESERVATION
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dory-vmm) VMM="${2:?missing path}"; shift 2 ;;
    --dory-hv) HV="${2:?missing path}"; shift 2 ;;
    --gvproxy) GVPROXY="${2:?missing path}"; shift 2 ;;
    --gvproxy-provenance) GVPROXY_PROVENANCE="${2:?missing path}"; shift 2 ;;
    --payload-inventory) PAYLOAD_INVENTORY="${2:?missing path}"; shift 2 ;;
    --kernel) KERNEL="${2:?missing path}"; shift 2 ;;
    --rootfs) ROOTFS="${2:?missing path}"; shift 2 ;;
    --docker) DOCKER="${2:?missing path}"; shift 2 ;;
    --workroot) WORKROOT="${2:?missing directory}"; shift 2 ;;
    --external-ipv6) EXTERNAL_IPV6="${2:?missing address}"; shift 2 ;;
    --require-external) REQUIRE_EXTERNAL=1; shift ;;
    --require-sonoma) REQUIRE_SONOMA=1; shift ;;
    --keep-workload) KEEP=1; shift ;;
    --fixture-image) FIXTURE_IMAGE="${2:?missing image}"; shift 2 ;;
    --ssh-client-image) SSH_CLIENT_IMAGE="${2:?missing image}"; shift 2 ;;
    --app) SOURCE_APP="${2:?missing app}"; shift 2 ;;
    --lan-host-address) SOURCE_LAN_HOST="${2:?missing address}"; shift 2 ;;
    --lan-peer-ssh) SOURCE_LAN_PEER="${2:?missing peer}"; shift 2 ;;
    --tailscale-host-address) SOURCE_TAILSCALE_HOST="${2:?missing address}"; shift 2 ;;
    --tailscale-peer-ssh) SOURCE_TAILSCALE_PEER="${2:?missing peer}"; shift 2 ;;
    --source-server-image) SOURCE_SERVER_IMAGE="${2:?missing image}"; shift 2 ;;
    --source-privileged-port) SOURCE_PRIVILEGED_PORT="${2:?missing port}"; shift 2 ;;
    --source-confirm) SOURCE_CONFIRM="${2:?missing token}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "VZ native IPv6 gate: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ "$(uname -m)" = arm64 ] || { echo "VZ native IPv6 gate: Apple silicon is required" >&2; exit 69; }
for path in "$VMM" "$GVPROXY" "$KERNEL" "$ROOTFS" "$DOCKER"; do
  [ -f "$path" ] || { echo "VZ native IPv6 gate: missing input: $path" >&2; exit 66; }
done
[ -x "$VMM" ] && [ -x "$GVPROXY" ] && [ -x "$DOCKER" ] \
  || { echo "VZ native IPv6 gate: helper inputs must be executable" >&2; exit 66; }
printf '%s\n' "$FIXTURE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || { echo "VZ native IPv6 gate: fixture image must be digest-pinned" >&2; exit 64; }
if [ -n "$SSH_CLIENT_IMAGE" ]; then
  printf '%s\n' "$SSH_CLIENT_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || { echo "VZ native IPv6 gate: SSH client image must be digest-pinned" >&2; exit 64; }
  [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] \
    || { echo "VZ native IPv6 gate: SSH client certification requires a live SSH_AUTH_SOCK" >&2; exit 69; }
  ssh-add -L >/dev/null 2>&1 \
    || { echo "VZ native IPv6 gate: SSH client certification requires a loaded identity" >&2; exit 69; }
fi

for value in "$SOURCE_APP" "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" \
  "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" "$SOURCE_SERVER_IMAGE" "$SOURCE_CONFIRM"; do
  [ -z "$value" ] || SOURCE_ENABLED=1
done
if [ "$SOURCE_ENABLED" = 1 ]; then
  [ "$SOURCE_CONFIRM" = PHYSICAL-VZ-SOURCE-PRESERVATION ] \
    || { echo "VZ native IPv6 gate: physical source certification requires its exact confirmation token" >&2; exit 64; }
  for value in "$SOURCE_APP" "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" \
    "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" "$SOURCE_SERVER_IMAGE"; do
    [ -n "$value" ] || { echo "VZ native IPv6 gate: every physical source option is required" >&2; exit 64; }
  done
  [ -d "$SOURCE_APP" ] || { echo "VZ native IPv6 gate: candidate app is missing" >&2; exit 66; }
  SOURCE_APP="$(cd "$SOURCE_APP" && pwd)"
  printf '%s\n' "$SOURCE_SERVER_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || { echo "VZ native IPv6 gate: source server image must be digest-pinned" >&2; exit 64; }
  for peer in "$SOURCE_LAN_PEER" "$SOURCE_TAILSCALE_PEER"; do
    case "$peer" in
      -*|*[!A-Za-z0-9_.@:%+-]*) echo "VZ native IPv6 gate: source peer contains unsafe characters" >&2; exit 64 ;;
    esac
  done
  case "$SOURCE_PRIVILEGED_PORT" in ''|*[!0-9]*)
    echo "VZ native IPv6 gate: --source-privileged-port must be an integer" >&2; exit 64 ;;
  esac
  [ "$SOURCE_PRIVILEGED_PORT" -ge 1 ] && [ "$SOURCE_PRIVILEGED_PORT" -lt 1024 ] \
    || { echo "VZ native IPv6 gate: --source-privileged-port must be between 1 and 1023" >&2; exit 64; }
  python3 - "$SOURCE_LAN_HOST" "$SOURCE_TAILSCALE_HOST" <<'PY'
import ipaddress, sys
for raw in sys.argv[1:]:
    value = ipaddress.IPv4Address(raw)
    assert not value.is_unspecified and not value.is_multicast and not value.is_loopback
PY
  sudo -n true >/dev/null 2>&1 \
    || { echo "VZ native IPv6 gate: physical source certification requires noninteractive sudo" >&2; exit 77; }
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if [ "$REQUIRE_SONOMA" = 1 ] && [ "$OS_MAJOR" != 14 ]; then
  echo "VZ native IPv6 gate: --require-sonoma needs macOS 14.x; found $OS_VERSION" >&2
  exit 69
fi
if [ "$REQUIRE_SONOMA" = 1 ] && [ -z "$SSH_CLIENT_IMAGE" ]; then
  echo "VZ native IPv6 gate: Sonoma release certification requires --ssh-client-image" >&2
  exit 64
fi

# shellcheck source=gvproxy-payload.sh
source "$ROOT/scripts/gvproxy-payload.sh"
dory_gvproxy_validate_overrides
if [ -n "$GVPROXY_PROVENANCE$PAYLOAD_INVENTORY" ]; then
  [ -n "$GVPROXY_PROVENANCE" ] && [ -n "$PAYLOAD_INVENTORY" ] \
    || { echo "VZ native IPv6 gate: signed gvproxy provenance and payload inventory must be supplied together" >&2; exit 64; }
  dory_verify_signed_gvproxy_payload "$GVPROXY" "$GVPROXY_PROVENANCE" "$PAYLOAD_INVENTORY"
else
  dory_verify_gvproxy_payload \
    "$GVPROXY" "$(dory_gvproxy_version)" "$(dory_gvproxy_expected_sha256)"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
WORK="$RUN_ROOT/work"
TEST_HOME="$WORK/home"
STATE="$WORK/s"
DRIVE="$TEST_HOME/Library/Application Support/Dory/Dory.dorydrive"
HANDOFF="$WORK/h.sock"
HANDOFF_JSON="$WORK/handoff.json"
PORT_FILE="$WORK/host-port"
VMM_PID=""
HANDOFF_PID=""
HOST_PID=""
GVPROXY_PID=""
mkdir -p "$EVIDENCE" "$WORK"
if [ "$SOURCE_ENABLED" = 1 ]; then
  for source_address in "$SOURCE_LAN_HOST" "$SOURCE_TAILSCALE_HOST"; do
    owner_file="$EVIDENCE/source-privileged-owner-${source_address//[^A-Za-z0-9]/_}.txt"
    if sudo -n lsof -nP -iTCP@"$source_address:$SOURCE_PRIVILEGED_PORT" -sTCP:LISTEN \
        > "$owner_file" 2>&1; then
      echo "VZ native IPv6 gate: interface-specific privileged port is already owned: $source_address:$SOURCE_PRIVILEGED_PORT" >&2
      exit 1
    fi
  done
fi
HOST_BOOT_EPOCH_BEFORE="$(/usr/sbin/sysctl -n kern.boottime \
  | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
printf '%s\n' "$HOST_BOOT_EPOCH_BEFORE" | grep -Eq '^[0-9]+$' \
  || { echo "VZ native IPv6 gate: could not capture host boot epoch" >&2; exit 1; }
PANIC_MARKER="$EVIDENCE/host-panic-window-start"
touch "$PANIC_MARKER"

if [ "$SOURCE_ENABLED" = 1 ]; then
  codesign --verify --strict --deep "$SOURCE_APP"
  xcrun stapler validate "$SOURCE_APP" >/dev/null
  cmp "$VMM" "$SOURCE_APP/Contents/Helpers/dory-vmm" \
    || { echo "VZ native IPv6 gate: dory-vmm differs from the exact app" >&2; exit 1; }
  cmp "$GVPROXY" "$SOURCE_APP/Contents/Helpers/gvproxy" \
    || { echo "VZ native IPv6 gate: gvproxy differs from the exact app" >&2; exit 1; }
  cmp "$DOCKER" "$SOURCE_APP/Contents/Helpers/docker" \
    || { echo "VZ native IPv6 gate: Docker CLI differs from the exact app" >&2; exit 1; }
  "$SOURCE_APP/Contents/MacOS/Dory" --register-network-helper \
    > "$EVIDENCE/network-helper-registration.txt" 2>&1 \
    || { echo "VZ native IPv6 gate: exact app network helper is not approved" >&2; exit 1; }
  grep -qx 'network-helper=enabled' "$EVIDENCE/network-helper-registration.txt" \
    || { echo "VZ native IPv6 gate: exact app did not confirm its network helper" >&2; exit 1; }
  sudo -n /sbin/pfctl -s References > "$EVIDENCE/pf-references-before.txt" 2>&1 \
    || { echo "VZ native IPv6 gate: could not capture PF reference baseline" >&2; exit 1; }
  /usr/sbin/sysctl -n net.inet.ip.forwarding > "$EVIDENCE/ipv4-forwarding-before.txt"

  python3 - "$WORK/source-server.py" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(r'''
import socket, threading

def tcp():
    server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 8080)); server.listen(16)
    while True:
        connection, peer = server.accept()
        token = connection.recv(1024).decode().strip()
        print(f"tcp={peer[0]} token={token}", flush=True)
        connection.sendall((token + "\n").encode()); connection.close()

def udp():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); server.bind(("0.0.0.0", 8080))
    while True:
        payload, peer = server.recvfrom(2048); token = payload.decode().strip()
        print(f"udp={peer[0]} token={token}", flush=True)
        server.sendto((token + "\n").encode(), peer)

threading.Thread(target=tcp, daemon=True).start(); udp()
''', encoding="utf-8")
PY
  python3 - "$WORK/source-peer.py" <<'PY'
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
    connection.close(); return source

if operation == "run":
    print("tcp_source=" + tcp_open(port, token))
    print("privileged_tcp_source=" + tcp_open(privileged_port, token + "-privileged"))
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.settimeout(4)
    udp.connect((host, port)); source = udp.getsockname()[0]
    udp.send((token + "\n").encode()); assert udp.recv(1024).decode().strip() == token
    udp.close(); print("udp_source=" + source)
    try: tcp_open(loop_port)
    except OSError: print("loopback_isolated=PASS")
    else: raise SystemExit("explicit loopback publication was reachable remotely")
elif operation == "closed":
    try: tcp_open(port)
    except OSError: print("tcp_unpublished=PASS")
    else: raise SystemExit("unpublished TCP port remains reachable")
    try: tcp_open(privileged_port)
    except OSError: print("privileged_tcp_unpublished=PASS")
    else: raise SystemExit("unpublished interface-specific privileged TCP port remains reachable")
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.settimeout(2)
    try: udp.sendto(b"closed", (host, port)); udp.recvfrom(1024)
    except OSError: print("udp_unpublished=PASS")
    else: raise SystemExit("unpublished UDP port remains reachable")
''', encoding="utf-8")
PY
fi

prepare_asset() {
  source_path="$1"
  output_name="$2"
  destination="$WORK/$output_name"
  case "$source_path" in
    *.lzfse)
      [ -n "$HV" ] && [ -x "$HV" ] \
        || { echo "VZ native IPv6 gate: compressed inputs require executable --dory-hv" >&2; exit 66; }
      "$HV" lzfse decompress "$source_path" "$destination" > "$EVIDENCE/decompress-$output_name.log"
      ;;
    *)
      cp -c "$source_path" "$destination" 2>/dev/null || cp "$source_path" "$destination"
      ;;
  esac
  printf '%s\n' "$destination"
}
KERNEL="$(prepare_asset "$KERNEL" kernel)"
ROOTFS="$(prepare_asset "$ROOTFS" rootfs.ext4)"

stop_vmm() {
  [ -n "$VMM_PID" ] || return 0
  if kill -0 "$VMM_PID" 2>/dev/null; then kill -TERM "$VMM_PID" 2>/dev/null || true; fi
  for _ in $(seq 1 300); do
    if ! kill -0 "$VMM_PID" 2>/dev/null; then
      wait "$VMM_PID" 2>/dev/null || true
      VMM_PID=""
      if [ -n "$GVPROXY_PID" ] && kill -0 "$GVPROXY_PID" 2>/dev/null; then
        echo "VZ native IPv6 gate: gvproxy survived graceful VMM shutdown" >&2
        return 1
      fi
      GVPROXY_PID=""
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$VMM_PID" 2>/dev/null || true
  wait "$VMM_PID" 2>/dev/null || true
  VMM_PID=""
  echo "VZ native IPv6 gate: dory-vmm did not stop within 30 seconds" >&2
  return 1
}

cleanup() {
  status=$?
  set +e
  stop_vmm
  [ -z "$HANDOFF_PID" ] || kill "$HANDOFF_PID" 2>/dev/null || true
  [ -z "$HANDOFF_PID" ] || wait "$HANDOFF_PID" 2>/dev/null || true
  [ -z "$HOST_PID" ] || kill "$HOST_PID" 2>/dev/null || true
  [ -z "$HOST_PID" ] || wait "$HOST_PID" 2>/dev/null || true
  if [ "$KEEP" -ne 1 ]; then rm -rf "$WORK"; fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

python3 - "$PORT_FILE" <<'PY' &
import pathlib, socket, sys
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("::1", 0)); s.listen(32)
pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1]))
response = b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\ndory-ipv6-loop\n"
while True:
    conn, _ = s.accept()
    with conn:
        conn.recv(65536); conn.sendall(response)
PY
HOST_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
[ -s "$PORT_FILE" ] || { echo "VZ native IPv6 gate: host listener did not start" >&2; exit 1; }
HOST_PORT="$(cat "$PORT_FILE")"

start_handoff_listener() {
  rm -f "$HANDOFF" "$HANDOFF_JSON"
  python3 - "$HANDOFF" "$HANDOFF_JSON" <<'PY' &
import json, os, pathlib, socket, sys
sock_path, output = sys.argv[1:]
try: os.unlink(sock_path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path); s.listen(1)
conn, _ = s.accept()
with conn:
    chunks = []
    while True:
        chunk = conn.recv(16384)
        if not chunk: break
        chunks.append(chunk)
payload = b"".join(chunks)
body = json.loads(payload)
assert body["machineID"] == "docker"
assert body.get("dockerdSocketPath")
pathlib.Path(output).write_text(json.dumps(body, sort_keys=True) + "\n")
PY
  HANDOFF_PID=$!
  for _ in $(seq 1 100); do [ -S "$HANDOFF" ] && return 0; sleep 0.05; done
  echo "VZ native IPv6 gate: handoff listener did not start" >&2
  exit 1
}

start_vmm() {
  cycle="$1"
  publish_host=127.0.0.1
  [ "$SOURCE_ENABLED" = 0 ] || publish_host=0.0.0.0
  start_handoff_listener
  ssh_agent_args=()
  if [ -n "$SSH_CLIENT_IMAGE" ]; then
    ssh_agent_args=(--ssh-agent-socket "$SSH_AUTH_SOCK")
  fi
  HOME="$TEST_HOME" "$VMM" \
    --machine-id docker --state-dir "$STATE" --data-drive "$DRIVE" \
    --kernel "$KERNEL" --rootfs "$ROOTFS" --gvproxy "$GVPROXY" \
    --handoff-sock "$HANDOFF" --memory-mb 2048 --cpus 2 \
    --publish-host "$publish_host" \
    "${ssh_agent_args[@]}" \
    >"$EVIDENCE/vmm-$cycle.log" 2>&1 &
  VMM_PID=$!
  for _ in $(seq 1 240); do
    kill -0 "$VMM_PID" 2>/dev/null || {
      echo "VZ native IPv6 gate: dory-vmm exited during $cycle" >&2
      tail -n 120 "$EVIDENCE/vmm-$cycle.log" >&2
      exit 1
    }
    if [ -s "$HANDOFF_JSON" ]; then
      wait "$HANDOFF_PID"; HANDOFF_PID=""
      DOCKER_SOCKET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dockerdSocketPath"])' "$HANDOFF_JSON")"
      DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" info >/dev/null 2>&1 && {
        GVPROXY_PID="$(pgrep -P "$VMM_PID" -f "$GVPROXY" | head -1 || true)"
        [ -n "$GVPROXY_PID" ] || { echo "VZ native IPv6 gate: gvproxy child is missing" >&2; exit 1; }
        cp "$HANDOFF_JSON" "$EVIDENCE/handoff-$cycle.json"
        return 0
      }
    fi
    sleep 0.5
  done
  echo "VZ native IPv6 gate: Docker readiness timed out during $cycle" >&2
  exit 1
}

verify_ssh_agent() {
  cycle="$1"
  [ -n "$SSH_CLIENT_IMAGE" ] || return 0
  gate_root="$WORK/ssh-agent-$cycle"
  scripts/ssh-agent-forwarding-gate.sh \
    --socket "$DOCKER_SOCKET" \
    --docker "$DOCKER" \
    --image "$SSH_CLIENT_IMAGE" \
    --workroot "$gate_root" \
    --concurrency 8 \
    > "$EVIDENCE/ssh-agent-$cycle.log" 2>&1
  gate_manifest="$(find "$gate_root" -type f -name manifest.txt -print)"
  [ "$(printf '%s\n' "$gate_manifest" | awk 'NF { count++ } END { print count + 0 }')" = 1 ] \
    || { echo "VZ native IPv6 gate: SSH-agent evidence is missing or ambiguous" >&2; exit 1; }
  cp "$gate_manifest" "$EVIDENCE/ssh-agent-$cycle.txt"
}

free_port() {
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

wait_http() {
  url="$1" expected="$2"
  for _ in $(seq 1 60); do
    [ "$(curl -gfsS --connect-timeout 2 "$url" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 1
  done
  return 1
}

bounded_capture() {
  limit="$1"; stdout="$2"; stderr="$3"; shift 3
  "$@" > "$stdout" 2> "$stderr" &
  bounded_pid=$!
  bounded_started=$SECONDS
  while kill -0 "$bounded_pid" 2>/dev/null; do
    if [ $((SECONDS - bounded_started)) -ge "$limit" ]; then
      kill -TERM "$bounded_pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$bounded_pid" 2>/dev/null || true
      wait "$bounded_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$bounded_pid"; then return 0; else return $?; fi
}

source_create_fixtures() {
  cycle="$1"
  SOURCE_SERVER_NAME="dory-vz-source-$cycle-$$"
  SOURCE_LOOPBACK_NAME="dory-vz-source-loopback-$cycle-$$"
  SOURCE_PRIVILEGED_NAME="dory-vz-source-privileged-$cycle-$$"
  SOURCE_PRESSURE_NAME="dory-vz-source-pressure-$cycle-$$"
  SOURCE_NETWORK_NAME="dory-vz-source-net-$cycle-$$"
  SOURCE_SERVER_CODE="$(cat "$WORK/source-server.py")"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" pull "$SOURCE_SERVER_IMAGE" \
    > "$EVIDENCE/source-image-pull-$cycle.txt"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" network create \
    --label dev.dory.vz-source-certification=true "$SOURCE_NETWORK_NAME" >/dev/null
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" run -d --name "$SOURCE_SERVER_NAME" \
    --label dev.dory.vz-source-certification=true \
    --network "$SOURCE_NETWORK_NAME" \
    -p "$SOURCE_PORT:8080/tcp" -p "$SOURCE_PORT:8080/udp" \
    "$SOURCE_SERVER_IMAGE" python3 -c "$SOURCE_SERVER_CODE" \
    > "$EVIDENCE/source-container-$cycle.id"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" run -d --name "$SOURCE_LOOPBACK_NAME" \
    --label dev.dory.vz-source-certification=true \
    --network "$SOURCE_NETWORK_NAME" \
    -p "127.0.0.1:$SOURCE_LOOPBACK_PORT:8080/tcp" \
    "$SOURCE_SERVER_IMAGE" python3 -c "$SOURCE_SERVER_CODE" \
    > "$EVIDENCE/source-loopback-$cycle.id"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" run -d --name "$SOURCE_PRIVILEGED_NAME" \
    --label dev.dory.vz-source-certification=true \
    --network "$SOURCE_NETWORK_NAME" \
    -p "$SOURCE_LAN_HOST:$SOURCE_PRIVILEGED_PORT:8080/tcp" \
    -p "$SOURCE_TAILSCALE_HOST:$SOURCE_PRIVILEGED_PORT:8080/tcp" \
    "$SOURCE_SERVER_IMAGE" python3 -c "$SOURCE_SERVER_CODE" \
    > "$EVIDENCE/source-privileged-$cycle.id"
  sleep 4
}

source_run_memory_pressure() {
  cycle="$1"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" run -d --name "$SOURCE_PRESSURE_NAME" \
    --label dev.dory.vz-source-certification=true --network "$SOURCE_NETWORK_NAME" \
    --memory 1280m "$SOURCE_SERVER_IMAGE" python3 -c '
import time
blocks = []
for _ in range(60):
    block = bytearray(16 * 1024 * 1024)
    for offset in range(0, len(block), 4096):
        block[offset] = 1
    blocks.append(block)
print("pressure_ready_mib=960", flush=True)
time.sleep(300)
' > "$EVIDENCE/source-pressure-$cycle.id"
  for _ in $(seq 1 100); do
    DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" logs "$SOURCE_PRESSURE_NAME" 2>/dev/null \
      | grep -qx "pressure_ready_mib=$SOURCE_PRESSURE_MIB" && break
    sleep 0.2
  done
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" logs "$SOURCE_PRESSURE_NAME" \
    > "$EVIDENCE/source-pressure-$cycle.log" 2>&1
  grep -qx "pressure_ready_mib=$SOURCE_PRESSURE_MIB" "$EVIDENCE/source-pressure-$cycle.log" \
    || { echo "VZ native IPv6 gate: memory-pressure workload did not become ready" >&2; return 1; }

  pressure_round=1
  while [ "$pressure_round" -le "$SOURCE_PRESSURE_ROUNDS" ]; do
    [ "$(source_peer_round lan "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" \
      "memory-pressure-$pressure_round")" = "$SOURCE_LAN_FIRST" ] \
      || { echo "VZ native IPv6 gate: LAN source changed under memory pressure" >&2; return 1; }
    [ "$(source_peer_round tailscale "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" \
      "memory-pressure-$pressure_round")" = "$SOURCE_TAILSCALE_FIRST" ] \
      || { echo "VZ native IPv6 gate: Tailscale source changed under memory pressure" >&2; return 1; }
    bounded_capture 5 "$EVIDENCE/source-docker-version-pressure-$pressure_round.out" \
      "$EVIDENCE/source-docker-version-pressure-$pressure_round.err" \
      env DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" version \
      || { echo "VZ native IPv6 gate: Docker API stalled under memory pressure" >&2; return 1; }
    bounded_capture 5 "$EVIDENCE/source-dns-pressure-$pressure_round.out" \
      "$EVIDENCE/source-dns-pressure-$pressure_round.err" \
      env DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" exec "$SOURCE_SERVER_NAME" \
        python3 -c 'import socket,sys; print(socket.getaddrinfo(sys.argv[1], 0, socket.AF_INET)[0][4][0])' \
        "$SOURCE_PRESSURE_NAME" \
      || { echo "VZ native IPv6 gate: Docker DNS stalled under memory pressure" >&2; return 1; }
    bounded_capture 5 "$EVIDENCE/source-configd-pressure-$pressure_round.out" \
      "$EVIDENCE/source-configd-pressure-$pressure_round.err" /usr/sbin/scutil --dns \
      || { echo "VZ native IPv6 gate: configd stalled under memory pressure" >&2; return 1; }
    sleep 3
    pressure_round=$((pressure_round + 1))
  done
  pressure_state="$(DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" inspect \
    -f '{{.State.Running}} {{.State.OOMKilled}}' "$SOURCE_PRESSURE_NAME")"
  [ "$pressure_state" = "true false" ] \
    || { echo "VZ native IPv6 gate: pressure workload was killed: $pressure_state" >&2; return 1; }
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" stats --no-stream \
    "$SOURCE_PRESSURE_NAME" "$SOURCE_SERVER_NAME" \
    > "$EVIDENCE/source-pressure-stats-$cycle.txt"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" rm -f "$SOURCE_PRESSURE_NAME" >/dev/null
}

source_peer_round() {
  mode="$1" host="$2" peer="$3" phase="$4"
  token="dory-vz-$mode-$phase-$$"
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$peer" \
    python3 - "$host" "$SOURCE_PORT" "$SOURCE_LOOPBACK_PORT" \
    "$SOURCE_PRIVILEGED_PORT" "$token" run \
    < "$WORK/source-peer.py")" \
    || { echo "VZ native IPv6 gate: $mode source peer failed during $phase" >&2; return 1; }
  printf '%s\n' "$output" > "$EVIDENCE/source-peer-$mode-$phase.txt"
  grep -qx 'loopback_isolated=PASS' "$EVIDENCE/source-peer-$mode-$phase.txt" \
    || { echo "VZ native IPv6 gate: $mode loopback publication widened during $phase" >&2; return 1; }
  tcp_source="$(sed -n 's/^tcp_source=//p' "$EVIDENCE/source-peer-$mode-$phase.txt")"
  udp_source="$(sed -n 's/^udp_source=//p' "$EVIDENCE/source-peer-$mode-$phase.txt")"
  privileged_source="$(sed -n 's/^privileged_tcp_source=//p' \
    "$EVIDENCE/source-peer-$mode-$phase.txt")"
  [ -n "$tcp_source" ] && [ "$tcp_source" = "$udp_source" ] \
    && [ "$tcp_source" = "$privileged_source" ] \
    || { echo "VZ native IPv6 gate: $mode ordinary/privileged TCP or UDP source mismatch during $phase" >&2; return 1; }
  case "$tcp_source" in
    127.*|192.168.127.1|192.168.127.2|192.168.127.253|192.168.215.253|192.168.215.254|"")
      echo "VZ native IPv6 gate: $mode observed a Dory/loopback hop: $tcp_source" >&2; return 1 ;;
  esac
  for _ in $(seq 1 50); do
    logs="$(DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" logs "$SOURCE_SERVER_NAME" 2>&1)"
    printf '%s\n' "$logs" | grep -Fqx "tcp=$tcp_source token=$token" \
      && printf '%s\n' "$logs" | grep -Fqx "udp=$udp_source token=$token" && break
    sleep 0.2
  done
  printf '%s\n' "$logs" > "$EVIDENCE/source-container-$mode-$phase.log"
  grep -Fqx "tcp=$tcp_source token=$token" "$EVIDENCE/source-container-$mode-$phase.log" \
    && grep -Fqx "udp=$udp_source token=$token" "$EVIDENCE/source-container-$mode-$phase.log" \
    || { echo "VZ native IPv6 gate: container lost $mode source identity during $phase" >&2; return 1; }
  for _ in $(seq 1 50); do
    privileged_logs="$(DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" logs \
      "$SOURCE_PRIVILEGED_NAME" 2>&1)"
    printf '%s\n' "$privileged_logs" \
      | grep -Fqx "tcp=$privileged_source token=$token-privileged" && break
    sleep 0.2
  done
  printf '%s\n' "$privileged_logs" \
    > "$EVIDENCE/source-privileged-$mode-$phase.log"
  grep -Fqx "tcp=$privileged_source token=$token-privileged" \
    "$EVIDENCE/source-privileged-$mode-$phase.log" \
    || { echo "VZ native IPv6 gate: interface-specific privileged port lost $mode source identity during $phase" >&2; return 1; }
  printf '%s\n' "$tcp_source"
}

source_remove_and_verify_closed() {
  cycle="$1"
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" rm -f "$SOURCE_PRESSURE_NAME" \
    >/dev/null 2>&1 || true
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" rm -f \
    "$SOURCE_SERVER_NAME" "$SOURCE_LOOPBACK_NAME" "$SOURCE_PRIVILEGED_NAME" >/dev/null
  for mode in lan tailscale; do
    if [ "$mode" = lan ]; then host="$SOURCE_LAN_HOST"; peer="$SOURCE_LAN_PEER"
    else host="$SOURCE_TAILSCALE_HOST"; peer="$SOURCE_TAILSCALE_PEER"; fi
    closed_output="$EVIDENCE/source-unpublish-$mode-$cycle.txt"
    passed=0
    for _ in $(seq 1 20); do
      if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$peer" \
          python3 - "$host" "$SOURCE_PORT" "$SOURCE_LOOPBACK_PORT" \
          "$SOURCE_PRIVILEGED_PORT" "dory-vz-$cycle" closed \
          < "$WORK/source-peer.py" > "$closed_output" 2>&1; then
        passed=1
        break
      fi
      sleep 0.5
    done
    [ "$passed" = 1 ] && grep -qx 'tcp_unpublished=PASS' "$closed_output" \
      && grep -qx 'udp_unpublished=PASS' "$closed_output" \
      && grep -qx 'privileged_tcp_unpublished=PASS' "$closed_output" \
      || { echo "VZ native IPv6 gate: $mode listeners survived $cycle cleanup" >&2; return 1; }
  done
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" network rm "$SOURCE_NETWORK_NAME" >/dev/null
}

verify_cycle() {
  cycle="$1"
  export DOCKER_HOST="unix://$DOCKER_SOCKET"
  "$DOCKER" network inspect bridge > "$EVIDENCE/bridge-$cycle.json"
  "$DOCKER" run --rm "$FIXTURE_IMAGE" sh -ec "
    ip -6 address show dev eth0
    ip -6 route show
    nslookup -type=AAAA one.one.one.one
    nslookup -type=AAAA registry-1.docker.io
    test \"\$(wget -T 10 -qO- 'http://[fd7d:6f72:7900::1]:$HOST_PORT/')\" = dory-ipv6-loop
  " > "$EVIDENCE/container-$cycle.txt"
  python3 - "$EVIDENCE/bridge-$cycle.json" "$EVIDENCE/container-$cycle.txt" <<'PY'
import json, pathlib, sys
bridge = json.loads(pathlib.Path(sys.argv[1]).read_text())[0]
text = pathlib.Path(sys.argv[2]).read_text()
assert bridge["EnableIPv6"] is True
assert any(x.get("Subnet") == "fd7d:6f72:7901::/64" for x in bridge["IPAM"]["Config"])
assert "inet6 fd7d:6f72:7901::" in text
assert "2606:4700:4700::" in text
assert "2600:1f18:" in text
PY

  wildcard_name="dory-vz-wildcard-$cycle-$$"
  wildcard_port="$(free_port)"
  "$DOCKER" run -d --name "$wildcard_name" -p "$wildcard_port:8080" "$FIXTURE_IMAGE" sh -c \
    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 9\\r\\nConnection: close\\r\\n\\r\\ndory-port' | nc -l -p 8080; done" \
    > "$EVIDENCE/wildcard-$cycle.id"
  wait_http "http://127.0.0.1:$wildcard_port/" dory-port \
    && wait_http "http://[::1]:$wildcard_port/" dory-port \
    || { echo "VZ native IPv6 gate: dual-stack localhost publication failed" >&2; exit 1; }

  ipv4_name="dory-vz-v4only-$cycle-$$"
  ipv4_port="$(free_port)"
  intent="{\"8080/tcp\":{\"$ipv4_port\":\"ipv4\"}}"
  "$DOCKER" run -d --name "$ipv4_name" \
    --label "dev.dory.internal.loopback-port-intent=$intent" \
    -p "0.0.0.0:$ipv4_port:8080" "$FIXTURE_IMAGE" sh -c \
    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 7\\r\\nConnection: close\\r\\n\\r\\ndory-v4' | nc -l -p 8080; done" \
    > "$EVIDENCE/ipv4-only-$cycle.id"
  wait_http "http://127.0.0.1:$ipv4_port/" dory-v4 \
    || { echo "VZ native IPv6 gate: explicit IPv4 loopback publication failed" >&2; exit 1; }
  if curl -gfsS --connect-timeout 2 "http://[::1]:$ipv4_port/" >/dev/null 2>&1; then
    echo "VZ native IPv6 gate: IPv4 loopback publication widened to IPv6" >&2
    exit 1
  fi

  "$DOCKER" rm -f "$wildcard_name" "$ipv4_name" >/dev/null
  for _ in $(seq 1 20); do
    if ! curl -fsS --connect-timeout 1 "http://127.0.0.1:$wildcard_port/" >/dev/null 2>&1 \
      && ! curl -gfsS --connect-timeout 1 "http://[::1]:$wildcard_port/" >/dev/null 2>&1 \
      && ! curl -fsS --connect-timeout 1 "http://127.0.0.1:$ipv4_port/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "VZ native IPv6 gate: removed container left a published listener" >&2
  exit 1
}

SOURCE_RESULT=SKIP
SOURCE_LAN_FIRST=SKIP
SOURCE_TAILSCALE_FIRST=SKIP
if [ "$SOURCE_ENABLED" = 1 ]; then
  SOURCE_PORT="$(free_port)"
  SOURCE_LOOPBACK_PORT="$(free_port)"
  [ "$SOURCE_PORT" != "$SOURCE_LOOPBACK_PORT" ] || SOURCE_LOOPBACK_PORT="$(free_port)"
fi

start_vmm first
DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" image inspect "$FIXTURE_IMAGE" >/dev/null 2>&1 \
  || DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" pull "$FIXTURE_IMAGE" > "$EVIDENCE/pull.log"
if [ -n "$SSH_CLIENT_IMAGE" ]; then
  DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" image inspect "$SSH_CLIENT_IMAGE" >/dev/null 2>&1 \
    || DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" pull "$SSH_CLIENT_IMAGE" \
      > "$EVIDENCE/ssh-client-pull.log"
fi
verify_cycle first
verify_ssh_agent first
if [ "$SOURCE_ENABLED" = 1 ]; then
  source_create_fixtures first
  SOURCE_LAN_FIRST="$(source_peer_round lan "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" first)"
  SOURCE_TAILSCALE_FIRST="$(source_peer_round tailscale "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" first)"
  sudo -n /bin/launchctl kickstart -k system/dev.dory.network-helper \
    > "$EVIDENCE/source-helper-restart.txt" 2>&1 \
    || { echo "VZ native IPv6 gate: could not restart the privileged network helper" >&2; exit 1; }
  sleep 5
  [ "$(source_peer_round lan "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" helper-restart)" = "$SOURCE_LAN_FIRST" ] \
    || { echo "VZ native IPv6 gate: LAN source changed after helper restart" >&2; exit 1; }
  [ "$(source_peer_round tailscale "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" helper-restart)" = "$SOURCE_TAILSCALE_FIRST" ] \
    || { echo "VZ native IPv6 gate: Tailscale source changed after helper restart" >&2; exit 1; }
  source_run_memory_pressure first
  source_remove_and_verify_closed first
fi
stop_vmm
start_vmm restart
verify_cycle restart
verify_ssh_agent restart
if [ "$SOURCE_ENABLED" = 1 ]; then
  source_create_fixtures restart
  [ "$(source_peer_round lan "$SOURCE_LAN_HOST" "$SOURCE_LAN_PEER" engine-restart)" = "$SOURCE_LAN_FIRST" ] \
    || { echo "VZ native IPv6 gate: LAN source changed after VZ restart" >&2; exit 1; }
  [ "$(source_peer_round tailscale "$SOURCE_TAILSCALE_HOST" "$SOURCE_TAILSCALE_PEER" engine-restart)" = "$SOURCE_TAILSCALE_FIRST" ] \
    || { echo "VZ native IPv6 gate: Tailscale source changed after VZ restart" >&2; exit 1; }
  source_remove_and_verify_closed restart
  SOURCE_RESULT=PASS
fi

EXTERNAL_RESULT=SKIP
if nc -6 -z -w 10 "$EXTERNAL_IPV6" 443 >/dev/null 2>&1; then
  if DOCKER_HOST="unix://$DOCKER_SOCKET" "$DOCKER" run --rm "$FIXTURE_IMAGE" \
      nc -z -w 15 "$EXTERNAL_IPV6" 443 > "$EVIDENCE/external-ipv6.out" 2> "$EVIDENCE/external-ipv6.err"; then
    EXTERNAL_RESULT=PASS
  else
    echo "VZ native IPv6 gate: host IPv6 works but container TCP failed" >&2
    exit 1
  fi
elif [ "$REQUIRE_EXTERNAL" = 1 ]; then
  echo "VZ native IPv6 gate: --require-external needs a real host IPv6 route" >&2
  exit 1
fi

stop_vmm
if [ "$SOURCE_ENABLED" = 1 ]; then
  sudo -n test ! -e /var/run/dev.dory/pf-enable-token \
    || { echo "VZ native IPv6 gate: PF token survived final cleanup" >&2; exit 1; }
  sudo -n test ! -e /var/run/dev.dory/ipv4-forwarding-owner \
    || { echo "VZ native IPv6 gate: forwarding marker survived final cleanup" >&2; exit 1; }
  sudo -n /sbin/pfctl -a com.apple/dev.dory.lan -sn > "$EVIDENCE/source-pf-after.txt" 2>&1 || true
  ! grep -Eq '(^|[[:space:]])rdr([[:space:]]|$)' "$EVIDENCE/source-pf-after.txt" \
    || { echo "VZ native IPv6 gate: PF redirects survived final cleanup" >&2; exit 1; }
  ! netstat -rn -f inet | awk '$1 == "192.168.215.254" { found=1 } END { exit !found }' \
    || { echo "VZ native IPv6 gate: source-preserving route survived final cleanup" >&2; exit 1; }
  sudo -n /sbin/pfctl -s References > "$EVIDENCE/pf-references-after.txt" 2>&1
  cmp "$EVIDENCE/pf-references-before.txt" "$EVIDENCE/pf-references-after.txt" \
    || { echo "VZ native IPv6 gate: PF reference set changed after cleanup" >&2; exit 1; }
  /usr/sbin/sysctl -n net.inet.ip.forwarding > "$EVIDENCE/ipv4-forwarding-after.txt"
  cmp "$EVIDENCE/ipv4-forwarding-before.txt" "$EVIDENCE/ipv4-forwarding-after.txt" \
    || { echo "VZ native IPv6 gate: IPv4 forwarding state changed after cleanup" >&2; exit 1; }
fi
cp "$STATE/gvproxy-dual-stack.yaml" "$EVIDENCE/gvproxy-dual-stack.yaml"
cp "$STATE/serial.log" "$EVIDENCE/serial.log"
HOST_BOOT_EPOCH_AFTER="$(/usr/sbin/sysctl -n kern.boottime \
  | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
[ "$HOST_BOOT_EPOCH_AFTER" = "$HOST_BOOT_EPOCH_BEFORE" ] \
  || { echo "VZ native IPv6 gate: host boot session changed during certification" >&2; exit 1; }
PANIC_REPORTS="$EVIDENCE/new-host-panic-reports.txt"
: > "$PANIC_REPORTS"
for report_root in /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports"; do
  [ ! -d "$report_root" ] || find "$report_root" -type f -newer "$PANIC_MARKER" \
    \( -iname '*.panic' -o -iname '*panic*.ips' \) -print 2>/dev/null >> "$PANIC_REPORTS" \
    || true
done
[ ! -s "$PANIC_REPORTS" ] \
  || { echo "VZ native IPv6 gate: new host panic report appeared during certification" >&2; exit 1; }
SONOMA_RESULT="$([ "$OS_MAJOR" = 14 ] && echo PASS || echo SKIP)"
RELEASE_QUALIFYING=false
[ "$SONOMA_RESULT" = PASS ] && [ "$EXTERNAL_RESULT" = PASS ] && RELEASE_QUALIFYING=true
SSH_AGENT_RESULT=SKIP
if [ -n "$SSH_CLIENT_IMAGE" ]; then SSH_AGENT_RESULT=PASS; else RELEASE_QUALIFYING=false; fi
if [ "$SOURCE_ENABLED" = 1 ] && [ "$SOURCE_RESULT" != PASS ]; then RELEASE_QUALIFYING=false; fi
{
  echo status=PASS
  echo architecture=arm64
  echo macos_version="$OS_VERSION"
  echo sonoma="$SONOMA_RESULT"
  echo dory_vmm_sha256="$(shasum -a 256 "$VMM" | awk '{print $1}')"
  echo gvproxy_version="$(dory_gvproxy_version)"
  echo gvproxy_sha256="$(dory_gvproxy_file_sha256 "$GVPROXY")"
  echo gvproxy_build_sha256="$(dory_gvproxy_expected_sha256)"
  echo fixture_image="$FIXTURE_IMAGE"
  echo vz_file_handle_network=PASS
  echo fresh_boot=PASS
  echo restart=PASS
  echo graceful_cleanup=PASS
  echo host_boot_epoch_before="$HOST_BOOT_EPOCH_BEFORE"
  echo host_boot_epoch_after="$HOST_BOOT_EPOCH_AFTER"
  echo host_boot_session_unchanged=PASS
  echo host_panic_report_absence=PASS
  echo docker_bridge_ipv6=PASS
  echo container_global_ipv6=PASS
  echo dns_aaaa=PASS
  echo registry_aaaa=PASS
  echo ipv6_tcp_loopback=PASS
  echo wildcard_ipv4_ipv6_loopback=PASS
  echo explicit_ipv4_loopback=PASS
  echo unpublish_cleanup=PASS
  echo ssh_agent_forwarding="$SSH_AGENT_RESULT"
  if [ "$SSH_AGENT_RESULT" = PASS ]; then
    echo ssh_agent_fresh_boot=PASS
    echo ssh_agent_restart=PASS
    echo ssh_client_image="$SSH_CLIENT_IMAGE"
  fi
  echo physical_source_preservation="$SOURCE_RESULT"
  if [ "$SOURCE_ENABLED" = 1 ]; then
    echo app_executable_sha256="$(shasum -a 256 "$SOURCE_APP/Contents/MacOS/Dory" | awk '{print $1}')"
    echo source_server_image="$SOURCE_SERVER_IMAGE"
    echo lan_tcp_udp_source_preserved=PASS
    echo tailscale_tcp_udp_source_preserved=PASS
    echo explicit_loopback_remote_isolation=PASS
    echo interface_specific_privileged_tcp=PASS
    echo source_helper_restart_recovery=PASS
    echo source_engine_restart_recovery=PASS
    echo source_memory_pressure_lan=PASS
    echo source_memory_pressure_tailscale=PASS
    echo source_dns_pressure=PASS
    echo source_configd_pressure_liveness=PASS
    echo source_memory_pressure_mib="$SOURCE_PRESSURE_MIB"
    echo source_memory_pressure_rounds="$SOURCE_PRESSURE_ROUNDS"
    echo source_unpublish_cleanup=PASS
    echo source_privileged_tcp_unpublish_cleanup=PASS
    echo source_privileged_port="$SOURCE_PRIVILEGED_PORT"
    echo source_pf_reference_cleanup=PASS
    echo source_ipv4_forwarding_cleanup=PASS
  fi
  echo external_ipv6_tcp="$EXTERNAL_RESULT"
  echo release_qualifying="$RELEASE_QUALIFYING"
} > "$EVIDENCE/manifest.txt"
echo "VZ native IPv6 gate: PASS ($EVIDENCE/manifest.txt)"
