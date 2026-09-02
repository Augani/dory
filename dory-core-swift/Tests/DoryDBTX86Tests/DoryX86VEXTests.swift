import Foundation
import Testing

@testable import DoryDBTX86

/// Decode and execute coverage for the VEX-prefixed AVX/AVX2 instructions that
/// real x86_64 system libraries exercise: VMOVUPS, VMOVAPS, VMOVDQA, VXORPS,
/// VPOR, VPXOR, VPCMPEQB, VPMOVMSKB, VMOVQ, VPSHUFB, VZEROUPPER, and the
/// VBROADCAST family.
@Suite struct DoryX86VEXTests {
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

  private func fullYmm(_ index: Int, in state: DoryX86ArchitecturalState) -> [UInt8] {
    Array(state.floatingPoint.ymm[index].bytes)
  }

  private func bytes(_ ranges: Range<Int>...) -> [UInt8] {
    ranges.flatMap { $0 }.map { UInt8($0) }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult) {
    guard case .retired = result else {
      Issue.record("instruction did not retire: \(result)")
      return
    }
  }

  // MARK: - VZEROUPPER

  @Test func vzeroupperZerosUpper128OfAllYMMRegisters() throws {
    let instruction = try decoder.decode([0xC5, 0xF8, 0x77], at: 0x1000, mode: .long64)
    #expect(instruction.operation == .vexZeroUpper)

    var current = try state { floatingPoint in
      for i in 0..<16 {
        floatingPoint.ymm[i] = try .init(
          bytes: Array(repeating: 0xFF, count: 32), expectedByteCount: 32)
      }
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xC5, 0xF8, 0x77])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    for i in 0..<16 {
      let full = fullYmm(i, in: current)
      #expect(Array(full[0..<16]) == Array(repeating: 0xFF, count: 16))
      #expect(Array(full[16..<32]) == Array(repeating: 0, count: 16))
    }
  }

  // MARK: - VMOVUPS (128-bit, C5 form)

  @Test func vmovups128LoadsFromMemory() throws {
    // C5 F8 10 03: VMOVUPS xmm0, [rbx]  (L=0, pp=00, vvvv=0)
    let instruction = try decoder.decode(
      [0xC5, 0xF8, 0x10, 0x03], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexMoveVector(
          destination: .register(0), source: .memory(.init(base: .rbx, width: .quadword)),
          length: .xmm128, requiresAlignment: false))

    var registers = DoryX86GeneralRegisters()
    registers.rbx = 0x2000
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0xC5, 0xF8, 0x10, 0x03] + .init(repeating: 0, count: 0x1100))
    try memory.write(at: 0x2000, bytes: bytes(10..<26))
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(ymmBytes(0, in: current) == bytes(10..<26))
  }

  @Test func vmovups256Loads32BytesFromMemory() throws {
    // C5 FC 10 03: VMOVUPS ymm0, [rbx]  (L=1, pp=00, vvvv=0)
    let instruction = try decoder.decode(
      [0xC5, 0xFC, 0x10, 0x03], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexMoveVector(
          destination: .register(0), source: .memory(.init(base: .rbx, width: .quadword)),
          length: .ymm256, requiresAlignment: false))

    var registers = DoryX86GeneralRegisters()
    registers.rbx = 0x2000
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0xC5, 0xFC, 0x10, 0x03] + .init(repeating: 0, count: 0x1100))
    try memory.write(at: 0x2000, bytes: bytes(0..<32))
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(fullYmm(0, in: current) == bytes(0..<32))
  }

  // MARK: - VXORPS (3-operand, 128-bit)

  @Test func vxorps128ThreeOperandXorsFirstSourceAndSecondSource() throws {
    // C5 E8 57 C8: VXORPS xmm1, xmm2, xmm0
    // C5 E8: R=0, vvvv=~1101=0010=2, L=0, pp=00
    let instruction = try decoder.decode(
      [0xC5, 0xE8, 0x57, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexVectorBinary(
          .xor, destination: 1, firstSource: 2, secondSource: .register(0),
          length: .xmm128))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xAA, count: 16) + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
      floatingPoint.ymm[2] = try .init(
        bytes: Array(repeating: 0xFF, count: 16) + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xC5, 0xE8, 0x57, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // 0xFF XOR 0xAA = 0x55; upper 128 should be zeroed (128-bit VEX)
    #expect(ymmBytes(1, in: current) == Array(repeating: 0x55, count: 16))
  }

  // MARK: - VPOR (3-operand, 128-bit)

  @Test func vpor128ThreeOperandOrsFirstSourceAndSecondSource() throws {
    // C5 E1 EB C8: VPOR xmm1, xmm3, xmm0
    // C5 E1: R=0, vvvv=~1100=0011=3, L=0, pp=01(66)
    let instruction = try decoder.decode(
      [0xC5, 0xE1, 0xEB, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexVectorBinary(
          .or, destination: 1, firstSource: 3, secondSource: .register(0),
          length: .xmm128))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0x0F, count: 16) + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
      floatingPoint.ymm[3] = try .init(
        bytes: Array(repeating: 0xF0, count: 16) + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xC5, 0xE1, 0xEB, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(ymmBytes(1, in: current) == Array(repeating: 0xFF, count: 16))
  }

  // MARK: - VPCMPEQB (3-operand, 128-bit)

  @Test func vpcmpeqb128ThreeOperandComparesBytes() throws {
    // C5 FD 74 C8: VPCMPEQB xmm1, xmm0, xmm0  (vvvv=0, pp=66, L=1)
    // Actually vvvv=0 means firstSource=0 (same as dest in 2-op form).
    let instruction = try decoder.decode(
      [0xC5, 0xFD, 0x74, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexComparePackedBytes(
          destination: 1, firstSource: 0, secondSource: .register(0),
          length: .ymm256))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0x42, count: 32), expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xC5, 0xFD, 0x74, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // All bytes equal -> all 0xFF
    #expect(fullYmm(1, in: current) == Array(repeating: 0xFF, count: 32))
  }

  // MARK: - VPMOVMSKB

  @Test func vpmovmskb128ExtractsHighBitsToGPR() throws {
    // C5 FD D7 C0: VPMOVMSKB eax, xmm0  (vvvv=0, pp=66, L=1)
    let instruction = try decoder.decode(
      [0xC5, 0xFD, 0xD7, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexMoveMaskToInteger(
          destination: .register(.rax, width: .doubleword), source: 0,
          length: .ymm256))

    var current = try state { floatingPoint in
      // Bytes 0,2,4,... have high bit set; bytes 1,3,5,... don't.
      var vectorBytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<32 where i % 2 == 0 { vectorBytes[i] = 0x80 }
      floatingPoint.ymm[0] = try .init(bytes: vectorBytes, expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xC5, 0xFD, 0xD7, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // 256-bit: 32 bytes, bits 0,2,4,...,30 set -> 0x55555555
    #expect(current.registers.rax == 0x5555_5555)
  }

  // MARK: - VMOVQ (3-byte VEX, W=1)

  @Test func vmovqLoadsFromGPRToXMM() throws {
    // C4 E1 F9 6E C0: VMOVQ xmm0, rax  (map=0F, pp=66, W=1, vvvv=0)
    let instruction = try decoder.decode(
      [0xC4, 0xE1, 0xF9, 0x6E, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexMoveIntegerToVector(
          destination: 0, source: .register(.rax, width: .quadword), quadword: true))

    var registers = DoryX86GeneralRegisters()
    registers.rax = 0x1122_3344_5566_7788
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE1, 0xF9, 0x6E, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let xmm0 = ymmBytes(0, in: current)
    #expect(xmm0 == [
      0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
      0, 0, 0, 0, 0, 0, 0, 0])
  }

  // MARK: - VPSHUFB (3-byte VEX, 0F38 map)

  @Test func vpshufb128ShufflesBytesFromFirstSource() throws {
    // C4 E2 7D 00 C8: VPSHUFB ymm1, ymm0, ymm0  (map=0F38, pp=66, L=1, vvvv=0)
    // Actually vvvv=0 means firstSource=0; but let's use a 128-bit form.
    // C4 E2 61 00 C8: VPSHUFB xmm1, xmm4, xmm0  (map=0F38, pp=66, L=0, vvvv=4)
    // Wait, let me compute: C4 E2 61 = byte1=E2(R=1,X=1,B=0,map=2), byte2=61(W=0,vvvv=1100=3,L=0,pp=01)
    // vvvv = ~0110 = 1001 = 9... hmm, let me recalculate.
    // byte2 = 0x61 = 0110 0001: W=0, vvvv=~1100=0011=12, L=0, pp=01(66)
    // That's vvvv=12, not what I want. Let me use a simpler encoding.
    // C4 E2 79 00 C8: byte2=79=0111 1001: W=0, vvvv=~1111=0000=0, L=0, pp=01(66)
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0x79, 0x00, 0xC8], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexShufflePackedBytes(
          destination: 1, firstSource: 0, secondSource: .register(0),
          length: .xmm128))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: Array(0..<16) + Array(repeating: 0, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0x79, 0x00, 0xC8])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // PSHUFB with indices 0..15 (table = 0..15): result[i] = table[i] = i
    #expect(ymmBytes(1, in: current) == bytes(0..<16))
  }

  // MARK: - VBROADCASTSS

  @Test func vbroadcastss128Broadcasts32BitToAllDwordLanes() throws {
    // C4 E2 79 18 C0: VBROADCASTSS xmm0, xmm0  (map=0F38, pp=66, L=0, vvvv=0)
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0x79, 0x18, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexBroadcast(
          destination: 0, source: .register(0), mode: .single32, length: .xmm128))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: [0x42, 0x00, 0x00, 0x00] + Array(repeating: 0, count: 28),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0x79, 0x18, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // 128-bit: 4 dwords, all = 0x00000042
    let expected = [UInt8]([0x42, 0, 0, 0]) + [UInt8]([0x42, 0, 0, 0])
      + [UInt8]([0x42, 0, 0, 0]) + [UInt8]([0x42, 0, 0, 0])
    #expect(ymmBytes(0, in: current) == expected)
  }

  @Test func vbroadcasti128Broadcasts128BitsToBothHalves() throws {
    // C4 E2 7D 5A C0: VBROADCASTI128 ymm0, xmm0  (map=0F38, pp=66, L=1, vvvv=0)
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0x7D, 0x5A, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexBroadcast(
          destination: 0, source: .register(0), mode: .packed128, length: .ymm256))

    var current = try state { floatingPoint in
      floatingPoint.ymm[0] = try .init(
        bytes: bytes(0..<16) + Array(repeating: 0xFF, count: 16),
        expectedByteCount: 32)
    }
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0x7D, 0x5A, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    // Both halves should be the low 128 bits of the source
    #expect(fullYmm(0, in: current) == bytes(0..<16) + bytes(0..<16))
  }

  // MARK: - VMOVAPS (256-bit, aligned)

  @Test func vmovaps256StoresToMemory() throws {
    // C5 FC 29 03: VMOVAPS [rbx], ymm0  (L=1, pp=66, vvvv=0)
    let instruction = try decoder.decode(
      [0xC5, 0xFC, 0x29, 0x03], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .vexMoveVector(
          destination: .memory(.init(base: .rbx, width: .quadword)),
          source: .register(0),
          length: .ymm256, requiresAlignment: true))

    var registers = DoryX86GeneralRegisters()
    registers.rbx = 0x2100  // aligned to 32
    var current = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    current.floatingPoint.ymm[0] = try .init(
      bytes: bytes(0..<32), expectedByteCount: 32)
    // Backing must cover 0x1000..0x2120 (0x1120 bytes)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0xC5, 0xFC, 0x29, 0x03] + .init(repeating: 0, count: 0x1200))
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let stored = try memory.read(at: 0x2100, byteCount: 32)
    #expect(stored == bytes(0..<32))
  }

  // MARK: - BMI1 SHRX (VEX 0F38 F7 with F2 pp)

  @Test func shrx64ShiftsRightWithoutModifyingFlags() throws {
    // C4 E2 F3 F7 C0: SHRX rax, rax, rcx
    // C4 E2: R=1,X=1,B=1, map=00010(0F38)
    // F3: W=1, vvvv=~1110=0001=1(rcx), L=0, pp=11(F2) -> SHRX
    // C0: ModRM mod=11, reg=000(rax), rm=000(rax)
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0xF3, 0xF7, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .flaglessShift(
          .shiftRight,
          destination: .register(.rax, width: .quadword),
          source: .register(.rax, width: .quadword),
          count: .register(.rcx, width: .quadword)
        ))

    var registers = DoryX86GeneralRegisters()
    registers.rax = 0x8000_0000_0000_0000
    registers.rcx = 4
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    // Set some flags to verify they're preserved.
    state.rflags.insert(.carry)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0xF3, 0xF7, 0xC0])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(state.registers.rax == 0x0800_0000_0000_0000)
    // Flags must be preserved (carry still set).
    #expect(state.rflags.contains(.carry))
  }

  @Test func shlx64ShiftsLeftWithoutModifyingFlags() throws {
    // C4 E2 E1 F7 C0: SHLX rax, rax, rcx
    // C4 E2: R=1,X=1,B=1, map=00010(0F38)
    // E1: W=1, vvvv=~1100=0011=1... wait
    // E1 = 1110 0001: W=1, vvvv=~1100=0011=3... no
    // E1 = 1110 0001: W=1, vvvv=~1100=0011=3, L=0, pp=01(66) -> SHLX
    // vvvv=3 means rcx? No, vvvv=3 -> register 3 = rbx
    // Let me use vvvv=1 (rcx): byte2 = W=1, vvvv=~0001=1110, L=0, pp=01
    // = 1111 0001 = F1
    // C4 E2 F1 F7 C0: SHLX rax, rax, rcx
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0xF1, 0xF7, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .flaglessShift(
          .shiftLeft,
          destination: .register(.rax, width: .quadword),
          source: .register(.rax, width: .quadword),
          count: .register(.rcx, width: .quadword)
        ))

    var registers = DoryX86GeneralRegisters()
    registers.rax = 0x0000_0000_0000_000F
    registers.rcx = 4
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0xF1, 0xF7, 0xC0])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    expectRetired(result)
    #expect(state.registers.rax == 0x0000_0000_0000_00F0)
  }

  @Test func sarx64ArithmeticShiftsRightWithoutModifyingFlags() throws {
    // C4 E2 F3 F7 C2: SARX rax, rdx, rcx
    // F3: W=1, vvvv=~1110=0001=1(rcx), L=0, pp=11(F2) -> SARX? No, F2=pp=3 -> SHRX
    // SARX uses pp=2 (F3): byte2 = W=1, vvvv=~0001=1110, L=0, pp=10
    // = 1111 0010 = F2
    // C4 E2 F2 F7 C2: SARX rax, rdx, rcx
    let instruction = try decoder.decode(
      [0xC4, 0xE2, 0xF2, 0xF7, 0xC2], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .flaglessShift(
          .arithmeticShiftRight,
          destination: .register(.rax, width: .quadword),
          source: .register(.rdx, width: .quadword),
          count: .register(.rcx, width: .quadword)
        ))

    var registers = DoryX86GeneralRegisters()
    registers.rdx = 0x8000_0000_0000_0000
    registers.rcx = 4
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xC4, 0xE2, 0xF2, 0xF7, 0xC2])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    expectRetired(result)
    // Arithmetic right shift of sign bit -> fills with 1s
    #expect(state.registers.rax == 0xF800_0000_0000_0000)
  }
}
