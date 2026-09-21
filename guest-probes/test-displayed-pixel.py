#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = ROOT / "guest-probes" / "verify-displayed-pixel.py"
SPEC = importlib.util.spec_from_file_location("dory_displayed_pixel_verifier", VERIFIER_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def build_fixture(root: Path) -> None:
    probe = {
        "schema": "dev.dory.gpu-probe",
        "version": 1,
        "probe": "gl",
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "zink",
        "apiVersion": "4.6",
        "extensionsUsed": ["GL_ARB_vertex_array_object"],
        "resultHash": "fnv1a64:0123456789abcdef",
        "frameCount": 180,
        "nonce": "campaign-001",
        "timings": {"totalMilliseconds": 3000.0},
    }
    write_json(root / "gpu-probe.json", probe)
    (root / "framebuffer.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
    frame = {
        "kind": "dev.dory.display-qualification-window",
        "schemaVersion": 1,
        "machineID": "ubuntu",
        "operationID": "operation-1",
        "scanoutID": 0,
        "frameSequence": 44,
        "displayResourceGeneration": 8,
        "metalCommandBufferCompletionID": 19,
        "windowNumber": 73,
        "windowTitle": "Dory — ubuntu — Display 1",
        "transport": "sharedTexture",
    }
    write_json(root / "display-capture-frame.json", frame)
    capture = {
        "kind": "dev.dory.machine-window-capture",
        "schemaVersion": 1,
        "status": "PASS",
        **{key: frame[key] for key in (
            "machineID", "operationID", "frameSequence", "displayResourceGeneration",
            "metalCommandBufferCompletionID", "windowNumber", "windowTitle", "transport",
        )},
        "framebufferSHA256": digest(root / "framebuffer.png"),
        "windowReceiptSHA256": digest(root / "display-capture-frame.json"),
    }
    write_json(root / "window-capture.json", capture)
    trace = {
        "sequence": 91,
        "stage": "metalPresentationCompleted",
        "context": {"machineID": "ubuntu", "operationID": "operation-1"},
        "scanoutID": 0,
        "displayResourceGeneration": 8,
        "metalCommandBufferCompletionID": 19,
    }
    (root / "graphics-trace.ndjson").write_text(json.dumps(trace) + "\n", encoding="utf-8")
    correlation = {
        "kind": "dev.dory.display-graphics-correlation",
        "schemaVersion": 1,
        "status": "PASS",
        **{key: capture[key] for key in (
            "machineID", "operationID", "frameSequence", "displayResourceGeneration",
            "metalCommandBufferCompletionID", "framebufferSHA256",
        )},
        "graphicsTraceSequence": 91,
        "graphicsTraceSHA256": digest(root / "graphics-trace.ndjson"),
    }
    write_json(root / "graphics-correlation.json", correlation)
    evidence = {
        "kind": "dev.dory.gpu-displayed-pixel-evidence",
        "schemaVersion": 1,
        "status": "PASS",
        "machineID": "ubuntu",
        "operationID": "operation-1",
        "probe": "gl",
        "probeNonce": "campaign-001",
        "probeResultHash": "fnv1a64:0123456789abcdef",
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "zink",
        "frameCount": 180,
        "probeSHA256": digest(root / "gpu-probe.json"),
        "framebufferSHA256": digest(root / "framebuffer.png"),
        "windowReceiptSHA256": digest(root / "display-capture-frame.json"),
        "captureReceiptSHA256": digest(root / "window-capture.json"),
        "graphicsTraceSHA256": digest(root / "graphics-trace.ndjson"),
        "graphicsCorrelationSHA256": digest(root / "graphics-correlation.json"),
        "displayResourceGeneration": 8,
        "metalCommandBufferCompletionID": 19,
    }
    write_json(root / "gpu-display-evidence.json", evidence)


with tempfile.TemporaryDirectory(prefix="dory-gpu-display-evidence-") as directory:
    root = Path(directory)
    build_fixture(root)
    verified = VERIFIER.verify(root, "campaign-001")
    assert verified["status"] == "evidence-verified"
    assert verified["metalCommandBufferCompletionID"] == 19

    trace_path = root / "graphics-trace.ndjson"
    original_trace = trace_path.read_text(encoding="utf-8")
    trace = json.loads(original_trace)
    trace["metalCommandBufferCompletionID"] = 20
    trace_path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "exactly one matching Metal completion" in str(error)
    else:
        raise AssertionError("verifier admitted a mismatched Metal completion")
    trace_path.write_text(original_trace, encoding="utf-8")

    evidence_path = root / "gpu-display-evidence.json"
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    evidence["framebufferSHA256"] = "0" * 64
    write_json(evidence_path, evidence)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "framebufferSHA256" in str(error)
    else:
        raise AssertionError("verifier admitted a mismatched framebuffer digest")

print("GPU displayed-pixel evidence verifier tests passed")
