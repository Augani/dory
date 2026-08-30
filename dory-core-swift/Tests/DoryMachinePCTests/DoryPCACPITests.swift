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
    #expect(
      tables.dsdt.suffix(14) == [
        0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x08, 0x04, 0x0A, 0x05, 0x0A, 0x05, 0, 0,
      ])
  }

  @Test func installsAtomicallyAfterPreflightingEveryTable() throws {
    let tables = try DoryPCACPIBuilder.build(
      layout: .init(rsdp: 0x100, xsdt: 0x200, madt: 0x300, hpet: 0x400, mcfg: 0x500))
    let memory = DoryX86ByteArrayMemory(byteCount: 0x1000)

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

  private func makeMinimalELF() -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + 1)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(0x3E), to: &data, at: 18)
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
