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

  @Test func nativeMemoryLoadAgreesWithInterpreter() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x8B, 0x00] + .init(repeating: 0, count: 8)
      let memory = DoryX86ByteArrayMemory(baseAddress: 0x2000, bytes: bytes)
      let state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x2000),
        rip: 0x2000,
        cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
      )

      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes,
        initialState: state,
        memory: memory,
        mode: .long64
      )
      #expect(result.compiled.tier == .baseline)
      #expect(result.compiled.requiresMemoryCallbacks)
      #expect(result.agrees)
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

  @Test func nativeConditionalBranchesHonorEveryX86ConditionCode() throws {
    #if arch(arm64)
      let operands: [(UInt64, UInt64)] = [
        (0, 0),
        (0, 1),
        (1, 0),
        (0x7FFF_FFFF_FFFF_FFFF, UInt64.max),
        (0x8000_0000_0000_0000, 1),
        (0x103, 0x100),
      ]
      for rawCondition in UInt8(0)..<UInt8(16) {
        let condition = DoryX86Condition(rawValue: rawCondition)!
        for (caseIndex, operand) in operands.enumerated() {
          let bytes: [UInt8] = [0x48, 0x39, 0xD8, 0x70 | condition.rawValue, 0x05]
          let address = UInt64(0x5000 + Int(condition.rawValue) * 0x100 + caseIndex * 0x10)
          let memory = DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
          let state = try DoryX86ArchitecturalState(
            registers: .init(rax: operand.0, rbx: operand.1),
            rip: address,
            cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
          )

          let result = try DoryX86DifferentialHarness().compare(
            bytes: bytes,
            initialState: state,
            memory: memory,
            mode: .long64
          )
          #expect(
            result.agrees,
            "condition \(condition) case \(caseIndex) diverged"
          )
        }
      }
    #endif
  }

  @Test func nativeCarryArithmeticMatchesX86CarryAndBorrowConventions() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64, UInt64, Bool)] = [
        ([0x48, 0x11, 0xD8], UInt64.max, 0, false),
        ([0x48, 0x11, 0xD8], UInt64.max, 0, true),
        ([0x48, 0x11, 0xD8], 0x7FFF_FFFF_FFFF_FFFF, 0, true),
        ([0x48, 0x19, 0xD8], 0, 0, false),
        ([0x48, 0x19, 0xD8], 0, 0, true),
        ([0x48, 0x19, 0xD8], 0x8000_0000_0000_0000, 0, true),
        ([0x11, 0xD8], 0xFFFF_FFFF, 0, true),
        ([0x19, 0xD8], 0, 0, true),
      ]
      for (index, testCase) in cases.enumerated() {
        let (bytes, rax, rbx, carry) = testCase
        let address = UInt64(0x8000 + index * 0x10)
        let memory = DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
        var flags: DoryX86RFLAGS = [.reservedOne, .direction, .interruptEnable]
        if carry { flags.insert(.carry) }
        let state = try DoryX86ArchitecturalState(
          registers: .init(rax: rax, rbx: rbx),
          rip: address,
          rflags: flags,
          cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
        )

        let result = try DoryX86DifferentialHarness().compare(
          bytes: bytes,
          initialState: state,
          memory: memory,
          mode: .long64
        )
        #expect(result.agrees, "carry case \(index) diverged")
      }
    #endif
  }

  @Test func nativeUnaryArithmeticMatchesX86FlagsAndRegisterWidths() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64, Bool)] = [
        ([0x48, 0xFF, 0xC0], 0x7FFF_FFFF_FFFF_FFFF, false),
        ([0x48, 0xFF, 0xC0], UInt64.max, true),
        ([0x48, 0xFF, 0xC8], 0x8000_0000_0000_0000, false),
        ([0x48, 0xFF, 0xC8], 0, true),
        ([0x48, 0xF7, 0xD0], 0x0123_4567_89AB_CDEF, true),
        ([0x48, 0xF7, 0xD8], 0, false),
        ([0x48, 0xF7, 0xD8], 0x8000_0000_0000_0000, true),
        ([0xFF, 0xC0], UInt64.max, true),
        ([0xF7, 0xD8], 0x8000_0000, false),
      ]
      for (index, testCase) in cases.enumerated() {
        let (bytes, rax, carry) = testCase
        let address = UInt64(0x9000 + index * 0x10)
        let memory = DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
        var flags: DoryX86RFLAGS = [
          .reservedOne, .parity, .auxiliaryCarry, .zero, .sign, .overflow, .direction,
        ]
        if carry { flags.insert(.carry) }
        let state = try DoryX86ArchitecturalState(
          registers: .init(rax: rax),
          rip: address,
          rflags: flags,
          cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
        )

        let result = try DoryX86DifferentialHarness().compare(
          bytes: bytes,
          initialState: state,
          memory: memory,
          mode: .long64
        )
        #expect(result.agrees, "unary case \(index) diverged")
      }
    #endif
  }

  @Test func nativeEffectiveAddressesHandleScaledAndRIPRelativeForms() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64, UInt64)] = [
        ([0x48, 0x8D, 0x44, 0x8B, 0xF0], 0x1000, 3),
        ([0x48, 0x8D, 0x05, 0x34, 0x12, 0x00, 0x00], 0, 0),
        ([0x67, 0x48, 0x8D, 0x04, 0x8B], 0xFFFF_FFFF_0000_1000, 3),
      ]
      for (index, testCase) in cases.enumerated() {
        let (bytes, rbx, rcx) = testCase
        let address = UInt64(0xA000 + index * 0x100)
        let memory = DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
        let state = try DoryX86ArchitecturalState(
          registers: .init(rcx: rcx, rbx: rbx),
          rip: address,
          cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
        )

        let result = try DoryX86DifferentialHarness().compare(
          bytes: bytes,
          initialState: state,
          memory: memory,
          mode: .long64
        )
        #expect(result.agrees, "effective-address case \(index) diverged")
      }
    #endif
  }
}
