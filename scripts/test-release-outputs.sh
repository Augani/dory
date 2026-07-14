#!/bin/bash
# Offline regression tests for the public release artifact/appcast contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-release-outputs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

build_help="$(scripts/build.sh --help)"
grep -Fq 'development app only' <<< "$build_help" \
  || { echo "test-release-outputs: build help is missing its non-release warning" >&2; exit 1; }
test_help="$(scripts/test.sh --help)"
grep -Fq 'dedicated shared Dory UI Tests scheme' <<< "$test_help" \
  || { echo "test-release-outputs: test help is missing UI scheme routing" >&2; exit 1; }
grep -Fq 'scheme="Dory UI Tests"' scripts/test.sh \
  || { echo "test-release-outputs: DoryUITests requests are not routed to the UI scheme" >&2; exit 1; }
grep -Fq 'if [ "${#test_args[@]}" -gt 0 ]' scripts/test.sh \
  || { echo "test-release-outputs: unfiltered app tests still expand an empty Bash 3 array" >&2; exit 1; }
grep -Fq 'dory-transfer-helper-image-arm64.tar' scripts/bundle-engine.sh \
  || { echo "test-release-outputs: release bundler omits the transfer-helper image" >&2; exit 1; }
grep -Fq 'bundle_debug_transfer_helper' scripts/build.sh \
  || { echo "test-release-outputs: debug bundler omits the transfer-helper image" >&2; exit 1; }

VERSION="0.3.0"
BUILD="42"
APP="$TMP/export-arm64/Dory.app"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
LAUNCH_DAEMONS="$APP/Contents/Library/LaunchDaemons"
mkdir -p "$RESOURCES" "$HELPERS" "$LAUNCH_DAEMONS"
for helper in dory-dataplane-proxy docker-buildx dory-network-helper dory-hv; do
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done
DORY_HV_SHA="$(shasum -a 256 "$HELPERS/dory-hv" | awk '{print $1}')"
cp Config/dev.dory.network-helper.plist \
  "$LAUNCH_DAEMONS/dev.dory.network-helper.plist"
printf '#!/bin/sh\nprintf "%%s\\n" "gvproxy version v0.8.9-dory1"\n' > "$HELPERS/gvproxy"
chmod 0755 "$HELPERS/gvproxy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
PLIST

printf '%s\n' \
  'version=v0.8.9-dory1' \
  'upstream_version=v0.8.9' \
  'source_url=https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/v0.8.9.tar.gz' \
  'source_sha256=6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb' \
  'patch_sha256=ca76b2a8a304aa4b3aba835543f325832de83a14163f6b86b37491cc165e2ce3' \
  'go_toolchain=go1.26.5' \
  'go_mod_sha256=75848c190dca5cc7af27ebe017d5a4d59d4a117c97eaa6b8ac0359e58d868eec' \
  'go_sum_sha256=25b1a52ad3181030b6ccf92af5d69a1a4282f8f2342dad5348b5c954c304c4b3' \
  'go_proxy=https://proxy.golang.org' \
  'go_sumdb=sum.golang.org' \
  'go_arm64=v8.0' \
  'go_amd64=v1' \
  'fat_x86_64_segalign=0x1000' \
  'fat_arm64_segalign=0x4000' \
  'arm64_sha256=98f142909b2ba839e87bf8c4cf61e9a20f79d5c9ea1158930240d63dcaee380b' \
  'amd64_sha256=3d2d55b482e7c47033d2f956141b569c0d00861947038173a23e3b08c132c4f0' \
  'verified_sha256=bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0' \
  'features=native-ipv6-v1,source-preserving-lan-qemu-v1' \
  'architectures=x86_64 arm64' \
  'source=pinned-source-build' > "$RESOURCES/gvproxy-provenance.txt"
printf 'name=docker version=29.0.1 arch=arm64 sha256=fixture source_url=https://example.invalid\n' \
  > "$RESOURCES/host-cli-provenance.txt"
printf 'schema=2\narch=arm64\ninput_sha256=fixture\n' > "$RESOURCES/dory-kernel-build-arm64.stamp"
printf 'schema=2\narch=arm64\ninput_sha256=fixture\n' > "$RESOURCES/dory-initfs-build-arm64.stamp"
printf 'gpu-kernel\n' > "$RESOURCES/dory-hv-kernel-gpu-arm64.lzfse"
printf 'schema=2\narch=arm64\ngpu=1\ninput_sha256=fixture\n' \
  > "$RESOURCES/dory-kernel-build-arm64-gpu.stamp"
TRANSFER_HELPER_FIXTURE="$TMP/dory-transfer-helper-fixture"
python3 - "$TRANSFER_HELPER_FIXTURE" <<'PY'
import struct, sys
helper = bytearray(120)
helper[:7] = b"\x7fELF\x02\x01\x01"
struct.pack_into("<HHI", helper, 16, 2, 183, 1)
struct.pack_into("<Q", helper, 24, 0x400000)
struct.pack_into("<Q", helper, 32, 64)
struct.pack_into("<HHH", helper, 52, 64, 56, 1)
struct.pack_into("<I", helper, 64, 1)
open(sys.argv[1], "wb").write(helper)
PY
python3 scripts/build-transfer-helper-image.py \
  --helper "$TRANSFER_HELPER_FIXTURE" \
  --output "$RESOURCES/dory-transfer-helper-image-arm64.tar" \
  --metadata-output "$RESOURCES/dory-transfer-helper-image-arm64.json" >/dev/null
(
  cd "$APP"
  find Contents/Helpers Contents/Resources -type f ! -name dory-payload-sha256.txt -print \
    | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done
) > "$RESOURCES/dory-payload-sha256.txt"

artifacts=(
  "Dory-$VERSION-arm64.zip"
  "Dory-$VERSION-arm64.dmg"
  "Dory-$VERSION-lite.zip"
  "Dory-$VERSION-app-update.zip"
  "dory-engine-$VERSION-arm64.tar.gz"
  "appcast.xml"
)
for artifact in "${artifacts[@]}"; do
  printf 'fixture:%s\n' "$artifact" > "$TMP/$artifact"
done
rm -f "$TMP/dory-engine-$VERSION-arm64.tar.gz"
mkdir -p "$TMP/runtime-payload/dory-engine-$VERSION-arm64/bin"
cp "$HELPERS/dory-hv" "$TMP/runtime-payload/dory-engine-$VERSION-arm64/bin/dory-hv"
tar -czf "$TMP/dory-engine-$VERSION-arm64.tar.gz" \
  -C "$TMP/runtime-payload" "dory-engine-$VERSION-arm64"
rm "$TMP/Dory-$VERSION-app-update.zip"
mkdir -p "$TMP/update-payload"
cp -R "$APP" "$TMP/update-payload/"
(cd "$TMP/update-payload" && /usr/bin/zip -qry "$TMP/Dory-$VERSION-app-update.zip" Dory.app)
cp "$TMP/Dory-$VERSION-arm64.zip" "$TMP/Dory-$VERSION.zip"
cp "$TMP/Dory-$VERSION-arm64.dmg" "$TMP/Dory-$VERSION.dmg"
scripts/generate-release-sbom.py \
  --app "$APP" --version "$VERSION" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --output "$TMP/Dory-$VERSION.cdx.json"

python3 - "$TMP" "$VERSION" "$BUILD" <<'PY'
import base64
import hashlib
import json
import os
import sys

root, version, build = sys.argv[1:4]

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

signature = base64.b64encode(b"\0" * 64).decode()
update = os.path.join(root, f"Dory-{version}-app-update.zip")
appcast = f'''<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/Augani/dory/releases/download/v{version}/Dory-{version}-app-update.zip" sparkle:edSignature="{signature}" length="{os.path.getsize(update)}" />
</item></channel></rss>'''
with open(os.path.join(root, "appcast.xml"), "w", encoding="utf-8") as handle:
    handle.write(appcast)

names = [name for name in os.listdir(root) if name.endswith((".zip", ".dmg", ".tar.gz", ".xml", ".cdx.json"))]
records = []
for name in sorted(names):
    path = os.path.join(root, name)
    digest = sha256_file(path)
    kind = "cyclonedx-json" if name.endswith(".cdx.json") else "fixture"
    records.append({"name": name, "path": name, "kind": kind, "bytes": os.path.getsize(path), "sha256": digest})
manifest = {
    "schemaVersion": 2,
    "version": version,
    "build": build,
    "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
    "publicRelease": True,
    "bundleEngine": True,
    "notarized": True,
    "variants": "arm64",
    "artifacts": records,
}
with open(os.path.join(root, "release-manifest.json"), "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null

cp "$TMP/Dory-$VERSION.cdx.json" "$TMP/Dory-$VERSION.cdx.valid.json"
cp "$TMP/release-manifest.json" "$TMP/release-manifest.sbom-valid.json"
python3 - "$TMP" "$VERSION" <<'PY'
import hashlib
import json
import os
import sys

root, version = sys.argv[1:]
sbom_path = os.path.join(root, f"Dory-{version}.cdx.json")
with open(sbom_path, encoding="utf-8") as handle:
    sbom = json.load(handle)
sbom["components"][0]["hashes"][0]["content"] = "0" * 64
with open(sbom_path, "w", encoding="utf-8") as handle:
    json.dump(sbom, handle, sort_keys=True)
manifest_path = os.path.join(root, "release-manifest.json")
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
record = next(row for row in manifest["artifacts"] if row["name"] == f"Dory-{version}.cdx.json")
record["bytes"] = os.path.getsize(sbom_path)
record["sha256"] = hashlib.sha256(open(sbom_path, "rb").read()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: accepted a manifest-bound but false SBOM inventory" >&2
  exit 1
fi
mv "$TMP/Dory-$VERSION.cdx.valid.json" "$TMP/Dory-$VERSION.cdx.json"
mv "$TMP/release-manifest.sbom-valid.json" "$TMP/release-manifest.json"

cp "$TMP/release-manifest.json" "$TMP/release-manifest.portable.json"
python3 - "$TMP/release-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["artifacts"][0]["path"] = "/Users/release-runner/private/build/" + manifest["artifacts"][0]["name"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: public manifest accepted a runner-local artifact path" >&2
  exit 1
fi
mv "$TMP/release-manifest.portable.json" "$TMP/release-manifest.json"

cp "$TMP/release-manifest.json" "$TMP/release-manifest.unique.json"
python3 - "$TMP/release-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["artifacts"].append(dict(manifest["artifacts"][0]))
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: public manifest accepted a duplicate artifact record" >&2
  exit 1
fi
mv "$TMP/release-manifest.unique.json" "$TMP/release-manifest.json"

mkdir -p "$APP/Contents/PlugIns/DoryUITests-Runner.app"
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: public app accepted an XCTest runner" >&2
  exit 1
fi
rm -rf "$APP/Contents/PlugIns"

cp "$TMP/Dory-$VERSION-app-update.zip" "$TMP/app-update.valid.zip"
mkdir -p "$TMP/test-runner-injection/Dory.app/Contents/PlugIns/DoryUITests-Runner.app"
(cd "$TMP/test-runner-injection" && \
  /usr/bin/zip -qry "$TMP/Dory-$VERSION-app-update.zip" Dory.app)
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: Sparkle archive accepted an XCTest runner" >&2
  exit 1
fi
mv "$TMP/app-update.valid.zip" "$TMP/Dory-$VERSION-app-update.zip"

cp "$RESOURCES/gvproxy-provenance.txt" "$TMP/gvproxy-provenance.valid.txt"
cp "$RESOURCES/dory-payload-sha256.txt" "$TMP/dory-payload-sha256.valid.txt"
sed 's/^features=native-ipv6-v1,source-preserving-lan-qemu-v1$/features=ipv4-only/' \
  "$TMP/gvproxy-provenance.valid.txt" > "$RESOURCES/gvproxy-provenance.txt"
(
  cd "$APP"
  find Contents/Helpers Contents/Resources -type f ! -name dory-payload-sha256.txt -print \
    | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done
) > "$RESOURCES/dory-payload-sha256.txt"
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: IPv4-only gvproxy provenance was accepted" >&2
  exit 1
fi
mv "$TMP/gvproxy-provenance.valid.txt" "$RESOURCES/gvproxy-provenance.txt"
mv "$TMP/dory-payload-sha256.valid.txt" "$RESOURCES/dory-payload-sha256.txt"

QUALIFICATION_FIXTURE="$TMP/qualification-fixture"
mkdir -p \
  "$QUALIFICATION_FIXTURE/evidence/data-disk-growth/run" \
  "$QUALIFICATION_FIXTURE/evidence/managed-data-drive/run" \
  "$QUALIFICATION_FIXTURE/evidence/offline-bundled-boot/run" \
  "$QUALIFICATION_FIXTURE/evidence/default-platform-image/run" \
  "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run" \
  "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run" \
  "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run" \
  "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run" \
  "$QUALIFICATION_FIXTURE/evidence/ecr-registry/run" \
  "$QUALIFICATION_FIXTURE/evidence/bind-file-coherence/run" \
  "$QUALIFICATION_FIXTURE/evidence/native-ipv6/run" \
  "$QUALIFICATION_FIXTURE/evidence/gvproxy-qemu-switch" \
  "$QUALIFICATION_FIXTURE/evidence/migration/run" \
  "$QUALIFICATION_FIXTURE/evidence/competitor-runtime/run" \
  "$QUALIFICATION_FIXTURE/evidence/standalone-supervisor-recovery" \
  "$QUALIFICATION_FIXTURE/evidence/bind-advisory-lock/run" \
  "$QUALIFICATION_FIXTURE/evidence/guest-agent" \
  "$QUALIFICATION_FIXTURE/evidence/ssh-agent/run" \
  "$QUALIFICATION_FIXTURE/evidence/testcontainers/run" \
  "$QUALIFICATION_FIXTURE/evidence/devcontainers/run" \
  "$QUALIFICATION_FIXTURE/evidence/act/run" \
  "$QUALIFICATION_FIXTURE/evidence/localstack/run" \
  "$QUALIFICATION_FIXTURE/evidence/tilt/run" \
  "$QUALIFICATION_FIXTURE/evidence/supabase/run" \
  "$QUALIFICATION_FIXTURE/evidence/kubernetes-tooling/run" \
  "$QUALIFICATION_FIXTURE/evidence/long-lived/run" \
  "$QUALIFICATION_FIXTURE/evidence/endurance/run"
printf 'duration evidence\n' > "$QUALIFICATION_FIXTURE/evidence/proof.txt"
cat > "$QUALIFICATION_FIXTURE/evidence/data-disk-growth/run/summary.txt" <<'EOF'
status=PASS
seed_allocated_bytes=8589934592
grown_logical_bytes=137438953472
grown_allocated_bytes=1073741824
minimum_logical_bytes=137438953472
guest_ext4_bytes=128849018880
minimum_guest_bytes=128849018880
sparse_allocation=PASS
discard_reclaim=PASS
boot_trim_evidence=PASS
named_volume_restart_persistence=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/managed-data-drive/run/summary.txt" <<'EOF'
status=PASS
fresh_drive_default=PASS
explicit_drive_status=PASS
running_drive_mismatch_rejected=PASS
lost_drive_identity_recovered=PASS
lost_drive_identity_mismatch_rejected=PASS
alternate_drive_untouched=PASS
unwritable_drive_rejected_cleanly=PASS
missing_external_drive_rejected=PASS
concurrent_attach_rejected=PASS
alias_concurrent_attach_rejected=PASS
manifest_uuid_identity=PASS
stopped_missing_selected_drive_rejected=PASS
image_persistence=PASS
container_writable_layer_persistence=PASS
named_volume_persistence=PASS
custom_network_persistence=PASS
transient_runtime_replacement=PASS
durable_selection_survives_runtime_reset=PASS
EOF
mkdir -p "$QUALIFICATION_FIXTURE/evidence/data-drive-volume-identity/run"
cat > "$QUALIFICATION_FIXTURE/evidence/data-drive-volume-identity/run/summary.txt" <<EOF
status=PASS
architecture=arm64
external_volume_identity=PASS
durable_selection_outside_runtime_state=PASS
bookmark_volume_rename_recovery=PASS
missing_volume_shadow_prevention=PASS
same_name_wrong_volume_rejected=PASS
original_volume_reaccepted=PASS
drive_id=11111111-1111-4111-8111-111111111111
volume_uuid=22222222-2222-4222-8222-222222222222
dory_hv_sha256=$DORY_HV_SHA
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/offline-bundled-boot/run/manifest.txt" <<'EOF'
status=PASS
kernel_asset_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rootfs_asset_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
agent_asset_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
prepared_kernel_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
prepared_rootfs_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
fresh_bundled_boot=PASS
cached_boot_without_bundle_sources=PASS
dead_proxy_environment=PASS
host_tcp_dependency_absence=PASS
prepared_assets_unchanged=PASS
release_qualifying=true
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/default-platform-image/run/manifest.txt" <<'EOF'
status=PASS
docker_cli_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
image=alpine:3.22@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
registry=docker.io
expected_platform=linux/arm64
default_pull_without_platform=PASS
single_platform_local_image=PASS
default_run_architecture=PASS
image_list_system_df_reconciled=PASS
image_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
local_architecture=arm64
default_run_uname=aarch64
inspect_size_bytes=4194304
image_list_size_bytes=13421772
system_df_size_bytes=13421772
system_df_layers_size_bytes=13421772
inspect_to_storage_ratio_milli=3199
requested_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
python3 - "$QUALIFICATION_FIXTURE/evidence/default-platform-image/run" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
image_id = "sha256:" + "a" * 64
digest = "sha256:" + "b" * 64
(root / "image-inspect.json").write_text(json.dumps([{
    "Id": image_id,
    "Os": "linux",
    "Architecture": "arm64",
    "Size": 4194304,
    "RepoDigests": ["alpine@" + digest],
}]), encoding="utf-8")
(root / "images-json.json").write_text(json.dumps([{
    "Id": image_id,
    "Size": 13421772,
    "RepoDigests": ["alpine@" + digest],
}]), encoding="utf-8")
(root / "system-df.json").write_text(json.dumps({
    "LayersSize": 13421772,
    "Images": [{"Id": image_id, "Size": 13421772, "SharedSize": 0, "Containers": 0}],
}), encoding="utf-8")
(root / "default-run-uname.txt").write_text("aarch64\n", encoding="utf-8")
PY
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run/manifest.txt" <<'EOF'
status=PASS
image=nixos/nix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
platform=linux/amd64
architecture=x86_64
nix_version=2.34.7
fresh_pull=PASS
unreachable_store_path_created=PASS
nix_collect_garbage_delete_old=PASS
unreachable_store_path_deleted=PASS
docker_api_after_gc=PASS
owned_cleanup=PASS
docker_cli_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run_output_sha256=PLACEHOLDER
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run/run.out" <<'EOF'
architecture=x86_64
version=nix (Nix) 2.34.7
garbage_path=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-dory-nix-garbage
gc_deleted_unreachable_path=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run/image-inspect.json" <<'EOF'
[{"Id":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","Os":"linux","Architecture":"amd64","RepoDigests":["nixos/nix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}]
EOF
nix_output_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run/run.out" | awk '{print $1}')"
sed -i '' "s/run_output_sha256=PLACEHOLDER/run_output_sha256=$nix_output_sha/" \
  "$QUALIFICATION_FIXTURE/evidence/nonnative-nix-gc/run/manifest.txt"
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/build.out" <<'EOF'
#1 [2/2] RUN pacman -Sy --noconfirm fzf
#1 DONE
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/run.out" <<'EOF'
fzf 0.65.2-1
0.65.2 (fixture)
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/base-image-inspect.json" <<'EOF'
[{"Id":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","Os":"linux","Architecture":"amd64","RepoDigests":["archlinux@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}]
EOF
arch_build_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/build.out" | awk '{print $1}')"
arch_run_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/run.out" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-arch-pacman/run/manifest.txt" <<EOF
status=PASS
base_image=archlinux@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
platform=linux/amd64
architecture=x86_64
fresh_pull=PASS
pacman_default_sandbox=PASS
alpm_user_switch=PASS
oci_default_runtime=dory-runc
fex_handler=PASS
fex_binfmt_flags=POCF
fex_bundle_read_only=PASS
fex_sha256=b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b
fex_server_sha256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597
fzf_inventory=PASS
fzf_runtime=PASS
docker_api_after_build=PASS
owned_cleanup=PASS
docker_cli_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
build_output_sha256=$arch_build_sha
run_output_sha256=$arch_run_sha
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/build.err" <<'EOF'
#1 RUN mmdebstrap --variant=minbase trixie /tmp/rootfs.tar
#1 DONE
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/run.out" <<'EOF'
architecture=x86_64
fex_sha256=b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b
fex_server_sha256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597
rootfs_archive_readable=PASS
nested_chroot_no_proc=PASS
nested_chroot_shebang=PASS
private_marker_isolation=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/base-image-inspect.json" <<'EOF'
[{"Id":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","Os":"linux","Architecture":"amd64","RepoDigests":["debian@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"]}]
EOF
mm_build_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/build.err" | awk '{print $1}')"
mm_run_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/run.out" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-mmdebstrap/run/manifest.txt" <<EOF
status=PASS
orbstack_issue=2543
base_image=debian@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
platform=linux/amd64
architecture=x86_64
fresh_pull=PASS
reported_dockerfile_commands=PASS
mmdebstrap_minbase_trixie=PASS
bad_fd_number_absent=PASS
oci_default_runtime=dory-runc
fex_handler=PASS
fex_binfmt_flags=POCF
fex_bundle_read_only=PASS
fex_sha256=b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b
fex_server_sha256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597
rootfs_archive_readable=PASS
nested_chroot_no_proc=PASS
nested_chroot_shebang=PASS
private_marker_isolation=PASS
docker_api_after_build=PASS
build_cache_cleanup=PASS
owned_cleanup=PASS
build_log_sha256=$mm_build_sha
run_output_sha256=$mm_run_sha
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/build.err" <<'EOF'
#1 fd-exec-arguments-buildkit=PASS
#2 fd-exec-null-argv-buildkit=PASS
#3 seccomp-shebang-chain-buildkit=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/seccomp-chain.out" <<'EOF'
seccomp-shebang-chain-ok debian=13.5
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/docker-exec.out" <<'EOF'
Debian 'dpkg' package management program version 1.22.0 (amd64).
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/base-image-inspect.json" <<'EOF'
[{"Id":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","Os":"linux","Architecture":"amd64","RepoDigests":["debian@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"]}]
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/native-image-inspect.json" <<'EOF'
[{"Id":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","Os":"linux","Architecture":"arm64","RepoDigests":["alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}]
EOF
exec_build_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/build.err" | awk '{print $1}')"
exec_seccomp_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/seccomp-chain.out" | awk '{print $1}')"
exec_docker_sha="$(shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/docker-exec.out" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/nonnative-exec-conformance/run/manifest.txt" <<EOF
status=PASS
base_image=debian@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
native_image=alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
platform=linux/amd64
architecture=x86_64
fresh_pulls=PASS
oci_default_runtime=dory-runc
fex_sha256=b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b
fex_server_sha256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597
amd64_only_binfmt=PASS
fex_binfmt_flags=POCF
canonical_shebang_paths=PASS
env_shebang_chain=PASS
private_marker_isolation=PASS
guest_seccomp_inheritance=PASS
fd_exec_arguments=PASS
fd_exec_null_argv=PASS
buildkit_exec_matrix=PASS
runtime_exec_matrix=PASS
docker_exec_matrix=PASS
docker_api_after_exec=PASS
build_cache_cleanup=PASS
owned_cleanup=PASS
build_log_sha256=$exec_build_sha
seccomp_output_sha256=$exec_seccomp_sha
docker_exec_output_sha256=$exec_docker_sha
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/ecr-registry/run/manifest.txt" <<'EOF'
status=PASS
registry_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
repository_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
region=us-east-1
base_image=alpine:3.22@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
docker_cli_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
buildx_cli_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
layer_mib=96
layer_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
authenticated_login=PASS
bundled_buildx=PASS
interrupted_push_progress=PASS
interrupted_push_nonzero=PASS
resumed_blob_upload=PASS
repeated_manifest_put=PASS
repull_run_checksum=PASS
local_image_cleanup=PASS
remote_tag_cleanup=PASS
isolated_credential_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/bind-file-coherence/run/results.tsv" <<'EOF'
phase	host_inode	host_size	guest_directory_size	guest_direct_size	host_sha256	guest_directory_sha256	guest_direct_sha256
initial	1	4096	4096	4096	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
same-inode-shrink	1	7	7	7	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
same-inode-grow	1	131073	131073	131073	cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc	cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc	cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
same-inode-content	1	131073	131073	131073	dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd	dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd	dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
atomic-replacement-pinned-direct	2	40	40	131073	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
direct-rebind-after-replacement	2	40	40	40	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
guest-truncate	2	3	3	3	ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff	ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff	ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF
bind_file_results_sha="$(shasum -a 256 \
  "$QUALIFICATION_FIXTURE/evidence/bind-file-coherence/run/results.tsv" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/bind-file-coherence/run/manifest.txt" <<EOF
status=PASS
path_with_spaces=PASS
directory_bind=PASS
direct_single_file_bind=PASS
direct_single_file_recreate_cycles=20
same_inode_shrink=PASS
same_inode_grow=PASS
same_inode_content_refresh=PASS
atomic_replacement=PASS
direct_atomic_replacement_pins_inode=PASS
direct_rebind_follows_replacement=PASS
guest_to_host_truncation=PASS
image=alpine:3.22@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
docker_cli_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
results_sha256=$bind_file_results_sha
EOF
fixture_gvproxy_sha="$(shasum -a 256 "$HELPERS/gvproxy" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/native-ipv6/run/manifest.txt" <<EOF
status=PASS
architecture=arm64
gvproxy_version=v0.8.9-dory1
gvproxy_sha256=$fixture_gvproxy_sha
gvproxy_build_sha256=bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0
fresh_boot=PASS
restart=PASS
docker_bridge_ipv6=PASS
container_global_ipv6=PASS
dns_aaaa=PASS
registry_aaaa=PASS
ipv6_tcp_loopback=PASS
ipv6_localhost_publish=PASS
external_ipv6_tcp=PASS
release_qualifying=true
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/gvproxy-qemu-switch/manifest.txt" <<EOF
status=PASS
transport=qemu-unix-stream
gvproxy_sha256=$fixture_gvproxy_sha
gvproxy_build_sha256=bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0
lan_to_guest=PASS
guest_to_lan=PASS
release_qualifying=true
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/migration/run/manifest.txt" <<'EOF'
status=PASS
production_migration_path=PASS
source_baseline_restored=PASS
target_baseline_restored=PASS
image_transfer=PASS
two_named_volumes=PASS
volume_64mib_checksum=PASS
volume_metadata_symlink_hardlink=PASS
custom_network_ipam=PASS
running_paused_state=PASS
stopped_writable_layer=PASS
fixed_port_handoff=PASS
EOF
{
  printf 'test\tstatus\tdetail\n'
  for test in \
    published-port-handoff host-port-collision named-signal-delivery forwarded-connection-fds concurrent-proxy-backpressure \
    missing-source-cp restart-churn compose-port-restart network-route-conflict \
    network-alias-restart-ip standalone-engine-restart named-volume-empty named-volume named-volume-cp \
    security-opt-label seccomp-profile bind-open-create-0200 bind-mount-option-contract \
    nested-bind-subvolume bind-special-file-fail-fast bind-open-fd-stability \
    bind-hardlink-permissions healthcheck buildx-named-context buildkit-default-arg \
    image-save-stdout image-hardlink-missing-parent buildkit-large-dockerfile \
    buildkit-relative-temp-context dockerignore-layered-unignore \
    buildkit-concurrent-sessions container-resolver-contract container-dns-search \
    cleanup-restart-persistence; do
    printf '%s\tPASS\tok\n' "$test"
  done
} > "$QUALIFICATION_FIXTURE/evidence/competitor-runtime/run/results.tsv"
printf 'amd64_enabled=1\n' \
  > "$QUALIFICATION_FIXTURE/evidence/competitor-runtime/run/engine-settings.txt"
competitor_engine_settings_sha="$(
  shasum -a 256 "$QUALIFICATION_FIXTURE/evidence/competitor-runtime/run/engine-settings.txt" \
    | awk '{print $1}'
)"
cat > "$QUALIFICATION_FIXTURE/evidence/competitor-runtime/run/manifest.txt" <<EOF
source_commit=0123456789abcdef0123456789abcdef01234567
docker_bin_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
dory_engine_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
bin_dory_hv_sha256=$DORY_HV_SHA
bin_gvproxy_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
bin_dory_dataplane_proxy_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
share_dory_dory_hv_kernel_arm64_lzfse_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
share_dory_dory_engine_rootfs_ext4_lzfse_sha256=1111111111111111111111111111111111111111111111111111111111111111
share_dory_dory_agent_linux_arm64_sha256=2222222222222222222222222222222222222222222222222222222222222222
engine_settings_sha256=$competitor_engine_settings_sha
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/standalone-supervisor-recovery/manifest.txt" <<EOF
status=PASS
healthy_pidfile_repair=PASS
dead_dataplane_detected=PASS
incomplete_runtime_poweroff=PASS
fresh_helper_pair=PASS
docker_api_recovery=PASS
runtime_launcher_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dory_hv_sha256=$DORY_HV_SHA
dataplane_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
release_qualifying=true
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/bind-advisory-lock/run/manifest.txt" <<'EOF'
status=PASS
image=python:3.13-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
docker_cli_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
create_excl_readonly_mode0000_unlink=PASS
bsd_flock_exclusive_shared_unlock_upgrade_crash=PASS
posix_range_nonoverlap_blocking_unlock_crash=PASS
cross_container_bind_mount=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/guest-agent/manifest.txt" <<'EOF'
expected_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
fresh_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
restart_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
status=PASS
EOF
ssh_buildx_sha="$(shasum -a 256 "$HELPERS/docker-buildx" | awk '{print $1}')"
cat > "$QUALIFICATION_FIXTURE/evidence/ssh-agent/run/manifest.txt" <<EOF
status=PASS
guest_socket=/run/host-services/ssh-auth.sock
concurrency=8
public_key_listing_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
buildkit_required_ssh_mount=PASS
buildkit_public_key_listing_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
image=alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26
docker_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
buildx_sha256=$ssh_buildx_sha
bundled_buildx=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/testcontainers/run/manifest.txt" <<'EOF'
testcontainers=12.0.4
status=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/devcontainers/run/manifest.txt" <<'EOF'
status=PASS
devcontainers_cli=0.87.0
official_cli_invocation=PASS
host_to_container_workspace=PASS
container_to_host_workspace=PASS
container_exec=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/act/run/manifest.txt" <<'EOF'
status=PASS
act_version=0.2.89
act_archive_sha256=48ae218af96725f7635a66de2b87e1e346893b02add0f16b92f560296b2151fc
runner_image=node:20.19.5-bookworm-slim@sha256:9e70124bd00f47dd023e349cd587132ae61892acc0e47ed641416c3e18f401c3
host_socket_routing=PASS
guest_local_socket_mount=PASS
workflow_execution=PASS
host_to_runner_workspace=PASS
runner_to_host_workspace=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/localstack/run/manifest.txt" <<'EOF'
status=PASS
localstack_image=localstack/localstack:4.14.0@sha256:3ebc37595918b8accb852f8048fef2aff047d465167edd655528065b07bc364a
dynamic_localhost_port=PASS
loopback_only_listener=PASS
health_endpoint=PASS
s3_object_roundtrip=PASS
sqs_message_roundtrip=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/tilt/run/manifest.txt" <<'EOF'
status=PASS
tilt_version=0.37.5
tilt_archive_sha256=d8c701ada9d3ee29c983651a8f344d8a4c13363e6c25a843b478aa4444ee6f30
tilt_ci=PASS
docker_compose_resource=PASS
compose_health=PASS
host_to_service_workspace=PASS
service_to_host_workspace=PASS
tilt_down=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/supabase/run/manifest.txt" <<'EOF'
status=PASS
supabase_cli=2.109.1
supabase_archive_sha256=e36776717a56d704769229649349b3a382f413cb31f1fb2ba4647ef8bcf7339b
full_default_stack=PASS
guest_local_docker_socket=PASS
all_services_running=PASS
defined_healthchecks_healthy=PASS
docker_healthcheck_count=10
postgres_migration_seed_roundtrip=PASS
postgrest_roundtrip=PASS
auth_health=PASS
storage_health=PASS
loopback_only_listeners=PASS
supabase_stop_no_backup=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/kubernetes-tooling/run/manifest.txt" <<'EOF'
status=PASS
k3s_image=rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87
workload_image=nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa
k3s_node_ready=PASS
host_kubectl_api=PASS
loopback_only_api_listener=PASS
loopback_only_nodeport_listener=PASS
skaffold_version=2.23.0
skaffold_sha256=91723c608562b11cbbdd1df8596e8bb54ab4d7069184ba1e29497bba8d69047c
skaffold_run=PASS
skaffold_rollout=PASS
skaffold_nodeport_http=PASS
ingress_only_network_policy_egress=PASS
skaffold_delete=PASS
tilt_version=0.37.5
tilt_archive_sha256=d8c701ada9d3ee29c983651a8f344d8a4c13363e6c25a843b478aa4444ee6f30
tilt_kubernetes_ci=PASS
tilt_rollout=PASS
tilt_nodeport_http=PASS
tilt_down=PASS
exact_baseline_cleanup=PASS
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/long-lived/run/summary.txt" <<'EOF'
status=PASS
heartbeats=9000
actual_elapsed_seconds=90000.000
unique_connection_tuples=1
same_tcp_connection=PASS
duration_beyond_24_hours=PASS
machine_to_docker_service=PASS
machine_service_route=host.docker.internal
machine_service_regular_200_400ms_plateau=ABSENT
machine_service_samples=3000
machine_service_actual_elapsed_seconds=90000.000
machine_service_p99_ms=10
machine_service_max_ms=10
machine_service_over_100ms_samples=0
machine_service_200ms_samples=0
machine_service_max_sustained_150ms_samples=0
machine_outbound_tcp=PASS
machine_outbound_failure_budget_per_mille=5
machine_outbound_consecutive_failure_limit=2
machine_outbound_samples=3000
machine_outbound_tcp_successes=3000
machine_outbound_timeout_samples=0
machine_outbound_max_consecutive_failures=0
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/long-lived/run/manifest.txt" <<'EOF'
machine_service_host=host.docker.internal
machine_service_route=machine-container-to-published-docker-service
machine_service_p99_budget_ms=100
machine_service_sustained_budget_ms=150
machine_service_sustained_sample_limit=3
machine_outbound_host=registry-1.docker.io
machine_outbound_port=443
machine_outbound_failure_budget_per_mille=5
machine_outbound_consecutive_failure_limit=2
EOF
printf 'host.docker.internal has address 192.0.2.1\n' \
  > "$QUALIFICATION_FIXTURE/evidence/long-lived/run/machine-service-hosts.txt"
python3 - "$QUALIFICATION_FIXTURE/evidence/long-lived/run/machine-to-docker-rtt.tsv" <<'PY'
import csv
import sys

with open(sys.argv[1], "w", encoding="utf-8", newline="") as handle:
    output = csv.writer(handle, delimiter="\t")
    output.writerow(["sequence", "epoch", "elapsed_seconds", "rtt_ms", "status"])
    for sequence in range(1, 3001):
        output.writerow([sequence, sequence, f"{sequence * 30:.3f}", 10, "PASS"])
PY
python3 - "$QUALIFICATION_FIXTURE/evidence/long-lived/run/machine-outbound-tcp.tsv" <<'PY'
import csv
import sys

with open(sys.argv[1], "w", encoding="utf-8", newline="") as handle:
    output = csv.writer(handle, delimiter="\t")
    output.writerow(["sequence", "epoch", "elapsed_seconds", "rtt_ms", "remote_ipv4", "status"])
    for sequence in range(1, 3001):
        output.writerow([sequence, sequence, f"{sequence * 30:.3f}", 50, "192.0.2.10", "PASS"])
PY
cat > "$QUALIFICATION_FIXTURE/evidence/endurance/run/manifest.txt" <<'EOF'
duration_seconds=28800
fseventsd_rss_growth_mb=128
fseventsd_cpu_percent=25
release_qualifying=true
EOF
printf 'cycle\tepoch\telapsed\tstatus\tdetail\n1\t1\t1\tPASS\tok\n' \
  > "$QUALIFICATION_FIXTURE/evidence/endurance/run/cycles.tsv"
python3 - "$QUALIFICATION_FIXTURE/evidence/endurance/run/resources.tsv" <<'PY'
import csv
import sys

fields = ["phase", "cycle", "epoch", "pid_count", "fd_total", "rss_kb", "cpu_percent", "state_kb",
          "fseventsd_pid_count", "fseventsd_rss_kb", "fseventsd_cpu_percent"]
with open(sys.argv[1], "w", encoding="utf-8", newline="") as handle:
    output = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
    output.writeheader()
    for cycle in range(1, 9):
        output.writerow({
            "phase": "cleaned", "cycle": cycle, "epoch": cycle,
            "pid_count": 3, "fd_total": 60, "rss_kb": 500000,
            "cpu_percent": 0.5, "state_kb": 3000000,
            "fseventsd_pid_count": 1, "fseventsd_rss_kb": 50000,
            "fseventsd_cpu_percent": 0.2,
        })
PY
cat > "$QUALIFICATION_FIXTURE/evidence/power-assertion-manifest.txt" <<'EOF'
status=PASS
flags=-is
display_sleep_prevented=false
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/power-source.txt" <<'EOF'
Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	100%; charged; present: true
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/power-assertions.txt" <<'EOF'
pid 123(caffeinate): PreventUserIdleSystemSleep named: "caffeinate command-line tool"
pid 123(caffeinate): PreventSystemSleep named: "caffeinate command-line tool"
EOF
cat > "$QUALIFICATION_FIXTURE/evidence/power-history.tsv" <<'EOF'
checked_utc	pmset_state
2026-07-10T00:00:00Z	Now drawing from 'AC Power';battery charged
2026-07-11T01:00:00Z	Now drawing from 'AC Power';battery charged
EOF
(cd "$QUALIFICATION_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$QUALIFICATION_FIXTURE/qualification.complete.json" "$TMP" "$VERSION" "$BUILD" <<'PY'
import hashlib
import json
import os
import sys

output, build_dir, version, build = sys.argv[1:]
def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

root = os.path.dirname(output)
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "releaseQualifying": True,
    "developmentUnnotarized": False,
    "dataDiskGrowthGate": "PASS",
    "managedDataDriveGate": "PASS",
    "dataDriveVolumeIdentityGate": "PASS",
    "offlineBundledBootGate": "PASS",
    "defaultPlatformImageGate": "PASS",
    "nonnativeNixGCGate": "PASS",
    "nonnativeArchPacmanGate": "PASS",
    "nonnativeMmdebstrapGate": "PASS",
    "nonnativeExecConformanceGate": "PASS",
    "ecrRegistryRetryGate": "PASS",
    "bindFileCoherenceGate": "PASS",
    "powerAssertion": "PASS",
    "nativeIPv6Gate": "PASS",
    "gvproxyQEMUSwitchGate": "PASS",
    "migrationGate": "PASS",
    "competitorRuntimeGate": "PASS",
    "machineToDockerLongLivedGate": "PASS",
    "machineOutboundLongLivedGate": "PASS",
    "standaloneSupervisorRecoveryGate": "PASS",
    "bindAdvisoryLockGate": "PASS",
    "bindAdvisoryLockImage": "python:3.13-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "bindAdvisoryLockDockerCLI_SHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "guestAgentBootConfigGate": "PASS",
    "guestAgentSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "sshAgentForwardingGate": "PASS",
    "sshAgentImage": "alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26",
    "fixtureImage": "alpine:3.22@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "testcontainersGate": "PASS",
    "testcontainersVersion": "12.0.4",
    "devcontainersGate": "PASS",
    "devcontainersVersion": "0.87.0",
    "actGate": "PASS",
    "actVersion": "0.2.89",
    "localstackGate": "PASS",
    "localstackImage": "localstack/localstack:4.14.0@sha256:3ebc37595918b8accb852f8048fef2aff047d465167edd655528065b07bc364a",
    "tiltGate": "PASS",
    "tiltVersion": "0.37.5",
    "supabaseGate": "PASS",
    "supabaseVersion": "2.109.1",
    "kubernetesToolingGate": "PASS",
    "k3sImage": "rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87",
    "kubernetesWorkloadImage": "nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa",
    "skaffoldVersion": "2.23.0",
    "version": version,
    "build": build,
    "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
    "githubRunId": "1234",
    "githubRunAttempt": "2",
    "candidateManifestSha256": digest(os.path.join(build_dir, "release-manifest.json")),
    "appUpdateSha256": digest(os.path.join(build_dir, f"Dory-{version}-app-update.zip")),
    "runtimeSha256": digest(os.path.join(build_dir, f"dory-engine-{version}-arm64.tar.gz")),
    "evidenceManifestSha256": digest(os.path.join(root, "evidence", "evidence-sha256.txt")),
    "enduranceDurationSeconds": 28800,
    "longLivedDurationSeconds": 90000,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
universal_sha="$(shasum -a 256 "$TMP/Dory-$VERSION.zip" | awk '{print $1}')"
scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$QUALIFICATION_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null

POWER_FAILURE_FIXTURE="$TMP/qualification-power-failure"
cp -R "$QUALIFICATION_FIXTURE" "$POWER_FAILURE_FIXTURE"
python3 - "$POWER_FAILURE_FIXTURE/qualification.complete.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.pop("powerAssertion", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$POWER_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: qualification without a sleep-prevention assertion was accepted" >&2
  exit 1
fi

POWER_HISTORY_FAILURE_FIXTURE="$TMP/qualification-power-history-failure"
cp -R "$QUALIFICATION_FIXTURE" "$POWER_HISTORY_FAILURE_FIXTURE"
sed -i '' "s/Now drawing from 'AC Power'/Now drawing from 'Battery Power'/g" \
  "$POWER_HISTORY_FAILURE_FIXTURE/evidence/power-history.tsv"
(cd "$POWER_HISTORY_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$POWER_HISTORY_FAILURE_FIXTURE/qualification.complete.json" \
  "$POWER_HISTORY_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys
complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$POWER_HISTORY_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed qualification with battery-power history was accepted" >&2
  exit 1
fi

IPV6_FAILURE_FIXTURE="$TMP/qualification-ipv6-failure"
cp -R "$QUALIFICATION_FIXTURE" "$IPV6_FAILURE_FIXTURE"
sed -i '' 's/^external_ipv6_tcp=PASS$/external_ipv6_tcp=SKIP/; s/^release_qualifying=true$/release_qualifying=false/' \
  "$IPV6_FAILURE_FIXTURE/evidence/native-ipv6/run/manifest.txt"
(cd "$IPV6_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$IPV6_FAILURE_FIXTURE/qualification.complete.json" \
  "$IPV6_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$IPV6_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed native IPv6 evidence without external routing was accepted" >&2
  exit 1
fi

SEMANTIC_FAILURE_FIXTURE="$TMP/qualification-semantic-failure"
cp -R "$QUALIFICATION_FIXTURE" "$SEMANTIC_FAILURE_FIXTURE"
printf 'case\tstatus\tdetail\ncontrol\tFAIL\tinjected\n' \
  > "$SEMANTIC_FAILURE_FIXTURE/evidence/competitor-runtime/run/results.tsv"
(cd "$SEMANTIC_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$SEMANTIC_FAILURE_FIXTURE/qualification.complete.json" \
  "$SEMANTIC_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$SEMANTIC_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed failed competitor evidence was accepted" >&2
  exit 1
fi

MIGRATION_FAILURE_FIXTURE="$TMP/qualification-migration-failure"
cp -R "$QUALIFICATION_FIXTURE" "$MIGRATION_FAILURE_FIXTURE"
sed -i '' '/^stopped_writable_layer=PASS$/d' \
  "$MIGRATION_FAILURE_FIXTURE/evidence/migration/run/manifest.txt"
(cd "$MIGRATION_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$MIGRATION_FAILURE_FIXTURE/qualification.complete.json" \
  "$MIGRATION_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$MIGRATION_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed incomplete migration evidence was accepted" >&2
  exit 1
fi

DEVCONTAINERS_FAILURE_FIXTURE="$TMP/qualification-devcontainers-failure"
cp -R "$QUALIFICATION_FIXTURE" "$DEVCONTAINERS_FAILURE_FIXTURE"
sed -i '' '/^container_exec=PASS$/d' \
  "$DEVCONTAINERS_FAILURE_FIXTURE/evidence/devcontainers/run/manifest.txt"
(cd "$DEVCONTAINERS_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$DEVCONTAINERS_FAILURE_FIXTURE/qualification.complete.json" \
  "$DEVCONTAINERS_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$DEVCONTAINERS_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed incomplete Dev Containers evidence was accepted" >&2
  exit 1
fi

ACT_FAILURE_FIXTURE="$TMP/qualification-act-failure"
cp -R "$QUALIFICATION_FIXTURE" "$ACT_FAILURE_FIXTURE"
sed -i '' '/^guest_local_socket_mount=PASS$/d' \
  "$ACT_FAILURE_FIXTURE/evidence/act/run/manifest.txt"
(cd "$ACT_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$ACT_FAILURE_FIXTURE/qualification.complete.json" \
  "$ACT_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$ACT_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed incomplete act socket evidence was accepted" >&2
  exit 1
fi

LOCALSTACK_FAILURE_FIXTURE="$TMP/qualification-localstack-failure"
cp -R "$QUALIFICATION_FIXTURE" "$LOCALSTACK_FAILURE_FIXTURE"
sed -i '' '/^loopback_only_listener=PASS$/d' \
  "$LOCALSTACK_FAILURE_FIXTURE/evidence/localstack/run/manifest.txt"
(cd "$LOCALSTACK_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$LOCALSTACK_FAILURE_FIXTURE/qualification.complete.json" \
  "$LOCALSTACK_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$LOCALSTACK_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed LocalStack evidence without loopback proof was accepted" >&2
  exit 1
fi

SUPABASE_FAILURE_FIXTURE="$TMP/qualification-supabase-failure"
cp -R "$QUALIFICATION_FIXTURE" "$SUPABASE_FAILURE_FIXTURE"
sed -i '' '/^guest_local_docker_socket=PASS$/d' \
  "$SUPABASE_FAILURE_FIXTURE/evidence/supabase/run/manifest.txt"
(cd "$SUPABASE_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$SUPABASE_FAILURE_FIXTURE/qualification.complete.json" \
  "$SUPABASE_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$SUPABASE_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed Supabase evidence without guest socket proof was accepted" >&2
  exit 1
fi

KUBERNETES_FAILURE_FIXTURE="$TMP/qualification-kubernetes-tooling-failure"
cp -R "$QUALIFICATION_FIXTURE" "$KUBERNETES_FAILURE_FIXTURE"
sed -i '' '/^loopback_only_nodeport_listener=PASS$/d' \
  "$KUBERNETES_FAILURE_FIXTURE/evidence/kubernetes-tooling/run/manifest.txt"
(cd "$KUBERNETES_FAILURE_FIXTURE" && \
  find evidence -type f ! -name evidence-sha256.txt -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    > evidence/evidence-sha256.txt)
python3 - "$KUBERNETES_FAILURE_FIXTURE/qualification.complete.json" \
  "$KUBERNETES_FAILURE_FIXTURE/evidence/evidence-sha256.txt" <<'PY'
import hashlib
import json
import sys

complete, evidence_manifest = sys.argv[1:]
with open(complete, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(evidence_manifest, "rb") as handle:
    payload["evidenceManifestSha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(complete, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$KUBERNETES_FAILURE_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: rehashed Kubernetes evidence without NodePort listener proof was accepted" >&2
  exit 1
fi

printf 'tampered\n' >> "$QUALIFICATION_FIXTURE/evidence/proof.txt"
if scripts/verify-release-qualification.sh \
  --build-dir "$TMP" \
  --qualification "$QUALIFICATION_FIXTURE" \
  --version "$VERSION" \
  --build "$BUILD" \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --run-id 1234 \
  --run-attempt 2 \
  --universal-sha256 "$universal_sha" >/dev/null 2>&1; then
  echo "test-release-outputs: tampered duration evidence was accepted" >&2
  exit 1
fi

if DORY_ALLOW_SHORT_QUALIFICATION=1 DORY_ALLOW_UNNOTARIZED_QUALIFICATION=1 \
  scripts/qualify-release-candidate.sh \
    --build-dir "$TMP" \
    --version "$VERSION" \
    --build "$BUILD" \
    --source-commit fedcba9876543210fedcba9876543210fedcba98 \
    --qualification-root "$TMP/qualification-must-not-exist" \
    --long-duration 1 \
    --endurance-duration 1 \
    --min-free-gb 1 \
    --image alpine:3.22@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --lock-image python:3.13-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --ssh-client-image alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26 \
    --ecr-registry 123456789012.dkr.ecr.us-east-1.amazonaws.com \
    --ecr-repository dory-release-retry \
    --ecr-region us-east-1 \
    --confirm QUALIFY-EXACT-DORY-RELEASE \
    > "$TMP/qualification-mismatch.out" 2>&1; then
  echo "test-release-outputs: qualification accepted a different source commit" >&2
  exit 1
fi
if ! grep -q 'release manifest source commit mismatch' "$TMP/qualification-mismatch.out"; then
  cat "$TMP/qualification-mismatch.out" >&2
  echo "test-release-outputs: qualification source binding failed for the wrong reason" >&2
  exit 1
fi
[ ! -e "$TMP/qualification-must-not-exist" ] \
  || { echo "test-release-outputs: mismatched qualification mutated durable evidence" >&2; exit 1; }

cp "$TMP/release-manifest.json" "$TMP/release-manifest.valid.json"
python3 - "$TMP/release-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["sourceCommit"] = "not-a-commit"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: invalid source commit binding was accepted" >&2
  exit 1
fi
mv "$TMP/release-manifest.valid.json" "$TMP/release-manifest.json"

mv "$TMP/Dory-$VERSION-app-update.zip" "$TMP/missing-app-update.zip"
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: missing app-update ZIP was accepted" >&2
  exit 1
fi
mv "$TMP/missing-app-update.zip" "$TMP/Dory-$VERSION-app-update.zip"

printf 'tampered\n' >> "$RESOURCES/dory-kernel-build-arm64.stamp"
if DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION=1 \
  scripts/validate-release-outputs.sh "$TMP" "$VERSION" "$BUILD" >/dev/null 2>&1; then
  echo "test-release-outputs: tampered in-app payload was accepted" >&2
  exit 1
fi

grep -q 'steps.build.outputs.app_update' .github/workflows/release.yml \
  || { echo "test-release-outputs: workflow does not upload the appcast enclosure" >&2; exit 1; }
grep -q 'fail_on_unmatched_files: true' .github/workflows/release.yml \
  || { echo "test-release-outputs: GitHub release tolerates unmatched artifact paths" >&2; exit 1; }
grep -q "DORY_PUBLIC_RELEASE: '1'" .github/workflows/release.yml \
  || { echo "test-release-outputs: workflow does not enable public release policy" >&2; exit 1; }
grep -q "DORY_BUNDLE_VENUS_REQUIRED: '1'" .github/workflows/release.yml \
  || { echo "test-release-outputs: workflow does not require its advertised Venus payload" >&2; exit 1; }
grep -q 'DORY_EXPERIMENTAL_GPU=1 guest/kernel/verify-build.sh arm64' scripts/release.sh \
  || { echo "test-release-outputs: release preflight does not verify the arm64 GPU provenance" >&2; exit 1; }
if grep -R -n -E '~0%|4\.7x|122 MB|574 MB' README.md website/src; then
  echo "test-release-outputs: unqualified legacy idle-memory/CPU marketing claim returned" >&2
  exit 1
fi
mutable_actions="$(grep -R -n -E '^[[:space:]]*(-[[:space:]]*)?uses:' .github/workflows \
  | grep -E -v '@[0-9a-f]{40}' || true)"
if [ -n "$mutable_actions" ]; then
  printf '%s\n' "$mutable_actions" >&2
  echo "test-release-outputs: a workflow action is not pinned to an immutable commit" >&2
  exit 1
fi

python3 - .github/workflows/release.yml .github/workflows/pages.yml .github/workflows/tests.yml <<'PY'
import sys

release = open(sys.argv[1], encoding="utf-8").read()
pages = open(sys.argv[2], encoding="utf-8").read()
tests = open(sys.argv[3], encoding="utf-8").read()
assert "path: release-build/appcast.xml" in release, "generated appcast is not uploaded from the immutable candidate"
assert "release-build/*.cdx.json" in release, "CycloneDX SBOM is not retained with the immutable candidate"
assert "release-build/Dory-${{ needs.release_candidate.outputs.version }}.cdx.json" in release, \
    "CycloneDX SBOM is not published with the GitHub release"
release_script = open("scripts/release.sh", encoding="utf-8").read()
for required in ("scripts/generate-release-sbom.py", "scripts/verify-release-sbom.py", '"cyclonedx-json"'):
    assert required in release_script, f"release SBOM pipeline omits: {required}"
assert "publish-pages:" in release, "release has no live Pages publication job"
publish = release.split("  publish-pages:", 1)[1].split("\n  # Keeps the Homebrew", 1)[0]
assert "needs: publish_release" in publish, "live feed can deploy before GitHub Release assets exist"
assert "name: dory-appcast" in publish, "live feed does not consume the generated appcast artifact"
assert "cp appcast-artifact/appcast.xml docs-build/appcast.xml" in publish, "generated appcast is not overlaid on the complete site"
assert "uses: actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e" in publish, "generated appcast never reaches GitHub Pages"
assert "https://augani.github.io/dory/appcast.xml" in publish, "release does not verify the actual SUFeedURL"
bump = release.split("  bump-cask:", 1)[1]
assert "needs: [publish_release, publish-pages]" in bump, "cask can move before the live Sparkle feed"
assert "website/public/appcast.xml" not in bump, "cask job still relies on a commit-to-main feed update"
assert "Preserve the currently deployed Sparkle feed" in pages, "ordinary Pages deploy can overwrite the release feed"
assert "cancel-in-progress: false" in pages, "ordinary Pages deploy can cancel a release feed deployment"
assert 'minimumSystemVersion\") == "14.0"' in pages, "ordinary Pages deploy preserves an invalid live macOS floor"
assert "retaining the checked-in macOS 14 bootstrap feed" in pages, "invalid live feed cannot fall back to the repair bootstrap"
live_step = "scripts/release-candidate-live-smoke.sh release-build/export-arm64/Dory.app"
assert live_step in release, "public release never exercises the built/notarized Dory.app"
assert release.index(live_step) < release.index("name: Publish GitHub Release"), "live app test runs after publication"
assert "DORY_RELEASE_RUN_PHYSICAL_SLEEP: '1'" in release, \
    "notarized direct candidate does not run disruptive sleep/wake certification"
for variable in ("DORY_CORPORATE_DNS_SERVER", "DORY_CORPORATE_VPN_PROBE_HOST",
                 "DORY_CORPORATE_VPN_PROBE_URL"):
    assert variable in release, f"release preflight omits required corporate-network input: {variable}"
assert "dory-live-release-evidence-${{ github.sha }}-${{ github.run_attempt }}" in release, \
    "sleep/wake evidence is not commit/rerun-bound"
assert "name: Verify physical sleep/wake evidence binding" in release, \
    "publication does not semantically verify physical sleep/wake evidence"
sleep_gate = open("scripts/host-network-integrity-gate.sh", encoding="utf-8").read()
for required in ("sudo -n pmset relative wake", "sudo -n pmset sleepnow",
                 "sleep/wake Docker CLI differs from the exact candidate app",
                 "physical release qualification requires --require-vpn",
                 "required custom DNS server is absent",
                 "custom_dns_sha256=", "probe_host_sha256=", "probe_url_sha256=",
                 "source_commit=$SOURCE_COMMIT", "release_qualifying="):
    assert required in sleep_gate, f"physical sleep/wake gate lacks: {required}"
sleep_verify = open("scripts/verify-sleep-wake-evidence.py", encoding="utf-8").read()
for required in ("vpn_required", "custom_dns_required", "custom_dns_sha256",
                 "probe_host_sha256", "probe_url_sha256"):
    assert required in sleep_verify, f"sleep evidence verifier omits: {required}"
homebrew_audit = "name: Strict exact-candidate Homebrew cask audit"
assert "homebrew_cask_audit:" in release, "public release has no isolated Homebrew audit job"
assert homebrew_audit in release, "public release does not audit its exact staged Homebrew cask"
assert "runs-on: macos-15" in release, "Homebrew audit still depends on the physical release host toolchain"
assert "dory-release-candidate-${{ github.sha }}-${{ github.run_attempt }}" in release, \
    "Homebrew audit is not bound to the immutable candidate artifact"
assert "brew style \"$audit_root/Casks/dory.rb\"" in release, "staged cask skips Homebrew style"
assert "brew tap-new \"$audit_tap\"" in release, \
    "staged cask is not loaded through a supported temporary Homebrew tap"
assert "brew audit --cask --strict \"$audit_tap/dory\"" in release, \
    "staged cask skips the current name-based strict Homebrew audit"
assert "brew untap --force \"$audit_tap\"" in release, \
    "staged cask audit does not clean up its temporary tap"
assert "brew audit --cask --strict \"$audit_root/Casks/dory.rb\"" not in release, \
    "staged cask still uses Homebrew's disabled path-based audit"
assert "dory-homebrew-audit-evidence-${{ github.sha }}-${{ github.run_attempt }}" in release, \
    "Homebrew audit evidence is not retained and rerun-bound"
assert "Verify Homebrew audit evidence binding" in release, \
    "publication does not revalidate Homebrew audit evidence"
assert "source_preserving_lan_certification, homebrew_cask_audit" in release, \
    "publication can run before the isolated Homebrew audit"
assert release.index(homebrew_audit) < release.index("name: Publish GitHub Release"), \
    "Homebrew audit runs after publication"
sparkle_step = "scripts/sparkle-install-relaunch-gate.sh"
assert sparkle_step in release, "public release never exercises the real Sparkle installer"
assert 'scripts/release-candidate-live-smoke.sh "${{ steps.sparkle_candidate.outputs.app }}"' not in release, \
    "public release still substitutes a direct app launch for the Sparkle installer"
assert "UPDATE_ZIP: ${{ steps.build.outputs.app_update }}" in release, "Sparkle gate does not extract the final update ZIP"
assert "Sparkle candidate ZIP differs from release manifest" in release, "extracted Sparkle candidate is not manifest-bound"
assert "scripts/verify-sparkle-update.sh" in release, "release never verifies the Sparkle signature/key compatibility"
candidate = release.split("  release_candidate:", 1)[1].split("\n  release_qualification:", 1)[0]
for required in (
    "name: Resolve the exact release-build Sparkle source checkout",
    "DORY_RELEASE_CLEAN_USER: '1'",
    '--candidate-app "${{ steps.sparkle_candidate.outputs.app }}"',
    '--update-zip "${{ steps.build.outputs.app_update }}"',
    "--appcast release-build/appcast.xml",
    "--release-manifest release-build/release-manifest.json",
    '--sbom "release-build/Dory-${{ steps.ver.outputs.version }}.cdx.json"',
    '--sparkle-source "${{ steps.sparkle_source.outputs.path }}"',
    '--version "${{ steps.ver.outputs.version }}"',
    '--build "${{ github.run_number }}"',
    '--source-commit "$GITHUB_SHA"',
    '--signing-identity "Developer ID Application"',
    '--workroot "$RUNNER_TEMP/dory-release-live-sparkle"',
    "--confirm CLEAN-RELEASE-USER-SPARKLE-INSTALL",
):
    assert required in candidate, f"real Sparkle workflow gate omits: {required}"
sparkle_install = open("scripts/sparkle-install-relaunch-gate.sh", encoding="utf-8").read()
for required in (
    'SPARKLE_VERSION" = 2.9.4',
    'git -C "$SPARKLE_SOURCE" rev-parse HEAD',
    '-scheme sparkle-cli',
    '-onlyUsePackageVersionsFromResolvedFile',
    'python3 -m http.server',
    'GET /appcast.xml ',
    'GET /$UPDATE_NAME ',
    'NEW_PID" != "$OLD_PID',
    'verify-release-sbom.py" --sbom "$SBOM" --app "$INSTALL_APP',
    "source=Notarized Developer ID",
    'echo "update_zip_sha256=$UPDATE_ZIP_SHA"',
    'echo "release_manifest_sha256=$RELEASE_MANIFEST_SHA"',
    'echo "sbom_sha256=$SBOM_SHA"',
    'echo "gate_script_sha256=$GATE_SCRIPT_SHA"',
    "rollback_fixture_restored=PASS",
    "initial_clean_user_state_restored=PASS",
):
    assert required in sparkle_install, f"real Sparkle installer gate omits: {required}"
sparkle_verify = open("scripts/verify-sparkle-update.sh", encoding="utf-8").read()
for required in ("--verify --ed-key-file -", "SUPublicEDKey", "Curve25519.Signing.PrivateKey",
                 "Curve25519.Signing.PublicKey", "isValidSignature", "secret.count == 96"):
    assert required in sparkle_verify, f"Sparkle verification gate lacks: {required}"

release_script = open("scripts/release.sh", encoding="utf-8").read()
for required in (
    "scripts/sign-sparkle-for-distribution.sh",
    "scripts/verify-distribution-signatures.sh",
    'scripts/sign-sparkle-for-distribution.sh "$LITE_APP"',
    'sign_dmg "$dmg"',
    'verify_dmg_signature "$dmg"',
    'source=Notarized Developer ID',
):
    assert required in release_script, f"release omits nested distribution signing gate: {required}"
sparkle_signing = open("scripts/sign-sparkle-for-distribution.sh", encoding="utf-8").read()
for required in ("Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app",
                 "--preserve-metadata=entitlements", "--timestamp"):
    assert required in sparkle_signing, f"Sparkle distribution signing omits: {required}"
assert "--deep" not in "\n".join(
    line for line in sparkle_signing.splitlines() if not line.lstrip().startswith("#")
), "Sparkle distribution signer uses unsafe --deep signing"
assert "scripts/verify-clean-release-source.sh ." in release_script, \
    "public release can claim HEAD while packaging dirty source"
assert "previous-release upgrade" not in release, \
    "pre-launch Dory compatibility returned to the release workflow"
assert "release-upgrade-rollback-smoke.sh" not in release, \
    "pre-launch upgrade harness returned to the release workflow"
assert release.index(live_step) < release.index(sparkle_step) \
    < release.index("name: Publish GitHub Release"), \
    "clean direct/Sparkle candidate smokes do not run before publication"
qualification = release.split("  release_qualification:", 1)[1].split("\n  publish_release:", 1)[0]
publication = release.split("  publish_release:", 1)[1].split("\n  publish-pages:", 1)[0]
assert "name: Publish GitHub Release" not in candidate, "candidate job can publish before duration qualification"
assert "dory-release-candidate-${{ github.sha }}-${{ github.run_attempt }}" in candidate, \
    "candidate artifacts are not SHA/rerun-bound"
assert "needs: release_candidate" in qualification, "duration qualification can run without a built candidate"
assert "timeout-minutes: 1800" in qualification, "25-hour qualification cannot finish before job timeout"
assert "persist-credentials: false" in qualification, "long qualification retains an expiring Git credential"
assert "scripts/qualify-release-candidate.sh" in qualification, "release omits the duration qualification harness"
assert "QUALIFY-EXACT-DORY-RELEASE" in qualification, "duration qualification lacks its destructive-scope token"
assert "name: Select the pinned Xcode 26.6 release toolchain" in qualification, \
    "duration qualification does not select the pinned Xcode 26.6 toolchain"
assert "/Applications/Xcode-26.6.0-Release.Candidate.app" in qualification, \
    "duration qualification does not bind the approved Xcode 26.6 installation"
assert qualification.index("name: Select the pinned Xcode 26.6 release toolchain") \
    < qualification.index("scripts/qualify-release-candidate.sh"), \
    "duration qualification selects Xcode after starting the qualifier"
assert "needs: [release_candidate, release_qualification, sonoma_vz_certification, source_preserving_lan_certification, homebrew_cask_audit]" in publication, \
    "publication is not blocked on duration, Sonoma VZ, source-preservation, and Homebrew certification"
assert "permissions:\n      contents: write" in publication, "publication job lacks explicit release permission"
assert "permissions:\n  contents: read" in release, "non-publication release jobs inherit contents:write"
oidc_action = "aws-actions/configure-aws-credentials@61815dcd50bd041e203e49132bacad1fd04d2708"
assert release.count(oidc_action) == 2, \
    "release must use the pinned AWS OIDC action for preflight and exact qualification"
assert "DORY_RELEASE_AWS_ROLE_ARN: ${{ vars.DORY_RELEASE_AWS_ROLE_ARN }}" in release, \
    "release does not receive its repository-scoped AWS role"
assert release.count("id-token: write") == 3, \
    "OIDC token permission changed outside release preflight, exact qualification, or Pages"
for forbidden in ("DORY_ECR_ACCESS_KEY_ID", "DORY_ECR_SECRET_ACCESS_KEY", "DORY_ECR_SESSION_TOKEN"):
    assert forbidden not in release, f"release still accepts long-lived AWS credential secret: {forbidden}"
assert release.index("role-session-name: DoryReleasePreflight") \
    < release.index("aws sts get-caller-identity"), \
    "release preflight calls AWS before obtaining short-lived OIDC credentials"
assert release.index("role-session-name: DoryReleaseQualification") \
    < release.index("scripts/qualify-release-candidate.sh"), \
    "exact qualification starts before obtaining short-lived OIDC credentials"
assert "role-duration-seconds: 900" in release and "role-duration-seconds: 21600" in release, \
    "OIDC sessions do not bound preflight tightly or cover the pre-soak qualification gates"
assert "scripts/verify-release-qualification.sh" in publication, \
    "publication does not invoke the qualification verifier"
qualification_verify = open("scripts/verify-release-qualification.sh", encoding="utf-8").read()
qualification_run = open("scripts/qualify-release-candidate.sh", encoding="utf-8").read()
assert "candidateManifestSha256" in qualification_verify and "runtimeSha256" in qualification_verify, \
    "publication is not digest-bound to the qualified candidate"
assert "releaseQualifying" in qualification_verify, "publication accepts shortened development qualification"
assert "developmentUnnotarized" in qualification_verify, "publication accepts a notarization development escape"
assert "powerAssertion" in qualification_verify, \
    "publication accepts qualification without a continuous sleep-prevention assertion"
for required in ("/usr/bin/caffeinate -is -w $$", "Now drawing from 'AC Power'",
                 "display_sleep_prevented=false", "power-history.tsv"):
    assert required in qualification_run, f"qualification power safety lacks: {required}"
for required in (
    "DORY_LIVE_MIGRATION_EVIDENCE_DIR",
    "scripts/native-ipv6-gate.sh",
    '"nativeIPv6Gate": "PASS"',
    "scripts/live-orbstack-migration-smoke.sh",
    '"migrationGate": "PASS"',
    "scripts/bind-advisory-lock-gate.sh",
    '"bindAdvisoryLockGate": "PASS"',
    "scripts/ssh-agent-forwarding-gate.sh",
    '"sshAgentForwardingGate": "PASS"',
    '"sshAgentImage": ssh_client_image',
    "scripts/devcontainers-compatibility-gate.sh",
    '"devcontainersGate": "PASS"',
    "scripts/act-compatibility-gate.sh",
    '"actGate": "PASS"',
    "scripts/localstack-compatibility-gate.sh",
    '"localstackGate": "PASS"',
    "scripts/tilt-compose-compatibility-gate.sh",
    '"tiltGate": "PASS"',
    "scripts/supabase-compatibility-gate.sh",
    '"supabaseGate": "PASS"',
    "scripts/kubernetes-tooling-compatibility-gate.sh",
    '"kubernetesToolingGate": "PASS"',
):
    assert required in qualification_run, f"duration qualification lacks migration proof: {required}"
ssh_gate = open("scripts/ssh-agent-forwarding-gate.sh", encoding="utf-8").read()
assert "apk add" not in ssh_gate, "SSH-agent qualification installs mutable packages at runtime"
assert "@sha256:" in ssh_gate, "SSH-agent qualification does not require a digest-pinned image"
assert "--mount=type=ssh,required=true" in ssh_gate, "SSH-agent qualification omits the required BuildKit mount"
assert '--ssh "default=$SSH_AUTH_SOCK"' in ssh_gate, "BuildKit proof does not forward the exact host agent"
assert "--network=none" in ssh_gate, "BuildKit SSH identity proof unnecessarily permits network access"
for required in (
    "DORY_RELEASE_SSH_CLIENT_IMAGE: ${{ vars.DORY_RELEASE_SSH_CLIENT_IMAGE }}",
    "--ssh-client-image",
    "ssh_agent_fresh_boot",
    "ssh_agent_restart",
):
    assert required in release, f"release workflow lacks SSH-agent proof: {required}"
assert "xcodebuild -version" in qualification_run, \
    "duration qualification does not fail early without full Xcode"
assert "Gatekeeper assessments are disabled" in qualification_run \
    and "source=Notarized Developer ID" in qualification_run, \
    "duration qualification can pass without active Gatekeeper trust"
assert "GITHUB_RUN_ATTEMPT" in publication, "publication can consume evidence from a different rerun"
assert publication.index("Verify durable qualification") < publication.index("name: Publish GitHub Release"), \
    "qualification evidence is checked after publication"
assert "DORY_RELEASE_SOURCE_COMMIT: ${{ github.sha }}" in candidate, \
    "release manifest is not bound to the workflow commit"
assert "git status --porcelain --untracked-files=no" in candidate, \
    "candidate can be built from tracked changes outside the manifest commit"
assert "git merge-base --is-ancestor \"$GITHUB_SHA\" origin/main" in release, "tagged releases can publish commits outside main"
assert "HOMEBREW_TAP_DEPLOY_KEY is required" in release, "advertised Homebrew tap can silently remain stale"
assert "homebrew-dory did not converge" in release, "release never verifies the advertised tap"
tap_preflight = "name: Preflight required credentials and advertised Homebrew tap access"
assert tap_preflight in release, "Homebrew credentials are not checked before building"
assert release.index(tap_preflight) < release.index("name: Publish GitHub Release"), "Homebrew access is checked after publication"
assert "push --dry-run origin" in release and "HEAD:refs/heads/dory-release-preflight" in release, \
    "Homebrew deploy-key preflight does not prove write access"
assert "https://api.github.com/meta" in release and "StrictHostKeyChecking=yes" in release, \
    "Homebrew SSH transport does not authenticate GitHub host keys from the TLS API"
assert "x-access-token" not in release and "HOMEBREW_TAP_TOKEN" not in release, \
    "release still accepts a broad token for the Homebrew tap"
assert "secrets.SPARKLE_PRIVATE_KEY || secrets.SPARKLE_ED_PRIVATE_KEY" in release, \
    "release ignores the configured Sparkle private-key secret"

# Release credentials and contents:write make action-tag drift a supply-chain release mutation.
# Every third-party action is therefore immutable, and the nearby comment preserves readability.
import re
for workflow_name, workflow in (("release", release), ("Pages", pages)):
    uses_lines = [line for line in workflow.splitlines() if re.match(r"^\s*(?:-\s*)?uses:\s*", line)]
    assert uses_lines, f"{workflow_name} workflow contains no actions to validate"
    for line in uses_lines:
        action = re.search(r"uses:\s*([^\s#]+)", line).group(1)
        assert re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action), f"mutable {workflow_name} action ref: {action}"
        assert re.search(r"#[ \t]*\S+", line), \
            f"pinned {workflow_name} action lacks a readable version comment: {line.strip()}"

rust_job = release.split("  rust-workspace:", 1)[1].split("\n  guest-assets-arm64:", 1)[0]
for job in ("rust-workspace", "guest-assets-arm64", "prepublication-quality"):
    header = "\n".join(release.split(f"  {job}:", 1)[1].splitlines()[:8])
    assert "needs: release-configuration" in header, f"{job} can start before release credential preflight"
for required in (
    "components: rustfmt, clippy",
    "cargo fmt --all -- --check",
    "cargo clippy --workspace --all-targets --locked -- -D warnings",
    "cargo test --workspace --locked",
):
    assert required in rust_job, f"release Rust quality gate lacks: {required}"
guest_agent_job = tests.split("  guest-agent-linux:", 1)[1].split("\n  unit:", 1)[0]
for required in (
    "components: rustfmt, clippy",
    "cargo fmt --all -- --check",
    "cargo clippy --workspace --all-targets --locked -- -D warnings",
    "cargo test --workspace --locked",
):
    assert required in guest_agent_job, f"ordinary Rust CI gate lacks: {required}"

# Ignored guest/out products cannot survive checkout. The public arm64 payload is rebuilt from this
# SHA; Intel remains a separately gated roadmap job and is not downloaded into the release.
assert "guest-assets-arm64:" in release, "same-run arm64 guest build job missing"
assert "runs-on: ubuntu-24.04-arm" in release, "arm64 guest kernel is not built on native arm64 CI"
assert "name: dory-guest-arm64-${{ github.sha }}" in release, "arm64 guest artifact is not SHA-bound"
assert "retention-days: 30" in release, "guest/readiness evidence retention is too short or unspecified"
assert "Download same-commit arm64 guest payload" in release, "release never downloads the rebuilt arm64 guest"
assert "Independently verify every downloaded guest payload" in release, "downloaded guest payloads are trusted without verification"
assert "DORY_EXPERIMENTAL_GPU=1 guest/kernel/verify-build.sh arm64" in release, "downloaded GPU guest provenance is not verified"

# Intel work remains available only as an explicitly enabled roadmap track; it cannot block or add
# artifacts to the Apple-Silicon-first public release.
assert "physical-intel-quality:" in release, "release lost the later Intel roadmap gate"
intel = release.split("  physical-intel-quality:", 1)[1].split("\n  release_candidate:", 1)[0]
assert "vars.DORY_ENABLE_INTEL_ROADMAP == '1'" in intel, "Intel roadmap gate runs by default"
assert "runs-on: [self-hosted, macOS, intel, dory]" in intel, "Intel gate can run on emulation/hosted virtualization"
assert "READINESS_PHYSICAL_INTEL_CONFIRMED=1" in intel, "Intel gate never records confirmed host facts"
assert "DORY_RELEASE_LIVE_REQUIRE_PHYSICAL_INTEL: '1'" in intel, "Intel candidate skips strict physical readiness"
release_job = release.split("\n  release_candidate:", 1)[1].split("\n  release_qualification:", 1)[0]
assert "needs: [rust-workspace, prepublication-quality, guest-assets-arm64]" in release_job, \
    "Apple Silicon candidate depends on out-of-scope release jobs"
assert "DORY_RELEASE_VARIANTS: 'arm64'" in release_job, "public release is not arm64-only"
assert "Download same-commit amd64 guest payload" not in release_job, "arm64 candidate consumes Intel guest assets"
assert "runs-on: [self-hosted, macOS, arm64, dory, release]" in release_job, \
    "Apple-silicon publication can run on non-dedicated or hosted hardware"
assert "DORY_RELEASE_PHYSICAL_ARM64_CONFIRMED=1" in release_job, \
    "release never records confirmed physical Apple-silicon host facts"
assert "kern.hv_vmm_present" in release_job and "VirtualMac" in release_job, \
    "release does not reject nested/virtual Apple-silicon hosts"

live = open("scripts/release-candidate-live-smoke.sh", encoding="utf-8").read()
for required in (
    "dory.experimentalGPU -bool true",
    "dory.rosettaX86Enabled -bool true",
    "DORYD_GPU",
    "DORYD_AMD64",
    "dory-hv-kernel-gpu-arm64",
    "experimental gpu=venus: attached virtio-gpu with virglrenderer",
    "--device /dev/dri/renderD128",
    "scripts/nonnative-build-smoke.sh",
    "scripts/machine-resource-reconfiguration-gate.sh",
    "ISOLATED-DORY-MACHINE-RESOURCES",
    "scripts/external-volume-bind-gate.sh",
    "ISOLATED-EXTERNAL-APFS-BIND",
    "DORY_RELEASE_EXTERNAL_VOLUME_ROOT",
    "DORY_RELEASE_PHYSICAL_ARM64_CONFIRMED",
    "kern.hv_vmm_present",
):
    assert required in live, f"exact candidate live gate lacks: {required}"

PY

[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/Dory-Info.plist)" = \
  "https://augani.github.io/dory/appcast.xml" ] \
  || { echo "test-release-outputs: app feed URL and deployed URL diverged" >&2; exit 1; }

if (DORY_RELEASE_SOURCE_COMMIT=not-a-commit DORY_RELEASE_SOURCE_ONLY=1; \
  source scripts/release.sh "$VERSION" "$BUILD"; DORY_PUBLIC_RELEASE=1; \
  preflight_public_release) >"$TMP/source-commit.out" 2>&1; then
  echo "test-release-outputs: public release accepted an invalid source commit" >&2
  exit 1
fi
grep -q 'source commit must be a full lowercase Git SHA' "$TMP/source-commit.out" \
  || { echo "test-release-outputs: source commit policy failed for the wrong reason" >&2; exit 1; }

if (DORY_RELEASE_SOURCE_ONLY=1; source scripts/release.sh "$VERSION" "$BUILD"; \
  DORY_PUBLIC_RELEASE=1 DORY_BUNDLE_VENUS=0 DORY_BUNDLE_VENUS_REQUIRED=1 \
  preflight_public_release) >"$TMP/venus-disabled.out" 2>&1; then
  echo "test-release-outputs: public release accepted its advertised Venus payload being disabled" >&2
  exit 1
fi
grep -q 'must bundle it' "$TMP/venus-disabled.out" \
  || { echo "test-release-outputs: disabled Venus policy failed for the wrong reason" >&2; exit 1; }

if (DORY_RELEASE_SOURCE_ONLY=1; source scripts/release.sh "$VERSION" "$BUILD"; \
  DORY_PUBLIC_RELEASE=1 DORY_BUNDLE_VENUS=1 DORY_BUNDLE_VENUS_REQUIRED=0 \
  preflight_public_release) >"$TMP/venus-optional.out" 2>&1; then
  echo "test-release-outputs: public release accepted an optional advertised Venus renderer" >&2
  exit 1
fi
grep -q 'must fail when the advertised Venus renderer is unavailable' "$TMP/venus-optional.out" \
  || { echo "test-release-outputs: optional Venus policy failed for the wrong reason" >&2; exit 1; }

if DORY_PUBLIC_RELEASE=1 DORY_BUNDLE_ENGINE=0 DORY_RELEASE_PREFLIGHT_ONLY=1 \
  scripts/release.sh "$VERSION" "$BUILD" >"$TMP/public-policy.out" 2>&1; then
  echo "test-release-outputs: public app-only release was accepted" >&2
  exit 1
fi
grep -q 'public releases must bundle the engine' "$TMP/public-policy.out" \
  || { echo "test-release-outputs: public release policy did not fail for the expected reason" >&2; exit 1; }

NOTARY_BIN="$TMP/notary-bin"
mkdir -p "$NOTARY_BIN"
cat > "$NOTARY_BIN/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = notarytool ]
[ "${2:-}" = history ]
case " $* " in
  " notarytool history --keychain-profile valid-profile --output-format json ") exit 0 ;;
  " notarytool history --apple-id valid@example.com --team-id VALIDTEAM --password valid-password --output-format json ") exit 0 ;;
  *) exit 69 ;;
esac
SH
chmod 0755 "$NOTARY_BIN/xcrun"

if (
  export PATH="$NOTARY_BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  source scripts/release.sh "$VERSION" "$BUILD"
  NOTARY_PROFILE=missing-profile
  validate_notary_credentials
) >"$TMP/notary-missing.out" 2>&1; then
  echo "test-release-outputs: release preflight accepted a missing notarytool profile" >&2
  exit 1
fi
grep -q "keychain profile 'missing-profile' is unavailable or invalid" "$TMP/notary-missing.out" \
  || { echo "test-release-outputs: missing notary profile failed for the wrong reason" >&2; exit 1; }

(
  export PATH="$NOTARY_BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  source scripts/release.sh "$VERSION" "$BUILD"
  NOTARY_PROFILE=valid-profile
  validate_notary_credentials
) >"$TMP/notary-profile-valid.out" 2>&1

(
  export PATH="$NOTARY_BIN:$PATH" DORY_RELEASE_SOURCE_ONLY=1
  source scripts/release.sh "$VERSION" "$BUILD"
  NOTARY_APPLE_ID=valid@example.com
  NOTARY_TEAM_ID=VALIDTEAM
  NOTARY_PASSWORD=valid-password
  validate_notary_credentials
) >"$TMP/notary-environment-valid.out" 2>&1

sparkle_arming_args=(
  --candidate-app /not-inspected-before-arming/Dory.app
  --update-zip /not-inspected-before-arming/update.zip
  --appcast /not-inspected-before-arming/appcast.xml
  --release-manifest /not-inspected-before-arming/release-manifest.json
  --sbom /not-inspected-before-arming/sbom.json
  --sparkle-source /not-inspected-before-arming/Sparkle
  --version 1.0.0
  --build 2
  --source-commit 0123456789abcdef0123456789abcdef01234567
)
if DORY_RELEASE_CLEAN_USER=1 scripts/sparkle-install-relaunch-gate.sh \
  "${sparkle_arming_args[@]}" >"$TMP/sparkle-missing-confirm.out" 2>&1; then
  echo "test-release-outputs: live Sparkle gate accepted missing confirmation" >&2
  exit 1
fi
grep -q 'full execution requires --confirm CLEAN-RELEASE-USER-SPARKLE-INSTALL' \
  "$TMP/sparkle-missing-confirm.out" \
  || { echo "test-release-outputs: live Sparkle confirmation failed for the wrong reason" >&2; exit 1; }
if env -u DORY_RELEASE_CLEAN_USER scripts/sparkle-install-relaunch-gate.sh \
  "${sparkle_arming_args[@]}" \
  --confirm CLEAN-RELEASE-USER-SPARKLE-INSTALL \
  >"$TMP/sparkle-missing-clean-user.out" 2>&1; then
  echo "test-release-outputs: live Sparkle gate accepted a non-release account" >&2
  exit 1
fi
grep -q 'full execution requires DORY_RELEASE_CLEAN_USER=1' \
  "$TMP/sparkle-missing-clean-user.out" \
  || { echo "test-release-outputs: live Sparkle clean-user guard failed for the wrong reason" >&2; exit 1; }

bash -n scripts/release.sh scripts/bundle-engine.sh scripts/validate-release-outputs.sh \
  scripts/sign-sparkle-for-distribution.sh scripts/verify-distribution-signatures.sh \
  scripts/release-candidate-live-smoke.sh scripts/verify-sparkle-update.sh \
  scripts/sparkle-install-relaunch-gate.sh \
  scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh
echo "test-release-outputs: PASS"
