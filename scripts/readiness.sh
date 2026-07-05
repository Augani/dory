#!/bin/bash
# End-to-end replacement readiness checks for Dory, OrbStack, and Docker Desktop.
#
# The suite drives the public Docker CLI against each engine socket. It labels and names every
# resource it creates, then removes only those resources during cleanup.
#
# Examples:
#   scripts/readiness.sh --engines dory
#   scripts/readiness.sh --engines orbstack,dory --memory-count 5
#   RUN_DOMAINS=1 RUN_AMD64=1 scripts/readiness.sh --engines dory,orbstack
#
# Environment knobs:
#   DORY_SOCK, ORBSTACK_SOCK, DOCKER_DESKTOP_SOCK
#   READINESS_WORKDIR, READINESS_SETTLE, READINESS_ALPINE_IMAGE, READINESS_NGINX_IMAGE
#   RUN_MEMORY=0|1, RUN_AMD64=0|1, RUN_ONLINE=0|1, RUN_DOMAINS=0|1, RUN_DIRECT_IP=0|1, RUN_FILE_WATCH=0|1, RUN_K8S=0|1, RUN_MACHINES=0|1, RUN_MACHINE_RECIPE=0|1, RUN_USB=0|1, RUN_VPN=0|1
#   DORY_DIRECT_IP_INTERFACE_FILE points at the helper-written utun interface file
#   READINESS_FILE_WATCH_IMAGE for --file-watch (default: alpine image)
#   READINESS_MACHINE_RECIPE, READINESS_MACHINE_RECIPE_COMMAND for --machine-recipe
#   RUN_DEBUG_SHELL=0|1, DORY_DEBUG_AGENT_SOCK, DORY_DEBUG_CONTAINER_ID
#   RUN_CLOCK_SYNC=0|1, DORY_CLOCK_SYNC_AGENT_SOCK, DORY_CLOCK_SYNC_PID, DORY_CLOCK_SYNC_TOLERANCE_MS
#   RUN_GUEST_AGENT=0|1, DORY_HV_BIN, DORY_GUEST_KERNEL, DORY_GUEST_INITFS
#   DORY_USB_TEST_BUSID, DORY_USB_AGENT_SOCK, DORY_USBIP_SOCKET_FD for --usb hardware smoke
#   DORY_REQUIRE_VPN=1 makes --vpn fail when no active VPN-like interface or route is detected
#   STOP_ORBSTACK=1 to quit OrbStack before running Dory-only checks
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINES="${ENGINES:-dory}"
ALPINE_IMAGE="${READINESS_ALPINE_IMAGE:-alpine:latest}"
NGINX_IMAGE="${READINESS_NGINX_IMAGE:-nginx:alpine}"
MEMORY_COUNT="${READINESS_MEMORY_COUNT:-3}"
SETTLE="${READINESS_SETTLE:-8}"
RUN_MEMORY="${RUN_MEMORY:-1}"
RUN_AMD64="${RUN_AMD64:-1}"
RUN_ONLINE="${RUN_ONLINE:-0}"
RUN_DOMAINS="${RUN_DOMAINS:-0}"
RUN_DIRECT_IP="${RUN_DIRECT_IP:-0}"
RUN_FILE_WATCH="${RUN_FILE_WATCH:-0}"
RUN_K8S="${RUN_K8S:-0}"
RUN_MACHINES="${RUN_MACHINES:-0}"
RUN_MACHINE_RECIPE="${RUN_MACHINE_RECIPE:-0}"
RUN_BRIDGE="${RUN_BRIDGE:-0}"
RUN_GUEST_AGENT="${RUN_GUEST_AGENT:-0}"
RUN_DAX="${RUN_DAX:-0}"
RUN_ROSETTA="${RUN_ROSETTA:-0}"
RUN_USB="${RUN_USB:-0}"
RUN_VPN="${RUN_VPN:-0}"
RUN_DEBUG_SHELL="${RUN_DEBUG_SHELL:-0}"
RUN_CLOCK_SYNC="${RUN_CLOCK_SYNC:-0}"
CLOCK_SYNC_TOLERANCE_MS="${DORY_CLOCK_SYNC_TOLERANCE_MS:-100}"
STOP_ORBSTACK="${STOP_ORBSTACK:-0}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_SLUG="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_.-')"
WORKROOT="${READINESS_WORKDIR:-$HOME/.dory-readiness}"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
MEMORY_RESULTS="$WORKDIR/memory.tsv"
SUMMARY_JSON="$WORKDIR/summary.json"
LABEL_KEY="dev.dory.readiness"
CASE_ID=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT_ENGINE=""
ENGINE_SOCK=""
ENGINE_ID=""
PREFIX=""

usage() {
  cat <<EOF
Usage: scripts/readiness.sh [options]

Options:
  --engines LIST       Comma-separated: dory,orbstack,docker-desktop,current
  --memory-count N     Containers to run for memory measurements (default: $MEMORY_COUNT)
  --settle SECONDS     Wait time before/after memory workload (default: $SETTLE)
  --skip-memory        Skip memory measurements
  --skip-amd64         Skip linux/amd64 emulation check
  --online             Run online registry search check
  --domains            Run *.dory.local / *.orb.local checks when integration is active
  --direct-ip          Run Dory direct container-IP ping + browser check (requires system integration route)
  --file-watch         Run host edit to inotify propagation check for bind/shared mounts
  --k8s                Run Kubernetes context checks
  --machines           Run Linux machine CLI checks
  --machine-recipe     Create a Linux machine from a recipe and assert its provisioned command
  --bridge             Run guest→host bridge (dory-open) check
  --guest-agent        Run dory-hv guest-agent vsock smoke (requires DORY_GUEST_KERNEL and DORY_GUEST_INITFS)
  --dax                Run dory-hv virtio-fs DAX coherence probe (requires a signed dory-hv, DORY_HV_BIN)
  --rosetta            Run Rosetta x86-64 machine execution smoke (requires a signed dory-vm + Rosetta; DORY_VM_HELPER)
  --usb                Run USB/IP hardware smoke when DORY_USB_TEST_BUSID and agent socket settings are set
  --vpn                Record route/DNS state and run userspace networking checks during VPN coexistence testing
  --debug-shell        Run debug shell smoke when DORY_DEBUG_AGENT_SOCK and DORY_DEBUG_CONTAINER_ID are set
  --clock-sync         Run host-wake clock sync smoke when agent socket and helper PID are available
  --stop-orbstack      Quit OrbStack before Dory-only runs
  -h, --help           Show this help

Clock sync env:
  DORY_CLOCK_SYNC_AGENT_SOCK or DORY_AGENT_SOCK
  DORY_CLOCK_SYNC_PID, DORY_CLOCK_SYNC_TOLERANCE_MS
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="$2"; shift 2 ;;
    --memory-count) MEMORY_COUNT="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --skip-memory) RUN_MEMORY=0; shift ;;
    --skip-amd64) RUN_AMD64=0; shift ;;
    --online) RUN_ONLINE=1; shift ;;
    --domains) RUN_DOMAINS=1; shift ;;
    --direct-ip) RUN_DIRECT_IP=1; shift ;;
    --file-watch) RUN_FILE_WATCH=1; shift ;;
    --k8s) RUN_K8S=1; shift ;;
    --machines) RUN_MACHINES=1; shift ;;
    --machine-recipe) RUN_MACHINE_RECIPE=1; shift ;;
    --bridge) RUN_BRIDGE=1; shift ;;
    --guest-agent) RUN_GUEST_AGENT=1; shift ;;
    --dax) RUN_DAX=1; shift ;;
    --rosetta) RUN_ROSETTA=1; shift ;;
    --usb) RUN_USB=1; shift ;;
    --vpn) RUN_VPN=1; shift ;;
    --debug-shell) RUN_DEBUG_SHELL=1; shift ;;
    --clock-sync) RUN_CLOCK_SYNC=1; shift ;;
    --stop-orbstack) STOP_ORBSTACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$WORKDIR"
printf 'status\tengine\ttest\tdetail\n' > "$RESULTS"
printf 'engine\tcontainers\timage\tsystem_delta_bytes\tsystem_delta_mb\tprocess_delta_bytes\tprocess_delta_mb\n' > "$MEMORY_RESULTS"

note() {
  printf '==> %s\n' "$*"
}

sanitize() {
  printf '%s' "$*" | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c 1-500
}

record() {
  local status="$1" engine="$2" test_name="$3" detail="$4"
  printf '%s\t%s\t%s\t%s\n' "$status" "$engine" "$test_name" "$(sanitize "$detail")" >> "$RESULTS"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)); printf '  [PASS] %s\n' "$test_name" ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  [FAIL] %s -- %s\n' "$test_name" "$(sanitize "$detail")" ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  [SKIP] %s -- %s\n' "$test_name" "$(sanitize "$detail")" ;;
  esac
}

run_case() {
  local engine="$1" test_name="$2"
  shift 2
  CASE_ID=$((CASE_ID + 1))
  local out="$WORKDIR/${ENGINE_ID:-$(engine_id "$engine")}-${CASE_ID}.log"
  if ( set -e; "$@" ) > "$out" 2>&1; then
    record PASS "$engine" "$test_name" "ok"
  else
    local rc=$?
    record FAIL "$engine" "$test_name" "exit=$rc $(tail -20 "$out" 2>/dev/null)"
  fi
}

skip_case() {
  record SKIP "$1" "$2" "$3"
}

mb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.0f", b / 1048576 }'
}

used_mem() {
  vm_stat | awk '
    /page size of/ { for (i=1;i<=NF;i++) if ($i+0>0) ps=$i }
    /Pages active/ { gsub(/\./,"",$3); a=$3 }
    /Pages wired down/ { gsub(/\./,"",$4); w=$4 }
    /Pages occupied by compressor/ { gsub(/\./,"",$5); c=$5 }
    END { printf "%.0f", (a+w+c)*ps }'
}

process_rss_bytes() {
  local engine="$1" pattern
  case "$engine" in
    dory) pattern="${DORY_PROCESS_PATTERN:-Dory|dory-vm|dory-vmboot|containermanagerd}" ;;
    orbstack) pattern="${ORBSTACK_PROCESS_PATTERN:-OrbStack}" ;;
    docker-desktop|desktop) pattern="${DOCKER_DESKTOP_PROCESS_PATTERN:-Docker|com.docker}" ;;
    *) pattern="${GENERIC_ENGINE_PROCESS_PATTERN:-$engine}" ;;
  esac
  ps -axo rss,args | awk -v pat="$pattern" '$0 ~ pat && $0 !~ /awk/ { sum += $1 } END { printf "%.0f", sum * 1024 }'
}

engine_id() {
  local engine="$1" base
  base="$(basename "$engine" 2>/dev/null | sed 's/\.sock$//')"
  [ -n "$base" ] || base="$engine"
  printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

engine_socket() {
  local engine="$1"
  case "$engine" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    docker-desktop|desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
    current)
      docker context inspect "$(docker context show)" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null | sed 's#^unix://##'
      ;;
    *)
      echo "$engine"
      ;;
  esac
}

docker_e() {
  docker -H "unix://$ENGINE_SOCK" "$@"
}

compose_e() {
  DOCKER_HOST="unix://$ENGINE_SOCK" docker compose "$@"
}

cleanup_engine() {
  [ -n "${ENGINE_SOCK:-}" ] || return 0
  docker_e ps -aq --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f "$id" >/dev/null 2>&1
  done
  docker_e network ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e network rm "$id" >/dev/null 2>&1
  done
  docker_e volume ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e volume rm -f "$id" >/dev/null 2>&1
  done
  docker_e image ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rmi -f "$id" >/dev/null 2>&1
  done
}

stop_orbstack() {
  osascript -e 'tell application "OrbStack" to quit' >/dev/null 2>&1 || true
  sleep 3
  pgrep -f '/Applications/OrbStack.app' >/dev/null 2>&1 && pkill -f '/Applications/OrbStack.app' >/dev/null 2>&1 || true
}

require_socket() {
  [ -S "$ENGINE_SOCK" ]
}

test_engine_info() {
  require_socket
  docker_e version >/dev/null
  docker_e info >/dev/null
  docker_e system df >/dev/null
}

test_pull_images() {
  docker_e pull "$ALPINE_IMAGE" >/dev/null
  docker_e pull "$NGINX_IMAGE" >/dev/null
}

test_lifecycle_logs_exec_stats() {
  local name="$PREFIX-basic"
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sh -c 'echo ready; sleep 300' >/dev/null
  sleep 1
  docker_e logs "$name" | grep -q 'ready'
  docker_e exec "$name" sh -c 'echo exec-ok' | grep -q 'exec-ok'
  docker_e stats --no-stream --format '{{.Name}} {{.MemUsage}}' "$name" | grep -q "$name"
  docker_e restart "$name" >/dev/null
  docker_e stop "$name" >/dev/null
  docker_e start "$name" >/dev/null
  docker_e inspect "$name" >/dev/null
  docker_e rm -f "$name" >/dev/null
}

test_cp_archive() {
  local name="$PREFIX-cp"
  local host_file="$WORKDIR/${ENGINE_ID}-host.txt"
  local copied="$WORKDIR/${ENGINE_ID}-copied.txt"
  printf 'host-ok\n' > "$host_file"
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sh -c 'echo container-ok > /tmp/container.txt; sleep 300' >/dev/null
  docker_e cp "$host_file" "$name:/tmp/host.txt"
  docker_e exec "$name" cat /tmp/host.txt | grep -q 'host-ok'
  docker_e cp "$name:/tmp/container.txt" "$copied"
  grep -q 'container-ok' "$copied"
  docker_e export "$name" >/dev/null
  docker_e rm -f "$name" >/dev/null
}

test_bind_mount() {
  local dir="$WORKDIR/${ENGINE_ID}-bind"
  mkdir -p "$dir"
  printf 'from-host\n' > "$dir/input.txt"
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" -v "$dir:/mnt" "$ALPINE_IMAGE" sh -c 'grep -q from-host /mnt/input.txt && echo from-container > /mnt/output.txt'
  grep -q 'from-container' "$dir/output.txt"
}

test_file_watch() {
  local dir="$WORKDIR/${ENGINE_ID}-file-watch"
  local name="$PREFIX-file-watch"
  local image="${READINESS_FILE_WATCH_IMAGE:-$ALPINE_IMAGE}"
  mkdir -p "$dir"
  printf 'before\n' > "$dir/input.txt"
  docker_e rm -f "$name" >/dev/null 2>&1 || true
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" -v "$dir:/work" "$image" sh -lc '
    apk add --no-cache inotify-tools >/dev/null
    touch /work/ready
    timeout 20 inotifywait -q -e modify,attrib,create,delete /work/input.txt > /work/event.txt
  ' >/dev/null
  trap 'docker_e rm -f "$name" >/dev/null 2>&1 || true' RETURN
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -f "$dir/ready" ] && break
    docker_e inspect "$name" --format '{{.State.Running}}' 2>/dev/null | grep -q true || { docker_e logs "$name" 2>&1; return 1; }
    sleep 1
  done
  [ -f "$dir/ready" ] || { docker_e logs "$name" 2>&1; echo "inotify watcher did not become ready"; return 1; }
  sleep 1
  printf 'after\n' >> "$dir/input.txt"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$dir/event.txt" ] && break
    sleep 1
  done
  [ -s "$dir/event.txt" ] || { docker_e logs "$name" 2>&1; echo "host edit did not produce an inotify event"; return 1; }
  grep -Eq 'MODIFY|ATTRIB|CREATE|DELETE' "$dir/event.txt"
  docker_e rm -f "$name" >/dev/null 2>&1 || true
  trap - RETURN
}

test_volume_roundtrip() {
  local vol="$PREFIX-vol"
  docker_e volume create --label "$LABEL_KEY=$RUN_ID" "$vol" >/dev/null
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" -v "$vol:/data" "$ALPINE_IMAGE" sh -c 'echo volume-ok > /data/msg'
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" -v "$vol:/data" "$ALPINE_IMAGE" cat /data/msg | grep -q 'volume-ok'
  docker_e volume inspect "$vol" >/dev/null
  docker_e volume rm "$vol" >/dev/null
}

test_network_dns() {
  local net="$PREFIX-net"
  local web="$PREFIX-web"
  docker_e network create --label "$LABEL_KEY=$RUN_ID" "$net" >/dev/null
  docker_e run -d --name "$web" --label "$LABEL_KEY=$RUN_ID" --network "$net" --network-alias web "$NGINX_IMAGE" >/dev/null
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" --network "$net" "$ALPINE_IMAGE" wget -qO- http://web | grep -qi 'welcome'
  docker_e rm -f "$web" >/dev/null
  docker_e network rm "$net" >/dev/null
}

test_published_port() {
  local name="$PREFIX-port"
  local port
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" -p 127.0.0.1::80 "$NGINX_IMAGE" >/dev/null
  port="$(docker_e port "$name" 80/tcp | sed 's/.*://')"
  [ -n "$port" ]
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    curl -fsS "http://127.0.0.1:$port" | grep -qi 'welcome' && { docker_e rm -f "$name" >/dev/null; return 0; }
    sleep 1
  done
  docker_e rm -f "$name" >/dev/null
  return 1
}

test_buildkit_build() {
  local dir="$WORKDIR/${ENGINE_ID}-build"
  local tag="dory-readiness-${ENGINE_ID}-${RUN_SLUG}:build"
  mkdir -p "$dir"
  cat > "$dir/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
LABEL $LABEL_KEY=$RUN_ID
RUN echo built-ok > /built.txt
CMD ["cat", "/built.txt"]
EOF
  DOCKER_BUILDKIT=1 docker_e build -t "$tag" "$dir" >/dev/null
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" "$tag" | grep -q 'built-ok'
  docker_e rmi -f "$tag" >/dev/null
}

test_compose() {
  local dir="$WORKDIR/${ENGINE_ID}-compose"
  local project="doryreadiness${ENGINE_ID}${RUN_SLUG}" port rc
  project="$(printf '%s' "$project" | tr -cd '[:alnum:]' | cut -c 1-40)"
  mkdir -p "$dir"
  cat > "$dir/compose.yaml" <<EOF
services:
  web:
    image: $NGINX_IMAGE
    labels:
      $LABEL_KEY: "$RUN_ID"
    ports:
      - "127.0.0.1::80"
  worker:
    image: $ALPINE_IMAGE
    labels:
      $LABEL_KEY: "$RUN_ID"
    command: ["sh", "-c", "echo compose-ok; sleep 300"]
    depends_on:
      - web
volumes:
  cache:
    labels:
      $LABEL_KEY: "$RUN_ID"
EOF
  compose_e -f "$dir/compose.yaml" -p "$project" up -d >/dev/null
  compose_e -f "$dir/compose.yaml" -p "$project" ps >/dev/null
  compose_e -f "$dir/compose.yaml" -p "$project" logs worker | grep -q 'compose-ok'
  port="$(compose_e -f "$dir/compose.yaml" -p "$project" port web 80 | sed 's/.*://')"
  [ -n "$port" ]
  rc=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://127.0.0.1:$port" | grep -qi 'welcome'; then
      rc=0
      break
    fi
    sleep 1
  done
  compose_e -f "$dir/compose.yaml" -p "$project" down -v --remove-orphans >/dev/null
  return "$rc"
}

test_image_archive_commit() {
  local name="$PREFIX-commit"
  local tag="dory-readiness-${ENGINE_ID}-${RUN_SLUG}:commit"
  local tar="$WORKDIR/${ENGINE_ID}-image.tar"
  docker_e create --name "$name" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" sh -c 'echo commit-ok > /result.txt' >/dev/null
  docker_e start -a "$name" >/dev/null
  docker_e commit --change "LABEL $LABEL_KEY=$RUN_ID" "$name" "$tag" >/dev/null
  docker_e image inspect "$tag" >/dev/null
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" "$tag" cat /result.txt | grep -q 'commit-ok'
  docker_e save -o "$tar" "$tag"
  docker_e rmi -f "$tag" >/dev/null
  docker_e load -i "$tar" >/dev/null
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" "$tag" cat /result.txt | grep -q 'commit-ok'
  docker_e rm -f "$name" >/dev/null
  docker_e rmi -f "$tag" >/dev/null
}

test_resource_limits_update() {
  local name="$PREFIX-limits" limits
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" --memory 128m --cpus 0.5 "$ALPINE_IMAGE" sleep 300 >/dev/null
  limits="$(docker_e inspect "$name" --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}')"
  printf '%s\n' "$limits" | grep -q '134217728'
  printf '%s\n' "$limits" | grep -q '500000000'
  docker_e update --memory 256m "$name" >/dev/null
  docker_e inspect "$name" --format '{{.HostConfig.Memory}}' | grep -q '268435456'
  docker_e rm -f "$name" >/dev/null
}

test_amd64() {
  local name="$PREFIX-binfmt"
  docker_e run --rm --privileged --name "$name" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" \
    sh -c 'test -e /proc/sys/fs/binfmt_misc/register || { echo "binfmt_misc not mounted" >&2; exit 1; }
           test -e /proc/sys/fs/binfmt_misc/qemu-x86_64 || { echo "qemu-x86_64 handler not registered" >&2; exit 1; }
           grep -qx enabled /proc/sys/fs/binfmt_misc/qemu-x86_64 || { echo "qemu-x86_64 handler not enabled" >&2; exit 1; }'
  docker_e run --rm --platform linux/amd64 --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" uname -m | grep -Eq 'x86_64|amd64'
}

test_online_search() {
  docker_e search --limit 1 alpine | grep -qi 'alpine'
}

test_domains() {
  local name="$PREFIX-domain"
  local host
  case "$CURRENT_ENGINE" in
    dory) host="$name.dory.local" ;;
    orbstack) host="$name.orb.local" ;;
    *) return 2 ;;
  esac
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" -p 80 "$NGINX_IMAGE" >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://$host" | grep -qi 'welcome' && { docker_e rm -f "$name" >/dev/null; return 0; }
    sleep 1
  done
  docker_e rm -f "$name" >/dev/null
  return 1
}

test_direct_ip() {
  [ "$CURRENT_ENGINE" = "dory" ] || { echo "direct container IP routing is a Dory shared-VM claim"; return 1; }
  local name="$PREFIX-direct-ip" ip iface_file iface route_info
  iface_file="${DORY_DIRECT_IP_INTERFACE_FILE:-$HOME/.dory/hv/direct-ip.interface}"
  [ -f "$iface_file" ] || {
    echo "direct-IP interface file missing: $iface_file; start Dory and run scripts/enable-networking.sh --direct-ip"
    return 1
  }
  iface="$(tr -d '[:space:]' < "$iface_file")"
  [ -n "$iface" ] || { echo "direct-IP interface file is empty: $iface_file"; return 1; }
  if ! ifconfig "$iface" >/dev/null 2>&1; then
    echo "direct-IP interface is not active: $iface"
    return 1
  fi
  docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" "$NGINX_IMAGE" >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ip="$(docker_e inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null)"
    [ -n "$ip" ] && break
    sleep 1
  done
  [ -n "$ip" ] || { docker_e rm -f "$name" >/dev/null; echo "container has no IPv4 address"; return 1; }
  route_info="$(route -n get "$ip" 2>/dev/null || true)"
  if ! printf '%s\n' "$route_info" | grep -Eq "interface: +$iface"; then
    docker_e rm -f "$name" >/dev/null
    echo "host route for $ip does not use $iface; run scripts/enable-networking.sh --direct-ip"
    return 1
  fi
  ping -c 1 -W 1000 "$ip" >/dev/null
  curl -fsS --connect-timeout 3 "http://$ip" | grep -qi 'welcome'
  docker_e rm -f "$name" >/dev/null
}

vpn_snapshot() {
  local dir="$1"
  mkdir -p "$dir"
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig > "$dir/interfaces.txt" 2>&1 || true
  elif command -v ip >/dev/null 2>&1; then
    ip addr show > "$dir/interfaces.txt" 2>&1 || true
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -rn > "$dir/routes.txt" 2>&1 || true
  elif command -v ip >/dev/null 2>&1; then
    ip route show table all > "$dir/routes.txt" 2>&1 || true
  fi
  if command -v route >/dev/null 2>&1; then
    route -n get default > "$dir/default-route.txt" 2>&1 || true
  fi
  if command -v scutil >/dev/null 2>&1; then
    scutil --dns > "$dir/dns.txt" 2>&1 || true
  elif [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$dir/dns.txt" 2>/dev/null || true
  fi
}

vpn_detected() {
  local dir="$1"
  grep -Eiq '(^utun[0-9]*:|^ppp[0-9]*:|^tun[0-9]*:|^tap[0-9]*:|wireguard|wg[0-9]|tailscale|zerotier|vpn)' \
    "$dir/interfaces.txt" "$dir/routes.txt" "$dir/dns.txt" 2>/dev/null
}

test_vpn_coexistence() {
  [ "$CURRENT_ENGINE" = "dory" ] || { echo "VPN coexistence is a Dory gvproxy claim"; return 1; }
  local dir="$WORKDIR/${ENGINE_ID}-vpn"
  vpn_snapshot "$dir"
  if vpn_detected "$dir"; then
    echo "VPN-like interface or route detected; artifacts: $dir"
  elif [ "${DORY_REQUIRE_VPN:-0}" = "1" ]; then
    echo "no VPN-like interface or route detected; artifacts: $dir"
    return 1
  else
    echo "no VPN-like interface or route detected; recorded baseline artifacts: $dir"
  fi
  test_engine_info
  test_network_dns
  test_published_port
}

test_k8s() {
  command -v kubectl >/dev/null
  case "$CURRENT_ENGINE" in
    dory) KUBECONFIG="$HOME/.kube/dory-config" kubectl get nodes >/dev/null ;;
    orbstack) kubectl --context orbstack get nodes >/dev/null ;;
    docker-desktop|desktop) kubectl --context docker-desktop get nodes >/dev/null ;;
    *) return 2 ;;
  esac
}

test_machines() {
  case "$CURRENT_ENGINE" in
    dory) test_machines_dory ;;
    orbstack) orb list >/dev/null ;;
    docker-desktop|desktop) return 2 ;;
    *) return 2 ;;
  esac
}

# Exercises Dory's REAL machines feature (MachineService/MachineImageBuilder), not Apple's
# `container machine`: builds a systemd machine image with the same apt Dockerfile the app uses,
# runs it privileged as `/sbin/init` with the createBody HostConfig, and asserts systemd comes up
# as PID 1 — the backend-specific risk. Image + container carry the run label so cleanup removes them.
test_machines_dory() {
  local dir="$WORKDIR/${ENGINE_ID}-machine"
  local tag="dory-readiness-machine-${ENGINE_ID}-${RUN_SLUG}:latest"
  local name="$PREFIX-machine"
  mkdir -p "$dir"
  cat > "$dir/Dockerfile" <<EOF
FROM ubuntu:24.04
LABEL $LABEL_KEY=$RUN_ID
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session sudo bash openssh-server ca-certificates iproute2 iputils-ping curl && rm -rf /var/lib/apt/lists/* && (systemctl mask systemd-resolved.service systemd-networkd.service || true)
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
  DOCKER_BUILDKIT=1 docker_e build -t "$tag" "$dir" >/dev/null
  docker_e create --name "$name" --hostname machinetest \
    --label "$LABEL_KEY=$RUN_ID" --label "dory.machine=ubuntu" \
    --privileged --cgroupns host \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --restart unless-stopped --stop-signal SIGRTMIN+3 \
    -e container=docker \
    "$tag" /sbin/init >/dev/null
  docker_e start "$name" >/dev/null
  local ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if docker_e exec "$name" systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then ok=1; break; fi
    sleep 2
  done
  [ "$ok" = "1" ]
  docker_e exec "$name" cat /proc/1/comm | grep -q systemd
  docker_e exec "$name" sh -c 'echo machine-exec-ok' | grep -q machine-exec-ok
  docker_e exec "$name" sh -c 'getent hosts host.docker.internal >/dev/null || ping -c1 -W1 host.docker.internal >/dev/null'
  docker_e exec "$name" sh -c 'getent hosts host.dory.internal >/dev/null || ping -c1 -W1 host.dory.internal >/dev/null'
  docker_e rm -f "$name" >/dev/null
  docker_e rmi -f "$tag" >/dev/null
}

machine_recipe_command() {
  local recipe="$1"
  if [ -n "${READINESS_MACHINE_RECIPE_COMMAND:-}" ]; then
    printf '%s' "$READINESS_MACHINE_RECIPE_COMMAND"
    return
  fi
  case "$recipe" in
    rust|rust-dev) printf '%s' 'test -x "$HOME/.cargo/bin/cargo" && "$HOME/.cargo/bin/cargo" --version' ;;
    node) printf '%s' 'node --version && corepack --version' ;;
    go) printf '%s' '. /etc/profile.d/go.sh 2>/dev/null || true; go version' ;;
    python-ml) printf '%s' 'python3 --version && python3 -m pip --version' ;;
    docker-host) printf '%s' 'docker --version' ;;
    k8s-lab) printf '%s' 'kubectl version --client=true' ;;
    *) printf '%s' 'cat /proc/1/comm | grep -Eq "systemd|tail"' ;;
  esac
}

test_machine_recipe() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  local recipe="${READINESS_MACHINE_RECIPE:-rust}"
  local name="recipe-${RUN_SLUG}"
  local cid="dory-machine-$name"
  local command
  command="$(machine_recipe_command "$recipe")"
  docker_e rm -f "$cid" >/dev/null 2>&1 || true
  trap 'docker_e rm -f "$cid" >/dev/null 2>&1 || true' RETURN
  "$ROOT/scripts/dory" machine create "$name" --recipe "$recipe" >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    docker_e inspect "$cid" --format '{{.State.Running}}' 2>/dev/null | grep -q true && break
    sleep 2
  done
  docker_e inspect "$cid" --format '{{index .Config.Labels "dory.recipe"}}' | grep -qx "$recipe"
  docker_e exec "$cid" sh -lc "$command"
  docker_e rm -f "$cid" >/dev/null
  trap - RETURN
}

test_bridge() {
  local mname="dory-brdg-$RUN_SLUG"
  local cname="dory-machine-$mname"
  local hbridge="$HOME/.dory/bridge/$mname"
  rm -rf "$hbridge"; mkdir -p "$hbridge/open" "$hbridge/forward"
  docker_e rm -f "$cname" >/dev/null 2>&1 || true
  docker_e run -d --name "$cname" --label "$LABEL_KEY=$RUN_ID" \
    -v "$hbridge:/opt/dory/bridge" -e BROWSER=dory-open \
    "$ALPINE_IMAGE" tail -f /dev/null >/dev/null
  awk '/static let script = ##"""/{f=1;next} f && $0 ~ /^[[:space:]]*"""##[[:space:]]*$/{f=0;next} f' \
    "$ROOT/Dory/Runtime/Machines/DoryOpenShim.swift" \
    | docker_e exec -i "$cname" sh -c 'cat > /usr/local/bin/dory-open && chmod +x /usr/local/bin/dory-open'
  docker_e exec "$cname" sh -c 'command -v nc >/dev/null 2>&1 || (apk add --no-cache netcat-openbsd >/dev/null 2>&1 || true)'
  docker_e exec -d "$cname" sh -c '(printf "HTTP/1.0 200 OK\r\n\r\nok" | nc -l -p 53219) >/dev/null 2>&1'
  docker_e exec "$cname" sh -c '/usr/local/bin/dory-open "http://127.0.0.1:53219/cb?code=xyz"' >/dev/null
  local seen_open=0 seen_forward=0
  for _ in $(seq 1 20); do
    ls "$hbridge/open/"*.json >/dev/null 2>&1 && seen_open=1
    [ -f "$hbridge/forward/53219.json" ] && seen_forward=1
    [ "$seen_open" = 1 ] && [ "$seen_forward" = 1 ] && break
    sleep 0.25
  done
  grep -q 'http://127.0.0.1:53219/cb?code=xyz' "$hbridge/open/"*.json 2>/dev/null || { echo "open request missing"; return 1; }
  [ "$seen_forward" = 1 ] || { echo "forward request missing"; return 1; }
  ( echo -e "GET /cb HTTP/1.0\r\n\r" | docker_e exec -i "$cname" nc 127.0.0.1 53219 ) | grep -q 'ok' \
    || { echo "guest loopback server unreachable via exec-nc"; return 1; }
  docker_e rm -f "$cname" >/dev/null 2>&1 || true
  rm -rf "$hbridge"
  return 0
}

test_dax() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  local hv="${DORY_HV_BIN:-$ROOT/Packages/ContainerizationEngine/.build/debug/dory-hv}"
  [ -x "$hv" ] || { echo "dory-hv not found or executable: $hv"; return 1; }
  "$hv" daxprobe | grep -q "dax coherence passed"
}

test_rosetta() {
  local vm="${DORY_VM_HELPER:-$ROOT/Packages/ContainerizationEngine/.build/out/Products/Debug/dory-vmboot}"
  [ -x "$vm" ] || { echo "dory-vm helper not found or executable: $vm"; return 1; }
  [ -e /Library/Apple/usr/libexec/oah/RosettaLinux ] || { echo "Rosetta for Linux not installed (softwareupdate --install-rosetta)"; return 1; }
  "$vm" --image "${DORY_ROSETTA_IMAGE:-docker.io/library/alpine:latest}" --arch amd64 --rosetta -- 'uname -m' 2>/dev/null | grep -qx x86_64
}

test_guest_agent() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  local hv="${DORY_HV_BIN:-$ROOT/Packages/ContainerizationEngine/.build/debug/dory-hv}"
  local kernel="${DORY_GUEST_KERNEL:-$ROOT/guest/out/Image}"
  local initfs="${DORY_GUEST_INITFS:-}"
  [ -x "$hv" ] || { echo "dory-hv not found or executable: $hv"; return 1; }
  [ -f "$kernel" ] || { echo "guest kernel not found: $kernel"; return 1; }
  [ -n "$initfs" ] && [ -f "$initfs" ] || { echo "set DORY_GUEST_INITFS to a built initfs.ext4"; return 1; }
  "$hv" agent-ping --kernel "$kernel" --initfs "$initfs" --mem-mb "${DORY_GUEST_AGENT_MEM_MB:-512}" --cpus 2 --timeout-sec "${DORY_GUEST_AGENT_TIMEOUT:-30}" \
    | tee "$WORKDIR/${ENGINE_ID}-guest-agent.json" \
    | grep -q '"kernel":"6.12.30-dory"'
}

agent_rpc_readiness() {
  local sock="$1" method="$2" payload="$3"
  [ -n "$sock" ] && [ -S "$sock" ] || { echo "agent socket not found: $sock"; return 2; }
  python3 - "$sock" "$method" "$payload" <<'PY'
import json, socket, struct, sys

def recv_exactly(s, count):
    buf = b""
    while len(buf) < count:
        chunk = s.recv(count - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf

sock_path, method, payload = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
request = json.dumps({"id": 1, "method": method, "params": payload}, separators=(",", ":")).encode()
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(sock_path)
    s.sendall(struct.pack(">I", len(request)) + request)
    header = recv_exactly(s, 4)
    if len(header) != 4:
        raise SystemExit("agent closed before response")
    length = struct.unpack(">I", header)[0]
    data = recv_exactly(s, length)
    if len(data) != length:
        raise SystemExit("agent closed mid-response")
response = json.loads(data)
if response.get("error"):
    print(response["error"].get("message", "agent request failed"), file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(response.get("result", {}), sort_keys=True))
PY
}

agent_exec_stdout() {
  local sock="$1" payload="$2"
  agent_rpc_readiness "$sock" "exec" "$payload" | python3 -c '
import base64, json, sys
result = json.load(sys.stdin)
if int(result.get("exit_code", 0)) != 0:
    if result.get("stderr_b64"):
        sys.stderr.buffer.write(base64.b64decode(result["stderr_b64"]))
    raise SystemExit(int(result.get("exit_code", 1)))
if result.get("stdout_b64"):
    sys.stdout.buffer.write(base64.b64decode(result["stdout_b64"]))
'
}

clock_sync_helper_pid() {
  if [ -n "${DORY_CLOCK_SYNC_PID:-}" ]; then
    echo "$DORY_CLOCK_SYNC_PID"
    return
  fi
  [ -f "$HOME/.dory/engine.pid" ] && cat "$HOME/.dory/engine.pid"
}

test_clock_sync() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  local sock="${DORY_CLOCK_SYNC_AGENT_SOCK:-${DORY_AGENT_SOCK:-}}"
  local pid guest_raw guest_ns host_ns delta_ms
  [ -n "$sock" ] && [ -S "$sock" ] || { echo "set DORY_CLOCK_SYNC_AGENT_SOCK or DORY_AGENT_SOCK to a live guest agent bridge socket"; return 1; }
  pid="$(clock_sync_helper_pid)"
  [ -n "$pid" ] || { echo "set DORY_CLOCK_SYNC_PID or start Dory so $HOME/.dory/engine.pid exists"; return 1; }
  kill -0 "$pid" 2>/dev/null || { echo "helper pid is not live: $pid"; return 1; }

  agent_exec_stdout "$sock" '{"argv":["date","-s","@946684800"],"timeout_ms":5000}' >/dev/null
  kill -USR1 "$pid"
  sleep "${DORY_CLOCK_SYNC_SETTLE:-0.5}"
  guest_raw="$(agent_exec_stdout "$sock" '{"argv":["date","+%s%N"],"timeout_ms":5000}' | tr -d '[:space:]')"
  case "$guest_raw" in
    *[!0-9]*|"") echo "guest date does not support numeric nanosecond output: $guest_raw"; return 1 ;;
  esac
  guest_ns="$guest_raw"
  host_ns="$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)"
  delta_ms="$(python3 - "$host_ns" "$guest_ns" <<'PY'
import sys
host = int(sys.argv[1])
guest = int(sys.argv[2])
print(abs(host - guest) // 1_000_000)
PY
)"
  [ "$delta_ms" -le "$CLOCK_SYNC_TOLERANCE_MS" ] || {
    echo "clock delta ${delta_ms}ms exceeds tolerance ${CLOCK_SYNC_TOLERANCE_MS}ms"
    return 1
  }
  echo "clock delta ${delta_ms}ms"
}

test_usb() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  if ! "$ROOT/scripts/dory" usb ls 2>/dev/null | grep -q "$DORY_USB_TEST_BUSID"; then
    echo "device $DORY_USB_TEST_BUSID not present in 'dory usb ls'" >&2
    return 1
  fi
  "$ROOT/scripts/dory" usb attach "$DORY_USB_TEST_BUSID" "${DORY_USBIP_PORT:-0}" || return 1
  "$ROOT/scripts/dory" usb detach "$DORY_USB_TEST_BUSID" "${DORY_USBIP_PORT:-0}" || return 1
}

test_debug_shell() {
  [ "$CURRENT_ENGINE" = "dory" ] || return 2
  DORY_DEBUG_AGENT_SOCK="$DORY_DEBUG_AGENT_SOCK" "$ROOT/scripts/dory" debug "$DORY_DEBUG_CONTAINER_ID" -- /bin/sh -c 'echo dory-debug-ok' \
    | grep -q 'dory-debug-ok'
}

measure_memory() {
  local engine="$1"
  local image="$ALPINE_IMAGE"
  local base peak rss_base rss_peak sys_delta rss_delta i name
  cleanup_engine
  docker_e pull "$image" >/dev/null 2>&1 || return 1
  sleep "$SETTLE"
  base="$(used_mem)"
  rss_base="$(process_rss_bytes "$engine")"
  for i in $(seq 1 "$MEMORY_COUNT"); do
    name="$PREFIX-mem-$i"
    docker_e run -d --name "$name" --label "$LABEL_KEY=$RUN_ID" "$image" sleep 600 >/dev/null || return 1
  done
  sleep "$SETTLE"
  peak="$(used_mem)"
  rss_peak="$(process_rss_bytes "$engine")"
  sys_delta=$((peak - base))
  rss_delta=$((rss_peak - rss_base))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$engine" "$MEMORY_COUNT" "$image" "$sys_delta" "$(mb "$sys_delta")" "$rss_delta" "$(mb "$rss_delta")" >> "$MEMORY_RESULTS"
  cleanup_engine
}

run_engine() {
  CURRENT_ENGINE="$1"
  ENGINE_ID="$(engine_id "$CURRENT_ENGINE")"
  ENGINE_SOCK="$(engine_socket "$CURRENT_ENGINE")"
  PREFIX="dory-ready-$ENGINE_ID-$$"

  note "$CURRENT_ENGINE ($ENGINE_SOCK)"
  if ! command -v docker >/dev/null 2>&1; then
    skip_case "$CURRENT_ENGINE" "all Docker CLI checks" "docker CLI not found"
    return
  fi
  if ! require_socket; then
    skip_case "$CURRENT_ENGINE" "all checks" "socket not found: $ENGINE_SOCK"
    return
  fi

  cleanup_engine
  run_case "$CURRENT_ENGINE" "engine info / version / system df" test_engine_info
  run_case "$CURRENT_ENGINE" "pull alpine + nginx" test_pull_images
  run_case "$CURRENT_ENGINE" "container lifecycle + logs + exec + stats" test_lifecycle_logs_exec_stats
  run_case "$CURRENT_ENGINE" "docker cp + export" test_cp_archive
  run_case "$CURRENT_ENGINE" "bind mount host read/write" test_bind_mount
  if [ "$RUN_FILE_WATCH" = "1" ]; then
    run_case "$CURRENT_ENGINE" "host file edit propagates to inotify" test_file_watch
  else
    skip_case "$CURRENT_ENGINE" "host file edit propagates to inotify" "enable with --file-watch"
  fi
  run_case "$CURRENT_ENGINE" "volume create/use/inspect/remove" test_volume_roundtrip
  run_case "$CURRENT_ENGINE" "network create + service DNS" test_network_dns
  run_case "$CURRENT_ENGINE" "localhost published port" test_published_port
  run_case "$CURRENT_ENGINE" "BuildKit docker build" test_buildkit_build
  run_case "$CURRENT_ENGINE" "docker compose up/logs/port/down" test_compose
  run_case "$CURRENT_ENGINE" "commit + save/load image archive" test_image_archive_commit
  run_case "$CURRENT_ENGINE" "memory/cpu resource limits + update" test_resource_limits_update

  if [ "$RUN_AMD64" = "1" ]; then
    run_case "$CURRENT_ENGINE" "linux/amd64 emulation" test_amd64
  else
    skip_case "$CURRENT_ENGINE" "linux/amd64 emulation" "disabled"
  fi

  if [ "$RUN_ONLINE" = "1" ]; then
    run_case "$CURRENT_ENGINE" "online docker search" test_online_search
  else
    skip_case "$CURRENT_ENGINE" "online docker search" "disabled by default"
  fi

  if [ "$RUN_DOMAINS" = "1" ]; then
    run_case "$CURRENT_ENGINE" "automatic local domains" test_domains
  else
    skip_case "$CURRENT_ENGINE" "automatic local domains" "enable with --domains after system integration is installed"
  fi

  if [ "$RUN_DIRECT_IP" = "1" ]; then
    run_case "$CURRENT_ENGINE" "direct container IP ping + HTTP" test_direct_ip
  else
    skip_case "$CURRENT_ENGINE" "direct container IP ping + HTTP" "enable with --direct-ip after scripts/enable-networking.sh --direct-ip"
  fi

  if [ "$RUN_VPN" = "1" ]; then
    run_case "$CURRENT_ENGINE" "VPN coexistence userspace networking" test_vpn_coexistence
  else
    skip_case "$CURRENT_ENGINE" "VPN coexistence userspace networking" "enable with --vpn; set DORY_REQUIRE_VPN=1 to require an active VPN"
  fi

  if [ "$RUN_K8S" = "1" ]; then
    run_case "$CURRENT_ENGINE" "Kubernetes context reachable" test_k8s
  else
    skip_case "$CURRENT_ENGINE" "Kubernetes context reachable" "enable with --k8s"
  fi

  if [ "$RUN_MACHINES" = "1" ]; then
    run_case "$CURRENT_ENGINE" "Linux machine build + systemd boot + exec" test_machines
  else
    skip_case "$CURRENT_ENGINE" "Linux machine build + systemd boot + exec" "enable with --machines"
  fi

  if [ "$RUN_MACHINE_RECIPE" = "1" ]; then
    run_case "$CURRENT_ENGINE" "Linux machine recipe create + provisioned command" test_machine_recipe
  else
    skip_case "$CURRENT_ENGINE" "Linux machine recipe create + provisioned command" "enable with --machine-recipe"
  fi

  if [ "$RUN_BRIDGE" = "1" ]; then
    run_case "$CURRENT_ENGINE" "guest→host bridge (dory-open open + forward)" test_bridge
  else
    skip_case "$CURRENT_ENGINE" "guest→host bridge (dory-open open + forward)" "enable with --bridge"
  fi

  if [ "$RUN_GUEST_AGENT" = "1" ]; then
    run_case "$CURRENT_ENGINE" "dory-hv guest-agent vsock ping" test_guest_agent
  else
    skip_case "$CURRENT_ENGINE" "dory-hv guest-agent vsock ping" "enable with --guest-agent and DORY_GUEST_INITFS"
  fi

  if [ "$RUN_DAX" = "1" ]; then
    run_case "$CURRENT_ENGINE" "dory-hv virtio-fs DAX coherence" test_dax
  else
    skip_case "$CURRENT_ENGINE" "dory-hv virtio-fs DAX coherence" "enable with --dax (needs a signed dory-hv)"
  fi

  if [ "$RUN_ROSETTA" = "1" ]; then
    run_case "$CURRENT_ENGINE" "Rosetta x86-64 machine execution" test_rosetta
  else
    skip_case "$CURRENT_ENGINE" "Rosetta x86-64 machine execution" "enable with --rosetta (needs a signed dory-vm + Rosetta installed)"
  fi

  if [ "$RUN_CLOCK_SYNC" = "1" ] && [ "$CURRENT_ENGINE" != "dory" ]; then
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "Dory-only"
  elif [ "$RUN_CLOCK_SYNC" = "1" ] && [ -z "${DORY_CLOCK_SYNC_AGENT_SOCK:-${DORY_AGENT_SOCK:-}}" ]; then
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "set DORY_CLOCK_SYNC_AGENT_SOCK or DORY_AGENT_SOCK"
  elif [ "$RUN_CLOCK_SYNC" = "1" ] && { [ -z "${DORY_CLOCK_SYNC_PID:-}" ] && [ ! -f "$HOME/.dory/engine.pid" ]; }; then
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "set DORY_CLOCK_SYNC_PID or start Dory"
  elif [ "$RUN_CLOCK_SYNC" = "1" ]; then
    run_case "$CURRENT_ENGINE" "host wake clock sync" test_clock_sync
  else
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "enable with --clock-sync and a live agent socket"
  fi

  if [ "$RUN_USB" = "1" ] && [ -z "${DORY_USB_TEST_BUSID:-}" ]; then
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "set DORY_USB_TEST_BUSID"
  elif [ "$RUN_USB" = "1" ] && { [ -z "${DORY_USB_AGENT_SOCK:-}" ] || [ -z "${DORY_USBIP_SOCKET_FD:-}" ]; }; then
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "set DORY_USB_AGENT_SOCK and DORY_USBIP_SOCKET_FD"
  elif [ "$RUN_USB" = "1" ] && ! grep -q 'usb)' "$ROOT/scripts/dory"; then
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "USB CLI attach surface pending"
  elif [ "$RUN_USB" = "1" ]; then
    run_case "$CURRENT_ENGINE" "USB/IP hardware smoke" test_usb
  else
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "enable with --usb and DORY_USB_TEST_BUSID"
  fi

  if [ "$RUN_DEBUG_SHELL" = "1" ] && { [ -z "${DORY_DEBUG_AGENT_SOCK:-}" ] || [ -z "${DORY_DEBUG_CONTAINER_ID:-}" ]; }; then
    skip_case "$CURRENT_ENGINE" "debug shell via guest agent" "set DORY_DEBUG_AGENT_SOCK and DORY_DEBUG_CONTAINER_ID"
  elif [ "$RUN_DEBUG_SHELL" = "1" ]; then
    run_case "$CURRENT_ENGINE" "debug shell via guest agent" test_debug_shell
  else
    skip_case "$CURRENT_ENGINE" "debug shell via guest agent" "enable with --debug-shell"
  fi

  if [ "$RUN_MEMORY" = "1" ]; then
    run_case "$CURRENT_ENGINE" "memory delta for $MEMORY_COUNT idle containers" measure_memory "$CURRENT_ENGINE"
  else
    skip_case "$CURRENT_ENGINE" "memory delta" "disabled"
  fi
  cleanup_engine
}

write_summary() {
  cat > "$SUMMARY_JSON" <<EOF
{
  "runId": "$RUN_ID",
  "engines": "$ENGINES",
  "pass": $PASS_COUNT,
  "fail": $FAIL_COUNT,
  "skip": $SKIP_COUNT,
  "results": "$RESULTS",
  "memory": "$MEMORY_RESULTS"
}
EOF
}

trap '{ cleanup_engine; write_summary; } >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

note "readiness run $RUN_ID"
note "results: $RESULTS"

if [ "$STOP_ORBSTACK" = "1" ]; then
  note "stopping OrbStack before checks"
  stop_orbstack
fi

OLD_IFS="$IFS"
IFS=','
for engine in $ENGINES; do
  IFS="$OLD_IFS"
  engine="$(printf '%s' "$engine" | sed 's/^ *//;s/ *$//')"
  [ -n "$engine" ] && run_engine "$engine"
  IFS=','
done
IFS="$OLD_IFS"

write_summary

note "summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
note "memory: $MEMORY_RESULTS"
note "summary json: $SUMMARY_JSON"

[ "$FAIL_COUNT" -eq 0 ]
