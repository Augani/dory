#!/usr/bin/env python3
"""Stock Ubuntu Desktop PC installation through the signed app's real input/display path.

The frozen keyboard plan supplies focus/account choices, not custom images or recognition
rules. Each required interactive screen is independently recognized from retained guest
pixels. Normal daemon transactions cold-boot the installed disk with the signed tools ISO;
the generated offline installer command is followed by exact ISO/package and EFI-root
observations through the real guest agent. No screenshot alone promotes a release cell.
"""
import argparse
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

SPEC = importlib.util.spec_from_file_location("pc_installer_navigation", Path(__file__).with_name("arm-ubuntu-installer-navigation.py"))
navigation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(navigation)
lifecycle = navigation.lifecycle
require = lifecycle.require
ROOT = Path(__file__).resolve().parents[1]
KIND = "dev.dory.pc-ubuntu-desktop-installer"
PROOF = "pc-desktop-installation.json"
MEDIA_ID = "ubuntu-desktop-24.04.4-x86_64"
MEDIA_SHA256 = "3a4c9877b483ab46d7c3fbe165a0db275e1ae3cfe56a5657e5a47c2f99a99d1e"
INSTALL_STAGES = ("uefi-menu", "uefi-boot-manager", "grub-menu", "grub-edit", "grub-challenge",
                  "language", "accessibility", "keyboard", "network", "installation-choice",
                  "interactive-installation", "applications", "third-party", "disk-setup",
                  "account", "timezone", "review", "install-complete")
DISK_STAGES = ("installed-login", "installed-desktop", "tools-terminal")
STAGES = INSTALL_STAGES + DISK_STAGES


def sources():
    paths = (Path(__file__), Path(navigation.__file__), Path(lifecycle.__file__), navigation.OCR_SOURCE)
    return {str(path.relative_to(ROOT)): lifecycle.digest(lifecycle.direct_bytes(path)) for path in paths}


def media_digest(path):
    """Stream large optical media without following links or buffering the image in RAM."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 16 * 1024**3, "invalid optical image")
        sha, count = hashlib.sha256(), 0
        while chunk := source.read(1024 * 1024):
            sha.update(chunk)
            count += len(chunk)
            require(count <= before.st_size, "optical image grew during hashing")
        after = os.fstat(source.fileno())
        require(count == before.st_size and (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), "optical image changed during hashing")
        return {"sha256": sha.hexdigest(), "byteCount": count}


def check_media(media):
    require(isinstance(media, dict) and set(media) == {"installer", "tools"}
            and all(isinstance(item, dict) and set(item) == {"sha256", "byteCount"}
                    and lifecycle.sha256_value(item["sha256"]) and type(item["byteCount"]) is int
                    and 0 < item["byteCount"] <= 16 * 1024**3 for item in media.values())
            and media["installer"]["sha256"] == MEDIA_SHA256, "not the frozen stock Ubuntu Desktop x86 installer/tools bytes")


def ascii_steps(text):
    codes = dict(zip("qwertyuiop", range(16, 26)))
    codes.update(zip("asdfghjkl", range(30, 39)))
    codes.update(zip("zxcvbnm", range(44, 51)))
    codes.update(zip("1234567890", range(2, 12)))
    codes.update({" ": 57, "-": 12, "=": 13, "[": 26, "]": 27, ";": 39,
                  "'": 40, "`": 41, "\\": 43, ",": 51, ".": 52, "/": 53})
    shifted = dict(zip("!@#$%^&*()_+{}:\"~|<>?", "1234567890-=[];'`\\,./"))
    steps = []
    for letter in text:
        key = letter.lower() if letter.isupper() else shifted.get(letter, letter)
        require(key in codes, "generated command is not representable on the frozen US evdev layout")
        steps.append({"delayMilliseconds": 20, "events": navigation.press(*([42] if letter.isupper() or letter in shifted else []), codes[key])})
    return steps


def tools_command(nonce):
    require(re.fullmatch(r"[0-9a-f]{32}", nonce) is not None, "invalid installation nonce")
    mount = "/mnt/dory-tools-" + nonce
    # Only the selected VM is touched. The ISO's existing signed offline installer owns
    # repository verification and native package/service transactions; no curl or custom Mesa.
    return "sudo /bin/sh -ec 'mkdir " + mount + "; mount -o ro /dev/disk/by-label/DORY_TOOLS " + mount + "; /bin/sh " + mount + "/install.sh install; printf \"DORY-TOOLS-READY " + nonce + "\\n\"'"


def script_for(stage, item, machine, nonce):
    if stage == "grub-challenge":
        # Stock desktop media normally logs to the framebuffer only; make the fresh
        # kernel command-line witness observable on the PC's UART as well.
        steps = navigation.challenge_steps(nonce) + ascii_steps(" console=ttyS0,115200 console=tty0 ignore_loglevel")
    elif stage == "language":
        steps = [{"delayMilliseconds": 0, "events": navigation.press(29, 45)}]
    elif stage == "tools-terminal":
        steps = item["steps"] + ascii_steps(tools_command(nonce)) + [
            {"delayMilliseconds": 0, "events": navigation.press(28)}] + item["authenticationSteps"]
    else:
        steps = item["steps"]
    return {"kind": "dev.dory.display-qualification-keyboard-script", "schemaVersion": 1,
            "machineID": machine, "steps": steps}


def validate_plan(plan, machine):
    require(isinstance(plan, dict) and set(plan) == {"kind", "schemaVersion", "machineID", "stages"}
            and plan["kind"] == KIND + "-plan" and type(plan["schemaVersion"]) is int
            and plan["schemaVersion"] == 1 and plan["machineID"] == machine, "installer plan does not bind this machine")
    items = plan["stages"]
    require(isinstance(items, list) and len(items) == len(STAGES), "full interactive installation checkpoints are required")
    delay, events = 0, 0
    for stage, item in zip(STAGES, items):
        keys = {"stage", "captureDelayMilliseconds"}
        if stage not in {"grub-challenge", "language"}: keys.add("steps")
        if stage == "tools-terminal": keys.add("authenticationSteps")
        require(isinstance(item, dict) and set(item) == keys and item["stage"] == stage,
                "installer checkpoint is missing, reordered or caller-defined")
        for field in ("steps", "authenticationSteps"):
            if field in keys:
                require(isinstance(item[field], list) and 1 <= len(item[field]) <= 1024,
                        "installer checkpoint has no bounded keyboard frames")
        require(type(item["captureDelayMilliseconds"]) is int and 0 <= item["captureDelayMilliseconds"] <= 300000,
                "unbounded installer capture delay")
        script = script_for(stage, item, machine, "0" * 32)
        navigation.validate_keyboard(script, machine)
        delay += item["captureDelayMilliseconds"] + sum(step["delayMilliseconds"] for step in script["steps"])
        events += sum(len(step["events"]) for step in script["steps"])
        required = {"uefi-menu": 1, "uefi-boot-manager": 28, "grub-menu": 28, "grub-edit": 18}.get(stage)
        require(required is None or any(event["code"] == required and event["value"] == 1
                for step in script["steps"] for event in step["events"]), "missing required boot navigation input")
    require(delay <= 7200000 and events <= 32768, "full installer plan exceeds bounded campaign work")
    return items


def bind_plan(source, evidence, machine, service):
    # Only an explicit PC template may be rebound; an existing VM's plan never is.
    require(re.fullmatch(r"wave0-pc-gpu-[A-Za-z0-9-]+", machine) is not None
            and service == "dev.dory.wave0.pcgpu." + machine.removeprefix("wave0-pc-gpu-"),
            "installer plan binding requires the exact isolated PC endpoint")
    data = lifecycle.direct_bytes(source, 1024 * 1024)
    plan = lifecycle.object_json(data.decode())
    require(plan.get("machineID") in {machine, "wave0-pc-gpu-TEMPLATE"}, "installer input belongs to another machine")
    plan["machineID"] = machine
    validate_plan(plan, machine)
    return plan


def check_screen(observation, stage, nonce, image_hash, frame):
    text = navigation.recognized_text(observation, image_hash, frame)
    tests = {
        "uefi-menu": "boot manager" in text and ("device manager" in text or "boot maintenance manager" in text),
        "uefi-boot-manager": "boot manager" in text and any(word in text for word in ("uefi", "ubuntu", "dvd", "virtio")),
        "grub-menu": "gnu grub" in text and "try or install ubuntu" in text and "ubuntu server" not in text,
        "grub-edit": "setparams" in text and "linux" in text and "/casper/vmlinuz" in text and "ubuntu server" not in text,
        "grub-challenge": "linux" in text and "/casper/vmlinuz" in text and navigation.SUFFIX + nonce in text,
        "language": "ubuntu" in text and "english" in text and any(word in text for word in ("welcome", "language")),
        "accessibility": "accessibility" in text and any(word in text for word in ("vision", "hearing", "typing")),
        "keyboard": "keyboard" in text and "layout" in text,
        "network": any(word in text for word in ("connect to the internet", "internet connection")),
        "installation-choice": "install ubuntu" in text and "try ubuntu" in text,
        "interactive-installation": "interactive installation" in text and "automated installation" in text,
        "applications": "default selection" in text and "extended selection" in text,
        "third-party": "third-party" in text and any(word in text for word in ("software", "drivers")),
        "disk-setup": "erase disk" in text and "install ubuntu" in text and "manual installation" in text,
        "account": "password" in text and any(word in text for word in ("create your account", "your name")),
        "timezone": "timezone" in text or "time zone" in text,
        "review": "review" in text and "install" in text and any(word in text for word in ("disk", "partition")),
        "install-complete": "installation complete" in text and "restart" in text,
        "installed-login": "password" in text and "install ubuntu" not in text,
        # The plan opens GNOME Settings' system-details view after login. GNOME 46's
        # overview button is an icon, so do not require an obsolete Activities label.
        "installed-desktop": "ubuntu 24.04" in text and "os name" in text
                             and ("gnome" in text or "windowing system" in text) and "install ubuntu" not in text,
        "tools-terminal": "dory-tools-ready " + nonce in text,
    }
    require(tests.get(stage) is True, f"stock PC desktop pixels do not prove {stage}")


TOOLS_SOURCE = r'''
import hashlib, json, subprocess
from pathlib import Path
mount = Path('/mnt/dory-tools-' + nonce)
remaining = tools_size
sha = hashlib.sha256()
with open('/dev/disk/by-label/DORY_TOOLS', 'rb', buffering=0) as disc:
    while remaining:
        chunk = disc.read(min(1024 * 1024, remaining))
        if not chunk:
            raise RuntimeError('short tools ISO')
        sha.update(chunk)
        remaining -= len(chunk)
packages = list(mount.rglob('*.deb'))
if len(packages) != 1:
    raise RuntimeError('tools ISO has no unique native Debian package')
def command(argv):
    return subprocess.check_output(argv, text=True).strip()
installed = command(['dpkg-query', '-W', '-f=${Package}\n${Status}\n${Version}\n${Architecture}', 'dory-guest-tools']).splitlines()
native = command(['dpkg-deb', '-f', str(packages[0]), 'Package', 'Version', 'Architecture']).splitlines()
print(json.dumps({'nonce': nonce, 'bootID': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                 'toolsISOSHA256': sha.hexdigest(), 'toolsISOByteCount': tools_size,
                 'package': installed[0], 'packageStatus': installed[1], 'packageVersion': installed[2],
                 'packageArchitecture': installed[3], 'nativePackageFields': native,
                 'agentActive': command(['systemctl', 'is-active', 'dory-agent.service']) == 'active',
                 'toolsInstallerSHA256': hashlib.sha256((mount / 'install.sh').read_bytes()).hexdigest()}, sort_keys=True))
'''


def tools_probe(nonce, size):
    return "nonce, tools_size = " + repr((nonce, size)) + "\n" + TOOLS_SOURCE


def check_tools(body, nonce, media, expected_boot=None):
    require(body.get("nonce") == nonce and lifecycle.canonical_uuid(body.get("bootID"))
            and (expected_boot is None or body["bootID"] == expected_boot)
            and body.get("toolsISOSHA256") == media["tools"]["sha256"]
            and body.get("toolsISOByteCount") == media["tools"]["byteCount"]
            and body.get("package") == "dory-guest-tools" and body.get("packageStatus") == "install ok installed"
            and isinstance(body.get("packageVersion"), str) and bool(body["packageVersion"])
            and body.get("packageArchitecture") == "amd64" and body.get("agentActive") is True
            and body.get("nativePackageFields") == ["Package: dory-guest-tools", "Version: " + body["packageVersion"], "Architecture: amd64"]
            and lifecycle.sha256_value(body.get("toolsInstallerSHA256")), "guest tools are not the exact attached native PC package")


def check_runtime(body, machine, backend, *, installer, tools=False, running=True):
    lifecycle.check_status(body, machine, running=running, media_absent=not installer, network="shared-nat",
                           architecture="x86_64", graphics_backend=backend)
    require(body.get("installerMediaAttached") is installer and body.get("guestToolsMediaAttached") is tools,
            "daemon retained the wrong optical media phase")


def run_installation(campaign, plan, media, recognize):
    evidence = campaign.evidence
    binding = lifecycle.profile_binding(evidence, campaign.machine, campaign.service, campaign.app, "x86_64", campaign.graphics_backend)
    frozen = sources()
    check_media(media)
    items = validate_plan(plan, campaign.machine)
    names = [evidence.write("pc-installer-plan.json", plan), evidence.write("pc-installer-media.json", media)]
    before, name = campaign.ctl_call(["status", campaign.machine], "status-before")
    names.append(name)
    check_runtime(before, campaign.machine, campaign.graphics_backend, installer=True)
    console, name = campaign.ctl_call(["console", campaign.machine, "--limit", "65536"], "console-before")
    names.append(name)
    require((navigation.SUFFIX + campaign.nonce).encode() not in navigation.console_bytes(console, campaign.machine), "installation challenge is not fresh")
    def kernel_wait():
        cursor, collected = console, b""
        deadline = time.monotonic() + campaign.timeout
        for _ in range(1800):
            require(time.monotonic() < deadline, "stock installer kernel deadline expired")
            args = ["console", campaign.machine, "--limit", "65536"]
            if cursor.get("generation") is not None:
                args += ["--generation", cursor["generation"], "--after", str(cursor["nextOffset"])]
            after, name = campaign.ctl_call(args, "console-after", min(15, max(1, int(deadline - time.monotonic()))))
            names.append(name)
            chunk = navigation.console_bytes(after, campaign.machine)
            if cursor.get("generation") is not None:
                require(after.get("generation") == cursor["generation"] and after["startOffset"] == cursor["nextOffset"]
                        and after["snapshotRequired"] is False, "installer serial witness lost its generation/cursor")
            else:
                require(after["startOffset"] == 0, "first installer serial bytes were lost")
            collected += chunk
            require(len(collected) <= 1024 * 1024, "installer serial budget exceeded")
            try:
                navigation.console_witness(collected, campaign.nonce)
                return
            except lifecycle.LifecycleError:
                cursor = after
                time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        raise lifecycle.LifecycleError("installer serial sample limit exceeded")
    points = []
    runtime = before
    for item in items:
        if item["stage"] == DISK_STAGES[0]:
            final, name = campaign.ctl_call(["status", campaign.machine], "installer-final")
            names.append(name)
            check_runtime(final, campaign.machine, campaign.graphics_backend, installer=True)
            require(final["runtimeIdentity"] == before["runtimeIdentity"]
                    and final["runtimeGraphicsSelection"]["operationID"] == before["runtimeGraphicsSelection"]["operationID"],
                    "installer ownership changed before the cold disk handoff")
            for args, label in [(["stop", campaign.machine], "stop"),
                                (["update", campaign.machine, "--eject-installer"], "eject"),
                                (["update", campaign.machine, "--attach-guest-tools"], "attach-tools"),
                                (["start", campaign.machine], "start")]:
                _, name = campaign.ctl_call(args, label)
                names.append(name)
            deadline = time.monotonic() + campaign.timeout
            while True:
                require(time.monotonic() < deadline, "installed disk runtime deadline expired")
                runtime, name = campaign.ctl_call(["status", campaign.machine], "status-disk", min(15, max(1, int(deadline - time.monotonic()))))
                names.append(name)
                require(runtime.get("state") not in {"failed", "stopped", "suspended"}, "installed runtime entered terminal state")
                if runtime.get("state") == "running": break
                time.sleep(0.5)
            check_runtime(runtime, campaign.machine, campaign.graphics_backend, installer=False, tools=True)
        name = evidence.write("navigation-" + item["stage"] + "-script.json", script_for(item["stage"], item, campaign.machine, campaign.nonce))
        point = navigation.capture_checkpoint(campaign, item, name, runtime, recognize,
                                             kernel_wait if item["stage"] == "language" else None, screen_check=check_screen)
        points.append(point)
        names.extend(value for key, value in point.items() if key != "stage")
    # The same installed boot/operation must answer both independent root/GUI and tools probes.
    boot, boot_name = campaign.guest("boot")
    names.append(boot_name)
    lifecycle.check_guest(boot, "boot", campaign.nonce, "shared-nat", architecture="x86_64")
    argv = ["python3", "-c", tools_probe(campaign.nonce, media["tools"]["byteCount"])]
    transport, name = campaign.ctl_call(["exec", campaign.machine, "--json", "--timeout-ms", str(campaign.timeout * 1000),
                                       "--output-limit-bytes", "4194304", "--", *argv], "tools-probe")
    names.append(name)
    check_tools(lifecycle.check_exec(transport, campaign.machine, argv), campaign.nonce, media, boot["bootID"])
    after, name = campaign.ctl_call(["status", campaign.machine], "status-after")
    names.append(name)
    check_runtime(after, campaign.machine, campaign.graphics_backend, installer=False, tools=True)
    require(sources() == frozen and binding == lifecycle.profile_binding(evidence, campaign.machine, campaign.service,
            campaign.app, "x86_64", campaign.graphics_backend), "installer source/candidate changed during work")
    evidence.write(PROOF, {"kind": KIND, "schemaVersion": 1, "status": "PASS", "machine": campaign.machine,
                          "machService": campaign.service, "nonce": campaign.nonce, **binding, "sourceSHA256": frozen,
                          "mediaID": MEDIA_ID, "installedBootID": boot["bootID"], "releaseEligible": False,
                          "checkpoints": points, "references": reference_hashes(evidence, names)})
    return verify_installation(evidence, campaign.machine, campaign.service, campaign.app, campaign.graphics_backend, recognize)


def reference_hashes(evidence, names):
    require(len(names) == len(set(names)) and 1 <= len(names) <= 2048, "invalid installer reference set")
    result = {}
    for name in names:
        require(isinstance(name, str) and re.fullmatch(r"(?:navigation|pc-installer)-[a-z0-9.-]+", name), "unscoped installer evidence")
        result[name] = lifecycle.digest(lifecycle.direct_bytes(evidence.directory / name, 32 * 1024 * 1024))
    return result


def control(raw, app, machine, service):
    argv = raw.get("argv")
    require(isinstance(argv, list) and len(argv) >= 8 and all(isinstance(value, str) for value in argv)
            and argv[:4] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service, "--timeout"]
            and re.fullmatch(r"[1-9][0-9]{0,3}", argv[4]) and int(argv[4]) <= 7200
            and argv[5] == "machine" and argv[7] == machine and type(raw.get("returnCode")) is int
            and raw["returnCode"] == 0 and raw.get("timedOut") is False, "installer control transport is invalid")
    return argv[6:], lifecycle.object_json(raw.get("stdout")), int(argv[4])


def verify_installation(evidence, machine, service, app, backend, recognize):
    binding = lifecycle.profile_binding(evidence, machine, service, app, "x86_64", backend)
    record = evidence.read(PROOF)
    nonce = record.get("nonce")
    require(record.get("kind") == KIND and type(record.get("schemaVersion")) is int and record["schemaVersion"] == 1
            and record.get("status") == "PASS" and record.get("machine") == machine and record.get("machService") == service
            and record.get("releaseEligible") is False and record.get("sourceSHA256") == sources()
            and record.get("mediaID") == MEDIA_ID and isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce)
            and all(record.get(key) == value for key, value in binding.items()), "installer proof source/candidate/scope mismatch")
    refs = record.get("references")
    require(isinstance(refs, dict) and refs == reference_hashes(evidence, list(refs)), "installer raw bytes changed")
    require({"pc-installer-plan.json", "pc-installer-media.json"} <= set(refs), "missing frozen installer inputs")
    plan, media = evidence.read("pc-installer-plan.json"), evidence.read("pc-installer-media.json")
    items = validate_plan(plan, machine)
    check_media(media)
    names = sorted(name for name in refs if re.fullmatch(r"navigation-[0-9]{4}-[a-z-]+\.json", name))
    controls = [control(evidence.read(name), app, machine, service) for name in names]
    require(len(controls) >= 12 and [args[0] for args, _, _ in controls[:2]] == ["status", "console"], "missing installer baseline")
    before = controls[0][1]
    require(controls[0][0] == ["status", machine] and controls[1][0] == ["console", machine, "--limit", "65536"], "wrong baseline controls")
    check_runtime(before, machine, backend, installer=True)
    cursor = controls[1][1]
    require((navigation.SUFFIX + nonce).encode() not in navigation.console_bytes(cursor, machine), "installer challenge was stale")
    index, serial = 2, b""
    while index < len(controls) and controls[index][0][0] == "console":
        args, body, _ = controls[index]
        expected = ["console", machine, "--limit", "65536"]
        if cursor.get("generation") is not None:
            expected += ["--generation", cursor["generation"], "--after", str(cursor["nextOffset"])]
            require(body.get("generation") == cursor["generation"] and body.get("startOffset") == cursor["nextOffset"]
                    and body.get("snapshotRequired") is False, "installer kernel console is discontinuous")
        else: require(body.get("startOffset") == 0, "missing first kernel console bytes")
        require(args == expected, "installer serial cursor arguments changed")
        serial += navigation.console_bytes(body, machine)
        require(len(serial) <= 1024 * 1024, "installer serial replay budget exceeded")
        cursor = body
        index += 1
    navigation.console_witness(serial, nonce)
    expected = [["status", machine], ["stop", machine], ["update", machine, "--eject-installer"],
                ["update", machine, "--attach-guest-tools"], ["start", machine]]
    require([args for args, _, _ in controls[index:index + 5]] == expected, "installer media/cold boot handoff changed")
    final = controls[index][1]
    check_runtime(final, machine, backend, installer=True)
    require(final["runtimeIdentity"] == before["runtimeIdentity"]
            and final["runtimeGraphicsSelection"]["operationID"] == before["runtimeGraphicsSelection"]["operationID"], "installer ownership was replaced")
    for offset, installer, tools in ((1, True, False), (2, False, False), (3, False, True)):
        check_runtime(controls[index + offset][1], machine, backend, installer=installer, tools=tools, running=False)
    index += 5
    disk = None
    while index < len(controls) and controls[index][0][0] == "status":
        require(controls[index][0] == ["status", machine], "installed status has extra arguments")
        body = controls[index][1]
        require(body.get("id") == machine and body.get("guestArchitecture") == "x86_64"
                and body.get("state") in {"starting", "running"}, "invalid installed boot status")
        index += 1
        if body["state"] == "running":
            disk = body
            break
    require(disk is not None, "no installed runtime")
    check_runtime(disk, machine, backend, installer=False, tools=True)
    require(disk["runtimeGraphicsSelection"]["operationID"] != before["runtimeGraphicsSelection"]["operationID"]
            and disk["runtimeIdentity"]["planSHA256"] != before["runtimeIdentity"]["planSHA256"], "installed disk reused the installer operation/plan")
    require(len(controls[index:]) == 3 and [item[0][0] for item in controls[index:]] == ["exec", "exec", "status"], "missing exact installed guest witnesses")
    boot = None
    for (args, transport, timeout), argv, is_tools in zip(controls[index:index + 2],
            (["python3", "-c", lifecycle.guest_script("boot", nonce, "shared-nat")],
             ["python3", "-c", tools_probe(nonce, media["tools"]["byteCount"])]), (False, True)):
        require(len(args) == 11 and args[:4] == ["exec", machine, "--json", "--timeout-ms"]
                and re.fullmatch(r"[1-9][0-9]{0,6}", args[4]) and int(args[4]) <= timeout * 1000
                and args[5:] == ["--output-limit-bytes", "4194304", "--", *argv], "installed witness uses another command or unbounded transport")
        guest = lifecycle.check_exec(transport, machine, argv)
        if is_tools: check_tools(guest, nonce, media, boot["bootID"])
        else:
            lifecycle.check_guest(guest, "boot", nonce, "shared-nat", architecture="x86_64")
            boot = guest
    args, after, _ = controls[-1]
    require(args == ["status", machine], "final status has extra arguments")
    check_runtime(after, machine, backend, installer=False, tools=True)
    require(after["runtimeIdentity"] == disk["runtimeIdentity"]
            and after["runtimeGraphicsSelection"] == disk["runtimeGraphicsSelection"]
            and record.get("installedBootID") == boot["bootID"], "installed guest ownership changed during tools/root verification")
    points = record.get("checkpoints")
    require(isinstance(points, list) and len(points) == len(STAGES), "missing installer screenshot checkpoints")
    used = {"pc-installer-plan.json", "pc-installer-media.json", *names}
    previous_frame, previous_command, hashes = 0, 0, set()
    for stage, item, point in zip(STAGES, items, points):
        runtime = before if stage in INSTALL_STAGES else disk
        if stage == DISK_STAGES[0]: previous_frame, previous_command = 0, 0
        keys = {"stage", "script", "window", "input", "frame", "released", "image", "recognition"}
        require(isinstance(point, dict) and set(point) == keys and point["stage"] == stage, "installer checkpoint was transplanted/reordered")
        for key in keys - {"stage"}:
            name = "navigation-" + stage + (".png" if key == "image" else "-" + ("ocr" if key == "recognition" else key) + ".json")
            require(point[key] == name and name in refs, "checkpoint artifact is missing/aliased")
            used.add(name)
        script, window, frame = (evidence.read(point[key]) for key in ("script", "window", "frame"))
        require(script == script_for(stage, item, machine, nonce), "installer input differs from frozen plan/generated command")
        for displayed in (window, frame): lifecycle.check_window(displayed, runtime, machine, service, window.get("processID"))
        keyboard = evidence.read(point["input"])
        navigation.check_input(keyboard, {"body": script, "sha256": refs[point["script"]]}, machine, service,
                               runtime["runtimeGraphicsSelection"]["operationID"], window["processID"])
        require(keyboard["firstCommandSequence"] > previous_command and frame.get("framePollingHeldForCapture") is True
                and frame["windowNumber"] == window["windowNumber"] and frame["frameSequence"] > previous_frame
                and frame["frameSequence"] > window["frameSequence"]
                and frame["metalCommandBufferCompletionID"] > window["metalCommandBufferCompletionID"], "installer checkpoint input/frame is not fresh")
        previous_command, previous_frame = keyboard["lastCommandSequence"], frame["frameSequence"]
        require(evidence.read(point["released"]) == {"stage": stage, "nonce": nonce}, "installer capture was not released")
        image_hash = lifecycle.digest(navigation.png_bytes(evidence, point["image"]))
        require(image_hash not in hashes, "installer copied an earlier screenshot")
        hashes.add(image_hash)
        retained = evidence.read(point["recognition"])
        replay = recognize(evidence, point["image"], point["frame"])
        for observation in (retained, replay): check_screen(observation, stage, nonce, image_hash, frame)
        require(retained == replay, "installer OCR was not reproduced from retained viewport pixels")
    require(used == set(refs), "installer proof has unused or unscoped evidence")
    graphics = after["runtimeGraphicsSelection"]
    return {"status": "evidence-verified", "machineID": machine, "guestArchitecture": "x86_64", "mediaID": MEDIA_ID,
            "installedBootID": boot["bootID"], "operationID": graphics["operationID"],
            "resolvedPlanSHA256": after["runtimeIdentity"]["planSHA256"], "rendererGeneration": graphics["rendererGeneration"],
            "rendererWorkerReceiptSHA256": graphics["rendererWorkerReceiptSHA256"], "releaseEligible": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--gpu-profile", choices=("virgl", "venus"), default="virgl")
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--installer-plan", type=Path)
    parser.add_argument("--installer-media", type=Path)
    parser.add_argument("--tools-iso", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--confirm", choices=("EXACT-DORY-PC-DESKTOP-INSTALL",))
    args = parser.parse_args()
    backend = "virgl" if args.gpu_profile == "virgl" else "virgl-venus"
    def interrupted(signum, _): raise lifecycle.LifecycleError(f"installer interrupted by signal {signum}")
    handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        if not args.verify_only:
            require(args.confirm is not None, "live installation requires --confirm EXACT-DORY-PC-DESKTOP-INSTALL")
        evidence = lifecycle.Evidence(args.run_directory)
        lifecycle.profile_binding(evidence, args.machine, args.mach_service, args.app, "x86_64", backend)
        if not args.verify_only:
            require(args.installer_plan is not None and args.installer_media is not None and args.tools_iso is not None, "installation requires frozen plan, stock media and native tools ISO")
            lifecycle.validate_target(args.app, args.mach_service, args.machine, args.run_directory, args.timeout_seconds,
                                      architecture="x86_64", require_fresh_lifecycle=False)
            require(not any(path.name.startswith(("navigation-", "pc-installer-")) or path.name == PROOF
                            for path in args.run_directory.iterdir()), "refusing to reuse installer evidence")
            media = {"installer": media_digest(args.installer_media), "tools": media_digest(args.tools_iso)}
            check_media(media)
            plan = bind_plan(args.installer_plan, evidence, args.machine, args.mach_service)
            campaign = lifecycle.Campaign(args.app, args.mach_service, args.machine, evidence, args.timeout_seconds,
                                          secrets.token_hex(16), record_prefix="navigation", architecture="x86_64", graphics_backend=backend)
        with navigation.Recognizer() as recognize:
            verdict = (verify_installation(evidence, args.machine, args.mach_service, args.app, backend, recognize)
                       if args.verify_only else run_installation(campaign, plan, media, recognize))
        print(json.dumps(verdict, sort_keys=True))
        return 0
    except (lifecycle.LifecycleError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"pc-ubuntu-installer: {error}", file=sys.stderr)
        return 2
    finally:
        for signum, handler in handlers.items(): signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
