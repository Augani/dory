#!/bin/bash
# Dory — enable seamless local domains + automatic HTTPS system-wide. This performs privileged,
# system-modifying actions and will prompt for your admin password. Review before running; safe to
# re-run. It wires the (already-running, unprivileged) Dory DNS resolver + reverse proxy into macOS:
#
#   1) /etc/resolver/dory.local → Dory's DNS resolver (127.0.0.1:15353), so *.dory.local resolves
#      host-wide with no per-app config. DNS on a high port needs no root binding.
#   2) pf redirect :80→:8080 and :443→:8443, so http(s)://<name>.dory.local works with no port.
#   3) Installs Dory's local CA into the System trust store so the HTTPS is trusted.
#   4) Optional: --direct-ip adds the container subnet route used by the direct-IP data path.
#
# Undo:
#   sudo rm /etc/resolver/dory.local
#   sudo pfctl -a com.dory.rdr -F nat 2>/dev/null; sudo pfctl -d 2>/dev/null
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
CONTAINER_SUBNET="192.168.215.0/24"
HOST_GATEWAY="192.168.127.1"
GUEST_GATEWAY="192.168.127.2"
DIRECT_IP_INTERFACE=""
DIRECT_IP_INTERFACE_FILE="$HOME/.dory/hv/direct-ip.interface"

usage() {
  cat <<EOF
Usage: $0 [--direct-ip] [--container-subnet CIDR] [--host-gateway IPv4] [--guest-gateway IPv4] [--direct-ip-interface IFACE] [--remove]

  --direct-ip             Add/remove the direct container-IP route with the same admin consent flow.
  --container-subnet CIDR Container bridge subnet to route. Default: $CONTAINER_SUBNET
  --host-gateway IPv4     Host-side point-to-point utun address. Default: $HOST_GATEWAY
  --guest-gateway IPv4    Guest/gvproxy gateway for that subnet. Default: $GUEST_GATEWAY
  --direct-ip-interface IFACE
                          Route via an active Dory utun interface. Defaults to reading
                          $DIRECT_IP_INTERFACE_FILE, written by dory-hv while the engine runs.
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --direct-ip) DIRECT_IP=1; shift ;;
    --container-subnet) CONTAINER_SUBNET="${2:?missing CIDR}"; shift 2 ;;
    --host-gateway) HOST_GATEWAY="${2:?missing IPv4}"; shift 2 ;;
    --guest-gateway) GUEST_GATEWAY="${2:?missing IPv4}"; shift 2 ;;
    --direct-ip-interface) DIRECT_IP_INTERFACE="${2:?missing interface}"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

valid_cidr "$CONTAINER_SUBNET" || { echo "invalid --container-subnet: $CONTAINER_SUBNET" >&2; exit 2; }
valid_ipv4 "$HOST_GATEWAY" || { echo "invalid --host-gateway: $HOST_GATEWAY" >&2; exit 2; }
valid_ipv4 "$GUEST_GATEWAY" || { echo "invalid --guest-gateway: $GUEST_GATEWAY" >&2; exit 2; }

if [ "$REMOVE" = "1" ]; then
  echo "==> Removing Dory networking integration…"
  sudo rm -f "/etc/resolver/$SUFFIX"
  sudo pfctl -a com.dory.rdr -F nat 2>/dev/null || true
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

echo "==> Pointing the system resolver for *.$SUFFIX at Dory's DNS (127.0.0.1:$DNS_PORT)…"
sudo mkdir -p /etc/resolver
sudo tee "/etc/resolver/$SUFFIX" >/dev/null <<EOF
nameserver 127.0.0.1
port $DNS_PORT
EOF

echo "==> Redirecting :80→:$HTTP_PORT and :443→:$HTTPS_PORT via pf…"
ANCHOR=com.dory.rdr
sudo tee "/etc/pf.anchors/$ANCHOR" >/dev/null <<EOF
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port $HTTP_PORT
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port $HTTPS_PORT
EOF
if ! grep -q "$ANCHOR" /etc/pf.conf 2>/dev/null; then
  echo "rdr-anchor \"$ANCHOR\"" | sudo tee -a /etc/pf.conf >/dev/null
  echo "load anchor \"$ANCHOR\" from \"/etc/pf.anchors/$ANCHOR\"" | sudo tee -a /etc/pf.conf >/dev/null
fi
sudo pfctl -f /etc/pf.conf -e 2>/dev/null || true

if [ "$DIRECT_IP" = "1" ]; then
  if [ -z "$DIRECT_IP_INTERFACE" ] && [ -f "$DIRECT_IP_INTERFACE_FILE" ]; then
    DIRECT_IP_INTERFACE="$(tr -d '[:space:]' < "$DIRECT_IP_INTERFACE_FILE")"
  fi
  valid_interface "$DIRECT_IP_INTERFACE" || {
    echo "direct IP needs a running Dory engine utun interface; start Dory, then re-run or pass --direct-ip-interface utunN" >&2
    exit 2
  }
  echo "==> Configuring $DIRECT_IP_INTERFACE as $HOST_GATEWAY → $GUEST_GATEWAY for direct container/machine IP access…"
  sudo /sbin/ifconfig "$DIRECT_IP_INTERFACE" inet "$HOST_GATEWAY" "$GUEST_GATEWAY" up
  echo "==> Routing $CONTAINER_SUBNET through $DIRECT_IP_INTERFACE…"
  sudo /sbin/route -n delete -net "$CONTAINER_SUBNET" 2>/dev/null || true
  sudo /sbin/route -n add -net "$CONTAINER_SUBNET" -interface "$DIRECT_IP_INTERFACE"
fi

echo "==> Installing Dory's local CA into the System trust store…"
if [ ! -f "$CA_CERT" ]; then
  echo "    CA not found at $CA_CERT — open Dory once (it generates the CA), then re-run."
  exit 1
fi
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_CERT"

echo "Done. Every published container is now reachable at https://<name>.$SUFFIX with trusted TLS."
