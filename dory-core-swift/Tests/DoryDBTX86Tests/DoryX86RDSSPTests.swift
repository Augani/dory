import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B, RDSSPD/RDSSPQ: NOP without CET, including preservation
// of the destination. LOCK raises #UD in all operating modes.
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86RDSSPTests {
  @Test func disabledShadowStackReadPreservesEveryDestinationAndAllOtherState() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      let encodings = mode == .long64 ? longEncodings : (0..<8).map { [0xF3, 0x0F, 0x1E, UInt8(0xC8 + $0)] }
      for bytes in encodings {
        let memory = try NoOperandMemory(bytes: bytes)
        var state = try initialState(mode: mode)
        var expected = state
        expected.rip += UInt64(bytes.count)
        let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: mode)
        #expect(decoded.operation == .noOperation)
        #expect(decoded.bytes == bytes)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
        #expect(state == expected)
      }
    }
  }

  @Test func lockAndNonRegisterFormsCannotAliasTheCETDisabledNoOperation() throws {
    let invalid: [[UInt8]] = [
      [0xF0, 0xF3, 0x48, 0x0F, 0x1E, 0xC8],
      [0xF3, 0xF0, 0x0F, 0x1E, 0xCF],
      [0x0F, 0x1E, 0xC8], [0xF2, 0x0F, 0x1E, 0xC8],
      [0xF3, 0x0F, 0x1E, 0x08], [0xF3, 0x0F, 0x1E, 0x48, 0],
      [0xF3, 0x0F, 0x1E, 0xC0], [0xF3, 0x0F, 0x1E, 0xD0],
    ]
    for bytes in invalid {
      let memory = try NoOperandMemory(bytes: bytes)
      var state = try initialState(mode: .long64)
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: state.rip)))
      #expect(state == before)
    }
  }

  @Test func bothNativeTiersPreserveRDSSPStateAndInstructionAccounting() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for bytes in longEncodings {
          let memory = try NoOperandMemory(bytes: bytes)
          var state = try initialState(mode: .long64)
          var expected = state
          expected.rip += UInt64(bytes.count)
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096, optimization: optimization)
          let result = try #require(executor.executeSummary(
            byteProvider: { Array(bytes.prefix($0)) }, at: state.rip, mode: .long64,
            addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory))
          #expect(result.guestInstructionCount == 1)
          #expect(state == expected)
        }
      }
    #endif
  }

  @Test func glibcSetjmpSequenceRetainsZeroForTheUnavailableShadowStack() throws {
    // Reduced from the pinned glibc loader's failing sequence, independent of its load address.
    let bytes: [UInt8] = [0x31, 0xC0, 0xF3, 0x48, 0x0F, 0x1E, 0xC8]
    let memory = try NoOperandMemory(bytes: bytes)
    var state = try initialState(mode: .long64)
    for _ in 0..<2 {
      guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) else {
        Issue.record("CET-disabled glibc sequence did not retire")
        return
      }
    }
    #expect(state.registers.rax == 0)
    #expect(state.rip == 0x1000 + UInt64(bytes.count))
    #expect(state.rflags.contains(.zero))
  }

  private var longEncodings: [[UInt8]] {
    (0..<16).flatMap { register in
      [false, true].map { wide in
        let rex: UInt8 = 0x40 | (wide ? 8 : 0) | (register >= 8 ? 1 : 0)
        return [0xF3, rex, 0x0F, 0x1E, UInt8(0xC8 + register % 8)]
      }
    }
  }

  private func initialState(mode: DoryX86ExecutionMode) throws -> DoryX86ArchitecturalState {
    var registers = DoryX86GeneralRegisters()
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      registers[register] = 0xABCDEF01_76543210 + UInt64(index)
    }
    return try .init(registers: registers, rip: 0x1000,
      rflags: [.reservedOne, .carry, .zero, .overflow],
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      control: .init(cr0: mode == .real16 ? 0 : 1))
  }
}

private final class NoOperandMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  init(bytes: [UInt8]) throws { backing = try .init(baseAddress: 0x1000, bytes: bytes) }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    Issue.record("RDSSP must not read an operand")
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    Issue.record("RDSSP must not write an operand")
    throw DoryX86MemoryError.unmapped(address: address, byteCount: bytes.count, access: .write)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    Issue.record("RDSSP must not preflight an operand")
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .write)
  }
  func synchronize() { Issue.record("RDSSP must not synchronize memory") }
}
