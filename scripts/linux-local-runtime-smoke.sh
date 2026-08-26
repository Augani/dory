#!/bin/bash
# Produce local, candidate-bound physical Linux runtime evidence. This is a developer smoke,
# not a release gate: GPU acceleration and physical USB passthrough are deliberately never
# qualified here.
set -euo pipefail

CTL=""
CANDIDATE_HV=""
MACHINE=""
KERNEL=""
INITFS=""
SHARE_TAG=""
SHARE_HOST=""
SHARE_GUEST=""
EVIDENCE_DIR=""
CONFIRM=""
MACHINE_STARTED=0
HOST_MARKER=""
GUEST_MARKER=""
RESULT=0

usage() {
  cat >&2 <<'EOF'
usage: linux-local-runtime-smoke.sh \
  --ctl PATH --candidate-hv PATH --machine NAME \
  --kernel PATH --initfs PATH \
  --share-tag TAG --share-host PATH --share-guest PATH \
  --evidence-dir PATH --confirm LOCAL-PHYSICAL-LINUX-SMOKE

The machine must already exist, be stopped, use software graphics, and contain the exact
read-write share passed above. The daemon must already be configured to launch CANDIDATE_HV.
The harness starts and stops only that machine and creates a new evidence directory.
EOF
  exit 64
}

fail() {
  printf 'linux local runtime smoke: %s\n' "$*" >&2
  exit 1
}

require_regular_file() {
  local label="$1" path="$2"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] \
    || fail "$label must be a non-empty regular, non-symlink file: $path"
}

absolute_file() {
  local input="$1" directory
  directory="$(cd "$(dirname "$input")" && pwd -P)"
  printf '%s/%s\n' "$directory" "$(basename "$input")"
}

json_field() {
  local field="$1"
  python3 -c '
import json
import sys

value = json.load(sys.stdin)
for component in sys.argv[1].split("."):
    if not isinstance(value, dict) or component not in value:
        raise SystemExit(2)
    value = value[component]
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (str, int)):
    print(value)
else:
    raise SystemExit(2)
' "$field"
}

exec_passed() {
  local token="$1" response="$2"
  python3 - "$token" "$response" <<'PY'
import json
import sys

token, path = sys.argv[1:]
with open(path, "rb") as stream:
    body = json.load(stream)
if body.get("exitCode") != 0 or body.get("timedOut") is not False:
    raise SystemExit(1)
stdout = body.get("stdout")
if not isinstance(stdout, str) or token not in stdout:
    raise SystemExit(1)
PY
}

record_command() {
  local argument
  printf 'command' >> "$EVIDENCE_DIR/commands.txt"
  for argument in "$@"; do
    printf ' %q' "$argument" >> "$EVIDENCE_DIR/commands.txt"
  done
  printf '\n' >> "$EVIDENCE_DIR/commands.txt"
}

capture_exec() {
  local destination="$1" token="$2"
  shift 2
  record_command "$CTL" machine exec "$MACHINE" --json --timeout-ms 120000 \
    --output-limit-bytes 1048576 -- "$@"
  if ! "$CTL" machine exec "$MACHINE" --json --timeout-ms 120000 \
      --output-limit-bytes 1048576 -- "$@" > "$destination"; then
    return 1
  fi
  exec_passed "$token" "$destination"
}

wait_for_running() {
  local attempt state
  for attempt in $(seq 1 480); do
    if "$CTL" machine status "$MACHINE" --json > "$EVIDENCE_DIR/status-wait.json" 2>/dev/null; then
      state="$(json_field state < "$EVIDENCE_DIR/status-wait.json" 2>/dev/null || true)"
      [ "$state" != running ] || return 0
      case "$state" in failed|unsupported) return 1 ;; esac
    fi
    sleep 0.25
  done
  return 1
}

wait_for_stopped() {
  local attempt state
  for attempt in $(seq 1 120); do
    if "$CTL" machine status "$MACHINE" --json > "$EVIDENCE_DIR/status-stop-wait.json" 2>/dev/null; then
      state="$(json_field state < "$EVIDENCE_DIR/status-stop-wait.json" 2>/dev/null || true)"
      [ "$state" != stopped ] || return 0
    fi
    sleep 0.25
  done
  return 1
}

stop_machine() {
  [ "$MACHINE_STARTED" = 1 ] || return 0
  set +e
  record_command "$CTL" machine stop "$MACHINE" --json
  "$CTL" machine stop "$MACHINE" --json > "$EVIDENCE_DIR/stop-request.json" 2>&1
  wait_for_stopped
  local stop_result=$?
  "$CTL" machine status "$MACHINE" --json > "$EVIDENCE_DIR/stopped-status.json" 2>&1
  MACHINE_STARTED=0
  set -e
  return "$stop_result"
}

cleanup() {
  local status=$?
  set +e
  if [ "$MACHINE_STARTED" = 1 ]; then
    stop_machine || true
  fi
  [ -z "$HOST_MARKER" ] || rm -f -- "$HOST_MARKER"
  [ -z "$GUEST_MARKER" ] || rm -f -- "$GUEST_MARKER"
  trap - EXIT INT TERM
  exit "$status"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ctl) CTL="${2:?missing path}"; shift 2 ;;
    --candidate-hv) CANDIDATE_HV="${2:?missing path}"; shift 2 ;;
    --machine) MACHINE="${2:?missing name}"; shift 2 ;;
    --kernel) KERNEL="${2:?missing path}"; shift 2 ;;
    --initfs) INITFS="${2:?missing path}"; shift 2 ;;
    --share-tag) SHARE_TAG="${2:?missing tag}"; shift 2 ;;
    --share-host) SHARE_HOST="${2:?missing path}"; shift 2 ;;
    --share-guest) SHARE_GUEST="${2:?missing path}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:?missing path}"; shift 2 ;;
    --confirm) CONFIRM="${2:?missing confirmation}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ "$CONFIRM" = LOCAL-PHYSICAL-LINUX-SMOKE ] || usage
for required in CTL CANDIDATE_HV MACHINE KERNEL INITFS SHARE_TAG SHARE_HOST SHARE_GUEST EVIDENCE_DIR; do
  [ -n "${!required}" ] || usage
done
printf '%s\n' "$MACHINE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' \
  || fail "invalid machine name: $MACHINE"
printf '%s\n' "$SHARE_TAG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' \
  || fail "invalid share tag: $SHARE_TAG"
printf '%s\n' "$SHARE_GUEST" | grep -Eq '^/[A-Za-z0-9._/-]+$' \
  || fail "share guest path must be an absolute simple path: $SHARE_GUEST"
case "$EVIDENCE_DIR" in /*) ;; *) fail "evidence directory must be absolute" ;; esac
[ ! -e "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] \
  || fail "evidence directory already exists or is indirect: $EVIDENCE_DIR"

require_regular_file dorydctl "$CTL"
require_regular_file dory-hv "$CANDIDATE_HV"
require_regular_file kernel "$KERNEL"
require_regular_file initfs "$INITFS"
[ -x "$CTL" ] || fail "dorydctl is not executable: $CTL"
[ -x "$CANDIDATE_HV" ] || fail "dory-hv is not executable: $CANDIDATE_HV"
[ -d "$SHARE_HOST" ] && [ ! -L "$SHARE_HOST" ] \
  || fail "share host path must be a non-symlink directory: $SHARE_HOST"
CTL="$(absolute_file "$CTL")"
CANDIDATE_HV="$(absolute_file "$CANDIDATE_HV")"
KERNEL="$(absolute_file "$KERNEL")"
INITFS="$(absolute_file "$INITFS")"
SHARE_HOST="$(cd "$SHARE_HOST" && pwd -P)"

[ "$(uname -s)" = Darwin ] || fail "physical smoke requires macOS"
[ "$(uname -m)" = arm64 ] || fail "physical Linux smoke currently requires Apple silicon"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || fail "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || fail "nested virtualization host detected"
case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
  VirtualMac*) fail "VirtualMac does not provide physical qualification evidence" ;;
esac
command -v python3 >/dev/null || fail "python3 is required to validate evidence JSON"
command -v codesign >/dev/null || fail "codesign is required to bind the candidate"
command -v lsof >/dev/null || fail "lsof is required to bind the running process"

umask 077
mkdir -p "$EVIDENCE_DIR"
trap cleanup EXIT INT TERM
: > "$EVIDENCE_DIR/commands.txt"
{
  printf 'evidence_scope=local-developer-physical-smoke\n'
  printf 'release_qualification=false\n'
  printf 'gpu_acceleration=not-exercised\n'
  printf 'usb_physical_passthrough=not-exercised\n'
  printf 'machine=%s\n' "$MACHINE"
  printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  uname -a
  sysctl -n hw.model hw.memsize kern.hv_support 2>/dev/null || true
  system_profiler SPHardwareDataType 2>/dev/null || true
} > "$EVIDENCE_DIR/host-facts.txt"
{
  shasum -a 256 "$CANDIDATE_HV" "$CTL" "$KERNEL" "$INITFS"
} > "$EVIDENCE_DIR/artifacts-sha256.txt"
record_command codesign --verify --strict "$CANDIDATE_HV"
codesign --verify --strict "$CANDIDATE_HV"
record_command codesign -d --verbose=4 --entitlements :- "$CANDIDATE_HV"
codesign -d --verbose=4 --entitlements :- "$CANDIDATE_HV" \
  > "$EVIDENCE_DIR/candidate-codesign.txt" 2>&1
grep -q 'com.apple.security.hypervisor' "$EVIDENCE_DIR/candidate-codesign.txt" \
  || fail "candidate lacks the Hypervisor.framework entitlement"

record_command "$CTL" machine status "$MACHINE" --json
"$CTL" machine status "$MACHINE" --json > "$EVIDENCE_DIR/preflight-status.json"
[ "$(json_field state < "$EVIDENCE_DIR/preflight-status.json")" = stopped ] \
  || fail "machine must be stopped before the smoke"
python3 - "$EVIDENCE_DIR/preflight-status.json" "$SHARE_TAG" "$SHARE_GUEST" <<'PY'
import json
import sys

path, tag, guest = sys.argv[1:]
with open(path, "rb") as stream:
    status = json.load(stream)
graphics = status.get("typedSettings", {}).get("desktopGraphicsPreference")
if graphics != "software":
    raise SystemExit(f"machine must use software graphics; found {graphics!r}")
shares = status.get("shares")
if not isinstance(shares, list):
    raise SystemExit("machine status omitted shares")
expected = (tag, guest, "rw")
actual = {
    (share.get("tag"), share.get("guestPath"), share.get("mode"))
    for share in shares if isinstance(share, dict)
}
if expected not in actual:
    raise SystemExit(f"required rw guest share is absent: {expected!r}; got {sorted(actual)!r}")
PY

MARKER_ID="dory-local-linux-smoke-$$-$(date -u +%s)"
HOST_MARKER="$SHARE_HOST/$MARKER_ID-host.txt"
GUEST_MARKER="$SHARE_HOST/$MARKER_ID-guest.txt"
[ ! -e "$HOST_MARKER" ] && [ ! -L "$HOST_MARKER" ] || fail "host marker collision"
set -C
printf '%s\n' "$MARKER_ID-host" > "$HOST_MARKER"
set +C

record_command "$CTL" machine start "$MACHINE" --json
"$CTL" machine start "$MACHINE" --json > "$EVIDENCE_DIR/start-request.json"
MACHINE_STARTED=1
wait_for_running || fail "machine did not reach running state"
"$CTL" machine status "$MACHINE" --json > "$EVIDENCE_DIR/running-status.json"
PID="$(json_field pid < "$EVIDENCE_DIR/running-status.json")"
printf '%s\n' "$PID" | grep -Eq '^[1-9][0-9]*$' || fail "running status has no valid pid"
RUNNING_EXECUTABLE="$(lsof -a -p "$PID" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
RUNNING_EXECUTABLE="$(absolute_file "$RUNNING_EXECUTABLE")"
{
  printf 'pid=%s\n' "$PID"
  printf 'expected_executable=%s\n' "$CANDIDATE_HV"
  printf 'running_executable=%s\n' "$RUNNING_EXECUTABLE"
  ps -p "$PID" -o pid=,ppid=,etime=,command=
} > "$EVIDENCE_DIR/candidate-process.txt"
[ "$RUNNING_EXECUTABLE" = "$CANDIDATE_HV" ] \
  || fail "daemon launched $RUNNING_EXECUTABLE instead of candidate $CANDIDATE_HV"
[ "$(shasum -a 256 "$RUNNING_EXECUTABLE" | awk '{print $1}')" = \
  "$(shasum -a 256 "$CANDIDATE_HV" | awk '{print $1}')" ] \
  || fail "running candidate digest changed"
python3 - "$EVIDENCE_DIR/candidate-process.txt" "$SHARE_TAG" "$SHARE_HOST" "$SHARE_GUEST" <<'PY'
import base64
import os
import re
import sys

path, expected_tag, expected_host, expected_guest = sys.argv[1:]
text = open(path, encoding="utf-8").read()
encoded_shares = re.findall(r"(?:^|\s)--share\s+(dory-share-v1\.[^\s]+)", text)
actual = set()
for encoded in encoded_shares:
    parts = encoded.split(".")
    if len(parts) != 5 or parts[0] != "dory-share-v1":
        continue
    try:
        tag, host, guest = (
            base64.b64decode(part, validate=True).decode("utf-8")
            for part in parts[1:4]
        )
    except (ValueError, UnicodeDecodeError):
        continue
    actual.add((tag, os.path.realpath(host), guest, parts[4]))
expected = (expected_tag, os.path.realpath(expected_host), expected_guest, "rw")
if expected not in actual:
    raise SystemExit(f"launched process omitted exact share {expected!r}; got {sorted(actual)!r}")
PY

READY=0
for _ in $(seq 1 60); do
  if capture_exec "$EVIDENCE_DIR/readiness.json" DORY_EXEC_READY \
      sh -lc 'echo DORY_EXEC_READY' >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" = 1 ] || fail "guest agent exec did not become ready"

BOOT_SCRIPT='set -eu
echo DORY_BOOT_DEVICE_SMOKE_BEGIN
uname -a
cat /etc/os-release
cat /proc/cmdline
printf "nproc="; nproc
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
ROOT_OPTIONS=$(findmnt -n -o OPTIONS /)
printf "root_source=%s\nroot_fstype=%s\nroot_options=%s\n" "$ROOT_SOURCE" "$ROOT_FSTYPE" "$ROOT_OPTIONS"
case "$ROOT_SOURCE" in /dev/vd*) ;; *) exit 41 ;; esac
[ -n "$ROOT_FSTYPE" ]
case ",$ROOT_OPTIONS," in *,rw,*) ;; *) exit 42 ;; esac
lsblk -b -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
[ -b /dev/vda ]
printf "vda_size_bytes="; blockdev --getsize64 /dev/vda
for DRIVER in virtio_blk virtio_gpu virtio_rng virtio_balloon vmw_vsock_virtio_transport virtio_input virtio_snd virtiofs virtio_net; do
  FOUND=0
  for DEV in /sys/bus/virtio/devices/*; do
    [ ! -L "$DEV/driver" ] || [ "$(basename "$(readlink "$DEV/driver")")" != "$DRIVER" ] || FOUND=1
  done
  [ "$FOUND" = 1 ] || exit 43
done
for DEV in /sys/bus/virtio/devices/*; do
  [ -e "$DEV" ] || continue
  DRIVER=none; [ ! -L "$DEV/driver" ] || DRIVER=$(basename "$(readlink "$DEV/driver")")
  printf "virtio name=%s device=%s vendor=%s driver=%s\n" "$(basename "$DEV")" "$(cat "$DEV/device")" "$(cat "$DEV/vendor")" "$DRIVER"
done
[ -e /dev/vsock ]
ls -l /dev/vsock
echo DORY_BOOT_DEVICE_SMOKE_PASS'
if ! capture_exec "$EVIDENCE_DIR/boot-devices.json" DORY_BOOT_DEVICE_SMOKE_PASS \
    sh -lc "$BOOT_SCRIPT"; then
  RESULT=1
fi

NETWORK_SCRIPT='set -eu
echo DORY_NETWORK_SMOKE_BEGIN
ip -br link
ip -br addr
ip -4 route
ip -4 addr show dev eth0 | grep -q "inet "
ip -4 route show default | grep -q "default"
getent ahostsv4 example.com | head -n 3
python3 - <<"PY"
import socket
with socket.create_connection(("example.com", 443), timeout=15):
    pass
print("tcp_443=pass")
PY
echo DORY_NETWORK_SMOKE_PASS'
if ! capture_exec "$EVIDENCE_DIR/network.json" DORY_NETWORK_SMOKE_PASS \
    sh -lc "$NETWORK_SCRIPT"; then
  RESULT=1
fi

HOST_MARKER_NAME="$(basename "$HOST_MARKER")"
GUEST_MARKER_NAME="$(basename "$GUEST_MARKER")"
SHARE_SCRIPT="set -eu
echo DORY_SHARE_SMOKE_BEGIN
AUTOMOUNT=pass
if ! mountpoint -q '$SHARE_GUEST'; then
  AUTOMOUNT=fail
  mkdir -p '$SHARE_GUEST'
  mount -t virtiofs '$SHARE_TAG' '$SHARE_GUEST'
fi
printf 'automount=%s\\n' \"\$AUTOMOUNT\"
findmnt -n -o SOURCE,FSTYPE,OPTIONS '$SHARE_GUEST'
grep -qx '$MARKER_ID-host' '$SHARE_GUEST/$HOST_MARKER_NAME'
printf '%s\\n' '$MARKER_ID-guest' > '$SHARE_GUEST/$GUEST_MARKER_NAME'
sync '$SHARE_GUEST/$GUEST_MARKER_NAME' 2>/dev/null || sync
grep -qx '$MARKER_ID-guest' '$SHARE_GUEST/$GUEST_MARKER_NAME'
echo DORY_VIRTIOFS_DATAPATH_PASS
[ \"\$AUTOMOUNT\" = pass ]
echo DORY_SHARE_SMOKE_PASS"
if ! capture_exec "$EVIDENCE_DIR/share.json" DORY_SHARE_SMOKE_PASS \
    sh -lc "$SHARE_SCRIPT"; then
  RESULT=1
fi
if [ -f "$GUEST_MARKER" ] && grep -qx "$MARKER_ID-guest" "$GUEST_MARKER"; then
  printf 'guest_to_host_coherence=pass\n' > "$EVIDENCE_DIR/share-host-check.txt"
else
  printf 'guest_to_host_coherence=fail\n' > "$EVIDENCE_DIR/share-host-check.txt"
  RESULT=1
fi

OBSERVATION_SCRIPT='set -eu
echo DORY_CAPABILITY_OBSERVATIONS_BEGIN
if [ -d /dev/dri ]; then ls -l /dev/dri; else echo dri=absent; fi
if [ -r /proc/asound/cards ]; then cat /proc/asound/cards; else echo asound_cards=absent; fi
if [ -d /dev/input ]; then ls -l /dev/input; else echo input=absent; fi
find /sys/devices/platform -maxdepth 1 -iname "vhci*" -print 2>/dev/null || true
if command -v lsusb >/dev/null 2>&1; then lsusb; else echo lsusb=unavailable; fi
echo gpu_acceleration_exercised=false
echo usb_physical_device_exercised=false
echo DORY_CAPABILITY_OBSERVATIONS_PASS'
if ! capture_exec "$EVIDENCE_DIR/capability-observations.json" \
    DORY_CAPABILITY_OBSERVATIONS_PASS sh -lc "$OBSERVATION_SCRIPT"; then
  RESULT=1
fi

record_command "$CTL" machine device-telemetry "$MACHINE"
"$CTL" machine device-telemetry "$MACHINE" > "$EVIDENCE_DIR/device-telemetry.json" \
  || RESULT=1
record_command "$CTL" machine flight-recorder "$MACHINE"
"$CTL" machine flight-recorder "$MACHINE" > "$EVIDENCE_DIR/flight-recorder.json" \
  || RESULT=1
stop_machine || RESULT=1

record_command "$CANDIDATE_HV" smoke
if ! "$CANDIDATE_HV" smoke > "$EVIDENCE_DIR/rawhv-smoke.txt" 2>&1; then
  RESULT=1
fi
record_command "$CANDIDATE_HV" agent-ping --kernel "$KERNEL" --initfs "$INITFS" \
  --mem-mb 2048 --cpus 2 --timeout-sec 90
if ! "$CANDIDATE_HV" agent-ping --kernel "$KERNEL" --initfs "$INITFS" \
    --mem-mb 2048 --cpus 2 --timeout-sec 90 \
    > "$EVIDENCE_DIR/rawhv-agent-ping.txt" 2>&1; then
  RESULT=1
fi

{
  printf 'finished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'overall=%s\n' "$([ "$RESULT" = 0 ] && printf pass || printf fail)"
  printf 'scope=local-developer-physical-smoke\n'
  printf 'release_qualification=false\n'
  printf 'gpu_acceleration=not-exercised\n'
  printf 'usb_physical_passthrough=not-exercised\n'
} > "$EVIDENCE_DIR/qualification-result.txt"

if [ "$RESULT" != 0 ]; then
  fail "one or more lanes failed; evidence preserved at $EVIDENCE_DIR"
fi
printf 'linux local runtime smoke passed; evidence: %s\n' "$EVIDENCE_DIR"
