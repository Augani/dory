#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import subprocess
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "guest/desktop/install-graphics-pack.sh"
EXPECTED_FILES = {
    "lib/libvulkan_virtio.so": b"candidate-icd",
    "libexec/dory-vulkan-compositor-probe": b"candidate-compositor-probe",
    "libexec/dory-vulkan-probe": b"candidate-probe",
    "share/dory/build-packages.txt": b"fixture=1\n",
    "share/dory/runtime.env": b"schema=6\npack_layout=single-tree\n",
    "share/vulkan/icd.d/virtio_icd.aarch64.json": b"{}\n",
}


def archive(
    root: pathlib.Path,
    name: str,
    *,
    extra: str | None = None,
    symlink: bool = False,
    runtime_manifest: bytes | None = None,
) -> pathlib.Path:
    source = root / f"{name}-source" / "opt/dory/mesa"
    for relative, contents in EXPECTED_FILES.items():
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative == "share/dory/runtime.env" and runtime_manifest is not None:
            contents = runtime_manifest
        path.write_bytes(contents)
        path.chmod(0o755 if relative.startswith("libexec/") else 0o644)
    if extra:
        path = source / extra
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"stale")
        path.chmod(0o644)
    if symlink:
        (source / "lib/escape.so").symlink_to("/tmp/escape")
    tar_path = root / f"{name}.tar"
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as output:
        output.add(source.parents[1], arcname="./opt", recursive=True)
    compressed = root / f"{name}.tar.zst"
    subprocess.run(
        ["zstd", "-q", "-f", str(tar_path), "-o", str(compressed)],
        check=True,
    )
    return compressed


class GraphicsPackInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-graphics-pack-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.target = self.root / "target"
        self.target.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def install(self, candidate: pathlib.Path, *, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(INSTALLER), str(candidate), str(self.target), str(os.getuid())],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if succeeds and result.returncode != 0:
            self.fail(result.stderr)
        if not succeeds and result.returncode == 0:
            self.fail("invalid graphics pack unexpectedly installed")
        return result

    def test_old_schema_tree_is_replaced_without_stale_dso(self) -> None:
        old = self.target / "opt/dory/mesa"
        (old / "lib").mkdir(parents=True)
        (old / "lib/libxcb-keysyms.so.1.0.0").write_bytes(b"old")
        (old / "share/dory").mkdir(parents=True)
        (old / "share/dory/runtime.env").write_text("schema=2\n", encoding="utf-8")

        self.install(archive(self.root, "candidate"))

        installed = self.target / "opt/dory/mesa"
        actual = {
            path.relative_to(installed).as_posix(): path.read_bytes()
            for path in installed.rglob("*")
            if path.is_file()
        }
        self.assertEqual(actual, EXPECTED_FILES)
        self.assertFalse((self.target / "opt/dory/.mesa-update-transaction").exists())

    def test_extra_file_and_symlink_are_rejected_without_replacing_old_tree(self) -> None:
        old = self.target / "opt/dory/mesa"
        old.mkdir(parents=True)
        sentinel = old / "sentinel"
        sentinel.write_bytes(b"old")

        self.install(archive(self.root, "extra", extra="lib/libxcb-keysyms.so.1"), succeeds=False)
        self.assertEqual(sentinel.read_bytes(), b"old")
        self.install(archive(self.root, "symlink", symlink=True), succeeds=False)
        self.assertEqual(sentinel.read_bytes(), b"old")

    def test_schema_four_candidate_is_rejected_without_replacing_old_tree(self) -> None:
        old = self.target / "opt/dory/mesa"
        old.mkdir(parents=True)
        sentinel = old / "sentinel"
        sentinel.write_bytes(b"old")

        candidate = archive(
            self.root,
            "schema-four",
            runtime_manifest=b"schema=4\npack_layout=single-tree\n",
        )
        self.install(candidate, succeeds=False)
        self.assertEqual(sentinel.read_bytes(), b"old")

    def test_interrupted_old_tree_rename_is_recovered_before_replacement(self) -> None:
        transaction = self.target / "opt/dory/.mesa-update-transaction"
        previous = transaction / "previous"
        previous.mkdir(parents=True)
        (previous / "old-sentinel").write_bytes(b"old")
        (transaction / "owner").write_text("pid=999999999\n", encoding="utf-8")

        self.install(archive(self.root, "recovery"))

        self.assertFalse(transaction.exists())
        self.assertFalse((self.target / "opt/dory/mesa/old-sentinel").exists())
        self.assertEqual(
            (self.target / "opt/dory/mesa/lib/libvulkan_virtio.so").read_bytes(),
            b"candidate-icd",
        )


if __name__ == "__main__":
    unittest.main()
