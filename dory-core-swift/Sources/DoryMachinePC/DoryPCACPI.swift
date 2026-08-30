import DoryDBTX86
import Foundation

public struct DoryPCACPILayout: Codable, Sendable, Hashable {
  public let rsdp: UInt64
  public let xsdt: UInt64
  public let madt: UInt64
  public let hpet: UInt64
  public let mcfg: UInt64
  public let fadt: UInt64
  public let facs: UInt64
  public let dsdt: UInt64

  public init(
    rsdp: UInt64 = DoryPCV1ABI.acpiBase,
    xsdt: UInt64 = DoryPCV1ABI.acpiBase + 0x100,
    madt: UInt64 = DoryPCV1ABI.acpiBase + 0x200,
    hpet: UInt64 = DoryPCV1ABI.acpiBase + 0x300,
    mcfg: UInt64 = DoryPCV1ABI.acpiBase + 0x400,
    fadt: UInt64? = nil,
    facs: UInt64? = nil,
    dsdt: UInt64? = nil
  ) {
    self.rsdp = rsdp
    self.xsdt = xsdt
    self.madt = madt
    self.hpet = hpet
    self.mcfg = mcfg
    self.fadt = fadt ?? mcfg + 0x100
    self.facs = facs ?? (fadt ?? mcfg + 0x100) + 0x140
    self.dsdt = dsdt ?? (fadt ?? mcfg + 0x100) + 0x200
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
  public let hpet: [UInt8]
  public let mcfg: [UInt8]
  public let fadt: [UInt8]
  public let facs: [UInt8]
  public let dsdt: [UInt8]

  public func install(into memory: any DoryX86Memory) throws {
    let artifacts = [
      (layout.rsdp, rsdp), (layout.xsdt, xsdt), (layout.madt, madt), (layout.hpet, hpet),
      (layout.mcfg, mcfg), (layout.fadt, fadt), (layout.facs, facs), (layout.dsdt, dsdt),
    ]
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

/// DoryPC-v1 ACPI discovery and fixed-hardware contract for direct-kernel and firmware boot.
public enum DoryPCACPIBuilder {
  public static func build(
    layout: DoryPCACPILayout = .init(),
    processorCount: UInt8 = 1
  ) throws -> DoryPCACPITables {
    precondition(processorCount > 0)
    let madt = makeMADT(processorCount: processorCount)
    let hpet = makeHPET()
    let mcfg = makeMCFG()
    let dsdt = makeDSDT()
    let facs = makeFACS()
    let fadt = makeFADT(facsAddress: layout.facs, dsdtAddress: layout.dsdt)
    let xsdt = makeXSDT(tableAddresses: [layout.fadt, layout.madt, layout.hpet, layout.mcfg])
    let rsdp = makeRSDP(xsdtAddress: layout.xsdt)
    let ranges = [
      layout.rsdp..<(layout.rsdp + UInt64(rsdp.count)),
      layout.xsdt..<(layout.xsdt + UInt64(xsdt.count)),
      layout.madt..<(layout.madt + UInt64(madt.count)),
      layout.hpet..<(layout.hpet + UInt64(hpet.count)),
      layout.mcfg..<(layout.mcfg + UInt64(mcfg.count)),
      layout.fadt..<(layout.fadt + UInt64(fadt.count)),
      layout.facs..<(layout.facs + UInt64(facs.count)),
      layout.dsdt..<(layout.dsdt + UInt64(dsdt.count)),
    ].sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCACPIError.overlappingTables
    }
    return .init(
      layout: layout,
      rsdp: rsdp,
      xsdt: xsdt,
      madt: madt,
      hpet: hpet,
      mcfg: mcfg,
      fadt: fadt,
      facs: facs,
      dsdt: dsdt
    )
  }

  private static func makeMADT(processorCount: UInt8) -> [UInt8] {
    var body: [UInt8] = []
    append(UInt32(DoryPCV1ABI.localAPICBase), to: &body)
    append(UInt32(1), to: &body)
    for processor in 0..<processorCount {
      body += [0, 8, processor, processor]
      append(UInt32(1), to: &body)
    }
    // IOAPIC ID 0 at the frozen DoryPC-v1 address, GSI base 0.
    body += [1, 12, 0, 0]
    append(UInt32(DoryPCV1ABI.ioAPICBase), to: &body)
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

  private static func makeHPET() -> [UInt8] {
    var body: [UInt8] = []
    // Hardware revision 1, three comparators, 64-bit counter, legacy replacement capable.
    let eventTimerBlockID: UInt32 = 1 | (2 << 8) | (1 << 13) | (1 << 15) | (0xD0D0 << 16)
    append(eventTimerBlockID, to: &body)
    // ACPI Generic Address Structure: system memory, 64-bit register, QWord access.
    body += [0, 64, 0, 4]
    append(DoryPCV1ABI.hpetBase, to: &body)
    body += [0]
    append(UInt16(128), to: &body)
    body += [0]
    return table(signature: "HPET", revision: 1, body: body)
  }

  private static func makeXSDT(tableAddresses: [UInt64]) -> [UInt8] {
    var body: [UInt8] = []
    for address in tableAddresses { append(address, to: &body) }
    return table(signature: "XSDT", revision: 1, body: body)
  }

  private static func makeMCFG() -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 8)
    append(DoryPCV1ABI.pcieECAMBase, to: &body)
    append(UInt16(0), to: &body)
    body += [0, 0xFF]
    append(UInt32(0), to: &body)
    return table(signature: "MCFG", revision: 1, body: body)
  }

  private static func makeFADT(facsAddress: UInt64, dsdtAddress: UInt64) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 240)
    put(UInt32(truncatingIfNeeded: facsAddress), at: 0, in: &body)
    put(UInt32(truncatingIfNeeded: dsdtAddress), at: 4, in: &body)
    body[9] = 1  // Desktop preferred power-management profile.
    put(UInt16(9), at: 10, in: &body)
    put(UInt32(DoryPCPowerController.pm1ControlPort), at: 28, in: &body)
    body[53] = 2  // PM1 control register width.
    body[72] = 0x32  // RTC century register.
    put(UInt16(0b1_0101), at: 73, in: &body)  // Legacy devices, no VGA probing, no ASPM.
    put(UInt32((1 << 2) | (1 << 10)), at: 76, in: &body)  // C1 and RESET_REG.
    putGAS(
      spaceID: 1,
      bitWidth: 8,
      accessSize: 1,
      address: UInt64(DoryPCPowerController.resetPort),
      at: 80,
      in: &body
    )
    body[92] = DoryPCPowerController.resetValue
    body[95] = 6
    put(facsAddress, at: 96, in: &body)
    put(dsdtAddress, at: 104, in: &body)
    putGAS(
      spaceID: 1,
      bitWidth: 16,
      accessSize: 2,
      address: UInt64(DoryPCPowerController.pm1ControlPort),
      at: 136,
      in: &body
    )
    return table(signature: "FACP", revision: 6, body: body)
  }

  private static func makeFACS() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 64)
    bytes.replaceSubrange(0..<4, with: Array("FACS".utf8))
    put(UInt32(bytes.count), at: 4, in: &bytes)
    bytes[32] = 2
    return bytes
  }

  private static func makeDSDT() -> [UInt8] {
    // Name (_S5, Package (4) { 5, 5, Zero, Zero }). ACPICA iasl round-trip is covered by tests.
    table(
      signature: "DSDT",
      revision: 2,
      body: [0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x08, 0x04, 0x0A, 0x05, 0x0A, 0x05, 0, 0]
    )
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

  private static func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8])
  {
    for index in 0..<MemoryLayout<T>.size {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }

  private static func putGAS(
    spaceID: UInt8,
    bitWidth: UInt8,
    accessSize: UInt8,
    address: UInt64,
    at offset: Int,
    in bytes: inout [UInt8]
  ) {
    bytes[offset] = spaceID
    bytes[offset + 1] = bitWidth
    bytes[offset + 2] = 0
    bytes[offset + 3] = accessSize
    put(address, at: offset + 4, in: &bytes)
  }
}
