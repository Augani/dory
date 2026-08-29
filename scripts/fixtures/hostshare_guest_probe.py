#!/usr/bin/env python3
"""Guest-side probes for scripts/live-hostshare-integration.sh.

This file is copied into a fresh bind-mounted test directory by the host harness.  It deliberately
uses only Python's standard library so the live suite never installs packages in the guest.
"""

import ctypes
import errno
import hashlib
import json
import mmap
import os
import re
import select
import struct
import sys
import time
from pathlib import Path


ROOT = Path(os.environ.get("DORY_PROBE_ROOT", "/work"))


def fixed_payload(label: str, size: int = 4096) -> bytes:
    seed = (label + "\n").encode("utf-8")
    return (seed * ((size + len(seed) - 1) // len(seed)))[:size]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def wait_for(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.005)
    raise TimeoutError(f"timed out waiting for {path}")


def ready(message: str) -> None:
    print(message, flush=True)


def clean_probe() -> int:
    directory = ROOT / "clean"
    path = directory / "value.bin"
    result_path = directory / "result.json"
    initial = fixed_payload(os.environ["DORY_INITIAL_LABEL"])
    expected = fixed_payload(os.environ["DORY_EXPECTED_LABEL"])
    first = path.read_bytes()
    inode_before = path.stat().st_ino
    if first != initial:
        raise RuntimeError("clean probe did not observe the exact initial payload")
    ready("DORY_PROBE_READY clean")
    deadline = time.monotonic() + float(os.environ.get("DORY_PROBE_TIMEOUT", "15"))
    samples = 0
    last = first
    while time.monotonic() < deadline:
        last = path.read_bytes()
        samples += 1
        if last == expected:
            write_json(
                result_path,
                {
                    "initial_sha256": digest(first),
                    "observed_sha256": digest(last),
                    "inode_before": inode_before,
                    "inode_after": path.stat().st_ino,
                    "samples": samples,
                },
            )
            return 0
        time.sleep(0.005)
    write_json(
        result_path,
        {
            "error": "timeout",
            "last_sha256": digest(last),
            "samples": samples,
        },
    )
    return 1


def atomic_probe() -> int:
    directory = ROOT / "atomic"
    path = directory / "value.bin"
    result_path = directory / "result.json"
    original = fixed_payload(os.environ["DORY_ORIGINAL_LABEL"])
    dirty_prefix = os.environ["DORY_DIRTY_PREFIX"].encode("utf-8")
    replacement = fixed_payload(os.environ["DORY_REPLACEMENT_LABEL"])
    descriptor = os.open(path, os.O_RDWR)
    mapping = None
    try:
        initial = os.pread(descriptor, len(original), 0)
        if initial != original:
            raise RuntimeError("atomic probe did not observe the exact original payload")
        old_inode = os.fstat(descriptor).st_ino
        mapping = mmap.mmap(descriptor, len(original), access=mmap.ACCESS_WRITE)
        mapping[: len(dirty_prefix)] = dirty_prefix
        expected_old = dirty_prefix + original[len(dirty_prefix) :]
        ready("DORY_PROBE_READY atomic")
        timeout = float(os.environ.get("DORY_PROBE_TIMEOUT", "15"))
        wait_for(directory / "go", timeout)

        # Seeing `go` proves the host mutation is visible, but it is not an acknowledgement that
        # the earlier FSEvents reverse-invalidation batch has completed. Poll within the same hard
        # deadline for replacement identity + final old-inode nlink. At every intermediate sample,
        # the dirty old FD/mmap must remain exact and the path may contain only the old or new whole
        # payload—never mixed/corrupt bytes.
        started = time.monotonic()
        deadline = started + timeout
        samples = 0
        while True:
            samples += 1
            old_fd = os.pread(descriptor, len(original), 0)
            old_mapping = bytes(mapping[:])
            if old_fd != expected_old or old_mapping != expected_old:
                raise RuntimeError("atomic replacement changed the dirty old FD or mmap")
            fresh = path.read_bytes()
            if fresh not in (expected_old, replacement):
                raise RuntimeError("atomic replacement exposed a mixed or unexpected payload")
            old_stat = os.fstat(descriptor)
            fresh_stat = path.stat()
            if (
                fresh == replacement
                and fresh_stat.st_ino != old_inode
                and old_stat.st_nlink == 0
            ):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    "atomic replacement did not converge to fresh identity with old nlink=0"
                )
            time.sleep(0.005)
        write_json(
            result_path,
            {
                "old_fd_sha256": digest(old_fd),
                "old_mmap_sha256": digest(old_mapping),
                "expected_old_sha256": digest(expected_old),
                "fresh_sha256": digest(fresh),
                "expected_fresh_sha256": digest(replacement),
                "old_inode": old_inode,
                "old_inode_after": old_stat.st_ino,
                "fresh_inode": fresh_stat.st_ino,
                "old_nlink": old_stat.st_nlink,
                "samples": samples,
                "convergence_ms": round((time.monotonic() - started) * 1000, 3),
            },
        )
        return 0
    finally:
        if mapping is not None:
            mapping.close()
        os.close(descriptor)


def repeated_probe() -> int:
    directory = ROOT / "repeated"
    path = directory / "value.txt"
    result_path = directory / "result.json"
    stop_path = directory / "stop"
    pattern = re.compile(rb"^value-([0-9]{6})\n$")
    expected_final_version = int(os.environ["DORY_EXPECTED_FINAL_VERSION"])
    expected_final_payload = f"value-{expected_final_version:06d}\n"
    errors = []
    invalid = []
    violations = []
    samples = 0
    unique_inodes = set()
    inode_versions = {}
    observations = []
    last_version = None
    last_pair = None
    maximum_transitions = max(1024, (expected_final_version + 1) * 8 + 1024)

    def record_sample(phase: str):
        nonlocal samples, last_version, last_pair
        descriptor = os.open(path, os.O_RDONLY)
        try:
            data = os.read(descriptor, 128)
            status = os.fstat(descriptor)
        finally:
            os.close(descriptor)

        samples += 1
        inode = status.st_ino
        unique_inodes.add(inode)
        match = pattern.fullmatch(data)
        if match is None:
            invalid.append({"sample": samples, "phase": phase, "hex": data.hex()})
            return None

        version = int(match.group(1))
        prior_version = inode_versions.get(inode)
        if prior_version is None:
            inode_versions[inode] = version
        elif prior_version != version:
            violations.append(
                {
                    "kind": "inode_reused_for_different_payload",
                    "sample": samples,
                    "inode": inode,
                    "prior_version": prior_version,
                    "version": version,
                }
            )
        if last_version is not None and version < last_version:
            violations.append(
                {
                    "kind": "version_regression",
                    "sample": samples,
                    "prior_version": last_version,
                    "version": version,
                }
            )

        pair = (inode, version)
        if pair != last_pair:
            observations.append(
                {
                    "sample": samples,
                    "phase": phase,
                    "inode": inode,
                    "version": version,
                    "payload": data.decode("ascii").rstrip("\n"),
                }
            )
            last_pair = pair
            if len(observations) > maximum_transitions:
                violations.append(
                    {
                        "kind": "excessive_identity_transitions",
                        "sample": samples,
                        "limit": maximum_transitions,
                    }
                )
        last_version = version
        return {"inode": inode, "version": version, "payload": data.decode("ascii")}

    final_observation = None
    final_convergence_samples = 0
    try:
        initial = record_sample("initial")
        if initial is None or initial["version"] != 0:
            violations.append(
                {
                    "kind": "unexpected_initial_version",
                    "expected": 0,
                    "observed": None if initial is None else initial["version"],
                }
            )
    except OSError as error:
        errors.append(
            {
                "sample": samples,
                "phase": "initial",
                "errno": error.errno,
                "name": errno.errorcode.get(error.errno, "UNKNOWN"),
                "message": str(error),
            }
        )
    ready("DORY_PROBE_READY repeated")
    deadline = time.monotonic() + float(os.environ.get("DORY_PROBE_TIMEOUT", "20"))
    while (
        time.monotonic() < deadline
        and not stop_path.exists()
        and len(errors) + len(invalid) + len(violations) < 32
    ):
        try:
            record_sample("race")
        except OSError as error:
            errors.append(
                {
                    "sample": samples,
                    "phase": "race",
                    "errno": error.errno,
                    "name": errno.errorcode.get(error.errno, "UNKNOWN"),
                    "message": str(error),
                }
            )

    stopped = stop_path.exists()
    final_deadline = time.monotonic() + float(
        os.environ.get("DORY_FINAL_CONVERGENCE_TIMEOUT", "10")
    )
    while final_convergence_samples == 0 or (
        stopped
        and (final_observation is None or final_observation["version"] != expected_final_version)
        and time.monotonic() < final_deadline
        and len(errors) + len(invalid) + len(violations) < 32
    ):
        final_convergence_samples += 1
        try:
            final_observation = record_sample("final-convergence")
        except OSError as error:
            errors.append(
                {
                    "sample": samples,
                    "phase": "final-convergence",
                    "errno": error.errno,
                    "name": errno.errorcode.get(error.errno, "UNKNOWN"),
                    "message": str(error),
                }
            )
        if final_observation is not None and final_observation["version"] == expected_final_version:
            break
        time.sleep(0.005)
    if final_observation is None or final_observation["version"] != expected_final_version:
        violations.append(
            {
                "kind": "wrong_final_guest_payload",
                "expected_version": expected_final_version,
                "observed_version": (
                    None if final_observation is None else final_observation["version"]
                ),
            }
        )

    write_json(
        result_path,
        {
            "samples": samples,
            "unique_inode_count": len(unique_inodes),
            "observations": observations,
            "inode_versions": {str(inode): version for inode, version in inode_versions.items()},
            "errors": errors,
            "invalid_payloads": invalid,
            "violations": violations,
            "stopped": stopped,
            "expected_final_payload": expected_final_payload.rstrip("\n"),
            "final_payload": (
                None if final_observation is None else final_observation["payload"].rstrip("\n")
            ),
            "final_version": (
                None if final_observation is None else final_observation["version"]
            ),
            "final_inode": None if final_observation is None else final_observation["inode"],
            "final_convergence_samples": final_convergence_samples,
        },
    )
    return 0 if stopped and samples > 0 and not errors and not invalid and not violations else 1


def hardlink_probe() -> int:
    directory = ROOT / "hardlink"
    first = directory / "a.txt"
    second = directory / "b.txt"
    result_path = directory / "result.json"
    os.link(first, second)
    descriptor = os.open(first, os.O_RDONLY)
    try:
        initial_first = first.stat()
        initial_second = second.stat()
        ready("DORY_PROBE_READY hardlink-phase1")
        timeout = float(os.environ.get("DORY_PROBE_TIMEOUT", "15"))
        wait_for(directory / "go1", timeout)
        deadline = time.monotonic() + timeout
        after_first_unlink = second.stat()
        while after_first_unlink.st_nlink != 1 and time.monotonic() < deadline:
            time.sleep(0.005)
            after_first_unlink = second.stat()
        if after_first_unlink.st_nlink != 1:
            raise RuntimeError("surviving hard-link attributes did not converge to nlink=1")
        survivor = second.read_bytes()
        old_fd_after_first = os.pread(descriptor, 4096, 0)
        ready("DORY_PROBE_READY hardlink-phase2")
        wait_for(directory / "go2", timeout)
        deadline = time.monotonic() + timeout
        final_stat = os.fstat(descriptor)
        while (first.exists() or second.exists() or final_stat.st_nlink != 0) and time.monotonic() < deadline:
            time.sleep(0.005)
            final_stat = os.fstat(descriptor)
        if first.exists() or second.exists() or final_stat.st_nlink != 0:
            raise RuntimeError("final hard-link removal did not converge while the old fd remained open")
        old_fd_after_final = os.pread(descriptor, 4096, 0)
        write_json(
            result_path,
            {
                "initial_first_inode": initial_first.st_ino,
                "initial_second_inode": initial_second.st_ino,
                "initial_first_nlink": initial_first.st_nlink,
                "initial_second_nlink": initial_second.st_nlink,
                "after_first_unlink_nlink": after_first_unlink.st_nlink,
                "survivor_sha256": digest(survivor),
                "old_fd_after_first_sha256": digest(old_fd_after_first),
                "old_fd_after_final_sha256": digest(old_fd_after_final),
                "final_fd_inode": final_stat.st_ino,
                "final_fd_nlink": final_stat.st_nlink,
                "first_exists": first.exists(),
                "second_exists": second.exists(),
            },
        )
        return 0
    finally:
        os.close(descriptor)


def read_file(path: Path):
    return path.read_bytes().hex()


def write_file(path: Path):
    descriptor = os.open(path, os.O_WRONLY)
    try:
        return os.write(descriptor, b"ESCAPE-WRITE")
    finally:
        os.close(descriptor)


def create_file(path: Path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    return "created"


def attempt(results, group: str, operation: str, callback) -> None:
    key = f"{group}.{operation}"
    try:
        value = callback()
        results.append(
            {
                "key": key,
                "outcome": "succeeded",
                "expected_denial": False,
                "value": repr(value)[:512],
            }
        )
    except OSError as error:
        expected_errno = {
            errno.EACCES,
            errno.EPERM,
            errno.ENOENT,
            errno.ENOTDIR,
            errno.ESTALE,
            errno.EXDEV,
            errno.ELOOP,
        }
        results.append(
            {
                "key": key,
                "outcome": "os_error",
                "expected_denial": error.errno in expected_errno,
                "errno": error.errno,
                "name": errno.errorcode.get(error.errno, "UNKNOWN"),
                "message": str(error),
            }
        )
    except Exception as error:  # Preserve unexpected guest failures as evidence, but never success.
        results.append(
            {
                "key": key,
                "outcome": "unexpected_exception",
                "expected_denial": False,
                "errno": None,
                "name": type(error).__name__,
                "message": str(error),
            }
        )


def containment_matrix(results, group: str, base: Path, source_root: Path) -> None:
    attempt(results, group, "read", lambda: read_file(base / "read.txt"))
    attempt(results, group, "write", lambda: write_file(base / "write.txt"))
    attempt(results, group, "truncate", lambda: os.truncate(base / "truncate.txt", 0))
    attempt(results, group, "create", lambda: create_file(base / "created.txt"))
    attempt(results, group, "mkdir", lambda: os.mkdir(base / "created-directory"))
    attempt(results, group, "symlink", lambda: os.symlink("read.txt", base / "created-link"))
    attempt(
        results,
        group,
        "link_into",
        lambda: os.link(source_root / f"{group}-link-source.txt", base / "linked.txt"),
    )
    attempt(
        results,
        group,
        "rename_into",
        lambda: os.rename(source_root / f"{group}-rename-source.txt", base / "renamed.txt"),
    )
    attempt(
        results,
        group,
        "rename_out",
        lambda: os.rename(base / "rename-out.txt", source_root / f"{group}-escaped.txt"),
    )
    attempt(
        results,
        group,
        "link_out",
        lambda: os.link(base / "link-out.txt", source_root / f"{group}-escaped-link.txt"),
    )
    attempt(results, group, "unlink", lambda: os.unlink(base / "unlink.txt"))
    attempt(results, group, "rmdir", lambda: os.rmdir(base / "empty"))
    attempt(results, group, "readlink", lambda: os.readlink(base / "target-link"))
    attempt(results, group, "readdir", lambda: sorted(os.listdir(base)))


def containment_probe() -> int:
    directory = ROOT / "containment"
    results = []
    containment_matrix(results, "intermediate", directory / "intermediate", directory)

    moved = directory / "moved"
    # Prime all relevant dentries and the directory before the host moves this parent out of the
    # production share.  The live test then exercises cached HostFS node identities as well as fresh
    # pathname resolution.
    os.listdir(moved)
    for name in [
        "read.txt",
        "write.txt",
        "truncate.txt",
        "unlink.txt",
        "rename-out.txt",
        "link-out.txt",
        "target-link",
        "empty",
    ]:
        os.lstat(moved / name)
    with open(moved / "read.txt", "rb") as handle:
        handle.read()
    os.readlink(moved / "target-link")
    ready("DORY_PROBE_READY containment-moved")
    wait_for(Path("/tmp/dory-containment-go"), float(os.environ.get("DORY_PROBE_TIMEOUT", "15")))
    containment_matrix(results, "moved", moved, directory)
    write_json(directory / "result.json", {"operations": results})
    return 0 if results and all(item["expected_denial"] for item in results) else 1


IN_MODIFY = 0x00000002
IN_ATTRIB = 0x00000004
IN_CLOSE_WRITE = 0x00000008
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_NONBLOCK = 0x00000800
IN_CLOEXEC = 0x00080000
WATCH_MASK = (
    IN_MODIFY
    | IN_ATTRIB
    | IN_CLOSE_WRITE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
)
MASK_NAMES = [
    (IN_MODIFY, "MODIFY"),
    (IN_ATTRIB, "ATTRIB"),
    (IN_CLOSE_WRITE, "CLOSE_WRITE"),
    (IN_MOVED_FROM, "MOVED_FROM"),
    (IN_MOVED_TO, "MOVED_TO"),
    (IN_CREATE, "CREATE"),
    (IN_DELETE, "DELETE"),
    (IN_DELETE_SELF, "DELETE_SELF"),
    (IN_MOVE_SELF, "MOVE_SELF"),
]


def watch_semantics(directory: Path, sentinel: str):
    return {
        "modify": (directory / "modify.txt").read_text(encoding="utf-8") == sentinel + "\n",
        "create": (directory / "created.txt").read_text(encoding="utf-8") == sentinel + "\n",
        "delete": not (directory / "delete.txt").exists(),
        "rename_source_absent": not (directory / "rename-source.txt").exists(),
        "rename_destination": (directory / "rename-destination.txt").read_text(encoding="utf-8")
        == sentinel + "\n",
        "atomic": (directory / "atomic.txt").read_text(encoding="utf-8") == sentinel + "\n",
    }


def has_event(events, name: str, allowed_mask: int) -> bool:
    return any(item["name"] == name and item["mask"] & allowed_mask for item in events)


def watcher_probe() -> int:
    directory = ROOT / os.environ["DORY_WATCH_DIRECTORY"]
    result_path = ROOT / os.environ["DORY_WATCH_RESULT"]
    sentinel = os.environ["DORY_WATCH_SENTINEL"]
    # Keep positive dentries/node identities live before the host mutates them.  In particular,
    # FUSE_NOTIFY_DELETE can name a removed child only when the kernel and HostFS both know the old
    # identity; a directory watch alone does not guarantee those child lookups.
    for name in ["modify.txt", "delete.txt", "rename-source.txt", "atomic.txt"]:
        path = directory / name
        os.lstat(path)
        path.read_bytes()
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int
    descriptor = libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
    if descriptor < 0:
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value))
    try:
        watch = libc.inotify_add_watch(descriptor, os.fsencode(directory), WATCH_MASK)
        if watch < 0:
            value = ctypes.get_errno()
            raise OSError(value, os.strerror(value))
        events = []
        ready("DORY_PROBE_READY watcher")
        deadline = time.monotonic() + float(os.environ.get("DORY_PROBE_TIMEOUT", "20"))
        complete = False
        semantics = {}
        coverage = {}
        while time.monotonic() < deadline:
            readable, _, _ = select.select([descriptor], [], [], 0.2)
            if readable:
                try:
                    data = os.read(descriptor, 65536)
                except BlockingIOError:
                    data = b""
                offset = 0
                while offset + 16 <= len(data):
                    wd, mask, cookie, length = struct.unpack_from("iIII", data, offset)
                    offset += 16
                    raw_name = data[offset : offset + length]
                    offset += length
                    name = raw_name.split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
                    events.append(
                        {
                            "wd": wd,
                            "mask": mask,
                            "mask_names": [label for bit, label in MASK_NAMES if mask & bit],
                            "cookie": cookie,
                            "name": name,
                            "monotonic_ns": time.monotonic_ns(),
                        }
                    )
            try:
                semantics = watch_semantics(directory, sentinel)
            except (FileNotFoundError, OSError):
                semantics = {}
            coverage = {
                "modify": has_event(events, "modify.txt", IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE),
                "create": has_event(events, "created.txt", IN_CREATE | IN_MOVED_TO | IN_ATTRIB),
                "delete": has_event(events, "delete.txt", IN_DELETE | IN_MOVED_FROM),
                "rename_source": has_event(events, "rename-source.txt", IN_MOVED_FROM | IN_DELETE),
                "rename_destination": has_event(
                    events, "rename-destination.txt", IN_MOVED_TO | IN_CREATE | IN_ATTRIB
                ),
                "atomic": has_event(
                    events,
                    "atomic.txt",
                    IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO,
                ),
            }
            complete = bool(semantics) and all(semantics.values()) and all(coverage.values())
            if complete:
                break
        write_json(
            result_path,
            {
                "complete": complete,
                "sentinel": sentinel,
                "semantics": semantics,
                "coverage": coverage,
                "events": events,
            },
        )
        return 0 if complete else 1
    finally:
        os.close(descriptor)


def dirty_probe() -> int:
    path = ROOT / "dirty" / "value.bin"
    original = fixed_payload(os.environ["DORY_ORIGINAL_LABEL"])
    descriptor = os.open(path, os.O_RDWR)
    mapping = None
    try:
        if os.pread(descriptor, len(original), 0) != original:
            raise RuntimeError("dirty probe did not observe the exact original payload")
        mapping = mmap.mmap(descriptor, len(original), access=mmap.ACCESS_WRITE)
        marker = b"DORY-GUEST-DIRTY-"
        counter = 0
        mapping[: len(marker) + 16] = marker + b"0" * 16
        ready("DORY_PROBE_READY dirty-mmap")
        deadline = time.monotonic() + float(os.environ.get("DORY_DIRTY_LIFETIME", "180"))
        while time.monotonic() < deadline:
            encoded = f"{counter:016x}".encode("ascii")
            mapping[len(marker) : len(marker) + 16] = encoded
            counter += 1
            time.sleep(0.001)
        return 3
    finally:
        if mapping is not None:
            mapping.close()
        os.close(descriptor)


MODES = {
    "clean": clean_probe,
    "atomic": atomic_probe,
    "repeated": repeated_probe,
    "hardlink": hardlink_probe,
    "containment": containment_probe,
    "watcher": watcher_probe,
    "dirty": dirty_probe,
}


def main() -> int:
    if sys.flags.optimize != 0:
        print("guest probe refuses optimized Python because assertions would be disabled", file=sys.stderr)
        return 2
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        print(f"usage: {sys.argv[0]} {'|'.join(sorted(MODES))}", file=sys.stderr)
        return 2
    try:
        return MODES[sys.argv[1]]()
    except Exception as error:
        print(f"guest probe {sys.argv[1]} failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
