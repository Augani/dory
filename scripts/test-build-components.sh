#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-components-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

python3 - "$ROOT/scripts/build.sh" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def function_body(name):
    match = re.search(rf"^{re.escape(name)}\(\) \{{\n(.*?)^\}}$", text, re.M | re.S)
    assert match is not None, f"missing build function: {name}"
    return match.group(1)

signer = function_body("sign_hardened_payload")
assert "--options runtime" in signer
assert "|| codesign" not in signer
assert "=designated => identifier" in signer
runner = function_body("bundle_debug_hv_helper")
inventory_guard = runner.index(
    'if [ -e "$renderer_inventory" ] || [ -L "$renderer_inventory" ]; then'
)
development_signing = runner.index('sign_hardened_payload "$fs_worker_app"')
common_verification = runner.index(
    'verify_hardened_runtime_signature "$fs_worker_app"'
)
assert inventory_guard < development_signing < common_verification
assert '\n    else\n' in runner[inventory_guard:development_signing]
assert runner.find("sign_hardened_payload") == development_signing
assert "preserving Xcode-sealed production DoryHVRunner graph" in runner
assert "production renderer inventory is not a direct file" in runner
for payload in (
    '"$fs_worker_app"',
    '"$renderer_worker_app"',
    '"$runner_app"',
):
    assert f"sign_hardened_payload {payload}" in runner
    assert f"verify_hardened_runtime_signature {payload}" in runner
assert "codesign --verify --deep --strict \"$runner_app\"" in runner
vmm = function_body("bundle_doryd_swiftpm_helpers")
assert 'sign_hardened_payload "$helper" "$entitlements" dory-vmm' in vmm
assert 'sign_hardened_payload "$vmm_app" "$entitlements" dory-vmm' in vmm
assert "xcodebuild_status=$?" in text
assert 'echo "xcodebuild_exit=$xcodebuild_status"' in text
assert 'echo "build_exit=$status"' in text
PY

if ! (
  export DORY_RELEASE_SOURCE_ONLY=1
  export DORY_PUBLIC_RELEASE=0
  source "$ROOT/scripts/release.sh" 9.8.7 42
  preflight_public_release
); then
  echo "component packaging test: public component stop line blocked a local non-public build" >&2
  exit 1
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
grep -Fq 'no physical Linux VM campaign producer is wired after immutable candidate assembly and SBOM generation' \
  "$TMP/component-preflight.out" \
  || { echo "component packaging test: public preflight does not identify the producer/order gap" >&2; exit 1; }

# A pre-existing directory containing shape-only JSON and literal signature text cannot bypass the
# missing post-candidate physical producer. This specifically guards against the circular flow that
# previously treated pre-candidate placeholders as release authorization.
PREFLIGHT_EVIDENCE="$TMP/component-preflight-evidence"
PREFLIGHT_RECEIPT="$PREFLIGHT_EVIDENCE/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.linux-vm-performance-verification.json"
mkdir -p "$PREFLIGHT_EVIDENCE"
printf '{}\n' > "$PREFLIGHT_EVIDENCE/virtual-machine-qualification.json"
printf 'signature\n' > "$PREFLIGHT_EVIDENCE/virtual-machine-qualification.json.sig"
printf '{}\n' > "$PREFLIGHT_RECEIPT"
printf 'signature\n' > "$PREFLIGHT_RECEIPT.sig"
if (
  export DORY_RELEASE_SOURCE_ONLY=1
  export DORY_COMPONENT_QUALIFICATION_DIR="$PREFLIGHT_EVIDENCE"
  source "$ROOT/scripts/release.sh" 9.8.7 42
  preflight_component_supply_chain
) >"$TMP/component-preflight-dummy.out" 2>&1; then
  echo "component packaging test: dummy pre-candidate evidence bypassed the public stop line" >&2
  exit 1
fi
grep -Fq 'pre-candidate or synthetic qualification evidence cannot authorize schema-2 finalization' \
  "$TMP/component-preflight-dummy.out" \
  || { echo "component packaging test: dummy evidence failed for the wrong reason" >&2; exit 1; }

SOURCE="$TMP/source"
CORE_APP="$TMP/Dory.app"
CORE_ARTIFACT="$TMP/Dory-test.dmg"
DMG_SOURCE="$TMP/dmg-source"
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
PRODUCTION_CATALOG_PUBLIC_KEY="AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="
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
VMM_APP="$CORE_APP/Contents/Helpers/DoryVMM.app"
VMM_EXECUTABLE="$VMM_APP/Contents/MacOS/dory-vmm"
VMM_ENTITLEMENTS="$TMP/DoryVMM.entitlements"
VMM_EXCESS_ENTITLEMENTS="$TMP/DoryVMM-excess.entitlements"
OUTER_ENTITLEMENTS="$TMP/Dory.entitlements"
mkdir -p \
  "$SOURCE" \
  "$CORE_APP/Contents/MacOS" \
  "$RUNNER_APP/Contents/MacOS" \
  "$WORKER_XPC/Contents/MacOS" \
  "$RENDERER_XPC/Contents/MacOS" \
  "$VMM_APP/Contents/MacOS"

write_fixture() {
  local path="$1" bytes="$2"
  dd if=/dev/zero of="$path" bs=1 count=0 seek="$bytes" 2>/dev/null
  printf 'dory-fixture-%s\n' "$(basename "$path")" | dd of="$path" conv=notrunc 2>/dev/null
}

printf 'int main(void) { return 0; }\n' > "$TMP/fixture-main.c"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 \
  "$TMP/fixture-main.c" -o "$TMP/fixture-main"
for executable in \
  "$CORE_APP/Contents/MacOS/Dory" \
  "$RUNNER_EXECUTABLE" \
  "$WORKER_EXECUTABLE" \
  "$RENDERER_EXECUTABLE" \
  "$VMM_EXECUTABLE"; do
  cp "$TMP/fixture-main" "$executable"
done
cat > "$CORE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dory</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>9.8.7</string>
<key>CFBundleVersion</key><string>42</string>
</dict></plist>
PLIST
cat > "$OUTER_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array>
<string>864H636QW4.group.com.pythonxi.Dory</string>
</array>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST
cat > "$RUNNER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>dory-hv</string>
<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.HVRunner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSCameraUsageDescription</key><string>Dory test camera usage.</string>
<key>NSMicrophoneUsageDescription</key><string>Dory test microphone usage.</string>
</dict></plist>
PLIST
cat > "$RUNNER_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.camera</key><true/>
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
cat > "$VMM_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>dory-vmm</string>
<key>CFBundleIdentifier</key><string>dory-vmm</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSMicrophoneUsageDescription</key><string>Dory test microphone usage.</string>
</dict></plist>
PLIST
cat > "$VMM_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.virtualization</key><true/>
</dict></plist>
PLIST
cat > "$VMM_EXCESS_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.virtualization</key><true/>
</dict></plist>
PLIST
chmod 0755 \
  "$RUNNER_EXECUTABLE" \
  "$WORKER_EXECUTABLE" \
  "$RENDERER_EXECUTABLE" \
  "$VMM_EXECUTABLE" \
  "$CORE_APP/Contents/MacOS/Dory"
sign_test_bundle() {
  local entitlements="$1" bundle="$2" identifier="$3"
  codesign --force --sign - \
    --requirements "=designated => identifier \"$identifier\"" \
    --entitlements "$entitlements" "$bundle" >/dev/null
}
sign_test_bundle "$WORKER_ENTITLEMENTS" "$WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.FSWorker
sign_test_bundle "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" \
  com.pythonxi.Dory.HVRunner.RendererWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm
sign_test_bundle "$OUTER_ENTITLEMENTS" "$CORE_APP" com.pythonxi.Dory
codesign --verify --deep --strict "$RUNNER_APP"
codesign --verify --deep --strict "$VMM_APP"
codesign --verify --deep --strict "$CORE_APP"

prepare_core_release_fixture() {
  sign_test_bundle "$OUTER_ENTITLEMENTS" "$CORE_APP" com.pythonxi.Dory
  codesign --verify --deep --strict "$CORE_APP"
  rm -rf "$DMG_SOURCE"
  mkdir -p "$DMG_SOURCE"
  ditto "$CORE_APP" "$DMG_SOURCE/Dory.app"
  rm -f "$CORE_ARTIFACT"
  hdiutil create -quiet -ov -format UDZO -fs HFS+ -volname DoryTest \
    -srcfolder "$DMG_SOURCE" "$CORE_ARTIFACT"
}
prepare_core_release_fixture
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
  local candidate_output="${1:-$CANDIDATE}"
  "$ROOT/scripts/build-components.py" assemble \
    --version 9.8.7 \
    --core-artifact "$CORE_ARTIFACT" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$candidate_output" \
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
grep -Fq 'nested runner XPC worker graph is not exact' "$TMP/missing-worker.out" \
  || { cat "$TMP/missing-worker.out" >&2; echo "component packaging rejected a missing worker for the wrong reason" >&2; exit 1; }
mv "$TMP/DoryFSWorker.xpc.hold" "$WORKER_XPC"
sign_test_bundle "$WORKER_ENTITLEMENTS" "$WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.FSWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner

# A runner without the renderer process boundary must also remain unpublishable.
mv "$RENDERER_XPC" "$TMP/DoryRendererWorker.xpc.hold"
if assemble >"$TMP/missing-renderer-worker.out" 2>&1; then
  echo "component packaging accepted a runner without its renderer worker" >&2
  exit 1
fi
grep -Fq 'nested runner XPC worker graph is not exact' "$TMP/missing-renderer-worker.out" \
  || { cat "$TMP/missing-renderer-worker.out" >&2; echo "component packaging rejected a missing renderer worker for the wrong reason" >&2; exit 1; }
mv "$TMP/DoryRendererWorker.xpc.hold" "$RENDERER_XPC"
sign_test_bundle "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" \
  com.pythonxi.Dory.HVRunner.RendererWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner

# Ambient capabilities on the worker must not slip through an otherwise valid inside-out graph.
sign_test_bundle "$WORKER_EXCESS_ENTITLEMENTS" "$WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.FSWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner
if assemble >"$TMP/excess-worker-entitlements.out" 2>&1; then
  echo "component packaging accepted excess filesystem worker entitlements" >&2
  exit 1
fi
grep -Fq 'filesystem worker entitlements do not match its descriptor capability boundary' \
  "$TMP/excess-worker-entitlements.out" \
  || { cat "$TMP/excess-worker-entitlements.out" >&2; echo "component packaging rejected excess worker entitlements for the wrong reason" >&2; exit 1; }
sign_test_bundle "$WORKER_ENTITLEMENTS" "$WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.FSWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner

# The renderer is descriptor-only and receives no ambient file or network capability.
sign_test_bundle "$RENDERER_EXCESS_ENTITLEMENTS" "$RENDERER_XPC" \
  com.pythonxi.Dory.HVRunner.RendererWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner
if assemble >"$TMP/excess-renderer-entitlements.out" 2>&1; then
  echo "component packaging accepted excess renderer worker entitlements" >&2
  exit 1
fi
grep -Fq 'renderer worker entitlements do not match its minimal sandbox' \
  "$TMP/excess-renderer-entitlements.out" \
  || { echo "component packaging rejected excess renderer entitlements for the wrong reason" >&2; exit 1; }
sign_test_bundle "$RENDERER_ENTITLEMENTS" "$RENDERER_XPC" \
  com.pythonxi.Dory.HVRunner.RendererWorker
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner

# The portable backend is an application identity, never a flat executable binding.
mv "$VMM_APP" "$TMP/DoryVMM.app.hold"
if assemble >"$TMP/missing-vmm-app.out" 2>&1; then
  echo "component packaging accepted a core app without DoryVMM.app" >&2
  exit 1
fi
grep -Fq 'dory-vmm candidate helper is missing' "$TMP/missing-vmm-app.out" \
  || { cat "$TMP/missing-vmm-app.out" >&2; echo "component packaging rejected a missing VMM app for the wrong reason" >&2; exit 1; }
mv "$TMP/DoryVMM.app.hold" "$VMM_APP"
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm

# DoryVMM owns no XPC workers; adding an empty service root is itself a graph violation.
mkdir -p "$VMM_APP/Contents/XPCServices"
if assemble >"$TMP/vmm-xpc-worker.out" 2>&1; then
  echo "component packaging accepted XPC workers in DoryVMM.app" >&2
  exit 1
fi
grep -Fq 'nested VMM application must not contain XPC workers' "$TMP/vmm-xpc-worker.out" \
  || { cat "$TMP/vmm-xpc-worker.out" >&2; echo "component packaging rejected the VMM XPC graph for the wrong reason" >&2; exit 1; }
rm -rf "$VMM_APP/Contents/XPCServices"
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm

# The VMM entitlement boundary is exact and excludes dynamic-library authority.
sign_test_bundle "$VMM_EXCESS_ENTITLEMENTS" "$VMM_APP" dory-vmm
if assemble >"$TMP/excess-vmm-entitlements.out" 2>&1; then
  echo "component packaging accepted excess VMM entitlements" >&2
  exit 1
fi
grep -Fq 'nested VMM entitlements do not match its hardware boundary' \
  "$TMP/excess-vmm-entitlements.out" \
  || { cat "$TMP/excess-vmm-entitlements.out" >&2; echo "component packaging rejected excess VMM entitlements for the wrong reason" >&2; exit 1; }
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm

# Privacy authorization is part of the signed runner identity, not an optional UI convention.
/usr/libexec/PlistBuddy -c 'Delete :NSCameraUsageDescription' \
  "$RUNNER_APP/Contents/Info.plist"
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner
if assemble >"$TMP/missing-runner-camera-usage.out" 2>&1; then
  echo "component packaging accepted a runner without camera privacy disclosure" >&2
  exit 1
fi
grep -Fq 'nested runner is missing NSCameraUsageDescription' \
  "$TMP/missing-runner-camera-usage.out" \
  || { cat "$TMP/missing-runner-camera-usage.out" >&2; echo "component packaging rejected the runner privacy graph for the wrong reason" >&2; exit 1; }
/usr/libexec/PlistBuddy -c \
  'Add :NSCameraUsageDescription string Dory test camera usage.' \
  "$RUNNER_APP/Contents/Info.plist"
sign_test_bundle "$RUNNER_ENTITLEMENTS" "$RUNNER_APP" com.pythonxi.Dory.HVRunner

# Every host executable in the shipped graph must actually contain Apple-silicon code.
xcrun clang -arch x86_64 -mmacosx-version-min=14.0 \
  "$TMP/fixture-main.c" -o "$TMP/fixture-main-x86_64"
cp "$VMM_EXECUTABLE" "$TMP/dory-vmm-arm64"
cp "$TMP/fixture-main-x86_64" "$VMM_EXECUTABLE"
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm
if assemble >"$TMP/x86-vmm.out" 2>&1; then
  echo "component packaging accepted an x86-only VMM" >&2
  exit 1
fi
grep -Fq 'nested VMM executable does not contain arm64 code' "$TMP/x86-vmm.out" \
  || { cat "$TMP/x86-vmm.out" >&2; echo "component packaging rejected the VMM architecture for the wrong reason" >&2; exit 1; }
cp "$TMP/dory-vmm-arm64" "$VMM_EXECUTABLE"
sign_test_bundle "$VMM_ENTITLEMENTS" "$VMM_APP" dory-vmm

# Assembly rejects a lexical output symlink before it can replace or populate the target.
mkdir "$TMP/assemble-output-target"
printf 'preserve\n' > "$TMP/assemble-output-target/sentinel"
ln -s "$TMP/assemble-output-target" "$TMP/indirect-assemble-output"
if assemble "$TMP/indirect-assemble-output" \
    >"$TMP/indirect-assemble-output.out" 2>&1; then
  echo "component packaging followed an indirect candidate output" >&2
  exit 1
fi
grep -Fq 'component candidate output cannot be a symbolic link' \
  "$TMP/indirect-assemble-output.out" \
  || { cat "$TMP/indirect-assemble-output.out" >&2; echo "component packaging rejected an indirect candidate output for the wrong reason" >&2; exit 1; }
[ "$(cat "$TMP/assemble-output-target/sentinel")" = preserve ] \
  || { echo "component packaging mutated the indirect candidate target" >&2; exit 1; }

# Assembly has no SBOM, qualification, signature, or catalog inputs and must still succeed.
prepare_core_release_fixture

# The outer app release version is an exact part of the component release identity.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.8.6' \
  "$CORE_APP/Contents/Info.plist"
sign_test_bundle "$OUTER_ENTITLEMENTS" "$CORE_APP" com.pythonxi.Dory
if assemble >"$TMP/wrong-outer-version.out" 2>&1; then
  echo "component packaging accepted an outer app from another release" >&2
  exit 1
fi
grep -Fq 'outer Dory marketing version does not match the component release' \
  "$TMP/wrong-outer-version.out" \
  || { cat "$TMP/wrong-outer-version.out" >&2; echo "component packaging rejected the outer app version for the wrong reason" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.8.7' \
  "$CORE_APP/Contents/Info.plist"
prepare_core_release_fixture

# A valid disk image from another app tree cannot be paired with this signed/versioned Dory.app.
cp "$CORE_ARTIFACT" "$TMP/Dory-correct.dmg"
rm -rf "$TMP/wrong-dmg-source"
mkdir -p "$TMP/wrong-dmg-source"
ditto "$CORE_APP" "$TMP/wrong-dmg-source/Dory.app"
mkdir -p "$TMP/wrong-dmg-source/Dory.app/Contents/Resources"
printf 'different signed app tree\n' \
  > "$TMP/wrong-dmg-source/Dory.app/Contents/Resources/not-the-candidate.txt"
rm -f "$CORE_ARTIFACT"
hdiutil create -quiet -ov -format UDZO -fs HFS+ -volname DoryWrongTest \
  -srcfolder "$TMP/wrong-dmg-source" "$CORE_ARTIFACT"
if assemble >"$TMP/wrong-dmg-application.out" 2>&1; then
  echo "component packaging accepted an unrelated app disk image" >&2
  exit 1
fi
grep -Fq 'Docker Core disk image does not contain the exact supplied Dory.app' \
  "$TMP/wrong-dmg-application.out" \
  || { cat "$TMP/wrong-dmg-application.out" >&2; echo "component packaging rejected the unrelated disk image for the wrong reason" >&2; exit 1; }
cp "$TMP/Dory-correct.dmg" "$CORE_ARTIFACT"

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
artifact = inventory["core"]["artifact"]
assert artifact["sha256"]
assert artifact["format"] == "apple-disk-image"
assert artifact["embeddedApplicationPath"] == "Dory.app"
application = inventory["core"]["application"]
assert application["entryCount"] > 0
assert application["regularFileBytes"] == inventory["core"]["installedBytes"]
assert len(application["graphSHA256"]) == 64
assert artifact["embeddedApplicationGraphSHA256"] == application["graphSHA256"]
outer = application["signedBundle"]
assert outer["path"] == "Dory.app"
assert outer["bundleIdentifier"] == "com.pythonxi.Dory"
assert outer["bundleExecutable"] == "Dory"
assert outer["bundlePackageType"] == "APPL"
assert outer["bundleShortVersion"] == "9.8.7"
assert outer["bundleVersion"] == "42"
assert outer["signatureKind"] == "adhoc-test"
assert outer["teamIdentifier"] == "-"
assert outer["hardenedRuntime"] is False
assert outer["entitlements"] == {
    "com.apple.security.application-groups": [
        "864H636QW4.group.com.pythonxi.Dory"
    ],
    "com.apple.security.device.audio-input": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}
assert outer["executableBytes"] > 0
assert len(outer["executableSHA256"]) == 64
assert [item["componentIdentifier"] for item in inventory["core"]["helpers"]] == [
    "dory-hv", "dory-vmm",
]
runner = inventory["core"]["helpers"][0]
assert runner["path"] == "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv"
assert runner["signedBundle"]["path"] == "Contents/Helpers/DoryHVRunner.app"
assert runner["signedBundle"]["bundleIdentifier"] == "com.pythonxi.Dory.HVRunner"
assert runner["signedBundle"]["bundleExecutable"] == "dory-hv"
assert runner["signedBundle"]["bundlePackageType"] == "APPL"
assert runner["signedBundle"]["designatedRequirement"] == 'identifier "com.pythonxi.Dory.HVRunner"'
assert runner["signedBundle"]["signatureKind"] == "adhoc-test"
assert runner["signedBundle"]["teamIdentifier"] == "-"
assert runner["signedBundle"]["hardenedRuntime"] is False
assert runner["signedBundle"]["entitlements"] == {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.device.camera": True,
    "com.apple.security.hypervisor": True,
}
assert [item["path"] for item in runner["signedBundle"]["nestedBundles"]] == [
    "Contents/XPCServices/DoryFSWorker.xpc",
    "Contents/XPCServices/DoryRendererWorker.xpc",
]
assert runner["signedBundle"]["nestedBundles"][0]["entitlements"] == {}
assert runner["signedBundle"]["nestedBundles"][1]["entitlements"] == {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.application-groups": ["864H636QW4.dory-renderer"],
}
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
vmm = inventory["core"]["helpers"][1]
assert vmm["path"] == "Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm"
assert vmm["signedBundle"]["path"] == "Contents/Helpers/DoryVMM.app"
assert vmm["signedBundle"]["bundleIdentifier"] == "dory-vmm"
assert vmm["signedBundle"]["bundleExecutable"] == "dory-vmm"
assert vmm["signedBundle"]["bundlePackageType"] == "APPL"
assert vmm["signedBundle"]["designatedRequirement"] == 'identifier "dory-vmm"'
assert vmm["signedBundle"]["signatureKind"] == "adhoc-test"
assert vmm["signedBundle"]["teamIdentifier"] == "-"
assert vmm["signedBundle"]["hardenedRuntime"] is False
assert vmm["signedBundle"]["entitlements"] == {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.virtualization": True,
}
assert "com.apple.security.cs.disable-library-validation" not in vmm["signedBundle"]["entitlements"]
assert not any("xpc" in key.lower() for key in vmm["signedBundle"]["entitlements"])
assert vmm["signedBundle"]["nestedBundles"] == []
vmm_files = {
    item["path"]: item
    for item in vmm["signedBundle"]["files"]
}
assert "Contents/Info.plist" in vmm_files
assert "Contents/_CodeSignature/CodeResources" in vmm_files
assert vmm["signedBundle"]["codeResourcesSHA256"] == vmm_files[
    "Contents/_CodeSignature/CodeResources"
]["sha256"]
assert vmm_files["Contents/MacOS/dory-vmm"]["sha256"] == vmm["sha256"]
assert vmm_files["Contents/MacOS/dory-vmm"]["mode"] & 0o111
assert not any(path.startswith("Contents/XPCServices/") for path in vmm_files)
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
  --candidate "$CANDIDATE" \
  --core-artifact "$CORE_ARTIFACT" \
  --core-app "$CORE_APP" \
  --allow-test-signatures \
  > "$TMP/candidate-verification.json"
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

mutate_core_inventory() {
  local mutation="$1" destination
  destination="$TMP/$mutation-candidate"
  cp -R "$CANDIDATE" "$destination"
  python3 - "$destination" "$mutation" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
inventory_path = root / "component-candidate-inventory.json"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
vmm = next(
    item for item in inventory["core"]["helpers"]
    if item["componentIdentifier"] == "dory-vmm"
)
runner = next(
    item for item in inventory["core"]["helpers"]
    if item["componentIdentifier"] == "dory-hv"
)

def canonical(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()

if mutation == "missing-vmm-bundle":
    del vmm["signedBundle"]
elif mutation == "wrong-vmm-graph":
    bundle = vmm["signedBundle"]
    bundle["files"] = [
        item for item in bundle["files"]
        if item["path"] != "Contents/Info.plist"
    ]
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "missing-vmm-code-resources":
    bundle = vmm["signedBundle"]
    bundle["files"] = [
        item for item in bundle["files"]
        if item["path"] != "Contents/_CodeSignature/CodeResources"
    ]
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "missing-renderer-code-resources":
    bundle = runner["signedBundle"]
    seal = (
        "Contents/XPCServices/DoryRendererWorker.xpc/Contents/"
        "_CodeSignature/CodeResources"
    )
    bundle["files"] = [item for item in bundle["files"] if item["path"] != seal]
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "forged-vmm-requirement":
    bundle = vmm["signedBundle"]
    bundle["designatedRequirement"] = 'identifier "forged-vmm"'
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "forged-vmm-entitlements":
    bundle = vmm["signedBundle"]
    bundle["entitlements"]["com.apple.security.cs.disable-library-validation"] = True
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "vmm-executable-mismatch":
    bundle = vmm["signedBundle"]
    executable = next(
        item for item in bundle["files"]
        if item["path"] == "Contents/MacOS/dory-vmm"
    )
    executable["sha256"] = "0" * 64 if vmm["sha256"] != "0" * 64 else "1" * 64
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
elif mutation == "canonical-forged-vmm-seal":
    bundle = vmm["signedBundle"]
    seal = next(
        item for item in bundle["files"]
        if item["path"] == "Contents/_CodeSignature/CodeResources"
    )
    forged = "0" * 64 if seal["sha256"] != "0" * 64 else "1" * 64
    seal["sha256"] = forged
    bundle["codeResourcesSHA256"] = forged
    graph = dict(bundle)
    del graph["graphSHA256"]
    bundle["graphSHA256"] = hashlib.sha256(canonical(graph)).hexdigest()
else:
    raise SystemExit(f"unknown inventory mutation: {mutation}")

raw = canonical(inventory)
inventory_path.write_bytes(raw)
(root / "component-candidate-inventory.json.sha256").write_text(
    hashlib.sha256(raw).hexdigest() + "\n",
    encoding="ascii",
)
PY
}

# Inventory validation must fail closed even when an attacker recomputes the unsigned candidate
# digest and, where applicable, the nested bundle graph digest.
for mutation in \
  missing-vmm-bundle \
  wrong-vmm-graph \
  missing-vmm-code-resources \
  missing-renderer-code-resources \
  forged-vmm-requirement \
  forged-vmm-entitlements \
  vmm-executable-mismatch \
  canonical-forged-vmm-seal; do
  mutate_core_inventory "$mutation"
  if "$ROOT/scripts/build-components.py" verify-candidate \
      --candidate "$TMP/$mutation-candidate" \
      --core-artifact "$CORE_ARTIFACT" \
      --core-app "$CORE_APP" \
      --allow-test-signatures \
      >"$TMP/$mutation.out" 2>&1; then
    echo "component packaging accepted adversarial VMM inventory: $mutation" >&2
    exit 1
  fi
done
grep -Fq 'core helper 1 has missing or unknown fields' "$TMP/missing-vmm-bundle.out" \
  || { cat "$TMP/missing-vmm-bundle.out" >&2; echo "component packaging rejected a missing VMM bundle graph for the wrong reason" >&2; exit 1; }
grep -Fq 'does not contain its required dory-vmm signed bundle Info.plist' "$TMP/wrong-vmm-graph.out" \
  || { cat "$TMP/wrong-vmm-graph.out" >&2; echo "component packaging rejected a wrong VMM bundle graph for the wrong reason" >&2; exit 1; }
grep -Fq 'does not contain its required dory-vmm signed bundle CodeResources seal' \
  "$TMP/missing-vmm-code-resources.out" \
  || { cat "$TMP/missing-vmm-code-resources.out" >&2; echo "component packaging rejected an incomplete VMM seal graph for the wrong reason" >&2; exit 1; }
grep -Fq 'does not contain its required dory-hv signed bundle renderer worker CodeResources seal' \
  "$TMP/missing-renderer-code-resources.out" \
  || { cat "$TMP/missing-renderer-code-resources.out" >&2; echo "component packaging rejected an incomplete renderer seal graph for the wrong reason" >&2; exit 1; }
grep -Fq 'dory-vmm signed bundle designated requirement is not canonical' \
  "$TMP/forged-vmm-requirement.out" \
  || { cat "$TMP/forged-vmm-requirement.out" >&2; echo "component packaging rejected a forged VMM requirement for the wrong reason" >&2; exit 1; }
grep -Fq 'dory-vmm signed bundle entitlements is invalid' \
  "$TMP/forged-vmm-entitlements.out" \
  || { cat "$TMP/forged-vmm-entitlements.out" >&2; echo "component packaging rejected forged VMM entitlements for the wrong reason" >&2; exit 1; }
grep -Fq 'dory-vmm executable binding differs from its signed bundle graph' \
  "$TMP/vmm-executable-mismatch.out" \
  || { cat "$TMP/vmm-executable-mismatch.out" >&2; echo "component packaging rejected a VMM executable mismatch for the wrong reason" >&2; exit 1; }
grep -Fq 'core signature evidence differs from the exact candidate-verification core inputs' \
  "$TMP/canonical-forged-vmm-seal.out" \
  || { cat "$TMP/canonical-forged-vmm-seal.out" >&2; echo "component packaging rejected a fully recomputed canonical graph for the wrong reason" >&2; exit 1; }

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
    --core-artifact "$CORE_ARTIFACT" \
    --core-app "$CORE_APP" \
    --sbom "$SBOM" \
    --qualification-manifest "$TMP/missing-qualification.json" \
    --qualification-signature "$TMP/missing-qualification.json.sig" \
    --performance-verification-receipt "$TMP/missing-performance-receipt.json" \
    --performance-verification-signature "$TMP/missing-performance-receipt.json.sig" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PUBLIC_KEY" \
    --allow-test-signatures \
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
        "applicationSHA256": inventory["core"]["application"]["graphSHA256"],
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

# The hidden fixture path is structurally and cryptographically outside the production trust root.
if "$ROOT/scripts/build-components.py" finalize \
    --candidate "$CANDIDATE" \
    --output "$TMP/production-key-test-signature-final" \
    --core-artifact "$CORE_ARTIFACT" \
    --core-app "$CORE_APP" \
    --sbom "$SBOM" \
    --qualification-manifest "$QUALIFICATION" \
    --qualification-signature "$QUALIFICATION_SIGNATURE" \
    --performance-verification-receipt "$PERFORMANCE_RECEIPT" \
    --performance-verification-signature "$PERFORMANCE_RECEIPT_SIGNATURE" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PRODUCTION_CATALOG_PUBLIC_KEY" \
    --allow-test-signatures \
    >"$TMP/production-key-test-signature.out" 2>&1; then
  echo "component packaging accepted fixture identities under the production trust root" >&2
  exit 1
fi
grep -Fq 'test-signature finalization requires a non-production catalog trust root' \
  "$TMP/production-key-test-signature.out" \
  || { cat "$TMP/production-key-test-signature.out" >&2; echo "component packaging rejected the production fixture trust root for the wrong reason" >&2; exit 1; }

# A staged/public finalization must never accept the deterministic ad-hoc fixture graph unless the
# explicitly hidden test-only switch is present.
if "$ROOT/scripts/build-components.py" finalize \
    --candidate "$CANDIDATE" \
    --output "$TMP/adhoc-public-final" \
    --core-artifact "$CORE_ARTIFACT" \
    --core-app "$CORE_APP" \
    --sbom "$SBOM" \
    --qualification-manifest "$QUALIFICATION" \
    --qualification-signature "$QUALIFICATION_SIGNATURE" \
    --performance-verification-receipt "$PERFORMANCE_RECEIPT" \
    --performance-verification-signature "$PERFORMANCE_RECEIPT_SIGNATURE" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PUBLIC_KEY" \
    >"$TMP/adhoc-public.out" 2>&1; then
  echo "component packaging accepted ad-hoc core identities as a public candidate" >&2
  exit 1
fi
grep -Fq 'staged finalization requires Developer ID core signature evidence' \
  "$TMP/adhoc-public.out" \
  || { cat "$TMP/adhoc-public.out" >&2; echo "component packaging rejected ad-hoc public identities for the wrong reason" >&2; exit 1; }

finalize() {
  local candidate="$1" output="$2" manifest="$3" signature="$4" sbom="$5"
  "$ROOT/scripts/build-components.py" finalize \
    --candidate "$candidate" \
    --output "$output" \
    --core-artifact "$CORE_ARTIFACT" \
    --core-app "$CORE_APP" \
    --sbom "$sbom" \
    --qualification-manifest "$manifest" \
    --qualification-signature "$signature" \
    --performance-verification-receipt "$PERFORMANCE_RECEIPT" \
    --performance-verification-signature "$PERFORMANCE_RECEIPT_SIGNATURE" \
    --signer "$CATALOG_SIGNER" \
    --catalog-public-key "$PUBLIC_KEY" \
    --allow-test-signatures
}

# A correctly signed performance campaign for a different Dory.app graph is not release evidence
# for this candidate, even when its qualification manifest is regenerated around that receipt.
cp "$PERFORMANCE_RECEIPT" "$TMP/performance-receipt.correct"
cp "$PERFORMANCE_RECEIPT_SIGNATURE" "$TMP/performance-receipt.correct.sig"
python3 - "$PERFORMANCE_RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text(encoding="utf-8"))
receipt["candidate"]["applicationSHA256"] = "0" * 64
path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
sign_file "$PERFORMANCE_RECEIPT" "$PERFORMANCE_RECEIPT_SIGNATURE"
write_qualification "$TMP/wrong-performance-application.json" none
sign_file "$TMP/wrong-performance-application.json" \
  "$TMP/wrong-performance-application.json.sig"
if finalize "$CANDIDATE" "$TMP/wrong-performance-application-final" \
    "$TMP/wrong-performance-application.json" \
    "$TMP/wrong-performance-application.json.sig" "$SBOM" \
    >"$TMP/wrong-performance-application.out" 2>&1; then
  echo "component packaging accepted performance evidence for another Dory app" >&2
  exit 1
fi
grep -Fq 'performance receipt binds another Dory application' \
  "$TMP/wrong-performance-application.out" \
  || { cat "$TMP/wrong-performance-application.out" >&2; echo "component packaging rejected the performance app binding for the wrong reason" >&2; exit 1; }
cp "$TMP/performance-receipt.correct" "$PERFORMANCE_RECEIPT"
cp "$TMP/performance-receipt.correct.sig" "$PERFORMANCE_RECEIPT_SIGNATURE"

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
assert catalog["kind"] == "dev.dory.component-catalog.test-fixture"
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
assert repo.is_dir()
assert subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "--is-inside-work-tree"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip() == "true"
PY

echo "component packaging test passed"
