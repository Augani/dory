# Dory on Intel Macs Implementation Plan (dory-hv x86_64)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Scope note:** This is the master plan for the Intel (x86_64 host) port. Tracks I0 and I1 are specified to execution granularity here. Tracks I2, I3, I4, I5 are specified to task granularity with locked designs, exact files, and acceptance gates; before executing one of those tracks, expand it into its own dated plan with superpowers:writing-plans using the design locked here as the spec.

**Goal:** Bring Dory's own fast engine (dory-hv, our raw Hypervisor.framework VMM) to Intel Macs natively, so Dory is the best container runtime on BOTH Mac architectures and captures the Intel base that Docker Desktop, Colima, and OrbStack are abandoning.

**Implementation status (2026-07-05):** Hardware-independent implementation is wired:
universal app/package builds, Intel tier selection, x86 PVH loader/boot structures, x86 exit
decode/execute, APIC accelerator request, PIO/MMIO/CR/MSR handling, virtio interrupt routing,
arch-suffixed raw-HV/VZ resources, Intel-aware readiness/benchmark methodology, and a self-hosted
Intel CI workflow. Verified locally with RuntimeSupportTests, the DoryHV Swift package suite, shell
syntax checks, workflow YAML parsing, diff whitespace checks, and universal package builds.

**Remaining hard gates:** Physical Intel Mac validation is still required for VZ readiness,
raw `dory-hv` smoke, APIC/INIT/SIPI behavior, PVH boot to serial, virtio/agent-ping, raw engine
mode readiness, SMP + elastic memory, DAX/USB/Kubernetes/network parity, benchmarks, release
claims, and the 24-hour stability soak. Do not mark I2/I3/I4/I5 release gates complete without
those artifacts from a real Intel Mac.

**Architecture:** The DoryHV library is ~83% arch-neutral (all virtio devices, virtqueues, FUSE/virtio-fs, vsock, usbip, agent RPC, gvproxy glue). The port replaces the arm64 machine model (GICv3 + PSCI + FDT + PL011/PL031 + arm64 Image loader, 1129 LoC) with an x86 machine model: Apple's in-kernel APIC (`HV_VM_ACCEL_APIC`, macOS 12+), PVH direct boot of our own kernel, MPTABLE enumeration, a 16550 serial + CMOS RTC + i8042 stub, and a small x86 MMIO instruction decoder. Virtio stays on MMIO (registered via kernel cmdline), so every existing device ports unchanged. The bundled VZ helper (dory-vmboot) ships first on Intel as the interim engine and remains the permanent fallback, exactly as on Apple silicon.

**Tech Stack:** Swift (VMM + app), Go (guest agent), Linux 6.12 LTS x86_64 guest kernel (PVH, virtio-mmio, 8250 console), Hypervisor.framework x86 API (`hv.h`/`hv_vmx.h`), universal (arm64 + x86_64) app and helper binaries.

## Global Constraints

- Intel host floor: **macOS 15 (Sequoia)**, NOT 26. Every Hypervisor.framework x86 API this plan uses exists by macOS 12 (`HV_VM_ACCEL_APIC`, `hv_vm_allocate` 12.0; `hv_vm_add_pio_notifier`, `hv_vcpu_set_tsc_relative` 11.0; `hv_vcpu_run_until` 10.15). Requiring 26 would shrink the Intel market to the four Tahoe-supported models; requiring 15 covers every 2017-2020 Intel Mac that can run Sequoia. The macOS 26 requirement on the Apple-silicon engine path must not leak into the Intel path (Track I1 removes its root cause, the Apple `container` initfs dependency).
- Intel hardware floor: any Sequoia-capable Intel Mac (2017+). All have VT-x with EPT, Unrestricted Mode, invariant TSC, and TSC-deadline timer, which is exactly Hypervisor.framework's documented Intel requirement.
- The app ships as ONE universal binary (arm64 + x86_64); helper binaries (`dory-hv`, `dory-vm`, gvproxy) ship universal or per-arch inside the same bundle. One Sparkle feed, one cask, one zip. App zip stays under ~120 MB even with dual-arch guest assets; if it does not fit, guest assets for the non-native arch are downloaded on first run instead of bundled.
- dory-hv keeps the single entitlement `com.apple.security.hypervisor` (identical key on Intel; the deprecated `com.apple.vm.hypervisor` is NOT needed at our 15.0 floor).
- Runtime capability check on Intel is `sysctl kern.hv_support` plus engine-asset presence, never a hardcoded model list. (Availability precision: `hv_vm_allocate` is 12.0 on x86_64 but 12.1 on arm64; no shared code may assume a single 12.0 floor for both slices.)
- Xcode project stays at objectVersion 77; build with stable xcode-select. The package emits products to `.build/out/Products/<config>/`.
- Free and open source, no paid tier. Commit format `type(scope): description` matching repo history (scope optional); feature branches `feat/intel-<track>-<name>`; `swift test` in `Packages/ContainerizationEngine` plus `scripts/test.sh` green before every commit.
- All new engine behavior is gated by integration tests runnable via `scripts/readiness.sh` on the Intel test machine and benchmarked via `scripts/benchmark.sh` (Intel methodology addendum in Track I4).
- Every kernel source tarball, rootfs base, and downloaded toolchain binary is pinned by sha256.
- No em dashes in any user-facing copy or docs.
- Honest-horizon rule: macOS 26 is the last Intel macOS and Apple's security tail runs to roughly 2028. All Intel marketing copy states what we support and until when; no open-ended promises.

---

## Part 1: Why do this (and the honest counter-argument)

The counter-argument first: Intel Macs are a sunsetting platform. macOS 27 drops them entirely; Apple's security updates run out around 2028. Nobody builds new HVF-x86 VMMs anymore (the last one, HyperKit, is deprecated; xhyve is dormant since 2021). Why spend a quarter on it?

Because the abandonment is exactly the opportunity, and the cost is far smaller than it looks:

1. **The field has left the door open.** OrbStack hard-fences Intel to Skylake through Ice Lake CPUs on macOS 14+ and markets itself as "written from the ground up for Apple Silicon." Docker Desktop still ships on Intel but its fast path (Docker VMM) is Apple-silicon-only, so Intel users get the legacy tier. Colima/Lima's arch quirks push Intel users onto the slow QEMU fallback. Podman's fast path (krunkit/libkrun) is Apple-silicon-only. Nobody is investing in Intel Mac containers.
2. **Nobody offers elastic memory on Intel.** Host-RAM reclaim (our measured 472 MB vs OrbStack's 849 MB on Apple silicon) exists on Intel only inside OrbStack's narrow fence. Docker Desktop's VM holds all allocated RAM. Free-page reporting plus madvise is arch-independent in the guest kernel and is actually CLEANER on Intel (4K host pages, guest reports 2M blocks, no 16K alignment shim). dory-hv-x86 would be the only tool bringing memory reclaim to the broad Intel base.
3. **The port is bounded.** Measured against the codebase: 5662 of 6791 DoryHV library LoC (all virtio devices, virtqueues, FUSE, vsock, usbip, agent, networking) are arch-neutral and port unchanged. The arm64-bound remainder is 1129 LoC across 9 files: the core (Machine + VCPU + GICv3 glue) is 748 LoC to rewrite plus 381 LoC of boot/serial/RTC/diagnostic serialization to re-target. Apple's in-kernel APIC on Intel (macOS 12+) removes the biggest historical cost of HVF-x86 VMMs (userspace LAPIC/IOAPIC/PIC emulation, the reason xhyve is tens of thousands of lines).
4. **Strategic credibility.** "Works on every Mac" is a real differentiator against OrbStack in team adoption decisions, and the 2026-2028 enterprise refresh window is full of mixed fleets. Capturing Intel users now converts them to Dory-on-Apple-silicon users at refresh time.
5. **Most of the work is not Intel-specific.** The in-repo initfs pipeline (I1), the engine-tier gating rework (I2), universal shipping and the appcast fix (I0), and CI for the engine tests (I5) all pay down debt the Apple-silicon product carries today.

**Positioning claim when done:** "Dory is the only container runtime with its own VMM, its own kernel, elastic memory, and fast file sharing on BOTH Apple silicon and Intel Macs. Free and open source. If your Mac runs macOS 15, Dory's engine runs on it."

## Part 2: Intel gap matrix (2026-07 snapshot, sources in fact-check record)

| Capability on an Intel Mac | Docker Desktop | Colima/Lima | OrbStack | Podman | Dory today | Dory after this plan |
|---|---|---|---|---|---|---|
| Installs on all macOS 15 Intel Macs | Yes | Yes | No (Skylake-Ice Lake, macOS 14+) | Yes | Yes (proxy only) | **Yes** |
| Own engine (not a proxy/frontend) | Yes (VZ) | Yes (VZ/QEMU) | Yes (VZ) | Yes (VZ/vfkit) | **No** | **Yes (VZ in I2, own VMM in I3)** |
| Own VMM (not VZ/QEMU) | No | No | No | No | No | **Yes (Track I3)** |
| Elastic memory returned to macOS | No | No | Only inside its fence | No | No | **Yes (I3/I4)** |
| virtio-fs file sharing | Yes | vz mounts | Yes | Yes | No | **Yes + DAX at 4K (I4)** |
| USB passthrough | No | No | No | No | No | **Yes (I4)** |
| Direct container IP routing | No | No | Yes | No | No | **Yes (I4)** |
| arm64 containers (emulated) | Yes (qemu) | Yes (qemu) | Yes | Yes | Via proxied engine | **Yes (qemu-aarch64 binfmt, I1)** |
| Kubernetes (one click) | Yes | Yes (k3s) | Yes (inside its fence) | No | Via proxied engine | **Yes (k3s, gated in I4)** |
| Free and open source | No | Yes | No | Yes | Yes | **Yes** |
| Getting new performance investment | No (Docker VMM is AS-only) | No | No | No | n/a | **Yes** |

## Part 3: Track overview and dependencies

```
Track I0: truthfulness + universal shipping (independent, ship immediately)
Track I1: amd64 guest artifacts + in-repo initfs pipeline
  |                          \
Track I2: VZ engine on Intel   \        <- first Intel engine release (needs I1 + Intel hardware)
  |                             \
Track I3: dory-hv-x86 core VMM   (needs I1 artifacts; I3.0 arch-split is independent)
  |
Track I4: differentiator parity on Intel (elastic memory, DAX, USB, direct IP, readiness/bench twins)
Track I5: CI + release + docs + positioning (starts with I0, finishes after I4)
```

Recommended execution order: I0 -> I1 -> (I3.0 in parallel with I2) -> I3 -> I4 -> I5 finish. Track I2 ships a public Intel beta while I3 is in flight.

**Hardware prerequisite (blocking gate for I2 and beyond):** at least one physical Intel Mac running macOS 15 or 26 (ideal: a 2019 16-inch MacBook Pro or 2020 27-inch iMac, which are Tahoe-capable), set up as a self-hosted GitHub runner with labels `[self-hosted, macOS, intel, dory]`. Hypervisor.framework does not work under Rosetta translation, so no Apple-silicon machine can substitute for VM execution tests. GitHub retired its hosted Intel macOS runners, so self-hosted is the only CI option. Acquire or designate this machine during Track I1; nothing in I0/I1 needs it.

---

# Track I0: Intel truthfulness + universal shipping

Bugs that mislead Intel users TODAY (in proxy mode) plus the packaging fixes universal shipping needs. Every fix here is correct regardless of the engine strategy and ships in the next regular release.

**Branch:** `feat/intel-i0-truthfulness`

**Local status (2026-07-05):** implementation pieces are present and verified where noted below.
Historical TDD "expected fail" steps and commit steps remain unchecked because this worktree has not
been committed in this thread. Targeted app tests passed for `DockerShimArchTests` and
`RecipeStoreTests`; a local unsigned Release archive with `ARCHS="arm64 x86_64"` produced a
universal `Dory.app` binary (`lipo -archs` -> `x86_64 arm64`) with `LSMinimumSystemVersion=15.0`.
The earlier UI-test failure was fixed by making UI automation launch the app in explicit mock/test
mode; `xcodebuild test -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS'
-only-testing:DoryUITests` now passes all 9 UI tests.
`DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer scripts/test.sh`
also passes locally.

### Task I0.1: DockerShim stops hardcoding arm64 in /version and /info

**Files:**
- Modify: `Dory/Shim/DockerShim.swift:1117` (`"Arch": "arm64"`), `:1134` (`"Architecture": "aarch64"`)
- Test: `DoryTests/DockerShimArchTests.swift` (create)

**Interfaces:**
- Produces: `DockerShim.hostDockerArch() -> String` (GOARCH style: `arm64`/`amd64`) and `DockerShim.hostKernelArch() -> String` (uname style: `aarch64`/`x86_64`), both `#if arch(arm64)` based, mirroring the existing `defaultDockerArchitecture()` pattern at `DockerShim.swift:1729-1735`. The guest daemon arch always matches the host arch in Dory's engine designs, so build-arch derivation is correct on both.

- [x] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

@Suite struct DockerShimArchTests {
    @Test func versionArchMatchesBuildArch() {
        #if arch(arm64)
        #expect(DockerShim.hostDockerArch() == "arm64")
        #expect(DockerShim.hostKernelArch() == "aarch64")
        #else
        #expect(DockerShim.hostDockerArch() == "amd64")
        #expect(DockerShim.hostKernelArch() == "x86_64")
        #endif
    }
}
```

- [ ] **Step 2: Run it** (`scripts/test.sh` filtered to DockerShimArchTests). Expected: FAIL, functions not defined. Historical expected-fail evidence was not captured before implementation; post-implementation filtered run passed.
- [x] **Step 3: Implement** the two static helpers next to `defaultDockerArchitecture()` and replace the literals at `:1117` and `:1134` with `Self.hostDockerArch()` / `Self.hostKernelArch()`.

```swift
static func hostDockerArch() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "amd64"
    #endif
}

static func hostKernelArch() -> String {
    #if arch(arm64)
    return "aarch64"
    #else
    return "x86_64"
    #endif
}
```

- [x] **Step 4: Test passes.** Also grep `Dory/Shim/DockerShim.swift` for any remaining `"arm64"`/`"aarch64"` literals in response payloads and route them through the helpers.
- [ ] **Step 5: Commit** `fix(shim): report host arch instead of hardcoded arm64`

### Task I0.2: DevRecipe defaults to the host arch

**Files:**
- Modify: `Dory/Runtime/Machines/DevRecipe.swift:60` (Swift default parameter `arch: String = "arm64"`), `:136` (YAML-parse fallback)
- Test: `DoryTests/RecipeStoreTests.swift` (extend)

- [x] **Step 1: Failing test:** a recipe YAML without an `arch:` key must parse with `recipe.arch == MachineArch.host.rawValue` (asserts `amd64` when the suite runs on Intel, `arm64` on Apple silicon; write it arch-relative, not literal).
- [x] **Step 2: Implement:** both defaults become `MachineArch.host.rawValue`. `validate()` at `:164` stays as-is (`arm64|amd64` whitelist).
- [ ] **Step 3: Test green, commit** `fix(machines): recipe arch defaults to host arch, not arm64`. Filtered `RecipeStoreTests` passed; commit remains undone.

### Task I0.3: Sparkle appcast min-OS 26.0 -> 15.0

The live feed requires macOS 26.0, which silently blocks updates for every macOS 15-25 user the README, cask, and release notes claim to support (including all Intel users on Sequoia).

**Files:**
- Modify: `scripts/update-appcast.sh:7` (`MINOS="${6:-26.0}"` -> `MINOS="${6:-15.0}"`)
- Modify: `docs/appcast.xml:13` (existing entry `<sparkle:minimumSystemVersion>26.0` -> `15.0`)

- [x] **Step 1:** Make both edits. Confirm the app's actual `LSMinimumSystemVersion` in the built Info.plist is 15.0 or lower (`defaults read` on a built app or grep `MACOSX_DEPLOYMENT_TARGET` in `project.pbxproj`); if the deployment target is higher than 15.0, reconcile in the same commit and record which way it was resolved.
- [x] **Step 2:** `scripts/update-appcast.sh` dry-run on a scratch copy; verify the emitted entry carries 15.0.
- [ ] **Step 3: Commit** `fix(release): appcast minimumSystemVersion matches the macOS 15 floor`

### Task I0.4: Release pipeline actually builds universal

`Casks/dory.rb:12` and the release notes claim "Universal for Intel and Apple silicon," but `scripts/release.sh:33-40` builds only the host arch. The app target and its packages compile for x86_64 today (the vendored containerization framework gates its Rosetta paths behind `#if arch(arm64)`), so this is a build-settings fix. Note: the engine helpers under `Contents/Helpers` and the engine resources remain arm64-only until I1/I3; that is fine because `DoryHVSupport` gates the engine off on Intel, where the app runs in proxy mode.

**Files:**
- Modify: `scripts/release.sh:33-40` (add `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` to the xcodebuild archive invocation)
- Modify: `.github/workflows/tests.yml` (add a build-only x86_64 cross-compile job)

- [x] **Step 1:** Add the ARCHS override to the archive step. Build locally, then verify: `lipo -archs "<archived>.app/Contents/MacOS/Dory"` prints `x86_64 arm64`.
- [x] **Step 2:** If the x86_64 slice fails to compile, fix each error by gating arm64-only API use behind `#if arch(arm64)` with a proxy-mode fallback (the pattern already used at `DockerShim.swift:1729`). Do NOT stub with fatalError on paths reachable on Intel. The local unsigned Release archive compiled both slices without additional arch gates.
- [x] **Step 3:** Add to `tests.yml` a job `build-x86_64` on `macos-latest`: `xcodebuild build -project Dory.xcodeproj -scheme Dory -destination 'generic/platform=macOS' ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO` (cross-compile only, no test run). This keeps the Intel slice from rotting between releases.
- [ ] **Step 4:** Run `scripts/test.sh`, commit `fix(release): build a true universal binary and guard the x86_64 slice in CI`. The broad local script now passes after the explicit UI automation test-mode fix. Commit remains undone.

### Task I0.5: Intel onboarding honesty

**Files:**
- Modify: `Dory/Models/AppStore.swift:182-189` (`dockerCompatibleFallbackHint` at `:183` and `sharedVMUnavailableStatus` at `:189`, the static helpers where the engine-off copy actually lives; the routing that surfaces it is `connectBackend` at `:353-370`)

- [x] On Intel (`MacHostPlatform.isAppleSilicon == false`), the engine-off hint explains that the built-in Intel engine needs bundled engine assets and Hypervisor.framework support, then points users at a local Docker-compatible fallback. Keep the Apple-silicon copy unchanged. Commit `fix(app): honest Intel engine-status copy`.

**Track I0 exit criteria:** all five fixes merged; `lipo -archs` proves universal; appcast entry carries 15.0; an Intel Mac in proxy mode reports its true arch through `docker version`.

---

# Track I1: amd64 guest artifacts + in-repo initfs pipeline

Everything the guest side needs, buildable on any Mac (no Intel hardware required). Also removes the Apple-`container` initfs dependency, which is what currently drags the macOS 26 requirement into the engine path.

**Branch:** `feat/intel-i1-guest-artifacts`

**Local status (2026-07-05):** kernel/agent/initfs build scripts and bundle resource selection are
implemented. The initfs builder uses pinned Alpine minirootfs and Docker static tarballs directly
instead of a Docker-based assembly container; the Apple `container` initfs fallback has been removed.
Artifact verification and boot/readiness gates remain open until the guest images are actually built
and exercised. On this machine Docker is installed but the daemon was unavailable during local
verification, so the x86 kernel artifact build has not been completed here; `guest/out` currently
contains the dual-arch agents and initfs images, but not `vmlinux-x86.zst` or `bzImage-x86`.

### Task I1.1: x86_64 guest kernel build

**Files:**
- Modify: `guest/kernel/build.sh` (take `ARCH` parameter: `arm64` default, `amd64` new)
- Create: `guest/kernel/dory-x86.config` (x86 additions fragment)
- Modify: `guest/kernel/dory.config` (split the two PL011 console lines 49-50 into an arm-only fragment `dory-arm.config` so the shared fragment stays arch-neutral; lines 48 `CONFIG_TTY` and 51 `CONFIG_VIRTIO_CONSOLE` are arch-neutral and stay shared)

**Interfaces:**
- Produces: `guest/out/Image.zst` (arm64, unchanged name) and `guest/out/vmlinux-x86.zst` + `guest/out/bzImage-x86` (amd64). `vmlinux` is the primary x86 ELF output and carries the PVH note when `CONFIG_PVH=y`; `bzImage` is derived from it (compressed + real-mode stub) and does NOT carry the note. dory-hv-x86 loads the vmlinux (Track I3); the VZ path loads the bzImage (Track I2). Same pinned 6.12.30 source, same PINS file.

- [x] **Step 1: Write `guest/kernel/dory-x86.config`:**

```
CONFIG_PVH=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_X86_MPPARSE=y
CONFIG_SERIO_I8042=y
CONFIG_KEYBOARD_ATKBD=y
CONFIG_PCI=y
CONFIG_VIRTIO_PCI=y
CONFIG_ACPI=y
CONFIG_UNWINDER_ORC=y
```
(x86 `defconfig` already enables ACPI/PCI; the lines are pinned here so `merge_config.sh` output is deterministic. PVH is the dory-hv-x86 boot path; 8250 is the x86 serial console; MMIO_CMDLINE registers our virtio devices; MPPARSE reads our MPTABLE; i8042+ATKBD give the guest a reset line; PCI/VIRTIO_PCI are for the VZ interim engine which exposes devices over PCI.)

Move `CONFIG_SERIAL_AMBA_PL011=y` / `CONFIG_SERIAL_AMBA_PL011_CONSOLE=y` out of `dory.config` into a new `dory-arm.config`; everything else in `dory.config` (virtio, PAGE_REPORTING, DAX chain, USBIP, netfilter/IPVS, binfmt_misc, overlayfs) is arch-neutral and stays shared. The netfilter/IPVS/bridge/veth/cgroup/overlay set is exactly what the one-click k3s feature needs; carrying the shared fragment verbatim is what keeps Kubernetes working on the amd64 guest (gated in I4.4).

- [x] **Step 2: Parameterize `guest/kernel/build.sh`:** `ARCH=${1:-arm64}`. For `amd64`: `--platform linux/amd64`, merge `dory.config` + `dory-x86.config`, `make -j$(nproc) vmlinux bzImage`, copy `vmlinux` -> `/out/vmlinux-x86` (zstd to `vmlinux-x86.zst`) and `arch/x86/boot/bzImage` -> `/out/bzImage-x86`. For `arm64`: unchanged behavior plus the `dory-arm.config` merge.
- [ ] **Step 3: Verify artifacts on the build host (no Intel hardware needed):** `file guest/out/bzImage-x86` reports an x86 Linux kernel; `readelf -n guest/out/vmlinux-x86 2>/dev/null | grep -A1 Xen` shows the `XEN_ELFNOTE_PHYS32_ENTRY` PVH note (name `Xen`, type 0x12). If the note is missing, PVH did not build; fix before proceeding.
- [ ] **Step 4:** Re-run the arm64 build, boot-check via the existing `dory-hv agent-ping` readiness step to prove no regression. Commit `feat(guest): x86_64 kernel build (PVH vmlinux + bzImage) alongside arm64`

### Task I1.2: amd64 guest agent

**Files:**
- Modify: `guest/agent/build.sh:5`

- [x] **Step 1:** Build both arches to distinct outputs:

```bash
for GOARCH in arm64 amd64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -trimpath -ldflags='-s -w' \
    -o "../out/dory-agent-$GOARCH" .
done
ln -sf dory-agent-arm64 ../out/dory-agent
```
(The symlink keeps every existing consumer of `guest/out/dory-agent` working.) The agent is pure Go over `golang.org/x/sys/unix` with no assembly; nothing else changes.
- [x] **Step 2:** `file guest/out/dory-agent-amd64` reports x86-64 static ELF; `go vet ./... && go test ./...` in `guest/agent`. Commit `feat(guest): build dory-agent for amd64 alongside arm64`

### Task I1.3: In-repo initfs pipeline (both arches)

The initfs is currently sourced from Apple `container`'s vminit ext4 (`bundle-engine.sh:312`), which exists only on Apple-silicon build hosts and is the root of the macOS 26 coupling. Replace it with a reproducible in-repo build for BOTH arches.

**Files:**
- Create: `guest/initfs/build.sh`, `guest/initfs/init` (the /sbin/init script), `guest/initfs/PINS` (busybox/base image digests)
- Modify: `scripts/bundle-engine.sh` (consume `guest/out/initfs-<arch>.ext4` instead of the Apple container path; keep `DORY_INITFS` as an override)

**Interfaces:**
- Produces: `guest/out/initfs-arm64.ext4` and `guest/out/initfs-amd64.ext4`. Contents: static busybox (all applets), `/sbin/init` (our script: mount proc/sys/dev, launch `/usr/bin/dory-agent`, then exec the engine bring-up the current init performs), `/usr/bin/dory-agent` (arch-matched), `/.dory-toolbox/bin/{busybox,curl,strace}` (arch-matched), and for cross-arch containers `qemu-x86_64-static` (arm64 initfs) or `qemu-aarch64-static` (amd64 initfs).

- [x] **Step 1 [SPIKE, half a day]: inventory the current initfs.** `debugfs -R 'ls -l /' ~/.dory/vm/dory-vm-initfs.ext4` (and `/sbin`, `/usr/bin`, `/etc`) plus `debugfs -R 'cat /sbin/init'`. Record every file and the full init script into `guest/initfs/CONTENTS.md`. The rebuild must reproduce the behaviors the engine relies on (mounts, console, agent launch, engine handoff), not the exact byte contents.
- [x] **Step 2:** Write `guest/initfs/build.sh`: assemble a root dir from pinned per-arch Alpine minirootfs and Docker static tarballs, add our init and agent, then `mke2fs -d rootdir -t ext4 initfs-<arch>.ext4 <size>`. Pin every downloaded binary source in `PINS` by sha256.
- [ ] **Step 3:** Boot-test the arm64 rebuild through the full existing readiness suite (engine boots dockerd, agent answers, containers run). This proves the in-repo initfs is a drop-in before any Intel work depends on it.
- [x] **Step 4:** Update `bundle-engine.sh`: source initfs from `guest/out/initfs-$(target arch).ext4`; generalize `is_linux_aarch64_elf` (`:126-132`) to `is_linux_elf_for_arch`; make `inject_qemu_into_initfs` (`:109-124`) arch-aware (inject `qemu-aarch64-static` into the amd64 initfs) and give its discovery helper `find_qemu_x86_64_static` (`:95-107`) a per-arch twin; drop the Apple `container` fallback path. Commit `feat(guest): reproducible in-repo initfs for arm64 and amd64`

### Task I1.4: Arch-suffixed engine resources + per-arch gvproxy

**Files:**
- Modify: `scripts/bundle-engine.sh` (resource naming + gvproxy)
- Modify: `Dory/Runtime/Shared/SharedVMProvisioner.swift:78,229-234,280-282` (resource selection by host arch)
- Modify: `Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift:351`, `Packages/ContainerizationEngine/Sources/dory-vmboot/Boot.swift:246` (the two `Platform(arch: "arm64")` literals) and `Boot.swift:177` (the `.linuxArm` kernel-platform hardcode); `Boot.swift:132` already reads `args.arch` and needs no change

**Interfaces:**
- Resource names become `dory-vm-kernel-<arch>.zst` and `dory-vm-initfs-<arch>.ext4.zst` (`<arch>` in `arm64|amd64`); `SharedVMProvisioner` resolves `<arch>` from `MachineArch.host`. The amd64 kernel resource contains the bzImage for the VZ path; the vmlinux resource for dory-hv-x86 (`dory-hv-kernel-amd64.zst`) is added and wired by milestone I3.5, which owns it.
- gvproxy: gvisor-tap-vsock's published release asset `gvproxy-darwin` is already a universal (fat amd64+arm64) binary; bundle it directly, pinned by sha256. (Per-arch `gvproxy-darwin-amd64/arm64` exist only as intermediate make targets that upstream merges and deletes; build from source only if the fat binary ever becomes a size problem.)

- [x] **Step 1:** Rename bundle outputs with arch suffixes; keep unsuffixed names as symlinked aliases for one release so existing installs upgrade cleanly. The bundle script now emits `dory-hv-kernel-<arch>.zst`, `dory-vm-kernel-<arch>.zst`, and `dory-vm-initfs-<arch>.ext4.zst`; host-arch unsuffixed aliases are retained for one release. The implicit installed-kernel fallback is arm64-only for both VZ and raw HV paths so Intel raw HV cannot accidentally bundle a non-PVH Apple container kernel.
- [x] **Step 2:** `SharedVMProvisioner` computes the suffix once (`private var engineArch: String`), uses it in `hvKernelPath()` and `vmInitfsPath()`. Intel VZ availability now requires suffixed amd64 VZ assets; legacy unsuffixed and installed-resource fallbacks are arm64-only except for the one-release raw-HV host alias.
- [x] **Step 3:** Replace the two `Platform(arch: "arm64")` literals (`EngineMode.swift:351`, `Boot.swift:246`) and the `.linuxArm` hardcode (`Boot.swift:177`) with host-arch-derived values (`MachineArch.host.rawValue` app-side; `uname`-derived in the helpers).
- [ ] **Step 4:** Full arm64 regression: `scripts/readiness.sh` core tracks green on Apple silicon. Commit `feat(engine): arch-suffixed resources, universal gvproxy, parameterized dind arch`

**Track I1 exit criteria:** one `bundle-engine.sh` run on an Apple-silicon host can produce a bundle containing BOTH arch guest asset sets; arm64 readiness is fully green using the in-repo initfs; every amd64 artifact verifies by `file`/`readelf` inspection.

---

# Track I2: VZ engine on Intel (first Intel engine release)

Ship Dory's self-contained engine on Intel using the Virtualization.framework helper that already exists (`dory-vmboot`), with the I1 amd64 artifacts. This is the same fallback-engine role dory-vm plays on Apple silicon. It will NOT have elastic memory (Apple's traditional balloon cannot return host RAM, proven in the Phase 0 measurements); it exists to (a) give Intel users a real Dory engine now, (b) shake out every arch assumption end to end, and (c) provide the A/B baseline dory-hv-x86 must beat.

**Branch:** `feat/intel-i2-vz-engine` | **Expand into its own plan before execution.**

**Design (locked):**
- Engine tiers replace the binary gate. `DoryHVSupport.evaluate()` (`Dory/Runtime/Apple/AppleContainerSupport.swift:62-70`) becomes `EngineSupport.evaluate() -> EngineTier` with `enum EngineTier { case hvNative, vzShared, proxyOnly }` plus a reason. Apple silicon + assets -> `.hvNative` (unchanged behavior). Intel + `kern.hv_support` + amd64 assets -> `.vzShared` (new). Otherwise -> `.proxyOnly`. `SharedVMProvisioner.hostSupport()` (`SharedVMProvisioner.swift:57-70`) and `AppStore.connectBackend` (`AppStore.swift:335-371`) route on the tier. `RuntimeSupportTests.swift:20-25,46-48` is rewritten: Intel is no longer `.architecture`-rejected; the old assertions become "Intel resolves to `.vzShared` when assets exist, `.proxyOnly` when not."
- dory-vmboot arch parameterization: `Args.arch` (`Boot.swift:66`) defaults to the host arch; `tunedKernel()` (`Boot.swift:170-178`) selects the platform by arch. RISK (verify first in the expansion plan): whether the vendored containerization `Kernel` platform type has an x86 case. If it does not, bypass the wrapper on Intel and construct `VZVirtualMachineConfiguration` directly with `VZLinuxBootLoader(kernelURL: bzImage)` + initrd + cmdline `console=hvc0` (VZ virtio console) or `console=ttyS0`, virtio-blk/net/vsock/fs devices, which VZ supports on Intel hosts. The Rosetta code paths stay behind their existing `#if arch(arm64)` gates and are never invoked on Intel (Rosetta has no meaning there; amd64 is native).
- The engine-mode docker flow (dind rootfs unpack, journaled data disk, gvproxy, port forwarding, docker context routing, shim) is arch-neutral and reused as-is with the I1 parameterizations.
- The `Run x86 with Rosetta` setting (`SettingsView.swift:444-454`) is hidden on Intel hosts (feature is native there).
- Emulated-arch flip: `MachineService.ensureEmulation` already installs binfmt for non-native arches symmetrically; verify `docker run --platform linux/arm64 alpine uname -m` -> `aarch64` on the Intel machine (via the I1 qemu-aarch64 injection or the tonistiigi fallback).

**Task list:**
- [ ] I2.1 `EngineTier` model + gating rework + tests (`RuntimeSupportTests` inversion; unit-testable on any arch by injecting the platform struct)
- [ ] I2.2 dory-vmboot amd64 boot: platform selection or direct-VZ fallback; boots the I1 bzImage + amd64 initfs to a shell on the Intel test Mac
- [ ] I2.3 Shared engine end to end on Intel: dockerd up, `docker run hello-world` (native amd64), shim + context routing, ports, compose
- [ ] I2.4 arm64-emulation flip verified (`--platform linux/arm64` works via qemu-aarch64)
- [ ] I2.5 readiness.sh: core Docker tracks green on Intel against the VZ engine; `test_amd64` (`readiness.sh:448-455`) split into `test_nonnative_arch` that asserts the OPPOSITE arch of the host (amd64 emulated on arm64 hosts, arm64 emulated on x86_64 hosts)
- [ ] I2.6 Release marker `0.8.0 "Dory engine on Intel (beta)"`: universal app + both asset sets (or amd64 assets downloaded on first run if the zip budget requires it), Sparkle + cask updated, README/COMPATIBILITY updated to "Intel: built-in engine (beta), fast engine in development"

**Exit criteria:** a stock Intel Mac with no Docker tooling installs Dory and runs containers with zero third-party dependencies; readiness core is green on Intel hardware.
**Claims unlocked:** "Dory runs its own engine on every Mac, Intel included. Free, open source, no Docker Desktop license."

---

# Track I3: dory-hv-x86 core VMM (the fast engine)

The centerpiece: port the raw Hypervisor.framework VMM to x86_64. The device/transport layer (5662 LoC: virtqueues, virtio-blk/net/vsock/rng/balloon/fs, FUSE server, usbip, agent channel, gvproxy glue, DirectIPBridge) is reused unchanged. What is new or rewritten, with the design locked below: vCPU/exit loop, boot, interrupts, timers, MMIO decode, and four small platform devices.

**Branch:** `feat/intel-i3-hv-x86` | **Expand into its own plan before execution.**

## Locked design decisions

1. **Boot protocol: PVH.** We control the guest kernel, so it ships `CONFIG_PVH=y` (I1.1). The VMM parses the `vmlinux` ELF, finds `XEN_ELFNOTE_PHYS32_ENTRY`, builds `hvm_start_info` (cmdline pointer, memmap, initrd module entry), and enters at the 32-bit entry with paging off, `EBX` = start_info physical address, flat protected-mode segments. This avoids writing the long-mode/page-table/zero-page bring-up that the 64-bit boot protocol would demand. A bzImage/64-bit-protocol loader is explicitly out of scope for v1 (users who want custom kernels build them PVH; revisit only on demand).
2. **virtio transport: keep virtio-mmio.** Devices are registered via kernel cmdline `virtio_mmio.device=<size>@<addr>:<irq>` entries, one per attached slot, generated exactly where the FDT nodes are generated today. `VirtioMMIO.swift` and every device behind it port with zero changes. virtio-pci is out of scope for v1.
3. **Interrupts: Apple's in-kernel APIC, with a userspace fallback gate.** `hv_vm_create(HV_VM_ACCEL_APIC)` gives an in-kernel LAPIC + IOAPIC + 8259 (macOS 12+, verified in the SDK headers: `hv_vm_lapic_set_intr`, `hv_vm_ioapic_assert_irq`, `hv_vcpu_apic_*`, INIT/SIPI via `hv_vcpu_exit_info`). `Machine.raiseSPI(spi)` becomes `raiseGSI(gsi)` -> `hv_vm_ioapic_assert_irq`/`deassert`. Risk: this API surface has little public usage (QEMU predates it and emulates its own). Task I3.2 is a hard go/no-go spike; the fallback is a userspace LAPIC+IOAPIC (xhyve's `ioapic.c`/`atpic.c` as reference, roughly +1200 LoC and +2 weeks) with `hv_vcpu_interrupt` + VMCS event injection.
4. **Timer/clock: TSC everywhere.** Guest CPUID exposes invariant TSC (leaf 0x80000007 EDX[8]) and TSC-deadline (leaf 1 ECX[24]); `IA32_TSC` runs native via `hv_vcpu_enable_native_msr`; guest cmdline pins `clocksource=tsc tsc=reliable`. With the in-kernel APIC, the LAPIC timer/TSC-deadline is serviced in-kernel; on the fallback path the VMM arms a host `DispatchSourceTimer` per vCPU for the deadline and injects the timer vector. Wall clock: CMOS RTC (below) + the existing vsock `clock.sync` (already handles host-wake resync; arch-neutral).
5. **MMIO exits: minimal x86 instruction decoder + guest page-table walker.** On `EXIT_REASON_EPT_FAULT` in a device window, fetch the instruction at guest RIP (walking the 4-level guest page tables, 4K/2M/1G pages, to translate RIP and read up to 15 bytes), decode, execute against `MMIOBus`, advance RIP by the decoded length. Scope: prefixes + REX + ModRM + SIB parsing, and the forms compiler-generated `readl/writel` produce: `MOV r/m,r` (0x88/0x89), `MOV r,r/m` (0x8A/0x8B), `MOV r/m,imm` (0xC6/0xC7), `MOVZX` (0x0F 0xB6/0xB7), `MOVSX` (0x0F 0xBE/0xBF), all widths. Anything else raises a fatal diagnostic that logs RIP + 15 instruction bytes (turning any gap into a one-look bug report). The APIC pages are handled in-kernel (decision 3), so the decoder only ever sees our virtio windows: the trap surface is small and controlled by our own kernel config.
6. **PIO devices, no decoder needed:** port I/O arrives as `EXIT_REASON_INOUT` with size/direction/port pre-decoded in the exit qualification. Implement a `PIOBus` with: 16550A UART at 0x3f8 IRQ4 (console, `console=ttyS0`), MC146818 CMOS RTC at 0x70/0x71 (wall clock at boot), i8042 at 0x60/0x64 (reset stub: the 0xFE pulse is the guest-reboot signal, and the poweroff path is agent-driven exactly like today). Optionally register `hv_vm_add_pio_notifier` on virtio notify addresses later as a doorbell fast path (not v1).
7. **SMP: INIT/SIPI via `hv_vcpu_exit_info` (`HV_VM_EXITINFO_INIT_AP` / `STARTUP_AP`),** with CPU count and IOAPIC published through an MPTABLE (`CONFIG_X86_MPPARSE=y` in the I1 kernel). The MPTABLE MUST carry type-3 I/O-interrupt entries mapping each virtio IRQ to the identical IOAPIC pin `hv_vm_ioapic_assert_irq` is called with; cmdline IRQ, MPTABLE entry, and injection pin come from one shared constant per slot. ACPI tables are out of scope for v1. GATED ASSUMPTION, not settled fact: a 6.12 kernel with `ACPI=y` compiled but no ACPI tables provided falls back to MPTABLE parsing (the regime Firecracker booted in for years, but less exercised upstream since Firecracker moved to ACPI). The I3.3 gate watches dmesg for the successful MPS parse; documented fallbacks if it misbehaves: `acpi=off` on the guest cmdline, or emit a minimal RSDP+MADT the way current Firecracker does.
8. **Memory: page size becomes a parameter.** `GuestMemory.pageSize` (16384 literal at `GuestMemory.swift:16`), `VirtioBalloon.swift:19`, and `Fuse/DaxWindow.swift:36` switch to a single `HostPage.size` sourced from `vm_page_size` (16384 on AS, 4096 on Intel), and the FUSE DAX alignment advertised at init becomes `log2(HostPage.size)`. Free-page reporting keeps working unchanged: the guest reports 2M blocks, which are whole multiples of 4K host pages (cleaner than the 16K case).
9. **Source layout: `#if arch()` file-level split, shared protocols.** New sources `Machine_x86.swift`, `VCPUx86.swift`, `PVHLoader.swift`, `MPTable.swift`, `X86Decoder.swift`, `GuestPageWalker.swift`, `UART16550.swift`, `CMOSRTC.swift`, `I8042.swift`, `CPUIDPolicy.swift`, `GuestLayoutX86.swift` under `Sources/DoryHV/x86/`, all wrapped `#if arch(x86_64)`; the existing arm64-only files (Machine, VCPU, GICv3MMIO, FDT, KernelImage, PL011, PL031, Smoke, DaxCoherenceProbe) get wrapped `#if arch(arm64)`. Shared seams: `MMIODevice`/`MMIOBus` (already neutral), a new `PIODevice`/`PIOBus`, and a small `MachineHosting` protocol so `dory-hv/main.swift` + `EngineMode.swift` wire devices identically on both arches (their only arch branches: console cmdline `ttyAMA0` vs `ttyS0`, GuestLayout constants, virtio cmdline vs FDT).
10. **Guest layout (GuestLayoutX86):** RAM from 0x0 with the conventional sub-1M hole honored in the e820/start_info memmap; virtio-mmio window at 0xd000_0000 (slot stride 0x1000), DAX window above the top of RAM as today. Virtio interrupts use IOAPIC pins 16..23 (the IOAPIC has 24 pins, 0..15 are legacy ISA), advertised identically in the cmdline `:irq` field and the MPTABLE I/O-interrupt entries per decision 7; Firecracker's low-IRQ convention (5 and up) is an acceptable alternative if 16..23 misbehaves, so long as all three sites stay one constant. Locked at expansion time against the memmap the kernel accepts.

## Milestones with gates (each is a demo on the Intel test Mac)

- [ ] **I3.0 Arch-split refactor (no Intel hardware needed).** Wrap arm64 files, introduce `HostPage.size` + `PIOBus` + shared seams, make the whole package compile for BOTH arches: `swift build --arch arm64 --arch x86_64` green on the Apple-silicon build host; all existing DoryHVTests still pass on arm64. Gate: universal build + zero arm64 behavior change. Commit early; this unblocks I0.4's helper bundling too.
- [ ] **I3.1 x86 Smoke.** `Smoke_x86.swift`: real-mode guest (Unrestricted Mode), a few hand-assembled bytes ending in `out %al, $0xF4`, VMM sees `EXIT_REASON_INOUT` with the expected value. Gate: `dory-hv smoke` passes on the Intel Mac. This validates VM create, memory map, vCPU run loop, and exit decoding end to end.
- [ ] **I3.2 [SPIKE, go/no-go, 3 days] In-kernel APIC.** With `HV_VM_ACCEL_APIC`: inject a vector via `hv_vm_lapic_set_intr` into a tiny guest with a real IDT and observe delivery; assert an IOAPIC GSI and observe routing; verify `hv_vcpu_exit_info` reports INIT/SIPI for a second vCPU; verify the in-kernel APIC timer fires (guest arms TSC-deadline, interrupt arrives without VMM timer help). GO: decision 3 stands. NO-GO on any leg: document which legs failed, fall back to userspace LAPIC/IOAPIC for those legs only, re-estimate (+2 weeks worst case).
- [ ] **I3.3 PVH boot to serial banner.** PVHLoader + start_info + memmap + MPTABLE + UART16550 + CPUIDPolicy + MSR handling (native TSC, EFER and friends per QEMU's hvf MSR list) + HLT idle blocking. Gate: the I1 vmlinux prints its full boot log on `console=ttyS0` and panics only at "no init found" when booted without an initfs. This is the hardest gate; expect most debugging here (CPUID and MSR gaps present as silent early hangs; mitigate by comparing against QEMU `target/i386/hvf` and xhyve for every unexpected exit reason).
- [ ] **I3.4 MMIO decoder + virtio up.** X86Decoder + GuestPageWalker + virtio-mmio cmdline generation; decoder unit tests run on ANY arch (pure byte-level tests with assembler-generated fixtures; add these to the always-on CI suite). Gate: guest mounts the initfs from VirtioBlk, dory-agent answers `agent-ping` over vsock on the Intel Mac.
- [ ] **I3.5 Engine mode on Intel.** First: bundle `guest/out/vmlinux-x86.zst` as resource `dory-hv-kernel-amd64.zst` in `bundle-engine.sh` and extend the `SharedVMProvisioner`/`EngineMode` kernel-path resolution to select it for the hvNative tier on Intel (this milestone owns that wiring, mirroring the I1.4 suffix pattern). Then `EngineMode` boots the amd64 dind rootfs, dockerd up, gvproxy networking, ports, the full shim. Gate: readiness core Docker tracks green against dory-hv-x86; `DORY_HV_ENGINE=1` works on Intel.
- [ ] **I3.6 SMP + elastic memory.** 4 vCPUs via INIT/SIPI + MPTABLE; free-page reporting -> `madvise` at 4K granularity verified (host RSS drops after guest frees memory; the MadviseProbe diagnostic generalized to x86). Gate: A/B memory benchmark against the I2 VZ engine and Docker Desktop on the same Intel machine, published like the existing 472-vs-849 MB result.
- [ ] **I3.7 Stability soak.** The known failure mode of HVF-x86 stacks is sustained-memory-pressure crashes (QEMU issue #1091, `vmx_write_mem: mmu_gva_to_gpa failed`, reproducible via a big `git clone` in the guest). Soak: 24h loop of parallel `git clone` + kernel build + `docker build` in containers, plus host sleep/wake cycles (clock resync assertions). Gate: zero VMM crashes, guest clock within 100 ms of host after wake, no fd/memory leaks over the soak.

**Effort note (honest):** I3 is 6 to 9 focused weeks: ~1 week I3.0, ~1 week I3.1+I3.2, 2 to 3 weeks I3.3 (boot debugging dominates), ~1 week I3.4, ~1 week I3.5, 1 to 2 weeks I3.6+I3.7. The +2 week APIC fallback risk is on top. New code is roughly 2500 to 3500 LoC of Swift plus tests, replacing 1129 LoC of arm64-only code; for calibration, the whole existing library is 6791 LoC and xhyve (full-PC scope we are NOT taking) is tens of thousands.

**Claims unlocked:** "Our own VMM on Intel too: the only container runtime that returns idle memory to macOS on any Mac."

---

# Track I4: Differentiator parity on Intel

Everything that makes dory-hv worth having, verified on x86. Most items are "already arch-neutral, now prove it," not new builds.

**Branch:** `feat/intel-i4-parity` | **Expand into its own plan before execution.**

- [ ] I4.1 **virtio-fs + DAX at 4K.** The FUSE server and DAX window port unchanged; the 16K alignment shim relaxes to `HostPage.size` (I3 decision 8). Re-run the DAX coherence probe (generalized from `DaxCoherenceProbe.swift`, x86 instruction bytes) on Intel: file-backed `hv_vm_map` coherency is expected to hold but is unverified on Intel hardware until this gate. Fallback if it fails: plain virtio-fs without DAX (same graceful flag-gating as on arm64). Benchmarks vs OrbStack/Docker Desktop on the Intel machine, recorded in `docs/research/file-sharing.md`.
- [ ] I4.2 **USB passthrough.** IOUSBHost + the usbip stack are arch-neutral; the amd64 kernel keeps `CONFIG_USBIP_VHCI_HCD=y` (shared fragment). Re-run the hardware smoke matrix on the Intel Mac. Note macOS policy gates (notarization, capture entitlement) are identical on Intel.
- [ ] I4.3 **Direct IP + networking polish.** gvproxy-amd64 (I1.4), DirectIPBridge, `*.dory.local` domains, VPN coexistence: re-run the readiness tracks on Intel; fix what breaks (expected: none, all userspace).
- [ ] I4.4 **Readiness Intel twins.** Every dory-hv-bound track (`direct_ip`, `vpn`, `dax`, `guest_agent`, `clock_sync`, `usb`, `bridge`, `machines`, `debug_shell`) plus the Kubernetes track runs on the Intel runner: the one-click k3s cluster must come up and pass the existing k8s readiness assertions on both the VZ and hv-x86 Intel engines (the k3s kernel symbols ride the shared fragment, I1.1). `test_rosetta` is marked N/A on Intel with an explicit skip reason; the guest-agent assertion `"kernel":"6.12.30-dory"` already matches both arches (same version string).
- [ ] I4.5 **Benchmark methodology: Intel edition.** New section in `docs/research/benchmark-methodology.md`: Dory (hv-x86) vs Dory (vz) vs Docker Desktop vs Colima-vz vs OrbStack (if the machine is inside OrbStack's fence) on the Intel test Mac: memory footprint/reclaim, boot time, file sharing, network. Audit every hardcoded image in readiness/benchmarks for amd64+arm64 manifests (the iperf3 trap from `benchmark-methodology.md:216`, inverted).
- [ ] I4.6 **Machines + recipes on Intel.** `scripts/dory` and recipe defaults follow `MachineArch.host` (I0.2); amd64 machines native, arm64 machines emulated with honest labeling (existing `ensureEmulation` flow).

**Exit criteria:** the full readiness suite (minus explicit N/A tracks) is green on Intel hardware with dory-hv-x86 as the engine; published Intel benchmark table.

---

# Track I5: CI, release, docs, positioning

**Branch:** `feat/intel-i5-ship` (docs/CI changes land continuously; this track is the checklist)

**Local docs status (2026-07-05):** README, COMPATIBILITY.md, docs/comparison.md, the Homebrew
cask stanza, and website Install/UnderTheHood/MemoryBars/Hero copy have been updated to the
tiered Intel engine story. The generated GitHub Pages output was rebuilt from `website/`. The
full I5.3 gate remains open until real Intel A/B numbers exist and can be added without inference.

- [ ] I5.1 **CI matrix.** (a) `build-x86_64` cross-compile job from I0.4 (hosted arm64 runner, catches slice rot); (b) decoder/boot-serialization unit tests (pure logic) run in the hosted suite on every PR; (c) self-hosted Intel runner job: `DoryHVTests` (which today run in NO CI, fix that for arm64 at the same time on the existing self-hosted runner) + readiness core, nightly and on engine-touching PRs; (d) release workflow builds universal and asserts `lipo -archs` in a gate step.
- [ ] I5.2 **Release.** Marker `0.9.0 "The fast engine on Intel"`: dory-hv-x86 default engine on Intel (VZ demoted to fallback, same posture as Apple silicon), notarized universal build, appcast + cask, GitHub release notes with the Intel benchmark table.
- [ ] I5.3 **Docs sweep.** README (replace the Requirements block: the "Dory's own engine requires Apple silicon" blockquote plus its Apple-silicon/Intel bullets, roughly lines 99-110 today, with the Intel engine matrix; anchor on the text, line numbers drift), COMPATIBILITY.md (new Intel engine matrix + the honest-horizon statement), docs/comparison.md, website Install/UnderTheHood/MemoryBars components (add the Intel A/B once measured), `Casks/dory.rb` stanza review.
- [ ] I5.4 **Positioning.** Launch content: "Dory brings elastic memory to Intel Macs" (the OrbStack fence and Docker VMM AS-only facts, cited); explicit support statement: "Intel supported through the macOS 26 security window (approximately 2028); your containers, machines, and volumes migrate to Apple silicon with Dory's portable machines when you do." Close GH#3-style Intel asks with the roadmap link.
- [ ] I5.5 **Memory/telemetry-free success check.** Define graduation-to-default criteria before I5.2 ships: readiness green 2 consecutive weekly runs on Intel, soak clean, no open P1 Intel issues.

---

## Sequencing and rough effort

| Phase | Tracks | Effort (focused) | Release marker |
|---|---|---|---|
| 1 | I0 | 2-4 days | ships with next regular release |
| 2 | I1 | 1.5-2 weeks | (build-side only) |
| 3 | I2 (+ I3.0 in parallel) | 1.5-2.5 weeks | 0.8.0 "Dory engine on Intel (beta)" |
| 4 | I3 | 6-9 weeks (+2 risk) | internal alpha behind `DORY_HV_ENGINE=1` |
| 5 | I4 | 3-4 weeks | benchmark publication |
| 6 | I5 | 1-2 weeks (mostly parallel) | 0.9.0 "The fast engine on Intel" |

Total: roughly 3.5 to 4.5 focused months. Natural pause points: after I2 (Intel users have a real engine; decide with fresh market data whether I3 proceeds immediately) and after I3.5 (engine works; I4 ordering can follow user demand).

## Decision gates and risk register

1. **In-kernel APIC (I3.2)** is the load-bearing bet. GO: the plan as written. Partial NO-GO: userspace irqchip fallback, +2 weeks, design already referenced (xhyve). Total NO-GO (HVF x86 fundamentally broken on our test hardware, contradicting the QEMU/xhyve existence proofs): stop I3, ship I2's VZ engine as Intel's terminal state, and say so publicly; Intel still gets a self-contained free engine, just not the memory win.
2. **Sustained-load stability (I3.7).** QEMU's HVF-x86 has a documented crash under memory pressure. Our stack is simpler (no shadow paging paths QEMU exercises), and the gva-to-gpa walker is only used for instruction fetch, but the soak gate exists precisely because this class of bug decides shippability. Budget real time for it.
3. **Vendored containerization framework on x86 (I2.2).** If `Kernel`'s platform enum has no x86 case, the locked fallback (direct VZ configuration) is small and well-understood; do not fork the vendored package.
4. **DAX coherency on Intel (I4.1)** is probable but unproven until the probe runs; plain virtio-fs is the shippable fallback, as it was on arm64.
5. **Market decay.** Every quarter of delay shrinks the Intel base. That argues for shipping I2 fast (it is cheap) and deciding on I3 with real adoption numbers from the 0.8.0 beta. The pause point after Phase 3 is deliberate.
6. **Hardware dependency.** One Intel test Mac is a single point of failure for CI and soak; a second cheap unit (2018 mini class, Sequoia-capable) removes it. Flag at purchase time.
7. **MPTABLE-without-ACPI-tables boot (I3 decision 7)** is a gated assumption on kernel 6.12, verified at the I3.3 gate; fallbacks (`acpi=off` cmdline, minimal RSDP+MADT) are locked in the decision text.

## Self-review notes

- Every guest-side capability the tracks assume is present in the I1.1 kernel fragments (PVH, 8250, MMIO cmdline, MPPARSE, i8042; DAX/usbip/binfmt/netfilter inherited from the shared fragment).
- The interface names introduced here are used consistently: `EngineTier`/`EngineSupport.evaluate` (I2.1, consumed I2.6, I5.2), `HostPage.size` (I3.0, consumed I3 decision 8 and I4.1), `PIOBus` (I3 decisions 6, 9), `raiseGSI` (I3 decision 3), arch-suffixed resources `dory-vm-kernel-<arch>.zst` (I1.4, consumed I2.2, I2.6).
- Risky items carry explicit spikes with go/no-go gates and shippable fallbacks: in-kernel APIC (I3.2), initfs inventory (I1.3 step 1), containerization x86 platform case (I2.2), DAX-on-Intel (I4.1), stability soak (I3.7).
- Known open values deliberately not invented here: busybox/base digests in `guest/initfs/PINS` (pin at execution), the exact GuestLayoutX86 constants (locked at I3 expansion against the kernel's accepted memmap), gvproxy amd64 artifact sha256 (pin at execution).
- Consistency with the VM platform roadmap (2026-07-04): this plan is a sibling master track; the roadmap's global constraint "Apple silicon only for dory-hv" is superseded by this plan when I3 lands; Track 4 (x86 on Apple silicon) is unrelated to and unaffected by this work.

## Fact-check record (2026-07-05)

Load-bearing external claims were researched by an 8-agent recon/research pass (4 codebase investigators, 4 web researchers) with primary sources. The draft plan was then adversarially re-verified by a 3-agent pass (codebase references, technical claims against SDK headers and upstream sources, plan quality); 17 corrections were applied inline, the notable ones being: the LoC partition (1129 arm64-bound / 5662 neutral, replacing an inconsistent 1186/5374 split), the Platform-literal sites (two literals plus one `.linuxArm` hardcode, not three literals), gvproxy shipping as a single universal release asset, the MPTABLE-without-ACPI-tables boot downgraded from fact to a gated assumption with locked fallbacks, the virtio GSI choice explicitly coupled to MPTABLE I/O-interrupt entries, and a previously missing Kubernetes gate added to the gap matrix and I4.4. Key verified findings this plan stands on:

- Hypervisor.framework x86: NOT deprecated (docs metadata: introduced 10.10, no deprecation; Intel requirement is VT-x + EPT + Unrestricted Mode). No `hv_vcpu_exit` struct on x86; exits read from VMCS (`VMCS_RO_EXIT_REASON` et al.). `HV_VM_ACCEL_APIC` (1<<10) plus the full `hv_vcpu_apic_*`/`hv_vm_ioapic_*`/`hv_vm_atpic_*`/`hv_vcpu_exit_info` INIT-SIPI surface exists in the current SDK headers (macOS 12+). PIO via `EXIT_REASON_INOUT` + optional `hv_vm_add_pio_notifier` (11.0). 4 KiB map granularity on Intel. Entitlement `com.apple.security.hypervisor` (11.0+), same key both arches. (SDK headers on this machine; Apple docs JSON.)
- MMIO on x86 requires a userspace instruction decoder: QEMU's HVF backend calls `decode_instruction`/`exec_instruction` on EPT faults and ships a near-complete x86 emulator for it; a MOV-subset decoder suffices for virtio-mmio-only guests but must parse prefixes/REX/ModRM/SIB correctly. (QEMU `target/i386/hvf`, `target/i386/emulate`.)
- Prior art: xhyve/HyperKit prove firmware-less Linux-on-HVF-x86 (bzImage kexec path) but carry a full-PC device model and are dormant/deprecated; Firecracker defines the minimal device set (serial 0x3f8, i8042 reset stub, virtio-mmio via `virtio_mmio.device=` cmdline, MPTABLE historically, ACPI now) but relies on KVM's in-kernel irqchip and kvm-clock, which HVF replaces with ACCEL_APIC and native TSC respectively. PVH entry (`XEN_ELFNOTE_PHYS32_ENTRY`, EBX -> `hvm_start_info`, 32-bit paging-off) per Xen docs; Firecracker itself uses the 64-bit protocol, Cloud Hypervisor supports both. `clocksource=tsc tsc=reliable` is the accepted non-KVM guest clock regime; invariant TSC present on all target Intel Macs.
- Free-page reporting is arch-independent (generic mm + virtio-balloon, `CONFIG_PAGE_REPORTING`); guest reports at pageblock order (2M on x86_64); host reclaim via madvise; 4K/4K host-guest page match makes Intel the easy case. (LWN 808807, kernel sources.)
- Codebase: DoryHV library 6791 LoC, arm64-bound 1129 LoC across the 9 files enumerated in I3 decision 9 (MadviseProbe stays shared and is generalized in I3.6), zero existing `#if arch` conditionals, no build-system arch pin; `DoryHVSupport.evaluate` is the single Intel gate; dory-vmboot hardcodes `.linuxArm` + `Platform(arch: "arm64")` (3 sites); initfs sourced from Apple `container`; appcast minOS 26.0 vs claimed macOS 15+ floor; release.sh builds single-arch despite the universal cask claim; DoryHVTests run in no CI. (file:line evidence in the recon reports.)
- Market: macOS 26 Tahoe (2025-09-15) is the last Intel macOS, four supported Intel models, security tail to ~2028, macOS 27 is AS-only. OrbStack fences Intel to Skylake-Ice Lake CPUs and macOS 14+; Docker VMM is AS-only with HyperKit deprecated; Lima defaults to VZ but non-native-arch requests fall back to QEMU; krunkit is AS-only. No mainstream competitor documents host-RAM reclaim for the broad Intel base. (Vendor docs, GitHub issues.)
