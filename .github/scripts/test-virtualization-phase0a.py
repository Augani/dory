#!/usr/bin/env python3
"""Regression tests for the Phase 0A decision dossier."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / ".github/scripts/verify-virtualization-phase0a.py"


def load_verifier():
    specification = importlib.util.spec_from_file_location("phase0a_verifier", VERIFIER)
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load Phase 0A verifier")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


VERIFICATION = load_verifier()


class VirtualizationPhase0ATests(unittest.TestCase):
    def test_repository_dossier_is_complete(self) -> None:
        VERIFICATION.validate(
            ROOT / "docs/virtualization/phase-0a-decision-records.md",
            ROOT / "docs/virtualization/phase-0a-program.json",
        )

    def test_missing_adr_and_closed_status_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_adrs = ROOT / "docs/virtualization/phase-0a-decision-records.md"
            source_program = ROOT / "docs/virtualization/phase-0a-program.json"
            adrs = root / "adrs.md"
            program = root / "program.json"
            text = source_adrs.read_text(encoding="utf-8")
            adrs.write_text(text.replace("## ADR-026", "## ADR-099", 1), encoding="utf-8")
            program.write_bytes(source_program.read_bytes())
            with self.assertRaisesRegex(VERIFICATION.ValidationFailure, "ADR sequence"):
                VERIFICATION.validate(adrs, program)

            adrs.write_text(text, encoding="utf-8")
            document = json.loads(source_program.read_text(encoding="utf-8"))
            document["status"] = "complete"
            program.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(VERIFICATION.ValidationFailure, "in-progress"):
                VERIFICATION.validate(adrs, program)


if __name__ == "__main__":
    unittest.main()
