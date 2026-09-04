import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 1 §8.5.1.1 and Vol. 2A FPTAN/FSINCOS/FXTRACT:
// special operations publish a masked indefinite result, while an unmasked
// stack exception suppresses destination and TOP changes. Source underflow has
// priority over overflow for the forms that push a second result.
@Suite struct DoryX86X87SpecialStackFaultTests {
  private let indefinite: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF]

  @Test func unaryAndTwoOperandFormsPublishTheRightMaskedDestination() throws {
    let forms: [(code: [UInt8], empty: Int, destination: Int, pop: Bool)] = [
      ([0xD9, 0xE0], 0, 0, false), // FCHS
      ([0xD9, 0xF0], 0, 0, false), // F2XM1
      ([0xD9, 0xFA], 0, 0, false), // FSQRT
      ([0xD9, 0xF5], 1, 0, false), // FPREM1
      ([0xD9, 0xFD], 1, 0, false), // FSCALE
      ([0xD9, 0xF1], 0, 1, true),  // FYL2X
      ([0xD9, 0xF3], 1, 1, true),  // FPATAN
    ]
    for form in forms {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 4)
        empty(form.empty, in: &state.floatingPoint)
        let before = state.floatingPoint

        try retire(&state, code: form.code)
        expectStackFault(state.floatingPoint, overflow: false, masked: masked)
        if masked {
          let destination = (4 + form.destination) & 7
          #expect(state.floatingPoint.x87[destination].bytes == indefinite)
          #expect(tag(destination, in: state.floatingPoint) == 2)
          #expect(top(state.floatingPoint) == (form.pop ? 5 : 4))
        } else {
          expectOperandsUnchanged(state.floatingPoint, from: before)
        }
      }
    }
  }

  @Test func pushProducingFormsHandleSourceUnderflowBeforeCapacity() throws {
    for code: [UInt8] in [[0xD9, 0xF2], [0xD9, 0xF4], [0xD9, 0xFB]] {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 3)
        empty(0, in: &state.floatingPoint)
        let before = state.floatingPoint

        try retire(&state, code: code)
        expectStackFault(state.floatingPoint, overflow: false, masked: masked)
        if masked {
          #expect(top(state.floatingPoint) == 2)
          #expect(state.floatingPoint.x87[2].bytes == indefinite)
          #expect(state.floatingPoint.x87[3].bytes == indefinite)
          #expect(tag(2, in: state.floatingPoint) == 2)
          #expect(tag(3, in: state.floatingPoint) == 2)
        } else {
          expectOperandsUnchanged(state.floatingPoint, from: before)
        }
      }
    }
  }

  @Test func pushProducingFormsPublishMaskedOverflowWithoutComputingTheInput() throws {
    for code: [UInt8] in [[0xD9, 0xF2], [0xD9, 0xF4], [0xD9, 0xFB]] {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 3)
        let before = state.floatingPoint

        try retire(&state, code: code)
        expectStackFault(state.floatingPoint, overflow: true, masked: masked)
        if masked {
          #expect(top(state.floatingPoint) == 2)
          #expect(state.floatingPoint.x87[2].bytes == indefinite)
          #expect(tag(2, in: state.floatingPoint) == 2)
          #expect(state.floatingPoint.x87[3] == before.x87[3])
          #expect(tag(3, in: state.floatingPoint) == tag(3, in: before))
        } else {
          expectOperandsUnchanged(state.floatingPoint, from: before)
        }
      }
    }
  }

  private func makeState(masked: Bool, top: Int) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: masked ? 0x037F : 0x037E,
      x87StatusWord: 0x4500 | UInt16(top << 11), x87TagWord: 0,
      x87Opcode: 0x321)
    for index in 0..<8 {
      floatingPoint.x87[index] = try .init(
        bytes: DoryX86ExtendedFloat(Double(index + 1)).bytes(), expectedByteCount: 10)
    }
    return try .init(
      rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: floatingPoint)
  }

  private func empty(_ logical: Int, in state: inout DoryX86FloatingPointState) {
    let physical = (top(state) + logical) & 7
    state.x87TagWord |= UInt16(3) << UInt16(physical * 2)
  }

  private func top(_ state: DoryX86FloatingPointState) -> Int {
    Int(state.x87StatusWord >> 11) & 7
  }

  private func tag(_ physical: Int, in state: DoryX86FloatingPointState) -> UInt16 {
    state.x87TagWord >> UInt16(physical * 2) & 3
  }

  private func expectStackFault(
    _ state: DoryX86FloatingPointState, overflow: Bool, masked: Bool
  ) {
    #expect(state.x87StatusWord & 0x82C1
      == 0x0041 | (overflow ? 0x0200 : 0) | (masked ? 0 : 0x8080))
  }

  private func expectOperandsUnchanged(
    _ state: DoryX86FloatingPointState, from before: DoryX86FloatingPointState
  ) {
    #expect(state.x87 == before.x87)
    #expect(state.x87TagWord == before.x87TagWord)
    #expect(top(state) == top(before))
  }

  private func retire(_ state: inout DoryX86ArchitecturalState, code: [UInt8]) throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .retired(instruction))
  }
}
