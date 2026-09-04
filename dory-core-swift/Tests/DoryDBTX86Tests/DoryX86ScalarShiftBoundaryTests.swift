import Testing

@testable import DoryDBTX86

// Intel SDM 253667-092 Vol. 2B, RCL/RCR/ROL/ROR pp. 4-535–537:
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
// Vol. 3A, #PF Program State Change p. 7-50:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86ScalarShiftBoundaryTests {
  @Test func fullByteAndWordRotationsUpdateCarryFromTheUnchangedDestination() throws {
    let unaffected: DoryX86RFLAGS = [.reservedOne, .parity, .auxiliaryCarry, .zero, .sign,
      .interruptEnable, .direction]
    for width in [8, 16] {
      for right in [false, true] {
        for carryOut in [false, true] {
          for count in (width == 8 ? [8, 16, 24, 40] : [16, 48]) {
            for useCL in [false, true] {
              let value: UInt64 = right ? (carryOut ? 0x8001 : 0x4001)
                : (carryOut ? 0x4281 : 0x4280)
              let low = width == 8 && right ? (carryOut ? UInt64(0x81) : 0x41) : value
              let rax = 0xBEEF_1234_5678_0000 | low
              let bytes = rotateBytes(width: width, group: right ? 1 : 0,
                count: UInt8(count), useCL: useCL)
              let memory = try DoryX86ByteArrayMemory(bytes: bytes)
              var flags = unaffected
              if !carryOut { flags.insert(.carry) }
              var state = try DoryX86ArchitecturalState(
                registers: .init(rax: rax, rcx: UInt64(count)), rip: 0, rflags: flags)
              try retire(bytes, state: &state, memory: memory)
              #expect(state.registers.rax == rax)
              #expect(state.rflags.contains(.carry) == carryOut)
              #expect(state.rflags.intersection(unaffected) == unaffected)
              // OF is undefined for these masked counts and is deliberately not asserted.
            }
          }
        }
      }
    }
  }

  @Test func maskedZeroCountsPreserveFlagsForEveryRotateWidth() throws {
    let flags: DoryX86RFLAGS = [.reservedOne, .carry, .parity, .auxiliaryCarry,
      .zero, .sign, .overflow, .direction]
    for width in [8, 16, 32, 64] {
      for group: UInt8 in [0, 1, 2, 3] {
        for count: UInt8 in [0, width == 64 ? 64 : 32] {
          for useCL in [false, true] {
            let bytes = rotateBytes(width: width, group: group, count: count, useCL: useCL)
            let memory = try DoryX86ByteArrayMemory(bytes: bytes)
            var state = try DoryX86ArchitecturalState(
              registers: .init(rax: 0x81, rcx: UInt64(count)), rip: 0, rflags: flags)
            try retire(bytes, state: &state, memory: memory)
            #expect(state.registers.rax == 0x81)
            #expect(state.rflags == flags)
          }
        }
      }
    }
  }

  @Test func throughCarryFullRotationsPreserveBothDataAndFlags() throws {
    for width in [8, 16] {
      for group: UInt8 in [2, 3] {
        for count in (width == 8 ? [9, 18, 27] : [17]) {
          for carry in [false, true] {
            let bytes = rotateBytes(width: width, group: group,
              count: UInt8(count), useCL: false)
            let memory = try DoryX86ByteArrayMemory(bytes: bytes)
            var flags: DoryX86RFLAGS = [.reservedOne, .overflow, .zero, .auxiliaryCarry]
            if carry { flags.insert(.carry) }
            var state = try DoryX86ArchitecturalState(
              registers: .init(rax: 0xABCD_1234_5678_4281), rip: 0, rflags: flags)
            try retire(bytes, state: &state, memory: memory)
            #expect(state.registers.rax == 0xABCD_1234_5678_4281)
            #expect(state.rflags == flags)
          }
        }
      }
    }
  }

  @Test func maskedOneCountsProduceDefinedCarryAndOverflow() throws {
    // ROL/ROR/RCL/RCR of 0x81 with CF=0: all set CF; only ROR clears OF.
    for (group, result, overflow): (UInt8, UInt64, Bool) in [
      (0, 3, true), (1, 0xC0, false), (2, 2, true), (3, 0x40, true),
    ] {
      for count: UInt8 in [1, 33] {
        let bytes = rotateBytes(width: 8, group: group, count: count, useCL: false)
        let memory = try DoryX86ByteArrayMemory(bytes: bytes)
        var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x81), rip: 0)
        try retire(bytes, state: &state, memory: memory)
        #expect(state.registers.rax == result)
        #expect(state.rflags.contains(.carry))
        #expect(state.rflags.contains(.overflow) == overflow)
      }
    }
  }

  @Test func crossPageShiftFaultsPreserveTheEntireDestinationAndInstructionState() throws {
    for width in [16, 32, 64] {
      for bytes in memoryShiftBytes(width: width, count: 1) {
        let memory = try pagedMemory(bytes: bytes)
        var state = try pagedState()
        let paging = DoryX86PagingUnit()
        let before = state
        let data = try memory.read(at: 0x8FFF, byteCount: 8)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64,
          pagingUnit: paging) == writeFault())
        var expected = before
        expected.control.cr2 = 0x9000
        #expect(state == expected)
        #expect(try memory.read(at: 0x8FFF, byteCount: 8) == data)
        // Repair only the missing write permission and retry the original instruction.
        try memory.writeScalar(at: 0xD048, value: 0x9007, byteCount: 8)
        paging.invalidateAll()
        let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64,
          pagingUnit: paging) == .retired(instruction))
        #expect(state.rip == 0x1000 + UInt64(bytes.count))
        #expect(try memory.read(at: 0x8FFF, byteCount: width / 8) != Array(data.prefix(width / 8)))
        #expect(try memory.read(at: 0x8FFF + UInt64(width / 8), byteCount: 8 - width / 8)
          == Array(data.dropFirst(width / 8)))
      }
    }
  }

  @Test func zeroCountMemoryOperandsStillValidateTheFullWritableRange() throws {
    for bytes in memoryShiftBytes(width: 16, count: 0) {
      let memory = try pagedMemory(bytes: bytes)
      var state = try pagedState()
      let before = state
      let data = try memory.read(at: 0x8FFF, byteCount: 8)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64,
        pagingUnit: .init()) == writeFault())
      var expected = before
      expected.control.cr2 = 0x9000
      #expect(state == expected)
      #expect(try memory.read(at: 0x8FFF, byteCount: 8) == data)
    }
  }

  @Test func bothNativeTiersDeclineAffectedRotatesAndMemoryShiftsWithoutEffects() throws {
    #if arch(arm64)
      let cases = [rotateBytes(width: 8, group: 0, count: 8, useCL: false),
        rotateBytes(width: 16, group: 1, count: 16, useCL: true)]
        + memoryShiftBytes(width: 16, count: 1)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
          optimization: optimization)
        for bytes in cases {
          let memory = try DoryX86ByteArrayMemory(byteCount: 64)
          try memory.write(at: 0, bytes: bytes)
          try memory.write(at: 32, bytes: [0x81, 0x42])
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: 0x81, rcx: 16, rdx: 0x1234, rbx: 32), rip: 0)
          let before = state
          let data = memory.snapshot()
          #expect(try executor.executeSummary(
            byteProvider: { Array(bytes.prefix($0)) }, at: 0, mode: .long64,
            addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory) == nil)
          #expect(state == before)
          #expect(memory.snapshot() == data)
          executor.invalidateAll()
        }
      }
    #endif
  }

  private func rotateBytes(width: Int, group: UInt8, count: UInt8, useCL: Bool) -> [UInt8] {
    let prefix: [UInt8] = width == 16 ? [0x66] : (width == 64 ? [0x48] : [])
    let opcode: UInt8 = useCL ? (width == 8 ? 0xD2 : 0xD3) : (width == 8 ? 0xC0 : 0xC1)
    return prefix + [opcode, 0xC0 | (group << 3)] + (useCL ? [] : [count])
  }

  private func memoryShiftBytes(width: Int, count: UInt8) -> [[UInt8]] {
    let prefix: [UInt8] = width == 16 ? [0x66] : (width == 64 ? [0x48] : [])
    let groups: [UInt8] = [0, 1, 2, 3, 4, 5, 7]
    return groups.map { prefix + [0xC1, ($0 << 3) | 3, count] }
      + [prefix + [0x0F, 0xA4, 0x13, count], prefix + [0x0F, 0xAC, 0x13, count]]
  }

  private func retire(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory) throws {
    let instruction = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .retired(instruction))
  }

  private func pagedMemory(bytes: [UInt8]) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [(0xA000, 0xB007), (0xB000, 0xC007),
      (0xC000, 0xD007), (0xD008, 0x1007), (0xD040, 0x8007), (0xD048, 0x9005)] {
      try memory.writeScalar(at: address, value: value, byteCount: 8)
    }
    try memory.write(at: 0x1000, bytes: bytes)
    try memory.write(at: 0x8FFF, bytes: [0x81, 0x42, 0x96, 0x28, 0xC3, 0xF4, 0x65, 0xD7])
    return memory
  }

  private func pagedState() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rcx: 1, rdx: 0x1234_5678_9ABC_DEF0, rbx: 0x8FFF), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow, .zero],
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 0x8001_0011, cr2: 0x1234, cr3: 0xA000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }

  private func writeFault() -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: 7,
      instructionPointer: 0x1000, linearAddress: 0x9000))
  }
}
