#!/usr/bin/env python3
"""Exercise actual installer functions with owned fixtures and non-mutating package stubs.

Never executes the privileged installer entry point, repository cleanup, package managers,
service control, signing or installation. Command stubs expose the exact requested arguments.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "GuestTools/Linux/iso/install.sh"
FUNCTIONS = ("inspect_debian_package", "verify_installed_debian_package", "inspect_rpm_package",
             "verify_installed_rpm_package", "install_rpm_package")
STUBS = r'''
uname() { printf '%s\n' "$DORY_TEST_CPU"; }
dpkg() { printf '%s\n' "$DORY_TEST_DEB_NATIVE_ARCH"; }
dory_test_dpkg_deb() {
  case "$3" in
    Package) printf '%s\n' "$DORY_TEST_NAME" ;;
    Version) printf '%s\n' "$DORY_TEST_DEB_TARGET" ;;
    Architecture) printf '%s\n' "$DORY_TEST_DEB_ARCH" ;;
    *) return 92 ;;
  esac
}
dory_test_dpkg_query() {
  case "$2" in
    '--showformat=${Status}\n${Version}\n${Architecture}')
      printf '%s\n%s\n%s\n' "$DORY_TEST_DEB_STATUS" "$DORY_TEST_DEB_INSTALLED" "$DORY_TEST_DEB_INSTALLED_ARCH" ;;
    *) return 93 ;;
  esac
}
rpm() {
  case "$1" in
    --eval) printf '%s\n' "$DORY_TEST_RPM_NATIVE_ARCH" ;;
    -qp)
      case "$3" in
        '%{NAME}') printf '%s\n' "$DORY_TEST_NAME" ;;
        '%{ARCH}') printf '%s\n' "$DORY_TEST_RPM_ARCH" ;;
        '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}') printf '%s\n' "$DORY_TEST_RPM_TARGET" ;;
        *) return 94 ;;
      esac ;;
    -q)
      [ "$3" = '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' ] || return 95
      [ -n "$DORY_TEST_RPM_INSTALLED" ] || return 1
      printf '%s\n' "$DORY_TEST_RPM_INSTALLED" ;;
    *) return 96 ;;
  esac
}
dnf() {
  printf '%s\n' "$@" > "$DORY_TEST_COMMANDS"
  [ "$DORY_TEST_MANAGER_EXIT" = 0 ] || return "$DORY_TEST_MANAGER_EXIT"
  DORY_TEST_RPM_INSTALLED=$DORY_TEST_MANAGER_RESULT
}
'''


class InstallerPackageIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dory-linux-tools-identity-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.package = self.directory / "owned.package"
        self.package.write_bytes(b"owned fixture, never passed to a real package manager")
        self.commands = self.directory / "arguments.txt"
        self.source = INSTALLER.read_text()
        definitions = []
        for name in FUNCTIONS:
            match = re.search(r"(?m)^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", self.source, re.DOTALL)
            self.assertIsNotNone(match, name)
            definitions.append(match[0])
        self.definitions = "\n".join(definitions)
        # POSIX sh forbids hyphens in function identifiers. Real executable stubs preserve
        # command names without rewriting production definitions or changing shell semantics.
        self.bin_directory = self.directory / "bin"
        self.bin_directory.mkdir()
        for name, function in [("dpkg-deb", "dory_test_dpkg_deb"), ("dpkg-query", "dory_test_dpkg_query")]:
            executable = self.bin_directory / name
            executable.write_text("#!/bin/sh\n" + STUBS + f'\n{function} "$@"\n')
            executable.chmod(0o700)
        self.environment = dict(os.environ, DORY_TEST_CPU="x86_64", DORY_TEST_NAME="dory-guest-tools",
            DORY_TEST_DEB_NATIVE_ARCH="amd64", DORY_TEST_DEB_ARCH="amd64",
            DORY_TEST_DEB_INSTALLED_ARCH="amd64", DORY_TEST_DEB_TARGET="2:1.0.0-7",
            DORY_TEST_DEB_INSTALLED="2:1.0.0-7", DORY_TEST_DEB_STATUS="install ok installed",
            DORY_TEST_RPM_NATIVE_ARCH="x86_64", DORY_TEST_RPM_ARCH="x86_64",
            DORY_TEST_RPM_TARGET="2:1.0.0-7.x86_64", DORY_TEST_RPM_INSTALLED="1:1.0.0-7.x86_64",
            DORY_TEST_MANAGER_RESULT="2:1.0.0-7.x86_64", DORY_TEST_MANAGER_EXIT="0",
            DORY_TEST_COMMANDS=str(self.commands), PATH=f"{self.bin_directory}:/usr/bin:/bin")

    def invoke(self, script, **environment):
        return subprocess.run(["/bin/sh", "-s", "--", str(self.package)],
            input=STUBS + "\n" + self.definitions + "\n" + script + "\n", text=True,
            capture_output=True, check=False, timeout=5, env=dict(self.environment, **environment))

    def test_debian_exact_configured_native_package_is_accepted(self):
        result = self.invoke('inspect_debian_package "$1" && verify_installed_debian_package')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.commands.exists())

    def test_debian_residual_partial_or_foreign_architecture_package_is_rejected(self):
        for environment in [{"DORY_TEST_DEB_STATUS": "deinstall ok config-files"},
                            {"DORY_TEST_DEB_STATUS": "install ok unpacked"},
                            {"DORY_TEST_DEB_INSTALLED_ARCH": "arm64"},
                            {"DORY_TEST_DEB_INSTALLED": "1:1.0.0-7"}]:
            with self.subTest(environment=environment):
                result = self.invoke('inspect_debian_package "$1" && verify_installed_debian_package', **environment)
                self.assertEqual(result.returncode, 65, result.stderr)

    def test_wrong_native_architecture_or_indirect_package_stops_before_manager(self):
        for function, environment in [
            ("inspect_debian_package", {"DORY_TEST_DEB_ARCH": "arm64"}),
            ("inspect_debian_package", {"DORY_TEST_DEB_NATIVE_ARCH": "arm64"}),
            ("inspect_rpm_package", {"DORY_TEST_RPM_ARCH": "aarch64"}),
            ("inspect_rpm_package", {"DORY_TEST_RPM_NATIVE_ARCH": "aarch64"})]:
            with self.subTest(function=function, environment=environment):
                result = self.invoke(f'{function} "$1" && install_rpm_package', **environment)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertFalse(self.commands.exists())
        direct = self.directory / "direct.package"
        self.package.rename(direct)
        self.package.symlink_to(direct)
        for function in ["inspect_debian_package", "inspect_rpm_package"]:
            result = self.invoke(f'{function} "$1" && install_rpm_package')
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertEqual(direct.read_bytes(), b"owned fixture, never passed to a real package manager")

    def test_rpm_rollback_selects_exact_epoch_version_release_architecture(self):
        result = self.invoke('action=rollback; inspect_rpm_package "$1" && install_rpm_package')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands.read_text().splitlines(), ["--assumeyes", "--disablerepo=*",
            "--enablerepo=dory-guest-tools-installer", "downgrade", "dory-guest-tools-2:1.0.0-7.x86_64"])

    def test_rpm_success_without_selected_epoch_does_not_pass(self):
        result = self.invoke('action=rollback; inspect_rpm_package "$1" && install_rpm_package',
                             DORY_TEST_MANAGER_RESULT="1:1.0.0-7.x86_64")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("epoch/version", result.stderr)

    def test_same_rpm_version_is_reinstalled_not_silently_skipped(self):
        result = self.invoke('action=install; inspect_rpm_package "$1" && install_rpm_package',
                             DORY_TEST_RPM_INSTALLED="2:1.0.0-7.x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reinstall", self.commands.read_text().splitlines())

    def test_new_rpm_install_uses_only_selected_offline_repository_and_exact_package(self):
        result = self.invoke('action=install; inspect_rpm_package "$1" && install_rpm_package',
                             DORY_TEST_RPM_INSTALLED="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands.read_text().splitlines()[-4:], ["repository-packages",
            "dory-guest-tools-installer", "install", "dory-guest-tools-2:1.0.0-7.x86_64"])

    def test_package_manager_failure_is_preserved_and_never_claims_verification(self):
        result = self.invoke('action=install; inspect_rpm_package "$1" && install_rpm_package',
                             DORY_TEST_MANAGER_EXIT="17")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn("did not install", result.stderr)

    def test_both_supported_native_isa_pairs_are_admitted(self):
        for function in ["inspect_debian_package", "inspect_rpm_package"]:
            result = self.invoke(f'{function} "$1"', DORY_TEST_CPU="aarch64",
                DORY_TEST_DEB_NATIVE_ARCH="arm64", DORY_TEST_DEB_ARCH="arm64",
                DORY_TEST_RPM_NATIVE_ARCH="aarch64", DORY_TEST_RPM_ARCH="aarch64",
                DORY_TEST_RPM_TARGET="0:1.0.0-7.aarch64")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_version_or_wrong_name_stops_before_transaction(self):
        for function, key in [("inspect_debian_package", "DORY_TEST_DEB_TARGET"),
                              ("inspect_rpm_package", "DORY_TEST_RPM_TARGET")]:
            for value in ["", "x" * 257, "version *", "version\nnext"]:
                result = self.invoke(f'{function} "$1" && install_rpm_package', **{key: value})
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertFalse(self.commands.exists())
            result = self.invoke(f'{function} "$1" && install_rpm_package', DORY_TEST_NAME="unrelated")
            self.assertEqual(result.returncode, 65, result.stderr)

    def test_production_entry_point_preflights_before_legacy_retirement_and_activates_after_verification(self):
        # Composition assertion supplements actual function execution; never run /run or /etc code.
        deb = self.source.split("if command -v apt-get", 1)[1].split("elif command -v dnf", 1)[0]
        rpm = self.source.split("elif command -v dnf", 1)[1]
        self.assertLess(deb.index('inspect_debian_package "$1"'), deb.index("retire_legacy_repository"))
        self.assertLess(rpm.index('inspect_rpm_package "$1"'), rpm.index("retire_legacy_repository"))
        self.assertLess(deb.index("verify_installed_debian_package"), deb.index("legacy_retire_committed=1"))
        self.assertLess(rpm.index("install_rpm_package"), rpm.index("legacy_retire_committed=1"))


if __name__ == "__main__":
    unittest.main()
