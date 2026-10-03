#!/usr/bin/env python3
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "GuestTools/Linux/build-tools-iso.sh"
INSTALLER = ROOT / "GuestTools/Linux/iso/install.sh"
VERIFIER = ROOT / "GuestTools/Linux/verify-tools-iso.sh"


class LinuxGuestToolsISOSourceTests(unittest.TestCase):
    def test_legacy_dnf_cleanup_preserves_modified_repository_files(self):
        source = INSTALLER.read_text(encoding="utf-8")
        start = source.index("retire_legacy_repository() {")
        end = source.index("\n}\n\ncleanup_repository()", start) + 2
        function = source[start:end]
        original = (
            "[dory-guest-tools]\n"
            "name=Dory Guest Tools\n"
            "baseurl=file:///media/DORY_TOOLS/rpm\n"
            "enabled=1\n"
            "gpgcheck=1\n"
            "repo_gpgcheck=1\n"
            "gpgkey=file:///media/DORY_TOOLS/dory-repository-key.asc\n"
        )
        with tempfile.TemporaryDirectory(prefix="dory-legacy-repo-") as temporary:
            path = Path(temporary) / "dory-guest-tools.repo"
            for contents, expected_exit in (
                (original, 0),
                (original + "priority=1\n", 65),
                (original.replace("repo_gpgcheck=1", "repo_gpgcheck=0"), 65),
                (original.replace("dory-repository-key.asc", "other.asc"), 65),
            ):
                path.write_text(contents, encoding="utf-8")
                result = subprocess.run(
                    ["sh", "-c", function + '\nlegacy_backup=""\nretire_legacy_repository "$1"\n',
                     "sh", str(path)],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, expected_exit, result.stderr)
                if expected_exit == 0:
                    self.assertFalse(path.exists())
                else:
                    self.assertEqual(path.read_text(encoding="utf-8"), contents)

    def test_builder_requires_both_native_formats_and_signed_repositories(self):
        source = BUILDER.read_text(encoding="utf-8")
        for expected in [
            "dpkg-scanpackages",
            "apt-ftparchive -o",
            "APT::FTPArchive::Release::Origin=Dory",
            "createrepo_c",
            "rpmsign --addsign",
            "Debian package signature verification failed",
            "repomd.xml.asc",
            "SHA256SUMS.asc",
            "verify-native-package-set.py",
            "native-build-manifest.json",
            "verify-tools-iso.sh",
            "DORY_TOOLS",
        ]:
            self.assertIn(expected, source)
        self.assertNotRegex(source.lower(), r"(?m)^\s*(docker|qemu(?:-system)?)(?:\s|$)")
        self.assertTrue(BUILDER.stat().st_mode & stat.S_IXUSR)

    def test_iso_verifier_anchors_source_architecture_key_and_signed_bytes(self):
        source = VERIFIER.read_text(encoding="utf-8")
        for expected in [
            "--expected-gpg-key",
            "--expected-source-commit",
            "--expected-architecture",
            "SHA256SUMS.asc",
            "shasum -a 256 -c",
            "native-build-manifest.json",
            "apt/Release.gpg",
            "Origin: Dory",
            "rpm/repodata/repomd.xml.asc",
            "rpm2cpio",
            "--portable",
        ]:
            self.assertIn(expected, source)
        self.assertTrue(VERIFIER.stat().st_mode & stat.S_IXUSR)

    def test_installer_uses_only_the_signed_offline_repositories(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("mktemp /usr/share/keyrings/dory-guest-tools-installer.", source)
        self.assertIn("printf 'deb [signed-by=%s] file:%s/apt ./", source)
        self.assertIn('rm -f "$keyring"', source)
        self.assertIn('rm -f "$preferences"', source)
        self.assertIn('Pin: release o=Dory', source)
        self.assertIn('Pin-Priority: 1001', source)
        self.assertIn('apt-get "$@" install --reinstall', source)
        self.assertIn('Dir::Etc::sourcelist=$repo', source)
        self.assertIn('Dir::Etc::sourceparts=-', source)
        self.assertIn('Dir::State::lists=$apt_lists', source)
        self.assertIn('mktemp -d /var/lib/apt/lists/dory-guest-tools-installer.', source)
        self.assertIn('rm -r "$apt_lists"', source)
        self.assertIn("repo_gpgcheck=1", source)
        self.assertEqual(
            source.count("--disablerepo='*' --enablerepo=dory-guest-tools-installer"), 3
        )
        self.assertIn("repository-packages dory-guest-tools-installer", source)
        self.assertIn("gpgcheck=1", source)
        self.assertIn("file://", source)
        self.assertIn("rollback", source)
        self.assertIn("uninstall", source)
        self.assertIn("mktemp /etc/apt/sources.list.d/", source)
        self.assertIn("mktemp /etc/yum.repos.d/", source)
        self.assertIn("retire_legacy_repository", source)
        self.assertIn('lock_path=/run/dory-guest-tools-installer.lock', source)
        self.assertIn('exec 9>"$lock_path"', source)
        self.assertIn('flock -n 9', source)
        self.assertIn('Another Dory Guest Tools transaction is already running', source)
        self.assertIn("package removal will continue", source)
        self.assertIn("installed_version", source)
        self.assertIn("legacy_retire_committed=1", source)
        self.assertIn("systemctl enable dory-agent.service", source)
        self.assertIn("systemctl restart dory-agent.service", source)
        self.assertIn("systemctl is-active --quiet dory-agent.service", source)
        self.assertNotRegex(source, r"https?://")
        self.assertFalse(re.search(r"--nogpgcheck|allow-unauthenticated|trusted=yes", source))
        self.assertTrue(INSTALLER.stat().st_mode & stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
