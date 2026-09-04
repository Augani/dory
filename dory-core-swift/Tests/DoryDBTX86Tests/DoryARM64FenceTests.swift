import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64FenceTests {
  // LFENCE, MFENCE and SFENCE register encodings. Feature qualification is separate;
  // these checks establish that a decoded fence retains its existing memory-ordering effect.
  private let fences: [[UInt8]] = [[0x0F, 0xAE, 0xE8], [0x0F, 0xAE, 0xF0], [0x0F, 0xAE, 0xF8]]

  @Test func translationPreservesEveryFenceAsAnExactInterpreterBoundary() throws {
    for fence in fences {
      let translator = DoryX86IRTranslator()
      let prefix = try translator.translate(
        [0x48, 0xFF, 0xC1] + fence + [0x48, 0xFF, 0xC2], at: 0x1000, mode: .long64)
      #expect(prefix.guestInstructionCount == 1)
      #expect(prefix.guestByteCount == 3)
      #expect(prefix.terminator == .next(0x1003))

      let boundary = try translator.translate(fence + [0x48, 0xFF, 0xC2], at: 0x1003, mode: .long64)
      #expect(boundary.guestInstructionCount == 1)
      #expect(boundary.guestByteCount == 3)
      #expect(boundary.statements == [.helper(identifier: "x86.interpret.one", payload: fence)])
      #expect(boundary.terminator == .exit(.interpreter, resumeAt: 0x1003))
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        #expect(DoryARM64BaselineEmitter().compile(prefix, tier: tier).tier == tier)
        #expect(DoryARM64BaselineEmitter().compile(boundary, tier: tier).tier == .interpreterFallback)
      }
    }
  }

  @Test func fenceAtEntryDeclinesWithoutMutationThenInvokesOrderingExactlyOnce() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for fence in fences {
          let memory = try FenceObservingMemory()
          try memory.backing.write(at: 0x1000, bytes: fence + [0x48, 0xFF, 0xC1])
          var state = try DoryX86ArchitecturalState(registers: .init(rcx: 9), rip: 0x1000)
          let initial = state
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096, optimization: optimization)
          #expect(try executor.executeSummary(
            byteProvider: { try memory.instructionBytes(at: 0x1000, maximumCount: $0) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
            state: &state, memory: memory) == nil)
          #expect(state == initial)
          #expect(memory.events.isEmpty)
          let decoded = try DoryX86Decoder().decode(fence, at: initial.rip, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
          var expected = initial
          expected.rip += 3
          #expect(state == expected)
          #expect(memory.events == [.synchronize])
        }
      }
    #endif
  }

  @Test func coldAndReplayedChainsPublishEachStoreOnceAndOrderTheFollowingLoad() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for fence in fences {
          // Two register-only blocks permit actual hot native-batch replay. The store then
          // publishes once before the fence, and the following load stays after synchronize().
          let bytes: [UInt8] = [
            0x48, 0xFF, 0xC1, 0xEB, 0,  // INC RCX; JMP next
            0x48, 0xFF, 0xC0, 0xEB, 0,  // INC RAX; JMP next
            0x48, 0x89, 0x0B,           // MOV [RBX], RCX
          ] + fence + [
            0x48, 0x8B, 0x13,           // MOV RDX, [RBX]
            0x48, 0xFF, 0xC6,           // INC RSI
          ]
          let initial = try DoryX86ArchitecturalState(registers: .init(rbx: 0x8000), rip: 0x1000)
          let referenceMemory = try FenceObservingMemory()
          try referenceMemory.backing.write(at: 0x1000, bytes: bytes)
          var reference = initial
          for _ in 0..<8 {
            let instruction = try DoryX86Decoder().decode(
              referenceMemory.instructionBytes(at: reference.rip, maximumCount: 15),
              at: reference.rip, mode: .long64)
            #expect(DoryX86Interpreter().step(state: &reference, memory: referenceMemory, mode: .long64)
              == .retired(instruction))
          }
          #expect(referenceMemory.events == [.write(1), .synchronize, .read(1)])

          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          for _ in 0..<2 {
            let memory = try FenceObservingMemory()
            try memory.backing.write(at: 0x1000, bytes: bytes)
            var state = initial
            let prefix = try #require(executor.executeChainedSummary(
              byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
              codeGenerationProvider: { _, _ in 1 },
              at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 32,
              state: &state, memory: memory))
            #expect(prefix.guestInstructionCount == 5)
            #expect(prefix.exitCode == .dispatch)
            #expect(state.rip == 0x100D)
            #expect(state.registers.rax == 1 && state.registers.rcx == 1)
            #expect(state.registers.rdx == 0 && state.registers.rsi == 0)
            #expect(memory.events == [.write(1)])

            // Retrying native entry at this boundary cannot replay the completed prefix.
            let atFence = state
            for _ in 0..<2 {
              #expect(try executor.executeChainedSummary(
                byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
                codeGenerationProvider: { _, _ in 1 },
                at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 32,
                state: &state, memory: memory) == nil)
              #expect(state == atFence)
              #expect(memory.events == [.write(1)])
            }
            let decoded = try DoryX86Decoder().decode(fence, at: state.rip, mode: .long64)
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
            #expect(state.rip == 0x1010)
            #expect(memory.events == [.write(1), .synchronize])

            let suffix = try #require(executor.executeChainedSummary(
              byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
              codeGenerationProvider: { _, _ in 1 },
              at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
              state: &state, memory: memory))
            #expect(suffix.guestInstructionCount == 2)
            #expect(state == reference)
            #expect(memory.events == referenceMemory.events)
            #expect(try memory.backing.readScalar(at: 0x8000, byteCount: 8) == 1)
          }
          #expect(executor.nativeBatchExecutionCount > 0)
        }
      }
    #endif
  }
}

/// Per-test serial observer. Fetch and permission checks do not count as data accesses.
private final class FenceObservingMemory: DoryX86ScalarMemory, @unchecked Sendable {
  enum Event: Equatable { case write(UInt64), synchronize, read(UInt64) }
  let backing: DoryX86ByteArrayMemory
  private(set) var events: [Event] = []

  init() throws { backing = try DoryX86ByteArrayMemory(byteCount: 0x10000) }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    let bytes = try backing.read(at: address, byteCount: byteCount)
    events.append(.read(scalar(bytes)))
    return bytes
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
    events.append(.write(scalar(bytes)))
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    let value = try backing.readScalar(at: address, byteCount: byteCount)
    events.append(.read(value))
    return value
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
    events.append(.write(value))
  }

  func synchronize() {
    backing.synchronize()
    events.append(.synchronize)
  }

  private func scalar(_ bytes: [UInt8]) -> UInt64 {
    bytes.prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}
