import Foundation
import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 1 §21.3 (vendor/signature) and Vol. 3A §12.11.7
// (BIOS_SIGN_ID, including the no-loaded-update case):
// https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// This candidate does not qualify a physical Intel SKU, microcode loading, or Linux.
@Suite struct DoryX86IntelCompatibleProfileTests {
  @Test func explicitIdentityChangesOnlyVendorAndSignature() {
    let legacy = DoryX86CPUProfile.compatibleV1
    let candidate = DoryX86CPUProfile.intelCompatibleV1
    #expect(candidate.identifier == "dory.x86_64.intel-compatible-v1")
    #expect(candidate.identity == .intelCompatibleV1)
    #expect(legacy.identity == .legacyDoryV1)
    #expect(candidate.features == legacy.features)
    #expect(candidate.physicalAddressBits == legacy.physicalAddressBits)
    #expect(candidate.linearAddressBits == legacy.linearAddressBits)
    #expect(candidate.virtualTSCFrequencyHz == legacy.virtualTSCFrequencyHz)
    let vendor = candidate.cpuid(leaf: 0)
    let bytes = [vendor.ebx, vendor.edx, vendor.ecx].flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }
    #expect(String(bytes: bytes, encoding: .ascii) == "GenuineIntel")
    #expect(vendor.eax == legacy.cpuid(leaf: 0).eax)
    #expect(candidate.cpuid(leaf: 1).eax == 0x600)
    #expect(legacy.cpuid(leaf: 1).eax == 0x0006_0F00)
    let leaves = Array(UInt32(0)...0x10)
      + Array(UInt32(0x8000_0000)...0x8000_0009)
      + Array(UInt32(0x4000_0000)...0x4000_00FF)
    for leaf in leaves {
      for subleaf: UInt32 in [0, 1, 2, 0xFF] {
        let old = legacy.cpuid(leaf: leaf, subleaf: subleaf, processorID: 3,
          logicalProcessorCount: 4, cr4: 1 << 18, xcr0: 7)
        let new = candidate.cpuid(leaf: leaf, subleaf: subleaf, processorID: 3,
          logicalProcessorCount: 4, cr4: 1 << 18, xcr0: 7)
        if leaf == 0 { #expect(new.eax == old.eax) }
        else if leaf == 1 {
          #expect(new.ebx == old.ebx && new.ecx == old.ecx && new.edx == old.edx)
        } else { #expect(new == old) }
      }
    }
    #expect(candidate.cpuid(leaf: 1).ecx & (1 << 31) == 0)
    #expect(!candidate.supports(.invariantTSC) && !candidate.supports(.avx))
  }

  @Test func legacyProfileJSONDefaultsIdentityAndArbitraryLabelsCannotSwitchIt() throws {
    var json = try object(DoryX86CPUProfile.compatibleV1)
    json.removeValue(forKey: "identity")
    let legacy = try decode(DoryX86CPUProfile.self, json)
    #expect(legacy == .compatibleV1)
    json["identifier"] = DoryX86CPUProfile.intelCompatibleV1Identifier
    let relabelled = try decode(DoryX86CPUProfile.self, json)
    #expect(relabelled.identity == .legacyDoryV1)
    #expect(relabelled.cpuid(leaf: 0) == legacy.cpuid(leaf: 0))
    #expect(relabelled.cpuid(leaf: 1) == legacy.cpuid(leaf: 1))
    for profile in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
      #expect(try JSONDecoder().decode(DoryX86CPUProfile.self,
        from: JSONEncoder().encode(profile)) == profile)
    }
    json["identity"] = "unrecognizedFutureCPU"
    #expect(throws: DecodingError.self) { try decode(DoryX86CPUProfile.self, json) }
  }

  @Test func oldArchitecturalStateDefaultsSignatureAndNewStatePreservesIt() throws {
    let old = try initialState()
    var json = try object(old)
    var msrs = try #require(json["modelSpecific"] as? [String: Any])
    msrs.removeValue(forKey: "biosUpdateSignature")
    json["modelSpecific"] = msrs
    #expect(try decode(DoryX86ArchitecturalState.self, json) == old)
    var current = old
    current.modelSpecific.biosUpdateSignature = 0xABCD_EF01
    #expect(try JSONDecoder().decode(DoryX86ArchitecturalState.self,
      from: JSONEncoder().encode(current)) == current)
    msrs["biosUpdateSignature"] = UInt64(UInt32.max) + 1
    json["modelSpecific"] = msrs
    #expect(throws: DecodingError.self) { try decode(DoryX86ArchitecturalState.self, json) }
  }

  @Test func signatureStoresHighDWORDAndCPUIDDoesNotInventAMicrocodeUpdate() throws {
    for signature: UInt32 in [0, 1, 0xABCD_EF01, .max] {
      var state = try initialState()
      state.modelSpecific.biosUpdateSignature = 0xDEAD_BEEF
      state.registers.rcx = 0x8B
      state.registers.rax = 0
      state.registers.rdx = UInt64(signature)
      try retired([0x0F, 0x30], state: &state)
      #expect(state.modelSpecific.biosUpdateSignature == signature)
      for leaf: UInt64 in [0, 1, 7, 0x8000_0001] {
        state.registers.rax = leaf
        try retired([0x0F, 0xA2], state: &state)
        #expect(state.modelSpecific.biosUpdateSignature == signature)
      }
      state.registers.rcx = 0x8B
      state.registers.rax = .max
      state.registers.rdx = .max
      try retired([0x0F, 0x32], state: &state)
      #expect(state.registers.rax == 0 && state.registers.rdx == UInt64(signature))
    }
  }

  @Test func reservedLowDWORDAndMicrocodeTriggerFaultWithoutEffects() throws {
    for bit in 0..<32 {
      var state = try initialState()
      state.modelSpecific.biosUpdateSignature = 0xAABB_CCDD
      state.registers.rcx = 0x8B
      state.registers.rax = UInt64(1) << bit
      state.registers.rdx = 0x5566_7788
      try rejected([0x0F, 0x30], state: &state, kind: .generalProtection)
    }
    for opcode: UInt8 in [0x30, 0x32] {
      var state = try initialState()
      state.modelSpecific.biosUpdateSignature = 0xAABB_CCDD
      state.registers.rcx = 0x79 // IA32_BIOS_UPDT_TRIG is not implemented.
      try rejected([0x0F, opcode], state: &state, kind: .generalProtection)
    }
  }

  @Test func oldIdentityAndInsufficientPrivilegeCannotAccessSignature() throws {
    for opcode: UInt8 in [0x30, 0x32] {
      var legacy = try initialState()
      legacy.registers.rcx = 0x8B
      try rejected([0x0F, opcode], state: &legacy, profile: .compatibleV1,
        kind: .generalProtection)
      var user = try initialState()
      user.cs.selector = 3
      user.registers.rcx = 0x8B
      user.modelSpecific.biosUpdateSignature = 0x1234_5678
      try rejected([0x0F, opcode], state: &user, kind: .generalProtection)
    }
  }

  @Test func absentMSRFeatureRaisesInvalidOpcodeBeforePrivilegeAndWrites() throws {
    let candidate = DoryX86CPUProfile.intelCompatibleV1
    let masked = DoryX86CPUProfile(identifier: "test.no-msr",
      features: candidate.features.subtracting([.msr]),
      physicalAddressBits: candidate.physicalAddressBits, linearAddressBits: candidate.linearAddressBits,
      virtualTSCFrequencyHz: candidate.virtualTSCFrequencyHz, identity: candidate.identity)
    for cpl: UInt16 in [0, 3] {
      for opcode: UInt8 in [0x30, 0x32] {
        var state = try initialState()
        state.cs.selector = cpl
        state.registers.rcx = 0x8B
        state.modelSpecific.biosUpdateSignature = 0x1234_5678
        try rejected([0x0F, opcode], state: &state, profile: masked, kind: .invalidOpcode)
      }
    }
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    try .init(rip: 0x1000, cs: .init(attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x13))
  }

  private func retired(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState) throws {
    state.rip = 0x1000
    let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    #expect(DoryX86Interpreter(profile: .intelCompatibleV1).step(state: &state,
      memory: memory, mode: .long64) == .retired(decoded))
  }

  private func rejected(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    profile: DoryX86CPUProfile = .intelCompatibleV1, kind: DoryX86Exception.Kind) throws {
    let before = state
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory,
      mode: .long64) == .exception(.init(kind: kind, vector: kind == .invalidOpcode ? 6 : 13,
        errorCode: kind == .invalidOpcode ? nil : 0, instructionPointer: 0x1000)))
    #expect(state == before)
  }

  private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }

  private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }
}
