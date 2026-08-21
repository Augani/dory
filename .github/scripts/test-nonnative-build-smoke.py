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
    def test_build_is_digest_pinned_and_network_free(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "images must be digest-pinned",
            'docker_e image inspect "$ALPINE_IMAGE"',
            'docker_e image inspect "$BUILD_IMAGE"',
            "FEX-x86_64",
            "flags: POCF",
            "--platform \"linux/$TARGET_ARCH\"",
            "RUN --network=none npm ci --ignore-scripts --no-audit --no-fund",
            "RUN --network=none npm run build",
            "--pull=false",
            "nested-gnu-tar-ok",
            "hardlink.txt",
            "dory-nonnative-build-ok",
            "explicit workdir must not already exist",
        ):
            self.assertIn(proof, text, proof)
        for mutable in ("alpine:latest", "node:20-alpine\n", "apk add"):
            self.assertNotIn(mutable, text, mutable)

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
