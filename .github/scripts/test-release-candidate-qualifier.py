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
    def test_orchestrator_uses_signed_schema_two_authority_and_current_gate_apis(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "QUALIFY-EXACT-DORY-RELEASE",
            "validate-release-metadata.py",
            "signed schema-2 release metadata validation failed",
            "checked-out source does not match --source-commit",
            "tracked qualification harness differs from the checked-out source commit",
            "qualification harness authority changed during qualification",
            "qualification harness bytes changed during qualification",
            "engine PID is outside the exact isolated runtime authority",
            "PHYSICAL-APFS-VOLUME-IDENTITY",
            "ISOLATED-RUNTIME-DATA-DISK-GROWTH",
            "ISOLATED-ENGINE-DEFAULT-PLATFORM",
            "ISOLATED-ENGINE-PRIVATE-REGISTRY",
            "ISOLATED-ENGINE-BIND-FILE-COHERENCE",
            "ISOLATED-ENGINE-TESTCONTAINERS",
            '--ryuk-image "$TESTCONTAINERS_RYUK_IMAGE"',
            '--image "$IMAGE"',
            '--compose "$COMPOSE"',
            '--runner-image "$ACT_RUNNER_IMAGE"',
            "ISOLATED-ENGINE-LONG-LIVED-TCP",
            "ISOLATED-ENGINE-ENDURANCE-RELIABILITY",
            "candidate-binding.txt",
            "component_catalog_schema=2",
            "component_catalog_signature_sha256=",
            "app_executable_sha256=",
            "dory_vmm_sha256=",
            "kernel_sha256=",
            "rootfs_sha256=",
            "guest_agent_sha256=",
            '"schemaVersion": 2',
            '"kind": "dev.dory.release-qualification"',
            '"candidateBindingSha256"',
            '"componentCatalogSchemaVersion": 2',
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            '"schemaVersion": 1',
            'catalog.get("schemaVersion") == 1',
            "DORY_ALLOW_UNNOTARIZED_QUALIFICATION",
            "DORY_ALLOW_SHORT_QUALIFICATION",
            "trap cleanup EXIT INT TERM",
            'rm -rf "$private_registry_workroot"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
        ):
            self.assertNotIn(unsafe, text, unsafe)

        references = set(
            re.findall(r"(?<![A-Za-z0-9_./-])(scripts/[A-Za-z0-9_./-]+(?:\.sh|\.py))", text)
        )
        self.assertGreaterEqual(len(references), 30)
        for reference in references:
            path = ROOT / reference
            self.assertTrue(path.is_file(), reference)
            self.assertFalse(path.is_symlink(), reference)

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
