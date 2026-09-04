import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2A FSCALE and FPREM/FPREM1:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// Exact result-data regressions for host-conversion boundaries. These do not
// qualify pending numeric exceptions or the general partial-remainder algorithm.
@Suite struct DoryX86FloatingHostBoundaryTests {
  @Test func finiteScalePowersOutsideHostIntegerRangeCannotTrapOrDestroyZeros() throws {
    let huge = value(0x8000_0000_0000_0000, 0x403E) // Exactly 2^63.
    let largest = value(.max, 0x7FFE)
    for mode in modes {
      for power in [huge, largest] {
        for negativePower in [false, true] {
          let scale = negativePower ? power.negated() : power
          for negative in [false, true] {
            let one = negative ? DoryX86ExtendedFloat.one.negated() : .one
            let result = try execute([0xD9, 0xFD], first: one, second: scale, mode: mode)
            let expected = negativePower ? DoryX86ExtendedFloat.zero
              : value(0x8000_0000_0000_0000, 0x7FFF)
            #expect(result.bytes() == (negative ? expected.negated() : expected).bytes())
            let zero = negative ? DoryX86ExtendedFloat.zero.negated() : .zero
            #expect(try execute([0xD9, 0xFD], first: zero, second: scale, mode: mode).bytes() == zero.bytes())
          }
        }
      }
      // Int.min + a negative ST(0) exponent previously overflowed on the host.
      #expect(try execute([0xD9, 0xFD], first: value(0x8000_0000_0000_0000, 0x3FFE),
        second: huge.negated(), mode: mode).isZero)
      // Even the smallest subnormal must overflow for a huge positive power.
      #expect(try execute([0xD9, 0xFD], first: value(1, 0), second: largest, mode: mode).isInfinite)
    }
  }

  @Test func scaleTruncatesBinary80WithoutDoubleRoundingAndRetainsWideFiniteOperands() throws {
    // 2 - 2^-63 rounds to 2 as Double, but FSCALE must truncate it to 1.
    let belowTwo = value(.max, 0x3FFF)
    for mode in modes {
      for negative in [false, true] {
        let scale = negative ? belowTwo.negated() : belowTwo
        let expected = value(0x8000_0000_0000_0000, negative ? 0x3FFE : 0x4000)
        #expect(try execute([0xD9, 0xFD], first: .one, second: scale, mode: mode).bytes() == expected.bytes())
      }
      // ST(0) exceeds Double's range but scaling it by -1 stays exact binary80.
      let wide = value(0x8000_0000_0000_0001, 0x6000)
      let expected = value(0x8000_0000_0000_0001, 0x5FFF)
      #expect(try execute([0xD9, 0xFD], first: wide, second: .one.negated(), mode: mode).bytes() == expected.bytes())
    }
  }

  @Test func remainderQuotientAtPositiveTwoTo63DoesNotNarrowThroughInt64() throws {
    // Exponent difference 63 permits a completed remainder. Exact division by
    // one leaves zero and low quotient bits000 for both rounding variants.
    let dividend = value(0x8000_0000_0000_0000, 0x403E)
    for mode in modes {
      for opcode: UInt8 in [0xF5, 0xF8] {
        #expect(try execute([0xD9, opcode], first: dividend, second: .one, mode: mode).isZero)
      }
    }
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func value(_ significand: UInt64, _ exponent: UInt16) -> DoryX86ExtendedFloat {
    .init(bytes: (0..<8).map { UInt8(truncatingIfNeeded: significand >> ($0 * 8)) }
      + [UInt8(truncatingIfNeeded: exponent), UInt8(truncatingIfNeeded: exponent >> 8)])
  }

  private func execute(_ code: [UInt8], first: DoryX86ExtendedFloat,
    second: DoryX86ExtendedFloat, mode: DoryX86ExecutionMode) throws -> DoryX86ExtendedFloat {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + [0, 0])
    var fp = try DoryX86FloatingPointState()
    fp.x87[0] = try .init(bytes: first.bytes(), expectedByteCount: 10)
    fp.x87[1] = try .init(bytes: second.bytes(), expectedByteCount: 10)
    fp.x87TagWord = 0
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    var state = try DoryX86ArchitecturalState(rip: 0x1000,
      cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31), floatingPoint: fp)
    let initial = state
    let decoded = try DoryX86Decoder().decode(code, at: state.rip, mode: mode)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
    #expect(state.rip == 0x1002 && state.registers == initial.registers && state.rflags == initial.rflags)
    #expect(Array(state.floatingPoint.x87.dropFirst()) == Array(initial.floatingPoint.x87.dropFirst()))
    #expect(state.floatingPoint.ymm == initial.floatingPoint.ymm)
    #expect(state.floatingPoint.mxcsr == initial.floatingPoint.mxcsr)
    return .init(bytes: state.floatingPoint.x87[0].bytes)
  }
}
