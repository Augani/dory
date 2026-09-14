import DoryExecutionContracts

public enum DoryPCV1RegionKind: String, Codable, CaseIterable, Sendable, Hashable {
  case pvhHandoff = "pvh-handoff"
  case acpiTables = "acpi-tables"
  case smbios = "smbios"
  case pcieMMIO = "pcie-mmio"
  case pcieECAM = "pcie-ecam"
  case firmwareConfiguration = "firmware-configuration"
  case firmwareVariables = "firmware-variables"
  case ioAPIC = "io-apic"
  case hpet
  case localAPIC = "local-apic"
  case firmwareCode = "firmware-code"
}

public struct DoryPCV1Region: Codable, Sendable, Hashable {
  public let kind: DoryPCV1RegionKind
  public let range: DoryGuestAddressRange

  public init(kind: DoryPCV1RegionKind, base: UInt64, byteCount: UInt64) throws {
    self.kind = kind
    range = try .init(base: base, byteCount: byteCount)
  }
}

/// Frozen guest-visible machine contract shared by the x86 interpreter and every JIT tier.
public enum DoryPCV1ABI {
  public static let identity = "dory.pc@1"
  public static let schemaVersion: UInt32 = 1
  public static let firmwareABIIdentity = "dory.edk2.pc@1"
  public static let variableStoreFormatIdentity = "dory.uefi.variables.pc@1"
  public static let variableBridgeIdentity = "dory.uefi.variable-bridge.pc@1"

  // P2-01 item 4 — Guest-physical layout vs host mapping granule:
  //
  // The x86 guest uses 4-KiB pages. On Apple Silicon the host page size is 16 KiB.
  // DoryDBT's stage-2 mapping uses the host page size, so every 4-KiB guest page is
  // backed by a 16-KiB host mapping. This means:
  //   - Guest RAM is mapped at 16-KiB granularity; 4-KiB-aligned guest addresses within
  //     the same 16-KiB host page share one host mapping.
  //   - MMIO regions (PCIe MMIO, ECAM, IOAPIC, HPET, local APIC, firmware) are at
  //     4-KiB boundaries in the guest physical map but are backed by 16-KiB host
  //     mappings. The DBT memory provider must handle 4-KiB guest-page faults within
  //     a 16-KiB host page correctly (see DoryX86MmapMemory).
  //   - Shared-memory apertures (renderer blob mappings, filesystem workers) use the
  //     host page size for backing. Guest 4-KiB pages within a shared 16-KiB host page
  //     are all accessible to the worker that mapped the host page.
  //   - Huge pages (2 MiB, 1 GiB) are not used in v1; all RAM is mapped at the host
  //     page size. Guest huge-page requests are satisfied by mapping multiple host
  //     pages.
  //
  // P2-01 item 2 — Reserved ranges:
  //
  // PCIe ECAM (0xE000_0000, 256 MiB) and PCIe MMIO (0xD000_0000, 256 MiB) are active
  // in ABI v1: the PCI host bridge enumerates devices and the guest discovers them
  // via ACPI/PNP0A03. All BAR addresses are allocated from the frozen PCIe MMIO
  // aperture. USB (xHCI at device 7) is active when a USB controller is instantiated.
  // GPU (VirtIO GPU at device 2) is active when a graphics device is instantiated.
  // A device slot that is not instantiated is a reservation: the PCI address is
  // allocated but no device function is exposed to the guest.
  //
  // P2-01 item 6 — Migration behavior:
  //
  // The ABI identity ("dory.pc@1") and schemaVersion (1) are persisted with each
  // VM's configuration. On reopen, the firmware configuration block stores
  // schemaVersion and rejects a mismatched version before any disk mutation.
  // A newer schema version is rejected, not silently reinterpreted as v1.
  // This ensures an old machine is never silently reinterpreted as a different
  // platform. Migration to a newer ABI requires an explicit upgrade path that is
  // not yet implemented; until then, a version mismatch is a hard error.

  public static let minimumProductMemoryBytes: UInt64 = 512 << 20
  public static let maximumMemoryBytes: UInt64 = 512 << 30
  public static let maximumVCPUCount = 255

  /// Guest-page granularity for region ownership. The x86 guest uses 4-KiB pages, so
  /// every region base must be 4-KiB-aligned and each region exclusively owns the guest
  /// pages its range rounds up to. This is a guest-layout contract only; it does not
  /// depend on the host page size or mapping granule.
  public static let guestPageBytes: UInt64 = 0x1000
  public static let minimumGuestPhysicalAddressBits: UInt8 = 36
  public static let maximumGuestPhysicalAddressBits: UInt8 = 40

  public static let pvhStartInfo: UInt64 = 0x0009_0000
  public static let pvhCommandLine: UInt64 = 0x0009_1000
  public static let pvhModules: UInt64 = 0x0009_2000
  public static let pvhMemoryMap: UInt64 = 0x0009_3000
  public static let pvhHandoffBytes: UInt64 = 0x0000_4000
  public static let lowRAMEnd = pvhStartInfo
  public static let lowReservedEnd: UInt64 = 0x000A_0000
  public static let acpiBase: UInt64 = 0x0009_E000
  public static let acpiBytes: UInt64 = 0x0000_2000
  public static let smbiosBase: UInt64 = 0x000F_0000
  public static let smbiosBytes: UInt64 = 0x0001_0000
  public static let highRAMStart: UInt64 = 0x0010_0000
  public static let directKernelInitrd: UInt64 = 0x1000_0000

  public static let pcieMMIOBase: UInt64 = 0xD000_0000
  public static let pcieMMIOBytes: UInt64 = 0x1000_0000
  public static let pcieECAMBase: UInt64 = 0xE000_0000
  public static let pcieECAMBytes: UInt64 = 0x1000_0000
  public static let mmioHoleStart = pcieMMIOBase
  public static let above4GRAMStart: UInt64 = 0x1_0000_0000

  public static let firmwareConfigurationBase: UInt64 = 0xFE90_0000
  public static let firmwareConfigurationBytes: UInt64 = 0x0000_1000
  public static let firmwareVariableBase: UInt64 = 0xFEA0_0000
  public static let firmwareVariableBytes: UInt64 = 0x0020_0000
  public static let ioAPICBase: UInt64 = 0xFEC0_0000
  public static let ioAPICBytes: UInt64 = 0x1000
  public static let hpetBase: UInt64 = 0xFED0_0000
  public static let hpetBytes: UInt64 = 0x400
  public static let localAPICBase: UInt64 = 0xFEE0_0000
  public static let localAPICBytes: UInt64 = 0x1000
  public static let firmwareCodeBase: UInt64 = 0xFF00_0000
  public static let firmwareCodeBytes: UInt64 = 0x0100_0000
  public static let uefiResetAddress: UInt64 = 0xFFFF_FFF0

  public static let pciINTxFirstGSI: UInt8 = 16
  public static let pciINTxLineCount: UInt8 = 8
  public static let systemDiskPCIAddress = DoryPCPCIAddress(bus: 0, device: 1, function: 0)
  public static let displayPCIAddress = DoryPCPCIAddress(bus: 0, device: 2, function: 0)
  public static let keyboardPCIAddress = DoryPCPCIAddress(bus: 0, device: 3, function: 0)
  public static let pointerPCIAddress = DoryPCPCIAddress(bus: 0, device: 4, function: 0)
  public static let tabletPCIAddress = DoryPCPCIAddress(bus: 0, device: 5, function: 0)
  public static let soundPCIAddress = DoryPCPCIAddress(bus: 0, device: 6, function: 0)
  public static let xhciPCIAddress = DoryPCPCIAddress(bus: 0, device: 7, function: 0)
  public static let networkPCIAddress = DoryPCPCIAddress(bus: 0, device: 8, function: 0)
  public static let entropyPCIAddress = DoryPCPCIAddress(bus: 0, device: 9, function: 0)
  public static let vsockPCIAddress = DoryPCPCIAddress(bus: 0, device: 10, function: 0)
  public static let maximumFileSystemShareCount = 8
  public static let fileSystemPCIAddresses: [DoryPCPCIAddress] = [
    DoryPCPCIAddress(bus: 0, device: 11, function: 0),
    DoryPCPCIAddress(bus: 0, device: 13, function: 0),
    DoryPCPCIAddress(bus: 0, device: 14, function: 0),
    DoryPCPCIAddress(bus: 0, device: 15, function: 0),
    DoryPCPCIAddress(bus: 0, device: 16, function: 0),
    DoryPCPCIAddress(bus: 0, device: 17, function: 0),
    DoryPCPCIAddress(bus: 0, device: 18, function: 0),
    DoryPCPCIAddress(bus: 0, device: 19, function: 0),
  ]
  public static let removableMediaPCIAddress = DoryPCPCIAddress(bus: 0, device: 12, function: 0)
  public static let systemDiskBARAddress = pcieMMIOBase
  public static let removableMediaBARAddress = pcieMMIOBase + 0x1000
  public static let displayBARAddress = pcieMMIOBase + 0x2000
  public static let keyboardBARAddress = pcieMMIOBase + 0x3000
  public static let pointerBARAddress = pcieMMIOBase + 0x4000
  public static let tabletBARAddress = pcieMMIOBase + 0x5000
  public static let soundBARAddress = pcieMMIOBase + 0x6000
  public static let xhciBARAddress = pcieMMIOBase + 0x8000
  public static let networkBARAddress = pcieMMIOBase + 0xC000
  public static let entropyBARAddress = pcieMMIOBase + 0xD000
  public static let vsockBARAddress = pcieMMIOBase + 0xE000
  public static let fileSystemBARAddresses: [UInt64] = (0..<maximumFileSystemShareCount).map {
    pcieMMIOBase + 0xF000 + UInt64($0) * 0x1000
  }

  public static let regions: [DoryPCV1Region] = [
    fixedRegion(kind: .pvhHandoff, base: pvhStartInfo, byteCount: pvhHandoffBytes),
    fixedRegion(kind: .acpiTables, base: acpiBase, byteCount: acpiBytes),
    fixedRegion(kind: .smbios, base: smbiosBase, byteCount: smbiosBytes),
    fixedRegion(kind: .pcieMMIO, base: pcieMMIOBase, byteCount: pcieMMIOBytes),
    fixedRegion(kind: .pcieECAM, base: pcieECAMBase, byteCount: pcieECAMBytes),
    fixedRegion(
      kind: .firmwareConfiguration,
      base: firmwareConfigurationBase,
      byteCount: firmwareConfigurationBytes
    ),
    fixedRegion(
      kind: .firmwareVariables,
      base: firmwareVariableBase,
      byteCount: firmwareVariableBytes
    ),
    fixedRegion(kind: .ioAPIC, base: ioAPICBase, byteCount: ioAPICBytes),
    fixedRegion(kind: .hpet, base: hpetBase, byteCount: hpetBytes),
    fixedRegion(kind: .localAPIC, base: localAPICBase, byteCount: localAPICBytes),
    fixedRegion(kind: .firmwareCode, base: firmwareCodeBase, byteCount: firmwareCodeBytes),
  ]

  public static func interruptLine(device: UInt8, pin: UInt8) -> UInt8 {
    precondition(device < 32 && (1...4).contains(pin))
    return pciINTxFirstGSI &+ ((device &+ pin &- 1) % pciINTxLineCount)
  }

  public static func guestPhysicalAddressBits(memoryBytes: UInt64) -> UInt8 {
    precondition(memoryBytes > 0 && memoryBytes <= maximumMemoryBytes)
    let highRAMBytes = memoryBytes > mmioHoleStart ? memoryBytes - mmioHoleStart : 0
    let requiredUpperBound = above4GRAMStart + highRAMBytes
    let requiredBits = UInt8(UInt64.bitWidth - (requiredUpperBound - 1).leadingZeroBitCount)
    return min(max(requiredBits, minimumGuestPhysicalAddressBits), maximumGuestPhysicalAddressBits)
  }

  public static func guestPhysicalAddressSpaceBytes(memoryBytes: UInt64) -> UInt64 {
    1 << guestPhysicalAddressBits(memoryBytes: memoryBytes)
  }

  public static func validateProductMemoryBytes(_ byteCount: UInt64) throws {
    guard byteCount >= minimumProductMemoryBytes else {
      throw DoryPCV1ABIError.memoryBelowMinimum(
        minimum: minimumProductMemoryBytes,
        actual: byteCount
      )
    }
    guard byteCount <= maximumMemoryBytes else {
      throw DoryPCV1ABIError.memoryAboveMaximum(maximum: maximumMemoryBytes, actual: byteCount)
    }
    guard byteCount % (2 << 20) == 0 else {
      throw DoryPCV1ABIError.unalignedMemory(byteCount)
    }
  }

  public static func validateVCPUCount(_ count: Int) throws {
    guard (1...maximumVCPUCount).contains(count) else {
      throw DoryPCV1ABIError.invalidVCPUCount(maximum: maximumVCPUCount, actual: count)
    }
  }

  /// Validates the frozen region list for overlaps, integer overflow, and alignment.
  /// Called at construction time to ensure the physical address map is well-formed before
  /// any guest memory is mapped. The frozen regions are compile-time constants, so this
  /// validator catches accidental ABI edits that would create overlapping reservations.
  public static func validateRegions() throws {
    try Self.validateRegions(regions)
  }

  /// Validates an arbitrary region list against the guest-page ownership contract.
  /// Each region's byteCount must be positive (DoryGuestAddressRange already checks
  /// end overflow at construction) and its base must be aligned to `guestPageBytes`.
  /// A region's guest-page coverage runs from its containing page through its end
  /// rounded up to the next page boundary; no two regions may share a guest page, so
  /// a sub-page reservation such as the frozen 1-KiB HPET window is valid only when
  /// no other region lands in its page. Page-ownership is checked on the caller's
  /// input before base alignment is enforced, so a region that intrudes into another
  /// region's page is reported as a sharing violation rather than only an unaligned
  /// base. Detection is independent of caller order: a checked local view is sorted
  /// by base address before neighboring coverages are compared, so an unsorted list
  /// cannot hide a shared page between non-adjacent regions. The caller-owned layout
  /// is never reordered or mutated; only the validation view is sorted.
  public static func validateRegions(_ regions: [DoryPCV1Region]) throws {
    for region in regions {
      guard region.range.byteCount > 0 else {
        throw DoryPCV1ABIError.zeroLengthRegion(kind: region.kind)
      }
    }
    let sorted = regions.sorted { $0.range.base < $1.range.base }
    for pair in zip(sorted, sorted.dropFirst()) {
      guard pair.1.range.base.rawValue >= guestPageCoverageEnd(of: pair.0.range) else {
        if pair.0.range.overlaps(pair.1.range) {
          throw DoryPCV1ABIError.overlappingRegions(
            previous: pair.0.range,
            current: pair.1.range
          )
        }
        throw DoryPCV1ABIError.regionsShareGuestPage(
          previous: pair.0.range,
          current: pair.1.range
        )
      }
    }
    for region in regions {
      guard region.range.base.rawValue.isMultiple(of: guestPageBytes) else {
        throw DoryPCV1ABIError.misalignedRegionBase(
          kind: region.kind,
          base: region.range.base,
          requiredAlignment: guestPageBytes
        )
      }
    }
  }

  /// Exclusive end of a region's guest-page coverage: the range end rounded up to the
  /// next `guestPageBytes` boundary, saturating at UInt64.max instead of overflowing.
  private static func guestPageCoverageEnd(of range: DoryGuestAddressRange) -> UInt64 {
    let end = range.endExclusive.rawValue
    let remainder = end % guestPageBytes
    guard remainder != 0 else { return end }
    let (rounded, overflow) = (end - remainder).addingReportingOverflow(guestPageBytes)
    return overflow ? UInt64.max : rounded
  }

  public static let markdown = """
    # DoryPC-v1 ABI

    Identity: `dory.pc@1`

    This file is the checked-in projection of `DoryPCV1ABI`. Guest-visible changes require a new machine identity. The x86 interpreter, baseline ARM64 JIT, and optimizing JIT use this same contract.

    ## Physical address map

    | Region | Base | Reserved bytes |
    |---|---:|---:|
    | PVH handoff | `0x00090000` | `0x00004000` |
    | ACPI tables | `0x0009e000` | `0x00002000` |
    | SMBIOS discovery | `0x000f0000` | `0x00010000` |
    | RAM above low reservations | `0x00100000` | to the PCI MMIO hole |
    | PCIe MMIO | `0xd0000000` | `0x10000000` |
    | PCIe ECAM | `0xe0000000` | `0x10000000` |
    | Firmware configuration | `0xfe900000` | `0x00001000` |
    | Firmware-variable bridge | `0xfea00000` | `0x00200000` |
    | IOAPIC | `0xfec00000` | `0x00001000` |
    | HPET | `0xfed00000` | `0x00000400` |
    | Local APIC | `0xfee00000` | `0x00001000` |
    | Firmware code | `0xff000000` | `0x01000000` |
    | RAM remapped above 4 GiB | `0x0000000100000000` | variable |

    UEFI resets at `0xfffffff0`, uses firmware ABI `dory.edk2.pc@1`, and persists variables as `dory.uefi.variables.pc@1`. Product launches accept 512 MiB through 512 GiB in 2 MiB increments and 1...255 logical processors. The host reservation is a power-of-two guest-physical space selected from 36 through 40 address bits for the admitted RAM size.

    ## Interrupt and PCI contract

    The IOAPIC exposes GSIs 0...23. PCI INTx uses level-triggered, active-low GSIs 16...23 with standard device/pin swizzling. MSI and MSI-X target the local APIC window. PCIe ECAM covers segment 0, buses 0...255. BAR MMIO is allocated from the frozen 256 MiB PCIe aperture. The VirtIO GPU advertises PCI class `03:80` (display-other), never VGA class `03:00`; Dory does not expose a legacy VGA framebuffer.

    | Boot device | PCI address | BAR 0 |
    |---|---:|---:|
    | System disk | `0000:00:01.0` | `0xd0000000` |
    | Removable installer media | `0000:00:0c.0` | `0xd0001000` |
    | VirtIO GPU | `0000:00:02.0` | `0xd0002000` |
    | VirtIO keyboard | `0000:00:03.0` | `0xd0003000` |
    | VirtIO relative pointer | `0000:00:04.0` | `0xd0004000` |
    | VirtIO absolute tablet | `0000:00:05.0` | `0xd0005000` |
    | VirtIO sound | `0000:00:06.0` | `0xd0006000` |
    | xHCI USB controller | `0000:00:07.0` | `0xd0008000` |
    | VirtIO network | `0000:00:08.0` | `0xd000c000` |
    | VirtIO entropy | `0000:00:09.0` | `0xd000d000` |
    | VirtIO socket | `0000:00:0a.0` | `0xd000e000` |
    | VirtIO filesystem share 0 | `0000:00:0b.0` | `0xd000f000` |
    | VirtIO filesystem shares 1...7 | `0000:00:0d.0`...`0000:00:13.0` | `0xd0010000`...`0xd0016000` |

    ## Boot contract

    Direct-kernel PVH remains an engineering and managed-image profile. Product installation starts at the UEFI reset vector, discovers ACPI/SMBIOS, boots removable media according to persistent UEFI boot variables, and then boots the installed system disk. Firmware code is immutable per launch; each VM owns an atomic variable store.

    Before UEFI executes, the launch authority atomically projects the validated device order into
    standard `Boot####` and `BootOrder` variables under the EFI global-variable GUID. Dory-owned load
    options contain an active whole-device path of `ACPI(PNP0A03,0)/PCI(function,device)` and private
    optional-data marker `DORYPC1\\0<logical-id>`. New Dory options allocate from `BootD000` through
    `BootDFFF` without replacing an occupied guest option. Existing Dory options are reused by marker;
    stale or duplicate Dory-owned options are removed. Guest-created options and their relative
    `BootOrder` are retained after the launch plan's physical-device fallbacks. An unchanged projection
    does not advance the variable-store generation, and a store requiring backup recovery cannot boot
    until recovery is explicitly completed.

    ## Execution-tier firmware gate

    `dory-pc-uefi-smoke` must reach the firmware-owned `DORY-PC-UEFI-BOOT` marker and ACPI power-off
    under the interpreter, baseline JIT, and optimizing JIT with the same zero RTC epoch, memory size,
    processor count, firmware bundle, runner, and in-memory boot disk. Preserve each JSON receipt, then
    issue the comparison receipt with:

    ```sh
    swift run -c release --package-path dory-core-swift dory-pc-tier-qualification \\
      --interpreter-receipt /absolute/evidence/interpreter.json \\
      --baseline-jit-receipt /absolute/evidence/baseline-jit.json \\
      --optimizing-jit-receipt /absolute/evidence/optimizing-jit.json \\
      --output /absolute/evidence/tier-qualification.json
    ```

    The `dory.pc-uefi-tier-equivalence@1` verifier fails closed unless all three receipts bind the
    same runner, firmware/SBOM/NVRAM identities, configuration, exact retired-instruction count,
    power-off reason, full architectural-state digest, marker, and serial output. It also proves that
    each requested JIT tier actually retired instructions in that tier. This gate establishes the
    deterministic firmware baseline; installer, installed-disk, update, recovery, device, workload,
    and performance qualification remain separate Phase 5 evidence.
    """

  private static func fixedRegion(
    kind: DoryPCV1RegionKind,
    base: UInt64,
    byteCount: UInt64
  ) -> DoryPCV1Region {
    do {
      return try .init(kind: kind, base: base, byteCount: byteCount)
    } catch {
      preconditionFailure("Invalid fixed DoryPC-v1 region: \(error)")
    }
  }
}

public enum DoryPCV1ABIError: Error, Sendable, Equatable {
  case memoryBelowMinimum(minimum: UInt64, actual: UInt64)
  case memoryAboveMaximum(maximum: UInt64, actual: UInt64)
  case unalignedMemory(UInt64)
  case invalidVCPUCount(maximum: Int, actual: Int)
  case zeroLengthRegion(kind: DoryPCV1RegionKind)
  case misalignedRegionBase(
    kind: DoryPCV1RegionKind,
    base: DoryGuestPhysicalAddress,
    requiredAlignment: UInt64
  )
  case overlappingRegions(previous: DoryGuestAddressRange, current: DoryGuestAddressRange)
  case regionsShareGuestPage(previous: DoryGuestAddressRange, current: DoryGuestAddressRange)
}
