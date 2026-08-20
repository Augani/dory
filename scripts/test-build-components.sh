#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-components-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
CORE_APP="$TMP/Dory.app"
OUTPUT="$TMP/components/arm64"
QUALIFICATION="$TMP/virtual-machine-qualification.json"
mkdir -p "$SOURCE" "$CORE_APP/Contents/MacOS" "$CORE_APP/Contents/Helpers"

write_fixture() {
  local path="$1" bytes="$2"
  dd if=/dev/zero of="$path" bs=1 count=0 seek="$bytes" 2>/dev/null
  printf 'dory-fixture-%s\n' "$(basename "$path")" | dd of="$path" conv=notrunc 2>/dev/null
}

write_fixture "$TMP/Dory-test.dmg" 4096
write_fixture "$CORE_APP/Contents/MacOS/Dory" 8192
write_fixture "$CORE_APP/Contents/Helpers/dory-hv" 4096
write_fixture "$CORE_APP/Contents/Helpers/dory-vmm" 4096
chmod 0755 "$CORE_APP/Contents/Helpers/dory-hv" "$CORE_APP/Contents/Helpers/dory-vmm"
write_fixture "$TMP/kubectl" 16384
chmod 0755 "$TMP/kubectl"
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

python3 - "$QUALIFICATION" "$SOURCE" "$CORE_APP" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

key = base64.b64decode("AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4=")
digest = lambda byte: byte * 64
source = pathlib.Path(sys.argv[2])
app = pathlib.Path(sys.argv[3])
file_digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
runtime_digest = file_digest(app / "Contents/Helpers/dory-hv")
manifest = {
    "kind": "dev.dory.virtual-machine-qualification-manifest",
    "schemaVersion": 1,
    "manifestIdentity": "dory-release-9.8.7-apple-silicon",
    "catalogReleaseVersion": "9.8.7",
    "architecture": "arm64",
    "signingKeyID": hashlib.sha256(key).hexdigest(),
    "records": [{
        "qualificationIdentity": "linux-desktop-arm64-mac16-1-25a1",
        "guest": {"family": "linux", "architecture": "arm64"},
        "bootMediaKind": "linux-kernel",
        "bootMediaSource": "dory-bundled",
        "immutableArtifactSHA256": file_digest(source / "Image-desktop"),
        "backend": "dory-hypervisor",
        "backendImplementationIdentifier": "dory.raw-hv-linux.compatibility.v1",
        "backendRuntimeBuildIdentifier": f"sha256:{runtime_digest}",
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
            "buildIdentifier": f"sha256:{runtime_digest}",
            "artifactSHA256": runtime_digest,
        }],
        "virtioGPUKernelAndDeviceSupportQualified": True,
        "venusVulkanGuestRuntimeQualified": True,
    }],
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

build() {
  "$ROOT/scripts/build-components.py" \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$OUTPUT" \
    --asset-base-url https://example.invalid/dory \
    --generated-at 2026-07-16T00:00:00Z \
    --qualification-manifest "$QUALIFICATION" \
    --skip-source-verification
}

build
build

python3 - "$OUTPUT" "$ROOT" "$QUALIFICATION" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
qualification_source = pathlib.Path(sys.argv[3])
catalog = json.loads((root / "catalog.json").read_text())
assert catalog["kind"] == "dev.dory.component-catalog"
assert catalog["schemaVersion"] == 2
assert catalog["architecture"] == "arm64"
assert [item["id"] for item in catalog["components"]] == [
    "docker-core",
    "kubernetes",
    "linux-machines",
    "linux-desktop",
    "desktop-debian",
    "desktop-ubuntu",
    "desktop-kali",
]
assert catalog["components"][0]["assets"] == []
assert catalog["components"][0]["downloadBytes"] == 4096
assert catalog["components"][0]["installedBytes"] == 16384
qualification = catalog["virtualMachineQualification"]
assert qualification["component"] == "linux-desktop"
assert qualification["path"] == "virtual-machine-qualification.json"
assert qualification["manifestIdentity"] == "dory-release-9.8.7-apple-silicon"
assert qualification["manifestFormatVersion"] == 1
linux_desktop = next(item for item in catalog["components"] if item["id"] == "linux-desktop")
qualification_assets = [
    item for item in linux_desktop["assets"]
    if item["path"] == "virtual-machine-qualification.json"
]
assert len(qualification_assets) == 1
assert qualification_assets[0]["installedSHA256"] == hashlib.sha256(
    qualification_source.read_bytes()
).hexdigest()

for component in catalog["components"][1:]:
    assert component["downloadBytes"] == sum(
        item["downloadBytes"] for item in component["assets"]
    )
    assert component["installedBytes"] == sum(
        item["installedBytes"] for item in component["assets"]
    )
    for asset in component["assets"]:
        artifact = root / asset["url"].rsplit("/", 1)[-1]
        assert artifact.is_file()
        assert artifact.stat().st_size == asset["downloadBytes"]
        assert hashlib.sha256(artifact.read_bytes()).hexdigest() == asset["sha256"]
        if asset["compression"] == "none":
            assert asset["downloadBytes"] == asset["installedBytes"]
            assert asset["sha256"] == asset["installedSHA256"]
        else:
            with tempfile.NamedTemporaryFile() as decoded:
                subprocess.run(
                    [
                        "/usr/bin/compression_tool",
                        "-decode",
                        "-a",
                        "lzfse",
                        "-i",
                        str(artifact),
                        "-o",
                        decoded.name,
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                data = pathlib.Path(decoded.name).read_bytes()
                assert len(data) == asset["installedBytes"]
                assert hashlib.sha256(data).hexdigest() == asset["installedSHA256"]

assert not list(root.parent.glob(".arm64.partial-*"))
assert (root / "catalog.json.sha256").read_text().strip() == hashlib.sha256(
    (root / "catalog.json").read_bytes()
).hexdigest()

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

cp "$QUALIFICATION" "$TMP/invalid-qualification.json"
python3 - "$TMP/invalid-qualification.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["catalogReleaseVersion"] = "9.8.6"
path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
if "$ROOT/scripts/build-components.py" \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$TMP/rejected-components" \
    --qualification-manifest "$TMP/invalid-qualification.json" \
    --skip-source-verification 2>/dev/null; then
  echo "component packaging accepted a qualification manifest for another release" >&2
  exit 1
fi

cp "$QUALIFICATION" "$TMP/mismatched-helper-qualification.json"
python3 - "$TMP/mismatched-helper-qualification.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["records"][0]["components"][0]["artifactSHA256"] = "c" * 64
path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
if "$ROOT/scripts/build-components.py" \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$TMP/mismatched-helper-components" \
    --qualification-manifest "$TMP/mismatched-helper-qualification.json" \
    --skip-source-verification 2>/dev/null; then
  echo "component packaging accepted qualification evidence for different helper bytes" >&2
  exit 1
fi

cp "$QUALIFICATION" "$TMP/mismatched-media-qualification.json"
python3 - "$TMP/mismatched-media-qualification.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["records"][0]["immutableArtifactSHA256"] = "d" * 64
path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
if "$ROOT/scripts/build-components.py" \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$TMP/mismatched-media-components" \
    --qualification-manifest "$TMP/mismatched-media-qualification.json" \
    --skip-source-verification 2>/dev/null; then
  echo "component packaging accepted qualification evidence for different bundled media" >&2
  exit 1
fi

if "$ROOT/scripts/build-components.py" \
    --version 9.8.7 \
    --core-artifact "$TMP/Dory-test.dmg" \
    --core-app "$CORE_APP" \
    --kubectl "$TMP/kubectl" \
    --source-root "$SOURCE" \
    --output "$TMP/missing-qualification-components" \
    --skip-source-verification 2>/dev/null; then
  echo "component packaging accepted a catalog without qualification evidence" >&2
  exit 1
fi

echo "component packaging test passed"
