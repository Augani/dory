#!/usr/bin/env python3
from pathlib import Path
import re
import stat
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "GuestTools/Linux/build-tools-iso.sh"
INSTALLER = ROOT / "GuestTools/Linux/iso/install.sh"


class LinuxGuestToolsISOSourceTests(unittest.TestCase):
    def test_builder_requires_both_native_formats_and_signed_repositories(self):
        source = BUILDER.read_text(encoding="utf-8")
        for expected in [
            "dpkg-scanpackages",
            "apt-ftparchive release",
            "createrepo_c",
            "rpmsign --addsign",
            "repomd.xml.asc",
            "SHA256SUMS.asc",
            "DORY_TOOLS",
        ]:
            self.assertIn(expected, source)
        self.assertNotRegex(source.lower(), r"(?m)^\s*(docker|qemu(?:-system)?)(?:\s|$)")
        self.assertTrue(BUILDER.stat().st_mode & stat.S_IXUSR)

    def test_installer_uses_only_the_signed_offline_repositories(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("signed-by=/usr/share/keyrings/dory-guest-tools.asc", source)
        self.assertIn("repo_gpgcheck=1", source)
        self.assertIn("gpgcheck=1", source)
        self.assertIn("file://", source)
        self.assertNotRegex(source, r"https?://")
        self.assertFalse(re.search(r"--nogpgcheck|allow-unauthenticated|trusted=yes", source))
        self.assertTrue(INSTALLER.stat().st_mode & stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
