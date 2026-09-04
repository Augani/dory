import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A FINIT/FNINIT and FCLEX/FNCLEX, pages 3-345/3-346
// and 3-320. Pointer/opcode reset coverage is in the environment transfer suite;
// these cases cover physical register preservation and defined reset flag bits.
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
@Suite struct DoryX86LegacyFloatingPointResetTests {
  @Test func fninitResetsOnlyModeledControlStatusAndTagsInEveryExecutionMode() throws {
    for mode in modes {
      for top: UInt16 in 0..<8 {
        var state = try state(mode: mode, status: 0xC7FF | (top << 11))
        let before = state
        let memory = ResetMemory(code: [0xDB, 0xE3])
        let decoded = try DoryX86Decoder().decode([0xDB, 0xE3], at: state.rip, mode: mode)

        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))

        var expected = before
        expected.rip += 2
        expected.floatingPoint.x87ControlWord = 0x037F
        expected.floatingPoint.x87StatusWord = 0
        expected.floatingPoint.x87TagWord = 0xFFFF
        #expect(state == expected)
        #expect(memory.dataAccesses == 0)
      }
    }
  }

  @Test func fnclexClearsEveryDefinedExceptionBitAndPreservesTopAndOtherState() throws {
    let statuses: [UInt16] = [0, 0xFFFF, 0xB8FF, 0x4700]
      + (0..<16).map { UInt16(1) << UInt16($0) }
    for mode in modes {
      for status in statuses {
        var state = try state(mode: mode, status: status)
        let before = state
        let memory = ResetMemory(code: [0xDB, 0xE2])
        let decoded = try DoryX86Decoder().decode([0xDB, 0xE2], at: state.rip, mode: mode)

        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))

        #expect(state.floatingPoint.x87StatusWord & 0x80FF == 0)
        #expect(state.floatingPoint.x87StatusWord & 0x3800 == before.floatingPoint.x87StatusWord & 0x3800)
        // C0/C1/C2/C3 are undefined for FNCLEX. Normalize them rather than
        // asserting that retaining the implementation's values is architectural.
        var actual = state
        actual.floatingPoint.x87StatusWord &= ~UInt16(0x4700)
        var expected = before
        expected.rip += 2
        expected.floatingPoint.x87StatusWord &= 0x3800
        #expect(actual == expected)
        #expect(memory.dataAccesses == 0)
      }
    }
  }

  @Test func fninitPreservesMMXRegisterAliasesObservableBySubsequentMOVQ() throws {
    // MM3 aliases physical R3, irrespective of the previous x87 TOP. FNINIT
    // empties tags but does not destroy those bytes; MOVQ must still see them.
    let bytes: [UInt8] = [0xDB, 0xE3, 0x48, 0x0F, 0x7E, 0xD8]
    let memory = ResetMemory(code: bytes)
    var state = try state(status: 5 << 11)
    let initial = state
    for _ in 0..<2 {
      let decoded = try DoryX86Decoder().decode(
        memory.instructionBytes(at: state.rip, maximumCount: 15), at: state.rip, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
    }
    let original = initial.floatingPoint.x87[3].bytes
    let expected = original.prefix(8).enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    #expect(state.registers.rax == expected)
    #expect(state.floatingPoint.x87 == initial.floatingPoint.x87)
    #expect(state.floatingPoint.ymm == initial.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == initial.floatingPoint.mxcsr)
    #expect(state.floatingPoint.mxcsrMask == initial.floatingPoint.mxcsrMask)
    #expect(memory.dataAccesses == 0)
  }

  @Test func waitingSpellingsKeepSeparateWaitAndNonWaitingInstructionBoundaries() throws {
    for opcode: UInt8 in [0xE2, 0xE3] {
      // MP=0 permits WAIT despite TS=1; the following FN instruction must #NM
      // at its own RIP, leaving all floating-point state unchanged.
      let memory = ResetMemory(code: [0x9B, 0xDB, opcode])
      var state = try state(status: 0) // No pending numeric exception is part of this admission test.
      state.control.cr0 |= 8
      state.control.cr0 &= ~UInt64(2)
      let initial = state
      let wait = try DoryX86Decoder().decode([0x9B, 0xDB, opcode], at: state.rip, mode: .long64)
      #expect(wait.length == 1 && wait.operation == .waitForCoprocessor)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(wait))
      let atFN = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .deviceNotAvailable, vector: 7, instructionPointer: 0x1001)))
      #expect(state == atFN && state.floatingPoint == initial.floatingPoint)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func disabledNonWaitingInstructionsCannotPartiallyResetState() throws {
    for mode in modes {
      for bytes: [UInt8] in [[0xDB, 0xE2], [0xDB, 0xE3]] {
        for disabled: UInt64 in [4, 8, 12] {
          var state = try state(mode: mode)
          state.control.cr0 |= disabled
          let before = state
          let memory = ResetMemory(code: bytes)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == .exception(.init(kind: .deviceNotAvailable, vector: 7, instructionPointer: 0x1000)))
          #expect(state == before && memory.dataAccesses == 0)
        }
      }
    }
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func state(mode: DoryX86ExecutionMode = .long64, status: UInt16 = 0xFFFF) throws -> DoryX86ArchitecturalState {
    let registers = try (0..<8).map { register in
      try DoryX86RegisterBytes(bytes: (0..<10).map { UInt8(0x30 + register * 13 + $0) }, expectedByteCount: 10)
    }
    let vectors = try (0..<16).map { register in
      try DoryX86RegisterBytes(bytes: (0..<32).map { UInt8(truncatingIfNeeded: register * 19 + $0) },
        expectedByteCount: 32)
    }
    let fp = try DoryX86FloatingPointState(x87: registers, ymm: vectors,
      x87ControlWord: 0x0B40, x87StatusWord: status, x87TagWord: 0x1234,
      mxcsr: 0xDFC5, mxcsrMask: 0xFFFF)
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0xABCDEF, rcx: 0x123456, rdx: 0xFEDCBA), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow], cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31, cr2: 0xAB00), floatingPoint: fp)
  }
}

private final class ResetMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses = 0
  init(code: [UInt8]) { self.code = code }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0x10)
    }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validateRead(at: address, byteCount: byteCount)
    return []
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
  }
  func synchronize() {}
}
