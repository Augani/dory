#!/bin/bash
# Physical sleep/wake gate for the class of failures where a container runtime leaves macOS Wi-Fi,
# DNS, routes, or proxies broken. Release qualification requires real sleep and an active Wi-Fi
# service; a no-sleep preflight is available but is explicitly marked non-qualifying.
set -euo pipefail

SOCKET="${DORY_NETWORK_INTEGRITY_SOCKET:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_NETWORK_INTEGRITY_DOCKER:-}"
APP="${DORY_NETWORK_INTEGRITY_APP:-}"
IMAGE="${DORY_NETWORK_INTEGRITY_IMAGE:-alpine:latest}"
WORKROOT="${DORY_NETWORK_INTEGRITY_WORKROOT:-$HOME/.dory-network-integrity}"
CYCLES="${DORY_NETWORK_INTEGRITY_CYCLES:-5}"
WAKE_TIMEOUT="${DORY_NETWORK_INTEGRITY_WAKE_TIMEOUT:-120}"
AUTO_WAKE_SECONDS="${DORY_NETWORK_INTEGRITY_AUTO_WAKE_SECONDS:-30}"
SOURCE_COMMIT="${DORY_NETWORK_INTEGRITY_SOURCE_COMMIT:-${GITHUB_SHA:-}}"
CUSTOM_DNS="${DORY_NETWORK_INTEGRITY_CUSTOM_DNS:-}"
TAILSCALE_EXIT_NODE="${DORY_NETWORK_INTEGRITY_TAILSCALE_EXIT_NODE:-}"
TAILSCALE_BIN="${DORY_NETWORK_INTEGRITY_TAILSCALE_BIN:-}"
SLEEP_TOKEN=""
ROUTE_CHURN_TOKEN=""
ROUTE_CHURN_ROUNDS=3
TAILSCALE_EXIT_NODE_ACTIVE=0
NO_SLEEP=0
REQUIRE_WIFI=1
REQUIRE_VPN=0
PROBE_HOST="${DORY_NETWORK_INTEGRITY_PROBE_HOST:-registry-1.docker.io}"
PROBE_URL="${DORY_NETWORK_INTEGRITY_PROBE_URL:-https://registry-1.docker.io/v2/}"
MACHINE_CTL=""
MACHINE_KERNEL=""
MACHINE_ROOTFS=""
MACHINE=""
MACHINE_OWNED=0
SESSION_PID=""
SESSION_WRITER_PID=""
SESSION_FIFO=""

usage() {
  cat <<EOF
Usage: scripts/host-network-integrity-gate.sh [options]

Options:
  --socket PATH        Dory Docker socket (default: ~/.dory/dory.sock)
  --docker PATH        Exact candidate Docker CLI (required for physical qualification)
  --app PATH           Exact notarized candidate Dory.app (required for physical qualification)
  --cycles N           Physical sleep/wake cycles (default: $CYCLES)
  --wake-timeout SEC   Network recovery deadline after wake (default: $WAKE_TIMEOUT)
  --auto-wake-seconds N
                       Schedule a relative hardware wake before each sleep (default: $AUTO_WAKE_SECONDS)
  --workroot PATH      Evidence root (default: ~/.dory-network-integrity)
  --probe-host HOST    DNS/TCP probe host (default: $PROBE_HOST)
  --probe-url URL      HTTPS probe URL; 2xx/3xx/401/403 count as reachable
  --custom-dns ADDRESS Require this resolver in the active macOS DNS contract and use it explicitly
                       from a container for the probe host
  --require-vpn        Fail unless an active VPN-like interface is present
  --tailscale-exit-node HOST
                       Real tailnet exit node used for enable/disable route recovery
  --confirm-route-churn VPN-ROUTE-CHURN
                       Required before changing exit-node state on the dedicated runner
  --confirm-physical-sleep SLEEP-AND-WAKE-THIS-MAC
                       Required before this script invokes pmset sleepnow
  --no-sleep           Preflight snapshots and activity only; never release-qualifying
  --allow-non-wifi     Permit a wired host for preflight; never release-qualifying
  -h, --help

Run this from a physical release account with no authentication sheet active. The script sleeps
the Mac, resumes when the user wakes it, proves host and container connectivity, and requires the
semantic default-route, DNS, proxy, and resolver configuration to match the pre-Dory baseline.
Physical qualification also holds a live interactive Dory machine shell across every sleep, then
proves a fresh exec, stop/start, and persistent-disk access after the client session disconnects.
EOF
}

die() { echo "network-integrity: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --app) need_value "$1" "$#"; APP="$2"; shift 2 ;;
    --cycles) need_value "$1" "$#"; CYCLES="$2"; shift 2 ;;
    --wake-timeout) need_value "$1" "$#"; WAKE_TIMEOUT="$2"; shift 2 ;;
    --auto-wake-seconds) need_value "$1" "$#"; AUTO_WAKE_SECONDS="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --probe-host) need_value "$1" "$#"; PROBE_HOST="$2"; shift 2 ;;
    --probe-url) need_value "$1" "$#"; PROBE_URL="$2"; shift 2 ;;
    --custom-dns) need_value "$1" "$#"; CUSTOM_DNS="$2"; shift 2 ;;
    --require-vpn) REQUIRE_VPN=1; shift ;;
    --tailscale-exit-node) need_value "$1" "$#"; TAILSCALE_EXIT_NODE="$2"; shift 2 ;;
    --confirm-route-churn) need_value "$1" "$#"; ROUTE_CHURN_TOKEN="$2"; shift 2 ;;
    --confirm-physical-sleep) need_value "$1" "$#"; SLEEP_TOKEN="$2"; shift 2 ;;
    --no-sleep) NO_SLEEP=1; shift ;;
    --allow-non-wifi) REQUIRE_WIFI=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
for pair in "cycles:$CYCLES" "wake-timeout:$WAKE_TIMEOUT" "auto-wake-seconds:$AUTO_WAKE_SECONDS"; do
  case "${pair#*:}" in ''|*[!0-9]*) die "${pair%%:*} must be a positive integer" ;; esac
  [ "${pair#*:}" -gt 0 ] || die "${pair%%:*} must be positive"
done
case "$NO_SLEEP" in 0|1) ;; *) die "invalid no-sleep mode" ;; esac
case "$REQUIRE_WIFI" in 0|1) ;; *) die "invalid Wi-Fi requirement" ;; esac
case "$REQUIRE_VPN" in 0|1) ;; *) die "invalid VPN requirement" ;; esac
if [ "$NO_SLEEP" = "0" ] && [ "$SLEEP_TOKEN" != "SLEEP-AND-WAKE-THIS-MAC" ]; then
  die "physical sleep requires --confirm-physical-sleep SLEEP-AND-WAKE-THIS-MAC"
fi
if [ -n "$TAILSCALE_EXIT_NODE" ] && [ "$ROUTE_CHURN_TOKEN" != "VPN-ROUTE-CHURN" ]; then
  die "exit-node testing requires --confirm-route-churn VPN-ROUTE-CHURN"
fi
case "$TAILSCALE_EXIT_NODE" in
  -*|*[!A-Za-z0-9_.:%-]*) die "--tailscale-exit-node contains unsafe characters" ;;
esac

if [ "${DORY_NETWORK_INTEGRITY_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

[ "$(uname -s)" = Darwin ] || die "physical host-network gate requires macOS"
for command in codesign curl dscacheutil ifconfig jq networksetup route scutil pmset shasum spctl sudo xcrun; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
[ -n "$DOCKER" ] || DOCKER="$(command -v docker 2>/dev/null || true)"
[ -x "$DOCKER" ] || die "exact Docker CLI is unavailable: $DOCKER"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready"
docker_e image inspect "$IMAGE" >/dev/null 2>&1 || die "required offline image is missing: $IMAGE"
if [ "$NO_SLEEP" = "0" ]; then
  [ "$(uname -m)" = arm64 ] || die "release sleep/wake qualification requires Apple silicon"
  [ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
    || die "Hypervisor.framework is unavailable"
  [ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
    || die "nested virtualization cannot qualify physical sleep/wake"
  case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
    VirtualMac*) die "VirtualMac cannot qualify physical sleep/wake" ;;
  esac
  [ -d "$APP" ] && [ -x "$APP/Contents/MacOS/Dory" ] \
    || die "exact candidate app is required for physical sleep/wake"
  MACHINE_CTL="$APP/Contents/Helpers/dorydctl"
  MACHINE_KERNEL="$APP/Contents/Resources/dory-hv-kernel-arm64"
  MACHINE_ROOTFS="$APP/Contents/Resources/dory-machine-rootfs-arm64.ext4"
  [ -x "$MACHINE_CTL" ] || die "exact candidate dorydctl is unavailable: $MACHINE_CTL"
  [ -s "$MACHINE_KERNEL" ] || die "exact candidate machine kernel is unavailable: $MACHINE_KERNEL"
  [ -s "$MACHINE_ROOTFS" ] || die "exact candidate machine rootfs is unavailable: $MACHINE_ROOTFS"
  [ "$(shasum -a 256 "$DOCKER" | awk '{print $1}')" = \
    "$(shasum -a 256 "$APP/Contents/Helpers/docker" | awk '{print $1}')" ] \
    || die "sleep/wake Docker CLI differs from the exact candidate app"
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || die "physical sleep/wake requires an exact source commit"
  codesign --verify --strict --deep "$APP" || die "candidate app signature is invalid"
  xcrun stapler validate "$APP" || die "candidate app has no notarization ticket"
  assessment="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" \
    || die "Gatekeeper rejected the candidate app: $assessment"
  grep -q '^source=Notarized Developer ID$' <<< "$assessment" \
    || die "sleep/wake candidate is not accepted as Notarized Developer ID"
  sudo -n -l /usr/bin/pmset >/dev/null 2>&1 \
    || die "passwordless /usr/bin/pmset access is required only on the dedicated sleep/wake runner"
  [ "$REQUIRE_VPN" = 1 ] \
    || die "physical release qualification requires --require-vpn"
  [ -n "$TAILSCALE_EXIT_NODE" ] \
    || die "physical release qualification requires --tailscale-exit-node"
  [ "$ROUTE_CHURN_TOKEN" = VPN-ROUTE-CHURN ] \
    || die "physical release qualification requires explicit route-churn confirmation"
  [ -n "$TAILSCALE_BIN" ] || TAILSCALE_BIN="$(command -v tailscale 2>/dev/null || true)"
  [ -x "$TAILSCALE_BIN" ] \
    || die "physical route-churn qualification requires the Tailscale CLI"
  [ -n "$CUSTOM_DNS" ] \
    || die "physical release qualification requires --custom-dns"
  case "$PROBE_URL" in
    https://"$PROBE_HOST"|https://"$PROBE_HOST"/*) ;;
    *) die "physical release probe URL must use the exact probe host over HTTPS" ;;
  esac
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-network-integrity-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
mkdir -p "$WORKDIR"
printf 'cycle\tphase\tstatus\tdetail\n' > "$RESULTS"

wifi_interface() {
  networksetup -listallhardwareports | awk '
    /^Hardware Port: (Wi-Fi|AirPort)$/ {wifi=1; next}
    wifi && /^Device: / {print $2; exit}
    /^$/ {wifi=0}
  '
}

capture_contract() {
  local dir="$1" wifi service
  mkdir -p "$dir"
  route -n get default > "$dir/default-route.raw" 2>&1
  awk '/gateway:|interface:|if scope:|flags:/{gsub(/^[[:space:]]+/, ""); print}' \
    "$dir/default-route.raw" > "$dir/default-route.contract"
  scutil --dns > "$dir/dns.raw" 2>&1
  scutil --nwi > "$dir/network-information.raw" 2>&1 || true
  ifconfig > "$dir/interfaces.raw" 2>&1
  awk '/nameserver\[[0-9]+\]|search domain\[[0-9]+\]|domain[[:space:]]*:|if_index[[:space:]]*:|flags[[:space:]]*:.*(Scoped|Supplemental)/ {
    gsub(/^[[:space:]]+/, ""); print
  }' "$dir/dns.raw" > "$dir/dns.contract"
  scutil --proxy > "$dir/proxy.contract" 2>&1
  networksetup -listallnetworkservices > "$dir/network-services.raw" 2>&1
  : > "$dir/service-dns.contract"
  tail -n +2 "$dir/network-services.raw" | sed 's/^\*//' | while IFS= read -r service; do
    [ -n "$service" ] || continue
    printf 'SERVICE %s\n' "$service"
    networksetup -getdnsservers "$service" 2>&1 || true
    networksetup -getsearchdomains "$service" 2>&1 || true
  done > "$dir/service-dns.contract"
  if [ -d /etc/resolver ]; then
    for file in /etc/resolver/*; do
      [ -f "$file" ] || continue
      printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$(basename "$file")"
    done | LC_ALL=C sort > "$dir/resolvers.contract"
  else
    : > "$dir/resolvers.contract"
  fi
  wifi="$(wifi_interface)"
  printf '%s\n' "$wifi" > "$dir/wifi-interface"
  if [ -n "$wifi" ]; then
    networksetup -getairportpower "$wifi" > "$dir/wifi-power" 2>&1 || true
    networksetup -getairportnetwork "$wifi" > "$dir/wifi-network" 2>&1 || true
  fi
  for file in default-route.contract dns.contract proxy.contract service-dns.contract resolvers.contract; do
    shasum -a 256 "$dir/$file"
  done > "$dir/contract.sha256"
}

vpn_detected() {
  grep -Eiq '(^utun[0-9]*:|^ppp[0-9]*:|^tun[0-9]*:|^tap[0-9]*:|wireguard|tailscale|zerotier|vpn)' \
    "$1/interfaces.raw" "$1/network-information.raw" "$1/default-route.raw" "$1/dns.raw" \
    2>/dev/null
}

custom_dns_active() {
  awk -v expected="$CUSTOM_DNS" \
    '$1 ~ /^nameserver\[[0-9]+\]$/ && $2 == ":" && $3 == expected { found=1 } END { exit !found }' \
    "$1/dns.raw"
}

compare_contract() {
  local baseline="$1" current="$2" failed=0 file
  for file in default-route.contract dns.contract proxy.contract service-dns.contract resolvers.contract; do
    if ! diff -u "$baseline/$file" "$current/$file" > "$current/$file.diff"; then
      echo "host network contract changed: $file" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

host_probe() {
  dscacheutil -q host -a name "$PROBE_HOST" | grep -Eq '^ip_address:'
  route -n get default | grep -q 'interface:'
  code="$(curl -sS -o /dev/null --connect-timeout 5 --max-time 20 -w '%{http_code}' "$PROBE_URL")"
  case "$code" in 2??|3??|401|403) ;; *) echo "unexpected host HTTPS status: $code" >&2; return 1 ;; esac
}

container_probe() {
  docker_e run --rm --label "dev.dory.network-integrity=$OWNER" "$IMAGE" sh -c \
    'getent hosts "$1" >/dev/null && nc -z -w 10 "$1" 443' sh "$PROBE_HOST"
  if [ -n "$CUSTOM_DNS" ]; then
    docker_e run --rm --dns "$CUSTOM_DNS" --label "dev.dory.network-integrity=$OWNER" \
      "$IMAGE" sh -c \
      'getent hosts "$1" >/dev/null && nc -z -w 10 "$1" 443' sh "$PROBE_HOST"
  fi
}

engine_activity() {
  local name="$OWNER-activity"
  docker_e rm -f "$name" >/dev/null 2>&1 || true
  docker_e run -d --name "$name" --label "dev.dory.network-integrity=$OWNER" "$IMAGE" sleep 120 >/dev/null
  docker_e exec "$name" sh -c 'printf activity-ok' | grep -q activity-ok
  docker_e rm -f "$name" >/dev/null
}

machine_ctl() { "$MACHINE_CTL" --timeout 180 "$@"; }

terminate_machine_session() {
  if [ -n "$SESSION_PID" ]; then
    kill "$SESSION_PID" >/dev/null 2>&1 || true
    wait "$SESSION_PID" >/dev/null 2>&1 || true
    SESSION_PID=""
  fi
  if [ -n "$SESSION_WRITER_PID" ]; then
    kill "$SESSION_WRITER_PID" >/dev/null 2>&1 || true
    wait "$SESSION_WRITER_PID" >/dev/null 2>&1 || true
    SESSION_WRITER_PID=""
  fi
  if [ -n "$SESSION_FIFO" ]; then
    rm -f "$SESSION_FIFO"
    SESSION_FIFO=""
  fi
}

start_machine_session() {
  local cycle="$1" token="DORY_SESSION_READY_${cycle}_${RUN_ID}" deadline
  SESSION_FIFO="$WORKDIR/cycle-$cycle-machine-shell.fifo"
  rm -f "$SESSION_FIFO"
  mkfifo "$SESSION_FIFO"
  (
    printf 'echo %s\n' "$token"
    sleep $((AUTO_WAKE_SECONDS + WAKE_TIMEOUT + 300))
  ) > "$SESSION_FIFO" &
  SESSION_WRITER_PID=$!
  machine_ctl machine shell "$MACHINE" < "$SESSION_FIFO" \
    > "$WORKDIR/cycle-$cycle-machine-shell.out" \
    2> "$WORKDIR/cycle-$cycle-machine-shell.err" &
  SESSION_PID=$!
  deadline=$(( $(date +%s) + 60 ))
  until grep -aFq "$token" "$WORKDIR/cycle-$cycle-machine-shell.out" 2>/dev/null; do
    if ! kill -0 "$SESSION_PID" >/dev/null 2>&1; then
      terminate_machine_session
      die "interactive machine shell disconnected before sleep cycle $cycle"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      terminate_machine_session
      die "interactive machine shell was not ready before sleep cycle $cycle"
    fi
    sleep 1
  done
}

verify_machine_reconnect() {
  local cycle="$1" reconnect_token="dory-machine-reconnect-$1" restart_token="dory-machine-restart-$1"
  terminate_machine_session
  machine_ctl machine status "$MACHINE" > "$WORKDIR/cycle-$cycle-machine-status-after-wake.json"
  jq -e '.state == "running"' "$WORKDIR/cycle-$cycle-machine-status-after-wake.json" >/dev/null \
    || die "machine is not running after sleep cycle $cycle"
  machine_ctl machine exec "$MACHINE" --json -- sh -ec \
    'test -f /root/dory-sleep-session-marker; printf "%s" "$1"' sh "$reconnect_token" \
    > "$WORKDIR/cycle-$cycle-machine-reconnect.json"
  jq -e --arg machine "$MACHINE" --arg token "$reconnect_token" \
    '.schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine and
     .exitCode == 0 and .timedOut == false and .stdout == $token and
     .stdoutTruncated == false and .stderrTruncated == false' \
    "$WORKDIR/cycle-$cycle-machine-reconnect.json" >/dev/null \
    || die "fresh machine exec failed after sleep cycle $cycle"
  machine_ctl machine stop "$MACHINE" > "$WORKDIR/cycle-$cycle-machine-stop.json"
  machine_ctl machine status "$MACHINE" > "$WORKDIR/cycle-$cycle-machine-status-stopped.json"
  jq -e '.state == "stopped"' "$WORKDIR/cycle-$cycle-machine-status-stopped.json" >/dev/null \
    || die "machine stop wedged after sleep cycle $cycle"
  machine_ctl machine start "$MACHINE" > "$WORKDIR/cycle-$cycle-machine-start.json"
  machine_ctl machine status "$MACHINE" > "$WORKDIR/cycle-$cycle-machine-status-restarted.json"
  jq -e '.state == "running"' "$WORKDIR/cycle-$cycle-machine-status-restarted.json" >/dev/null \
    || die "machine restart failed after sleep cycle $cycle"
  machine_ctl machine exec "$MACHINE" --json -- sh -ec \
    'test -f /root/dory-sleep-session-marker; printf "%s" "$1"' sh "$restart_token" \
    > "$WORKDIR/cycle-$cycle-machine-restart-persistence.json"
  jq -e --arg machine "$MACHINE" --arg token "$restart_token" \
    '.schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine and
     .exitCode == 0 and .timedOut == false and .stdout == $token and
     .stdoutTruncated == false and .stderrTruncated == false' \
    "$WORKDIR/cycle-$cycle-machine-restart-persistence.json" >/dev/null \
    || die "machine disk persistence failed after stop/start in sleep cycle $cycle"
}

cleanup() {
  if [ "$TAILSCALE_EXIT_NODE_ACTIVE" -eq 1 ] && [ -x "${TAILSCALE_BIN:-}" ]; then
    "$TAILSCALE_BIN" set --exit-node= \
      > "$WORKDIR/cleanup-tailscale-exit-node.out" \
      2> "$WORKDIR/cleanup-tailscale-exit-node.err" || true
    TAILSCALE_EXIT_NODE_ACTIVE=0
  fi
  terminate_machine_session
  if [ "$MACHINE_OWNED" -eq 1 ]; then
    machine_ctl machine stop "$MACHINE" > "$WORKDIR/cleanup-machine-stop.json" \
      2> "$WORKDIR/cleanup-machine-stop.err" || true
    machine_ctl machine delete "$MACHINE" > "$WORKDIR/cleanup-machine-delete.json" \
      2> "$WORKDIR/cleanup-machine-delete.err" || true
    MACHINE_OWNED=0
  fi
  docker_e ps -aq --filter "label=dev.dory.network-integrity=$OWNER" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

if [ "$NO_SLEEP" = "0" ]; then
  MACHINE="dory-sleep-session-$RUN_ID"
  machine_ctl machine list > "$WORKDIR/machine-list-before.json"
  jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/machine-list-before.json" >/dev/null \
    || die "owned sleep-session machine name already exists: $MACHINE"
  machine_ctl machine create "$MACHINE" --kernel "$MACHINE_KERNEL" --rootfs "$MACHINE_ROOTFS" \
    --memory-mb 2048 --cpus 2 > "$WORKDIR/machine-create.json"
  MACHINE_OWNED=1
  machine_ctl machine start "$MACHINE" > "$WORKDIR/machine-start.json"
  machine_ctl machine exec "$MACHINE" --json -- sh -ec \
    'printf marker > /root/dory-sleep-session-marker' > "$WORKDIR/machine-marker.json"
  jq -e --arg machine "$MACHINE" \
    '.schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine and
     .exitCode == 0 and .timedOut == false and .stdoutTruncated == false and .stderrTruncated == false' \
    "$WORKDIR/machine-marker.json" >/dev/null || die "could not initialize machine persistence marker"
fi

run_route_churn() {
  local round deadline enabled restored
  printf 'round\tphase\tstatus\tdetail\n' > "$WORKDIR/route-churn-results.tsv"
  round=1
  while [ "$round" -le "$ROUTE_CHURN_ROUNDS" ]; do
    enabled="$WORKDIR/route-churn-$round-enabled"
    restored="$WORKDIR/route-churn-$round-restored"
    mkdir -p "$enabled" "$restored"
    "$TAILSCALE_BIN" set --exit-node="$TAILSCALE_EXIT_NODE" \
      --exit-node-allow-lan-access=true \
      > "$enabled/tailscale-set.out" 2> "$enabled/tailscale-set.err"
    TAILSCALE_EXIT_NODE_ACTIVE=1
    "$TAILSCALE_BIN" status --json > "$enabled/tailscale-status.json"
    deadline=$(( $(date +%s) + WAKE_TIMEOUT ))
    until host_probe >/dev/null 2>&1 && container_probe >/dev/null 2>&1 \
      && docker_e version >/dev/null 2>&1; do
      [ "$(date +%s)" -lt "$deadline" ] \
        || die "host/container/Docker did not survive exit-node activation in round $round"
      sleep 2
    done
    capture_contract "$enabled"
    printf '%s\texit-node-active\tPASS\thost/container/API remained reachable\n' "$round" \
      >> "$WORKDIR/route-churn-results.tsv"

    "$TAILSCALE_BIN" set --exit-node= \
      > "$restored/tailscale-set.out" 2> "$restored/tailscale-set.err"
    TAILSCALE_EXIT_NODE_ACTIVE=0
    deadline=$(( $(date +%s) + WAKE_TIMEOUT ))
    until capture_contract "$restored" && compare_contract "$BASELINE" "$restored" \
      && host_probe >/dev/null 2>&1 && container_probe >/dev/null 2>&1 \
      && docker_e version >/dev/null 2>&1; do
      [ "$(date +%s)" -lt "$deadline" ] \
        || die "host network contract did not self-heal after exit-node round $round"
      sleep 2
    done
    "$TAILSCALE_BIN" status --json > "$restored/tailscale-status.json"
    printf '%s\tbaseline-restored\tPASS\troute/DNS/proxy contract and Docker recovered\n' \
      "$round" >> "$WORKDIR/route-churn-results.tsv"
    round=$((round + 1))
  done
}

if [ "$NO_SLEEP" = "0" ]; then
  "$TAILSCALE_BIN" set --exit-node= \
    > "$WORKDIR/tailscale-baseline-disable.out" \
    2> "$WORKDIR/tailscale-baseline-disable.err"
  TAILSCALE_EXIT_NODE_ACTIVE=0
  "$TAILSCALE_BIN" status --json > "$WORKDIR/tailscale-baseline-status.json"
  baseline_deadline=$(( $(date +%s) + WAKE_TIMEOUT ))
  until host_probe >/dev/null 2>&1 && container_probe >/dev/null 2>&1 \
    && docker_e version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$baseline_deadline" ] \
      || die "host/container/Docker did not recover after clearing the baseline exit node"
    sleep 2
  done
fi

BASELINE="$WORKDIR/baseline"
capture_contract "$BASELINE"
wifi="$(cat "$BASELINE/wifi-interface")"
if [ "$REQUIRE_WIFI" = "1" ]; then
  [ -n "$wifi" ] || die "no Wi-Fi hardware service found"
  grep -Eqi ': On$' "$BASELINE/wifi-power" || die "Wi-Fi is not powered on"
  ! grep -Eqi 'not associated' "$BASELINE/wifi-network" || die "Wi-Fi is not associated with a network"
fi
if [ "$REQUIRE_VPN" = 1 ]; then
  vpn_detected "$BASELINE" || die "no active VPN-like interface is present"
  custom_dns_active "$BASELINE" \
    || die "required custom DNS server is absent from the active macOS resolver contract"
fi
host_probe
container_probe
if [ "$NO_SLEEP" = "0" ]; then
  run_route_churn
fi

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  engine_activity
  before="$WORKDIR/cycle-$cycle-before"
  after="$WORKDIR/cycle-$cycle-after"
  capture_contract "$before"
  compare_contract "$BASELINE" "$before"
  if [ "$NO_SLEEP" = "0" ]; then
    start_machine_session "$cycle"
    printf '%s\tmachine-session-pre-sleep\tPASS\tinteractive shell ready token observed\n' \
      "$cycle" >> "$RESULTS"
    printf '%s\tpre-sleep\tPASS\tcontract and probes healthy\n' "$cycle" >> "$RESULTS"
    before_sleep_epoch="$(date +%s)"
    sudo -n pmset relative wake "$AUTO_WAKE_SECONDS"
    pmset -g sched > "$WORKDIR/cycle-$cycle-scheduled-wake.txt"
    grep -Eqi 'wake' "$WORKDIR/cycle-$cycle-scheduled-wake.txt" \
      || die "relative hardware wake was not scheduled for cycle $cycle"
    sudo -n pmset sleepnow
    after_wake_epoch="$(date +%s)"
    slept_seconds=$((after_wake_epoch - before_sleep_epoch))
    minimum_sleep=$((AUTO_WAKE_SECONDS / 2))
    [ "$minimum_sleep" -ge 5 ] || minimum_sleep=5
    [ "$slept_seconds" -ge "$minimum_sleep" ] \
      || die "physical sleep cycle $cycle resumed after only ${slept_seconds}s"
    pmset -g log | tail -300 > "$WORKDIR/cycle-$cycle-pmset-log.txt"
    printf '%s\tsleep-resume\tPASS\telapsed_seconds=%s scheduled_wake_seconds=%s\n' \
      "$cycle" "$slept_seconds" "$AUTO_WAKE_SECONDS" >> "$RESULTS"
    verify_machine_reconnect "$cycle"
    printf '%s\tmachine-session-reconnect\tPASS\tfresh exec, stop/start, and disk marker verified\n' \
      "$cycle" >> "$RESULTS"
  fi
  deadline=$(( $(date +%s) + WAKE_TIMEOUT ))
  until host_probe >/dev/null 2>&1 && docker_e version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '%s\tpost-wake\tFAIL\tnetwork/API did not recover before deadline\n' "$cycle" >> "$RESULTS"
      die "network/API did not recover within ${WAKE_TIMEOUT}s after cycle $cycle"
    }
    sleep 2
  done
  host_probe
  container_probe
  capture_contract "$after"
  compare_contract "$BASELINE" "$after"
  printf '%s\t%s\tPASS\thost/container probes and network contract preserved\n' \
    "$cycle" "$([ "$NO_SLEEP" = "1" ] && echo preflight || echo post-wake)" >> "$RESULTS"
  cycle=$((cycle + 1))
done

if [ "$NO_SLEEP" = "0" ]; then
  terminate_machine_session
  machine_ctl machine stop "$MACHINE" > "$WORKDIR/machine-final-stop.json"
  machine_ctl machine delete "$MACHINE" > "$WORKDIR/machine-final-delete.json"
  MACHINE_OWNED=0
  machine_ctl machine list > "$WORKDIR/machine-list-after.json"
  jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/machine-list-after.json" >/dev/null \
    || die "owned sleep-session machine survived deletion"
fi
cleanup
{
  echo "run_id=$RUN_ID"
  echo "cycles=$CYCLES"
  echo "auto_wake_seconds=$AUTO_WAKE_SECONDS"
  echo "physical_sleep=$([ "$NO_SLEEP" = "0" ] && echo true || echo false)"
  echo "wifi_required=$([ "$REQUIRE_WIFI" = "1" ] && echo true || echo false)"
  echo "vpn_required=$([ "$REQUIRE_VPN" = "1" ] && echo true || echo false)"
  echo "custom_dns_required=$([ -n "$CUSTOM_DNS" ] && echo true || echo false)"
  echo "route_churn=$([ "$NO_SLEEP" = "0" ] && echo PASS || echo SKIP)"
  echo "route_churn_rounds=$([ "$NO_SLEEP" = "0" ] && echo "$ROUTE_CHURN_ROUNDS" || echo 0)"
  echo "release_qualifying=$([ "$NO_SLEEP" = "0" ] && [ "$REQUIRE_WIFI" = "1" ] && [ "$REQUIRE_VPN" = "1" ] && [ -n "$CUSTOM_DNS" ] && [ -n "$TAILSCALE_EXIT_NODE" ] && echo true || echo false)"
  if [ "$NO_SLEEP" = "0" ]; then
    echo "source_commit=$SOURCE_COMMIT"
    echo "github_run_id=${GITHUB_RUN_ID:-manual}"
    echo "github_run_attempt=${GITHUB_RUN_ATTEMPT:-1}"
    echo "app_executable_sha256=$(shasum -a 256 "$APP/Contents/MacOS/Dory" | awk '{print $1}')"
    echo "docker_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
    echo "doryd_sha256=$(shasum -a 256 "$APP/Contents/Helpers/doryd" | awk '{print $1}')"
    echo "dory_hv_sha256=$(shasum -a 256 "$APP/Contents/Helpers/dory-hv" | awk '{print $1}')"
    echo "dorydctl_sha256=$(shasum -a 256 "$MACHINE_CTL" | awk '{print $1}')"
    echo "machine_kernel_sha256=$(shasum -a 256 "$MACHINE_KERNEL" | awk '{print $1}')"
    echo "machine_rootfs_sha256=$(shasum -a 256 "$MACHINE_ROOTFS" | awk '{print $1}')"
    echo "machine_id=$MACHINE"
    echo "machine_session_reconnect=PASS"
    echo "custom_dns_sha256=$(printf '%s' "$CUSTOM_DNS" | shasum -a 256 | awk '{print $1}')"
    echo "probe_host_sha256=$(printf '%s' "$PROBE_HOST" | shasum -a 256 | awk '{print $1}')"
    echo "probe_url_sha256=$(printf '%s' "$PROBE_URL" | shasum -a 256 | awk '{print $1}')"
    echo "tailscale_exit_node_sha256=$(printf '%s' "$TAILSCALE_EXIT_NODE" | shasum -a 256 | awk '{print $1}')"
  fi
} > "$WORKDIR/manifest.txt"
echo "host network integrity gate PASS; evidence: $WORKDIR"
