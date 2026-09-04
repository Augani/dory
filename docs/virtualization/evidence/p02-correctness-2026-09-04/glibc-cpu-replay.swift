

@testable import DoryDBTX86

// Reduced from the actual glibc 2.39 loader used by the P02 kernel-B probe.
// ELF SHA256: 1cd555ac46b7887edeaf3c42aac5408c8135e52f6b37870da2cf82d5fe14e829.
// The executable PT_LOAD has equal file/virtual offsets, starting at 0x1000.
// These unmodified instruction slices retain their original RIP-relative operands
// and branch destinations. No external loader or guest distribution is needed.
// Corresponding upstream source (LGPL-2.1-or-later):
// https://github.com/bminor/glibc/blob/glibc-2.39/sysdeps/x86/cpu-features.c
// get_common_indices queries CPUID.1 only with a nonnull family pointer; the
// arch_kind_other path supplies NULL. update_active then computes ISA level zero.
struct DoryX86GlibcCPUDetectionTests {
  func existingV1VendorSkipsLeafOneAndProducesZeroISALevel() throws {
    for tier in tiers {
      let memory = try fixture()
      var state = try initialState(rip: 0x19616)
      let dispatch = try replay(state: &state, memory: memory, tier: tier, until: 0x19758)
      requireTrue(dispatch.queries == [.init(0, 0), .init(7, 0), .init(7, 1), .init(0xD, 1)])
      requireTrue(dispatch.visited.contains(0x1A89E))
      requireTrue(dispatch.visited.contains(0x19642))
      requireTrue(try memory.readScalar(at: 0x37B30, byteCount: 4) == 0)
      requireTrue(try memory.readScalar(at: 0x37B2C, byteCount: 4) == 0)
      // Enter the actual update_active body at the call destination. Stop after
      // it stores isa_1, before the unrelated epilogue/caller's tuning policy.
      state.rip = 0x18EF0
      let update = try replay(state: &state, memory: memory, tier: tier, until: 0x190CA)
      requireTrue(update.queries.isEmpty)
      requireTrue(try memory.readScalar(at: 0x37B40, byteCount: 4) == 0)
      requireTrue(try memory.readScalar(at: 0x37C68, byteCount: 4) == 0)
      if tier != nil { requireTrue(dispatch.nativeInstructions + update.nativeInstructions > 0) }
      // Preserve this already published guest identity; a future compatible
      // identity must have its own profile version rather than changing v1.
      let leaf = DoryX86CPUProfile.compatibleV1.cpuid(leaf: 1)
      requireTrue(leaf.edx & baselineMask == baselineMask)
    }
  }

  func theSameAdvertisedBitsPropagateAndPassTheActualBaselineCheck() throws {
    for tier in tiers {
      let memory = try fixture()
      let leaf = DoryX86CPUProfile.compatibleV1.cpuid(leaf: 1)
      try memory.writeScalar(at: 0x37B28, value: UInt64(leaf.eax), byteCount: 4)
      try memory.writeScalar(at: 0x37B2C, value: UInt64(leaf.ecx), byteCount: 4)
      try memory.writeScalar(at: 0x37B30, value: UInt64(leaf.edx), byteCount: 4)
      var state = try initialState(rip: 0x18EF0)
      let update = try replay(state: &state, memory: memory, tier: tier, until: 0x190CA)
      requireTrue(update.visited.contains(0x190BB)) // TEST CH,0x81 checks CX8 and CMOV.
      requireTrue(update.visited.contains(0x192E0)) // Raw FPU, then MMX/FXSR/SSE/SSE2.
      requireTrue(try memory.readScalar(at: 0x37B40, byteCount: 4)
        == UInt64(leaf.edx & 0x1788_8110))
      requireTrue(try memory.readScalar(at: 0x37C68, byteCount: 4) == 1)
      if tier != nil { requireTrue(update.nativeInstructions > 0) }
    }
  }

  func intelVendorTupleSelectsTheFamilyAwareBranchWithoutChangingFeatureBits() throws {
    let memory = try fixture()
    // A controlled CPUID.0 result at the instruction after CPUID proves the
    // dispatch dependency; this does not modify any production profile.
    var state = try initialState(rip: 0x19618)
    state.registers.rax = UInt64(DoryX86CPUProfile.maximumBasicCPUIDLeaf)
    state.registers.rbx = 0x756E_6547
    state.registers.rdx = 0x4965_6E69
    state.registers.rcx = 0x6C65_746E
    let result = try replay(state: &state, memory: memory, tier: nil, until: 0x1A3F8)
    requireTrue(!result.visited.contains(0x19642))
    requireTrue(result.queries.isEmpty)
    requireTrue(try memory.readScalar(at: 0x37B30, byteCount: 4) == 0)
  }

  private let baselineMask: UInt32 = (1 << 0) | (1 << 8) | (1 << 15)
    | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 26)

  private var tiers: [DoryARM64JITOptimization?] {
    #if arch(arm64)
      [nil, .baseline, .optimizing]
    #else
      [nil]
    #endif
  }

  private struct Query: Equatable {
    let leaf: UInt32
    let subleaf: UInt32
    init(_ leaf: UInt32, _ subleaf: UInt32) { self.leaf = leaf; self.subleaf = subleaf }
  }

  private struct Replay {
    var queries: [Query] = []
    var visited: Set<UInt64> = []
    var nativeInstructions = 0
  }

  private func replay(state: inout DoryX86ArchitecturalState, memory: DoryX86ByteArrayMemory,
    tier: DoryARM64JITOptimization?, until stop: UInt64) throws -> Replay {
    let executor = try tier.map { try DoryARM64BaselineExecutor(
      maximumCodeBytes: 65536, optimization: $0) }
    var result = Replay()
    for _ in 0..<400 {
      if state.rip == stop { return result }
      let rip = state.rip
      let chunk = try requireValue(chunks.first { rip >= $0.0 && rip < $0.0 + UInt64($0.1.count) })
      let count = min(15, Int(chunk.0 + UInt64(chunk.1.count) - rip))
      let bytes = try memory.instructionBytes(at: rip, maximumCount: count)
      let decoded = try DoryX86Decoder().decode(bytes, at: rip, mode: .long64)
      result.visited.insert(rip)
      if decoded.operation == .cpuid {
        result.queries.append(.init(UInt32(truncatingIfNeeded: state.registers.rax),
          UInt32(truncatingIfNeeded: state.registers.rcx)))
      }
      // One instruction per native entry retains exact observation of CPUID
      // requests and TEST CH fallback while still exercising each lowering tier.
      if let executor, let summary = try executor.executeSummary(
        byteProvider: { _ in bytes }, at: rip, mode: .long64, addressSpaceID: 0,
        maximumInstructions: 1,
        state: &state, memory: memory) {
        requireTrue(summary.guestInstructionCount == 1)
        result.nativeInstructions += Int(summary.guestInstructionCount)
      } else {
        requireTrue(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
      }
    }
    fatalError("glibc fragment exceeded the bounded replay instruction budget")
    return result
  }

  private func initialState(rip: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rsp: 0x3F000), rip: rip,
      cs: .init(attributes: 0xA09B, limit: .max), control: .init(cr0: 0x13))
  }

  private func fixture() throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x40000)
    for (address, bytes) in chunks { try memory.write(at: address, bytes: bytes) }
    return memory
  }

  private var chunks: [(UInt64, [UInt8])] {
    Self.hexChunks.map { address, hex in
      (address, hex.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! })
    }
  }

  private static let hexChunks: [(UInt64, String)] = [
    (0x19616, """
      0f a2 89 05 f6 e4 01 00 81 fb 47 65 6e 75 0f 85 76 01 00 00 81 f9 6e 74
      65 6c 0f 85 6a 01 00 00 81 fa 69 6e 65 49 0f 84 b6 0d 00 00 83 3d cb e4
      01 00 06 0f 8e c9 00 00 00 41 b8 07 00 00 00 31 f6 44 89 c0 89 f1 0f a2
      bf 01 00 00 00 89 05 db e4 01 00 44 89 c0 89 0d da e4 01 00 89 f9 89 1d
      ce e4 01 00 89 15 d0 e4 01 00 0f a2 83 3d 8b e4 01 00 0c 89 05 55 e5 01
      00 89 1d 53 e5 01 00 89 0d 51 e5 01 00 89 15 4f e5 01 00 7e 75 b8 0d 00
      00 00 89 f9 0f a2 83 3d 61 e4 01 00 13 89 05 cb e4 01 00 89 1d c9 e4 01
      00 89 0d c7 e4 01 00 89 15 c5 e4 01 00 7e 4b b8 14 00 00 00 89 f1 0f a2
      83 3d 37 e4 01 00 18 89 05 41 e5 01 00 89 1d 3f e5 01 00 89 0d 3d e5 01
      00 89 15 3b e5 01 00 7e 21 b8 19 00 00 00 89 f1 0f a2 89 05 fe e4 01 00
      89 1d fc e4 01 00 89 0d fa e4 01 00 89 15 f8 e4 01 00 48 83 3d a0 e3 01
      00 00 75 36 83 3d eb e3 01 00 0c 0f 8e 11 09 00 00 f6 05 f9 e3 01 00 08
      0f 84 04 09 00 00 b8 0d 00 00 00 31 c9 0f a2 8d 83 04 02 00 00 48 89 05
      6e e3 01 00 66 0f 1f 44 00 00
      """),
    (0x197A0, """
      81 fb 41 75 74 68 0f 85 cc 08 00 00 81 f9 63 41 4d 44 0f 85 c0 08 00 00
      81 fa 65 6e 74 69 0f 85 7e fe ff ff
      """),
    (0x1A078, """
      81 fb 48 79 67 6f 75 19 81 f9 75 69 6e 65 75 11 81 fa 6e 47 65 6e 0f 85
      ae f5 ff ff e9 2b f7 ff ff 81 fb 43 65 6e 74 0f 85 f9 07 00 00 81 f9 61
      75 6c 73 0f 85 ed 07 00 00 81 fa 61 75 72 48 0f 85 85 f5 ff ff
      """),
    (0x1A89E, """
      81 fb 20 20 53 68 40 0f 94 c6 81 f9 61 69 20 20 0f 94 c0 40 84 c6 0f 84
      88 ed ff ff 81 fa 61 6e 67 68 0f 84 f7 f7 ff ff e9 77 ed ff ff
      """),
    (0x1A040, """
      48 c7 05 75 da 01 00 00 08 00 00 e9 08 f7 ff ff
      """),
    (0x18EF0, """
      55 48 89 e5 41 57 41 56 41 55 41 54 53 48 81 ec b0 00 00 00 8b 3d 22 ec
      01 00 44 8b 3d 1f ec 01 00 44 8b 35 30 ec 01 00 44 8b 15 2d ec 01 00 41
      89 fc 89 fa 44 8b 05 25 ec 01 00 41 89 f9 41 81 e4 00 00 00 08 44 89 f8
      44 89 f6 44 89 d3 81 e2 03 22 d8 02 0b 15 f2 eb 01 00 41 81 e1 00 00 00
      40 25 10 81 88 17 44 09 e2 0b 05 e1 eb 01 00 81 e6 18 03 8c 21 81 e3 31
      01 40 1a 41 09 d1 44 89 c2 0b 35 e1 eb 01 00 0b 1d df eb 01 00 81 e2 10
      48 01 00 0b 15 d7 eb 01 00 89 05 b1 eb 01 00 89 95 c0 fe ff ff 89 15 c5
      eb 01 00 89 35 b7 eb 01 00 44 89 0d 94 eb 01 00 89 1d ae eb 01 00 8b 0d
      b8 eb 01 00 44 8b 1d 35 ec 01 00 89 ca 89 8d c8 fe ff ff 8b 0d 1b ec 01
      00 81 e2 61 01 20 00 0b 15 a7 eb 01 00 89 95 c4 fe ff ff 89 15 9b eb 01
      00 8b 15 89 eb 01 00 89 8d cc fe ff ff 81 e2 00 00 00 08 09 15 87 eb 01
      00 8b 15 c9 eb 01 00 81 e2 00 02 00 00 09 15 cd eb 01 00 89 ca 8b 0d 15
      ec 01 00 81 e2 88 1c 00 00 0b 15 d5 eb 01 00 89 15 cf eb 01 00 41 89 d5
      44 89 da 83 e1 10 81 e2 00 40 00 00 0b 15 c6 eb 01 00 09 0d f8 eb 01 00
      89 15 ba eb 01 00 41 f7 c0 00 08 00 00 75 11 44 89 f1 81 e1 00 08 00 00
      09 ce 89 35 f8 ea 01 00 45 85 e4 75 7b 44 89 d2 83 e2 10 85 d2 74 07 83
      0d e6 ea 01 00 08 8b 15 8c eb 01 00 f6 c2 01 74 20 83 e2 04 0b 15 8e eb
      01 00 41 81 e2 00 00 80 00 44 09 15 c4 ea 01 00 83 ca 01 89 15 77 eb 01
      00 f6 05 28 ed 01 00 02 74 0b 41 83 e6 01 44 09 35 a3 ea 01 00 89 c1 31
      d2 f7 d1 f6 c5 81 0f 84 1c 02 00 00 89 15 9e eb 01 00
      """),
    (0x192E0, """
      44 89 fa 83 e2 01 0f 84 d8 fd ff ff 89 c8 a9 00 00 80 07 0f 84 6f 01 00
      00 31 d2 e9 c4 fd ff ff
      """),
    (0x19468, """
      41 f7 c1 00 20 00 00 0f 84 4f fc ff ff 8b 05 01 e7 01 00 89 c1 83 e1 01
      0f 84 3e fc ff ff
      """),
  ]
}

private func requireTrue(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
  precondition(condition, "replay expectation failed", file: file, line: line)
}
private func requireValue<T>(_ value: T?) throws -> T {
  guard let value else { fatalError("missing replay value") }; return value
}
let suite = DoryX86GlibcCPUDetectionTests()
try suite.existingV1VendorSkipsLeafOneAndProducesZeroISALevel()
print("PASS actual Dory-v1 vendor dispatch and zero ISA level, interpreter/baseline/optimizing")
try suite.theSameAdvertisedBitsPropagateAndPassTheActualBaselineCheck()
print("PASS actual active-feature propagation and baseline check, interpreter/baseline/optimizing")
try suite.intelVendorTupleSelectsTheFamilyAwareBranchWithoutChangingFeatureBits()
print("PASS controlled Intel CPUID.0 tuple selects family-aware branch")
