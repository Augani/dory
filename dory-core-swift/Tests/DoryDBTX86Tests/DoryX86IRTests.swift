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
    let expectedBoundaries: [DoryIRInstructionBoundary] = [
      .init(guestRIP: 0x1000, guestByteOffset: 0, guestByteCount: 5,
        statementStartIndex: 0, statementCount: 1),
      .init(guestRIP: 0x1005, guestByteOffset: 5, guestByteCount: 5,
        statementStartIndex: 1, statementCount: 1),
      .init(guestRIP: 0x100A, guestByteOffset: 10, guestByteCount: 5,
        statementStartIndex: 2, statementCount: 1),
      .init(guestRIP: 0x100F, guestByteOffset: 15, guestByteCount: 2,
        statementStartIndex: 3, statementCount: 0),
    ]
    #expect(block.instructionBoundaries == expectedBoundaries)
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

  @Test func prefixedBitScansLowerOnlyWhenTheSelectedProfileUsesAliasSemantics() throws {
    let baseline = try DoryX86IRTranslator().translate(
      [0xF3, 0x48, 0x0F, 0xBC, 0xDB],
      at: 0x2100,
      mode: .long64
    )
    #expect(baseline.statements == [
      .bitScan(
        reverse: false,
        destination: .register(.init(bank: "x86.gpr", index: 3, width: .i64)),
        source: .register(.init(bank: "x86.gpr", index: 3, width: .i64))
      )
    ])

    let baselineLeading = try DoryX86IRTranslator().translate(
      [0xF3, 0x48, 0x0F, 0xBD, 0xDB],
      at: 0x2110,
      mode: .long64
    )
    #expect(baselineLeading.statements == [
      .bitScan(
        reverse: true,
        destination: .register(.init(bank: "x86.gpr", index: 3, width: .i64)),
        source: .register(.init(bank: "x86.gpr", index: 3, width: .i64))
      )
    ])

    let extendedProfile = DoryX86CPUProfile(
      identifier: "test.ir.bmi1-lzcnt",
      features: DoryX86CPUProfile.compatibleV1.features.union([.bmi1, .lzcnt]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true
    )
    let tzcnt = try DoryX86IRTranslator(profile: extendedProfile).translate(
      [0xF3, 0x48, 0x0F, 0xBC, 0xDB],
      at: 0x2100,
      mode: .long64
    )
    #expect(tzcnt.statements == [
      .helper(identifier: "x86.interpret.one", payload: [0xF3, 0x48, 0x0F, 0xBC, 0xDB])
    ])
    #expect(tzcnt.terminator == .exit(.interpreter, resumeAt: 0x2100))

    let lzcnt = try DoryX86IRTranslator(profile: extendedProfile).translate(
      [0xF3, 0x48, 0x0F, 0xBD, 0xDB],
      at: 0x2110,
      mode: .long64
    )
    #expect(lzcnt.statements == [
      .helper(identifier: "x86.interpret.one", payload: [0xF3, 0x48, 0x0F, 0xBD, 0xDB])
    ])
    #expect(lzcnt.terminator == .exit(.interpreter, resumeAt: 0x2110))
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

  @Test func memoryConditionalMovesLowerNativelyWhileWordFormsRemainFallbacks() throws {
    let memoryBytes: [UInt8] = [
      0x4C, 0x0F, 0x43, 0x6C, 0x24, 0x68,  // cmovae r13,[rsp+0x68]
    ]
    let memoryBlock = try DoryX86IRTranslator().translate(
      memoryBytes, at: 0x3000, mode: .long64)
    #expect(memoryBlock.guestInstructionCount == 1)
    let compiledMemory = DoryARM64BaselineEmitter().compile(memoryBlock)
    #expect(compiledMemory.tier == .baseline)
    #expect(compiledMemory.requiresMemoryCallbacks)
    #expect(compiledMemory.mayExitToInterpreter == false)

    let wordBlock = try DoryX86IRTranslator().translate(
      [0x66, 0x0F, 0x42, 0xC3],  // cmovb ax,bx
      at: 0x3000,
      mode: .long64
    )
    #expect(wordBlock.guestInstructionCount == 1)
    #expect(DoryARM64BaselineEmitter().compile(wordBlock).tier == .interpreterFallback)
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
    #expect(block.instructionBoundaries.count == 2)
    #expect(block.instructionBoundaries.allSatisfy { $0.statementCount == 0 })
  }

  @Test func dispatchBoundaryDoesNotPublishMetadataForTheRewoundInstruction() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x90, 0x0F, 0xA2],  // nop; cpuid
      at: 0x3100,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 1)
    #expect(block.guestByteCount == 1)
    #expect(block.terminator == .next(0x3101))
    let expectedBoundaries: [DoryIRInstructionBoundary] = [
      .init(guestRIP: 0x3100, guestByteOffset: 0, guestByteCount: 1,
        statementStartIndex: 0, statementCount: 0)
    ]
    #expect(block.instructionBoundaries == expectedBoundaries)
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
