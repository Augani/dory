#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-components-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
CORE_APP="$TMP/Dory.app"
OUTPUT="$TMP/components/arm64"
mkdir -p "$SOURCE" "$CORE_APP/Contents/MacOS"

write_fixture() {
  local path="$1" bytes="$2"
  dd if=/dev/zero of="$path" bs=1 count=0 seek="$bytes" 2>/dev/null
  printf 'dory-fixture-%s\n' "$(basename "$path")" | dd of="$path" conv=notrunc 2>/dev/null
}

write_fixture "$TMP/Dory-test.dmg" 4096
write_fixture "$CORE_APP/Contents/MacOS/Dory" 8192
write_fixture "$TMP/kubectl" 16384
chmod 0755 "$TMP/kubectl"
write_fixture "$SOURCE/Image" 131072
write_fixture "$SOURCE/initfs-arm64.ext4" 262144
write_fixture "$SOURCE/Image-desktop" 196608

for distro in debian ubuntu kali; do
  write_fixture "$SOURCE/dory-desktop-$distro-rootfs-arm64.ext4" 327680
  printf 'schema=fixture\n' > "$SOURCE/dory-desktop-$distro-build-arm64.stamp"
  printf 'xfce4\tfixture\n' > "$SOURCE/dory-desktop-$distro-packages-arm64.txt"
done
printf 'schema=fixture\n' > "$SOURCE/kernel-build-arm64-desktop.stamp"

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
    --skip-source-verification
}

build
build

python3 - "$OUTPUT" "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
catalog = json.loads((root / "catalog.json").read_text())
assert catalog["kind"] == "dev.dory.component-catalog"
assert catalog["schemaVersion"] == 1
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
assert catalog["components"][0]["installedBytes"] == 8192

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

echo "component packaging test passed"
