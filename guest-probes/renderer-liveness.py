#!/usr/bin/env python3
"""Bounded guest CPU/memory/fsync witness; this is not a GPU workload or a release verdict."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time


def run(root, nonce, seconds):
    if not re.fullmatch(r"[0-9a-f]{32}", nonce) or not 1 <= seconds <= 7200:
        raise ValueError("invalid liveness challenge or lifetime")
    expected_root = Path("/var/lib/dory/qualification") / ("renderer-recovery-" + nonce)
    if root != expected_root:
        raise ValueError("witness directory is not the owned challenge directory")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(directory)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise RuntimeError("witness directory is not exclusively owned")
        memory = os.urandom(2 * 1024 * 1024)  # Never persisted; restarting cannot reconstruct it.
        memory_hash = hashlib.sha256(memory).hexdigest()
        payload = hashlib.sha256(nonce.encode("ascii")).digest() * 16384
        fd = os.open("durability.bin", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        with os.fdopen(fd, "r+b") as target:
            target.write(payload); target.flush(); os.fsync(target.fileno()); os.fsync(directory)
            pid = os.getpid()
            start_ticks = int(Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19])
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            source_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
            deadline, counter = time.monotonic() + seconds, 0
            while time.monotonic() < deadline:
                if hashlib.sha256(memory).hexdigest() != memory_hash:
                    raise RuntimeError("volatile memory changed")
                target.seek(0)
                if target.read(len(payload) + 1) != payload:
                    raise RuntimeError("durable bytes changed")
                target.seek(0); target.write(payload); target.flush(); os.fsync(target.fileno())
                counter += 1
                body = {"kind": "dev.dory.renderer-liveness", "schemaVersion": 1,
                        "nonce": nonce, "bootID": boot, "processID": pid,
                        "processStartTicks": start_ticks, "progressCounter": counter,
                        "memoryBytes": len(memory), "volatileMemorySHA256": memory_hash,
                        "payloadSHA256": hashlib.sha256(payload).hexdigest(),
                        "fileFsync": True, "directoryFsync": True, "sourceSHA256": source_hash}
                temporary = "progress-" + str(counter) + ".json"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
                with os.fdopen(fd, "wb") as output:
                    output.write((json.dumps(body, sort_keys=True, separators=(",", ":")) + "\n").encode())
                    output.flush(); os.fsync(output.fileno())
                os.rename(temporary, "progress.json", src_dir_fd=directory, dst_dir_fd=directory)
                os.fsync(directory)
                time.sleep(0.25)
    finally:
        os.close(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--seconds", type=int, required=True)
    args = parser.parse_args()
    run(args.root, args.nonce, args.seconds)
