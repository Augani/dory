import Testing

@testable import DoryDBTX86

@Suite struct DoryX86VEXScalarCompareTests {
  private let interpreter = DoryX86Interpreter(
    profile: .init(
      identifier: "test-only.avx-scalar-compare-semantics",
      features: DoryX86CPUProfile.compatibleV1.features.union([.xsave, .avx]),
      physicalAddressBits: 40, linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000))

  @Test func ordinaryComparisonsSetOnlyZFPFCFAndPreserveOtherFlags() throws {
    let cases: [(Bool, UInt64, UInt64, DoryX86RFLAGS)] = [
      (false, UInt64(Float(1).bitPattern), UInt64(Float(2).bitPattern), [.carry]),
      (false, UInt64(Float(2).bitPattern), UInt64(Float(1).bitPattern), []),
      (true, Double(2).bitPattern, Double(2).bitPattern, [.zero]),
    ]
    for (doublePrecision, lhs, rhs, comparisonFlags) in cases {
      let code = instruction(ordered: false, doublePrecision: doublePrecision)
      var state = try initialState(
        lhs: lhs, rhs: rhs, doublePrecision: doublePrecision,
        rflags: [
          .reservedOne, .direction, .overflow, .sign, .auxiliaryCarry, .zero, .parity, .carry,
        ])
      try expectRetired(step(code, state: &state), code: code)
      #expect(state.rflags == [.reservedOne, .direction, comparisonFlags])
      #expect(state.floatingPoint.mxcsr == 0x1F80)
    }
  }

  @Test func quietNaNRaisesInvalidForCOMIButNotUCOMI() throws {
    for doublePrecision in [false, true] {
      let quietNaN: UInt64 = doublePrecision ? 0x7FF8_0000_0000_0001 : 0x7FC0_0001
      let one: UInt64 =
        doublePrecision
        ? Double(1).bitPattern : UInt64(Float(1).bitPattern)
      for ordered in [false, true] {
        let code = instruction(ordered: ordered, doublePrecision: doublePrecision)
        var state = try initialState(
          lhs: quietNaN, rhs: one, doublePrecision: doublePrecision,
          rflags: [.reservedOne, .overflow, .sign, .auxiliaryCarry])
        try expectRetired(step(code, state: &state), code: code)
        #expect(state.rflags == [.reservedOne, .zero, .parity, .carry])
        #expect(state.floatingPoint.mxcsr == 0x1F80 | (ordered ? 1 : 0))
      }
    }
  }

  @Test func signalingNaNRaisesInvalidForBothCOMIForms() throws {
    for doublePrecision in [false, true] {
      let signalingNaN: UInt64 = doublePrecision ? 0x7FF0_0000_0000_0001 : 0x7F80_0001
      let one: UInt64 =
        doublePrecision
        ? Double(1).bitPattern : UInt64(Float(1).bitPattern)
      for ordered in [false, true] {
        let code = instruction(ordered: ordered, doublePrecision: doublePrecision)
        var state = try initialState(
          lhs: one, rhs: signalingNaN, doublePrecision: doublePrecision,
          rflags: [.reservedOne])
        try expectRetired(step(code, state: &state), code: code)
        #expect(state.rflags == [.reservedOne, .zero, .parity, .carry])
        #expect(state.floatingPoint.mxcsr == 0x1F81)
      }
    }
  }

  @Test func unmaskedInvalidPublishesStickyStatusWithoutChangingFlagsOrRIP() throws {
    for doublePrecision in [false, true] {
      let signalingNaN: UInt64 = doublePrecision ? 0x7FF0_0000_0000_0001 : 0x7F80_0001
      let one: UInt64 =
        doublePrecision
        ? Double(1).bitPattern : UInt64(Float(1).bitPattern)
      for supportsXM in [false, true] {
        let code = instruction(ordered: false, doublePrecision: doublePrecision)
        var state = try initialState(
          lhs: signalingNaN, rhs: one, doublePrecision: doublePrecision,
          mxcsr: 0x1F00, supportsXM: supportsXM,
          rflags: [.reservedOne, .direction, .overflow, .carry])
        var expected = state
        expected.floatingPoint.mxcsr |= 1
        #expect(
          step(code, state: &state)
            == .exception(
              .init(
                kind: supportsXM ? .simdFloatingPoint : .invalidOpcode,
                vector: supportsXM ? 19 : 6, instructionPointer: 0x1000)))
        #expect(state == expected)
      }
    }
  }

  @Test func denormalsHonorMaskAndDAZBeforeComparing() throws {
    for doublePrecision in [false, true] {
      let denormal: UInt64 = 1
      let zero: UInt64 = 0
      let code = instruction(ordered: false, doublePrecision: doublePrecision)

      var masked = try initialState(
        lhs: denormal, rhs: zero, doublePrecision: doublePrecision,
        rflags: [.reservedOne, .zero, .parity, .carry])
      try expectRetired(step(code, state: &masked), code: code)
      #expect(masked.rflags == [.reservedOne])
      #expect(masked.floatingPoint.mxcsr == 0x1F82)

      var daz = try initialState(
        lhs: denormal, rhs: zero, doublePrecision: doublePrecision,
        mxcsr: 0x1FC0, rflags: [.reservedOne])
      try expectRetired(step(code, state: &daz), code: code)
      #expect(daz.rflags == [.reservedOne, .zero])
      #expect(daz.floatingPoint.mxcsr == 0x1FC0)

      var unmasked = try initialState(
        lhs: denormal, rhs: zero, doublePrecision: doublePrecision,
        mxcsr: 0x1E80, rflags: [.reservedOne, .direction, .carry])
      var expected = unmasked
      expected.floatingPoint.mxcsr |= 1 << 1
      #expect(
        step(code, state: &unmasked)
          == .exception(
            .init(
              kind: .simdFloatingPoint, vector: 19, instructionPointer: 0x1000)))
      #expect(unmasked == expected)
    }
  }

  private func instruction(ordered: Bool, doublePrecision: Bool) -> [UInt8] {
    [0xC5, doublePrecision ? 0xF9 : 0xF8, ordered ? 0x2F : 0x2E, 0xC1]
  }

  private func initialState(
    lhs: UInt64, rhs: UInt64, doublePrecision: Bool,
    mxcsr: UInt32 = 0x1F80, supportsXM: Bool = true,
    rflags: DoryX86RFLAGS = [.reservedOne]
  ) throws -> DoryX86ArchitecturalState {
    let byteCount = doublePrecision ? 8 : 4
    var floatingPoint = try DoryX86FloatingPointState(mxcsr: mxcsr)
    floatingPoint.ymm[0] = try .init(
      bytes: littleEndian(lhs, byteCount: byteCount)
        + Array(repeating: 0xA0, count: 32 - byteCount),
      expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(
      bytes: littleEndian(rhs, byteCount: byteCount)
        + Array(repeating: 0xB1, count: 32 - byteCount),
      expectedByteCount: 32)
    return try .init(
      rip: 0x1000, rflags: rflags,
      control: .init(cr4: (1 << 9) | (supportsXM ? 1 << 10 : 0) | (1 << 18), xcr0: 7),
      floatingPoint: floatingPoint)
  }

  private func step(
    _ code: [UInt8], state: inout DoryX86ArchitecturalState
  ) -> DoryX86InterpreterResult {
    let memory = try! DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    return interpreter.step(state: &state, memory: memory, mode: .long64)
  }

  private func littleEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult, code: [UInt8]) throws {
    let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(result == .retired(instruction))
  }
}
