# Dory FEX-2607 container and signal-context build

These two arm64 ELF files are the exact FEX binaries shipped in Dory's private runtime bundle.
They are static PIE executables so the binfmt interpreter remains executable after translated tools
enter nested chroots while remaining relocatable around guest VMA reservations. The initfs builder
installs the bytes without rewriting them.

Provenance:

- upstream: `https://github.com/FEX-Emu/FEX`
- tag: `FEX-2607` (annotated tag object `6efd1c099193bba708b68395738a31e9e5409e9a`)
- source commit: `1cc4b93e7a71c883ec021b71359f136394dc1f3c`
- Dory container patch: `patches/fex-container-fd-isolation.patch`
- container patch SHA-256: `374eb59a207c0356f548295552f235c0eeadcdbac360a64b01535933a1af8f8a`
- upstream ProcessorID fix: `patches/fex-processor-id-stack-fix.patch`
- ProcessorID patch SHA-256: `e1da91d76caf48ed30183486abcc9a0eb768d28fd5d041a8b4cbe1c7b75df35c`
- Dory signal-context fix: `patches/fex-restore-complete-signal-context.patch`
- signal-context patch SHA-256: `e405db087203d5f22d50b54820b6a2120d013c0cdd33d1db343f4fac4c1d1e22`
- builder: `ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90`
- Ubuntu archive snapshot: `20260713T120000Z`
- snapshot CA bootstrap package SHA-256: `6bac2a01979e210d9eac1d4d56747ec709ea60654744d66705dc3c36e7629e50`
- reproducible source epoch: `1783039651` (`2026-07-03T00:47:31Z`, the source commit timestamp)
- build package inventory: `BUILD_PACKAGES.txt`
- build package inventory SHA-256: `ad3b0e4ab4e53ac328b0209f592a6f86100f5ca2c17715f2b40ee9b130b0f0b1`
- FEX SHA-256: `01921fa471efc53c955b1d6263f7df4ad0f08f082669a3a7adb6f1e1d5ac0c28`
- FEXServer SHA-256: `bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597`

The rebuild initializes only the eight submodules required by the two production targets. The
toolchain stage resolves packages from the immutable Ubuntu snapshot above and exports every
installed package and version. `SOURCE_DATE_EPOCH` replaces compiler wall-clock macros, while
`--no-cache-filter builder` forces each verification invocation to compile the binaries again and
allows only the pinned toolchain layer to be reused. `BUILD_TESTING=False` excludes test-only
submodule and binary inputs from the release build.

The patch keeps translator-only descriptors out of the guest's normal low descriptor range by
moving the FEX server socket, rootfs handle, `/proc` handle, and non-standard log handles to file
descriptors 256 or higher. It also closes the nested-seccomp handoff descriptor after consuming it.
Guest-created descriptors and application behavior are otherwise unchanged. This prevents
translated descriptor-sensitive tools such as `mmdebstrap` from selecting descriptor 10 or 11 and
then passing a multi-digit `>&N` redirection to Debian `dash`.

The same patch lets FEXServer pass a read-only descriptor for the container's procfs mount over its
abstract Unix socket. A translated process can therefore enter a nested chroot without mounting
procfs there, while FEX still reads its own maps, stat, and descriptor metadata. No Dory runtime
path or file is copied into the user-created rootfs.

The ProcessorID patch is upstream commit `b5660c8a922c1e5ddfe9bea91abaaf5c52cd48a6`. It releases
the temporary host stack allocation after `RDPID` instead of allocating a second block. This
prevents stack corruption in translated runtimes such as Go.

The signal-context patch makes x86-64 signal return restore the complete guest register state and
resume through the dispatcher. Go's asynchronous preemption changes the context saved by its
`SIGURG` handler. Restoring every register prevents stale translated state from corrupting later Go
compiler work.

Nested execution follows Linux rather than package-specific exceptions. X86 shebangs are delegated
to the kernel's binfmt path, FEX preserves its already-proven interpreter state only across the
exceptional self-exec path, and private handoff variables are consumed before the guest environment
is built. Descriptor-based `execveat` retains the caller's argument vector, including Linux's null
`argv` behavior, while a `/` merged rootfs preserves canonical single-slash script paths. These
invariants cover shell, `/usr/bin/env`, Python, child ELF, Docker exec, and inherited guest-seccomp
chains inside ordinary containers and proc-less nested chroots.

Static PIE linking is also part of the compatibility contract: a dynamically loaded native interpreter
loses access to its ARM64 loader when an x86 process invokes `chroot`, causing nested package tools
to fail with a misleading `No such file or directory`, while a fixed-address static interpreter can
collide with guest VMA reservations. The shipped pair has no ELF interpreter or dynamic library
dependencies and remains relocatable, so it is valid across both boundaries.

Run `./rebuild.sh /absolute/output/directory` from this directory (or from any working directory)
to fetch the exact source and required submodules, apply the checked patches, perform a fresh
compilation, and verify that the output hashes and package inventory still match the shipped
artifacts. The checked-in binaries and inventory are immutable release inputs; a changed source,
patch, toolchain, package snapshot, or generated byte cannot silently alter a Dory initfs.

FEX is distributed under the MIT license in `LICENSE.FEX`. The built initfs also carries the
upstream Ubuntu package copyright inventory and third-party notices alongside the runtime.
