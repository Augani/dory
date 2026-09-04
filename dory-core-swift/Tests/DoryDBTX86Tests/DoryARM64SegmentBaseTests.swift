import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64SegmentBaseTests {
  @Test func longModeFSAndGSMemoryOperandsRetainTheirSegmentsInIR() throws {
    for (prefix, segment): (UInt8, String) in [(0x64, "fs"), (0x65, "gs")] {
      for addressPrefix: [UInt8] in [[], [0x67]] {
        for opcode: UInt8 in [0x8B, 0x89, 0x01] {
          let bytes = [prefix] + addressPrefix + [0x48, opcode, 0x03]
          let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
          let statement = try #require(block.statements.first)
          let memoryOperand: DoryIROperand
          switch statement {
          case .copy(let destination, let source):
            memoryOperand = opcode == 0x8B ? source : destination
          case .binary(_, let destination, _, _):
            memoryOperand = destination
          default:
            Issue.record("Expected a memory move or arithmetic statement")
            continue
          }
          guard case .memory(let address, _) = memoryOperand else {
            Issue.record("Expected a memory operand")
            continue
          }
          #expect(address.segment == segment)
          #expect(address.addressWidth == (addressPrefix.isEmpty ? .i64 : .i32))
          for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
            let compiled = DoryARM64BaselineEmitter().compile(block, tier: tier)
            #expect(compiled.tier == .interpreterFallback)
            #expect(compiled.exitCode == .interpreter)
          }
        }
      }
    }
  }

  @Test func fsAndGSLoadsStoresAndReadModifyWritesFallBackWithoutEffects() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (prefix, segmentBase): (UInt8, UInt64) in [(0x64, 0x1000), (0x65, 0x2000)] {
          for addressPrefix: [UInt8] in [[], [0x67]] {
            for opcode: UInt8 in [0x8B, 0x89, 0x01] {
              let bytes = [prefix] + addressPrefix + [0x48, opcode, 0x03]
              let memory = try SegmentRecordingMemory()
              try memory.backing.write(at: 0, bytes: bytes)
              try memory.backing.writeScalar(at: 0x100, value: 0xDEAD, byteCount: 8)
              try memory.backing.writeScalar(at: segmentBase + 0x100, value: 0x20, byteCount: 8)
              var state = try makeState()
              let original = state
              let originalMemory = memory.backing.snapshot()
              let result = try DoryARM64BaselineExecutor(
                maximumCodeBytes: 16384, optimization: optimization
              ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
                maximumInstructions: 1, state: &state, memory: memory)
              #expect(result == nil)
              #expect(state == original)
              #expect(memory.backing.snapshot() == originalMemory)
              #expect(memory.dataAccessCount == 0)

              let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
              #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
                == .retired(decoded))
              #expect(state.rip == UInt64(bytes.count))
              #expect(state.registers.rax == (opcode == 0x8B ? 0x20 : 7))
              #expect(try memory.backing.readScalar(at: 0x100, byteCount: 8) == 0xDEAD)
              let expected: UInt64 = opcode == 0x89 ? 7 : opcode == 0x01 ? 0x27 : 0x20
              #expect(try memory.backing.readScalar(at: segmentBase + 0x100, byteCount: 8) == expected)
            }
          }
        }
      }
    #endif
  }

  @Test func gsRIPRelativePerCPUOffsetReadFallsBackToRelocatedAddress() throws {
    #if arch(arm64)
      // add rbx,gs:[rip+0xf8]: the linked slot at 0x100 differs from its per-CPU copy.
      let bytes: [UInt8] = [0x65, 0x48, 0x03, 0x1D, 0xF8, 0, 0, 0]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = try SegmentRecordingMemory()
        try memory.backing.write(at: 0, bytes: bytes)
        try memory.backing.writeScalar(at: 0x100, value: 0, byteCount: 8)
        try memory.backing.writeScalar(at: 0x2100, value: 0x1000, byteCount: 8)
        var state = try makeState()
        let original = state
        let result = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16384, optimization: optimization
        ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &state, memory: memory)
        #expect(result == nil)
        #expect(state == original)
        #expect(memory.dataAccessCount == 0)
        let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
        #expect(state.registers.rbx == 0x1100)
        #expect(state.rip == UInt64(bytes.count))
      }
    #endif
  }

  @Test func nativePrefixStopsBeforeSegmentAccessAndFallbackDoesNotReplayIt() throws {
    #if arch(arm64)
      // mov eax,7; mov rax,gs:[rbx]
      let prefix: [UInt8] = [0xB8, 7, 0, 0, 0]
      let segmented: [UInt8] = [0x65, 0x48, 0x8B, 0x03]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = try SegmentRecordingMemory()
        var state = try makeState()
        state.registers.rax = 99
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let first = try #require(executor.execute(bytes: prefix + segmented, at: 0,
          mode: .long64, addressSpaceID: 0, maximumInstructions: 2, state: &state, memory: memory))
        #expect(first.block.tier.rawValue == optimization.rawValue)
        #expect(first.block.guestInstructionCount == 1)
        #expect(first.exitCode == .dispatch)
        #expect(state.rip == UInt64(prefix.count))
        #expect(state.registers.rax == 7)
        #expect(memory.dataAccessCount == 0)
        let beforeFallback = state
        let second = try executor.execute(bytes: segmented, at: state.rip,
          mode: .long64, addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory)
        #expect(second == nil)
        #expect(state == beforeFallback)
        #expect(memory.dataAccessCount == 0)
      }
    #endif
  }

  @Test func longModeDSAndSSBasesRemainIgnoredInNativeMemoryOperations() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        // RBX defaults to DS; RBP defaults to SS. Explicit legacy overrides are also ignored.
        for prefix: [UInt8] in [[], [0x3E], [0x36]] {
          for addressing: [UInt8] in [[0x03], [0x45, 0]] {
            for opcode: UInt8 in [0x8B, 0x89, 0x01] {
              let bytes = prefix + [0x48, opcode] + addressing
              let memory = try DoryX86ByteArrayMemory(byteCount: 0x4000)
              try memory.writeScalar(at: 0x100, value: 0x20, byteCount: 8)
              try memory.writeScalar(at: 0x1100, value: 0xDEAD, byteCount: 8)
              try memory.writeScalar(at: 0x2100, value: 0xBEEF, byteCount: 8)
              var state = try makeState()
              let result = try #require(DoryARM64BaselineExecutor(
                maximumCodeBytes: 16384, optimization: optimization
              ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
                maximumInstructions: 1, state: &state, memory: memory))
              #expect(result.block.tier.rawValue == optimization.rawValue)
              #expect(result.exitCode == .dispatch)
              #expect(state.rip == UInt64(bytes.count))
              #expect(state.registers.rax == (opcode == 0x8B ? 0x20 : 7))
              let expected: UInt64 = opcode == 0x89 ? 7 : opcode == 0x01 ? 0x27 : 0x20
              #expect(try memory.readScalar(at: 0x100, byteCount: 8) == expected)
              #expect(try memory.readScalar(at: 0x1100, byteCount: 8) == 0xDEAD)
              #expect(try memory.readScalar(at: 0x2100, byteCount: 8) == 0xBEEF)
            }
          }
        }
      }
    #endif
  }

  private func makeState() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 7, rbx: 0x100, rbp: 0x100), rip: 0,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(attributes: 0xA09B, limit: .max),
      ds: .init(base: 0x1000), fs: .init(base: 0x1000), gs: .init(base: 0x2000),
      ss: .init(base: 0x2000))
  }
}

private final class SegmentRecordingMemory:
  DoryX86ScalarMemory, DoryX86RestartableScalarMemory, @unchecked Sendable
{
  let backing: DoryX86ByteArrayMemory
  private(set) var dataAccessCount = 0

  init() throws {
    backing = try DoryX86ByteArrayMemory(byteCount: 0x4000)
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccessCount += 1
    return try backing.read(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataAccessCount += 1
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccessCount += 1
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    dataAccessCount += 1
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    dataAccessCount += 1
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    dataAccessCount += 1
    return try backing.readScalar(at: address, byteCount: byteCount)
  }
}
