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
    #expect(
      instruction.operation
        == .move(
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
    #expect(
      ripRelative.operation
        == .move(
          destination: .register(.rax, width: .quadword),
          source: .memory(
            .init(
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
    #expect(
      sib.operation
        == .move(
          destination: .register(.rax, width: .quadword),
          source: .memory(
            .init(
              base: .r8,
              index: .r9,
              scale: 4,
              displacement: 0x20,
              width: .quadword
            ))
        ))
  }

  @Test func decodesControlFlowWithSignedDisplacements() throws {
    #expect(
      try decoder.decode([0xEB, 0xFE], at: 0x100, mode: .long64).operation == .jump(relative: -2))
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
    #expect(
      throws: DoryX86DecodeError.invalidEncoding(
        address: 0x6000, detail: "LEA requires a memory source")
    ) {
      try decoder.decode([0x48, 0x8D, 0xC0], at: 0x6000, mode: .long64)
    }
  }

  @Test func decodesPrivilegedControlAndTimingInstructions() throws {
    #expect(
      try decoder.decode([0x0F, 0x20, 0xD9], at: 0x7000, mode: .long64).operation
        == .readControlRegister(index: 3, destination: .rcx)
    )
    #expect(
      try decoder.decode([0x44, 0x0F, 0x22, 0xC0], at: 0x7000, mode: .long64).operation
        == .writeControlRegister(index: 8, source: .rax)
    )
    #expect(
      try decoder.decode([0x0F, 0x01, 0x38], at: 0x7000, mode: .long64).operation
        == .invalidatePage(.init(base: .rax, width: .quadword))
    )
    #expect(
      try decoder.decode([0x0F, 0x01, 0xF9], at: 0x7000, mode: .long64).operation
        == .readTimestampCounter(includeAuxiliary: true)
    )
    #expect(
      try decoder.decode([0x0F, 0x01, 0xF8], at: 0x7000, mode: .long64).operation
        == .swapGS
    )
  }

  @Test func decodesByteRegistersImmediateGroupsAndIndirectControlFlow() throws {
    #expect(
      try decoder.decode([0xB4, 0x12], at: 0x8000, mode: .long64).operation
        == .move(
          destination: .highByteRegister(.rax),
          source: .immediate(0x12, width: .byte)
        )
    )
    #expect(
      try decoder.decode([0x40, 0xB4, 0x12], at: 0x8000, mode: .long64).operation
        == .move(
          destination: .register(.rsp, width: .byte),
          source: .immediate(0x12, width: .byte)
        )
    )
    #expect(
      try decoder.decode([0x48, 0x83, 0xD0, 0xFF], at: 0x8000, mode: .long64).operation
        == .alu(
          .addWithCarry,
          destination: .register(.rax, width: .quadword),
          source: .immediate(.max, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0x48, 0xC1, 0xE0, 4], at: 0x8000, mode: .long64).operation
        == .shift(
          .shiftLeft,
          destination: .register(.rax, width: .quadword),
          count: .immediate(4)
        )
    )
    #expect(
      try decoder.decode([0xFF, 0xD0], at: 0x8000, mode: .long64).operation
        == .callIndirect(.register(.rax, width: .quadword))
    )
  }

  @Test func decodesMultiplyExtensionAndConditionalDataFlow() throws {
    #expect(
      try decoder.decode([0x48, 0x0F, 0xBE, 0xC0], at: 0x9000, mode: .long64).operation
        == .extendMove(
          destination: .register(.rax, width: .quadword),
          source: .register(.rax, width: .byte),
          signed: true
        )
    )
    #expect(
      try decoder.decode([0x48, 0x6B, 0xC1, 0xFE], at: 0x9000, mode: .long64).operation
        == .signedMultiply(
          destination: .register(.rax, width: .quadword),
          lhs: .register(.rcx, width: .quadword),
          rhs: .immediate(UInt64(bitPattern: -2), width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0x0F, 0x94, 0xC3], at: 0x9000, mode: .long64).operation
        == .setCondition(.equal, destination: .register(.rbx, width: .byte))
    )
    #expect(
      try decoder.decode([0x48, 0x0F, 0x44, 0xCA], at: 0x9000, mode: .long64).operation
        == .conditionalMove(
          .equal,
          destination: .register(.rcx, width: .quadword),
          source: .register(.rdx, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0x48, 0xF7, 0xFB], at: 0x9000, mode: .long64).operation
        == .accumulatorArithmetic(
          .signedDivide,
          source: .register(.rbx, width: .quadword)
        )
    )
  }

  @Test func decodesAtomicAndBitManipulationInstructions() throws {
    #expect(
      try decoder.decode([0x48, 0x87, 0x08], at: 0xA000, mode: .long64).operation
        == .exchange(
          .memory(.init(base: .rax, width: .quadword)),
          .register(.rcx, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0xF0, 0x48, 0x0F, 0xB1, 0x08], at: 0xA000, mode: .long64)
        .operation
        == .compareExchange(
          destination: .memory(.init(base: .rax, width: .quadword)),
          source: .register(.rcx, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0xF0, 0x48, 0x0F, 0xC1, 0x08], at: 0xA000, mode: .long64)
        .operation
        == .exchangeAdd(
          destination: .memory(.init(base: .rax, width: .quadword)),
          source: .register(.rcx, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0xF0, 0x48, 0x0F, 0xAB, 0x08], at: 0xA000, mode: .long64)
        .operation
        == .bitTest(
          .set,
          base: .memory(.init(base: .rax, width: .quadword)),
          index: .register(.rcx, width: .quadword)
        )
    )
    #expect(
      try decoder.decode([0xF0, 0x48, 0x0F, 0xC7, 0x08], at: 0xA000, mode: .long64)
        .operation
        == .compareExchangePair(
          destination: .init(base: .rax, width: .quadword),
          doubleQuadword: true
        )
    )
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode([0xF0, 0x48, 0x89, 0x08], at: 0xA000, mode: .long64)
    }
    #expect(
      try decoder.decode([0x0F, 0xAE, 0xF0], at: 0xA000, mode: .long64).operation
        == .memoryFence(.full)
    )
    #expect(
      try decoder.decode([0xF3, 0x90], at: 0xA000, mode: .long64).operation
        == .processorPause
    )
  }

  @Test func decodesRepeatableStringInstructionsWithoutInventingOperands() throws {
    let move = try decoder.decode([0xF3, 0xA4], at: 0xB000, mode: .long64)
    #expect(move.prefixes.repeatPrefix == 0xF3)
    #expect(move.operation == .string(.move, width: .byte))

    let compare = try decoder.decode([0xF2, 0x66, 0xA7], at: 0xB000, mode: .long64)
    #expect(compare.prefixes.repeatPrefix == 0xF2)
    #expect(compare.operation == .string(.compare, width: .word))
    #expect(
      try decoder.decode([0x48, 0xAB], at: 0xB000, mode: .long64).operation
        == .string(.store, width: .quadword)
    )
  }

  @Test func decodesRealModeAddressingAndRelativeWidths() throws {
    #expect(
      try decoder.decode([0x8B, 0x42, 0xFE], at: 0x100, mode: .real16).operation
        == .move(
          destination: .register(.rax, width: .word),
          source: .memory(
            .init(
              base: .rbp,
              index: .rsi,
              displacement: -2,
              width: .word,
              addressWidth: .word,
              segment: .ss,
              ignoresLegacySegmentBase: false
            ))
        )
    )
    #expect(
      try decoder.decode([0x26, 0x8B, 0x00], at: 0x100, mode: .real16).operation
        == .move(
          destination: .register(.rax, width: .word),
          source: .memory(
            .init(
              base: .rbx,
              index: .rsi,
              width: .word,
              addressWidth: .word,
              segment: .es,
              ignoresLegacySegmentBase: false
            ))
        )
    )
    #expect(
      try decoder.decode([0xE9, 0xFC, 0xFF], at: 0x100, mode: .real16).operation
        == .jump(relative: -4)
    )
  }

  @Test func decodesDescriptorTableTransitions() throws {
    #expect(
      try decoder.decode([0x0F, 0x01, 0x10], at: 0x200, mode: .real16).operation
        == .descriptorTable(
          .global,
          load: true,
          address: .init(
            base: .rbx,
            index: .rsi,
            width: .quadword,
            addressWidth: .word,
            ignoresLegacySegmentBase: false
          )
        )
    )
    #expect(
      try decoder.decode([0x0F, 0x01, 0x09], at: 0x200, mode: .long64).operation
        == .descriptorTable(
          .interrupt,
          load: false,
          address: .init(base: .rcx, width: .quadword)
        )
    )
  }

  @Test func decodesSegmentLoadsAndFarControlTransfer() throws {
    #expect(
      try decoder.decode([0x8E, 0xD8], at: 0x300, mode: .real16).operation
        == .writeSegment(.ds, source: .register(.rax, width: .word))
    )
    #expect(
      try decoder.decode([0x8C, 0xC8], at: 0x300, mode: .real16).operation
        == .readSegment(.cs, destination: .register(.rax, width: .word))
    )
    #expect(
      try decoder.decode([0xEA, 0x00, 0x02, 0x78, 0x56], at: 0x300, mode: .real16).operation
        == .farJump(offset: 0x200, selector: 0x5678)
    )
  }

  @Test func decodesMachineStatusTransitions() throws {
    #expect(
      try decoder.decode([0x0F, 0x01, 0xE0], at: 0x400, mode: .real16).operation
        == .machineStatusWord(load: false, operand: .register(.rax, width: .word))
    )
    #expect(
      try decoder.decode([0x0F, 0x01, 0xF0], at: 0x400, mode: .real16).operation
        == .machineStatusWord(load: true, operand: .register(.rax, width: .word))
    )
    #expect(
      try decoder.decode([0x0F, 0x06], at: 0x400, mode: .protected32).operation
        == .clearTaskSwitched
    )
  }

  @Test func decodesSystemSegmentLoads() throws {
    #expect(
      try decoder.decode([0x0F, 0x00, 0xD0], at: 0x500, mode: .protected32).operation
        == .loadSystemSegment(task: false, source: .register(.rax, width: .word))
    )
    #expect(
      try decoder.decode([0x0F, 0x00, 0xDB], at: 0x500, mode: .protected32).operation
        == .loadSystemSegment(task: true, source: .register(.rbx, width: .word))
    )
  }

  @Test func decodesFarCallAndReturnFrames() throws {
    #expect(
      try decoder.decode([0x9A, 0x34, 0x12, 0x78, 0x56], at: 0x600, mode: .real16).operation
        == .farCall(offset: 0x1234, selector: 0x5678, width: .word)
    )
    #expect(
      try decoder.decode([0xCA, 8, 0], at: 0x600, mode: .protected32).operation
        == .farReturn(popBytes: 8, width: .doubleword)
    )
  }

  @Test func decodesScalarPortIOWithArchitecturalWidths() throws {
    #expect(
      try decoder.decode([0xE4, 0x60], at: 0x700, mode: .long64).operation
        == .input(port: .immediate(0x60), width: .byte)
    )
    #expect(
      try decoder.decode([0x66, 0xED], at: 0x700, mode: .long64).operation
        == .input(port: .dx, width: .word)
    )
    #expect(
      try decoder.decode([0x48, 0xEF], at: 0x700, mode: .long64).operation
        == .output(port: .dx, width: .doubleword)
    )
    #expect(
      try decoder.decode([0xE7, 0x80], at: 0x700, mode: .real16).operation
        == .output(port: .immediate(0x80), width: .word)
    )
  }
}
