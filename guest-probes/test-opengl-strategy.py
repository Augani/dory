#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify-opengl-strategy.py")
SPEC = importlib.util.spec_from_file_location("opengl_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def workload(identifier: str, status: str = "PASS") -> dict[str, object]:
    return {
        "id": identifier,
        "status": status,
        "frameCount": 180,
        "p95FrameIntervalMs": 16.7,
        "firstShaderCompileStallMs": 24.0,
        "workerPeakCPUPercent": 48.0,
        "workerPeakRSSBytes": 268435456,
        "score": 1200 if identifier == "glmark2" else None,
        "failure": None if status == "PASS" else "named workload failed",
    }


def run(path: str) -> dict[str, object]:
    return {
        "schema": MODULE.RUN_SCHEMA,
        "path": path,
        "sourceCommit": "a" * 40,
        "candidateID": "candidate-1",
        "capturedAt": "2026-09-21T12:00:00Z",
        "hostHardwareModelIdentifier": "Mac14,10",
        "hostOperatingSystemBuild": "26B5086k",
        "machineID": "gpu-a4-ubuntu",
        "guestDistribution": "ubuntu",
        "guestVersion": "24.04.5",
        "guestArchitecture": "arm64",
        "desktopEnvironment": "GNOME",
        "widthPixels": 1920,
        "heightPixels": 1080,
        "cpuCount": 4,
        "memoryMB": 8192,
        "rendererDevice": "Apple M2 Pro",
        "glVersion": "4.6",
        "apiCapabilities": [
            "GL_ARB_robustness",
            "VK_EXT_extended_dynamic_state",
            "VK_EXT_robustness2",
            "VK_KHR_dynamic_rendering",
            "timelineSemaphore",
        ],
        "softwareRendererDetected": False,
        "workerArtifactSHA256": "b" * 64,
        "workloads": [workload(identifier) for identifier in MODULE.WORKLOADS],
    }


class OpenGLStrategyEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-opengl-evidence-")
        self.root = Path(self.temporary.name)
        self.values = {path: run(path) for path in MODULE.PATHS}
        self.comparison = {
            "schema": MODULE.SCHEMA,
            "selectedPath": "zink-venus",
            "compatibilityRequirement": "VirGL2 is required for the legacy GTK renderer",
            "decisionRationale": "Zink passed with lower p95 frame time.",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self) -> None:
        (self.root / "comparison.json").write_text(json.dumps(self.comparison))
        for path, value in self.values.items():
            (self.root / f"{path}.json").write_text(json.dumps(value))

    def test_complete_controlled_comparison_passes_and_renders_table(self) -> None:
        self.write()
        summary = MODULE.verify(self.root)
        self.assertEqual(summary["selectedPath"], "zink-venus")
        table = MODULE.markdown(summary)
        self.assertIn("glmark2 | p95 frame", table)
        self.assertIn("Selected default: `zink-venus`", table)

    def test_missing_workload_fails(self) -> None:
        self.values["zink-venus"]["workloads"] = self.values["zink-venus"]["workloads"][:-1]
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "exactly the required"):
            MODULE.verify(self.root)

    def test_uncontrolled_resources_fail(self) -> None:
        self.values["virgl2-angle"]["memoryMB"] = 4096
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "memoryMB differs"):
            MODULE.verify(self.root)

    def test_selected_path_must_pass_without_software_fallback(self) -> None:
        self.values["zink-venus"]["rendererDevice"] = "llvmpipe"
        self.values["zink-venus"]["softwareRendererDetected"] = True
        for item in self.values["zink-venus"]["workloads"]:
            item["status"] = "FAIL"
            item["failure"] = "software fallback"
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "selectedPath"):
            MODULE.verify(self.root)

    def test_passing_alternative_requires_named_compatibility_need(self) -> None:
        self.comparison["compatibilityRequirement"] = None
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "compatibility requirement"):
            MODULE.verify(self.root)

    def test_failing_alternative_cannot_be_retained(self) -> None:
        first = self.values["virgl2-angle"]["workloads"][0]
        first["status"] = "FAIL"
        first["frameCount"] = 0
        first["p95FrameIntervalMs"] = None
        first["firstShaderCompileStallMs"] = None
        first["workerPeakCPUPercent"] = None
        first["workerPeakRSSBytes"] = None
        first["score"] = None
        first["failure"] = "shader compile failed"
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "failing alternative"):
            MODULE.verify(self.root)

    def test_failed_unselected_workload_may_retain_null_metrics(self) -> None:
        first = self.values["virgl2-angle"]["workloads"][0]
        first.update({
            "status": "FAIL",
            "frameCount": 0,
            "p95FrameIntervalMs": None,
            "firstShaderCompileStallMs": None,
            "workerPeakCPUPercent": None,
            "workerPeakRSSBytes": None,
            "score": None,
            "failure": "context creation failed before the first frame",
        })
        self.comparison["compatibilityRequirement"] = None
        self.write()
        summary = MODULE.verify(self.root)
        self.assertEqual(summary["runs"]["virgl2-angle"]["workloads"][0]["status"], "FAIL")
        self.assertIn("—", MODULE.markdown(summary))

    def test_api_capabilities_must_be_explicit_unique_and_sorted(self) -> None:
        self.values["zink-venus"]["apiCapabilities"] = ["VK_KHR_dynamic_rendering", "VK_KHR_dynamic_rendering"]
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "unique and sorted"):
            MODULE.verify(self.root)

    def test_passing_zink_requires_the_reviewed_vulkan_prerequisites(self) -> None:
        self.values["zink-venus"]["apiCapabilities"].remove("VK_EXT_robustness2")
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "missing required capabilities"):
            MODULE.verify(self.root)


if __name__ == "__main__":
    unittest.main()
