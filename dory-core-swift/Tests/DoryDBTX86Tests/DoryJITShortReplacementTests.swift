import Testing
@testable import DoryDBTX86

@Suite struct DoryJITShortReplacementTests {
  @Test func shorterReplacementAtSameAddressRecompilesWithoutStaleExecution() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096, optimization: optimization)
        let original: [UInt8] = [0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
        var state = try DoryX86ArchitecturalState(rip: 0x1000)
        _ = try #require(executor.execute(bytes: original, at: 0x1000, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state))
        #expect(state.registers.rax == 0x1122_3344_5566_7788)
        state = try DoryX86ArchitecturalState(registers: .init(rax: 37), rip: 0x1000)
        _ = try #require(executor.execute(bytes: [0x90], at: 0x1000, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state))
        #expect(state.registers.rax == 37)
        #expect(state.rip == 0x1001)
        state = try DoryX86ArchitecturalState(registers: .init(rax: 42), rip: 0x1000)
        let before = state
        #expect(try executor.execute(bytes: [0x48, 0xB8], at: 0x1000, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state) == nil)
        #expect(state == before)
      }
    #endif
  }
}
