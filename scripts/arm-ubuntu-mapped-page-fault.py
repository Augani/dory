#!/usr/bin/env python3
"""Run/replay an owned mapped-page fault through the exact signed campaign daemon.

No retry loop is synthesized: only the signed helper's real exception counters, joined to
the source-bound guest SIGBUS witness and a fresh current-operation display, can pass.
"""
import argparse
import base64
import importlib.util
import json
import re
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("dory_lifecycle", Path(__file__).with_name("arm-ubuntu-desktop-lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
require = lifecycle.require
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "guest-probes/mapped-page-retry.c"
FAULT = "mapped-page-repeated-permission"


def normalized_uuid(value):
    require(isinstance(value, str) and re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value) is not None,
        "invalid runtime UUID")
    parsed = uuid.UUID(value)
    require(parsed.int != 0, "zero runtime UUID")
    return str(parsed)


def pattern_hash(challenge):
    unit = ("dory-mapped-page-v1:" + normalized_uuid(challenge)).encode("ascii")
    return lifecycle.digest((unit + b"\n" * (64 - len(unit))) * 256)


GUEST_SOURCE = r'''
import base64, hashlib, json, os, platform, stat, subprocess
from pathlib import Path
root = Path('/var/lib/dory/qualification') / ('mapped-page-' + challenge)
receipts = Path('/run') / ('dory-mapped-page-' + challenge)
unit = 'dory-mapped-page-' + challenge
boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
result = {'action': action, 'challenge': challenge, 'bootID': boot, 'unit': unit}
def direct_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(fd)
        raise RuntimeError('guest scratch directory is not exclusively owned')
    return fd
def read_record(name):
    if not receipts.exists():
        return None
    directory = direct_directory(receipts)
    try:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > 4096:
                raise RuntimeError('guest receipt is indirect, shared or unbounded')
            return json.loads(source.read(4097))
    finally:
        os.close(directory)
if action == 'prepare':
    if platform.machine() != 'aarch64' or os.sysconf('SC_PAGESIZE') != 4096:
        raise RuntimeError('not the supported ARM64 guest ABI')
    source = base64.b64decode(encoded_source, validate=True)
    if hashlib.sha256(source).hexdigest() != source_sha256 or not 1 <= len(source) <= 32768:
        raise RuntimeError('guest source bytes do not match the retained source')
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.mkdir(mode=0o700)
    directory = direct_directory(root)
    try:
        fd = os.open('probe.c', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'wb') as target:
            target.write(source); target.flush(); os.fsync(target.fileno())
        os.fsync(directory)
    finally:
        os.close(directory)
    compiler = subprocess.check_output(['/usr/bin/cc', '--version'], text=True, timeout=5).splitlines()[0]
    subprocess.run(['/usr/bin/cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', str(root / 'probe.c'), '-o', str(root / 'probe')],
                   check=True, capture_output=True, timeout=45)
    binary = (root / 'probe').read_bytes()
    if binary[:6] != b'\x7fELF\x02\x01' or int.from_bytes(binary[18:20], 'little') != 183:
        raise RuntimeError('guest compiler did not produce an ARM64 ELF')
    pattern = subprocess.check_output([str(root / 'probe'), '--pattern', challenge], timeout=5)
    if len(pattern) != 16384:
        raise RuntimeError('compiled guest scratch pattern is incomplete')
    with (root / 'stdout.log').open('xb') as output, (root / 'stderr.log').open('xb') as error:
        # systemd owns bounded cleanup even if the host control connection disappears.
        subprocess.run(['systemd-run', '--quiet', '--no-block', '--unit=' + unit,
                        '--property=RuntimeMaxSec=75s', '--property=Restart=no', '--property=UMask=0077',
                        '--property=StandardOutput=file:' + str(root / 'stdout.log'),
                        '--property=StandardError=file:' + str(root / 'stderr.log'),
                        str(root / 'probe'), '--challenge', challenge], check=True, timeout=5)
    result.update(sourceSHA256=source_sha256, binarySHA256=hashlib.sha256(binary).hexdigest(),
                  patternSHA256=hashlib.sha256(pattern).hexdigest(), compiler=compiler)
elif action in ('ready', 'result'):
    result[action] = read_record(action + '.json')
elif action == 'trigger':
    directory = direct_directory(receipts)
    try:
        fd = os.open('trigger', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'wb') as target:
            target.write(challenge.encode('ascii')); target.flush(); os.fsync(target.fileno())
        os.fsync(directory)
    finally:
        os.close(directory)
    result['triggered'] = True
elif action == 'cleanup':
    info = subprocess.check_output(['systemctl', 'show', unit, '--property=LoadState'], text=True, timeout=5)
    if info.strip() != 'LoadState=not-found':
        subprocess.run(['systemctl', 'stop', unit], check=True, capture_output=True, timeout=10)
    info = subprocess.check_output(['systemctl', 'show', unit, '--property=MainPID,ActiveState'], text=True, timeout=5)
    properties = dict(row.split('=', 1) for row in info.splitlines())
    if properties.get('MainPID') != '0' or properties.get('ActiveState') not in ('inactive', 'failed'):
        raise RuntimeError('guest scratch unit did not stop')
    result['stopped'] = True
else:
    raise RuntimeError('unknown guest fault action')
print(json.dumps(result, sort_keys=True, separators=(',', ':')))
'''


def guest_script(action, challenge, source):
    require(action in {"prepare", "ready", "trigger", "result", "cleanup"}, "unknown guest fault action")
    encoded = base64.b64encode(source).decode("ascii") if action == "prepare" else ""
    return "action, challenge, encoded_source, source_sha256 = " + repr(
        (action, normalized_uuid(challenge), encoded, lifecycle.digest(source))) + "\n" + GUEST_SOURCE


def check_guest(body, action, challenge, boot):
    require(body.get("action") == action and body.get("challenge") == challenge
            and normalized_uuid(body.get("bootID")) == boot
            and body.get("unit") == "dory-mapped-page-" + challenge,
            "guest scratch observation belongs to another challenge or boot")


def check_ready(ready, challenge, boot):
    require(isinstance(ready, dict) and ready.get("kind") == "dev.dory.mapped-page-retry-guest-ready@1"
            and ready.get("challenge") == challenge and normalized_uuid(ready.get("bootID")) == boot
            and type(ready.get("processID")) is int and ready["processID"] > 0
            and type(ready.get("virtualCPU")) is int and ready["virtualCPU"] == 0
            and type(ready.get("guestPhysicalAddress")) is int and 0 < ready["guestPhysicalAddress"] < 2**64
            and ready["guestPhysicalAddress"] % 16384 == 0
            and type(ready.get("virtualAddress")) is int and 0 < ready["virtualAddress"] < 2**64
            and ready["virtualAddress"] % (2 * 1024 * 1024) == 0
            and ready.get("scratchBytes") == 2 * 1024 * 1024 and ready.get("hostPageBytes") == 16384,
            "guest did not prove an owned aligned scratch page")


def check_result(result, ready):
    require(isinstance(result, dict) and result.get("kind") == "dev.dory.mapped-page-retry-guest-result@1"
            and result.get("status") == "PASS" and result.get("guestFaultObserved") is True
            and result.get("unchangedPageReadable") is True,
            "guest did not observe the fault and unchanged readable page")
    require(all(result.get(key) == ready[key] for key in
                ("challenge", "bootID", "processID", "virtualCPU", "guestPhysicalAddress", "virtualAddress"))
            and all(type(result.get(key)) is int for key in
                    ("processID", "virtualCPU", "guestPhysicalAddress", "virtualAddress", "signalAddress"))
            and type(result.get("signal")) is int and result["signal"] == 7
            # Linux arm64's synchronous-external-abort fault_info entry uses BUS_OBJERR.
            # https://github.com/torvalds/linux/blob/v6.8/arch/arm64/mm/fault.c
            and type(result.get("signalCode")) is int and result["signalCode"] == 3
            and result.get("signalAddress") == ready["virtualAddress"],
            "SIGBUS/BUS_OBJERR does not bind the nominated owner and address")


def fault_arguments(machine, action, challenge, operation, plan, manifest, address=None):
    values = ["qualification-fault", machine, "--action", action, "--operation-id", operation,
              "--plan-sha256", plan, "--manifest-sha256", manifest, "--challenge", challenge]
    if action == "arm":
        values += ["--kind", FAULT, "--guest-physical-address", str(address)]
    return values


def check_host(body, state, campaign, challenge, operation, plan, manifest, ready):
    require(body.get("kind") == FAULT and body.get("state") == state
            and normalized_uuid(body.get("challenge")) == challenge
            and normalized_uuid(body.get("operationID")) == operation
            and body.get("machineID") == campaign.machine
            and body.get("resolvedPlanSHA256") == plan and body.get("campaignManifestSHA256") == manifest
            and type(body.get("guestPhysicalAddress")) is int
            and body["guestPhysicalAddress"] == ready["guestPhysicalAddress"]
            and all(body.get(key) is None for key in ("injectedErrno", "guestStatus", "queueIndex", "queueGeneration")),
            "helper fault receipt is not bound to this exact operation and scratch page")
    if state == "armed":
        require(body.get("memoryProtectionRestored") is False and type(body.get("faultExitCount")) is int
                and body["faultExitCount"] == 0 and type(body.get("retryCount")) is int and body["retryCount"] == 0
                and all(body.get(key) is None for key in ("virtualCPUIndex", "instructionAddress", "guestException")),
                "fault was not freshly armed")
    elif state == "faulting":
        require(body.get("memoryProtectionRestored") is False
                and type(body.get("faultExitCount")) is int and 1 <= body["faultExitCount"] <= 17
                and type(body.get("retryCount")) is int and body["retryCount"] == min(body["faultExitCount"], 16)
                and type(body.get("virtualCPUIndex")) is int and body["virtualCPUIndex"] == 0
                and type(body.get("instructionAddress")) is int and 0 < body["instructionAddress"] < 2**64
                and body.get("guestException") is None, "intermediate fault episode is malformed")
    else:
        require(body.get("memoryProtectionRestored") is True
                and type(body.get("faultExitCount")) is int and body["faultExitCount"] == 17
                and type(body.get("retryCount")) is int and body["retryCount"] == 16
                and type(body.get("virtualCPUIndex")) is int and body["virtualCPUIndex"] == 0
                and type(body.get("instructionAddress")) is int and 0 < body["instructionAddress"] < 2**64
                and body.get("guestException") == "synchronous-external-data-abort",
                "real retry budget, owner exception injection or permission restoration did not complete")


def read_source():
    require(SOURCE.is_file() and not SOURCE.is_symlink() and 1 <= SOURCE.stat().st_size <= 32768,
            "guest witness source is missing or unbounded")
    return SOURCE.read_bytes()


def check_authority(evidence, machine, app, kind=FAULT):
    authority = evidence.read("campaign-authority.json")
    manifest = lifecycle.digest((evidence.directory / "campaign-authority.json").read_bytes())
    require(authority.get("kind") == "dev.dory.virtual-machine-candidate-campaign-authorization"
            and authority.get("schemaVersion") == 2 and authority.get("applicationRoot") == str(app)
            and isinstance(authority.get("machineIDPrefix"), str)
            and bool(authority["machineIDPrefix"]) and machine.startswith(authority["machineIDPrefix"]),
            "fault authority does not bind this campaign")
    require(isinstance(authority.get("cells"), list), "fault authority has no cell list")
    require(any(isinstance(cell, dict) and isinstance(cell.get("faultPolicy"), dict)
                and isinstance(cell["faultPolicy"].get("permittedFaults"), list)
                and kind in cell["faultPolicy"]["permittedFaults"]
                for cell in authority["cells"]), "signed campaign has no requested fault policy")
    # This is an early scope check, not a signature-verification shortcut. The daemon rechecks
    # its verified inherited authority and exact resolved plan before every arming request.
    return manifest


def run_fault(campaign):
    evidence, names, source = campaign.evidence, [], read_source()
    manifest = check_authority(evidence, campaign.machine, campaign.app)
    before, status, initial_names = campaign.wait_boot()
    names += initial_names
    boot = normalized_uuid(before["bootID"])
    operation = normalized_uuid(status["runtimeGraphicsSelection"]["operationID"])
    plan = status["runtimeIdentity"]["planSHA256"]
    challenge = str(uuid.uuid4())
    armed_attempt, prepared_attempt = False, False

    def guest(action):
        argv = ["python3", "-c", guest_script(action, challenge, source)]
        seconds = min(campaign.timeout, 60 if action == "prepare" else 15)
        raw, name = campaign.ctl_call(["exec", campaign.machine, "--json", "--timeout-ms", str(seconds * 1000),
                                       "--output-limit-bytes", "4194304", "--", *argv], action, seconds)
        names.append(name)
        result = lifecycle.check_exec(raw, campaign.machine, argv)
        check_guest(result, action, challenge, boot)
        return result

    def fault(action, ready):
        raw, name = campaign.ctl_call(fault_arguments(campaign.machine, action, challenge, operation, plan,
                                                     manifest, ready["guestPhysicalAddress"]), action, 10)
        names.append(name)
        return raw

    def wait_guest(action):
        deadline = time.monotonic() + min(campaign.timeout, 30)
        while True:
            result = guest(action)
            if result.get(action) is not None:
                return result[action]
            require(time.monotonic() < deadline, "guest scratch witness did not publish " + action)
            time.sleep(0.1)

    try:
        prepared_attempt = True
        prepared = guest("prepare")
        require(prepared.get("sourceSHA256") == lifecycle.digest(source)
                and lifecycle.sha256_value(prepared.get("binarySHA256"))
                and prepared.get("patternSHA256") == pattern_hash(challenge)
                and isinstance(prepared.get("compiler"), str) and bool(prepared["compiler"]),
                "compiled guest witness is not bound to the current source and pattern")
        ready = wait_guest("ready")
        check_ready(ready, challenge, boot)
        armed_attempt = True
        check_host(fault("arm", ready), "armed", campaign, challenge, operation, plan, manifest, ready)
        require(guest("trigger").get("triggered") is True, "guest scratch trigger was not published")
        deadline = time.monotonic() + min(campaign.timeout, 15)
        while True:
            observed = fault("observe", ready)
            if observed.get("state") == "retryEscalated":
                break
            require(observed.get("state") in {"armed", "faulting"} and time.monotonic() < deadline,
                    "mapped-page fault terminated without a completed retry escalation")
            check_host(observed, observed["state"], campaign, challenge, operation, plan, manifest, ready)
            time.sleep(0.1)
        check_host(observed, "retryEscalated", campaign, challenge, operation, plan, manifest, ready)
        check_result(wait_guest("result"), ready)
        # Cancellation is idempotent after completion. Its authenticated reply also proves that
        # later command traffic did not silently start another operation or reset the counters.
        check_host(fault("cancel", ready), "retryEscalated", campaign, challenge, operation, plan, manifest, ready)
        armed_attempt = False
        require(guest("cleanup").get("stopped") is True, "guest scratch unit was not stopped")
        prepared_attempt = False
        after, current, after_names = campaign.wait_boot()
        names += after_names
        require(normalized_uuid(after["bootID"]) == boot
                and normalized_uuid(current["runtimeGraphicsSelection"]["operationID"]) == operation
                and current["runtimeIdentity"]["planSHA256"] == plan,
                "fault recovery rebooted the guest or replaced its runtime")
        names.append(campaign.display("mapped-fault-recovered", current))
        evidence.write("fault-retry.json", {
            "kind": "dev.dory.installed-desktop-mapped-page-fault", "schemaVersion": 1, "status": "PASS",
            "machine": campaign.machine, "machService": campaign.service, "challenge": challenge,
            "bootID": boot, "operationID": operation, "resolvedPlanSHA256": plan,
            "campaignManifestSHA256": manifest, "sourceSHA256": lifecycle.digest(source),
            "guestBinarySHA256": prepared["binarySHA256"], "guestFaultInjected": True,
            "mappedPageRetryEscalated": True, "releaseEligible": False,
            "references": evidence.references(names),
        })
        return verify_fault(evidence, campaign.machine, campaign.service, campaign.app)
    finally:
        try:
            if armed_attempt:
                # This can run after an RPC timeout: cancel only this exact attempted challenge.
                fault("cancel", ready)
        finally:
            if prepared_attempt:
                guest("cleanup")


def verify_fault(evidence, machine, service, app):
    """Reconstruct exact commands and join raw helper, SIGBUS, boot and display receipts."""
    record = evidence.read("fault-retry.json")
    require(record.get("kind") == "dev.dory.installed-desktop-mapped-page-fault" and record.get("schemaVersion") == 1
            and record.get("status") == "PASS" and record.get("machine") == machine
            and record.get("machService") == service and record.get("releaseEligible") is False
            and record.get("guestFaultInjected") is True and record.get("mappedPageRetryEscalated") is True,
            "mapped-page phase is incomplete or foreign")
    challenge, boot, operation = (normalized_uuid(record.get(key)) for key in ("challenge", "bootID", "operationID"))
    plan, manifest, source = record.get("resolvedPlanSHA256"), record.get("campaignManifestSHA256"), read_source()
    require(lifecycle.sha256_value(plan) and manifest == check_authority(evidence, machine, app)
        and record.get("sourceSHA256") == lifecycle.digest(source), "fault source or signed authority bytes changed")
    references = record.get("references")
    require(isinstance(references, dict) and 10 <= len(references) <= 256, "missing bounded raw fault evidence")
    controls, windows = [], []
    for name, sha256 in sorted(references.items()):
        raw = evidence.read(name)
        require(lifecycle.sha256_value(sha256) and lifecycle.digest((evidence.directory / name).read_bytes()) == sha256,
                "raw fault evidence digest mismatch")
        if raw.get("kind") == "dev.dory.display-qualification-window":
            require(name == "lifecycle-mapped-fault-recovered-window.json", "fault window was borrowed from another phase")
            windows.append(raw)
            continue
        require(re.fullmatch(r"mapped-fault-[0-9]{4}-[a-z-]+\.json", name) is not None,
                "foreign control-record namespace")
        argv = raw.get("argv")
        require(isinstance(argv, list) and len(argv) >= 8 and all(isinstance(value, str) for value in argv)
                and argv[:4] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service, "--timeout"]
                and argv[4].isdigit() and 1 <= int(argv[4]) <= 7200 and argv[5] == "machine"
                and type(raw.get("returnCode")) is int and raw["returnCode"] == 0 and raw.get("timedOut") is False,
                "fault control transport failed or belongs to another endpoint")
        controls.append((argv[6:], lifecycle.object_json(raw.get("stdout"))))
    return replay_controls(record, controls, windows, evidence, machine, service, app, source,
                           challenge, boot, operation, plan, manifest)


def replay_controls(record, controls, windows, evidence, machine, service, app, source,
                    challenge, boot, operation, plan, manifest):
    phase, ready, completed, status, boot_count = "before", None, None, None, 0
    campaign = type("CampaignIdentity", (), {"machine": machine})()
    for args, body in controls:
        if args == ["status", machine]:
            lifecycle.check_status(body, machine, network="shared-nat")
            require(body["runtimeIdentity"]["planSHA256"] == plan
                    and normalized_uuid(body["runtimeGraphicsSelection"]["operationID"]) == operation,
                    "fault phase changed its runtime")
            status = body
            continue
        if args[:2] == ["exec", machine]:
            require(len(args) == 11 and args[2:4] == ["--json", "--timeout-ms"] and args[4].isdigit()
                    and 1 <= int(args[4]) <= 7_200_000
                    and args[5:8] == ["--output-limit-bytes", "4194304", "--"], "unexpected guest transport options")
            argv = args[8:]
            body = lifecycle.check_exec(body, machine, argv)
            if argv[:2] == ["python3", "-c"] and len(argv) == 3 and argv[2].startswith("action, nonce, network = "):
                import ast
                action, nonce, network = ast.literal_eval(argv[2].splitlines()[0].split(" = ", 1)[1])
                require(action == "boot" and network == "shared-nat" and argv[2] == lifecycle.guest_script(action, nonce, network)
                        and phase in {"before", "cleaned"}, "fault boot command changed or ran out of order")
                lifecycle.check_guest(body, action, nonce, network)
                require(normalized_uuid(body.get("bootID")) == boot, "fault witness rebooted its guest")
                boot_count += 1
                continue
            require(len(argv) == 3 and argv[:2] == ["python3", "-c"], "unexpected guest command")
            actions = [action for action in ("prepare", "ready", "trigger", "result", "cleanup")
                       if argv[2] == guest_script(action, challenge, source)]
            require(len(actions) == 1, "guest scratch command differs from current source")
            action = actions[0]
            check_guest(body, action, challenge, boot)
            if action == "prepare":
                require(phase == "before" and boot_count == 1 and status is not None, "scratch preparation ran out of order")
                require(body.get("sourceSHA256") == lifecycle.digest(source)
                        and body.get("binarySHA256") == record.get("guestBinarySHA256")
                        and lifecycle.sha256_value(body.get("binarySHA256"))
                        and body.get("patternSHA256") == pattern_hash(challenge)
                        and isinstance(body.get("compiler"), str) and bool(body["compiler"]), "guest build receipt changed")
                phase = "prepared"
            elif action == "ready":
                require(phase == "prepared", "scratch readiness ran out of order")
                if body.get("ready") is not None:
                    ready = body["ready"]
                    check_ready(ready, challenge, boot)
                    phase = "ready"
            elif action == "trigger":
                require(phase == "armed" and body.get("triggered") is True, "scratch was touched before arming")
                phase = "triggered"
            elif action == "result":
                require(phase == "escalated", "guest fault result ran before helper exception injection")
                if body.get("result") is not None:
                    check_result(body["result"], ready)
                    phase = "witnessed"
            elif action == "cleanup":
                require(phase == "cancelled" and body.get("stopped") is True, "guest scratch owner was not cleaned up")
                phase = "cleaned"
            continue
        require(ready is not None and args[:2] == ["qualification-fault", machine], "unexpected fault command")
        action = args[3] if len(args) > 3 and args[2] == "--action" else None
        require(action in {"arm", "observe", "cancel"}
                and args == fault_arguments(machine, action, challenge, operation, plan, manifest,
                                             ready["guestPhysicalAddress"]), "fault intent fields changed")
        if action == "arm":
            require(phase == "ready", "fault arming ran out of order")
            check_host(body, "armed", campaign, challenge, operation, plan, manifest, ready)
            phase = "armed"
        elif action == "observe":
            require(phase == "triggered", "fault observation ran out of order")
            if body.get("state") == "retryEscalated":
                check_host(body, "retryEscalated", campaign, challenge, operation, plan, manifest, ready)
                completed, phase = body, "escalated"
            else:
                require(body.get("state") in {"armed", "faulting"}, "fault terminated unsuccessfully")
                check_host(body, body["state"], campaign, challenge, operation, plan, manifest, ready)
        else:
            require(phase == "witnessed" and body == completed, "completed fault changed during cancellation")
            phase = "cancelled"
    require(phase == "cleaned" and boot_count == 2 and status is not None and len(windows) == 1,
            "fault phase lacks cleanup, same-boot recovery or a fresh window")
    lifecycle.check_window(windows[0], status, machine, service)
    return {"status": "evidence-verified", "machineID": machine, "operationID": operation, "challenge": challenge}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--confirm", choices=["EXACT-DORY-ARM-MAPPED-PAGE-FAULT"])
    args = parser.parse_args()
    previous_handlers = {}
    try:
        evidence = lifecycle.Evidence(args.run_directory)
        if args.verify_only:
            result = verify_fault(evidence, args.machine, args.mach_service, args.app)
        else:
            require(args.confirm == "EXACT-DORY-ARM-MAPPED-PAGE-FAULT", "missing exact fault-campaign confirmation")
            lifecycle.validate_target(args.app, args.mach_service, args.machine, args.run_directory,
                                      args.timeout_seconds, require_fresh_lifecycle=False)
            require(not any(args.run_directory.glob("mapped-fault-*"))
                    and not any(args.run_directory.glob("lifecycle-mapped-fault-*"))
                    and all(not (args.run_directory / name).exists() and not (args.run_directory / name).is_symlink()
                            for name in ("fault-retry.json", "mapped-page-fault-failure.json")), "refusing to reuse fault output")
            def interrupted(signum, _frame):
                raise lifecycle.LifecycleError(f"fault campaign interrupted by signal {signum}")
            previous_handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
            campaign = lifecycle.Campaign(args.app, args.mach_service, args.machine, evidence, args.timeout_seconds,
                                          uuid.uuid4().hex, record_prefix="mapped-fault")
            try:
                result = run_fault(campaign)
            except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError) as error:
                evidence.write("mapped-page-fault-failure.json", {
                    "kind": "dev.dory.installed-desktop-mapped-page-fault-failure", "schemaVersion": 1,
                    "status": "FAIL", "machine": args.machine, "machService": args.mach_service,
                    "detail": str(error), "releaseEligible": False,
                })
                raise
        print(json.dumps(result, sort_keys=True))
        return 0
    except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError, ValueError, TypeError, IndexError) as error:
        print(f"arm-ubuntu-mapped-page-fault: {error}", file=sys.stderr)
        return 2
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
