# P02 minimal systemd userspace diagnostic

This is a deterministic input fixture. **No systemd guest execution or distribution
qualification is claimed by its construction.** The separate
[glibc fixture](../p02-glibc-userspace/README.md) remains unchanged.

`/init` is a symlink directly to the unchanged Ubuntu `systemd` ELF. Its embedded
version is **255.4-1ubuntu8.12**. PID 1 starts one root `Type=oneshot` service;
BusyBox/glibc runs its seven bounded checks, and a separate `ExecStartPost`
command reports the eighth check, `systemd.service_supervision`. The service
commands require PID 1 as their parent, `/proc/1/exe` resolving to the systemd
binary, a systemd `INVOCATION_ID`, and the unified cgroup
`/system.slice/dory-diagnostic.service`.

The main command writes a completion record and exits zero only after all seven
checks pass. The post command requires the same run UUID and invocation, verifies
that the main process has been reaped, removes the record, and emits the sole
successful runner receipt. A failed or incomplete main command cannot emit it.
This verifies completion of the oneshot command; it does not claim readiness of
a long-running `Type=notify` daemon.

The distinction follows the upstream [v255 service contract](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.service.xml)
and its [oneshot child-exit transition](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/service.c).
The manager supplies the same invocation ID to both commands, and output-only
TTY attachment avoids a journald dependency. See the
[execution-environment contract](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.exec.xml).

`RemainAfterExit=no` lets a successful service become inactive. Both
`SuccessAction=poweroff` and `FailureAction=poweroff` request the normal manager
shutdown transaction, as specified by the
[unit contract](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.unit.xml)
and implemented in [emergency-action.c](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/emergency-action.c).
The five pinned upstream units order `shutdown.target`, `umount.target`, and
`final.target` before `systemd-poweroff.service` hands off to `systemd-shutdown`.
There is no direct poweroff syscall helper, klibc shutdown command, or systemctl
substitute in this fixture. Failure can still power off; **poweroff alone is not
success**. The host must require the fresh matching receipt and all eight checks
as well as independently observed ACPI S5.

## Pinned inputs and preparation

The 28 ELF files and six upstream data/unit files come from the already pinned
Ubuntu Server 24.04.4 x86-64 ISO, SHA-256
`e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`.
Its `casper/ubuntu-server-minimal.squashfs` member is 166,309,888 bytes, SHA-256
`cbb98254e0f38428994db0e1cf45fb4512af17d59ff98189acb1a6a104aa5681`.
The recipe pins every extracted file, its installed path/mode, observed ELF
interpreter/SONAME/DT_NEEDED metadata, and all nine local sources.

The runtime includes `systemd-executor`, which v255 uses for
[service process creation](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/execute.c),
and the complete interpreter/DT_NEEDED closure of PID 1, executor, shutdown, and
BusyBox. Optional features that load libraries dynamically are outside this
minimal service. No extracted guest program executes on the host.

Only this builder opts into the exact literal
`DT_RUNPATH=/usr/lib/x86_64-linux-gnu/systemd` found in the three systemd
executables. RPATH, other RUNPATH values, loader tokens, relative paths, and
directory lists are rejected. The glibc builder retains its strict default
rejection of search-path overrides. A fixed standard-directory symlink to
`systemd/libsystemd-shared-255.so` also resolves the core library's dependency
without depending on parent RUNPATH inheritance or loader traversal order.

Use Python 3, ISO-capable libarchive `tar`, and `unsquashfs` with `-cat` support:

```sh
python3 scripts/prepare-virtualization-fixtures.py \
  --id ubuntu-server-24.04.4-x86_64 \
  --cache-directory /tmp/dory-p02-systemd-guest-fixtures \
  --extract --systemd-diagnostic-initramfs
```

Add `--verify-only` to require an exact cached ISO and forbid downloading.
The preparer streams the pinned squashfs member and selected files with one
worker and a 16 MiB extractor cache. Each member is limited to 8 MiB, the total
upstream input to 32 MiB, and the archive to 33 MiB. Extraction failures, size or
hash mismatches, missing dependencies, duplicate paths, and unsafe paths fail
before archive publication. Existing mismatched cache records are preserved.
Use a fresh output cache when the builder or recipe changes: the manifest binds
their exact source hashes.

The output is `x86_64-p02-systemd-userspace-v1.cpio`, **19,935,232 bytes**, SHA-256
`3365a741cf5dcecd8675eed4da01b2ed31395f56125d026f461c8f48948f196a`.
It is uncompressed `newc`, with sorted names, sequential inodes, zero
UID/GID/timestamps, fixed modes/devices, and 512-byte padding. The companion
`.manifest.json` records the builder, recipe, upstream inputs, local sources,
ELF closure, guest links, output identity and qualification limits. No binaries
are checked into the repository.

## Later guest acceptance

The kernel must provide the API filesystems and cgroup facilities required by
[systemd v255](https://raw.githubusercontent.com/systemd/systemd/v255/README).
PID 1 mounts those filesystems; the workload verifies them and mounts a separate
8 MiB tmpfs at `/run/dory`, leaving the manager's `/run` intact. Include
`systemd.unified_cgroup_hierarchy=1` because the supervision check requires a
unified cgroup path.

For a later authorized run, prepare the existing pinned Alpine 6.18.35 kernel
in a separate cache, then invoke the built runner explicitly. These are bounded
experimental probe commands, not a claim that the guest has passed:

```sh
python3 scripts/prepare-virtualization-fixtures.py \
  --id alpine-virt-3.24.1-x86_64 \
  --cache-directory /tmp/dory-p02-systemd-kernel-inputs --extract

run_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
/absolute/path/dory-pc-linux-boot-runner \
  --kernel /tmp/dory-p02-systemd-kernel-inputs/x86_64-vmlinux \
  --kernel-sha256 e48a2de81362198d41bcac5519c6ae2d8f19e056aec4763fa590d000abf348d8 \
  --initrd /tmp/dory-p02-systemd-guest-fixtures/x86_64-p02-systemd-userspace-v1.cpio \
  --initrd-sha256 3365a741cf5dcecd8675eed4da01b2ed31395f56125d026f461c8f48948f196a \
  --command-line 'console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1 rdinit=/init systemd.unified_cgroup_hierarchy=1 systemd.log_target=console systemd.show_status=false' \
  --tier baseline-jit --memory-mib 512 \
  --max-instructions 2000000000 --wall-seconds 900 --run-id "$run_uuid" \
  --diagnostics /tmp/dory-p02-systemd-probe.json \
  --workload bootstrap.filesystems --workload syscall.identity \
  --workload process.creation_exec_wait --workload memory.allocation_copy \
  --workload signal.handler_return --workload timer.sleep_elapsed \
  --workload filesystem.write_read_sync --workload systemd.service_supervision
```

The runner adds the UUID to the kernel command line. Both service commands
require exactly one canonical lowercase UUID and the receipt repeats it. Guest
startup has a 30-second service timeout, while the host independently enforces
instruction and monotonic wall budgets. Retain the runner identity, invocation,
diagnostic JSON, console and exit status; missing fixtures or receipts must fail.

The workload covers identity, child creation/exec/wait, a 64 KiB shell string,
USR1 delivery to the service process, a one-second sleep, a 64 KiB tmpfs file
round trip, and the systemd supervision check. It does not qualify a complete
distribution, journald, udev, networking, PAM login, disk persistence, stress,
or exhaustive syscall behavior.

## Offline checks

```sh
python3 scripts/test-prepare-virtualization-fixtures.py
shellcheck -x -s sh guest/diagnostics/p02-systemd-userspace/common \
  guest/diagnostics/p02-systemd-userspace/workload \
  guest/diagnostics/p02-systemd-userspace/receipt
```

Tests inspect synthetic ELF and archive data, receipt record rejection, unit
ordering inputs, deterministic construction and cache preservation. Host shell
tests run only the isolated pure receipt validation/formatting functions; they
never start systemd, a guest workload, mounts, or a poweroff operation. Actual
systemd service behavior requires the later guest receipt and host evidence.
