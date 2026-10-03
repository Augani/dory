#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


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
            "dynamicRendering",
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

    def test_direct_json_rejects_indirect_and_ambiguous_evidence(self) -> None:
        retained = self.root / "retained.json"
        retained.write_text('{"schema":"first","schema":"second"}')
        with self.assertRaisesRegex(MODULE.EvidenceError, "duplicates schema"):
            MODULE.direct_json_payload(self.root, retained.name)
        retained.write_text('{"value":NaN}')
        with self.assertRaisesRegex(MODULE.EvidenceError, "non-finite NaN"):
            MODULE.direct_json_payload(self.root, retained.name)
        indirect = self.root / "indirect.json"
        indirect.symlink_to(retained)
        with self.assertRaisesRegex(MODULE.EvidenceError, "missing or indirect"):
            MODULE.direct_json_payload(self.root, indirect.name)

    def verify(self, probe_digest_override: str | None = None) -> dict:
        # The displayed-pixel verifier has its own image/trace negative fixtures. These
        # comparison tests exercise its required provenance binding without duplicating PNGs.
        def visual_summary(directory: Path) -> dict:
            path = directory.name.removesuffix(".visual-evidence")
            return {
                "status": "evidence-verified", "machineID": "gpu-a4-ubuntu",
                "operationID": "operation-1", "workerGeneration": 7,
                "probe": "vulkan-application" if path == "zink-venus" else "gl",
                "probeNonce": "campaign-001",
                "probeSHA256": probe_digest_override or hashlib.sha256(
                    (directory / "gpu-probe.json").read_bytes()).hexdigest(),
                "gpuDisplayedPixelEvidenceSHA256": hashlib.sha256(
                    (directory / "gpu-display-evidence.json").read_bytes()).hexdigest(),
            }
        with mock.patch.object(MODULE.PIXEL_VERIFIER, "verify", side_effect=visual_summary):
            return MODULE.verify(self.root)

    def write(self) -> None:
        (self.root / "comparison.json").write_text(json.dumps(self.comparison))
        for path, value in self.values.items():
            run_bytes = json.dumps(value).encode()
            (self.root / f"{path}.json").write_bytes(run_bytes)
            visual_directory = self.root / f"{path}.visual-evidence"
            visual_directory.mkdir(exist_ok=True)
            probe = {
                "deviceName": "Venus" if path == "zink-venus" else "virgl",
                "driver": "venus" if path == "zink-venus" else "virgl",
                "apiVersion": "1.3",
            }
            probe_bytes = json.dumps(probe).encode()
            (visual_directory / "gpu-probe.json").write_bytes(probe_bytes)
            visual_bytes = json.dumps({"kind": "fixture-visual-proof", "path": path}).encode()
            (visual_directory / "gpu-display-evidence.json").write_bytes(visual_bytes)
            compute_bytes = None
            if path == "zink-venus":
                reduction, result_hash = (
                    MODULE.PIXEL_VERIFIER.PROBE_VALIDATOR.expected_compute_result(
                        "campaign-001"))
                compute_bytes = json.dumps({
                    "schema": "dev.dory.gpu-probe", "version": 1, "probe": "compute",
                    "deviceName": "Venus", "driver": "venus", "apiVersion": "1.3",
                    "extensionsUsed": [], "resultHash": result_hash, "frameCount": 1,
                    "nonce": "campaign-001", "timings": {"totalMilliseconds": 1.0},
                    "elementCount": 1024 * 1024, "reduction": reduction,
                }).encode()
                (self.root / f"{path}.compute.json").write_bytes(compute_bytes)
            inventory = {
                "schema": MODULE.INVENTORY_SCHEMA, "path": path,
                **{field: value[field] for field in (
                    "guestDistribution", "guestVersion", "guestArchitecture",
                    "desktopEnvironment", "rendererDevice", "glVersion",
                    "apiCapabilities", "softwareRendererDetected")},
                "kernelRelease": "6.13.0", "sessionType": "wayland",
                "compositorVersion": "GNOME Shell 46.0", "mesaVersion": "25.0.1",
                "probeDeviceName": "Venus" if path == "zink-venus" else "virgl",
                "probeDriver": "venus" if path == "zink-venus" else "virgl",
                "probeApiVersion": "1.3",
                "probeResultSHA256": hashlib.sha256(probe_bytes).hexdigest(),
                "probeSurfaceFormat": "bgra8-unorm" if path == "zink-venus" else None,
                "probeColorAtlasFormat": "bgra8-unorm" if path == "zink-venus" else None,
                "probeStrategyFeatureFallback": False if path == "zink-venus" else None,
                "packages": ["mesa-vulkan-drivers\t25.0.1"],
                "driverFiles": ["/usr/share/vulkan/icd.d/virtio_icd.json"],
                "glxinfoBasic": "OpenGL renderer string: Apple M2 Pro",
                "vulkanSummary": "deviceName = Venus" if path == "zink-venus" else None,
            }
            inventory_bytes = json.dumps(inventory).encode()
            (self.root / f"{path}.inventory.json").write_bytes(inventory_bytes)
            raw_directory = self.root / f"{path}.raw"
            raw_directory.mkdir(exist_ok=True)
            raw_workloads = []
            for item in value["workloads"]:
                identifier = item["id"]
                stdout = raw_directory / f"{identifier}.stdout"
                stderr = raw_directory / f"{identifier}.stderr"
                trace = raw_directory / f"{identifier}.graphics-trace.ndjson"
                samples = raw_directory / f"{identifier}.worker-samples.ndjson"
                output_lines = []
                if item["firstShaderCompileStallMs"] is not None:
                    output_lines.append(
                        'DORY_METRIC {"kind":"shaderCompile",'
                        '"durationNanoseconds":24000000}')
                if identifier == "glmark2" and item["score"] is not None:
                    output_lines.append(f"glmark2 Score: {item['score']}")
                stdout.write_bytes(("\n".join(output_lines) + "\n").encode())
                stderr.write_bytes(b"")
                events = []
                timestamp = 1_000_000_000
                for sequence in range(1, item["frameCount"] + 1):
                    if sequence > 1:
                        timestamp += 16_700_000 if sequence <= 176 else 17_000_000
                    event = {
                        "context": {"machineID": value["machineID"],
                                    "operationID": "operation-1", "workerGeneration": 7},
                        "scanoutID": 0, "width": 1920, "height": 1080,
                        "resourceID": 42, "displayResourceGeneration": 3,
                        "rendererResourceGeneration": 5, "deviceGeneration": 2,
                        "frameSequence": sequence,
                    }
                    events.append({**event, "stage": "hostSubmissionAccepted",
                                   "monotonicNanoseconds": timestamp - 1})
                    events.append({**event, "stage": "metalPresentationCompleted",
                                   "metalCommandBufferCompletionID": sequence,
                                   "monotonicNanoseconds": timestamp})
                trace.write_bytes(b"".join(json.dumps(event).encode() + b"\n"
                                           for event in events))
                if item["workerPeakCPUPercent"] is None:
                    samples.write_bytes(b"")
                else:
                    samples.write_bytes(json.dumps({
                        "monotonicNanoseconds": 1_000_000_000,
                        "workerPID": 123,
                        "cpuPercent": item["workerPeakCPUPercent"],
                        "rssBytes": item["workerPeakRSSBytes"],
                    }).encode() + b"\n")
                raw_workloads.append({
                    "id": identifier, "command": ["fixture-workload", identifier],
                    "exitCode": 0, "timedOut": False,
                    "frameCount": item["frameCount"],
                    "p99FrameIntervalMs": 17.0 if item["frameCount"] > 1 else None,
                    "stdoutSHA256": hashlib.sha256(stdout.read_bytes()).hexdigest(),
                    "stderrSHA256": hashlib.sha256(stderr.read_bytes()).hexdigest(),
                    "graphicsTraceSHA256": hashlib.sha256(trace.read_bytes()).hexdigest(),
                    "workerSamplesSHA256": hashlib.sha256(samples.read_bytes()).hexdigest(),
                })
            plan = {
                "schema": "dory.opengl-workload-plan@2", "path": path,
                "workerPID": 123, "expectedProbeNonce": "campaign-001",
                "metadata": {
                    **{field: value[field] for field in (
                        "candidateID", "machineID", "guestDistribution", "guestVersion",
                        "guestArchitecture", "desktopEnvironment", "widthPixels",
                        "heightPixels", "cpuCount", "memoryMB", "rendererDevice",
                        "glVersion", "apiCapabilities", "softwareRendererDetected",
                    )},
                    "workerGeneration": 7, "operationID": "operation-1",
                },
                "workloads": [{"id": raw["id"], "command": raw["command"]}
                              for raw in raw_workloads],
            }
            plan_bytes = json.dumps(plan).encode()
            (self.root / f"{path}.plan.json").write_bytes(plan_bytes)
            collection = {
                "schema": MODULE.COLLECTION_SCHEMA, "path": path,
                "planSHA256": hashlib.sha256(plan_bytes).hexdigest(), "workerPID": 123,
                "workerGeneration": 7, "operationID": "operation-1",
                "inventorySHA256": hashlib.sha256(inventory_bytes).hexdigest(),
                "runSHA256": hashlib.sha256(run_bytes).hexdigest(),
                "visualEvidenceSHA256": hashlib.sha256(visual_bytes).hexdigest(),
                "computeSHA256": (hashlib.sha256(compute_bytes).hexdigest()
                                  if compute_bytes is not None else None),
                "workloads": raw_workloads,
            }
            (self.root / f"{path}.collection.json").write_text(json.dumps(collection))

    def test_complete_controlled_comparison_passes_and_renders_table(self) -> None:
        self.write()
        summary = self.verify()
        self.assertEqual(summary["selectedPath"], "zink-venus")
        table = MODULE.markdown(summary)
        self.assertIn("glmark2 | p95 frame", table)
        self.assertIn("glmark2 | p99 frame", table)
        self.assertIn("Selected default: `zink-venus`", table)

    def test_missing_workload_fails(self) -> None:
        self.values["zink-venus"]["workloads"] = self.values["zink-venus"]["workloads"][:-1]
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "exactly the required"):
            self.verify()

    def test_uncontrolled_resources_fail(self) -> None:
        self.values["virgl2-angle"]["memoryMB"] = 4096
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "memoryMB differs"):
            self.verify()

    def test_selected_path_must_pass_without_software_fallback(self) -> None:
        self.values["zink-venus"]["rendererDevice"] = "llvmpipe"
        self.values["zink-venus"]["softwareRendererDetected"] = True
        for item in self.values["zink-venus"]["workloads"]:
            item["status"] = "FAIL"
            item["failure"] = "software fallback"
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "selectedPath"):
            self.verify()

    def test_passing_alternative_requires_named_compatibility_need(self) -> None:
        self.comparison["compatibilityRequirement"] = None
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "compatibility requirement"):
            self.verify()

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
            self.verify()

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
        summary = self.verify()
        self.assertEqual(summary["runs"]["virgl2-angle"]["workloads"][0]["status"], "FAIL")
        self.assertIn("—", MODULE.markdown(summary))

    def test_api_capabilities_must_be_explicit_unique_and_sorted(self) -> None:
        self.values["zink-venus"]["apiCapabilities"] = ["VK_KHR_dynamic_rendering", "VK_KHR_dynamic_rendering"]
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "unique and sorted"):
            self.verify()

    def test_passing_zink_requires_the_reviewed_vulkan_prerequisites(self) -> None:
        self.values["zink-venus"]["apiCapabilities"].remove("VK_EXT_robustness2")
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "missing required capabilities"):
            self.verify()

    def test_passing_zink_cannot_use_baseline_feature_fallback(self) -> None:
        self.write()
        inventory_path = self.root / "zink-venus.inventory.json"
        collection_path = self.root / "zink-venus.collection.json"
        inventory = json.loads(inventory_path.read_text())
        inventory["probeStrategyFeatureFallback"] = True
        inventory_bytes = json.dumps(inventory).encode()
        inventory_path.write_bytes(inventory_bytes)
        collection = json.loads(collection_path.read_text())
        collection["inventorySHA256"] = hashlib.sha256(inventory_bytes).hexdigest()
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError, "fell back"):
            self.verify()

    def test_run_or_inventory_tamper_breaks_collection_hash(self) -> None:
        self.write()
        inventory_path = self.root / "zink-venus.inventory.json"
        inventory_path.write_bytes(inventory_path.read_bytes() + b" ")
        with self.assertRaisesRegex(MODULE.EvidenceError, "collection hash mismatch"):
            self.verify()

    def test_passing_workload_requires_raw_metal_trace_evidence(self) -> None:
        self.write()
        collection_path = self.root / "zink-venus.collection.json"
        collection = json.loads(collection_path.read_text())
        collection["workloads"][0]["graphicsTraceSHA256"] = None
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError, "graphicsTraceSHA256 lacks"):
            self.verify()

    def test_rehashed_metadata_cannot_substitute_for_missing_or_altered_raw_trace(self) -> None:
        self.write()
        trace = self.root / "zink-venus.raw" / "glmark2.graphics-trace.ndjson"
        original = trace.read_bytes()
        trace.write_bytes(b'{"stage":"fabricated"}\n')
        with self.assertRaisesRegex(MODULE.EvidenceError, "differs from the retained raw"):
            self.verify()
        trace.unlink()
        with self.assertRaisesRegex(MODULE.EvidenceError, "is missing"):
            self.verify()
        replacement = self.root / "outside-trace.ndjson"
        replacement.write_bytes(original)
        trace.symlink_to(replacement)
        with self.assertRaisesRegex(MODULE.EvidenceError, "missing or indirect"):
            self.verify()

    def test_consistently_rehashed_trace_still_replays_frame_count(self) -> None:
        self.write()
        trace = self.root / "zink-venus.raw" / "glmark2.graphics-trace.ndjson"
        lines = trace.read_bytes().splitlines(keepends=True)
        trace.write_bytes(b"".join(lines[:-2]))
        collection_path = self.root / "zink-venus.collection.json"
        collection = json.loads(collection_path.read_text())
        collection["workloads"][0]["graphicsTraceSHA256"] = hashlib.sha256(
            trace.read_bytes()).hexdigest()
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError, "frame count differs from raw"):
            self.verify()

    def test_rehashed_trace_rejects_completion_before_submission(self) -> None:
        self.write()
        trace = self.root / "zink-venus.raw" / "glmark2.graphics-trace.ndjson"
        events = [json.loads(line) for line in trace.read_bytes().splitlines()]
        events[0]["monotonicNanoseconds"] = (
            events[1]["monotonicNanoseconds"] + 1
        )
        trace.write_bytes(b"".join(json.dumps(event).encode() + b"\n" for event in events))
        collection_path = self.root / "zink-venus.collection.json"
        collection = json.loads(collection_path.read_text())
        collection["workloads"][0]["graphicsTraceSHA256"] = hashlib.sha256(
            trace.read_bytes()
        ).hexdigest()
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError,
                                    "completion does not follow its accepted host submission"):
            self.verify()

    def test_rehashed_worker_samples_cannot_forge_reported_cpu_peak(self) -> None:
        self.write()
        samples = self.root / "zink-venus.raw" / "glmark2.worker-samples.ndjson"
        sample = json.loads(samples.read_text())
        sample["cpuPercent"] = 1.0
        samples.write_bytes(json.dumps(sample).encode() + b"\n")
        collection_path = self.root / "zink-venus.collection.json"
        collection = json.loads(collection_path.read_text())
        collection["workloads"][0]["workerSamplesSHA256"] = hashlib.sha256(
            samples.read_bytes()
        ).hexdigest()
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError,
                                    "CPU/RSS peaks differ from retained raw samples"):
            self.verify()

    def test_raw_workload_command_must_match_the_retained_plan(self) -> None:
        self.write()
        collection_path = self.root / "zink-venus.collection.json"
        collection = json.loads(collection_path.read_text())
        collection["workloads"][0]["command"] = ["different-workload"]
        collection_path.write_text(json.dumps(collection))
        with self.assertRaisesRegex(MODULE.EvidenceError, "command differs from retained plan"):
            self.verify()

    def test_visual_proof_must_be_bound_to_the_same_worker_generation(self) -> None:
        self.write()
        with mock.patch.object(MODULE.PIXEL_VERIFIER, "verify", return_value={
            "status": "evidence-verified", "machineID": "gpu-a4-ubuntu",
            "operationID": "operation-1", "workerGeneration": 99,
            "probe": "vulkan-application", "probeNonce": "campaign-001",
            "gpuDisplayedPixelEvidenceSHA256": "0" * 64,
        }):
            with self.assertRaisesRegex(MODULE.EvidenceError, "another path or runner"):
                MODULE.verify(self.root)

    def test_visual_proof_must_bind_the_same_probe_bytes(self) -> None:
        self.write()
        with self.assertRaisesRegex(MODULE.EvidenceError, "probe differs from guest inventory"):
            self.verify(probe_digest_override="0" * 64)

    def test_zink_needs_independently_checked_compute_result(self) -> None:
        self.write()
        (self.root / "zink-venus.compute.json").unlink()
        with self.assertRaisesRegex(MODULE.EvidenceError, "compute.json is missing"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
