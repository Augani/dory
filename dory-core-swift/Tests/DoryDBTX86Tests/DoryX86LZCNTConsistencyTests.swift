import Testing

@testable import DoryDBTX86

// P2-07 item 7: CPUID, decoder, feature policy, and interpreter must agree.
// LZCNT is advertised via CPUID.0x8000_0001:ECX[5] when the profile opts into
// the .lzcnt feature. Before this change, F3 0F BD was always decoded as BSR,
// so a profile advertising LZCNT disagreed with the decoder and interpreter:
// CPUID said LZCNT was available, but the instruction executed as BSR.
//
// F3 0F BD is an architecturally dual form: LZCNT when the feature is
// advertised, or BSR with the F3 prefix ignored when it is not. These tests
// verify the decoder, feature policy, interpreter, and CPUID now agree.
@Suite struct DoryX86LZCNTConsistencyTests {
  // Internal test profile that admits LZCNT through the semantic boundary.
  private let lzcntProfile = DoryX86CPUProfile(
    identifier: "test.lzcnt",
    features: DoryX86CPUProfile.compatibleV1.features.union([.lzcnt]),
    physicalAddressBits: 40,
    linearAddressBits: 48,
    virtualTSCFrequencyHz: 1_000_000_000,
    allowingUnqualifiedSIMDAndExtendedState: true)

  private let lzcntInterpreter = DoryX86Interpreter(
    profile: DoryX86CPUProfile(
      identifier: "test.lzcnt",
      features: DoryX86CPUProfile.compatibleV1.features.union([.lzcnt]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true))

  // LZCNT r32, r32: 0x00000001 has 31 leading zeros.
  // F3 0F BD C0 = LZCNT EAX, EAX (ModRM C0 = mod 11, reg 0, r/m 0).
  @Test func lzcnt32CountsLeadingZeros() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0000_0001), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 31)
    #expect(state.rip == 0x1004)
  }

  // LZCNT r32, r32: 0x80000000 has 0 leading zeros. ZF=1 (result is 0).
  @Test func lzcnt32MsbSetReturnsZero() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x8000_0000), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // LZCNT r32, r32: source 0 → result 32, CF=1, ZF=0.
  @Test func lzcnt32ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 32)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
  }

  // LZCNT r64, r64: 0x0000000000000001 has 63 leading zeros.
  // F3 48 0F BD C0 = LZCNT RAX, RAX.
  @Test func lzcnt64CountsLeadingZeros() throws {
    let code: [UInt8] = [0xF3, 0x48, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0000_0000_0000_0001), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax == 63)
    #expect(!state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
  }

  // LZCNT r64, r64: source 0 → result 64, CF=1.
  @Test func lzcnt64ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x48, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax == 64)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
  }

  // LZCNT r16, r16: 0x0001 has 15 leading zeros.
  // F3 66 0F BD C0 = LZCNT AX, AX.
  @Test func lzcnt16CountsLeadingZeros() throws {
    let code: [UInt8] = [0xF3, 0x66, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0001), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFF == 15)
  }

  // LZCNT r16, r16: source 0 → result 16.
  @Test func lzcnt16ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x66, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFF == 16)
    #expect(state.rflags.contains(.carry))
  }

  // Without LZCNT advertised, F3 0F BD must execute as BSR (F3 ignored).
  // BSR EAX, EAX with EAX=1 → index 0, ZF=0.
  @Test func bsrFallbackWhenLzcntNotAdvertised() throws {
    let plainInterpreter = DoryX86Interpreter()  // compatibleV1 has no LZCNT
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 1), rip: 0x1000)
    let result = plainInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    // BSR EAX, EAX with EAX=1 → index 0 (bit 0 is the highest set bit).
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // Without LZCNT, F3 0F BD with source 0 → ZF=1, destination undefined (unchanged).
  @Test func bsrFallbackZeroSourceSetsZeroFlag() throws {
    let plainInterpreter = DoryX86Interpreter()
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = plainInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.rflags.contains(.zero))
  }

  // The decoder must produce .countLeadingZeros for F3 0F BD.
  @Test func decoderProducesCountLeadingZerosForF3PrefixedBSR() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0xF3, 0x0F, 0xBD, 0xC0], at: 0, mode: .long64)
    guard case .countLeadingZeros(let destination, _) = instruction.operation else {
      Issue.record("expected .countLeadingZeros for F3 0F BD, got \(instruction.operation)")
      return
    }
    #expect(destination == .register(.rax, width: .doubleword))
  }

  // The decoder must still produce .bitScan for 0F BD without F3 (BSR).
  @Test func decoderProducesBitScanForUnprefixedBSR() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0x0F, 0xBD, 0xC0], at: 0, mode: .long64)
    guard case .bitScan(let reverse, _, _) = instruction.operation else {
      Issue.record("expected .bitScan for 0F BD, got \(instruction.operation)")
      return
    }
    #expect(reverse == true)
  }

  // The decoder must now produce .countTrailingZeros for F3 0F BC (TZCNT/BSF).
  // F3 0F BC is TZCNT when BMI1 is advertised, or BSF with the F3 prefix ignored
  // when it is not; the decoder emits a distinct operation in both cases.
  @Test func decoderProducesCountTrailingZerosForF3PrefixedBSF() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0xF3, 0x0F, 0xBC, 0xC0], at: 0, mode: .long64)
    guard case .countTrailingZeros(let destination, _) = instruction.operation else {
      Issue.record("expected .countTrailingZeros for F3 0F BC, got \(instruction.operation)")
      return
    }
    #expect(destination == .register(.rax, width: .doubleword))
  }

  // The feature policy must always permit .countLeadingZeros; it is either
  // LZCNT (when advertised) or BSR (when not), both architecturally valid.
  @Test func featurePolicyAlwaysPermitsCountLeadingZeros() throws {
    let instruction = try DoryX86Decoder().decode(
      [0xF3, 0x0F, 0xBD, 0xC0], at: 0, mode: .long64)
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: lzcntProfile))
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
  }

  // CPUID must advertise LZCNT when the profile opts into the feature.
  @Test func cpuidAdvertisesLzcntWhenFeaturePresent() {
    #expect(lzcntProfile.cpuid(leaf: 0x8000_0001).ecx & (1 << 5) != 0)
    #expect(lzcntProfile.supports(.lzcnt))
  }

  // CPUID must not advertise LZCNT under the public baseline profile.
  @Test func cpuidDoesNotAdvertiseLzcntUnderBaseline() {
    #expect(DoryX86CPUProfile.compatibleV1.cpuid(leaf: 0x8000_0001).ecx & (1 << 5) == 0)
    #expect(!DoryX86CPUProfile.compatibleV1.supports(.lzcnt))
  }

  // The public profile boundary must filter out LZCNT even if requested.
  @Test func publicProfileFiltersOutLzcnt() {
    let publicProfile = DoryX86CPUProfile(
      identifier: "test.public",
      features: DoryX86CPUProfile.compatibleV1.features.union([.lzcnt]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000)
    #expect(!publicProfile.supports(.lzcnt))
    #expect(publicProfile.cpuid(leaf: 0x8000_0001).ecx & (1 << 5) == 0)
  }

  // LZCNT from memory: F3 0F BD 07 = LZCNT EAX, [RDI].
  @Test func lzcnt32FromMemory() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBD, 0x07]
    let data: [UInt8] = [0x00, 0x00, 0x00, 0x80]  // 0x80000000 → 0 leading zeros
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = lzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(state.rflags.contains(.zero))
  }
}

// P2-07 item 7: CPUID, decoder, feature policy, and interpreter must agree for
// TZCNT. TZCNT is advertised via CPUID.7:EBX.BMI1 when the profile opts into
// the .bmi1 feature. Before this change, F3 0F BC was always decoded as BSF,
// so a profile advertising BMI1 disagreed with the decoder and interpreter:
// CPUID said BMI1 was available, but the instruction executed as BSF.
//
// F3 0F BC is an architecturally dual form: TZCNT when the feature is
// advertised, or BSF with the F3 prefix ignored when it is not. These tests
// verify the decoder, feature policy, interpreter, and CPUID now agree.
@Suite struct DoryX86TZCNTConsistencyTests {
  // Internal test profile that admits BMI1 through the semantic boundary.
  private let tzcntProfile = DoryX86CPUProfile(
    identifier: "test.tzcnt",
    features: DoryX86CPUProfile.compatibleV1.features.union([.bmi1]),
    physicalAddressBits: 40,
    linearAddressBits: 48,
    virtualTSCFrequencyHz: 1_000_000_000,
    allowingUnqualifiedSIMDAndExtendedState: true)

  private let tzcntInterpreter = DoryX86Interpreter(
    profile: DoryX86CPUProfile(
      identifier: "test.tzcnt",
      features: DoryX86CPUProfile.compatibleV1.features.union([.bmi1]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true))

  // TZCNT r32, r32: 0x00000001 has 0 trailing zeros. ZF=1 (result is 0), CF=0.
  // F3 0F BC C0 = TZCNT EAX, EAX (ModRM C0 = mod 11, reg 0, r/m 0).
  @Test func tzcnt32LsbSetReturnsZero() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0000_0001), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // TZCNT r32, r32: 0x80000000 has 31 trailing zeros. ZF=0, CF=0.
  @Test func tzcnt32CountsTrailingZeros() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x8000_0000), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 31)
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // TZCNT r32, r32: source 0 → result 32, CF=1, ZF=0.
  @Test func tzcnt32ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 32)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
  }

  // TZCNT r64, r64: 0x0000000000000001 has 0 trailing zeros. ZF=1, CF=0.
  // F3 48 0F BC C0 = TZCNT RAX, RAX.
  @Test func tzcnt64LsbSetReturnsZero() throws {
    let code: [UInt8] = [0xF3, 0x48, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0000_0000_0000_0001), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax == 0)
    #expect(state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // TZCNT r64, r64: 0x8000000000000000 has 63 trailing zeros. ZF=0, CF=0.
  @Test func tzcnt64CountsTrailingZeros() throws {
    let code: [UInt8] = [0xF3, 0x48, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x8000_0000_0000_0000), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax == 63)
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // TZCNT r64, r64: source 0 → result 64, CF=1, ZF=0.
  @Test func tzcnt64ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x48, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax == 64)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
  }

  // TZCNT r16, r16: 0x0001 has 0 trailing zeros. ZF=1.
  // F3 66 0F BC C0 = TZCNT AX, AX.
  @Test func tzcnt16LsbSetReturnsZero() throws {
    let code: [UInt8] = [0xF3, 0x66, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x0001), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFF == 0)
    #expect(state.rflags.contains(.zero))
  }

  // TZCNT r16, r16: 0x8000 has 15 trailing zeros. ZF=0.
  @Test func tzcnt16CountsTrailingZeros() throws {
    let code: [UInt8] = [0xF3, 0x66, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x8000), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFF == 15)
    #expect(!state.rflags.contains(.zero))
  }

  // TZCNT r16, r16: source 0 → result 16, CF=1.
  @Test func tzcnt16ZeroSourceReturnsOperandSize() throws {
    let code: [UInt8] = [0xF3, 0x66, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFF == 16)
    #expect(state.rflags.contains(.carry))
  }

  // Without BMI1 advertised, F3 0F BC must execute as BSF (F3 ignored).
  // BSF EAX, EAX with EAX=1 → index 0, ZF=0.
  @Test func bsfFallbackWhenBmi1NotAdvertised() throws {
    let plainInterpreter = DoryX86Interpreter()  // compatibleV1 has no BMI1
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 1), rip: 0x1000)
    let result = plainInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    // BSF EAX, EAX with EAX=1 → index 0 (bit 0 is the lowest set bit).
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.carry))
  }

  // Without BMI1, F3 0F BC with source 0 → ZF=1, destination undefined (unchanged).
  @Test func bsfFallbackZeroSourceSetsZeroFlag() throws {
    let plainInterpreter = DoryX86Interpreter()
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0), rip: 0x1000)
    let result = plainInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.rflags.contains(.zero))
  }

  // BSR fallback is not affected: 0F BD without F3 still decodes as bitScan BSR.
  @Test func bsrFallbackNotAffected() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0x0F, 0xBD, 0xC0], at: 0, mode: .long64)
    guard case .bitScan(let reverse, _, _) = instruction.operation else {
      Issue.record("expected .bitScan for 0F BD, got \(instruction.operation)")
      return
    }
    #expect(reverse == true)
  }

  // The decoder must produce .countTrailingZeros for F3 0F BC.
  @Test func decoderProducesCountTrailingZerosForF3PrefixedBSF() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0xF3, 0x0F, 0xBC, 0xC0], at: 0, mode: .long64)
    guard case .countTrailingZeros(let destination, _) = instruction.operation else {
      Issue.record("expected .countTrailingZeros for F3 0F BC, got \(instruction.operation)")
      return
    }
    #expect(destination == .register(.rax, width: .doubleword))
  }

  // The decoder must still produce .bitScan for 0F BC without F3 (BSF).
  @Test func decoderProducesBitScanForUnprefixedBSF() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0x0F, 0xBC, 0xC0], at: 0, mode: .long64)
    guard case .bitScan(let reverse, _, _) = instruction.operation else {
      Issue.record("expected .bitScan for 0F BC, got \(instruction.operation)")
      return
    }
    #expect(reverse == false)
  }

  // The feature policy must always permit .countTrailingZeros; it is either
  // TZCNT (when advertised) or BSF (when not), both architecturally valid.
  @Test func featurePolicyAlwaysPermitsCountTrailingZeros() throws {
    let instruction = try DoryX86Decoder().decode(
      [0xF3, 0x0F, 0xBC, 0xC0], at: 0, mode: .long64)
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: tzcntProfile))
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
  }

  // CPUID must advertise BMI1 when the profile opts into the feature.
  @Test func cpuidAdvertisesBmi1WhenFeaturePresent() {
    #expect(tzcntProfile.cpuid(leaf: 7).ebx & (1 << 3) != 0)
    #expect(tzcntProfile.supports(.bmi1))
  }

  // CPUID must not advertise BMI1 under the public baseline profile.
  @Test func cpuidDoesNotAdvertiseBmi1UnderBaseline() {
    #expect(DoryX86CPUProfile.compatibleV1.cpuid(leaf: 7).ebx & (1 << 3) == 0)
    #expect(!DoryX86CPUProfile.compatibleV1.supports(.bmi1))
  }

  // The public profile boundary must filter out BMI1 even if requested.
  @Test func publicProfileFiltersOutBmi1() {
    let publicProfile = DoryX86CPUProfile(
      identifier: "test.public",
      features: DoryX86CPUProfile.compatibleV1.features.union([.bmi1]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000)
    #expect(!publicProfile.supports(.bmi1))
    #expect(publicProfile.cpuid(leaf: 7).ebx & (1 << 3) == 0)
  }

  // TZCNT from memory: F3 0F BC 07 = TZCNT EAX, [RDI].
  @Test func tzcnt32FromMemory() throws {
    let code: [UInt8] = [0xF3, 0x0F, 0xBC, 0x07]
    let data: [UInt8] = [0x00, 0x00, 0x00, 0x80]  // 0x80000000 → 31 trailing zeros
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = tzcntInterpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 31)
    #expect(!state.rflags.contains(.zero))
  }
}
