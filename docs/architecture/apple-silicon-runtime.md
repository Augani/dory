# Apple Silicon launch runtime

Status: accepted for launch qualification on 2026-07-13.

## Decision

Dory ships one Apple Silicon product architecture:

1. One persistent Linux engine owns Docker, BuildKit, Compose, Kubernetes, and managed Linux
   machines. macOS 15 and later use Dory's Hypervisor.framework VMM; macOS 14 uses the bundled
   Virtualization.framework fallback. Runtime selection does not create a second hidden x86 VM.
2. One user-visible managed sparse data drive owns images, containers, writable layers, named
   volumes, networks, machine disks, and Kubernetes state. Transient sockets, PID files, logs, and
   prepared boot assets remain replaceable runtime state. Uninstall never silently deletes the data
   drive. Canonical identity, relocation, backup, migration, and recovery follow the separate
   [Apple Silicon storage contract](apple-silicon-storage.md) and shared
   [transactional data-operations contract](transactional-data-operations.md); a raw sparse disk
   is never presented as the user's portable backup format.
3. Arm64 is native. Common `linux/amd64` images use one provenance-pinned FEX-Emu 2607 runtime,
   registered only for x86_64. There is no production qemu-user fallback and no workload-name
   heuristic. Missing or mismatched FEX state fails closed before the OCI runtime starts a user
   process.
4. Intel Mac support is outside the Apple Silicon launch contract and must not be inferred from
   amd64 container support.

## Why this translator

Rosetta for Linux is exposed through Apple's `VZLinuxRosettaDirectoryShare`, which belongs to
Virtualization.framework. Dory's primary VMM uses Hypervisor.framework, so making Rosetta the
container path would split the product across engines and weaken the single data/network/control
plane. It would also retain a platform dependency that Dory cannot patch or qualify internally.

QEMU static binfmt passed the exact OrbStack `mmdebstrap` reproduction, but failed Arch's unmodified
`pacman -Sy --noconfirm fzf`: QEMU returned `EINVAL` while installing the default alpm seccomp
sandbox and the sandbox user switch failed. A dual FEX/QEMU path would therefore exchange one class
of failures for another and make behavior depend on an unreliable workload guess.

FEX passed the Arch sandbox, Docker seccomp, Nix GC, Node/npm, and ordinary runtime paths. Research
then traced its Debian failure to generic nested-exec invariants rather than `mmdebstrap` itself.
Dory's pinned patch fixes those invariants:

- translator-owned descriptors live at 256 or above;
- a read-only pre-chroot procfs descriptor survives nested chroots without injecting Dory files;
- static PIE keeps the native interpreter executable and relocatable after chroot;
- Linux handles x86 shebangs through binfmt, including `/usr/bin/env` chains;
- already-proven interpreter state is propagated only across the exceptional FEX self-exec and is
  consumed before the guest environment is created;
- descriptor `execveat` preserves the caller's arguments and Linux null-`argv` behavior;
- a merged `/` rootfs retains canonical single-slash script paths; and
- guest seccomp filters survive script and child-ELF transitions.

This is one execution model for Docker run, BuildKit `RUN`, and `docker exec`, not a list of
package-manager exceptions.

## Launch support boundary

The launch contract is native `linux/arm64` plus common 64-bit `linux/amd64` OCI images on Apple
Silicon. Dory intentionally does not register a 32-bit x86 handler. Any future x86-32 or Intel-host
claim needs its own runtime design and physical qualification.

The immutable FEX source commit, patch, build image, Ubuntu snapshot, compiler package inventory,
source epoch, binary hashes, licenses, and forced-fresh rebuild procedure live in
`guest/initfs/vendor/fex-2607-dory1`. The guest and OCI wrapper verify the same binary pair before
use. The build epoch is the upstream commit timestamp; no release binary depends on the wall clock.

## Release evidence

Publication is blocked unless the exact notarized candidate repeats all of the following from fresh,
digest-pinned inputs and removes its owned images and BuildKit cache:

- OrbStack issue 2543's unmodified `mmdebstrap --variant=minbase trixie /tmp/rootfs.tar`, followed
  by a proc-less nested-chroot shebang;
- Apple container issue 1628's unmodified Arch pacman sandbox install;
- Nix 2.34.7 garbage collection;
- Node/npm BuildKit build, tests, GNU tar hardlinks, and runtime;
- canonical shell and `/usr/bin/env` shebang chains;
- inherited guest seccomp through Python and a child ELF;
- descriptor exec with normal and null argument vectors;
- Docker run, BuildKit, and `docker exec`; and
- an amd64-only `POCF` binfmt registration with no leaked private handoff variables.

Primary references:

- [Apple Virtualization: VZLinuxRosettaDirectoryShare](https://developer.apple.com/documentation/virtualization/vzlinuxrosettadirectoryshare)
- [Linux binfmt_misc](https://docs.kernel.org/admin-guide/binfmt-misc.html)
- [FEX-Emu](https://github.com/FEX-Emu/FEX)
- [QEMU user-mode emulation](https://qemu.readthedocs.io/en/master/user/main.html)
- [tonistiigi/binfmt](https://github.com/tonistiigi/binfmt)
- [Ubuntu snapshot service](https://ubuntu.com/server/docs/how-to/software/snapshot-service/)
- [OrbStack issue 2543](https://github.com/orbstack/orbstack/issues/2543)
- [Apple container issue 1628](https://github.com/apple/container/issues/1628)
