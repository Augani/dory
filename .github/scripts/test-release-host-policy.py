#!/usr/bin/env python3
"""Behavior coverage for the frozen public-host/experimental boundary."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "release_host_policy", Path(__file__).with_name("verify-release-host-policy.py")
)
assert SPEC is not None and SPEC.loader is not None
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class ReleaseHostPolicyTests(unittest.TestCase):
    def test_exact_public_tuple_is_eligible_but_not_qualified(self) -> None:
        receipt = POLICY.inspect_host("26.6.2", "25G83")
        self.assertTrue(receipt["releaseTestingEligible"])
        self.assertFalse(receipt["releaseQualified"])
        self.assertEqual(receipt["minimumRuntimeMacOS"], "15.0")

    def test_beta_unreviewed_final_and_mismatched_tuples_reject(self) -> None:
        for version, build in (
            ("27.0", "26A5425a"), ("26.5", "25F5071a"),
            ("26.5", "25F999"), ("26.6", "25F71"),
            ("26.5", "25F71"), ("26.6.2", "25G5083a"), ("26.6.1", "25G83"),
            ("15.0", "24A335"), ("27.0", "26A335"),
        ):
            with self.subTest(version=version, build=build):
                with self.assertRaisesRegex(POLICY.HostPolicyFailure, "outside the frozen"):
                    POLICY.inspect_host(version, build)

    def test_malformed_facts_reject_even_in_experimental_mode(self) -> None:
        for version, build in (("26.5beta", "25F71"), ("26.5", "25F71\n"), ("", "")):
            with self.subTest(version=version, build=build):
                with self.assertRaises(POLICY.HostPolicyFailure):
                    POLICY.inspect_host(version, build, experimental=True)

    def test_experimental_mode_never_returns_release_eligibility(self) -> None:
        for version, build in (("27.0", "26A5425a"), ("26.6.2", "25G83")):
            with self.subTest(version=version):
                receipt = POLICY.inspect_host(version, build, experimental=True)
                self.assertEqual(receipt["status"], "EXPERIMENTAL")
                self.assertFalse(receipt["releaseTestingEligible"])
                self.assertFalse(receipt["releaseQualified"])

    def test_cli_rejects_beta_without_writing_a_passing_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.json"
            with patch.object(POLICY, "observed_version", side_effect=["27.0", "26A5425a"]), \
                 patch("sys.argv", ["verify-release-host-policy.py", "--output", str(output)]), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(POLICY.main(), 1)
            self.assertFalse(output.exists())

    def test_cli_experimental_capture_cannot_pass_a_shell_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.json"
            with patch.object(POLICY, "observed_version", side_effect=["27.0", "26A5425a"]), \
                 patch("sys.argv", ["verify-release-host-policy.py", "--experimental", "--output", str(output)]):
                self.assertEqual(POLICY.main(), 3)
            receipt = json.loads(output.read_text())
            self.assertFalse(receipt["releaseTestingEligible"])
            self.assertEqual(receipt["hostBuild"], "26A5425a")


if __name__ == "__main__":
    unittest.main()
