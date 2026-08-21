#!/usr/bin/env python3
"""Offline contract tests for the physical host-network recovery gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "host-network-integrity-gate.sh"


class HostNetworkIntegrityGateTests(unittest.TestCase):
    def test_physical_recovery_contract_is_complete(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")

        for proof in (
            "SLEEP-AND-WAKE-THIS-MAC",
            "VPN-ROUTE-CHURN",
            "network probe image must be digest-pinned",
            "Dory socket is not owned by the release user",
            "candidate app has no notarization ticket",
            "Notarized Developer ID",
            "sudo -n pmset relative wake",
            "sudo -n pmset sleepnow",
            "default-route.contract dns.contract proxy.contract service-dns.contract resolvers.contract",
            "required custom DNS server is absent",
            "no active VPN-like interface is present",
            "already has an active Tailscale exit node",
            "ROUTE_CHURN_ROUNDS=3",
            "Arm cleanup before requesting the mutation",
            "host network contract did not self-heal after exit-node round",
            "interactive machine shell",
            "fresh machine exec failed",
            "machine disk persistence failed",
            "release_qualifying=",
            "tailscale_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)

        self.assertRegex(text, r"\^\.\+@sha256:\[0-9a-f\]\{64\}\$")
        self.assertIn("(.ExitNodeStatus // null) == null", text)
        self.assertIn("(.ExitNode // false) == true", text)
        self.assertLess(
            text.index("TAILSCALE_EXIT_NODE_ACTIVE=1", text.index("run_route_churn()")),
            text.index('"$TAILSCALE_BIN" set --exit-node="$TAILSCALE_EXIT_NODE"'),
        )
        self.assertNotIn("tailscale-baseline-disable", text)
        for stale in ("alpine:latest", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_physical_confirmation_fails_before_host_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--app",
                    "/missing/Dory.app",
                    "--workroot",
                    str(pathlib.Path(temporary) / "evidence"),
                ],
                cwd=ROOT,
                env={
                    "DORY_NETWORK_INTEGRITY_IMAGE": "example.invalid/alpine@sha256:" + "a" * 64,
                    "HOME": temporary,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("physical sleep requires --confirm-physical-sleep", result.stderr)


if __name__ == "__main__":
    unittest.main()
