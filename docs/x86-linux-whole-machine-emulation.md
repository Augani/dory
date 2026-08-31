# x86_64 Linux whole-machine translation contract

- **Decision date:** 2026-08-30
- **Normative plan:**
  [`linux-and-macos-virtualization-delivery-plan.md`](linux-and-macos-virtualization-delivery-plan.md)
- **Only product host:** Apple-silicon Mac
- **Guest scope:** Qualified x86_64 UEFI Linux installation media and installed systems
- **Execution engine:** `DoryDBTX86ToARM64`
- **Machine:** `DoryPC-v1` (`dory.pc@1`)
- **Status:** Implementation and qualification in progress; unavailable to production resolution

## Supersession notice

The 2026-08-26 draft of this document proposed a QEMU/TCG product path. That proposal is
superseded and non-normative. Dory does not ship, invoke, link, download, persist, or silently
substitute QEMU. Historical reasoning remains available in repository history and in the dated
evidence document, but it is not an implementation instruction.

## Product contract

Dory runs x86_64 Linux on Apple silicon through its own full-system translator and virtual PC:

```text
inspected x86_64 Linux media
            |
            v
DoryDBTX86ToARM64 + dory.x86_64.compat-v1
            |
            v
DoryPC-v1 + dory.edk2.pc@1 + dory.virtio@1
```

The resolver must fail before download, workspace mutation, disk allocation, or runner launch
when the host is not Apple silicon, media is not structurally compatible, a required signed Dory
component is absent, or the exact guest tuple has not reached its declared support tier. There is
no alternate QEMU backend and no process-level translator fallback.

“Compatible x86_64 Linux media” means media whose inspected architecture, firmware boot path, and
required drivers match a published qualification tuple. It does not mean every historical ISO,
legacy BIOS image, architecture-neutral filename, or kernel configuration.

## Required composition

1. **DoryDBT CPU execution.** The interpreter is the executable architecture oracle. Baseline and
   optimizing ARM64 JIT tiers preserve identical architectural state, faults, ordering, clocks,
   interrupts, paging, and invalidation behavior. Unsupported CPUID features remain absent.
2. **Frozen Dory PC.** `DoryPC-v1` supplies the documented memory map, ACPI/SMBIOS, APIC/IOAPIC,
   clocks, PCIe, USB, reset, power, and stable VirtIO PCI topology. All execution tiers use the
   same machine ABI.
3. **Dory firmware.** Product boot starts at the Dory EDK II reset vector with immutable firmware,
   a crash-safe per-VM variable store, deterministic boot projection, provenance, and recovery.
4. **Owned media and disks.** Media is inspected by content and fingerprinted before mutation.
   Installation media is read-only; system-disk creation, sparse growth, flush, discard, ENOSPC,
   repair, and rollback remain transaction-bound.
5. **Complete desktop devices.** Storage, network, display, keyboard, mouse, trackpad, sound,
   microphone, camera, USB, entropy, sockets, clipboard, and sharing use Dory-owned device cores,
   brokers, renderer, and guest protocols. Stock installer access cannot depend on guest tools.
6. **Truthful graphics.** The baseline is a qualified firmware/software framebuffer. VirGL OpenGL
   and Venus Vulkan are advertised only when the complete renderer, fencing, scanout, resize,
   recovery, and guest-driver tuple passes its independent hardware-acceleration gate.
7. **Durable lifecycle.** Install, eject, cold boot, update, recovery, pause, resume, stop,
   force-stop, snapshot, clone, rollback, crash recovery, and component rollback are operation-
   journaled and bind exact ABI and artifact identities.

The frozen guest-visible ABI is documented in
[`virtualization/dory-pc-v1-abi.md`](virtualization/dory-pc-v1-abi.md).

## Qualification gate

Production exposure remains fail-closed until the exact signed and notarized candidate physically
qualifies representative Ubuntu LTS, Debian stable, Fedora Workstation, and Arch/Omarchy x86_64
media on the supported low-, middle-, and high-tier Apple-silicon host matrix.

Each tuple must prove clean installation, installer ejection, repeated cold boot, update, recovery,
terminal and desktop workloads, storage durability, networking, display resize and assignment,
input, audio, camera, USB, clipboard, sharing, snapshots, rollback, hostile-guest containment,
resource pressure, long-duration stability, and published translated-performance budgets.

Receipts bind the Dory app/controller/runner, CPU profile, execution tier, machine, firmware,
variable store, device ABI, renderer, media, disk, guest build, host hardware, and macOS build.
Passing a boot smoke test does not change the public support tier.

## Current engineering boundary

Direct-kernel and UEFI smoke tools are internal qualification instruments. They may establish
instruction, firmware, bus, or device evidence but are not production backends. The planner,
persisted definition authority, UI, CLI, agent API, and component catalog continue to reject an
unqualified x86_64 Linux launch with a stable reason rather than exposing a hidden flag.

The older native-x86 Hypervisor.framework path may be compiled only as an internal physical-x86
comparison harness. It is not linked into public artifacts and never makes an Intel Mac eligible
for this product.

## Primary specifications

- [Intel 64 and IA-32 Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [UEFI specifications](https://uefi.org/specifications)
- [PCI Express specifications](https://pcisig.com/specifications)
- [ACPI specifications](https://uefi.org/specifications)
- [VirtIO specifications](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
- [Apple: porting JIT compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)
