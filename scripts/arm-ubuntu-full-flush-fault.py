#!/usr/bin/env python3
"""Run/replay guest-visible full-flush failure and offline byte recovery via the signed daemon.

The only raw-block operation is fsync on a read-only descriptor for the verified guest root
disk. Normal file writes, stop/start and snapshot APIs own all durability/recovery work.
"""
import argparse
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location("dory_mapped_fault", Path(__file__).with_name("arm-ubuntu-mapped-page-fault.py"))
mapped = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapped)
lifecycle, require = mapped.lifecycle, mapped.require
FAULT = "block-full-flush-enospc"


# Linux block/fops.c blkdev_fsync calls blkdev_issue_flush and returns its error.
# https://github.com/torvalds/linux/blob/v6.8/block/fops.c
GUEST_SOURCE = r'''
import errno, hashlib, json, os, stat
from pathlib import Path
root = Path('/var/lib/dory/qualification') / nonce
payload = root / 'durability.bin'
expected = hashlib.sha256(nonce.encode('ascii')).digest() * 16384
boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
result = {'action': action, 'nonce': nonce, 'challenge': challenge, 'bootID': boot}
disk = os.open('/dev/vda', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    info = os.fstat(disk)
    if not stat.S_ISBLK(info.st_mode):
        raise RuntimeError('root flush target is not a block device')
    disk_id = str(os.major(info.st_rdev)) + ':' + str(os.minor(info.st_rdev))
    mounted = os.stat('/').st_dev
    root_id = str(os.major(mounted)) + ':' + str(os.minor(mounted))
    ancestry, visited = [], set()
    current = root_id
    while True:
        if current in visited or len(ancestry) >= 32:
            raise RuntimeError('root block ancestry is cyclic or unbounded')
        visited.add(current)
        node = (Path('/sys/dev/block') / current).resolve(strict=True)
        if not str(node).startswith('/sys/devices/') or (node / 'dev').read_text().strip() != current:
            raise RuntimeError('root block identity is inconsistent')
        ancestry.append(current)
        if (node / 'partition').exists():
            current = (node.parent / 'dev').read_text().strip()
            continue
        slaves = sorted((node / 'slaves').iterdir())
        if slaves:
            if len(slaves) != 1:
                raise RuntimeError('campaign root has multiple physical backing devices')
            current = (slaves[0] / 'dev').read_text().strip()
            continue
        if current != disk_id or node.name != 'vda':
            raise RuntimeError('flush descriptor is not the installed root disk')
        break
    cache = Path('/sys/class/block/vda/queue/write_cache').read_text().strip()
    if cache != 'write back':
        raise RuntimeError('guest root does not issue hardware cache flush requests')
    result['deviceIdentity'] = {'devicePath': '/dev/vda', 'rootMajorMinor': root_id,
                              'diskMajorMinor': disk_id, 'ancestry': ancestry, 'writeCache': cache}
    if action == 'prepare':
        root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        root.mkdir(mode=0o700)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        owned = os.fstat(directory)
        if owned.st_uid != os.geteuid() or stat.S_IMODE(owned.st_mode) != 0o700:
            raise RuntimeError('durability directory is not exclusively owned')
        if action == 'prepare':
            fd = os.open('durability.bin', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(fd, 'wb') as target:
                target.write(expected); target.flush(); os.fsync(target.fileno())
            os.fsync(directory)
            os.sync()
            os.fsync(disk)
            result.update(baselineFlushExitCode=0, fileFsync=True, directoryFsync=True)
        elif action == 'exercise':
            first_errno = 0
            try:
                os.fsync(disk)
            except OSError as error:
                first_errno = error.errno
            if first_errno != errno.EIO:
                raise RuntimeError('nominated root flush did not report EIO: ' + str(first_errno))
            # The same descriptor must successfully issue the next real cache flush.
            os.fsync(disk)
            fd = os.open('durability.bin', os.O_RDWR | os.O_NOFOLLOW, dir_fd=directory)
            with os.fdopen(fd, 'r+b') as target:
                info = os.fstat(target.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_size != len(expected) or info.st_mode & 0o077:
                    raise RuntimeError('durability payload is indirect or shared')
                if target.read() != expected:
                    raise RuntimeError('baseline bytes changed during injected failure')
                target.seek(0); target.write(expected); target.flush(); os.fsync(target.fileno())
            os.fsync(directory)
            os.fsync(disk)
            result.update(firstFlushErrno=first_errno, subsequentFlushExitCode=0,
                          fileFsync=True, directoryFsync=True)
        else:
            raise RuntimeError('unknown storage fault action')
        fd = os.open('durability.bin', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_size != len(expected) or info.st_mode & 0o077:
                raise RuntimeError('durability payload is indirect or shared')
            actual = source.read(len(expected) + 1)
        if actual != expected:
            raise RuntimeError('durable bytes do not match this challenge')
        result['payloadSHA256'] = hashlib.sha256(actual).hexdigest()
    finally:
        os.close(directory)
finally:
    os.close(disk)
print(json.dumps(result, sort_keys=True, separators=(',', ':')))
'''


def guest_script(action, nonce, challenge):
    require(action in {"prepare", "exercise"} and nonce == uuid.UUID(challenge).hex,
            "invalid storage witness action or nonce")
    return "action, nonce, challenge = " + repr((action, nonce, challenge)) + "\n" + GUEST_SOURCE


def expected_payload(nonce):
    return lifecycle.digest(hashlib.sha256(nonce.encode("ascii")).digest() * 16384)


def check_guest(body, action, nonce, challenge, boot):
    require(body.get("action") == action and body.get("nonce") == nonce and body.get("challenge") == challenge
            and mapped.normalized_uuid(body.get("bootID")) == boot
            and body.get("fileFsync") is True and body.get("directoryFsync") is True
            and body.get("payloadSHA256") == expected_payload(nonce), "storage witness lost its challenge, boot or bytes")
    device = body.get("deviceIdentity")
    require(isinstance(device, dict) and device.get("devicePath") == "/dev/vda"
            and device.get("writeCache") == "write back", "flush was not issued on the root cache-flush device")
    ancestry = device.get("ancestry")
    require(isinstance(ancestry, list) and 1 <= len(ancestry) <= 32 and len(set(ancestry)) == len(ancestry)
            and all(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*:[0-9]+", value) for value in ancestry)
            and ancestry[0] == device.get("rootMajorMinor") and ancestry[-1] == device.get("diskMajorMinor"),
            "root block ancestry does not bind the flush target")
    if action == "prepare":
        require(type(body.get("baselineFlushExitCode")) is int and body["baselineFlushExitCode"] == 0,
                "root flush did not succeed before arming")
    else:
        require(type(body.get("firstFlushErrno")) is int and body["firstFlushErrno"] == 5
                and type(body.get("subsequentFlushExitCode")) is int and body["subsequentFlushExitCode"] == 0,
                "guest did not observe EIO followed by a successful real flush")


def arguments(machine, action, challenge, operation, plan, manifest):
    args = ["qualification-fault", machine, "--action", action, "--operation-id", operation,
            "--plan-sha256", plan, "--manifest-sha256", manifest, "--challenge", challenge]
    return args + (["--kind", FAULT] if action == "arm" else [])


def check_host(body, state, machine, challenge, operation, plan, manifest):
    require(body.get("kind") == FAULT and body.get("state") == state and body.get("machineID") == machine
            and mapped.normalized_uuid(body.get("challenge")) == challenge
            and mapped.normalized_uuid(body.get("operationID")) == operation
            and body.get("resolvedPlanSHA256") == plan and body.get("campaignManifestSHA256") == manifest
            and all(body.get(key) is None for key in ("guestPhysicalAddress", "virtualCPUIndex", "instructionAddress",
                                                     "faultExitCount", "retryCount", "guestException", "memoryProtectionRestored")),
            "full-flush receipt belongs to another runtime or fault class")
    if state == "armed":
        require(all(body.get(key) is None for key in ("injectedErrno", "guestStatus", "queueIndex", "queueGeneration")),
                "full-flush fault was not freshly armed")
    else:
        require(type(body.get("injectedErrno")) is int and body["injectedErrno"] == 28
                and type(body.get("queueIndex")) is int and 0 <= body["queueIndex"] < 16
                and type(body.get("queueGeneration")) is int and 0 <= body["queueGeneration"] < 2**64
                and (body.get("guestStatus") is None if state == "consumed"
                     else type(body.get("guestStatus")) is int and body["guestStatus"] == 1),
                "backend error did not publish IOERR on the current guest queue")


def run_fault(campaign):
    evidence, names = campaign.evidence, []
    manifest = mapped.check_authority(evidence, campaign.machine, campaign.app, kind=FAULT)
    before, status, initial_names = campaign.wait_boot()
    names += initial_names
    boot = mapped.normalized_uuid(before["bootID"])
    operation = mapped.normalized_uuid(status["runtimeGraphicsSelection"]["operationID"])
    plan = status["runtimeIdentity"]["planSHA256"]
    challenge = str(uuid.UUID(hex=campaign.nonce))
    armed_attempt = False

    def guest(action):
        argv = ["python3", "-c", guest_script(action, campaign.nonce, challenge)]
        seconds = min(campaign.timeout, 30)
        raw, name = campaign.ctl_call(["exec", campaign.machine, "--json", "--timeout-ms", str(seconds * 1000),
                                       "--output-limit-bytes", "4194304", "--", *argv], action, seconds)
        names.append(name)
        body = lifecycle.check_exec(raw, campaign.machine, argv)
        check_guest(body, action, campaign.nonce, challenge, boot)
        return body

    def fault(action):
        raw, name = campaign.ctl_call(arguments(campaign.machine, action, challenge, operation, plan, manifest), action, 10)
        names.append(name)
        return raw

    try:
        prepared = guest("prepare")
        armed_attempt = True
        check_host(fault("arm"), "armed", campaign.machine, challenge, operation, plan, manifest)
        exercised = guest("exercise")
        require(exercised["deviceIdentity"] == prepared["deviceIdentity"], "guest root device changed after arming")
        deadline = time.monotonic() + min(campaign.timeout, 15)
        while True:
            observed = fault("observe")
            if observed.get("state") == "guestCompleted":
                break
            require(observed.get("state") in {"armed", "consumed"} and time.monotonic() < deadline,
                    "full-flush fault did not reach the guest queue")
            check_host(observed, observed["state"], campaign.machine, challenge, operation, plan, manifest)
            time.sleep(0.1)
        check_host(observed, "guestCompleted", campaign.machine, challenge, operation, plan, manifest)
        require(fault("cancel") == observed, "completed full-flush receipt changed during cancellation")
        armed_attempt = False
        after, current, after_names = campaign.wait_boot(expected_hash=expected_payload(campaign.nonce))
        names += after_names
        require(mapped.normalized_uuid(after["bootID"]) == boot
                and mapped.normalized_uuid(current["runtimeGraphicsSelection"]["operationID"]) == operation
                and current["runtimeIdentity"]["planSHA256"] == plan, "guest silently restarted during error recovery")
        names.append(campaign.display("flush-fault-live-recovered", current))
        # Explicit, ordinary cold-boot recovery follows the observed live recovery; it never
        # substitutes for proving that the original operation survived the injected error.
        offline, _, offline_names = campaign.cold_boot("flush-fault-offline", boot, "disconnected",
                                                       expected_payload(campaign.nonce))
        names += offline_names
        reopened, _, reopened_names = campaign.cold_boot("flush-fault-online", offline["bootID"], "shared-nat",
                                                         expected_payload(campaign.nonce))
        names += reopened_names
        evidence.write("storage-full-flush-fault.json", {
            "kind": "dev.dory.installed-desktop-full-flush-fault", "schemaVersion": 1, "status": "PASS",
            "machine": campaign.machine, "machService": campaign.service, "nonce": campaign.nonce,
            "challenge": challenge, "bootID": boot, "operationID": operation, "resolvedPlanSHA256": plan,
            "campaignManifestSHA256": manifest, "guestSourceSHA256": lifecycle.digest(GUEST_SOURCE.encode()),
            "expectedPayloadSHA256": expected_payload(campaign.nonce), "durableFlush": True,
            "recovered": True, "fullFlushFailureObserved": True, "offlineBootID": offline["bootID"],
            "recoveredBootID": reopened["bootID"], "releaseEligible": False,
            "references": evidence.references(names),
        })
        return verify_fault(evidence, campaign.machine, campaign.service, campaign.app)
    finally:
        if armed_attempt:
            fault("cancel")


def verify_fault(evidence, machine, service, app):
    record = evidence.read("storage-full-flush-fault.json")
    require(record.get("kind") == "dev.dory.installed-desktop-full-flush-fault" and record.get("schemaVersion") == 1
            and record.get("status") == "PASS" and record.get("machine") == machine and record.get("machService") == service
            and record.get("releaseEligible") is False and all(record.get(key) is True for key in
                                                              ("durableFlush", "recovered", "fullFlushFailureObserved")),
            "full-flush phase is incomplete or foreign")
    challenge, boot, operation, offline_boot, recovered_boot = (mapped.normalized_uuid(record.get(key)) for key in
        ("challenge", "bootID", "operationID", "offlineBootID", "recoveredBootID"))
    nonce, plan, manifest = record.get("nonce"), record.get("resolvedPlanSHA256"), record.get("campaignManifestSHA256")
    require(nonce == uuid.UUID(challenge).hex and lifecycle.sha256_value(plan)
            and manifest == mapped.check_authority(evidence, machine, app, kind=FAULT)
            and record.get("guestSourceSHA256") == lifecycle.digest(GUEST_SOURCE.encode())
            and record.get("expectedPayloadSHA256") == expected_payload(nonce)
            and len({boot, offline_boot, recovered_boot}) == 3, "full-flush source, authority, challenge or boot chain changed")
    references = record.get("references")
    require(isinstance(references, dict) and 20 <= len(references) <= 256, "missing bounded full-flush raw evidence")
    controls, windows = [], {}
    for name, sha256 in sorted(references.items()):
        raw = evidence.read(name)
        require(lifecycle.sha256_value(sha256) and lifecycle.digest((evidence.directory / name).read_bytes()) == sha256,
                "full-flush raw evidence digest mismatch")
        if raw.get("kind") == "dev.dory.display-qualification-window":
            require(name in {"lifecycle-flush-fault-live-recovered-window.json", "lifecycle-flush-fault-offline-window.json",
                             "lifecycle-flush-fault-online-window.json"}, "borrowed full-flush display receipt")
            windows[name] = raw
            continue
        require(re.fullmatch(r"flush-fault-[0-9]{4}-[a-z-]+\.json", name) is not None, "foreign full-flush control namespace")
        argv = raw.get("argv")
        require(isinstance(argv, list) and len(argv) >= 8 and all(isinstance(value, str) for value in argv)
                and argv[:4] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service, "--timeout"]
                and argv[4].isdigit() and 1 <= int(argv[4]) <= 7200 and argv[5] == "machine"
                and type(raw.get("returnCode")) is int and raw["returnCode"] == 0 and raw.get("timedOut") is False,
                "full-flush control transport failed or is foreign")
        controls.append((argv[6:], lifecycle.object_json(raw.get("stdout"))))
    phase, prepared, completed, live_boots, status, live_status = "before", None, None, 0, None, None
    cold_controls, cold_observations, cold_statuses = [], [], []
    for args, body in controls:
        if args == ["status", machine]:
            network = "disconnected" if phase in {"offline-started", "offline-booted"} else "shared-nat"
            lifecycle.check_status(body, machine, network=network)
            if phase in {"before", "cancelled"}:
                require(body["runtimeIdentity"]["planSHA256"] == plan
                        and mapped.normalized_uuid(body["runtimeGraphicsSelection"]["operationID"]) == operation,
                        "full-flush live recovery changed runtime")
            status = body
            if phase == "cancelled":
                live_status = body
            if phase in {"offline-started", "offline-booted", "online-started", "online-booted"}:
                cold_statuses.append((phase, body))
            continue
        if args[:2] == ["exec", machine]:
            require(len(args) == 11 and args[2:4] == ["--json", "--timeout-ms"] and args[4].isdigit()
                    and 1 <= int(args[4]) <= 7_200_000 and args[5:8] == ["--output-limit-bytes", "4194304", "--"],
                    "unexpected full-flush guest transport")
            argv = args[8:]
            observed = lifecycle.check_exec(body, machine, argv)
            if argv[2].startswith("action, nonce, network = "):
                action, script_nonce, network = ast.literal_eval(argv[2].splitlines()[0].split(" = ", 1)[1])
                require(action == "boot" and script_nonce == nonce and argv == ["python3", "-c", lifecycle.guest_script(action, nonce, network)]
                        and phase in {"before", "cancelled", "offline-started", "online-started"}, "unexpected full-flush boot command order")
                lifecycle.check_guest(observed, action, nonce, network,
                                      None if phase == "before" else expected_payload(nonce))
                if phase in {"before", "cancelled"}:
                    require(observed["bootID"] == boot and network == "shared-nat", "live full-flush recovery rebooted")
                    live_boots += 1
                else:
                    require(observed["bootID"] == (offline_boot if phase == "offline-started" else recovered_boot)
                            and network == ("disconnected" if phase == "offline-started" else "shared-nat"), "cold recovery boot/network changed")
                    cold_observations.append(observed)
                    phase = "offline-booted" if phase == "offline-started" else "online-booted"
                continue
            action = observed.get("action")
            require(action in {"prepare", "exercise"} and argv == ["python3", "-c", guest_script(action, nonce, challenge)],
                    "full-flush witness command changed")
            check_guest(observed, action, nonce, challenge, boot)
            if action == "prepare":
                require(phase == "before" and live_boots == 1 and status is not None, "full-flush prepare ran out of order")
                prepared, phase = observed, "prepared"
            else:
                require(phase == "armed" and observed["deviceIdentity"] == prepared["deviceIdentity"],
                        "full-flush exercise ran before arming or on another disk")
                phase = "exercised"
            continue
        if args[:2] == ["qualification-fault", machine]:
            action = args[3] if len(args) > 3 and args[2] == "--action" else None
            require(action in {"arm", "observe", "cancel"} and args == arguments(machine, action, challenge, operation, plan, manifest),
                    "full-flush intent changed")
            if action == "arm":
                require(phase == "prepared", "full-flush arming ran out of order")
                check_host(body, "armed", machine, challenge, operation, plan, manifest)
                phase = "armed"
            elif action == "observe":
                require(phase == "exercised" and body.get("state") in {"armed", "consumed", "guestCompleted"}, "unsuccessful full-flush observation")
                check_host(body, body["state"], machine, challenge, operation, plan, manifest)
                if body["state"] == "guestCompleted":
                    completed, phase = body, "completed"
            else:
                require(phase == "completed" and body == completed, "completed full-flush receipt changed during cancellation")
                phase = "cancelled"
            continue
        cold_controls.append(args[0])
        if args == ["stop", machine]:
            require(phase in {"cancelled", "offline-booted"} and (phase != "cancelled" or live_boots == 2)
                    and body.get("id") == machine and body.get("state") == "stopped", "full-flush stop ran out of order")
            phase = "offline-stopped" if phase == "cancelled" else "online-stopped"
        elif args == ["update", machine, "--network", "disconnected" if phase == "offline-stopped" else "shared-nat"]:
            require(phase in {"offline-stopped", "online-stopped"}, "full-flush network update ran out of order")
            lifecycle.check_status(body, machine, running=False,
                                   network="disconnected" if phase == "offline-stopped" else "shared-nat")
            phase = "offline-updated" if phase == "offline-stopped" else "online-updated"
        elif args == ["start", machine]:
            require(phase in {"offline-updated", "online-updated"}, "full-flush start ran out of order")
            phase = "offline-started" if phase == "offline-updated" else "online-started"
        else:
            raise lifecycle.LifecycleError("unexpected full-flush control command")
    require(phase == "online-booted" and live_boots == 2 and len(cold_observations) == 2
            and cold_controls == ["stop", "update", "start", "stop", "update", "start"] and len(windows) == 3
            and live_status is not None,
            "full-flush recovery lacks live, offline or online completion")
    # Bind each post-fault window to the status of its own boot operation, not the first renderer.
    lifecycle.check_window(windows["lifecycle-flush-fault-live-recovered-window.json"], live_status, machine, service)
    restored_plans = {plan}
    restored_operations = {operation}
    for label, prefix in (("offline", "offline"), ("online", "online")):
        matches = [body for phase_name, body in cold_statuses if phase_name.startswith(prefix)]
        require(bool(matches) and matches[-1]["runtimeIdentity"]["planSHA256"] != plan, "cold boot reused stale fault plan")
        restored_plans.add(matches[-1]["runtimeIdentity"]["planSHA256"])
        restored_operations.add(mapped.normalized_uuid(matches[-1]["runtimeGraphicsSelection"]["operationID"]))
        lifecycle.check_window(windows[f"lifecycle-flush-fault-{label}-window.json"], matches[-1], machine, service)
    require(len(restored_plans) == 3 and len(restored_operations) == 3, "cold recoveries reused an old runtime authority")
    return {"status": "evidence-verified", "machineID": machine, "operationID": operation, "challenge": challenge}


def qualify_storage(evidence, machine, service, app):
    lifecycle.verify_journey(evidence, machine, service, app)
    result = verify_fault(evidence, machine, service, app)
    baseline = evidence.read("storage-recovery.json")
    fault = evidence.read("storage-full-flush-fault.json")
    require(baseline["afterBootID"] == fault["bootID"], "storage fault was not run after this snapshot recovery")
    evidence.write("storage-recovery-qualification.json", {
        "kind": "dev.dory.installed-desktop-storage-qualification", "schemaVersion": 1, "status": "PASS",
        "machine": machine, "machService": service, "durableFlush": True, "recovered": True,
        "fullFlushFailureObserved": True, "releaseEligible": False,
        "references": evidence.references(["storage-recovery.json", "storage-full-flush-fault.json"]),
    })
    return result


def verify_storage(evidence, machine, service, app):
    record = evidence.read("storage-recovery-qualification.json")
    require(record.get("kind") == "dev.dory.installed-desktop-storage-qualification" and record.get("schemaVersion") == 1
            and record.get("status") == "PASS" and record.get("machine") == machine and record.get("machService") == service
            and record.get("releaseEligible") is False and all(record.get(key) is True for key in
                                                              ("durableFlush", "recovered", "fullFlushFailureObserved")), "storage qualification is incomplete or foreign")
    references = record.get("references")
    require(isinstance(references, dict) and set(references) == {"storage-recovery.json", "storage-full-flush-fault.json"}, "storage qualification lost its phases")
    for name, sha256 in references.items():
        evidence.read(name)
        require(sha256 == lifecycle.digest((evidence.directory / name).read_bytes()), "storage phase digest changed")
    lifecycle.verify_journey(evidence, machine, service, app)
    result = verify_fault(evidence, machine, service, app)
    require(evidence.read("storage-recovery.json")["afterBootID"] == evidence.read("storage-full-flush-fault.json")["bootID"],
            "snapshot recovery and injected failure belong to different boots")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--login-input-script", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--confirm", choices=["EXACT-DORY-ARM-FULL-FLUSH-FAULT"])
    args = parser.parse_args()
    previous_handlers = {}
    try:
        evidence = lifecycle.Evidence(args.run_directory)
        if args.verify_only:
            result = verify_storage(evidence, args.machine, args.mach_service, args.app)
        else:
            require(args.confirm == "EXACT-DORY-ARM-FULL-FLUSH-FAULT", "missing exact full-flush confirmation")
            lifecycle.validate_target(args.app, args.mach_service, args.machine, args.run_directory,
                                      args.timeout_seconds, require_fresh_lifecycle=False)
            if args.login_input_script is not None:
                lifecycle.validate_login_input(args.login_input_script, args.machine)
            require(not any(args.run_directory.glob("flush-fault-*"))
                    and not any(args.run_directory.glob("lifecycle-flush-fault-*")) and all(
                not (args.run_directory / name).exists() and not (args.run_directory / name).is_symlink()
                for name in ("storage-full-flush-fault.json", "storage-recovery-qualification.json", "full-flush-fault-failure.json")),
                "refusing to reuse full-flush evidence")
            lifecycle.verify_journey(evidence, args.machine, args.mach_service, args.app)
            def interrupted(signum, _frame):
                raise lifecycle.LifecycleError(f"full-flush campaign interrupted by signal {signum}")
            previous_handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
            campaign = lifecycle.Campaign(args.app, args.mach_service, args.machine, evidence, args.timeout_seconds,
                                          uuid.uuid4().hex, args.login_input_script, record_prefix="flush-fault")
            try:
                run_fault(campaign)
                result = qualify_storage(evidence, args.machine, args.mach_service, args.app)
            except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError) as error:
                evidence.write("full-flush-fault-failure.json", {
                    "kind": "dev.dory.installed-desktop-full-flush-fault-failure", "schemaVersion": 1,
                    "status": "FAIL", "machine": args.machine, "machService": args.mach_service,
                    "detail": str(error), "releaseEligible": False,
                })
                raise
        print(json.dumps(result, sort_keys=True))
        return 0
    except (lifecycle.LifecycleError, OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError, IndexError) as error:
        print(f"arm-ubuntu-full-flush-fault: {error}", file=sys.stderr)
        return 2
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
