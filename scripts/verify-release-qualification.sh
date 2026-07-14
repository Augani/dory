#!/bin/bash
# Re-verify durable long-gate evidence against freshly downloaded public candidate artifacts.
set -euo pipefail

BUILD_DIR=""
QUALIFICATION=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
RUN_ID=""
RUN_ATTEMPT=""
PRIMARY_SHA256=""

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-qualification.sh [required options]

  --build-dir DIR          Freshly downloaded public candidate artifacts
  --qualification DIR      Durable qualification directory
  --version VERSION        Exact release version
  --build BUILD            Exact release build
  --source-commit SHA      Exact full Git commit
  --run-id ID              Exact workflow run ID
  --run-attempt N          Exact workflow rerun attempt
  --primary-sha256 HASH    Apple Silicon SHA advertised to Homebrew for Dory-VERSION.zip
EOF
}

die() { echo "release qualification verification: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-dir) need_value "$1" "$#"; BUILD_DIR="$2"; shift 2 ;;
    --qualification) need_value "$1" "$#"; QUALIFICATION="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --run-id) need_value "$1" "$#"; RUN_ID="$2"; shift 2 ;;
    --run-attempt) need_value "$1" "$#"; RUN_ATTEMPT="$2"; shift 2 ;;
    --primary-sha256|--universal-sha256) need_value "$1" "$#"; PRIMARY_SHA256="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for pair in \
  "build-dir:$BUILD_DIR" "qualification:$QUALIFICATION" "version:$VERSION" "build:$BUILD" \
  "source-commit:$SOURCE_COMMIT" "run-id:$RUN_ID" "run-attempt:$RUN_ATTEMPT" \
  "primary-sha256:$PRIMARY_SHA256"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
[ -d "$BUILD_DIR" ] || die "build directory is unavailable: $BUILD_DIR"
[ -d "$QUALIFICATION" ] || die "qualification directory is unavailable: $QUALIFICATION"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
QUALIFICATION="$(cd "$QUALIFICATION" && pwd)"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "source commit must be a full lowercase Git SHA"
printf '%s\n' "$PRIMARY_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "primary Apple Silicon SHA-256 is invalid"

UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-app-update.zip"
[ -s "$UPDATE_ZIP" ] || die "candidate app-update ZIP is missing"
RUNTIME_TAR="$BUILD_DIR/dory-engine-$VERSION-arm64.tar.gz"
[ -s "$RUNTIME_TAR" ] || die "candidate standalone runtime archive is missing"
DORY_HV_MEMBER="$(tar -tzf "$RUNTIME_TAR" | awk '/\/bin\/dory-hv$/ {count += 1; value=$0} END {
  if (count == 1) print value; else exit 1
}')" || die "candidate runtime archive does not contain one dory-hv"
DORY_HV_SHA256="$(tar -xOzf "$RUNTIME_TAR" "$DORY_HV_MEMBER" | shasum -a 256 | awk '{print $1}')"
CANDIDATE_GVPROXY_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Helpers/gvproxy | shasum -a 256 | awk '{print $1}')"
CANDIDATE_BUILDX_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Helpers/docker-buildx | shasum -a 256 | awk '{print $1}')"
CANDIDATE_DOCKER_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Helpers/docker | shasum -a 256 | awk '{print $1}')"
CANDIDATE_COMPOSE_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Helpers/docker-compose | shasum -a 256 | awk '{print $1}')"
CANDIDATE_GVPROXY_BUILD_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Resources/gvproxy-provenance.txt | awk -F= '
    $1 == "verified_sha256" { count += 1; value = $2 }
    END { if (count == 1) print value; else exit 1 }
  ')" || die "candidate gvproxy provenance is missing its singular build hash"
[ "$CANDIDATE_GVPROXY_BUILD_SHA" = \
    bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0 ] \
  || die "candidate gvproxy provenance has the wrong reproducible-build hash"
CANDIDATE_GVPROXY_INVENTORY_SHA="$(unzip -p "$UPDATE_ZIP" \
  Dory.app/Contents/Resources/dory-payload-sha256.txt | awk '
    $2 == "Contents/Helpers/gvproxy" { count += 1; value = $1 }
    END { if (count == 1) print value; else exit 1 }
  ')" || die "candidate payload inventory is missing its singular gvproxy hash"
[ "$CANDIDATE_GVPROXY_INVENTORY_SHA" = "$CANDIDATE_GVPROXY_SHA" ] \
  || die "candidate signed gvproxy is outside its payload inventory"

COMPLETE="$QUALIFICATION/qualification.complete.json"
EVIDENCE_MANIFEST="$QUALIFICATION/evidence/evidence-sha256.txt"
[ -s "$COMPLETE" ] || die "completion record is missing"
[ -s "$EVIDENCE_MANIFEST" ] || die "evidence digest manifest is missing"
(cd "$QUALIFICATION" && shasum -a 256 -c evidence/evidence-sha256.txt)

single_evidence_file() {
  local directory="$1" name="$2" matches count
  [ -d "$QUALIFICATION/evidence/$directory" ] \
    || die "qualification evidence directory is missing: $directory"
  matches="$(find "$QUALIFICATION/evidence/$directory" -type f -name "$name" -print)"
  count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -eq 1 ] \
    || die "expected exactly one $directory/$name evidence file, found $count"
  printf '%s\n' "$matches"
}

growth_summary="$(single_evidence_file data-disk-growth summary.txt)"
grep -qx 'status=PASS' "$growth_summary" \
  && grep -qx 'sparse_allocation=PASS' "$growth_summary" \
  && grep -qx 'discard_reclaim=PASS' "$growth_summary" \
  && grep -qx 'boot_trim_evidence=PASS' "$growth_summary" \
  && grep -qx 'named_volume_restart_persistence=PASS' "$growth_summary" \
  && grep -qx 'capacity_api=PASS' "$growth_summary" \
  && grep -qx 'running_growth_rejected=PASS' "$growth_summary" \
  && grep -qx 'forced_offline_check=PASS' "$growth_summary" \
  && grep -qx 'guest_resize_evidence=PASS' "$growth_summary" \
  && grep -qx 'explicit_capacity_growth=PASS' "$growth_summary" \
  && grep -qx 'explicit_growth_named_volume_persistence=PASS' "$growth_summary" \
  || die "retained data-disk growth evidence is not release qualifying"

drive_summary="$(single_evidence_file managed-data-drive summary.txt)"
for proof in status fresh_drive_default first_launch_resume_before_drive \
  first_launch_resume_after_drive first_launch_identity_mismatch_rejected \
  explicit_drive_status running_drive_mismatch_rejected \
  lost_drive_identity_recovered lost_drive_identity_mismatch_rejected alternate_drive_untouched \
  unwritable_drive_rejected_cleanly missing_external_drive_rejected concurrent_attach_rejected \
  alias_concurrent_attach_rejected manifest_uuid_identity image_persistence \
  stopped_missing_selected_drive_rejected \
  container_writable_layer_persistence named_volume_persistence custom_network_persistence \
  transient_runtime_replacement durable_selection_survives_runtime_reset; do
  grep -qx "$proof=PASS" "$drive_summary" \
    || die "retained managed data-drive evidence does not prove $proof"
done

volume_identity_summary="$(single_evidence_file data-drive-volume-identity summary.txt)"
for proof in status external_volume_identity durable_selection_outside_runtime_state \
  bookmark_volume_rename_recovery missing_volume_shadow_prevention \
  same_name_wrong_volume_rejected original_volume_reaccepted; do
  grep -qx "$proof=PASS" "$volume_identity_summary" \
    || die "retained data-drive volume-identity evidence does not prove $proof"
done
grep -qx "dory_hv_sha256=$DORY_HV_SHA256" "$volume_identity_summary" \
  || die "retained data-drive volume-identity evidence used the wrong dory-hv"

offline_boot_manifest="$(single_evidence_file offline-bundled-boot manifest.txt)"
for proof in status fresh_bundled_boot cached_boot_without_bundle_sources \
  dead_proxy_environment host_tcp_dependency_absence prepared_assets_unchanged; do
  grep -qx "$proof=PASS" "$offline_boot_manifest" \
    || die "retained offline bundled boot evidence does not prove $proof"
done

default_platform_manifest="$(single_evidence_file default-platform-image manifest.txt)"
default_platform_inspect="$(single_evidence_file default-platform-image image-inspect.json)"
default_platform_images="$(single_evidence_file default-platform-image images-json.json)"
default_platform_df="$(single_evidence_file default-platform-image system-df.json)"
default_platform_uname="$(single_evidence_file default-platform-image default-run-uname.txt)"
for proof in status default_pull_without_platform single_platform_local_image \
  default_run_architecture image_list_system_df_reconciled; do
  grep -qx "$proof=PASS" "$default_platform_manifest" \
    || die "retained default platform image evidence does not prove $proof"
done
grep -qx 'expected_platform=linux/arm64' "$default_platform_manifest" \
  || die "retained default image evidence does not qualify Apple Silicon"
grep -qx 'registry=docker.io' "$default_platform_manifest" \
  || die "retained default image evidence does not qualify Docker Hub manifest access"
grep -Eq '^image=.+@sha256:[0-9a-f]{64}$' "$default_platform_manifest" \
  || die "retained default image evidence is not digest-pinned"
grep -Eq '^docker_cli_sha256=[0-9a-f]{64}$' "$default_platform_manifest" \
  || die "retained default image evidence omits the Docker CLI digest"
default_inspect_size="$(sed -n 's/^inspect_size_bytes=//p' "$default_platform_manifest")"
default_list_size="$(sed -n 's/^image_list_size_bytes=//p' "$default_platform_manifest")"
default_df_size="$(sed -n 's/^system_df_size_bytes=//p' "$default_platform_manifest")"
default_size_ratio="$(sed -n 's/^inspect_to_storage_ratio_milli=//p' "$default_platform_manifest")"
[ -n "$default_inspect_size" ] && [ "$default_inspect_size" -gt 0 ] \
  && [ -n "$default_list_size" ] && [ "$default_list_size" = "$default_df_size" ] \
  && [ -n "$default_size_ratio" ] && [ "$default_size_ratio" -le 16000 ] \
  || die "retained default image storage sizes do not reconcile within Docker's definitions"
python3 - "$default_platform_manifest" "$default_platform_inspect" \
  "$default_platform_images" "$default_platform_df" "$default_platform_uname" <<'PY'
import json
import pathlib
import sys

manifest_path, inspect_path, images_path, df_path, uname_path = sys.argv[1:]
properties = {}
for raw in pathlib.Path(manifest_path).read_text(encoding="utf-8").splitlines():
    key, separator, value = raw.partition("=")
    if separator:
        properties[key] = value

inspect = json.loads(pathlib.Path(inspect_path).read_text(encoding="utf-8"))
assert isinstance(inspect, list) and len(inspect) == 1, "retained image inspect is not singular"
image = inspect[0]
assert image.get("Os") == "linux" and image.get("Architecture") == "arm64", \
    "retained default image is not linux/arm64"
image_id = image.get("Id")
inspect_size = int(image.get("Size", 0))
images = json.loads(pathlib.Path(images_path).read_text(encoding="utf-8"))
assert len(images) == 1 and images[0].get("Id") == image_id, \
    "retained fresh image list is not one selected image"
list_size = int(images[0].get("Size", 0))
system_df = json.loads(pathlib.Path(df_path).read_text(encoding="utf-8"))
df_images = system_df.get("Images") or []
assert len(df_images) == 1 and df_images[0].get("Id") == image_id, \
    "retained fresh system-df is not one selected image"
df_size = int(df_images[0].get("Size", 0))
layers_size = int(system_df.get("LayersSize", 0))
assert inspect_size > 0 and list_size == df_size, "retained image-list/system-df bytes disagree"
ratio = max(inspect_size, df_size) * 1000 // min(inspect_size, df_size)
assert ratio <= 16000, "retained inspect/storage definitions diverge by more than 16x"
assert df_size <= layers_size <= df_size * 2, \
    "retained layer bytes are not attributable to the one local image"
assert pathlib.Path(uname_path).read_text(encoding="utf-8").strip() in {"aarch64", "arm64"}, \
    "retained default run is not arm64"
assert properties.get("image_id") == image_id, "retained image ID differs from the manifest"
assert int(properties.get("inspect_size_bytes", -1)) == inspect_size
assert int(properties.get("image_list_size_bytes", -1)) == list_size
assert int(properties.get("system_df_size_bytes", -1)) == df_size
assert int(properties.get("system_df_layers_size_bytes", -1)) == layers_size
assert int(properties.get("inspect_to_storage_ratio_milli", -1)) == ratio
PY

prune_manifest="$(single_evidence_file prune-safety manifest.txt)"
prune_system_df="$(single_evidence_file prune-safety system-df-after.json)"
for proof in status empty_engine_precondition unfiltered_system_prune \
  unfiltered_container_prune unfiltered_image_prune unfiltered_network_prune \
  unfiltered_volume_prune unfiltered_builder_prune active_container_survived \
  active_image_survived active_volume_survived active_network_survived \
  active_volume_bytes_preserved unused_container_removed unused_image_removed \
  unused_volume_removed unused_network_removed build_cache_removed owned_cleanup; do
  grep -qx "$proof=PASS" "$prune_manifest" \
    || die "retained prune-safety evidence does not prove $proof"
done
grep -Fx "source_commit=$SOURCE_COMMIT" "$prune_manifest" >/dev/null \
  || die "retained prune-safety evidence belongs to another source commit"
prune_base_image="$(sed -n 's/^base_image=//p' "$prune_manifest")"
printf '%s\n' "$prune_base_image" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "retained prune-safety fixture is not digest-pinned"
grep -qx "docker_cli_sha256=$CANDIDATE_DOCKER_SHA" "$prune_manifest" \
  || die "retained prune-safety evidence used a different Docker client"
for output in system-prune.txt container-prune.txt image-prune.txt network-prune.txt \
  volume-prune.txt builder-prune.txt; do
  single_evidence_file prune-safety "$output" >/dev/null
done
python3 - "$prune_system_df" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert not (report.get("BuildCache") or []), "retained prune evidence contains build cache"
PY

private_registry_manifest="$(single_evidence_file private-registry-auth manifest.txt)"
private_registry_archive="$(single_evidence_file private-registry-auth built-image.tar)"
private_registry_archive_list="$(single_evidence_file \
  private-registry-auth built-image-tar-list.txt)"
private_registry_inspect="$(single_evidence_file \
  private-registry-auth registry-image-inspect.json)"
for proof in status registry_fixture_arm64 unauthenticated_pull_rejected authenticated_login \
  authenticated_pull_run buildkit_registry_auth buildkit_secret_nonleak \
  buildkit_registry_cache_export buildkit_registry_cache_import registry_push \
  image_inspect_history image_save_load_identity image_tag_remove filtered_image_prune \
  owned_cleanup isolated_credential_cleanup; do
  grep -qx "$proof=PASS" "$private_registry_manifest" \
    || die "retained private-registry evidence does not prove $proof"
done
grep -Fx "source_commit=$SOURCE_COMMIT" "$private_registry_manifest" >/dev/null \
  || die "retained private-registry evidence belongs to another source commit"
private_registry_base_image="$(sed -n 's/^base_image=//p' "$private_registry_manifest")"
private_registry_image="$(sed -n 's/^registry_image=//p' "$private_registry_manifest")"
printf '%s\n' "$private_registry_base_image" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  && printf '%s\n' "$private_registry_image" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "retained private-registry image fixtures are not digest-pinned"
[ "$prune_base_image" = "$private_registry_base_image" ] \
  || die "prune and private-registry gates used different base images"
grep -qx "docker_cli_sha256=$CANDIDATE_DOCKER_SHA" "$private_registry_manifest" \
  && grep -qx "buildx_cli_sha256=$CANDIDATE_BUILDX_SHA" "$private_registry_manifest" \
  || die "retained private-registry evidence used different candidate clients"
private_registry_archive_sha="$(shasum -a 256 "$private_registry_archive" | awk '{print $1}')"
grep -qx "archive_sha256=$private_registry_archive_sha" "$private_registry_manifest" \
  || die "retained private-registry image archive digest is wrong"
grep -qx 'manifest.json' "$private_registry_archive_list" \
  || die "retained private-registry image archive has no manifest.json"
tar -tf "$private_registry_archive" | cmp -s - "$private_registry_archive_list" \
  || die "retained private-registry archive listing differs from the archive"
private_registry_id_before="$(sed -n 's/^image_id_before=//p' "$private_registry_manifest")"
private_registry_id_after="$(sed -n 's/^image_id_after=//p' "$private_registry_manifest")"
printf '%s\n' "$private_registry_id_before" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  && [ "$private_registry_id_before" = "$private_registry_id_after" ] \
  || die "retained private-registry save/load image identity differs"
if find "$(dirname "$(dirname "$private_registry_manifest")")" -type d \
    \( -name docker-config -o -name unauth-config -o -name auth \) -print -quit \
    | grep -q .; then
  die "retained private-registry evidence still contains credential directories"
fi
python3 - "$private_registry_inspect" "$private_registry_image" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "registry image inspect is not singular"
image = payload[0]
assert image.get("Os") == "linux" and image.get("Architecture") == "arm64", \
    "registry fixture is not linux/arm64"
digest = sys.argv[2].rsplit("@", 1)[1]
assert any(value.endswith("@" + digest) for value in image.get("RepoDigests") or []), \
    "registry fixture inspect does not contain the qualified digest"
PY

nonnative_nix_manifest="$(single_evidence_file nonnative-nix-gc manifest.txt)"
nonnative_nix_output="$(single_evidence_file nonnative-nix-gc run.out)"
nonnative_nix_inspect="$(single_evidence_file nonnative-nix-gc image-inspect.json)"
for proof in status fresh_pull unreachable_store_path_created nix_collect_garbage_delete_old \
  unreachable_store_path_deleted docker_api_after_gc owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_nix_manifest" \
    || die "retained non-native Nix GC evidence does not prove $proof"
done
grep -Eq '^image=.+@sha256:[0-9a-f]{64}$' "$nonnative_nix_manifest" \
  && grep -qx 'platform=linux/amd64' "$nonnative_nix_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_nix_manifest" \
  && grep -qx 'nix_version=2.34.7' "$nonnative_nix_manifest" \
  && grep -Eq '^docker_cli_sha256=[0-9a-f]{64}$' "$nonnative_nix_manifest" \
  && grep -Eq '^run_output_sha256=[0-9a-f]{64}$' "$nonnative_nix_manifest" \
  || die "retained non-native Nix GC evidence omits exact provenance"
expected_nix_output_sha="$(sed -n 's/^run_output_sha256=//p' "$nonnative_nix_manifest")"
[ "$expected_nix_output_sha" = "$(shasum -a 256 "$nonnative_nix_output" | awk '{print $1}')" ] \
  || die "retained non-native Nix GC output digest does not match"
grep -qx 'architecture=x86_64' "$nonnative_nix_output" \
  && grep -qx 'version=nix (Nix) 2.34.7' "$nonnative_nix_output" \
  && grep -Eq '^garbage_path=/nix/store/[a-z0-9]{32}-dory-nix-garbage$' "$nonnative_nix_output" \
  && grep -qx 'gc_deleted_unreachable_path=PASS' "$nonnative_nix_output" \
  || die "retained non-native Nix GC raw output is incomplete"
python3 - "$nonnative_nix_manifest" "$nonnative_nix_inspect" <<'PY'
import json
import pathlib
import sys

manifest, inspect_path = map(pathlib.Path, sys.argv[1:])
properties = dict(
    line.split("=", 1)
    for line in manifest.read_text(encoding="utf-8").splitlines()
    if "=" in line
)
digest = properties["image"].rsplit("@", 1)[1]
payload = json.loads(inspect_path.read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "retained Nix image inspect is not singular"
image = payload[0]
assert image.get("Os") == "linux" and image.get("Architecture") == "amd64", \
    "retained Nix image is not linux/amd64"
assert any(value.endswith("@" + digest) for value in image.get("RepoDigests") or []), \
    "retained Nix image digest differs from the manifest"
PY

nonnative_arch_manifest="$(single_evidence_file nonnative-arch-pacman manifest.txt)"
nonnative_arch_build="$(single_evidence_file nonnative-arch-pacman build.out)"
nonnative_arch_run="$(single_evidence_file nonnative-arch-pacman run.out)"
nonnative_arch_inspect="$(single_evidence_file nonnative-arch-pacman base-image-inspect.json)"
for proof in status fresh_pull pacman_default_sandbox alpm_user_switch fex_handler \
  fex_bundle_read_only fzf_inventory fzf_runtime docker_api_after_build owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_arch_manifest" \
    || die "retained non-native Arch pacman evidence does not prove $proof"
done
grep -qx 'oci_default_runtime=dory-runc' "$nonnative_arch_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_arch_manifest" \
  && grep -Eq '^fex_sha256=[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  && grep -Eq '^fex_server_sha256=[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  || die "retained non-native Arch pacman evidence omits the FEX runtime contract"
fex_pair="$(sed -n 's/^fex_sha256=//p' "$nonnative_arch_manifest"):$(sed -n 's/^fex_server_sha256=//p' "$nonnative_arch_manifest")"
case "$fex_pair" in
  b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b:bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597) ;;
  *) die "retained non-native Arch pacman evidence has an unverified FEX binary pair" ;;
esac
grep -Eq '^base_image=.+@sha256:[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  && grep -qx 'platform=linux/amd64' "$nonnative_arch_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_arch_manifest" \
  && grep -Eq '^docker_cli_sha256=[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  || die "retained non-native Arch pacman evidence omits exact provenance"
expected_arch_build_sha="$(sed -n 's/^build_output_sha256=//p' "$nonnative_arch_manifest")"
expected_arch_run_sha="$(sed -n 's/^run_output_sha256=//p' "$nonnative_arch_manifest")"
[ "$expected_arch_build_sha" = "$(shasum -a 256 "$nonnative_arch_build" | awk '{print $1}')" ] \
  && [ "$expected_arch_run_sha" = "$(shasum -a 256 "$nonnative_arch_run" | awk '{print $1}')" ] \
  || die "retained non-native Arch pacman output digest does not match"
grep -Fq 'pacman -Sy --noconfirm fzf' "$nonnative_arch_build" \
  || die "retained Arch build did not run the competitor's exact pacman command"
if grep -Fq -- '--disable-sandbox' "$nonnative_arch_build"; then
  die "retained Arch build disabled pacman's sandbox"
fi
grep -Eq '^fzf [0-9]' "$nonnative_arch_run" \
  && grep -Eq '^[0-9]+[.][0-9]+' "$nonnative_arch_run" \
  || die "retained Arch pacman package did not execute"
python3 - "$nonnative_arch_manifest" "$nonnative_arch_inspect" <<'PY'
import json
import pathlib
import sys

manifest, inspect_path = map(pathlib.Path, sys.argv[1:])
properties = dict(
    line.split("=", 1)
    for line in manifest.read_text(encoding="utf-8").splitlines()
    if "=" in line
)
digest = properties["base_image"].rsplit("@", 1)[1]
payload = json.loads(inspect_path.read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "retained Arch inspect is not singular"
image = payload[0]
assert image.get("Os") == "linux" and image.get("Architecture") == "amd64", \
    "retained Arch image is not linux/amd64"
assert any(value.endswith("@" + digest) for value in image.get("RepoDigests") or []), \
    "retained Arch digest differs from the manifest"
PY

nonnative_mm_manifest="$(single_evidence_file nonnative-mmdebstrap manifest.txt)"
nonnative_mm_build="$(single_evidence_file nonnative-mmdebstrap build.err)"
nonnative_mm_run="$(single_evidence_file nonnative-mmdebstrap run.out)"
nonnative_mm_inspect="$(single_evidence_file nonnative-mmdebstrap base-image-inspect.json)"
for proof in status fresh_pull reported_dockerfile_commands mmdebstrap_minbase_trixie \
  bad_fd_number_absent fex_handler fex_bundle_read_only rootfs_archive_readable \
  nested_chroot_no_proc nested_chroot_shebang private_marker_isolation \
  docker_api_after_build build_cache_cleanup owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_mm_manifest" \
    || die "retained non-native mmdebstrap evidence does not prove $proof"
done
grep -qx 'orbstack_issue=2543' "$nonnative_mm_manifest" \
  && grep -qx 'platform=linux/amd64' "$nonnative_mm_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_mm_manifest" \
  && grep -qx 'oci_default_runtime=dory-runc' "$nonnative_mm_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_mm_manifest" \
  || die "retained non-native mmdebstrap evidence omits exact provenance"
mm_fex_pair="$(sed -n 's/^fex_sha256=//p' "$nonnative_mm_manifest"):$(sed -n 's/^fex_server_sha256=//p' "$nonnative_mm_manifest")"
case "$mm_fex_pair" in
  b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b:bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597) ;;
  *) die "retained non-native mmdebstrap evidence has an unverified FEX binary pair" ;;
esac
expected_mm_build_sha="$(sed -n 's/^build_log_sha256=//p' "$nonnative_mm_manifest")"
expected_mm_run_sha="$(sed -n 's/^run_output_sha256=//p' "$nonnative_mm_manifest")"
[ "$expected_mm_build_sha" = "$(shasum -a 256 "$nonnative_mm_build" | awk '{print $1}')" ] \
  && [ "$expected_mm_run_sha" = "$(shasum -a 256 "$nonnative_mm_run" | awk '{print $1}')" ] \
  || die "retained non-native mmdebstrap output digest does not match"
grep -Fq 'mmdebstrap --variant=minbase trixie /tmp/rootfs.tar' "$nonnative_mm_build" \
  && grep -qx 'nested_chroot_no_proc=PASS' "$nonnative_mm_run" \
  && grep -qx 'nested_chroot_shebang=PASS' "$nonnative_mm_run" \
  && grep -qx 'private_marker_isolation=PASS' "$nonnative_mm_run" \
  || die "retained non-native mmdebstrap raw evidence is incomplete"
python3 - "$nonnative_mm_manifest" "$nonnative_mm_inspect" <<'PY'
import json
import pathlib
import sys

manifest, inspect_path = map(pathlib.Path, sys.argv[1:])
properties = dict(line.split("=", 1) for line in manifest.read_text().splitlines() if "=" in line)
digest = properties["base_image"].rsplit("@", 1)[1]
payload = json.loads(inspect_path.read_text())
assert isinstance(payload, list) and len(payload) == 1
image = payload[0]
assert image.get("Os") == "linux" and image.get("Architecture") == "amd64"
assert any(value.endswith("@" + digest) for value in image.get("RepoDigests") or [])
PY

nonnative_exec_manifest="$(single_evidence_file nonnative-exec-conformance manifest.txt)"
nonnative_exec_build="$(single_evidence_file nonnative-exec-conformance build.err)"
nonnative_exec_seccomp="$(single_evidence_file nonnative-exec-conformance seccomp-chain.out)"
nonnative_exec_docker_exec="$(single_evidence_file nonnative-exec-conformance docker-exec.out)"
nonnative_exec_base_inspect="$(single_evidence_file nonnative-exec-conformance base-image-inspect.json)"
nonnative_exec_native_inspect="$(single_evidence_file nonnative-exec-conformance native-image-inspect.json)"
for proof in status fresh_pulls amd64_only_binfmt canonical_shebang_paths env_shebang_chain \
  private_marker_isolation guest_seccomp_inheritance fd_exec_arguments fd_exec_null_argv \
  buildkit_exec_matrix runtime_exec_matrix docker_exec_matrix docker_api_after_exec \
  build_cache_cleanup owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_exec_manifest" \
    || die "retained non-native exec evidence does not prove $proof"
done
grep -qx 'platform=linux/amd64' "$nonnative_exec_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_exec_manifest" \
  && grep -qx 'oci_default_runtime=dory-runc' "$nonnative_exec_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_exec_manifest" \
  || die "retained non-native exec evidence omits exact provenance"
exec_fex_pair="$(sed -n 's/^fex_sha256=//p' "$nonnative_exec_manifest"):$(sed -n 's/^fex_server_sha256=//p' "$nonnative_exec_manifest")"
case "$exec_fex_pair" in
  b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b:bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597) ;;
  *) die "retained non-native exec evidence has an unverified FEX binary pair" ;;
esac
for evidence in \
  "build_log_sha256:$nonnative_exec_build" \
  "seccomp_output_sha256:$nonnative_exec_seccomp" \
  "docker_exec_output_sha256:$nonnative_exec_docker_exec"; do
  key="${evidence%%:*}"
  path="${evidence#*:}"
  expected="$(sed -n "s/^${key}=//p" "$nonnative_exec_manifest")"
  [ "$expected" = "$(shasum -a 256 "$path" | awk '{print $1}')" ] \
    || die "retained non-native exec digest does not match for $key"
done
for proof in fd-exec-arguments-buildkit fd-exec-null-argv-buildkit \
  seccomp-shebang-chain-buildkit; do
  grep -q "$proof=PASS" "$nonnative_exec_build" \
    || die "retained BuildKit exec evidence omits $proof"
done
grep -q '^seccomp-shebang-chain-ok ' "$nonnative_exec_seccomp" \
  && grep -q '^Debian .dpkg. package management program version' "$nonnative_exec_docker_exec" \
  || die "retained runtime/docker exec output is incomplete"
python3 - "$nonnative_exec_manifest" "$nonnative_exec_base_inspect" \
  "$nonnative_exec_native_inspect" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
properties = dict(line.split("=", 1) for line in manifest.read_text().splitlines() if "=" in line)
for key, path, architecture in (
    ("base_image", sys.argv[2], "amd64"),
    ("native_image", sys.argv[3], "arm64"),
):
    digest = properties[key].rsplit("@", 1)[1]
    payload = json.loads(pathlib.Path(path).read_text())
    assert isinstance(payload, list) and len(payload) == 1
    image = payload[0]
    assert image.get("Os") == "linux" and image.get("Architecture") == architecture
    assert any(value.endswith("@" + digest) for value in image.get("RepoDigests") or [])
PY

ecr_manifest="$(single_evidence_file ecr-registry manifest.txt)"
for proof in status authenticated_login bundled_buildx interrupted_push_progress \
  interrupted_push_nonzero resumed_blob_upload \
  repeated_manifest_put repull_run_checksum local_image_cleanup remote_tag_cleanup \
  isolated_credential_cleanup; do
  grep -qx "$proof=PASS" "$ecr_manifest" \
    || die "retained managed ECR evidence does not prove $proof"
done
grep -Eq '^registry_sha256=[0-9a-f]{64}$' "$ecr_manifest" \
  && grep -Eq '^repository_sha256=[0-9a-f]{64}$' "$ecr_manifest" \
  && grep -Eq '^layer_sha256=[0-9a-f]{64}$' "$ecr_manifest" \
  && grep -Eq '^docker_cli_sha256=[0-9a-f]{64}$' "$ecr_manifest" \
  && grep -Eq '^buildx_cli_sha256=[0-9a-f]{64}$' "$ecr_manifest" \
  || die "retained managed ECR evidence omits provenance digests"
ecr_layer_mib="$(sed -n 's/^layer_mib=//p' "$ecr_manifest")"
[ -n "$ecr_layer_mib" ] && [ "$ecr_layer_mib" -ge 64 ] \
  || die "retained managed ECR retry layer is below 64 MiB"
grep -qx 'release_qualifying=true' "$offline_boot_manifest" \
  || die "retained offline bundled boot evidence is not release qualifying"
for asset in kernel_asset rootfs_asset agent_asset prepared_kernel prepared_rootfs; do
  grep -Eq "^${asset}_sha256=[0-9a-f]{64}$" "$offline_boot_manifest" \
    || die "retained offline bundled boot evidence omits ${asset} digest"
done

bind_file_manifest="$(single_evidence_file bind-file-coherence manifest.txt)"
bind_file_results="$(single_evidence_file bind-file-coherence results.tsv)"
for proof in status path_with_spaces directory_bind direct_single_file_bind \
  same_inode_shrink same_inode_grow same_inode_content_refresh atomic_replacement \
  direct_atomic_replacement_pins_inode direct_rebind_follows_replacement \
  guest_to_host_truncation; do
  grep -qx "$proof=PASS" "$bind_file_manifest" \
    || die "retained bind-file coherence evidence does not prove $proof"
done
grep -qx 'direct_single_file_recreate_cycles=20' "$bind_file_manifest" \
  || die "retained bind-file coherence evidence omitted 20 direct attachment cycles"
grep -Eq '^image=.+@sha256:[0-9a-f]{64}$' "$bind_file_manifest" \
  || die "retained bind-file coherence image is not digest-pinned"
grep -Eq '^docker_cli_sha256=[0-9a-f]{64}$' "$bind_file_manifest" \
  || die "retained bind-file coherence Docker CLI digest is invalid"
expected_bind_results_sha="$(awk -F= '$1 == "results_sha256" {print $2; exit}' "$bind_file_manifest")"
[ "$expected_bind_results_sha" = "$(shasum -a 256 "$bind_file_results" | awk '{print $1}')" ] \
  || die "retained bind-file coherence result digest does not match"
python3 - "$bind_file_results" <<'PY'
import csv
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open(newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
expected = [
    "initial",
    "same-inode-shrink",
    "same-inode-grow",
    "same-inode-content",
    "atomic-replacement-pinned-direct",
    "direct-rebind-after-replacement",
    "guest-truncate",
]
assert [row["phase"] for row in rows] == expected, "unexpected bind coherence phases"
for index, row in enumerate(rows):
    assert row["host_size"] == row["guest_directory_size"], \
        f"directory size divergence in {row['phase']}"
    assert row["host_sha256"] == row["guest_directory_sha256"], \
        f"directory content divergence in {row['phase']}"
    if row["phase"] == "atomic-replacement-pinned-direct":
        previous = rows[index - 1]
        assert row["guest_direct_size"] == previous["guest_direct_size"], \
            "direct bind did not retain the pre-replacement inode size"
        assert row["guest_direct_sha256"] == previous["guest_direct_sha256"], \
            "direct bind did not retain the pre-replacement inode content"
        assert row["guest_direct_sha256"] != row["host_sha256"], \
            "atomic replacement fixture did not distinguish direct and directory views"
    else:
        assert row["host_size"] == row["guest_direct_size"], \
            f"direct size divergence in {row['phase']}"
        assert row["host_sha256"] == row["guest_direct_sha256"], \
            f"direct content divergence in {row['phase']}"
PY

native_ipv6_manifest="$(single_evidence_file native-ipv6 manifest.txt)"
for proof in \
  status fresh_boot restart docker_bridge_ipv6 container_global_ipv6 dns_aaaa registry_aaaa \
  ipv6_tcp_loopback ipv6_localhost_publish external_ipv6_tcp; do
  grep -qx "$proof=PASS" "$native_ipv6_manifest" \
    || die "retained native IPv6 evidence does not prove $proof"
done
grep -qx 'architecture=arm64' "$native_ipv6_manifest" \
  || die "retained native IPv6 evidence is not from Apple Silicon"
grep -qx 'gvproxy_version=v0.8.9-dory1' "$native_ipv6_manifest" \
  || die "retained native IPv6 evidence used the wrong gvproxy derivative"
grep -qx "gvproxy_sha256=$CANDIDATE_GVPROXY_SHA" \
  "$native_ipv6_manifest" \
  || die "retained native IPv6 evidence used the wrong gvproxy binary"
grep -qx "gvproxy_build_sha256=$CANDIDATE_GVPROXY_BUILD_SHA" \
  "$native_ipv6_manifest" \
  || die "retained native IPv6 evidence used the wrong reproducible gvproxy build"
grep -qx 'release_qualifying=true' "$native_ipv6_manifest" \
  || die "retained native IPv6 evidence skipped real external IPv6 routing"

qemu_switch_manifest="$(single_evidence_file gvproxy-qemu-switch manifest.txt)"
for proof in lan_to_guest guest_to_lan; do
  grep -qx "$proof=PASS" "$qemu_switch_manifest" \
    || die "retained gvproxy QEMU switch evidence does not prove $proof"
done
grep -qx 'transport=qemu-unix-stream' "$qemu_switch_manifest" \
  || die "retained LAN switch evidence used the wrong transport"
grep -qx "gvproxy_sha256=$CANDIDATE_GVPROXY_SHA" \
  "$qemu_switch_manifest" \
  || die "retained LAN switch evidence used the wrong gvproxy binary"
grep -qx "gvproxy_build_sha256=$CANDIDATE_GVPROXY_BUILD_SHA" \
  "$qemu_switch_manifest" \
  || die "retained LAN switch evidence used the wrong reproducible gvproxy build"
grep -qx 'release_qualifying=true' "$qemu_switch_manifest" \
  || die "retained LAN switch evidence is not release qualifying"

migration_manifest="$(single_evidence_file migration manifest.txt)"
for proof in \
  status production_migration_path source_baseline_restored target_baseline_restored \
  image_transfer two_named_volumes volume_64mib_checksum volume_metadata_symlink_hardlink \
  custom_network_ipam running_paused_state stopped_writable_layer fixed_port_handoff; do
  grep -qx "$proof=PASS" "$migration_manifest" \
    || die "retained migration evidence does not prove $proof"
done

competitor_results="$(single_evidence_file competitor-runtime results.tsv)"
competitor_manifest="$(single_evidence_file competitor-runtime manifest.txt)"
[ "$(wc -l < "$competitor_results" | tr -d ' ')" -gt 1 ] \
  || die "retained competitor runtime evidence has no result rows"
grep -qx "source_commit=$SOURCE_COMMIT" "$competitor_manifest" \
  || die "retained competitor runtime evidence used the wrong source commit"
for digest_key in docker_bin_sha256 compose_bin_sha256 buildx_bin_sha256 \
  dory_engine_sha256 bin_dory_hv_sha256 \
  bin_gvproxy_sha256 bin_dory_dataplane_proxy_sha256 \
  share_dory_dory_hv_kernel_arm64_lzfse_sha256 \
  share_dory_dory_engine_rootfs_ext4_lzfse_sha256 \
  share_dory_dory_agent_linux_arm64_sha256 engine_settings_sha256; do
  grep -Eq "^${digest_key}=[0-9a-f]{64}$" "$competitor_manifest" \
    || die "retained competitor runtime evidence omits $digest_key"
done
grep -qx "bin_dory_hv_sha256=$DORY_HV_SHA256" "$competitor_manifest" \
  || die "retained competitor runtime evidence used the wrong dory-hv"
competitor_settings="$(single_evidence_file competitor-runtime engine-settings.txt)"
grep -qx 'amd64_enabled=1' "$competitor_settings" \
  || die "retained competitor runtime restart lost Apple Silicon amd64/FEX mode"
[ "$(shasum -a 256 "$competitor_settings" | awk '{print $1}')" = \
  "$(sed -n 's/^engine_settings_sha256=//p' "$competitor_manifest")" ] \
  || die "retained competitor engine settings do not match their digest"
competitor_docker_sha256="$(sed -n 's/^docker_bin_sha256=//p' "$competitor_manifest")"
competitor_compose_sha256="$(sed -n 's/^compose_bin_sha256=//p' "$competitor_manifest")"
competitor_buildx_sha256="$(sed -n 's/^buildx_bin_sha256=//p' "$competitor_manifest")"
[ "$competitor_compose_sha256" = "$CANDIDATE_COMPOSE_SHA" ] \
  || die "retained competitor evidence used the wrong Compose v2 helper"
[ "$competitor_buildx_sha256" = "$CANDIDATE_BUILDX_SHA" ] \
  || die "retained competitor evidence used the wrong Buildx helper"
grep -q $'\tFAIL\t' "$competitor_results" \
  && die "retained competitor runtime evidence contains a failed row"
for proof in \
  published-port-handoff host-port-collision named-signal-delivery forwarded-connection-fds concurrent-proxy-backpressure \
  missing-source-cp restart-churn compose-port-restart compose-v2-lifecycle \
  network-route-conflict network-api-lifecycle \
  network-alias-restart-ip standalone-engine-restart named-volume-empty named-volume named-volume-cp volume-api-lifecycle \
  security-opt-label seccomp-profile bind-open-create-0200 bind-mount-option-contract \
  nested-bind-subvolume bind-special-file-fail-fast bind-open-fd-stability \
  bind-hardlink-permissions healthcheck buildx-named-context buildkit-default-arg \
  image-save-stdout image-hardlink-missing-parent buildkit-large-dockerfile \
  buildkit-relative-temp-context dockerignore-layered-unignore \
  buildkit-concurrent-sessions buildkit-cache-cancellation \
  container-resolver-contract container-dns-search \
  cleanup-restart-persistence; do
  awk -F '\t' -v proof="$proof" \
    '$1 == proof && $2 == "PASS" { found=1 } END { exit !found }' "$competitor_results" \
    || die "retained competitor runtime evidence does not prove $proof"
done

supervisor_manifest="$(single_evidence_file standalone-supervisor-recovery manifest.txt)"
for proof in status healthy_pidfile_repair dead_dataplane_detected \
  incomplete_runtime_poweroff fresh_helper_pair docker_api_recovery; do
  grep -qx "$proof=PASS" "$supervisor_manifest" \
    || die "retained standalone supervisor evidence does not prove $proof"
done
for digest_name in runtime_launcher_sha256 dory_hv_sha256 dataplane_sha256; do
  grep -Eq "^${digest_name}=[0-9a-f]{64}$" "$supervisor_manifest" \
    || die "retained standalone supervisor evidence omits $digest_name"
done
grep -qx "dory_hv_sha256=$DORY_HV_SHA256" "$supervisor_manifest" \
  || die "retained supervisor recovery evidence used the wrong dory-hv"
grep -qx 'release_qualifying=true' "$supervisor_manifest" \
  || die "retained standalone supervisor evidence is not release qualifying"

bind_lock_manifest="$(single_evidence_file bind-advisory-lock manifest.txt)"
for proof in status create_excl_readonly_mode0000_unlink \
  bsd_flock_exclusive_shared_unlock_upgrade_crash \
  posix_range_nonoverlap_blocking_unlock_crash cross_container_bind_mount; do
  grep -qx "$proof=PASS" "$bind_lock_manifest" \
    || die "retained bind advisory-lock evidence does not prove $proof"
done
bind_lock_image="$(sed -n 's/^image=//p' "$bind_lock_manifest")"
printf '%s\n' "$bind_lock_image" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "retained bind advisory-lock evidence has no digest-pinned image"
bind_lock_docker_sha256="$(sed -n 's/^docker_cli_sha256=//p' "$bind_lock_manifest")"
printf '%s\n' "$bind_lock_docker_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "retained bind advisory-lock evidence has no exact Docker CLI digest"
[ "$competitor_docker_sha256" = "$bind_lock_docker_sha256" ] \
  || die "competitor runtime and bind-lock evidence used different Docker CLIs"

guest_agent_manifest="$(single_evidence_file guest-agent manifest.txt)"
for proof in status; do
  grep -qx "$proof=PASS" "$guest_agent_manifest" \
    || die "retained guest-agent boot evidence does not prove $proof"
done
guest_agent_sha256="$(sed -n 's/^expected_sha256=//p' "$guest_agent_manifest")"
printf '%s\n' "$guest_agent_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "retained guest-agent boot evidence has no bundled-agent digest"
grep -qx "fresh_sha256=$guest_agent_sha256" "$guest_agent_manifest" \
  || die "fresh guest boot did not execute the exact bundled agent"
grep -qx "restart_sha256=$guest_agent_sha256" "$guest_agent_manifest" \
  || die "restarted guest did not execute the exact bundled agent"

ssh_agent_manifest="$(single_evidence_file ssh-agent manifest.txt)"
for proof in status; do
  grep -qx "$proof=PASS" "$ssh_agent_manifest" \
    || die "retained SSH-agent evidence does not prove $proof"
done
grep -qx 'guest_socket=/run/host-services/ssh-auth.sock' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence used the wrong guest socket"
ssh_agent_concurrency="$(sed -n 's/^concurrency=//p' "$ssh_agent_manifest")"
case "$ssh_agent_concurrency" in ''|*[!0-9]*) die "retained SSH-agent concurrency is invalid" ;; esac
[ "$ssh_agent_concurrency" -ge 8 ] \
  || die "retained SSH-agent evidence covers fewer than eight concurrent clients"
grep -Eq '^public_key_listing_sha256=[0-9a-f]{64}$' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence has no identity-listing digest"
grep -qx 'buildkit_required_ssh_mount=PASS' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence does not prove a required BuildKit SSH mount"
grep -Eq '^buildkit_public_key_listing_sha256=[0-9a-f]{64}$' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence has no BuildKit identity-listing digest"
ssh_agent_hash="$(sed -n 's/^public_key_listing_sha256=//p' "$ssh_agent_manifest")"
buildkit_ssh_agent_hash="$(sed -n 's/^buildkit_public_key_listing_sha256=//p' "$ssh_agent_manifest")"
[ "$buildkit_ssh_agent_hash" = "$ssh_agent_hash" ] \
  || die "retained BuildKit SSH identities differ from the ordinary agent proof"
grep -Eq '^image=.+@sha256:[0-9a-f]{64}$' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence has no digest-pinned image"
ssh_agent_image="$(sed -n 's/^image=//p' "$ssh_agent_manifest")"
grep -qx "docker_sha256=$competitor_docker_sha256" "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence used the wrong Docker CLI"
grep -qx "buildx_sha256=$CANDIDATE_BUILDX_SHA" "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence used the wrong Buildx plugin"
grep -qx 'bundled_buildx=PASS' "$ssh_agent_manifest" \
  || die "retained SSH-agent evidence did not prove the bundled Buildx plugin"

testcontainers_manifest="$(single_evidence_file testcontainers manifest.txt)"
grep -qx 'status=PASS' "$testcontainers_manifest" \
  || die "retained Testcontainers/Ryuk evidence is not PASS"
testcontainers_version="$(sed -n 's/^testcontainers=//p' "$testcontainers_manifest")"
printf '%s\n' "$testcontainers_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' \
  || die "retained Testcontainers evidence has no exact npm version"

devcontainers_manifest="$(single_evidence_file devcontainers manifest.txt)"
for proof in \
  status official_cli_invocation host_to_container_workspace container_to_host_workspace \
  container_exec exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$devcontainers_manifest" \
    || die "retained Dev Containers evidence does not prove $proof"
done
devcontainers_version="$(sed -n 's/^devcontainers_cli=//p' "$devcontainers_manifest")"
printf '%s\n' "$devcontainers_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' \
  || die "retained Dev Containers evidence has no exact npm version"

act_manifest="$(single_evidence_file act manifest.txt)"
for proof in \
  status host_socket_routing guest_local_socket_mount workflow_execution \
  host_to_runner_workspace runner_to_host_workspace exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$act_manifest" \
    || die "retained act evidence does not prove $proof"
done
act_version="$(sed -n 's/^act_version=//p' "$act_manifest")"
printf '%s\n' "$act_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "retained act evidence has no exact version"
grep -Eq '^act_archive_sha256=[0-9a-f]{64}$' "$act_manifest" \
  || die "retained act evidence has no archive digest"
grep -Eq '^runner_image=.+@sha256:[0-9a-f]{64}$' "$act_manifest" \
  || die "retained act evidence has no digest-pinned runner image"

localstack_manifest="$(single_evidence_file localstack manifest.txt)"
for proof in \
  status dynamic_localhost_port loopback_only_listener health_endpoint \
  s3_object_roundtrip sqs_message_roundtrip exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$localstack_manifest" \
    || die "retained LocalStack evidence does not prove $proof"
done
localstack_image="$(sed -n 's/^localstack_image=//p' "$localstack_manifest")"
printf '%s\n' "$localstack_image" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "retained LocalStack evidence has no digest-pinned image"

tilt_manifest="$(single_evidence_file tilt manifest.txt)"
for proof in \
  status tilt_ci docker_compose_resource compose_health host_to_service_workspace \
  service_to_host_workspace tilt_down exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$tilt_manifest" || die "retained Tilt evidence does not prove $proof"
done
tilt_version="$(sed -n 's/^tilt_version=//p' "$tilt_manifest")"
printf '%s\n' "$tilt_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "retained Tilt evidence has no exact version"
grep -Eq '^tilt_archive_sha256=[0-9a-f]{64}$' "$tilt_manifest" \
  || die "retained Tilt evidence has no archive digest"

supabase_manifest="$(single_evidence_file supabase manifest.txt)"
for proof in \
  status full_default_stack guest_local_docker_socket all_services_running \
  defined_healthchecks_healthy postgres_migration_seed_roundtrip postgrest_roundtrip \
  auth_health storage_health loopback_only_listeners supabase_stop_no_backup \
  exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$supabase_manifest" \
    || die "retained Supabase evidence does not prove $proof"
done
supabase_version="$(sed -n 's/^supabase_cli=//p' "$supabase_manifest")"
printf '%s\n' "$supabase_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "retained Supabase evidence has no exact CLI version"
grep -Eq '^supabase_archive_sha256=[0-9a-f]{64}$' "$supabase_manifest" \
  || die "retained Supabase evidence has no archive digest"
supabase_healthchecks="$(sed -n 's/^docker_healthcheck_count=//p' "$supabase_manifest")"
case "$supabase_healthchecks" in ''|*[!0-9]*) die "retained Supabase healthcheck count is invalid" ;; esac
[ "$supabase_healthchecks" -ge 8 ] \
  || die "retained Supabase evidence covers too few Docker healthchecks"

kubernetes_tooling_manifest="$(single_evidence_file kubernetes-tooling manifest.txt)"
for proof in \
  status k3s_node_ready host_kubectl_api loopback_only_api_listener \
  loopback_only_nodeport_listener skaffold_run skaffold_rollout \
  skaffold_nodeport_http ingress_only_network_policy_egress skaffold_delete \
  tilt_kubernetes_ci tilt_rollout \
  tilt_nodeport_http tilt_down exact_baseline_cleanup; do
  grep -qx "$proof=PASS" "$kubernetes_tooling_manifest" \
    || die "retained Kubernetes tooling evidence does not prove $proof"
done
k3s_image="$(sed -n 's/^k3s_image=//p' "$kubernetes_tooling_manifest")"
kubernetes_workload_image="$(sed -n 's/^workload_image=//p' "$kubernetes_tooling_manifest")"
skaffold_version="$(sed -n 's/^skaffold_version=//p' "$kubernetes_tooling_manifest")"
printf '%s\n' "$k3s_image" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "retained Kubernetes tooling evidence has no digest-pinned k3s image"
printf '%s\n' "$kubernetes_workload_image" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "retained Kubernetes tooling evidence has no digest-pinned workload image"
printf '%s\n' "$skaffold_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "retained Kubernetes tooling evidence has no exact Skaffold version"
grep -Eq '^skaffold_sha256=[0-9a-f]{64}$' "$kubernetes_tooling_manifest" \
  || die "retained Kubernetes tooling evidence has no Skaffold binary digest"
grep -Eq '^tilt_archive_sha256=[0-9a-f]{64}$' "$kubernetes_tooling_manifest" \
  || die "retained Kubernetes tooling evidence has no Tilt archive digest"

long_summary="$(single_evidence_file long-lived summary.txt)"
long_manifest="$(single_evidence_file long-lived manifest.txt)"
long_machine_results="$(single_evidence_file long-lived machine-to-docker-rtt.tsv)"
long_outbound_results="$(single_evidence_file long-lived machine-outbound-tcp.tsv)"
long_machine_hosts="$(single_evidence_file long-lived machine-service-hosts.txt)"
grep -qx 'status=PASS' "$long_summary" \
  && grep -qx 'same_tcp_connection=PASS' "$long_summary" \
  && grep -qx 'duration_beyond_24_hours=PASS' "$long_summary" \
  && grep -qx 'unique_connection_tuples=1' "$long_summary" \
  || die "retained long-lived TCP evidence does not prove one connection beyond 24 hours"
grep -qx 'machine_to_docker_service=PASS' "$long_summary" \
  && grep -qx 'machine_service_route=host.docker.internal' "$long_summary" \
  && grep -qx 'machine_service_regular_200_400ms_plateau=ABSENT' "$long_summary" \
  || die "retained long-lived evidence does not prove stable machine-to-Docker service latency"
grep -qx 'machine_outbound_tcp=PASS' "$long_summary" \
  && grep -qx 'machine_outbound_failure_budget_per_mille=5' "$long_summary" \
  && grep -qx 'machine_outbound_consecutive_failure_limit=2' "$long_summary" \
  || die "retained long-lived evidence weakens managed-machine outbound TCP reliability"
grep -qx 'machine_service_host=host.docker.internal' "$long_manifest" \
  && grep -qx 'machine_service_route=machine-container-to-published-docker-service' "$long_manifest" \
  && grep -qx 'machine_service_p99_budget_ms=100' "$long_manifest" \
  && grep -qx 'machine_service_sustained_budget_ms=150' "$long_manifest" \
  && grep -qx 'machine_service_sustained_sample_limit=3' "$long_manifest" \
  || die "retained machine-to-Docker manifest weakens the latency route or budgets"
grep -qx 'machine_outbound_host=registry-1.docker.io' "$long_manifest" \
  && grep -qx 'machine_outbound_port=443' "$long_manifest" \
  && grep -qx 'machine_outbound_failure_budget_per_mille=5' "$long_manifest" \
  && grep -qx 'machine_outbound_consecutive_failure_limit=2' "$long_manifest" \
  || die "retained managed-machine outbound target or budgets changed"
grep -Fq 'host.docker.internal' "$long_machine_hosts" \
  || die "retained machine-to-Docker evidence does not prove route-name resolution"

endurance_manifest="$(single_evidence_file endurance manifest.txt)"
endurance_cycles="$(single_evidence_file endurance cycles.tsv)"
endurance_resources="$(single_evidence_file endurance resources.tsv)"
power_manifest="$QUALIFICATION/evidence/power-assertion-manifest.txt"
power_history="$QUALIFICATION/evidence/power-history.tsv"
power_assertions="$QUALIFICATION/evidence/power-assertions.txt"
power_source="$QUALIFICATION/evidence/power-source.txt"
for power_evidence in "$power_manifest" "$power_history" "$power_assertions" "$power_source"; do
  [ -s "$power_evidence" ] || die "retained qualification power evidence is missing: $power_evidence"
done
grep -qx 'release_qualifying=true' "$endurance_manifest" \
  || die "retained endurance manifest is not release qualifying"
grep -qx 'fseventsd_rss_growth_mb=128' "$endurance_manifest" \
  && grep -qx 'fseventsd_cpu_percent=25' "$endurance_manifest" \
  || die "retained endurance manifest weakens host fseventsd budgets"
[ "$(wc -l < "$endurance_cycles" | tr -d ' ')" -gt 1 ] \
  || die "retained endurance evidence has no cycle rows"
grep -q $'\tFAIL\t' "$endurance_cycles" \
  && die "retained endurance evidence contains a failed cycle"
python3 scripts/analyze-endurance-resources.py "$endurance_resources" \
  --fd-growth 16 --rss-growth-mb 384 --disk-growth-mb 256 --idle-cpu 25 \
  --fseventsd-rss-growth-mb 128 --fseventsd-cpu 25 \
  >/dev/null \
  || die "retained endurance resource evidence does not show a stable plateau"

python3 - "$growth_summary" "$competitor_results" "$long_summary" "$long_machine_results" \
  "$long_outbound_results" \
  "$endurance_manifest" \
  "$power_manifest" "$power_history" "$power_assertions" "$power_source" <<'PY'
import csv
import datetime as dt
import math
import sys

(
    growth_path, competitor_path, long_path, long_machine_path, long_outbound_path, endurance_path,
    power_manifest_path, power_history_path, power_assertions_path, power_source_path,
) = sys.argv[1:]

def properties(path):
    values = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            key, separator, value = raw.strip().partition("=")
            if separator:
                values[key] = value
    return values

growth = properties(growth_path)
for key in ("seed_allocated_bytes", "grown_logical_bytes", "grown_allocated_bytes",
            "minimum_logical_bytes", "guest_ext4_bytes", "minimum_guest_bytes"):
    assert key in growth, f"growth evidence omits {key}"
assert int(growth["grown_logical_bytes"]) >= int(growth["minimum_logical_bytes"]), \
    "sparse disk did not reach the required logical capacity"
assert int(growth["grown_allocated_bytes"]) < int(growth["grown_logical_bytes"]), \
    "grown disk is not sparse"
assert int(growth["grown_allocated_bytes"]) < int(growth["seed_allocated_bytes"]), \
    "discard did not reclaim the preallocated seed"
assert int(growth["guest_ext4_bytes"]) >= int(growth["minimum_guest_bytes"]), \
    "guest ext4 capacity stayed below its required floor"

required_competitor_tests = {
    "published-port-handoff", "host-port-collision", "named-signal-delivery", "container-api-lifecycle",
    "forwarded-connection-fds",
    "concurrent-proxy-backpressure",
    "missing-source-cp", "restart-churn", "compose-port-restart", "compose-v2-lifecycle",
    "network-route-conflict",
    "network-api-lifecycle",
    "standalone-engine-restart", "named-volume-empty", "named-volume", "named-volume-cp",
    "volume-api-lifecycle", "security-opt-label", "seccomp-profile",
    "bind-open-create-0200",
    "bind-mount-option-contract",
    "healthcheck", "buildx-named-context", "buildkit-default-arg", "image-save-stdout",
    "image-hardlink-missing-parent", "buildkit-large-dockerfile",
    "buildkit-concurrent-sessions", "buildkit-cache-cancellation",
    "container-resolver-contract", "container-dns-search", "cleanup-restart-persistence",
}
with open(competitor_path, encoding="utf-8", newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
by_test = {row.get("test"): row.get("status") for row in rows}
missing = required_competitor_tests - set(by_test)
assert not missing, f"competitor evidence omits required tests: {sorted(missing)}"
assert all(by_test[name] == "PASS" for name in required_competitor_tests), \
    "one or more required competitor tests did not pass"

long = properties(long_path)
assert float(long.get("actual_elapsed_seconds", "0")) > 86400, \
    "same-connection evidence did not actually cross 24 hours"
assert int(long.get("heartbeats", "0")) > 0, "same-connection evidence has no heartbeats"
assert int(long.get("unique_connection_tuples", "0")) == 1, \
    "same-connection evidence changed its TCP tuple"
assert long.get("machine_to_docker_service") == "PASS", \
    "machine-to-Docker service route did not pass"
assert long.get("machine_service_route") == "host.docker.internal", \
    "machine-to-Docker service used the wrong route"
assert float(long.get("machine_service_actual_elapsed_seconds", "0")) > 86400, \
    "machine-to-Docker latency evidence did not actually cross 24 hours"
with open(long_machine_path, encoding="utf-8", newline="") as handle:
    machine_rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(machine_rows) == int(long.get("machine_service_samples", "0")), \
    "machine-to-Docker sample count differs from the summary"
assert len(machine_rows) >= 2592, \
    "machine-to-Docker evidence retains fewer than 90% of 25-hour/30-second samples"
assert all(row.get("status") == "PASS" for row in machine_rows), \
    "machine-to-Docker latency evidence contains a failed sample"
machine_values = [int(row["rtt_ms"]) for row in machine_rows]
ordered = sorted(machine_values)
machine_p99 = ordered[max(0, math.ceil(len(ordered) * 0.99) - 1)]
machine_over_100 = sum(value > 100 for value in machine_values)
machine_200 = sum(value >= 200 for value in machine_values)
assert machine_p99 <= 100, f"machine-to-Docker p99 exceeds 100ms: {machine_p99}ms"
assert machine_over_100 <= max(1, math.floor(len(machine_values) * 0.01)), \
    "machine-to-Docker RTT exceeds 100ms too frequently"
run = 0
max_run = 0
for value in machine_values:
    run = run + 1 if value >= 150 else 0
    max_run = max(max_run, run)
assert max_run < 3, "machine-to-Docker RTT contains a sustained >=150ms plateau"
assert int(long.get("machine_service_p99_ms", "-1")) == machine_p99, \
    "machine-to-Docker p99 differs from the raw evidence"
assert int(long.get("machine_service_max_ms", "-1")) == max(machine_values), \
    "machine-to-Docker maximum differs from the raw evidence"
assert int(long.get("machine_service_over_100ms_samples", "-1")) == machine_over_100, \
    "machine-to-Docker >100ms count differs from the raw evidence"
assert int(long.get("machine_service_200ms_samples", "-1")) == machine_200, \
    "machine-to-Docker >=200ms count differs from the raw evidence"
assert int(long.get("machine_service_max_sustained_150ms_samples", "-1")) == max_run, \
    "machine-to-Docker sustained-latency run differs from the raw evidence"
assert long.get("machine_outbound_tcp") == "PASS", \
    "managed-machine outbound TCP qualification did not pass"
with open(long_outbound_path, encoding="utf-8", newline="") as handle:
    outbound_rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(outbound_rows) == int(long.get("machine_outbound_samples", "0")), \
    "managed-machine outbound sample count differs from the summary"
assert len(outbound_rows) == len(machine_rows), \
    "managed-machine outbound sample count differs from the local-route count"
outbound_successes = sum(row.get("status") == "PASS" for row in outbound_rows)
outbound_failures = len(outbound_rows) - outbound_successes
assert outbound_failures <= max(1, math.floor(len(outbound_rows) * 0.005)), \
    "managed-machine outbound TCP failure budget exceeded"
failure_run = 0
max_failure_run = 0
for row in outbound_rows:
    failure_run = failure_run + 1 if row.get("status") != "PASS" else 0
    max_failure_run = max(max_failure_run, failure_run)
assert max_failure_run < 2, "managed-machine outbound TCP has consecutive failures"
assert all(
    len(row.get("remote_ipv4", "").split(".")) == 4
    and all(
        part.isdigit() and 0 <= int(part) <= 255
        for part in row["remote_ipv4"].split(".")
    )
    for row in outbound_rows if row.get("status") == "PASS"
), "managed-machine outbound PASS row lacks a valid IPv4 target"
assert int(long.get("machine_outbound_tcp_successes", "-1")) == outbound_successes, \
    "managed-machine outbound success count differs from raw evidence"
assert int(long.get("machine_outbound_timeout_samples", "-1")) == outbound_failures, \
    "managed-machine outbound failure count differs from raw evidence"
assert int(long.get("machine_outbound_max_consecutive_failures", "-1")) == max_failure_run, \
    "managed-machine outbound failure run differs from raw evidence"

endurance = properties(endurance_path)
assert int(endurance.get("duration_seconds", "0")) >= 28800, \
    "endurance evidence was configured below eight hours"

power_manifest = properties(power_manifest_path)
assert power_manifest == {
    "status": "PASS",
    "flags": "-is",
    "display_sleep_prevented": "false",
}, "power assertion manifest is not the display-neutral -is contract"
with open(power_source_path, encoding="utf-8") as handle:
    assert "Now drawing from 'AC Power'" in handle.read(), "qualification did not start on AC power"
with open(power_assertions_path, encoding="utf-8") as handle:
    assertions = handle.read()
assert "pid " in assertions and "(caffeinate)" in assertions, \
    "power evidence is not owned by caffeinate"
assert "PreventUserIdleSystemSleep" in assertions, "idle-sleep assertion is missing"
assert "PreventSystemSleep" in assertions, "system-sleep assertion is missing"
with open(power_history_path, encoding="utf-8", newline="") as handle:
    power_rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(power_rows) >= 2, "continuous power evidence has fewer than two samples"
timestamps = []
for row in power_rows:
    assert "Now drawing from 'AC Power'" in row["pmset_state"], \
        "qualification lost AC power"
    timestamps.append(dt.datetime.fromisoformat(row["checked_utc"].replace("Z", "+00:00")))
required_power_span = float(long["actual_elapsed_seconds"]) - 120
assert (timestamps[-1] - timestamps[0]).total_seconds() >= required_power_span, \
    "power assertion history does not span the same-connection qualification"
PY

python3 - "$COMPLETE" "$BUILD_DIR" "$VERSION" "$BUILD" "$SOURCE_COMMIT" \
  "$RUN_ID" "$RUN_ATTEMPT" "$PRIMARY_SHA256" "$testcontainers_version" \
  "$devcontainers_version" "$act_version" "$localstack_image" "$tilt_version" \
  "$supabase_version" "$k3s_image" "$kubernetes_workload_image" \
  "$skaffold_version" "$bind_lock_image" "$bind_lock_docker_sha256" \
  "$guest_agent_sha256" "$ssh_agent_image" "$private_registry_base_image" \
  "$private_registry_image" <<'PY'
import hashlib
import json
import os
import sys

(
    complete_path, build_dir, version, build, source_commit, run_id, run_attempt,
    primary_sha, testcontainers_version, devcontainers_version, act_version,
    localstack_image, tilt_version, supabase_version, k3s_image,
    kubernetes_workload_image, skaffold_version, bind_lock_image, bind_lock_docker_sha256,
    guest_agent_sha256, ssh_agent_image, private_registry_base_image,
    private_registry_image,
) = sys.argv[1:]

def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

with open(complete_path, encoding="utf-8") as handle:
    qualification = json.load(handle)
assert qualification.get("schemaVersion") == 1, "unexpected qualification schema"
assert qualification.get("status") == "PASS", "qualification did not pass"
assert qualification.get("releaseQualifying") is True, "qualification used development exceptions"
assert qualification.get("developmentUnnotarized") is False, "qualification skipped notarization"
assert qualification.get("dataDiskGrowthGate") == "PASS", \
    "16→128 GiB growth/sparse-trim/persistence qualification did not pass"
assert qualification.get("managedDataDriveGate") == "PASS", \
    "managed data-drive persistence/fail-closed qualification did not pass"
assert qualification.get("dataDriveVolumeIdentityGate") == "PASS", \
    "data-drive APFS volume-identity qualification did not pass"
assert qualification.get("offlineBundledBootGate") == "PASS", \
    "bundled/cached offline boot qualification did not pass"
assert qualification.get("defaultPlatformImageGate") == "PASS", \
    "default arm64 image selection/storage qualification did not pass"
assert qualification.get("pruneSafetyGate") == "PASS", \
    "active-versus-unused Docker prune qualification did not pass"
assert qualification.get("privateRegistryAuthGate") == "PASS", \
    "private-registry authentication/image lifecycle qualification did not pass"
assert qualification.get("privateRegistryImage") == private_registry_image, \
    "private-registry fixture differs from the completion record"
assert qualification.get("nonnativeNixGCGate") == "PASS", \
    "linux/amd64 Nix garbage-collection qualification did not pass"
assert qualification.get("nonnativeArchPacmanGate") == "PASS", \
    "linux/amd64 Arch pacman sandbox qualification did not pass"
assert qualification.get("nonnativeMmdebstrapGate") == "PASS", \
    "linux/amd64 mmdebstrap nested-chroot qualification did not pass"
assert qualification.get("nonnativeExecConformanceGate") == "PASS", \
    "linux/amd64 generic exec conformance qualification did not pass"
assert qualification.get("ecrRegistryRetryGate") == "PASS", \
    "managed ECR interrupted-upload/retry qualification did not pass"
assert qualification.get("bindFileCoherenceGate") == "PASS", \
    "spaced-path/direct-file bind coherence qualification did not pass"
assert qualification.get("powerAssertion") == "PASS", \
    "qualification did not prove a continuous display-neutral sleep-prevention assertion"
assert qualification.get("gvproxyQEMUSwitchGate") == "PASS", \
    "independent bidirectional gvproxy LAN switch-port qualification did not pass"
assert qualification.get("nativeIPv6Gate") == "PASS", \
    "native IPv6 address/DNS/registry/TCP/restart qualification did not pass"
assert qualification.get("migrationGate") == "PASS", \
    "two-engine production migration qualification did not pass"
assert qualification.get("competitorRuntimeGate") == "PASS", \
    "concurrent-backpressure/restart qualification did not pass"
assert qualification.get("machineToDockerLongLivedGate") == "PASS", \
    "machine-to-Docker long-lived latency qualification did not pass"
assert qualification.get("machineOutboundLongLivedGate") == "PASS", \
    "managed-machine outbound long-lived qualification did not pass"
assert qualification.get("standaloneSupervisorRecoveryGate") == "PASS", \
    "standalone stale/orphan supervisor recovery qualification did not pass"
assert qualification.get("bindAdvisoryLockGate") == "PASS", \
    "cross-container bind advisory-lock qualification did not pass"
assert qualification.get("bindAdvisoryLockImage") == bind_lock_image, \
    "bind advisory-lock evidence image differs from the completion record"
assert qualification.get("bindAdvisoryLockDockerCLI_SHA256") == bind_lock_docker_sha256, \
    "bind advisory-lock Docker CLI digest differs from the completion record"
assert qualification.get("guestAgentBootConfigGate") == "PASS", \
    "exact bundled guest-agent boot qualification did not pass"
assert qualification.get("guestAgentSha256") == guest_agent_sha256, \
    "guest-agent evidence digest differs from the completion record"
assert qualification.get("sshAgentForwardingGate") == "PASS", \
    "SSH-agent forwarding qualification did not pass"
assert qualification.get("sshAgentImage") == ssh_agent_image, \
    "SSH-agent evidence image differs from the completion record"
fixture_image = qualification.get("fixtureImage", "")
assert __import__("re").fullmatch(r".+@sha256:[0-9a-f]{64}", fixture_image), \
    "qualification fixture image is not digest-pinned"
assert fixture_image == private_registry_base_image, \
    "private-registry base image differs from the qualification fixture"
assert qualification.get("testcontainersGate") == "PASS", \
    "Testcontainers/Ryuk qualification did not pass"
assert qualification.get("testcontainersVersion") == testcontainers_version, \
    "Testcontainers evidence version differs from the completion record"
assert qualification.get("devcontainersGate") == "PASS", \
    "Dev Containers CLI qualification did not pass"
assert qualification.get("devcontainersVersion") == devcontainers_version, \
    "Dev Containers evidence version differs from the completion record"
assert qualification.get("actGate") == "PASS", "act workflow qualification did not pass"
assert qualification.get("actVersion") == act_version, \
    "act evidence version differs from the completion record"
assert qualification.get("localstackGate") == "PASS", \
    "LocalStack S3/SQS qualification did not pass"
assert qualification.get("localstackImage") == localstack_image, \
    "LocalStack evidence image differs from the completion record"
assert qualification.get("tiltGate") == "PASS", "Tilt Compose qualification did not pass"
assert qualification.get("tiltVersion") == tilt_version, \
    "Tilt evidence version differs from the completion record"
assert qualification.get("supabaseGate") == "PASS", \
    "full default Supabase qualification did not pass"
assert qualification.get("supabaseVersion") == supabase_version, \
    "Supabase evidence version differs from the completion record"
assert qualification.get("kubernetesToolingGate") == "PASS", \
    "k3s/Skaffold/Tilt Kubernetes qualification did not pass"
assert qualification.get("k3sImage") == k3s_image, \
    "k3s evidence image differs from the completion record"
assert qualification.get("kubernetesWorkloadImage") == kubernetes_workload_image, \
    "Kubernetes workload evidence image differs from the completion record"
assert qualification.get("skaffoldVersion") == skaffold_version, \
    "Skaffold evidence version differs from the completion record"
assert qualification.get("version") == version, "qualification version mismatch"
assert str(qualification.get("build")) == build, "qualification build mismatch"
assert qualification.get("sourceCommit") == source_commit, "qualification commit mismatch"
assert str(qualification.get("githubRunId")) == run_id, "qualification run mismatch"
assert str(qualification.get("githubRunAttempt")) == run_attempt, "qualification attempt mismatch"
assert int(qualification.get("enduranceDurationSeconds", 0)) >= 28800, "endurance duration is too short"
assert int(qualification.get("longLivedDurationSeconds", 0)) > 86400, "TCP duration does not cross 24 hours"

manifest_path = os.path.join(build_dir, "release-manifest.json")
assert qualification.get("candidateManifestSha256") == digest(manifest_path), \
    "candidate manifest differs from the qualified manifest"
assert qualification.get("appUpdateSha256") == digest(
    os.path.join(build_dir, f"Dory-{version}-app-update.zip")
), "Sparkle candidate differs from the qualified archive"
assert qualification.get("runtimeSha256") == digest(
    os.path.join(build_dir, f"dory-engine-{version}-arm64.tar.gz")
), "runtime differs from the qualified archive"
evidence_manifest = os.path.join(os.path.dirname(complete_path), "evidence", "evidence-sha256.txt")
assert qualification.get("evidenceManifestSha256") == digest(evidence_manifest), \
    "qualification evidence manifest changed"

with open(manifest_path, encoding="utf-8") as handle:
    release_manifest = json.load(handle)
assert release_manifest.get("schemaVersion") == 2, "unexpected release manifest schema"
assert release_manifest.get("version") == version, "release manifest version mismatch"
assert str(release_manifest.get("build")) == build, "release manifest build mismatch"
assert release_manifest.get("sourceCommit") == source_commit, "release manifest commit mismatch"
assert release_manifest.get("publicRelease") is True, "candidate is not marked public"
assert release_manifest.get("notarized") is True, "candidate is not marked notarized"
assert release_manifest.get("variants") == "arm64", "candidate is not Apple-Silicon-only"
by_name = {record.get("name"): record for record in release_manifest.get("artifacts", [])}
required = {
    f"Dory-{version}-arm64.zip", f"Dory-{version}.zip",
    f"Dory-{version}-arm64.dmg", f"Dory-{version}.dmg",
    f"Dory-{version}-lite.zip", f"Dory-{version}-app-update.zip",
    f"dory-engine-{version}-arm64.tar.gz", "appcast.xml",
    f"Dory-{version}.cdx.json",
}
assert len(by_name) == len(release_manifest.get("artifacts", [])), \
    "release manifest contains duplicate artifact names"
assert not (required - set(by_name)), f"release manifest omits: {sorted(required - set(by_name))}"
assert not (set(by_name) - required), \
    f"release manifest contains unexpected artifacts: {sorted(set(by_name) - required)}"
for name in required:
    path = os.path.join(build_dir, name)
    assert os.path.isfile(path), f"candidate artifact is missing: {name}"
    record = by_name[name]
    assert record.get("path") == name, f"candidate manifest path is not portable: {name}"
    assert record.get("bytes") == os.path.getsize(path), f"candidate size mismatch: {name}"
    assert record.get("sha256") == digest(path), f"candidate digest mismatch: {name}"
assert by_name[f"Dory-{version}.zip"].get("sha256") == primary_sha, \
    "Homebrew/Apple-Silicon SHA output differs from the qualified manifest"
PY

echo "release qualification verification: PASS"
