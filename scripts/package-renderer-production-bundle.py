#!/usr/bin/env python3
"""Seal and verify Dory's dual VirGL2 + Venus Metal production renderer worker.

Build-stage archives are provenance inputs, never runtime artifacts. Packaging verifies the
canonical staticLinkClosure, proves that the worker contains its three static archives, verifies
the two exact XPC-local ANGLE Metal dylibs, and inventories the complete signed runtime closure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import posixpath
import re
import stat
import subprocess
import sys
import tempfile
from typing import NoReturn


RUNNER_IDENTIFIER = "com.pythonxi.Dory.HVRunner"
RUNNER_EXECUTABLE = "dory-hv"
WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.RendererWorker"
WORKER_EXECUTABLE = "DoryRendererWorker"
FILESYSTEM_WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.FSWorker"
FILESYSTEM_WORKER_EXECUTABLE = "DoryFSWorker"
OUTER_IDENTIFIER = "com.pythonxi.Dory"
INVENTORY_RELATIVE_PATH = "Resources/renderer-production-inventory.json"
QUALIFICATION_RELATIVE_PATH = "Resources/renderer-bootstrap-qualification.json"
QUALIFICATION_SIGNATURE_RELATIVE_PATH = (
    "Resources/renderer-bootstrap-qualification.json.sig"
)
STATIC_ARCHIVES = (
    "lib/libvirglrenderer.a", "lib/libepoxy.a", "lib/libMoltenVK.a",
)
ANGLE_RUNTIME_NAMES = ("libEGL.dylib", "libGLESv2.dylib")
STATIC_FRAMEWORKS = (
    "AppKit", "CoreGraphics", "Foundation", "IOKit", "IOSurface", "Metal", "QuartzCore",
)
REQUIRED_VIRGL_SYMBOLS = (
    "virgl_renderer_cleanup",
    "virgl_renderer_context_create_fence",
    "virgl_renderer_context_create_with_flags",
    "virgl_renderer_context_destroy",
    "virgl_renderer_ctx_attach_resource",
    "virgl_renderer_ctx_detach_resource",
    "virgl_renderer_fill_caps",
    "virgl_renderer_get_cap_set",
    "virgl_renderer_init",
    "virgl_renderer_poll",
    "virgl_renderer_resource_attach_iov",
    "virgl_renderer_resource_create_blob",
    "virgl_renderer_resource_detach_iov",
    "virgl_renderer_resource_export_blob",
    "virgl_renderer_resource_get_info",
    "virgl_renderer_resource_get_map_info",
    "virgl_renderer_resource_unref",
    "virgl_renderer_submit_cmd2",
    "virgl_renderer_transfer_read_iov",
    "virgl_renderer_transfer_write_iov",
)
LEGACY_RENDERER_NAMES = frozenset({
    "libMoltenVK.a", "libMoltenVK.dylib", "libepoxy.0.dylib",
    "libvirglrenderer.a", "libvirglrenderer.dylib",
    "libvulkan.1.dylib", "MoltenVK_icd.json", "renderer-static-link.json",
})
FORBIDDEN_STRING_AUTHORITIES = (
    "DORY_VIRGLRENDERER_PATH", "VK_DRIVER_FILES", "VK_ICD_FILENAMES",
    "libMoltenVK.dylib", "libepoxy.0.dylib", "libvirglrenderer.dylib",
    "libvulkan.1.dylib", "MoltenVK_icd.json",
)
FORBIDDEN_RUNNER_RENDERER_AUTHORITIES = (
    "DORY_MOLTENVK_ICD", "DORY_VIRGLRENDERER_PATH", "DORY_VIRGLRENDERER",
    "DORY_VIRGL_SYNC_MODE", "VK_ICD_FILENAMES", "libvirglrenderer.dylib",
    "MoltenVK_icd.json",
)
FORBIDDEN_SYMBOL = re.compile(
    r"_(?:CGL[A-Za-z0-9_]*|vtest[A-Za-z0-9_]*)$"
)
REQUIRED_VIRGL_ARCHIVE_MEMBERS = frozenset({
    "vrend_vrend_renderer.c.o",
    "vrend_vrend_winsys.c.o",
    "vrend_vrend_winsys_egl.c.o",
    "venus_vkr_renderer.c.o",
    "proxy_proxy_renderer.c.o",
    "proxy_proxy_server.c.o",
    ".._server_render_server.c.o",
    ".._server_render_worker.c.o",
})
FORBIDDEN_VIRGL_ARCHIVE_MEMBER_PREFIXES = (
    "vtest_", "drm_", "neptune_",
)
MAX_PLIST_BYTES = 1024 * 1024
MAX_JSON_BYTES = 1024 * 1024
EXPECTED_RUNNER_ENTITLEMENTS = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.hypervisor": True,
}
RENDERER_APP_SANDBOX_GROUP = "864H636QW4.dory-renderer"


class PackagingError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise PackagingError(message)


def run(arguments: list[str], label: str, *, capture: bool = True) -> str:
    try:
        result = subprocess.run(
            arguments, check=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError) and error.stdout:
            detail = f": {error.stdout.strip()}"
        fail(f"{label} failed{detail}")
    return result.stdout.strip() if capture else ""


def direct_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        status = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISDIR(status.st_mode) or path.is_symlink():
        fail(f"{label} must be a direct directory")
    return path


def direct_regular_file(path: pathlib.Path, label: str, *, executable: bool = False) -> pathlib.Path:
    try:
        status = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if (not stat.S_ISREG(status.st_mode) or path.is_symlink() or status.st_nlink != 1
            or status.st_size <= 0):
        fail(f"{label} must be a nonempty direct regular file with one link")
    if executable and status.st_mode & 0o111 == 0:
        fail(f"{label} must be executable")
    return path


def ensure_direct_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        path.mkdir()
    except FileExistsError:
        pass
    except OSError as error:
        fail(f"cannot create {label}: {error}")
    return direct_directory(path, label)


def plist(path: pathlib.Path, label: str) -> dict[str, object]:
    direct_regular_file(path, label)
    try:
        raw = path.read_bytes()
        if not raw or len(raw) > MAX_PLIST_BYTES:
            fail(f"{label} has an invalid size")
        value = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{label} is invalid: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root must be a dictionary")
    return value


def canonical_json_file(path: pathlib.Path, label: str) -> dict[str, object]:
    direct_regular_file(path, label)
    try:
        raw = path.read_bytes()
        if not raw or len(raw) > MAX_JSON_BYTES:
            fail(f"{label} has an invalid size")
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    canonical = (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode()
    if raw != canonical:
        fail(f"{label} must be canonical JSON")
    return value


def qualification_path(contents: pathlib.Path) -> pathlib.Path:
    return contents.joinpath(*pathlib.PurePosixPath(QUALIFICATION_RELATIVE_PATH).parts)


def qualification_signature_path(contents: pathlib.Path) -> pathlib.Path:
    return contents.joinpath(
        *pathlib.PurePosixPath(QUALIFICATION_SIGNATURE_RELATIVE_PATH).parts
    )


def validate_bundle_identity(bundle: pathlib.Path, *, identifier: str, executable: str,
                             package_type: str, label: str) -> pathlib.Path:
    direct_directory(bundle, label)
    contents = direct_directory(bundle / "Contents", f"{label} Contents")
    macos = direct_directory(contents / "MacOS", f"{label} MacOS")
    info = plist(contents / "Info.plist", f"{label} Info.plist")
    for key, expected in {
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable,
        "CFBundlePackageType": package_type,
    }.items():
        if info.get(key) != expected:
            fail(f"{label} {key} must be {expected}")
    actual = {path.name for path in macos.iterdir()}
    if actual != {executable}:
        fail(f"{label} MacOS executable set differs (actual={sorted(actual)})")
    return direct_regular_file(macos / executable, f"{label} executable", executable=True)


def macho_architectures(path: pathlib.Path) -> tuple[str, ...]:
    return tuple(run(["lipo", "-archs", os.fspath(path)], f"inspect {path.name} architectures").split())


def verify_arm64(path: pathlib.Path, label: str) -> None:
    if macho_architectures(path) != ("arm64",):
        fail(f"{label} must contain exactly the arm64 architecture")


def macho_dependencies(path: pathlib.Path) -> list[str]:
    lines = run(["otool", "-L", os.fspath(path)], f"inspect {path.name} dependencies").splitlines()
    result: list[str] = []
    for line in lines[1:]:
        match = re.match(r"^\s+(.+?)\s+\(compatibility version ", line)
        if not match:
            fail(f"{path.name} has an unparseable load command: {line!r}")
        result.append(match.group(1))
    return result


def macho_rpaths(path: pathlib.Path) -> list[str]:
    lines = run(["otool", "-l", os.fspath(path)], f"inspect {path.name} load commands").splitlines()
    result: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            if index + 2 >= len(lines):
                fail(f"{path.name} contains a truncated LC_RPATH")
            match = re.match(r"^\s*path (.+?) \(offset \d+\)$", lines[index + 2])
            if not match:
                fail(f"{path.name} contains an unparseable LC_RPATH")
            result.append(match.group(1))
    return result


def verify_system_dependencies(path: pathlib.Path, label: str) -> None:
    for dependency in macho_dependencies(path):
        if not dependency.startswith(("/System/Library/", "/usr/lib/")):
            fail(f"{label} has non-system runtime dependency {dependency}")
        if posixpath.normpath(dependency) != dependency:
            fail(f"{label} has noncanonical system dependency {dependency}")


def verify_system_load_graph(path: pathlib.Path, label: str) -> None:
    verify_system_dependencies(path, label)
    if macho_rpaths(path):
        fail(f"{label} contains LC_RPATH despite its closed static renderer graph")


def symbol_names(output: str) -> set[str]:
    result: set[str] = set()
    for line in output.splitlines():
        match = re.search(r"(_[A-Za-z][A-Za-z0-9_$]*)$", line.strip())
        if match:
            result.add(match.group(1))
    return result


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def code_directory_hash(value: str, label: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value) or value == "0" * 40:
        fail(f"{label} must be a nonzero 40-hex CodeDirectory hash")
    return value.lower()


def relative_direct_tree(root: pathlib.Path, label: str) -> tuple[set[str], set[str]]:
    files: set[str] = set()
    directories: set[str] = set()
    def walk_error(error: OSError) -> NoReturn:
        fail(f"cannot traverse {label}: {error}")
    for directory, names, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        current = pathlib.Path(directory)
        for name in names:
            path = direct_directory(current / name, f"{label} directory")
            directories.add(path.relative_to(root).as_posix())
        for name in filenames:
            path = direct_regular_file(current / name, f"{label} artifact")
            files.add(path.relative_to(root).as_posix())
    return files, directories


def verify_static_archive_policy(link_root: pathlib.Path) -> None:
    virgl = link_root / "lib/libvirglrenderer.a"
    epoxy = link_root / "lib/libepoxy.a"
    moltenvk = link_root / "lib/libMoltenVK.a"
    for archive, label in (
        (virgl, "virglrenderer archive"),
        (epoxy, "libepoxy archive"),
        (moltenvk, "MoltenVK archive"),
    ):
        direct_regular_file(archive, label)
        verify_arm64(archive, label)
    member_output = run(["ar", "-t", os.fspath(virgl)],
                        "inspect virglrenderer archive members")
    members = {
        posixpath.basename(line.strip())
        for line in member_output.splitlines()
        if line.strip()
    }
    missing_members = sorted(REQUIRED_VIRGL_ARCHIVE_MEMBERS - members)
    if missing_members:
        fail(
            "virglrenderer archive is missing required Venus thread member "
            f"{missing_members[0]}"
        )
    forbidden_members = sorted(
        member for member in members
        if member.startswith(FORBIDDEN_VIRGL_ARCHIVE_MEMBER_PREFIXES)
    )
    if forbidden_members:
        fail(
            "virglrenderer archive contains a forbidden classic/DRM/Neptune object "
            f"{forbidden_members[0]}"
        )
    virgl_symbols = symbol_names(run(["nm", os.fspath(virgl)], "inspect virglrenderer symbols"))
    for symbol in REQUIRED_VIRGL_SYMBOLS:
        if f"_{symbol}" not in virgl_symbols:
            fail(f"virglrenderer archive is missing {symbol}")
    for symbol in virgl_symbols:
        if FORBIDDEN_SYMBOL.fullmatch(symbol):
            fail(f"virglrenderer archive contains forbidden symbol {symbol}")
    for symbol in ("_vrend_renderer_init", "_vrend_renderer_context_create"):
        if symbol not in virgl_symbols:
            fail(f"virglrenderer archive is missing classic renderer symbol {symbol}")
    epoxy_strings = set(
        run(["strings", "-a", os.fspath(epoxy)], "inspect static libepoxy resolver").splitlines()
    )
    expected_resolvers = {
        "@loader_path/../Frameworks/libEGL.dylib",
        "@loader_path/../Frameworks/libGLESv2.dylib",
    }
    if not expected_resolvers.issubset(epoxy_strings):
        fail("static libepoxy lacks its fixed XPC-local ANGLE resolver")
    if epoxy_strings.intersection({
        "libEGL.dylib", "libGLESv2.dylib", "@rpath/libEGL.dylib",
        "@rpath/libGLESv2.dylib",
    }):
        fail("static libepoxy retains an ambient ANGLE resolver")
    molten_globals = symbol_names(run(["nm", "-gU", os.fspath(moltenvk)], "inspect MoltenVK globals"))
    if "_vkGetInstanceProcAddr" not in molten_globals:
        fail("MoltenVK archive is missing vkGetInstanceProcAddr")
    unexpected_vk = sorted(symbol for symbol in molten_globals
                           if re.fullmatch(r"_vk[A-Z][A-Za-z0-9_]*", symbol)
                           and symbol != "_vkGetInstanceProcAddr")
    if unexpected_vk:
        fail(f"MoltenVK archive exports forbidden Vulkan entrypoints {unexpected_vk}")
    for symbol in symbol_names(run(["nm", os.fspath(moltenvk)], "inspect all MoltenVK symbols")):
        if FORBIDDEN_SYMBOL.fullmatch(symbol):
            fail(f"MoltenVK archive contains forbidden symbol {symbol}")


def verify_static_link_stage(repo_root: pathlib.Path, link_root: pathlib.Path,
                             link_inventory: pathlib.Path) -> None:
    direct_directory(link_root, "renderer static link stage")
    direct_regular_file(link_inventory, "renderer static link inventory")
    try:
        if link_inventory.parent.resolve(strict=True) != link_root.resolve(strict=True):
            fail("renderer static link inventory must be a direct child of its stage")
    except OSError as error:
        fail(f"cannot resolve renderer static link stage: {error}")
    actual_files, actual_directories = relative_direct_tree(link_root, "renderer static link stage")
    definition_path = direct_regular_file(
        repo_root / "Config/DoryRendererProductionTuple.json", "renderer tuple definition"
    )
    try:
        definition = json.loads(definition_path.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"renderer tuple definition is invalid: {error}")
    if not isinstance(definition, dict):
        fail("renderer tuple definition root must be an object")
    components = definition.get("artifactProfiles", {}).get("staticLinkClosure")
    if not isinstance(components, dict):
        fail("renderer tuple has no staticLinkClosure profile")
    expected_files = {
        relative
        for paths in components.values()
        if isinstance(paths, list)
        for relative in paths
        if isinstance(relative, str)
    }
    expected_files.add(link_inventory.name)
    expected_directories: set[str] = set()
    for relative in expected_files:
        parent = pathlib.PurePosixPath(relative).parent
        while parent != pathlib.PurePosixPath("."):
            expected_directories.add(parent.as_posix())
            parent = parent.parent
    if actual_files != expected_files or actual_directories != expected_directories:
        fail("renderer static link stage differs "
             f"(files={sorted(actual_files)}, directories={sorted(actual_directories)})")
    run([
        sys.executable, os.fspath(repo_root / "scripts/renderer-production-tuple.py"),
        "--definition", os.fspath(repo_root / "Config/DoryRendererProductionTuple.json"),
        "verify-inventory", "--profile", "staticLinkClosure", "--root",
        os.fspath(link_root), "--inventory", os.fspath(link_inventory),
    ], "verify canonical renderer static link inventory", capture=False)
    contract = canonical_json_file(link_root / "renderer-static-link.json",
                                   "renderer static link contract")
    expected_contract = {
        "appleFrameworks": list(STATIC_FRAMEWORKS),
        "architecture": "arm64",
        "archives": [{"path": path, "sha256": sha256(link_root / path)} for path in STATIC_ARCHIVES],
        "cxxRuntime": "c++",
        "forceLoadArchives": list(STATIC_ARCHIVES),
        "kind": "dev.dory.renderer-static-link-contract",
        "requiredCompileDefinitions": [
            "DORY_VIRGL_RENDERER_DUAL_METAL",
            "DORY_VIRGL_RENDERER_STATIC_LINKED",
        ],
        "requiredVirGLCapsets": [2, 4],
        "runtimeLibraries": [
            {
                "installName": f"@loader_path/{name}",
                "path": f"Frameworks/{name}",
                "sha256": sha256(link_root / "Frameworks" / name),
            }
            for name in ANGLE_RUNTIME_NAMES
        ],
        "schemaVersion": 2,
    }
    if contract != expected_contract:
        fail("renderer static link contract differs from its exact dual-Metal closure")
    verify_static_archive_policy(link_root)


def read_entitlements(bundle: pathlib.Path, label: str) -> dict[str, object]:
    try:
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", os.fspath(bundle)], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        value = plistlib.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        fail(f"inspect {label} entitlements failed: {error}")
    if not isinstance(value, dict):
        fail(f"{label} entitlements must be a dictionary")
    return value


def verify_signature(path: pathlib.Path, *, label: str, identifier: str,
                     expected_team: str, allow_adhoc_test: bool, deep: bool = False) -> str:
    arguments = ["codesign", "--verify", "--strict"]
    if deep:
        arguments.append("--deep")
    arguments.append(os.fspath(path))
    run(arguments, f"verify {label}")
    details = run(["codesign", "-d", "--verbose=4", os.fspath(path)],
                  f"inspect {label} signature")
    if not re.search(rf"(?m)^Identifier={re.escape(identifier)}$", details):
        fail(f"{label} code-signing identifier is not {identifier}")
    if expected_team == "-":
        if not allow_adhoc_test or not re.search(r"(?m)^TeamIdentifier=not set$", details):
            fail(f"{label} must use the explicitly allowed ad-hoc test identity")
    elif not re.search(rf"(?m)^TeamIdentifier={re.escape(expected_team)}$", details):
        fail(f"{label} is not signed by team {expected_team}")
    if not re.search(r"(?m)^CodeDirectory .*flags=.*\(.*runtime.*\)", details):
        fail(f"{label} is not sealed with the hardened runtime")
    match = re.search(r"(?m)^CDHash=([0-9a-fA-F]+)$", details)
    if not match:
        fail(f"{label} signature has no CDHash")
    return code_directory_hash(match.group(1), f"{label} CDHash")


def worker_bundle(runner_app: pathlib.Path) -> pathlib.Path:
    return runner_app / "Contents/XPCServices/DoryRendererWorker.xpc"


def filesystem_worker_bundle(runner_app: pathlib.Path) -> pathlib.Path:
    return runner_app / "Contents/XPCServices/DoryFSWorker.xpc"


def verify_xpc_closure(runner_app: pathlib.Path) -> None:
    services = direct_directory(runner_app / "Contents/XPCServices", "DoryHVRunner.app XPCServices")
    actual = {path.name for path in services.iterdir()}
    expected = {"DoryFSWorker.xpc", "DoryRendererWorker.xpc"}
    if actual != expected:
        fail(f"runner XPCServices set differs (actual={sorted(actual)})")
    for path in services.iterdir():
        direct_directory(path, f"runner nested service {path.name}")


def verify_filesystem_worker(runner_app: pathlib.Path, expected_team: str,
                             allow_adhoc_test: bool) -> None:
    bundle = filesystem_worker_bundle(runner_app)
    executable = validate_bundle_identity(
        bundle, identifier=FILESYSTEM_WORKER_IDENTIFIER,
        executable=FILESYSTEM_WORKER_EXECUTABLE, package_type="XPC!", label="DoryFSWorker.xpc",
    )
    verify_arm64(executable, "DoryFSWorker.xpc executable")
    verify_signature(bundle, label="DoryFSWorker.xpc", identifier=FILESYSTEM_WORKER_IDENTIFIER,
                     expected_team=expected_team, allow_adhoc_test=allow_adhoc_test)
    # The worker accepts only signed-XPC transferred, identity-sealed directory descriptors. App
    # Sandbox cannot delegate descendant openat authority through those descriptors, and the
    # unsandboxed hypervisor cannot mint a Powerbox bookmark for this distinct XPC identity.
    # Requiring an empty entitlement set makes that deliberate filesystem namespace choice exact;
    # any added network, device, bookmark, or temporary-exception authority still fails closed.
    if read_entitlements(bundle, "DoryFSWorker.xpc") != {}:
        fail("DoryFSWorker.xpc entitlements differ from its production authority")


def verify_angle_runtime_closure(bundle: pathlib.Path, expected_team: str,
                                 allow_adhoc_test: bool) -> None:
    frameworks = direct_directory(
        bundle / "Contents/Frameworks", "DoryRendererWorker.xpc Frameworks"
    )
    actual = {path.name for path in frameworks.iterdir()}
    if actual != set(ANGLE_RUNTIME_NAMES):
        fail(f"DoryRendererWorker.xpc ANGLE runtime set differs (actual={sorted(actual)})")
    for name in ANGLE_RUNTIME_NAMES:
        library = direct_regular_file(frameworks / name, f"ANGLE runtime {name}", executable=True)
        verify_arm64(library, f"ANGLE runtime {name}")
        expected_id = f"@loader_path/{name}"
        identifiers = run(["otool", "-D", os.fspath(library)], f"inspect {name} install name").splitlines()
        # `otool -D` prefixes its payload with the inspected path followed by a colon. Treat that
        # framing as part of the exact output contract so a valid loader-local ID is accepted while
        # extra or reordered install names still fail closed.
        if identifiers != [f"{os.fspath(library)}:", expected_id]:
            fail(f"ANGLE runtime {name} install name is not {expected_id}")
        if macho_rpaths(library):
            fail(f"ANGLE runtime {name} contains LC_RPATH")
        for dependency in macho_dependencies(library):
            if dependency == expected_id:
                continue
            if not dependency.startswith(("/System/Library/", "/usr/lib/")):
                fail(f"ANGLE runtime {name} has non-system/non-sibling dependency {dependency}")
            if posixpath.normpath(dependency) != dependency:
                fail(f"ANGLE runtime {name} has noncanonical dependency {dependency}")
        verify_signature(
            library,
            label=f"ANGLE runtime {name}",
            identifier=f"{WORKER_IDENTIFIER}.{name}",
            expected_team=expected_team,
            allow_adhoc_test=allow_adhoc_test,
        )


def verify_worker_linkage(executable: pathlib.Path) -> None:
    direct_regular_file(
        executable, "DoryRendererWorker production executable", executable=True
    )
    verify_arm64(executable, "DoryRendererWorker production executable")
    verify_system_load_graph(executable, "DoryRendererWorker production executable")
    defined = symbol_names(run(["nm", "-gU", os.fspath(executable)],
                               "inspect renderer worker definitions"))
    for symbol in (
        *REQUIRED_VIRGL_SYMBOLS,
        "epoxy_eglInitialize",
        "epoxy_glGetString",
        "vkGetInstanceProcAddr",
    ):
        if f"_{symbol}" not in defined:
            fail(f"renderer worker is missing statically linked symbol {symbol}")
    undefined = symbol_names(run(["nm", "-u", os.fspath(executable)],
                                 "inspect renderer worker undefined symbols"))
    forbidden_undefined = sorted(symbol for symbol in undefined
        if symbol.startswith("_virgl_renderer_") or symbol == "_vkGetInstanceProcAddr"
        or symbol.startswith(("_epoxy_", "_vrend_", "_egl"))
        or re.fullmatch(r"_gl[A-Z][A-Za-z0-9_]*", symbol)
        or FORBIDDEN_SYMBOL.fullmatch(symbol))
    if forbidden_undefined:
        fail(f"renderer worker retains forbidden undefined symbols {forbidden_undefined}")
    all_symbols = symbol_names(run(["nm", os.fspath(executable)],
                                   "inspect all renderer worker symbols"))
    # virglrenderer intentionally marks its classic-renderer implementation entry points hidden.
    # The final Mach-O therefore retains them as local text symbols even when the archive was
    # force-loaded.  Requiring them to be externally exported contradicts that visibility policy;
    # requiring their exact local-or-global definitions still proves the VirGL2 implementation was
    # linked into the worker instead of accepting a Venus-only public API shell.
    for symbol in ("vrend_renderer_context_create", "vrend_renderer_init"):
        if f"_{symbol}" not in all_symbols:
            fail(f"renderer worker is missing statically linked symbol {symbol}")
    forbidden_symbols = sorted(symbol for symbol in all_symbols if FORBIDDEN_SYMBOL.fullmatch(symbol))
    if forbidden_symbols:
        fail(f"renderer worker contains forbidden classic/GL/loader symbols {forbidden_symbols}")
    strings = run(["strings", "-a", os.fspath(executable)], "inspect renderer worker strings")
    for authority in FORBIDDEN_STRING_AUTHORITIES:
        if authority in strings:
            fail(f"renderer worker contains forbidden runtime authority {authority}")
    string_set = set(strings.splitlines())
    required_resolvers = {
        "@loader_path/../Frameworks/libEGL.dylib",
        "@loader_path/../Frameworks/libGLESv2.dylib",
    }
    if not required_resolvers.issubset(string_set):
        fail("renderer worker lacks its exact XPC-local ANGLE resolver")
    if string_set.intersection({
        "libEGL.dylib", "libGLESv2.dylib", "@rpath/libEGL.dylib",
        "@rpath/libGLESv2.dylib",
    }):
        fail("renderer worker retains ambient ANGLE load authority")


def verify_runner_renderer_closure(executable: pathlib.Path) -> None:
    for dependency in macho_dependencies(executable):
        if "/OpenGL.framework/" in dependency:
            fail("DoryHVRunner.app retains the retired in-process OpenGL renderer dependency")
    strings = run(["strings", "-a", os.fspath(executable)], "inspect runner renderer authority")
    for authority in FORBIDDEN_RUNNER_RENDERER_AUTHORITIES:
        if authority in strings:
            fail(f"DoryHVRunner.app retains retired renderer authority {authority}")


def canonicalize_worker_linkage(executable: pathlib.Path, developer_dir: pathlib.Path,
                                receipt: pathlib.Path) -> None:
    """Remove SwiftPM's unused Xcode compatibility rpath before the worker is signed."""
    direct_regular_file(
        executable, "DoryRendererWorker link output", executable=True
    )
    verify_arm64(executable, "DoryRendererWorker link output")
    verify_system_dependencies(executable, "DoryRendererWorker link output")
    developer = direct_directory(developer_dir, "selected Xcode developer directory")
    try:
        developer = developer.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve selected Xcode developer directory: {error}")

    rpaths = macho_rpaths(executable)
    if len(rpaths) != 1:
        fail(
            "DoryRendererWorker link output must contain exactly one SwiftPM compatibility rpath "
            f"before canonicalization (actual={rpaths})"
        )
    raw_rpath = rpaths[0]
    if not raw_rpath.startswith("/") or posixpath.normpath(raw_rpath) != raw_rpath:
        fail(
            "DoryRendererWorker SwiftPM compatibility rpath is not canonical and absolute "
            f"(actual={raw_rpath!r})"
        )
    rpath = pathlib.Path(raw_rpath)
    direct_directory(rpath, "SwiftPM compatibility library directory")
    try:
        relative = rpath.resolve(strict=True).relative_to(developer)
    except (OSError, ValueError) as error:
        fail(f"DoryRendererWorker rpath is outside the selected Xcode toolchain: {error}")
    parts = relative.parts
    if (len(parts) != 6
            or parts[:4] != ("Toolchains", "XcodeDefault.xctoolchain", "usr", "lib")
            or not re.fullmatch(r"swift-[0-9]+\.[0-9]+", parts[4])
            or parts[5] != "macosx"):
        fail("DoryRendererWorker rpath is not the exact Xcode Swift compatibility directory")

    direct_directory(receipt.parent, "worker canonicalization receipt directory")
    if os.path.lexists(receipt):
        fail("worker canonicalization receipt already exists")
    before = sha256(executable)
    run([
        "/usr/bin/xcrun", "--sdk", "macosx", "install_name_tool",
        "-delete_rpath", raw_rpath, os.fspath(executable),
    ], "remove SwiftPM compatibility rpath", capture=False)
    if macho_rpaths(executable):
        fail("DoryRendererWorker retains LC_RPATH after canonicalization")
    verify_system_dependencies(executable, "canonical DoryRendererWorker link output")
    after = sha256(executable)
    if after == before:
        fail("DoryRendererWorker canonicalization did not change its link output")

    value = {
        "inputExecutableSHA256": before,
        "kind": "dev.dory.renderer-worker-link-canonicalization",
        "outputExecutableSHA256": after,
        "removedToolchainRPaths": [relative.as_posix()],
        "schemaVersion": 1,
    }
    temporary = receipt.with_name(f".{receipt.name}.tmp-{os.getpid()}")
    try:
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o644)
        os.replace(temporary, receipt)
    except OSError as error:
        fail(f"cannot publish worker canonicalization receipt: {error}")
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
    canonical_json_file(receipt, "worker canonicalization receipt")


def verify_renderer_worker(runner_app: pathlib.Path, expected_team: str,
                           allow_adhoc_test: bool) -> tuple[pathlib.Path, str]:
    verify_xpc_closure(runner_app)
    verify_filesystem_worker(runner_app, expected_team, allow_adhoc_test)
    bundle = worker_bundle(runner_app)
    executable = validate_bundle_identity(
        bundle, identifier=WORKER_IDENTIFIER, executable=WORKER_EXECUTABLE,
        package_type="XPC!", label="DoryRendererWorker.xpc",
    )
    verify_arm64(executable, "DoryRendererWorker.xpc executable")
    verify_angle_runtime_closure(bundle, expected_team, allow_adhoc_test)
    info = plist(bundle / "Contents/Info.plist", "DoryRendererWorker.xpc Info.plist")
    if info.get("XPCService") != {"ServiceType": "Application"}:
        fail("DoryRendererWorker.xpc must use the Application XPC service type")
    verify_worker_linkage(executable)
    cdhash = verify_signature(
        bundle, label="DoryRendererWorker.xpc", identifier=WORKER_IDENTIFIER,
        expected_team=expected_team, allow_adhoc_test=allow_adhoc_test,
    )
    if read_entitlements(bundle, "DoryRendererWorker.xpc") != {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.application-groups": [RENDERER_APP_SANDBOX_GROUP],
    }:
        fail("DoryRendererWorker.xpc entitlements exceed its static renderer sandbox")
    return executable, cdhash


def reject_legacy_bundle_artifacts(contents: pathlib.Path) -> None:
    for directory, names, filenames in os.walk(contents, followlinks=False):
        current = pathlib.Path(directory)
        for name in names:
            path = current / name
            if path.is_symlink():
                fail(f"runner bundle contains symlink directory {path.relative_to(contents)}")
            if name == "vulkan" and path.parent.name == "Resources":
                fail("runner bundle contains forbidden Vulkan ICD resource directory")
        for name in filenames:
            if name in LEGACY_RENDERER_NAMES:
                fail(f"runner bundle contains forbidden renderer artifact {name}")


def inventory_path(contents: pathlib.Path) -> pathlib.Path:
    return contents.joinpath(*pathlib.PurePosixPath(INVENTORY_RELATIVE_PATH).parts)


def verify_bundle_inventory(repo_root: pathlib.Path, contents: pathlib.Path) -> str:
    inventory = direct_regular_file(inventory_path(contents), "renderer bundle inventory")
    run([
        sys.executable, os.fspath(repo_root / "scripts/renderer-production-tuple.py"),
        "--definition", os.fspath(repo_root / "Config/DoryRendererProductionTuple.json"),
        "verify-inventory", "--profile", "rendererBundle", "--root", os.fspath(contents),
        "--inventory", os.fspath(inventory),
    ], "verify canonical renderer bundle inventory", capture=False)
    return sha256(inventory)


def create_bundle_inventory(repo_root: pathlib.Path, contents: pathlib.Path) -> str:
    resources = ensure_direct_directory(contents / "Resources", "runner Resources")
    destination = resources / pathlib.PurePosixPath(INVENTORY_RELATIVE_PATH).name
    temporary = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    try:
        run([
            sys.executable, os.fspath(repo_root / "scripts/renderer-production-tuple.py"),
            "--definition", os.fspath(repo_root / "Config/DoryRendererProductionTuple.json"),
            "create-inventory", "--profile", "rendererBundle", "--root", os.fspath(contents),
            "--output", os.fspath(temporary),
        ], "create canonical renderer bundle inventory", capture=False)
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    except OSError as error:
        fail(f"cannot publish renderer bundle inventory: {error}")
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
    return verify_bundle_inventory(repo_root, contents)


def verify_qualification_evidence(
    repo_root: pathlib.Path,
    contents: pathlib.Path,
    managed_kernel: pathlib.Path,
    *,
    require_release_signature: bool,
    allow_unsealed_staging: bool,
) -> tuple[str, str | None]:
    definition_path = direct_regular_file(
        repo_root / "Config/DoryRendererProductionTuple.json", "renderer tuple definition"
    )
    runner = contents.parent
    verifier_arguments = [
        sys.executable,
        os.fspath(repo_root / "scripts/verify-renderer-bootstrap-qualification.py"),
        "--runner-app", os.fspath(runner),
        "--managed-kernel", os.fspath(managed_kernel),
        "--repo-root", os.fspath(repo_root),
    ]
    if allow_unsealed_staging:
        verifier_arguments.append("--allow-unsealed-staging")
    if require_release_signature:
        verifier_arguments.append("--require-release-signature")
    run(verifier_arguments, "verify candidate-bound renderer qualification", capture=False)

    receipt_path = direct_regular_file(
        qualification_path(contents), "renderer bootstrap qualification receipt"
    )
    signature = qualification_signature_path(contents)
    signature_digest: str | None = None
    if os.path.lexists(signature):
        signature_digest = sha256(
            direct_regular_file(signature, "renderer qualification detached signature")
        )

    profile = (
        "rendererReleaseQualificationEvidence"
        if signature_digest is not None
        else "rendererQualificationEvidence"
    )
    with tempfile.TemporaryDirectory(prefix="dory-renderer-evidence-") as temporary:
        evidence_inventory = pathlib.Path(temporary) / "inventory.json"
        run([
            sys.executable, os.fspath(repo_root / "scripts/renderer-production-tuple.py"),
            "--definition", os.fspath(definition_path), "create-inventory",
            "--profile", profile, "--root", os.fspath(contents),
            "--output", os.fspath(evidence_inventory),
        ], "create renderer qualification evidence inventory", capture=False)
        run([
            sys.executable, os.fspath(repo_root / "scripts/renderer-production-tuple.py"),
            "--definition", os.fspath(definition_path), "verify-inventory",
            "--profile", profile, "--root", os.fspath(contents),
            "--inventory", os.fspath(evidence_inventory),
        ], "verify renderer qualification evidence inventory", capture=False)
    return sha256(receipt_path), signature_digest


def unlink_phase_file(path: pathlib.Path, label: str) -> None:
    try:
        status = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not (stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode)):
        fail(f"{label} is not a removable phase-owned file")
    try:
        path.unlink()
    except OSError as error:
        fail(f"cannot remove {label}: {error}")


def remove_empty_directory(path: pathlib.Path, label: str) -> None:
    try:
        status = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not stat.S_ISDIR(status.st_mode) or path.is_symlink():
        fail(f"{label} must be a direct directory")
    try:
        if not any(path.iterdir()):
            path.rmdir()
    except OSError as error:
        fail(f"cannot prune {label}: {error}")


def prune(arguments: argparse.Namespace) -> None:
    runner = arguments.runner_app
    validate_bundle_identity(runner, identifier=RUNNER_IDENTIFIER, executable=RUNNER_EXECUTABLE,
                             package_type="APPL", label="DoryHVRunner.app")
    contents = direct_directory(runner / "Contents", "DoryHVRunner.app Contents")
    frameworks = contents / "Frameworks"
    if os.path.lexists(frameworks):
        direct_directory(frameworks, "runner Frameworks")
        for name in LEGACY_RENDERER_NAMES:
            unlink_phase_file(frameworks / name, f"stale renderer artifact {name}")
        remove_empty_directory(frameworks, "empty runner Frameworks")
    resources = contents / "Resources"
    if os.path.lexists(resources):
        direct_directory(resources, "runner Resources")
        unlink_phase_file(inventory_path(contents), "stale renderer bundle inventory")
        unlink_phase_file(
            qualification_path(contents), "stale renderer bootstrap qualification receipt"
        )
        unlink_phase_file(
            qualification_signature_path(contents),
            "stale renderer bootstrap qualification signature",
        )
        icd = resources / "vulkan/icd.d/MoltenVK_icd.json"
        unlink_phase_file(icd, "stale MoltenVK ICD")
        remove_empty_directory(icd.parent, "empty Vulkan ICD directory")
        remove_empty_directory(icd.parent.parent, "empty Vulkan resource directory")
        remove_empty_directory(resources, "empty runner Resources")
    print(f"renderer.bundle={runner}")
    print("renderer.packaging=disabled-pruned")


def package(arguments: argparse.Namespace, repo_root: pathlib.Path) -> None:
    runner = arguments.runner_app
    contents = runner / "Contents"
    direct_directory(runner.parent, "runner product directory")
    runner_executable = validate_bundle_identity(
        runner, identifier=RUNNER_IDENTIFIER, executable=RUNNER_EXECUTABLE,
        package_type="APPL", label="DoryHVRunner.app",
    )
    verify_arm64(runner_executable, "DoryHVRunner.app executable")
    verify_runner_renderer_closure(runner_executable)
    if plist(arguments.runner_entitlements, "DoryHVRunner production entitlements") != (
        EXPECTED_RUNNER_ENTITLEMENTS
    ):
        fail("DoryHVRunner production entitlements differ from its exact static-renderer authority")
    try:
        runner_root = runner.resolve(strict=True)
        link_root = arguments.link_root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve renderer packaging roots: {error}")
    if runner_root == link_root or runner_root in link_root.parents or link_root in runner_root.parents:
        fail("renderer static link stage and runner bundle must not overlap")
    verify_static_link_stage(repo_root, arguments.link_root, arguments.link_inventory)
    _, cdhash = verify_renderer_worker(runner, arguments.expected_team, arguments.allow_adhoc_test)
    resources = ensure_direct_directory(contents / "Resources", "runner Resources")
    unlink_phase_file(
        qualification_path(contents), "stale renderer bootstrap qualification receipt"
    )
    unlink_phase_file(
        qualification_signature_path(contents),
        "stale renderer bootstrap qualification signature",
    )
    reject_legacy_bundle_artifacts(contents)
    inventory_digest = create_bundle_inventory(repo_root, contents)
    reject_legacy_bundle_artifacts(contents)
    verify_renderer_worker(runner, arguments.expected_team, arguments.allow_adhoc_test)
    print(f"renderer.bundle={runner}")
    print(f"renderer.worker.cdhash={cdhash}")
    print(f"renderer.inventory.sha256={inventory_digest}")
    print("renderer.packaging=prepared-dual-metal")


def seal_evidence(arguments: argparse.Namespace, repo_root: pathlib.Path) -> None:
    runner = arguments.runner_app
    contents = runner / "Contents"
    runner_executable = validate_bundle_identity(
        runner, identifier=RUNNER_IDENTIFIER, executable=RUNNER_EXECUTABLE,
        package_type="APPL", label="DoryHVRunner.app",
    )
    verify_arm64(runner_executable, "DoryHVRunner.app executable")
    verify_runner_renderer_closure(runner_executable)
    _, cdhash = verify_renderer_worker(
        runner, arguments.expected_team, arguments.allow_adhoc_test
    )
    reject_legacy_bundle_artifacts(contents)
    inventory_digest = verify_bundle_inventory(repo_root, contents)
    receipt_digest, signature_digest = verify_qualification_evidence(
        repo_root,
        contents,
        arguments.managed_kernel,
        require_release_signature=arguments.require_release_signature,
        allow_unsealed_staging=True,
    )
    print(f"renderer.bundle={runner}")
    print(f"renderer.worker.cdhash={cdhash}")
    print(f"renderer.inventory.sha256={inventory_digest}")
    print(f"renderer.qualification.sha256={receipt_digest}")
    print(
        "renderer.qualification.releaseSignature.sha256="
        f"{signature_digest if signature_digest is not None else 'absent-preview'}"
    )
    print("renderer.qualification=sealed-candidate-evidence")


def verify(arguments: argparse.Namespace, repo_root: pathlib.Path) -> None:
    runner = arguments.runner_app
    contents = runner / "Contents"
    executable = validate_bundle_identity(
        runner, identifier=RUNNER_IDENTIFIER, executable=RUNNER_EXECUTABLE,
        package_type="APPL", label="DoryHVRunner.app",
    )
    verify_arm64(executable, "DoryHVRunner.app executable")
    verify_runner_renderer_closure(executable)
    _, cdhash = verify_renderer_worker(
        runner, arguments.expected_team, arguments.allow_adhoc_test
    )
    reject_legacy_bundle_artifacts(contents)
    inventory_digest = verify_bundle_inventory(repo_root, contents)
    receipt_digest, signature_digest = verify_qualification_evidence(
        repo_root,
        contents,
        arguments.managed_kernel,
        require_release_signature=arguments.require_release_signature,
        allow_unsealed_staging=False,
    )
    verify_signature(runner, label="DoryHVRunner.app", identifier=RUNNER_IDENTIFIER,
                     expected_team=arguments.expected_team,
                     allow_adhoc_test=arguments.allow_adhoc_test, deep=True)
    if read_entitlements(runner, "DoryHVRunner.app") != EXPECTED_RUNNER_ENTITLEMENTS:
        fail("DoryHVRunner.app entitlements differ from its exact static-renderer authority")
    if arguments.outer_app is not None:
        outer = arguments.outer_app
        outer_executable = validate_bundle_identity(
            outer, identifier=OUTER_IDENTIFIER, executable="Dory", package_type="APPL",
            label="Dory.app",
        )
        verify_arm64(outer_executable, "Dory.app executable")
        expected_runner = direct_directory(outer / "Contents/Helpers", "Dory.app Helpers") / "DoryHVRunner.app"
        if os.path.abspath(expected_runner) != os.path.abspath(runner):
            fail("DoryHVRunner.app is not at the fixed outer application path")
        verify_signature(outer, label="Dory.app", identifier=OUTER_IDENTIFIER,
                         expected_team=arguments.expected_team,
                         allow_adhoc_test=arguments.allow_adhoc_test, deep=True)
    print(f"renderer.bundle={runner}")
    print(f"renderer.worker.cdhash={cdhash}")
    print(f"renderer.inventory.sha256={inventory_digest}")
    print(f"renderer.qualification.sha256={receipt_digest}")
    print(
        "renderer.qualification.releaseSignature.sha256="
        f"{signature_digest if signature_digest is not None else 'absent-preview'}"
    )
    print("renderer.signatureGraph=verified-dual-metal")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    package_command = commands.add_parser("package")
    package_command.add_argument("--runner-app", type=pathlib.Path, required=True)
    package_command.add_argument("--link-root", type=pathlib.Path, required=True)
    package_command.add_argument("--link-inventory", type=pathlib.Path, required=True)
    package_command.add_argument("--runner-entitlements", type=pathlib.Path, required=True)
    package_command.add_argument("--expected-team", required=True)
    package_command.add_argument("--allow-adhoc-test", action="store_true")
    verify_command = commands.add_parser("verify")
    verify_command.add_argument("--runner-app", type=pathlib.Path, required=True)
    verify_command.add_argument("--outer-app", type=pathlib.Path)
    verify_command.add_argument("--expected-team", required=True)
    verify_command.add_argument("--allow-adhoc-test", action="store_true")
    verify_command.add_argument("--require-release-signature", action="store_true")
    verify_command.add_argument("--managed-kernel", type=pathlib.Path, required=True)
    evidence_command = commands.add_parser("seal-evidence")
    evidence_command.add_argument("--runner-app", type=pathlib.Path, required=True)
    evidence_command.add_argument("--expected-team", required=True)
    evidence_command.add_argument("--allow-adhoc-test", action="store_true")
    evidence_command.add_argument("--require-release-signature", action="store_true")
    evidence_command.add_argument("--managed-kernel", type=pathlib.Path, required=True)
    link_command = commands.add_parser("verify-link-stage")
    link_command.add_argument("--link-root", type=pathlib.Path, required=True)
    link_command.add_argument("--link-inventory", type=pathlib.Path, required=True)
    worker_command = commands.add_parser("verify-worker-linkage")
    worker_command.add_argument("--worker-executable", type=pathlib.Path, required=True)
    canonicalize_command = commands.add_parser("canonicalize-worker-linkage")
    canonicalize_command.add_argument("--worker-executable", type=pathlib.Path, required=True)
    canonicalize_command.add_argument("--developer-dir", type=pathlib.Path, required=True)
    canonicalize_command.add_argument("--receipt", type=pathlib.Path, required=True)
    prune_command = commands.add_parser("prune")
    prune_command.add_argument("--runner-app", type=pathlib.Path, required=True)
    return result


def validate_signing_arguments(arguments: argparse.Namespace) -> None:
    if arguments.expected_team == "-" and not arguments.allow_adhoc_test:
        fail("ad-hoc operation requires --allow-adhoc-test")
    if arguments.expected_team != "-" and arguments.allow_adhoc_test:
        fail("--allow-adhoc-test cannot weaken a production team identity")


def main() -> int:
    arguments = parser().parse_args()
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    try:
        if arguments.command == "package":
            validate_signing_arguments(arguments)
            package(arguments, repo_root)
        elif arguments.command == "verify":
            validate_signing_arguments(arguments)
            verify(arguments, repo_root)
        elif arguments.command == "seal-evidence":
            validate_signing_arguments(arguments)
            seal_evidence(arguments, repo_root)
        elif arguments.command == "verify-link-stage":
            verify_static_link_stage(repo_root, arguments.link_root, arguments.link_inventory)
            print(f"renderer.linkStage={arguments.link_root}")
            print("renderer.linkStage.policy=verified-static")
        elif arguments.command == "verify-worker-linkage":
            verify_worker_linkage(arguments.worker_executable)
            print(f"renderer.worker={arguments.worker_executable}")
            print(f"renderer.worker.sha256={sha256(arguments.worker_executable)}")
            print("renderer.worker.linkage=verified-static")
        elif arguments.command == "canonicalize-worker-linkage":
            canonicalize_worker_linkage(
                arguments.worker_executable, arguments.developer_dir, arguments.receipt
            )
            print(f"renderer.worker={arguments.worker_executable}")
            print(f"renderer.worker.canonicalization.receipt={arguments.receipt}")
            print(f"renderer.worker.canonicalization.receipt.sha256={sha256(arguments.receipt)}")
            print("renderer.worker.linkage=canonicalized")
        else:
            prune(arguments)
    except PackagingError as error:
        print(f"renderer packaging error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
