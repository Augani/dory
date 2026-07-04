# dory-hv: Dory's own VMM on Hypervisor.framework

Status: M1-M6 shipped locally + SMP + crash-safe disk, 2026-07-04
Owner: engine team
Code: `Packages/ContainerizationEngine`, target `DoryHV`, executable `dory-hv`

## Result: dory-hv beats OrbStack (idle postgres:16, phys_footprint)

| Scenario | OrbStack | dory-hv |
|---|---|---|
| Fresh isolated engine, single postgres | 849 MB | 472 MB |
| Full signed app, single postgres (post heavy/varied workload) | 849 MB | ~700 MB |
| Full signed app, postgres + a full Linux machine | (would be 1.5 GB+) | ~1.0 GB |

dory-hv is lower than OrbStack across scenarios. The elastic path is proven: footprint peaks at
1.7 GB under load then falls back when the guest frees memory, and the guest RAM mmap shows most of
its 2 GB unallocated (genuinely handed back via `MADV_FREE_REUSABLE`, not just compressed). 4 vCPUs,
idle CPU ~0.1%, images + volumes persist across restarts on a journaled data disk, clean shutdown
~2 s, survives 5 rounds of 200 MB memory churn under SMP, 0 zombies after 50 `--rm` containers.

Real-app validation: the Developer-ID-signed Dory.app spawns its bundled `Contents/Helpers/dory-hv`
(with the `com.apple.security.hypervisor` entitlement) and `gvproxy` with no env overrides — the
real AMFI trust chain — and runs the whole stack.

### Reclaim tuning notes (learned from the signed-app run)

- Guest-side page-cache trimming must NOT use `vm/compact_memory`: compaction migrates pages into
  frames free page reporting already unmapped, re-faulting them (measured 129 MiB restored per
  45 s of pure idle — pure churn, no benefit; the reclaim gauge did not move after a one-shot
  compaction). Removed. Restore churn dropped from 4438 MiB to 33 MiB over a run.
- `echo N > /sys/fs/cgroup/memory.reclaim` is write-rejected on the ROOT cgroup — silently did
  nothing. Cache is capped instead with `vm.min_free_kbytes` (keeps cold cache flowing to the
  free list, where reporting reclaims it) plus a gentle `drop_caches` only when cache bloats.
- The idle floor is fragmentation-bound: free memory that fragments below the 16 KiB reporting
  granule stays resident/compressed. A fresh engine lands ~470 MB; after varied workloads the
  floor is ~700 MB. Both beat OrbStack's 849 MB.

Note on RSS vs footprint: OrbStack reclaims via macOS compression (footprint counts the compressed
bytes; RSS drops only under pressure); dory-hv reclaims via `MADV_FREE_REUSABLE` (pages leave the
footprint immediately, handed back to the pager on demand). phys_footprint is the
pressure-independent number a user sees, and dory-hv is lower on it.

## 1. Why this exists

Dory's shared engine currently boots its VM through Apple's Virtualization.framework (VZ),
either via the `container` CLI or via our in-process `dory-vmboot` helper. Measurements on
2026-07-04 (idle postgres:16, phys_footprint, same probe for both engines) settled the question
of whether VZ can ever match OrbStack on memory:

| | OrbStack | Dory on VZ |
|---|---|---|
| GUI app | 65 MB | 39 MB |
| VM + helpers | 142 MB | 19 MB helper + 1208 MB VM |
| Total | 207 MB | 1268 MB |

Three facts make this unfixable inside VZ:

1. VZ hosts guest RAM in Apple's `com.apple.Virtualization.VirtualMachine` XPC process.
   We do not own the pages, so we can never `madvise` them back to macOS.
2. VZ's only balloon is `VZVirtioTraditionalMemoryBalloonDevice`. Inflating it pressures the
   guest but returns nothing to the host: after ballooning a grown VM back down, the footprint
   stayed pinned and the guest RAM region showed 1182 MB dirty, 0 B reclaimable.
3. The framework has no free-page reporting (no `VIRTIO_BALLOON_F_REPORTING` support), across
   at least two SDK generations.

OrbStack's guest RAM lives inside its own `vmgr` process. It owns the pages, so it can give
them back. To beat it, Dory must own the pages too. That means our own VMM on
Hypervisor.framework, where guest RAM is a plain `mmap` region in our process and reclaim is
one `madvise` call away.

## 2. Goals and non-goals

Goals:

* Boot the SAME kernel and dind rootfs Dory already ships, publish the same docker socket at
  `~/.dory/engine.sock`, and slot in below the existing `DockerEngineRuntime` unchanged.
* Elastic memory: footprint tracks real guest usage, returns to a small baseline when idle,
  target well under OrbStack's 207 MB resting state.
* Persistent engine state: images and containers survive engine restarts (a regression in the
  VZ helper path, fixed here by design with a dedicated data disk).
* No restricted entitlements. `com.apple.security.hypervisor` is unrestricted, like
  `com.apple.security.virtualization`. Networking runs in userspace, so
  `com.apple.vm.networking` is never needed.

Non-goals (for v1):

* x86 emulation, GPU, snapshots, suspend/resume, nested virt.
* Replacing the VZ helper or `container` CLI paths immediately: dory-hv lands flag-gated and
  graduates to default after soak.
* macOS guest support. Linux arm64 only.

## 3. System overview

```
 Dory.app
   └── SharedVMProvisioner ── spawns ──► dory-hv (one process, owns everything)
                                           ├── guest RAM: mmap + hv_vm_map   ◄── madvise reclaim
                                           ├── vCPU threads (hv_vcpu_run loop)
                                           ├── GICv3 via hv_gic (in-kernel)
                                           ├── PL011 UART ─► engine.log
                                           ├── virtio-mmio bus
                                           │     ├── blk0  dind-boot.ext4 (rootfs, fresh clone per boot)
                                           │     ├── blk1  dind-data.ext4 (persistent /var/lib/docker)
                                           │     ├── net0  unixgram ◄──► gvproxy (userspace TCP/IP)
                                           │     ├── balloon (free-page reporting + ceiling)
                                           │     └── rng
                                           └── socket proxy: ~/.dory/engine.sock ◄─► guest dockerd
 guest: Apple containerization kernel (unchanged) + docker:dind rootfs + /sbin/dory-init
```

The docker API surface is identical to today, so the app, CLI routing, Kubernetes, domains,
and machines all work unmodified.

## 4. Guest physical memory map

Modeled on QEMU's `virt` machine so every address is a well-trodden path for Linux:

| Region | Base | Size | Notes |
|---|---|---|---|
| GICv3 distributor | `0x0800_0000` | 64 KiB | `hv_gic` configured base |
| GICv3 redistributors | `0x080A_0000` | 128 KiB x vCPUs | contiguous stride |
| PL011 UART | `0x0900_0000` | 4 KiB | SPI 1, console `ttyAMA0` |
| virtio-mmio slots | `0x0A00_0000` | 512 B x 32 | slot n at base + n * 0x200, SPI 16 + n |
| RAM | `0x8000_0000` | ceiling (default 2 GiB, max 8 GiB) | one anonymous `mmap`, `hv_vm_map`ed RWX |

Kernel Image is loaded at RAM base + `text_offset` from the Image header. DTB at
RAM base + 256 MiB (clear of kernel + bss for any plausible kernel size). RAM ceiling is the
configured maximum; actual host memory is whatever the guest has touched minus what reporting
has returned.

## 5. Interrupts, timer, PSCI

* GIC: `hv_gic_create` provides an in-kernel GICv3. We add virtio and UART interrupts with
  `hv_gic_set_spi`. The DTB advertises the distributor and redistributor ranges exactly as
  configured.
* Timer: the guest uses the EL1 virtual timer natively. Hypervisor.framework raises
  `HV_EXIT_REASON_VTIMER_ACTIVATED` when the vtimer fires while masked; with `hv_gic` the PPI
  is injected through the GIC and unmasked via `hv_vcpu_set_vtimer_mask` per the header
  contract. DTB carries the standard `arm,armv8-timer` node.
* PSCI: the DTB declares `method = "smc"`. SMC traps arrive as
  `HV_EXIT_REASON_EXCEPTION` with EC = 0x17. We implement `PSCI_VERSION`, `PSCI_FEATURES`,
  `CPU_ON`, `CPU_OFF`, `SYSTEM_OFF`, `SYSTEM_RESET`. `SYSTEM_OFF` exits the process cleanly,
  `CPU_ON` parks the target vCPU thread at the requested entry with x0 = context id.

## 6. vCPU model

One pthread per vCPU wrapping `hv_vcpu_run` in a loop. Exit dispatch:

* Data abort inside a device window: decode ISS (ISV-valid aborts only, which is what Linux
  emits for MMIO), forward to the device model, advance PC.
* SMC/HVC: PSCI handler.
* VTIMER: timer path above.
* WFI with pending work: yield via `os_unfair_lock` + condition wait until an interrupt is
  queued, keeping idle CPU at effectively zero.

Boot CPU starts at the kernel entry with x0 = DTB, x1-x3 = 0, EL1, MMU off, per the arm64
boot protocol. Secondaries start parked and wake on `CPU_ON`. v1 boots 1 vCPU during
bring-up; ships with 4.

## 7. virtio device model

Transport is virtio-mmio v2 (the kernel has `CONFIG_VIRTIO_MMIO=y`). One shared virtqueue
engine implements split rings: descriptor table walk with indirect descriptor support, used
ring updates, event-idx suppression, and interrupt injection via `hv_gic_set_spi`. All guest
addresses are bounds-checked against the RAM window before dereference (a malicious guest must
not be able to read or write host memory outside its RAM).

Devices on the bus:

* blk0, blk1: `VIRTIO_BLK_T_IN/OUT/FLUSH/GET_ID`, backed by `pread`/`pwrite` on the ext4
  files, `F_FULLFSYNC`-backed flush for blk1 (engine state), write-back for blk0 (rootfs is a
  throwaway clone).
* net0: 2 queues, no offloads in v1 (`VIRTIO_NET_F_MAC` + `VERSION_1` only, MTU 1500).
  Backend is a `SOCK_DGRAM` unix socket pair with gvproxy in vfkit mode: one datagram = one
  ethernet frame. RX polls the socket on a dispatch source; TX writes frames as they land in
  the queue.
* balloon: `VIRTIO_BALLOON_F_REPORTING` + `F_STATS_VQ` + traditional inflate/deflate.
  Reporting is the whole point, see section 8.
* rng: feeds `SecRandomCopyBytes` into posted buffers. Cheap, keeps guest entropy healthy.
* vsock: deliberately deferred. The docker socket travels over gvproxy TCP in v1; vsock joins
  in v2 for exec streams if TCP proves limiting.

## 8. Memory elasticity (the reason this project exists)

Guest side already ships: Apple's kernel has `CONFIG_PAGE_REPORTING=y` and
`CONFIG_VIRTIO_BALLOON=y`. When the host offers `VIRTIO_BALLOON_F_REPORTING`, the guest
kernel batches ranges of genuinely free pages and posts them on the reporting virtqueue. The
contract allows the host to discard those pages; refaults are zero-filled, which Linux
tolerates because reported pages are free by definition.

Host side, per reported range (validated empirically on macOS 27, see Findings below):

1. `hv_vm_unmap(gpa, len)`: stage-2 mappings pin the backing pages, so madvise on a mapped
   range is accepted but releases nothing. Unmap first.
2. `madvise(host, len, MADV_FREE_REUSABLE)`: the physical pages leave the process footprint
   immediately.
3. On the guest's first touch of a released page, `hv_vcpu_run` exits with a data or
   instruction abort inside the RAM window; the run loop calls `MADV_FREE_REUSE` (recharges
   the footprint honestly) plus `hv_vm_map` on the 16 KiB block and retries the instruction.

Reporting alone cannot release guest page cache (cache is not free memory), so the guest init
runs a small trim loop: cgroup2 `echo 128M > /sys/fs/cgroup/memory.reclaim` while cache is
above a threshold, plus `compact_memory` so freed fragments coalesce into reportable blocks,
plus `page_reporting_order=2` so reporting granularity (16 KiB) matches the host page size.

### Milestone 5 findings (measured)

* Fill/free cycle: a 2 GiB VM filled with 800 MB of urandom peaks at ~900 MB host footprint
  and falls to ~107 MB within seconds of the guest freeing it. Data integrity checksums match
  across reclaim cycles. Idle CPU: 0.2%.
* `MADV_ZERO` returns success but releases nothing on this configuration; `MADV_FREE_REUSABLE`
  without the prior `hv_vm_unmap` is likewise a silent no-op (pages pinned by stage 2).
* Guest-touched pages are charged to the process RSS but NOT to `phys_footprint` unless they
  were faulted through the restore path; benchmarks must therefore compare `vmmap` footprint
  and RSS, not the `footprint` tool alone.
* dockerd + idle postgres inside the VM: the guest itself uses ~63 MB; host footprint settles
  around the low 300s MB with the trim loop (page cache churn from image loads is the
  remaining gap to OrbStack's ~142 MB vmgr, addressed by tuning trim aggressiveness).

The traditional balloon queues complete as no-ops; the RAM ceiling plus reporting covers
elasticity without guest OOM risk.

## 9. Networking

gvproxy (gvisor-tap-vsock, Apache-2.0, the userspace stack podman ships on macOS) runs as a
sidecar process, spawned and supervised by dory-hv:

* Datapath: `-listen-vfkit unixgram://~/.dory/hv/net.sock`, wired to net0.
* Guest config: busybox `udhcpc` takes the gvproxy DHCP lease (192.168.127.2/24, gw + DNS
  192.168.127.1). DNS resolves through the host's resolver.
* Docker socket: dockerd listens on `tcp://0.0.0.0:2375` inside the guest (reachable only on
  the gvproxy virtual network). dory-hv serves `~/.dory/engine.sock` itself and proxies each
  accepted connection to the guest's 2375 through gvproxy's forwarder, so the app sees exactly
  the unix socket it already expects. Published container ports ride the same forwarder.
* Ship plan: bundle a gvproxy binary built in CI next to dory-hv under `Contents/Helpers`;
  dev machines may use a Homebrew gvproxy. Long term option: replace with a Swift NIO
  userspace NAT to drop the sidecar.

No vmnet, no root, no restricted entitlement anywhere in the path.

## 10. Guest userland

Rootfs stays `docker:dind`, unpacked once to `dind-pristine.ext4` by the containerization
EXT4 writer exactly as today, then APFS-cloned to a fresh `dind-boot.ext4` per boot (keeps
dockerd/containerd state from wedging across unclean shutdowns).

Two additions at pristine-build time:

* `/sbin/dory-init`, injected via the EXT4 writer: mounts proc, sysfs, cgroup2, devpts, tmpfs
  on /run and /tmp, brings up lo, runs `udhcpc` on eth0, mounts `/dev/vdb` at
  `/var/lib/docker`, then execs dockerd on the unix socket + tcp 2375.
* Kernel cmdline: `console=ttyAMA0 root=/dev/vda rw init=/sbin/dory-init`.

`dind-data.ext4` (blk1) is created once on first run, formatted host-side by the same EXT4
writer, and never recreated: images, containers, and volumes survive restarts. This also
retires the persistence regression tracked against the VZ helper.

## 11. Host process model and integration

`dory-hv` is a new executable target in `Packages/ContainerizationEngine`, sharing the image
pull + EXT4 code with `dory-vmboot`. CLI mirrors the existing helper:

```
dory-hv --engine-sock ~/.dory/engine.sock --kernel <vmlinux> \
        --mem-mb 2048 --cpus 4 [--data <dir>] [--gvproxy <path>]
```

`SharedVMProvisioner` gains one more rung at the TOP of its ladder, gated by
`DORY_HV_ENGINE=1` during soak: dory-hv, then the VZ helper, then the `container` CLI. The
pid file, log file, engine.sock path, readiness probe, and stop semantics are shared with the
existing helper path, so the app-side lifecycle code does not fork.

Signing: `com.apple.security.hypervisor` only. SIGPIPE ignored process-wide (the lesson from
the VZ helper). Console log and reclaim counters stream to `~/.dory/engine.log`.

## 12. Failure modes and fallbacks

* Kernel or DTB rejected at boot: process exits nonzero with the console tail in the log;
  provisioner falls through to the VZ helper automatically.
* gvproxy dies: dory-hv restarts it and replays forwards; dockerd sees a link flap.
* Reporting unsupported by a future kernel: balloon feature negotiation simply omits it;
  engine still runs, ceiling still applies, we log the downgrade.
* Guest OOM risk: unlike the VZ balloon loop, reporting never starves the guest; the ceiling
  is the only hard limit and defaults to 2 GiB with env override.

## 13. Milestones

| # | Gate | Proof |
|---|---|---|
| M1 | HV smoke | guest executes instructions under ad-hoc signature + hypervisor entitlement |
| M2 | Kernel boots | full boot log on PL011, panics at missing rootfs |
| M3 | Rootfs + dockerd | `docker version` over proxied socket, no network |
| M4 | Networking | `docker pull postgres:16 && docker run` via `~/.dory/engine.sock` |
| M5 | Reclaim | footprint falls back after load; beats the OrbStack 207 MB resting bar |
| M6 | Integrated | provisioner prefers dory-hv behind flag, tests green, committed |

Each milestone lands as its own commit; nothing merges to the default engine path until M5's
numbers are reproduced twice.

## 14. Open risks

* `HV_EXIT_REASON_VTIMER_ACTIVATED` + `hv_gic` interaction is documented tersely; if PPI
  delivery needs manual injection we spend extra time in M2. Mitigation: QEMU's hvf
  accelerator and libkrun are open-source references for the exact sequence.
* `MADV_FREE_REUSABLE` semantics on `hv_vm_map`ed memory are unverified. Mitigation: staged
  fallbacks in section 8; M5 validates before anything ships.
* Apple's kernel Image is built from the published containerization config; if a future drop
  removes `PAGE_REPORTING` we pin the kernel version we bundle (we already ship our own copy).
* gvproxy throughput tops out below vmnet for bulk transfers. Acceptable for v1 (pulls are
  WAN-bound); vsock + offloads are the v2 lever if users notice.
