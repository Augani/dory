#!/bin/bash
# Physical exact-candidate negative/positive qualification for the supported Dory sandbox boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DORY_BIN="${DORY_SANDBOX_GATE_DORY:-$(command -v dory || true)}"
WORKROOT="${DORY_SANDBOX_GATE_WORKROOT:-$HOME/.dory-sandbox-gate}"
ALLOWED_DESTINATION="${DORY_SANDBOX_GATE_ALLOWED_NETWORK:-1.1.1.1:443}"

usage() {
  cat <<EOF
Usage: scripts/sandbox-security-gate.sh [--dory PATH] [--workroot DIR] [--allowed-network HOST:PORT]

Runs destructive tests only against uniquely named sandbox VMs owned by this invocation. A real
physical Dory machine runtime and external connectivity to the allowed destination are required.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dory) DORY_BIN="${2:?--dory requires a path}"; shift 2 ;;
    --workroot) WORKROOT="${2:?--workroot requires a path}"; shift 2 ;;
    --allowed-network) ALLOWED_DESTINATION="${2:?--allowed-network requires HOST:PORT}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sandbox-security-gate: unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$DORY_BIN" ] && [ ! -L "$DORY_BIN" ] && [ -x "$DORY_BIN" ] \
  || { echo "sandbox-security-gate: Dory CLI is not an exact regular executable: $DORY_BIN" >&2; exit 2; }
case "$WORKROOT" in /*) ;; *) echo "sandbox-security-gate: --workroot must be absolute" >&2; exit 2 ;; esac
case "$WORKROOT" in /|"$HOME"|"$ROOT") echo "sandbox-security-gate: unsafe --workroot: $WORKROOT" >&2; exit 2 ;; esac
[ ! -L "$WORKROOT" ] \
  || { echo "sandbox-security-gate: --workroot must not be a symlink" >&2; exit 2; }
python3 - "$ALLOWED_DESTINATION" <<'PY'
import ipaddress
import re
import sys

value = sys.argv[1]
if value.count(":") != 1:
    raise SystemExit("sandbox-security-gate: --allowed-network must be HOST:PORT")
host, raw_port = value.rsplit(":", 1)
try:
    port = int(raw_port)
except ValueError:
    raise SystemExit("sandbox-security-gate: allowed network port is invalid")
if not 1 <= port <= 65535:
    raise SystemExit("sandbox-security-gate: allowed network port is outside 1...65535")
try:
    ipaddress.ip_address(host)
except ValueError:
    if re.fullmatch(r"(?=.{1,253}\Z)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host) is None:
        raise SystemExit("sandbox-security-gate: allowed network host is invalid")
PY

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
WORKDIR="$WORKROOT/$RUN_ID"
INPUT="$WORKDIR/read-only-input"
EVIDENCE="$WORKDIR/evidence"
BASE="dory-sandbox-gate-base-$RUN_ID"
ROLLBACK="dory-sandbox-gate-rollback-$RUN_ID"
TTL="dory-sandbox-gate-ttl-$RUN_ID"
mkdir -p "$INPUT" "$EVIDENCE"
[ -d "$WORKROOT" ] && [ ! -L "$WORKROOT" ] && [ -d "$WORKDIR" ] && [ ! -L "$WORKDIR" ] \
  || { echo "sandbox-security-gate: workroot changed while preparing evidence" >&2; exit 2; }
printf 'host-sentinel\n' > "$INPUT/sentinel.txt"
export DORY_SANDBOX_GATE_SECRET="dory-secret-$RUN_ID"

cleanup() {
  "$DORY_BIN" sandbox kill "$BASE" >/dev/null 2>&1 || true
  "$DORY_BIN" sandbox kill "$ROLLBACK" >/dev/null 2>&1 || true
  "$DORY_BIN" sandbox kill "$TTL" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$DORY_BIN" sandbox run --json --keep --name "$BASE" \
  --mount "$INPUT:/input" --network none --secret-env DORY_SANDBOX_GATE_SECRET \
  --memory-mb 1024 --cpus 1 --disk-mb 64 --processes 32 --open-files 64 \
  --wall-time-seconds 45 -- /bin/sh -eu -c '
test "$(id -u)" -ne 0
test "$(cat /input/sentinel.txt)" = host-sentinel
! touch /input/write-must-fail
test "$DORY_SANDBOX_GATE_SECRET" != ""
test -z "${SSH_AUTH_SOCK:-}"
test "$(ulimit -n)" -eq 64
test "$(ulimit -u)" -le 32
! nslookup example.com >/dev/null 2>&1
! nc -z -w 1 127.0.0.1 80 >/dev/null 2>&1
! nc -z -w 1 192.168.127.1 80 >/dev/null 2>&1
! nc -z -w 1 169.254.169.254 80 >/dev/null 2>&1
! (dd if=/dev/zero of="$DORY_SCRATCH/over-cap" bs=1M count=80 >/dev/null 2>&1)
printf SANDBOX-NEGATIVE-PASS
' > "$EVIDENCE/negative.json"

python3 - "$EVIDENCE/negative.json" "$HOME/.dory/sandboxes/$BASE.json" "$DORY_SANDBOX_GATE_SECRET" <<'PY'
import json, pathlib, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
manifest_path = pathlib.Path(sys.argv[2])
secret = sys.argv[3]
manifest_text = manifest_path.read_text(encoding="utf-8")
manifest = json.loads(manifest_text)
if result.get("exitCode") != 0 or result.get("exec", {}).get("stdout") != "SANDBOX-NEGATIVE-PASS":
    raise SystemExit(f"negative sandbox execution failed: {result!r}")
identity = manifest.get("identity", {})
if identity.get("elevated") is not False or identity.get("uid") == 0:
    raise SystemExit(f"sandbox identity is not unprivileged: {manifest!r}")
mounts = manifest.get("mounts")
if not isinstance(mounts, list) or len(mounts) != 1 or mounts[0].get("readOnly") is not True:
    raise SystemExit(f"sandbox mount is not read-only: {manifest!r}")
network = manifest.get("network", {})
if network.get("mode") != "none" or network.get("egressFilterEnforced") is not True:
    raise SystemExit(f"sandbox network-none authority is invalid: {manifest!r}")
if manifest.get("credentials", {}).get("secretEnvironmentNames") != ["DORY_SANDBOX_GATE_SECRET"]:
    raise SystemExit(f"sandbox secret reference is absent: {manifest!r}")
if secret in manifest_text:
    raise SystemExit("sandbox manifest leaked the opaque secret value")
if manifest.get("command", {}).get("argumentsPersisted") is not False:
    raise SystemExit(f"sandbox persisted command arguments: {manifest!r}")
expected_limits = {"cpus":1,"memoryMB":1024,"diskMB":64,"processes":32,"openFiles":64,"wallTimeSeconds":45}
if manifest.get("limits") != expected_limits:
    raise SystemExit(f"sandbox limits differ from the requested contract: {manifest!r}")
PY
[ ! -e "$INPUT/write-must-fail" ] || { echo "sandbox-security-gate: read-only mount was modified" >&2; exit 1; }

allowed_host="${ALLOWED_DESTINATION%:*}"
allowed_port="${ALLOWED_DESTINATION##*:}"
"$DORY_BIN" sandbox run --json --network outbound --allow-network "$ALLOWED_DESTINATION" \
  --memory-mb 1024 --cpus 1 --disk-mb 32 --wall-time-seconds 30 -- \
  /bin/sh -eu -c '
host="$1"; port="$2"
nslookup example.com >/dev/null
nc -z -w 10 "$host" "$port"
! nc -z -w 1 127.0.0.1 80 >/dev/null 2>&1
! nc -z -w 1 169.254.169.254 80 >/dev/null 2>&1
printf SANDBOX-OUTBOUND-PASS
' sh "$allowed_host" "$allowed_port" > "$EVIDENCE/outbound.json"

set +e
"$DORY_BIN" sandbox run --json --network none --memory-mb 1024 --cpus 1 --disk-mb 32 \
  --wall-time-seconds 1 -- /bin/sleep 30 > "$EVIDENCE/wall-time.json"
wall_rc=$?
set -e
[ "$wall_rc" -eq 124 ] || { echo "sandbox-security-gate: wall timeout returned $wall_rc, expected 124" >&2; exit 1; }
python3 - "$EVIDENCE/wall-time.json" <<'PY'
import json, sys
row = json.load(open(sys.argv[1], encoding="utf-8"))
if row.get("exitCode") != 124 or row.get("exec", {}).get("timedOut") is not True:
    raise SystemExit(f"sandbox timeout evidence is invalid: {row!r}")
if row.get("cleanup", {}).get("deleted") is not True:
    raise SystemExit(f"timed-out sandbox was not deleted: {row!r}")
PY

"$DORY_BIN" sandbox run --json --keep --name "$ROLLBACK" --network none --rollback \
  --memory-mb 1024 --cpus 1 --disk-mb 32 --wall-time-seconds 30 -- \
  /bin/sh -eu -c 'printf changed > "$DORY_SCRATCH/rollback-must-remove"' \
  > "$EVIDENCE/rollback-create.json"
"$DORY_BIN" sandbox run --json --reuse "$ROLLBACK" --network none --wall-time-seconds 30 -- \
  /bin/sh -eu -c 'test ! -e "$DORY_SCRATCH/rollback-must-remove"; printf SANDBOX-ROLLBACK-PASS' \
  > "$EVIDENCE/rollback-reuse.json"
"$DORY_BIN" sandbox kill "$ROLLBACK" > "$EVIDENCE/rollback-kill.txt"

"$DORY_BIN" sandbox run --json --keep --name "$TTL" --ttl-seconds 2 --network none \
  --memory-mb 1024 --cpus 1 --disk-mb 32 --wall-time-seconds 30 -- /bin/true \
  > "$EVIDENCE/ttl-create.json"
ttl_deleted=0
for _ in $(seq 1 35); do
  if ! "$DORY_BIN" machine status "$TTL" >/dev/null 2>&1; then ttl_deleted=1; break; fi
  sleep 1
done
[ "$ttl_deleted" -eq 1 ] || { echo "sandbox-security-gate: daemon did not delete expired TTL sandbox" >&2; exit 1; }

python3 - "$EVIDENCE/outbound.json" "$EVIDENCE/rollback-reuse.json" <<'PY'
import json, sys
outbound = json.load(open(sys.argv[1], encoding="utf-8"))
rollback = json.load(open(sys.argv[2], encoding="utf-8"))
if outbound.get("exec", {}).get("stdout") != "SANDBOX-OUTBOUND-PASS":
    raise SystemExit(f"sandbox outbound execution failed: {outbound!r}")
network = outbound.get("manifest", {}).get("network", {})
if network.get("mode") != "outbound" or not network.get("grants"):
    raise SystemExit(f"sandbox outbound authority is invalid: {outbound!r}")
if rollback.get("exec", {}).get("stdout") != "SANDBOX-ROLLBACK-PASS":
    raise SystemExit(f"sandbox rollback execution failed: {rollback!r}")
if rollback.get("rollback", {}).get("requested") is not False:
    raise SystemExit(f"sandbox reuse unexpectedly requested another rollback: {rollback!r}")
PY

cat > "$WORKDIR/manifest.txt" <<EOF
schema=dev.dory.sandbox.security-gate.v1
status=PASS
run_id=$RUN_ID
dory_sha256=$(shasum -a 256 "$DORY_BIN" | awk '{print $1}')
allowed_network=$ALLOWED_DESTINATION
non_root=PASS
read_only_mount=PASS
secret_manifest_omission=PASS
network_none=PASS
network_outbound_allowlist=PASS
private_lan_host_loopback_metadata_denial=PASS
dns_policy=PASS
disk_process_fd_wall_caps=PASS
rollback_reuse=PASS
kill_switch=PASS
daemon_ttl=PASS
EOF

trap - EXIT INT TERM
cleanup
printf 'sandbox security gate PASS; evidence: %s\n' "$WORKDIR"
