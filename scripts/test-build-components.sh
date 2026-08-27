#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-components-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if (
  export DORY_RELEASE_SOURCE_ONLY=1
  source "$ROOT/scripts/release.sh" 9.8.7 42
  preflight_component_supply_chain
) >"$TMP/component-preflight.out" 2>&1; then
  echo "component packaging test: incomplete public producer wiring was not blocked" >&2
  exit 1
fi
grep -Fq 'public component publication is blocked' "$TMP/component-preflight.out" \
  || { echo "component packaging test: public preflight failed for the wrong reason" >&2; exit 1; }
grep -Fq 'physical campaign receipts and schema-2 VM qualification are not yet bound' \
  "$TMP/component-preflight.out" \
  || { echo "component packaging test: public preflight does not identify the producer gap" >&2; exit 1; }

SOURCE="$TMP/source"
CORE_APP="$TMP/Dory.app"
CANDIDATE="$TMP/components/candidate-arm64"
OUTPUT="$TMP/components/arm64"
SBOM="$TMP/Dory-test.cdx.json"
QUALIFICATION="$TMP/virtual-machine-qualification.json"
QUALIFICATION_SIGNATURE="$TMP/virtual-machine-qualification.json.sig"
PERFORMANCE_RECEIPT="$TMP/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.linux-vm-performance-verification.json"
PERFORMANCE_RECEIPT_SIGNATURE="$PERFORMANCE_RECEIPT.sig"
PRIVATE_KEY="$TMP/qualification-private-key.raw"
SIGN_HELPER="$TMP/sign.swift"
CATALOG_SIGNER="$TMP/sign_update"
RUNNER_APP="$CORE_APP/Contents/Helpers/DoryHVRunner.app"
RUNNER_EXECUTABLE="$RUNNER_APP/Contents/MacOS/dory-hv"
RUNNER_ENTITLEMENTS="$TMP/DoryHVRunner.entitlements"
WORKER_XPC="$RUNNER_APP/Contents/XPCServices/DoryFSWorker.xpc"
WORKER_EXECUTABLE="$WORKER_XPC/Contents/MacOS/DoryFSWorker"
WORKER_ENTITLEMENTS="$TMP/DoryFSWorker.entitlements"
WORKER_EXCESS_ENTITLEMENTS="$TMP/DoryFSWorker-excess.entitlements"
RENDERER_XPC="$RUNNER_APP/Contents/XPCServices/DoryRendererWorker.xpc"
RENDERER_EXECUTABLE="$RENDERER_XPC/Contents/MacOS/DoryRendererWorker"
RENDERER_ENTITLEMENTS="$TMP/DoryRendererWorker.entitlements"
RENDERER_EXCESS_ENTITLEMENTS="$TMP/DoryRendererWorker-excess.entitlements"
mkdir -p \
  "$SOURCE" \
  "$CORE_APP/Contents/MacOS" \
  "$RUNNER_APP/Contents/MacOS" \
  "$WORKER_XPC/Contents/MacOS" \
  "$RENDERER_XPC/Contents/MacOS"

write_fixture() {
  local path="$1" bytes="$2"
  dd if=/dev/zero of="$path" bs=1 count=0 seek="$bytes" 2>/dev/null
  printf 'dory-fixture-%s\n' "$(basename "$path")" | dd of="$path" conv=notrunc 2>/dev/null
}

write_fixture "$TMP/Dory-test.dmg" 4096
write_fixture "$CORE_APP/Contents/MacOS/Dory" 8192
write_fixture "$CORE_APP/Contents/Helpers/dory-vmm" 4096
cp /usr/bin/true "$RUNNER_EXECUTABLE"
cp /usr/bin/true "$WORKER_EXECUTABLE"
cp /usr/bin/true "$RENDERER_EXECUTABLE"
cat > "$RUNNER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>dory-hv</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.HVRunner</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$RUNNER_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.hypervisor</key><true/>
</dict></plist>
PLIST
cat > "$WORKER_XPC/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DoryFSWorker</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.HVRunner.FSWorker</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
cat > "$WORKER_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
</dict></plist>
PLIST
cat > "$WORKER_EXCESS_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
cat > "$RENDERER_XPC/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DoryRendererWorker</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.HVRunner.RendererWorker</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
cat > "$RENDERER_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array>
<string>864H636QW4.dory-renderer</string>
</array>
</dict></plist>
PLIST
cat > "$RENDERER_EXCESS_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array>
<string>864H636QW4.dory-renderer</string>
</array>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
chmod 0755 \
  "$RUNNER_EXECUTABLE" \
  "$WORKER_EXECUTABLE" \
  "$RENDERER_EXECUTABLE" \
  "$CORE_APP/Contents/Helpers/dory-vmm"
codesign --force --sign - --entitlements "$WORKER_ENTITLEMENTS" "$WORKER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null
codesign --verify --deep --strict "$RUNNER_APP"
write_fixture "$TMP/kubectl" 16384
chmod 0755 "$TMP/kubectl"
printf '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}\n' > "$SBOM"
write_fixture "$SOURCE/Image" 131072
write_fixture "$SOURCE/initfs-arm64.ext4" 262144
write_fixture "$SOURCE/Image-desktop" 196608

for distro in debian ubuntu kali; do
  write_fixture "$SOURCE/dory-desktop-$distro-rootfs-arm64.ext4" 327680
  printf 'schema=fixture\n' > "$SOURCE/dory-desktop-$distro-build-arm64.stamp"
  if [ "$distro" = ubuntu ]; then
    printf 'ubuntu-desktop-minimal\tfixture\nubuntu-session\tfixture\ngdm3\tfixture\n' \
      > "$SOURCE/dory-desktop-$distro-packages-arm64.txt"
  else
    printf 'xfce4\tfixture\nlightdm\tfixture\n' \
      > "$SOURCE/dory-desktop-$distro-packages-arm64.txt"
  fi
  write_fixture "$SOURCE/dory-desktop-$distro-update-arm64.tar" 4096
done
printf 'schema=fixture\n' > "$SOURCE/kernel-build-arm64-desktop.stamp"

cat > "$SIGN_HELPER" <<'SWIFT'
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("test signer error: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "generate" where arguments.count == 2:
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: URL(fileURLWithPath: arguments[1]))
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case "sign" where arguments.count == 3:
        let raw = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let message = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        print(try key.signature(for: message).base64EncodedString())
    case "verify" where arguments.count == 4:
        let raw = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let message = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        guard let signature = Data(base64Encoded: arguments[3]),
              key.publicKey.isValidSignature(signature, for: message) else {
            fail("signature verification failed")
        }
    default:
        fail("usage: sign.swift generate PRIVATE | sign PRIVATE MESSAGE | verify PRIVATE MESSAGE SIGNATURE")
    }
} catch {
    fail("cryptographic operation failed")
}
SWIFT

PUBLIC_KEY="$(xcrun swift "$SIGN_HELPER" generate "$PRIVATE_KEY")"
chmod 0600 "$PRIVATE_KEY"
export DORY_TEST_SIGN_HELPER="$SIGN_HELPER"
export DORY_TEST_PRIVATE_KEY="$PRIVATE_KEY"
cat > "$CATALOG_SIGNER" <<'SH'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  -p)
    [ "$#" -eq 2 ]
    exec xcrun swift "$DORY_TEST_SIGN_HELPER" sign "$DORY_TEST_PRIVATE_KEY" "$2"
    ;;
  --verify)
    [ "$#" -eq 3 ]
    exec xcrun swift "$DORY_TEST_SIGN_HELPER" verify "$DORY_TEST_PRIVATE_KEY" "$2" "$3"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod 0755 "$CATALOG_SIGNER"

assemble() {
  "$ROOT/scripts/build-components.py" assemble \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$CANDIDATE" \
    --asset-base-url https://example.invalid/dory \
    --generated-at 2026-07-16T00:00:00Z \
    --source-commit 0123456789abcdef0123456789abcdef01234567 \
    --skip-source-verification
}

# A runner without the isolated filesystem worker is not a releasable runtime graph.
mv "$WORKER_XPC" "$TMP/DoryFSWorker.xpc.hold"
if assemble >"$TMP/missing-worker.out" 2>&1; then
  echo "component packaging accepted a runner without its filesystem worker" >&2
  exit 1
fi
grep -Fq 'nested filesystem worker XPC service is missing' "$TMP/missing-worker.out" \
  || { cat "$TMP/missing-worker.out" >&2; echo "component packaging rejected a missing worker for the wrong reason" >&2; exit 1; }
mv "$TMP/DoryFSWorker.xpc.hold" "$WORKER_XPC"
codesign --force --sign - --entitlements "$WORKER_ENTITLEMENTS" "$WORKER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null

# A runner without the renderer process boundary must also remain unpublishable.
mv "$RENDERER_XPC" "$TMP/DoryRendererWorker.xpc.hold"
if assemble >"$TMP/missing-renderer-worker.out" 2>&1; then
  echo "component packaging accepted a runner without its renderer worker" >&2
  exit 1
fi
grep -Fq 'nested renderer worker XPC service is missing' "$TMP/missing-renderer-worker.out" \
  || { cat "$TMP/missing-renderer-worker.out" >&2; echo "component packaging rejected a missing renderer worker for the wrong reason" >&2; exit 1; }
mv "$TMP/DoryRendererWorker.xpc.hold" "$RENDERER_XPC"
codesign --force --sign - --entitlements "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null

# Ambient capabilities on the worker must not slip through an otherwise valid inside-out graph.
codesign --force --sign - \
  --entitlements "$WORKER_EXCESS_ENTITLEMENTS" \
  "$WORKER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null
if assemble >"$TMP/excess-worker-entitlements.out" 2>&1; then
  echo "component packaging accepted excess filesystem worker entitlements" >&2
  exit 1
fi
grep -Fq 'filesystem worker entitlements do not match its descriptor capability boundary' \
  "$TMP/excess-worker-entitlements.out" \
  || { echo "component packaging rejected excess worker entitlements for the wrong reason" >&2; exit 1; }
codesign --force --sign - --entitlements "$WORKER_ENTITLEMENTS" "$WORKER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null

# The renderer is descriptor-only and receives no ambient file or network capability.
codesign --force --sign - \
  --entitlements "$RENDERER_EXCESS_ENTITLEMENTS" \
  "$RENDERER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null
if assemble >"$TMP/excess-renderer-entitlements.out" 2>&1; then
  echo "component packaging accepted excess renderer worker entitlements" >&2
  exit 1
fi
grep -Fq 'renderer worker entitlements do not match its minimal sandbox' \
  "$TMP/excess-renderer-entitlements.out" \
  || { echo "component packaging rejected excess renderer entitlements for the wrong reason" >&2; exit 1; }
codesign --force --sign - --entitlements "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" >/dev/null
codesign --force --sign - --entitlements "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" >/dev/null

# Assembly has no SBOM, qualification, signature, or catalog inputs and must still succeed.
assemble
python3 - "$CANDIDATE" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
inventory_path = root / "component-candidate-inventory.json"
digest_path = root / "component-candidate-inventory.json.sha256"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
assert inventory["kind"] == "dev.dory.component-candidate-inventory"
assert inventory["schemaVersion"] == 2
assert inventory["releaseVersion"] == "9.8.7"
assert inventory["architecture"] == "arm64"
assert inventory["sourceCommit"] == "0123456789abcdef0123456789abcdef01234567"
assert inventory["recipeDigest"]
assert inventory["core"]["artifact"]["sha256"]
assert [item["componentIdentifier"] for item in inventory["core"]["helpers"]] == [
    "dory-hv", "dory-vmm",
]
runner = inventory["core"]["helpers"][0]
assert runner["path"] == "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv"
assert runner["signedBundle"]["path"] == "Contents/Helpers/DoryHVRunner.app"
assert runner["signedBundle"]["bundleIdentifier"] == "com.pythonxi.Dory.HVRunner"
assert runner["signedBundle"]["bundleExecutable"] == "dory-hv"
assert any(
    item["path"] == "Contents/MacOS/dory-hv"
    and item["sha256"] == runner["sha256"]
    for item in runner["signedBundle"]["files"]
)
worker_files = {
    item["path"]: item
    for item in runner["signedBundle"]["files"]
}
assert "Contents/XPCServices/DoryFSWorker.xpc/Contents/Info.plist" in worker_files
worker_executable = worker_files[
    "Contents/XPCServices/DoryFSWorker.xpc/Contents/MacOS/DoryFSWorker"
]
assert worker_executable["mode"] & 0o111
assert "Contents/XPCServices/DoryRendererWorker.xpc/Contents/Info.plist" in worker_files
renderer_executable = worker_files[
    "Contents/XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker"
]
assert renderer_executable["mode"] & 0o111
assert inventory["mediaBindings"]
assert [item["name"] for item in inventory["files"]] == sorted(
    item["name"] for item in inventory["files"]
)
assert digest_path.read_text(encoding="ascii") == hashlib.sha256(
    inventory_path.read_bytes()
).hexdigest() + "\n"

component_files = {
    asset["url"].rsplit("/", 1)[-1]: asset
    for component in inventory["components"]
    for asset in component["assets"]
}
assert set(component_files) == {item["name"] for item in inventory["files"]}
for record in inventory["files"]:
    path = root / record["name"]
    asset = component_files[record["name"]]
    assert path.stat().st_size == record["bytes"] == asset["downloadBytes"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"] == asset["sha256"]
    assert len(asset["installedSHA256"]) == 64

serialized = inventory_path.read_text(encoding="utf-8")
assert "qualification" not in serialized.lower()
assert "sbom" not in serialized.lower()
assert not (root / "catalog.json").exists()
assert not any(item["role"] == "qualification-evidence" for item in component_files.values())
linux = next(item for item in inventory["components"] if item["id"] == "linux-desktop")
assert linux["provides"] == ["guest.linux-desktop-runtime.arm64@1"]
assert not any("virgl" in claim or "venus" in claim for claim in linux["provides"])
assert set(path.name for path in root.iterdir()) == set(component_files) | {
    "component-candidate-inventory.json",
    "component-candidate-inventory.json.sha256",
}
PY

"$ROOT/scripts/build-components.py" verify-candidate \
  --candidate "$CANDIDATE" > "$TMP/candidate-verification.json"
python3 - "$CANDIDATE" "$TMP/candidate-verification.json" <<'PY'
import hashlib
import json
import pathlib
import sys

candidate, receipt_path = map(pathlib.Path, sys.argv[1:])
inventory_path = candidate / "component-candidate-inventory.json"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
assert receipt == {
    "architecture": "arm64",
    "componentCandidateInventorySHA256": hashlib.sha256(
        inventory_path.read_bytes()
    ).hexdigest(),
    "components": [component["id"] for component in inventory["components"]],
    "fileCount": len(inventory["files"]),
    "kind": "dev.dory.component-candidate-verification",
    "releaseVersion": "9.8.7",
    "schemaVersion": 1,
    "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
}
PY

snapshot_candidate() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
inventory = json.loads((root / "component-candidate-inventory.json").read_text())
names = [item["name"] for item in inventory["files"]] + [
    "component-candidate-inventory.json",
    "component-candidate-inventory.json.sha256",
]
snapshot = {}
for name in names:
    path = root / name
    info = path.stat()
    snapshot[name] = {
        "bytes": info.st_size,
        "mode": info.st_mode,
        "inode": info.st_ino,
        "mtimeNS": info.st_mtime_ns,
        "ctimeNS": info.st_ctime_ns,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
pathlib.Path(sys.argv[2]).write_text(json.dumps(snapshot, sort_keys=True) + "\n")
PY
}

snapshot_candidate "$CANDIDATE" "$TMP/candidate-before.json"

# Finalization cannot run before the evidence producer has emitted its exact inputs.
if "$ROOT/scripts/build-components.py" finalize \
    --candidate "$CANDIDATE" \
    --output "$TMP/missing-evidence-final" \
    --sbom "$SBOM" \
    --qualification-manifest "$TMP/missing-qualification.json" \
    --qualification-signature "$TMP/missing-qualification.json.sig" \
    --performance-verification-receipt "$TMP/missing-performance-receipt.json" \
    --performance-verification-signature "$TMP/missing-performance-receipt.json.sig" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PUBLIC_KEY" \
    >"$TMP/missing-evidence.out" 2>&1; then
  echo "component packaging accepted finalization before qualification evidence" >&2
  exit 1
fi
grep -Fq 'VM qualification manifest is missing' "$TMP/missing-evidence.out" \
  || { echo "component packaging rejected missing evidence for the wrong reason" >&2; exit 1; }
[ ! -e "$TMP/missing-evidence-final/catalog.json" ] \
  || { echo "component packaging partially finalized without evidence" >&2; exit 1; }

write_qualification() {
  local destination="$1" mutation="$2"
  python3 - \
    "$destination" "$CANDIDATE" "$SBOM" "$PUBLIC_KEY" "$mutation" \
    "$PERFORMANCE_RECEIPT" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

destination, output, sbom, public_key, mutation, receipt_path = sys.argv[1:]
output = pathlib.Path(output)
receipt_path = pathlib.Path(receipt_path)
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
inventory = json.loads((output / "component-candidate-inventory.json").read_text())
inventory_digest = hashlib.sha256(
    (output / "component-candidate-inventory.json").read_bytes()
).hexdigest()
sbom_digest = hashlib.sha256(pathlib.Path(sbom).read_bytes()).hexdigest()
helper = next(
    item for item in inventory["core"]["helpers"]
    if item["componentIdentifier"] == "dory-hv"
)
media = next(
    item for item in inventory["mediaBindings"]
    if item["componentIdentifier"] == "linux-desktop"
    and item["bootMediaKind"] == "linux-kernel"
)
manifest = {
    "kind": "dev.dory.virtual-machine-qualification-manifest",
    "schemaVersion": 2,
    "manifestIdentity": "dory-release-9.8.7-apple-silicon",
    "catalogReleaseVersion": "9.8.7",
    "architecture": "arm64",
    "signingKeyID": hashlib.sha256(base64.b64decode(public_key, validate=True)).hexdigest(),
    "candidateBinding": {
        "componentCandidateInventorySHA256": inventory_digest,
        "sbomSHA256": sbom_digest,
    },
    "records": [{
        "qualificationIdentity": "linux-desktop-arm64-mac16-1-25a1",
        "guest": {"family": "linux", "architecture": "arm64"},
        "bootMediaKind": "linux-kernel",
        "bootMediaSource": "dory-bundled",
        "immutableArtifactSHA256": media["immutableArtifactSHA256"],
        "backend": "dory-hypervisor",
        "backendImplementationIdentifier": "dory.raw-hv-linux.compatibility.v1",
        "backendRuntimeBuildIdentifier": f"sha256:{helper['sha256']}",
        "virtualHardwareABIVersion": 1,
        "graphics": "hardware-accelerated-3d",
        "devices": {
            "networkAttachment": "shared-nat",
            "audioInput": True,
            "audioOutput": True,
            "keyboard": True,
            "pointer": True,
            "directorySharing": True,
            "clipboard": True,
            "clockSynchronization": True,
            "dynamicDisplay": True,
            "gracefulShutdown": True,
        },
        "hostHardwareModelIdentifier": "Mac16,1",
        "hostOperatingSystemBuild": "25A1",
        "components": [{
            "componentIdentifier": "dory-hv",
            "buildIdentifier": f"sha256:{helper['sha256']}",
            "artifactSHA256": helper["sha256"],
        }],
        "virtioGPUKernelAndDeviceSupportQualified": True,
        "producerFenceBeforeFlushQualified": True,
        "venusVulkanGuestRuntimeQualified": True,
        "performanceQualification": {
            "bundleInventorySHA256": receipt["bundleInventorySHA256"],
            "graphicsImplementation": receipt["supportCell"]["graphicsImplementation"],
            "matrixCellID": receipt["supportCell"]["matrixCellID"],
            "signaturePublicKeyID": receipt["signaturePublicKeyID"],
            "verificationReceiptPath": receipt_path.name,
            "verificationReceiptSHA256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
        },
    }],
}
if mutation == "wrong-inventory":
    manifest["candidateBinding"]["componentCandidateInventorySHA256"] = "a" * 64
elif mutation == "wrong-helper":
    manifest["records"][0]["backendRuntimeBuildIdentifier"] = "sha256:" + "c" * 64
    manifest["records"][0]["components"][0]["buildIdentifier"] = "sha256:" + "c" * 64
    manifest["records"][0]["components"][0]["artifactSHA256"] = "c" * 64
elif mutation == "wrong-media":
    manifest["records"][0]["immutableArtifactSHA256"] = "d" * 64
elif mutation == "wrong-release":
    manifest["catalogReleaseVersion"] = "9.8.6"
elif mutation != "none":
    raise SystemExit(f"unknown qualification mutation: {mutation}")
pathlib.Path(destination).write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

sign_file() {
  xcrun swift "$SIGN_HELPER" sign "$PRIVATE_KEY" "$1" > "$2"
}

write_performance_receipt() {
  python3 - "$PERFORMANCE_RECEIPT" "$CANDIDATE" "$SBOM" "$PUBLIC_KEY" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

destination, candidate_root, sbom_path, public_key = sys.argv[1:]
candidate_root = pathlib.Path(candidate_root)
inventory_path = candidate_root / "component-candidate-inventory.json"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
media = next(
    item for item in inventory["mediaBindings"]
    if item["componentIdentifier"] == "linux-desktop"
    and item["bootMediaKind"] == "linux-kernel"
)
receipt = {
    "bundleInventorySHA256": "f" * 64,
    "candidate": {
        "applicationSHA256": "1" * 64,
        "budgetSetSHA256": "2" * 64,
        "componentCandidateInventorySHA256": hashlib.sha256(inventory_path.read_bytes()).hexdigest(),
        "runtimePlanSHA256": "3" * 64,
        "sbomSHA256": hashlib.sha256(pathlib.Path(sbom_path).read_bytes()).hexdigest(),
        "virtualHardwareABIVersion": "1",
    },
    "kind": "dev.dory.linux-vm-performance-verification-receipt",
    "releaseQualified": True,
    "schemaVersion": 1,
    "signaturePublicKeyID": hashlib.sha256(
        base64.b64decode(public_key, validate=True)
    ).hexdigest(),
    "supportCell": {
        "backend": "rawhv",
        "graphicsImplementation": "virgl2+venus",
        "hostIdentitySHA256": "4" * 64,
        "installedSystemIdentitySHA256": "5" * 64,
        "installerSHA256": media["immutableArtifactSHA256"],
        "matrixCellID": "e" * 64,
        "requestedGraphicsQuality": "accelerated",
        "selectedGraphicsQuality": "accelerated",
    },
}
pathlib.Path(destination).write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

write_performance_receipt
sign_file "$PERFORMANCE_RECEIPT" "$PERFORMANCE_RECEIPT_SIGNATURE"
write_qualification "$QUALIFICATION" none
sign_file "$QUALIFICATION" "$QUALIFICATION_SIGNATURE"

finalize() {
  local candidate="$1" output="$2" manifest="$3" signature="$4" sbom="$5"
  "$ROOT/scripts/build-components.py" finalize \
    --candidate "$candidate" \
    --output "$output" \
    --sbom "$sbom" \
    --qualification-manifest "$manifest" \
    --qualification-signature "$signature" \
    --performance-verification-receipt "$PERFORMANCE_RECEIPT" \
    --performance-verification-signature "$PERFORMANCE_RECEIPT_SIGNATURE" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PUBLIC_KEY"
}

# Exact-set validation rejects extra, missing, or mutated candidate files.
cp -R "$CANDIDATE" "$TMP/extra-candidate"
printf 'not inventory bound\n' > "$TMP/extra-candidate/rogue.txt"
if finalize "$TMP/extra-candidate" "$TMP/extra-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/extra.out" 2>&1; then
  echo "component packaging accepted an extra candidate file" >&2
  exit 1
fi
grep -Fq 'candidate output file set changed' "$TMP/extra.out" \
  || { echo "component packaging rejected an extra file for the wrong reason" >&2; exit 1; }

cp -R "$CANDIDATE" "$TMP/missing-candidate"
MISSING_ASSET="$(python3 - "$TMP/missing-candidate" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
inventory = json.loads((root / "component-candidate-inventory.json").read_text())
print(inventory["files"][0]["name"])
PY
)"
rm "$TMP/missing-candidate/$MISSING_ASSET"
if finalize "$TMP/missing-candidate" "$TMP/missing-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/missing.out" 2>&1; then
  echo "component packaging accepted a missing candidate file" >&2
  exit 1
fi
grep -Fq 'candidate output file set changed' "$TMP/missing.out" \
  || { echo "component packaging rejected a missing file for the wrong reason" >&2; exit 1; }

cp -R "$CANDIDATE" "$TMP/mutated-candidate"
python3 - "$TMP/mutated-candidate" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
inventory = json.loads((root / "component-candidate-inventory.json").read_text())
path = root / inventory["files"][0]["name"]
with path.open("r+b") as handle:
    first = handle.read(1)
    handle.seek(0)
    handle.write(bytes([first[0] ^ 0xff]))
PY
if finalize "$TMP/mutated-candidate" "$TMP/mutated-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/mutated.out" 2>&1; then
  echo "component packaging accepted mutated candidate bytes" >&2
  exit 1
fi
grep -Fq 'inventory-bound asset changed' "$TMP/mutated.out" \
  || { echo "component packaging rejected mutated bytes for the wrong reason" >&2; exit 1; }

# Candidate and publication authority are distinct direct paths. Finalization must neither replace
# its evidence input nor follow a caller-controlled output symlink into another directory.
if finalize "$CANDIDATE" "$CANDIDATE" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/same-output.out" 2>&1; then
  echo "component packaging replaced its candidate input" >&2
  exit 1
fi
grep -Fq 'must be separate from the candidate directory' "$TMP/same-output.out" \
  || { echo "component packaging rejected a shared candidate/output for the wrong reason" >&2; exit 1; }

if finalize "$CANDIDATE" "$CANDIDATE/nested-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/nested-output.out" 2>&1; then
  echo "component packaging published inside its candidate input" >&2
  exit 1
fi
grep -Fq 'must be separate from the candidate directory' "$TMP/nested-output.out" \
  || { echo "component packaging rejected a nested output for the wrong reason" >&2; exit 1; }

ln -s "$CANDIDATE" "$TMP/indirect-candidate"
if finalize "$TMP/indirect-candidate" "$TMP/indirect-candidate-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/indirect-candidate.out" 2>&1; then
  echo "component packaging accepted an indirect candidate path" >&2
  exit 1
fi
grep -Fq 'component candidate input is not a directory' "$TMP/indirect-candidate.out" \
  || { echo "component packaging rejected an indirect candidate for the wrong reason" >&2; exit 1; }

mkdir "$TMP/symlink-output-target"
printf 'preserve\n' > "$TMP/symlink-output-target/sentinel"
ln -s "$TMP/symlink-output-target" "$TMP/indirect-final"
if finalize "$CANDIDATE" "$TMP/indirect-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM" \
    >"$TMP/indirect-final.out" 2>&1; then
  echo "component packaging followed an indirect publication path" >&2
  exit 1
fi
grep -Fq 'final component output cannot be a symbolic link' "$TMP/indirect-final.out" \
  || { echo "component packaging rejected an indirect output for the wrong reason" >&2; exit 1; }
[ "$(cat "$TMP/symlink-output-target/sentinel")" = preserve ] \
  || { echo "component packaging mutated the symlink target" >&2; exit 1; }

# Authenticated evidence must bind this inventory, SBOM, runtime helper, and packaged media.
for mutation in wrong-inventory wrong-helper wrong-media wrong-release; do
  manifest="$TMP/$mutation.json"
  signature="$TMP/$mutation.json.sig"
  write_qualification "$manifest" "$mutation"
  sign_file "$manifest" "$signature"
  if finalize "$CANDIDATE" "$TMP/$mutation-final" \
      "$manifest" "$signature" "$SBOM" \
      >"$TMP/$mutation.out" 2>&1; then
    echo "component packaging accepted qualification mismatch: $mutation" >&2
    exit 1
  fi
done
grep -Fq 'binds another component candidate inventory' "$TMP/wrong-inventory.out" \
  || { echo "component packaging rejected inventory mismatch for the wrong reason" >&2; exit 1; }
grep -Fq 'runtime build does not match' "$TMP/wrong-helper.out" \
  || { echo "component packaging rejected helper mismatch for the wrong reason" >&2; exit 1; }
grep -Fq 'bundled media digest is not inventory-bound' "$TMP/wrong-media.out" \
  || { echo "component packaging rejected media mismatch for the wrong reason" >&2; exit 1; }
grep -Fq 'release does not match' "$TMP/wrong-release.out" \
  || { echo "component packaging rejected release mismatch for the wrong reason" >&2; exit 1; }

printf '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[{"name":"changed"}]}\n' \
  > "$TMP/other.cdx.json"
if finalize "$CANDIDATE" "$TMP/wrong-sbom-final" \
    "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$TMP/other.cdx.json" \
    >"$TMP/wrong-sbom.out" 2>&1; then
  echo "component packaging accepted qualification for another SBOM" >&2
  exit 1
fi
grep -Fq 'binds another SBOM' "$TMP/wrong-sbom.out" \
  || { echo "component packaging rejected SBOM mismatch for the wrong reason" >&2; exit 1; }

if finalize "$CANDIDATE" "$TMP/wrong-signature-final" \
    "$QUALIFICATION" "$TMP/wrong-helper.json.sig" "$SBOM" \
    >"$TMP/wrong-signature.out" 2>&1; then
  echo "component packaging accepted a detached signature for another manifest" >&2
  exit 1
fi
grep -Fq 'signature does not authenticate the message' "$TMP/wrong-signature.out" \
  || { echo "component packaging rejected signature mismatch for the wrong reason" >&2; exit 1; }

# Finalization publishes to a separate directory and leaves the candidate untouched.
finalize "$CANDIDATE" "$OUTPUT" "$QUALIFICATION" "$QUALIFICATION_SIGNATURE" "$SBOM"
python3 - \
  "$CANDIDATE" "$OUTPUT" "$TMP/candidate-before.json" "$SBOM" "$QUALIFICATION" \
  "$QUALIFICATION_SIGNATURE" "$PUBLIC_KEY" "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys

candidate = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
before = json.loads(pathlib.Path(sys.argv[3]).read_text())
sbom = pathlib.Path(sys.argv[4])
qualification_source = pathlib.Path(sys.argv[5])
qualification_signature_source = pathlib.Path(sys.argv[6])
public_key = sys.argv[7]
repo = pathlib.Path(sys.argv[8])

for name, expected in before.items():
    candidate_path = candidate / name
    final_path = root / name
    candidate_info = candidate_path.stat()
    final_info = final_path.stat()
    assert candidate_info.st_size == expected["bytes"]
    assert candidate_info.st_mode == expected["mode"]
    assert candidate_info.st_ino == expected["inode"]
    assert candidate_info.st_mtime_ns == expected["mtimeNS"]
    assert candidate_info.st_ctime_ns == expected["ctimeNS"]
    assert hashlib.sha256(candidate_path.read_bytes()).hexdigest() == expected["sha256"]
    assert final_info.st_size == expected["bytes"]
    assert hashlib.sha256(final_path.read_bytes()).hexdigest() == expected["sha256"]
    assert (final_info.st_dev, final_info.st_ino) != (
        candidate_info.st_dev, candidate_info.st_ino,
    )
assert not (candidate / "catalog.json").exists()

inventory = json.loads((root / "component-candidate-inventory.json").read_text())
catalog = json.loads((root / "catalog.json").read_text())
assert catalog["kind"] == "dev.dory.component-catalog"
assert catalog["schemaVersion"] == 2
assert catalog["releaseVersion"] == inventory["releaseVersion"]
assert catalog["generatedAt"] == inventory["generatedAt"]
assert catalog["architecture"] == "arm64"
assert [item["id"] for item in catalog["components"]] == [
    "docker-core", "kubernetes", "linux-machines", "linux-desktop",
    "desktop-debian", "desktop-ubuntu", "desktop-kali",
]
sbom_digest = hashlib.sha256(sbom.read_bytes()).hexdigest()
attestation_digest = hashlib.sha256(qualification_source.read_bytes()).hexdigest()
for component in catalog["components"]:
    assert component["provenance"] == {
        "sourceCommit": inventory["sourceCommit"],
        "builder": inventory["builder"],
        "recipeDigest": inventory["recipeDigest"],
        "sbomDigest": sbom_digest,
        "attestationDigest": attestation_digest,
    }
    assert isinstance(component["qualification"], list)

linux = next(item for item in catalog["components"] if item["id"] == "linux-desktop")
assert linux["qualification"] == ["linux-desktop-arm64-mac16-1-25a1"]
assert not any("virgl" in claim or "venus" in claim for claim in linux["provides"])
evidence = {
    asset["path"]: asset
    for asset in linux["assets"]
    if asset["role"] == "qualification-evidence"
}
assert set(evidence) == {
    "virtual-machine-qualification.json",
    "virtual-machine-qualification.json.sig",
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.linux-vm-performance-verification.json",
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.linux-vm-performance-verification.json.sig",
}
assert evidence["virtual-machine-qualification.json"]["installedSHA256"] == hashlib.sha256(
    qualification_source.read_bytes()
).hexdigest()
assert evidence["virtual-machine-qualification.json.sig"]["installedSHA256"] == hashlib.sha256(
    qualification_signature_source.read_bytes()
).hexdigest()
performance_receipt = qualification_source.parent / (
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    ".linux-vm-performance-verification.json"
)
performance_signature = performance_receipt.with_name(performance_receipt.name + ".sig")
assert evidence[performance_receipt.name]["installedSHA256"] == hashlib.sha256(
    performance_receipt.read_bytes()
).hexdigest()
assert evidence[performance_signature.name]["installedSHA256"] == hashlib.sha256(
    performance_signature.read_bytes()
).hexdigest()
for asset in evidence.values():
    artifact = root / asset["url"].rsplit("/", 1)[-1]
    assert hashlib.sha256(artifact.read_bytes()).hexdigest() == asset["sha256"]

qualification = catalog["virtualMachineQualification"]
assert qualification["component"] == "linux-desktop"
assert qualification["path"] == "virtual-machine-qualification.json"
assert qualification["manifestIdentity"] == "dory-release-9.8.7-apple-silicon"
assert qualification["manifestFormatVersion"] == 2

assert (root / "catalog.json.sha256").read_text().strip() == hashlib.sha256(
    (root / "catalog.json").read_bytes()
).hexdigest()
subprocess.run(
    [
        "xcrun", "swift", str(repo / ".github/scripts/verify-ed25519-signature.swift"),
        public_key, str(root / "catalog.json.sig"), str(root / "catalog.json"),
    ],
    check=True,
)
assert not list(root.parent.glob(".arm64.partial-*"))
assert not list(root.parent.glob(".arm64.finalize-*"))
assert not list(candidate.parent.glob(".candidate-arm64.partial-*"))

spec = importlib.util.spec_from_file_location(
    "dory_build_components", repo / "scripts/build-components.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
try:
    module.remove_private_build_directory(repo, repo.parent)
except SystemExit as error:
    assert "refusing unsafe component build cleanup" in str(error)
else:
    raise AssertionError("cleanup guard accepted the repository root")
assert (repo / ".git").is_dir()
PY

echo "component packaging test passed"
