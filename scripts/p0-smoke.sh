#!/bin/bash
# P0 release smoke for the Dory Docker-compatible surface.
#
# Requires a running Dory socket. This intentionally fails on any doctor/network/mount/Compose
# regression so it can gate a release candidate after the app bundle has been rebuilt/relaunched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${DORY_P0_IMAGE:-alpine:latest}"

resolve_docker_bin() {
  local candidate resolved
  if [ -n "${DORY_DOCKER_BIN:-}" ]; then
    candidate="$DORY_DOCKER_BIN"
  elif [ -n "${DORY_APP:-}" ]; then
    candidate="${DORY_APP%/}/Contents/Helpers/docker"
    if [ ! -x "$candidate" ]; then
      echo "p0-smoke: DORY_APP has no executable bundled Docker CLI at $candidate" >&2
      return 1
    fi
    printf '%s\n' "$candidate"
    return 0
  else
    candidate="docker"
  fi

  if [[ "$candidate" == */* ]]; then
    resolved="$candidate"
  else
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
  fi
  if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
    echo "p0-smoke: Docker CLI is not executable: $candidate" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

resolve_dory_cli() {
  local candidate="${DORY_CLI_BIN:-}"
  if [ -z "$candidate" ] && [ -n "${DORY_APP:-}" ]; then
    candidate="${DORY_APP%/}/Contents/Helpers/dory"
  fi
  [ -n "$candidate" ] || candidate="scripts/dory"
  if [ ! -x "$candidate" ]; then
    echo "p0-smoke: Dory CLI is not executable: $candidate" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

resolve_dorydctl() {
  local candidate="${DORYDCTL_BIN:-}"
  if [ -z "$candidate" ] && [ -n "${DORY_APP:-}" ]; then
    candidate="${DORY_APP%/}/Contents/Helpers/dorydctl"
  fi
  [ -n "$candidate" ] || candidate="$HOME/.dory/bin/dorydctl"
  if [ ! -x "$candidate" ]; then
    echo "p0-smoke: dorydctl is not executable: $candidate" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

wake_engine_and_capture_status() {
  local status_file="$1" dory_cli="${DORY_CLI_BIN:?DORY_CLI_BIN is required}"
  "$dory_cli" engine wake >/dev/null
  "$dory_cli" engine status --json > "$status_file"
  if ! python3 - "$status_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
if status.get("state") not in {"running", "awake"} and status.get("awake") is not True:
    raise SystemExit(1)
PY
  then
    echo "p0-smoke: dory engine status did not report a running engine after wake" >&2
    return 1
  fi
}

cleanup() {
  if [ "${STOP_WAKE_STARTED:-0}" = "1" ] && [ -n "${DORY_CLI_BIN:-}" ]; then
    "$DORY_CLI_BIN" engine wake >/dev/null 2>&1 || true
  fi
  if [ -n "${PERSISTENT_CONTAINER:-}" ]; then
    docker_e rm -f "$PERSISTENT_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [ -n "$PORT" ]; then
    "$DOCKER_BIN" -H "unix://$DORY_SOCK" compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}

stop_wake_storage_smoke() {
  local running created before after before_label after_label http_status response="$WORKDIR/system-df.json"
  running="$(docker_e ps -q)"
  if [ -n "$running" ]; then
    echo "p0-smoke: refusing stop/wake gate while unrelated containers are running" >&2
    return 1
  fi

  PERSISTENT_CONTAINER="dory-p0-persist-$$"
  created="$(docker_e create --name "$PERSISTENT_CONTAINER" \
    --label "dev.dory.p0-smoke=$PROJECT" \
    "$IMAGE" sh -c 'printf dory-persist >/marker')"
  [ -n "$created" ] || { echo "p0-smoke: persistent container create returned no ID" >&2; return 1; }
  before="$(docker_e inspect --format '{{.Id}}' "$PERSISTENT_CONTAINER")"
  [ -n "$before" ] || { echo "p0-smoke: persistent container inspect returned no ID" >&2; return 1; }
  before_label="$(docker_e inspect --format '{{ index .Config.Labels "dev.dory.p0-smoke" }}' "$PERSISTENT_CONTAINER")"
  [ "$before_label" = "$PROJECT" ] \
    || { echo "p0-smoke: persistent container lost its ownership label before sleep" >&2; return 1; }

  STOP_WAKE_STARTED=1
  "$DORY_CLI_BIN" engine sleep --json > "$WORKDIR/engine-sleep.json"
  wake_engine_and_capture_status "$WORKDIR/engine-wake.json"
  STOP_WAKE_STARTED=0

  after="$(docker_e inspect --format '{{.Id}}' "$PERSISTENT_CONTAINER")"
  [ "$after" = "$before" ] || {
    echo "p0-smoke: stopped container identity changed across engine sleep/wake" >&2
    return 1
  }
  after_label="$(docker_e inspect --format '{{ index .Config.Labels "dev.dory.p0-smoke" }}' "$PERSISTENT_CONTAINER")"
  [ "$after_label" = "$before_label" ] || {
    echo "p0-smoke: stopped container ownership label changed across engine sleep/wake" >&2
    return 1
  }

  http_status="$(curl -sS --max-time 15 --unix-socket "$DORY_SOCK" \
    -o "$response" -w '%{http_code}' http://d/system/df)"
  [ "$http_status" = "200" ] || {
    echo "p0-smoke: Docker /system/df returned HTTP $http_status after stop/wake" >&2
    cat "$response" >&2 || true
    return 1
  }
  python3 - "$response" "$before" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict):
    raise SystemExit("/system/df did not return a JSON object")
containers = payload.get("Containers")
if not isinstance(containers, list):
    raise SystemExit("/system/df did not return its Containers inventory")
expected = sys.argv[2]
if expected not in {item.get("Id") for item in containers if isinstance(item, dict)}:
    raise SystemExit("/system/df omitted the stopped container preserved across sleep/wake")
PY
  docker_e rm "$PERSISTENT_CONTAINER" >/dev/null
  PERSISTENT_CONTAINER=""
}

docker_e() {
  "$DOCKER_BIN" -H "unix://$DORY_SOCK" "$@"
}

compose_down() {
  local output status=0 remaining
  output="$(docker_e compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" down -v --remove-orphans 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    [ -z "$output" ] || printf '%s\n' "$output"
    return 0
  fi
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

repair_subsystem() {
  local target="$1" output
  output="$WORKDIR/repair-$target.json"
  "$DORYDCTL_BIN" network repair "$target" > "$output"
  python3 - "$output" "$target" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("ok") is not True or not payload.get("message"):
    raise SystemExit(f"{sys.argv[2]} repair did not return a successful attributed result")
PY
}

subsystem_recovery_smoke() {
  local hv_log="$HOME/.dory/hv/dory-hv.log" before after=0
  for target in dns domains routes guest-agent docker-api; do
    repair_subsystem "$target"
  done

  before="$(grep -Fc 'manual port reconcile requested' "$hv_log" 2>/dev/null || true)"
  repair_subsystem ports
  for _ in $(seq 1 40); do
    after="$(grep -Fc 'manual port reconcile requested' "$hv_log" 2>/dev/null || true)"
    [ "$after" -gt "$before" ] && break
    sleep 0.1
  done
  [ "$after" -gt "$before" ] || {
    echo "p0-smoke: dory-hv did not acknowledge the manual published-port reconciliation" >&2
    return 1
  }
}

main() {
  cd "$ROOT"
  DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
  DOCKER_BIN="$(resolve_docker_bin)"
  DORY_CLI_BIN="$(resolve_dory_cli)"
  DORYDCTL_BIN="$(resolve_dorydctl)"
  # Keep every nested doctor/compatibility probe on the same release-candidate CLI.
  export DORY_DOCKER_BIN="$DOCKER_BIN" DORY_CLI_BIN
  if [ -n "${DORY_APP:-}" ]; then
    DORY_DOCTOR_BIN="${DORY_APP%/}/Contents/Helpers/dory-doctor"
    [ -x "$DORY_DOCTOR_BIN" ] || { echo "p0-smoke: candidate dory-doctor is missing" >&2; exit 1; }
    export DORY_DOCTOR_BIN
  fi
  PROJECT="dory-p0-smoke-$$"
  WORKDIR="$(mktemp -d)"
  PORT=""
  PERSISTENT_CONTAINER=""
  STOP_WAKE_STARTED=0
  trap cleanup EXIT

  [ -S "$DORY_SOCK" ] || { echo "p0-smoke: missing Dory socket at $DORY_SOCK" >&2; exit 1; }

  scripts/test-dory-doctor.sh
  "$DORY_CLI_BIN" doctor --json --only socket,api,docker,context,disk,memory,helpers > "$WORKDIR/doctor.json"
  "$DORY_CLI_BIN" network --active --json > "$WORKDIR/network.json"
  "$DORY_CLI_BIN" mount --json > "$WORKDIR/mount.json"

  ENGINE_SOCK="${DORY_ENGINE_SOCK:-$HOME/.dory/engine.sock}"
  if [ -S "$ENGINE_SOCK" ]; then
    wake_engine_and_capture_status "$WORKDIR/engine-status.json"
  fi
  "$DORY_CLI_BIN" idle history --json > "$WORKDIR/idle-history.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORKDIR/idle-history.json"
  "$DORY_CLI_BIN" idle status --json > "$WORKDIR/idle-status.json" 2>/dev/null || true

  DORY_SOCK="$DORY_SOCK" scripts/compat-smoke.sh

  docker_e buildx version >/dev/null
  docker_e run --rm "$IMAGE" true

  PORT="$(free_port)"
  cat > "$WORKDIR/compose.yaml" <<YAML
services:
  web:
    image: "$IMAGE"
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
  subsystem_recovery_smoke
  wait_http "http://127.0.0.1:${PORT}" "dory-p0-smoke"
  docker_e compose -p "$PROJECT" -f "$WORKDIR/compose.yaml" ps --format json > "$WORKDIR/compose-ps.json"
  compose_down

  if [ "${DORY_P0_STOP_WAKE:-0}" = "1" ]; then
    stop_wake_storage_smoke
  fi

  echo "p0-smoke: PASS"
}

if [ "${DORY_P0_SMOKE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
