#!/usr/bin/env python3
"""Offline contract tests for the physical managed-desktop release gate."""

from __future__ import annotations

import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "desktop-linux-live-gate.sh"


class DesktopLinuxLiveGateTests(unittest.TestCase):
    @staticmethod
    def _write_plist(path: pathlib.Path, value: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            plistlib.dump(value, handle)

    @staticmethod
    def _write_executable(path: pathlib.Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile("/usr/bin/true", path)
        path.chmod(0o700)

    def _signed_gate_fixture(
        self,
        root: pathlib.Path,
        *,
        vmm_identifier: str = "dory-vmm",
        extra_vmm_entitlement: bool = False,
        extra_vmm_xpc_entitlement: bool = False,
        vmm_xpc_services: bool = False,
        omit_renderer_worker: bool = False,
        runner_package_type: str = "APPL",
        runner_symlink: bool = False,
        vmm_executable_name: str = "dory-vmm",
    ) -> tuple[list[str], dict[str, str]]:
        runner_temp = root / "runner"
        helpers = root / "helpers"
        components = root / "components"
        workroot = runner_temp / "gate"
        for directory in (runner_temp, helpers, components):
            directory.mkdir()
        ctl = helpers / "dorydctl"
        ctl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        ctl.chmod(0o700)

        runner = helpers / "DoryHVRunner.app"
        runner_executable = runner / "Contents" / "MacOS" / "dory-hv"
        fs_worker = runner / "Contents" / "XPCServices" / "DoryFSWorker.xpc"
        renderer_worker = (
            runner / "Contents" / "XPCServices" / "DoryRendererWorker.xpc"
        )
        vmm = helpers / "DoryVMM.app"
        self._write_executable(runner_executable)
        self._write_executable(fs_worker / "Contents" / "MacOS" / "DoryFSWorker")
        if not omit_renderer_worker:
            self._write_executable(
                renderer_worker / "Contents" / "MacOS" / "DoryRendererWorker"
            )
        self._write_executable(vmm / "Contents" / "MacOS" / "dory-vmm")
        self._write_plist(
            runner / "Contents" / "Info.plist",
            {
                "CFBundleExecutable": "dory-hv",
                "CFBundleIdentifier": "com.pythonxi.Dory.HVRunner",
                "CFBundlePackageType": runner_package_type,
                "NSCameraUsageDescription": "Camera test.",
                "NSMicrophoneUsageDescription": "Microphone test.",
            },
        )
        self._write_plist(
            fs_worker / "Contents" / "Info.plist",
            {
                "CFBundleExecutable": "DoryFSWorker",
                "CFBundleIdentifier": "com.pythonxi.Dory.HVRunner.FSWorker",
                "CFBundlePackageType": "XPC!",
                "XPCService": {"ServiceType": "Application"},
            },
        )
        if not omit_renderer_worker:
            self._write_plist(
                renderer_worker / "Contents" / "Info.plist",
                {
                    "CFBundleExecutable": "DoryRendererWorker",
                    "CFBundleIdentifier": "com.pythonxi.Dory.HVRunner.RendererWorker",
                    "CFBundlePackageType": "XPC!",
                    "XPCService": {"ServiceType": "Application"},
                },
            )
        self._write_plist(
            vmm / "Contents" / "Info.plist",
            {
                "CFBundleExecutable": vmm_executable_name,
                "CFBundleIdentifier": vmm_identifier,
                "CFBundlePackageType": "APPL",
                "NSMicrophoneUsageDescription": "Microphone test.",
            },
        )

        entitlement_values = {
            "runner": {
                "com.apple.security.device.audio-input": True,
                "com.apple.security.device.camera": True,
                "com.apple.security.hypervisor": True,
            },
            "filesystem": {},
            "renderer": {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.application-groups": [
                    "864H636QW4.dory-renderer"
                ],
            },
            "vmm": {
                "com.apple.security.device.audio-input": True,
                "com.apple.security.virtualization": True,
            },
        }
        if extra_vmm_entitlement:
            entitlement_values["vmm"][
                "com.apple.security.cs.disable-library-validation"
            ] = True
        if extra_vmm_xpc_entitlement:
            entitlement_values["vmm"]["com.apple.security.xpc-service"] = True
        bundles = [
            ("filesystem", fs_worker),
        ]
        if not omit_renderer_worker:
            bundles.append(("renderer", renderer_worker))
        bundles.extend((("runner", runner), ("vmm", vmm)))
        for name, bundle in bundles:
            entitlements = root / f"{name}.entitlements"
            self._write_plist(entitlements, entitlement_values[name])
            subprocess.run(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--entitlements",
                    str(entitlements),
                    str(bundle),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        if vmm_xpc_services:
            (vmm / "Contents" / "XPCServices").mkdir(parents=True)
        if runner_symlink:
            direct_runner = helpers / "DoryHVRunner.direct.app"
            runner.rename(direct_runner)
            runner.symlink_to(direct_runner.name)

        assets = []
        for name in ("Image-desktop", "debian.ext4", "debian-update.tar"):
            path = root / name
            path.write_bytes(name.encode("ascii"))
            assets.append(path)
        arguments = [
            str(GATE),
            "--ctl", str(ctl),
            "--component-dir", str(components),
            "--kernel", str(assets[0]),
            "--debian-rootfs", str(assets[1]),
            "--debian-update", str(assets[2]),
            "--distro", "debian",
            "--version", "9.8.7",
            "--workroot", str(workroot),
            "--confirm", "EXACT-CANDIDATE-DESKTOPS",
        ]
        return arguments, {**os.environ, "RUNNER_TEMP": str(runner_temp)}

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
            "verify_exact_entitlements",
            "DoryHVRunner XPC worker graph is not exact",
            "DoryVMM must not contain XPCServices",
            "developer_id_requirement",
            "designated requirement is not canonical",
            "is not hardened-runtime signed",
            "com.apple.security.device.camera",
            "com.apple.security.virtualization",
            "com.apple.security.cs.disable-library-validation",
            "DoryHVRunner.app is missing or indirect",
            "require_arm64_slice",
            "applicationGraphSHA256",
            "componentCandidateInventorySHA256",
            "component import response binds another catalog",
            "signed VM qualification binds another candidate inventory",
            "machine launched a different VM helper",
            "runnerCodeDirectoryHash",
            "running VM code identity differs from the candidate",
            "exact_release_binding=PASS",
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

    def test_live_gate_rejects_excess_vmm_entitlement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            arguments, environment = self._signed_gate_fixture(
                pathlib.Path(temporary), extra_vmm_entitlement=True
            )
            result = subprocess.run(
                arguments,
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DoryVMM retains forbidden library-validation authority", result.stderr)

    def test_live_gate_rejects_runner_bundle_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            arguments, environment = self._signed_gate_fixture(
                pathlib.Path(temporary), runner_symlink=True
            )
            result = subprocess.run(
                arguments,
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DoryHVRunner.app is missing or indirect", result.stderr)

    def test_live_gate_rejects_wrong_vmm_bundle_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            arguments, environment = self._signed_gate_fixture(
                pathlib.Path(temporary), vmm_identifier="dev.dory.forged-vmm"
            )
            result = subprocess.run(
                arguments,
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DoryVMM CFBundleIdentifier is not dory-vmm", result.stderr)

    def test_live_gate_rejects_vmm_xpc_authority_and_services(self) -> None:
        cases = (
            (
                {"extra_vmm_xpc_entitlement": True},
                "DoryVMM retains forbidden XPC authority",
            ),
            (
                {"vmm_xpc_services": True},
                "DoryVMM must not contain XPCServices",
            ),
        )
        for options, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                arguments, environment = self._signed_gate_fixture(
                    pathlib.Path(temporary), **options
                )
                result = subprocess.run(
                    arguments,
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)

    def test_live_gate_rejects_incomplete_worker_and_info_graphs(self) -> None:
        cases = (
            (
                {"omit_renderer_worker": True},
                "renderer worker is missing",
            ),
            (
                {"runner_package_type": "XPC!"},
                "DoryHVRunner CFBundlePackageType is not APPL",
            ),
            (
                {"vmm_executable_name": "forged-vmm"},
                "DoryVMM CFBundleExecutable is not dory-vmm",
            ),
        )
        for options, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                arguments, environment = self._signed_gate_fixture(
                    pathlib.Path(temporary), **options
                )
                result = subprocess.run(
                    arguments,
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)

    def test_release_gate_rejects_adhoc_signature_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            arguments, environment = self._signed_gate_fixture(pathlib.Path(temporary))
            arguments.insert(-2, "--require-release-signature")
            result = subprocess.run(
                arguments,
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DoryHVRunner is not signed by Dory's Developer ID", result.stderr)

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
            for worker_name, executable_name in (
                ("DoryFSWorker.xpc", "DoryFSWorker"),
                ("DoryRendererWorker.xpc", "DoryRendererWorker"),
            ):
                worker = (
                    helpers
                    / "DoryHVRunner.app"
                    / "Contents"
                    / "XPCServices"
                    / worker_name
                    / "Contents"
                    / "MacOS"
                    / executable_name
                )
                worker.parent.mkdir(parents=True)
                worker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                worker.chmod(0o700)
            vmm = helpers / "DoryVMM.app" / "Contents" / "MacOS" / "dory-vmm"
            vmm.parent.mkdir(parents=True)
            vmm.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            vmm.chmod(0o700)
            with (vmm.parents[1] / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "dory-vmm",
                        "CFBundleIdentifier": "dory-vmm",
                        "CFBundlePackageType": "APPL",
                    },
                    handle,
                )
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
