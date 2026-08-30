#!/usr/bin/env python3
"""Build and exercise the Phase 0A Apple-silicon JIT publication probe."""

from __future__ import annotations

import json
import platform
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "dory-core-swift"
SOURCE = PACKAGE / "Sources/dory-jit-probe/main.c"
ENTITLEMENTS = ROOT / "Config/DoryJITProbe.entitlements"


class DoryJITProbeTests(unittest.TestCase):
    def test_source_freezes_single_region_allowlist_and_publication_contract(self) -> None:
        text = SOURCE.read_text(encoding="utf-8")
        manifest = (PACKAGE / "Package.swift").read_text(encoding="utf-8")
        self.assertIn('.executable(name: "dory-jit-probe"', manifest)
        self.assertIn('name: "dory-jit-probe",\n            path: "Sources/dory-jit-probe"', manifest)
        self.assertEqual(text.count("void *mapping = mmap("), 1)
        self.assertIn("MAP_PRIVATE | MAP_ANON | MAP_JIT", text)
        self.assertIn("PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(dory_emit_probe)", text)
        self.assertIn("pthread_jit_write_with_callback_np", text)
        self.assertIn("sys_icache_invalidate", text)
        self.assertIn("const size_t mapping_size = page_size", text)
        self.assertNotIn("dlopen", text)
        self.assertNotIn("pthread_jit_write_protect_np", text)

    def test_entitlements_are_exact_and_narrow(self) -> None:
        with ENTITLEMENTS.open("rb") as handle:
            document = plistlib.load(handle)
        self.assertEqual(
            document,
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.cs.jit-write-allowlist": True,
            },
        )

    def test_release_workflow_requires_the_signed_notarized_probe(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        for contract in (
            "Build, sign, execute, and notarize the JIT entitlement probe",
            "Config/DoryJITProbe.entitlements",
            'codesign --verify --strict --verbose=4 "$root/dory-jit-probe"',
            '"$root/dory-jit-probe" > "$root/evidence/execution.json"',
            'xcrun notarytool submit "$root/dory-jit-probe.zip"',
            'receipt.get("status") != "Accepted"',
            "dory-jit-probe/evidence",
        ):
            self.assertIn(contract, workflow, contract)

    @unittest.skipUnless(
        platform.system() == "Darwin" and platform.machine() == "arm64",
        "the product JIT probe executes only on Apple silicon",
    )
    def test_probe_emits_a_machine_readable_pass_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "dory-jit-probe"
            build = subprocess.run(
                [
                    "xcrun", "clang", "-std=c17", "-O2", "-Wall", "-Wextra",
                    "-Werror", "-mmacosx-version-min=14.0", str(SOURCE),
                    "-o", str(executable),
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=60,
                check=False,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(
            receipt,
            {
                "schemaVersion": 1,
                "status": "PASS",
                "hostArchitecture": "arm64",
                "mapJITRegions": 1,
                "guardPages": 0,
                "codePages": 1,
                "writeAPI": "pthread_jit_write_with_callback_np",
                "instructionCachePublication": "sys_icache_invalidate",
                "generatedResult": 42,
            },
        )


if __name__ == "__main__":
    unittest.main()
