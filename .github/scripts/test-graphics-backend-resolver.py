#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "guest/desktop/rootfs-overlay/usr/lib/dory/resolve-graphics-backend"
ACTIVATOR = ROOT / "guest/desktop/rootfs-overlay/usr/lib/dory/configure-graphics-backend"
DISPLAY_MANAGER_DROP_IN = (
    ROOT
    / "guest/desktop/rootfs-overlay/etc/systemd/system/display-manager.service.d"
    / "10-dory-graphics.conf"
)


class GraphicsBackendResolverTests(unittest.TestCase):
    def resolve(self, command_line: str, expected: str) -> None:
        result = subprocess.run(
            [str(RESOLVER), command_line],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertEqual(result.stdout, f"{expected}\n")
        self.assertEqual(result.stderr, "")

    def reject(self, command_line: str, message: str) -> None:
        result = subprocess.run(
            [str(RESOLVER), command_line],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)

    def test_resolves_default_versioned_and_legacy_contracts(self) -> None:
        self.resolve("quiet root=/dev/vda", "software")
        self.resolve("quiet dory.graphics=software", "software")
        self.resolve("dory.graphics=virgl", "virgl2")
        self.resolve("dory.graphics=virgl-venus", "virgl2+venus")
        self.resolve("quiet dory.gpu=venus", "virgl2+venus")

    def test_rejects_duplicate_conflicting_and_unknown_authority(self) -> None:
        self.reject(
            "dory.graphics=virgl dory.graphics=virgl",
            "multiple dory.graphics authorities",
        )
        self.reject(
            "dory.graphics=virgl-venus dory.gpu=venus",
            "versioned and legacy graphics authorities conflict",
        )
        self.reject("dory.graphics=future", "unsupported graphics contract")
        self.reject("dory.gpu=software", "unsupported legacy graphics contract")


class GraphicsBackendActivationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.environment = self.root / "etc/environment.d/70-dory-graphics.conf"
        self.session = self.root / "etc/X11/Xsession.d/70dory-graphics"
        self.requested = self.root / "run/dory/graphics-requested-backend"
        self.effective = self.root / "run/dory/graphics-backend"
        self.status = self.root / "run/dory/graphics-status"
        self.icd = self.root / "opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json"
        self.preflight = self.root / "usr/lib/dory/preflight-graphics-pack"
        self.cmdline = self.root / "proc/cmdline"

        rewritten = ACTIVATOR.read_text(encoding="utf-8")
        assignments = {
            "environment_file=/etc/environment.d/70-dory-graphics.conf":
                f"environment_file={shlex.quote(str(self.environment))}",
            "session_environment=/etc/X11/Xsession.d/70dory-graphics":
                f"session_environment={shlex.quote(str(self.session))}",
            "requested_file=/run/dory/graphics-requested-backend":
                f"requested_file={shlex.quote(str(self.requested))}",
            "effective_file=/run/dory/graphics-backend":
                f"effective_file={shlex.quote(str(self.effective))}",
            "graphics_status=/run/dory/graphics-status":
                f"graphics_status={shlex.quote(str(self.status))}",
            "venus_icd=/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json":
                f"venus_icd={shlex.quote(str(self.icd))}",
            "venus_preflight=/usr/lib/dory/preflight-graphics-pack":
                f"venus_preflight={shlex.quote(str(self.preflight))}",
            "backend_resolver=/usr/lib/dory/resolve-graphics-backend":
                f"backend_resolver={shlex.quote(str(RESOLVER))}",
            "kernel_cmdline_file=/proc/cmdline":
                f"kernel_cmdline_file={shlex.quote(str(self.cmdline))}",
        }
        for original, replacement in assignments.items():
            self.assertEqual(rewritten.count(original), 1, original)
            rewritten = rewritten.replace(original, replacement)

        self.script = self.root / "configure-graphics-backend"
        self.script.write_text(rewritten, encoding="utf-8")
        self.script.chmod(0o700)
        self.icd.parent.mkdir(parents=True)
        self.icd.write_text("{}\n", encoding="utf-8")
        self.cmdline.parent.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def configure_preflight(self, exit_code: int) -> None:
        self.preflight.parent.mkdir(parents=True, exist_ok=True)
        self.preflight.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' 'driver=venus external-sync-fd=yes "
            "import-signaled-fd=yes queue-submit2=yes fence-signal=yes'\n"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        self.preflight.chmod(0o700)

    def activate(self, command_line: str) -> subprocess.CompletedProcess[str]:
        self.cmdline.write_text(f"{command_line}\n", encoding="utf-8")
        return subprocess.run(
            [str(self.script)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_venus_publishes_requested_and_effective_state_after_preflight(self) -> None:
        self.configure_preflight(0)
        result = self.activate("quiet dory.graphics=virgl-venus")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested.read_text(), "virgl2+venus\n")
        self.assertEqual(self.effective.read_text(), "virgl2+venus\n")
        self.assertIn("venus-ready: driver=venus", self.status.read_text())
        expected_icd = str(self.icd)
        self.assertEqual(
            self.environment.read_text().splitlines()[1:],
            [
                "GSK_RENDERER=gl",
                f"VK_DRIVER_FILES={expected_icd}",
                f"VK_ICD_FILENAMES={expected_icd}",
            ],
        )
        self.assertEqual(
            self.session.read_text().splitlines()[1:],
            [
                "export GSK_RENDERER=gl",
                f"export VK_DRIVER_FILES={expected_icd}",
                f"export VK_ICD_FILENAMES={expected_icd}",
            ],
        )

    def test_failed_preflight_falls_back_to_virgl_without_blocking_desktop(self) -> None:
        self.configure_preflight(23)
        for path in (self.environment, self.session, self.effective):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("stale\n", encoding="utf-8")
        result = self.activate("dory.graphics=virgl-venus")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested.read_text(), "virgl2+venus\n")
        self.assertEqual(self.effective.read_text(), "virgl2\n")
        self.assertEqual(
            self.environment.read_text().splitlines()[1:],
            ["GSK_RENDERER=gl"],
        )
        self.assertEqual(
            self.session.read_text().splitlines()[1:],
            ["export GSK_RENDERER=gl"],
        )
        self.assertIn("venus-unavailable:", self.status.read_text())
        self.assertIn("fallback=virgl2", self.status.read_text())

    def test_missing_venus_pack_falls_back_to_virgl(self) -> None:
        result = self.activate("dory.graphics=virgl-venus")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested.read_text(), "virgl2+venus\n")
        self.assertEqual(self.effective.read_text(), "virgl2\n")
        self.assertIn("preflight is missing", self.status.read_text())

    def test_software_activation_keeps_managed_gtk_policy_without_venus(self) -> None:
        self.configure_preflight(0)
        result = self.activate("quiet dory.graphics=software")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested.read_text(), "software\n")
        self.assertEqual(self.effective.read_text(), "software\n")
        self.assertEqual(self.status.read_text(), "software-ready\n")
        self.assertEqual(
            self.environment.read_text().splitlines()[1:],
            ["GSK_RENDERER=gl"],
        )
        self.assertEqual(
            self.session.read_text().splitlines()[1:],
            ["export GSK_RENDERER=gl"],
        )

    def test_conflicting_authority_has_no_requested_or_effective_state(self) -> None:
        self.configure_preflight(0)
        result = self.activate("dory.graphics=virgl-venus dory.gpu=venus")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.requested.exists())
        self.assertFalse(self.effective.exists())
        self.assertIn("authorities conflict", self.status.read_text())

    def test_display_manager_orders_after_graphics_without_requiring_it(self) -> None:
        drop_in = DISPLAY_MANAGER_DROP_IN.read_text(encoding="utf-8")
        self.assertIn("Wants=dory-graphics-backend.service", drop_in)
        self.assertIn("After=dory-graphics-backend.service", drop_in)
        self.assertNotIn("Requires=dory-graphics-backend.service", drop_in)


if __name__ == "__main__":
    unittest.main()
