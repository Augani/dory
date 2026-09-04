import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A section 15.2/Table 15-2: reads, writes and EMMS all
// clear TOP; only destination MMX registers acquire an all-ones exponent.
// This covers successful effects and ordinary operand/admission faults, not
// pending numeric exception generation/delivery or x87 environment formats.
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86MMXStateEffectsTests {
  private let writingForms: [[UInt8]] = [
    [0x0F, 0x6F, 0xC1], [0x0F, 0x7F, 0xC8], // MOVQ MM0,MM1, both directions
    [0x0F, 0x6E, 0xC0], // MOVD MM0,EAX
    [0x0F, 0xEF, 0xC1], [0x0F, 0xFC, 0xC1], // PXOR, PADDB
    [0x0F, 0x71, 0xD0, 1], [0x0F, 0xD1, 0xC1], // PSRLW immediate/register
    [0x0F, 0x60, 0xC1], [0x0F, 0x63, 0xC1], // PUNPCKLBW, PACKSSWB
    [0x0F, 0xC4, 0xC0, 1], // PINSRW MM0,EAX,1
    [0x0F, 0xE0, 0xC1], [0x0F, 0xD4, 0xC1], // SSE PAVGB, SSE2 PADDQ, MMX forms
  ]
  private let readingForms: [[UInt8]] = [
    [0x0F, 0x7E, 0xD8], // MOVD EAX,MM3
    [0x0F, 0xC5, 0xC3, 3], // PEXTRW EAX,MM3,3
    [0x0F, 0xD7, 0xC3], // PMOVMSKB EAX,MM3
  ]

  @Test func representedMMXWritersSetAllTagsAndClearEveryInitialTOP() throws {
    for mode in modes {
      for top: UInt16 in 0..<8 {
        for code in writingForms {
          var state = try state(mode: mode, top: top)
          let before = state
          let memory = MMXEffectMemory(code: code)
          try retire(code, state: &state, memory: memory, mode: mode)
          #expect(state.floatingPoint.x87TagWord == 0)
          #expect(state.floatingPoint.x87StatusWord == before.floatingPoint.x87StatusWord & ~UInt16(0x3800))
          #expect(state.floatingPoint.x87[0].bytes.suffix(2).elementsEqual([0xFF, 0xFF]))
          #expect(state.floatingPoint.x87.dropFirst() == before.floatingPoint.x87.dropFirst())
          #expect(state.floatingPoint.x87ControlWord == before.floatingPoint.x87ControlWord)
          #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
          #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr)
          #expect(state.floatingPoint.mxcsrMask == before.floatingPoint.mxcsrMask)
          #expect(state.rflags == before.rflags && state.registers == before.registers)
          #expect(memory.dataAccesses == 0)
        }
      }
    }
  }

  @Test func readOnlyFormsKeepPhysicalBytesAndReadMM3IndependentlyOfTOP() throws {
    for mode in modes {
      for top: UInt16 in 0..<8 {
        for (index, code) in readingForms.enumerated() {
          var state = try state(mode: mode, top: top)
          let before = state
          let bytes = before.floatingPoint.x87[3].bytes
          let output: UInt64
          switch index {
          case 0: output = integer(Array(bytes.prefix(4)))
          case 1: output = integer(Array(bytes[6..<8]))
          default:
            output = bytes.prefix(8).enumerated().reduce(0) {
              $0 | (($1.element & 0x80 != 0 ? UInt64(1) : 0) << UInt64($1.offset))
            }
          }
          let memory = MMXEffectMemory(code: code)
          try retire(code, state: &state, memory: memory, mode: mode)
          var expected = before
          expected.rip += UInt64(code.count)
          expected.registers.rax = output
          expected.floatingPoint.x87TagWord = 0
          expected.floatingPoint.x87StatusWord &= ~UInt16(0x3800)
          #expect(state == expected && memory.dataAccesses == 0)
        }
      }
    }
    var state = try state(top: 7)
    let before = state
    let code: [UInt8] = [0x48, 0x0F, 0x7E, 0xD8] // MOVQ RAX,MM3
    let memory = MMXEffectMemory(code: code)
    try retire(code, state: &state, memory: memory)
    #expect(state.registers.rax == integer(Array(before.floatingPoint.x87[3].bytes.prefix(8))))
    #expect(state.floatingPoint.x87 == before.floatingPoint.x87)
    #expect(state.floatingPoint.x87TagWord == 0 && state.floatingPoint.x87StatusWord & 0x3800 == 0)
  }

  @Test func storeOnlyFormsCommitMemoryThenSetTagsWithoutChangingAnyPhysicalRegister() throws {
    let forms: [([UInt8], Int)] = [
      ([0x0F, 0x7F, 0x1B], 8), // MOVQ [RBX],MM3
      ([0x0F, 0x7E, 0x1B], 4), // MOVD [RBX],MM3
      ([0x48, 0x0F, 0x7E, 0x1B], 8), // MOVQ [RBX],MM3, integer transfer
    ]
    for (code, width) in forms {
      var state = try state(top: 6)
      let before = state
      let memory = MMXEffectMemory(code: code)
      try retire(code, state: &state, memory: memory)
      var expected = before
      expected.rip += UInt64(code.count)
      expected.floatingPoint.x87TagWord = 0
      expected.floatingPoint.x87StatusWord &= ~UInt16(0x3800)
      #expect(state == expected && memory.writes == 1)
      #expect(memory.data.prefix(width).elementsEqual(before.floatingPoint.x87[3].bytes.prefix(width)))
      #expect(memory.data.dropFirst(width).allSatisfy { $0 == 0xA5 })
    }
  }

  @Test func emmsEmptiesTagsAndClearsTOPWithoutAlteringRegisterPayloads() throws {
    for mode in modes {
      for top: UInt16 in 0..<8 {
        for tags: UInt16 in [0, 0x1234, 0xFFFF] {
          var state = try state(mode: mode, top: top)
          state.floatingPoint.x87TagWord = tags
          var expected = state
          expected.rip += 2
          expected.floatingPoint.x87TagWord = 0xFFFF
          expected.floatingPoint.x87StatusWord &= ~UInt16(0x3800)
          let memory = MMXEffectMemory(code: [0x0F, 0x77])
          try retire([0x0F, 0x77], state: &state, memory: memory, mode: mode)
          #expect(state == expected && memory.dataAccesses == 0)
        }
      }
    }
  }

  @Test func faultsCannotPublishMMXTagsTOPOrDataWrites() throws {
    for (code, write) in [([UInt8(0x0F), 0x6F, 0x03], false), ([0x0F, 0x7F, 0x1B], true),
      ([0x0F, 0x7E, 0x1B], true)] {
      var state = try state(top: 5)
      var expected = state
      expected.control.cr2 = 0x4000
      let memory = MMXEffectMemory(code: code, failData: true)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .pageFault, vector: 14, errorCode: write ? 2 : 0,
          instructionPointer: 0x1000, linearAddress: 0x4000)))
      #expect(state == expected && memory.writes == 0 && memory.data.allSatisfy { $0 == 0xA5 })
    }
    for code in readingForms + [[0x0F, 0x7F, 0x1B], [0x0F, 0x77]] {
      for bits: UInt64 in [4, 8, 12] {
        var state = try state(top: 7)
        state.control.cr0 |= bits
        let before = state
        let memory = MMXEffectMemory(code: code)
        let kind: DoryX86Exception.Kind = bits & 4 != 0 ? .invalidOpcode : .deviceNotAvailable
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: kind, vector: bits & 4 != 0 ? 6 : 7, instructionPointer: 0x1000)))
        #expect(state == before && memory.dataAccesses == 0)
      }
      var state = try state(top: 7)
      let before = state
      let memory = MMXEffectMemory(code: code)
      let base = DoryX86CPUProfile.compatibleV1
      let masked = DoryX86CPUProfile(identifier: "test-only.mmx-masked",
        features: base.features.subtracting([.mmx]), physicalAddressBits: base.physicalAddressBits,
        linearAddressBits: base.linearAddressBits, virtualTSCFrequencyHz: base.virtualTSCFrequencyHz)
      #expect(DoryX86Interpreter(profile: masked).step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
      #expect(state == before && memory.dataAccesses == 0)
    }
  }

  @Test func xmmNearNeighborsNeverAcquireMMXTagOrTOPEffects() throws {
    for code in writingForms + readingForms {
      let xmm = [UInt8(0x66)] + code
      var state = try state(top: 7)
      let before = state.floatingPoint
      let memory = MMXEffectMemory(code: xmm)
      try retire(xmm, state: &state, memory: memory)
      #expect(state.floatingPoint.x87 == before.x87)
      #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
      #expect(state.floatingPoint.x87StatusWord == before.x87StatusWord)
      #expect(state.floatingPoint.x87ControlWord == before.x87ControlWord)
    }
  }

  @Test func bothNativeTiersDeclineEveryRepresentedMMXCategory() throws {
    for code in writingForms + readingForms + [[0x0F, 0x77], [0x0F, 0x7F, 0x1B]] {
      let block = try DoryX86IRTranslator().translate(code, at: 0x1000, mode: .long64)
      #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: code)])
      #expect(block.terminator == .exit(.interpreter, resumeAt: 0x1000))
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        #expect(DoryARM64BaselineEmitter().compile(block, tier: tier).tier == .interpreterFallback)
      }
    }
  }

  @Test func nativePrefixFallbackAndRetryDoNotDuplicateRetirementEffects() throws {
    #if os(macOS) && arch(arm64)
      let mmx: [UInt8] = [0x0F, 0x7E, 0xD8]
      let code: [UInt8] = [0x48, 0xFF, 0xC1] + mmx + [0x48, 0xFF, 0xC2]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let memory = MMXEffectMemory(code: code)
        var state = try state(top: 6)
        state.control.cr0 |= 8
        let initial = state
        let prefix = try #require(executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 3, state: &state, memory: memory))
        #expect(prefix.guestInstructionCount == 1 && state.rip == 0x1003)
        #expect(state.floatingPoint == initial.floatingPoint && state.registers.rcx == 1)
        let atMMX = state
        #expect(try executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 2, state: &state, memory: memory) == nil)
        #expect(state == atMMX)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: .deviceNotAvailable, vector: 7, instructionPointer: 0x1003)))
        #expect(state == atMMX)
        state.control.cr0 &= ~UInt64(8)
        try retire(mmx, state: &state, memory: memory)
        let afterMMX = state
        let suffix = try #require(executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory))
        #expect(suffix.guestInstructionCount == 1 && state.rip == 0x1009)
        #expect(state.registers.rcx == 1 && state.registers.rdx == 1)
        #expect(state.floatingPoint == afterMMX.floatingPoint)
        #expect(state.floatingPoint.x87TagWord == 0 && state.floatingPoint.x87StatusWord & 0x3800 == 0)
        #expect(memory.dataAccesses == 0)
      }
    #endif
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func state(mode: DoryX86ExecutionMode = .long64, top: UInt16) throws -> DoryX86ArchitecturalState {
    let registers = try (0..<8).map { register in
      try DoryX86RegisterBytes(bytes: (0..<10).map { UInt8(truncatingIfNeeded: 0x61 + register * 29 + $0 * 37) },
        expectedByteCount: 10)
    }
    let vectors = try (0..<16).map { register in
      try DoryX86RegisterBytes(bytes: (0..<32).map { UInt8(truncatingIfNeeded: register * 19 + $0) },
        expectedByteCount: 32)
    }
    let fp = try DoryX86FloatingPointState(x87: registers, ymm: vectors,
      x87ControlWord: 0x037F, x87StatusWord: 0xC755 | (top << 11), x87TagWord: 0x1234,
      mxcsr: 0x1F85, mxcsrMask: 0xFFFF)
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0x89ABCDEF, rbx: 0x4000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow], cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31, cr2: 0xAB00, cr4: 1 << 9), floatingPoint: fp)
  }

  private func retire(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    memory: MMXEffectMemory, mode: DoryX86ExecutionMode = .long64) throws {
    let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: mode)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
  }

  private func integer(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}

private final class MMXEffectMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let failData: Bool
  private(set) var data = [UInt8](repeating: 0xA5, count: 64)
  private(set) var dataAccesses = 0
  private(set) var writes = 0
  init(code: [UInt8], failData: Bool = false) { self.code = code; self.failData = failData }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    guard !failData, address == 0x4000, (1...64).contains(byteCount) else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
    }
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    guard !failData, address == 0x4000, (1...64).contains(byteCount) else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
    }
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validateRead(at: address, byteCount: byteCount)
    return Array(data.prefix(byteCount))
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
    data.replaceSubrange(0..<bytes.count, with: bytes)
    writes += 1
  }
  func synchronize() {}
}
