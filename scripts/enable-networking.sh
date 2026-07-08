#!/bin/bash
# Dory — enable seamless local domains + automatic HTTPS system-wide. This performs privileged,
# system-modifying actions and will prompt for your admin password. Review before running; safe to
# re-run. It wires the (already-running, unprivileged) Dory DNS resolver + reverse proxy into macOS:
#
#   1) /etc/resolver/dory.local → Dory's DNS resolver (127.0.0.1:15353), so *.dory.local resolves
#      host-wide with no per-app config. DNS on a high port needs no root binding.
#   2) pf redirect :80 -> :8080 and :443 -> :8443, so http(s)://<name>.dory.local works with no port.
#   3) Installs Dory's local CA into the System trust store so the HTTPS is trusted.
#   4) Optional: --direct-ip adds the container subnet route used by the direct-IP data path.
#
# Undo:
#   sudo rm /etc/resolver/dory.local
#   sudo pfctl -a com.apple/dev.dory -F all 2>/dev/null
#   sudo security delete-certificate -c "Dory Local CA" /Library/Keychains/System.keychain
#   sudo /sbin/route -n delete -net 192.168.215.0/24
set -euo pipefail

SUFFIX="dory.local"
DNS_PORT=15353
HTTP_PORT=8080
HTTPS_PORT=8443
CA_CERT="$HOME/.dory/ca/ca.crt"
DIRECT_IP=0
REMOVE=0
DRY_RUN=0
PRIVILEGED_FORWARDS=()
CONTAINER_SUBNET="192.168.215.0/24"
HOST_GATEWAY="192.168.127.1"
GUEST_GATEWAY="192.168.127.2"
DIRECT_IP_INTERFACE=""
DIRECT_IP_INTERFACE_FILE="$HOME/.dory/hv/direct-ip.interface"

usage() {
  cat <<EOF
Usage: $0 [--direct-ip] [--forward LOW:HIGH] [--container-subnet CIDR] [--host-gateway IPv4] [--guest-gateway IPv4] [--direct-ip-interface IFACE] [--dry-run] [--remove]

  --direct-ip             Add/remove the direct container-IP route with the same admin consent flow.
  --forward LOW:HIGH      Add a privileged TCP redirect only in fallback mode, e.g. 25:1025. With
                          live doryd, currently published low TCP ports are discovered automatically;
                          use DORYD_PRIVILEGED_TCP_FORWARDS only for static extra redirects.
  --container-subnet CIDR Container bridge subnet to route. Default: $CONTAINER_SUBNET
  --host-gateway IPv4     Host-side point-to-point utun address. Default: $HOST_GATEWAY
  --guest-gateway IPv4    Guest/gvproxy gateway for that subnet. Default: $GUEST_GATEWAY
  --direct-ip-interface IFACE
                          Route via an active Dory utun interface. Defaults to reading
                          $DIRECT_IP_INTERFACE_FILE, written by dory-hv while the engine runs.
  --dry-run               Validate and print the generated authorization work without sudo.
  --remove                Remove installed resolver/pf/direct-IP route entries.
EOF
}

valid_ipv4() {
  local ip="$1" IFS=. parts part
  read -r -a parts <<< "$ip"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
    [ "$part" = "0" ] || [[ "$part" != 0* ]] || return 1
  done
}

valid_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

valid_interface() {
  local iface="$1"
  [[ "$iface" =~ ^[A-Za-z0-9_-]{1,15}$ ]]
}

valid_forward() {
  local mapping="$1" low high
  [[ "$mapping" == *:* ]] || return 1
  low="${mapping%%:*}"
  high="${mapping#*:}"
  [[ "$low" =~ ^[0-9]+$ && "$high" =~ ^[0-9]+$ ]] || return 1
  [ "$low" -ge 1 ] && [ "$low" -lt 1024 ] || return 1
  [ "$high" -ge 1024 ] && [ "$high" -le 65535 ] || return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --direct-ip) DIRECT_IP=1; shift ;;
    --forward) PRIVILEGED_FORWARDS+=("${2:?missing LOW:HIGH}"); shift 2 ;;
    --container-subnet) CONTAINER_SUBNET="${2:?missing CIDR}"; shift 2 ;;
    --host-gateway) HOST_GATEWAY="${2:?missing IPv4}"; shift 2 ;;
    --guest-gateway) GUEST_GATEWAY="${2:?missing IPv4}"; shift 2 ;;
    --direct-ip-interface) DIRECT_IP_INTERFACE="${2:?missing interface}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

valid_cidr "$CONTAINER_SUBNET" || { echo "invalid --container-subnet: $CONTAINER_SUBNET" >&2; exit 2; }
valid_ipv4 "$HOST_GATEWAY" || { echo "invalid --host-gateway: $HOST_GATEWAY" >&2; exit 2; }
valid_ipv4 "$GUEST_GATEWAY" || { echo "invalid --guest-gateway: $GUEST_GATEWAY" >&2; exit 2; }
if [ "${#PRIVILEGED_FORWARDS[@]}" -gt 0 ]; then
  for forward in "${PRIVILEGED_FORWARDS[@]}"; do
    valid_forward "$forward" || { echo "invalid --forward: $forward (expected LOW:HIGH with LOW < 1024 and HIGH >= 1024)" >&2; exit 2; }
  done
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

first_executable() {
  local cand
  for cand in "$@"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

latest_debug_app_helper() {
  local name="$1" app cand
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    cand="$app/Contents/Helpers/$name"
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

find_dorydctl() {
  first_executable \
    "${DORYD_CTL:-}" \
    "$ROOT/dory-core-swift/.build/debug/dorydctl" \
    "$ROOT/dory-core-swift/.build/$(uname -m)-apple-macosx/debug/dorydctl" \
    "$HOME/.dory/bin/dorydctl" \
    "$(latest_debug_app_helper dorydctl 2>/dev/null)" \
    "$(command -v dorydctl 2>/dev/null || true)"
}

find_network_helper() {
  first_executable \
    "${DORY_NETWORK_HELPER:-}" \
    "$ROOT/dory-core-swift/.build/debug/dory-network-helper" \
    "$ROOT/dory-core-swift/.build/$(uname -m)-apple-macosx/debug/dory-network-helper" \
    "$HOME/.dory/bin/dory-network-helper" \
    "$(latest_debug_app_helper dory-network-helper 2>/dev/null)" \
    "$(command -v dory-network-helper 2>/dev/null || true)"
}

apply_live_doryd_plan() {
  local ctl helper plan rc
  ctl="$(find_dorydctl || true)"
  helper="$(find_network_helper || true)"
  [ -n "$ctl" ] && [ -n "$helper" ] || return 2
  plan="$(mktemp "${TMPDIR:-/tmp}/dory-network-plan.XXXXXX.json")"
  if ! "$ctl" --timeout 30 network authorization-plan > "$plan" 2>/dev/null; then
    rm -f "$plan"
    return 2
  fi
  echo "==> Applying live doryd networking authorization plan with $helper"
  if [ "${#PRIVILEGED_FORWARDS[@]}" -gt 0 ]; then
    echo "    note: live doryd plans ignore --forward; doryd discovers Docker-published low TCP ports automatically."
  fi
  if [ "$DRY_RUN" = "1" ]; then
    "$helper" --dry-run --plan-json "$plan"
    rc=$?
  else
    sudo "$helper" --plan-json "$plan"
    rc=$?
  fi
  rm -f "$plan"
  return "$rc"
}

apply_fallback_plan() {
  echo "==> doryd authorization plan unavailable; using script defaults."
  if [ "$DRY_RUN" = "1" ]; then
    cat <<EOF
resolver: /etc/resolver/$SUFFIX -> 127.0.0.1:$DNS_PORT
pf anchor: /etc/pf.anchors/dev.dory loaded as com.apple/dev.dory
http:  127.0.0.1:80  -> 127.0.0.1:$HTTP_PORT
https: 127.0.0.1:443 -> 127.0.0.1:$HTTPS_PORT
trust: $CA_CERT
EOF
    if [ "${#PRIVILEGED_FORWARDS[@]}" -gt 0 ]; then
      for forward in "${PRIVILEGED_FORWARDS[@]}"; do
        echo "tcp:   127.0.0.1:${forward%%:*}  -> 127.0.0.1:${forward#*:}"
      done
    fi
    return 0
  fi

  echo "==> Pointing the system resolver for *.$SUFFIX at Dory's DNS (127.0.0.1:$DNS_PORT)..."
  sudo mkdir -p /etc/resolver
  sudo tee "/etc/resolver/$SUFFIX" >/dev/null <<EOF
nameserver 127.0.0.1
port $DNS_PORT
EOF

  echo "==> Redirecting :80 -> :$HTTP_PORT and :443 -> :$HTTPS_PORT via pf..."
  sudo tee "/etc/pf.anchors/dev.dory" >/dev/null <<EOF
# Managed by Dory. Do not edit.
rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port $HTTP_PORT
rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port $HTTPS_PORT
EOF
  if [ "${#PRIVILEGED_FORWARDS[@]}" -gt 0 ]; then
    for forward in "${PRIVILEGED_FORWARDS[@]}"; do
      echo "rdr pass on lo0 inet proto tcp from any to any port ${forward%%:*} -> 127.0.0.1 port ${forward#*:}" \
        | sudo tee -a /etc/pf.anchors/dev.dory >/dev/null
    done
  fi
  sudo pfctl -a com.apple/dev.dory -f /etc/pf.anchors/dev.dory
  sudo pfctl -E >/dev/null 2>&1 || true

  echo "==> Installing Dory's local CA into the System trust store..."
  if [ ! -f "$CA_CERT" ]; then
    echo "    CA not found at $CA_CERT - open Dory once (it generates the CA), then re-run."
    exit 1
  fi
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_CERT"
}

if [ "$REMOVE" = "1" ]; then
  echo "==> Removing Dory networking integration..."
  if [ "$DRY_RUN" = "1" ]; then
    echo "would remove /etc/resolver/$SUFFIX"
    echo "would remove /etc/pf.anchors/dev.dory and flush com.apple/dev.dory"
    [ "$DIRECT_IP" = "1" ] && echo "would remove direct-IP route $CONTAINER_SUBNET"
    exit 0
  fi
  sudo rm -f "/etc/resolver/$SUFFIX"
  sudo rm -f /etc/pf.anchors/dev.dory /etc/pf.anchors/com.dory.rdr 2>/dev/null || true
  sudo pfctl -a com.apple/dev.dory -F all 2>/dev/null || true
  sudo pfctl -a dev.dory -F all 2>/dev/null || true
  sudo pfctl -a com.dory.rdr -F all 2>/dev/null || true
  if [ "$DIRECT_IP" = "1" ]; then
    if [ -z "$DIRECT_IP_INTERFACE" ] && [ -f "$DIRECT_IP_INTERFACE_FILE" ]; then
      DIRECT_IP_INTERFACE="$(tr -d '[:space:]' < "$DIRECT_IP_INTERFACE_FILE")"
    fi
    sudo /sbin/route -n delete -net "$CONTAINER_SUBNET" 2>/dev/null || true
    if valid_interface "$DIRECT_IP_INTERFACE"; then
      sudo /sbin/ifconfig "$DIRECT_IP_INTERFACE" down 2>/dev/null || true
    fi
  fi
  echo "Done."
  exit 0
fi

if apply_live_doryd_plan; then
  :
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    apply_fallback_plan
  else
    exit "$rc"
  fi
fi

if [ "$DIRECT_IP" = "1" ]; then
  if [ -z "$DIRECT_IP_INTERFACE" ] && [ -f "$DIRECT_IP_INTERFACE_FILE" ]; then
    DIRECT_IP_INTERFACE="$(tr -d '[:space:]' < "$DIRECT_IP_INTERFACE_FILE")"
  fi
  valid_interface "$DIRECT_IP_INTERFACE" || {
    echo "direct IP needs a running Dory engine utun interface; start Dory, then re-run or pass --direct-ip-interface utunN" >&2
    exit 2
  }
  if [ "$DRY_RUN" = "1" ]; then
    echo "would configure $DIRECT_IP_INTERFACE as $HOST_GATEWAY -> $GUEST_GATEWAY"
    echo "would route $CONTAINER_SUBNET through $DIRECT_IP_INTERFACE"
  else
  echo "==> Configuring $DIRECT_IP_INTERFACE as $HOST_GATEWAY -> $GUEST_GATEWAY for direct container/machine IP access..."
  sudo /sbin/ifconfig "$DIRECT_IP_INTERFACE" inet "$HOST_GATEWAY" "$GUEST_GATEWAY" up
  echo "==> Routing $CONTAINER_SUBNET through $DIRECT_IP_INTERFACE..."
  sudo /sbin/route -n delete -net "$CONTAINER_SUBNET" 2>/dev/null || true
  sudo /sbin/route -n add -net "$CONTAINER_SUBNET" -interface "$DIRECT_IP_INTERFACE"
  fi
fi

echo "Done. Every published container is now reachable at https://<name>.$SUFFIX with trusted TLS."
