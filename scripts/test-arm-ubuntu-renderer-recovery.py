#!/usr/bin/env python3
"""Synthetic CPU/daemon/pixel fixtures; never a physical renderer recovery qualification."""
import ast
from contextlib import contextmanager
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recovery = load("renderer_recovery_unit", ROOT / "scripts/arm-ubuntu-renderer-recovery.py")
journey = load("renderer_journey_unit", ROOT / "scripts/test-arm-ubuntu-desktop-lifecycle.py")
lifecycle = recovery.lifecycle
APP, MACHINE, SERVICE = journey.APP, journey.MACHINE, journey.SERVICE
NONCE, CANDIDATE = "f" * 32, "e" * 64


def pixel_helpers():
    path = ROOT / "guest-probes/test-displayed-pixel.py"
    source = ast.parse(path.read_text(), filename=str(path))
    stop = next(index for index, node in enumerate(source.body) if isinstance(node, ast.Expr)
                and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name)
                and node.value.func.id == "test_vulkan_result_hash_replay")
    namespace = {"__file__": str(path)}
    exec(compile(ast.Module(body=source.body[:stop], type_ignores=[]), str(path), "exec"), namespace)
    return namespace


PIXELS = pixel_helpers()
PLAN = {"kind": recovery.KIND + "-redraw-plan", "schemaVersion": 1,
        "guestCommand": "launch-probe-using-fresh-environment", "expectedOutput": "started\n",
        "probeResultCommand": "read-probe-result-using-fresh-environment", "probeBuildReceiptCommand": "read-build-receipt",
        "probeReadyFileTemplate": "/tmp/dory-renderer-{nonce}.ready", "graphicsTrace": "/unit/graphics-trace.ndjson"}


class ModelCampaign(recovery.RendererCampaign):
    def __init__(self, evidence, failure=None, initial_number=7, mode="controlled-restart", *,
                 architecture="arm64", network="shared-nat", graphics_backend="virgl-venus",
                 machine=None, service=None, app=None, initial_runtime_number=None, initial_generation=7):
        super().__init__(app or APP, service or SERVICE, machine or MACHINE, evidence, 10, NONCE, mode,
                         architecture=architecture, network=network, graphics_backend=graphics_backend)
        self.generation, self.failure, self.calls, self.observations = initial_generation, failure, [], 0
        self.initial_generation = initial_generation
        self.number = initial_number
        self.runtime_number = initial_runtime_number if initial_runtime_number is not None else initial_number
        self.crash_receipt = None
        self.unavailable = False

    def status(self):
        body = journey.status(self.runtime_number, network=self.network, media=False)
        body.update(id=self.machine, guestArchitecture=self.architecture)
        body["runtimeGraphicsSelection"].update(rendererGeneration=self.generation,
                                               backend=self.graphics_backend,
                                               rendererWorkerReceiptSHA256=str(self.generation) * 64)
        if self.architecture == "x86_64":
            body["runtimeGraphicsSelection"]["accelerationLevel"] = "hardware-accelerated-3d"
        if self.failure == "new-operation" and self.generation == self.initial_generation + 1:
            body["runtimeGraphicsSelection"]["operationID"] = journey.boot(999)
        return body

    def ctl_call(self, arguments, label, timeout=None):
        self.calls.append(arguments)
        if arguments == ["status", self.machine]:
            body = self.status()
            if self.unavailable:
                body["runtimeGraphicsSelection"] = None
                self.unavailable = False
        elif arguments[:2] == ["qualification-fault", self.machine]:
            action = arguments[arguments.index("--action") + 1]
            if action == "arm":
                assert arguments[-4:] == ["--kind", recovery.CRASH_FAULT, "--renderer-worker-generation", str(self.initial_generation)]
                self.crash_receipt = {
                    "kind": recovery.CRASH_FAULT, "state": "crashRequested", "machineID": self.machine,
                    "operationID": arguments[arguments.index("--operation-id") + 1],
                    "resolvedPlanSHA256": arguments[arguments.index("--plan-sha256") + 1],
                    "campaignManifestSHA256": arguments[arguments.index("--manifest-sha256") + 1],
                    "challenge": arguments[arguments.index("--challenge") + 1], "rendererWorkerGeneration": self.initial_generation,
                    "rendererCrashRequestNanoseconds": 1500, "rendererCrashAcknowledgedNanoseconds": 1600,
                    "rendererInFlightCommandCount": 0,
                }
                if self.failure == "crash-rejected": self.crash_receipt["state"] = "crashRejected"
            elif action == "observe":
                self.crash_receipt.update(state="workerLost", rendererWorkerInterruptedNanoseconds=1700)
                if self.failure == "no-crash-ack": self.crash_receipt.pop("rendererCrashAcknowledgedNanoseconds")
                if self.failure == "no-crash-interruption": self.crash_receipt.pop("rendererWorkerInterruptedNanoseconds")
                self.generation = self.initial_generation + 1
                self.unavailable = self.failure == "temporarily-unavailable"
            else:
                self.crash_receipt["state"] = "cancelled"
            body = copy.deepcopy(self.crash_receipt)
        else:
            argv = arguments[arguments.index("--") + 1:]
            assert arguments[:2] == ["exec", self.machine]
            if argv[-1].startswith("action, nonce, network = "):
                action, nonce, network = ast.literal_eval(argv[-1].splitlines()[0].split(" = ", 1)[1])
                guest = journey.observation(action, network, self.number)
                guest["nonce"] = nonce
                if action == "boot" and self.architecture == "x86_64":
                    guest["architecture"] = "x86_64"
                    if network == "shared-nat":
                        guest["repositoryURL"] = "https://archive.ubuntu.com/ubuntu/dists/noble/Release"
            else:
                action, nonce, encoded, source_hash, runtime = ast.literal_eval(argv[-1].splitlines()[0].split(" = ", 1)[1])
                guest = {"action": action, "nonce": nonce, "bootID": journey.boot(self.number),
                         "unit": "dory-renderer-liveness-" + nonce + ".service"}
                if action == "prepare":
                    guest.update(started=True, sourceSHA256=source_hash, runtimeMaxSeconds=runtime)
                elif action == "observe":
                    self.observations += 1
                    value = {"kind": "dev.dory.renderer-liveness", "schemaVersion": 1,
                             "nonce": nonce, "bootID": journey.boot(self.number), "processID": 222,
                             "processStartTicks": 1000, "progressCounter": self.observations,
                             "memoryBytes": 2 * 1024 * 1024, "volatileMemorySHA256": "a" * 64,
                             "payloadSHA256": recovery.payload_hash(nonce), "sourceSHA256": source_hash,
                             "fileFsync": True, "directoryFsync": True}
                    if self.observations > 1:
                        if self.failure == "new-process": value["processID"] += 1
                        if self.failure == "memory-loss": value["volatileMemorySHA256"] = "b" * 64
                        if self.failure == "corrupt-disk": value["payloadSHA256"] = "b" * 64
                        if self.failure == "no-progress": value["progressCounter"] = 1
                    guest.update(observation=value, activeState="active", mainPID=value["processID"])
                else:
                    guest.update(stopped=self.failure != "cleanup", payloadSHA256=recovery.payload_hash(nonce))
            body = {"schema": "dev.dory.machine.exec", "version": 1, "machine": self.machine, "argv": argv,
                    "exitCode": 0, "timedOut": False, "stdoutTruncated": False, "stderrTruncated": False,
                    "stdout": json.dumps(guest), "stderr": ""}
        self.sequence += 1
        name = f"renderer-recovery-{self.sequence:04d}-{label}.json"
        argv = [str(self.ctl), "--mach-service", self.service, "--timeout", str(timeout or self.timeout), "machine", *arguments]
        self.evidence.write(name, {"argv": argv, "returnCode": 0, "timedOut": False,
                                   "stdout": json.dumps(body), "stderr": ""})
        return copy.deepcopy(body), name

    @contextmanager
    def restart(self, status, frame):
        request = {"kind": "dev.dory.display-qualification-renderer-restart-request", "schemaVersion": 1,
                   "machineID": self.machine, "machServiceName": self.service, "operationID": status["runtimeGraphicsSelection"]["operationID"],
                   "nonce": NONCE, "beforeRendererGeneration": 7, "beforeDisplayResourceGeneration": frame["displayResourceGeneration"],
                   "beforeFrameSequence": frame["frameSequence"]}
        self.evidence.write(recovery.REQUEST, request)
        window = journey.window(status)
        window.update(machineID=self.machine, machServiceName=self.service,
                      windowTitle=f"Dory — {self.machine} — Display 1", displayResourceGeneration=3, frameSequence=46)
        self.evidence.write(recovery.WINDOW, window)
        ack = {"kind": "dev.dory.display-qualification-renderer-restart", "schemaVersion": 1,
               "delivery": "runner-applied", "rendererRecoveryVerified": False, "bundleIdentifier": "com.pythonxi.Dory",
               "processID": window["processID"], "requestSHA256": lifecycle.digest((self.evidence.directory / recovery.REQUEST).read_bytes()),
               "completedAt": "2026-10-02T00:00:00Z", "commandSequence": 100,
               "commandFrameSequence": 46, "commandDisplayResourceGeneration": 3, "commandMetalCommandBufferCompletionID": 1,
               **{key: request[key] for key in ("machineID", "machServiceName", "operationID", "nonce",
                                               "beforeRendererGeneration", "beforeDisplayResourceGeneration", "beforeFrameSequence")}}
        self.evidence.write(recovery.ACK, ack)
        self.generation = 8
        yield [recovery.REQUEST, recovery.ACK, recovery.WINDOW]

    def capture(self, plan, phase, nonce, candidate):
        root = self.evidence.directory / ("renderer-recovery-" + phase + "-redraw")
        root.mkdir()
        ready = plan["probeReadyFileTemplate"].replace("{nonce}", nonce)
        operation = self.status()["runtimeGraphicsSelection"]["operationID"]
        PIXELS["build_fixture"](root, nonce=nonce, machine_id=self.machine, operation_id=operation, mach_service=self.service,
                                worker_generation=self.generation, frame_sequence=44 if phase == "before" else 54,
                                display_generation=8 if phase == "before" else 9, ready_file=ready)
        if self.architecture == "x86_64":
            receipt = root / "gpu-probe-build-receipt.txt"
            receipt.write_text(receipt.read_text().replace("architecture=aarch64\n", "architecture=x86_64\n"))
            if self.graphics_backend == "virgl":
                for name in ("gpu-probe.json", "gpu-display-evidence.json"):
                    body = json.loads((root / name).read_text())
                    body.update(deviceName="virgl (Apple M4)", driver="virgl")
                    PIXELS["write_json"](root / name, body)
            PIXELS["refresh_chain"](root)
        PIXELS["write_json"](root / "campaign-challenge.json", {"kind": "dev.dory.gpu-campaign-challenge", "schemaVersion": 1,
            "candidateID": candidate, "machineID": self.machine, "operationID": operation, "nonce": nonce})
        env = ["env", "DORY_GPU_PROBE_NONCE=" + nonce, "DORY_GPU_PROBE_READY_FILE=" + ready]
        for filename, key, output in [("guest-command-transport.json", "guestCommand", plan["expectedOutput"]),
                                     ("gpu-probe-transport.json", "probeResultCommand", (root / "gpu-probe.json").read_text()),
                                     ("gpu-probe-build-transport.json", "probeBuildReceiptCommand", (root / "gpu-probe-build-receipt.txt").read_text())]:
            PIXELS["write_json"](root / filename, {"schema": "dev.dory.machine.exec", "version": 1,
                "machine": self.machine, "argv": env + ["sh", "-ec", plan[key]], "exitCode": 0,
                "timedOut": False, "stdoutTruncated": False, "stderrTruncated": False, "stdout": output, "stderr": ""})
        raw = {"argv": recovery.capture_argv(self, plan, phase, nonce, candidate), "returnCode": 0, "timedOut": False,
               "stdout": "", "stderr": "", "files": recovery.capture_files(root), "verification": recovery.pixels.verify(root, nonce)}
        return self.evidence.write("renderer-recovery-" + phase + "-capture.json", raw)


def write_fixture(directory, machine=MACHINE, service=SERVICE, mode="controlled-restart"):
    """Shared outer-gate fixture builder. This is a synthetic model, never a real guest run."""
    global MACHINE, SERVICE
    MACHINE, SERVICE = machine, service
    journey.MACHINE, journey.SERVICE = machine, service
    evidence = lifecycle.Evidence(directory)
    fault = evidence.read("fault-retry.json")
    number = int(fault["bootID"].replace("-", ""), 16)
    campaign = ModelCampaign(evidence, initial_number=number, mode=mode)
    with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
        result = recovery.run_recovery(campaign, PLAN)
    for name in ("renderer-recovery.out", "renderer-recovery-gate-verification.json"):
        evidence.write(name, result)
    path = directory / "scenario-driver-readiness.json"
    readiness = json.loads(path.read_text())
    readiness.update(rendererRecoverySHA256=lifecycle.digest((directory / recovery.PROOF).read_bytes()),
                     rendererRecoveryRunnerSHA256=lifecycle.digest(Path(recovery.__file__).read_bytes()), rendererRecoveryMode=mode)
    path.write_text(json.dumps(readiness))
    (directory / "machine-status-final.json").write_text(json.dumps(campaign.status()))
    return campaign


class RendererRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dory-renderer-recovery-unit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.evidence = lifecycle.Evidence(self.root)
        self.evidence.write("campaign-authority.json", {"kind": "dev.dory.virtual-machine-candidate-campaign-authorization",
            "schemaVersion": 2, "applicationRoot": str(APP), "machineIDPrefix": "readiness-arm-ubuntu-",
            "candidateInventorySHA256": CANDIDATE})

    def fixture(self, failure=None, mode="controlled-restart"):
        campaign = ModelCampaign(self.evidence, failure, mode=mode)
        with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
            recovery.run_recovery(campaign, PLAN)
        return campaign

    def permit_crash(self):
        path = self.root / "campaign-authority.json"
        body = json.loads(path.read_text())
        body["cells"] = [{"capability": {"backend": "dory-hypervisor", "guest": {"architecture": "arm64", "family": "linux"}},
                          "faultPolicy": {"permittedFaults": [recovery.CRASH_FAULT], "maximumArmingCount": 1,
                                          "maximumArmedMilliseconds": 10_000}}]
        path.write_text(json.dumps(body))

    def test_abrupt_crash_replays_actual_loss_and_same_boot_witness_without_claiming_context_survival(self):
        self.permit_crash()
        campaign = self.fixture(mode="unexpected-worker-crash")
        result = self.replay()
        self.assertEqual(result["mode"], "unexpected-worker-crash")
        proof = self.evidence.read(recovery.PROOF)
        self.assertTrue(proof["unexpectedRendererDeathTested"])
        self.assertFalse(proof["survivingGPUContextVerified"])
        self.assertFalse(proof["releaseEligible"])
        self.assertTrue((self.root / recovery.CRASH_REQUEST).exists())
        self.assertFalse((self.root / recovery.REQUEST).exists())
        self.assertFalse(any(call[0] in {"start", "stop", "update", "restart"} for call in campaign.calls))
        self.assertEqual(sum(call[:1] == ["qualification-fault"] and call[3] == "arm" for call in campaign.calls), 1)

    def test_abrupt_crash_rejects_missing_policy_before_any_commands(self):
        campaign = ModelCampaign(self.evidence, mode="unexpected-worker-crash")
        with self.assertRaises(lifecycle.LifecycleError): recovery.run_recovery(campaign, PLAN)
        self.assertEqual(campaign.calls, [])

    def test_abrupt_crash_requires_ack_and_interruption_and_attempts_cancellation_on_failure(self):
        self.permit_crash()
        for failure in ("no-crash-ack", "no-crash-interruption", "crash-rejected"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                evidence = lifecycle.Evidence(Path(directory))
                evidence.write("campaign-authority.json", self.evidence.read("campaign-authority.json"))
                campaign = ModelCampaign(evidence, failure, mode="unexpected-worker-crash")
                with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
                    with self.assertRaises(lifecycle.LifecycleError): recovery.run_recovery(campaign, PLAN)
                self.assertFalse((Path(directory) / recovery.PROOF).exists())
                self.assertTrue(any(call[:1] == ["qualification-fault"] and "cancel" in call for call in campaign.calls))
                self.assertIn("'cleanup'", campaign.calls[-1][-1].splitlines()[0])

    def test_recovery_allows_only_bounded_pre_redraw_graphics_unavailability(self):
        self.permit_crash()
        with patch.object(recovery.time, "sleep"):
            self.fixture("temporarily-unavailable", mode="unexpected-worker-crash")
        self.assertEqual(self.replay()["mode"], "unexpected-worker-crash")
        self.mutate_control(lambda raw: raw["argv"][-2:] == ["status", MACHINE]
                            and json.loads(raw["stdout"]).get("runtimeGraphicsSelection") is not None
                            and json.loads(raw["stdout"])["runtimeGraphicsSelection"]["rendererGeneration"] == 8,
                            lambda raw: raw.update(stdout=json.dumps({**json.loads(raw["stdout"]), "runtimeGraphicsSelection": None})))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_crash_replay_rejects_rehashed_generation_identity_and_incomplete_or_rewritten_facts(self):
        self.permit_crash()
        self.fixture(mode="unexpected-worker-crash")
        proof = self.evidence.read(recovery.PROOF)
        name = next(name for name in proof["observations"] if name.endswith("crash-observe.json"))
        path, original = self.root / name, self.evidence.read(name)
        mutations = {"rendererWorkerGeneration": 8, "challenge": journey.boot(999),
                     "rendererCrashAcknowledgedNanoseconds": None, "rendererWorkerInterruptedNanoseconds": None,
                     "rendererInFlightCommandCount": True, "guestPhysicalAddress": 16384,
                     "rendererCrashRequestNanoseconds": 1400, "rendererCrashAcknowledgedNanoseconds-rewritten": 1650,
                     "rendererWorkerInterruptedNanoseconds-unbounded": 30_000_002_000,
                     "rendererWorkerInterruptedNanoseconds-signed-budget": 10_000_002_000}
        for key, value in mutations.items():
            with self.subTest(key=key):
                raw = copy.deepcopy(original); body = json.loads(raw["stdout"])
                body[key.split("-")[0]] = value
                raw["stdout"] = json.dumps(body); path.write_text(json.dumps(raw)); self.rehash()
                with self.assertRaises(lifecycle.LifecycleError): self.replay()
        path.write_text(json.dumps(original)); self.rehash()
        self.assertEqual(self.replay()["mode"], "unexpected-worker-crash")

    def test_crash_replay_rejects_rehashed_wrong_dispatch_generation(self):
        self.permit_crash()
        self.fixture(mode="unexpected-worker-crash")
        def mutate(raw):
            raw["argv"][raw["argv"].index("--renderer-worker-generation") + 1] = "8"
        self.mutate_control(lambda raw: "--renderer-worker-generation" in raw["argv"], mutate)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_controlled_restart_cannot_be_relabeled_as_an_unexpected_crash(self):
        self.permit_crash()
        self.fixture()
        path = self.root / recovery.PROOF; proof = self.evidence.read(recovery.PROOF)
        proof.update(mode="unexpected-worker-crash", unexpectedRendererDeathTested=True)
        path.write_text(json.dumps(proof))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def replay(self):
        return recovery.verify_recovery(self.evidence, MACHINE, SERVICE, APP)

    def rehash(self):
        path = self.root / recovery.PROOF
        body = json.loads(path.read_text())
        body["references"] = self.evidence.references(body["observations"])
        path.write_text(json.dumps(body))

    def mutate_control(self, predicate, mutate):
        proof = self.evidence.read(recovery.PROOF)
        for name in proof["observations"]:
            raw = self.evidence.read(name)
            if "argv" not in raw or not predicate(raw): continue
            mutate(raw)
            (self.root / name).write_text(json.dumps(raw))
            self.rehash()
            return
        self.fail("missing fixture control")

    def test_complete_same_boot_recovery_replays_actual_pixel_oracle(self):
        campaign = self.fixture()
        result = self.replay()
        self.assertEqual(result["afterRendererGeneration"], 8)
        self.assertEqual(result["beforeRendererGeneration"], 7)
        self.assertFalse(result["releaseEligible"])
        self.assertFalse(any(call[0] in {"start", "stop", "update"} for call in campaign.calls))

    def test_guest_identity_memory_disk_progress_and_cleanup_fail_closed(self):
        for failure in ("new-process", "memory-loss", "corrupt-disk", "no-progress", "cleanup", "new-operation"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                evidence = lifecycle.Evidence(Path(directory))
                evidence.write("campaign-authority.json", self.evidence.read("campaign-authority.json"))
                campaign = ModelCampaign(evidence, failure)
                with patch.object(recovery.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
                    with self.assertRaises(lifecycle.LifecycleError): recovery.run_recovery(campaign, PLAN)
                self.assertFalse((Path(directory) / recovery.PROOF).exists())
                self.assertIn("'cleanup'", campaign.calls[-1][-1].splitlines()[0])

    def test_production_or_cross_campaign_service_rejects_before_commands(self):
        campaign = ModelCampaign(self.evidence)
        campaign.service = "dev.dory.doryd"
        with self.assertRaises(lifecycle.LifecycleError): recovery.run_recovery(campaign, PLAN)
        self.assertEqual(campaign.calls, [])

    def test_redraw_plan_requires_fresh_bounded_ready_marker(self):
        for key, value in (("probeReadyFileTemplate", "/tmp/reused.ready"),
                           ("probeReadyFileTemplate", "/tmp/../foreign/{nonce}"),
                           ("probeReadyFileTemplate", "/home/user/{nonce}"), ("graphicsTrace", "relative")):
            plan = dict(PLAN, **{key: value})
            with self.assertRaises(lifecycle.LifecycleError): recovery.check_plan(plan)

    def test_acknowledgement_cannot_claim_recovery(self):
        self.fixture()
        path = self.root / recovery.ACK
        ack = json.loads(path.read_text()); ack["rendererRecoveryVerified"] = True
        path.write_text(json.dumps(ack)); self.rehash()
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_command_frame_older_than_baseline_is_rejected(self):
        self.fixture(); path = self.root / recovery.ACK
        ack = json.loads(path.read_text()); ack["commandFrameSequence"] = 43
        path.write_text(json.dumps(ack)); self.rehash()
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_changed_source_bound_witness_command_is_rejected_after_rehash(self):
        self.fixture()
        self.mutate_control(lambda raw: "exec" in raw["argv"] and "'prepare'" in raw["argv"][-1].splitlines()[0],
                            lambda raw: raw["argv"].__setitem__(-1, raw["argv"][-1] + "\nprint('forged')"))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rebooted_guest_with_rehashed_receipts_is_rejected(self):
        self.fixture()
        def mutate(raw):
            transport = json.loads(raw["stdout"]); guest = json.loads(transport["stdout"])
            guest["bootID"] = journey.boot(999); transport["stdout"] = json.dumps(guest); raw["stdout"] = json.dumps(transport)
        self.mutate_control(lambda raw: "exec" in raw["argv"] and "'cleanup'" in raw["argv"][-1].splitlines()[0], mutate)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_missing_cleanup_or_final_runtime_observation_is_rejected(self):
        self.fixture()
        path = self.root / recovery.PROOF
        original = json.loads(path.read_text())
        for suffix in ("cleanup.json", "status.json"):
            body = copy.deepcopy(original)
            name = next(name for name in reversed(body["observations"]) if name.endswith(suffix))
            body["observations"].remove(name); body["references"].pop(name)
            path.write_text(json.dumps(body))
            with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_reordered_raw_commands_are_rejected(self):
        self.fixture()
        path = self.root / recovery.PROOF; body = json.loads(path.read_text())
        indexes = [index for index, name in enumerate(body["observations"]) if re_full_control(name)]
        body["observations"][indexes[0]], body["observations"][indexes[1]] = body["observations"][indexes[1]], body["observations"][indexes[0]]
        path.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_foreign_restart_operation_is_rejected(self):
        self.fixture(); path = self.root / recovery.REQUEST
        request = json.loads(path.read_text()); request["operationID"] = journey.boot(999)
        path.write_text(json.dumps(request)); self.rehash()
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_changed_redraw_command_transport_is_rejected(self):
        self.fixture()
        root = self.root / "renderer-recovery-after-redraw"
        path = root / "guest-command-transport.json"; body = json.loads(path.read_text())
        body["argv"][-1] = "borrow-another-result"; path.write_text(json.dumps(body))
        raw_path = self.root / "renderer-recovery-after-capture.json"; raw = json.loads(raw_path.read_text())
        raw["files"] = recovery.capture_files(root); raw_path.write_text(json.dumps(raw)); self.rehash()
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_coherent_fresh_pixels_from_the_retired_worker_are_rejected(self):
        self.fixture()
        root = self.root / "renderer-recovery-after-redraw"
        path = root / "graphics-trace.ndjson"
        events = [json.loads(line) for line in path.read_text().splitlines()]
        for event in events:
            event["context"]["workerGeneration"] = 7
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        frame = json.loads((root / "display-capture-frame.json").read_text())
        chain = recovery.pixels.TRACE_CHAIN.verify(events, frame)
        for name in ("graphics-correlation.json", "gpu-display-evidence.json"):
            file = root / name; body = json.loads(file.read_text()); body.update(chain); file.write_text(json.dumps(body))
        PIXELS["refresh_chain"](root)
        verification = recovery.pixels.verify(root, "2" * 32)
        self.assertEqual(verification["workerGeneration"], 7)
        raw_path = self.root / "renderer-recovery-after-capture.json"; raw = json.loads(raw_path.read_text())
        raw.update(files=recovery.capture_files(root), verification=verification)
        raw_path.write_text(json.dumps(raw)); self.rehash()
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_runner_ack_without_completed_generation_cannot_qualify(self):
        self.fixture()
        def mutate(raw):
            body = json.loads(raw["stdout"])
            body["runtimeGraphicsSelection"].update(rendererGeneration=7, rendererWorkerReceiptSHA256="7" * 64)
            raw["stdout"] = json.dumps(body)
        self.mutate_control(lambda raw: raw["argv"][-2:] == ["status", MACHINE]
                            and json.loads(raw["stdout"])["runtimeGraphicsSelection"]["rendererGeneration"] == 8, mutate)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_wrong_pixels_fail_even_if_all_digest_receipts_match(self):
        self.fixture(); root = self.root / "renderer-recovery-after-redraw"
        PIXELS["write_challenge_png"](root / "framebuffer.png", "2" * 32, 180, blank=True)
        PIXELS["refresh_chain"](root)
        raw_path = self.root / "renderer-recovery-after-capture.json"; raw = json.loads(raw_path.read_text())
        raw["files"] = recovery.capture_files(root); raw_path.write_text(json.dumps(raw)); self.rehash()
        with self.assertRaises((lifecycle.LifecycleError, ValueError)): self.replay()

    def test_witness_source_is_bounded_and_syntax_valid(self):
        source = recovery.direct_bytes(recovery.WITNESS, 65536)
        compile(source, str(recovery.WITNESS), "exec")
        for action in ("prepare", "observe", "cleanup"):
            compile(recovery.guest_script(action, NONCE, source, 150), "guest-controller", "exec")
        self.assertIn(b"os.urandom(2 * 1024 * 1024)", source)


def re_full_control(name):
    import re
    return re.fullmatch(r"renderer-recovery-[0-9]{4}-[a-z-]+\.json", name) is not None


if __name__ == "__main__":
    unittest.main()
