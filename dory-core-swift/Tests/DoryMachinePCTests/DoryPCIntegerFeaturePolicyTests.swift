import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCIntegerFeaturePolicyTests {
  @Test func selectedCMOVMaskReachesEveryMachineExecutor() throws {
    for tier in tiers {
      for enabled in [false, true] {
        let base = DoryX86CPUProfile.intelCompatibleV1
        let profile = DoryX86CPUProfile(identifier: base.identifier,
          features: enabled ? base.features : base.features.subtracting([.cmov]),
          physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
          virtualTSCFrequencyHz: base.virtualTSCFrequencyHz, identity: base.identity)
        let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024,
          interpreter: .init(profile: profile), executionTier: tier,
          baselineJITMaximumCodeBytes: 64 * 1024, optimizingJITWarmupDispatches: 0)
        // PVH enters protected32 with ZF clear and EBX pointing to start-info.
        try machine.load(kernel: elf([0x0F, 0x45, 0xC3]), commandLine: "x")
        let before = try #require(machine.state)
        #expect(!before.rflags.contains(.zero) && before.registers.rbx != 0)
        let statistics = machine.executionStatistics
        if enabled {
          #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
          let after = try #require(machine.state)
          #expect(after.rip == before.rip + 3 && after.registers.rax == before.registers.rbx)
          switch tier {
          case .interpreter:
            #expect(machine.executionStatistics.interpreterInstructions - statistics.interpreterInstructions == 1)
          case .baselineJIT:
            #expect(machine.executionStatistics.baselineJITInstructions - statistics.baselineJITInstructions == 1)
          case .optimizingJIT:
            #expect(machine.executionStatistics.optimizingJITInstructions - statistics.optimizingJITInstructions == 1)
          }
        } else {
          for _ in 0..<2 {
            let result = try machine.run(maximumInstructions: 1)
            #expect(result == .exception(.init(kind: .invalidOpcode, vector: 6,
              instructionPointer: before.rip), instructionCount: 0))
            let after = try #require(machine.state)
            var expected = before
            expected.tsc = after.tsc // Board time may advance without instruction retirement.
            #expect(after == expected)
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
