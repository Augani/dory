#!/usr/bin/env python3
"""Focused tamper tests for the signed schema-2 release catalog boundary."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "scripts" / "validate-release-metadata.py"
SPEC = importlib.util.spec_from_file_location("validate_release_metadata", VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("release metadata validator could not be loaded")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ReleaseCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tool_directory = tempfile.TemporaryDirectory(prefix="dory-release-signing-test.")
        tool_root = pathlib.Path(cls.tool_directory.name)
        signer_source = tool_root / "signer.swift"
        signer_source.write_text(
            textwrap.dedent(
                """
                import CryptoKit
                import Foundation

                func fail() -> Never { exit(2) }
                let arguments = Array(CommandLine.arguments.dropFirst())
                guard let command = arguments.first else { fail() }
                if command == "keygen", arguments.count == 3 {
                    let key = Curve25519.Signing.PrivateKey()
                    try key.rawRepresentation.write(to: URL(fileURLWithPath: arguments[1]))
                    try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8)
                        .write(to: URL(fileURLWithPath: arguments[2]))
                } else if command == "sign", arguments.count == 4 {
                    let privateData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
                    let message = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
                    let signature = try key.signature(for: message).base64EncodedString() + "\\n"
                    try Data(signature.utf8).write(to: URL(fileURLWithPath: arguments[3]))
                } else {
                    fail()
                }
                """
            ),
            encoding="utf-8",
        )
        cls.signer = tool_root / "signer"
        subprocess.run(
            ["xcrun", "swiftc", str(signer_source), "-o", str(cls.signer)],
            check=True,
        )
        cls.private_key = tool_root / "private-key"
        cls.public_key_file = tool_root / "public-key"
        subprocess.run(
            [str(cls.signer), "keygen", str(cls.private_key), str(cls.public_key_file)],
            check=True,
        )
        cls.public_key = cls.public_key_file.read_text(encoding="ascii")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tool_directory.cleanup()

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="dory-release-catalog-test.")
        self.build = pathlib.Path(self.directory.name)
        self.components = self.build / "components" / "arm64"
        self.components.mkdir(parents=True)
        self.catalog_path = self.components / "catalog.json"
        self.digest_path = self.components / "catalog.json.sha256"
        self.signature_path = self.components / "catalog.json.sig"
        self.asset_name = (
            "Dory-9.8.7-component-linux-desktop-arm64-"
            "virtual-machine-qualification.json"
        )
        self.asset_payload = b"q"
        (self.components / self.asset_name).write_bytes(self.asset_payload)
        asset_digest = hashlib.sha256(self.asset_payload).hexdigest()
        key_id = hashlib.sha256(base64.b64decode(self.public_key, validate=True)).hexdigest()
        self.catalog = {
            "kind": "dev.dory.component-catalog",
            "schemaVersion": 2,
            "releaseVersion": "9.8.7",
            "generatedAt": "2026-08-21T01:02:03Z",
            "minimumAppVersion": "9.8.7",
            "architecture": "arm64",
            "components": [
                self.component("docker-core", [], []),
                self.component(
                    "linux-desktop",
                    ["docker-core"],
                    [{
                        "path": "virtual-machine-qualification.json",
                        "role": "qualification-evidence",
                        "url": (
                            "https://github.com/Augani/dory/releases/download/v9.8.7/"
                            f"{self.asset_name}"
                        ),
                        "compression": "none",
                        "downloadBytes": 1,
                        "installedBytes": 1,
                        "sha256": asset_digest,
                        "installedSHA256": asset_digest,
                        "executable": False,
                    }],
                    qualification=["qualification-1"],
                    attestation_digest=asset_digest,
                ),
            ],
            "virtualMachineQualification": {
                "component": "linux-desktop",
                "path": "virtual-machine-qualification.json",
                "manifestIdentity": "qualification-1",
                "manifestFormatVersion": 2,
                "signingKeyID": key_id,
            },
        }

    def tearDown(self) -> None:
        self.directory.cleanup()

    @staticmethod
    def component(
        identifier: str,
        dependencies: list[str],
        assets: list[dict],
        *,
        qualification: list[str] | None = None,
        attestation_digest: str = "d" * 64,
    ) -> dict:
        return {
            "id": identifier,
            "version": "9.8.7",
            "displayName": identifier,
            "summary": f"{identifier} fixture",
            "dependencies": dependencies,
            "downloadBytes": 1,
            "installedBytes": 1,
            "assets": assets,
            "architectures": ["arm64"],
            "hostRequirements": {"platform": "macos", "minimumVersion": "14.0"},
            "provides": [],
            "requires": [],
            "provenance": {
                "sourceCommit": "a" * 40,
                "builder": "dory.test",
                "recipeDigest": "b" * 64,
                "sbomDigest": "c" * 64,
                "attestationDigest": attestation_digest,
            },
            "qualification": qualification or [],
        }

    def publish(self, *, resign: bool = True) -> None:
        self.catalog_path.write_text(
            json.dumps(self.catalog, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        self.digest_path.write_text(
            hashlib.sha256(self.catalog_path.read_bytes()).hexdigest() + "\n",
            encoding="ascii",
        )
        if resign:
            subprocess.run(
                [
                    str(self.signer),
                    "sign",
                    str(self.private_key),
                    str(self.catalog_path),
                    str(self.signature_path),
                ],
                check=True,
            )

    def validate(self) -> set[str]:
        return VALIDATOR.validate_catalog(
            self.build,
            "9.8.7",
            "a" * 40,
            public_key=self.public_key,
        )

    def test_signed_schema_two_catalog_is_accepted(self) -> None:
        self.publish()
        self.assertEqual(
            self.validate(),
            {"Dory-9.8.7-component-linux-desktop-arm64-virtual-machine-qualification.json"},
        )

    def test_schema_one_is_rejected_even_when_correctly_signed(self) -> None:
        self.catalog["schemaVersion"] = 1
        self.publish()
        with self.assertRaisesRegex(ValueError, "schema 2"):
            self.validate()

    def test_test_fixture_catalog_kind_is_never_public_release_metadata(self) -> None:
        self.catalog["kind"] = "dev.dory.component-catalog.test-fixture"
        self.publish()
        with self.assertRaisesRegex(ValueError, "kind mismatch"):
            self.validate()

    def test_qualification_schema_one_is_rejected_even_when_correctly_signed(self) -> None:
        self.catalog["virtualMachineQualification"]["manifestFormatVersion"] = 1
        self.publish()
        with self.assertRaisesRegex(ValueError, "qualification schema"):
            self.validate()

    def test_catalog_mutation_with_rewritten_digest_fails_signature(self) -> None:
        self.publish()
        self.catalog["generatedAt"] = "2026-08-21T01:02:04Z"
        self.publish(resign=False)
        with self.assertRaisesRegex(ValueError, "signature is invalid"):
            self.validate()

    def test_unknown_catalog_field_is_rejected(self) -> None:
        self.catalog["unexpected"] = True
        self.publish()
        with self.assertRaisesRegex(ValueError, "shape is invalid"):
            self.validate()

    def test_signed_asset_digest_must_match_delivered_bytes(self) -> None:
        self.catalog["components"][1]["assets"][0]["sha256"] = "e" * 64
        self.catalog["components"][1]["assets"][0]["installedSHA256"] = "e" * 64
        self.publish()
        with self.assertRaisesRegex(ValueError, "digest differs from catalog"):
            self.validate()

    def test_signed_asset_size_must_match_delivered_bytes(self) -> None:
        self.catalog["components"][1]["assets"][0]["downloadBytes"] = 2
        self.catalog["components"][1]["assets"][0]["installedBytes"] = 2
        self.publish()
        with self.assertRaisesRegex(ValueError, "byte count differs from catalog"):
            self.validate()

    def test_uncompressed_asset_must_have_equal_stored_and_installed_binding(self) -> None:
        self.catalog["components"][1]["assets"][0]["installedSHA256"] = "f" * 64
        self.publish()
        with self.assertRaisesRegex(ValueError, "uncompressed component asset"):
            self.validate()

    def test_delivered_asset_symlink_is_rejected(self) -> None:
        artifact = self.components / self.asset_name
        direct = self.components / "direct-qualification.json"
        artifact.rename(direct)
        artifact.symlink_to(direct.name)
        self.publish()
        with self.assertRaisesRegex(ValueError, "indirect or empty"):
            self.validate()

    def test_catalog_symlink_is_rejected_before_signature_verification(self) -> None:
        self.publish()
        direct = self.components / "catalog-direct.json"
        self.catalog_path.rename(direct)
        self.catalog_path.symlink_to(direct.name)
        with self.assertRaisesRegex(ValueError, "missing or indirect"):
            self.validate()

    def test_qualification_must_use_the_pinned_signing_key(self) -> None:
        self.catalog["virtualMachineQualification"]["signingKeyID"] = "e" * 64
        self.publish()
        with self.assertRaisesRegex(ValueError, "trust root"):
            self.validate()

    def test_current_appcast_must_declare_catalog_schema_two(self) -> None:
        update = self.build / "Dory-9.8.7-app-update.zip"
        update.write_bytes(b"fixture")

        def write_appcast(component_schema: int) -> None:
            (self.build / "appcast.xml").write_text(
                textwrap.dedent(
                    f"""\
                    <?xml version="1.0"?>
                    <rss version="2.0"
                         xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
                         xmlns:dory="https://augani.github.io/dory/appcast">
                      <channel>
                        <title>Dory</title>
                        <link>https://augani.github.io/dory/appcast.xml</link>
                        <description>Updates for Dory - native Docker and Linux containers for macOS.</description>
                        <language>en</language>
                        <item>
                          <title>9.8.7</title>
                          <pubDate>Fri, 21 Aug 2026 01:02:03 +0000</pubDate>
                          <sparkle:version>42</sparkle:version>
                          <sparkle:shortVersionString>9.8.7</sparkle:shortVersionString>
                          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                          <dory:dataSchemaVersion>1</dory:dataSchemaVersion>
                          <dory:minimumReadableDataSchema>1</dory:minimumReadableDataSchema>
                          <dory:maximumReadableDataSchema>1</dory:maximumReadableDataSchema>
                          <dory:componentCatalogSchema>{component_schema}</dory:componentCatalogSchema>
                          <enclosure
                            url="https://github.com/Augani/dory/releases/download/v9.8.7/Dory-9.8.7-app-update.zip"
                            sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"
                            length="{update.stat().st_size}"
                            type="application/octet-stream" />
                        </item>
                      </channel>
                    </rss>
                    """
                ),
                encoding="utf-8",
            )

        write_appcast(1)
        with self.assertRaisesRegex(ValueError, "component schema"):
            VALIDATOR.validate_appcast(
                self.build,
                "9.8.7",
                "42",
                "appcast.xml",
                "Dory",
                "https://augani.github.io/dory/appcast.xml",
                update.name,
            )
        write_appcast(2)
        VALIDATOR.validate_appcast(
            self.build,
            "9.8.7",
            "42",
            "appcast.xml",
            "Dory",
            "https://augani.github.io/dory/appcast.xml",
            update.name,
        )


if __name__ == "__main__":
    unittest.main()
