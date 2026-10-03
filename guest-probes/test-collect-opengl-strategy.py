#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("collect-opengl-strategy.py")
SPEC = importlib.util.spec_from_file_location("dory_opengl_collector", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


def event(completion: int, timestamp: int, *, machine: str = "vm-1") -> dict:
    return {
        "stage": "metalPresentationCompleted",
        "context": {
            "machineID": machine, "operationID": "operation-1", "workerGeneration": 7,
        },
        "scanoutID": 0,
        "width": 1920,
        "height": 1080,
        "metalCommandBufferCompletionID": completion,
        "monotonicNanoseconds": timestamp,
        "resourceID": 42,
        "displayResourceGeneration": 3,
        "rendererResourceGeneration": 5,
        "deviceGeneration": 2,
        "frameSequence": completion,
    }


def accepted(completion: int, timestamp: int, *, machine: str = "vm-1") -> dict:
    return {**event(completion, timestamp, machine=machine),
            "stage": "hostSubmissionAccepted", "metalCommandBufferCompletionID": None}


class OpenGLStrategyCollectorTests(unittest.TestCase):
    def test_direct_evidence_reads_reject_links_and_allow_empty_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence"
            evidence.write_bytes(b"guest-rendered-frame")
            link = root / "indirect"
            link.symlink_to(evidence)
            self.assertEqual(COLLECTOR.direct_bytes(evidence), b"guest-rendered-frame")
            self.assertEqual(COLLECTOR.sha256(evidence), hashlib.sha256(
                b"guest-rendered-frame").hexdigest())
            with self.assertRaises(OSError):
                COLLECTOR.direct_bytes(link)
            with self.assertRaises(OSError):
                COLLECTOR.sha256(link)
            replacement = root / "replacement"
            replacement.write_bytes(b"new-evidence")
            original_lstat = Path.lstat
            def replace_on_final_stat(path: Path):
                if path == evidence and replacement.exists():
                    os.replace(replacement, evidence)
                return original_lstat(path)
            with mock.patch.object(Path, "lstat", replace_on_final_stat):
                with self.assertRaisesRegex(COLLECTOR.CollectionError, "changed"):
                    COLLECTOR.direct_bytes(evidence)
            empty_log = root / "empty-log"
            empty_log.write_bytes(b"")
            self.assertEqual(COLLECTOR.direct_bytes(empty_log, allow_empty=True), b"")
            with self.assertRaises(COLLECTOR.CollectionError):
                COLLECTOR.direct_bytes(empty_log)

    def test_trace_measures_only_this_machine_generation_and_scanout(self) -> None:
        entries = [
            accepted(1, 999_000_000),
            event(1, 1_000_000_000),
            accepted(2, 1_009_000_000, machine="another-vm"),
            event(2, 1_010_000_000, machine="another-vm"),
            accepted(3, 1_019_000_000),
            event(3, 1_020_000_000),
            {**event(4, 1_025_000_000), "scanoutID": 1},
            accepted(5, 1_039_000_000),
            event(5, 1_040_000_000),
        ]
        raw = b"".join(json.dumps(item).encode() + b"\n" for item in entries)
        timestamps = COLLECTOR.parse_trace(raw, "vm-1", "operation-1", 7, 1920, 1080)
        self.assertEqual(timestamps, [1_000_000_000, 1_020_000_000, 1_040_000_000])
        intervals = [(right - left) / 1_000_000
                     for left, right in zip(timestamps, timestamps[1:])]
        self.assertEqual(COLLECTOR.percentile(intervals, 95), 20.0)
        self.assertEqual(COLLECTOR.percentile(intervals, 99), 20.0)

    def test_duplicate_or_partial_completion_fails_closed(self) -> None:
        duplicate = [accepted(1, 500), event(1, 1_000), event(1, 2_000)]
        raw = b"".join(json.dumps(item).encode() + b"\n" for item in duplicate)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "duplicate"):
            COLLECTOR.parse_trace(raw, "vm-1", "operation-1", 7, 1920, 1080)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "partial"):
            COLLECTOR.parse_trace(raw[:-1], "vm-1", "operation-1", 7, 1920, 1080)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "accepted host submission"):
            COLLECTOR.parse_trace(json.dumps(event(2, 3_000)).encode() + b"\n",
                                  "vm-1", "operation-1", 7, 1920, 1080)
        reversed_events = [event(2, 3_000), accepted(2, 2_000)]
        raw = b"".join(json.dumps(item).encode() + b"\n" for item in reversed_events)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "earlier accepted host submission"):
            COLLECTOR.parse_trace(raw, "vm-1", "operation-1", 7, 1920, 1080)
        reversed_times = [accepted(2, 3_000), event(2, 2_000)]
        raw = b"".join(json.dumps(item).encode() + b"\n" for item in reversed_times)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "does not follow"):
            COLLECTOR.parse_trace(raw, "vm-1", "operation-1", 7, 1920, 1080)

    def test_campaign_process_group_termination_retires_grandchildren(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "orphan-survived"
            ready = Path(temporary) / "grandchild-ready"
            wrapper = (
                "import pathlib,subprocess,sys,time\n"
                "child = 'import pathlib,signal,sys,time; "
                "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "pathlib.Path(sys.argv[2]).write_text(\"ready\"); time.sleep(1); "
                "pathlib.Path(sys.argv[1]).write_text(\"orphan\")'\n"
                "subprocess.Popen([sys.executable, '-c', child, sys.argv[1], sys.argv[2]])\n"
                "deadline = time.monotonic() + 5\n"
                "while not pathlib.Path(sys.argv[2]).exists() and time.monotonic() < deadline: "
                "time.sleep(0.01)\n"
                "print('ready', flush=True)\n"
                "time.sleep(30)\n"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", wrapper, str(marker), str(ready)],
                stdout=subprocess.PIPE, start_new_session=True,
            )
            try:
                assert process.stdout is not None
                self.assertEqual(process.stdout.readline(), b"ready\n")
                self.assertTrue(ready.exists())
                COLLECTOR.terminate_process_group(process)
                time.sleep(1.2)
                self.assertFalse(marker.exists(), "timed-out wrapper left a guest child alive")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait(timeout=5)
                process.stdout.close()

    def test_trace_tail_is_bound_to_the_same_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            trace = Path(temporary) / "graphics-trace.ndjson"
            trace.write_bytes(b"earlier-event\n")
            with COLLECTOR.open_trace(trace) as source:
                start = os.fstat(source.fileno()).st_size
                with trace.open("ab") as destination:
                    destination.write(b"new-event\n")
                self.assertEqual(
                    COLLECTOR.appended_trace(source, trace, start), b"new-event\n"
                )
                replacement = Path(temporary) / "replacement"
                replacement.write_bytes(b"same-size-fake\n")
                os.replace(replacement, trace)
                with self.assertRaisesRegex(COLLECTOR.CollectionError, "replaced"):
                    COLLECTOR.appended_trace(source, trace, start)
            link = Path(temporary) / "link"
            link.symlink_to(trace)
            with self.assertRaises(OSError):
                COLLECTOR.open_trace(link)

    def test_workload_retains_replayable_renderer_cpu_rss_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = root / "graphics-trace.ndjson"
            trace.write_bytes(b"")
            raw = b"".join(json.dumps(item).encode() + b"\n" for item in (
                accepted(1, 999_000_000), event(1, 1_000_000_000),
                accepted(2, 1_015_000_000), event(2, 1_016_000_000),
            ))
            command = (
                "import pathlib,sys,time\n"
                "with pathlib.Path(sys.argv[1]).open('ab') as trace:\n"
                " trace.write(sys.argv[2].encode())\n"
                "time.sleep(0.4)\n"
                "print('DORY_METRIC {\"kind\":\"shaderCompile\",\"durationNanoseconds\":24000000}')\n"
                "print('glmark2 Score: 1200')\n"
            )
            spec = {
                "id": "glmark2",
                "command": [sys.executable, "-c", command, str(trace), raw.decode()],
                "timeoutSeconds": 10,
            }
            plan = {
                "graphicsTrace": str(trace), "workerPID": 123,
                "metadata": {
                    "machineID": "vm-1", "operationID": "operation-1",
                    "widthPixels": 1920, "heightPixels": 1080,
                    "softwareRendererDetected": False,
                },
            }
            with mock.patch.object(COLLECTOR, "sample_worker", return_value=(42.0, 123456)):
                measured, retained = COLLECTOR.collect_workload(spec, plan, root, 7)
            self.assertEqual(measured["status"], "PASS")
            self.assertEqual(measured["workerPeakCPUPercent"], 42.0)
            self.assertEqual(measured["workerPeakRSSBytes"], 123456)
            samples = root / "glmark2.worker-samples.ndjson"
            self.assertEqual(retained["workerSamplesSHA256"], COLLECTOR.sha256(samples))
            COLLECTOR.VERIFIER.replay_worker_samples(samples.read_bytes(), measured, 123)

    def test_shader_stall_requires_explicit_machine_event(self) -> None:
        self.assertIsNone(COLLECTOR.shader_stall("shader compiled quickly"))
        self.assertEqual(COLLECTOR.shader_stall(
            'DORY_METRIC {"kind":"shaderCompile","durationNanoseconds":42000000}\n'
        ), 42.0)
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "invalid fields"):
            COLLECTOR.shader_stall('DORY_METRIC {"kind":"shaderCompile"}\n')

    def test_plan_requires_all_workloads_and_explicit_unsupported_failures(self) -> None:
        plan = {
            "schema": COLLECTOR.PLAN_SCHEMA,
            "path": "zink-venus",
            "workerPID": 123,
            "workerExecutable": "/tmp/dory-renderer-worker",
            "graphicsTrace": "/tmp/graphics-trace.ndjson",
            "inventoryCommand": ["ssh", "guest", "collect-opengl-inventory.py"],
            "visualEvidenceDirectory": "/tmp/visual-evidence",
            "computeResultFile": "/tmp/compute-result.json",
            "expectedProbeNonce": "campaign-001",
            "metadata": {
                "candidateID": "candidate-1", "machineID": "vm-1",
                "guestDistribution": "ubuntu", "guestVersion": "24.04",
                "guestArchitecture": "aarch64", "desktopEnvironment": "GNOME",
                "widthPixels": 1920, "heightPixels": 1080,
                "cpuCount": 4, "memoryMB": 8192, "rendererDevice": "Apple GPU",
                "glVersion": "4.6", "apiCapabilities": ["VK_KHR_dynamic_rendering"],
                "softwareRendererDetected": False, "workerGeneration": 7,
                "operationID": "operation-1",
            },
            "workloads": [{
                "id": identifier, "command": None,
                "timeoutSeconds": 120, "unavailableReason": "not installed",
            } for identifier in COLLECTOR.VERIFIER.WORKLOADS],
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "plan.json"
            path.write_text(json.dumps(plan))
            self.assertEqual(len(COLLECTOR.load_plan(path)["workloads"]), 9)
            plan["workloads"][0]["unavailableReason"] = None
            path.write_text(json.dumps(plan))
            with self.assertRaisesRegex(COLLECTOR.CollectionError, "unavailable reason"):
                COLLECTOR.load_plan(path)

    def test_inventory_must_match_plan_facts_and_enabled_capabilities(self) -> None:
        metadata = {
            "guestDistribution": "ubuntu", "guestVersion": "24.04",
            "guestArchitecture": "aarch64", "desktopEnvironment": "ubuntu:GNOME",
            "rendererDevice": "zink (Venus)", "glVersion": "4.6 Mesa 25.0.1",
            "apiCapabilities": ["VK_KHR_swapchain", "dynamicRendering"],
            "softwareRendererDetected": False,
        }
        plan = {"path": "zink-venus", "metadata": metadata}
        inventory = {
            "schema": COLLECTOR.INVENTORY_SCHEMA, "path": "zink-venus", **metadata,
            "kernelRelease": "6.13.0", "sessionType": "wayland",
            "compositorVersion": "GNOME Shell 46.0", "mesaVersion": "25.0.1",
            "probeDeviceName": "Venus", "probeDriver": "venus",
            "probeApiVersion": "1.3", "probeResultSHA256": "a" * 64,
            "probeSurfaceFormat": "VK_FORMAT_B8G8R8A8_UNORM",
            "probeColorAtlasFormat": "bgra8-unorm",
            "probeStrategyFeatureFallback": False,
            "packages": ["mesa-vulkan-drivers\t25.0.1"],
            "driverFiles": ["/usr/share/vulkan/icd.d/virtio_icd.json"],
            "glxinfoBasic": "OpenGL renderer string: zink (Venus)",
            "vulkanSummary": "deviceName = Venus",
        }
        self.assertEqual(COLLECTOR.validate_inventory(inventory, plan), inventory)
        inventory["apiCapabilities"] = ["VK_EXT_robustness2", *metadata["apiCapabilities"]]
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "apiCapabilities disagrees"):
            COLLECTOR.validate_inventory(inventory, plan)
        inventory["apiCapabilities"] = metadata["apiCapabilities"]
        inventory["guestVersion"] = "25.04"
        with self.assertRaisesRegex(COLLECTOR.CollectionError, "guestVersion disagrees"):
            COLLECTOR.validate_inventory(inventory, plan)

    def test_visual_preflight_copies_and_binds_exact_probe_before_workloads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            probe = {"deviceName": "virgl", "driver": "virgl", "apiVersion": "4.6"}
            probe_bytes = json.dumps(probe).encode()
            for name in COLLECTOR.VISUAL_FILES:
                (source / name).write_bytes(
                    probe_bytes if name == "gpu-probe.json" else b"retained-evidence")
            plan = {
                "path": "virgl2-angle", "visualEvidenceDirectory": str(source),
                "expectedProbeNonce": "campaign-001", "computeResultFile": None,
                "metadata": {
                    "machineID": "vm-1", "operationID": "operation-1",
                    "workerGeneration": 7,
                },
            }
            inventory = {
                "probeResultSHA256": hashlib.sha256(probe_bytes).hexdigest(),
                "probeDeviceName": "virgl", "probeDriver": "virgl",
                "probeApiVersion": "4.6",
            }
            output = root / "output"
            output.mkdir()
            proof = {
                "status": "evidence-verified", "probe": "gl", "machineID": "vm-1",
                "operationID": "operation-1", "workerGeneration": 7,
                "probeNonce": "campaign-001",
            }
            with mock.patch.object(COLLECTOR.VERIFIER.PIXEL_VERIFIER, "verify",
                                   return_value=proof):
                visual_hash, compute_hash = COLLECTOR.collect_visual_proof(
                    plan, inventory, output)
            self.assertEqual(visual_hash, COLLECTOR.sha256(
                output / "visual-evidence" / "gpu-display-evidence.json"))
            self.assertIsNone(compute_hash)
            proof["workerGeneration"] = 8
            other_output = root / "other-output"
            other_output.mkdir()
            with mock.patch.object(COLLECTOR.VERIFIER.PIXEL_VERIFIER, "verify",
                                   return_value=proof):
                with self.assertRaisesRegex(COLLECTOR.CollectionError,
                                            "another path, machine, operation or worker"):
                    COLLECTOR.collect_visual_proof(plan, inventory, other_output)


if __name__ == "__main__":
    unittest.main()
