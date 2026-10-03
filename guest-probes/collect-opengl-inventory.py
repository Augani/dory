#!/usr/bin/env python3
"""Capture guest facts for one Dory OpenGL strategy comparison run.

Run inside the graphical Linux guest, in the same user session as the workloads.
The probe result must be the unedited JSON output of the matching Dory GPU probe.
Only extensions/features reported as *used* by that probe become API capabilities.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
from typing import Any


SCHEMA = "dory.opengl-guest-inventory@1"
PATHS = {"zink-venus": "vulkan-application", "virgl2-angle": "gl"}
PACKAGE_PATTERN = re.compile(r"mesa|vulkan|virgl|angle|gnome-shell|kwin|linux-image|kernel-core", re.I)
MESA_VERSION = re.compile(r"\bMesa\s+([0-9]+(?:\.[0-9]+){1,3}(?:[-+~.][A-Za-z0-9]+)?)")
MAX_COMMAND_BYTES = 4 * 1_048_576


class InventoryError(ValueError):
    pass


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise InventoryError(reason)


def run(argv: list[str]) -> str:
    try:
        result = subprocess.run(argv, capture_output=True, check=False, timeout=30,
                                env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InventoryError(f"{argv[0]} unavailable: {error}") from error
    require(result.returncode == 0, f"{argv[0]} failed: {result.stderr[:300]!r}")
    require(len(result.stdout) <= MAX_COMMAND_BYTES, f"{argv[0]} output is too large")
    return result.stdout.decode("utf-8", errors="strict")


def os_release() -> dict[str, str]:
    result: dict[str, str] = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1].replace(r'\"', '"')
        result[key] = value
    require(bool(result.get("ID")) and bool(result.get("VERSION_ID")),
            "/etc/os-release lacks ID or VERSION_ID")
    return result


def glxinfo_fields(output: str) -> tuple[str, str, str]:
    fields: dict[str, str] = {}
    for line in output.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    renderer = fields.get("OpenGL renderer string", "")
    version = (fields.get("OpenGL core profile version string")
               or fields.get("OpenGL version string") or "")
    mesa = MESA_VERSION.search(version)
    require(bool(renderer) and bool(version) and mesa is not None,
            "glxinfo -B did not identify the OpenGL renderer and Mesa version")
    return renderer, version, mesa.group(1)


def package_inventory() -> list[str]:
    if shutil.which("dpkg-query"):
        output = run(["dpkg-query", "-W", "-f=${Package}\t${Version}\n"])
    elif shutil.which("rpm"):
        output = run(["rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n"])
    else:
        raise InventoryError("neither dpkg-query nor rpm can report installed packages")
    packages = sorted(line for line in output.splitlines()
                      if "\t" in line and PACKAGE_PATTERN.search(line.split("\t", 1)[0]))
    require(bool(packages), "no installed graphics/compositor package versions were found")
    return packages


def driver_files() -> list[str]:
    directories = [Path("/usr/share/vulkan/icd.d"), Path("/etc/vulkan/icd.d"),
                   Path("/usr/lib/dri"), Path("/usr/lib64/dri")]
    directories.extend(Path("/usr/lib").glob("*/dri"))
    result: set[str] = set()
    for directory in directories:
        if not directory.is_dir():
            continue
        for item in directory.iterdir():
            if item.is_file() and (item.suffix in (".json", ".so") or ".so." in item.name):
                result.add(str(item))
    return sorted(result)


def probe_result(path: Path, expected_probe: str) -> tuple[dict[str, Any], str]:
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW), "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 1_048_576,
                "probe result must be a nonempty direct regular file below 1 MiB")
        raw = source.read(1_048_577)
        after = os.fstat(source.fileno())
        current = path.lstat()
        require(len(raw) == before.st_size
                and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                and (before.st_dev, before.st_ino) == (current.st_dev, current.st_ino),
                "probe result changed during inventory collection")
    try:
        result = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InventoryError(f"probe result is invalid JSON: {error}") from error
    require(isinstance(result, dict) and result.get("schema") == "dev.dory.gpu-probe"
            and result.get("version") == 1 and result.get("probe") == expected_probe,
            "probe result is not the matching Dory GPU probe")
    for field in ("deviceName", "driver", "apiVersion"):
        require(isinstance(result.get(field), str) and bool(result[field]),
                f"probe result lacks {field}")
    require(type(result.get("frameCount")) is int and result["frameCount"] > 0,
            "probe result lacks a presented frame")
    require(isinstance(result.get("nonce"), str) and bool(result["nonce"])
            and isinstance(result.get("resultHash"), str)
            and re.fullmatch(r"fnv1a64:[0-9a-f]{16}", result["resultHash"]) is not None
            and isinstance(result.get("visualChallenge"), dict),
            "probe result lacks its challenged output identity")
    for field in ("extensionsUsed", "featuresUsed"):
        value = result.get(field, [])
        require(isinstance(value, list) and all(isinstance(item, str) and item
                for item in value) and value == sorted(set(value)),
                f"probe result {field} must be a sorted unique list")
    require(bool(result.get("extensionsUsed") or result.get("featuresUsed")),
            "probe result has no enabled API capabilities")
    return result, hashlib.sha256(raw).hexdigest()


def collect(path: str, probe_path: Path) -> dict[str, Any]:
    require(platform.system() == "Linux", "guest inventory must run inside Linux")
    require(path in PATHS, "unknown OpenGL strategy path")
    release = os_release()
    session_type = os.environ.get("XDG_SESSION_TYPE", "")
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "")
    require(session_type in ("wayland", "x11") and bool(desktop),
            "inventory must run in an identified graphical desktop session")
    compositor_command = (["gnome-shell", "--version"] if "GNOME" in desktop.upper()
                          else ["kwin_wayland" if session_type == "wayland" else "kwin_x11",
                                "--version"] if "KDE" in desktop.upper() else None)
    require(compositor_command is not None,
            "desktop compositor is not identified as GNOME or KDE")
    compositor_version = run(compositor_command).strip()
    require(bool(compositor_version), "compositor version is empty")
    gl_output = run(["glxinfo", "-B"])
    renderer, gl_version, mesa_version = glxinfo_fields(gl_output)
    probe, probe_sha = probe_result(probe_path, PATHS[path])
    if path == "zink-venus":
        require(isinstance(probe.get("strategyFeatureFallback"), bool),
                "Zink/Venus probe did not report optional feature negotiation status")
        require("zink" in renderer.lower() and probe["driver"].lower() == "venus",
                "Zink/Venus inventory identified a different OpenGL or Vulkan driver")
        require(probe.get("wsi") in ("wayland", "xcb")
                and probe.get("surfaceFormat") not in (None, "none")
                and probe.get("colorAtlasFormat") in ("bgra8-unorm", "rgba8-unorm"),
                "Zink/Venus probe did not negotiate a windowed surface and atlas format")
    else:
        require("virgl" in renderer.lower() and probe["deviceName"] == renderer,
                "VirGL2 inventory identified a different OpenGL renderer")
    capabilities = sorted(set(probe.get("extensionsUsed", []) + probe.get("featuresUsed", [])))
    vulkan_summary = run(["vulkaninfo", "--summary"]) if path == "zink-venus" else None
    files = driver_files()
    require(bool(files), "no installed ICD or DRI files were found")
    software = any(token in renderer.lower() or token in probe["deviceName"].lower()
                   for token in ("llvmpipe", "lavapipe", "softpipe", "swrast",
                                 "software rasterizer"))
    return {
        "schema": SCHEMA, "path": path, "guestDistribution": release["ID"],
        "guestVersion": release["VERSION_ID"], "guestArchitecture": platform.machine(),
        "kernelRelease": platform.release(), "desktopEnvironment": desktop,
        "sessionType": session_type, "compositorVersion": compositor_version,
        "rendererDevice": renderer, "glVersion": gl_version, "mesaVersion": mesa_version,
        "apiCapabilities": capabilities, "softwareRendererDetected": software,
        "probeDeviceName": probe["deviceName"], "probeDriver": probe["driver"],
        "probeApiVersion": probe["apiVersion"], "probeResultSHA256": probe_sha,
        "probeSurfaceFormat": probe.get("surfaceFormat"),
        "probeColorAtlasFormat": probe.get("colorAtlasFormat"),
        "probeStrategyFeatureFallback": probe.get("strategyFeatureFallback"),
        "packages": package_inventory(), "driverFiles": files,
        "glxinfoBasic": gl_output, "vulkanSummary": vulkan_summary,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", choices=sorted(PATHS), required=True)
    parser.add_argument("--probe-result", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        inventory = collect(arguments.path, arguments.probe_result)
    except (InventoryError, OSError, UnicodeDecodeError) as error:
        print(f"OpenGL guest inventory failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(inventory, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
