import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 1 §§11.5.2-3: SIMD arithmetic applies DAZ before execution,
// records prioritized MXCSR status, and suppresses the destination on an
// unmasked exception.
@Suite struct DoryX86SIMDBinaryExceptionTests {
  @Test func legacyDivideByZeroRaisesPreciseSIMDFault() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x5E, 0xC1] // DIVSS xmm0,xmm1
    var state = try makeState(
      lhs: [Float(6).bitPattern], rhs: [Float(0).bitPattern],
      mxcsr: 0x1F80 & ~(1 << 9))
    let before = state

    #expect(step(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.rip == before.rip)
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 2))
  }

  @Test func missingOSXMMExceptionSupportConvertsUnmaskedFaultToUD() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x5E, 0xC1] // DIVSS xmm0,xmm1
    var state = try makeState(
      lhs: [Float(1).bitPattern], rhs: [Float(0).bitPattern],
      mxcsr: 0x1F80 & ~(1 << 9), osxmmexcpt: false)
    let before = state

    #expect(step(code, state: &state)
      == .exception(.init(kind: .invalidOpcode, vector: 6,
        instructionPointer: 0x1000)))
    #expect(state.rip == before.rip)
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 2))
  }

  @Test func dazControlsDenormalOperandFaultsAndSignedZeroInput() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x58, 0xC1] // ADDSS xmm0,xmm1
    var faulting = try makeState(
      lhs: [Float(1).bitPattern], rhs: [1],
      mxcsr: 0x1F80 & ~(1 << 8))
    let beforeFault = faulting
    #expect(step(code, state: &faulting)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(faulting.floatingPoint.ymm == beforeFault.floatingPoint.ymm)
    #expect(faulting.floatingPoint.mxcsr == beforeFault.floatingPoint.mxcsr | (1 << 1))

    var daz = try makeState(
      lhs: [Float(1).bitPattern], rhs: [0x8000_0001],
      mxcsr: 0x1F80 | (1 << 6))
    expectRetired(step(code, state: &daz))
    #expect(lane32(0, register: 0, state: daz) == Float(1).bitPattern)
    #expect(daz.floatingPoint.mxcsr & (1 << 1) == 0)
  }

  @Test func packedInvalidLaneSuppressesTheWholeLegacyDestination() throws {
    let code: [UInt8] = [0x0F, 0x59, 0xC1] // MULPS xmm0,xmm1
    var state = try makeState(
      lhs: [Float(2).bitPattern, Float(0).bitPattern, Float(4).bitPattern, Float(8).bitPattern],
      rhs: [Float(3).bitPattern, Float.infinity.bitPattern,
        Float(5).bitPattern, Float(2).bitPattern],
      mxcsr: 0x1F80 & ~(1 << 7))
    let before = state

    #expect(step(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | 1)
  }

  @Test func packedDoubleExceptionUsesTheSamePreciseCommitBoundary() throws {
    let code: [UInt8] = [0x66, 0x0F, 0x5E, 0xC1] // DIVPD xmm0,xmm1
    var state = try makeState(
      lhs: [0], rhs: [0], mxcsr: 0x1F80 & ~(1 << 9))
    var lhs = state.floatingPoint.ymm[0].bytes
    var rhs = state.floatingPoint.ymm[1].bytes
    lhs.replaceSubrange(0..<8, with: littleEndian(Double(9).bitPattern))
    rhs.replaceSubrange(0..<8, with: littleEndian(Double(0).bitPattern))
    state.floatingPoint.ymm[0] = try .init(bytes: lhs, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: rhs, expectedByteCount: 32)
    let before = state

    #expect(step(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 2))
  }

  @Test func maskedInvalidProducesIndefiniteWithoutChangingScalarUpperLanes() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x59, 0xC1] // MULSS xmm0,xmm1
    var state = try makeState(
      lhs: [Float(0).bitPattern], rhs: [Float.infinity.bitPattern], mxcsr: 0x1F80)
    let upperBefore = Array(state.floatingPoint.ymm[0].bytes[4..<32])

    expectRetired(step(code, state: &state))
    #expect(lane32(0, register: 0, state: state) == 0xFFC0_0000)
    #expect(Array(state.floatingPoint.ymm[0].bytes[4..<32]) == upperBefore)
    #expect(state.floatingPoint.mxcsr == 0x1F81)
  }

  @Test func unmaskedVEXFaultDoesNotPublishDestinationOrUpperLaneClear() throws {
    let code: [UInt8] = [0xC5, 0xEA, 0x5E, 0xC8] // VDIVSS xmm1,xmm2,xmm0
    var state = try makeState(
      lhs: [Float(0).bitPattern], rhs: [Float(0).bitPattern],
      mxcsr: 0x1F80 & ~(1 << 9), avx: true)
    var firstSource = state.floatingPoint.ymm[2].bytes
    firstSource.replaceSubrange(0..<4, with: littleEndian(Float(7).bitPattern))
    state.floatingPoint.ymm[2] = try .init(bytes: firstSource, expectedByteCount: 32)
    let before = state

    #expect(step(code, state: &state, avx: true)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 2))
  }

  @Test func scalarAdditionObeysEveryMXCSRRoundingModeAndReportsPrecision() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x58, 0xC1] // ADDSS xmm0,xmm1
    let halfway = Float(0x1p-24).bitPattern
    let expected: [UInt32] = [
      Float(1).bitPattern,
      Float(1).bitPattern,
      Float(1).nextUp.bitPattern,
      Float(1).bitPattern,
    ]

    for rounding: UInt32 in 0..<4 {
      var state = try makeState(
        lhs: [Float(1).bitPattern], rhs: [halfway],
        mxcsr: 0x1F80 | (rounding << 13))
      expectRetired(step(code, state: &state))
      #expect(lane32(0, register: 0, state: state) == expected[Int(rounding)])
      #expect(state.floatingPoint.mxcsr == 0x1FA0 | (rounding << 13))
    }
  }

  @Test func scalarMultiplicationPublishesOverflowAndGuestDirectedResult() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x59, 0xC1] // MULSS xmm0,xmm1
    let expected: [UInt32] = [
      Float.infinity.bitPattern,
      Float.greatestFiniteMagnitude.bitPattern,
      Float.infinity.bitPattern,
      Float.greatestFiniteMagnitude.bitPattern,
    ]

    for rounding: UInt32 in 0..<4 {
      var state = try makeState(
        lhs: [Float.greatestFiniteMagnitude.bitPattern], rhs: [Float(2).bitPattern],
        mxcsr: 0x1F80 | (rounding << 13))
      expectRetired(step(code, state: &state))
      #expect(lane32(0, register: 0, state: state) == expected[Int(rounding)])
      #expect(state.floatingPoint.mxcsr == 0x1FA8 | (rounding << 13))
    }
  }

  @Test func flushToZeroAppliesOnlyToAnInexactTinyResult() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x59, 0xC1] // MULSS xmm0,xmm1
    let tinyProduct = Float.leastNormalMagnitude * Float(0.1)

    var gradual = try makeState(
      lhs: [Float.leastNormalMagnitude.bitPattern], rhs: [Float(0.1).bitPattern],
      mxcsr: 0x1F80)
    expectRetired(step(code, state: &gradual))
    #expect(lane32(0, register: 0, state: gradual) == tinyProduct.bitPattern)
    #expect(gradual.floatingPoint.mxcsr == 0x1FB0)

    var flushed = try makeState(
      lhs: [Float.leastNormalMagnitude.bitPattern], rhs: [Float(0.1).bitPattern],
      mxcsr: 0x1F80 | (1 << 15))
    expectRetired(step(code, state: &flushed))
    #expect(lane32(0, register: 0, state: flushed) == 0)
    #expect(flushed.floatingPoint.mxcsr == 0x9FB0)

    var exact = try makeState(
      lhs: [Float.leastNormalMagnitude.bitPattern], rhs: [Float(0.5).bitPattern],
      mxcsr: 0x1F80 | (1 << 15))
    expectRetired(step(code, state: &exact))
    #expect(lane32(0, register: 0, state: exact) == 0x0040_0000)
    #expect(exact.floatingPoint.mxcsr == 0x9F80)
  }

  @Test func unmaskedUnderflowSuppressesTheDestinationAfterPublishingStatus() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x59, 0xC1] // MULSS xmm0,xmm1
    var state = try makeState(
      lhs: [Float.leastNormalMagnitude.bitPattern], rhs: [Float(0.1).bitPattern],
      mxcsr: 0x1F80 & ~(1 << 11))
    let before = state

    #expect(step(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | 0x10)
  }

  @Test func scalarDoubleDivisionUsesMXCSRInsteadOfHostRounding() throws {
    let code: [UInt8] = [0xF2, 0x0F, 0x5E, 0xC1] // DIVSD xmm0,xmm1
    let nearest = Double(0.1).bitPattern
    let expected = [nearest, nearest - 1, nearest, nearest - 1]

    for rounding: UInt32 in 0..<4 {
      var state = try makeDoubleState(
        lhs: Double(1).bitPattern, rhs: Double(10).bitPattern,
        mxcsr: 0x1F80 | (rounding << 13))
      expectRetired(step(code, state: &state))
      #expect(lane64(0, register: 0, state: state) == expected[Int(rounding)])
      #expect(state.floatingPoint.mxcsr == 0x1FA0 | (rounding << 13))
    }
  }

  @Test func minimumAndMaximumQuietASecondSignalingNaNOrFaultPrecisely() throws {
    let minSingle: [UInt8] = [0xF3, 0x0F, 0x5D, 0xC1] // MINSS xmm0,xmm1
    let signalingSingle: UInt32 = 0x7F81_2345
    var masked = try makeState(
      lhs: [Float(1).bitPattern], rhs: [signalingSingle], mxcsr: 0x1F80)
    expectRetired(step(minSingle, state: &masked))
    #expect(lane32(0, register: 0, state: masked) == signalingSingle | 0x0040_0000)
    #expect(masked.floatingPoint.mxcsr == 0x1F81)

    var unmasked = try makeState(
      lhs: [Float(1).bitPattern], rhs: [signalingSingle],
      mxcsr: 0x1F80 & ~(1 << 7))
    let before = unmasked
    #expect(step(minSingle, state: &unmasked)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(unmasked.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(unmasked.floatingPoint.mxcsr == before.floatingPoint.mxcsr | 1)

    let maxDouble: [UInt8] = [0xF2, 0x0F, 0x5F, 0xC1] // MAXSD xmm0,xmm1
    let signalingDouble: UInt64 = 0x7FF0_0000_0001_2345
    var double = try makeDoubleState(
      lhs: Double(1).bitPattern, rhs: signalingDouble, mxcsr: 0x1F80)
    expectRetired(step(maxDouble, state: &double))
    #expect(lane64(0, register: 0, state: double)
      == signalingDouble | 0x0008_0000_0000_0000)
    #expect(double.floatingPoint.mxcsr == 0x1F81)
  }

  private func makeState(
    lhs: [UInt32], rhs: [UInt32], mxcsr: UInt32,
    osxmmexcpt: Bool = true, avx: Bool = false
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(mxcsr: mxcsr)
    var lhsBytes = [UInt8](repeating: 0xA5, count: 32)
    var rhsBytes = [UInt8](repeating: 0x5A, count: 32)
    for (lane, bits) in lhs.enumerated() {
      lhsBytes.replaceSubrange(lane * 4..<lane * 4 + 4, with: littleEndian(bits))
    }
    for (lane, bits) in rhs.enumerated() {
      rhsBytes.replaceSubrange(lane * 4..<lane * 4 + 4, with: littleEndian(bits))
    }
    floatingPoint.ymm[0] = try .init(bytes: lhsBytes, expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: rhsBytes, expectedByteCount: 32)
    var cr4 = UInt64(1 << 9)
    if osxmmexcpt { cr4 |= 1 << 10 }
    var control = DoryX86ControlState(cr4: cr4)
    if avx {
      control.cr4 |= 1 << 18
      control.xcr0 = 7
    }
    return try DoryX86ArchitecturalState(
      rip: 0x1000, control: control, floatingPoint: floatingPoint)
  }

  private func makeDoubleState(
    lhs: UInt64, rhs: UInt64, mxcsr: UInt32
  ) throws -> DoryX86ArchitecturalState {
    var state = try makeState(lhs: [], rhs: [], mxcsr: mxcsr)
    var lhsBytes = state.floatingPoint.ymm[0].bytes
    var rhsBytes = state.floatingPoint.ymm[1].bytes
    lhsBytes.replaceSubrange(0..<8, with: littleEndian(lhs))
    rhsBytes.replaceSubrange(0..<8, with: littleEndian(rhs))
    state.floatingPoint.ymm[0] = try .init(bytes: lhsBytes, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: rhsBytes, expectedByteCount: 32)
    return state
  }

  private func step(
    _ code: [UInt8], state: inout DoryX86ArchitecturalState, avx: Bool = false
  ) -> DoryX86InterpreterResult {
    let profile = avx
      ? DoryX86CPUProfile(
        identifier: "test-only.avx-simd-binary",
        features: DoryX86CPUProfile.compatibleV1.features.union([.xsave, .avx]),
        physicalAddressBits: 40, linearAddressBits: 48,
        virtualTSCFrequencyHz: 1_000_000_000,
        allowingUnqualifiedSIMDAndExtendedState: true)
      : .compatibleV1
    let memory = try! DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    return DoryX86Interpreter(profile: profile).step(
      state: &state, memory: memory, mode: .long64)
  }

  private func lane32(
    _ lane: Int, register: Int, state: DoryX86ArchitecturalState
  ) -> UInt32 {
    let offset = lane * 4
    let bytes = state.floatingPoint.ymm[register].bytes
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }

  private func lane64(
    _ lane: Int, register: Int, state: DoryX86ArchitecturalState
  ) -> UInt64 {
    let offset = lane * 8
    return state.floatingPoint.ymm[register].bytes[offset..<offset + 8]
      .enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult) {
    guard case .retired = result else {
      Issue.record("instruction did not retire: \(result)")
      return
    }
  }

  private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
