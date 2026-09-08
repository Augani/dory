#!/usr/bin/env python3
"""Exercise architecture selection before any Docker or ELF tooling is needed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def run(script, *args, **env):
    return subprocess.run(
        ['bash', str(ROOT / 'guest/mesa' / script), *args],
        env={**os.environ, **env}, text=True, capture_output=True,
    )


class ArchitectureTests(unittest.TestCase):
    def test_aliases_and_default_have_identical_fingerprints(self):
        for aliases in [('', 'amd64', 'x86_64'), ('arm64', 'aarch64')]:
            results = [run('input-pc-virgl2-fingerprint.sh', *([a] if a else [])) for a in aliases]
            self.assertTrue(all(r.returncode == 0 for r in results))
            self.assertEqual(len({r.stdout for r in results}), 1)
            self.assertRegex(results[0].stdout, r'^[a-f0-9]{64}\n$')

    def test_architectures_have_distinct_fingerprints(self):
        self.assertNotEqual(
            run('input-pc-virgl2-fingerprint.sh', 'arm64').stdout,
            run('input-pc-virgl2-fingerprint.sh', 'x86_64').stdout,
        )

    def test_all_entry_points_reject_unknown_architecture(self):
        for script in ['build-pc-virgl2.sh', 'verify-pc-virgl2-build.sh', 'input-pc-virgl2-fingerprint.sh']:
            with self.subTest(script=script):
                self.assertEqual(run(script, 'riscv64').returncode, 64)

    def test_verifier_rejects_swapped_architecture_and_profile(self):
        for arch, other, profile in [('arm64', 'x86_64', 'arm-virgl2'), ('x86_64', 'arm64', 'pc-virgl2')]:
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                (out / f'dory-mesa-virgl2-{arch}.tar.zst').write_bytes(b'not yet an archive')
                stamp = out / f'dory-mesa-virgl2-build-{arch}.stamp'
                stamp.write_text(f'schema=2\narch={other}\nprofile={profile}\n')
                result = run('verify-pc-virgl2-build.sh', arch, DORY_MESA_OUT_DIR=directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('another architecture', result.stderr)
                stamp.write_text(f'schema=2\narch={arch}\nprofile=wrong\n')
                result = run('verify-pc-virgl2-build.sh', arch, DORY_MESA_OUT_DIR=directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('another profile', result.stderr)


if __name__ == '__main__':
    unittest.main()
