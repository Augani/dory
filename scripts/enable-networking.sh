#!/bin/bash
# Dory — enable seamless local domains + automatic HTTPS system-wide. This performs privileged,
# system-modifying actions and will prompt for your admin password. Review before running; safe to
# re-run. It wires the (already-running, unprivileged) Dory DNS resolver + reverse proxy into macOS:
#
#   1) /etc/resolver/dory.local → Dory's DNS resolver (127.0.0.1:15353), so *.dory.local resolves
#      host-wide with no per-app config. DNS on a high port needs no root binding.
#   2) pf redirect :80→:8080 and :443→:8443, so http(s)://<name>.dory.local works with no port.
#   3) Installs Dory's local CA into the System trust store so the HTTPS is trusted.
#
# Undo:
#   sudo rm /etc/resolver/dory.local
#   sudo pfctl -a com.dory.rdr -F nat 2>/dev/null; sudo pfctl -d 2>/dev/null
#   sudo security delete-certificate -c "Dory Local CA" /Library/Keychains/System.keychain
set -euo pipefail

SUFFIX="dory.local"
DNS_PORT=15353
HTTP_PORT=8080
HTTPS_PORT=8443
CA_CERT="$HOME/.dory/ca/ca.crt"

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

echo "==> Installing Dory's local CA into the System trust store…"
if [ ! -f "$CA_CERT" ]; then
  echo "    CA not found at $CA_CERT — open Dory once (it generates the CA), then re-run."
  exit 1
fi
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_CERT"

echo "Done. Every published container is now reachable at https://<name>.$SUFFIX with trusted TLS."
