#!/usr/bin/env python3
"""Offline contract tests for durable release-qualification verification."""

from __future__ import annotations

import hashlib
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SHELL_VERIFIER = ROOT / "scripts/verify-release-qualification.sh"
AUTHORITY_VALIDATOR = ROOT / "scripts/validate-release-qualification.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("release_qualification_validator", AUTHORITY_VALIDATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load release qualification validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ReleaseQualificationVerifierTests(unittest.TestCase):
    def test_verifier_is_explicit_schema_two_fail_closed_authority(self) -> None:
        subprocess.run(["bash", "-n", str(SHELL_VERIFIER)], check=True)
        subprocess.run([sys.executable, "-m", "py_compile", str(AUTHORITY_VALIDATOR)], check=True)
        shell = SHELL_VERIFIER.read_text(encoding="utf-8")
        validator = AUTHORITY_VALIDATOR.read_text(encoding="utf-8")
        for proof in (
            "validate-release-qualification.py",
            "durable schema-2 qualification authority is invalid",
            "checked-out source does not match --source-commit",
            "tracked qualification verifier differs from the checked-out source commit",
            "qualification verifier bytes changed during verification",
            "durable qualification authority changed during semantic verification",
            "testcontainers_version=",
            "ryuk_image=",
            "runner_image=",
        ):
            self.assertIn(proof, shell, proof)
        self.assertEqual(shell.count("python3 scripts/validate-release-qualification.py"), 2)
        for proof in (
            '"schemaVersion"',
            '"dev.dory.release-qualification"',
            '"candidateBindingSha256"',
            '"componentCatalogSchemaVersion"',
            '"componentCatalogSignatureSha256"',
            "validate_evidence_manifest",
            "evidence manifest does not cover the exact retained evidence set",
            "candidate binding shape is invalid",
            "qualificationHarnessSha256",
            "metadataValidatorSha256",
            "testcontainersRyukImage",
            "actRunnerImage",
        ):
            self.assertIn(proof, validator, proof)
        self.assertNotRegex(shell, r"\bassert\s")
        self.assertNotRegex(validator, r"\bassert\s")
        self.assertNotIn('schemaVersion"] == 1', shell)
        self.assertNotIn('schemaVersion"] == 1', validator)

        references = set(
            re.findall(r"(?<![A-Za-z0-9_./-])(scripts/[A-Za-z0-9_./-]+(?:\.sh|\.py))", shell)
        )
        references.update(
            re.findall(r'"scripts/([A-Za-z0-9_./-]+(?:\.sh|\.py))"', validator)
        )
        self.assertGreaterEqual(len(references), 2)
        for reference in references:
            relative = reference if reference.startswith("scripts/") else "scripts/" + reference
            path = ROOT / relative
            self.assertTrue(path.is_file(), relative)
            self.assertFalse(path.is_symlink(), relative)

    def test_evidence_manifest_requires_exact_direct_sorted_file_set(self) -> None:
        validator = load_validator()
        with tempfile.TemporaryDirectory() as temporary:
            qualification = pathlib.Path(temporary)
            evidence = qualification / "evidence"
            evidence.mkdir()
            retained = evidence / "retained.txt"
            retained.write_text("safe evidence\n", encoding="utf-8")
            digest = hashlib.sha256(retained.read_bytes()).hexdigest()
            manifest = evidence / "evidence-sha256.txt"
            manifest.write_text(f"{digest}  evidence/retained.txt\n", encoding="ascii")
            self.assertEqual(validator.validate_evidence_manifest(qualification), manifest)

            indirect = evidence / "indirect.txt"
            indirect.symlink_to(retained)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                validator.validate_evidence_manifest(qualification)
            indirect.unlink()

            unlisted = evidence / "unlisted.txt"
            unlisted.write_text("not authenticated\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "exact retained evidence set"):
                validator.validate_evidence_manifest(qualification)

    def test_completion_and_candidate_binding_shapes_are_closed(self) -> None:
        validator = load_validator()
        self.assertEqual(len(validator.COMPLETION_KEYS), 71)
        self.assertEqual(len(validator.BINDING_KEYS), 36)
        self.assertIn("componentCatalogSignatureSha256", validator.COMPLETION_KEYS)
        self.assertIn("candidateBindingSha256", validator.COMPLETION_KEYS)
        self.assertIn("component_catalog_digest_file_sha256", validator.BINDING_KEYS)
        self.assertIn("host_facts_sha256", validator.BINDING_KEYS)
        self.assertIn("qualifier_sha256", validator.BINDING_KEYS)


if __name__ == "__main__":
    unittest.main()
