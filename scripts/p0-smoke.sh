#!/bin/bash
# P0 release smoke for the Dory Docker-compatible surface.
#
# Requires a running Dory socket. This intentionally fails on any doctor/network/mount/Compose
# regression so it can gate a release candidate after the app bundle has been rebuilt/relaunched.
set -euo pipefail
cd "$(dirname "$0")/.."

DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
DOCKER_BIN="${DORY_DOCKER_BIN:-$(command -v docker || echo docker)}"
PROJECT="dory-p0-smoke-$$"
WORKDIR="$(mktemp -d)"
PORT=""

cleanup() {
  if [ -n "$PORT" ]; then
    "$DOCKER_BIN" -H "unix://$DORY_SOCK" compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

docker_e() {
  "$DOCKER_BIN" -H "unix://$DORY_SOCK" "$@"
}

compose_down() {
  local output status remaining
  if output="$(docker_e compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" down -v --remove-orphans 2>&1)"; then
    [ -z "$output" ] || printf '%s\n' "$output"
    return 0
  fi
  status=$?
  remaining="$(docker_e ps -a --filter "label=com.docker.compose.project=$PROJECT" -q 2>/dev/null || true)"
  if printf '%s\n' "$output" | grep -q 'parsing time ""' && [ -z "$remaining" ]; then
    printf '%s\n' "$output" >&2
    echo "p0-smoke: tolerated Docker Compose empty-time parse bug after cleanup" >&2
    return 0
  fi
  printf '%s\n' "$output" >&2
  return "$status"
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_http() {
  local url="$1" expected="$2"
  for _ in $(seq 1 40); do
    body="$(curl -fsS --max-time 2 "$url" 2>/dev/null || true)"
    [ "$body" = "$expected" ] && return 0
    sleep 0.25
  done
  echo "p0-smoke: timed out waiting for $url" >&2
  return 1
}

[ -S "$DORY_SOCK" ] || { echo "p0-smoke: missing Dory socket at $DORY_SOCK" >&2; exit 1; }

scripts/test-dory-doctor.sh
scripts/dory doctor --json --only socket,api,docker,context,disk,memory,helpers > "$WORKDIR/doctor.json"
scripts/dory network --active --json > "$WORKDIR/network.json"
scripts/dory mount --json > "$WORKDIR/mount.json"

docker_e run --rm alpine:latest true

PORT="$(free_port)"
cat > "$WORKDIR/compose.yaml" <<YAML
services:
  web:
    image: alpine:latest
    command:
      - sh
      - -c
      - |
        while true; do printf 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\ndory-p0-smoke' | nc -l -p 8080; done
    ports:
      - "127.0.0.1:${PORT}:8080"
YAML

docker_e compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" up -d
wait_http "http://127.0.0.1:${PORT}" "dory-p0-smoke"
docker_e compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" ps --format json > "$WORKDIR/compose-ps.json"
compose_down

echo "p0-smoke: PASS"
