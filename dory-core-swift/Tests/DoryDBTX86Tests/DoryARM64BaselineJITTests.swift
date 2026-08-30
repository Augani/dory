import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64BaselineJITTests {
  @Test func emitsDeterministicARM64ForRegisterImmediateMoves() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x90],
      at: 0x1000,
      mode: .long64
    )
    let emitter = DoryARM64BaselineEmitter()
    let first = emitter.compile(block)
    let second = emitter.compile(block)

    #expect(first == second)
    #expect(first.tier == .baseline)
    #expect(first.exitCode == .dispatch)
    #expect(first.machineWords.last == 0xD65F_03C0)
    #expect(first.machineBytes.count == first.machineWords.count * 4)
  }

  @Test func unsupportedIRProducesAClosedInterpreterFallbackStub() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x48, 0x8B, 0x00],
      at: 0x2000,
      mode: .long64
    )
    let compiled = DoryARM64BaselineEmitter().compile(block)

    #expect(compiled.tier == .interpreterFallback)
    #expect(compiled.exitCode == .interpreter)
    #expect(compiled.machineWords.last == 0xD65F_03C0)
  }

  @Test func boundedCacheEvictsAndInvalidatesDeterministically() throws {
    let emitter = DoryARM64BaselineEmitter()
    let translator = DoryX86IRTranslator()
    let first = emitter.compile(try translator.translate([0x90], at: 0x1000, mode: .long64))
    let second = emitter.compile(try translator.translate([0x90], at: 0x2000, mode: .long64))
    let capacity = first.machineBytes.count + second.machineBytes.count - 1
    let cache = DoryJITCodeCache(maximumBytes: capacity)
    let firstKey = DoryJITBlockKey(guestStart: 0x1000, addressSpaceID: 7, codeGeneration: 1)
    let secondKey = DoryJITBlockKey(guestStart: 0x2000, addressSpaceID: 7, codeGeneration: 1)

    cache.insert(first, for: firstKey)
    cache.insert(second, for: secondKey)
    #expect(cache.block(for: firstKey) == nil)
    #expect(cache.block(for: secondKey) == second)
    cache.invalidate(addressSpaceID: 7, guestRange: 0x1fff..<0x2001)
    #expect(cache.residentBlockCount == 0)
    #expect(cache.residentByteCount == 0)
  }

  @Test func publishesAndExecutesThroughTheGuardedMAPJITRegion() throws {
    #if arch(arm64)
      let block = try DoryX86IRTranslator().translate(
        [0x48, 0xB8, 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0],
        at: 0x4000,
        mode: .long64
      )
      let compiled = DoryARM64BaselineEmitter().compile(block)
      let region = try DoryJITExecutableRegion(minimumCapacity: 4096)
      try region.publish(compiled, at: 0)
      var context = [UInt64](repeating: 0, count: DoryJITExecutableRegion.contextWordCount)

      let exit = try region.execute(at: 0, context: &context)
      #expect(exit == .dispatch)
      #expect(context[0] == 0x1234_5678)
      #expect(context[16] == 0x400A)
    #endif
  }

  @Test func boundedExecutorRecompilesChangedGuestCode() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(rip: 0x5000)
      let first = try #require(
        executor.execute(
          bytes: [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 7,
          maximumInstructions: 1,
          state: &state
        )
      )
      #expect(first.block.guestInstructionCount == 1)
      #expect(state.registers.rax == 1)
      #expect(state.rip == 0x500A)

      state.rip = 0x5000
      let second = try #require(
        executor.execute(
          bytes: [0x48, 0xB8, 2, 0, 0, 0, 0, 0, 0, 0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 7,
          maximumInstructions: 1,
          state: &state
        )
      )
      #expect(second.block.guestInstructionCount == 1)
      #expect(state.registers.rax == 2)
      #expect(executor.residentBlockCount == 2)
    #endif
  }
}
