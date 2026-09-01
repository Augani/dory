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
    madt: UInt64 = DoryPCV1ABI.acpiBase + 0x1000,
    hpet: UInt64 = DoryPCV1ABI.acpiBase + 0x200,
    mcfg: UInt64 = DoryPCV1ABI.acpiBase + 0x300,
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
  case tablesOutsideReservedRegion
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
    let ranges = try [
      checkedRange(start: layout.rsdp, byteCount: rsdp.count),
      checkedRange(start: layout.xsdt, byteCount: xsdt.count),
      checkedRange(start: layout.madt, byteCount: madt.count),
      checkedRange(start: layout.hpet, byteCount: hpet.count),
      checkedRange(start: layout.mcfg, byteCount: mcfg.count),
      checkedRange(start: layout.fadt, byteCount: fadt.count),
      checkedRange(start: layout.facs, byteCount: facs.count),
      checkedRange(start: layout.dsdt, byteCount: dsdt.count),
    ].sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCACPIError.overlappingTables
    }
    let (reservedEnd, overflow) = layout.rsdp.addingReportingOverflow(DoryPCV1ABI.acpiBytes)
    guard !overflow,
      ranges.allSatisfy({ layout.rsdp <= $0.lowerBound && $0.upperBound <= reservedEnd })
    else {
      throw DoryPCACPIError.tablesOutsideReservedRegion
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

  private static func checkedRange(start: UInt64, byteCount: Int) throws -> Range<UInt64> {
    let (end, overflow) = start.addingReportingOverflow(UInt64(byteCount))
    guard !overflow else { throw DoryPCACPIError.tablesOutsideReservedRegion }
    return start..<end
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
    let sleepState = amlName(
      "_S5_",
      value: amlPackage([amlInteger(5), amlInteger(5), amlInteger(0), amlInteger(0)])
    )

    let pciResources = amlResourceTemplate([
      // WordBusNumber(ResourceProducer, MinFixed, MaxFixed, PosDecode, 0, 0, 255, 0, 256)
      0x88, 0x0D, 0x00, 0x02, 0x0C, 0x00,
      0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01,
      // DWordMemory(ResourceProducer, PosDecode, MinFixed, MaxFixed,
      //   NonCacheable, ReadWrite, 0, 0xD0000000, 0xDFFFFFFF, 0, 0x10000000)
      0x87, 0x17, 0x00, 0x00, 0x0C, 0x01,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0xD0,
      0xFF, 0xFF, 0xFF, 0xDF,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x10,
    ])
    var interruptRoutes: [[UInt8]] = []
    interruptRoutes.reserveCapacity(32 * 4)
    for device: UInt8 in 0..<32 {
      for pin: UInt8 in 0..<4 {
        let address = UInt32(device) << 16 | 0xFFFF
        let gsi = DoryPCV1ABI.interruptLine(device: device, pin: pin + 1)
        interruptRoutes.append(
          amlPackage([
            amlInteger(UInt64(address)), amlInteger(UInt64(pin)), amlInteger(0),
            amlInteger(UInt64(gsi)),
          ]))
      }
    }
    let pciRoot = amlDevice(
      "PCI0",
      terms: amlName("_HID", value: amlEISAID("PNP0A08"))
        + amlName("_CID", value: amlEISAID("PNP0A03"))
        + amlName("_UID", value: amlInteger(0))
        + amlName("_SEG", value: amlInteger(0))
        + amlName("_BBN", value: amlInteger(0))
        + amlName("_CRS", value: pciResources)
        + amlName("_PRT", value: amlPackage(interruptRoutes))
    )

    // Reserve ECAM in the namespace without advertising it as a PCI child allocation window.
    let ecamReservation = amlDevice(
      "MRES",
      terms: amlName("_HID", value: amlEISAID("PNP0C02"))
        + amlName("_UID", value: amlInteger(1))
        + amlName(
          "_CRS",
          value: amlResourceTemplate([
            0x86, 0x09, 0x00, 0x00,
            0x00, 0x00, 0x00, 0xE0,
            0x00, 0x00, 0x00, 0x10,
          ]))
    )
    let systemBus = amlScope("\\_SB_", terms: pciRoot + ecamReservation)
    return table(signature: "DSDT", revision: 2, body: sleepState + systemBus)
  }

  private static func amlName(_ name: String, value: [UInt8]) -> [UInt8] {
    [0x08] + amlNameString(name) + value
  }

  private static func amlScope(_ name: String, terms: [UInt8]) -> [UInt8] {
    let payload = amlNameString(name) + terms
    return [0x10] + amlPackagePayload(payload)
  }

  private static func amlDevice(_ name: String, terms: [UInt8]) -> [UInt8] {
    let payload = amlNameString(name) + terms
    return [0x5B, 0x82] + amlPackagePayload(payload)
  }

  private static func amlPackage(_ elements: [[UInt8]]) -> [UInt8] {
    precondition(elements.count <= Int(UInt8.max))
    return [0x12] + amlPackagePayload([UInt8(elements.count)] + elements.flatMap { $0 })
  }

  private static func amlResourceTemplate(_ descriptors: [UInt8]) -> [UInt8] {
    let bytes = descriptors + [0x79, 0x00]
    return [0x11] + amlPackagePayload(amlInteger(UInt64(bytes.count)) + bytes)
  }

  private static func amlEISAID(_ identifier: String) -> [UInt8] {
    precondition(identifier.utf8.count == 7)
    let bytes = Array(identifier.utf8)
    let manufacturer =
      UInt16(bytes[0] - 0x40) << 10
      | UInt16(bytes[1] - 0x40) << 5
      | UInt16(bytes[2] - 0x40)
    let product = UInt16(identifier.suffix(4), radix: 16)!
    return [
      0x0C,
      UInt8(manufacturer >> 8), UInt8(truncatingIfNeeded: manufacturer),
      UInt8(product >> 8), UInt8(truncatingIfNeeded: product),
    ]
  }

  private static func amlInteger(_ value: UInt64) -> [UInt8] {
    switch value {
    case 0: return [0x00]
    case 1: return [0x01]
    case ...UInt64(UInt8.max): return [0x0A, UInt8(value)]
    case ...UInt64(UInt16.max):
      return [0x0B, UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    case ...UInt64(UInt32.max):
      return [0x0C] + (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    default:
      return [0x0E] + (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
  }

  private static func amlNameString(_ name: String) -> [UInt8] {
    let rooted = name.first == "\\"
    let segment = rooted ? String(name.dropFirst()) : name
    precondition(segment.utf8.count == 4)
    return (rooted ? [0x5C] : []) + Array(segment.utf8)
  }

  private static func amlPackagePayload(_ payload: [UInt8]) -> [UInt8] {
    for width in 1...4 {
      let length = payload.count + width
      let limit = width == 1 ? 0x40 : 1 << (4 + (width - 1) * 8)
      if length < limit { return amlPackageLength(length, width: width) + payload }
    }
    preconditionFailure("AML package exceeds the four-byte package-length encoding")
  }

  private static func amlPackageLength(_ length: Int, width: Int) -> [UInt8] {
    precondition((1...4).contains(width))
    if width == 1 { return [UInt8(length)] }
    var bytes = [UInt8(0x40 * (width - 1) | (length & 0x0F))]
    for index in 0..<(width - 1) {
      bytes.append(UInt8(truncatingIfNeeded: length >> (4 + index * 8)))
    }
    return bytes
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
