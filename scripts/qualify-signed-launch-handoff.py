#!/usr/bin/env python3
"""Exercise a packaged DoryHVRunner's production daemon-authentication boundary.

This is an opt-in physical signing harness, not a release qualification receipt. It compiles one
nonshipping Unix-socket peer, signs separate copies with the supplied Developer ID and a different
team identity, and proves the runner only transfers its token and descriptor to `doryd` signed by
the expected Developer ID team. The legacy bypass environment variable is deliberately present in
every invocation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import os
import re
import select
import shutil
import subprocess
import tempfile
import time
from typing import NoReturn


ROOT = Path(__file__).resolve().parents[1]
PEER_SOURCE = ROOT / "scripts/fixtures/signed-launch-handoff-peer.c"
EXPECTED_TEAM = "864H636QW4"
RUNNER_IDENTIFIER = "com.pythonxi.Dory.HVRunner"
DAEMON_IDENTIFIER = "doryd"
HANDOFF_SOCKET_ARGUMENT = "--doryd-application-launch-handoff"
HANDOFF_TOKEN_ARGUMENT = "--doryd-application-launch-token"
CASES = (
    "valid-peer",
    "wrong-team",
    "wrong-identity",
    "unsigned",
    "absent",
    "malformed",
)


class QualificationError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise QualificationError(f"signed launch handoff qualification: {message}")


def run(command: list[str], *, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"could not run {' '.join(command)}: {error}")
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        fail(f"{' '.join(command)} failed: {detail}")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def signing_details(path: Path) -> str:
    result = subprocess.run(
        ["codesign", "-d", "--verbose=4", os.fspath(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"could not inspect code signature for {path}")
    return result.stdout + result.stderr


def signed_value(details: str, name: str) -> str | None:
    match = re.search(rf"^{re.escape(name)}(?:=|\s+)(.+)$", details, flags=re.MULTILINE)
    return match.group(1).strip() if match else None


def verify_runner(runner: Path) -> None:
    if not runner.is_file() or runner.is_symlink() or not os.access(runner, os.X_OK):
        fail(f"runner must be an executable direct file: {runner}")
    run(["codesign", "--verify", "--strict", os.fspath(runner)])
    details = signing_details(runner)
    if signed_value(details, "Identifier") != RUNNER_IDENTIFIER:
        fail("runner signing identifier is not DoryHVRunner")
    if signed_value(details, "TeamIdentifier") != EXPECTED_TEAM:
        fail("runner signing team is not Dory's production team")
    if "Authority=Developer ID Application:" not in details:
        fail("runner is not Developer ID signed")
    if "runtime" not in (signed_value(details, "CodeDirectory") or ""):
        fail("runner lacks the hardened runtime")


def compile_peer(output: Path) -> None:
    if not PEER_SOURCE.is_file() or PEER_SOURCE.is_symlink():
        fail(f"peer source is unavailable: {PEER_SOURCE}")
    compiler = run(["xcrun", "--find", "clang"]).stdout.strip()
    if not compiler:
        fail("Xcode clang is unavailable")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    if not sdk:
        fail("macOS SDK is unavailable")
    run([
        compiler,
        "-Wall", "-Wextra", "-Werror", "-O2", "-isysroot", sdk,
        "-mmacosx-version-min=14.0",
        os.fspath(PEER_SOURCE), "-o", os.fspath(output),
    ])


def sign_peer(path: Path, *, identity: str, identifier: str) -> None:
    run([
        "codesign", "--force", "--sign", identity, "--identifier", identifier,
        "--options", "runtime", os.fspath(path),
    ])
    run(["codesign", "--verify", "--strict", os.fspath(path)])


def wait_for_ready(process: subprocess.Popen[str]) -> tuple[str, str]:
    if process.stdout is None:
        fail("qualification peer stdout is unavailable")
    deadline = time.monotonic() + 8
    invitation = bytearray()
    while not invitation.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or len(invitation) >= 1024:
            fail("qualification peer did not publish a bounded invitation")
        readable, _, _ = select.select([process.stdout], [], [], remaining)
        if not readable:
            fail("qualification peer did not publish an invitation")
        chunk = os.read(process.stdout.fileno(), 1)
        if not chunk:
            fail("qualification peer exited before publishing an invitation")
        invitation.extend(chunk)
    try:
        line = invitation.decode("ascii").strip()
    except UnicodeDecodeError:
        fail("qualification peer invitation is not ASCII")
    fields = line.split()
    if len(fields) != 3 or fields[0] != "READY" or not fields[1].startswith("/") \
            or not re.fullmatch(r"[0-9a-f]{64}", fields[2]):
        terminate(process)
        fail(f"qualification peer published an invalid invitation: {line!r}")
    return fields[1], fields[2]


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.kill()
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()


def run_with_peer(runner: Path, peer: Path) -> tuple[int, str, str]:
    # Own the socket directory outside the peer process so even SIGKILL and a
    # runner timeout cannot strand private invitations or socket files.
    with tempfile.TemporaryDirectory(prefix="dory-handoff-", dir="/tmp") as directory:
        process = subprocess.Popen(
            [os.fspath(peer), directory],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            socket_path, token = wait_for_ready(process)
            if Path(socket_path) != Path(directory) / "h.sock":
                fail("qualification peer invitation escaped its owned directory")
            environment = dict(os.environ)
            environment["DORY_TEST_BYPASS_DAEMON_AUTH"] = "1"
            runner_result = subprocess.run(
                [os.fspath(runner), "madvtest", HANDOFF_SOCKET_ARGUMENT, socket_path,
                 HANDOFF_TOKEN_ARGUMENT, token],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=environment, timeout=25, check=False,
            )
            try:
                peer_stdout, peer_stderr = process.communicate(timeout=25)
            except subprocess.TimeoutExpired:
                fail("qualification peer did not terminate")
            if process.returncode != 0:
                fail(
                    "qualification peer failed: "
                    f"{peer_stderr.strip() or peer_stdout.strip()}; "
                    f"runner exit {runner_result.returncode}: {runner_result.stderr.strip()}"
                )
            return runner_result.returncode, runner_result.stderr.strip(), peer_stdout.strip()
        finally:
            terminate(process)


def run_absent_or_malformed(runner: Path, *, malformed: bool) -> tuple[int, str]:
    environment = dict(os.environ)
    environment["DORY_TEST_BYPASS_DAEMON_AUTH"] = "1"
    with tempfile.TemporaryDirectory(prefix="dory-signed-handoff-absent-") as directory:
        socket_path = "relative-socket" if malformed else os.fspath(Path(directory) / "absent.sock")
        result = subprocess.run(
            [
                os.fspath(runner), "madvtest", HANDOFF_SOCKET_ARGUMENT, socket_path,
                HANDOFF_TOKEN_ARGUMENT, "a" * 64,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=25,
            check=False,
        )
    return result.returncode, result.stderr.strip()


def expect_rejection(name: str, runner: Path, peer: Path) -> dict[str, object]:
    exit_code, stderr, peer_stdout = run_with_peer(runner, peer)
    if exit_code == 0:
        fail(f"{name} peer unexpectedly launched the runner")
    if "RESULT token=0 descriptor=0 acknowledgement=0" not in peer_stdout:
        fail(f"{name} peer received launch authority: {peer_stdout!r}")
    if "dynamicCodeRejected" not in stderr:
        fail(f"{name} peer did not fail at live code validation: {stderr!r}")
    return {"runnerExit": exit_code, "peer": peer_stdout, "stderr": stderr}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--developer-id", help="Developer ID Application identity for Dory's team")
    parser.add_argument("--wrong-team-identity", help="installed signing identity from a different team")
    parser.add_argument("--list", action="store_true", help="print the immutable case list without tools")
    arguments = parser.parse_args()
    if arguments.list:
        print(json.dumps({"cases": CASES}, sort_keys=True))
        return 0
    if (arguments.runner is None) == (arguments.app is None):
        parser.error("provide exactly one of --runner or --app")
    if not arguments.developer_id:
        parser.error("--developer-id is required")
    runner = arguments.runner or arguments.app / "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv"
    runner = runner.absolute()
    verify_runner(runner)

    with tempfile.TemporaryDirectory(prefix="dory-signed-handoff-qualification-") as directory:
        root = Path(directory)
        unsigned = root / "peer-unsigned"
        compile_peer(unsigned)
        records: dict[str, object] = {}

        valid = root / "peer-valid"
        shutil.copy2(unsigned, valid)
        sign_peer(valid, identity=arguments.developer_id, identifier=DAEMON_IDENTIFIER)
        exit_code, stderr, peer_stdout = run_with_peer(runner, valid)
        if exit_code != 0 or "RESULT token=1 descriptor=1 acknowledgement=1" not in peer_stdout:
            fail(f"valid signed daemon did not complete the handoff: {stderr} {peer_stdout}")
        records["valid-peer"] = {"runnerExit": exit_code, "peer": peer_stdout}

        wrong_identity = root / "peer-wrong-identity"
        shutil.copy2(unsigned, wrong_identity)
        sign_peer(wrong_identity, identity=arguments.developer_id, identifier="not-doryd")
        records["wrong-identity"] = expect_rejection("wrong-identity", runner, wrong_identity)

        missing_cases: list[str] = []
        if arguments.wrong_team_identity:
            wrong_team = root / "peer-wrong-team"
            shutil.copy2(unsigned, wrong_team)
            sign_peer(wrong_team, identity=arguments.wrong_team_identity, identifier=DAEMON_IDENTIFIER)
            if signed_value(signing_details(wrong_team), "TeamIdentifier") == EXPECTED_TEAM:
                fail("--wrong-team-identity belongs to Dory's production team")
            records["wrong-team"] = expect_rejection("wrong-team", runner, wrong_team)
        else:
            records["wrong-team"] = {
                "status": "unavailable",
                "reason": "no installed Apple signing identity from another team",
            }
            missing_cases.append("wrong-team")

        records["unsigned"] = expect_rejection("unsigned", runner, unsigned)
        for name, malformed in (("absent", False), ("malformed", True)):
            exit_code, stderr = run_absent_or_malformed(runner, malformed=malformed)
            if exit_code == 0:
                fail(f"{name} peer unexpectedly launched the runner")
            records[name] = {"runnerExit": exit_code, "stderr": stderr}

    print(json.dumps({
        "kind": "dev.dory.signed-launch-handoff-qualification",
        "missingCases": missing_cases,
        "runnerSHA256": sha256(runner),
        "results": records,
    }, sort_keys=True))
    # An incomplete identity matrix is useful evidence, but must not accidentally pass a shell
    # qualification gate or be re-labelled as a complete signed-peer result.
    return 3 if missing_cases else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QualificationError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
