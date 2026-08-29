#!/usr/bin/env python3
"""Focused static tests for Dory's schema-3 dual-Metal renderer tuple."""

from __future__ import annotations

import hashlib
import json
import pathlib
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock


REPO = pathlib.Path(__file__).resolve().parents[2]
DEFINITION = REPO / "Config/DoryRendererProductionTuple.json"
VERIFIER = REPO / "scripts/renderer-production-tuple.py"
PACKAGE = REPO / "scripts/package-renderer-production-bundle.py"
ASSEMBLER = REPO / "scripts/assemble-renderer-production-worker.sh"
QUALIFICATION_VERIFIER = REPO / "scripts/verify-renderer-bootstrap-qualification.py"


def run(*arguments: object, ok: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(argument) for argument in arguments],
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if ok and result.returncode != 0:
        raise AssertionError(result.stdout)
    if not ok and result.returncode == 0:
        raise AssertionError(f"command unexpectedly succeeded: {arguments}\n{result.stdout}")
    return result


def tuple_command(
    *arguments: object,
    definition: pathlib.Path = DEFINITION,
    ok: bool = True,
) -> subprocess.CompletedProcess[str]:
    return run("python3", VERIFIER, "--definition", definition, *arguments, ok=ok)


class StaticTupleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.definition = json.loads(DEFINITION.read_text(encoding="utf-8"))

    def test_definition_is_exact_schema_3_dual_metal_architecture(self) -> None:
        result = tuple_command("verify-definition", "--repo-root", REPO)
        canonical = (
            json.dumps(
                self.definition,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode()
        digest = hashlib.sha256(canonical).hexdigest()
        self.assertEqual(result.stdout.strip(), f"definition.sha256={digest}")
        self.assertEqual(tuple_command("definition-sha256").stdout.strip(), digest)
        self.assertEqual(self.definition["schemaVersion"], 3)
        self.assertEqual(self.definition["sourceTuple"], "dory-dual-metal-20260826")
        self.assertEqual(
            set(self.definition["sources"]),
            {"angle", "libepoxy", "mesa", "moltenVK", "virglrenderer"},
        )
        profiles = self.definition["artifactProfiles"]
        self.assertEqual(
            set(profiles),
            {
                "rendererBundle",
                "rendererQualificationEvidence",
                "rendererReleaseQualificationEvidence",
                "staticDependencies",
                "staticLinkClosure",
            },
        )
        self.assertEqual(
            profiles["rendererBundle"],
            {
                "angleMetal": [
                    "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libEGL.dylib",
                    "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libGLESv2.dylib",
                ],
                "rendererWorker": [
                    "XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker"
                ],
            },
        )
        for component in profiles["rendererBundle"].values():
            self.assertNotIn(
                "Resources/renderer-bootstrap-qualification.json", component
            )
        self.assertEqual(
            profiles["rendererQualificationEvidence"],
            {"qualification": ["Resources/renderer-bootstrap-qualification.json"]},
        )
        self.assertEqual(
            profiles["rendererReleaseQualificationEvidence"],
            {
                "qualification": ["Resources/renderer-bootstrap-qualification.json"],
                "releaseSignature": [
                    "Resources/renderer-bootstrap-qualification.json.sig"
                ],
            },
        )
        policy = self.definition["virglBuildPolicy"]
        self.assertEqual(policy["classicRenderer"], "virgl2-angle-metal")
        self.assertEqual(policy["platforms"], ["egl"])
        self.assertEqual(policy["requiredCapsets"], [2, 4])
        self.assertFalse(policy["venusOnly"])
        self.assertTrue(policy["venus"])
        self.assertFalse(policy["vulkanDynamicLoad"])

    def test_old_schema_and_venus_only_policy_fail_closed(self) -> None:
        mutated = json.loads(json.dumps(self.definition))
        mutated["schemaVersion"] = 2
        mutated["virglBuildPolicy"]["venusOnly"] = True
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "old.json"
            path.write_text(json.dumps(mutated), encoding="utf-8")
            result = tuple_command(
                "verify-definition", "--repo-root", REPO,
                definition=path, ok=False,
            )
        self.assertIn("schema is unsupported", result.stdout)

    def test_every_profile_round_trips_and_tampering_is_rejected(self) -> None:
        profiles = self.definition["artifactProfiles"]
        for profile, components in profiles.items():
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary) / "root"
                root.mkdir()
                for paths in components.values():
                    for relative in paths:
                        artifact = root.joinpath(*pathlib.PurePosixPath(relative).parts)
                        artifact.parent.mkdir(parents=True, exist_ok=True)
                        artifact.write_bytes(f"{profile}:{relative}".encode())
                inventory = pathlib.Path(temporary) / "inventory.json"
                tuple_command(
                    "create-inventory", "--profile", profile, "--root", root,
                    "--output", inventory,
                )
                value = json.loads(inventory.read_text(encoding="utf-8"))
                self.assertEqual(value["schemaVersion"], 3)
                tuple_command(
                    "verify-inventory", "--profile", profile, "--root", root,
                    "--inventory", inventory,
                )
                first = next(iter(next(iter(components.values()))))
                root.joinpath(*pathlib.PurePosixPath(first).parts).write_bytes(b"tampered")
                result = tuple_command(
                    "verify-inventory", "--profile", profile, "--root", root,
                    "--inventory", inventory, ok=False,
                )
                self.assertIn("bytes differ", result.stdout)

    def test_inventory_rejects_symlink_artifact(self) -> None:
        components = self.definition["artifactProfiles"]["staticDependencies"]
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target = root / "target"
            target.write_bytes(b"archive")
            symlinked = False
            for paths in components.values():
                for relative in paths:
                    artifact = root.joinpath(*pathlib.PurePosixPath(relative).parts)
                    artifact.parent.mkdir(parents=True, exist_ok=True)
                    if not symlinked:
                        artifact.symlink_to(target)
                        symlinked = True
                    else:
                        artifact.write_bytes(relative.encode())
            result = tuple_command(
                "create-inventory", "--profile", "staticDependencies",
                "--root", root, "--output", root / "inventory.json", ok=False,
            )
        self.assertIn("non-symlink regular file", result.stdout)

    def test_reviewed_meson_graph_requires_classic_and_venus(self) -> None:
        options = {
            "buildtype": "release", "check-gl-errors": False,
            "default_library": "static", "drm-renderers": [], "fuzzer": False,
            "minigbm_allocation": False, "neptune": False, "platforms": ["egl"],
            "render-server-mode": "thread", "render-server-worker": "thread",
            "tests": False, "unstable-apis": True, "venus": True,
            "venus-only": False, "video": False, "vtest": False,
            "vulkan-dload": False, "vulkan-preload": False,
        }
        classic = [
            "src/vrend/vrend_renderer.c",
            "src/vrend/vrend_winsys.c",
            "src/vrend/vrend_winsys_egl.c",
        ]
        venus = ["src/virglrenderer.c", "src/venus/vkr_renderer.c"]
        transport = [
            "server/render_client.c", "server/render_common.c",
            "server/render_context.c", "server/render_server.c",
            "server/render_socket.c", "server/render_state.c",
            "server/render_worker.c", "src/proxy/proxy_client.c",
            "src/proxy/proxy_common.c", "src/proxy/proxy_context.c",
            "src/proxy/proxy_renderer.c", "src/proxy/proxy_server.c",
            "src/proxy/proxy_socket.c",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            build = pathlib.Path(temporary)
            (build / "meson-info").mkdir()
            (build / "meson-logs").mkdir()
            (build / "meson-info/intro-buildoptions.json").write_text(
                json.dumps([{"name": name, "value": value} for name, value in options.items()]),
                encoding="utf-8",
            )
            (build / "config.h").write_text(
                "\n".join(
                    f"#define {macro} 1" for macro in (
                        "ENABLE_RENDER_SERVER", "ENABLE_RENDER_SERVER_WORKER_THREAD",
                        "ENABLE_SAME_PROCESS_RENDER_SERVER", "ENABLE_VENUS",
                        "HAVE_EPOXY_EGL_H",
                    )
                ),
                encoding="utf-8",
            )
            (build / "meson-logs/meson-log.txt").write_text(
                "Run-time dependency epoxy found: YES 1.5.11\n"
                "Run-time dependency vulkan found: YES 1.4.0\n",
                encoding="utf-8",
            )
            commands = build / "compile_commands.json"
            graph = [
                {"file": f"../virglrenderer/{source}"}
                for source in classic + venus + transport
            ]
            commands.write_text(json.dumps(graph), encoding="utf-8")
            tuple_command("verify-meson", "--build-dir", build)
            commands.write_text(
                json.dumps([
                    entry for entry in graph
                    if not entry["file"].endswith(classic[0])
                ]),
                encoding="utf-8",
            )
            result = tuple_command("verify-meson", "--build-dir", build, ok=False)
            self.assertIn("missing required classic VirGL2/ANGLE source", result.stdout)
            commands.write_text(
                json.dumps(
                    graph + [{"file": "../virglrenderer/src/vtest/vtest_renderer.c"}]
                ),
                encoding="utf-8",
            )
            result = tuple_command("verify-meson", "--build-dir", build, ok=False)
            self.assertIn("forbidden source fragment", result.stdout)

    def test_build_packaging_and_qualification_consumers_are_dual_and_closed(self) -> None:
        dependencies = (
            REPO / "scripts/build-renderer-production-dependencies.sh"
        ).read_text()
        virgl = (REPO / "scripts/build-virglrenderer.sh").read_text()
        package = PACKAGE.read_text()
        assembler = ASSEMBLER.read_text()
        xcode = (REPO / "scripts/xcode-package-renderer-production.sh").read_text()
        abi = (REPO / "scripts/verify-virgl-resource-info-abi.c").read_text()

        for authority in (
            'install_name_tool -id "@loader_path/$angle_name"',
            "libEGL.dylib", "libGLESv2.dylib", "lib/libepoxy.a",
            "cmd LC_RPATH", "@loader_path/../Frameworks/libEGL.dylib",
            "@loader_path/../Frameworks/libGLESv2.dylib",
        ):
            self.assertIn(authority, dependencies)
        self.assertIn("Source/ThirdParty/ANGLE", dependencies)
        self.assertIn("verify_angle_runtime_library", dependencies)
        self.assertIn("MVK_HIDE_VULKAN_SYMBOLS=1", dependencies)

        self.assertIn("-Dplatforms=egl", virgl)
        self.assertIn("-Dvenus-only=false", virgl)
        self.assertNotIn("-Dvenus-only=true", virgl)
        self.assertIn("-DDORY_VIRGL_RENDERER_STATIC_LINKED", virgl)
        self.assertIn("-DDORY_VIRGL_RENDERER_DUAL_METAL", virgl)
        self.assertEqual(virgl.count("-Wl,-force_load"), 3)
        self.assertIn('"requiredVirGLCapsets": [2, 4]', virgl)

        self.assertIn("-Xcc -DDORY_VIRGL_RENDERER_STATIC_LINKED", assembler)
        self.assertIn("-Xcc -DDORY_VIRGL_RENDERER_DUAL_METAL", assembler)
        self.assertEqual(assembler.count("-Xlinker -force_load"), 3)
        self.assertLess(
            assembler.index(
                "for angle_name in libEGL.dylib libGLESv2.dylib; do\n"
                "  /usr/bin/codesign"
            ),
            assembler.index('"${CODESIGN_ARGUMENTS[@]}" "$WORKER_BUNDLE"'),
        )
        self.assertIn("verify_angle_runtime_closure", package)
        self.assertIn("if macho_rpaths(library)", package)
        self.assertIn("non-system/non-sibling dependency", package)
        self.assertIn("DORY_VIRGL_RENDERER_DUAL_METAL", package)
        self.assertIn("rendererReleaseQualificationEvidence", package)
        self.assertIn("--require-release-signature", package)
        self.assertIn("verify-renderer-bootstrap-qualification.py", package)
        self.assertIn("--allow-unsealed-staging", package)
        self.assertIn("renderer-virgl-metal-shared-texture-probe.m", virgl)
        shareable_scanout_patch = (
            REPO / "patches/virglrenderer-metal-shareable-scanout.patch"
        ).read_text()
        self.assertIn("newSharedTextureWithDescriptor", shareable_scanout_patch)
        self.assertIn("desc->bind & VIRGL_RES_BIND_SCANOUT", shareable_scanout_patch)
        self.assertNotIn("desc->bind & PIPE_BIND_SCANOUT", shareable_scanout_patch)
        shared_texture_probe = (
            REPO / "scripts/renderer-virgl-metal-shared-texture-probe.m"
        ).read_text()
        self.assertIn(".bind = VIRGL_RES_BIND_RENDER_TARGET", shared_texture_probe)
        self.assertIn("VIRGL_RES_BIND_SCANOUT != PIPE_BIND_SCANOUT", shared_texture_probe)
        venus_transport_patch = (
            REPO / "patches/virglrenderer-venus-only-static.patch"
        ).read_text()
        self.assertIn(
            "+      uint32_t proxy_flags = flags | VIRGL_RENDERER_NO_VIRGL;",
            venus_transport_patch,
        )
        self.assertIn(
            '+      if (!getenv("VIRGL_DISABLE_MT"))',
            venus_transport_patch,
        )
        self.assertIn(
            "+         proxy_flags |= VIRGL_RENDERER_THREAD_SYNC;",
            venus_transport_patch,
        )
        self.assertIn(
            "+      ret = proxy_renderer_init(&proxy_cbs, proxy_flags);",
            venus_transport_patch,
        )
        self.assertIn(
            "+#if defined(ENABLE_VENUS_ONLY) && defined(__APPLE__)",
            venus_transport_patch,
        )
        self.assertNotIn(
            "+#if defined(__APPLE__)\n+   has_thread_sync_notification = true;",
            venus_transport_patch,
        )
        self.assertIn(
            "+   if (!has_thread_sync_notification || getenv(\"VIRGL_DISABLE_MT\"))\n"
            "       flags &= ~VIRGL_RENDERER_THREAD_SYNC;",
            venus_transport_patch,
        )
        self.assertNotIn("+   flags |= VIRGL_RENDERER_THREAD_SYNC;", venus_transport_patch)

        order = [
            '"$ROOT/scripts/assemble-renderer-production-worker.sh"',
            'python3 "$ROOT/scripts/package-renderer-production-bundle.py" package',
            "/usr/bin/codesign \\",
            '"$RUNNER_APP/Contents/MacOS/dory-hv" renderer-qualify',
            'install -m0644 "$STAGED_RECEIPT"',
            'python3 "$ROOT/scripts/package-renderer-production-bundle.py" seal-evidence',
        ]
        positions = [xcode.index(fragment) for fragment in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("DORY_RENDERER_MANAGED_KERNEL_SHA256", xcode)
        self.assertIn("DORY_RENDERER_MANAGED_KERNEL", xcode)
        self.assertIn("DORY_RENDERER_QUALIFICATION_MODE", xcode)
        self.assertIn("--require-release-signature", xcode)

        for constant in (
            "DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET",
            "DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW",
            "DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT",
        ):
            self.assertIn(constant, abi)

    def test_cdhash_shape_is_strict(self) -> None:
        namespace = runpy.run_path(str(PACKAGE))
        validate_cdhash = namespace["code_directory_hash"]
        error = namespace["PackagingError"]
        self.assertEqual(validate_cdhash("a" * 40, "fixture"), "a" * 40)
        for invalid in ("a" * 39, "a" * 41, "0" * 40, "g" * 40):
            with self.subTest(invalid=invalid), self.assertRaises(error):
                validate_cdhash(invalid, "fixture")

    def test_qualification_codesign_requirement_is_an_expression(self) -> None:
        namespace = runpy.run_path(str(QUALIFICATION_VERIFIER))
        completed = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(namespace["subprocess"], "run", return_value=completed) as run_mock:
            namespace["verify_code_identity"](
                pathlib.Path("/tmp/DoryHVRunner.app"),
                'anchor apple generic and identifier "com.pythonxi.Dory.HVRunner"',
                check_nested=True,
            )
        command = run_mock.call_args.args[0]
        requirement_index = command.index("-R") + 1
        self.assertEqual(
            command[requirement_index],
            '=anchor apple generic and identifier "com.pythonxi.Dory.HVRunner"',
        )

    def test_qualification_accepts_parent_alias_but_rejects_symlink_bundle(self) -> None:
        namespace = runpy.run_path(str(QUALIFICATION_VERIFIER))
        direct_bundle_path = namespace["direct_bundle_path"]
        verification_error = namespace["VerificationError"]
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            authority = root / "authority"
            authority.mkdir()
            runner = authority / "DoryHVRunner.app"
            runner.mkdir()
            alias = root / "alias"
            alias.symlink_to(authority, target_is_directory=True)

            self.assertEqual(
                direct_bundle_path(alias / "DoryHVRunner.app"),
                runner.resolve(strict=True),
            )

            indirect_runner = root / "Indirect.app"
            indirect_runner.symlink_to(runner, target_is_directory=True)
            with self.assertRaises(verification_error):
                direct_bundle_path(indirect_runner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
