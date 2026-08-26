#!/usr/bin/env python3
"""Offline contract tests for the cross-engine readiness gate."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "readiness.sh"
DIGEST_IMAGE = "example.invalid/fixture@sha256:" + "a" * 64


class ReadinessGateTests(unittest.TestCase):
    def test_release_contract_is_fail_closed_and_reproducible(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "strict readiness requires READINESS_DOCKER_BIN for the exact candidate CLI",
            "strict readiness Docker CLI is unavailable or indirect",
            "readiness fixture images must be exact digest references",
            "READINESS_NONNATIVE_BUILD_IMAGE must be an exact digest reference",
            "READINESS_WORKDIR must not be a symlink",
            "physical Intel qualification must target exactly the Dory engine",
            "independently confirmed native Intel host facts",
            "READINESS_STOP_ORBSTACK_CONFIRMED=STOP-ORBSTACK-FOR-READINESS",
            "Rosetta translates applications only inside an eligible ARM64 Linux VM",
            "Dory exposes no partial x86 VM mode",
            "packaged QEMU TCG backend",
            'stat -f %u "$ENGINE_SOCK"',
            'docker_e image inspect "$ALPINE_IMAGE"',
            "container lifecycle + logs + exec + stats",
            "BuildKit npm ci + build + test",
            "memory/cpu resource limits + update",
            "same-host competitor correctness gate",
            "json.dumps(payload, indent=2, sort_keys=True)",
            "Content-Length: 14",
        ):
            self.assertIn(proof, text, proof)
        for stale in (
            "alpine:latest",
            "nginx:alpine",
            "node:20-alpine",
            "FROM ubuntu:24.04",
            "docker_e pull",
            "pending dory-vmm Rosetta",
            "Rosetta x86-64 machine execution",
        ):
            self.assertNotIn(stale, text, stale)

    def test_source_mode_defines_helpers_without_creating_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = pathlib.Path(temporary) / "must-not-exist"
            summary = pathlib.Path(temporary) / "summary.json"
            command = f'''
set -euo pipefail
READINESS_SOURCE_ONLY=1 READINESS_WORKDIR={str(evidence)!r} source {str(GATE)!r}
test "$(binfmt_handler_for_arch amd64)" = FEX-x86_64
test "$(binfmt_handler_for_arch arm64)" = qemu-aarch64
test ! -e {str(evidence)!r}
SUMMARY_JSON={str(summary)!r}
RESULTS={str(pathlib.Path(temporary) / 'results.tsv')!r}
MEMORY_RESULTS={str(pathlib.Path(temporary) / 'memory.tsv')!r}
RUN_ID='quoted"run'
ENGINES='dory,"other'
write_summary
'''
            subprocess.run(["bash", "-c", command], cwd=ROOT, check=True)
            payload = json.loads(summary.read_text(encoding="utf-8"))
            self.assertEqual(payload["runId"], 'quoted"run')
            self.assertEqual(payload["engines"], 'dory,"other')

    def test_x86_guest_boundary_has_no_partial_vm_claim(self) -> None:
        public_contracts = (
            ROOT / "README.md",
            ROOT / "COMPATIBILITY.md",
            ROOT / "website/public/llms-full.txt",
            ROOT / "docs/linux-vm-performance-contract.md",
        )
        for contract in public_contracts:
            text = contract.read_text(encoding="utf-8")
            self.assertIn("no partial x86 VM", text, contract)
            self.assertIn("packaged QEMU TCG backend", text, contract)

        llms_contract = (ROOT / "website/public/llms-full.txt").read_text(encoding="utf-8")
        self.assertIn("`dory vm` is also unavailable and fails closed", llms_contract)
        self.assertNotIn("`dory vm` is an in-process framework engine surface", llms_contract)

        app_store = (ROOT / "Dory/Models/AppStore.swift").read_text(encoding="utf-8")
        for stale in (
            "Dory's built-in Intel engine needs",
            "one-off `dory vm --rosetta` path",
            "x86/amd64 emulation enabled",
        ):
            self.assertNotIn(stale, app_store, stale)
        self.assertIn("x86_64 Linux applications inside Dory's ARM64 container", app_store)

    def test_mutable_fixture_fails_before_docker_or_socket_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            env = {
                **os.environ,
                "HOME": temporary,
                "READINESS_WORKDIR": str(pathlib.Path(temporary) / "evidence"),
                "READINESS_DOCKER_BIN": "/usr/bin/true",
                "READINESS_ALPINE_IMAGE": "alpine:latest",
                "RUN_NONNATIVE_ARCH": "0",
            }
            result = subprocess.run(
                [str(GATE), "--engines", "dory"],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("fixture images must be exact digest references", result.stderr)

    def test_strict_mode_requires_an_explicit_candidate_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            env = {
                **os.environ,
                "HOME": temporary,
                "READINESS_WORKDIR": str(pathlib.Path(temporary) / "evidence"),
                "READINESS_DOCKER_BIN": "",
                "READINESS_ALPINE_IMAGE": DIGEST_IMAGE,
                "RUN_NONNATIVE_ARCH": "0",
            }
            result = subprocess.run(
                [str(GATE), "--engines", "dory", "--strict"],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("strict readiness requires READINESS_DOCKER_BIN", result.stderr)


if __name__ == "__main__":
    unittest.main()
