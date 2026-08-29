#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[2]
TOOL = REPO / "scripts" / "validate-linux-vm-performance-evidence.py"
MATRIX_CELL = "a" * 64


def canonical(value: object) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def digest(character: str) -> str:
    return character * 64


def frozen_budget(
    *, quality: str = "software", budget_id: str = "ux.boot.login-ready.duration"
) -> dict:
    return {
        "applicability": {
            "architecture": "arm64",
            "graphicsQuality": quality,
            "matrixCellIDs": [MATRIX_CELL],
            "qualificationModes": ["release"],
        },
        "approval": {
            "approvedAt": "2026-08-23T12:34:56Z",
            "owner": "Dory performance",
            "recordSHA256": digest("b"),
            "reviewer": "Dory release",
        },
        "baselineEvidenceSHA256": digest("c"),
        "direction": "atMost",
        "id": budget_id,
        "lowerBound": None,
        "metricDefinitionRevision": 1,
        "rationale": "Synthetic validator fixture; not a product performance threshold.",
        "state": "frozen",
        "statistic": "p95",
        "unit": "milliseconds",
        "upperBound": 42.5,
    }


def frozen_budget_set(
    *, quality: str = "software", budget_id: str = "ux.boot.login-ready.duration"
) -> dict:
    return {
        "architecture": "arm64",
        "budgetSetID": "linux-vm-release",
        "budgets": [frozen_budget(quality=quality, budget_id=budget_id)],
        "kind": "dev.dory.linux-vm-performance-budget-set",
        "revision": 1,
        "schemaVersion": 1,
        "state": "frozen",
    }


def provisional_budget_set() -> dict:
    budget = frozen_budget()
    budget.update(
        {
            "approval": None,
            "baselineEvidenceSHA256": None,
            "lowerBound": None,
            "state": "provisional",
            "upperBound": None,
        }
    )
    budget["applicability"]["qualificationModes"] = ["calibration"]
    return {
        "architecture": "arm64",
        "budgetSetID": "linux-vm-calibration",
        "budgets": [budget],
        "kind": "dev.dory.linux-vm-performance-budget-set",
        "revision": 1,
        "schemaVersion": 1,
        "state": "provisional",
    }


def evidence_manifest(*, mode: str = "release", verdict: str = "qualified") -> dict:
    return {
        "campaign": {
            "clockCalibration": "evidence/clocks.json",
            "definitionID": "linux-desktop-interactive",
            "definitionRevision": 1,
            "harnessSHA256": digest("d"),
            "matrixCellID": MATRIX_CELL,
            "matrixCellDescriptor": "evidence/matrix-cell.json",
            "samplingPlan": "evidence/sampling-plan.json",
            "workloadSHA256": digest("e"),
        },
        "candidate": {
            "applicationSHA256": digest("f"),
            "budgetSetSHA256": digest("1"),
            "codeSignatureEvidence": "evidence/candidate-signatures.json",
            "componentCandidateInventorySHA256": digest("3"),
            "runtimePlanSHA256": digest("4"),
            "sbomSHA256": digest("2"),
            "virtualHardwareABIVersion": "arm64-v1",
        },
        "fallbacks": "summary/fallbacks.json",
        "guest": {
            "architecture": "arm64",
            "guestToolsSHA256": digest("5"),
            "initrdSHA256": None,
            "installedSystemIdentity": "evidence/guest-system.json",
            "installerSHA256": digest("6"),
            "installerSignatureEvidence": "evidence/installer-signature.json",
            "kernelSHA256": digest("7"),
            "mesaAndRendererClientIdentity": "evidence/guest-graphics.json",
        },
        "host": {
            "architecture": "arm64",
            "displayTopology": "evidence/host-display.json",
            "identity": "evidence/host-identity.json",
            "noiseControls": "evidence/noise-controls.json",
            "powerAndThermalState": "evidence/host-state.json",
            "storageTopology": "evidence/host-storage.json",
        },
        "kind": "dev.dory.linux-vm-performance-evidence",
        "launch": {
            "backend": "vz",
            "devices": "evidence/devices.json",
            "graphics": {
                "accelerationEvidence": None,
                "accelerationEvidenceSHA256": None,
                "fallback": False,
                "fallbackReason": None,
                "implementation": "software",
                "requestedQuality": "software",
                "selectedQuality": "software",
                "selectionReceiptSHA256": digest("8"),
            },
            "graphicsSelectionReceipt": "evidence/graphics-selection.json",
            "operationID": "12345678-1234-4abc-8def-1234567890ab",
            "planGeneration": 1,
            "resources": "evidence/resources.json",
        },
        "observations": "raw/observations.jsonl",
        "qualificationMode": mode,
        "schemaVersion": 1,
        "signature": "signatures/evidence-bundle.sig",
        "summaries": "summary/metrics.json",
        "unavailableEvidence": "summary/unavailable.json",
        "verdict": verdict,
    }


class LinuxVMPerformanceEvidenceTests(unittest.TestCase):
    def invoke(
        self,
        evidence: dict,
        budget_set: dict,
        *,
        success: bool,
        rebind: bool = True,
        evidence_raw: bytes | None = None,
        budget_raw: bytes | None = None,
    ) -> subprocess.CompletedProcess[str]:
        evidence = copy.deepcopy(evidence)
        budget_set = copy.deepcopy(budget_set)
        budget_bytes = budget_raw if budget_raw is not None else canonical(budget_set)
        if rebind:
            evidence["candidate"]["budgetSetSHA256"] = hashlib.sha256(
                budget_bytes
            ).hexdigest()
        evidence_bytes = (
            evidence_raw if evidence_raw is not None else canonical(evidence)
        )
        with tempfile.TemporaryDirectory(
            prefix="dory-linux-vm-performance."
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            evidence_path = root / "evidence.json"
            budget_path = root / "budget-set.json"
            evidence_path.write_bytes(evidence_bytes)
            budget_path.write_bytes(budget_bytes)
            result = subprocess.run(
                [
                    "python3",
                    os.fspath(TOOL),
                    "--evidence",
                    os.fspath(evidence_path),
                    "--budget-set",
                    os.fspath(budget_path),
                ],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        if success and result.returncode != 0:
            self.fail(f"validator rejected fixture: {result.stderr}")
        if not success and result.returncode == 0:
            self.fail("validator accepted adversarial fixture")
        return result

    def rejected(
        self, evidence: dict, budget_set: dict, expected: str, **kwargs: object
    ) -> None:
        result = self.invoke(evidence, budget_set, success=False, **kwargs)
        self.assertIn(expected, result.stderr)

    def test_accepts_canonical_qualified_and_calibration_documents(self) -> None:
        release = self.invoke(evidence_manifest(), frozen_budget_set(), success=True)
        self.assertIn("structure: PASS", release.stdout)
        self.assertRegex(release.stdout, r"budget-set\.sha256=[0-9a-f]{64}")

        calibration = evidence_manifest(
            mode="calibration", verdict="not-release-qualifying"
        )
        self.invoke(calibration, provisional_budget_set(), success=True)

    def test_rejects_duplicate_keys_and_noncanonical_or_nonfinite_json(self) -> None:
        evidence = evidence_manifest()
        budgets = frozen_budget_set()
        duplicate_evidence = b'{"kind":"duplicate",' + canonical(evidence)[1:]
        self.rejected(
            evidence,
            budgets,
            "repeats key 'kind'",
            evidence_raw=duplicate_evidence,
        )

        duplicate_budget = b'{"kind":"duplicate",' + canonical(budgets)[1:]
        self.rejected(
            evidence,
            budgets,
            "repeats key 'kind'",
            budget_raw=duplicate_budget,
        )

        pretty = (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode()
        self.rejected(evidence, budgets, "must be canonical JSON", evidence_raw=pretty)

        nonfinite = canonical(budgets).replace(
            b'"upperBound":42.5', b'"upperBound":NaN'
        )
        self.rejected(evidence, budgets, "non-finite number", budget_raw=nonfinite)

    def test_schema_kind_mode_verdict_and_shapes_fail_closed(self) -> None:
        mutations = [
            (
                lambda value: value.update(schemaVersion=2),
                "evidence schema is unsupported",
            ),
            (
                lambda value: value.update(kind="dev.dory.other"),
                "evidence kind is unsupported",
            ),
            (
                lambda value: value.update(qualificationMode="diagnostic"),
                "qualification mode is unsupported",
            ),
            (lambda value: value.update(verdict="PASS"), "verdict contradicts"),
            (lambda value: value.update(unexpected=True), "extra=['unexpected']"),
            (
                lambda value: value["candidate"].pop("runtimePlanSHA256"),
                "missing=['runtimePlanSHA256']",
            ),
            (
                lambda value: value["launch"]["graphics"].update(unknown=True),
                "extra=['unknown']",
            ),
        ]
        for mutate, expected in mutations:
            with self.subTest(expected=expected):
                evidence = evidence_manifest()
                mutate(evidence)
                self.rejected(evidence, frozen_budget_set(), expected)

        calibration = evidence_manifest(mode="calibration", verdict="qualified")
        self.rejected(calibration, provisional_budget_set(), "verdict contradicts")

        budget = frozen_budget_set()
        budget["schemaVersion"] = True
        self.rejected(evidence_manifest(), budget, "budget set schema is unsupported")
        budget = frozen_budget_set()
        budget["kind"] = "dev.dory.other"
        self.rejected(evidence_manifest(), budget, "budget set kind is unsupported")
        budget = frozen_budget_set()
        budget["unknown"] = True
        self.rejected(evidence_manifest(), budget, "extra=['unknown']")
        budget = frozen_budget_set()
        budget["budgets"][0]["direction"] = "faster"
        self.rejected(evidence_manifest(), budget, "direction is unsupported")
        budget = frozen_budget_set()
        budget["budgets"][0]["approval"]["unknown"] = True
        self.rejected(evidence_manifest(), budget, "extra=['unknown']")

    def test_candidate_plan_operation_and_budget_bindings_are_exact(self) -> None:
        cases = [
            (
                "candidate",
                "componentCandidateInventorySHA256",
                digest("A"),
                "lowercase SHA-256",
            ),
            ("candidate", "runtimePlanSHA256", "0" * 64, "all-zero identity"),
            ("launch", "operationID", "not-a-uuid", "canonical UUID"),
            ("launch", "planGeneration", True, "positive integer"),
            ("launch", "planGeneration", 0, "positive integer"),
        ]
        for owner, key, replacement, expected in cases:
            with self.subTest(owner=owner, key=key):
                evidence = evidence_manifest()
                evidence[owner][key] = replacement
                self.rejected(evidence, frozen_budget_set(), expected)

        evidence = evidence_manifest()
        evidence["candidate"]["budgetSetSHA256"] = digest("9")
        self.rejected(evidence, frozen_budget_set(), "does not bind", rebind=False)

    def test_native_arm64_classification_is_mandatory(self) -> None:
        evidence = evidence_manifest()
        evidence["guest"]["architecture"] = "x86_64"
        self.rejected(evidence, frozen_budget_set(), "native arm64")

        evidence = evidence_manifest()
        evidence["host"]["architecture"] = "x86_64"
        self.rejected(evidence, frozen_budget_set(), "host architecture must be arm64")

        budgets = frozen_budget_set()
        budgets["architecture"] = "x86_64"
        self.rejected(
            evidence_manifest(), budgets, "budget set architecture must be arm64"
        )

        budgets = frozen_budget_set()
        budgets["budgets"][0]["applicability"]["architecture"] = "x86_64"
        self.rejected(evidence_manifest(), budgets, "architecture must be arm64")

    def test_bundle_references_cannot_escape_alias_or_change_role(self) -> None:
        paths = [
            ("../raw/observations.jsonl", "forbidden path component"),
            ("/raw/observations.jsonl", "canonical relative POSIX path"),
            ("raw\\observations.jsonl", "POSIX separators"),
            ("summary/observations.jsonl", "inside raw/"),
            ("raw/observations.json", "must end in .jsonl"),
        ]
        for replacement, expected in paths:
            with self.subTest(path=replacement):
                evidence = evidence_manifest()
                evidence["observations"] = replacement
                self.rejected(evidence, frozen_budget_set(), expected)

        evidence = evidence_manifest()
        evidence["summaries"] = evidence["fallbacks"]
        self.rejected(evidence, frozen_budget_set(), "references must be unique")

        evidence = evidence_manifest()
        evidence["signature"] = "evidence/signature.sig"
        self.rejected(evidence, frozen_budget_set(), "inside signatures/")

    def test_provisional_or_unapproved_bounds_cannot_qualify(self) -> None:
        self.rejected(
            evidence_manifest(),
            provisional_budget_set(),
            "requires a frozen budget set",
        )

        budgets = frozen_budget_set()
        budgets["budgets"][0].update(
            approval=None,
            baselineEvidenceSHA256=None,
            lowerBound=None,
            state="provisional",
            upperBound=None,
        )
        self.rejected(evidence_manifest(), budgets, "contains a provisional budget")

        for key, replacement, expected in (
            ("baselineEvidenceSHA256", None, "lowercase SHA-256"),
            ("approval", None, "must be an object"),
            ("upperBound", None, "must be a JSON number"),
        ):
            with self.subTest(key=key):
                budgets = frozen_budget_set()
                budgets["budgets"][0][key] = replacement
                self.rejected(evidence_manifest(), budgets, expected)

        budgets = frozen_budget_set()
        record = budgets["budgets"][0]
        record.update(direction="range", lowerBound=10.0, upperBound=5.0)
        self.rejected(evidence_manifest(), budgets, "range bounds are reversed")

    def test_budget_identifiers_and_applicability_are_unambiguous(self) -> None:
        budgets = frozen_budget_set()
        duplicate = copy.deepcopy(budgets["budgets"][0])
        budgets["budgets"].append(duplicate)
        self.rejected(evidence_manifest(), budgets, "sorted and unique")

        budgets = frozen_budget_set()
        budgets["budgets"][0]["applicability"]["matrixCellIDs"] = [
            digest("b"),
            MATRIX_CELL,
        ]
        self.rejected(
            evidence_manifest(), budgets, "matrixCellIDs must be sorted and unique"
        )

        budgets = frozen_budget_set()
        budgets["budgets"][0]["applicability"]["matrixCellIDs"] = [digest("9")]
        self.rejected(evidence_manifest(), budgets, "no applicable frozen budget")

        budgets = frozen_budget_set(
            quality="software", budget_id="gpu.accelerated.frame-time"
        )
        self.rejected(
            evidence_manifest(), budgets, "accelerated GPU metric is misclassified"
        )

    def test_graphics_selection_fallback_and_acceleration_are_not_interchangeable(
        self,
    ) -> None:
        evidence = evidence_manifest()
        evidence["launch"]["graphics"]["implementation"] = "virgl-venus"
        self.rejected(evidence, frozen_budget_set(), "software implementation")

        evidence = evidence_manifest()
        evidence["launch"]["graphics"]["accelerationEvidence"] = (
            "evidence/graphics-acceleration.json"
        )
        self.rejected(
            evidence,
            frozen_budget_set(),
            "software graphics cannot reference acceleration evidence",
        )

        evidence = evidence_manifest()
        evidence["launch"]["graphics"]["accelerationEvidenceSHA256"] = digest("9")
        self.rejected(
            evidence,
            frozen_budget_set(),
            "software graphics cannot carry acceleration evidence",
        )

        evidence = evidence_manifest()
        graphics = evidence["launch"]["graphics"]
        graphics.update(requestedQuality="accelerated", selectedQuality="software")
        self.rejected(
            evidence, frozen_budget_set(), "fallback classification contradicts"
        )

        evidence = evidence_manifest()
        graphics = evidence["launch"]["graphics"]
        graphics.update(
            fallback=True,
            fallbackReason="Renderer receipt unavailable",
            requestedQuality="accelerated",
            selectedQuality="software",
        )
        self.rejected(
            evidence,
            frozen_budget_set(),
            "qualified evidence cannot contain a graphics fallback",
        )

        budgets = frozen_budget_set(
            quality="accelerated", budget_id="gpu.accelerated.frame-time"
        )
        self.rejected(evidence_manifest(), budgets, "graphics quality contradicts")

    def test_structurally_bound_acceleration_requires_rawhv_and_accelerated_budget(
        self,
    ) -> None:
        evidence = evidence_manifest()
        evidence["launch"]["backend"] = "rawhv"
        evidence["launch"]["graphics"].update(
            accelerationEvidence="evidence/graphics-acceleration.json",
            accelerationEvidenceSHA256=digest("9"),
            implementation="virgl-venus",
            requestedQuality="accelerated",
            selectedQuality="accelerated",
        )
        budgets = frozen_budget_set(
            quality="accelerated", budget_id="gpu.accelerated.frame-time"
        )
        self.invoke(evidence, budgets, success=True)

        evidence["launch"]["backend"] = "vz"
        self.rejected(evidence, budgets, "not available on this backend")

        evidence["launch"]["backend"] = "rawhv"
        evidence["launch"]["graphics"]["accelerationEvidence"] = None
        self.rejected(evidence, budgets, "must be a string")

        evidence["launch"]["graphics"]["accelerationEvidence"] = (
            "evidence/graphics-acceleration.json"
        )
        evidence["launch"]["graphics"]["accelerationEvidenceSHA256"] = None
        self.rejected(evidence, budgets, "lowercase SHA-256")

        evidence["launch"]["graphics"]["accelerationEvidenceSHA256"] = digest("9")
        software_budget = frozen_budget_set(quality="any")
        self.rejected(evidence, software_budget, "no applicable accelerated budget")


if __name__ == "__main__":
    unittest.main()
