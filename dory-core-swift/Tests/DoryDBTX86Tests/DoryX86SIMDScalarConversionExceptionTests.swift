import Testing

@testable import DoryDBTX86

@Suite struct DoryX86SIMDScalarConversionExceptionTests {
  @Test func unmaskedPrecisionSuppressesCVTSD2SSDestination() throws {
    let code: [UInt8] = [0xF2, 0x0F, 0x5A, 0xC1] // CVTSD2SS xmm0,xmm1
    var state = try state(
      source: littleEndian(Double.pi.bitPattern),
      mxcsr: 0x1F80 & ~(1 << 12))
    let before = state

    #expect(try execute(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 5))
  }

  @Test func maskedOverflowHonorsDirectedRoundingAndRecordsPrecision() throws {
    let code: [UInt8] = [0xF2, 0x0F, 0x5A, 0xC1] // CVTSD2SS xmm0,xmm1
    var state = try state(
      source: littleEndian(Double.greatestFiniteMagnitude.bitPattern),
      mxcsr: 0x1F80 | (1 << 13)) // Round down.

    expectRetired(try execute(code, state: &state))
    #expect(low32(state) == Float.greatestFiniteMagnitude.bitPattern)
    #expect(state.floatingPoint.mxcsr & 0x3F == (1 << 3) | (1 << 5))
  }

  @Test func signalingNaNConversionRaisesPreciseInvalid() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x5A, 0xC1] // CVTSS2SD xmm0,xmm1
    var state = try state(
      source: littleEndian(UInt32(0x7F80_0001)),
      mxcsr: 0x1F80 & ~(1 << 7))
    let before = state

    #expect(try execute(code, state: &state)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | 1)
  }

  @Test func dazControlsSingleToDoubleDenormalHandling() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0x5A, 0xC1] // CVTSS2SD xmm0,xmm1
    var faulting = try state(
      source: littleEndian(UInt32(1)), mxcsr: 0x1F80 & ~(1 << 8))
    let before = faulting
    #expect(try execute(code, state: &faulting)
      == .exception(.init(kind: .simdFloatingPoint, vector: 19,
        instructionPointer: 0x1000)))
    #expect(faulting.floatingPoint.ymm == before.floatingPoint.ymm)
    #expect(faulting.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 1))

    var daz = try state(
      source: littleEndian(UInt32(0x8000_0001)), mxcsr: 0x1F80 | (1 << 6))
    expectRetired(try execute(code, state: &daz))
    #expect(low64(daz) == 0x8000_0000_0000_0000)
    #expect(daz.floatingPoint.mxcsr & (1 << 1) == 0)
  }

  private func state(source: [UInt8], mxcsr: UInt32) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(mxcsr: mxcsr)
    floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0xA5, count: 32), expectedByteCount: 32)
    var sourceBytes = [UInt8](repeating: 0x5A, count: 32)
    sourceBytes.replaceSubrange(0..<source.count, with: source)
    floatingPoint.ymm[1] = try .init(bytes: sourceBytes, expectedByteCount: 32)
    return try DoryX86ArchitecturalState(
      rip: 0x1000, control: .init(cr4: (1 << 9) | (1 << 10)),
      floatingPoint: floatingPoint)
  }

  private func execute(
    _ code: [UInt8], state: inout DoryX86ArchitecturalState
  ) throws -> DoryX86InterpreterResult {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    return DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
  }

  private func low32(_ state: DoryX86ArchitecturalState) -> UInt32 {
    let bytes = state.floatingPoint.ymm[0].bytes
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
      | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
  }

  private func low64(_ state: DoryX86ArchitecturalState) -> UInt64 {
    state.floatingPoint.ymm[0].bytes.prefix(8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult) {
    guard case .retired = result else {
      Issue.record("instruction did not retire: \(result)")
      return
    }
  }
}
