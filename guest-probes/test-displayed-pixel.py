#!/usr/bin/env python3

from __future__ import annotations

import binascii
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = ROOT / "guest-probes" / "verify-displayed-pixel.py"
SPEC = importlib.util.spec_from_file_location("dory_displayed_pixel_verifier", VERIFIER_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)
ORACLE = VERIFIER.PIXEL_ORACLE


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload)) + kind + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFF_FFFF)
    )


def expect_png_failure(path: Path, reason: str) -> None:
    try:
        ORACLE.decode_png(path)
    except ORACLE.PixelOracleError as error:
        assert reason in str(error), str(error)
    else:
        raise AssertionError(f"PNG parser admitted {path.name}")


def red_corner_field(columns: int, rows: int) -> tuple[object, dict[str, object]]:
    """Many plausible top-left corners, with no complete challenge grid."""
    width, height = columns * 5, rows * 5
    pixels = bytearray(bytes((17, 24, 39, 255)) * width * height)
    red = bytes((*ORACLE.COLORS["topLeft"], 255))
    for row in range(rows):
        for column in range(columns):
            for local_y in range(3):
                for local_x in range(3):
                    offset = ((row * 5 + local_y) * width + column * 5 + local_x) * 4
                    pixels[offset : offset + 4] = red
    image = ORACLE.PNGImage(width, height, bytes(pixels))
    viewport = {
        "coordinateSpace": "capture-pixels-top-left",
        "x": 0, "y": 0, "width": width, "height": height,
        "sourceWidth": width, "sourceHeight": height,
        "backingScaleFactor": 1.0, "colorSpace": "sRGB",
    }
    return image, viewport


def expect_oracle_failure(image: object, viewport: dict[str, object], reason: str) -> None:
    try:
        ORACLE.verify_image_pixels(image, viewport, "campaign-001", 1)
    except ORACLE.PixelOracleError as error:
        assert reason in str(error), str(error)
    else:
        raise AssertionError(f"pixel oracle admitted an adversarial capture: {reason}")


def write_challenge_png(
    path: Path,
    nonce: str,
    frame_marker: int,
    *,
    blank: bool = False,
    swap_red_blue: bool = False,
    textured: bool = True,
    origin_x: int = 48,
    origin_y: int = 64,
    cell_size: int = 12,
    cell_height: int | None = None,
    background: tuple[int, int, int] = (17, 24, 39),
    srgb: bool = False,
    marker_alpha: int = 255,
    mirror_marker: bool = False,
    flip_marker: bool = False,
) -> tuple[int, int]:
    width, height = 1280, 800
    pixels = bytearray(bytes((*background, 255)) * width * height)
    if not blank:
        if textured:
            # Simulate the probe's two alpha-blended checker colors in its central
            # textured quad; a copied challenge marker over a flat image must fail.
            window_x, window_y = origin_x - 24, origin_y - 24
            for y in range(window_y + 210, window_y + 390):
                for x in range(window_x + 350, window_x + 610):
                    color = (
                        (176, 67, 154, 255)
                        if ((x // 32) ^ (y // 32)) & 1
                        else (27, 115, 150, 255)
                    )
                    offset = (y * width + x) * 4
                    pixels[offset : offset + 4] = bytes(color)
        challenge_hash = ORACLE.fnv1a64(nonce, frame_marker)
        for row in range(ORACLE.GRID_ROWS):
            for column in range(ORACLE.GRID_COLUMNS):
                if column == 0 and row == 0:
                    name = "topLeft"
                elif column == ORACLE.GRID_COLUMNS - 1 and row == 0:
                    name = "topRight"
                elif column == 0 and row == ORACLE.GRID_ROWS - 1:
                    name = "bottomLeft"
                elif column == ORACLE.GRID_COLUMNS - 1 and row == ORACLE.GRID_ROWS - 1:
                    name = "bottomRight"
                elif (
                    column == 0 or row == 0
                    or column == ORACLE.GRID_COLUMNS - 1
                    or row == ORACLE.GRID_ROWS - 1
                ):
                    name = "border"
                else:
                    bit_index = (row - 1) * 10 + (column - 1)
                    bit = (
                        (challenge_hash >> bit_index) & 1
                        if bit_index < 64
                        else (frame_marker >> (bit_index - 64)) & 1
                    )
                    name = "one" if bit else "zero"
                red, green, blue = ORACLE.COLORS[name]
                if srgb:
                    red, green, blue = ORACLE._srgb_color((red, green, blue))
                if swap_red_blue:
                    red, blue = blue, red
                row_height = cell_height if cell_height is not None else cell_size
                output_row = ORACLE.GRID_ROWS - 1 - row if flip_marker else row
                output_column = (
                    ORACLE.GRID_COLUMNS - 1 - column if mirror_marker else column
                )
                for y in range(
                    origin_y + output_row * row_height,
                    origin_y + (output_row + 1) * row_height,
                ):
                    for x in range(
                        origin_x + output_column * cell_size,
                        origin_x + (output_column + 1) * cell_size,
                    ):
                        offset = (y * width + x) * 4
                        pixels[offset : offset + 4] = bytes((red, green, blue, marker_alpha))
    scanlines = b"".join(
        b"\x00" + pixels[row * width * 4 : (row + 1) * width * 4]
        for row in range(height)
    )
    encoded = (
        ORACLE.PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(scanlines, 9))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(encoded)
    return width, height



def test_png_filter_rows_retain_exact_rgba_samples():
    # Hand-encoded rows exercise None, Sub, Up, Average and Paeth in one image.
    # Each pixel carries nonopaque alpha, so a bulk copy cannot silently normalize it.
    raw = bytes([
        0, 10, 20, 30, 40, 50, 60, 70, 80,
        1, 11, 22, 33, 44, 44, 44, 44, 44,
        2, 1, 2, 3, 4, 5, 6, 7, 8,
        3, 8, 16, 24, 32, 33, 34, 35, 36,
        4, 2, 4, 6, 8, 10, 12, 14, 16,
    ])
    expected = bytes([
        10, 20, 30, 40, 50, 60, 70, 80,
        11, 22, 33, 44, 55, 66, 77, 88,
        12, 24, 36, 48, 60, 72, 84, 96,
        14, 28, 42, 56, 70, 84, 98, 112,
        16, 32, 48, 64, 80, 96, 112, 128,
    ])
    payload = (ORACLE.PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 5, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw))
        + png_chunk(b"IEND", b""))
    image = ORACLE.decode_png_bytes(payload)
    assert (image.width, image.height, image.rgba) == (2, 5, expected)


def refresh_chain(root: Path) -> None:
    capture = json.loads((root / "window-capture.json").read_text(encoding="utf-8"))
    capture["framebufferSHA256"] = digest(root / "framebuffer.png")
    capture["windowReceiptSHA256"] = digest(root / "display-capture-frame.json")
    write_json(root / "window-capture.json", capture)
    correlation = json.loads((root / "graphics-correlation.json").read_text(encoding="utf-8"))
    correlation["framebufferSHA256"] = capture["framebufferSHA256"]
    correlation["graphicsTraceSHA256"] = digest(root / "graphics-trace.ndjson")
    write_json(root / "graphics-correlation.json", correlation)
    evidence = json.loads((root / "gpu-display-evidence.json").read_text(encoding="utf-8"))
    evidence.update({
        "probeSHA256": digest(root / "gpu-probe.json"),
        "probeBuildReceiptSHA256": digest(root / "gpu-probe-build-receipt.txt"),
        "probeReadyTransportSHA256": digest(root / "gpu-probe-ready-transport.json"),
        "framebufferSHA256": capture["framebufferSHA256"],
        "windowReceiptSHA256": capture["windowReceiptSHA256"],
        "captureReceiptSHA256": digest(root / "window-capture.json"),
        "captureReleaseSHA256": digest(root / "display-capture-frame.released"),
        "graphicsCorrelationSHA256": digest(root / "graphics-correlation.json"),
        "graphicsTraceSHA256": digest(root / "graphics-trace.ndjson"),
        "pixelOracleSHA256": digest(root / "pixel-oracle.json"),
    })
    write_json(root / "gpu-display-evidence.json", evidence)


def test_vulkan_result_hash_replay() -> None:
    validator = VERIFIER.PROBE_VALIDATOR

    def digest_parts(*parts: bytes) -> str:
        value = 14695981039346656037
        for part in parts:
            for byte in part:
                value ^= byte
                value = value * 1099511628211 & 0xFFFF_FFFF_FFFF_FFFF
        return f"fnv1a64:{value:016x}"

    common = {
        "schema": "dev.dory.gpu-probe", "version": 1,
        "deviceName": "Dory Vulkan Device", "driver": "Venus",
        "apiVersion": "1.3.0", "extensionsUsed": [],
        "nonce": "campaign-001", "timings": {"totalMilliseconds": 1.0},
    }
    prefix = tuple(common[key].encode("utf-8") for key in (
        "nonce", "deviceName", "driver",
    ))
    application = {
        **common, "probe": "vulkan-application", "frameCount": 0,
        "extent": {"width": 0, "height": 0},
        "surfaceFormat": "none", "colorAtlasFormat": "bgra8-unorm",
        "offscreenExtent": validator.OFFSCREEN_APPLICATION_EXTENT,
        "offscreenReadbackEncoding": validator.VISUAL_READBACK_ENCODING,
        "offscreenReadbackRGBHex": ORACLE.expected_readback_rgb(common["nonce"], 1).hex(),
        "offscreenBackgroundRGBAHex": "081830ff",
        "offscreenReadbackMemoryCoherency": "coherent",
    }
    application["resultHash"] = digest_parts(
        *prefix, struct.pack("<I", 44), struct.pack("<II", 0, 0),
    )
    validator.validate(application, common["nonce"])
    for change in ({"resultHash": "fnv1a64:0123456789abcdef"},
                   {"colorAtlasFormat": "rgba8-unorm"},
                   {"extent": {"width": 1, "height": 0}},
                   {"offscreenReadbackRGBHex": "00" * 360},
                   {"offscreenBackgroundRGBAHex": "000000ff"}):
        try:
            validator.validate({**application, **change}, common["nonce"])
        except ValueError:
            pass
        else:
            raise AssertionError(f"Vulkan application admitted altered metadata: {change}")

    compositor = {
        **common, "probe": "vulkan-compositor", "frameCount": 1,
        "extent": {"width": 1280, "height": 800},
        "format": "xrgb8888/bgra8-unorm", "presentedHoldMilliseconds": 5000,
        "visualChallenge": ORACLE.expected_challenge_record(common["nonce"], 1),
        "scanoutBackgroundRGBAHex": "0040bfff",
        "visualReadbackEncoding": validator.VISUAL_READBACK_ENCODING,
        "visualReadbackRGBHex": ORACLE.expected_readback_rgb(common["nonce"], 1).hex(),
    }
    compositor["resultHash"] = digest_parts(
        *prefix, compositor["format"].encode("utf-8"),
        struct.pack("<II", 1280, 800),
    )
    validator.validate(compositor, common["nonce"])
    for change in ({"resultHash": "fnv1a64:0123456789abcdef"},
                   {"format": "xbgr8888/rgba8-unorm"},
                   {"extent": {"width": 800, "height": 1280}},
                   {"visualReadbackRGBHex": "00" * 360},
                   {"scanoutBackgroundRGBAHex": "000000ff"}):
        try:
            validator.validate({**compositor, **change}, common["nonce"])
        except ValueError:
            pass
        else:
            raise AssertionError(f"Vulkan compositor admitted altered metadata: {change}")


def build_fixture(
    root: Path, *, nonce: str = "campaign-001", machine_id: str = "ubuntu",
    operation_id: str = "operation-1", mach_service: str | None = None,
    worker_generation: int = 7, frame_sequence: int = 44, display_generation: int = 8,
    ready_file: str = "/run/user/1000/dory-campaign-001.presented",
) -> None:
    frame_count = 180
    visual_challenge = ORACLE.expected_challenge_record(nonce, frame_count)
    probe = {
        "schema": "dev.dory.gpu-probe",
        "version": 1,
        "probe": "gl",
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "zink",
        "apiVersion": "4.6",
        "extensionsUsed": ["GL_ARB_vertex_array_object"],
        "resultHash": "fnv1a64:0123456789abcdef",
        "frameCount": frame_count,
        "nonce": nonce,
        "presentedHoldMilliseconds": 10000,
        "presentedReadyFile": ready_file,
        "visualChallenge": visual_challenge,
        "visualReadbackEncoding": VERIFIER.PROBE_VALIDATOR.VISUAL_READBACK_ENCODING,
        "visualReadbackRGBHex": ORACLE.expected_readback_rgb(nonce, frame_count).hex(),
        "extent": {"width": 960, "height": 600},
        "timings": {"totalMilliseconds": 3000.0},
    }
    write_json(root / "gpu-probe.json", probe)
    write_json(root / "gpu-probe-ready-transport.json", {
        "schema": "dev.dory.machine.exec",
        "version": 1,
        "machine": machine_id,
        "argv": ["cat", probe["presentedReadyFile"]],
        "exitCode": 0,
        "timedOut": False,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "stdout": f"dory-visual-presented:{visual_challenge['payloadHash']}:{frame_count}\n",
        "stderr": "",
    })
    build_receipt = {
        "schema": "dev.dory.guest-probe-build",
        "version": "2",
        "architecture": "aarch64",
        "kernel": "6.13-test",
        "compiler": "gcc test",
        "compositorSourceCommit": "stock-distro-session",
        "visualChallengeEncoding": "fnv1a64-frame16-grid12x10",
        "output": "/guest/probes",
    }
    build_receipt.update({
        key: digest(ROOT / "guest-probes" / name)
        for key, name in VERIFIER.BUILD_RECEIPT.SOURCE_FILES.items()
    })
    build_receipt.update({
        key: hashlib.sha256(key.encode("ascii")).hexdigest()
        for key in VERIFIER.BUILD_RECEIPT.BINARY_FILES
    })
    (root / "gpu-probe-build-receipt.txt").write_text(
        "".join(f"{key}={value}\n" for key, value in build_receipt.items()),
        encoding="utf-8",
    )
    (root / "display-capture-frame.released").write_bytes(
        b"capture-next-metal-completed-frame\n"
    )
    capture_width, capture_height = write_challenge_png(
        root / "framebuffer.png", nonce, frame_count
    )
    viewport = {
        "coordinateSpace": "capture-pixels-top-left",
        "x": 0,
        "y": 0,
        "width": capture_width,
        "height": capture_height,
        "sourceX": 0,
        "sourceY": 0,
        "sourceWidth": 1280,
        "sourceHeight": 800,
        "backingScaleFactor": 1.0,
        "colorSpace": "sRGB",
    }
    frame = {
        "kind": "dev.dory.display-qualification-window",
        "schemaVersion": 2,
        "machineID": machine_id,
        "operationID": operation_id,
        "scanoutID": 0,
        "frameSequence": frame_sequence,
        "displayResourceGeneration": display_generation,
        "metalCommandBufferCompletionID": 19,
        "windowNumber": 73,
        "windowTitle": f"Dory — {machine_id} — Display 1",
        "transport": "sharedTexture",
        "framePollingHeldForCapture": True,
        "guestViewport": viewport,
    }
    write_json(root / "display-capture-frame.json", frame)
    capture = {
        "kind": "dev.dory.machine-window-capture",
        "schemaVersion": 2,
        "status": "PASS",
        **({"machServiceName": mach_service} if mach_service is not None else {}),
        **{key: frame[key] for key in (
            "machineID", "operationID", "frameSequence", "displayResourceGeneration",
            "metalCommandBufferCompletionID", "windowNumber", "windowTitle", "transport",
            "guestViewport", "framePollingHeldForCapture",
        )},
        "captureWidth": capture_width,
        "captureHeight": capture_height,
        "framebufferSHA256": digest(root / "framebuffer.png"),
        "windowReceiptSHA256": digest(root / "display-capture-frame.json"),
    }
    write_json(root / "window-capture.json", capture)
    trace_identity = {
        "context": {
            "machineID": machine_id, "operationID": operation_id, "workerGeneration": worker_generation,
        },
        "scanoutID": 0, "resourceID": 52, "displayResourceGeneration": display_generation,
        "rendererResourceGeneration": 5, "deviceGeneration": 2,
        "frameSequence": 31, "width": 1280, "height": 800,
        "stride": 5120, "format": 1,
    }
    trace_events = [
        {**trace_identity, "sequence": 89, "monotonicNanoseconds": 1_000,
         "stage": "scanoutPublished", "scanoutID": None},
        {**trace_identity, "sequence": 90, "monotonicNanoseconds": 2_000,
         "stage": "hostSubmissionAccepted"},
        {**trace_identity, "sequence": 91, "monotonicNanoseconds": 3_000,
         "stage": "metalPresentationCompleted", "metalCommandBufferCompletionID": 19},
    ]
    (root / "graphics-trace.ndjson").write_text(
        "".join(json.dumps(event) + "\n" for event in trace_events), encoding="utf-8")
    chain = VERIFIER.TRACE_CHAIN.verify(trace_events, frame)
    correlation = {
        "kind": "dev.dory.display-graphics-correlation",
        "schemaVersion": 3,
        "status": "PASS",
        **{key: capture[key] for key in (
            "machineID", "operationID", "frameSequence", "displayResourceGeneration",
            "metalCommandBufferCompletionID", "framebufferSHA256",
        )},
        **chain,
        "graphicsTraceSHA256": digest(root / "graphics-trace.ndjson"),
    }
    write_json(root / "graphics-correlation.json", correlation)
    oracle = ORACLE.verify_pixels(
        root / "framebuffer.png", viewport, nonce, frame_count,
        probe_kind="gl", probe_extent=probe["extent"],
    )
    write_json(root / "pixel-oracle.json", oracle)
    evidence = {
        "kind": "dev.dory.gpu-displayed-pixel-evidence",
        "schemaVersion": 3,
        "status": "PASS",
        "machineID": machine_id,
        "operationID": operation_id,
        "frameSequence": frame_sequence,
        "probe": "gl",
        "probeNonce": nonce,
        "probeResultHash": "fnv1a64:0123456789abcdef",
        "deviceName": "Virtio-GPU Venus (Apple M4)",
        "driver": "zink",
        "frameCount": frame_count,
        "visualChallenge": visual_challenge,
        "probeSHA256": digest(root / "gpu-probe.json"),
        "probeBuildReceiptSHA256": digest(root / "gpu-probe-build-receipt.txt"),
        "probePresentedReadyFile": probe["presentedReadyFile"],
        "probeReadyTransportSHA256": digest(root / "gpu-probe-ready-transport.json"),
        "framebufferSHA256": digest(root / "framebuffer.png"),
        "windowReceiptSHA256": digest(root / "display-capture-frame.json"),
        "captureReceiptSHA256": digest(root / "window-capture.json"),
        "captureReleaseSHA256": digest(root / "display-capture-frame.released"),
        "graphicsTraceSHA256": digest(root / "graphics-trace.ndjson"),
        "graphicsCorrelationSHA256": digest(root / "graphics-correlation.json"),
        "pixelOracleSHA256": digest(root / "pixel-oracle.json"),
        "displayResourceGeneration": display_generation,
        "metalCommandBufferCompletionID": 19,
        **chain,
    }
    write_json(root / "gpu-display-evidence.json", evidence)


test_vulkan_result_hash_replay()

with tempfile.TemporaryDirectory(prefix="dory-gpu-display-evidence-") as directory:
    root = Path(directory)
    tiny_header = png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
    tiny_image = zlib.compress(b"\x00\xff\x00\x00\xff")
    png_end = png_chunk(b"IEND", b"")
    oversized = root / "oversized.png"
    with oversized.open("wb") as destination:
        destination.truncate(ORACLE.MAX_PNG_BYTES + 1)
    expect_png_failure(oversized, "encoded byte count")
    linked = root / "linked.png"
    linked.symlink_to(oversized)
    expect_png_failure(linked, "unreadable")
    bad_first_chunk = root / "bad-first-chunk.png"
    bad_first_chunk.write_bytes(
        ORACLE.PNG_SIGNATURE + png_chunk(b"tEXt", b"note\x00before-header")
        + tiny_header + png_chunk(b"IDAT", tiny_image) + png_end
    )
    expect_png_failure(bad_first_chunk, "IHDR must be the first")
    interrupted_idat = root / "interrupted-idat.png"
    midpoint = len(tiny_image) // 2
    interrupted_idat.write_bytes(
        ORACLE.PNG_SIGNATURE + tiny_header
        + png_chunk(b"IDAT", tiny_image[:midpoint])
        + png_chunk(b"tEXt", b"note\x00between-idat")
        + png_chunk(b"IDAT", tiny_image[midpoint:]) + png_end
    )
    expect_png_failure(interrupted_idat, "IDAT ordering")
    false_transparency = root / "false-transparency.png"
    false_transparency.write_bytes(
        ORACLE.PNG_SIGNATURE + tiny_header + png_chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00")
        + png_chunk(b"IDAT", tiny_image) + png_end
    )
    expect_png_failure(false_transparency, "transparency metadata")
    oversized_decoded = root / "oversized-decoded.png"
    oversized_decoded.write_bytes(
        ORACLE.PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 16_384, 16_384, 8, 0, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"\x00\xff")) + png_end
    )
    expect_png_failure(oversized_decoded, "pixel count exceeds")
    excessive_pixels = root / "excessive-pixels.png"
    excessive_pixels.write_bytes(
        ORACLE.PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 16_384, 1_025, 8, 0, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"\x00\xff")) + png_end
    )
    expect_png_failure(excessive_pixels, "pixel count exceeds")

    crowded_image, crowded_viewport = red_corner_field(13, 10)
    expect_oracle_failure(crowded_image, crowded_viewport, "too many red corner candidates")
    decoy_image, decoy_viewport = red_corner_field(11, 2)
    expect_oracle_failure(decoy_image, decoy_viewport, "search budget")
    large_side = 129
    red_pixel = bytes((*ORACLE.COLORS["topLeft"], 255))
    large_red_image = ORACLE.PNGImage(
        large_side, large_side, red_pixel * large_side * large_side
    )
    large_red_viewport = dict(crowded_viewport)
    large_red_viewport.update({
        "width": large_side, "height": large_side,
        "sourceWidth": large_side, "sourceHeight": large_side,
    })
    expect_oracle_failure(large_red_image, large_red_viewport, "oversized red corner")

    build_fixture(root)
    verified = VERIFIER.verify(root, "campaign-001")
    assert verified["status"] == "evidence-verified"
    assert verified["probeSHA256"] == digest(root / "gpu-probe.json")
    assert verified["metalCommandBufferCompletionID"] == 19
    original_object_from = VERIFIER.object_from
    original_probe_bytes = (root / "gpu-probe.json").read_bytes()
    def mutate_after_snapshot(payload: bytes, label: str) -> dict[str, object]:
        if label == "GPU probe":
            (root / "gpu-probe.json").write_bytes(b"replaced-after-snapshot")
        return original_object_from(payload, label)
    VERIFIER.object_from = mutate_after_snapshot
    try:
        # The verifier may not parse one version and hash a later replacement of that file.
        assert VERIFIER.verify(root, "campaign-001")["status"] == "evidence-verified"
    finally:
        VERIFIER.object_from = original_object_from
        (root / "gpu-probe.json").write_bytes(original_probe_bytes)

    probe_path = root / "gpu-probe.json"
    original_probe_text = probe_path.read_text(encoding="utf-8")
    probe_path.write_text(
        original_probe_text.rstrip()[:-1] + ',"nonce":"campaign-001"}\n',
        encoding="utf-8",
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "duplicate nonce" in str(error)
    else:
        raise AssertionError("verifier admitted ambiguous duplicate JSON fields")
    probe_path.write_text(original_probe_text, encoding="utf-8")
    refresh_chain(root)

    ready_path = root / "gpu-probe-ready-transport.json"
    original_ready = ready_path.read_text(encoding="utf-8")
    ready = json.loads(original_ready)
    ready["stdout"] = "dory-probe-started\n"
    write_json(ready_path, ready)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "presented marker" in str(error)
    else:
        raise AssertionError("verifier admitted a start marker as presented-frame proof")
    ready_path.write_text(original_ready, encoding="utf-8")
    refresh_chain(root)

    ready = json.loads(original_ready)
    stale = ORACLE.expected_challenge_record("campaign-001", 179)
    ready["stdout"] = f"dory-visual-presented:{stale['payloadHash']}:179\n"
    write_json(ready_path, ready)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "presented marker" in str(error)
    else:
        raise AssertionError("verifier admitted a consistently rehashed stale ready marker")
    ready_path.write_text(original_ready, encoding="utf-8")
    refresh_chain(root)

    trace_path = root / "graphics-trace.ndjson"
    original_trace_bytes = trace_path.read_bytes()
    with trace_path.open("wb") as destination:
        destination.truncate(VERIFIER.MAX_CAPTURE_OR_TRACE_BYTES + 1)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "exceeds the supported byte bound" in str(error)
    else:
        raise AssertionError("verifier admitted an oversized graphics trace")
    trace_path.write_bytes(original_trace_bytes)

    VERIFIER.BUILD_RECEIPT.validate(
        root / "gpu-probe-build-receipt.txt",
        source_directory=ROOT / "guest-probes",
        architecture="aarch64",
    )

    build_path = root / "gpu-probe-build-receipt.txt"
    original_build = build_path.read_text(encoding="utf-8")
    build_path.write_text(
        original_build.replace(
            "glProbeSourceSHA256=" + digest(ROOT / "guest-probes" / "dory-gl-probe.c"),
            "glProbeSourceSHA256=" + "0" * 64,
        ),
        encoding="utf-8",
    )
    try:
        VERIFIER.BUILD_RECEIPT.validate(
            build_path, source_directory=ROOT / "guest-probes"
        )
    except VERIFIER.BUILD_RECEIPT.BuildReceiptError as error:
        assert "glProbeSourceSHA256" in str(error)
    else:
        raise AssertionError("build receipt admitted a mismatched probe source hash")
    build_path.write_text(original_build, encoding="utf-8")

    invalid_binary = original_build.replace(
        "glProbeBinarySHA256=" + hashlib.sha256(b"glProbeBinarySHA256").hexdigest(),
        "glProbeBinarySHA256=" + "0" * 64,
    )
    build_path.write_text(invalid_binary, encoding="utf-8")
    try:
        VERIFIER.BUILD_RECEIPT.validate(
            build_path, source_directory=ROOT / "guest-probes"
        )
    except VERIFIER.BUILD_RECEIPT.BuildReceiptError as error:
        assert "unset binary digest" in str(error)
    else:
        raise AssertionError("build receipt admitted an unset probe binary digest")
    build_path.write_text(original_build, encoding="utf-8")

    # Rehash the entire evidence chain around false GPU readback samples. A valid window
    # marker cannot cover a guest readback that did not contain the same challenge.
    probe_path = root / "gpu-probe.json"
    original_probe = probe_path.read_text(encoding="utf-8")
    probe = json.loads(original_probe)
    probe["visualReadbackRGBHex"] = "00" * 360
    write_json(probe_path, probe)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "independent challenge color oracle" in str(error)
    else:
        raise AssertionError("verifier admitted consistently rehashed false GPU readback")
    probe_path.write_text(original_probe, encoding="utf-8")
    refresh_chain(root)

    # A marker cannot borrow pixels from the window chrome or another view outside the
    # recorded guest viewport, even when its top-left corner lies inside that viewport.
    clipped_viewport = {
        "coordinateSpace": "capture-pixels-top-left",
        "x": 48,
        "y": 64,
        "width": 80,
        "height": 80,
        "sourceX": 0,
        "sourceY": 0,
        "sourceWidth": 80,
        "sourceHeight": 80,
        "backingScaleFactor": 1.0,
        "colorSpace": "sRGB",
    }
    try:
        ORACLE.verify_pixels(
            root / "framebuffer.png", clipped_viewport, "campaign-001", 180
        )
    except ORACLE.PixelOracleError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("oracle admitted a marker extending outside the guest viewport")

    trace_path = root / "graphics-trace.ndjson"
    original_trace = trace_path.read_text(encoding="utf-8")
    trace = [json.loads(line) for line in original_trace.splitlines()]
    trace[-1]["metalCommandBufferCompletionID"] = 20
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in trace), encoding="utf-8")
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "exactly one matching Metal completion" in str(error)
    else:
        raise AssertionError("verifier admitted a mismatched Metal completion")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    # A consistently rehashed second frame with the same app completion ID is ambiguous even
    # when its display resource generation differs from the captured frame.
    trace = [json.loads(line) for line in original_trace.splitlines()]
    duplicate_completion = {
        **trace[-1], "sequence": 92, "monotonicNanoseconds": 4_000,
        "resourceID": 53, "displayResourceGeneration": 9,
    }
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in (*trace, duplicate_completion)),
        encoding="utf-8",
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "exactly one matching Metal completion" in str(error)
    else:
        raise AssertionError("verifier admitted a reused Metal completion ID")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    trace = [json.loads(line) for line in original_trace.splitlines()]
    for event in trace:
        event["contextID"] = 3
        event["fenceID"] = 77
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in trace), encoding="utf-8"
    )
    refresh_chain(root)
    assert VERIFIER.verify(root, "campaign-001")["status"] == "evidence-verified"
    trace[1]["fenceID"] = 78
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in trace), encoding="utf-8"
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "host submission" in str(error)
    else:
        raise AssertionError("verifier joined a host submission from another producer fence")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    trace = [json.loads(line) for line in original_trace.splitlines()]
    rejected_submission = {
        **trace[1], "stage": "hostSubmissionRejected", "sequence": 92,
        "monotonicNanoseconds": 4_000,
    }
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in (*trace, rejected_submission)),
        encoding="utf-8",
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "host submission" in str(error)
    else:
        raise AssertionError("verifier admitted a rejected submission for the captured frame")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    # Rehash a Metal completion without the same frame's accepted host submission. The image
    # remains correct, but a CPU/firmware blit cannot satisfy the accelerated renderer claim.
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in (
            event for event in (json.loads(line) for line in original_trace.splitlines())
            if event["stage"] != "hostSubmissionAccepted"
        )), encoding="utf-8")
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "host submission" in str(error)
    else:
        raise AssertionError("verifier admitted a Metal completion without a host submission")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    trace = [json.loads(line) for line in original_trace.splitlines()]
    trace[1]["context"]["workerGeneration"] = 99
    trace_path.write_text(
        "".join(json.dumps(event) + "\n" for event in trace), encoding="utf-8")
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "host submission" in str(error)
    else:
        raise AssertionError("verifier admitted a host submission from another worker")
    trace_path.write_text(original_trace, encoding="utf-8")
    refresh_chain(root)

    capture_frame_path = root / "display-capture-frame.json"
    capture_path = root / "window-capture.json"
    original_capture_frame = capture_frame_path.read_text(encoding="utf-8")
    original_capture = capture_path.read_text(encoding="utf-8")
    capture_frame = json.loads(original_capture_frame)
    capture_frame["transport"] = "cpuCopy"
    write_json(capture_frame_path, capture_frame)
    capture = json.loads(original_capture)
    capture["transport"] = "cpuCopy"
    write_json(capture_path, capture)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "not an accelerated renderer lease" in str(error)
    else:
        raise AssertionError("verifier admitted a CPU frame with host Metal completion")
    capture_frame_path.write_text(original_capture_frame, encoding="utf-8")
    capture_path.write_text(original_capture, encoding="utf-8")
    refresh_chain(root)

    capture_frame = json.loads(original_capture_frame)
    capture_frame["guestViewport"]["sourceWidth"] = 1400
    write_json(capture_frame_path, capture_frame)
    capture = json.loads(original_capture)
    capture["guestViewport"]["sourceWidth"] = 1400
    write_json(capture_path, capture)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "source rectangle exceeds the accelerated surface" in str(error)
    else:
        raise AssertionError("verifier admitted a rehashed source crop beyond its GPU surface")
    capture_frame_path.write_text(original_capture_frame, encoding="utf-8")
    capture_path.write_text(original_capture, encoding="utf-8")
    refresh_chain(root)

    evidence_path = root / "gpu-display-evidence.json"
    original_evidence = evidence_path.read_text(encoding="utf-8")
    evidence = json.loads(original_evidence)
    evidence["framebufferSHA256"] = "0" * 64
    write_json(evidence_path, evidence)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "framebufferSHA256" in str(error)
    else:
        raise AssertionError("verifier admitted a mismatched framebuffer digest")
    evidence_path.write_text(original_evidence, encoding="utf-8")

    original_capture_frame = capture_frame_path.read_text(encoding="utf-8")
    capture_frame = json.loads(original_capture_frame)
    capture_frame.pop("framePollingHeldForCapture")
    write_json(capture_frame_path, capture_frame)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "capture-frame receipt schema identity" in str(error)
    else:
        raise AssertionError("verifier admitted a capture without a frame-poll hold")
    capture_frame_path.write_text(original_capture_frame, encoding="utf-8")

    release_path = root / "display-capture-frame.released"
    original_release = release_path.read_bytes()
    release_path.write_bytes(b"released-before-screenshot\n")
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "capture release marker" in str(error)
    else:
        raise AssertionError("verifier admitted an invalid capture release marker")
    release_path.write_bytes(original_release)

    # Rehash every receipt around an intentionally blank PNG. Digest consistency must not be
    # mistaken for semantic pixel correctness.
    write_challenge_png(root / "framebuffer.png", "campaign-001", 180, blank=True)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted a consistently rehashed blank capture")

    # Rehash marker-only content, not merely all-black pixels. The separate
    # alpha-textured GL region is part of the image oracle too.
    write_challenge_png(root / "framebuffer.png", "campaign-001", 180, textured=False)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "alpha-textured checker colors" in str(error)
    else:
        raise AssertionError("verifier admitted a marker pasted over flat content")

    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180, marker_alpha=0
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted transparent challenge pixels")

    write_challenge_png(root / "framebuffer.png", "campaign-001", 180, cell_size=9)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted a correctly colored but undersized marker")

    write_challenge_png(root / "framebuffer.png", "campaign-001", 180, origin_x=600)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted a marker outside the possible GL window")

    # A stale frame with the old nonce is also invalid even when every surrounding digest agrees.
    write_challenge_png(root / "framebuffer.png", "campaign-000", 180)
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted a stale visual challenge")

    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180, swap_red_blue=True
    )
    refresh_chain(root)
    try:
        VERIFIER.verify(root, "campaign-001")
    except VERIFIER.EvidenceError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("verifier admitted a channel-swapped visual challenge")

    for reflection in ("mirror_marker", "flip_marker"):
        write_challenge_png(
            root / "framebuffer.png", "campaign-001", 180,
            **{reflection: True},
        )
        refresh_chain(root)
        try:
            VERIFIER.verify(root, "campaign-001")
        except VERIFIER.EvidenceError as error:
            assert "expected visual challenge" in str(error)
        else:
            raise AssertionError(f"verifier admitted a {reflection} image")

    viewport = json.loads((root / "window-capture.json").read_text(encoding="utf-8"))[
        "guestViewport"
    ]
    application_extent = {"width": 960, "height": 600}
    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, background=(8, 24, 48),
    )
    ORACLE.verify_pixels(
        root / "framebuffer.png", viewport, "campaign-001", 180,
        probe_kind="vulkan-application", probe_extent=application_extent,
        probe_format="bgra8-unorm",
    )
    srgb_background = ORACLE._srgb_color((8, 24, 48))
    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, background=srgb_background, srgb=True,
    )
    ORACLE.verify_pixels(
        root / "framebuffer.png", viewport, "campaign-001", 180,
        probe_kind="vulkan-application", probe_extent=application_extent,
        probe_format="bgra8-srgb",
    )

    compositor_extent = {"width": 1280, "height": 800}
    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, origin_x=24, origin_y=24, cell_size=16,
        background=(0, 64, 191),
    )
    ORACLE.verify_pixels(
        root / "framebuffer.png", viewport, "campaign-001", 180,
        probe_kind="vulkan-compositor", probe_extent=compositor_extent,
    )
    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, origin_x=48, origin_y=24, cell_size=16,
        background=(0, 64, 191),
    )
    try:
        ORACLE.verify_pixels(
            root / "framebuffer.png", viewport, "campaign-001", 180,
            probe_kind="vulkan-compositor", probe_extent=compositor_extent,
        )
    except ORACLE.PixelOracleError as error:
        assert "expected visual challenge" in str(error)
    else:
        raise AssertionError("oracle admitted a compositor marker in the wrong position")

    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, origin_x=24, origin_y=24, cell_size=16,
    )
    try:
        ORACLE.verify_pixels(
            root / "framebuffer.png", viewport, "campaign-001", 180,
            probe_kind="vulkan-compositor", probe_extent=compositor_extent,
        )
    except ORACLE.PixelOracleError as error:
        assert "compositor interior" in str(error)
    else:
        raise AssertionError("oracle admitted a compositor marker over false scanout content")

    scaled_viewport = {**viewport, "width": 640}
    write_challenge_png(
        root / "framebuffer.png", "campaign-001", 180,
        textured=False, origin_x=12, origin_y=24,
        cell_size=8, cell_height=16, background=(0, 64, 191),
    )
    ORACLE.verify_pixels(
        root / "framebuffer.png", scaled_viewport, "campaign-001", 180,
        probe_kind="vulkan-compositor", probe_extent=compositor_extent,
    )

test_png_filter_rows_retain_exact_rgba_samples()

print("GPU displayed-pixel evidence verifier tests passed")
