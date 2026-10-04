#!/usr/bin/env python3
"""Run the installed-disk journey using only the campaign's bundled dorydctl.

This is not a second VM control plane. Installation/input and GPU qualification remain with
the scenario driver. These phases exercise the normal stop/update/start, guest-exec and disk
snapshot APIs. No host fault is fabricated: successful byte recovery is still INCOMPLETE for
the separate full-flush-failure requirement.
"""
import argparse
from contextlib import contextmanager
import hashlib
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


class LifecycleError(Exception):
    pass


class TransportUnavailable(LifecycleError):
    pass


class GuestNotReady(LifecycleError):
    pass


def require(condition, message):
    if not condition:
        raise LifecycleError(message)


def dictionary(value, label):
    require(isinstance(value, dict), f"missing or malformed {label}")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def object_json(text):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, f"duplicate JSON field: {key}")
            result[key] = value
        return result
    try:
        result = json.loads(text, object_pairs_hook=pairs)
    except (ValueError, TypeError) as error:
        raise LifecycleError(f"invalid JSON: {error}") from error
    require(isinstance(result, dict), "expected one JSON object")
    return result


def canonical_uuid(value):
    return isinstance(value, str) and re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value
    ) is not None


def sha256_value(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


ROOT = Path(__file__).resolve().parents[1]
JOURNEY_PHASES = ("installer-reboot", "cold-offline-reopen", "cold-reopen", "guest-reboot",
                  "package-update", "storage-recovery")


def direct_bytes(path, limit=8 * 1024 * 1024):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= limit,
                "indirect, empty or unbounded lifecycle source/evidence")
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
        require(len(data) == before.st_size and len(data) <= limit
                and (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                "lifecycle source/evidence changed during read")
        return data


def source_hashes(architecture):
    require(architecture in {"arm64", "x86_64"}, "unsupported lifecycle ISA")
    paths = [Path(__file__)]
    if architecture == "x86_64":
        paths.append(ROOT / "scripts/pc-ubuntu-desktop-lifecycle.py")
    return {str(path.relative_to(ROOT)): digest(direct_bytes(path)) for path in paths}


def profile_binding(evidence, machine, service, app, architecture, graphics_backend):
    require(architecture in {"arm64", "x86_64"}
            and graphics_backend in ({"virgl-venus"} if architecture == "arm64" else {"virgl", "virgl-venus"}),
            "unsupported lifecycle ISA/graphics profile")
    result = {"guestArchitecture": architecture, "runtimeGraphicsBackend": graphics_backend,
              "guestProbeSHA256": digest(GUEST_SOURCE.encode())}
    if architecture == "x86_64":
        prefix = "wave0-pc-gpu-"
        require(re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9-]+", machine) is not None
                and service == "dev.dory.wave0.pcgpu." + machine.removeprefix(prefix),
                "PC lifecycle requires the exact isolated PC campaign")
        authority = evidence.read("campaign-authority.json")
        require(authority.get("kind") == "dev.dory.virtual-machine-candidate-campaign-authorization"
                and authority.get("schemaVersion") == 2 and authority.get("purpose") == "candidate-qualification-campaign"
                and authority.get("applicationRoot") == str(app) and authority.get("machineIDPrefix") == prefix
                and sha256_value(authority.get("candidateInventorySHA256"))
                and isinstance(authority.get("cells"), list)
                and any(isinstance(cell, dict) and isinstance(cell.get("capability"), dict)
                        and cell["capability"].get("guest") == {"architecture": "x86_64", "family": "linux"}
                        and cell["capability"].get("backend") == "dory-hypervisor"
                        and cell["capability"].get("graphics") == "hardware-accelerated-3d"
                        for cell in authority["cells"]),
                "PC lifecycle authority does not bind this candidate and hardware desktop cell")
        result.update(campaignManifestSHA256=digest(direct_bytes(evidence.directory / "campaign-authority.json")),
                      candidateInventorySHA256=authority["candidateInventorySHA256"])
    return result


def check_exec(body, machine, argv):
    require(body.get("schema") == "dev.dory.machine.exec" and type(body.get("version")) is int
            and body["version"] == 1
            and body.get("machine") == machine and body.get("argv") == argv,
            "guest exec does not bind the exact machine and command")
    require(type(body.get("exitCode")) is int and body["exitCode"] == 0
            and body.get("timedOut") is False and body.get("stdoutTruncated") is False
            and body.get("stderrTruncated") is False,
            "guest command failed, timed out or was truncated")
    require(isinstance(body.get("stdout"), str), "guest exec stdout is missing")
    return object_json(body["stdout"])


def guest_script(action, nonce, network):
    # Constants are JSON-encoded, never interpolated into guest shell syntax. The agent runs
    # python3 directly. The same source is reconstructed during replay to bind each observation.
    return "action, nonce, network = " + repr((action, nonce, network)) + "\n" + GUEST_SOURCE


GUEST_SOURCE = r'''
import hashlib, json, os, platform, socket, subprocess, urllib.request
from pathlib import Path
directory = Path('/var/lib/dory/qualification') / nonce
payload = directory / 'durability.bin'
reference = hashlib.sha256(nonce.encode('ascii')).digest() * 16384
def command(argv):
    return subprocess.check_output(argv, text=True).strip()
def payload_hash():
    return hashlib.sha256(payload.read_bytes()).hexdigest()
result = {'nonce': nonce, 'action': action}
if action in ('write', 'mutate'):
    directory.mkdir(mode=0o700, parents=True, exist_ok=action == 'mutate')
    if directory.is_symlink() or payload.is_symlink():
        raise RuntimeError('qualification payload is a symlink')
    flags = os.O_WRONLY | os.O_NOFOLLOW
    flags |= (os.O_CREAT | os.O_EXCL) if action == 'write' else os.O_TRUNC
    fd = os.open(payload, flags, 0o600)
    with os.fdopen(fd, 'wb') as target:
        target.write(reference if action == 'write' else b'mutated-after-snapshot\n')
        target.flush()
        os.fsync(target.fileno())
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    os.sync()
    result.update(payloadSHA256=payload_hash(), fileFsync=True, directoryFsync=True)
elif action == 'boot':
    release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            release[key] = value.strip('"')
    mounts = json.loads(command(['findmnt', '--json', '--target', '/', '--output', 'SOURCE,FSTYPE']))
    root = mounts['filesystems'][0]
    routes = json.loads(command(['ip', '-json', 'route', 'show', 'default']))
    routes6 = json.loads(command(['ip', '-json', '-6', 'route', 'show', 'default']))
    sessions = []
    for line in command(['loginctl', 'list-sessions', '--no-legend']).splitlines():
        session_id = line.split()[0]
        properties = {}
        for row in command(['loginctl', 'show-session', session_id,
                            '--property=Type,Class,State,Remote,Seat']).splitlines():
            key, value = row.split('=', 1)
            properties[key] = value
        if properties.get('Type') in ('x11', 'wayland'):
            sessions.append(properties)
    result.update(bootID=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                  architecture=platform.machine(), osID=release.get('ID'),
                  osVersion=release.get('VERSION_ID'), efi=Path('/sys/firmware/efi').is_dir(),
                  rootSource=root['source'], rootFSType=root['fstype'],
                  defaultRoutes=routes + routes6, graphicalSessions=sessions,
                  displayManagerActive=subprocess.run(['systemctl', 'is-active', 'display-manager'],
                                                      capture_output=True, text=True).stdout.strip() == 'active',
                  payloadSHA256=payload_hash() if payload.exists() else None)
    if network == 'shared-nat':
        repository_host, repository_path = (('archive.ubuntu.com', '/ubuntu/dists/noble/Release')
                                           if platform.machine() == 'x86_64'
                                           else ('ports.ubuntu.com', '/ubuntu-ports/dists/noble/Release'))
        repository_url = 'https://' + repository_host + repository_path
        addresses = socket.getaddrinfo(repository_host, 443, type=socket.SOCK_STREAM)
        with urllib.request.urlopen(repository_url, timeout=15) as response:
            prefix = response.read(256)
            result.update(networkStatus=response.status, dnsAddressCount=len(addresses),
                          repositoryPrefixSHA256=hashlib.sha256(prefix).hexdigest(), repositoryURL=repository_url)
elif action == 'reboot':
    subprocess.run(['systemd-run', '--quiet', '--unit=dory-qualification-reboot-' + nonce,
                    '--on-active=3s', '/usr/bin/systemctl', 'reboot'], check=True)
    result['rebootScheduled'] = True
elif action == 'packages':
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    environment = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='a')
    log = directory / 'apt.log'
    with log.open('xb') as output:
        for argv in (['apt-get', '-o', 'APT::Update::Error-Mode=any', 'update'],
                     ['apt-get', '-y', '--with-new-pkgs', 'upgrade'],
                     ['apt-get', '-y', '--reinstall', 'install', 'tree']):
            subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT,
                           env=environment, check=True)
        output.flush()
        os.fsync(output.fileno())
    result.update(updateExitCode=0, upgradeExitCode=0, installExitCode=0, package='tree',
                  packageStatus=command(['dpkg-query', '-W', '-f=${Status}', 'tree']),
                  packageVersion=command(['dpkg-query', '-W', '-f=${Version}', 'tree']),
                  packageLogSHA256=hashlib.sha256(log.read_bytes()).hexdigest())
else:
    raise RuntimeError('unknown lifecycle action')
print(json.dumps(result, sort_keys=True, separators=(',', ':')))
'''


def check_guest(observation, action, nonce, network, expected_hash=None, graphical=True, *, architecture="arm64"):
    require(architecture in {"arm64", "x86_64"}, "unsupported installed guest architecture")
    require(observation.get("nonce") == nonce and observation.get("action") == action,
            "guest observation is stale or belongs to another phase")
    if action == "boot":
        require(canonical_uuid(observation.get("bootID")), "guest boot ID is invalid")
        require(observation.get("architecture") == ("aarch64" if architecture == "arm64" else "x86_64")
                and observation.get("osID") == "ubuntu"
                and observation.get("osVersion") == "24.04" and observation.get("efi") is True,
                "guest is not the selected installed EFI Ubuntu 24.04 ISA cell")
        require(isinstance(observation.get("rootSource"), str)
                and observation["rootSource"].startswith("/dev/")
                and not observation["rootSource"].startswith(("/dev/loop", "/dev/sr"))
                and observation.get("rootFSType") in {"ext4", "xfs", "btrfs"},
                "guest root is an installer/live filesystem rather than an installed disk")
        sessions = observation.get("graphicalSessions")
        require(isinstance(sessions, list) and type(observation.get("displayManagerActive")) is bool,
                "guest graphical-session observation is malformed")
        if graphical and not (observation["displayManagerActive"]
                and any(isinstance(session, dict) and session.get("Type") in {"x11", "wayland"}
                        and session.get("Class") == "user" and session.get("State") == "active"
                        and session.get("Remote") == "no" and session.get("Seat") == "seat0"
                        for session in sessions)):
            raise GuestNotReady("installed guest has no active local graphical user session")
        routes = observation.get("defaultRoutes")
        require(isinstance(routes, list), "missing guest network observation")
        if network == "disconnected":
            require(not routes and "networkStatus" not in observation,
                    "offline reopen still has a default network route")
        else:
            require(bool(routes) and observation.get("networkStatus") == 200
                    and type(observation.get("dnsAddressCount")) is int
                    and observation["dnsAddressCount"] > 0
                    and sha256_value(observation.get("repositoryPrefixSHA256")),
                    "guest NAT, DNS and repository access are not working")
            if architecture == "x86_64":
                require(observation.get("repositoryURL") == "https://archive.ubuntu.com/ubuntu/dists/noble/Release",
                        "PC network probe did not check the x86 Ubuntu repository")
        if expected_hash is not None:
            require(observation.get("payloadSHA256") == expected_hash,
                    "durable guest payload did not survive the transition")
    elif action in {"write", "mutate"}:
        require(observation.get("fileFsync") is True
                and observation.get("directoryFsync") is True
                and observation.get("payloadSHA256") == expected_hash,
                "guest write did not fsync the expected bytes")
    elif action == "reboot":
        require(observation.get("rebootScheduled") is True, "guest reboot was not scheduled")
    elif action == "packages":
        require(all(type(observation.get(key)) is int and observation[key] == 0
                    for key in ("updateExitCode", "upgradeExitCode", "installExitCode"))
                and observation.get("package") == "tree"
                and observation.get("packageStatus") == "install ok installed"
                and isinstance(observation.get("packageVersion"), str)
                and bool(observation["packageVersion"])
                and sha256_value(observation.get("packageLogSHA256")),
                "APT update/upgrade/install did not all complete")


def check_status(status, machine, *, running=True, media_absent=True, network=None,
                 architecture="arm64", graphics_backend="virgl-venus"):
    require(architecture in {"arm64", "x86_64"}
            and graphics_backend in ({"virgl-venus"} if architecture == "arm64" else {"virgl", "virgl-venus"}),
            "unsupported guest ISA/renderer profile")
    require(status.get("id") == machine and status.get("guestArchitecture") == architecture
            and status.get("state") == ("running" if running else "stopped"),
            "daemon returned a different machine, architecture or state")
    if media_absent:
        require(status.get("installerMediaAttached") is False,
                "installer media is still attached")
    if network is not None:
        settings = status.get("typedSettings")
        require(isinstance(settings, dict) and settings.get("networkMode") == network,
                "daemon did not retain the requested network policy")
    if running:
        identity = status.get("runtimeIdentity")
        graphics = status.get("runtimeGraphicsSelection")
        require(isinstance(identity, dict) and identity.get("mode") == "resolved-plan"
                and sha256_value(identity.get("planSHA256")), "missing resolved runtime authority")
        require(isinstance(graphics, dict) and canonical_uuid(graphics.get("operationID"))
                and graphics.get("resolvedPlanSHA256") == identity["planSHA256"]
                and graphics.get("backend") == graphics_backend
                and type(graphics.get("rendererGeneration")) is int
                and graphics["rendererGeneration"] > 0
                and sha256_value(graphics.get("rendererWorkerReceiptSHA256")),
                "renderer ownership does not bind the running plan")
        if architecture == "x86_64":
            require(graphics.get("accelerationLevel") == "hardware-accelerated-3d",
                    "PC renderer campaign cannot accept software acceleration or a silent fallback")


def check_window(window, status, machine, service, pid=None):
    require(window.get("kind") == "dev.dory.display-qualification-window"
            and window.get("schemaVersion") == 2
            and window.get("machineID") == machine and window.get("machServiceName") == service
            and window.get("bundleIdentifier") == "com.pythonxi.Dory"
            and window.get("operationID") == status["runtimeGraphicsSelection"]["operationID"]
            and window.get("scanoutID") == 0
            and window.get("windowTitle") == f"Dory — {machine} — Display 1"
            and window.get("transport") in {"sharedMemory", "sharedTexture"},
            "fresh display receipt does not bind this runtime and app window")
    for key in ("processID", "windowNumber", "frameSequence", "displayResourceGeneration",
                "metalCommandBufferCompletionID"):
        require(type(window.get(key)) is int and window[key] > 0,
                f"display receipt has no positive {key}")
    require(pid is None or window["processID"] == pid, "display receipt belongs to another process")


class Evidence:
    def __init__(self, directory):
        self.directory = directory

    def write(self, name, body):
        require(re.fullmatch(r"[a-z0-9.-]+", name) is not None, "invalid evidence filename")
        path = self.directory / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as target:
            target.write((json.dumps(body, indent=2, sort_keys=True) + "\n").encode())
            target.flush()
            os.fsync(target.fileno())
        return name

    def read(self, name):
        require(re.fullmatch(r"[a-z0-9.-]+", name) is not None, "invalid evidence reference")
        path = self.directory / name
        try:
            return object_json(direct_bytes(path).decode())
        except (OSError, UnicodeError) as error:
            raise LifecycleError(f"unsafe or missing evidence {name}: {error}") from error

    def references(self, names):
        require(all(isinstance(name, str) and re.fullmatch(r"[a-z0-9.-]+", name) is not None for name in names),
                "invalid lifecycle reference name")
        return {name: digest(direct_bytes(self.directory / name)) for name in names}


CONTROL_TIMING_BOUNDARY = "host-cli-submission-through-subprocess-completion"
CONTROL_RECORD_PREFIXES = {"lifecycle", "mapped-fault", "flush-fault", "navigation", "renderer-recovery"}


def verify_control_timing(record, name, app, service, machine):
    """Validate transport wall time, never guest boot/login/frame or release performance."""
    timing = dictionary(record.get("controlTiming"), "control timing")
    match = re.fullmatch(r"([a-z-]+)-([0-9]{4,})-([a-z-]+)\.json", name)
    argv = record.get("argv")
    require(match is not None and match[1] in CONTROL_RECORD_PREFIXES
            and isinstance(argv, list) and len(argv) >= 8
            and all(isinstance(value, str) for value in argv)
            and argv[:3] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service]
            and argv[3] == "--timeout" and argv[5] == "machine" and argv[7] == machine
            and re.fullmatch(r"[1-9][0-9]{0,3}", argv[4]) is not None and int(argv[4]) <= 7200,
            "control timing command authority mismatch")
    require(timing.get("kind") == "dev.dory.desktop-control-timing"
            and type(timing.get("schemaVersion")) is int and timing["schemaVersion"] == 1
            and timing.get("clock") == "host-monotonic"
            and timing.get("boundary") == CONTROL_TIMING_BOUNDARY
            and timing.get("operationLabel") == match[3], "control timing schema/boundary mismatch")
    fields = ("startedUptimeNanoseconds", "completedUptimeNanoseconds", "elapsedNanoseconds", "timeoutNanoseconds")
    require(all(type(timing.get(key)) is int and 0 <= timing[key] <= 2**64 - 1 for key in fields)
            and timing["completedUptimeNanoseconds"] >= timing["startedUptimeNanoseconds"]
            and timing["elapsedNanoseconds"] == timing["completedUptimeNanoseconds"] - timing["startedUptimeNanoseconds"]
            and timing["timeoutNanoseconds"] == int(argv[4]) * 1_000_000_000,
            "control timing interval or original deadline mismatch")
    outcome = timing.get("outcome")
    code = record.get("returnCode")
    require(isinstance(record.get("stdout"), str) and isinstance(record.get("stderr"), str)
            and ((outcome == "succeeded" and type(code) is int and code == 0 and record.get("timedOut") is False)
                 or (outcome == "failed" and type(code) is int and code != 0 and record.get("timedOut") is False)
                 or (outcome == "timed-out" and code is None and record.get("timedOut") is True)
                 or (outcome == "spawn-failed" and code is None and record.get("timedOut") is False
                     and type(record.get("spawnErrorNumber")) is int)
                 or (outcome == "interrupted" and code is None and record.get("timedOut") is False
                     and isinstance(record.get("interruption"), str))),
            "control timing outcome does not match raw completion")
    return timing


def control_timing_groups(evidence, names, app, service, machine):
    require(isinstance(names, list) and len(names) <= 16384
            and all(isinstance(name, str) for name in names) and len(names) == len(set(names)),
            "control timing inventory is invalid or unbounded")
    groups, previous_end, previous_sequence = {}, None, 0
    for name in names:
        raw = evidence.read(name)
        timing = verify_control_timing(raw, name, app, service, machine)
        sequence = int(re.fullmatch(r"[a-z-]+-([0-9]{4,})-[a-z-]+\.json", name)[1])
        require(sequence == previous_sequence + 1
                and (previous_end is None or timing["startedUptimeNanoseconds"] >= previous_end),
                "control timings are reordered, overlapping or missing an attempt")
        previous_sequence, previous_end = sequence, timing["completedUptimeNanoseconds"]
        key = (raw["argv"][6], timing["operationLabel"])
        group = groups.setdefault(key, {"command": key[0], "operationLabel": key[1], "attemptCount": 0,
            "succeededCount": 0, "failedCount": 0, "timedOutCount": 0, "spawnFailedCount": 0,
            "interruptedCount": 0, "successfulElapsedNanoseconds": []})
        group["attemptCount"] += 1
        counter = {"succeeded": "succeededCount", "failed": "failedCount", "timed-out": "timedOutCount",
                   "spawn-failed": "spawnFailedCount", "interrupted": "interruptedCount"}[timing["outcome"]]
        group[counter] += 1
        if timing["outcome"] == "succeeded":
            group["successfulElapsedNanoseconds"].append(timing["elapsedNanoseconds"])
    for group in groups.values():
        values = sorted(group["successfulElapsedNanoseconds"])
        # Nearest-rank quantiles of successful transport calls only. All failed/censored calls
        # remain in the hashed inventory and separate counters, not hidden in these quantiles.
        group["successfulPercentilesNanoseconds"] = {
            f"p{percent}": values[(len(values) * percent + 99) // 100 - 1] if values else None
            for percent in (50, 95, 99)}
    return [groups[key] for key in sorted(groups)]


def verify_control_timing_summary(evidence, machine, service, app, *, architecture="arm64",
                                  graphics_backend="virgl-venus", expected_nonce=None):
    summary = evidence.read("desktop-lifecycle-control-timings.json")
    prefix, names = summary.get("recordPrefix"), summary.get("attempts")
    require(isinstance(prefix, str) and prefix in CONTROL_RECORD_PREFIXES
            and isinstance(names, list) and len(names) <= 16384
            and all(isinstance(name, str) for name in names) and len(names) == len(set(names)),
            "control timing namespace/inventory mismatch")
    inventory = sorted(path.name for path in evidence.directory.iterdir()
                       if re.fullmatch(re.escape(prefix) + r"-[0-9]{4,}-[a-z-]+\.json", path.name))
    require(sorted(names) == inventory, "control timing summary omitted or added a raw attempt")
    require(summary.get("kind") == "dev.dory.desktop-control-timing-summary"
            and type(summary.get("schemaVersion")) is int and summary["schemaVersion"] == 1
            and summary.get("releaseEligible") is False and summary.get("boundary") == CONTROL_TIMING_BOUNDARY
            and summary.get("machine") == machine and summary.get("machService") == service
            and summary.get("guestArchitecture") == architecture
            and isinstance(summary.get("nonce"), str) and re.fullmatch(r"[0-9a-f]{32}", summary["nonce"]) is not None
            and (expected_nonce is None or summary["nonce"] == expected_nonce)
            and summary.get("profileBinding") == profile_binding(evidence, machine, service, app, architecture, graphics_backend)
            and summary.get("sourceSHA256") == source_hashes(architecture)
            and summary.get("references") == evidence.references(names), "control timing summary authority mismatch")
    # Python considers True == 1 and 30.0 == 30; evidence must retain integer counts/times.
    require(json.dumps(summary.get("groups"), sort_keys=True)
            == json.dumps(control_timing_groups(evidence, names, app, service, machine), sort_keys=True),
            "control timing statistics disagree with retained attempts")
    return summary


class Campaign:
    def __init__(self, app, service, machine, evidence, timeout, nonce, login_input=None,
                 record_prefix="lifecycle", architecture="arm64", graphics_backend="virgl-venus"):
        self.app, self.service, self.machine = app, service, machine
        self.evidence, self.timeout, self.nonce = evidence, timeout, nonce
        self.ctl = app / "Contents/Helpers/dorydctl"
        self.sequence = 0
        self.control_records = []
        self.login_input = login_input
        self.login_input_sha256 = None if login_input is None else digest(login_input.read_bytes())
        require(record_prefix in CONTROL_RECORD_PREFIXES, "unknown control-record namespace")
        self.record_prefix = record_prefix
        self.architecture, self.graphics_backend = architecture, graphics_backend

    def ctl_call(self, arguments, label, timeout=None):
        require(isinstance(label, str) and re.fullmatch(r"[a-z-]+", label) is not None,
                "invalid control operation label")
        self.sequence += 1
        name = f"{self.record_prefix}-{self.sequence:04d}-{label}.json"
        seconds = self.timeout if timeout is None else min(timeout, self.timeout)
        argv = [str(self.ctl), "--mach-service", self.service, "--timeout", str(seconds),
                "machine", *arguments]
        started = time.monotonic_ns()
        interrupted = None
        try:
            result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", timeout=seconds)
            record = {"argv": argv, "returnCode": result.returncode, "timedOut": False,
                      "stdout": result.stdout, "stderr": result.stderr}
            outcome = "succeeded" if result.returncode == 0 else "failed"
        except subprocess.TimeoutExpired as error:
            def partial_text(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            record = {"argv": argv, "returnCode": None, "timedOut": True,
                      "stdout": partial_text(error.stdout), "stderr": partial_text(error.stderr)}
            outcome = "timed-out"
        except OSError as error:
            record = {"argv": argv, "returnCode": None, "timedOut": False, "stdout": "",
                      "stderr": str(error), "spawnErrorNumber": error.errno if error.errno is not None else 0}
            outcome = "spawn-failed"
        except LifecycleError as error:
            interrupted = error
            record = {"argv": argv, "returnCode": None, "timedOut": False, "stdout": "",
                      "stderr": "", "interruption": str(error)}
            outcome = "interrupted"
        completed = time.monotonic_ns()
        record["controlTiming"] = {"kind": "dev.dory.desktop-control-timing", "schemaVersion": 1,
            "clock": "host-monotonic", "boundary": CONTROL_TIMING_BOUNDARY, "operationLabel": label,
            "startedUptimeNanoseconds": started, "completedUptimeNanoseconds": completed,
            "elapsedNanoseconds": completed - started, "timeoutNanoseconds": seconds * 1_000_000_000,
            "outcome": outcome}
        self.evidence.write(name, record)
        self.control_records.append(name)
        if interrupted is not None:
            raise interrupted
        if record["timedOut"] or record["returnCode"] != 0:
            raise TransportUnavailable(f"control request failed; retained {name}")
        require(len(record["stdout"].encode()) <= 8 * 1024 * 1024, "control output exceeds limit")
        return object_json(record["stdout"]), name

    def write_control_timing_summary(self):
        names = list(self.control_records)
        self.evidence.write("desktop-lifecycle-control-timings.json", {
            "kind": "dev.dory.desktop-control-timing-summary", "schemaVersion": 1,
            "machine": self.machine, "machService": self.service, "nonce": self.nonce,
            "guestArchitecture": self.architecture, "releaseEligible": False,
            "boundary": CONTROL_TIMING_BOUNDARY, "recordPrefix": self.record_prefix,
            "sourceSHA256": source_hashes(self.architecture),
            "profileBinding": profile_binding(self.evidence, self.machine, self.service, self.app,
                                               self.architecture, self.graphics_backend),
            "attempts": names, "references": self.evidence.references(names),
            "groups": control_timing_groups(self.evidence, names, self.app, self.service, self.machine),
        })
        return verify_control_timing_summary(self.evidence, self.machine, self.service, self.app,
            architecture=self.architecture, graphics_backend=self.graphics_backend, expected_nonce=self.nonce)

    def guest(self, action, network="shared-nat", timeout=None):
        argv = ["python3", "-c", guest_script(action, self.nonce, network)]
        seconds = self.timeout if timeout is None else min(timeout, self.timeout)
        body, name = self.ctl_call(["exec", self.machine, "--json", "--timeout-ms",
                                    str(seconds * 1000), "--output-limit-bytes", "4194304",
                                    "--", *argv], action, seconds)
        observation = check_exec(body, self.machine, argv)
        return observation, name

    def wait_boot(self, old_boot=None, network="shared-nat", media_absent=True, expected_hash=None,
                  graphical=True):
        deadline = time.monotonic() + self.timeout
        last_unavailable = "no installed-disk boot observation"
        while time.monotonic() < deadline:
            remaining = max(1, int(deadline - time.monotonic()))
            try:
                status, status_name = self.ctl_call(["status", self.machine], "status", min(15, remaining))
                require(status.get("id") == self.machine, "status returned another machine")
                require(status.get("state") not in {"failed", "stopped", "suspended"},
                        "runtime entered a terminal state while waiting for boot")
                if status.get("state") == "running":
                    remaining = max(1, int(deadline - time.monotonic()))
                    require(time.monotonic() < deadline, "boot deadline expired during status query")
                    observation, guest_name = self.guest("boot", network, min(30, remaining))
                    check_guest(observation, "boot", self.nonce, network, expected_hash, graphical,
                                architecture=self.architecture)
                    if old_boot is None or observation["bootID"] != old_boot:
                        check_status(status, self.machine, media_absent=media_absent, network=network,
                                     architecture=self.architecture, graphics_backend=self.graphics_backend)
                        return observation, status, [status_name, guest_name]
            except (TransportUnavailable, GuestNotReady) as error:
                last_unavailable = str(error)
                # Agent/display-manager startup may lag the CPU boot; malformed evidence is terminal.
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        raise LifecycleError("guest did not reach a new installed-disk boot before the deadline: " + last_unavailable)

    @contextmanager
    def display_session(self, label, login=False):
        """Keep the owned window available while agent/graphical-login startup progresses."""
        name = f"lifecycle-{label}-window.json"
        path = self.evidence.directory / name
        require(not path.exists() and not path.is_symlink(), "display evidence already exists")
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("DORY_DISPLAY_QUALIFICATION_")}
        environment.update(DORYD_MACH_SERVICE=self.service,
                           DORY_DISPLAY_QUALIFICATION_MACHINE_ID=self.machine,
                           DORY_DISPLAY_QUALIFICATION_SCANOUT_ID="0",
                           DORY_DISPLAY_QUALIFICATION_WINDOW_RECEIPT=str(path))
        if login and self.login_input is not None:
            environment.update(DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT=str(self.login_input),
                               DORY_DISPLAY_QUALIFICATION_INPUT_RECEIPT=str(
                                   self.evidence.directory / f"lifecycle-{label}-input.json"))
        executable = self.app / "Contents/MacOS/Dory"
        with (self.evidence.directory / f"lifecycle-{label}-app.out").open("xb") as output, \
             (self.evidence.directory / f"lifecycle-{label}-app.err").open("xb") as error:
            process = subprocess.Popen([str(executable)], env=environment, stdout=output, stderr=error)
            try:
                yield process, name
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)

    def display(self, label, status):
        with self.display_session(label) as (process, name):
            path = self.evidence.directory / name
            deadline = time.monotonic() + self.timeout
            while not path.exists():
                require(process.poll() is None, "display app exited before publishing a frame")
                require(time.monotonic() < deadline, "display frame deadline expired")
                time.sleep(0.2)
            window = self.evidence.read(name)
            check_window(window, status, self.machine, self.service, process.pid)
            return name

    def login_boot(self, label, old_boot=None, network="shared-nat", expected_hash=None):
        if self.login_input is not None:
            # Never send an installed-desktop login script to firmware or the pre-reboot
            # operation. Keep a window visible until the new guest's system agent is ready,
            # then create the key-delivering app for that operation only.
            with self.display_session(label + "-boot") as (process, _):
                self.wait_boot(old_boot, network, expected_hash=expected_hash, graphical=False)
                require(process.poll() is None, "boot display app exited before agent readiness")
        with self.display_session(label + "-login", login=True) as (process, _):
            # The signed app continues polling across firmware/boot and delivers optional keys
            # itself. This window is not the post-login phase receipt: reacquire that below.
            observation, status, names = self.wait_boot(old_boot, network, expected_hash=expected_hash)
            require(process.poll() is None, "login display app exited during boot")
            if self.login_input is not None:
                require(digest(self.login_input.read_bytes()) == self.login_input_sha256,
                        "login script changed during the campaign")
                input_name = f"lifecycle-{label}-login-input.json"
                keyboard = self.evidence.read(input_name)
                require(keyboard.get("kind") == "dev.dory.display-qualification-input"
                        and keyboard.get("schemaVersion") == 1
                        and keyboard.get("delivery") == "runner-applied"
                        and keyboard.get("bundleIdentifier") == "com.pythonxi.Dory"
                        and keyboard.get("machineID") == self.machine
                        and keyboard.get("machServiceName") == self.service
                        and keyboard.get("processID") == process.pid
                        and keyboard.get("operationID") == status["runtimeGraphicsSelection"]["operationID"]
                        and keyboard.get("scriptSHA256") == self.login_input_sha256
                        and type(keyboard.get("firstCommandSequence")) is int
                        and keyboard["firstCommandSequence"] > 0
                        and type(keyboard.get("lastCommandSequence")) is int
                        and keyboard["lastCommandSequence"] >= keyboard["firstCommandSequence"],
                        "login input was not applied by this machine's signed display app")
        names.append(self.display(label, status))
        return observation, status, names

    def stop(self):
        status, name = self.ctl_call(["stop", self.machine], "stop")
        require(status.get("id") == self.machine and status.get("state") == "stopped",
                "stop did not close the campaign runtime")
        return name

    def cold_boot(self, label, old_boot, network, expected_hash, eject=False):
        names = [self.stop()]
        arguments = ["update", self.machine, "--network", network]
        status, name = self.ctl_call(arguments, "update")
        check_status(status, self.machine, running=False, media_absent=not eject, network=network,
                     architecture=self.architecture, graphics_backend=self.graphics_backend)
        names.append(name)
        if eject:
            status, name = self.ctl_call(["update", self.machine, "--eject-installer"], "eject")
            check_status(status, self.machine, running=False, network=network,
                         architecture=self.architecture, graphics_backend=self.graphics_backend)
            names.append(name)
        _, name = self.ctl_call(["start", self.machine], "start")
        names.append(name)
        observation, status, boot_names = self.login_boot(label, old_boot, network, expected_hash)
        names += boot_names
        return observation, status, names


def phase_record(campaign, name, observation, before, references, network="shared-nat"):
    return {
        "kind": "dev.dory.installed-desktop-lifecycle-phase", "schemaVersion": 1,
        "status": "PASS", "phase": name, "machine": campaign.machine,
        "machService": campaign.service, "nonce": campaign.nonce,
        **profile_binding(campaign.evidence, campaign.machine, campaign.service, campaign.app,
                          campaign.architecture, campaign.graphics_backend),
        "beforeBootID": before, "afterBootID": observation["bootID"],
        "expectedNetwork": network, "display": True, "storage": True,
        "network": True, "vsock": True, "rendererOwnership": True,
        "references": campaign.evidence.references(references),
    }


def run_journey(campaign):
    evidence = campaign.evidence
    binding = profile_binding(evidence, campaign.machine, campaign.service, campaign.app,
                              campaign.architecture, campaign.graphics_backend)
    sources = source_hashes(campaign.architecture)
    nonce = campaign.nonce
    expected_hash = digest(hashlib.sha256(nonce.encode("ascii")).digest() * 16384)
    before, baseline_status, baseline_names = campaign.wait_boot(media_absent=False)
    written, write_name = campaign.guest("write")
    check_guest(written, "write", nonce, "shared-nat", expected_hash, architecture=campaign.architecture)
    installed, _, names = campaign.cold_boot("installer-reboot", before["bootID"],
                                              "shared-nat", expected_hash, eject=baseline_status.get("installerMediaAttached") is True)
    evidence.write("installer-reboot.json", phase_record(campaign, "installer-reboot", installed,
                                                        before["bootID"], baseline_names + [write_name] + names))
    offline, _, offline_names = campaign.cold_boot("cold-offline-reopen", installed["bootID"],
                                                   "disconnected", expected_hash)
    evidence.write("cold-offline-reopen.json", phase_record(campaign, "cold-offline-reopen", offline,
                                                          installed["bootID"], offline_names, "disconnected"))
    reopened, _, names = campaign.cold_boot("cold-reopen", offline["bootID"], "shared-nat", expected_hash)
    evidence.write("cold-reopen.json", phase_record(campaign, "cold-reopen", reopened,
                                                   offline["bootID"], names))
    reboot, reboot_name = campaign.guest("reboot")
    check_guest(reboot, "reboot", nonce, "shared-nat", architecture=campaign.architecture)
    rebooted, status, names = campaign.login_boot("guest-reboot", reopened["bootID"], expected_hash=expected_hash)
    names = [reboot_name] + names
    evidence.write("guest-reboot.json", phase_record(campaign, "guest-reboot", rebooted,
                                                    reopened["bootID"], names))
    packages, package_name = campaign.guest("packages")
    check_guest(packages, "packages", nonce, "shared-nat", architecture=campaign.architecture)
    evidence.write("package-update.json", {
        "kind": "dev.dory.installed-desktop-package-phase", "schemaVersion": 1, "status": "PASS",
        "machine": campaign.machine, "machService": campaign.service, "nonce": nonce,
        **binding,
        "updated": True, "installed": True, "package": packages["package"],
        "packageVersion": packages["packageVersion"], "references": evidence.references([package_name]),
    })
    snapshot_id = "desktop-recovery-" + nonce
    names = [campaign.stop()]
    snapshot, snapshot_name = campaign.ctl_call(
        ["snapshot", campaign.machine, "--id", snapshot_id, "--note", "Installed desktop byte recovery"],
        "snapshot")
    require(snapshot.get("machineID") == campaign.machine and snapshot.get("id") == snapshot_id
            and snapshot.get("consistency") == "cold-stopped", "snapshot has the wrong consistency/owner")
    root = dictionary(dictionary(snapshot.get("artifactEvidence"), "snapshot artifact evidence").get("rootfs"),
                      "snapshot root disk")
    require(sha256_value(root.get("sha256")) and type(root.get("byteCount")) is int and root["byteCount"] > 0,
            "snapshot has no retained root-disk artifact")
    _, start_name = campaign.ctl_call(["start", campaign.machine], "start")
    mutation_boot, _, boot_names = campaign.login_boot("snapshot-mutation", rebooted["bootID"], expected_hash=expected_hash)
    mutated, mutate_name = campaign.guest("mutate")
    check_guest(mutated, "mutate", nonce, "shared-nat", digest(b"mutated-after-snapshot\n"),
                architecture=campaign.architecture)
    names += [snapshot_name, start_name] + boot_names + [mutate_name, campaign.stop()]
    restored, restore_name = campaign.ctl_call(["restore-snapshot", campaign.machine, snapshot_id], "restore")
    check_status(restored, campaign.machine, running=False,
                 architecture=campaign.architecture, graphics_backend=campaign.graphics_backend)
    _, start_name = campaign.ctl_call(["start", campaign.machine], "start")
    recovered, status, boot_names = campaign.login_boot("storage-recovery", mutation_boot["bootID"], expected_hash=expected_hash)
    snapshot_plan = dictionary(snapshot.get("runtimeIdentity"), "snapshot runtime identity").get("planSHA256")
    require(sha256_value(snapshot_plan) and status["runtimeIdentity"]["planSHA256"] != snapshot_plan,
            "restored runtime reused a stale snapshot plan")
    names += [restore_name, start_name] + boot_names
    deleted, delete_name = campaign.ctl_call(["delete-snapshot", campaign.machine, snapshot_id], "delete-snapshot")
    require(deleted.get("ok") is True, "recovery snapshot was not deleted")
    names.append(delete_name)
    evidence.write("storage-recovery.json", {
        "kind": "dev.dory.installed-desktop-storage-phase", "schemaVersion": 1,
        "status": "INCOMPLETE", "machine": campaign.machine, "machService": campaign.service,
        "nonce": nonce, "durableFlush": True, "recovered": True, "fullFlushFailureObserved": False,
        **binding,
        "expectedPayloadSHA256": expected_hash, "recoveredPayloadSHA256": recovered["payloadSHA256"],
        "beforeBootID": mutation_boot["bootID"], "afterBootID": recovered["bootID"],
        "snapshotID": snapshot_id, "references": evidence.references([write_name] + names),
        "missingAuthorities": ["daemon-storage-fault-injection"],
        "detail": "Guest fsync, offline cold reopen and exact snapshot byte recovery passed; no host full-flush failure was injected.",
    })
    require(sources == source_hashes(campaign.architecture)
            and binding == profile_binding(evidence, campaign.machine, campaign.service, campaign.app,
                                           campaign.architecture, campaign.graphics_backend),
            "lifecycle source/candidate changed during execution")
    verify_journey(evidence, campaign.machine, campaign.service, campaign.app,
                   architecture=campaign.architecture, graphics_backend=campaign.graphics_backend)
    evidence.write("desktop-lifecycle-readiness.json", {
        "kind": "dev.dory.installed-desktop-lifecycle-readiness", "schemaVersion": 1,
        "status": "implemented-phases-passed", "machine": campaign.machine,
        "machService": campaign.service, "nonce": nonce, "releaseEligible": False,
        **binding, "sourceSHA256": sources,
        "references": evidence.references(["installer-reboot.json", "cold-offline-reopen.json",
                                           "cold-reopen.json", "guest-reboot.json", "package-update.json",
                                           "storage-recovery.json"]),
    })
    return verify_readiness(evidence, campaign.machine, campaign.service, campaign.app,
                            architecture=campaign.architecture, graphics_backend=campaign.graphics_backend)


def verify_journey(evidence, machine, service, app, *, architecture="arm64", graphics_backend="virgl-venus"):
    """Replay raw command/results; consistently rehashed PASS booleans are insufficient."""
    phases = ("installer-reboot", "cold-offline-reopen", "cold-reopen", "guest-reboot")
    previous_boot = None
    previous_runtime = None
    nonce = None
    expected_hash = None
    binding = profile_binding(evidence, machine, service, app, architecture, graphics_backend)
    for phase in (*phases, "package-update", "storage-recovery"):
        record = evidence.read(phase + ".json")
        require(record.get("schemaVersion") == 1 and record.get("machine") == machine
                and record.get("machService") == service, "phase authority mismatch")
        require(all(record.get(key, value if architecture == "arm64" else None) == value
                    for key, value in binding.items()), "lifecycle phase ISA/backend/candidate/source mismatch")
        if nonce is None:
            nonce = record.get("nonce")
            require(isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None,
                    "invalid lifecycle nonce")
            expected_hash = digest(hashlib.sha256(nonce.encode("ascii")).digest() * 16384)
        require(record.get("nonce") == nonce, "phase belongs to a different journey")
        references = record.get("references")
        require(isinstance(references, dict) and 1 <= len(references) <= 256, "phase has no bounded raw evidence")
        controls, observations, windows = [], [], []
        control_sequence = []
        for name, sha256 in sorted(references.items()):
            require(sha256_value(sha256), "invalid evidence digest")
            body = evidence.read(name)
            require(digest((evidence.directory / name).read_bytes()) == sha256,
                    "phase raw evidence digest mismatch")
            if body.get("kind") == "dev.dory.display-qualification-window":
                windows.append(body)
                continue
            argv = body.get("argv")
            sequence = re.fullmatch(r"lifecycle-([0-9]{4,})-[a-z-]+\.json", name)
            require(isinstance(argv, list) and len(argv) >= 8
                    and argv[:3] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service]
                    and argv[3] == "--timeout" and argv[5] == "machine"
                    and isinstance(argv[4], str) and re.fullmatch(r"[1-9][0-9]{0,3}", argv[4]) is not None
                    and int(argv[4]) <= 7200
                    and argv[7] == machine and type(body.get("returnCode")) is int
                    and body["returnCode"] == 0 and sequence is not None
                    and argv[6] in {"exec", "status", "start", "stop", "update", "snapshot",
                                    "restore-snapshot", "delete-snapshot"}
                    and body.get("timedOut") is False, "raw control authority mismatch")
            if "controlTiming" in body:
                verify_control_timing(body, name, app, service, machine)
            control_sequence.append(int(sequence[1]))
            arguments = argv[6:]
            if argv[6] in {"status", "start", "stop"}:
                require(arguments == [argv[6], machine], "lifecycle control has unrequested arguments")
            elif argv[6] == "update":
                expected = ["update", machine, "--network", "disconnected" if phase == "cold-offline-reopen" else "shared-nat"]
                require(arguments == expected or (phase == "installer-reboot"
                        and arguments == ["update", machine, "--eject-installer"]),
                        "lifecycle update changed its network/media scope or mixed transactions")
            elif argv[6] == "snapshot":
                require(arguments == ["snapshot", machine, "--id", "desktop-recovery-" + nonce,
                                      "--note", "Installed desktop byte recovery"], "snapshot creation changed its scope")
            elif argv[6] in {"restore-snapshot", "delete-snapshot"}:
                require(arguments == [argv[6], machine, "desktop-recovery-" + nonce],
                        "snapshot restore/delete changed its scope")
            output = object_json(body.get("stdout"))
            controls.append((argv[6], output, argv))
            if argv[6] == "exec":
                require("--" in argv, "guest command boundary is missing")
                require(len(arguments) == 11 and arguments[:4] == ["exec", machine, "--json", "--timeout-ms"]
                        and isinstance(arguments[4], str) and re.fullmatch(r"[1-9][0-9]{0,6}", arguments[4]) is not None
                        and 1 <= int(arguments[4]) <= int(argv[4]) * 1000
                        and arguments[5:8] == ["--output-limit-bytes", "4194304", "--"],
                        "guest lifecycle transport lost its bounded exact arguments")
                guest_argv = argv[argv.index("--") + 1:]
                observation = check_exec(output, machine, guest_argv)
                action = observation.get("action")
                require(action in {"boot", "write", "mutate", "reboot", "packages"},
                        "unknown guest lifecycle action")
                network = record.get("expectedNetwork", "shared-nat")
                # Installer's baseline probe precedes the durable-file creation.
                payload_expected = (None if phase == "installer-reboot" and action == "boot"
                                    and observation.get("bootID") == record.get("beforeBootID")
                                    else digest(b"mutated-after-snapshot\n") if action == "mutate"
                                    else expected_hash)
                require(guest_argv == ["python3", "-c", guest_script(action, nonce, network)],
                        "raw guest result was produced by a different probe")
                check_guest(observation, action, nonce, network, payload_expected, architecture=architecture)
                observations.append(observation)
        require(control_sequence == sorted(set(control_sequence)), "control sequence is not strictly ordered")
        if phase in phases:
            require(record.get("kind") == "dev.dory.installed-desktop-lifecycle-phase"
                    and record.get("status") == "PASS" and record.get("phase") == phase
                    and all(record.get(key) is True for key in
                            ("display", "storage", "network", "vsock", "rendererOwnership")),
                    "lifecycle phase is incomplete")
            before, after = record.get("beforeBootID"), record.get("afterBootID")
            require(canonical_uuid(before) and canonical_uuid(after) and before != after,
                    "transition reused its old guest boot ID")
            require(previous_boot is None or before == previous_boot, "boot chain is discontinuous")
            if phase == "installer-reboot":
                require(any(item.get("bootID") == before for item in observations),
                        "installer baseline boot was not observed")
                baseline_status = next(item[1] for item in controls if item[0] == "status")
                ejections = [item for item in controls if item[0] == "update" and "--eject-installer" in item[2]]
                require(type(baseline_status.get("installerMediaAttached")) is bool
                        and len(ejections) == int(baseline_status["installerMediaAttached"]),
                        "installer ejection does not match the initial media phase")
                require(any(item.get("action") == "write" for item in observations),
                        "durability baseline was never written")
            if phase == "guest-reboot":
                require(any(item.get("action") == "reboot" for item in observations)
                        and not any(item[0] in {"stop", "start", "restart"} for item in controls),
                        "guest reboot was replaced by a host restart")
            else:
                require(all(any(item[0] == command for item in controls)
                            for command in ("stop", "update", "start")), "cold boot controls are missing")
                order = [item[0] for item in controls if item[0] in {"stop", "update", "start"}]
                require(order == (["stop", "update", "update", "start"] if phase == "installer-reboot" and baseline_status["installerMediaAttached"]
                                  else ["stop", "update", "start"]), "cold boot controls ran out of order")
            network = "disconnected" if phase == "cold-offline-reopen" else "shared-nat"
            require(record.get("expectedNetwork") == network, "incorrect phase network expectation")
            require(any(item.get("bootID") == after for item in observations),
                    "new installed-disk boot was not observed")
            statuses = [item[1] for item in controls if item[0] == "status"]
            require(bool(statuses) and len(windows) == 1, "missing fresh runtime/display evidence")
            check_status(statuses[-1], machine, network=network,
                         architecture=architecture, graphics_backend=graphics_backend)
            check_window(windows[0], statuses[-1], machine, service)
            current = statuses[-1]
            if phase == "installer-reboot":
                require(len(statuses) >= 2, "installer has no baseline runtime receipt")
                check_status(statuses[0], machine, media_absent=False, network="shared-nat",
                             architecture=architecture, graphics_backend=graphics_backend)
                require(current["runtimeGraphicsSelection"]["operationID"] != statuses[0]["runtimeGraphicsSelection"]["operationID"],
                        "installer cold boot reused its original operation")
            elif phase == "guest-reboot":
                require(current["runtimeIdentity"] == previous_runtime["runtimeIdentity"]
                        and current["runtimeGraphicsSelection"]["operationID"] == previous_runtime["runtimeGraphicsSelection"]["operationID"],
                        "guest reboot replaced the VM operation or resolved plan")
            else:
                require(current["runtimeGraphicsSelection"]["operationID"] != previous_runtime["runtimeGraphicsSelection"]["operationID"],
                        "cold reopen reused an old operation")
            previous_runtime = current
            previous_boot = after
        elif phase == "package-update":
            require(record.get("kind") == "dev.dory.installed-desktop-package-phase"
                    and record.get("status") == "PASS" and record.get("updated") is True
                    and record.get("installed") is True and len(observations) == 1
                    and len(controls) == 1 and controls[0][0] == "exec"
                    and observations[0].get("action") == "packages"
                    and record.get("package") == observations[0]["package"]
                    and record.get("packageVersion") == observations[0]["packageVersion"],
                    "package result has no successful raw APT observation")
        else:
            require(record.get("kind") == "dev.dory.installed-desktop-storage-phase"
                    and record.get("status") == "INCOMPLETE"
                    and record.get("fullFlushFailureObserved") is False
                    and record.get("durableFlush") is True and record.get("recovered") is True
                    and record.get("missingAuthorities") == ["daemon-storage-fault-injection"]
                    and record.get("expectedPayloadSHA256") == expected_hash
                    and record.get("recoveredPayloadSHA256") == expected_hash,
                    "snapshot recovery must not claim an injected full-flush failure")
            require(all(any(item.get("action") == action for item in observations)
                        for action in ("write", "mutate", "boot")), "missing recovery byte observations")
            snapshots = [item[1] for item in controls if item[0] == "snapshot"]
            require(len(snapshots) == 1 and snapshots[0].get("machineID") == machine
                    and snapshots[0].get("id") == record.get("snapshotID") == "desktop-recovery-" + nonce
                    and snapshots[0].get("consistency") == "cold-stopped", "snapshot authority mismatch")
            root = dictionary(dictionary(snapshots[0].get("artifactEvidence"), "snapshot artifact evidence").get("rootfs"),
                              "snapshot root disk")
            require(sha256_value(root.get("sha256")) and type(root.get("byteCount")) is int
                    and root["byteCount"] > 0, "missing root-disk snapshot artifact")
            for command in ("restore-snapshot", "delete-snapshot"):
                matches = [item for item in controls if item[0] == command]
                require(len(matches) == 1 and len(matches[0][2]) == 9
                        and matches[0][2][8] == record["snapshotID"],
                        "restore/delete targeted another snapshot")
            require(next(item[1] for item in controls if item[0] == "delete-snapshot").get("ok") is True,
                    "snapshot deletion did not succeed")
            order = [item[0] if item[0] != "exec" else object_json(item[1]["stdout"])["action"]
                     for item in controls]
            lifecycle_order = [command for command in order
                               if command in {"write", "stop", "snapshot", "start", "mutate",
                                              "restore-snapshot", "delete-snapshot"}]
            require(lifecycle_order == ["write", "stop", "snapshot", "start", "mutate", "stop",
                                        "restore-snapshot", "start", "delete-snapshot"],
                    "snapshot/byte mutation/recovery ran out of order")
            before, after = record.get("beforeBootID"), record.get("afterBootID")
            require(canonical_uuid(before) and canonical_uuid(after) and before != after
                    and all(any(item.get("bootID") == value for item in observations)
                            for value in (before, after)), "recovery did not reach a fresh guest boot")
            statuses = [item[1] for item in controls if item[0] == "status"]
            require(bool(statuses) and len(windows) == 2, "recovery runtime/display evidence is missing")
            check_status(statuses[-1], machine, network="shared-nat",
                         architecture=architecture, graphics_backend=graphics_backend)
            recovery_windows = [item for item in windows
                                if item.get("operationID") == statuses[-1]["runtimeGraphicsSelection"]["operationID"]]
            require(len(recovery_windows) == 1, "recovery did not reacquire its own fresh window")
            check_window(recovery_windows[0], statuses[-1], machine, service)
            snapshot_plan = dictionary(snapshots[0].get("runtimeIdentity"), "snapshot runtime identity").get("planSHA256")
            require(sha256_value(snapshot_plan)
                    and statuses[-1]["runtimeIdentity"]["planSHA256"] != snapshot_plan,
                    "recovered launch reused the snapshot plan")
    return nonce


def verify_readiness(evidence, machine, service, app, *, architecture="arm64", graphics_backend="virgl-venus"):
    record = evidence.read("desktop-lifecycle-readiness.json")
    binding = profile_binding(evidence, machine, service, app, architecture, graphics_backend)
    require(record.get("kind") == "dev.dory.installed-desktop-lifecycle-readiness"
            and record.get("schemaVersion") == 1 and record.get("status") == "implemented-phases-passed"
            and record.get("machine") == machine and record.get("machService") == service
            and record.get("releaseEligible") is False and record.get("sourceSHA256") == source_hashes(architecture)
            and all(record.get(key) == value for key, value in binding.items()),
            "lifecycle readiness/source/ISA/candidate authority mismatch")
    names = [phase + ".json" for phase in JOURNEY_PHASES]
    require(record.get("references") == evidence.references(names), "lifecycle phase bundle changed")
    nonce = verify_journey(evidence, machine, service, app, architecture=architecture, graphics_backend=graphics_backend)
    require(record.get("nonce") == nonce, "lifecycle readiness belongs to another journey")
    if (evidence.directory / "desktop-lifecycle-control-timings.json").exists():
        verify_control_timing_summary(evidence, machine, service, app, architecture=architecture,
                                     graphics_backend=graphics_backend, expected_nonce=nonce)
    storage = evidence.read("storage-recovery.json")
    statuses = [object_json(raw["stdout"]) for name in sorted(storage["references"])
                if (raw := evidence.read(name)).get("argv", [None] * 7)[6] == "status"]
    final = statuses[-1]
    graphics = final["runtimeGraphicsSelection"]
    return {"status": "evidence-verified", "machineID": machine, "nonce": nonce, "guestArchitecture": architecture,
            "runtimeGraphicsBackend": graphics_backend, "bootID": storage["afterBootID"],
            "operationID": graphics["operationID"], "resolvedPlanSHA256": final["runtimeIdentity"]["planSHA256"],
            "rendererGeneration": graphics["rendererGeneration"],
            "rendererWorkerReceiptSHA256": graphics["rendererWorkerReceiptSHA256"],
            "releaseEligible": False, "storageFaultInjectionVerified": False}


def validate_target(app, service, machine, directory, timeout, *, require_fresh_lifecycle=True, architecture="arm64"):
    require(app.is_absolute() and app.name == "Dory.app" and app.is_dir() and not app.is_symlink()
            and app.resolve() == app,
            "expected the direct signed Dory.app bundle")
    require(architecture in {"arm64", "x86_64"}, "unsupported campaign architecture")
    prefix, endpoint = ("readiness-arm-ubuntu-", "dev.dory.readiness.armubuntu.") if architecture == "arm64" \
        else ("wave0-pc-gpu-", "dev.dory.wave0.pcgpu.")
    require(re.fullmatch(re.escape(prefix) + r"[a-zA-Z0-9-]+", machine) is not None
            and service == endpoint + machine.removeprefix(prefix),
            "campaign service and machine do not share one run ID")
    require(directory.is_absolute() and directory.is_dir() and not directory.is_symlink()
            and directory.resolve() == directory, "evidence directory is not direct and normalized")
    require(1 <= timeout <= 7200, "deadline must be 1...7200 seconds")
    for path in (app / "Contents/Helpers/dorydctl", app / "Contents/MacOS/Dory"):
        require(path.is_file() and not path.is_symlink() and os.access(path, os.X_OK),
                "signed application helper/executable is unavailable")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True,
                   capture_output=True, timeout=30)
    details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)], check=True,
                             capture_output=True, text=True, timeout=30).stderr.splitlines()
    require("Identifier=com.pythonxi.Dory" in details and "TeamIdentifier=864H636QW4" in details
            and any(line.startswith("Authority=Developer ID Application:") for line in details),
            "application does not have the required Developer ID identity")
    require(not require_fresh_lifecycle or (not any(directory.glob("lifecycle-*"))
            and all(not (directory / name).exists() and not (directory / name).is_symlink()
                    for name in ("installer-reboot.json", "cold-offline-reopen.json", "cold-reopen.json",
                                 "guest-reboot.json", "package-update.json", "storage-recovery.json",
                                 "desktop-lifecycle-readiness.json", "desktop-lifecycle-failure.json",
                                 "desktop-lifecycle-control-timings.json"))),
            "refusing to reuse lifecycle output")


def validate_login_input(path, machine):
    require(path.is_absolute() and path.is_file() and not path.is_symlink()
            and path.resolve() == path and path.stat().st_size <= 1024 * 1024,
            "login input is not a bounded direct file")
    script = object_json(path.read_text(encoding="utf-8"))
    require(script.get("kind") == "dev.dory.display-qualification-keyboard-script"
            and script.get("schemaVersion") == 1 and script.get("machineID") == machine,
            "login script does not bind the campaign machine")
    steps = script.get("steps")
    require(isinstance(steps, list) and 1 <= len(steps) <= 1024, "login script has no bounded steps")
    pressed = set()
    total_delay = 0
    for step in steps:
        require(isinstance(step, dict), "invalid login step")
        delay = step.get("delayMilliseconds")
        events = step.get("events")
        require(type(delay) is int and 0 <= delay <= 300000
                and isinstance(events, list) and 1 <= len(events) <= 64, "unbounded login step")
        total_delay += delay
        require(total_delay <= 7200000, "login script exceeds the maximum operation deadline")
        for event in events:
            require(isinstance(event, dict) and event.get("type") == 1
                    and type(event.get("code")) is int and 1 <= event["code"] <= 255
                    and type(event.get("value")) is int and event["value"] in {0, 1, 2},
                    "invalid login keyboard event")
            code, value = event["code"], event["value"]
            if value == 1:
                require(code not in pressed, "duplicate login key press")
                pressed.add(code)
            elif value == 0:
                require(code in pressed, "login key release has no press")
                pressed.remove(code)
            else:
                require(code in pressed, "login key repeat has no press")
    require(not pressed, "login script leaves pressed keys behind")


def bind_pc_login_template(source, destination, machine, service):
    prefix = "wave0-pc-gpu-"
    require(re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9-]+", machine) is not None
            and service == "dev.dory.wave0.pcgpu." + machine.removeprefix(prefix),
            "PC login binding requires the exact isolated PC campaign")
    data = direct_bytes(source, 1024 * 1024)
    body = object_json(data.decode())
    original_machine = body.get("machineID")
    require(original_machine in {machine, "wave0-pc-gpu-TEMPLATE"},
            "PC login input belongs to another machine; only an explicit PC TEMPLATE can be rebound")
    validate_login_input(source, original_machine)
    require(data == direct_bytes(source, 1024 * 1024), "PC login input changed during validation")
    require(destination.is_absolute() and destination.parent.resolve() == destination.parent
            and not destination.parent.is_symlink(), "PC login destination is indirect")
    body["machineID"] = machine
    Evidence(destination.parent).write(destination.name, body)
    validate_login_input(destination, machine)
    return destination


def main(architecture="arm64"):
    pc = architecture == "x86_64"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--login-input-script", type=Path,
                        help="Separate balanced keyboard script for post-install graphical login")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--confirm", choices=["EXACT-DORY-PC-DESKTOP-LIFECYCLE" if pc else "EXACT-DORY-ARM-DESKTOP-LIFECYCLE"],
                        help="Permit reboot/update/snapshot writes to the isolated campaign machine")
    if pc:
        parser.add_argument("--gpu-profile", choices=["virgl", "venus"], default="virgl")
        parser.add_argument("--login-input-template", type=Path,
                            help="Bind only an explicit wave0-pc-gpu-TEMPLATE keyboard script to this campaign")
    args = parser.parse_args()
    backend = "virgl" if pc and args.gpu_profile == "virgl" else "virgl-venus"
    def interrupted(signum, _frame):
        raise LifecycleError(f"campaign interrupted by signal {signum}")
    previous_handlers = {signum: signal.signal(signum, interrupted)
                         for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        evidence = Evidence(args.run_directory)
        if args.verify_only:
            print(json.dumps(verify_readiness(evidence, args.machine, args.mach_service, args.app,
                                              architecture=architecture, graphics_backend=backend), sort_keys=True))
            return 0
        require(args.confirm is not None, "live lifecycle writes require the exact ISA-specific confirmation")
        validate_target(args.app, args.mach_service, args.machine, args.run_directory, args.timeout_seconds,
                        architecture=architecture)
        if pc and args.login_input_template is not None:
            require(args.login_input_script is None, "choose a bound login script or a PC template, not both")
            profile_binding(evidence, args.machine, args.mach_service, args.app, architecture, backend)
            args.login_input_script = bind_pc_login_template(args.login_input_template,
                args.run_directory / "desktop-lifecycle-login-input.json", args.machine, args.mach_service)
        if args.login_input_script is not None:
            validate_login_input(args.login_input_script, args.machine)
        campaign = Campaign(args.app, args.mach_service, args.machine, evidence, args.timeout_seconds,
                            secrets.token_hex(16), args.login_input_script,
                            architecture=architecture, graphics_backend=backend)
        try:
            verdict = run_journey(campaign)
            campaign.write_control_timing_summary()
            print(json.dumps(verdict, sort_keys=True))
        except (LifecycleError, OSError, subprocess.SubprocessError) as error:
            evidence.write("desktop-lifecycle-failure.json", {
                "kind": "dev.dory.installed-desktop-lifecycle-failure", "schemaVersion": 1,
                "status": "FAIL", "machine": args.machine, "machService": args.mach_service,
                "nonce": campaign.nonce, "detail": str(error), "releaseEligible": False,
            })
            # Retain unsuccessful readiness polls and original timeouts even if the journey
            # fails. A summary failure must not replace the original campaign failure.
            if not (evidence.directory / "desktop-lifecycle-control-timings.json").exists():
                try:
                    campaign.write_control_timing_summary()
                except (LifecycleError, OSError) as timing_error:
                    print(f"control timing summary unavailable: {timing_error}", file=sys.stderr)
            raise
    except (LifecycleError, OSError, subprocess.SubprocessError) as error:
        print(("pc" if pc else "arm") + f"-ubuntu-desktop-lifecycle: {error}", file=sys.stderr)
        return 2
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    return 0


if __name__ == "__main__":
    sys.exit(main())
