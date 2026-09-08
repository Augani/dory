# Dory: implementation plan to a qualified VM product

Updated 2026-09-08. Reviewed runtime baseline: `2dc5eae2e`, following `713473475`. This is the single active implementation plan. It replaces the duplicated phase checklists and historical progress journal; Git history retains those details.

**Required outcome:** macOS ARM64, Linux ARM64 and Linux x86_64 VMs on Apple Silicon Macs, usable through the shipped app and CLI, with validated GPU acceleration, recoverable data and qualified performance. **No guest cell is currently release-qualified.**

## Start here

1. Read **Scope**, **Current state** and **Working rules** before choosing work.
2. Pick one A00–A30 card from the delivery order. Its numbered steps are the assignable units; for example, `A13.4` means revoking PC Venus mappings safely.
3. Confirm the listed prerequisites and existing implementation. Assign an owner/reviewer and exact files in the issue or agent brief. A task is not permission to rewrite neighboring modules.
4. Perform the step's **Action**, understand its **Why**, then satisfy its **Check**. The check explains what evidence makes the implementation credible.
5. Commit focused changes, attach the standard receipt, and update the step in place. A merged implementation can still have an open physical qualification gate.
6. Continue to the next unblocked step. Do not append another progress journal or start another roadmap.

Navigation: [Scope](#scope) · [Current state](#current-state) · [Architecture](#architecture-and-ownership) · [Working rules](#working-rules-and-evidence) · [Delivery order](#delivery-order) · [Task cards](#implementation-cards) · [Budgets](#performance-and-reliability-contract) · [Cleanup](#retirement-inventory) · [Finish gates](#final-completion-gates).

## Scope

| Required cell | Execution owner to qualify | Required graphics | Required user outcome |
|---|---|---|---|
| Linux ARM64 | Existing Dory native Hypervisor.framework runtime, consolidated with DoryARMVirt | Guest OpenGL and Vulkan, worker-isolated host hardware execution | Fresh ordinary install, installed boot, updates, desktop/development work and recovery |
| Linux x86_64 | DoryDBT + DoryPC full-system translation | Guest OpenGL and Vulkan through the PC GPU transport | Same installed-OS outcome, complete declared CPU profiles and useful translated performance |
| macOS ARM64 | Existing Dory VZMac adapter and supported Apple Mac platform | Real guest Metal render and compute | Supported IPSW installation, persistent identity, daily Mac work, lifecycle and recovery |
| Existing containers | Preserve native ARM64 and FEX amd64 application execution | Hardware compute through standard Docker GPU requests | Default-mode compatibility, combined GPU/translation support, data safety and retained performance gates |

Apple Silicon is the only product host in this programme. macOS x86_64 and Intel-host support are excluded. A01 freezes the exact supported host OS/SoC/resource classes and guest versions; none are silently inferred from an SDK build or an old receipt.

### What complete x86_64 translation means

Finish a versioned **baseline full-system profile**, **x86-64-v2**, and **x86-64-v3/AVX2** profile. This includes every mandatory feature of the selected psABI levels, not merely a list of decoded instructions. Firmware/kernel-required real, protected, compatibility and long modes; supported 32-bit compatibility applications; precise faults; paging; x87/SIMD/XSTATE; interrupts; timers; and actual parallel vCPUs with x86 memory ordering are part of the contract.

A03 must inventory all mandatory forms and dependencies. Examples include SSE3–SSE4.2, POPCNT, XSAVE/OSXSAVE, AVX/AVX2, F16C/FMA, BMI1/BMI2, LZCNT and MOVBE; the pinned specification, not this illustrative list, determines completeness. Every advertised feature needs execution, saved-state and independent-reference evidence. Current safe feature masking remains until that evidence exists, but cannot permanently close a required feature task.

AVX-512/v4, AMX, nested VMX/SVM, SGX and vendor-specific facilities require a separate scope decision. Optional crypto/random facilities needed by selected applications need explicit implemented-or-unavailable decisions. Do not advertise “all x86 software” or universal native speed.

Full-system DBT boots the x86 Linux kernel. FEX translates amd64 applications within ARM Linux; it does not replace full-system DBT. Mac application translation is separate again and does not create an Intel macOS VM.

### What GPU acceleration means

For Linux, retain and qualify the existing **VirGL2 → ANGLE → Metal** and **Venus → MoltenVK → Metal** paths. ARM MMIO and PC PCI share semantic contracts. Hardware rendering requires guest API/device identity, correct shader/pixel/compute output, completed synchronization and actual Dory presentation. A worker process, API version string, framebuffer or host-only Metal success is insufficient. llvmpipe/lavapipe results cannot close hardware gates.

Mac uses the supported VZMac graphics path and must execute real guest Metal work. Preserve the current one-independent-guest-display limit until supported public APIs and physical tests justify changing it; moving a window to another monitor is not another guest display. Containers must use ordinary GPU requests and architecture-correct guest libraries, without diagnostic driver environment overrides.

Freeze stock versus managed Linux kernel/Mesa profiles separately. Resolve the existing 16 KiB GPU / 4 KiB FEX configuration conflict before claiming combined translated-container GPU support. Optional codecs, passthrough, camera/USB modes and compute APIs require their own admission and verification.

Live migration, portable host RAM/JIT state and renderer-state migration are outside the initial finish line. Cold snapshots, backup, clone/import/export and safe compatible local restore are required. Any advertised live save needs complete quiescence and recovery proof; otherwise it must be explicitly unavailable.

Normative starting points: [Intel manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), [x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI), [VirtIO 1.3](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html), [ARM64 Linux boot](https://www.kernel.org/doc/html/latest/arch/arm64/booting.html), [Mesa Venus](https://docs.mesa3d.org/drivers/venus.html), [Mesa Zink](https://docs.mesa3d.org/drivers/zink.html), [Apple Virtualization](https://developer.apple.com/documentation/virtualization), [Apple Hypervisor](https://developer.apple.com/documentation/hypervisor). Pin the actual revision/section used by each fixture. These are design references, not proof of Dory support. Zink remains an optional path, not a prerequisite for discarding working VirGL.

## Current state

“Implemented” below means source or bounded development evidence exists. It does not mean the production composition, every guest or a release candidate passes.

| Area | Preserve what exists | Still required |
|---|---|---|
| Launch authority | `713473475` removes the environment authentication bypass and keeps test injection internal; focused rejection tests pass. | Signed Release success/rejection and authentic physical GPU harness activation: A00/A27. |
| Harness quality | GPU harness has absolute campaign budgets, real readiness/output assertions, explicit opt-in skips and owned scratch cleanup. | Actual accelerated PC workload and signed production composition: A11/A14. |
| ARM production runtime | `DoryHV/Machine.swift` remains the execution owner; prior four-CPU direct-kernel/agent smoke exists. | Direct/UEFI parity, ordinary installers, GIC/PSCI completion, lifecycle/quiescence and owner consolidation: A18–A20. |
| ARM review | `2dc5eae2e` adds bounded probe deadlines, serialized handle teardown/mapping, narrowed register traps, DFR identity sanitization and corrected exception-entry state. | Guest-executed MRS/MSR/undefined handling, production Linux boot, IRQ/cancel races and minimum-host qualification: A18. |
| ARM probe evidence | Focused core run reports 17 tests, six live tests explicitly skipped; separate device suite runs six tests. Entitled smoke passes execution, deadlines, lifecycle checks and DFR readback. | This is 17 executed unit tests across the two runs plus a separate entitled smoke, not six passing opt-in live tests or a production OS campaign. |
| x86 machine/CPU | Checked PVH loader, conservative versioned profiles, interpreter/JIT checks, retained musl/glibc/systemd and bounded I/O successes. | Full baseline/v2/v3 inventory, precise semantics and independent x86 evidence: A03–A08. |
| x86 execution speed | Existing baseline and optimizing JITs and measured boot/RPC paths. | Useful boot/RPC latency, bounded JIT resources and true parallel TSO-correct SMP: A02/A09/A10. |
| PC GPU composition | `DoryPCMode` already creates renderer authority and has scanout/presentation/reset paths. | First verified production hardware frame, complete fence/blob semantics and PC Venus mappings: A11–A15. |
| ARM Linux graphics | Isolated VirGL/ANGLE and Venus/MoltenVK code, guest producers and pinned tuple exist. | Stock/managed synchronization, actual desktop matrix, sustained use and recovery: A12/A14/A15. |
| Container GPU | Development standard Docker request validates all 65,536 shader outputs; bounded idle-worker recovery preserves volume data. | Combined FEX/page-size solution, active-work recovery, Settings and sustained isolation: A16/A17. |
| FEX | Pinned translator and compatibility work exist. | Default Go asynchronous-preemption regression, full default-mode validation and safe promotion; `asyncpreemptoff` is not acceptance: A16. |
| Mac | Development desktop and 1,048,576-output guest Metal compute pass; private signed-helper lifecycle and installed-media transitions exist. | Actual installed daemon/catalog/app installation, post-restore work, atomic recovery, privacy and sustained Metal: A21/A22/A23. |
| Control transport | Shared bounded local control I/O, listener ownership, deadline and admission work exists. | Operation/generation binding and backend command cancellation; a client timeout does not cancel an operation: A18/A21/A26/A27. |
| Devices and integration | Block/network/vsock, guest tools, input/audio/USB and filesystem worker implementations exist at varying completeness. | Shared transport parity, actual policy enforcement and daily workloads: A20/A24/A25. |
| Storage and recovery | Mutation authority, journals, Mac bundle/recovery and snapshot infrastructure exist. | All advertised data operations, failure boundaries, second-host import and real restore drills: A23. |
| Build and release | Existing component producers, manifests, build/test and publication workflows. | Compatible FFI deployment targets, exact signed/notarized candidate and full matrix: A01/A27/A29/A30. |
| Local test storage | Previous cleanup reclaimed approximately 71.4 GiB before later builds; source, evidence, production data and representative fixtures were preserved. | Keep future campaigns bounded and disposable; reacquire deleted fixture payloads rather than treating absence as success. |

### Evidence worth reading first

- **Current ARM review:** [verification receipt](docs/virtualization/evidence/arm-review-2026-09-08/verification.json) and [entitled smoke output](docs/virtualization/evidence/arm-review-2026-09-08/entitled-smoke.jsonl). Latest reviewed 50 ms spin deadline returned in 54.1 ms; past deadline preserved PC `0x80000000`, future deadline allowed hypercall 42, and DFR0/1 read back zero. Build logs are path-redacted with original hashes retained.
- **Previous auth/harness review:** [verification](docs/virtualization/evidence/review-fixes-2026-09-08/verification.json). Source fixes and focused tests, not physical PC GPU qualification.
- **x86 latency:** [tier/RPC observations](docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json) and [clock rescope](docs/virtualization/evidence/p06-pc-2026-09-06/clock-stall-rescope.json). Historical optimizing bind-ready was 3,901 s versus baseline 3,361 s; optimizing RPC was 218.725 s. Better handshake time is not a boot speedup. Do not assign a speculative clock rewrite from a superseded diagnosis.
- **ARM installed-media transition:** [manager campaign](docs/virtualization/evidence/p05-arm-2026-09-05/actual-manager-desktop-installer-detach-cold-reopen.json). Existing Alpine disk, not a fresh general-purpose installation.
- **Mac lifecycle:** [managed suspend/restore](docs/virtualization/evidence/p07-macos-2026-09-05/actual-managed-suspend-restore.json) and [installed-media private campaign](docs/virtualization/evidence/p07-macos-2026-09-05/installed-media-physical-private.json). Real helper execution with private admission, not the release daemon/catalog.

Historical receipt bytes remain historical. Their local payloads may have been cleaned or may not exist on another checkout. A01 validates availability and candidate binding before reusing any result. Local cleanup reports are under `~/.dory/cleanup-reports/2026-09-08/`; they are not portable qualification fixtures.

## Architecture and ownership

```text
App / CLI: user intent and presentation
  → daemon: definitions, policy, admission, durable operations
    → immutable launch plan and explicitly granted resources
      → Linux ARM64: existing native HV owner + DoryARMVirt
      → Linux x86_64: DoryDBT + DoryPC
      → macOS ARM64: Dory VZMac adapter + Apple Mac platform

Linux machines → shared virtio semantics → MMIO / PCI transports
Device operations → isolated renderer / filesystem workers
Host integrations → narrowly granted network / audio / camera / USB brokers
```

The runner owns volatile execution/device state. The daemon owns policy and durable operations. A worker owns the resources and parsers it isolates. A child must not reinterpret an approved ISA, backend or graphics tier. Keep one durable definition, one resolved plan and one operation record; project UI/CLI state from those owners.

Reuse the working native runtime and existing Mac adapter. Consolidate duplicate devices incrementally after parity. Preserve the interpreter as a semantic reference, while independent x86 tests provide the external oracle. Keep Swift orchestration and existing C/Rust boundaries; a language rewrite requires a measured need. Start from raw sparse disks and transactional conversion for promised import formats.

Preserve isolation, peer identity, descriptor containment, generation/lease revocation, signed components, guest permissions, durable journals and meaningful negative tests. Reducing duplication must not remove these protections.

### Interfaces that need adjacent-owner review

| Boundary | Contract to preserve | Required proof |
|---|---|---|
| Media → resolver | ISA, format, digest, sizes, authority | Wrong or changed media rejects before mutable allocation. |
| Resolver → runner | Plan fingerprint, effective policy, versioned identities, grants | Runner executes exactly that plan or returns a typed error. |
| CPU → machine | Precise exit/state/address/width, restart token, cancellation/barrier | Faults/MMIO/interrupts preserve architectural state across tiers. |
| Machine → device | Checked physical DMA, generations, clock, IRQ sink | Reset/late completion cannot modify a newer machine. |
| GPU → worker → display | Immutable bounded commands, context/worker generation, fences, texture leases | Correct output precedes presentation; backing is not reused before retirement. |
| Tools → daemon | Machine/session identity, protocol, capabilities, observed readiness | Absent/unhealthy tools are distinguishable and cannot gain unrelated host access. |
| Runtime → persistence | Quiesced inventory, ABI/config/host constraints, hashes | Incomplete/incompatible state rejects before partial restore. |
| Qualification → release | Exact candidate/host/guest/profile, commands, raw results, verdicts | Missing or changed evidence cannot unlock capabilities. |

## Working rules and evidence

### Before changing code

- Verify `git status`, the task's current call sites and the actual production owner. Preserve unrelated work.
- Read relevant package manifests, test entrypoints and existing receipts. Identify which tests are pure, mocked, entitled or real-guest.
- Give each task an owner and adjacent reviewer. Reserve shared files such as `MachineManager.swift`, `DoryPCMode.swift`, `DoryX86Interpreter.swift`, `DoryARM64BaselineJIT.swift`, manifests and renderer wire contracts before concurrent edits.
- Split a large step into child issues (`A07.2a`, etc.) without changing its parent acceptance. Resolve shared ABI changes before another implementation depends on them.
- Missing hardware/media blocks the affected qualification, not independent implementation. Required CI jobs fail on absent fixtures; optional local jobs explicitly skip.

### Verification ladder

1. **Focused behavioral regression:** assert values, faults, state changes, resource effects or compatibility. Avoid source-spelling tests and tests that merely repeat implementation structure.
2. **Subsystem integration:** execute the real resolver/runner/device boundary with explicit substitutions labeled. Test failure paths and malformed input as well as success.
3. **Candidate-bound guest work:** rerun the affected kernel/application/lifecycle with immutable inputs and actual output checks. A parser test cannot close a boot requirement.
4. **Physical failure/recovery:** use owned fixtures for worker/process loss, reset, host changes and durable commit interruptions. CPU/DMA/JIT races require guest stress as well as supported sanitizer/fuzz tooling.
5. **Release qualification:** run the declared matrix and budgets on exact signed/notarized bytes. Private or development results remain supporting evidence.

A checkbox closes only when its specified check passes and the completion receipt is reviewed. Where a step has implementation and physical work, record `implementation merged; qualification open` and keep the box open. Failed, timed-out, missing and skipped results are separate states. Retries never erase failures.

### Standard completion receipt

Use existing evidence infrastructure under `docs/virtualization/evidence/`; do not invent another ledger package. Record:

- Task/step, owner, reviewer, source commit and any dirty patch; changed production entrypoints and retired path.
- Exact command, toolchain, dependency/build locks and fixture digests; live runs also include signed app/daemon/runner/worker, firmware, kernel/rootfs/Mesa/tools, host/guest versions and effective settings.
- Expected versus observed result, exit status, start/end/deadline, cancellation and cleanup outcome. Include raw outputs/checksums and bounded diagnostics.
- Test counts with skipped cases separated, negative cases, relevant guest rerun and limitations. Performance includes matched raw before/after samples and correctness.
- Artifact hashes, redaction description, candidate applicability, remaining gates and next unblocked step. Do not fabricate success JSON or overwrite historical evidence.

### Storage discipline for every campaign

1. Inventory live process/VM leases, owned fixture paths, allocated bytes and free-space floor before starting. Sparse logical size is not reclaimed physical space.
2. Use explicit disposable clones in a campaign-owned directory. Give disks, media downloads, renderer caches and build outputs a byte budget and owner.
3. Bound process trees, guest command duration and log size. Persist small logs/receipts outside scratch before cleanup.
4. Stop and confirm guest/helpers are gone before removing backing. If teardown cannot be confirmed, fail the campaign and retain the still-owned backing for recovery.
5. Remove only inactive owned scratch and reproducible obsolete outputs; preserve user VMs, originals, source, useful evidence and chosen reusable fixtures. Record before/after allocated bytes and reacquisition instructions.
6. Required fixture loss remains visible. Never silently substitute a different disk or treat an empty/skipped physical campaign as a pass.

### Verified local entrypoints

Public orchestration is `scripts/build.sh` and `scripts/test.sh`; inspect their current options and cleanup behavior before execution. The latter has `rust`, `gvproxy`, `swift`, `app`, `ui`, `build`, `all` modes. Large campaigns are separate from ordinary focused development checks.

The current review used the installed Xcode 26.6 Release Candidate toolchain. A01 must select and pin the supported build toolchain; a local RC is not a release support claim. These commands run focused checks, not whole-product qualification:

```sh
# Set DEVELOPER_DIR to the selected installed Xcode Contents/Developer directory.
xcrun swift test --package-path dory-core-swift --jobs 4 \
  --filter 'NativeHVArm64HostClockTests|NativeHVArm64EngineTests|ARM64ArchitecturalStateTests'
xcrun swift test --package-path Packages/ContainerizationEngine --jobs 4 \
  --filter 'ARMSystemRegisterTrapTests'
```

The native-HV tests gated by `DORY_RUN_NATIVE_HV_SMOKE` require an appropriately entitled executable. Default SwiftPM skips are not live passes. The reviewed standalone `dory-native-hv-smoke` was signed with `Config/DoryNativeHVSmoke.entitlements` and run under an external 30-second process deadline. It allocates a bare-metal test page, not a Linux VM disk.

For another subsystem, find actual suites with `rg` in the relevant `Tests` directory and verify the filter matches tests. Starting points include `DoryDBTX86Tests`, `DoryMachinePCTests`, `DoryVirtioTests`, `DoryVZMacCoreTests`, `DoryVZMacAdapterTests.swift` and `MachineManagerResolvedPlanIntegrationTests.swift`. Do not run an uninspected broad suite against active user storage.

## Delivery order

| Wave | Start here | Required handoff |
|---|---|---|
| 0: trustworthy foundation | A00 remaining signed-path checks; A01 candidate/fixtures/matrix | Trusted activation and reproducible inputs. |
| 1: diagnose and unblock | A02 x86 latency; A03 coverage; A18 native owner; A21 Mac lifecycle; A16 FEX | Measured CPU gaps, stable native/Mac paths and default-mode FEX reproducer. |
| 2: execution and devices | A04–A08 semantics/oracle; A12 shared GPU; A19 installers; A20 I/O | Correct CPU/device behavior and reproducible guest entrypoints. |
| 3: acceleration and throughput | A09 measured JIT; A10 SMP; A11 PC frame; A13 Venus; A14 desktops; A22 Metal | Verified hardware work and useful execution, with explicit per-cell limits. |
| 4: product and data | A15 graphics recovery; A17 container GPU; A23 storage; A24 network/shares; A25 tools; A26 app/CLI | Ordinary user journeys, effective policy and recoverable data. |
| 5: final qualification | A27 security; A28 retirement; A29 campaigns; A30 release | Exact candidate meets all required finish gates. |

A card’s final acceptance may consume results from work it unblocks. Dependencies therefore name the prerequisite steps where this matters: A03 inventory precedes CPU implementation, A03 profile promotion follows it; A02 measurement precedes A09 improvement; A30 candidate assembly precedes A29 qualification, but A30 publication follows it.

Waves communicate dependencies, not a requirement to pause independent work. A12 design/vectors can start with A01. A11 needs trusted activation and a reproducible x86 boot, not completed CPU performance optimization. ARM A14 can advance before PC A13. A17's combined exit requires A16 and the page-size solution. A23–A28 can integrate available cells early; their final gates wait for the relevant backend. A29/A30 cannot borrow missing evidence from another architecture.

Reserve a shared physical host for CPU/GPU benchmarks; overlapping campaigns invalidate matched comparisons. Do not estimate calendar completion from checkbox counts. The main unknowns are x86 semantic coverage/throughput, PC Venus memory coherence, stock-guest graphics synchronization and production recovery.

## Implementation cards

Task directory:

- **Foundation:** [A00 Authentication](#a00), [A01 Candidate and fixtures](#a01), [A02 x86 latency](#a02).
- **x86:** [A03 Coverage](#a03), [A04 Scalar](#a04), [A05 System semantics](#a05), [A06 FP/v2](#a06), [A07 XSTATE/v3](#a07), [A08 Independent oracle](#a08), [A09 JIT speed](#a09), [A10 Parallel SMP](#a10).
- **GPU/containers:** [A11 PC frame](#a11), [A12 Shared GPU](#a12), [A13 PC Venus](#a13), [A14 Linux desktops](#a14), [A15 Recovery/UI](#a15), [A16 FEX](#a16), [A17 Container GPU](#a17).
- **Operating systems:** [A18 Native ARM](#a18), [A19 Linux installation](#a19), [A20 Devices](#a20), [A21 Mac lifecycle](#a21), [A22 Mac policy/Metal](#a22).
- **Product:** [A23 Storage](#a23), [A24 Networks/shares](#a24), [A25 Tools](#a25), [A26 App/CLI](#a26), [A27 Security](#a27), [A28 Retirement](#a28).
- **Finish:** [A29 Campaigns](#a29), [A30 Release](#a30).

All cards are open at the product level. Only individually evidenced steps are checked. Each card has five primary steps; the cross-cutting budgets, container campaigns, retirement inventory and final gates below are part of its acceptance, not optional reading.

## Foundation and diagnosis

<a id="a00"></a>

### A00 — Remove production authentication bypass

**Owner/home:** runner launch authority; `Packages/ContainerizationEngine/Sources/dory-hv/main.swift`, `DorydKit/DoryApplicationLaunchHandoff.swift`, handoff integration tests.

**Dependencies:** none.

**Priority:** release blocker.

**Legacy coverage:** P13-02/03/12.

**Starting point:** Source removal and internal test seam are merged; signed Release qualification remains open.

#### A00.1 — Remove ambient authentication override

- [x] **Action:** Remove the runtime environment-controlled no-op authentication branch from every shipped runner entrypoint. Source fix and focused public-path rejection coverage: [review-fix receipt](docs/virtualization/evidence/review-fixes-2026-09-08/verification.json). Keep test injection in a nonshipping harness/test composition with explicit scope; restoring a comment saying “test-only” is insufficient.

**Why:** Local environment must never replace daemon identity.

**Check:** Invoke the public handoff path with the old variable present and a rejected peer; verify no launch payload is consumed. Retain the existing regression.

#### A00.2 — Contain the test seam

- [x] **Action:** Restore the smallest API visibility needed for authentication test seams. `receiveIfRequested(arguments:authenticateDaemon:)` is internal again; production entrypoint uses the validating public overload. Broader launch/renderer override and child-environment audit remains A27.

**Why:** A public injection API expands the shipping trust surface.

**Check:** Inspect exported API and production call sites; the only public overload authenticates and test injection remains internal.

#### A00.3 — Exercise signed rejection and success

- [ ] **Action:** Execute the packaged Release runner with the bypass variable set against a wrong-team/unsigned/wrong-identity handoff peer. Require rejection before consuming launch arguments or resource authority. Cover normal authenticated success as well as a missing/malformed peer.

**Why:** Debug tests cannot establish Release peer admission.

**Check:** On packaged binaries, capture wrong-team, unsigned, wrong-identity, malformed, absent and valid-peer outcomes; rejection precedes descriptor use.

**Status:** Logic-level rejection coverage merged — `testAbsentPeerConnectionFailsBeforeAnyDescriptorUse`, `testAuthenticationFailureLeavesTargetDescriptorsUninstalled` (wrong-team/wrong-identity/unsigned cases), `testValidPeerSuccessInstallsDescriptorsOnlyAfterAuthentication`, plus `DorydXPCSecurityTests` identity-rejection cases. The reproducible `scripts/qualify-signed-launch-handoff.py` harness now exercises a scoped Developer-ID-signed Release app with the legacy variable set: valid peer + granted descriptor succeeds; unsigned/wrong-identity peers receive neither token nor descriptor; absent and malformed invocations fail closed. Its wrong-team case is explicitly unavailable on the current host because every installed Apple signing identity has Dory’s team; it exits nonzero rather than claiming completion. See the [partial supporting receipt](docs/virtualization/evidence/wave0-2026-09-08/verification.json) and [renderer preview receipt](docs/virtualization/evidence/wave0-2026-09-08/renderer-preview-candidate.json). Neither is a release qualification, and physical GPU execution remains open.

#### A00.4 — Restore the physical GPU harness

- [ ] **Action:** Rebuild the real private GPU harness using valid scoped signing/peer identity; it may use fixture media/catalog data, but must not disable the production authentication boundary.

**Status:** `scripts/pc-gpu-daemon-live-gate.sh` now supplies an isolated, hardware-only DoryPC VirGL campaign through the signed app daemon. It rejects legacy or test-root component catalogs through the normal production catalog verifier before it can create a VM; it neither uses QEMU nor enables Docker, bootstrap activation, test roots, or testing validators. The first local admission run proved that boundary against the retained test-root catalog: the daemon returned `component catalog signature is invalid`, no machine-creation artifact was written, and its temporary launch service was removed; see [the negative-admission receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-gpu-daemon-test-root-rejection.json). The configured production endpoint was also inspected on 2026-09-08: it still serves schema-1 release `0.4.5`, with no `virtualMachineQualification`; [the catalog audit](docs/virtualization/evidence/wave0-2026-09-08/production-catalog-schema-audit.json) records the exact fetched bytes. This is intentionally not a GPU pass. The remaining input is a current schema-2 PC candidate whose catalog signature verifies under the production component root; that input is required before the gate can create the disposable VM, verify the hardware VirGL status, and run the guest command.

**Why:** A harness must exercise the same authority as the product.

**Check:** Launch through the legitimate signed daemon, confirm matching peer identity and granted FDs, then prove the intended guest command runs.

#### A00.5 — Close the authority gate

- [ ] **Action:** Retain behavioral evidence on the signed candidate and revalidate A11 after this change.

**Why:** Downstream graphics evidence depends on trusted activation.

**Check:** Attach exact signed binary hashes and negative results; rerun A11 on those bytes and get a security-boundary review.

**Card closes when:** changing environment variables cannot disable daemon authentication in shipped binaries.

<a id="a01"></a>

### A01 — Freeze source, artifacts, fixtures and qualification matrix

**Owner/home:** qualification/build; existing component manifests, firmware locks, renderer tuple and evidence scripts.

**Dependencies:** None for inventory/fixtures. Trusted production launch requires A00.1–A00.3; a development candidate does not wait for A00.5 GPU revalidation.

**Legacy coverage:** P00 follow-through, P13, P14-01.

**Starting point:** Producers and historical receipts exist; there is no coherent fully qualified release candidate. The FFI producer now rebuilds in a private target directory at macOS 14.0 and rejects any archive object above that floor; the current rebuilt archive contains 2,283 verified objects across arm64/x86_64. Candidate/release and physical matrix completion remain open.

#### A01.1 — Inventory every producer

- [x] **Action:** Inventory current app, daemon, FFI archive, runner, renderer, firmware, kernel, rootfs, Mesa and guest-tool producers; record source ownership and eliminate mixed-revision candidates. The 2026-09-08 focused builds warn that existing prebuilt FFI objects target macOS 27.0 while consumers target 14.0/15.0; rebuild/pin compatible FFI deployment targets and verify the oldest advertised host before release. Inspect ignored evidence with explicit paths: ordinary `rg --files` can omit these directories.

**Status:** `scripts/inventory-wave0-candidate.py` records the app, daemon, FFI, runner, renderer, PC firmware, both kernel profiles, desktop rootfs, both Mesa runtimes and guest tools with source-input and artifact hashes, plus ARM64 deployment targets for app binaries. Desktop rootfs admission validates each stamped fingerprint against the current producer inputs. Kernel admission invokes the exact profile verifier and rejects image presence without a package/toolchain receipt. `scripts/build.sh` seals each development app with a complete source snapshot and the inventory rejects a missing or stale binding; generated qualification receipts are intentionally excluded so recording evidence cannot invalidate the artifact it describes. The current Developer-ID-signed Release preview is captured in [the producer inventory](docs/virtualization/evidence/wave0-2026-09-08/candidate-producer-inventory.json) as `development-source-bound`, with no incomplete producer: the rebuilt ARM64 Venus kernel now verifies alongside the PC kernel/Mesa, current Debian/Ubuntu/Kali rootfs, FFI archive and renderer graph. Its preview-only, local Developer-ID evidence is not a release candidate, and oldest-advertised-host verification remains a release gate.

**Required cases:** Maintain one renderer lock manifest with validated/generated Swift, Python and guest-PINS consumers. Separate signed host artifact identity from guest ISA/kernel/driver requirements; source upgrades do not automatically change the wire ABI. Audit fork patches against upstream and retain a regression and owner for each required patch.

**Why:** Mixed build revisions make failures and passes irreproducible.

**Check:** Produce a manifest resolving every runtime file to source, build, digest and deployment target; incompatible FFI minimum-host metadata blocks admission.

**Producer progress (2026-09-08):** The shared VirGL2 Mesa producer now supports ARM64 (`arm-virgl2`) alongside x86_64 (`pc-virgl2`), with architecture-specific compiler, dependencies, artifact names, fingerprints, manifest checks, and ELF validation. Four architecture-selection tests pass, including rejection of substituted architecture/profile stamps. The real ARM64 build is in progress; neither its output nor graphics qualification is claimed yet. The changed producer fingerprint also requires an x86_64 rebuild before a fresh coherent candidate can qualify.

#### A01.2 — Validate historical evidence

- [x] **Action:** Validate critical historical receipt references, raw logs and candidate bindings. Label inaccessible local-only artifacts as unavailable; preserve historical JSON bytes and do not convert their summaries into new passes.

**Status:** `scripts/audit-plan-evidence.py` now audits the eight historical documents directly cited in “Evidence worth reading first” and retains a machine-readable classification in [the Wave 0 audit](docs/virtualization/evidence/wave0-2026-09-08/historical-evidence-audit.json). The ARM review, prior review fixes and private Mac lifecycle receipt retain matching local payload hashes; the ARM smoke JSONL parses. Four receipts remain explicitly incomplete: the private ARM manager has only machine-local artifact paths, both PC receipts lack portable raw attachments, and the Mac suspend/restore receipt lacks a portable test payload. They remain historical-only evidence and must be reacquired rather than promoted into a candidate pass.

**Why:** A summary is only as trustworthy as its retained inputs.

**Check:** Resolve each cited receipt and raw result, verify digests, and classify missing payloads as reacquisition work without editing old receipts.

#### A01.3 — Freeze the test matrix

- [ ] **Action:** Freeze an explicit matrix of host SoC/OS/build/resource class, Linux distro/version/ISA/kernel/Mesa/compositor, Mac restore/guest build, GPU profile and CPU profile. Select at least two Linux distro families per ISA; pin media digests and their publisher verification. Select final versions using current vendor support/API evidence.

**Status:** The proposed, fail-closed [Wave 0 qualification matrix](Config/DoryWave0QualificationMatrix.json) now identifies the exact required host class; CPU and graphics profiles; 4 KiB/16 KiB page-size split; resource classes and workloads; immutable ARM64/x86_64 Ubuntu 24.04.4 and Fedora 44 media cells; and the exact Mac restore image cell. It cross-references current vendor lifecycle/API material and checks the actual managed kernel/Mesa digests. `scripts/validate-wave0-qualification-matrix.py` rejects missing, duplicate or unpinned tuple inputs and public `scripts/release.sh` now requires its `--require-approved` mode. The status remains `proposed-review-required`: the release owner, runtime owner and security reviewer must approve the exact matrix digest before it can be frozen or authorize a public candidate.

**Validator review:** The validator now binds the candidate catalog bytes, enforces guest/profile architecture agreement and unique selections, and requires named review records for the exact content digest instead of accepting approval flags alone. Twelve tests pass. Current validation also exposes missing kernel and Mesa pins for `arm64-virgl2-angle-metal`; these must be supplied before matrix approval. The matrix remains a proposal, not a frozen qualification input; [review receipt](docs/virtualization/evidence/wave0-2026-09-08/tooling-review.json).

**Why:** Support must be finite enough to test completely.

**Check:** Reviewer approves host/guest versions, ISAs, CPU/GPU profiles, page sizes, resources and workloads; every required cell has immutable input identities.

#### A01.4 — Prepare owned fixtures

- [x] **Action:** Prepare disposable fixture copies and a documented acquisition path; record disk authority and cleanup ownership. Install/restore media requiring interactive setup remains a named prerequisite. Do not substitute an already-installed Alpine disk for a fresh general-purpose installer campaign.

**Status:** The recorded [fixture preflight](docs/virtualization/evidence/wave0-2026-09-08/owned-fixture-preflight.json) confirms 53,407,662,080 free bytes against a 12 GiB minimum and a new `.dory-build/wave0-fixtures` campaign path. A temporary Colima Docker engine rebuilt Debian, Ubuntu, and Kali ARM64 desktop rootfs inputs through `guest/desktop/build.sh`; each producer completed its offline verification, recorded a compressed digest, and now has a stamp matching its current inputs. Colima was removed and the original Docker context restored. The native [standalone offline-boot receipt](docs/virtualization/evidence/wave0-2026-09-08/native-runtime-offline-boot-full-runner/20260908T192256Z-54520/manifest.txt) then cloned an exact disposable Dory runtime, booted its bundled ARM64 kernel/rootfs on Dory's Hypervisor.framework runner under an isolated HOME with dead proxy settings, stopped it, hid the compressed sources, and booted again only from the prepared local cache. Both boots passed; the gate removed its disposable runtime clone and HOME on exit, and no user runtime/VM path was adopted. This is a development native-runtime fixture check, not GPU or release qualification.

**Why:** Qualification must neither reuse mutable unknown inputs nor endanger user disks.

**Check:** Rebuild one fixture from its acquisition instructions; verify its digest, exclusive ownership, free-space budget and successful disposable-copy cleanup.

#### A01.5 — Build a coherent candidate

- [ ] **Action:** Produce one source-bound development candidate, then a release-signing candidate when ready.

**Status:** A local Developer-ID-signed Release renderer preview now exists, with strict signature verification, exact ARM64/PC renderer-artifact binding and an embedded current development-source snapshot. The rebuilt ARM64 Venus producer now verifies with its package/toolchain receipts, and the current producer inventory has no incomplete entry. A second clean Xcode build on the same pinned toolchain reproduced the complete source snapshot and immutable FFI/kernel/Mesa/renderer-link inputs; its separately sealed artifact identities are retained in [the second-clean-build receipt](docs/virtualization/evidence/wave0-2026-09-08/second-clean-source-bound-build.json), rather than falsely treating timestamped Developer-ID outputs as byte-identical. After the physical DoryPC gate work, a fresh Developer-ID build resealed the current 2,216-entry source snapshot and exact ARM/PC renderer tuple; see [the current gate-preview receipt](docs/virtualization/evidence/wave0-2026-09-08/current-source-bound-gate-preview.json). This remains a source-bound development preview, not a release-signing candidate: the host and preview receipt mode prohibit promotion. Physical qualification, the approved matrix and the release-signing candidate remain open.

**Current-source update:** The retained previews above predate the current build/runtime repairs and cannot qualify current HEAD. `4ad8f7d58` preserves the precompile source identity; `e5b7e52b0` separates internal filesystem shares from home; `69cba2b7a` and `2d5456af8` seal final renderer resources; `49ec918f8` preserves the standalone signed runner bundle; `48c4c16b6` restores its LZFSE command; `0c3b616c0` includes the dataplane proxy; and `184ec118c` aligns Ubuntu production and verification. The [build-repair receipt](docs/virtualization/evidence/wave0-2026-09-08/build-repairs.json) records focused tests, component packaging and Ubuntu offline verification. A complete signed rebuild and fresh inventory remain required; A01.5 stays open.

**Revalidation:** The committed inventory now rejects incomplete app identity and desktop archives that do not match their build stamps. Its [current rerun](docs/virtualization/evidence/wave0-2026-09-08/current-candidate-inventory-after-repairs.json) admits the guest/FFI producer inputs but reports `incomplete` because the app source binding is stale. The [updated historical audit](docs/virtualization/evidence/wave0-2026-09-08/historical-evidence-audit-current.json) still requires reacquisition of four historical receipts; it does not promote their summaries.

**Why:** All later results need the same reproducible foundation.

**Check:** A second clean build reproduces inputs and expected outputs; receipt distinguishes development signing from the eventual release candidate.

**Card closes when:** another agent can reproduce the same launch inputs and distinguish mock, private fixture, development and release evidence.

<a id="a02"></a>

### A02 — Explain x86 boot and RPC latency before broad optimization

**Owner/home:** DBT performance and PC runner; `DoryPCDirectKernelMachine`, `DoryARM64BaselineJIT`, `DoryPCMode`, guest agent/vsock instrumentation.

**Dependencies:** A01 coherent candidate and fixture identity; no speculative clock rewrite.

**Legacy coverage:** P07-01/02, P14-02/09.

**Starting point:** Historical whole-boot/RPC timings are slow; clock-stall diagnosis was rescoped. Diagnose current bytes before optimizing.

#### A02.1 — Instrument the entire boot

- [ ] **Action:** Reproduce the retained UEFI/host-monotonic/optimizing-JIT boot on a single frozen candidate. Capture GRUB, kernel, root mount, init, agent copy, agent bind, handshake, request receipt, process start, process exit and response delivery as separate milestones.

**Why:** The current x86 delay is not explained by handshake timing.

**Check:** Timestamp firmware, kernel, init, agent bind and ready milestones using one host clock; every interval has a start, end or explicit timeout.

**Development progress (2026-09-08):** The UART now records bounded host-clock milestones before console-buffer loss; production execution publishes a separate observation identity for each machine generation. Six timeline/guest-port tests and five production reset lifecycle tests pass. The UEFI diagnostic supports capture-on/off comparison and an execution deadline that requests normal machine power-off. A two-second deadline test retained its unfinished boot as censored. Four matched 100-million-instruction firmware samples averaged 17.328 seconds with capture and 17.171 seconds without (0.92% difference), but each emitted only 33 terminal-control bytes and reached no GRUB marker. This does not establish whole-boot overhead or complete A02.1; agent/RPC milestones and a coherent-candidate boot remain outstanding. Raw outputs, identities and limitations are retained in [the development timing receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-boot-timeline/measurement.json).

**EFI control (2026-09-08):** With only `efi=debug` added and KASLR still enabled, the retained single-variable diagnostic reached root mount at 502.732 seconds and `/sbin/init` at 586.708 seconds. The strict 600-second deadline stopped it normally at 600.000127 seconds; agent readiness and RPC were not observed. This run avoided the earlier EFI panic without `nokaslr`, but does not establish its cause or a performance improvement. The separate `nokaslr`-only control remains in progress. [Raw logs and identity receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-boot-timeline/efi-debug-only/receipt.json).

#### A02.2 — Attribute execution cost

- [ ] **Action:** Measure host CPU samples, instructions/second by stage, native/fallback counts by instruction form, compilation/block lookup/page-walk/helper/device time, timer interrupts and runnable/idle time. Keep instrumentation bounded and measure its overhead.

**Why:** Optimizing the wrong hot path can slow overall boot.

**Check:** Retain bounded host samples and counters with sampling overhead; reconcile dominant CPU/helper/device time with measured wall time.

#### A02.3 — Separate RPC from execution

- [ ] **Action:** Separate a serial guest command from an agent RPC command on the same already-ready VM; test echo/ping and command execution independently to isolate transport scheduling from CPU execution and process creation.

**Why:** Transport, guest scheduling and process startup have different owners.

**Check:** On the same ready guest, compare serial command, protocol ping and command RPC; capture request receipt through response delivery.

#### A02.4 — Compare tiers fairly

- [ ] **Action:** Repeat baseline and optimizing tiers with the same disk state, resources, observer and timeout. Retain incomplete runs as censored/timeouts. Do not turn projected 765-second RPC time into an observed measurement or claim a boot win from handshake timing.

**Why:** Different disk state and timeouts invalidate speed claims.

**Check:** Run repeated matched baseline/optimizing samples; report boot and RPC separately, preserving unfinished runs as timeouts rather than estimates.

#### A02.5 — Choose the first optimization

- [ ] **Action:** Rank bottlenecks and assign minimized A09 changes. Keep long diagnostic deadlines distinct from product usability budgets; provide bounded user cancellation even during slow boot.

**Why:** A prioritized measured cause makes the next change reviewable.

**Check:** Identify the largest measured component, its owner and a bounded A09 change; demonstrate cancellation still works during the slow stage.

**Card closes when:** a reproducible latency breakdown identifies the measured dominant cause, an A09 optimization is assigned, and user cancellation remains bounded. A09 owns the subsequent improvement proof; A02 does not wait for it.

## Complete x86 architecture and execution

<a id="a03"></a>

### A03 — Build the authoritative instruction and feature coverage ledger

**Owner/home:** `DoryX86CPUProfile`, decoder/feature policy, `dory-x86-decode-audit`, vectors and independent-reference fixtures.

**Dependencies:** A01 for inventory. A03.1–A03.4 hand off gaps to A04–A08; A03.5 final promotion waits for their results, so downstream work must not wait for the whole card.

**Legacy coverage:** P02-10–20, P07.

**Starting point:** Conservative versioned CPU profiles exist. v2/v3 remain required future profiles, not currently qualified capabilities.

#### A03.1 — Enumerate the promised architecture

- [ ] **Action:** Enumerate required v1/v2/v3 feature bits and every encoding/operand/address-size/mode form, prefix legality and privileged state dependency. Include SSE3 through SSE4.2, POPCNT, XSAVE/OSXSAVE, AVX/AVX2, F16C/FMA, BMI1/BMI2, LZCNT and MOVBE in the v3 requirements audit; derive completeness from psABI rather than this illustrative list.

**Why:** Complete translation needs a finite inventory beyond instruction names.

**Check:** Pin psABI/manual revisions and enumerate every mandatory form and feature dependency for baseline, v2 and v3; reviewer identifies any missing family.

#### A03.2 — Separate implementation from proof

- [ ] **Action:** Extend the existing machine-readable support catalog with separate decoder, interpreter, baseline JIT, optimizing JIT, flags, exceptions, memory ordering and independent-reference evidence. Distinguish unsupported, implemented-unqualified and qualified; do not use source locations alone as execution proof.

**Why:** Decoding or finding a source anchor is not successful execution.

**Check:** Each catalog row has interpreter/JIT/state/fault status and links to executable vectors and independent evidence, or an explicit open gap.

**Development progress (2026-09-08):** Inventory report schema 3 now reports per-form architectural-state, memory-ordering and independent-reference gaps alongside the existing interpreter/JIT/flags/fault annotations. Retained retirement and fault observations leave every form unqualified. Fifteen audit tests pass, including serialized-gap checks after verified historical support is attached; see [test evidence](docs/virtualization/evidence/wave0-2026-09-08/isa-proof-dimensions-tests.log.gz). The architectural denominator, full form ledger and independent execution evidence remain incomplete.

#### A03.3 — Audit public feature state

- [ ] **Action:** Compare public CPUID leaves/subleaves, MSRs, XCR0 and feature dependencies to implemented state. Add round-trip persisted-profile compatibility and unsupported-instruction/#UD tests before enabling new profile bits.

**Why:** A guest may execute anything CPUID and XCR0 advertise.

**Check:** Compare guest-observed CPUID/MSRs/XCR0 against enabled code and state; invalid combinations trap and old persisted profiles retain their meaning.

**Status:** Partial implementation in `a7aecb1ef` and `2f05f941e` adds F16C/FMA/BMI1/BMI2/LZCNT/MOVBE identities and the v3 CPUID/control requirements to the existing profile policy. Public construction and persisted-profile decoding keep all new unqualified features masked. F16C/FMA require AVX state dependencies; integer features remain independent. Eighteen focused CPU/profile tests pass, including unchanged legacy profile round trips and rejection of semantic promotion from feature advertisement alone. This is a feature/state inventory, not the complete encoding/form ledger or guest execution qualification; A03.1–A03.5 stay open. See [focused verification](docs/virtualization/evidence/wave0-2026-09-08/wave1-foundation-verification.json).

#### A03.4 — Assign each gap

- [ ] **Action:** Generate a finite gap list assigning each form to A04–A08. Audit optional application-required crypto/CRC/random features explicitly; entropy must have real semantics, and unsupported feature probing must fail architecturally.

**Why:** Large architecture goals must become bounded implementation work.

**Check:** Every missing form belongs to A04–A08 with named expected outputs/faults; no required row is unowned or silently marked optional.

#### A03.5 — Freeze profile promotion rules

- [ ] **Action:** Freeze baseline/v2/v3 profile identifiers and upgrade rules.

**Why:** Feature growth changes compatibility and saved-state semantics.

**Check:** Reject promotion while mandatory rows lack evidence; test old-profile restore and unsupported-instruction behavior on the promoted candidate.

**Card closes when:** zero unknown forms in each advertised profile, with every required semantic/fault path linked to evidence; optional unimplemented features remain clearly unadvertised.

<a id="a04"></a>

### A04 — Finish scalar decode, flags, memory operands and restartability

**Owner/home:** decoder/interpreter/IR/JIT scalar instructions.

**Dependencies:** A03.1–A03.4 inventory and assigned scalar gaps. Do not wait for A03.5 final profile qualification; coordinate shared interpreter files.

**Legacy coverage:** P02-14.

**Starting point:** Interpreter and JIT scalar coverage exists; the complete form/fault inventory and independent qualification remain open.

#### A04.1 — Close decode boundaries

- [ ] **Action:** Validate prefix groups, REX/high-byte register rules, ModRM/SIB/displacements, RIP-relative and FS/GS addressing, signed immediates, 16/32/64-bit address wrapping and the 15-byte instruction limit.

**Why:** Prefix and addressing mistakes corrupt otherwise correct operations.

**Check:** Generate legal/illegal combinations around every byte boundary; assert decoded length or precise fault, including a cross-page 15-byte limit case.

#### A04.2 — Check scalar result and flags

- [ ] **Action:** Exhaust boundary cases for arithmetic, ADC/SBB, shifts/rotates including zero/oversized counts, bit scans/tests, multiply/divide including overflow, compare/exchange, conditional moves/sets and flag materialization. Mask undefined outputs in independent comparisons; preserve architecturally defined ones.

**Why:** Compilers depend on edge cases that simple arithmetic misses.

**Check:** Compare registers and defined flag bits against independent x86 vectors at zero, sign, carry, overflow and count boundaries in every tier.

#### A04.3 — Make faults restartable

- [ ] **Action:** Test read-modify-write operations with faults at each memory access, unaligned/cross-page operands, MMIO and page permissions. Faulting instructions cannot leak partial register/flag/store changes except where architecture specifies partial progress.

**Why:** A failed memory access must not partially commit an instruction.

**Check:** Place operands across protected pages and MMIO; assert fault address/RIP and unchanged state or only architecturally permitted progress before retry.

#### A04.4 — Finish REP semantics

- [ ] **Action:** Verify REP MOVS/STOS/CMPS/SCAS/LODS in both directions, zero counts, segment/address-size variants, overlap and interruption mid-string. Resume must retain exact RCX/RSI/RDI/flags and side effects.

**Why:** String operations may fault or be interrupted after partial progress.

**Check:** Interrupt each iteration boundary in forward/backward and overlapping copies; resumed memory and RCX/RSI/RDI/flags match the independent oracle.

#### A04.5 — Qualify scalar users

- [ ] **Action:** Run identical vectors under all tiers and actual compiler/libc workloads.

**Why:** Unit agreement does not establish working compiler and libc behavior.

**Check:** Run the same fixture under interpreter and both JITs, then compiler/libc workloads; attach outputs, checksums and any remaining coverage gaps.

**Card closes when:** all A03 scalar forms covered, precise faults preserved, no kernel-address-specific workaround.

<a id="a05"></a>

### A05 — Finish privileged execution, paging, interrupts and architectural time

**Owner/home:** architectural state, paging/interrupt code, PC clocks/APIC and firmware transitions.

**Dependencies:** A03.1–A03.4 system/feature inventory. Revisit A02 only when a demonstrated clock or execution defect affects its measurements.

**Legacy coverage:** P02-11–13, P04-08–10.

**Starting point:** PC firmware, paging and interrupt/timer implementations exist, including prior APIC/IOAPIC fixes. Full privileged qualification is open.

#### A05.1 — Validate mode and privilege transitions

- [ ] **Action:** Validate real→protected→long and compatibility transitions, descriptor caches/limits, GDT/LDT/IDT/TSS, CPL/IOPL, interrupt gates/IST stacks, IRET and syscall/sysenter return paths, including invalid descriptor and stack cases.

**Why:** Firmware and Linux rely on precise privilege boundaries.

**Check:** Exercise valid and invalid descriptors, gates, stacks and returns; independently verify target mode, saved state and fault priority.

#### A05.2 — Complete paging behavior

- [ ] **Action:** Cover page sizes/modes, canonicality, reserved/NX bits, WP, user/supervisor access, A/D updates, PAE latches, CR3/INVLPG and cross-page instruction fetch. Test page-table edits against both interpreter and cached translations.

**Why:** Stale translations or incorrect permissions defeat kernel isolation.

**Check:** Vary page sizes, CR3, NX/WP/U-S and A/D bits; edit live page tables and assert each tier sees correct fetch/data faults and invalidation.

#### A05.3 — Implement exception delivery

- [ ] **Action:** Implement exact exception priority, error codes, CR2 and fault RIP; test nested faults, double/triple fault, debug state, NMI blocking, interrupt shadow and restart after delivery. Validate exposed CR/MSR semantics rather than successful blanket no-ops.

**Why:** Incorrect saved RIP or nested faults can hide as random kernel hangs.

**Check:** Test error code, CR2, saved RIP, NMI/shadow and double/triple faults with handler memory markers and bounded reset observation.

#### A05.4 — Reconcile interrupt and clock devices

- [ ] **Action:** Exercise local/IO APIC priorities, EOI/remote-IRR, level interrupts, logical destinations, AP startup, PIT/HPET/RTC/PM timer wrap and clock calibration. Distinguish deterministic test time from production host-monotonic time; test suspend/resume and host sleep discontinuities.

**Required cases:** Include PIC/PIT and ACPI PM status/enable/control separation, W1C, SCI, sleep/reset, FADT flags and the 3.579545 MHz PM timer width/wrap. Test unsupported delivery modes explicitly. xAPIC logical mode has no independent CPUID feature bit to hide; implement it or require a specifically qualified temporary guest contract.

**Why:** Linux calibrates and schedules using several interacting sources.

**Check:** Check AP startup, logical routing, EOI, SCI/W1C and timer wrap with deterministic vectors, then repeat idle/sleep/resume against host-monotonic time.

#### A05.5 — Validate real kernels

- [ ] **Action:** Boot ordinary firmware and multiple Linux kernels through syscall, signal, process/thread and I/O stress.

**Why:** Privileged semantics must survive normal system activity.

**Check:** Boot pinned firmware and multiple kernels; run syscall, signal, process/thread and I/O stress without fixed-PC exceptions or unexplained retries.

**Card closes when:** required privileged feature/state inventory passes, with independent instruction checks and real kernel evidence. The old nonreproducible clock stall is not assumed to be the cause of future failures.

<a id="a06"></a>

### A06 — Finish floating point and v2 SIMD

**Owner/home:** x87/extended-float/environment, SIMD interpreter and lowerings.

**Dependencies:** A03.1–A03.4 inventory and the A04 operand/flag/fault primitives used by the selected forms. Independent vectors come from A08.1–A08.3.

**Legacy coverage:** P02-15/16.

**Starting point:** x87/SIMD implementations and tests exist; a complete independently qualified v2 profile is not established.

#### A06.1 — Finish x87 and MMX state

- [ ] **Action:** Qualify x87 80-bit state, stack tags, precision/rounding controls, NaNs/infinities/denormals, pending/unmasked exceptions, conversions and save/restore; test MMX aliasing and EMMS.

**Why:** ARM arithmetic is not automatically x87-compatible.

**Check:** Compare 80-bit values, tags, rounding and pending exceptions against physical x86; save/restore and MMX-to-x87 transitions preserve exact state.

#### A06.2 — Finish v2 vector forms

- [ ] **Action:** Complete SSE/SSE2 and v2-required SSE3/SSSE3/SSE4.1/SSE4.2 forms: lane selection, saturation, shuffle/immediates, comparisons, conversions, alignment and access faults. Include CRC/string-comparison variants as required by the profile.

**Why:** Missing lane or fault behavior breaks modern userspace dispatch.

**Check:** Cover each mandatory form and immediate with vector outputs, saturation, alignment and cross-page fault checks in every execution tier.

#### A06.3 — Isolate guest floating-point control

- [ ] **Action:** Preserve guest MXCSR and exception behavior independently of host floating-point state. Test host-thread migration and transitions between interpreted/native paths; do not infer equivalence from ARM floating-point defaults.

**Why:** Host FP settings must not leak into guest results.

**Check:** Change guest MXCSR around interpreter/JIT transitions and host threads; expected exceptions/results remain stable and host state is restored.

#### A06.4 — Use independent numeric workloads

- [ ] **Action:** Use independent physical-x86 reference outputs with defined tolerances only where the ISA allows them. Exercise numeric libraries, image processing, browser/media code and libc dispatch on the v2 candidate.

**Why:** Matching two implementations can preserve the same bug.

**Check:** Retain physical-x86 reference identity and permitted tolerance; run numerical, image, media and libc-dispatch workloads with verified output.

#### A06.5 — Promote v2 deliberately

- [ ] **Action:** Promote v2 CPUID only after all dependencies and state tests pass.

**Why:** Safe feature masking is temporary while required semantics are missing.

**Check:** Guest sees the complete frozen v2 profile only after all mandatory vectors and application gates pass; profile downgrade/restore behavior remains defined.

**Card closes when:** a qualified v2 profile, with no masked mandatory feature left as a permanent completion shortcut.

<a id="a07"></a>

### A07 — Implement XSTATE and the complete v3/AVX2 contract

**Owner/home:** CPU profile/state, decoder, interpreter, vector IR/JIT and snapshot format.

**Dependencies:** A03.1–A03.4 v3 inventory and relevant A06 SIMD/FP semantics. XSTATE design can start earlier; final v3 promotion requires A06 v2 qualification and A08 reference evidence. Snapshot owner reviews ABI.

**Legacy coverage:** P02-16, P07-02.

**Starting point:** v3/AVX2 and full XSTATE qualification are required work; do not enable missing profile bits ahead of semantics.

#### A07.1 — Specify XSTATE before AVX

- [ ] **Action:** Specify CPUID leaf 0xD, XSAVE-area layout/alignment/sizing, XGETBV/XSETBV validation, CR4.OSXSAVE/XCR0 enablement and fault behavior. Implement the advertised XSAVE/XRSTOR variants and initial/modified component semantics before enabling AVX.

**Why:** AVX correctness includes operating-system state management.

**Check:** Validate leaf 0xD, alignment, sizes, XCR0 dependencies, initial state and malformed XSAVE/XRSTOR areas against an independent reference.

#### A07.2 — Complete v3 execution forms

- [ ] **Action:** Implement all required VEX encodings, 128/256-bit operations, upper-lane zero/preserve rules, VZEROUPPER/VZEROALL, FMA rounding and F16C conversion behavior, plus required integer/bit-manipulation instructions. Add architectural state/feature cases currently missing from the profile model.

**Why:** AVX2 alone is not the entire v3 contract.

**Check:** A03 inventory reaches zero missing mandatory forms; compare 128/256-bit lanes, VEX zeroing, FMA/F16C rounding and integer extensions in all tiers.

#### A07.3 — Validate partial memory faults

- [ ] **Action:** Test masked memory/gather operations, partial/restartable faults where specified, cross-page operands and unsupported prefix/feature combinations. Lower 256-bit operations to appropriate ARM sequences without losing lane or exception semantics.

**Why:** Gather and masked accesses have special restart semantics.

**Check:** Use protected-page lane fixtures and illegal encodings; verify only permitted lanes commit, saved state is exact and restart completes correctly.

#### A07.4 — Preserve vector state everywhere

- [ ] **Action:** Preserve full vector state across guest context switches, signals, exceptions, JIT fallback, stop/resume and snapshot/restore. Stress applications that mix scalar, SSE and AVX code on many threads.

**Why:** Context switching and fallback can lose upper vector halves.

**Check:** Alternate scalar/SSE/AVX across signals, threads, interrupts, fallback and snapshots; compare full XSTATE before and after each boundary.

#### A07.5 — Promote the versioned v3 profile

- [ ] **Action:** Run independent reference vectors and v3-targeted real binaries, then enable the versioned profile.

**Why:** A wider enum or successful decode cannot establish compatibility.

**Check:** Run independently checked vectors and real v3-targeted binaries; all required state, faults and application gates pass on the advertised profile.

**Card closes when:** required v3 features are implemented and qualified end to end; AVX2 decode support or a widened enum alone cannot close this task.

<a id="a08"></a>

### A08 — Establish an independent x86 conformance service

**Owner/home:** existing `guest/diagnostics/p02-x86-reference` and support vectors.

**Dependencies:** A03.1–A03.2 inventory/schema. Build the oracle alongside A04–A07; do not wait for A03.5 profile promotion.

**Legacy coverage:** P02-20, Q01/02.

**Starting point:** Reference fixture infrastructure exists; complete independent physical-x86 coverage is not established.

#### A08.1 — Provision the independent oracle

- [ ] **Action:** Acquire a declared physical x86 reference with known CPUID/OS/toolchain. Separate user-mode vector execution from a controlled privileged test environment; do not execute privileged vectors in the ordinary host OS.

**Why:** Interpreter/JIT agreement is insufficient when they share semantics.

**Check:** Record physical x86 CPUID, OS and compiler; separate ordinary user-mode tests from an isolated privileged environment with bounded recovery.

#### A08.2 — Define portable vector records

- [ ] **Action:** Serialize input registers/flags/memory/control state and output registers/memory/faults with undefined-bit masks and versioned endianness. Hash test bytes and reference identity.

**Why:** Reference results need exact reproducible starting state.

**Check:** Round-trip registers, memory, control state, bytes and fault masks; validate checksums and reject incompatible schema or missing reference identity.

#### A08.3 — Run isolated comparisons

- [ ] **Action:** Execute the same vectors through interpreter and both JIT tiers from isolated initial states; prevent shared mutable fixture memory from making engines agree accidentally.

**Why:** Shared fixture mutation can create false agreement.

**Check:** Reinitialize independent memory/state for each engine; compare defined outputs and precise faults, recording mismatches with the original input.

#### A08.4 — Generate and minimize failures

- [ ] **Action:** Add seeded randomized cases, cross-page faults, SMC and minimized regressions. Retain reproducible seeds and triage disagreements against the specification before changing expected output.

**Why:** Random coverage is useful only if failures are reproducible.

**Check:** Retain seeds, original and minimized cases; replay each under reference and all tiers before accepting a semantic fix.

#### A08.5 — Test the oracle itself

- [ ] **Action:** Require independent coverage for every profile family and all discovered regressions.

**Why:** A comparison service must be capable of detecting bad execution.

**Check:** Introduce a controlled test mutation, observe failure, remove it and obtain a pass; require independent coverage for every advertised family.

**Card closes when:** the reference can reject an intentionally incorrect implementation; self-consistency is not the only correctness oracle.

<a id="a09"></a>

### A09 — Make translated execution fast and bounded

**Owner/home:** JIT/IR/optimizer/memory and native runtime C boundaries.

**Dependencies:** A02.1–A02.4 measured baseline plus behavioral/reference coverage for each optimized form. Final budgets use A29 calibration; optimization does not wait for A29 campaign completion.

**Legacy coverage:** P07-01–08/15/16.

**Starting point:** Both JIT tiers exist. Latest retained handshake improvement does not establish boot or user-workflow improvement.

#### A09.1 — Optimize measured hot forms

- [ ] **Action:** Optimize measured hot instruction/forms first: reduce helper transitions and redundant decoding, improve register residency/lazy flags, block lookup/linking and address translation. Each change includes cold compile time, warm throughput, code size and whole-workload impact.

**Why:** Throughput work must improve the actual slow workloads.

**Check:** Report compile cost, warm execution, code size and whole-workload before/after samples with identical resources and verified guest output.

#### A09.2 — Make cache identity complete

- [ ] **Action:** Audit every cached block key against mode/CPL, segment assumptions, feature profile, page mapping, code bytes/generation and memory permissions. Test self-modifying code, executable aliases, remap, DMA writes and cross-vCPU invalidation.

**Why:** Reusing a block under changed assumptions causes silent corruption.

**Check:** Change mode, privilege, profile, aliases, bytes and mappings independently; stale blocks never run and unrelated blocks remain usable.

#### A09.3 — Retain precise recovery points

- [ ] **Action:** Preserve guest RIP/state recovery at every possible fault/interrupt boundary, including mid-block memory faults and REP. Guard optimizations with explicit deoptimization paths rather than incorrect host assumptions.

**Why:** Fast blocks still need architectural fault and interrupt boundaries.

**Check:** Inject faults and interrupts at each relevant lowering boundary; restored guest state matches the interpreter and independent reference.

#### A09.4 — Bound executable memory lifetime

- [ ] **Action:** Bound code cache, compilation jobs, block linking and retirement; verify W^X, instruction-cache publication and active-reader reclamation in signed Release builds. Never deserialize executable host code from guest snapshots.

**Required cases:** Exercise MAP_JIT policy, approved writer, guard pages, instruction-cache invalidation and C/Swift/assembly ABI/pointer-authentication assumptions. No snapshot may deserialize executable host code; no persistent-code or superblock project precedes measured workload need.

**Why:** Unbounded or prematurely freed JIT code can exhaust or crash the host.

**Check:** Exercise cache pressure and concurrent readers in signed Release; W^X, publication, retirement and maximum memory/job counts hold.

#### A09.5 — Measure useful completion

- [ ] **Action:** Rerun installed boot, package install, compile, compression, browser and RPC workloads against A02 and the pinned external full-system reference.

**Why:** A local microbenchmark win may regress installation or interaction.

**Check:** Installed boot, package install, build, compression, browser and RPC meet A29 budgets with no correctness or key-workload regression.

**Card closes when:** frozen absolute usability budgets and relevant throughput targets pass without changing guest work, durability or correctness.

<a id="a10"></a>

### A10 — Implement real parallel x86 vCPUs and TSO

**Owner/home:** PC machine scheduler, per-vCPU DBT state, memory/JIT publication and device event owners.

**Dependencies:** A05 AP/interrupt/privilege primitives and A08.1–A08.3 independent comparison service. Agree memory/JIT ownership with A09 before concurrent changes; final SMP qualification includes all relevant semantic gates.

**Legacy coverage:** P07-09–14.

**Starting point:** The PC runner currently schedules serialized vCPU slices; true parallel SMP remains open.

#### A10.1 — Specify the ARM implementation of TSO

- [ ] **Action:** Document ordinary load/store, locked RMW, fences, unaligned/cross-cache-line/cross-page atomics, instruction visibility and CPU↔DMA ordering on ARM. Start with a conservative correct barrier/locking strategy and independent litmus expectations.

**Why:** x86 memory ordering does not follow automatically from ARM execution.

**Check:** Review loads/stores, locked operations, fences, DMA and unaligned atomic rules; independent litmus expectations accompany every lowering strategy.

#### A10.2 — Introduce per-vCPU execution

- [ ] **Action:** Replace the global serialized run-loop ownership with one execution context per vCPU. Separate shared RAM, device, interrupt and code-cache synchronization; preserve deterministic single-thread replay as a diagnostic mode.

**Why:** Serialized slices do not deliver advertised multicore performance.

**Check:** Observe overlapping host execution on separate vCPU contexts; race tests verify shared RAM/devices/cache have explicit synchronization owners.

#### A10.3 — Coordinate lifecycle rendezvous

- [ ] **Action:** Implement AP startup, interrupt enqueue/wakeup, HLT idle, stop/pause/reset rendezvous, timeout and teardown without a CPU waiting on a resource held by a stopped peer.

**Why:** Parallel CPUs can deadlock while pausing or stopping one another.

**Check:** Stop during HLT, IRQ, helper and lock contention; every CPU acknowledges within the budget and owner-thread teardown leaves no live handles.

#### A10.4 — Stress concurrent correctness

- [ ] **Action:** Test memory-order litmus, futexes, kernel lock torture, concurrent page-table edits, JIT code invalidation, GPU DMA, flush and reset at 1/2/4/8 vCPUs where admitted. Use race/sanitizer tooling where supported, plus guest stress for uninstrumented generated code.

**Why:** SMP exposes bugs absent from deterministic single-thread runs.

**Check:** At 1/2/4/8 admitted CPUs, run litmus, futex, lock torture, page-table, DMA and invalidation stress with no forbidden results or lost wakeups.

#### A10.5 — Qualify parallel usefulness

- [ ] **Action:** Measure real simultaneous host execution, scaling/contention/fairness and multi-VM behavior.

**Why:** CPU overlap alone can still lose to contention.

**Check:** Measure scaling, fairness, stop latency and multi-VM resource use; both correctness gates and the frozen workload budgets pass.

**Card closes when:** advertised multicore is genuinely parallel, architecture-correct and stable; serialized virtual SMP alone does not pass.

## Linux and container GPU acceleration

<a id="a11"></a>

### A11 — Qualify production renderer admission and first PC accelerated frame

**Owner/home:** daemon production activation, `DoryPCMode`, `DoryPCVirGLRendererAuthority`, renderer launch/wire contracts and host display.

**Dependencies:** A00.1–A00.4 trusted harness activation, A01 coherent candidate and reproducible x86 boot from A02.1. No dependency on A00.5 or completed A09 performance optimization.

**Legacy coverage:** P06-01–06/24.

**Starting point:** PC renderer authority/bootstrap and presentation code are already connected. A verified production hardware frame is still missing.

#### A11.1 — Trace production renderer authority

- [ ] **Action:** Trace the real app/CLI → installed daemon → immutable plan → signed runner → granted renderer descriptors → worker → PCI GPU → host display path. Record which component owns every FD, receipt and generation; prohibit fixture authority substitutions in release evidence.

**Required cases:** Define software display, VirGL/OpenGL and VirGL-plus-Venus/Vulkan profiles with authenticated artifact identity and explicit capset, guest synchronization, format, presentation and recovery requirements. Software is a visible diagnostic/recovery choice, never a successful required-hardware result.

**Why:** A private fixture can bypass the path users actually run.

**Check:** Follow app/CLI through installed daemon, plan, signed runner and worker; match each descriptor/lease/generation to its actual grant and owner.

#### A11.2 — Finish existing PC composition

- [ ] **Action:** Reuse the existing PC authority/bootstrap/presentation code. Confirm the real network helper and read-only configuration share work, guest tools match x86_64, and progress timeout/cancellation does not invalidate live worker resources.

**Why:** Renderer bootstrap is already present and should not be rebuilt blindly.

**Check:** Verify gvproxy, read-only configuration share and x86 tools using actual runner logs; deadline cancellation leaves no prematurely revoked resources.

#### A11.3 — Render a verifiable guest pattern

- [ ] **Action:** Boot with the VirGL profile; verify actual guest DRM node, capset/driver binding and nonsoftware renderer. Execute a known shader/render pattern and validate resulting pixels before requiring an entire compositor to start.

**Why:** A device node or API string does not prove hardware work.

**Check:** Identify guest DRM/capset/driver, reject software renderer names, run known shader input and compare the resulting pixel buffer.

#### A11.4 — Present the real frame

- [ ] **Action:** Present those pixels through Dory's real window with producer completion and consumer retirement evidence. A worker process, successful GL context or software framebuffer is insufficient.

**Why:** Offscreen rendering alone does not prove a working Dory display.

**Check:** Capture guest-produced pixels in the actual window; trace producer fence, presentation generation and consumer retirement with no stale frame.

#### A11.5 — Repeat through catalog activation

- [ ] **Action:** Repeat after cold boot and through the production catalog.

**Why:** First success may depend on warm or private state.

**Check:** Cold-start the same profile from production catalog inputs and repeat pixel/presentation checks; retain signed identities and authority negatives.

**Card closes when:** first verified PC hardware-rendered frame and valid production authority. This does not yet qualify sustained desktop, Vulkan or reset behavior.

<a id="a12"></a>

### A12 — Finish shared GPU resource, queue and fence semantics

**Owner/home:** raw/portable virtio GPU, worker command lane, shared texture/blob leases.

**Dependencies:** A01 for shared design/vectors. Integrate with A11 for PC live tests; A11 bootstrap can use existing semantics before this card’s full completion.

**Legacy coverage:** P04, P06-07–15/25/38/39.

**Starting point:** Raw and portable GPU implementations exist with incomplete shared asynchronous qualification.

#### A12.1 — Choose one semantic owner

- [ ] **Action:** Inventory raw-MMIO versus portable-PCI behavior and choose one owner per shared semantic. Port incrementally using identical vectors over both transports; retain working accelerated paths until parity.

**Required cases:** Keep Metal/XPC objects in host adapters. Preserve damage-proportional software updates and move in-process renderer fakes to worker-channel doubles only after equivalent failure/fence/reset coverage. Do not regress into whole-frame copies during consolidation.

**Why:** Divergent MMIO/PCI GPU behavior multiplies correctness work.

**Check:** Execute identical request vectors on both transports; document each remaining difference and migrate only after equivalent effects and errors pass.

#### A12.2 — Validate resource operations

- [ ] **Action:** Validate resource/context creation/destruction, attach/detach backing, capsets, transfer bounds/strides/formats, scanouts and cursor updates. Add per-resource plus aggregate VM/worker limits.

**Required cases:** Include RESOURCE_CREATE_BLOB/MAP_BLOB/UNMAP_BLOB/SET_SCANOUT_BLOB, UUID and context initialization, negotiated command-feature combinations, cursor shape/hotspot/hide/show and per-scanout delivery. Unsupported combinations must return precise errors.

**Why:** Guest-controlled sizes and IDs are a host isolation boundary.

**Check:** Test formats, strides, backing, scanouts, cursors, invalid ranges and per-VM/global caps; invalid requests neither allocate nor access unrelated memory.

#### A12.3 — Complete asynchronous fences

- [ ] **Action:** Retain descriptors until actual fence completion, with global/context/ring ordering and exactly-once completion. Exercise out-of-order signals, no-fence commands, insufficient responses, timeouts and errors without blocking the vCPU on worker RPC.

**Why:** Early completion permits premature buffer reuse and corruption.

**Check:** Delay/reorder fences and exercise no-fence/error paths; descriptor completion occurs exactly once after required work, without synchronous vCPU blocking.

#### A12.4 — Protect backing generations

- [ ] **Action:** Test backing readback against concurrent unrelated guest writes; preserve dirty regions and producer/consumer ownership. Validate reset/ID reuse, stale callbacks, late texture retirement and worker replacement across generations.

**Why:** Reset and readback must not overwrite newer guest or worker state.

**Check:** Interleave CPU writes, readback, detach, ID reuse and late callbacks; compare dirty regions and reject stale texture/backing publication.

#### A12.5 — Break a busy worker

- [ ] **Action:** Kill a worker during confirmed outstanding work, reset the device and teardown the VM.

**Why:** Idle crash recovery does not establish safe in-flight recovery.

**Check:** Confirm pending GPU work, terminate its worker, then reset/stop; guest sees bounded failure and resource inventory returns to the admitted baseline.

**Card closes when:** bounded failure, correct guest-visible errors/reset, no stale DMA/publication, no leaked textures/FDs and parity across MMIO/PCI.

<a id="a13"></a>

### A13 — Implement and validate PC Venus shared memory

**Owner/home:** `DoryPCPCIExpress`, physical memory, GPU transport, DBT mappings and renderer leases.

**Dependencies:** A12 resource/fence/generation contracts and A11 PC boot/worker composition. Design mappings alongside A12; final tests need the integrated semantics. Shared ABI changes require machine/DBT review.

**Legacy coverage:** P06-10/18/26–29.

**Starting point:** Inventory current blob code first. PC host-visible aperture/coherence/DBT invalidation remains a required Vulkan gate.

#### A13.1 — Define the PCI aperture ABI

- [ ] **Action:** Inventory current blob support before adding files. Specify the versioned host-visible PCI capability/BAR, aperture size/alignment/address limits and overlap with RAM/firmware/MMIO; preserve or migrate persisted machine ABI.

**Why:** Shared GPU mappings affect firmware, guest addressing and persisted machines.

**Check:** Review BAR/capability layout, alignment and address limits against RAM/ROM/MMIO; preserve old machine ABI or provide a tested migration.

#### A13.2 — Implement admitted blob mappings

- [ ] **Action:** Implement BAR sizing/relocation, memory-decode control and CREATE/MAP/UNMAP/SET_SCANOUT_BLOB with explicit feature admission. Reject invalid offset/size/resource/format/permissions and unsupported mapping modes.

**Why:** Advertising unsupported mapping features makes guest Vulkan unreliable.

**Check:** Probe and relocate BARs, toggle memory decode and execute blob lifecycle; reject bad offset/size/format/mode without side effects.

#### A13.3 — Respect allocation granules

- [ ] **Action:** Import only validated worker-exported handles; implement 4 KiB guest-page versus host allocation-granule bounds/coherence. No mapped subrange may expose adjacent host/other-VM memory.

**Why:** A small guest mapping must not expose adjacent host memory.

**Check:** Exercise 4 KiB subranges on the real host granule; out-of-range accesses fail and two VMs cannot read each other's exported allocation.

#### A13.4 — Revoke cached CPU access

- [ ] **Action:** Bind all mappings to memory/device/worker generations. Unmap/remap must revoke DBT cached pointers/translations, prevent stale execution and synchronize active CPU/GPU readers before backing reuse.

**Why:** DBT pointers can outlive GPU unmapping or worker replacement.

**Check:** Map, execute, unmap, reuse and reset under active readers; old pointers/translations are invalid before any backing is recycled.

#### A13.5 — Qualify Vulkan memory operations

- [ ] **Action:** Stress CPU/GPU sharing, BAR relocation, worker death, reset and allocation failure; build architecture-correct x86_64 Venus artifacts.

**Why:** Correct BAR enumeration is only the start of Venus support.

**Check:** Run x86_64 Venus memory/fence tests and fault injection with validated output; A14 remains the separate desktop/API promotion gate.

**Card closes when:** valid Vulkan memory/fence operations on PC with negative isolation tests; keep Vulkan unadvertised until A14.

<a id="a14"></a>

### A14 — Qualify OpenGL/Vulkan and compositors on both Linux ISAs

**Owner/home:** guest Mesa/kernel/desktop packaging and live graphics gates.

**Dependencies:** A12 semantics and a reproducible native guest for ARM. PC additionally requires A11; PC Vulkan additionally requires A13. Guest media/profile inputs come from A01/A19 as available.

**Legacy coverage:** P06-16–23/30–37.

**Starting point:** ARM guest/host graphics builds exist. Neither Linux ISA has the complete required qualified desktop matrix.

#### A14.1 — Define stock and managed profiles

- [ ] **Action:** Freeze separate managed/stock guest profiles with exact kernel/Mesa/host renderer requirements. Test producer fences on stock kernels; supply an explicit supported guest package when needed instead of weakening admission or silently replacing the user's kernel.

**Why:** Guest synchronization support varies by kernel and Mesa build.

**Check:** Record exact producer-fence/driver requirements; stock and supplied-package profiles pass their own admission tests, without hidden kernel replacement.

#### A14.2 — Validate graphics correctness

- [ ] **Action:** Run shader/pixel comparisons and selected relevant GL/Vulkan conformance cases, robust-access and device-loss tests. Record passed/failed/skipped cases and avoid claiming formal Khronos conformance without its process.

**Required cases:** Check orientation, alpha, row stride, clipping, damage and color formats, plus same-GPU Metal texture export/import compatibility on every admitted host class. Formal Khronos conformance is a separate process; selected passing tests do not establish it.

**Why:** Fast incorrect output must fail before performance is measured.

**Check:** Compare shader pixels and compute buffers; retain GL/Vulkan case lists and failures/skips, robust-access results and device-loss behavior.

#### A14.3 — Exercise Vulkan synchronization

- [ ] **Action:** Exercise Vulkan external memory/semaphore import/export, acquire→render→submit→present, optimal-image→linear-scanout copies and queue/fence lifetime. Count CPU and GPU copies and attribute CPU translator time separately from GPU execution.

**Required cases:** Qualify direct-linear rendering separately from optimal-image-to-linear scanout. Count CPU and GPU copies; shared memory does not establish a zero-copy claim. Keep translator CPU time separate from worker GPU execution.

**Why:** External memory and presentation involve multiple owners and queues.

**Check:** Trace acquire, import/export, render, submit, copy and present; stress reuse/teardown and prove semaphore/fence ordering and image correctness.

#### A14.4 — Qualify actual compositors

- [ ] **Action:** Qualify Xorg, XWayland and native Wayland on GNOME/KDE as separate cells; verify actively redrawing hardware-rendered GTK/Qt/browser/WebGL/editor windows, text, resize, scaling, fullscreen and sustained resource churn. Remove compositor overrides only after their original failures pass.

**Required cases:** Native Wayland readiness needs compositor-aware observation, not X11 window enumeration. Remove WaylandEnable=false or forced GSK_RENDERER=gl only after the original failures pass. wlroots, rotation and codec acceleration are separate optional cells; ordinary video playback still needs usability testing.

**Why:** A demo shader does not establish a usable Linux desktop.

**Check:** For each required GNOME/KDE Xorg/XWayland/Wayland cell, verify active GTK/Qt/browser/WebGL/editor rendering, text, resize, scaling and fullscreen.

#### A14.5 — Repeat under realistic pressure

- [ ] **Action:** Repeat at declared resolutions, resource limits, host sleep/wake and multiple VM pressure.

**Why:** GPU support must survive sustained use and changing displays.

**Check:** Test frozen resolutions, sleep/wake, allocation churn and simultaneous VMs; no llvmpipe/lavapipe fallback, corruption or unexplained crash is accepted.

**Card closes when:** both Linux ISAs pass required GL and Vulkan desktop workloads without llvmpipe/lavapipe fallback; optional codecs/compute APIs remain independently reported.

<a id="a15"></a>

### A15 — Finish GPU product behavior and recovery

**Owner/home:** effective capabilities, UI/daemon events, display and worker recovery.

**Dependencies:** A12/A14; usability can be developed earlier with explicit fixtures.

**Legacy coverage:** P06-06/22/34/38/39, P12.

**Starting point:** Worker/presentation lifecycle code exists; truthful product readiness and sustained active-loss recovery need qualification.

#### A15.1 — Expose observed capability state

- [ ] **Action:** Project requested versus admitted versus observed graphics state, guest driver/API/features, workload readiness and loss/recovery into one daemon-owned result. Distinguish worker-ready, guest-device-ready and first-presented-frame.

**Why:** Users need to know whether the requested graphics mode actually works.

**Check:** Compare requested, admitted and observed profiles in daemon/UI; worker-ready, guest-device-ready and first-presented-frame are separate events.

#### A15.2 — Reject unavailable required APIs

- [ ] **Action:** Make a required Vulkan request fail clearly when only VirGL/software is available; offer an explicit user choice where appropriate. Never silently turn a mandatory GPU request into software rendering.

**Why:** Silent software fallback contradicts required acceleration.

**Check:** Request unavailable Vulkan or incompatible guest driver; operation fails with the precise cause or an explicit alternate user choice.

#### A15.3 — Recover renderer loss honestly

- [ ] **Action:** Implement bounded renderer-loss recovery with queue cancellation/device reset or a clearly explained VM restart where live recovery is impossible. Preserve disks and report failed GPU work honestly.

**Why:** A restarted worker does not make interrupted guest work successful.

**Check:** Inject active loss; verify GPU error/reset or documented VM restart, preserved disk checksums and accurate operation status.

#### A15.4 — Complete display resource behavior

- [ ] **Action:** Exercise cursor/input focus, resize, multiple scanouts where advertised, minimize/occlusion, display disconnect and teardown; establish per-VM/global resource admission and reclamation grace periods.

**Why:** Ordinary window actions exercise lifetime and pressure edges.

**Check:** Resize/minimize/occlude/disconnect/focus and stop each profile; allowed scanouts work and textures/FDs reclaim within the frozen grace period.

#### A15.5 — Verify multi-VM containment

- [ ] **Action:** Run concurrent VM malicious/exhaustion cases and active-work kill/restart cycles.

**Why:** One guest must not exhaust or corrupt another guest's graphics.

**Check:** Run adversarial allocation and repeated busy-worker restart alongside a healthy VM; quotas hold and unaffected workloads retain correct output.

**Card closes when:** UI reports effective reality, failed work is not marked successful, and recovery/data/resource behavior matches the documented capability.

<a id="a16"></a>

### A16 — Repair and promote FEX application compatibility

**Owner/home:** pinned FEX producer, signal-context patches, initfs and container live gates.

**Dependencies:** A01; independent of full-system DBT implementation.

**Legacy coverage:** P06-C02/C06, existing container contract.

**Starting point:** The default Go preemption failure remains a promotion blocker. Keep the current production pin until repaired and qualified.

#### A16.1 — Reproduce default-mode FEX failure

- [ ] **Action:** Reproduce default Go asynchronous-preemption regexp failures against shipped, upstream-control and candidate FEX on identical kernels/rootfs/toolchains. Keep `GODEBUG=asyncpreemptoff` as a diagnostic control, never the compatibility acceptance condition.

**Why:** Disabling Go preemption hides the compatibility defect.

**Check:** On identical inputs, compare shipped, upstream and patched FEX; default Go regexp/runtime workloads must pass, with override only a diagnostic control.

**Status:** `d5de35864` retains the previously private regexp/goroutine reproducer under `guest/diagnostics/fex-go-preemption`, pinned to Go 1.22.10 with matching hashes from two builds. The retained historical binary identifies itself as Go 1.22.10; earlier Go 1.25.9 notes describe separate inputs. On the same shipped FEX/kernel/base-rootfs tuple, the [retained binary replay](docs/virtualization/evidence/wave0-2026-09-08/wave1-fex-shipped-replay.json) failed default preemption with exit 2, and the [rebuilt source replay](docs/virtualization/evidence/wave0-2026-09-08/wave1-fex-rebuilt-replay.json) failed with exit 4 in Go stack unwinding. Both diagnostic `asyncpreemptoff` controls exited zero with total 133056000. Disposable clones were removed after shutdown. This is a current, reproducible failure, not a repaired compatibility result; the upstream/candidate comparison and all promotion gates stay open.

#### A16.2 — Repair signal context handling

- [ ] **Action:** Minimize signal arrival in translated code, dispatcher, syscall entry/return and host alternate stack. Validate unchanged versus edited RIP/RSP/GPR/flags/vector contexts, nested signals, interrupted syscalls, thread exit and restart behavior.

**Why:** Signals can interrupt translated and host helper state differently.

**Check:** Inject at dispatcher/syscall/translated boundaries; verify unchanged and edited register/vector contexts, nested signals and restart semantics.

#### A16.3 — Protect adjacent application behavior

- [ ] **Action:** Verify static PIE/nested chroot, binfmt exec, execveat, descriptor isolation and seccomp behavior remain intact. Run Go/runtime stress, real amd64 dockerd and supported package-manager/compiler/container workloads with default settings.

**Why:** A signal fix can break exec, descriptors or container startup.

**Check:** Run static PIE/chroot/binfmt/execveat/seccomp cases, default Go stress and real amd64 dockerd; verify output and descriptor isolation.

#### A16.4 — Rebuild reproducibly before promotion

- [ ] **Action:** Rebuild from clean pinned source, record patch/source/toolchain hashes and independently verify outputs. Do not alter production pins until all default-mode regressions pass.

**Why:** Production pins must identify reviewed and qualified bytes.

**Check:** Two clean builds record source/patch/toolchain hashes and matching expected artifacts; default-mode regression evidence precedes pin changes.

**Status:** `d9ff409b1` repairs a producer provenance mismatch: the production patch path had been overwritten by the unpromoted September 6 candidate while rebuild pins still selected the shipped hash. The exact shipped patch is restored; the experimental bytes are retained separately as `patches/fex-signal-context-hostaltstack-candidate.patch`. Both sequences apply to the pinned upstream revision, and the full ARM64 initfs verifier again passes fingerprint `9328714a5a288c3f622f037d01c41b3cb3a3a9bf105413b8540a869ef3c0a4cd`; [verification](docs/virtualization/evidence/wave0-2026-09-08/wave1-fex-patch-binding.json). No translator bytes or production pins changed. Two clean candidate builds and default-mode qualification remain open.

#### A16.5 — Promote with rollback

- [ ] **Action:** Promote transactionally with rollback and repeat ordinary container lifecycle/data tests.

**Why:** Translator replacement must preserve the existing container product.

**Check:** Install candidate, run ordinary amd64 workloads, volumes and lifecycle, then rollback; data and supported defaults remain correct both ways.

**Card closes when:** supported amd64 applications pass with defaults; a full-system x86 VM result cannot substitute for this FEX gate.

<a id="a17"></a>

### A17 — Deliver combined native/amd64 container GPU support

**Owner/home:** engine configuration, guest kernel/Mesa/initfs, OCI device admission and Docker producer.

**Dependencies:** A12/A16; ARM-only compute can be qualified earlier.

**Legacy coverage:** P06-C01–06.

**Starting point:** ARM no-override compute and idle-worker recovery are bounded successes. Combined FEX/GPU and pending-work recovery remain open.

#### A17.1 — Resolve the page-size conflict

- [ ] **Action:** Resolve the 16 KiB GPU versus 4 KiB FEX guest-page conflict with a reproducible experiment matrix. Prefer a correctly qualified common guest configuration; if separate engine profiles are necessary, specify explicit switching/data compatibility and do not claim combined same-engine support until it actually works.

**Why:** Current native GPU and translated application requirements conflict.

**Check:** Compare pinned 4 KiB/16 KiB kernel-FEX-Mesa combinations using both actual compute and default amd64 workloads; record an explicit supported configuration.

#### A17.2 — Package both guest library stacks

- [ ] **Action:** Package correct ARM64 and amd64 userspace ICD/libraries for supported container images. Verify the guest kernel DRM ABI and translation/driver interaction; host ARM libraries are not valid substitutes for guest amd64 libraries.

**Why:** GPU libraries must match the container ISA and guest DRM ABI.

**Check:** Inspect ELF architecture, ICD loading and dependencies in ARM64/amd64 images; shader execution uses the expected guest libraries and hardware driver.

#### A17.3 — Qualify standard Docker requests

- [ ] **Action:** Run normal `docker run --gpus all` with no driver environment overrides; validate exact render-node permissions and hardware compute outputs for both ISAs. Test denied/conflicting device requests and cross-container isolation.

**Why:** Debug environment setup is not the normal user workflow.

**Check:** Run standard GPU requests without ICD/driver overrides; verify every expected output, render-node permissions and denied-device/cross-container negatives.

#### A17.4 — Qualify engine recovery changes

- [ ] **Action:** Requalify maintained Docker start-intent checkpoint changes at the pre-ack crash boundary and during genuinely pending GPU work. Inspect restored task state, exit status, volume checksums and automatic engine recovery; promote pinned binaries only after these gates.

**Why:** A pre-ack crash can lose or replay task start intent.

**Check:** Crash at checkpoint boundaries and during confirmed GPU work; restored tasks, exits and volume checksums match committed state before promoting Docker pins.

#### A17.5 — Integrate sustained combined support

- [ ] **Action:** Connect observed GPU readiness to Settings/daemon, run concurrent sustained workloads and measure memory/resource reclamation.

**Required cases:** Replace any remaining ambient dlopen/Homebrew Settings probe with the same verified authority as the runner. Preserve requested settings on initialization failure. Exact OCI render-node permissions must follow admitted device requests, not the presence of a request string.

**Why:** Separate one-off successes do not establish one working product.

**Check:** Settings and daemon agree on readiness; concurrent native/translated compute passes, active failures are truthful and resources reclaim after stop.

**Card closes when:** default native and supported translated container GPU workloads succeed, interrupted work is truthful, and existing container data/compatibility gates remain intact.

## Native Linux and macOS operation

<a id="a18"></a>

### A18 — Finish native ARM execution ownership and machine correctness

**Owner/home:** `DoryHV/Machine.swift`, `DoryNativeHVArm64`, ARM machine/DTB and HV adapters.

**Dependencies:** A01 inputs. A19 supplies ordinary installer/UEFI end-to-end validation after A18.1–A18.4 establish the necessary runtime; do not require A19 completion before starting this card.

**Legacy coverage:** P03.

**Starting point:** The reviewed probe implements deadlines/lifecycle and DFR readback. Production trap changes have unit coverage; real guest register/fault behavior and production owner parity remain open.

#### A18.1 — Map the real native owner

- [ ] **Action:** Trace production HV/vCPU/GIC/memory ownership and every probe-only API. Wrap or extract from the working runtime only where a real caller needs the contract. Keep availability checks in the host adapter.

**Why:** Probe abstractions must not become a competing production runtime.

**Check:** Trace app launch to actual HV/GIC/memory owners; adapter/extraction changes preserve both direct and UEFI guest behavior before deleting a path.

#### A18.2 — Complete production lifecycle boundaries

- [ ] **Action:** Extend the reviewed deadline and owner-thread contracts through actual start/stop/reset/pause/suspend operations. Cover run, WFI, IRQ handling, device/worker activity, pending exits and concurrent teardown. Coordinate quiescence across all owners.

**Why:** Bare-metal deadline smoke covers only a narrow execution contract.

**Check:** Cancel during run, WFI, IRQ, device work and teardown; verify owner threads, bounded rendezvous and generation-safe quiescence on production launches.

**Status:** `58f141a5f` serializes ARM team-array initialization against incoming stop/pause requests, reads terminal state under the team lock, and protects the shared sysreg log counter across vCPUs. Nineteen focused PSCI/pause/register/owner-thread tests pass. A four-vCPU/1 GiB native Linux boot returned agent information over vsock and shut down in 2.90 seconds with disposable backing removed; [receipt](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-smp.json). This supports the source fix but does not close the startup-cancellation, IRQ/device-stress, quiescence or recovery campaign; A18.2 stays open.

#### A18.3 — Qualify registers, PSCI and interrupts

- [ ] **Action:** Validate the narrowed debug/PMU policy and sanitized guest feature state through guest-executed instructions, including unsupported encodings, read/write direction, exception entry and return. Complete PSCI version/features, CPU_ON/OFF, affinity, reset/poweroff and one GIC pending/in-service owner; hotplug/suspend requires explicit admission.

**Why:** Feature masks and trap classifications need real guest validation.

**Check:** Guest-executed MRS/MSR vectors verify RAZ/WI or undefined state/return; exercise PSCI CPU_ON/OFF/affinity and GIC routing under SMP without blanket no-ops.

#### A18.4 — Validate boot and memory topology

- [ ] **Action:** Check kernel Image header/placement, DTB alignment/size, initramfs, RAM/ROM/MMIO/firmware/shared-memory ranges, reservations, boot registers, MMU/cache state and timer frequency. Ensure runtime and firmware/DTB describe identical topology.

**Why:** Firmware, DTB and runtime must describe the same physical machine.

**Check:** Assert placement, ranges, reservations, timers, initial state and resource bounds; real kernels boot at admitted minima and under host memory pressure.

**Status:** `4fb4396e8` fixes legacy Image text-offset interpretation, enforces 2 MiB base alignment, and rejects overflowing or reserved kernel extents before copying to RAM. The production direct loader reserves DTB/payload space through the shared loader, replacing its post-copy overlap check. Twelve focused loader/payload tests pass. A disposable two-vCPU/1 GiB native-HV boot using Linux 6.12.106-dory returned real agent information over vsock and exited in 2.91 seconds; [receipt and logs](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-agent-ping.json) bind the exact kernel/rootfs/entitled runner. This ad-hoc development rerun is not UEFI, signed-daemon, memory-pressure or minimum-host qualification; A18.4 remains open.

#### A18.5 — Prove parity and retire duplication

- [ ] **Action:** Run SMP direct-kernel and UEFI workloads at admitted CPU/RAM limits, IRQ storms, memory pressure, rapid lifecycle and sleep/wake. Preserve correct all-pages-dirty reporting until CPU/DMA/granule write coverage proves optimized tracking. Remove duplicate execution only after production and minimum-host parity.

**Why:** Passing a probe is not permission to replace working production code.

**Check:** Run direct/UEFI, 1/2/4/8 admitted CPUs, sleep/wake and dirty CPU/DMA snapshot checks; one production owner remains and minimum-host API branches pass.

**Card closes when:** One production execution owner; reliable lifecycle, precise guest-visible register behavior, direct/UEFI parity, coherent interrupts and no reachable unimplemented deadline contract. Probe-only evidence cannot close production qualification.

<a id="a19"></a>

### A19 — Qualify ordinary Linux installation and updates on both ISAs

**Owner/home:** firmware/media pipeline, machine planners, install journals and guest catalog.

**Dependencies:** A01 media/candidate; integrated A18.1–A18.4 boot primitives for ARM; reproducible PC boot plus A04/A05 and the CPU profile required by the selected distro for x86. Final accelerated desktop acceptance also requires A14.

**Legacy coverage:** P05.

**Starting point:** Existing-disk manager campaigns prove some media transitions. They do not prove fresh ordinary installation on either ISA.

#### A19.1 — Reproduce firmware

- [ ] **Action:** Rebuild ARM/PC firmware from pinned inputs on two clean builders; verify ABI and reproducibility. Exercise reset/entry, console/GOP, boot variables, device enumeration, ExitBootServices and runtime variables.

**Required cases:** Preserve an atomic recoverable firmware-variable store across restart, failed install and firmware update. Compare clean-build output hashes or explicitly document nondeterministic fields; never reset an existing variable store to make a boot pass.

**Why:** Ordinary installers require a stable firmware ABI.

**Check:** Build on two clean builders, verify locked inputs, and test console/GOP, variables, enumeration, ExitBootServices and reset with retained firmware hashes.

#### A19.2 — Validate media before mutation

- [ ] **Action:** Validate ISO/raw/imported media detection, architecture, allocation limits and selected firmware path. Reject malformed/wrong-ISA media before allocating mutable VM artifacts; preserve original input bytes.

**Required cases:** Implement streaming verified download/import with resume, cancellation, temporary-space reservation, immutable deduplicated cache and atomic publication. Keep installer, writable disk, firmware code/variables and tools as distinct artifacts. Promised QCOW2/VMDK import requires an isolated bounded converter with backing-chain/cycle/path checks and no shipped QEMU utility dependency.

**Why:** Invalid or wrong-ISA media should not leave costly partial machines.

**Check:** Feed valid and malformed ISO/raw/imported images; assert ISA/format diagnosis, bounded allocation and no alteration of original bytes.

#### A19.3 — Perform fresh installations

- [ ] **Action:** Install each frozen distro/ISA from fresh ordinary supported media through the app and CLI into a new disk. Verify partitioning, bootloader, keyboard/network/storage, installer progress and cancellation/retry without fixed diagnostic load addresses.

**Required cases:** Retain a serial/recovery console when graphical setup fails. Exercise checksum failure, low disk, cancellation, host/process restart and external-drive loss at install stages. Managed templates remain optional; do not infer backend compatibility from distro names or require a managed kernel for an installed stock guest.

**Why:** Existing diagnostic disks cannot prove general installer support.

**Check:** From pinned ordinary media, install each required distro/ISA through app and CLI; verify partitioning, bootloader, input, networking and cancel/retry cleanup.

#### A19.4 — Prove installed-disk independence

- [ ] **Action:** Detach installation media, relaunch Dory/daemon, cold boot offline, change resources while stopped and reboot repeatedly. Persist boot order/NVRAM and installed-media state; no hidden dependency on installer/initfs/config scratch paths.

**Why:** A VM may appear installed while depending on scratch or media files.

**Check:** Detach media, remove only owned scratch copies, restart daemon/app and cold boot offline; persisted variables and changed stopped resources work.

#### A19.5 — Qualify updates and recovery

- [ ] **Action:** Perform package and kernel/bootloader updates, tools/graphics package updates and rollback/recovery.

**Required cases:** Cover guest-controlled encrypted disks and unlock/recovery prompts, non-US keyboard input, changed boot order and initramfs regeneration. Host-managed disk encryption is a separately declared feature. Unknown media cannot inherit a nearby distro’s release qualification.

**Why:** A one-time boot is not a maintainable operating system.

**Check:** Update kernel/bootloader/packages/tools, reboot and exercise rollback; verify user files and hardware desktop state on two distro families per ISA.

**Card closes when:** two selected distro families per ISA complete install→installed boot→update→recovery, with accelerated profiles explicitly gated by A14.

<a id="a20"></a>

### A20 — Finish essential device parity and daily I/O

**Owner/home:** shared virtio cores, MMIO/PCI transports, host network/audio/USB/input adapters.

**Dependencies:** A01; run against A18/A19 guests.

**Legacy coverage:** P04, P09.

**Starting point:** Essential device implementations and focused tests exist; full MMIO/PCI and real-guest parity are not established.

#### A20.1 — Unify queue and DMA correctness

- [ ] **Action:** Inventory queue/feature/reset differences; validate descriptor chains, indirect/loop/overflow bounds, event suppression, queue wrap and exactly-once asynchronous completion over both transports. Test DMA authority independent of CPU virtual-address privilege rules.

**Required cases:** Cover FEATURES_OK/DRIVER_OK and full reset; immutable bounded in-flight requests; readable/writable chain ordering and overlapping rings. Check PCI 32/64-bit BAR probing/reassignment, ECAM, decode enables, capability lists, MSI/MSI-X table/mask/PBA and INTx using real firmware enumeration. Packed rings require a measured justification before expanding scope.

**Why:** Invalid descriptors and stale completion are cross-architecture hazards.

**Check:** Test feature/status negotiation, loops, overflow, wrap, indirect descriptors and reset generations over MMIO/PCI; DMA uses granted physical authority.

#### A20.2 — Qualify durable block I/O

- [ ] **Action:** Qualify block geometry/read/write/flush/discard/write-zeroes, short I/O, read-only errors, cancellation and reset. Verify data checksums and promised persistence after completed flushes.

**Why:** A completed flush must represent the promised persistence boundary.

**Check:** Use checksum workloads with short I/O, read-only disks, discard, ENOSPC and reset; crash after acknowledged flush and verify durable data.

#### A20.3 — Finish network, RNG and control devices

- [ ] **Action:** Validate network offload/MTU/backpressure/link change, cryptographic RNG, vsock flow control/half-close/reset and guest-agent framing/deadlines. Do not reintroduce empty invalid PCI capabilities.

**Why:** Boot success can conceal broken everyday transport semantics.

**Check:** Check offloads/MTU/backpressure, real cryptographic entropy and vsock half-close/framing/cancellation; malformed requests remain bounded.

#### A20.4 — Complete interactive device behavior

- [ ] **Action:** Complete keyboard release/focus recovery, relative/absolute pointer/scrolling, audio routing/latency/underrun, USB/xHCI enumeration/reset/detach and the actually advertised camera/mass-storage policies. Keep physical passthrough distinct from emulated devices.

**Required cases:** Test xHCI control/bulk/interrupt transfers, hotplug lease conflicts and queue-overflow input resynchronization. Audio includes PCM formats/rates/channels, positions/events, overrun/underrun and device loss. Physical USB passthrough, emulated HID, camera forwarding and disk-image mass storage are separate capabilities.

**Why:** Focus changes and device loss are ordinary user actions.

**Check:** Exercise complete key release, pointers, audio formats/events/underrun and USB transfer/reset/detach; verify opted-in camera/storage behavior separately.

#### A20.5 — Verify parity under concurrent I/O

- [ ] **Action:** Stress I/O during reset/stop and multi-VM load; remove duplicate cores only after transport parity and guest regressions pass.

**Why:** Shared device cores must survive lifecycle races in real guests.

**Check:** Reset/stop during outstanding work on both transports and multiple VMs; no stale DMA, duplicate completion, hang or leaked backing survives.

**Card closes when:** device features work in real daily workloads, unsupported hotplug rejects explicitly, and malformed guest input remains contained.

<a id="a21"></a>

### A21 — Finish production Mac installation and lifecycle

**Owner/home:** VZMac adapter/application/core, daemon activation/manager and install/saved-state journals.

**Dependencies:** A00.1–A00.3 production authentication and A01 restore/candidate inputs; preserve completed install-stop behavior. No dependency on PC GPU qualification.

**Legacy coverage:** P08-02–09/17–25/31.

**Starting point:** Install-stop orchestration, installed-media transition and private signed-helper lifecycle work exist. Production admission and all failure boundaries remain open.

#### A21.1 — Install through the shipped Mac path

- [ ] **Action:** Use Apple-supported restore discovery and verify hardware-model compatibility and resource minima. Through the actual installed daemon and signed helper, run download/cache→prepare→install→first boot→Setup Assistant→installed cold boot without the IPSW cache.

**Why:** Private helper success does not qualify production activation.

**Check:** Record supported restore/hardware requirements, then actual daemon download through Setup Assistant; cold boot succeeds without the disposable IPSW cache.

#### A21.2 — Preserve Mac identity atomically

- [ ] **Action:** Preserve hardware model, machine identifier, auxiliary storage, disk and configuration as one owned bundle. Verify retry and cold restart never regenerate identity or replace a user's disk.

**Why:** Regenerating platform identity during recovery can invalidate a machine.

**Check:** Hash and reopen the hardware model, machine ID, auxiliary storage, disk and configuration bundle across retries; ordinary start never replaces them.

#### A21.3 — Qualify every lifecycle transition

- [ ] **Action:** Qualify start/guest shutdown/forced stop/restart/pause/suspend/restore with observed state transitions and bounded cancellation. Perform a real guest file/compute task after restore; a resumed title/window is insufficient.

**Required cases:** Reuse bounded authenticated control framing and owner-safe socket lifecycle; complete machine/operation/generation binding and backend execution deadlines. SIGTERM/SIGINT must request bounded guest shutdown or install cancellation before forced termination. Do not equate the client socket deadline with canceled backend work.

**Why:** A resumed window alone does not prove guest execution recovered.

**Check:** Observe start/shutdown/force-stop/restart/pause/suspend/restore with deadlines; run a checksum file task and compute workload after restore.

#### A21.4 — Inject failures at durable boundaries

- [ ] **Action:** Inject failure at reserve/quiesce/save/validate/publish/acknowledge and restore/consume/cleanup boundaries. Reopen with a fresh daemon after each interruption. Stop/discard of a suspended VM must reconcile backend bundle and daemon wrapper atomically, preserving cold-bootable disk state.

**Required cases:** Use one outer saved-state operation manifest plus the verified backend payload, not competing pseudo-saved formats. Bind configuration/identity/host/runtime/payload hashes and refreshed mutable provenance. Suspended stop/discard must reconcile both daemon wrapper and backend bundle without changing guest disk data.

**Why:** Backend and daemon state can disagree after interrupted save or discard.

**Check:** Kill/reopen at reserve, save, validate, publish, acknowledge, consume and cleanup; a fresh daemon selects one recoverable state and never replays consumed RAM.

#### A21.5 — Qualify host and upgrade failures

- [ ] **Action:** Test locked/unlocked console behavior, host sleep/restart, disk full, external-drive loss, stale leases, unsupported saved-state compatibility and guest/Dory upgrades. Offer safe cold boot for incompatible RAM state without discarding data.

**Why:** Real environments include locks, power events and unavailable drives.

**Check:** Exercise locked console, sleep/restart, full disk, lost drive, stale leases and incompatible RAM state; safe cold boot preserves data and identity.

**Card closes when:** real production install/lifecycle/recovery passes; private fixture successes remain supporting evidence only.

<a id="a22"></a>

### A22 — Finish Mac device policy, guest tools and Metal qualification

**Owner/home:** `DoryVZMacConfigurationBuilder`, guest tools, host brokers and Mac live gate.

**Dependencies:** A21 for production qualification; policy implementation may run earlier.

**Legacy coverage:** P08-10–16/26–30, P09.

**Starting point:** Private guest Metal compute succeeds; default camera/microphone off and policy work exist. Actual policy/revocation and production Metal qualification remain open.

#### A22.1 — Connect requested device policy

- [ ] **Action:** Trace CPU/RAM/display/network/audio input/output/clipboard/shares/camera/USB settings from definition through resolved plan into actual VZ configuration and brokers. Verify disabled devices are absent or effectively blocked in the guest.

**Why:** Persisted settings are ineffective unless they reach VZ and brokers.

**Check:** Inspect actual constructed devices and guest access for each setting; disabled audio/network/shares/camera/USB/clipboard cannot operate.

#### A22.2 — Enforce granted integrations

- [ ] **Action:** Finish granted-directory authority and directional clipboard enforcement. Reject unsupported network/camera/USB modes truthfully; do not replace a denied mode with shared NAT or bidirectional clipboard.

**Required cases:** Camera and microphone remain opt-in with host permission, visible use and revocation. Optional camera-extension activation cannot block base Mac installation/boot. Distinguish virtual USB mass storage, physical attachment and camera bridging against the selected public SDK and host availability.

**Why:** Convenience defaults must not override denied or directional policy.

**Check:** Test read-only/read-write roots, clipboard directions and revocation; unavailable modes reject instead of silently widening access.

#### A22.3 — Deliver trustworthy Mac tools

- [ ] **Action:** Install and supervise machine-bound Mac guest tools using supported service mechanisms. Report guest OS/build, tools protocol/capabilities and actual readiness; distinguish helper alive, VM running, guest login and workload-ready.

**Why:** Helper liveness, login and workload readiness differ.

**Check:** Install/update/uninstall the machine-bound service; verify protocol/build identity, reconnect and observed readiness without ambient host authority.

#### A22.4 — Prove guest Metal after lifecycle changes

- [ ] **Action:** Run real guest Metal render and compute workloads with validated pixels/outputs, feature inventory and no host-only proxy success. Repeat after suspend/restore, resize, sleep/wake, resource pressure and long application use.

**Why:** Host presentation can succeed while guest applications use no GPU.

**Check:** Validate guest render pixels, compute results and device features before/after restore, resize, sleep/wake and pressure using the actual production composition.

#### A22.5 — Qualify daily Mac work

- [ ] **Action:** Qualify browser/productivity and representative Xcode build/debug, input shortcuts, audio, clipboard and shared-folder workflows through the production app.

**Why:** A numerical probe does not establish a useful development desktop.

**Check:** Complete browser/productivity and Xcode build/debug with fixed resources; verify input, audio, shares, clipboard and sustained Metal workloads.

**Card closes when:** accelerated Mac desktop with enforced policy, observed readiness and retained sustained workload evidence; Apple API limits are explicitly documented.

## Data, integrations and shipped surfaces

<a id="a23"></a>

### A23 — Make storage, snapshots, clone and backup recoverable

**Owner/home:** artifact mutation/leases, snapshot/backup/import/export and Mac bundle recovery.

**Dependencies:** A19/A21 per cell; coordinate GPU/CPU quiescence with A10/A12/A18.

**Legacy coverage:** P10, P08-20–24.

**Starting point:** Artifact authority and recovery primitives exist; advertised data operations need integrated interruption and restore evidence.

#### A23.1 — Define durable inventory and authority

- [ ] **Action:** Define the durable inventory and transaction states for each backend: disks, firmware variables, Mac identity/auxiliary storage, configuration and optional saved RAM. Acquire exclusive mutation authority and reject concurrent destructive operations.

**Required cases:** Use descriptor-rooted file operations with type/owner/permission/symlink/volume checks and exclusive leases. Inventory tools metadata/logs separately from reconstructible cache and irreplaceable guest data; startup reconciles interrupted operations and orphaned processes without inferring permission to delete disks.

**Why:** Data operations need one owner across daemon and backend artifacts.

**Check:** Enumerate disk/NVRAM/Mac identity/config/RAM states; overlapping mutations reject and each transaction has recoverable ownership and commit points.

#### A23.2 — Make storage errors transactional

- [ ] **Action:** Verify raw sparse disk flush/error semantics, allocation/capacity changes, ENOSPC and external-drive disconnect. Implement supported format import via bounded transactional conversion; retain originals until verified commit.

**Required cases:** Preserve sparse/APFS clone allocation while accounting for clone divergence and recovery headroom. Grow disks only while stopped or through a qualified coordinated path; reject shrink without guest-filesystem-aware support. File growth alone is not filesystem growth. Test EIO, ownership/volume changes and remount.

**Why:** Disk-full or conversion failure must not replace good user data.

**Check:** Inject partial writes, allocation failure and drive loss; original images survive, sizes remain bounded and acknowledged persistence matches policy.

#### A23.3 — Qualify cold snapshots before live save

- [ ] **Action:** Qualify stopped/cold snapshots first. For any advertised live save, quiesce CPUs/devices/workers, drain or cancel I/O/GPU work and record compatible backend state; otherwise explicitly limit that operation to cold snapshots.

**Required cases:** For live capture, freeze → stop new work → drain/fence → capture → validate → publish → resume; durable suspend stops/releases the helper after commit. Linux state includes CPUs, RAM, clocks, interrupts, queues and pending I/O; Mac uses supported opaque Apple state. Never persist stale GPU handles. Reject live accelerated save if renderer restore cannot be implemented safely.

**Why:** Live state requires more than copying a disk file.

**Check:** Restore cold snapshots with checksums; any admitted live save proves CPU/device/GPU quiescence and rejects incompatible or incomplete state.

#### A23.4 — Separate restore, clone and export

- [ ] **Action:** Distinguish same-machine restore from new-machine clone; preserve or regenerate identities intentionally. Portable exports exclude host-bound executable/RAM state, validate paths/sizes/hashes and import on a second supported Mac.

**Required cases:** Clone identity includes Linux UUID/MAC/guest-control credentials as well as Mac platform identity. Prevent concurrent duplicated credentials or MACs. Imports must reject archive traversal, symlink escapes, compression bombs and external backing references before registration; portable bundles retain sparse storage and declared dependencies.

**Why:** Identity and host-bound state have different portability rules.

**Check:** Same-machine restore preserves identity, clone intentionally changes it, and portable import validates paths/hashes on a second supported Mac.

#### A23.5 — Run real recovery drills

- [ ] **Action:** Inject crash at copy/fsync/rename/metadata/cleanup boundaries; test backup retention, disk-full backup, interrupted restore and actual restore drills with checksums.

**Required cases:** Snapshot/base reference tracking must prevent retention cleanup from deleting backing used by a clone or backup. Wire existing backup scheduling to verified exports and real restore drills; keep a last-known-good local recovery point and do not promise unimplemented offsite backup. Doctor/repair operations must say whether they change configuration, discard volatile state or modify durable data.

**Why:** Successful backup creation is not evidence of successful restoration.

**Check:** Crash at copy/fsync/rename/metadata/cleanup, fill backup storage and interrupt restore; recover actual files with checksums and verify retention policy.

**Card closes when:** every advertised data operation preserves recoverable originals and passes interruption testing; a success receipt alone is insufficient.

<a id="a24"></a>

### A24 — Finish networking and filesystem sharing

**Owner/home:** network helpers/brokers, guest-facing adapters and filesystem worker.

**Dependencies:** A20/A21 per backend.

**Legacy coverage:** P11.

**Starting point:** Network and isolated filesystem workers exist. Effective modes, coherence, recovery and performance remain per-cell gates.

#### A24.1 — Qualify effective network modes

- [ ] **Action:** Define effective NAT/isolated/bridged/source-preserving modes supported per cell; verify DHCP/DNS/IPv4/IPv6, MTU, port forwarding and inbound rules with real packets and guest connections.

**Required cases:** Bind forwarded ports to localhost by default and make LAN exposure explicit. Include UDP/TCP fragmentation, DNS search domains, address renewal and promised MAC/IP persistence. Mac VZ networking must pass directly; working Linux GVProxy is not Mac forwarding proof.

**Why:** A named mode must match actual connectivity and exposure.

**Check:** Use real packets for DHCP/DNS/IPv4/IPv6, MTU and forwarding; isolated mode isolates and external access respects selected interfaces.

#### A24.2 — Recover host networking changes

- [ ] **Action:** Test host VPN/Wi-Fi changes, sleep/wake, offline launch, address/port conflicts, helper death and daemon reconnect. Enforce privileged mode admission and prevent unintended exposure beyond configured interfaces.

**Required cases:** Include corporate proxy/trusted-CA configuration, split DNS and Wi-Fi/Ethernet transitions. Test simultaneous VMs/containers, subnet conflicts and privilege loss. Teardown removes only owned rules and returns host DNS/routes/firewall to expected state; environmental outages are distinct from a broken guest NIC.

**Why:** VPN and sleep transitions are common production events.

**Check:** Change VPN/Wi-Fi, conflict ports, remove helpers and restart daemon; observe bounded recovery with no unintended inbound exposure.

#### A24.3 — Enforce share semantics and containment

- [ ] **Action:** Verify read-only/writable granted roots, path traversal/symlink containment, rename/unlink/open-file behavior, permissions, case/Unicode handling, xattrs and timestamp semantics supported by each guest share mechanism.

**Required cases:** Include hard links, rename-over-open, UID mapping, sparse files, locks, fsync, mmap, directory replacement/path races and external-volume identity. FUSE xattrs and filesystem-wide sync must actually reach the guest or reject explicitly. Host shares are not universal POSIX storage; keep root filesystems/databases on guest block disks unless required semantics are proven.

**Why:** Host shares expose valuable data to untrusted guest paths.

**Check:** Test traversal/symlinks, grants, permissions, rename/unlink/open handles, Unicode/case/xattrs/timestamps and revoked access with real guest operations.

#### A24.4 — Prove coherence before caching

- [ ] **Action:** Keep zero-TTL/non-DAX as the correctness baseline until cross-host/guest edit coherence is proven. Stress multiple writers, editors/watchers, git/build trees, large files and revocation while requests are in flight.

**Required cases:** Test lost/coalesced FSEvents, watcher overflow, dirty pages, atomic-save rename and root replacement. Qualify stock kernels without Dory notifications separately from managed extensions. Keep DAX deferred until a measured need and complete truncation/permission/granule/revocation/crash semantics are demonstrated; reuse one file service over both transports.

**Why:** Fast stale file data breaks development workflows.

**Check:** Keep zero-TTL/non-DAX baseline; run concurrent edits/watchers/git/builds and in-flight revocation before qualifying any cache optimization.

#### A24.5 — Measure useful share/network recovery

- [ ] **Action:** Measure throughput/latency and recovery under worker death/mount disconnect.

**Why:** Throughput cannot excuse incorrect files or inaccessible services.

**Check:** Under worker/mount loss, verify file checksums and service health first; then measure matched throughput/latency and resource cleanup.

**Card closes when:** effective policy matches observed network/share access, denied roots remain inaccessible and supported development workflows preserve data/coherence.

<a id="a25"></a>

### A25 — Finish guest-tool delivery and desktop integration

**Owner/home:** Rust agent/transports, `GuestTools`, architecture-specific installers and host UI integration.

**Dependencies:** A19/A21/A20.

**Legacy coverage:** P09.

**Starting point:** Guest agent/tool infrastructure exists; complete OS/ISA delivery and ordinary desktop/session qualification remain open.

#### A25.1 — Build and manage tools by guest ISA

- [ ] **Action:** Inventory required tools per OS/ISA, build reproducible artifacts and bind architecture/protocol/version to the machine. Support installation/update/uninstall with restart/rollback and no ambient host-process authority.

**Required cases:** The existing Mac camera application is not a complete general guest agent. Reuse small versioned framing with OS/build/ISA, heartbeat, network addresses and capability negotiation; do not build another general RPC platform.

**Why:** Wrong-architecture or unmanaged agents are not a deployable feature.

**Check:** Reproduce Linux ARM64/x86_64 and Mac ARM64 packages; install/update/uninstall and rollback preserve protocol compatibility and machine binding.

#### A25.2 — Secure bounded tool operations

- [ ] **Action:** Implement bounded machine-authenticated health, shutdown, resize and permitted file/clipboard operations; reconnect after guest/service/daemon restart and reject stale sessions or incompatible messages.

**Why:** Guest tools must not become an ambient host control channel.

**Check:** Test authenticated health/shutdown/resize/permitted transfers, stale sessions, reconnect and malformed requests with bounded resource/time limits.

#### A25.3 — Report absence and failure truthfully

- [ ] **Action:** Make tools absence, denied permission, unsupported feature and unhealthy VM distinct statuses. Installer boot and normal OS boot must not depend on an uninstalled guest agent.

**Why:** Agent failure must not be confused with a dead or healthy VM.

**Check:** Boot/install without tools, deny permissions and break the service; UI shows distinct states while base OS operation remains available.

#### A25.4 — Qualify everyday integration

- [ ] **Action:** Exercise key layouts/modifiers, trackpad/pointer focus, high-DPI scaling, resize, audio playback/recording and clipboard/file transfer with Unicode/large payloads and policy changes.

**Required cases:** Cover dead keys, composed text/IME, key repeat, shortcut capture/release and complete button/key release on disconnect. Clipboard needs type/size bounds, rich text, loop suppression, focus and multi-VM isolation. Drag/drop/file transfer needs cancellation, destination authority, safe overwrite and progress. Test Bluetooth/wired audio routing, mute/unplug, microphone release on stop, camera format/rate/timestamps/buffering, A/V sync and extension update/removal.

**Why:** Layout and payload edge cases defeat happy-path desktop tests.

**Check:** Exercise modifiers/layouts, trackpad focus, DPI/resize, audio and large Unicode clipboard/files with direction and permission changes.

#### A25.5 — Test sessions and recovery

- [ ] **Action:** Test user login/logout and multiple desktop sessions where supported.

**Required cases:** Run VMs with differing clipboard/microphone/camera/share/display policies and verify events never cross machine/session identity. Dedicated-display mode needs a reliable host-window exit route and is not passthrough. Preserve Mac single-display and admitted independent Linux scanout limits.

**Why:** Login changes alter desktop authority and tool lifetime.

**Check:** Log out/in, restart services and exercise admitted multiple sessions; operations reach only their authorized session and recover without debug setup.

**Card closes when:** ordinary desktop/developer journeys work without debug environment setup; tools failure is recoverable and cannot grant unrelated host access.

<a id="a26"></a>

### A26 — Finish app/CLI/API parity and upgrade migration

**Owner/home:** creation/settings/machines UI, `AppStore`, operation projections, CLI and daemon manager.

**Dependencies:** capabilities from A15/A19/A21/A22; can implement UI with explicit unqualified states earlier.

**Legacy coverage:** P12.

**Starting point:** Unified planning and operation infrastructure exists; complete clean/upgrade user journeys and truthful capability/readiness remain open.

#### A26.1 — Unify creation and admission

- [ ] **Action:** Deliver one creation flow for media/ISA/native-versus-translated execution, CPU/RAM/disks, graphics and integration permissions. Detect wrong media and unsupported requests before expensive provisioning.

**Why:** Early validation avoids expensive unusable machines.

**Check:** App/CLI submit equivalent media/resources/graphics policies; wrong ISA and unsupported requests reject before disk provisioning.

#### A26.2 — Expose real operation progress

- [ ] **Action:** Expose observed preparation/install/boot/tools/desktop progress, bounded cancellation, actionable failures and retry/recovery. A launched process cannot turn a slow or failed guest into a green “ready” VM.

**Why:** A running helper is not proof of a ready guest.

**Check:** Simulate slow/hung stages and run real installs; readiness follows observed milestones, cancel is bounded and retry identifies the actual failure.

#### A26.3 — Align lifecycle operations and events

- [ ] **Action:** Align start/stop/reset/pause/suspend/snapshot/clone/import/export/delete semantics and operation IDs across app/CLI/API. Handle reconnect/missed events with daemon snapshots plus versioned events, not divergent UI state caches.

**Required cases:** CLI output needs stable machine-readable results, operation IDs, progress and exit codes; diagnostics stay off normal stdout. Destructive operations identify the machine and affected durable versus volatile data. Do not mutate live topology merely by editing persisted settings.

**Why:** Independent UI caches can contradict durable daemon state.

**Check:** Compare app/CLI/API operation IDs and outcomes; drop events and reconnect, then verify snapshots converge without duplicate actions.

#### A26.4 — Migrate existing installations safely

- [ ] **Action:** Migrate existing definitions/components/catalogs and preserve installed VM data. Reject retired architectures intelligibly; test clean and upgraded accounts, offline boot, component removal, failed update and uninstall preservation.

**Why:** A clean install alone misses existing user data and definitions.

**Check:** Upgrade and rollback representative old accounts; preserve VM disks, reject retired routes intelligibly and boot supported guests offline.

#### A26.5 — Qualify accessible user journeys

- [ ] **Action:** Add automated full user journeys and accessibility/keyboard checks around real backend outcomes.

**Required cases:** Include reduced motion, scalable text, progress/error announcements and guest input while host accessibility features are active. Ordinary setup should show useful capability/error language; renderer tuple hashes and implementation names belong in diagnostics.

**Why:** Required operations must be usable from shipped surfaces.

**Check:** Run creation-to-recovery through real backends plus VoiceOver, keyboard focus/order, contrast and text-size checks; private harnesses cannot close this step.

**Card closes when:** each qualified cell is usable through shipped surfaces with truthful capabilities and no private harness requirement.

<a id="a27"></a>

### A27 — Qualify trust boundaries, isolation and component delivery

**Owner/home:** signing/component import, sandbox policies, parsers, JIT/worker boundaries and release inventory.

**Dependencies:** A00 source fix/admission contract. Begin threat/fuzz/component work early; final packaged checks use the integrated candidate, and must not wait for A30 publication.

**Legacy coverage:** P13.

**Starting point:** The known runner authentication override is removed. Broader packaged trust, parser, resource and component qualification remains open.

#### A27.1 — Map each trust boundary

- [ ] **Action:** Map untrusted media/instructions/queues/GPU commands/shares/tools/local IPC to their validation and resource owner. Audit rights inherited by child processes and granted descriptor/resource revocation.

**Why:** Isolation depends on actual inherited and granted authority.

**Check:** Trace media, decoder, queue, GPU, share, tools and IPC input to validation/limits; inspect real child FDs, environment and revocation behavior.

#### A27.2 — Fuzz parsers and state transitions

- [ ] **Action:** Fuzz bounded parsers and state transitions; test malformed lengths/overflow, malicious archives, stale generations, wrong signatures/architectures, downgrade attempts and conflicting resources. Retain minimized cases and affected runtime regressions.

**Why:** Malformed inputs often escape ordinary functional coverage.

**Check:** Run seeded bounded fuzzing and minimized cases for lengths, archives, signatures, generations and downgrade conflicts; retain crash/time/resource results.

#### A27.3 — Test packaged containment

- [ ] **Action:** Run actual packaged sandbox/entitlement tests and JIT publication/retirement checks. Test resource exhaustion per object, per VM and globally; one guest cannot acquire another VM's backing or authority.

**Why:** Debug entitlement and memory behavior can differ from Release.

**Check:** On signed binaries, exercise JIT W^X and resource exhaustion; one VM cannot access another's backing or escape its admitted sandbox rights.

#### A27.4 — Qualify component delivery

- [ ] **Action:** Verify signed component install/update/rollback from clean and offline accounts, actual linked libraries/RPATHs, SBOM/source provenance and required notices. Review current vendor terms where distribution requires it; never infer license compliance from dependency names alone.

**Required cases:** No runner or guest integration downloads mutable executables at launch; updates are explicit verified transactions and installed machines boot offline. Account for source/notice obligations of Rust, EDK II, Linux, Mesa, virglrenderer, ANGLE, MoltenVK and patches. Use supported Apple restore acquisition and provenance; do not bundle Apple installation media in Dory.

**Why:** Correct source is insufficient if the wrong libraries ship.

**Check:** Install/update/rollback signed components offline and clean; inspect linked dylibs/RPATHs, SBOM, hashes, architectures, deployment targets and notices.

#### A27.5 — Validate diagnostics and close findings

- [ ] **Action:** Inspect support-bundle redaction and diagnostic opt-in for sensitive data.

**Why:** Support artifacts must be useful without exposing private data.

**Check:** Inspect generated bundles for guest/user secrets; reproduce remaining findings and require no unresolved critical/high release defects or auth bypass.

**Card closes when:** no unresolved critical/high-severity defects, no ambient authentication bypass and no unqualified components admitted into release.

<a id="a28"></a>

### A28 — Consolidate obsolete code, stale tasks and active documentation

**Owner/home:** coordinator with affected subsystem owners; build manifests, READMEs and this plan.

**Dependencies:** Each replacement’s focused behavioral/physical parity and migration evidence. Retire incrementally; do not wait for final A29/A30 acceptance before preparing the candidate they test.

**Legacy coverage:** R01–R20, Q08, P12/13/15.

**Starting point:** This rewrite consolidates the roadmap. Code retirement and active documentation/payload validation remain dependent on demonstrated parity.

#### A28.1 — Reconcile status in place

- [ ] **Action:** Reconcile A-step outcomes and the legacy P/R/Q/DONE crosswalk against current code and receipts. Keep implemented-but-unqualified work open. Replace stale next-investigation text and links in place; preserve historical evidence.

**Why:** Repeated progress journals create contradictory assignments.

**Check:** Every closed step links actual evidence and every missing physical gate remains open; no active instruction assigns already completed bootstrap work.

#### A28.2 — Retire redundant execution owners

- [ ] **Action:** Inventory duplicate native/device/control ownership and production QEMU/legacy helpers using call sites, built artifacts and process inventory. Remove only after replacement parity and migration; preserve test-only external comparators and attribution accurately.

**Why:** Dead or competing paths increase maintenance and migration risk.

**Check:** Audit R01–R20 call sites, package products and processes; remove a path only after replacement behavior and persisted-data migration pass.

#### A28.3 — Replace spelling tests and stale links

- [ ] **Action:** Retire source-spelling tests and private fixture-only production branches after equivalent behavioral/security coverage. Resolve stale package README links to deleted architecture documents using the relevant PLAN section or current build contract.

**Why:** Source wording is not a durable safety assertion.

**Check:** Equivalent behavioral negatives fail when intentionally broken; active README/build/help links resolve after obsolete documents and branches are removed.

#### A28.4 — Prune actual shipping payloads

- [ ] **Action:** Remove unused entitlements, dependencies and build jobs; run affected build/package checks and inspect actual shipped payloads. Preserve immutable historical evidence and its old paths as historical references where necessary.

**Why:** Deleting source alone may leave obsolete binaries or privileges.

**Check:** Inspect built archive, nested entitlements, linked dependencies and CI jobs; preserve required ABI fixtures and immutable historical results.

#### A28.5 — Keep one live roadmap

- [ ] **Action:** Keep this as the only active roadmap.

**Why:** Future agents need a single authoritative next action.

**Check:** PLAN task IDs, dependencies and current evidence agree with source; optional deferred cleanup has an owner and cannot conceal a release blocker.

**Card closes when:** no release-critical obsolete path, no contradicted active assignment, and each deferred optional cleanup has an explicit owner/dependency.

## Qualification and release

<a id="a29"></a>

### A29 — Run frozen performance and reliability campaigns

**Owner/home:** qualification owner plus CPU/GPU/OS reviewers; existing Linux performance schemas/live gates and Mac campaign.

**Dependencies:** Calibration/matrix work starts with A01. Full campaigns require the applicable implementation, A27 security and A28 candidate payload for each cell; do not require A30 publication.

**Legacy coverage:** P14, Q01–08.

**Starting point:** Historical development measurements exist. Frozen exact-candidate physical matrix, budgets and endurance do not yet pass.

#### A29.1 — Freeze budgets before judging results

- [ ] **Action:** Calibrate and freeze numerical budgets for every advertised cell before judging the release candidate. Keep the performance-contract targets as targets until validated; record allowed resources, resolutions, workload versions and measurement boundaries. Do not lower budgets after seeing a failing candidate.

**Why:** Moving thresholds after failure produces meaningless qualification.

**Check:** Commit matrix, workload versions, resources, resolutions, counters and numeric budgets; reviewer approves calibration before candidate samples run.

#### A29.2 — Establish correctness first

- [ ] **Action:** Run correctness before speed: independent instruction/guest checks, shader pixels/compute output, storage checksums and actual effective GPU identities. Collect end-to-end boot/input/presentation/RPC, CPU throughput, I/O, code cache, worker/VM resource and energy/thermal observations separately.

**Why:** Fast corrupted output or software rendering is a failed result.

**Check:** CPU/reference, pixels/compute, storage checksums and actual GPU identity pass before timing; report CPU/GPU/presentation/RPC separately.

#### A29.3 — Run controlled comparisons

- [ ] **Action:** Use cold/warm repeated runs, balanced order and attributable process accounting. Compare ARM/Mac to matched same-guest native virtualization references and x86 to a pinned full-system translated reference; retain absolute latency even when relative performance looks favorable.

**Why:** Cache, order and resource differences can dominate measured speed.

**Check:** Retain repeated cold/warm balanced samples, complete process accounting and matched references; report distributions and absolute latency, including timeouts.

#### A29.4 — Complete physical endurance

- [ ] **Action:** Complete the frozen physical matrix: oldest admitted host class, midrange/high-resource classes, supported host OS branches, two distro families per Linux ISA, selected Mac builds, 1/2/4/8 admitted CPUs, RAM/storage variants and concurrent VMs. Run at least 100 lifecycle cycles and a 48-hour mixed workload per required composition, with frozen suspend/restore and active-GPU failure counts.

**Why:** Short successful probes miss resource leaks and recovery races.

**Check:** Execute the frozen host/guest/resource matrix, at least 100 lifecycle cycles and 48-hour workloads per required composition; retain all failure samples.

#### A29.5 — Validate the exact integrated candidate

- [ ] **Action:** Validate install→guest update→Dory update→recovery and failure injection on the exact signed candidate.

**Why:** Results from different builds cannot be combined into one release pass.

**Check:** Run update/recovery/failure journeys on the candidate bytes; validate raw manifests, budget results and reclamation, blocking any unavailable required cell.

**Card closes when:** raw artifacts validate, frozen budgets pass, resources reclaim, no unexpected crash/data corruption remains and every failed sample is accounted for. Missing hardware/metrics blocks the affected claim.

<a id="a30"></a>

### A30 — Qualify and publish the exact release

**Owner/home:** release coordinator, existing workflow/catalog/support owners.

**Dependencies:** All required CPU/GPU/native/Mac/container and A23–A29 acceptance, including C01–C11. Candidate assembly can precede its A29 run; publication waits for exact-candidate qualification and explicit authorization.

**Legacy coverage:** P15, DONE-01–14.

**Starting point:** Release automation exists; this task does not authorize publication and no cell is yet qualified for the programme finish line.

#### A30.1 — Build the release candidate

- [ ] **Action:** Build the candidate from reviewed source with locked dependencies and refreshed component manifests; verify nested signatures, entitlements, notarization/Gatekeeper behavior and clean-machine installation. Bind qualification to exact bytes, not just a version string.

**Required cases:** Inspect the actual archive for developer probes, unused backends, debug traces and obsolete privileged dependencies. Validate stapling, nested entitlements and embedded dependencies on clean physical hardware; a standalone signed probe is supplementary.

**Why:** Signatures and provenance apply to exact artifacts.

**Check:** Verify reviewed source, locks, manifests, nested signing, notarization and clean-machine Gatekeeper install; record downloadable artifact digests.

#### A30.2 — Exercise public activation

- [ ] **Action:** Exercise production catalog/download/activation, actual launchd daemon, UI/CLI and all supported guest profiles on that candidate. No private catalog, authentication bypass or unnotarized helper substitutes for release-path acceptance.

**Why:** Private catalog and helper paths may bypass production requirements.

**Check:** Use actual launchd daemon, production downloads/catalog and shipped UI/CLI for all guest profiles; candidate identity matches A29 evidence.

#### A30.3 — Generate accurate capability claims

- [ ] **Action:** Generate public capabilities/limits from qualified results. Keep optional codec, GPU compute API, nested virtualization, live-save and CPU extension limits explicit; remove universal native-speed/universal-x86 claims.

**Why:** Marketing must not imply untested ISA, graphics or platform support.

**Check:** Derive support from qualified rows; review each optional API, extension, live-save and performance claim against its actual evidence and limits.

#### A30.4 — Validate upgrade and support closure

- [ ] **Action:** Verify update/rollback, component compatibility, recovery support bundles and public documentation. Freeze known limitations and confirm none contradict a required DONE gate.

**Required cases:** Run support drills for failed install, no desktop, GPU loss, network failure, incompatible saved state and corrupt media. Each redacted diagnostic must identify a tested recovery action and owner. Verify download interruption, upgrade from the last supported release and uninstall data preservation.

**Why:** Release users need recoverable updates and diagnosable failures.

**Check:** Test update/rollback, components and redacted support bundles; documentation covers recovery and no known limitation contradicts a required finish gate.

#### A30.5 — Publish only the qualified bytes

- [ ] **Action:** Use the existing `scripts/publish-release.sh <version>` workflow only when release publication is authorized and all applicable gates pass. Verify all distribution surfaces serve the same candidate.

**Required cases:** Check app archive/DMG, component catalog, update metadata, package managers, website and evidence assets against one release identity using the existing whole-release workflow. Tag candidate/plan evidence. Windows is a separate future programme after this release is stable.

**Why:** Final distribution must match what passed qualification.

**Check:** With publication authorization, run the existing workflow, download every distribution surface and compare digests plus evidence archives before closing DONE gates.

**Card closes when:** all DONE items have evidence/reviewer sign-off, shipped claims match the tested product and no release-critical task is left hidden behind “experimental.”

## Performance and reliability contract

A29 owns final qualification; A02/A09/A10/A14/A17 supply subsystem measurements. The numbers below are **initial engineering targets**, not achieved results. A01/A29 calibrate and freeze numeric budgets per admitted host/resource/guest/profile before evaluating a release candidate. If a target proves unrealistic, explicitly change scope/resource class with reviewed rationale before a new campaign; do not lower it after failure to manufacture a pass.

| Dimension | Initial target / decision rule | Measurement boundary |
|---|---|---|
| Native CPU microbenchmark | At least 95% throughput of equivalent host-native code and at least 97% of minimal HV/VZ orchestration where a valid comparator exists | Release executable, repeated matched loops and broader compute cases; no desktop inference |
| Native whole-workload overhead | Target within 10% of the same guest workload/resources on a minimal/qualified same-host native-virtualization reference | Build, compression, language runtime and interactive applications; each reported separately |
| x86 translated compute | Target at least 20% geometric-mean improvement over the pinned full-system reference suite, with no key workload more than 10% worse; also meet absolute interactive budgets | Identical x86 guest/image/compiler/resources; keep this as an ambition until measured |
| Linux/Mac display at 1080p60 | Under a specified normal interactive workload, p95 frame interval ≤16.7 ms, p99 ≤33.4 ms, and ≤1% missed 60 Hz deadlines | Continuously demanded updates through completed host presentation; exclude intentional idle frames and freeze refresh/timestamp tolerance before measuring |
| Input-to-visible-update | Target p95 ≤50 ms and p99 ≤100 ms on the declared desktop profile | Injected input to verified changed frame; no IPC-only latency claims |
| Resize-to-stable-content | Target p95 ≤250 ms after final resize event for normal desktop workload | Correct guest resolution/scale and completed nonstale presentation |
| Installed cold boot | Initial target ≤30 s ARM Linux, ≤60 s macOS, ≤120 s x86 Linux to the defined ready point | Fixed disk/cache/resource state; installer and deliberate filesystem-repair cases separate |
| Idle behavior | Target total attributable VM/helper CPU ≤5% of one host core for an idle desktop; headless target ≤2%; no busy polling | Fixed sampling interval with host/guest workload state recorded |
| Storage and network | Target ≥90% of comparable same-host baseline throughput; no more than 10% p95 regression at matched queue depth/concurrency | Correct data, identical durability/MTU/offload/cache policy, not guest-cache bandwidth |
| Memory and resources | Freeze per-profile guest RAM + host overhead + DBT/GPU budgets; no unbounded growth; resources return within a declared grace period after stop | Attributed physical footprint and resource objects; no double-counting shared mappings |
| Reliability | Zero data-corruption/checksum errors and zero unexpected VM/worker crashes in the required campaign | Failures remain recorded; retry does not erase an unsuccessful observation |

For 4K, high refresh and multiple Linux displays, define separate resource classes, workloads and timing tolerance. Freeze guest RAM, host overhead, JIT cache, GPU/worker memory, allocation/FD/thread ceilings and stop-reclamation grace periods numerically. Any uncalibrated required ceiling remains a release blocker.

### Physical matrix and execution order

1. Freeze oldest admitted Apple Silicon/resource class, midrange and high-resource hosts, every supported OS/API branch and a deliberate low-memory case. Keep beta host/guest evidence separate.
2. Include at least two general-purpose distro families per Linux ISA plus diagnostic fixtures; list each marketed version/kernel/Mesa/compositor explicitly. Select compatible Mac guest builds and retain restore provenance.
3. Cover admitted 1/2/4/8 CPUs, small/typical/large RAM, one/multiple VMs, internal/qualified external drives, offline launch and network changes. Unsupported resources must reject rather than silently change the profile.
4. First validate CPU/fault correctness, guest GPU identity and output, storage checksums, effective permissions and actual application health. Then collect boot, RPC, input, presentation, throughput, footprint, thermal and energy results separately.
5. Run at least 100 start/stop/reboot cycles per required cell and a 48-hour mixed desktop/development workload on each release-critical composition. Freeze additional suspend/restore, active-GPU loss and reset counts in the manifest before execution.
6. Include install → installed boot → tools → guest update → Dory update → rollback/recovery. Inject disk full, process/worker loss, host restart and data-drive disconnect using disposable owned fixtures.
7. Retain all failures, timeouts and raw samples. A fix reruns the minimized failure and affected end-to-end gate. Relevant artifact/config changes invalidate their old qualification; unavailable hardware or metrics block the corresponding claim.

### Existing container performance and reliability gates

These remain required even after the three VM cells work. Full-VM and container results cannot substitute for one another. A17 supplies compatibility/GPU correctness; A29 owns the controlled campaigns; A30 verifies the published evidence bytes.

#### C01 — Bind immutable candidate inputs (P14-C01)

- [ ] **Action:** Use the exact extracted notarized candidate, source/build/release-manifest/SBOM/archive digests and app/helper/kernel/rootfs/agent/component identities. Every comparison image must be immutable `@sha256:` content with matching platform, layers and lockfiles.

**Why:** A release label does not identify executable bytes.

**Check:** Verify all app/helper/kernel/rootfs/agent/component and image digests against the extracted notarized candidate before any timing.

#### C02 — Match benchmark environments (P14-C02)

- [ ] **Action:** Run on a dedicated physical Apple Silicon benchmark account. The destructive isolated campaign runs one engine at a time, with matched **6 vCPU/6 GiB** and each product's recorded defaults. Compare the selected Dory, OrbStack and Colima versions; additional products require the same protocol.

**Why:** Different engine allocations invalidate product comparisons.

**Check:** Use an isolated dedicated account and recorded versions; verify 6 vCPU/6 GiB matched runs and each product’s defaults separately.

#### C03 — Balance repeated execution (P14-C03)

- [ ] **Action:** Run a separate same-session matched interleaved campaign with at least **nine balanced rounds**. Record exact settings and resource allocation; invalidate comparisons with different content/architecture, memory differing by more than 5%, mutable fixtures or invalid cleanup.

**Why:** Order, caches and content can create false wins.

**Check:** Retain at least nine balanced rounds; reject architecture/content mismatches, >5% memory mismatch, mutable inputs or invalid cleanup.

#### C04 — Run the actual developer workloads (P14-C04)

- [ ] **Action:** Cover npm/pnpm offline dependency installs, Rails/Bundler and Composer bind workflows, cold/cached native ARM64 and amd64 BuildKit builds, framework watchers, Compose/Testcontainers readiness, warm lifecycle, cold start/wake and controlled external HTTPS/DNS/TCP/TLS.

**Why:** Microbenchmarks cannot replace ordinary development work.

**Check:** Each named workflow executes real work and records completion outputs, health and readiness rather than only subsystem counters.

#### C05 — Check correctness before elapsed time (P14-C05)

- [ ] **Action:** Verify exact trees/lockfiles, service health, watcher events, durable markers and teardown before accepting timing. Separate cache generation, cold pulls, offline installs, warm lifecycle, internal networking and external networking.

**Why:** Fast incomplete work is a failure.

**Check:** Compare exact trees/lockfiles, service state, watcher events, markers and teardown; label cold/cache/pull/network boundaries separately.

#### C06 — Reuse the existing harness owners (P14-C06)

- [ ] **Action:** Keep the existing harness responsibilities: `benchmark-user-workflows.sh`, `benchmark-developer-workflows.sh`, `benchmark-registry-npm.sh`, `benchmark-external-network.sh`, `benchmark-campaign.sh`, and `qualify-container-engine-performance.sh`. Keep workload and evidence requirements here; the campaign archive carries executable protocol inputs and results, not a copy of the changing roadmap.

**Why:** Duplicating harnesses creates incompatible definitions of success.

**Check:** Inspect the listed current scripts and archive the executable protocol inputs/results; keep the changing roadmap only here.

#### C07 — Apply statistical claim rules (P14-C07)

- [ ] **Action:** Preserve raw samples, median, quartiles, range, variation and order. A parity description requires medians within 10% and overlapping distributions; a claimed win requires >10% median improvement with nonoverlapping bootstrap 95% confidence intervals from the matched campaign. Otherwise report the observed gap/inconclusive result.

**Why:** A noisy small gap is not a measured win.

**Check:** Preserve samples/order/distributions and bootstrap intervals; apply the exact parity/win criteria in the action and report inconclusive cases.

#### C08 — Account for all resources (P14-C08)

- [ ] **Action:** Measure attributable physical footprint for the full process set, reclaim, guest RAM, threads/FDs, watcher backlog and disk growth. Keep subsystem counters diagnostic unless the actual user workflow also ran.

**Why:** Moving work into helpers can hide overhead.

**Check:** Measure full-process physical footprint and guest/cache/watcher/disk growth; user workload and cleanup evidence accompany diagnostic counters.

#### C09 — Complete long reliability runs (P14-C09)

- [ ] **Action:** Preserve the separate reliability obligation: eight-hour resource/file/API endurance and more-than-24-hour unchanged TCP connection, using the existing 25-hour evidence run. Any correctness error or linear unbounded growth fails the campaign.

**Why:** Short successful tests miss leaks and connection loss.

**Check:** Verify eight-hour file/API/resource endurance and a continuous >24-hour TCP connection using the 25-hour run; correctness errors or linear growth fail.

#### C10 — Assemble durable evidence archives (P14-C10)

- [ ] **Action:** Publish `Dory-<version>-container-engine-performance-evidence.zip` and `Dory-<version>-reliability-evidence.zip` bound to the same candidate. Performance ZIP includes `manifest.json`, deterministic `sha256.txt`, raw harness results, generated summaries, cleanup and redaction reports; reliability ZIP includes duration completion, candidate binding and raw endurance/connection results.

**Why:** Temporary CI logs are not a reproducible release record.

**Check:** Validate manifests, deterministic digest lists, raw samples, summaries, duration, cleanup/redaction and candidate bindings in both ZIPs.

#### C11 — Reverify downloaded publication (P14-C11)

- [ ] **Action:** Reverify both evidence families in publication after artifact download, against source/run/build/manifest/archive identity, then publish their digests with the release. Missing/failed/skipped/wrong-candidate evidence blocks claims. Temporary CI artifacts are not the stable public record.

**Why:** Uploaded evidence may not match what users can download.

**Check:** Download both archives and the candidate, recompute identities/digests and reject missing, failed, skipped or mismatched required evidence.

Correctness, coherence, durability and host permissions cannot be weakened for a benchmark. Preserve the existing selected full-system translation reference for x86 VM comparisons; FEX/Rosetta application measurements are different execution models. Native comparisons must use the same guest work and resources, with a declared valid HV/VZ reference.

## Retirement inventory

A28 owns this inventory with the affected subsystem reviewer. These are removal/migration obligations, not blanket deletion authorization. R01–R04 already have bounded replacements; confirm production call sites and remaining qualification. R11 specifically preserves and finishes existing PC authority rather than deleting needed GPU code. A path is retired only after persisted-state migration, behavioral parity, affected guest tests and shipping-payload inspection pass.

| Priority / ID | Candidate | Action | Prerequisite and proof |
|---|---|---|---|
| Now / R01 | Kernel-address tracing and local-image assumptions in PC bring-up | Move useful trace facilities behind explicit diagnostic configuration; remove hardcoded kernel PCs and unconditional output | P02 pinned boot fixtures and structured failure traces reproduce failures |
| Now / R02 | Blanket Xen CPUID and successful unimplemented hypercalls | Remove impersonation/workarounds; support only a documented minimal PVH contract or a genuinely implemented explicit Xen profile | PVH entry without false capabilities; negative hypercall and memory-size tests |
| Now / R03 | ELF address masks and unqualified section loading | Replace with validated boot-format mapping and segment/zero-fill rules | Multiple kernels, malformed inputs, relocation/high-memory tests |
| Now / R04 | Tests that depend on local `/tmp` files or lack successful-boot assertions | Replace with assertions and explicit fixture availability; move manual experiments out of ordinary unit tests | Required integration job fails when its fixture is absent; optional local test reports skipped |
| Early / R05 | Source-text tests requiring QEMU policy or fixed prose headings | Delete those assertions after structured backend/capability/evidence checks exist | Old unsupported routes reject; release manifest and artifact audit still enforce the actual policy |
| Early / R06 | x86 macOS / Intel-host planning, UI options, components and production branches | Remove unreachable production options and build wiring; retain only explicit legacy-definition rejection where needed | Linux x86 guest support remains; importing an old definition is safe and intelligible |
| Early / R07 | Generic VZLinux/custom-VZ-GPU experiments competing with DoryARMVirt | Keep only a bounded reference/legacy compatibility adapter until migration is qualified; exclude experimental engines from normal resolution | Existing installed Linux users retain a tested migration/recovery path |
| Early / R08 | Duplicate native-HV CPU ownership in `DoryHV/Machine.swift` and `DoryNativeHVArm64` | Converge through an adapter or extraction; remove the redundant production candidate after parity | ARM direct and UEFI boot, stop/reset/suspend, interrupts and resource tests pass |
| Early / R09 | Duplicate old/new virtio devices | Select the mature behavior as reference, port into shared core, delete superseded core and adapters | Same device vectors and real Linux traces pass over MMIO and PCI |
| Early / R10 | In-process legacy renderer/executor in raw `VirtioGPU.swift` used by test fakes | Replace fakes with worker-channel test doubles; delete test-only production rendering branches | Worker protocol tests cover equivalent failure/fence/reset behavior; no real call sites remain |
| Early / R11 | `DoryPCVirGLRendererAuthority` production qualification | Retain the existing authority, scanout bridge and resource/generation tests while P06 connects the required PC GPU path. Delete only after a shared replacement preserves behavior. | Real PC worker authority, asynchronous completion and accelerated guest output; a dead-code deletion cannot close the GPU requirement. |
| Early / R12 | Hardcoded dual-capset/kernel tuple policy | Replace with typed authenticated profiles with explicit guest synchronization requirements | Unsupported profile combinations still reject; no capability is advertised without implementation |
| Early / R13 | Monolithic `MachineManager.swift`, `DesktopMode.swift`, `Machine.swift` responsibilities | Extract operation-specific implementations and immutable projections while deleting duplicate logic | Behavioral tests stay at public operation boundaries; extraction does not add another coordinator chain |
| Early / R14 | Repeated little-endian/wire utility code and serialization wrappers | Share a small checked binary utility where behavior is identical; remove redundant codecs | Byte fixtures, bounds/overflow and backward-compatibility tests |
| Later / R15 | Legacy QEMU execution, image-helper, binfmt and control dependencies | Retire actual runtime dependencies and unused build paths based on call-site evidence; preserve standards-compatible transport implementations, truthful migration messages and attribution | No actual QEMU production dependency remains; package, process and linked-binary inventory checked; name-only references classified accurately |
| Later / R16 | Competing legacy and typed lifecycle models | Migrate existing definitions/operations once, then delete redundant planners, caches and state transitions | Interrupted migration/restart/rollback corpus passes without data loss |
| Later / R17 | Probe executables and one-off benchmark entrypoints in release package graph | Move to developer/test targets; retain focused reproducible qualification tooling | Shipping artifact inventory excludes probes; CI still has necessary tools |
| Later / R18 | Manually curated “pass” receipts, schema-only certification and obsolete evidence | Remove as authority; keep historical immutable inputs only where useful for regression | Candidate identity, actual commands/results and validated raw artifacts establish every pass |
| Later / R19 | Platform options that cannot be implemented with public macOS APIs | Remove dead UI toggles and false capability flags; report exact unsupported reason | Capabilities match built configuration on every supported host/guest tuple |
| Later / R20 | Optimizations without measured benefit or correct fallback | Remove or leave disabled behind internal experiments; retain only benchmarked wins | Correctness and p95/p99/resource results justify keeping each optimization |

## Legacy coverage and completion rules

A00–A30 are now the only primary implementation checklist. The table below migrates all P00–P15 obligations; R01–R20 remain in the retirement inventory, Q01–Q08 remain the verification rules, and DONE-01–14 remain the final release gates. Historical P03 checkmarks based on probe evidence do not mean A18 production qualification is complete. Preserve old IDs in issue cross-references rather than maintaining a second editable phase checklist.

| Earlier phase | Current owners | Required closing proof |
|---|---|---|
| <a id="phase-p00"></a>P00 | A01/A28/A29 | Reproducible baseline, scoped support matrix, evidence and budgets. |
| <a id="phase-p01"></a>P01 | A00/A01/A26/A27 | One effective plan, trustworthy handoff and daemon-owned operation projection. |
| <a id="phase-p02"></a>P02 | A03–A08 | Full declared CPU forms/state/faults with independent reference and real Linux work. |
| <a id="phase-p03"></a>P03 | A18 | One native owner, precise traps, lifecycle/SMP/GIC/PSCI, direct and UEFI parity. |
| <a id="phase-p04"></a>P04 | A05/A10/A12/A13/A20 | Correct DMA, queues, interrupts, PCI/MMIO and concurrent device behavior. |
| <a id="phase-p05"></a>P05 | A19 | Firmware and ordinary installation, detached-media boot, updates and recovery. |
| <a id="phase-p06"></a>P06 | A11–A17 | Hardware GL/Vulkan desktops and standard native/translated container compute. |
| <a id="phase-p07"></a>P07 | A02/A09/A10 | Useful measured translated performance, bounded JIT and parallel TSO-correct SMP. |
| <a id="phase-p08"></a>P08 | A21/A22/A23 | Production Mac install, identity, lifecycle, policy, Metal and recovery. |
| <a id="phase-p09"></a>P09 | A20/A22/A25 | Daily input/audio/display/tools/session workflows with correct policy. |
| <a id="phase-p10"></a>P10 | A23 | Durable data operations and actual interrupted restore/clone/import drills. |
| <a id="phase-p11"></a>P11 | A24 | Observed network isolation/connectivity and coherent contained host shares. |
| <a id="phase-p12"></a>P12 | A15/A26 | Truthful app/CLI/API creation, operations, readiness and upgrade migration. |
| <a id="phase-p13"></a>P13 | A00/A01/A27/A28 | Packaged authority/isolation, compatible pinned components and shipping inventory. |
| <a id="phase-p14"></a>P14 | A02/A09/A14/A17/A29; C01–C11 | Frozen whole-workload budgets, physical matrix, sustained VM/container evidence. |
| <a id="phase-p15"></a>P15 | A28/A29/A30 | Exact signed/notarized distribution, accurate claims and no remaining required gate. |

### Q01–Q08: review rules carried forward

| Rule | Apply before closing a step |
|---|---|
| Q01 | CPU/device fixes have minimized regression and affected real-guest rerun; durable changes have interruption/recovery checks. |
| Q02 | Immutable external fixture identity and acquisition are explicit; required absence fails, optional absence visibly skips. |
| Q03 | Tests check outputs, faults, lifecycle and resources, not preferred source text or prose. |
| Q04 | Versioned ABI/serialization fixtures protect actual compatibility and have one owner. |
| Q05 | Supported sanitizer/race/fuzz runs cover native concurrency and parsers; unsupported tooling is reported as unavailable. |
| Q06 | Long physical campaigns are separate required pre-release jobs on owned isolated fixtures/accounts. |
| Q07 | Optimization requires correct output and credible whole-workload improvement without unacceptable tail/resource regression. |
| Q08 | Deletion removes real call sites and migrates persistence, while equivalent safety behavior retains tests. |

## Final completion gates

A30 closes these only from reviewed candidate-bound evidence. A required capability cannot disappear into an “experimental” label, and one qualified cell cannot stand for all three. Optional limitations must not contradict the scope above.

- [ ] **DONE-01** Apple Silicon is the sole product host; Linux ARM64, Linux x86_64 and macOS ARM64 are the only guest cells in this programme.

- [ ] **DONE-02** Each cell installs from its supported ordinary media, reboots without installer dependence, updates, shuts down and recovers through the app and CLI.

- [ ] **DONE-03** ARM Linux uses the consolidated native Dory runtime; x86 Linux uses DoryDBT/DoryPC; Mac uses the supported VZMac path. No hidden QEMU runtime or architecture substitution remains.

- [ ] **DONE-04** Both Linux ISAs have qualified guest OpenGL and Vulkan acceleration; Mac has qualified guest Metal; Docker containers have qualified GPU compute through the same isolated renderer architecture. Effective application/renderer evidence rules out accidental software rendering.

- [ ] **DONE-05** The baseline, x86-64-v2 and declared v3/AVX2 CPU profiles in Scope, memory/fault/XSTATE semantics, interrupts/timers, device queues and actual parallel x86 execution pass the required correctness and independent-reference tests. Unsupported optional extensions are explicitly unadvertised.

- [ ] **DONE-06** Display/input, storage/network, sound, shares and supported tools work through daily desktop/developer journeys. Optional capabilities and public API limits are accurately represented.

- [ ] **DONE-07** Requested privacy/device/network policy equals actual configuration; disabled integrations cannot operate.

- [ ] **DONE-08** Cold snapshots, clone/export/import, backup restore, safe upgrade and interruption recovery preserve guest data and correct identity. Any unsupported live-save capability is explicitly unavailable.

- [ ] **DONE-09** Performance budgets are frozen and met for every advertised host/guest/profile; translated CPU performance is reported separately and native-speed claims are workload-specific.

- [ ] **DONE-10** Sustained physical campaigns, failure injection, multi-VM pressure and exact signed/notarized release validation pass with retained evidence.

- [ ] **DONE-11** Obsolete implementations, false-success stubs, fixed-address diagnostics, duplicate owners and expired compatibility scaffolding identified in the retirement inventory are removed or have an explicit remaining dependency and owner; release-critical ones are gone.

- [ ] **DONE-12** The existing container product retains its required correctness, compatibility, data safety, performance and reliability gates.

- [ ] **DONE-13** Public capabilities and release metadata match the qualified product, support can reproduce/repair failures, and no unresolved release-critical defects remain.

- [ ] **DONE-14** This is the only active team implementation/architecture plan. New work updates its checklist and evidence instead of rebuilding the old document sprawl.

## Agent assignment template

Use a bounded step or card; fill the brackets before assigning. A proposed new source/test file is not an instruction to add a package when an existing owner fits. Release publication requires explicit publication authorization; implementation and local verification should proceed within the assigned scope.

> Execute **[Axx.n — step title]** from PLAN.md on **[source revision]**. Read its starting point, dependencies, action, reason and acceptance check. Own **[exact files/modules]**; coordinate shared interfaces with **[owner/reviewer]**. Prerequisites are **[IDs, candidate and immutable fixtures]**. Preserve **[existing behavior/evidence]**. Implement through **[production entrypoint]**, add the smallest meaningful regression, then run **[verified focused command]** and **[required guest/failure workload]**. Use disposable owned resources and the storage discipline above. Record raw results and the standard receipt, including skips and remaining boundaries. Commit the focused change and update this step in place; report changed behavior, verification, limits and the next unblocked step. Do not widen feature claims, disable authority, silently use software graphics, or mark missing physical evidence passed.

### The next useful assignments

1. **A01.1–A01.4:** reconcile producer/deployment targets, validate evidence, freeze matrix and reacquire only necessary owned fixtures.
2. **A00.3–A00.4:** qualify packaged daemon authentication and repair legitimate physical-harness activation.
3. **A02.1–A02.3:** obtain a current x86 boot/RPC cost breakdown. In parallel workstreams, **A03.1–A03.4** defines finite CPU gaps and **A08.1–A08.2** prepares an independent oracle.
4. **A18.2–A18.4:** qualify the reviewed ARM behavior through production guest register/lifecycle/IRQ tests and direct/UEFI paths.
5. **A21.1–A21.4:** move existing private Mac success through actual daemon/catalog installation and interrupted save/restore/discard recovery.
6. **A12.1–A12.3** and then **A11.1–A11.4:** establish shared fence/resource semantics and the first trustworthy PC hardware frame. **A16.1–A16.3** can independently repair default FEX compatibility.

These are assignments, not claims that any campaign ran during the plan rewrite. Advance only the relevant checks as their implementation and evidence become available.
