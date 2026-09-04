#!/usr/bin/env python3
"""Offline integrity and cleanup tests for the pinned guest fixture preparer."""

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
