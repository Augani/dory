import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B MOVDQ2Q pp. 4-57–58, MOVQ pp. 4-99–100,
// and MOVQ2DQ pp. 4-102–103. These tests qualify only the three legacy
// mandatory-prefix forms of 0F D6 represented here.
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86D6MoveTests {
  @Test func mandatoryPrefixesSelectExactRegisterAndMemoryFormsInEveryMode() throws {
    for mode in modes {
      let movq = try DoryX86Decoder().decode([0x66, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: mode)
      #expect(movq.operation == .moveVectorScalar(
        destination: .register(1), source: .register(0), byteCount: 8, upperPolicy: .zero))

      let store = try DoryX86Decoder().decode([0x66, 0x0F, 0xD6, 0x03], at: 0x1000, mode: mode)
      guard case .moveVectorScalar(.memory(_), .register(0), 8, .zero) = store.operation else {
        Issue.record("66 0F D6 did not retain its m64 destination")
        continue
      }

      let toXMM = try DoryX86Decoder().decode([0xF3, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: mode)
      #expect(toXMM.operation == .moveMMXToVector(destination: 0, source: 1))
      let toMMX = try DoryX86Decoder().decode([0xF2, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: mode)
      #expect(toMMX.operation == .moveVectorToMMX(destination: 0, source: 1))
      #expect(try DoryX86Decoder().decode(
        [0x67, 0x2E, 0xF3, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: mode).operation
        == toXMM.operation)
    }

    #expect(try DoryX86Decoder().decode(
      [0x66, 0x45, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: .long64).operation
      == .moveVectorScalar(
        destination: .register(9), source: .register(8), byteCount: 8, upperPolicy: .zero))
    #expect(try DoryX86Decoder().decode(
      [0xF3, 0x44, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: .long64).operation
      == .moveMMXToVector(destination: 8, source: 1))
    #expect(try DoryX86Decoder().decode(
      [0xF2, 0x41, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: .long64).operation
      == .moveVectorToMMX(destination: 0, source: 9))
    #expect(try DoryX86Decoder().decode(
      [0xF3, 0x48, 0x0F, 0xD6, 0xC1], at: 0x1000, mode: .long64).operation
      == .moveMMXToVector(destination: 0, source: 1))
  }

  @Test func reservedPrefixesMemoryCrossDomainAndExtendedMMXEncodingsAreRejected() throws {
    for mode in modes {
      for bytes: [UInt8] in [
        [0x0F, 0xD6, 0xC1], [0x66, 0xF2, 0x0F, 0xD6, 0xC1],
        [0x66, 0xF3, 0x0F, 0xD6, 0xC1], [0xF2, 0x0F, 0xD6, 0x03],
        [0xF3, 0x0F, 0xD6, 0x03], [0xF0, 0x66, 0x0F, 0xD6, 0x03],
        [0xF0, 0xF2, 0x0F, 0xD6, 0xC1], [0xF0, 0xF3, 0x0F, 0xD6, 0xC1],
      ] {
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
        }
      }
    }
    for bytes: [UInt8] in [
      [0xF3, 0x41, 0x0F, 0xD6, 0xC1], // REX.B cannot create MM8.
      [0xF2, 0x44, 0x0F, 0xD6, 0xC1], // REX.R cannot create MM8.
    ] {
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      }
    }
  }

  @Test func registerTransfersPreserveArchitecturalUpperStateAndApplyMMXRetirement() throws {
    var state = try initialState()
    let initial = state.floatingPoint
    try retire([0x66, 0x0F, 0xD6, 0xC1], state: &state)
    #expect(state.floatingPoint.ymm[1].bytes == Array(initial.ymm[0].bytes.prefix(8))
      + [UInt8](repeating: 0, count: 8) + Array(initial.ymm[1].bytes.suffix(16)))
    #expect(state.floatingPoint.x87 == initial.x87)
    #expect(state.floatingPoint.x87StatusWord == initial.x87StatusWord)
    #expect(state.floatingPoint.x87TagWord == initial.x87TagWord)

    state = try initialState()
    let beforeToXMM = state.floatingPoint
    try retire([0xF3, 0x0F, 0xD6, 0xC1], state: &state)
    #expect(state.floatingPoint.ymm[0].bytes == Array(beforeToXMM.x87[1].bytes.prefix(8))
      + [UInt8](repeating: 0, count: 8) + Array(beforeToXMM.ymm[0].bytes.suffix(16)))
    #expect(state.floatingPoint.x87 == beforeToXMM.x87)
    #expect(state.floatingPoint.x87TagWord == 0)
    #expect(state.floatingPoint.x87StatusWord == beforeToXMM.x87StatusWord & ~UInt16(0x3800))

    state = try initialState()
    let beforeToMMX = state.floatingPoint
    try retire([0xF2, 0x0F, 0xD6, 0xC1], state: &state)
    #expect(state.floatingPoint.x87[0].bytes == Array(beforeToMMX.ymm[1].bytes.prefix(8)) + [0xFF, 0xFF])
    #expect(state.floatingPoint.x87.dropFirst() == beforeToMMX.x87.dropFirst())
    #expect(state.floatingPoint.ymm == beforeToMMX.ymm)
    #expect(state.floatingPoint.x87TagWord == 0)
    #expect(state.floatingPoint.x87StatusWord == beforeToMMX.x87StatusWord & ~UInt16(0x3800))
  }

  @Test func movqMemoryDestinationWritesExactlyEightBytesAndFaultsAtomically() throws {
    let bytes: [UInt8] = [0x66, 0x0F, 0xD6, 0x03]
    var state = try initialState()
    let before = state
    let memory = D6MoveMemory(code: bytes)
    try retire(bytes, state: &state, memory: memory)
    #expect(memory.validatedWrites.count == 1)
    #expect(memory.validatedWrites.first?.0 == 0x8000)
    #expect(memory.validatedWrites.first?.1 == 8)
    #expect(memory.writes.count == 1)
    #expect(memory.writes.first?.address == 0x8000)
    #expect(memory.writes.first?.bytes == Array(before.floatingPoint.ymm[0].bytes.prefix(8)))
    #expect(state.floatingPoint == before.floatingPoint)

    state = try initialState()
    var expected = state
    expected.control.cr2 = 0x8000
    let denied = D6MoveMemory(code: bytes, denyWrite: true)
    #expect(DoryX86Interpreter().step(state: &state, memory: denied, mode: .long64)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 2,
        instructionPointer: 0x1000, linearAddress: 0x8000)))
    #expect(state == expected)
    #expect(denied.validatedWrites.count == 1)
    #expect(denied.validatedWrites.first?.0 == 0x8000)
    #expect(denied.validatedWrites.first?.1 == 8 && denied.writes.isEmpty)
  }

  @Test func featureAndExecutionStateFaultsPrecedeAllEffectsWithSpecifiedPriority() throws {
    for bytes: [UInt8] in [[0xF3, 0x0F, 0xD6, 0xC1], [0xF2, 0x0F, 0xD6, 0xC1]] {
      for variant in 0..<7 {
        var state = try initialState()
        let selectedProfile: DoryX86CPUProfile
        switch variant {
        case 0:
          selectedProfile = profile(removing: [.sse2])
          state.control.cr0 |= 8
        case 1:
          selectedProfile = profile(removing: [.mmx])
          state.control.cr0 |= 8
        default:
          selectedProfile = .compatibleV1
          if variant == 2 { state.control.cr0 |= 4 | 8 }
          if variant == 3 { state.control.cr4 &= ~UInt64(1 << 9); state.control.cr0 |= 8 }
          if variant == 4 { state.control.cr0 |= 8 }
          if variant >= 5 { state.floatingPoint.x87StatusWord |= 0x80 }
          if variant == 6 { state.control.cr4 &= ~UInt64(1 << 9) }
        }
        let before = state
        let expectedKind: DoryX86Exception.Kind = variant == 4 ? .deviceNotAvailable
          : variant == 5 ? .x87FloatingPoint : .invalidOpcode
        let vector: UInt8 = variant == 4 ? 7 : variant == 5 ? 16 : 6
        let memory = D6MoveMemory(code: bytes)
        #expect(DoryX86Interpreter(profile: selectedProfile).step(
          state: &state, memory: memory, mode: .long64) == .exception(.init(
            kind: expectedKind, vector: vector, instructionPointer: 0x1000)))
        #expect(state == before && memory.validatedWrites.isEmpty && memory.writes.isEmpty)
      }
    }

    // The pure XMM/m64 MOVQ does not acquire an MMX feature or MMX tag/TOP effect.
    var state = try initialState()
    let before = state.floatingPoint
    let bytes: [UInt8] = [0x66, 0x0F, 0xD6, 0xC1]
    let memory = D6MoveMemory(code: bytes)
    let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter(profile: profile(removing: [.mmx])).step(
      state: &state, memory: memory, mode: .long64) == .retired(decoded))
    #expect(state.floatingPoint.x87 == before.x87)
    #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(state.floatingPoint.x87StatusWord == before.x87StatusWord)
  }

  @Test func allThreeFormsAreInterpreterFallbacksInBothNativeTiers() throws {
    for bytes: [UInt8] in [
      [0x66, 0x0F, 0xD6, 0xC1], [0x66, 0x0F, 0xD6, 0x03],
      [0xF3, 0x0F, 0xD6, 0xC1], [0xF2, 0x0F, 0xD6, 0xC1],
    ] {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0x1000, mode: .long64)
      #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: bytes)])
      #expect(block.terminator == .exit(.interpreter, resumeAt: 0x1000))
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        #expect(DoryARM64BaselineEmitter().compile(block, tier: tier).tier == .interpreterFallback)
      }
    }
  }

  @Test func nativePrefixPublishesOnceThenBothTiersStopWithoutD6Effects() throws {
    #if os(macOS) && arch(arm64)
      for form: [UInt8] in [[0x66, 0x0F, 0xD6, 0xC1], [0xF3, 0x0F, 0xD6, 0xC1],
        [0xF2, 0x0F, 0xD6, 0xC1]] {
        let code: [UInt8] = [0x48, 0xFF, 0xC1] + form
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16384, optimization: optimization)
          let memory = D6MoveMemory(code: code)
          var state = try initialState()
          let initialFP = state.floatingPoint
          let prefix = try #require(executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
            state: &state, memory: memory))
          #expect(prefix.guestInstructionCount == 1)
          #expect(state.rip == 0x1003 && state.registers.rcx == 1)
          #expect(state.floatingPoint == initialFP)
          let atBoundary = state
          #expect(try executor.executeSummary(
            byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
          #expect(state == atBoundary && memory.writes.isEmpty)
        }
      }
    #endif
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func initialState() throws -> DoryX86ArchitecturalState {
    let x87 = try (0..<8).map { register in
      try DoryX86RegisterBytes(
        bytes: (0..<10).map { UInt8(truncatingIfNeeded: register * 31 + $0 * 7) },
        expectedByteCount: 10)
    }
    let ymm = try (0..<16).map { register in
      try DoryX86RegisterBytes(
        bytes: (0..<32).map { UInt8(truncatingIfNeeded: 0x20 + register * 17 + $0) },
        expectedByteCount: 32)
    }
    return try .init(registers: .init(rbx: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow], cs: .init(attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x31, cr4: 1 << 9),
      floatingPoint: .init(x87: x87, ymm: ymm, x87ControlWord: 0x037F,
        x87StatusWord: 5 << 11, x87TagWord: 0xA5A5, mxcsr: 0x1F80, mxcsrMask: 0xFFFF))
  }

  private func retire(
    _ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    memory: D6MoveMemory? = nil
  ) throws {
    let selectedMemory = memory ?? D6MoveMemory(code: bytes)
    let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: selectedMemory,
      mode: .long64) == .retired(decoded))
  }

  private func profile(removing features: Set<DoryX86Feature>) -> DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(identifier: "test.d6-move", features: base.features.subtracting(features),
      physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz)
  }
}

private final class D6MoveMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let denyWrite: Bool
  private(set) var validatedWrites: [(UInt64, Int)] = []
  private(set) var writes: [(address: UInt64, bytes: [UInt8])] = []

  init(code: [UInt8], denyWrite: Bool = false) {
    self.code = code
    self.denyWrite = denyWrite
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    validatedWrites.append((address, byteCount))
    guard !denyWrite else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
    }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes.append((address, bytes))
  }
}
