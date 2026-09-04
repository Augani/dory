import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPagingFeatureTests {
  @Test func selectedProfileControlsMachineFetchDiagnosticsAndBothNativeTiers() throws {
    for tier in tiers {
      for supportsOneGiBPages in [false, true] {
        let base = DoryX86CPUProfile.compatibleV1
        let profile = DoryX86CPUProfile(identifier: "test.paging-capability",
          features: supportsOneGiBPages ? base.features : base.features.subtracting([.oneGiBPages]),
          physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
          virtualTSCFrequencyHz: base.virtualTSCFrequencyHz)
        let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024,
          interpreter: .init(profile: profile), executionTier: tier,
          baselineJITMaximumCodeBytes: 64 * 1024, optimizingJITWarmupDispatches: 0)
        let setup: [UInt8] = [
          0xB8, 0x20, 0, 0, 0, 0x0F, 0x22, 0xE0, // CR4.PAE.
          0xB8, 0, 0, 0x08, 0, 0x0F, 0x22, 0xD8, // CR3=0x80000.
          0xB9, 0x80, 0, 0, 0xC0, // ECX=IA32_EFER.
          0xB8, 0, 0x09, 0, 0, // EAX=LME|NXE.
          0xBA, 0, 0, 0, 0, // EDX=0.
          0x0F, 0x30, // WRMSR.
          0xB8, 0x11, 0, 0, 0x80, 0x0F, 0x22, 0xC0, // CR0.PG|ET|PE.
        ]
        // IA32e compatibility mode is sufficient to exercise the same PDPTE walk.
        let loop: [UInt8] = [0xFF, 0xC3, 0xEB, 0xFC] // INC EBX; JMP back.
        try machine.load(kernel: elf(setup + loop), commandLine: "x")
        try write64(0x81027, at: 0x80000, to: machine)
        try write64(0x83, at: 0x81000, to: machine)
        #expect(try machine.run(maximumInstructions: 10) == .instructionBudget(10))
        let initial = try #require(machine.state)
        #expect(initial.rip == 0x100000 + UInt64(setup.count))
        #expect(initial.control.efer & (1 << 10) != 0)
        let statistics = machine.executionStatistics

        if supportsOneGiBPages {
          #expect(try machine.instructionBytes(maximumCount: 4) == loop)
          #expect(try machine.memoryBytes(atLinearAddress: initial.rip, maximumCount: 4) == loop)
          #expect(try machine.run(maximumInstructions: 64) == .instructionBudget(64))
          let after = try #require(machine.state)
          #expect(after.registers.rbx == initial.registers.rbx + 32)
          #expect(after.rip == initial.rip)
          switch tier {
          case .interpreter:
            #expect(machine.executionStatistics.interpreterInstructions - statistics.interpreterInstructions == 64)
          case .baselineJIT:
            #expect(machine.executionStatistics.baselineJITInstructions - statistics.baselineJITInstructions == 64)
          case .optimizingJIT:
            #expect(machine.executionStatistics.optimizingJITInstructions - statistics.optimizingJITInstructions == 64)
          }
        } else {
          let tables = try machine.memory.read(at: 0x80000, byteCount: 0x2000)
          #expect(throws: DoryX86MemoryError.pageFault(address: initial.rip, errorCode: 25)) {
            try machine.instructionBytes(maximumCount: 4)
          }
          #expect(throws: DoryX86MemoryError.pageFault(address: initial.rip, errorCode: 9)) {
            try machine.memoryBytes(atLinearAddress: initial.rip, maximumCount: 4)
          }
          for _ in 0..<2 {
            let result = try machine.run(maximumInstructions: 64)
            guard case .exception(let exception, let count) = result else {
              Issue.record("Expected reserved-page fetch fault, got \(result)")
              continue
            }
            #expect(exception.kind == .pageFault && exception.vector == 14)
            #expect(exception.errorCode == 25 && exception.linearAddress == initial.rip)
            #expect(exception.instructionPointer == initial.rip && count == 0)
            var expected = initial
            expected.control.cr2 = initial.rip
            let after = try #require(machine.state)
            // Board time advances on an attempted execution; compare CPU fault
            // state without treating the timer's independent tick as retirement.
            expected.tsc = after.tsc
            #expect(after == expected)
            #expect(try machine.memory.read(at: 0x80000, byteCount: 0x2000) == tables)
            #expect(machine.executionStatistics.baselineJITInstructions == statistics.baselineJITInstructions)
            #expect(machine.executionStatistics.optimizingJITInstructions == statistics.optimizingJITInstructions)
          }
        }
      }
    }
  }

  private var tiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private func write64(_ value: UInt64, at address: UInt64, to machine: DoryPCDirectKernelMachine) throws {
    try machine.memory.write(at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  private func elf(_ code: [UInt8]) -> Data {
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
