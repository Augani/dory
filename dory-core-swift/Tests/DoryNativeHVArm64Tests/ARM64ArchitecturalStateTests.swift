import Foundation
import Testing

@testable import DoryNativeHVArm64

@Suite struct ARM64ArchitecturalStateTests {
  @Test func resetStateHasExactVersionedArchitecturalShape() throws {
    let state = try DoryARM64ArchitecturalState.reset(
      programCounter: 0x8000_0000,
      x0: 0x8100_0000
    )
    #expect(state.schemaVersion == 1)
    #expect(state.generalRegisters.count == 31)
    #expect(state.generalRegisters[0] == 0x8100_0000)
    #expect(state.programCounter == 0x8000_0000)
    #expect(state.currentProgramStatus == 0x3c5)
    #expect(state.simdRegisters.count == 32)
    #expect(
      state.systemRegisters.map(\.register) == DoryARM64ArchitecturalState.requiredSystemRegisters)
  }

  @Test func rejectsPartialOrNoncanonicalRegisterBanks() throws {
    let reset = try DoryARM64ArchitecturalState.reset(programCounter: 0)
    #expect(throws: DoryARM64ArchitecturalStateError.invalidGeneralRegisterCount(actual: 30)) {
      try DoryARM64ArchitecturalState(
        generalRegisters: Array(reset.generalRegisters.dropLast()),
        programCounter: 0,
        floatingPointControl: 0,
        floatingPointStatus: 0,
        currentProgramStatus: 0,
        simdRegisters: reset.simdRegisters,
        systemRegisters: reset.systemRegisters,
        irqPending: false,
        fiqPending: false,
        virtualTimerMasked: false
      )
    }

    #expect(
      throws: DoryARM64ArchitecturalStateError.invalidSystemRegisterSet(
        expected: DoryARM64ArchitecturalState.requiredSystemRegisters,
        actual: Array(DoryARM64ArchitecturalState.requiredSystemRegisters.dropFirst())
      )
    ) {
      try DoryARM64ArchitecturalState(
        generalRegisters: reset.generalRegisters,
        programCounter: 0,
        floatingPointControl: 0,
        floatingPointStatus: 0,
        currentProgramStatus: 0,
        simdRegisters: reset.simdRegisters,
        systemRegisters: Array(reset.systemRegisters.dropFirst()),
        irqPending: false,
        fiqPending: false,
        virtualTimerMasked: false
      )
    }
  }

  @Test func decoderRejectsObsoleteSchemaAndRoundTripIsDeterministic() throws {
    let state = try DoryARM64ArchitecturalState.reset(programCounter: 0x1000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(state)
    let decoded = try JSONDecoder().decode(DoryARM64ArchitecturalState.self, from: encoded)
    #expect(decoded == state)
    #expect(try encoder.encode(decoded) == encoded)

    let obsolete = String(decoding: encoded, as: UTF8.self)
      .replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
    #expect(throws: DoryARM64ArchitecturalStateError.unsupportedSchemaVersion(2)) {
      try JSONDecoder().decode(DoryARM64ArchitecturalState.self, from: Data(obsolete.utf8))
    }
  }

  @Test func serializedStateContainsNoHostOrTranslatorAuthority() throws {
    let encoded = try JSONEncoder().encode(
      try DoryARM64ArchitecturalState.reset(programCounter: 0x1000)
    )
    let json = String(decoding: encoded, as: UTF8.self)
    for forbidden in ["hostPointer", "hv_vcpu", "jit", "translated", "codeCache"] {
      #expect(!json.contains(forbidden))
    }
  }
}
