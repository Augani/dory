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
    '--display-mode desktop --runtime accelerated --graphics virgl',
    '.runtimeGraphicsSelection.accelerationLevel == "hardware-accelerated-3d"',
    '.runtimeGraphicsSelection.backend == "virgl"',
    '"usesQEMU": False',
    'HOME="$WORKDIR/home" "$CTL"',
    'launchctl bootstrap "gui/$(id -u)" "$PLIST"',
    'ctl machine delete "$MACHINE"',
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
           str(root / "firmware input"), str(authority), str(signature)]
subprocess.run(command, check=True, capture_output=True, text=True)
manifest = json.loads(manifest_path.read_text())
assert manifest["releaseQualified"] is False
assert manifest["qualificationMode"].endswith("-smoke")
assert "shader-pixel-correctness" in manifest["unverified"]
assert "host-metal-execution" in manifest["unverified"]
assert manifest["guestCommand"] == "echo marker"
assert manifest["resources"]["guestCPUs"] == 2
assert set(manifest["artifactSHA256"]) == {"results.tsv", "guest-command.json"}
for name, expected in manifest["artifactSHA256"].items():
    assert hashlib.sha256((evidence / name).read_bytes()).hexdigest() == expected
# External aliases cannot silently replace the portable raw campaign record.
(evidence / "external.json").symlink_to(candidate / "component-candidate-inventory.json")
result = subprocess.run(command, capture_output=True, text=True)
assert result.returncode != 0
assert "symbolic links" in result.stderr
print("PC gate absolute input paths and bounded evidence-claim tests passed")
PYEVIDENCETEST

echo "pc GPU daemon live gate test passed"
