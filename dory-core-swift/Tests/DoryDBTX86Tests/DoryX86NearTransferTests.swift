import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2A CALL/Jcc/JMP and Vol. 2B RET. These vectors cover
// ordinary near transfers; CET and long-mode RET operand overrides are separate.
@Suite struct DoryX86NearTransferTests {
  @Test func legacyCallsAndReturnsUseOperandWidthIndependentlyOfStackAddressSize() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      for override in [false, true] {
        for stack32 in [false, true] where mode != .real16 || !stack32 {
          for indirect in [false, true] {
            let width = ((mode != .protected32) != override) ? 2 : 4
            let prefix: [UInt8] = override ? [0x66, 0x67] : [0x67]
            let code = prefix + (indirect ? [0xFF, 0xD0] : [0xE8] + le(0x20, width))
            let target: UInt64 = indirect ? 0x2000 : 0x1000 + UInt64(code.count) + 0x20
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x30000)
            try memory.write(at: 0x1000, bytes: code)
            try memory.write(at: target, bytes: prefix + [0xC2, 6, 0])
            try memory.write(at: 0x7FF0, bytes: [UInt8](repeating: 0xAA, count: 32))
            var state = try state(mode, stack32: stack32)
            state.registers.rax = target
            let before = state
            try retired(&state, memory, mode)
            #expect(state.rip == target)
            let expectedSP = (before.registers.rsp - UInt64(width))
            #expect(state.registers.rsp == expectedSP)
            #expect(try memory.readScalar(at: 0x8000 - UInt64(width), byteCount: width)
              == (0x1000 + UInt64(code.count)))
            #expect(try memory.readScalar(at: 0x8000, byteCount: 1) == 0xAA)
            try retired(&state, memory, mode)
            #expect(state.rip == 0x1000 + UInt64(code.count))
            #expect(state.registers.rsp == before.registers.rsp + 6)
            #expect(state.cs == before.cs && state.rflags == before.rflags)
          }
        }
      }
    }
  }

  @Test func wordCallWrapsTargetAndReturnAddressBeforeLegacyLimitChecks() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x30000)
    // EIP+4+0x30 wraps to0x24 for a16-bit operand in a32-bit code segment.
    try memory.write(at: 0x1FFF0, bytes: [0x66, 0xE8, 0x30, 0])
    try memory.write(at: 0x24, bytes: [0x66, 0xC3])
    var state = try state(.protected32)
    state.rip = 0x1FFF0
    try retired(&state, memory, .protected32)
    #expect(state.rip == 0x24 && state.registers.rsp == 0x7FFE)
    #expect(try memory.readScalar(at: 0x7FFE, byteCount: 2) == 0xFFF4)
    try retired(&state, memory, .protected32)
    #expect(state.rip == 0xFFF4 && state.registers.rsp == 0x8000)
  }

  @Test func doublewordTransferInSixteenBitCodePreservesHighEIPOnSubsequentFetch() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x30000)
    try memory.write(at: 0x1000, bytes: [0x66, 0xE8, 0, 0, 1, 0])
    try memory.write(at: 0x11006, bytes: [0x90, 0x66, 0xC3])
    var state = try state(.protected16)
    try retired(&state, memory, .protected16)
    #expect(state.rip == 0x11006 && state.registers.rsp == 0x7FFC)
    try retired(&state, memory, .protected16)
    #expect(state.rip == 0x11007)
    try retired(&state, memory, .protected16)
    #expect(state.rip == 0x1006 && state.registers.rsp == 0x8000)
  }

  @Test func legacyTargetLimitsFaultAtTheTransferWithoutPublishingStackOrCounterEffects() throws {
    for code: [UInt8] in [
      [0xE8, 0, 0x10, 0, 0], [0xFF, 0xD0], [0xFF, 0xE0],
      [0xC3], [0xC2, 8, 0], [0xE9, 0, 0x10, 0, 0],
      [0x0F, 0x84, 0, 0x10, 0, 0], [0xE2, 0x7F],
    ] {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
      try memory.write(at: 0x1000, bytes: code)
      try memory.writeScalar(at: 0x8000, value: 0x2000, byteCount: 4)
      var state = try state(.protected32)
      state.cs.limit = 0x100F
      state.registers.rax = 0x2000
      state.registers.rcx = 2
      state.rflags.insert(.zero)
      let before = state
      let bytes = memory.snapshot()
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
        == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
      #expect(state == before && memory.snapshot() == bytes)
    }
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    try memory.write(at: 0x1000, bytes: [0x0F, 0x84, 0, 0x10, 0, 0])
    var notTaken = try state(.protected32)
    notTaken.cs.limit = 0x100F
    try retired(&notTaken, memory, .protected32)
    #expect(notTaken.rip == 0x1006)
  }

  @Test func indirectStackOperandUsesTheOriginalStackPointerAndFullWritePreflight() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    try memory.write(at: 0x1000, bytes: [0x66, 0xFF, 0x14, 0x24]) // CALL word [ESP]
    try memory.writeScalar(at: 0x8000, value: 0x2345, byteCount: 2)
    var state = try state(.protected32, stack32: true)
    try retired(&state, memory, .protected32)
    #expect(state.rip == 0x2345 && state.registers.rsp == 0x7FFE)
    #expect(try memory.readScalar(at: 0x7FFE, byteCount: 2) == 0x1004)
    #expect(try memory.readScalar(at: 0x8000, byteCount: 2) == 0x2345)

    try memory.write(at: 0x1000, bytes: [0x66, 0xE8, 0, 0])
    var limited = try self.state(.protected32)
    limited.ss.limit = 0x7FFF
    limited.registers.rsp = 0x8001 // The2-byte push straddles SS.limit.
    let before = limited
    let bytes = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &limited, memory: memory, mode: .protected32)
      == .exception(.init(kind: .stackSegment, vector: 12, errorCode: 0, instructionPointer: 0x1000)))
    #expect(limited == before && memory.snapshot() == bytes)
  }

  @Test func longRelativeBranchesIgnore66ForDisplacementAndCallReturnWidth() throws {
    for operation: [UInt8] in [[0xE8], [0xE9], [0x0F, 0x84]] {
      let code = [UInt8(0x66)] + operation + [UInt8(0x10), 0, 1, 0]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x20000)
      try memory.write(at: 0x1000, bytes: code)
      var state = try self.state(.long64)
      state.rflags.insert(.zero)
      let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
      #expect(instruction.bytes == code)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
      #expect(state.rip == 0x1000 + UInt64(code.count) + 0x10010)
      if operation == [0xE8] {
        #expect(state.registers.rsp == 0x7FF8)
        #expect(try memory.readScalar(at: 0x7FF8, byteCount: 8) == 0x1000 + UInt64(code.count))
      }
    }
  }

  @Test func sixteenBitDirectBranchesUseTheInterpreterForSegmentAndWidthChecks() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16] {
      for code: [UInt8] in [[0xEB, 0], [0x74, 0], [0x66, 0xEB, 0], [0x66, 0x74, 0]] {
        let block = try DoryX86IRTranslator().translate(code, at: 0x1000, mode: mode)
        #expect(block.terminator == .exit(.interpreter, resumeAt: 0x1000))
      }
    }
  }

  @Test func nativeFlat32BranchesRetainWordTargetsAndRejectNarrowSegmentsAfterCacheWarmup() throws {
    for optimization: DoryARM64JITOptimization in [.baseline, .optimizing] {
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
      let code: [UInt8] = [0x66, 0xE9, 0x30, 0]
      var wide = try state(.protected32)
      wide.rip = 0x1FFF0
      let result = try executor.execute(bytes: code, at: wide.rip, mode: .protected32,
        addressSpaceID: 0, maximumInstructions: 1, state: &wide)
      #expect(result != nil && wide.rip == 0x24)
      var limited = try state(.protected32)
      limited.rip = 0x1FFF0
      limited.cs.limit = 0xFFFF
      let before = limited
      #expect(try executor.execute(bytes: code, at: limited.rip, mode: .protected32,
        addressSpaceID: 0, maximumInstructions: 1, state: &limited) == nil)
      #expect(limited == before)
      #expect(try executor.executeChainedSummary(byteProvider: { _, count in Array(code.prefix(count)) },
        at: limited.rip, mode: .protected32, addressSpaceID: 0, maximumInstructions: 4,
        state: &limited) == nil)
      #expect(limited == before)
    }
  }

  private func state(_ mode: DoryX86ExecutionMode, stack32: Bool = true) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rsp: mode != .long64 && !stack32 ? 0x1234_8000 : 0x8000), rip: 0x1000,
      cs: .init(selector: mode == .real16 ? 0 : 8,
        attributes: mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B,
        limit: mode == .real16 ? 0xFFFF : .max),
      ss: .init(selector: 0x10, attributes: stack32 ? 0xC093 : 0x0093, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11))
  }

  private func retired(_ state: inout DoryX86ArchitecturalState, _ memory: DoryX86ByteArrayMemory,
    _ mode: DoryX86ExecutionMode) throws {
    let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
    guard case .retired = result else { Issue.record("Expected retirement: \(result)"); return }
  }
  private func le(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
}
