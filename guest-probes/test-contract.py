#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "guest-probes" / "validate-result.py"
spec = importlib.util.spec_from_file_location("dory_probe_validator", VALIDATOR_PATH)
assert spec is not None and spec.loader is not None
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def visual_challenge(nonce: str, frame_count: int) -> dict[str, object]:
    value = validator.PIXEL_ORACLE.expected_challenge_record(nonce, frame_count)
    return dict(value)


def sample(probe: str) -> dict[str, object]:
    record = {
        "schema": "dev.dory.gpu-probe",
        "version": 1,
        "probe": probe,
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "venus",
        "apiVersion": "1.3.0",
        "extensionsUsed": (
            ["GL_ARB_vertex_array_object"] if probe == "gl"
            else [] if probe == "compute"
            else ["VK_KHR_swapchain"]
        ),
        "resultHash": "fnv1a64:0123456789abcdef",
        "frameCount": 1,
        "nonce": "campaign-001",
        "timings": {"totalMilliseconds": 3.25},
    }
    if probe in {"vulkan-application", "vulkan-compositor", "gl"}:
        record["visualChallenge"] = visual_challenge("campaign-001", 1)
        record["extent"] = {"width": 960, "height": 600}
        record["presentedHoldMilliseconds"] = 1_000
    if probe in {"vulkan-application", "vulkan-compositor"}:
        prefix = (
            b"campaign-001",
            record["deviceName"].encode(),
            record["driver"].encode(),
        )
        dimensions = struct.pack("<II", 960, 600)
        if probe == "vulkan-application":
            record["colorAtlasFormat"] = "rgba8-unorm"
            record["surfaceFormat"] = "bgra8-unorm"
            record["offscreenExtent"] = validator.OFFSCREEN_APPLICATION_EXTENT
            record["offscreenReadbackEncoding"] = validator.VISUAL_READBACK_ENCODING
            record["offscreenReadbackRGBHex"] = (
                validator.PIXEL_ORACLE.expected_readback_rgb("campaign-001", 1).hex()
            )
            record["offscreenBackgroundRGBAHex"] = "081830ff"
            record["offscreenReadbackMemoryCoherency"] = "coherent"
            record["presentedReadbackEncoding"] = validator.VISUAL_READBACK_ENCODING
            record["presentedReadbackRGBHex"] = (
                validator.PIXEL_ORACLE.expected_readback_rgb("campaign-001", 1).hex()
            )
            record["presentedBackgroundRGBAHex"] = "081830ff"
            record["presentedReadbackMemoryCoherency"] = "coherent"
            record["resultHash"] = validator.fnv1a64(prefix + (
                struct.pack("<I", validator.VULKAN_ATLAS_FORMATS["rgba8-unorm"]),
                dimensions,
            ))
        else:
            record["format"] = "xrgb8888/bgra8-unorm"
            record["readbackMemoryCoherency"] = "noncoherent"
            record["scanoutBackgroundRGBAHex"] = "0040bfff"
            record["visualReadbackEncoding"] = validator.VISUAL_READBACK_ENCODING
            record["visualReadbackRGBHex"] = (
                validator.PIXEL_ORACLE.expected_readback_rgb("campaign-001", 1).hex()
            )
            record["resultHash"] = validator.fnv1a64(prefix + (
                record["format"].encode(), dimensions,
            ))
    if probe == "gl":
        record["visualReadbackEncoding"] = validator.VISUAL_READBACK_ENCODING
        record["visualReadbackRGBHex"] = (
            validator.PIXEL_ORACLE.expected_readback_rgb("campaign-001", 1).hex()
        )
    if probe == "compute":
        reduction, result_hash = validator.expected_compute_result("campaign-001")
        record["elementCount"] = 1024 * 1024
        record["reduction"] = reduction
        record["resultHash"] = result_hash
        record["memoryCoherency"] = {"input": "noncoherent", "output": "coherent"}
    return record


for probe in validator.PROBES:
    assert validator.validate(sample(probe), "campaign-001")["probe"] == probe

for probe, field in (
    ("vulkan-application", "colorAtlasFormat"),
    ("vulkan-application", "surfaceFormat"),
    ("vulkan-compositor", "format"),
):
    for malformed in ([], {}):
        record = sample(probe)
        record[field] = malformed
        try:
            validator.validate(record, "campaign-001")
        except ValueError as error:
            assert "format is unsupported" in str(error)
        else:
            raise AssertionError(f"validator admitted malformed {probe} {field}")

boolean_version = sample("vulkan-application")
boolean_version["version"] = True
try:
    validator.validate(boolean_version, "campaign-001")
except ValueError as error:
    assert "schema/version" in str(error)
else:
    raise AssertionError("validator admitted a Boolean probe schema version")

for renderer in ("llvmpipe", "lavapipe", "softpipe", "swrast", "Software Rasterizer"):
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

stale_visual = sample("gl")
stale_visual["visualChallenge"] = visual_challenge("old-campaign", 1)
try:
    validator.validate(stale_visual, "campaign-001")
except ValueError:
    pass
else:
    raise AssertionError("validator admitted a stale visual challenge")

for wrong_readback in (
    "00" * 360,
    validator.PIXEL_ORACLE.expected_readback_rgb("old-campaign", 1).hex(),
):
    corrupt_gl = sample("gl")
    corrupt_gl["visualReadbackRGBHex"] = wrong_readback
    try:
        validator.validate(corrupt_gl, "campaign-001")
    except ValueError as error:
        assert "independent challenge color oracle" in str(error)
    else:
        raise AssertionError("validator admitted a false GL GPU readback")

for field, wrong in (
    ("reduction", 0),
    ("resultHash", "fnv1a64:0123456789abcdef"),
    ("elementCount", 1),
):
    corrupt_compute = sample("compute")
    corrupt_compute[field] = wrong
    try:
        validator.validate(corrupt_compute, "campaign-001")
    except ValueError as error:
        assert "independent v1 reduction oracle" in str(error)
    else:
        raise AssertionError(f"validator admitted a false compute {field}")

for wrong in (
    {"input": "cached", "output": "coherent"},
    {"input": "coherent"},
    {"input": [], "output": "coherent"},
):
    corrupt_compute = sample("compute")
    corrupt_compute["memoryCoherency"] = wrong
    try:
        validator.validate(corrupt_compute, "campaign-001")
    except ValueError as error:
        assert "coherency record is malformed" in str(error)
    else:
        raise AssertionError("validator admitted invalid compute memory properties")

for wrong in ("unknown", []):
    corrupt_compositor = sample("vulkan-compositor")
    corrupt_compositor["readbackMemoryCoherency"] = wrong
    try:
        validator.validate(corrupt_compositor, "campaign-001")
    except ValueError as error:
        assert "readback memory coherency is invalid" in str(error)
    else:
        raise AssertionError("validator admitted invalid compositor memory properties")

for field, wrong in (
    ("visualReadbackRGBHex", "00" * 360),
    ("scanoutBackgroundRGBAHex", "000000ff"),
    ("scanoutBackgroundRGBAHex", "0040bf"),
):
    corrupt_compositor = sample("vulkan-compositor")
    corrupt_compositor[field] = wrong
    try:
        validator.validate(corrupt_compositor, "campaign-001")
    except ValueError as error:
        assert "oracle" in str(error) or "malformed" in str(error)
    else:
        raise AssertionError(f"validator admitted false compositor readback {field}")

for field, wrong in (
    ("offscreenExtent", {"width": 0, "height": 0}),
    ("offscreenReadbackRGBHex", "00" * 360),
    ("offscreenBackgroundRGBAHex", "000000ff"),
    ("offscreenReadbackMemoryCoherency", []),
    ("presentedReadbackRGBHex", "00" * 360),
    ("presentedBackgroundRGBAHex", "000000ff"),
    ("presentedReadbackMemoryCoherency", []),
):
    corrupt_application = sample("vulkan-application")
    corrupt_application[field] = wrong
    try:
        validator.validate(corrupt_application, "campaign-001")
    except ValueError:
        pass
    else:
        raise AssertionError(f"validator admitted false application offscreen readback {field}")

srgb_application = sample("vulkan-application")
srgb_application["surfaceFormat"] = "bgra8-srgb"
raw_samples = validator.PIXEL_ORACLE.expected_readback_rgb("campaign-001", 1)
srgb_application["presentedReadbackRGBHex"] = bytes(
    channel for index in range(0, len(raw_samples), 3)
    for channel in validator.PIXEL_ORACLE._srgb_color(tuple(raw_samples[index:index + 3]))
).hex()
srgb_application["presentedBackgroundRGBAHex"] = bytes((
    *validator.PIXEL_ORACLE._srgb_color((8, 24, 48)), 255
)).hex()
validator.validate(srgb_application, "campaign-001")

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
    malformed = sample("vulkan-application")
    malformed["surfaceFormat"] = []
    path.write_text(json.dumps(malformed), encoding="utf-8")
    rejected = subprocess.run(
        [str(VALIDATOR_PATH), "--nonce=campaign-001", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert rejected.returncode == 1
    assert "surface format is unsupported" in rejected.stderr
    assert "Traceback" not in rejected.stderr

compute_source = (ROOT / "guest-probes" / "dory-compute-probe.c").read_text()
compute_shader = (ROOT / "guest-probes" / "dory-compute-reduce.comp").read_text()
gl_source = (ROOT / "guest-probes" / "dory-gl-probe.c").read_text()
assert "1024u * 1024u" in compute_source
assert "actual != expected" in compute_source
assert "vkFlushMappedMemoryRanges" in compute_source
assert "vkInvalidateMappedMemoryRanges" in compute_source
assert "--memory=noncoherent" in compute_source
assert "--readback-memory=noncoherent" in (
    ROOT / "guest-probes" / "dory-vulkan-compositor-probe.c"
).read_text()
assert "gl_GlobalInvocationID" in compute_shader
assert "GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA" in gl_source
assert "FRAME:%06u NONCE:" in gl_source
assert "draw_visual_challenge" in gl_source
assert all(name in (compute_source + gl_source).lower() for name in ("llvmpipe", "lavapipe"))

# Compile the guest-side marker writer independently and compare its bytes with the
# host oracle. A stale marker at the same path must also fail O_EXCL publication.
with tempfile.TemporaryDirectory() as directory:
    marker_binary = pathlib.Path(directory) / "ready-marker"
    marker_path = pathlib.Path(directory) / "presented"
    subprocess.run(
        ["cc", "-std=c11", "-D_GNU_SOURCE", "-I", str(ROOT / "guest-probes"),
         "-x", "c", "-", "-o", str(marker_binary)],
        input=(
            '#include "dory-visual-challenge.h"\n'
            'int main(int argc, char **argv) {\n'
            '  if (argc != 2) return 2;\n'
            '  return dory_visual_publish_presented(argv[1], "campaign-001", 180) != 0;\n'
            '}\n'
        ),
        check=True, capture_output=True, text=True,
    )
    subprocess.run([str(marker_binary), str(marker_path)], check=True)
    expected_hash = validator.PIXEL_ORACLE.fnv1a64("campaign-001", 180)
    assert marker_path.read_text(encoding="ascii") == (
        f"dory-visual-presented:fnv1a64:{expected_hash:016x}:180\n"
    )
    assert subprocess.run([str(marker_binary), str(marker_path)], check=False).returncode != 0
    assert marker_path.read_text(encoding="ascii") == (
        f"dory-visual-presented:fnv1a64:{expected_hash:016x}:180\n"
    )
    assert not list(pathlib.Path(directory).glob("presented.tmp.*"))

subprocess.run(
    [sys.executable, str(ROOT / "guest-probes" / "test-displayed-pixel.py")],
    check=True,
)

print("guest GPU probe contract tests passed")
