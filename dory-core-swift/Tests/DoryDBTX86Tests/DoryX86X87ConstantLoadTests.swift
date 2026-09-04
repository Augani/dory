import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 1 §8.3.4 and Vol. 2A FLD1/FLDL2T/FLDL2E/FLDPI/
// FLDLG2/FLDLN2/FLDZ: load constants use their more-precise internal values,
// round only according to RC, ignore PC, and do not raise #P or set C1 for a
// rounded-up result.
@Suite struct DoryX86X87ConstantLoadTests {
  private struct Form {
    let opcode: UInt8
    let downward: UInt64
    let nearest: UInt64
    let upward: UInt64
    let exponentField: UInt16
    let zero: Bool
  }

  private let forms: [Form] = [
    .init(
      opcode: 0xE8, downward: 0x8000_0000_0000_0000,
      nearest: 0x8000_0000_0000_0000, upward: 0x8000_0000_0000_0000,
      exponentField: 0x3FFF, zero: false),
    .init(
      opcode: 0xE9, downward: 0xD49A_784B_CD1B_8AFE,
      nearest: 0xD49A_784B_CD1B_8AFE, upward: 0xD49A_784B_CD1B_8AFF,
      exponentField: 0x4000, zero: false),
    .init(
      opcode: 0xEA, downward: 0xB8AA_3B29_5C17_F0BB,
      nearest: 0xB8AA_3B29_5C17_F0BC, upward: 0xB8AA_3B29_5C17_F0BC,
      exponentField: 0x3FFF, zero: false),
    .init(
      opcode: 0xEB, downward: 0xC90F_DAA2_2168_C234,
      nearest: 0xC90F_DAA2_2168_C235, upward: 0xC90F_DAA2_2168_C235,
      exponentField: 0x4000, zero: false),
    .init(
      opcode: 0xEC, downward: 0x9A20_9A84_FBCF_F798,
      nearest: 0x9A20_9A84_FBCF_F799, upward: 0x9A20_9A84_FBCF_F799,
      exponentField: 0x3FFD, zero: false),
    .init(
      opcode: 0xED, downward: 0xB172_17F7_D1CF_79AB,
      nearest: 0xB172_17F7_D1CF_79AC, upward: 0xB172_17F7_D1CF_79AC,
      exponentField: 0x3FFE, zero: false),
    .init(
      opcode: 0xEE, downward: 0, nearest: 0, upward: 0,
      exponentField: 0, zero: true),
  ]

  @Test func exactPayloadsFollowRCAndIgnorePrecisionControl() throws {
    // PC encodings 01b is reserved, so qualify the three architectural modes.
    for precisionControl: UInt16 in [0, 2, 3] {
      for roundingControl: UInt16 in 0..<4 {
        for form in forms {
          let controlWord =
            UInt16(0x007F) | precisionControl << 8 | roundingControl << 10
          var state = try emptyState(controlWord: controlWord)

          try retire(&state, opcode: form.opcode)

          let significand =
            switch roundingControl {
            case 0: form.nearest
            case 2: form.upward
            default: form.downward
            }
          #expect(
            state.floatingPoint.x87[7].bytes
              == binary80(significand: significand, exponentField: form.exponentField))
          #expect(state.floatingPoint.x87TagWord >> 14 & 3 == (form.zero ? 1 : 0))
          #expect(state.floatingPoint.x87StatusWord == 0x7D00)
          #expect(state.floatingPoint.x87ControlWord == controlWord)
        }
      }
    }
  }

  @Test func fullStackOverflowPrecedesEveryConstantAndRoundingMode() throws {
    for roundingControl: UInt16 in 0..<4 {
      for form in forms {
        for masked in [false, true] {
          let controlWord = UInt16(masked ? 0x037F : 0x037E) | roundingControl << 10
          var state = try fullState(controlWord: controlWord, top: 3)
          let before = state.floatingPoint

          try retire(&state, opcode: form.opcode)

          #expect(
            state.floatingPoint.x87StatusWord & 0x82C1
              == 0x0241 | (masked ? 0 : 0x8080))
          if masked {
            #expect(state.floatingPoint.x87StatusWord >> 11 & 7 == 2)
            #expect(
              state.floatingPoint.x87[2].bytes
                == [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF])
            #expect(state.floatingPoint.x87TagWord >> 4 & 3 == 2)
          } else {
            #expect(state.floatingPoint.x87 == before.x87)
            #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
            #expect(
              state.floatingPoint.x87StatusWord & 0x3800
                == before.x87StatusWord & 0x3800)
          }
        }
      }
    }
  }

  private func emptyState(controlWord: UInt16) throws -> DoryX86ArchitecturalState {
    let floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: 0x4700, x87TagWord: 0xFFFF)
    return try state(floatingPoint)
  }

  private func fullState(controlWord: UInt16, top: UInt16) throws
    -> DoryX86ArchitecturalState
  {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord,
      x87StatusWord: 0x4500 | top << 11,
      x87TagWord: 0
    )
    for index in 0..<8 {
      floatingPoint.x87[index] = try .init(
        bytes: DoryX86ExtendedFloat(Int64(index + 1)).bytes(), expectedByteCount: 10)
    }
    return try state(floatingPoint)
  }

  private func state(_ floatingPoint: DoryX86FloatingPointState) throws
    -> DoryX86ArchitecturalState
  {
    try .init(
      rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: 0x31),
      floatingPoint: floatingPoint
    )
  }

  private func binary80(significand: UInt64, exponentField: UInt16) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: significand >> UInt64($0 * 8)) }
      + [UInt8(truncatingIfNeeded: exponentField), UInt8(truncatingIfNeeded: exponentField >> 8)]
  }

  private func retire(_ state: inout DoryX86ArchitecturalState, opcode: UInt8) throws {
    let code: [UInt8] = [0xD9, opcode]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(instruction))
  }
}
