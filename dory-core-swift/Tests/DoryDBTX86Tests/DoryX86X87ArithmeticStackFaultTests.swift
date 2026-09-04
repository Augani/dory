import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 1 §8.5.1.1 and Vol. 2A FADD/FCOM/FCOMI/FUCOM:
// https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// Empty arithmetic/comparison register operands generate #IS. IM selects a
// masked indefinite/unordered response with the normal pop, or an unmasked
// status-only response that preserves destination, flags, tags and TOP.
@Suite struct DoryX86X87ArithmeticStackFaultTests {
  private let indefinite: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF]

  @Test func binaryRegisterUnderflowWritesMaskedIndefiniteOrSuppressesEveryEffect() throws {
    let forms: [(code: [UInt8], destination: Int, empty: Int, pop: Bool)] = [
      ([0xD8, 0xC1], 0, 0, false), // FADD ST(0), ST(1): empty destination.
      ([0xD8, 0xC1], 0, 1, false), // FADD ST(0), ST(1): empty source.
      ([0xDC, 0xC1], 1, 1, false), // FADD ST(1), ST(0): empty destination.
      ([0xDC, 0xC1], 1, 0, false), // FADD ST(1), ST(0): empty source.
      ([0xDE, 0xC1], 1, 1, true),  // FADDP ST(1), ST(0): empty destination.
      ([0xDE, 0xC1], 1, 0, true),  // FADDP ST(1), ST(0): empty source.
    ]
    for form in forms {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 3)
        empty(form.empty, in: &state.floatingPoint)
        let before = state.floatingPoint
        try retire(&state, code: form.code)

        expectUnderflow(state.floatingPoint, masked: masked)
        #expect(state.rip == 0x1002)
        #expect(state.floatingPoint.x87InstructionPointer == 0x1000)
        let expectedOpcode = UInt16(form.code[0] & 7) << 8 | UInt16(form.code[1])
        #expect(state.floatingPoint.x87Opcode == (masked ? 0x456 : expectedOpcode))
        if masked {
          let destination = (3 + form.destination) & 7
          #expect(state.floatingPoint.x87[destination].bytes == indefinite)
          #expect(tag(destination, in: state.floatingPoint) == 2)
          #expect(top(state.floatingPoint) == (form.pop ? 4 : 3))
          if form.pop { #expect(tag(3, in: state.floatingPoint) == 3) }
        } else {
          #expect(state.floatingPoint.x87 == before.x87)
          #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
          #expect(top(state.floatingPoint) == 3)
          #expect(state.floatingPoint.x87StatusWord & 0x4500 == before.x87StatusWord & 0x4500)
        }
      }
    }
  }

  @Test func statusComparisonsPublishMaskedUnorderedAndOnlyThenPop() throws {
    let forms: [(code: [UInt8], popCount: Int)] = [
      ([0xD8, 0xD1], 0), // FCOM ST(1)
      ([0xD8, 0xD9], 1), // FCOMP ST(1)
      ([0xDE, 0xD9], 2), // FCOMPP
      ([0xDA, 0xE9], 2), // FUCOMPP
    ]
    for form in forms {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 2)
        empty(1, in: &state.floatingPoint)
        let before = state.floatingPoint
        try retire(&state, code: form.code)

        expectUnderflow(state.floatingPoint, masked: masked)
        if masked {
          #expect(state.floatingPoint.x87StatusWord & 0x4500 == 0x4500)
          #expect(top(state.floatingPoint) == (2 + form.popCount) & 7)
          for logical in 0..<form.popCount {
            #expect(tag((2 + logical) & 7, in: state.floatingPoint) == 3)
          }
        } else {
          #expect(state.floatingPoint.x87StatusWord & 0x4500 == before.x87StatusWord & 0x4500)
          #expect(state.floatingPoint.x87 == before.x87)
          #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
          #expect(top(state.floatingPoint) == 2)
        }
      }
    }
  }

  @Test func integerFlagComparisonsPublishMaskedUnorderedAndSuppressUnmaskedPop() throws {
    let forms: [(code: [UInt8], pop: Bool)] = [
      ([0xDB, 0xF1], false), // FCOMI ST, ST(1)
      ([0xDF, 0xF1], true),  // FCOMIP ST, ST(1)
    ]
    let originalFlags: DoryX86RFLAGS = [
      .reservedOne, .interruptEnable, .direction, .overflow, .sign, .auxiliaryCarry,
    ]
    for form in forms {
      for masked in [false, true] {
        var state = try makeState(masked: masked, top: 6, rflags: originalFlags)
        empty(1, in: &state.floatingPoint)
        let before = state.floatingPoint
        try retire(&state, code: form.code)

        expectUnderflow(state.floatingPoint, masked: masked)
        #expect(state.floatingPoint.x87StatusWord & 0x4500 == before.x87StatusWord & 0x4500)
        if masked {
          #expect(state.rflags == [
            .reservedOne, .interruptEnable, .direction, .zero, .parity, .carry,
          ])
          #expect(top(state.floatingPoint) == (form.pop ? 7 : 6))
          if form.pop { #expect(tag(6, in: state.floatingPoint) == 3) }
        } else {
          #expect(state.rflags == originalFlags)
          #expect(state.floatingPoint.x87 == before.x87)
          #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
          #expect(top(state.floatingPoint) == 6)
        }
      }
    }
  }

  @Test func memoryFaultPrecedesStackStatusAndSuccessfulReadPrecedesMaskedResponse() throws {
    var state = try makeState(masked: true, top: 1)
    state.registers.rax = 0x2000
    empty(0, in: &state.floatingPoint)
    let before = state
    let faulting = ArithmeticStackMemory(code: [0xD8, 0x00], failRead: true)
    #expect(DoryX86Interpreter().step(state: &state, memory: faulting, mode: .long64)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: 0x1000, linearAddress: 0x2002)))
    var expected = before
    expected.control.cr2 = 0x2002
    #expect(state == expected)
    #expect(faulting.dataReads == 1)

    state = try makeState(masked: true, top: 1)
    state.registers.rax = 0x2000
    empty(0, in: &state.floatingPoint)
    let readable = ArithmeticStackMemory(code: [0xD8, 0x00], failRead: false)
    try retire(&state, memory: readable)
    expectUnderflow(state.floatingPoint, masked: true)
    #expect(readable.dataReads == 1)
    #expect(state.floatingPoint.x87[1].bytes == indefinite)
    #expect(tag(1, in: state.floatingPoint) == 2)
  }

  @Test func successfulComparisonClearsC1WithoutInventingAStackFault() throws {
    var state = try makeState(masked: true, top: 0)
    state.floatingPoint.x87StatusWord |= 0x0200
    try retire(&state, code: [0xD8, 0xD1])
    #expect(state.floatingPoint.x87StatusWord & 0x0241 == 0)
    #expect(state.floatingPoint.x87StatusWord & 0x4500 == 0x0100)
    #expect(top(state.floatingPoint) == 0)
  }

  private func makeState(
    masked: Bool, top: Int, rflags: DoryX86RFLAGS = [.reservedOne]
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: masked ? 0x037F : 0x037E,
      x87StatusWord: 0x4700 | UInt16(top << 11), x87TagWord: 0,
      x87InstructionPointer: 0xABCD, x87InstructionSelector: 0x1234,
      x87DataPointer: 0xDCBA, x87DataSelector: 0x5678, x87Opcode: 0x456)
    for index in 0..<8 {
      floatingPoint.x87[index] = try .init(
        bytes: DoryX86ExtendedFloat(Double(index + 1)).bytes(), expectedByteCount: 10)
    }
    return try .init(
      rip: 0x1000, rflags: rflags,
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

  private func expectUnderflow(_ state: DoryX86FloatingPointState, masked: Bool) {
    #expect(state.x87StatusWord & 0x82C1 == 0x0041 | (masked ? 0 : 0x8080))
  }

  private func retire(_ state: inout DoryX86ArchitecturalState, code: [UInt8]) throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .retired(instruction))
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState, memory: ArithmeticStackMemory
  ) throws {
    let instruction = try DoryX86Decoder().decode(
      memory.code, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .retired(instruction))
  }
}

private final class ArithmeticStackMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private let failRead: Bool
  private(set) var dataReads = 0

  init(code: [UInt8], failRead: Bool) {
    self.code = code
    self.failRead = failRead
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address == 0x1000 else { return [] }
    return Array(code.prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReads += 1
    if failRead {
      throw DoryX86MemoryError.pageFault(address: 0x2002, errorCode: 4)
    }
    #expect(address == 0x2000 && byteCount == 4)
    return [0, 0, 0, 0x40] // 2.0f
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    Issue.record("x87 arithmetic source unexpectedly wrote memory")
  }
}
