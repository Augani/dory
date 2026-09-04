import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2D SYSRET. SYSRET is executable only from 64-bit mode at
// CPL0 with EFER.SCE enabled. Its operand size selects a compatibility-mode
// EIP return or a 64-bit RIP return after validating full RCX as canonical;
// neither form changes RSP.
@Suite struct DoryX86SystemReturnModeTests {
  @Test func defaultOperandSizeReturnsToCompatibilityModeUsingECX() throws {
    let bytes: [UInt8] = [0x0F, 0x07]
    let memory = try codeMemory(bytes)
    var state = try longModeState(
      rcx: 0xFFFF_8000_7654_3210,
      r11: DoryX86RFLAGS.reservedOne.rawValue
        | DoryX86RFLAGS.interruptEnable.rawValue
        | DoryX86RFLAGS.direction.rawValue)
    let originalRSP = state.registers.rsp
    let originalRCX = state.registers.rcx

    try expectRetired(bytes, state: &state, memory: memory)

    #expect(state.rip == 0x7654_3210)
    #expect(state.registers.rcx == originalRCX)
    #expect(state.registers.rsp == originalRSP)
    #expect(
      state.cs
        == .init(
          selector: 0x23, attributes: 0xC0FB,
          limit: .max, base: 0))
    #expect(
      state.ss
        == .init(
          selector: 0x2B, attributes: 0xC0F3,
          limit: .max, base: 0))
    #expect(state.rflags == [.reservedOne, .interruptEnable, .direction])
  }

  @Test func rexWReturnsTo64BitModeAndRequiresCanonicalRCX() throws {
    let bytes: [UInt8] = [0x48, 0x0F, 0x07]
    let memory = try codeMemory(bytes)
    var state = try longModeState(rcx: 0xFFFF_8000_0000_1234)
    let originalRSP = state.registers.rsp

    try expectRetired(bytes, state: &state, memory: memory)

    #expect(state.rip == 0xFFFF_8000_0000_1234)
    #expect(state.registers.rsp == originalRSP)
    #expect(
      state.cs
        == .init(
          selector: 0x33, attributes: 0xA0FB,
          limit: .max, base: 0))
    #expect(
      state.ss
        == .init(
          selector: 0x2B, attributes: 0xC0F3,
          limit: .max, base: 0))

    var noncanonical = try longModeState(rcx: 0x0000_8000_0000_0000)
    let before = noncanonical
    #expect(
      interpreter.step(state: &noncanonical, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection, vector: 13,
            errorCode: 0, instructionPointer: 0x1000)))
    #expect(noncanonical == before)
  }

  @Test func compatibilityReturnAlsoRequiresCanonicalFullRCX() throws {
    let bytes: [UInt8] = [0x0F, 0x07]
    let memory = try codeMemory(bytes)
    var state = try longModeState(
      rcx: 0x0000_8000_7654_3210,
      r11: DoryX86RFLAGS.reservedOne.rawValue | DoryX86RFLAGS.direction.rawValue)
    let before = state

    expectFault(.generalProtection, state: &state, memory: memory, mode: .long64)

    #expect(state == before)
  }

  @Test func unavailableAndWrongModeSYSRETRaiseUDWithoutStateChanges() throws {
    let bytes: [UInt8] = [0x0F, 0x07]
    let memory = try codeMemory(bytes)

    var disabled = try longModeState(rcx: 0x1234, sce: false)
    let beforeDisabled = disabled
    expectFault(.invalidOpcode, state: &disabled, memory: memory, mode: .long64)
    #expect(disabled == beforeDisabled)

    let restrictedProfile = DoryX86CPUProfile(
      identifier: "test.no-syscall", features: [], physicalAddressBits: 40,
      linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000)
    var unavailable = try longModeState(rcx: 0x1234)
    let beforeUnavailable = unavailable
    expectFault(
      .invalidOpcode, state: &unavailable, memory: memory, mode: .long64,
      using: DoryX86Interpreter(profile: restrictedProfile))
    #expect(unavailable == beforeUnavailable)

    var compatibility = try compatibilityState()
    let beforeCompatibility = compatibility
    expectFault(.invalidOpcode, state: &compatibility, memory: memory, mode: .protected32)
    #expect(compatibility == beforeCompatibility)
  }

  @Test func userModeSYSRETRaisesPreciseGP() throws {
    let bytes: [UInt8] = [0x48, 0x0F, 0x07]
    let memory = try codeMemory(bytes)
    var state = try longModeState(rcx: 0x1234)
    state.cs.selector = 3
    let before = state

    expectFault(.generalProtection, state: &state, memory: memory, mode: .long64)

    #expect(state == before)
  }

  private var interpreter: DoryX86Interpreter { .init() }

  private func longModeState(
    rcx: UInt64, r11: UInt64 = DoryX86RFLAGS.reservedOne.rawValue,
    sce: Bool = true
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rcx: rcx, rsp: 0xFFFF_8000_0000_8000, r11: r11),
      rip: 0x1000,
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      control: .init(
        cr0: 0x8000_0011, cr4: 1 << 5,
        efer: 0x500 | (sce ? 1 : 0)),
      modelSpecific: .init(star: UInt64(0x20) << 48))
  }

  private func compatibilityState() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rcx: 0x1234), rip: 0x1000,
      cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
      control: .init(cr0: 0x11, efer: 1),
      modelSpecific: .init(star: UInt64(0x20) << 48))
  }

  private func codeMemory(_ bytes: [UInt8]) throws -> DoryX86ByteArrayMemory {
    try .init(baseAddress: 0x1000, bytes: bytes + .init(repeating: 0, count: 16))
  }

  private func expectRetired(
    _ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded))
  }

  private func expectFault(
    _ kind: DoryX86Exception.Kind, state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode,
    using interpreter: DoryX86Interpreter = .init()
  ) {
    let vector: UInt8 = kind == .invalidOpcode ? 6 : 13
    #expect(
      interpreter.step(state: &state, memory: memory, mode: mode)
        == .exception(
          .init(
            kind: kind, vector: vector,
            errorCode: kind == .generalProtection ? 0 : nil,
            instructionPointer: 0x1000)))
  }
}
