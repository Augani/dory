# P02 minimal glibc userspace diagnostic

This is a deterministic **input fixture**, not a boot or distribution qualification.
The five ELF inputs come unchanged from the existing P00-pinned Ubuntu Server
24.04.4 x86-64 ISO and its `casper/ubuntu-server-minimal.squashfs` member. No host
guest programs execute during preparation, and no distribution name changes VMM
behavior.

The actual BusyBox binary identifies itself as
`BusyBox v1.36.1 (Ubuntu 1:1.36.1-6ubuntu3.1)`. Its ELF interpreter is
`/lib64/ld-linux-x86-64.so.2`; its only direct dependency is `libc.so.6`.
The extracted libc's own banner is
`GNU C Library (Ubuntu GLIBC 2.39-0ubuntu8.7) stable release version 2.39.`
The recipe pins the complete interpreter/SONAME/dependency closure, byte sizes,
and SHA-256 values. The builder checks those properties directly from the ELF
program headers and dynamic tables, including file-backed string-table bounds.

All seven workload checks run through dynamically linked glibc BusyBox. This
BusyBox build does not contain the `poweroff` applet, so **only final shutdown**
uses the same ISO's small klibc `poweroff` program and its separate interpreter.
Its embedded usage string is
`Usage: {halt|reboot|poweroff} [-n] [reboot-arg]`. The guest calls
`/sbin/poweroff` with no arguments after `busybox sync`; the Alpine `-f` flag is
not used. Inspection reads binary data and never invokes a host poweroff command.
This helper is outside the seven glibc checks; no systemd behavior is exercised.

## Reproduce

Use Python 3, libarchive `tar` with ISO9660 support, and `unsquashfs` supporting
`-cat`, `-processors`, and `-mem`. The builder streams the selected squashfs
member, then extracts only the five pinned files through `unsquashfs -cat` with
one worker and a 16 MiB cache. It does not unpack guest-controlled paths onto the
host. Input/output bounds and hashes are enforced before atomic publication.
Existing mismatched cache entries are preserved and rejected.

```sh
python3 scripts/prepare-virtualization-fixtures.py \
  --id ubuntu-server-24.04.4-x86_64 \
  --cache-directory /tmp/dory-p02-glibc-guest-fixtures \
  --extract --glibc-diagnostic-initramfs
```

Add `--verify-only` to require an already cached exact ISO without downloading.
The source filename is `ubuntu-24.04.4-live-server-amd64.iso`, SHA-256
`e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`.
Use a fresh output cache when the builder or recipe changes: manifests bind the
exact builder source and deliberately do not overwrite earlier provenance.

The output is `x86_64-p02-glibc-userspace-v1.cpio`, **2,788,352 bytes**, SHA-256
`813de160103ef6179de5d3b6d9271ed8f9883d8c3fa7671a49254f0ec7cb9d24`.
The uncompressed `newc` archive sorts names, uses sequential inodes, zeroes
UID/GID/timestamps, fixes modes and device identities, and pads to 512 bytes.
Its companion `.manifest.json` binds the exact ISO, squashfs, every extracted
ELF, init, recipe, builder, output, and runtime limits. No generated binaries
are checked into the repository. The Alpine musl fixture and its v2 archive
remain independent and unchanged.

## Workload and acceptance contract

The workload matches the [musl diagnostic](../p02-minimal-userspace/README.md):

1. `bootstrap.filesystems`: proc/devtmpfs/sysfs and bounded tmpfs mounts.
2. `syscall.identity`: x86-64 `uname` and the PID 1 procfs record.
3. `process.creation_exec_wait`: child process isolation, dynamic exec, PID and wait status.
4. `memory.allocation_copy`: a 64 KiB shell heap string.
5. `signal.handler_return`: a PID 1 USR1 handler that returns.
6. `timer.sleep_elapsed`: a one-second sleep and at least 900 ms procfs elapsed time.
7. `filesystem.write_read_sync`: a 64 KiB tmpfs write, copy, compare, read and sync.

Each run requires a fresh canonical lowercase UUID in exactly one
`dory.pvh_run_id=UUID` kernel argument. The final unprefixed JSON line uses the
runner's `schemaVersion: 1`, `doryPVHBoot: "userspace-ready"`, `runID`,
`workloadsPassed`, and exact seven `workloads` names. A partial or failed run
cannot emit a successful receipt. Supply the seven names as repeated runner
`--workload` arguments. `shutdown.request` is supplemental and is never counted
as success: the host must separately observe ACPI S5 / `poweredOff`.

These are bounded shell checks, not complete syscall, allocator, signal, timer,
block-persistence, glibc, or general-purpose distribution coverage. The exact
fork/clone/vfork syscall choice is not traced. Preparation alone proves none of
the execution requirements.

The recipe also retains the same ISO's `casper/vmlinuz` identity and its
bzImage Zstandard payload offsets as optional future input metadata. It is not
part of this initramfs or a supported kernel extraction recipe; existing pinned
kernel ELF fixtures may be paired with this userspace for later runner probes.

## Offline checks

```sh
python3 scripts/test-prepare-virtualization-fixtures.py
```

Tests cover malformed ELF bounds and search paths, missing interpreter/SONAME
dependencies, corrupt inputs, unsafe paths, extractor failures and size limits,
deterministic metadata, retained cache records, and the shared UUID receipt.
Synthetic parser-test ELFs are never executed or represented as guest evidence.
