import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPAEExecutionBoundaryTests {
  @Test func selectedPhysicalWidthReachesBothJITsAndRunPreservesTheLoadedPDPTEs() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier, physicalAddressBits: 48)
      #expect(try machine.runOnDedicatedStack(maximumInstructions: 6) == .instructionBudget(6))
      let initial = try #require(machine.state)
      #expect(initial.control.isLegacyPAEPagingActive)
      #expect(initial.control.legacyPAEPDPTEs == .init(0xA001, (1 << 40) | 1))

      // A later run resumes the architectural latch. Reading modified guest PDPT RAM here
      // would reject this reserved bit, even though no control-register reload occurred.
      try write(UInt64(3), to: machine, at: 0x9008)
      let before = machine.executionStatistics
      let stop = try machine.runOnDedicatedStack(maximumInstructions: 64)
      try #require(stop == .instructionBudget(64))
      let resumed = try #require(machine.state)
      #expect(resumed.registers.rbx == initial.registers.rbx + 32)
      #expect(resumed.rip == initial.rip)
      #expect(resumed.control == initial.control)
      #expect(try machine.memory.read(at: 0x9008, byteCount: 8) == [3, 0, 0, 0, 0, 0, 0, 0])

      // Native counts distinguish correct width propagation from an unnoticed fallback
      // to the interpreter when a JIT accidentally retains the default 40-bit limit.
      let after = machine.executionStatistics
      switch tier {
      case .interpreter:
        #expect(after.interpreterInstructions - before.interpreterInstructions == 64)
        #expect(after.baselineJITInstructions == 0)
        #expect(after.optimizingJITInstructions == 0)
      case .baselineJIT:
        #expect(after.baselineJITInstructions - before.baselineJITInstructions == 64)
        #expect(after.interpreterInstructions == before.interpreterInstructions)
      case .optimizingJIT:
        #expect(after.optimizingJITInstructions - before.optimizingJITInstructions == 64)
        #expect(after.interpreterInstructions == before.interpreterInstructions)
      }
    }
  }

  @Test func narrowerPhysicalWidthRejectsPagingEnableWithoutPublishingControlOrLatch() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier, physicalAddressBits: 40)
      #expect(try machine.runOnDedicatedStack(maximumInstructions: 5) == .instructionBudget(5))
      let before = try #require(machine.state)
      #expect(!before.control.isLegacyPAEPagingActive)
      #expect(before.control.legacyPAEPDPTEs == nil)
      let originalPDPT = try machine.memory.read(at: 0x9000, byteCount: 32)

      // All four present PDPTEs are checked, including this unused entry above MAXPHYADDR.
      // The same failing instruction can be retried without publishing partial controls.
      for _ in 0..<2 {
        let stop = try machine.runOnDedicatedStack(maximumInstructions: 1)
        guard case .exception(let exception, let count) = stop else {
          Issue.record("Expected paging-enable #GP, got \(stop)")
          continue
        }
        #expect(exception.kind == .generalProtection)
        #expect(exception.vector == 13)
        #expect(exception.errorCode == 0)
        #expect(exception.instructionPointer == before.rip)
        #expect(count == 0)
        let after = try #require(machine.state)
        #expect(after.control == before.control)
        #expect(after.rip == before.rip)
        #expect(after.registers == before.registers)
        #expect(try machine.memory.read(at: 0x9000, byteCount: 32) == originalPDPT)
      }
    }
  }

  @Test func invalidProfileWidthsThrowBeforeAllocatingMachineOrExecutionResources() {
    for tier in executionTiers {
      for width: UInt8 in [0, 31, 53, 255] {
        #expect(throws: DoryX86StateError.invalidPhysicalAddressBits(width)) {
          _ = try makeMachine(tier: tier, physicalAddressBits: width)
        }
      }
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
    physicalAddressBits: UInt8
  ) throws -> DoryPCDirectKernelMachine {
    let baseline = DoryX86CPUProfile.compatibleV1
    // This profile exercises width plumbing without advertising PAE qualification.
    let profile = DoryX86CPUProfile(
      identifier: "pae-width-\(physicalAddressBits)-mechanism-test",
      features: baseline.features,
      physicalAddressBits: physicalAddressBits,
      linearAddressBits: baseline.linearAddressBits,
      virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: .init(
        startInfo: 0x90000, commandLine: 0x91000, modules: 0x92000,
        memoryMap: 0x93000, initrd: 0x180000
      ),
      interpreter: .init(profile: profile),
      executionTier: tier,
      baselineJITMaximumCodeBytes: 64 * 1024,
      optimizingJITWarmupDispatches: 0
    )
    let code: [UInt8] = [
      0xB8, 0x00, 0x90, 0x00, 0x00,  // MOV EAX,0x9000
      0x0F, 0x22, 0xD8,              // MOV CR3,EAX
      0xB8, 0x20, 0x00, 0x00, 0x00,  // MOV EAX,CR4.PAE
      0x0F, 0x22, 0xE0,              // MOV CR4,EAX
      0xB8, 0x11, 0x00, 0x00, 0x80,  // MOV EAX,CR0.PG|ET|PE
      0x0F, 0x22, 0xC0,              // MOV CR0,EAX: latch all four PDPTEs
      0xFF, 0xC3, 0xEB, 0xFC,        // INC EBX; JMP back to INC
    ]
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    try write(UInt64(0xA001), to: machine, at: 0x9000)
    try write(UInt64((1 << 40) | 1), to: machine, at: 0x9008)
    try write(UInt64(0), to: machine, at: 0x9010)
    try write(UInt64(0), to: machine, at: 0x9018)
    try write(UInt64(0x87), to: machine, at: 0xA000)  // Low 2 MiB identity mapping.
    return machine
  }

  private func write(_ value: UInt64, to machine: DoryPCDirectKernelMachine, at address: UInt64)
    throws
  {
    try machine.memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    )
  }

  private func makeELF(code: [UInt8]) -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + code.count)
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(64), to: &data, at: 52)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeHeader(to: &data, at: 0x40, type: 1, fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000, size: UInt64(code.count))
    write(UInt32(5), to: &data, at: 0x44)
    write(UInt64(0x10_0000), to: &data, at: 0x50)
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
    to data: inout Data, at offset: Int, type: UInt32, fileOffset: UInt64,
    physicalAddress: UInt64, size: UInt64
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
