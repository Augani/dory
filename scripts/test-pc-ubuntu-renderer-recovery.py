#!/usr/bin/env python3
"""PC campaign regression fixtures. Synthetic model evidence is never hardware qualification."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pc_recovery_model", ROOT / "scripts/test-arm-ubuntu-renderer-recovery.py")
model = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model)
recovery, lifecycle = model.recovery, model.lifecycle
MACHINE, SERVICE = "wave0-pc-gpu-unit", "dev.dory.wave0.pcgpu.unit"
PROFILE = dict(architecture="x86_64", network="disconnected", graphics_backend="virgl-venus")


def authorization():
    return {"kind": "dev.dory.virtual-machine-candidate-campaign-authorization", "schemaVersion": 2,
            "applicationRoot": str(model.APP), "machineIDPrefix": "wave0-pc-gpu-",
            "candidateInventorySHA256": model.CANDIDATE,
            "cells": [{"capability": {"backend": "dory-hypervisor", "guest": {"architecture": "x86_64", "family": "linux"},
                                       "graphics": "hardware-accelerated-3d"},
                       "faultPolicy": {"permittedFaults": [recovery.CRASH_FAULT], "maximumArmingCount": 1,
                                       "maximumArmedMilliseconds": 10000}}]}


class PCPolicyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="dory-pc-recovery-policy-")
        self.addCleanup(temp.cleanup)
        self.evidence = lifecycle.Evidence(Path(temp.name))
        self.evidence.write("campaign-authority.json", authorization())

    def test_pc_requires_exact_renderer_only_hardware_cell(self):
        self.assertEqual(recovery.crash_policy(self.evidence, "x86_64"), 10000)
        for field, value in [("graphics", "software"), ("backend", "apple-virtualization"),
                             ("guest", {"architecture": "arm64", "family": "linux"})]:
            body = authorization()
            body["cells"][0]["capability"][field] = value
            (self.evidence.directory / "campaign-authority.json").write_text(json.dumps(body))
            with self.subTest(field=field), self.assertRaises(lifecycle.LifecycleError):
                recovery.crash_policy(self.evidence, "x86_64")
        body = authorization()
        body["cells"][0]["faultPolicy"]["permittedFaults"] = ["fs-worker-sigkill", recovery.CRASH_FAULT]
        (self.evidence.directory / "campaign-authority.json").write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError): recovery.crash_policy(self.evidence, "x86_64")

    def test_foreign_namespace_and_missing_policy_reject_before_dispatch(self):
        for machine, service in [(model.MACHINE, model.SERVICE), (MACHINE, "dev.dory.doryd"),
                                 (MACHINE, SERVICE + ".other")]:
            campaign = model.ModelCampaign(self.evidence, mode="unexpected-worker-crash", machine=machine, service=service, **PROFILE)
            with self.subTest(service=service), self.assertRaises(lifecycle.LifecycleError):
                recovery.run_recovery(campaign, model.PLAN)
            self.assertEqual(campaign.calls, [])
        body = authorization(); body["cells"] = []
        (self.evidence.directory / "campaign-authority.json").write_text(json.dumps(body))
        campaign = model.ModelCampaign(self.evidence, mode="unexpected-worker-crash", machine=MACHINE, service=SERVICE, **PROFILE)
        with self.assertRaises(lifecycle.LifecycleError): recovery.run_recovery(campaign, model.PLAN)
        self.assertEqual(campaign.calls, [])

    def test_guest_and_daemon_isa_backend_network_and_installer_are_bound(self):
        campaign = model.ModelCampaign(self.evidence, mode="unexpected-worker-crash", machine=MACHINE, service=SERVICE, **PROFILE)
        baseline = campaign.status()
        recovery.check_runtime(baseline, campaign)
        for key, value in [("guestArchitecture", "arm64"), ("installerMediaAttached", True), ("state", "stopped")]:
            body = copy.deepcopy(baseline); body[key] = value
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): recovery.check_runtime(body, campaign)
        body = copy.deepcopy(baseline); body["runtimeGraphicsSelection"]["backend"] = "virgl"
        with self.assertRaises(lifecycle.LifecycleError): recovery.check_runtime(body, campaign)
        body = copy.deepcopy(baseline); body["typedSettings"]["networkMode"] = "shared-nat"
        with self.assertRaises(lifecycle.LifecycleError): recovery.check_runtime(body, campaign)
        for level in (None, "software", "software-fallback"):
            body = copy.deepcopy(baseline)
            body["runtimeGraphicsSelection"]["accelerationLevel"] = level
            with self.subTest(level=level), self.assertRaises(lifecycle.LifecycleError): recovery.check_runtime(body, campaign)
        # Both real PC runtime profiles are supported, never an ARM receipt relabeled as PC.
        campaign.graphics_backend = "virgl"
        body = copy.deepcopy(baseline); body["runtimeGraphicsSelection"]["backend"] = "virgl"
        recovery.check_runtime(body, campaign)
        guest = model.journey.observation(number=7, network="disconnected")
        guest["nonce"] = model.NONCE
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.check_guest(guest, "boot", model.NONCE, "disconnected", architecture="x86_64")
        guest["architecture"] = "x86_64"
        lifecycle.check_guest(guest, "boot", model.NONCE, "disconnected", architecture="x86_64")

    def test_pc_collector_cannot_enter_arm_install_or_fault_driver(self):
        result = subprocess.run(["bash", str(recovery.DRIVER), "--guest-architecture", "x86_64"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("PC capture cannot execute the ARM install/lifecycle/fault campaign", result.stderr)

    def test_pc_cannot_enter_arm_only_controlled_restart_route(self):
        with self.assertRaises(lifecycle.LifecycleError):
            model.ModelCampaign(self.evidence, mode="controlled-restart", machine=MACHINE, service=SERVICE, **PROFILE)
        command = [sys.executable, str(ROOT / "scripts/pc-ubuntu-renderer-recovery.py"), "--app", str(model.APP),
                   "--machine", MACHINE, "--mach-service", SERVICE, "--run-directory", str(self.evidence.directory),
                   "--mode", "controlled-restart"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice: 'controlled-restart'", result.stderr)

    def test_shortest_eligible_pc_window_is_used_and_invalid_budgets_reject(self):
        body = authorization()
        shorter = copy.deepcopy(body["cells"][0]); shorter["faultPolicy"]["maximumArmedMilliseconds"] = 1500
        body["cells"].append(shorter)
        path = self.evidence.directory / "campaign-authority.json"
        path.write_text(json.dumps(body))
        self.assertEqual(recovery.crash_policy(self.evidence, "x86_64"), 1500)
        for field, value in [("maximumArmingCount", True), ("maximumArmingCount", 9),
                             ("maximumArmedMilliseconds", 0), ("maximumArmedMilliseconds", 30001),
                             ("maximumArmedMilliseconds", 1.5)]:
            body = authorization(); body["cells"][0]["faultPolicy"][field] = value
            path.write_text(json.dumps(body))
            with self.subTest(field=field, value=value), self.assertRaises(lifecycle.LifecycleError):
                recovery.crash_policy(self.evidence, "x86_64")


class PCReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="dory-pc-recovery-replay-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name) / "evidence"
        cls.root.mkdir()
        cls.app = Path(cls.temp.name) / "Dory.app"
        (cls.app / "Contents/MacOS").mkdir(parents=True)
        (cls.app / "Contents/MacOS/Dory").write_bytes(b"synthetic-app-not-executable")
        cls.evidence = lifecycle.Evidence(cls.root)
        authority = authorization(); authority["applicationRoot"] = str(cls.app)
        authority["candidateInventorySHA256"] = lifecycle.digest(b"{}")
        cls.evidence.write("campaign-authority.json", authority)
        cls.campaign = model.ModelCampaign(cls.evidence, mode="unexpected-worker-crash", machine=MACHINE,
                                          service=SERVICE, app=cls.app, **PROFILE)
        with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
            cls.verdict = recovery.run_recovery(cls.campaign, model.PLAN)

    def rehash(self):
        proof = self.evidence.read(recovery.PROOF)
        proof["references"] = self.evidence.references(proof["observations"])
        (self.root / recovery.PROOF).write_text(json.dumps(proof))

    def state_replay(self):
        # These tests mutate state receipts, not pixels. The baseline was independently replayed
        # by the real oracle in setUpClass; caching avoids redoing it for unrelated state errors.
        def cached_pixels(directory, _nonce):
            phase = "before" if directory.name.endswith("before-redraw") else "after"
            return self.evidence.read("renderer-recovery-" + phase + "-capture.json")["verification"]
        with patch.object(recovery.pixels, "verify", side_effect=cached_pixels):
            return recovery.verify_recovery(self.evidence, MACHINE, SERVICE, self.app, **PROFILE)

    def test_actual_oracle_replayed_pc_crash_without_guest_restart(self):
        self.assertEqual(self.verdict["guestArchitecture"], "x86_64")
        self.assertEqual(self.verdict["mode"], "unexpected-worker-crash")
        self.assertEqual(self.verdict["afterRendererGeneration"], 8)
        proof = self.evidence.read(recovery.PROOF)
        self.assertTrue(proof["unexpectedRendererDeathTested"])
        self.assertFalse(proof["survivingGPUContextVerified"])
        self.assertFalse(proof["releaseEligible"])
        self.assertFalse(any(call[0] in {"start", "stop", "update", "restart"} for call in self.campaign.calls))
        self.assertIn("scripts/pc-ubuntu-renderer-recovery.py", proof["sourceSHA256"])
        self.assertEqual(self.state_replay(), self.verdict)

    def test_virgl_profile_replays_its_own_pc_crash_and_gl_probe(self):
        with tempfile.TemporaryDirectory(prefix="dory-pc-virgl-recovery-") as directory:
            evidence = lifecycle.Evidence(Path(directory))
            evidence.write("campaign-authority.json", authorization())
            profile = dict(PROFILE, graphics_backend="virgl")
            campaign = model.ModelCampaign(evidence, mode="unexpected-worker-crash", machine=MACHINE, service=SERVICE, **profile)
            with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
                verdict = recovery.run_recovery(campaign, model.PLAN)
            self.assertEqual(verdict["runtimeGraphicsBackend"], "virgl")
            probe = json.loads((Path(directory) / "renderer-recovery-after-redraw/gpu-probe.json").read_text())
            self.assertEqual(probe["driver"], "virgl")
            self.assertFalse(verdict["releaseEligible"])

    def test_rehashed_boot_or_process_replacement_rejects(self):
        proof = self.evidence.read(recovery.PROOF)
        name = next(name for name in reversed(proof["observations"]) if name.endswith("observe.json") and "crash" not in name)
        path = self.root / name; original = path.read_bytes()
        try:
            for key, value in [("bootID", model.journey.boot(999)), ("processID", 333),
                               ("processStartTicks", 1001), ("volatileMemorySHA256", "b" * 64)]:
                raw = json.loads(original); guest = json.loads(json.loads(raw["stdout"])["stdout"])
                guest["observation"][key] = value
                if key == "processID": guest["mainPID"] = value
                transport = json.loads(raw["stdout"]); transport["stdout"] = json.dumps(guest)
                raw["stdout"] = json.dumps(transport); path.write_text(json.dumps(raw)); self.rehash()
                with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.state_replay()
        finally:
            path.write_bytes(original); self.rehash()

    def test_profile_or_source_relabeling_rejects(self):
        path = self.root / recovery.PROOF; original = path.read_bytes()
        try:
            for key, value in [("guestArchitecture", "arm64"), ("networkMode", "shared-nat"),
                               ("runtimeGraphicsBackend", "virgl"), ("sourceSHA256", {})]:
                proof = json.loads(original); proof[key] = value; path.write_text(json.dumps(proof))
                with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.state_replay()
        finally: path.write_bytes(original)

    def test_coherent_arm_build_receipt_cannot_fill_pc_capture(self):
        root = self.root / "renderer-recovery-after-redraw"
        names = ["gpu-probe-build-receipt.txt", "gpu-display-evidence.json", "gpu-probe-build-transport.json",
                 "window-capture.json", "graphics-correlation.json"]
        original = {name: (root / name).read_bytes() for name in names}
        capture_path = self.root / "renderer-recovery-after-capture.json"
        capture_original = capture_path.read_bytes()
        try:
            receipt = root / names[0]
            receipt.write_text(receipt.read_text().replace("architecture=x86_64\n", "architecture=aarch64\n"))
            model.PIXELS["refresh_chain"](root)
            transport = json.loads((root / names[2]).read_text()); transport["stdout"] = receipt.read_text()
            (root / names[2]).write_text(json.dumps(transport))
            raw = json.loads(capture_original); raw["files"] = recovery.capture_files(root)
            capture_path.write_text(json.dumps(raw)); self.rehash()
            with self.assertRaises(recovery.pixels.BUILD_RECEIPT.BuildReceiptError): self.state_replay()
        finally:
            for name, data in original.items(): (root / name).write_bytes(data)
            capture_path.write_bytes(capture_original); self.rehash()

    def test_pc_wrapper_replays_only_the_selected_isa_and_backend(self):
        command = [sys.executable, str(ROOT / "scripts/pc-ubuntu-renderer-recovery.py"), "--verify-only",
                   "--app", str(self.app), "--machine", MACHINE, "--mach-service", SERVICE,
                   "--run-directory", str(self.root), "--gpu-profile", "venus"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.verdict)
        command[-1] = "virgl"
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("ISA, network, backend or source changed", result.stderr)

    def test_outer_manifest_requires_full_replay_before_expanding_scope(self):
        # Run the exact live gate's receipt writer with synthetic inputs. This tests its join,
        # not launchd, a signed application, or physical GPU qualification.
        inputs = Path(self.temp.name) / "manifest-inputs"
        inputs.mkdir()
        for name in ("daemon", "control", "runner", "installer.iso", "signature"):
            (inputs / name).write_bytes(name.encode())
        candidate = inputs / "candidate"; candidate.mkdir()
        (candidate / "component-candidate-inventory.json").write_bytes(b"{}")
        results = self.root / "results.tsv"
        results.write_text("check\tstatus\tdetail\nrenderer-recovery\tPASS\tsynthetic model\n")
        source = (ROOT / "scripts/pc-gpu-daemon-live-gate.sh").read_text()
        writer = source.split("<<'PYMANIFEST'\n", 1)[1].split("\nPYMANIFEST\n", 1)[0]
        manifest = self.root / "manifest.json"
        command = [sys.executable, "-c", writer, str(manifest), str(self.app), str(inputs / "daemon"),
                   str(inputs / "control"), str(inputs / "runner"), str(candidate), str(inputs / "installer.iso"),
                   SERVICE, MACHINE, str(results), "prepare-installed-guest", "prepared", "4096", "2", "900",
                   str(inputs), str(self.root / "campaign-authority.json"), str(inputs / "signature"),
                   "venus", "virgl-venus", str(self.root / recovery.PLAN), str(ROOT), "0", "disconnected"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = json.loads(manifest.read_text())
        self.assertFalse(body["releaseQualified"])
        self.assertEqual(body["rendererRecovery"], self.verdict)
        self.assertEqual(body["rendererRecoverySHA256"], lifecycle.digest((self.root / recovery.PROOF).read_bytes()))
        self.assertIn("replacement-worker-challenged-pixels", body["proofScope"])
        self.assertIn("surviving-gl-vulkan-contexts", body["unverified"])
        path = self.root / recovery.PROOF; original = path.read_bytes()
        try:
            forged = json.loads(original); forged["guestArchitecture"] = "arm64"
            path.write_text(json.dumps(forged))
            result = subprocess.run(command, text=True, capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ISA, network, backend or source changed", result.stderr)
        finally: path.write_bytes(original)


if __name__ == "__main__": unittest.main(verbosity=2)
