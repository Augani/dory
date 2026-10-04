#!/usr/bin/env python3
"""Offline contract for the exact signed-candidate qualification orchestrator."""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "qualify-release-candidate.sh"

class ReleaseCandidateQualifierTests(unittest.TestCase):

    def test_confirmation_fails_before_candidate_or_qualification_root_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            qualification = root / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--build-dir",
                    str(root / "missing-build"),
                    "--version",
                    "1.2.3",
                    "--build",
                    "42",
                    "--source-commit",
                    "a" * 40,
                    "--qualification-root",
                    str(qualification),
                ],
                cwd=ROOT,
                env={**os.environ, "HOME": temporary},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(qualification.exists())

    def test_completion_writer_emits_typed_schema_two_binding(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        marker = '<<\'PY\'\nimport json\nimport sys\n\n(\n    output, release_qualifying'
        start = text.find(marker)
        self.assertNotEqual(start, -1)
        script_start = start + len("<<'PY'\n")
        script_end = text.find("\nPY\nmv \"$WORKDIR/qualification.complete.json.partial\"", script_start)
        self.assertNotEqual(script_end, -1)
        writer = text[script_start:script_end]

        digest = "b" * 64
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "complete.json"
            arguments = [
                str(output), "true", "false", "1.2.3", "42", "a" * 40, "7", "3",
                digest, digest, digest, digest, digest, "28800", "90000", "12.0.4",
                "0.87.0", "0.2.89", "localstack@sha256:" + digest, "0.37.5", "2.109.1",
                "k3s@sha256:" + digest, "nginx@sha256:" + digest, "2.23.0",
                "python@sha256:" + digest, digest, digest, "alpine@sha256:" + digest,
                "registry@sha256:" + digest, "ssh@sha256:" + digest, "ryuk@sha256:" + digest,
                "node@sha256:" + digest, digest, digest, digest, digest, "123456",
            ]
            result = subprocess.run(
                ["python3", "-", *arguments],
                input=writer,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["schemaVersion"], 2)
            self.assertEqual(payload["kind"], "dev.dory.release-qualification")
            self.assertIs(payload["releaseQualifying"], True)
            self.assertEqual(payload["sourceCommit"], "a" * 40)
            self.assertEqual(payload["candidateBindingSha256"], digest)
            self.assertEqual(payload["componentCatalogSchemaVersion"], 2)
            self.assertEqual(payload["componentCatalogSignatureSha256"], digest)

if __name__ == "__main__":
    unittest.main()
