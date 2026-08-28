#!/usr/bin/env python3
"""Create and verify Dory's dual VirGL2 + Venus renderer artifact inventories.

This tool deliberately separates reviewed source identity from built-byte identity. A source
revision is not evidence that a static archive or final worker came from that revision, and an
archive digest is not evidence that its guest protocol peers match. Every accepted inventory copies
the complete
checked-in tuple definition and binds each required regular file by relative path, byte count, and
SHA-256.  The canonical inventory digest is the `candidateInventory` value carried by the worker
bootstrap after the complete Linux candidate has been assembled.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
from typing import Any


INVENTORY_KIND = "dev.dory.renderer-artifact-inventory"
INVENTORY_SCHEMA = 3
MAX_JSON_BYTES = 1024 * 1024
MAX_ARTIFACT_BYTES = 8 * 1024 * 1024 * 1024
SOURCE_NAMES = {"angle", "libepoxy", "mesa", "moltenVK", "virglrenderer"}
PROFILE_NAMES = {
    "rendererBundle",
    "rendererQualificationEvidence",
    "rendererReleaseQualificationEvidence",
    "staticDependencies",
    "staticLinkClosure",
}
PATCH_SOURCE_NAMES = {"angle", "libepoxy", "moltenVK"}
EXPECTED_SOURCES = {
    "angle": {
        "repository": "https://github.com/utmapp/WebKit.git",
        "revision": "6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7",
        "subdirectory": "Source/ThirdParty/ANGLE",
        "tree": "6ff242f54d40a2aaf08ed74b6a4bfe65a8bf447f",
    },
    "libepoxy": {
        "repository": "https://github.com/utmapp/libepoxy.git",
        "revision": "15d904dcb1d5a8d626ffe11e8f3339499d6f7b09",
        "tree": "86af2dd5a68cb45140eef8a1165cd5bfd23a03e8",
    },
    "mesa": {
        "repository": "https://gitlab.freedesktop.org/osy/mesa.git",
        "revision": "79bc850d884a1307356ff61c017e58901b90c7e2",
        "tree": "585b6604e6ef58585cfc44f7b4d5eab172ddfbbd",
    },
    "moltenVK": {
        "repository": "https://github.com/utmapp/MoltenVK.git",
        "revision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        "tree": "14f470cffb6b74c5e72647925a0c7f83ba64abb8",
    },
    "virglrenderer": {
        "repository": "https://github.com/utmapp/virglrenderer.git",
        "revision": "65cc14eb896f121ffc5130ce04815a923a03c41d",
        "tree": "94dc34ffde98cf70f0c11fe921bec10a09d3907f",
    },
}
EXPECTED_DEPENDENCY_SOURCES = {
    "moltenVK": {
        "cereal": {
            "repository": "https://github.com/USCiLab/cereal.git",
            "revision": "a56bad8bbb770ee266e930c95d37fff2a5be7fea",
            "tree": "31169d00742fa22795e582f47bce5a0eeafecdad",
        },
        "spirvCross": {
            "repository": "https://github.com/utmapp/SPIRV-Cross.git",
            "revision": "939b40b33a44443c404c4078823c406e3c94866f",
            "tree": "09cb57c85e770936a6390ed3f891363075a0b67a",
        },
        "spirvHeaders": {
            "repository": "https://github.com/KhronosGroup/SPIRV-Headers.git",
            "revision": "b824a462d4256d720bebb40e78b9eb8f78bbb305",
            "tree": "4f5ba6304fde3759b6e42e94f36499802c6f3bdb",
        },
        "spirvTools": {
            "repository": "https://github.com/KhronosGroup/SPIRV-Tools.git",
            "revision": "262bdab48146c937467f826699a40da0fdfc0f1a",
            "tree": "0252479f729a6f5f2064a36d89044c5326171566",
        },
        "volk": {
            "repository": "https://github.com/zeux/Volk.git",
            "revision": "59660878571aa99e3c9a366bb1d19fdcd701f0e7",
            "tree": "ba6a6ea0d7b581d637a3c8822a71ffb743c0c007",
        },
        "vulkanHeaders": {
            "repository": "https://github.com/KhronosGroup/Vulkan-Headers.git",
            "revision": "6aefb8eb95c8e170d0805fd0f2d02832ec1e099a",
            "tree": "b6a7d1d42b0439ba90a2927d94ed098c9111cc2d",
        },
        "vulkanTools": {
            "repository": "https://github.com/KhronosGroup/Vulkan-Tools.git",
            "revision": "013058f74e2356347f8d9317233bc769816c9dfb",
            "tree": "9e704d67ff5461b87f360dc194c09b67c805b594",
        },
    },
}
EXPECTED_DEPENDENCY_BUILD_POLICY = {
    "compatibilityPatches": [
        {
            "path": "patches/moltenvk-fail-closed-robustness2.patch",
            "resultBlob": "110c542637a68618e797e5d8b83cf95f2ee6bb39",
            "sha256": "7c90f042dadd6fcb805843faa7b78fef835b16283a744652a2b9ead3e8b0d609",
            "source": "moltenVK",
            "sourceBlob": "612a527083ab6059c5349414457cd52e439f3cd7",
            "targetPath": "MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm",
            "upstreamRepository": "https://github.com/utmapp/MoltenVK.git",
            "upstreamRevision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        },
        {
            "path": "patches/moltenvk-hidden-vulkan-alias.patch",
            "resultBlob": "878e5ca82468bd1e827c5b28d198ff3be1e12dc5",
            "sha256": "be4aec6b7fc08fadc785c1b10bc66439d8882b9a025c0106d7adfac9cefaf646",
            "source": "moltenVK",
            "sourceBlob": "3071c3f89e9eca8b1020ec2ba38dd30f02b0bb87",
            "targetPath": "MoltenVK/MoltenVK/GPUObjects/MVKInstance.mm",
            "upstreamRepository": "https://github.com/utmapp/MoltenVK.git",
            "upstreamRevision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        },
        {
            "path": "patches/moltenvk-sync-fd-binary-consumption.patch",
            "resultBlob": "51752fd183ae00c55c92bbdd97a4ccab03f0960c",
            "sha256": "588504b0474eb2130d273cc2bfb31dc9672fbb9cdc3ad4cdbb621b4cc08274d7",
            "source": "moltenVK",
            "sourceBlob": "34022876aaa3d333b043049f48db81403f85fc73",
            "targetPath": "MoltenVK/MoltenVK/GPUObjects/MVKSync.mm",
            "upstreamRepository": "https://github.com/utmapp/MoltenVK.git",
            "upstreamRevision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        },
        {
            "path": "patches/moltenvk-hidden-vulkan-icd-entrypoints.patch",
            "resultBlob": "588a5fb8b44f8e7b5b258051f2e819acb80a8bec",
            "sha256": "feb558dfc75622bd6ebb5e89b5d4ab5d21bd14b26d442ec8eae791228189de69",
            "source": "moltenVK",
            "sourceBlob": "198b8473c6bdd9977b805c5a8854cfd1bcd0849c",
            "targetPath": "MoltenVK/MoltenVK/Vulkan/vulkan.mm",
            "upstreamRepository": "https://github.com/utmapp/MoltenVK.git",
            "upstreamRevision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        },
        {
            "path": "patches/moltenvk-dory-native-arrays.patch",
            "resultBlob": "59915f75a5294d5f54647cb5e02c87aa162b6045",
            "sha256": "1485bc300e1b8969121b90a34011f53f8c3b1a1c49a2da521b72cc040d2f4877",
            "source": "moltenVK",
            "sourceBlob": "b52730b2afc1ce97d886fc9a782d10e1bfef6e8d",
            "targetPath": "MoltenVKShaderConverter/MoltenVKShaderConverter/SPIRVToMSLConverter.cpp",
            "upstreamRepository": "https://github.com/utmapp/MoltenVK.git",
            "upstreamRevision": "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384",
        },
    ],
    "libcxxHardeningMode": "extensive",
    "maximumConcurrentBuildJobs": 3,
    "moltenVKStaticProduct": {
        "archivePath": "lib/libMoltenVK.a",
        "hideVulkanSymbols": True,
        "requiredEntrypoint": "vkGetInstanceProcAddr",
    },
    "moltenVKSemaphoreQualification": {
        "importExportCycles": 2,
        "path": "scripts/renderer-moltenvk-semaphore-probe.m",
        "sha256": "156a9ffc2e1b435872866e2f2ae381fea32b922c9830c53c0b8256f382ddbd16",
        "signalExportCycles": 2,
        "style": "mtlEvent",
    },
    "moltenVKScanoutCopyQualification": {
        "destinationTiling": "linear",
        "directLinearColorAttachment": False,
        "formats": ["bgra8-unorm", "rgba8-unorm"],
        "path": "scripts/renderer-moltenvk-scanout-copy-probe.m",
        "readback": "mapped-host-visible",
        "renderTiling": "optimal",
        "sha256": "d9affc819971f5aee4a7140862283126aaae8cc69c2f8f36a2dfe63bf971a61e",
        "transfer": "vkCmdCopyImage",
    },
    "warningSuppression": False,
    "zeroFuzzPatchApplication": True,
}
EXPECTED_GUEST_MESA_BUILD_POLICY = {
    "applicationReadiness": {
        "application": "zed",
        "applicationRevision": "eb8e1c8b5502b7007465fbbc465f4a736fa39210",
        "applicationTag": "v1.16.1",
        "atlasFormats": ["bgra8-unorm", "rgba8-unorm"],
        "atlasUsages": ["copy-destination", "texture-binding"],
        "backend": "vulkan",
        "minimumVulkanAPI": "1.3",
        "presentMode": "fifo",
        "sourceRepository": "https://github.com/zed-industries/zed.git",
        "surfaceExtent": "64x64",
        "surfaceFormatPolicy": "first-capability-format",
        "wgpuRevision": "e99f5305ded96ff7006f0714d043a7f735bd45c2",
        "wgpuVersion": "29.0.4",
    },
    "builderImage": "debian:bullseye-slim@sha256:f313b4bd62667092a59b3a664d7d3ab8b5e65f41675f48e81455a15dc5abe792",
    "builderSnapshot": "20260713T000000Z",
    "compositorProbeNeededSONAMEs": ["libc.so.6", "libvulkan.so.1"],
    "compositorProfile": "native-vulkan-optimal-copy-compositor-v2",
    "compositorProfileSourceCommit": "329a88e72424486180ff3339440fa9f8f711af02",
    "compositorProfileSourceTree": "ef4676a2279bd364c645f31cd0e1e1cb238e0e0c",
    "glibcSymbolCeiling": "GLIBC_2.31",
    "hiddenQueueSubmission": False,
    "icdNeededSONAMEs": [
        "libX11-xcb.so.1",
        "libc.so.6",
        "libdl.so.2",
        "libm.so.6",
        "libpthread.so.0",
        "libwayland-client.so.0",
        "libxcb-dri3.so.0",
        "libxcb-keysyms.so.1",
        "libxcb-present.so.0",
        "libxcb-randr.so.0",
        "libxcb-shm.so.0",
        "libxcb-sync.so.1",
        "libxcb-xfixes.so.0",
        "libxcb.so.1",
        "libxshmfence.so.1",
        "libz.so.1",
        "libzstd.so.1",
    ],
    "inputSHA256": "19a55684e03b26053f504982ebbbd85f31d198bcaeb307239689fd11189f17e9",
    "libcFamily": "glibc",
    "libdrmLinkage": "static-hidden",
    "manifestLibraryPath": "../../../lib/libvulkan_virtio.so",
    "maxGLIBCSymbol": "GLIBC_2.29",
    "mesonVersion": "1.10.0",
    "mesonWheelSHA256": "4b27aafce281e652dcb437b28007457411245d975c48b5db3a797d3e93ae1585",
    "packLayout": "single-tree",
    "patches": [],
    "probeNeededSONAMEs": [
        "libc.so.6",
        "libvulkan.so.1",
        "libwayland-client.so.0",
        "libxcb.so.1",
    ],
    "requiredDeviceExtensions": [
        "VK_KHR_external_semaphore_fd",
        "VK_KHR_swapchain",
    ],
    "requiredInstanceExtensions": [
        "VK_KHR_surface",
        "VK_KHR_wayland_surface",
        "VK_KHR_xcb_surface",
    ],
    "requiredVulkan13Features": [
        "dynamicRendering",
        "maintenance4",
        "synchronization2",
    ],
    "runtimeArtifactPath": "guest/out/dory-mesa-venus-arm64.tar.zst",
    "runtimeDigestContract": "DoryRendererArtifactManifest.guestMesa",
    "runtimeManifestSchema": 6,
    "runtimeSHA256": "fa12e2bef9855dd382c3cd7f1dcd434f65302fc13471ae06367179f1ad37124c",
    "sourceDateEpoch": 1767751301,
    "standardWSISemaphorePath": "sync-fd-minus-one",
    "vulkanAPI": "1.3",
    "waylandProtocolsVersion": "1.41",
    "waylandVersion": "1.20.0",
    "wsi": ["x11", "wayland"],
    "wsiSurfaceGate": ["xcb", "wayland"],
}


class TupleError(Exception):
    pass


def fail(message: str) -> None:
    raise TupleError(message)


def no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON object repeats key {key!r}")
        result[key] = value
    return result


def load_json(path: pathlib.Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        fail(f"cannot read {label} {path}: {error}")
    if not raw or len(raw) > MAX_JSON_BYTES:
        fail(f"{label} must contain 1..{MAX_JSON_BYTES} bytes")
    try:
        value = json.loads(raw, object_pairs_hook=no_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot decode {label} {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    return value, raw


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"{label} keys differ (missing={missing}, extra={extra})")


def lowercase_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        fail(f"{label} must be a 64-character SHA-256")
    if any(character not in "0123456789abcdef" for character in value):
        fail(f"{label} must be lowercase hexadecimal")
    if value == "0" * 64:
        fail(f"{label} must not be all zero")
    return value


def git_identity(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 40:
        fail(f"{label} must be a full 40-character Git object identity")
    if any(character not in "0123456789abcdef" for character in value):
        fail(f"{label} must be lowercase hexadecimal")
    return value


def nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        fail(f"{label} must be a non-empty canonical string")
    return value


def validate_relative_path(value: Any, label: str) -> str:
    text = nonempty_string(value, label)
    path = pathlib.PurePosixPath(text)
    if path.is_absolute() or text != path.as_posix():
        fail(f"{label} must be a canonical relative POSIX path")
    if any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{label} contains a forbidden path component")
    return text


def validate_definition(value: dict[str, Any]) -> dict[str, Any]:
    exact_keys(
        value,
        {
            "architecture",
            "artifactProfiles",
            "dependencyBuildPolicy",
            "dependencySources",
            "guestMesaBuildPolicy",
            "kind",
            "platform",
            "producerFence",
            "schemaVersion",
            "sourceTuple",
            "sources",
            "toolchain",
            "virglBuildPolicy",
        },
        "tuple definition",
    )
    if value["kind"] != "dev.dory.renderer-production-tuple":
        fail("tuple definition kind is unsupported")
    if value["schemaVersion"] != 3:
        fail("tuple definition schema is unsupported")
    if value["sourceTuple"] != "dory-dual-metal-20260826":
        fail("tuple definition sourceTuple is unsupported")
    if value["platform"] != "macos" or value["architecture"] != "arm64":
        fail("renderer tuple currently supports macOS arm64 only")

    toolchain = value["toolchain"]
    required_toolchain = {
        "appleClang": "Apple clang version 21.0.0 (clang-2100.1.1.101)",
        "cmake": "4.2.3",
        "meson": "1.12.0",
        "ninja": "1.13.2",
        "pkgConfig": "2.5.1",
        "xcodeBuild": "17F109",
        "xcodeVersion": "26.6",
    }
    if toolchain != required_toolchain:
        fail("renderer tuple toolchain does not match the reviewed release toolchain")

    sources = value["sources"]
    if not isinstance(sources, dict) or set(sources) != SOURCE_NAMES:
        fail("tuple definition must contain the exact reviewed source set")
    if sources != EXPECTED_SOURCES:
        fail(
            "tuple definition source identities differ from the reviewed maintained tuple"
        )
    for name, source in sources.items():
        if not isinstance(source, dict):
            fail(f"source {name} must be an object")
        allowed = {"repository", "revision", "tree", "subdirectory"}
        if set(source) - allowed or not {"repository", "revision"}.issubset(source):
            fail(f"source {name} has an invalid field set")
        repository = nonempty_string(source["repository"], f"source {name} repository")
        if not repository.startswith("https://") or not repository.endswith(".git"):
            fail(
                f"source {name} repository must be an immutable HTTPS Git remote identity"
            )
        git_identity(source["revision"], f"source {name} revision")
        if "tree" in source:
            git_identity(source["tree"], f"source {name} tree")
        if "subdirectory" in source:
            validate_relative_path(
                source["subdirectory"], f"source {name} subdirectory"
            )

    dependency_build_policy = value["dependencyBuildPolicy"]
    if not isinstance(dependency_build_policy, dict):
        fail("dependencyBuildPolicy must be an object")
    exact_keys(
        dependency_build_policy,
        {
            "angleMetalProduct",
            "compatibilityPatches",
            "libcxxHardeningMode",
            "libepoxyStaticProduct",
            "maximumConcurrentBuildJobs",
            "moltenVKScanoutCopyQualification",
            "moltenVKSemaphoreQualification",
            "moltenVKStaticProduct",
            "warningSuppression",
            "zeroFuzzPatchApplication",
        },
        "dependencyBuildPolicy",
    )
    if dependency_build_policy["angleMetalProduct"] != {
        "archiveScheme": "ANGLE",
        "eglInstallName": "@loader_path/libEGL.dylib",
        "glesInstallName": "@loader_path/libGLESv2.dylib",
        "runtimePaths": [
            "Frameworks/libEGL.dylib",
            "Frameworks/libGLESv2.dylib",
        ],
    }:
        fail("dependencyBuildPolicy ANGLE Metal product differs")
    if dependency_build_policy["libepoxyStaticProduct"] != {
        "archivePath": "lib/libepoxy.a",
        "eglResolver": "@loader_path/../Frameworks/libEGL.dylib",
        "glesResolver": "@loader_path/../Frameworks/libGLESv2.dylib",
    }:
        fail("dependencyBuildPolicy libepoxy product differs")
    for field, expected in (
        ("libcxxHardeningMode", "extensive"),
        ("maximumConcurrentBuildJobs", 3),
        ("warningSuppression", False),
        ("zeroFuzzPatchApplication", True),
    ):
        if dependency_build_policy[field] != expected:
            fail(f"dependencyBuildPolicy {field} differs")
    if dependency_build_policy["moltenVKStaticProduct"] != (
        EXPECTED_DEPENDENCY_BUILD_POLICY["moltenVKStaticProduct"]
    ):
        fail("dependencyBuildPolicy MoltenVK static product differs")
    if dependency_build_policy["moltenVKSemaphoreQualification"] != (
        EXPECTED_DEPENDENCY_BUILD_POLICY["moltenVKSemaphoreQualification"]
    ):
        fail("dependencyBuildPolicy MoltenVK semaphore qualification differs")
    if dependency_build_policy["moltenVKScanoutCopyQualification"] != (
        EXPECTED_DEPENDENCY_BUILD_POLICY["moltenVKScanoutCopyQualification"]
    ):
        fail("dependencyBuildPolicy MoltenVK scanout qualification differs")
    patches = dependency_build_policy["compatibilityPatches"]
    if not isinstance(patches, list) or not patches:
        fail("dependencyBuildPolicy compatibilityPatches must be a non-empty array")
    target_keys: list[tuple[str, str]] = []
    patch_paths: list[str] = []
    for index, patch in enumerate(patches):
        label = f"dependencyBuildPolicy compatibility patch {index}"
        if not isinstance(patch, dict):
            fail(f"{label} must be an object")
        exact_keys(
            patch,
            {
                "path",
                "resultBlob",
                "sha256",
                "source",
                "sourceBlob",
                "targetPath",
                "upstreamRepository",
                "upstreamRevision",
            },
            label,
        )
        patch_paths.append(validate_relative_path(patch["path"], f"{label} path"))
        source_name = nonempty_string(patch["source"], f"{label} source")
        if source_name not in PATCH_SOURCE_NAMES:
            fail(f"{label} source is not a reviewed dependency build checkout")
        target_keys.append((
            source_name,
            validate_relative_path(patch["targetPath"], f"{label} targetPath"),
        ))
        lowercase_sha256(patch["sha256"], f"{label} sha256")
        git_identity(patch["sourceBlob"], f"{label} sourceBlob")
        git_identity(patch["resultBlob"], f"{label} resultBlob")
        git_identity(patch["upstreamRevision"], f"{label} upstreamRevision")
        repository = nonempty_string(
            patch["upstreamRepository"], f"{label} upstreamRepository"
        )
        if not repository.startswith("https://") or not repository.endswith(".git"):
            fail(f"{label} upstreamRepository must be an HTTPS Git remote identity")
    if len(patch_paths) != len(set(patch_paths)):
        fail("dependencyBuildPolicy patch paths must be unique")
    expected_patch_paths = {
        "patches/angle-final-virtual-destructor-backport.patch",
        "patches/angle-gles1-shader-state-copy-contract-backport.patch",
        "patches/angle-gles1-shader-state-logical-key-backport.patch",
        "patches/angle-logical-state-constructor-contract-backport.patch",
        "patches/angle-logical-state-copy-backport.patch",
        "patches/angle-metal-blit-logical-base-copy-backport.patch",
        "patches/angle-metal-state-cache-logical-key-backport.patch",
        "patches/angle-sampler-state-logical-equality-backport.patch",
        "patches/angle-shaderlang-trivial-copy-contract-backport.patch",
        "patches/angle-shaderlang-trivial-copy-implementation-backport.patch",
        "patches/angle-shift-count-overflow-backport.patch",
        "patches/libepoxy-dory-angle-rpath.patch",
        "patches/moltenvk-dory-native-arrays.patch",
        "patches/moltenvk-fail-closed-robustness2.patch",
        "patches/moltenvk-hidden-vulkan-alias.patch",
        "patches/moltenvk-hidden-vulkan-icd-entrypoints.patch",
        "patches/moltenvk-sync-fd-binary-consumption.patch",
    }
    if set(patch_paths) != expected_patch_paths:
        fail("dependencyBuildPolicy patch path set differs")
    if target_keys != sorted(set(target_keys)):
        fail("dependencyBuildPolicy patch source/target pairs must be sorted and unique")

    dependency_sources = value["dependencySources"]
    if dependency_sources != EXPECTED_DEPENDENCY_SOURCES:
        fail("dependencySources differ from the reviewed transitive source closure")
    for owner, dependencies in dependency_sources.items():
        if not isinstance(dependencies, dict) or not dependencies:
            fail(f"dependencySources {owner} must be a non-empty object")
        for name, source in dependencies.items():
            label = f"dependencySources {owner}.{name}"
            if not isinstance(source, dict):
                fail(f"{label} must be an object")
            allowed = {"repository", "revision", "tag", "tree"}
            required = {"repository", "revision", "tree"}
            if set(source) - allowed or not required.issubset(source):
                fail(f"{label} has an invalid field set")
            repository = nonempty_string(source["repository"], f"{label} repository")
            if not repository.startswith("https://") or not repository.endswith(".git"):
                fail(
                    f"{label} repository must be an immutable HTTPS Git remote identity"
                )
            git_identity(source["revision"], f"{label} revision")
            git_identity(source["tree"], f"{label} tree")
            if "tag" in source:
                nonempty_string(source["tag"], f"{label} tag")

    guest_mesa_policy = value["guestMesaBuildPolicy"]
    if guest_mesa_policy != EXPECTED_GUEST_MESA_BUILD_POLICY:
        fail(
            "guestMesaBuildPolicy differs from the reviewed deterministic Venus runtime"
        )
    lowercase_sha256(
        guest_mesa_policy["inputSHA256"], "guestMesaBuildPolicy inputSHA256"
    )
    lowercase_sha256(
        guest_mesa_policy["runtimeSHA256"], "guestMesaBuildPolicy runtimeSHA256"
    )
    validate_relative_path(
        guest_mesa_policy["runtimeArtifactPath"],
        "guestMesaBuildPolicy runtimeArtifactPath",
    )

    policy = value["virglBuildPolicy"]
    if not isinstance(policy, dict):
        fail("virglBuildPolicy must be an object")
    exact_keys(
        policy,
        {
            "checkGLErrors",
            "classicRenderer",
            "defaultLibrary",
            "drmRenderers",
            "fuzzer",
            "minimumMacOS",
            "metalSharedTextureQualification",
            "minigbmAllocation",
            "neptune",
            "platforms",
            "renderServerMode",
            "renderServerWorker",
            "requiredCapsets",
            "sourcePatches",
            "tests",
            "unstableAPIs",
            "venus",
            "venusOnly",
            "video",
            "vtest",
            "vulkanDynamicLoad",
        },
        "virglBuildPolicy",
    )
    required_policy = {
        "checkGLErrors": False,
        "classicRenderer": "virgl2-angle-metal",
        "defaultLibrary": "static",
        "drmRenderers": [],
        "fuzzer": False,
        "minimumMacOS": "15.0",
        "metalSharedTextureQualification": {
            "allocation": "newSharedTextureWithDescriptor",
            "crossProcessHandle": True,
            "path": "scripts/renderer-virgl-metal-shared-texture-probe.m",
            "renderImportReadback": True,
            "sha256": "1b939c36c82fa29eb17a6b3c2405f3b4cb1e42ad6196eb5815fbcec66fe7d622",
            "storageMode": "private",
        },
        "minigbmAllocation": False,
        "neptune": False,
        "platforms": ["egl"],
        "renderServerMode": "thread",
        "renderServerWorker": "thread",
        "requiredCapsets": [2, 4],
        "sourcePatches": [
            {
                "path": "patches/virglrenderer-venus-only-static.patch",
                "sha256": "e067deb5086f70d4781bd4877c1df94cfb95f2f7c4f62c72570996b5dc4c736a",
                "targets": {
                    "config.h.meson": {
                        "resultBlob": "fc7d181899b2f4ca14ca8672e30f32659084a831",
                        "sourceBlob": "99ead1ab20f15ebf01eeb3549659334c2b6abc08",
                    },
                    "meson.build": {
                        "resultBlob": "7ed632df5fa6ed61f433c631d30df8208774cb25",
                        "sourceBlob": "b863eccba1acff2ffaa5ee9160640721e58043ab",
                    },
                    "meson_options.txt": {
                        "resultBlob": "d1dbd265391de867e7c35b8c7de0df83f0fa8d6f",
                        "sourceBlob": "1862ee50f0230d00ec672ac70d175a27c4ff4bcf",
                    },
                    "server/render_protocol.h": {
                        "resultBlob": "821dca2db428ca2e47f3a0cadaeb31a23d50e783",
                        "sourceBlob": "9dd4c48f3a6f68b628e6b4eefc1fb0cf8e2d7dab",
                    },
                    "src/gallium/meson.build": {
                        "resultBlob": "e9a1487dcc51a9f28c6e682d0e095e124eb4d3eb",
                        "sourceBlob": "ac8f8be23edf640329dd6b9c0e7c1c5392259bb8",
                    },
                    "src/meson.build": {
                        "resultBlob": "78434d835650c1267d6a65a20dccb354213b56e8",
                        "sourceBlob": "e6e48ca5bdb157c8ce7a4a8939dc792246e90aa7",
                    },
                    "src/proxy/proxy_context.c": {
                        "resultBlob": "736b013aa603083c0d76ed338284431aabffcfdf",
                        "sourceBlob": "9b334532803bd294505dbbfd28afae977b19edbb",
                    },
                    "src/proxy/proxy_context.h": {
                        "resultBlob": "662fcaac39c98353050d3f047a04c7c03fb40482",
                        "sourceBlob": "ce29ecaea7fa06f4e6cc8d6d1646099489423aa7",
                    },
                    "src/virglrenderer.c": {
                        "resultBlob": "96992b73af8f1c39cedf5fcc3626edb2247152e7",
                        "sourceBlob": "71076727dbafd4a4f9432a3af03cf439ebd7907e",
                    },
                },
            },
            {
                "path": "patches/virglrenderer-dory-submit-failure-offset.patch",
                "sha256": "ee4ba95725e2fd505ee823610cd227a45812389f3611c6fbe93385151bd488a6",
                "targets": {
                    "src/vrend/vrend_decode.c": {
                        "resultBlob": "bdba09859231455ea0a77c96c87e3d6302418a57",
                        "sourceBlob": "7774a253bc4532f95edeb92874a8987bc2e3ddd9",
                    },
                },
            },
            {
                "path": "patches/virglrenderer-linear-modifier-contract.patch",
                "sha256": "03e2c23c43e38c080291ba0d5aaf61c03f85bf9702fed7cf0e5324374034639c",
                "targets": {
                    "src/venus/vkr_physical_device.c": {
                        "resultBlob": "a7a3d3c6710723f232466f36eda84ee1a750a0ff",
                        "sourceBlob": "e8558156a7b674c78b13b0714120f247a1946739",
                    },
                },
            },
            {
                "path": "patches/virglrenderer-metal-shm-external-memory.patch",
                "sha256": "ec642b18929c9ee66e4b0ab073ebe0b86754bdbcca781f26dea485cbca10a497",
                "targets": {
                    "src/venus/vkr_context.c": {
                        "resultBlob": "5c79451cab9d6509d2a20d2c3e5e42222e97d010",
                        "sourceBlob": "2ea589881710405f68819469f455133558b6f9e2",
                    },
                    "src/venus/vkr_context.h": {
                        "resultBlob": "e765a177f86613a5e6ccc026bbb17057f265329a",
                        "sourceBlob": "12541a72d2e948b2ebf106702ae403c1a8cc073f",
                    },
                    "src/venus/vkr_device_memory.c": {
                        "resultBlob": "d65e979dc4875a63c9bb05e81c0eeffab6684e73",
                        "sourceBlob": "b2e606f738591ecd7561f44750bb921c14f316ef",
                    },
                    "src/venus/vkr_metal_helpers.h": {
                        "resultBlob": "a92ff8a1f9357655b45714ee438affd3fc58cafc",
                        "sourceBlob": "4f5208bd1720210c6d89ce4177a45b6887687b77",
                    },
                    "src/venus/vkr_metal_helpers.m": {
                        "resultBlob": "7cab45751332bdf26bd67176cf43edf2292c1ff7",
                        "sourceBlob": "f0373ed10bf23bc0a8dde6e9a6a542325b93a4aa",
                    },
                },
            },
            {
                "path": "patches/virglrenderer-metal-shareable-scanout.patch",
                "sha256": "2f7505d21a29361c0cce47a986a678f79823bd22214fcdacf947451aeb9ee658",
                "targets": {
                    "src/vrend/vrend_metal.m": {
                        "resultBlob": "750a2b44848833bcf2fd668eef969c920979bbe7",
                        "sourceBlob": "e8ded745d272cecd5b54b6e59ee7739e543c2194",
                    },
                },
            },
        ],
        "tests": False,
        "unstableAPIs": True,
        "venus": True,
        "venusOnly": False,
        "video": False,
        "vtest": False,
        "vulkanDynamicLoad": False,
    }
    if policy != required_policy:
        fail(
            "virglBuildPolicy does not match Dory's reviewed in-worker renderer policy"
        )

    producer = value["producerFence"]
    if not isinstance(producer, dict):
        fail("producerFence must be an object")
    exact_keys(
        producer,
        {"failClosedPatch", "kernelVersion", "prepareFramebufferPatch"},
        "producerFence",
    )
    if producer["kernelVersion"] != "6.12.106":
        fail("producerFence kernel version is unsupported")
    expected_producer_patches = {
        "prepareFramebufferPatch": {
            "path": "guest/kernel/patches/6.12.106/0007-virtio-gpu-wait-for-scanout-producers.patch",
            "sha256": "b899d2981d192828ebcbba02a3f8f3409dd27663bf8ca3059bdc95da55090f42",
        },
        "failClosedPatch": {
            "path": "guest/kernel/patches/6.12.106/0008-virtio-gpu-fail-closed-on-producer-fence-error.patch",
            "sha256": "53f0db7b102f53c6d3aee13dc43cf45dbfedd5dabd0c04026b0b0c709c13953d",
        },
    }
    for field in ("prepareFramebufferPatch", "failClosedPatch"):
        patch = producer[field]
        if not isinstance(patch, dict):
            fail(f"producerFence {field} must be an object")
        exact_keys(patch, {"path", "sha256"}, f"producerFence {field}")
        validate_relative_path(patch["path"], f"producerFence {field} path")
        lowercase_sha256(patch["sha256"], f"producerFence {field} sha256")
        if patch != expected_producer_patches[field]:
            fail(f"producerFence {field} differs from the reviewed backport")

    profiles = value["artifactProfiles"]
    if not isinstance(profiles, dict) or set(profiles) != PROFILE_NAMES:
        fail("artifactProfiles differ from the reviewed dual-renderer profile set")
    for profile_name, components in profiles.items():
        if not isinstance(components, dict) or not components:
            fail(f"artifact profile {profile_name} must contain components")
        for component_name, paths in components.items():
            nonempty_string(component_name, f"{profile_name} component name")
            if not isinstance(paths, list) or not paths:
                fail(f"{profile_name} component {component_name} must contain files")
            canonical_paths = [
                validate_relative_path(path, f"{profile_name}.{component_name} path")
                for path in paths
            ]
            if canonical_paths != sorted(set(canonical_paths)):
                fail(
                    f"{profile_name} component {component_name} paths must be sorted and unique"
                )
    if profiles["staticDependencies"] != {
        "angleHeaders": [
            "include/ANGLE/EGL/egl.h",
            "include/ANGLE/EGL/eglext.h",
            "include/ANGLE/EGL/eglplatform.h",
            "include/ANGLE/KHR/khrplatform.h",
        ],
        "angleMetal": [
            "Frameworks/libEGL.dylib",
            "Frameworks/libGLESv2.dylib",
        ],
        "libepoxy": [
            "include/epoxy/common.h",
            "include/epoxy/egl.h",
            "include/epoxy/egl_angle_ext_generated.h",
            "include/epoxy/egl_generated.h",
            "include/epoxy/gl.h",
            "include/epoxy/gl_generated.h",
            "lib/libepoxy.a",
        ],
        "moltenVK": ["lib/libMoltenVK.a"],
    }:
        fail("staticDependencies differ from the reviewed ANGLE/epoxy/MoltenVK closure")
    if profiles["staticLinkClosure"] != {
        "angleHeaders": [
            "include/ANGLE/EGL/egl.h",
            "include/ANGLE/EGL/eglext.h",
            "include/ANGLE/EGL/eglplatform.h",
            "include/ANGLE/KHR/khrplatform.h",
        ],
        "angleMetal": [
            "Frameworks/libEGL.dylib",
            "Frameworks/libGLESv2.dylib",
        ],
        "libepoxy": ["lib/libepoxy.a"],
        "libepoxyHeaders": [
            "include/epoxy/common.h",
            "include/epoxy/egl.h",
            "include/epoxy/egl_angle_ext_generated.h",
            "include/epoxy/egl_generated.h",
            "include/epoxy/gl.h",
            "include/epoxy/gl_generated.h",
        ],
        "linkContract": ["renderer-static-link.json"],
        "moltenVK": ["lib/libMoltenVK.a"],
        "virglrenderer": ["lib/libvirglrenderer.a"],
    }:
        fail("staticLinkClosure differs from the reviewed dual-Metal link closure")
    if profiles["rendererBundle"] != {
        "angleMetal": [
            "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libEGL.dylib",
            "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libGLESv2.dylib",
        ],
        "rendererWorker": [
            "XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker"
        ]
    }:
        fail("rendererBundle must bind the worker and its exact XPC-local ANGLE pair")
    if profiles["rendererQualificationEvidence"] != {
        "qualification": ["Resources/renderer-bootstrap-qualification.json"]
    }:
        fail("rendererQualificationEvidence differs")
    if profiles["rendererReleaseQualificationEvidence"] != {
        "qualification": ["Resources/renderer-bootstrap-qualification.json"],
        "releaseSignature": ["Resources/renderer-bootstrap-qualification.json.sig"],
    }:
        fail("rendererReleaseQualificationEvidence differs")
    return value


def load_definition(path: pathlib.Path) -> dict[str, Any]:
    value, _ = load_json(path, "tuple definition")
    return validate_definition(value)


def verify_dependency_build_inputs(
    definition: dict[str, Any], repo_root: pathlib.Path
) -> None:
    for patch in definition["dependencyBuildPolicy"]["compatibilityPatches"]:
        patch_record = inspect_file(repo_root, patch["path"])
        if patch_record["sha256"] != patch["sha256"]:
            fail(
                f"renderer dependency patch digest drifted: {repo_root / patch['path']}"
            )
    semaphore_probe = definition["dependencyBuildPolicy"][
        "moltenVKSemaphoreQualification"
    ]
    probe_record = inspect_file(repo_root, semaphore_probe["path"])
    if probe_record["sha256"] != semaphore_probe["sha256"]:
        fail(f"MoltenVK semaphore probe digest drifted: {repo_root / semaphore_probe['path']}")
    scanout_copy_probe = definition["dependencyBuildPolicy"][
        "moltenVKScanoutCopyQualification"
    ]
    probe_record = inspect_file(repo_root, scanout_copy_probe["path"])
    if probe_record["sha256"] != scanout_copy_probe["sha256"]:
        fail(
            "MoltenVK scanout-copy probe digest drifted: "
            f"{repo_root / scanout_copy_probe['path']}"
        )


def verify_local_patches(definition: dict[str, Any], repo_root: pathlib.Path) -> None:
    for field in ("prepareFramebufferPatch", "failClosedPatch"):
        record = definition["producerFence"][field]
        path = repo_root / record["path"]
        file_record = inspect_file(repo_root, record["path"])
        if file_record["sha256"] != record["sha256"]:
            fail(f"producer-fence patch digest drifted: {path}")
    verify_dependency_build_inputs(definition, repo_root)
    metal_probe = definition["virglBuildPolicy"]["metalSharedTextureQualification"]
    metal_probe_record = inspect_file(repo_root, metal_probe["path"])
    if metal_probe_record["sha256"] != metal_probe["sha256"]:
        fail(
            "virglrenderer shared-texture probe digest drifted: "
            f"{repo_root / metal_probe['path']}"
        )
    for patch in definition["virglBuildPolicy"]["sourcePatches"]:
        patch_record = inspect_file(repo_root, patch["path"])
        if patch_record["sha256"] != patch["sha256"]:
            fail(f"virglrenderer source patch digest drifted: {repo_root / patch['path']}")

    definition_sha256 = hashlib.sha256(canonical_json(definition)).hexdigest()
    pin_path = (
        repo_root
        / "dory-core-swift/Sources/DoryRendererWorkerWireContracts/"
        "DoryRendererWorkerIdentity.swift"
    )
    if not pin_path.is_file() or pin_path.is_symlink():
        fail(f"renderer tuple Swift pin is unavailable: {pin_path}")
    try:
        pin_source = pin_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"renderer tuple Swift pin cannot be read: {error}")
    pins = re.findall(
        r'public static let productionDefinitionSHA256\s*=\s*\n\s*"([0-9a-f]{64})"',
        pin_source,
    )
    if pins != [definition_sha256]:
        fail(
            "renderer tuple Swift pin differs from the canonical definition: "
            f"expected {definition_sha256}"
        )


def inspect_file(root: pathlib.Path, relative: str) -> dict[str, Any]:
    validate_relative_path(relative, "artifact path")
    try:
        root_resolved = root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve artifact root {root}: {error}")
    candidate = root_resolved.joinpath(*pathlib.PurePosixPath(relative).parts)
    try:
        status = candidate.lstat()
    except OSError as error:
        fail(f"cannot inspect artifact {relative}: {error}")
    if not stat.S_ISREG(status.st_mode) or candidate.is_symlink():
        fail(f"artifact {relative} must be a non-symlink regular file")
    if status.st_size <= 0 or status.st_size > MAX_ARTIFACT_BYTES:
        fail(f"artifact {relative} has invalid byte count {status.st_size}")
    digest = hashlib.sha256()
    try:
        with candidate.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash artifact {relative}: {error}")
    return {"bytes": status.st_size, "path": relative, "sha256": digest.hexdigest()}


def component_digest(name: str, files: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_json({"files": files, "name": name})).hexdigest()


def create_inventory(
    definition: dict[str, Any], profile: str, root: pathlib.Path
) -> dict[str, Any]:
    if profile not in PROFILE_NAMES:
        fail(f"unsupported artifact profile {profile}")
    components: dict[str, Any] = {}
    for name, paths in definition["artifactProfiles"][profile].items():
        files = [inspect_file(root, relative) for relative in paths]
        components[name] = {"digest": component_digest(name, files), "files": files}
    return {
        "architecture": definition["architecture"],
        "buildPolicy": definition["virglBuildPolicy"],
        "components": components,
        "dependencyBuildPolicy": definition["dependencyBuildPolicy"],
        "dependencySources": definition["dependencySources"],
        "definitionSha256": hashlib.sha256(canonical_json(definition)).hexdigest(),
        "guestMesaBuildPolicy": definition["guestMesaBuildPolicy"],
        "kind": INVENTORY_KIND,
        "platform": definition["platform"],
        "producerFence": definition["producerFence"],
        "profile": profile,
        "schemaVersion": INVENTORY_SCHEMA,
        "sourceTuple": definition["sourceTuple"],
        "sources": definition["sources"],
        "toolchain": definition["toolchain"],
    }


def validate_file_record(value: Any, expected_path: str, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    exact_keys(value, {"bytes", "path", "sha256"}, label)
    if value["path"] != expected_path:
        fail(f"{label} path differs from the tuple definition")
    if isinstance(value["bytes"], bool) or not isinstance(value["bytes"], int):
        fail(f"{label} byte count must be an integer")
    if value["bytes"] <= 0 or value["bytes"] > MAX_ARTIFACT_BYTES:
        fail(f"{label} byte count is out of bounds")
    lowercase_sha256(value["sha256"], f"{label} sha256")
    return value


def validate_inventory(
    value: dict[str, Any], definition: dict[str, Any], profile: str
) -> dict[str, Any]:
    exact_keys(
        value,
        {
            "architecture",
            "buildPolicy",
            "components",
            "dependencyBuildPolicy",
            "dependencySources",
            "definitionSha256",
            "guestMesaBuildPolicy",
            "kind",
            "platform",
            "producerFence",
            "profile",
            "schemaVersion",
            "sourceTuple",
            "sources",
            "toolchain",
        },
        "renderer inventory",
    )
    if value["kind"] != INVENTORY_KIND or value["schemaVersion"] != INVENTORY_SCHEMA:
        fail("renderer inventory kind or schema is unsupported")
    if value["profile"] != profile:
        fail("renderer inventory profile differs from the requested profile")
    expected_definition_sha = hashlib.sha256(canonical_json(definition)).hexdigest()
    if value["definitionSha256"] != expected_definition_sha:
        fail("renderer inventory binds a different tuple definition")
    for field, expected in (
        ("architecture", definition["architecture"]),
        ("buildPolicy", definition["virglBuildPolicy"]),
        ("dependencyBuildPolicy", definition["dependencyBuildPolicy"]),
        ("dependencySources", definition["dependencySources"]),
        ("guestMesaBuildPolicy", definition["guestMesaBuildPolicy"]),
        ("platform", definition["platform"]),
        ("producerFence", definition["producerFence"]),
        ("sourceTuple", definition["sourceTuple"]),
        ("sources", definition["sources"]),
        ("toolchain", definition["toolchain"]),
    ):
        if value[field] != expected:
            fail(f"renderer inventory {field} differs from the tuple definition")
    components = value["components"]
    expected_components = definition["artifactProfiles"][profile]
    if not isinstance(components, dict) or set(components) != set(expected_components):
        fail("renderer inventory component set differs from the requested profile")
    for name, paths in expected_components.items():
        component = components[name]
        if not isinstance(component, dict):
            fail(f"renderer component {name} must be an object")
        exact_keys(component, {"digest", "files"}, f"renderer component {name}")
        files = component["files"]
        if not isinstance(files, list) or len(files) != len(paths):
            fail(f"renderer component {name} file set differs from the definition")
        validated = [
            validate_file_record(
                file, expected, f"renderer component {name} file {index}"
            )
            for index, (file, expected) in enumerate(zip(files, paths))
        ]
        digest = lowercase_sha256(
            component["digest"], f"renderer component {name} digest"
        )
        if digest != component_digest(name, validated):
            fail(f"renderer component {name} digest does not bind its files")
    return value


def verify_inventory_files(inventory: dict[str, Any], root: pathlib.Path) -> None:
    for component_name, component in inventory["components"].items():
        actual_files = [inspect_file(root, item["path"]) for item in component["files"]]
        if actual_files != component["files"]:
            fail(f"renderer component {component_name} bytes differ from its inventory")


def run_git(checkout: pathlib.Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", os.fspath(checkout), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot inspect Git checkout {checkout}: {error}")
    return result.stdout.strip()


def verify_git_source_identity(
    source: dict[str, Any], label: str, checkout: pathlib.Path
) -> None:
    if run_git(checkout, "remote", "get-url", "origin") != source["repository"]:
        fail(f"{label} checkout origin differs from the reviewed repository")
    if run_git(checkout, "rev-parse", "HEAD") != source["revision"]:
        fail(f"{label} checkout is not at the exact pinned revision")
    if "tree" in source:
        treeish = (
            f"HEAD:{source['subdirectory']}"
            if "subdirectory" in source
            else "HEAD^{tree}"
        )
        if run_git(checkout, "rev-parse", treeish) != source["tree"]:
            fail(f"{label} checkout tree differs from the reviewed tree")


def verify_git_source_checkout(
    source: dict[str, Any], label: str, checkout: pathlib.Path
) -> None:
    verify_git_source_identity(source, label, checkout)
    if run_git(checkout, "status", "--porcelain", "--untracked-files=all"):
        fail(f"{label} checkout contains modifications or untracked inputs")


def verify_checkout(
    definition: dict[str, Any], source_name: str, checkout: pathlib.Path
) -> None:
    source = definition["sources"].get(source_name)
    if source is None:
        fail(f"unknown tuple source {source_name}")
    verify_git_source_checkout(source, source_name, checkout)


def verify_dependency_checkout(
    definition: dict[str, Any], owner: str, dependency: str, checkout: pathlib.Path
) -> None:
    dependencies = definition["dependencySources"].get(owner)
    if dependencies is None:
        fail(f"unknown dependency source owner {owner}")
    source = dependencies.get(dependency)
    if source is None:
        fail(f"unknown dependency source {owner}.{dependency}")
    verify_git_source_checkout(source, f"{owner}.{dependency}", checkout)


def verify_dependency_build_checkout(
    definition: dict[str, Any], source_name: str, checkout: pathlib.Path, state: str
) -> None:
    if source_name not in PATCH_SOURCE_NAMES:
        fail(f"unknown dependency build source {source_name}")
    source = definition["sources"][source_name]
    verify_git_source_identity(source, source_name, checkout)
    patches = [
        patch
        for patch in definition["dependencyBuildPolicy"]["compatibilityPatches"]
        if patch["source"] == source_name
    ]
    if not patches:
        fail(f"dependency build source {source_name} has no reviewed patches")
    expected_targets = sorted(patch["targetPath"] for patch in patches)
    expected_hash_field = "sourceBlob" if state == "source" else "resultBlob"
    for patch in patches:
        actual = run_git(checkout, "hash-object", "--", patch["targetPath"])
        if actual != patch[expected_hash_field]:
            fail(f"dependency build {state} blob differs for {patch['targetPath']}")

    if state == "source":
        if run_git(checkout, "status", "--porcelain", "--untracked-files=all"):
            fail(
                "dependency build source checkout contains modifications or untracked inputs"
            )
        return

    changed = run_git(checkout, "diff", "--name-only", "--").splitlines()
    if changed != expected_targets:
        fail("dependency build patch set modified an unexpected path")
    if run_git(checkout, "diff", "--cached", "--name-only", "--"):
        fail("dependency build patch set must not stage source changes")
    if run_git(checkout, "ls-files", "--others", "--exclude-standard"):
        fail("dependency build patch set introduced untracked inputs")
    if run_git(checkout, "diff", "--check", "--"):
        fail("dependency build patch set introduced whitespace errors")


def verify_virgl_build_checkout(
    definition: dict[str, Any], checkout: pathlib.Path, state: str
) -> None:
    verify_git_source_identity(
        definition["sources"]["virglrenderer"], "virglrenderer", checkout
    )
    targets: dict[str, dict[str, str]] = {}
    for patch in definition["virglBuildPolicy"]["sourcePatches"]:
        for target, record in patch["targets"].items():
            if target in targets:
                fail(f"virglrenderer source patches overlap at {target}")
            targets[target] = record
    expected_hash_field = "sourceBlob" if state == "source" else "resultBlob"
    for target, record in targets.items():
        actual = run_git(checkout, "hash-object", "--", target)
        if actual != record[expected_hash_field]:
            fail(f"virglrenderer build {state} blob differs for {target}")

    if state == "source":
        if run_git(checkout, "status", "--porcelain", "--untracked-files=all"):
            fail("virglrenderer source checkout contains modifications or untracked inputs")
        return

    changed = run_git(checkout, "diff", "--name-only", "--").splitlines()
    if changed != sorted(targets):
        fail("virglrenderer source patches modified an unexpected path")
    if run_git(checkout, "diff", "--cached", "--name-only", "--"):
        fail("virglrenderer source patches must not stage source changes")
    if run_git(checkout, "ls-files", "--others", "--exclude-standard"):
        fail("virglrenderer source patches introduced untracked inputs")
    if run_git(checkout, "diff", "--check", "--"):
        fail("virglrenderer source patches introduced whitespace errors")


def command_output(arguments: list[str], label: str) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot inspect {label}: {error}")
    return result.stdout.strip()


def verify_guest_mesa_runtime(
    definition: dict[str, Any], repo_root: pathlib.Path
) -> dict[str, Any]:
    policy = definition["guestMesaBuildPolicy"]
    verify_script = repo_root / "guest" / "mesa" / "verify-build.sh"
    fingerprint_script = repo_root / "guest" / "mesa" / "input-fingerprint.sh"
    if (
        command_output(
            [os.fspath(fingerprint_script), "arm64"], "guest Mesa input fingerprint"
        )
        != policy["inputSHA256"]
    ):
        fail("guest Mesa build inputs differ from the reviewed runtime fingerprint")
    command_output([os.fspath(verify_script), "arm64"], "guest Mesa runtime verifier")
    artifact = inspect_file(repo_root, policy["runtimeArtifactPath"])
    if artifact["sha256"] != policy["runtimeSHA256"]:
        fail("guest Mesa runtime bytes differ from the reviewed compatibility tuple")
    return artifact


def verify_toolchain(definition: dict[str, Any]) -> None:
    expected = definition["toolchain"]
    xcode_lines = command_output(["xcodebuild", "-version"], "Xcode").splitlines()
    if xcode_lines != [
        f"Xcode {expected['xcodeVersion']}",
        f"Build version {expected['xcodeBuild']}",
    ]:
        fail("active DEVELOPER_DIR does not select the reviewed Xcode build")
    clang = command_output(["xcrun", "clang", "--version"], "Apple Clang").splitlines()[
        0
    ]
    if clang != expected["appleClang"]:
        fail("active Xcode does not contain the reviewed Apple Clang build")
    actual = {
        "cmake": command_output(["cmake", "--version"], "CMake")
        .splitlines()[0]
        .removeprefix("cmake version "),
        "meson": command_output(["meson", "--version"], "Meson"),
        "ninja": command_output(["ninja", "--version"], "Ninja"),
        "pkgConfig": command_output(["pkg-config", "--version"], "pkg-config"),
    }
    for name, actual_version in actual.items():
        if actual_version != expected[name]:
            fail(
                f"{name} version {actual_version!r} differs from reviewed {expected[name]!r}"
            )


def verify_meson(definition: dict[str, Any], build_dir: pathlib.Path) -> None:
    options_path = build_dir / "meson-info" / "intro-buildoptions.json"
    try:
        raw = options_path.read_bytes()
    except OSError as error:
        fail(f"cannot read Meson build options: {error}")
    if not raw or len(raw) > MAX_JSON_BYTES:
        fail("Meson build options have an invalid size")
    try:
        options_list = json.loads(raw, object_pairs_hook=no_duplicate_object)
    except json.JSONDecodeError as error:
        fail(f"cannot decode Meson build options: {error}")
    if not isinstance(options_list, list):
        fail("Meson build options must be an array")
    options = {
        item["name"]: item.get("value")
        for item in options_list
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    expected = {
        "buildtype": "release",
        "check-gl-errors": False,
        "default_library": "static",
        "drm-renderers": [],
        "fuzzer": False,
        "minigbm_allocation": False,
        "neptune": False,
        "platforms": ["egl"],
        "render-server-mode": "thread",
        "render-server-worker": "thread",
        "tests": False,
        "unstable-apis": True,
        "venus": True,
        "venus-only": False,
        "video": False,
        "vtest": False,
        "vulkan-dload": False,
        "vulkan-preload": False,
    }
    for name, expected_value in expected.items():
        if options.get(name) != expected_value:
            fail(f"Meson option {name} is not the reviewed value {expected_value!r}")
    config_path = build_dir / "config.h"
    try:
        config = config_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read generated virgl config.h: {error}")
    for macro in (
        "ENABLE_RENDER_SERVER",
        "ENABLE_RENDER_SERVER_WORKER_THREAD",
        "ENABLE_SAME_PROCESS_RENDER_SERVER",
        "ENABLE_VENUS",
    ):
        if f"#define {macro} 1" not in config:
            fail(f"generated virgl configuration is missing {macro}")
    if "#define ENABLE_VENUS_ONLY 1" in config:
        fail("generated virgl configuration incorrectly disabled classic VirGL")
    if not re.search(r"(?m)^#define HAVE_EPOXY_EGL_H(?: 1)?$", config):
        fail("generated virgl configuration is missing the ANGLE/EGL winsys")
    if (
        "#define ENABLE_NEPTUNE 1" in config
        or "#define ENABLE_LIBDRM 1" in config
        or "#define ENABLE_VULKAN_DLOAD 1" in config
        or "#define ENABLE_VULKAN_PRELOAD 1" in config
    ):
        fail("generated virgl configuration enabled an unreviewed backend")
    for unexpected in (
        build_dir / "src" / "libvirglrenderer.dylib",
        build_dir / "src" / "libvirglrenderer.1.dylib",
    ):
        if unexpected.exists():
            fail("dual renderer build emitted a forbidden renderer dylib")
    if (build_dir / "server" / "virgl_render_server").exists():
        fail(
            "reviewed Dory build must not emit virgl's ambient render-server executable"
        )

    log_path = build_dir / "meson-logs" / "meson-log.txt"
    try:
        log = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        fail(f"cannot read Meson configuration log: {error}")
    if "Run-time dependency epoxy found: YES" not in log:
        fail("dual virgl build did not resolve the pinned static libepoxy dependency")
    if "Run-time dependency vulkan found: YES" not in log:
        fail("virgl build did not resolve the pinned static MoltenVK dependency")

    commands_path = build_dir / "compile_commands.json"
    try:
        commands_raw = commands_path.read_bytes()
    except OSError as error:
        fail(f"cannot read virgl compile commands: {error}")
    if not commands_raw or len(commands_raw) > MAX_JSON_BYTES:
        fail("virgl compile commands have an invalid size")
    try:
        commands = json.loads(commands_raw, object_pairs_hook=no_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot decode virgl compile commands: {error}")
    if not isinstance(commands, list):
        fail("virgl compile commands must be an array")
    compiled_sources: set[str] = set()
    for index, command in enumerate(commands):
        if not isinstance(command, dict) or not isinstance(command.get("file"), str):
            fail(f"virgl compile command {index} has no source file")
        source = command["file"].replace("\\", "/")
        if not source:
            fail(f"virgl compile command {index} has an empty source file")
        compiled_sources.add(source)

    required_venus_sources = {
        "src/virglrenderer.c",
        "src/venus/vkr_renderer.c",
    }
    required_classic_sources = {
        "src/vrend/vrend_renderer.c",
        "src/vrend/vrend_winsys.c",
        "src/vrend/vrend_winsys_egl.c",
    }
    required_thread_transport_sources = {
        "server/render_client.c",
        "server/render_common.c",
        "server/render_context.c",
        "server/render_server.c",
        "server/render_socket.c",
        "server/render_state.c",
        "server/render_worker.c",
        "src/proxy/proxy_client.c",
        "src/proxy/proxy_common.c",
        "src/proxy/proxy_context.c",
        "src/proxy/proxy_renderer.c",
        "src/proxy/proxy_server.c",
        "src/proxy/proxy_socket.c",
    }

    def source_is_compiled(required: str) -> bool:
        return any(
            source == required or source.endswith(f"/{required}")
            for source in compiled_sources
        )

    for label, required_sources in (
        ("classic VirGL2/ANGLE", required_classic_sources),
        ("Venus entry", required_venus_sources),
        ("in-worker thread transport", required_thread_transport_sources),
    ):
        missing = sorted(source for source in required_sources if not source_is_compiled(source))
        if missing:
            fail(
                f"dual renderer compile graph is missing required {label} source "
                f"{missing[0]}"
            )

    forbidden_sources = (
        "/vtest/",
        "vtest_",
        "/video/",
        "drm_renderer.c",
    )
    for source in compiled_sources:
        normalized = f"/{source.lstrip('/')}"
        for fragment in forbidden_sources:
            if fragment in normalized:
                fail(
                    "dual renderer compile graph contains forbidden source fragment "
                    f"{fragment}"
                )


def print_inventory_evidence(inventory: dict[str, Any], raw: bytes) -> None:
    print(f"inventory.sha256={hashlib.sha256(raw).hexdigest()}")
    for name in sorted(inventory["components"]):
        print(f"component.{name}.sha256={inventory['components'][name]['digest']}")


def parser() -> argparse.ArgumentParser:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--definition",
        type=pathlib.Path,
        default=repo_root / "Config" / "DoryRendererProductionTuple.json",
    )
    commands = result.add_subparsers(dest="command", required=True)

    definition = commands.add_parser("verify-definition")
    definition.add_argument("--repo-root", type=pathlib.Path, default=repo_root)

    commands.add_parser("definition-sha256")

    guest_mesa = commands.add_parser("verify-guest-mesa-runtime")
    guest_mesa.add_argument("--repo-root", type=pathlib.Path, default=repo_root)

    commands.add_parser("verify-toolchain")

    checkout = commands.add_parser("verify-checkout")
    checkout.add_argument("--source", required=True)
    checkout.add_argument("--checkout", required=True, type=pathlib.Path)

    dependency_checkout = commands.add_parser("verify-dependency-checkout")
    dependency_checkout.add_argument("--owner", required=True)
    dependency_checkout.add_argument("--dependency", required=True)
    dependency_checkout.add_argument("--checkout", required=True, type=pathlib.Path)

    dependency_build_checkout = commands.add_parser("verify-dependency-build-checkout")
    dependency_build_checkout.add_argument(
        "--checkout", required=True, type=pathlib.Path
    )
    dependency_build_checkout.add_argument(
        "--source", required=True, choices=sorted(PATCH_SOURCE_NAMES)
    )
    dependency_build_checkout.add_argument(
        "--state", required=True, choices=("source", "applied")
    )

    dependency_patch_paths = commands.add_parser("dependency-build-patch-paths")
    dependency_patch_paths.add_argument(
        "--repo-root", type=pathlib.Path, default=repo_root
    )
    dependency_patch_paths.add_argument(
        "--source", required=True, choices=sorted(PATCH_SOURCE_NAMES)
    )

    virgl_build_checkout = commands.add_parser("verify-virgl-build-checkout")
    virgl_build_checkout.add_argument(
        "--checkout", required=True, type=pathlib.Path
    )
    virgl_build_checkout.add_argument(
        "--state", required=True, choices=("source", "applied")
    )

    virgl_patch_paths = commands.add_parser("virgl-build-patch-paths")
    virgl_patch_paths.add_argument(
        "--repo-root", type=pathlib.Path, default=repo_root
    )

    create = commands.add_parser("create-inventory")
    create.add_argument("--profile", required=True, choices=sorted(PROFILE_NAMES))
    create.add_argument("--root", required=True, type=pathlib.Path)
    create.add_argument("--output", required=True, type=pathlib.Path)

    verify = commands.add_parser("verify-inventory")
    verify.add_argument("--profile", required=True, choices=sorted(PROFILE_NAMES))
    verify.add_argument("--root", required=True, type=pathlib.Path)
    verify.add_argument("--inventory", required=True, type=pathlib.Path)

    meson = commands.add_parser("verify-meson")
    meson.add_argument("--build-dir", required=True, type=pathlib.Path)
    return result


def main() -> int:
    arguments = parser().parse_args()
    definition = load_definition(arguments.definition)
    if arguments.command == "verify-definition":
        verify_local_patches(definition, arguments.repo_root)
        print(
            f"definition.sha256={hashlib.sha256(canonical_json(definition)).hexdigest()}"
        )
        return 0
    if arguments.command == "definition-sha256":
        print(hashlib.sha256(canonical_json(definition)).hexdigest())
        return 0
    if arguments.command == "verify-guest-mesa-runtime":
        artifact = verify_guest_mesa_runtime(definition, arguments.repo_root)
        print(
            f"guest-mesa.input.sha256={definition['guestMesaBuildPolicy']['inputSHA256']}"
        )
        print(f"guest-mesa.runtime.sha256={artifact['sha256']}")
        return 0
    if arguments.command == "verify-toolchain":
        verify_toolchain(definition)
        print("toolchain=verified")
        return 0
    if arguments.command == "verify-checkout":
        verify_checkout(definition, arguments.source, arguments.checkout)
        print(
            f"source.{arguments.source}.revision={definition['sources'][arguments.source]['revision']}"
        )
        return 0
    if arguments.command == "verify-dependency-checkout":
        verify_dependency_checkout(
            definition,
            arguments.owner,
            arguments.dependency,
            arguments.checkout,
        )
        source = definition["dependencySources"][arguments.owner][arguments.dependency]
        print(
            f"dependency.{arguments.owner}.{arguments.dependency}.revision={source['revision']}"
        )
        print(
            f"dependency.{arguments.owner}.{arguments.dependency}.tree={source['tree']}"
        )
        return 0
    if arguments.command == "verify-dependency-build-checkout":
        verify_dependency_build_checkout(
            definition, arguments.source, arguments.checkout, arguments.state
        )
        print(f"dependency-build.{arguments.source}.checkout={arguments.state}")
        return 0
    if arguments.command == "dependency-build-patch-paths":
        verify_dependency_build_inputs(definition, arguments.repo_root)
        for patch in definition["dependencyBuildPolicy"]["compatibilityPatches"]:
            if patch["source"] == arguments.source:
                print(patch["path"])
        return 0
    if arguments.command == "verify-virgl-build-checkout":
        verify_virgl_build_checkout(
            definition, arguments.checkout, arguments.state
        )
        print(f"virgl-build.checkout={arguments.state}")
        return 0
    if arguments.command == "virgl-build-patch-paths":
        verify_local_patches(definition, arguments.repo_root)
        for patch in definition["virglBuildPolicy"]["sourcePatches"]:
            print(patch["path"])
        return 0
    if arguments.command == "create-inventory":
        inventory = create_inventory(definition, arguments.profile, arguments.root)
        raw = canonical_json(inventory)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = arguments.output.with_name(
            f".{arguments.output.name}.tmp-{os.getpid()}"
        )
        try:
            with temporary.open("xb") as handle:
                handle.write(raw)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, arguments.output)
        except OSError as error:
            fail(f"cannot publish renderer inventory {arguments.output}: {error}")
        print_inventory_evidence(inventory, raw)
        return 0
    if arguments.command == "verify-inventory":
        value, raw = load_json(arguments.inventory, "renderer inventory")
        if raw != canonical_json(value):
            fail("renderer inventory is not canonical JSON")
        inventory = validate_inventory(value, definition, arguments.profile)
        verify_inventory_files(inventory, arguments.root)
        print_inventory_evidence(inventory, raw)
        return 0
    if arguments.command == "verify-meson":
        verify_meson(definition, arguments.build_dir)
        print("meson.policy=verified")
        return 0
    fail("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TupleError as error:
        print(f"renderer-production-tuple: {error}", file=sys.stderr)
        raise SystemExit(1)
