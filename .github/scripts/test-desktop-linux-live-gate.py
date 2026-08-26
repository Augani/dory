#!/usr/bin/env python3
"""Offline contract tests for the physical managed-desktop release gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "desktop-linux-live-gate.sh"


class DesktopLinuxLiveGateTests(unittest.TestCase):
    def test_shell_contract_separates_desktop_recovery_from_venus_qualification(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")

        required = (
            "scope=managed-rootfs-only",
            "generic_arm64_efi_iso_software_baseline=SEPARATE-GATE",
            "--component-dir",
            "component install-candidate",
            "component verify all --offline --json",
            "component path linux-desktop dory-desktop-kernel-arm64.lzfse",
            'cmp -s "$KERNEL" "$installed_kernel"',
            "--guest-user dorygate --guest-uid 1550",
            '--desktop-distro "$distro" --runtime accelerated --graphics "$graphics_preference"',
            "graphics_preference=virgl-venus",
            "--require-acceleration",
            "--require-release-signature",
            "verify-renderer-bootstrap-qualification.py",
            "--clipboard bidirectional",
            "--resolved-graphics (hardware-accelerated-3d|software)",
            "/run/dory/graphics-requested-backend",
            "virgl2+venus",
            "virgl2)",
            "software:software)",
            "software-ready",
            "^venus-unavailable:",
            "fallback=virgl2$",
            "venus-ready:",
            "managed_desktop_baseline=PASS",
            "GSK_RENDERER=gl",
            "MOZ_ENABLE_WAYLAND=0",
            "XDG_SESSION_TYPE=x11",
            'run_desktop ubuntu "$UBUNTU_ROOTFS" gdm3 gnome-shell firefox',
            "contract=vulkan-1.3-application",
            "hardware-device=yes",
            "dynamic-rendering=yes",
            "synchronization2=yes",
            "maintenance4=yes",
            "color-atlas-texture-binding=yes",
            "color-atlas-copy-dst=yes",
            '--distribution-installation "$distribution_installation"',
            '--runtime-installation "$runtime_installation"',
            '"provenance": "verified-update-bundle"',
            "stale-update-rejected",
            "--zed-archive",
            'applicationReadiness"]["applicationTag',
            '"v$ZED_VERSION" = "$TUPLE_ZED_TAG"',
            "zed-native-venus",
            "/zed.app/libexec/zed-editor",
            "for candidate_pid in",
            "*crash-handler*) continue",
            "^LD_LIBRARY_PATH=.",
            "zed --version",
            "--foreground",
            "tr -cs '0-9.'",
            "ZED_RESULT=UNAVAILABLE",
            "ZED_RESULT=PASS",
            "ZED_RESULT=FAIL",
            "strict acceleration requires native Ubuntu Venus/Zed PASS",
            "zed_native_venus=%s",
            "mesa_virgl_desktop=%s",
            "renderer_release_signature=%s",
            "glxinfo -B",
            "glxgears -info",
            "OpenGL renderer string:.*virgl",
            "llvmpipe|softpipe|swrast|software rasterizer",
            "mesa-virgl-desktop",
            "VK_DRIVER_FILES",
            "VK_ICD_FILENAMES",
            "external-sync-fd=yes",
            "import-signaled-fd=yes",
            "export-sync-fd=yes",
            "queue-submit2=yes",
            "fence-signal=yes",
            "dory-vulkan-probe --wsi=xcb",
            "wsi-surface=xcb",
            "surface-create=yes",
            "present-queue=yes",
            "surface-format-policy=first-capability-format",
            "surface-format-id=[1-9][0-9]*",
            "color-atlas-format=(bgra8|rgba8)-unorm",
            "fifo-present=yes",
            "swapchain-create=yes",
            "swapchain-extent=64x64",
            "swapchain-images=[1-9][0-9]*",
            "swapchain-acquire=yes",
            "swapchain-render=yes",
            "queue-present=yes",
            "present-idle=yes",
            '/opt/dory/mesa/lib/libvulkan_virtio.so\' \\"/proc/\\$zed_pid/maps\\"',
            "sleep 30",
            "VK_ERROR_DEVICE_LOST",
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
            'keystroke "f" using {command down, control down}',
            'attribute "AXFullScreen"',
            "fullscreen-display-resized",
            "guest display mode did not follow the full-screen host window",
            "fullscreen-display-restored",
            "guest display mode did not restore after leaving full screen",
            "fullscreen_display=PASS",
            "cursor-left-ready",
            "xsetroot -cursor_name left_ptr",
            "cursor-crosshair-ready",
            "xsetroot -cursor_name crosshair",
            'screencapture -C -x -R"$cursor_region"',
            "guest cursor shape did not change the captured macOS cursor",
            "cursor-shapes.sha256",
            "cursor-restored",
            "cursor_shape=PASS",
            "clipboard-host-to-guest-pass",
            "/usr/lib/dory/clipboard get 'text/plain;charset=utf-8'",
            "clipboard-guest-source-ready",
            "/usr/lib/dory/clipboard set 'text/plain;charset=utf-8'",
            "guest clipboard did not reach the host",
            "clipboard_bidirectional=PASS",
            "input-window-ready",
            "xterm -title DoryInputGate",
            "click at {clickX, clickY}",
            "keystroke inputToken",
            "keyboard-pointer-input-pass",
            "host keyboard/pointer input did not reach the guest exactly",
            "keyboard_pointer_input=PASS",
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
            'LD_LIBRARY_PATH="\\$library_path"',
            "venus_implicit_fencing=true",
            'venus_implicit_fencing="\\$fencing"',
            "dory-vulkan-probe --wsi=wayland",
            "wsi-surface=\\$wsi",
            "WAYLAND_DISPLAY",
            "XDG_SESSION_TYPE=wayland",
            "ZED_EXPECTED",
            "ZED_QUALIFIED",
            "pgrep -n -u dorygate -f '/zed.app/libexec/zed-editor'",
            "grep -q '^LD_LIBRARY_PATH='",
        )
        for stale in forbidden:
            self.assertNotIn(stale, text, stale)

    def test_managed_gate_does_not_claim_generic_iso_qualification(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        self.assertIn("ARM64 EFI ISO installation", text)
        self.assertIn("separate end-to-end gate", text)
        self.assertIn("generic_arm64_efi_iso_software_baseline=SEPARATE-GATE", text)
        self.assertNotIn("--installer-iso", text)

    def test_non_ubuntu_workroot_check_does_not_require_zed_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            runner_temp = root / "runner"
            helpers = root / "helpers"
            components = root / "components"
            outside = root / "outside"
            for directory in (runner_temp, helpers, components):
                directory.mkdir()
            for helper in ("dorydctl", "dory-vmm"):
                path = helpers / helper
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o700)
            hv_runner = helpers / "DoryHVRunner.app" / "Contents" / "MacOS" / "dory-hv"
            hv_runner.parent.mkdir(parents=True)
            hv_runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            hv_runner.chmod(0o700)
            assets = []
            for name in ("Image-desktop", "debian.ext4", "debian-update.tar"):
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
                    "--debian-rootfs",
                    str(assets[1]),
                    "--debian-update",
                    str(assets[2]),
                    "--distro",
                    "debian",
                    "--version",
                    "9.8.7",
                    "--workroot",
                    str(outside),
                    "--confirm",
                    "EXACT-CANDIDATE-DESKTOPS",
                ],
                cwd=ROOT,
                env={**os.environ, "RUNNER_TEMP": str(runner_temp)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertIn("workroot must be a strict child of RUNNER_TEMP", result.stderr)
            self.assertNotIn("Zed", result.stderr)
            self.assertFalse(outside.exists())


if __name__ == "__main__":
    unittest.main()
