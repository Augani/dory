# ContainerizationEngine — Dory's in-process VM engine (framework integration)

This package is the foundation of Dory's **next engine architecture**: instead of running `dockerd`
inside a VM launched by Apple's `container` CLI (the shipping "shared VM" backend), Dory drives the
Linux VM **directly** via Apple's [`containerization`](https://github.com/apple/containerization)
Swift framework + Virtualization.framework. It is a **separate package** so the shipping
`Dory.xcodeproj` app stays stable while this large integration is built and proven.

## Why this exists — it unblocks the last OrbStack features

The `container` CLI hides the low-level VM controls these features need. The framework exposes them
as first-class API (see `ContainerizationVMEngine.swift`):

| Blocked OrbStack feature | Framework capability used |
|---|---|
| **Rosetta-fast x86** | `ContainerManager(rosetta: true)` — native Rosetta, far faster than the qemu binfmt fallback |
| **Reverse / bidirectional file mounts** | `Mount.share(source:destination:)` — host↔guest virtiofs in either direction |
| **USB / audio passthrough** | `VZVirtualMachineManager` + `LinuxContainer.Configuration` device config (Virtualization.framework) |
| **Dynamic memory balloon** | direct `memoryInBytes` + Virtualization.framework memory-balloon control |
| Self-contained packaging | no external `container` toolchain — kernel + initfs bundled, VM spawned in-process |

## Status

- Engine scaffold (`ContainerizationVMEngine`) implemented against the real framework API
  (`Kernel` + `ContainerManager` + `LinuxContainer`, mirroring the framework's own `cctl run`).
- Package **resolves**; build verifies the API usage compiles here.

## Wiring into Dory (the remaining multi-week work)

1. Build this package green (in progress).
2. Add a `ContainerizationRuntime: ContainerRuntime` adapter mapping Dory's protocol
   (`snapshot/create/start/stop/exec/logs/...`) onto `ContainerManager`/`LinuxContainer`.
3. Bundle a Linux kernel + `vminit` initfs in the app (the framework needs them to boot).
4. Add it as a `RuntimeKind.containerization` backend selectable in `AppStore.connectBackend`,
   alongside the shared-VM default — so it can be hardened without disrupting the shipping engine.
5. Move Rosetta, reverse mounts, USB/audio, and ballooning onto this backend.

This is the deliberate, additive path to 100% feature-for-feature parity: the working product keeps
shipping on the shared-VM engine while the framework engine matures behind a backend switch.
