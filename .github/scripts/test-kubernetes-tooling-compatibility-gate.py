#!/usr/bin/env python3
"""Offline contract for the exact Kubernetes tooling compatibility gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "kubernetes-tooling-compatibility-gate.sh"


class KubernetesToolingCompatibilityGateTests(unittest.TestCase):
    def test_gate_binds_candidate_tools_control_plane_workloads_and_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-KUBERNETES-TOOLING",
            "socket is not owned by the release user",
            "$helper_name helper must be an absolute path",
            "$helper_name helper is unavailable or indirect",
            "tool cache tilt.tgz is missing or indirect",
            "tool cache skaffold is missing or indirect",
            "verified Tilt archive did not contain a direct regular binary",
            "re.escape(version)",
            '"$KUBECTL" version --client -o json',
            'shasum -a 256 "$DOCKER"',
            'shasum -a 256 "$KUBECTL"',
            'docker_e run -d --pull=never --privileged --name "$K3S_CONTAINER"',
            'dory.release.kubernetes-tooling.run=$RUN_ID',
            "nested k3s container does not use the exact qualified image",
            "nested k3s control plane unexpectedly binds host paths",
            'binding.get("HostIp") != "127.0.0.1"',
            're.fullmatch(r"127\\.0\\.0\\.1:([0-9]{1,5})\\n?", text)',
            'servers != ["https://127.0.0.1:6443"]',
            "host Kubernetes API connection failed at stability sample",
            "expected exactly one qualified workload pod",
            "workload pod does not declare the exact qualified image",
            "runtime workload image has no immutable image ID",
            "ingress_only_network_policy_egress=PASS",
            'docker_e rm -f -v "$k3s_container_id"',
            'label=dory.release.kubernetes-tooling.run=$RUN_ID',
            "k3s_container_exact_image=PASS",
            "privileged_nested_control_plane=PASS",
            "exact_workload_image=PASS",
            "docker_cli_sha256=",
            "kubectl_sha256=",
            "tilt_binary_sha256=",
            "skaffold_binary_sha256=",
            "owned_container_cleanup=PASS",
            "exact_baseline_cleanup=PASS",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            "dory-k8s-tooling-gate",
            "cleanup_objects",
            'ids="$(docker_e ps -aq)"',
            "docker_e volume rm",
            "docker_e network rm",
            "assert ",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_helpers_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--kubectl",
                    "/missing/kubectl",
                    "--workroot",
                    str(workroot),
                    "--k3s-image",
                    "invalid",
                    "--workload-image",
                    "invalid",
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
