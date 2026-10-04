#!/usr/bin/env python3
"""Synthetic PC lifecycle regressions, not signed-candidate or physical qualification."""
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
SPEC = importlib.util.spec_from_file_location("pc_lifecycle_model", ROOT / "scripts/test-arm-ubuntu-desktop-lifecycle.py")
model = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model)
lifecycle = model.lifecycle
MACHINE, SERVICE = "wave0-pc-gpu-lifecycle", "dev.dory.wave0.pcgpu.lifecycle"
PROFILE = dict(architecture="x86_64", graphics_backend="virgl")


def authorization(app=model.APP):
    return {"kind": "dev.dory.virtual-machine-candidate-campaign-authorization", "schemaVersion": 2,
            "purpose": "candidate-qualification-campaign", "applicationRoot": str(app),
            "machineIDPrefix": "wave0-pc-gpu-", "candidateInventorySHA256": "e" * 64,
            "cells": [{"capability": {"backend": "dory-hypervisor", "guest": {"architecture": "x86_64", "family": "linux"},
                                       "graphics": "hardware-accelerated-3d"}}]}


class PCLifecycleTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="dory-pc-lifecycle-unit-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.evidence = lifecycle.Evidence(self.root)
        self.evidence.write("campaign-authority.json", authorization())
        self.campaign = model.ModelCampaign(self.evidence, machine=MACHINE, service=SERVICE, **PROFILE)

    def journey(self):
        return lifecycle.run_journey(self.campaign)

    def replay(self):
        return lifecycle.verify_readiness(self.evidence, MACHINE, SERVICE, model.APP, **PROFILE)

    def refresh(self, name):
        for phase in lifecycle.JOURNEY_PHASES:
            path = self.root / (phase + ".json")
            body = json.loads(path.read_text())
            if name in body["references"]:
                body["references"][name] = lifecycle.digest((self.root / name).read_bytes())
                path.write_text(json.dumps(body))
        readiness_path = self.root / "desktop-lifecycle-readiness.json"
        readiness = json.loads(readiness_path.read_text())
        readiness["references"] = self.evidence.references([phase + ".json" for phase in lifecycle.JOURNEY_PHASES])
        readiness_path.write_text(json.dumps(readiness))

    def mutate_control(self, phase, command, mutate):
        for name in self.evidence.read(phase + ".json")["references"]:
            raw = self.evidence.read(name)
            if raw.get("argv", [None] * 7)[6] == command:
                mutate(raw)
                (self.root / name).write_text(json.dumps(raw))
                self.refresh(name)
                return
        self.fail("missing model control")

    def test_full_pc_journey_and_source_bound_readiness_remain_unqualified(self):
        verdict = self.journey()
        self.assertEqual(self.replay(), verdict)
        self.assertEqual(verdict["guestArchitecture"], "x86_64")
        self.assertFalse(verdict["releaseEligible"])
        self.assertFalse(verdict["storageFaultInjectionVerified"])
        readiness = self.evidence.read("desktop-lifecycle-readiness.json")
        self.assertIn("scripts/pc-ubuntu-desktop-lifecycle.py", readiness["sourceSHA256"])
        self.assertIn(["update", MACHINE, "--network", "shared-nat"], self.campaign.calls)
        self.assertIn(["update", MACHINE, "--eject-installer"], self.campaign.calls)
        self.assertIn(["update", MACHINE, "--network", "disconnected"], self.campaign.calls)
        self.assertFalse(any(call[0] in {"create", "delete", "restart"} for call in self.campaign.calls))
        self.assertEqual(self.evidence.read("storage-recovery.json")["status"], "INCOMPLETE")

    def test_both_pc_profiles_replay_but_cannot_be_relabelled(self):
        self.campaign.graphics_backend = "virgl-venus"
        verdict = self.journey()
        self.assertEqual(verdict["runtimeGraphicsBackend"], "virgl-venus")
        with self.assertRaises(lifecycle.LifecycleError): self.replay()
        self.assertEqual(lifecycle.verify_readiness(self.evidence, MACHINE, SERVICE, model.APP,
                                                  architecture="x86_64", graphics_backend="virgl-venus"), verdict)

    def test_already_ejected_installer_handoff_does_not_eject_the_tools_disc(self):
        self.campaign.media = False
        self.journey()
        self.assertEqual(self.replay()["status"], "evidence-verified")
        self.assertFalse(any("--eject-installer" in args for args in self.campaign.calls))
        self.assertIn(["update", MACHINE, "--network", "shared-nat"], self.campaign.calls)

    def test_missing_or_wrong_signed_cell_rejects_before_commands(self):
        for key, value in [("machineIDPrefix", "readiness-arm-ubuntu-"), ("applicationRoot", "/another/Dory.app"),
                           ("candidateInventorySHA256", "not-a-hash"), ("purpose", "public-release"), ("cells", [])]:
            body = authorization(); body[key] = value
            (self.root / "campaign-authority.json").write_text(json.dumps(body))
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.journey()
            self.assertEqual(self.campaign.calls, [])

    def test_production_or_arm_namespace_rejects_before_commands(self):
        for machine, service in [("personal-vm", SERVICE), (MACHINE, "dev.dory.doryd"),
                                 (model.MACHINE, model.SERVICE), (MACHINE, SERVICE + ".other")]:
            self.campaign.machine, self.campaign.service = machine, service
            with self.subTest(machine=machine), self.assertRaises(lifecycle.LifecycleError): self.journey()
            self.assertEqual(self.campaign.calls, [])

    def test_rehashed_arm_guest_boot_and_wrong_x86_repository_reject(self):
        self.journey()
        def mutate(raw):
            transport = json.loads(raw["stdout"]); guest = json.loads(transport["stdout"])
            guest["architecture"] = "aarch64"
            transport["stdout"] = json.dumps(guest); raw["stdout"] = json.dumps(transport)
        self.mutate_control("cold-reopen", "exec", mutate)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_network_probe_must_use_x86_distro_repository(self):
        guest = model.observation(number=1)
        guest.update(architecture="x86_64", repositoryURL="https://ports.ubuntu.com/ubuntu-ports/dists/noble/Release")
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.check_guest(guest, "boot", model.NONCE, "shared-nat", architecture="x86_64")
        guest["repositoryURL"] = "https://archive.ubuntu.com/ubuntu/dists/noble/Release"
        lifecycle.check_guest(guest, "boot", model.NONCE, "shared-nat", architecture="x86_64")

    def test_rehashed_runtime_isa_backend_and_software_fallback_reject(self):
        self.journey()
        record = self.evidence.read("cold-reopen.json")
        name = next(name for name in record["references"] if self.evidence.read(name).get("argv", [None] * 7)[6] == "status")
        path = self.root / name; original = path.read_bytes()
        for key, value in [("guestArchitecture", "arm64"), ("backend", "virgl-venus"), ("accelerationLevel", "software")]:
            raw = json.loads(original); status = json.loads(raw["stdout"])
            (status if key == "guestArchitecture" else status["runtimeGraphicsSelection"])[key] = value
            raw["stdout"] = json.dumps(status); path.write_text(json.dumps(raw)); self.refresh(name)
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_snapshot_alias_rejects(self):
        self.journey()
        self.mutate_control("storage-recovery", "restore-snapshot", lambda raw: raw["argv"].__setitem__(8, "another-snapshot"))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_durable_bytes_and_foreign_window_reject(self):
        self.journey()
        def mutate(raw):
            transport = json.loads(raw["stdout"]); guest = json.loads(transport["stdout"])
            guest["payloadSHA256"] = "b" * 64
            transport["stdout"] = json.dumps(guest); raw["stdout"] = json.dumps(transport)
        self.mutate_control("cold-reopen", "exec", mutate)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_guest_reboot_cannot_replace_the_vm_even_with_a_matching_window(self):
        self.journey()
        operation = model.boot(999)
        def mutate(raw):
            status = json.loads(raw["stdout"]); status["runtimeGraphicsSelection"]["operationID"] = operation
            raw["stdout"] = json.dumps(status)
        self.mutate_control("guest-reboot", "status", mutate)
        name = "lifecycle-guest-reboot-window.json"
        window = self.evidence.read(name); window["operationID"] = operation
        (self.root / name).write_text(json.dumps(window)); self.refresh(name)
        with self.assertRaisesRegex(lifecycle.LifecycleError, "replaced the VM operation"): self.replay()

    def test_control_argument_injection_and_unbounded_transport_reject(self):
        self.journey()
        self.mutate_control("cold-reopen", "stop", lambda raw: raw["argv"].append("--unrequested-force"))
        with self.assertRaisesRegex(lifecycle.LifecycleError, "unrequested arguments"): self.replay()

    def test_unicode_or_oversized_exec_deadlines_are_cleanly_rejected(self):
        self.journey()
        record = self.evidence.read("package-update.json")
        name = next(iter(record["references"]))
        path = self.root / name; original = path.read_bytes()
        for value in ("²", "9" * 100, "7200001", "0"):
            raw = json.loads(original); raw["argv"][10] = value
            path.write_text(json.dumps(raw)); self.refresh(name)
            with self.subTest(value=value), self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_pc_login_template_cannot_retarget_another_machine_or_overwrite_evidence(self):
        source = self.root / "template.json"
        destination = self.root / "bound.json"
        body = {"kind": "dev.dory.display-qualification-keyboard-script", "schemaVersion": 1,
                "machineID": "wave0-pc-gpu-TEMPLATE", "steps": [{"delayMilliseconds": 100,
                    "events": [{"type": 1, "code": 30, "value": 1}, {"type": 1, "code": 30, "value": 0}]}]}
        source.write_text(json.dumps(body))
        self.assertEqual(lifecycle.bind_pc_login_template(source, destination, MACHINE, SERVICE), destination)
        bound = json.loads(destination.read_text())
        self.assertEqual(bound["machineID"], MACHINE)
        self.assertEqual(bound["steps"], body["steps"])
        with self.assertRaises(FileExistsError): lifecycle.bind_pc_login_template(source, destination, MACHINE, SERVICE)
        body["machineID"] = "wave0-pc-gpu-another-owned-guest"; source.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.bind_pc_login_template(source, self.root / "other.json", MACHINE, SERVICE)
        body["machineID"] = "wave0-pc-gpu-TEMPLATE"; body["steps"][0]["events"].pop()
        source.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.bind_pc_login_template(source, self.root / "other.json", MACHINE, SERVICE)

    def test_outer_gate_replays_lifecycle_and_crash_on_the_same_final_guest(self):
        inputs = self.root / "inputs"; inputs.mkdir()
        app = inputs / "Dory.app"; (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Dory").write_bytes(b"synthetic-app-not-executable")
        for name in ("daemon", "control", "runner", "installer", "signature"):
            (inputs / name).write_bytes(name.encode())
        candidate = inputs / "candidate"; candidate.mkdir()
        (candidate / "component-candidate-inventory.json").write_bytes(b"{}")
        authority = authorization(app); authority["candidateInventorySHA256"] = lifecycle.digest(b"{}")
        authority["cells"][0]["faultPolicy"] = {"permittedFaults": ["renderer-worker-sigkill"],
            "maximumArmingCount": 1, "maximumArmedMilliseconds": 10000}
        (self.root / "campaign-authority.json").write_text(json.dumps(authority))
        self.campaign.app, self.campaign.ctl = app, app / "Contents/Helpers/dorydctl"
        lifecycle_verdict = self.journey()
        spec = importlib.util.spec_from_file_location("pc_combined_renderer_model", ROOT / "scripts/test-arm-ubuntu-renderer-recovery.py")
        renderer = importlib.util.module_from_spec(spec); spec.loader.exec_module(renderer)
        campaign = renderer.ModelCampaign(self.evidence, mode="unexpected-worker-crash", machine=MACHINE, service=SERVICE, app=app,
            architecture="x86_64", network="shared-nat", graphics_backend="virgl", initial_number=self.campaign.number,
            initial_runtime_number=self.campaign.runtime_number, initial_generation=lifecycle_verdict["rendererGeneration"])
        with patch.object(renderer.recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
            renderer_verdict = renderer.recovery.run_recovery(campaign, renderer.PLAN)
        self.assertEqual(renderer_verdict["operationID"], lifecycle_verdict["operationID"])
        results = self.root / "results.tsv"; results.write_text("check\tstatus\tdetail\nsynthetic\tPASS\tmodel only\n")
        source = (ROOT / "scripts/pc-gpu-daemon-live-gate.sh").read_text()
        writer = source.split("<<'PYMANIFEST'\n", 1)[1].split("\nPYMANIFEST\n", 1)[0]
        manifest = self.root / "manifest.json"
        command = [sys.executable, "-c", writer, str(manifest), str(app), str(inputs / "daemon"), str(inputs / "control"),
                   str(inputs / "runner"), str(candidate), str(inputs / "installer"), SERVICE, MACHINE, str(results),
                   "prepare-installed-guest", "prepared", "4096", "2", "900", str(inputs),
                   str(self.root / "campaign-authority.json"), str(inputs / "signature"), "virgl", "virgl",
                   str(self.root / renderer.recovery.PLAN), str(ROOT), "1", "shared-nat"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = json.loads(manifest.read_text())
        self.assertFalse(body["releaseQualified"])
        self.assertEqual(body["desktopLifecycle"], lifecycle_verdict)
        self.assertEqual(body["rendererRecovery"], renderer_verdict)
        self.assertIn("cold-snapshot-exact-byte-recovery", body["proofScope"])
        self.assertIn("replacement-worker-challenged-pixels", body["proofScope"])
        self.assertIn("host-full-flush-failure-injection", body["unverified"])
        (candidate / "component-candidate-inventory.json").write_bytes(b"substituted candidate")
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another retained candidate/authority", result.stderr)

    def test_readiness_profile_source_manifest_and_release_claim_are_not_trusted(self):
        self.journey()
        path = self.root / "desktop-lifecycle-readiness.json"; original = path.read_bytes()
        for key, value in [("guestArchitecture", "arm64"), ("runtimeGraphicsBackend", "virgl-venus"),
                           ("guestProbeSHA256", "a" * 64), ("campaignManifestSHA256", "a" * 64),
                           ("sourceSHA256", {}), ("releaseEligible", True)]:
            body = json.loads(original); body[key] = value; path.write_text(json.dumps(body))
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_storage_bytes_cannot_claim_a_host_full_flush_fault(self):
        self.journey()
        path = self.root / "storage-recovery.json"
        body = json.loads(path.read_text()); body.update(status="PASS", fullFlushFailureObserved=True, missingAuthorities=[])
        path.write_text(json.dumps(body)); self.refresh(path.name)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_pc_cli_confirmation_is_required_before_any_codesign_or_mutation(self):
        command = [sys.executable, str(ROOT / "scripts/pc-ubuntu-desktop-lifecycle.py"), "--app", str(model.APP),
                   "--machine", MACHINE, "--mach-service", SERVICE, "--run-directory", str(self.root)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("exact ISA-specific confirmation", result.stderr)
        result = subprocess.run(command + ["--confirm", "EXACT-DORY-ARM-DESKTOP-LIFECYCLE"],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)

    def test_pc_cli_can_independently_replay_the_portable_raw_bundle(self):
        verdict = self.journey()
        command = [sys.executable, str(ROOT / "scripts/pc-ubuntu-desktop-lifecycle.py"), "--verify-only",
                   "--app", str(model.APP), "--machine", MACHINE, "--mach-service", SERVICE, "--run-directory", str(self.root)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), verdict)


if __name__ == "__main__": unittest.main(verbosity=2)
