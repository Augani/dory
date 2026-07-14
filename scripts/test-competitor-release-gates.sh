#!/bin/bash
# Offline regression and safety tests for the competitor-derived release gates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-competitor-gates.XXXXXX")"
test_pids=""
short_runtime_home=""
cleanup() {
  local pid
  for pid in $test_pids; do
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
  [ -z "$short_runtime_home" ] || rm -rf "$short_runtime_home"
}
trap cleanup EXIT
fail() { echo "competitor gate test failed: $*" >&2; exit 1; }

scripts/test-endurance-resource-analysis.sh >/dev/null
scripts/test-idle-proxy-cold-wake.sh >/dev/null
scripts/verify-competitor-coverage-matrix.sh >/dev/null

for script in \
  scripts/endurance-reliability-soak.sh \
  scripts/external-volume-bind-gate.sh \
  scripts/bind-advisory-lock-gate.sh \
  scripts/ssh-agent-forwarding-gate.sh \
  scripts/competitor-runtime-regression-gate.sh \
  scripts/restart-pressure-soak.sh \
  scripts/data-disk-growth-gate.sh \
  scripts/testcontainers-compatibility-gate.sh \
  scripts/devcontainers-compatibility-gate.sh \
  scripts/act-compatibility-gate.sh \
  scripts/localstack-compatibility-gate.sh \
  scripts/tilt-compose-compatibility-gate.sh \
  scripts/supabase-compatibility-gate.sh \
  scripts/kubernetes-tooling-compatibility-gate.sh \
  scripts/native-ipv6-gate.sh \
  scripts/vz-native-ipv6-gate.sh \
  scripts/source-preserving-lan-gate.sh \
  scripts/host-network-integrity-gate.sh \
  scripts/network-contract-gate.sh \
  scripts/bind-file-coherence-gate.sh \
  scripts/prune-safety-gate.sh \
  scripts/private-registry-auth-gate.sh \
  scripts/ecr-registry-retry-gate.sh \
  scripts/headless-cold-start-soak.sh \
  scripts/offline-bundled-boot-gate.sh \
  scripts/default-platform-image-gate.sh \
  scripts/nonnative-nix-gc-gate.sh \
  scripts/nonnative-arch-pacman-gate.sh \
  scripts/nonnative-mmdebstrap-gate.sh \
  scripts/nonnative-exec-conformance-gate.sh \
  scripts/machine-resource-reconfiguration-gate.sh \
  scripts/long-lived-network-soak.sh \
  scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh \
  scripts/verify-competitor-coverage-matrix.sh \
  scripts/sign-machine-image-manifest.sh \
  scripts/sparkle-install-relaunch-gate.sh \
  scripts/generate-release-sbom.py \
  scripts/verify-release-sbom.py \
  scripts/nonnative-build-smoke.sh; do
  case "$script" in
    *.py) python3 -m py_compile "$script" ;;
    *) bash -n "$script" ;;
  esac
  "$script" --help > "$TMP/$(basename "$script").help"
done
python3 -m py_compile scripts/gvproxy-qemu-switch-gate.py
python3 -m py_compile scripts/bind-advisory-lock-probe.py
grep -F 'Dory-$VERSION.cdx.json' scripts/release.sh scripts/validate-release-outputs.sh >/dev/null \
  || fail "public release omits the exact-app CycloneDX SBOM"
grep -F 'release-build/*.cdx.json' .github/workflows/release.yml >/dev/null \
  || fail "immutable candidate upload omits the CycloneDX SBOM"
grep -F 'Dory-${{ needs.release_candidate.outputs.version }}.cdx.json' \
  .github/workflows/release.yml >/dev/null \
  || fail "GitHub Release publication omits the CycloneDX SBOM"
scripts/gvproxy-qemu-switch-gate.py --help > "$TMP/gvproxy-qemu-switch-gate.help"
python3 - <<'PY'
from pathlib import Path
import re

for name in (
    "scripts/long-lived-network-soak.sh",
    "scripts/competitor-runtime-regression-gate.sh",
    "scripts/ecr-registry-retry-gate.sh",
    "scripts/nonnative-nix-gc-gate.sh",
    "scripts/nonnative-arch-pacman-gate.sh",
    "scripts/nonnative-mmdebstrap-gate.sh",
    "scripts/nonnative-exec-conformance-gate.sh",
    "scripts/qualify-release-candidate.sh",
):
    source = Path(name).read_text(encoding="utf-8")
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", source, flags=re.DOTALL)
    assert blocks, f"no embedded Python found in {name}"
    for index, block in enumerate(blocks, 1):
        compile(block, f"{name}:heredoc-{index}", "exec")
PY
bash -n scripts/dory
grep -F 'STATE="$DORY_ROOT/standalone"' scripts/runtime/dory-engine >/dev/null \
  || fail "standalone runtime private state can overlap doryd ownership"
if grep -F 'Legacy app-shim fallback' scripts/dory >/dev/null; then
  fail "app CLI retained the competing legacy app-owned engine fallback"
fi
python3 - <<'PY'
from pathlib import Path

source = Path("Dory/Models/AppStore.swift").read_text(encoding="utf-8")
start = source.index("        case .dory:")
end = source.index("    private func connectDorydBackend", start)
assert "DockerEngineRuntime.detect" not in source[start:end], (
    "Dory preference silently falls back to an external engine"
)
PY
grep -F -- '--state-dir "$STATE/hv"' scripts/runtime/dory-engine >/dev/null \
  || fail "headless runtime does not isolate dory-hv/gvproxy state beneath its own HOME"
grep -F -- '--data-drive "$DATA_DRIVE"' scripts/runtime/dory-engine >/dev/null \
  || fail "headless runtime does not route persistence through the managed Dory data drive"
grep -F -- '--share "volumes=/Volumes:rw:at=/Volumes:safe"' scripts/runtime/dory-engine >/dev/null \
  || fail "headless runtime does not expose explicit external-volume bind paths"
grep -F -- '--guest-agent "$AGENT_OUTPUT"' scripts/runtime/dory-engine >/dev/null \
  || fail "headless runtime can silently boot the stale rootfs agent behind its safe home share"
grep -F 'Keep gvproxy alive while dory-hv asks the guest shutdown listener' \
  scripts/runtime/dory-engine >/dev/null \
  || fail "standalone stop can kill gvproxy before guest Docker state is synced and unmounted"
grep -F 'verify_running_guest_agent fresh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification does not prove the exact bundled agent on a fresh guest boot"
grep -F 'verify_running_guest_agent restart' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification does not prove the exact bundled agent after an engine restart"
grep -F '"guestAgentBootConfigGate": "PASS"' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification does not publish its exact guest-agent boot result"
grep -F 'guestAgentBootConfigGate' scripts/verify-release-qualification.sh >/dev/null \
  || fail "release publication does not verify the exact guest-agent boot result"
grep -F '[ -f "$KERNEL_ASSET" ] || [ -f "$KERNEL" ]' scripts/runtime/dory-engine >/dev/null \
  || fail "standalone runtime cannot boot from a valid prepared kernel cache"
for offline_boot_contract in cached_boot_without_bundle_sources dead_proxy_environment \
  host_tcp_dependency_absence prepared_assets_unchanged; do
  grep -F "$offline_boot_contract" scripts/offline-bundled-boot-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "offline cached-boot qualification omits $offline_boot_contract"
done
grep -F 'lima-vm/lima/issues/5188' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Lima's cached-image HEAD failure"
grep -F 'docker/for-mac/issues/7825' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Docker Desktop's file-share backend-switch kernel crash"
if grep -R -Eis 'grpc.?fuse' Dory Packages/ContainerizationEngine/Sources \
    dory-core-swift/Sources >/dev/null; then
  fail "production source introduced a switchable gRPC FUSE backend"
fi
for default_platform_contract in default_pull_without_platform single_platform_local_image \
  default_run_architecture image_list_system_df_reconciled require-docker-hub; do
  grep -F "$default_platform_contract" scripts/default-platform-image-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "default platform image qualification omits $default_platform_contract"
done
grep -F '# Intentionally no --platform here.' scripts/default-platform-image-gate.sh >/dev/null \
  || fail "default platform image gate no longer documents the unqualified pull"
for private_registry_contract in registry_fixture_arm64 unauthenticated_pull_rejected authenticated_login \
  authenticated_pull_run buildkit_registry_auth buildkit_secret_nonleak registry_push \
  image_inspect_history image_save_load_identity image_tag_remove filtered_image_prune \
  owned_cleanup isolated_credential_cleanup; do
  grep -F "$private_registry_contract" scripts/private-registry-auth-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "private-registry qualification omits $private_registry_contract"
done
grep -F 'registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373' \
  scripts/private-registry-auth-gate.sh scripts/qualify-release-candidate.sh >/dev/null \
  || fail "private-registry qualification lost its digest-pinned registry fixture"
grep -F 'scripts/private-registry-auth-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "exact candidate qualification does not run private-registry auth"
grep -F 'privateRegistryAuthGate' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "private-registry qualification is not bound to publication evidence"
grep -F 'docker_cli_sha256=$CANDIDATE_DOCKER_SHA' \
  scripts/verify-release-qualification.sh >/dev/null \
  && grep -F 'buildx_cli_sha256=$CANDIDATE_BUILDX_SHA' \
    scripts/verify-release-qualification.sh >/dev/null \
  || fail "private-registry evidence is not bound to exact candidate clients"
for prune_contract in empty_engine_precondition unfiltered_system_prune \
  unfiltered_container_prune unfiltered_image_prune unfiltered_network_prune \
  unfiltered_volume_prune unfiltered_builder_prune active_container_survived \
  active_image_survived active_volume_survived active_network_survived \
  active_volume_bytes_preserved unused_container_removed unused_image_removed \
  unused_volume_removed unused_network_removed build_cache_removed owned_cleanup; do
  grep -F "$prune_contract" scripts/prune-safety-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "exact prune-safety qualification omits $prune_contract"
done
grep -F 'scripts/prune-safety-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  && grep -F 'pruneSafetyGate' scripts/qualify-release-candidate.sh \
    scripts/verify-release-qualification.sh >/dev/null \
  || fail "prune-safety qualification is not bound to exact publication evidence"
grep -F 'apple/container/issues/1537' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Apple's multi-platform storage regression"
for nix_gc_contract in fresh_pull unreachable_store_path_created \
  nix_collect_garbage_delete_old unreachable_store_path_deleted docker_api_after_gc \
  owned_cleanup; do
  grep -F "$nix_gc_contract" scripts/nonnative-nix-gc-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "non-native Nix GC qualification omits $nix_gc_contract"
done
grep -F 'orbstack/orbstack/issues/2538' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits OrbStack's linux/amd64 Nix GC regression"
grep -F 'apple/container/issues/1825' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Apple's BuildKit-without-Rosetta request"
for arch_pacman_contract in fresh_pull pacman_default_sandbox alpm_user_switch fex_handler \
  fex_bundle_read_only fex_binfmt_flags oci_default_runtime fzf_inventory fzf_runtime \
  docker_api_after_build owned_cleanup; do
  grep -F "$arch_pacman_contract" scripts/nonnative-arch-pacman-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "non-native Arch pacman qualification omits $arch_pacman_contract"
done
for mmdebstrap_contract in fresh_pull reported_dockerfile_commands mmdebstrap_minbase_trixie \
  bad_fd_number_absent rootfs_archive_readable nested_chroot_no_proc nested_chroot_shebang \
  private_marker_isolation build_cache_cleanup owned_cleanup; do
  grep -F "$mmdebstrap_contract" scripts/nonnative-mmdebstrap-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "non-native mmdebstrap qualification omits $mmdebstrap_contract"
done
for exec_contract in fresh_pulls amd64_only_binfmt canonical_shebang_paths env_shebang_chain \
  private_marker_isolation guest_seccomp_inheritance fd_exec_arguments fd_exec_null_argv \
  buildkit_exec_matrix runtime_exec_matrix docker_exec_matrix build_cache_cleanup owned_cleanup; do
  grep -F "$exec_contract" scripts/nonnative-exec-conformance-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "non-native exec qualification omits $exec_contract"
done
grep -F 'RUN pacman -Sy --noconfirm fzf' scripts/nonnative-arch-pacman-gate.sh >/dev/null \
  || fail "Arch pacman gate lost the competitor's exact Dockerfile command"
for fex_contract in fex_arm64 fex_libc6_arm64 fex_gcc_base_arm64; do
  grep -F "$fex_contract" guest/initfs/PINS >/dev/null \
    || fail "Apple Silicon FEX runtime omits provenance pin $fex_contract"
done
if grep -Eq '^fex_(libgcc|libstdcxx)_arm64 ' guest/initfs/PINS; then
  fail "static Apple Silicon FEX runtime still carries obsolete dynamic-library payload pins"
fi
grep -F 'CMAKE_EXE_LINKER_FLAGS=-static-pie' guest/initfs/vendor/fex-2607-dory1/Dockerfile >/dev/null \
  || fail "Apple Silicon FEX interpreter is not built to survive nested chroot boundaries"
grep -F 'const REAL_RUNC: &str = "/usr/local/bin/runc.real"' \
  dory-core/runc-wrapper/src/main.rs >/dev/null \
  || fail "Dory OCI wrapper can recurse instead of delegating to the vendor runc"
grep -F 'ln -s dory-runc "$rootfs/usr/local/bin/runc"' guest/initfs/build.sh >/dev/null \
  || fail "BuildKit's conventional runc path bypasses Dory's FEX OCI wrapper"
grep -F 'printf '\''%s'\''' Packages/ContainerizationEngine/Sources/DoryHV/BinfmtRegistration.swift >/dev/null \
  || fail "FEX binfmt registration does not preserve the kernel's literal byte escapes"
if grep -F 'printf '\''%b'\''' Packages/ContainerizationEngine/Sources/DoryHV/BinfmtRegistration.swift >/dev/null; then
  fail "FEX binfmt registration decodes NUL bytes before the kernel parses its mask"
fi
grep -F 'flags: POCF' Packages/ContainerizationEngine/Sources/DoryHV/BinfmtRegistration.swift >/dev/null \
  || fail "FEX binfmt registration lost its preserve/open/credential/fix-binary flags"
grep -F 'start --mem-mb 8192 --cpus 6 --amd64' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "exact qualification does not enable its mandatory non-native architecture path"
for ecr_contract in authenticated_login bundled_buildx interrupted_push_progress \
  interrupted_push_nonzero resumed_blob_upload \
  repeated_manifest_put repull_run_checksum local_image_cleanup remote_tag_cleanup \
  isolated_credential_cleanup; do
  grep -F "$ecr_contract" scripts/ecr-registry-retry-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "managed ECR qualification omits $ecr_contract"
done
grep -F 'DOCKER_CONFIG/cli-plugins/docker-buildx' scripts/ecr-registry-retry-gate.sh >/dev/null \
  || fail "managed ECR qualification hides the exact candidate Buildx plugin behind its isolated Docker config"
grep -F 'BUILDX="$(dirname "$DOCKER")/docker-buildx"' scripts/ecr-registry-retry-gate.sh >/dev/null \
  || fail "managed ECR qualification does not bind Buildx to the exact candidate Docker client"
grep -F 'apple/container/issues/1707' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Apple's ECR manifest PUT regression"
grep -F 'apple/container/issues/1895' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Apple's partial-blob retry regression"
grep -F 'apple/containerization/issues/790' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits containerization's byte-zero retry regression"
grep -F '"volumes=/Volumes:rw:at=/Volumes:safe"' \
  Dory/Runtime/Shared/SharedVMProvisioner.swift >/dev/null \
  || fail "app runtime does not expose explicit external-volume bind paths"
grep -F -- '--direct-ipv6' scripts/runtime/dory-engine \
  Dory/Runtime/Shared/SharedVMProvisioner.swift \
  dory-core-swift/Sources/DorydKit/DorydConfiguration.swift >/dev/null \
  || fail "native IPv6 is not enabled by every production dory-hv launcher"
grep -F 'scripts/native-ipv6-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the exact-artifact native IPv6 gate"
for ipv6_gate in scripts/native-ipv6-gate.sh scripts/vz-native-ipv6-gate.sh; do
  grep -F 'Library/Application Support/Dory/Dory.dorydrive' "$ipv6_gate" >/dev/null \
    || fail "IPv6 qualification uses a data drive outside the production-authorized root: $ipv6_gate"
done
grep -F 'HOME="$HOME_ROOT" "$HV" engine' scripts/native-ipv6-gate.sh >/dev/null \
  || fail "native IPv6 qualification does not bind data-drive validation to its isolated home"
grep -F 'HOME="$TEST_HOME" "$VMM"' scripts/vz-native-ipv6-gate.sh >/dev/null \
  || fail "VZ IPv6 qualification does not bind data-drive validation to its isolated home"
grep -F 'observeRootsOnDemand: true' \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift >/dev/null \
  || fail "production host shares returned to whole-root FSEvents observation"
grep -F 'notifyEventObservation(for: relative)' \
  Packages/ContainerizationEngine/Sources/DoryHV/Fuse/HostFS.swift >/dev/null \
  || fail "host lookup no longer arms narrow observation before namespace stat"
for fsevent_budget in fseventsd_rss_growth_mb fseventsd_cpu_percent; do
  grep -F "$fsevent_budget" scripts/endurance-reliability-soak.sh \
    scripts/verify-release-qualification.sh >/dev/null \
    || fail "exact endurance publication omits $fsevent_budget"
done
for data_drive_guard in protectedLocation unsupportedLocation MNT_LOCAL 'type == "apfs"'; do
  grep -F "$data_drive_guard" dory-core-swift/Sources/DoryOperations/DoryDataDrive.swift >/dev/null \
    || fail "managed data drive lost fail-closed guard: $data_drive_guard"
done
for data_drive_recovery_guard in \
  running_dory_hv_uses_drive \
  lost_drive_identity_recovered \
  lost_drive_identity_mismatch_rejected \
  alternate_drive_untouched \
  first_launch_resume_before_drive \
  first_launch_resume_after_drive \
  first_launch_identity_mismatch_rejected \
  unwritable_drive_rejected_cleanly \
  alias_concurrent_attach_rejected \
  manifest_uuid_identity \
  stopped_missing_selected_drive_rejected \
  durable_selection_survives_runtime_reset; do
  grep -F "$data_drive_recovery_guard" scripts/runtime/dory-engine \
    scripts/managed-data-drive-gate.sh scripts/qualify-release-candidate.sh \
    scripts/verify-release-qualification.sh >/dev/null \
    || fail "managed data-drive qualification omits $data_drive_recovery_guard"
done
grep -F 'scripts/gvproxy-qemu-switch-gate.py' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the exact-artifact bidirectional LAN switch gate"
grep -F 'gvproxyQEMUSwitchGate' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification does not record and verify the independent LAN switch port"
grep -F '"nativeIPv6Gate": "PASS"' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification does not record and verify native IPv6"
grep -F 'scripts/data-drive-volume-identity-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits APFS data-drive volume identity"
grep -F 'dataDriveVolumeIdentityGate' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification does not publish APFS data-drive volume identity"
grep -F -- '--require-external' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification permits IPv6 proof without a real external route"
grep -F 'body["EnableIPv6"] as? Bool == true' DoryTests/MigrationTests.swift >/dev/null \
  || fail "migration regression tests do not preserve a source network's native IPv6 contract"
if grep -F 'native IPv6 networks are not supported' Dory/Runtime/MigrationAssistant.swift >/dev/null; then
  fail "migration still rejects native IPv6 networks"
fi
if grep -F -- '--legacy-data-disk' scripts/runtime/dory-engine \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift \
  Packages/ContainerizationEngine/Sources/dory-hv/main.swift >/dev/null; then
  fail "public-v1 runtime still exposes a prelaunch Dory disk-adoption interface"
fi
grep -F 'dory-dataplane-proxy" --listen "$SOCK" --backend "$BACKEND_SOCK"' \
  scripts/runtime/dory-engine >/dev/null \
  || fail "headless runtime bypasses the Docker-create compatibility dataplane"
grep -F 'dory-dataplane-proxy' scripts/bundle-engine.sh scripts/release.sh >/dev/null \
  || fail "headless dataplane proxy is not part of the signed bundle/release contract"
grep -F 'EngineStateDirectoryLock(stateDirectory: state)' \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift >/dev/null \
  || fail "dory-hv does not exclusively lock persistent engine state before mounting its data disk"
grep -F 'EngineStateDirectoryLock(stateDirectory: stateDirectory)' \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null \
  || fail "dory-vmm does not exclusively lock persistent engine state before mounting its data disk"
grep -F 'engine requires explicit --state-dir' \
  Packages/ContainerizationEngine/Sources/dory-hv/main.swift >/dev/null \
  || fail "dory-hv still permits an implicit persistent state directory"
grep -F 'mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc' \
  scripts/nonnative-build-smoke.sh scripts/readiness.sh >/dev/null \
  || fail "non-native readiness probes do not mount their container-local binfmt_misc view"
if grep -Eq 'find_qemu_static|inject_qemu_into_initfs|DORY_QEMU_(X86_64|AARCH64)_STATIC' \
    scripts/bundle-engine.sh; then
  fail "app bundling can still depend on or inject an unpinned host qemu-user runtime"
fi
python3 - <<'PY'
from pathlib import Path
import re

unsafe_boundary = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
failures = []
for path in Path("scripts").rglob("*.sh"):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = unsafe_boundary.search(line)
        if match:
            failures.append(f"{path}:{line_number}: {match.group()!r}")
if failures:
    raise SystemExit(
        "unbraced shell variable touches non-ASCII text and may become a locale-dependent name:\n"
        + "\n".join(failures)
    )
PY
grep -F 'runtime_mount="$(awk "\$2 == \"/run/dory-fex\"' \
  scripts/nonnative-mmdebstrap-gate.sh >/dev/null \
  || fail "mmdebstrap post-build mount verification can escape its container shell quoting"
grep -F 'same-inode-shrink' scripts/bind-file-coherence-gate.sh >/dev/null \
  || fail "bind coherence gate lost the stale-size shrink reproduction"
for bind_file_contract in direct_single_file_bind direct_single_file_recreate_cycles path_with_spaces; do
  grep -F "$bind_file_contract" scripts/bind-file-coherence-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "final qualification omits bind-file contract: $bind_file_contract"
done
grep -F 'scripts/bind-file-coherence-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "final qualification does not execute the bind-file coherence gate"
grep -F 'chmod 0777 /share/test' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor bind-create fixture is not prepared through the guest bind"
grep -F 'bind-special-file-fail-fast' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate lost the nonblocking host-FIFO regression"
grep -F 'while [ "$i" -lt 10000 ]' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate no longer crosses the external-share FD leak threshold"
grep -F 'bind-hardlink-permissions' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate lost restrictive hard-link reads"
for host_port_preflight in scripts/competitor-runtime-regression-gate.sh \
  scripts/verify-release-qualification.sh; do
  grep -F 'host-port-collision' "$host_port_preflight" >/dev/null \
    || fail "$host_port_preflight lost occupied macOS host-port rejection and recovery"
done
grep -F 'cleanup-restart-persistence' scripts/competitor-runtime-regression-gate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification no longer proves Docker-object deletions survive engine restart"
for start_preflight in dory-core/dataplane/src/classify.rs dory-core/dataplane/src/serve.rs; do
  grep -F 'ContainerStartPreflight' "$start_preflight" >/dev/null \
    || fail "$start_preflight allows Docker container starts to bypass macOS host-port preflight"
done
grep -F 'container_start_preflight_fails_closed_when_inspect_transport_fails' \
  dory-core/dataplane/src/serve.rs >/dev/null \
  || fail "container start preflight can fail open when dockerd inspection is unavailable"
grep -F 'container_lifecycle_contract_preserves_routes_and_queries' \
  dory-core/dataplane/src/classify.rs >/dev/null \
  || fail "Docker container lifecycle routes no longer retain their byte-transparent contract"
grep -F 'pass container-api-lifecycle' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate lost the bounded complete container lifecycle proof"
grep -F 'container-api-lifecycle' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "exact release qualification no longer requires the complete container lifecycle proof"
grep -F 'pass volume-api-lifecycle' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate lost the complete volume lifecycle proof"
for volume_contract in \
  'dev.dory.volume-contract=original' \
  'same-name create mutated existing volume metadata' \
  'in-use named volume was removed' \
  'explicit volume removal failed or exceeded ten seconds'; do
  grep -F "$volume_contract" scripts/competitor-runtime-regression-gate.sh >/dev/null \
    || fail "competitor runtime gate lost volume contract: $volume_contract"
done
grep -F 'volume-api-lifecycle' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "exact release qualification no longer requires the complete volume lifecycle proof"
grep -F 'pass network-api-lifecycle' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "competitor runtime gate lost the complete network lifecycle proof"
for network_contract in \
  'dev.dory.network-contract=original' \
  'duplicate create mutated existing network metadata' \
  'in-use network was removed' \
  'static-IP alias connect'; do
  grep -F "$network_contract" scripts/competitor-runtime-regression-gate.sh >/dev/null \
    || fail "competitor runtime gate lost network contract: $network_contract"
done
grep -F 'network-api-lifecycle' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "exact release qualification no longer requires the complete network lifecycle proof"
grep -F 'os.O_CREAT | os.O_EXCL | os.O_RDONLY' scripts/bind-advisory-lock-probe.py >/dev/null \
  || fail "bind gate lost the exact mode-0000 exclusive-create reproduction"
grep -F 'create_excl_readonly_mode0000_unlink=PASS' scripts/bind-advisory-lock-gate.sh \
  scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
  || fail "exact release paths no longer require mode-0000 create/unlink proof"
grep -F 'ISOLATED-DORY-MACHINE-RESOURCES' scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate is not fail-closed to an isolated owned machine"
grep -F 'ISOLATED-EXTERNAL-APFS-BIND' scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external APFS gate is not fail-closed to an isolated physical volume"
grep -F 'test path is not on an external physical volume' scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external bind gate can qualify an internal/System volume"
grep -F 'DISCONNECT-RECONNECT-DEDICATED-APFS' scripts/external-volume-bind-gate.sh \
  scripts/release-candidate-live-smoke.sh >/dev/null \
  || fail "external APFS gate can skip physical disconnect/reconnect authorization"
grep -F 'DORY-DEDICATED-RELEASE-APFS-V1' scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external APFS gate can unmount an operator-unmarked volume"
grep -F 'diskutil unmount "$device_identifier"' scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external APFS gate does not actually detach the target volume"
grep -F 'missing_drive_rejected=PASS' scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external APFS gate does not retain missing-drive fail-closed evidence"
grep -F 'missing external volume created an internal shadow path' \
  scripts/external-volume-bind-gate.sh >/dev/null \
  || fail "external APFS gate does not reject internal shadow writes while detached"
grep -F 'ISOLATED-DORY-BIND-LOCKS' scripts/bind-advisory-lock-gate.sh >/dev/null \
  || fail "bind advisory-lock gate is not fail-closed to an isolated engine"
grep -F 'upgrade-holder' scripts/bind-advisory-lock-gate.sh \
  scripts/bind-advisory-lock-probe.py >/dev/null \
  || fail "bind advisory-lock gate lost the contended upgrade regression"
if grep -F 'flock-upgrade-retained-shared' scripts/bind-advisory-lock-gate.sh >/dev/null; then
  fail "bind advisory-lock gate requires an atomic conversion state that Linux flock does not promise"
fi
grep -F 'record-waiter' scripts/bind-advisory-lock-gate.sh >/dev/null \
  || fail "bind advisory-lock gate lost the blocking POSIX lock regression"
grep -F 'seq 1 1500' scripts/bind-advisory-lock-gate.sh >/dev/null \
  || fail "bind advisory-lock gate no longer tolerates a clean-boot fixture unpack"
grep -F 'DOCKER="$(command -v "$DOCKER")"' scripts/bind-advisory-lock-gate.sh >/dev/null \
  || fail "bind advisory-lock evidence can hash an unresolved Docker command name"
grep -F "grep -Eq '^[0-9a-f]{64}$'" scripts/bind-advisory-lock-gate.sh >/dev/null \
  || fail "bind advisory-lock evidence can pass without an exact Docker CLI digest"
grep -F 'case .getlk' Packages/ContainerizationEngine/Sources/DoryHV/Fuse/FuseServer.swift >/dev/null \
  || fail "FUSE server no longer handles GETLK"
grep -F 'case .setlkw' Packages/ContainerizationEngine/Sources/DoryHV/Fuse/FuseServer.swift >/dev/null \
  || fail "FUSE server no longer handles SETLKW"
grep -F 'case .interrupt' Packages/ContainerizationEngine/Sources/DoryHV/Fuse/FuseServer.swift >/dev/null \
  || fail "blocking bind locks are no longer interruptible"
grep -F 'scripts/bind-advisory-lock-gate.sh' scripts/release-candidate-live-smoke.sh \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "exact release paths omit the live cross-container bind-lock gate"
for clean_user_gate in \
  scripts/release-candidate-live-smoke.sh \
  scripts/sparkle-install-relaunch-gate.sh; do
  grep -F 'APP_SUPPORT="$HOME/Library/Application Support/Dory"' "$clean_user_gate" \
    >/dev/null \
    || fail "clean-user release gate checks the wrong managed data-drive root: $clean_user_gate"
  if grep -F 'APP_SUPPORT="$HOME/Library/Application Support/com.pythonxi.Dory"' \
      "$clean_user_gate" >/dev/null; then
    fail "clean-user release gate still uses the obsolete bundle-ID state root: $clean_user_gate"
  fi
done
grep -F 'env HOME="$ENGINE_HOME" scripts/bind-advisory-lock-gate.sh' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "isolated release qualifier runs the bind-lock gate outside its shared engine HOME"
grep -F 'HostSSHAgentBridge' Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift >/dev/null \
  || fail "raw Hypervisor.framework runtime does not attach the host SSH-agent bridge"
grep -F 'DoryVZHostSSHAgentBridge' dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null \
  || fail "Virtualization.framework runtime does not attach the host SSH-agent bridge"
grep -F '/run/host-services/ssh-auth.sock' dory-core/agent/src/vsock_server.rs \
  scripts/ssh-agent-forwarding-gate.sh >/dev/null \
  || fail "guest agent and live gate do not share the fixed SSH-agent socket contract"
grep -F 'MAX_CONCURRENT_SSH_AGENT_CONNECTIONS' dory-core/agent/src/vsock_server.rs >/dev/null \
  || fail "guest SSH-agent bridge has no connection-exhaustion bound"
grep -F 'scripts/ssh-agent-forwarding-gate.sh' scripts/release-candidate-live-smoke.sh \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "exact release paths omit the live SSH-agent forwarding gate"
grep -F -- '--mount=type=ssh,required=true' scripts/ssh-agent-forwarding-gate.sh >/dev/null \
  || fail "SSH-agent gate no longer proves BuildKit required SSH mounts"
grep -F 'buildkit_public_key_listing_sha256' scripts/ssh-agent-forwarding-gate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "BuildKit and ordinary SSH-agent identity proofs are not publication-bound"
for ssh_buildx_contract in 'BUILDX="$(dirname "$DOCKER")/docker-buildx"' \
  'DOCKER_CONFIG="$WORKDIR/docker-config"' bundled_buildx buildx_sha256; do
  grep -F "$ssh_buildx_contract" scripts/ssh-agent-forwarding-gate.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "SSH-agent qualification omits exact bundled Buildx contract: $ssh_buildx_contract"
done
grep -F 'sshAgentForwardingGate' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification does not record and verify SSH-agent forwarding"
grep -F 'machine update "$MACHINE" --cpus 8 --memory-mb 16384' \
  scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate no longer reaches the advertised CPU/memory maximum"
if grep -F 'local label="$1" cpus="$2" memory="$3" status=' \
    scripts/machine-resource-reconfiguration-gate.sh >/dev/null; then
  fail "machine resource gate references a strict-mode local before it is initialized"
fi
grep -F 'did not become ready within 180 seconds' \
  scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate no longer waits for asynchronous VMM readiness"
grep -F 'machine update "$MACHINE" --cpus 9' \
  scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate no longer proves out-of-contract CPU rejection"
grep -F 'ctl machine stats "$MACHINE"' \
  scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate no longer proves first-class guest statistics"
grep -F '"dev.dory.machine.stats"' \
  scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "machine resource gate no longer validates the versioned machine-stats contract"
grep -F 'required_provisioning=PASS' scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "exact-candidate machine gate no longer requires successful provisioning"
grep -F 'kubectl version --client=true' scripts/machine-resource-reconfiguration-gate.sh >/dev/null \
  || fail "exact-candidate machine provisioning lacks independent verification"
grep -F 'lima-vm/lima/issues/5225' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Lima's silent machine provisioning failure"
for runtime_regression in nested-bind-subvolume buildkit-relative-temp-context \
  network-api-lifecycle network-alias-restart-ip named-volume-empty named-volume-cp \
  volume-api-lifecycle dockerignore-layered-unignore \
  buildkit-default-arg 'ARG TAG="${TAG:-latest}"' \
  image-save-stdout 'nonzero bytes follow the tar EOF records' \
  image-hardlink-missing-parent 'link to bin/app' \
  buildkit-concurrent-sessions buildkit-large-dockerfile seccomp-profile \
  'SCMP_ACT_ERRNO' '65536' named-signal-delivery '--signal USR1' \
  container-dns-search '--dns-search dev.dory.test' bind-mount-option-contract \
  'unsupported nosuid bind option was silently accepted' \
  'parallel_pids+=("$!")' \
  'anonymous child volume leaked' '--secret id=fixture,src=secret.txt'; do
  grep -F -- "$runtime_regression" scripts/competitor-runtime-regression-gate.sh >/dev/null \
    || fail "competitor runtime gate lost $runtime_regression"
done
for publication_runtime_regression in named-volume-empty buildkit-default-arg \
  image-save-stdout image-hardlink-missing-parent; do
  grep -F -- "$publication_runtime_regression" scripts/verify-release-qualification.sh >/dev/null \
    || fail "release publication no longer requires $publication_runtime_regression"
done
for nonnative_regression in "tar --version | grep -q 'GNU tar'" /tmp/tar-source/a/b/c \
  /tmp/tar-output/a/b/c/hardlink.txt; do
  grep -F -- "$nonnative_regression" scripts/nonnative-build-smoke.sh >/dev/null \
    || fail "non-native release gate lost $nonnative_regression"
done
grep -F 'ingress_only_network_policy_egress=PASS' \
  scripts/kubernetes-tooling-compatibility-gate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "nested Kubernetes gate no longer proves ingress-only policy egress"
grep -F 'standalone bind fixture workroot must be inside runtime HOME' \
  scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "standalone competitor gate can mistake an unshared guest path for a host bind"
grep -F -- '--source-commit "$SOURCE_COMMIT"' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "exact release qualification does not bind competitor evidence to its source commit"
grep -F 'source_commit=$SOURCE_COMMIT' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release qualification does not verify competitor evidence source identity"
for standalone_setting in 'SETTINGSFILE="$STATE/engine-settings"' '--no-amd64' \
  'amd64_enabled=1' 'DATA_DRIVE="$recorded_drive"' \
  'restart-policy container did not resume within 20 seconds'; do
  grep -F -- "$standalone_setting" scripts/runtime/dory-engine \
    scripts/competitor-runtime-regression-gate.sh >/dev/null \
    || fail "standalone restart contract lost $standalone_setting"
done
grep -F 'Wait.forHttp("/", 8080)' scripts/testcontainers-compatibility-gate.sh >/dev/null \
  || fail "Testcontainers HTTP wait strategy lost its required container port"
grep -F 'docker_e ps -aq 2>/dev/null | while IFS= read -r id' \
  scripts/testcontainers-compatibility-gate.sh >/dev/null \
  || fail "interrupted Testcontainers cleanup is not exhaustive on its isolated engine"
grep -F '[signed machine-image contract](MACHINE_IMAGE_CONTRACT.md)' README.md >/dev/null \
  || fail "the public README does not surface the signed machine-image contract"
grep -F 'dory machine create baseline' MACHINE_IMAGE_CONTRACT.md >/dev/null \
  || fail "the machine-image contract lost its supported bundled baseline recipe"
for required_recipe in \
  'guest/kernel/build.sh arm64' \
  'guest/initfs/build.sh arm64' \
  'guest/kernel/verify-build.sh arm64' \
  'guest/initfs/verify-build.sh arm64' \
  'guest/kernel/build.sh amd64' \
  'guest/initfs/build.sh amd64' \
  'guest/kernel/verify-build.sh amd64' \
  'guest/initfs/verify-build.sh amd64' \
  '--kernel guest/out/Image' \
  '--kernel guest/out/bzImage-x86' \
  '--rootfs guest/out/initfs-arm64.ext4' \
  '--rootfs guest/out/initfs-amd64.ext4'; do
  grep -F -- "$required_recipe" MACHINE_IMAGE_CONTRACT.md >/dev/null \
    || fail "the public supported machine-image recipe lost: $required_recipe"
done
grep -F '128 * 1024 * 1024 * 1024' dory-core-swift/Sources/DoryOperations/DockerDataDisk.swift >/dev/null \
  || fail "the shared Docker data disk regressed below the sparse 128 GiB release capacity"
grep -F 'invalidExistingDisk' dory-core-swift/Sources/DoryOperations/DockerDataDisk.swift >/dev/null \
  || fail "an existing allocated non-ext4 Docker disk can reach first-boot formatting instead of failing closed"
python3 - dory-core-swift/Sources/DoryOperations/DockerDataDisk.swift <<'PY' \
  || fail "an ext4-magic file with invalid geometry can be enlarged before corruption is rejected"
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
existing = source[source.index("if try pathEntryExists"):source.index("try fileManager.createDirectory")]
assert existing.index("try validateContents") < existing.index("ftruncate(descriptor")
PY
grep -F 'engineDiskUsableBytes: Int64 = 120 * 1024 * 1024 * 1024' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "migration admission trusts sparse logical length instead of the guest-proven ext4 capacity"
for resize_source in \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift \
  guest/initfs/init; do
  grep -F 'resize2fs /dev/vdb' "$resize_source" >/dev/null \
    || fail "existing ext4 Docker data disks are not expanded by $resize_source"
done
for boot_source in \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift; do
  grep -F 'FORMAT-PROVEN-BLANK' "$boot_source" >/dev/null \
    || fail "Docker disk formatting is not gated by host-proven blank state in $boot_source"
  grep -F 'MOUNT-FAILED-EXISTING-EXT4' "$boot_source" >/dev/null \
    || fail "an existing ext4 mount failure does not fail closed in $boot_source"
done
if grep -F '"  dory_mount_docker_data || { echo DATA-DISK-FORMAT' \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null; then
  fail "an existing ext4 mount failure can still fall through to destructive formatting"
fi
grep -F 'refusing to start dockerd without its persistent data disk' guest/initfs/init >/dev/null \
  || fail "generic guest init can start dockerd after the persistent data disk fails to mount"
for trim_source in \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  dory-core-swift/Sources/DoryCore/GuestShutdownCommand.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift \
  guest/initfs/init; do
  grep -F 'fstrim -v /var/lib/docker' "$trim_source" >/dev/null \
    || fail "free ext4 blocks are not returned to the host by $trim_source"
done
if grep -F -- '--default-runtime crun' \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift guest/initfs/init >/dev/null; then
  fail "crun became Docker's default again even though docker update is incompatible with crun 1.28"
fi
for runtime_source in Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift guest/initfs/init; do
  grep -F -- '--add-runtime crun=/usr/local/bin/crun' "$runtime_source" >/dev/null \
    || fail "explicit crun opt-in registration disappeared from $runtime_source"
done
grep -F 'kill -TERM $DORY_DOCKERD_PID' guest/initfs/init >/dev/null \
  || fail "generic guest init can power off without first quiescing dockerd"
for resize_source in \
  Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift \
  guest/initfs/init; do
  grep -F 'blockdev --getsize64 /dev/vdb' "$resize_source" >/dev/null \
    || fail "Docker data resize still runs without a device/filesystem geometry guard in $resize_source"
  grep -F 'e2fsck -f -p /dev/vdb' "$resize_source" >/dev/null \
    || fail "Docker data resize can run without the forced offline preen required after prior mounts in $resize_source"
done
grep -F 'sparse_allocation=PASS' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate does not prove 128 GiB remains sparsely allocated on the host"
grep -F '"$RUNTIME/bin/dory-hv" data-drive select' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate does not use the public runtime archive layout"
grep -F 'DORY_DATA_DISK_RUNTIME_HOME:-$HOME/.ddg-$$' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate can exceed the macOS Unix socket path limit"
grep -F 'home="$HOME/.dcs-$$-$cycle"' scripts/headless-cold-start-soak.sh >/dev/null \
  || fail "the cold-start gate can exceed the macOS Unix socket path limit"
grep -F 'discard_reclaim=PASS' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate does not prove deleted ext4 blocks are returned to the host"
grep -F 'explicit_capacity_growth=PASS' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate does not prove the user-controlled 256 GiB path"
grep -F 'data-drive grow 256' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate bypasses the public capacity helper"
grep -F 'running_growth_rejected=PASS' scripts/data-disk-growth-gate.sh >/dev/null \
  || fail "the data-disk growth gate does not prove running-drive mutation is rejected"
grep -F 'guard discardEnabled else { return .unsupported }' Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift >/dev/null \
  || fail "virtio-blk accepts discard/write-zeroes requests while the feature is disabled"
grep -F 'segmentEntries <= Int(Discard.maxSegments) - entryCount' Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift >/dev/null \
  || fail "virtio-blk does not enforce its advertised discard segment limit"
grep -F 'numSectors <= UInt64(Discard.maxSectors)' Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift >/dev/null \
  || fail "virtio-blk does not enforce its advertised per-range discard limit"
grep -F 'e2fsprogs-extra_arm64' guest/initfs/PINS >/dev/null \
  || fail "arm64 guest resize2fs artifact is not provenance-pinned"
grep -F 'e2fsprogs-extra_amd64' guest/initfs/PINS >/dev/null \
  || fail "amd64 guest resize2fs artifact is not provenance-pinned"
grep -F 'st.st_blocks * 512' scripts/dory-doctor >/dev/null \
  || fail "doctor reports sparse VM logical capacity as physical host usage"
for prepared_asset_contract in \
  'withAssetPreparationLock' \
  'removeAbandonedAssetPartials' \
  'compressedResourceIdentity' \
  'Darwin.rename(temporary.path, output.path)'; do
  grep -F "$prepared_asset_contract" dory-core-swift/Sources/DorydKit/DorydConfiguration.swift >/dev/null \
    || fail "bundled rootfs preparation lost contract: $prepared_asset_contract"
done
for prepared_asset_test in \
  'testDockerTierRemovesOnlyAbandonedPartialsForItsPreparedRootfs' \
  'testConcurrentDockerTierPreparationPublishesOneCompleteRootfsAndNoPartials' \
  'testDockerTierRefreshesPreparedRootfsWhenCompressedContentChangesWithoutNewerMtime'; do
  grep -F "$prepared_asset_test" dory-core-swift/Tests/DorydKitTests/DorydConfigurationTests.swift >/dev/null \
    || fail "bundled rootfs preparation lost regression: $prepared_asset_test"
done
grep -F 'removesAbandonedPartialEvenWhenPristineAndStampAreCurrent' \
  Packages/ContainerizationEngine/Tests/DoryHVTests/RootfsPristineRefreshTests.swift >/dev/null \
  || fail "dory-hv pristine-rootfs refresh can leak an interrupted partial forever"
if grep -F "Volume **data** isn't copied automatically" Dory/Features/Settings/SettingsView.swift >/dev/null; then
  fail "migration UI still incorrectly claims that named-volume data is not copied"
fi
grep -F 'through read-only source mounts' Dory/Features/Settings/SettingsView.swift >/dev/null \
  || fail "migration UI does not explain the source-safe named-volume copy contract"
grep -F 'comparisonRow("Common x86 / amd64 images", .yes, .yes, .yes' \
  Dory/Features/Settings/SettingsView.swift >/dev/null \
  || fail "Apple Silicon comparison does not present the tested common-amd64 contract as supported"
grep -F "built-in FEX runtime for amd64 images and BuildKit workloads, including nested seccomp sandboxes" \
  Dory/Features/Settings/SettingsView.swift >/dev/null \
  || fail "amd64 UI does not state the bundled FEX/nested-seccomp contract"
if grep -F 'case yes, no(String?), partial' Dory/Features/Settings/SettingsView.swift >/dev/null \
    || grep -E '\*\*(Partial|Gap)|Partial/strong|Gap/gate' COMPETITOR_ISSUE_COVERAGE.md >/dev/null; then
  fail "competitive strategy reintroduced a partial-support tier"
fi
grep -F '**LAUNCH BLOCKER' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitive strategy can no longer block publication on unfinished Apple Silicon coverage"
if grep -F '"~/Library/Application Support/Dory"' Casks/dory.rb >/dev/null; then
  fail "Homebrew zap can erase the managed workload data drive"
fi
cmp -s Casks/dory.rb ../homebrew-dory/Casks/dory.rb \
  || fail "the primary and tap Homebrew casks diverged"
grep -F 'func migrationSnapshot() async throws -> RuntimeSnapshot' \
  Dory/Runtime/ContainerRuntime.swift Dory/Runtime/Docker/DockerEngineRuntime.swift >/dev/null \
  || fail "migration inventory can silently downgrade a failed Docker object endpoint to empty"
grep -F 'func migrationContainerWritableSizes() async throws -> [String: Int64]' \
  Dory/Runtime/ContainerRuntime.swift Dory/Runtime/Docker/DockerEngineRuntime.swift >/dev/null \
  || fail "container writable-layer data is absent from strict migration inventory"
grep -F 'dory-migration/container-snapshot:' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "containers are recreated from base images without preserving writable-layer changes"
grep -F 'kind: "rollback"' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "reserved writable-layer rollback tags can collide with unrelated target images"
grep -F 'runningWritableLayerContainers' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "running changed container filesystems can be snapshotted inconsistently"
grep -F 'target volume was not created' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "volume migration can create an empty target when no safe helper image exists"
grep -F 'cleanup of partial volume failed' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "failed volume extraction does not report transactional target cleanup"
grep -F 'sourceNetworkObjects' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "custom network contracts are not captured before the first migration write"
grep -F 'runningVolumeBackedContainers' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "migration can copy a live writable named volume without a quiescence decision"
grep -F 'runningContainerUsesVolume' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "named-volume quiescence is not rechecked immediately before copying"
grep -F '$0.type == "volume" && !$0.readOnly' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "read-only source volume consumers are unnecessarily treated as active writers"
grep -F 'guard let writable = mount["RW"] as? Bool else { return nil }' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "live volume quiescence can fail open when Docker omits mount write mode"
grep -F 'SHA256.hash' Dory/Runtime/Docker/DockerEngineRuntime.swift >/dev/null \
  || fail "same-source retry ownership uses a collision-prone socket identifier"
grep -F 'portabilityFailures(for: spec' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "nonportable container contracts can fail only after target mutation"
grep -F 'saveImageThrowing' Dory/Runtime/Docker/DockerEngineRuntime.swift Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "image migration still treats a truncated source archive as a complete stream"
grep -F 'successfulBodyStream' Dory/Runtime/Docker/DockerEngineRuntime.swift \
  Dory/Runtime/Transport/UnixSocketHTTP.swift >/dev/null \
  || fail "multi-gigabyte migration archives are not demand-driven"
grep -F 'namedVolumeSizes(on:' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "migration volume capacity is not matched to the strict inventory by name"
grep -F 'targetCollisionBlockers' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "same-name target objects can still become an image-only partial import before the UI blocks"
grep -F 'replaceableEmptyTargetVolumeNames' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "empty detached target volumes cannot be adopted without destructive manual cleanup"
grep -F 'original empty target volume was restored' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "a failed empty-volume adoption can erase the target's original metadata"
grep -F 'original detached target network was restored' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "a failed source-network replacement can erase the target's original contract"
grep -F 'imageContractsMatch' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "daemon-normalized image IDs cannot be verified without weakening tag collisions"
grep -F 'hostDiskPreflightAvailable' Dory/Runtime/MigrationAssistant.swift >/dev/null \
  || fail "migration host-capacity metadata can fail open"
grep -F 'concurrent-proxy-backpressure' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "runtime gate lost concurrent proxy backpressure isolation coverage"
grep -F 'range(12)' scripts/competitor-runtime-regression-gate.sh >/dev/null \
  || fail "runtime gate no longer probes unrelated Docker requests concurrently"
grep -F 'ENGINE_HOME="$HOME/.dqe-$RUN_ID-$RUN_ATTEMPT"' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification can exceed the macOS Unix socket path limit"
grep -F -- '--workroot "$ENGINE_HOME/gate-evidence/endurance"' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release endurance bind fixtures are outside the standalone runtime shared HOME"
grep -F 'TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock' \
  scripts/dory-doctor scripts/testcontainers-compatibility-gate.sh >/dev/null \
  || fail "Testcontainers/Ryuk is not routed to Dory's guest-local Docker socket"
grep -F 'scripts/testcontainers-compatibility-gate.sh' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the pinned Testcontainers/Ryuk gate"
grep -F -- '--workroot "$ENGINE_HOME/gate-evidence/testcontainers"' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification does not retain Testcontainers evidence"
grep -F 'act --container-daemon-socket unix:///var/run/docker.sock' scripts/dory-doctor >/dev/null \
  || fail "act recipe mounts the macOS proxy path instead of the daemon's guest-local socket"
grep -F 'scripts/act-compatibility-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the real act workflow gate"
grep -F 'loopback_only_listener=PASS' scripts/localstack-compatibility-gate.sh >/dev/null \
  || fail "LocalStack gate does not prove requested loopback ports stay off LAN interfaces"
grep -F 'normalize_dory_socket_mounts(hc);' dory-core/dataplane/src/create_rewrite.rs >/dev/null \
  || fail "Supabase compatibility does not rewrite Vector's Dory proxy bind to the guest-local socket"
grep -F 'unset DOCKER_SOCKET_LOCATION' scripts/supabase-compatibility-gate.sh >/dev/null \
  || fail "Supabase gate still depends on a CLI socket override instead of Dory compatibility"
grep -F 'keepalive_create_after_streamed_image_pull_is_still_rewritten' \
  dory-core/dataplane/src/serve.rs >/dev/null \
  || fail "Docker SDK create requests after a streamed pull can bypass Dory rewrites"
grep -F 'scripts/supabase-compatibility-gate.sh' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the full default Supabase gate"
grep -F '"supabaseGate": "PASS"' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release completion does not record the Supabase result"
grep -F 'scripts/kubernetes-tooling-compatibility-gate.sh' \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification omits the k3s/Skaffold/Tilt Kubernetes gate"
grep -F '"kubernetesToolingGate": "PASS"' scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release completion does not record the Kubernetes tooling result"
grep -F -- '--delete-namespaces' scripts/kubernetes-tooling-compatibility-gate.sh >/dev/null \
  || fail "Tilt Kubernetes cleanup leaves its namespace behind"
grep -F 'loopback_only_nodeport_listener=PASS' \
  scripts/kubernetes-tooling-compatibility-gate.sh >/dev/null \
  || fail "Kubernetes tooling gate does not prove NodePort remains loopback-only"
grep -F 'engine-health-after-k3s-pull.txt' \
  scripts/kubernetes-tooling-compatibility-gate.sh >/dev/null \
  || fail "Kubernetes tooling gate does not retain post-pull Dory health evidence"
grep -F 'trap cleanup EXIT' scripts/kubernetes-tooling-compatibility-gate.sh >/dev/null \
  || fail "Kubernetes tooling gate can resume after signal cleanup"
grep -F 'VZFileHandleNetworkDeviceAttachment' \
  dory-core-swift/Sources/DoryVMMKit/DoryVMMGVProxyNetwork.swift >/dev/null \
  || fail "the macOS 14 VZ fallback regressed to an IPv4-only NAT attachment"
grep -F 'ipv6Subnet: \(Self.virtualNetwork)' \
  dory-core-swift/Sources/DoryVMMKit/DoryVMMGVProxyNetwork.swift >/dev/null \
  || fail "the macOS 14 VZ fallback lost its native IPv6 gvproxy contract"
grep -F -- '"--gvproxy", gvproxy' \
  dory-core-swift/Sources/DorydKit/DorydConfiguration.swift >/dev/null \
  || fail "doryd no longer supplies the pinned gvproxy to the macOS 14 VZ fallback"
grep -F 'DoryVMMPortForwarder(' \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null \
  || fail "the macOS 14 VZ fallback no longer mirrors Docker published ports"
grep -F 'SO_NOSIGPIPE' dory-core-swift/Sources/DorydKit/DockerAPIProbe.swift >/dev/null \
  || fail "a closed Docker probe can terminate dory-vmm via SIGPIPE"
grep -F 'MSG_NOSIGNAL' dory-core-swift/Sources/DorydKit/VmmHandoff.swift \
  dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null \
  || fail "the VZ fallback handoff/splice paths lost SIGPIPE hardening"
grep -F -- '--require-sonoma' scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
  || fail "release certification does not require the VZ fallback on macOS 14"
grep -F -- '--require-external' scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
  || fail "Sonoma VZ certification can skip real external IPv6"
grep -F -- '--ssh-client-image' scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
  || fail "Sonoma VZ certification omits the digest-pinned SSH-agent fixture"
for proof in ssh_agent_forwarding ssh_agent_fresh_boot ssh_agent_restart; do
  grep -F "$proof" scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
    || fail "Sonoma VZ certification does not retain $proof"
done
grep -F 'sonoma_vz_certification' .github/workflows/release.yml >/dev/null \
  || fail "public release is not blocked by Sonoma VZ certification"
grep -F 'needs: [release_candidate, release_qualification, sonoma_vz_certification, source_preserving_lan_certification, homebrew_cask_audit, homebrew_install_certification]' \
  .github/workflows/release.yml >/dev/null \
  || fail "publication can bypass Sonoma VZ, physical source-preservation, or Homebrew certification"
grep -F 'source_preserving_lan_certification' .github/workflows/release.yml >/dev/null \
  || fail "public release is not blocked by physical LAN/Tailscale source-preservation certification"
grep -F 'sudo -n pmset relative wake "$AUTO_WAKE_SECONDS"' \
  scripts/host-network-integrity-gate.sh >/dev/null \
  || fail "physical sleep gate does not schedule an unattended hardware wake"
grep -F 'sudo -n pmset sleepnow' scripts/host-network-integrity-gate.sh >/dev/null \
  || fail "physical sleep gate does not invoke real system sleep"
grep -F 'sleep/wake Docker CLI differs from the exact candidate app' \
  scripts/host-network-integrity-gate.sh >/dev/null \
  || fail "physical sleep gate is not bound to the exact candidate Docker CLI"
for machine_session_contract in \
  'machine-session-pre-sleep' \
  'machine-session-reconnect' \
  'machine_ctl machine shell "$MACHINE"' \
  'machine_ctl machine exec "$MACHINE" --json' \
  'machine_ctl machine stop "$MACHINE"' \
  'machine_ctl machine start "$MACHINE"' \
  'dorydctl_sha256=' \
  'machine_kernel_sha256=' \
  'machine_rootfs_sha256='; do
  grep -F "$machine_session_contract" scripts/host-network-integrity-gate.sh >/dev/null \
    || fail "physical sleep gate omits machine session contract: $machine_session_contract"
done
grep -F 'machine_session_reconnect' scripts/verify-sleep-wake-evidence.py >/dev/null \
  || fail "physical sleep evidence verifier can ignore machine reconnect proof"
grep -F 'DORY_RELEASE_RUN_PHYSICAL_SLEEP' .github/workflows/release.yml \
  scripts/release-candidate-live-smoke.sh >/dev/null \
  || fail "notarized release candidate does not run physical sleep/wake"
grep -F 'Verify physical sleep/wake evidence binding' .github/workflows/release.yml >/dev/null \
  || fail "publication does not semantically verify physical sleep/wake evidence"
grep -F 'dory-live-release-evidence-${{ github.sha }}-${{ github.run_attempt }}' \
  .github/workflows/release.yml >/dev/null \
  || fail "physical sleep/wake evidence is not commit/rerun-bound"
for required_preflight in DORY_LAN_PEER_SSH DORY_LAN_HOST_IPV4 \
  DORY_TAILSCALE_PEER_SSH DORY_TAILSCALE_HOST_IPV4 DORY_SOURCE_GATE_IMAGE \
  DORY_RELEASE_ALPINE_IMAGE DORY_RELEASE_NONNATIVE_BUILD_IMAGE \
  DORY_TAILSCALE_EXIT_NODE; do
  sed -n '/release-configuration:/,/rust-workspace:/p' .github/workflows/release.yml \
    | grep -F "$required_preflight" >/dev/null \
    || fail "release credential preflight omits $required_preflight"
done
for route_churn_contract in --tailscale-exit-node --confirm-route-churn \
  route-churn-results.tsv tailscale_exit_node_sha256; do
  grep -F -- "$route_churn_contract" scripts/host-network-integrity-gate.sh \
    scripts/release-candidate-live-smoke.sh scripts/verify-sleep-wake-evidence.py \
    .github/workflows/release.yml >/dev/null \
    || fail "physical network qualification omits route-churn contract $route_churn_contract"
done
grep -F 'DORY_RELEASE_QUALIFICATION_IMAGE' .github/workflows/release.yml \
  scripts/qualify-release-candidate.sh >/dev/null \
  || fail "release qualification does not receive the digest-pinned fixture image"
for exact_release_script in scripts/release-candidate-live-smoke.sh \
  scripts/qualify-release-candidate.sh; do
  if grep -F 'alpine:latest' "$exact_release_script" >/dev/null; then
    fail "exact release path still contains a mutable Alpine tag: $exact_release_script"
  fi
done
for mode in lan tailscale; do
  grep -F -- "--mode $mode" .github/workflows/release.yml >/dev/null \
    || fail "release certification omits the $mode source-preservation path"
done
for proof in tcp_source_preserved udp_source_preserved interface_specific_privileged_tcp \
  privileged_tcp_unpublish_cleanup helper_restart_recovery \
  engine_restart_recovery pf_reference_cleanup ipv4_forwarding_cleanup \
  memory_pressure_source_preserved docker_dns_pressure configd_pressure_liveness \
  host_boot_session_unchanged host_panic_report_absence; do
  grep -F "$proof" scripts/source-preserving-lan-gate.sh .github/workflows/release.yml >/dev/null \
    || fail "source-preserving LAN certification does not prove $proof"
done
for option in --app --lan-host-address --lan-peer-ssh --tailscale-host-address \
  --tailscale-peer-ssh --source-server-image --source-privileged-port --source-confirm; do
  grep -F -- "$option" scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
    || fail "Sonoma VZ source-preservation certification omits $option"
done
for proof in lan_tcp_udp_source_preserved tailscale_tcp_udp_source_preserved \
  interface_specific_privileged_tcp source_helper_restart_recovery source_engine_restart_recovery \
  source_privileged_tcp_unpublish_cleanup \
  source_pf_reference_cleanup source_ipv4_forwarding_cleanup \
  source_memory_pressure_lan source_memory_pressure_tailscale \
  source_dns_pressure source_configd_pressure_liveness \
  host_boot_session_unchanged host_panic_report_absence; do
  grep -F "$proof" scripts/vz-native-ipv6-gate.sh >/dev/null \
    || fail "Sonoma VZ source-preservation certification does not prove $proof"
done
grep -F 'memory_pressure_mib=$PRESSURE_MIB' scripts/source-preserving-lan-gate.sh >/dev/null \
  && grep -F 'memory_pressure_rounds=$PRESSURE_ROUNDS' scripts/source-preserving-lan-gate.sh >/dev/null \
  && grep -F 'source_memory_pressure_mib="$SOURCE_PRESSURE_MIB"' scripts/vz-native-ipv6-gate.sh >/dev/null \
  && grep -F 'source_memory_pressure_rounds="$SOURCE_PRESSURE_ROUNDS"' scripts/vz-native-ipv6-gate.sh >/dev/null \
  || fail "physical source-preservation evidence omits bounded memory-pressure dimensions"
for host_survival_guard in host_boot_epoch_before host_boot_epoch_after \
  new-host-panic-reports.txt 'test ! -s'; do
  grep -F "$host_survival_guard" scripts/source-preserving-lan-gate.sh \
    scripts/vz-native-ipv6-gate.sh .github/workflows/release.yml >/dev/null \
    || fail "physical network certification omits host survival guard: $host_survival_guard"
done
for proof in healthy_pidfile_repair dead_dataplane_detected incomplete_runtime_poweroff \
  fresh_helper_pair docker_api_recovery standaloneSupervisorRecoveryGate; do
  grep -F "$proof" scripts/qualify-release-candidate.sh \
    scripts/verify-release-qualification.sh >/dev/null \
    || fail "final qualification omits standalone supervisor proof $proof"
done
grep -F 'public static let connectionMark = "0xd072"' \
  dory-core-swift/Sources/DoryCore/SourcePreservingLANPlan.swift >/dev/null \
  && grep -F 'CONNMARK --set-xmark \(connectionMark)/0xffffffff' \
  dory-core-swift/Sources/DoryCore/SourcePreservingLANPlan.swift >/dev/null \
  || fail "source-preserving replies are still selected by collision-prone client subnets"
grep -F 'ip route replace default via \(guestReturnGatewayIPv4) dev eth0 table \(policyRoutingTable)' \
  dory-core-swift/Sources/DoryCore/SourcePreservingLANPlan.swift >/dev/null \
  || fail "marked source-preserving replies have no overlap-safe policy route"
grep -Fx 'CONFIG_NETFILTER_XT_CONNMARK=y' guest/kernel/dory.config >/dev/null \
  || fail "guest kernel cannot retain source-preserving conntrack marks"
grep -Fx 'CONFIG_IP_MULTIPLE_TABLES=y' guest/kernel/dory.config >/dev/null \
  || fail "guest kernel cannot policy-route marked source-preserving replies"
python3 - <<'PY'
from pathlib import Path

swift = Path("dory-core-swift/Sources/DorydKit/NetworkingAuthorizationPlan.swift").read_text()
start = swift.index('let resolverContents = """')
payload = swift[start:].split('"""', 2)[1]
assert not any(line.strip().startswith("search ") for line in payload.splitlines()), \
    "doryd resolver plan contaminates the system-wide search list"

shell = Path("scripts/enable-networking.sh").read_text()
start = shell.index('sudo tee "/etc/resolver/$SUFFIX"')
payload = shell[start:].split("<<EOF", 1)[1].split("\nEOF", 1)[0]
assert not any(line.strip().startswith("search ") for line in payload.splitlines()), \
    "legacy resolver installer contaminates the system-wide search list"
PY

# Destructive/disruptive paths must fail during argument validation, before sockets, pmset, Docker,
# runtime helpers, or output directories can be touched.
if scripts/host-network-integrity-gate.sh --cycles 1 > "$TMP/sleep.out" 2> "$TMP/sleep.err"; then
  fail "physical sleep gate ran without the exact confirmation token"
fi
grep -q 'physical sleep requires' "$TMP/sleep.err"
for corporate_input in DORY_CORPORATE_DNS_SERVER DORY_CORPORATE_VPN_PROBE_HOST \
  DORY_CORPORATE_VPN_PROBE_URL; do
  grep -F "$corporate_input" scripts/release-candidate-live-smoke.sh \
    .github/workflows/release.yml >/dev/null \
    || fail "physical release workflow omits $corporate_input"
done
for corporate_contract in '--require-vpn' '--custom-dns "$CORPORATE_DNS"' \
  '--probe-host "$CORPORATE_PROBE_HOST"' '--probe-url "$CORPORATE_PROBE_URL"'; do
  grep -F -- "$corporate_contract" scripts/release-candidate-live-smoke.sh >/dev/null \
    || fail "physical sleep/VPN gate omits $corporate_contract"
done
if scripts/network-contract-gate.sh --require-lan-peer > "$TMP/lan.out" 2> "$TMP/lan.err"; then
  fail "LAN peer gate accepted missing peer/address/source-IP arguments"
fi
grep -q -- '--require-lan-peer needs --lan-address' "$TMP/lan.err"
if scripts/headless-cold-start-soak.sh --runtime "$TMP/missing" > "$TMP/cold.out" 2> "$TMP/cold.err"; then
  fail "cold-start gate accepted a missing runtime"
fi
grep -q 'runtime directory not found' "$TMP/cold.err"
if scripts/long-lived-network-soak.sh --socket "$TMP/missing.sock" --docker "$TMP/missing" --image alpine:3.20 \
    > "$TMP/long-lived.out" 2> "$TMP/long-lived.err"; then
  fail "25-hour TCP gate ran without the exact isolated-engine confirmation token"
fi
grep -q 'ISOLATED-ENGINE-LONG-LIVED-TCP' "$TMP/long-lived.err"
if scripts/nonnative-nix-gc-gate.sh \
    --socket "$TMP/missing.sock" --docker "$TMP/missing" \
    --image 'nixos/nix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    > "$TMP/nonnative-nix.out" 2> "$TMP/nonnative-nix.err"; then
  fail "non-native Nix GC gate ran without its exact confirmation token"
fi
grep -q 'ISOLATED-DORY-NONNATIVE-NIX-GC' "$TMP/nonnative-nix.err"
if scripts/nonnative-arch-pacman-gate.sh \
    --socket "$TMP/missing.sock" --docker "$TMP/missing" \
    --base-image 'archlinux@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    > "$TMP/nonnative-arch.out" 2> "$TMP/nonnative-arch.err"; then
  fail "non-native Arch pacman gate ran without its exact confirmation token"
fi
grep -q 'ISOLATED-DORY-NONNATIVE-ARCH-PACMAN' "$TMP/nonnative-arch.err"
if scripts/nonnative-mmdebstrap-gate.sh \
    --socket "$TMP/missing.sock" --docker "$TMP/missing" \
    --base-image 'debian@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    > "$TMP/nonnative-mm.out" 2> "$TMP/nonnative-mm.err"; then
  fail "non-native mmdebstrap gate ran without its exact confirmation token"
fi
grep -q 'ISOLATED-DORY-NONNATIVE-MMDEBSTRAP' "$TMP/nonnative-mm.err"
if scripts/nonnative-exec-conformance-gate.sh \
    --socket "$TMP/missing.sock" --docker "$TMP/missing" \
    --base-image 'debian@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    --native-image 'alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    > "$TMP/nonnative-exec.out" 2> "$TMP/nonnative-exec.err"; then
  fail "non-native exec gate ran without its exact confirmation token"
fi
grep -q 'ISOLATED-DORY-NONNATIVE-EXEC' "$TMP/nonnative-exec.err"
if scripts/ecr-registry-retry-gate.sh \
    --socket "$TMP/missing.sock" --docker "$TMP/missing" \
    --base-image 'alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    --registry 123456789012.dkr.ecr.us-east-1.amazonaws.com \
    --repository dory-release-retry --region us-east-1 \
    > "$TMP/ecr-retry.out" 2> "$TMP/ecr-retry.err"; then
  fail "managed ECR retry gate ran without its exact confirmation token"
fi
grep -q 'DISPOSABLE-ECR-INTERRUPT-RETRY' "$TMP/ecr-retry.err"
for machine_latency_contract in \
  'host.docker.internal' \
  'machine-to-docker-rtt.tsv' \
  'machine_service_p99_budget_ms=100' \
  'machine_service_sustained_budget_ms=150' \
  'machine_service_regular_200_400ms_plateau=ABSENT'; do
  grep -F "$machine_latency_contract" scripts/long-lived-network-soak.sh >/dev/null \
    || fail "25-hour gate omits machine-to-Docker latency contract: $machine_latency_contract"
done
for outbound_contract in machine-outbound-tcp.tsv machine_outbound_tcp \
  machine_outbound_failure_budget_per_mille machine_outbound_consecutive_failure_limit; do
  grep -F "$outbound_contract" scripts/long-lived-network-soak.sh \
    scripts/qualify-release-candidate.sh scripts/verify-release-qualification.sh >/dev/null \
    || fail "25-hour gate omits managed-machine outbound contract: $outbound_contract"
done
grep -F 'rancher-sandbox/rancher-desktop/issues/6943' COMPETITOR_ISSUE_COVERAGE.md >/dev/null \
  || fail "competitor coverage omits Rancher Desktop's intermittent outbound packet loss"
grep -F 'machineToDockerLongLivedGate' scripts/qualify-release-candidate.sh \
  scripts/verify-release-qualification.sh >/dev/null \
  || fail "release publication does not bind the machine-to-Docker duration gate"
grep -F 'orbstack/orbstack/issues/2587' COMPETITOR_ISSUE_COVERAGE.md RELEASE_READINESS.md >/dev/null \
  || fail "competitor coverage omits OrbStack's machine-to-Docker latency regression"
if scripts/qualify-release-candidate.sh \
    --build-dir "$TMP" --version 0.3.0 --build 1 \
    --source-commit 0123456789abcdef0123456789abcdef01234567 \
    > "$TMP/qualification.out" 2> "$TMP/qualification.err"; then
  fail "release qualification ran without the exact confirmation token"
fi
grep -q 'QUALIFY-EXACT-DORY-RELEASE' "$TMP/qualification.err"
if scripts/endurance-reliability-soak.sh --cycles 0 --duration 0 > "$TMP/endurance.out" 2> "$TMP/endurance.err"; then
  fail "endurance gate accepted zero work"
fi
grep -q 'duration or cycles must be positive' "$TMP/endurance.err"
if scripts/competitor-runtime-regression-gate.sh --connections 0 > "$TMP/compat.out" 2> "$TMP/compat.err"; then
  fail "runtime compatibility gate accepted zero forwarded connections"
fi
grep -q 'connections must be a positive integer' "$TMP/compat.err"
if scripts/competitor-runtime-regression-gate.sh \
    --source-commit not-a-commit > "$TMP/compat-source.out" 2> "$TMP/compat-source.err"; then
  fail "runtime compatibility gate accepted an invalid source commit"
fi
grep -q 'source commit must be a full lowercase Git SHA' "$TMP/compat-source.err"
if scripts/restart-pressure-soak.sh --duration 0 > "$TMP/pressure.out" 2> "$TMP/pressure.err"; then
  fail "restart pressure gate accepted zero duration"
fi
grep -q 'duration must be a positive integer' "$TMP/pressure.err"
if scripts/data-disk-growth-gate.sh > "$TMP/disk-growth.out" 2> "$TMP/disk-growth.err"; then
  fail "data-disk growth gate accepted missing exact runtime and Docker CLI"
fi
grep -q -- '--runtime is required' "$TMP/disk-growth.err"
if scripts/testcontainers-compatibility-gate.sh > "$TMP/testcontainers.out" 2> "$TMP/testcontainers.err"; then
  fail "Testcontainers gate accepted missing isolated socket/client/version"
fi
if scripts/devcontainers-compatibility-gate.sh > "$TMP/devcontainers.out" 2> "$TMP/devcontainers.err"; then
  fail "Dev Containers gate ran without its isolated-engine confirmation token"
fi
if scripts/act-compatibility-gate.sh > "$TMP/act.out" 2> "$TMP/act.err"; then
  fail "act gate ran without its isolated-engine confirmation token"
fi
if scripts/localstack-compatibility-gate.sh > "$TMP/localstack.out" 2> "$TMP/localstack.err"; then
  fail "LocalStack gate ran without its isolated-engine confirmation token"
fi
if scripts/tilt-compose-compatibility-gate.sh > "$TMP/tilt.out" 2> "$TMP/tilt.err"; then
  fail "Tilt gate ran without its isolated-engine confirmation token"
fi
if scripts/supabase-compatibility-gate.sh > "$TMP/supabase.out" 2> "$TMP/supabase.err"; then
  fail "Supabase gate ran without its isolated-engine confirmation token"
fi
if scripts/kubernetes-tooling-compatibility-gate.sh \
    > "$TMP/kubernetes-tooling.out" 2> "$TMP/kubernetes-tooling.err"; then
  fail "Kubernetes tooling gate ran without its isolated-engine confirmation token"
fi
grep -q -- '--socket is required' "$TMP/testcontainers.err"
if scripts/prune-safety-gate.sh > "$TMP/prune.out" 2> "$TMP/prune.err"; then
  fail "destructive prune gate ran without the exact confirmation token"
fi
grep -q 'ISOLATED-ENGINE-PRUNE' "$TMP/prune.err"

# The standalone supervisor must neither unlink a planted regular file at its public socket path
# nor trust a recycled/unrelated PID merely because it appears in a pidfile.
runtime="$TMP/runtime"
short_runtime_home="/tmp/dory-supervisor-test-$$"
rm -rf "$short_runtime_home"
runtime_home="$short_runtime_home"
runtime_arch=arm64
[ "$(uname -m)" = x86_64 ] && runtime_arch=amd64
mkdir -p "$runtime/bin" "$runtime/share/dory" "$runtime_home/.dory/standalone/vm"
cp scripts/runtime/dory-engine "$runtime/dory-engine"
chmod +x "$runtime/dory-engine"
for helper in dory-hv gvproxy dory-dataplane-proxy; do
  printf '#!/bin/sh\nexit 99\n' > "$runtime/bin/$helper"
  chmod +x "$runtime/bin/$helper"
done
printf 'kernel-asset\n' > "$runtime/share/dory/dory-hv-kernel-$runtime_arch.lzfse"
printf 'prepared-kernel\n' > "$runtime_home/.dory/standalone/vm/dory-hv-kernel-$runtime_arch"
touch "$runtime_home/.dory/standalone/vm/dory-hv-kernel-$runtime_arch"
printf 'do-not-delete\n' > "$runtime_home/.dory/engine.sock"
if HOME="$runtime_home" "$runtime/dory-engine" start > "$TMP/runtime-file.out" 2> "$TMP/runtime-file.err"; then
  fail "standalone runtime replaced a regular file planted at engine.sock"
fi
grep -q 'refusing to replace non-socket or symlink path' "$TMP/runtime-file.err"
grep -qx 'do-not-delete' "$runtime_home/.dory/engine.sock" \
  || fail "standalone runtime changed the planted engine.sock file"
printf '%s\n' "$$" > "$runtime_home/.dory/standalone/engine-cli.pid"
printf '%s\n' "$$" > "$runtime_home/.dory/standalone/dataplane-cli.pid"
if HOME="$runtime_home" "$runtime/dory-engine" status > "$TMP/runtime-pid.out" 2>&1; then
  fail "standalone runtime trusted unrelated recycled PIDs"
fi
grep -q 'not running' "$TMP/runtime-pid.out"

# Reproduce Lima #5075: a fast host shutdown can leave socket nodes and PID metadata after every
# owning process is gone. Stop must remove only stale socket nodes, and the following start must
# advance to a fresh helper launch instead of treating connection-refused state as running.
rm -f "$runtime_home/.dory/engine.sock"
mkdir -p "$runtime_home/.dory/standalone/hv"
python3 - "$runtime_home/.dory/engine.sock" \
  "$runtime_home/.dory/standalone/hv/docker-backend.sock" <<'PY'
import os
import socket
import sys

for path in sys.argv[1:]:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.close()
PY
printf '999999\n' > "$runtime_home/.dory/standalone/engine-cli.pid"
printf '999998\n' > "$runtime_home/.dory/standalone/dataplane-cli.pid"
HOME="$runtime_home" "$runtime/dory-engine" stop > "$TMP/runtime-stale-stop.out" 2>&1
grep -q 'not running' "$TMP/runtime-stale-stop.out"
for stale in "$runtime_home/.dory/engine.sock" \
  "$runtime_home/.dory/standalone/hv/docker-backend.sock" \
  "$runtime_home/.dory/standalone/engine-cli.pid" \
  "$runtime_home/.dory/standalone/dataplane-cli.pid"; do
  [ ! -e "$stale" ] || fail "standalone runtime retained stale shutdown state: $stale"
done

# Reproduce Lima #5087 defensively: dory-hv and the dataplane may survive while their pidfiles are
# lost. The launcher must rediscover only helpers carrying this HOME's exact private paths, stop
# them, and continue to a fresh launch attempt. An identical helper name with foreign paths must
# not be touched. Use a native executable for the old helpers so replacing their on-disk paths
# models an app upgrade: the already-mapped processes must remain alive until the supervisor
# explicitly stops them. A copied native interpreter keeps the fixture independent of the
# replacement paths without consuming CPU while it waits.
helper_cwd="$TMP/native-helper"
mkdir -p "$helper_cwd"
cat > "$helper_cwd/engine" <<'EOF'
$SIG{TERM} = sub { exit 0 };
$SIG{INT} = sub { exit 0 };
while (1) { sleep 60; }
EOF
cp /usr/bin/perl "$runtime/bin/dory-hv"
cp "$runtime/bin/dory-hv" "$runtime/bin/dory-dataplane-proxy"
chmod +x "$runtime/bin/dory-hv" "$runtime/bin/dory-dataplane-proxy"
cd "$helper_cwd"
"$runtime/bin/dory-hv" engine \
  --engine-sock "$runtime_home/.dory/standalone/hv/docker-backend.sock" \
  --state-dir "$runtime_home/.dory/standalone/hv" > /dev/null &
orphan_hv_pid=$!
"$runtime/bin/dory-dataplane-proxy" engine \
  --listen "$runtime_home/.dory/engine.sock" \
  --backend "$runtime_home/.dory/standalone/hv/docker-backend.sock" > /dev/null &
orphan_dataplane_pid=$!
mkdir -p "$TMP/foreign-helper"
cp "$runtime/bin/dory-hv" "$TMP/foreign-helper/dory-hv"
chmod +x "$TMP/foreign-helper/dory-hv"
"$TMP/foreign-helper/dory-hv" engine \
  --engine-sock "$TMP/unrelated-backend.sock" --state-dir "$TMP/unrelated-state" > /dev/null &
unrelated_hv_pid=$!
cd "$ROOT"
test_pids="$test_pids $orphan_hv_pid $orphan_dataplane_pid $unrelated_hv_pid"
wait_for_process_contract() {
  local pid="$1" token command attempt matched
  shift
  for ((attempt = 0; attempt < 200; attempt++)); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    matched=1
    for token in "$@"; do
      case "$command" in *"$token"*) ;; *) matched=0; break ;; esac
    done
    [ "$matched" -eq 0 ] || return 0
    kill -0 "$pid" 2>/dev/null \
      || fail "supervisor fixture exited before publishing its process contract: $*"
    sleep 0.01
  done
  fail "supervisor fixture did not publish its process contract: $*"
}
wait_for_process_contract "$orphan_hv_pid" \
  "$runtime/bin/dory-hv engine" \
  "--engine-sock $runtime_home/.dory/standalone/hv/docker-backend.sock" \
  "--state-dir $runtime_home/.dory/standalone/hv"
wait_for_process_contract "$orphan_dataplane_pid" \
  "$runtime/bin/dory-dataplane-proxy" \
  "--listen $runtime_home/.dory/engine.sock" \
  "--backend $runtime_home/.dory/standalone/hv/docker-backend.sock"
wait_for_process_contract "$unrelated_hv_pid" \
  "$TMP/foreign-helper/dory-hv engine" \
  "--engine-sock $TMP/unrelated-backend.sock" \
  "--state-dir $TMP/unrelated-state"
for helper in dory-hv dory-dataplane-proxy; do
  printf '#!/bin/sh\nexit 99\n' > "$runtime/bin/$helper.next"
  chmod +x "$runtime/bin/$helper.next"
  mv "$runtime/bin/$helper.next" "$runtime/bin/$helper"
done
if HOME="$runtime_home" "$runtime/dory-engine" start \
    > "$TMP/runtime-orphan-recovery.out" 2> "$TMP/runtime-orphan-recovery.err"; then
  fail "standalone runtime unexpectedly started with the intentional exit-99 helper"
fi
if ! grep -q 'stopping incomplete previous runtime' "$TMP/runtime-orphan-recovery.out"; then
  printf '%s\n' '--- orphan recovery stdout ---' >&2
  sed -n '1,120p' "$TMP/runtime-orphan-recovery.out" >&2
  printf '%s\n' '--- orphan recovery stderr ---' >&2
  sed -n '1,120p' "$TMP/runtime-orphan-recovery.err" >&2
  printf '%s\n' '--- fixture process table ---' >&2
  ps -p "$orphan_hv_pid,$orphan_dataplane_pid,$unrelated_hv_pid" \
    -o pid=,state=,command= >&2 || true
  fail "standalone runtime did not detect its pidfile-less helpers"
fi
wait "$orphan_hv_pid" 2>/dev/null || true
wait "$orphan_dataplane_pid" 2>/dev/null || true
kill -0 "$orphan_hv_pid" 2>/dev/null \
  && fail "standalone runtime left its pidfile-less dory-hv running"
kill -0 "$orphan_dataplane_pid" 2>/dev/null \
  && fail "standalone runtime left its pidfile-less dataplane running"
kill -0 "$unrelated_hv_pid" 2>/dev/null \
  || fail "standalone runtime killed a foreign dory-hv with unrelated state paths"
kill "$unrelated_hv_pid" 2>/dev/null || true
wait "$unrelated_hv_pid" 2>/dev/null || true

# If dory-hv is force-killed, its gvproxy child can be reparented and outlive the VM. The
# standalone supervisor must match the exact bundled binary plus both private state sockets and
# reap that orphan even though gvproxy has no pidfile.
cat > "$runtime/bin/gvproxy" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$runtime/bin/gvproxy"
mkdir -p "$runtime_home/.dory/hv" "$runtime_home/.dory/standalone/hv"

# doryd and the standalone archive can coexist in one account, but only doryd owns ~/.dory/hv.
# Stopping the standalone supervisor must not signal an app-owned gvproxy carrying those paths.
"$runtime/bin/gvproxy" \
  -listen-vfkit "unixgram://$runtime_home/.dory/hv/net.sock" \
  -listen "unix://$runtime_home/.dory/hv/gvproxy-api.sock" &
app_gvproxy_pid=$!
test_pids="$test_pids $app_gvproxy_pid"
sleep 0.2
HOME="$runtime_home" "$runtime/dory-engine" stop > "$TMP/runtime-app-owner-stop.out" 2>&1
kill -0 "$app_gvproxy_pid" 2>/dev/null \
  || fail "standalone runtime killed doryd's app-owned gvproxy"
kill "$app_gvproxy_pid" 2>/dev/null || true
wait "$app_gvproxy_pid" 2>/dev/null || true

"$runtime/bin/gvproxy" \
  -listen-vfkit "unixgram://$runtime_home/.dory/standalone/hv/net.sock" \
  -listen "unix://$runtime_home/.dory/standalone/hv/gvproxy-api.sock" &
orphan_pid=$!
test_pids="$test_pids $orphan_pid"
sleep 0.2
kill -0 "$orphan_pid" 2>/dev/null || fail "gvproxy orphan fixture did not start"
HOME="$runtime_home" "$runtime/dory-engine" stop > "$TMP/runtime-orphan-stop.out" 2>&1
wait "$orphan_pid" 2>/dev/null || true
if kill -0 "$orphan_pid" 2>/dev/null; then
  fail "standalone runtime left its state-owned gvproxy orphan running"
fi

# Generate a real Ed25519 trust chain and prove the user-facing CLI verifies both signature and
# artifact digests before it invokes dorydctl. The fake control binary records invocation only.
printf 'kernel-v1\n' > "$TMP/Image"
printf 'rootfs-v1\n' > "$TMP/rootfs.raw"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/signing-key"
scripts/sign-machine-image-manifest.sh \
  --kernel "$TMP/Image" --rootfs "$TMP/rootfs.raw" \
  --key "$TMP/signing-key" --signer release@example.com \
  --output "$TMP/machine-image.json" > "$TMP/sign.out"

cat > "$TMP/dorydctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DORY_TEST_CTL_LOG"
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/dorydctl"
: > "$TMP/ctl.log"
DORYDCTL_BIN="$TMP/dorydctl" DORY_TEST_CTL_LOG="$TMP/ctl.log" DORY_MACHINE_ENV_ALLOW_LIST='' \
  scripts/dory machine create dev \
    --kernel "$TMP/Image" --rootfs "$TMP/rootfs.raw" \
    --image-manifest "$TMP/machine-image.json" \
    --image-signature "$TMP/machine-image.json.sig" \
    --image-allowed-signers "$TMP/machine-image.json.allowed_signers" \
    --image-signer release@example.com > "$TMP/create.out"
grep -F "machine create dev --kernel $TMP/Image --rootfs $TMP/rootfs.raw" "$TMP/ctl.log" >/dev/null
! grep -q -- '--image-' "$TMP/ctl.log" || fail "trust-only CLI options leaked into dorydctl"

cp "$TMP/rootfs.raw" "$TMP/rootfs.original"
printf 'tampered\n' >> "$TMP/rootfs.raw"
before_lines="$(wc -l < "$TMP/ctl.log" | tr -d ' ')"
if DORYDCTL_BIN="$TMP/dorydctl" DORY_TEST_CTL_LOG="$TMP/ctl.log" DORY_MACHINE_ENV_ALLOW_LIST='' \
    scripts/dory machine create dev-tampered \
      --kernel "$TMP/Image" --rootfs "$TMP/rootfs.raw" \
      --image-manifest "$TMP/machine-image.json" \
      --image-signature "$TMP/machine-image.json.sig" \
      --image-allowed-signers "$TMP/machine-image.json.allowed_signers" \
      --image-signer release@example.com > "$TMP/tampered.out" 2> "$TMP/tampered.err"; then
  fail "tampered rootfs passed signed-manifest verification"
fi
grep -q 'rootfs digest does not match' "$TMP/tampered.err"
[ "$(wc -l < "$TMP/ctl.log" | tr -d ' ')" = "$before_lines" ] \
  || fail "dorydctl ran after artifact verification failed"
mv "$TMP/rootfs.original" "$TMP/rootfs.raw"

cp "$TMP/machine-image.json" "$TMP/manifest.original"
printf ' ' >> "$TMP/machine-image.json"
if DORYDCTL_BIN="$TMP/dorydctl" DORY_TEST_CTL_LOG="$TMP/ctl.log" DORY_MACHINE_ENV_ALLOW_LIST='' \
    scripts/dory machine create dev-badsig \
      --kernel "$TMP/Image" --rootfs "$TMP/rootfs.raw" \
      --image-manifest "$TMP/machine-image.json" \
      --image-signature "$TMP/machine-image.json.sig" \
      --image-allowed-signers "$TMP/machine-image.json.allowed_signers" \
      --image-signer release@example.com > "$TMP/badsig.out" 2> "$TMP/badsig.err"; then
  fail "modified manifest passed signature verification"
fi
grep -q 'manifest signature is invalid' "$TMP/badsig.err"
mv "$TMP/manifest.original" "$TMP/machine-image.json"

if DORYDCTL_BIN="$TMP/dorydctl" DORY_TEST_CTL_LOG="$TMP/ctl.log" DORY_MACHINE_ENV_ALLOW_LIST='' \
    scripts/dory machine create dev-partial \
      --kernel "$TMP/Image" --rootfs "$TMP/rootfs.raw" \
      --image-manifest "$TMP/machine-image.json" > "$TMP/partial.out" 2> "$TMP/partial.err"; then
  fail "partial image trust options were accepted"
fi
grep -q 'require --image-manifest' "$TMP/partial.err"

echo "competitor-derived release gate tests: PASS"
