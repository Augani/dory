#!/usr/bin/env python3
"""Offline contract tests for the non-native BuildKit release smoke."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "nonnative-build-smoke.sh"

class NonNativeBuildSmokeTests(unittest.TestCase):

    def test_fixture_is_self_contained(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary) / "fixture"
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'gate="$1"; fixture="$2"; set --; '
                    'DORY_NONNATIVE_SMOKE_SOURCE_ONLY=1 source "$gate"; '
                    'write_node_build_fixture "$fixture"',
                    "bash",
                    str(GATE),
                    str(fixture),
                ],
                cwd=ROOT,
                check=True,
            )
            expected = {
                "package.json",
                "package-lock.json",
                "src/app.mjs",
                "scripts/build.mjs",
                "test/app.test.mjs",
                "vendor/dory-math/package.json",
                "vendor/dory-math/index.mjs",
            }
            actual = {
                str(path.relative_to(fixture))
                for path in fixture.rglob("*")
                if path.is_file()
            }
            self.assertEqual(actual, expected)

if __name__ == "__main__":
    unittest.main()
