import Foundation

/// Dory-owned, read-only PEI discovery page. Firmware consumes this instead of probing an
/// emulated legacy chipset or another VMM's private configuration transport.
public final class DoryPCFirmwareConfiguration: DoryPCMMIODevice, @unchecked Sendable {
  public enum ABI {
    public static let magic: UInt64 = 0x3146_4350_5952_4f44  // "DORYPCF1"
    public static let version: UInt32 = 1
    public static let headerByteCount: UInt32 = 144

    public static let magicOffset = 0
    public static let versionOffset = 8
    public static let headerByteCountOffset = 12
    public static let machineSchemaVersionOffset = 16
    public static let flagsOffset = 20
    public static let totalRAMBytesOffset = 24
    public static let lowRAMBytesOffset = 32
    public static let highRAMBytesOffset = 40
    public static let processorCountOffset = 48
    public static let pciSegmentOffset = 52
    public static let pcieECAMBaseOffset = 56
    public static let pcieECAMBytesOffset = 64
    public static let pcieMMIOBaseOffset = 72
    public static let pcieMMIOBytesOffset = 80
    public static let acpiRSDPAddressOffset = 88
    public static let smbiosEntryAddressOffset = 96
    public static let variableBridgeBaseOffset = 104
    public static let variableBridgeBytesOffset = 112
    public static let firmwareCodeBaseOffset = 120
    public static let firmwareCodeBytesOffset = 128
    public static let highRAMBaseOffset = 136
  }

  public let baseAddress = DoryPCV1ABI.firmwareConfigurationBase
  public let byteCount = DoryPCV1ABI.firmwareConfigurationBytes
  public let totalRAMBytes: UInt64
  public let processorCount: UInt32

  private let page: [UInt8]

  public init(
    totalRAMBytes: UInt64,
    processorCount: Int,
    acpiRSDPAddress: UInt64 = DoryPCV1ABI.acpiBase,
    smbiosEntryAddress: UInt64 = DoryPCV1ABI.smbiosBase
  ) {
    precondition(totalRAMBytes > 0)
    precondition((1...DoryPCV1ABI.maximumVCPUCount).contains(processorCount))
    self.totalRAMBytes = totalRAMBytes
    self.processorCount = UInt32(processorCount)

    let lowRAMBytes = min(totalRAMBytes, DoryPCV1ABI.mmioHoleStart)
    let highRAMBytes =
      totalRAMBytes > DoryPCV1ABI.mmioHoleStart
      ? totalRAMBytes - DoryPCV1ABI.mmioHoleStart : 0
    var bytes = [UInt8](repeating: 0, count: Int(DoryPCV1ABI.firmwareConfigurationBytes))
    Self.store(ABI.magic, at: ABI.magicOffset, in: &bytes)
    Self.store(ABI.version, at: ABI.versionOffset, in: &bytes)
    Self.store(ABI.headerByteCount, at: ABI.headerByteCountOffset, in: &bytes)
    Self.store(DoryPCV1ABI.schemaVersion, at: ABI.machineSchemaVersionOffset, in: &bytes)
    Self.store(UInt32(0), at: ABI.flagsOffset, in: &bytes)
    Self.store(totalRAMBytes, at: ABI.totalRAMBytesOffset, in: &bytes)
    Self.store(lowRAMBytes, at: ABI.lowRAMBytesOffset, in: &bytes)
    Self.store(highRAMBytes, at: ABI.highRAMBytesOffset, in: &bytes)
    Self.store(UInt32(processorCount), at: ABI.processorCountOffset, in: &bytes)
    Self.store(UInt32(0), at: ABI.pciSegmentOffset, in: &bytes)
    Self.store(DoryPCV1ABI.pcieECAMBase, at: ABI.pcieECAMBaseOffset, in: &bytes)
    Self.store(DoryPCV1ABI.pcieECAMBytes, at: ABI.pcieECAMBytesOffset, in: &bytes)
    Self.store(DoryPCV1ABI.pcieMMIOBase, at: ABI.pcieMMIOBaseOffset, in: &bytes)
    Self.store(DoryPCV1ABI.pcieMMIOBytes, at: ABI.pcieMMIOBytesOffset, in: &bytes)
    Self.store(acpiRSDPAddress, at: ABI.acpiRSDPAddressOffset, in: &bytes)
    Self.store(smbiosEntryAddress, at: ABI.smbiosEntryAddressOffset, in: &bytes)
    Self.store(DoryPCV1ABI.firmwareVariableBase, at: ABI.variableBridgeBaseOffset, in: &bytes)
    Self.store(DoryPCV1ABI.firmwareVariableBytes, at: ABI.variableBridgeBytesOffset, in: &bytes)
    Self.store(DoryPCV1ABI.firmwareCodeBase, at: ABI.firmwareCodeBaseOffset, in: &bytes)
    Self.store(DoryPCV1ABI.firmwareCodeBytes, at: ABI.firmwareCodeBytesOffset, in: &bytes)
    Self.store(DoryPCV1ABI.above4GRAMStart, at: ABI.highRAMBaseOffset, in: &bytes)
    page = bytes
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount > 0, offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: false)
    }
    let start = Int(offset)
    return Array(page[start..<(start + byteCount)])
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: offset, byteCount: bytes.count, write: true)
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: offset, byteCount: byteCount, write: true)
  }

  private static func store<T: FixedWidthInteger>(
    _ value: T,
    at offset: Int,
    in bytes: inout [UInt8]
  ) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { source in
      bytes.replaceSubrange(offset..<(offset + source.count), with: source)
    }
  }
}
