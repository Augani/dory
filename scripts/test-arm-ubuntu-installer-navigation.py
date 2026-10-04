#!/usr/bin/env python3
"""Adversarial navigation models and real local OCR tests, not physical qualification."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


navigation = load("navigation", "arm-ubuntu-installer-navigation.py")
journey = load("navigation_journey", "test-arm-ubuntu-desktop-lifecycle.py")
lifecycle = navigation.lifecycle
APP, MACHINE, SERVICE = journey.APP, journey.MACHINE, journey.SERVICE
NONCE = "abcdef0123456789abcdef0123456789"


def plan(machine=MACHINE):
    return {"kind": navigation.KIND + "-plan", "schemaVersion": 1, "machineID": machine,
            "stages": [{"stage": stage, "captureDelayMilliseconds": 0,
                        **({"steps": [{"delayMilliseconds": 0, "events": navigation.press(code)}]} if index < 4 else {})}
                       for index, (stage, code) in enumerate(zip(navigation.STAGES, (1, 28, 28, 18, 107, 45)))]}


def screen_text(stage, nonce):
    return {
        "uefi-menu": "Boot Manager\nDevice Manager\nBoot Maintenance Manager",
        "uefi-boot-manager": "Boot Manager\nUEFI Ubuntu DVD\nVirtio",
        "grub-menu": "GNU GRUB version 2.12\nTry or Install Ubuntu Server",
        "grub-edit": "setparams 'Try or Install Ubuntu Server'\nlinux /casper/vmlinuz quiet ---",
        "grub-challenge": "setparams 'Try or Install Ubuntu Server'\nlinux /casper/vmlinuz quiet ---\n" + navigation.SUFFIX + nonce,
        "installer": "Welcome!\nUse UP, DOWN and ENTER keys to select your language.\nEnglish\nDeutsch\nFrançais",
    }[stage]


def fake_recognizer(evidence, image, frame):
    # Deliberately not a PNG decoder: only injected into unit models. Production always
    # independently decodes PNG through ImageIO/Vision, which rejects these synthetic bytes.
    text = (evidence.directory / image).read_bytes()[24:].decode()
    return {"kind": "dev.dory.guest-viewport-text", "schemaVersion": 1, "revision": 3,
            "framebufferSHA256": lifecycle.digest((evidence.directory / image).read_bytes()),
            "recognizerSourceSHA256": lifecycle.digest(navigation.OCR_SOURCE.read_bytes()), "cropWidth": 1280, "cropHeight": 720,
            "lines": [{"text": line, "confidence": 1, "x": 0.1, "y": 0.9 - index * 0.05, "width": 0.7, "height": 0.03}
                      for index, line in enumerate(text.splitlines())]}


def serial(machine, text, start=0, snapshot=False):
    data = text.encode()
    return {"schemaVersion": 1, "machineID": machine, "generation": "9" * 64, "startOffset": start,
            "nextOffset": start + len(data), "totalBytes": start + len(data), "snapshotRequired": snapshot,
            "inputAvailable": True, "bytesBase64": base64.b64encode(data).decode()}


class ModelCampaign(lifecycle.Campaign):
    def __init__(self, evidence, machine=MACHINE, service=SERVICE, recognize=fake_recognizer, renderer=None):
        super().__init__(APP, service, machine, evidence, 90, NONCE, record_prefix="navigation")
        self.recognize, self.renderer, self.index = recognize, renderer, 0
        self.runtime = journey.status(1, "shared-nat", True)
        self.runtime["id"] = machine
        self.before = serial(machine, "UEFI firmware\n", snapshot=True)

    def ctl_call(self, args, label, timeout=None):
        self.sequence += 1
        if args[0] == "status":
            body = self.runtime
        elif label == "console-before":
            body = self.before
        else:
            body = serial(self.machine, "[    0.000000] Kernel command line: boot=casper " + navigation.SUFFIX + NONCE + "\n", self.before["nextOffset"])
        name = f"navigation-{self.sequence:04d}-{label}.json"
        self.evidence.write(name, {"argv": [str(self.ctl), "--mach-service", self.service, "--timeout", str(timeout or self.timeout), "machine", *args],
                                   "returnCode": 0, "timedOut": False, "stdout": json.dumps(body), "stderr": ""})
        return copy.deepcopy(body), name

    def capture(self, campaign, item, script_name, runtime, recognize, kernel_wait=None):
        assert campaign is self
        stage = item["stage"]
        self.index += 1
        prefix = "navigation-" + stage
        window = journey.window(runtime)
        window.update(machineID=self.machine, machServiceName=self.service, windowTitle=f"Dory — {self.machine} — Display 1")
        window.update(frameSequence=self.index * 10, metalCommandBufferCompletionID=1,
                      guestViewport={"coordinateSpace": "capture-pixels-top-left", "x": 0, "y": 0, "width": 1280, "height": 720})
        self.evidence.write(prefix + "-window.json", window)
        script = self.evidence.read(script_name)
        keyboard = {"kind": "dev.dory.display-qualification-input", "schemaVersion": 1, "delivery": "runner-applied",
                    "bundleIdentifier": "com.pythonxi.Dory", "machineID": self.machine, "machServiceName": self.service,
                    "operationID": window["operationID"], "processID": window["processID"],
                    "scriptSHA256": lifecycle.digest((self.evidence.directory / script_name).read_bytes()),
                    "stepCount": len(script["steps"]), "eventCount": sum(len(item["events"]) for item in script["steps"]),
                    "firstCommandSequence": self.index * 100, "lastCommandSequence": self.index * 100 + len(script["steps"]) - 1}
        self.evidence.write(prefix + "-input.json", keyboard)
        if kernel_wait:
            kernel_wait()
        frame = {**window, "frameSequence": window["frameSequence"] + 1, "metalCommandBufferCompletionID": 2, "framePollingHeldForCapture": True}
        self.evidence.write(prefix + "-frame.json", frame)
        self.evidence.write(prefix + "-released.json", {"stage": stage, "nonce": NONCE})
        image = prefix + ".png"
        path = self.evidence.directory / image
        text = screen_text(stage, NONCE)
        if self.renderer:
            self.renderer(text, path)
        else:
            path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0" * 4 + b"IHDR" + (1280).to_bytes(4, "big") + (720).to_bytes(4, "big") + text.encode())
        self.evidence.write(prefix + "-ocr.json", recognize(self.evidence, image, prefix + "-frame.json"))
        return {"stage": stage, "script": script_name, "image": image, "recognition": prefix + "-ocr.json",
                **{key: prefix + "-" + key + ".json" for key in ("window", "input", "frame", "released")}}


def write_fixture(directory, machine=MACHINE, service=SERVICE, recognize=fake_recognizer, renderer=None):
    evidence = lifecycle.Evidence(directory)
    campaign = ModelCampaign(evidence, machine, service, recognize, renderer)
    with patch.object(navigation, "capture_checkpoint", campaign.capture):
        navigation.run_navigation(campaign, plan(machine), recognize)
    return campaign


class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-navigation-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.evidence = lifecycle.Evidence(self.directory)

    def replay(self, recognize=fake_recognizer):
        return navigation.verify_navigation(self.evidence, MACHINE, SERVICE, APP, recognize)

    def mutate(self, name, change):
        record = self.evidence.read(name)
        change(record)
        path = self.directory / name
        path.write_text(json.dumps(record))
        receipt = self.evidence.read("installer-navigation.json")
        receipt["references"][name] = lifecycle.digest(path.read_bytes())
        (self.directory / "installer-navigation.json").write_text(json.dumps(receipt))

    def test_all_checkpoint_pixels_keys_and_fresh_kernel_nonce_replay(self):
        write_fixture(self.directory)
        self.assertEqual(self.replay()["status"], "evidence-verified")

    def test_explicit_template_binding_changes_only_machine_and_is_exclusive(self):
        body = plan("readiness-arm-ubuntu-TEMPLATE")
        source = self.directory / "template.json"
        source.write_text(json.dumps(body))
        destination = self.directory.resolve() / "materialized.json"
        result = navigation.bind_input(source, destination, MACHINE, SERVICE, "navigation")
        expected = copy.deepcopy(body)
        expected["machineID"] = MACHINE
        self.assertEqual(json.loads(destination.read_text()), expected)
        self.assertEqual(json.loads(source.read_text()), body)
        self.assertEqual(result["materializedSHA256"], lifecycle.digest(destination.read_bytes()))
        with self.assertRaises(FileExistsError):
            navigation.bind_input(source, destination, MACHINE, SERVICE, "navigation")

    def test_binding_rejects_foreign_machine_and_unbalanced_installer_input(self):
        source = self.directory / "input.json"
        source.write_text(json.dumps(plan("readiness-arm-ubuntu-other")))
        destination = self.directory.resolve() / "materialized.json"
        with self.assertRaises(lifecycle.LifecycleError):
            navigation.bind_input(source, destination, MACHINE, SERVICE, "navigation")
        body = navigation.script_for("uefi-menu", plan()["stages"][0], "readiness-arm-ubuntu-TEMPLATE", NONCE)
        body["steps"][0]["events"].pop()
        source.write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError):
            navigation.bind_input(source, destination, MACHINE, SERVICE, "installer")
        self.assertFalse(destination.exists())

    def test_binding_rejects_symlink_output_without_overwriting_target(self):
        source = self.directory / "input.json"
        source.write_text(json.dumps(navigation.script_for("uefi-menu", plan()["stages"][0], MACHINE, NONCE)))
        target = self.directory / "target.json"
        target.write_text("untouched")
        destination = self.directory.resolve() / "materialized.json"
        destination.symlink_to(target)
        with self.assertRaises(FileExistsError):
            navigation.bind_input(source, destination, MACHINE, SERVICE, "installer")
        self.assertEqual(target.read_text(), "untouched")

    def test_plan_requires_all_six_stages_in_order(self):
        body = plan()
        body["stages"].reverse()
        with self.assertRaises(lifecycle.LifecycleError):
            navigation.validate_plan(body, MACHINE)

    def test_plan_rejects_unbalanced_keys_and_boolean_delay(self):
        for mutate in (lambda body: body["stages"][0]["steps"][0]["events"].pop(),
                       lambda body: body["stages"][0].update(captureDelayMilliseconds=True)):
            body = plan()
            mutate(body)
            with self.assertRaises(lifecycle.LifecycleError):
                navigation.validate_plan(body, MACHINE)

    def test_caller_cannot_replace_generated_nonce_or_boot_keys(self):
        body = plan()
        body["stages"][-1]["steps"] = [{"delayMilliseconds": 0, "events": navigation.press(28)}]
        with self.assertRaises(lifecycle.LifecycleError):
            navigation.validate_plan(body, MACHINE)

    def test_generated_challenge_keys_decode_exact_nonce_and_release_every_frame(self):
        steps = navigation.challenge_steps(NONCE)
        inverse = {value: key for key, value in dict(zip("qwertyuiop", range(16, 26))).items()}
        inverse.update({value: key for key, value in dict(zip("asdfghjkl", range(30, 39))).items()})
        inverse.update({value: key for key, value in dict(zip("zxcvbnm", range(44, 51))).items()})
        inverse.update({value: key for key, value in dict(zip("1234567890", range(2, 12))).items()})
        inverse.update({57: " ", 52: ".", 13: "="})
        self.assertEqual(steps[0]["events"], navigation.press(107))
        self.assertEqual("".join(inverse[item["events"][0]["code"]] for item in steps[1:]), " " + navigation.SUFFIX + NONCE)
        for item in steps:
            self.assertEqual(item["events"][0]["code"], item["events"][-1]["code"])
            self.assertEqual(item["events"][-1]["value"], 0)

    def test_rehashed_pass_without_a_frozen_post_input_frame_fails(self):
        write_fixture(self.directory)
        self.mutate("navigation-grub-menu-frame.json", lambda body: body.update(framePollingHeldForCapture=False))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_wrong_operation_input_fails(self):
        write_fixture(self.directory)
        self.mutate("navigation-grub-edit-input.json", lambda body: body.update(operationID="wrong"))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_reused_command_sequence_fails(self):
        write_fixture(self.directory)
        self.mutate("navigation-grub-edit-input.json", lambda body: body.update(firstCommandSequence=1))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_nonce_printed_in_userspace_is_not_a_kernel_command_line(self):
        write_fixture(self.directory)
        self.mutate("navigation-0003-console-after.json", lambda raw: raw.update(stdout=json.dumps(serial(MACHINE, "echo " + navigation.SUFFIX + NONCE + "\n", len("UEFI firmware\n")))))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_replaced_console_generation_fails(self):
        write_fixture(self.directory)
        self.mutate("navigation-0003-console-after.json", lambda raw: raw.update(stdout=json.dumps({**json.loads(raw["stdout"]), "generation": "8" * 64})))
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_rehashed_forged_ocr_fails_independent_pixels(self):
        write_fixture(self.directory)
        def forged(body):
            body["lines"].append({"text": "fake", "confidence": 1, "x": 0, "y": 0, "width": 0.1, "height": 0.1})
        self.mutate("navigation-grub-menu-ocr.json", forged)
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()

    def test_independent_wrong_screen_fails_even_if_retained_ocr_says_pass(self):
        write_fixture(self.directory)
        def wrong(evidence, image, frame):
            result = fake_recognizer(evidence, image, frame)
            result["lines"] = [{"text": "Dory desktop", "confidence": 1, "x": 0, "y": 0, "width": 1, "height": 1}]
            return result
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay(wrong)

    def test_indirect_png_and_foreign_campaign_fail(self):
        write_fixture(self.directory)
        image = self.directory / "navigation-grub-menu.png"
        image.rename(self.directory / "other.png")
        image.symlink_to(self.directory / "other.png")
        with self.assertRaises(lifecycle.LifecycleError):
            self.replay()
        with self.assertRaises(lifecycle.LifecycleError):
            navigation.scope(MACHINE, "dev.dory.doryd")

    @unittest.skipUnless(sys.platform == "darwin", "ImageIO/Vision test requires macOS")
    def test_native_vision_decodes_every_screen_and_rejects_text_outside_guest_viewport(self):
        fixture_source = Path(__file__).parent / "fixtures/arm-navigation/text-screen.swift"
        renderer_path = self.directory / "renderer"
        subprocess.run(["/usr/bin/xcrun", "swiftc", str(fixture_source), "-o", str(renderer_path)], check=True, capture_output=True, timeout=60)
        def render(text, path):
            subprocess.run([str(renderer_path), text, str(path)], check=True, capture_output=True, timeout=10)
        with navigation.Recognizer() as recognize:
            write_fixture(self.directory, recognize=recognize, renderer=render)
            self.assertEqual(self.replay(recognize)["status"], "evidence-verified")
            frame_name = "navigation-grub-menu-frame.json"
            frame = self.evidence.read(frame_name)
            frame["guestViewport"].update(y=400, height=300)
            (self.directory / frame_name).write_text(json.dumps(frame))
            cropped = recognize(self.evidence, "navigation-grub-menu.png", frame_name)
            self.assertFalse(cropped["lines"], "OCR leaked host/title pixels outside the guest viewport")

    @unittest.skipUnless(sys.platform == "darwin", "Swift app sequence checks require Xcode")
    def test_actual_app_command_sequence_source_survives_process_relaunch_and_equal_ticks(self):
        root = Path(__file__).resolve().parents[1]
        executable = self.directory / "sequence-check"
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6",
                        str(root / "Dory/Runtime/Machines/DoryDisplayCommandSequence.swift"),
                        str(root / "scripts/fixtures/arm-navigation/command-sequence-check.swift"),
                        "-o", str(executable)], check=True, capture_output=True, timeout=30)
        result = subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=5)
        self.assertIn("sequence checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
