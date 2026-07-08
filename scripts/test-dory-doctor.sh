#!/bin/bash
# Fast checks for the P0 diagnostics CLI. These intentionally do not require a
# running Dory engine; engine-backed probes are covered by readiness scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
PIDS_TO_CLEAN=()

cleanup() {
  if [ "${#PIDS_TO_CLEAN[@]}" -gt 0 ]; then
    for pid in "${PIDS_TO_CLEAN[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      fi
    done
  fi
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

export HOME="$TMP_HOME"
export DORY_CONFIG="$TMP_HOME/config.json"
export DORY_SOCK="$TMP_HOME/missing-dory.sock"

python3 -m py_compile scripts/dory-doctor
python3 -m py_compile scripts/dory-idle-proxy
bash -n scripts/dory
bash -n scripts/p0-smoke.sh

scripts/dory agent guide --json | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
assert data["schema"] == "dev.dory.agent.guide"
assert data["version"] == 1
assert data["defaults"]["socket"] == os.environ["DORY_SOCK"]
commands = {item["id"]: item for item in data["commands"]}
assert commands["doctor"]["status"] == "available"
assert commands["doctor"]["json"] is True
assert commands["repair"]["dryRun"] is True
assert commands["sandbox"]["status"] == "planned"
assert commands["wait"]["invoke"].startswith("dory wait")
assert data["recommendedRecoveryLoop"]
'

scripts/dory agent guide --text | grep -q "Dory agent guide v1"

scripts/dory-doctor mode show --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["runtimeMode"] == "manual"
assert data["idle"]["sleepAfterMinutes"] == 15
'

scripts/dory-doctor mode auto-idle --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["runtimeMode"] == "auto-idle"
'

scripts/dory-doctor idle status --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["mode"] == "auto-idle"
assert data["auto_idle_enabled"] is True
assert data["can_sleep"] is False
assert data["blockers"]
assert data["proxy_state"]["available"] is False
assert data["proxy_state"]["state"] == "unknown"
'

cat > "$TMP_HOME/idle-state.json" <<'JSON'
{
  "state": "idle-cooling-down",
  "detail": "waiting 42s before sleep",
  "updated_at": "2026-07-06T00:00:00Z",
  "active_connections": 0,
  "engine_ready": true
}
JSON

DORY_IDLE_STATE="$TMP_HOME/idle-state.json" scripts/dory-doctor idle status --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["proxy_state"]["available"] is True
assert data["proxy_state"]["state"] == "idle-cooling-down"
assert data["proxy_state"]["detail"] == "waiting 42s before sleep"
'

scripts/dory-doctor disk --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert "host" in data
assert "docker" in data
assert data["docker"]["available"] is False
'

mkdir -p "$TMP_HOME/.dory"
python3 - "$TMP_HOME/.dory/engine.log" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"0123456789" * 10)
PY

scripts/dory-doctor cleanup --json --log-max-bytes 10 | python3 -c '
import json, sys
data = json.load(sys.stdin)
logs = [item for item in data["actions"] if item["target"] == "logs"][0]
assert logs["bytes_reclaimable"] == 90
assert logs["applied"] is False
assert any(item["target"] == "docker" and item["status"] == "skip" for item in data["actions"])
'

scripts/dory-doctor cleanup --json --apply --log-max-bytes 10 | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
logs = [item for item in data["actions"] if item["target"] == "logs"][0]
assert logs["applied"] is True
assert os.path.getsize(os.path.expanduser("~/.dory/engine.log")) == 10
'

scripts/dory-doctor network --save-probe internal=registry.internal.example:5000 --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["saved"]["name"] == "internal"
assert data["saved"]["host"] == "registry.internal.example"
assert data["saved"]["port"] == 5000
'

scripts/dory-doctor network --list-probes --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
probes = {(item["host"], item["port"]) for item in data["probes"]}
assert ("registry-1.docker.io", 443) in probes
assert ("registry.internal.example", 5000) in probes
'

set +e
bad_probe="$(scripts/dory-doctor network --save-probe 'https://user:secret@registry.internal.example' 2>&1)"
bad_rc=$?
set -e
test "$bad_rc" -eq 2
printf '%s' "$bad_probe" | grep -q "must not contain credentials"

scripts/dory-doctor network --remove-probe registry.internal.example:5000 --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["removed"] is True
'

set +e
routes_json="$(scripts/dory-doctor routes --json)"
routes_rc=$?
set -e
test "$routes_rc" -eq 1
printf '%s' "$routes_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["error"]
assert data["ports"] == []
'

set +e
doctor_json="$(scripts/dory-doctor doctor --json --only socket,api)"
doctor_rc=$?
set -e
test "$doctor_rc" -eq 1
printf '%s' "$doctor_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
codes = {item["code"] for item in data["results"]}
assert "socket.missing" in codes
assert "socket.unreachable" in codes
'

set +e
repair_json="$(scripts/dory-doctor repair all --json)"
repair_rc=$?
set -e
test "$repair_rc" -eq 1
printf '%s' "$repair_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
targets = {item["target"] for item in data["actions"]}
assert {"socket", "context", "dns", "routes", "ports", "domains", "dockerd", "guest-agent"} <= targets
assert any(item["target"] == "guest-agent" and item["status"] == "skip" for item in data["actions"])
'

set +e
cat > "$TMP_HOME/.dory/engine.log" <<'LOG'
Authorization: Bearer secret-token
Proxy-Authorization: Basic abc123
password=supersecret
LOG
bundle_json="$(DORY_TOKEN=supersecret scripts/dory-doctor doctor --json --only socket --bundle "$TMP_HOME/dory-diagnostics.zip")"
bundle_rc=$?
set -e
test "$bundle_rc" -eq 1
printf '%s' "$bundle_json" | python3 -c '
import json, os, sys, zipfile
data = json.load(sys.stdin)
assert os.path.exists(data["bundle"])
assert data["bundle"].endswith("dory-diagnostics.zip")
with zipfile.ZipFile(data["bundle"]) as zf:
    text = zf.read("doctor.json").decode()
    log = zf.read("logs/engine.log").decode()
assert "supersecret" not in text
assert "supersecret" not in log
assert "secret-token" not in log
assert "[redacted]" in text
assert "[redacted]" in log
'

scripts/dory help | grep -q "dory doctor"
scripts/dory help | grep -q "dory idle proxy"
scripts/dory help | grep -q "dory idle proxy-status"
scripts/dory help | grep -q "dory cleanup"
scripts/dory help | grep -q "dory compat"
scripts/dory help | grep -q "dory agent guide"

# Compatibility center: every registered tool is checked and every non-pass carries an action;
# runs without an engine (skips/warns/fails, never crashes). `compat` exits 1 when a tool fails,
# which is expected here, so capture first rather than piping under pipefail.
compat_json="$(scripts/dory compat --json || true)"
printf '%s' "$compat_json" | python3 -c '
import json, sys
results = json.load(sys.stdin)["results"]
checked = {r["id"].split(".")[1] for r in results}
required = {"docker", "compose", "testcontainers", "act", "kubernetes", "vscode", "cursor", "supabase", "localstack"}
missing = required - checked
assert not missing, f"compat did not check: {sorted(missing)}"
for r in results:
    assert r["status"] in {"pass", "warn", "fail", "skip"}, r
    if r["status"] in {"fail", "warn"}:
        assert r.get("action") or r.get("detail"), r
'

# Every recipe ships a verification command (Track 4 exit criterion).
scripts/dory compat --recipe --json | python3 -c '
import json, sys
tools = json.load(sys.stdin)["tools"]
assert tools, "no recipes"
for name, recipe in tools.items():
    assert recipe.get("verify"), f"{name} has no verification command"
'

scripts/dory compat --recipe testcontainers | grep -q "Verify:"
set +e
scripts/dory compat --recipe no-such-tool >/dev/null 2>&1
compat_rc=$?
set -e
[ "$compat_rc" = "2" ] || { echo "unknown compat recipe should exit 2, got $compat_rc"; exit 1; }

# Log caps (Track 5 P0): the always-on proxy caps live O_APPEND logs in place (truncate), which is
# the only safe operation on a file another process is appending to; keep-tail rotation is the
# writers' job (they run when the log is closed), verified via the doctor disk check below.
python3 - <<'PY'
import importlib.machinery, importlib.util, tempfile
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("dip", "scripts/dory-idle-proxy")
dip = importlib.util.module_from_spec(importlib.util.spec_from_loader("dip", loader))
loader.exec_module(dip)
d = Path(tempfile.mkdtemp())
live = d / "engine.log"
live.write_bytes(b"x" * 5000)
assert dip.cap_log_inplace(live, 1000) is True, "cap should truncate a live over-cap log"
assert live.stat().st_size == 0, "cap did not truncate in place"
assert dip.cap_log_inplace(live, 1000) is False, "cap must no-op under the hard cap"
# cap_dory_logs globs *.log / *.err.log in the state dir and caps each over the hard cap.
(d / "engine.log").write_bytes(b"a" * 5000)
(d / "idle-proxy.err.log").write_bytes(b"b" * 5000)
assert dip.cap_dory_logs(d, 1000) == 2, "cap_dory_logs should cap both oversized logs"
PY

mkdir -p "$TMP_HOME/.dory"
head -c 200000 /dev/zero | tr '\0' 'x' > "$TMP_HOME/.dory/engine.log"
DORY_LOG_HARD_MAX_BYTES=1000 scripts/dory disk --json | python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["state"]["largest_log"]["bytes"] >= 200000, report["state"]
'
# `doctor --only disk` exits non-zero when the host disk is critically low, so capture before piping.
disk_json="$(DORY_LOG_HARD_MAX_BYTES=1000 scripts/dory-doctor doctor --json --only disk 2>/dev/null || true)"
printf '%s' "$disk_json" | python3 -c '
import json, sys
results = json.load(sys.stdin)["results"]
log_check = [r for r in results if r["id"] == "disk.dory_logs"]
assert log_check, "disk.dory_logs check missing"
assert log_check[0]["status"] == "warn", log_check[0]
assert log_check[0]["code"] == "disk.dory_log_uncapped", log_check[0]
'
rm -f "$TMP_HOME/.dory/engine.log"

# Auto-Idle policy CLI (Track 7): `dory idle set` writes idle.* keys, preserves runtimeMode, and
# `idle status --json` echoes the full policy for the Settings UI. Isolated config so it does not
# perturb the idle-proxy tests below.
IDLE_CFG="$TMP_HOME/idle-policy-config.json"
DORY_CONFIG="$IDLE_CFG" scripts/dory mode auto-idle >/dev/null
DORY_CONFIG="$IDLE_CFG" scripts/dory idle set sleepAfterMinutes 30 >/dev/null
DORY_CONFIG="$IDLE_CFG" scripts/dory idle set keepPublishedPortsAwake off >/dev/null
DORY_CONFIG="$IDLE_CFG" scripts/dory idle status --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["mode"] == "auto-idle", data["mode"]
policy = data.get("policy") or {}
assert policy.get("sleepAfterMinutes") == 30, policy
assert policy.get("keepPublishedPortsAwake") is False, policy
assert policy.get("keepKubernetesAwake") is True, policy
'
set +e
DORY_CONFIG="$IDLE_CFG" scripts/dory idle set bogusKey 5 >/dev/null 2>&1
idle_set_rc=$?
set -e
[ "$idle_set_rc" = "2" ] || { echo "unknown idle key should exit 2, got $idle_set_rc"; exit 1; }

# Proxy inspector (Track 2 P1): a host proxy that Docker is not configured to use warns with an
# actionable fix, and proxy-URL credentials are redacted from the output.
HTTPS_PROXY="http://user:secretpw@proxy.corp.test:8080" \
  DORY_SOCK=/tmp/dory-no-such-proxy.sock scripts/dory-doctor doctor --json --only proxy | python3 -c '
import json, sys
results = json.load(sys.stdin)["results"]
proxy = [r for r in results if r["id"] == "network.proxy"]
assert proxy, "network.proxy check missing"
assert proxy[0]["status"] == "warn", proxy[0]
assert proxy[0]["code"] == "network.proxy_not_propagated", proxy[0]
assert "secretpw" not in json.dumps(proxy[0]), "proxy credentials leaked in output"
'

# LAN access controls (Track 2 P1): default is localhost-only (pass); `dory network --lan-visible on`
# flips the check to a clear warn (no silent exposure); a bad value exits 2.
LAN_CFG="$TMP_HOME/lan-config.json"
DORY_CONFIG="$LAN_CFG" DORY_SOCK=/tmp/dory-no-such-lan.sock scripts/dory-doctor doctor --json --only exposure | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["results"] if x["id"] == "network.lan_exposure"][0]
assert r["status"] == "pass" and r["code"] == "network.lan_localhost_only", r
'
DORY_CONFIG="$LAN_CFG" scripts/dory network --lan-visible on >/dev/null
DORY_CONFIG="$LAN_CFG" DORY_SOCK=/tmp/dory-no-such-lan.sock scripts/dory-doctor doctor --json --only exposure | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["results"] if x["id"] == "network.lan_exposure"][0]
assert r["status"] == "warn" and r["code"] == "network.lan_exposed", r
'
python3 -c 'import json; assert json.load(open("'"$LAN_CFG"'"))["network"]["lanVisible"] is True'
set +e
DORY_CONFIG="$LAN_CFG" scripts/dory network --lan-visible maybe >/dev/null 2>&1
lan_rc=$?
set -e
[ "$lan_rc" = "2" ] || { echo "bad --lan-visible value should exit 2, got $lan_rc"; exit 1; }

# File-sharing dashboard + file-lock probe (Track 3 P1): `dory mount --json` shows the active share +
# safe policy; the file-lock probe registers (skips without a live engine).
# `dory mount` exits non-zero when the socket is absent, so capture before piping under pipefail.
mount_json="$(DORY_SOCK=/tmp/dory-no-such-mount.sock scripts/dory mount --json 2>/dev/null || true)"
printf '%s' "$mount_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["shares"], "mount dashboard missing shares"
share = d["shares"][0]
assert share["mode"] == "rw" and share["policy"] == "safe", share
assert d.get("policy_note"), "missing policy note"
ids = {r["id"]: r for r in d["results"]}
assert "mount.lock" in ids and ids["mount.lock"]["status"] == "skip", ids.get("mount.lock")
'

# Last-known-good doctor diff: a healthy run saves the baseline; a later regression is reported and
# a failing run never overwrites the good baseline.
python3 - <<'PY'
import importlib.machinery, importlib.util, os, sys, tempfile
loader = importlib.machinery.SourceFileLoader("dd", "scripts/dory-doctor")
dd = importlib.util.module_from_spec(importlib.util.spec_from_loader("dd", loader))
sys.modules["dd"] = dd
loader.exec_module(dd)
os.environ["DORY_LAST_GOOD"] = os.path.join(tempfile.mkdtemp(), "lg.json")
CR = dd.CheckResult
dd.save_last_good([CR("socket.exists", "pass", "socket.ok", "Socket", "ok"),
                   CR("network.proxy", "pass", "network.proxy_ok", "Proxy", "ok")])
diff = dd.diff_last_good([CR("socket.exists", "pass", "socket.ok", "Socket", "ok"),
                          CR("network.proxy", "fail", "network.proxy_x", "Proxy", "broke")])
assert any(r["id"] == "network.proxy" and r["to"] == "fail" for r in diff["regressions"]), diff
dd.save_last_good([CR("network.proxy", "fail", "x", "Proxy", "broke")])
assert dd.load_last_good()["checks"]["network.proxy"]["status"] == "pass", "fail run overwrote baseline"
PY

# Incident timeline (Track 6): `dory repair --apply` records an incident; `dory incidents --json`
# reads it newest-first at 0600; a healthy `repair all --apply` records only what it actually applied.
INC_LOG="$TMP_HOME/incidents-test.jsonl"
DORY_INCIDENTS="$INC_LOG" scripts/dory incidents --json | python3 -c '
import json, sys
assert json.load(sys.stdin)["incidents"] == [], "expected empty incident timeline"
'
DORY_INCIDENTS="$INC_LOG" DORY_SOCK=/tmp/dory-no-such-sock.sock scripts/dory repair socket --apply >/dev/null 2>&1 || true
DORY_INCIDENTS="$INC_LOG" scripts/dory incidents --json | python3 -c '
import json, sys
inc = json.load(sys.stdin)["incidents"]
assert inc, "repair --apply should record an incident"
assert inc[0]["type"] == "repair", inc[0]
assert "socket" in (inc[0].get("detail") or ""), inc[0]
'
inc_perm="$(stat -f "%Lp" "$INC_LOG")"
[ "$inc_perm" = "600" ] || { echo "incidents perms=$inc_perm (want 600)"; exit 1; }

# Concurrent record_incident calls must all land as whole, valid JSON lines (flock + O_APPEND),
# never interleaved or lost.
python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, sys, tempfile, threading
loader = importlib.machinery.SourceFileLoader("dd", "scripts/dory-doctor")
dd = importlib.util.module_from_spec(importlib.util.spec_from_loader("dd", loader))
sys.modules["dd"] = dd
loader.exec_module(dd)
path = os.path.join(tempfile.mkdtemp(), "incidents.jsonl")
os.environ["DORY_INCIDENTS"] = path
threads = [threading.Thread(target=dd.record_incident, args=("test", f"line-{i}")) for i in range(40)]
for t in threads:
    t.start()
for t in threads:
    t.join()
lines = [line for line in open(path, encoding="utf-8").read().splitlines() if line.strip()]
assert len(lines) == 40, f"expected 40 incident lines, got {len(lines)}"
for line in lines:
    json.loads(line)
PY

# Memory inspector + guest disk (Track 5 P1): footprint breaks host RSS into engine/app roles;
# the guest disk probe is active-only and must skip cleanly in the default passive run.
# `--only memory,disk` exits non-zero when the host disk is critically low; capture before piping.
memdisk_json="$(scripts/dory-doctor doctor --json --only memory,disk 2>/dev/null || true)"
printf '%s' "$memdisk_json" | python3 -c '
import json, sys
results = json.load(sys.stdin)["results"]
mem = [r for r in results if r["id"] == "memory.footprint"]
assert mem, "memory.footprint check missing"
data = mem[0].get("data", {})
assert "engine_rss_bytes" in data and "app_rss_bytes" in data, data
guest = [r for r in results if r["id"] == "disk.guest"]
assert guest and guest[0]["status"] == "skip", "guest disk should skip passively"
assert guest[0]["code"] == "disk.active_probe_skipped", guest[0]
'

scripts/dory-idle-proxy launch-agent print | python3 -c '
import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
assert data["Label"] == "dev.dory.idle-proxy"
assert data["RunAtLoad"] is True
assert data["KeepAlive"] is True
assert data["ProgramArguments"][-2:] == ["proxy", "--foreground"]
'

scripts/dory idle launch-agent print | python3 -c '
import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
assert data["Label"] == "dev.dory.idle-proxy"
'

DORY_IDLE_STATE="$TMP_HOME/idle-state.json" scripts/dory idle proxy-status --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["available"] is True
assert data["state"] == "idle-cooling-down"
'

cat > "$TMP_HOME/fake_engine_server.py" <<'PY'
import os
import socket
import sys

sock_path, ready_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(16)
with open(ready_path, "w", encoding="utf-8") as handle:
    handle.write("ready")

while True:
    conn, _ = server.accept()
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    if b"GET /_ping " in data:
        body = b"OK"
        conn.sendall(
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Length: 2\r\n"
            b"Connection: close\r\n"
            b"\r\n" + body
        )
    elif b"GET /containers/json" in data:
        body = b"[]"
        conn.sendall(
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: 2\r\n"
            b"Connection: close\r\n"
            b"\r\n" + body
        )
    else:
        body = b'{"ok":true}'
        conn.sendall(
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: %d\r\n"
            b"Connection: close\r\n"
            b"\r\n" % len(body) + body
        )
    conn.close()
PY

cat > "$TMP_HOME/fake-engine" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  start)
    echo start >> "$FAKE_ENGINE_STARTS"
    python3 "$FAKE_ENGINE_SERVER" "$FAKE_ENGINE_SOCK" "$FAKE_ENGINE_READY" > "$FAKE_ENGINE_LOG" 2>&1 &
    echo "$!" > "$FAKE_ENGINE_PID"
    ;;
  stop)
    if [ -s "$FAKE_ENGINE_PID" ]; then
      kill "$(cat "$FAKE_ENGINE_PID")" 2>/dev/null || true
    fi
    ;;
  *)
    exit 64
    ;;
esac
SH
chmod +x "$TMP_HOME/fake-engine"

export FAKE_ENGINE_SERVER="$TMP_HOME/fake_engine_server.py"
export FAKE_ENGINE_SOCK="$TMP_HOME/engine.sock"
export FAKE_ENGINE_READY="$TMP_HOME/fake-engine.ready"
export FAKE_ENGINE_STARTS="$TMP_HOME/fake-engine.starts"
export FAKE_ENGINE_PID="$TMP_HOME/fake-engine.pid"
export FAKE_ENGINE_LOG="$TMP_HOME/fake-engine.log"

DORY_CONFIG="$TMP_HOME/config.json" scripts/dory-idle-proxy proxy \
  --foreground \
  --listener "$TMP_HOME/proxy.sock" \
  --engine-sock "$FAKE_ENGINE_SOCK" \
  --engine-command "$TMP_HOME/fake-engine" \
  --idle-seconds 3600 \
  --wake-timeout 5 \
  --state-file "$TMP_HOME/proxy-state.json" \
  > "$TMP_HOME/proxy.log" 2>&1 &
proxy_pid=$!
PIDS_TO_CLEAN+=("$proxy_pid")

python3 - "$TMP_HOME/proxy.sock" "$TMP_HOME/proxy.log" <<'PY'
import os
import sys
import time

sock_path, log_path = sys.argv[1], sys.argv[2]
deadline = time.time() + 5
while time.time() < deadline:
    if os.path.exists(sock_path):
        raise SystemExit(0)
    time.sleep(0.05)

try:
    log = open(log_path, encoding="utf-8").read()
except FileNotFoundError:
    log = ""
raise SystemExit(f"proxy socket was not created; log:\n{log}")
PY

proxy_response="$(python3 - "$TMP_HOME/proxy.sock" <<'PY'
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(sys.argv[1])
client.sendall(b"GET /_ping HTTP/1.1\r\nHost: dory\r\nConnection: close\r\n\r\n")
client.shutdown(socket.SHUT_WR)
chunks = []
while True:
    try:
        chunk = client.recv(4096)
    except TimeoutError:
        break
    if not chunk:
        break
    chunks.append(chunk)
    if b"\r\n\r\nOK" in b"".join(chunks):
        break
raw = b"".join(chunks)
if not raw:
    raise SystemExit("proxy returned no response")
print(raw.decode("iso-8859-1"))
PY
)"
printf '%s' "$proxy_response" | grep -q "HTTP/1.1 200 OK"
printf '%s' "$proxy_response" | grep -q "OK"
grep -q "start" "$FAKE_ENGINE_STARTS"
test -S "$FAKE_ENGINE_SOCK"

python3 - "$TMP_HOME/proxy-state.json" <<'PY'
import json
import sys
import time

state_path = sys.argv[1]
deadline = time.time() + 5
last = {}
while time.time() < deadline:
    try:
        last = json.load(open(state_path, encoding="utf-8"))
    except FileNotFoundError:
        last = {}
    if last.get("state") in {"awake", "busy"} and last.get("engine_ready") is True:
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(f"proxy did not publish an awake/busy state: {last!r}")
PY

# --- Auto-Idle: incident history records genuine transitions (not every refresh) ---
python3 - "$TMP_HOME/idle-history.jsonl" <<'PY'
import json
import sys
import time

hist = sys.argv[1]
deadline = time.time() + 5
states: list[str] = []
while time.time() < deadline:
    try:
        lines = [line for line in open(hist, encoding="utf-8").read().splitlines() if line.strip()]
    except FileNotFoundError:
        lines = []
    states = [json.loads(line).get("state") for line in lines]
    if "waking" in states and "awake" in states:
        break
    time.sleep(0.05)
if "waking" not in states or "awake" not in states:
    raise SystemExit(f"history missing wake transitions: {states!r}")
for previous, current in zip(states, states[1:]):
    if previous == current:
        raise SystemExit(f"history recorded a non-transition: {states!r}")
PY

history_perm="$(stat -f '%Lp' "$TMP_HOME/idle-history.jsonl")"
[ "$history_perm" = "600" ] || { echo "idle-history.jsonl perms=$history_perm (want 600)"; exit 1; }

scripts/dory-idle-proxy history --state-file "$TMP_HOME/proxy-state.json" --json | grep -q '"state": "awake"'

# --- Auto-Idle: concurrent clients are all served (slot semaphore does not drop them) ---
python3 - "$TMP_HOME/proxy.sock" <<'PY'
import socket
import sys
import threading

sock_path = sys.argv[1]
results: list[bool] = []
lock = threading.Lock()


def one(_index: int) -> None:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    try:
        client.connect(sock_path)
        client.sendall(b"GET /_ping HTTP/1.1\r\nHost: dory\r\nConnection: close\r\n\r\n")
        client.shutdown(socket.SHUT_WR)
        buf = b""
        while True:
            try:
                chunk = client.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
        with lock:
            results.append(b"200 OK" in buf)
    finally:
        client.close()


threads = [threading.Thread(target=one, args=(index,)) for index in range(8)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
if len(results) != 8 or not all(results):
    raise SystemExit(f"concurrent clients failed: {results!r}")
PY

# --- Auto-Idle: coexistence — proxy defers to the app that owns the socket, never steals it ---
APP_SOCK="$TMP_HOME/app-owned.sock"
APP_READY="$TMP_HOME/app.ready"
python3 "$TMP_HOME/fake_engine_server.py" "$APP_SOCK" "$APP_READY" > "$TMP_HOME/app.log" 2>&1 &
app_pid=$!
PIDS_TO_CLEAN+=("$app_pid")

python3 - "$APP_READY" <<'PY'
import os
import sys
import time

deadline = time.time() + 5
while time.time() < deadline:
    if os.path.exists(sys.argv[1]):
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit("stand-in app socket never became ready")
PY

app_inode="$(stat -f '%i' "$APP_SOCK")"

scripts/dory-idle-proxy proxy \
  --foreground \
  --listener "$APP_SOCK" \
  --engine-sock "$FAKE_ENGINE_SOCK" \
  --engine-command "$TMP_HOME/fake-engine" \
  --idle-seconds 3600 \
  --wake-timeout 5 \
  --state-file "$TMP_HOME/coexist-state.json" \
  > "$TMP_HOME/coexist.log" 2>&1 &
coexist_pid=$!
PIDS_TO_CLEAN+=("$coexist_pid")

python3 - "$TMP_HOME/coexist-state.json" <<'PY'
import json
import sys
import time

state_path = sys.argv[1]
deadline = time.time() + 5
last: dict = {}
while time.time() < deadline:
    try:
        last = json.load(open(state_path, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        last = {}
    if last.get("state") == "deferred":
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(f"proxy did not defer to the app: {last!r}")
PY

now_inode="$(stat -f '%i' "$APP_SOCK")"
[ "$app_inode" = "$now_inode" ] || { echo "proxy stole the app socket (inode $app_inode -> $now_inode)"; exit 1; }

python3 - "$APP_SOCK" <<'PY'
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(sys.argv[1])
client.sendall(b"GET /_ping HTTP/1.1\r\nHost: dory\r\nConnection: close\r\n\r\n")
client.shutdown(socket.SHUT_WR)
buf = b""
while True:
    try:
        chunk = client.recv(4096)
    except TimeoutError:
        break
    if not chunk:
        break
    buf += chunk
if b"200 OK" not in buf:
    raise SystemExit("stand-in app socket stopped answering after the proxy deferred")
PY

kill "$coexist_pid" 2>/dev/null || true
