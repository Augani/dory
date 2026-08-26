#!/usr/bin/env python3
"""Offline regression tests for Linux VM performance bundle schema 1."""

from __future__ import annotations

import copy
import dataclasses
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPT = pathlib.Path(__file__).with_name("verify-linux-vm-performance-bundle.py")
SPEC = importlib.util.spec_from_file_location(
    "dory_linux_vm_performance_bundle", SCRIPT
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

FIXTURE_ROOT = (
    pathlib.Path(__file__).parent / "fixtures/linux-vm-performance-bundle-schema1"
)
FIXTURE_BUNDLE = FIXTURE_ROOT / "bundle"
TEST_PUBLIC_KEY = (
    (FIXTURE_ROOT / "test-public-key-base64.txt").read_text(encoding="ascii").strip()
)


def load_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_bytes())


class LinuxVMPerformanceBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.evidence = load_json(FIXTURE_BUNDLE / "evidence-manifest.json")
        cls.budget_set = load_json(FIXTURE_BUNDLE / "budget-set.json")
        cls.budgets = MODULE._STRUCTURAL.validate_budget_set(cls.budget_set)
        cls.inventory = load_json(FIXTURE_BUNDLE / "bundle-inventory.json")
        cls.inventory_paths = {item["path"] for item in cls.inventory["files"]}
        cls.inventory_entries = {
            item["path"]: MODULE.InventoryEntry(
                item["path"], item["bytes"], item["sha256"]
            )
            for item in cls.inventory["files"]
        }
        cls.observations = MODULE.validate_observations(
            (FIXTURE_BUNDLE / "raw/observations.jsonl").read_bytes(),
            cls.evidence,
            cls.inventory_paths,
        )
        cls.plan = MODULE.validate_sampling_plan(
            load_json(FIXTURE_BUNDLE / "evidence/sampling-plan.json")
        )
        cls.summaries_value = load_json(FIXTURE_BUNDLE / "summary/metrics.json")
        cls.summaries = MODULE.validate_summaries(
            cls.summaries_value,
            cls.observations,
            cls.plan,
        )

    def test_signed_test_fixture_passes_exact_bundle_verification(self) -> None:
        result = MODULE.verify_bundle(FIXTURE_BUNDLE, TEST_PUBLIC_KEY)
        self.assertTrue(result.release_qualified)
        self.assertEqual(len(result.budget_results), 1)
        self.assertTrue(result.budget_results[0].passed)

    def test_release_verification_has_no_unsigned_mode(self) -> None:
        with self.assertRaisesRegex(ValueError, "public key"):
            MODULE.verify_bundle(FIXTURE_BUNDLE, "")

    def test_publication_requires_release_verdict_and_exact_candidate_bindings(self) -> None:
        result = MODULE.verify_bundle(FIXTURE_BUNDLE, TEST_PUBLIC_KEY)
        MODULE.enforce_publication_admission(
            result,
            require_release_qualified=True,
            expected=result.candidate,
            expected_cell=MODULE.ExpectedSupportCell(
                result.support_cell.matrix_cell_id,
                result.support_cell.installer_sha256,
                result.support_cell.backend,
                result.support_cell.selected_graphics_quality,
            ),
        )

        wrong_application = dataclasses.replace(
            result.candidate,
            application_sha256="a" * 64,
        )
        with self.assertRaisesRegex(
            ValueError, "application SHA-256 does not match"
        ):
            MODULE.enforce_publication_admission(
                result,
                require_release_qualified=True,
                expected=wrong_application,
                expected_cell=MODULE.ExpectedSupportCell(
                    result.support_cell.matrix_cell_id,
                    result.support_cell.installer_sha256,
                    result.support_cell.backend,
                    result.support_cell.selected_graphics_quality,
                ),
            )

        with self.assertRaisesRegex(ValueError, "expected candidate binding"):
            MODULE.enforce_publication_admission(
                result,
                require_release_qualified=True,
                expected=None,
                expected_cell=None,
            )

        with self.assertRaisesRegex(ValueError, "expected support-cell binding"):
            MODULE.enforce_publication_admission(
                result,
                require_release_qualified=True,
                expected=result.candidate,
                expected_cell=None,
            )

        wrong_cell = MODULE.ExpectedSupportCell(
            "a" * 64,
            result.support_cell.installer_sha256,
            result.support_cell.backend,
            result.support_cell.selected_graphics_quality,
        )
        with self.assertRaisesRegex(ValueError, "matrix-cell ID"):
            MODULE.enforce_publication_admission(
                result,
                require_release_qualified=True,
                expected=result.candidate,
                expected_cell=wrong_cell,
            )

        calibration = dataclasses.replace(
            result,
            qualification_mode="calibration",
            manifest_verdict="not-release-qualifying",
        )
        with self.assertRaisesRegex(ValueError, "not release-qualified"):
            MODULE.enforce_publication_admission(
                calibration,
                require_release_qualified=True,
                expected=calibration.candidate,
                expected_cell=MODULE.ExpectedSupportCell(
                    calibration.support_cell.matrix_cell_id,
                    calibration.support_cell.installer_sha256,
                    calibration.support_cell.backend,
                    calibration.support_cell.selected_graphics_quality,
                ),
            )

    def test_release_cli_binds_precatalog_candidate_and_sbom(self) -> None:
        verified = MODULE.verify_bundle(FIXTURE_BUNDLE, TEST_PUBLIC_KEY)
        candidate = verified.candidate
        cell = verified.support_cell
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPT),
                "--bundle-root",
                str(FIXTURE_BUNDLE),
                "--signature-public-key-base64",
                TEST_PUBLIC_KEY,
                "--require-release-qualified",
                "--expected-component-candidate-inventory-sha256",
                candidate.component_candidate_inventory_sha256,
                "--expected-application-sha256",
                candidate.application_sha256,
                "--expected-sbom-sha256",
                candidate.sbom_sha256,
                "--expected-runtime-plan-sha256",
                candidate.runtime_plan_sha256,
                "--expected-budget-set-sha256",
                candidate.budget_set_sha256,
                "--expected-virtual-hardware-abi-version",
                candidate.virtual_hardware_abi_version,
                "--expected-matrix-cell-id",
                cell.matrix_cell_id,
                "--expected-installer-sha256",
                cell.installer_sha256,
                "--expected-backend",
                cell.backend,
                "--expected-selected-graphics-quality",
                cell.selected_graphics_quality,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("release qualification: PASS", completed.stdout)
        self.assertNotIn("component catalog", completed.stdout + completed.stderr)

    def test_payload_sha_tampering_fails_before_qualification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = pathlib.Path(temporary).resolve() / "bundle"
            shutil.copytree(FIXTURE_BUNDLE, copied)
            (copied / "evidence/host.json").write_text("[]\n", encoding="ascii")
            with self.assertRaisesRegex(ValueError, "SHA-256 differs from inventory"):
                MODULE.verify_bundle(copied, TEST_PUBLIC_KEY)

    def test_matrix_cell_id_is_derived_from_every_exact_descriptor_byte(self) -> None:
        descriptor_path = FIXTURE_BUNDLE / self.evidence["campaign"][
            "matrixCellDescriptor"
        ]
        raw = descriptor_path.read_bytes()
        binding = MODULE.validate_matrix_cell_descriptor(
            raw, self.evidence, self.inventory_entries
        )
        self.assertEqual(
            binding.matrix_cell_id, self.evidence["campaign"]["matrixCellID"]
        )

        wrong_identity = copy.deepcopy(self.evidence)
        wrong_identity["campaign"]["matrixCellID"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "not the SHA-256"):
            MODULE.validate_matrix_cell_descriptor(
                raw, wrong_identity, self.inventory_entries
            )

        wrong_receipt = copy.deepcopy(self.evidence)
        wrong_receipt["launch"]["graphics"]["selectionReceiptSHA256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "selection receipt digest"):
            MODULE.validate_matrix_cell_descriptor(
                raw, wrong_receipt, self.inventory_entries
            )

    def test_detached_signature_tampering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = pathlib.Path(temporary).resolve() / "bundle"
            shutil.copytree(FIXTURE_BUNDLE, copied)
            signature = copied / "signatures/evidence-bundle.sig"
            original = signature.read_text(encoding="ascii")
            replacement = "A" if original[0] != "A" else "B"
            signature.write_text(replacement + original[1:], encoding="ascii")
            with self.assertRaisesRegex(
                ValueError, "detached bundle signature is invalid"
            ):
                MODULE.verify_bundle(copied, TEST_PUBLIC_KEY)

    def test_symlinked_payload_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = pathlib.Path(temporary).resolve() / "bundle"
            shutil.copytree(FIXTURE_BUNDLE, copied)
            target = copied / "evidence/host.json"
            target.unlink()
            target.symlink_to(FIXTURE_BUNDLE / "evidence/host.json")
            with self.assertRaisesRegex(ValueError, "indirect|symbolic link"):
                MODULE.verify_bundle(copied, TEST_PUBLIC_KEY)

    def test_uninventoried_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = pathlib.Path(temporary).resolve() / "bundle"
            shutil.copytree(FIXTURE_BUNDLE, copied)
            (copied / "untracked.txt").write_text("untracked\n", encoding="ascii")
            with self.assertRaisesRegex(
                ValueError, "files differ from the canonical inventory"
            ):
                MODULE.verify_bundle(copied, TEST_PUBLIC_KEY)

    def test_sampling_plan_prevents_a_missing_sample_from_passing(self) -> None:
        changed_plan = copy.deepcopy(
            load_json(FIXTURE_BUNDLE / "evidence/sampling-plan.json")
        )
        changed_plan["metrics"][0]["expectedSampleCount"] = 4
        plan = MODULE.validate_sampling_plan(changed_plan)
        with self.assertRaisesRegex(ValueError, "planned sample count"):
            MODULE.validate_summaries(
                self.summaries_value,
                self.observations,
                plan,
            )

    def test_summary_statistic_is_recomputed_from_raw_observations(self) -> None:
        changed_summary = copy.deepcopy(self.summaries_value)
        changed_summary["metrics"][0]["statistics"]["median"] = 49
        with self.assertRaisesRegex(ValueError, "differs from raw observations"):
            MODULE.validate_summaries(
                changed_summary,
                self.observations,
                self.plan,
            )

    def test_invalid_observation_cannot_pass_an_absolute_budget(self) -> None:
        changed = copy.deepcopy(self.observations)
        changed[0]["validity"] = "invalid"
        changed[0]["value"] = None
        changed[0]["reason"] = "test-only invalid sample"
        evaluated = tuple(
            observation
            for observation in changed
            if observation["validity"] == "valid"
            and observation["correctness"] == "passed"
            and not observation["fallback"]
        )
        key = ("ux.boot.login-ready.duration", 1, "milliseconds")
        summary = MODULE.SummaryMetric(
            key,
            tuple(changed),
            evaluated,
            MODULE.compute_statistics(evaluated),
        )
        result = MODULE.evaluate_budgets(
            self.budgets,
            self.evidence,
            {key: summary},
        )
        self.assertEqual(len(result), 1)
        self.assertFalse(result[0].passed)
        self.assertIn("invalid", result[0].reason)

    def test_absolute_budget_directions_are_inclusive_and_deterministic(self) -> None:
        cases = [
            ("atMost", None, 50, True),
            ("atMost", None, 49, False),
            ("atLeast", 50, None, True),
            ("atLeast", 51, None, False),
            ("range", 50, 50, True),
            ("range", 51, 60, False),
        ]
        for direction, lower, upper, expected in cases:
            with self.subTest(direction=direction, lower=lower, upper=upper):
                budgets = copy.deepcopy(self.budgets)
                budgets[0]["direction"] = direction
                budgets[0]["lowerBound"] = lower
                budgets[0]["upperBound"] = upper
                result = MODULE.evaluate_budgets(
                    budgets,
                    self.evidence,
                    self.summaries,
                )
                self.assertEqual(result[0].passed, expected)


if __name__ == "__main__":
    unittest.main()
