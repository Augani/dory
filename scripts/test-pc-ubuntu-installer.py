#!/usr/bin/env python3
"""Synthetic and native retained-pixel installer regressions; not physical qualification."""
import ast
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


installer = load("pc_installer", "pc-ubuntu-installer.py")
fixture = load("pc_installer_navigation_fixture", "test-arm-ubuntu-installer-navigation.py")
pc_fixture = load("pc_installer_authority_fixture", "test-pc-ubuntu-desktop-lifecycle.py")
lifecycle, navigation = installer.lifecycle, installer.navigation
APP, NONCE = fixture.APP, fixture.NONCE
MACHINE, SERVICE = "wave0-pc-gpu-installer", "dev.dory.wave0.pcgpu.installer"
MEDIA = {"installer": {"sha256": installer.MEDIA_SHA256, "byteCount": 100},
         "tools": {"sha256": "a" * 64, "byteCount": 200}}


def plan(machine=MACHINE):
    stages = []
    for stage in installer.STAGES:
        item = {"stage": stage, "captureDelayMilliseconds": 0}
        if stage not in {"grub-challenge", "language"}:
            code = {"uefi-menu": 1, "uefi-boot-manager": 28, "grub-menu": 28, "grub-edit": 18}.get(stage, 28)
            item["steps"] = [{"delayMilliseconds": 0, "events": navigation.press(code)}]
        if stage == "tools-terminal": item["authenticationSteps"] = [{"delayMilliseconds": 0, "events": navigation.press(28)}]
        stages.append(item)
    return {"kind": installer.KIND + "-plan", "schemaVersion": 1, "machineID": machine, "stages": stages}


def screen_text(stage, nonce):
    return {
        "uefi-menu": "Boot Manager\nDevice Manager\nBoot Maintenance Manager",
        "uefi-boot-manager": "Boot Manager\nUEFI Ubuntu DVD\nVirtio",
        "grub-menu": "GNU GRUB version 2.12\nTry or Install Ubuntu",
        "grub-edit": "setparams 'Try or Install Ubuntu'\nlinux /casper/vmlinuz quiet ---",
        "grub-challenge": "linux /casper/vmlinuz quiet ---\n" + navigation.SUFFIX + nonce,
        "language": "Welcome to Ubuntu\nChoose your language\nEnglish\nDeutsch",
        "accessibility": "Accessibility\nVision\nHearing\nTyping",
        "keyboard": "Keyboard layout\nEnglish (US)",
        "network": "Connect to the internet\nWired connection",
        "installation-choice": "Install Ubuntu\nTry Ubuntu",
        "interactive-installation": "Interactive installation\nAutomated installation",
        "applications": "Default selection\nExtended selection",
        "third-party": "Install third-party software\nDrivers",
        "disk-setup": "Erase disk and install Ubuntu\nManual installation",
        "account": "Create your account\nYour name\nPassword",
        "timezone": "Select your time zone\nAccra",
        "review": "Review your choices\nDisk partitions\nInstall",
        "install-complete": "Installation complete\nRestart now",
        "installed-login": "Password\nSign in",
        "installed-desktop": "OS Name\nUbuntu 24.04.4 LTS\nGNOME Version\n46\nWindowing System\nWayland",
        "tools-terminal": "DORY-TOOLS-READY " + nonce,
    }[stage]


def tools_body():
    return {"nonce": NONCE, "bootID": fixture.journey.boot(2),
            "toolsISOSHA256": MEDIA["tools"]["sha256"], "toolsISOByteCount": MEDIA["tools"]["byteCount"],
            "package": "dory-guest-tools", "packageStatus": "install ok installed", "packageVersion": "1.0.0",
            "packageArchitecture": "amd64", "agentActive": True, "toolsInstallerSHA256": "b" * 64,
            "nativePackageFields": ["Package: dory-guest-tools", "Version: 1.0.0", "Architecture: amd64"]}


class ModelCampaign(fixture.ModelCampaign):
    def __init__(self, evidence, backend="virgl", recognize=fixture.fake_recognizer, renderer=None):
        super().__init__(evidence, MACHINE, SERVICE, recognize, renderer)
        self.architecture, self.graphics_backend, self.timeout = "x86_64", backend, 90
        self.number, self.media, self.tools, self.state, self.calls = 1, True, False, "running", []
        self.runtime = self.current_runtime()

    def current_runtime(self):
        body = fixture.journey.status(self.number, "shared-nat", self.media, self.state)
        body.update(id=self.machine, guestArchitecture="x86_64", guestToolsMediaAttached=self.tools)
        body["runtimeGraphicsSelection"].update(backend=self.graphics_backend, accelerationLevel="hardware-accelerated-3d")
        return body

    def ctl_call(self, args, label, timeout=None):
        self.calls.append(args)
        command = args[0]
        if command == "stop": self.state = "stopped"
        elif command == "start": self.state, self.number = "running", self.number + 1
        elif command == "update":
            assert len(args) == 3, "optical media is a standalone normal daemon transaction"
            if args[2] == "--eject-installer": self.media = False
            elif args[2] == "--attach-guest-tools": self.tools = True
            else: raise AssertionError(args)
        if command == "console":
            body = self.before if label == "console-before" else fixture.serial(self.machine,
                "[ 0.0] Kernel command line: boot=casper " + navigation.SUFFIX + NONCE + "\n", self.before["nextOffset"])
        elif command == "exec":
            argv = args[args.index("--") + 1:]
            if argv[2].startswith("nonce, tools_size"):
                body = tools_body()
            else:
                action, nonce, network = ast.literal_eval(argv[2].splitlines()[0].split(" = ", 1)[1])
                assert nonce == NONCE and action == "boot" and network == "shared-nat"
                body = fixture.journey.observation("boot", "shared-nat", self.number)
                body.update(nonce=NONCE, architecture="x86_64", repositoryURL="https://archive.ubuntu.com/ubuntu/dists/noble/Release")
            body = {"schema": "dev.dory.machine.exec", "version": 1, "machine": self.machine, "argv": argv,
                    "exitCode": 0, "timedOut": False, "stdoutTruncated": False, "stderrTruncated": False,
                    "stdout": json.dumps(body), "stderr": ""}
        else: body = self.current_runtime()
        self.sequence += 1
        name = f"navigation-{self.sequence:04d}-{label}.json"
        self.evidence.write(name, {"argv": [str(self.ctl), "--mach-service", self.service, "--timeout", str(timeout or self.timeout), "machine", *args],
                                   "returnCode": 0, "timedOut": False, "stdout": json.dumps(body), "stderr": ""})
        return copy.deepcopy(body), name

    def capture(self, campaign, item, name, runtime, recognize, kernel_wait=None, *, screen_check):
        with patch.object(fixture, "screen_text", screen_text):
            point = super().capture(campaign, item, name, runtime, recognize, kernel_wait)
        screen_check(self.evidence.read(point["recognition"]), item["stage"], NONCE,
                     lifecycle.digest(navigation.png_bytes(self.evidence, point["image"])), self.evidence.read(point["frame"]))
        return point


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="dory-pc-installer-unit-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.evidence = lifecycle.Evidence(self.root)
        self.evidence.write("campaign-authority.json", pc_fixture.authorization(APP))
        self.campaign = ModelCampaign(self.evidence)

    def run_fixture(self, recognize=fixture.fake_recognizer):
        with patch.object(navigation, "capture_checkpoint", self.campaign.capture):
            return installer.run_installation(self.campaign, plan(), MEDIA, recognize)

    def replay(self, recognize=fixture.fake_recognizer):
        return installer.verify_installation(self.evidence, MACHINE, SERVICE, APP, self.campaign.graphics_backend, recognize)

    def mutate(self, name, mutate):
        body = self.evidence.read(name)
        mutate(body)
        (self.root / name).write_text(json.dumps(body))
        proof = self.evidence.read(installer.PROOF)
        proof["references"][name] = lifecycle.digest((self.root / name).read_bytes())
        (self.root / installer.PROOF).write_text(json.dumps(proof))

    def mutate_control(self, label, mutate):
        name = next(name for name in self.evidence.read(installer.PROOF)["references"] if name.endswith("-" + label + ".json"))
        self.mutate(name, mutate)

    def test_complete_interactive_installation_cold_disk_and_exact_tools_remain_unqualified(self):
        verdict = self.run_fixture()
        self.assertEqual(verdict, self.replay())
        self.assertEqual(verdict["guestArchitecture"], "x86_64")
        self.assertFalse(verdict["releaseEligible"])
        self.assertEqual(len(self.evidence.read(installer.PROOF)["checkpoints"]), 21)
        self.assertIn(["update", MACHINE, "--attach-guest-tools"], self.campaign.calls)
        self.assertFalse(any(args[0] in {"create", "delete", "restart"} for args in self.campaign.calls))

    def test_venus_profile_replays_and_virgl_relabel_fails(self):
        self.campaign.graphics_backend = "virgl-venus"
        self.run_fixture()
        self.assertEqual(self.replay()["status"], "evidence-verified")
        with self.assertRaises(lifecycle.LifecycleError):
            installer.verify_installation(self.evidence, MACHINE, SERVICE, APP, "virgl", fixture.fake_recognizer)

    def test_missing_foreign_or_arm_authority_denies_before_input(self):
        body = pc_fixture.authorization(APP)
        body["cells"][0]["capability"]["guest"]["architecture"] = "arm64"
        (self.root / "campaign-authority.json").write_text(json.dumps(body))
        with self.assertRaises(lifecycle.LifecycleError): self.run_fixture()
        self.assertEqual(self.campaign.calls, [])

    def test_server_media_shortcut_or_reordered_interactive_steps_reject_before_input(self):
        bad_media = copy.deepcopy(MEDIA); bad_media["installer"]["sha256"] = "e" * 64
        with self.assertRaises(lifecycle.LifecycleError):
            installer.run_installation(self.campaign, plan(), bad_media, fixture.fake_recognizer)
        for change in (lambda body: body["stages"].pop(6), lambda body: body["stages"].reverse(),
                       lambda body: body["stages"][6].update(expectedText="anything")):
            bad = plan(); change(bad)
            with self.assertRaises(lifecycle.LifecycleError): installer.validate_plan(bad, MACHINE)
        self.assertEqual(self.campaign.calls, [])

    def test_generated_boot_nonce_has_pc_serial_and_offline_tools_command_is_not_caller_replaced(self):
        scripts = {item["stage"]: installer.script_for(item["stage"], item, MACHINE, NONCE) for item in plan()["stages"]}
        expected = navigation.challenge_steps(NONCE) + installer.ascii_steps(" console=ttyS0,115200 console=tty0 ignore_loglevel")
        self.assertEqual(scripts["grub-challenge"]["steps"], expected)
        self.assertIn("/dev/disk/by-label/DORY_TOOLS", installer.tools_command(NONCE))
        self.assertIn("/install.sh install", installer.tools_command(NONCE))
        self.run_fixture()
        self.mutate("navigation-tools-terminal-script.json", lambda body: body["steps"].pop(2))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_unbalanced_or_unbounded_keyboard_plan_rejects(self):
        for change in (lambda item: item["steps"][0]["events"].pop(),
                       lambda item: item.update(captureDelayMilliseconds=True),
                       lambda item: item["steps"][0].update(delayMilliseconds=300001)):
            bad = plan(); change(bad["stages"][0])
            with self.assertRaises(lifecycle.LifecycleError): installer.validate_plan(bad, MACHINE)
        bad = plan(); bad["stages"][-1]["authenticationSteps"] = None
        with self.assertRaises(lifecycle.LifecycleError): installer.validate_plan(bad, MACHINE)

    def test_generated_ascii_command_roundtrips_the_us_keyboard_layout(self):
        rows = dict(zip(range(16, 26), "qwertyuiop"))
        rows.update(zip(range(30, 39), "asdfghjkl")); rows.update(zip(range(44, 51), "zxcvbnm"))
        rows.update(zip(range(2, 12), "1234567890"))
        rows.update({57: " ", 12: "-", 13: "=", 26: "[", 27: "]", 39: ";", 40: "'", 41: "`", 43: "\\", 51: ",", 52: ".", 53: "/"})
        shifted = dict(zip("1234567890-=[];'`\\,./", "!@#$%^&*()_+{}:\"~|<>?"))
        command = installer.tools_command(NONCE)
        result = ""
        for step in installer.ascii_steps(command):
            presses = [event["code"] for event in step["events"] if event["value"] == 1]
            letter = rows[presses[-1]]
            result += (letter.upper() if letter.isalpha() else shifted[letter]) if 42 in presses else letter
        self.assertEqual(result, command)

    def test_explicit_template_only_and_source_not_overwritten(self):
        source = self.root / "input.json"
        source.write_text(json.dumps(plan("wave0-pc-gpu-TEMPLATE")))
        original = source.read_bytes()
        self.assertEqual(installer.bind_plan(source, self.evidence, MACHINE, SERVICE)["machineID"], MACHINE)
        self.assertEqual(source.read_bytes(), original)
        source.write_text(json.dumps(plan("wave0-pc-gpu-someone-else")))
        with self.assertRaises(lifecycle.LifecycleError): installer.bind_plan(source, self.evidence, MACHINE, SERVICE)
        source.rename(self.root / "other.json"); source.symlink_to(self.root / "other.json")
        with self.assertRaises(OSError): installer.bind_plan(source, self.evidence, MACHINE, SERVICE)

    def test_rehashed_live_root_wrong_isa_or_software_renderer_rejects(self):
        self.run_fixture()
        def wrong(raw):
            transport = json.loads(raw["stdout"]); guest = json.loads(transport["stdout"])
            guest["rootFSType"] = "overlay"; transport["stdout"] = json.dumps(guest); raw["stdout"] = json.dumps(transport)
        self.mutate_control("boot", wrong)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_native_tools_isa_package_version_media_hash_and_service_required(self):
        for key, value in [("packageArchitecture", "arm64"), ("toolsISOSHA256", "c" * 64),
                           ("agentActive", False), ("packageVersion", "other"), ("toolsISOByteCount", 201)]:
            body = tools_body(); body[key] = value
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): installer.check_tools(body, NONCE, MEDIA)

    def test_guest_reboot_between_root_and_tools_observations_rejects_even_in_same_vm(self):
        self.run_fixture()
        def rebooted(raw):
            transport = json.loads(raw["stdout"]); guest = json.loads(transport["stdout"])
            guest["bootID"] = fixture.journey.boot(3)
            transport["stdout"] = json.dumps(guest); raw["stdout"] = json.dumps(transport)
        self.mutate_control("tools-probe", rebooted)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_confirmation_is_required_before_paths_codesign_or_daemon_access(self):
        args = [sys.executable, str(Path(installer.__file__)), "--app", "/missing/Dory.app", "--machine", MACHINE,
                "--mach-service", SERVICE, "--run-directory", "/missing/evidence"]
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --confirm EXACT-DORY-PC-DESKTOP-INSTALL", result.stderr)

    def test_rehashed_renderer_and_installer_window_cannot_cross_cold_boot(self):
        self.run_fixture()
        self.mutate("navigation-installed-login-window.json", lambda body: body.update(operationID=fixture.journey.boot(101)))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_extra_control_arguments_or_mixed_media_transaction_rejects(self):
        self.run_fixture()
        self.mutate_control("eject", lambda raw: raw["argv"].extend(["--network", "disconnected"]))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_serial_generation_loss_or_userspace_nonce_rejects(self):
        self.run_fixture()
        def forged(raw):
            body = json.loads(raw["stdout"]); body["generation"] = "1" * 64; raw["stdout"] = json.dumps(body)
        self.mutate_control("console-after", forged)
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_rehashed_forged_recognition_requires_independent_retained_pixels(self):
        self.run_fixture()
        self.mutate("navigation-review-ocr.json", lambda body: body["lines"][0].update(text="Review forged pixels"))
        with self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_server_screen_is_not_desktop_grub_even_with_real_scope(self):
        self.run_fixture()
        body = self.evidence.read("navigation-grub-menu-ocr.json")
        body["lines"][1]["text"] = "Try or Install Ubuntu Server"
        with self.assertRaises(lifecycle.LifecycleError):
            installer.check_screen(body, "grub-menu", NONCE, body["framebufferSHA256"], self.evidence.read("navigation-grub-menu-frame.json"))

    def test_rehashed_source_release_claim_or_missing_screenshot_denies(self):
        self.run_fixture()
        record = self.evidence.read(installer.PROOF)
        for key, value in [("releaseEligible", True), ("sourceSHA256", {}), ("installedBootID", fixture.journey.boot(9))]:
            changed = copy.deepcopy(record); changed[key] = value
            (self.root / installer.PROOF).write_text(json.dumps(changed))
            with self.subTest(key=key), self.assertRaises(lifecycle.LifecycleError): self.replay()

    def test_media_digest_rejects_symlink_and_preserves_exact_bytes(self):
        image = self.root / "image.iso"; image.write_bytes(b"iso bytes")
        self.assertEqual(installer.media_digest(image), {"sha256": lifecycle.digest(b"iso bytes"), "byteCount": 9})
        link = self.root / "link.iso"; link.symlink_to(image)
        with self.assertRaises(OSError): installer.media_digest(link)

    @unittest.skipUnless(sys.platform == "darwin", "native ImageIO/Vision requires macOS")
    def test_native_ocr_replays_all_interactive_and_installed_screens(self):
        executable = self.root / "render"
        subprocess.run(["/usr/bin/xcrun", "swiftc", str(Path(__file__).parent / "fixtures/arm-navigation/text-screen.swift"),
                        "-o", str(executable)], check=True, capture_output=True, timeout=60)
        def render(text, path):
            subprocess.run([str(executable), text, str(path)], check=True, capture_output=True, timeout=10)
        with navigation.Recognizer() as recognize:
            self.campaign = ModelCampaign(self.evidence, recognize=recognize, renderer=render)
            self.assertEqual(self.run_fixture(recognize), self.replay(recognize))
            frame = self.evidence.read("navigation-review-frame.json")
            frame["guestViewport"].update(y=400, height=300)
            (self.root / "navigation-review-frame.json").write_text(json.dumps(frame))
            self.assertFalse(recognize(self.evidence, "navigation-review.png", "navigation-review-frame.json")["lines"])


if __name__ == "__main__": unittest.main()
