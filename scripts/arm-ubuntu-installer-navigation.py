#!/usr/bin/env python3
"""Checkpoint real UEFI/GRUB keyboard navigation in an isolated signed ARM campaign.

This phase ends at the stock installer's language screen. It neither installs a custom
image nor claims the later installed-disk journey. Replay recognizes the retained PNGs
again and requires the freshly typed GRUB nonce in Linux's actual kernel command line.
"""
import argparse
import base64
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location("navigation_lifecycle", Path(__file__).with_name("arm-ubuntu-desktop-lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
require = lifecycle.require
STAGES = ("uefi-menu", "uefi-boot-manager", "grub-menu", "grub-edit", "grub-challenge", "installer")
OCR_SOURCE = Path(__file__).with_name("arm-ubuntu-navigation-ocr.swift")
KIND = "dev.dory.arm-ubuntu-installer-navigation"
SUFFIX = "dory.navigation="


def scope(machine, service):
    require(re.fullmatch(r"readiness-arm-ubuntu-[a-zA-Z0-9-]+", machine) is not None
            and service == "dev.dory.readiness.armubuntu." + machine.removeprefix("readiness-arm-ubuntu-"),
            "navigation is restricted to one isolated campaign machine/service")


def press(*codes):
    return [{"type": 1, "code": code, "value": 1} for code in codes] + [
        {"type": 1, "code": code, "value": 0} for code in reversed(codes)]


def challenge_steps(nonce):
    require(re.fullmatch(r"[0-9a-f]{32}", nonce) is not None, "invalid navigation nonce")
    # US evdev layout; each frame releases its keys. The plan must position the GRUB cursor
    # on the linux line. If it does not, Linux's serial command-line witness cannot pass.
    codes = dict(zip("qwertyuiop", range(16, 26)))
    codes.update(zip("asdfghjkl", range(30, 39)))
    codes.update(zip("zxcvbnm", range(44, 51)))
    codes.update(zip("1234567890", range(2, 12)))
    codes.update({" ": 57, ".": 52, "=": 13})
    return [{"delayMilliseconds": 0, "events": press(107)}] + [
        {"delayMilliseconds": 20, "events": press(codes[letter])} for letter in " " + SUFFIX + nonce]


def script_for(stage, plan, machine, nonce):
    if stage == "grub-challenge":
        steps = challenge_steps(nonce)
    elif stage == "installer":
        steps = [{"delayMilliseconds": 0, "events": press(29, 45)}]  # Ctrl-X: boot edited GRUB entry
    else:
        steps = plan["steps"]
    return {"kind": "dev.dory.display-qualification-keyboard-script", "schemaVersion": 1,
            "machineID": machine, "steps": steps}


def validate_keyboard(script, machine):
    require(set(script) == {"kind", "schemaVersion", "machineID", "steps"}
            and script["kind"] == "dev.dory.display-qualification-keyboard-script"
            and type(script["schemaVersion"]) is int and script["schemaVersion"] == 1
            and script["machineID"] == machine, "keyboard script does not bind this campaign machine")
    steps = script["steps"]
    require(isinstance(steps, list) and 1 <= len(steps) <= 1024, "unbounded keyboard script")
    total_delay, total_events = 0, 0
    for step in steps:
        require(isinstance(step, dict) and set(step) == {"delayMilliseconds", "events"}
                and type(step["delayMilliseconds"]) is int and 0 <= step["delayMilliseconds"] <= 300000
                and isinstance(step["events"], list) and 1 <= len(step["events"]) <= 64,
                "invalid keyboard frame")
        total_delay += step["delayMilliseconds"]
        total_events += len(step["events"])
        held = set()
        for event in step["events"]:
            require(isinstance(event, dict) and set(event) == {"type", "code", "value"}
                    and type(event["type"]) is int and event["type"] == 1
                    and type(event["code"]) is int and 1 <= event["code"] <= 255
                    and type(event["value"]) is int and event["value"] in {0, 1, 2}, "invalid keyboard event")
            code, value = event["code"], event["value"]
            if value == 1:
                require(code not in held, "duplicate keyboard press")
                held.add(code)
            elif value == 0:
                require(code in held, "unpaired keyboard release")
                held.remove(code)
            else:
                require(code in held, "unpaired keyboard repeat")
        require(not held, "keyboard frame leaves a key held")
    require(total_delay <= 7200000 and total_events <= 8192, "keyboard script exceeds campaign bounds")


def bind_input(source, destination, machine, service, role):
    """Materialize an explicit template; never rebind a plan for a different live machine."""
    scope(machine, service)
    require(role in {"navigation", "installer", "login"}, "unknown campaign input role")
    require(source.is_file() and not source.is_symlink() and 0 < source.stat().st_size <= 256 * 1024,
            "campaign input source is not a bounded direct file")
    data = source.read_bytes()
    body = lifecycle.object_json(data.decode("utf-8"))
    require(body.get("machineID") in {machine, "readiness-arm-ubuntu-TEMPLATE"},
            "input is for another machine; only an explicit TEMPLATE may be materialized")
    body["machineID"] = machine
    if role == "navigation":
        validate_plan(body, machine)
    else:
        validate_keyboard(body, machine)
    encoded = (json.dumps(body, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    require(len(encoded) <= 256 * 1024, "materialized input exceeds the app's encoding limit")
    require(destination.is_absolute() and destination.parent.is_dir() and not destination.parent.is_symlink()
            and destination.parent.resolve() == destination.parent, "input destination is not an exact owned campaign directory")
    require(source.resolve() != destination, "cannot replace the input source")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as target:
        target.write(encoded)
        target.flush()
        os.fsync(target.fileno())
    return {"kind": "dev.dory.campaign-input-binding", "schemaVersion": 1, "machineID": machine,
            "machServiceName": service, "role": role, "sourceSHA256": lifecycle.digest(data),
            "materializedSHA256": lifecycle.digest(encoded), "releaseEligible": False}


def validate_plan(plan, machine):
    require(set(plan) == {"kind", "schemaVersion", "machineID", "stages"}
            and plan["kind"] == KIND + "-plan" and plan["schemaVersion"] == 1
            and plan["machineID"] == machine, "navigation plan does not bind the machine")
    stages = plan["stages"]
    require(isinstance(stages, list) and len(stages) == len(STAGES), "navigation plan must contain all six checkpoints")
    total_delay, total_events = 0, 0
    for expected, item in zip(STAGES, stages):
        keys = {"stage", "captureDelayMilliseconds"} | ({"steps"} if expected in STAGES[:4] else set())
        require(isinstance(item, dict) and set(item) == keys and item["stage"] == expected,
                "navigation checkpoints are missing, reordered or caller-generated")
        delay = item["captureDelayMilliseconds"]
        require(type(delay) is int and 0 <= delay <= 300000, "unbounded checkpoint capture delay")
        total_delay += delay
        steps = script_for(expected, item, machine, "0" * 32)["steps"]
        require(isinstance(steps, list) and 1 <= len(steps) <= 1024, "unbounded checkpoint input")
        required_key = {"uefi-menu": 1, "uefi-boot-manager": 28, "grub-menu": 28, "grub-edit": 18}.get(expected)
        delivered = set()
        for step in steps:
            require(isinstance(step, dict) and set(step) == {"delayMilliseconds", "events"}
                    and type(step["delayMilliseconds"]) is int and 0 <= step["delayMilliseconds"] <= 300000
                    and isinstance(step["events"], list) and 1 <= len(step["events"]) <= 64,
                    "invalid keyboard frame")
            total_delay += step["delayMilliseconds"]
            total_events += len(step["events"])
            held = set()
            for event in step["events"]:
                require(isinstance(event, dict) and set(event) == {"type", "code", "value"}
                        and type(event["type"]) is int and event["type"] == 1
                        and type(event["code"]) is int and 1 <= event["code"] <= 255
                        and type(event["value"]) is int and event["value"] in {0, 1, 2}, "not a bounded evdev keyboard event")
                code, value = event["code"], event["value"]
                if value == 1:
                    require(code not in held, "duplicate key press")
                    held.add(code)
                    delivered.add(code)
                elif value == 0:
                    require(code in held, "unpaired key release")
                    held.remove(code)
                else:
                    require(code in held, "unpaired key repeat")
            require(not held, "checkpoint leaves a key held")
        require(required_key is None or required_key in delivered, "checkpoint has no required navigation key")
    require(total_delay <= 7200000 and total_events <= 8192, "navigation plan exceeds campaign bounds")
    return stages


def png_bytes(evidence, name):
    require(re.fullmatch(r"navigation-[a-z-]+\.png", name) is not None, "invalid checkpoint PNG reference")
    path = evidence.directory / name
    require(path.is_file() and not path.is_symlink() and 24 <= path.stat().st_size <= 32 * 1024 * 1024,
            "missing, indirect or unbounded checkpoint PNG")
    data = path.read_bytes()
    require(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", "checkpoint is not a PNG")
    width, height = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    require(320 <= width <= 16384 and 200 <= height <= 16384, "checkpoint PNG has invalid dimensions")
    return data


class Recognizer:
    def __enter__(self):
        require(sys.platform == "darwin", "independent navigation recognition requires macOS")
        developer = subprocess.run(["/usr/bin/xcode-select", "-p"], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
        require("RC" not in developer.upper() and "BETA" not in developer.upper(), "navigation recognition refuses a prerelease Xcode path")
        version = subprocess.run(["/usr/bin/xcodebuild", "-version"], capture_output=True, text=True, check=True, timeout=10).stdout
        require(version.strip() in {"Xcode 27.0\nBuild version 27A266a", "Xcode 26.6\nBuild version 17F113"},
                "navigation recognition requires the final qualified Xcode toolchain")
        require(OCR_SOURCE.is_file() and not OCR_SOURCE.is_symlink(), "recognizer source is indirect")
        self.source_hash = lifecycle.digest(OCR_SOURCE.read_bytes())
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-navigation-ocr-")
        self.executable = Path(self.temporary.name) / "ocr"
        try:
            subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "6", str(OCR_SOURCE),
                            "-framework", "Vision", "-framework", "ImageIO", "-o", str(self.executable)],
                           capture_output=True, check=True, timeout=60)
            require(lifecycle.digest(OCR_SOURCE.read_bytes()) == self.source_hash, "recognizer source changed during compilation")
        except BaseException:
            self.temporary.cleanup()
            raise
        return self

    def __exit__(self, *args):
        self.temporary.cleanup()

    def __call__(self, evidence, image, frame):
        png_bytes(evidence, image)
        result = subprocess.run([str(self.executable), str(evidence.directory / image), str(evidence.directory / frame)],
                                capture_output=True, text=True, check=True, timeout=30)
        body = lifecycle.object_json(result.stdout)
        require(lifecycle.digest(OCR_SOURCE.read_bytes()) == self.source_hash, "recognizer source changed during replay")
        body["recognizerSourceSHA256"] = self.source_hash
        return body


def recognized_text(observation, image_hash, window):
    require(observation.get("kind") == "dev.dory.guest-viewport-text" and observation.get("schemaVersion") == 1
            and observation.get("revision") == 3 and observation.get("framebufferSHA256") == image_hash
            and observation.get("recognizerSourceSHA256") == lifecycle.digest(OCR_SOURCE.read_bytes()),
            "checkpoint recognition does not bind retained pixels and current recognizer")
    viewport = window.get("guestViewport")
    require(isinstance(viewport, dict) and viewport.get("coordinateSpace") == "capture-pixels-top-left"
            and observation.get("cropWidth") == viewport.get("width")
            and observation.get("cropHeight") == viewport.get("height"), "recognition includes pixels outside the guest viewport")
    lines = observation.get("lines")
    require(isinstance(lines, list) and 1 <= len(lines) <= 1024, "no bounded guest text recognized")
    for line in lines:
        require(isinstance(line, dict) and isinstance(line.get("text"), str) and 1 <= len(line["text"]) <= 4096
                and type(line.get("confidence")) in {int, float} and 0.5 <= line["confidence"] <= 1
                and all(type(line.get(key)) in {int, float} and 0 <= line[key] <= 1 for key in ("x", "y", "width", "height")),
                "invalid recognized guest text region")
    return re.sub(r"\s+", " ", " ".join(line["text"] for line in lines)).lower()


def check_screen(observation, stage, nonce, image_hash, window):
    text = recognized_text(observation, image_hash, window)
    tests = {
        "uefi-menu": "boot manager" in text and ("device manager" in text or "boot maintenance manager" in text),
        "uefi-boot-manager": "boot manager" in text and any(item in text for item in ("uefi", "ubuntu", "dvd", "virtio")),
        "grub-menu": "gnu grub" in text and "try or install ubuntu server" in text,
        "grub-edit": "setparams" in text and "linux" in text and "/casper/vmlinuz" in text,
        "grub-challenge": "linux" in text and "/casper/vmlinuz" in text and SUFFIX + nonce in text,
        "installer": "welcome" in text and "english" in text and any(item in text for item in ("language", "deutsch", "français")),
    }
    require(tests.get(stage) is True, f"guest pixels do not prove the {stage} checkpoint")


def console_bytes(body, machine):
    require(body.get("schemaVersion") == 1 and body.get("machineID") == machine
            and all(type(body.get(key)) is int and 0 <= body[key] < 2**64 for key in ("startOffset", "nextOffset", "totalBytes"))
            and type(body.get("snapshotRequired")) is bool and type(body.get("inputAvailable")) is bool
            and isinstance(body.get("bytesBase64"), str), "installer console is malformed or belongs to another machine")
    try:
        data = base64.b64decode(body["bytesBase64"], validate=True)
    except ValueError as error:
        raise lifecycle.LifecycleError("invalid serial console bytes") from error
    require(len(data) <= 65536 and body["startOffset"] <= body["nextOffset"] <= body["totalBytes"]
            and body["nextOffset"] - body["startOffset"] == len(data), "serial console cursor does not bound its bytes")
    require(lifecycle.sha256_value(body.get("generation")) or (body.get("generation") is None
            and not data and body["totalBytes"] == 0), "serial console has no valid log identity")
    return data


def console_witness(data, nonce):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", data.decode("utf-8", errors="replace")).replace("\r", "")
    lines = [line for line in text.splitlines() if re.search(r"(?:^|\])\s*Kernel command line:", line)]
    require(any(SUFFIX + nonce in line.split("Kernel command line:", 1)[1].split() for line in lines),
            "fresh GRUB nonce never reached Linux's kernel command line")


def check_input(keyboard, script, machine, service, operation, pid):
    require(keyboard.get("kind") == "dev.dory.display-qualification-input" and keyboard.get("schemaVersion") == 1
            and keyboard.get("delivery") == "runner-applied" and keyboard.get("bundleIdentifier") == "com.pythonxi.Dory"
            and keyboard.get("machineID") == machine and keyboard.get("machServiceName") == service
            and keyboard.get("operationID") == operation and keyboard.get("processID") == pid
            and keyboard.get("scriptSHA256") == script["sha256"] and keyboard.get("stepCount") == len(script["body"]["steps"])
            and keyboard.get("eventCount") == sum(len(step["events"]) for step in script["body"]["steps"])
            and type(keyboard.get("firstCommandSequence")) is int and keyboard["firstCommandSequence"] > 0
            and type(keyboard.get("lastCommandSequence")) is int
            and keyboard["lastCommandSequence"] >= keyboard["firstCommandSequence"], "checkpoint input lacks current runner-applied authority")


@contextmanager
def checkpoint_app(campaign, stage, script_name):
    prefix = "navigation-" + stage
    directory = campaign.evidence.directory
    paths = {key: prefix + "-" + key + ".json" for key in ("window", "input", "frame", "request", "released")}
    env = {key: value for key, value in os.environ.items() if not key.startswith("DORY_DISPLAY_QUALIFICATION_")}
    env.update(DORYD_MACH_SERVICE=campaign.service, DORY_DISPLAY_QUALIFICATION_MACHINE_ID=campaign.machine,
               DORY_DISPLAY_QUALIFICATION_SCANOUT_ID="0", DORY_DISPLAY_QUALIFICATION_WINDOW_RECEIPT=str(directory / paths["window"]),
               DORY_DISPLAY_QUALIFICATION_INPUT_SCRIPT=str(directory / script_name), DORY_DISPLAY_QUALIFICATION_INPUT_RECEIPT=str(directory / paths["input"]),
               DORY_DISPLAY_QUALIFICATION_CAPTURE_REQUEST=str(directory / paths["request"]), DORY_DISPLAY_QUALIFICATION_CAPTURE_RECEIPT=str(directory / paths["frame"]))
    with (directory / (prefix + "-app.out")).open("xb") as output, (directory / (prefix + "-app.err")).open("xb") as error:
        process = subprocess.Popen([str(campaign.app / "Contents/MacOS/Dory")], env=env, stdout=output, stderr=error)
        try:
            yield process, paths
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def wait_file(campaign, process, name, deadline):
    path = campaign.evidence.directory / name
    while not path.exists():
        require(process.poll() is None, "checkpoint display app exited")
        require(time.monotonic() < deadline, "checkpoint display deadline expired")
        time.sleep(0.1)
    require(time.monotonic() < deadline and process.poll() is None, "checkpoint display completed after its deadline or app exit")
    return campaign.evidence.read(name)


def capture_checkpoint(campaign, item, script_name, runtime, recognize, kernel_wait=None, *, screen_check=check_screen):
    stage, evidence = item["stage"], campaign.evidence
    with checkpoint_app(campaign, stage, script_name) as (process, paths):
        deadline = time.monotonic() + campaign.timeout
        window = wait_file(campaign, process, paths["window"], deadline)
        lifecycle.check_window(window, runtime, campaign.machine, campaign.service, process.pid)
        keyboard = wait_file(campaign, process, paths["input"], deadline)
        script = evidence.read(script_name)
        check_input(keyboard, {"sha256": lifecycle.digest((evidence.directory / script_name).read_bytes()), "body": script},
                    campaign.machine, campaign.service, window["operationID"], process.pid)
        delay = item["captureDelayMilliseconds"] / 1000
        require(time.monotonic() + delay < deadline, "capture delay exceeds checkpoint deadline")
        if kernel_wait is not None:
            kernel_wait()
        require(time.monotonic() + delay < deadline, "kernel startup left no time for the checkpoint capture")
        # Signals interrupt sleep; this is bounded campaign work, not a recurring monitor.
        time.sleep(delay)
        evidence.write(paths["request"], {"stage": stage, "nonce": campaign.nonce})
        frame = wait_file(campaign, process, paths["frame"], deadline)
        lifecycle.check_window(frame, runtime, campaign.machine, campaign.service, process.pid)
        require(frame.get("framePollingHeldForCapture") is True and frame["metalCommandBufferCompletionID"] > window["metalCommandBufferCompletionID"],
                "capture was not a post-input held Metal frame")
        image = "navigation-" + stage + ".png"
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l" + str(frame["windowNumber"]), str(evidence.directory / image)],
                       capture_output=True, check=True, timeout=min(30, campaign.timeout))
        os.rename(evidence.directory / paths["request"], evidence.directory / paths["released"])
        ocr_name = "navigation-" + stage + "-ocr.json"
        recognized = recognize(evidence, image, paths["frame"])
        evidence.write(ocr_name, recognized)
        screen_check(recognized, stage, campaign.nonce, lifecycle.digest(png_bytes(evidence, image)), frame)
        return {"stage": stage, "script": script_name, **{key: paths[key] for key in ("window", "input", "frame", "released")},
                "image": image, "recognition": ocr_name}


def run_navigation(campaign, plan, recognize):
    scope(campaign.machine, campaign.service)
    stages = validate_plan(plan, campaign.machine)
    evidence = campaign.evidence
    plan_name = evidence.write("navigation-plan.json", plan)
    runtime, status_name = campaign.ctl_call(["status", campaign.machine], "status-before")
    lifecycle.check_status(runtime, campaign.machine, media_absent=False, network="shared-nat")
    require(runtime.get("installerMediaAttached") is True, "navigation is not booting the attached installer")
    before, before_name = campaign.ctl_call(["console", campaign.machine, "--limit", "65536"], "console-before")
    require((SUFFIX + campaign.nonce).encode() not in console_bytes(before, campaign.machine), "navigation nonce was already in the console")
    checkpoints = []
    names = [plan_name, status_name, before_name]
    def kernel_wait():
        cursor, collected = before, b""
        deadline = time.monotonic() + campaign.timeout
        while True:
            args = ["console", campaign.machine, "--limit", "65536"]
            if cursor.get("generation") is not None:
                args += ["--generation", cursor["generation"], "--after", str(cursor["nextOffset"])]
            after, name = campaign.ctl_call(args, "console-after", min(15, campaign.timeout))
            names.append(name)
            chunk = console_bytes(after, campaign.machine)
            if cursor.get("generation") is not None:
                require(after.get("generation") == cursor["generation"] and after["startOffset"] == cursor["nextOffset"]
                        and after["snapshotRequired"] is False, "installer console log was replaced or lost bytes")
            collected += chunk
            require(len(collected) <= 1024 * 1024, "installer console exceeded the retained navigation budget")
            try:
                console_witness(collected, campaign.nonce)
                return
            except lifecycle.LifecycleError:
                require(time.monotonic() < deadline and len(names) < 1800, "fresh GRUB nonce never reached the kernel before deadline")
                cursor = after
                time.sleep(0.5)
    for item in stages:
        script_name = evidence.write("navigation-" + item["stage"] + "-script.json", script_for(item["stage"], item, campaign.machine, campaign.nonce))
        point = capture_checkpoint(campaign, item, script_name, runtime, recognize,
                                   kernel_wait if item["stage"] == "installer" else None)
        checkpoints.append(point)
        names.extend(value for key, value in point.items() if key != "stage")
    final, final_name = campaign.ctl_call(["status", campaign.machine], "status-after")
    lifecycle.check_status(final, campaign.machine, media_absent=False, network="shared-nat")
    require(final["runtimeIdentity"] == runtime["runtimeIdentity"] and final["runtimeGraphicsSelection"]["operationID"] == runtime["runtimeGraphicsSelection"]["operationID"],
            "navigation changed host runner ownership")
    names.append(final_name)
    result = {"kind": KIND, "schemaVersion": 1, "status": "PASS", "machine": campaign.machine,
              "machService": campaign.service, "nonce": campaign.nonce, "operationID": runtime["runtimeGraphicsSelection"]["operationID"],
              "planSHA256": runtime["runtimeIdentity"]["planSHA256"], "keyboardNavigation": True,
              "kernelCommandLineChallengeObserved": True, "releaseEligible": False, "checkpoints": checkpoints,
              "references": evidence.references(names)}
    evidence.write("installer-navigation.json", result)
    return verify_navigation(evidence, campaign.machine, campaign.service, campaign.app, recognize)


def verify_navigation(evidence, machine, service, app, recognize):
    scope(machine, service)
    record = evidence.read("installer-navigation.json")
    nonce = record.get("nonce")
    require(record.get("kind") == KIND and type(record.get("schemaVersion")) is int and record["schemaVersion"] == 1 and record.get("status") == "PASS"
            and record.get("machine") == machine and record.get("machService") == service
            and record.get("releaseEligible") is False and record.get("keyboardNavigation") is True
            and record.get("kernelCommandLineChallengeObserved") is True
            and isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None,
            "navigation receipt is not a scoped challenged non-release result")
    references = record.get("references")
    require(isinstance(references, dict) and 3 <= len(references) <= 2048, "navigation has no bounded raw references")
    for name, value in references.items():
        require(isinstance(name, str) and re.fullmatch(r"navigation-[a-z0-9.-]+", name) is not None
                and lifecycle.sha256_value(value), "invalid navigation evidence reference")
        path = evidence.directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 32 * 1024 * 1024
                and lifecycle.digest(path.read_bytes()) == value, "navigation evidence bytes changed")
    require("navigation-plan.json" in references, "missing retained navigation plan")
    plan = evidence.read("navigation-plan.json")
    stages = validate_plan(plan, machine)
    points = record.get("checkpoints")
    require(isinstance(points, list) and len(points) == len(STAGES), "missing navigation checkpoints")
    control_names = sorted(name for name in references if re.fullmatch(r"navigation-[0-9]{4}-[a-z-]+\.json", name))
    controls = []
    for name in control_names:
        raw = evidence.read(name)
        argv = raw.get("argv")
        require(type(raw.get("returnCode")) is int and raw["returnCode"] == 0 and raw.get("timedOut") is False
                and isinstance(argv, list) and len(argv) >= 8 and all(isinstance(value, str) for value in argv)
                and argv[:4] == [str(app / "Contents/Helpers/dorydctl"), "--mach-service", service, "--timeout"]
                and argv[4].isdigit() and 1 <= int(argv[4]) <= 7200 and argv[5] == "machine", "invalid navigation control transport")
        args = argv[6:]
        require(args == ["status", machine] or (args[:4] == ["console", machine, "--limit", "65536"]
                and (len(args) == 4 or (len(args) == 8 and args[4] == "--generation" and lifecycle.sha256_value(args[5])
                     and args[6] == "--after" and args[7].isdigit()))), "navigation replay contains another control operation")
        controls.append((args[0], lifecycle.object_json(raw.get("stdout", "")), args))
    require(len(controls) >= 4 and [item[0] for item in controls[:2]] == ["status", "console"]
            and controls[-1][0] == "status" and all(item[0] == "console" for item in controls[2:-1]), "navigation control phases are reordered")
    before, initial_console, after = controls[0][1], controls[1][1], controls[-1][1]
    for runtime in (before, after):
        lifecycle.check_status(runtime, machine, media_absent=False, network="shared-nat")
        require(runtime.get("installerMediaAttached") is True and runtime["runtimeIdentity"]["planSHA256"] == record.get("planSHA256")
                and runtime["runtimeGraphicsSelection"]["operationID"] == record.get("operationID"), "navigation belongs to another installer operation")
    require(controls[1][2] == ["console", machine, "--limit", "65536"]
            and (SUFFIX + nonce).encode() not in console_bytes(initial_console, machine), "navigation challenge is not fresh")
    cursor, collected = initial_console, b""
    for _, body, args in controls[2:-1]:
        chunk = console_bytes(body, machine)
        if cursor.get("generation") is not None:
            require(args[4:] == ["--generation", cursor["generation"], "--after", str(cursor["nextOffset"])]
                    and body.get("generation") == cursor["generation"] and body["startOffset"] == cursor["nextOffset"]
                    and body["snapshotRequired"] is False, "serial navigation witness is discontinuous or transplanted")
        else:
            require(len(args) == 4 and body["startOffset"] == 0, "first installer serial bytes are missing")
        collected += chunk
        require(len(collected) <= 1024 * 1024, "navigation console exceeded its budget")
        cursor = body
    console_witness(collected, nonce)
    used = {"navigation-plan.json", *control_names}
    previous_frame, previous_command, hashes = 0, 0, set()
    for stage, item, point in zip(STAGES, stages, points):
        keys = {"stage", "script", "window", "input", "frame", "released", "image", "recognition"}
        require(isinstance(point, dict) and set(point) == keys and point["stage"] == stage, "checkpoint is missing or reordered")
        for key in keys - {"stage"}:
            expected = "navigation-" + stage + (".png" if key == "image" else "-" + ("ocr" if key == "recognition" else key) + ".json")
            require(point[key] == expected and expected in references, "checkpoint artifact was transplanted")
            used.add(expected)
        script = evidence.read(point["script"])
        require(script == script_for(stage, item, machine, nonce), "checkpoint input differs from retained plan or fresh generated keys")
        window, frame = evidence.read(point["window"]), evidence.read(point["frame"])
        for displayed in (window, frame):
            lifecycle.check_window(displayed, before, machine, service, window["processID"])
        keyboard = evidence.read(point["input"])
        check_input(keyboard, {"sha256": references[point["script"]], "body": script}, machine, service, record["operationID"], window["processID"])
        require(keyboard["firstCommandSequence"] > previous_command, "checkpoint input reuses an earlier runner command")
        previous_command = keyboard["lastCommandSequence"]
        require(frame.get("framePollingHeldForCapture") is True and frame["windowNumber"] == window["windowNumber"]
                and frame["metalCommandBufferCompletionID"] > window["metalCommandBufferCompletionID"]
                and frame["frameSequence"] > previous_frame, "checkpoint did not capture a fresh post-input Metal frame")
        previous_frame = frame["frameSequence"]
        require(evidence.read(point["released"]) == {"stage": stage, "nonce": nonce}, "held checkpoint capture was not released")
        image_hash = lifecycle.digest(png_bytes(evidence, point["image"]))
        require(image_hash not in hashes, "navigation copied an earlier screenshot")
        hashes.add(image_hash)
        retained = evidence.read(point["recognition"])
        check_screen(retained, stage, nonce, image_hash, frame)
        replay = recognize(evidence, point["image"], point["frame"])
        check_screen(replay, stage, nonce, image_hash, frame)
        require(retained == replay, "recognition receipt differs from independent retained-pixel replay")
    require(used == set(references), "navigation contains unused or unscoped raw evidence")
    return {"status": "evidence-verified", "machineID": machine, "operationID": record["operationID"],
            "nonce": nonce, "navigationSHA256": lifecycle.digest((evidence.directory / "installer-navigation.json").read_bytes())}


def qualification_record(evidence, machine, service, verified):
    capture = evidence.read("window-capture.json")
    require(verified.get("status") == "evidence-verified" and verified.get("machineID") == machine
            and capture.get("kind") == "dev.dory.machine-window-capture" and capture.get("schemaVersion") == 2
            and capture.get("status") == "PASS" and capture.get("machineID") == machine
            and capture.get("machServiceName") == service and capture.get("operationID") == verified["operationID"]
            and lifecycle.sha256_value(capture.get("framebufferSHA256")), "installer navigation is not joined to this scenario's captured operation")
    framebuffer = evidence.directory / "framebuffer.png"
    require(framebuffer.is_file() and not framebuffer.is_symlink() and framebuffer.stat().st_size <= 32 * 1024 * 1024
            and lifecycle.digest(framebuffer.read_bytes()) == capture["framebufferSHA256"], "scenario framebuffer bytes changed")
    require(evidence.read("installer-navigation-verification.json") == verified, "retained navigation replay differs from independent pixels")
    return {"kind": KIND + "-qualification", "schemaVersion": 1, "status": "PASS", "machine": machine,
            "machService": service, "operationID": verified["operationID"], "nonce": verified["nonce"],
            "keyboardNavigation": True, "kernelCommandLineChallengeObserved": True, "releaseEligible": False,
            "framebufferSHA256": capture["framebufferSHA256"], "references": evidence.references([
                "installer-navigation.json", "installer-navigation-verification.json", "window-capture.json"])}


def verify_qualification(evidence, machine, service, app, recognize):
    verified = verify_navigation(evidence, machine, service, app, recognize)
    require(evidence.read("uefi-grub-input.json") == qualification_record(evidence, machine, service, verified),
            "UEFI/GRUB qualification differs from independently replayed navigation")
    return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--navigation-plan", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--require-qualification", action="store_true", help="Also replay the join to the scenario framebuffer")
    parser.add_argument("--confirm", choices=["EXACT-DORY-ARM-INSTALLER-NAVIGATION"])
    args = parser.parse_args()
    previous = {}
    try:
        scope(args.machine, args.mach_service)
        require(args.run_directory.is_absolute() and args.run_directory.is_dir() and not args.run_directory.is_symlink()
                and args.run_directory.resolve() == args.run_directory, "navigation evidence root is indirect")
        require(args.app.is_absolute() and args.app.name == "Dory.app" and args.app.resolve() == args.app, "navigation replay has no exact application root")
        evidence = lifecycle.Evidence(args.run_directory)
        if not args.verify_only:
            require(args.confirm == "EXACT-DORY-ARM-INSTALLER-NAVIGATION" and args.navigation_plan is not None,
                    "navigation writes require exact confirmation and a bounded plan")
            lifecycle.validate_target(args.app, args.mach_service, args.machine, args.run_directory, args.timeout_seconds, require_fresh_lifecycle=False)
            require(not any(args.run_directory.glob("navigation-*")) and not (args.run_directory / "installer-navigation.json").exists(), "refusing to reuse navigation evidence")
            require(args.navigation_plan.is_file() and not args.navigation_plan.is_symlink() and args.navigation_plan.stat().st_size <= 256 * 1024, "navigation plan is not a bounded direct file")
            plan = lifecycle.object_json(args.navigation_plan.read_text())
            validate_plan(plan, args.machine)
            def interrupted(signum, _):
                raise lifecycle.LifecycleError(f"navigation interrupted by signal {signum}")
            previous = {number: signal.signal(number, interrupted) for number in (signal.SIGINT, signal.SIGTERM)}
        with Recognizer() as recognize:
            if args.verify_only:
                replay = verify_qualification if args.require_qualification else verify_navigation
                result = replay(evidence, args.machine, args.mach_service, args.app, recognize)
            else:
                campaign = lifecycle.Campaign(args.app, args.mach_service, args.machine, evidence, args.timeout_seconds,
                                              secrets.token_hex(16), record_prefix="navigation")
                result = run_navigation(campaign, plan, recognize)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (lifecycle.LifecycleError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print(f"arm-ubuntu-installer-navigation: {error}", file=sys.stderr)
        return 2
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
