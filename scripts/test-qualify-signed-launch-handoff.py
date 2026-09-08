#!/usr/bin/env python3
"""Offline contract for the signed application-launch handoff qualification harness."""

from __future__ import annotations

import json
import array
import importlib.util
import os
import socket
import struct
import tempfile
from unittest import mock
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts/qualify-signed-launch-handoff.py"
PEER = ROOT / "scripts/fixtures/signed-launch-handoff-peer.c"


class SignedLaunchHandoffHarnessTests(unittest.TestCase):
    def test_case_inventory_is_explicit_and_complete(self) -> None:
        result = subprocess.run(
            ["python3", str(HARNESS), "--list"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["cases"],
            ["valid-peer", "wrong-team", "wrong-identity", "unsigned", "absent", "malformed"],
        )

    def load_harness(self):
        spec = importlib.util.spec_from_file_location("handoff_harness", HARNESS)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_timeout_and_invalid_invitation_reap_peer_and_remove_owned_directory(self):
        harness = self.load_harness()
        real_popen = subprocess.Popen
        for invalid in [False, True]:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                peer = Path(directory) / "peer"
                invitation = '"X" * 2048' if invalid else '"READY " + sys.argv[1] + "/h.sock " + "a" * 64'
                peer.write_text("#!/usr/bin/env python3\nimport sys, time\nprint(" + invitation + ", flush=True)\ntime.sleep(60)\n")
                peer.chmod(0o755)
                processes = []
                scratch = []
                def start(command, **options):
                    scratch.append(Path(command[1]))
                    process = real_popen(command, **options)
                    processes.append(process)
                    return process
                with mock.patch.object(harness.subprocess, "Popen", side_effect=start), \
                     mock.patch.object(harness.subprocess, "run", side_effect=subprocess.TimeoutExpired("runner", 25)) as runner:
                    expected = harness.QualificationError if invalid else subprocess.TimeoutExpired
                    with self.assertRaises(expected):
                        harness.run_with_peer(Path("unused-runner"), peer)
                    if not invalid:
                        self.assertEqual(runner.call_args.kwargs["env"]["DORY_TEST_BYPASS_DAEMON_AUTH"], "1")
                self.assertIsNotNone(processes[0].poll())
                self.assertFalse(scratch[0].exists())

    def test_compiled_peer_exchanges_token_descriptor_and_acknowledgement(self):
        harness = self.load_harness()
        with tempfile.TemporaryDirectory(prefix="dory-peer-test-", dir="/tmp") as directory:
            root = Path(directory)
            peer = root / "peer"
            harness.compile_peer(peer)
            scratch = root / "scratch"
            scratch.mkdir(mode=0o700)
            process = subprocess.Popen([str(peer), str(scratch)], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                path, token = harness.wait_for_ready(process)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(3)
                    connection.connect(path)
                    connection.sendall(struct.pack("!I", len(token)) + token.encode())
                    def read_exact(count):
                        value = b""
                        while len(value) < count:
                            chunk = connection.recv(count - len(value))
                            self.assertTrue(chunk)
                            value += chunk
                        return value
                    length, = struct.unpack("!I", read_exact(4))
                    self.assertEqual(json.loads(read_exact(length)), {"schemaVersion": 1, "targetDescriptors": [900]})
                    marker, controls, flags, _ = connection.recvmsg(1, socket.CMSG_SPACE(array.array("i").itemsize))
                    self.assertEqual(marker, b"\xd4")
                    self.assertEqual(flags & socket.MSG_CTRUNC, 0)
                    self.assertEqual(len(controls), 1)
                    level, kind, data = controls[0]
                    self.assertEqual((level, kind), (socket.SOL_SOCKET, socket.SCM_RIGHTS))
                    descriptors = array.array("i")
                    descriptors.frombytes(data)
                    try:
                        self.assertEqual(len(descriptors), 1)
                        self.assertEqual(os.read(descriptors[0], 1), b"")
                    finally:
                        for descriptor in descriptors:
                            os.close(descriptor)
                    connection.sendall(b"\xa7")
                output, error = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, error)
                self.assertIn("RESULT token=1 descriptor=1 acknowledgement=1", output)
                self.assertFalse((scratch / "h.sock").exists())
            finally:
                harness.terminate(process)


if __name__ == "__main__":
    unittest.main()
