#!/usr/bin/env python3
"""Adversarial unit/replay fixtures; these never qualify a physical machine."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("mapped_fault", Path(__file__).with_name("arm-ubuntu-mapped-page-fault.py"))
fault = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fault)
lifecycle = fault.lifecycle
APP = Path("/unit/Dory.app")
MACHINE = "readiness-arm-ubuntu-unit"
SERVICE = "dev.dory.readiness.armubuntu.unit"
CHALLENGE = "aaaa0000-0000-0000-0000-000000000001"
BOOT = "bbbb0000-0000-0000-0000-000000000001"
OPERATION = "cccc0000-0000-0000-0000-000000000001"
PLAN = "b" * 64


def runtime():
    return {"id": MACHINE, "state": "running", "guestArchitecture": "arm64", "installerMediaAttached": False,
            "typedSettings": {"networkMode": "shared-nat"},
            "runtimeIdentity": {"mode": "resolved-plan", "planSHA256": PLAN},
            "runtimeGraphicsSelection": {"operationID": OPERATION, "resolvedPlanSHA256": PLAN,
                                         "backend": "virgl-venus", "rendererGeneration": 1,
                                         "rendererWorkerReceiptSHA256": "c" * 64}}


class ModelCampaign(lifecycle.Campaign):
    def __init__(self, evidence, bad_counts=False, bad_guest=False, cancel_fails=False):
        super().__init__(APP, SERVICE, MACHINE, evidence, 90, "a" * 32, record_prefix="mapped-fault")
        self.calls = []
        self.bad_counts, self.bad_guest, self.cancel_fails = bad_counts, bad_guest, cancel_fails
        self.ready = None
        self.completed = None
        self.armed = None

    def ctl_call(self, args, label, timeout=None):
        self.calls.append(args)
        if args == ["status", MACHINE]:
            body = runtime()
        elif args[:2] == ["exec", MACHINE]:
            argv = args[args.index("--") + 1:]
            values = ast.literal_eval(argv[2].splitlines()[0].split(" = ", 1)[1])
            action = values[0]
            if len(values) == 3:
                guest = {"action": "boot", "nonce": self.nonce, "bootID": BOOT,
                         "architecture": "aarch64", "osID": "ubuntu", "osVersion": "24.04", "efi": True,
                         "rootSource": "/dev/vda2", "rootFSType": "ext4", "displayManagerActive": True,
                         "graphicalSessions": [{"Type": "wayland", "Class": "user", "State": "active", "Remote": "no", "Seat": "seat0"}],
                         "defaultRoutes": [{"gateway": "192.168.64.1"}], "networkStatus": 200,
                         "dnsAddressCount": 1, "repositoryPrefixSHA256": "d" * 64}
            else:
                challenge = values[1]
                guest = {"action": action, "challenge": challenge, "bootID": BOOT, "unit": "dory-mapped-page-" + challenge}
                if action == "prepare":
                    guest.update(sourceSHA256=lifecycle.digest(fault.read_source()), binarySHA256="e" * 64,
                                 patternSHA256=fault.pattern_hash(challenge), compiler="unit-model-cc")
                elif action == "ready":
                    self.ready = {"kind": "dev.dory.mapped-page-retry-guest-ready@1", "challenge": challenge,
                                  "bootID": BOOT, "processID": 123, "virtualCPU": 0,
                                  "guestPhysicalAddress": 0x4000_4000, "virtualAddress": 0x200000,
                                  "scratchBytes": 2 * 1024 * 1024, "hostPageBytes": 16384}
                    guest["ready"] = self.ready
                elif action == "trigger":
                    guest["triggered"] = True
                elif action == "result":
                    guest["result"] = {**self.ready, "kind": "dev.dory.mapped-page-retry-guest-result@1", "status": "PASS",
                                       "signal": 7, "signalCode": 3, "signalAddress": self.ready["virtualAddress"],
                                       "guestFaultObserved": True, "unchangedPageReadable": not self.bad_guest}
                elif action == "cleanup":
                    guest["stopped"] = True
            body = {"schema": "dev.dory.machine.exec", "version": 1, "machine": MACHINE, "argv": argv,
                    "exitCode": 0, "timedOut": False, "stdoutTruncated": False, "stderrTruncated": False,
                    "stdout": json.dumps(guest), "stderr": ""}
        elif args[:2] == ["qualification-fault", MACHINE]:
            action = args[3]
            if action == "cancel" and self.cancel_fails:
                raise lifecycle.TransportUnavailable("unit-model failed cancellation")
            challenge = args[args.index("--challenge") + 1]
            manifest = args[args.index("--manifest-sha256") + 1]
            base = {"challenge": challenge.upper(), "kind": fault.FAULT, "machineID": MACHINE,
                    "operationID": OPERATION.upper(), "resolvedPlanSHA256": PLAN, "campaignManifestSHA256": manifest,
                    "guestPhysicalAddress": self.ready["guestPhysicalAddress"]}
            if action == "arm":
                body = {**base, "state": "armed", "faultExitCount": 0, "retryCount": 0, "memoryProtectionRestored": False}
                self.armed = body
            else:
                body = {**base, "state": "retryEscalated", "faultExitCount": 16 if self.bad_counts else 17,
                        "retryCount": 16, "virtualCPUIndex": 0, "instructionAddress": 0x1000,
                        "guestException": "synchronous-external-data-abort", "memoryProtectionRestored": True}
                self.completed = body
        else:
            raise AssertionError(args)
        self.sequence += 1
        name = f"mapped-fault-{self.sequence:04d}-{label}.json"
        argv = [str(self.ctl), "--mach-service", self.service, "--timeout", str(timeout or self.timeout), "machine", *args]
        self.evidence.write(name, {"argv": argv, "returnCode": 0, "timedOut": False, "stdout": json.dumps(body), "stderr": ""})
        return body, name

    def display(self, label, status):
        return self.evidence.write("lifecycle-" + label + "-window.json", {
            "kind": "dev.dory.display-qualification-window", "schemaVersion": 2, "machineID": MACHINE,
            "machServiceName": SERVICE, "bundleIdentifier": "com.pythonxi.Dory", "operationID": OPERATION,
            "scanoutID": 0, "windowTitle": f"Dory — {MACHINE} — Display 1", "transport": "sharedTexture",
            "processID": 45, "windowNumber": 1, "frameSequence": 20, "displayResourceGeneration": 1,
            "metalCommandBufferCompletionID": 20})


class FaultTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-mapped-fault-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.evidence = lifecycle.Evidence(self.directory)
        self.evidence.write("campaign-authority.json", {
            "kind": "dev.dory.virtual-machine-candidate-campaign-authorization", "schemaVersion": 2,
            "applicationRoot": str(APP), "machineIDPrefix": "readiness-arm-ubuntu-",
            "cells": [{"faultPolicy": {"permittedFaults": [fault.FAULT]}}]})

    def run_fixture(self, **options):
        campaign = ModelCampaign(self.evidence, **options)
        result = fault.run_fault(campaign)
        self.assertEqual(result["status"], "evidence-verified")
        return campaign

    def replay(self):
        return fault.verify_fault(self.evidence, MACHINE, SERVICE, APP)

    def tamper(self, predicate, mutation):
        record = self.evidence.read("fault-retry.json")
        for name in record["references"]:
            raw = self.evidence.read(name)
            if predicate(raw):
                mutation(raw)
                path = self.directory / name
                path.write_text(json.dumps(raw))
                record["references"][name] = lifecycle.digest(path.read_bytes())
                (self.directory / "fault-retry.json").write_text(json.dumps(record))
                return
        self.fail("unit fixture did not find the target raw record")

    def test_exact_join_replays_without_running_any_real_guest(self):
        campaign = self.run_fixture()
        self.assertEqual(self.replay()["operationID"], OPERATION)
        self.assertEqual([args[3] for args in campaign.calls if args[0] == "qualification-fault"], ["arm", "observe", "cancel"])

    def test_real_budget_count_cannot_be_replaced_by_guest_pass_booleans(self):
        campaign = ModelCampaign(self.evidence, bad_counts=True)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertFalse((self.directory / "fault-retry.json").exists())
        self.assertEqual(campaign.calls[-1][0], "exec")
        self.assertIn("'cleanup'", campaign.calls[-1][-1].splitlines()[0])
        self.assertTrue(any(args[:4] == ["qualification-fault", MACHINE, "--action", "cancel"] for args in campaign.calls))

    def test_guest_fault_without_unchanged_page_recovery_cannot_pass(self):
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(ModelCampaign(self.evidence, bad_guest=True))
        self.assertFalse((self.directory / "fault-retry.json").exists())

    def test_guest_unit_cleanup_runs_even_if_fault_cancellation_rpc_fails(self):
        campaign = ModelCampaign(self.evidence, bad_counts=True, cancel_fails=True)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertIn("'cleanup'", campaign.calls[-1][-1].splitlines()[0])

    def test_rehashed_wrong_page_arm_intent_is_rejected(self):
        self.run_fixture()
        self.tamper(lambda raw: "--guest-physical-address" in raw.get("argv", []),
                    lambda raw: raw["argv"].__setitem__(-1, str(0x4000_8000)))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_changed_guest_source_command_is_rejected(self):
        self.run_fixture()
        self.tamper(lambda raw: "encoded_source" in raw.get("argv", [""])[-1],
                    lambda raw: raw["argv"].__setitem__(-1, raw["argv"][-1] + "\nprint('forged')\n"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_missing_permission_rollback_is_rejected(self):
        self.run_fixture()
        def mutate(raw):
            body = json.loads(raw["stdout"])
            body["memoryProtectionRestored"] = False
            raw["stdout"] = json.dumps(body)
        self.tamper(lambda raw: "qualification-fault" in raw.get("argv", []) and "observe" in raw["argv"], mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_wrong_sigbus_code_or_signal_address_is_rejected(self):
        self.run_fixture()
        def mutate(raw):
            body = json.loads(raw["stdout"])
            guest = json.loads(body["stdout"])
            guest["result"]["signalCode"] = 2
            body["stdout"] = json.dumps(guest)
            raw["stdout"] = json.dumps(body)
        self.tamper(lambda raw: "exec" in raw.get("argv", []) and "'result'" in raw["argv"][-1].splitlines()[0], mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_different_authority_bytes_cannot_reuse_observations(self):
        self.run_fixture()
        path = self.directory / "campaign-authority.json"
        path.write_text(path.read_text() + "\n")
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_foreign_endpoint_cannot_replay_even_when_all_artifacts_are_rehashed(self):
        self.run_fixture()
        self.tamper(lambda raw: "argv" in raw, lambda raw: raw["argv"].__setitem__(2, SERVICE + "-other"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_zero_uppercase_and_malformed_guest_challenges_are_rejected(self):
        self.assertEqual(fault.normalized_uuid(CHALLENGE.upper()), CHALLENGE)
        for value in (None, "00000000-0000-0000-0000-000000000000", "not-a-uuid"):
            with self.assertRaises(lifecycle.LifecycleError):
                fault.normalized_uuid(value)

    def test_guest_source_commands_are_bounded_and_parse_as_python(self):
        for action in ("prepare", "ready", "trigger", "result", "cleanup"):
            source = fault.guest_script(action, CHALLENGE, fault.read_source())
            self.assertLess(len(source.encode()), 65536)
            ast.parse(source)

    def test_portable_compiled_c_pattern_matches_swift_contract_vector(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler)
        binary = self.directory / "pattern-probe"
        result = subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                                 str(fault.SOURCE), "-o", str(binary)], capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = subprocess.check_output([str(binary), "--pattern", CHALLENGE], timeout=5)
        self.assertEqual(len(actual), 16384)
        self.assertEqual(hashlib.sha256(actual).hexdigest(), "2523d62477f2315f0f61272bd7d825eeee86b3d7b70855b078c4d1343dce1ecd")
        for challenge in (CHALLENGE.upper(), "00000000-0000-0000-0000-000000000000", "bad"):
            rejected = subprocess.run([str(binary), "--pattern", challenge], capture_output=True, timeout=5)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(rejected.stdout, b"")


if __name__ == "__main__":
    unittest.main()
