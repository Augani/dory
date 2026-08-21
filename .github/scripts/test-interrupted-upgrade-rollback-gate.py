#!/usr/bin/env python3
"""Non-mutating arming tests for the physical interrupted-upgrade gate."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "interrupted-upgrade-rollback-gate.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
PUBLIC_KEY = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="


class InterruptedUpgradeRollbackGateTests(unittest.TestCase):
    @staticmethod
    def fixture(temporary: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        app = temporary / "Dory.app"
        app.mkdir()
        signer = temporary / "sign_update"
        signer.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        signer.chmod(0o755)
        return app, signer

    @staticmethod
    def invoke(
        temporary: pathlib.Path,
        app: pathlib.Path,
        signer: pathlib.Path,
        *,
        confirmation: str = "CLEAN-RELEASE-USER-INTERRUPTED-UPGRADE",
        workroot_name: str = "dory-release-live-transactional-upgrade",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "DORY_RELEASE_CLEAN_USER": "1",
                "DORY_SPARKLE_PRIVATE_KEY": "test-private-key",
                "PYTHONOPTIMIZE": "2",
                "RUNNER_TEMP": str(temporary),
            }
        )
        return subprocess.run(
            [
                str(GATE),
                "--candidate-app", str(app),
                "--sign-update", str(signer),
                "--version", "9.8.7",
                "--build", "42",
                "--source-commit", "a" * 40,
                "--fixture-image", "example.invalid/alpine@sha256:" + "b" * 64,
                "--workroot", str(temporary / workroot_name),
                "--confirm", confirmation,
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_source_is_shell_valid_optimizer_safe_and_exactly_bound(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], cwd=ROOT, check=True)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "candidate app must be a direct Dory.app",
            "sign_update must be a direct executable",
            "nested virtualization is not release-qualifying",
            "source=Notarized Developer ID",
            "candidate is not signed by Dory team 864H636QW4",
            "workroot must be inside runner temporary storage",
            "run authority already exists",
            '"schemaVersion": 2',
            '"role": "qualification-evidence"',
            '"virtualMachineQualification": {',
            "<dory:componentCatalogSchema>2</dory:componentCatalogSchema>",
            ".github/scripts/verify-ed25519-signature.swift",
            "automaticRollback",
            "component_catalog_signatures_verified=PASS",
            "component_qualification_authority=PASS",
            "durable_volume_sentinel_preserved=PASS",
            "initial_clean_user_state_restored=PASS",
        ):
            self.assertIn(contract, source)
        self.assertNotIn("codesign --force --deep --sign", source)

    def test_schema_two_catalog_fixture_has_complete_qualification_authority(self) -> None:
        source = GATE.read_text(encoding="utf-8")
        start = source.index("import base64, hashlib, json, pathlib, sys")
        end = source.index("\nPY\n\nsign_file()", start)
        generator = source[start:end]
        with tempfile.TemporaryDirectory(prefix="dory-upgrade-catalog-test.") as raw:
            root = pathlib.Path(raw).resolve()
            (root / "component-v1.txt").write_text("generation-one\n", encoding="utf-8")
            (root / "component-v2.txt").write_text("generation-two\n", encoding="utf-8")
            prior_argv = sys.argv
            try:
                sys.argv = [
                    "fixture-generator", str(root), "9.8.7", "a" * 40,
                    "https://127.0.0.1/catalog-v1.json",
                    "https://127.0.0.1/catalog-v2.json",
                    "b" * 64, "c" * 64, "Mac16,1", "26A123", PUBLIC_KEY,
                ]
                exec(compile(generator, str(GATE), "exec"), {})
            finally:
                sys.argv = prior_argv

            first = json.loads((root / "catalog-v1.json").read_text(encoding="utf-8"))
            second = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
            manifest = json.loads(
                (root / "virtual-machine-qualification.json").read_text(encoding="utf-8")
            )
        self.assertEqual(first["schemaVersion"], 2)
        self.assertEqual(second["schemaVersion"], 2)
        self.assertLess(first["generatedAt"], second["generatedAt"])
        self.assertEqual(
            first["virtualMachineQualification"]["manifestIdentity"],
            manifest["manifestIdentity"],
        )
        machines = next(item for item in first["components"] if item["id"] == "linux-machines")
        self.assertEqual(machines["qualification"], [manifest["records"][0]["qualificationIdentity"]])
        self.assertEqual(
            {asset["role"] for asset in machines["assets"]},
            {"qualification-evidence", "build-metadata"},
        )
        self.assertEqual(manifest["records"][0]["hostHardwareModelIdentifier"], "Mac16,1")

    def test_release_evidence_binding_is_optimizer_safe(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        block = workflow.split(
            "      - name: Verify interrupted transactional-upgrade evidence binding", 1
        )[1].split("\n      - name:", 1)[0]
        self.assertNotIn("assert ", block)
        for contract in (
            '"component_catalog_schema": "2"',
            '"component_catalog_signatures_verified"',
            '"component_qualification_authority"',
            "invalid or duplicate evidence row",
        ):
            self.assertIn(contract, block)

    def test_confirmation_indirect_candidate_and_workroot_fail_before_physical_probe(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-upgrade-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            app, signer = self.fixture(temporary)
            confirmation = self.invoke(temporary, app, signer, confirmation="wrong")
            linked = temporary / "linked-Dory.app"
            linked.symlink_to(app, target_is_directory=True)
            indirect = self.invoke(temporary, linked, signer)
            workroot = self.invoke(temporary, app, signer, workroot_name="unscoped")
        self.assertIn("requires --confirm", confirmation.stdout)
        self.assertIn("candidate app must be a direct Dory.app", indirect.stdout)
        self.assertIn("dedicated interrupted-upgrade name", workroot.stdout)


if __name__ == "__main__":
    unittest.main()
