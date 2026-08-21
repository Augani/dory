#!/usr/bin/env python3
"""Offline contracts for the exact Supabase CLI and service-image qualification gate."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "supabase-compatibility-gate.sh"
INVENTORY = ROOT / ".github" / "fixtures" / "supabase-cli-2.109.1-images.json"


class SupabaseCompatibilityGateTests(unittest.TestCase):
    def test_inventory_is_closed_and_digest_pinned(self) -> None:
        document = json.loads(INVENTORY.read_text(encoding="utf-8"))
        self.assertEqual(
            set(document), {"schemaVersion", "cliVersion", "registry", "services"}
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["cliVersion"], "2.109.1")
        self.assertEqual(document["registry"], "public.ecr.aws")
        services = document["services"]
        self.assertEqual(len(services), 14)
        self.assertEqual(sum(item["enabledByDefault"] for item in services), 13)
        self.assertEqual(len({item["service"] for item in services}), 14)
        self.assertEqual(len({item["runtime"] for item in services}), 14)
        for service in services:
            self.assertEqual(
                set(service),
                {"service", "source", "runtime", "digest", "enabledByDefault"},
            )
            self.assertRegex(
                service["runtime"],
                r"^public\.ecr\.aws/supabase/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$",
            )
            self.assertRegex(service["digest"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(
            {item["service"] for item in services if not item["enabledByDefault"]},
            {"pooler"},
        )

    def test_gate_binds_cli_inventory_runtime_behavior_and_secret_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-SUPABASE",
            "socket is not owned by the release user",
            "Docker CLI is unavailable or indirect",
            "--inventory is required for a non-default Supabase version",
            "Supabase image inventory has an unexpected top-level shape",
            "Supabase default stack must contain exactly 13 enabled service images",
            "Docker-Content-Digest",
            "Supabase registry digest changed",
            'docker_e pull "$runtime@$digest"',
            'docker_e tag "$runtime@$digest" "$runtime"',
            "verified Supabase archive did not contain direct CLI executables",
            "full Supabase default stack did not create exactly 13 owned containers",
            "Supabase service image is not bound to its approved digest",
            "com.supabase.cli.project",
            "Supabase REST round-trip returned unexpected rows",
            "required Supabase default host port is already in use",
            "Supabase port $port was widened to all host interfaces",
            '> /dev/null 2> "$EVIDENCE/start.stderr"',
            "secret_free_evidence=PASS",
            "exact_service_image_inventory=PASS",
            "owned_project_cleanup=PASS",
            "exact_baseline_cleanup=PASS",
            "supabase_binary_sha256=",
            "image_inventory_sha256=",
            "docker_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in (
            "ids=\"$(docker_e ps -aq)\"",
            "docker_e volume ls -q);",
            "assert ",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_registry_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--inventory", str(INVENTORY),
                    "--workroot", str(workroot),
                ],
                cwd=ROOT,
                env={**os.environ, "HOME": temporary},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
