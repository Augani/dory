# Default Go preemption reproducer (A16)

This retains the regexp/goroutine workload previously available only in a private
campaign directory. It runs 32 goroutines, 4,000 iterations per goroutine, and
checks 1,024 regexp matches on every iteration. Successful output is
`regexpstress-ok total=133056000` with exit zero. It deliberately uses four Go
processors, matching the original stress workload. No Go preemption override is
set by the program.

Build from this directory with `make build GO=/path/to/go OUT=/absolute/probe`.
The build selects Go 1.22.10, Linux amd64, baseline v1 and no C dependencies.
The Go toolchain downloader verifies the selected toolchain through Go's module
checksum mechanism. Retain `go version -m`, the source SHA-256 and the produced
binary SHA-256 with every campaign. This pinned regression toolchain does not
establish the application's supported Go-version matrix.

The retained September 6 comparison binary reports **Go 1.22.10** in its own
build metadata. Earlier notes also mention Go 1.25.9; those are separate inputs.
The newly built source is a new fixture: do not claim byte equivalence with the
old binary without comparing hashes.

## Disposable native-HV reproduction

Use the exact 4 KiB ARM kernel, ARM64 initfs and entitled development `dory-hv`
runner. Clone the initfs into a new campaign directory before making any writes.
Never inject this init program into a user VM or the original initfs. Require
space for the clone, 2 GiB guest RAM, a 160-second outer process deadline and a
bounded log. Record all kernel/rootfs/FEX/FEXServer/probe/runner digests.

With an offline ext4 editor, write the probe to `/regexpstress` and the `init`
file from this directory to `/dory-fex-init`, both mode 0755. For example, on the
**owned clone only**, use debugfs commands `write PROBE /regexpstress`,
`set_inode_field /regexpstress mode 0100755`, `write INIT /dory-fex-init`, and
`set_inode_field /dory-fex-init mode 0100755`. Verify every write; debugfs can
report command errors without a nonzero process status.

Run the runner's existing `agent-ping` diagnostic with `--kernel KERNEL`,
`--initfs CLONE`, `--mem-mb 2048`, `--cpus 4`, `--timeout-sec 150`, and
`--cmdline "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 root=/dev/vda rw panic=0 init=/dory-fex-init"`.
The custom init runs the test instead of the guest agent. Consequently runner
exit 1 with “guest stopped before agent answered” is expected after poweroff;
**use the guest case markers and outputs**, not that runner exit, for verdicts.
An outer timeout, missing case marker, wrong digest, or missing completion
marker is incomplete evidence. Confirm process exit before removing the clone.

The first case has default Go asynchronous preemption. The second sets
`GODEBUG=asyncpreemptoff=1` as a diagnostic control only. The control cannot close
compatibility or authorize a translator pin update. Repeat with identical inputs
for an upstream control and candidate FEX/FEXServer, and preserve all failures.
This fixture does not cover nested signals, binfmt, syscall restart, execveat,
seccomp, Docker or promotion/rollback acceptance.
