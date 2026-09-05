import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCExceptionEscalationTests {
  @Test func acceptedAPICInterruptGateFaultEntersGeneralProtectionHandlerSerially() throws {
    let machine = try makeMachine(code: setupCode(following: [0xFB, 0xFF, 0xC3, 0xF4]))
    try installTables(machine, validVectors: [13: 0x10_0100])
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.localAPIC.inject(vector: 0x30)
    let initialRBX = try #require(machine.state).registers.rbx

    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)
    guard case .halted = stop else {
      Issue.record("Expected serial #GP handler to halt, got \(stop)")
      return
    }
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "G")])
    #expect(machine.localAPIC.snapshot().interruptRequest.isEmpty)
    #expect(machine.localAPIC.snapshot().inService == [0x30])
    let state = try #require(machine.state)
    #expect(state.interruptShadow == nil)
    #expect(state.registers.rbx == initialRBX + 1)
    #expect(state.registers.rsp == 0x7FF0)
    // Vector 0x30's IDT selector with IDT and EXT set.
    #expect(try machine.memory.readScalar(at: 0x7FF0, byteCount: 4) == 0x183)
  }

  @Test func faultEnteringAcceptedNMIIsSerialAndKeepsNMIBlocked() throws {
    let machine = try makeMachine(code: setupCode(following: [0xF4]))
    try installTables(machine, validVectors: [13: 0x10_0100])
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 4) == .halted(instructionCount: 3))

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(4 << 8 | 1 << 18)
    )
    let stop = try machine.runOnDedicatedStack(maximumInstructions: 8, exceptionPolicy: .deliver)
    guard case .halted = stop else {
      Issue.record("Expected serial #GP handler to halt, got \(stop)")
      return
    }
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "G")])
    let state = try #require(machine.state)
    #expect(state.nmiBlocked)
    #expect(state.interruptShadow == nil)
    // Vector 2's IDT selector with IDT and EXT set.
    #expect(try machine.memory.readScalar(at: 0x7FF0, byteCount: 4) == 0x13)
  }

  @Test func faultWhileEnteringDoubleFaultStopsTheCoreAsTripleFault() throws {
    let machine = try makeMachine(code: setupCode(following: [0xF4]))
    try installTables(machine, validVectors: [:])
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 4) == .halted(instructionCount: 3))

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(4 << 8 | 1 << 18)
    )
    let stop = try machine.runOnDedicatedStack(maximumInstructions: 8, exceptionPolicy: .deliver)
    guard case .tripleFault(let source, _) = stop else {
      Issue.record("Expected processor shutdown to stop the core, got \(stop)")
      return
    }
    #expect(source == .interrupt(vector: 2, source: .nonMaskable, processor: 0))
    #expect(try #require(machine.state).nmiBlocked)
  }

  private func setupCode(following: [UInt8]) -> [UInt8] {
    var code = [UInt8](repeating: 0x90, count: 0x109)
    code.replaceSubrange(
      0..<(14 + following.count),
      with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0,  // LIDT [0x80000]
        0x0F, 0x01, 0x15, 6, 0, 8, 0,  // LGDT [0x80006]
      ] + following
    )
    // Common #GP handler: MOV AL,'G'; MOV EDX,0x3f8; OUT DX,AL; HLT.
    code.replaceSubrange(
      0x100..<0x109,
      with: [0xB0, UInt8(ascii: "G"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4]
    )
    return code
  }

  private func makeMachine(code: [UInt8]) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    return machine
  }

  private func installTables(
    _ machine: DoryPCDirectKernelMachine,
    validVectors: [UInt8: UInt32]
  ) throws {
    try machine.memory.write(at: 0x80000, bytes: [0xFF, 0x07, 0x00, 0x10, 0x08, 0x00])
    try machine.memory.write(at: 0x80006, bytes: [0x17, 0x00, 0x00, 0x20, 0x08, 0x00])
    for (vector, target) in validVectors {
      try machine.memory.write(
        at: 0x81000 + UInt64(vector) * 8,
        bytes: [
          UInt8(truncatingIfNeeded: target), UInt8(truncatingIfNeeded: target >> 8),
          0x08, 0, 0, 0x8E,
          UInt8(truncatingIfNeeded: target >> 16), UInt8(truncatingIfNeeded: target >> 24),
        ]
      )
    }
    try machine.memory.write(
      at: 0x82000,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )
  }

  private func makeELF(code: [UInt8]) -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + code.count)
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
    writeHeader(to: &data, at: 0x40, type: 1, fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000, size: UInt64(code.count))
    writeHeader(to: &data, at: 0x78, type: 4, fileOffset: 0x180,
      physicalAddress: 0, size: 20)
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
    write(UInt32(5), to: &data, at: offset + 4)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 16)
    write(physicalAddress, to: &data, at: offset + 24)
    write(size, to: &data, at: offset + 32)
    write(size, to: &data, at: offset + 40)
    write(UInt64(0x200), to: &data, at: offset + 48)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
