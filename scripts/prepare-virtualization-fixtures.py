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
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid
import zlib


CATALOG = Path(__file__).resolve().parent.parent / "Config/DoryVirtualizationGuestCandidates.json"
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
    before = file_stamp(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    process = subprocess.Popen(["tar", "-xOf", "/dev/fd/" + str(descriptor), "--", member],
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
                        require(size <= MAX_MEMBER_BYTES, "archive member exceeds byte limit")
                        yield chunk
        status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        require(status == 0, "tar member extraction failed: " + errors.decode("utf-8", "replace"))
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--list", action="store_true", help="list pinned IDs without downloading")
    parser.add_argument("--id", action="append", default=[], help="explicit artifact ID (repeatable)")
    parser.add_argument("--cache-directory", type=Path)
    parser.add_argument("--verify-only", action="store_true", help="require cached inputs; never download")
    parser.add_argument("--extract", action="store_true",
                        help="derive missing boot files from verified inputs; verify existing outputs")
    arguments = parser.parse_args(argv)
    if arguments.list:
        if arguments.id or arguments.cache_directory or arguments.verify_only or arguments.extract:
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
        results = []
        with Cache(arguments.cache_directory) as cache:
            for identity in arguments.id:
                results.append(prepare(by_id[identity], cache, arguments.verify_only, arguments.extract))
        print(json.dumps({"schemaVersion": 1, "kind": "virtualization-fixture-preparation",
                          "cacheDirectory": str(arguments.cache_directory.absolute()),
                          "qualification": "input integrity only; no guest boot or workload qualification",
                          "artifacts": results}, indent=2))
        return 0
    except (FixtureError, OSError, ValueError, zlib.error, subprocess.SubprocessError) as error:
        print("fixture preparation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
