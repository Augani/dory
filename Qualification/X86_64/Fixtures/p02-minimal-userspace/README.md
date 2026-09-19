# P02 minimal userspace diagnostic

This PID 1 workload uses the exact x86-64 BusyBox and musl loader from the pinned
Alpine 3.24.1 initramfs. It replaces Alpine's ISO-discovery boot flow with seven
small checks and a poweroff request. It requires no ISO, modules, network or root
disk at runtime. `fixture.json` binds the source archive, two ELF files, init
script, primary kernel and generated archive by SHA-256.

The generated `x86_64-p02-minimal-userspace-v2.cpio` is 1,482,752 bytes and has
SHA-256 `22bdcf6331ac87da9fb427037086c9b9b77a4d1ac277e6f2891e2c83adac2249`.
Construction and parser tests do not establish that a guest booted or passed.

## Reproduce

From the repository root, with the P00 inputs already cached:

```sh
python3 scripts/prepare-virtualization-fixtures.py \
  --id alpine-virt-3.24.1-x86_64 \
  --cache-directory /tmp/dory-p00-guest-fixtures \
  --verify-only --extract --diagnostic-initramfs
python3 scripts/test-prepare-virtualization-fixtures.py
```

For a new cache, omit `--verify-only` to download the catalog's pinned official
ISO. The existing preparer verifies the ISO and extracted inputs before deriving
the diagnostic. It never boots the guest. Existing outputs with different bytes
are preserved and rejected. The adjacent `.cpio.manifest.json` records input,
recipe, init, builder and output digests. Use a new cache if a changed builder
produces a different provenance manifest for an already published output name.

The archive is uncompressed `newc` with sorted names, sequential inode numbers,
fixed modes and device numbers, zero UID/GID/mtime and 512-byte padding. The
builder reads selected regular files directly from bounded archive bytes; it
does not extract archive paths onto the host. Both ELF payloads retain their
upstream bytes. `/bin/sh` and the musl libc name are symlinks to those payloads;
the archive also supplies `/dev/console`, `/dev/null` and `/dev/zero` device nodes.

## Execute with the bounded PVH runner

Build `dory-pc-linux-boot-runner` in release mode through the core package workflow. Import the
three manifest-bound objects with `dory-pc-x86-fixture-importer`; use only the resulting
content-addressed paths. Supply a newly generated lowercase run UUID and every candidate identity.
The source-tree value must describe the tree used for the runner binary, not the tree at some later
time. For example:

```sh
/absolute/path/release/dory-pc-linux-boot-runner \
  --kernel /absolute/content-store/sha256/e48a2de81362198d41bcac5519c6ae2d8f19e056aec4763fa590d000abf348d8 \
  --kernel-sha256 e48a2de81362198d41bcac5519c6ae2d8f19e056aec4763fa590d000abf348d8 \
  --initrd /absolute/content-store/sha256/22bdcf6331ac87da9fb427037086c9b9b77a4d1ac277e6f2891e2c83adac2249 \
  --initrd-sha256 22bdcf6331ac87da9fb427037086c9b9b77a4d1ac277e6f2891e2c83adac2249 \
  --symbols /absolute/content-store/sha256/a1909638842396ba3c5acfb88c47678be3c808c7278d04c71241e4ab6935288a \
  --symbols-sha256 a1909638842396ba3c5acfb88c47678be3c808c7278d04c71241e4ab6935288a \
  --command-line 'console=ttyS0 rdinit=/init panic=-1' \
  --tier baseline-jit --tier1 enabled --memory-mib 512 \
  --max-instructions 1000000000 --wall-seconds 900 \
  --run-id fresh-lowercase-uuid-for-this-run \
  --workload bootstrap.filesystems \
  --workload syscall.identity \
  --workload process.creation_exec_wait \
  --workload memory.allocation_copy \
  --workload signal.handler_return \
  --workload timer.sleep_elapsed \
  --workload filesystem.write_read_sync \
  --diagnostics /absolute/path/unique-run-result.json \
  --cpu-profile dory.x86_64.compat-v1 \
  --fixture-manifest /absolute/repository/Qualification/X86_64/Manifests/alpine-virt-3.24.1-pvh-smoke-v2.json \
  --fixture-manifest-sha256 9a11a01ad9feae91041ec8ce29bc8ed1c15a6d507f971ffdbef51e801dc62e6b \
  --source-commit full-40-character-git-commit \
  --source-tree clean \
  --host-class validated-host-class-identifier \
  --processor-count 1 \
  --jit-write-policy protected-host-pages \
  --raw-target-prediction none
```

The example budgets are limits, not a general performance claim. `none` is the correctness
baseline: current-source exact-candidate runs rejected `all` and `tier1-direct-chain` after each
reproduced a native slice that did not return before the wall watchdog. Other modes remain explicit
engineering experiments and cannot close a qualification gate. Repeat with a fresh UUID and output
path for each tier. The runner appends
`dory.pvh_run_id=<lowercase UUID>`; do not add that parameter yourself. PID 1
rejects a missing, repeated or malformed UUID. Never execute `init` on the host;
it rejects execution outside PID 1 before performing any workload.

Each check emits a supplemental `DORY_P02_RESULT` JSON record. A matching
unprefixed JSON line has `schemaVersion: 1`, `doryPVHBoot: "userspace-ready"`,
the exact UUID in `runID`, and the seven names in `workloads` only when all seven
checks pass. A failed or incomplete run emits `workloadsPassed: false` and an
empty workload list. The host must also observe the machine's ACPI S5 poweroff;
neither the receipt nor `shutdown.request` is standalone shutdown evidence.
If Linux POWER_OFF returns, PID 1 emits `shutdown.returned` and remains alive.

## Coverage limits

| Result | What it exercises |
| --- | --- |
| `bootstrap.filesystems` | procfs, devtmpfs, sysfs and an 8 MiB tmpfs mount |
| `syscall.identity` | musl dynamic loading, x86-64 uname and PID 1 procfs access |
| `process.creation_exec_wait` | background process isolation, BusyBox exec, actual child PID and exit-status wait |
| `memory.allocation_copy` | a 64 KiB shell heap string and repeated copying |
| `signal.handler_return` | USR1 delivery to an installed PID 1 handler and return |
| `timer.sleep_elapsed` | one-second sleep with at least 900 ms of procfs elapsed time |
| `filesystem.write_read_sync` | 64 KiB tmpfs write, separate read/copy, content comparison and sync |

The process test establishes fork-like isolation and exec/wait behavior; it does
not trace whether this BusyBox/libc combination uses fork, clone or vfork. The
allocation, signal and timer cases are small behavioral checks, not exhaustive
syscall or fault-injection suites. File writes use tmpfs and do not qualify a
block device or durable filesystem. This fixture provides no glibc, systemd,
general-purpose distribution or release qualification. Parser tests use clearly
synthetic ELF headers and are separate from the pinned real guest archive.

## Required CI boot checks

The `Tests` workflow runs `P02 userspace boot (interpreter)` and
`P02 userspace boot (baseline-jit)` on every configured push, pull request and manual
run. Both are unconditional jobs, and one tier failing does not cancel the other.
Repository branch protection must require both named checks; workflow source alone
does not configure that repository setting.

Each job uses the ARM64 `macos-26` hosted image, requires final Xcode 26.6 build
17F113 with SDK 26.5, builds from the checked-out source, fetches the pinned Alpine
3.24.1 input through the existing fixture preparer and independently re-verifies
the generated archive. It gives the guest 512 MiB, at most one billion instructions
and 900 seconds on the runner's monotonic clock. The fixture/download, build and
boot steps also have outer CI timeouts. These limits are engineering bounds; they
do not assert that the current implementation can finish within them.

Acceptance requires runner exit 0, the fresh UUID, all seven exact workload names,
the diagnostic's successful outcome and a final `powered-off` machine exit. Missing
media, altered hashes, HLT, reset, exceptions, instruction/wall budget exhaustion,
an absent marker or a marker without ACPI poweroff fail the job. No fixture skip or
`continue-on-error` is used. Both jobs upload their source/host identity, input
provenance, build logs, runner exit status, summary, console/fault diagnostic and
stderr on success or failure, retaining artifacts for 14 days. An infrastructure
termination can prevent the final artifact upload; the runner's 900-second watchdog
normally finishes before the 17-minute CI boot-step limit.

The hosted image and installed toolchain are documented by
[GitHub's runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
This CI gate is userspace boot engineering evidence. It does not substitute for
physical x86 instruction-reference results, minimum-host testing or release qualification.
