import Testing

@testable import DoryDBTX86

@Suite struct DoryX86DifferentialTests {
  @Test func baselineJITAgreesWithInterpreterAtBlockBoundary() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0x48, 0x89, 0xC1,
        0x90,
      ]
      let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      let state = try DoryX86ArchitecturalState(
        rip: 0x1000,
        cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
      )

      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes,
        initialState: state,
        memory: memory,
        mode: .long64
      )
      #expect(result.compiled.tier == .baseline)
      #expect(result.jitExit == .dispatch)
      #expect(result.agrees)
      #expect(result.jitState.registers.rax == 0x1122_3344_5566_7788)
      #expect(result.jitState.registers.rcx == 0x1122_3344_5566_7788)
      #expect(result.jitState.rip == 0x100E)
    #endif
  }

  @Test func memoryIRIsRejectedInsteadOfSilentlyDiverging() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x8B, 0x00]
      let memory = DoryX86ByteArrayMemory(baseAddress: 0x2000, bytes: bytes)
      let state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x2000),
        rip: 0x2000,
        cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
      )

      #expect(throws: DoryX86DifferentialError.requiresBaselineJIT) {
        try DoryX86DifferentialHarness().compare(
          bytes: bytes,
          initialState: state,
          memory: memory,
          mode: .long64
        )
      }
    #endif
  }

  @Test func nativeRegisterALUPreservesExactX86ResultsAndFlags() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64, UInt64)] = [
        ([0x48, 0x01, 0xD8], 0x7FFF_FFFF_FFFF_FFFF, 1),
        ([0x48, 0x29, 0xD8], 0, 1),
        ([0x48, 0x21, 0xD8], 0xFF00_FF00_FF00_FF00, 0x0FF0_0FF0_0FF0_0FF0),
        ([0x48, 0x09, 0xD8], 0x8000_0000_0000_0000, 1),
        ([0x48, 0x31, 0xD8], 0xAAAA_AAAA_AAAA_AAAA, 0x5555_5555_5555_5555),
        ([0x48, 0x39, 0xD8], 0x10, 0x10),
        ([0x48, 0x85, 0xD8], 0x03, 0x01),
        ([0x01, 0xD8], 0xFFFF_FFFF_FFFF_FFFF, 1),
        ([0x48, 0x83, 0xC0, 0x01], 0xFF, 0),
      ]
      for (index, testCase) in cases.enumerated() {
        let (bytes, rax, rbx) = testCase
        let address = UInt64(0x3000 + index * 0x100)
        let memory = DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
        let state = try DoryX86ArchitecturalState(
          registers: .init(rax: rax, rbx: rbx),
          rip: address,
          rflags: [.reservedOne, .carry, .auxiliaryCarry, .direction, .interruptEnable],
          cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
        )

        let result = try DoryX86DifferentialHarness().compare(
          bytes: bytes,
          initialState: state,
          memory: memory,
          mode: .long64
        )
        #expect(result.compiled.tier == .baseline, "case \(index) fell back")
        #expect(result.agrees, "case \(index) diverged")
      }
    #endif
  }
}
