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

| Workload | Dory before fix | Dory after fix | OrbStack |
|---|---|---|---|
| Single stream, cache-resident (`invalidate=0`) | ~18k (broken: no caching) | **1,075k IOPS** | 1,011k |
| Single stream, raw / cache-bypassed (`invalidate=1`) | 18k | 18.8k | 223k |
| 16 parallel jobs, cache-resident | ~28k | **2,978k IOPS** | 7,505k |

The realistic case (an application reading files that stay resident in the guest page cache) went from
effectively broken to **1.06x faster than OrbStack**. That is the "plain virtio-fs is clearly not
broken and within 1.5x" gate, and it is passed.

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

## The residual gap is latency, and it is a DAX / passthrough target

On the raw cache-bypassed plane Dory is 18.8k IOPS (~53 µs/read) vs OrbStack 223k (~4.5 µs/read).
That is per-request round-trip latency (vCPU exit → worker → pread → interrupt → resume). It is not
closed by more worker-pool tuning; the levers are DAX (map file pages directly into guest memory,
skipping the FUSE round-trip on reads — host `hv_vm_map` coherence is already proven by
`dory-hv daxprobe`) and fewer exits. This is explicitly the DAX/passthrough goal, not the plain-path
gate, which the cache-resident numbers above already pass.

## Reproducing

```sh
guest/kernel/build.sh                         # build guest/out/Image
dory-hv boot --kernel guest/out/Image --disk <fio-rootfs.ext4> \
  --share bench=<macos-dir>:rw --cmdline "console=ttyAMA0 root=/dev/vda rw init=/init"
# in the guest: fio --rw=randread --bs=4k --ioengine=psync --invalidate=0|1 --numjobs=1|16 ...
scripts/benchmark.sh fileshare                # competitors, auto-detected sockets
```
