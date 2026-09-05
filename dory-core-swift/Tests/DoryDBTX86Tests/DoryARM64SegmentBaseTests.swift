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
            let conservative = DoryARM64BaselineEmitter().compile(block, tier: tier)
            #expect(conservative.tier == .interpreterFallback)
            #expect(conservative.exitCode == .interpreter)

            let longMode = DoryARM64BaselineEmitter().compile(
              block, tier: tier, executionMode: .long64)
            #expect(longMode.tier == tier)
            #expect(longMode.exitCode == .dispatch)
          }
        }
      }
    }
  }

  @Test func longModeFSAndGSLoadsStoresAndReadModifyWritesUseSegmentBase() throws {
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
              let result = try #require(DoryARM64BaselineExecutor(
                maximumCodeBytes: 16384, optimization: optimization
              ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
                maximumInstructions: 1, state: &state, memory: memory))
              #expect(result.block.tier.rawValue == optimization.rawValue)
              #expect(result.exitCode == .dispatch)
              #expect(memory.dataAccessCount > 0)
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

  @Test func gsRIPRelativePerCPUOffsetReadExecutesNativelyAtRelocatedAddress() throws {
    #if arch(arm64)
      // add rbx,gs:[rip+0xf8]: the linked slot at 0x100 differs from its per-CPU copy.
      let bytes: [UInt8] = [0x65, 0x48, 0x03, 0x1D, 0xF8, 0, 0, 0]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let nativeMemory = try SegmentRecordingMemory()
        let interpretedMemory = try SegmentRecordingMemory()
        for memory in [nativeMemory, interpretedMemory] {
          try memory.backing.write(at: 0, bytes: bytes)
          try memory.backing.writeScalar(at: 0x100, value: 0, byteCount: 8)
          try memory.backing.writeScalar(at: 0x2100, value: 0x1000, byteCount: 8)
        }
        var native = try makeState()
        var interpreted = native
        let result = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16384, optimization: optimization
        ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &native, memory: nativeMemory))
        let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &interpreted, memory: interpretedMemory, mode: .long64)
          == .retired(decoded))
        #expect(result.block.tier.rawValue == optimization.rawValue)
        #expect(result.block.requiresMemoryCallbacks)
        #expect(native == interpreted)
        #expect(native.registers.rbx == 0x1100)
        #expect(native.rip == UInt64(bytes.count))
      }
    #endif
  }

  @Test func longModeGSByteCompareUsesSegmentBaseInNativePath() throws {
    #if arch(arm64)
      // cmp byte ptr gs:[rip+0xf8],0: the linked slot at 0x100 differs from per-CPU storage.
      let bytes: [UInt8] = [0x65, 0x80, 0x3D, 0xF8, 0, 0, 0, 0]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let nativeMemory = try SegmentRecordingMemory()
        let interpretedMemory = try SegmentRecordingMemory()
        for memory in [nativeMemory, interpretedMemory] {
          try memory.backing.write(at: 0, bytes: bytes)
          try memory.backing.write(at: 0x100, bytes: [0])
          try memory.backing.write(at: 0x2100, bytes: [0x80])
        }
        var native = try makeState()
        var interpreted = native
        let result = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024, optimization: optimization
        ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &native, memory: nativeMemory))
        let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &interpreted, memory: interpretedMemory,
          mode: .long64) == .retired(decoded))
        #expect(result.block.tier.rawValue == optimization.rawValue)
        #expect(result.block.requiresMemoryCallbacks)
        #expect(native == interpreted)
        #expect(native.rflags.contains(.sign))
        #expect(!native.rflags.contains(.carry))
        #expect(!native.rflags.contains(.overflow))
        #expect(!native.rflags.contains(.zero))
        #expect(nativeMemory.dataAccessCount > 0)
      }
    #endif
  }

  @Test func nativePrefixCanCrossLongModeSegmentAccess() throws {
    #if arch(arm64)
      // mov eax,7; mov rax,gs:[rbx]
      let prefix: [UInt8] = [0xB8, 7, 0, 0, 0]
      let segmented: [UInt8] = [0x65, 0x48, 0x8B, 0x03]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = try SegmentRecordingMemory()
        var state = try makeState()
        state.registers.rax = 99
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        try memory.backing.writeScalar(at: 0x2100, value: 0x1234, byteCount: 8)
        let first = try #require(executor.execute(bytes: prefix + segmented, at: 0,
          mode: .long64, addressSpaceID: 0, maximumInstructions: 2, state: &state, memory: memory))
        #expect(first.block.tier.rawValue == optimization.rawValue)
        #expect(first.block.guestInstructionCount == 2)
        #expect(first.exitCode == .dispatch)
        #expect(state.rip == UInt64((prefix + segmented).count))
        #expect(state.registers.rax == 0x1234)
        #expect(memory.dataAccessCount > 0)
      }
    #endif
  }


  @Test func longModeLEAIgnoresFSAndGSSegmentBasesInNativePath() throws {
    #if arch(arm64)
      struct LEACase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let expectedRAX: UInt64
      }
      let cases = [
        LEACase(
          bytes: [0x48, 0x8D, 0x83, 0x34, 0x12, 0, 0],
          registers: .init(rbx: 0x100),
          expectedRAX: 0x1334
        ),
        LEACase(
          bytes: [0x67, 0x8D, 0x83, 0xFC, 0xFF, 0xFF, 0xFF],
          registers: .init(rbx: 2),
          expectedRAX: 0xFFFF_FFFE
        ),
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for prefix: UInt8 in [0x64, 0x65] {
          for testCase in cases {
            let bytes = [prefix] + testCase.bytes
            let memory = try DoryX86ByteArrayMemory(bytes: bytes)
            var state = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: 0,
              rflags: [.reservedOne, .carry, .overflow],
              cs: .init(attributes: 0xA09B, limit: .max),
              fs: .init(base: 0x1000),
              gs: .init(base: 0x2000)
            )
            let execution = try #require(DoryARM64BaselineExecutor(
              maximumCodeBytes: 16 * 1024, optimization: optimization
            ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &state, memory: memory))
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(!execution.block.requiresMemoryCallbacks)
            #expect(state.registers.rax == testCase.expectedRAX)
            #expect(state.rip == UInt64(bytes.count))
            #expect(state.rflags == [.reservedOne, .carry, .overflow])
          }
        }
      }
    #endif
  }

  @Test func faultingFSAndGSMemoryAccessesDeclineBeforePublishingNativeState() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for prefix: UInt8 in [0x64, 0x65] {
          let bytes: [UInt8] = [prefix, 0x48, 0x8B, 0x03]  // mov rax,fs/gs:[rbx]
          let memory = try SegmentRecordingMemory()
          try memory.backing.write(at: 0, bytes: bytes)
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: 0xCAFE, rbx: 0x100),
            rip: 0,
            rflags: [.reservedOne, .carry],
            cs: .init(attributes: 0xA09B, limit: .max),
            fs: .init(base: 0x4000),
            gs: .init(base: 0x5000)
          )
          let original = state
          let result = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization
          ).executeChainedSummary(
            byteProvider: { address, maximumCount in
              try memory.instructionBytes(at: address, maximumCount: maximumCount)
            },
            at: 0,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state,
            memory: memory
          )
          #expect(result == nil)
          #expect(state == original)
          #expect(memory.dataAccessCount > 0)

          guard case .exception(let fault) = DoryX86Interpreter().step(
            state: &state, memory: memory, mode: .long64)
          else {
            Issue.record("expected interpreter fallback to publish the precise FS/GS fault")
            continue
          }
          #expect(fault.instructionPointer == 0)
          #expect(state.registers.rax == original.registers.rax)
        }
      }
    #endif
  }

  @Test func protectedModeFSAndGSMemoryOperandsStillFallBackBeforeSegmentValidation() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for prefix: UInt8 in [0x64, 0x65] {
          let bytes: [UInt8] = [prefix, 0x8B, 0x03]  // mov eax,fs/gs:[ebx]
          let memory = try SegmentRecordingMemory()
          try memory.backing.write(at: 0, bytes: bytes)
          var state = try makeState()
          let original = state
          let result = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16384, optimization: optimization
          ).execute(bytes: bytes, at: 0, mode: .protected32, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory)
          #expect(result == nil)
          #expect(state == original)
          #expect(memory.dataAccessCount == 0)
        }
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
