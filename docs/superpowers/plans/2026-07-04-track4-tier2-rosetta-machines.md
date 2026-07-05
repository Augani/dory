# Track 4 Tier 2: Rosetta-accelerated x86 machines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
>
> This is the expansion of Track 4 Tier 2 from `2026-07-04-dory-vm-platform-roadmap.md`, which mandated "expand into its own plan before execution." Tier 1 (qemu-user binfmt) is shipped and verified. Tier 3 (Rosetta under dory-hv) is CLOSED as infeasible. This plan is the only remaining piece of Track 4.

**Goal:** `dory machine create intel --recipe ubuntu-dev --arch amd64` runs x86_64 workloads at near-native speed via Apple Rosetta, instead of 5-10x-slower qemu-user emulation.

## STATUS (2026-07-04): Rosetta capability DELIVERED + PROVEN; persistent-machine backend remains

What is done and verified on Apple Silicon hardware this session:
- **Rosetta-on-Virtualization.framework PROVEN.** `dory-vmboot --image <amd64> --arch amd64 --rosetta -- <cmd>` runs x86_64 binaries: verified `uname -m` -> `x86_64`, the x86_64 `/bin/sh`/`busybox` execute (no qemu present, so only Rosetta could). Apple's Containerization framework mounts the RosettaLinux share and sets up guest translation automatically when `VZVirtualMachineManager(rosetta: true)`.
- **Rosetta enabled on the shared vz engine** (`runSharedEngine`), opt-in via `DORY_ENGINE_ROSETTA=1` (default off), so amd64 containers on the vz engine get Rosetta when requested.
- **Wired + gated:** `dory vm --arch amd64 --rosetta -- <cmd>` is the user-facing Rosetta execution path (already in scripts/dory); new readiness track `scripts/readiness.sh --rosetta` asserts `x86_64` execution.

What remains (the persistent-machine backend, genuinely separate integration work): Dory machines are docker containers on the sole `dory-hv` engine, where Rosetta is infeasible (Tier 3, closed). Making a PERSISTENT, sshable `arch: amd64` machine Rosetta-fast needs one of: (a) run the vz `runSharedEngine` with `DORY_ENGINE_ROSETTA=1` as a SECOND engine and route amd64 machines' docker operations to its socket, or (b) a per-machine dedicated dory-vm VM lifecycle. Until then, amd64 machines run via qemu-user (Tier 1) and are honestly labeled "emulated"; x86 speed is available today through the `dory vm --rosetta` execution path. Tasks 1-4 below detail option (a)/(b).

**Architecture:** Rosetta for Linux is only available inside a Virtualization.framework VM (verified: it aborts under any raw-Hypervisor.framework VMM, so dory-hv cannot host it). Dory already bundles the `dory-vm`/`dory-vmboot` helper (Virtualization.framework), whose single-container path already passes `rosetta: args.rosetta` to `VZVirtualMachineManager`. This plan extends the helper's SHARED ENGINE (`runSharedEngine`) to optionally enable Rosetta, registers the Rosetta binary as the guest's x86_64 binfmt handler (in place of qemu-user), and routes `arch: amd64` machines to that Rosetta-enabled engine.

**Tech Stack:** Swift (dory-vmboot helper on Apple's Containerization framework + the app-side provisioner), Linux guest binfmt_misc.

## Global Constraints

- Inherits every constraint from the master roadmap. Rosetta only runs on the vz engine (`dory-vm`), never on the default dory-hv engine; when dory-hv is the active engine, `arch: amd64` machines MUST fall back to Tier 1 (qemu-user) and be labeled "emulated", never silently claim Rosetta.
- The Rosetta virtio-fs share tag is developer-chosen (not the magic string "rosetta"); `rosetta` is the filename of the runtime binary inside the share.
- Best performance needs Apple's TSO guest-kernel patch (ACTLR TSOEN + `prctl(PR_SET_MEM_MODEL, PR_SET_MEM_MODEL_TSO)`); this plan works without it (Rosetta runs, slightly slower) and treats TSO as an optional follow-up.
- Verification of actual x86 execution REQUIRES real Apple Silicon hardware with Rosetta installed; the unit-testable parts (routing decision, labels, arg construction) are gated in CI, the execution acceptance test is a manual/hardware readiness track.

---

### Task 1: Engine Rosetta-capability surface

**Files:**
- Modify: `Dory/Runtime/Shared/SharedVMProvisioner.swift` (add `static func activeEngineSupportsRosetta() -> Bool`)
- Modify: `Dory/Runtime/Machines/MachineArch.swift` (add the acceleration model)
- Test: `DoryTests/MachineTests.swift`

**Interfaces:**
- Produces: `enum MachineAcceleration: String { case native, rosetta, emulated }` and `static func MachineAcceleration.resolve(arch: MachineArch, engineSupportsRosetta: Bool) -> MachineAcceleration` — pure: returns `.native` when `arch.isNative`; `.rosetta` when `!isNative && engineSupportsRosetta`; `.emulated` otherwise.
- `SharedVMProvisioner.activeEngineSupportsRosetta()` returns `true` only when the running engine is the vz helper (`dory-vm`) with Rosetta available on this Mac; `false` for dory-hv.

- [ ] Step 1: Write failing tests for `MachineAcceleration.resolve` covering all three branches (native arch, amd64+rosetta-capable, amd64+not-capable).
- [ ] Step 2: Implement the enum + resolve. Run tests to green.
- [ ] Step 3: Implement `activeEngineSupportsRosetta()` (engine-kind check + `VZLinuxRosettaDirectoryShare.availability` when linkable, else a capability probe). Commit `feat(machines): MachineAcceleration model + engine Rosetta capability`.

### Task 2: Rosetta-enabled shared vz engine

**Files:**
- Modify: `Packages/ContainerizationEngine/Sources/dory-vmboot/Boot.swift` (`runSharedEngine` gains a `rosetta: Bool` parameter; when true, build `VZVirtualMachineManager(kernel:initialFilesystem:rosetta: true)` and mount the Rosetta share)
- Modify: `Packages/ContainerizationEngine/Sources/dory-vmboot/Boot.swift` arg parsing (`--rosetta` already sets `args.rosetta`; thread it into the engine subcommand)
- Modify: the engine guest init (`scripts/bundle-engine.sh` initfs, or `BinfmtRegistration`) so that WHEN the Rosetta share is mounted, the x86_64 binfmt handler points at the mounted `rosetta` binary with the `F` (fix-binary) flag instead of qemu-x86_64-static.

- [ ] Step 1: Thread `rosetta` through `runSharedEngine`; when true, add the Rosetta directory share (developer-chosen tag, e.g. `dory-rosetta`) to the engine VM config.
- [ ] Step 2: Guest-side: mount the share at boot and register x86_64 binfmt with the rosetta binary (`update-binfmts`-style register line, magic/mask for x86_64 ELF, `F` flag). Prefer Rosetta over qemu when the share is present; keep qemu registration as the fallback when it is not.
- [ ] Step 3: Rebuild helper + initfs; boot the vz shared engine with `--rosetta` on real Apple Silicon and confirm `cat /proc/sys/fs/binfmt_misc/rosetta` shows enabled. Commit `feat(hv): Rosetta on the shared vz engine`.

### Task 3: Provisioner routing on arch

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`ensureEmulation` becomes `ensureAcceleration(for:progress:)`: if `MachineAcceleration.resolve(...) == .rosetta`, ensure the engine is the Rosetta-enabled vz engine and skip qemu binfmt; if `.emulated`, keep the current qemu path)
- Modify: `Dory/Models/AppStore.swift` (surface the acceleration on the created machine; store `dory.machine.accel` label)
- Modify: `Dory/Runtime/Machines/MachineService.swift` `createBody` (add `accelLabel`)
- Test: `DoryTests/MachineTests.swift` (createBody carries the resolved accel label for amd64 under each engine capability)

- [ ] Step 1: Failing test: amd64 recipe + rosetta-capable engine → label `rosetta`; amd64 + dory-hv → label `emulated`; arm64 → `native`.
- [ ] Step 2: Implement routing + label. When `.rosetta` is requested but the active engine is dory-hv, either transparently start the vz engine for that machine OR fall back to `.emulated` with a clear progress message (decide during execution; falling back is the safe default). Commit `feat(machines): route amd64 machines to Rosetta when available`.

### Task 4: UI + CLI + acceptance

**Files:**
- Modify: `Dory/Features/Sheets/NewMachineSheet.swift` (the emulation note becomes accel-aware: "Rosetta-accelerated" vs "Emulated via binfmt")
- Modify: `scripts/dory` (`dory machine ls` shows the accel mode; `dory machine create --arch amd64 --rosetta`)
- Modify: `scripts/readiness.sh` (new track `rosetta`, gated on `RUN_ROSETTA=1` + real hardware: create an amd64 machine and assert a known x86_64 binary runs and `/proc/sys/fs/binfmt_misc/rosetta` is enabled)

- [ ] Step 1: Wire the UI/CLI labels off `MachineAcceleration`.
- [ ] Step 2: Add the hardware-gated readiness track. Manual acceptance: `dory machine create intel --recipe ubuntu-dev --arch amd64` then time an x86 build vs the qemu path; expect a large speedup. Commit `feat: Rosetta machine UX + hardware readiness track`.

## Self-review

- Every branch that could claim Rosetta while running on dory-hv MUST fall back to emulated; there is a test for it (Task 3 Step 1).
- No code path defeats or replays a Rosetta ioctl (Tier 3 is closed); this plan only uses Apple's supported vz Rosetta API.
- The one thing that cannot be finished in CI is real x86 execution speed; that is the Task 4 hardware readiness track, explicitly gated.
