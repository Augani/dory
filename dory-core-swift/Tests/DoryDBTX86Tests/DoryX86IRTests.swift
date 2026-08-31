import Testing

@testable import DoryDBTX86

@Suite struct DoryX86IRTests {
  @Test func translatesStraightLineIntegerWorkIntoTypedIR() throws {
    let bytes: [UInt8] = [
      0xB8, 5, 0, 0, 0,
      0x05, 3, 0, 0, 0,
      0x3D, 8, 0, 0, 0,
      0x75, 0xFE,
      0xF4,
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: 0x1000, mode: .protected32)

    #expect(block.guestStart == 0x1000)
    #expect(block.guestByteCount == 17)
    #expect(block.guestInstructionCount == 4)
    #expect(block.statements.count == 3)
    #expect(
      block.terminator
        == .conditional(
          condition: "x86.condition.5",
          taken: 0x100F,
          notTaken: 0x1011
        )
    )
  }

  @Test func unsupportedOperationsExitThroughAnObservableInterpreterHelper() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x0F, 0xA2, 0x90],
      at: 0x2000,
      mode: .long64
    )

    #expect(block.guestByteCount == 2)
    #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: [0x0F, 0xA2])])
    #expect(block.terminator == .exit(.interpreter, resumeAt: 0x2000))
  }

  @Test func packsOneReadWithRegisterWorkButStopsBeforeASecondAccess() throws {
    let block = try DoryX86IRTranslator().translate(
      [
        0xB8, 1, 0, 0, 0,
        0x48, 0x8B, 0x08,
        0x48, 0x83, 0xC2, 0x01,
        0x48, 0x8B, 0x18,
      ],
      at: 0x2400,
      mode: .long64
    )

    #expect(block.guestByteCount == 12)
    #expect(block.guestInstructionCount == 3)
    #expect(block.statements.count == 3)
    #expect(block.terminator == .next(0x240C))
    #expect(DoryARM64BaselineEmitter().compile(block).tier == .baseline)
  }

  @Test func memoryWriteRemainsASelfModifyingCodeBoundary() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x48, 0x89, 0x08, 0x48, 0x83, 0xC2, 0x01],
      at: 0x2500,
      mode: .long64
    )

    #expect(block.guestByteCount == 3)
    #expect(block.guestInstructionCount == 1)
    #expect(block.terminator == .next(0x2503))
  }

  @Test func instructionBudgetCreatesAStableResumeBoundary() throws {
    let block = try DoryX86IRTranslator(instructionBudget: 2).translate(
      [0x90, 0x90, 0x90],
      at: 0x3000,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 2)
    #expect(block.guestByteCount == 2)
    #expect(block.terminator == .exit(.instructionBudget, resumeAt: 0x3002))
  }
}
