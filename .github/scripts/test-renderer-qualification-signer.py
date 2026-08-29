#!/usr/bin/env python3
"""Contract tests for the release-owned renderer qualification signer adapter."""

from __future__ import annotations

import base64
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SIGNER = ROOT / "scripts/release.sh"


class RendererQualificationSignerTests(unittest.TestCase):
    def test_writes_one_canonical_ed25519_line(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-renderer-signer.") as raw:
            work = pathlib.Path(raw)
            receipt = work / "receipt.json"
            output = work / "receipt.json.sig"
            tool = work / "sign_update"
            receipt.write_text('{"candidate":"exact"}\n', encoding="utf-8")
            signature = base64.b64encode(bytes(range(64))).decode("ascii")
            tool.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "[ \"${1:-}\" = -p ] && [ \"${2:-}\" = \"$EXPECTED_RECEIPT\" ]\n"
                "printf 'sign_update note\\n%s\\n' \"$EXPECTED_SIGNATURE\"\n",
                encoding="utf-8",
            )
            tool.chmod(0o755)
            result = subprocess.run(
                [str(SIGNER), "--receipt", str(receipt), "--output", str(output)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "DORY_SPARKLE_SIGN_UPDATE": str(tool),
                    "EXPECTED_RECEIPT": str(receipt),
                    "EXPECTED_SIGNATURE": signature,
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(output.read_text(encoding="ascii"), signature + "\n")
            self.assertEqual(output.stat().st_mode & 0o777, 0o644)

    def test_rejects_non_ed25519_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-renderer-signer.") as raw:
            work = pathlib.Path(raw)
            receipt = work / "receipt.json"
            output = work / "receipt.json.sig"
            tool = work / "sign_update"
            receipt.write_text("{}\n", encoding="utf-8")
            tool.write_text("#!/bin/bash\nprintf 'not-a-signature\\n'\n", encoding="utf-8")
            tool.chmod(0o755)
            result = subprocess.run(
                [str(SIGNER), "--receipt", str(receipt), "--output", str(output)],
                cwd=ROOT,
                env={**os.environ, "DORY_SPARKLE_SIGN_UPDATE": str(tool)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed Ed25519 signature", result.stdout)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
