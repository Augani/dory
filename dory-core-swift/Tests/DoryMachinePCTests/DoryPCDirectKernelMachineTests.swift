import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCDirectKernelMachineTests {
  @Test func entersPVHCodeWritesSerialAndHalts() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024, bootLayout: layout)
    let code: [UInt8] = [
      0xB0, UInt8(ascii: "D"),
      0xBA, 0xF8, 0x03, 0x00, 0x00,
      0xEE,
      0xF4,
    ]

    try machine.load(kernel: makeELF(code: code), commandLine: "console=ttyS0")
    let stop = try machine.run(maximumInstructions: 16)

    #expect(stop == .halted(instructionCount: 4))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "D")])
    #expect(machine.state?.registers.rbx == layout.startInfo)
  }

  @Test func stopsOnBudgetAndReportsPreciseExceptions() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let budgeted = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    try budgeted.load(kernel: makeELF(code: [0x90, 0xEB, 0xFD]), commandLine: "x")
    #expect(try budgeted.run(maximumInstructions: 5) == .instructionBudget(5))

    let faulting = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    try faulting.load(kernel: makeELF(code: [0x0F, 0x0B]), commandLine: "x")
    guard case .exception(let exception, let count) = try faulting.run(maximumInstructions: 1)
    else {
      Issue.record("expected invalid opcode")
      return
    }
    #expect(exception.kind == .invalidOpcode)
    #expect(count == 0)
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
}
