#!/usr/bin/env python3
"""Offline integrity and cleanup tests for the pinned guest fixture preparer."""

import contextlib
import configparser
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "fixture_preparer", Path(__file__).with_name("prepare-virtualization-fixtures.py"))
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class FixturePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache_path = self.root / "cache"
        self.catalog_path = self.root / "catalog.json"

    def artifact(self, data=b"pinned artifact"):
        return {"id": "candidate", "url": "https://example.invalid/fixture.iso",
                "filename": "fixture.iso", "sha256": digest(data), "bytes": len(data)}

    def catalog(self, artifact):
        self.catalog_path.write_text(json.dumps({
            "schemaVersion": 1, "kind": "virtualization-guest-candidates", "artifacts": [artifact]}))
        return fixture.read_catalog(self.catalog_path)

    def archive(self, data, *, compressed=False, offset=0, trailing=b""):
        path = self.root / "source.tar"
        payload = b"X" * offset + gzip.compress(data) + trailing if compressed else data
        with tarfile.open(path, "w") as archive:
            info = tarfile.TarInfo("boot/kernel")
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        raw = path.read_bytes()
        artifact = self.artifact(raw)
        recipe = {"member": "boot/kernel", "filename": "kernel.raw",
                  "sha256": digest(data), "maximumBytes": max(1, len(data))}
        if compressed:
            recipe.update(compression="gzip", compressedOffset=offset)
        artifact["extractions"] = [recipe]
        self.cache_path.mkdir()
        (self.cache_path / artifact["filename"]).write_bytes(raw)
        self.catalog(artifact)
        return artifact

    def assert_clean(self, *expected):
        self.assertEqual(set(path.name for path in self.cache_path.iterdir()), set(expected))

    def test_download_verifies_before_publication_and_reuses_cache(self):
        data = b"pinned artifact"
        artifact = self.artifact(data)
        with fixture.Cache(self.cache_path) as cache:
            with mock.patch.object(fixture, "download_chunks", return_value=iter([data])) as download:
                result = fixture.prepare(artifact, cache)
                self.assertEqual(result["action"], "downloaded-verified")
                self.assertEqual(download.call_count, 1)
            with mock.patch.object(fixture, "download_chunks", side_effect=AssertionError("network")):
                self.assertEqual(fixture.prepare(artifact, cache, verify_only=True)["action"], "verified-cache")
        self.assertEqual((self.cache_path / "fixture.iso").read_bytes(), data)
        self.assert_clean("fixture.iso")

    def test_missing_verify_only_input_does_not_download(self):
        with fixture.Cache(self.cache_path) as cache:
            with mock.patch.object(fixture, "download_chunks", side_effect=AssertionError("network")):
                with self.assertRaisesRegex(fixture.FixtureError, "missing"):
                    fixture.prepare(self.artifact(), cache, verify_only=True)
        self.assert_clean()

    def test_altered_existing_cache_is_preserved(self):
        with fixture.Cache(self.cache_path) as cache:
            source = self.cache_path / "fixture.iso"
            source.write_bytes(b"altered artifact")
            with mock.patch.object(fixture, "download_chunks", side_effect=AssertionError("network")):
                with self.assertRaises(fixture.FixtureError):
                    fixture.prepare(self.artifact(), cache)
            self.assertEqual(source.read_bytes(), b"altered artifact")
        self.assert_clean("fixture.iso")

    def test_bad_or_oversized_download_leaves_no_published_or_temporary_file(self):
        for chunks in ([b"bad artifact!!!"], [b"x" * 100]):
            with self.subTest(chunks=chunks), fixture.Cache(self.cache_path) as cache:
                with mock.patch.object(fixture, "download_chunks", return_value=iter(chunks)):
                    with self.assertRaises(fixture.FixtureError):
                        fixture.prepare(self.artifact(), cache)
            self.assert_clean()

    def test_failed_producer_cleans_temporary_file(self):
        def fail():
            yield b"part"
            raise OSError("interrupted download")
        with fixture.Cache(self.cache_path) as cache:
            with mock.patch.object(fixture, "download_chunks", return_value=fail()):
                with self.assertRaisesRegex(OSError, "interrupted"):
                    fixture.prepare(self.artifact(), cache)
        self.assert_clean()

    def test_unsafe_names_and_members_reject_before_cache_creation(self):
        vectors = [("filename", "../outside"), ("filename", "/tmp/outside"),
                   ("filename", "nested/file"), ("filename", "a\\b"), ("filename", "-option"),
                   ("member", "../../outside"), ("member", "/absolute"),
                   ("member", "boot/../outside"), ("member", "boot//kernel"),
                   ("member", "boot/\nfile"), ("member", "--checkpoint-action=exec=bad")]
        for key, value in vectors:
            with self.subTest(key=key, value=value):
                artifact = self.artifact()
                artifact["extractions"] = [{"filename": "kernel.raw", "member": "boot/kernel",
                                            "sha256": "0" * 64, "maximumBytes": 1024}]
                if key == "filename":
                    artifact[key] = value
                else:
                    artifact["extractions"][0][key] = value
                with self.assertRaises(fixture.FixtureError):
                    self.catalog(artifact)
        self.assertFalse(self.cache_path.exists())

    def test_invalid_recipes_duplicate_names_and_non_https_urls_reject(self):
        mutations = [lambda a: a.update(url="http://example.invalid/file"),
                     lambda a: a.update(sha256="F" * 64),
                     lambda a: a.update(bytes=True),
                     lambda a: a.update(extractions=[{"filename": "fixture.iso", "member": "boot/kernel",
                                                       "sha256": "0" * 64, "maximumBytes": 3}]),
                     lambda a: a.update(extractions=[{"filename": "kernel.raw", "member": "boot/kernel",
                                                       "sha256": "0" * 64, "maximumBytes": 3,
                                                       "compression": "gzip", "compressedOffset": -1}])]
        for mutate in mutations:
            artifact = self.artifact()
            mutate(artifact)
            with self.assertRaises(fixture.FixtureError):
                self.catalog(artifact)

    def test_raw_extraction_and_pinned_gzip_offset_with_wrapper_trailer(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed):
                data = b"guest kernel\x00" * 20000
                artifact = self.archive(data, compressed=compressed, offset=37, trailing=b"wrapper trailer")
                with fixture.Cache(self.cache_path) as cache:
                    result = fixture.prepare(artifact, cache, verify_only=True, extract=True)
                    self.assertEqual(result["extractions"][0]["action"], "extracted-verified")
                    result = fixture.prepare(artifact, cache, verify_only=True, extract=True)
                    self.assertEqual(result["extractions"][0]["action"], "verified-cache")
                self.assertEqual((self.cache_path / "kernel.raw").read_bytes(), data)
                self.assert_clean("fixture.iso", "kernel.raw")
                for path in self.cache_path.iterdir():
                    path.unlink()
                self.cache_path.rmdir()

    def test_bad_extraction_hash_and_oversized_output_cleanup(self):
        artifact = self.archive(b"kernel bytes")
        for change in ({"sha256": "0" * 64}, {"maximumBytes": 2}):
            recipe = dict(artifact["extractions"][0], **change)
            with fixture.Cache(self.cache_path) as cache:
                with self.assertRaises(fixture.FixtureError):
                    fixture.prepare(dict(artifact, extractions=[recipe]), cache, True, True)
            self.assert_clean("fixture.iso")

    def test_truncated_gzip_and_decompression_bomb_cleanup(self):
        artifact = self.archive(b"A" * 200000, compressed=True, offset=10)
        recipe = dict(artifact["extractions"][0], maximumBytes=100)
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaisesRegex(fixture.FixtureError, "exceeds"):
                fixture.prepare(dict(artifact, extractions=[recipe]), cache, True, True)
        self.assert_clean("fixture.iso")
        # A raw tar member containing an incomplete gzip stream is still a valid, pinned archive.
        (self.cache_path / "fixture.iso").unlink()
        self.cache_path.rmdir()
        artifact = self.archive(gzip.compress(b"kernel")[:-4])
        artifact["extractions"][0].update(compression="gzip", compressedOffset=0,
                                          maximumBytes=100, sha256=digest(b"kernel"))
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaisesRegex(fixture.FixtureError, "truncated gzip"):
                fixture.prepare(artifact, cache, True, True)
        self.assert_clean("fixture.iso")

    def test_missing_member_and_offset_outside_member_cleanup(self):
        artifact = self.archive(b"short member")
        for change in ({"member": "boot/missing"},
                       {"compression": "gzip", "compressedOffset": 1000}):
            recipe = dict(artifact["extractions"][0], **change)
            with fixture.Cache(self.cache_path) as cache:
                with self.assertRaises(fixture.FixtureError):
                    fixture.prepare(dict(artifact, extractions=[recipe]), cache, True, True)
            self.assert_clean("fixture.iso")

    def test_bad_existing_extraction_is_not_replaced(self):
        artifact = self.archive(b"kernel")
        output = self.cache_path / "kernel.raw"
        output.write_bytes(b"bad")
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaises(fixture.FixtureError):
                fixture.prepare(artifact, cache, True, True)
        self.assertEqual(output.read_bytes(), b"bad")
        self.assert_clean("fixture.iso", "kernel.raw")

    def test_symlink_and_special_file_cache_inputs_are_rejected(self):
        self.cache_path.mkdir()
        outside = self.root / "outside"
        outside.write_bytes(b"pinned artifact")
        entry = self.cache_path / "fixture.iso"
        entry.symlink_to(outside)
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaises(OSError):
                fixture.prepare(self.artifact(), cache, True)
        entry.unlink()
        os.mkfifo(entry)
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaisesRegex(fixture.FixtureError, "regular file"):
                fixture.prepare(self.artifact(), cache, True)
        self.assertEqual(outside.read_bytes(), b"pinned artifact")

    def test_atomic_publication_does_not_replace_concurrent_destination(self):
        original = b"concurrent output"
        def chunks():
            (self.cache_path / "fixture.iso").write_bytes(original)
            yield b"pinned artifact"
        with fixture.Cache(self.cache_path) as cache:
            with self.assertRaisesRegex(fixture.FixtureError, "destination appeared"):
                cache.publish("fixture.iso", digest(b"pinned artifact"), 100, chunks())
        self.assertEqual((self.cache_path / "fixture.iso").read_bytes(), original)
        self.assert_clean("fixture.iso")

    def test_cli_requires_explicit_selection_and_lists_without_network(self):
        self.catalog(self.artifact())
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fixture.main(["--catalog", str(self.catalog_path), "--list"]), 0)
            with self.assertRaises(SystemExit) as raised:
                fixture.main(["--catalog", str(self.catalog_path)])
            self.assertEqual(raised.exception.code, 2)
            self.assertEqual(fixture.main(["--catalog", str(self.catalog_path), "--id", "unknown",
                                           "--cache-directory", str(self.cache_path)]), 1)
        self.assertFalse(self.cache_path.exists())


class DiagnosticInitramfsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "source"
        self.directory.mkdir()
        self.cache_path = self.root / "cache"
        self.cache_path.mkdir()
        self.init = b"#!/bin/sh\nprintf diagnostic-fixture-test\n"
        (self.directory / "init").write_bytes(self.init)
        elf = bytearray(64)
        elf[:7] = b"\x7fELF\x02\x01\x01"
        elf[18:20] = (62).to_bytes(2, "little")
        self.members = {"usr/bin/busybox": bytes(elf),
                        "usr/lib/ld-musl-x86_64.so.1": bytes(elf) + b"loader"}
        self.install_archive(list(self.members.items()))

    @staticmethod
    def cpio(entries, *, mode=0o100755, nlink=1):
        output = bytearray()
        for index, (name, body) in enumerate(entries + [("TRAILER!!!", b"")], 1):
            encoded = name.encode() + b"\0"
            fields = [index, mode, 0, 0, nlink, 123456, len(body), 0, 0, 0, 0, len(encoded), 0]
            output.extend(b"070701" + "".join(f"{value:08x}" for value in fields).encode())
            output.extend(encoded)
            output.extend(b"\0" * (-len(output) % 4))
            output.extend(body)
            output.extend(b"\0" * (-len(output) % 4))
        return bytes(output)

    def install_archive(self, entries):
        archive = gzip.compress(self.cpio(entries))
        (self.cache_path / "input.gz").write_bytes(archive)
        (self.cache_path / "kernel").write_bytes(b"pinned test kernel")
        self.artifact = {"id": "synthetic-parser-test", "sha256": digest(b"synthetic ISO"),
                         "extractions": [
                             {"filename": "input.gz", "sha256": digest(archive), "maximumBytes": len(archive)},
                             {"filename": "kernel", "sha256": digest(b"pinned test kernel"), "maximumBytes": 100}]}
        self.recipe = {
            "schemaVersion": 1, "kind": "p02-minimal-userspace", "architecture": "x86_64",
            "artifactID": self.artifact["id"], "sourceFilename": "input.gz", "sourceSHA256": digest(archive),
            "maximumExpandedBytes": 65536, "kernelFilename": "kernel",
            "kernelSHA256": digest(b"pinned test kernel"), "initSHA256": digest(self.init),
            "members": {name: digest(data) for name, data in self.members.items()},
            "outputFilename": "diagnostic.cpio", "outputSHA256": digest(fixture.diagnostic_cpio(self.init, self.members))}
        self.save_recipe()

    def save_recipe(self):
        (self.directory / "fixture.json").write_text(json.dumps(self.recipe))

    def prepare(self):
        with fixture.Cache(self.cache_path) as cache:
            return fixture.prepare_diagnostic(self.artifact, cache, self.directory)

    def test_reproducible_derivation_and_manifest_bind_exact_sources(self):
        first = self.prepare()
        output = (self.cache_path / first["filename"]).read_bytes()
        self.assertEqual(output, fixture.diagnostic_cpio(self.init, self.members))
        self.assertEqual(len(output) % 512, 0)
        manifest_bytes = (self.cache_path / first["manifestFilename"]).read_bytes()
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["initSHA256"], digest(self.init))
        self.assertEqual(manifest["sourceSHA256"], self.recipe["sourceSHA256"])
        self.assertEqual(manifest["members"], self.recipe["members"])
        self.assertEqual(first["manifestSHA256"], digest(manifest_bytes))
        self.assertIn("guest has not executed", manifest["qualification"])
        self.assertEqual(self.prepare(), first)

    def test_source_and_member_tampering_reject_before_publication(self):
        (self.directory / "init").write_bytes(self.init + b"changed")
        with self.assertRaisesRegex(fixture.FixtureError, "init source SHA"):
            self.prepare()
        (self.directory / "init").write_bytes(self.init)
        self.recipe["members"]["usr/bin/busybox"] = "0" * 64
        self.save_recipe()
        with self.assertRaisesRegex(fixture.FixtureError, "member SHA"):
            self.prepare()
        self.assertFalse((self.cache_path / "diagnostic.cpio").exists())

    def test_catalog_binding_and_missing_kernel_reject(self):
        self.recipe["sourceSHA256"] = "0" * 64
        self.save_recipe()
        with self.assertRaisesRegex(fixture.FixtureError, "pinned catalog"):
            self.prepare()
        self.recipe["sourceSHA256"] = self.artifact["extractions"][0]["sha256"]
        self.save_recipe()
        (self.cache_path / "kernel").unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "kernel is missing"):
            self.prepare()
        self.assertFalse((self.cache_path / "diagnostic.cpio").exists())

    def test_cpio_traversal_duplicates_links_and_truncation_reject(self):
        cases = [self.cpio([( "../outside", b"x")] + list(self.members.items())),
                 self.cpio(list(self.members.items()) * 2),
                 self.cpio(list(self.members.items()), mode=0o120777),
                 self.cpio(list(self.members.items()), nlink=2),
                 self.cpio(list(self.members.items()))[:-1]]
        for archive in cases:
            with self.subTest(length=len(archive)), self.assertRaises(fixture.FixtureError):
                fixture.diagnostic_members(archive, self.members)
        self.assertFalse((self.root / "outside").exists())

    def test_expanded_archive_bound_and_wrong_architecture_reject(self):
        self.recipe["maximumExpandedBytes"] = 110
        self.save_recipe()
        with self.assertRaisesRegex(fixture.FixtureError, "expanded byte limit"):
            self.prepare()
        self.recipe["maximumExpandedBytes"] = 65536
        self.members["usr/bin/busybox"] = b"not-an-ELF" * 8
        self.install_archive(list(self.members.items()))
        with self.assertRaisesRegex(fixture.FixtureError, "not ELF64"):
            self.prepare()
        self.assertFalse((self.cache_path / "diagnostic.cpio").exists())

    def test_existing_corrupt_output_is_preserved(self):
        target = self.cache_path / "diagnostic.cpio"
        target.write_bytes(b"retain this output")
        with self.assertRaises(fixture.FixtureError):
            self.prepare()
        self.assertEqual(target.read_bytes(), b"retain this output")
        self.assertFalse(any(path.name.startswith(".dory-fixture-") for path in self.cache_path.iterdir()))

    def test_guest_receipt_matches_runner_protocol_and_rejects_incomplete_workloads(self):
        source = (fixture.DIAGNOSTIC_DIRECTORY / "init").read_text()
        recipe = json.loads((fixture.DIAGNOSTIC_DIRECTORY / "fixture.json").read_text())
        runner = (fixture.DIAGNOSTIC_DIRECTORY.parents[2] /
                  "dory-core-swift/Tests/DoryMachinePCLinuxBootRunner/PVHBootRunnerSupport.swift").read_text()
        self.assertIn("dory.pvh_run_id=", source)
        self.assertIn("dory.pvh_run_id=", runner)
        self.assertNotIn("dory.run_uuid=", source)
        self.assertEqual(digest(source.encode()), recipe["initSHA256"])
        # Execute only this print-only function, never guest init's mount/kill/poweroff workload.
        body = source.split("\nemit_runner_receipt() {\n", 1)[1].split("\n}\n", 1)[0]
        command = 'run_uuid=$1; passed=$2; failed=$3\nemit_runner_receipt() {\n' + body + '\n}\nemit_runner_receipt\n'
        run_id = "ba947d6c-ddfc-4437-a164-b159f63ad299"
        expected = [name for name in recipe["expectedResults"] if name != "shutdown.request"]
        for passed, failed in [(7, 0), (6, 1), (6, 0), (8, 0), (7, 1)]:
            with self.subTest(passed=passed, failed=failed):
                reply = subprocess.run(["/bin/sh", "-c", command, "receipt-test", run_id,
                                        str(passed), str(failed)], check=True, capture_output=True, text=True)
                self.assertEqual(len(reply.stdout.splitlines()), 1)
                receipt = json.loads(reply.stdout)
                self.assertEqual(receipt["schemaVersion"], 1)
                self.assertEqual(receipt["doryPVHBoot"], "userspace-ready")
                self.assertEqual(receipt["runID"], run_id)
                self.assertIs(receipt["workloadsPassed"], passed == 7 and failed == 0)
                self.assertEqual(receipt["workloads"], expected if receipt["workloadsPassed"] else [])


class GlibcDiagnosticTests(unittest.TestCase):
    @staticmethod
    def elf(interpreter=None, needed=(), soname=None, banner=b"", *, runpath=None, path_tag=29):
        """Small synthetic ELF tables exercise inspection only; never execute these bytes."""
        output = bytearray(2048)
        output[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", output, 16, 3, 62, 1)
        struct.pack_into("<Q", output, 32, 64)
        struct.pack_into("<HHH", output, 52, 64, 56, 3 if interpreter else 2)
        struct.pack_into("<IIQQQQQQ", output, 64, 1, 4, 0, 0x400000, 0, len(output), len(output), 4096)
        strings = bytearray(b"\0")
        tags = []
        for name in needed:
            tags.append((1, len(strings)))
            strings.extend(name.encode() + b"\0")
        if soname:
            tags.append((14, len(strings)))
            strings.extend(soname.encode() + b"\0")
        if runpath is not None:
            tags.append((path_tag, len(strings)))
            strings.extend(runpath.encode() + b"\0")
        tags.extend([(5, 0x400400), (10, len(strings)), (0, 0)])
        for index, tag in enumerate(tags):
            struct.pack_into("<qQ", output, 512 + index * 16, *tag)
        struct.pack_into("<IIQQQQQQ", output, 120, 2, 4, 512, 0x400200, 0,
                         len(tags) * 16, len(tags) * 16, 8)
        output[1024:1024 + len(strings)] = strings
        output[1536:1536 + len(banner)] = banner
        if interpreter:
            encoded = interpreter.encode() + b"\0"
            output[256:256 + len(encoded)] = encoded
            struct.pack_into("<IIQQQQQQ", output, 176, 3, 4, 256, 0x400100, 0,
                             len(encoded), len(encoded), 1)
        return bytes(output)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "source"
        self.directory.mkdir()
        self.cache_path = self.root / "cache"
        self.cache_path.mkdir()
        self.init = b"#!/bin/sh\nprintf synthetic-fixture\n"
        (self.directory / "init").write_bytes(self.init)
        self.members = {"upstream/busybox": self.elf("/lib64/loader", ["libc.so.6"]),
                        "upstream/libc": self.elf(None, ["loader"], "libc.so.6", b"synthetic-glibc-banner"),
                        "upstream/loader": self.elf(None, (), "loader"),
                        "upstream/poweroff": self.elf("/lib64/loader", ["libc.so.6"])}
        destinations = ["bin/busybox", "usr/lib/x86_64-linux-gnu/libc.so.6",
                        "usr/lib/x86_64-linux-gnu/loader", "sbin/poweroff"]
        self.specs = {name: {"bytes": len(data), "sha256": digest(data), "destination": destination,
                             "elf": fixture.elf_dependencies(data)}
                      for (name, data), destination in zip(self.members.items(), destinations)}
        self.squashfs = b"synthetic pinned extractor input"
        (self.cache_path / "input.squashfs").write_bytes(self.squashfs)
        self.artifact = {"id": "parser-fixture", "sha256": digest(b"synthetic ISO"),
                         "filename": "input.iso", "bytes": 13}
        output = fixture.glibc_diagnostic_cpio(self.init, self.members, self.specs)
        self.recipe = {"schemaVersion": 1, "kind": "p02-glibc-userspace", "architecture": "x86_64",
                       "artifactID": self.artifact["id"], "sourceSHA256": self.artifact["sha256"],
                       "squashfs": {"member": "casper/input.squashfs", "filename": "input.squashfs",
                                    "bytes": len(self.squashfs), "sha256": digest(self.squashfs)},
                       "members": self.specs, "initSHA256": digest(self.init),
                       "outputFilename": "glibc.cpio", "outputSHA256": digest(output), "outputBytes": len(output),
                       "upstreamUserspace": {"libcMember": "upstream/libc", "libcBanner": "synthetic-glibc-banner"},
                       "runnerProtocol": {}, "limitations": ["synthetic inspection-only test"]}
        self.save_recipe()

    def save_recipe(self):
        (self.directory / "fixture.json").write_text(json.dumps(self.recipe))

    def prepare(self):
        def extract(descriptor, command, maximum):
            self.assertEqual(os.read(descriptor, len(self.squashfs)), self.squashfs)
            os.lseek(descriptor, 0, os.SEEK_SET)
            self.assertEqual(command[:6], ["unsquashfs", "-processors", "1", "-mem", "16M", "-cat"])
            self.assertEqual(maximum, len(self.members[command[-1]]))
            return iter([self.members[command[-1]]])
        with fixture.Cache(self.cache_path) as cache, mock.patch.object(fixture, "checked_member_chunks", extract):
            return fixture.prepare_glibc_diagnostic(self.artifact, cache, self.directory)

    def test_reproducible_archive_and_manifest_bind_observed_dependency_closure(self):
        first = self.prepare()
        self.assertEqual(self.prepare(), first)
        manifest = json.loads((self.cache_path / first["manifestFilename"]).read_text())
        self.assertEqual(manifest["observedELFDependencies"],
                         {name: fixture.elf_dependencies(data) for name, data in self.members.items()})
        self.assertEqual(manifest["squashfs"], self.recipe["squashfs"])
        self.assertEqual(manifest["members"], self.specs)
        self.assertIn("guest has not executed", manifest["qualification"])
        normal = (self.cache_path / "glibc.cpio").read_bytes()
        self.assertEqual(normal, fixture.glibc_diagnostic_cpio(self.init,
            dict(reversed(list(self.members.items()))), dict(reversed(list(self.specs.items())))))
        self.assertEqual(len(normal) % 512, 0)

    def test_elf_missing_interpreter_dependency_or_wrong_soname_rejects(self):
        for missing in ("upstream/loader", "upstream/libc"):
            with self.subTest(missing=missing), self.assertRaises(fixture.FixtureError):
                fixture.validate_glibc_closure({k: v for k, v in self.members.items() if k != missing},
                                              {k: v for k, v in self.specs.items() if k != missing})
        self.members["upstream/libc"] = self.elf(None, (), "other-libc.so")
        self.specs["upstream/libc"]["elf"] = fixture.elf_dependencies(self.members["upstream/libc"])
        with self.assertRaisesRegex(fixture.FixtureError, "SONAME"):
            fixture.validate_glibc_closure(self.members, self.specs)

    def test_elf_out_of_range_headers_strings_and_search_override_reject(self):
        valid = self.members["upstream/busybox"]
        mutations = [(32, "<Q", len(valid)), (64 + 32, "<Q", len(valid) + 1),
                     (512 + 8, "<Q", 0xffff), (512, "<q", 29)]
        for offset, encoding, value in mutations:
            data = bytearray(valid)
            struct.pack_into(encoding, data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(fixture.FixtureError):
                fixture.elf_dependencies(bytes(data))

    def test_corrupt_member_banner_or_catalog_binding_never_publishes_output(self):
        mutations = [lambda: self.recipe.update(sourceSHA256="0" * 64),
                     lambda: self.recipe["members"]["upstream/libc"].update(sha256="0" * 64),
                     lambda: self.recipe["upstreamUserspace"].update(libcBanner="wrong version")]
        original = json.dumps(self.recipe)
        for mutate in mutations:
            self.recipe = json.loads(original)
            mutate()
            self.save_recipe()
            with self.assertRaises(fixture.FixtureError):
                self.prepare()
            self.assertFalse((self.cache_path / "glibc.cpio").exists())

    def test_unsafe_extraction_path_destination_or_parent_collision_rejects(self):
        for key, value in [("destination", "../../outside"), ("destination", "bin"), ("bytes", -1)]:
            original = self.specs["upstream/busybox"][key]
            self.specs["upstream/busybox"][key] = value
            self.save_recipe()
            with self.subTest(key=key, value=value), self.assertRaises(fixture.FixtureError):
                self.prepare()
            self.specs["upstream/busybox"][key] = original
        self.assertFalse((self.root / "outside").exists())

    def test_corrupt_existing_archive_is_preserved(self):
        (self.cache_path / "glibc.cpio").write_bytes(b"retain previous record")
        with self.assertRaises(fixture.FixtureError):
            self.prepare()
        self.assertEqual((self.cache_path / "glibc.cpio").read_bytes(), b"retain previous record")
        self.assertFalse(any(path.name.startswith(".dory-fixture-") for path in self.cache_path.iterdir()))

    def test_streamed_member_limit_and_failed_extractor_reject(self):
        with fixture.Cache(self.cache_path) as cache:
            descriptor = cache.open_verified("input.squashfs", digest(self.squashfs), len(self.squashfs))
            try:
                for code in ["import os;os.write(1,b'x'*1025)", "raise SystemExit(3)"]:
                    with self.subTest(code=code), self.assertRaises(fixture.FixtureError):
                        list(fixture.checked_member_chunks(descriptor, [sys.executable, "-c", code], 1024))
            finally:
                os.close(descriptor)

    def test_glibc_workloads_share_runner_contract_and_use_unflagged_shutdown(self):
        source = (fixture.GLIBC_DIAGNOSTIC_DIRECTORY / "init").read_text()
        original = (fixture.DIAGNOSTIC_DIRECTORY / "init").read_text()
        recipe = json.loads((fixture.GLIBC_DIAGNOSTIC_DIRECTORY / "fixture.json").read_text())
        self.assertEqual(source, original.replace('"$BB" poweroff -f', '/sbin/poweroff').replace('musl', 'glibc'))
        self.assertEqual(digest(source.encode()), recipe["initSHA256"])
        self.assertIn("dory.pvh_run_id=", source)
        body = source.split("\nemit_runner_receipt() {\n", 1)[1].split("\n}\n", 1)[0]
        command = 'run_uuid=$1; passed=$2; failed=$3\nemit_runner_receipt() {\n' + body + '\n}\nemit_runner_receipt\n'
        run_id = "51c98ad0-a67b-4658-ac7e-81a779805823"
        for passed, failed in [(7, 0), (6, 0), (7, 1)]:
            reply = subprocess.run(["/bin/sh", "-c", command, "receipt-test", run_id,
                                    str(passed), str(failed)], check=True, capture_output=True, text=True)
            receipt = json.loads(reply.stdout)
            self.assertEqual(receipt["runID"], run_id)
            self.assertEqual(receipt["doryPVHBoot"], "userspace-ready")
            self.assertEqual(receipt["workloads"], recipe["expectedResults"][:-1] if passed == 7 and failed == 0 else [])
        self.assertIn("klibc", recipe["upstreamUserspace"]["shutdownRuntime"])

    def test_cli_glibc_selection_cannot_mix_or_replace_musl_fixture(self):
        cases = [["--id", "alpine-virt-3.24.1-x86_64", "--extract"],
                 ["--id", "ubuntu-server-24.04.4-x86_64"],
                 ["--id", "ubuntu-server-24.04.4-x86_64", "--extract", "--diagnostic-initramfs"]]
        for arguments in cases:
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fixture.main(arguments + ["--glibc-diagnostic-initramfs",
                    "--cache-directory", str(self.root / "unused-cache")]), 1)
        self.assertFalse((self.root / "unused-cache").exists())


class SystemdDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "source"
        self.directory.mkdir()
        self.cache_path = self.root / "cache"
        self.cache_path.mkdir()
        self.local = {name: (fixture.SYSTEMD_DIAGNOSTIC_DIRECTORY / name).read_bytes()
                      for name in fixture.SYSTEMD_GUEST_FILES}
        for name, data in self.local.items():
            (self.directory / name).write_bytes(data)
        self.members, self.specs = {}, {}
        definitions = [(root, GlibcDiagnosticTests.elf("/lib64/loader", ["shared.so"],
                        banner=b"synthetic-systemd", runpath=fixture.SYSTEMD_RUNPATH))
                       for root in fixture.SYSTEMD_ROOTS]
        definitions += [("usr/lib/x86_64-linux-gnu/shared.so", GlibcDiagnosticTests.elf(None, (), "shared.so")),
                        ("usr/lib/x86_64-linux-gnu/loader", GlibcDiagnosticTests.elf(None, (), "loader"))]
        for index, (destination, data) in enumerate(definitions):
            name = "upstream/member-" + str(index)
            self.members[name] = data
            self.specs[name] = {"destination": destination, "mode": 0o755, "bytes": len(data),
                                "sha256": digest(data),
                                "elf": fixture.elf_dependencies(data, (fixture.SYSTEMD_RUNPATH,))}
        self.squashfs = b"synthetic systemd extractor input"
        (self.cache_path / "input.squashfs").write_bytes(self.squashfs)
        self.artifact = {"id": "synthetic-systemd", "sha256": digest(b"synthetic ISO"),
                         "filename": "input.iso", "bytes": 13}
        output = fixture.systemd_diagnostic_cpio(self.local, self.members, self.specs)
        self.recipe = {"schemaVersion": 1, "kind": "p02-systemd-userspace", "architecture": "x86_64",
            "artifactID": self.artifact["id"], "sourceSHA256": self.artifact["sha256"],
            "squashfs": {"member": "casper/input.squashfs", "filename": "input.squashfs",
                         "bytes": len(self.squashfs), "sha256": digest(self.squashfs)},
            "entrypoints": list(fixture.SYSTEMD_ROOTS), "allowedRUNPATH": fixture.SYSTEMD_RUNPATH,
            "members": self.specs, "localFiles": {name: {"bytes": len(data), "sha256": digest(data)}
                                                   for name, data in self.local.items()},
            "upstreamIdentities": {"upstream/member-0": "synthetic-systemd"},
            "outputFilename": "systemd.cpio", "outputBytes": len(output), "outputSHA256": digest(output),
            "runnerProtocol": {}, "limitations": ["synthetic inspection-only test"]}
        self.save_recipe()

    def save_recipe(self):
        (self.directory / "fixture.json").write_text(json.dumps(self.recipe))

    def prepare(self):
        def extract(descriptor, command, maximum):
            self.assertEqual(command[:6], ["unsquashfs", "-processors", "1", "-mem", "16M", "-cat"])
            self.assertEqual(os.read(descriptor, len(self.squashfs)), self.squashfs)
            os.lseek(descriptor, 0, os.SEEK_SET)
            self.assertEqual(maximum, self.specs[command[-1]]["bytes"])
            return iter([self.members[command[-1]]])
        with fixture.Cache(self.cache_path) as cache, mock.patch.object(fixture, "checked_member_chunks", extract):
            return fixture.prepare_systemd_diagnostic(self.artifact, cache, self.directory)

    def test_runpath_requires_exact_opt_in_and_rejects_rpath_and_loader_tokens(self):
        data = GlibcDiagnosticTests.elf(runpath=fixture.SYSTEMD_RUNPATH)
        with self.assertRaisesRegex(fixture.FixtureError, "search-path"):
            fixture.elf_dependencies(data)
        self.assertEqual(fixture.elf_dependencies(data, (fixture.SYSTEMD_RUNPATH,))["runpath"],
                         fixture.SYSTEMD_RUNPATH)
        for value in ("", "$ORIGIN", "/usr/lib:$ORIGIN", "/usr/lib/../etc", "relative", "/other"):
            with self.subTest(value=value), self.assertRaises(fixture.FixtureError):
                fixture.elf_dependencies(GlibcDiagnosticTests.elf(runpath=value), (fixture.SYSTEMD_RUNPATH,))
        for value in ("$ORIGIN", "/usr/lib:$ORIGIN", "/usr/lib/../etc", "relative"):
            with self.subTest(explicit_unsafe=value), self.assertRaises(fixture.FixtureError):
                fixture.elf_dependencies(GlibcDiagnosticTests.elf(runpath=value), (value,))
        with self.assertRaises(fixture.FixtureError):
            fixture.elf_dependencies(GlibcDiagnosticTests.elf(runpath=fixture.SYSTEMD_RUNPATH, path_tag=15),
                                     (fixture.SYSTEMD_RUNPATH,))

    def test_archive_binds_real_init_link_all_runtime_roots_and_deterministic_metadata(self):
        first = self.prepare()
        self.assertEqual(first, self.prepare())
        output = (self.cache_path / first["filename"]).read_bytes()
        self.assertEqual(output, fixture.systemd_diagnostic_cpio(dict(reversed(list(self.local.items()))),
            dict(reversed(list(self.members.items()))), dict(reversed(list(self.specs.items())))))
        # Independent newc reader checks encoded metadata and payloads, not the builder's dictionary.
        offset, entries, inodes = 0, {}, []
        while True:
            self.assertEqual(output[offset:offset + 6], b"070701")
            fields = [int(output[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
            inode, mode, uid, gid, _, mtime, size, _, _, major, minor, namesize, checksum = fields
            offset += 110
            name = output[offset:offset + namesize - 1].decode()
            self.assertEqual(output[offset + namesize - 1], 0)
            offset = (offset + namesize + 3) & ~3
            body = output[offset:offset + size]
            offset = (offset + size + 3) & ~3
            self.assertEqual((uid, gid, mtime, checksum), (0, 0, 0, 0))
            inodes.append(inode)
            if name == "TRAILER!!!":
                break
            self.assertNotIn(name, entries)
            entries[name] = (mode, body, major, minor)
        self.assertEqual(inodes, list(range(1, len(inodes) + 1)))
        self.assertEqual(list(entries), sorted(entries))
        self.assertEqual(entries["init"], (stat.S_IFLNK | 0o777, b"usr/lib/systemd/systemd", 0, 0))
        for root in fixture.SYSTEMD_ROOTS:
            self.assertTrue(entries[root][1].startswith(b"\x7fELF"))
        self.assertEqual(entries["etc/systemd/system/default.target"][1], b"dory-diagnostic.target")
        self.assertEqual(entries["dev/console"], (stat.S_IFCHR | 0o600, b"", 5, 1))
        self.assertEqual(len(output) % 512, 0)
        self.assertFalse(any(output[offset:]))
        manifest = json.loads((self.cache_path / first["manifestFilename"]).read_text())
        self.assertEqual(manifest["entrypoints"], list(fixture.SYSTEMD_ROOTS))
        self.assertEqual(manifest["localFiles"], self.recipe["localFiles"])
        self.assertEqual(manifest["observedELFDependencies"], {n: s["elf"] for n, s in self.specs.items()})
        self.assertIn("guest has not executed", manifest["qualification"])

    def test_missing_executor_dependency_or_orphan_elf_rejects(self):
        for missing in ("upstream/member-1", "upstream/member-4", "upstream/member-5"):
            members = {n: d for n, d in self.members.items() if n != missing}
            specs = {n: s for n, s in self.specs.items() if n != missing}
            with self.subTest(missing=missing), self.assertRaises(fixture.FixtureError):
                fixture.validate_elf_closure(members, specs, fixture.SYSTEMD_LINKS, fixture.SYSTEMD_ROOTS,
                                             (fixture.SYSTEMD_RUNPATH,))
        data = GlibcDiagnosticTests.elf()
        self.members["orphan"] = data
        self.specs["orphan"] = {"destination": "usr/lib/orphan", "elf": fixture.elf_dependencies(data)}
        with self.assertRaisesRegex(fixture.FixtureError, "unreferenced"):
            fixture.validate_elf_closure(self.members, self.specs, fixture.SYSTEMD_LINKS, fixture.SYSTEMD_ROOTS,
                                         (fixture.SYSTEMD_RUNPATH,))

    def test_bad_source_pins_paths_modes_and_bounds_never_publish(self):
        mutations = [lambda r: r.update(sourceSHA256="0" * 64),
                     lambda r: r.update(allowedRUNPATH="/unreviewed"),
                     lambda r: r["entrypoints"].pop(),
                     lambda r: r["members"]["upstream/member-0"].update(sha256="0" * 64),
                     lambda r: r["members"]["upstream/member-0"].update(destination="../outside"),
                     lambda r: r["members"]["upstream/member-0"].update(destination="init"),
                     lambda r: r["members"]["upstream/member-0"].update(destination="usr/lib"),
                     lambda r: r["members"]["upstream/member-0"].update(mode=0o4755),
                     lambda r: r["members"]["upstream/member-0"].update(bytes=8 * 1024**2 + 1),
                     lambda r: r["localFiles"]["workload"].update(sha256="0" * 64),
                     lambda r: r["localFiles"].update({"../outside": {"bytes": 1, "sha256": "0" * 64}}),
                     lambda r: r["upstreamIdentities"].update({"upstream/member-0": "incorrect version"})]
        original = json.dumps(self.recipe)
        for mutation in mutations:
            self.recipe = json.loads(original)
            mutation(self.recipe)
            self.save_recipe()
            with self.subTest(recipe=self.recipe), self.assertRaises(fixture.FixtureError):
                self.prepare()
            self.assertFalse((self.cache_path / "systemd.cpio").exists())
        self.assertEqual({p.name for p in self.cache_path.iterdir()}, {"input.squashfs"})

    def test_missing_or_altered_sources_and_failed_extractor_preserve_cache(self):
        (self.cache_path / "input.squashfs").unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "missing"):
            self.prepare()
        (self.cache_path / "input.squashfs").write_bytes(b"altered")
        with self.assertRaises(fixture.FixtureError):
            self.prepare()
        self.assertEqual((self.cache_path / "input.squashfs").read_bytes(), b"altered")
        (self.cache_path / "input.squashfs").write_bytes(self.squashfs)
        self.members["upstream/member-0"] += b"oversized"
        with self.assertRaisesRegex(fixture.FixtureError, "size or SHA"):
            self.prepare()
        with fixture.Cache(self.cache_path) as cache, mock.patch.object(
                fixture, "checked_member_chunks", side_effect=fixture.FixtureError("extractor failed")):
            with self.assertRaisesRegex(fixture.FixtureError, "extractor failed"):
                fixture.prepare_systemd_diagnostic(self.artifact, cache, self.directory)
        self.assertEqual({p.name for p in self.cache_path.iterdir()}, {"input.squashfs"})

    def test_stale_manifest_rejected_before_output_publication(self):
        (self.cache_path / "systemd.cpio.manifest.json").write_bytes(b"retain historical provenance")
        with self.assertRaises(fixture.FixtureError):
            self.prepare()
        self.assertFalse((self.cache_path / "systemd.cpio").exists())
        self.assertEqual((self.cache_path / "systemd.cpio.manifest.json").read_bytes(), b"retain historical provenance")

    def test_pinned_unit_waits_for_successful_oneshot_and_never_bypasses_pid1_shutdown(self):
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read_string(self.local["dory-diagnostic.service"].decode())
        self.assertEqual(parser["Service"]["Type"], "oneshot")
        self.assertEqual(parser["Service"]["RemainAfterExit"], "no")
        self.assertEqual(parser["Service"]["ExecStart"], "/bin/busybox sh /usr/lib/dory/diagnostic-workload")
        self.assertEqual(parser["Service"]["ExecStartPost"], "/bin/busybox sh /usr/lib/dory/diagnostic-receipt")
        self.assertEqual(parser["Unit"]["SuccessAction"], "poweroff")
        self.assertEqual(parser["Unit"]["FailureAction"], "poweroff")
        self.assertEqual(parser["Service"]["TimeoutStartSec"], "30s")
        self.assertEqual(parser["Service"]["StandardOutput"], "tty")
        self.assertNotIn("SuccessExitStatus", parser["Service"])
        self.assertNotIn("ExecCondition", parser["Service"])
        workload = self.local["workload"].decode()
        self.assertNotIn('"doryPVHBoot":"userspace-ready"', workload)
        self.assertIn('"$BB" kill -USR1 "$$"', workload)
        self.assertNotIn('"$BB" kill -USR1 1', workload)
        self.assertNotIn("/sbin/poweroff", workload + self.local["receipt"].decode())
        recipe = json.loads((fixture.SYSTEMD_DIAGNOSTIC_DIRECTORY / "fixture.json").read_text())
        for name, data in self.local.items():
            self.assertEqual(recipe["localFiles"][name], {"bytes": len(data), "sha256": digest(data)})
        for name in ("poweroff.target", "systemd-poweroff.service", "shutdown.target", "umount.target", "final.target"):
            self.assertIn("usr/lib/systemd/system/" + name, recipe["members"])

    def test_receipt_requires_matching_successful_completion_record(self):
        source = self.local["receipt"].decode()
        def function(name):
            return name + "() {\n" + source.split("\n" + name + "() {\n", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        # Execute only the pure record-validation and JSON-formatting functions on the host.
        # No guest context, /proc access, guest commands, service or shutdown operation executes.
        command = ('run_uuid=$1; INVOCATION_ID=$2; completed_uuid=$3; completed_invocation=$4; '
                   'completed_pid=$5; passed=$6; failed=$7; extra=$8\n'
                   + function("validate_completion_record") + function("emit_runner_receipt")
                   + "validate_completion_record || exit 1\nemit_runner_receipt\n")
        run_id, invocation = "ddbd0d67-e969-400f-ad8b-1daa5d2290a5", "a" * 32
        valid = [run_id, invocation, run_id, invocation, "2147483647", "7", "0", ""]
        result = subprocess.run(["/bin/sh", "-c", command, "receipt-test"] + valid, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        receipt = json.loads(result.stdout)
        recipe = json.loads((fixture.SYSTEMD_DIAGNOSTIC_DIRECTORY / "fixture.json").read_text())
        self.assertEqual(receipt["workloads"], recipe["runnerProtocol"]["workloads"])
        self.assertEqual(len(receipt["workloads"]), 8)
        self.assertEqual(receipt["runID"], run_id)
        self.assertTrue(receipt["workloadsPassed"])
        for index, value in ((2, "different-run"), (3, "different-invocation"), (4, "1"), (4, ""),
                             (4, "bad"), (5, "6"), (6, "1"), (7, "unexpected-token")):
            arguments = valid.copy()
            arguments[index] = value
            result = subprocess.run(["/bin/sh", "-c", command, "receipt-test"] + arguments,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_cli_systemd_fixture_selection_is_explicit_and_exclusive(self):
        cases = [["--id", "alpine-virt-3.24.1-x86_64", "--extract"],
                 ["--id", "ubuntu-server-24.04.4-x86_64"],
                 ["--id", "ubuntu-server-24.04.4-x86_64", "--extract", "--glibc-diagnostic-initramfs"],
                 ["--id", "ubuntu-server-24.04.4-x86_64", "--extract", "--diagnostic-initramfs"]]
        for arguments in cases:
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fixture.main(arguments + ["--systemd-diagnostic-initramfs",
                    "--cache-directory", str(self.root / "unused-cache")]), 1)
        self.assertFalse((self.root / "unused-cache").exists())


class StressDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "source"
        self.directory.mkdir()
        self.cache_path = self.root / "cache"
        self.cache_path.mkdir()
        self.binary_path = self.root / "stress.elf"
        self.build_path = self.root / "build.json"
        self.sources = {"stress.c": b"synthetic C inspection fixture\n", "Makefile": b"synthetic Makefile\n",
                        "init": b"#!/bin/sh\n# synthetic; never executed\n"}
        for name, data in self.sources.items():
            (self.directory / name).write_bytes(data)
        self.source_sha = digest(self.sources["stress.c"] + self.sources["Makefile"])
        self.binary = self.elf(self.source_sha)
        self.binary_path.write_bytes(self.binary)
        self.members = {"usr/bin/busybox": self.elf("1" * 64),
                        "usr/lib/ld-musl-x86_64.so.1": self.elf("2" * 64)}
        archive = gzip.compress(DiagnosticInitramfsTests.cpio(list(self.members.items())))
        (self.cache_path / "input.gz").write_bytes(archive)
        (self.cache_path / "kernel").write_bytes(b"synthetic kernel")
        self.artifact = {"id": "synthetic-stress-parser", "sha256": digest(b"synthetic ISO"),
            "extractions": [{"filename": "input.gz", "sha256": digest(archive), "maximumBytes": len(archive)},
                            {"filename": "kernel", "sha256": digest(b"synthetic kernel"), "maximumBytes": 100}]}
        self.build = {"schemaVersion": 1, "kind": "p02-userspace-stress-cross-build",
            "sourceSHA256": self.source_sha, "compiler": {"name": "zig", "version": "0.15.2"},
            "target": "x86_64-linux-musl", "cpu": "baseline", "stripped": True,
            "executedGuestCode": False, "binary": {"bytes": len(self.binary), "sha256": digest(self.binary)}}
        output = fixture.stress_diagnostic_cpio(self.sources["init"], self.binary, self.members)
        self.recipe = {"schemaVersion": 1, "kind": "p02-userspace-stress", "architecture": "x86_64",
            "artifactID": self.artifact["id"], "requiredWorkloads": fixture.STRESS_WORKLOADS,
            "localFiles": {name: {"bytes": len(data), "sha256": digest(data)} for name, data in self.sources.items()},
            "source": {"filename": "input.gz", "sha256": digest(archive)},
            "kernel": {"filename": "kernel", "sha256": digest(b"synthetic kernel")},
            "members": {name: digest(data) for name, data in self.members.items()}, "maximumExpandedBytes": 65536,
            "outputFilename": "stress.cpio", "outputBytes": len(output), "outputSHA256": digest(output)}
        self.save_build()

    @staticmethod
    def elf(source_digest):
        # A single executable PT_LOAD with a file-backed entry and embedded identity.
        data = bytearray(1024)
        data[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHIQQ", data, 16, 2, 62, 1, 0x400100, 64)
        struct.pack_into("<HHH", data, 52, 64, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0x400000, 0, len(data), len(data), 4096)
        data[256:320] = source_digest.encode("ascii")
        return bytes(data)

    def save_recipe(self):
        (self.directory / "fixture.json").write_text(json.dumps(self.recipe))

    def save_build(self):
        self.build_path.write_text(json.dumps(self.build))
        self.recipe["buildMetadataSHA256"] = digest(self.build_path.read_bytes())
        self.save_recipe()

    def prepare(self):
        with fixture.Cache(self.cache_path) as cache, \
             mock.patch.object(fixture.subprocess, "Popen", side_effect=AssertionError("compiler or guest execution")), \
             mock.patch.object(fixture, "download_chunks", side_effect=AssertionError("network")):
            return fixture.prepare_stress_diagnostic(self.artifact, cache, self.binary_path,
                                                     self.build_path, self.directory)

    def test_reproducible_archive_exact_static_binary_and_build_manifest(self):
        result = self.prepare()
        self.assertEqual(self.prepare(), result)
        raw = (self.cache_path / result["filename"]).read_bytes()
        self.assertEqual(len(raw) % 512, 0)
        members = fixture.diagnostic_members(raw, {"init", "bin/p02-userspace-stress", "bin/busybox"})
        self.assertEqual(members["bin/p02-userspace-stress"], self.binary)
        self.assertEqual(members["bin/busybox"], self.members["usr/bin/busybox"])
        self.assertEqual(members["init"], self.sources["init"])
        manifest = json.loads((self.cache_path / result["manifestFilename"]).read_text())
        self.assertEqual(manifest["suppliedBuildMetadata"], self.build)
        self.assertEqual(manifest["requiredWorkloads"], fixture.STRESS_WORKLOADS)
        self.assertTrue(manifest["observedStressELF"]["staticNoInterpreterOrDynamicTable"])
        self.assertIn("not independently attested", manifest["buildTrust"])
        self.assertIn("guest has not executed", manifest["qualification"])

    def test_source_metadata_and_binary_tampering_never_publish(self):
        paths = [self.directory / "stress.c", self.directory / "Makefile", self.directory / "init",
                 self.build_path, self.binary_path]
        for path in paths:
            original = path.read_bytes()
            path.write_bytes(original + b"altered")
            with self.subTest(path=path.name), self.assertRaises(fixture.FixtureError):
                self.prepare()
            path.write_bytes(original)
            self.assertFalse((self.cache_path / "stress.cpio").exists())

    def test_missing_or_symlinked_external_build_inputs_reject(self):
        for path in (self.binary_path, self.build_path):
            original = path.read_bytes()
            path.unlink()
            with self.subTest(path=path.name), self.assertRaises(OSError):
                self.prepare()
            target = self.root / (path.name + ".target")
            target.write_bytes(original)
            path.symlink_to(target)
            with self.assertRaises(OSError):
                self.prepare()
            path.unlink()
            path.write_bytes(original)
        self.assertFalse((self.cache_path / "stress.cpio").exists())

    def test_static_elf_rejects_dynamic_wrong_arch_truncation_entry_and_embedded_source(self):
        mutations = [(18, "<H", 183), (16, "<H", 3), (24, "<Q", 0x500000),
                     (32, "<Q", len(self.binary)), (64, "<I", 2), (64, "<I", 3),
                     (68, "<I", 4), (64 + 32, "<Q", len(self.binary) + 1),
                     (64 + 40, "<Q", 1), (64 + 48, "<Q", 3)]
        for offset, fmt, value in mutations:
            data = bytearray(self.binary)
            struct.pack_into(fmt, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(fixture.FixtureError):
                fixture.stress_static_elf(data, self.source_sha)
        with self.assertRaises(fixture.FixtureError):
            fixture.stress_static_elf(self.binary[:100], self.source_sha)
        with self.assertRaises(fixture.FixtureError):
            fixture.stress_static_elf(self.binary, "f" * 64)

    def test_invalid_build_configuration_and_source_binding_reject(self):
        original = json.dumps(self.build)
        for key, value in (("target", "aarch64-linux-musl"), ("sourceSHA256", "0" * 64),
                           ("stripped", False), ("executedGuestCode", True),
                           ("compiler", {"name": "zig", "version": "unverified"})):
            self.build = json.loads(original)
            self.build[key] = value
            self.save_build()
            with self.subTest(key=key), self.assertRaises(fixture.FixtureError):
                self.prepare()
        self.assertFalse((self.cache_path / "stress.cpio").exists())

    def test_missing_kernel_wrong_member_output_and_unsafe_name_fail_without_publication(self):
        kernel = self.cache_path / "kernel"
        data = kernel.read_bytes()
        kernel.unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "kernel is missing"):
            self.prepare()
        kernel.write_bytes(data)
        original = json.dumps(self.recipe)
        for key, value in (("outputFilename", "../escape.cpio"), ("outputSHA256", "0" * 64),
                           ("members", {name: "0" * 64 for name in self.members}),
                           ("requiredWorkloads", fixture.STRESS_WORKLOADS[:-1])):
            self.recipe = json.loads(original)
            self.recipe[key] = value
            self.save_recipe()
            with self.subTest(key=key), self.assertRaises(fixture.FixtureError):
                self.prepare()
        self.assertFalse((self.cache_path / "stress.cpio").exists())
        self.assertFalse((self.root / "escape.cpio").exists())

    def test_corrupt_archive_or_manifest_preserved_before_any_new_publication(self):
        for filename in ("stress.cpio", "stress.cpio.manifest.json"):
            path = self.cache_path / filename
            path.write_bytes(b"preserve mismatched previous output")
            with self.subTest(filename=filename), self.assertRaises(fixture.FixtureError):
                self.prepare()
            self.assertEqual(path.read_bytes(), b"preserve mismatched previous output")
            self.assertEqual(set(p.name for p in self.cache_path.iterdir()), {"kernel", "input.gz", filename})
            path.unlink()

    def test_cli_requires_explicit_binary_metadata_and_exclusive_alpine_selection(self):
        base = ["--id", "alpine-virt-3.24.1-x86_64", "--cache-directory", str(self.root / "unused")]
        invalid = [["--stress-binary", "missing"], ["--stress-build-metadata", "missing"],
                   ["--stress-diagnostic-initramfs"],
                   ["--stress-diagnostic-initramfs", "--extract", "--stress-binary", "missing"],
                   ["--stress-diagnostic-initramfs", "--extract", "--stress-binary", "missing",
                    "--stress-build-metadata", "missing", "--diagnostic-initramfs"]]
        for arguments in invalid:
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fixture.main(base + arguments), 1)
        self.assertFalse((self.root / "unused").exists())

    def test_init_output_gate_never_publishes_success_for_failed_child_or_sync(self):
        source = (fixture.STRESS_DIAGNOSTIC_DIRECTORY / "init").read_text()
        body = source.split("\npublish_workload_output() {\n", 1)[1].split("\n}\n", 1)[0]
        # Only the extracted output gate runs. Mock sync; never mount, power off or run the C guest.
        command = r'''
BB=mock_busybox
mock_busybox() {
    applet=$1
    shift
    case "$applet" in
        sync) return "$SYNC_STATUS" ;;
        wc) wc "$@" ;;
        sed) sed "$@" ;;
        cat) cat "$@"; return "$CAT_STATUS" ;;
        *) return 99 ;;
    esac
}
'''
        command += "publish_workload_output() {\n" + body + "\n}\n"
        command += 'publish_workload_output "$1" "$2"; status=$?; printf "%s\\n" "$receipt_publication_started" >&2; exit "$status"\n'
        output = self.root / "output"
        receipt = '{"doryPVHBoot":"userspace-ready","workloadsPassed":true}\n'
        result_line = 'DORY_P02_RESULT {"status":"pass"}\n'
        for child, sync, cat, content, passed, published in [
            (0, 0, 0, result_line + receipt, True, "yes"),
            (1, 0, 0, result_line + receipt, False, "no"),
            (0, 1, 0, result_line + receipt, False, "no"),
            (0, 0, 0, "", False, "no"),
            (0, 0, 0, "x" * 16385, False, "no"),
            (0, 0, 1, result_line + receipt, False, "yes")]:
            output.write_text(content)
            reply = subprocess.run(["/bin/sh", "-c", command, "gate-test", str(child), str(output)],
                env={**os.environ, "SYNC_STATUS": str(sync), "CAT_STATUS": str(cat)},
                check=False, capture_output=True, text=True, timeout=5)
            with self.subTest(child=child, sync=sync, cat=cat, bytes=len(content)):
                self.assertEqual(reply.returncode == 0, passed)
                self.assertEqual(reply.stderr, published + "\n")
                if published == "no":
                    self.assertNotIn('"doryPVHBoot"', reply.stdout)
                if passed:
                    self.assertEqual(reply.stdout, content)


class IOStressDiagnosticTests(unittest.TestCase):
    elf = staticmethod(StressDiagnosticTests.elf)
    save_build = StressDiagnosticTests.save_build
    save_recipe = StressDiagnosticTests.save_recipe

    def setUp(self):
        StressDiagnosticTests.setUp(self)
        self.recipe.update(kind="p02-userspace-io-stress", requiredWorkloads=fixture.IO_STRESS_WORKLOADS,
                           outputFilename="io-stress.cpio")
        self.build["kind"] = "p02-userspace-io-stress-cross-build"
        for name in fixture.IO_STRESS_MODULES:
            data = bytearray(self.elf("3" * 64))
            struct.pack_into("<H", data, 16, 1)
            data.extend(b"vermagic=6.18.35-0-virt SMP preempt mod_unload modversions \0")
            data.extend(b"~Module signature appended~\n")
            self.members[name] = bytes(data)
        self.install_inputs()

    def install_inputs(self):
        archive = gzip.compress(DiagnosticInitramfsTests.cpio(list(self.members.items())))
        (self.cache_path / "input.gz").write_bytes(archive)
        self.artifact["extractions"][0].update(sha256=digest(archive), maximumBytes=len(archive))
        self.recipe["source"]["sha256"] = digest(archive)
        self.recipe["members"] = {name: digest(data) for name, data in self.members.items()}
        if set(fixture.IO_STRESS_MODULES) <= self.members.keys():
            output = fixture.stress_diagnostic_cpio(self.sources["init"], self.binary, self.members, io=True)
            self.recipe.update(outputBytes=len(output), outputSHA256=digest(output))
        self.save_build()

    def prepare(self, *, io_mode=True):
        with fixture.Cache(self.cache_path) as cache, \
             mock.patch.object(fixture.subprocess, "Popen", side_effect=AssertionError("guest execution")), \
             mock.patch.object(fixture, "download_chunks", side_effect=AssertionError("network")):
            return fixture.prepare_stress_diagnostic(self.artifact, cache, self.binary_path,
                                                     self.build_path, self.directory, io=io_mode)

    def test_fixed_module_closure_and_separate_binary_are_reproduced(self):
        result = self.prepare()
        self.assertEqual(self.prepare(), result)
        raw = (self.cache_path / result["filename"]).read_bytes()
        selected = {name.removeprefix("usr/") for name in fixture.IO_STRESS_MODULES}
        selected.add("bin/p02-userspace-io-stress")
        members = fixture.diagnostic_members(raw, selected)
        for name in fixture.IO_STRESS_MODULES:
            self.assertEqual(members[name.removeprefix("usr/")], self.members[name])
        self.assertEqual(members["bin/p02-userspace-io-stress"], self.binary)
        manifest = json.loads((self.cache_path / result["manifestFilename"]).read_text())
        self.assertEqual(manifest["kind"], "p02-userspace-io-stress-build")
        self.assertEqual(manifest["requiredWorkloads"], fixture.IO_STRESS_WORKLOADS)
        self.assertIn("host reopened block bytes and actual flush", manifest["acceptance"])
        self.assertIn("reconciled ioNetwork counters", manifest["acceptance"])

    def test_missing_transitive_module_rejects_without_publishing(self):
        del self.members[fixture.IO_STRESS_MODULES[1]]  # failover is required by net_failover.
        self.install_inputs()
        with self.assertRaisesRegex(fixture.FixtureError, "member set differs"):
            self.prepare()
        self.assertFalse((self.cache_path / "io-stress.cpio").exists())

    def test_rehashed_wrong_release_type_or_signature_still_rejects(self):
        name = fixture.IO_STRESS_MODULES[-1]
        valid = self.members[name]
        variants = [valid.replace(b"6.18.35-0-virt", b"6.18.34-0-virt"),
                    valid[:16] + struct.pack("<H", 2) + valid[18:], valid[:-1]]
        for variant in variants:
            self.members[name] = variant
            self.install_inputs()
            with self.subTest(sha=digest(variant)), self.assertRaisesRegex(fixture.FixtureError, "module shape"):
                self.prepare()
            self.assertFalse((self.cache_path / "io-stress.cpio").exists())

    def test_io_and_seven_workload_recipes_cannot_be_substituted(self):
        with self.assertRaisesRegex(fixture.FixtureError, "unsupported stress diagnostic recipe"):
            self.prepare(io_mode=False)
        self.recipe["requiredWorkloads"] = fixture.STRESS_WORKLOADS
        self.save_recipe()
        with self.assertRaisesRegex(fixture.FixtureError, "workload set differs"):
            self.prepare()
        args = ["--id", "alpine-virt-3.24.1-x86_64", "--cache-directory", str(self.root / "unused"),
                "--extract", "--stress-binary", str(self.binary_path), "--stress-build-metadata", str(self.build_path)]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fixture.main(args + ["--stress-diagnostic-initramfs", "--io-stress-diagnostic-initramfs"]), 1)
        self.assertFalse((self.root / "unused").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
