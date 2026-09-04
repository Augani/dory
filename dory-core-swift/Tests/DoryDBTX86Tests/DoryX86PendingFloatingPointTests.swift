import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 3A Event16 and §15.5.1, Vol. 2D WAIT/FWAIT:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// Tests begin with explicit numeric status. Arithmetic exception generation and
// legacy NE=0 external FERR/IGNNE signaling are not qualified by this suite.
@Suite struct DoryX86PendingFloatingPointTests {
  private let waiting: [[UInt8]] = [
    [0x9B], [0xD9, 0xD0], [0xD9, 0xE8], // WAIT, FNOP, FLD1
    [0x0F, 0x6E, 0xC0], [0x0F, 0x77], // MOVD MM0,EAX and EMMS also wait.
  ]

  @Test func everyUnmaskedNumericFlagFaultsAtTheWaitingInstructionInAllModes() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for bit: UInt16 in 0..<6 {
        for bytes in waiting {
          var state = try state(mode: mode, bit: bit)
          let before = state
          let memory = PendingMemory(code: bytes)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == .exception(.init(kind: .x87FloatingPoint, vector: 16, instructionPointer: 0x1000)))
          #expect(state == before && memory.dataAccesses == 0)
        }
      }
    }
  }

  @Test func maskedFlagsWithoutSummaryDoNotInventPendingNumericExceptions() throws {
    for bytes in waiting {
      for status: UInt16 in [0, 0x3F, 0x7F, 0x4700] {
        var state = try state()
        state.floatingPoint.x87ControlWord |= 0x3F
        state.floatingPoint.x87StatusWord = status
        let memory = PendingMemory(code: bytes)
        let instruction = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
        #expect(memory.dataAccesses == 0)
      }
    }
  }

  @Test func nonWaitingFNAndFXFormsIgnorePendingStatus() throws {
    let forms: [[UInt8]] = [
      [0xDB, 0xE3], [0xDB, 0xE2], [0xDF, 0xE0], // FNINIT/FNCLEX/FNSTSW AX
      [0xD9, 0x3B], [0xDD, 0x3B], [0xD9, 0x33], // FNSTCW/FNSTSW/FNSTENV [RBX]
      [0x0F, 0xAE, 0x03], [0x0F, 0xAE, 0x0B], // FXSAVE/FXRSTOR [RBX]
    ]
    for bytes in forms {
      var state = try state()
      let memory = PendingMemory(code: bytes)
      let instruction = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
      #expect(DoryX86LegacyFloatingPointPolicy.executionFault(instruction, state: state) == nil)
      // Data forms reach the deliberately inaccessible operand; this proves
      // pending status does not take precedence over their ordinary page fault.
      let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      if bytes == [0xDB, 0xE3] || bytes == [0xDB, 0xE2] || bytes == [0xDF, 0xE0] {
        #expect(result == .retired(instruction) && memory.dataAccesses == 0)
      } else {
        guard case .exception(let exception) = result else { Issue.record("Expected data fault"); continue }
        #expect(exception.kind == .pageFault && memory.dataAccesses > 0)
      }
    }
  }

  @Test func admissionFaultsPrecedeMFAndMFPredatesDataOperands() throws {
    // FLD m32 and MOVQ MM0,m64 would fault on data reads without pending status.
    for bytes: [UInt8] in [[0xD9, 0x03], [0x0F, 0x6F, 0x03]] {
      for controls: UInt64 in [0, 4, 8, 12] {
        var state = try state()
        state.control.cr0 |= controls
        let before = state
        let memory = PendingMemory(code: bytes)
        let kind: DoryX86Exception.Kind = controls == 0 ? .x87FloatingPoint
          : bytes[0] == 0x0F && controls & 4 != 0 ? .invalidOpcode : .deviceNotAvailable
        let vector: UInt8 = kind == .x87FloatingPoint ? 16 : kind == .invalidOpcode ? 6 : 7
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: kind, vector: vector, instructionPointer: 0x1000)))
        #expect(state == before && memory.dataAccesses == 0)
      }
    }
    for mp in [false, true] {
      var state = try state()
      state.control.cr0 |= 8
      if mp { state.control.cr0 |= 2 } else { state.control.cr0 &= ~UInt64(2) }
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: PendingMemory(code: [0x9B]), mode: .long64)
        == .exception(.init(kind: mp ? .deviceNotAvailable : .x87FloatingPoint,
          vector: mp ? 7 : 16, instructionPointer: 0x1000)))
      #expect(state == before)
    }
  }

  @Test func clearingStatusAndUnmaskingExistingFlagsChangeTheNextWaitBoundary() throws {
    var cleared = try state()
    let memory = PendingMemory(code: [0xDB, 0xE2, 0x9B])
    for _ in 0..<2 {
      guard case .retired = DoryX86Interpreter().step(state: &cleared, memory: memory, mode: .long64)
      else { Issue.record("FNCLEX followed by WAIT should retire"); return }
    }
    #expect(cleared.rip == 0x1003 && cleared.floatingPoint.x87StatusWord & 0x3F == 0)
    for bit: UInt16 in 0..<6 {
      var unmasked = try state(bit: bit)
      unmasked.floatingPoint.x87ControlWord |= 0x3F
      unmasked.floatingPoint.x87StatusWord &= ~UInt16(0x8080)
      let beforeStatus = unmasked.floatingPoint.x87StatusWord
      let backing = try DoryX86ByteArrayMemory(byteCount: 0x9000)
      // FLDCW [RBX]; FNSTSW AX; FWAIT. Observe the summary before the fault.
      try backing.write(at: 0x1000, bytes: [0xD9, 0x2B, 0xDF, 0xE0, 0x9B])
      try backing.writeScalar(at: 0x8000, value: UInt64(0x037F & ~(UInt16(1) << bit)), byteCount: 2)
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(state: &unmasked, memory: backing, mode: .long64)
        else { Issue.record("FLDCW and nonwaiting status read should retire"); return }
      }
      #expect(unmasked.floatingPoint.x87StatusWord == beforeStatus | 0x8080)
      #expect(unmasked.registers.rax & 0xFFFF == UInt64(beforeStatus | 0x8080))
      let before = unmasked
      #expect(DoryX86Interpreter().step(state: &unmasked, memory: backing, mode: .long64)
        == .exception(.init(kind: .x87FloatingPoint, vector: 16, instructionPointer: 0x1004)))
      #expect(unmasked == before)
    }
  }

  @Test func wordEnvironmentLoadRecomputesSummaryBeforeTheNextWait() throws {
    for pending in [false, true] {
      let backing = try DoryX86ByteArrayMemory(byteCount: 0x9000)
      // Protected16 FLDENV [8000]; FNSTSW AX; FWAIT uses the 14-byte layout.
      // This does not qualify the separately incomplete 28-byte layout/pointers.
      try backing.write(at: 0x1000, bytes: [0xD9, 0x26, 0, 0x80, 0xDF, 0xE0, 0x9B])
      let control: UInt64 = pending ? 0x037E : 0x037F
      try backing.writeScalar(at: 0x8000, value: control, byteCount: 2)
      try backing.writeScalar(at: 0x8002, value: 0x4501, byteCount: 2)
      try backing.writeScalar(at: 0x8004, value: 0xFFFF, byteCount: 2)
      var loaded = try state(mode: .protected16)
      loaded.floatingPoint.x87StatusWord = 0
      loaded.floatingPoint.x87ControlWord = 0x037F
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(state: &loaded, memory: backing, mode: .protected16)
        else { Issue.record("FLDENV and nonwaiting status read should retire"); return }
      }
      let expected: UInt16 = pending ? 0xC581 : 0x4501
      #expect(loaded.floatingPoint.x87StatusWord == expected)
      #expect(loaded.registers.rax & 0xFFFF == UInt64(expected))
      let before = loaded
      let result = DoryX86Interpreter().step(state: &loaded, memory: backing, mode: .protected16)
      if pending {
        #expect(result == .exception(.init(kind: .x87FloatingPoint, vector: 16,
          instructionPointer: 0x1006)))
        #expect(loaded == before)
      } else {
        #expect(result == .retired(try DoryX86Decoder().decode([0x9B], at: 0x1006, mode: .protected16)))
        #expect(loaded.rip == 0x1007)
      }
    }
  }

  @Test func environmentStoreSavesPendingStatusThenClearsSummaryOnlyAfterSuccess() throws {
    let bytes: [UInt8] = [0xD9, 0x36, 0, 0x80, 0x9B] // FNSTENV [8000]; FWAIT, protected16.
    let backing = try DoryX86ByteArrayMemory(byteCount: 0x9000)
    try backing.write(at: 0x1000, bytes: bytes)
    var saved = try state(mode: .protected16)
    let before = saved
    guard case .retired = DoryX86Interpreter().step(state: &saved, memory: backing, mode: .protected16)
    else { Issue.record("FNSTENV should ignore pending status"); return }
    #expect(try backing.readScalar(at: 0x8000, byteCount: 2) == UInt64(before.floatingPoint.x87ControlWord))
    #expect(try backing.readScalar(at: 0x8002, byteCount: 2) == UInt64(before.floatingPoint.x87StatusWord))
    #expect(saved.floatingPoint.x87ControlWord & 0x3F == 0x3F)
    #expect(saved.floatingPoint.x87StatusWord == before.floatingPoint.x87StatusWord & ~UInt16(0x8080))
    guard case .retired = DoryX86Interpreter().step(state: &saved, memory: backing, mode: .protected16)
    else { Issue.record("Masked FWAIT should retire"); return }
    #expect(saved.rip == 0x1005)

    var failed = before
    let denied = PendingMemory(code: bytes)
    guard case .exception(let fault) = DoryX86Interpreter().step(state: &failed, memory: denied, mode: .protected16)
    else { Issue.record("Expected inaccessible environment destination to fault"); return }
    #expect(fault.kind == .pageFault && denied.dataAccesses > 0)
    var expected = before
    expected.control.cr2 = 0x8000
    #expect(failed == expected)
  }

  @Test func fxrstorLeavesConsistentLoadedSummaryForTheNextWaitWithoutDeliveringEarly() throws {
    for pending in [false, true] {
      let backing = try DoryX86ByteArrayMemory(byteCount: 0x9000)
      try backing.write(at: 0x1000, bytes: [0x0F, 0xAE, 0x0B, 0xDF, 0xE0, 0x9B])
      let status: UInt64 = pending ? 0x8081 : 1
      try backing.writeScalar(at: 0x8000, value: pending ? 0x037E : 0x037F, byteCount: 2)
      try backing.writeScalar(at: 0x8002, value: status, byteCount: 2)
      try backing.writeScalar(at: 0x8018, value: 0x1F80, byteCount: 4)
      var restored = try state()
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(state: &restored, memory: backing, mode: .long64)
        else { Issue.record("FXRSTOR and nonwaiting status read should retire"); return }
      }
      #expect(restored.floatingPoint.x87StatusWord == UInt16(status))
      #expect(restored.registers.rax & 0xFFFF == status)
      let before = restored
      let result = DoryX86Interpreter().step(state: &restored, memory: backing, mode: .long64)
      if pending {
        #expect(result == .exception(.init(kind: .x87FloatingPoint, vector: 16, instructionPointer: 0x1005)))
        #expect(restored == before)
      } else {
        #expect(result == .retired(try DoryX86Decoder().decode([0x9B], at: 0x1005, mode: .long64)))
        #expect(restored.rip == 0x1006)
      }
    }
    // Intel describes restoring x87 state; QEMU and Bochs differ on contradictory
    // ES/mask images. Their normalization is intentionally not claimed here.
  }

  private func state(mode: DoryX86ExecutionMode = .long64, bit: UInt16 = 0) throws -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState()
    fp.x87ControlWord &= ~(UInt16(1) << bit)
    fp.x87StatusWord = 0x8080 | (UInt16(1) << bit) // Consistent ES and backward-compatible B.
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0x1234, rbx: 0x8000), rip: 0x1000,
      cs: .init(selector: mode == .real16 ? 0 : 8, attributes: attributes, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31, cr4: 1 << 9), floatingPoint: fp)
  }
}

private final class PendingMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses = 0
  init(code: [UInt8]) { self.code = code }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 16)
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
