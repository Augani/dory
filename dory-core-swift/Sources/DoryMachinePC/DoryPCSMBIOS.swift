import DoryDBTX86
import Foundation

public struct DoryPCSMBIOSLayout: Codable, Sendable, Hashable {
  public let entryPoint: UInt64
  public let structureTable: UInt64

  public init(
    entryPoint: UInt64 = DoryPCV1ABI.smbiosBase,
    structureTable: UInt64 = DoryPCV1ABI.smbiosBase + 0x1000
  ) {
    self.entryPoint = entryPoint
    self.structureTable = structureTable
  }
}

public struct DoryPCSMBIOSIdentity: Codable, Sendable, Hashable {
  public let manufacturer: String
  public let productName: String
  public let version: String
  public let serialNumber: String
  /// SMBIOS wire-format UUID bytes. An all-zero value explicitly means no UUID is assigned.
  public let systemUUID: [UInt8]
  public let skuNumber: String
  public let family: String

  public init(
    manufacturer: String = "Dory",
    productName: String = "DoryPC-v1",
    version: String = "1",
    serialNumber: String = "Not Specified",
    systemUUID: [UInt8] = .init(repeating: 0, count: 16),
    skuNumber: String = "DORY-PC-V1",
    family: String = "Dory Virtual Machine"
  ) {
    self.manufacturer = manufacturer
    self.productName = productName
    self.version = version
    self.serialNumber = serialNumber
    self.systemUUID = systemUUID
    self.skuNumber = skuNumber
    self.family = family
  }
}

public enum DoryPCSMBIOSError: Error, Sendable, Equatable {
  case invalidProcessorCount(Int)
  case invalidMemorySize(Int)
  case invalidIdentityField(String)
  case invalidUUIDByteCount(Int)
  case overlappingArtifacts
  case guestMemoryRejected(DoryX86MemoryError)
}

public struct DoryPCSMBIOSTables: Sendable, Hashable {
  public let layout: DoryPCSMBIOSLayout
  public let entryPoint: [UInt8]
  public let structureTable: [UInt8]

  public func install(into memory: any DoryX86Memory) throws {
    let artifacts = [
      (layout.entryPoint, entryPoint),
      (layout.structureTable, structureTable),
    ]
    do {
      for (address, bytes) in artifacts {
        try memory.validateWrite(at: address, byteCount: bytes.count)
      }
      for (address, bytes) in artifacts { try memory.write(at: address, bytes: bytes) }
    } catch let error as DoryX86MemoryError {
      throw DoryPCSMBIOSError.guestMemoryRejected(error)
    }
  }
}

/// SMBIOS 3.0 identity for the frozen DoryPC-v1 platform.
public enum DoryPCSMBIOSBuilder {
  public static let majorVersion: UInt8 = 3
  public static let minorVersion: UInt8 = 0
  public static let documentRevision: UInt8 = 0

  public static func build(
    layout: DoryPCSMBIOSLayout = .init(),
    identity: DoryPCSMBIOSIdentity = .init(),
    processorCount: Int = 1,
    memoryBytes: Int,
    cpuProfile: DoryX86CPUProfile = .compatibleV1
  ) throws -> DoryPCSMBIOSTables {
    guard (1...255).contains(processorCount) else {
      throw DoryPCSMBIOSError.invalidProcessorCount(processorCount)
    }
    guard memoryBytes >= 1024 * 1024, memoryBytes % (1024 * 1024) == 0 else {
      throw DoryPCSMBIOSError.invalidMemorySize(memoryBytes)
    }
    try validate(identity: identity)

    let mappedRanges = DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryBytes))
      .filter { $0.kind == .ram }
    var table: [UInt8] = []
    table += firmwareInformation()
    table += systemInformation(identity: identity)
    table += processorInformation(
      processorCount: processorCount,
      cpuProfile: cpuProfile
    )
    table += physicalMemoryArray(memoryBytes: UInt64(memoryBytes))
    table += memoryDevice(memoryBytes: UInt64(memoryBytes))
    for (index, range) in mappedRanges.enumerated() {
      table += memoryArrayMappedAddress(
        handle: 0x1300 + UInt16(index),
        address: range.address,
        size: range.size
      )
    }
    table += structure(type: 32, handle: 0x2000, body: .init(repeating: 0, count: 7))
    table += structure(type: 127, handle: 0x7F00, body: [])

    let entryPoint = try makeEntryPoint(
      tableAddress: layout.structureTable,
      maximumTableSize: table.count
    )
    let entryRange = try range(address: layout.entryPoint, count: entryPoint.count)
    let tableRange = try range(address: layout.structureTable, count: table.count)
    guard !entryRange.overlaps(tableRange) else {
      throw DoryPCSMBIOSError.overlappingArtifacts
    }
    return .init(layout: layout, entryPoint: entryPoint, structureTable: table)
  }

  private static func firmwareInformation() -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x14)
    body[0] = 1  // Vendor.
    body[1] = 2  // Version.
    body[4] = 3  // Release date.
    body[5] = 0  // 64 KiB firmware image.
    put(UInt64((1 << 7) | (1 << 15) | (1 << 16)), at: 6, in: &body)
    body[14] = 1  // ACPI.
    body[15] = (1 << 3) | (1 << 4)  // UEFI and virtual-machine identity.
    body[16] = 1
    body[17] = 0
    body[18] = 0xFF
    body[19] = 0xFF
    return structure(
      type: 0,
      handle: 0,
      body: body,
      strings: ["Dory", "DoryPC Firmware ABI 1", "01/01/2026"]
    )
  }

  private static func systemInformation(identity: DoryPCSMBIOSIdentity) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x17)
    body[0] = 1
    body[1] = 2
    body[2] = 3
    body[3] = 4
    body.replaceSubrange(4..<20, with: identity.systemUUID)
    body[20] = 0x06  // Power switch.
    body[21] = 5
    body[22] = 6
    return structure(
      type: 1,
      handle: 0x0100,
      body: body,
      strings: [
        identity.manufacturer,
        identity.productName,
        identity.version,
        identity.serialNumber,
        identity.skuNumber,
        identity.family,
      ]
    )
  }

  private static func processorInformation(
    processorCount: Int,
    cpuProfile: DoryX86CPUProfile
  ) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x2C)
    body[0] = 1  // Socket designation.
    body[1] = 3  // Central processor.
    body[2] = 2  // Unknown family; the stable profile string is authoritative.
    body[3] = 2  // Manufacturer.
    let cpuid = cpuProfile.cpuid(leaf: 1, logicalProcessorCount: UInt16(processorCount))
    put(cpuid.eax, at: 4, in: &body)
    put(cpuid.edx, at: 8, in: &body)
    body[12] = 3  // Version.
    body[20] = 0x41  // Populated and enabled.
    body[21] = 2  // Unknown upgrade.
    put(UInt16.max, at: 22, in: &body)
    put(UInt16.max, at: 24, in: &body)
    put(UInt16.max, at: 26, in: &body)
    let count = UInt8(processorCount)
    body[31] = count
    body[32] = count
    body[33] = count
    var characteristics: UInt16 = 1 << 2  // 64-bit capable.
    if processorCount > 1 { characteristics |= 1 << 3 }
    if cpuProfile.supports(.executeDisable) { characteristics |= 1 << 5 }
    put(characteristics, at: 34, in: &body)
    put(UInt16(2), at: 36, in: &body)
    put(UInt16(processorCount), at: 38, in: &body)
    put(UInt16(processorCount), at: 40, in: &body)
    put(UInt16(processorCount), at: 42, in: &body)
    return structure(
      type: 4,
      handle: 0x0400,
      body: body,
      strings: ["CPU0", "Dory", cpuProfile.identifier]
    )
  }

  private static func physicalMemoryArray(memoryBytes: UInt64) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x13)
    body[0] = 3  // System board.
    body[1] = 3  // System memory.
    body[2] = 3  // No error correction.
    let capacityKiB = memoryBytes / 1024
    if capacityKiB < 0x8000_0000 {
      put(UInt32(capacityKiB), at: 3, in: &body)
    } else {
      put(UInt32(0x8000_0000), at: 3, in: &body)
      put(memoryBytes, at: 11, in: &body)
    }
    put(UInt16(0xFFFE), at: 7, in: &body)
    put(UInt16(1), at: 9, in: &body)
    return structure(type: 16, handle: 0x1000, body: body)
  }

  private static func memoryDevice(memoryBytes: UInt64) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x24)
    put(UInt16(0x1000), at: 0, in: &body)
    put(UInt16(0xFFFE), at: 2, in: &body)
    put(UInt16(64), at: 4, in: &body)
    put(UInt16(64), at: 6, in: &body)
    let sizeMiB = memoryBytes / (1024 * 1024)
    if sizeMiB < 0x7FFF {
      put(UInt16(sizeMiB), at: 8, in: &body)
    } else {
      put(UInt16(0x7FFF), at: 8, in: &body)
      put(UInt32(sizeMiB), at: 24, in: &body)
    }
    body[10] = 9  // DIMM.
    body[12] = 1  // Device locator.
    body[13] = 2  // Bank locator.
    body[14] = 2  // Unknown memory technology: do not invent host DRAM details.
    body[19] = 3  // Manufacturer.
    return structure(
      type: 17,
      handle: 0x1100,
      body: body,
      strings: ["RAM0", "BANK0", "Dory"]
    )
  }

  private static func memoryArrayMappedAddress(
    handle: UInt16,
    address: UInt64,
    size: UInt64
  ) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 0x1B)
    let end = address + size - 1
    let startKiB = address / 1024
    let endKiB = end / 1024
    if startKiB <= UInt32.max, endKiB <= UInt32.max {
      put(UInt32(startKiB), at: 0, in: &body)
      put(UInt32(endKiB), at: 4, in: &body)
    } else {
      put(UInt32.max, at: 0, in: &body)
      put(UInt32.max, at: 4, in: &body)
      put(address, at: 11, in: &body)
      put(end, at: 19, in: &body)
    }
    put(UInt16(0x1000), at: 8, in: &body)
    body[10] = 1
    return structure(type: 19, handle: handle, body: body)
  }

  private static func makeEntryPoint(
    tableAddress: UInt64,
    maximumTableSize: Int
  ) throws -> [UInt8] {
    guard let tableSize = UInt32(exactly: maximumTableSize) else {
      throw DoryPCSMBIOSError.overlappingArtifacts
    }
    var bytes = Array("_SM3_".utf8)
    bytes += [0, 0x18, majorVersion, minorVersion, documentRevision, 1, 0]
    append(tableSize, to: &bytes)
    append(tableAddress, to: &bytes)
    bytes[5] = checksum(bytes)
    return bytes
  }

  private static func structure(
    type: UInt8,
    handle: UInt16,
    body: [UInt8],
    strings: [String] = []
  ) -> [UInt8] {
    precondition(body.count <= Int(UInt8.max) - 4)
    var bytes = [type, UInt8(4 + body.count)]
    append(handle, to: &bytes)
    bytes += body
    for string in strings {
      bytes += string.utf8
      bytes.append(0)
    }
    bytes.append(0)
    if strings.isEmpty { bytes.append(0) }
    return bytes
  }

  private static func validate(identity: DoryPCSMBIOSIdentity) throws {
    guard identity.systemUUID.count == 16 else {
      throw DoryPCSMBIOSError.invalidUUIDByteCount(identity.systemUUID.count)
    }
    for field in [
      identity.manufacturer,
      identity.productName,
      identity.version,
      identity.serialNumber,
      identity.skuNumber,
      identity.family,
    ] {
      let bytes = Array(field.utf8)
      guard !bytes.isEmpty, bytes.count <= 64, bytes.allSatisfy({ (0x20...0x7E).contains($0) })
      else { throw DoryPCSMBIOSError.invalidIdentityField(field) }
    }
  }

  private static func range(address: UInt64, count: Int) throws -> Range<UInt64> {
    let end = address.addingReportingOverflow(UInt64(count))
    guard !end.overflow else { throw DoryPCSMBIOSError.overlappingArtifacts }
    return address..<end.partialValue
  }

  private static func checksum(_ bytes: [UInt8]) -> UInt8 { 0 &- bytes.reduce(0, &+) }

  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for index in 0..<MemoryLayout<T>.size {
      bytes.append(UInt8(truncatingIfNeeded: value >> T(index * 8)))
    }
  }

  private static func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8])
  {
    for index in 0..<MemoryLayout<T>.size {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
