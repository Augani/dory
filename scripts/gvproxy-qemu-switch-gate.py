#!/usr/bin/env python3
"""Prove the exact gvproxy gives Dory's LAN bridge an independent bidirectional L2 port."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import tempfile
import time


PINNED_SHA256 = "47c278f1636736ba552de3d2f0e68409cdc968d63bc02149637e449f40274459"
PINNED_VERSION = "gvproxy version v0.8.9-dory2"
CONFIRMATION = "EXACT-GVPROXY-QEMU-SWITCH"
GUEST_MAC = bytes.fromhex("5a94efe40cee")
BRIDGE_MAC = bytes.fromhex("5a94efd01201")


def fail(message: str) -> None:
    raise SystemExit(f"gvproxy QEMU switch gate: FAIL: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def frame(destination: bytes, source: bytes, marker: bytes) -> bytes:
    return destination + source + b"\x88\xb5" + marker


def wait_for_paths(process: subprocess.Popen[bytes], paths: list[Path], deadline: float) -> None:
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
            fail(f"gvproxy exited early with status {process.returncode}: {stderr.strip()}")
        if all(path.exists() for path in paths):
            return
        time.sleep(0.02)
    fail("gvproxy did not create its vfkit and QEMU sockets")


def receive_bytes(sock: socket.socket, count: int) -> bytes:
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            fail("gvproxy closed the QEMU switch connection")
        result.extend(chunk)
    return bytes(result)


def send_qemu_frame(sock: socket.socket, payload: bytes) -> None:
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def receive_qemu_frame(sock: socket.socket, expected: bytes, label: str) -> None:
    sock.settimeout(3)
    try:
        length = struct.unpack(">I", receive_bytes(sock, 4))[0]
        actual = receive_bytes(sock, length)
    except TimeoutError:
        fail(f"timed out waiting for {label}")
    if actual != expected:
        fail(f"{label} changed in transit (expected {expected.hex()}, got {actual.hex()})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("gvproxy", type=Path, help="exact gvproxy executable to validate")
    parser.add_argument("--expected-sha256", default=PINNED_SHA256)
    parser.add_argument("--provenance", type=Path)
    parser.add_argument("--workroot", type=Path, required=True, help="new private evidence root")
    parser.add_argument("--evidence", type=Path, help="must be WORKROOT/manifest.txt")
    parser.add_argument("--source-commit", default="")
    parser.add_argument("--mtu", type=int, default=1280)
    parser.add_argument("--confirm", default="")
    parser.add_argument("--release-candidate", action="store_true")
    args = parser.parse_args()

    if args.confirm != CONFIRMATION:
        fail(f"requires --confirm {CONFIRMATION}")
    if not 576 <= args.mtu <= 9000:
        fail("MTU must be between 576 and 9000")
    if args.source_commit and re.fullmatch(r"[0-9a-f]{40}", args.source_commit) is None:
        fail("source commit must be a full lowercase Git SHA")
    if re.fullmatch(r"[0-9a-f]{64}", args.expected_sha256.lower()) is None:
        fail("expected SHA-256 is invalid")
    if not args.gvproxy.is_absolute():
        fail("gvproxy must be an absolute path")
    if args.gvproxy.is_symlink() or not args.gvproxy.is_file() or not os.access(args.gvproxy, os.X_OK):
        fail("gvproxy is unavailable or indirect")
    binary = args.gvproxy.resolve(strict=True)
    if binary.stat().st_uid != os.getuid():
        fail("gvproxy is not owned by the release user")
    if args.release_candidate:
        if args.expected_sha256.lower() != PINNED_SHA256:
            fail("release candidate digest is compiled and cannot be overridden")
        if not args.source_commit:
            fail("release candidate evidence requires --source-commit")
        if args.provenance is None:
            fail("release candidate evidence requires --provenance")

    actual_sha = sha256(binary)
    if actual_sha != args.expected_sha256.lower():
        fail(f"SHA-256 mismatch (expected {args.expected_sha256.lower()}, got {actual_sha})")
    build_sha = actual_sha
    provenance_sha = "none"
    if args.provenance:
        if not args.provenance.is_absolute():
            fail("provenance must be an absolute path")
        if args.provenance.is_symlink() or not args.provenance.is_file():
            fail("provenance is missing or indirect")
        if args.provenance.stat().st_size > 1024 * 1024:
            fail("provenance exceeds one MiB")
        provenance_sha = sha256(args.provenance)
        values = [
            line.partition("=")[2].strip().lower()
            for line in args.provenance.read_text(encoding="utf-8").splitlines()
            if line.partition("=")[0] == "verified_sha256"
        ]
        if len(values) != 1:
            fail("provenance must contain exactly one verified_sha256")
        build_sha = values[0]
        if build_sha != PINNED_SHA256:
            fail(f"reproducible-build SHA-256 mismatch (expected {PINNED_SHA256}, got {build_sha})")

    identity = subprocess.run(
        [str(binary), "-version"], check=False, capture_output=True, text=True, timeout=5
    )
    version = (identity.stdout + identity.stderr).strip().splitlines()
    if identity.returncode != 0 or not version or version[0] != PINNED_VERSION:
        fail(f"unexpected version identity: {version[0] if version else 'no output'}")

    if not args.workroot.is_absolute():
        fail("workroot must be an absolute path")
    if args.workroot.name in ("", ".", ".."):
        fail("workroot has an unsafe leaf")
    if args.workroot.exists() or args.workroot.is_symlink():
        fail("workroot already exists or is indirect")
    workroot_parent = args.workroot.parent
    if not workroot_parent.is_dir():
        fail("workroot parent is unavailable")
    workroot = workroot_parent.resolve(strict=True) / args.workroot.name
    if workroot.exists() or workroot.is_symlink():
        fail("canonical workroot already exists or is indirect")
    workroot.mkdir(mode=0o700)
    evidence_input = args.evidence or (workroot / "manifest.txt")
    if not evidence_input.is_absolute():
        fail("evidence must be the exact WORKROOT/manifest.txt authority")
    evidence = evidence_input.parent.resolve(strict=True) / evidence_input.name
    if evidence != workroot / "manifest.txt":
        fail("evidence must be the exact WORKROOT/manifest.txt authority")

    temporary = Path(tempfile.mkdtemp(prefix="runtime-", dir=workroot))
    process: subprocess.Popen[bytes] | None = None
    vfkit_client: socket.socket | None = None
    qemu_client: socket.socket | None = None
    forced_termination = False
    unexpected_status: int | None = None
    ingress = b""
    reply = b""
    try:
        vfkit_path = temporary / "vfkit.sock"
        vfkit_client_path = temporary / "vfkit-client.sock"
        qemu_path = temporary / "qemu.sock"
        api_path = temporary / "api.sock"
        process = subprocess.Popen(
            [
                str(binary),
                "-mtu", str(args.mtu),
                "-listen-vfkit", f"unixgram://{vfkit_path}",
                "-listen-qemu", f"unix://{qemu_path}",
                "-listen", f"unix://{api_path}",
                "-ssh-port", "-1",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        wait_for_paths(process, [vfkit_path, qemu_path], time.monotonic() + 5)
        for socket_path in (vfkit_path, qemu_path):
            socket_status = socket_path.stat()
            if not stat.S_ISSOCK(socket_status.st_mode) or socket_status.st_uid != os.getuid():
                fail("gvproxy published a missing, indirect, or foreign-owned switch socket")

        vfkit_client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        vfkit_client.bind(str(vfkit_client_path))
        vfkit_client.connect(str(vfkit_path))
        vfkit_client.settimeout(3)
        vfkit_client.send(frame(BRIDGE_MAC, GUEST_MAC, b"learn-guest"))

        qemu_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        qemu_client.connect(str(qemu_path))
        time.sleep(0.05)

        ingress = frame(GUEST_MAC, BRIDGE_MAC, b"lan-to-guest")
        send_qemu_frame(qemu_client, ingress)
        try:
            actual_ingress = vfkit_client.recv(65536)
        except TimeoutError:
            fail("timed out waiting for LAN-to-guest Ethernet frame")
        if actual_ingress != ingress:
            fail("LAN-to-guest Ethernet frame changed in transit")

        reply = frame(BRIDGE_MAC, GUEST_MAC, b"guest-to-lan")
        vfkit_client.send(reply)
        receive_qemu_frame(qemu_client, reply, "guest-to-LAN Ethernet frame")
    finally:
        if vfkit_client is not None:
            vfkit_client.close()
        if qemu_client is not None:
            qemu_client.close()
        if process is not None:
            unexpected_status = process.poll()
            if unexpected_status is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    forced_termination = True
                    process.kill()
                    process.wait(timeout=2)
        shutil.rmtree(temporary, ignore_errors=True)

    if unexpected_status is not None:
        fail(f"gvproxy exited before teardown with status {unexpected_status}")
    if forced_termination:
        fail("gvproxy did not terminate within two seconds of SIGTERM")
    release_qualifying = args.release_candidate and build_sha == PINNED_SHA256
    evidence.write_text(
        "\n".join(
            [
                "schema=3",
                "status=PASS",
                f"source_commit={args.source_commit}",
                f"gvproxy_sha256={actual_sha}",
                f"gvproxy_build_sha256={build_sha}",
                f"provenance_sha256={provenance_sha}",
                f"gvproxy_version={PINNED_VERSION}",
                f"mtu={args.mtu}",
                "transport=qemu-unix-stream",
                "same_user_switch_sockets=PASS",
                "graceful_helper_shutdown=PASS",
                "lan_to_guest=PASS",
                "guest_to_lan=PASS",
                f"frame_contract_sha256={hashlib.sha256(ingress + reply).hexdigest()}",
                f"release_qualifying={str(release_qualifying).lower()}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    evidence.chmod(0o600)
    print(f"gvproxy QEMU switch gate: PASS ({evidence})")


if __name__ == "__main__":
    main()
