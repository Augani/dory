#!/usr/bin/env python3
"""Offline contract tests for the exact physical release-candidate wrapper."""

from __future__ import annotations

import os
import pathlib
import re
import socket
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "release-candidate-live-smoke.sh"
FEX_KIND_GATE = ROOT / "scripts" / "fex-kind-live-gate.sh"


class ReleaseCandidateLiveSmokeTests(unittest.TestCase):
    def test_live_contract_binds_candidate_and_all_physical_gates(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "DORY_RELEASE_LIVE_CONFIRMED=ISOLATED-DORY-RELEASE-USER",
            "live qualification requires an exact source commit",
            "candidate app is unavailable or indirect",
            "candidate executable is unavailable or indirect",
            'HV_RUNNER_EXECUTABLE="$APP/Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv"',
            "candidate Docker socket is not owned by the release user",
            "candidate app has no valid notarization ticket",
            "candidate is not accepted as Notarized Developer ID",
            "required offline release fixture is missing",
            "ISOLATED-DORY-MACHINE-RESOURCES",
            "EXACT-CANDIDATE-DESKTOPS",
            '--component-dir "$DESKTOP_COMPONENT_DIR"',
            "ISOLATED-EXTERNAL-APFS-BIND",
            "ISOLATED-DORY-BIND-LOCKS",
            "SLEEP-AND-WAKE-THIS-MAC",
            'DORY_APP="$APP"',
            'READINESS_DOCKER_BIN="$DOCKER_CLI"',
            'READINESS_ALPINE_IMAGE="$FIXTURE_IMAGE"',
            'READINESS_NONNATIVE_BUILD_IMAGE="$NONNATIVE_BUILD_IMAGE"',
            "live-manifest.txt",
            "live_candidate=PASS",
            "zed-linux-aarch64.tar.gz",
            'ZED_VERSION="1.16.1"',
            "releases/download/v$ZED_VERSION/zed-linux-aarch64.tar.gz",
            "384499c75d75c6aab53110dbc1d8856f6f774baaa32dc57b9963f9e29f8d007b",
            'managed_desktop_baseline=$MANAGED_DESKTOP_BASELINE_RESULT',
            'mesa_virgl_desktop=$MESA_VIRGL_DESKTOP_RESULT',
            'renderer_release_signature=$RENDERER_RELEASE_SIGNATURE_RESULT',
            'zed_native_venus=$ZED_NATIVE_VENUS_RESULT',
            "--require-acceleration",
            "--require-release-signature",
            "native Ubuntu Venus/Zed application evidence did not pass",
            "Mesa VirGL desktop application evidence did not pass",
            "renderer release qualification signature was not authenticated",
            "signed desktop component candidate is unavailable or indirect",
            "signed Kubernetes component is unavailable or indirect",
            "release-build/component-candidate/arm64/component-candidate-inventory.json",
            "Kubernetes component TeamIdentifier does not match the candidate app",
            "Kubernetes component bytes differ from the immutable candidate inventory",
            'candidate_team_identifier=$APP_TEAM_IDENTIFIER',
            'kubectl_team_identifier=$KUBECTL_TEAM_IDENTIFIER',
            'kubectl_component_sha256=$KUBECTL_COMPONENT_SHA256',
            'component_inventory_sha256=$COMPONENT_INVENTORY_SHA256',
            "scripts/fex-kind-live-gate.sh",
            "EXACT-DORY-FEX-KIND",
            'fex_kind_issue_78=$FEX_KIND_GATE_RESULT',
            'KIND_VERSION="0.29.0"',
            "314d8f1428842fd1ba2110fd0052a0f0b3ab5773ab1bdcdad1ff036e913310c9",
            "DORY_RELEASE_LIVE_LOG_ROOT",
        ):
            self.assertIn(proof, text, proof)
        for stale in (
            "alpine:latest",
            "nginx:alpine",
            "node:20-alpine",
            "assert ",
            '"$APP/Contents/Helpers/dory-hv"',
        ):
            self.assertNotIn(stale, text, stale)

    def test_every_invoked_script_is_tracked(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        dependencies = sorted(set(re.findall(r"scripts/[A-Za-z0-9._/-]+\.sh", text)))
        self.assertGreaterEqual(len(dependencies), 10)
        for dependency in dependencies:
            result = subprocess.run(
                ["git", "ls-files", "--error-unmatch", dependency],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, f"untracked live dependency: {dependency}")

    def test_fex_kind_gate_is_the_exact_issue_78_reproduction(self) -> None:
        subprocess.run(["bash", "-n", str(FEX_KIND_GATE)], check=True)
        text = FEX_KIND_GATE.read_text(encoding="utf-8")
        for proof in (
            "EXACT-DORY-FEX-KIND",
            "kindest/node:v1.33.0@sha256:02f73d6ae3f11ad5d543f16736a2cb2a63a300ad60e81dac22099b0b04784a4e",
            "polinux/stress:1.0.4@sha256:b6144f84f9c15dac80deb48d3a646b55c7043ab1d83ea0a697c09097aaad21aa",
            'EXPECTED_NODE_RUNC_VERSION="1.2.3"',
            "guest/kernel/verify-build.sh arm64",
            "guest/initfs/verify-build.sh arm64",
            "running Dory VM kernel differs from the same-commit Venus release artifact",
            "running Dory VM initfs differs from the same-commit release artifact",
            'node_runtime="$(docker_e inspect',
            "/usr/local/bin/runc.real",
            "/usr/local/bin/dory-runc",
            "runc.real is not the preserved kind node runtime file mount",
            "flags: POCF",
            'kubectl_e exec "$EXEC_POD" -- uname -m',
            "issue #78 one-shot result is not x86_64",
            "nested runc exec result is not x86_64",
            "FEXServerClient",
            "Failure to setup client",
            "runc_wrapper_sha256=",
            "fex_sha256=",
            "fex_server_sha256=",
            "fex_errors=absent",
            "kind cluster cleanup failed",
            "kind node container remains after cleanup",
            "kind node image remains after cleanup",
            "isolated_cleanup=PASS",
            "docker_after=PASS",
            "issue_78=PASS",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        self.assertNotIn("kindest/node:v1.33 --", text)

    def test_fex_kind_confirmation_fails_before_host_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(FEX_KIND_GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--workroot",
                    str(workroot),
                ],
                cwd=ROOT,
                env={**os.environ, "HOME": temporary},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm EXACT-DORY-FEX-KIND", result.stderr)
            self.assertFalse(workroot.exists())

    def test_fex_kind_rejects_unpinned_kind_bytes_before_evidence_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            socket_path = root / "dory.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(socket_path))
            try:
                fake_tool = root / "fake-tool"
                fake_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                fake_tool.chmod(0o755)
                running_kernel = root / "running-kernel"
                expected_kernel = root / "expected-kernel"
                running_initfs = root / "running-initfs"
                expected_initfs = root / "expected-initfs"
                running_kernel.write_bytes(b"same kernel\n")
                expected_kernel.write_bytes(b"same kernel\n")
                running_initfs.write_bytes(b"same initfs\n")
                expected_initfs.write_bytes(b"same initfs\n")
                workroot = root / "must-not-exist"
                result = subprocess.run(
                    [
                        "bash",
                        str(FEX_KIND_GATE),
                        "--socket",
                        str(socket_path),
                        "--docker",
                        str(fake_tool),
                        "--kind",
                        str(fake_tool),
                        "--kubectl",
                        str(fake_tool),
                        "--kernel",
                        str(running_kernel),
                        "--initfs",
                        str(running_initfs),
                        "--expected-kernel",
                        str(expected_kernel),
                        "--expected-initfs",
                        str(expected_initfs),
                        "--source-commit",
                        "a" * 40,
                        "--workroot",
                        str(workroot),
                        "--confirm",
                        "EXACT-DORY-FEX-KIND",
                    ],
                    cwd=ROOT,
                    env={**os.environ, "HOME": temporary},
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            finally:
                listener.close()
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("kind v0.29.0 Darwin ARM64 digest mismatch", result.stderr)
            self.assertFalse(workroot.exists())

    def test_dedicated_user_confirmation_fails_before_host_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "Dory.app"
            app.mkdir()
            result = subprocess.run(
                [str(GATE), str(app)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_RELEASE_SOURCE_COMMIT": "a" * 40,
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("DORY_RELEASE_LIVE_CONFIRMED", result.stderr)


if __name__ == "__main__":
    unittest.main()
