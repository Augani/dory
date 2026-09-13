import Testing

@testable import DoryDBTX86

// P2-07 item 7: CPUID, decoder, feature policy, and interpreter must agree.
// MOVBE is advertised in the v3 Linux baseline (CPUID.01H:ECX[22]). Before this
// change, the decoder had no path for 0F 38 F0/F1, so a guest using MOVBE got
// #UD despite CPUID advertising the feature. These tests verify the decoder,
// feature policy gate, and interpreter now agree.
@Suite struct DoryX86MOVBEConsistencyTests {
  private let interpreter = DoryX86Interpreter(
    profile: .init(
      identifier: "test.movbe",
      features: DoryX86CPUProfile.compatibleV1.features.union([.movbe]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000))

  // MOVBE r32, m32: memory [0x12,0x34,0x56,0x78] = value 0x78563412, byte-swap → 0x12345678.
  // ModRM 0x07 = mod=00, reg=0 (EAX), r/m=7 (RDI) → MOVBE EAX, [RDI]
  @Test func movbeLoad32SwapsBytesIntoRegister() throws {
    let code: [UInt8] = [0x0F, 0x38, 0xF0, 0x07]
    let data: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    #expect(state.registers.rax & 0xFFFFFFFF == 0x12345678)
    #expect(state.rip == 0x1004)
  }

  // MOVBE r64, m64: load 8 bytes, byte-swap to reversed order.
  @Test func movbeLoad64SwapsBytesIntoRegister() throws {
    let code: [UInt8] = [0x48, 0x0F, 0x38, 0xF0, 0x07]
    let data: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    // Memory little-endian value = 0x0807060504030201, byte-swap → 0x0102030405060708
    #expect(state.registers.rax == 0x0102030405060708)
  }

  // MOVBE m32, r32: EAX=0x12345678, byte-swap → 0x78563412, stored little-endian.
  @Test func movbeStore32SwapsRegisterBytesToMemory() throws {
    let code: [UInt8] = [0x0F, 0x38, 0xF1, 0x07]
    let padding: [UInt8] = [0, 0, 0, 0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + padding)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x12345678, rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    // 0x78563412 stored little-endian = [0x12, 0x34, 0x56, 0x78]
    let stored = try memory.read(at: 0x1000 + UInt64(code.count), byteCount: 4)
    #expect(stored == [0x12, 0x34, 0x56, 0x78])
  }

  // MOVBE r16, m16: 16-bit load with byte-swap.
  @Test func movbeLoad16SwapsBytesIntoRegister() throws {
    let code: [UInt8] = [0x66, 0x0F, 0x38, 0xF0, 0x07]
    let data: [UInt8] = [0x34, 0x12]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("expected retired, got \(result)"); return
    }
    // Memory little-endian value = 0x1234, byte-swap → 0x3412
    #expect(state.registers.rax & 0xFFFF == 0x3412)
  }

  // MOVBE with register-to-register form must raise an exception.
  // ModRM 0xC0 = mod=11, reg=0, r/m=0 → register-to-register.
  @Test func movbeRegisterToRegisterRaisesInvalidOpcode() throws {
    let code: [UInt8] = [0x0F, 0x38, 0xF0, 0xC0]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try DoryX86ArchitecturalState(rip: 0x1000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    if case .exception(let exc) = result {
      #expect(exc.kind == .invalidOpcode || exc.kind == .generalProtection)
    } else {
      Issue.record("expected exception for register-to-register MOVBE, got \(result)")
    }
  }

  // Without the MOVBE feature advertised, MOVBE must raise #UD.
  @Test func movbeWithoutFeatureRaisesInvalidOpcode() throws {
    let plainInterpreter = DoryX86Interpreter()  // compatibleV1 has no MOVBE
    let code: [UInt8] = [0x0F, 0x38, 0xF0, 0x07]
    let data: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code + data)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x1000 + UInt64(code.count)), rip: 0x1000)
    let result = plainInterpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(result == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(state.registers.rax == 0)
    #expect(state.rip == 0x1000)
  }

  // The decoder must produce a .moveByteSwapped operation for 0F 38 F0.
  @Test func decoderProducesMoveByteSwappedForLoadForm() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0x0F, 0x38, 0xF0, 0x07], at: 0, mode: .long64)
    guard case .moveByteSwapped(let reg, _, let load) = instruction.operation else {
      Issue.record("expected .moveByteSwapped for 0F 38 F0, got \(instruction.operation)")
      return
    }
    #expect(load == true)
    #expect(reg == .register(.rax, width: .doubleword))
  }

  // The decoder must produce a .moveByteSwapped operation for 0F 38 F1.
  @Test func decoderProducesMoveByteSwappedForStoreForm() throws {
    let decoder = DoryX86Decoder()
    let instruction = try decoder.decode([0x0F, 0x38, 0xF1, 0x07], at: 0, mode: .long64)
    guard case .moveByteSwapped(_, _, let load) = instruction.operation else {
      Issue.record("expected .moveByteSwapped for 0F 38 F1, got \(instruction.operation)")
      return
    }
    #expect(load == false)
  }

  // The feature policy must gate MOVBE behind the .movbe feature.
  @Test func featurePolicyGatesMovbeBehindMovbeFeature() throws {
    let withMovbe = DoryX86CPUProfile(
      identifier: "test.movbe",
      features: DoryX86CPUProfile.compatibleV1.features.union([.movbe]),
      physicalAddressBits: 40, linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000)
    let withoutMovbe = DoryX86CPUProfile.compatibleV1

    let instruction = try DoryX86Decoder().decode(
      [0x0F, 0x38, 0xF0, 0x07], at: 0, mode: .long64)
    #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: withMovbe))
    #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: withoutMovbe))
  }
}
