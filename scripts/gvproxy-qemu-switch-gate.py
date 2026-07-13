#!/usr/bin/env python3
"""Prove the exact gvproxy gives Dory's LAN bridge an independent bidirectional L2 port."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time


PINNED_SHA256 = "bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0"
PINNED_VERSION = "gvproxy version v0.8.9-dory1"
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
    parser.add_argument(
        "--provenance",
        type=Path,
        help="signed-candidate provenance containing the pinned pre-signing verified_sha256",
    )
    parser.add_argument("--evidence", type=Path, help="optional key=value evidence output")
    args = parser.parse_args()

    binary = args.gvproxy.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        fail(f"not an executable file: {binary}")
    actual_sha = sha256(binary)
    if actual_sha != args.expected_sha256.lower():
        fail(f"SHA-256 mismatch (expected {args.expected_sha256.lower()}, got {actual_sha})")
    build_sha = actual_sha
    if args.provenance:
        if not args.provenance.is_file():
            fail(f"provenance is missing: {args.provenance}")
        values = [
            line.partition("=")[2].strip().lower()
            for line in args.provenance.read_text(encoding="utf-8").splitlines()
            if line.partition("=")[0] == "verified_sha256"
        ]
        if len(values) != 1:
            fail("provenance must contain exactly one verified_sha256")
        build_sha = values[0]
        if build_sha != PINNED_SHA256:
            fail(
                "reproducible-build SHA-256 mismatch "
                f"(expected {PINNED_SHA256}, got {build_sha})"
            )
    identity = subprocess.run(
        [str(binary), "-version"], check=False, capture_output=True, text=True, timeout=5
    )
    version = (identity.stdout + identity.stderr).strip().splitlines()
    if not version or version[0] != PINNED_VERSION:
        fail(f"unexpected version identity: {version[0] if version else 'no output'}")

    temporary = Path(tempfile.mkdtemp(prefix="dory-gvproxy-qemu-"))
    process: subprocess.Popen[bytes] | None = None
    vfkit_client: socket.socket | None = None
    qemu_client: socket.socket | None = None
    try:
        vfkit_path = temporary / "vfkit.sock"
        vfkit_client_path = temporary / "vfkit-client.sock"
        qemu_path = temporary / "qemu.sock"
        api_path = temporary / "api.sock"
        process = subprocess.Popen(
            [
                str(binary),
                "-mtu", "1500",
                "-listen-vfkit", f"unixgram://{vfkit_path}",
                "-listen-qemu", f"unix://{qemu_path}",
                "-listen", f"unix://{api_path}",
                "-ssh-port", "-1",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        wait_for_paths(process, [vfkit_path, qemu_path], time.monotonic() + 5)

        vfkit_client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        vfkit_client.bind(str(vfkit_client_path))
        vfkit_client.connect(str(vfkit_path))
        vfkit_client.settimeout(3)

        # The first datagram establishes vfkit's peer and learns the guest CAM entry.
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

        if args.evidence:
            args.evidence.parent.mkdir(parents=True, exist_ok=True)
            args.evidence.write_text(
                "\n".join(
                    [
                        "schema=2",
                        f"gvproxy_path={binary}",
                        f"gvproxy_sha256={actual_sha}",
                        f"gvproxy_build_sha256={build_sha}",
                        "transport=qemu-unix-stream",
                        "lan_to_guest=PASS",
                        "guest_to_lan=PASS",
                        "release_qualifying=true",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
        print("gvproxy QEMU switch gate: PASS (independent bidirectional L2 port)")
    finally:
        if vfkit_client is not None:
            vfkit_client.close()
        if qemu_client is not None:
            qemu_client.close()
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    main()
