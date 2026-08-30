import Testing

@testable import DoryDBTX86

@Suite struct DoryX86DecoderTests {
  private let decoder = DoryX86Decoder()

  @Test func decodesREXImmediateAndExtendedRegisters() throws {
    let instruction = try decoder.decode(
      [0x49, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11],
      at: 0x1000,
      mode: .long64
    )
    #expect(instruction.length == 10)
    #expect(instruction.nextInstructionAddress == 0x100A)
    #expect(instruction.operation == .move(
      destination: .register(.r8, width: .quadword),
      source: .immediate(0x1122_3344_5566_7788, width: .quadword)
    ))
  }

  @Test func decodesRIPRelativeAndSIBMemory() throws {
    let ripRelative = try decoder.decode(
      [0x48, 0x8B, 0x05, 0x34, 0x12, 0, 0],
      at: 0x2000,
      mode: .long64
    )
    #expect(ripRelative.operation == .move(
      destination: .register(.rax, width: .quadword),
      source: .memory(.init(
        base: nil,
        displacement: 0x1234,
        ripRelative: true,
        width: .quadword
      ))
    ))

    let sib = try decoder.decode(
      [0x4B, 0x8B, 0x44, 0x88, 0x20],
      at: 0x3000,
      mode: .long64
    )
    #expect(sib.operation == .move(
      destination: .register(.rax, width: .quadword),
      source: .memory(.init(
        base: .r8,
        index: .r9,
        scale: 4,
        displacement: 0x20,
        width: .quadword
      ))
    ))
  }

  @Test func decodesControlFlowWithSignedDisplacements() throws {
    #expect(try decoder.decode([0xEB, 0xFE], at: 0x100, mode: .long64).operation == .jump(relative: -2))
    #expect(
      try decoder.decode([0x0F, 0x85, 0xFC, 0xFF, 0xFF, 0xFF], at: 0x100, mode: .long64).operation
        == .conditionalJump(.notEqual, relative: -4)
    )
  }

  @Test func enforcesArchitecturalInstructionLengthAndRejectsUnknownOpcodes() throws {
    let prefixes = Array(repeating: UInt8(0x66), count: 15)
    #expect(throws: DoryX86DecodeError.instructionTooLong(address: 0x4000)) {
      try decoder.decode(prefixes + [0x90], at: 0x4000, mode: .long64)
    }
    #expect(throws: DoryX86DecodeError.unsupportedOpcode(address: 0x5000, bytes: [0x0F, 0x0B])) {
      try decoder.decode([0x0F, 0x0B], at: 0x5000, mode: .long64)
    }
  }

  @Test func rejectsRegisterFormLEAInsteadOfInventingSemantics() throws {
    #expect(throws: DoryX86DecodeError.invalidEncoding(address: 0x6000, detail: "LEA requires a memory source")) {
      try decoder.decode([0x48, 0x8D, 0xC0], at: 0x6000, mode: .long64)
    }
  }
}
