import DoryExecutionContracts

public enum DoryARMVirtV1RegionKind: String, Codable, CaseIterable, Sendable, Hashable {
  case firmwareCode
  case firmwareVariables
  case gicDistributor
  case gicRedistributors
  case uart
  case rtc
  case powerController
  case virtioMMIO
  case pcieECAM
  case pcieMMIO
}

public enum DoryARMVirtV1BootProtocol: String, Codable, CaseIterable, Sendable, Hashable {
  case directLinux = "direct-linux"
  case uefi
}

public struct DoryARMVirtV1Region: Codable, Sendable, Hashable {
  public let kind: DoryARMVirtV1RegionKind
  public let range: DoryGuestAddressRange

  public init(kind: DoryARMVirtV1RegionKind, base: UInt64, byteCount: UInt64) throws {
    self.kind = kind
    self.range = try DoryGuestAddressRange(base: base, byteCount: byteCount)
  }
}

public enum DoryARMVirtV1DeviceRole: String, Codable, CaseIterable, Sendable, Hashable {
  case systemDisk = "system-disk"
  case graphics
  case entropy
  case balloon
  case vsock
  case keyboard
  case pointer
  case audio
  case network
  case auxiliaryStorage = "auxiliary-storage"
  case directoryShare = "directory-share"
  case usbController = "usb-controller"
  case reserved
}

public struct DoryARMVirtV1VirtioSlot: Codable, Sendable, Hashable {
  public let index: Int
  public let baseAddress: UInt64
  public let byteCount: UInt64
  public let spi: UInt32
  public let interruptID: UInt32
  public let role: DoryARMVirtV1DeviceRole

  public init(
    index: Int,
    baseAddress: UInt64,
    byteCount: UInt64,
    spi: UInt32,
    interruptID: UInt32,
    role: DoryARMVirtV1DeviceRole
  ) {
    self.index = index
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    self.spi = spi
    self.interruptID = interruptID
    self.role = role
  }
}

public enum DoryARMVirtV1ABI {
  public static let identity = "dory.armvirt@1"
  public static let schemaVersion: UInt32 = 1
  public static let minimumMemoryBytes: UInt64 = 1 << 30
  public static let maximumVCPUCount = 256

  public static let firmwareCodeBase: UInt64 = 0x0000_0000
  public static let firmwareCodeBytes: UInt64 = 0x0400_0000
  public static let firmwareVariableBase: UInt64 = 0x0400_0000
  public static let firmwareVariableBytes: UInt64 = 0x0400_0000
  public static let firmwareABIIdentity = "dory.edk2.armvirt@1"
  public static let variableStoreFormatIdentity = "dory.uefi.variables.armvirt@1"
  public static let uefiResetAddress = firmwareCodeBase
  public static let directLinuxDeviceTreeRegister: UInt8 = 0
  public static let gicDistributorBase: UInt64 = 0x0800_0000
  public static let gicDistributorReservedBytes: UInt64 = 0x0001_0000
  public static let gicRedistributorBase: UInt64 = 0x080a_0000
  public static let gicRedistributorReservedBytes: UInt64 = 0x0200_0000
  public static let uartBase: UInt64 = 0x0c00_0000
  public static let uartBytes: UInt64 = 0x1000
  public static let uartSPI: UInt32 = 1
  public static let uartInterruptID: UInt32 = 32 + uartSPI
  public static let rtcBase: UInt64 = 0x0c09_0000
  public static let rtcBytes: UInt64 = 0x1000
  public static let powerControllerBase: UInt64 = 0x0c0a_0000
  public static let powerControllerBytes: UInt64 = 0x1000
  public static let virtioBase: UInt64 = 0x0c10_0000
  public static let virtioSlotBytes: UInt64 = 0x200
  public static let virtioSlotCount = 32
  public static let virtioFirstSPI: UInt32 = 16
  public static let pcieECAMBase: UInt64 = 0x1000_0000
  public static let pcieECAMBytes: UInt64 = 0x1000_0000
  public static let pcieMMIOBase: UInt64 = 0x4000_0000
  public static let pcieMMIOBytes: UInt64 = 0x4000_0000
  public static let ramBase: UInt64 = 0x8000_0000
  public static let dtbOffset: UInt64 = 256 << 20
  public static let initrdOffset: UInt64 = 320 << 20
  public static let daxWindowBase: UInt64 = 0x0000_000c_0000_0000
  public static let maximumRAMBytes = daxWindowBase - ramBase

  public static let securePhysicalTimerPPI: UInt32 = 13
  public static let nonsecurePhysicalTimerPPI: UInt32 = 14
  public static let virtualTimerPPI: UInt32 = 11
  public static let hypervisorPhysicalTimerPPI: UInt32 = 10

  public static let regions: [DoryARMVirtV1Region] = [
    fixedRegion(kind: .firmwareCode, base: firmwareCodeBase, byteCount: firmwareCodeBytes),
    fixedRegion(
      kind: .firmwareVariables,
      base: firmwareVariableBase,
      byteCount: firmwareVariableBytes
    ),
    fixedRegion(
      kind: .gicDistributor,
      base: gicDistributorBase,
      byteCount: gicDistributorReservedBytes
    ),
    fixedRegion(
      kind: .gicRedistributors,
      base: gicRedistributorBase,
      byteCount: gicRedistributorReservedBytes
    ),
    fixedRegion(kind: .uart, base: uartBase, byteCount: uartBytes),
    fixedRegion(kind: .rtc, base: rtcBase, byteCount: rtcBytes),
    fixedRegion(
      kind: .powerController,
      base: powerControllerBase,
      byteCount: powerControllerBytes
    ),
    fixedRegion(
      kind: .virtioMMIO,
      base: virtioBase,
      byteCount: UInt64(virtioSlotCount) * virtioSlotBytes
    ),
    fixedRegion(kind: .pcieECAM, base: pcieECAMBase, byteCount: pcieECAMBytes),
    fixedRegion(kind: .pcieMMIO, base: pcieMMIOBase, byteCount: pcieMMIOBytes),
  ]

  public static let virtioSlots: [DoryARMVirtV1VirtioSlot] = (0..<virtioSlotCount).map { index in
    let spi = virtioFirstSPI + UInt32(index)
    return DoryARMVirtV1VirtioSlot(
      index: index,
      baseAddress: virtioBase + UInt64(index) * virtioSlotBytes,
      byteCount: virtioSlotBytes,
      spi: spi,
      interruptID: 32 + spi,
      role: role(forSlot: index)
    )
  }

  public static func role(forSlot slot: Int) -> DoryARMVirtV1DeviceRole {
    switch slot {
    case 0: .systemDisk
    case 1: .graphics
    case 2: .entropy
    case 3: .balloon
    case 4: .vsock
    case 5: .keyboard
    case 6: .pointer
    case 7: .audio
    case 8...11: .network
    case 12...19: .auxiliaryStorage
    case 20...29: .directoryShare
    case 30: .usbController
    default: .reserved
    }
  }

  public static func validateMemoryBytes(_ byteCount: UInt64) throws {
    guard byteCount >= minimumMemoryBytes else {
      throw DoryARMVirtV1ABIError.memoryBelowMinimum(
        minimum: minimumMemoryBytes,
        actual: byteCount
      )
    }
    guard byteCount <= maximumRAMBytes else {
      throw DoryARMVirtV1ABIError.memoryOverlapsDAXWindow(
        maximum: maximumRAMBytes,
        actual: byteCount
      )
    }
  }

  public static func validateVCPUCount(_ count: Int) throws {
    guard (1...maximumVCPUCount).contains(count) else {
      throw DoryARMVirtV1ABIError.invalidVCPUCount(maximum: maximumVCPUCount, actual: count)
    }
  }

  public static let markdown = """
    # DoryARMVirt-v1 ABI

    Identity: `dory.armvirt@1`

    This file is the checked-in projection of `DoryARMVirtV1ABI`. Changes are ABI changes and require a new machine identity.

    ## Physical address map

    | Region | Base | Reserved bytes |
    |---|---:|---:|
    | Firmware code | `0x00000000` | `0x04000000` |
    | Firmware variables | `0x04000000` | `0x04000000` |
    | GICv3 distributor | `0x08000000` | `0x00010000` |
    | GICv3 redistributors | `0x080a0000` | `0x02000000` |
    | PL011 UART | `0x0c000000` | `0x00001000` |
    | PL031 RTC | `0x0c090000` | `0x00001000` |
    | Power/reset controller | `0x0c0a0000` | `0x00001000` |
    | VirtIO MMIO slots | `0x0c100000` | `0x00004000` |
    | PCIe ECAM | `0x10000000` | `0x10000000` |
    | PCIe MMIO | `0x40000000` | `0x40000000` |
    | RAM | `0x80000000` | `0x0000000b80000000` maximum before DAX |
    | DAX window | `0x0000000c00000000` | variable, admitted separately |

    Both boot protocols place the FDT at RAM + `0x10000000` and pass its address in `x0`. Direct Linux places the initrd at RAM + `0x14000000`. UEFI begins at `0x00000000`, uses firmware ABI `dory.edk2.armvirt@1`, and persists variables as `dory.uefi.variables.armvirt@1`. The minimum RAM size is `0x40000000` bytes. The machine exposes 1...256 vCPUs subject to host admission.

    ## Interrupt map

    UART uses SPI 1 / INTID 33. VirtIO slots 0...31 use SPIs 16...47 / INTIDs 48...79. Architectural timer PPIs are secure physical 13, non-secure physical 14, virtual 11, and hypervisor physical 10.

    ## VirtIO MMIO slot roles

    | Slots | Role |
    |---|---|
    | 0 | system disk |
    | 1 | graphics |
    | 2 | entropy |
    | 3 | balloon |
    | 4 | vsock |
    | 5 | keyboard |
    | 6 | pointer |
    | 7 | audio |
    | 8...11 | network |
    | 12...19 | auxiliary/removable storage |
    | 20...29 | directory sharing |
    | 30 | USB controller |
    | 31 | reserved; never allocatable in ABI v1 |

    VirtIO MMIO is the compatibility transport. PCIe ECAM/MMIO, firmware flash, persistent variables, and power/reset addresses are frozen reservations in v1; exposing a device in one of those regions must preserve this map and the separately versioned firmware and device ABIs.
    """

  private static func fixedRegion(
    kind: DoryARMVirtV1RegionKind,
    base: UInt64,
    byteCount: UInt64
  ) -> DoryARMVirtV1Region {
    do {
      return try DoryARMVirtV1Region(kind: kind, base: base, byteCount: byteCount)
    } catch {
      preconditionFailure("Invalid fixed DoryARMVirt-v1 region: \(error)")
    }
  }
}

public enum DoryARMVirtV1ABIError: Error, Equatable, Sendable {
  case memoryBelowMinimum(minimum: UInt64, actual: UInt64)
  case memoryOverlapsDAXWindow(maximum: UInt64, actual: UInt64)
  case invalidVCPUCount(maximum: Int, actual: Int)
}
