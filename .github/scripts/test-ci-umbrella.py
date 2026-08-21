#!/usr/bin/env python3
"""Clean-checkout dependency and retry tests for scripts/ci-test.sh."""

from __future__ import annotations

import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CI_TEST = ROOT / "scripts" / "ci-test.sh"


class CIUmbrellaTests(unittest.TestCase):
    def test_source_is_shell_valid_and_keeps_retry_contract(self) -> None:
        subprocess.run(["bash", "-n", str(CI_TEST)], cwd=ROOT, check=True)
        source = CI_TEST.read_text(encoding="utf-8")
        for contract in (
            "test-security-contracts.sh",
            "test-destructive-action-contracts.sh",
            "test-ci-test-support.sh",
            "test-dmg-distribution-signing.sh",
            "test-sleep-wake-evidence.sh",
            "test-live-hostshare-integration.sh",
            "test-agent-protocol-consumers.sh",
            "for attempt in 1 2",
            'bash scripts/test.sh app -- -skip-testing:DoryUITests',
            '"${passed:-0}" -ge 300',
            "still not clean after retry",
            "log path cannot be a symlink",
        ):
            self.assertIn(contract, source)

    def test_every_invoked_repository_script_is_tracked(self) -> None:
        source = CI_TEST.read_text(encoding="utf-8")
        references = sorted(
            set(re.findall(r"scripts/[A-Za-z0-9_.-]+(?:\.sh|\.py)", source))
        )
        tracked = set(
            subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).splitlines()
        )
        missing = [reference for reference in references if reference not in tracked]
        self.assertEqual(missing, [], f"untracked ci-test dependencies: {missing}")


if __name__ == "__main__":
    unittest.main()
