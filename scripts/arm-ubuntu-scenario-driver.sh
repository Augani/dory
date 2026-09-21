#!/bin/bash
# Fail-closed entry point for the physical ARM Ubuntu qualification scenario.
#
# The old file was an evidence scaffold: it copied an unrelated PNG and emitted unconditional
# PASS JSON for installer, reboot, package, storage, and fault phases. That output was not runtime
# evidence and must never be accepted by the signed campaign gate.
#
# This driver now launches the exact signed candidate in its display-only qualification mode and
# captures the exact campaign-owned Dory window after a Metal-completed frame. It remains
# intentionally fail-closed for installer orchestration and daemon fault injection. Keyboard
# commands are delivered only by the signed app through the isolated display broker.
set -euo pipefail

APP=""
CTL=""
MACH_SERVICE=""
MACHINE=""
RUN_DIR=""
GUEST_COMMAND=""
EXPECTED_OUTPUT=""
PROBE_RESULT_COMMAND=""
PROBE_NONCE=""
GRAPHICS_TRACE=""
INPUT_SCRIPT=""
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
  --guest-command COMMAND  Vsock command run after input and before the capture request
  --expected-output TEXT   Exact non-truncated stdout required from that command
  --input-script PATH       Bounded, balanced evdev keyboard script for this machine

Optional:
  --probe-result-command COMMAND
                           Read one dev.dory.gpu-probe JSON object from the guest
  --probe-nonce NONCE      Exact nonce required in that GPU probe result
  --graphics-trace PATH    Runner graphics-trace.ndjson to correlate and retain
  --timeout-seconds N      Per-operation deadline (default: 900)
  --help

This in-tree driver retains a machine-scoped Dory-window capture and an app-authored receipt for
keyboard commands accepted by the isolated display broker. It still fails closed for unexecuted
installer and fault-injection phases.
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
    --probe-result-command) need_value "$1" "$#"; PROBE_RESULT_COMMAND="$2"; shift 2 ;;
    --probe-nonce) need_value "$1" "$#"; PROBE_NONCE="$2"; shift 2 ;;
    --graphics-trace) need_value "$1" "$#"; GRAPHICS_TRACE="$2"; shift 2 ;;
    --input-script) need_value "$1" "$#"; INPUT_SCRIPT="$2"; shift 2 ;;
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
[ -x "$CTL" ] && [ ! -L "$CTL" ] || die "--ctl is not a direct executable: $CTL"
CTL="$(cd "$(dirname "$CTL")" && pwd -P)/$(basename "$CTL")"
[ "$CTL" = "$APP/Contents/Helpers/dorydctl" ] \
  || die "--ctl must be the dorydctl bundled in the signed Dory.app"
[ -n "$MACH_SERVICE" ] || die "--mach-service is required"
[ -n "$MACHINE" ] || die "--machine is required"
[ -n "$RUN_DIR" ] || die "--run-directory is required"
[ -n "$GUEST_COMMAND" ] || die "--guest-command is required"
[ -n "$EXPECTED_OUTPUT" ] || die "--expected-output is required"
[ -n "$INPUT_SCRIPT" ] || die "--input-script is required"
if { [ -z "$PROBE_RESULT_COMMAND" ] && [ -n "$PROBE_NONCE" ]; } \
    || { [ -n "$PROBE_RESULT_COMMAND" ] && [ -z "$PROBE_NONCE" ]; }; then
  die "--probe-result-command and --probe-nonce must be supplied together"
fi
if [ -n "$PROBE_NONCE" ]; then
  [ "${#PROBE_NONCE}" -le 256 ] || die "--probe-nonce must not exceed 256 characters"
  printf '%s' "$PROBE_NONCE" | LC_ALL=C grep -Eq '^[[:graph:] ]+$' \
    || die "--probe-nonce must contain printable characters only"
fi
if [ -n "$GRAPHICS_TRACE" ]; then
  case "$GRAPHICS_TRACE" in /*) ;; *) die "--graphics-trace must be absolute" ;; esac
fi
[ -z "$PROBE_NONCE" ] || [ -n "$GRAPHICS_TRACE" ] \
  || die "--graphics-trace is required when retaining a GPU probe"
[ -f "$INPUT_SCRIPT" ] && [ ! -L "$INPUT_SCRIPT" ] && [ -s "$INPUT_SCRIPT" ] \
  || die "--input-script must be a nonempty direct file: $INPUT_SCRIPT"
INPUT_SCRIPT="$(cd "$(dirname "$INPUT_SCRIPT")" && pwd -P)/$(basename "$INPUT_SCRIPT")"
command -v jq >/dev/null || die "jq is required"
jq -e --arg machine "$MACHINE" '
  .kind == "dev.dory.display-qualification-keyboard-script"
  and .schemaVersion == 1 and .machineID == $machine
  and (.steps | type == "array" and length > 0 and length <= 1024)
  and all(.steps[];
    (.delayMilliseconds | type == "number" and . >= 0 and . <= 300000)
    and (.events | type == "array" and length > 0 and length <= 64)
    and all(.events[];
      .type == 1 and (.code | type == "number" and . >= 1 and . <= 255)
      and (.value == 0 or .value == 1 or .value == 2)))
' "$INPUT_SCRIPT" >/dev/null || die "--input-script has an invalid qualification envelope"
INPUT_SCRIPT_SHA256="$(shasum -a 256 "$INPUT_SCRIPT" | awk '{print $1}')"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive integer"
[ "$TIMEOUT_SECONDS" -le 7200 ] || die "timeout must not exceed 7200 seconds"
case "$RUN_DIR" in /*) ;; *) die "--run-directory must be absolute" ;; esac
mkdir -p "$RUN_DIR"
[ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] \
  || die "--run-directory must be a direct directory"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
mkdir -p "$RUN_DIR/home"
[ -d "$RUN_DIR/home" ] && [ ! -L "$RUN_DIR/home" ] \
  || die "campaign home must be a direct directory"
chmod 0700 "$RUN_DIR/home"

WINDOW_RECEIPT="$RUN_DIR/display-window.json"
CAPTURE_FRAME_REQUEST="$RUN_DIR/display-capture-frame.request"
CAPTURE_FRAME_RECEIPT="$RUN_DIR/display-capture-frame.json"
INPUT_RECEIPT="$RUN_DIR/display-input.json"
FRAMEBUFFER="$RUN_DIR/framebuffer.png"
CAPTURE_RECEIPT="$RUN_DIR/window-capture.json"
GUEST_COMMAND_TRANSPORT="$RUN_DIR/guest-command-transport.json"
GUEST_COMMAND_RESULT="$RUN_DIR/guest-command.json"
GPU_PROBE_TRANSPORT=""
GPU_PROBE_RESULT=""
GPU_DISPLAY_EVIDENCE=""
GPU_DISPLAY_VERIFICATION=""
GRAPHICS_TRACE_COPY=""
GRAPHICS_CORRELATION=""
for output in "$WINDOW_RECEIPT" "$CAPTURE_FRAME_REQUEST" "$CAPTURE_FRAME_RECEIPT" \
    "$INPUT_RECEIPT" "$FRAMEBUFFER" "$CAPTURE_RECEIPT" \
    "$GUEST_COMMAND_TRANSPORT" "$GUEST_COMMAND_RESULT" \
    "$RUN_DIR/scenario-driver-readiness.json"; do
  [ ! -e "$output" ] && [ ! -L "$output" ] \
    || die "refusing pre-existing scenario output: $output"
done
if [ -n "$PROBE_NONCE" ]; then
  GPU_PROBE_TRANSPORT="$RUN_DIR/gpu-probe-transport.json"
  GPU_PROBE_RESULT="$RUN_DIR/gpu-probe.json"
  GPU_DISPLAY_EVIDENCE="$RUN_DIR/gpu-display-evidence.json"
  GPU_DISPLAY_VERIFICATION="$RUN_DIR/gpu-display-verification.json"
  for output in "$GPU_PROBE_TRANSPORT" "$GPU_PROBE_RESULT" \
      "$GPU_DISPLAY_EVIDENCE" "$GPU_DISPLAY_VERIFICATION"; do
    [ ! -e "$output" ] && [ ! -L "$output" ] \
      || die "refusing pre-existing scenario output: $output"
  done
fi
if [ -n "$GRAPHICS_TRACE" ]; then
  GRAPHICS_TRACE_COPY="$RUN_DIR/graphics-trace.ndjson"
  GRAPHICS_CORRELATION="$RUN_DIR/graphics-correlation.json"
  for output in "$GRAPHICS_TRACE_COPY" "$GRAPHICS_CORRELATION"; do
    [ ! -e "$output" ] && [ ! -L "$output" ] \
      || die "refusing pre-existing scenario output: $output"
  done
fi
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
DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT="$INPUT_SCRIPT" \
DORY_DISPLAY_QUALIFICATION_INPUT_RECEIPT="$INPUT_RECEIPT" \
DORY_DISPLAY_QUALIFICATION_CAPTURE_REQUEST="$CAPTURE_FRAME_REQUEST" \
DORY_DISPLAY_QUALIFICATION_CAPTURE_RECEIPT="$CAPTURE_FRAME_RECEIPT" \
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

jq -e --arg machine "$MACHINE" --arg service "$MACH_SERVICE" --argjson pid "$APP_PID" '
  .kind == "dev.dory.display-qualification-window" and .schemaVersion == 1
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .scanoutID == 0 and .machServiceName == $service
  and .windowTitle == ("Dory — " + $machine + " — Display 1")
  and (.windowNumber | type == "number" and . > 0)
  and (.frameSequence | type == "number" and . > 0)
  and (.displayResourceGeneration | type == "number" and . > 0)
  and (.metalCommandBufferCompletionID | type == "number" and . > 0)
  and (.transport == "sharedMemory" or .transport == "sharedTexture")
' "$WINDOW_RECEIPT" >/dev/null || die "display qualification window receipt is invalid"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ ! -s "$INPUT_RECEIPT" ]; do
  kill -0 "$APP_PID" 2>/dev/null \
    || die "display qualification app exited before producing its input receipt"
  [ "$SECONDS" -lt "$deadline" ] \
    || die "timed out waiting for authenticated qualification keyboard input"
  sleep 1
done
[ "$(shasum -a 256 "$INPUT_SCRIPT" | awk '{print $1}')" = "$INPUT_SCRIPT_SHA256" ] \
  || die "qualification input script changed during execution"
INPUT_STEP_COUNT="$(jq '.steps | length' "$INPUT_SCRIPT")"
INPUT_EVENT_COUNT="$(jq '[.steps[].events | length] | add' "$INPUT_SCRIPT")"
jq -e --arg machine "$MACHINE" --arg service "$MACH_SERVICE" \
  --arg operation "$(jq -r '.operationID' "$WINDOW_RECEIPT")" \
  --arg script "$INPUT_SCRIPT_SHA256" --argjson pid "$APP_PID" \
  --argjson steps "$INPUT_STEP_COUNT" --argjson events "$INPUT_EVENT_COUNT" '
  .kind == "dev.dory.display-qualification-input" and .schemaVersion == 1
  and .delivery == "runner-applied"
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .machServiceName == $service
  and .operationID == $operation and .scriptSHA256 == $script
  and .stepCount == $steps and .eventCount == $events
  and (.firstCommandSequence | type == "number") and .firstCommandSequence > 0
  and (.lastCommandSequence | type == "number")
  and .lastCommandSequence >= .firstCommandSequence
' "$INPUT_RECEIPT" >/dev/null || die "display qualification input receipt is invalid"
HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
  machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
  --output-limit-bytes 4194304 -- sh -ec "$GUEST_COMMAND" \
  > "$GUEST_COMMAND_TRANSPORT" 2> "$RUN_DIR/guest-command.err" \
  || die "guest command transport failed"
jq -e --arg machine "$MACHINE" --arg command "$GUEST_COMMAND" \
  --arg expected "$EXPECTED_OUTPUT" '
  .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
  and .argv == ["sh", "-ec", $command]
  and .exitCode == 0 and .timedOut == false
  and .stdoutTruncated == false and .stderrTruncated == false
  and .stdout == $expected
' "$GUEST_COMMAND_TRANSPORT" >/dev/null \
  || die "guest command did not complete with the exact expected output"
jq '. + {status: "PASS"}' "$GUEST_COMMAND_TRANSPORT" > "$GUEST_COMMAND_RESULT"

python3 - "$CAPTURE_FRAME_REQUEST" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as target:
    target.write(b"capture-next-metal-completed-frame\n")
PY
deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ ! -s "$CAPTURE_FRAME_RECEIPT" ]; do
  kill -0 "$APP_PID" 2>/dev/null \
    || die "display qualification app exited before producing its capture-frame receipt"
  [ "$SECONDS" -lt "$deadline" ] \
    || die "timed out waiting for a post-input Metal-completed capture frame"
  sleep 1
done
jq -e --arg machine "$MACHINE" --arg service "$MACH_SERVICE" --argjson pid "$APP_PID" \
  --arg operation "$(jq -r '.operationID' "$WINDOW_RECEIPT")" \
  --argjson first_completion "$(jq '.metalCommandBufferCompletionID' "$WINDOW_RECEIPT")" '
  .kind == "dev.dory.display-qualification-window" and .schemaVersion == 1
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .scanoutID == 0 and .machServiceName == $service
  and .operationID == $operation
  and .windowTitle == ("Dory — " + $machine + " — Display 1")
  and (.windowNumber | type == "number" and . > 0)
  and (.frameSequence | type == "number" and . > 0)
  and (.displayResourceGeneration | type == "number" and . > 0)
  and (.metalCommandBufferCompletionID | type == "number")
  and .metalCommandBufferCompletionID > $first_completion
  and (.transport == "sharedMemory" or .transport == "sharedTexture")
' "$CAPTURE_FRAME_RECEIPT" >/dev/null \
  || die "display qualification capture-frame receipt is invalid"
WINDOW_NUMBER="$(jq -r '.windowNumber' "$CAPTURE_FRAME_RECEIPT")"
/usr/sbin/screencapture -x -o -l"$WINDOW_NUMBER" "$FRAMEBUFFER" \
  || die "WindowServer could not capture the campaign Dory window"
python3 - "$FRAMEBUFFER" "$WINDOW_RECEIPT" "$CAPTURE_FRAME_RECEIPT" \
  "$CAPTURE_RECEIPT" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

framebuffer, discovery_receipt, capture_frame_receipt, output = map(Path, sys.argv[1:])
payload = framebuffer.read_bytes()
if payload[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("captured Dory window is not a PNG")
window = json.loads(capture_frame_receipt.read_text(encoding="utf-8"))
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
    "operationID": window["operationID"],
    "frameSequence": window["frameSequence"],
    "displayResourceGeneration": window["displayResourceGeneration"],
    "metalCommandBufferCompletionID": window["metalCommandBufferCompletionID"],
    "transport": window["transport"],
    "framebufferSHA256": hashlib.sha256(payload).hexdigest(),
    "windowReceiptSHA256": hashlib.sha256(capture_frame_receipt.read_bytes()).hexdigest(),
    "discoveryWindowReceiptSHA256": hashlib.sha256(discovery_receipt.read_bytes()).hexdigest(),
}
output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if [ -n "$GRAPHICS_TRACE" ]; then
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while ! { [ -f "$GRAPHICS_TRACE" ] && [ ! -L "$GRAPHICS_TRACE" ] \
      && jq -s -e --arg machine "$MACHINE" \
        --arg operation "$(jq -r '.operationID' "$CAPTURE_FRAME_RECEIPT")" \
        --argjson completion "$(jq '.metalCommandBufferCompletionID' "$CAPTURE_FRAME_RECEIPT")" \
        --argjson generation "$(jq '.displayResourceGeneration' "$CAPTURE_FRAME_RECEIPT")" '
          any(.[];
            .stage == "metalPresentationCompleted"
            and .context.machineID == $machine
            and .context.operationID == $operation
            and .scanoutID == 0
            and .displayResourceGeneration == $generation
            and .metalCommandBufferCompletionID == $completion)
        ' "$GRAPHICS_TRACE" >/dev/null 2>&1; }; do
    kill -0 "$APP_PID" 2>/dev/null \
      || die "display qualification app exited before trace correlation completed"
    [ "$SECONDS" -lt "$deadline" ] \
      || die "timed out waiting for the runner Metal completion trace"
    sleep 1
  done
  python3 - "$GRAPHICS_TRACE" "$GRAPHICS_TRACE_COPY" "$CAPTURE_FRAME_RECEIPT" \
    "$GRAPHICS_CORRELATION" <<'PY'
import datetime
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

source, retained, capture_path, output = map(Path, sys.argv[1:])
source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
try:
    retained_descriptor = os.open(
        retained, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        with os.fdopen(source_descriptor, "rb", closefd=False) as reader:
            with os.fdopen(retained_descriptor, "wb", closefd=False) as writer:
                shutil.copyfileobj(reader, writer)
    finally:
        os.close(retained_descriptor)
finally:
    os.close(source_descriptor)

capture = json.loads(capture_path.read_text(encoding="utf-8"))
events = [json.loads(line) for line in retained.read_text(encoding="utf-8").splitlines()]
matches = [
    event for event in events
    if event.get("stage") == "metalPresentationCompleted"
    and event.get("context", {}).get("machineID") == capture["machineID"]
    and event.get("context", {}).get("operationID") == capture["operationID"]
    and event.get("scanoutID") == 0
    and event.get("displayResourceGeneration") == capture["displayResourceGeneration"]
    and event.get("metalCommandBufferCompletionID")
        == capture["metalCommandBufferCompletionID"]
]
if len(matches) != 1:
    raise SystemExit("retained graphics trace does not contain exactly one capture completion")
record = {
    "kind": "dev.dory.display-graphics-correlation",
    "schemaVersion": 1,
    "status": "PASS",
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machineID": capture["machineID"],
    "operationID": capture["operationID"],
    "frameSequence": capture["frameSequence"],
    "displayResourceGeneration": capture["displayResourceGeneration"],
    "metalCommandBufferCompletionID": capture["metalCommandBufferCompletionID"],
    "graphicsTraceSequence": matches[0]["sequence"],
    "framebufferSHA256": capture["framebufferSHA256"],
    "graphicsTraceSHA256": hashlib.sha256(retained.read_bytes()).hexdigest(),
}
output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
fi

if [ -n "$PROBE_NONCE" ]; then
  HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
    machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
    --output-limit-bytes 4194304 -- sh -ec "$PROBE_RESULT_COMMAND" \
    > "$GPU_PROBE_TRANSPORT" 2> "$RUN_DIR/gpu-probe.err" \
    || die "GPU probe result transport failed"
  jq -e --arg machine "$MACHINE" --arg command "$PROBE_RESULT_COMMAND" '
    .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
    and .argv == ["sh", "-ec", $command]
    and .exitCode == 0 and .timedOut == false
    and .stdoutTruncated == false and .stderrTruncated == false
  ' "$GPU_PROBE_TRANSPORT" >/dev/null \
    || die "GPU probe result transport envelope is invalid"
  jq -er '.stdout' "$GPU_PROBE_TRANSPORT" > "$GPU_PROBE_RESULT" \
    || die "GPU probe result transport did not contain UTF-8 JSON"
  python3 "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/validate-result.py" \
    --nonce "$PROBE_NONCE" "$GPU_PROBE_RESULT" >/dev/null \
    || die "GPU probe result failed campaign validation"
  python3 - "$GPU_PROBE_RESULT" "$CAPTURE_RECEIPT" "$GRAPHICS_CORRELATION" \
    "$GPU_DISPLAY_EVIDENCE" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

probe_path, capture_path, correlation_path, output = map(Path, sys.argv[1:])
probe = json.loads(probe_path.read_text(encoding="utf-8"))
capture = json.loads(capture_path.read_text(encoding="utf-8"))
correlation = json.loads(correlation_path.read_text(encoding="utf-8"))
if correlation.get("status") != "PASS":
    raise SystemExit("graphics correlation is not passing")
for key in (
    "machineID", "operationID", "displayResourceGeneration",
    "metalCommandBufferCompletionID", "framebufferSHA256",
):
    if correlation.get(key) != capture.get(key):
        raise SystemExit(f"graphics correlation disagrees with capture for {key}")
record = {
    "kind": "dev.dory.gpu-displayed-pixel-evidence",
    "schemaVersion": 1,
    "status": "PASS",
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machineID": capture["machineID"],
    "operationID": capture["operationID"],
    "probe": probe["probe"],
    "probeNonce": probe["nonce"],
    "probeResultHash": probe["resultHash"],
    "deviceName": probe["deviceName"],
    "driver": probe["driver"],
    "frameCount": probe["frameCount"],
    "probeSHA256": hashlib.sha256(probe_path.read_bytes()).hexdigest(),
    "framebufferSHA256": capture["framebufferSHA256"],
    "windowReceiptSHA256": capture["windowReceiptSHA256"],
    "captureReceiptSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "graphicsTraceSHA256": correlation["graphicsTraceSHA256"],
    "graphicsCorrelationSHA256": hashlib.sha256(
        correlation_path.read_bytes()
    ).hexdigest(),
    "displayResourceGeneration": capture["displayResourceGeneration"],
    "metalCommandBufferCompletionID": capture["metalCommandBufferCompletionID"],
}
output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  GPU_DISPLAY_VERIFICATION_PAYLOAD="$(
    python3 "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/verify-displayed-pixel.py" \
      --nonce "$PROBE_NONCE" "$RUN_DIR"
  )" || die "retained GPU displayed-pixel evidence failed replay verification"
  python3 - "$GPU_DISPLAY_VERIFICATION" "$GPU_DISPLAY_VERIFICATION_PAYLOAD" <<'PY'
import os
import sys

descriptor = os.open(
    sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
)
with os.fdopen(descriptor, "w", encoding="utf-8") as target:
    target.write(sys.argv[2] + "\n")
PY
fi

python3 - "$RUN_DIR/scenario-driver-readiness.json" \
  "$MACH_SERVICE" "$MACHINE" "$TIMEOUT_SECONDS" "$CAPTURE_RECEIPT" \
  "$INPUT_RECEIPT" "$GUEST_COMMAND_RESULT" "$GPU_PROBE_RESULT" \
  "$GRAPHICS_CORRELATION" "$GPU_DISPLAY_EVIDENCE" \
  "$GPU_DISPLAY_VERIFICATION" <<'PY'
import json
import sys
from pathlib import Path

(
    path, service, machine, timeout, capture_path, input_path, command_path,
    probe_path, correlation_path, gpu_display_path, gpu_display_verification_path,
) = sys.argv[1:]
capture = json.loads(Path(capture_path).read_text(encoding="utf-8"))
keyboard = json.loads(Path(input_path).read_text(encoding="utf-8"))
command = json.loads(Path(command_path).read_text(encoding="utf-8"))
completed = [
    "machine-scoped-window-capture",
    "authenticated-machine-keyboard-input",
    "guest-command-over-vsock",
]
probe_sha256 = None
if probe_path:
    completed.append("nonce-bound-gpu-probe-over-vsock")
    probe_sha256 = __import__("hashlib").sha256(Path(probe_path).read_bytes()).hexdigest()
correlation_sha256 = None
if correlation_path:
    completed.append("runner-metal-completion-correlation")
    correlation_sha256 = __import__("hashlib").sha256(
        Path(correlation_path).read_bytes()
    ).hexdigest()
gpu_display_sha256 = None
if gpu_display_path:
    completed.append("displayed-pixel-gpu-correlation")
    gpu_display_sha256 = __import__("hashlib").sha256(
        Path(gpu_display_path).read_bytes()
    ).hexdigest()
gpu_display_verification_sha256 = None
if gpu_display_verification_path:
    verification = json.loads(
        Path(gpu_display_verification_path).read_text(encoding="utf-8")
    )
    if verification.get("status") != "evidence-verified":
        raise SystemExit("displayed-pixel replay verification did not pass")
    completed.append("replay-verified-displayed-pixel-evidence")
    gpu_display_verification_sha256 = __import__("hashlib").sha256(
        Path(gpu_display_verification_path).read_bytes()
    ).hexdigest()
record = {
    "kind": "dev.dory.arm-ubuntu-scenario-driver-readiness",
    "schemaVersion": 1,
    "status": "FAIL",
    "machine": machine,
    "machService": service,
    "timeoutSeconds": int(timeout),
    "missingAuthorities": [
        "daemon-storage-fault-injection",
        "daemon-mapped-page-retry-injection",
    ],
    "completedAuthorities": completed,
    "framebufferSHA256": capture["framebufferSHA256"],
    "windowReceiptSHA256": capture["windowReceiptSHA256"],
    "metalCommandBufferCompletionID": capture["metalCommandBufferCompletionID"],
    "inputScriptSHA256": keyboard["scriptSHA256"],
    "guestCommandTransport": {
        "schema": command["schema"],
        "version": command["version"],
        "exitCode": command["exitCode"],
    },
    "inputCommandSequence": {
        "first": keyboard["firstCommandSequence"],
        "last": keyboard["lastCommandSequence"],
    },
    "detail": (
        "The signed candidate displayed one machine-scoped Metal frame and the isolated broker "
        "accepted the bounded keyboard script. Installer navigation and fault phases remain "
        "unverified; no PASS was synthesized for them."
    ),
}
if probe_sha256 is not None:
    record["gpuProbeSHA256"] = probe_sha256
if correlation_sha256 is not None:
    record["graphicsCorrelationSHA256"] = correlation_sha256
if gpu_display_sha256 is not None:
    record["gpuDisplayedPixelEvidenceSHA256"] = gpu_display_sha256
if gpu_display_verification_sha256 is not None:
    record["gpuDisplayedPixelVerificationSHA256"] = gpu_display_verification_sha256
Path(path).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY

die "required installer/fault campaign phases are incomplete; retained authenticated input, guest command, machine-scoped capture, and readiness evidence"
