#!/bin/bash
# Fail-closed entry point for the physical ARM Ubuntu qualification scenario.
#
# The old file was an evidence scaffold: it copied an unrelated PNG and emitted unconditional
# PASS JSON for installer, reboot, package, storage, and fault phases. That output was not runtime
# evidence and must never be accepted by the signed campaign gate.
#
# This driver now launches the exact signed candidate in its display-only qualification mode and
# captures the exact campaign-owned Dory window after a Metal-completed frame. It remains
# intentionally fail-closed for unattended UEFI/installer input and daemon fault injection.
set -euo pipefail

APP=""
CTL=""
MACH_SERVICE=""
MACHINE=""
RUN_DIR=""
GUEST_COMMAND=""
EXPECTED_OUTPUT=""
TIMEOUT_SECONDS=900

usage() {
  cat <<'EOF'
Usage: scripts/arm-ubuntu-scenario-driver.sh [options]

Required:
  --app PATH
  --ctl PATH
  --mach-service NAME
  --machine NAME
  --run-directory PATH
  --guest-command COMMAND
  --expected-output TEXT

Optional:
  --timeout-seconds N      Per-operation deadline (default: 900)
  --help

This in-tree driver retains a machine-scoped Dory-window capture, then fails closed until Dory
exposes authenticated unattended UEFI/input and fault-injection controls. It never derives PASS
for an unexecuted phase.
EOF
}

die() {
  echo "arm-ubuntu-scenario-driver: $*" >&2
  exit 2
}

need_value() {
  [ "$2" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) need_value "$1" "$#"; APP="$2"; shift 2 ;;
    --ctl) need_value "$1" "$#"; CTL="$2"; shift 2 ;;
    --mach-service) need_value "$1" "$#"; MACH_SERVICE="$2"; shift 2 ;;
    --machine) need_value "$1" "$#"; MACHINE="$2"; shift 2 ;;
    --run-directory) need_value "$1" "$#"; RUN_DIR="$2"; shift 2 ;;
    --guest-command) need_value "$1" "$#"; GUEST_COMMAND="$2"; shift 2 ;;
    --expected-output) need_value "$1" "$#"; EXPECTED_OUTPUT="$2"; shift 2 ;;
    --timeout-seconds) need_value "$1" "$#"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$APP" ] || die "--app is required"
[ -d "$APP" ] && [ ! -L "$APP" ] || die "--app is not a direct application bundle: $APP"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
[ "$(basename "$APP")" = Dory.app ] || die "--app must name Dory.app"
APP_EXECUTABLE="$APP/Contents/MacOS/Dory"
[ -x "$APP_EXECUTABLE" ] && [ ! -L "$APP_EXECUTABLE" ] \
  || die "Dory application executable is unavailable: $APP_EXECUTABLE"
codesign --verify --deep --strict "$APP" >/dev/null \
  || die "Dory application signature verification failed"
app_details="$(codesign -d --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$app_details" | grep -Fqx 'Identifier=com.pythonxi.Dory' \
  || die "Dory application identifier is invalid"
printf '%s\n' "$app_details" | grep -Fqx 'TeamIdentifier=864H636QW4' \
  || die "Dory application signing team is invalid"
printf '%s\n' "$app_details" | grep -Fq 'Authority=Developer ID Application:' \
  || die "Dory application is not Developer-ID-signed"
[ -n "$CTL" ] || die "--ctl is required"
[ -x "$CTL" ] || die "--ctl is not executable: $CTL"
[ -n "$MACH_SERVICE" ] || die "--mach-service is required"
[ -n "$MACHINE" ] || die "--machine is required"
[ -n "$RUN_DIR" ] || die "--run-directory is required"
[ -n "$GUEST_COMMAND" ] || die "--guest-command is required"
[ -n "$EXPECTED_OUTPUT" ] || die "--expected-output is required"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive integer"
[ "$TIMEOUT_SECONDS" -le 7200 ] || die "timeout must not exceed 7200 seconds"
case "$RUN_DIR" in /*) ;; *) die "--run-directory must be absolute" ;; esac
mkdir -p "$RUN_DIR"
mkdir -p "$RUN_DIR/home"
chmod 0700 "$RUN_DIR/home"

WINDOW_RECEIPT="$RUN_DIR/display-window.json"
FRAMEBUFFER="$RUN_DIR/framebuffer.png"
CAPTURE_RECEIPT="$RUN_DIR/window-capture.json"
for output in "$WINDOW_RECEIPT" "$FRAMEBUFFER" "$CAPTURE_RECEIPT" \
    "$RUN_DIR/scenario-driver-readiness.json"; do
  [ ! -e "$output" ] && [ ! -L "$output" ] \
    || die "refusing pre-existing scenario output: $output"
done
APP_PID=""
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

HOME="$RUN_DIR/home" \
DORYD_MACH_SERVICE="$MACH_SERVICE" \
DORY_DISPLAY_QUALIFICATION_MACHINE_ID="$MACHINE" \
DORY_DISPLAY_QUALIFICATION_SCANOUT_ID=0 \
DORY_DISPLAY_QUALIFICATION_WINDOW_RECEIPT="$WINDOW_RECEIPT" \
  "$APP_EXECUTABLE" > "$RUN_DIR/display-app.out" 2> "$RUN_DIR/display-app.err" &
APP_PID=$!

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ ! -s "$WINDOW_RECEIPT" ]; do
  kill -0 "$APP_PID" 2>/dev/null \
    || die "display qualification app exited before producing its window receipt"
  [ "$SECONDS" -lt "$deadline" ] \
    || die "timed out waiting for a Metal-completed Dory display window"
  sleep 1
done

command -v jq >/dev/null || die "jq is required"
jq -e --arg machine "$MACHINE" --arg service "$MACH_SERVICE" --argjson pid "$APP_PID" '
  .kind == "dev.dory.display-qualification-window" and .schemaVersion == 1
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .scanoutID == 0 and .machServiceName == $service
  and .windowTitle == ("Dory — " + $machine + " — Display 1")
  and (.windowNumber | type == "number" and . > 0)
  and (.frameSequence | type == "number" and . > 0)
  and (.displayResourceGeneration | type == "number" and . > 0)
  and (.transport == "sharedMemory" or .transport == "sharedTexture")
' "$WINDOW_RECEIPT" >/dev/null || die "display qualification window receipt is invalid"
WINDOW_NUMBER="$(jq -r '.windowNumber' "$WINDOW_RECEIPT")"
sleep 1
/usr/sbin/screencapture -x -o -l"$WINDOW_NUMBER" "$FRAMEBUFFER" \
  || die "WindowServer could not capture the campaign Dory window"
python3 - "$FRAMEBUFFER" "$WINDOW_RECEIPT" "$CAPTURE_RECEIPT" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

framebuffer, window_receipt, output = map(Path, sys.argv[1:])
payload = framebuffer.read_bytes()
if payload[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("captured Dory window is not a PNG")
window = json.loads(window_receipt.read_text(encoding="utf-8"))
receipt = {
    "kind": "dev.dory.machine-window-capture",
    "schemaVersion": 1,
    "status": "PASS",
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machineID": window["machineID"],
    "machServiceName": window["machServiceName"],
    "processID": window["processID"],
    "windowNumber": window["windowNumber"],
    "windowTitle": window["windowTitle"],
    "frameSequence": window["frameSequence"],
    "displayResourceGeneration": window["displayResourceGeneration"],
    "transport": window["transport"],
    "framebufferSHA256": hashlib.sha256(payload).hexdigest(),
    "windowReceiptSHA256": hashlib.sha256(window_receipt.read_bytes()).hexdigest(),
}
output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$RUN_DIR/scenario-driver-readiness.json" \
  "$MACH_SERVICE" "$MACHINE" "$TIMEOUT_SECONDS" "$CAPTURE_RECEIPT" <<'PY'
import json
import sys
from pathlib import Path

path, service, machine, timeout, capture_path = sys.argv[1:]
capture = json.loads(Path(capture_path).read_text(encoding="utf-8"))
record = {
    "kind": "dev.dory.arm-ubuntu-scenario-driver-readiness",
    "schemaVersion": 1,
    "status": "FAIL",
    "machine": machine,
    "machService": service,
    "timeoutSeconds": int(timeout),
    "missingAuthorities": [
        "authenticated-uefi-keyboard-input",
        "daemon-storage-fault-injection",
        "daemon-mapped-page-retry-injection",
    ],
    "completedAuthorities": ["machine-scoped-window-capture"],
    "framebufferSHA256": capture["framebufferSHA256"],
    "windowReceiptSHA256": capture["windowReceiptSHA256"],
    "detail": (
        "The signed candidate displayed and retained one machine-scoped Metal frame. The "
        "remaining input and fault phases were not executed and no PASS was synthesized for them."
    ),
}
Path(path).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY

die "required input/fault campaign authorities are unavailable; retained machine-scoped capture and readiness evidence"
