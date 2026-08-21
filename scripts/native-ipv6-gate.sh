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
IMAGE="alpine:3.20"
WORKROOT="${TMPDIR:-/tmp}/dory-native-ipv6-evidence"
EXTERNAL_IPV6="2606:4700:4700::1111"
REQUIRE_EXTERNAL=0
KEEP=0
SOURCE_COMMIT=""
CONFIRM=""
RELEASE_CANDIDATE=0

usage() {
  cat <<'EOF'
Usage: scripts/native-ipv6-gate.sh --dory-hv PATH --gvproxy PATH --kernel PATH --rootfs PATH --docker PATH [options]

Options:
  --workroot DIR       Evidence root
  --image REF          Preloaded Alpine-compatible fixture image
  --source-commit SHA  Exact 40-character source commit for release evidence
  --confirm TOKEN      Must be ISOLATED-ENGINE-NATIVE-IPV6
  --release-candidate  Require signed, digest-pinned release inputs
  --gvproxy-provenance PATH  Signed-app gvproxy build provenance
  --payload-inventory PATH   Signed-app payload digest inventory
  --external-ipv6 IP   Real IPv6 TCP endpoint used on a host with IPv6 routing
  --require-external   Fail unless the Mac has IPv6 routing and the container reaches the endpoint
  --keep-workload      Preserve disposable engine files
EOF
}

die() { echo "native IPv6 gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dory-hv) need_value "$1" "$#"; HV="$2"; shift 2 ;;
    --gvproxy) need_value "$1" "$#"; GVPROXY="$2"; shift 2 ;;
    --gvproxy-provenance) need_value "$1" "$#"; GVPROXY_PROVENANCE="$2"; shift 2 ;;
    --payload-inventory) need_value "$1" "$#"; PAYLOAD_INVENTORY="$2"; shift 2 ;;
    --kernel) need_value "$1" "$#"; KERNEL="$2"; shift 2 ;;
    --rootfs) need_value "$1" "$#"; ROOTFS="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --external-ipv6) need_value "$1" "$#"; EXTERNAL_IPV6="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --release-candidate) RELEASE_CANDIDATE=1; shift ;;
    --require-external) REQUIRE_EXTERNAL=1; shift ;;
    --keep-workload) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "native IPv6 gate: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-NATIVE-IPV6 ] \
  || die "requires --confirm ISOLATED-ENGINE-NATIVE-IPV6"
for command in curl id nc ps python3 seq shasum stat uname; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done
[ "$(uname -m)" = arm64 ] || { echo "native IPv6 gate: Apple silicon is required" >&2; exit 69; }
for path in "$HV" "$GVPROXY" "$KERNEL" "$ROOTFS" "$DOCKER"; do
  case "$path" in /*) ;; *) die "candidate inputs must use absolute paths" ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] \
    || { echo "native IPv6 gate: missing or indirect input: $path" >&2; exit 66; }
done
[ -x "$HV" ] && [ -x "$GVPROXY" ] && [ -x "$DOCKER" ] \
  || { echo "native IPv6 gate: helper inputs must be executable" >&2; exit 66; }
if [ -n "$SOURCE_COMMIT" ]; then
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || die "source commit must be a full lowercase Git SHA"
fi
python3 - "$EXTERNAL_IPV6" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv6Address(sys.argv[1])
except ValueError as error:
    raise SystemExit(f"external IPv6 endpoint is invalid: {error}")
PY
if [ "$RELEASE_CANDIDATE" -eq 1 ]; then
  [ -n "$SOURCE_COMMIT" ] || die "release candidate evidence requires --source-commit"
  [ "$REQUIRE_EXTERNAL" -eq 1 ] || die "release candidate evidence requires --require-external"
  printf '%s\n' "$IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || die "release candidate image must be digest-pinned"
  [ -n "$GVPROXY_PROVENANCE" ] && [ -n "$PAYLOAD_INVENTORY" ] \
    || die "release candidate evidence requires signed gvproxy provenance and payload inventory"
fi
case "$WORKROOT" in /*) ;; *) die "workroot must be an absolute path" ;; esac
case "$WORKROOT" in /|"$HOME") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"

# shellcheck source=gvproxy-payload.sh
source "$ROOT/scripts/gvproxy-payload.sh"
dory_gvproxy_validate_overrides
if [ -n "$GVPROXY_PROVENANCE$PAYLOAD_INVENTORY" ]; then
  [ -n "$GVPROXY_PROVENANCE" ] && [ -n "$PAYLOAD_INVENTORY" ] \
    || { echo "native IPv6 gate: signed gvproxy provenance and payload inventory must be supplied together" >&2; exit 64; }
  for authority_path in "$GVPROXY_PROVENANCE" "$PAYLOAD_INVENTORY"; do
    case "$authority_path" in /*) ;; *) die "signed gvproxy authority must use absolute paths" ;; esac
    [ -f "$authority_path" ] && [ ! -L "$authority_path" ] && [ -s "$authority_path" ] \
      || die "signed gvproxy authority is missing or indirect: $authority_path"
  done
  dory_verify_signed_gvproxy_payload "$GVPROXY" "$GVPROXY_PROVENANCE" "$PAYLOAD_INVENTORY"
else
  dory_verify_gvproxy_payload \
    "$GVPROXY" "$(dory_gvproxy_version)" "$(dory_gvproxy_expected_sha256)"
fi
mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
input_hv_sha="$(shasum -a 256 "$HV" | awk '{print $1}')"
input_gvproxy_sha="$(shasum -a 256 "$GVPROXY" | awk '{print $1}')"
input_kernel_sha="$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
input_rootfs_sha="$(shasum -a 256 "$ROOTFS" | awk '{print $1}')"
input_docker_sha="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
HOME_BASE="${DORY_NATIVE_IPV6_HOME_BASE:-$HOME}"
HOME_BASE="$(cd "$HOME_BASE" 2>/dev/null && pwd -P)" || {
  echo "native IPv6 gate: runtime HOME base is unavailable: $HOME_BASE" >&2
  exit 66
}
HOME_ROOT="$HOME_BASE/.dni6-$$"
STATE="$HOME_ROOT/s"
DRIVE="$HOME_ROOT/Library/Application Support/Dory/Dory.dorydrive"
SOCKET="$HOME_ROOT/e.sock"
PORT_FILE="$HOME_ROOT/host-port"
ENGINE_PID=""
HOST_PID=""
[ ! -e "$HOME_ROOT" ] || {
  echo "native IPv6 gate: isolated runtime HOME already exists: $HOME_ROOT" >&2
  exit 73
}
[ ! -L "$HOME_ROOT" ] || die "isolated runtime HOME is indirect: $HOME_ROOT"
python3 - "$SOCKET" "$STATE/docker-backend.sock" "$STATE/gvproxy-api.sock" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    length = len(os.fsencode(path))
    if length > 103:
        raise SystemExit(f"native IPv6 Unix socket path is {length} bytes (limit 103): {path}")
PY
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

docker_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_HOST="unix://$SOCKET" \
    "$DOCKER" "$@"
}

stop_engine() {
  [ -n "$ENGINE_PID" ] || return 0
  cycle_pid="$ENGINE_PID"
  ps -axo pid=,ppid=,command= | awk -v parent="$cycle_pid" '$2 == parent { print }' \
    > "$EVIDENCE/engine-children-before-stop-$cycle_pid.txt"
  gvproxy_pids="$(awk '/gvproxy/ { print $1 }' "$EVIDENCE/engine-children-before-stop-$cycle_pid.txt")"
  if kill -0 "$ENGINE_PID" 2>/dev/null; then kill -TERM "$ENGINE_PID" 2>/dev/null || true; fi
  for _ in $(seq 1 300); do
    kill -0 "$ENGINE_PID" 2>/dev/null || {
      wait "$ENGINE_PID" 2>/dev/null || true
      ENGINE_PID=""
      for child_pid in $gvproxy_pids; do
        if kill -0 "$child_pid" 2>/dev/null; then
          echo "native IPv6 gate: gvproxy child $child_pid survived engine shutdown" >&2
          return 1
        fi
      done
      return 0
    }
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    docker_e info >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "native IPv6 gate: engine readiness timed out during $cycle" >&2
  exit 1
}

verify_cycle() {
  cycle="$1"
  kill -0 "$HOST_PID" 2>/dev/null || {
    echo "native IPv6 gate: host IPv6 listener exited before $cycle verification" >&2
    exit 1
  }
  host_response="$(curl --noproxy '*' -gfsS --connect-timeout 2 "http://[::1]:$HOST_PORT/")"
  printf '%s\n' "$host_response" > "$EVIDENCE/host-listener-$cycle.txt"
  [ "$host_response" = dory-ipv6-loop ] || {
    echo "native IPv6 gate: host IPv6 listener failed before $cycle verification" >&2
    exit 1
  }
  docker_e network inspect bridge > "$EVIDENCE/bridge-$cycle.json"
  docker_e run --rm "$IMAGE" sh -ec "
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
if bridge["EnableIPv6"] is not True:
    raise SystemExit("default bridge does not enable IPv6")
if not any(x.get("Subnet") == "fd7d:6f72:7901::/64" for x in bridge["IPAM"]["Config"]):
    raise SystemExit("default bridge omits the exact qualified IPv6 subnet")
if "inet6 fd7d:6f72:7901::" not in text:
    raise SystemExit("container does not have an address on the qualified IPv6 subnet")
if "2606:4700:4700::" not in text:
    raise SystemExit("Cloudflare AAAA resolution is missing")
if "2600:1f18:" not in text:
    raise SystemExit("registry AAAA resolution is missing")
PY

  name="dory-ni6-publish-$cycle-$$"
  host_port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  docker_e run -d --name "$name" -p "$host_port:8080" "$IMAGE" sh -c \
    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 9\\r\\nConnection: close\\r\\n\\r\\ndory-port' | nc -l -p 8080; done" \
    > "$EVIDENCE/published-$cycle.id"
  published_ok=0
  for _ in $(seq 1 60); do
    if [ "$(curl --noproxy '*' -fsS --connect-timeout 2 "http://127.0.0.1:$host_port/" 2>/dev/null)" = dory-port ] \
      && [ "$(curl --noproxy '*' -gfsS --connect-timeout 2 "http://[::1]:$host_port/" 2>/dev/null)" = dory-port ]; then
      published_ok=1
      break
    fi
    sleep 1
  done
  docker_e rm -f "$name" >/dev/null
  [ "$published_ok" = 1 ] || { echo "native IPv6 gate: dual-stack localhost publishing failed" >&2; exit 1; }
}

start_engine first
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] || die "engine socket is missing or indirect"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "engine socket is not owned by the release user"
if ! docker_e image inspect "$IMAGE" >/dev/null 2>&1; then
  [ "$RELEASE_CANDIDATE" -eq 0 ] || die "release candidate image is not preloaded"
  docker_e pull "$IMAGE" > "$EVIDENCE/pull.log"
fi
image_id="$(docker_e image inspect -f '{{.Id}}' "$IMAGE")"
verify_cycle first
stop_engine
start_engine restart
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] || die "restart socket is missing or indirect"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "restart socket is not owned by the release user"
[ "$(docker_e image inspect -f '{{.Id}}' "$IMAGE")" = "$image_id" ] \
  || die "engine restart changed the exact fixture image identity"
verify_cycle restart

EXTERNAL_RESULT=SKIP
if nc -6 -z -w 10 "$EXTERNAL_IPV6" 443 >/dev/null 2>&1; then
  if docker_e run --rm "$IMAGE" \
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
release_qualifying=false
if [ "$RELEASE_CANDIDATE" -eq 1 ] && [ "$EXTERNAL_RESULT" = PASS ]; then
  release_qualifying=true
fi
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
  echo exact_image_identity=PASS
  echo same_user_engine_socket=PASS
  echo source_commit="$SOURCE_COMMIT"
  echo dory_hv_sha256="$input_hv_sha"
  echo gvproxy_input_sha256="$input_gvproxy_sha"
  echo kernel_input_sha256="$input_kernel_sha"
  echo rootfs_input_sha256="$input_rootfs_sha"
  echo docker_cli_sha256="$input_docker_sha"
  echo image_id="$image_id"
  echo network_contract_sha256="$(shasum -a 256 "$EVIDENCE/gvproxy-dual-stack.yaml" | awk '{print $1}')"
  echo guest_network_log_sha256="$(shasum -a 256 "$EVIDENCE/guest-network.log" | awk '{print $1}')"
  echo release_qualifying="$release_qualifying"
} > "$EVIDENCE/manifest.txt"
echo "native IPv6 gate: PASS ($EVIDENCE/manifest.txt)"
