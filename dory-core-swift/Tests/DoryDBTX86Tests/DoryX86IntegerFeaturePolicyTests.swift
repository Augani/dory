import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A CMOVcc pp. 3-159–160, CMPXCHG8B/16B pp. 3-196–198:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// Intel explicitly lists missing CX16 under #GP(0). These are admission tests,
// not qualification of every memory/atomicity or cross-vendor exception rule.
@Suite struct DoryX86IntegerFeaturePolicyTests {
  @Test func allCMOVConditionsAndPairWidthsUseIndependentCPUIDBits() throws {
    for mode in modes {
      for bytes in cmovForms(mode: mode) {
        let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
        #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
        #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: [.cmov])))
        #expect(DoryX86InstructionFeaturePolicy.permits(instruction,
          profile: profile(removing: [.cmpxchg8b, .cmpxchg16b])))
      }
      for (bytes, feature) in pairForms(mode: mode) {
        let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
        #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: [feature])))
        let unrelated: Set<DoryX86Feature> = feature == .cmpxchg8b ? [.cmov, .cmpxchg16b] : [.cmov, .cmpxchg8b]
        #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: unrelated)))
      }
    }
    let noCMOV = profile(removing: [.cmov]).cpuid(leaf: 1)
    #expect(noCMOV.edx & (1 << 15) == 0 && noCMOV.edx & (1 << 8) != 0 && noCMOV.ecx & (1 << 13) != 0)
    let noCX8 = profile(removing: [.cmpxchg8b]).cpuid(leaf: 1)
    #expect(noCX8.edx & (1 << 8) == 0 && noCX8.edx & (1 << 15) != 0 && noCX8.ecx & (1 << 13) != 0)
    let noCX16 = profile(removing: [.cmpxchg16b]).cpuid(leaf: 1)
    #expect(noCX16.ecx & (1 << 13) == 0 && noCX16.edx & (1 << 8) != 0 && noCX16.edx & (1 << 15) != 0)
  }

  @Test func absentFeaturesFaultBeforeOperandsAlignmentAndStateChanges() throws {
    for mode in modes {
      let forms = cmovForms(mode: mode).map { ($0, DoryX86Feature.cmov) } + pairForms(mode: mode)
      for (bytes, feature) in forms {
        for address: UInt64 in [0x8000, 0x8001, 0x0000_8000_0000_0000] {
          let memory = IntegerPolicyMemory(code: bytes)
          var state = try initialState(mode: mode)
          state.registers.rbx = address
          state.registers.rdi = address
          let before = state
          let result = DoryX86Interpreter(profile: profile(removing: [feature])).step(
            state: &state, memory: memory, mode: mode)
          #expect(result == featureFault(feature))
          #expect(state == before)
          #expect(memory.dataAccesses == 0)
        }
      }
    }
  }

  @Test func enabledIndependentFeaturesRetireOnBothSelectedIdentities() throws {
    for base in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
      for doubleQuadword in [false, true] {
        let unrelated: Set<DoryX86Feature> = doubleQuadword ? [.cmov, .cmpxchg8b] : [.cmov, .cmpxchg16b]
        let selected = profile(removing: unrelated, base: base)
        let bytes: [UInt8] = [0xF0] + (doubleQuadword ? [0x48] : []) + [0x0F, 0xC7, 0x0F]
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x9000)
        try memory.write(at: 0x1000, bytes: bytes)
        let old: UInt64 = doubleQuadword ? 0x11 : 0x2200_0000_11
        try memory.writeScalar(at: 0x8000, value: old, byteCount: 8)
        if doubleQuadword { try memory.writeScalar(at: 0x8008, value: 0x22, byteCount: 8) }
        var state = try initialState()
        state.registers.rax = 0x11
        state.registers.rdx = 0x22
        state.registers.rbx = 0x33
        state.registers.rcx = 0x44
        let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
        #expect(DoryX86Interpreter(profile: selected).step(state: &state, memory: memory,
          mode: .long64) == .retired(instruction))
        #expect(state.rflags.contains(.zero))
        #expect(try memory.readScalar(at: 0x8000, byteCount: 8) == (doubleQuadword ? 0x33 : 0x4400_0000_33))
        if doubleQuadword { #expect(try memory.readScalar(at: 0x8008, byteCount: 8) == 0x44) }
      }
      let bytes: [UInt8] = [0x48, 0x0F, 0x45, 0xC3] // CMOVNE RAX,RBX; ZF=0.
      var state = try initialState()
      let instruction = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      #expect(DoryX86Interpreter(profile: profile(removing: [.cmpxchg8b, .cmpxchg16b], base: base))
        .step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
      #expect(state.registers.rax == 0x8000)
    }
  }

  @Test func bothNativeTiersRejectMaskedCMOVBeforeAnyBlockPrefixEffects() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for bytes: [UInt8] in [
          [0x48, 0x0F, 0x45, 0xC3], // Native 64-bit CMOVNE.
          [0x0F, 0x45, 0xC3], // Native 32-bit CMOVNE.
          [0x0F, 0x44, 0xC0], // Same source/destination must not be optimized past admission.
          [0x48, 0xFF, 0xC1, 0x48, 0x0F, 0x45, 0xC3], // Unexecuted INC prefix.
        ] {
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
            profile: profile(removing: [.cmov]), optimization: optimization)
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          var state = try initialState()
          let before = state
          for _ in 0..<3 {
            #expect(try executor.executeSummary(byteProvider: { Array(bytes.prefix($0)) },
              at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
              state: &state, memory: memory) == nil)
            #expect(try executor.executeChainedSummary(byteProvider: { _, count in Array(bytes.prefix(count)) },
              at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
              state: &state, memory: memory) == nil)
            #expect(state == before && memory.snapshot() == bytes)
            #expect(executor.residentBlockCount == 0)
          }
          if bytes.first != 0x48 || bytes[1] != 0xFF {
            #expect(DoryX86Interpreter(profile: profile(removing: [.cmov])).step(
              state: &state, memory: memory, mode: .long64) == featureFault(.cmov))
            #expect(state == before)
          }
        }
      }
    #endif
  }

  @Test func selectedProfilesRetainNativeCMOVOnColdAndCachedEntry() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0xFF, 0xC1, 0x48, 0x0F, 0x45, 0xC3]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for selected in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
            profile: selected, optimization: optimization)
          for _ in 0..<3 {
            var state = try initialState()
            let execution = try executor.executeSummary(byteProvider: { Array(bytes.prefix($0)) },
              at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 2, state: &state)
            let summary = try #require(execution)
            #expect(summary.guestInstructionCount == 2)
            #expect(summary.tier == (optimization == .optimizing ? .optimizing : .baseline))
            #expect(state.rip == 0x1007 && state.registers.rcx == 1 && state.registers.rax == 0x8000)
          }
          #expect(executor.residentBlockCount == 1)
        }
      }
    #endif
  }

  @Test func completedNativeStorePublishesOnceBeforeMaskedIntegerFallback() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (target, feature) in [([UInt8(0x48), 0x0F, 0x45, 0xC3], DoryX86Feature.cmov)] + pairForms(mode: .long64) {
          let bytes: [UInt8] = [0x48, 0xFF, 0x07] + target // INC qword [RDI] forces a block boundary.
          let selected = profile(removing: [feature])
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
            profile: selected, optimization: optimization)
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x9000)
          try memory.write(at: 0x1000, bytes: bytes)
          try memory.writeScalar(at: 0x8000, value: 5, byteCount: 8)
          var state = try initialState()
          let execution = try executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
            state: &state, memory: memory)
          let summary = try #require(execution)
          #expect(summary.guestInstructionCount == 1 && state.rip == 0x1003)
          #expect(try memory.readScalar(at: 0x8000, byteCount: 8) == 6)
          let before = state
          let snapshot = memory.snapshot()
          for _ in 0..<2 {
            #expect(try executor.executeSummary(
              byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
              at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
              state: &state, memory: memory) == nil)
            #expect(DoryX86Interpreter(profile: selected).step(state: &state,
              memory: memory, mode: .long64) == featureFault(feature, rip: 0x1003))
            #expect(state == before && memory.snapshot() == snapshot)
          }
        }
      }
    #endif
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func cmovForms(mode: DoryX86ExecutionMode) -> [[UInt8]] {
    let prefixes: [[UInt8]] = mode == .long64 ? [[], [0x66], [0x48]] : [[], [0x66]]
    return prefixes.flatMap { prefix in
      (UInt8(0x40)...0x4F).flatMap { opcode in
        [prefix + [0x0F, opcode, 0xC3], prefix + [0x0F, opcode, 0x03]]
      }
    }
  }

  private func pairForms(mode: DoryX86ExecutionMode) -> [([UInt8], DoryX86Feature)] {
    var forms: [([UInt8], DoryX86Feature)] = []
    for prefix: [UInt8] in [[], [0x66], [0xF0], [0x67, 0xF0]] {
      forms.append((prefix + [0x0F, 0xC7, 0x0F], .cmpxchg8b))
      if mode == .long64 { forms.append((prefix + [0x48, 0x0F, 0xC7, 0x0F], .cmpxchg16b)) }
    }
    return forms
  }

  private func profile(removing features: Set<DoryX86Feature>, base: DoryX86CPUProfile = .compatibleV1) -> DoryX86CPUProfile {
    // Keep the same identifier deliberately: admission is based on stored bits, not the name.
    .init(identifier: base.identifier, features: base.features.subtracting(features),
      physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz, identity: base.identity)
  }

  private func initialState(mode: DoryX86ExecutionMode = .long64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x8000, rdi: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(selector: mode == .real16 ? 0 : 8,
        attributes: mode == .long64 ? 0xA09B : 0x009B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11))
  }

  private func featureFault(_ feature: DoryX86Feature, rip: UInt64 = 0x1000) -> DoryX86InterpreterResult {
    feature == .cmpxchg16b
      ? .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: rip))
      : .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: rip))
  }
}

private final class IntegerPolicyMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses = 0
  init(code: [UInt8]) { self.code = code }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] { Array(code.prefix(maximumCount)) }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
}
