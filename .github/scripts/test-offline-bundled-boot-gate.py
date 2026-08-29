#!/usr/bin/env python3
"""Offline contract for exact bundled-image boot without an observed host TCP dependency."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "offline-bundled-boot-gate.sh"


class OfflineBundledBootGateTests(unittest.TestCase):
    def test_gate_binds_exact_candidate_bytes_and_continuously_samples_tcp(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "DISPOSABLE-RUNTIME-OFFLINE-CACHE",
            "--runtime must be absolute",
            "runtime directory is unavailable or indirect",
            "required runtime helper is missing or indirect",
            "required runtime asset is missing or indirect",
            "workroot already exists or is indirect",
            "offline HOME base overlaps a protected runtime/evidence root",
            "offline Docker backend socket path is",
            'cp -cR "$RUNTIME/." "$RUNTIME_COPY/"',
            'cmp "$RUNTIME/$relative" "$RUNTIME_COPY/$relative"',
            "dory_engine_sha256=",
            "dory_hv_sha256=",
            "gvproxy_sha256=",
            "dataplane_proxy_sha256=",
            "kernel_asset_sha256=",
            "rootfs_asset_sha256=",
            "agent_asset_sha256=",
            "HTTP_PROXY=http://127.0.0.1:9",
            "HTTPS_PROXY=http://127.0.0.1:9",
            "ALL_PROXY=socks5://127.0.0.1:9",
            "NO_PROXY=",
            "http_proxy=http://127.0.0.1:9",
            "https_proxy=http://127.0.0.1:9",
            "all_proxy=socks5://127.0.0.1:9",
            "no_proxy=",
            'TCP_MONITOR_OUTPUT="$WORKDIR/fresh-host-tcp-continuous.txt"',
            'TCP_MONITOR_OUTPUT="$WORKDIR/cached-host-tcp-continuous.txt"',
            "sleep 0.05",
            "offline boot retained a host TCP dependency",
            "published a Docker socket owned by another user",
            'mv "$kernel_asset" "$HIDDEN_ASSETS/"',
            'mv "$rootfs_asset" "$HIDDEN_ASSETS/"',
            "fresh boot did not prepare a direct bundled kernel",
            "fresh boot did not prepare a direct bundled rootfs",
            "cached offline boot changed the prepared kernel",
            "cached offline boot changed the prepared rootfs",
            "cached offline boot tried to prepare a missing kernel source",
            "cached offline boot tried to prepare a missing rootfs source",
            "stop returned but the isolated Docker socket remained published",
            "fresh_bundled_boot=PASS",
            "cached_boot_without_bundle_sources=PASS",
            "dead_proxy_environment=PASS",
            "host_tcp_dependency_absence=PASS",
            "continuous_host_tcp_sampling=PASS",
            "same_user_docker_socket=PASS",
            "observable_stop_teardown=PASS",
            "prepared_assets_unchanged=PASS",
        ):
            self.assertIn(proof, text, proof)
        for stale in (
            "assert ",
            'echo "runtime=$RUNTIME"',
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_runtime_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--runtime",
                    str(pathlib.Path(temporary) / "missing-runtime"),
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
