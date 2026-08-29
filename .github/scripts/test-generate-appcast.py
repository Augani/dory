#!/usr/bin/env python3
"""Offline contract tests for the signed appcast generator."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts/generate-appcast.sh"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DORY = "https://augani.github.io/dory/appcast"


class GenerateAppcastTests(unittest.TestCase):
    def test_schema_two_item_is_escaped_signed_and_preserves_only_older_items(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            artifact = root / "Dory-1.2.3-app-update.zip"
            artifact.write_bytes(b"signed candidate bytes")
            previous = root / "previous.xml"
            previous.write_text(
                """<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item>
<sparkle:version>42</sparkle:version>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
</item>
<item>
<sparkle:version>41</sparkle:version>
<sparkle:shortVersionString>1.2.2</sparkle:shortVersionString>
</item>
</channel></rss>\n""",
                encoding="utf-8",
            )
            output = root / "appcast.xml"
            environment = {
                **os.environ,
                "DORY_SPARKLE_ED_SIGNATURE": "c2lnbmF0dXJl",
                "DORY_APPCAST_TITLE": "Dory & Desktop",
                "DORY_APPCAST_PUBDATE": "Fri, 21 Aug 2026 06:00:00 +0000",
                "DORY_DATA_SCHEMA_VERSION": "2",
                "DORY_MINIMUM_READABLE_DATA_SCHEMA": "1",
                "DORY_MAXIMUM_READABLE_DATA_SCHEMA": "2",
                "DORY_COMPONENT_CATALOG_SCHEMA": "2",
            }
            completed = subprocess.run(
                ["bash", str(GENERATOR), "1.2.3", "42", str(artifact), str(output), str(previous)],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            tree = ET.parse(output)
            channel = tree.getroot().find("channel")
            self.assertIsNotNone(channel)
            self.assertEqual(channel.findtext("title"), "Dory & Desktop")
            items = channel.findall("item")
            self.assertEqual(len(items), 2)
            self.assertEqual(items[0].findtext(f"{{{SPARKLE}}}version"), "42")
            self.assertEqual(items[0].findtext(f"{{{DORY}}}dataSchemaVersion"), "2")
            self.assertEqual(items[0].findtext(f"{{{DORY}}}componentCatalogSchema"), "2")
            enclosure = items[0].find("enclosure")
            self.assertIsNotNone(enclosure)
            self.assertEqual(enclosure.attrib[f"{{{SPARKLE}}}edSignature"], "c2lnbmF0dXJl")
            self.assertEqual(int(enclosure.attrib["length"]), artifact.stat().st_size)
            self.assertEqual(items[1].findtext(f"{{{SPARKLE}}}version"), "41")

    def test_invalid_schema_range_fails_without_publishing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            artifact = root / "candidate.zip"
            artifact.write_bytes(b"candidate")
            output = root / "appcast.xml"
            completed = subprocess.run(
                ["bash", str(GENERATOR), "1.2.3", "42", str(artifact), str(output)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "DORY_SPARKLE_ED_SIGNATURE": "c2lnbmF0dXJl",
                    "DORY_DATA_SCHEMA_VERSION": "3",
                    "DORY_MINIMUM_READABLE_DATA_SCHEMA": "1",
                    "DORY_MAXIMUM_READABLE_DATA_SCHEMA": "2",
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("range excludes", completed.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
