# Dory VM readiness review — 2026-09-15

Reviewed at commit `96a7d61a6` (working tree dirty; see §1.1). Scope: are Linux ARM64, Linux x86_64 and macOS ARM64 virtual machines ready to run through the shipped app, what is wrong, and what is left to be competitive with Parallels / VMware Fusion / UTM.

Method: read the runtime paths for each guest family (DoryHV, DoryDBTX86 + DoryMachinePC, DoryVZMacCore + DoryVMMKit), the daemon admission path (DorydKit), firmware build descriptions, the retained evidence receipts, and built + ran the test suites on this machine (M2 Pro, macOS 26.6.2, Xcode 26.6 RC and Xcode 26 GM).

Everything below is stated as a finding, a location, an impact, and an exact fix. Severity: **P0** = blocks the finish line for a guest family; **P1** = user-visible defect or data risk; **P2** = quality/competitiveness; **P3** = hygiene.

---

## 0. Bottom line

| Guest family | Boots today? | Usable daily? | Blocking gaps |
|---|---|---|---|
| **Linux ARM64** (DoryHV + Hypervisor.framework) | Yes — direct-kernel and UEFI (EDK2) boot, virtio-mmio devices, GPU via renderer worker | Close. Engine is architecturally sound. | Guest **reboot kills the VM** (§2.1); ARM firmware has **no graphical console / no keyboard in UEFI or GRUB** (§2.2); `fsync` instead of `F_FULLFSYNC` (§5.1); no PCIe/xHCI on the board (§2.5). |
| **Linux x86_64** (DoryDBTX86 JIT + DoryMachinePC) | Firmware + tiny fixtures only. Alpine PVH boots to userspace; UEFI installer ISO reached long mode but **no GRUB/kernel milestone within budget**. Gated off in production builds. | **No.** Measured **3–5 MIPS** (§3.1). Ubuntu-class boot ≈ 1 h; `/bin/true` over RPC = 218 s. | Throughput is 2–3 orders of magnitude short; single-threaded vCPU orchestration; x86-64-v1 CPU only (no SSE3+/POPCNT/XSAVE/AVX → RHEL9-class distros, Chrome, many Rust/Go binaries won't run); a **vsock PCI deadlock** (§3.4). |
| **macOS ARM64** (DoryVZMacCore + Virtualization.framework) | Yes — install from IPSW, start, pause, save/restore. | Mostly. Apple does the heavy lifting. | Fixed 1920×1080 single display; NAT-only networking; shared folders wired but admission policy rejects user shares; no host-build preflight before restore (§4). |

Cross-cutting: the dory-core-swift **test target does not compile on the GM Xcode 26 toolchain** (§6.1); one committed test is failing (§6.2); the whole `guest/` tree is deleted-but-uncommitted in the working tree (§1.1); `MachineManager.swift` is 25,441 lines (§7.1).

---

## 1. Repository state

### 1.1 `guest/` is deleted in the working tree (uncommitted) — **P1**

`git status` shows 142 ` D` entries: the entire `guest/{desktop,diagnostics,initfs,kernel,mesa,qemu-builder}` tree is gone from disk but still tracked. This tree is the producer for the managed desktop rootfs, initramfs, kernel and Mesa packs that the ARM desktop path, the desktop-rootfs candidate producer (`candidate.incompleteProducers: ["desktop-rootfs"]` in `docs/virtualization/evidence/review-2026-09-12/candidate-campaign-launch.json`), and `scripts/build-dory-armvirt-firmware.py`'s siblings consume.

Decide and record one of: `git checkout -- guest/` (restore), or `git rm -r guest/` with a commit explaining where the producers moved. Until then, no clean checkout can reproduce a desktop image and the candidate inventory stays "incomplete".

### 1.2 26 untracked evidence files and 4 untracked scripts

`scripts/pc-gpu-daemon-live-gate.sh`, `scripts/test-pc-gpu-daemon-live-gate.sh`, `scripts/validate-wave0-qualification-matrix.py`, `scripts/test-validate-wave0-qualification-matrix.py` and the `wave0-2026-09-08/native-runtime-offline-boot-*` receipts are unversioned. Commit or delete; the plan's own rule is that untracked receipts are not qualification.

---

## 2. Linux ARM64 — DoryHV (`Packages/ContainerizationEngine/Sources/DoryHV`, `dory-hv`)

Overall: this is the strongest engine. vCPU thread ownership, GIC bridging, PSCI, pause/stop rendezvous and guest-memory reclaim are carefully done and the focused suites pass (53 tests in 7 suites when run serially).

### 2.1 Guest reset ends the VM with an error — **P0**

`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:3315-3322`:

```swift
case .reset: VMError.unexpectedExit("desktop guest requested reset")
```

`Machine` is deliberately single-run (`Machine.swift:377-393`), and `RawHVMachineRunner` is single-use. PSCI `SYSTEM_RESET` (`Machine.swift:1135`) therefore ends the run, and the desktop controller reports it as a failure. Nothing in DorydKit relaunches on reset (grep for "requested reset"/reset-relaunch in `DorydKit` returns nothing).

Impact: every ordinary installer ends with a reboot. Ubuntu/Debian/Fedora installs will appear to "crash" at the end, and `sudo reboot` inside a running guest kills the machine. This alone prevents the ordinary-installer journey the plan calls the finish line. (The x86 path *does* handle reset — `DoryPCMode.swift:1147-1180` builds a replacement machine — so the pattern exists.)

Fix (dory-hv, not doryd, so the display window, vsock services, port forwards and renderer worker survive):
1. In `DesktopMode.Controller`, on `.reset`: run the same GPU/FS quiesce used for stop, then build a new `Machine` from the same `MachineConfiguration` (variable store re-`load()`ed, `attachedVirtioSlots` re-attached with the same backends, `bus.seal()`), create a new `RawHVMachineRunner`, and restart. Keep `VirtioBlk`, `VirtioNet`, `VirtioFS`, `VirtioVsock` instances but call their reset paths (`vsock.resetTransportNeutralDevice()`, virtio status reset) — the PC mode shows the exact sequence.
2. Because `hv_vm_create` is per-process and `Machine.deinit` calls `hv_vm_destroy`, either (a) make `Machine` re-runnable (reset vCPU state, re-map RAM/firmware, don't destroy the VM), or (b) destroy and recreate the VM within the process. (a) is cheaper and avoids re-mapping multi-GiB RAM.
3. Add a compatibility gate: the matrix already has `installReboot = "install-reboot"` (`DoryARMVirtCompatibilityMatrix.swift:5`), and `dory-armvirt-uefi-smoke` already expects `.reset` (`main.swift:1609`). Make production `dory-hv desktop` pass that gate.
4. Also handle the reset when the *renderer worker* is attached: the GPU generation must be retired and re-created (mirror `scheduleRendererReplacementReset`).

### 2.2 ARM UEFI firmware has no display output and no keyboard — **P0 for installer UX**

`Firmware/DoryARMVirt/DoryARMVirtPkg/DoryARMVirt.fdf:55-93` includes `SerialDxe`, `TerminalDxe`, `VirtioBlk/Net/Rng`, `Virtio10`, but **no `OvmfPkg/VirtioGpuDxe/VirtioGpu.inf`** and no input driver. (The PC firmware has both: `DoryPC.fdf:184, 277-282`.)

Impact: from the moment the VM starts until Linux's `virtio-gpu` DRM driver binds, the desktop window is black. The UEFI boot menu, GRUB menu and any "Try or Install / Safe graphics" prompt are invisible and cannot be navigated from the window. Editing kernel parameters (`nomodeset`, recovery) is impossible. Compatibility qualification currently drives installers via serial console scripts (`consoleScriptPath` in the matrix), which hides this from evidence.

Fix:
1. Add `OvmfPkg/VirtioGpuDxe/VirtioGpu.inf` to the ARM DSC/FDF. It binds through `VIRTIO_DEVICE_PROTOCOL`, which `DoryPlatformDxe` already provides for virtio-mmio slots, and publishes GOP → `ConSplitter` gives a graphical console. Verify the guest scanout path accepts the 2D `RESOURCE_CREATE_2D`/`SET_SCANOUT`/`TRANSFER_TO_HOST_2D`/`RESOURCE_FLUSH` sequence when no renderer context exists (VirtioGPU.swift handles 2D resources; qualify it with the firmware).
2. Keyboard: EDK2 has no virtio-input driver. Options: (a) write `DoryVirtioInputDxe` (small: one virtqueue, translate `EV_KEY` to `EFI_SIMPLE_TEXT_INPUT_EX`), or (b) add xHCI + USB HID to the ARM board (§2.5) and reuse `XhciDxe/UsbKbDxe`. (a) is ~600 lines and keeps the board simple; (b) also unlocks USB passthrough for generic guests.
3. Add a compatibility gate that captures the GRUB menu framebuffer and injects a key through the display path, not the serial socket.

### 2.3 Unhandled guest faults crash the whole VM instead of faulting the guest — **P1**

`Machine.swift:1099-1103` throws `unexpectedExit("guest touched unmapped pa …")` on a data abort outside any device; `1093-1097` throws when ISV=0 (no syndrome info); `1044-1048` crashes on any exception class not in the 5-entry `ExceptionClass` enum. Each of these tears down the machine.

Impact: a guest driver probing a reserved range (e.g. the PCIe ECAM/MMIO reservations at `0x1000_0000`/`0x4000_0000` that are advertised as reserved but have no owner), a `ldp/stp`/atomic to MMIO (ISV=0), or an FP/SVE trap the framework surfaces will kill the VM. Real hardware raises SError/synchronous external abort; the guest usually survives.

Fix: (1) inject a synchronous external data abort (EC=0x24 to EL1 with ESR DFSC=0b010000) using the same mechanism as `injectUndefinedInstruction`; (2) for ISV=0 decode the instruction at PC from guest memory for the common `ldp/stp/ldxr/stxr/ldadd` forms (or return RAZ/WI and log); (3) add `ExceptionClass` cases for `0x07` (FP/SIMD access), `0x0e` (illegal state), `0x1c` (BTI), `0x3c` (BRK) and inject to the guest rather than crash.

### 2.4 `restorePage` livelock on a mapped page — **P1 (latent)**

`GuestMemory.swift:245-247` returns `true` for a page already `.mapped`, and `Machine.swift:1091` treats `true` as "handled, retry". The header comment on `restoreIfReleasedRAM` (Machine.swift:1237-1240) says the opposite ("returns false … falls through to the crash path"). If Hypervisor.framework ever reports a stage-2 fault inside RAM for a page that is mapped (permission, alignment on device memory, or a framework bug), the vCPU spins re-executing the faulting instruction forever. Stop still works, but the guest hangs with no diagnostic.

Fix: return a tri-state from `restorePage` (`restored` / `alreadyMapped` / `notTracked`); on `alreadyMapped` count retries per (vCPU, PA) and escalate to §2.3's guest fault injection after N (e.g. 16) consecutive refaults.

### 2.5 Board has no PCIe, xHCI or USB; USB passthrough is USB/IP over vsock — **P2**

`DoryARMVirtV1ABI` reserves ECAM/MMIO but nothing owns them; all devices are virtio-mmio (32 slots, `virtioSlotBytes = 0x200`). Consequences: no MSI/MSI-X (every device IRQ is a level SPI through `hv_gic_set_spi`, more exits for multiqueue net/blk), no xHCI, so USB passthrough (`DoryHV/Usb/*`) needs the guest-side `usbip` modules and Dory's agent — it does not work for a stock installer or before the agent starts. Parallels/UTM present real PCIe + xHCI.

Fix: implement a `dory.armvirt@2` board: generic PCIe host bridge (ECAM at the reserved base, `pci-host-ecam-generic` in the DT), move virtio devices to virtio-pci (reuse `DoryMachinePC/DoryPCVirtioPCI.swift`'s transport — it is already transport-neutral), add xHCI (reuse `DoryPCXHCI.swift`), and route MSIs via GICv3 ITS if `hv_gic` exposes it (if not, use legacy INTx through the GIC). Keep `@1` for existing definitions per P2-01 item 6.

### 2.6 Smaller ARM correctness items — **P2/P3**

- `ARMSystemRegisterTrap.swift:109-117`: `ID_AA64DFR0_EL1` is forced to **0**. `DebugVer=0b0000` is a *reserved* encoding (minimum architected value is 0b0110). Linux copes, but it's not architectural. Set `DebugVer=0x6`, `BRPs=1`, `WRPs=1` (field+1 = two each, the architectural minimum) and keep `PMUVer=0`, `TraceVer=0`; the DBGB*/DBGW* RAZ/WI traps you already have then match.
- `Machine.swift:1151-1153`: `CPU_OFF` on CPU0 returns `-1` (NOT_SUPPORTED); the comment says DENIED (`-3`). Linux prints "unable to power off CPU0" and spins; harmless but wrong code.
- `Machine.swift:1065-1069`: **all** HVC calls return NOT_SUPPORTED, including `SMCCC_VERSION` (0x8000_0000) and `SMCCC_ARCH_FEATURES`. Implement SMCCC 1.1 (`VERSION`, `ARCH_FEATURES`, `ARCH_WORKAROUND_1/2/3` → NOT_REQUIRED, `ARCH_SOC_ID`) so the guest kernel stops probing and so the TRNG SMCCC interface can be offered later.
- `Machine.swift:1008-1011`: on `HV_EXIT_REASON_VTIMER_ACTIVATED` the vtimer is unmasked immediately. With `hv_gic` this is probably correct, but measure exit rate under a 1 kHz `CNTV` load; if it storms, defer the unmask until the GIC reports INTID 27 no longer pending.
- PSCI `CPU_SUSPEND` is NOT_SUPPORTED (documented, fine). Linux falls back to WFI; `hv_vcpu_run` blocks. Acceptable; measure idle host CPU with 4–8 idle vCPUs.
- No `CNTVOFF` management: the guest counter equals the host counter. Fine for run/pause; **required** before saved-state restore (guest time must not jump backward).
- `Machine.swift:499-509` documents that there is **no dirty tracking**; live snapshot/suspend for Linux is therefore not implementable yet. Parallels/UTM both suspend Linux VMs. Plan: stage-2 write-protect + fault-collect (`hv_vm_protect` per 16 KiB granule), plus DMA/renderer writer logging as the comment enumerates.

---

## 3. Linux x86_64 — DoryDBTX86 + DoryMachinePC (`dory-core-swift/Sources/…`)

### 3.1 Throughput is 2–3 orders of magnitude short of usable — **P0**

Retained numbers (all from your own receipts):

| Receipt | Work | Wall | Rate |
|---|---|---|---|
| `a05-tier1-2026-09-12/pvh-tier1-direct-chain-acceptance.json` (Alpine PVH, 512 MiB, release runner) | 733.6 M retired | 231.7 s | **3.2 MIPS** |
| `p06-pc-2026-09-06/tier-comparison-rpcdiag.json` optimizing tier, UEFI+GRUB+Linux to agent bind-ready | 17.0 G | 3901 s | **4.4 MIPS**; `/bin/true` RPC 218 s |
| `review-2026-09-12/pc-current-stable-release.json.gz` firmware to `DORY-PC-UEFI-BOOT` marker | 57.7 M | ≤180 s | firmware only |
| `review-2026-09-12/candidate-campaign-launch.json` (installer ISO, 2 vCPU/4 GiB) | 374 M | bounded stop | "no GRUB, kernel, root-mount or init serial milestone was observed" |

Reference points: QEMU TCG on Apple Silicon sustains roughly 200–500 MIPS and boots Ubuntu x86_64 in a few minutes; a modern distro boot retires 20–60 G instructions; a desktop session needs ≥1,000 MIPS to feel usable. At 3–5 MIPS a Ubuntu boot is ≈1–3 hours and a browser is unusable. The plan (2.5–2.11) says "profile before redesigning"; the numbers say the *shape* of the engine is the problem, not tuning:

1. **Instruction-budgeted, host-orchestrated execution.** `DoryPCDirectKernelMachine.swift:1381-1472`: the machine loop hands each vCPU a `maximumInstructions` slice via `workers[processor].perform { … }` (a synchronous hop to a worker thread and back), then re-enters Swift to advance clocks, deliver interrupts and pick the next vCPU. Every slice pays two thread handoffs plus Swift-side bookkeeping. The "parallel" path (`prepareParallelInstructions`, line 1386) executes **one instruction per vCPU per batch**, which is slower than serial.
2. **Checked-callback memory writes.** Production selects `jitWriteCoherencePolicy = .checkedCallbacks` (`x86-stable-production-selection.json`); every generated store leaves JIT code into a C callback (`dory_jit_memory_write_function`, `DoryJITRuntimeC.h:186`) because the protected-host-page experiment regressed (`firstBadRevision 81ad3f00f`). Stores are ~30% of x86 instructions.
3. **Global mutex around every locked instruction.** `DoryJITRuntimeC.c:36, 887-892`: `dory_jit_atomic_lock()` takes `pthread_mutex_t dory_jit_atomic_mutex` on every `LOCK CMPXCHG/XADD/…` *in addition to* the native `__atomic_*`. The CASPAL fix is good; the mutex around it is dead weight and will serialize SMP.
4. **Interpreter fallbacks in hot kernel paths.** The stable receipt's `negativeCacheHotSites` show `interpreterHelper` declines for `fxsave/fxrstor` (`0fae0e`), `in al,dx` (`ec`), `movdqu` (`f3440f6f…`), `lidt` (`0f010c24`) and `div` (`48f774…`). Every context switch and every I/O port access drops to the interpreter.
5. **Chaining barely links.** `chainTargetAccepts 3932 / attempts 116323` (3.4 %); `chainTargetCompilerABIRejections 43993`, `RestartableWriterRejections 47673`. Most blocks return to the dispatcher. Lazy flags (`DoryARM64LazyFlags.swift`) are fine; 169 k materializations in a firmware boot is acceptable.

What "fast enough" requires (this is the muscle-work, in dependency order):
- **a. Free-running vCPU threads.** Each vCPU thread owns its state, TLB, code-cache cursor and runs `dory_jit_region_execute` in a loop with *no* per-slice return to Swift. Interrupts/time are polled via a per-vCPU `pending_work` byte that devices set (you already have `dory_jit_pending_work_*`). The machine object becomes a device/interrupt authority, not a scheduler. This also removes the `perform` hops.
- **b. Inline fast-path loads/stores.** Emit a software-TLB lookup + direct `ldr/str` to host memory for RAM hits (`DoryX86JITTLB.swift` exists — make it the default, not `checked-callbacks`). SMC/protected-page coherence: keep the *protected host pages* design but fix the `81ad3f00f` regression (fetch touched unmapped `0xfffffe8f` for 5 bytes → the invalidation missed the 16 KiB host-granule alias for code straddling a 4 KiB guest page boundary; plan §2.6 item 6 names exactly this).
- **c. Register allocation across a block** (guest GPRs in ARM64 callee-saved regs for the block's lifetime; spill at exits). Today each IR statement loads/stores the vCPU context.
- **d. Direct/indirect chaining that actually links** — the ABI rejections above mean Tier1 blocks cannot call each other because of mismatched entry conventions; unify on one internal ABI (plan 2.9 item 5).
- **e. Drop the atomic mutex** for aligned natural-width ops; keep it only for the split/unaligned fallback.
- **f. Lower the hot fallbacks**: `fxsave/fxrstor`, `in/out`, `lidt/lgdt`, `div/idiv`, `movdqu/movdqa/pxor/por/pand` (SSE2 moves are trivially NEON).
- Target: ≥300 MIPS single-vCPU on M2 before enabling SMP; measure with the existing `dory-x86-generation-benchmark` and `pvh-*` fixtures. Below ~100 MIPS the x86 tier should stay hidden behind the qualification flag it already has (§3.5).

### 3.2 CPU profile is x86-64-v1 (SSE2 only) — **P0 for distro coverage**

`DoryX86CPUProfile.swift:216-227` (`compatibleV1`) advertises x87/MMX/SSE/SSE2/CX8/CX16/LM/NX/SYSCALL/LAHF and nothing newer; `137-140` strips SSE3…AVX2, XSAVE, F16C, FMA, BMI, LZCNT (and `.popcnt` is not in v1 at all); `PAT` is absent; RDRAND/RDSEED are #UD.

Consequences:
- **Won't boot/run**: RHEL 9 / Alma 9 / Rocky 9 / CentOS Stream 9 (x86-64-v2 baseline: SSE4.2, SSSE3, POPCNT), RHEL 10 (v3: AVX2), openSUSE Tumbleweed (v2 since 2024-Q4). Chrome/Chromium (SSE3 required), most Electron apps, Node ≥ 16 builds, anything compiled `-march=x86-64-v2/v3`, many Docker images with SSE4-tuned wheels.
- **Slow**: no PAT → Linux disables PAT, `ioremap_wc` becomes UC → GPU framebuffer writes crawl.
- **Entropy**: no RDRAND; confirm `DoryPCVirtioEntropyPCI` is attached in the production PC composition, otherwise `getrandom()` blocks early boot.

Fix: implement and independently vector-test (plan 2.4) then advertise, in this order: `POPCNT`, `SSE3`, `SSSE3`, `SSE4.1`, `SSE4.2`+`CRC32`, `PAT` (with real memory-type modelling or at least honouring WC as WB), `XSAVE/XRSTOR/XGETBV/XSETBV` with XCR0 = x87|SSE, `MOVBE`, `LZCNT/BMI1/BMI2`, `F16C/FMA/AVX/AVX2` (NEON has no 256-bit vectors: lower YMM as two 128-bit ops; VEX.128 zero-upper vs legacy-SSE preserve-upper per plan 2.12), `AES-NI/PCLMULQDQ/SHA` (NEON has native AESE/AESMC, PMULL, SHA1/SHA256 → these are cheap once decoded), `RDRAND/RDSEED` backed by `SecRandomCopyBytes`/`arc4random_buf` with CF semantics. Publish `dory.x86_64.v2` and `v3` profiles; keep `compat-v1` for existing definitions.

### 3.3 vCPUs execute serially — **P1**

`DoryPCDirectKernelMachine.swift:629, 1403, 2325-2329` (`roundRobinCursor`). A 4-vCPU x86 VM is a 1-vCPU VM with more context-switch overhead. The plan's 2.10 covers this; it depends on §3.1(a).

### 3.4 Deadlock: virtio-vsock PCI TX processing re-enters the transport lock — **P1 (reproduced)**

Running the engine suite serially (`swift test --no-parallel` in `Packages/ContainerizationEngine`) hangs forever in `DoryPCVirtioVsockPCITests.guestRequestCrossesPCIQueuesAndPublishesResponse()`. Stack (sampled):

```
DoryPCVirtioPCITransport.drain(queue: 1)                       DoryPCVirtioPCI.swift:410
  deviceState.withLockedSnapshot                               DoryVirtioDevice.swift:163   <-- holds mutex
    processor(1, chain, memory)                                DoryPCVirtioVsockPCI.swift:92
      VirtioVsock.consumeTransportNeutralGuestPacket           VirtioVsock.swift:631
        VirtioVsock.flushIfAttached                            VirtioVsock.swift:1178
          receiveReadySink -> transport.processQueue(0)        DoryPCVirtioVsockPCI.swift:56-59
            DoryPCVirtioPCITransport.drain(queue: 0)           DoryPCVirtioPCI.swift:410
              deviceState.withLockedSnapshot                   DoryVirtioDevice.swift:161   <-- same non-recursive mutex
                _pthread_mutex_firstfit_lock_slow              (hang)
```

`processingLocks` are per-queue, but `deviceState` is shared across queues. A guest whose vsock TX packet produces an immediate RX (connection response, credit update) deadlocks the vCPU thread. On x86 the agent, port-forwarding, clipboard and camera all ride vsock, so the first guest→host connection can hang the VM.

Fix: in `DoryPCVirtioPCITransport.drain`, copy the snapshot fields needed (`negotiatedFeatures`, `isOperational`, `lifecycleEpoch`) **before** entering the processing loop and release `deviceState`'s lock while calling `processor`; re-validate epoch on completion (you already have `terminalEpoch` for that). Alternatively make `receiveReadySink` defer to the pending-work path (`transport.requestProcess(0)` sets a flag consumed after the current drain returns). Add the serial test run to CI (§6.3).

### 3.5 x86 is gated off in the shipped app — **note**

`MachineManager.swift:15585-15593`: x86_64 requires `allowsQualificationBootstrapLaunches && bootMode == .efi && displayMode == .desktop`, otherwise "x86_64 Linux is available only in an explicit Apple-silicon DoryPC qualification build". The UI (`NewMachineSheet.swift:54-80`) offers "Linux x86_64" regardless, so a user in a normal build selects it and gets a persistence error. Either hide the tile when the daemon capability doesn't include x86 (there is a capability model — `DoryVirtualMachineCapabilities.swift`) or show it disabled with the reason.

### 3.6 Smaller x86 items — **P2**

- `DoryX86CPUProfile.swift:226`: `virtualTSCFrequencyHz = 1 GHz` and CPUID leaves 0x15/0x16 are unimplemented, so Linux calibrates TSC against PIT/HPET; fine, but advertise `invariantTSC` once host-monotonic clock sync (`synchronizeHostClock`) is the only production clock source — it is (`clockSource: host-monotonic` in the stable receipt).
- No x2APIC, no TSC-deadline timer → Linux uses LAPIC one-shot + `hpet`/`acpi_pm` clocksource; both are emulated in Swift per tick. Add TSC-deadline (trivial once TSC is host-time) to cut timer exits.
- `Firmware/DoryPC/abi.txt` drifted from `DoryPCV1ABI.markdown` (§6.2).

---

## 4. macOS ARM64 — DoryVZMacCore / DoryVMMKit / dory-vmm

Overall: correct use of Virtualization.framework; install journal, saved-state receipts and lease handling are careful. Gaps are product-level.

### 4.1 Fixed single 1920×1080@144 display — **P1**

`DoryVZMacConfigurationBuilder.swift:276-283`: one `VZMacGraphicsDisplayConfiguration(1920, 1080, 144)`. The view has `automaticallyReconfiguresDisplay = true` (`DoryVZMacAdapter.swift:144`) so the guest follows window size once macOS's display driver is up, but: no user-selectable initial resolution/scale (Retina users get 144 ppi regardless of host), **no multiple displays** (`VZMacGraphicsDeviceConfiguration.displays` supports several), and the fingerprint (`fingerprint()` line 187) hard-codes the string so any change invalidates saved states.

Fix: persist `displays: [{width,height,ppi}]` in the machine definition; derive the initial config from the host screen (`NSScreen.main.backingScaleFactor`), allow N displays, include the display list in `configurationSHA256` **only** through a versioned schema bump (`dory.vzmac-configuration@4`).

### 4.2 Networking is NAT or nothing — **P1 (competitive)**

`DoryVZMacConfigurationBuilder.swift:307-318` and `MachineManager.swift:15654-15664` reject `bridged`/`isolated` for VZMac. Bridged requires the restricted `com.apple.vm.networking` entitlement (Apple grants it to VM vendors — apply). Host-only/isolated can be done today with `VZFileHandleNetworkDeviceAttachment` + a user-space switch: `DoryVMMGVProxyNetwork.swift` already exists for Linux — wire the same gvproxy datapath to the Mac device so port-forwards, static leases and host-only mode behave identically across guest families.

### 4.3 Shared folders exist in the builder but admission rejects user shares — **P1**

Builder: `DoryVZMacConfigurationBuilder.swift:341-357` (multiple-directory share with `macOSGuestAutomountTag`). Daemon: `MachineManager.swift:15665-15669` requires `devices.directorySharing == !shares.isEmpty`, and per PLAN 1.1 "production user-share authority is not wired through the adapter; policy explicitly rejects it". Connect the validated `DoryMachineShareConfiguration` list into `--share` for `dory-vmm` (the argument parser already accepts `--share`, `DoryVMM.swift:258`) and remove the rejection.

### 4.4 Saved-state restore has no host-build preflight and hashes the whole state — **P2**

`DoryVZMacSavedState.swift:128-146`: restore checks host UUID, hardware model, machine identifier, configuration SHA and then **SHA-256s the entire `machine-state.bin`** (≈ RAM size; 8 GiB ≈ 5–8 s on M2 before the VM even starts resuming). It records `hostBuildVersion` but does not compare it; VZ saved states are only restorable on the same macOS build, so after a host update the user gets an opaque VZ error late.

Fix: compare `hostBuildVersion` (and `hostOperatingSystemVersion`) first and offer "discard saved state and cold boot" as a typed error; replace whole-file SHA with size + a sampled digest (first/last 4 MiB + 64 random 1 MiB windows keyed by the receipt) or rely on VZ's own integrity check.

### 4.5 Other macOS items — **P2/P3**

- `DoryVZMacConfigurationBuilder.swift:262-273`: only one extra disk (USB mass storage); no second virtio-blk data disk, no disk resize path for the Mac bundle.
- Camera bridge is a Dory system extension in the guest (`GuestTools/DoryGuestTools` — 723 lines: camera + Metal probe). There is no Dory guest agent for macOS (no host→guest command channel, no drag-and-drop, no display-scale hints, no graceful-shutdown request beyond `requestStop`). Parallels Tools does all of these.
- `MachineManager.swift:3140-3149`: macOS creation is stamped `experimentalAuthorization`. Decide whether macOS ships as "preview" and surface that tier in the UI.

---

## 5. Cross-cutting device correctness

### 5.1 `VIRTIO_BLK_T_FLUSH` → `fsync()` (not `F_FULLFSYNC`) — **P1 (data integrity)**

`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift:282`: `synchronize: { descriptor in Darwin.fsync(descriptor) }`. On macOS `fsync` only pushes data to the drive; it does **not** force the drive cache to stable media. The guest's journaling filesystem treats FLUSH as a durability barrier; a host power loss/kernel panic can corrupt ext4/btrfs journals. `PristineRootfs.swift:71` already uses `F_FULLFSYNC` correctly. Same check applies to `DoryVirtioFileBlockStorage` on the PC side.

Fix: `fcntl(fd, F_FULLFSYNC)` for FLUSH, with a per-machine "fast writeback (unsafe)" option like Parallels/UTM offer. Keep the 250 ms slow-flush telemetry.

### 5.2 Raw disks only; no QCOW2/VMDK/VHDX import — **P2**

No `qcow`/`vmdk` handling outside `HealthReporter.swift`. Users migrating from UTM/Parallels/VirtualBox have qcow2/hdd/vdi. Plan 2.3 item 7 says an owned bounded converter is acceptable; it is not started. Minimum: read-only qcow2 v2/v3 (no compression/encryption) → raw stream converter with L1/L2 bounds checks, run under the transfer-helper sandbox.

### 5.3 Linux snapshots are cold full copies — **P2**

`MachineManager.cloneSnapshot` (line 11282+) requires a stopped VM and copies rootfs/kernel/nvram (APFS `clonefile` is used — good, cheap). No live snapshot (needs §2.6 dirty tracking), no snapshot tree/branching UI, no memory state. Parallels has live snapshots; UTM has none for Apple Virtualization. Medium priority after §2.1.

### 5.4 Clock/RTC on ARM

PL031 is present (`PL031.swift`, DT node `pl031@…`). Confirm it is seeded from host time at boot and that guest RTC writes are ignored or persisted per policy — not verified in this pass.

---

## 6. Build and test health

### 6.1 dory-core-swift tests do not compile on Xcode 26 GM (Swift 6.4) — **P1**

With `xcode-select` pointing at `/Applications/Xcode.app` (Swift 6.4.0), `swift build --build-tests` fails:

```
Tests/DoryDBTX86Tests/DoryX86IRTests.swift:31:6: error: the compiler is unable to type-check this expression in reasonable time
```

The `#expect(block.instructionBoundaries == [ .init(...), .init(...), … ])` array-literal-of-implicit-member expression trips Swift 6.4's type checker. It compiles with Xcode-26.6.0-RC (Swift 6.3.3), which is what the receipts used. All 74 suites/493 tests in the filtered set pass there except §6.2.

Fix: `let expected: [DoryX86InstructionBoundary] = [...]` then `#expect(block.instructionBoundaries == expected)`; grep the DBT tests for the same pattern (12 files reported failure because the module failed). Pin the toolchain: add a `DEVELOPER_DIR`/Swift-version check to `scripts/build.sh` (it already discovers Xcode) and fail loudly on mismatch.

### 6.2 Committed failing test — **P3**

`DoryPCV1ABITests.checkedInABIProjectionMatchesSource` fails: `Firmware/DoryPC/abi.txt` was hand-edited in `26fe7ea52` (the smoke command was wrapped with `\` line continuations) and no longer equals `DoryPCV1ABI.markdown`. Regenerate the file from source (or make the markdown emit the wrapped form).

### 6.3 Engine tests are timing-sensitive and one hangs — **P1**

`Packages/ContainerizationEngine`: run in parallel while the machine was loaded, 45 tests failed on 1–5 s waits (VirtioNet, VirtioFS, Vsock, RendererWorkerBroker, FSWorkerBroker, UsbControl, RawHVSerialConsoleInput, GuestExecutionPauseCoordinator). Re-run serially, the same suites pass in 1.4 s — so those are load-flaky, not wrong. But the serial full run **never completes** because of §3.4. CI (`scripts/ci-test.sh`) should run this package with `--no-parallel` and a per-test timeout so a deadlock fails instead of hanging the job.

---

## 7. Architecture / maintainability

### 7.1 `MachineManager.swift` is 25,441 lines — **P2**

Plus `DockerTier.swift` 4,721, `DorydService.swift` 3,838. The VM control plane, container tier, migration, snapshots, macOS bundle handling, x86 gating and share policy all live in one class. Every guest-family fix above touches it. Split along the plan's own ownership table: `MachineLifecycle` (create/start/stop/journal), `MachineArchitectureAdmission` (§3.5 logic), `VZMacLaunchComposer`, `RawHVLaunchComposer`, `SnapshotService`, `ShareAuthority`. Mechanical extraction; no behaviour change; do it before the SMP/x86 work multiplies the surface.

### 7.2 Three virtio stacks

`DoryHV/Virtio*.swift` (ARM, virtio-mmio), `dory-core-swift/Sources/DoryVirtio` (semantic core), `DoryMachinePC/DoryPCVirtioPCI.swift` (PC transport) — plus `DoryPCVirtio{Vsock,FS}PCI` adapters in DoryHV bridging the two. The §3.4 deadlock is a direct product of this bridging. Finishing §2.5 (ARM on virtio-pci) lets ARM and PC share one transport and one adapter set.

### 7.3 Evidence-first culture is good; keep it honest

The receipts are precise about limits — keep that. Two places overstate: PLAN §1.1 row "Native ARM Linux … EDK2 boot exist" omits that the firmware is headless (§2.2); "Mac lifecycle … Share primitives exist" omits that admission rejects them (§4.3).

---

## 8. What is left to beat Parallels / Fusion / UTM

Ordered by user impact, with the concrete deliverable for each.

**Tier A — required for "install an ordinary distro and use it" (ARM64 Linux, macOS)**
1. Guest reboot/reset relaunch for ARM desktop (§2.1).
2. ARM UEFI: VirtioGpuDxe + keyboard driver (§2.2).
3. `F_FULLFSYNC` on FLUSH (§5.1).
4. Guest-fault injection instead of VM crash (§2.3, §2.4).
5. macOS: display config, user shares, host-build preflight (§4.1, §4.3, §4.4).
6. Test toolchain pin + CI serial run + fix §3.4/§6.1/§6.2.
7. Restore or formally remove `guest/` (§1.1) and get the desktop-rootfs producer back into the candidate inventory.

**Tier B — parity features**
8. Live suspend/resume and snapshots for Linux (dirty tracking §2.6; ARM first).
9. `dory.armvirt@2`: PCIe + virtio-pci + xHCI + USB passthrough without guest agent (§2.5).
10. Bridged and host-only networking for all families (§4.2); apply for `com.apple.vm.networking`.
11. qcow2/vmdk import (§5.2); disk resize; multiple data disks.
12. Multi-display, per-display scale, fullscreen/Spaces integration; dynamic resolution on ARM Linux via virtio-gpu EDID (check `VirtioGPU.swift` `scanoutCount` handling and `GET_EDID`).
13. Linux guest tools installer for *stock* distros (the agent exists in `dory-core/agent`; package it as `.deb`/`.rpm`/`.apk` with systemd units for clipboard, shares, resize, time sync) — today it only ships inside Dory's managed rootfs.
14. macOS guest agent (clipboard fallback, drag-drop, shutdown, display hints) beyond the camera extension.

**Tier C — x86_64 (the differentiator, and the biggest lift)**
15. Engine restructure to free-running vCPU threads + inline TLB'd memory + block register allocation + working chaining (§3.1 a–f). Gate: ≥300 MIPS single-vCPU on M2 on the Alpine PVH fixture; then SMP (§3.3).
16. CPU profile to x86-64-v2, then v3 (§3.2) with independent vectors (plan 2.4).
17. Only then: UEFI installer qualification for Ubuntu/Debian/Fedora x86_64, GPU (Venus) on PC, and unhiding the tile (§3.5).

If the x86 engine cannot reach ~10× today's rate within the next milestone, the honest product move is to ship ARM64 Linux + macOS as GA and x86_64 as "technology preview (slow)". Parallels no longer offers x86 guests on Apple Silicon at all, so a *working* x86 tier at even QEMU-TCG speed is already a differentiator; a 4 MIPS one is not.

---

## Appendix A — Commands used

```sh
# builds (both clean)
cd dory-core-swift && swift build                         # Xcode 26 GM, 54 s
cd Packages/ContainerizationEngine && swift build          # 57 s
# tests
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer \
  swift test --package-path dory-core-swift --filter 'DoryVZMacCoreTests|DoryFirmwareTests|DoryMachinePCTests|DoryVirtioTests|DoryNativeHVArm64Tests'
  # -> 493 tests / 74 suites, 1 failure (DoryPCV1ABITests.checkedInABIProjectionMatchesSource)
swift build --package-path dory-core-swift --build-tests    # Xcode 26 GM -> type-check timeout in DoryX86IRTests.swift:31
swift test --package-path Packages/ContainerizationEngine --no-parallel \
  --filter 'GuestExecutionPauseCoordinatorTests|VirtioMMIOTransportTests|VirtioNetTests|RawHVSerialConsoleInputTests|ARMPSCILifecycleTests|ARMVirtMachineContractTests'
  # -> 53 tests / 7 suites pass
swift test --package-path Packages/ContainerizationEngine --no-parallel
  # -> hangs in DoryPCVirtioVsockPCITests.guestRequestCrossesPCIQueuesAndPublishesResponse (deadlock, §3.4)
```

## Appendix B — Files referenced

- `Packages/ContainerizationEngine/Sources/DoryHV/{Machine,VCPU,GICv3MMIO,ARMSystemRegisterTrap,ARMPSCICPUState,GuestMemory,GuestExecutionPauseCoordinator,RawHVMachineRunner,VirtioBlk,DoryPCVirtioVsockPCI}.swift`
- `Packages/ContainerizationEngine/Sources/dory-hv/{DesktopMode,DoryPCMode}.swift`
- `dory-core-swift/Sources/DoryDBTX86/DoryX86CPUProfile.swift`, `DoryJITRuntimeC/DoryJITRuntimeC.c`
- `dory-core-swift/Sources/DoryMachinePC/{DoryPCDirectKernelMachine,DoryPCVirtioPCI}.swift`
- `dory-core-swift/Sources/DoryVZMacCore/{DoryVZMacConfigurationBuilder,DoryVZMacSavedState}.swift`
- `dory-core-swift/Sources/DoryVMMKit/{DoryVZMacAdapter,DoryVMM}.swift`
- `dory-core-swift/Sources/DorydKit/MachineManager.swift`
- `Firmware/DoryARMVirt/DoryARMVirtPkg/DoryARMVirt.fdf`, `Firmware/DoryPC/DoryPCPkg/DoryPC.fdf`, `Firmware/DoryPC/abi.txt`
- `Dory/Features/Sheets/NewMachineSheet.swift`
- Evidence: `docs/virtualization/evidence/{review-2026-09-12,a05-tier1-2026-09-12,p06-pc-2026-09-06,a03-gap-list-2026-09-12}`
