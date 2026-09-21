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
            "dory-agent.service",
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


if __name__ == "__main__":
    unittest.main()
