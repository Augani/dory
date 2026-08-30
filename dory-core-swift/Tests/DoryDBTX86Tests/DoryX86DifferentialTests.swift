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
}
