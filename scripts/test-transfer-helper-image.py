#!/usr/bin/env python3
"""Offline regression tests for the deterministic transfer-helper image archive."""

from __future__ import annotations

import importlib.util
import io
import sys
import tarfile
import struct
import unittest
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("build-transfer-helper-image.py")
SPEC = importlib.util.spec_from_file_location("dory_transfer_helper_image", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class TransferHelperImageTests(unittest.TestCase):
    def setUp(self) -> None:
        helper = bytearray(120)
        helper[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", helper, 16, 2, 183, 1)
        struct.pack_into("<Q", helper, 24, 0x400000)
        struct.pack_into("<Q", helper, 32, 64)
        struct.pack_into("<HHH", helper, 52, 64, 56, 1)
        struct.pack_into("<I", helper, 64, 1)
        self.helper = bytes(helper)
        self.helper_sha256 = MODULE.sha256(self.helper)

    def test_build_is_deterministic_and_self_verifying(self) -> None:
        first, first_metadata = MODULE.build_archive(self.helper)
        second, second_metadata = MODULE.build_archive(self.helper)
        self.assertEqual(first, second)
        self.assertEqual(first_metadata, second_metadata)
        self.assertEqual(
            MODULE.verify_archive(first, self.helper_sha256), first_metadata
        )

    def test_wrong_expected_helper_digest_fails_closed(self) -> None:
        archive, _ = MODULE.build_archive(self.helper)
        with self.assertRaisesRegex(ValueError, "helper digest label"):
            MODULE.verify_archive(archive, "0" * 64)

    def test_extra_outer_member_fails_closed(self) -> None:
        archive, _ = MODULE.build_archive(self.helper)
        output = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
            with tarfile.open(
                fileobj=output, mode="w", format=tarfile.USTAR_FORMAT
            ) as target:
                for member in source.getmembers():
                    target.addfile(member, source.extractfile(member))
                target.addfile(
                    MODULE.tar_info("unexpected", 1, 0o644), io.BytesIO(b"x")
                )
        with self.assertRaisesRegex(ValueError, "unexpected member set"):
            MODULE.verify_archive(output.getvalue(), self.helper_sha256)

    def test_changed_layer_bytes_fail_the_rootfs_digest(self) -> None:
        archive, _ = MODULE.build_archive(self.helper)
        output = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
            manifest = MODULE.json.loads(source.extractfile("manifest.json").read())
            layer_name = manifest[0]["Layers"][0]
            with tarfile.open(
                fileobj=output, mode="w", format=tarfile.USTAR_FORMAT
            ) as target:
                for member in source.getmembers():
                    contents = source.extractfile(member).read()
                    if member.name == layer_name:
                        contents = contents[:-1] + bytes([contents[-1] ^ 1])
                    target.addfile(
                        MODULE.tar_info(member.name, len(contents), member.mode),
                        io.BytesIO(contents),
                    )
        with self.assertRaisesRegex(ValueError, "layer digest"):
            MODULE.verify_archive(output.getvalue(), self.helper_sha256)


if __name__ == "__main__":
    unittest.main()
