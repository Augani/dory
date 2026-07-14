#!/bin/bash
# Proves Dory's native container IPv6 contract against one isolated Apple Silicon engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HV=""
GVPROXY=""
GVPROXY_PROVENANCE=""
PAYLOAD_INVENTORY=""
KERNEL=""
ROOTFS=""
DOCKER=""
WORKROOT="${TMPDIR:-/tmp}/dory-native-ipv6-evidence"
EXTERNAL_IPV6="2606:4700:4700::1111"
REQUIRE_EXTERNAL=0
KEEP=0

usage() {
  cat <<'EOF'
Usage: scripts/native-ipv6-gate.sh --dory-hv PATH --gvproxy PATH --kernel PATH --rootfs PATH --docker PATH [options]

Options:
  --workroot DIR       Evidence root
  --gvproxy-provenance PATH  Signed-app gvproxy build provenance
  --payload-inventory PATH   Signed-app payload digest inventory
  --external-ipv6 IP   Real IPv6 TCP endpoint used on a host with IPv6 routing
  --require-external   Fail unless the Mac has IPv6 routing and the container reaches the endpoint
  --keep-workload      Preserve disposable engine files
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --keep-workload) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "native IPv6 gate: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ "$(uname -m)" = arm64 ] || { echo "native IPv6 gate: Apple silicon is required" >&2; exit 69; }
for path in "$HV" "$GVPROXY" "$KERNEL" "$ROOTFS" "$DOCKER"; do
  [ -f "$path" ] || { echo "native IPv6 gate: missing input: $path" >&2; exit 66; }
done
[ -x "$HV" ] && [ -x "$GVPROXY" ] && [ -x "$DOCKER" ] \
  || { echo "native IPv6 gate: helper inputs must be executable" >&2; exit 66; }

# shellcheck source=gvproxy-payload.sh
source "$ROOT/scripts/gvproxy-payload.sh"
dory_gvproxy_validate_overrides
if [ -n "$GVPROXY_PROVENANCE$PAYLOAD_INVENTORY" ]; then
  [ -n "$GVPROXY_PROVENANCE" ] && [ -n "$PAYLOAD_INVENTORY" ] \
    || { echo "native IPv6 gate: signed gvproxy provenance and payload inventory must be supplied together" >&2; exit 64; }
  dory_verify_signed_gvproxy_payload "$GVPROXY" "$GVPROXY_PROVENANCE" "$PAYLOAD_INVENTORY"
else
  dory_verify_gvproxy_payload \
    "$GVPROXY" "$(dory_gvproxy_version)" "$(dory_gvproxy_expected_sha256)"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
HOME_ROOT="${TMPDIR:-/tmp}/dory-ni6-$$"
STATE="$HOME_ROOT/s"
DRIVE="$HOME_ROOT/Library/Application Support/Dory/Dory.dorydrive"
SOCKET="$HOME_ROOT/e.sock"
PORT_FILE="$HOME_ROOT/host-port"
ENGINE_PID=""
HOST_PID=""
mkdir -p "$EVIDENCE" "$HOME_ROOT"

prepare_asset() {
  source_path="$1"
  output_name="$2"
  case "$source_path" in
    *.lzfse)
      prepared="$HOME_ROOT/$output_name"
      "$HV" lzfse decompress "$source_path" "$prepared" > "$EVIDENCE/decompress-$output_name.log"
      printf '%s\n' "$prepared"
      ;;
    *) printf '%s\n' "$source_path" ;;
  esac
}
KERNEL="$(prepare_asset "$KERNEL" kernel)"
ROOTFS="$(prepare_asset "$ROOTFS" rootfs.ext4)"

stop_engine() {
  [ -n "$ENGINE_PID" ] || return 0
  if kill -0 "$ENGINE_PID" 2>/dev/null; then kill -TERM "$ENGINE_PID" 2>/dev/null || true; fi
  for _ in $(seq 1 300); do
    kill -0 "$ENGINE_PID" 2>/dev/null || { wait "$ENGINE_PID" 2>/dev/null || true; ENGINE_PID=""; return 0; }
    sleep 0.1
  done
  kill -KILL "$ENGINE_PID" 2>/dev/null || true
  wait "$ENGINE_PID" 2>/dev/null || true
  ENGINE_PID=""
  return 1
}

cleanup() {
  status=$?
  set +e
  stop_engine
  [ -z "$HOST_PID" ] || kill "$HOST_PID" 2>/dev/null || true
  [ -z "$HOST_PID" ] || wait "$HOST_PID" 2>/dev/null || true
  if [ "$KEEP" -ne 1 ]; then rm -rf "$HOME_ROOT"; fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

python3 - "$PORT_FILE" <<'PY' &
import pathlib, socket, sys
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("::1", 0))
s.listen(32)
pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1]))
payload = b"dory-ipv6-loop\n"
response = b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n" + payload
while True:
    conn, _ = s.accept()
    with conn:
        conn.recv(65536)
        conn.sendall(response)
PY
HOST_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
[ -s "$PORT_FILE" ] || { echo "native IPv6 gate: host listener did not start" >&2; exit 1; }
HOST_PORT="$(cat "$PORT_FILE")"

start_engine() {
  cycle="$1"
  HOME="$HOME_ROOT" "$HV" engine \
    --state-dir "$STATE" --data-drive "$DRIVE" \
    --kernel "$KERNEL" --gvproxy "$GVPROXY" --rootfs "$ROOTFS" \
    --engine-sock "$SOCKET" --direct-ipv6 \
    >"$EVIDENCE/engine-$cycle.log" 2>&1 &
  ENGINE_PID=$!
  for _ in $(seq 1 180); do
    kill -0 "$ENGINE_PID" 2>/dev/null || {
      echo "native IPv6 gate: engine exited during $cycle" >&2
      tail -n 100 "$EVIDENCE/engine-$cycle.log" >&2
      exit 1
    }
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" info >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "native IPv6 gate: engine readiness timed out during $cycle" >&2
  exit 1
}

verify_cycle() {
  cycle="$1"
  export DOCKER_HOST="unix://$SOCKET"
  "$DOCKER" network inspect bridge > "$EVIDENCE/bridge-$cycle.json"
  "$DOCKER" run --rm alpine:3.20 sh -ec "
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

  name="dory-ni6-publish-$cycle-$$"
  host_port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  "$DOCKER" run -d --name "$name" -p "$host_port:8080" alpine:3.20 sh -c \
    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 9\\r\\nConnection: close\\r\\n\\r\\ndory-port' | nc -l -p 8080; done" \
    > "$EVIDENCE/published-$cycle.id"
  published_ok=0
  for _ in $(seq 1 60); do
    if [ "$(curl -fsS --connect-timeout 2 "http://127.0.0.1:$host_port/" 2>/dev/null)" = dory-port ] \
      && [ "$(curl -gfsS --connect-timeout 2 "http://[::1]:$host_port/" 2>/dev/null)" = dory-port ]; then
      published_ok=1
      break
    fi
    sleep 1
  done
  "$DOCKER" rm -f "$name" >/dev/null
  [ "$published_ok" = 1 ] || { echo "native IPv6 gate: dual-stack localhost publishing failed" >&2; exit 1; }
}

start_engine first
DOCKER_HOST="unix://$SOCKET" "$DOCKER" image inspect alpine:3.20 >/dev/null 2>&1 \
  || DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull alpine:3.20 > "$EVIDENCE/pull.log"
verify_cycle first
stop_engine
start_engine restart
verify_cycle restart

EXTERNAL_RESULT=SKIP
if nc -6 -z -w 10 "$EXTERNAL_IPV6" 443 >/dev/null 2>&1; then
  if DOCKER_HOST="unix://$SOCKET" "$DOCKER" run --rm alpine:3.20 \
      nc -z -w 15 "$EXTERNAL_IPV6" 443 > "$EVIDENCE/external-ipv6.out" 2> "$EVIDENCE/external-ipv6.err"; then
    EXTERNAL_RESULT=PASS
  else
    echo "native IPv6 gate: Mac has an IPv6 route but container TCP failed" >&2
    exit 1
  fi
elif [ "$REQUIRE_EXTERNAL" = 1 ]; then
  echo "native IPv6 gate: --require-external needs a real host IPv6 route" >&2
  exit 1
fi

stop_engine
cp "$STATE/gvproxy-dual-stack.yaml" "$EVIDENCE/gvproxy-dual-stack.yaml"
cp "$STATE/guest-logs/network.log" "$EVIDENCE/guest-network.log"
{
  echo status=PASS
  echo architecture=arm64
  echo gvproxy_version="$(dory_gvproxy_version)"
  echo gvproxy_sha256="$(dory_gvproxy_file_sha256 "$GVPROXY")"
  echo gvproxy_build_sha256="$(dory_gvproxy_expected_sha256)"
  echo fresh_boot=PASS
  echo restart=PASS
  echo docker_bridge_ipv6=PASS
  echo container_global_ipv6=PASS
  echo dns_aaaa=PASS
  echo registry_aaaa=PASS
  echo ipv6_tcp_loopback=PASS
  echo ipv6_localhost_publish=PASS
  echo external_ipv6_tcp="$EXTERNAL_RESULT"
  echo release_qualifying="$([ "$EXTERNAL_RESULT" = PASS ] && echo true || echo false)"
} > "$EVIDENCE/manifest.txt"
echo "native IPv6 gate: PASS ($EVIDENCE/manifest.txt)"
