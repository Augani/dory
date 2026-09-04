import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 1 §§8.2.2 and 8.5.1.1; Vol. 2A FADD/FCOM/FLD/FTST.
// Exact m80/register transfers preserve unsupported encodings. Instructions
// that consume them raise #IA: the masked response commits real indefinite or
// unordered, while an unmasked response suppresses the destination and pops.
@Suite struct DoryX86UnsupportedBinary80ExecutionTests {
  private var unsupportedEncodings: [[UInt8]] {
    [
      binary80(significand: 0x4000_0000_0000_1234, exponent: 0x3FFF),
      binary80(significand: 0x4000_0000_0000_5678, exponent: 0x7FFF, negative: true),
    ]
  }

  private var one: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3FFF)
  }

  private var realIndefinite: [UInt8] {
    binary80(significand: 0xC000_0000_0000_0000, exponent: 0x7FFF, negative: true)
  }

  @Test func extendedLoadsPreserveUnsupportedPayloadWithoutRaisingInvalid() throws {
    for unsupported in unsupportedEncodings {
      let memory = try memory(code: [0xDB, 0x28], operand: unsupported)  // FLD m80 [RAX]
      var state = try emptyState(controlWord: 0x037E, statusWord: 0x4700)  // IM=0

      try retire(&state, memory: memory, bytes: [0xDB, 0x28])

      #expect(top(state.floatingPoint) == 7)
      #expect(state.floatingPoint.x87[7].bytes == unsupported)
      #expect(tag(7, state.floatingPoint) == 2)
      #expect(state.floatingPoint.x87StatusWord & 0x8081 == 0)
      #expect(state.floatingPoint.x87StatusWord & 0x0200 == 0)
    }
  }

  @Test func unsupportedArithmeticCommitsIndefiniteOnlyWhenInvalidIsMasked() throws {
    for unsupported in unsupportedEncodings {
      let bytes: [UInt8] = [0xDE, 0xC1]  // FADDP ST(1), ST(0)

      var masked = try binaryState(
        unsupported: unsupported, controlWord: 0x037F, statusWord: 0x4700)
      try retire(&masked, memory: try memory(code: bytes), bytes: bytes)
      #expect(masked.floatingPoint.x87[1].bytes == realIndefinite)
      #expect(top(masked.floatingPoint) == 1)
      #expect(tag(0, masked.floatingPoint) == 3 && tag(1, masked.floatingPoint) == 2)
      #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)
      #expect(masked.floatingPoint.x87StatusWord & 0x4700 == 0x4500)

      let unmaskedMemory = try memory(code: bytes + [0x9B])  // followed by FWAIT
      var unmasked = try binaryState(
        unsupported: unsupported, controlWord: 0x037E, statusWord: 0x4700)
      let originalRegisters = unmasked.floatingPoint.x87
      let originalTags = unmasked.floatingPoint.x87TagWord
      try retire(&unmasked, memory: unmaskedMemory, bytes: bytes)
      #expect(unmasked.floatingPoint.x87 == originalRegisters)
      #expect(unmasked.floatingPoint.x87TagWord == originalTags)
      #expect(top(unmasked.floatingPoint) == 0)
      #expect(unmasked.floatingPoint.x87StatusWord == 0xC581)
      #expect(unmasked.floatingPoint.x87Opcode == 0x06C1)

      let beforeWait = unmasked
      #expect(
        interpreter.step(state: &unmasked, memory: unmaskedMemory, mode: .long64)
          == .exception(
            .init(
              kind: .x87FloatingPoint, vector: 16,
              instructionPointer: 0x1002)))
      #expect(unmasked == beforeWait)
    }
  }

  @Test func everyCompareFamilyTreatsUnsupportedAsInvalidAndSuppressesUnmaskedEffects() throws {
    let conditionFlagMask: UInt64 = 0x08D5  // OF, SF, ZF, AF, PF, CF
    let forms: [(bytes: [UInt8], popCount: Int, setsIntegerFlags: Bool)] = [
      ([0xD8, 0xD1], 0, false),  // FCOM ST(1)
      ([0xD8, 0xD9], 1, false),  // FCOMP ST(1)
      ([0xDA, 0xE9], 2, false),  // FUCOMPP
      ([0xDB, 0xE9], 0, true),  // FUCOMI ST, ST(1)
      ([0xDF, 0xF1], 1, true),  // FCOMIP ST, ST(1)
    ]
    for unsupported in unsupportedEncodings {
      for form in forms {
        var masked = try binaryState(
          unsupported: unsupported, controlWord: 0x037F, statusWord: 0x4700)
        masked.rflags = [
          .reservedOne, .interruptEnable, .overflow, .sign,
          .zero, .auxiliaryCarry, .parity, .carry,
        ]
        try retire(&masked, memory: try memory(code: form.bytes), bytes: form.bytes)
        #expect(top(masked.floatingPoint) == form.popCount)
        #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)
        #expect(masked.floatingPoint.x87StatusWord & 0x4700 == 0x4500)
        if form.setsIntegerFlags {
          #expect(masked.rflags.rawValue & conditionFlagMask == 0x45)
        }

        var unmasked = try binaryState(
          unsupported: unsupported, controlWord: 0x037E, statusWord: 0x4700)
        unmasked.rflags = [
          .reservedOne, .interruptEnable, .overflow, .sign,
          .zero, .auxiliaryCarry, .parity, .carry,
        ]
        let originalFlags = unmasked.rflags
        let originalRegisters = unmasked.floatingPoint.x87
        let originalTags = unmasked.floatingPoint.x87TagWord
        try retire(&unmasked, memory: try memory(code: form.bytes), bytes: form.bytes)
        #expect(unmasked.rflags == originalFlags)
        #expect(unmasked.floatingPoint.x87 == originalRegisters)
        #expect(unmasked.floatingPoint.x87TagWord == originalTags)
        #expect(top(unmasked.floatingPoint) == 0)
        #expect(unmasked.floatingPoint.x87StatusWord == 0xC581)
      }
    }
  }

  @Test func ftstUsesTheSameMaskedAndUnmaskedUnsupportedRules() throws {
    let bytes: [UInt8] = [0xD9, 0xE4]  // FTST
    for unsupported in unsupportedEncodings {
      var masked = try binaryState(
        unsupported: unsupported, controlWord: 0x037F, statusWord: 0x0200)
      let maskedRegisters = masked.floatingPoint.x87
      try retire(&masked, memory: try memory(code: bytes), bytes: bytes)
      #expect(masked.floatingPoint.x87 == maskedRegisters)
      #expect(masked.floatingPoint.x87StatusWord == 0x4501)

      var unmasked = try binaryState(
        unsupported: unsupported, controlWord: 0x037E, statusWord: 0x0200)
      let unmaskedRegisters = unmasked.floatingPoint.x87
      let unmaskedTags = unmasked.floatingPoint.x87TagWord
      try retire(&unmasked, memory: try memory(code: bytes), bytes: bytes)
      #expect(unmasked.floatingPoint.x87 == unmaskedRegisters)
      #expect(unmasked.floatingPoint.x87TagWord == unmaskedTags)
      #expect(unmasked.floatingPoint.x87StatusWord == 0x8081)
    }
  }

  private var interpreter: DoryX86Interpreter { .init() }

  private func emptyState(
    controlWord: UInt16, statusWord: UInt16
  ) throws -> DoryX86ArchitecturalState {
    let floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord, x87TagWord: 0xFFFF)
    return try architecturalState(floatingPoint)
  }

  private func binaryState(
    unsupported: [UInt8], controlWord: UInt16, statusWord: UInt16
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord, x87TagWord: 0xFFF2)
    floatingPoint.x87[0] = try register(unsupported)
    floatingPoint.x87[1] = try register(one)
    return try architecturalState(floatingPoint)
  }

  private func architecturalState(
    _ floatingPoint: DoryX86FloatingPointState
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: 0x1800), rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x0093, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: floatingPoint)
  }

  private func memory(
    code: [UInt8], operand: [UInt8]? = nil
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
    try memory.write(at: 0x1000, bytes: code)
    if let operand { try memory.write(at: 0x1800, bytes: operand) }
    return memory
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory,
    bytes: [UInt8]
  ) throws {
    let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
  }

  private func register(_ bytes: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: bytes, expectedByteCount: 10)
  }

  private func top(_ state: DoryX86FloatingPointState) -> Int {
    Int(state.x87StatusWord >> 11) & 7
  }

  private func tag(_ physical: Int, _ state: DoryX86FloatingPointState) -> UInt16 {
    state.x87TagWord >> UInt16(physical * 2) & 3
  }

  private func binary80(
    significand: UInt64, exponent: UInt16, negative: Bool = false
  ) -> [UInt8] {
    littleEndian(significand, count: 8)
      + littleEndian(UInt64(exponent | (negative ? 0x8000 : 0)), count: 2)
  }

  private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
