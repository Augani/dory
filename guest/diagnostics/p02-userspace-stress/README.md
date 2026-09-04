# Bounded P02 userspace stress workload

`stress.c` is a standalone Linux x86-64 guest program for P02-25 engineering
checks. A supervising guest init runs `p02-userspace-stress --run`; the program
refuses PID 1. It requires procfs, a writable `/run`, and the exact Alpine BusyBox
and musl loader already pinned by `../p02-minimal-userspace/fixture.json`.
It does not mount filesystems, access a network, or shut down the machine.

This directory supplies source, a cross-build record and a pinned initramfs recipe.
Preparation verifies and packages inputs; it supplies **no successful guest
execution receipt**. Never execute the resulting x86 binary on the development host,
including through Rosetta, another emulator, or a host Linux environment.

## Build without execution

With Zig 0.15.2, from this directory:

```sh
make ZIG=/opt/homebrew/bin/zig BUILD_DIR=/tmp/dory-p02-userspace-stress
file /tmp/dory-p02-userspace-stress/p02-userspace-stress
shasum -a 256 /tmp/dory-p02-userspace-stress/p02-userspace-stress
```

The target is static, stripped `x86_64-linux-musl` with the baseline CPU target and
a fixed source-path prefix map. The digest
embedded in every result is SHA-256 of the literal concatenation `stress.c`, then
`Makefile`. `build.json` binds the compiler version, command, source digest and
output ELF digest. `fixture.json` additionally binds that exact build record,
the init adapter and the upstream guest inputs. The published manifest retains
all these identities and the preparer's own SHA-256. Build-record claims are
supplied provenance; the preparer verifies hashes and ELF structure without
independently attesting which compiler produced the supplied bytes.
The Makefile contains no execution target. Compiler diagnostics and ELF metadata
inspection establish build validity only.

Two local builds from distinct source directories using Zig 0.15.2 produced the
same 55,856-byte stripped ELF, SHA-256
`87ce0be824de62928b075d9be1aa6a567cd3e287b66072e1feef3bc5b2754d18`.
This verifies source-path independence on that host; it does not establish
cross-host or compiler-distribution reproducibility. The embedded source digest is
`89f357e8d4d126998c0c563bec5675c5ea976d1abca00bcd83c6c070c12437f1`.

## Prepare and run

From the repository root, after the explicit build and with the pinned Alpine
inputs already cached:

```sh
python3 scripts/prepare-virtualization-fixtures.py \
  --id alpine-virt-3.24.1-x86_64 \
  --cache-directory /tmp/dory-p00-guest-fixtures \
  --verify-only --extract --stress-diagnostic-initramfs \
  --stress-binary /tmp/dory-p02-userspace-stress/p02-userspace-stress \
  --stress-build-metadata guest/diagnostics/p02-userspace-stress/build.json
python3 scripts/test-prepare-virtualization-fixtures.py
```

For a fresh cache, omit `--verify-only` to fetch the catalog's pinned ISO. Stress
selection requires `--extract`, the sole Alpine x86-64 ID, and both explicit build
inputs. It is exclusive with the existing musl, glibc and systemd diagnostic
options. The preparer never compiles or executes the stress ELF. It rejects a
different source, build record, binary, embedded source digest, architecture,
dynamic ELF dependency, archive input or output digest. Existing mismatched CPIO
or provenance files are preserved; use a fresh cache after a reviewed source or
builder change. Files are packaged through deterministic `newc` bytes without
extracting archive paths onto the host. Existing diagnostic CPIO recipes and
generation paths are unchanged.

The fixture's `/init` runs as Linux x86-64 PID 1, mounts procfs, devtmpfs, sysfs and
an 8 MiB mode-0700 tmpfs at `/run`, then invokes the C program as a child. It
buffers the child's bounded output until exit 0 and final sync succeed. Failure
publishes only diagnostic lines and no success receipt. If output delivery fails
after publication begins, PID 1 exits without requesting poweroff, preventing a
partial handoff from qualifying. Otherwise it makes exactly one pinned BusyBox
`poweroff -f` request through Linux POWER_OFF. A returned request is a failure;
there is no guest retry loop. Host instruction and wall budgets bound kernel
failure or a PID 1 exit panic.

Use the existing PVH runner with a fresh `--run-id`, explicit tier and budgets,
the kernel and output hashes from `fixture.json`, and all seven `--workload` names
below. Select `console=ttyS0 rdinit=/init panic=-1` as the command line; the runner
adds the UUID. The fixture requests no disk or network devices. A CPIO build or
receipt without independent host ACPI S5 evidence does not qualify the run.

The pinned `x86_64-p02-userspace-stress-v1.cpio` is 1,535,488 bytes with SHA-256
`b4f77cbb1d2e0f835d724110c307b0fd4d51b5c34afa50ace89ece005efb122c`.

## Inputs and identity

The host runner supplies a fresh UUID through its existing `--run-id` option,
which adds exactly one `dory.pvh_run_id=<lowercase UUID>` to the guest command
line. Before changing resource limits, creating children or writing files, the
program checks Linux/x86-64 and bounded `/proc/cmdline`, rejecting missing,
repeated, uppercase, malformed and oversized UUID input. These checks prevent
accidental invocation; a command-line marker is not cryptographic guest attestation.

Install the existing verified Alpine members at these guest paths:

| Path | SHA-256 |
| --- | --- |
| `/bin/busybox` (regular file) | `01a989eb4d1d04b0d146c790ac536abd88f374ec74a2e110c58910b840d42045` |
| `/lib/ld-musl-x86_64.so.1` | `38d022ce7425ff105ccfb53598f606e6e5f5f0a34bfbc793d65e6f34c9d72806` |

Retain the libc symlink used by the existing fixture. The verified upstream
BusyBox is 1.37.0, with musl 1.2.6-r2. All subprocesses use explicit `execve`
argument arrays and a fixed environment, without a shell. A BusyBox self-check
using `sha256sum` detects accidental mismatched inputs; **independent preparer
verification of BusyBox and its loader remains the trust boundary**. A missing
applet, wrong pin, missing writable directory or unavailable syscall fails.

## Results and bounds

Each successful stage writes a `DORY_P02_RESULT` JSON line with `schemaVersion: 1`,
`kind: "userspace-result"`, the exact UUID in `runUUID`, its name, `status: "pass"`,
validated iteration count and `sourceSHA256`. A failing stage writes `status:
"fail"`, stops and returns nonzero. Input refusal returns 2. These are exact
required runner workload names:

| Name | Validated work |
| --- | --- |
| `stress.allocation_free` | 32 malloc/realloc/calloc/free rounds; byte patterns survive growth; calloc bytes are zero; each allocation at most 499,729 bytes |
| `stress.mmap_protection` | Four four-page mappings; eight isolated children must terminate from SIGSEGV on a read-only write or PROT_NONE read; parent restores protections and checks all bytes |
| `stress.process_exec_wait` | Eight real fork + `/proc/self/exe` execve + waitpid cycles; exact child token, UUID, ordinal and exit 23 |
| `stress.filesystem_roundtrip` | Eight 128 KiB create/write/fsync/close/reopen/read/unlink rounds and a known SHA-256 |
| `stress.compression_checksum` | Three actual BusyBox gzip/decompression cycles; exact bytes and pinned expected sha256sum; compressed payload must be smaller |
| `stress.package_unpack` | Two BusyBox tar creation, gzip/decompression and tar extraction cycles; exact archive roundtrip and extracted checksum |
| `stress.monotonic_clock` | Four 20 ms nanosleeps; monotonic timestamps never regress and each elapsed interval reaches its requested duration |

The fixed payload is 131,072 bytes, byte `i = (i * 37 + (i >> 8)) mod 256`. Its
independently computed SHA-256 is
`dbb71d178d43f63f39dd9b0fb5fc30fb366ada39e3b8763e41338b892c098cd6`.
The parent validates the tar header checksum, literal `payload` name, regular
file type, empty link/prefix, exact size/content, block alignment and zero trailer
before invoking tar extraction in a new private subdirectory. This is a real tar
package roundtrip; it is not an OS package-manager transaction or an arbitrary
archive extractor.

All work has a shared 120-second guest monotonic deadline, additionally checked
after child termination and before the receipt. At most one child is outstanding,
with a hard limit of 64 launches (the successful path uses 37). Each regular output
is limited by RLIMIT_FSIZE to 256 KiB, RLIMIT_NOFILE is 32, core dumps are disabled,
and each process inherits a 120 CPU-second ceiling. Program-controlled allocations
stay below 1 MiB at once; BusyBox and libc add their own working memory. `/run`
must be mounted with an explicit fixture size limit (at least 8 MiB). All files
are created in one mode-0700 `mkdtemp` directory, all names are literal, subprocess
outputs are bounded files, and cleanup removes only that known file set.

The parent kills and reaps its one child on deadline failure. Blocking kernel
syscalls, SIGKILL reaping, and a broken guest clock still require the host runner's
independent instruction and monotonic wall budgets; the guest timer alone cannot
bound a malfunctioning virtual machine. Expected SIGSEGV diagnostics may appear
in the kernel log, while core files remain disabled.

Only after all seven stages, successful cleanup and a final deadline check does
the program emit the unprefixed runner receipt with `doryPVHBoot:
"userspace-ready"`, matching `runID`, `workloadsPassed: true` and all seven names.
The supervising init must treat nonzero exit as failure and request normal
shutdown. Host acceptance must require every exact workload, fresh matching UUID,
runner exit 0 and independently observed ACPI S5 poweroff. No incomplete or
deadline-exhausted run produces a successful receipt.

## Remaining integration coverage

These file checks exercise filesystem syscall behavior and content integrity on
the supplied writable guest filesystem. Tmpfs `fsync` does not establish durable
block-device writes, filesystem replay or persistence across VM restart. Those
require a separately pinned disk fixture, bounded read/write/fsync workload and
host-side reopen verification. Sustained device-backed networking likewise needs
a controlled external endpoint and bounded traffic with independent byte counts;
this program makes no network claim. Full P02-25 stress qualification, guest
receipt retention and tier comparisons remain open until those integrations run.

The syscall contracts follow the Linux man-pages project documentation for
[mprotect](https://man7.org/linux/man-pages/man2/mprotect.2.html),
[waitpid](https://man7.org/linux/man-pages/man2/waitpid.2.html),
[setrlimit](https://man7.org/linux/man-pages/man2/getrlimit.2.html) and
[clock_gettime](https://man7.org/linux/man-pages/man2/clock_gettime.2.html).
The tool invocations use the documented
[BusyBox applet interface](https://www.busybox.net/downloads/BusyBox.html).
