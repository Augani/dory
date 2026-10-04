#!/usr/bin/env python3
"""Unit tests with an in-memory daemon model, never real VM qualification evidence."""
import ast
from contextlib import contextmanager
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock
import uuid

spec = importlib.util.spec_from_file_location("lifecycle", Path(__file__).with_name("arm-ubuntu-desktop-lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)

MACHINE = "readiness-arm-ubuntu-unit"
SERVICE = "dev.dory.readiness.armubuntu.unit"
NONCE = "a" * 32
APP = Path("/unit/Dory.app")


def boot(number):
    return str(uuid.UUID(int=number))


def observation(action="boot", network="shared-nat", number=1, payload=None):
    value = {"action": action, "nonce": NONCE}
    if action == "boot":
        value.update(bootID=boot(number), architecture="aarch64", osID="ubuntu", osVersion="24.04",
                     efi=True, rootSource="/dev/vda2", rootFSType="ext4", payloadSHA256=payload,
                     displayManagerActive=True,
                     graphicalSessions=[{"Type": "wayland", "Class": "user", "State": "active",
                                         "Remote": "no", "Seat": "seat0"}],
                     defaultRoutes=[] if network == "disconnected" else [{"gateway": "192.168.64.1"}])
        if network == "shared-nat":
            value.update(networkStatus=200, dnsAddressCount=1, repositoryPrefixSHA256="e" * 64)
    elif action in {"write", "mutate"}:
        value.update(fileFsync=True, directoryFsync=True, payloadSHA256=payload)
    elif action == "reboot":
        value["rebootScheduled"] = True
    elif action == "packages":
        value.update(updateExitCode=0, upgradeExitCode=0, installExitCode=0, package="tree",
                     packageStatus="install ok installed", packageVersion="2.1.1-2ubuntu3",
                     packageLogSHA256="c" * 64)
    return value


def status(number=1, network="shared-nat", media=False, state="running"):
    plan = hashlib.sha256(str(number).encode()).hexdigest()
    return {"id": MACHINE, "state": state, "guestArchitecture": "arm64",
            "installerMediaAttached": media, "typedSettings": {"networkMode": network},
            "runtimeIdentity": {"mode": "resolved-plan", "planSHA256": plan},
            "runtimeGraphicsSelection": {"operationID": boot(number + 100), "resolvedPlanSHA256": plan,
                                         "backend": "virgl-venus", "rendererGeneration": number,
                                         "rendererWorkerReceiptSHA256": "b" * 64}}


def window(runtime):
    return {"kind": "dev.dory.display-qualification-window", "schemaVersion": 2,
            "machineID": MACHINE, "machServiceName": SERVICE, "bundleIdentifier": "com.pythonxi.Dory",
            "operationID": runtime["runtimeGraphicsSelection"]["operationID"], "scanoutID": 0,
            "windowTitle": f"Dory — {MACHINE} — Display 1", "transport": "sharedTexture",
            "processID": 42, "windowNumber": 1, "frameSequence": 1,
            "displayResourceGeneration": 1, "metalCommandBufferCompletionID": 1}


class ModelCampaign(lifecycle.Campaign):
    def __init__(self, evidence, *, app=None, machine=None, service=None,
                 architecture="arm64", graphics_backend="virgl-venus"):
        super().__init__(app or APP, service or SERVICE, machine or MACHINE, evidence, 5, NONCE,
                         architecture=architecture, graphics_backend=graphics_backend)
        self.number, self.network, self.media, self.state = 1, "shared-nat", True, "running"
        self.runtime_number = 1
        self.payload = None
        self.snapshot_payload = None
        self.calls = []

    def runtime(self):
        body = status(self.runtime_number, self.network, self.media, self.state)
        body.update(id=self.machine, guestArchitecture=self.architecture)
        body["runtimeGraphicsSelection"]["backend"] = self.graphics_backend
        if self.architecture == "x86_64":
            body["runtimeGraphicsSelection"]["accelerationLevel"] = "hardware-accelerated-3d"
        return body

    def ctl_call(self, arguments, label, timeout=None):
        self.calls.append(arguments)
        command = arguments[0]
        if command == "exec":
            guest_argv = arguments[arguments.index("--") + 1:]
            action, nonce, network = ast.literal_eval(guest_argv[2].splitlines()[0].split(" = ", 1)[1])
            self.assert_equal(nonce, NONCE)
            if action == "write":
                self.payload = lifecycle.digest(hashlib.sha256(NONCE.encode()).digest() * 16384)
            elif action == "mutate":
                self.payload = lifecycle.digest(b"mutated-after-snapshot\n")
            elif action == "reboot":
                self.number += 1
            guest = observation(action, network, self.number, self.payload)
            if action == "boot" and self.architecture == "x86_64":
                guest["architecture"] = "x86_64"
                if network == "shared-nat":
                    guest["repositoryURL"] = "https://archive.ubuntu.com/ubuntu/dists/noble/Release"
            result = {"schema": "dev.dory.machine.exec", "version": 1, "machine": self.machine,
                      "argv": guest_argv, "exitCode": 0, "timedOut": False,
                      "stdoutTruncated": False, "stderrTruncated": False,
                      "stdout": json.dumps(guest), "stderr": ""}
        elif command == "stop":
            self.state = "stopped"
            result = self.runtime()
        elif command == "update":
            if "--network" in arguments:
                self.network = arguments[arguments.index("--network") + 1]
            self.assert_equal(not ("--network" in arguments and "--eject-installer" in arguments), True)
            if "--eject-installer" in arguments:
                self.media = False
            result = self.runtime()
        elif command == "start":
            self.state = "running"
            self.number += 1
            self.runtime_number += 1
            result = self.runtime()
        elif command == "status":
            result = self.runtime()
        elif command == "snapshot":
            self.snapshot_payload = self.payload
            result = {"machineID": self.machine, "id": arguments[arguments.index("--id") + 1],
                      "consistency": "cold-stopped", "runtimeIdentity": self.runtime()["runtimeIdentity"],
                      "artifactEvidence": {"rootfs": {"sha256": "f" * 64, "byteCount": 4096}}}
        elif command == "restore-snapshot":
            self.payload = self.snapshot_payload
            result = self.runtime()
        elif command == "delete-snapshot":
            result = {"ok": True}
        else:
            raise AssertionError(f"unexpected model command: {arguments}")
        self.sequence += 1
        name = f"lifecycle-{self.sequence:04d}-{label}.json"
        argv = [str(self.ctl), "--mach-service", self.service, "--timeout", str(timeout or self.timeout),
                "machine", *arguments]
        self.evidence.write(name, {"argv": argv, "returnCode": 0, "timedOut": False,
                                   "stdout": json.dumps(result), "stderr": ""})
        return copy.deepcopy(result), name

    @staticmethod
    def assert_equal(left, right):
        assert left == right

    def display(self, label, runtime):
        name = f"lifecycle-{label}-window.json"
        receipt = window(runtime)
        receipt.update(machineID=self.machine, machServiceName=self.service,
                       windowTitle=f"Dory — {self.machine} — Display 1")
        self.evidence.write(name, receipt)
        return name

    def login_boot(self, label, old_boot=None, network="shared-nat", expected_hash=None):
        observation, runtime, names = self.wait_boot(old_boot, network, expected_hash=expected_hash)
        names.append(self.display(label, runtime))
        return observation, runtime, names


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.evidence = lifecycle.Evidence(self.directory)
        self.campaign = ModelCampaign(self.evidence)

    def journey(self):
        lifecycle.run_journey(self.campaign)

    def rehash(self, name):
        for phase in ("installer-reboot", "cold-offline-reopen", "cold-reopen", "guest-reboot",
                      "package-update", "storage-recovery"):
            path = self.directory / (phase + ".json")
            body = json.loads(path.read_text())
            if name in body["references"]:
                body["references"][name] = lifecycle.digest((self.directory / name).read_bytes())
                path.write_text(json.dumps(body))

    def tamper_control(self, phase, command, mutate):
        record = self.evidence.read(phase + ".json")
        for name in record["references"]:
            raw = self.evidence.read(name)
            if "argv" in raw and raw["argv"][6] == command:
                mutate(raw)
                (self.directory / name).write_text(json.dumps(raw))
                self.rehash(name)
                return
        self.fail("control fixture not found")

    def replay(self):
        return lifecycle.verify_journey(self.evidence, MACHINE, SERVICE, APP)

    def test_complete_journey_uses_only_campaign_apis_and_stays_unqualified(self):
        self.journey()
        self.assertEqual(self.replay(), NONCE)
        readiness = self.evidence.read("desktop-lifecycle-readiness.json")
        self.assertEqual(readiness["status"], "implemented-phases-passed")
        self.assertIs(readiness["releaseEligible"], False)
        recovery = self.evidence.read("storage-recovery.json")
        self.assertEqual(recovery["status"], "INCOMPLETE")
        self.assertIs(recovery["fullFlushFailureObserved"], False)
        self.assertIn(["update", MACHINE, "--network", "shared-nat"], self.campaign.calls)
        self.assertIn(["update", MACHINE, "--eject-installer"], self.campaign.calls)
        self.assertIn(["update", MACHINE, "--network", "disconnected"], self.campaign.calls)
        self.assertFalse(any(call[0] in {"create", "delete", "restart"} for call in self.campaign.calls))

    def test_live_installer_root_is_rejected(self):
        for source, filesystem in (("overlay", "overlay"), ("/dev/loop0", "ext4"),
                                   ("/dev/sr0", "ext4"), ("/dev/vda2", "squashfs")):
            with self.subTest(source=source):
                value = observation()
                value.update(rootSource=source, rootFSType=filesystem)
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_guest(value, "boot", NONCE, "shared-nat")

    def test_wrong_os_architecture_efi_nonce_are_rejected(self):
        for key, value in (("architecture", "x86_64"), ("osID", "fedora"), ("osVersion", "22.04"),
                           ("efi", False), ("nonce", "b" * 32), ("bootID", "not-a-boot-id")):
            with self.subTest(key=key):
                body = observation()
                body[key] = value
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_guest(body, "boot", NONCE, "shared-nat")

    def test_offline_boot_requires_no_ipv4_or_ipv6_default_route(self):
        body = observation(network="disconnected")
        lifecycle.check_guest(body, "boot", NONCE, "disconnected")
        body["defaultRoutes"] = [{"gateway": "fe80::1"}]
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.check_guest(body, "boot", NONCE, "disconnected")

    def test_display_manager_or_greeter_alone_does_not_prove_desktop_login(self):
        for sessions in ([], [{"Type": "tty", "Class": "user", "State": "active", "Remote": "no", "Seat": "seat0"}],
                         [{"Type": "wayland", "Class": "greeter", "State": "active", "Remote": "no", "Seat": "seat0"}],
                         [{"Type": "x11", "Class": "user", "State": "active", "Remote": "yes", "Seat": "seat0"}]):
            with self.subTest(sessions=sessions):
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_guest(dict(observation(), graphicalSessions=sessions), "boot", NONCE, "shared-nat")

    def test_connected_boot_requires_dns_repository_and_default_route(self):
        for key, value in (("defaultRoutes", []), ("networkStatus", 503), ("dnsAddressCount", 0),
                           ("repositoryPrefixSHA256", "not-a-hash")):
            with self.subTest(key=key):
                body = observation()
                body[key] = value
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_guest(body, "boot", NONCE, "shared-nat")

    def test_payload_checksum_is_not_optional_after_write(self):
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.check_guest(observation(payload="a" * 64), "boot", NONCE, "shared-nat", "b" * 64)

    def test_truncated_failed_or_wrong_command_exec_cannot_be_observation(self):
        argv = ["python3", "-c", "probe"]
        base = {"schema": "dev.dory.machine.exec", "version": 1, "machine": MACHINE, "argv": argv,
                "exitCode": 0, "timedOut": False, "stdoutTruncated": False,
                "stderrTruncated": False, "stdout": json.dumps(observation())}
        for key, value in (("machine", "another-vm"), ("argv", ["printf", "fake"]), ("exitCode", 1),
                           ("timedOut", True), ("stdoutTruncated", True), ("stderrTruncated", True)):
            with self.subTest(key=key):
                body = dict(base, **{key: value})
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_exec(body, MACHINE, argv)

    def test_renderer_must_bind_the_current_plan_and_window_operation(self):
        runtime = status()
        lifecycle.check_status(runtime, MACHINE)
        good = window(runtime)
        lifecycle.check_window(good, runtime, MACHINE, SERVICE, 42)
        for key, value in (("operationID", boot(999)), ("transport", "cpuCopy"), ("processID", 43),
                           ("machineID", "another-vm"), ("metalCommandBufferCompletionID", 0)):
            with self.subTest(key=key):
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_window(dict(good, **{key: value}), runtime, MACHINE, SERVICE, 42)

    def test_package_update_requires_all_three_successes(self):
        for key, value in (("updateExitCode", 1), ("upgradeExitCode", 1), ("installExitCode", 1),
                           ("packageStatus", "deinstall ok config-files"), ("packageVersion", "")):
            with self.subTest(key=key):
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_guest(dict(observation("packages"), **{key: value}), "packages", NONCE, "shared-nat")

    def test_daemon_network_policy_and_renderer_plan_are_not_inferred(self):
        for key, value in (("typedSettings", None), ("runtimeIdentity", None),
                           ("runtimeGraphicsSelection", None), ("installerMediaAttached", True)):
            with self.subTest(key=key):
                with self.assertRaises(lifecycle.LifecycleError):
                    lifecycle.check_status(dict(status(), **{key: value}), MACHINE, network="shared-nat")
        runtime = status(network="shared-nat")
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.check_status(runtime, MACHINE, network="disconnected")

    def test_raw_hash_mismatch_is_rejected(self):
        self.journey()
        name = next(iter(self.evidence.read("package-update.json")["references"]))
        (self.directory / name).write_text("{}")
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_wrong_guest_command_is_rejected(self):
        self.journey()
        def mutate(raw):
            result = json.loads(raw["stdout"])
            boundary = raw["argv"].index("--")
            raw["argv"][boundary + 1:] = ["printf", result["stdout"]]
            result["argv"] = raw["argv"][boundary + 1:]
            raw["stdout"] = json.dumps(result)
        self.tamper_control("package-update", "exec", mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_wrong_payload_with_passing_booleans_is_rejected(self):
        self.journey()
        def mutate(raw):
            result = json.loads(raw["stdout"])
            guest = json.loads(result["stdout"])
            guest["payloadSHA256"] = "d" * 64
            result["stdout"] = json.dumps(guest)
            raw["stdout"] = json.dumps(result)
        self.tamper_control("cold-reopen", "exec", mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_guest_reboot_cannot_reuse_boot_id(self):
        self.journey()
        path = self.directory / "guest-reboot.json"
        body = json.loads(path.read_text())
        body["afterBootID"] = body["beforeBootID"]
        path.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_snapshot_recovery_cannot_claim_full_flush_failure(self):
        self.journey()
        path = self.directory / "storage-recovery.json"
        body = json.loads(path.read_text())
        body.update(status="PASS", fullFlushFailureObserved=True, missingAuthorities=[])
        path.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_renderer_receipt_from_old_runtime_is_rejected(self):
        self.journey()
        name = "lifecycle-cold-reopen-window.json"
        body = self.evidence.read(name)
        body["operationID"] = boot(999)
        (self.directory / name).write_text(json.dumps(body))
        self.rehash(name)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_restore_of_another_snapshot_is_rejected(self):
        self.journey()
        self.tamper_control("storage-recovery", "restore-snapshot", lambda raw: raw["argv"].__setitem__(8, "another-snapshot"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_snapshot_without_root_artifact_is_rejected_cleanly(self):
        self.journey()
        def mutate(raw):
            result = json.loads(raw["stdout"])
            result["artifactEvidence"] = None
            raw["stdout"] = json.dumps(result)
        self.tamper_control("storage-recovery", "snapshot", mutate)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_snapshot_operations_in_wrong_order_are_rejected(self):
        self.journey()
        names = self.evidence.read("storage-recovery.json")["references"]
        selected = {}
        for name in names:
            raw = self.evidence.read(name)
            if "argv" in raw and raw["argv"][6] in {"snapshot", "restore-snapshot"}:
                selected[raw["argv"][6]] = name
        left, right = selected["snapshot"], selected["restore-snapshot"]
        left_bytes, right_bytes = (self.directory / left).read_bytes(), (self.directory / right).read_bytes()
        (self.directory / left).write_bytes(right_bytes)
        (self.directory / right).write_bytes(left_bytes)
        self.rehash(left)
        self.rehash(right)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_reuse_of_evidence_is_rejected(self):
        self.evidence.write("owned.json", {"original": True})
        with self.assertRaises(FileExistsError):
            self.evidence.write("owned.json", {"original": False})
        self.assertEqual(self.evidence.read("owned.json"), {"original": True})

    def test_evidence_symlinks_and_parent_references_are_rejected(self):
        (self.directory / "linked.json").symlink_to("missing.json")
        for name in ("linked.json", "../other.json", "/other.json"):
            with self.subTest(name=name):
                with self.assertRaises(lifecycle.LifecycleError):
                    self.evidence.read(name)

    def test_duplicate_json_fields_are_rejected(self):
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.object_json('{"status":"FAIL","status":"PASS"}')

    def test_control_timeout_is_retained_and_not_an_observation(self):
        campaign = lifecycle.Campaign(APP, SERVICE, MACHINE, self.evidence, 1, NONCE)
        with patch.object(lifecycle.subprocess, "run", side_effect=subprocess.TimeoutExpired("ctl", 1, b"partial")):
            with self.assertRaises(lifecycle.TransportUnavailable):
                campaign.ctl_call(["status", MACHINE], "timeout")
        retained = self.evidence.read("lifecycle-0001-timeout.json")
        self.assertIs(retained["timedOut"], True)
        self.assertEqual(retained["stdout"], "partial")

    def test_unavailable_agent_has_a_bounded_boot_deadline(self):
        campaign = lifecycle.Campaign(APP, SERVICE, MACHINE, self.evidence, 1, NONCE)
        with patch.object(campaign, "ctl_call", side_effect=lifecycle.TransportUnavailable("offline")), \
             patch.object(lifecycle.time, "monotonic", side_effect=[0, 0, 0, 0, 2]), \
             patch.object(lifecycle.time, "sleep"):
            with self.assertRaisesRegex(lifecycle.LifecycleError, "deadline"):
                campaign.wait_boot()

    def test_graphical_login_may_lag_agent_readiness_within_the_deadline(self):
        self.campaign.media = False
        original = self.campaign.guest
        count = [0]
        def guest(*args, **kwargs):
            body, name = original(*args, **kwargs)
            count[0] += 1
            if count[0] == 1:
                body["graphicalSessions"] = []
            return body, name
        with patch.object(self.campaign, "guest", side_effect=guest), patch.object(lifecycle.time, "sleep"):
            body, _, _ = self.campaign.wait_boot()
        self.assertEqual(body["bootID"], boot(1))
        self.assertEqual(count[0], 2)

    def test_display_shutdown_is_bounded_and_targets_only_its_child(self):
        campaign = lifecycle.Campaign(APP, SERVICE, MACHINE, self.evidence, 1, NONCE)
        child = Mock(pid=42)
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired("owned-app", 5), 0]
        runtime = status()
        def launch(*args, **kwargs):
            self.evidence.write("lifecycle-owned-window.json", window(runtime))
            self.assertEqual(args[0], [str(APP / "Contents/MacOS/Dory")])
            self.assertEqual(kwargs["env"]["DORYD_MACH_SERVICE"], SERVICE)
            self.assertNotIn("DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT", kwargs["env"])
            return child
        with patch.object(lifecycle.subprocess, "Popen", side_effect=launch), \
             patch.dict(lifecycle.os.environ, {"DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT": "/wrong/input"}):
            self.assertEqual(campaign.display("owned", runtime), "lifecycle-owned-window.json")
        child.terminate.assert_called_once()
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 2)
        self.assertTrue(all(call.kwargs == {"timeout": 5} for call in child.wait.call_args_list))

    def test_login_window_is_open_before_waiting_for_graphical_session(self):
        campaign = lifecycle.Campaign(APP, SERVICE, MACHINE, self.evidence, 1, NONCE)
        active = [False]
        child = Mock(pid=42)
        child.poll.return_value = None
        @contextmanager
        def session(label, login=False):
            self.assertEqual(label, "boot-login")
            self.assertIs(login, True)
            active[0] = True
            try:
                yield child, "unqualified-login-window.json"
            finally:
                active[0] = False
        def wait(*args, **kwargs):
            self.assertTrue(active[0], "login is impossible without its open window")
            return observation(), status(), []
        def display(label, runtime):
            self.assertFalse(active[0])
            self.assertEqual(label, "boot")
            return "fresh-post-login-window.json"
        with patch.object(campaign, "display_session", side_effect=session), \
             patch.object(campaign, "wait_boot", side_effect=wait), \
             patch.object(campaign, "display", side_effect=display):
            _, _, names = campaign.login_boot("boot")
        self.assertEqual(names, ["fresh-post-login-window.json"])

    def test_post_install_login_keys_are_machine_bound_bounded_and_balanced(self):
        path = self.directory / "login.json"
        body = {"kind": "dev.dory.display-qualification-keyboard-script", "schemaVersion": 1,
                "machineID": MACHINE, "steps": [{"delayMilliseconds": 100,
                    "events": [{"type": 1, "code": 30, "value": 1}, {"type": 1, "code": 30, "value": 0}]}]}
        path.write_text(json.dumps(body))
        lifecycle.validate_login_input(path, MACHINE)
        for mutate in (lambda value: value.__setitem__("machineID", "another-vm"),
                       lambda value: value["steps"][0].__setitem__("delayMilliseconds", 300001),
                       lambda value: value["steps"][0]["events"].pop(),
                       lambda value: value["steps"][0]["events"][0].__setitem__("value", 2)):
            corrupted = copy.deepcopy(body)
            mutate(corrupted)
            path.write_text(json.dumps(corrupted))
            with self.assertRaises(lifecycle.LifecycleError):
                lifecycle.validate_login_input(path, MACHINE)

    def test_production_machine_or_service_are_not_valid_mutation_targets(self):
        for service, machine in (("dev.dory.daemon", MACHINE), (SERVICE, "personal-vm"),
                                 (SERVICE, "readiness-arm-ubuntu-another-run")):
            with self.subTest(service=service, machine=machine):
                with tempfile.TemporaryDirectory() as directory:
                    app = Path(directory) / "Dory.app"
                    app.mkdir()
                    with self.assertRaises(lifecycle.LifecycleError):
                        lifecycle.validate_target(app, service, machine, Path(directory), 900)

    def test_guest_source_compiles_and_uses_no_host_shell(self):
        for action in ("boot", "write", "mutate", "reboot", "packages"):
            compile(lifecycle.guest_script(action, NONCE, "shared-nat"), "guest-probe", "exec")
        source = Path(__file__).with_name("arm-ubuntu-desktop-lifecycle.py").read_text()
        self.assertNotIn("shell=True", source)
        self.assertNotIn("launchctl", source)
        self.assertNotIn("os.environ['HOME']", source)


if __name__ == "__main__":
    unittest.main()
