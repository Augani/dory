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

  private func step(
    _ code: [UInt8], state: inout DoryX86ArchitecturalState, avx: Bool = false
  ) -> DoryX86InterpreterResult {
    let profile = avx
      ? DoryX86CPUProfile(
        identifier: "test-only.avx-simd-binary",
        features: DoryX86CPUProfile.compatibleV1.features.union([.xsave, .avx]),
        physicalAddressBits: 40, linearAddressBits: 48,
        virtualTSCFrequencyHz: 1_000_000_000)
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
