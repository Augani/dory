#!/usr/bin/env python3
"""In-memory storage fault/recovery fixtures, never physical qualification evidence."""
import ast
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fault = load("full_flush", "arm-ubuntu-full-flush-fault.py")
journey = load("full_flush_journey_fixture", "test-arm-ubuntu-desktop-lifecycle.py")
lifecycle = fault.lifecycle
APP, MACHINE, SERVICE = journey.APP, journey.MACHINE, journey.SERVICE
NONCE = "f" * 32


class ModelCampaign(lifecycle.Campaign):
    def __init__(self, evidence, initial_number=7, first_errno=5, second_exit=0, bad_queue=False, corrupt_offline=False):
        super().__init__(APP, SERVICE, MACHINE, evidence, 90, NONCE, record_prefix="flush-fault")
        self.number, self.network, self.state, self.payload = initial_number, "shared-nat", "running", None
        self.first_errno, self.second_exit = first_errno, second_exit
        self.bad_queue, self.corrupt_offline = bad_queue, corrupt_offline
        self.calls = []

    def runtime(self):
        return journey.status(self.number, self.network, False, self.state)

    def ctl_call(self, args, label, timeout=None):
        self.calls.append(args)
        if args[:2] == ["exec", MACHINE]:
            argv = args[args.index("--") + 1:]
            action, nonce, third = ast.literal_eval(argv[2].splitlines()[0].split(" = ", 1)[1])
            assert nonce == NONCE
            if argv[2].startswith("action, nonce, challenge = "):
                if action == "prepare":
                    self.payload = fault.expected_payload(nonce)
                guest = {"action": action, "nonce": nonce, "challenge": third, "bootID": journey.boot(self.number),
                         "fileFsync": True, "directoryFsync": True, "payloadSHA256": self.payload,
                         "deviceIdentity": {"devicePath": "/dev/vda", "rootMajorMinor": "252:2",
                                            "diskMajorMinor": "252:0", "ancestry": ["252:2", "252:0"], "writeCache": "write back"}}
                if action == "prepare":
                    guest["baselineFlushExitCode"] = 0
                else:
                    guest.update(firstFlushErrno=self.first_errno, subsequentFlushExitCode=self.second_exit)
            else:
                guest = journey.observation(action, third, self.number, self.payload)
                guest["nonce"] = nonce
            body = {"schema": "dev.dory.machine.exec", "version": 1, "machine": MACHINE, "argv": argv,
                    "exitCode": 0, "timedOut": False, "stdoutTruncated": False, "stderrTruncated": False,
                    "stdout": json.dumps(guest), "stderr": ""}
        elif args[:2] == ["qualification-fault", MACHINE]:
            action = args[3]
            body = {"kind": fault.FAULT, "challenge": args[args.index("--challenge") + 1].upper(), "machineID": MACHINE,
                    "operationID": args[args.index("--operation-id") + 1].upper(),
                    "resolvedPlanSHA256": args[args.index("--plan-sha256") + 1],
                    "campaignManifestSHA256": args[args.index("--manifest-sha256") + 1]}
            if action == "arm":
                body["state"] = "armed"
            else:
                body.update(state="guestCompleted", injectedErrno=28, guestStatus=None if self.bad_queue else 1,
                            queueIndex=0, queueGeneration=2)
        elif args == ["status", MACHINE]:
            body = self.runtime()
        elif args == ["stop", MACHINE]:
            self.state = "stopped"
            body = self.runtime()
        elif args[:2] == ["update", MACHINE]:
            self.network = args[args.index("--network") + 1]
            body = self.runtime()
        elif args == ["start", MACHINE]:
            self.number += 1
            self.state = "running"
            if self.corrupt_offline and self.network == "disconnected":
                self.payload = "0" * 64
            body = self.runtime()
        else:
            raise AssertionError(args)
        self.sequence += 1
        name = f"flush-fault-{self.sequence:04d}-{label}.json"
        argv = [str(self.ctl), "--mach-service", SERVICE, "--timeout", str(timeout or self.timeout), "machine", *args]
        self.evidence.write(name, {"argv": argv, "returnCode": 0, "timedOut": False,
                                   "stdout": json.dumps(body), "stderr": ""})
        return copy.deepcopy(body), name

    def display(self, label, runtime):
        return self.evidence.write("lifecycle-" + label + "-window.json", journey.window(runtime))

    def login_boot(self, label, old_boot=None, network="shared-nat", expected_hash=None):
        observed, runtime, names = self.wait_boot(old_boot, network, expected_hash=expected_hash)
        names.append(self.display(label, runtime))
        return observed, runtime, names


def write_fixture(directory, machine=MACHINE, service=SERVICE):
    """Shared evidence-validator fixture builder; all observations are explicitly unit models."""
    global MACHINE, SERVICE
    MACHINE, SERVICE = machine, service
    journey.MACHINE, journey.SERVICE = machine, service
    evidence = lifecycle.Evidence(directory)
    if not (directory / "storage-recovery.json").exists():
        initial = journey.ModelCampaign(evidence)
        journey.lifecycle.run_journey(initial)
    else:
        initial = None
    boot = evidence.read("storage-recovery.json")["afterBootID"]
    number = int(boot.replace("-", ""), 16)
    campaign = ModelCampaign(evidence, initial_number=number)
    fault.run_fault(campaign)
    fault.qualify_storage(evidence, machine, service, APP)
    return campaign


class FullFlushTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-full-flush-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.evidence = lifecycle.Evidence(self.directory)
        self.evidence.write("campaign-authority.json", {
            "kind": "dev.dory.virtual-machine-candidate-campaign-authorization", "schemaVersion": 2,
            "applicationRoot": str(APP), "machineIDPrefix": "readiness-arm-ubuntu-",
            "cells": [{"faultPolicy": {"permittedFaults": [fault.FAULT, fault.mapped.FAULT]}}]})

    def fixture(self):
        return write_fixture(self.directory)

    def replay(self):
        return fault.verify_storage(self.evidence, MACHINE, SERVICE, APP)

    def tamper(self, predicate, mutate):
        phase = self.evidence.read("storage-full-flush-fault.json")
        for name in phase["references"]:
            raw = self.evidence.read(name)
            if predicate(raw):
                mutate(raw)
                path = self.directory / name
                path.write_text(json.dumps(raw))
                phase["references"][name] = lifecycle.digest(path.read_bytes())
                phase_path = self.directory / "storage-full-flush-fault.json"
                phase_path.write_text(json.dumps(phase))
                qualification = self.evidence.read("storage-recovery-qualification.json")
                qualification["references"][phase_path.name] = lifecycle.digest(phase_path.read_bytes())
                (self.directory / "storage-recovery-qualification.json").write_text(json.dumps(qualification))
                return
        self.fail("missing raw fixture record")

    def test_full_error_live_recovery_cold_boots_and_snapshot_join_replay(self):
        self.fixture()
        self.assertEqual(self.replay()["status"], "evidence-verified")
        self.assertIs(self.evidence.read("storage-recovery.json")["fullFlushFailureObserved"], False)
        self.assertEqual(self.evidence.read("storage-recovery.json")["status"], "INCOMPLETE")
        self.assertEqual(self.evidence.read("storage-recovery-qualification.json")["status"], "PASS")

    def test_guest_success_instead_of_an_error_cannot_qualify(self):
        campaign = ModelCampaign(self.evidence, first_errno=0)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertFalse((self.directory / "storage-full-flush-fault.json").exists())
        self.assertEqual(campaign.calls[-1][3], "cancel")
        self.assertFalse(any(args[0] == "stop" for args in campaign.calls))

    def test_guest_retry_failure_cannot_be_hidden_by_a_cold_reboot(self):
        campaign = ModelCampaign(self.evidence, second_exit=1)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertFalse(any(args[0] == "stop" for args in campaign.calls))

    def test_backend_consumption_without_guest_queue_ioerr_is_not_proof(self):
        campaign = ModelCampaign(self.evidence, bad_queue=True)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertFalse((self.directory / "storage-full-flush-fault.json").exists())

    def test_cold_boot_must_retain_exact_challenged_bytes(self):
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(ModelCampaign(self.evidence, corrupt_offline=True))
        self.assertFalse((self.directory / "storage-full-flush-fault.json").exists())

    def test_missing_signed_fault_policy_rejects_before_guest_writes(self):
        path = self.directory / "campaign-authority.json"
        authority = json.loads(path.read_text())
        authority["cells"][0]["faultPolicy"]["permittedFaults"] = [fault.mapped.FAULT]
        path.write_text(json.dumps(authority))
        campaign = ModelCampaign(self.evidence)
        with self.assertRaises(lifecycle.LifecycleError):
            fault.run_fault(campaign)
        self.assertEqual(campaign.calls, [])

    def test_rehashed_missing_used_ring_status_is_rejected(self):
        self.fixture()
        def mutate(raw):
            body = json.loads(raw["stdout"])
            body.pop("guestStatus")
            raw["stdout"] = json.dumps(body)
        self.tamper(lambda raw: "qualification-fault" in raw.get("argv", []) and "observe" in raw["argv"], mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_flush_on_another_disk_is_rejected(self):
        self.fixture()
        def mutate(raw):
            body = json.loads(raw["stdout"])
            guest = json.loads(body["stdout"])
            guest["deviceIdentity"]["devicePath"] = "/dev/vdb"
            body["stdout"] = json.dumps(guest)
            raw["stdout"] = json.dumps(body)
        self.tamper(lambda raw: "exec" in raw.get("argv", []) and "'exercise'" in raw["argv"][-1].splitlines()[0], mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_witness_command_change_is_rejected(self):
        self.fixture()
        self.tamper(lambda raw: "exec" in raw.get("argv", []) and "'exercise'" in raw["argv"][-1].splitlines()[0],
                    lambda raw: raw["argv"].__setitem__(-1, raw["argv"][-1] + "\nprint('forged')\n"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_offline_recovery_with_nat_is_rejected(self):
        self.fixture()
        self.tamper(lambda raw: "update" in raw.get("argv", []) and "disconnected" in raw["argv"],
                    lambda raw: raw["argv"].__setitem__(-1, "shared-nat"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_snapshot_receipt_must_remain_unchanged_and_link_to_fault_boot(self):
        self.fixture()
        path = self.directory / "storage-recovery.json"
        payload = json.loads(path.read_text())
        payload["afterBootID"] = journey.boot(999)
        path.write_text(json.dumps(payload))
        record = self.evidence.read("storage-recovery-qualification.json")
        record["references"][path.name] = lifecycle.digest(path.read_bytes())
        (self.directory / "storage-recovery-qualification.json").write_text(json.dumps(record))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_witness_has_no_raw_disk_writes_and_commands_are_bounded(self):
        tree = ast.parse(fault.GUEST_SOURCE)
        disk_open = next(node for node in tree.body if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == "disk" for target in node.targets))
        self.assertIsInstance(disk_open.value, ast.Call)
        self.assertIn("O_RDONLY", ast.unparse(disk_open.value))
        self.assertNotIn("O_RDWR", ast.unparse(disk_open.value))
        for action in ("prepare", "exercise"):
            script = fault.guest_script(action, NONCE, str(fault.uuid.UUID(hex=NONCE)))
            ast.parse(script)
            self.assertLess(len(script.encode()), 65536)


if __name__ == "__main__":
    unittest.main()
