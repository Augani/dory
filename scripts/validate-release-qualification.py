#!/usr/bin/env python3
"""Validate durable qualification authority against freshly downloaded release bytes."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import zipfile


SHA256 = re.compile(r"[0-9a-f]{64}")
DIGEST_IMAGE = re.compile(r".+@sha256:[0-9a-f]{64}")
COMPLETION_KEYS = {
    "schemaVersion", "kind", "status", "releaseQualifying", "developmentUnnotarized",
    "dataDiskGrowthGate", "managedDataDriveGate", "dataDriveVolumeIdentityGate",
    "offlineBundledBootGate", "defaultPlatformImageGate", "pruneSafetyGate",
    "privateRegistryAuthGate", "privateRegistryImage", "nonnativeNixGCGate",
    "nonnativeArchPacmanGate", "nonnativeMmdebstrapGate", "nonnativeExecConformanceGate",
    "ecrRegistryRetryGate", "bindFileCoherenceGate", "powerAssertion",
    "gvproxyQEMUSwitchGate", "nativeIPv6Gate", "migrationGate", "competitorRuntimeGate",
    "machineToDockerLongLivedGate", "machineOutboundLongLivedGate",
    "standaloneSupervisorRecoveryGate", "bindAdvisoryLockGate", "sshAgentForwardingGate",
    "sshAgentImage", "bindAdvisoryLockImage", "bindAdvisoryLockDockerCLI_SHA256",
    "guestAgentBootConfigGate", "guestAgentSha256", "fixtureImage", "testcontainersGate",
    "testcontainersVersion", "testcontainersRyukImage", "devcontainersGate",
    "devcontainersVersion", "actGate", "actVersion", "actRunnerImage", "localstackGate",
    "localstackImage", "tiltGate", "tiltVersion", "supabaseGate", "supabaseVersion",
    "kubernetesToolingGate", "k3sImage", "kubernetesWorkloadImage", "skaffoldVersion",
    "version", "build", "sourceCommit", "githubRunId", "githubRunAttempt",
    "candidateManifestSha256", "appUpdateSha256", "componentCatalogSha256",
    "componentCatalogSchemaVersion", "componentCatalogSignatureSha256", "runtimeSha256",
    "candidateBindingSha256", "qualificationHarnessSha256", "metadataValidatorSha256",
    "evidenceManifestSha256", "enduranceDurationSeconds", "longLivedDurationSeconds",
    "completedEpoch",
}
BINDING_KEYS = {
    "schema_version", "kind", "version", "build", "source_commit",
    "release_manifest_sha256", "app_update_sha256", "runtime_archive_sha256",
    "sbom_sha256", "component_catalog_schema", "component_catalog_sha256",
    "component_catalog_digest_file_sha256", "component_catalog_signature_sha256",
    "app_executable_sha256", "doryd_sha256", "dory_vmm_sha256", "dory_hv_sha256",
    "gvproxy_sha256", "gvproxy_build_sha256", "dataplane_sha256", "docker_cli_sha256",
    "compose_sha256", "buildx_sha256", "kubectl_sha256", "kernel_sha256",
    "rootfs_sha256", "guest_agent_sha256", "host_facts_sha256", "qualifier_sha256",
    "metadata_validator_sha256", "developer_id", "notarization", "stapling",
    "gatekeeper", "sparkle", "status",
}
PASS_FIELDS = {
    "status", "dataDiskGrowthGate", "managedDataDriveGate", "dataDriveVolumeIdentityGate",
    "offlineBundledBootGate", "defaultPlatformImageGate", "pruneSafetyGate",
    "privateRegistryAuthGate", "nonnativeNixGCGate", "nonnativeArchPacmanGate",
    "nonnativeMmdebstrapGate", "nonnativeExecConformanceGate", "ecrRegistryRetryGate",
    "bindFileCoherenceGate", "powerAssertion", "gvproxyQEMUSwitchGate", "nativeIPv6Gate",
    "migrationGate", "competitorRuntimeGate", "machineToDockerLongLivedGate",
    "machineOutboundLongLivedGate", "standaloneSupervisorRecoveryGate",
    "bindAdvisoryLockGate", "guestAgentBootConfigGate", "sshAgentForwardingGate",
    "testcontainersGate", "devcontainersGate", "actGate", "localstackGate", "tiltGate",
    "supabaseGate", "kubernetesToolingGate",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def unique_json(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        require(key not in result, f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path) -> object:
    require(path.is_file() and not path.is_symlink(), f"input is missing or indirect: {path}")
    require(path.stat().st_size <= 2 * 1024 * 1024, f"JSON input is too large: {path.name}")
    return json.loads(path.read_bytes(), object_pairs_hook=unique_json)


def direct_canonical_directory(value: str, label: str) -> pathlib.Path:
    path = pathlib.Path(value)
    require(path.is_absolute(), f"{label} must be absolute")
    require(path.is_dir() and not path.is_symlink(), f"{label} is missing or indirect")
    require(path.resolve() == path, f"{label} must be canonical")
    return path


def parse_properties(path: pathlib.Path) -> dict[str, str]:
    require(path.is_file() and not path.is_symlink(), f"evidence is missing or indirect: {path}")
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        require("=" in line, f"evidence property is malformed: {path.name}")
        key, value = line.split("=", 1)
        require(key and key not in result, f"evidence property is duplicate or empty: {key}")
        result[key] = value
    return result


def exactly_one(root: pathlib.Path, directory: str, name: str) -> pathlib.Path:
    base = root / "evidence" / directory
    require(base.is_dir() and not base.is_symlink(), f"evidence directory is missing: {directory}")
    matches = [path for path in base.rglob(name) if path.is_file() and not path.is_symlink()]
    require(len(matches) == 1, f"expected exactly one {directory}/{name} evidence file")
    return matches[0]


def validate_evidence_manifest(qualification: pathlib.Path) -> pathlib.Path:
    evidence = qualification / "evidence"
    manifest = evidence / "evidence-sha256.txt"
    require(evidence.is_dir() and not evidence.is_symlink(), "evidence directory is missing or indirect")
    require(manifest.is_file() and not manifest.is_symlink(), "evidence digest manifest is missing or indirect")
    for path in evidence.rglob("*"):
        require(not path.is_symlink(), f"qualification evidence contains a symlink: {path.relative_to(evidence)}")
    records: list[tuple[str, str]] = []
    seen: set[str] = set()
    pattern = re.compile(r"([0-9a-f]{64})  (evidence/[A-Za-z0-9._/+@=-]+)")
    for line in manifest.read_text(encoding="ascii").splitlines():
        match = pattern.fullmatch(line)
        require(match is not None, "evidence digest manifest contains a malformed record")
        digest, relative = match.groups()
        require(relative not in seen, f"evidence digest manifest repeats {relative}")
        require(relative != "evidence/evidence-sha256.txt", "evidence manifest cannot authenticate itself")
        seen.add(relative)
        records.append((relative, digest))
    require(records and [item[0] for item in records] == sorted(seen), "evidence manifest is empty or unsorted")
    actual = {
        path.relative_to(qualification).as_posix()
        for path in evidence.rglob("*")
        if path.is_file() and path != manifest
    }
    require(seen == actual, "evidence manifest does not cover the exact retained evidence set")
    for relative, expected in records:
        path = qualification / relative
        require(path.is_file() and not path.is_symlink(), f"evidence member is missing or indirect: {relative}")
        require(sha256_file(path) == expected, f"evidence digest mismatch: {relative}")
    return manifest


def zip_member_digest(archive: pathlib.Path, name: str) -> str:
    with zipfile.ZipFile(archive) as candidate:
        matches = [item for item in candidate.infolist() if item.filename == name]
        require(len(matches) == 1 and not matches[0].is_dir(), f"candidate ZIP member is missing or duplicate: {name}")
        mode = (matches[0].external_attr >> 16) & 0o170000
        require(mode != 0o120000, f"candidate ZIP member is a symlink: {name}")
        with candidate.open(matches[0]) as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
            return digest.hexdigest()


def zip_member_bytes(archive: pathlib.Path, name: str) -> bytes:
    with zipfile.ZipFile(archive) as candidate:
        matches = [item for item in candidate.infolist() if item.filename == name]
        require(len(matches) == 1 and not matches[0].is_dir(), f"candidate ZIP member is missing or duplicate: {name}")
        mode = (matches[0].external_attr >> 16) & 0o170000
        require(mode != 0o120000, f"candidate ZIP member is a symlink: {name}")
        return candidate.read(matches[0])


def tar_suffix_digest(archive: pathlib.Path, suffix: str) -> str:
    with tarfile.open(archive, "r:gz") as candidate:
        matches = [item for item in candidate.getmembers() if item.name.endswith(suffix)]
        require(len(matches) == 1 and matches[0].isfile(), f"runtime member is missing, indirect, or duplicate: {suffix}")
        handle = candidate.extractfile(matches[0])
        require(handle is not None, f"runtime member cannot be read: {suffix}")
        with handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
            return digest.hexdigest()


def catalog_kubectl_digest(build_dir: pathlib.Path) -> str:
    catalog = load_json(build_dir / "components/arm64/catalog.json")
    require(isinstance(catalog, dict), "component catalog is not an object")
    components = catalog.get("components")
    require(isinstance(components, list), "component catalog components are invalid")
    matches = [item for item in components if isinstance(item, dict) and item.get("id") == "kubernetes"]
    require(len(matches) == 1, "component catalog must contain one Kubernetes component")
    assets = matches[0].get("assets")
    require(isinstance(assets, list) and len(assets) == 1, "Kubernetes component assets are invalid")
    asset = assets[0]
    require(isinstance(asset, dict) and asset.get("path") == "kubectl", "Kubernetes component must contain kubectl")
    url = asset.get("url")
    require(isinstance(url, str), "kubectl component URL is invalid")
    name = pathlib.PurePosixPath(url.split("?", 1)[0]).name
    require(name and "/" not in name, "kubectl component filename is invalid")
    path = build_dir / "components/arm64" / name
    require(path.is_file() and not path.is_symlink(), "kubectl component is missing or indirect")
    return sha256_file(path)


def verify_metadata(repo: pathlib.Path, build_dir: pathlib.Path, version: str, build: str, source: str) -> None:
    validator = repo / "scripts/validate-release-metadata.py"
    require(validator.is_file() and not validator.is_symlink(), "release metadata validator is missing or indirect")
    completed = subprocess.run(
        [sys.executable, str(validator), str(build_dir), version, build],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    require(completed.returncode == 0, f"signed schema-2 release metadata is invalid: {completed.stderr.strip()}")
    require(completed.stdout.strip() == source, "signed release metadata belongs to another source commit")


def validate(
    build_dir_value: str,
    qualification_value: str,
    version: str,
    build: str,
    source: str,
    run_id: str,
    run_attempt: str,
    primary_sha: str,
) -> None:
    repo = pathlib.Path(__file__).resolve().parent.parent
    require(pathlib.Path(__file__).is_file() and not pathlib.Path(__file__).is_symlink(), "qualification validator is indirect")
    build_dir = direct_canonical_directory(build_dir_value, "build directory")
    qualification = direct_canonical_directory(qualification_value, "qualification directory")
    require(re.fullmatch(r"[0-9a-f]{40}", source) is not None, "source commit is invalid")
    require(SHA256.fullmatch(primary_sha) is not None, "primary SHA-256 is invalid")
    verify_metadata(repo, build_dir, version, build, source)
    evidence_manifest = validate_evidence_manifest(qualification)

    completion_path = qualification / "qualification.complete.json"
    completion = load_json(completion_path)
    require(isinstance(completion, dict) and set(completion) == COMPLETION_KEYS, "qualification completion shape is invalid")
    require(completion["schemaVersion"] == 2, "qualification must use schema 2")
    require(completion["kind"] == "dev.dory.release-qualification", "qualification kind is invalid")
    require(completion["releaseQualifying"] is True, "qualification used development exceptions")
    require(completion["developmentUnnotarized"] is False, "qualification skipped notarization")
    for field in PASS_FIELDS:
        require(completion[field] == "PASS", f"qualification did not pass {field}")

    manifests = {
        name: parse_properties(exactly_one(qualification, directory, "manifest.txt"))
        for name, directory in {
            "private": "private-registry-auth", "lock": "bind-advisory-lock",
            "agent": "guest-agent", "ssh": "ssh-agent", "testcontainers": "testcontainers",
            "devcontainers": "devcontainers", "act": "act", "localstack": "localstack",
            "tilt": "tilt", "supabase": "supabase", "kubernetes": "kubernetes-tooling",
        }.items()
    }
    dynamic = {
        "privateRegistryImage": manifests["private"].get("registry_image"),
        "bindAdvisoryLockImage": manifests["lock"].get("image"),
        "bindAdvisoryLockDockerCLI_SHA256": manifests["lock"].get("docker_cli_sha256"),
        "guestAgentSha256": manifests["agent"].get("expected_sha256"),
        "sshAgentImage": manifests["ssh"].get("image"),
        "fixtureImage": manifests["private"].get("base_image"),
        "testcontainersVersion": manifests["testcontainers"].get("testcontainers_version"),
        "testcontainersRyukImage": manifests["testcontainers"].get("ryuk_image"),
        "devcontainersVersion": manifests["devcontainers"].get("devcontainers_cli"),
        "actVersion": manifests["act"].get("act_version"),
        "actRunnerImage": manifests["act"].get("runner_image"),
        "localstackImage": manifests["localstack"].get("localstack_image"),
        "tiltVersion": manifests["tilt"].get("tilt_version"),
        "supabaseVersion": manifests["supabase"].get("supabase_cli"),
        "k3sImage": manifests["kubernetes"].get("k3s_image"),
        "kubernetesWorkloadImage": manifests["kubernetes"].get("workload_image"),
        "skaffoldVersion": manifests["kubernetes"].get("skaffold_version"),
    }
    for field, expected in dynamic.items():
        require(isinstance(expected, str) and expected, f"retained evidence omits {field}")
        require(completion[field] == expected, f"completion record differs from retained evidence: {field}")
    for field in ("privateRegistryImage", "bindAdvisoryLockImage", "sshAgentImage", "fixtureImage",
                  "testcontainersRyukImage", "actRunnerImage", "localstackImage", "k3sImage",
                  "kubernetesWorkloadImage"):
        require(DIGEST_IMAGE.fullmatch(str(completion[field])) is not None, f"{field} is not digest-pinned")

    scalar_expected: dict[str, object] = {
        "version": version, "build": build, "sourceCommit": source,
        "githubRunId": run_id, "githubRunAttempt": run_attempt,
        "candidateManifestSha256": sha256_file(build_dir / "release-manifest.json"),
        "appUpdateSha256": sha256_file(build_dir / f"Dory-{version}-app-update.zip"),
        "componentCatalogSha256": sha256_file(build_dir / "components/arm64/catalog.json"),
        "componentCatalogSchemaVersion": 2,
        "componentCatalogSignatureSha256": sha256_file(build_dir / "components/arm64/catalog.json.sig"),
        "runtimeSha256": sha256_file(build_dir / f"dory-engine-{version}-arm64.tar.gz"),
        "qualificationHarnessSha256": sha256_file(repo / "scripts/qualify-release-candidate.sh"),
        "metadataValidatorSha256": sha256_file(repo / "scripts/validate-release-metadata.py"),
        "evidenceManifestSha256": sha256_file(evidence_manifest),
    }
    for field, expected in scalar_expected.items():
        require(completion[field] == expected, f"qualification completion mismatch: {field}")
    for field, minimum, strict in (
        ("enduranceDurationSeconds", 28800, False),
        ("longLivedDurationSeconds", 86400, True),
        ("completedEpoch", 0, True),
    ):
        value = completion[field]
        require(type(value) is int and (value > minimum if strict else value >= minimum), f"{field} is invalid")

    update = build_dir / f"Dory-{version}-app-update.zip"
    runtime = build_dir / f"dory-engine-{version}-arm64.tar.gz"
    provenance = zip_member_bytes(update, "Dory.app/Contents/Resources/gvproxy-provenance.txt").decode("utf-8")
    provenance_values = {}
    for line in provenance.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            require(key not in provenance_values, f"gvproxy provenance repeats {key}")
            provenance_values[key] = value
    binding_path = exactly_one(qualification, "", "candidate-binding.txt")
    require(binding_path == qualification / "evidence/candidate-binding.txt", "candidate binding is misplaced")
    binding = parse_properties(binding_path)
    require(set(binding) == BINDING_KEYS, "candidate binding shape is invalid")
    require(completion["candidateBindingSha256"] == sha256_file(binding_path), "candidate binding digest changed")
    expected_binding = {
        "schema_version": "2", "kind": "dev.dory.release-qualification-candidate-binding",
        "version": version, "build": build, "source_commit": source,
        "release_manifest_sha256": sha256_file(build_dir / "release-manifest.json"),
        "app_update_sha256": sha256_file(update), "runtime_archive_sha256": sha256_file(runtime),
        "sbom_sha256": sha256_file(build_dir / f"Dory-{version}.cdx.json"),
        "component_catalog_schema": "2",
        "component_catalog_sha256": sha256_file(build_dir / "components/arm64/catalog.json"),
        "component_catalog_digest_file_sha256": sha256_file(build_dir / "components/arm64/catalog.json.sha256"),
        "component_catalog_signature_sha256": sha256_file(build_dir / "components/arm64/catalog.json.sig"),
        "app_executable_sha256": zip_member_digest(update, "Dory.app/Contents/MacOS/Dory"),
        "doryd_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/doryd"),
        "dory_vmm_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/dory-vmm"),
        "dory_hv_sha256": tar_suffix_digest(runtime, "/bin/dory-hv"),
        "gvproxy_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/gvproxy"),
        "gvproxy_build_sha256": provenance_values.get("verified_sha256"),
        "dataplane_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/dory-dataplane-proxy"),
        "docker_cli_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/docker"),
        "compose_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/docker-compose"),
        "buildx_sha256": zip_member_digest(update, "Dory.app/Contents/Helpers/docker-buildx"),
        "kubectl_sha256": catalog_kubectl_digest(build_dir),
        "kernel_sha256": tar_suffix_digest(runtime, "/share/dory/dory-hv-kernel-arm64.lzfse"),
        "rootfs_sha256": tar_suffix_digest(runtime, "/share/dory/dory-engine-rootfs.ext4.lzfse"),
        "guest_agent_sha256": tar_suffix_digest(runtime, "/share/dory/dory-agent-linux-arm64"),
        "host_facts_sha256": sha256_file(qualification / "evidence/host-facts.txt"),
        "qualifier_sha256": sha256_file(repo / "scripts/qualify-release-candidate.sh"),
        "metadata_validator_sha256": sha256_file(repo / "scripts/validate-release-metadata.py"),
        "developer_id": "PASS", "notarization": "PASS", "stapling": "PASS",
        "gatekeeper": "PASS", "sparkle": "PASS", "status": "PASS",
    }
    for field, expected in expected_binding.items():
        require(isinstance(expected, str) and binding[field] == expected, f"candidate binding mismatch: {field}")
    require(completion["guestAgentSha256"] == binding["guest_agent_sha256"], "guest-agent evidence is not candidate-bound")
    require(binding["docker_cli_sha256"] == manifests["lock"].get("docker_cli_sha256"), "bind-lock evidence used another Docker CLI")

    manifest = load_json(build_dir / "release-manifest.json")
    require(isinstance(manifest, dict), "release manifest is invalid")
    artifacts = manifest.get("artifacts")
    require(isinstance(artifacts, list), "release manifest artifact list is invalid")
    primary = [item for item in artifacts if isinstance(item, dict) and item.get("name") == f"Dory-{version}.zip"]
    require(len(primary) == 1 and primary[0].get("sha256") == primary_sha, "Homebrew SHA differs from signed release metadata")


def main() -> None:
    if len(sys.argv) != 9:
        raise SystemExit(
            "usage: validate-release-qualification.py <build-dir> <qualification> "
            "<version> <build> <source-commit> <run-id> <run-attempt> <primary-sha256>"
        )
    validate(*sys.argv[1:])
    print("release qualification authority: PASS")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, tarfile.TarError, zipfile.BadZipFile) as error:
        raise SystemExit(f"release qualification error: {error}") from error
