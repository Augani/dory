#!/bin/bash
# Boot and exercise every managed rootfs desktop with the exact signed release candidate. Generic
# ARM64 EFI ISO installation on the Virtualization.framework software-display baseline belongs to
# a separate end-to-end gate; success here must never be reported as ISO qualification.
# This gate is intentionally destructive only to its uniquely named temporary machines and work
# directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTL=""
COMPONENT_DIR=""
KERNEL=""
DEBIAN_ROOTFS=""
UBUNTU_ROOTFS=""
KALI_ROOTFS=""
DEBIAN_UPDATE=""
UBUNTU_UPDATE=""
KALI_UPDATE=""
ZED_ARCHIVE=""
ZED_VERSION=""
ZED_SHA256=""
DESKTOP_VERSION=""
SELECTED_DISTRO="all"
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-desktop-linux-live"
CONFIRM=""
REQUIRE_ACCELERATION=0
REQUIRE_RELEASE_SIGNATURE=0
RENDERER_RELEASE_SIGNATURE_RESULT=NOT-REQUIRED
MESA_VIRGL_DESKTOP_RESULT=NOT-REQUIRED

usage() {
  echo "usage: desktop-linux-live-gate.sh --ctl PATH --component-dir PATH --kernel PATH [--distro all|debian|ubuntu|kali] [desktop assets] [Ubuntu-only acceleration assets: --zed-archive PATH --zed-version VERSION --zed-sha256 SHA256] [--require-acceleration] [--require-release-signature] --version VERSION --workroot PATH --confirm EXACT-CANDIDATE-DESKTOPS" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ctl) CTL="${2:?missing path}"; shift 2 ;;
    --component-dir) COMPONENT_DIR="${2:?missing path}"; shift 2 ;;
    --kernel) KERNEL="${2:?missing path}"; shift 2 ;;
    --debian-rootfs) DEBIAN_ROOTFS="${2:?missing path}"; shift 2 ;;
    --ubuntu-rootfs) UBUNTU_ROOTFS="${2:?missing path}"; shift 2 ;;
    --kali-rootfs) KALI_ROOTFS="${2:?missing path}"; shift 2 ;;
    --debian-update) DEBIAN_UPDATE="${2:?missing path}"; shift 2 ;;
    --ubuntu-update) UBUNTU_UPDATE="${2:?missing path}"; shift 2 ;;
    --kali-update) KALI_UPDATE="${2:?missing path}"; shift 2 ;;
    --zed-archive) ZED_ARCHIVE="${2:?missing path}"; shift 2 ;;
    --zed-version) ZED_VERSION="${2:?missing version}"; shift 2 ;;
    --zed-sha256) ZED_SHA256="${2:?missing digest}"; shift 2 ;;
    --distro) SELECTED_DISTRO="${2:?missing distro}"; shift 2 ;;
    --version) DESKTOP_VERSION="${2:?missing version}"; shift 2 ;;
    --workroot) WORKROOT="${2:?missing path}"; shift 2 ;;
    --confirm) CONFIRM="${2:?missing confirmation}"; shift 2 ;;
    --require-acceleration) REQUIRE_ACCELERATION=1; shift ;;
    --require-release-signature) REQUIRE_RELEASE_SIGNATURE=1; REQUIRE_ACCELERATION=1; shift ;;
    *) usage ;;
  esac
done

[ "$CONFIRM" = EXACT-CANDIDATE-DESKTOPS ] || usage
case "$SELECTED_DISTRO" in
  all|debian|ubuntu|kali) ;;
  *) echo "desktop live gate: unsupported distro selection: $SELECTED_DISTRO" >&2; exit 64 ;;
esac
[ -f "$CTL" ] && [ ! -L "$CTL" ] && [ -x "$CTL" ] \
  || { echo "desktop live gate: dorydctl is missing or indirect: $CTL" >&2; exit 66; }
[ "$(basename "$CTL")" = dorydctl ] \
  || { echo "desktop live gate: control helper is not the exact dorydctl identity" >&2; exit 66; }
[ -d "$COMPONENT_DIR" ] && [ ! -L "$COMPONENT_DIR" ] \
  || { echo "desktop live gate: missing component candidate directory: $COMPONENT_DIR" >&2; exit 66; }
HELPERS="$(cd "$(dirname "$CTL")" && pwd -P)"
CTL="$HELPERS/dorydctl"
RUNNER_APP="$HELPERS/DoryHVRunner.app"
VMM="$RUNNER_APP/Contents/MacOS/dory-hv"
VZ_VMM_APP="$HELPERS/DoryVMM.app"
VZ_VMM="$VZ_VMM_APP/Contents/MacOS/dory-vmm"
VZ_VMM_INFO="$VZ_VMM_APP/Contents/Info.plist"
FS_WORKER_APP="$RUNNER_APP/Contents/XPCServices/DoryFSWorker.xpc"
FS_WORKER="$FS_WORKER_APP/Contents/MacOS/DoryFSWorker"
RENDERER_WORKER_APP="$RUNNER_APP/Contents/XPCServices/DoryRendererWorker.xpc"
RENDERER_WORKER="$RENDERER_WORKER_APP/Contents/MacOS/DoryRendererWorker"
[ -d "$RUNNER_APP" ] && [ ! -L "$RUNNER_APP" ] \
  || { echo "desktop live gate: DoryHVRunner.app is missing or indirect: $RUNNER_APP" >&2; exit 66; }
[ -f "$VMM" ] && [ ! -L "$VMM" ] && [ -x "$VMM" ] \
  || { echo "desktop live gate: accelerated candidate dory-hv is missing or indirect: $VMM" >&2; exit 66; }
[ -d "$VZ_VMM_APP" ] && [ ! -L "$VZ_VMM_APP" ] \
  || { echo "desktop live gate: portable baseline DoryVMM.app is missing: $VZ_VMM_APP" >&2; exit 66; }
[ -f "$VZ_VMM" ] && [ ! -L "$VZ_VMM" ] && [ -x "$VZ_VMM" ] \
  || { echo "desktop live gate: portable baseline candidate dory-vmm is missing or indirect: $VZ_VMM" >&2; exit 66; }
[ -f "$VZ_VMM_INFO" ] && [ ! -L "$VZ_VMM_INFO" ] \
  || { echo "desktop live gate: portable baseline VMM Info.plist is missing: $VZ_VMM_INFO" >&2; exit 66; }
[ -d "$FS_WORKER_APP" ] && [ ! -L "$FS_WORKER_APP" ] \
  && [ -f "$FS_WORKER" ] && [ ! -L "$FS_WORKER" ] && [ -x "$FS_WORKER" ] \
  || { echo "desktop live gate: filesystem worker is missing or indirect: $FS_WORKER" >&2; exit 66; }
[ -d "$RENDERER_WORKER_APP" ] && [ ! -L "$RENDERER_WORKER_APP" ] \
  && [ -f "$RENDERER_WORKER" ] && [ ! -L "$RENDERER_WORKER" ] \
  && [ -x "$RENDERER_WORKER" ] \
  || { echo "desktop live gate: renderer worker is missing or indirect: $RENDERER_WORKER" >&2; exit 66; }
QUALIFY_UBUNTU_ACCELERATION=0
case "$SELECTED_DISTRO" in
  all|ubuntu) QUALIFY_UBUNTU_ACCELERATION=1 ;;
esac
assets=("$KERNEL")
[ "$QUALIFY_UBUNTU_ACCELERATION" = 0 ] || assets+=("$ZED_ARCHIVE")
case "$SELECTED_DISTRO" in
  all) assets+=("$DEBIAN_ROOTFS" "$UBUNTU_ROOTFS" "$KALI_ROOTFS" "$DEBIAN_UPDATE" "$UBUNTU_UPDATE" "$KALI_UPDATE") ;;
  debian) assets+=("$DEBIAN_ROOTFS" "$DEBIAN_UPDATE") ;;
  ubuntu) assets+=("$UBUNTU_ROOTFS" "$UBUNTU_UPDATE") ;;
  kali) assets+=("$KALI_ROOTFS" "$KALI_UPDATE") ;;
esac
for asset in "${assets[@]}"; do
  [ -f "$asset" ] && [ ! -L "$asset" ] && [ -s "$asset" ] \
    || { echo "desktop live gate: missing regular asset: $asset" >&2; exit 66; }
done
absolute_asset() {
  local asset_input="$1"
  local asset_directory
  asset_directory="$(cd "$(dirname "$asset_input")" && pwd -P)"
  printf '%s/%s\n' "$asset_directory" "$(basename "$asset_input")"
}
KERNEL="$(absolute_asset "$KERNEL")"
[ "$QUALIFY_UBUNTU_ACCELERATION" = 0 ] \
  || ZED_ARCHIVE="$(absolute_asset "$ZED_ARCHIVE")"
COMPONENT_DIR="$(cd "$COMPONENT_DIR" && pwd -P)"
case "$SELECTED_DISTRO" in
  all)
    DEBIAN_ROOTFS="$(absolute_asset "$DEBIAN_ROOTFS")"
    UBUNTU_ROOTFS="$(absolute_asset "$UBUNTU_ROOTFS")"
    KALI_ROOTFS="$(absolute_asset "$KALI_ROOTFS")"
    DEBIAN_UPDATE="$(absolute_asset "$DEBIAN_UPDATE")"
    UBUNTU_UPDATE="$(absolute_asset "$UBUNTU_UPDATE")"
    KALI_UPDATE="$(absolute_asset "$KALI_UPDATE")"
    ;;
  debian)
    DEBIAN_ROOTFS="$(absolute_asset "$DEBIAN_ROOTFS")"
    DEBIAN_UPDATE="$(absolute_asset "$DEBIAN_UPDATE")"
    ;;
  ubuntu)
    UBUNTU_ROOTFS="$(absolute_asset "$UBUNTU_ROOTFS")"
    UBUNTU_UPDATE="$(absolute_asset "$UBUNTU_UPDATE")"
    ;;
  kali)
    KALI_ROOTFS="$(absolute_asset "$KALI_ROOTFS")"
    KALI_UPDATE="$(absolute_asset "$KALI_UPDATE")"
    ;;
esac
printf '%s\n' "$DESKTOP_VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' \
  || { echo "desktop live gate: invalid desktop version: $DESKTOP_VERSION" >&2; exit 64; }
if [ "$QUALIFY_UBUNTU_ACCELERATION" = 1 ]; then
  printf '%s\n' "$ZED_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "desktop live gate: invalid Zed version: $ZED_VERSION" >&2; exit 64; }
  TUPLE_ZED_TAG="$(python3 - "$ROOT/Config/DoryRendererProductionTuple.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)["guestMesaBuildPolicy"]["applicationReadiness"]["applicationTag"]
if not isinstance(value, str) or not value.startswith("v"):
    raise SystemExit("renderer tuple has an invalid application tag")
print(value)
PY
)" || { echo "desktop live gate: cannot read the renderer tuple Zed tag" >&2; exit 66; }
  [ "v$ZED_VERSION" = "$TUPLE_ZED_TAG" ] \
    || { echo "desktop live gate: Zed $ZED_VERSION differs from tuple $TUPLE_ZED_TAG" >&2; exit 66; }
  printf '%s\n' "$ZED_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
    || { echo "desktop live gate: invalid Zed digest" >&2; exit 64; }
  [ "$(shasum -a 256 "$ZED_ARCHIVE" | awk '{print $1}')" = "$ZED_SHA256" ] \
    || { echo "desktop live gate: Zed archive digest mismatch" >&2; exit 66; }
fi
[ -n "${RUNNER_TEMP:-}" ] \
  || { echo "desktop live gate: RUNNER_TEMP must identify the dedicated release workspace" >&2; exit 64; }
case "$RUNNER_TEMP" in /*) ;; *) echo "desktop live gate: RUNNER_TEMP must be absolute" >&2; exit 64 ;; esac
case "$WORKROOT" in /*) ;; *) echo "desktop live gate: workroot must be absolute" >&2; exit 64 ;; esac
[ ! -L "$WORKROOT" ] \
  || { echo "desktop live gate: workroot must not be a symlink" >&2; exit 64; }
WORKROOT="$(python3 - "$RUNNER_TEMP" "$WORKROOT" <<'PY'
import os
import sys

runner, requested = map(os.path.realpath, sys.argv[1:])
if requested == runner or not requested.startswith(runner.rstrip(os.sep) + os.sep):
    raise SystemExit("workroot must be a strict child of RUNNER_TEMP")
print(requested)
PY
)" || { echo "desktop live gate: unsafe workroot: $WORKROOT" >&2; exit 64; }

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT/share" "$WORKROOT/evidence"
printf 'Dory desktop release gate\n' > "$WORKROOT/share/host-marker.txt"
if [ "$QUALIFY_UBUNTU_ACCELERATION" = 1 ]; then
  cp "$ZED_ARCHIVE" "$WORKROOT/share/zed-linux-aarch64.tar.gz"
  [ "$(shasum -a 256 "$WORKROOT/share/zed-linux-aarch64.tar.gz" | awk '{print $1}')" = "$ZED_SHA256" ]
fi
verify_bundle_info() {
  local info="$1" identifier="$2" executable="$3" package_type="$4" service_type="$5" label="$6"
  shift 6
  python3 - "$info" "$identifier" "$executable" "$package_type" \
    "$service_type" "$label" "$@" <<'PY'
import os
import plistlib
import stat
import sys

path, identifier, executable, package_type, service_type, label, *usage_keys = sys.argv[1:]
entry = os.lstat(path)
if not stat.S_ISREG(entry.st_mode) or entry.st_size <= 0:
    raise SystemExit(f"desktop live gate: {label} Info.plist is not a direct regular file")
with open(path, "rb") as handle:
    info = plistlib.load(handle)
expected = {
    "CFBundleIdentifier": identifier,
    "CFBundleExecutable": executable,
    "CFBundlePackageType": package_type,
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"desktop live gate: {label} {key} is not {value}")
if service_type != "-" and info.get("XPCService") != {"ServiceType": service_type}:
    raise SystemExit(f"desktop live gate: {label} XPC service identity is invalid")
for key in usage_keys:
    value = info.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"desktop live gate: {label} is missing {key}")
PY
}

verify_exact_worker_graph() {
  python3 - "$RUNNER_APP/Contents/XPCServices" <<'PY'
import os
import sys

root = sys.argv[1]
expected = {"DoryFSWorker.xpc", "DoryRendererWorker.xpc"}
entries = {entry.name: entry for entry in os.scandir(root)}
if set(entries) != expected or not all(
    entry.is_dir(follow_symlinks=False) and not entry.is_symlink()
    for entry in entries.values()
):
    raise SystemExit("desktop live gate: DoryHVRunner XPC worker graph is not exact")
PY
}

verify_exact_entitlements() {
  local bundle="$1" policy="$2" label="$3" output="$4"
  codesign -d --entitlements - --xml "$bundle" \
    > "$output" 2> "$output.codesign.txt"
  python3 - "$output" "$policy" "$label" <<'PY'
import plistlib
import sys

path, policy, label = sys.argv[1:]
expected = {
    "outer": {
        "com.apple.security.application-groups": [
            "864H636QW4.group.com.pythonxi.Dory"
        ],
        "com.apple.security.device.audio-input": True,
        "com.apple.security.network.client": True,
        "com.apple.security.network.server": True,
    },
    "runner": {
        "com.apple.security.device.audio-input": True,
        "com.apple.security.device.camera": True,
        "com.apple.security.hypervisor": True,
    },
    "filesystem-worker": {},
    "renderer-worker": {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.application-groups": ["864H636QW4.dory-renderer"],
    },
    "vmm": {
        "com.apple.security.device.audio-input": True,
        "com.apple.security.virtualization": True,
    },
}[policy]
with open(path, "rb") as handle:
    actual = plistlib.load(handle)
if "com.apple.security.cs.disable-library-validation" in actual:
    raise SystemExit(f"desktop live gate: {label} retains forbidden library-validation authority")
if policy == "vmm" and any("xpc" in key.lower() for key in actual):
    raise SystemExit(f"desktop live gate: {label} retains forbidden XPC authority")
if actual != expected:
    raise SystemExit(
        f"desktop live gate: {label} entitlements are not exact "
        f"(actual={actual!r}, expected={expected!r})"
    )
PY
}

developer_id_requirement() {
  local identifier="$1"
  printf '%s\n' \
    "identifier \"$identifier\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"864H636QW4\""
}

verify_release_identity() {
  local bundle="$1" identifier="$2" label="$3" requirement actual details
  requirement="$(developer_id_requirement "$identifier")"
  codesign --verify --strict "-R=$requirement" "$bundle" \
    || { echo "desktop live gate: $label is not signed by Dory's Developer ID" >&2; return 1; }
  actual="$(codesign -d -r- "$bundle" 2>&1 | sed -n 's/^designated => //p')"
  [ "$actual" = "$requirement" ] \
    || { echo "desktop live gate: $label designated requirement is not canonical" >&2; return 1; }
  details="$WORKROOT/evidence/$label-signature.txt"
  codesign -d --verbose=4 "$bundle" > /dev/null 2> "$details"
  grep -Fqx "Identifier=$identifier" "$details" \
    || { echo "desktop live gate: $label signing identifier is invalid" >&2; return 1; }
  grep -Fqx 'TeamIdentifier=864H636QW4' "$details" \
    || { echo "desktop live gate: $label signing team is invalid" >&2; return 1; }
  grep -Eq '^CodeDirectory .*flags=.*\([^)]*runtime[^)]*\)' "$details" \
    || { echo "desktop live gate: $label is not hardened-runtime signed" >&2; return 1; }
}

verify_bundle_info "$RUNNER_APP/Contents/Info.plist" \
  com.pythonxi.Dory.HVRunner dory-hv APPL - DoryHVRunner \
  NSCameraUsageDescription NSMicrophoneUsageDescription
verify_bundle_info "$FS_WORKER_APP/Contents/Info.plist" \
  com.pythonxi.Dory.HVRunner.FSWorker DoryFSWorker 'XPC!' Application DoryFSWorker
verify_bundle_info "$RENDERER_WORKER_APP/Contents/Info.plist" \
  com.pythonxi.Dory.HVRunner.RendererWorker DoryRendererWorker 'XPC!' Application DoryRendererWorker
verify_bundle_info "$VZ_VMM_INFO" dory-vmm dory-vmm APPL - DoryVMM \
  NSMicrophoneUsageDescription
verify_exact_worker_graph
[ ! -e "$VZ_VMM_APP/Contents/XPCServices" ] \
  || { echo "desktop live gate: DoryVMM must not contain XPCServices" >&2; exit 1; }

codesign --verify --strict "$FS_WORKER_APP"
codesign --verify --strict "$RENDERER_WORKER_APP"
codesign --verify --deep --strict "$RUNNER_APP"
codesign --verify --deep --strict "$VZ_VMM_APP"
verify_exact_entitlements "$RUNNER_APP" runner DoryHVRunner \
  "$WORKROOT/evidence/dory-hv-entitlements.plist"
verify_exact_entitlements "$FS_WORKER_APP" filesystem-worker DoryFSWorker \
  "$WORKROOT/evidence/dory-fs-worker-entitlements.plist"
verify_exact_entitlements "$RENDERER_WORKER_APP" renderer-worker DoryRendererWorker \
  "$WORKROOT/evidence/dory-renderer-worker-entitlements.plist"
verify_exact_entitlements "$VZ_VMM_APP" vmm DoryVMM \
  "$WORKROOT/evidence/dory-vmm-entitlements.plist"
if [ "$REQUIRE_RELEASE_SIGNATURE" = 1 ]; then
  verify_release_identity "$RUNNER_APP" com.pythonxi.Dory.HVRunner DoryHVRunner
  verify_release_identity "$FS_WORKER_APP" \
    com.pythonxi.Dory.HVRunner.FSWorker DoryFSWorker
  verify_release_identity "$RENDERER_WORKER_APP" \
    com.pythonxi.Dory.HVRunner.RendererWorker DoryRendererWorker
  verify_release_identity "$VZ_VMM_APP" dory-vmm DoryVMM
  python3 "$ROOT/scripts/verify-renderer-bootstrap-qualification.py" \
    --runner-app "$RUNNER_APP" --managed-kernel "$KERNEL" \
    --repo-root "$ROOT" --require-release-signature \
    > "$WORKROOT/evidence/renderer-bootstrap-qualification.txt"
  grep -Fqx 'renderer.qualification.releaseSignature=verified' \
    "$WORKROOT/evidence/renderer-bootstrap-qualification.txt"
  RENDERER_RELEASE_SIGNATURE_RESULT=PASS
fi

require_arm64_slice() {
  local executable="$1" label="$2"
  lipo -archs "$executable" | tr ' ' '\n' | grep -Fqx arm64 \
    || { echo "desktop live gate: $label does not contain arm64 code" >&2; return 1; }
}
require_arm64_slice "$CTL" dorydctl
require_arm64_slice "$VMM" DoryHVRunner
require_arm64_slice "$FS_WORKER" DoryFSWorker
require_arm64_slice "$RENDERER_WORKER" DoryRendererWorker
require_arm64_slice "$VZ_VMM" DoryVMM

case "$HELPERS" in
  */Dory.app/Contents/Helpers)
    OUTER_APP="${HELPERS%/Contents/Helpers}"
    ;;
  *)
    echo "desktop live gate: helpers are not inside the exact Dory.app candidate" >&2
    exit 66
    ;;
esac
OUTER_INFO="$OUTER_APP/Contents/Info.plist"
OUTER_EXECUTABLE="$OUTER_APP/Contents/MacOS/Dory"
[ -d "$OUTER_APP" ] && [ ! -L "$OUTER_APP" ] \
  || { echo "desktop live gate: outer Dory.app is missing or indirect" >&2; exit 66; }
[ -f "$OUTER_EXECUTABLE" ] && [ ! -L "$OUTER_EXECUTABLE" ] \
  && [ -x "$OUTER_EXECUTABLE" ] \
  || { echo "desktop live gate: outer Dory executable is missing or indirect" >&2; exit 66; }
require_arm64_slice "$OUTER_EXECUTABLE" 'outer Dory application'
verify_bundle_info "$OUTER_INFO" com.pythonxi.Dory Dory APPL - Dory \
  NSMicrophoneUsageDescription
python3 - "$OUTER_INFO" "$DESKTOP_VERSION" <<'PY'
import plistlib
import re
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
if info.get("CFBundleShortVersionString") != sys.argv[2]:
    raise SystemExit("desktop live gate: outer Dory release version differs from the candidate")
build = info.get("CFBundleVersion")
if not isinstance(build, str) or re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", build) is None:
    raise SystemExit("desktop live gate: outer Dory build version is invalid")
PY
codesign --verify --deep --strict "$OUTER_APP"
verify_exact_entitlements "$OUTER_APP" outer Dory \
  "$WORKROOT/evidence/dory-entitlements.plist"
if [ "$REQUIRE_RELEASE_SIGNATURE" = 1 ]; then
  verify_release_identity "$OUTER_APP" com.pythonxi.Dory Dory
fi

BINDING_EVIDENCE="$WORKROOT/evidence/exact-release-binding.json"
capture_release_binding() {
  local destination="$1"
  python3 - \
    "$ROOT/scripts/build-components.py" "$ROOT" "$COMPONENT_DIR" "$OUTER_APP" \
    "$CTL" "$OUTER_EXECUTABLE" "$VMM" "$FS_WORKER" "$RENDERER_WORKER" \
    "$VZ_VMM" "$DESKTOP_VERSION" "$destination" <<'PY'
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

(
    builder_path,
    repo_path,
    component_path,
    application_path,
    ctl_path,
    outer_executable_path,
    runner_path,
    filesystem_worker_path,
    renderer_worker_path,
    vmm_path,
    expected_version,
    destination_path,
) = sys.argv[1:]
builder_path = pathlib.Path(builder_path)
repo = pathlib.Path(repo_path)
component_root = pathlib.Path(component_path)
application = pathlib.Path(application_path)
destination = pathlib.Path(destination_path)

spec = importlib.util.spec_from_file_location("dory_release_binding", builder_path)
if spec is None or spec.loader is None:
    raise SystemExit("desktop live gate: release-binding verifier could not be loaded")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

def direct_file(path_value: str | pathlib.Path, label: str) -> pathlib.Path:
    path = pathlib.Path(path_value)
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise SystemExit(f"desktop live gate: {label} is missing") from None
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
        raise SystemExit(f"desktop live gate: {label} is indirect or empty")
    return path

def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def code_directory_hash(path: pathlib.Path) -> str:
    completed = subprocess.run(
        ["codesign", "-d", "--verbose=4", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit("desktop live gate: could not read candidate code identity")
    match = re.search(r"^CDHash=([0-9a-f]+)$", completed.stderr, re.MULTILINE)
    if match is None:
        raise SystemExit("desktop live gate: candidate code identity omits CDHash")
    return match.group(1)

inventory, inventory_digest = builder.load_candidate_inventory(component_root)
if inventory["releaseVersion"] != expected_version:
    raise SystemExit("desktop live gate: candidate inventory release differs from Dory.app")
expected_application = {
    key: inventory["core"]["application"][key]
    for key in ("entryCount", "regularFileBytes", "graphSHA256")
}
actual_application = builder.application_tree_binding(application)
if actual_application != expected_application:
    raise SystemExit(
        "desktop live gate: launched Dory.app differs from the candidate inventory"
    )

catalog_path = direct_file(component_root / "catalog.json", "signed component catalog")
catalog_digest_path = direct_file(
    component_root / "catalog.json.sha256", "component catalog digest"
)
catalog_signature_path = direct_file(
    component_root / "catalog.json.sig", "component catalog signature"
)
catalog_bytes = catalog_path.read_bytes()
catalog_digest = hashlib.sha256(catalog_bytes).hexdigest()
if catalog_digest_path.read_text(encoding="ascii") != catalog_digest + "\n":
    raise SystemExit("desktop live gate: catalog digest does not bind catalog.json")
catalog = json.loads(catalog_bytes, object_pairs_hook=builder.unique_json_object)
if catalog_bytes != builder.canonical_json_bytes(catalog):
    raise SystemExit("desktop live gate: component catalog is not canonical JSON")
if (
    catalog.get("kind") != builder.CATALOG_KIND
    or catalog.get("schemaVersion") != builder.CATALOG_SCHEMA
    or catalog.get("releaseVersion") != expected_version
    or catalog.get("architecture") != builder.ARCHITECTURE
):
    raise SystemExit("desktop live gate: signed component catalog identity is invalid")
builder.verify_ed25519_signature(
    repo,
    catalog_path,
    catalog_signature_path,
    builder.DEFAULT_CATALOG_PUBLIC_KEY,
    "component catalog",
)

qualification = catalog.get("virtualMachineQualification")
if not isinstance(qualification, dict):
    raise SystemExit("desktop live gate: catalog omits VM qualification authority")
qualification_component = qualification.get("component")
qualification_installed_path = qualification.get("path")
components = catalog.get("components")
if not isinstance(components, list):
    raise SystemExit("desktop live gate: catalog components are invalid")
component = next(
    (
        value for value in components
        if isinstance(value, dict) and value.get("id") == qualification_component
    ),
    None,
)
if component is None or not isinstance(component.get("assets"), list):
    raise SystemExit("desktop live gate: qualification component is missing")
qualification_asset = next(
    (
        value for value in component["assets"]
        if isinstance(value, dict) and value.get("path") == qualification_installed_path
    ),
    None,
)
signature_asset = next(
    (
        value for value in component["assets"]
        if isinstance(value, dict)
        and value.get("path") == f"{qualification_installed_path}.sig"
    ),
    None,
)
if qualification_asset is None or signature_asset is None:
    raise SystemExit("desktop live gate: qualification evidence assets are incomplete")

def delivered_asset(asset: dict, label: str) -> pathlib.Path:
    if asset.get("compression") != "none" \
            or asset.get("downloadBytes") != asset.get("installedBytes") \
            or asset.get("sha256") != asset.get("installedSHA256"):
        raise SystemExit(f"desktop live gate: {label} is not an exact byte asset")
    url = asset.get("url")
    if not isinstance(url, str):
        raise SystemExit(f"desktop live gate: {label} URL is invalid")
    filename = url.rsplit("/", 1)[-1]
    path = direct_file(component_root / filename, label)
    if path.stat().st_size != asset.get("downloadBytes") or digest(path) != asset.get("sha256"):
        raise SystemExit(f"desktop live gate: delivered {label} differs from the catalog")
    return path

qualification_path = delivered_asset(qualification_asset, "VM qualification manifest")
qualification_signature = delivered_asset(
    signature_asset, "VM qualification signature"
)
builder.verify_ed25519_signature(
    repo,
    qualification_path,
    qualification_signature,
    builder.DEFAULT_CATALOG_PUBLIC_KEY,
    "VM qualification",
)
qualification_manifest = builder.load_qualification_manifest(
    qualification_path,
    release_version=expected_version,
    public_key_base64=builder.DEFAULT_CATALOG_PUBLIC_KEY,
)
candidate_binding = qualification_manifest.get("candidateBinding")
if not isinstance(candidate_binding, dict) \
        or candidate_binding.get("componentCandidateInventorySHA256") != inventory_digest:
    raise SystemExit(
        "desktop live gate: signed VM qualification binds another candidate inventory"
    )

helpers = {
    value["componentIdentifier"]: value for value in inventory["core"]["helpers"]
}
runner = helpers.get("dory-hv")
vmm = helpers.get("dory-vmm")
if runner is None or vmm is None:
    raise SystemExit("desktop live gate: candidate helper inventory is incomplete")
paths = {
    "controlHelperSHA256": direct_file(ctl_path, "dorydctl"),
    "outerExecutableSHA256": direct_file(
        outer_executable_path, "outer Dory executable"
    ),
    "runnerExecutableSHA256": direct_file(runner_path, "DoryHVRunner executable"),
    "filesystemWorkerSHA256": direct_file(
        filesystem_worker_path, "DoryFSWorker executable"
    ),
    "rendererWorkerSHA256": direct_file(
        renderer_worker_path, "DoryRendererWorker executable"
    ),
    "vmmExecutableSHA256": direct_file(vmm_path, "DoryVMM executable"),
}
for record, key, path_value in (
    (runner, "runnerExecutableSHA256", runner_path),
    (vmm, "vmmExecutableSHA256", vmm_path),
):
    path = pathlib.Path(path_value)
    if path.relative_to(application).as_posix() != record["path"] \
            or path.stat().st_size != record["bytes"] \
            or digest(path) != record["sha256"]:
        raise SystemExit("desktop live gate: candidate helper executable binding differs")
outer_binding = inventory["core"]["application"]["signedBundle"]
outer_executable = paths["outerExecutableSHA256"]
if outer_executable.stat().st_size != outer_binding["executableBytes"] \
        or digest(outer_executable) != outer_binding["executableSHA256"]:
    raise SystemExit("desktop live gate: outer Dory executable binding differs")
worker_files = {
    value["path"]: value for value in runner["signedBundle"]["files"]
}
for path_value, relative in (
    (
        filesystem_worker_path,
        "Contents/XPCServices/DoryFSWorker.xpc/Contents/MacOS/DoryFSWorker",
    ),
    (
        renderer_worker_path,
        "Contents/XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker",
    ),
):
    path = pathlib.Path(path_value)
    record = worker_files.get(relative)
    if record is None or path.stat().st_size != record["bytes"] \
            or digest(path) != record["sha256"]:
        raise SystemExit("desktop live gate: candidate XPC worker binding differs")

evidence = {
    "applicationGraphSHA256": expected_application["graphSHA256"],
    "bundleVersion": outer_binding["bundleVersion"],
    "catalogSHA256": catalog_digest,
    "catalogSignatureSHA256": digest(catalog_signature_path),
    "componentCandidateInventorySHA256": inventory_digest,
    "qualificationManifestSHA256": digest(qualification_path),
    "qualificationSignatureSHA256": digest(qualification_signature),
    "releaseVersion": expected_version,
    "runnerCodeDirectoryHash": code_directory_hash(paths["runnerExecutableSHA256"]),
}
for key, path in paths.items():
    evidence[key] = digest(path)
destination.write_bytes(builder.canonical_json_bytes(evidence))
PY
}
capture_release_binding "$BINDING_EVIDENCE"
assert_release_binding_unchanged() {
  local current="$WORKROOT/evidence/exact-release-binding.current.json"
  capture_release_binding "$current"
  cmp -s "$BINDING_EVIDENCE" "$current" \
    || { echo "desktop live gate: exact signed release binding changed before launch" >&2; return 1; }
  rm -f "$current"
}
ACTIVE_MACHINE=""
ZED_RESULT=NOT-SELECTED

cleanup() {
  result=$?
  set +e
  if [ -n "$ACTIVE_MACHINE" ]; then
    "$CTL" machine stop "$ACTIVE_MACHINE" >/dev/null 2>&1 || true
    "$CTL" machine delete "$ACTIVE_MACHINE" >/dev/null 2>&1 || true
  fi
  trap - EXIT INT TERM
  exit "$result"
}
trap cleanup EXIT INT TERM

exec_json() {
  machine="$1"
  shift
  "$CTL" machine exec "$machine" --json --timeout-ms 120000 \
    --output-limit-bytes 262144 -- "$@"
}

assert_exec_token() {
  machine="$1"
  token="$2"
  shift 2
  output="$(exec_json "$machine" "$@")"
  if ! printf '%s\n' "$output" | python3 -c '
import json, sys
token = sys.argv[1]
body = json.load(sys.stdin)
if not isinstance(body, dict):
    raise SystemExit("exec response is not an object")
if body.get("exitCode") != 0 or body.get("timedOut") is not False:
    raise SystemExit(f"exec failed: {body!r}")
stdout = body.get("stdout")
if not isinstance(stdout, str) or token not in stdout:
    raise SystemExit(f"exec response omitted {token!r}: {body!r}")
' "$token"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

wait_for_exec_token() {
  machine="$1"
  token="$2"
  shift 2
  for _attempt in $(seq 1 60); do
    if output="$(assert_exec_token "$machine" "$token" "$@" 2>/dev/null)"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 1
  done
  echo "desktop live gate: $machine did not satisfy $token readiness" >&2
  assert_exec_token "$machine" "$token" "$@"
}

wait_for_desktop() {
  machine="$1"
  manager="$2"
  session="$3"
  for _attempt in $(seq 1 120); do
    if assert_exec_token "$machine" desktop-ready sh -lc \
      "systemctl is-active '$manager' >/dev/null && pgrep -u dorygate -x '$session' >/dev/null && echo desktop-ready" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  "$CTL" machine status "$machine" >&2 || true
  echo "desktop live gate: $machine did not reach its graphical session" >&2
  return 1
}

wait_for_running() {
  machine="$1"
  for _attempt in $(seq 1 240); do
    if "$CTL" machine status "$machine" 2>/dev/null | python3 -c '
import json, sys
body = json.load(sys.stdin)
raise SystemExit(0 if body.get("state") == "running" else 1)
'; then
      return 0
    fi
    sleep 0.25
  done
  "$CTL" machine status "$machine" >&2 || true
  echo "desktop live gate: $machine did not complete its ready handoff" >&2
  return 1
}

run_desktop() {
  distro="$1"
  rootfs="$2"
  manager="$3"
  session="$4"
  browser="$5"
  browser_pattern="$6"
  browser_desktop="$7"
  update_bundle="$8"
  shift 8
  expected_apps="$*"
  machine="dory-release-desktop-${distro}-$$"
  ACTIVE_MACHINE="$machine"
  assert_release_binding_unchanged

  component_id="desktop-$distro"
  candidate_result="$WORKROOT/evidence/$distro-component-import.json"
  "$CTL" component install-candidate "$component_id" \
    --candidate-dir "$COMPONENT_DIR" --json > "$candidate_result"
  selection="$WORKROOT/evidence/$distro-component-selection.txt"
  python3 - "$candidate_result" "$COMPONENT_DIR/catalog.json" \
    "$component_id" "$DESKTOP_VERSION" > "$selection" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

result_path, catalog_path, component_id, expected_version = sys.argv[1:]
result = json.loads(pathlib.Path(result_path).read_text(encoding="utf-8"))
if not isinstance(result, dict) or set(result) != {
    "catalogDigest", "installations", "operationID", "schema", "schemaVersion"
}:
    raise SystemExit("component import response has an unexpected shape")
if result["schema"] != "dev.dory.component-candidate-import" or result["schemaVersion"] != 2:
    raise SystemExit("component import response has an unexpected contract")
operation_id = result["operationID"]
if not isinstance(operation_id, str) or re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
    operation_id,
) is None:
    raise SystemExit("component import response has an invalid operation identity")
digest = result["catalogDigest"]
if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("component import response has an invalid catalog digest")
actual_catalog_digest = hashlib.sha256(pathlib.Path(catalog_path).read_bytes()).hexdigest()
if digest != actual_catalog_digest:
    raise SystemExit("component import response binds another catalog")
installations = result["installations"]
if not isinstance(installations, dict) or set(installations) != {"linux-desktop", component_id}:
    raise SystemExit("component import response does not contain the exact desktop dependency set")
safe_id = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,254}")
for value in installations.values():
    if not isinstance(value, str) or safe_id.fullmatch(value) is None:
        raise SystemExit("component import response has an invalid installation identity")

catalog = json.loads(pathlib.Path(catalog_path).read_text(encoding="utf-8"))
if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 2:
    raise SystemExit("signed component catalog is not schema 2")
if catalog.get("releaseVersion") != expected_version:
    raise SystemExit("signed component catalog release differs from the desktop candidate")
components = catalog.get("components")
if not isinstance(components, list):
    raise SystemExit("signed component catalog omits components")
matches = {
    row.get("id"): row for row in components
    if isinstance(row, dict) and row.get("id") in {"linux-desktop", component_id}
}
if set(matches) != {"linux-desktop", component_id}:
    raise SystemExit("signed component catalog omits the selected desktop components")
runtime_version = matches["linux-desktop"].get("version")
distribution_version = matches[component_id].get("version")
for value in (runtime_version, distribution_version):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", value) is None:
        raise SystemExit("signed component version is invalid")

print(digest)
print(installations["linux-desktop"])
print(installations[component_id])
print(runtime_version)
print(distribution_version)
PY
  [ "$(wc -l < "$selection" | tr -d ' ')" = 5 ] \
    || { echo "desktop live gate: invalid component selection evidence" >&2; exit 1; }
  catalog_digest="$(sed -n '1p' "$selection")"
  runtime_installation="$(sed -n '2p' "$selection")"
  distribution_installation="$(sed -n '3p' "$selection")"
  runtime_version="$(sed -n '4p' "$selection")"
  distribution_version="$(sed -n '5p' "$selection")"
  update_version="$distribution_version+runtime.$runtime_version"

  "$CTL" component verify all --offline --json \
    > "$WORKROOT/evidence/$distro-component-verify.json"
  installed_kernel="$("$CTL" component path linux-desktop dory-desktop-kernel-arm64.lzfse)"
  installed_rootfs="$("$CTL" component path "$component_id" \
    "dory-desktop-$distro-rootfs-arm64.ext4.lzfse")"
  installed_update="$("$CTL" component path "$component_id" \
    "dory-desktop-$distro-update-arm64.tar")"
  for installed_asset in "$installed_kernel" "$installed_rootfs" "$installed_update"; do
    [ -f "$installed_asset" ] && [ ! -L "$installed_asset" ] && [ -s "$installed_asset" ] \
      || { echo "desktop live gate: installed component asset is invalid: $installed_asset" >&2; exit 1; }
  done
  cmp -s "$KERNEL" "$installed_kernel" \
    || { echo "desktop live gate: installed desktop kernel differs from the candidate" >&2; exit 1; }
  cmp -s "$rootfs" "$installed_rootfs" \
    || { echo "desktop live gate: installed $distro rootfs differs from the candidate" >&2; exit 1; }
  cmp -s "$update_bundle" "$installed_update" \
    || { echo "desktop live gate: installed $distro update differs from the candidate" >&2; exit 1; }

  if "$CTL" machine status "$machine" >/dev/null 2>&1; then
    echo "desktop live gate: refusing to overwrite existing machine $machine" >&2
    exit 1
  fi

  created="$WORKROOT/evidence/$distro-create.json"
  graphics_preference=auto
  [ "$REQUIRE_ACCELERATION" = 0 ] || graphics_preference=virgl-venus
  "$CTL" machine create "$machine" \
    --kernel "$installed_kernel" --rootfs "$installed_rootfs" --memory-mb 4096 --cpus 4 \
    --display-mode desktop \
    --share "releasegate=$WORKROOT/share:/home/dorygate/Mac:ro" \
    --guest-user dorygate --guest-uid 1550 \
    --desktop-distro "$distro" --runtime accelerated --graphics "$graphics_preference" \
    --clipboard bidirectional > "$created"
  python3 - "$created" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("state") != "created":
    raise SystemExit(f"machine create did not return created: {body!r}")
if body.get("displayMode") != "desktop":
    raise SystemExit(f"machine create did not retain desktop mode: {body!r}")
PY

  assert_release_binding_unchanged
  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-start.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  "$CTL" machine status "$machine" > "$WORKROOT/evidence/$distro-running.json"
  machine_pid="$(python3 - "$WORKROOT/evidence/$distro-running.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("state") != "running" \
        or body.get("displayMode") != "desktop":
    raise SystemExit(f"machine did not reach running desktop state: {body!r}")
pid = body.get("pid")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(f"machine status has an invalid pid: {body!r}")
print(pid)
PY
)"
  launched_executable="$(python3 - "$machine_pid" <<'PY'
import ctypes
import os
import sys

pid = int(sys.argv[1])
buffer = ctypes.create_string_buffer(4096)
length = ctypes.CDLL(None).proc_pidpath(pid, buffer, len(buffer))
if length <= 0:
    raise SystemExit("desktop live gate: could not resolve the launched VM executable")
print(os.path.realpath(os.fsdecode(buffer.value)))
PY
)"
  [ "$launched_executable" = "$VMM" ] \
    || { echo "desktop live gate: machine launched a different VM helper: $launched_executable" >&2; exit 1; }
  expected_vmm_digest="$(python3 - "$BINDING_EVIDENCE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["runnerExecutableSHA256"])
PY
)"
  [ "$(shasum -a 256 "$launched_executable" | awk '{print $1}')" = \
      "$expected_vmm_digest" ] \
    || { echo "desktop live gate: launched VM helper digest differs from the candidate" >&2; exit 1; }
  codesign --verify --strict "$machine_pid"
  running_cdhash="$(codesign -d --verbose=4 "$machine_pid" 2>&1 \
    | sed -n 's/^CDHash=//p')"
  expected_cdhash="$(python3 - "$BINDING_EVIDENCE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["runnerCodeDirectoryHash"])
PY
)"
  [ -n "$running_cdhash" ] && [ "$running_cdhash" = "$expected_cdhash" ] \
    || { echo "desktop live gate: running VM code identity differs from the candidate" >&2; exit 1; }
  assert_release_binding_unchanged
  ps -ww -p "$machine_pid" -o command= | grep -F "$VMM" \
    > "$WORKROOT/evidence/$distro-vmm-command.txt"
  if [ "$REQUIRE_ACCELERATION" = 1 ]; then
    grep -F -- '--resolved-graphics hardware-accelerated-3d' \
      "$WORKROOT/evidence/$distro-vmm-command.txt"
  else
    grep -E -- '--resolved-graphics (hardware-accelerated-3d|software)' \
      "$WORKROOT/evidence/$distro-vmm-command.txt"
  fi

  app_checks=""
  for app in $expected_apps; do
    app_checks="$app_checks command -v '$app' >/dev/null;"
  done
  wait_for_exec_token "$machine" system-pass sh -lc "
    set -eu
    systemctl is-active '$manager' >/dev/null
    systemctl is-active dory-zram.service >/dev/null
    requested_graphics=\$(cat /run/dory/graphics-requested-backend)
    effective_graphics=\$(cat /run/dory/graphics-backend)
    if test '$REQUIRE_ACCELERATION' = 1; then
      test \"\$requested_graphics\" = virgl2+venus
      test \"\$effective_graphics\" = virgl2+venus
      grep -q '^venus-ready:' /run/dory/graphics-status
    else
      case \"\$requested_graphics:\$effective_graphics\" in
        virgl2+venus:virgl2+venus)
          grep -q '^venus-ready:' /run/dory/graphics-status
          ;;
        virgl2+venus:virgl2)
          grep -q '^venus-unavailable:' /run/dory/graphics-status
          grep -q 'fallback=virgl2$' /run/dory/graphics-status
          ;;
        software:software)
          grep -q '^software-ready$' /run/dory/graphics-status
          ;;
        *)
          echo \"inconsistent managed-desktop graphics resolution: \$requested_graphics -> \$effective_graphics\" >&2
          exit 1
          ;;
      esac
    fi
    grep -q '^/dev/zram0 ' /proc/swaps
    pgrep -u dorygate -x '$session' >/dev/null
    desktop_uid=\$(id -u dorygate)
    desktop_environment=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      systemctl --user show-environment)
    printf '%s\n' \"\$desktop_environment\" | grep -Fqx 'GSK_RENDERER=gl'
    if test '$distro' = ubuntu; then
      printf '%s\n' \"\$desktop_environment\" | grep -Fqx 'MOZ_ENABLE_WAYLAND=0'
      printf '%s\n' \"\$desktop_environment\" | grep -Fqx 'XDG_SESSION_TYPE=x11'
    fi
    if test \"\$effective_graphics\" = virgl2+venus; then
      printf '%s\n' \"\$desktop_environment\" | grep -Fqx \
        'VK_DRIVER_FILES=/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json'
      printf '%s\n' \"\$desktop_environment\" | grep -Fqx \
        'VK_ICD_FILENAMES=/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json'
    elif printf '%s\n' \"\$desktop_environment\" \
        | grep -Eq '^(VK_DRIVER_FILES|VK_ICD_FILENAMES)='; then
      echo 'Venus environment survived a non-Venus recovery backend' >&2
      exit 1
    fi
    if printf '%s\n' \"\$desktop_environment\" \
        | grep -Eq '^LD_LIBRARY_PATH=.|^venus_implicit_fencing='; then
      echo 'retired process-wide renderer override reached the desktop session' >&2
      exit 1
    fi
    ethernet=\$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '\$2 ~ /^ethernet\$/ && \$3 ~ /^connected\$/ { print \$1; exit }')
    test -n \"\$ethernet\"
    ip -4 -o addr show dev \"\$ethernet\" | grep -q ' inet '
    test \"\$(nmcli -g GENERAL.CONNECTION device show \"\$ethernet\")\" = 'Dory Wired'
    test \"\$(readlink /etc/resolv.conf)\" = ../run/NetworkManager/resolv.conf
    getent ahostsv4 example.com >/dev/null
    test \"\$(curl -4 -fsS --max-time 30 -o /dev/null -w '%{http_code}' https://example.com)\" = 200
    command -v '$browser' >/dev/null
    command -v gio >/dev/null
    test -f '$browser_desktop'
    command -v xwininfo >/dev/null
    $app_checks
    grep -q 'virtio-snd' /proc/asound/cards
    grep -q 'playback' /proc/asound/pcm
    grep -q 'capture' /proc/asound/pcm
    audio_status=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      wpctl status)
    test \"\$(printf '%s\\n' \"\$audio_status\" | grep -Fc 'Dory Audio Pro')\" -ge 2
    runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      timeout 15 aplay -D pipewire -q -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero
    runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      timeout 15 arecord -D pipewire -q -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/null
    mountpoint -q /home/dorygate/Mac
    grep -qx 'Dory desktop release gate' /home/dorygate/Mac/host-marker.txt
    ! touch /home/dorygate/Mac/write-must-fail 2>/dev/null
    printf persistence-pass > /home/dorygate/.dory-release-marker
    echo system-pass
  " > "$WORKROOT/evidence/$distro-system.json"

  if [ "$REQUIRE_ACCELERATION" = 1 ]; then
    assert_exec_token "$machine" mesa-virgl-desktop sh -lc "
      set -eu
      test \"\$(cat /run/dory/graphics-requested-backend)\" = virgl2+venus
      test \"\$(cat /run/dory/graphics-backend)\" = virgl2+venus
      command -v glxinfo >/dev/null
      command -v glxgears >/dev/null
      uid=\$(id -u dorygate)
      runtime=/run/user/\$uid
      session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
        DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
        | grep -E '^(DISPLAY|XAUTHORITY)=')
      display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
      xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
      test -n \"\$display\"
      test -n \"\$xauth\"
      glx=\$(runuser -u dorygate -- env -u LIBGL_ALWAYS_SOFTWARE \
        DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" glxinfo -B)
      printf '%s\n' \"\$glx\"
      printf '%s\n' \"\$glx\" | grep -Eiq '^direct rendering:[[:space:]]*Yes$'
      printf '%s\n' \"\$glx\" | grep -Eiq '^OpenGL renderer string:.*virgl'
      if printf '%s\n' \"\$glx\" \
          | grep -Eiq 'llvmpipe|softpipe|swrast|software rasterizer'; then
        echo 'Mesa desktop probe selected a software renderer' >&2
        exit 1
      fi
      rm -f /tmp/dory-release-glxgears.log
      runuser -u dorygate -- env -u LIBGL_ALWAYS_SOFTWARE \
        DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" glxgears -info \
        >/tmp/dory-release-glxgears.log 2>&1 &
      launcher=\$!
      mapped=0
      for _ in \$(seq 1 30); do
        if kill -0 \"\$launcher\" 2>/dev/null \
            && runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
              xwininfo -root -tree 2>/dev/null | grep -Eiq 'glxgears'; then
          mapped=1
          break
        fi
        sleep 1
      done
      test \"\$mapped\" = 1
      sleep 30
      kill -0 \"\$launcher\"
      pgrep -u dorygate -x '$session' >/dev/null
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xwininfo -root -tree 2>/dev/null | grep -Eiq 'glxgears'
      if grep -Eiq 'llvmpipe|softpipe|swrast|software rasterizer|device lost|context lost|GPU reset' \
          /tmp/dory-release-glxgears.log; then
        cat /tmp/dory-release-glxgears.log >&2
        exit 1
      fi
      kill \"\$launcher\"
      wait \"\$launcher\" 2>/dev/null || true
      echo mesa-virgl-desktop
    " > "$WORKROOT/evidence/$distro-mesa-virgl.json"
    MESA_VIRGL_DESKTOP_RESULT=PASS
  fi

  # Arm a receipt that can only be written by systemd while the guest is performing an orderly
  # shutdown. Merely terminating the VM helper cannot create this marker, so the subsequent boot
  # distinguishes graceful guest shutdown from the host watchdog fallback.
  assert_exec_token "$machine" graceful-shutdown-armed sh -lc "
    set -eu
    marker=/var/lib/dory/release-graceful-shutdown
    unit=/etc/systemd/system/dory-release-graceful-shutdown.service
    rm -f \"\$marker\"
    printf '%s\n' \
      '[Unit]' \
      'Description=Dory release gate graceful shutdown receipt' \
      'After=multi-user.target' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      'ExecStart=/bin/true' \
      \"ExecStop=/bin/sh -c 'printf graceful-shutdown-pass > \$marker; sync'\" \
      'RemainAfterExit=yes' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' > \"\$unit\"
    systemctl daemon-reload
    systemctl enable --now dory-release-graceful-shutdown.service >/dev/null
    systemctl is-active --quiet dory-release-graceful-shutdown.service
    test ! -e \"\$marker\"
    echo graceful-shutdown-armed
  " > "$WORKROOT/evidence/$distro-graceful-shutdown-armed.json"

  assert_exec_token "$machine" display-baseline-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    mode=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
    printf '%s\n' \"\$mode\" | grep -Eq '^[0-9]+x[0-9]+$'
    printf '%s\n' \"\$mode\" > /var/lib/dory/release-display-baseline
    echo display-baseline-ready
  " > "$WORKROOT/evidence/$distro-display-baseline.json"

  original_window_size="$(osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    if not UI elements enabled then error "Accessibility permission is required for display qualification"
    set targetProcess to first process whose unix id is targetPID
    set originalSize to size of front window of targetProcess
    set size of front window of targetProcess to {960, 640}
    return ((item 1 of originalSize) as text) & "x" & ((item 2 of originalSize) as text)
  end tell
end run
APPLESCRIPT
)"
  printf '%s\n' "$original_window_size" | grep -Eq '^[0-9]+x[0-9]+$' \
    || { echo "desktop live gate: invalid original window size: $original_window_size" >&2; exit 1; }
  printf '%s\n' "$original_window_size" \
    > "$WORKROOT/evidence/$distro-display-original-window.txt"

  assert_exec_token "$machine" dynamic-display-resized sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if printf '%s\n' \"\$current\" | grep -Eq '^[0-9]+x[0-9]+$' \
          && test \"\$current\" != \"\$baseline\"; then
        printf '%s\n' \"\$current\" > /var/lib/dory/release-display-resized
        echo dynamic-display-resized
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not follow the host window resize' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-resized.json"

  original_window_width="${original_window_size%x*}"
  original_window_height="${original_window_size#*x}"
  osascript - "$machine_pid" "$original_window_width" "$original_window_height" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set restoredWidth to (item 2 of argv) as integer
  set restoredHeight to (item 3 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set size of front window of targetProcess to {restoredWidth, restoredHeight}
  end tell
end run
APPLESCRIPT

  assert_exec_token "$machine" dynamic-display-restored sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if test \"\$current\" = \"\$baseline\"; then
        echo dynamic-display-restored
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not return after restoring the host window' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-restored.json"

  fullscreen_window_size="$(osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    keystroke "f" using {command down, control down}
    repeat 80 times
      delay 0.25
      set targetWindow to front window of targetProcess
      if value of attribute "AXFullScreen" of targetWindow is true then
        set fullSize to size of targetWindow
        return ((item 1 of fullSize) as text) & "x" & ((item 2 of fullSize) as text)
      end if
    end repeat
    error "Dory display did not enter full screen"
  end tell
end run
APPLESCRIPT
)"
  printf '%s\n' "$fullscreen_window_size" | grep -Eq '^[0-9]+x[0-9]+$' \
    || { echo "desktop live gate: invalid full-screen window size: $fullscreen_window_size" >&2; exit 1; }
  printf '%s\n' "$fullscreen_window_size" \
    > "$WORKROOT/evidence/$distro-display-fullscreen-window.txt"

  assert_exec_token "$machine" fullscreen-display-resized sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if printf '%s\n' \"\$current\" | grep -Eq '^[0-9]+x[0-9]+$' \
          && test \"\$current\" != \"\$baseline\"; then
        printf '%s\n' \"\$current\" > /var/lib/dory/release-display-fullscreen
        echo fullscreen-display-resized
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not follow the full-screen host window' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-fullscreen.json"

  osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    keystroke "f" using {command down, control down}
    repeat 80 times
      delay 0.25
      if value of attribute "AXFullScreen" of front window of targetProcess is false then return
    end repeat
    error "Dory display did not leave full screen"
  end tell
end run
APPLESCRIPT

  assert_exec_token "$machine" fullscreen-display-restored sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if test \"\$current\" = \"\$baseline\"; then
        echo fullscreen-display-restored
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not restore after leaving full screen' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-fullscreen-restored.json"

  assert_exec_token "$machine" cursor-left-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      xsetroot -cursor_name left_ptr
    echo cursor-left-ready
  " > "$WORKROOT/evidence/$distro-cursor-left.json"

  cursor_point="$(osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    set targetWindow to front window of targetProcess
    set windowPosition to position of targetWindow
    set windowSize to size of targetWindow
    set cursorX to (item 1 of windowPosition) + ((item 1 of windowSize) div 2)
    set cursorY to (item 2 of windowPosition) + ((item 2 of windowSize) div 2)
    click at {cursorX, cursorY}
    delay 0.5
    return (cursorX as text) & "," & (cursorY as text)
  end tell
end run
APPLESCRIPT
)"
  printf '%s\n' "$cursor_point" | grep -Eq '^[0-9]+,[0-9]+$' \
    || { echo "desktop live gate: invalid cursor point: $cursor_point" >&2; exit 1; }
  cursor_x="${cursor_point%,*}"
  cursor_y="${cursor_point#*,}"
  cursor_left=$((cursor_x > 48 ? cursor_x - 48 : 0))
  cursor_top=$((cursor_y > 48 ? cursor_y - 48 : 0))
  cursor_region="$cursor_left,$cursor_top,96,96"
  cursor_left_capture="$WORKROOT/evidence/$distro-cursor-left.png"
  cursor_crosshair_capture="$WORKROOT/evidence/$distro-cursor-crosshair.png"
  screencapture -C -x -R"$cursor_region" "$cursor_left_capture"
  [ -s "$cursor_left_capture" ] \
    || { echo "desktop live gate: screen recording permission is required for cursor qualification" >&2; exit 1; }

  assert_exec_token "$machine" cursor-crosshair-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      xsetroot -cursor_name crosshair
    echo cursor-crosshair-ready
  " > "$WORKROOT/evidence/$distro-cursor-crosshair.json"
  osascript - "$cursor_x" "$cursor_y" <<'APPLESCRIPT'
on run argv
  set cursorX to (item 1 of argv) as integer
  set cursorY to (item 2 of argv) as integer
  tell application "System Events"
    click at {cursorX + 1, cursorY}
    click at {cursorX, cursorY}
    delay 0.5
  end tell
end run
APPLESCRIPT
  screencapture -C -x -R"$cursor_region" "$cursor_crosshair_capture"
  [ -s "$cursor_crosshair_capture" ] \
    || { echo "desktop live gate: crosshair cursor capture is empty" >&2; exit 1; }
  if cmp -s "$cursor_left_capture" "$cursor_crosshair_capture"; then
    echo "desktop live gate: guest cursor shape did not change the captured macOS cursor" >&2
    exit 1
  fi
  {
    shasum -a 256 "$cursor_left_capture"
    shasum -a 256 "$cursor_crosshair_capture"
  } > "$WORKROOT/evidence/$distro-cursor-shapes.sha256"

  assert_exec_token "$machine" cursor-restored sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      xsetroot -cursor_name left_ptr
    echo cursor-restored
  " > "$WORKROOT/evidence/$distro-cursor-restored.json"

  host_to_guest_clipboard="dory-host-to-guest-$distro-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  osascript <<'APPLESCRIPT'
tell application "Finder" to activate
delay 0.25
APPLESCRIPT
  printf '%s' "$host_to_guest_clipboard" | pbcopy
  osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
  end tell
end run
APPLESCRIPT
  assert_exec_token "$machine" clipboard-host-to-guest-pass sh -lc "
    set -eu
    for _ in \$(seq 1 30); do
      actual=\$(/usr/lib/dory/clipboard get 'text/plain;charset=utf-8' 2>/dev/null || true)
      if test \"\$actual\" = '$host_to_guest_clipboard'; then
        echo clipboard-host-to-guest-pass
        exit 0
      fi
      sleep 1
    done
    echo 'host clipboard did not reach the guest' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-clipboard-host-to-guest.json"

  guest_to_host_clipboard="dory-guest-to-host-$distro-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  assert_exec_token "$machine" clipboard-guest-source-ready sh -lc "
    set -eu
    printf '%s' '$guest_to_host_clipboard' \
      | /usr/lib/dory/clipboard set 'text/plain;charset=utf-8'
    echo clipboard-guest-source-ready
  " > "$WORKROOT/evidence/$distro-clipboard-guest-source.json"
  osascript <<'APPLESCRIPT'
tell application "Finder" to activate
APPLESCRIPT
  clipboard_guest_to_host_ok=0
  for _ in $(seq 1 30); do
    if [ "$(pbpaste)" = "$guest_to_host_clipboard" ]; then
      clipboard_guest_to_host_ok=1
      break
    fi
    sleep 1
  done
  [ "$clipboard_guest_to_host_ok" = 1 ] \
    || { echo "desktop live gate: guest clipboard did not reach the host" >&2; exit 1; }
  printf '%s\n' "$guest_to_host_clipboard" \
    > "$WORKROOT/evidence/$distro-clipboard-guest-to-host.txt"

  input_token="doryinputpass$distro"
  assert_exec_token "$machine" input-window-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    marker=/home/dorygate/.dory-release-input
    reader=/tmp/dory-release-input-reader
    rm -f \"\$marker\"
    printf '%s' \
      'IyEvYmluL3NoCklGUz0gcmVhZCAtciBsaW5lCnByaW50ZiAiJXMiICIkbGluZSIgPiAvaG9tZS9kb3J5Z2F0ZS8uZG9yeS1yZWxlYXNlLWlucHV0Cg==' \
      | base64 -d > \"\$reader\"
    chmod 0755 \"\$reader\"
    chown dorygate:dorygate \"\$reader\"
    runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      setsid -f xterm -title DoryInputGate -geometry 200x60+0+0 -e \"\$reader\"
    for _ in \$(seq 1 30); do
      if runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
          xwininfo -root -tree 2>/dev/null | grep -Fq 'DoryInputGate'; then
        echo input-window-ready
        exit 0
      fi
      sleep 1
    done
    echo 'guest input window did not map' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-input-window.json"

  osascript - "$machine_pid" "$input_token" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set inputToken to item 2 of argv
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    set targetWindow to front window of targetProcess
    set windowPosition to position of targetWindow
    set windowSize to size of targetWindow
    set clickX to (item 1 of windowPosition) + ((item 1 of windowSize) div 2)
    set clickY to (item 2 of windowPosition) + ((item 2 of windowSize) div 2)
    delay 0.25
    click at {clickX, clickY}
    delay 0.25
    keystroke inputToken
    key code 36
  end tell
end run
APPLESCRIPT

  assert_exec_token "$machine" keyboard-pointer-input-pass sh -lc "
    set -eu
    marker=/home/dorygate/.dory-release-input
    for _ in \$(seq 1 30); do
      if test -f \"\$marker\" && test \"\$(cat \"\$marker\")\" = '$input_token'; then
        echo keyboard-pointer-input-pass
        exit 0
      fi
      sleep 1
    done
    echo 'host keyboard/pointer input did not reach the guest exactly' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-keyboard-pointer-input.json"

  assert_exec_token "$machine" browser-window-mapped sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR)=')
    display=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    dbus=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
    xauth=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    configured_runtime=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^XDG_RUNTIME_DIR=//p')
    test -n \"\$display\"
    test -n \"\$xauth\"
    test \"\$configured_runtime\" = \"\$runtime\"
    if [ '$distro' = ubuntu ]; then
      favorites=\$(runuser -u dorygate -- env DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \
        XDG_RUNTIME_DIR=\"\$runtime\" gsettings get org.gnome.shell favorite-apps)
      printf '%s\\n' \"\$favorites\" | grep -Fq \"'firefox.desktop'\"
      ! printf '%s\\n' \"\$favorites\" | grep -Fq 'firefox_firefox.desktop'
    fi
    runuser -u dorygate -- env DISPLAY=\"\$display\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \
      XAUTHORITY=\"\$xauth\" XDG_RUNTIME_DIR=\"\$runtime\" MOZ_ENABLE_WAYLAND=0 \
      gio launch '$browser_desktop' https://example.com >/tmp/dory-release-browser.log 2>&1
    for _ in \$(seq 1 30); do
      if pgrep -u dorygate -f '$browser_pattern' >/dev/null \
          && runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
            xwininfo -root -tree 2>/dev/null \
            | grep -Eq '\(\"Navigator\" \"firefox(-esr)?\"\)'; then
        echo browser-running
        echo browser-window-mapped
        exit 0
      fi
      sleep 1
    done
    cat /tmp/dory-release-browser.log >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-browser.json"

  if [ "$distro" = ubuntu ]; then
    assert_exec_token "$machine" gtk-windows-mapped sh -lc "
      set -eu
      uid=\$(id -u dorygate)
      runtime=/run/user/\$uid
      session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
        DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
        | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR|GSK_RENDERER|MOZ_ENABLE_WAYLAND|XDG_SESSION_TYPE)=')
      display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
      dbus=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
      xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
      renderer=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^GSK_RENDERER=//p')
      moz_wayland=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^MOZ_ENABLE_WAYLAND=//p')
      session_type=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XDG_SESSION_TYPE=//p')
      test \"\$renderer\" = gl
      test \"\$moz_wayland\" = 0
      test \"\$session_type\" = x11
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Nautilus.desktop \
        >/tmp/dory-release-files.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Calculator.desktop \
        >/tmp/dory-release-calculator.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Settings.desktop \
        >/tmp/dory-release-settings.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gnome-terminal >/tmp/dory-release-terminal.log 2>&1
      for _ in \$(seq 1 30); do
        windows=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
          xwininfo -root -tree 2>/dev/null)
        if printf '%s\n' \"\$windows\" | grep -Fq '(\"org.gnome.Nautilus\" \"org.gnome.Nautilus\")' \
            && printf '%s\n' \"\$windows\" | grep -Fq '(\"gnome-calculator\" \"gnome-calculator\")' \
            && printf '%s\n' \"\$windows\" | grep -Fq '(\"gnome-control-center\" \"gnome-control-center\")' \
            && printf '%s\n' \"\$windows\" | grep -Eq '\(\"gnome-terminal-server\" \"Gnome-terminal(-server)?\"\)'; then
          for process_pattern in '/usr/bin/nautilus' '/usr/bin/gnome-calculator' 'gnome-control-center'; do
            process_id=\$(pgrep -n -u dorygate -f \"\$process_pattern\")
            tr '\\0' '\\n' <\"/proc/\$process_id/environ\" | grep -Fqx 'GSK_RENDERER=gl'
            if tr '\\0' '\\n' <\"/proc/\$process_id/environ\" | grep -Eq '^LD_LIBRARY_PATH=.'; then
              echo 'GTK process inherited a retired renderer library override' >&2
              exit 1
            fi
          done
          echo gtk-windows-mapped
          exit 0
        fi
        sleep 1
      done
      cat /tmp/dory-release-files.log /tmp/dory-release-calculator.log \
        /tmp/dory-release-settings.log /tmp/dory-release-terminal.log >&2
      exit 1
    " > "$WORKROOT/evidence/$distro-gtk-windows.json"

    # Native Venus application qualification is Ubuntu-only. The baseline gate records an honest
    # optional result; require-acceleration upgrades unavailable or failed evidence to a
    # release-blocking failure.
    ZED_RESULT=UNAVAILABLE
    if assert_exec_token "$machine" venus-available sh -lc \
        "test \"\$(cat /run/dory/graphics-backend)\" = virgl2+venus && echo venus-available" \
        > "$WORKROOT/evidence/$distro-venus-availability.json" 2>&1; then
      if assert_exec_token "$machine" zed-native-venus sh -lc "
        set -eu
        test \"\$(cat /run/dory/graphics-backend)\" = virgl2+venus
        grep -q '^venus-ready:' /run/dory/graphics-status
        for proof in contract=vulkan-1.3-application driver=venus hardware-device=yes \
          dynamic-rendering=yes synchronization2=yes maintenance4=yes \
          color-atlas-texture-binding=yes color-atlas-copy-dst=yes \
          external-sync-fd=yes import-signaled-fd=yes export-sync-fd=yes \
          queue-submit2=yes fence-signal=yes; do
          grep -Fq \"\$proof\" /run/dory/graphics-status
        done
        uid=\$(id -u dorygate)
        runtime=/run/user/\$uid
        complete_session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \\
          DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment)
        if printf '%s\n' \"\$complete_session_env\" \\
            | grep -Eq '^LD_LIBRARY_PATH=.|^(venus_implicit_fencing|ZED_ALLOW_EMULATED_GPU)='; then
          echo 'retired or emulated GPU policy reached the desktop session' >&2
          exit 1
        fi
        session_env=\$(printf '%s\n' \"\$complete_session_env\" \\
          | grep -E '^(DISPLAY|XDG_SESSION_TYPE|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR|VK_DRIVER_FILES|VK_ICD_FILENAMES)=')
        display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
        session_type=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XDG_SESSION_TYPE=//p')
        dbus=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
        xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
        vk_driver=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^VK_DRIVER_FILES=//p')
        vk_icd=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^VK_ICD_FILENAMES=//p')
        test \"\$session_type\" = x11
        test -n \"\$display\"
        test -n \"\$xauth\"
        test -n \"\$vk_driver\"
        test \"\$vk_icd\" = \"\$vk_driver\"
        surface_probe=\$(runuser -u dorygate -- env -u LD_LIBRARY_PATH \
          DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
          XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \
          VK_DRIVER_FILES=\"\$vk_driver\" VK_ICD_FILENAMES=\"\$vk_icd\" \
          timeout 15 /opt/dory/mesa/libexec/dory-vulkan-probe --wsi=xcb)
        for proof in contract=vulkan-1.3-application driver=venus hardware-device=yes \
          dynamic-rendering=yes synchronization2=yes maintenance4=yes \
          color-atlas-texture-binding=yes color-atlas-copy-dst=yes export-sync-fd=yes \
          wsi-surface=xcb surface-create=yes present-queue=yes fifo-present=yes \
          surface-format-policy=first-capability-format \
          swapchain-create=yes swapchain-extent=64x64 swapchain-acquire=yes \
          swapchain-render=yes queue-present=yes present-idle=yes; do
          printf '%s\n' \"\$surface_probe\" | grep -Fq \"\$proof\"
        done
        printf '%s\n' \"\$surface_probe\" | grep -Eq 'surface-format-id=[1-9][0-9]*'
        printf '%s\n' \"\$surface_probe\" | grep -Eq 'color-atlas-format=(bgra8|rgba8)-unorm'
        printf '%s\n' \"\$surface_probe\" | grep -Eq 'swapchain-images=[1-9][0-9]*'
        printf 'vulkan-surface-readiness: %s\n' \"\$surface_probe\"
        rm -rf /home/dorygate/.local/zed.app
        runuser -u dorygate -- mkdir -p /home/dorygate/.local /home/dorygate/Projects/dory-gate
        test \"\$(sha256sum /home/dorygate/Mac/zed-linux-aarch64.tar.gz | awk '{print \$1}')\" \\
          = '$ZED_SHA256'
        printf 'fn main() { println!(\"Dory Venus gate\"); }\n' \\
          > /home/dorygate/Projects/dory-gate/main.rs
        chown -R dorygate:dorygate /home/dorygate/Projects/dory-gate
        runuser -u dorygate -- tar -xzf /home/dorygate/Mac/zed-linux-aarch64.tar.gz \\
          -C /home/dorygate/.local
        test -x /home/dorygate/.local/zed.app/bin/zed
        runuser -u dorygate -- /home/dorygate/.local/zed.app/bin/zed --version \\
          | tr -cs '0-9.' '\\n' | grep -Fx '$ZED_VERSION'
        runuser -u dorygate -- env -u ZED_ALLOW_EMULATED_GPU \\
          DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \\
          XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \\
          VK_DRIVER_FILES=\"\$vk_driver\" VK_ICD_FILENAMES=\"\$vk_icd\" \\
          /home/dorygate/.local/zed.app/bin/zed --foreground \\
          /home/dorygate/Projects/dory-gate/main.rs \\
          >/tmp/dory-release-zed.log 2>&1 &
        zed_cli_pid=\$!
        for _ in \$(seq 1 60); do
          zed_pid=
          for candidate_pid in \$(pgrep -u dorygate -f '/zed.app/libexec/zed-editor' || true); do
            candidate_command=\$(tr '\\0' ' ' <\"/proc/\$candidate_pid/cmdline\")
            case \"\$candidate_command\" in
              *crash-handler*) continue ;;
            esac
            zed_pid=\$candidate_pid
            break
          done
          if test -n \"\$zed_pid\" \\
              && tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -Fqx \"VK_DRIVER_FILES=\$vk_driver\" \\
              && tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -Fqx \"VK_ICD_FILENAMES=\$vk_icd\" \\
              && ! tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -Eq '^LD_LIBRARY_PATH=.' \\
              && ! tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -q '^ZED_ALLOW_EMULATED_GPU=' \\
              && ! tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -q '^venus_implicit_fencing=' \\
              && grep -Fq '/opt/dory/mesa/lib/libvulkan_virtio.so' \"/proc/\$zed_pid/maps\" \\
              && runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \\
                xwininfo -root -tree 2>/dev/null | grep -Eiq 'zed|dory-gate/main.rs'; then
            sleep 30
            kill -0 \"\$zed_cli_pid\"
            kill -0 \"\$zed_pid\"
            grep -Fq '/opt/dory/mesa/lib/libvulkan_virtio.so' \"/proc/\$zed_pid/maps\"
            runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \\
              xwininfo -root -tree 2>/dev/null | grep -Eiq 'zed|dory-gate/main.rs'
            if grep -Eiq 'unsupported GPU|GPU[^[:alnum:]]+not supported|software rendering|llvmpipe|VK_ERROR_DEVICE_LOST|device lost|falling back[^[:alnum:]]+(to )?(CPU|software)' \\
                /tmp/dory-release-zed.log; then
              cat /tmp/dory-release-zed.log >&2
              exit 1
            fi
            echo zed-native-venus
            exit 0
          fi
          sleep 1
        done
        cat /tmp/dory-release-zed.log >&2
        exit 1
      " > "$WORKROOT/evidence/$distro-zed.json" 2> "$WORKROOT/evidence/$distro-zed.stderr"; then
        ZED_RESULT=PASS
      else
        ZED_RESULT=FAIL
        echo "desktop live gate: Ubuntu Venus/Zed qualification failed" >&2
      fi
    else
      printf '%s\n' \
        'Venus unavailable; managed Ubuntu Xorg continued on the VirGL2 compatibility fallback.' \
        > "$WORKROOT/evidence/$distro-zed-skipped.txt"
    fi
    if [ "$REQUIRE_ACCELERATION" = 1 ] && [ "$ZED_RESULT" != PASS ]; then
      echo "desktop live gate: strict acceleration requires native Ubuntu Venus/Zed PASS" >&2
      exit 1
    fi
  fi

  "$CTL" machine stop "$machine" > "$WORKROOT/evidence/$distro-stop.json"
  python3 - "$WORKROOT/evidence/$distro-stop.json" "$machine" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("id") != sys.argv[2] \
        or body.get("state") != "stopped":
    raise SystemExit(f"machine stop did not complete cleanly: {body!r}")
PY
  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-restart.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" graceful-shutdown-pass sh -lc "
    set -eu
    grep -Fqx graceful-shutdown-pass /var/lib/dory/release-graceful-shutdown
    cat /home/dorygate/.dory-release-marker
    mountpoint -q /home/dorygate/Mac
    echo graceful-shutdown-pass
  " \
    > "$WORKROOT/evidence/$distro-persistence.json"

  recovery_snapshot="recovery-$distro"
  assert_exec_token "$machine" recovery-source-ready sh -lc "
    set -eu
    recovery_path=/home/dorygate/.dory-release-recovery.bin
    recovery_sum=/home/dorygate/.dory-release-recovery.sha256
    dd if=/dev/urandom of=\"\$recovery_path\" bs=1M count=16 status=none
    sha256sum \"\$recovery_path\" > \"\$recovery_sum\"
    sync
    echo recovery-source-ready
  " > "$WORKROOT/evidence/$distro-recovery-source.json"
  "$CTL" machine snapshot "$machine" --id "$recovery_snapshot" \
    --note "Exact release-candidate recovery proof" \
    > "$WORKROOT/evidence/$distro-recovery-snapshot.json"
  snapshot_plan_sha="$(python3 - \
    "$WORKROOT/evidence/$distro-recovery-snapshot.json" \
    "$machine" "$recovery_snapshot" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("machineID") != sys.argv[2] \
        or body.get("id") != sys.argv[3]:
    raise SystemExit(f"snapshot returned the wrong authority: {body!r}")
if body.get("consistency") not in {"cold-stopped", "guest-quiesced"}:
    raise SystemExit(f"snapshot omitted an exact consistency contract: {body!r}")
identity = body.get("runtimeIdentity")
if not isinstance(identity, dict) or identity.get("mode") != "resolved-plan" \
        or re.fullmatch(r"[0-9a-f]{64}", identity.get("planSHA256", "")) is None:
    raise SystemExit(f"snapshot omitted resolved runtime authority: {body!r}")
artifacts = body.get("artifactEvidence")
if not isinstance(artifacts, dict):
    raise SystemExit(f"snapshot omitted artifact evidence: {body!r}")
for key in ("rootfs", "kernel"):
    artifact = artifacts.get(key)
    if not isinstance(artifact, dict) \
            or not isinstance(artifact.get("byteCount"), int) \
            or artifact["byteCount"] <= 0 \
            or re.fullmatch(r"[0-9a-f]{64}", artifact.get("sha256", "")) is None:
        raise SystemExit(f"snapshot has invalid {key} evidence: {body!r}")
print(identity["planSHA256"])
PY
  )"
  printf '%s\n' "$snapshot_plan_sha" \
    > "$WORKROOT/evidence/$distro-recovery-snapshot-plan.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" recovery-source-mutated sh -lc "
    set -eu
    recovery_path=/home/dorygate/.dory-release-recovery.bin
    recovery_sum=/home/dorygate/.dory-release-recovery.sha256
    printf 'mutated-after-snapshot\n' > \"\$recovery_path\"
    if sha256sum -c \"\$recovery_sum\" >/dev/null 2>&1; then
      echo 'recovery mutation did not change the payload' >&2
      exit 1
    fi
    sync
    echo recovery-source-mutated
  " > "$WORKROOT/evidence/$distro-recovery-mutated.json"
  "$CTL" machine restore-snapshot "$machine" "$recovery_snapshot" \
    > "$WORKROOT/evidence/$distro-recovery-restore.json"
  restored_plan_sha="$(python3 - \
    "$WORKROOT/evidence/$distro-recovery-restore.json" \
    "$machine" "$snapshot_plan_sha" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("id") != sys.argv[2] \
        or body.get("state") not in {"starting", "running"}:
    raise SystemExit(f"restore did not resume the running machine: {body!r}")
identity = body.get("runtimeIdentity")
if not isinstance(identity, dict) or identity.get("mode") != "resolved-plan" \
        or re.fullmatch(r"[0-9a-f]{64}", identity.get("planSHA256", "")) is None:
    raise SystemExit(f"restore did not publish fresh resolved authority: {body!r}")
if identity["planSHA256"] == sys.argv[3]:
    raise SystemExit(f"restore reused the snapshot's stale launch plan: {body!r}")
print(identity["planSHA256"])
PY
  )"
  printf '%s\n' "$restored_plan_sha" \
    > "$WORKROOT/evidence/$distro-recovery-restored-plan.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" recovery-exact-bytes-restored sh -lc "
    set -eu
    sha256sum -c /home/dorygate/.dory-release-recovery.sha256
    echo recovery-exact-bytes-restored
  " > "$WORKROOT/evidence/$distro-recovery-qualified.json"
  "$CTL" machine delete-snapshot "$machine" "$recovery_snapshot" \
    > "$WORKROOT/evidence/$distro-recovery-delete.json"
  "$CTL" machine snapshots "$machine" \
    > "$WORKROOT/evidence/$distro-recovery-remaining-snapshots.json"
  python3 - "$WORKROOT/evidence/$distro-recovery-remaining-snapshots.json" \
    "$recovery_snapshot" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, list) or any(
        isinstance(row, dict) and row.get("id") == sys.argv[2] for row in body):
    raise SystemExit(f"recovery snapshot survived deletion: {body!r}")
PY

  "$CTL" machine desktop-update "$machine" \
    --distro "$distro" --version "$update_version" \
    --distribution-installation "$distribution_installation" \
    --runtime-installation "$runtime_installation" \
    > "$WORKROOT/evidence/$distro-desktop-update.json"
  python3 - "$WORKROOT/evidence/$distro-desktop-update.json" "$update_version" \
    "$catalog_digest" "$distribution_installation" "$runtime_installation" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("version") != sys.argv[2]:
    raise SystemExit(f"desktop update returned the wrong version: {body!r}")
operation_id = body.get("operationID")
if not isinstance(operation_id, str) or re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
    operation_id,
) is None:
    raise SystemExit(f"desktop update omitted its operation identity: {body!r}")
status = body.get("status")
if not isinstance(status, dict) or status.get("state") != "running":
    raise SystemExit(f"desktop update did not restore running state: {body!r}")
for key in ("inputSHA256", "bundleSHA256"):
    value = body.get(key)
    if not isinstance(value, str) or len(value) != 64:
        raise SystemExit(f"desktop update omitted {key}: {body!r}")
if not isinstance(body.get("snapshotID"), str) or not body["snapshotID"]:
    raise SystemExit(f"desktop update omitted rollback snapshot authority: {body!r}")
receipt = status.get("installedDesktopPayloadReceipt")
if not isinstance(receipt, dict):
    raise SystemExit(f"desktop status omitted installed payload receipt: {body!r}")
expected = {
    "releaseVersion": sys.argv[2],
    "distributionCatalogSHA256": sys.argv[3],
    "runtimeCatalogSHA256": sys.argv[3],
    "distributionInstallationName": sys.argv[4],
    "runtimeInstallationName": sys.argv[5],
    "provenance": "verified-update-bundle",
}
for key, value in expected.items():
    if receipt.get(key) != value:
        raise SystemExit(f"desktop receipt mismatch for {key}: {body!r}")
PY
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" update-pass sh -lc \
    "grep -Fqx 'version=$update_version' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo update-pass" \
    > "$WORKROOT/evidence/$distro-update-qualified.json"

  # Public updates accept only signed component installation identities. A stale identity must be
  # rejected before guest mutation while the already-qualified machine keeps running.
  if "$CTL" machine desktop-update "$machine" \
      --distro "$distro" --version "$update_version" \
      --distribution-installation "$distribution_installation-stale" \
      --runtime-installation "$runtime_installation" \
      > "$WORKROOT/evidence/$distro-stale-update-stdout.json" \
      2> "$WORKROOT/evidence/$distro-stale-update-stderr.txt"; then
    echo "desktop live gate: stale $distro component identity unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q 'desktop update component selection is stale' \
    "$WORKROOT/evidence/$distro-stale-update-stderr.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" stale-update-rejected sh -lc \
    "grep -Fqx 'version=$update_version' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo stale-update-rejected" \
    > "$WORKROOT/evidence/$distro-stale-update-qualified.json"

  "$CTL" machine stop "$machine" >/dev/null
  "$CTL" machine delete "$machine" >/dev/null
  if "$CTL" machine status "$machine" >/dev/null 2>&1; then
    echo "desktop live gate: temporary machine survived deletion: $machine" >&2
    exit 1
  fi
  ACTIVE_MACHINE=""
  printf '%s=PASS\n' "$distro" >> "$WORKROOT/evidence/desktop-results.txt"
}

if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = debian ]; then
  run_desktop debian "$DEBIAN_ROOTFS" lightdm xfce4-session firefox-esr \
    'firefox-esr|/firefox' /usr/share/applications/firefox-esr.desktop "$DEBIAN_UPDATE" \
    xfce4-terminal thunar mousepad ristretto file-roller evince galculator
fi
if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = ubuntu ]; then
  run_desktop ubuntu "$UBUNTU_ROOTFS" gdm3 gnome-shell firefox \
    'firefox' /usr/share/applications/firefox.desktop "$UBUNTU_UPDATE" \
    gnome-terminal nautilus gnome-text-editor eog file-roller evince \
    gnome-calculator gnome-control-center
fi
if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = kali ]; then
  run_desktop kali "$KALI_ROOTFS" lightdm xfce4-session firefox-esr \
    'firefox-esr|/firefox' /usr/share/applications/firefox-esr.desktop "$KALI_UPDATE" \
    xfce4-terminal thunar mousepad ristretto file-roller atril
fi

{
  printf 'source_commit=%s\n' "${GITHUB_SHA:-local}"
  printf 'scope=managed-rootfs-only\n'
  printf 'generic_arm64_efi_iso_software_baseline=SEPARATE-GATE\n'
  printf 'distros=%s\n' "$SELECTED_DISTRO"
  printf 'kernel_sha256=%s\n' "$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
  if [ "$QUALIFY_UBUNTU_ACCELERATION" = 1 ]; then
    printf 'zed_version=%s\n' "$ZED_VERSION"
    printf 'zed_sha256=%s\n' "$ZED_SHA256"
  fi
  printf 'zed_native_venus=%s\n' "$ZED_RESULT"
  printf 'mesa_virgl_desktop=%s\n' "$MESA_VIRGL_DESKTOP_RESULT"
  printf 'renderer_release_signature=%s\n' "$RENDERER_RELEASE_SIGNATURE_RESULT"
  printf 'acceleration_required=%s\n' "$REQUIRE_ACCELERATION"
  python3 - "$BINDING_EVIDENCE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    binding = json.load(handle)
for key in sorted(binding):
    print(f"release_binding_{key}={binding[key]}")
PY
  printf 'exact_release_binding=PASS\n'
  printf 'managed_desktop_baseline=PASS\n'
  printf 'snapshot_restore_exact_bytes=PASS\n'
  printf 'graceful_shutdown=PASS\n'
  printf 'dynamic_retina_display=PASS\n'
  printf 'fullscreen_display=PASS\n'
  printf 'cursor_shape=PASS\n'
  printf 'clipboard_bidirectional=PASS\n'
  printf 'keyboard_pointer_input=PASS\n'
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = debian ]; then
    printf 'debian_rootfs_sha256=%s\n' "$(shasum -a 256 "$DEBIAN_ROOTFS" | awk '{print $1}')"
    printf 'debian_update_sha256=%s\n' "$(shasum -a 256 "$DEBIAN_UPDATE" | awk '{print $1}')"
  fi
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = ubuntu ]; then
    printf 'ubuntu_rootfs_sha256=%s\n' "$(shasum -a 256 "$UBUNTU_ROOTFS" | awk '{print $1}')"
    printf 'ubuntu_update_sha256=%s\n' "$(shasum -a 256 "$UBUNTU_UPDATE" | awk '{print $1}')"
  fi
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = kali ]; then
    printf 'kali_rootfs_sha256=%s\n' "$(shasum -a 256 "$KALI_ROOTFS" | awk '{print $1}')"
    printf 'kali_update_sha256=%s\n' "$(shasum -a 256 "$KALI_UPDATE" | awk '{print $1}')"
  fi
  printf 'status=PASS\n'
} > "$WORKROOT/evidence/manifest.txt"

rm -f "$WORKROOT/share/zed-linux-aarch64.tar.gz"

echo "Desktop Linux managed-rootfs baseline gate: PASS ($WORKROOT/evidence/manifest.txt)"
