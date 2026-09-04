#!/usr/bin/env python3
"""Fetch pinned guest candidates and derive verified boot inputs without booting them."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid
import zlib


CATALOG = Path(__file__).resolve().parent.parent / "Config/DoryVirtualizationGuestCandidates.json"
DIAGNOSTIC_DIRECTORY = Path(__file__).resolve().parent.parent / "guest/diagnostics/p02-minimal-userspace"
GLIBC_DIAGNOSTIC_DIRECTORY = DIAGNOSTIC_DIRECTORY.with_name("p02-glibc-userspace")
SYSTEMD_DIAGNOSTIC_DIRECTORY = DIAGNOSTIC_DIRECTORY.with_name("p02-systemd-userspace")
STRESS_DIAGNOSTIC_DIRECTORY = DIAGNOSTIC_DIRECTORY.with_name("p02-userspace-stress")
CHUNK_BYTES = 64 * 1024
MAX_DOWNLOAD_BYTES = 32 * 1024**3
MAX_MEMBER_BYTES = 512 * 1024**2
DOWNLOAD_TIMEOUT_SECONDS = 60 * 60
EXTRACTION_TIMEOUT_SECONDS = 180
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class FixtureError(Exception):
    pass


def require(condition, detail):
    if not condition:
        raise FixtureError(detail)


def safe_name(value):
    require(isinstance(value, str) and SAFE_NAME.fullmatch(value), "unsafe cache filename or ID")
    return value


def safe_member(value):
    require(isinstance(value, str) and len(value) <= 1024, "invalid archive member")
    require(value and not value.startswith(("/", "-")) and "\\" not in value,
            "unsafe archive member")
    require(all(part not in ("", ".", "..") for part in value.split("/")),
            "unsafe archive member")
    require(all(32 <= ord(char) < 127 for char in value), "unsafe archive member")
    return value


def bounded_integer(value, maximum, label, minimum=1):
    require(type(value) is int and minimum <= value <= maximum, "invalid " + label)
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate catalog key: " + key)
        result[key] = value
    return result


def read_catalog(path):
    with open(path, "rb") as source:
        raw = source.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "catalog exceeds 1 MiB")
    catalog = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(catalog, dict) and type(catalog.get("schemaVersion")) is int
            and catalog["schemaVersion"] == 1
            and catalog.get("kind") == "virtualization-guest-candidates", "unsupported catalog")
    artifacts = catalog.get("artifacts")
    require(isinstance(artifacts, list) and 0 < len(artifacts) <= 128, "invalid artifact list")
    ids, filenames = set(), set()
    for artifact in artifacts:
        require(isinstance(artifact, dict), "invalid artifact")
        identity = safe_name(artifact.get("id"))
        require(identity not in ids, "duplicate artifact ID: " + identity)
        ids.add(identity)
        require(isinstance(artifact.get("url"), str), "invalid artifact URL")
        url = urllib.parse.urlsplit(artifact["url"])
        require(url.scheme == "https" and url.hostname and not url.username
                and not url.password and not url.fragment, "artifact URL must be HTTPS")
        if "bytes" in artifact:
            bounded_integer(artifact["bytes"], MAX_DOWNLOAD_BYTES, "artifact bytes")
        extractions = artifact.get("extractions", [])
        require(isinstance(extractions, list) and len(extractions) <= 32, "invalid extraction list")
        for entry in [artifact] + extractions:
            require(isinstance(entry, dict), "invalid extraction recipe")
            filename = safe_name(entry.get("filename"))
            require(filename not in filenames, "duplicate cache filename: " + filename)
            filenames.add(filename)
            require(isinstance(entry.get("sha256"), str) and SHA256.fullmatch(entry["sha256"]),
                    "invalid SHA-256 for " + filename)
        for recipe in extractions:
            safe_member(recipe.get("member"))
            bounded_integer(recipe.get("maximumBytes"), MAX_MEMBER_BYTES, "extraction maximumBytes")
            require(recipe.get("compression") in (None, "gzip"), "unsupported extraction compression")
            if recipe.get("compression") == "gzip":
                bounded_integer(recipe.get("compressedOffset"), MAX_MEMBER_BYTES,
                                "compressedOffset", minimum=0)
            else:
                require("compressedOffset" not in recipe, "compressedOffset requires gzip")
    return artifacts


def file_stamp(descriptor):
    value = os.fstat(descriptor)
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


class Cache:
    def __init__(self, directory):
        self.path = Path(directory).absolute()
        self.path.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.descriptor)

    def open_verified(self, filename, digest, maximum, expected_bytes=None):
        safe_name(filename)
        try:
            descriptor = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=self.descriptor)
        except FileNotFoundError:
            return None
        try:
            metadata = os.fstat(descriptor)
            require(stat.S_ISREG(metadata.st_mode), "cache input is not a regular file: " + filename)
            before = file_stamp(descriptor)
            require(metadata.st_size <= maximum, "cached file exceeds byte limit: " + filename)
            require(expected_bytes is None or metadata.st_size == expected_bytes,
                    "cached file size differs: " + filename)
            actual, size = hashlib.sha256(), 0
            while True:
                chunk = os.read(descriptor, CHUNK_BYTES)
                if not chunk:
                    break
                size += len(chunk)
                require(size <= metadata.st_size, "cached file grew while hashing: " + filename)
                actual.update(chunk)
            require(file_stamp(descriptor) == before, "cached file changed while hashing: " + filename)
            require(actual.hexdigest() == digest, "cached SHA-256 differs; file preserved: " + filename)
            os.lseek(descriptor, 0, os.SEEK_SET)
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def publish(self, filename, digest, maximum, chunks, expected_bytes=None):
        """Write only a private temporary file; link publication cannot replace an existing name."""
        safe_name(filename)
        temporary = ".dory-fixture-" + uuid.uuid4().hex
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=self.descriptor)
        size, actual = 0, hashlib.sha256()
        try:
            with os.fdopen(descriptor, "wb") as target:
                for chunk in chunks:
                    require(len(chunk) <= CHUNK_BYTES, "producer exceeded streaming chunk limit")
                    size += len(chunk)
                    require(size <= maximum, "output exceeds byte limit: " + filename)
                    actual.update(chunk)
                    target.write(chunk)
                require(expected_bytes is None or size == expected_bytes,
                        "downloaded size differs: " + filename)
                require(actual.hexdigest() == digest, "output SHA-256 differs: " + filename)
                target.flush()
                os.fsync(target.fileno())
            try:
                os.link(temporary, filename, src_dir_fd=self.descriptor,
                        dst_dir_fd=self.descriptor, follow_symlinks=False)
            except FileExistsError as error:
                raise FixtureError("cache destination appeared; preserved: " + filename) from error
            os.fsync(self.descriptor)
            return size
        finally:
            # Closing the producer also terminates only our own tar process on a rejected stream.
            close = getattr(chunks, "close", None)
            try:
                if close is not None:
                    close()
            finally:
                os.unlink(temporary, dir_fd=self.descriptor)


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        require(urllib.parse.urlsplit(new_url).scheme == "https", "non-HTTPS artifact redirect")
        return super().redirect_request(request, response, code, message, headers, new_url)


def download_chunks(url, maximum):
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT_SECONDS
    opener = urllib.request.build_opener(HTTPSRedirects())
    with opener.open(url, timeout=30) as response:
        require(urllib.parse.urlsplit(response.url).scheme == "https", "non-HTTPS artifact response")
        length = response.headers.get("Content-Length")
        if length is not None:
            require(length.isdecimal() and int(length) <= maximum, "download exceeds byte limit")
        total = 0
        while True:
            require(time.monotonic() < deadline, "artifact download timed out")
            chunk = response.read(CHUNK_BYTES)
            if not chunk:
                return
            total += len(chunk)
            require(total <= maximum, "download exceeds byte limit")
            yield chunk


def tar_member_chunks(descriptor, member):
    """libarchive's tar can read ISO9660; -O streams data and never creates archive paths."""
    safe_member(member)
    yield from checked_member_chunks(descriptor,
        ["tar", "-xOf", "/dev/fd/" + str(descriptor), "--", member], MAX_MEMBER_BYTES)


def checked_member_chunks(descriptor, command, maximum):
    """Stream a selected member from an owned verified descriptor; never extract host paths."""
    before = file_stamp(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    process = subprocess.Popen(command,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, pass_fds=(descriptor,))
    errors, size = bytearray(), 0
    deadline = time.monotonic() + EXTRACTION_TIMEOUT_SECONDS
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "output")
            selector.register(process.stderr, selectors.EVENT_READ, "error")
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, "archive extraction timed out")
                for key, _ in selector.select(min(remaining, 1)):
                    chunk = os.read(key.fileobj.fileno(), CHUNK_BYTES)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif key.data == "error":
                        errors.extend(chunk[:max(0, 4096 - len(errors))])
                    else:
                        size += len(chunk)
                        require(size <= maximum, "archive member exceeds byte limit")
                        yield chunk
        status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        require(status == 0, "archive member extraction failed: " + errors.decode("utf-8", "replace"))
        require(file_stamp(descriptor) == before, "verified archive changed during extraction")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()
        process.stderr.close()


def extraction_chunks(descriptor, recipe):
    source = tar_member_chunks(descriptor, recipe["member"])
    try:
        if recipe.get("compression") != "gzip":
            yield from source
            return
        skip = recipe["compressedOffset"]
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        size = 0
        for chunk in source:
            if skip:
                skipped = min(skip, len(chunk))
                skip -= skipped
                chunk = chunk[skipped:]
            if not chunk or decoder.eof:
                continue
            while chunk:
                output = decoder.decompress(chunk, CHUNK_BYTES)
                size += len(output)
                require(size <= recipe["maximumBytes"], "decompressed output exceeds byte limit")
                if output:
                    yield output
                chunk = decoder.unconsumed_tail
                if decoder.eof:
                    break
        require(skip == 0 and decoder.eof, "truncated gzip payload at pinned offset")
        # zboot/bzImage may carry wrapper bytes after the one pinned gzip member. They are
        # drained above (checking tar success), not interpreted as an additional gzip member.
    finally:
        source.close()


def prepare(artifact, cache, verify_only=False, extract=False):
    maximum = artifact.get("bytes", MAX_DOWNLOAD_BYTES)
    descriptor = cache.open_verified(artifact["filename"], artifact["sha256"], maximum,
                                     artifact.get("bytes"))
    action = "verified-cache"
    if descriptor is None:
        require(not verify_only, "required cached input is missing: " + artifact["filename"])
        cache.publish(artifact["filename"], artifact["sha256"], maximum,
                      download_chunks(artifact["url"], maximum), artifact.get("bytes"))
        descriptor = cache.open_verified(artifact["filename"], artifact["sha256"], maximum,
                                         artifact.get("bytes"))
        require(descriptor is not None, "published artifact disappeared")
        action = "downloaded-verified"
    try:
        derived = []
        for recipe in artifact.get("extractions", []) if extract else []:
            existing = cache.open_verified(recipe["filename"], recipe["sha256"], recipe["maximumBytes"])
            if existing is not None:
                size = os.fstat(existing).st_size
                os.close(existing)
                derived_action = "verified-cache"
            else:
                size = cache.publish(recipe["filename"], recipe["sha256"], recipe["maximumBytes"],
                                     extraction_chunks(descriptor, recipe))
                derived_action = "extracted-verified"
            derived.append({"filename": recipe["filename"], "sha256": recipe["sha256"],
                            "bytes": size, "action": derived_action})
        return {"id": artifact["id"], "filename": artifact["filename"],
                "sha256": artifact["sha256"], "bytes": os.fstat(descriptor).st_size,
                "action": action, "extractions": derived}
    finally:
        os.close(descriptor)


def read_diagnostic_source(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= maximum,
                "diagnostic source is not a bounded regular file")
        before = file_stamp(descriptor)
        data = bytearray()
        while True:
            chunk = os.read(descriptor, CHUNK_BYTES)
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= maximum, "diagnostic source grew beyond limit")
        require(file_stamp(descriptor) == before, "diagnostic source changed while reading")
        return bytes(data)
    finally:
        os.close(descriptor)


def diagnostic_archive(descriptor, maximum):
    """Decode one pinned gzip member with a strict allocation bound; never extract host paths."""
    before = file_stamp(descriptor)
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    data = bytearray()
    while True:
        chunk = os.read(descriptor, CHUNK_BYTES)
        if not chunk:
            break
        require(not decoder.eof, "unexpected trailing diagnostic gzip data")
        while chunk:
            output = decoder.decompress(chunk, min(CHUNK_BYTES, maximum + 1 - len(data)))
            data.extend(output)
            require(len(data) <= maximum, "diagnostic archive exceeds expanded byte limit")
            chunk = decoder.unconsumed_tail
            require(not decoder.unused_data, "unexpected trailing diagnostic gzip data")
    require(decoder.eof, "truncated diagnostic gzip archive")
    require(file_stamp(descriptor) == before, "diagnostic archive changed while reading")
    return bytes(data)


def diagnostic_members(data, selected):
    """Read bounded newc entries. Symlinks, device nodes and hardlinks are never materialized."""
    offset, seen, members = 0, set(), {}
    while offset + 110 <= len(data):
        require(data[offset:offset + 6] == b"070701", "unsupported diagnostic cpio header")
        try:
            fields = [int(data[offset + 6 + index * 8:offset + 14 + index * 8], 16)
                      for index in range(13)]
        except ValueError as error:
            raise FixtureError("invalid diagnostic cpio integer") from error
        size, name_size = fields[6], fields[11]
        require(1 <= name_size <= 1024, "invalid diagnostic cpio name length")
        name_start = offset + 110
        name_end = name_start + name_size
        require(name_end <= len(data) and data[name_end - 1] == 0,
                "truncated diagnostic cpio name")
        try:
            name = data[name_start:name_end - 1].decode("ascii")
        except UnicodeError as error:
            raise FixtureError("non-ASCII diagnostic cpio name") from error
        body_start = (name_end + 3) & ~3
        body_end = body_start + size
        offset = (body_end + 3) & ~3
        require(offset <= len(data), "truncated diagnostic cpio body")
        if name == "TRAILER!!!":
            require(size == 0 and not any(data[offset:]), "unexpected diagnostic cpio trailer")
            require(set(members) == set(selected), "required diagnostic cpio members are missing")
            return members
        if name != ".":
            safe_member(name)
        require(name not in seen and len(seen) < 4096, "duplicate or excessive diagnostic cpio entries")
        seen.add(name)
        if name in selected:
            require(stat.S_ISREG(fields[1]) and fields[4] == 1,
                    "diagnostic binary must be a standalone regular file")
            members[name] = data[body_start:body_end]
    raise FixtureError("diagnostic cpio trailer is missing")


def diagnostic_cpio(init, members):
    """Uncompressed newc avoids compressor-version differences. All metadata is normalized."""
    entries = {name: (stat.S_IFDIR | 0o755, b"", 0, 0)
               for name in ("bin", "dev", "lib", "proc", "run", "sys", "tmp")}
    entries.update({
        "bin/busybox": (stat.S_IFREG | 0o755, members["usr/bin/busybox"], 0, 0),
        "bin/sh": (stat.S_IFLNK | 0o777, b"busybox", 0, 0),
        "lib/ld-musl-x86_64.so.1": (stat.S_IFREG | 0o755,
                                     members["usr/lib/ld-musl-x86_64.so.1"], 0, 0),
        "lib/libc.musl-x86_64.so.1": (stat.S_IFLNK | 0o777, b"ld-musl-x86_64.so.1", 0, 0),
        "dev/console": (stat.S_IFCHR | 0o600, b"", 5, 1),
        "dev/null": (stat.S_IFCHR | 0o666, b"", 1, 3),
        "dev/zero": (stat.S_IFCHR | 0o666, b"", 1, 5),
        "init": (stat.S_IFREG | 0o755, init, 0, 0),
    })
    output = bytearray()
    for inode, name in enumerate(sorted(entries) + ["TRAILER!!!"], 1):
        mode, body, major, minor = entries.get(name, (0, b"", 0, 0))
        encoded = name.encode("ascii") + b"\0"
        fields = [inode, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0,
                  len(body), 0, 0, major, minor, len(encoded), 0]
        output.extend(b"070701" + "".join(f"{value:08x}" for value in fields).encode("ascii"))
        output.extend(encoded)
        output.extend(b"\0" * (-len(output) % 4))
        output.extend(body)
        output.extend(b"\0" * (-len(output) % 4))
    output.extend(b"\0" * (-len(output) % 512))
    return bytes(output)


def prepare_diagnostic(artifact, cache, directory=DIAGNOSTIC_DIRECTORY):
    recipe_bytes = read_diagnostic_source(directory / "fixture.json", 64 * 1024)
    recipe = json.loads(recipe_bytes, object_pairs_hook=unique_object)
    require(isinstance(recipe, dict) and type(recipe.get("schemaVersion")) is int
            and recipe["schemaVersion"] == 1 and recipe.get("kind") == "p02-minimal-userspace"
            and recipe.get("architecture") == "x86_64", "unsupported diagnostic recipe")
    require(recipe.get("artifactID") == artifact["id"], "diagnostic recipe artifact differs")
    recipes = [entry for entry in artifact.get("extractions", [])
               if entry["filename"] == recipe.get("sourceFilename")]
    require(len(recipes) == 1 and recipes[0]["sha256"] == recipe.get("sourceSHA256"),
            "diagnostic source must match a pinned catalog extraction")
    kernels = [entry for entry in artifact.get("extractions", [])
               if entry["filename"] == recipe.get("kernelFilename")]
    require(len(kernels) == 1 and kernels[0]["sha256"] == recipe.get("kernelSHA256"),
            "diagnostic kernel must match a pinned catalog extraction")
    kernel = cache.open_verified(kernels[0]["filename"], kernels[0]["sha256"],
                                 kernels[0]["maximumBytes"])
    require(kernel is not None, "required diagnostic kernel is missing; use --extract")
    os.close(kernel)
    input_recipe = recipes[0]
    maximum = bounded_integer(recipe.get("maximumExpandedBytes"), 64 * 1024**2,
                              "diagnostic expanded byte limit")
    init = read_diagnostic_source(directory / "init", 64 * 1024)
    init_digest = hashlib.sha256(init).hexdigest()
    require(init_digest == recipe.get("initSHA256"), "diagnostic init source SHA-256 differs")
    expected_members = recipe.get("members")
    require(isinstance(expected_members, dict) and set(expected_members) == {
        "usr/bin/busybox", "usr/lib/ld-musl-x86_64.so.1"}, "unsupported diagnostic member set")
    descriptor = cache.open_verified(input_recipe["filename"], input_recipe["sha256"],
                                     input_recipe["maximumBytes"])
    require(descriptor is not None, "required diagnostic initramfs is missing; use --extract")
    try:
        members = diagnostic_members(diagnostic_archive(descriptor, maximum), expected_members)
    finally:
        os.close(descriptor)
    for name, data in members.items():
        require(hashlib.sha256(data).hexdigest() == expected_members[name],
                "diagnostic member SHA-256 differs: " + name)
        require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01"
                and int.from_bytes(data[18:20], "little") == 62,
                "diagnostic member is not ELF64 little-endian x86-64: " + name)
    output = diagnostic_cpio(init, members)
    output_digest = hashlib.sha256(output).hexdigest()
    require(output_digest == recipe.get("outputSHA256"), "diagnostic output SHA-256 differs")
    filename = safe_name(recipe.get("outputFilename"))

    def publish_verified(name, data, expected_digest):
        existing = cache.open_verified(name, expected_digest, len(data), len(data))
        if existing is not None:
            os.close(existing)
            return
        cache.publish(name, expected_digest, len(data),
                      (data[offset:offset + CHUNK_BYTES] for offset in range(0, len(data), CHUNK_BYTES)),
                      len(data))

    publish_verified(filename, output, output_digest)
    manifest = {
        "schemaVersion": 1, "kind": "p02-minimal-userspace-build", "architecture": "x86_64",
        "qualification": "archive integrity and deterministic construction only; guest has not executed",
        "sourceArtifactID": artifact["id"], "sourceArtifactSHA256": artifact["sha256"],
        "sourceFilename": input_recipe["filename"], "sourceSHA256": input_recipe["sha256"],
        "kernelFilename": recipe["kernelFilename"], "kernelSHA256": recipe["kernelSHA256"],
        "recipeSHA256": hashlib.sha256(recipe_bytes).hexdigest(), "initSHA256": init_digest,
        "builderSHA256": hashlib.sha256(read_diagnostic_source(Path(__file__), 1024**2)).hexdigest(),
        "members": expected_members, "outputFilename": filename,
        "outputSHA256": output_digest, "outputBytes": len(output),
        "format": "newc; sorted names; uid/gid/mtime zero; sequential inodes; 512-byte padded; uncompressed",
        "runUUIDSource": "exactly one canonical lowercase dory.pvh_run_id= value in /proc/cmdline",
    }
    manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_name = filename + ".manifest.json"
    publish_verified(manifest_name, manifest_bytes, manifest_digest)
    return {"filename": filename, "sha256": output_digest, "bytes": len(output),
            "manifestFilename": manifest_name, "manifestSHA256": manifest_digest,
            "qualification": manifest["qualification"]}


def elf_dependencies(data, allowed_runpaths=()):
    """Inspect file-backed ELF64 tables without executing an extracted guest program."""
    require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01"
            and int.from_bytes(data[18:20], "little") == 62, "not ELF64 little-endian x86-64")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phsize, count = struct.unpack_from("<HH", data, 54)
    require(phsize == 56 and 1 <= count <= 128 and phoff + count * phsize <= len(data),
            "invalid ELF program-header table")
    loads, dynamic, interpreter = [], None, None
    for index in range(count):
        kind, _, offset, address, _, size, memory_size, _ = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + index * phsize)
        require(offset + size <= len(data), "ELF segment extends beyond file")
        if kind == 1:
            require(size <= memory_size, "invalid ELF load segment")
            loads.append((address, offset, size))
        elif kind == 2:
            require(dynamic is None and size % 16 == 0, "invalid ELF dynamic table")
            dynamic = data[offset:offset + size]
        elif kind == 3:
            require(interpreter is None and 2 <= size <= 1024
                    and data[offset + size - 1] == 0, "invalid ELF interpreter")
            interpreter = data[offset:offset + size - 1].decode("ascii")
            require(interpreter.startswith("/"), "ELF interpreter must be absolute")
            safe_member(interpreter[1:])
    strings, needed_offsets, soname_offset, runpath = {}, [], None, None
    if dynamic is not None:
        terminated = False
        for offset in range(0, len(dynamic), 16):
            tag, value = struct.unpack_from("<qQ", dynamic, offset)
            if tag == 0:
                terminated = True
                break
            if tag == 1:
                needed_offsets.append(value)
            elif tag in (5, 10, 14, 29):
                require(tag != 29 or allowed_runpaths, "ELF search-path overrides are unsupported")
                require(tag not in strings, "duplicate ELF dynamic field")
                strings[tag] = value
            elif tag == 15:
                raise FixtureError("ELF search-path overrides are unsupported")
        require(terminated, "unterminated ELF dynamic table")
        if needed_offsets or 14 in strings or 29 in strings:
            require(5 in strings and 10 in strings and 0 < strings[10] <= len(data),
                    "missing ELF dynamic strings")
            candidates = [offset + strings[5] - address for address, offset, size in loads
                          if address <= strings[5] and strings[5] + strings[10] <= address + size]
            require(len(candidates) == 1, "ELF strings are not uniquely file-backed")
            table = data[candidates[0]:candidates[0] + strings[10]]

            def string_at(offset):
                require(offset < len(table), "ELF dynamic string offset exceeds table")
                end = table.find(b"\0", offset)
                require(end >= offset, "unterminated ELF dynamic string")
                return table[offset:end].decode("ascii")

            needed_offsets = [safe_name(string_at(offset)) for offset in needed_offsets]
            soname_offset = safe_name(string_at(strings[14])) if 14 in strings else None
            if 29 in strings:
                runpath = string_at(strings[29])
                require(runpath in allowed_runpaths and runpath.startswith("/"),
                        "ELF RUNPATH is not explicitly allowed")
                # A single literal absolute directory only: no loader tokens, relative paths or lists.
                require("$" not in runpath and ":" not in runpath, "unsafe ELF RUNPATH")
                safe_member(runpath[1:])
    require(len(set(needed_offsets)) == len(needed_offsets), "duplicate ELF dependency")
    return {"interpreter": interpreter, "needed": needed_offsets, "soname": soname_offset,
            **({"runpath": runpath} if runpath is not None else {})}


GLIBC_LINKS = {"bin/sh": "busybox", "lib": "usr/lib", "lib64": "usr/lib/x86_64-linux-gnu"}


def validate_glibc_closure(members, specifications):
    return validate_elf_closure(members, specifications, GLIBC_LINKS, ("bin/busybox", "sbin/poweroff"))


def validate_elf_closure(members, specifications, links, roots, allowed_runpaths=()):
    installed, observed = {}, {}
    for member, specification in specifications.items():
        destination = safe_member(specification["destination"])
        require(destination not in installed and destination not in links, "duplicate ELF guest destination")
        installed[destination] = member
        observed[member] = elf_dependencies(members[member], allowed_runpaths)
        require(observed[member] == specification.get("elf"), "ELF dependency pins differ: " + member)

    def resolve(path):
        for _ in range(8):
            parts = path.split("/")
            for count in range(1, len(parts) + 1):
                prefix = "/".join(parts[:count])
                if prefix in links:
                    target = links[prefix]
                    path = "/".join(([] if target.startswith("/") else parts[:count - 1])
                                    + [target.lstrip("/")] + parts[count:])
                    break
            else:
                return installed.get(path)
        raise FixtureError("guest symlink cycle")

    edges = {}
    for member, metadata in observed.items():
        dependencies = []
        if metadata["interpreter"]:
            dependency = resolve(metadata["interpreter"][1:])
            require(dependency is not None, "ELF interpreter is missing from closure")
            dependencies.append(dependency)
        for name in metadata["needed"]:
            directories = ["lib/x86_64-linux-gnu", "lib", "usr/lib/x86_64-linux-gnu", "usr/lib"]
            if metadata.get("runpath"):
                directories.insert(0, metadata["runpath"][1:])
            targets = {resolve(directory + "/" + name) for directory in directories}
            targets.discard(None)
            require(len(targets) == 1, "ELF dependency is missing or ambiguous: " + name)
            dependency = targets.pop()
            require(observed[dependency]["soname"] == name, "ELF dependency SONAME differs")
            dependencies.append(dependency)
        edges[member] = set(dependencies)
    pending = [resolve(root) for root in roots]
    require(None not in pending, "ELF workload and runtime entrypoints are required")
    reached = set()
    while pending:
        member = pending.pop()
        if member not in reached:
            reached.add(member)
            pending.extend(edges[member] - reached)
    require(reached == set(members), "unreferenced ELF outside minimal dependency closure")
    return observed


def glibc_diagnostic_cpio(init, members, specifications):
    entries = {name: (stat.S_IFREG | 0o755, members[member], 0, 0)
               for member, spec in specifications.items() for name in [spec["destination"]]}
    entries.update({name: (stat.S_IFLNK | 0o777, target.encode("ascii"), 0, 0)
                    for name, target in GLIBC_LINKS.items()})
    entries.update({"init": (stat.S_IFREG | 0o755, init, 0, 0),
                    "dev/console": (stat.S_IFCHR | 0o600, b"", 5, 1),
                    "dev/null": (stat.S_IFCHR | 0o666, b"", 1, 3),
                    "dev/zero": (stat.S_IFCHR | 0o666, b"", 1, 5)})
    directories = {"bin", "sbin", "dev", "proc", "run", "sys", "tmp"}
    return newc_archive(entries, directories)


def newc_archive(entries, directories):
    entries, directories = dict(entries), set(directories)
    for name in list(entries):
        safe_member(name)
        parts = name.split("/")
        directories.update("/".join(parts[:count]) for count in range(1, len(parts)))
    require(not directories.intersection(entries), "guest archive parent is not a directory")
    entries.update({name: (stat.S_IFDIR | 0o755, b"", 0, 0) for name in directories})
    output = bytearray()
    for inode, name in enumerate(sorted(entries) + ["TRAILER!!!"], 1):
        mode, body, major, minor = entries.get(name, (0, b"", 0, 0))
        encoded = name.encode("ascii") + b"\0"
        fields = [inode, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0,
                  len(body), 0, 0, major, minor, len(encoded), 0]
        output.extend(b"070701" + "".join(f"{value:08x}" for value in fields).encode("ascii"))
        output.extend(encoded)
        output.extend(b"\0" * (-len(output) % 4))
        output.extend(body)
        output.extend(b"\0" * (-len(output) % 4))
    output.extend(b"\0" * (-len(output) % 512))
    return bytes(output)


def prepare_glibc_diagnostic(artifact, cache, directory=GLIBC_DIAGNOSTIC_DIRECTORY):
    recipe_bytes = read_diagnostic_source(directory / "fixture.json", 64 * 1024)
    recipe = json.loads(recipe_bytes, object_pairs_hook=unique_object)
    require(isinstance(recipe, dict) and type(recipe.get("schemaVersion")) is int
            and recipe.get("schemaVersion") == 1 and recipe.get("kind") == "p02-glibc-userspace"
            and recipe.get("architecture") == "x86_64", "unsupported glibc diagnostic recipe")
    require(recipe.get("artifactID") == artifact["id"] and recipe.get("sourceSHA256") == artifact["sha256"],
            "glibc source must match pinned catalog artifact")
    source = recipe.get("squashfs")
    require(isinstance(source, dict), "invalid squashfs recipe")
    safe_member(source.get("member"))
    safe_name(source.get("filename"))
    require(isinstance(source.get("sha256"), str) and SHA256.fullmatch(source["sha256"]), "invalid squashfs SHA")
    size = bounded_integer(source.get("bytes"), MAX_MEMBER_BYTES, "squashfs byte limit")
    specs = recipe.get("members")
    require(isinstance(specs, dict) and 1 <= len(specs) <= 16, "invalid glibc member count")
    for name, spec in specs.items():
        safe_member(name)
        require(isinstance(spec, dict), "invalid glibc member recipe")
        safe_member(spec.get("destination"))
        bounded_integer(spec.get("bytes"), 8 * 1024**2, "glibc member byte limit")
        require(isinstance(spec.get("sha256"), str) and SHA256.fullmatch(spec["sha256"]), "invalid glibc member SHA")
    require(sum(spec["bytes"] for spec in specs.values()) <= 32 * 1024**2, "glibc closure exceeds byte limit")
    upstream = recipe.get("upstreamUserspace")
    require(isinstance(upstream, dict) and isinstance(upstream.get("libcBanner"), str)
            and upstream.get("libcMember") in specs, "invalid glibc version recipe")
    safe_name(recipe.get("outputFilename"))
    bounded_integer(recipe.get("outputBytes"), 33 * 1024**2, "glibc output byte limit")
    require(isinstance(recipe.get("runnerProtocol"), dict) and isinstance(recipe.get("limitations"), list),
            "missing glibc acceptance limits")
    init = read_diagnostic_source(directory / "init", 64 * 1024)
    require(hashlib.sha256(init).hexdigest() == recipe.get("initSHA256"), "glibc init source SHA differs")
    descriptor = cache.open_verified(source["filename"], source["sha256"], size, size)
    if descriptor is None:
        archive = cache.open_verified(artifact["filename"], artifact["sha256"],
                                      artifact.get("bytes", MAX_DOWNLOAD_BYTES), artifact.get("bytes"))
        require(archive is not None, "required cached glibc ISO is missing")
        try:
            cache.publish(source["filename"], source["sha256"], size,
                          tar_member_chunks(archive, source["member"]), size)
        finally:
            os.close(archive)
        descriptor = cache.open_verified(source["filename"], source["sha256"], size, size)
    require(descriptor is not None, "published squashfs disappeared")
    members = {}
    try:
        for name, spec in specs.items():
            chunks = checked_member_chunks(descriptor,
                ["unsquashfs", "-processors", "1", "-mem", "16M", "-cat",
                 "/dev/fd/" + str(descriptor), name], spec["bytes"])
            data = b"".join(chunks)
            require(len(data) == spec["bytes"] and hashlib.sha256(data).hexdigest() == spec["sha256"],
                    "glibc member size or SHA differs: " + name)
            members[name] = data
    finally:
        os.close(descriptor)
    observed = validate_glibc_closure(members, specs)
    banner = recipe["upstreamUserspace"]["libcBanner"].encode("ascii")
    require(banner in members[recipe["upstreamUserspace"]["libcMember"]], "actual glibc version banner differs")
    for key, destination in (("busybox", "bin/busybox"), ("shutdownBinaryUsage", "sbin/poweroff")):
        if key in upstream:
            require(isinstance(upstream[key], str), "invalid glibc tool identity")
            identity = upstream[key].encode("ascii")
            require(any(spec["destination"] == destination and identity in members[name]
                        for name, spec in specs.items()), "actual guest tool identity differs: " + key)
    output = glibc_diagnostic_cpio(init, members, specs)
    output_digest = hashlib.sha256(output).hexdigest()
    require(len(output) == recipe["outputBytes"] and output_digest == recipe.get("outputSHA256"),
            "glibc output size or SHA differs")
    filename = safe_name(recipe["outputFilename"])
    manifest = {"schemaVersion": 1, "kind": "p02-glibc-userspace-build", "architecture": "x86_64",
        "qualification": "archive integrity and deterministic construction only; guest has not executed",
        "sourceArtifactID": artifact["id"], "sourceArtifactSHA256": artifact["sha256"],
        "squashfs": source, "members": specs, "observedELFDependencies": observed,
        "upstreamUserspace": recipe["upstreamUserspace"],
        "recipeSHA256": hashlib.sha256(recipe_bytes).hexdigest(), "initSHA256": recipe["initSHA256"],
        "builderSHA256": hashlib.sha256(read_diagnostic_source(Path(__file__), 1024**2)).hexdigest(),
        "outputFilename": filename, "outputSHA256": output_digest, "outputBytes": len(output),
        "format": "newc; sorted names; uid/gid/mtime zero; sequential inodes; 512-byte padded; uncompressed",
        "runnerProtocol": recipe["runnerProtocol"], "limitations": recipe["limitations"]}
    manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_name = filename + ".manifest.json"
    for name, data, digest in ((filename, output, output_digest), (manifest_name, manifest_bytes, manifest_digest)):
        existing = cache.open_verified(name, digest, len(data), len(data))
        if existing is not None:
            os.close(existing)
        else:
            cache.publish(name, digest, len(data),
                          (data[offset:offset + CHUNK_BYTES] for offset in range(0, len(data), CHUNK_BYTES)), len(data))
    return {"filename": filename, "sha256": output_digest, "bytes": len(output),
            "manifestFilename": manifest_name, "manifestSHA256": manifest_digest,
            "qualification": manifest["qualification"]}


SYSTEMD_RUNPATH = "/usr/lib/x86_64-linux-gnu/systemd"
SYSTEMD_ROOTS = ("usr/lib/systemd/systemd", "usr/lib/systemd/systemd-executor",
                 "usr/lib/systemd/systemd-shutdown", "bin/busybox")
SYSTEMD_LINKS = {**GLIBC_LINKS, "init": "usr/lib/systemd/systemd",
    "etc/os-release": "/usr/lib/os-release",
    "etc/systemd/system/default.target": "dory-diagnostic.target",
    # libsystemd-core has no RUNPATH of its own. This standard-directory alias also makes its
    # shared dependency independently resolvable, without relying on a parent's loader order.
    "usr/lib/x86_64-linux-gnu/libsystemd-shared-255.so": "systemd/libsystemd-shared-255.so"}
SYSTEMD_GUEST_FILES = {
    "common": ("usr/lib/dory/diagnostic-common", 0o644),
    "workload": ("usr/lib/dory/diagnostic-workload", 0o755),
    "receipt": ("usr/lib/dory/diagnostic-receipt", 0o755),
    "dory-diagnostic.service": ("etc/systemd/system/dory-diagnostic.service", 0o644),
    "dory-diagnostic.target": ("etc/systemd/system/dory-diagnostic.target", 0o644),
    "manager.conf": ("etc/systemd/system.conf", 0o644),
    "passwd": ("etc/passwd", 0o644), "group": ("etc/group", 0o644),
    "machine-id": ("etc/machine-id", 0o644)}


def systemd_diagnostic_cpio(local_files, members, specifications):
    require(set(local_files) == set(SYSTEMD_GUEST_FILES), "systemd local file set differs")
    entries = {name: (stat.S_IFLNK | 0o777, target.encode("ascii"), 0, 0)
               for name, target in SYSTEMD_LINKS.items()}
    for name, data in local_files.items():
        destination, mode = SYSTEMD_GUEST_FILES[name]
        entries[destination] = (stat.S_IFREG | mode, data, 0, 0)
    for member, spec in specifications.items():
        destination = safe_member(spec["destination"])
        require(destination not in entries, "duplicate systemd guest destination")
        require(type(spec.get("mode")) is int and spec["mode"] in (0o644, 0o755), "invalid guest file mode")
        entries[destination] = (stat.S_IFREG | spec["mode"], members[member], 0, 0)
    for name, major, minor, mode in (("console", 5, 1, 0o600), ("null", 1, 3, 0o666), ("zero", 1, 5, 0o666)):
        require("dev/" + name not in entries, "duplicate systemd device node")
        entries["dev/" + name] = (stat.S_IFCHR | mode, b"", major, minor)
    return newc_archive(entries, {"bin", "sbin", "dev", "proc", "run", "sys", "tmp", "root", "var", "var/log"})


def prepare_systemd_diagnostic(artifact, cache, directory=SYSTEMD_DIAGNOSTIC_DIRECTORY):
    recipe_bytes = read_diagnostic_source(directory / "fixture.json", 128 * 1024)
    recipe = json.loads(recipe_bytes, object_pairs_hook=unique_object)
    require(isinstance(recipe, dict) and type(recipe.get("schemaVersion")) is int
            and recipe.get("schemaVersion") == 1 and recipe.get("kind") == "p02-systemd-userspace"
            and recipe.get("architecture") == "x86_64", "unsupported systemd diagnostic recipe")
    require(recipe.get("artifactID") == artifact["id"] and recipe.get("sourceSHA256") == artifact["sha256"],
            "systemd source must match pinned catalog artifact")
    source = recipe.get("squashfs")
    require(isinstance(source, dict), "invalid squashfs recipe")
    safe_member(source.get("member"))
    safe_name(source.get("filename"))
    require(isinstance(source.get("sha256"), str) and SHA256.fullmatch(source["sha256"]), "invalid squashfs SHA")
    size = bounded_integer(source.get("bytes"), MAX_MEMBER_BYTES, "squashfs byte limit")
    specs, local_specs = recipe.get("members"), recipe.get("localFiles")
    require(isinstance(specs, dict) and 1 <= len(specs) <= 40, "invalid systemd member count")
    require(isinstance(local_specs, dict) and set(local_specs) == set(SYSTEMD_GUEST_FILES),
            "systemd local file set differs")
    for name, spec in specs.items():
        safe_member(name)
        require(isinstance(spec, dict), "invalid systemd member recipe")
        safe_member(spec.get("destination"))
        bounded_integer(spec.get("bytes"), 8 * 1024**2, "systemd member byte limit")
        require(type(spec.get("mode")) is int and spec["mode"] in (0o644, 0o755), "invalid guest file mode")
        require(isinstance(spec.get("sha256"), str) and SHA256.fullmatch(spec["sha256"]), "invalid systemd member SHA")
        require(spec["mode"] == (0o755 if "elf" in spec else 0o644), "systemd member mode differs from type")
    require(sum(spec["bytes"] for spec in specs.values()) <= 32 * 1024**2, "systemd closure exceeds byte limit")
    local_files = {}
    for name, spec in local_specs.items():
        require(isinstance(spec, dict), "invalid systemd local recipe")
        length = bounded_integer(spec.get("bytes"), 64 * 1024, "systemd local byte limit", minimum=0)
        data = read_diagnostic_source(directory / name, 64 * 1024)
        require(len(data) == length and hashlib.sha256(data).hexdigest() == spec.get("sha256"),
                "systemd local source size or SHA differs: " + name)
        local_files[name] = data
    require(recipe.get("allowedRUNPATH") == SYSTEMD_RUNPATH, "systemd RUNPATH policy differs")
    require(recipe.get("entrypoints") == list(SYSTEMD_ROOTS), "systemd runtime entrypoints differ")
    require(isinstance(recipe.get("runnerProtocol"), dict) and isinstance(recipe.get("limitations"), list),
            "missing systemd acceptance limits")
    identities = recipe.get("upstreamIdentities")
    require(isinstance(identities, dict) and identities and set(identities) <= set(specs),
            "invalid systemd upstream identity")
    require(all(isinstance(value, str) and 1 <= len(value) <= 1024 for value in identities.values()),
            "invalid upstream identity text")
    filename = safe_name(recipe.get("outputFilename"))
    bounded_integer(recipe.get("outputBytes"), 33 * 1024**2, "systemd output byte limit")
    require(isinstance(recipe.get("outputSHA256"), str) and SHA256.fullmatch(recipe["outputSHA256"]),
            "invalid systemd output SHA")
    descriptor = cache.open_verified(source["filename"], source["sha256"], size, size)
    if descriptor is None:
        archive = cache.open_verified(artifact["filename"], artifact["sha256"],
                                      artifact.get("bytes", MAX_DOWNLOAD_BYTES), artifact.get("bytes"))
        require(archive is not None, "required cached systemd ISO is missing")
        try:
            cache.publish(source["filename"], source["sha256"], size,
                          tar_member_chunks(archive, source["member"]), size)
        finally:
            os.close(archive)
        descriptor = cache.open_verified(source["filename"], source["sha256"], size, size)
    require(descriptor is not None, "published squashfs disappeared")
    members = {}
    try:
        for name, spec in specs.items():
            data = b"".join(checked_member_chunks(descriptor,
                ["unsquashfs", "-processors", "1", "-mem", "16M", "-cat",
                 "/dev/fd/" + str(descriptor), name], spec["bytes"]))
            require(len(data) == spec["bytes"] and hashlib.sha256(data).hexdigest() == spec["sha256"],
                    "systemd member size or SHA differs: " + name)
            require(data.startswith(b"\x7fELF") == ("elf" in spec), "systemd member ELF classification differs")
            members[name] = data
    finally:
        os.close(descriptor)
    elf_specs = {name: spec for name, spec in specs.items() if "elf" in spec}
    require(1 <= len(elf_specs) <= 32, "invalid systemd ELF count")
    observed = validate_elf_closure({name: members[name] for name in elf_specs}, elf_specs,
                                   SYSTEMD_LINKS, SYSTEMD_ROOTS, (SYSTEMD_RUNPATH,))
    for name, identity in identities.items():
        require(identity.encode("ascii") in members[name], "actual systemd upstream identity differs: " + name)
    output = systemd_diagnostic_cpio(local_files, members, specs)
    output_digest = hashlib.sha256(output).hexdigest()
    require(len(output) == recipe["outputBytes"] and output_digest == recipe["outputSHA256"],
            "systemd output size or SHA differs")
    manifest = {"schemaVersion": 1, "kind": "p02-systemd-userspace-build", "architecture": "x86_64",
        "qualification": "archive integrity and deterministic construction only; guest has not executed",
        "sourceArtifactID": artifact["id"], "sourceArtifactSHA256": artifact["sha256"],
        "squashfs": source, "members": specs, "localFiles": local_specs, "guestLinks": SYSTEMD_LINKS,
        "entrypoints": list(SYSTEMD_ROOTS), "allowedRUNPATH": SYSTEMD_RUNPATH,
        "observedELFDependencies": observed, "upstreamIdentities": identities,
        "recipeSHA256": hashlib.sha256(recipe_bytes).hexdigest(),
        "builderSHA256": hashlib.sha256(read_diagnostic_source(Path(__file__), 1024**2)).hexdigest(),
        "outputFilename": filename, "outputSHA256": output_digest, "outputBytes": len(output),
        "format": "newc; sorted names; uid/gid/mtime zero; sequential inodes; 512-byte padded; uncompressed",
        "runnerProtocol": recipe["runnerProtocol"], "limitations": recipe["limitations"]}
    manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_name = filename + ".manifest.json"
    # Check both existing records before publishing either new record. Preserve mismatched provenance.
    publications = ((filename, output, output_digest), (manifest_name, manifest_bytes, manifest_digest))
    missing = []
    for name, data, digest in publications:
        existing = cache.open_verified(name, digest, len(data), len(data))
        if existing is not None:
            os.close(existing)
        else:
            missing.append((name, data, digest))
    for name, data, digest in missing:
        cache.publish(name, digest, len(data),
                      (data[offset:offset + CHUNK_BYTES] for offset in range(0, len(data), CHUNK_BYTES)), len(data))
    return {"filename": filename, "sha256": output_digest, "bytes": len(output),
            "manifestFilename": manifest_name, "manifestSHA256": manifest_digest,
            "qualification": manifest["qualification"]}


STRESS_WORKLOADS = ["stress.allocation_free", "stress.mmap_protection", "stress.process_exec_wait",
                   "stress.filesystem_roundtrip", "stress.compression_checksum",
                   "stress.package_unpack", "stress.monotonic_clock"]
STRESS_SOURCE_FILES = ("stress.c", "Makefile", "init")


def stress_static_elf(data, source_digest):
    """Inspect a supplied static Linux executable; never compile or execute guest bytes."""
    require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01" and data[7] in (0, 3)
            and struct.unpack_from("<HHI", data, 16) == (2, 62, 1),
            "stress binary must be ET_EXEC ELF64 little-endian x86-64")
    entry, phoff = struct.unpack_from("<QQ", data, 24)
    ehsize, phsize, count = struct.unpack_from("<HHH", data, 52)
    require(ehsize == 64 and phsize == 56 and 1 <= count <= 64
            and phoff >= 64 and phoff + count * phsize <= len(data), "invalid stress ELF headers")
    loads, executable_entry = [], False
    for index in range(count):
        kind, flags, offset, address, _, size, memory_size, alignment = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + index * phsize)
        require(kind not in (2, 3), "stress binary must have no dynamic table or interpreter")
        require(offset + size <= len(data), "stress ELF segment extends beyond file")
        if kind != 1:
            continue
        require(flags & ~7 == 0 and size <= memory_size <= 64 * 1024**2
                and address + memory_size < 2**64, "invalid stress ELF load segment")
        require(alignment in (0, 1) or (alignment <= 2**32 and alignment & (alignment - 1) == 0
                and address % alignment == offset % alignment), "invalid stress ELF alignment")
        if memory_size:
            require(all(address + memory_size <= start or end <= address for start, end in loads),
                    "overlapping stress ELF load segments")
            loads.append((address, address + memory_size))
        if flags & 1 and address <= entry < address + size:
            executable_entry = True
    require(loads and executable_entry, "stress ELF entry is not file-backed executable memory")
    require(isinstance(source_digest, str) and SHA256.fullmatch(source_digest)
            and source_digest.encode("ascii") in data, "stress ELF embedded source digest differs")
    return {"format": "ELF64 little-endian ET_EXEC x86-64", "entry": entry,
            "loadSegmentCount": len(loads), "staticNoInterpreterOrDynamicTable": True,
            "embeddedSourceSHA256": source_digest}


def stress_diagnostic_cpio(init, executable, members):
    entries = {
        "init": (stat.S_IFREG | 0o755, init, 0, 0),
        "bin/p02-userspace-stress": (stat.S_IFREG | 0o755, executable, 0, 0),
        "bin/busybox": (stat.S_IFREG | 0o755, members["usr/bin/busybox"], 0, 0),
        "bin/sh": (stat.S_IFLNK | 0o777, b"busybox", 0, 0),
        "lib/ld-musl-x86_64.so.1": (stat.S_IFREG | 0o755, members["usr/lib/ld-musl-x86_64.so.1"], 0, 0),
        "lib/libc.musl-x86_64.so.1": (stat.S_IFLNK | 0o777, b"ld-musl-x86_64.so.1", 0, 0),
        "dev/console": (stat.S_IFCHR | 0o600, b"", 5, 1),
        "dev/null": (stat.S_IFCHR | 0o666, b"", 1, 3),
        "dev/zero": (stat.S_IFCHR | 0o666, b"", 1, 5)}
    return newc_archive(entries, {"bin", "dev", "lib", "proc", "run", "sys", "tmp"})


def prepare_stress_diagnostic(artifact, cache, binary_path, build_path, directory=STRESS_DIAGNOSTIC_DIRECTORY):
    recipe_bytes = read_diagnostic_source(directory / "fixture.json", 64 * 1024)
    recipe = json.loads(recipe_bytes, object_pairs_hook=unique_object)
    require(isinstance(recipe, dict) and type(recipe.get("schemaVersion")) is int
            and recipe["schemaVersion"] == 1 and recipe.get("kind") == "p02-userspace-stress"
            and recipe.get("architecture") == "x86_64", "unsupported stress diagnostic recipe")
    require(recipe.get("artifactID") == artifact["id"], "stress diagnostic artifact differs")
    require(recipe.get("requiredWorkloads") == STRESS_WORKLOADS, "stress workload set differs")
    source_specs = recipe.get("localFiles")
    require(isinstance(source_specs, dict) and set(source_specs) == set(STRESS_SOURCE_FILES),
            "stress local source set differs")
    local_files = {}
    for name in STRESS_SOURCE_FILES:
        expected = source_specs[name]
        require(isinstance(expected, dict), "invalid stress local source recipe")
        size = bounded_integer(expected.get("bytes"), 256 * 1024, "stress local source bytes")
        data = read_diagnostic_source(directory / name, 256 * 1024)
        require(len(data) == size and hashlib.sha256(data).hexdigest() == expected.get("sha256"),
                "stress local source size or SHA differs: " + name)
        local_files[name] = data
    source_digest = hashlib.sha256(local_files["stress.c"] + local_files["Makefile"]).hexdigest()
    build_bytes = read_diagnostic_source(build_path, 64 * 1024)
    require(hashlib.sha256(build_bytes).hexdigest() == recipe.get("buildMetadataSHA256"),
            "stress build metadata SHA differs")
    build = json.loads(build_bytes, object_pairs_hook=unique_object)
    require(isinstance(build, dict) and type(build.get("schemaVersion")) is int
            and build["schemaVersion"] == 1 and build.get("kind") == "p02-userspace-stress-cross-build"
            and build.get("sourceSHA256") == source_digest, "stress build source identity differs")
    require(build.get("compiler") == {"name": "zig", "version": "0.15.2"}
            and build.get("target") == "x86_64-linux-musl" and build.get("cpu") == "baseline"
            and build.get("stripped") is True and build.get("executedGuestCode") is False,
            "stress build configuration differs")
    binary_spec = build.get("binary")
    require(isinstance(binary_spec, dict), "invalid stress binary record")
    maximum = bounded_integer(binary_spec.get("bytes"), 8 * 1024**2, "stress binary bytes")
    binary = read_diagnostic_source(binary_path, 8 * 1024**2)
    binary_digest = hashlib.sha256(binary).hexdigest()
    require(len(binary) == maximum and binary_digest == binary_spec.get("sha256"),
            "stress binary size or SHA differs")
    observed = stress_static_elf(binary, source_digest)
    inputs = {}
    for key in ("source", "kernel"):
        spec = recipe.get(key)
        require(isinstance(spec, dict), "invalid stress " + key + " recipe")
        matches = [item for item in artifact.get("extractions", [])
                   if item["filename"] == spec.get("filename") and item["sha256"] == spec.get("sha256")]
        require(len(matches) == 1, "stress " + key + " must match pinned catalog extraction")
        inputs[key] = matches[0]
    kernel = cache.open_verified(inputs["kernel"]["filename"], inputs["kernel"]["sha256"],
                                 inputs["kernel"]["maximumBytes"])
    require(kernel is not None, "required stress kernel is missing; use --extract")
    os.close(kernel)
    member_specs = recipe.get("members")
    require(isinstance(member_specs, dict) and set(member_specs) == {
        "usr/bin/busybox", "usr/lib/ld-musl-x86_64.so.1"}, "stress member set differs")
    maximum = bounded_integer(recipe.get("maximumExpandedBytes"), 64 * 1024**2, "stress expanded bytes")
    archive = cache.open_verified(inputs["source"]["filename"], inputs["source"]["sha256"],
                                  inputs["source"]["maximumBytes"])
    require(archive is not None, "required stress source is missing; use --extract")
    try:
        members = diagnostic_members(diagnostic_archive(archive, maximum), member_specs)
    finally:
        os.close(archive)
    for name, data in members.items():
        require(hashlib.sha256(data).hexdigest() == member_specs[name], "stress member SHA differs: " + name)
        require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01"
                and int.from_bytes(data[18:20], "little") == 62, "stress member is not x86-64 ELF")
    output = stress_diagnostic_cpio(local_files["init"], binary, members)
    output_digest = hashlib.sha256(output).hexdigest()
    expected_bytes = bounded_integer(recipe.get("outputBytes"), 12 * 1024**2, "stress output bytes")
    require(len(output) == expected_bytes and output_digest == recipe.get("outputSHA256"),
            "stress output size or SHA differs")
    filename = safe_name(recipe.get("outputFilename"))
    manifest = {"schemaVersion": 1, "kind": "p02-userspace-stress-build", "architecture": "x86_64",
        "qualification": "archive integrity and deterministic construction only; guest has not executed",
        "sourceArtifactID": artifact["id"], "sourceArtifactSHA256": artifact["sha256"],
        "source": recipe["source"], "kernel": recipe["kernel"], "members": member_specs,
        "localFiles": source_specs, "suppliedBuildMetadata": build,
        "buildMetadataSHA256": recipe["buildMetadataSHA256"], "observedStressELF": observed,
        "buildTrust": "Hashes and static ELF shape checked; supplied compiler provenance is not independently attested",
        "recipeSHA256": hashlib.sha256(recipe_bytes).hexdigest(),
        "builderSHA256": hashlib.sha256(read_diagnostic_source(Path(__file__), 1024**2)).hexdigest(),
        "outputFilename": filename, "outputSHA256": output_digest, "outputBytes": len(output),
        "requiredWorkloads": STRESS_WORKLOADS,
        "acceptance": "Fresh matching UUID, all seven workloads, child exit 0, and independent host ACPI S5 poweroff",
        "limitations": ["No guest execution by preparer", "Tmpfs does not qualify persistent block storage",
                        "No sustained device-backed network qualification"],
        "format": "newc; sorted names; uid/gid/mtime zero; sequential inodes; 512-byte padded; uncompressed"}
    manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_name = filename + ".manifest.json"
    # Preflight both existing records, so mismatched provenance cannot publish a new CPIO.
    missing = []
    for name, data, digest in ((filename, output, output_digest), (manifest_name, manifest_bytes, manifest_digest)):
        descriptor = cache.open_verified(name, digest, len(data), len(data))
        if descriptor is not None:
            os.close(descriptor)
        else:
            missing.append((name, data, digest))
    for name, data, digest in missing:
        cache.publish(name, digest, len(data),
                      (data[offset:offset + CHUNK_BYTES] for offset in range(0, len(data), CHUNK_BYTES)), len(data))
    return {"filename": filename, "sha256": output_digest, "bytes": len(output),
            "manifestFilename": manifest_name, "manifestSHA256": manifest_digest,
            "qualification": manifest["qualification"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--list", action="store_true", help="list pinned IDs without downloading")
    parser.add_argument("--id", action="append", default=[], help="explicit artifact ID (repeatable)")
    parser.add_argument("--cache-directory", type=Path)
    parser.add_argument("--verify-only", action="store_true", help="require cached inputs; never download")
    parser.add_argument("--extract", action="store_true",
                        help="derive missing boot files from verified inputs; verify existing outputs")
    parser.add_argument("--diagnostic-initramfs", action="store_true",
                        help="derive the pinned P02 x86-64 BusyBox/musl workload (requires --extract)")
    parser.add_argument("--glibc-diagnostic-initramfs", action="store_true",
                        help="derive the pinned P02 x86-64 BusyBox/glibc workload (requires --extract)")
    parser.add_argument("--systemd-diagnostic-initramfs", action="store_true",
                        help="derive pinned P02 x86-64 systemd PID 1 and supervised workloads (requires --extract)")
    parser.add_argument("--stress-diagnostic-initramfs", action="store_true",
                        help="derive pinned P02 stress workload from explicitly supplied verified static ELF")
    parser.add_argument("--stress-binary", type=Path, help="prebuilt static stress ELF; never compiled or executed here")
    parser.add_argument("--stress-build-metadata", type=Path, help="pinned stress cross-build JSON record")
    arguments = parser.parse_args(argv)
    if arguments.list:
        if (arguments.id or arguments.cache_directory or arguments.verify_only or arguments.extract
                or arguments.diagnostic_initramfs or arguments.glibc_diagnostic_initramfs
                or arguments.systemd_diagnostic_initramfs or arguments.stress_diagnostic_initramfs
                or arguments.stress_binary or arguments.stress_build_metadata):
            parser.error("--list cannot be combined with preparation options")
    elif not arguments.id or arguments.cache_directory is None:
        parser.error("preparation requires explicit --id and --cache-directory")
    try:
        artifacts = read_catalog(arguments.catalog)
        if arguments.list:
            print(json.dumps({"schemaVersion": 1, "artifacts": artifacts}, indent=2))
            return 0
        by_id = {artifact["id"]: artifact for artifact in artifacts}
        require(len(set(arguments.id)) == len(arguments.id), "duplicate requested artifact ID")
        require(all(identity in by_id for identity in arguments.id), "unknown requested artifact ID")
        require(sum((arguments.diagnostic_initramfs, arguments.glibc_diagnostic_initramfs,
                     arguments.systemd_diagnostic_initramfs, arguments.stress_diagnostic_initramfs)) <= 1,
                "select only one diagnostic initramfs")
        require(arguments.stress_diagnostic_initramfs or
                (arguments.stress_binary is None and arguments.stress_build_metadata is None),
                "stress binary and metadata require --stress-diagnostic-initramfs")
        if arguments.stress_diagnostic_initramfs:
            require(arguments.extract and arguments.id == ["alpine-virt-3.24.1-x86_64"]
                    and arguments.stress_binary is not None and arguments.stress_build_metadata is not None,
                    "stress diagnostic requires --extract, sole Alpine x86-64 ID, --stress-binary and --stress-build-metadata")
        if arguments.diagnostic_initramfs:
            require(arguments.extract and arguments.id == ["alpine-virt-3.24.1-x86_64"],
                    "diagnostic initramfs requires --extract and only --id alpine-virt-3.24.1-x86_64")
        if arguments.glibc_diagnostic_initramfs:
            require(arguments.extract and not arguments.diagnostic_initramfs
                    and arguments.id == ["ubuntu-server-24.04.4-x86_64"],
                    "glibc diagnostic initramfs requires --extract and only --id ubuntu-server-24.04.4-x86_64")
        if arguments.systemd_diagnostic_initramfs:
            require(arguments.extract and arguments.id == ["ubuntu-server-24.04.4-x86_64"],
                    "systemd diagnostic initramfs requires --extract and only --id ubuntu-server-24.04.4-x86_64")
        results = []
        diagnostic = None
        with Cache(arguments.cache_directory) as cache:
            for identity in arguments.id:
                results.append(prepare(by_id[identity], cache, arguments.verify_only, arguments.extract))
            if arguments.diagnostic_initramfs:
                diagnostic = prepare_diagnostic(by_id[arguments.id[0]], cache)
            if arguments.glibc_diagnostic_initramfs:
                diagnostic = prepare_glibc_diagnostic(by_id[arguments.id[0]], cache)
            if arguments.systemd_diagnostic_initramfs:
                diagnostic = prepare_systemd_diagnostic(by_id[arguments.id[0]], cache)
            if arguments.stress_diagnostic_initramfs:
                diagnostic = prepare_stress_diagnostic(by_id[arguments.id[0]], cache,
                    arguments.stress_binary, arguments.stress_build_metadata)
        print(json.dumps({"schemaVersion": 1, "kind": "virtualization-fixture-preparation",
                          "cacheDirectory": str(arguments.cache_directory.absolute()),
                          "qualification": "input integrity only; no guest boot or workload qualification",
                          "artifacts": results,
                          **({"diagnosticInitramfs": diagnostic} if diagnostic is not None else {})}, indent=2))
        return 0
    except (FixtureError, OSError, ValueError, zlib.error, subprocess.SubprocessError) as error:
        print("fixture preparation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
