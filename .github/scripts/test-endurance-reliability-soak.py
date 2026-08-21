#!/usr/bin/env python3
"""Offline contract for the eight-hour endurance reliability release soak."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "endurance-reliability-soak.sh"
ANALYZER = ROOT / "scripts" / "analyze-endurance-resources.py"
HEADER = (
    "phase\tcycle\tepoch\tpid_count\tfd_total\trss_kb\tcpu_percent\tstate_kb\t"
    "fseventsd_pid_count\tfseventsd_rss_kb\tfseventsd_cpu_percent\n"
)


class EnduranceReliabilitySoakTests(unittest.TestCase):
    def test_gate_binds_isolated_candidate_resources_and_terminal_evidence(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        subprocess.run(["python3", "-m", "py_compile", str(ANALYZER)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-ENDURANCE-RELIABILITY",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "state directory must be a direct canonical path",
            "process root must exactly equal the state directory",
            "dory-dataplane-proxy|gvproxy",
            "Docker CLI must be a direct canonical path",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "release candidate evidence cannot use --cycles",
            "release candidate duration must be at least eight hours",
            "release candidate image must be digest-pinned",
            "release candidate fixture must resolve to linux/arm64",
            "release candidate FD growth budget is too permissive",
            "DOCKER_CONTEXT",
            "COMPOSE_PROJECT_NAME",
            'bounded 120 docker_raw "$@"',
            "resource analyzer is unavailable or indirect",
            "resource analyzer changed during the soak",
            "isolated Docker socket identity changed during the soak",
            "isolated state authority changed during the soak",
            "Docker CLI changed during the soak",
            "endurance gate changed during the soak",
            "endurance soak changed the exact fixture image identity",
            "guest ownership request changed host bind ownership",
            "duration-based soak ended before its requested wall time",
            "cycles_sha256=",
            "resources_sha256=",
            "resource_analysis_sha256=",
            "analyzer_sha256=",
            "same_user_socket=PASS",
            "exact_process_authority=PASS",
            "exact_image_identity=PASS",
            "resource_plateau=PASS",
            "owned_cleanup=PASS",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" docker',
            'echo "socket=$SOCKET"',
            'echo "state_dir=$STATE_DIR"',
            'echo "process_root=$PROCESS_ROOT"',
            "DORY_ENDURANCE_SOURCE_ONLY",
        ):
            self.assertNotIn(unsafe, text, unsafe)

    def test_confirmation_fails_before_socket_state_cli_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            workroot = root / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--socket",
                    str(root / "missing.sock"),
                    "--state-dir",
                    str(root / "missing-state"),
                    "--docker",
                    "/missing/docker",
                    "--image",
                    "invalid",
                    "--process-root",
                    str(root / "missing-state"),
                    "--workroot",
                    str(workroot),
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

    def test_analyzer_accepts_exact_plateau_and_rejects_bad_schema_and_nan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            valid = root / "valid.tsv"
            valid.write_text(
                HEADER
                + "baseline\t0\t100\t2\t10\t1000\t1.0\t2000\t1\t3000\t1.0\n"
                + "cleaned\t1\t110\t2\t11\t1010\t1.0\t2010\t1\t3010\t1.0\n"
                + "final\t1\t120\t2\t11\t1010\t1.0\t2010\t1\t3010\t1.0\n",
                encoding="utf-8",
            )
            args = [
                "python3",
                str(ANALYZER),
                str(valid),
                "--fd-growth",
                "16",
                "--rss-growth-mb",
                "384",
                "--disk-growth-mb",
                "256",
                "--idle-cpu",
                "25",
                "--fseventsd-rss-growth-mb",
                "128",
                "--fseventsd-cpu",
                "25",
            ]
            result = subprocess.run(args, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("resource plateau PASS", result.stdout)

            bad_schema = root / "bad-schema.tsv"
            bad_schema.write_text(HEADER.replace("phase", "unexpected") + "x\n", encoding="utf-8")
            result = subprocess.run(args[:2] + [str(bad_schema)] + args[3:], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected schema", result.stderr)

            invalid = root / "invalid.tsv"
            invalid.write_text(valid.read_text(encoding="utf-8").replace("1.0", "nan", 1), encoding="utf-8")
            result = subprocess.run(args[:2] + [str(invalid)] + args[3:], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("finite and non-negative", result.stderr)


if __name__ == "__main__":
    unittest.main()
