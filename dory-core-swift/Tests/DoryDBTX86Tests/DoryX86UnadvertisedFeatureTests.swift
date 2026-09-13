import Foundation
import Testing

@testable import DoryDBTX86

// A03.3: Unadvertised SIMD/extended-state forms must fault with #UD before any
// data access when the public profile filters them out. The public profile
// subtracts `unqualifiedSIMDAndExtendedStateFeatures` (SSE3, SSSE3, SSE4.1,
// SSE4.2, XSAVE, OSXSAVE, AVX, AVX2, F16C, FMA, BMI1, BMI2, LZCNT).
// MOVBE was promoted to a qualified feature in P2-07 and is no longer masked.
// These tests verify that representative forms from each family fault with #UD
// and leave architectural state unchanged when using the public `.compatibleV1`
// profile, which does not advertise any of these features.
@Suite struct DoryX86UnadvertisedFeatureTests {
  @Test func sse3FormsFaultWithUDUnderPublicProfile() throws {
    for bytes: [UInt8] in [
      [0x66, 0x0F, 0xD0, 0xC1],  // ADDSUBPD xmm0, xmm1 (SSE3, 66 0F D0)
      [0xF2, 0x0F, 0xD0, 0xC1],  // ADDSUBPS xmm0, xmm1 (SSE3, F2 0F D0)
    ] {
      let memory = UnadvertisedFeatureMemory(code: bytes)
      var state = try initialState()
      let before = state
      let result = DoryX86Interpreter(profile: .compatibleV1).step(
        state: &state, memory: memory, mode: .long64)
      #expect(result == invalidOpcodeResult())
      #expect(state == before)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func ssse3FormsFaultWithUDUnderPublicProfile() throws {
    for bytes: [UInt8] in [
      [0x0F, 0x38, 0x00, 0xC1],  // PSHUFB mm0, mm1 (SSSE3)
      [0x66, 0x0F, 0x38, 0x00, 0xC1],  // PSHUFB xmm0, xmm1 (SSSE3, 66 prefix)
    ] {
      let memory = UnadvertisedFeatureMemory(code: bytes)
      var state = try initialState()
      let before = state
      let result = DoryX86Interpreter(profile: .compatibleV1).step(
        state: &state, memory: memory, mode: .long64)
      #expect(result == invalidOpcodeResult())
      #expect(state == before)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func sse4FormsFaultWithUDUnderPublicProfile() throws {
    for bytes: [UInt8] in [
      [0x66, 0x0F, 0x38, 0x17, 0xC1],  // PTEST xmm0, xmm1 (SSE4.1)
      [0x66, 0x0F, 0x38, 0x40, 0xC1],  // PMULLD xmm0, xmm1 (SSE4.1)
      [0x66, 0x0F, 0x38, 0x37, 0xC1],  // PCMPGTQ xmm0, xmm1 (SSE4.2)
    ] {
      let memory = UnadvertisedFeatureMemory(code: bytes)
      var state = try initialState()
      let before = state
      let result = DoryX86Interpreter(profile: .compatibleV1).step(
        state: &state, memory: memory, mode: .long64)
      #expect(result == invalidOpcodeResult())
      #expect(state == before)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func avxFormsFaultWithUDUnderPublicProfile() throws {
    for bytes: [UInt8] in [
      [0xC5, 0xF9, 0x6F, 0xC1],  // VMOVDQA xmm0, xmm1 (AVX)
      [0xC5, 0xFD, 0x6F, 0xC1],  // VMOVDQA ymm0, ymm1 (AVX)
      [0xC5, 0xFB, 0x12, 0xC1],  // VMOVDDUP xmm0, xmm1 (AVX)
    ] {
      let memory = UnadvertisedFeatureMemory(code: bytes)
      var state = try initialState()
      let before = state
      let result = DoryX86Interpreter(profile: .compatibleV1).step(
        state: &state, memory: memory, mode: .long64)
      #expect(result == invalidOpcodeResult())
      #expect(state == before)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func xsaveFormsFaultWithUDUnderPublicProfile() throws {
    for bytes: [UInt8] in [
      [0x0F, 0xAE, 0x20],  // XSAVE [rax] (XSAVE)
      [0x0F, 0xAE, 0x28],  // XRSTOR [rax] (XSAVE)
      [0x0F, 0xAE, 0x30],  // XSAVEOPT [rax] (XSAVE)
    ] {
      let memory = UnadvertisedFeatureMemory(code: bytes)
      var state = try initialState()
      let before = state
      let result = DoryX86Interpreter(profile: .compatibleV1).step(
        state: &state, memory: memory, mode: .long64)
      #expect(result == invalidOpcodeResult())
      #expect(state == before)
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func roundTripPersistedProfileFiltersUnqualifiedFeatures() throws {
    // MOVBE is now a qualified feature (P2-07) and passes through the public
    // boundary. The remaining v3 additions are still filtered.
    let requested = DoryX86CPUProfile.compatibleV1.features.union([
      .sse3, .ssse3, .sse41, .sse42, .xsave, .osxsave, .avx, .avx2,
      .f16c, .fma, .bmi1, .bmi2, .lzcnt, .movbe,
    ])
    let encoded = try JSONEncoder().encode(DoryX86CPUProfile(
      identifier: "test.roundtrip",
      features: requested,
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000))
    let decoded = try JSONDecoder().decode(DoryX86CPUProfile.self, from: encoded)
    let unqualified: Set<DoryX86Feature> = [
      .sse3, .ssse3, .sse41, .sse42, .xsave, .osxsave, .avx, .avx2,
      .f16c, .fma, .bmi1, .bmi2, .lzcnt,
    ]
    #expect(decoded.features.isDisjoint(with: unqualified))
    // MOVBE is now admitted.
    #expect(decoded.supports(.movbe))
    #expect(decoded.cpuid(leaf: 1).ecx & (1 << 22) != 0)
    // CPUID leaf 1 ECX must not advertise SSE3/SSSE3/SSE4.1/SSE4.2/XSAVE/OSXSAVE/AVX/F16C/FMA.
    let ecx = decoded.cpuid(leaf: 1, cr4: 1 << 18).ecx
    let ecxMask: UInt32 = (1 << 0) | (1 << 9) | (3 << 19) | (7 << 26) | (1 << 12) | (1 << 28) | (1 << 29)
    #expect(ecx & ecxMask == 0)
    // CPUID leaf 7 EBX must not advertise BMI1/AVX2/BMI2.
    let ebx7 = decoded.cpuid(leaf: 7).ebx
    #expect(ebx7 & ((1 << 3) | (1 << 5) | (1 << 8)) == 0)
    // CPUID 0x8000_0001 ECX must not advertise LZCNT.
    #expect(decoded.cpuid(leaf: 0x8000_0001).ecx & (1 << 5) == 0)
    // XSAVE area must be empty.
    #expect(decoded.cpuid(leaf: 0xD, xcr0: 7) == .init())
  }

  private func invalidOpcodeResult(at rip: UInt64 = 0x1000) -> DoryX86InterpreterResult {
    .exception(DoryX86Exception(kind: .invalidOpcode, vector: 6, instructionPointer: rip))
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: 0x1234_5678_9ABC_DEF0, rbx: 0x8000),
      rip: 0x1000,
      rflags: [.reservedOne, .interruptEnable])
  }
}

private final class UnadvertisedFeatureMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses: Int = 0

  init(code: [UInt8]) {
    self.code = code
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < UInt64(code.count) else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccesses += 1
    return Array(repeating: 0, count: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {}
  func write(at address: UInt64, bytes: [UInt8]) throws { dataAccesses += 1 }
  func validateWrite(at address: UInt64, byteCount: Int) throws {}
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try read(at: address, byteCount: byteCount)
  }
  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 { 0 }
  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {}
  func synchronize() {}
}
