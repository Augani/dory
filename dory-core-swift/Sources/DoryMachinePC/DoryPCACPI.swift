import DoryDBTX86
import Foundation

public struct DoryPCACPILayout: Codable, Sendable, Hashable {
  public let rsdp: UInt64
  public let xsdt: UInt64
  public let madt: UInt64

  public init(rsdp: UInt64 = 0x0009_E000, xsdt: UInt64 = 0x0009_E100, madt: UInt64 = 0x0009_E200) {
    self.rsdp = rsdp
    self.xsdt = xsdt
    self.madt = madt
  }
}

public enum DoryPCACPIError: Error, Sendable, Equatable {
  case overlappingTables
  case guestMemoryRejected(DoryX86MemoryError)
}

public struct DoryPCACPITables: Sendable, Hashable {
  public let layout: DoryPCACPILayout
  public let rsdp: [UInt8]
  public let xsdt: [UInt8]
  public let madt: [UInt8]

  public func install(into memory: any DoryX86Memory) throws {
    let artifacts = [(layout.rsdp, rsdp), (layout.xsdt, xsdt), (layout.madt, madt)]
    do {
      for artifact in artifacts {
        try memory.validateWrite(at: artifact.0, byteCount: artifact.1.count)
      }
      for artifact in artifacts { try memory.write(at: artifact.0, bytes: artifact.1) }
    } catch let error as DoryX86MemoryError {
      throw DoryPCACPIError.guestMemoryRejected(error)
    }
  }
}

/// Minimal DoryPC-v1 ACPI discovery set for direct-kernel boot. Firmware phases extend the XSDT
/// with FADT/MCFG and AML without changing the already frozen APIC topology described here.
public enum DoryPCACPIBuilder {
  public static func build(layout: DoryPCACPILayout = .init()) throws -> DoryPCACPITables {
    let madt = makeMADT()
    let xsdt = makeXSDT(madtAddress: layout.madt)
    let rsdp = makeRSDP(xsdtAddress: layout.xsdt)
    let ranges = [
      layout.rsdp..<(layout.rsdp + UInt64(rsdp.count)),
      layout.xsdt..<(layout.xsdt + UInt64(xsdt.count)),
      layout.madt..<(layout.madt + UInt64(madt.count)),
    ].sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCACPIError.overlappingTables
    }
    return .init(layout: layout, rsdp: rsdp, xsdt: xsdt, madt: madt)
  }

  private static func makeMADT() -> [UInt8] {
    var body: [UInt8] = []
    append(UInt32(0xFEE0_0000), to: &body)
    append(UInt32(1), to: &body)
    // Processor UID 0, local APIC ID 0, enabled.
    body += [0, 8, 0, 0]
    append(UInt32(1), to: &body)
    // IOAPIC ID 0 at the frozen DoryPC-v1 address, GSI base 0.
    body += [1, 12, 0, 0]
    append(UInt32(0xFEC0_0000), to: &body)
    append(UInt32(0), to: &body)
    // ISA IRQ0 is wired to IOAPIC input/GSI 2.
    body += [2, 10, 0, 0]
    append(UInt32(2), to: &body)
    append(UInt16(0), to: &body)
    // All processors receive the local APIC NMI on LINT1.
    body += [4, 6, 0xFF]
    append(UInt16(0), to: &body)
    body += [1]
    return table(signature: "APIC", revision: 5, body: body)
  }

  private static func makeXSDT(madtAddress: UInt64) -> [UInt8] {
    var body: [UInt8] = []
    append(madtAddress, to: &body)
    return table(signature: "XSDT", revision: 1, body: body)
  }

  private static func makeRSDP(xsdtAddress: UInt64) -> [UInt8] {
    var bytes = Array("RSD PTR ".utf8)
    bytes += [0]
    bytes += Array("DORY  ".utf8)
    bytes += [2]
    append(UInt32(0), to: &bytes)
    append(UInt32(36), to: &bytes)
    append(xsdtAddress, to: &bytes)
    bytes += [0, 0, 0, 0]
    bytes[8] = checksum(Array(bytes.prefix(20)))
    bytes[32] = checksum(bytes)
    return bytes
  }

  private static func table(signature: String, revision: UInt8, body: [UInt8]) -> [UInt8] {
    var bytes = Array(signature.utf8)
    append(UInt32(36 + body.count), to: &bytes)
    bytes += [revision, 0]
    bytes += Array("DORY  ".utf8)
    bytes += Array("DORYPCV1".utf8)
    append(UInt32(1), to: &bytes)
    bytes += Array("DORY".utf8)
    append(UInt32(1), to: &bytes)
    bytes += body
    bytes[9] = checksum(bytes)
    return bytes
  }

  private static func checksum(_ bytes: [UInt8]) -> UInt8 {
    0 &- bytes.reduce(0, &+)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for index in 0..<MemoryLayout<T>.size {
      bytes.append(UInt8(truncatingIfNeeded: value >> T(index * 8)))
    }
  }
}
