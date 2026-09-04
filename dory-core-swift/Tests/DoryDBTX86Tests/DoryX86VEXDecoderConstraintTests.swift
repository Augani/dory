import Testing

@testable import DoryDBTX86

// Intel XED's AVX/AVX2 instruction tables are the primary encoding reference:
// https://github.com/intelxed/xed/tree/main/datafiles/avx
// https://github.com/intelxed/xed/tree/main/datafiles/hswavx
@Suite struct DoryX86VEXDecoderConstraintTests {
  private let decoder = DoryX86Decoder()

  @Test func mandatoryPrefixesRejectAliasesForEveryRepresentedArm() throws {
    let noOr66: [UInt8] = [0x10, 0x11, 0x28, 0x29, 0x54, 0x55, 0x56, 0x57,
      0x2E, 0x2F, 0x14, 0x15]
    for opcode in noOr66 {
      for pp: UInt8 in 0...3 {
        let bytes = vex(pp: pp, opcode: opcode)
        if pp <= 1 {
          _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
        } else {
          expectRejected(bytes)
        }
      }
    }

    let prefix66: [UInt8] = [0x64, 0x65, 0x66, 0x74, 0x76, 0xFC, 0xFD, 0xFE,
      0xDB, 0xDF, 0xEB, 0xEF, 0xDA, 0xEA, 0xD8, 0xD9, 0xF8, 0xF9,
      0x6E, 0x7E, 0xD7]
    for opcode in prefix66 {
      for pp: UInt8 in 0...3 {
        let bytes = vex(pp: pp, opcode: opcode)
        if pp == 1 {
          _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
        } else {
          expectRejected(bytes)
        }
      }
    }

    for opcode: UInt8 in [0x6F, 0x7F] {
      for pp: UInt8 in 0...3 {
        let bytes = vex(pp: pp, opcode: opcode)
        if pp == 1 || pp == 2 {
          _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
        } else {
          expectRejected(bytes)
        }
      }
    }

    for opcode: UInt8 in [0x5A, 0x2C, 0x2D] {
      for pp: UInt8 in 0...3 {
        let bytes = vex(pp: pp, opcode: opcode)
        if pp >= 2 {
          _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
        } else {
          expectRejected(bytes)
        }
      }
    }

    let map0F38: [UInt8] = [0x00, 0x18, 0x19, 0x1A, 0x5A, 0x45, 0x46]
    for opcode in map0F38 {
      let largeVector = opcode == 0x19 || opcode == 0x1A || opcode == 0x5A
      let memoryOnly = opcode == 0x1A || opcode == 0x5A
      for pp: UInt8 in 0...3 {
        let bytes = vex(map: 2, pp: pp, largeVector: largeVector,
          opcode: opcode, modRM: memoryOnly ? 0x01 : 0xC1)
        if pp == 1 {
          _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
        } else {
          expectRejected(bytes)
        }
      }
    }
  }

  @Test func scalarAndReservedVEXFieldsAreEnforced() throws {
    for opcode: UInt8 in [0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F] {
      for pp: UInt8 in 0...3 {
        _ = try decoder.decode(vex(pp: pp, opcode: opcode), at: 0x1000, mode: .long64)
        if pp >= 2 { expectRejected(vex(pp: pp, largeVector: true, opcode: opcode)) }
      }
    }
    for opcode: UInt8 in [0x2E, 0x2F] {
      expectRejected(vex(pp: 0, largeVector: true, opcode: opcode))
      expectRejected(vex(pp: 0, vvvv: 1, opcode: opcode))
    }
    for opcode: UInt8 in [0x10, 0x11, 0x28, 0x29, 0x6E, 0x7E, 0x6F, 0x7F, 0xD7] {
      let pp: UInt8 = [0x10, 0x11, 0x28, 0x29].contains(opcode) ? 0 : 1
      expectRejected(vex(pp: pp, vvvv: 1, opcode: opcode))
    }
    for opcode: UInt8 in [0x6E, 0x7E] {
      expectRejected(vex(pp: 1, largeVector: true, opcode: opcode))
    }
    expectRejected(vex(pp: 1, opcode: 0xD7, modRM: 0x01))
    for opcode: UInt8 in [0x5A, 0x2C, 0x2D] {
      expectRejected(vex(pp: 2, largeVector: true, opcode: opcode))
    }
    for opcode: UInt8 in [0x2C, 0x2D] {
      expectRejected(vex(pp: 2, vvvv: 1, opcode: opcode))
      expectRejected(vex(pp: 2, opcode: opcode, modRM: 0x01))
    }
  }

  @Test func immediateShiftGroupsSelectTheArchitecturalOperandsAndWidths() throws {
    let arithmetic = try decoder.decode(
      vex(pp: 1, vvvv: 3, opcode: 0x72, modRM: 0xE1, tail: [7]),
      at: 0x1000, mode: .long64)
    #expect(arithmetic.operation == .vexVectorShiftImmediate(
      operation: .arithmeticRight, destination: 3, source: 1, immediate: 7,
      laneWidth: .doubleword, length: .xmm128))

    let logical = try decoder.decode(
      vex(pp: 1, vvvv: 4, opcode: 0x73, modRM: 0xF2, tail: [9]),
      at: 0x1000, mode: .long64)
    #expect(logical.operation == .vexVectorShiftImmediate(
      operation: .logicalLeft, destination: 4, source: 2, immediate: 9,
      laneWidth: .quadword, length: .xmm128))

    expectRejected(vex(pp: 1, opcode: 0x73, modRM: 0xE1, tail: [1]))
    expectRejected(vex(pp: 1, opcode: 0x72, modRM: 0x21, tail: [1]))
    expectRejected(vex(pp: 0, opcode: 0x72, modRM: 0xE1, tail: [1]))
  }

  @Test func correctedOperationsDoNotDecodeTheirHistoricalAliases() throws {
    let vmovupd = try decoder.decode(
      vex(pp: 1, opcode: 0x10), at: 0x1000, mode: .long64)
    #expect(vmovupd.operation == .vexMoveVector(
      destination: .register(0), source: .register(1),
      length: .xmm128, requiresAlignment: false))

    let vmovdqu = try decoder.decode(
      vex(pp: 2, opcode: 0x6F), at: 0x1000, mode: .long64)
    #expect(vmovdqu.operation == .vexMoveVector(
      destination: .register(0), source: .register(1),
      length: .xmm128, requiresAlignment: false))

    let scalarToInteger = try decoder.decode(
      vex(pp: 3, w: true, opcode: 0x2C), at: 0x1000, mode: .long64)
    #expect(scalarToInteger.operation == .vexConvertScalarToInteger(
      truncated: true, doublePrecision: true,
      destination: .register(.rax, width: .quadword), source: 1))

    let subtract = try decoder.decode(
      vex(pp: 1, opcode: 0xF8), at: 0x1000, mode: .long64)
    #expect(subtract.operation == .vexSubPackedIntegers(
      laneWidth: .byte, saturating: false, unsigned: false,
      destination: 0, firstSource: 0, secondSource: .register(1),
      length: .xmm128))

    let moveMask = try decoder.decode(
      vex(pp: 1, largeVector: true, w: true, opcode: 0xD7),
      at: 0x1000, mode: .long64)
    #expect(moveMask.operation == .vexMoveMaskToInteger(
      destination: .register(.rax, width: .doubleword), source: 1,
      length: .ymm256))

    for opcode: UInt8 in [0xE2, 0xE3, 0xFA, 0xFB, 0x93] {
      expectRejected(vex(pp: opcode == 0x93 ? 0 : 1, opcode: opcode))
    }
    expectRejected(vex(map: 2, pp: 1, opcode: 0x78))
    expectRejected(vex(pp: 2, opcode: 0x10)) // unsupported scalar VMOVSS alias
    expectRejected(vex(pp: 3, opcode: 0x11)) // unsupported scalar VMOVSD alias
  }

  @Test func MXCSRZeroingAndBroadcastFormsEnforceFixedFieldsAndModRM() throws {
    _ = try decoder.decode(vex(opcode: 0xAE, modRM: 0x10), at: 0x1000, mode: .long64)
    _ = try decoder.decode(vex(opcode: 0xAE, modRM: 0x18), at: 0x1000, mode: .long64)
    for bytes in [
      vex(pp: 1, opcode: 0xAE, modRM: 0x10),
      vex(largeVector: true, opcode: 0xAE, modRM: 0x10),
      vex(vvvv: 1, opcode: 0xAE, modRM: 0x10),
      vex(opcode: 0xAE, modRM: 0xD0),
    ] { expectRejected(bytes) }

    _ = try decoder.decode(vex(opcode: 0x77, modRM: nil), at: 0x1000, mode: .long64)
    expectRejected(vex(largeVector: true, opcode: 0x77, modRM: nil))
    expectRejected(vex(vvvv: 1, opcode: 0x77, modRM: nil))

    for opcode: UInt8 in [0x18, 0x19, 0x1A, 0x5A] {
      let largeVector = opcode != 0x18
      let bytes = vex(map: 2, pp: 1, largeVector: largeVector,
        opcode: opcode, modRM: opcode == 0x18 || opcode == 0x19 ? 0xC1 : 0x01)
      _ = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      expectRejected(vex(map: 2, pp: 1, largeVector: largeVector, vvvv: 1,
        opcode: opcode, modRM: 0x01))
      expectRejected(vex(map: 2, pp: 1, largeVector: largeVector, w: true,
        opcode: opcode, modRM: 0x01))
    }
    expectRejected(vex(map: 2, pp: 1, opcode: 0x19))
    expectRejected(vex(map: 2, pp: 1, opcode: 0x1A))
    expectRejected(vex(map: 2, pp: 1, largeVector: true, opcode: 0x1A))
    expectRejected(vex(map: 2, pp: 1, opcode: 0x5A))
    expectRejected(vex(map: 2, pp: 1, largeVector: true, opcode: 0x5A))
  }

  @Test func variableAndBMI2ShiftsUseTheirArchitecturalMapAndFixedFields() throws {
    let variableShifts: [(UInt8, Bool)] = [(0x45, false), (0x46, true)]
    for (opcode, arithmetic) in variableShifts {
      let instruction = try decoder.decode(
        vex(map: 2, pp: 1, vvvv: 2, opcode: opcode),
        at: 0x1000, mode: .long64)
      #expect(instruction.operation == .vexVariableShift(
        arithmetic: arithmetic, laneWidth: .doubleword,
        destination: 0, firstSource: 2, secondSource: .register(1),
        length: .xmm128))
      expectRejected(vex(map: 2, pp: 1, w: true, opcode: opcode))
    }

    for pp: UInt8 in 1...3 {
      _ = try decoder.decode(vex(map: 2, pp: pp, opcode: 0xF7), at: 0x1000, mode: .long64)
      expectRejected(vex(map: 2, pp: pp, largeVector: true, opcode: 0xF7))
    }
    expectRejected(vex(map: 2, opcode: 0xF7))
  }

  private func expectRejected(_ bytes: [UInt8]) {
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode(bytes, at: 0x1000, mode: .long64)
    }
  }

  private func vex(
    map: UInt8 = 1,
    pp: UInt8 = 0,
    largeVector: Bool = false,
    vvvv: UInt8 = 0,
    w: Bool = false,
    opcode: UInt8,
    modRM: UInt8? = 0xC1,
    tail: [UInt8] = []
  ) -> [UInt8] {
    let field = ((~vvvv) & 0x0F) << 3
    let control = (w ? 0x80 : 0) | field | (largeVector ? 0x04 : 0) | pp
    return [0xC4, 0xE0 | map, control, opcode] + (modRM.map { [$0] } ?? []) + tail
  }
}
