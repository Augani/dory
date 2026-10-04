#!/usr/bin/env python3
"""Build and exercise the Phase 0A Apple-silicon JIT publication probe."""

from __future__ import annotations

import json
import platform
import plistlib
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "dory-core-swift"
SOURCE = PACKAGE / "Sources/dory-jit-probe/main.c"
ENTITLEMENTS = ROOT / "Config/DoryJITProbe.entitlements"

class DoryJITProbeTests(unittest.TestCase):

    def test_entitlements_are_exact_and_narrow(self) -> None:
        with ENTITLEMENTS.open("rb") as handle:
            document = plistlib.load(handle)
        self.assertEqual(
            document,
            {
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.cs.jit-write-allowlist": True,
            },
        )

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
        self.assertGreater(receipt.pop("readerExecutions"), 0)
        for field in ("writeProtectionSignal", "leadingGuardSignal", "trailingGuardSignal"):
            self.assertIn(receipt.pop(field), (signal.SIGBUS, signal.SIGSEGV))
        self.assertEqual(
            receipt,
            {
                "schemaVersion": 2,
                "status": "PASS",
                "hostArchitecture": "arm64",
                "mapJITRegions": 1,
                "guardPages": 2,
                "codePages": 1,
                "writeAPI": "pthread_jit_write_with_callback_np",
                "instructionCachePublication": "sys_icache_invalidate",
                "hostileCallbackRejections": 6,
                "reuseIterations": 1000,
                "readerThreads": 4,
                "readerFailures": 0,
                "postCrashResult": 42,
            },
        )

if __name__ == "__main__":
    unittest.main()
