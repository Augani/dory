#!/bin/bash
# Fail-closed entry point for the physical ARM Ubuntu qualification scenario.
#
# The old file was an evidence scaffold: it copied an unrelated PNG and emitted unconditional
# PASS JSON for installer, reboot, package, storage, and fault phases. That output was not runtime
# evidence and must never be accepted by the signed campaign gate.
#
# A qualifying driver still needs an authenticated, machine-scoped UI/input channel for the
# UEFI/GRUB and installer phases plus daemon fault-injection controls. dorydctl intentionally
# exposes neither today. Until those controls exist, this repository driver records the missing
# authority and exits nonzero. The gate retains this artifact and its cleanup evidence as a failed
# campaign; it cannot manufacture a passing bundle.
set -euo pipefail

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
  --ctl PATH
  --mach-service NAME
  --machine NAME
  --run-directory PATH
  --guest-command COMMAND
  --expected-output TEXT

Optional:
  --timeout-seconds N      Per-operation deadline (default: 900)
  --help

This in-tree driver is intentionally fail-closed until Dory exposes authenticated UEFI/input,
window-capture, and fault-injection controls. Supply a separately reviewed evidence driver to the
campaign gate only when it performs those operations and derives every PASS from retained output.
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

python3 - "$RUN_DIR/scenario-driver-readiness.json" \
  "$MACH_SERVICE" "$MACHINE" "$TIMEOUT_SECONDS" <<'PY'
import json
import sys
from pathlib import Path

path, service, machine, timeout = sys.argv[1:]
record = {
    "kind": "dev.dory.arm-ubuntu-scenario-driver-readiness",
    "schemaVersion": 1,
    "status": "FAIL",
    "machine": machine,
    "machService": service,
    "timeoutSeconds": int(timeout),
    "missingAuthorities": [
        "authenticated-uefi-keyboard-input",
        "machine-scoped-window-capture",
        "daemon-storage-fault-injection",
        "daemon-mapped-page-retry-injection",
    ],
    "detail": (
        "The in-tree scenario driver is fail-closed; no phase was executed and no PASS "
        "artifact was synthesized."
    ),
}
Path(path).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY

die "required graphical/fault campaign authorities are unavailable; retained scenario-driver-readiness.json"
