import Testing

@testable import DoryDBTX86

@Suite struct DoryX86AccumulatorSignExtensionTests {
  @Test func systemdCDQEReducerIgnoresAlreadySignExtendedRAXUpperBits() throws {
    // Source39 systemd run trapped in the checked UInt32(RAX) conversion with
    // host x8=0xffffffffffffffe7. CDQE reads EAX, including when RAX was already
    // sign extended. This reducer exercises the fixed operation without a host crash.
    let form = Form(mode: .long64, prefix: [0x48], width: .quadword)
    try verify(form, input: 0xFFFF_FFFF_FFFF_FFE7, outputRAX: 0xFFFF_FFFF_FFFF_FFE7)
  }

  @Test func lowAccumulatorExtensionsHonorWidthsPrefixesAndPreservedUpperBits() throws {
    for form in forms {
      for vector in lowVectors(width: form.width) {
        try verify(form, input: vector.0, outputRAX: vector.1)
      }
    }
  }

  @Test func highHalfExtensionsPreserveTheAccumulatorAndUnwrittenRegisterBits() throws {
    for form in forms {
      for negative in [false, true] {
        let input: UInt64
        let expectedRDX: UInt64
        switch form.width {
        case .word:
          input = negative ? 0xAABB_CCDD_1234_8000 : 0xAABB_CCDD_1234_7FFF
          expectedRDX = negative ? 0x1234_5678_9ABC_FFFF : 0x1234_5678_9ABC_0000
        case .doubleword:
          input = negative ? 0xAABB_CCDD_8000_0000 : 0xAABB_CCDD_7FFF_FFFF
          expectedRDX = negative ? 0xFFFF_FFFF : 0
        case .quadword:
          input = negative ? 0x8000_0000_0000_0000 : 0x7FFF_FFFF_FFFF_FFFF
          expectedRDX = negative ? .max : 0
        case .byte:
          Issue.record("98/99 have no byte operand form")
          continue
        }
        try verify(form, input: input, outputRAX: input, intoHighHalf: true, outputRDX: expectedRDX)
      }
    }
  }

  @Test func bothNativeTiersDeclineBeforeEffectsThenInterpreterRetiresExactlyOnce() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        for form in forms {
          for highHalf in [false, true] {
            let bytes = form.prefix + [highHalf ? 0x99 : 0x98]
            let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
            var state = try initialState(mode: form.mode, rax: .max)
            let before = state
            let snapshot = memory.snapshot()
            let summary = try executor.executeSummary(
              byteProvider: { Array(bytes.prefix($0)) }, at: state.rip, mode: form.mode,
              addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory)
            #expect(summary == nil)
            #expect(state == before && memory.snapshot() == snapshot)
            let expectedRAX: UInt64 = highHalf ? .max : (form.width == .doubleword ? 0xFFFF_FFFF : .max)
            let expectedRDX: UInt64 = form.width == .word ? 0x1234_5678_9ABC_FFFF
              : (form.width == .doubleword ? 0xFFFF_FFFF : .max)
            var expected = before
            expected.registers.rax = expectedRAX
            if highHalf { expected.registers.rdx = expectedRDX }
            expected.rip += UInt64(bytes.count)
            let decoded = try DoryX86Decoder().decode(bytes, at: before.rip, mode: form.mode)
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: form.mode) == .retired(decoded))
            #expect(state == expected && memory.snapshot() == snapshot)
          }
        }
      }
    #endif
  }

  @Test func lockPrefixRaisesInvalidOpcodeWithoutChangingTheAccumulatorOrHighHalf() throws {
    for form in forms {
      for opcode: UInt8 in [0x98, 0x99] {
        let bytes = [UInt8(0xF0)] + form.prefix + [opcode]
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
        var state = try initialState(mode: form.mode, rax: .max)
        let before = state
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: form.mode)
          == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: before.rip)))
        #expect(state == before)
      }
    }
  }

  private func verify(
    _ form: Form, input: UInt64, outputRAX: UInt64,
    intoHighHalf: Bool = false, outputRDX: UInt64 = 0x1234_5678_9ABC_DEF0
  ) throws {
    let bytes = form.prefix + [intoHighHalf ? 0x99 : 0x98]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var state = try initialState(mode: form.mode, rax: input)
    var expected = state
    expected.registers.rax = outputRAX
    expected.registers.rdx = outputRDX
    expected.rip += UInt64(bytes.count)
    let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: form.mode)
    #expect(decoded.operation == .signExtendAccumulator(width: form.width, intoHighHalf: intoHighHalf))
    let beforeBytes = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: form.mode) == .retired(decoded))
    #expect(state == expected)
    #expect(memory.snapshot() == beforeBytes)
  }

  private struct Form {
    let mode: DoryX86ExecutionMode
    let prefix: [UInt8]
    let width: DoryX86OperandWidth
  }

  private var forms: [Form] {
    var forms: [Form] = []
    for mode: DoryX86ExecutionMode in [.real16, .protected16] {
      forms += [.init(mode: mode, prefix: [], width: .word), .init(mode: mode, prefix: [0x66], width: .doubleword)]
    }
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      forms += [.init(mode: mode, prefix: [], width: .doubleword), .init(mode: mode, prefix: [0x66], width: .word)]
    }
    // REX.W wins over 66; REX.B and address-size overrides do not select another accumulator.
    forms += [.init(mode: .long64, prefix: [0x48], width: .quadword),
      .init(mode: .long64, prefix: [0x66, 0x48], width: .quadword),
      .init(mode: .long64, prefix: [0x67, 0x49], width: .quadword)]
    return forms
  }

  private func lowVectors(width: DoryX86OperandWidth) -> [(UInt64, UInt64)] {
    switch width {
    case .word:
      [(0xFEDC_BA98_7654_1280, 0xFEDC_BA98_7654_FF80),
       (0xFEDC_BA98_7654_FF7F, 0xFEDC_BA98_7654_007F),
       (0xFFFF_FFFF_FFFF_0000, 0xFFFF_FFFF_FFFF_0000)]
    case .doubleword:
      [(0xFEDC_BA98_FFFF_8001, 0xFFFF_8001),
       (0xFEDC_BA98_FFFF_7FFF, 0x7FFF),
       (0xFFFF_FFFF_FFFF_0000, 0)]
    case .quadword:
      [(0xFFFF_FFFF_FFFF_FFE7, 0xFFFF_FFFF_FFFF_FFE7),
       (0xDEAD_BEEF_1234_5678, 0x1234_5678),
       (0x0000_0000_8000_0000, 0xFFFF_FFFF_8000_0000)]
    case .byte: []
    }
  }

  private func initialState(mode: DoryX86ExecutionMode, rax: UInt64) throws -> DoryX86ArchitecturalState {
    var registers = DoryX86GeneralRegisters()
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      registers[register] = 0x7654_3210_FEDC_BA00 + UInt64(index)
    }
    registers.rax = rax
    registers.rdx = 0x1234_5678_9ABC_DEF0
    return try .init(registers: registers, rip: 0x1000,
      rflags: [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow],
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      control: .init(cr0: mode == .real16 ? 0 : 1))
  }
}
