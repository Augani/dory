import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCInterruptShadowTests {
  @Test func nativeTiersInterpretTheProtectedBoundaryThenResumeNativeExecution() throws {
    for tier in executionTiers {
      let machine = try makeMachine(
        tier: tier,
        code: [
          0xFB,  // STI establishes the shadow.
          0xFF, 0xC3,  // INC EBX is the protected following instruction.
          0xFF, 0xC1,  // INC ECX may resume in the selected native tier.
          0xEB, 0xFC,  // Loop at INC ECX.
        ])
      let initialRBX = try #require(machine.state).registers.rbx

      #expect(try machine.run(maximumInstructions: 3) == .instructionBudget(3))
      let state = try #require(machine.state)
      #expect(state.registers.rbx == initialRBX + 1)
      #expect(state.registers.rcx == 1)
      #expect(state.interruptShadow == nil)
      let statistics = machine.executionStatistics
      switch tier {
      case .interpreter:
        #expect(statistics.interpreterInstructions == 3)
        #expect(statistics.baselineJITInstructions == 0)
        #expect(statistics.optimizingJITInstructions == 0)
      case .baselineJIT:
        #expect(statistics.interpreterInstructions == 2)
        #expect(statistics.baselineJITInstructions == 1)
      case .optimizingJIT:
        #expect(statistics.interpreterInstructions == 2)
        #expect(statistics.optimizingJITInstructions == 1)
      }
    }
  }

  @Test func localAPICRequestIsNotAcknowledgedUntilInstructionAfterSTI() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier, code: [0xFB, 0xFF, 0xC3, 0xEB, 0xFE])
      let initialRBX = try #require(machine.state).registers.rbx
      try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
      try machine.localAPIC.inject(vector: 0x30)
      #expect(machine.localAPIC.snapshot().interruptRequest == [0x30])

      let stop = try machine.run(maximumInstructions: 8)
      guard case .tripleFault(let source, let count) = stop,
        case .interrupt(let vector, let interruptSource, let processor) = source
      else {
        Issue.record("Expected delivery through the deliberately absent IDT, got \(stop)")
        continue
      }
      #expect(vector == 0x30)
      #expect(interruptSource == .externalMaskable)
      #expect(processor == 0)
      #expect(count == 2)
      let state = try #require(machine.state)
      #expect(state.registers.rbx == initialRBX + 1)
      #expect(state.interruptShadow == nil)
      let apic = machine.localAPIC.snapshot()
      #expect(apic.interruptRequest.isEmpty)
      #expect(apic.inService == [0x30])
      #expect(machine.executionStatistics.interpreterInstructions == 2)
    }
  }

  @Test func legacyPICRequestRemainsPendingAcrossSTIShadow() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier, code: [0xFB, 0xFF, 0xC3, 0xEB, 0xFE])
      let initialRBX = try #require(machine.state).registers.rbx
      try configurePIC(machine)
      try machine.legacyPIC.raise(irq: 0)
      #expect(machine.legacyPIC.snapshot().masterRequest == 1)

      let stop = try machine.run(maximumInstructions: 8)
      guard case .tripleFault(let source, let count) = stop,
        case .interrupt(let vector, let interruptSource, let processor) = source
      else {
        Issue.record("Expected PIC delivery through the deliberately absent IDT, got \(stop)")
        continue
      }
      #expect(vector == 0x20)
      #expect(interruptSource == .externalMaskable)
      #expect(processor == 0)
      #expect(count == 2)
      let state = try #require(machine.state)
      #expect(state.registers.rbx == initialRBX + 1)
      #expect(state.interruptShadow == nil)
      let pic = machine.legacyPIC.snapshot()
      #expect(pic.masterRequest == 0)
      #expect(pic.masterInService == 1)
    }
  }

  @Test func movSSShadowAlsoDefersAControllerRequestForOneInstruction() throws {
    for tier in executionTiers {
      let machine = try makeMachine(
        tier: tier,
        code: [
          0x0F, 0x01, 0x15, 0x06, 0, 0x08, 0,  // LGDT [0x80006]
          0xFB,  // STI
          0x90,  // consume STI shadow
          0xB8, 0x10, 0, 0, 0,  // MOV EAX,0x10
          0x8E, 0xD0,  // MOV SS,AX
          0xFF, 0xC3,  // protected INC EBX
          0xEB, 0xFE,
        ])
      try machine.memory.write(at: 0x80006, bytes: [0x17, 0, 0, 0x20, 0x08, 0])
      try machine.memory.write(
        at: 0x82000,
        bytes: [
          0, 0, 0, 0, 0, 0, 0, 0,
          0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
          0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
        ])
      #expect(try machine.run(maximumInstructions: 5) == .instructionBudget(5))
      let before = try #require(machine.state)
      #expect(before.interruptShadow == .movSS)
      #expect(before.ss.selector == 0x10)

      try configurePIC(machine)
      try machine.legacyPIC.raise(irq: 0)
      let stop = try machine.run(maximumInstructions: 8)
      guard case .tripleFault(_, let count) = stop else {
        Issue.record("Expected PIC delivery through the deliberately absent IDT, got \(stop)")
        continue
      }
      #expect(count == 1)
      let after = try #require(machine.state)
      #expect(after.registers.rbx == before.registers.rbx + 1)
      #expect(after.interruptShadow == nil)
    }
  }

  private var executionTiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private func makeMachine(
    tier: DoryPCExecutionTier,
    code: [UInt8]
  ) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      executionTier: tier,
      baselineJITMaximumCodeBytes: 64 * 1024,
      optimizingJITWarmupDispatches: 0
    )
    try machine.load(kernel: makeELF(code), commandLine: "x")
    return machine
  }

  private func configurePIC(_ machine: DoryPCDirectKernelMachine) throws {
    try machine.ioBus.write(port: 0x20, value: 0x11, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x20, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x04, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x01, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0xFE, width: .byte)
  }

  private func makeELF(_ code: [UInt8]) -> Data {
    var data = Data(repeating: 0, count: 0x200 + code.count)
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    put(UInt16(2), into: &data, at: 16)
    put(UInt16(0x3E), into: &data, at: 18)
    put(UInt32(1), into: &data, at: 20)
    put(UInt64(0x40), into: &data, at: 32)
    put(UInt16(64), into: &data, at: 52)
    put(UInt16(56), into: &data, at: 54)
    put(UInt16(2), into: &data, at: 56)
    put(UInt32(1), into: &data, at: 0x40)
    put(UInt32(5), into: &data, at: 0x44)
    put(UInt64(0x200), into: &data, at: 0x48)
    put(UInt64(0x100000), into: &data, at: 0x50)
    put(UInt64(0x100000), into: &data, at: 0x58)
    put(UInt64(code.count), into: &data, at: 0x60)
    put(UInt64(code.count), into: &data, at: 0x68)
    put(UInt32(4), into: &data, at: 0x78)
    put(UInt64(0x180), into: &data, at: 0x80)
    put(UInt64(20), into: &data, at: 0x98)
    put(UInt64(20), into: &data, at: 0xA0)
    put(UInt32(4), into: &data, at: 0x180)
    put(UInt32(4), into: &data, at: 0x184)
    put(UInt32(0x12), into: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    put(UInt32(0x100000), into: &data, at: 0x190)
    data.replaceSubrange(0x200..<data.count, with: code)
    return data
  }

  private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
    }
  }
}
