#!/bin/bash
# Smoke-test DoryPC's hardware-3D runtime selection through a signed Dory.app and an isolated doryd
# service. This is deliberately separate from the Swift test harness: the daemon must activate a
# production-key-signed, short-lived candidate campaign authority before this gate creates any
# machine. It never uses public catalog qualification, QEMU, an existing doryd, or a user-owned
# machine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP=""
CANDIDATE=""
CAMPAIGN_AUTHORITY=""
CAMPAIGN_SIGNATURE=""
INSTALLER=""
PC_FIRMWARE=""
COMMAND=""
EXPECTED_OUTPUT=""
WORKROOT=""
DATA_DRIVE=""
CONFIRM=""
MEMORY_MB=4096
CPUS=2
TIMEOUT_SECONDS=900

usage() {
  cat <<'EOF'
Usage: scripts/pc-gpu-daemon-live-gate.sh [options]

Run an isolated physical DoryPC VirGL runtime-selection smoke through the packaged Dory daemon.

Required:
  --app PATH                Exact Developer-ID-signed Dory.app candidate
  --component-candidate DIR Exact schema-2 component candidate, signed by Dory's production key
  --campaign-authority PATH Exact signed candidate-campaign authorization JSON
  --campaign-signature PATH Detached Ed25519 signature for the campaign authorization
  --installer-media PATH    Exact x86_64 EFI installer/disk admitted by the candidate manifest
  --pc-firmware DIR         Exact verified DoryPC firmware bundle admitted by the candidate
  --guest-command COMMAND   Command to execute through the real guest agent
  --expected-output TEXT    Required substring of the non-truncated guest stdout
  --workroot PATH           New, absolute, campaign-owned evidence root
  --data-drive PATH         Existing, isolated Dory.dorydrive bound by the authorization
  --confirm TOKEN           Must be EXACT-DORY-PC-GPU-DAEMON

Optional:
  --memory-mb N             Guest memory (default: 4096)
  --cpus N                  Guest CPUs (default: 2)
  --timeout-seconds N       Per-operation deadline (default: 900)
  --help                    Show this help

The gate starts a uniquely named launchd service with Docker disabled, activates only the supplied
candidate campaign, creates and later deletes only its own machine, and requires DoryPC's
hardware-accelerated VirGL runtime selection before running the guest command. Candidate authority
permits measurement only; this gate never marks a result as a public release qualification itself.
The caller-supplied command and output substring do not independently prove GPU execution,
shader/pixel correctness, presentation, or worker-loss recovery.
EOF
}

die() { echo "pc-gpu-daemon-live-gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
require_direct_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ] || die "$2 is not a nonempty direct file: $1"
}
require_direct_executable() {
  require_direct_file "$1" "$2"
  [ -x "$1" ] || die "$2 is not executable: $1"
}
require_direct_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || die "$2 is not a direct directory: $1"
}
canonical_input_paths() {
  # launchd does not inherit this shell's working directory. Freeze paths before handing
  # firmware to the daemon or installer media to a service running in another directory.
  CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"
  DATA_DRIVE="$(cd "$DATA_DRIVE" && pwd -P)"
  CAMPAIGN_AUTHORITY="$(cd "$(dirname "$CAMPAIGN_AUTHORITY")" && pwd -P)/$(basename "$CAMPAIGN_AUTHORITY")"
  CAMPAIGN_SIGNATURE="$(cd "$(dirname "$CAMPAIGN_SIGNATURE")" && pwd -P)/$(basename "$CAMPAIGN_SIGNATURE")"
  PC_FIRMWARE="$(cd "$PC_FIRMWARE" && pwd -P)"
  INSTALLER="$(cd "$(dirname "$INSTALLER")" && pwd -P)/$(basename "$INSTALLER")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) need_value "$1" "$#"; APP="$2"; shift 2 ;;
    --component-candidate) need_value "$1" "$#"; CANDIDATE="$2"; shift 2 ;;
    --campaign-authority) need_value "$1" "$#"; CAMPAIGN_AUTHORITY="$2"; shift 2 ;;
    --campaign-signature) need_value "$1" "$#"; CAMPAIGN_SIGNATURE="$2"; shift 2 ;;
    --installer-media) need_value "$1" "$#"; INSTALLER="$2"; shift 2 ;;
    --pc-firmware) need_value "$1" "$#"; PC_FIRMWARE="$2"; shift 2 ;;
    --guest-command) need_value "$1" "$#"; COMMAND="$2"; shift 2 ;;
    --expected-output) need_value "$1" "$#"; EXPECTED_OUTPUT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --data-drive) need_value "$1" "$#"; DATA_DRIVE="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --memory-mb) need_value "$1" "$#"; MEMORY_MB="$2"; shift 2 ;;
    --cpus) need_value "$1" "$#"; CPUS="$2"; shift 2 ;;
    --timeout-seconds) need_value "$1" "$#"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = EXACT-DORY-PC-GPU-DAEMON ] || die "requires --confirm EXACT-DORY-PC-GPU-DAEMON"
for value in "$APP" "$CANDIDATE" "$CAMPAIGN_AUTHORITY" "$CAMPAIGN_SIGNATURE" \
  "$INSTALLER" "$PC_FIRMWARE" "$COMMAND" "$EXPECTED_OUTPUT" "$WORKROOT" "$DATA_DRIVE"; do
  [ -n "$value" ] || die "all required options must be supplied"
done
for value in "$MEMORY_MB" "$CPUS" "$TIMEOUT_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] && [ "${#value}" -le 5 ] \
    || die "memory, CPU, and timeout values must be bounded positive integers"
done
[ "$MEMORY_MB" -le 63488 ] && [ "$CPUS" -le 64 ] && [ "$TIMEOUT_SECONDS" -le 7200 ] \
  || die "memory, CPU, or timeout exceeds the diagnostic limit"
case "$WORKROOT" in
  /*) ;;
  *) die "--workroot must be absolute" ;;
esac
case "$WORKROOT" in
  /|"$HOME"|"$ROOT") die "unsafe --workroot: $WORKROOT" ;;
esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "--workroot must not already exist: $WORKROOT"

require_direct_directory "$APP" "Dory.app"
[ "$(basename "$APP")" = Dory.app ] || die "--app must name Dory.app"
APP="$(cd "$(dirname "$APP")" && pwd -P)/Dory.app"
HELPERS="$APP/Contents/Helpers"
RESOURCES="$APP/Contents/Resources"
DORYD="$HELPERS/doryd"
CTL="$HELPERS/dorydctl"
RUNNER_APP="$HELPERS/DoryHVRunner.app"
RUNNER="$RUNNER_APP/Contents/MacOS/dory-hv"
VMM_APP="$HELPERS/DoryVMM.app"
VMM="$VMM_APP/Contents/MacOS/dory-vmm"
GVPROXY="$HELPERS/gvproxy"
for pair in \
  "$DORYD:doryd" "$CTL:dorydctl" "$RUNNER:dory-hv" "$VMM:dory-vmm" "$GVPROXY:gvproxy"; do
  path="$(printf '%s\n' "$pair" | cut -d: -f1)"
  label="$(printf '%s\n' "$pair" | cut -d: -f2)"
  require_direct_executable "$path" "$label"
done
require_direct_directory "$RUNNER_APP" "DoryHVRunner.app"
require_direct_directory "$VMM_APP" "DoryVMM.app"
require_direct_directory "$PC_FIRMWARE" "DoryPC firmware bundle"
require_direct_directory "$CANDIDATE" "component candidate"
require_direct_directory "$DATA_DRIVE" "campaign data drive"
[ "$(basename "$DATA_DRIVE")" = Dory.dorydrive ] \
  || die "--data-drive must name an isolated Dory.dorydrive"
require_direct_file "$CANDIDATE/component-candidate-inventory.json" "component candidate inventory"
require_direct_file "$CANDIDATE/component-candidate-inventory.json.sha256" "component candidate inventory digest"
require_direct_file "$CAMPAIGN_AUTHORITY" "candidate campaign authority"
require_direct_file "$CAMPAIGN_SIGNATURE" "candidate campaign signature"
require_direct_file "$INSTALLER" "installer media"
canonical_input_paths

command -v jq >/dev/null || die "jq is required"
command -v launchctl >/dev/null || die "launchctl is required"
[ "$(uname -s)" = Darwin ] || die "requires macOS"
[ "$(uname -m)" = arm64 ] || die "requires an Apple Silicon host"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested Virtualization.framework hosts cannot qualify this physical gate"
case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
  VirtualMac*) die "VirtualMac hosts cannot qualify this physical gate" ;;
esac

# Verify the outer graph first. The nested runner must remain Apple-signed rather than merely
# inheriting a valid outer bundle seal.
codesign --verify --deep --strict "$APP" >/dev/null \
  || die "Dory.app signature verification failed"
for bundle in "$RUNNER_APP" "$VMM_APP"; do
  codesign --verify --deep --strict "$bundle" >/dev/null \
    || die "nested bundle signature verification failed: $bundle"
done
runner_details="$(codesign -d --verbose=4 "$RUNNER_APP" 2>&1)"
printf '%s\n' "$runner_details" | grep -Fqx 'Identifier=com.pythonxi.Dory.HVRunner' \
  || die "runner identity is not com.pythonxi.Dory.HVRunner"
printf '%s\n' "$runner_details" | grep -Fqx 'TeamIdentifier=864H636QW4' \
  || die "runner signing team is not Dory's Developer ID team"
printf '%s\n' "$runner_details" | grep -Fq 'Authority=Developer ID Application:' \
  || die "runner is not Developer-ID-signed"

# Candidate admission is intentionally distinct from schema-2 public qualification.
jq -e --arg candidate "$CANDIDATE" --arg app "$APP" \
  --arg state "$DATA_DRIVE/machines" '
  .kind == "dev.dory.virtual-machine-candidate-campaign-authorization"
  and .purpose == "candidate-qualification-campaign"
  and .schemaVersion == 2
  and .candidateRoot == $candidate
  and .applicationRoot == $app
  and .stateRoot == $state
  and any(.cells[]; .capability.guest.architecture == "x86_64"
    and .capability.graphics == "hardware-accelerated-3d"
    and .capability.backend == "dory-hypervisor")
' "$CAMPAIGN_AUTHORITY" >/dev/null \
  || die "campaign authority does not bind this candidate, app, and DoryPC GPU cell"

mkdir -m 0700 "$WORKROOT" || die "could not exclusively create workroot"
[ -d "$WORKROOT" ] && [ ! -L "$WORKROOT" ] || die "workroot changed while preparing"
chmod 0700 "$WORKROOT"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$WORKROOT/$RUN_ID"
mkdir -p "$WORKDIR" "$WORKDIR/home" "$WORKDIR/logs" "$WORKDIR/runtime"
chmod 0700 "$WORKDIR" "$WORKDIR/home" "$WORKDIR/logs" "$WORKDIR/runtime"
SERVICE="dev.dory.wave0.pcgpu.$RUN_ID"
MACHINE="wave0-pc-gpu-$RUN_ID"
PLIST="$WORKDIR/$SERVICE.plist"
MANIFEST="$WORKDIR/manifest.json"
RESULTS="$WORKDIR/results.tsv"
printf 'check\tstatus\tdetail\n' > "$RESULTS"
SERVICE_LOADED=0
MACHINE_OWNED=0

ctl() {
  HOME="$WORKDIR/home" "$CTL" --mach-service "$SERVICE" --timeout "$TIMEOUT_SECONDS" "$@"
}
# Status requests are read-only. Bound both the individual client and the entire
# polling interval; repeating a 900-second client call is not a 60-second wait.
wait_for_ctl_state() {
  python3 - "$CTL" "$SERVICE" "$WORKDIR/home" "$@" <<'PYPOLL'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ctl, service, home, mode, budget, stem, *arguments = sys.argv[1:]
deadline = time.monotonic() + float(budget)
while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SystemExit(1)
    timeout = min(2.0, remaining)
    try:
        result = subprocess.run([ctl, "--mach-service", service, "--timeout", str(timeout), *arguments],
                                env=dict(os.environ, HOME=home), capture_output=True, timeout=timeout)
        Path(stem + ".out").write_bytes(result.stdout)
        Path(stem + ".err").write_bytes(result.stderr)
        if result.returncode == 0:
            if mode == "protocol":
                raise SystemExit(0)
            try:
                payload = json.loads(result.stdout)
                state = payload.get("state") if isinstance(payload, dict) else None
            except (ValueError, UnicodeDecodeError):
                state = None
            if state == "running":
                raise SystemExit(0)
            if state in {"failed", "stopped"}:
                raise SystemExit(2)
    except subprocess.TimeoutExpired:
        Path(stem + ".err").write_text("status client exceeded polling deadline\n")
    time.sleep(min(0.5, max(0, deadline - time.monotonic())))
PYPOLL
}

record_pass() { printf '%s\tPASS\t%s\n' "$1" "$2" >> "$RESULTS"; }
cleanup() {
  set +e
  if [ "$MACHINE_OWNED" = 1 ]; then
    HOME="$WORKDIR/home" "$CTL" --mach-service "$SERVICE" --timeout 10 machine stop "$MACHINE" > "$WORKDIR/cleanup-stop.out" 2> "$WORKDIR/cleanup-stop.err" || true
    HOME="$WORKDIR/home" "$CTL" --mach-service "$SERVICE" --timeout 10 machine delete "$MACHINE" > "$WORKDIR/cleanup-delete.out" 2> "$WORKDIR/cleanup-delete.err" || true
  fi
  if [ "$SERVICE_LOADED" = 1 ]; then
    launchctl bootout "gui/$(id -u)/$SERVICE" > "$WORKDIR/cleanup-launchd.out" 2> "$WORKDIR/cleanup-launchd.err" || true
  fi
  if launchctl print "gui/$(id -u)/$SERVICE" >/dev/null 2>&1; then
    printf 'cleanup_service=FAILED\n' >> "$RESULTS"
  else
    printf 'cleanup_service=PASS\n' >> "$RESULTS"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$PLIST" "$SERVICE" "$DORYD" "$WORKDIR" "$DATA_DRIVE" "$RUNNER" "$VMM" \
  "$GVPROXY" "$PC_FIRMWARE" "$CAMPAIGN_AUTHORITY" "$CAMPAIGN_SIGNATURE" "$APP" <<'PY'
import plistlib
import sys

(path, service, doryd, workdir, drive, runner, vmm, gvproxy, firmware,
 authority, signature, application) = sys.argv[1:]
environment = {
    "DORYD_ACCELERATED_DESKTOP": "1",
    "DORYD_DATA_DRIVE": drive,
    "DORYD_DESKTOP_HV_HELPER": runner,
    "DORYD_DOCKER_TIER": "0",
    "DORYD_GVPROXY": gvproxy,
    "DORYD_HOME": workdir + "/home",
    "DORYD_HOST_CLI": "0",
    "DORYD_MACHINE_LOG_DIR": workdir + "/logs",
    "DORYD_MACHINE_RUNTIME_DIR": workdir + "/runtime",
    "DORYD_MACH_SERVICE": service,
    "DORYD_NETWORKING": "0",
    "DORYD_PC_FIRMWARE_BUNDLE": firmware,
    "DORYD_VMM_HELPER": vmm,
    "DORYD_VMM_READY_HANDOFF": "1",
    "DORYD_VM_CANDIDATE_CAMPAIGN_AUTHORITY": authority,
    "DORYD_VM_CANDIDATE_CAMPAIGN_SIGNATURE": signature,
    "DORYD_VM_CANDIDATE_APPLICATION_ROOT": application,
    "HOME": workdir + "/home",
}
payload = {
    "Label": service,
    "ProgramArguments": [doryd],
    "MachServices": {service: True},
    "EnvironmentVariables": environment,
    "RunAtLoad": True,
    "StandardOutPath": workdir + "/logs/doryd.out",
    "StandardErrorPath": workdir + "/logs/doryd.err",
}
with open(path, "xb") as handle:
    plistlib.dump(payload, handle, sort_keys=True)
PY
chmod 0600 "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "could not write isolated launchd plist"

launchctl print "gui/$(id -u)/$SERVICE" >/dev/null 2>&1 \
  && die "campaign service already exists: $SERVICE"
launchctl bootstrap "gui/$(id -u)" "$PLIST" > "$WORKDIR/launchctl-bootstrap.out" 2> "$WORKDIR/launchctl-bootstrap.err" \
  || die "could not bootstrap the isolated Dory daemon"
SERVICE_LOADED=1

wait_for_ctl_state protocol 60 "$WORKDIR/protocol-version" protocol-version \
  || die "isolated Dory daemon did not accept XPC within 60 seconds"
launch_state="$(launchctl print "gui/$(id -u)/$SERVICE")" \
  || die "launchd did not retain the isolated Dory daemon"
printf '%s\n' "$launch_state" > "$WORKDIR/launchctl-print.txt"
printf '%s\n' "$launch_state" | grep -Fq "program = $DORYD" \
  || die "isolated launchd service is not running the supplied Dory.app daemon"
printf '%s\n' "$launch_state" | grep -Fq "DORYD_VM_CANDIDATE_CAMPAIGN_AUTHORITY" \
  || die "isolated daemon did not receive candidate campaign authority"
record_pass daemon "isolated signed daemon serving $SERVICE with Docker disabled"
record_pass candidate-admission "production-root signed candidate campaign activated without public qualification"

ctl machine list > "$WORKDIR/machine-list-before.json"
jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/machine-list-before.json" >/dev/null \
  || die "campaign-owned machine unexpectedly existed before creation"
# The name was absent in this isolated service. Mark it owned before dispatch:
# a client timeout may happen after the daemon has durably created the machine.
MACHINE_OWNED=1
ctl machine create "$MACHINE" \
  --installer-iso "$INSTALLER" \
  --guest-architecture x86_64 \
  --memory-mb "$MEMORY_MB" --cpus "$CPUS" \
  --display-mode desktop --runtime accelerated --graphics virgl \
  --network disconnected \
  > "$WORKDIR/machine-create.json" 2> "$WORKDIR/machine-create.err" \
  || die "candidate campaign planner rejected the DoryPC launch request"
ctl machine start "$MACHINE" > "$WORKDIR/machine-start.json" 2> "$WORKDIR/machine-start.err" \
  || die "DoryPC launch request failed"

wait_for_ctl_state machine "$TIMEOUT_SECONDS" "$WORKDIR/machine-status" machine status "$MACHINE" \
  || die "DoryPC did not reach running state before the deadline, or entered a terminal state"
cp "$WORKDIR/machine-status.out" "$WORKDIR/machine-status.json"
jq -e '
  .state == "running"
  and .guestArchitecture == "x86_64"
  and .runtimeGraphicsSelection.accelerationLevel == "hardware-accelerated-3d"
  and .runtimeGraphicsSelection.backend == "virgl"
' "$WORKDIR/machine-status.json" >/dev/null \
  || die "running machine is not the DoryPC hardware-accelerated VirGL selection"
record_pass dorypc-runtime "x86_64 DoryPC hardware-accelerated VirGL selection reached running"

ctl machine exec "$MACHINE" --json --timeout-ms "$((TIMEOUT_SECONDS * 1000))" -- sh -ec "$COMMAND" \
  > "$WORKDIR/guest-command.json" 2> "$WORKDIR/guest-command.err" \
  || die "DoryPC guest command transport failed"
jq -e --arg expected "$EXPECTED_OUTPUT" '
  .exitCode == 0
  and .timedOut == false
  and .stdoutTruncated == false
  and .stderrTruncated == false
  and (.stdout | contains($expected))
' "$WORKDIR/guest-command.json" >/dev/null \
  || die "DoryPC guest command did not emit the expected output"
record_pass guest-command "caller-supplied command completed without truncation and emitted expected output"

ctl machine device-telemetry "$MACHINE" > "$WORKDIR/device-telemetry.json" \
  2> "$WORKDIR/device-telemetry.err" || die "could not collect DoryPC device telemetry"
ctl machine stop "$MACHINE" > "$WORKDIR/machine-stop.json" 2> "$WORKDIR/machine-stop.err" \
  || die "could not stop campaign-owned DoryPC"
ctl machine delete "$MACHINE" > "$WORKDIR/machine-delete.json" 2> "$WORKDIR/machine-delete.err" \
  || die "could not delete campaign-owned DoryPC"
MACHINE_OWNED=0
ctl machine list > "$WORKDIR/machine-list-after.json"
jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/machine-list-after.json" >/dev/null \
  || die "campaign-owned DoryPC remained after cleanup"
record_pass machine-cleanup "only the campaign-owned DoryPC was stopped and deleted"
launchctl bootout "gui/$(id -u)/$SERVICE" > "$WORKDIR/daemon-stop.out" 2> "$WORKDIR/daemon-stop.err" \
  || die "could not stop the isolated Dory daemon"
SERVICE_LOADED=0
if launchctl print "gui/$(id -u)/$SERVICE" >/dev/null 2>&1; then
  die "isolated Dory daemon survived cleanup"
fi
record_pass daemon-cleanup "isolated launchd service stopped before the campaign receipt was written"
# Cleanup has completed. Keep the evidence files stable after their digests are recorded.
trap - EXIT

python3 - "$MANIFEST" "$APP" "$DORYD" "$CTL" "$RUNNER" "$CANDIDATE" "$INSTALLER" \
  "$SERVICE" "$MACHINE" "$RESULTS" "$COMMAND" "$EXPECTED_OUTPUT" "$MEMORY_MB" "$CPUS" \
  "$TIMEOUT_SECONDS" "$PC_FIRMWARE" "$CAMPAIGN_AUTHORITY" "$CAMPAIGN_SIGNATURE" <<'PYMANIFEST'
import datetime
import hashlib
import json
from pathlib import Path
import sys

(output, app, daemon, ctl, runner, candidate, installer, service, machine, results,
 command, expected_output, memory_mb, cpus, timeout_seconds, firmware, authority,
 signature) = sys.argv[1:]
def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()
checks = Path(results).read_text(encoding="utf-8").splitlines()[1:]
evidence_root = Path(output).parent
attachments = {}
for path in sorted(evidence_root.rglob("*")):
    relative = path.relative_to(evidence_root)
    if relative.parts[0] in {"home", "runtime"}:
        continue
    if path.is_symlink():
        raise SystemExit(f"evidence must not contain symbolic links: {path}")
    # The isolated VM drive is intentionally deleted; retain only campaign diagnostics.
    if path.is_file() and path != Path(output):
        attachments[str(relative)] = digest(path)
payload = {
    "kind": "dev.dory.pc-gpu-daemon-live-gate",
    "schemaVersion": 1,
    "releaseQualified": False,
    "qualificationMode": "signed-candidate-campaign-physical-dorypc-daemon-smoke",
    "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "usesQEMU": False,
    "proofScope": ["candidate-campaign-admission", "daemon-reported-hardware-3d-selection", "guest-command-output"],
    "unverified": ["guest-drm-identity", "shader-pixel-correctness", "host-metal-execution", "present", "worker-loss"],
    "guestCommand": command,
    "expectedOutputSubstring": expected_output,
    "resources": {"guestMemoryMiB": int(memory_mb), "guestCPUs": int(cpus), "operationTimeoutSeconds": int(timeout_seconds)},
    "firmwarePath": firmware,
    "app": app,
    "appExecutableSHA256": digest(str(Path(app) / "Contents/MacOS/Dory")),
    "daemonSHA256": digest(daemon),
    "controlHelperSHA256": digest(ctl),
    "runnerSHA256": digest(runner),
    "candidateInventorySHA256": digest(str(Path(candidate) / "component-candidate-inventory.json")),
    "campaignAuthoritySHA256": digest(authority),
    "campaignSignatureSHA256": digest(signature),
    "installerSHA256": digest(installer),
    "machService": service,
    "machine": machine,
    "checks": checks,
    "artifactSHA256": attachments,
}
Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYMANIFEST
echo "DoryPC daemon runtime-selection smoke PASS; GPU correctness remains unverified; evidence: $WORKDIR"
