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

  @Test func registerConditionalMovesLowerToTypedNativeIR() throws {
    let bytes: [UInt8] = [
      0x41, 0x0F, 0x42, 0xF9,  // cmovb edi,r9d
      0x48, 0x0F, 0x42, 0xCA,  // cmovb rcx,rdx
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: 0x102_D533, mode: .long64)

    #expect(block.guestByteCount == bytes.count)
    #expect(block.guestInstructionCount == 2)
    #expect(block.statements.count == 2)
    guard
      case .conditionalMove(.below, let firstDestination, let firstSource) =
        block.statements[0],
      case .conditionalMove(.below, let secondDestination, let secondSource) =
        block.statements[1]
    else {
      Issue.record("hot CMOV pair did not lower to typed IR")
      return
    }
    #expect(
      firstDestination == .register(.init(bank: "x86.gpr", index: 7, width: .i32)))
    #expect(firstSource == .register(.init(bank: "x86.gpr", index: 9, width: .i32)))
    #expect(
      secondDestination == .register(.init(bank: "x86.gpr", index: 1, width: .i64)))
    #expect(secondSource == .register(.init(bank: "x86.gpr", index: 2, width: .i64)))
    #expect(DoryARM64BaselineEmitter().compile(block).tier == .baseline)
  }

  @Test func memoryAndWordConditionalMovesRemainInterpreterFallbacks() throws {
    let cases: [[UInt8]] = [
      [0x4C, 0x0F, 0x43, 0x6C, 0x24, 0x68],  // cmovae r13,[rsp+0x68]
      [0x66, 0x0F, 0x42, 0xC3],  // cmovb ax,bx
    ]

    for bytes in cases {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0x3000, mode: .long64)
      #expect(block.guestInstructionCount == 1)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
  }

  @Test func packsMultipleReadsWithRegisterWorkIntoOneRestartableBlock() throws {
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

    #expect(block.guestByteCount == 15)
    #expect(block.guestInstructionCount == 4)
    #expect(block.statements.count == 4)
    #expect(block.terminator == .next(0x240F))
    let compiled = DoryARM64BaselineEmitter().compile(block)
    #expect(compiled.tier == .baseline)
    #expect(compiled.requiresRestartableMemoryReads)
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

  @Test func prefetchHintsRemainPureNativeInstructions() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x0F, 0x18, 0x0A, 0x0F, 0x18, 0x4A, 0x40, 0x90],
      at: 0x3400,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 3)
    #expect(block.guestByteCount == 8)
    #expect(block.statements.isEmpty)
    #expect(block.terminator == .next(0x3408))
    let compiled = DoryARM64BaselineEmitter().compile(block)
    #expect(compiled.tier == .baseline)
    #expect(!compiled.requiresMemoryCallbacks)
  }

  @Test func endBranchWithoutCETRemainsAPureNativeInstruction() throws {
    let block = try DoryX86IRTranslator().translate(
      [0xF3, 0x0F, 0x1E, 0xFA, 0xF3, 0x0F, 0x1E, 0xFB, 0x90],
      at: 0x3500,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 3)
    #expect(block.guestByteCount == 9)
    #expect(block.statements.isEmpty)
    #expect(block.terminator == .next(0x3509))
    let compiled = DoryARM64BaselineEmitter().compile(block)
    #expect(compiled.tier == .baseline)
    #expect(!compiled.requiresMemoryCallbacks)
  }
}
