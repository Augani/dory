#!/usr/bin/env python3
"""Request a controlled restart or signed-policy abrupt renderer crash, then replay recovery.

Only the abrupt mode tests unexpected worker death, using a dedicated authenticated self-kill
RPC, never a PID supplied by this script. CPU/fsync survival is not GL-context survival. Outer
candidate/signature admission remains mandatory; no receipt authorizes a public release.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lifecycle = load("dory_renderer_lifecycle", ROOT / "scripts/arm-ubuntu-desktop-lifecycle.py")
pixels = load("dory_renderer_pixels", ROOT / "guest-probes/verify-displayed-pixel.py")
require = lifecycle.require
KIND = "dev.dory.installed-desktop-renderer-recovery"
DRIVER = ROOT / "scripts/arm-ubuntu-scenario-driver.sh"
WITNESS = ROOT / "guest-probes/renderer-liveness.py"
PROOF = "renderer-recovery.json"
PLAN = "renderer-recovery-plan.json"
REQUEST = "renderer-recovery-restart.request.json"
ACK = "renderer-recovery-restart.receipt.json"
WINDOW = "renderer-recovery-restart-window.json"
PHASES = ("before", "after")
MODES = ("controlled-restart", "unexpected-worker-crash")
CRASH_REQUEST = "renderer-recovery-crash.request.json"
CRASH_FAULT = "renderer-worker-sigkill"


def direct_bytes(path, limit=8 * 1024 * 1024, empty=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and (empty or info.st_size > 0) and info.st_size <= limit,
                "indirect, empty or unbounded renderer evidence: " + str(path))
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
        require(len(data) == info.st_size and len(data) <= limit
                and (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                "renderer evidence changed during read")
        return data


def source_hashes(architecture="arm64"):
    paths = [Path(__file__), DRIVER, WITNESS, ROOT / "scripts/arm-ubuntu-desktop-lifecycle.py",
             ROOT / "guest-probes/verify-displayed-pixel.py", ROOT / "guest-probes/pixel-oracle.py",
             ROOT / "guest-probes/graphics-trace-chain.py", ROOT / "guest-probes/validate-result.py",
             ROOT / "guest-probes/verify-build-receipt.py"]
    if architecture == "x86_64":
        paths.append(ROOT / "scripts/pc-ubuntu-renderer-recovery.py")
    return {str(path.relative_to(ROOT)): lifecycle.digest(direct_bytes(path)) for path in paths}


def authority(evidence, machine, service, app, architecture="arm64"):
    require(architecture in {"arm64", "x86_64"}, "unsupported renderer campaign ISA")
    prefix, endpoint = ("readiness-arm-ubuntu-", "dev.dory.readiness.armubuntu.") if architecture == "arm64" \
        else ("wave0-pc-gpu-", "dev.dory.wave0.pcgpu.")
    require(re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9-]+", machine) is not None
            and service == endpoint + machine.removeprefix(prefix),
            "renderer recovery is restricted to the exact isolated ISA campaign")
    body = evidence.read("campaign-authority.json")
    require(body.get("kind") == "dev.dory.virtual-machine-candidate-campaign-authorization"
            and body.get("schemaVersion") == 2 and body.get("applicationRoot") == str(app)
            and body.get("machineIDPrefix") == prefix
            and lifecycle.sha256_value(body.get("candidateInventorySHA256")),
            "renderer campaign authority does not bind this signed candidate")
    return lifecycle.digest(direct_bytes(evidence.directory / "campaign-authority.json")), body["candidateInventorySHA256"]


def check_plan(plan):
    keys = {"kind", "schemaVersion", "guestCommand", "expectedOutput", "probeResultCommand",
            "probeBuildReceiptCommand", "probeReadyFileTemplate", "graphicsTrace"}
    require(set(plan) == keys and plan["kind"] == KIND + "-redraw-plan" and plan["schemaVersion"] == 1,
            "unexpected renderer redraw plan")
    for key in keys - {"kind", "schemaVersion"}:
        require(isinstance(plan[key], str) and 1 <= len(plan[key].encode()) <= 16384 and "\0" not in plan[key],
                "missing or unbounded redraw plan field: " + key)
    template = plan["probeReadyFileTemplate"]
    require(template.count("{nonce}") == 1 and "{" not in template.replace("{nonce}", "")
            and "}" not in template.replace("{nonce}", "") and len(template) <= 4096,
            "ready file must contain exactly one explicit {nonce} placeholder")
    path = Path(template.replace("{nonce}", "a" * 32))
    require(path.is_absolute() and str(path) == template.replace("{nonce}", "a" * 32)
            and ".." not in path.parts and str(path).startswith(("/tmp/", "/var/lib/dory/qualification/")),
            "redraw ready marker is not a normalized run-owned guest path")
    trace = Path(plan["graphicsTrace"])
    require(trace.is_absolute() and str(trace) == plan["graphicsTrace"] and ".." not in trace.parts,
            "graphics trace path is not exact and absolute")
    return plan


GUEST_SOURCE = r'''
import base64, hashlib, json, os, stat, subprocess
from pathlib import Path
root = Path('/var/lib/dory/qualification') / ('renderer-recovery-' + nonce)
unit = 'dory-renderer-liveness-' + nonce + '.service'
boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
def properties():
    rows = subprocess.check_output(['systemctl', 'show', unit,
                                    '--property=LoadState,MainPID,ActiveState'], text=True, timeout=5)
    return dict(row.split('=', 1) for row in rows.splitlines())
def read_file(name, limit, optional=False):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory)
    except FileNotFoundError:
        if optional: return None
        raise
    with os.fdopen(fd, 'rb') as target:
        info = os.fstat(target.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o077 or not 0 < info.st_size <= limit:
            raise RuntimeError('witness file is indirect, shared or unbounded')
        data = target.read(limit + 1)
        if len(data) != info.st_size: raise RuntimeError('witness file changed during read')
        return data
result = {'action': action, 'nonce': nonce, 'bootID': boot, 'unit': unit}
if action == 'prepare':
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.mkdir(mode=0o700)
directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    info = os.fstat(directory)
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('witness directory is not exclusively owned')
    if action == 'prepare':
        source = base64.b64decode(encoded_source, validate=True)
        if not 0 < len(source) <= 65536 or hashlib.sha256(source).hexdigest() != source_sha256:
            raise RuntimeError('witness source bytes changed')
        compile(source, 'renderer-liveness.py', 'exec')
        fd = os.open('witness.py', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'wb') as output:
            output.write(source); output.flush(); os.fsync(output.fileno())
        os.fsync(directory)
        if properties().get('LoadState') != 'not-found':
            raise RuntimeError('witness unit already exists')
        subprocess.run(['systemd-run', '--quiet', '--no-block', '--unit=' + unit,
                        '--property=RuntimeMaxSec=' + str(runtime_seconds) + 's', '--property=Restart=no',
                        '--property=KillMode=control-group', '--property=UMask=0077',
                        '/usr/bin/python3', str(root / 'witness.py'), '--root', str(root),
                        '--nonce', nonce, '--seconds', str(runtime_seconds)], check=True, timeout=10)
        result.update(started=True, sourceSHA256=source_sha256, runtimeMaxSeconds=runtime_seconds)
    elif action == 'observe':
        props = properties()
        data = read_file('progress.json', 4096, optional=True)
        observation = None if data is None else json.loads(data)
        if observation is not None and (props.get('ActiveState') != 'active' or props.get('MainPID') != str(observation['processID'])):
            raise RuntimeError('witness process is no longer the active unit owner')
        if hashlib.sha256(read_file('witness.py', 65536)).hexdigest() != source_sha256:
            raise RuntimeError('running witness source changed')
        result.update(observation=observation, activeState=props.get('ActiveState'), mainPID=int(props.get('MainPID', '0')))
    elif action == 'cleanup':
        if properties().get('LoadState') != 'not-found':
            subprocess.run(['systemctl', 'stop', unit], check=True, capture_output=True, timeout=10)
        props = properties()
        if props.get('MainPID') != '0' or props.get('ActiveState') not in ('inactive', 'failed'):
            raise RuntimeError('owned witness did not stop')
        data = read_file('durability.bin', 512 * 1024)
        expected = hashlib.sha256(nonce.encode('ascii')).digest() * 16384
        if data != expected: raise RuntimeError('durable witness bytes changed')
        result.update(stopped=True, payloadSHA256=hashlib.sha256(data).hexdigest())
    else:
        raise RuntimeError('unknown witness action')
finally:
    os.close(directory)
print(json.dumps(result, sort_keys=True, separators=(',', ':')))
'''


def guest_script(action, nonce, source, runtime_seconds):
    require(action in {"prepare", "observe", "cleanup"} and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None
            and type(runtime_seconds) is int and 1 <= runtime_seconds <= 7200, "invalid renderer witness intent")
    encoded = base64.b64encode(source).decode("ascii") if action == "prepare" else ""
    return "action, nonce, encoded_source, source_sha256, runtime_seconds = " + repr(
        (action, nonce, encoded, lifecycle.digest(source), runtime_seconds)) + "\n" + GUEST_SOURCE


def payload_hash(nonce):
    return lifecycle.digest(hashlib.sha256(nonce.encode("ascii")).digest() * 16384)


def check_witness(body, action, nonce, boot, source, runtime):
    require(body.get("action") == action and body.get("nonce") == nonce and body.get("bootID") == boot
            and body.get("unit") == "dory-renderer-liveness-" + nonce + ".service",
            "renderer witness belongs to another boot or challenge")
    if action == "prepare":
        require(body.get("started") is True and body.get("sourceSHA256") == lifecycle.digest(source)
                and type(body.get("runtimeMaxSeconds")) is int and body["runtimeMaxSeconds"] == runtime,
                "witness source or bounded unit lifetime changed")
    elif action == "cleanup":
        require(body.get("stopped") is True and body.get("payloadSHA256") == payload_hash(nonce),
                "witness cleanup lost its owned process or durable bytes")
    elif body.get("observation") is not None:
        value = body["observation"]
        require(isinstance(value, dict) and value.get("kind") == "dev.dory.renderer-liveness"
                and value.get("schemaVersion") == 1 and value.get("nonce") == nonce and value.get("bootID") == boot
                and value.get("sourceSHA256") == lifecycle.digest(source)
                and value.get("memoryBytes") == 2 * 1024 * 1024
                and lifecycle.sha256_value(value.get("volatileMemorySHA256"))
                and value.get("payloadSHA256") == payload_hash(nonce)
                and value.get("fileFsync") is True and value.get("directoryFsync") is True
                and all(type(value.get(key)) is int and value[key] > 0
                        for key in ("processID", "processStartTicks", "progressCounter"))
                and body.get("activeState") == "active" and type(body.get("mainPID")) is int
                and body["mainPID"] == value["processID"], "guest CPU/memory/fsync witness is incomplete")


def same_witness(before, after):
    keys = {"nonce", "bootID", "processID", "processStartTicks", "memoryBytes", "volatileMemorySHA256",
            "payloadSHA256", "sourceSHA256"}
    require(all(before[key] == after[key] for key in keys)
            and after["progressCounter"] > before["progressCounter"],
            "renderer restart lost the guest process, volatile memory, fsynced bytes or forward progress")


def check_runtime(status, campaign, before=None):
    lifecycle.check_status(status, campaign.machine, network=campaign.network,
                           architecture=campaign.architecture, graphics_backend=campaign.graphics_backend)
    if before is not None:
        left, right = before["runtimeGraphicsSelection"], status["runtimeGraphicsSelection"]
        require(status["runtimeIdentity"] == before["runtimeIdentity"]
                and right["operationID"] == left["operationID"]
                and right["rendererGeneration"] >= left["rendererGeneration"],
                "renderer recovery restarted or replaced the VM operation")


def check_recovery_status(status, campaign, before):
    # The live graphics receipt is deliberately revoked while its worker is unavailable. That
    # interval must be allowed, but it is never evidence of recovered GPU output or a live worker.
    require(status.get("id") == campaign.machine and status.get("guestArchitecture") == campaign.architecture
            and status.get("state") == "running" and status.get("installerMediaAttached") is False
            and isinstance(status.get("typedSettings"), dict)
            and status["typedSettings"].get("networkMode") == campaign.network
            and status.get("runtimeIdentity") == before["runtimeIdentity"],
            "renderer recovery stopped the VM or changed its resolved plan/network/media")
    if status.get("runtimeGraphicsSelection") is None:
        return False
    check_runtime(status, campaign, before)
    return True


def crash_policy(evidence, architecture="arm64"):
    require(architecture in {"arm64", "x86_64"}, "unsupported renderer fault ISA")
    body = evidence.read("campaign-authority.json")
    cells = body.get("cells")
    require(isinstance(cells, list), "renderer crash requires an explicit signed cell policy")
    budgets = []
    for cell in cells:
        if not isinstance(cell, dict):
            continue
        capability, policy = cell.get("capability"), cell.get("faultPolicy")
        if (isinstance(capability, dict) and capability.get("backend") == "dory-hypervisor"
                and capability.get("guest") == {"architecture": architecture, "family": "linux"}
                and isinstance(policy, dict) and set(policy) == {"permittedFaults", "maximumArmingCount", "maximumArmedMilliseconds"}
                and isinstance(policy.get("permittedFaults"), list)
                and all(isinstance(value, str) for value in policy["permittedFaults"])
                and policy["permittedFaults"] == sorted(set(policy["permittedFaults"]))
                and CRASH_FAULT in policy["permittedFaults"]
                and (architecture == "arm64" or (capability.get("graphics") == "hardware-accelerated-3d"
                     and policy["permittedFaults"] == [CRASH_FAULT]))
                and type(policy.get("maximumArmingCount")) is int and 1 <= policy["maximumArmingCount"] <= 8
                and type(policy.get("maximumArmedMilliseconds")) is int and 1 <= policy["maximumArmedMilliseconds"] <= 30_000):
            budgets.append(policy["maximumArmedMilliseconds"])
    require(bool(budgets), "signed selected-ISA campaign does not permit renderer-worker-sigkill")
    # The daemon resolves the exact cell. Independent replay conservatively uses the shortest
    # eligible window rather than widening a short policy with another cell's longer allowance.
    return min(budgets)


def crash_request(campaign, status, frame, manifest):
    return {"kind": KIND + "-crash-request", "schemaVersion": 1, "machineID": campaign.machine,
            "machServiceName": campaign.service, "operationID": status["runtimeGraphicsSelection"]["operationID"],
            "resolvedPlanSHA256": status["runtimeIdentity"]["planSHA256"], "campaignManifestSHA256": manifest,
            "challenge": str(uuid.UUID(hex=campaign.nonce)),
            "maximumArmedMilliseconds": crash_policy(campaign.evidence, campaign.architecture),
            "rendererWorkerGeneration": status["runtimeGraphicsSelection"]["rendererGeneration"],
            "beforeFrameSequence": frame["frameSequence"], "beforeDisplayResourceGeneration": frame["displayResourceGeneration"]}


def crash_arguments(request, action):
    require(action in {"arm", "observe", "cancel"}, "unknown renderer fault action")
    result = ["qualification-fault", request["machineID"], "--action", action,
              "--operation-id", request["operationID"].lower(), "--plan-sha256", request["resolvedPlanSHA256"],
              "--manifest-sha256", request["campaignManifestSHA256"], "--challenge", request["challenge"]]
    return result + (["--kind", CRASH_FAULT, "--renderer-worker-generation", str(request["rendererWorkerGeneration"])]
                     if action == "arm" else [])


def check_crash_observation(body, request, previous=None):
    require(isinstance(body, dict) and body.get("kind") == CRASH_FAULT
            and body.get("state") in {"crashRequested", "workerLost"}
            and body.get("machineID") == request["machineID"]
            and isinstance(body.get("operationID"), str) and body["operationID"].lower() == request["operationID"].lower()
            and isinstance(body.get("challenge"), str) and body["challenge"].lower() == request["challenge"]
            and body.get("resolvedPlanSHA256") == request["resolvedPlanSHA256"]
            and body.get("campaignManifestSHA256") == request["campaignManifestSHA256"]
            and type(body.get("rendererWorkerGeneration")) is int
            and body["rendererWorkerGeneration"] == request["rendererWorkerGeneration"]
            and all(body.get(key) is None for key in ("injectedErrno", "guestStatus", "queueIndex", "queueGeneration",
                "guestPhysicalAddress", "virtualCPUIndex", "instructionAddress", "faultExitCount", "retryCount",
                "guestException", "memoryProtectionRestored")), "renderer fault receipt changed its exact grant or fault class")
    requested = body.get("rendererCrashRequestNanoseconds")
    acknowledged, interrupted = body.get("rendererCrashAcknowledgedNanoseconds"), body.get("rendererWorkerInterruptedNanoseconds")
    count = body.get("rendererInFlightCommandCount")
    deadline = min(2**64, requested + request["maximumArmedMilliseconds"] * 1_000_000) if type(requested) is int else 0
    require(type(requested) is int and 0 < requested < 2**64, "missing monotonic renderer crash request")
    require((acknowledged is None and count is None)
            or (type(acknowledged) is int and requested <= acknowledged < deadline
                and type(count) is int and 0 <= count <= 65535), "malformed renderer crash acknowledgement")
    require(interrupted is None or (type(interrupted) is int
            and requested <= interrupted < deadline), "missing/beyond-budget renderer interruption")
    require((body["state"] == "workerLost") == (acknowledged is not None and interrupted is not None),
            "renderer death requires both worker acceptance and actual connection interruption")
    if previous is not None:
        require(previous["rendererCrashRequestNanoseconds"] == requested
                and all(previous.get(key) is None or previous[key] == body.get(key) for key in
                    ("rendererCrashAcknowledgedNanoseconds", "rendererWorkerInterruptedNanoseconds", "rendererInFlightCommandCount"))
                and (previous["state"] != "workerLost" or body["state"] == "workerLost"),
                "renderer fault observations rewrote or lost an already witnessed fact")


def same_renderer_owner(left, right):
    keys = ("operationID", "resolvedPlanSHA256", "backend", "rendererGeneration", "rendererWorkerReceiptSHA256")
    return all(left.get(key) == right.get(key) for key in keys)


def check_request(request, campaign, status, frame):
    expected = {"kind": "dev.dory.display-qualification-renderer-restart-request", "schemaVersion": 1,
                "machineID": campaign.machine, "machServiceName": campaign.service,
                "operationID": status["runtimeGraphicsSelection"]["operationID"], "nonce": campaign.nonce,
                "beforeRendererGeneration": status["runtimeGraphicsSelection"]["rendererGeneration"],
                "beforeDisplayResourceGeneration": frame["displayResourceGeneration"], "beforeFrameSequence": frame["frameSequence"]}
    require(request == expected, "restart request is stale or for another operation/generation")


def check_ack(ack, request, request_hash, window, campaign, status):
    lifecycle.check_window(window, status, campaign.machine, campaign.service)
    require(ack.get("kind") == "dev.dory.display-qualification-renderer-restart" and ack.get("schemaVersion") == 1
            and ack.get("delivery") == "runner-applied" and ack.get("rendererRecoveryVerified") is False
            and ack.get("bundleIdentifier") == "com.pythonxi.Dory" and ack.get("processID") == window["processID"]
            and ack.get("requestSHA256") == request_hash and isinstance(ack.get("completedAt"), str)
            and all(ack.get(key) == request[key] for key in ("machineID", "machServiceName", "operationID", "nonce",
                                                           "beforeRendererGeneration", "beforeDisplayResourceGeneration", "beforeFrameSequence"))
            and type(ack.get("commandSequence")) is int and 0 < ack["commandSequence"] < 2**64
            and all(type(ack.get(key)) is int and 0 < ack[key] < 2**64 for key in
                    ("commandFrameSequence", "commandDisplayResourceGeneration", "commandMetalCommandBufferCompletionID"))
            and ack["commandFrameSequence"] >= max(request["beforeFrameSequence"], window["frameSequence"])
            and ack["commandMetalCommandBufferCompletionID"] >= window["metalCommandBufferCompletionID"],
            "restart acknowledgement does not bind the pre-restart signed-app frame and exact intent")
    if ack["commandFrameSequence"] == window["frameSequence"]:
        require(ack["commandDisplayResourceGeneration"] == window["displayResourceGeneration"],
                "restart command frame disagrees with this app's initial Metal-completed frame")


def capture_argv(campaign, plan, phase, nonce, candidate):
    profile = ["--guest-architecture", "x86_64"] if campaign.architecture == "x86_64" else []
    return ["/bin/bash", str(DRIVER), "--capture-only", *profile, "--app", str(campaign.app), "--ctl", str(campaign.ctl),
            "--mach-service", campaign.service, "--machine", campaign.machine, "--run-directory",
            str(campaign.evidence.directory / ("renderer-recovery-" + phase + "-redraw")),
            "--guest-command", plan["guestCommand"], "--expected-output", plan["expectedOutput"],
            "--probe-result-command", plan["probeResultCommand"],
            "--probe-build-receipt-command", plan["probeBuildReceiptCommand"], "--probe-nonce", nonce,
            "--component-candidate-inventory-sha256", candidate,
            "--probe-ready-file", plan["probeReadyFileTemplate"].replace("{nonce}", nonce),
            "--graphics-trace", plan["graphicsTrace"], "--timeout-seconds", str(min(campaign.timeout, 120))]


def capture_files(root):
    require(root.is_dir() and not root.is_symlink(), "redraw evidence directory is indirect")
    result, total = {}, 0
    for path in sorted(root.iterdir()):
        if path.name == "home":
            require(path.is_dir() and not path.is_symlink(), "capture home is indirect")
            continue  # Private app configuration, not an authority or a pixel receipt.
        require(re.fullmatch(r"[a-z0-9.-]+", path.name) is not None, "invalid redraw evidence filename")
        data = direct_bytes(path, 64 * 1024 * 1024, empty=True)
        total += len(data)
        require(total <= 256 * 1024 * 1024 and len(result) < 128, "redraw bundle exceeds bounds")
        result[path.name] = lifecycle.digest(data)
    return result


def check_capture(campaign, plan, phase, nonce, candidate, status):
    name = "renderer-recovery-" + phase + "-capture.json"
    raw = campaign.evidence.read(name)
    require(raw.get("argv") == capture_argv(campaign, plan, phase, nonce, candidate)
            and type(raw.get("returnCode")) is int and raw["returnCode"] == 0 and raw.get("timedOut") is False,
            "redraw collector was changed, failed or timed out")
    root = campaign.evidence.directory / ("renderer-recovery-" + phase + "-redraw")
    require(raw.get("files") == capture_files(root), "redraw bundle was substituted or modified")
    if campaign.architecture == "x86_64":
        # ARM/FEX evidence cannot fill a translated PC cell, even with coherent pixels.
        pixels.BUILD_RECEIPT.validate_payload(direct_bytes(root / "gpu-probe-build-receipt.txt", 16384),
                                            source_directory=ROOT / "guest-probes", architecture="x86_64")
    result = pixels.verify(root, nonce)
    challenge = lifecycle.object_json(direct_bytes(root / "campaign-challenge.json").decode())
    frame = lifecycle.object_json(direct_bytes(root / "display-capture-frame.json").decode())
    capture = lifecycle.object_json(direct_bytes(root / "window-capture.json").decode())
    # The independent pixel/trace verifier binds every resource/fence/Metal identity. Join its
    # worker generation to this daemon observation; an old but coherent bundle cannot qualify.
    require(challenge.get("kind") == "dev.dory.gpu-campaign-challenge" and challenge.get("schemaVersion") == 1
            and challenge.get("nonce") == nonce and challenge.get("candidateID") == candidate
            and challenge.get("machineID") == campaign.machine
            and challenge.get("operationID") == status["runtimeGraphicsSelection"]["operationID"]
            and capture.get("machServiceName") == campaign.service
            and result.get("workerGeneration") == status["runtimeGraphicsSelection"]["rendererGeneration"],
            "fresh pixels belong to another candidate, operation, service or renderer generation")
    ready = plan["probeReadyFileTemplate"].replace("{nonce}", nonce)
    environment = ["env", "DORY_GPU_PROBE_NONCE=" + nonce, "DORY_GPU_PROBE_READY_FILE=" + ready]
    transports = (("guest-command-transport.json", "guestCommand"),
                  ("gpu-probe-transport.json", "probeResultCommand"),
                  ("gpu-probe-build-transport.json", "probeBuildReceiptCommand"))
    for filename, key in transports:
        body = lifecycle.object_json(direct_bytes(root / filename).decode())
        require(body.get("schema") == "dev.dory.machine.exec" and body.get("version") == 1
                and body.get("machine") == campaign.machine and body.get("argv") == environment + ["sh", "-ec", plan[key]]
                and type(body.get("exitCode")) is int and body["exitCode"] == 0 and body.get("timedOut") is False
                and body.get("stdoutTruncated") is False and body.get("stderrTruncated") is False
                and isinstance(body.get("stdout"), str), "redraw guest transport lost its exact source command/challenge")
        if key == "guestCommand":
            require(body["stdout"] == plan["expectedOutput"], "redraw launch command did not complete as requested")
        elif key == "probeResultCommand":
            probe = lifecycle.object_json(direct_bytes(root / "gpu-probe.json").decode())
            require(lifecycle.object_json(body["stdout"]) == probe and probe.get("presentedReadyFile") == ready,
                    "redraw probe result was not returned by the retained guest transport")
        else:
            require(body["stdout"].encode() == direct_bytes(root / "gpu-probe-build-receipt.txt"),
                    "redraw build source/binary receipt was not returned by this guest")
    require(raw.get("verification") == result, "recorded redraw verdict differs from independent replay")
    return frame, result


class RendererCampaign(lifecycle.Campaign):
    def __init__(self, app, service, machine, evidence, timeout, nonce, mode="controlled-restart", *,
                 architecture="arm64", network="shared-nat", graphics_backend="virgl-venus"):
        super().__init__(app, service, machine, evidence, timeout, nonce, record_prefix="renderer-recovery",
                         architecture=architecture, graphics_backend=graphics_backend)
        require(mode in MODES, "unknown renderer recovery mode")
        require(network in {"shared-nat", "disconnected"} and (architecture == "x86_64" or network == "shared-nat"),
                "unsupported renderer campaign network")
        self.network = network
        self.mode = mode
        require(architecture != "x86_64" or mode == "unexpected-worker-crash",
                "PC recovery requires the authenticated abrupt crash route; controlled restart is ARM-only")

    def witness(self, action, source, runtime):
        argv = ["python3", "-c", guest_script(action, self.nonce, source, runtime)]
        seconds = min(self.timeout, 30)
        body, name = self.ctl_call(["exec", self.machine, "--json", "--timeout-ms", str(seconds * 1000),
                                    "--output-limit-bytes", "4194304", "--", *argv], action, seconds)
        return lifecycle.check_exec(body, self.machine, argv), name

    def capture(self, plan, phase, nonce, candidate):
        path = self.evidence.directory / ("renderer-recovery-" + phase + "-redraw")
        path.mkdir(mode=0o700)
        argv = capture_argv(self, plan, phase, nonce, candidate)
        # Do not allow the caller's qualification environment to add input/restart authority.
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("DORY_DISPLAY_QUALIFICATION_", "DORY_GPU_PROBE_"))}
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env=environment, start_new_session=True)
        timed_out = False
        try:
            try:
                output, error = process.communicate(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    output, error = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    output, error = process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
        raw = {"argv": argv, "returnCode": process.returncode, "timedOut": timed_out,
               "stdout": output, "stderr": error}
        require(len(raw["stdout"].encode()) + len(raw["stderr"].encode()) <= 8 * 1024 * 1024,
                "redraw collector output exceeds bounds")
        if raw["returnCode"] == 0 and not raw["timedOut"]:
            raw.update(files=capture_files(path), verification=pixels.verify(path, nonce))
        name = self.evidence.write("renderer-recovery-" + phase + "-capture.json", raw)
        require(raw["returnCode"] == 0 and not raw["timedOut"], "source-bound redraw failed; retained " + name)
        return name

    @contextmanager
    def crash(self, status, frame):
        manifest, _ = authority(self.evidence, self.machine, self.service, self.app, self.architecture)
        crash_policy(self.evidence, self.architecture)
        request = crash_request(self, status, frame, manifest)
        self.evidence.write(CRASH_REQUEST, request)
        names, observation, complete = [CRASH_REQUEST], None, False
        try:
            deadline = time.monotonic() + min(self.timeout, 30)
            action = "arm"
            while True:
                previous = observation
                observation, name = self.ctl_call(crash_arguments(request, action), "crash-" + action, min(self.timeout, 10))
                names.append(name)
                check_crash_observation(observation, request, previous)
                if observation["state"] == "workerLost":
                    complete = True
                    break
                require(time.monotonic() < deadline, "worker acceptance plus actual renderer interruption did not arrive")
                action = "observe"
                require(len(names) < 160, "renderer fault observations exceeded the bounded replay budget")
                time.sleep(0.2)
            yield names
        finally:
            if not complete:
                # Best-effort cancellation revokes any queued, unsent fault. An accepted self-kill
                # cannot be recalled; cleanup never upgrades a partial/lost-ACK receipt to PASS.
                try:
                    self.ctl_call(crash_arguments(request, "cancel"), "crash-cancel", min(self.timeout, 10))
                except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError, ValueError):
                    pass

    @contextmanager
    def restart(self, status, frame):
        request = {"kind": "dev.dory.display-qualification-renderer-restart-request", "schemaVersion": 1,
                   "machineID": self.machine, "machServiceName": self.service,
                   "operationID": status["runtimeGraphicsSelection"]["operationID"], "nonce": self.nonce,
                   "beforeRendererGeneration": status["runtimeGraphicsSelection"]["rendererGeneration"],
                   "beforeDisplayResourceGeneration": frame["displayResourceGeneration"], "beforeFrameSequence": frame["frameSequence"]}
        self.evidence.write(REQUEST, request)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("DORY_DISPLAY_QUALIFICATION_")}
        environment.update(DORYD_MACH_SERVICE=self.service, DORY_DISPLAY_QUALIFICATION_MACHINE_ID=self.machine,
                           DORY_DISPLAY_QUALIFICATION_SCANOUT_ID="0",
                           DORY_DISPLAY_QUALIFICATION_WINDOW_RECEIPT=str(self.evidence.directory / WINDOW),
                           DORY_DISPLAY_QUALIFICATION_RENDERER_RESTART_REQUEST=str(self.evidence.directory / REQUEST),
                           DORY_DISPLAY_QUALIFICATION_RENDERER_RESTART_RECEIPT=str(self.evidence.directory / ACK))
        with (self.evidence.directory / "renderer-recovery-app.out").open("xb") as output, \
             (self.evidence.directory / "renderer-recovery-app.err").open("xb") as error:
            process = subprocess.Popen([str(self.app / "Contents/MacOS/Dory")], env=environment,
                                       stdout=output, stderr=error)
            try:
                deadline = time.monotonic() + min(self.timeout, 90)
                while not all((self.evidence.directory / name).exists() for name in (WINDOW, ACK)):
                    require(process.poll() is None, "restart app exited before acknowledging the runner request")
                    require(time.monotonic() < deadline, "restart command acknowledgement deadline expired")
                    time.sleep(0.2)
                window, ack = self.evidence.read(WINDOW), self.evidence.read(ACK)
                require(window.get("processID") == process.pid, "restart frame is from another app")
                check_ack(ack, request, lifecycle.digest(direct_bytes(self.evidence.directory / REQUEST)),
                          window, self, status)
                yield [REQUEST, ACK, WINDOW]
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=5)


def run_recovery(campaign, plan):
    manifest, candidate = authority(campaign.evidence, campaign.machine, campaign.service, campaign.app, campaign.architecture)
    if campaign.mode == "unexpected-worker-crash":
        crash_policy(campaign.evidence, campaign.architecture)
    hashes, source = source_hashes(campaign.architecture), direct_bytes(WITNESS, 65536)
    plan = check_plan(plan)
    campaign.evidence.write(PLAN, plan)
    names = [PLAN]
    before_boot, before_status, boot_names = campaign.wait_boot(network=campaign.network)
    names += boot_names
    boot = before_boot["bootID"]
    nonces = {phase: secrets.token_hex(16) for phase in PHASES}
    require(len(set([campaign.nonce, *nonces.values()])) == 3, "renderer challenge nonce collision")
    names.append(campaign.capture(plan, "before", nonces["before"], candidate))
    before_frame, _ = check_capture(campaign, plan, "before", nonces["before"], candidate, before_status)
    runtime = min(7200, 3 * campaign.timeout + 120)
    prepared = False

    def witness(action):
        body, name = campaign.witness(action, source, runtime)
        names.append(name)
        check_witness(body, action, campaign.nonce, boot, source, runtime)
        return body

    try:
        prepared = True  # Cleanup is attempted even if launch acknowledgement is lost.
        witness("prepare")
        deadline = time.monotonic() + min(campaign.timeout, 30)
        while True:
            first = witness("observe").get("observation")
            if first is not None:
                break
            require(time.monotonic() < deadline, "guest liveness witness did not start")
            time.sleep(0.2)
        transition = campaign.restart if campaign.mode == "controlled-restart" else campaign.crash
        with transition(before_status, before_frame) as restart_names:
            names += restart_names
            deadline = time.monotonic() + campaign.timeout
            while True:
                remaining = max(1, min(15, int(deadline - time.monotonic())))
                after_status, name = campaign.ctl_call(["status", campaign.machine], "status", remaining)
                names.append(name)
                ready = check_recovery_status(after_status, campaign, before_status)
                if not ready:
                    require(time.monotonic() < deadline, "renderer remained unavailable after fault acceptance")
                    time.sleep(1)
                    continue
                old, new = before_status["runtimeGraphicsSelection"], after_status["runtimeGraphicsSelection"]
                if new["rendererGeneration"] > old["rendererGeneration"]:
                    require(new["rendererWorkerReceiptSHA256"] != old["rendererWorkerReceiptSHA256"],
                            "replacement generation retained the old worker identity")
                    break
                require(time.monotonic() < deadline, "renderer replacement never completed after command acceptance")
                time.sleep(1)
        names.append(campaign.capture(plan, "after", nonces["after"], candidate))
        after_frame, _ = check_capture(campaign, plan, "after", nonces["after"], candidate, after_status)
        command_frame = campaign.evidence.read(ACK)["commandFrameSequence"] if campaign.mode == "controlled-restart" else before_frame["frameSequence"]
        require(after_frame["frameSequence"] > command_frame
                and after_frame["displayResourceGeneration"] != before_frame["displayResourceGeneration"],
                "replacement redraw retained the old frame or volatile display resource")
        last = witness("observe").get("observation")
        require(last is not None, "guest witness disappeared after redraw")
        same_witness(first, last)
        observed, name = campaign.guest("boot", network=campaign.network, timeout=min(campaign.timeout, 30))
        names.append(name)
        lifecycle.check_guest(observed, "boot", campaign.nonce, campaign.network, architecture=campaign.architecture)
        require(observed["bootID"] == boot, "renderer recovery rebooted the guest")
        final_status, name = campaign.ctl_call(["status", campaign.machine], "status", min(campaign.timeout, 15))
        names.append(name)
        check_runtime(final_status, campaign, before_status)
        require(same_renderer_owner(final_status["runtimeGraphicsSelection"], after_status["runtimeGraphicsSelection"]),
                "renderer changed again while verifying recovered pixels")
    finally:
        if prepared:
            witness("cleanup")
    require(hashes == source_hashes(campaign.architecture), "renderer campaign source changed during execution")
    record = {"kind": KIND, "schemaVersion": 1, "status": "PASS", "releaseEligible": False,
              "mode": campaign.mode, "unexpectedRendererDeathTested": campaign.mode == "unexpected-worker-crash",
              "guestArchitecture": campaign.architecture, "networkMode": campaign.network,
              "runtimeGraphicsBackend": campaign.graphics_backend,
              "survivingGPUContextVerified": False, "machine": campaign.machine, "machService": campaign.service,
              "nonce": campaign.nonce, "probeNonces": nonces, "timeoutSeconds": campaign.timeout,
              "witnessRuntimeMaxSeconds": runtime, "campaignManifestSHA256": manifest,
              "candidateInventorySHA256": candidate, "sourceSHA256": hashes,
              "bootID": boot, "operationID": old["operationID"],
              "resolvedPlanSHA256": before_status["runtimeIdentity"]["planSHA256"],
              "beforeRendererGeneration": old["rendererGeneration"], "afterRendererGeneration": new["rendererGeneration"],
              "guestProcessID": first["processID"], "guestProcessStartTicks": first["processStartTicks"],
              "volatileMemorySHA256": first["volatileMemorySHA256"], "payloadSHA256": payload_hash(campaign.nonce),
              "observations": names, "references": campaign.evidence.references(names)}
    campaign.evidence.write(PROOF, record)
    return verify_recovery(campaign.evidence, campaign.machine, campaign.service, campaign.app,
                           architecture=campaign.architecture, network=campaign.network, graphics_backend=campaign.graphics_backend)


def verify_recovery(evidence, machine, service, app, *, architecture="arm64", network="shared-nat", graphics_backend="virgl-venus"):
    record = evidence.read(PROOF)
    manifest, candidate = authority(evidence, machine, service, app, architecture)
    mode = record.get("mode")
    require(record.get("kind") == KIND and record.get("schemaVersion") == 1 and record.get("status") == "PASS"
            and record.get("releaseEligible") is False
            and mode in (("unexpected-worker-crash",) if architecture == "x86_64" else MODES)
            and record.get("unexpectedRendererDeathTested") is (mode == "unexpected-worker-crash")
            and record.get("survivingGPUContextVerified") is False
            and record.get("machine") == machine and record.get("machService") == service
            and record.get("campaignManifestSHA256") == manifest and record.get("candidateInventorySHA256") == candidate
            and record.get("sourceSHA256") == source_hashes(architecture)
            and record.get("guestArchitecture", "arm64") == architecture
            and record.get("networkMode", "shared-nat") == network
            and record.get("runtimeGraphicsBackend", "virgl-venus") == graphics_backend,
            "renderer recovery authority, ISA, network, backend or source changed")
    if mode == "unexpected-worker-crash":
        crash_policy(evidence, architecture)
    nonce, timeout = record.get("nonce"), record.get("timeoutSeconds")
    require(isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None
            and type(timeout) is int and 1 <= timeout <= 1800, "unbounded renderer campaign")
    runtime = min(7200, 3 * timeout + 120)
    require(record.get("witnessRuntimeMaxSeconds") == runtime, "witness deadline changed")
    campaign = RendererCampaign(app, service, machine, evidence, timeout, nonce, mode,
                                architecture=architecture, network=network, graphics_backend=graphics_backend)
    source, refs, names = direct_bytes(WITNESS, 65536), record.get("references"), record.get("observations")
    require(isinstance(names, list) and 12 <= len(names) <= 256 and len(set(names)) == len(names)
            and isinstance(refs, dict) and set(refs) == set(names), "missing ordered bounded renderer observations")
    for name in names:
        require(isinstance(name, str) and re.fullmatch(r"[a-z0-9.-]+", name) is not None
                and lifecycle.sha256_value(refs[name])
                and lifecycle.digest(direct_bytes(evidence.directory / name)) == refs[name], "renderer raw evidence digest mismatch")
    nonces = record.get("probeNonces")
    require(isinstance(nonces, dict) and set(nonces) == set(PHASES)
            and all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value) is not None for value in nonces.values())
            and len(set([nonce, *nonces.values()])) == 3, "redraw challenges are stale or shared")
    plan = check_plan(evidence.read(PLAN))
    state, status, before_status, first, last = "initial", None, None, None, None
    boot, before_frame, after_status, last_control, after_boot, final_status_seen = None, None, None, 0, False, False
    expected_fixed = {PLAN, "renderer-recovery-before-capture.json", "renderer-recovery-after-capture.json"}
    expected_fixed.update({REQUEST, ACK, WINDOW} if mode == "controlled-restart" else {CRASH_REQUEST})
    require(expected_fixed.issubset(set(names)), "renderer recovery lacks an intent, acknowledgement or redraw")
    require(not ({CRASH_REQUEST} if mode == "controlled-restart" else {REQUEST, ACK, WINDOW}).intersection(names),
            "controlled restart and abrupt crash evidence cannot be substituted or combined")
    crash_observation = None
    for name in names:
        raw = evidence.read(name)
        if name == PLAN:
            require(state == "initial" and name == names[0], "redraw plan ran out of order")
            continue
        if name == "renderer-recovery-before-capture.json":
            require(state == "booted" and status is not None, "baseline GPU capture ran before installed boot")
            before_status = status
            before_frame, _ = check_capture(campaign, plan, "before", nonces["before"], candidate, status)
            state = "baseline"
            continue
        if name == REQUEST:
            require(mode == "controlled-restart" and state == "witnessed", "restart intent ran before a live witness")
            check_request(raw, campaign, before_status, before_frame)
            state = "requested"
            continue
        if name == ACK:
            require(mode == "controlled-restart" and state == "requested", "restart acknowledgement ran out of order")
            check_ack(raw, evidence.read(REQUEST), refs[REQUEST], evidence.read(WINDOW), campaign, before_status)
            state = "acknowledged"
            continue
        if name == WINDOW:
            require(mode == "controlled-restart" and state == "acknowledged", "restart app frame ran out of order")
            continue
        if name == CRASH_REQUEST:
            require(mode == "unexpected-worker-crash" and state == "witnessed"
                    and raw == crash_request(campaign, before_status, before_frame, manifest),
                    "renderer crash intent is stale, foreign or precedes its live witness")
            state = "crash-requested"
            continue
        if name == "renderer-recovery-after-capture.json":
            require(state == "replaced", "redraw ran before a completed renderer replacement")
            frame, _ = check_capture(campaign, plan, "after", nonces["after"], candidate, status)
            command_frame = evidence.read(ACK)["commandFrameSequence"] if mode == "controlled-restart" else before_frame["frameSequence"]
            require(frame["frameSequence"] > command_frame
                    and frame["displayResourceGeneration"] != before_frame["displayResourceGeneration"],
                    "renderer redraw is a stale frame/resource")
            after_status, state = status, "redrawn"
            continue
        require(re.fullmatch(r"renderer-recovery-[0-9]{4}-[a-z-]+\.json", name) is not None,
                "foreign renderer control namespace")
        control_sequence = int(name.split("-")[2])
        require(control_sequence > last_control, "renderer control observations were reordered")
        last_control = control_sequence
        argv = raw.get("argv")
        require(isinstance(argv, list) and len(argv) >= 8
                and argv[:4] == [str(campaign.ctl), "--mach-service", service, "--timeout"]
                and isinstance(argv[4], str) and argv[4].isdigit() and 1 <= int(argv[4]) <= timeout and argv[5] == "machine"
                and type(raw.get("returnCode")) is int and raw["returnCode"] == 0 and raw.get("timedOut") is False,
                "renderer control failed or belongs to another endpoint")
        args, body = argv[6:], lifecycle.object_json(raw.get("stdout"))
        if args[:1] == ["qualification-fault"]:
            require(mode == "unexpected-worker-crash" and state in {"crash-requested", "crash-pending"},
                    "renderer fault was armed twice or observed out of order")
            action = "arm" if state == "crash-requested" else "observe"
            request = evidence.read(CRASH_REQUEST)
            require(args == crash_arguments(request, action), "renderer fault command differs from exact signed intent")
            check_crash_observation(body, request, crash_observation)
            crash_observation = body
            state = "acknowledged" if body["state"] == "workerLost" else "crash-pending"
            continue
        if args == ["status", machine]:
            require(state in {"initial", "acknowledged", "replaced", "live-after", "boot-after"}, "status ran out of order")
            if before_status is not None and state == "acknowledged":
                if not check_recovery_status(body, campaign, before_status):
                    status = body
                    continue
            else:
                check_runtime(body, campaign, before_status)
            status = body
            if before_status is not None and body["runtimeGraphicsSelection"]["rendererGeneration"] > before_status["runtimeGraphicsSelection"]["rendererGeneration"]:
                require(body["runtimeGraphicsSelection"]["rendererWorkerReceiptSHA256"]
                        != before_status["runtimeGraphicsSelection"]["rendererWorkerReceiptSHA256"], "old worker identity survived replacement")
                if state in {"acknowledged", "replaced"}:
                    state = "replaced"
                else:
                    require(same_renderer_owner(body["runtimeGraphicsSelection"], after_status["runtimeGraphicsSelection"]),
                            "worker changed again after recovered redraw")
                    if state == "boot-after":
                        final_status_seen = True
            continue
        require(len(args) == 11 and args[:4] == ["exec", machine, "--json", "--timeout-ms"]
                and isinstance(args[4], str) and args[4].isdigit() and 1 <= int(args[4]) <= timeout * 1000
                and args[5:8] == ["--output-limit-bytes", "4194304", "--"] and args[8:10] == ["python3", "-c"],
                "unexpected or unsafe renderer guest command")
        guest = lifecycle.check_exec(body, machine, args[8:])
        if args[-1] == lifecycle.guest_script("boot", nonce, network):
            require(state in {"initial", "live-after"} and status is not None, "boot observation ran out of order")
            lifecycle.check_guest(guest, "boot", nonce, network, architecture=architecture)
            if boot is None:
                boot, state = guest["bootID"], "booted"
            else:
                require(guest["bootID"] == boot, "guest rebooted during renderer recovery")
                after_boot, state = True, "boot-after"
            continue
        actions = [action for action in ("prepare", "observe", "cleanup")
                   if args[-1] == guest_script(action, nonce, source, runtime)]
        require(len(actions) == 1, "renderer guest witness command differs from reviewed source")
        action = actions[0]
        check_witness(guest, action, nonce, boot, source, runtime)
        if action == "prepare":
            require(state == "baseline", "liveness witness started out of order")
            state = "prepared"
        elif action == "observe":
            require(state in {"prepared", "redrawn"}, "witness observation ran out of order")
            value = guest.get("observation")
            if value is not None:
                if state == "prepared":
                    first, state = value, "witnessed"
                else:
                    same_witness(first, value)
                    last, state = value, "live-after"
        else:
            require(state == "boot-after" and after_boot and final_status_seen and after_status is not None
                    and same_renderer_owner(status["runtimeGraphicsSelection"], after_status["runtimeGraphicsSelection"]),
                    "witness cleanup ran before same-boot recovered runtime verification")
            state = "cleaned"
    require(state == "cleaned" and first is not None and last is not None and after_status is not None,
            "renderer recovery is incomplete")
    require(mode == "controlled-restart" or (crash_observation is not None and crash_observation["state"] == "workerLost"),
            "abrupt renderer recovery is missing actual worker acceptance and connection interruption")
    old, new = before_status["runtimeGraphicsSelection"], after_status["runtimeGraphicsSelection"]
    require(record.get("bootID") == boot and record.get("operationID") == old["operationID"]
            and record.get("resolvedPlanSHA256") == before_status["runtimeIdentity"]["planSHA256"]
            and record.get("beforeRendererGeneration") == old["rendererGeneration"]
            and record.get("afterRendererGeneration") == new["rendererGeneration"]
            and record.get("guestProcessID") == first["processID"] and record.get("guestProcessStartTicks") == first["processStartTicks"]
            and record.get("volatileMemorySHA256") == first["volatileMemorySHA256"]
            and record.get("payloadSHA256") == payload_hash(nonce), "renderer summary differs from raw observations")
    return {"status": "evidence-verified", "mode": mode, "machineID": machine,
            "guestArchitecture": architecture, "networkMode": network, "runtimeGraphicsBackend": graphics_backend,
            "operationID": old["operationID"], "beforeRendererGeneration": old["rendererGeneration"],
            "afterRendererGeneration": new["rendererGeneration"], "releaseEligible": False}


def main(architecture="arm64"):
    pc = architecture == "x86_64"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--run-directory", type=Path, required=True)
    parser.add_argument("--redraw-plan", type=Path)
    parser.add_argument("--graphics-trace", type=Path,
                        help="Bind only an explicit DORY-CAMPAIGN-GRAPHICS-TRACE plan placeholder")
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--mode", choices=("unexpected-worker-crash",) if pc else MODES,
                        default="unexpected-worker-crash" if pc else "controlled-restart")
    family = "PC" if pc else "ARM"
    parser.add_argument("--confirm", choices=[f"EXACT-DORY-{family}-RENDERER-CRASH"] if pc
                        else [f"EXACT-DORY-{family}-RENDERER-RESTART", f"EXACT-DORY-{family}-RENDERER-CRASH"])
    if pc:
        parser.add_argument("--network-mode", choices=["disconnected", "shared-nat"], default="disconnected")
        parser.add_argument("--gpu-profile", choices=["virgl", "venus"], default="venus")
    args = parser.parse_args()
    network = args.network_mode if pc else "shared-nat"
    backend = "virgl" if pc and args.gpu_profile == "virgl" else "virgl-venus"
    handlers = {}
    try:
        evidence = lifecycle.Evidence(args.run_directory)
        if args.verify_only:
            result = verify_recovery(evidence, args.machine, args.mach_service, args.app,
                                     architecture=architecture, network=network, graphics_backend=backend)
        else:
            expected_confirmation = f"EXACT-DORY-{family}-RENDERER-" + ("RESTART" if args.mode == "controlled-restart" else "CRASH")
            require(args.confirm == expected_confirmation and args.redraw_plan is not None,
                    "renderer recovery requires mode-specific confirmation and a redraw plan")
            require(1 <= args.timeout_seconds <= 1800, "renderer phase timeout exceeds the bounded witness lifetime")
            lifecycle.validate_target(args.app, args.mach_service, args.machine, args.run_directory,
                                      args.timeout_seconds, require_fresh_lifecycle=False, architecture=architecture)
            require(not any(path.name not in {"renderer-recovery.out", "renderer-recovery.err"}
                            for path in args.run_directory.glob("renderer-recovery*")), "refusing existing renderer recovery outputs")
            plan = lifecycle.object_json(direct_bytes(args.redraw_plan, 65536).decode())
            if plan.get("graphicsTrace") == "DORY-CAMPAIGN-GRAPHICS-TRACE":
                require(args.graphics_trace is not None, "redraw plan needs the campaign's exact graphics trace")
                plan["graphicsTrace"] = str(args.graphics_trace)
            elif args.graphics_trace is not None:
                require(plan.get("graphicsTrace") == str(args.graphics_trace), "redraw plan names another runtime trace")
            check_plan(plan)
            def interrupted(signum, _frame):
                raise lifecycle.LifecycleError("renderer recovery interrupted by signal " + str(signum))
            handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
            campaign = RendererCampaign(args.app, args.mach_service, args.machine, evidence,
                                        args.timeout_seconds, secrets.token_hex(16), args.mode,
                                        architecture=architecture, network=network, graphics_backend=backend)
            try:
                result = run_recovery(campaign, plan)
            except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError, ValueError) as error:
                evidence.write("renderer-recovery-failure.json", {"kind": KIND + "-failure", "schemaVersion": 1,
                    "status": "FAIL", "machine": args.machine, "machService": args.mach_service,
                    "detail": str(error), "releaseEligible": False})
                raise
        print(json.dumps(result, sort_keys=True))
        return 0
    except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError, IndexError) as error:
        print(("pc" if pc else "arm") + "-ubuntu-renderer-recovery: " + str(error), file=sys.stderr)
        return 2
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
