#!/usr/bin/env python3
"""Offline contract tests for the physical managed-desktop release gate."""

from __future__ import annotations

import hashlib
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "desktop-linux-live-gate.sh"


class DesktopLinuxLiveGateTests(unittest.TestCase):
    def test_shell_contract_uses_signed_typed_venus_path(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")

        required = (
            "--component-dir",
            "component install-candidate",
            "component verify all --offline --json",
            "component path linux-desktop dory-desktop-kernel-arm64.lzfse",
            'cmp -s "$KERNEL" "$installed_kernel"',
            "--guest-user dorygate --guest-uid 1550",
            '--desktop-distro "$distro" --runtime accelerated --graphics virgl-venus',
            "--clipboard bidirectional",
            "--resolved-graphics hardware-accelerated-3d",
            "virgl2+venus",
            "venus-ready:",
            '--distribution-installation "$distribution_installation"',
            '--runtime-installation "$runtime_installation"',
            '"provenance": "verified-update-bundle"',
            "stale-update-rejected",
            "--zed-archive",
            "zed-native-venus",
            "/zed.app/libexec/zed-editor",
            "zed --version",
            "zed_native_venus=NOT-RUN",
            "VK_DRIVER_FILES",
            "LD_LIBRARY_PATH",
            "-u ZED_ALLOW_EMULATED_GPU",
            'machine snapshot "$machine"',
            'machine restore-snapshot "$machine"',
            'machine delete-snapshot "$machine"',
            "recovery-exact-bytes-restored",
            'identity.get("mode") != "resolved-plan"',
            "restore reused the snapshot's stale launch plan",
            "snapshot_restore_exact_bytes=PASS",
            "graceful-shutdown-armed",
            "dory-release-graceful-shutdown.service",
            "ExecStop=/bin/sh -c 'printf graceful-shutdown-pass",
            "machine stop did not complete cleanly",
            "graceful_shutdown=PASS",
            "display-baseline-ready",
            "Accessibility permission is required for display qualification",
            "set size of front window of targetProcess to {960, 640}",
            "dynamic-display-resized",
            "guest display mode did not follow the host window resize",
            "dynamic-display-restored",
            "dynamic_retina_display=PASS",
            "workroot must be a strict child of RUNNER_TEMP",
        )
        for proof in required:
            self.assertIn(proof, text, proof)

        forbidden = (
            "--env DORY_",
            '--env "DORY_',
            '--bundle "$update_bundle"',
            '--kernel "$KERNEL"',
            "assert ",
            "= virgl2\n",
            "rollback-pass",
        )
        for stale in forbidden:
            self.assertNotIn(stale, text, stale)

    def test_workroot_must_be_inside_runner_temp(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            runner = root / "runner"
            helpers = root / "helpers"
            components = root / "components"
            outside = root / "outside"
            for directory in (runner, helpers, components):
                directory.mkdir()
            for helper in ("dorydctl", "dory-hv", "dory-vmm"):
                path = helpers / helper
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o700)
            assets = []
            for name in ("Image-desktop", "ubuntu.ext4", "ubuntu-update.tar"):
                path = root / name
                path.write_bytes(name.encode("ascii"))
                assets.append(path)

            result = subprocess.run(
                [
                    str(GATE),
                    "--ctl",
                    str(helpers / "dorydctl"),
                    "--component-dir",
                    str(components),
                    "--kernel",
                    str(assets[0]),
                    "--ubuntu-rootfs",
                    str(assets[1]),
                    "--ubuntu-update",
                    str(assets[2]),
                    "--zed-archive",
                    str(assets[2]),
                    "--zed-version",
                    "1.16.1",
                    "--zed-sha256",
                    hashlib.sha256(assets[2].read_bytes()).hexdigest(),
                    "--distro",
                    "ubuntu",
                    "--version",
                    "9.8.7",
                    "--workroot",
                    str(outside),
                    "--confirm",
                    "EXACT-CANDIDATE-DESKTOPS",
                ],
                cwd=ROOT,
                env={**os.environ, "RUNNER_TEMP": str(runner)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertIn("workroot must be a strict child of RUNNER_TEMP", result.stderr)
            self.assertFalse(outside.exists())


if __name__ == "__main__":
    unittest.main()
