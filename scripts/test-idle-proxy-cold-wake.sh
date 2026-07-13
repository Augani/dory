#!/bin/bash
# Proves a cold Auto-Idle wake coalesces a client herd into one engine start and serves every client.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-idle-cold-wake.XXXXXX")"
PIDS=""
cleanup() {
  set +e
  for pid in $PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in $PIDS; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cat > "$TMP/fake_engine_server.py" <<'PY'
import os
import signal
import socket
import sys
import threading
import time

path, ready = sys.argv[1:]
time.sleep(0.8)  # Keep every proxy client inside the same cold-wake window.
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(64)
open(ready, "w", encoding="utf-8").write("ready\n")

def stop(_signum, _frame):
    server.close()
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)

def serve(client):
    with client:
        client.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        body = b"OK"
        client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" + body)

while True:
    try:
        client, _ = server.accept()
    except OSError:
        break
    threading.Thread(target=serve, args=(client,), daemon=True).start()
PY

cat > "$TMP/fake-engine" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  start)
    printf 'start\n' >> "$FAKE_ENGINE_STARTS"
    python3 "$FAKE_ENGINE_SERVER" "$FAKE_ENGINE_SOCK" "$FAKE_ENGINE_READY" \
      > "$FAKE_ENGINE_LOG" 2>&1 &
    printf '%s\n' "$!" > "$FAKE_ENGINE_PID"
    ;;
  stop)
    [ ! -s "$FAKE_ENGINE_PID" ] || kill "$(cat "$FAKE_ENGINE_PID")" 2>/dev/null || true
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$TMP/fake-engine"

export FAKE_ENGINE_SERVER="$TMP/fake_engine_server.py"
export FAKE_ENGINE_SOCK="$TMP/engine.sock"
export FAKE_ENGINE_READY="$TMP/engine.ready"
export FAKE_ENGINE_STARTS="$TMP/engine.starts"
export FAKE_ENGINE_PID="$TMP/engine.pid"
export FAKE_ENGINE_LOG="$TMP/engine.log"
: > "$FAKE_ENGINE_STARTS"

DORY_CONFIG="$TMP/config.json" DORY_IDLE_MAX_CONNECTIONS=32 \
  "$ROOT/scripts/dory-idle-proxy" proxy --foreground \
    --listener "$TMP/proxy.sock" \
    --engine-sock "$FAKE_ENGINE_SOCK" \
    --engine-command "$TMP/fake-engine" \
    --idle-seconds 3600 \
    --wake-timeout 8 \
    --state-file "$TMP/state.json" \
    > "$TMP/proxy.log" 2>&1 &
proxy_pid=$!
PIDS="$PIDS $proxy_pid"

python3 - "$TMP/proxy.sock" <<'PY'
import os, sys, time
deadline = time.time() + 5
while time.time() < deadline:
    if os.path.exists(sys.argv[1]):
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit("idle proxy listener did not appear")
PY

python3 - "$TMP/proxy.sock" <<'PY'
import socket
import sys
import threading

path = sys.argv[1]
count = 16
barrier = threading.Barrier(count)
results = [False] * count
errors = [""] * count

def request(index):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(15)
    try:
        barrier.wait(timeout=5)
        client.connect(path)
        client.sendall(b"GET /_ping HTTP/1.1\r\nHost: dory\r\nConnection: close\r\n\r\n")
        client.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        results[index] = b"HTTP/1.1 200 OK" in data and data.endswith(b"OK")
    except Exception as exc:
        errors[index] = repr(exc)
    finally:
        client.close()

threads = [threading.Thread(target=request, args=(index,)) for index in range(count)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join(timeout=20)
if any(thread.is_alive() for thread in threads):
    raise SystemExit("cold-wake clients did not finish within 20 seconds")
if not all(results):
    raise SystemExit(f"cold-wake herd lost clients: results={results!r} errors={errors!r}")
PY

[ "$(wc -l < "$FAKE_ENGINE_STARTS" | tr -d ' ')" = 1 ] \
  || { echo "cold-wake herd invoked engine start more than once" >&2; exit 1; }
python3 - "$TMP/state.json" "$TMP/idle-history.jsonl" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state.get("engine_ready") is True, state
assert state.get("state") in {"awake", "busy"}, state
history = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
assert sum(item.get("state") == "waking" for item in history) == 1, history
assert any(item.get("state") == "awake" for item in history), history
PY

echo "idle proxy cold-wake concurrency: PASS (16 clients, one engine start)"
