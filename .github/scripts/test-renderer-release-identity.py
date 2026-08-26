#!/usr/bin/env python3
"""Focused tests for the directed renderer release-identity packaging chain."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "renderer-release-identity.py"
BUNDLE_ENGINE = ROOT / "scripts" / "bundle-engine.sh"
RELEASE = ROOT / "scripts" / "release.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


def load_helper():
    spec = importlib.util.spec_from_file_location("renderer_release_identity", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load renderer release identity helper")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


identity = load_helper()


def production_details(
    *,
    identifier: str = identity.RUNNER_IDENTIFIER,
    team: str = identity.PRODUCTION_TEAM_IDENTIFIER,
    cdhash: str = "a1" * 20,
) -> str:
    return "\n".join((
        "Executable=/fixture/DoryHVRunner.app/Contents/MacOS/dory-hv",
        f"Identifier={identifier}",
        "Format=app bundle with Mach-O thin (arm64)",
        "CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded",
        "Signature size=9050",
        "Authority=Developer ID Application: Dory Fixture (864H636QW4)",
        "Authority=Developer ID Certification Authority",
        "Authority=Apple Root CA",
        f"TeamIdentifier={team}",
        "Runtime Version=26.0.0",
        "Timestamp=Aug 23, 2026 at 10:00:00 PM",
        f"CDHash={cdhash}",
        "",
    ))


class RendererReleaseIdentityTests(unittest.TestCase):
    def test_canonical_entitlement_has_exact_shape_and_types(self) -> None:
        expected = identity.release_identity_entitlements(
            runner_cdhash="a1" * 20,
            worker_cdhash="ab" * 20,
            tuple_digest="cd" * 32,
        )
        self.assertEqual(set(expected), {identity.ENTITLEMENT_NAME})
        nested = expected[identity.ENTITLEMENT_NAME]
        self.assertEqual(set(nested), identity.IDENTITY_KEYS)
        self.assertIs(type(nested["schema-version"]), int)
        for field in (
            "runner-cdhash",
            "renderer-worker-cdhash",
            "tuple-definition-sha256",
        ):
            self.assertIs(type(nested[field]), str)

        raw = identity.canonical_entitlement_bytes(expected)
        self.assertEqual(raw, identity.canonical_entitlement_bytes(expected))
        self.assertEqual(plistlib.loads(raw), expected)
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "doryd.entitlements"
            identity.write_entitlements(output, expected)
            self.assertEqual(output.read_bytes(), raw)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_entitlement_rejects_extra_missing_and_mistyped_fields(self) -> None:
        expected = identity.release_identity_entitlements(
            runner_cdhash="a1" * 20,
            worker_cdhash="ab" * 20,
            tuple_digest="cd" * 32,
        )
        fixtures: list[dict[str, object]] = []

        extra_top = copy.deepcopy(expected)
        extra_top["unreviewed"] = True
        fixtures.append(extra_top)

        extra_nested = copy.deepcopy(expected)
        extra_nested[identity.ENTITLEMENT_NAME]["unreviewed"] = "value"
        fixtures.append(extra_nested)

        missing = copy.deepcopy(expected)
        del missing[identity.ENTITLEMENT_NAME]["runner-cdhash"]
        fixtures.append(missing)

        for wrong in (True, 1.0, "1"):
            mistyped = copy.deepcopy(expected)
            mistyped[identity.ENTITLEMENT_NAME]["schema-version"] = wrong
            fixtures.append(mistyped)

        mistyped_hash = copy.deepcopy(expected)
        mistyped_hash[identity.ENTITLEMENT_NAME]["runner-cdhash"] = b"a1" * 20
        fixtures.append(mistyped_hash)

        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with self.assertRaises(identity.ReleaseIdentityError):
                    identity.validate_release_identity_entitlements(fixture, expected)

    def test_signature_parser_requires_exact_production_identity(self) -> None:
        cdhash = identity.parse_production_signature_details(
            production_details(),
            label="runner",
            expected_identifier=identity.RUNNER_IDENTIFIER,
            expected_team=identity.PRODUCTION_TEAM_IDENTIFIER,
        )
        self.assertEqual(cdhash, "a1" * 20)

        corruptions = {
            "wrong identifier": production_details(identifier="unreviewed"),
            "wrong team": production_details(team="ABCDEFGHIJ"),
            "ad hoc": production_details().replace(
                "Authority=Developer ID Application: Dory Fixture (864H636QW4)\n",
                "Signature=adhoc\n",
            ),
            "no hardened runtime": production_details().replace("(runtime)", "(none)"),
            "no timestamp": production_details().replace(
                "Timestamp=Aug 23, 2026 at 10:00:00 PM\n", ""
            ),
            "short hash": production_details(cdhash="a1" * 19),
            "uppercase hash": production_details(cdhash=("a1" * 20).upper()),
            "zero hash": production_details(cdhash="0" * 40),
            "two hashes": production_details() + f"CDHash={'ab' * 20}\n",
        }
        for label, details in corruptions.items():
            with self.subTest(label=label):
                with self.assertRaises(identity.ReleaseIdentityError):
                    identity.parse_production_signature_details(
                        details,
                        label="runner",
                        expected_identifier=identity.RUNNER_IDENTIFIER,
                        expected_team=identity.PRODUCTION_TEAM_IDENTIFIER,
                    )

    def test_tuple_digest_must_come_back_as_one_exact_verifier_value(self) -> None:
        digest = "cd" * 32
        self.assertEqual(
            identity.parse_tuple_definition_digest(f"definition.sha256={digest}\n"),
            digest,
        )
        for output in (
            "",
            f"definition.sha256={digest.upper()}\n",
            f"definition.sha256={digest}\ndefinition.sha256={digest}\n",
            f"definition.sha256={'0' * 64}\n",
        ):
            with self.subTest(output=output):
                with self.assertRaises(identity.ReleaseIdentityError):
                    identity.parse_tuple_definition_digest(output)

    def test_helper_reads_the_live_digest_through_the_tuple_verifier(self) -> None:
        expected = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "renderer-production-tuple.py"),
                "verify-definition",
                "--repo-root",
                str(ROOT),
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        self.assertEqual(
            identity.tuple_definition_digest(ROOT),
            identity.parse_tuple_definition_digest(expected),
        )

    def test_bundle_and_release_order_are_fail_closed(self) -> None:
        subprocess.run(["bash", "-n", str(BUNDLE_ENGINE)], check=True)
        subprocess.run(["bash", "-n", str(RELEASE)], check=True)
        bundle = BUNDLE_ENGINE.read_text(encoding="utf-8")
        release = RELEASE.read_text(encoding="utf-8")
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        execution = bundle.split("\nbundle_doryd_helpers\n", 1)[1]
        self.assertLess(
            execution.index("bundle_venus_renderer"),
            execution.index("finalize_doryd_signature"),
        )
        self.assertLess(
            execution.index("finalize_doryd_signature"),
            execution.index("PAYLOAD_DIGESTS="),
        )
        doryd_build = bundle.split("bundle_doryd_helpers() {", 1)[1].split(
            "\ninject_debug_toolbox_into_initfs()", 1
        )[0]
        self.assertIn("assemble_doryd_for_release_identity", doryd_build)
        self.assertNotIn(
            'bundle_swiftpm_executable "dory-core-swift" "$configuration" "doryd"',
            doryd_build,
        )
        self.assertIn("verify-absent", bundle)
        self.assertIn("RawHV hardware 3D fails closed", bundle)
        production_signer = bundle.split(
            "codesign_production_release_identity() {", 1
        )[1].split("\nfinalize_doryd_signature()", 1)[0]
        self.assertIn("/usr/bin/codesign", production_signer)
        self.assertIn("--identifier doryd", production_signer)
        self.assertNotIn("DORY_ALLOW_ADHOC_SIGN", production_signer)
        self.assertNotIn("--sign -", production_signer)
        self.assertIn("renderer-release-identity.py\" verify", release)
        self.assertIn(
            "public releases require the production doryd renderer release identity",
            release,
        )
        self.assertIn("scripts/renderer-release-identity.py verify", workflow)
        self.assertIn(
            '--doryd "$extracted/Dory.app/Contents/Helpers/doryd"', workflow
        )
        self.assertIn("dual VirGL2 + Venus renderer", bundle)
        self.assertIn("dual VirGL2 + Venus renderer", release)
        for stale in ("libvirglrenderer.dylib", "libMoltenVK.dylib"):
            self.assertNotIn(stale, bundle)
            self.assertNotIn(stale, release)

    def test_cli_rejects_nonproduction_team_before_reading_artifacts(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "create-entitlements",
                "--runner-app",
                "/nonexistent/DoryHVRunner.app",
                "--output",
                "/nonexistent/doryd.entitlements",
                "--expected-team",
                "ABCDEFGHIJ",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("can only bind Dory production team 864H636QW4", result.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "codesign fixture requires macOS")
    def test_ad_hoc_doryd_has_no_fabricated_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            doryd = pathlib.Path(temporary) / "doryd"
            shutil.copyfile("/usr/bin/true", doryd)
            doryd.chmod(0o755)
            subprocess.run(
                ["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", str(doryd)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            identity.verify_absent(argparse.Namespace(doryd=doryd))

    @unittest.skipUnless(sys.platform == "darwin", "codesign fixture requires macOS")
    def test_codesign_preserves_exact_custom_entitlement_shape(self) -> None:
        expected = identity.release_identity_entitlements(
            runner_cdhash="a1" * 20,
            worker_cdhash="ab" * 20,
            tuple_digest="cd" * 32,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            doryd = root / "doryd"
            entitlements = root / "doryd.entitlements"
            shutil.copyfile("/usr/bin/true", doryd)
            doryd.chmod(0o755)
            identity.write_entitlements(entitlements, expected)
            subprocess.run(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--options",
                    "runtime",
                    "--entitlements",
                    str(entitlements),
                    "--sign",
                    "-",
                    str(doryd),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            actual = identity.read_signed_entitlements(doryd, "fixture doryd")
            identity.validate_release_identity_entitlements(actual, expected)
            with self.assertRaises(identity.ReleaseIdentityError):
                identity.verify_absent(argparse.Namespace(doryd=doryd))


if __name__ == "__main__":
    unittest.main()
