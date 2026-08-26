#!/bin/bash
# Assemble Dory's dual VirGL2 + Venus worker and its exact XPC-local ANGLE Metal pair.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFINITION="$ROOT/Config/DoryRendererProductionTuple.json"
TUPLE_VERIFIER="$ROOT/scripts/renderer-production-tuple.py"
PACKAGER="$ROOT/scripts/package-renderer-production-bundle.py"
PACKAGE_ROOT="$ROOT/Packages/ContainerizationEngine"
ENTITLEMENTS="$PACKAGE_ROOT/DoryRendererWorker.entitlements"
WORKER_IDENTIFIER="com.pythonxi.Dory.HVRunner.RendererWorker"
WORKER_EXECUTABLE="DoryRendererWorker"
LINK_ROOT=""
LINK_INVENTORY=""
RUNNER_APP=""
SCRATCH_PATH=""
SIGN_IDENTITY=""
EXPECTED_TEAM=""
ALLOW_ADHOC_TEST=0

usage() {
  echo "usage: $0 --runner-app PATH --link-root PATH --link-inventory PATH --scratch-path PATH --sign-identity IDENTITY --expected-team TEAM [--allow-adhoc-test]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner-app) RUNNER_APP="${2:?missing runner app}"; shift 2 ;;
    --link-root) LINK_ROOT="${2:?missing link root}"; shift 2 ;;
    --link-inventory) LINK_INVENTORY="${2:?missing link inventory}"; shift 2 ;;
    --scratch-path) SCRATCH_PATH="${2:?missing scratch path}"; shift 2 ;;
    --sign-identity) SIGN_IDENTITY="${2:?missing signing identity}"; shift 2 ;;
    --expected-team) EXPECTED_TEAM="${2:?missing expected team}"; shift 2 ;;
    --allow-adhoc-test) ALLOW_ADHOC_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "assemble-renderer-production-worker: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$RUNNER_APP" ] && [ -n "$LINK_ROOT" ] && [ -n "$LINK_INVENTORY" ] \
  && [ -n "$SCRATCH_PATH" ] && [ -n "$SIGN_IDENTITY" ] && [ -n "$EXPECTED_TEAM" ] \
  || { usage; exit 2; }
[ -d "$LINK_ROOT" ] && [ ! -L "$LINK_ROOT" ] || {
  echo "assemble-renderer-production-worker: static link root is unavailable" >&2
  exit 1
}
[ -f "$LINK_INVENTORY" ] && [ ! -L "$LINK_INVENTORY" ] || {
  echo "assemble-renderer-production-worker: static link inventory is unavailable" >&2
  exit 1
}
[ "${CONFIGURATION:-}" = Release ] || {
  echo "assemble-renderer-production-worker: production assembly requires CONFIGURATION=Release" >&2
  exit 1
}
# Xcode provides ARCHS as a space-delimited build-setting list; intentional field splitting lets
# this gate reject every value except the single exact `arm64` element.
# shellcheck disable=SC2086
set -- ${ARCHS:-}
[ "$#" -eq 1 ] && [ "$1" = arm64 ] || {
  echo "assemble-renderer-production-worker: production assembly requires exactly ARCHS=arm64" >&2
  exit 1
}
[ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] || {
  echo "assemble-renderer-production-worker: Xcode code signing is required" >&2
  exit 1
}
[ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ] || {
  echo "assemble-renderer-production-worker: the hardened runtime is required" >&2
  exit 1
}
[ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ] || {
  echo "assemble-renderer-production-worker: DEVELOPER_DIR must select the reviewed full Xcode" >&2
  exit 1
}
[ -n "${TARGET_TEMP_DIR:-}" ] && [ -d "$TARGET_TEMP_DIR" ] && [ ! -L "$TARGET_TEMP_DIR" ] || {
  echo "assemble-renderer-production-worker: Xcode TARGET_TEMP_DIR is unavailable" >&2
  exit 1
}
case "$SIGN_IDENTITY:$EXPECTED_TEAM:$ALLOW_ADHOC_TEST" in
  -:-:1) ;;
  -:*|*:-:0|*:-:1)
    echo "assemble-renderer-production-worker: signing identity and team authority disagree" >&2
    exit 1 ;;
  *:*:1)
    echo "assemble-renderer-production-worker: test-only ad-hoc authority cannot weaken a team identity" >&2
    exit 1 ;;
  *:*:0) ;;
esac
case "$SIGN_IDENTITY" in
  *$'\n'*|*$'\r'*)
    echo "assemble-renderer-production-worker: signing identity is not canonical" >&2
    exit 1 ;;
esac

python3 - "$TARGET_TEMP_DIR" "$SCRATCH_PATH" "$RUNNER_APP" "$LINK_ROOT" <<'PY'
import pathlib
import sys

temporary = pathlib.Path(sys.argv[1]).resolve(strict=True)
scratch = pathlib.Path(sys.argv[2])
runner = pathlib.Path(sys.argv[3]).resolve(strict=True)
link = pathlib.Path(sys.argv[4]).resolve(strict=True)
if scratch.is_symlink():
    raise SystemExit("assemble-renderer-production-worker: scratch path must not be a symlink")
scratch_parent = scratch.parent.resolve(strict=True)
if scratch_parent != temporary and temporary not in scratch_parent.parents:
    raise SystemExit("assemble-renderer-production-worker: scratch path must be inside TARGET_TEMP_DIR")
if runner == link or runner in link.parents or link in runner.parents:
    raise SystemExit("assemble-renderer-production-worker: runner and static link roots overlap")
PY

WORKER_BUNDLE="$RUNNER_APP/Contents/XPCServices/DoryRendererWorker.xpc"
WORKER_DESTINATION="$WORKER_BUNDLE/Contents/MacOS/$WORKER_EXECUTABLE"
WORKER_FRAMEWORKS="$WORKER_BUNDLE/Contents/Frameworks"
python3 - "$WORKER_BUNDLE" "$ENTITLEMENTS" <<'PY'
import pathlib
import plistlib
import sys

bundle = pathlib.Path(sys.argv[1])
info_path = bundle / "Contents/Info.plist"
entitlements_path = pathlib.Path(sys.argv[2])
for path, label in ((bundle, "worker bundle"), (bundle / "Contents", "worker Contents"),
                    (bundle / "Contents/MacOS", "worker MacOS")):
    if not path.is_dir() or path.is_symlink():
        raise SystemExit(f"assemble-renderer-production-worker: {label} is unavailable")
try:
    info = plistlib.loads(info_path.read_bytes())
    entitlements = plistlib.loads(entitlements_path.read_bytes())
except (OSError, plistlib.InvalidFileException) as error:
    raise SystemExit(f"assemble-renderer-production-worker: invalid bundle authority: {error}")
expected = {
    "CFBundleExecutable": "DoryRendererWorker",
    "CFBundleIdentifier": "com.pythonxi.Dory.HVRunner.RendererWorker",
    "CFBundlePackageType": "XPC!",
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"assemble-renderer-production-worker: worker {key} differs")
if entitlements != {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.application-groups": ["864H636QW4.dory-renderer"],
}:
    raise SystemExit("assemble-renderer-production-worker: worker entitlements differ")
PY

python3 "$TUPLE_VERIFIER" --definition "$DEFINITION" verify-definition --repo-root "$ROOT"
python3 "$TUPLE_VERIFIER" --definition "$DEFINITION" verify-toolchain
python3 "$PACKAGER" verify-link-stage \
  --link-root "$LINK_ROOT" \
  --link-inventory "$LINK_INVENTORY"

mkdir -p "$SCRATCH_PATH"
[ -d "$SCRATCH_PATH" ] && [ ! -L "$SCRATCH_PATH" ] || {
  echo "assemble-renderer-production-worker: scratch path is not a direct directory" >&2
  exit 1
}
CANONICALIZATION_RECEIPT="$SCRATCH_PATH/renderer-worker-link-canonicalization.json"
RECEIPT="$SCRATCH_PATH/renderer-worker-assembly.json"
for PHASE_RECEIPT in "$CANONICALIZATION_RECEIPT" "$RECEIPT"; do
  if [ -L "$PHASE_RECEIPT" ] || { [ -e "$PHASE_RECEIPT" ] && [ ! -f "$PHASE_RECEIPT" ]; }; then
    echo "assemble-renderer-production-worker: phase receipt is not a direct file" >&2
    exit 1
  fi
  rm -f "$PHASE_RECEIPT"
done

# Clean only SwiftPM's caller-owned scratch graph. No source checkout, archive stage, or application
# bundle is a clean target.
xcrun --sdk macosx swift package \
  --package-path "$PACKAGE_ROOT" \
  --scratch-path "$SCRATCH_PATH" \
  clean

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
COMMON_BUILD_ARGUMENTS=(
  --package-path "$PACKAGE_ROOT"
  --scratch-path "$SCRATCH_PATH"
  --configuration release
  --product dory-renderer-worker
  --triple arm64-apple-macosx15.0
  --sdk "$SDK_PATH"
  --disable-index-store
  --disable-local-rpath
  --disable-dead-strip
  --explicit-target-dependency-import-check error
  --jobs 3
)
STATIC_BUILD_ARGUMENTS=(
  -Xcc -DDORY_VIRGL_RENDERER_STATIC_LINKED
  -Xcc -DDORY_VIRGL_RENDERER_DUAL_METAL
  -Xcc -I"$LINK_ROOT/include"
  -Xcc -I"$LINK_ROOT/include/ANGLE"
  # The worker's Swift runtime dylibs have absolute system install names. Keep the executable's
  # loader authority closed instead of retaining Swift's otherwise-unused /usr/lib/swift search path.
  -Xswiftc -no-stdlib-rpath
  -Xlinker -force_load
  -Xlinker "$LINK_ROOT/lib/libvirglrenderer.a"
  -Xlinker -force_load
  -Xlinker "$LINK_ROOT/lib/libepoxy.a"
  -Xlinker -force_load
  -Xlinker "$LINK_ROOT/lib/libMoltenVK.a"
)
for framework in AppKit CoreGraphics Foundation IOKit IOSurface Metal QuartzCore; do
  STATIC_BUILD_ARGUMENTS+=(
    -Xlinker -framework
    -Xlinker "$framework"
  )
done
STATIC_BUILD_ARGUMENTS+=(
  -Xlinker -lc++
)
BUILD_COMMAND=(
  xcrun --sdk macosx swift build
  "${COMMON_BUILD_ARGUMENTS[@]}"
  "${STATIC_BUILD_ARGUMENTS[@]}"
)
"${BUILD_COMMAND[@]}"
BIN_PATH="$(xcrun --sdk macosx swift build \
  "${COMMON_BUILD_ARGUMENTS[@]}" \
  "${STATIC_BUILD_ARGUMENTS[@]}" \
  --show-bin-path)"
BUILT_EXECUTABLE="$BIN_PATH/dory-renderer-worker"
[ -f "$BUILT_EXECUTABLE" ] && [ ! -L "$BUILT_EXECUTABLE" ] && [ -x "$BUILT_EXECUTABLE" ] || {
  echo "assemble-renderer-production-worker: SwiftPM did not emit the exact executable product" >&2
  exit 1
}
python3 "$PACKAGER" canonicalize-worker-linkage \
  --worker-executable "$BUILT_EXECUTABLE" \
  --developer-dir "$DEVELOPER_DIR" \
  --receipt "$CANONICALIZATION_RECEIPT"
python3 "$PACKAGER" verify-worker-linkage --worker-executable "$BUILT_EXECUTABLE"

STAGED_EXECUTABLE="$WORKER_BUNDLE/Contents/MacOS/.DoryRendererWorker.assemble-$$"
trap 'rm -f "$STAGED_EXECUTABLE"' EXIT
install -m0755 "$BUILT_EXECUTABLE" "$STAGED_EXECUTABLE"
python3 "$PACKAGER" verify-worker-linkage --worker-executable "$STAGED_EXECUTABLE"
mv -f "$STAGED_EXECUTABLE" "$WORKER_DESTINATION"
mkdir -p "$WORKER_FRAMEWORKS"
[ -d "$WORKER_FRAMEWORKS" ] && [ ! -L "$WORKER_FRAMEWORKS" ] || {
  echo "assemble-renderer-production-worker: worker Frameworks is not a direct directory" >&2
  exit 1
}
python3 - "$WORKER_FRAMEWORKS" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {"libEGL.dylib", "libGLESv2.dylib"}
actual = {path.name for path in root.iterdir()}
if actual - expected:
    raise SystemExit(
        "assemble-renderer-production-worker: worker Frameworks contains unowned artifacts"
    )
for name in actual:
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(
            "assemble-renderer-production-worker: existing ANGLE artifact is not a direct file"
        )
PY
for angle_name in libEGL.dylib libGLESv2.dylib; do
  install -m0755 "$LINK_ROOT/Frameworks/$angle_name" "$WORKER_FRAMEWORKS/$angle_name"
done
BUILT_SHA256="$(shasum -a 256 "$BUILT_EXECUTABLE" | awk '{print $1}')"
UNSIGNED_INSTALLED_SHA256="$(shasum -a 256 "$WORKER_DESTINATION" | awk '{print $1}')"
[ "$BUILT_SHA256" = "$UNSIGNED_INSTALLED_SHA256" ] || {
  echo "assemble-renderer-production-worker: installed unsigned worker differs from the SwiftPM product" >&2
  exit 1
}

CODESIGN_ARGUMENTS=(
  /usr/bin/codesign
  --force
  --sign "$SIGN_IDENTITY"
  --identifier "$WORKER_IDENTIFIER"
  --options runtime
  --entitlements "$ENTITLEMENTS"
)
for angle_name in libEGL.dylib libGLESv2.dylib; do
  /usr/bin/codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$WORKER_IDENTIFIER.$angle_name" \
    --options runtime \
    "$WORKER_FRAMEWORKS/$angle_name"
done
"${CODESIGN_ARGUMENTS[@]}" "$WORKER_BUNDLE"
python3 "$PACKAGER" verify-worker-linkage --worker-executable "$WORKER_DESTINATION"

INSTALLED_SHA256="$(shasum -a 256 "$WORKER_DESTINATION" | awk '{print $1}')"
LINK_INVENTORY_SHA256="$(shasum -a 256 "$LINK_INVENTORY" | awk '{print $1}')"
CDHASH="$(/usr/bin/codesign -d --verbose=4 "$WORKER_BUNDLE" 2>&1 \
  | awk -F= '$1 == "CDHash" { print tolower($2) }')"
if [[ ! "$CDHASH" =~ ^[0-9a-f]{40}$ ]] \
    || [ "$CDHASH" = 0000000000000000000000000000000000000000 ]; then
  echo "assemble-renderer-production-worker: signed worker CDHash must be nonzero 40-hex" >&2
  exit 1
fi

CANONICALIZATION_RECEIPT_SHA256="$(shasum -a 256 "$CANONICALIZATION_RECEIPT" | awk '{print $1}')"
python3 - "$RECEIPT" "$LINK_INVENTORY_SHA256" "$BUILT_SHA256" \
  "$UNSIGNED_INSTALLED_SHA256" "$INSTALLED_SHA256" "$CDHASH" \
  "$CANONICALIZATION_RECEIPT_SHA256" "${BUILD_COMMAND[@]}" <<'PY'
import json
import pathlib
import sys

receipt = {
    "buildCommand": sys.argv[8:],
    "builtExecutableSHA256": sys.argv[3],
    "installedExecutableCDHash": sys.argv[6],
    "installedExecutableSHA256": sys.argv[5],
    "kind": "dev.dory.renderer-worker-assembly-provenance",
    "linkCanonicalizationReceiptSHA256": sys.argv[7],
    "linkInventorySHA256": sys.argv[2],
    "runtimeAuthority": ["installedExecutableSHA256", "installedExecutableCDHash"],
    "schemaVersion": 1,
    "unsignedInstalledExecutableSHA256": sys.argv[4],
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(receipt, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
RECEIPT_SHA256="$(shasum -a 256 "$RECEIPT" | awk '{print $1}')"
echo "renderer.assembly.receipt=$RECEIPT"
echo "renderer.assembly.receipt.sha256=$RECEIPT_SHA256"
echo "renderer.worker.sha256=$INSTALLED_SHA256"
echo "renderer.worker.cdhash=$CDHASH"
