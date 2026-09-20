#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "guest-probes" / "validate-result.py"
spec = importlib.util.spec_from_file_location("dory_probe_validator", VALIDATOR_PATH)
assert spec is not None and spec.loader is not None
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def sample(probe: str) -> dict[str, object]:
    return {
        "schema": "dev.dory.gpu-probe",
        "version": 1,
        "probe": probe,
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "venus",
        "apiVersion": "1.3.0",
        "extensionsUsed": ["VK_KHR_swapchain"] if probe != "gl" else [
            "GL_ARB_vertex_array_object"
        ],
        "resultHash": "fnv1a64:0123456789abcdef",
        "frameCount": 1,
        "nonce": "campaign-001",
        "timings": {"totalMilliseconds": 3.25},
    }


for probe in validator.PROBES:
    assert validator.validate(sample(probe), "campaign-001")["probe"] == probe

for renderer in ("llvmpipe", "lavapipe", "Software Rasterizer"):
    record = sample("gl")
    record["deviceName"] = renderer
    try:
        validator.validate(record)
    except ValueError:
        pass
    else:
        raise AssertionError(f"validator admitted software renderer {renderer}")

try:
    validator.validate(sample("compute"), "different-nonce")
except ValueError:
    pass
else:
    raise AssertionError("validator admitted a mismatched campaign nonce")

with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "result.json"
    path.write_text(json.dumps(sample("vulkan-application")), encoding="utf-8")
    completed = subprocess.run(
        [str(VALIDATOR_PATH), "--nonce=campaign-001", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    assert json.loads(completed.stdout)["probe"] == "vulkan-application"

compute_source = (ROOT / "guest-probes" / "dory-compute-probe.c").read_text()
compute_shader = (ROOT / "guest-probes" / "dory-compute-reduce.comp").read_text()
gl_source = (ROOT / "guest-probes" / "dory-gl-probe.c").read_text()
assert "1024u * 1024u" in compute_source
assert "actual != expected" in compute_source
assert "gl_GlobalInvocationID" in compute_shader
assert "GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA" in gl_source
assert "FRAME:%06u NONCE:" in gl_source
assert all(name in (compute_source + gl_source).lower() for name in ("llvmpipe", "lavapipe"))

print("guest GPU probe contract tests passed")
