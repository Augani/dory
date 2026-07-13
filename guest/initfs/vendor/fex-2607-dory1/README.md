# Dory FEX-2607 container-FD isolation build

These two arm64 ELF files are the exact FEX binaries shipped in Dory's private runtime bundle.
They are linked directly to `/usr/lib/dory/fex/ld-linux-aarch64.so.1` with the private library
RPATH `/usr/lib/dory/fex/lib`; the initfs builder installs the bytes without rewriting them.

Provenance:

- upstream: `https://github.com/FEX-Emu/FEX`
- tag: `FEX-2607` (annotated tag object `6efd1c099193bba708b68395738a31e9e5409e9a`)
- source commit: `1cc4b93e7a71c883ec021b71359f136394dc1f3c`
- Dory patch: `patches/fex-container-fd-isolation.patch`
- patch SHA-256: `ce4b0d955a1c982b071c3d34b34f58e350526cd0b55b28980fbe0594abe1dc9b`
- builder: `ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90`
- FEX SHA-256: `385c2495a46f00450ffa62e641552b7f18928aa18f3d0a8b621c526ccf79e009`
- FEXServer SHA-256: `9a4b098f004a5e9e1759ead38795f48bbc900e654d51e3bcf20d9921f00b2ef4`

The patch keeps translator-only descriptors out of the guest's normal low descriptor range by
moving the FEX server socket, rootfs handle, `/proc` handle, and non-standard log handles to file
descriptors 256 or higher. It also closes the nested-seccomp handoff descriptor after consuming it.
Guest-created descriptors and application behavior are otherwise unchanged. This prevents
translated descriptor-sensitive tools such as `mmdebstrap` from selecting descriptor 10 or 11 and
then passing a multi-digit `>&N` redirection to Debian `dash`.

Run `./rebuild.sh /absolute/output/directory` from this directory (or from any working directory)
to fetch the exact source and submodules, apply the checked patch, build the pair, and verify that
the output hashes still match the shipped artifacts. The checked-in binaries are the immutable
release inputs; a changed toolchain or package archive cannot silently alter a Dory initfs.

FEX is distributed under the MIT license in `LICENSE.FEX`. The built initfs also carries the
upstream Ubuntu package copyright inventory and third-party notices alongside the runtime.
