# Dory virtio-fs file sharing: benchmark and analysis

Date: 2026-07-04. Host: Apple Silicon, macOS 27.0. Measured end to end on a real dory-hv guest
(kernel 6.12.30-dory) mounting a virtio-fs `--share` of a macOS directory, vs OrbStack via a
container bind mount of the same directory. Docker Desktop not installed on this host.

## Headline

A caching-correctness bug made every virtio-fs read — even a re-read of the same bytes — take a full
FUSE round-trip. After fixing it, plain virtio-fs on the realistic (cache-resident) workload matches
and slightly beats OrbStack. The remaining gap is only on the deliberately cache-bypassed data plane,
which is a per-request-latency problem for DAX / passthrough to close, not the plain-path gate.

## Results (fio 4k random read, same params on both engines)

| Workload | Dory before | Dory plain virtio-fs | Dory DAX | OrbStack |
|---|---|---|---|---|
| Single, cache-resident (`invalidate=0`) | ~18k (broken) | 1,075k | **1,186k** | 1,011k |
| Single, raw / cache-bypassed (`invalidate=1`) | 18k | 20.1k | **1,074k** | 223k |
| 16 parallel jobs, raw | ~28k | 43k | **4,147k** | — |

Two independent wins:
- **Plain virtio-fs** now matches/beats OrbStack on the realistic cache-resident workload (1.06x), passing
  the "not broken, within 1.5x" gate — after fixing page-cache retention (below).
- **DAX** removes the per-read guest<->host round-trip entirely, so even the deliberately cache-bypassed
  raw path hits 1,074k IOPS — **54x** over plain virtio-fs and **~4.8x past OrbStack** on the one path
  OrbStack was winning. DAX maps file pages directly into guest memory via `hv_vm_map`; reads are plain
  loads with zero FUSE traffic. Enable with `--share tag=/path:dax` and `mount -o dax=always`.

## The bug: the guest page cache was never retained

Diagnostic (read a stable 128 MiB file twice inside the guest):

| | before fix | after fix |
|---|---|---|
| `Cached:` in /proc/meminfo after read #1 | did not grow | +131 MiB |
| read #2 wall time | same as read #1 | 0.03s (~4.3 GB/s, cache hit) |

Before the fix a re-read cost the same as a cold read — nothing was cached. Two mistakes in the FUSE
attribute replies combined to defeat the guest page cache:

1. **LOOKUP returned `attr_valid = 0`** (`fuse_entry_out`), so the guest treated cached metadata as
   immediately stale and revalidated on essentially every access.
2. **Every attr reply carried `mtime_nsec = 0`** (only whole seconds were reported). We advertise
   `FUSE_AUTO_INVAL_DATA`, under which the kernel drops the page cache when a cached read observes a
   changed mtime. Because the real host mtime has nonzero nanoseconds but we always reported `.000`,
   an unchanged file looked modified on every revalidation, so the cache was thrown away each time.

Fix: report a 1-second `attr_valid`/`entry_valid` window and the real host `atime/mtime/ctime`
nanoseconds. `FUSE_AUTO_INVAL_DATA` is kept — with correct nsecs it now invalidates only on a genuine
host change, which is the correct cache=auto behavior (a shared file the host edits becomes visible
within the 1s window / on next open).

## The secondary fix: FUSE processing off the vCPU thread

Independently, request handling used to run synchronously on the vCPU thread inside the MMIO
queue-notify exit — a blocking `pread` per request with the guest frozen until it completed, so a deep
request queue collapsed to effective depth 1. It now dispatches to a small pool of drainers
(bounded by CPU count, out-of-order completion) so the vCPU returns immediately and concurrent
readers run in parallel. This lifted the raw concurrent number (28k → 43k pre-cache-fix) and is the
architecturally-correct model (no production virtio-fs backend blocks the vCPU). Also fixed
`FUSE_MAX_PAGES` so the advertised 256-page (1 MiB) request size is actually honored instead of the
guest clamping to 128 KiB.

## The raw-plane latency, and how DAX closed it

Measured breakdown of a plain-virtio-fs cache-bypassed 4k read (~50 µs): ~10 µs host `pread` (SSD for
the random working set), ~10 µs Swift per-request overhead (now removed by zero-copy `preadv`), and
~40 µs of guest<->host round-trip (a vCPU MMIO-exit per kick + a GIC interrupt per completion). No
amount of FUSE-server tuning removes the 40 µs round-trip — the only fix is to stop doing a round-trip
per read.

**DAX does exactly that** and is now working end to end. Getting there required three fixes, all found
by booting a real guest: enabling the `ZONE_DEVICE -> FS_DAX -> FUSE_DAX` kernel-config chain (defconfig
drops it, so the guest never even compiled DAX support); correcting `fuse_setupmapping_in` from 48 to its
real 40 bytes (every SETUPMAPPING was rejected as a short frame); and mapping the host region read-write
(Apple's `hv_vm_map` rejects a read-only host mapping) while keeping the guest's stage-2 protection
read-only. With DAX, the raw 4k-randread number is 1,074k IOPS — the round-trip is gone.

## Zero-config sharing (the OrbStack "just works" default)

The benchmarks above ran through a manual `dory-hv boot --share` harness. In the app, sharing is
now wired automatically: the engine shares the user's home directory at its identical guest path
(`home=$HOME:rw:at=$HOME:safe`), so a bind mount like `docker run -v ~/project:/app` resolves with no
configuration — the guest sees `~/project` at the same path, which is the virtio-fs mount. This uses
**plain** virtio-fs, not DAX (DAX stays opt-in via `:dax` for the raw-plane win): plain matches
OrbStack on realistic cache-resident workloads with none of DAX's window-thrashing or read-only-file
caveats.

**Security — the `:safe` denylist.** Sharing the whole home tree read-write would expose credential
stores (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, …), shell rc files, and `~/Library` to every
container — a real exfiltration/rc-poisoning risk. `:safe` applies `VirtioFSShareConfiguration.sensitiveNames`,
which `HostFS` hides by name at any depth: a lookup of a hidden name fails as not-found and hidden
entries are omitted from directory listings, so no container can read or overwrite them. This is
defense-in-depth for the convenience share; the stronger guarantee — sharing only the exact paths a
container `-v`-mounts, nothing else — is per-bind-mount **on-demand sharing**, tracked as a follow-up
(it needs the transparent-proxy shim to intercept `/containers/create` plus an engine-side authorization
channel, so it is a multi-component change, not a flag).

Verified end to end on a real dory-hv guest: with `:safe`, `~/.ssh`/`~/.aws`/`~/.zshrc` are invisible
(lookup fails, absent from `ls`) while `~/project` reads, writes, and lists normally. Separately, the
guest now advertises `FUSE_DO_READDIRPLUS` so shared directories actually enumerate — without it the
server saw plain `FUSE_READDIR` (unhandled) and every `ls` returned empty.

## Write correctness

Writes go through the same FUSE server for both plain and DAX shares. `SETATTR` now honors
`FATTR_SIZE`, so `truncate()` and `O_TRUNC` opens actually resize the host file — previously the size
field was dropped and an overwrite left a stale tail (we do not negotiate `atomic_o_trunc`, so the
guest relies on a separate `SETATTR size=0` for every `O_TRUNC`). Verified in a guest with
`-o dax=always`: O_TRUNC (41→3 bytes), ftruncate shrink/grow, extending write (0→4 MiB), create,
in-place overwrite, and write/read coherency all persist correctly to the host.

## Reproducing

```sh
guest/kernel/build.sh                         # build guest/out/Image
dory-hv boot --kernel guest/out/Image --disk <fio-rootfs.ext4> \
  --share bench=<macos-dir>:rw --cmdline "console=ttyAMA0 root=/dev/vda rw init=/init"
# in the guest: fio --rw=randread --bs=4k --ioengine=psync --invalidate=0|1 --numjobs=1|16 ...
scripts/benchmark.sh fileshare                # competitors, auto-detected sockets
```
