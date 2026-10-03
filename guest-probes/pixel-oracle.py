#!/usr/bin/env python3
"""Decode a retained PNG and verify Dory's machine-readable visual challenge."""

from __future__ import annotations

import argparse
import binascii
from dataclasses import dataclass
import json
import os
from pathlib import Path
import stat
import struct
import sys
from typing import Any, Iterable
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_BYTES = 64 * 1024 * 1024
MAX_DIMENSION = 16_384
MAX_DECODED_BYTES = 512 * 1024 * 1024
MAX_IMAGE_PIXELS = 16_777_216
MAX_RED_COMPONENT_PIXELS = 128 * 128
MAX_CORNER_COMPONENTS = 128
MAX_CANDIDATE_GEOMETRIES = 32_768
FNV_OFFSET = 14_695_981_039_346_656_037
FNV_PRIME = 1_099_511_628_211
GRID_COLUMNS = 12
GRID_ROWS = 10
ENCODING = "fnv1a64-frame16-grid12x10"

COLORS: dict[str, tuple[int, int, int]] = {
    "border": (6, 10, 20),
    "topLeft": (244, 67, 54),
    "topRight": (76, 175, 80),
    "bottomLeft": (33, 150, 243),
    "bottomRight": (255, 235, 59),
    "zero": (24, 52, 92),
    "one": (64, 224, 196),
}


class PixelOracleError(ValueError):
    pass


def fail(message: str) -> None:
    raise PixelOracleError(message)


@dataclass(frozen=True)
class PNGImage:
    width: int
    height: int
    rgba: bytes

    def pixel(self, x: int, y: int) -> tuple[int, int, int, int]:
        if not (0 <= x < self.width and 0 <= y < self.height):
            fail("pixel coordinate is outside the decoded PNG")
        offset = (y * self.width + x) * 4
        return tuple(self.rgba[offset : offset + 4])  # type: ignore[return-value]


def _paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    diagonal_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= diagonal_distance:
        return left
    if above_distance <= diagonal_distance:
        return above
    return upper_left


def decode_png(path: Path) -> PNGImage:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            source_stat = os.fstat(source.fileno())
            if not stat.S_ISREG(source_stat.st_mode):
                fail("PNG capture is not a regular file")
            if source_stat.st_size > MAX_PNG_BYTES:
                fail("PNG encoded byte count is outside the supported bound")
            payload = source.read(MAX_PNG_BYTES + 1)
    except OSError as error:
        fail(f"PNG is unreadable: {error}")
    return decode_png_bytes(payload)


def decode_png_bytes(payload: bytes) -> PNGImage:
    if not (len(PNG_SIGNATURE) < len(payload) <= MAX_PNG_BYTES):
        fail("PNG encoded byte count is outside the supported bound")
    if not payload.startswith(PNG_SIGNATURE):
        fail("capture is not a PNG")

    cursor = len(PNG_SIGNATURE)
    header: tuple[int, int, int, int, int, int, int] | None = None
    compressed = bytearray()
    saw_idat = False
    closed_idat = False
    saw_end = False
    while cursor < len(payload):
        if len(payload) - cursor < 12:
            fail("PNG contains a truncated chunk header")
        length = struct.unpack(">I", payload[cursor : cursor + 4])[0]
        kind = payload[cursor + 4 : cursor + 8]
        end = cursor + 12 + length
        if end > len(payload):
            fail("PNG contains a truncated chunk payload")
        data = payload[cursor + 8 : cursor + 8 + length]
        expected_crc = struct.unpack(">I", payload[cursor + 8 + length : end])[0]
        actual_crc = binascii.crc32(kind + data) & 0xFFFF_FFFF
        if actual_crc != expected_crc:
            fail(f"PNG {kind.decode('ascii', 'replace')} chunk has an invalid CRC")
        cursor = end
        if header is None and kind != b"IHDR":
            fail("PNG IHDR must be the first chunk")
        if saw_idat and kind != b"IDAT":
            closed_idat = True
        if kind == b"IHDR":
            if header is not None or length != 13:
                fail("PNG has an invalid IHDR")
            header = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT":
            if header is None or saw_end or closed_idat:
                fail("PNG IDAT ordering is invalid")
            saw_idat = True
            compressed.extend(data)
            if len(compressed) > MAX_PNG_BYTES:
                fail("PNG compressed image data exceeds the supported bound")
        elif kind == b"IEND":
            if length != 0 or header is None or saw_end:
                fail("PNG has an invalid IEND")
            saw_end = True
            if cursor != len(payload):
                fail("PNG has trailing bytes after IEND")
            break
        elif kind == b"tRNS":
            # Treating this chunk as an unknown ancillary chunk would silently decode
            # transparent RGB/gray samples as opaque, changing the visual oracle's input.
            fail("PNG transparency metadata is unsupported")
        elif kind and kind[0] & 0x20 == 0 and kind not in {b"IHDR"}:
            fail(f"PNG uses unsupported critical chunk {kind!r}")

    if header is None or not saw_end or not compressed:
        fail("PNG is missing IHDR, IDAT, or IEND")
    width, height, bit_depth, color_type, compression, filtering, interlace = header
    if not (1 <= width <= MAX_DIMENSION and 1 <= height <= MAX_DIMENSION):
        fail("PNG dimensions are outside the supported bound")
    if width * height > MAX_IMAGE_PIXELS:
        fail("PNG pixel count exceeds the supported bound")
    if bit_depth != 8 or color_type not in {0, 2, 4, 6}:
        fail("PNG must use 8-bit grayscale, grayscale-alpha, RGB, or RGBA pixels")
    if compression != 0 or filtering != 0 or interlace != 0:
        fail("PNG compression, filtering, or interlace method is unsupported")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    row_bytes = width * channels
    expected_bytes = height * (row_bytes + 1)
    reconstructed_bytes = height * row_bytes
    rgba_bytes = width * height * 4
    # The decoder retains inflated scanlines, reconstructed samples, and both bytearray and
    # immutable RGBA output during the final copy. Bound their combined peak, not one buffer.
    if expected_bytes + reconstructed_bytes + 2 * rgba_bytes > MAX_DECODED_BYTES:
        fail("PNG decoded image exceeds the supported bound")
    decompressor = zlib.decompressobj()
    try:
        decoded = decompressor.decompress(bytes(compressed), expected_bytes + 1)
    except zlib.error as error:
        fail(f"PNG image data is invalid: {error}")
    # A completed PNG zlib stream has no pending output. Do not call flush() on malformed
    # compressed input: it can expand without the decompression limit above.
    if (
        len(decoded) != expected_bytes
        or not decompressor.eof
        or decompressor.unused_data
        or decompressor.unconsumed_tail
    ):
        fail("PNG image data has the wrong decoded length")

    reconstructed = bytearray(reconstructed_bytes)
    source = 0
    for row in range(height):
        filter_kind = decoded[source]
        source += 1
        # Unfiltered rows already contain their exact samples. Copy them as a bounded
        # slice instead of executing the predictor loop once per byte of every capture.
        if filter_kind == 0:
            reconstructed[row * row_bytes : (row + 1) * row_bytes] = decoded[source : source + row_bytes]
            source += row_bytes
            continue
        current = reconstructed[row * row_bytes : (row + 1) * row_bytes]
        prior_start = (row - 1) * row_bytes
        for index in range(row_bytes):
            encoded = decoded[source + index]
            left = current[index - channels] if index >= channels else 0
            above = reconstructed[prior_start + index] if row else 0
            upper_left = (
                reconstructed[prior_start + index - channels]
                if row and index >= channels else 0
            )
            if filter_kind == 0:
                value = encoded
            elif filter_kind == 1:
                value = (encoded + left) & 0xFF
            elif filter_kind == 2:
                value = (encoded + above) & 0xFF
            elif filter_kind == 3:
                value = (encoded + ((left + above) // 2)) & 0xFF
            elif filter_kind == 4:
                value = (encoded + _paeth(left, above, upper_left)) & 0xFF
            else:
                fail(f"PNG row {row} uses invalid filter {filter_kind}")
            current[index] = value
        reconstructed[row * row_bytes : (row + 1) * row_bytes] = current
        source += row_bytes

    # RGBA has no channel conversion. Retain the same validated sample bytes, including
    # alpha, without allocating and rewriting a second pixel buffer.
    if color_type == 6:
        return PNGImage(width=width, height=height, rgba=bytes(reconstructed))

    rgba = bytearray(rgba_bytes)
    for pixel_index in range(width * height):
        source_offset = pixel_index * channels
        destination = pixel_index * 4
        if color_type == 0:
            gray = reconstructed[source_offset]
            rgba[destination : destination + 4] = bytes((gray, gray, gray, 255))
        elif color_type == 2:
            rgba[destination : destination + 4] = (
                reconstructed[source_offset : source_offset + 3] + b"\xff"
            )
        elif color_type == 4:
            gray, alpha = reconstructed[source_offset : source_offset + 2]
            rgba[destination : destination + 4] = bytes((gray, gray, gray, alpha))
        else:
            rgba[destination : destination + 4] = reconstructed[
                source_offset : source_offset + 4
            ]
    return PNGImage(width=width, height=height, rgba=bytes(rgba))


def fnv1a64(nonce: str, frame_marker: int) -> int:
    if not isinstance(nonce, str) or not nonce:
        fail("visual challenge nonce must be a nonempty string")
    if not isinstance(frame_marker, int) or isinstance(frame_marker, bool):
        fail("visual challenge frame marker must be an integer")
    if not 0 < frame_marker <= 0xFFFF:
        fail("visual challenge frame marker is outside 1...65535")
    value = FNV_OFFSET
    for byte in nonce.encode("utf-8") + struct.pack("<I", frame_marker):
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFF_FFFF_FFFF_FFFF
    return value


def expected_challenge_record(nonce: str, frame_marker: int) -> dict[str, Any]:
    return {
        "kind": "dev.dory.visual-challenge",
        "version": 1,
        "encoding": ENCODING,
        "frameMarker": frame_marker,
        "payloadHash": f"fnv1a64:{fnv1a64(nonce, frame_marker):016x}",
    }


def expected_readback_rgb(nonce: str, frame_marker: int) -> bytes:
    """Independent row-major RGB8 cell-center oracle for the GL guest readback."""
    payload = fnv1a64(nonce, frame_marker)
    samples = bytearray()
    for row in range(GRID_ROWS):
        for column in range(GRID_COLUMNS):
            if row == 0 and column == 0:
                color = "topLeft"
            elif row == 0 and column == GRID_COLUMNS - 1:
                color = "topRight"
            elif row == GRID_ROWS - 1 and column == 0:
                color = "bottomLeft"
            elif row == GRID_ROWS - 1 and column == GRID_COLUMNS - 1:
                color = "bottomRight"
            elif row in {0, GRID_ROWS - 1} or column in {0, GRID_COLUMNS - 1}:
                color = "border"
            else:
                bit_index = (row - 1) * (GRID_COLUMNS - 2) + column - 1
                bit = (
                    (payload >> bit_index) & 1
                    if bit_index < 64
                    else (frame_marker >> (bit_index - 64)) & 1
                )
                color = "one" if bit else "zero"
            samples.extend(COLORS[color])
    return bytes(samples)


def validate_challenge_record(record: Any, nonce: str, frame_count: int) -> dict[str, Any]:
    if not isinstance(record, dict):
        fail("visible probe result is missing visualChallenge")
    frame_marker = record.get("frameMarker")
    expected = expected_challenge_record(nonce, frame_count)
    if record != expected:
        fail("visualChallenge does not match the independently derived nonce/frame payload")
    if frame_marker != frame_count:
        fail("visual challenge frame marker does not match probe frameCount")
    return record


def _distance(pixel: Iterable[int], expected: tuple[int, int, int]) -> int:
    channels = tuple(pixel)
    if len(channels) >= 4 and channels[3] < 240:
        return 255
    actual = channels[:3]
    return max(abs(actual[index] - expected[index]) for index in range(3))


def _viewport(image: PNGImage, metadata: Any) -> tuple[int, int, int, int]:
    if not isinstance(metadata, dict):
        fail("capture viewport metadata must be an object")
    if metadata.get("coordinateSpace") != "capture-pixels-top-left":
        fail("capture viewport coordinate space is unsupported")
    values = tuple(metadata.get(key) for key in ("x", "y", "width", "height"))
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in values):
        fail("capture viewport geometry must contain integers")
    x, y, width, height = values
    if x < 0 or y < 0 or width <= 0 or height <= 0:
        fail("capture viewport geometry is invalid")
    if x > image.width or y > image.height:
        fail("capture viewport origin is outside the PNG")
    if width > image.width - x or height > image.height - y:
        fail("capture viewport extends outside the PNG")
    source_width = metadata.get("sourceWidth")
    source_height = metadata.get("sourceHeight")
    if type(source_width) is not int or type(source_height) is not int:
        fail("capture viewport source geometry is missing")
    if not (1 <= source_width <= MAX_DIMENSION and 1 <= source_height <= MAX_DIMENSION):
        fail("capture viewport source geometry is invalid")
    for key, extent in (("sourceX", source_width), ("sourceY", source_height)):
        if key in metadata:
            origin = metadata[key]
            if type(origin) is not int or origin < 0 or origin + extent > MAX_DIMENSION:
                fail("capture viewport source origin is invalid")
    scale = metadata.get("backingScaleFactor")
    if not isinstance(scale, (int, float)) or isinstance(scale, bool) or not 0.5 <= scale <= 4:
        fail("capture viewport scale is invalid")
    if metadata.get("colorSpace") not in {"sRGB", "extended-sRGB"}:
        fail("capture viewport color space is unsupported")
    return x, y, width, height


def _red_components(
    image: PNGImage, viewport: tuple[int, int, int, int],
    colors: dict[str, tuple[int, int, int]],
) -> list[tuple[int, int, int, int, int]]:
    x0, y0, width, height = viewport
    visited = bytearray(width * height)
    components: list[tuple[int, int, int, int, int]] = []
    for local_y in range(height):
        for local_x in range(width):
            index = local_y * width + local_x
            if visited[index] or _distance(
                image.pixel(x0 + local_x, y0 + local_y), colors["topLeft"]
            ) > 42:
                continue
            stack = [(local_x, local_y)]
            visited[index] = 1
            minimum_x = maximum_x = local_x
            minimum_y = maximum_y = local_y
            area = 0
            while stack:
                current_x, current_y = stack.pop()
                area += 1
                if area > MAX_RED_COMPONENT_PIXELS:
                    fail("capture contains an oversized red corner component")
                minimum_x = min(minimum_x, current_x)
                maximum_x = max(maximum_x, current_x)
                minimum_y = min(minimum_y, current_y)
                maximum_y = max(maximum_y, current_y)
                for next_x, next_y in (
                    (current_x - 1, current_y), (current_x + 1, current_y),
                    (current_x, current_y - 1), (current_x, current_y + 1),
                ):
                    if not (0 <= next_x < width and 0 <= next_y < height):
                        continue
                    next_index = next_y * width + next_x
                    if visited[next_index]:
                        continue
                    if _distance(
                        image.pixel(x0 + next_x, y0 + next_y), colors["topLeft"]
                    ) <= 42:
                        visited[next_index] = 1
                        stack.append((next_x, next_y))
            component_width = maximum_x - minimum_x + 1
            component_height = maximum_y - minimum_y + 1
            if area >= 9 and component_width <= 128 and component_height <= 128:
                components.append((
                    x0 + minimum_x, y0 + minimum_y,
                    component_width, component_height, area,
                ))
                if len(components) > MAX_CORNER_COMPONENTS:
                    fail("capture contains too many red corner candidates")
    return components


def _sample_cell(
    image: PNGImage, origin_x: int, origin_y: int, cell_width: int,
    cell_height: int,
    column: int, row: int,
) -> tuple[int, int, int, int]:
    center_x = origin_x + column * cell_width + cell_width // 2
    center_y = origin_y + row * cell_height + cell_height // 2
    return image.pixel(center_x, center_y)


def _decode_candidate(
    image: PNGImage,
    viewport: tuple[int, int, int, int],
    origin_x: int,
    origin_y: int,
    cell_width: int,
    cell_height: int,
    colors: dict[str, tuple[int, int, int]],
) -> tuple[int, int, int] | None:
    if origin_x < 0 or origin_y < 0:
        return None
    if origin_x + GRID_COLUMNS * cell_width > image.width:
        return None
    if origin_y + GRID_ROWS * cell_height > image.height:
        return None
    viewport_x, viewport_y, viewport_width, viewport_height = viewport
    if origin_x < viewport_x or origin_y < viewport_y:
        return None
    if origin_x + GRID_COLUMNS * cell_width > viewport_x + viewport_width:
        return None
    if origin_y + GRID_ROWS * cell_height > viewport_y + viewport_height:
        return None
    expectations = (
        (0, 0, "topLeft"), (GRID_COLUMNS - 1, 0, "topRight"),
        (0, GRID_ROWS - 1, "bottomLeft"),
        (GRID_COLUMNS - 1, GRID_ROWS - 1, "bottomRight"),
    )
    maximum_error = 0
    for column, row, name in expectations:
        error = _distance(
            _sample_cell(image, origin_x, origin_y, cell_width, cell_height, column, row),
            colors[name],
        )
        if error > 56:
            return None
        maximum_error = max(maximum_error, error)
    for column in range(1, GRID_COLUMNS - 1):
        for row in (0, GRID_ROWS - 1):
            error = _distance(
                _sample_cell(image, origin_x, origin_y, cell_width, cell_height, column, row),
                colors["border"],
            )
            if error > 48:
                return None
            maximum_error = max(maximum_error, error)
    for row in range(1, GRID_ROWS - 1):
        for column in (0, GRID_COLUMNS - 1):
            error = _distance(
                _sample_cell(image, origin_x, origin_y, cell_width, cell_height, column, row),
                colors["border"],
            )
            if error > 48:
                return None
            maximum_error = max(maximum_error, error)

    payload = 0
    for row in range(1, GRID_ROWS - 1):
        for column in range(1, GRID_COLUMNS - 1):
            bit_index = (row - 1) * 10 + (column - 1)
            pixel = _sample_cell(
                image, origin_x, origin_y, cell_width, cell_height, column, row
            )
            zero_error = _distance(pixel, colors["zero"])
            one_error = _distance(pixel, colors["one"])
            error = min(zero_error, one_error)
            if error > 56 or abs(zero_error - one_error) < 20:
                return None
            maximum_error = max(maximum_error, error)
            if one_error < zero_error:
                payload |= 1 << bit_index
    return payload & 0xFFFF_FFFF_FFFF_FFFF, (payload >> 64) & 0xFFFF, maximum_error


def verify_pixels(
    image_path: Path, viewport_metadata: Any, nonce: str, frame_marker: int,
    *, probe_kind: str | None = None, probe_extent: Any = None,
    probe_format: str | None = None,
) -> dict[str, Any]:
    return verify_image_pixels(
        decode_png(image_path), viewport_metadata, nonce, frame_marker,
        probe_kind=probe_kind, probe_extent=probe_extent,
        probe_format=probe_format,
    )


def _srgb_color(color: tuple[int, int, int]) -> tuple[int, int, int]:
    def encode(channel: int) -> int:
        linear = channel / 255
        encoded = 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
        return round(encoded * 255)

    return tuple(encode(channel) for channel in color)  # type: ignore[return-value]


def _verify_vulkan_application_background(
    image: PNGImage, viewport: tuple[int, int, int, int],
    marker: dict[str, int], source_width: int, source_height: int,
    probe_width: int, probe_height: int, probe_format: str,
) -> None:
    window_x = marker["x"] - 24 * viewport[2] / source_width
    window_y = marker["y"] - 24 * viewport[3] / source_height
    window_width = probe_width * viewport[2] / source_width
    window_height = probe_height * viewport[3] / source_height
    expected = (8, 24, 48)
    if probe_format.endswith("-srgb"):
        expected = _srgb_color(expected)
    for fraction_x, fraction_y in (
        (0.50, 0.50), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75),
    ):
        x = round(window_x + window_width * fraction_x)
        y = round(window_y + window_height * fraction_y)
        if _distance(image.pixel(x, y), expected) > 36:
            fail("captured Vulkan application interior differs from its clear color")


def _verify_compositor_background(image: PNGImage, viewport: tuple[int, int, int, int]) -> None:
    x, y, width, height = viewport
    # The Vulkan compositor probe clears the entire scanout to this UNORM color
    # before drawing the challenge. Sample well away from its top-left grid.
    for fraction_x, fraction_y in (
        (0.50, 0.50), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75),
    ):
        sample = image.pixel(x + int(width * fraction_x), y + int(height * fraction_y))
        if _distance(sample, (0, 64, 191)) > 36:
            fail("captured compositor interior differs from the expected scanout color")


def _verify_gl_texture(
    image: PNGImage, viewport: tuple[int, int, int, int],
    marker: dict[str, int], source_width: int, source_height: int,
    probe_width: int, probe_height: int,
) -> None:
    # The marker's fixed 24-source-pixel inset locates the SDL content, while the
    # central rotating quad is far from the marker and its text strip. Its two
    # alpha-blended checker colors remain distinguishable through display scaling.
    window_x = marker["x"] - 24 * viewport[2] / source_width
    window_y = marker["y"] - 24 * viewport[3] / source_height
    window_width = probe_width * viewport[2] / source_width
    window_height = probe_height * viewport[3] / source_height
    light = dark = 0
    for row in range(9):
        for column in range(9):
            x = round(window_x + window_width * (0.37 + column * 0.0325))
            y = round(window_y + window_height * (0.37 + row * 0.0325))
            pixel = image.pixel(x, y)
            if _distance(pixel, (176, 67, 154)) <= 45:
                light += 1
            elif _distance(pixel, (27, 115, 150)) <= 45:
                dark += 1
    if light < 4 or dark < 4:
        fail("captured GL interior lacks the expected alpha-textured checker colors")


def verify_image_pixels(
    image: PNGImage, viewport_metadata: Any, nonce: str, frame_marker: int,
    *, probe_kind: str | None = None, probe_extent: Any = None,
    probe_format: str | None = None,
) -> dict[str, Any]:
    viewport = _viewport(image, viewport_metadata)
    expected_hash = fnv1a64(nonce, frame_marker)
    expected_width: float | None = None
    expected_height: float | None = None
    if probe_kind is not None:
        if type(probe_kind) is not str or probe_kind not in {
            "gl", "vulkan-application", "vulkan-compositor",
        } or not isinstance(probe_extent, dict):
            fail("visual probe kind or extent is unsupported")
        probe_width = probe_extent.get("width")
        probe_height = probe_extent.get("height")
        if not all(
            type(value) is int and 1 <= value <= MAX_DIMENSION
            for value in (probe_width, probe_height)
        ):
            fail("visual probe extent is invalid")
        source_width = viewport_metadata["sourceWidth"]
        source_height = viewport_metadata["sourceHeight"]
        if "sourceX" not in viewport_metadata or "sourceY" not in viewport_metadata:
            fail("capture viewport source origin is missing")
        if probe_kind == "vulkan-compositor" and (
            probe_width != source_width or probe_height != source_height
            or viewport_metadata["sourceX"] != 0 or viewport_metadata["sourceY"] != 0
        ):
            fail("compositor extent does not match the uncropped guest viewport source")
        if probe_kind in {"gl", "vulkan-application"} and (
            probe_width > source_width or probe_height > source_height
        ):
            fail("visual probe window exceeds the captured guest viewport source")
        source_cell = max(8, min(20, probe_width // 80, probe_height // 50))
        expected_width = source_cell * viewport[2] / source_width
        expected_height = source_cell * viewport[3] / source_height
        if expected_width < 3 or expected_height < 3:
            fail("visual challenge is too small in the captured guest viewport")
    colors = COLORS
    if probe_kind == "vulkan-application":
        if type(probe_format) is not str or probe_format not in {
            "bgra8-unorm", "rgba8-unorm", "bgra8-srgb", "rgba8-srgb",
        }:
            fail("Vulkan application surface format is unsupported by the pixel oracle")
        if probe_format.endswith("-srgb"):
            colors = {name: _srgb_color(color) for name, color in COLORS.items()}
    candidates: list[dict[str, Any]] = []
    geometries_checked = 0
    for component_x, component_y, component_width, component_height, _ in _red_components(
        image, viewport, colors
    ):
        for cell_width in range(max(3, component_width - 2), min(128, component_width + 7) + 1):
            if expected_width is not None and abs(cell_width - expected_width) > max(1.25, expected_width * 0.12):
                continue
            for cell_height in range(max(3, component_height - 2), min(128, component_height + 7) + 1):
                if expected_height is not None and abs(cell_height - expected_height) > max(1.25, expected_height * 0.12):
                    continue
                for inset_x in range(0, 5):
                    for inset_y in range(0, 5):
                        origin_x = component_x - inset_x
                        origin_y = component_y - inset_y
                        geometries_checked += 1
                        if geometries_checked > MAX_CANDIDATE_GEOMETRIES:
                            fail("capture exceeds the visual challenge search budget")
                        decoded = _decode_candidate(
                            image, viewport, origin_x, origin_y,
                            cell_width, cell_height, colors,
                        )
                        if decoded is None:
                            continue
                        challenge_hash, decoded_frame, maximum_error = decoded
                        if challenge_hash != expected_hash or decoded_frame != frame_marker:
                            continue
                        if probe_kind == "vulkan-compositor" and (
                            abs((origin_x - viewport[0]) - 24 * viewport[2] / source_width) > 3
                            or abs((origin_y - viewport[1]) - 24 * viewport[3] / source_height) > 3
                        ):
                            continue
                        if probe_kind in {"gl", "vulkan-application"}:
                            window_x = origin_x - 24 * viewport[2] / source_width
                            window_y = origin_y - 24 * viewport[3] / source_height
                            window_width = probe_width * viewport[2] / source_width
                            window_height = probe_height * viewport[3] / source_height
                            if (
                                window_x < viewport[0] - 3
                                or window_y < viewport[1] - 3
                                or window_x + window_width > viewport[0] + viewport[2] + 3
                                or window_y + window_height > viewport[1] + viewport[3] + 3
                            ):
                                continue
                        candidates.append({
                            "x": origin_x,
                            "y": origin_y,
                            "width": GRID_COLUMNS * cell_width,
                            "height": GRID_ROWS * cell_height,
                            "cellWidth": cell_width,
                            "cellHeight": cell_height,
                            "maximumChannelError": maximum_error,
                        })
    unique = {
        (candidate["x"], candidate["y"], candidate["cellWidth"], candidate["cellHeight"]): candidate
        for candidate in candidates
    }
    if not unique:
        fail("captured guest viewport does not contain the expected visual challenge")
    best = min(unique.values(), key=lambda value: value["maximumChannelError"])
    if any(
        abs(candidate["x"] - best["x"]) > 5
        or abs(candidate["y"] - best["y"]) > 5
        for candidate in unique.values()
    ):
        fail("captured guest viewport contains ambiguous visual challenges")
    if probe_kind == "vulkan-compositor":
        _verify_compositor_background(image, viewport)
    elif probe_kind == "gl":
        _verify_gl_texture(
            image, viewport, best, source_width, source_height,
            probe_width, probe_height,
        )
    elif probe_kind == "vulkan-application":
        _verify_vulkan_application_background(
            image, viewport, best, source_width, source_height,
            probe_width, probe_height, probe_format,
        )
    return {
        "kind": "dev.dory.pixel-oracle-result",
        "version": 1,
        "status": "PASS",
        "encoding": ENCODING,
        "imageWidth": image.width,
        "imageHeight": image.height,
        "viewport": {
            "x": viewport[0], "y": viewport[1],
            "width": viewport[2], "height": viewport[3],
        },
        "marker": best,
        "frameMarker": frame_marker,
        "payloadHash": f"fnv1a64:{expected_hash:016x}",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--frame-marker", type=int, required=True)
    parser.add_argument("--viewport-json", type=Path, required=True)
    parser.add_argument("--probe-json", type=Path)
    parser.add_argument("image", type=Path)
    arguments = parser.parse_args()
    try:
        viewport_document = json.loads(arguments.viewport_json.read_text(encoding="utf-8"))
        viewport = viewport_document.get("guestViewport", viewport_document)
        probe = (
            json.loads(arguments.probe_json.read_text(encoding="utf-8"))
            if arguments.probe_json else None
        )
        if probe is not None and not isinstance(probe, dict):
            fail("visual probe record must be an object")
        result = verify_pixels(
            arguments.image, viewport, arguments.nonce, arguments.frame_marker,
            probe_kind=probe.get("probe") if probe is not None else None,
            probe_extent=probe.get("extent") if probe is not None else None,
            probe_format=probe.get("surfaceFormat") if probe is not None else None,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, PixelOracleError) as error:
        print(f"invalid Dory displayed pixels: {error}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
