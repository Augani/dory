import Foundation
import Testing

@testable import DoryDBTX86

// A03.4 gap-list decisions for RDRAND/RDSEED. The decoder must recognize the
// 0F C7 /6 and /7 register forms rather than rejecting them as invalid
// CMPXCHG8B/16B encodings. No profile advertises these features until a real
// entropy source is wired into the guest, so the interpreter faults with #UD
// before any data access. Intel SDM Vol. 2B RDRAND/RDSEED pp. 4-729–4-736.
@Suite struct DoryX86EntropyReadTests {
  @Test func decoderRecognizesRdrandRegisterFormsAcrossWidths() throws {
    let decoder = DoryX86Decoder()
    #expect(try decoder.decode([0x0F, 0xC7, 0xF0], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .doubleword), source: .rdrand))
    #expect(try decoder.decode([0x66, 0x0F, 0xC7, 0xF0], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .word), source: .rdrand))
    #expect(try decoder.decode([0x48, 0x0F, 0xC7, 0xF0], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .quadword), source: .rdrand))
    #expect(try decoder.decode([0x4D, 0x0F, 0xC7, 0xF1], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.r9, width: .quadword), source: .rdrand))
  }

  @Test func decoderRecognizesRdseedRegisterFormsAcrossWidths() throws {
    let decoder = DoryX86Decoder()
    #expect(try decoder.decode([0x0F, 0xC7, 0xF8], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .doubleword), source: .rdseed))
    #expect(try decoder.decode([0x66, 0x0F, 0xC7, 0xF8], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .word), source: .rdseed))
    #expect(try decoder.decode([0x48, 0x0F, 0xC7, 0xF8], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.rax, width: .quadword), source: .rdseed))
    #expect(try decoder.decode([0x4D, 0x0F, 0xC7, 0xF9], at: 0x1000, mode: .long64).operation
      == .randomRead(
        destination: .register(.r9, width: .quadword), source: .rdseed))
  }

  @Test func cmpxchg8bMemoryFormStillDecodesAfterRdrandRdseedSplit() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode(
      [0x0F, 0xC7, 0x08], at: 0x1000, mode: .long64)
    guard case .compareExchangePair(let operand, let doubleQuadword) = instruction.operation else {
      Issue.record("CMPXCHG8B memory form was displaced by the RDRAND/RDSEED split")
      return
    }
    #expect(operand.base == .rax)
    #expect(!doubleQuadword)
  }

  @Test func unrecognizedGroupFormsAreInvalidEncodings() throws {
    let decoder = DoryX86Decoder()
    for group in [0, 2, 3, 4, 5] {
      let modRM = UInt8(0xC0 | (group << 3))
      #expect(throws: DoryX86DecodeError.self) {
        try decoder.decode([0x0F, 0xC7, modRM], at: 0x1000, mode: .long64)
      }
    }
  }

  @Test func memoryOperandFormsAreInvalidEncodings() throws {
    let decoder = DoryX86Decoder()
    // 0F C7 /6 with a memory operand (ModRM 0x30 → [rax], /6) is reserved.
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode([0x0F, 0xC7, 0x30], at: 0x1000, mode: .long64)
    }
    // 0F C7 /7 with a memory operand (ModRM 0x38 → [rax], /7) is reserved.
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode([0x0F, 0xC7, 0x38], at: 0x1000, mode: .long64)
    }
  }

  @Test func unadvertisedFeatureFaultsWithUDBeforeAnyAccess() throws {
    let memory = EntropyReadMemory(code: [0x0F, 0xC7, 0xF0])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xDEAD_BEEF_DEAD_BEEF), rip: 0x1000)
    let initial = state
    #expect(DoryX86Interpreter(profile: .compatibleV1).step(
      state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(state == initial)
    #expect(memory.dataReads.isEmpty)
  }

  @Test func unadvertisedRdseedFaultsWithUDBeforeAnyAccess() throws {
    let memory = EntropyReadMemory(code: [0x0F, 0xC7, 0xF8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xDEAD_BEEF_DEAD_BEEF), rip: 0x1000)
    let initial = state
    #expect(DoryX86Interpreter(profile: .compatibleV1).step(
      state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(state == initial)
    #expect(memory.dataReads.isEmpty)
  }

  @Test func noProfileAdvertisesRdrandOrRdseedByDefault() throws {
    #expect(!DoryX86CPUProfile.compatibleV1.supports(.rdrand))
    #expect(!DoryX86CPUProfile.compatibleV1.supports(.rdseed))
    #expect(!DoryX86CPUProfile.intelCompatibleV1.supports(.rdrand))
    #expect(!DoryX86CPUProfile.intelCompatibleV1.supports(.rdseed))
    let instruction = try DoryX86Decoder().decode(
      [0x0F, 0xC7, 0xF0], at: 0x1000, mode: .long64)
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: .intelCompatibleV1))
  }

  @Test func requestedRdrandRemainsUnavailableWithoutAnEntropyImplementation() throws {
    let profile = rdrandProfile
    let instruction = try DoryX86Decoder().decode(
      [0x0F, 0xC7, 0xF0], at: 0x1000, mode: .long64)
    #expect(!profile.supports(.rdrand))
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile))
    #expect(profile.cpuid(leaf: 1).ecx & (1 << 30) == 0)
  }

  @Test func requestedRdseedRemainsUnavailableWithoutAnEntropyImplementation() throws {
    let profile = rdseedProfile
    let instruction = try DoryX86Decoder().decode(
      [0x0F, 0xC7, 0xF8], at: 0x1000, mode: .long64)
    #expect(!profile.supports(.rdseed))
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile))
    #expect(profile.cpuid(leaf: 7).ebx & (1 << 18) == 0)
  }

  @Test func entropyRegisterWidthFollowsTheExecutionMode() throws {
    let decoder = DoryX86Decoder()
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      let defaultsToWord = mode == .real16 || mode == .protected16
      for (modRM, source): (UInt8, DoryX86EntropySource) in [(0xF0, .rdrand), (0xF8, .rdseed)] {
        for override in [false, true] {
          let bytes: [UInt8] = (override ? [0x66] : []) + [0x0F, 0xC7, modRM]
          let width: DoryX86OperandWidth = defaultsToWord != override ? .word : .doubleword
          #expect(try decoder.decode(bytes, at: 0x1000, mode: mode).operation == .randomRead(
            destination: .register(.rax, width: width), source: source))
        }
      }
    }
  }

  @Test func repeatPrefixedGroupNineFormsAreNotMisdecodedAsEntropyInstructions() throws {
    for prefix: UInt8 in [0xF2, 0xF3] {
      for modRM: UInt8 in [0xF0, 0xF8] {
        // F3 0F C7 /7 is RDPID, which this decoder does not implement.
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode([prefix, 0x0F, 0xC7, modRM], at: 0x1000, mode: .long64)
        }
      }
    }
  }

  @Test func persistedEntropyRequestsRemainUnavailable() throws {
    let base = DoryX86CPUProfile.compatibleV1
    let requested = DoryX86CPUProfile(
      identifier: "test.persisted.entropy",
      features: base.features.union([.rdrand, .rdseed]),
      physicalAddressBits: base.physicalAddressBits,
      linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz,
      allowingUnqualifiedSIMDAndExtendedState: true)
    let decoded = try JSONDecoder().decode(
      DoryX86CPUProfile.self, from: JSONEncoder().encode(requested))
    #expect(!decoded.supports(.rdrand))
    #expect(!decoded.supports(.rdseed))
  }

  @Test func bothNativeTiersDeclineAtTheExactInstructionBoundary() throws {
    let rdrand: [UInt8] = [0x0F, 0xC7, 0xF0]
    let block = try DoryX86IRTranslator().translate(rdrand, at: 0x1000, mode: .long64)
    #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: rdrand)])
    #expect(block.terminator == .exit(.interpreter, resumeAt: 0x1000))
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      #expect(DoryARM64BaselineEmitter().compile(block, tier: tier).tier == .interpreterFallback)
    }
  }

  private var rdrandProfile: DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(
      identifier: "test.a03-rdrand",
      features: base.features.union([.rdrand]),
      physicalAddressBits: base.physicalAddressBits,
      linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz,
      identity: base.identity)
  }

  private var rdseedProfile: DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(
      identifier: "test.a03-rdseed",
      features: base.features.union([.rdseed]),
      physicalAddressBits: base.physicalAddressBits,
      linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz,
      identity: base.identity)
  }
}

private final class EntropyReadMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataReads: [(address: UInt64, byteCount: Int)] = []

  init(code: [UInt8]) {
    self.code = code
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReads.append((address, byteCount))
    return Array(repeating: 0, count: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {}
  func write(at address: UInt64, bytes: [UInt8]) throws {}
  func validateWrite(at address: UInt64, byteCount: Int) throws {}
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try read(at: address, byteCount: byteCount)
  }
  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 { 0 }
  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {}
  func synchronize() {}
}
