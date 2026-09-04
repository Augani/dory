import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCREPInterruptibilityTests {
  @Test func nmiInterruptsAndRestartsREPFromTheExactCompletedPrefix() throws {
    for tier in executionTiers {
      try exercise(tier: tier)
    }
  }

  private func exercise(tier: DoryPCExecutionTier) throws {
    let machine = try makeMachine(tier: tier)
    let initialMarker = try #require(machine.state).registers.rbx
    try installCopyBuffers(machine)
    try verifyInitialYield(machine)
    try injectSelfNMI(machine)
    try verifyNMIHandler(machine, initialMarker: initialMarker)
    try verifyIRETRestart(machine)
    try verifyCompletion(machine)
  }

  private func installCopyBuffers(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.memory.write(
      at: sourceAddress,
      bytes: (0..<elementCount).map { UInt8(truncatingIfNeeded: $0 &* 37) }
    )
    try machine.memory.write(
      at: destinationAddress,
      bytes: [UInt8](repeating: 0xCC, count: elementCount)
    )
  }

  private func verifyInitialYield(_ machine: DoryPCDirectKernelMachine) throws {
    // LIDT, LGDT, three register loads, then REP MOVSB. The REP dispatch
    // commits 4,096 complete iterations and yields with its RIP unchanged.
    let result = try runWithLargeStack(machine, maximumInstructions: 6)
    #expect(result == .instructionBudget(6))
    let yielded = try #require(machine.state)
    #expect(yielded.rip == repAddress)
    #expect(yielded.registers.rcx == 1)
    #expect(yielded.registers.rsi == sourceAddress + 4_096)
    #expect(yielded.registers.rdi == destinationAddress + 4_096)
    #expect(
      try machine.memory.read(at: destinationAddress, byteCount: 4_096)
        == (0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 37) }
    )
    #expect(try machine.memory.read(at: destinationAddress + 4_096, byteCount: 1) == [0xCC])
  }

  private func verifyNMIHandler(
    _ machine: DoryPCDirectKernelMachine,
    initialMarker: UInt64
  ) throws {
    // Delivery occurs before the machine can redispatch the yielded REP.
    let result = try runWithLargeStack(
      machine, maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(result == .instructionBudget(1))
    let inHandler = try #require(machine.state)
    #expect(inHandler.rip == handlerAddress + 2)
    #expect(inHandler.registers.rbx == initialMarker + 1)
    #expect(inHandler.nmiBlocked)
    #expect(inHandler.registers.rcx == 1)
    #expect(inHandler.registers.rsi == sourceAddress + 4_096)
    #expect(inHandler.registers.rdi == destinationAddress + 4_096)
    #expect(try machine.memory.read(at: destinationAddress + 4_096, byteCount: 1) == [0xCC])
  }

  private func verifyIRETRestart(_ machine: DoryPCDirectKernelMachine) throws {
    let result = try runWithLargeStack(
      machine, maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(result == .instructionBudget(1))
    let restarted = try #require(machine.state)
    #expect(restarted.rip == repAddress)
    #expect(!restarted.nmiBlocked)
    #expect(restarted.registers.rcx == 1)
    #expect(restarted.registers.rsi == sourceAddress + 4_096)
    #expect(restarted.registers.rdi == destinationAddress + 4_096)
    #expect(try machine.memory.read(at: destinationAddress + 4_096, byteCount: 1) == [0xCC])
  }

  private func verifyCompletion(_ machine: DoryPCDirectKernelMachine) throws {
    let result = try runWithLargeStack(
      machine, maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(result == .instructionBudget(1))
    let completed = try #require(machine.state)
    #expect(completed.rip == repAddress + 2)
    #expect(completed.registers.rcx == 0)
    #expect(completed.registers.rsi == sourceAddress + UInt64(elementCount))
    #expect(completed.registers.rdi == destinationAddress + UInt64(elementCount))
    #expect(
      try machine.memory.read(at: destinationAddress + 4_096, byteCount: 1)
        == [UInt8(truncatingIfNeeded: 4_096 &* 37)]
    )

    let completedRegisters = completed.registers
    let halt = try runWithLargeStack(
      machine, maximumInstructions: 2, exceptionPolicy: .deliver)
    #expect(halt == .halted(instructionCount: 1))
    #expect(machine.state?.registers == completedRegisters)
  }

  private var executionTiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private var entryAddress: UInt64 { 0x10_0000 }
  private var repAddress: UInt64 { entryAddress + 0x1D }
  private var handlerAddress: UInt64 { entryAddress + 0x100 }
  private var sourceAddress: UInt64 { 0x09_0000 }
  private var destinationAddress: UInt64 { 0x09_2000 }
  private var elementCount: Int { 4_097 }

  private func makeMachine(tier: DoryPCExecutionTier) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      executionTier: tier,
      baselineJITMaximumCodeBytes: 64 * 1024,
      optimizingJITWarmupDispatches: 1
    )
    var code = [UInt8](repeating: 0x90, count: 0x103)
    code.replaceSubrange(
      0..<0x20,
      with: [
        0x0F, 0x01, 0x1D, 0x00, 0x00, 0x08, 0x00,  // LIDT [0x80000]
        0x0F, 0x01, 0x15, 0x06, 0x00, 0x08, 0x00,  // LGDT [0x80006]
        0xBE, 0x00, 0x00, 0x09, 0x00,  // MOV ESI,0x90000
        0xBF, 0x00, 0x20, 0x09, 0x00,  // MOV EDI,0x92000
        0xB9, 0x01, 0x10, 0x00, 0x00,  // MOV ECX,4097
        0xF3, 0xA4,  // REP MOVSB
        0xF4,  // HLT
      ]
    )
    code.replaceSubrange(0x100..<0x103, with: [0xFF, 0xC3, 0xCF])  // INC EBX; IRET
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    try installProtectedTables(machine)
    return machine
  }

  private func installProtectedTables(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.memory.write(at: 0x80000, bytes: [0xFF, 0x07, 0x00, 0x10, 0x08, 0x00])
    try machine.memory.write(at: 0x80006, bytes: [0x17, 0x00, 0x00, 0x20, 0x08, 0x00])
    try machine.memory.write(
      at: 0x81000 + 2 * 8,
      bytes: [0x00, 0x01, 0x08, 0x00, 0x00, 0x8E, 0x10, 0x00]
    )
    try machine.memory.write(
      at: 0x82000,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )
  }

  private func injectSelfNMI(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(4 << 8 | 1 << 18)
    )
  }

  private func runWithLargeStack(
    _ machine: DoryPCDirectKernelMachine,
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    let result = REPThreadResult<DoryPCMachineStop>()
    let completed = DispatchSemaphore(value: 0)
    let thread = Thread {
      defer { completed.signal() }
      result.store(
        Result {
          try machine.run(
            maximumInstructions: maximumInstructions,
            exceptionPolicy: exceptionPolicy
          )
        })
    }
    thread.stackSize = 16 * 1024 * 1024
    thread.start()
    completed.wait()
    return try result.take().get()
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
    write(UInt64(entryAddress), to: &data, at: 0x50)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeHeader(
      to: &data,
      at: 0x40,
      type: 1,
      fileOffset: UInt64(segmentOffset),
      physicalAddress: entryAddress,
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
    write(UInt32(truncatingIfNeeded: entryAddress), to: &data, at: 0x190)
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

private final class REPThreadResult<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, any Error>?

  func store(_ result: Result<Value, any Error>) {
    lock.withLock { self.result = result }
  }

  func take() -> Result<Value, any Error> {
    lock.withLock { result! }
  }
}
