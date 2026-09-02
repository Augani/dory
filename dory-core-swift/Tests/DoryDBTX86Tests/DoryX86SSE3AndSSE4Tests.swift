import Foundation
import Testing

@testable import DoryDBTX86

/// Decode and execute coverage for the SSE3/SSSE3/SSE4.1 vector instructions that
/// real x86_64 system libraries exercise: the `0F 12`/`0F 16` half-move and
/// duplication family and the `0F 38`/`0F 3A` three-byte opcode map entries
/// (`PSHUFB`, `PALIGNR`, `PTEST`, `PMOVZXDQ`, `PMOVSXDQ`).
@Suite struct DoryX86SSE3AndSSE4Tests {
  private let decoder = DoryX86Decoder()
  private let interpreter = DoryX86Interpreter()

  private func state(
    rip: UInt64 = 0x1000,
    configuring: (inout DoryX86FloatingPointState) throws -> Void
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState()
    try configuring(&floatingPoint)
    return try DoryX86ArchitecturalState(rip: rip, floatingPoint: floatingPoint)
  }

  private func ymmBytes(_ index: Int, in state: DoryX86ArchitecturalState) -> [UInt8] {
    Array(state.floatingPoint.ymm[index].bytes.prefix(16))
  }

  /// Builds a `[UInt8]` from one or more integer ranges, for expected-vector
  /// comparisons against `ymmBytes`.
  private func bytes(_ ranges: Range<Int>...) -> [UInt8] {
    ranges.flatMap { $0 }.map { UInt8($0) }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult) {
    guard case .retired = result else {
      Issue.record("instruction did not retire: \(result)")
      return
    }
  }

  // MARK: - 0F 12 / 0F 16 half-move and duplication family

  @Test func movhlpsMovesSourceHighIntoDestinationLow() throws {
    // 0F 12 C8: MOVHLPS xmm1, xmm0 — high 64 of xmm0 -> low 64 of xmm1.
    let instruction = try decoder.decode([0x0F, 0x12, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .moveVectorQwordHalf(
          destination: .register(1), source: .register(0),
          sourceHigh: true, destinationHigh: false))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(bytes: Array(32..<64), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x0F, 0x12, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // Destination low 64 becomes source high 64 (bytes 8...15); high 64 preserved (40...47).
    #expect(ymmBytes(1, in: current) == bytes(8..<16, 40..<48))
  }

  @Test func movlhpsMovesSourceLowIntoDestinationHigh() throws {
    // 0F 16 C8: MOVLHPS xmm1, xmm0 — low 64 of xmm0 -> high 64 of xmm1.
    let instruction = try decoder.decode([0x0F, 0x16, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .moveVectorQwordHalf(
          destination: .register(1), source: .register(0),
          sourceHigh: false, destinationHigh: true))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(bytes: Array(32..<64), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x0F, 0x16, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // Destination low 64 preserved (32...39); high 64 becomes source low 64 (0...7).
    #expect(ymmBytes(1, in: current) == bytes(32..<40, 0..<8))
  }

  @Test func movddupBroadcastsLow64AcrossBothHalves() throws {
    // F2 0F 12 C8: MOVDDUP xmm1, xmm0 — low 64 of xmm0 into both halves of xmm1.
    let instruction = try decoder.decode(
      [0xF2, 0x0F, 0x12, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .duplicateVectorScalar(destination: 1, source: .register(0), mode: .doubleLow64))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF2, 0x0F, 0x12, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(ymmBytes(1, in: current) == bytes(0..<8, 0..<8))
  }

  @Test func movsldupDuplicatesLowSingleOfEachDwordPair() throws {
    // F3 0F 12 C8: MOVSLDUP xmm1, xmm0.
    let instruction = try decoder.decode(
      [0xF3, 0x0F, 0x12, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .duplicateVectorScalar(destination: 1, source: .register(0), mode: .singleLow32))

    var current = try state { floatingPoint in
      // Distinct dword lanes so duplication is observable: dwords 0,1,2,3 = 0x10..0x13 etc.
      floatingPoint.ymm[0] = try .init(
        bytes: [0x10, 0x11, 0x12, 0x13, 0x20, 0x21, 0x22, 0x23,
                0x30, 0x31, 0x32, 0x33, 0x40, 0x41, 0x42, 0x43]
          + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF3, 0x0F, 0x12, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let low: [UInt8] = [0x10, 0x11, 0x12, 0x13]
    let high: [UInt8] = [0x30, 0x31, 0x32, 0x33]
    let expected = low + low + high + high
    #expect(ymmBytes(1, in: current) == expected)
  }

  @Test func movshdupDuplicatesHighSingleOfEachDwordPair() throws {
    // F3 0F 16 C8: MOVSHDUP xmm1, xmm0.
    let instruction = try decoder.decode(
      [0xF3, 0x0F, 0x16, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .duplicateVectorScalar(destination: 1, source: .register(0), mode: .singleHigh32))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: [0x10, 0x11, 0x12, 0x13, 0x20, 0x21, 0x22, 0x23,
                0x30, 0x31, 0x32, 0x33, 0x40, 0x41, 0x42, 0x43]
          + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF3, 0x0F, 0x16, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let a: [UInt8] = [0x20, 0x21, 0x22, 0x23]
    let b: [UInt8] = [0x40, 0x41, 0x42, 0x43]
    let expected = a + a + b + b
    #expect(ymmBytes(1, in: current) == expected)
  }

  @Test func movlpsMemoryLoadsLow64PreservingDestinationHigh() throws {
    // 0F 12 0B: MOVLPS xmm1, [rbx] — 8 bytes from memory -> low 64 of xmm1.
    let instruction = try decoder.decode(
      [0x0F, 0x12, 0x0B], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .moveVectorQwordHalf(
          destination: .register(1), source: .memory(.init(base: .rbx, width: .quadword)),
          sourceHigh: false, destinationHigh: false))

    var registers = DoryX86GeneralRegisters()
    registers.rbx = 0x2000
    var current = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x1000,
      floatingPoint: {
        var fp = try DoryX86FloatingPointState()
        fp.ymm[1] = try .init(bytes: Array(32..<64), expectedByteCount: 32)
        return fp
      }()
    )
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x0F, 0x12, 0x0B] + .init(repeating: 0, count: 0x1100))
    // Place 8 distinct bytes at 0x2000.
    try memory.write(at: 0x2000, bytes: bytes(100..<108))
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(ymmBytes(1, in: current) == bytes(100..<108, 40..<48))
  }

  // MARK: - 0F 38 / 0F 3A three-byte opcode map

  @Test func pshufbShufflesBytesAndZeroesHighBitLanes() throws {
    // 66 0F 38 00 C8: PSHUFB xmm1, xmm0.
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x00, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .shufflePackedBytes(destination: 1, source: .register(0)))

    var current = try state { floatingPoint in
      // Destination table = 0..15. Source indices: 15, 0, 0x80(zero), 1, ...
      var indices = [UInt8](repeating: 0, count: 16)
      indices[0] = 15
      indices[1] = 0
      indices[2] = 0x80
      indices[3] = 1
      floatingPoint.ymm[0] = try .init(
        bytes: indices + Array(repeating: 0, count: 16), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(bytes: bytes(0..<16, 0..<16), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x00, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lanes = ymmBytes(1, in: current)
    #expect(lanes[0] == 15)       // index 15 -> table[15]
    #expect(lanes[1] == 0)        // index 0 -> table[0]
    #expect(lanes[2] == 0)        // high bit set -> zero
    #expect(lanes[3] == 1)        // index 1 -> table[1]
  }

  @Test func palignrConcatenatesAndExtractsAtImmediate() throws {
    // 66 0F 3A 0F C8 02: PALIGNR xmm1, xmm0, 2.
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x3A, 0x0F, 0xC8, 0x02], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .alignPackedBytes(destination: 1, source: .register(0), count: 2))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: bytes(0..<16) + Array(repeating: 0, count: 16), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(
        bytes: bytes(16..<32) + Array(repeating: 0, count: 16), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x3A, 0x0F, 0xC8, 0x02])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // combined = source(0..15) + destination(16..31); extract 16 bytes at offset 2.
    let combined: [UInt8] = bytes(0..<16, 16..<32)
    #expect(ymmBytes(1, in: current) == Array(combined[2..<18]))
  }

  @Test func pmovzxdqZeroExtendsTwoDoublewords() throws {
    // 66 0F 38 35 C8: PMOVZXDQ xmm1, xmm0.
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x35, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .extendPackedDwordToQword(destination: 1, source: .register(0), signed: false))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: [0x01, 0x02, 0x03, 0x80, 0x05, 0x06, 0x07, 0x90]
          + Array(repeating: 0, count: 24),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x35, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(
      ymmBytes(1, in: current)
        == [0x01, 0x02, 0x03, 0x80, 0, 0, 0, 0, 0x05, 0x06, 0x07, 0x90, 0, 0, 0, 0])
  }

  @Test func pmovsxdqSignExtendsTwoDoublewords() throws {
    // 66 0F 38 25 C8: PMOVSXDQ xmm1, xmm0.
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x25, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .extendPackedDwordToQword(destination: 1, source: .register(0), signed: true))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: [0x01, 0x02, 0x03, 0x80, 0x05, 0x06, 0x07, 0x10]
          + Array(repeating: 0, count: 24),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x25, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // First dword 0x80030201 is negative -> sign-extended with 0xFF bytes.
    // Second dword 0x10070505 is positive -> zero-extended.
    #expect(
      ymmBytes(1, in: current)
        == [0x01, 0x02, 0x03, 0x80, 0xFF, 0xFF, 0xFF, 0xFF,
            0x05, 0x06, 0x07, 0x10, 0, 0, 0, 0])
  }

  @Test func ptestSetsZeroAndCarryFlagsWithoutMutatingDestination() throws {
    // 66 0F 38 17 C8: PTEST xmm1, xmm0.
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x17, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .testPackedBits(destination: 1, source: .register(0)))

    var current = try state { floatingPoint in
      // DEST = all ones, SRC = all ones: (DEST AND SRC) != 0 -> ZF=0;
      // ((NOT DEST) AND SRC) == 0 -> CF=1.
      floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xFF, count: 32), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(
        bytes: Array(repeating: 0xFF, count: 32), expectedByteCount: 32)
    }
    let destinationBefore = ymmBytes(1, in: current)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x17, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(ymmBytes(1, in: current) == destinationBefore)  // destination unchanged
    #expect(!current.rflags.contains(.zero))
    #expect(current.rflags.contains(.carry))
  }

  @Test func ptestReportsAllZeroWhenOperandsAreDisjoint() throws {
    // DEST and SRC share no set bits: (DEST AND SRC) == 0 -> ZF=1;
    // ((NOT DEST) AND SRC) == SRC != 0 -> CF=0.
    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0x0F, count: 32), expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(
        bytes: Array(repeating: 0xF0, count: 32), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x17, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(current.rflags.contains(.zero))
    #expect(!current.rflags.contains(.carry))
  }

  // MARK: - Additional SSE4.1 instructions from broad binary audit

  @Test func pcmpeqqComparesPackedQwordsForEquality() throws {
    // 66 0F 38 29 C8: PCMPEQQ xmm1, xmm0
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x29, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .comparePackedQwords(destination: 1, source: .register(0)))

    var current = try state { floatingPoint in
      // Lane 0: equal (both 0x1122334455667788). Lane 1: different.
      var bytes0 = [UInt8](repeating: 0, count: 32)
      bytes0.replaceSubrange(0..<8, with: [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
      bytes0.replaceSubrange(8..<16, with: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
      floatingPoint.ymm[0] = try .init(bytes: bytes0, expectedByteCount: 32)
      var bytes1 = [UInt8](repeating: 0, count: 32)
      bytes1.replaceSubrange(0..<8, with: [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
      bytes1.replaceSubrange(8..<16, with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
      floatingPoint.ymm[1] = try .init(bytes: bytes1, expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x29, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lanes = ymmBytes(1, in: current)
    // Lane 0 equal -> all FF. Lane 1 different -> all 00.
    #expect(Array(lanes[0..<8]) == Array(repeating: 0xFF, count: 8))
    #expect(Array(lanes[8..<16]) == Array(repeating: 0, count: 8))
  }

  @Test func pmovsxbqSignExtendsTwoBytesToTwoQuadwords() throws {
    // 66 0F 38 22 C8: PMOVSXBQ xmm1, xmm0
    let instruction = try decoder.decode(
      [0x66, 0x0F, 0x38, 0x22, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .extendPackedByteToQword(destination: 1, source: .register(0), signed: true))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: [0x7F, 0x80] + Array(repeating: 0, count: 30),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x0F, 0x38, 0x22, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lanes = ymmBytes(1, in: current)
    // 0x7F is positive -> zero-extended. 0x80 is negative -> sign-extended.
    #expect(Array(lanes[0..<8]) == [0x7F, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(lanes[8..<16]) == [0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
  }

  @Test func pinsrqInsertsQwordFromGPRIntoLane0() throws {
    // 66 48 0F 3A 22 C0 00: PINSRQ xmm0, rax, 0
    let instruction = try decoder.decode(
      [0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x00], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .insertPackedQword(
          destination: 0, source: .register(.rax, width: .quadword), index: 0))

    var registers = DoryX86GeneralRegisters()
    registers.rax = 0x1122_3344_5566_7788
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    current.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0xAA, count: 32), expectedByteCount: 32)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x00])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lanes = ymmBytes(0, in: current)
    // Lane 0 should be the value, lane 1 preserved (0xAA bytes).
    #expect(Array(lanes[0..<8]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
    #expect(Array(lanes[8..<16]) == Array(repeating: 0xAA, count: 8))
  }

  @Test func pinsrqInsertsQwordFromGPRIntoLane1() throws {
    // 66 48 0F 3A 22 C0 01: PINSRQ xmm0, rax, 1
    let instruction = try decoder.decode(
      [0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x01], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .insertPackedQword(
          destination: 0, source: .register(.rax, width: .quadword), index: 1))

    var registers = DoryX86GeneralRegisters()
    registers.rax = 0x1122_3344_5566_7788
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    current.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0xAA, count: 32), expectedByteCount: 32)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x01])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lanes = ymmBytes(0, in: current)
    // Lane 0 preserved (0xAA), lane 1 should be the value.
    #expect(Array(lanes[0..<8]) == Array(repeating: 0xAA, count: 8))
    #expect(Array(lanes[8..<16]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
  }
}
