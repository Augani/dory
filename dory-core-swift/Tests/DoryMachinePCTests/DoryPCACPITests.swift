import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCACPITests {
  @Test func buildsChecksummedRSDPXSDTAndMADTTopology() throws {
    let tables = try DoryPCACPIBuilder.build()

    #expect(Array(tables.rsdp.prefix(8)) == Array("RSD PTR ".utf8))
    #expect(tables.rsdp.prefix(20).reduce(0, &+) == 0)
    #expect(tables.rsdp.reduce(0, &+) == 0)
    #expect(read64(tables.rsdp, at: 24) == tables.layout.xsdt)
    #expect(Array(tables.xsdt.prefix(4)) == Array("XSDT".utf8))
    #expect(tables.xsdt.reduce(0, &+) == 0)
    #expect(read64(tables.xsdt, at: 36) == tables.layout.fadt)
    #expect(read64(tables.xsdt, at: 44) == tables.layout.madt)
    #expect(read64(tables.xsdt, at: 52) == tables.layout.hpet)
    #expect(read64(tables.xsdt, at: 60) == tables.layout.mcfg)
    #expect(Array(tables.madt.prefix(4)) == Array("APIC".utf8))
    #expect(tables.madt.reduce(0, &+) == 0)
    #expect(read32(tables.madt, at: 36) == 0xFEE0_0000)
    #expect(tables.madt.containsSubsequence([1, 12, 0, 0, 0, 0, 0xC0, 0xFE]))
    #expect(Array(tables.hpet.prefix(4)) == Array("HPET".utf8))
    #expect(tables.hpet.reduce(0, &+) == 0)
    #expect(read64(tables.hpet, at: 44) == 0xFED0_0000)
    #expect(Array(tables.mcfg.prefix(4)) == Array("MCFG".utf8))
    #expect(tables.mcfg.reduce(0, &+) == 0)
    #expect(read64(tables.mcfg, at: 44) == 0xE000_0000)
    #expect(Array(tables.fadt.prefix(4)) == Array("FACP".utf8))
    #expect(tables.fadt.count == 276)
    #expect(tables.fadt.reduce(0, &+) == 0)
    #expect(read32(tables.fadt, at: 40) == UInt32(tables.layout.dsdt))
    #expect(read32(tables.fadt, at: 112) & (1 << 10) != 0)
    #expect(tables.fadt[116] == 1)
    #expect(read64(tables.fadt, at: 120) == UInt64(DoryPCPowerController.resetPort))
    #expect(tables.fadt[128] == DoryPCPowerController.resetValue)
    #expect(read64(tables.fadt, at: 132) == tables.layout.facs)
    #expect(read64(tables.fadt, at: 140) == tables.layout.dsdt)
    #expect(Array(tables.facs.prefix(4)) == Array("FACS".utf8))
    #expect(Array(tables.dsdt.prefix(4)) == Array("DSDT".utf8))
    #expect(tables.dsdt.reduce(0, &+) == 0)
    #expect(tables.dsdt.containsSubsequence(Array("_S5_".utf8)))
    #expect(tables.dsdt.containsSubsequence(Array("PCI0".utf8)))
    #expect(tables.dsdt.containsSubsequence(Array("_PRT".utf8)))
  }

  @Test func installsAtomicallyAfterPreflightingEveryTable() throws {
    let tables = try DoryPCACPIBuilder.build(
      layout: .init(rsdp: 0x100, xsdt: 0x200, madt: 0x300, hpet: 0x400, mcfg: 0x500))
    let memory = DoryX86ByteArrayMemory(byteCount: 0x3000)

    try tables.install(into: memory)

    #expect(try memory.read(at: 0x100, byteCount: 8) == Array("RSD PTR ".utf8))
    #expect(try memory.read(at: 0x200, byteCount: 4) == Array("XSDT".utf8))
    #expect(try memory.read(at: 0x300, byteCount: 4) == Array("APIC".utf8))
    #expect(try memory.read(at: 0x400, byteCount: 4) == Array("HPET".utf8))
    #expect(try memory.read(at: 0x500, byteCount: 4) == Array("MCFG".utf8))
    #expect(try memory.read(at: 0x600, byteCount: 4) == Array("FACP".utf8))
    #expect(try memory.read(at: 0x740, byteCount: 4) == Array("FACS".utf8))
    #expect(try memory.read(at: 0x800, byteCount: 4) == Array("DSDT".utf8))
  }

  @Test func madtPublishesEveryEnabledLogicalProcessor() throws {
    let tables = try DoryPCACPIBuilder.build(processorCount: 4)
    for processor: UInt8 in 0..<4 {
      #expect(
        tables.madt.containsSubsequence([
          0, 8, processor, processor, 1, 0, 0, 0,
        ]))
    }
  }

  @Test func everySupportedTopologyFitsTheReservedACPIRegion() throws {
    for processorCount: UInt8 in [1, 23, 24, 255] {
      let tables = try DoryPCACPIBuilder.build(processorCount: processorCount)
      let ranges = tableRanges(tables).sorted { $0.lowerBound < $1.lowerBound }
      let reserved = DoryPCV1ABI.acpiBase..<(DoryPCV1ABI.acpiBase + DoryPCV1ABI.acpiBytes)

      #expect(ranges.allSatisfy { reserved.lowerBound <= $0.lowerBound })
      #expect(ranges.allSatisfy { $0.upperBound <= reserved.upperBound })
      #expect(!zip(ranges, ranges.dropFirst()).contains { $0.0.overlaps($0.1) })
    }
  }

  @Test func dsdtDefinesTheCompletePCIeRootContract() throws {
    let dsl = try decompileDSDT(try DoryPCACPIBuilder.build().dsdt)
    let compactDSL = dsl.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    #expect(dsl.contains("Device (PCI0)"))
    #expect(dsl.contains("Name (_HID, EisaId (\"PNP0A08\")"))
    #expect(dsl.contains("Name (_CID, EisaId (\"PNP0A03\")"))
    #expect(dsl.contains("Name (_SEG, Zero)"))
    #expect(dsl.contains("Name (_BBN, Zero)"))
    #expect(dsl.contains("0xD0000000"))
    #expect(dsl.contains("0xDFFFFFFF"))
    #expect(dsl.contains("0x10000000"))
    #expect(dsl.contains("Device (MRES)"))
    #expect(dsl.contains("EisaId (\"PNP0C02\")"))
    #expect(dsl.components(separatedBy: "Package (0x04)").count - 1 == 129)
    #expect(compactDSL.contains("0xFFFF, Zero, Zero, 0x10"))
    #expect(compactDSL.contains("0x001FFFFF, 0x03, Zero, 0x12"))
  }

  @Test func directKernelHandoffPublishesTheRSDPAddress() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeMinimalELF(), commandLine: "x")

    let startInfo = try machine.memory.read(
      at: machine.bootLayout.startInfo,
      byteCount: 48
    )
    #expect(read64(startInfo, at: 32) == machine.acpiLayout.rsdp)
    #expect(
      try machine.memory.read(at: machine.acpiLayout.rsdp, byteCount: 8)
        == Array("RSD PTR ".utf8)
    )
  }

  private func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
  }

  private func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
  }

  private func tableRanges(_ tables: DoryPCACPITables) -> [Range<UInt64>] {
    [
      tables.layout.rsdp..<(tables.layout.rsdp + UInt64(tables.rsdp.count)),
      tables.layout.xsdt..<(tables.layout.xsdt + UInt64(tables.xsdt.count)),
      tables.layout.madt..<(tables.layout.madt + UInt64(tables.madt.count)),
      tables.layout.hpet..<(tables.layout.hpet + UInt64(tables.hpet.count)),
      tables.layout.mcfg..<(tables.layout.mcfg + UInt64(tables.mcfg.count)),
      tables.layout.fadt..<(tables.layout.fadt + UInt64(tables.fadt.count)),
      tables.layout.facs..<(tables.layout.facs + UInt64(tables.facs.count)),
      tables.layout.dsdt..<(tables.layout.dsdt + UInt64(tables.dsdt.count)),
    ]
  }

  private func decompileDSDT(_ bytes: [UInt8]) throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-acpi-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let tableURL = directory.appendingPathComponent("dsdt.aml")
    let outputURL = directory.appendingPathComponent("decoded")
    try Data(bytes).write(to: tableURL, options: .atomic)

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["iasl", "-d", "-p", outputURL.path, tableURL.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "DoryPCACPITests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)]
      )
    }
    return try String(contentsOf: outputURL.appendingPathExtension("dsl"), encoding: .utf8)
  }

  private func makeMinimalELF() -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + 1)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt16(64), to: &data, at: 52)
    write(UInt32(5), to: &data, at: 0x44)
    write(UInt64(0x10_0000), to: &data, at: 0x50)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    write(UInt32(1), to: &data, at: 0x40)
    write(UInt64(segmentOffset), to: &data, at: 0x48)
    write(UInt64(0x10_0000), to: &data, at: 0x58)
    write(UInt64(1), to: &data, at: 0x60)
    write(UInt64(1), to: &data, at: 0x68)
    write(UInt32(4), to: &data, at: 0x78)
    write(UInt64(0x180), to: &data, at: 0x80)
    write(UInt64(20), to: &data, at: 0x98)
    data.replaceSubrange(
      0x180..<0x194,
      with: [
        4, 0, 0, 0, 4, 0, 0, 0, 0x12, 0, 0, 0, 0x58, 0x65, 0x6E, 0,
        0, 0x00, 0x10, 0,
      ])
    data[segmentOffset] = 0xF4
    return data
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}

extension Array where Element: Equatable {
  fileprivate func containsSubsequence(_ subsequence: [Element]) -> Bool {
    guard !subsequence.isEmpty, subsequence.count <= count else { return false }
    return indices.dropLast(subsequence.count - 1).contains {
      Array(self[$0..<($0 + subsequence.count)]) == subsequence
    }
  }
}
