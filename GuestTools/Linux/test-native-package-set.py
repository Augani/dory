#!/usr/bin/env python3
"""Contract cases for architecture- and source-bound native guest-tools packages."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("verify-native-package-set.py")
SPEC = importlib.util.spec_from_file_location("dory_native_package_set", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativePackageSetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.deb = root / "dory-guest-tools_0.1.0-1_arm64.deb"
        self.rpm = root / "dory-guest-tools-0.1.0-1.aarch64.rpm"
        self.commit = "a" * 40
        self.write_package(self.deb, "deb", b"native-deb")
        self.write_package(self.rpm, "rpm", b"native-rpm")
        patcher = mock.patch.object(MODULE, "package_field", side_effect=self.package_field)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_package(self, path: Path, package_format: str, content: bytes) -> None:
        path.write_bytes(content)
        receipt = {
            "schema": MODULE.RECEIPT_SCHEMA,
            "sourceCommit": self.commit,
            "guestArchitecture": "arm64",
            "format": package_format,
            "packageFile": path.name,
            "packageSHA256": hashlib.sha256(content).hexdigest(),
        }
        Path(f"{path}.build-receipt.json").write_text(json.dumps(receipt), encoding="utf-8")

    @staticmethod
    def package_field(arguments: list[str]) -> str:
        field = arguments[-1] if arguments[0] == "dpkg-deb" else arguments[-2]
        return {
            "Package": "dory-guest-tools",
            "Architecture": "arm64",
            "Version": "0.1.0-1",
            "%{NAME}": "dory-guest-tools",
            "%{ARCH}": "aarch64",
            "%{VERSION}": "0.1.0",
        }[field]

    def test_accepts_matching_native_packages(self) -> None:
        manifest = MODULE.verify(self.deb, self.rpm)
        self.assertEqual(manifest["guestArchitecture"], "arm64")
        self.assertEqual(manifest["sourceCommit"], self.commit)
        self.assertEqual([item["format"] for item in manifest["packages"]], ["deb", "rpm"])

    def test_portable_verification_uses_signed_version_without_package_tools(self) -> None:
        expected = MODULE.verify(self.deb, self.rpm)
        with mock.patch.object(MODULE, "package_field", side_effect=AssertionError):
            actual = MODULE.verify(self.deb, self.rpm, portable_version=expected["version"])
        self.assertEqual(actual, expected)

    def test_rejects_consistently_named_but_tampered_package(self) -> None:
        self.rpm.write_bytes(b"different-rpm")
        with self.assertRaisesRegex(MODULE.PackageSetError, "digest"):
            MODULE.verify(self.deb, self.rpm)

    def test_rejects_mixed_guest_architectures(self) -> None:
        receipt_path = Path(f"{self.rpm}.build-receipt.json")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["guestArchitecture"] = "x86_64"
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        def mixed_metadata(arguments: list[str]) -> str:
            if arguments[-2] == "%{ARCH}":
                return "x86_64"
            return self.package_field(arguments)
        with mock.patch.object(MODULE, "package_field", side_effect=mixed_metadata):
            with self.assertRaisesRegex(MODULE.PackageSetError, "different guest architectures"):
                MODULE.verify(self.deb, self.rpm)

    def test_rejects_different_source_commits(self) -> None:
        receipt_path = Path(f"{self.rpm}.build-receipt.json")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["sourceCommit"] = "b" * 40
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.PackageSetError, "different source"):
            MODULE.verify(self.deb, self.rpm)

    def test_rejects_symlinked_receipt(self) -> None:
        receipt_path = Path(f"{self.rpm}.build-receipt.json")
        contents = receipt_path.read_bytes()
        receipt_path.unlink()
        target = receipt_path.with_suffix(".target")
        target.write_bytes(contents)
        receipt_path.symlink_to(target)
        with self.assertRaises(MODULE.PackageSetError):
            MODULE.verify(self.deb, self.rpm)


if __name__ == "__main__":
    unittest.main()
