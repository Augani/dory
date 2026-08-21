#!/usr/bin/env python3
"""Offline contract for exact native-IPv6 release qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "native-ipv6-gate.sh"


class NativeIPv6GateTests(unittest.TestCase):
    def test_gate_binds_candidate_network_contract_and_external_route(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-NATIVE-IPV6",
            "Apple silicon is required",
            "candidate inputs must use absolute paths",
            "missing or indirect input",
            "workroot already exists or is indirect",
            "external IPv6 endpoint is invalid",
            "release candidate evidence requires --source-commit",
            "release candidate evidence requires --require-external",
            "release candidate image must be digest-pinned",
            "release candidate evidence requires signed gvproxy provenance and payload inventory",
            "signed gvproxy authority is missing or indirect",
            "dory_verify_signed_gvproxy_payload",
            "DOCKER_CONTEXT",
            'DOCKER_HOST="unix://$SOCKET"',
            "--direct-ipv6",
            "default bridge does not enable IPv6",
            "fd7d:6f72:7901::/64",
            "Cloudflare AAAA resolution is missing",
            "registry AAAA resolution is missing",
            "fd7d:6f72:7900::1",
            "--noproxy '*'",
            "dual-stack localhost publishing failed",
            "engine socket is not owned by the release user",
            "engine restart changed the exact fixture image identity",
            "release candidate image is not preloaded",
            "Mac has an IPv6 route but container TCP failed",
            "external_ipv6_tcp=",
            "exact_image_identity=PASS",
            "same_user_engine_socket=PASS",
            "dory_hv_sha256=",
            "gvproxy_input_sha256=",
            "kernel_input_sha256=",
            "rootfs_input_sha256=",
            "docker_cli_sha256=",
            "network_contract_sha256=",
            "guest_network_log_sha256=",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
            'run --rm alpine:3.20',
        ):
            self.assertNotIn(unsafe, text, unsafe)

    def test_confirmation_fails_before_architecture_inputs_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--dory-hv",
                    "/missing/dory-hv",
                    "--gvproxy",
                    "/missing/gvproxy",
                    "--kernel",
                    "/missing/kernel",
                    "--rootfs",
                    "/missing/rootfs",
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
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
