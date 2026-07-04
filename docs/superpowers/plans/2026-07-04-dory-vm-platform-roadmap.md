# Dory VM Platform Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Scope note:** This is the master roadmap plan. Tracks 0 and 2 are specified to execution granularity here. Tracks 1, 3, 4, 5, 6 are specified to task granularity with locked designs, exact files, protocols, and acceptance gates; before executing one of those tracks, expand it into its own dated plan with superpowers:writing-plans using the design locked here as the spec.

**Goal:** Make dory-hv a full developer platform (custom guest kernel, guest agent, virtio-fs file sharing, real Linux machines with recipes, USB passthrough, x86 support) so Dory is measurably deeper-integrated than OrbStack and Colima, not "just another hypervisor."

**Architecture:** Dory already owns the entire device model (raw Hypervisor.framework VMM in `Packages/ContainerizationEngine/Sources/DoryHV`, no Virtualization.framework in the hot path). The roadmap adds the guest half of the stack: a Dory-built Linux kernel, a vsock control channel, and a guest agent. Every headline feature (virtio-fs, USB/IP, inotify relay, elastic memory) is a host device in DoryHV plus a kernel config plus an agent RPC.

**Tech Stack:** Swift (VMM + app), Go (guest agent, matches gvproxy), Linux 6.12 LTS (guest kernel, Docker-based reproducible build), musl static binaries in the initfs.

## Global Constraints

- Host: macOS 15+, Apple silicon only for dory-hv; the bundled `dory-vm` (Virtualization.framework helper) remains the fallback engine and the vehicle for Rosetta x86 machines.
- Xcode project stays at objectVersion 77; build with stable xcode-select (see docs: Dory build workflow). Never let Xcode 27 GUI re-bump it.
- The package emits products to `.build/out/Products/<config>/`, not swift's `--show-bin-path` location (bundle-engine.sh already handles this).
- dory-hv keeps the single entitlement `com.apple.security.hypervisor`. Any feature that would force a restricted entitlement ships behind a capability check with a graceful "not available" path.
- Free and open source, no paid tier. App zip stays under ~120 MB; the guest kernel must compress under ~8 MB zst, the initfs under ~40 MB zst.
- Guest agent and all initfs additions are static (musl or CGO_ENABLED=0), aarch64.
- All new engine features are gated by integration tests runnable via `scripts/readiness.sh` and benchmarked via `scripts/benchmark.sh` (methodology in `docs/research/benchmark-methodology.md`).
- Every kernel source tarball, Go module set, and rootfs base image is pinned by sha256 for reproducible builds.
- Commit format `type: description`; feature branches `feat/<track>-<name>`; `swift test` in `Packages/ContainerizationEngine` plus `scripts/test.sh` green before every commit.
- No em dashes in any user-facing copy or docs.

---

## Part 1: Positioning (the answer to "you're just another hypervisor")

The criticism: "OrbStack has a custom Linux kernel to translate VM calls to the host; unless you do something better you're just another hypervisor."

The factual response, which this roadmap turns from partially true into fully true:

1. **Dory sits one layer lower than OrbStack.** OrbStack builds on Apple's Virtualization.framework for the VM itself and customizes the guest. Dory implements the VMM itself on raw Hypervisor.framework: its own vCPU loop, GICv3, virtqueues, and every virtio device. That is strictly more control over "translating VM calls to the host" than OrbStack has, because Dory can invent host-side device behavior Apple never exposed.
2. **The proof already shipped:** elastic memory via virtio free-page reporting plus host madvise, measured 472 MB vs OrbStack's 849 MB footprint in a controlled A/B. That is a guest-kernel-cooperating, host-VMM-cooperating feature, exactly the class of integration the critic says defines OrbStack.
3. **What is missing is the guest half as a product:** today Dory ships a generic kernel and no guest agent. Tracks 0 and 1 close that: a Dory-built kernel (dory-guest) and a vsock agent, then virtio-fs with DAX for file sharing. After Track 1 the honest pitch is: "own VMM, own kernel, own guest userspace, measurably lower memory, file sharing on the same mechanism Apple and OrbStack use, plus USB passthrough neither OrbStack nor Colima offers."

Marketing claims unlocked per track are listed at the end of each track.

## Part 2: Gap matrix (2026-07 snapshot)

| Capability | OrbStack | Colima | Dory today | Dory after this plan |
|---|---|---|---|---|
| Own VMM (not vz/QEMU) | No (vz) | No (vz/QEMU) | **Yes** | Yes |
| Custom guest kernel | Yes | No (generic) | No | **Yes (Track 0)** |
| Guest agent / host RPC | Yes | Lima agent | No | **Yes (Track 0)** |
| Elastic memory returned to macOS | Yes (mechanism undocumented) | No | **Yes (free-page reporting), measured lower in A/B** | Yes |
| Fast file sharing (virtio-fs) | Yes (VirtioFS + custom caching) | sshfs/9p/virtiofs | Docker-context only | **Yes + DAX (Track 1)** |
| inotify propagation to guest | Yes (not independently verified) | Experimental, off by default (chmod trick) | No | **Yes, on by default (Track 1)** |
| Linux machines | Yes | Yes (profiles) | Container-backed, basic | **Full distro + systemd + recipes (Track 2)** |
| Machine recipes / declarative provisioning | cloud-init user data | Provision scripts; URL-shareable templates (Lima) | Scaffolding only | **Typed, layered, shareable (Track 2)** |
| `ssh <machine>` + ssh config integration | Yes | Yes | No | **Yes (Track 2)** |
| USB passthrough | No | No | No | **Yes (Track 3)** |
| x86_64 binaries on ARM | Yes (Rosetta) | Yes (QEMU; Rosetta with vz) | No | **qemu-user + Rosetta via vz helper (Track 4)** |
| Direct container IP routing from host | Yes | No | No (ports forwarded) | **Yes (Track 5)** |
| *.local HTTPS domains | Yes | No | **Yes** | Yes |
| Kubernetes | Yes | Yes | **Yes** | Yes |
| Debug shell into distroless containers | Yes | No | No | **Yes (Track 6)** |
| Machine snapshots + portable export | No | No | Partial (portable done) | **Yes (Track 6)** |
| GPU compute in guest | No | No | No | Research spike only (Track 6) |

## Part 3: Track overview and dependencies

```
Track 0: dory-guest foundation (kernel pipeline + virtio-vsock + guest agent)
  |                         \
Track 1: virtio-fs + inotify  Track 3: USB/IP passthrough
  |                            |
Track 2: machines + recipes (needs T0 agent; mounts get fast after T1)
  |
Track 4: x86 tiers (qemu-user needs T0 initfs; Rosetta machines use dory-vm fallback)
Track 5: network polish (independent, needs gvproxy only)
Track 6: DX extras (debug shell needs T0; snapshots independent)
```

Recommended execution order: 0 → 1 → 2 → 3 → 5 → 4 → 6. Track 2 can start its recipe-schema tasks in parallel with Track 1.

---

# Track 0: dory-guest foundation

The prerequisite for everything else and the direct answer to the critic. Deliverable: Dory boots ITS OWN kernel with a vsock device, and a guest agent answers RPCs from the app.

**Branch:** `feat/t0-dory-guest`

### Task 0.1: Reproducible guest kernel build pipeline

**Files:**
- Create: `guest/kernel/build.sh`
- Create: `guest/kernel/dory.config` (kconfig fragment)
- Create: `guest/kernel/PINS` (tarball URL + sha256)
- Modify: `scripts/bundle-engine.sh` (consume `guest/out/Image.zst` instead of the current prebuilt kernel)

**Interfaces:**
- Produces: `guest/out/Image` (aarch64, uncompressed) and `guest/out/Image.zst`; consumed by bundle-engine.sh and by `dory-hv --kernel`.

- [ ] **Step 1: Write the pin file and config fragment**

`guest/kernel/PINS`:
```
KERNEL_VERSION=6.12.30
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.30.tar.xz
KERNEL_SHA256=<fill from kernel.org sha256sums.asc at execution time and commit the literal value>
```

`guest/kernel/dory.config` (fragment applied on top of `defconfig`; everything built-in, no modules, so the initfs needs no module loading):
```
CONFIG_LOCALVERSION="-dory"
CONFIG_MODULES=n
CONFIG_VIRTIO=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_PAGE_REPORTING=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_FUSE_FS=y
CONFIG_VIRTIO_FS=y
CONFIG_DAX=y
CONFIG_FUSE_DAX=y
CONFIG_USBIP_CORE=y
CONFIG_USBIP_VHCI_HCD=y
CONFIG_USB=y
CONFIG_OVERLAY_FS=y
CONFIG_EROFS_FS=y
CONFIG_EXT4_FS=y
CONFIG_BINFMT_MISC=y
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_CRYPTO_ZSTD=y
```
(Keep the docker/k8s requirement set the current kernel already satisfies: netfilter, iptables, bridge, veth, ip_vs, xt_* match modules as =y. Diff the current kernel's /proc/config.gz during execution and carry those symbols over verbatim. Note: arm64 has no self-decompressing kernel, so there is no CONFIG_KERNEL_ZSTD for the arm64 Image; compression stays external, the zstd step below.)

- [ ] **Step 2: Write `guest/kernel/build.sh`**

Docker-based so the build is identical on any Mac (Dory itself provides the docker engine):
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS
OUT="$(pwd)/../out"; mkdir -p "$OUT"
docker run --rm --platform linux/arm64 \
  -v "$PWD":/src -v "$OUT":/out -w /build debian:12-slim bash -euxc '
  apt-get update && apt-get install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  make defconfig
  scripts/kconfig/merge_config.sh -m .config /src/dory.config
  make olddefconfig
  make -j$(nproc) Image
  cp arch/arm64/boot/Image /out/Image
  zstd -19 -f /out/Image -o /out/Image.zst'
```

- [ ] **Step 3: Boot-test the kernel**

Run: `swift build -c release --product dory-hv` in `Packages/ContainerizationEngine`, then
`.build/out/Products/Release/dory-hv boot --kernel guest/out/Image --mem-mb 512 --cpus 2 --cmdline "console=hvc0"`
Expected: kernel banner shows `6.12.30-dory`, reaches the point of failing to find init (no initfs given), no earlier panic.

- [ ] **Step 4: Wire into bundle-engine.sh and commit**

Replace the kernel source line in `scripts/bundle-engine.sh` with `guest/out/Image.zst`; keep the resource name `dory-vm-kernel.zst` so the app's first-launch decompression path is untouched.
```bash
git add guest/kernel scripts/bundle-engine.sh
git commit -m "feat: reproducible dory-guest kernel build pipeline"
```

### Task 0.2: virtio-vsock device in DoryHV

**Files:**
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/VirtioVsock.swift`
- Modify: `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift` (attach device, allocate MMIO slot + IRQ)
- Modify: `Packages/ContainerizationEngine/Sources/DoryHV/FDT.swift` (one more virtio-mmio node)
- Test: `Packages/ContainerizationEngine/Tests/DoryHVTests/VirtioVsockTests.swift`

**Interfaces:**
- Consumes: `VirtioMMIO`/`Virtqueue` infrastructure exactly as `VirtioNet.swift` does (same device registration pattern; copy its MMIO wiring).
- Produces: `final class VirtioVsock: VirtioMMIODevice` with `init(guestCID: UInt32, memory: GuestMemory)` and `func listen(port: UInt32, handler: @escaping (VsockConnection) -> Void)`; `VsockConnection` exposes `read(into:) / write(_:) / close()`. Device ID 19, three virtqueues (rx=0, tx=1, event=2), 64-bit config field `guest_cid`. Host side multiplexes connections in-process (no vsock socket API exists on macOS; the device IS the host endpoint).

- [ ] **Step 1: Failing unit test for the packet layer** (virtio_vsock_hdr is 44 bytes: src_cid u64, dst_cid u64, src_port u32, dst_port u32, len u32, type u16, op u16, flags u32, buf_alloc u32, fwd_cnt u32; test encode/decode round-trip and the OP_REQUEST → OP_RESPONSE handshake against a mock virtqueue).
- [ ] **Step 2: Implement header codec + connection state machine** (states: requested, established, closing; ops: REQUEST 1, RESPONSE 2, RST 3, SHUTDOWN 4, RW 5, CREDIT_UPDATE 6, CREDIT_REQUEST 7; enforce credit accounting with buf_alloc/fwd_cnt or streams stall).
- [ ] **Step 3: `swift test --filter VirtioVsockTests`** until green.
- [ ] **Step 4: Attach in Machine.swift + FDT node, boot-test** with cmdline unchanged; in-guest check: `ls /sys/bus/virtio/devices` gains one device; `cat /sys/class/virtio-ports 2>/dev/null` not needed; definitive check is Task 0.3's agent handshake.
- [ ] **Step 5: Commit** `feat(hv): virtio-vsock device with in-process host endpoint`

### Task 0.3: dory-guest-agent (Go, static) + host RPC client

**Files:**
- Create: `guest/agent/main.go`, `guest/agent/rpc.go`, `guest/agent/go.mod`, `guest/agent/build.sh` (CGO_ENABLED=0 GOARCH=arm64, output `guest/out/dory-agent`)
- Modify: initfs build in `scripts/bundle-engine.sh` (inject `/usr/bin/dory-agent` + init script line to start it)
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/AgentChannel.swift` (host-side typed client over VirtioVsock port 1024)
- Modify: `Packages/ContainerizationEngine/Sources/dory-hv/main.swift` (engine mode starts AgentChannel, exposes `dory-hv agent-ping` subcommand for smoke tests)
- Test: `Packages/ContainerizationEngine/Tests/DoryHVTests/AgentProtocolTests.swift`

**Interfaces:**
- Protocol: length-prefixed JSON frames on vsock port 1024. Request `{"id":1,"method":"ping","params":{}}`, response `{"id":1,"result":{...}}` or `{"id":1,"error":{"code":-1,"message":"..."}}`. Big-endian u32 length prefix, 16 MiB frame cap, unknown method returns error code -32601.
- v1 methods (all later tracks add methods to this table): `ping`, `info` (kernel version, uptime, mem), `exec` (argv, env, stdin b64, timeout ms; returns exit code + stdout/stderr b64), `clock.sync` (host epoch ns; agent clock_settime, called on VM resume from host sleep), `fsevents.batch` (Track 1), `usb.attach`/`usb.detach` (Track 3), `ports.watch` (Track 5: streams LISTEN-socket add/remove diffs by polling /proc/net/tcp, the mechanism Lima's guest agent uses in production since /proc/net/tcp cannot be inotify-watched).
- Produces (host): `final class AgentChannel { func call<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R }`.

- [ ] **Step 1: Failing Swift test** for frame codec + one canned ping round-trip against a stub connection.
- [ ] **Step 2: Implement AgentChannel.swift**, test green.
- [ ] **Step 3: Write the Go agent** (AF_VSOCK listener CID=3 port 1024 via x/sys/unix; dispatch table; exec via os/exec with contexts; clock.sync via unix.ClockSettime). `go vet ./... && go test ./...` in guest/agent.
- [ ] **Step 4: End-to-end smoke:** `dory-hv agent-ping --kernel guest/out/Image --initfs <initfs>` prints the agent's info JSON. Expected output includes `"kernel":"6.12.30-dory"`.
- [ ] **Step 5: Add the smoke to `scripts/readiness.sh`** as track "guest-agent". Commit `feat: dory-guest-agent with vsock RPC (ping/info/exec/clock.sync)`.

### Task 0.4: Clock resync after host sleep

**Files:**
- Modify: `Dory/Runtime/Shared` VM lifecycle owner (locate the class observing engine start; add `NSWorkspace.didWakeNotification` observer)
- Modify: `Packages/ContainerizationEngine/Sources/dory-hv/main.swift` (engine mode: on SIGUSR1 or a control-pipe message, call `clock.sync`)

- [ ] Wire host wake notification → agent `clock.sync`; readiness check: force `date -s` skew in guest via `exec`, trigger sync, assert guest time within 100 ms of host. Commit `fix: guest clock resyncs on host wake`.

**Track 0 exit criteria:** dory-hv boots the Dory-built kernel in under 1.5 s to agent-ready; readiness.sh gains guest-agent track; memory footprint unchanged vs current kernel (re-run benchmark-compare.sh).
**Claims unlocked:** "Dory ships its own VMM AND its own Linux kernel and guest userspace." The critic's sentence is now false by construction.

---

# Track 1: File sharing (virtio-fs + DAX) and inotify relay

The single highest-impact parity feature; OrbStack's headline is fast file sharing. We implement the virtio-fs device and FUSE server in Swift inside DoryHV. DAX (mapping host file pages directly into guest PA space via hv_vm_map) is the phase-2 differentiator that raw Hypervisor.framework makes possible.

**Branch:** `feat/t1-virtiofs` | **Expand into its own plan before execution.**

**Files (locked):**
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/VirtioFS.swift` (device ID 26, hiprio + 1 request queue, config space: tag[36] + num_request_queues; do NOT offer VIRTIO_FS_F_NOTIFICATION, the Linux driver has never implemented it and negotiating it would shift request queues to index 2)
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/Fuse/FuseProtocol.swift` (FUSE major version 7; advertise minor 38 and reject minors below 27 with EPROTO, the exact floor virtiofsd enforces via MIN_KERNEL_MINOR_VERSION; LOOKUP, GETATTR, SETATTR, OPEN, READ, WRITE, READDIRPLUS, CREATE, UNLINK, RENAME2, MKDIR, RMDIR, SYMLINK, READLINK, FLUSH, RELEASE, FSYNC, STATFS, SETXATTR/GETXATTR/LISTXATTR)
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/Fuse/HostFS.swift` (handle table keyed by u64 node id; openat/O_NOFOLLOW everywhere; fixed uid/gid squash: guest uid 1000 ↔ host user; symlink escape prevention by resolving inside the share root only)
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/Fuse/DaxWindow.swift` (phase 2: FUSE_SETUPMAPPING/REMOVEMAPPING; a 4 GiB guest PA window backed by per-file mmap regions mapped with hv_vm_map)
- Modify: `Machine.swift`, `FDT.swift` (device + `dax-window` reg), `dory-hv/main.swift` (`--share tag=path` repeatable flag)
- Modify: `Dory/Runtime/Machines/MachineService.swift` + engine provisioner (mount shares requested by recipes/containers: agent `exec` runs `mount -t virtiofs <tag> <dst>`)
- Test: `Tests/DoryHVTests/FuseProtocolTests.swift`, `Tests/DoryHVTests/HostFSTests.swift`

**Task list:**
- [ ] 1.1 FUSE wire codec + INIT negotiation (TDD against recorded byte fixtures from a real virtiofsd session)
- [ ] 1.2 HostFS read-only ops (LOOKUP/GETATTR/OPEN/READ/READDIRPLUS/STATFS); gate: guest mounts tag `home`, `ls -la` and `cat` match host
- [ ] 1.3 Write path ops + xattr + fsync; gate: `git clone` + `git status` inside the share is clean
- [ ] 1.4 Security pass: symlink escapes, `..` traversal, uid squash, readonly shares flag; explicit tests for each
- [ ] 1.5 inotify relay v1: host FSEvents stream (add an FSEvents watcher per active share alongside `Dory/Engine/EventSynthesizer.swift`) → agent method `fsevents.batch` `{paths:[...]}` → agent re-applies each file's EXISTING permission mode with chmod guest-side, which makes the guest kernel emit inotify events (IN_ATTRIB) so webpack/vite/chokidar watchers fire. This chmod-to-same-mode trick is the mechanism Colima proved in production (daemon/process/inotify/events.go). Do NOT use touch/utimensat: that writes a fresh mtime through virtio-fs onto the real host file and breaks incremental build tools. Our FUSE server additionally no-ops same-mode SETATTR so the relay never dirties host metadata at all. Debounce 50 ms, coalesce duplicate paths per batch; cover all active shares and enable by default (Colima's variant is experimental, off by default, and limited to running-container volumes). v2 differentiator, optional: implement VIRTIO_FS_F_NOTIFICATION (virtio 1.2 section 5.11) in the dory-guest kernel and our device so host changes arrive as real FUSE notifications; mainline Linux has never implemented that feature and we control both sides.
- [x] 1.6 Benchmarks: DONE + recorded in `docs/research/file-sharing.md` + `.json`. Measured end-to-end on a real dory-hv guest (kernel 6.12.30-dory) mounting a virtio-fs `--share`, vs OrbStack bind mount (Docker Desktop not installed on the bench host). Result: virtio-fs works end to end; write + git-status metadata competitive with OrbStack, fio 4k randread ~5.6x behind (motivates DAX + the deferred off-vCPU-thread FUSE I/O, finding #30). Building+booting the from-source kernel also surfaced + fixed two real `guest/kernel/dory.config` bugs: missing serial console (PL011) + devtmpfs (kernel booted blind), and defconfig pulling in GPU/DRM (nouveau) that fails to build (now disabled). DAX guest-mount (`-o dax`) is NOT yet active — guest reports "device does not support it"; host hv_vm_map primitive is proven (daxprobe) but the guest dax_device/SHM-window handshake is deferred (feature stays behind the `:dax` flag).
- [x] 1.7 DAX phase 2 [SPIKE, go/no-go]: transport and guest support are verified facts, not open questions: virtio-mmio gained shared-memory-region registers in virtio 1.2 (SHMSel 0x0ac, SHMLen/SHMBase pairs) and the Linux guest driver gained mmio SHM support in v5.10 (commit 38e895487afc), so the Track 0 kernel qualifies. The only open question is host-side: Apple documents hv_vm_map for regions "typically allocated with mmap or mach_vm_allocate" but says nothing about file-backed mmap coherency or lifetime. The spike proves an mmap'd host file mapped into the DAX window survives guest reads and writes coherently across host page-cache activity. Go: implement FUSE_SETUPMAPPING/FUSE_REMOVEMAPPING. No-go: ship without DAX, keep the window plumbing behind a flag. STATUS (2026-07-04): GO — coherency PROVEN on Apple Silicon hardware. FUSE_SETUPMAPPING/REMOVEMAPPING, DaxWindow, FileBackedDaxMappingBackend, virtio SHM region provider, and FUSE_INIT DAX-alignment negotiation are all IMPLEMENTED and flag-gated (`--share tag=/host/path:dax`, default off). A signed `dory-hv daxprobe` subcommand (DaxCoherenceProbe) maps a file-backed MAP_SHARED mmap into guest PA via hv_vm_map and runs a real vCPU that reads a host-written pattern and writes a marker back: verified the guest sees host writes AND the guest write is visible in the host mmap and persisted on disk. Added as readiness track `--dax`. The probe caught and fixed TWO real bugs in the initial flag implementation: (1) the window base 0x10_0000_0000 (64 GiB) is at the default guest IPA ceiling and never maps — moved to GuestLayout.daxWindowBase = 0xC_0000_0000 (48 GiB, verified in range); (2) hv_vm_map requires 16 KiB granularity on Apple Silicon — DaxWindow.pageSize was 4096, now 16384, which also corrects the FUSE_INIT map-alignment we advertise to the guest (log2 12 -> 14).

**Exit criteria:** container bind mounts and machine mounts on macOS paths within 1.5x of OrbStack on the three benchmarks; file watching demo (vite HMR from a host-edited file) in readiness.sh.
**Claims unlocked:** "Native-speed file sharing built into our own VMM" and, if 1.7 lands, "DAX file sharing: guest page cache IS the host page cache," which OrbStack does not advertise.

---

# Track 2: Linux machines with recipes

Machines stay container-backed (shared dory-hv kernel, LXC-style, full distro rootfs with systemd), which is the OrbStack model and why machines start in about a second and share the elastic memory pool. Recipes make them declarative and shareable. Prior art, checked against sources: OrbStack machines accept cloud-init user data; Lima templates carry free-form provision shell scripts (modes system/user/boot/data/yq) and whole templates are URL-shareable via limactl start; Colima supports provision scripts in its config file only. None of them offers what recipes add: a typed schema with per-distro package lists, mounts/ports/docker wiring, idempotent re-apply, and a catalog UI.

**Branch:** `feat/t2-machine-recipes`

### Task 2.1: Recipe schema v1 + parser

**Files:**
- Modify: `Dory/Runtime/Machines/DevRecipe.swift` (becomes the schema type)
- Create: `Dory/Runtime/Machines/RecipeStore.swift` (load/validate from `~/.dory/recipes/*.yaml`, built-ins from bundle resources)
- Create: `Dory/Resources/Recipes/` built-in catalog: `ubuntu-dev.yaml`, `node.yaml`, `go.yaml`, `rust.yaml`, `python-ml.yaml`, `docker-host.yaml`, `k8s-lab.yaml`
- Test: `DoryTests/RecipeStoreTests.swift`

**Interfaces (schema locked):**
```yaml
name: rust-dev
summary: Rust toolchain with common build deps
distro: ubuntu:24.04          # ubuntu|debian|fedora|alpine|arch, tag required
arch: arm64                   # arm64 | amd64 (amd64 routes to Track 4 tiers)
resources: {cpus: 4, memory: 8GiB, disk: 60GiB}
packages: [build-essential, pkg-config, libssl-dev]
runcmd:
  - curl https://sh.rustup.rs -sSf | sh -s -- -y
mounts:
  - ~/Projects:~/Projects     # virtiofs after Track 1
ports: [3000]
env: {CARGO_HOME: /home/{{user}}/.cargo}
ssh: {agent_forward: true}
docker: true                  # bind dory docker socket into the machine
user: {name: "{{host_user}}", sudo: true, shell: /bin/bash}
```
Produces: `struct DevRecipe: Codable` with `static func load(from url: URL) throws -> DevRecipe` and `func validate() throws` (unknown keys are errors; `{{user}}`/`{{host_user}}` are the only template vars).

- [ ] Failing tests: valid recipe round-trip, unknown key rejected, bad memory string rejected, template substitution. Implement. Commit `feat: machine recipe schema v1 + built-in catalog`.

### Task 2.2: Provisioner executes recipes

**Files:**
- Modify: `Dory/Runtime/Machines/MachineProvisioner.swift`, `ProvisionComposer.swift`, `ProvisionCatalog.swift`
- Modify: `Dory/Runtime/Machines/MachineImageBuilder.swift` (distro rootfs acquisition: official cloud images, pinned digests; systemd kept as machine init)
- Test: `DoryTests/MachineProvisionerTests.swift` (compose plan assertions, no VM needed) + readiness.sh track "machine-recipe" (create rust-dev machine, assert `cargo --version` via agent exec)

**Interfaces:**
- Produces: `MachineProvisioner.create(name: String, recipe: DevRecipe) async throws -> Machine`. Provision steps run through the Track 0 agent `exec` (package install with per-distro driver: apt/dnf/apk/pacman), streamed to the UI log. Idempotent: re-running a recipe on an existing machine applies only the diff (packages checked before install).

- [ ] Per-distro package driver table + compose plan TDD; wire runcmd, mounts, ports, env, docker socket. Commit per distro driver.

### Task 2.3: CLI + ssh integration

**Files:**
- Modify: `scripts/dory` CLI: `dory machine create <name> --recipe <name|path|url>`, `dory recipe ls|show|add <url|path>|new <name>`, `dory ssh <machine>`
- Create: `Dory/Runtime/Machines/SSHConfigWriter.swift` (writes `~/.dory/ssh/config` with one Host block per machine, ProxyCommand through the agent exec channel or forwarded port 22; prints the one-line `Include ~/.dory/ssh/config` instruction and offers to append it)

- [ ] `dory ssh rusty` lands in a shell as the recipe user; VS Code Remote-SSH connects using the generated Host entry (manual verify + readiness assertion that `ssh -F ~/.dory/ssh/config rusty true` exits 0). Commit `feat: dory ssh + ssh config integration`.

### Task 2.4: Machines UI

**Files:**
- Modify: `Dory/Features/Machines/` (recipe picker in the create flow: catalog cards, resource sliders pre-filled from the recipe, provisioning log stream)
- Follow WS4 machine-creation direction from the UI redesign workstreams.

- [ ] Create-from-recipe flow shippable; empty-state shows the catalog. Commit `feat: machine creation UI with recipe catalog`.

**Exit criteria:** `dory machine create dev --recipe ubuntu-dev` to usable ssh shell in under 60 s on a cold image cache, under 10 s warm; recipes shareable by URL.
**Claims unlocked:** "Declarative, shareable dev machines" (neither OrbStack nor Colima has recipe layering).

---

# Track 3: USB passthrough (differentiator: OrbStack and Colima have none)

Design (locked): USB/IP, not XHCI emulation. The guest kernel already gets `CONFIG_USBIP_VHCI_HCD=y` in Track 0. Host side is a usbip protocol server backed by IOUSBHost. Transport is vsock (vhci_hcd only needs a connected socket fd; the agent creates the vsock connection and writes `"port sockfd devid speed"` to `/sys/devices/platform/vhci_hcd.0/attach`). Verified against mainline: attach_store in drivers/usb/usbip/vhci_sysfs.c validates only `socket->type != SOCK_STREAM` (the 2021 hardening commit f55a057169 added exactly that check and deliberately no address-family restriction), so an AF_VSOCK stream socket qualifies.

**Branch:** `feat/t3-usb` | **Expand into its own plan before execution.**

**Files (locked):**
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/Usb/UsbipServer.swift` (protocol v1.1.1: OP_REQ_IMPORT handshake then USBIP_CMD_SUBMIT/USBIP_RET_SUBMIT, USBIP_CMD_UNLINK; one vsock stream per attached device)
- Create: `Packages/ContainerizationEngine/Sources/DoryHV/Usb/HostUsbDevice.swift` (IOUSBHost: enumerate via IOServiceMatching("IOUSBHostDevice"), open IOUSBHostDevice, claim interfaces, submit control/bulk/interrupt transfers from CMD_SUBMIT URBs; isochronous explicitly unsupported in v1, return EPIPE)
- Modify: `dory-hv/main.swift` (`usb list`, engine-mode RPC to attach/detach), agent methods `usb.attach {busid, vsockPort, devid, speed}` / `usb.detach {port}`
- Modify: `scripts/dory` (`dory usb ls`, `dory usb attach <vid:pid|busid> [--machine m]`, `dory usb detach`)
- Create: `Dory/Features/Settings/UsbDevicesView.swift` (device picker with per-device attach toggle, remembered attachments)
- Test: `Tests/DoryHVTests/UsbipProtocolTests.swift` (URB codec fixtures), hardware smoke doc `docs/research/usb-matrix.md`

**Task list:**
- [ ] 3.0 [SPIKE, go/no-go, 2 days] Capture matrix on real hardware: CDC-ACM serial adapter, DFU-mode microcontroller (STM32/RP2040), Android phone (adb), USB flash drive. Ground rules verified from Apple docs and the UTM precedent: devices with no matching kernel driver open via IOUSBHost + an IOServiceAuthorize authorization, no special entitlement; devices already claimed by an Apple kernel driver (e.g. mass storage) need IOUSBHostObjectInitOptions.deviceCapture, which requires the restricted `com.apple.vm.device-access` entitlement OR root privileges. v1 capture path for claimed devices is therefore a root privileged helper behind the same admin-consent flow the domain system-integration already uses; file the entitlement request with Apple in parallel (it is granted to virtualization products; UTM's App Store build carries it). Hard limits to document, learned from UTM: Apple-internal devices are never capturable (FaceTime HD camera, T2, Touch Bar), USB3 UAS storage is flaky under user-space capture, and no true hardware reset is possible without a kernel driver. Record the matrix; v1 scope = whatever opens cleanly.
- [ ] 3.1 usbip URB codec TDD from fixtures
- [ ] 3.2 IOUSBHost transfer bridge (control + bulk + interrupt)
- [ ] 3.3 vsock plumbing + agent attach/detach + CLI
- [ ] 3.4 UI picker + persistence (reattach on VM restart)
- [ ] 3.5 readiness track "usb" gated on a `DORY_USB_TEST_BUSID` env (skipped in CI, run in the hardware smoke)

**Exit criteria:** flash an RP2040 and run `adb devices` from inside a machine; documented device matrix.
**Claims unlocked:** "Flash your microcontroller and run adb from a Linux machine on your Mac. OrbStack can't."

---

# Track 4: x86_64 on Apple silicon (tiered, honest)

**Branch:** `feat/t4-x86` | **Expand into its own plan before execution.**

- **Tier 1 (ship first): qemu-user-static binfmt in the dory-hv guest.** Add pinned `qemu-x86_64-static` to the initfs; register binfmt_misc with the F (fix-binary) flag at guest boot so amd64 containers and `--platform linux/amd64` builds just work, exactly like Docker Desktop's qemu mode. Files: initfs injection in `scripts/bundle-engine.sh`, binfmt registration line in the guest init, readiness assertion `docker run --platform linux/amd64 alpine uname -m` → `x86_64`. Correct but 5-10x slower than native; label it clearly in docs.
- **Tier 2 (parity with OrbStack for machines): Rosetta via the bundled dory-vm fallback.** `arch: amd64` recipes and `--rosetta` machines provision through the existing Virtualization.framework helper (`Contents/Helpers/dory-vm`), which can legitimately use `VZLinuxRosettaDirectoryShare`. One extra VM only when requested; dory-hv remains the default engine. Files: routing switch in the engine provisioner keyed on recipe `arch`. Mechanics, verified: the Rosetta share's virtiofs tag is developer-chosen, not a magic string; the guest registers the rosetta binary via binfmt_misc; best performance needs Apple's TSO patch applied to the GUEST kernel (ACTLR TSOEN context switching plus a prctl PR_SET_MEM_MODEL mode) and rosettad AOT caching (macOS 14+).
- **Tier 3: Rosetta under dory-hv. CLOSED as infeasible (verified 2026-07-04).** The record: upstream libkrun, a raw-Hypervisor.framework VMM in exactly dory-hv's position, shipped this in 2022 by replaying Rosetta's legacy verification ioctl (0x80456122). Apple replaced that check with a challenge-response secret exchange (ioctl 0x80456125) that cannot be replayed, and libkrun's maintainer dropped the feature in 2024 ("It's been broken for a while and we have no way of supporting it in a reasonable way"). A 2025 prototype rebuilt all the plumbing (rosetta share mounted, binfmt registered, SMBIOS/FDT spoofed so systemd-detect-virt reports apple) and execution still aborts with "Rosetta is only intended to run on Apple Silicon with a macOS host using Virtualization.framework." Legally, the macOS SLA never names Rosetta, but defeating the handshake is DMCA anti-circumvention exposure on top of general SLA terms. Tier 2 is the permanent Rosetta answer unless Apple documents an API; spend no spike time here.

**Exit criteria:** amd64 containers run out of the box (Tier 1); `dory machine create intel --recipe ubuntu-dev --arch amd64` gives near-native x86 (Tier 2).

**STATUS (2026-07-04):** Tier 1 VERIFIED COMPLETE — the recipe create path calls `MachineService.ensureEmulation` (tonistiigi/binfmt) for any non-native arch, builds with `--platform linux/amd64`, and amd64 machines are honestly labeled "Emulated via binfmt" in the UI. Tier 3 CLOSED. Tier 2 Rosetta CAPABILITY DELIVERED + PROVEN on Apple Silicon: `dory-vmboot --arch amd64 --rosetta` runs x86_64 binaries (verified uname -m -> x86_64, x86_64 shell/busybox execute with no qemu present); Rosetta enabled on the shared vz engine via `DORY_ENGINE_ROSETTA=1`; user path `dory vm --arch amd64 --rosetta`; tested by readiness track `--rosetta`. REMAINING: persistent Rosetta MACHINES (Rosetta as the machine backend) — machines are docker containers on the sole dory-hv engine (Rosetta infeasible there), so a persistent amd64 Rosetta machine needs either a second (vz+Rosetta) engine with per-machine docker routing, or a per-machine dory-vm VM lifecycle. Detailed in the sub-plan `2026-07-04-track4-tier2-rosetta-machines.md`.

---

# Track 5: Networking polish

**Branch:** `feat/t5-net`

- [ ] 5.1 Direct container/machine IP routing from the host (OrbStack parity): a utun interface on the host with a route for the container subnet, packets bridged into the gvproxy switch. Files: `Dory/Net/TunRouter.swift`, privileged helper step added to the existing domain system-integration consent flow (one admin prompt covers both). Gate: `ping <container-ip>` and browser access to a container port with no forward configured.
- [ ] 5.2 mDNS for machines: `<machine>.dory.local` resolves to the machine IP (reuse the existing *.dory.local responder).
- [ ] 5.3 `host.docker.internal` + `host.dory.internal` verified inside machines (already works for containers via gvproxy; add readiness assertions for machines).
- [ ] 5.4 VPN coexistence regression tests documented in readiness (gvproxy userspace networking already avoids most VPN fights; capture that as a tested claim, not folklore).
- [ ] 5.5 Automatic port forwarding for machines: agent method `ports.watch` polls /proc/net/tcp for LISTEN-socket diffs and streams add/remove events (the mechanism Lima's guest agent uses in production, pkg/guestagent/guestagent_linux.go); the app forwards through gvproxy exactly like published container ports.

---

# Track 6: DX extras (beyond parity)

**Branch:** `feat/t6-dx` | Ordered by effort/value; each is independently shippable.

- [ ] 6.1 `dory debug <container>`: OrbStack-style debug shell in ANY container including distroless. Implementation: agent-side nsenter into the container's namespaces plus a read-only toolbox mount (static busybox + curl + strace, built into the initfs) overlaid at `/.dory-toolbox`, PATH prefixed. Files: agent method `debug.shell {containerID}`, `scripts/dory` subcommand, terminal integration in `Dory/Runtime/TerminalSession.swift`.
- [ ] 6.2 Machine snapshots and restore surfaced in UI + CLI (`dory machine snapshot/restore`, `MachineSnapshot.swift` exists; add scheduled snapshots and S3 backup per the cloud roadmap Phase 2b).
- [ ] 6.3 ssh-agent and git credential forwarding into machines and containers (mount an agent-proxied SSH_AUTH_SOCK via a vsock-backed unix socket bridge; host-bridge branch already built the credential bootstrap).
- [ ] 6.4 `dory expose <port|machine>`: public HTTPS tunnel for sharing a dev server (rides the remote-access roadmap phase; cloudflared-style, opt-in).
- [ ] 6.5 [RESEARCH ONLY] GPU compute in guest: virtio-gpu + Venus (Vulkan) over MoltenVK, libkrun/krunkit precedent. Write a findings doc in `docs/research/gpu-venus.md` before committing to anything; neither OrbStack nor Colima has it, so even a working llama.cpp demo is a headline, but the effort is large and MoltenVK feature gaps are real.

---

## Sequencing and rough effort

| Phase | Tracks | Effort (focused) | Release marker |
|---|---|---|---|
| A | Track 0 | 2-3 weeks | 0.3.0 "own kernel + agent" |
| B | Track 1 | 3-5 weeks | 0.4.0 "file sharing" (the OrbStack answer release) |
| C | Track 2 | 2-3 weeks | 0.5.0 "machines with recipes" |
| D | Track 3 + 5 | 3-4 weeks | 0.6.0 "USB + direct IPs" |
| E | Track 4 + 6.1-6.3 | 2-3 weeks | 0.7.0 |
| F | 6.4-6.5 | open | with cloud phases |

## Self-review notes

- Every track's guest-side requirement is present in the Task 0.1 kernel config (vsock, virtio-fs+DAX, usbip vhci, binfmt_misc, overlayfs).
- Agent method names are consistent across tracks: `ping/info/exec/clock.sync` (T0), `fsevents.batch` (T1), `usb.attach/usb.detach` (T3), `ports.watch` (T5), `debug.shell` (T6).
- `AgentChannel.call` (T0.3) is the only host→guest RPC entry point used by T1.5, T2.2, T3.3, T6.1.
- Risky items carry explicit spikes with go/no-go gates and shippable fallbacks: DAX (1.7, host-side question only, fallback plain virtio-fs), USB capture of kernel-claimed devices (3.0, fallback root-helper capture + driverless-device scope), GPU (research only). Rosetta-on-hvf is not a spike anymore: closed as infeasible on libkrun's documented record, Tier 2 via the bundled dory-vm is the answer.
- Known open value to fill at execution time, deliberately not invented here: the kernel tarball sha256 in `guest/kernel/PINS` (must come from kernel.org at build time and be committed as a literal).

## Fact-check record (2026-07-04)

Every load-bearing external claim in this plan was verified against primary sources by a 6-researcher, adversarially re-checked pass: 43 claims total, 32 confirmed, 8 nuanced, 3 refuted, 0 unverifiable. Corrections were applied inline above. The three refutations, for the record: the Colima inotify mechanism is chmod-to-same-mode (not mtime touch) and this plan's Task 1.5 was redesigned around it; the FUSE version floor is virtiofsd's 7.27 (not a client-side 7.31); Rosetta under a raw Hypervisor.framework VMM is infeasible (libkrun shipped it, Apple broke it with a challenge-response ioctl, libkrun removed it in 2024), so Track 4 Tier 3 was closed.

Key sources consulted (all fetched, not recalled):

- Colima: cmd/start.go, embedded/defaults/colima.yaml, daemon/process/inotify/{watch,events,volumes}.go, environment/container/* (github.com/abiosoft/colima)
- Lima: templates/default.yaml, pkg/guestagent/guestagent_linux.go, lima-vm.io/docs (port forwarding, provisioning), issue #2224 (USB)
- OrbStack: docs.orbstack.dev (architecture, efficiency, machines, cloud-init, orb debug, ssh), orbstack.dev/blog/dynamic-memory, issues #355/#1257/#2251
- virtio spec 1.2: sections 2.10 (shared memory regions), 5.10 (vsock), 5.11 (fs); include/uapi/linux/virtio_mmio.h SHM registers; kernel commit 38e895487afc (mmio SHM support, v5.10)
- FUSE: fs/fuse/inode.c process_init_reply; virtiofsd src/fuse.rs MIN_KERNEL_MINOR_VERSION=27
- USB/IP: drivers/usb/usbip/vhci_sysfs.c attach_store; hardening commit f55a057169 (SOCK_STREAM-only check, no address-family restriction); Documentation/usb/usbip_protocol.rst
- IOUSBHost: developer.apple.com IOUSBHostObjectInitOptions.deviceCapture and com.apple.vm.device-access (restricted entitlement; capture alternatively via root per Apple DTS forum guidance); UTM Platform/macOS/macOS.entitlements and usbBlockList as precedent
- Rosetta: developer.apple.com (VZLinuxRosettaDirectoryShare, "Accelerating the performance of Rosetta" TSO guest patch); libkrun PR #88 and removal commit 0b6a73562; podman discussion #28297 (working prototype, execution still refused)
- Kernel build: arch/arm64 has no self-decompressing Image (no CONFIG_KERNEL_ZSTD there); scripts/kconfig/merge_config.sh; 6.12 is LTS
- Misc: gvproxy is Apache-2.0; AF_VSOCK works from static cgo-free Go (x/sys/unix, mdlayher/vsock); qemu-user-static binfmt F-flag is the standard amd64-on-arm64 container mechanism (tonistiigi/binfmt et al.); hv_vm_map documented for mmap/mach_vm_allocate regions, silent on file-backed mappings (hence spike 1.7)
