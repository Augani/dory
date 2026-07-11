#!/bin/bash
# End-to-end replacement readiness checks for Dory, OrbStack, and Docker Desktop.
#
# The suite drives the public Docker CLI against each engine socket. It labels and names every
# resource it creates, then removes only those resources during cleanup.
#
# Examples:
#   scripts/readiness.sh --engines dory
#   scripts/readiness.sh --engines doryd
#   scripts/readiness.sh --engines orbstack,dory --memory-count 5
#   RUN_DOMAINS=1 RUN_NONNATIVE_ARCH=1 scripts/readiness.sh --engines dory,orbstack
#
# Environment knobs:
#   DORY_SOCK, DORYD_SOCK, ORBSTACK_SOCK, DOCKER_DESKTOP_SOCK
#   READINESS_WORKDIR, READINESS_SETTLE, READINESS_ALPINE_IMAGE, READINESS_NGINX_IMAGE
#   READINESS_BUILD_CONTEXT_MB for the BuildKit streaming build payload (default: 32)
#   READINESS_NONNATIVE_BUILD_IMAGE for the non-native BuildKit qemu/npm probe (default: node:20-alpine)
#   RUN_MEMORY=0|1, RUN_NONNATIVE_ARCH=0|1, RUN_AMD64=0|1 (legacy alias), RUN_ONLINE=0|1, RUN_DOMAINS=0|1, RUN_DIRECT_IP=0|1, RUN_FILE_WATCH=0|1, RUN_K8S=0|1, RUN_MACHINES=0|1, RUN_MACHINE_RECIPE=0|1, RUN_USB=0|1, RUN_VPN=0|1
#   DORY_DIRECT_IP_INTERFACE_FILE points at the helper-written utun interface file
#   READINESS_FILE_WATCH_IMAGE for --file-watch (default: alpine image)
#   READINESS_MACHINE_RECIPE, READINESS_MACHINE_RECIPE_COMMAND for --machine-recipe
#   RUN_DEBUG_SHELL=0|1 (currently records an explicit unsupported skip)
#   RUN_CLOCK_SYNC=0|1, DORY_CLOCK_SYNC_TOLERANCE_MS
#   RUN_GUEST_AGENT=0|1, DORY_HV_BIN, DORY_GUEST_KERNEL, DORY_GUEST_INITFS
#   DORYD_CTL, DORYD_MACHINE_KERNEL, DORYD_MACHINE_ROOTFS for doryd per-VM machine checks
#   RUN_USB=1 records an explicit unsupported skip until the agent has a vhci attach RPC
#   DORY_REQUIRE_VPN=1 makes --vpn fail when no active VPN-like interface or route is detected
#   STOP_ORBSTACK=1 to quit OrbStack before running Dory-only checks
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINES="${ENGINES:-dory}"
ALPINE_IMAGE="${READINESS_ALPINE_IMAGE:-alpine:latest}"
NGINX_IMAGE="${READINESS_NGINX_IMAGE:-nginx:alpine}"
NONNATIVE_BUILD_IMAGE="${READINESS_NONNATIVE_BUILD_IMAGE:-node:20-alpine}"
MEMORY_COUNT="${READINESS_MEMORY_COUNT:-3}"
BUILD_CONTEXT_MB="${READINESS_BUILD_CONTEXT_MB:-32}"
SETTLE="${READINESS_SETTLE:-8}"
RUN_MEMORY="${RUN_MEMORY:-1}"
RUN_NONNATIVE_ARCH="${RUN_NONNATIVE_ARCH:-${RUN_AMD64:-1}}"
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
  --engines LIST       Comma-separated: dory,doryd,orbstack,docker-desktop,current
  --memory-count N     Containers to run for memory measurements (default: $MEMORY_COUNT)
  --settle SECONDS     Wait time before/after memory workload (default: $SETTLE)
  --skip-memory        Skip memory measurements
  --skip-nonnative-arch
                       Skip the non-native architecture emulation check
  --skip-amd64         Legacy alias for --skip-nonnative-arch
  --online             Run online registry search check
  --domains            Run *.dory.local / *.orb.local checks when integration is active
  --direct-ip          Run Dory direct container-IP ping + browser check (requires system integration route)
  --file-watch         Run host edit to inotify propagation check for bind/shared mounts
  --k8s                Run Kubernetes context checks
  --machines           Run Linux machine CLI checks
  --machine-recipe     Create a Linux machine from a recipe and assert its provisioned command
  --bridge             Run guest→host bridge (dory-open) check
  --guest-agent        Run dory-hv guest-agent vsock smoke (requires DORY_GUEST_KERNEL and DORY_GUEST_INITFS)
  --dax                Run the low-level DAX mapping probe only (production host-share DAX is rejected)
  --rosetta            Record Rosetta machine backend status (pending dory-vmm Rosetta support)
  --usb                Record the unavailable guest USB attach/detach RPC explicitly
  --vpn                Record route/DNS state and run userspace networking checks during VPN coexistence testing
  --debug-shell        Record the unavailable agent namespace-debug RPC explicitly
  --clock-sync         Run the typed doryd host-wake clock synchronization path
  --stop-orbstack      Quit OrbStack before Dory-only runs
  -h, --help           Show this help

Clock sync env:
  DORY_CLOCK_SYNC_TOLERANCE_MS

doryd VM machine env:
  DORYD_CTL
  DORYD_MACHINE_KERNEL, DORYD_MACHINE_ROOTFS
  DORYD_MACHINE_MEMORY_MB, DORYD_MACHINE_CPUS
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="$2"; shift 2 ;;
    --memory-count) MEMORY_COUNT="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --skip-memory) RUN_MEMORY=0; shift ;;
    --skip-nonnative-arch|--skip-amd64) RUN_NONNATIVE_ARCH=0; shift ;;
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

host_guest_arch() {
  [ "$(uname -m)" = "x86_64" ] && printf '%s\n' "amd64" || printf '%s\n' "arm64"
}

nonnative_guest_arch() {
  [ "$(host_guest_arch)" = "amd64" ] && printf '%s\n' "arm64" || printf '%s\n' "amd64"
}

binfmt_handler_for_arch() {
  case "$1" in
    amd64) printf '%s\n' "qemu-x86_64" ;;
    arm64) printf '%s\n' "qemu-aarch64" ;;
    *) echo "unsupported arch: $1" >&2; return 2 ;;
  esac
}

uname_pattern_for_arch() {
  case "$1" in
    amd64) printf '%s\n' 'x86_64|amd64' ;;
    arm64) printf '%s\n' 'aarch64|arm64' ;;
    *) echo "unsupported arch: $1" >&2; return 2 ;;
  esac
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
    dory|doryd) pattern="${DORY_PROCESS_PATTERN:-Dory|doryd|dory-hv|dory-vmm|gvproxy}" ;;
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
    doryd) echo "${DORYD_SOCK:-${DORY_SOCK:-$HOME/.dory/dory.sock}}" ;;
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

dorydctl() {
  local arch cand
  if [ -n "${DORYD_CTL:-}" ]; then
    "$DORYD_CTL" "$@"
    return
  fi
  arch="$(uname -m)"
  for cand in \
    "$ROOT/dory-core-swift/.build/debug/dorydctl" \
    "$ROOT/dory-core-swift/.build/release/dorydctl" \
    "$ROOT/dory-core-swift/.build/$arch-apple-macosx/debug/dorydctl" \
    "$ROOT/dory-core-swift/.build/$arch-apple-macosx/release/dorydctl"; do
    [ -x "$cand" ] && { "$cand" "$@"; return; }
  done
  [ -f "$ROOT/dory-core-swift/Package.swift" ] || {
    echo "dorydctl not found; set DORYD_CTL or build dory-core-swift" >&2
    return 1
  }
  swift run --package-path "$ROOT/dory-core-swift" dorydctl "$@"
}

json_get() {
  local path="$1"
  python3 -c '
import json
import sys

path = sys.argv[1].split(".")
value = json.load(sys.stdin)
for part in path:
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
    if value is None:
        break
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "$path"
}

compose_e() {
  DOCKER_HOST="unix://$ENGINE_SOCK" docker compose "$@"
}

first_host_port() {
  awk -F: '
    NF {
      port = $NF
      gsub(/[^0-9].*/, "", port)
      if (port ~ /^[0-9]+$/) {
        print port
        exit
      }
    }
  '
}

wait_for_engine_ready() {
  local timeout="${READINESS_READY_TIMEOUT:-90}"
  local i
  for i in $(seq 1 "$timeout"); do
    docker_e version >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker_e version >/dev/null
}

is_dory_engine() {
  [ "$CURRENT_ENGINE" = "dory" ] || [ "$CURRENT_ENGINE" = "doryd" ]
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
  port="$(docker_e port "$name" 80/tcp | first_host_port)"
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
  local payload_mb payload_sha
  mkdir -p "$dir"
  case "$BUILD_CONTEXT_MB" in
    ''|*[!0-9]*) echo "READINESS_BUILD_CONTEXT_MB must be a non-negative integer"; return 1 ;;
  esac
  if [ "$BUILD_CONTEXT_MB" -gt 0 ]; then
    dd if=/dev/zero of="$dir/payload.bin" bs=1048576 count="$BUILD_CONTEXT_MB" status=none
  else
    : > "$dir/payload.bin"
  fi
  payload_mb="$BUILD_CONTEXT_MB"
  payload_sha="$(shasum -a 256 "$dir/payload.bin" | awk '{print $1}')"
  cat > "$dir/Dockerfile" <<EOF
FROM $ALPINE_IMAGE
LABEL $LABEL_KEY=$RUN_ID
ARG PAYLOAD_SHA
ARG PAYLOAD_MB
COPY payload.bin /payload.bin
RUN actual="\$(sha256sum /payload.bin | awk '{print \$1}')" \\
    && test "\$actual" = "\$PAYLOAD_SHA" \\
    && printf 'built-ok %sMB %s\n' "\$PAYLOAD_MB" "\$actual" > /built.txt
CMD ["cat", "/built.txt"]
EOF
  DOCKER_BUILDKIT=1 docker_e build --progress=plain \
    --build-arg "PAYLOAD_SHA=$payload_sha" \
    --build-arg "PAYLOAD_MB=$payload_mb" \
    -t "$tag" "$dir"
  docker_e run --rm --label "$LABEL_KEY=$RUN_ID" "$tag" | grep -q "built-ok ${payload_mb}MB $payload_sha"
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
  port="$(compose_e -f "$dir/compose.yaml" -p "$project" port web 80 | first_host_port)"
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

test_nonnative_arch() {
  local arch handler pattern name
  arch="$(nonnative_guest_arch)"
  handler="$(binfmt_handler_for_arch "$arch")"
  pattern="$(uname_pattern_for_arch "$arch")"
  name="$PREFIX-binfmt"
  docker_e run --rm --privileged --name "$name" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" \
    sh -c 'handler="$1"
           test -e /proc/sys/fs/binfmt_misc/register || { echo "binfmt_misc not mounted" >&2; exit 1; }
           test -e "/proc/sys/fs/binfmt_misc/$handler" || { echo "$handler handler not registered" >&2; exit 1; }
           grep -qx enabled "/proc/sys/fs/binfmt_misc/$handler" || { echo "$handler handler not enabled" >&2; exit 1; }' sh "$handler"
  docker_e run --rm --platform "linux/$arch" --label "$LABEL_KEY=$RUN_ID" "$ALPINE_IMAGE" uname -m | grep -Eq "$pattern"
}

test_nonnative_build() {
  local arch pattern node_arch dir tag
  arch="$(nonnative_guest_arch)"
  pattern="$(uname_pattern_for_arch "$arch")"
  case "$arch" in
    amd64) node_arch="x64" ;;
    arm64) node_arch="arm64" ;;
    *) echo "unsupported arch: $arch" >&2; return 2 ;;
  esac
  dir="$WORKDIR/${ENGINE_ID}-nonnative-build"
  tag="dory-readiness-${ENGINE_ID}-${RUN_SLUG}:nonnative-$arch"
  mkdir -p "$dir"
  cat > "$dir/Dockerfile" <<EOF
FROM $NONNATIVE_BUILD_IMAGE
LABEL $LABEL_KEY=$RUN_ID
ARG EXPECTED_UNAME
ARG EXPECTED_NODE_ARCH
ENV EXPECTED_NODE_ARCH=\$EXPECTED_NODE_ARCH
RUN actual="\$(uname -m)" \\
    && printf '%s\n' "\$actual" > /uname.txt \\
    && printf '%s\n' "\$actual" | grep -Eq "\$EXPECTED_UNAME"
RUN node -e "if (process.arch !== process.env.EXPECTED_NODE_ARCH) { throw new Error(process.arch + ' != ' + process.env.EXPECTED_NODE_ARCH) } console.log(process.arch)" > /node-arch.txt
RUN npm --version > /npm-version.txt
CMD ["sh", "-c", "cat /uname.txt /node-arch.txt /npm-version.txt"]
EOF
  DOCKER_BUILDKIT=1 docker_e build --progress=plain --platform "linux/$arch" \
    --build-arg "EXPECTED_UNAME=$pattern" \
    --build-arg "EXPECTED_NODE_ARCH=$node_arch" \
    -t "$tag" "$dir"
  docker_e run --rm --platform "linux/$arch" --label "$LABEL_KEY=$RUN_ID" "$tag" | grep -q "$node_arch"
  docker_e rmi -f "$tag" >/dev/null
}

test_online_search() {
  docker_e search --limit 1 alpine | grep -qi 'alpine'
}

test_domains() {
  local name="$PREFIX-domain"
  local host
  case "$CURRENT_ENGINE" in
    dory|doryd) host="$name.dory.local" ;;
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
  is_dory_engine || { echo "direct container IP routing is a Dory shared-VM claim"; return 1; }
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
  is_dory_engine || { echo "VPN coexistence is a Dory gvproxy claim"; return 1; }
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
    dory|doryd) KUBECONFIG="$HOME/.kube/dory-config" kubectl get nodes >/dev/null ;;
    orbstack) kubectl --context orbstack get nodes >/dev/null ;;
    docker-desktop|desktop) kubectl --context docker-desktop get nodes >/dev/null ;;
    *) return 2 ;;
  esac
}

test_machines() {
  case "$CURRENT_ENGINE" in
    dory|doryd) test_machines_doryd ;;
    orbstack) orb list >/dev/null ;;
    docker-desktop|desktop) return 2 ;;
    *) return 2 ;;
  esac
}

# Legacy container-backed machine smoke retained for explicit migration troubleshooting only.
# Release readiness uses doryd VM machines through test_machines_doryd.
test_machines_legacy_container() {
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

test_machines_doryd() {
  local host_arch rootfs_default kernel rootfs
  case "$(uname -m)" in
    arm64|aarch64) host_arch="arm64" ;;
    *) host_arch="amd64" ;;
  esac
  rootfs_default="$ROOT/guest/out/initfs-$host_arch.ext4"
  kernel="${DORYD_MACHINE_KERNEL:-${DORYD_GUEST_KERNEL:-$ROOT/guest/out/Image}}"
  rootfs="${DORYD_MACHINE_ROOTFS:-${DORYD_GUEST_ROOTFS:-$rootfs_default}}"
  local memory="${DORYD_MACHINE_MEMORY_MB:-2048}"
  local cpus="${DORYD_MACHINE_CPUS:-2}"
  local dir="$WORKDIR/${ENGINE_ID}-machine-vm"
  local name="ready-${RUN_SLUG}"
  local state agent agent_socket detail

  [ -n "$kernel" ] && [ -f "$kernel" ] || {
    echo "set DORYD_MACHINE_KERNEL to a bootable Linux kernel for doryd VM machine readiness"
    return 1
  }
  [ -n "$rootfs" ] && [ -f "$rootfs" ] || {
    echo "set DORYD_MACHINE_ROOTFS to a rootfs with dory-agent as PID 1 for doryd VM machine readiness"
    return 1
  }

  mkdir -p "$dir"
  dorydctl machine delete "$name" >/dev/null 2>&1 || true
  trap 'dorydctl machine stop "$name" >/dev/null 2>&1 || true; dorydctl machine delete "$name" >/dev/null 2>&1 || true' RETURN

  dorydctl machine create "$name" --kernel "$kernel" --rootfs "$rootfs" --memory-mb "$memory" --cpus "$cpus" > "$dir/create.json"
  dorydctl machine start "$name" > "$dir/start.json"

  state=""
  for _ in $(seq 1 "${DORYD_MACHINE_READY_POLLS:-60}"); do
    dorydctl machine status "$name" > "$dir/status.json"
    state="$(json_get state < "$dir/status.json")"
    case "$state" in
      running) break ;;
      failed)
        detail="$(json_get lastError < "$dir/status.json")"
        echo "doryd machine failed: ${detail:-unknown failure}"
        return 1
        ;;
    esac
    sleep "${DORYD_MACHINE_READY_INTERVAL:-2}"
  done

  [ "$state" = "running" ] || {
    cat "$dir/status.json" >&2
    echo "doryd machine did not reach running"
    return 1
  }
  agent="$(json_get agentBuild < "$dir/status.json")"
  [ -n "$agent" ] || {
    cat "$dir/status.json" >&2
    echo "doryd machine reached running without an agent build"
    return 1
  }
  agent_socket="$(json_get agentSocketPath < "$dir/status.json")"
  [ -n "$agent_socket" ] && [ -S "$agent_socket" ] || {
    cat "$dir/status.json" >&2
    echo "doryd machine reached running without a live agent socket"
    return 1
  }
  dorydctl machine exec "$name" -- /bin/sh -lc 'echo machine-exec-ok' > "$dir/exec.out"
  grep -qx 'machine-exec-ok' "$dir/exec.out"
  dorydctl machine stop "$name" > "$dir/stop.json"
  dorydctl machine delete "$name" > "$dir/delete.json"
  trap - RETURN
}

machine_recipe_command() {
  local recipe="$1"
  if [ -n "${READINESS_MACHINE_RECIPE_COMMAND:-}" ]; then
    printf '%s' "$READINESS_MACHINE_RECIPE_COMMAND"
    return
  fi
  if [ "${CURRENT_ENGINE:-}" = "dory" ] || [ "${CURRENT_ENGINE:-}" = "doryd" ]; then
    case "$recipe" in
      rust|rust-dev) printf '%s' 'cargo --version' ;;
      node) printf '%s' 'node --version && npm --version' ;;
      go) printf '%s' 'go version' ;;
      python|python-ml) printf '%s' 'python3 --version && python3 -m pip --version' ;;
      docker-host) printf '%s' 'docker --version' ;;
      k8s-lab|k8s|kubectl) printf '%s' 'kubectl version --client=true' ;;
      *) printf '%s' 'cat /proc/1/comm | grep -Eq "dory-agent|init|systemd|tail"' ;;
    esac
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
  is_dory_engine || return 2
  if is_dory_engine; then
    local host_arch rootfs_default kernel rootfs memory cpus dir name state detail command recipe
    case "$(uname -m)" in
      arm64|aarch64) host_arch="arm64" ;;
      *) host_arch="amd64" ;;
    esac
    rootfs_default="$ROOT/guest/out/initfs-$host_arch.ext4"
    kernel="${DORYD_MACHINE_KERNEL:-${DORYD_GUEST_KERNEL:-$ROOT/guest/out/Image}}"
    rootfs="${DORYD_MACHINE_ROOTFS:-${DORYD_GUEST_ROOTFS:-$rootfs_default}}"
    memory="${DORYD_MACHINE_MEMORY_MB:-2048}"
    cpus="${DORYD_MACHINE_CPUS:-2}"
    recipe="${READINESS_MACHINE_RECIPE:-rust}"
    dir="$WORKDIR/${ENGINE_ID}-machine-recipe"
    name="recipe-${RUN_SLUG}"
    command="$(machine_recipe_command "$recipe")"

    [ -n "$kernel" ] && [ -f "$kernel" ] || {
      echo "set DORYD_MACHINE_KERNEL to a bootable Linux kernel for doryd VM recipe readiness"
      return 1
    }
    [ -n "$rootfs" ] && [ -f "$rootfs" ] || {
      echo "set DORYD_MACHINE_ROOTFS to a rootfs with dory-agent as PID 1 for doryd VM recipe readiness"
      return 1
    }

    mkdir -p "$dir"
    dorydctl machine delete "$name" >/dev/null 2>&1 || true
    trap 'dorydctl machine stop "$name" >/dev/null 2>&1 || true; dorydctl machine delete "$name" >/dev/null 2>&1 || true' RETURN

    dorydctl machine create "$name" --kernel "$kernel" --rootfs "$rootfs" --memory-mb "$memory" --cpus "$cpus" > "$dir/create.json"
    dorydctl machine start "$name" > "$dir/start.json"
    state=""
    for _ in $(seq 1 "${DORYD_MACHINE_READY_POLLS:-60}"); do
      dorydctl machine status "$name" > "$dir/status.json"
      state="$(json_get state < "$dir/status.json")"
      case "$state" in
        running) break ;;
        failed)
          detail="$(json_get lastError < "$dir/status.json")"
          echo "doryd recipe machine failed: ${detail:-unknown failure}"
          return 1
          ;;
      esac
      sleep "${DORYD_MACHINE_READY_INTERVAL:-2}"
    done
    [ "$state" = "running" ] || {
      cat "$dir/status.json" >&2
      echo "doryd recipe machine did not reach running"
      return 1
    }
    dorydctl machine provision "$name" --recipe "$recipe" > "$dir/provision.json"
    dorydctl machine exec "$name" -- /bin/sh -lc "$command" > "$dir/verify.out"
    [ -s "$dir/verify.out" ] || {
      cat "$dir/provision.json" >&2
      echo "doryd recipe verification produced no output"
      return 1
    }
    dorydctl machine stop "$name" > "$dir/stop.json"
    dorydctl machine delete "$name" > "$dir/delete.json"
    trap - RETURN
    return 0
  fi
  return 2
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
  is_dory_engine || return 2
  local hv="${DORY_HV_BIN:-$ROOT/Packages/ContainerizationEngine/.build/debug/dory-hv}"
  [ -x "$hv" ] || { echo "dory-hv not found or executable: $hv"; return 1; }
  "$hv" daxprobe | grep -q "dax coherence passed"
}

test_rosetta() {
  echo "Rosetta machine execution is pending the dory-vmm machine backend; the removed legacy VZ helper path is no longer supported"
  return 2
}

test_guest_agent() {
  is_dory_engine || return 2
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

test_clock_sync() {
  [ "$CURRENT_ENGINE" = "doryd" ] || return 2
  local result_file="$WORKDIR/${ENGINE_ID}-clock-sync.json"
  local guest_raw delta_ms
  # This calls DockerTier.syncAgentClock, the exact typed path HostWakeCoordinator invokes after
  # host wake. The CLI fails unless the running agent attempted and accepted clock_settime.
  dorydctl docker clock-sync > "$result_file"
  python3 - "$result_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
if result.get("attempted") is not True or result.get("synced") is not True or result.get("error"):
    raise SystemExit(f"clock synchronization was not accepted: {result}")
PY
  guest_raw="$(docker_e info --format '{{.SystemTime}}' | tr -d '\r\n')"
  delta_ms="$(python3 - "$guest_raw" <<'PY'
from datetime import datetime
import sys, time

raw = sys.argv[1].strip().strip('"')
if raw.endswith('Z'):
    raw = raw[:-1] + '+00:00'
guest_ns = int(datetime.fromisoformat(raw).timestamp() * 1_000_000_000)
print(abs(time.time_ns() - guest_ns) // 1_000_000)
PY
)"
  [ "$delta_ms" -le "$CLOCK_SYNC_TOLERANCE_MS" ] || {
    echo "clock delta ${delta_ms}ms exceeds tolerance ${CLOCK_SYNC_TOLERANCE_MS}ms"
    return 1
  }
  echo "clock delta ${delta_ms}ms"
}

test_usb() {
  is_dory_engine || return 2
  if ! "$ROOT/scripts/dory" usb ls 2>/dev/null | grep -q "$DORY_USB_TEST_BUSID"; then
    echo "device $DORY_USB_TEST_BUSID not present in 'dory usb ls'" >&2
    return 1
  fi
  local mode="${DORY_USB_MODE:-userAuthorized}"
  "$ROOT/scripts/dory" usb attach "$DORY_USB_TEST_BUSID" --mode "$mode" || return 1
  "$ROOT/scripts/dory" usb detach "$DORY_USB_TEST_BUSID" || return 1
}

test_doryd_launchd() {
  [ "$CURRENT_ENGINE" = "doryd" ] || return 2
  local domain="gui/$(id -u)/dev.dory.doryd"
  launchctl print "$domain" | grep -q 'state = running'
  launchctl print "$domain" | grep -q '"dev.dory.doryd"'
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

  if [ "$CURRENT_ENGINE" = "doryd" ]; then
    run_case "$CURRENT_ENGINE" "doryd launchd MachService loaded" test_doryd_launchd
    test_doryd_launchd >/dev/null 2>&1 || return
  fi

  run_case "$CURRENT_ENGINE" "Docker API ready" wait_for_engine_ready
  wait_for_engine_ready >/dev/null 2>&1 || return

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

  if [ "$RUN_NONNATIVE_ARCH" = "1" ]; then
    run_case "$CURRENT_ENGINE" "linux/$(nonnative_guest_arch) emulation" test_nonnative_arch
    run_case "$CURRENT_ENGINE" "linux/$(nonnative_guest_arch) BuildKit node/npm build" test_nonnative_build
  else
    skip_case "$CURRENT_ENGINE" "linux/$(nonnative_guest_arch) emulation" "disabled"
    skip_case "$CURRENT_ENGINE" "linux/$(nonnative_guest_arch) BuildKit node/npm build" "disabled"
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
    run_case "$CURRENT_ENGINE" "Linux VM machine boot + exec" test_machines
  else
    skip_case "$CURRENT_ENGINE" "Linux VM machine boot + exec" "enable with --machines"
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
    run_case "$CURRENT_ENGINE" "dory-hv low-level DAX mapping probe" test_dax
  else
    skip_case "$CURRENT_ENGINE" "dory-hv low-level DAX mapping probe" "enable with --dax (production host-share DAX remains disabled)"
  fi

  if [ "$RUN_ROSETTA" = "1" ] && [ "$(host_guest_arch)" = "amd64" ]; then
    skip_case "$CURRENT_ENGINE" "Rosetta x86-64 machine execution" "N/A on Intel hosts; amd64 is native"
  elif [ "$RUN_ROSETTA" = "1" ]; then
    run_case "$CURRENT_ENGINE" "Rosetta x86-64 machine execution" test_rosetta
  else
    skip_case "$CURRENT_ENGINE" "Rosetta x86-64 machine execution" "pending dory-vmm Rosetta machine backend"
  fi

  if [ "$RUN_CLOCK_SYNC" = "1" ] && [ "$CURRENT_ENGINE" != "doryd" ]; then
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "typed clock-sync readiness is supported by the doryd engine only"
  elif [ "$RUN_CLOCK_SYNC" = "1" ]; then
    run_case "$CURRENT_ENGINE" "host wake clock sync" test_clock_sync
  else
    skip_case "$CURRENT_ENGINE" "host wake clock sync" "enable with --clock-sync on the doryd engine"
  fi

  if [ "$RUN_USB" = "1" ]; then
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "dory-agent protocol v1 has no guest vhci attach/detach RPC"
  else
    skip_case "$CURRENT_ENGINE" "USB/IP hardware smoke" "enable with --usb and DORY_USB_TEST_BUSID"
  fi

  if [ "$RUN_DEBUG_SHELL" = "1" ]; then
    skip_case "$CURRENT_ENGINE" "debug shell via guest agent" "dory-agent protocol v1 has no namespace-debug RPC"
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
