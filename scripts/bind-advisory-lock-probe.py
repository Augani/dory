#!/usr/bin/env python3
"""Container-side worker for the exact bind-mount advisory-lock gate."""

import errno
import fcntl
import os
from pathlib import Path
import sys
import time


def marker(name: str) -> Path:
    return Path("/shared") / name


def wait_for(name: str, timeout: float = 120.0) -> None:
    deadline = time.monotonic() + timeout
    path = marker(name)
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for {path}")


def acquire(file_object, family: str, mode: str, blocking: bool, start: int, length: int) -> None:
    operation = fcntl.LOCK_SH if mode == "shared" else fcntl.LOCK_EX
    if not blocking:
        operation |= fcntl.LOCK_NB
    if family == "flock":
        fcntl.flock(file_object.fileno(), operation)
    elif family == "record":
        fcntl.lockf(file_object.fileno(), operation, length, start, os.SEEK_SET)
    else:
        raise ValueError(f"unsupported lock family: {family}")


def unlock(file_object, family: str, start: int, length: int) -> None:
    if family == "flock":
        fcntl.flock(file_object.fileno(), fcntl.LOCK_UN)
    else:
        fcntl.lockf(file_object.fileno(), fcntl.LOCK_UN, length, start, os.SEEK_SET)


def opened(path: str):
    return open(Path("/shared") / path, "a+b", buffering=0)


def main() -> int:
    if sys.argv[1:] == ["create-mode-zero"]:
        path = marker("mode-zero/create-excl.lock")
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDONLY, 0)
        os.close(descriptor)
        if path.stat().st_mode & 0o7777 != 0:
            raise RuntimeError("O_CREAT mode 0000 was not preserved")
        path.unlink()
        if path.exists():
            raise RuntimeError("mode-0000 file survived explicit unlink")
        return 0

    command, family, path, mode, start_text, length_text, token = sys.argv[1:8]
    start, length = int(start_text), int(length_text)
    with opened(path) as file_object:
        if command == "try":
            try:
                acquire(file_object, family, mode, False, start, length)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    return 73
                raise
            unlock(file_object, family, start, length)
            return 0

        if command == "holder":
            acquire(file_object, family, mode, True, start, length)
            marker(f"{token}.ready").write_text("ready\n", encoding="utf-8")
            wait_for(f"{token}.release")
            unlock(file_object, family, start, length)
            return 0

        if command == "waiter":
            acquire(file_object, family, mode, True, start, length)
            marker(f"{token}.acquired").write_text("acquired\n", encoding="utf-8")
            unlock(file_object, family, start, length)
            return 0

        if command == "unlocked-holder":
            acquire(file_object, family, mode, True, start, length)
            unlock(file_object, family, start, length)
            marker(f"{token}.ready").write_text("ready\n", encoding="utf-8")
            wait_for(f"{token}.release")
            return 0

        if command == "upgrade-holder":
            if family != "flock" or mode != "shared":
                raise ValueError("upgrade-holder requires a shared flock")
            acquire(file_object, family, mode, True, start, length)
            marker(f"{token}.ready").write_text("ready\n", encoding="utf-8")
            wait_for(f"{token}.upgrade")
            try:
                acquire(file_object, family, "exclusive", False, start, length)
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                marker(f"{token}.blocked").write_text("blocked\n", encoding="utf-8")
            else:
                raise RuntimeError("exclusive upgrade unexpectedly succeeded with another shared owner")
            wait_for(f"{token}.retry")
            acquire(file_object, family, "exclusive", False, start, length)
            marker(f"{token}.upgraded").write_text("upgraded\n", encoding="utf-8")
            wait_for(f"{token}.release")
            unlock(file_object, family, start, length)
            return 0

    raise ValueError(f"unsupported command: {command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"bind advisory lock probe: {error}", file=sys.stderr)
        raise
