#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE=0
RELEASE=0
BASELINE=""
OUTPUT=""
EXPECT_INTERFACE=""
EXPECT_DNS=""
REQUIRE_PROXY=0
REQUIRE_CA=0

usage() {
  cat <<'EOF'
Usage: scripts/corporate-connectivity-gate.sh [options]

Without --live, performs the hermetic source/contract gate used by CI.

  --live                    Query the installed doryd profile and run its bounded probes
  --release                 Require a changed baseline plus explicit VPN/DNS expectations
  --baseline STATUS.json    Earlier live status captured before VPN/exit-node/DHCP churn
  --expect-interface NAME   Require this route or tunnel interface in current evidence
  --expect-dns ADDRESS      Require a successful probe sent explicitly to this DNS server
  --require-proxy           Require every registry probe to name its selected proxy
  --require-ca              Require at least one registry probe to name an applied CA id
  --output PATH             Write the current schema-v1 status to PATH

A release-qualifying run is intentionally two-phase: capture a live baseline, perform the
physical VPN/Tailscale/DHCP/sleep-wake transition, then run --live --release with that baseline.
The gate never toggles VPNs, sleeps the user's Mac, or changes a profile on its own.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --release) RELEASE=1; LIVE=1; shift ;;
    --baseline) BASELINE="${2:?--baseline requires a path}"; shift 2 ;;
    --output) OUTPUT="${2:?--output requires a path}"; shift 2 ;;
    --expect-interface) EXPECT_INTERFACE="${2:?--expect-interface requires a name}"; shift 2 ;;
    --expect-dns) EXPECT_DNS="${2:?--expect-dns requires an address}"; shift 2 ;;
    --require-proxy) REQUIRE_PROXY=1; shift ;;
    --require-ca) REQUIRE_CA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "corporate connectivity gate: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_source() {
  local pattern="$1" file="$2" detail="$3"
  rg -q -- "$pattern" "$ROOT/$file" || {
    echo "corporate connectivity gate: missing $detail in $file" >&2
    exit 1
  }
}

require_source 'dev\.dory\.corporate-connectivity' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'versioned profile schema'
require_source 'var host: CorporateProxyLayer' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'macOS/PAC proxy layer'
require_source 'var dockerd: CorporateProxyLayer' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'dockerd pull layer'
require_source 'var buildKit: CorporateProxyLayer' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'BuildKit layer'
require_source 'var containers: CorporateProxyLayer' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'container layer'
require_source 'proxies\.default contract cannot honor different values' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'truthful BuildKit/container conflict check'
require_source 'ownership conflict' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'ownership-safe Docker config restore'
require_source 'ProxyAutoConfigURLString' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'PAC discovery'
require_source 'requireSOA' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'SOA behavior probe'
require_source '"CNAME"' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'CNAME behavior probe'
require_source 'bridge subnet.*collides' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'VPN subnet collision refusal'
require_source 'temporaryCABundle' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'actual scoped CA probe bundle'
require_source 'reconcileAfterWake' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'wake reconciliation'
require_source 'lastFingerprint.*snapshot\.fingerprint' dory-core-swift/Sources/DorydKit/CorporateConnectivity.swift 'DHCP/interface/VPN fingerprint reconciliation'
require_source 'DORY_CORPORATE_CHANGED=0' dory-core-swift/Sources/DorydKit/DockerTier.swift 'effective digest no-op'
require_source '--live-restore' Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift 'live-restore dockerd reconfiguration'
require_source 'network corporate status' dory-core-swift/Sources/dorydctl/main.swift 'CLI status/plan/apply surface'
require_source 'CORPORATE CONNECTIVITY' Dory/Features/Settings/SettingsView.swift 'guided Settings surface'

if [ "$LIVE" -eq 0 ]; then
  echo "corporate connectivity gate: PASS (static contract)"
  exit 0
fi

command -v jq >/dev/null || { echo "corporate connectivity gate: jq is required for --live" >&2; exit 2; }

find_ctl() {
  local candidate
  for candidate in \
    "${DORYDCTL_BIN:-}" \
    "$ROOT/dory-core-swift/.build/debug/dorydctl" \
    "$HOME/.dory/bin/dorydctl" \
    "$(command -v dorydctl 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

CTL="$(find_ctl)" || { echo "corporate connectivity gate: dorydctl not found" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-corporate-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CURRENT="$TMP/status.json"
"$CTL" --timeout 45 network corporate status > "$CURRENT"

jq -e '
  .schema == "dev.dory.corporate-connectivity.status" and
  .version == 1 and .enabled == true and .valid == true and
  (.profile.schema == "dev.dory.corporate-connectivity") and
  (.profile.version == 1) and
  ([.plan[].destructive] | all(. == false)) and
  ([.probes[].succeeded] | all(. == true))
' "$CURRENT" >/dev/null || {
  jq '{valid, validationErrors, warnings, probes}' "$CURRENT" >&2
  echo "corporate connectivity gate: current profile or probe evidence is not release-ready" >&2
  exit 1
}

if [ -n "$EXPECT_DNS" ]; then
  jq -e --arg dns "$EXPECT_DNS" '[.probes[] | select(.dnsServer == $dns and .succeeded == true)] | length > 0' "$CURRENT" >/dev/null \
    || { echo "corporate connectivity gate: no successful explicit DNS probe used $EXPECT_DNS" >&2; exit 1; }
fi
if [ -n "$EXPECT_INTERFACE" ]; then
  jq -e --arg interface "$EXPECT_INTERFACE" '
    (.system.defaultInterface == $interface) or
    (.system.tunnelInterfaces | index($interface) != null) or
    ([.probes[].routeInterface] | index($interface) != null)
  ' "$CURRENT" >/dev/null \
    || { echo "corporate connectivity gate: expected interface $EXPECT_INTERFACE is absent from routes/tunnels" >&2; exit 1; }
fi
if [ "$REQUIRE_PROXY" -eq 1 ]; then
  jq -e '[.probes[] | select(.kind == "registry")] | length > 0 and all(.proxy != null and .proxy != "")' "$CURRENT" >/dev/null \
    || { echo "corporate connectivity gate: a registry probe did not name its selected proxy" >&2; exit 1; }
fi
if [ "$REQUIRE_CA" -eq 1 ]; then
  jq -e '[.probes[] | select(.kind == "registry" and (.caIDs | length > 0))] | length > 0' "$CURRENT" >/dev/null \
    || { echo "corporate connectivity gate: no registry probe used a declared host-probe CA" >&2; exit 1; }
fi

if [ "$RELEASE" -eq 1 ]; then
  [ -s "$BASELINE" ] || { echo "corporate connectivity gate: --release requires --baseline STATUS.json" >&2; exit 2; }
  [ -n "$EXPECT_INTERFACE" ] || { echo "corporate connectivity gate: --release requires --expect-interface" >&2; exit 2; }
  [ -n "$EXPECT_DNS" ] || { echo "corporate connectivity gate: --release requires --expect-dns" >&2; exit 2; }
  jq -e '.schema == "dev.dory.corporate-connectivity.status" and .version == 1' "$BASELINE" >/dev/null \
    || { echo "corporate connectivity gate: baseline has the wrong schema" >&2; exit 2; }
  before="$(jq -r '.system.fingerprint' "$BASELINE")"
  after="$(jq -r '.system.fingerprint' "$CURRENT")"
  [ -n "$before" ] && [ "$before" != "$after" ] \
    || { echo "corporate connectivity gate: system fingerprint did not change across the physical transition" >&2; exit 1; }
fi

if [ -n "$OUTPUT" ]; then
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$CURRENT" "$OUTPUT"
  chmod 0600 "$OUTPUT"
fi

echo "corporate connectivity gate: PASS (live=$LIVE release_qualifying=$RELEASE)"
