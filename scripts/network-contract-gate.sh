#!/bin/bash
# Release network contract: explicit upstream DNS, IPv4 and IPv6 egress, TCP and UDP publishing,
# VPN coexistence, opt-in LAN exposure, and remote client source-IP preservation. Unlike a broad
# readiness smoke, every requested contract is fail-closed and produces an artifact row.
set -euo pipefail

SOCKET="${DORY_NETWORK_CONTRACT_SOCKET:-$HOME/.dory/dory.sock}"
ALPINE_IMAGE="${DORY_NETWORK_CONTRACT_ALPINE_IMAGE:-alpine:latest}"
NGINX_IMAGE="${DORY_NETWORK_CONTRACT_NGINX_IMAGE:-nginx:alpine}"
WORKROOT="${DORY_NETWORK_CONTRACT_WORKROOT:-$HOME/.dory-network-contract}"
REGISTRY_HOST="${DORY_NETWORK_CONTRACT_REGISTRY_HOST:-registry-1.docker.io}"
CUSTOM_DNS="${DORY_NETWORK_CONTRACT_DNS:-}"
LAN_ADDRESS="${DORY_NETWORK_CONTRACT_LAN_ADDRESS:-}"
PEER_SSH="${DORY_NETWORK_CONTRACT_PEER_SSH:-}"
EXPECTED_SOURCE_IP="${DORY_NETWORK_CONTRACT_EXPECTED_SOURCE_IP:-}"
REQUIRE_VPN=0
REQUIRE_IPV6=0
REQUIRE_LAN_PEER=0

usage() {
  cat <<EOF
Usage: scripts/network-contract-gate.sh [options]

Options:
  --socket PATH          Dory Docker socket (default: ~/.dory/dory.sock)
  --custom-dns ADDRESS   Explicit DNS server; default is first active macOS resolver
  --registry-host HOST   Dual-stack registry endpoint (default: $REGISTRY_HOST)
  --lan-address ADDRESS  This Mac's LAN/Tailscale address for published-port checks
  --peer-ssh TARGET      External peer reachable with BatchMode SSH; it curls the LAN address
  --expected-source-ip IP
                         IP the container must log for the external peer
  --require-vpn          Fail unless a VPN-like interface/route is active
  --require-ipv6         Require real container IPv6 address, route, DNS AAAA, and TCP egress
  --require-lan-peer     Require external LAN/Tailscale reachability and source-IP preservation
  --workroot PATH        Evidence root (default: ~/.dory-network-contract)
  -h, --help

LAN publication is opt-in. Enable Settings -> Network -> Make published ports LAN-visible and
restart the engine before a LAN run. A host-only curl is useful preflight but cannot prove a remote
client's address; release qualification requires --peer-ssh and --expected-source-ip.
EOF
}

die() { echo "network-contract: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --custom-dns) need_value "$1" "$#"; CUSTOM_DNS="$2"; shift 2 ;;
    --registry-host) need_value "$1" "$#"; REGISTRY_HOST="$2"; shift 2 ;;
    --lan-address) need_value "$1" "$#"; LAN_ADDRESS="$2"; shift 2 ;;
    --peer-ssh) need_value "$1" "$#"; PEER_SSH="$2"; shift 2 ;;
    --expected-source-ip) need_value "$1" "$#"; EXPECTED_SOURCE_IP="$2"; shift 2 ;;
    --require-vpn) REQUIRE_VPN=1; shift ;;
    --require-ipv6) REQUIRE_IPV6=1; shift ;;
    --require-lan-peer) REQUIRE_LAN_PEER=1; shift ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
if [ "$REQUIRE_LAN_PEER" = "1" ]; then
  [ -n "$LAN_ADDRESS" ] || die "--require-lan-peer needs --lan-address"
  [ -n "$PEER_SSH" ] || die "--require-lan-peer needs --peer-ssh"
  [ -n "$EXPECTED_SOURCE_IP" ] || die "--require-lan-peer needs --expected-source-ip"
fi

if [ "${DORY_NETWORK_CONTRACT_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

for command in docker curl python3 scutil netstat route; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
docker_e() { DOCKER_HOST="unix://$SOCKET" docker "$@"; }
docker_e version >/dev/null || die "Docker API is not ready"
docker_e image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 || die "missing local image: $ALPINE_IMAGE"
docker_e image inspect "$NGINX_IMAGE" >/dev/null 2>&1 || die "missing local image: $NGINX_IMAGE"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-network-contract-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
mkdir -p "$WORKDIR"
printf 'status\ttest\tdetail\n' > "$RESULTS"

record_pass() { printf 'PASS\t%s\t%s\n' "$1" "$2" >> "$RESULTS"; echo "[PASS] $1"; }
record_skip() { printf 'SKIP\t%s\t%s\n' "$1" "$2" >> "$RESULTS"; echo "[SKIP] $1 -- $2"; }
record_fail() { printf 'FAIL\t%s\t%s\n' "$1" "$2" >> "$RESULTS"; echo "[FAIL] $1 -- $2" >&2; return 1; }

snapshot_host() {
  local dir="$1"
  mkdir -p "$dir"
  ifconfig > "$dir/interfaces.txt" 2>&1 || true
  netstat -rn > "$dir/routes.txt" 2>&1 || true
  route -n get default > "$dir/default-route.txt" 2>&1 || true
  scutil --dns > "$dir/dns.txt" 2>&1 || true
  scutil --proxy > "$dir/proxy.txt" 2>&1 || true
}

vpn_detected() {
  grep -Eiq '(^utun[0-9]*:|^ppp[0-9]*:|^tun[0-9]*:|^tap[0-9]*:|wireguard|tailscale|zerotier|vpn)' \
    "$1/interfaces.txt" "$1/routes.txt" "$1/dns.txt" 2>/dev/null
}

cleanup() {
  docker_e ps -aq --filter "label=dev.dory.network-contract=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

BEFORE="$WORKDIR/before"
AFTER="$WORKDIR/after"
snapshot_host "$BEFORE"
if vpn_detected "$BEFORE"; then
  record_pass "active VPN detected" "VPN-like interface/route recorded"
elif [ "$REQUIRE_VPN" = "1" ]; then
  record_fail "active VPN detected" "no VPN-like interface/route present"; exit 1
else
  record_skip "active VPN detected" "rerun with --require-vpn on the real corporate/VPN path"
fi

if [ -z "$CUSTOM_DNS" ]; then
  CUSTOM_DNS="$(awk '/nameserver\[[0-9]+\]/{print $3; exit}' "$BEFORE/dns.txt")"
fi
[ -n "$CUSTOM_DNS" ] || { record_fail "explicit custom DNS" "no active resolver discovered"; exit 1; }
if docker_e run --rm --dns "$CUSTOM_DNS" --label "dev.dory.network-contract=$OWNER" \
    "$ALPINE_IMAGE" getent hosts "$REGISTRY_HOST" > "$WORKDIR/custom-dns.txt" 2>&1; then
  record_pass "explicit custom DNS" "$CUSTOM_DNS resolved $REGISTRY_HOST"
else
  record_fail "explicit custom DNS" "$CUSTOM_DNS could not resolve $REGISTRY_HOST"; exit 1
fi

docker_e run --rm --label "dev.dory.network-contract=$OWNER" "$ALPINE_IMAGE" \
  nslookup "$REGISTRY_HOST" > "$WORKDIR/registry-dns.txt"
ipv4="$(awk '/^Address: /{print $2}' "$WORKDIR/registry-dns.txt" | grep -E '^[0-9]+(\.[0-9]+){3}$' | tail -1 || true)"
ipv6="$(awk '/^Address: /{print $2}' "$WORKDIR/registry-dns.txt" | grep ':' | tail -1 || true)"
[ -n "$ipv4" ] || { record_fail "registry IPv4 DNS" "no A result for $REGISTRY_HOST"; exit 1; }
if docker_e run --rm --label "dev.dory.network-contract=$OWNER" "$ALPINE_IMAGE" nc -z -w 10 "$ipv4" 443; then
  record_pass "registry IPv4 TCP" "$ipv4:443 reachable"
else
  record_fail "registry IPv4 TCP" "$ipv4:443 unreachable"; exit 1
fi

ipv6_contract() {
  [ -n "$ipv6" ] || { echo "no AAAA result for $REGISTRY_HOST"; return 1; }
  docker_e run --rm --label "dev.dory.network-contract=$OWNER" "$ALPINE_IMAGE" sh -c \
    'ip -6 addr show scope global | grep -q inet6 && ip -6 route | grep -q "^default" && nc -z -w 10 "$1" 443' sh "$ipv6"
}
if ipv6_contract > "$WORKDIR/ipv6.txt" 2>&1; then
  record_pass "registry IPv6 TCP" "$ipv6:443 reachable from a globally addressed container"
elif [ "$REQUIRE_IPV6" = "1" ]; then
  record_fail "registry IPv6 TCP" "container lacks a usable IPv6 address/route/AAAA path"; exit 1
else
  record_skip "registry IPv6 TCP" "enable --require-ipv6 for the release gate; current path did not prove IPv6"
fi

# TCP host publication.
tcp_name="$OWNER-tcp"
docker_e run -d --name "$tcp_name" --label "dev.dory.network-contract=$OWNER" -p 0.0.0.0::80 "$NGINX_IMAGE" >/dev/null
tcp_port="$(docker_e port "$tcp_name" 80/tcp | sed -nE 's/.*:([0-9]+)$/\1/p' | head -1)"
[ -n "$tcp_port" ] || { record_fail "TCP published port" "Docker returned no host port"; exit 1; }
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS "http://127.0.0.1:$tcp_port" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$tcp_port" >/dev/null
record_pass "TCP published port" "localhost:$tcp_port reachable"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl --noproxy '*' -g -fsS "http://[::1]:$tcp_port" >/dev/null 2>&1 && break
  sleep 1
done
curl --noproxy '*' -g -fsS "http://[::1]:$tcp_port" >/dev/null
record_pass "IPv6 localhost published port" "[::1]:$tcp_port reaches the IPv4 container service"

# UDP publication uses an owned echo container and a Python datagram client on the host.
udp_name="$OWNER-udp"
docker_e run -d --name "$udp_name" --label "dev.dory.network-contract=$OWNER" -p 127.0.0.1::9999/udp \
  "$ALPINE_IMAGE" sh -c 'while true; do nc -u -l -p 9999 -e cat; done' >/dev/null
udp_port="$(docker_e port "$udp_name" 9999/udp | sed -nE 's/.*:([0-9]+)$/\1/p' | head -1)"
[ -n "$udp_port" ] || { record_fail "UDP published port" "Docker returned no host UDP port"; exit 1; }
python3 - "$udp_port" <<'PY'
import socket, sys, time
port = int(sys.argv[1]); payload = b"dory-udp-contract"
deadline = time.time() + 10
while time.time() < deadline:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.settimeout(1)
    try:
        sock.sendto(payload, ("127.0.0.1", port))
        data, _ = sock.recvfrom(4096)
        if data == payload: raise SystemExit(0)
    except TimeoutError: pass
    finally: sock.close()
raise SystemExit("UDP echo timed out")
PY
record_pass "UDP published port" "localhost:$udp_port echo preserved payload"

if [ -n "$LAN_ADDRESS" ]; then
  if curl -fsS --connect-timeout 5 "http://$LAN_ADDRESS:$tcp_port" >/dev/null; then
    record_pass "LAN-address published port" "$LAN_ADDRESS:$tcp_port reachable from host"
  else
    record_fail "LAN-address published port" "$LAN_ADDRESS:$tcp_port is not reachable; enable LAN visibility and restart Dory"; exit 1
  fi
else
  record_skip "LAN-address published port" "provide --lan-address after enabling LAN visibility"
fi

if [ -n "$PEER_SSH" ] && [ -n "$EXPECTED_SOURCE_IP" ] && [ -n "$LAN_ADDRESS" ]; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$PEER_SSH" \
    "curl -fsS --connect-timeout 5 http://$LAN_ADDRESS:$tcp_port >/dev/null"
  sleep 1
  docker_e logs "$tcp_name" > "$WORKDIR/nginx-access.log" 2>&1
  if grep -Eq "^${EXPECTED_SOURCE_IP//./\\.}[[:space:]]" "$WORKDIR/nginx-access.log"; then
    record_pass "remote source IP preservation" "$EXPECTED_SOURCE_IP reached the container unchanged"
  else
    observed="$(tail -1 "$WORKDIR/nginx-access.log" | awk '{print $1}')"
    record_fail "remote source IP preservation" "expected $EXPECTED_SOURCE_IP, container observed ${observed:-unknown}"; exit 1
  fi
elif [ "$REQUIRE_LAN_PEER" = "1" ]; then
  record_fail "remote source IP preservation" "external peer arguments missing"; exit 1
else
  record_skip "remote source IP preservation" "requires --lan-address, --peer-ssh, and --expected-source-ip"
fi

cleanup
snapshot_host "$AFTER"
for file in default-route.txt dns.txt proxy.txt; do
  diff -u "$BEFORE/$file" "$AFTER/$file" > "$WORKDIR/$file.diff" \
    || { record_fail "host network state preservation" "$file changed during the campaign"; exit 1; }
done
record_pass "host network state preservation" "default route, DNS, and proxy snapshots unchanged"

{
  echo "run_id=$RUN_ID"
  echo "vpn_required=$REQUIRE_VPN"
  echo "ipv6_required=$REQUIRE_IPV6"
  echo "lan_peer_required=$REQUIRE_LAN_PEER"
  echo "release_qualifying=$([ "$REQUIRE_VPN" = 1 ] && [ "$REQUIRE_IPV6" = 1 ] && [ "$REQUIRE_LAN_PEER" = 1 ] && echo true || echo false)"
} > "$WORKDIR/manifest.txt"
echo "network contract gate PASS; evidence: $WORKDIR"
