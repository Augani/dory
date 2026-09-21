#!/usr/bin/env python3
from pathlib import Path
import re
import stat
import unittest


PACKAGE = Path(__file__).resolve().parent


class LinuxGuestToolsPackageSourceTests(unittest.TestCase):
    def test_package_is_stock_native_and_has_no_image_builder(self):
        build_files = [
            PACKAGE / "debian" / "rules",
            PACKAGE / "rpm" / "dory-guest-tools.spec",
        ]
        text = "\n".join(path.read_text(encoding="utf-8") for path in build_files)
        self.assertIn("cargo build --locked --release -p dory-agent", text)
        self.assertIn("dory-agent.service", text)
        self.assertNotRegex(text.lower(), r"\b(qemu|docker)\b")

    def test_both_package_formats_ship_the_same_runtime_contract(self):
        debian = (PACKAGE / "debian" / "rules").read_text(encoding="utf-8")
        rpm = (PACKAGE / "rpm" / "dory-guest-tools.spec").read_text(encoding="utf-8")
        for path in [
            "dory-agent",
            "clipboard",
            "clipboard-session",
            "display-resize",
            "dory-agent.service",
            "dory-clipboard.service",
            "90-dory-display-resize.rules",
            "dory-guest-tools.conf",
        ]:
            self.assertIn(path, debian)
            self.assertIn(path, rpm)
        for dependency in ["wl-clipboard", "xclip"]:
            self.assertIn(dependency, (PACKAGE / "debian" / "control").read_text())
            self.assertIn(dependency, rpm)

    def test_clipboard_is_bounded_to_declared_mime_types_and_user_session(self):
        helper = PACKAGE / "payload" / "usr" / "lib" / "dory" / "clipboard"
        source = helper.read_text(encoding="utf-8")
        self.assertIn("text/plain\\;charset=utf-8|image/png", source)
        self.assertIn("XDG_RUNTIME_DIR", source)
        self.assertIn("runuser -u", source)
        self.assertIn("unsupported clipboard type", source)
        self.assertFalse(re.search(r"eval|sh -c", source))
        self.assertTrue(helper.stat().st_mode & stat.S_IXUSR)

    def test_clipboard_authority_is_bound_to_a_graphical_user_service(self):
        helper = (PACKAGE / "payload/usr/lib/dory/clipboard").read_text(encoding="utf-8")
        session = PACKAGE / "payload/usr/lib/dory/clipboard-session"
        unit = (PACKAGE / "payload/usr/lib/systemd/user/dory-clipboard.service").read_text(
            encoding="utf-8"
        )
        self.assertIn("clipboard-session", helper)
        self.assertIn("XDG_RUNTIME_DIR", session.read_text(encoding="utf-8"))
        self.assertIn("PartOf=graphical-session.target", unit)
        self.assertIn("WantedBy=graphical-session.target", unit)
        self.assertIn("RuntimeDirectory=dory", unit)
        self.assertTrue(session.stat().st_mode & stat.S_IXUSR)

    def test_drm_hotplug_rule_has_a_bounded_resize_hook(self):
        rule = (PACKAGE / "payload/usr/lib/udev/rules.d/90-dory-display-resize.rules").read_text(
            encoding="utf-8"
        )
        helper = PACKAGE / "payload/usr/lib/dory/display-resize"
        source = helper.read_text(encoding="utf-8")
        self.assertIn('SUBSYSTEM=="drm"', rule)
        self.assertIn('ENV{HOTPLUG}=="1"', rule)
        self.assertIn("/usr/lib/dory/display-resize %k", rule)
        self.assertIn("xrandr --auto", source)
        self.assertIn("wayland-*", source)
        self.assertFalse(re.search(r"eval|sh -c", source))
        self.assertTrue(helper.stat().st_mode & stat.S_IXUSR)

    def test_uninstall_stops_user_service_and_removes_generated_identity(self):
        prerm = (PACKAGE / "debian/dory-guest-tools.prerm").read_text(encoding="utf-8")
        postrm = (PACKAGE / "debian/dory-guest-tools.postrm").read_text(encoding="utf-8")
        rpm = (PACKAGE / "rpm/dory-guest-tools.spec").read_text(encoding="utf-8")
        self.assertIn("systemctl --user stop dory-clipboard.service", prerm)
        self.assertIn("rm -f /var/lib/dory/username", postrm)
        self.assertIn("%systemd_user_preun dory-clipboard.service", rpm)
        self.assertIn("rm -f /var/lib/dory/username", rpm)


if __name__ == "__main__":
    unittest.main()
