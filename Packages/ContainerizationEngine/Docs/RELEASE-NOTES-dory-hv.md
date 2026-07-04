# Dory 0.3 — Dory's own engine

Dory now runs on its own container engine, built from scratch. No more dependency on Apple's
`container` toolchain, no per-container VMs, and the same lightweight behaviour for everyone.

## What's new

**Dory's own VMM.** Containers run in one shared Linux VM powered by `dory-hv`, a virtual machine
monitor we built directly on Apple's Hypervisor.framework. Dory controls the whole stack — the
CPU, memory, devices, and networking — so performance is uniform on every supported Mac.

**Lower memory than OrbStack.** dory-hv reclaims memory back to macOS as your containers idle,
using free-page reporting instead of holding a fixed allocation. On an idle Postgres a fresh
engine settles around 470 MB versus OrbStack's ~850 MB, and the gap widens with more containers.
The memory is genuinely returned, not just compressed.

**Self-contained.** The engine ships its own Linux kernel and userspace networking, so a fresh
install needs nothing else — no Homebrew, no Apple container toolchain, no separate downloads.
It runs on macOS 15 (Sequoia) or later on Apple silicon. Intel and older Macs can still pair Dory
with any Docker-compatible engine.

**Everything you'd expect works.** `docker` CLI and API, published ports (`docker run -p`),
volumes and images that persist across restarts, one-click Kubernetes, Linux machines, and
`*.dory.local` domains.

## Under the hood

- 4 virtual CPUs, with memory that flexes up under load and falls back when idle.
- A journaled data disk keeps your images, containers, and volumes safe across restarts and even
  an unclean quit; the system disk is disposable and rebuilt every boot.
- Graceful shutdown syncs and powers the VM off cleanly in about two seconds.
- Published container ports are forwarded to `localhost` automatically as containers start and
  stop.

## Notes

- The engine is on by default on supported hardware. Set `DORY_HV_ENGINE=0` to fall back to a
  Docker-compatible engine if you ever need to.
- gvproxy (Apache-2.0) provides userspace networking and ships inside the app.
