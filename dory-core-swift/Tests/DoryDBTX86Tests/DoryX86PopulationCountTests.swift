import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B POPCNT pp. 4-688–4-690. These tests cover the
// legacy F3 0F B8 encoding, its CPUID admission rule, and architectural effects.
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86PopulationCountTests {
  @Test func mandatoryPrefixAndOperandSizeSelectExactForms() throws {
    let decoder = DoryX86Decoder()
    let widths: [(DoryX86ExecutionMode, DoryX86OperandWidth, DoryX86OperandWidth)] = [
      (.real16, .word, .doubleword),
      (.protected16, .word, .doubleword),
      (.protected32, .doubleword, .word),
      (.long64, .doubleword, .word),
    ]
    for (mode, defaultWidth, overriddenWidth) in widths {
      #expect(try decoder.decode([0xF3, 0x0F, 0xB8, 0xC3], at: 0x1000, mode: mode).operation
        == .populationCount(
          destination: .register(.rax, width: defaultWidth),
          source: .register(.rbx, width: defaultWidth)))
      #expect(try decoder.decode([0x66, 0xF3, 0x0F, 0xB8, 0xC3], at: 0x1000, mode: mode).operation
        == .populationCount(
          destination: .register(.rax, width: overriddenWidth),
          source: .register(.rbx, width: overriddenWidth)))
      let memory = try decoder.decode(
        [0x2E, 0x67, 0xF3, 0x0F, 0xB8, 0x03], at: 0x1000, mode: mode)
      guard case .populationCount(.register(.rax, let width), .memory(let source)) = memory.operation else {
        Issue.record("POPCNT did not preserve its register destination and memory source")
        continue
      }
      #expect(width == defaultWidth && source.width == defaultWidth)
    }

    #expect(try decoder.decode(
      [0xF3, 0x4D, 0x0F, 0xB8, 0xC1], at: 0x1000, mode: .long64).operation
      == .populationCount(
        destination: .register(.r8, width: .quadword),
        source: .register(.r9, width: .quadword)))
    #expect(try decoder.decode(
      [0x66, 0xF3, 0x48, 0x0F, 0xB8, 0xC3], at: 0x1000, mode: .long64).operation
      == .populationCount(
        destination: .register(.rax, width: .quadword),
        source: .register(.rbx, width: .quadword)))
  }

  @Test func missingWrongAndLockPrefixesAreInvalidEncodings() throws {
    for bytes: [UInt8] in [
      [0x0F, 0xB8, 0xC3], [0x66, 0x0F, 0xB8, 0xC3],
      [0xF2, 0x0F, 0xB8, 0xC3], [0xF0, 0xF3, 0x0F, 0xB8, 0xC3],
      [0xF0, 0xF3, 0x0F, 0xB8, 0x03],
    ] {
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      }
    }
  }

  @Test func registerFormsCountTheirSelectedWidthAndDefineAllArithmeticFlags() throws {
    let preserved: DoryX86RFLAGS = [.reservedOne, .trap, .interruptEnable, .direction, .identification]
    let arithmetic: DoryX86RFLAGS = [.carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow]
    let forms: [([UInt8], UInt64, UInt64)] = [
      ([0x66, 0xF3, 0x0F, 0xB8, 0xC3], 0xABCD_EF01_2345_00F3, 0xABCD_EF01_2345_0006),
      ([0xF3, 0x0F, 0xB8, 0xC3], 0xABCD_EF01_F0F0_000F, 0x0000_0000_0000_000C),
      ([0xF3, 0x48, 0x0F, 0xB8, 0xC3], 0xF0F0_0000_0000_000F, 0x0000_0000_0000_000C),
    ]
    for (bytes, source, expectedDestination) in forms {
      let memory = PopulationCountMemory(code: bytes)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xABCD_EF01_2345_6789, rbx: source), rip: 0x1000,
        rflags: preserved.union(arithmetic))
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter(profile: popcntProfile).step(
        state: &state, memory: memory, mode: .long64) == .retired(decoded))
      #expect(state.registers.rax == expectedDestination)
      #expect(state.rflags == preserved)
      #expect(state.rip == 0x1000 + UInt64(bytes.count))
    }

    let bytes: [UInt8] = [0xF3, 0x48, 0x0F, 0xB8, 0xC3]
    var zero = try DoryX86ArchitecturalState(
      registers: .init(rax: .max, rbx: 0), rip: 0x1000,
      rflags: preserved.union(arithmetic))
    let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter(profile: popcntProfile).step(
      state: &zero, memory: PopulationCountMemory(code: bytes), mode: .long64) == .retired(decoded))
    #expect(zero.registers.rax == 0)
    #expect(zero.rflags == preserved.union(.zero))
  }

  @Test func memoryFormsReadExactlyTheirOperandWidth() throws {
    for (bytes, byteCount, expected): ([UInt8], Int, UInt64) in [
      ([0x66, 0xF3, 0x0F, 0xB8, 0x03], 2, 0xA5A5_A5A5_A5A5_0008),
      ([0xF3, 0x0F, 0xB8, 0x03], 4, 16),
      ([0xF3, 0x48, 0x0F, 0xB8, 0x03], 8, 32),
    ] {
      let memory = PopulationCountMemory(
        code: bytes, data: [0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00])
      var state = try initialState()
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter(profile: popcntProfile).step(
        state: &state, memory: memory, mode: .long64) == .retired(decoded))
      #expect(state.registers.rax == expected)
      #expect(memory.dataReads.count == 1)
      #expect(memory.dataReads.first?.address == 0x8000)
      #expect(memory.dataReads.first?.byteCount == byteCount)
    }
  }

  @Test func featureFaultPrecedesDataAccessAndEnabledDataFaultPreservesEffects() throws {
    let bytes: [UInt8] = [0xF3, 0x48, 0x0F, 0xB8, 0x03]
    let absentMemory = PopulationCountMemory(code: bytes, faultDataRead: true)
    var absentState = try initialState()
    let absentInitial = absentState
    #expect(DoryX86Interpreter(profile: .compatibleV1).step(
      state: &absentState, memory: absentMemory, mode: .long64)
      == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(absentState == absentInitial)
    #expect(absentMemory.dataReads.isEmpty)

    let faultingMemory = PopulationCountMemory(code: bytes, faultDataRead: true)
    var faultingState = try initialState()
    var expected = faultingState
    expected.control.cr2 = 0x8000
    #expect(DoryX86Interpreter(profile: popcntProfile).step(
      state: &faultingState, memory: faultingMemory, mode: .long64)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: 0x1000, linearAddress: 0x8000)))
    #expect(faultingState == expected)
    #expect(faultingMemory.dataReads.count == 1)
  }

  @Test func profileBitControlsCPUIDAdmissionWithoutChangingTheBaseline() throws {
    let instruction = try DoryX86Decoder().decode(
      [0xF3, 0x0F, 0xB8, 0xC3], at: 0x1000, mode: .long64)
    #expect(!DoryX86CPUProfile.compatibleV1.supports(.popcnt))
    #expect(DoryX86CPUProfile.compatibleV1.cpuid(leaf: 1).ecx & (1 << 23) == 0)
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
    #expect(popcntProfile.supports(.popcnt))
    #expect(popcntProfile.cpuid(leaf: 1).ecx & (1 << 23) != 0)
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: popcntProfile))
  }

  @Test func bothNativeTiersDeclineAtTheExactInstructionBoundaryWithoutEffects() throws {
    let popcnt: [UInt8] = [0xF3, 0x48, 0x0F, 0xB8, 0xC3]
    let block = try DoryX86IRTranslator().translate(popcnt, at: 0x1000, mode: .long64)
    #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: popcnt)])
    #expect(block.terminator == .exit(.interpreter, resumeAt: 0x1000))
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      #expect(DoryARM64BaselineEmitter().compile(block, tier: tier).tier == .interpreterFallback)
    }

    #if os(macOS) && arch(arm64)
      let code: [UInt8] = [0x48, 0xFF, 0xC1] + popcnt // INC RCX; POPCNT RAX,RBX.
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16_384, profile: popcntProfile, optimization: optimization)
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
        var state = try initialState()
        let initialRAX = state.registers.rax
        let prefix = try #require(executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
          state: &state, memory: memory))
        #expect(prefix.guestInstructionCount == 1)
        #expect(state.rip == 0x1003 && state.registers.rcx == 1)
        #expect(state.registers.rax == initialRAX)

        let atBoundary = state
        #expect(try executor.executeSummary(
          byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
          at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
          state: &state, memory: memory) == nil)
        #expect(state == atBoundary)
        #expect(try executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
          state: &state, memory: memory) == nil)
        #expect(state == atBoundary)
      }
    #endif
  }

  private var popcntProfile: DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(
      identifier: "test.p02-popcnt",
      features: base.features.union([.popcnt]),
      physicalAddressBits: base.physicalAddressBits,
      linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz,
      identity: base.identity)
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: 0xA5A5_A5A5_A5A5_A5A5, rbx: 0x8000),
      rip: 0x1000,
      rflags: [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
        .interruptEnable, .direction])
  }
}

private final class PopulationCountMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let data: [UInt8]
  let faultDataRead: Bool
  private(set) var dataReads: [(address: UInt64, byteCount: Int)] = []

  init(code: [UInt8], data: [UInt8] = [], faultDataRead: Bool = false) {
    self.code = code
    self.data = data
    self.faultDataRead = faultDataRead
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReads.append((address, byteCount))
    guard !faultDataRead else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 4)
    }
    guard address == 0x8000, data.count >= byteCount else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
    }
    return Array(data.prefix(byteCount))
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: bytes.count, access: .write)
  }
}
