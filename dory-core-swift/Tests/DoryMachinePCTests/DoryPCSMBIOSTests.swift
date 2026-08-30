import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCSMBIOSTests {
  @Test func publishesChecksummedPlatformTopologyAndMemoryIdentity() throws {
    let uuid: [UInt8] = [
      0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66,
      0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ]
    let tables = try DoryPCSMBIOSBuilder.build(
      identity: .init(serialNumber: "vm-42", systemUUID: uuid),
      processorCount: 4,
      memoryBytes: 2 * 1024 * 1024
    )

    #expect(Array(tables.entryPoint.prefix(5)) == Array("_SM3_".utf8))
    #expect(tables.entryPoint.count == 0x18)
    #expect(tables.entryPoint.reduce(0, &+) == 0)
    #expect(Array(tables.entryPoint[7...9]) == [3, 0, 0])
    #expect(read32(tables.entryPoint, at: 12) == UInt32(tables.structureTable.count))
    #expect(read64(tables.entryPoint, at: 16) == tables.layout.structureTable)

    let structures = try parseStructures(tables.structureTable)
    #expect(structures.map(\.type) == [0, 1, 4, 16, 17, 19, 19, 32, 127])
    let system = try #require(structures.first { $0.type == 1 })
    #expect(Array(system.formatted[8..<24]) == uuid)
    #expect(
      system.strings == [
        "Dory", "DoryPC-v1", "1", "vm-42", "DORY-PC-V1", "Dory Virtual Machine",
      ])

    let processor = try #require(structures.first { $0.type == 4 })
    #expect(processor.formatted.count == 0x30)
    #expect(Array(processor.formatted[0x23...0x25]) == [4, 4, 4])
    #expect(read16(processor.formatted, at: 0x2A) == 4)
    #expect(read16(processor.formatted, at: 0x2C) == 4)
    #expect(read16(processor.formatted, at: 0x2E) == 4)
    let cpuid = DoryX86CPUProfile.compatibleV1.cpuid(leaf: 1, logicalProcessorCount: 4)
    #expect(read32(processor.formatted, at: 8) == cpuid.eax)
    #expect(read32(processor.formatted, at: 12) == cpuid.edx)

    let array = try #require(structures.first { $0.type == 16 })
    #expect(read32(array.formatted, at: 7) == 2048)
    let device = try #require(structures.first { $0.type == 17 })
    #expect(read16(device.formatted, at: 0x0C) == 2)

    let mappings = structures.filter { $0.type == 19 }
    #expect(read32(mappings[0].formatted, at: 4) == 0)
    #expect(read32(mappings[0].formatted, at: 8) == 575)
    #expect(read32(mappings[1].formatted, at: 4) == 1024)
    #expect(read32(mappings[1].formatted, at: 8) == 2047)
  }

  @Test func validatesIdentityLayoutAndInstallationBeforeWriting() throws {
    #expect(throws: DoryPCSMBIOSError.invalidUUIDByteCount(1)) {
      try DoryPCSMBIOSBuilder.build(
        identity: .init(systemUUID: [0]),
        memoryBytes: 1024 * 1024
      )
    }
    #expect(throws: DoryPCSMBIOSError.invalidIdentityField("bad\0value")) {
      try DoryPCSMBIOSBuilder.build(
        identity: .init(serialNumber: "bad\0value"),
        memoryBytes: 1024 * 1024
      )
    }
    #expect(throws: DoryPCSMBIOSError.overlappingArtifacts) {
      try DoryPCSMBIOSBuilder.build(
        layout: .init(entryPoint: 0xF0000, structureTable: 0xF0008),
        memoryBytes: 1024 * 1024
      )
    }

    let tables = try DoryPCSMBIOSBuilder.build(memoryBytes: 1024 * 1024)
    let undersized = DoryX86ByteArrayMemory(byteCount: 0xF0000)
    #expect(throws: DoryPCSMBIOSError.self) { try tables.install(into: undersized) }
    #expect(try undersized.read(at: 0, byteCount: 16) == .init(repeating: 0, count: 16))
  }

  @Test func directKernelMachineInstallsDiscoverableSMBIOSIdentity() throws {
    let identity = DoryPCSMBIOSIdentity(
      serialNumber: "stable-vm",
      systemUUID: (0..<16).map(UInt8.init)
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      smbiosIdentity: identity
    )
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")

    #expect(
      try machine.memory.read(at: machine.smbios.layout.entryPoint, byteCount: 5)
        == Array("_SM3_".utf8)
    )
    #expect(
      try machine.memory.read(
        at: machine.smbios.layout.structureTable,
        byteCount: machine.smbios.structureTable.count
      ) == machine.smbios.structureTable
    )
  }
}

private struct ParsedSMBIOSStructure {
  let type: UInt8
  let formatted: [UInt8]
  let strings: [String]
}

private enum TestSMBIOSError: Error { case malformed }

private func parseStructures(_ table: [UInt8]) throws -> [ParsedSMBIOSStructure] {
  var result: [ParsedSMBIOSStructure] = []
  var cursor = 0
  while cursor < table.count {
    guard cursor + 4 <= table.count else { throw TestSMBIOSError.malformed }
    let length = Int(table[cursor + 1])
    guard length >= 4, cursor + length <= table.count else { throw TestSMBIOSError.malformed }
    let formatted = Array(table[cursor..<(cursor + length)])
    var strings: [String] = []
    var stringStart = cursor + length
    var index = stringStart
    while index + 1 < table.count, table[index] != 0 || table[index + 1] != 0 {
      if table[index] == 0 {
        guard let string = String(bytes: table[stringStart..<index], encoding: .utf8) else {
          throw TestSMBIOSError.malformed
        }
        strings.append(string)
        stringStart = index + 1
      }
      index += 1
    }
    guard index + 1 < table.count else { throw TestSMBIOSError.malformed }
    if index > stringStart {
      guard let string = String(bytes: table[stringStart..<index], encoding: .utf8) else {
        throw TestSMBIOSError.malformed
      }
      strings.append(string)
    }
    let type = table[cursor]
    result.append(.init(type: type, formatted: formatted, strings: strings))
    cursor = index + 2
    if type == 127 { break }
  }
  return result
}

private func read16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
  bytes[offset..<(offset + 2)].enumerated().reduce(0) {
    $0 | UInt16($1.element) << UInt16($1.offset * 8)
  }
}

private func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  bytes[offset..<(offset + 4)].enumerated().reduce(0) {
    $0 | UInt32($1.element) << UInt32($1.offset * 8)
  }
}

private func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
  bytes[offset..<(offset + 8)].enumerated().reduce(0) {
    $0 | UInt64($1.element) << UInt64($1.offset * 8)
  }
}

private func makeELF(code: [UInt8]) -> Data {
  let segmentOffset = 0x200
  var data = Data(repeating: 0, count: segmentOffset + code.count)
  data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
  data[4] = 2
  data[5] = 1
  data[6] = 1
  write(UInt16(0x3E), to: &data, at: 18)
  write(UInt64(0x40), to: &data, at: 32)
  write(UInt16(56), to: &data, at: 54)
  write(UInt16(2), to: &data, at: 56)
  writeHeader(
    to: &data,
    at: 0x40,
    type: 1,
    fileOffset: UInt64(segmentOffset),
    physicalAddress: 0x10_0000,
    size: UInt64(code.count)
  )
  writeHeader(
    to: &data,
    at: 0x78,
    type: 4,
    fileOffset: 0x180,
    physicalAddress: 0,
    size: 20
  )
  write(UInt32(4), to: &data, at: 0x180)
  write(UInt32(4), to: &data, at: 0x184)
  write(UInt32(0x12), to: &data, at: 0x188)
  data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
  write(UInt32(0x10_0000), to: &data, at: 0x190)
  data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
  return data
}

private func writeHeader(
  to data: inout Data,
  at offset: Int,
  type: UInt32,
  fileOffset: UInt64,
  physicalAddress: UInt64,
  size: UInt64
) {
  write(type, to: &data, at: offset)
  write(fileOffset, to: &data, at: offset + 8)
  write(physicalAddress, to: &data, at: offset + 24)
  write(size, to: &data, at: offset + 32)
  write(size, to: &data, at: offset + 40)
}

private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
  for index in 0..<MemoryLayout<T>.size {
    data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
