#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GATE="$ROOT/scripts/pc-gpu-daemon-live-gate.sh"
TMP="$(mktemp -d "/tmp/dory-pc-gpu-daemon-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

[ -x "$GATE" ] || { echo "pc GPU daemon gate is not executable" >&2; exit 1; }
bash -n "$GATE"
"$GATE" --help >/dev/null

# Confirmation must be checked before any path, launchd, daemon, or VM action. This makes the
# gate safe to invoke from a review job and prevents a partially supplied candidate from touching
# an existing Dory installation.
if "$GATE" \
  --app /not/a/dory.app \
  --component-candidate /not/a/candidate \
  --campaign-authority /not/an/authority \
  --campaign-signature /not/a/signature \
  --installer-media /not/an/installer \
  --pc-firmware /not/firmware \
  --guest-command true \
  --expected-output marker \
  --workroot "$TMP/unreachable" \
  --data-drive /not/a/data-drive \
  --confirm WRONG-TOKEN > "$TMP/rejected.out" 2>&1; then
  echo "pc GPU daemon gate accepted an invalid confirmation token" >&2
  exit 1
fi
grep -Fqx \
  'pc-gpu-daemon-live-gate: requires --confirm EXACT-DORY-PC-GPU-DAEMON' \
  "$TMP/rejected.out"

if "$GATE" --gpu-profile invalid --confirm EXACT-DORY-PC-GPU-DAEMON \
  > "$TMP/invalid-profile.out" 2>&1; then
  echo "pc GPU daemon gate accepted an unsupported GPU profile" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: --gpu-profile must be virgl or venus' \
  "$TMP/invalid-profile.out"

if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --desktop-installer-plan /missing/plan \
  > "$TMP/missing-installer-confirm.out" 2>&1; then
  echo "PC stock installation accepted no installation-specific confirmation" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: stock installation requires --desktop-installer-confirm EXACT-DORY-PC-DESKTOP-INSTALL' \
  "$TMP/missing-installer-confirm.out"
if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --desktop-installer-confirm EXACT-DORY-PC-DESKTOP-INSTALL \
  > "$TMP/missing-installer-plan.out" 2>&1; then
  echo "PC stock installation accepted no full installer plan" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: stock installation confirmation requires a full installer plan' \
  "$TMP/missing-installer-plan.out"

if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --renderer-recovery-plan /not/a/plan \
  > "$TMP/missing-recovery-confirm.out" 2>&1; then
  echo "PC renderer fault phase accepted no mode-specific confirmation" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: renderer recovery requires --renderer-recovery-confirm EXACT-DORY-PC-RENDERER-CRASH' \
  "$TMP/missing-recovery-confirm.out"
if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --renderer-recovery-confirm EXACT-DORY-PC-RENDERER-CRASH \
  > "$TMP/missing-recovery-plan.out" 2>&1; then
  echo "PC renderer recovery accepted confirmation without a plan" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: renderer recovery confirmation requires a redraw plan' \
  "$TMP/missing-recovery-plan.out"
if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --desktop-lifecycle \
  > "$TMP/missing-lifecycle-confirm.out" 2>&1; then
  echo "PC lifecycle writes accepted no mode-specific confirmation" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: desktop lifecycle requires --desktop-lifecycle-confirm EXACT-DORY-PC-DESKTOP-LIFECYCLE' \
  "$TMP/missing-lifecycle-confirm.out"
if "$GATE" --confirm EXACT-DORY-PC-GPU-DAEMON --desktop-lifecycle-confirm EXACT-DORY-PC-DESKTOP-LIFECYCLE \
  > "$TMP/missing-lifecycle.out" 2>&1; then
  echo "PC lifecycle confirmation accepted no phase selection" >&2
  exit 1
fi
grep -Fqx 'pc-gpu-daemon-live-gate: desktop lifecycle confirmation/input requires --desktop-lifecycle' \
  "$TMP/missing-lifecycle.out"

python3 - "$GATE" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    '"DORYD_DOCKER_TIER": "0"',
    '"DORYD_VM_CANDIDATE_CAMPAIGN_AUTHORITY": authority',
    '"DORYD_VM_CANDIDATE_CAMPAIGN_SIGNATURE": signature',
    '"DORYD_VM_CANDIDATE_APPLICATION_ROOT": application',
    '"candidate-campaign-admission"',
    '--guest-architecture x86_64',
    '--display-mode desktop --runtime accelerated --graphics "$GRAPHICS_SELECTION"',
    'venus) GRAPHICS_SELECTION=virgl-venus; EXPECTED_BACKEND=virgl-venus',
    '.runtimeGraphicsSelection.accelerationLevel == "hardware-accelerated-3d"',
    '.runtimeGraphicsSelection.backend == $backend',
    '"usesQEMU": False',
    'HOME="$WORKDIR/home" "$CTL"',
    'launchctl bootstrap "gui/$(id -u)" "$PLIST"',
    'ctl machine delete "$MACHINE"',
    'ctl machine update "$MACHINE" --eject-installer',
    '"$ROOT/scripts/pc-ubuntu-renderer-recovery.py" --verify-only',
    '--graphics-trace "$DATA_DRIVE/machines/$MACHINE/graphics-trace.ndjson"',
    '.faultPolicy.permittedFaults == ["renderer-worker-sigkill"]',
    'cp "$CAMPAIGN_AUTHORITY" "$WORKDIR/campaign-authority.json"',
    '"$ROOT/scripts/pc-ubuntu-desktop-lifecycle.py" --verify-only',
    '"$ROOT/scripts/pc-ubuntu-installer.py" --verify-only',
    '--tools-iso "$TOOLS_ISO" --confirm "$INSTALLER_CONFIRM"',
    '--network "$NETWORK_MODE"',
    '"DORYD_NETWORKING": "1" if network == "shared-nat" else "0"',
)
for value in required:
    assert value in source, f"missing gate contract: {value}"
assert 'qemu-system' not in source
assert 'ctl component install-candidate' not in source
assert 'DORY_PC_GPU_REAL_HARNESS' not in source
assert 'installLaunchGatedChildCodeValidatorForTesting' not in source
PY

# Exercise the actual polling function with a real slow subprocess, not source text.
python3 - "$GATE" "$TMP" <<'PYPOLLTEST'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

source = Path(sys.argv[1]).read_text()
start = source.index("wait_for_ctl_state() {")
function = source[start:source.index("\n}\n", start) + 3]
root = Path(sys.argv[2])
ctl = root / "ctl"
ctl.write_text("#!/bin/sh\n"
               "if [ \"$FAKE_STATE\" = hang ]; then exec /bin/sleep 30; fi\n"
               "printf '{\"state\":\"%s\"}\\n' \"$FAKE_STATE\"\n")
ctl.chmod(0o755)
for mode, state, expected in [("protocol", "ready", 0), ("machine", "running", 0),
                               ("machine", "stopped", 2), ("machine", "hang", 1)]:
    stem = root / (mode + "-" + state)
    environment = dict(os.environ, CTL=str(ctl), SERVICE="fixture-service", WORKDIR=str(root),
                       FAKE_STATE=state, STEM=str(stem), MODE=mode, BUDGET="0.3" if state == "hang" else "3")
    before = time.monotonic()
    result = subprocess.run(["bash"], input=function + '\nwait_for_ctl_state "$MODE" "$BUDGET" "$STEM" machine status fixture\n',
                            env=environment, text=True, capture_output=True, timeout=5)
    elapsed = time.monotonic() - before
    assert result.returncode == expected, (state, result.returncode, result.stderr, Path(str(stem) + ".err").read_text() if Path(str(stem) + ".err").exists() else "no log")
    assert elapsed < (2 if state == "hang" else 5), (state, elapsed)
    if state == "hang":
        assert "exceeded polling deadline" in Path(str(stem) + ".err").read_text()
print("PC gate polling success, terminal state, and deadline tests passed")
PYPOLLTEST

python3 - "$GATE" "$TMP" <<'PYEVIDENCETEST'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2]).resolve()
for name in ("candidate input", "firmware input", "media input"):
    (root / name).mkdir()
data_drive = root / "Dory.dorydrive"
data_drive.mkdir()
installer = root / "media input/installer.iso"
installer.write_bytes(b"installer")
authority = root / "authority.json"
authority.write_bytes(b"authority")
signature = root / "authority.json.sig"
signature.write_bytes(b"signature")
start = source.index("canonical_input_paths() {")
function = source[start:source.index("\n}\n", start) + 3]
environment = dict(os.environ, CANDIDATE="candidate input", PC_FIRMWARE="firmware input",
                   INSTALLER="media input/installer.iso", CAMPAIGN_AUTHORITY="authority.json",
                   CAMPAIGN_SIGNATURE="authority.json.sig", DATA_DRIVE="Dory.dorydrive")
result = subprocess.run(["bash"], cwd=root, env=environment, text=True, capture_output=True,
                        input=function + '\ncanonical_input_paths\nprintf "%s\\n" "$CANDIDATE" "$PC_FIRMWARE" "$INSTALLER" "$CAMPAIGN_AUTHORITY" "$CAMPAIGN_SIGNATURE" "$DATA_DRIVE"\n', check=True)
assert result.stdout.splitlines() == [str(root / "candidate input"), str(root / "firmware input"),
                                     str(installer), str(authority), str(signature), str(data_drive)]

app = root / "Dory.app"
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/MacOS/Dory").write_bytes(b"app")
for name in ("daemon", "control", "runner"):
    (root / name).write_bytes(name.encode())
candidate = root / "candidate input"
(candidate / "component-candidate-inventory.json").write_bytes(b"{}")
evidence = root / "evidence"
evidence.mkdir()
(evidence / "results.tsv").write_text("check\tstatus\tdetail\nguest-command\tPASS\tmarker\n")
(evidence / "guest-command.json").write_text('{"stdout":"marker"}')
(evidence / "home").mkdir()
(evidence / "home/private-runtime-state").write_bytes(b"not an evidence attachment")
manifest_code = source.split("<<'PYMANIFEST'\n", 1)[1].split("\nPYMANIFEST\n", 1)[0]
manifest_path = evidence / "manifest.json"
command = [sys.executable, "-c", manifest_code, str(manifest_path), str(app), str(root / "daemon"),
           str(root / "control"), str(root / "runner"), str(candidate), str(installer), "service", "machine",
           str(evidence / "results.tsv"), "echo marker", "marker", "4096", "2", "900",
           str(root / "firmware input"), str(authority), str(signature), "venus", "virgl-venus", "", str(Path(sys.argv[1]).parent.parent), "0", "disconnected"]
subprocess.run(command, check=True, capture_output=True, text=True)
manifest = json.loads(manifest_path.read_text())
assert manifest["releaseQualified"] is False
assert manifest["qualificationMode"].endswith("-smoke")
assert "shader-pixel-correctness" in manifest["unverified"]
assert "host-metal-execution" in manifest["unverified"]
assert manifest["guestCommand"] == "echo marker"
assert manifest["gpuProfile"] == "venus"
assert manifest["runtimeGraphicsBackend"] == "virgl-venus"
assert manifest["resources"]["guestCPUs"] == 2
assert set(manifest["artifactSHA256"]) == {"results.tsv", "guest-command.json"}
for name, expected in manifest["artifactSHA256"].items():
    assert hashlib.sha256((evidence / name).read_bytes()).hexdigest() == expected
# Adding a recovery flag cannot upgrade a smoke receipt with no raw recovery evidence.
forged = list(command)
forged[-4] = "/synthetic/redraw-plan.json"
result = subprocess.run(forged, capture_output=True, text=True)
assert result.returncode != 0
assert "renderer-recovery.json" in result.stderr
forged = list(command); forged[-2] = "1"; forged[-1] = "shared-nat"
result = subprocess.run(forged, capture_output=True, text=True)
assert result.returncode != 0
assert "desktop-lifecycle-readiness.json" in result.stderr
forged = [*command, "/synthetic/full-installer-plan.json"]
result = subprocess.run(forged, capture_output=True, text=True)
assert result.returncode != 0, "installer flag promoted a smoke without retained installation evidence"
# External aliases cannot silently replace the portable raw campaign record.
(evidence / "external.json").symlink_to(candidate / "component-candidate-inventory.json")
result = subprocess.run(command, capture_output=True, text=True)
assert result.returncode != 0
assert "symbolic links" in result.stderr
print("PC gate absolute input paths and bounded evidence-claim tests passed")
PYEVIDENCETEST

echo "pc GPU daemon live gate test passed"
