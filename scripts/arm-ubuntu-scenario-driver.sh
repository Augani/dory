#!/bin/bash
# Fail-closed entry point for the physical ARM Ubuntu qualification scenario.
#
# The old file was an evidence scaffold: it copied an unrelated PNG and emitted unconditional
# PASS JSON for installer, reboot, package, storage, and fault phases. That output was not runtime
# evidence and must never be accepted by the signed campaign gate.
#
# This driver now launches the exact signed candidate in its display-only qualification mode and
# captures the exact campaign-owned Dory window after a Metal-completed frame. It remains
# fail-closed until checkpointed navigation and both signed-policy fault witnesses pass.
# The installed-disk lifecycle runner executes real reboot, package and snapshot phases.
# Keyboard commands are delivered only by the signed app through the isolated display broker.
set -euo pipefail

APP=""
CTL=""
MACH_SERVICE=""
MACHINE=""
RUN_DIR=""
GUEST_COMMAND=""
EXPECTED_OUTPUT=""
PROBE_RESULT_COMMAND=""
PROBE_BUILD_RECEIPT_COMMAND=""
PROBE_NONCE=""
COMPONENT_CANDIDATE_INVENTORY_SHA256=""
PROBE_READY_FILE=""
GRAPHICS_TRACE=""
INPUT_SCRIPT=""
LIFECYCLE_INPUT_SCRIPT=""
NAVIGATION_PLAN=""
RENDERER_RECOVERY_PLAN=""
RENDERER_RECOVERY_MODE=controlled-restart
MAPPED_PAGE_FAULT=0
FULL_FLUSH_FAULT=0
CAPTURE_ONLY=0
GUEST_ARCHITECTURE=arm64
PROBE_ARCHITECTURE=aarch64
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
  --capture-only          Capture/replay one GPU redraw; never emits outer campaign PASS
  --guest-architecture arm64|x86_64
                           PC ISA is allowed only for isolated capture-only redraws
  --renderer-recovery-plan PATH
                           Source-bound before/after GPU redraw and same-boot restart witness
  --renderer-recovery-mode controlled-restart|unexpected-worker-crash
                           Abrupt mode requires an explicit signed renderer fault policy
  --navigation-plan PATH   Six checkpoint UEFI/GRUB plan; generated nonce must reach Linux
  --mapped-page-fault      Run the source-bound mapped-page witness (requires signed fault policy)
  --full-flush-fault       Observe guest root flush IOERR and cold byte recovery (signed policy)
  --lifecycle-input-script PATH
                           Separate balanced key script for installed-desktop login after boot
  --probe-result-command COMMAND
                           Read one dev.dory.gpu-probe JSON object from the guest
  --probe-build-receipt-command COMMAND
                           Read the probe build-receipt.txt from the same guest
  --probe-nonce NONCE      Exact nonce required in that GPU probe result
  --component-candidate-inventory-sha256 SHA256
                           Candidate inventory bound to the GPU challenge
  --probe-ready-file PATH  Run-owned guest marker created after GPU presentation
  --graphics-trace PATH    Runner graphics-trace.ndjson to correlate and retain
  --timeout-seconds N      Per-operation deadline (default: 900)
  --help

This in-tree driver retains a machine-scoped Dory-window capture and an app-authored receipt for
keyboard commands accepted by the isolated display broker. It still fails closed for unexecuted
installer-navigation and fault-injection phases. Once input and GPU capture finish, the installed
disk is checked through media ejection, offline/online cold boots, guest reboot, package updates
and exact snapshot byte recovery using the normal daemon APIs.
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
    --probe-build-receipt-command) need_value "$1" "$#"; PROBE_BUILD_RECEIPT_COMMAND="$2"; shift 2 ;;
    --probe-nonce) need_value "$1" "$#"; PROBE_NONCE="$2"; shift 2 ;;
    --component-candidate-inventory-sha256) need_value "$1" "$#"; COMPONENT_CANDIDATE_INVENTORY_SHA256="$2"; shift 2 ;;
    --probe-ready-file) need_value "$1" "$#"; PROBE_READY_FILE="$2"; shift 2 ;;
    --graphics-trace) need_value "$1" "$#"; GRAPHICS_TRACE="$2"; shift 2 ;;
    --input-script) need_value "$1" "$#"; INPUT_SCRIPT="$2"; shift 2 ;;
    --lifecycle-input-script) need_value "$1" "$#"; LIFECYCLE_INPUT_SCRIPT="$2"; shift 2 ;;
    --navigation-plan) need_value "$1" "$#"; NAVIGATION_PLAN="$2"; shift 2 ;;
    --renderer-recovery-plan) need_value "$1" "$#"; RENDERER_RECOVERY_PLAN="$2"; shift 2 ;;
    --renderer-recovery-mode) need_value "$1" "$#"; RENDERER_RECOVERY_MODE="$2"; shift 2 ;;
    --mapped-page-fault) MAPPED_PAGE_FAULT=1; shift ;;
    --full-flush-fault) FULL_FLUSH_FAULT=1; shift ;;
    --capture-only) CAPTURE_ONLY=1; shift ;;
    --guest-architecture) need_value "$1" "$#"; GUEST_ARCHITECTURE="$2"; shift 2 ;;
    --timeout-seconds) need_value "$1" "$#"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$GUEST_ARCHITECTURE" in
  arm64) ;;
  x86_64) [ "$CAPTURE_ONLY" = 1 ] || die "PC capture cannot execute the ARM install/lifecycle/fault campaign"; PROBE_ARCHITECTURE=x86_64 ;;
  *) die "unsupported guest architecture" ;;
esac

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
if [ "$CAPTURE_ONLY" = 0 ]; then
  [ -n "$INPUT_SCRIPT" ] || die "--input-script is required"
else
  [ -z "$INPUT_SCRIPT" ] && [ -z "$NAVIGATION_PLAN" ] && [ -z "$LIFECYCLE_INPUT_SCRIPT" ] \
    && [ "$MAPPED_PAGE_FAULT" = 0 ] && [ "$FULL_FLUSH_FAULT" = 0 ] && [ -z "$RENDERER_RECOVERY_PLAN" ] \
    || die "capture-only cannot execute input, install, lifecycle or fault phases"
  if [ "$GUEST_ARCHITECTURE" = arm64 ]; then
    [[ "$MACHINE" =~ ^readiness-arm-ubuntu-[a-zA-Z0-9-]+$ ]] \
      && [ "$MACH_SERVICE" = "dev.dory.readiness.armubuntu.${MACHINE#readiness-arm-ubuntu-}" ] \
      || die "capture-only is restricted to the isolated ARM campaign"
  else
    [[ "$MACHINE" =~ ^wave0-pc-gpu-[a-zA-Z0-9-]+$ ]] \
      && [ "$MACH_SERVICE" = "dev.dory.wave0.pcgpu.${MACHINE#wave0-pc-gpu-}" ] \
      || die "PC capture-only is restricted to the isolated PC campaign"
  fi
  [ -n "$PROBE_NONCE" ] || die "capture-only requires a challenged GPU probe"
fi
if { [ -z "$PROBE_RESULT_COMMAND" ] && [ -n "$PROBE_NONCE" ]; } \
    || { [ -n "$PROBE_RESULT_COMMAND" ] && [ -z "$PROBE_NONCE" ]; }; then
  die "--probe-result-command and --probe-nonce must be supplied together"
fi
if { [ -z "$PROBE_BUILD_RECEIPT_COMMAND" ] && [ -n "$PROBE_NONCE" ]; } \
    || { [ -n "$PROBE_BUILD_RECEIPT_COMMAND" ] && [ -z "$PROBE_NONCE" ]; }; then
  die "--probe-build-receipt-command is required with a GPU probe"
fi
if { [ -z "$PROBE_READY_FILE" ] && [ -n "$PROBE_NONCE" ]; } \
    || { [ -n "$PROBE_READY_FILE" ] && [ -z "$PROBE_NONCE" ]; }; then
  die "--probe-ready-file is required with a GPU probe"
fi
if [ -n "$PROBE_NONCE" ]; then
  [[ "$PROBE_NONCE" =~ ^[0-9a-f]{32}$ ]] \
    || die "--probe-nonce must be a fresh 128-bit lowercase hex value"
  [[ "$COMPONENT_CANDIDATE_INVENTORY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "--component-candidate-inventory-sha256 is required with a GPU probe"
  case "$PROBE_READY_FILE" in /*) ;; *) die "--probe-ready-file must be absolute" ;; esac
  [ "${#PROBE_READY_FILE}" -le 4096 ] \
    || die "--probe-ready-file is too long"
fi
[ -n "$PROBE_NONCE" ] || [ -z "$COMPONENT_CANDIDATE_INVENTORY_SHA256" ] \
  || die "--component-candidate-inventory-sha256 requires a GPU probe"
if [ -n "$GRAPHICS_TRACE" ]; then
  case "$GRAPHICS_TRACE" in /*) ;; *) die "--graphics-trace must be absolute" ;; esac
fi
[ -z "$PROBE_NONCE" ] || [ -n "$GRAPHICS_TRACE" ] \
  || die "--graphics-trace is required when retaining a GPU probe"
if [ -n "$RENDERER_RECOVERY_PLAN" ]; then
  [ -f "$RENDERER_RECOVERY_PLAN" ] && [ ! -L "$RENDERER_RECOVERY_PLAN" ] && [ -n "$GRAPHICS_TRACE" ] \
    || die "renderer recovery requires a direct redraw plan and exact runtime graphics trace"
  RENDERER_RECOVERY_PLAN="$(cd "$(dirname "$RENDERER_RECOVERY_PLAN")" && pwd -P)/$(basename "$RENDERER_RECOVERY_PLAN")"
fi
case "$RENDERER_RECOVERY_MODE" in
  controlled-restart) ;;
  unexpected-worker-crash) [ -n "$RENDERER_RECOVERY_PLAN" ] \
    || die "unexpected renderer crash requires a redraw plan and signed fault policy" ;;
  *) die "unknown renderer recovery mode: $RENDERER_RECOVERY_MODE" ;;
esac
if [ "$CAPTURE_ONLY" = 0 ]; then
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
fi
command -v jq >/dev/null || die "jq is required"
GUEST_EXEC_ENV=()
if [ -n "$PROBE_NONCE" ]; then
  GUEST_EXEC_ENV+=(env "DORY_GPU_PROBE_NONCE=$PROBE_NONCE" "DORY_GPU_PROBE_READY_FILE=$PROBE_READY_FILE")
fi
GUEST_EXEC_ENV_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${GUEST_EXEC_ENV[@]}")"
if [ -n "$LIFECYCLE_INPUT_SCRIPT" ]; then
  [ -f "$LIFECYCLE_INPUT_SCRIPT" ] && [ ! -L "$LIFECYCLE_INPUT_SCRIPT" ] \
    || die "--lifecycle-input-script must be a direct file"
  LIFECYCLE_INPUT_SCRIPT="$(cd "$(dirname "$LIFECYCLE_INPUT_SCRIPT")" && pwd -P)/$(basename "$LIFECYCLE_INPUT_SCRIPT")"
fi
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive integer"
[ "$TIMEOUT_SECONDS" -le 7200 ] || die "timeout must not exceed 7200 seconds"
case "$RUN_DIR" in /*) ;; *) die "--run-directory must be absolute" ;; esac
mkdir -p "$RUN_DIR"
[ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] \
  || die "--run-directory must be a direct directory"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
NAVIGATION_RUNNER="$(cd "$(dirname "$0")" && pwd -P)/arm-ubuntu-installer-navigation.py"
[ -f "$NAVIGATION_RUNNER" ] && [ ! -L "$NAVIGATION_RUNNER" ] \
  || die "installer navigation runner is unavailable"
NAVIGATION_RUNNER_SHA256="$(shasum -a 256 "$NAVIGATION_RUNNER" | awk '{print $1}')"
NAVIGATION_STATUS=not-run
if [ -n "$NAVIGATION_PLAN" ]; then
  [ -f "$NAVIGATION_PLAN" ] && [ ! -L "$NAVIGATION_PLAN" ] \
    || die "--navigation-plan must be a direct file"
  for output in "$RUN_DIR/installer-navigation-verification.json" "$RUN_DIR/installer-navigation.err" \
      "$RUN_DIR/uefi-grub-input.json"; do
    [ ! -e "$output" ] && [ ! -L "$output" ] || die "refusing pre-existing navigation output: $output"
  done
  python3 "$NAVIGATION_RUNNER" --app "$APP" --machine "$MACHINE" \
    --mach-service "$MACH_SERVICE" --run-directory "$RUN_DIR" \
    --navigation-plan "$NAVIGATION_PLAN" --timeout-seconds "$TIMEOUT_SECONDS" \
    --confirm EXACT-DORY-ARM-INSTALLER-NAVIGATION \
    > "$RUN_DIR/installer-navigation-verification.json" 2> "$RUN_DIR/installer-navigation.err" \
    || die "source-bound UEFI/GRUB navigation failed; retained its checkpoint diagnostics"
  [ "$(shasum -a 256 "$NAVIGATION_RUNNER" | awk '{print $1}')" = "$NAVIGATION_RUNNER_SHA256" ] \
    || die "navigation runner changed during execution"
  NAVIGATION_STATUS=0
fi
mkdir -p "$RUN_DIR/home"
[ -d "$RUN_DIR/home" ] && [ ! -L "$RUN_DIR/home" ] \
  || die "campaign home must be a direct directory"
chmod 0700 "$RUN_DIR/home"

WINDOW_RECEIPT="$RUN_DIR/display-window.json"
CAPTURE_FRAME_REQUEST="$RUN_DIR/display-capture-frame.request"
CAPTURE_FRAME_RELEASED="$RUN_DIR/display-capture-frame.released"
CAPTURE_FRAME_RECEIPT="$RUN_DIR/display-capture-frame.json"
INPUT_RECEIPT="$RUN_DIR/display-input.json"
FRAMEBUFFER="$RUN_DIR/framebuffer.png"
CAPTURE_RECEIPT="$RUN_DIR/window-capture.json"
GUEST_COMMAND_TRANSPORT="$RUN_DIR/guest-command-transport.json"
GUEST_COMMAND_RESULT="$RUN_DIR/guest-command.json"
GPU_PROBE_TRANSPORT=""
GPU_PROBE_RESULT=""
GPU_PROBE_BUILD_TRANSPORT=""
GPU_PROBE_BUILD_RECEIPT=""
GPU_PROBE_READY_TRANSPORT=""
GPU_DISPLAY_EVIDENCE=""
GPU_DISPLAY_VERIFICATION=""
CAMPAIGN_CHALLENGE=""
PIXEL_ORACLE_RESULT=""
GRAPHICS_TRACE_COPY=""
GRAPHICS_CORRELATION=""
for output in "$WINDOW_RECEIPT" "$CAPTURE_FRAME_REQUEST" "$CAPTURE_FRAME_RELEASED" \
    "$CAPTURE_FRAME_RECEIPT" \
    "$INPUT_RECEIPT" "$FRAMEBUFFER" "$CAPTURE_RECEIPT" \
    "$GUEST_COMMAND_TRANSPORT" "$GUEST_COMMAND_RESULT" \
    "$RUN_DIR/scenario-driver-readiness.json"; do
  [ ! -e "$output" ] && [ ! -L "$output" ] \
    || die "refusing pre-existing scenario output: $output"
done
if [ -n "$PROBE_NONCE" ]; then
  GPU_PROBE_TRANSPORT="$RUN_DIR/gpu-probe-transport.json"
  GPU_PROBE_RESULT="$RUN_DIR/gpu-probe.json"
  GPU_PROBE_BUILD_TRANSPORT="$RUN_DIR/gpu-probe-build-transport.json"
  GPU_PROBE_BUILD_RECEIPT="$RUN_DIR/gpu-probe-build-receipt.txt"
  GPU_PROBE_READY_TRANSPORT="$RUN_DIR/gpu-probe-ready-transport.json"
  GPU_DISPLAY_EVIDENCE="$RUN_DIR/gpu-display-evidence.json"
  GPU_DISPLAY_VERIFICATION="$RUN_DIR/gpu-display-verification.json"
  CAMPAIGN_CHALLENGE="$RUN_DIR/campaign-challenge.json"
  PIXEL_ORACLE_RESULT="$RUN_DIR/pixel-oracle.json"
  for output in "$GPU_PROBE_TRANSPORT" "$GPU_PROBE_RESULT" \
      "$GPU_PROBE_BUILD_TRANSPORT" "$GPU_PROBE_BUILD_RECEIPT" \
      "$GPU_PROBE_READY_TRANSPORT" \
      "$GPU_DISPLAY_EVIDENCE" "$GPU_DISPLAY_VERIFICATION" "$PIXEL_ORACLE_RESULT" \
      "$CAMPAIGN_CHALLENGE"; do
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
    local app_exit_deadline=$((SECONDS + 5))
    while kill -0 "$APP_PID" 2>/dev/null && [ "$SECONDS" -lt "$app_exit_deadline" ]; do
      sleep 0.1
    done
    kill -0 "$APP_PID" 2>/dev/null && kill -KILL "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

INPUT_ENV=()
if [ "$CAPTURE_ONLY" = 0 ]; then
  INPUT_ENV+=("DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT=$INPUT_SCRIPT" \
              "DORY_DISPLAY_QUALIFICATION_INPUT_RECEIPT=$INPUT_RECEIPT")
fi
HOME="$RUN_DIR/home" \
DORYD_MACH_SERVICE="$MACH_SERVICE" \
DORY_DISPLAY_QUALIFICATION_MACHINE_ID="$MACHINE" \
DORY_DISPLAY_QUALIFICATION_SCANOUT_ID=0 \
DORY_DISPLAY_QUALIFICATION_WINDOW_RECEIPT="$WINDOW_RECEIPT" \
DORY_DISPLAY_QUALIFICATION_CAPTURE_REQUEST="$CAPTURE_FRAME_REQUEST" \
DORY_DISPLAY_QUALIFICATION_CAPTURE_RECEIPT="$CAPTURE_FRAME_RECEIPT" \
  env "${INPUT_ENV[@]}" "$APP_EXECUTABLE" > "$RUN_DIR/display-app.out" 2> "$RUN_DIR/display-app.err" &
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
  .kind == "dev.dory.display-qualification-window" and .schemaVersion == 2
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .scanoutID == 0 and .machServiceName == $service
  and .windowTitle == ("Dory — " + $machine + " — Display 1")
  and (.windowNumber | type == "number" and . > 0)
  and (.frameSequence | type == "number" and . > 0)
  and (.displayResourceGeneration | type == "number" and . > 0)
  and (.metalCommandBufferCompletionID | type == "number" and . > 0)
  and .guestViewport.coordinateSpace == "capture-pixels-top-left"
  and (.guestViewport.x | type == "number" and . >= 0)
  and (.guestViewport.y | type == "number" and . >= 0)
  and (.guestViewport.width | type == "number" and . > 0)
  and (.guestViewport.height | type == "number" and . > 0)
  and (.guestViewport.sourceX | type == "number" and . >= 0)
  and (.guestViewport.sourceY | type == "number" and . >= 0)
  and (.guestViewport.sourceWidth | type == "number" and . > 0)
  and (.guestViewport.sourceHeight | type == "number" and . > 0)
  and (.guestViewport.backingScaleFactor | type == "number" and . >= 0.5 and . <= 4)
  and .guestViewport.colorSpace == "sRGB"
  and (.transport == "sharedMemory" or .transport == "sharedTexture")
' "$WINDOW_RECEIPT" >/dev/null || die "display qualification window receipt is invalid"
if [ -n "$PROBE_NONCE" ]; then
  python3 - "$CAMPAIGN_CHALLENGE" "$WINDOW_RECEIPT" \
    "$COMPONENT_CANDIDATE_INVENTORY_SHA256" "$PROBE_NONCE" <<'PY'
import json
import os
import sys
from pathlib import Path

output, window_path = map(Path, sys.argv[1:3])
window = json.loads(window_path.read_text(encoding="utf-8"))
challenge = {
    "candidateID": sys.argv[3],
    "kind": "dev.dory.gpu-campaign-challenge",
    "machineID": window["machineID"],
    "nonce": sys.argv[4],
    "operationID": window["operationID"],
    "schemaVersion": 1,
}
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(descriptor, "wb") as target:
    target.write((json.dumps(challenge, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
PY
fi
deadline=$((SECONDS + TIMEOUT_SECONDS))
if [ "$CAPTURE_ONLY" = 0 ]; then
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
fi
HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
  machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
  --output-limit-bytes 4194304 -- "${GUEST_EXEC_ENV[@]}" sh -ec "$GUEST_COMMAND" \
  > "$GUEST_COMMAND_TRANSPORT" 2> "$RUN_DIR/guest-command.err" \
  || die "guest command transport failed"
jq -e --arg machine "$MACHINE" --arg command "$GUEST_COMMAND" \
  --arg expected "$EXPECTED_OUTPUT" --argjson environment "$GUEST_EXEC_ENV_JSON" '
  .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
  and .argv == ($environment + ["sh", "-ec", $command])
  and .exitCode == 0 and .timedOut == false
  and .stdoutTruncated == false and .stderrTruncated == false
  and .stdout == $expected
' "$GUEST_COMMAND_TRANSPORT" >/dev/null \
  || die "guest command did not complete with the exact expected output"
jq '. + {status: "PASS"}' "$GUEST_COMMAND_TRANSPORT" > "$GUEST_COMMAND_RESULT"

if [ -n "$PROBE_NONCE" ]; then
  HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
    machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
    --output-limit-bytes 256 -- cat "$PROBE_READY_FILE" \
    > "$GPU_PROBE_READY_TRANSPORT" 2> "$RUN_DIR/gpu-probe-ready.err" \
    || die "presented GPU probe marker transport failed"
  jq -e --arg machine "$MACHINE" --arg path "$PROBE_READY_FILE" '
    .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
    and .argv == ["cat", $path]
    and .exitCode == 0 and .timedOut == false
    and .stdoutTruncated == false and .stderrTruncated == false
    and (.stdout | type == "string" and startswith("dory-visual-presented:fnv1a64:"))
  ' "$GPU_PROBE_READY_TRANSPORT" >/dev/null \
    || die "GPU probe did not publish its presented-frame marker"
  python3 - "$GPU_PROBE_READY_TRANSPORT" "$PROBE_NONCE" \
    "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/pixel-oracle.py" <<'PY'
import importlib.util
import json
import re
import sys
from pathlib import Path

receipt_path, nonce, oracle_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("dory_pixel_oracle", oracle_path)
if spec is None or spec.loader is None:
    raise SystemExit("GPU ready-marker oracle is unavailable")
oracle = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = oracle
spec.loader.exec_module(oracle)
receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
marker = receipt["stdout"]
match = re.fullmatch(r"dory-visual-presented:fnv1a64:([0-9a-f]{16}):([1-9][0-9]{0,4})\n", marker)
if match is None:
    raise SystemExit("GPU ready marker has no canonical challenge/frame binding")
frame = int(match.group(2))
if not 0 < frame <= 0xFFFF:
    raise SystemExit("GPU ready marker frame is outside the supported range")
expected = f"dory-visual-presented:fnv1a64:{oracle.fnv1a64(nonce, frame):016x}:{frame}\n"
if marker != expected:
    raise SystemExit("GPU ready marker belongs to another nonce or frame")
PY
fi

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
  .kind == "dev.dory.display-qualification-window" and .schemaVersion == 2
  and .bundleIdentifier == "com.pythonxi.Dory" and .processID == $pid
  and .machineID == $machine and .scanoutID == 0 and .machServiceName == $service
  and .operationID == $operation
  and .windowTitle == ("Dory — " + $machine + " — Display 1")
  and (.windowNumber | type == "number" and . > 0)
  and (.frameSequence | type == "number" and . > 0)
  and (.displayResourceGeneration | type == "number" and . > 0)
  and (.metalCommandBufferCompletionID | type == "number")
  and .metalCommandBufferCompletionID > $first_completion
  and .framePollingHeldForCapture == true
  and (.transport == "sharedMemory" or .transport == "sharedTexture")
' "$CAPTURE_FRAME_RECEIPT" >/dev/null \
  || die "display qualification capture-frame receipt is invalid"
WINDOW_NUMBER="$(jq -r '.windowNumber' "$CAPTURE_FRAME_RECEIPT")"
/usr/sbin/screencapture -x -o -l"$WINDOW_NUMBER" "$FRAMEBUFFER" \
  || die "WindowServer could not capture the campaign Dory window"
mv -n "$CAPTURE_FRAME_REQUEST" "$CAPTURE_FRAME_RELEASED" \
  || die "could not release the held qualification frame after capture"
[ ! -e "$CAPTURE_FRAME_REQUEST" ] && [ -f "$CAPTURE_FRAME_RELEASED" ] \
  || die "qualification frame release did not move the owned request marker"
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
if len(payload) < 24 or payload[12:16] != b"IHDR":
    raise SystemExit("captured Dory window has no canonical PNG IHDR")
width = int.from_bytes(payload[16:20], "big")
height = int.from_bytes(payload[20:24], "big")
window = json.loads(capture_frame_receipt.read_text(encoding="utf-8"))
receipt = {
    "kind": "dev.dory.machine-window-capture",
    "schemaVersion": 2,
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
    "framePollingHeldForCapture": window["framePollingHeldForCapture"],
    "captureWidth": width,
    "captureHeight": height,
    "guestViewport": window["guestViewport"],
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
    "$GRAPHICS_CORRELATION" \
    "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/graphics-trace-chain.py" <<'PY'
import datetime
import hashlib
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path

source, retained, capture_path, output, chain_module_path = map(Path, sys.argv[1:])
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
spec = importlib.util.spec_from_file_location("dory_graphics_trace_chain", chain_module_path)
if spec is None or spec.loader is None:
    raise SystemExit("accelerated graphics trace verifier is unavailable")
chain_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chain_module)
try:
    chain = chain_module.verify(events, capture)
except chain_module.TraceChainError as error:
    raise SystemExit(f"retained graphics trace lacks an accelerated frame chain: {error}")
record = {
    "kind": "dev.dory.display-graphics-correlation",
    "schemaVersion": 3,
    "status": "PASS",
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machineID": capture["machineID"],
    "operationID": capture["operationID"],
    "frameSequence": capture["frameSequence"],
    "displayResourceGeneration": capture["displayResourceGeneration"],
    "metalCommandBufferCompletionID": capture["metalCommandBufferCompletionID"],
    **chain,
    "framebufferSHA256": capture["framebufferSHA256"],
    "graphicsTraceSHA256": hashlib.sha256(retained.read_bytes()).hexdigest(),
}
output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
fi

if [ -n "$PROBE_NONCE" ]; then
  HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
    machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
    --output-limit-bytes 65536 -- "${GUEST_EXEC_ENV[@]}" sh -ec "$PROBE_BUILD_RECEIPT_COMMAND" \
    > "$GPU_PROBE_BUILD_TRANSPORT" 2> "$RUN_DIR/gpu-probe-build.err" \
    || die "GPU probe build receipt transport failed"
  jq -e --arg machine "$MACHINE" --arg command "$PROBE_BUILD_RECEIPT_COMMAND" --argjson environment "$GUEST_EXEC_ENV_JSON" '
    .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
    and .argv == ($environment + ["sh", "-ec", $command])
    and .exitCode == 0 and .timedOut == false
    and .stdoutTruncated == false and .stderrTruncated == false
  ' "$GPU_PROBE_BUILD_TRANSPORT" >/dev/null \
    || die "GPU probe build receipt transport envelope is invalid"
  jq -ejr '.stdout | select(type == "string" and length > 0)' "$GPU_PROBE_BUILD_TRANSPORT" > "$GPU_PROBE_BUILD_RECEIPT" \
    || die "GPU probe build receipt transport did not contain UTF-8 text"
  python3 "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/verify-build-receipt.py" \
    --source-directory "$(cd "$(dirname "$0")/../guest-probes" && pwd -P)" \
    --architecture "$PROBE_ARCHITECTURE" "$GPU_PROBE_BUILD_RECEIPT" >/dev/null \
    || die "GPU probe build receipt disagrees with the current source tuple"
  HOME="$RUN_DIR/home" "$CTL" --mach-service "$MACH_SERVICE" --timeout "$TIMEOUT_SECONDS" \
    machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
    --output-limit-bytes 4194304 -- "${GUEST_EXEC_ENV[@]}" sh -ec "$PROBE_RESULT_COMMAND" \
    > "$GPU_PROBE_TRANSPORT" 2> "$RUN_DIR/gpu-probe.err" \
    || die "GPU probe result transport failed"
  jq -e --arg machine "$MACHINE" --arg command "$PROBE_RESULT_COMMAND" --argjson environment "$GUEST_EXEC_ENV_JSON" '
    .schema == "dev.dory.machine.exec" and .version == 1 and .machine == $machine
    and .argv == ($environment + ["sh", "-ec", $command])
    and .exitCode == 0 and .timedOut == false
    and .stdoutTruncated == false and .stderrTruncated == false
  ' "$GPU_PROBE_TRANSPORT" >/dev/null \
    || die "GPU probe result transport envelope is invalid"
  jq -ejr '.stdout | select(type == "string" and length > 0)' "$GPU_PROBE_TRANSPORT" > "$GPU_PROBE_RESULT" \
    || die "GPU probe result transport did not contain UTF-8 JSON"
  python3 "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/validate-result.py" \
    --nonce "$PROBE_NONCE" "$GPU_PROBE_RESULT" >/dev/null \
    || die "GPU probe result failed campaign validation"
  jq -e --arg path "$PROBE_READY_FILE" \
    --slurpfile ready "$GPU_PROBE_READY_TRANSPORT" '
    .presentedReadyFile == $path
    and (.presentedHoldMilliseconds | type == "number" and . >= 5000 and . <= 30000)
    and $ready[0].stdout == (
      "dory-visual-presented:" + .visualChallenge.payloadHash
      + ":" + (.frameCount | tostring) + "\n"
    )
  ' "$GPU_PROBE_RESULT" >/dev/null \
    || die "GPU probe result does not bind the challenged presented marker and capture hold"
  PIXEL_ORACLE_PAYLOAD="$(
    python3 "$(cd "$(dirname "$0")/.." && pwd -P)/guest-probes/pixel-oracle.py" \
      --nonce "$PROBE_NONCE" \
      --frame-marker "$(jq -r '.frameCount' "$GPU_PROBE_RESULT")" \
      --viewport-json "$CAPTURE_RECEIPT" \
      --probe-json "$GPU_PROBE_RESULT" "$FRAMEBUFFER"
  )" || die "captured Dory window failed the independent pixel oracle"
  python3 - "$PIXEL_ORACLE_RESULT" "$PIXEL_ORACLE_PAYLOAD" <<'PY'
import os
import sys

descriptor = os.open(
    sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
)
with os.fdopen(descriptor, "w", encoding="utf-8") as target:
    target.write(sys.argv[2] + "\n")
PY
  python3 - "$GPU_PROBE_RESULT" "$GPU_PROBE_BUILD_RECEIPT" \
    "$GPU_PROBE_READY_TRANSPORT" \
    "$CAPTURE_RECEIPT" "$GRAPHICS_CORRELATION" \
    "$PIXEL_ORACLE_RESULT" "$CAPTURE_FRAME_RELEASED" "$GPU_DISPLAY_EVIDENCE" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

probe_path, build_path, ready_path, capture_path, correlation_path, oracle_path, release_path, output = map(
    Path, sys.argv[1:]
)
probe = json.loads(probe_path.read_text(encoding="utf-8"))
capture = json.loads(capture_path.read_text(encoding="utf-8"))
correlation = json.loads(correlation_path.read_text(encoding="utf-8"))
oracle = json.loads(oracle_path.read_text(encoding="utf-8"))
if correlation.get("status") != "PASS":
    raise SystemExit("graphics correlation is not passing")
if correlation.get("schemaVersion") != 3:
    raise SystemExit("graphics correlation lacks an accelerated frame chain")
if oracle.get("status") != "PASS":
    raise SystemExit("pixel oracle is not passing")
for key in (
    "machineID", "operationID", "displayResourceGeneration",
    "metalCommandBufferCompletionID", "framebufferSHA256",
):
    if correlation.get(key) != capture.get(key):
        raise SystemExit(f"graphics correlation disagrees with capture for {key}")
record = {
    "kind": "dev.dory.gpu-displayed-pixel-evidence",
    "schemaVersion": 3,
    "status": "PASS",
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machineID": capture["machineID"],
    "operationID": capture["operationID"],
    "frameSequence": capture["frameSequence"],
    "probe": probe["probe"],
    "probeNonce": probe["nonce"],
    "probeResultHash": probe["resultHash"],
    "deviceName": probe["deviceName"],
    "driver": probe["driver"],
    "frameCount": probe["frameCount"],
    "visualChallenge": probe["visualChallenge"],
    "probeSHA256": hashlib.sha256(probe_path.read_bytes()).hexdigest(),
    "probeBuildReceiptSHA256": hashlib.sha256(build_path.read_bytes()).hexdigest(),
    "probePresentedReadyFile": probe["presentedReadyFile"],
    "probeReadyTransportSHA256": hashlib.sha256(ready_path.read_bytes()).hexdigest(),
    "framebufferSHA256": capture["framebufferSHA256"],
    "windowReceiptSHA256": capture["windowReceiptSHA256"],
    "captureReceiptSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "captureReleaseSHA256": hashlib.sha256(release_path.read_bytes()).hexdigest(),
    "graphicsTraceSHA256": correlation["graphicsTraceSHA256"],
    "graphicsCorrelationSHA256": hashlib.sha256(
        correlation_path.read_bytes()
    ).hexdigest(),
    "pixelOracleSHA256": hashlib.sha256(oracle_path.read_bytes()).hexdigest(),
    "displayResourceGeneration": capture["displayResourceGeneration"],
    "metalCommandBufferCompletionID": capture["metalCommandBufferCompletionID"],
    **{key: correlation[key] for key in (
        "workerGeneration", "resourceID", "rendererResourceGeneration",
        "deviceGeneration", "graphicsFrameSequence", "graphicsSurfaceWidth",
        "graphicsSurfaceHeight", "scanoutPublishedTraceSequence",
        "hostSubmissionTraceSequence", "graphicsTraceSequence",
    )},
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

# The initial held GPU frame has already been retained and replay-verified. Close only the app
# launched by this driver before cycling the VM; each lifecycle phase opens a new app process
# and requires its current-operation Metal window receipt.
cleanup
APP_PID=""
if [ "$CAPTURE_ONLY" = 1 ]; then
  [ -s "$GPU_DISPLAY_VERIFICATION" ] || die "capture-only has no independent GPU pixel replay"
  jq -e '.status == "evidence-verified"' "$GPU_DISPLAY_VERIFICATION" >/dev/null \
    || die "capture-only GPU replay did not pass"
  exit 0
fi
LIFECYCLE_RUNNER="$(cd "$(dirname "$0")" && pwd -P)/arm-ubuntu-desktop-lifecycle.py"
[ -f "$LIFECYCLE_RUNNER" ] && [ ! -L "$LIFECYCLE_RUNNER" ] \
  || die "installed desktop lifecycle runner is unavailable"
LIFECYCLE_RUNNER_SHA256="$(shasum -a 256 "$LIFECYCLE_RUNNER" | awk '{print $1}')"
LIFECYCLE_STATUS=0
LIFECYCLE_ARGUMENTS=()
if [ -n "$LIFECYCLE_INPUT_SCRIPT" ]; then
  LIFECYCLE_ARGUMENTS+=(--login-input-script "$LIFECYCLE_INPUT_SCRIPT")
fi
python3 "$LIFECYCLE_RUNNER" --app "$APP" --mach-service "$MACH_SERVICE" \
  --machine "$MACHINE" --run-directory "$RUN_DIR" --timeout-seconds "$TIMEOUT_SECONDS" \
  --confirm EXACT-DORY-ARM-DESKTOP-LIFECYCLE \
  "${LIFECYCLE_ARGUMENTS[@]}" \
  > "$RUN_DIR/desktop-lifecycle.out" 2> "$RUN_DIR/desktop-lifecycle.err" \
  || LIFECYCLE_STATUS=$?
[ "$(shasum -a 256 "$LIFECYCLE_RUNNER" | awk '{print $1}')" = "$LIFECYCLE_RUNNER_SHA256" ] \
  || die "installed desktop lifecycle runner changed during execution"

FULL_FLUSH_RUNNER="$(cd "$(dirname "$0")" && pwd -P)/arm-ubuntu-full-flush-fault.py"
[ -f "$FULL_FLUSH_RUNNER" ] && [ ! -L "$FULL_FLUSH_RUNNER" ] \
  || die "full-flush fault runner is unavailable"
FULL_FLUSH_RUNNER_SHA256="$(shasum -a 256 "$FULL_FLUSH_RUNNER" | awk '{print $1}')"
FULL_FLUSH_STATUS=not-run
if [ "$FULL_FLUSH_FAULT" = 1 ] && [ "$LIFECYCLE_STATUS" = 0 ]; then
  FULL_FLUSH_STATUS=0
  python3 "$FULL_FLUSH_RUNNER" --app "$APP" --mach-service "$MACH_SERVICE" \
    --machine "$MACHINE" --run-directory "$RUN_DIR" --timeout-seconds "$TIMEOUT_SECONDS" \
    --confirm EXACT-DORY-ARM-FULL-FLUSH-FAULT "${LIFECYCLE_ARGUMENTS[@]}" \
    > "$RUN_DIR/full-flush-fault.out" 2> "$RUN_DIR/full-flush-fault.err" \
    || FULL_FLUSH_STATUS=$?
fi
[ "$(shasum -a 256 "$FULL_FLUSH_RUNNER" | awk '{print $1}')" = "$FULL_FLUSH_RUNNER_SHA256" ] \
  || die "full-flush fault runner changed during execution"

MAPPED_FAULT_RUNNER="$(cd "$(dirname "$0")" && pwd -P)/arm-ubuntu-mapped-page-fault.py"
[ -f "$MAPPED_FAULT_RUNNER" ] && [ ! -L "$MAPPED_FAULT_RUNNER" ] \
  || die "mapped-page fault runner is unavailable"
MAPPED_FAULT_RUNNER_SHA256="$(shasum -a 256 "$MAPPED_FAULT_RUNNER" | awk '{print $1}')"
MAPPED_FAULT_STATUS=not-run
if [ "$MAPPED_PAGE_FAULT" = 1 ] && [ "$LIFECYCLE_STATUS" = 0 ] \
    && { [ "$FULL_FLUSH_FAULT" = 0 ] || [ "$FULL_FLUSH_STATUS" = 0 ]; }; then
  MAPPED_FAULT_STATUS=0
  python3 "$MAPPED_FAULT_RUNNER" --app "$APP" --mach-service "$MACH_SERVICE" \
    --machine "$MACHINE" --run-directory "$RUN_DIR" --timeout-seconds "$TIMEOUT_SECONDS" \
    --confirm EXACT-DORY-ARM-MAPPED-PAGE-FAULT \
    > "$RUN_DIR/mapped-page-fault.out" 2> "$RUN_DIR/mapped-page-fault.err" \
    || MAPPED_FAULT_STATUS=$?
fi
[ "$(shasum -a 256 "$MAPPED_FAULT_RUNNER" | awk '{print $1}')" = "$MAPPED_FAULT_RUNNER_SHA256" ] \
  || die "mapped-page fault runner changed during execution"

RENDERER_RECOVERY_RUNNER="$(cd "$(dirname "$0")" && pwd -P)/arm-ubuntu-renderer-recovery.py"
[ -f "$RENDERER_RECOVERY_RUNNER" ] && [ ! -L "$RENDERER_RECOVERY_RUNNER" ] \
  || die "renderer recovery runner is unavailable"
RENDERER_RECOVERY_RUNNER_SHA256="$(shasum -a 256 "$RENDERER_RECOVERY_RUNNER" | awk '{print $1}')"
RENDERER_RECOVERY_STATUS=not-run
if [ -n "$RENDERER_RECOVERY_PLAN" ] && [ "$LIFECYCLE_STATUS" = 0 ] \
    && { [ "$FULL_FLUSH_FAULT" = 0 ] || [ "$FULL_FLUSH_STATUS" = 0 ]; } \
    && { [ "$MAPPED_PAGE_FAULT" = 0 ] || [ "$MAPPED_FAULT_STATUS" = 0 ]; }; then
  RENDERER_RECOVERY_STATUS=0
  for output in "$RUN_DIR/renderer-recovery.out" "$RUN_DIR/renderer-recovery.err"; do
    [ ! -e "$output" ] && [ ! -L "$output" ] || die "refusing existing renderer recovery output: $output"
  done
  RENDERER_RECOVERY_CONFIRM=EXACT-DORY-ARM-RENDERER-RESTART
  if [ "$RENDERER_RECOVERY_MODE" = unexpected-worker-crash ]; then
    RENDERER_RECOVERY_CONFIRM=EXACT-DORY-ARM-RENDERER-CRASH
  fi
  python3 "$RENDERER_RECOVERY_RUNNER" --app "$APP" --mach-service "$MACH_SERVICE" \
    --machine "$MACHINE" --run-directory "$RUN_DIR" --timeout-seconds "$((TIMEOUT_SECONDS < 1800 ? TIMEOUT_SECONDS : 1800))" \
    --redraw-plan "$RENDERER_RECOVERY_PLAN" --graphics-trace "$GRAPHICS_TRACE" \
    --mode "$RENDERER_RECOVERY_MODE" --confirm "$RENDERER_RECOVERY_CONFIRM" \
    > "$RUN_DIR/renderer-recovery.out" 2> "$RUN_DIR/renderer-recovery.err" \
    || RENDERER_RECOVERY_STATUS=$?
fi
[ "$(shasum -a 256 "$RENDERER_RECOVERY_RUNNER" | awk '{print $1}')" = "$RENDERER_RECOVERY_RUNNER_SHA256" ] \
  || die "renderer recovery runner changed during execution"

python3 - "$RUN_DIR/scenario-driver-readiness.json" \
  "$MACH_SERVICE" "$MACHINE" "$TIMEOUT_SECONDS" "$CAPTURE_RECEIPT" \
  "$INPUT_RECEIPT" "$GUEST_COMMAND_RESULT" "$GPU_PROBE_RESULT" \
  "$GPU_PROBE_BUILD_RECEIPT" "$GPU_PROBE_READY_TRANSPORT" \
  "$CAMPAIGN_CHALLENGE" \
  "$GRAPHICS_CORRELATION" "$GPU_DISPLAY_EVIDENCE" \
  "$GPU_DISPLAY_VERIFICATION" "$RUN_DIR" "$LIFECYCLE_STATUS" "$LIFECYCLE_RUNNER_SHA256" \
  "$MAPPED_FAULT_STATUS" "$MAPPED_FAULT_RUNNER" "$MAPPED_FAULT_RUNNER_SHA256" "$APP" \
  "$FULL_FLUSH_STATUS" "$FULL_FLUSH_RUNNER" "$FULL_FLUSH_RUNNER_SHA256" \
  "$NAVIGATION_STATUS" "$NAVIGATION_RUNNER" "$NAVIGATION_RUNNER_SHA256" \
  "$RENDERER_RECOVERY_STATUS" "$RENDERER_RECOVERY_RUNNER" "$RENDERER_RECOVERY_RUNNER_SHA256" "$RENDERER_RECOVERY_MODE" <<'PY'
import json
import sys
from pathlib import Path

(
    path, service, machine, timeout, capture_path, input_path, command_path,
    probe_path, probe_build_path, probe_ready_path, challenge_path, correlation_path,
    gpu_display_path, gpu_display_verification_path, run_directory, lifecycle_status, lifecycle_runner_sha256,
    mapped_fault_status, mapped_fault_runner, mapped_fault_runner_sha256, app,
    full_flush_status, full_flush_runner, full_flush_runner_sha256,
    navigation_status, navigation_runner, navigation_runner_sha256,
    renderer_status, renderer_runner, renderer_runner_sha256, renderer_mode,
) = sys.argv[1:]
capture = json.loads(Path(capture_path).read_text(encoding="utf-8"))
keyboard = json.loads(Path(input_path).read_text(encoding="utf-8"))
command = json.loads(Path(command_path).read_text(encoding="utf-8"))
completed = [
    "machine-scoped-window-capture",
    "authenticated-machine-keyboard-input",
    "guest-command-over-vsock",
]
missing = [
    "verified-uefi-grub-installer-navigation",
    "daemon-storage-fault-injection",
    "daemon-mapped-page-retry-injection",
    "same-boot-renderer-replacement-and-gpu-redraw",
]
navigation_sha256 = None
if navigation_status == "0":
    import importlib.util
    spec = importlib.util.spec_from_file_location("navigation_replay", navigation_runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    evidence = module.lifecycle.Evidence(Path(run_directory))
    with module.Recognizer() as recognize:
        replay = module.verify_navigation(evidence, machine, service, Path(app), recognize)
        evidence.write("uefi-grub-input.json", module.qualification_record(evidence, machine, service, replay))
    missing.remove("verified-uefi-grub-installer-navigation")
    completed.append("pixel-replayed-uefi-grub-keys-and-fresh-kernel-command-line-challenge")
    navigation_sha256 = __import__("hashlib").sha256((Path(run_directory) / "installer-navigation.json").read_bytes()).hexdigest()
lifecycle_path = Path(run_directory) / "desktop-lifecycle-readiness.json"
lifecycle_sha256 = None
if lifecycle_status == "0":
    lifecycle = json.loads(lifecycle_path.read_text(encoding="utf-8"))
    if (lifecycle.get("kind") != "dev.dory.installed-desktop-lifecycle-readiness"
            or lifecycle.get("status") != "implemented-phases-passed"
            or lifecycle.get("machine") != machine or lifecycle.get("machService") != service
            or lifecycle.get("releaseEligible") is not False):
        raise SystemExit("installed desktop lifecycle receipt is invalid")
    completed.extend([
        "installed-efi-disk-media-ejection",
        "offline-and-online-cold-reopen",
        "in-guest-reboot-with-new-boot-id",
        "guest-package-update-upgrade-install",
        "fsynced-payload-and-exact-snapshot-byte-recovery",
        "replay-verified-installed-desktop-lifecycle",
    ])
    lifecycle_sha256 = __import__("hashlib").sha256(lifecycle_path.read_bytes()).hexdigest()
else:
    missing.append("installed-desktop-lifecycle")
full_flush_sha256 = None
if full_flush_status == "0":
    import importlib.util
    spec = importlib.util.spec_from_file_location("full_flush_replay", full_flush_runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    replay = module.verify_storage(module.lifecycle.Evidence(Path(run_directory)), machine, service, Path(app))
    retained = json.loads((Path(run_directory) / "full-flush-fault.out").read_text(encoding="utf-8"))
    if replay != retained:
        raise SystemExit("full-flush recovery replay differs from retained result")
    missing.remove("daemon-storage-fault-injection")
    completed.append("real-full-flush-ioerr-live-retry-offline-durability-and-snapshot-recovery")
    full_flush_sha256 = __import__("hashlib").sha256((Path(run_directory) / "storage-recovery-qualification.json").read_bytes()).hexdigest()
mapped_fault_sha256 = None
if mapped_fault_status == "0":
    import importlib.util
    spec = importlib.util.spec_from_file_location("mapped_fault_replay", mapped_fault_runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    replay = module.verify_fault(module.lifecycle.Evidence(Path(run_directory)), machine, service, Path(app))
    retained = json.loads((Path(run_directory) / "mapped-page-fault.out").read_text(encoding="utf-8"))
    if replay != retained:
        raise SystemExit("mapped-page fault replay differs from the retained result")
    missing.remove("daemon-mapped-page-retry-injection")
    completed.append("real-mapped-page-retries-guest-fault-and-same-boot-display-recovery")
    mapped_fault_sha256 = __import__("hashlib").sha256((Path(run_directory) / "fault-retry.json").read_bytes()).hexdigest()
renderer_sha256 = None
if renderer_status == "0":
    import importlib.util
    spec = importlib.util.spec_from_file_location("renderer_replay", renderer_runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    replay = module.verify_recovery(module.lifecycle.Evidence(Path(run_directory)), machine, service, Path(app))
    retained = json.loads((Path(run_directory) / "renderer-recovery.out").read_text(encoding="utf-8"))
    if replay != retained or replay.get("mode") != renderer_mode:
        raise SystemExit("renderer recovery replay differs from the retained result")
    missing.remove("same-boot-renderer-replacement-and-gpu-redraw")
    completed.append(("controlled-renderer-restart" if renderer_mode == "controlled-restart" else "unexpected-renderer-worker-crash")
                     + "-same-boot-process-memory-fsync-and-fresh-gpu-pixels")
    renderer_sha256 = __import__("hashlib").sha256((Path(run_directory) / "renderer-recovery.json").read_bytes()).hexdigest()
probe_sha256 = None
if probe_path:
    completed.append("nonce-bound-gpu-probe-over-vsock")
    probe_sha256 = __import__("hashlib").sha256(Path(probe_path).read_bytes()).hexdigest()
probe_build_sha256 = None
if probe_build_path:
    completed.append("guest-probe-build-source-and-binary-hashes")
    probe_build_sha256 = __import__("hashlib").sha256(
        Path(probe_build_path).read_bytes()
    ).hexdigest()
probe_ready_sha256 = None
if probe_ready_path:
    completed.append("guest-presented-frame-marker-over-vsock")
    probe_ready_sha256 = __import__("hashlib").sha256(
        Path(probe_ready_path).read_bytes()
    ).hexdigest()
challenge_sha256 = None
if challenge_path:
    completed.append("candidate-operation-bound-gpu-campaign-challenge")
    challenge_sha256 = __import__("hashlib").sha256(
        Path(challenge_path).read_bytes()
    ).hexdigest()
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
else:
    missing.append("replay-verified-displayed-pixel-evidence")
record = {
    "kind": "dev.dory.arm-ubuntu-scenario-driver-readiness",
    "schemaVersion": 1,
    "status": "PASS" if not missing else "FAIL",
    "machine": machine,
    "machService": service,
    "timeoutSeconds": int(timeout),
    "missingAuthorities": missing,
    "completedAuthorities": completed,
    "installedDesktopLifecycleRunnerSHA256": lifecycle_runner_sha256,
    "mappedPageFaultRunnerSHA256": mapped_fault_runner_sha256,
    "fullFlushFaultRunnerSHA256": full_flush_runner_sha256,
    "installerNavigationRunnerSHA256": navigation_runner_sha256,
    "rendererRecoveryRunnerSHA256": renderer_runner_sha256,
    "rendererRecoveryMode": renderer_mode,
    "releaseEligible": False,
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
        "accepted the bounded keyboard script. Installed-disk lifecycle phases were attempted "
        "through the normal daemon controls; their raw receipts and replay result are retained. "
        "Remaining authorities are listed explicitly; this receipt never grants release admission."
    ),
}
if lifecycle_sha256 is not None:
    record["installedDesktopLifecycleSHA256"] = lifecycle_sha256
if navigation_sha256 is not None:
    record["installerNavigationSHA256"] = navigation_sha256
if mapped_fault_sha256 is not None:
    record["mappedPageFaultSHA256"] = mapped_fault_sha256
if full_flush_sha256 is not None:
    record["fullFlushRecoverySHA256"] = full_flush_sha256
if renderer_sha256 is not None:
    record["rendererRecoverySHA256"] = renderer_sha256
if probe_sha256 is not None:
    record["gpuProbeSHA256"] = probe_sha256
if probe_build_sha256 is not None:
    record["gpuProbeBuildReceiptSHA256"] = probe_build_sha256
if probe_ready_sha256 is not None:
    record["gpuProbeReadyTransportSHA256"] = probe_ready_sha256
if challenge_sha256 is not None:
    record["gpuCampaignChallengeSHA256"] = challenge_sha256
if correlation_sha256 is not None:
    record["graphicsCorrelationSHA256"] = correlation_sha256
if gpu_display_sha256 is not None:
    record["gpuDisplayedPixelEvidenceSHA256"] = gpu_display_sha256
if gpu_display_verification_sha256 is not None:
    record["gpuDisplayedPixelVerificationSHA256"] = gpu_display_verification_sha256
Path(path).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY

if ! jq -e '.status == "PASS" and .missingAuthorities == [] and .releaseEligible == false' \
    "$RUN_DIR/scenario-driver-readiness.json" >/dev/null; then
  die "required campaign authorities are incomplete; retained input, GPU capture, lifecycle, faults and readiness evidence"
fi
