import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCNMIBlockingTests {
  @Test func secondNMIWaitsForIRETAcrossExecutionTiers() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier)
      try prepareInterruptTables(machine)
      try enterFirstNMI(machine)
      try retireIRETWithCoalescedNMI(machine)
      try enterDeferredNMIAndHalt(machine)
    }
  }

  @Test func initClearsNMIBlockingAndItsCoalescedPendingRequest() throws {
    let machine = try makeMachine(tier: .interpreter)
    try prepareInterruptTables(machine)
    try enterNMIForResetTest(machine)
    try applyINITWithPendingNMI(machine)
    try startAfterINITAndProveNMIWasCleared(machine)
  }

  @Test func movSSDefersNMIWithoutConsumingThePendingRequest() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier)
      try prepareInterruptTables(machine)
      try executeMOVSSNMIWindow(machine)
    }
  }

  @inline(never)
  private func prepareInterruptTables(_ machine: DoryPCDirectKernelMachine) throws {
    // Retire LIDT and LGDT before injecting an NMI.
    let lidtStop = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(lidtStop == .instructionBudget(1))
    #expect(machine.state?.rip == 0x10_0007)
    let lgdtStop = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(lgdtStop == .instructionBudget(1))
    #expect(machine.state?.rip == 0x10_000E)
  }

  @inline(never)
  private func enterFirstNMI(_ machine: DoryPCDirectKernelMachine) throws {
    try injectSelfNMI(machine)
    let firstHandlerStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(firstHandlerStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == true)
    #expect(machine.state?.rip == 0x10_0101) // Handler NOP retired; IRET is next.
    #expect(machine.state?.registers.rsp == 0x7FF4)
    #expect(machine.executionStatistics.deliveredMaskableInterrupts == 0)
    #expect(machine.executionStatistics.deliveredNonMaskableInterrupts == 1)
    #expect(machine.executionStatistics.retiredInterruptReturns == 0)
    #expect(
      machine.executionStatistics.deliveredInterruptVectors == [.init(vector: 2, deliveries: 1)])
  }

  @inline(never)
  private func executeMOVSSNMIWindow(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.memory.write(
      at: 0x10_000E,
      bytes: [
        0xB8, 0x10, 0, 0, 0,  // MOV EAX,0x10
        0x8E, 0xD0,  // MOV SS,AX
        0xFF, 0xC3,  // INC EBX
        0xF4,
      ])
    let initialRBX = machine.state?.registers.rbx
    let movSSStop = try machine.runOnDedicatedStack(maximumInstructions: 2, exceptionPolicy: .deliver)
    #expect(movSSStop == .instructionBudget(2))
    #expect(machine.state?.interruptShadow == .movSS)
    #expect(machine.state?.rip == 0x10_0015)

    try injectSelfNMI(machine)
    let protectedStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(protectedStop == .instructionBudget(1))
    #expect(machine.state?.registers.rbx == initialRBX.map { $0 + 1 })
    #expect(machine.state?.interruptShadow == nil)
    #expect(machine.state?.nmiBlocked == false)
    #expect(machine.state?.rip == 0x10_0017)

    let handlerStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(handlerStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == true)
    #expect(machine.state?.rip == 0x10_0101)
  }

  @inline(never)
  private func retireIRETWithCoalescedNMI(_ machine: DoryPCDirectKernelMachine) throws {
    try injectSelfNMI(machine)
    try injectSelfNMI(machine) // Multiple blocked requests coalesce into one pending NMI.
    let firstIRETStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(firstIRETStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == false)
    #expect(machine.state?.rip == 0x10_000E)
    #expect(machine.state?.registers.rsp == 0x8000)
    #expect(machine.executionStatistics.deliveredNonMaskableInterrupts == 1)
    #expect(machine.executionStatistics.retiredInterruptReturns == 1)
    #expect(
      machine.executionStatistics.deliveredInterruptVectors == [.init(vector: 2, deliveries: 1)])
  }

  @inline(never)
  private func enterDeferredNMIAndHalt(_ machine: DoryPCDirectKernelMachine) throws {
    let secondHandlerStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(secondHandlerStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == true)
    #expect(machine.state?.rip == 0x10_0101)
    let secondIRETStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(secondIRETStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == false)
    #expect(machine.state?.rip == 0x10_000E)
    #expect(machine.executionStatistics.deliveredNonMaskableInterrupts == 2)
    #expect(machine.executionStatistics.retiredInterruptReturns == 2)
    #expect(
      machine.executionStatistics.deliveredInterruptVectors == [.init(vector: 2, deliveries: 2)])
    let haltStop = try machine.runOnDedicatedStack(maximumInstructions: 2, exceptionPolicy: .deliver)
    #expect(haltStop == .halted(instructionCount: 1))
  }

  @inline(never)
  private func enterNMIForResetTest(_ machine: DoryPCDirectKernelMachine) throws {
    try injectSelfNMI(machine)
    let handlerStop = try machine.runOnDedicatedStack(maximumInstructions: 1, exceptionPolicy: .deliver)
    #expect(handlerStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == true)
  }

  @inline(never)
  private func applyINITWithPendingNMI(_ machine: DoryPCDirectKernelMachine) throws {
    try injectSelfNMI(machine)
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(5 << 8 | 1 << 18)
    )
    let initStop = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(initStop == .halted(instructionCount: 0))
    #expect(machine.state?.nmiBlocked == false)
    #expect(machine.state?.interruptShadow == nil)
    #expect(machine.state?.rip == 0xFFF0)
  }

  @inline(never)
  private func startAfterINITAndProveNMIWasCleared(_ machine: DoryPCDirectKernelMachine) throws {
    // Give a stale pending NMI a valid, distinguishable real-mode handler. The
    // startup vector writes 0x5A to AL; vector 2 would write 0xA5 instead.
    try machine.memory.write(at: 8, bytes: [0x00, 0x50, 0x00, 0x00])
    try machine.memory.write(at: 0x5000, bytes: [0xB0, 0xA5, 0xF4])
    try machine.memory.write(at: 0x40_000, bytes: [0xB0, 0x5A, 0xF4])
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(0x40 | 6 << 8 | 1 << 18)
    )

    let startupStop = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(startupStop == .instructionBudget(1))
    #expect(machine.state?.nmiBlocked == false)
    #expect(machine.state?.cs.selector == 0x4000)
    #expect(machine.state?.cs.base == 0x40_000)
    #expect(machine.state?.rip == 2)
    #expect(machine.state?.registers.rax == 0x5A)
    let finalStop = try machine.runOnDedicatedStack(maximumInstructions: 2)
    #expect(finalStop == .halted(instructionCount: 1))
  }

  private var executionTiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private func makeMachine(tier: DoryPCExecutionTier) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      executionTier: tier,
      baselineJITMaximumCodeBytes: 4_096,
      optimizingJITWarmupDispatches: 1
    )
    var code = [UInt8](repeating: 0x90, count: 0x102)
    // LIDT [0x80000]; LGDT [0x80006]; HLT.
    code.replaceSubrange(
      0..<15,
      with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0,
        0x0F, 0x01, 0x15, 6, 0, 8, 0,
        0xF4,
      ])
    // NMI handler: NOP; IRET.
    code.replaceSubrange(0x100..<0x102, with: [0x90, 0xCF])
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
      ])
  }

  private func injectSelfNMI(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(4 << 8 | 1 << 18)
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
