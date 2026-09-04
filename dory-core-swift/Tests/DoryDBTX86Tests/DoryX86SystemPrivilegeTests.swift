import Testing

@testable import DoryDBTX86

@Suite struct DoryX86SystemPrivilegeTests {
  private func state(mode: DoryX86ExecutionMode, selector: UInt16) throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000,
      cs: .init(selector: selector, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max)
    )
  }

  @Test func haltFaultsPreciselyOutsideRingZero() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for selector: UInt16 in [1, 2, 3] {
        var state = try state(mode: mode, selector: selector)
        let before = state
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF4])
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
        #expect(state == before)
      }
    }
  }

  @Test func haltDistinguishesRealAndVirtual8086Modes() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF4])
    var real = try state(mode: .real16, selector: 3)
    guard case .halted = DoryX86Interpreter().step(state: &real, memory: memory, mode: .real16) else {
      Issue.record("HLT must work in real mode regardless of selector low bits")
      return
    }
    #expect(real.rip == 0x1001)
    var virtual = try state(mode: .protected16, selector: 0)
    virtual.rflags.insert(.virtual8086)
    let before = virtual
    #expect(DoryX86Interpreter().step(state: &virtual, memory: memory, mode: .protected16)
      == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
    #expect(virtual == before)
  }

  @Test func swapGSChecksModeBeforePrivilege() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for selector: UInt16 in [0, 3] {
        var state = try state(mode: mode, selector: selector)
        state.gs.base = 0x1234
        state.modelSpecific.gsBase = 0x1234
        state.modelSpecific.kernelGSBase = 0x5678
        let before = state
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x0F, 0x01, 0xF8])
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        if mode != .long64 {
          #expect(result == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
          #expect(state == before)
        } else if selector != 0 {
          #expect(result == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
          #expect(state == before)
        } else {
          guard case .retired = result else { Issue.record("Ring-zero SWAPGS faulted"); continue }
          #expect(state.gs.base == 0x5678)
          #expect(state.modelSpecific.kernelGSBase == 0x1234)
        }
      }
    }
  }

  @Test func nativeHaltCannotReuseRingZeroCodeAtUserPrivilege() throws {
    #if arch(arm64)
      for optimization: DoryARM64JITOptimization in [.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096, optimization: optimization)
        var kernel = try state(mode: .long64, selector: 0)
        #expect(try executor.execute(
          bytes: [0xF4], at: 0x1000, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &kernel)?.exitCode == .halt)
        for selector: UInt16 in [1, 2, 3] {
          var user = try state(mode: .long64, selector: selector)
          let before = user
          for _ in 0..<2 {
            #expect(try executor.execute(
              bytes: [0xF4], at: 0x1000, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &user) == nil)
            #expect(user == before)
          }
        }
        var virtual = try state(mode: .protected32, selector: 0)
        virtual.rflags.insert(.virtual8086)
        let before = virtual
        #expect(try executor.executeChainedSummary(
          byteProvider: { _, _ in [0xF4] }, at: 0x1000, mode: .protected32,
          addressSpaceID: 0, maximumInstructions: 1, state: &virtual) == nil)
        #expect(virtual == before)
      }
    #endif
  }
}
