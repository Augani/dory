import Foundation

public enum DoryX86DecodeError: Error, Sendable, Equatable, CustomStringConvertible {
  case truncated(address: UInt64)
  case instructionTooLong(address: UInt64)
  case unsupportedOpcode(address: UInt64, bytes: [UInt8])
  case invalidEncoding(address: UInt64, detail: String)

  public var description: String {
    switch self {
    case .truncated(let address):
      "x86 instruction at 0x\(String(address, radix: 16)) is truncated"
    case .instructionTooLong(let address):
      "x86 instruction at 0x\(String(address, radix: 16)) exceeds 15 bytes"
    case .unsupportedOpcode(let address, let bytes):
      "unsupported x86 opcode at 0x\(String(address, radix: 16)): \(bytes.map { String(format: "%02x", $0) }.joined())"
    case .invalidEncoding(let address, let detail):
      "invalid x86 encoding at 0x\(String(address, radix: 16)): \(detail)"
    }
  }
}

public struct DoryX86Decoder: Sendable {
  public init() {}

  public func decode(
    _ input: [UInt8],
    at address: UInt64,
    mode: DoryX86ExecutionMode
  ) throws -> DoryX86DecodedInstruction {
    try decode(input[...], at: address, mode: mode)
  }

  func decode(
    _ input: ArraySlice<UInt8>,
    at address: UInt64,
    mode: DoryX86ExecutionMode
  ) throws -> DoryX86DecodedInstruction {
    var cursor = Cursor(input: input, address: address)
    var prefixes = DoryX86InstructionPrefixes()
    // VEX prefixes (C4/C5) must be detected before the legacy prefix loop ends,
    // because they are not legacy prefixes — they replace the REX + mandatory
    // prefix + opcode-map selection in a single multi-byte encoding. In long
    // mode, C4/C5 are always VEX (LES/LDS are not encodable in 64-bit).
    if mode == .long64, let first = cursor.peek(), first == 0xC5 || first == 0xC4 {
      prefixes.vex = try parseVEXPrefix(&cursor)
      // Synthesize REX-equivalent bits so ModRM decoding extends registers.
      let v = prefixes.vex!
      prefixes.rex = DoryX86REXPrefix(w: v.w, r: v.r, x: v.x, b: v.b)
      // Synthesize the mandatory prefix from pp so existing opcode dispatch
      // sees the same prefix state as the equivalent legacy SSE encoding.
      switch v.pp {
      case 1: prefixes.operandSizeOverride = true   // 66
      case 2: prefixes.repeatPrefix = 0xF3           // F3
      case 3: prefixes.repeatPrefix = 0xF2           // F2
      default: break                                  // 00 = no prefix
      }
    } else {
      while let byte = cursor.peek() {
        let consumed: Bool
        switch byte {
        case 0xF0:
          prefixes.lock = true
          consumed = true
        case 0xF2, 0xF3:
          prefixes.repeatPrefix = byte
          consumed = true
        case 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65:
          prefixes.segmentOverride = byte
          consumed = true
        case 0x66:
          prefixes.operandSizeOverride = true
          consumed = true
        case 0x67:
          prefixes.addressSizeOverride = true
          consumed = true
        case 0x40...0x4F where mode == .long64:
          prefixes.rex = DoryX86REXPrefix(byte: byte)
          consumed = true
        default:
          consumed = false
        }
        guard consumed else { break }
        _ = try cursor.readByte()
      }
    }

    let opcode = try cursor.readByte()
    let width = operandWidth(mode: mode, prefixes: prefixes)
    let operation: DoryX86InstructionOperation
    // VEX-prefixed instructions have their own dispatch path. The VEX prefix
    // selects the opcode map (0F, 0F38, 0F3A), mandatory prefix, and vector
    // length, so we decode them separately from the legacy opcode switch.
    if let vex = prefixes.vex {
      operation = try decodeVEXOpcode(
        vex, opcode: opcode, cursor: &cursor, prefixes: prefixes, mode: mode)
      try validateLockPrefix(prefixes, operation: operation, address: address)
      guard cursor.offset <= 15 else {
        throw DoryX86DecodeError.instructionTooLong(address: address)
      }
      return DoryX86DecodedInstruction(
        address: address, bytes: cursor.consumedBytes,
        prefixes: prefixes, operation: operation)
    }
    switch opcode {
    case 0x90:
      if prefixes.repeatPrefix == 0xF3, prefixes.rex?.b != true {
        operation = .processorPause
      } else if prefixes.rex?.b == true {
        operation = .exchange(
          .register(.rax, width: width),
          .register(.r8, width: width)
        )
      } else {
        operation = .noOperation
      }
    case 0x91...0x97:
      operation = .exchange(
        .register(.rax, width: width),
        .register(register(Int(opcode - 0x90), extensionBit: prefixes.rex?.b == true), width: width)
      )
    case 0x9C:
      operation = .pushFlags(width: stackWidth(mode: mode, prefixes: prefixes))
    case 0x9B:
      operation = .waitForCoprocessor
    case 0x9D:
      operation = .popFlags(width: stackWidth(mode: mode, prefixes: prefixes))
    case 0x9E:
      operation = .flagByte(load: false)
    case 0x9F:
      operation = .flagByte(load: true)
    case 0xF4:
      operation = .halt
    case 0xF5:
      operation = .complementCarry
    case 0xF8:
      operation = .setCarry(false)
    case 0xF9:
      operation = .setCarry(true)
    case 0xFA:
      operation = .setInterruptsEnabled(false)
    case 0xFB:
      operation = .setInterruptsEnabled(true)
    case 0xFC:
      operation = .setDirection(false)
    case 0xFD:
      operation = .setDirection(true)
    case 0x40...0x47:
      operation = .unary(
        .increment,
        operand: .register(register(Int(opcode - 0x40), extensionBit: false), width: width)
      )
    case 0x48...0x4F:
      operation = .unary(
        .decrement,
        operand: .register(register(Int(opcode - 0x48), extensionBit: false), width: width)
      )
    case 0x50...0x57:
      let register = register(Int(opcode - 0x50), extensionBit: prefixes.rex?.b == true)
      operation = .push(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
    case 0x58...0x5F:
      let register = register(Int(opcode - 0x58), extensionBit: prefixes.rex?.b == true)
      operation = .pop(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
    case 0x8F:
      let targetWidth = stackWidth(mode: mode, prefixes: prefixes)
      let operands = try decodeModRM(
        cursor: &cursor, width: targetWidth, prefixes: prefixes, mode: mode)
      guard operands.group == 0 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "POP r/m group must be /0")
      }
      operation = .pop(operands.rm)
    case 0x63:
      guard mode == .long64 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "MOVSXD requires 64-bit mode")
      }
      let operands = try decodeModRM(
        cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
      let destinationWidth: DoryX86OperandWidth = prefixes.rex?.w == true ? .quadword : .doubleword
      operation = .extendMove(
        destination: resizedOperand(operands.reg, to: destinationWidth),
        source: operands.rm,
        signed: true
      )
    case 0x68:
      let targetWidth = stackWidth(mode: mode, prefixes: prefixes)
      let encodedWidth: DoryX86OperandWidth = targetWidth == .word ? .word : .doubleword
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      operation = .push(
        .immediate(signExtend(raw, from: encodedWidth, to: targetWidth), width: targetWidth)
      )
    case 0x6A:
      let targetWidth = stackWidth(mode: mode, prefixes: prefixes)
      let raw = try cursor.readUnsigned(byteCount: 1)
      operation = .push(
        .immediate(signExtend(raw, from: .byte, to: targetWidth), width: targetWidth)
      )
    case 0x6C...0x6F:
      let ioWidth: DoryX86OperandWidth =
        opcode & 1 == 0 ? .byte : ioOperandWidth(mode: mode, prefixes: prefixes)
      operation = .string(opcode & 2 == 0 ? .input : .output, width: ioWidth)
    case 0x69, 0x6B:
      let operands = try decodeModRM(
        cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
      let encodedWidth: DoryX86OperandWidth =
        opcode == 0x6B
        ? .byte
        : (width == .quadword ? .doubleword : width)
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      operation = .signedMultiply(
        destination: operands.reg,
        lhs: operands.rm,
        rhs: .immediate(signExtend(raw, from: encodedWidth, to: width), width: width)
      )
    case 0xB0...0xB7:
      operation = .move(
        destination: registerOperand(
          Int(opcode - 0xB0),
          extensionBit: prefixes.rex?.b == true,
          width: .byte,
          rexPresent: prefixes.rex != nil
        ),
        source: .immediate(try cursor.readUnsigned(byteCount: 1), width: .byte)
      )
    case 0xB8...0xBF:
      let register = register(Int(opcode - 0xB8), extensionBit: prefixes.rex?.b == true)
      let immediate = try cursor.readUnsigned(byteCount: width.byteCount)
      operation = .move(
        destination: .register(register, width: width),
        source: .immediate(immediate, width: width)
      )
    case 0x98:
      operation = .signExtendAccumulator(width: width, intoHighHalf: false)
    case 0x99:
      operation = .signExtendAccumulator(width: width, intoHighHalf: true)
    case 0x9A:
      guard mode != .long64 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "immediate far call is invalid in 64-bit mode")
      }
      operation = .farCall(
        offset: try cursor.readUnsigned(byteCount: width == .word ? 2 : 4),
        selector: UInt16(try cursor.readUnsigned(byteCount: 2)),
        width: width
      )
    case 0x8C, 0x8E:
      let operands = try decodeModRM(
        cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
      let segment = try segmentRegister(
        encoding: operands.group, address: address, allowCode: opcode == 0x8C)
      operation =
        opcode == 0x8C
        ? .readSegment(segment, destination: operands.rm)
        : .writeSegment(segment, source: operands.rm)
    case 0x86, 0x87, 0x88, 0x8A, 0x89, 0x8B, 0x8D,
      0x00, 0x02, 0x01, 0x03, 0x08, 0x0A, 0x09, 0x0B,
      0x10, 0x12, 0x11, 0x13, 0x18, 0x1A, 0x19, 0x1B,
      0x20, 0x22, 0x21, 0x23, 0x28, 0x2A, 0x29, 0x2B,
      0x30, 0x32, 0x31, 0x33, 0x38, 0x3A, 0x39, 0x3B,
      0x84, 0x85:
      let operandWidth: DoryX86OperandWidth = opcode & 1 == 0 ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor,
        width: operandWidth,
        prefixes: prefixes,
        mode: mode
      )
      switch opcode {
      case 0x86, 0x87:
        operation = .exchange(operands.rm, operands.reg)
      case 0x88:
        operation = .move(destination: operands.rm, source: operands.reg)
      case 0x8A:
        operation = .move(destination: operands.reg, source: operands.rm)
      case 0x89:
        operation = .move(destination: operands.rm, source: operands.reg)
      case 0x8B:
        operation = .move(destination: operands.reg, source: operands.rm)
      case 0x8D:
        guard case .memory(let memory) = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "LEA requires a memory source")
        }
        operation = .loadEffectiveAddress(destination: operands.reg, source: memory)
      case 0x00, 0x01: operation = .alu(.add, destination: operands.rm, source: operands.reg)
      case 0x02, 0x03: operation = .alu(.add, destination: operands.reg, source: operands.rm)
      case 0x08, 0x09: operation = .alu(.or, destination: operands.rm, source: operands.reg)
      case 0x0A, 0x0B: operation = .alu(.or, destination: operands.reg, source: operands.rm)
      case 0x10, 0x11:
        operation = .alu(.addWithCarry, destination: operands.rm, source: operands.reg)
      case 0x12, 0x13:
        operation = .alu(.addWithCarry, destination: operands.reg, source: operands.rm)
      case 0x18, 0x19:
        operation = .alu(.subtractWithBorrow, destination: operands.rm, source: operands.reg)
      case 0x1A, 0x1B:
        operation = .alu(.subtractWithBorrow, destination: operands.reg, source: operands.rm)
      case 0x20, 0x21: operation = .alu(.and, destination: operands.rm, source: operands.reg)
      case 0x22, 0x23: operation = .alu(.and, destination: operands.reg, source: operands.rm)
      case 0x28, 0x29:
        operation = .alu(.subtract, destination: operands.rm, source: operands.reg)
      case 0x2A, 0x2B:
        operation = .alu(.subtract, destination: operands.reg, source: operands.rm)
      case 0x30, 0x31: operation = .alu(.xor, destination: operands.rm, source: operands.reg)
      case 0x32, 0x33: operation = .alu(.xor, destination: operands.reg, source: operands.rm)
      case 0x38, 0x39:
        operation = .alu(.compare, destination: operands.rm, source: operands.reg)
      case 0x3A, 0x3B:
        operation = .alu(.compare, destination: operands.reg, source: operands.rm)
      default: operation = .alu(.test, destination: operands.rm, source: operands.reg)
      }
    case 0x04, 0x05, 0x0C, 0x0D, 0x14, 0x15, 0x1C, 0x1D,
      0x24, 0x25, 0x2C, 0x2D, 0x34, 0x35, 0x3C, 0x3D:
      let operandWidth: DoryX86OperandWidth = opcode & 1 == 0 ? .byte : width
      let aluOperation = try aluOperation(group: (opcode >> 3) & 7, address: address)
      let encodedWidth: DoryX86OperandWidth = operandWidth == .quadword ? .doubleword : operandWidth
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      let value =
        operandWidth == .quadword
        ? signExtend(raw, from: encodedWidth, to: operandWidth)
        : raw
      operation = .alu(
        aluOperation,
        destination: .register(.rax, width: operandWidth),
        source: .immediate(value, width: operandWidth)
      )
    case 0x80, 0x81, 0x83:
      let operandWidth: DoryX86OperandWidth = opcode == 0x80 ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
      let aluOperation = try aluOperation(group: operands.group, address: address)
      let encodedWidth: DoryX86OperandWidth =
        opcode == 0x83
        ? .byte
        : (operandWidth == .quadword ? .doubleword : operandWidth)
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      let value =
        opcode == 0x83 || operandWidth == .quadword
        ? signExtend(raw, from: encodedWidth, to: operandWidth)
        : raw
      operation = .alu(
        aluOperation,
        destination: operands.rm,
        source: .immediate(value, width: operandWidth)
      )
    case 0xA8, 0xA9:
      let operandWidth: DoryX86OperandWidth = opcode == 0xA8 ? .byte : width
      let encodedWidth: DoryX86OperandWidth = operandWidth == .quadword ? .doubleword : operandWidth
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      let value =
        operandWidth == .quadword
        ? signExtend(raw, from: encodedWidth, to: operandWidth)
        : raw
      operation = .alu(
        .test,
        destination: .register(.rax, width: operandWidth),
        source: .immediate(value, width: operandWidth)
      )
    case 0xA0...0xA3:
      let memoryWidth: DoryX86OperandWidth = opcode & 1 == 0 ? .byte : width
      let memoryAddressWidth = addressWidth(mode: mode, prefixes: prefixes)
      let absoluteAddress = try cursor.readUnsigned(byteCount: memoryAddressWidth.byteCount)
      let memory = DoryX86Operand.memory(
        .init(
          base: nil,
          displacement: Int64(bitPattern: absoluteAddress),
          width: memoryWidth,
          addressWidth: memoryAddressWidth,
          segment: segmentRegister(prefixes.segmentOverride) ?? .ds,
          ignoresLegacySegmentBase: mode == .long64
        ))
      let accumulator = DoryX86Operand.register(.rax, width: memoryWidth)
      operation =
        opcode & 2 == 0
        ? .move(destination: accumulator, source: memory)
        : .move(destination: memory, source: accumulator)
    case 0xA4...0xA7, 0xAA...0xAF:
      let elementWidth: DoryX86OperandWidth = opcode & 1 == 0 ? .byte : width
      let stringOperation: DoryX86StringOperation =
        switch opcode {
        case 0xA4, 0xA5: .move
        case 0xA6, 0xA7: .compare
        case 0xAA, 0xAB: .store
        case 0xAC, 0xAD: .load
        default: .scan
        }
      operation = .string(stringOperation, width: elementWidth)
    case 0xE4, 0xE5, 0xE6, 0xE7:
      let port = DoryX86IOPort.immediate(UInt8(try cursor.readUnsigned(byteCount: 1)))
      let ioWidth: DoryX86OperandWidth =
        opcode & 1 == 0 ? .byte : ioOperandWidth(mode: mode, prefixes: prefixes)
      operation =
        opcode & 2 == 0
        ? .input(port: port, width: ioWidth)
        : .output(port: port, width: ioWidth)
    case 0xEC, 0xED, 0xEE, 0xEF:
      let ioWidth: DoryX86OperandWidth =
        opcode & 1 == 0 ? .byte : ioOperandWidth(mode: mode, prefixes: prefixes)
      operation =
        opcode & 2 == 0
        ? .input(port: .dx, width: ioWidth)
        : .output(port: .dx, width: ioWidth)
    case 0xC6, 0xC7:
      let operandWidth: DoryX86OperandWidth = opcode == 0xC6 ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
      guard operands.group == 0 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "MOV immediate group must be /0")
      }
      let encodedWidth: DoryX86OperandWidth = operandWidth == .quadword ? .doubleword : operandWidth
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      let immediate =
        operandWidth == .quadword
        ? signExtend(raw, from: encodedWidth, to: operandWidth)
        : raw
      operation = .move(
        destination: operands.rm,
        source: .immediate(immediate, width: operandWidth)
      )
    case 0xFE, 0xFF:
      let operandWidth: DoryX86OperandWidth = opcode == 0xFE ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
      let controlOperand =
        mode == .long64
        ? resizedOperand(operands.rm, to: .quadword)
        : operands.rm
      switch operands.group {
      case 0: operation = .unary(.increment, operand: operands.rm)
      case 1: operation = .unary(.decrement, operand: operands.rm)
      case 2 where opcode == 0xFF: operation = .callIndirect(controlOperand)
      case 3 where opcode == 0xFF:
        guard case .memory(let memoryAddress) = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "far indirect CALL requires a memory operand")
        }
        operation = .farCallIndirect(address: memoryAddress, width: operandWidth)
      case 4 where opcode == 0xFF: operation = .jumpIndirect(controlOperand)
      case 5 where opcode == 0xFF:
        guard case .memory(let memoryAddress) = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "far indirect JMP requires a memory operand")
        }
        operation = .farJumpIndirect(address: memoryAddress, width: operandWidth)
      case 6 where opcode == 0xFF: operation = .push(controlOperand)
      default:
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "unsupported FE/FF group")
      }
    case 0xF6, 0xF7:
      let operandWidth: DoryX86OperandWidth = opcode == 0xF6 ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
      switch operands.group {
      case 0:
        let encodedWidth: DoryX86OperandWidth =
          operandWidth == .quadword ? .doubleword : operandWidth
        let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
        let value =
          operandWidth == .quadword
          ? signExtend(raw, from: encodedWidth, to: operandWidth)
          : raw
        operation = .alu(
          .test,
          destination: operands.rm,
          source: .immediate(value, width: operandWidth)
        )
      case 2: operation = .unary(.bitwiseNot, operand: operands.rm)
      case 3: operation = .unary(.negate, operand: operands.rm)
      case 4:
        operation = .accumulatorArithmetic(.unsignedMultiply, source: operands.rm)
      case 5:
        operation = .accumulatorArithmetic(.signedMultiply, source: operands.rm)
      case 6:
        operation = .accumulatorArithmetic(.unsignedDivide, source: operands.rm)
      case 7:
        operation = .accumulatorArithmetic(.signedDivide, source: operands.rm)
      default:
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "unsupported F6/F7 group")
      }
    case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:
      let operandWidth: DoryX86OperandWidth = opcode & 1 == 0 ? .byte : width
      let operands = try decodeModRM(
        cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
      let shiftOperation = try shiftOperation(group: operands.group, address: address)
      let count: DoryX86ShiftCount
      switch opcode {
      case 0xC0, 0xC1: count = .immediate(try cursor.readByte())
      case 0xD0, 0xD1: count = .immediate(1)
      default: count = .cl
      }
      operation = .shift(shiftOperation, destination: operands.rm, count: count)
    case 0xC9:
      operation = .leave(width: stackWidth(mode: mode, prefixes: prefixes))
    case 0xE8:
      operation = .call(
        relative: Int64(try cursor.readSigned(byteCount: width == .word ? 2 : 4)))
    case 0xC3:
      operation = .return
    case 0xC2:
      operation = .returnAndPop(UInt16(try cursor.readUnsigned(byteCount: 2)))
    case 0xCA, 0xCB:
      operation = .farReturn(
        popBytes: opcode == 0xCA ? UInt16(try cursor.readUnsigned(byteCount: 2)) : 0,
        width: width
      )
    case 0xCF:
      operation = .interruptReturn
    case 0xC8:
      operation = .enter(
        allocation: UInt16(try cursor.readUnsigned(byteCount: 2)),
        nesting: try cursor.readByte() & 0x1F,
        width: stackWidth(mode: mode, prefixes: prefixes)
      )
    case 0xCC:
      operation = .softwareInterrupt(vector: 3)
    case 0xCD:
      operation = .softwareInterrupt(vector: try cursor.readByte())
    case 0xF1:
      // ICEBP / INT1: raise debug exception (vector 1). Used by the Linux
      // kernel for breakpoints and self-IPI in certain code paths.
      operation = .softwareInterrupt(vector: 1)
    case 0xE9:
      operation = .jump(
        relative: Int64(try cursor.readSigned(byteCount: width == .word ? 2 : 4)))
    case 0xEB:
      operation = .jump(relative: Int64(try cursor.readSigned(byteCount: 1)))
    case 0xE0...0xE3:
      let condition: DoryX86LoopCondition =
        switch opcode {
        case 0xE0: .countNonzeroAndNotZero
        case 0xE1: .countNonzeroAndZero
        case 0xE2: .countNonzero
        default: .countZero
        }
      operation = .loop(
        condition,
        relative: Int64(try cursor.readSigned(byteCount: 1)),
        counterWidth: addressWidth(mode: mode, prefixes: prefixes)
      )
    case 0xEA:
      guard mode != .long64 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "immediate far jump is invalid in 64-bit mode")
      }
      operation = .farJump(
        offset: try cursor.readUnsigned(byteCount: width == .word ? 2 : 4),
        selector: UInt16(try cursor.readUnsigned(byteCount: 2))
      )
    case 0xD7:
      operation = .translateByte(
        addressWidth: addressWidth(mode: mode, prefixes: prefixes),
        segment: segmentRegister(prefixes.segmentOverride) ?? .ds,
        ignoresLegacySegmentBase: mode == .long64
      )
    case 0x70...0x7F:
      operation = .conditionalJump(
        DoryX86Condition(rawValue: opcode - 0x70)!,
        relative: Int64(try cursor.readSigned(byteCount: 1))
      )
    case 0xD8, 0xDA, 0xDC, 0xDE:
      let operands = try decodeModRM(
        cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
      if case .memory(let memory) = operands.rm {
        let format: DoryX87MemoryFormat =
          switch opcode {
          case 0xD8: .float32
          case 0xDA: .signedInteger32
          case 0xDC: .float64
          default: .signedInteger16
          }
        let source = DoryX87Operand.memory(memory, format: format)
        if operands.group == 2 || operands.group == 3 {
          operation = .compareX87(
            source: source,
            popCount: operands.group == 3 ? 1 : 0,
            ordered: true,
            setIntegerFlags: false
          )
        } else {
          operation = .x87Binary(
            try x87BinaryOperation(group: operands.group, address: address),
            destination: 0,
            source: source,
            pop: false
          )
        }
      } else if case .register = operands.rm {
        let register = vectorRegister(operands.rm)
        switch opcode {
        case 0xD8:
          if operands.group == 2 || operands.group == 3 {
            operation = .compareX87(
              source: .register(register),
              popCount: operands.group == 3 ? 1 : 0,
              ordered: true,
              setIntegerFlags: false
            )
          } else {
            operation = .x87Binary(
              try x87BinaryOperation(group: operands.group, address: address),
              destination: 0,
              source: .register(register),
              pop: false
            )
          }
        case 0xDC:
          let binary: DoryX87BinaryOperation =
            switch operands.group {
            case 0: .add
            case 1: .multiply
            case 4: .subtractReverse
            case 5: .subtract
            case 6: .divideReverse
            case 7: .divide
            default:
              throw DoryX86DecodeError.invalidEncoding(
                address: address, detail: "unsupported DC x87 register instruction")
            }
          operation = .x87Binary(
            binary, destination: register, source: .register(0), pop: false)
        case 0xDE where operands.group == 3 && register == 1:
          operation = .compareX87(
            source: .register(1), popCount: 2, ordered: true, setIntegerFlags: false)
        case 0xDE:
          let binary: DoryX87BinaryOperation =
            switch operands.group {
            case 0: .add
            case 1: .multiply
            case 4: .subtractReverse
            case 5: .subtract
            case 6: .divideReverse
            case 7: .divide
            default:
              throw DoryX86DecodeError.invalidEncoding(
                address: address, detail: "unsupported DE x87 register instruction")
            }
          operation = .x87Binary(
            binary, destination: register, source: .register(0), pop: true)
        case 0xDA where operands.group == 5 && register == 1:
          operation = .compareX87(
            source: .register(1), popCount: 2, ordered: false, setIntegerFlags: false)
        case 0xDA where operands.group <= 3:
          let condition: DoryX86Condition =
            switch operands.group {
            case 0: .below
            case 1: .equal
            case 2: .belowOrEqual
            default: .parity
            }
          operation = .conditionalMoveX87(condition, source: register)
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported x87 register arithmetic instruction")
        }
      } else {
        preconditionFailure("ModRM x87 operand must be register or memory")
      }
    case 0xD9:
      let operands = try decodeModRM(
        cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
      switch operands.rm {
      case .memory(let memory):
        switch operands.group {
        case 0: operation = .loadX87(.memory(memory, format: .float32))
        case 2:
          operation = .storeX87(
            destination: memory, format: .float32, pop: false, truncate: false)
        case 3:
          operation = .storeX87(
            destination: memory, format: .float32, pop: true, truncate: false)
        case 5: operation = .loadX87ControlWord(operands.rm)
        case 4: operation = .loadX87Environment(memory)
        case 6: operation = .storeX87Environment(memory)
        case 7: operation = .storeX87ControlWord(operands.rm)
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported D9 x87 memory instruction")
        }
      case .register:
        if operands.group == 0 {
          operation = .loadX87(.register(vectorRegister(operands.rm)))
        } else if operands.group == 1 {
          operation = .exchangeX87(vectorRegister(operands.rm))
        } else if operands.group == 2, vectorRegister(operands.rm) == 0 {
          operation = .noOperation
        } else {
          let encoded = UInt8(0xC0 | operands.group << 3 | vectorRegister(operands.rm))
          let special: DoryX87SpecialOperation =
            switch encoded {
            case 0xE0: .changeSign
            case 0xE1: .absolute
            case 0xE4: .test
            case 0xE5: .examine
            case 0xE8: .loadOne
            case 0xE9: .loadLog2Ten
            case 0xEA: .loadLog2E
            case 0xEB: .loadPi
            case 0xEC: .loadLog10Two
            case 0xED: .loadLnTwo
            case 0xEE: .loadZero
            case 0xF0: .twoToXMinusOne
            case 0xF1: .yLog2X
            case 0xF2: .tangent
            case 0xF3: .arctangent
            case 0xF4: .extract
            case 0xF5: .partialRemainderNearest
            case 0xF6: .decrementTop
            case 0xF7: .incrementTop
            case 0xF8: .partialRemainder
            case 0xF9: .yLog2XPlusOne
            case 0xFA: .squareRoot
            case 0xFB: .sineCosine
            case 0xFC: .roundToInteger
            case 0xFD: .scale
            case 0xFE: .sine
            case 0xFF: .cosine
            default:
              throw DoryX86DecodeError.invalidEncoding(
                address: address, detail: "unsupported D9 x87 special instruction")
            }
          operation = .x87Special(special)
        }
      default:
        preconditionFailure("ModRM x87 operand must be register or memory")
      }
    case 0xDB, 0xDD, 0xDF:
      let operands = try decodeModRM(
        cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
      if case .register = operands.rm {
        if opcode == 0xDB, operands.group <= 3 {
          let condition: DoryX86Condition =
            switch operands.group {
            case 0: .aboveOrEqual
            case 1: .notEqual
            case 2: .above
            default: .notParity
            }
          operation = .conditionalMoveX87(condition, source: vectorRegister(operands.rm))
        } else if opcode == 0xDB, operands.group == 4, vectorRegister(operands.rm) == 2 {
          operation = .clearX87Exceptions
        } else if opcode == 0xDB, operands.group == 4, vectorRegister(operands.rm) == 3 {
          operation = .initializeFloatingPoint
        } else if opcode == 0xDB, operands.group == 5 || operands.group == 6 {
          operation = .compareX87(
            source: .register(vectorRegister(operands.rm)),
            popCount: 0,
            ordered: operands.group == 6,
            setIntegerFlags: true
          )
        } else if opcode == 0xDD, operands.group == 4 || operands.group == 5 {
          operation = .compareX87(
            source: .register(vectorRegister(operands.rm)),
            popCount: operands.group == 5 ? 1 : 0,
            ordered: false,
            setIntegerFlags: false
          )
        } else if opcode == 0xDD, operands.group == 0 {
          operation = .freeX87(vectorRegister(operands.rm), pop: false)
        } else if opcode == 0xDD, operands.group == 2 || operands.group == 3 {
          operation = .moveX87(
            destination: vectorRegister(operands.rm),
            source: 0,
            pop: operands.group == 3
          )
        } else if opcode == 0xDF, operands.group == 4, vectorRegister(operands.rm) == 0 {
          operation = .storeX87StatusWord(.register(.rax, width: .word))
        } else if opcode == 0xDF, operands.group == 0 {
          operation = .freeX87(vectorRegister(operands.rm), pop: true)
        } else if opcode == 0xDF, operands.group == 5 || operands.group == 6 {
          operation = .compareX87(
            source: .register(vectorRegister(operands.rm)),
            popCount: 1,
            ordered: operands.group == 6,
            setIntegerFlags: true
          )
        } else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported register x87 instruction")
        }
      } else if case .memory(let memory) = operands.rm {
        if opcode == 0xDF, operands.group == 4 {
          operation = .loadX87PackedBCD(memory)
          break
        }
        if opcode == 0xDF, operands.group == 6 {
          operation = .storeX87PackedBCD(memory, pop: true)
          break
        }
        let format: DoryX87MemoryFormat
        switch opcode {
        case 0xDB:
          format = operands.group == 5 || operands.group == 7 ? .extended80 : .signedInteger32
        case 0xDD:
          if operands.group == 1 {
            format = .signedInteger64
          } else if operands.group == 7 {
            format = .signedInteger16
          } else {
            format = .float64
          }
        default:
          format = operands.group == 5 || operands.group == 7 ? .signedInteger64 : .signedInteger16
        }
        switch (opcode, operands.group) {
        case (0xDB, 0), (0xDB, 5), (0xDD, 0), (0xDF, 0), (0xDF, 5):
          operation = .loadX87(.memory(memory, format: format))
        case (0xDB, 1), (0xDD, 1), (0xDF, 1):
          operation = .storeX87(
            destination: memory, format: format, pop: true, truncate: true)
        case (0xDB, 2), (0xDD, 2), (0xDF, 2):
          operation = .storeX87(
            destination: memory, format: format, pop: false, truncate: false)
        case (0xDB, 3), (0xDD, 3), (0xDF, 3), (0xDB, 7), (0xDF, 7):
          operation = .storeX87(
            destination: memory, format: format, pop: true, truncate: false)
        case (0xDD, 7):
          operation = .storeX87StatusWord(operands.rm)
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported x87 memory instruction")
        }
      } else {
        preconditionFailure("ModRM x87 operand must be register or memory")
      }
    case 0x0F:
      let second = try cursor.readByte()
      switch second {
      case 0x0B:
        operation = .undefinedInstruction
      case 0xB9, 0xFF:
        // UD0 and UD1 include a ModRM byte solely to define the complete faulting instruction
        // length. Their operands are never read because retirement always raises #UD.
        _ = try decodeModRM(
          cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
        operation = .undefinedInstruction
      case 0x18:
        let operands = try decodeModRM(
          cursor: &cursor, width: .byte, prefixes: prefixes, mode: mode)
        guard operands.group <= 3, case .memory = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address,
            detail: "PREFETCHh requires a memory /0 through /3 operand"
          )
        }
        // PREFETCHh is only a cache hint. Decode its complete addressing form so RIP advances
        // correctly, but deliberately avoid an architectural guest-memory access.
        operation = .noOperation
      case 0x1E:
        let endBranchEncoding = try cursor.readByte()
        guard prefixes.repeatPrefix == 0xF3,
          endBranchEncoding == 0xFA || endBranchEncoding == 0xFB
        else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address,
            detail: "ENDBR requires the F3 0F 1E FA or F3 0F 1E FB encoding"
          )
        }
        // Dory deliberately does not expose CET indirect-branch tracking. Intel specifies both
        // ENDBR encodings as no-ops when CET IBT is unavailable or disabled.
        operation = .noOperation
      case 0x1F:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        guard operands.group == 0 else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "multi-byte NOP requires ModRM /0")
        }
        operation = .noOperation
      case 0x05:
        operation = .syscall
      case 0x06:
        operation = .clearTaskSwitched
      case 0x07:
        operation = .sysret
      case 0x08, 0x09:
        operation = .invalidateCaches(writeBack: second == 0x09)
      case 0x00:
        let operands = try decodeModRM(
          cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
        switch operands.group {
        case 0, 1:
          // Intel SDM 092 Vol. 2B SLDT/STR: memory stores remain 16 bits,
          // while register destinations use the operand size and zero-extend.
          let destination: DoryX86Operand
          if case .memory = operands.rm { destination = operands.rm }
          else { destination = resizedOperand(operands.rm, to: width) }
          operation = .storeSystemSegment(
            task: operands.group == 1, destination: destination)
        case 2, 3:
          operation = .loadSystemSegment(task: operands.group == 3, source: operands.rm)
        case 4, 5:
          guard prefixes.repeatPrefix == nil else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "VERR and VERW do not accept repeat prefixes")
          }
          operation = .verifySegment(readable: operands.group == 4, selector: operands.rm)
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported 0F 00 system instruction")
        }
      case 0x20, 0x22:
        let operands = try decodeSystemRegisterModRM(cursor: &cursor, prefixes: prefixes, debug: false)
        operation =
          second == 0x20
          ? .readControlRegister(index: operands.control, destination: operands.general)
          : .writeControlRegister(index: operands.control, source: operands.general)
      case 0x34:
        operation = .systemEnter
      case 0x35:
        operation = .systemExit(return64Bit: prefixes.rex?.w == true)
      case 0x21, 0x23:
        let operands = try decodeSystemRegisterModRM(cursor: &cursor, prefixes: prefixes, debug: true)
        operation =
          second == 0x21
          ? .readDebugRegister(index: operands.control, destination: operands.general)
          : .writeDebugRegister(index: operands.control, source: operands.general)
      case 0x30:
        operation = .writeModelSpecificRegister
      case 0x31:
        operation = .readTimestampCounter(includeAuxiliary: false)
      case 0x32:
        operation = .readModelSpecificRegister
      case 0x01:
        // Intel SDM group 7 and AMD SVM use the complete register ModRM byte.
        // REG alone cannot distinguish a descriptor operation from VMX/SVM.
        // Encoding reference: intelxed/xed datafiles/xed-isa.txt and amd/xed-amd-svm.txt.
        if let modRM = cursor.peek(), modRM >> 6 == 3,
          !((0xE0...0xE7).contains(modRM) || (0xF0...0xF7).contains(modRM))
        {
          _ = try cursor.readByte()
          let unsupported: DoryX86UnsupportedSystemInstruction?
          switch modRM {
          case 0xC0: unsupported = .enclv
          case 0xC2: unsupported = .vmLaunch
          case 0xC3: unsupported = .vmResume
          case 0xC4: unsupported = .vmxOff
          case 0xC5: unsupported = .pconfig
          case 0xC6: unsupported = .wrmsrns
          case 0xC7: unsupported = .pbndkb
          case 0xC8: unsupported = .monitor
          case 0xC9: unsupported = .mwait
          case 0xCA: unsupported = .clac
          case 0xCB: unsupported = .stac
          case 0xCF: unsupported = .encls
          case 0xD4: unsupported = .vmFunc
          case 0xD5: unsupported = .xend
          case 0xD6: unsupported = .xtest
          case 0xD7: unsupported = .enclu
          case 0xD8: unsupported = .vmRun
          case 0xD9: unsupported = .vmmCall
          case 0xDA: unsupported = .vmLoad
          case 0xDB: unsupported = .vmSave
          case 0xDC: unsupported = .stgi
          case 0xDD: unsupported = .clgi
          case 0xDE: unsupported = .skinit
          case 0xDF: unsupported = .invlpga
          case 0xE8: unsupported = .serialize
          case 0xEE: unsupported = .rdpkru
          case 0xEF: unsupported = .wrpkru
          case 0xFA: unsupported = .monitorx
          case 0xFB: unsupported = .mwaitx
          case 0xFC: unsupported = .clzero
          case 0xFD: unsupported = .rdpru
          case 0xFE: unsupported = .invlpgb
          case 0xFF: unsupported = .tlbsync
          default: unsupported = nil
          }
          if let unsupported {
            // Mandatory-prefix refinements name different, also unsupported
            // facilities (for example WRMSRLIST and TSXLDTRK). Do not alias them.
            operation = prefixes.repeatPrefix == nil && !prefixes.operandSizeOverride
              ? .unsupportedSystemInstruction(unsupported) : .undefinedInstruction
          } else {
            switch modRM {
            case 0xC1:
              operation = prefixes.repeatPrefix == nil && !prefixes.operandSizeOverride
                ? .vmCall : .undefinedInstruction
            case 0xD0, 0xD1:
              guard prefixes.repeatPrefix == nil, !prefixes.operandSizeOverride else {
                throw DoryX86DecodeError.invalidEncoding(
                  address: address, detail: "XGETBV/XSETBV do not accept refining prefixes")
              }
              operation = modRM == 0xD0 ? .readExtendedControlRegister : .writeExtendedControlRegister
            case 0xF8:
              guard mode == .long64 else {
                throw DoryX86DecodeError.invalidEncoding(
                  address: address, detail: "SWAPGS requires 64-bit mode")
              }
              operation = .swapGS
            case 0xF9:
              operation = .readTimestampCounter(includeAuxiliary: true)
            default:
              // Reserved or unmodeled facilities must never alias a successful operation.
              operation = .undefinedInstruction
            }
          }
        } else {
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          switch operands.group {
          case 4:
            let destination: DoryX86Operand
            if case .memory = operands.rm {
              destination = resizedOperand(operands.rm, to: .word)
            } else {
              destination = resizedOperand(operands.rm, to: width)
            }
            operation = .machineStatusWord(load: false, operand: destination)
          case 6:
            operation = .machineStatusWord(
              load: true, operand: resizedOperand(operands.rm, to: .word))
          case 0, 1, 2, 3, 7:
            guard case .memory(let memory) = operands.rm else {
              throw DoryX86DecodeError.invalidEncoding(
                address: address, detail: "0F 01 system-table instruction requires memory")
            }
            switch operands.group {
            case 0: operation = .descriptorTable(.global, load: false, address: memory)
            case 1: operation = .descriptorTable(.interrupt, load: false, address: memory)
            case 2: operation = .descriptorTable(.global, load: true, address: memory)
            case 3: operation = .descriptorTable(.interrupt, load: true, address: memory)
            default: operation = .invalidatePage(memory)
            }
          default:
            operation = .undefinedInstruction
          }
        }
      case 0x02, 0x03:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "LAR and LSL do not accept repeat prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        operation = .inspectSegmentDescriptor(
          accessRights: second == 0x02,
          destination: operands.reg,
          selector: resizedOperand(operands.rm, to: .word)
        )
      case 0xA2:
        operation = .cpuid
      case 0xAE:
        if let modRM = cursor.peek(), modRM >> 6 == 3 {
          _ = try cursor.readByte()
          // Intel SDM 092 LFENCE/MFENCE/SFENCE use NP and ignore ModRM.R/M.
          // 66/F2/F3 select different facilities, including WAITPKG and CET;
          // unsupported refinements must not execute as successful fences.
          guard prefixes.repeatPrefix == nil, !prefixes.operandSizeOverride else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported 0F AE register prefix refinement")
          }
          switch (modRM >> 3) & 7 {
          case 5: operation = .memoryFence(.load)
          case 6: operation = .memoryFence(.full)
          case 7: operation = .memoryFence(.store)
          default:
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported 0F AE register group")
          }
        } else {
          let operands = try decodeModRM(
            cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
          guard case .memory(let memory) = operands.rm else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported 0F AE memory group")
          }
          switch operands.group {
          case 0: operation = .saveFloatingPointState(memory)
          case 1: operation = .restoreFloatingPointState(memory)
          case 2: operation = .loadMXCSR(operands.rm)
          case 3: operation = .storeMXCSR(operands.rm)
          case 4: operation = .unsupportedSystemInstruction(.xsave)
          case 5: operation = .unsupportedSystemInstruction(.xrstor)
          case 6: operation = .unsupportedSystemInstruction(.xsaveopt)
          case 7:
            guard prefixes.repeatPrefix == nil, !prefixes.operandSizeOverride else {
              throw DoryX86DecodeError.invalidEncoding(
                address: address, detail: "unsupported cache-line flush prefix")
            }
            operation = .cacheLineFlush(memory)
          default:
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported 0F AE memory group")
          }
        }
      case 0x10, 0x11, 0x28, 0x29:
        let isLoad = second == 0x10 || second == 0x28
        let aligned = second == 0x28 || second == 0x29
        let scalarBytes: UInt8? =
          switch (prefixes.repeatPrefix, prefixes.operandSizeOverride) {
          case (0xF3, false): 4
          case (0xF2, false): 8
          case (nil, _): nil
          default:
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported vector move mandatory prefix")
          }
        guard !aligned || scalarBytes == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "aligned vector move does not have a scalar form")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let destination = vectorOperand(isLoad ? operands.reg : operands.rm)
        let source = vectorOperand(isLoad ? operands.rm : operands.reg)
        if let scalarBytes {
          operation = .moveVectorScalar(
            destination: destination,
            source: source,
            byteCount: scalarBytes,
            upperPolicy: isLoad ? .zeroOnMemorySource : .preserve
          )
        } else {
          operation = .moveVector128(
            destination: destination,
            source: source,
            requiresAlignment: aligned
          )
        }
      case 0x12, 0x16:
        // SSE/SSE3 64-bit-half and element-duplication moves. The mandatory prefix
        // selects the operation; `66` is reserved for both opcodes.
        //   no prefix, 0F 12: MOVLPS (mem) / MOVHLPS (reg)
        //   no prefix, 0F 16: MOVHPS (mem) / MOVLHPS (reg)
        //   F3 0F 12: MOVSLDUP   F3 0F 16: MOVSHDUP
        //   F2 0F 12: MOVDDUP    (F2 0F 16 is reserved)
        switch (prefixes.repeatPrefix, prefixes.operandSizeOverride) {
        case (nil, true):
          // 66 0F 12: MOVLPD (load low 64 bits from memory to XMM low half)
          // 66 0F 16: MOVHPD (load high 64 bits from memory to XMM high half)
          // Register form is reserved for 66 prefix.
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          guard case .memory = operands.rm else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "MOVLPD/MOVHPD requires a memory operand")
          }
          operation = .moveVectorQwordHalf(
            destination: vectorOperand(operands.reg),
            source: vectorOperand(operands.rm),
            sourceHigh: false,
            destinationHigh: second == 0x16
          )
        case (0xF3, false):
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          operation = .duplicateVectorScalar(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            mode: second == 0x12 ? .singleLow32 : .singleHigh32
          )
        case (0xF2, false) where second == 0x12:
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          operation = .duplicateVectorScalar(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            mode: .doubleLow64
          )
        case (nil, false):
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          let isRegisterForm: Bool
          if case .register = operands.rm { isRegisterForm = true } else { isRegisterForm = false }
          // 0F 12 writes the destination low half; 0F 16 writes the high half.
          let destinationHigh = second == 0x16
          // MOVHLPS (reg form of 0F 12) reads the source high half; every other
          // form reads the source low half (memory supplies only 8 bytes).
          let sourceHigh = second == 0x12 && isRegisterForm
          operation = .moveVectorQwordHalf(
            destination: vectorOperand(operands.reg),
            source: vectorOperand(operands.rm),
            sourceHigh: sourceHigh,
            destinationHigh: destinationHigh
          )
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported vector move mandatory prefix")
        }
      case 0x14, 0x15:
        // UNPCKLPS (no prefix) / UNPCKLPD (66) / UNPCKHPS (no prefix) / UNPCKHPD (66)
        let doublePrecision = prefixes.operandSizeOverride
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .unpackVector(
          high: second == 0x15,
          doublePrecision: doublePrecision,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm))
      case 0x17:
        // MOVHPS store (0F 17 /r mem): store high 64 bits of XMM to memory.
        // MOVHPD store (66 0F 17 /r mem): same with 66 prefix.
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .moveVectorQwordHalf(
          destination: vectorOperand(operands.rm),
          source: vectorOperand(operands.reg),
          sourceHigh: true,
          destinationHigh: false)
      case 0xC4:
        // PINSRW (66 0F C4 /r ib): insert word from GPR/memory into XMM at index.
        let operands = try decodeModRM(
          cursor: &cursor, width: .word, prefixes: prefixes, mode: mode)
        let index = try cursor.readByte() & 0x07
        operation = .insertPackedWord(
          destination: vectorRegister(operands.reg),
          source: operands.rm,
          index: index,
          mmx: false)
      case 0xE6:
        guard (prefixes.operandSizeOverride && prefixes.repeatPrefix == nil)
          || (!prefixes.operandSizeOverride
            && (prefixes.repeatPrefix == 0xF2 || prefixes.repeatPrefix == 0xF3))
        else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed conversion requires exactly one of 66/F2/F3")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        if prefixes.repeatPrefix == 0xF3 {
          operation = .convertPackedDwordToDouble(
            destination: vectorRegister(operands.reg), source: vectorOperand(operands.rm))
        } else {
          operation = .convertPackedDoubleToDword(
            truncated: prefixes.operandSizeOverride,
            destination: vectorRegister(operands.reg), source: vectorOperand(operands.rm))
        }
      case 0x2E, 0x2F:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "scalar floating compare rejects repeat prefixes")
        }
        let format: DoryX86VectorFloatingFormat =
          prefixes.operandSizeOverride ? .scalarDouble : .scalarSingle
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .vectorFloatingCompare(
          format: format,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm),
          quiet: second == 0x2E
        )
      case 0x2A:
        guard !prefixes.operandSizeOverride,
          prefixes.repeatPrefix == 0xF2 || prefixes.repeatPrefix == 0xF3
        else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "CVTSI2SS/CVTSI2SD requires F3 or F2 prefix")
        }
        let integerWidth: DoryX86OperandWidth = prefixes.rex?.w == true ? .quadword : .doubleword
        let operands = try decodeModRM(
          cursor: &cursor, width: integerWidth, prefixes: prefixes, mode: mode)
        operation = .convertIntegerToScalarFloat(
          format: prefixes.repeatPrefix == 0xF3 ? .scalarSingle : .scalarDouble,
          destination: vectorRegister(operands.reg),
          source: operands.rm
        )
      case 0x2C, 0x2D:
        guard !prefixes.operandSizeOverride,
          prefixes.repeatPrefix == 0xF2 || prefixes.repeatPrefix == 0xF3
        else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "scalar floating integer conversion requires F3 or F2 prefix")
        }
        let integerWidth: DoryX86OperandWidth = prefixes.rex?.w == true ? .quadword : .doubleword
        let operands = try decodeModRM(
          cursor: &cursor, width: integerWidth, prefixes: prefixes, mode: mode)
        operation = .convertScalarFloatToInteger(
          format: prefixes.repeatPrefix == 0xF3 ? .scalarSingle : .scalarDouble,
          destination: operands.reg,
          source: vectorOperand(operands.rm),
          truncate: second == 0x2C
        )
      case 0x50:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "floating move mask rejects repeat prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
        guard case .register = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "floating move mask requires register source")
        }
        operation = .moveVectorMask(
          destination: operands.reg,
          source: vectorOperand(operands.rm),
          laneWidth: prefixes.operandSizeOverride ? .quadword : .doubleword,
          vectorByteCount: 16
        )
      case 0x54...0x57, 0xDB, 0xDF, 0xEB, 0xEF:
        let packedInteger = second == 0xDB || second == 0xDF || second == 0xEB || second == 0xEF
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported vector bitwise mandatory prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let bitwiseOperation: DoryX86VectorBitwiseOperation =
          switch second {
          case 0x54, 0xDB: .and
          case 0x55, 0xDF: .andNot
          case 0x56, 0xEB: .or
          default: .xor
          }
        if packedInteger, !prefixes.operandSizeOverride {
          operation = .mmxBitwise(
            bitwiseOperation,
            destination: try mmxRegister(operands.reg, address: address),
            source: try mmxOperand(operands.rm, address: address)
          )
        } else {
          operation = .vectorBitwise(
            bitwiseOperation,
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm)
          )
        }
      case 0x51:
        // SQRTSS (F3 0F 51) / SQRTSD (F2 0F 51)
        guard prefixes.operandSizeOverride == false,
              prefixes.repeatPrefix == 0xF3 || prefixes.repeatPrefix == 0xF2 else {
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
        let format: DoryX86VectorFloatingFormat =
          prefixes.repeatPrefix == 0xF2 ? .scalarDouble : .scalarSingle
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .scalarSquareRoot(
          format: format,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm)
        )
      case 0x5A:
        // CVTSD2SS (F2 0F 5A) / CVTSS2SD (F3 0F 5A)
        guard prefixes.operandSizeOverride == false,
              prefixes.repeatPrefix == 0xF2 || prefixes.repeatPrefix == 0xF3 else {
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
        let direction: DoryX86ScalarConvertDirection =
          prefixes.repeatPrefix == 0xF2 ? .doubleToSingle : .singleToDouble
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .scalarConvert(
          direction: direction,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm)
        )
      case 0xC2:
        // CMPSS (F3 0F C2) / CMPSD (F2 0F C2) with immediate predicate
        guard prefixes.operandSizeOverride == false,
              prefixes.repeatPrefix == 0xF3 || prefixes.repeatPrefix == 0xF2 else {
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
        let format: DoryX86VectorFloatingFormat =
          prefixes.repeatPrefix == 0xF2 ? .scalarDouble : .scalarSingle
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let predicate = try cursor.readByte()
        guard let comparePredicate = DoryX86ScalarComparePredicate(rawValue: predicate) else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "scalar compare predicate must be 0-7")
        }
        operation = .scalarCompare(
          predicate: comparePredicate,
          format: format,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm)
        )
      case 0x58, 0x59, 0x5C...0x5F:
        let format = try vectorFloatingFormat(prefixes: prefixes, address: address)
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let floatingOperation: DoryX86VectorFloatingOperation =
          switch second {
          case 0x58: .add
          case 0x59: .multiply
          case 0x5C: .subtract
          case 0x5D: .minimum
          case 0x5E: .divide
          default: .maximum
          }
        operation = .vectorFloatingBinary(
          floatingOperation,
          format: format,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm)
        )
      case 0x60...0x62, 0x68...0x6A, 0x6C, 0x6D:
        let mmx = !prefixes.operandSizeOverride
        guard prefixes.repeatPrefix == nil, !mmx || second != 0x6C && second != 0x6D else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer interleave requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let laneWidth: DoryX86VectorLaneWidth =
          switch second {
          case 0x60, 0x68: .byte
          case 0x61, 0x69: .word
          case 0x62, 0x6A: .doubleword
          default: .quadword
          }
        let high = second == 0x68 || second == 0x69 || second == 0x6A || second == 0x6D
        if mmx {
          operation = .mmxIntegerInterleave(
            high: high,
            laneWidth: laneWidth,
            destination: try mmxRegister(operands.reg, address: address),
            source: try mmxOperand(operands.rm, address: address)
          )
        } else {
          operation = .vectorIntegerInterleave(
            high: high,
            laneWidth: laneWidth,
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm)
          )
        }
      case 0x63, 0x67, 0x6B:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer narrowing rejects repeat prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let packOperation: DoryX86VectorPackOperation =
          second == 0x67 ? .unsignedSaturating : .signedSaturating
        let sourceLaneWidth: DoryX86VectorLaneWidth = second == 0x6B ? .doubleword : .word
        if prefixes.operandSizeOverride {
          operation = .vectorIntegerPack(
            packOperation,
            sourceLaneWidth: sourceLaneWidth,
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm)
          )
        } else {
          operation = .mmxIntegerPack(
            packOperation,
            sourceLaneWidth: sourceLaneWidth,
            destination: try mmxRegister(operands.reg, address: address),
            source: try mmxOperand(operands.rm, address: address)
          )
        }
      case 0x64...0x66, 0x74...0x76, 0xD4, 0xD5, 0xD8...0xDA, 0xDC...0xDE, 0xE0, 0xE3,
        0xE4, 0xE5, 0xE8...0xEA, 0xEC...0xEE, 0xF4...0xFE:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer XMM operation requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let integerOperation: DoryX86VectorIntegerOperation
        let laneWidth: DoryX86VectorLaneWidth
        switch second {
        case 0x64: (integerOperation, laneWidth) = (.greaterThan, .byte)
        case 0x65: (integerOperation, laneWidth) = (.greaterThan, .word)
        case 0x66: (integerOperation, laneWidth) = (.greaterThan, .doubleword)
        case 0x74: (integerOperation, laneWidth) = (.equal, .byte)
        case 0x75: (integerOperation, laneWidth) = (.equal, .word)
        case 0x76: (integerOperation, laneWidth) = (.equal, .doubleword)
        case 0xD4: (integerOperation, laneWidth) = (.add, .quadword)
        case 0xD5: (integerOperation, laneWidth) = (.multiplyLow, .word)
        case 0xD8: (integerOperation, laneWidth) = (.subtractUnsignedSaturating, .byte)
        case 0xD9: (integerOperation, laneWidth) = (.subtractUnsignedSaturating, .word)
        case 0xDA: (integerOperation, laneWidth) = (.minimumUnsigned, .byte)
        case 0xDC: (integerOperation, laneWidth) = (.addUnsignedSaturating, .byte)
        case 0xDD: (integerOperation, laneWidth) = (.addUnsignedSaturating, .word)
        case 0xDE: (integerOperation, laneWidth) = (.maximumUnsigned, .byte)
        case 0xE0: (integerOperation, laneWidth) = (.averageUnsigned, .byte)
        case 0xE3: (integerOperation, laneWidth) = (.averageUnsigned, .word)
        case 0xE4: (integerOperation, laneWidth) = (.multiplyHighUnsigned, .word)
        case 0xE5: (integerOperation, laneWidth) = (.multiplyHighSigned, .word)
        case 0xE8: (integerOperation, laneWidth) = (.subtractSignedSaturating, .byte)
        case 0xE9: (integerOperation, laneWidth) = (.subtractSignedSaturating, .word)
        case 0xEA: (integerOperation, laneWidth) = (.minimumSigned, .word)
        case 0xEC: (integerOperation, laneWidth) = (.addSignedSaturating, .byte)
        case 0xED: (integerOperation, laneWidth) = (.addSignedSaturating, .word)
        case 0xEE: (integerOperation, laneWidth) = (.maximumSigned, .word)
        case 0xF4: (integerOperation, laneWidth) = (.multiplyUnsignedDoubleword, .doubleword)
        case 0xF5: (integerOperation, laneWidth) = (.multiplyAddWords, .word)
        case 0xF6: (integerOperation, laneWidth) = (.sumAbsoluteDifferences, .byte)
        case 0xF8: (integerOperation, laneWidth) = (.subtract, .byte)
        case 0xF9: (integerOperation, laneWidth) = (.subtract, .word)
        case 0xFA: (integerOperation, laneWidth) = (.subtract, .doubleword)
        case 0xFB: (integerOperation, laneWidth) = (.subtract, .quadword)
        case 0xFC: (integerOperation, laneWidth) = (.add, .byte)
        case 0xFD: (integerOperation, laneWidth) = (.add, .word)
        default: (integerOperation, laneWidth) = (.add, .doubleword)
        }
        if prefixes.operandSizeOverride {
          operation = .vectorIntegerBinary(
            integerOperation,
            laneWidth: laneWidth,
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm)
          )
        } else {
          operation = .mmxIntegerBinary(
            integerOperation,
            laneWidth: laneWidth,
            destination: try mmxRegister(operands.reg, address: address),
            source: try mmxOperand(operands.rm, address: address)
          )
        }
      case 0x6E:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVD/MOVQ rejects repeat prefixes")
        }
        let integerWidth: DoryX86OperandWidth = prefixes.rex?.w == true ? .quadword : .doubleword
        let operands = try decodeModRM(
          cursor: &cursor, width: integerWidth, prefixes: prefixes, mode: mode)
        if prefixes.operandSizeOverride {
          operation = .moveIntegerToVector(
            destination: vectorRegister(operands.reg), source: operands.rm)
        } else {
          operation = .moveIntegerToMMX(
            destination: try mmxRegister(operands.reg, address: address), source: operands.rm)
        }
      case 0x6F:
        let alignedVector = prefixes.operandSizeOverride && prefixes.repeatPrefix == nil
        let unalignedVector = prefixes.repeatPrefix == 0xF3 && !prefixes.operandSizeOverride
        let mmx = prefixes.repeatPrefix == nil && !prefixes.operandSizeOverride
        guard alignedVector || unalignedVector || mmx else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported 0F 6F mandatory prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        if mmx {
          operation = .moveMMX(
            destination: try mmxOperand(operands.reg, address: address),
            source: try mmxOperand(operands.rm, address: address),
            byteCount: 8
          )
        } else {
          operation = .moveVector128(
            destination: vectorOperand(operands.reg),
            source: vectorOperand(operands.rm),
            requiresAlignment: alignedVector
          )
        }
      case 0x70:
        guard prefixes.operandSizeOverride, prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "PSHUFD requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .vectorShuffle(
          format: .packedDoublewords,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm),
          control: try cursor.readByte()
        )
      case 0x71...0x73:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer immediate shift requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        guard case .register = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer immediate shift requires XMM destination")
        }
        let immediate = try cursor.readByte()
        if second == 0x73, prefixes.operandSizeOverride,
          operands.group == 3 || operands.group == 7
        {
          operation = .vectorByteShift(
            left: operands.group == 7,
            destination: vectorRegister(operands.rm),
            count: immediate
          )
          break
        }
        let shiftOperation: DoryX86VectorShiftOperation
        switch operands.group {
        case 2: shiftOperation = .logicalRight
        case 4 where second != 0x73: shiftOperation = .arithmeticRight
        case 6: shiftOperation = .logicalLeft
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "reserved packed integer immediate shift group")
        }
        let laneWidth: DoryX86VectorLaneWidth =
          switch second {
          case 0x71: .word
          case 0x72: .doubleword
          default: .quadword
          }
        if prefixes.operandSizeOverride {
          operation = .vectorIntegerShift(
            shiftOperation,
            laneWidth: laneWidth,
            destination: vectorRegister(operands.rm),
            count: .immediate(immediate)
          )
        } else {
          operation = .mmxIntegerShift(
            shiftOperation,
            laneWidth: laneWidth,
            destination: try mmxRegister(operands.rm, address: address),
            count: .immediate(immediate)
          )
        }
      case 0x7F:
        let alignedVector = prefixes.operandSizeOverride && prefixes.repeatPrefix == nil
        let unalignedVector = prefixes.repeatPrefix == 0xF3 && !prefixes.operandSizeOverride
        let mmx = prefixes.repeatPrefix == nil && !prefixes.operandSizeOverride
        guard alignedVector || unalignedVector || mmx else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported 0F 7F mandatory prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        if mmx {
          operation = .moveMMX(
            destination: try mmxOperand(operands.rm, address: address),
            source: try mmxOperand(operands.reg, address: address),
            byteCount: 8
          )
        } else {
          operation = .moveVector128(
            destination: vectorOperand(operands.rm),
            source: vectorOperand(operands.reg),
            requiresAlignment: alignedVector
          )
        }
      case 0xC3:
        guard prefixes.repeatPrefix == nil, !prefixes.operandSizeOverride else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVNTI rejects mandatory and operand-size prefixes")
        }
        let integerWidth: DoryX86OperandWidth =
          prefixes.rex?.w == true ? .quadword : .doubleword
        let operands = try decodeModRM(
          cursor: &cursor, width: integerWidth, prefixes: prefixes, mode: mode)
        guard case .memory = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVNTI requires a memory destination")
        }
        operation = .move(destination: operands.rm, source: operands.reg)
      case 0xC5:
        guard prefixes.repeatPrefix == nil, prefixes.rex?.w != true else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "PEXTRW rejects repeat and REX.W prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
        guard case .register = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "PEXTRW requires a packed register source")
        }
        let mmx = !prefixes.operandSizeOverride
        operation = .extractPackedWord(
          destination: operands.reg,
          source: mmx
            ? try mmxRegister(operands.rm, address: address)
            : vectorRegister(operands.rm),
          index: try cursor.readByte(),
          mmx: mmx
        )
      case 0xE7:
        guard prefixes.operandSizeOverride, prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVNTDQ requires the 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        guard case .memory = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVNTDQ requires a memory destination")
        }
        operation = .moveVector128(
          destination: vectorOperand(operands.rm),
          source: vectorOperand(operands.reg),
          requiresAlignment: true
        )
      case 0xD1...0xD3, 0xE1, 0xE2, 0xF1...0xF3:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed integer variable shift requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        let shiftOperation: DoryX86VectorShiftOperation =
          switch second {
          case 0xD1...0xD3: .logicalRight
          case 0xE1, 0xE2: .arithmeticRight
          default: .logicalLeft
          }
        let laneWidth: DoryX86VectorLaneWidth =
          switch second {
          case 0xD1, 0xE1, 0xF1: .word
          case 0xD2, 0xE2, 0xF2: .doubleword
          default: .quadword
          }
        if prefixes.operandSizeOverride {
          operation = .vectorIntegerShift(
            shiftOperation,
            laneWidth: laneWidth,
            destination: vectorRegister(operands.reg),
            count: .vector(vectorOperand(operands.rm))
          )
        } else {
          operation = .mmxIntegerShift(
            shiftOperation,
            laneWidth: laneWidth,
            destination: try mmxRegister(operands.reg, address: address),
            count: .vector(try mmxOperand(operands.rm, address: address))
          )
        }
      case 0xD7:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed byte move mask rejects repeat prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
        guard case .register = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed byte move mask requires register source")
        }
        operation = .moveVectorMask(
          destination: operands.reg,
          source: prefixes.operandSizeOverride
            ? vectorOperand(operands.rm) : try mmxOperand(operands.rm, address: address),
          laneWidth: .byte,
          vectorByteCount: prefixes.operandSizeOverride ? 16 : 8
        )
      case 0x7E:
        if prefixes.repeatPrefix == nil {
          let integerWidth: DoryX86OperandWidth =
            prefixes.rex?.w == true ? .quadword : .doubleword
          let operands = try decodeModRM(
            cursor: &cursor, width: integerWidth, prefixes: prefixes, mode: mode)
          if prefixes.operandSizeOverride {
            operation = .moveVectorToInteger(
              destination: operands.rm, source: vectorRegister(operands.reg))
          } else {
            operation = .moveMMXToInteger(
              destination: operands.rm,
              source: try mmxRegister(operands.reg, address: address)
            )
          }
        } else if prefixes.repeatPrefix == 0xF3, !prefixes.operandSizeOverride {
          let operands = try decodeModRM(
            cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
          operation = .moveVectorScalar(
            destination: vectorOperand(operands.reg),
            source: vectorOperand(operands.rm),
            byteCount: 8,
            upperPolicy: .zero
          )
        } else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported 0F 7E mandatory prefix")
        }
      case 0x77:
        guard prefixes.repeatPrefix == nil, !prefixes.operandSizeOverride else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "EMMS rejects mandatory prefixes")
        }
        operation = .emptyMMXState
      case 0xD6:
        guard prefixes.operandSizeOverride, prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "MOVQ from XMM requires 66 prefix")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .moveVectorToInteger(
          destination: operands.rm, source: vectorRegister(operands.reg))
      case 0xC6:
        guard prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "packed floating shuffle rejects repeat prefixes")
        }
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        operation = .vectorShuffle(
          format: prefixes.operandSizeOverride ? .packedDouble : .packedSingle,
          destination: vectorRegister(operands.reg),
          source: vectorOperand(operands.rm),
          control: try cursor.readByte()
        )
      case 0xA3, 0xAB, 0xB3, 0xBB:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        let bitOperation: DoryX86BitOperation =
          switch second {
          case 0xA3: .test
          case 0xAB: .set
          case 0xB3: .reset
          default: .complement
          }
        operation = .bitTest(bitOperation, base: operands.rm, index: operands.reg)
      case 0xA4, 0xA5, 0xAC, 0xAD:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        let count: DoryX86ShiftCount =
          second == 0xA4 || second == 0xAC
          ? .immediate(try cursor.readByte())
          : .cl
        operation = .doubleShift(
          second == 0xA4 || second == 0xA5 ? .left : .right,
          destination: operands.rm,
          source: operands.reg,
          count: count
        )
      case 0x40...0x4F:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        operation = .conditionalMove(
          DoryX86Condition(rawValue: second - 0x40)!,
          destination: operands.reg,
          source: operands.rm
        )
      case 0x80...0x8F:
        operation = .conditionalJump(
          DoryX86Condition(rawValue: second - 0x80)!,
          relative: Int64(try cursor.readSigned(byteCount: width == .word ? 2 : 4))
        )
      case 0x90...0x9F:
        let operands = try decodeModRM(
          cursor: &cursor, width: .byte, prefixes: prefixes, mode: mode)
        operation = .setCondition(
          DoryX86Condition(rawValue: second - 0x90)!,
          destination: operands.rm
        )
      case 0xAF:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        operation = .signedMultiply(
          destination: operands.reg,
          lhs: operands.reg,
          rhs: operands.rm
        )
      case 0xBC, 0xBD:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        operation = .bitScan(
          reverse: second == 0xBD,
          destination: operands.reg,
          source: operands.rm
        )
      case 0xB0, 0xB1:
        let operandWidth: DoryX86OperandWidth = second == 0xB0 ? .byte : width
        let operands = try decodeModRM(
          cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
        operation = .compareExchange(destination: operands.rm, source: operands.reg)
      case 0xB6, 0xB7, 0xBE, 0xBF:
        let sourceWidth: DoryX86OperandWidth = second == 0xB6 || second == 0xBE ? .byte : .word
        let operands = try decodeModRM(
          cursor: &cursor, width: sourceWidth, prefixes: prefixes, mode: mode)
        operation = .extendMove(
          destination: .register(
            register(Int(operands.group), extensionBit: prefixes.rex?.r == true),
            width: width
          ),
          source: operands.rm,
          signed: second == 0xBE || second == 0xBF
        )
      case 0xBA:
        let operands = try decodeModRM(
          cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
        let bitOperation: DoryX86BitOperation =
          switch operands.group {
          case 4: .test
          case 5: .set
          case 6: .reset
          case 7: .complement
          default:
            throw DoryX86DecodeError.invalidEncoding(
              address: address, detail: "unsupported 0F BA bit group")
          }
        operation = .bitTest(
          bitOperation,
          base: operands.rm,
          index: .immediate(try cursor.readUnsigned(byteCount: 1), width: .byte)
        )
      case 0xC0, 0xC1:
        let operandWidth: DoryX86OperandWidth = second == 0xC0 ? .byte : width
        let operands = try decodeModRM(
          cursor: &cursor, width: operandWidth, prefixes: prefixes, mode: mode)
        operation = .exchangeAdd(destination: operands.rm, source: operands.reg)
      case 0xC7:
        let operands = try decodeModRM(
          cursor: &cursor,
          width: prefixes.rex?.w == true ? .quadword : .doubleword,
          prefixes: prefixes,
          mode: mode
        )
        guard operands.group == 1, case .memory(let destination) = operands.rm else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "CMPXCHG8B/16B requires a memory /1 operand")
        }
        operation = .compareExchangePair(
          destination: destination,
          doubleQuadword: prefixes.rex?.w == true
        )
      case 0xC8...0xCF:
        let target = register(Int(second - 0xC8), extensionBit: prefixes.rex?.b == true)
        operation = .byteSwap(
          .register(target, width: prefixes.rex?.w == true ? .quadword : .doubleword)
        )
      case 0x38:
        // Three-byte opcode map 0F 38 (SSSE3/SSE4.1). Only the 66-prefixed 128-bit
        // XMM forms are decoded here; other mandatory prefixes are reserved.
        guard prefixes.operandSizeOverride, prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
        let third = try cursor.readByte()
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        switch third {
        case 0x00:
          operation = .shufflePackedBytes(
            destination: vectorRegister(operands.reg), source: vectorOperand(operands.rm))
        case 0x17:
          operation = .testPackedBits(
            destination: vectorRegister(operands.reg), source: vectorOperand(operands.rm))
        case 0x25:
          operation = .extendPackedDwordToQword(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            signed: true
          )
        case 0x35:
          operation = .extendPackedDwordToQword(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            signed: false
          )
        case 0x22:
          // PMOVSXBQ: sign-extend 2 low bytes to 2 quadwords. SSE4.1.
          operation = .extendPackedByteToQword(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            signed: true
          )
        case 0x29:
          // PCMPEQQ: compare packed quadwords for equality. SSE4.1.
          operation = .comparePackedQwords(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm)
          )
        default:
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
      case 0x3A:
        // Three-byte opcode map 0F 3A (SSSE3/SSE4 immediate forms). 66-prefixed
        // 128-bit XMM forms only; other mandatory prefixes are reserved.
        guard prefixes.operandSizeOverride, prefixes.repeatPrefix == nil else {
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
        let third = try cursor.readByte()
        let operands = try decodeModRM(
          cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
        switch third {
        case 0x0F:
          operation = .alignPackedBytes(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            count: try cursor.readByte()
          )
        case 0x22:
          // PINSRQ: insert qword from GPR/memory into XMM lane. SSE4.1.
          // REX.W selects 64-bit operand width.
          let index = try cursor.readByte() & 0x01
          operation = .insertPackedQword(
            destination: vectorRegister(operands.reg),
            source: operands.rm,
            index: index
          )
        case 0x63:
          // PCMPISTRI (66 0F 3A 63): SSE4.2 packed compare implicit-length
          // strings, return index in ECX. The immediate controls the
          // comparison mode (data size, aggregation, polarity, output).
          let immediate = try cursor.readByte()
          operation = .packedCompareStringIndex(
            destination: vectorRegister(operands.reg),
            source: vectorOperand(operands.rm),
            immediate: immediate
          )
        default:
          throw DoryX86DecodeError.unsupportedOpcode(
            address: address, bytes: cursor.consumedBytes)
        }
      default:
        throw DoryX86DecodeError.unsupportedOpcode(
          address: address,
          bytes: cursor.consumedBytes
        )
      }
    default:
      throw DoryX86DecodeError.unsupportedOpcode(address: address, bytes: cursor.consumedBytes)
    }
    try validateLockPrefix(prefixes, operation: operation, address: address)
    guard cursor.offset <= 15 else { throw DoryX86DecodeError.instructionTooLong(address: address) }
    return DoryX86DecodedInstruction(
      address: address,
      bytes: cursor.consumedBytes,
      prefixes: prefixes,
      operation: operation
    )
  }

  private func validateLockPrefix(
    _ prefixes: DoryX86InstructionPrefixes,
    operation: DoryX86InstructionOperation,
    address: UInt64
  ) throws {
    guard prefixes.lock else { return }
    let valid: Bool =
      switch operation {
      case .alu(let operation, let destination, _):
        operation != .compare && operation != .test && isMemory(destination)
      case .unary(_, let operand):
        isMemory(operand)
      case .compareExchange(let destination, _), .exchangeAdd(let destination, _):
        isMemory(destination)
      case .exchange(let lhs, let rhs):
        isMemory(lhs) || isMemory(rhs)
      case .bitTest(let operation, let base, _):
        operation != .test && isMemory(base)
      case .compareExchangePair:
        true
      default:
        false
      }
    guard valid else {
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "LOCK requires a supported memory read-modify-write operand")
    }
  }

  private func isMemory(_ operand: DoryX86Operand) -> Bool {
    if case .memory = operand { return true }
    return false
  }

  private func decodeSystemRegisterModRM(
    cursor: inout Cursor,
    prefixes: DoryX86InstructionPrefixes,
    debug: Bool
  ) throws -> (control: UInt8, general: DoryX86GeneralRegister) {
    let byte = try cursor.readByte()
    // MOV CR/DR ignores ModRM.MOD. Even apparent memory/SIB/displacement forms
    // select a GPR and consume exactly this one byte (SDM 092 Vol. 2B pp. 4-32/35).
    let control = ((byte >> 3) & 7) | (prefixes.rex?.r == true ? 8 : 0)
    let valid = debug ? control < 8 : [0, 2, 3, 4, 8].contains(control)
    guard valid else {
      throw DoryX86DecodeError.invalidEncoding(
        address: cursor.address,
        detail: debug ? "MOV DR does not encode DR8 through DR15"
          : "MOV CR requires CR0, CR2, CR3, CR4 or CR8"
      )
    }
    let general = register(Int(byte & 7), extensionBit: prefixes.rex?.b == true)
    return (control, general)
  }

  private func operandWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    if mode == .long64, prefixes.rex?.w == true { return .quadword }
    let defaultsToWord = mode == .real16 || mode == .protected16
    if prefixes.operandSizeOverride { return defaultsToWord ? .doubleword : .word }
    return defaultsToWord ? .word : .doubleword
  }

  private func stackWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    if mode == .long64 { return prefixes.operandSizeOverride ? .word : .quadword }
    return operandWidth(mode: mode, prefixes: prefixes)
  }

  private func ioOperandWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    switch (mode, prefixes.operandSizeOverride) {
    case (.real16, false), (.protected16, false): .word
    case (.real16, true), (.protected16, true): .doubleword
    case (_, false): .doubleword
    case (_, true): .word
    }
  }

  private func register(_ lowBits: Int, extensionBit: Bool) -> DoryX86GeneralRegister {
    DoryX86GeneralRegister.allCases[lowBits | (extensionBit ? 8 : 0)]
  }

  private func registerOperand(
    _ lowBits: Int,
    extensionBit: Bool,
    width: DoryX86OperandWidth,
    rexPresent: Bool
  ) -> DoryX86Operand {
    if width == .byte, !rexPresent, !extensionBit, (4...7).contains(lowBits) {
      return .highByteRegister(DoryX86GeneralRegister.allCases[lowBits - 4])
    }
    return .register(register(lowBits, extensionBit: extensionBit), width: width)
  }

  private func vectorOperand(_ operand: DoryX86Operand) -> DoryX86VectorOperand {
    switch operand {
    case .register(let register, _):
      .register(UInt8(DoryX86GeneralRegister.allCases.firstIndex(of: register)!))
    case .memory(let memory):
      .memory(memory)
    default:
      preconditionFailure("ModRM vector operand must be a register or memory")
    }
  }

  /// Parse a 2-byte (`C5`) or 3-byte (`C4`) VEX prefix from the cursor. In
  /// long mode these bytes are unambiguously VEX (LES/LDS are not encodable).
  private func parseVEXPrefix(_ cursor: inout Cursor) throws -> DoryX86VEXPrefix {
    let marker = try cursor.readByte()  // C4 or C5
    if marker == 0xC5 {
      // 2-byte VEX: C5 [R~|vvvv~|L|pp]
      let byte = try cursor.readByte()
      let r = byte & 0x80 == 0          // inverted
      let vvvv = (~byte >> 3) & 0x0F    // inverted, 0 means no third operand
      let largeVector = byte & 0x04 != 0
      let pp = byte & 0x03
      return DoryX86VEXPrefix(
        vvvv: vvvv, largeVector: largeVector, r: r, x: false, b: false,
        w: false, map: 1, pp: pp)
    }
    // 3-byte VEX: C4 [R~|X~|B~|mmmmm] [W|vvvv~|L|pp]
    let byte1 = try cursor.readByte()
    let byte2 = try cursor.readByte()
    let r = byte1 & 0x80 == 0
    let x = byte1 & 0x40 == 0
    let b = byte1 & 0x20 == 0
    let map = byte1 & 0x1F
    let w = byte2 & 0x80 != 0
    let vvvv = (~byte2 >> 3) & 0x0F
    let largeVector = byte2 & 0x04 != 0
    let pp = byte2 & 0x03
    return DoryX86VEXPrefix(
      vvvv: vvvv, largeVector: largeVector, r: r, x: x, b: b,
      w: w, map: map, pp: pp)
  }

  /// Decode a VEX-prefixed opcode. The VEX prefix has already been parsed and
  /// the equivalent REX/mandatory-prefix state has been synthesized into
  /// `prefixes`. This method reads the opcode byte and ModRM, then dispatches
  /// to the appropriate VEX operation based on the opcode map.
  private func decodeVEXOpcode(
    _ vex: DoryX86VEXPrefix,
    opcode: UInt8,
    cursor: inout Cursor,
    prefixes: DoryX86InstructionPrefixes,
    mode: DoryX86ExecutionMode
  ) throws -> DoryX86InstructionOperation {
    let length: DoryX86VectorLength = vex.largeVector ? .ymm256 : .xmm128
    switch vex.map {
    case 1:  // 0F map
      return try decodeVEX0FOpcode(
        vex, opcode: opcode, cursor: &cursor, prefixes: prefixes,
        mode: mode, length: length)
    case 2:  // 0F 38 map
      return try decodeVEX0F38Opcode(
        vex, opcode: opcode, cursor: &cursor, prefixes: prefixes,
        mode: mode, length: length)
    default:
      throw DoryX86DecodeError.unsupportedOpcode(
        address: cursor.address, bytes: cursor.consumedBytes)
    }
  }

  /// Decode VEX instructions in the `0F` opcode map.
  private func decodeVEX0FOpcode(
    _ vex: DoryX86VEXPrefix,
    opcode: UInt8,
    cursor: inout Cursor,
    prefixes: DoryX86InstructionPrefixes,
    mode: DoryX86ExecutionMode,
    length: DoryX86VectorLength
  ) throws -> DoryX86InstructionOperation {
    switch opcode {
    case 0x10, 0x11:
      // VMOVUPS (pp=00) / VMOVSS (pp=F3) / VMOVSD (pp=F2) / VMOVAPS (pp=66)
      let isLoad = opcode == 0x10
      let aligned = vex.pp == 1  // 66 -> aligned
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let destination = vectorOperand(isLoad ? operands.reg : operands.rm)
      let source = vectorOperand(isLoad ? operands.rm : operands.reg)
      return .vexMoveVector(
        destination: destination, source: source,
        length: length, requiresAlignment: aligned)
    case 0x28, 0x29:
      // VMOVAPS (pp=66, aligned)
      let isLoad = opcode == 0x28
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let destination = vectorOperand(isLoad ? operands.reg : operands.rm)
      let source = vectorOperand(isLoad ? operands.rm : operands.reg)
      return .vexMoveVector(
        destination: destination, source: source,
        length: length, requiresAlignment: true)
    case 0x57:
      // VXORPS (pp=00) / VXORPD (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexVectorBinary(
        .xor, destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x54, 0x55, 0x56:
      // VANDPS/VANDNPS/VORPS (pp=00) / VANDPD/VANDNPD/VORPD (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let op: DoryX86VectorBitwiseOperation =
        switch opcode {
        case 0x54: .and
        case 0x55: .andNot
        default: .or
        }
      return .vexVectorBinary(
        op, destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F:
      // VADDSS/SD, VMULSS/SD, VSUBSS/SD, VMINSS/SD, VDIVSS/SD, VMAXSS/SD
      let format: DoryX86VectorFloatingFormat =
        switch vex.pp {
        case 1: .packedDouble    // 66 -> packed double (but scalar for these)
        case 2: .scalarSingle    // F3
        case 3: .scalarDouble    // F2
        default: .packedSingle   // no prefix
        }
      // For scalar forms (F2/F3), use scalar format; for packed (66/none), use packed
      let actualFormat: DoryX86VectorFloatingFormat =
        vex.pp == 3 ? .scalarDouble : (vex.pp == 2 ? .scalarSingle : (vex.pp == 1 ? .packedDouble : .packedSingle))
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let fpOp: DoryX86VectorFloatingOperation =
        switch opcode {
        case 0x58: .add
        case 0x59: .multiply
        case 0x5C: .subtract
        case 0x5D: .minimum
        case 0x5E: .divide
        default: .maximum
        }
      return .vexVectorFloatingBinary(
        fpOp, format: actualFormat,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x2E, 0x2F:
      // VUCOMISS/COMISS (pp=00) / VUCOMISD/COMISD (pp=66)
      // These are 2-operand (reg, rm), vvvv must be 0
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexCompareScalar(
        ordered: opcode == 0x2F,
        doublePrecision: vex.pp == 1,
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm))
    case 0x64, 0x65, 0x66, 0x74, 0x76:
      // VPCMPGTB (64) / VPCMPGTW (65) / VPCMPGTD (66) / VPCMPEQB (74) / VPCMPEQD (76)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let laneWidth: DoryX86VectorLaneWidth =
        switch opcode {
        case 0x64, 0x74: .byte
        case 0x65: .word
        default: .doubleword  // 0x66, 0x76
        }
      let isGreaterThan = opcode == 0x64 || opcode == 0x65 || opcode == 0x66
      return .vexComparePackedIntegers(
        greaterThan: isGreaterThan,
        laneWidth: laneWidth,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0xFC, 0xFD, 0xFE:
      // VPADDB (FC) / VPADDW (FD) / VPADDD (FE)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let laneWidth: DoryX86VectorLaneWidth =
        switch opcode {
        case 0xFC: .byte
        case 0xFD: .word
        default: .doubleword
        }
      return .vexAddPackedIntegers(
        laneWidth: laneWidth,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0xDB, 0xDF, 0xEB, 0xEF:
      // VPAND (DB) / VPANDN (DF) / VPOR (EB) / VPXOR (EF)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let op: DoryX86VectorBitwiseOperation =
        switch opcode {
        case 0xDB: .and
        case 0xDF: .andNot
        case 0xEB: .or
        default: .xor
        }
      return .vexVectorBinary(
        op, destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0xDA, 0xE2, 0xE3, 0xEA:
      // VPMINUB (DA) / VPSRLVD (E2) / VPSRAVD (E3) / VPMINSW (EA)
      // For now, decode DA and EA as packed min, E2/E3 as variable shifts
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      switch opcode {
      case 0xDA:
        return .vexPackedMinMax(
          signed: false, minimum: true, laneWidth: .byte,
          destination: vectorRegister(operands.reg),
          firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
          length: length)
      case 0xEA:
        return .vexPackedMinMax(
          signed: true, minimum: true, laneWidth: .word,
          destination: vectorRegister(operands.reg),
          firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
          length: length)
      default:
        // VPSRLVD/VPSRAVD: variable shift by packed count
        return .vexVariableShift(
          arithmetic: opcode == 0xE3,
          laneWidth: .doubleword,
          destination: vectorRegister(operands.reg),
          firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
          length: length)
      }
    case 0xD8, 0xD9, 0xFA, 0xFB:
      // VPSUBUSB (D8) / VPSUBUSW (D9) / VPSUBB (FA) / VPSUBW (FB)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let laneWidth: DoryX86VectorLaneWidth =
        (opcode == 0xD8 || opcode == 0xFA) ? .byte : .word
      let saturating = opcode == 0xD8 || opcode == 0xD9
      let unsigned = opcode == 0xD8 || opcode == 0xD9
      return .vexSubPackedIntegers(
        laneWidth: laneWidth, saturating: saturating, unsigned: unsigned,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x5A:
      // VCVTSD2SS (F2) / VCVTSS2SD (F3)
      let direction: DoryX86ScalarConvertDirection =
        vex.pp == 3 ? .doubleToSingle : .singleToDouble
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexScalarConvert(
        direction: direction,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm))
    case 0x2C, 0x2D:
      // VCVTTSD2SI (2C, F2) / VCVTSD2SI (2D, F2) / VCVTTSS2SI (2C, F3) / VCVTSS2SI (2D, F3)
      let operands = try decodeModRM(
        cursor: &cursor, width: vex.w ? .quadword : .doubleword,
        prefixes: prefixes, mode: mode)
      return .vexConvertScalarToInteger(
        truncated: opcode == 0x2C,
        doublePrecision: vex.pp == 3,
        destination: operands.rm,
        source: vectorRegister(operands.reg))
    case 0x14:
      // VUNPCKLPS (pp=00) / VUNPCKLPD (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexUnpackLow(
        doublePrecision: vex.pp == 1,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x15:
      // VUNPCKHPS (pp=00) / VUNPCKHPD (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexUnpackHigh(
        doublePrecision: vex.pp == 1,
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0xAE:
      // VLDMXCSR/VSTMXCSR (pp=66, group 2/3): load/store MXCSR from memory.
      let operands = try decodeModRM(
        cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
      switch operands.group {
      case 2:
        return .vexLoadMXCSR(source: operands.rm)
      case 3:
        return .vexStoreMXCSR(destination: operands.rm)
      default:
        throw DoryX86DecodeError.unsupportedOpcode(
          address: cursor.address, bytes: cursor.consumedBytes)
      }
    case 0x93:
      // KMOVD (C5 FB 93): move between mask register and GPR/vector.
      // For now, decode as a no-op mask move since Dory doesn't model AVX-512
      // mask registers — treat as a move of the low 32 bits.
      let operands = try decodeModRM(
        cursor: &cursor, width: .doubleword, prefixes: prefixes, mode: mode)
      return .vexMaskMove(
        destination: vectorRegister(operands.reg),
        source: operands.rm)
    case 0x6E:
      // VMOVD/VMOVQ (register from integer): 66 0F 6E, W=1 for VMOVQ
      let operands = try decodeModRM(
        cursor: &cursor, width: vex.w ? .quadword : .doubleword,
        prefixes: prefixes, mode: mode)
      return .vexMoveIntegerToVector(
        destination: vectorRegister(operands.reg),
        source: operands.rm, quadword: vex.w)
    case 0x7E:
      // VMOVD/VMOVQ (integer from register): 66 0F 7E, W=1 for VMOVQ
      let operands = try decodeModRM(
        cursor: &cursor, width: vex.w ? .quadword : .doubleword,
        prefixes: prefixes, mode: mode)
      return .vexMoveVectorToInteger(
        destination: operands.rm, source: vectorRegister(operands.reg),
        quadword: vex.w)
    case 0x6F:
      // VMOVDQA (pp=66, aligned) — load form: reg <- rm
      let operands6F = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexMoveVector(
        destination: vectorOperand(operands6F.reg),
        source: vectorOperand(operands6F.rm),
        length: length, requiresAlignment: true)
    case 0x7F:
      // VMOVDQA (pp=66, aligned) — store form: rm <- reg
      let operands7F = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexMoveVector(
        destination: vectorOperand(operands7F.rm),
        source: vectorOperand(operands7F.reg),
        length: length, requiresAlignment: true)
    case 0x73:
      // VPSRLQ/VPSLLQ/VPSRAD (pp=66): packed shift by immediate.
      // ModRM reg field selects the operation: /2 = VPSRLQ, /6 = VPSLLQ, /4 = VPSRAD
      let operands73 = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      let immediate = try cursor.readByte()
      let shiftOperation: DoryX86VectorShiftOperation
      switch operands73.group {
      case 2: shiftOperation = .logicalRight
      case 4: shiftOperation = .arithmeticRight
      case 6: shiftOperation = .logicalLeft
      default:
        throw DoryX86DecodeError.invalidEncoding(
          address: cursor.address,
          detail: "VEX 0F 73 group \(operands73.group) is not a valid packed shift")
      }
      return .vexVectorShiftImmediate(
        operation: shiftOperation,
        destination: vectorRegister(operands73.reg),
        source: vex.vvvv,
        immediate: immediate,
        laneWidth: .quadword,
        length: length)
    case 0x74:
      // VPCMPEQB (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexComparePackedBytes(
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x77:
      // VZEROUPPER / VZEROALL (L=0 -> VZEROUPPER, L=1 -> VZEROALL)
      return .vexZeroUpper
    case 0xD7:
      // VPMOVMSKB (pp=66): GPR width depends on VEX.W.
      let gprWidth: DoryX86OperandWidth = vex.w ? .quadword : .doubleword
      let operands = try decodeModRM(
        cursor: &cursor, width: gprWidth, prefixes: prefixes, mode: mode)
      return .vexMoveMaskToInteger(
        destination: operands.reg, source: vectorRegister(operands.rm),
        length: length)
    case 0xEB:
      // VPOR (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexVectorBinary(
        .or, destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0xEF:
      // VPXOR (pp=66)
      let operands = try decodeModRM(
        cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
      return .vexVectorBinary(
        .xor, destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    default:
      throw DoryX86DecodeError.unsupportedOpcode(
        address: cursor.address, bytes: cursor.consumedBytes)
    }
  }

  /// Decode VEX instructions in the `0F 38` opcode map.
  private func decodeVEX0F38Opcode(
    _ vex: DoryX86VEXPrefix,
    opcode: UInt8,
    cursor: inout Cursor,
    prefixes: DoryX86InstructionPrefixes,
    mode: DoryX86ExecutionMode,
    length: DoryX86VectorLength
  ) throws -> DoryX86InstructionOperation {
    // BMI1 flagless shifts (SHRX/SARX/SHLX) use opcode F7 with pp selecting
    // the direction. These operate on GPRs, not vector registers.
    if opcode == 0xF7 {
      let gprWidth: DoryX86OperandWidth = vex.w ? .quadword : .doubleword
      let operands = try decodeModRM(
        cursor: &cursor, width: gprWidth, prefixes: prefixes, mode: mode)
      let operation: DoryX86ShiftOperation
      switch vex.pp {
      case 1: operation = .shiftLeft       // 66 -> SHLX
      case 2: operation = .arithmeticShiftRight  // F3 -> SARX
      case 3: operation = .shiftRight      // F2 -> SHRX
      default:
        throw DoryX86DecodeError.invalidEncoding(
          address: cursor.address,
          detail: "BMI1 shift requires 66/F3/F2 mandatory prefix")
      }
      // vvvv encodes the count register; reg is destination, rm is source.
      let countRegister = register(Int(vex.vvvv), extensionBit: false)
      return .flaglessShift(
        operation,
        destination: operands.reg,
        source: operands.rm,
        count: .register(countRegister, width: gprWidth)
      )
    }
    guard vex.pp == 1 else {  // 66 mandatory prefix for all 0F38 VEX vector forms
      throw DoryX86DecodeError.unsupportedOpcode(
        address: cursor.address, bytes: cursor.consumedBytes)
    }
    let operands = try decodeModRM(
      cursor: &cursor, width: .quadword, prefixes: prefixes, mode: mode)
    switch opcode {
    case 0x00:
      // VPSHUFB
      return .vexShufflePackedBytes(
        destination: vectorRegister(operands.reg),
        firstSource: vex.vvvv, secondSource: vectorOperand(operands.rm),
        length: length)
    case 0x18:
      // VBROADCASTSS
      return .vexBroadcast(
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm), mode: .single32, length: length)
    case 0x19:
      // VBROADCASTSD (requires L=1)
      return .vexBroadcast(
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm), mode: .double64, length: length)
    case 0x1A:
      // VBROADCASTF128 (requires L=1)
      return .vexBroadcast(
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm), mode: .packed128, length: length)
    case 0x5A:
      // VBROADCASTI128 (requires L=1)
      return .vexBroadcast(
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm), mode: .packed128, length: length)
    case 0x78:
      // VPBROADCASTB
      return .vexBroadcast(
        destination: vectorRegister(operands.reg),
        source: vectorOperand(operands.rm), mode: .single32, length: length)
    default:
      throw DoryX86DecodeError.unsupportedOpcode(
        address: cursor.address, bytes: cursor.consumedBytes)
    }
  }

  private func vectorRegister(_ operand: DoryX86Operand) -> UInt8 {
    guard case .register(let register, _) = operand else {
      preconditionFailure("ModRM reg operand must be a register")
    }
    return UInt8(DoryX86GeneralRegister.allCases.firstIndex(of: register)!)
  }

  private func mmxRegister(_ operand: DoryX86Operand, address: UInt64) throws -> UInt8 {
    let register = vectorRegister(operand)
    guard register < 8 else {
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "MMX register encoding exceeds MM7")
    }
    return register
  }

  private func mmxOperand(
    _ operand: DoryX86Operand,
    address: UInt64
  ) throws -> DoryX86VectorOperand {
    if case .register = operand {
      return .register(try mmxRegister(operand, address: address))
    }
    return vectorOperand(operand)
  }

  private func vectorFloatingFormat(
    prefixes: DoryX86InstructionPrefixes,
    address: UInt64
  ) throws -> DoryX86VectorFloatingFormat {
    switch (prefixes.repeatPrefix, prefixes.operandSizeOverride) {
    case (nil, false): return .packedSingle
    case (nil, true): return .packedDouble
    case (0xF3, false): return .scalarSingle
    case (0xF2, false): return .scalarDouble
    default:
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "unsupported floating-point mandatory prefix")
    }
  }

  private func signExtend(
    _ value: UInt64,
    from source: DoryX86OperandWidth,
    to destination: DoryX86OperandWidth
  ) -> UInt64 {
    guard source.rawValue < destination.rawValue else { return value }
    let signBit = UInt64(1) << UInt64(source.rawValue - 1)
    let sourceMask = (UInt64(1) << UInt64(source.rawValue)) - 1
    return value & signBit == 0 ? value & sourceMask : value | ~sourceMask
  }

  private func resizedOperand(
    _ operand: DoryX86Operand,
    to width: DoryX86OperandWidth
  ) -> DoryX86Operand {
    switch operand {
    case .register(let register, _):
      .register(register, width: width)
    case .memory(let memory):
      .memory(
        .init(
          base: memory.base,
          index: memory.index,
          scale: memory.scale,
          displacement: memory.displacement,
          ripRelative: memory.ripRelative,
          width: width,
          addressWidth: memory.addressWidth,
          segment: memory.segment,
          ignoresLegacySegmentBase: memory.ignoresLegacySegmentBase
        ))
    case .immediate(let value, _):
      .immediate(value, width: width)
    case .relative(let value, _):
      .relative(value, width: width)
    case .highByteRegister:
      operand
    }
  }

  private func aluOperation(group: UInt8, address: UInt64) throws -> DoryX86ALUOperation {
    switch group {
    case 0: .add
    case 1: .or
    case 2: .addWithCarry
    case 3: .subtractWithBorrow
    case 4: .and
    case 5: .subtract
    case 6: .xor
    case 7: .compare
    default:
      throw DoryX86DecodeError.invalidEncoding(address: address, detail: "invalid ALU group")
    }
  }

  private func shiftOperation(group: UInt8, address: UInt64) throws -> DoryX86ShiftOperation {
    switch group {
    case 0: .rotateLeft
    case 1: .rotateRight
    case 2: .rotateCarryLeft
    case 3: .rotateCarryRight
    case 4: .shiftLeft
    case 5: .shiftRight
    case 7: .arithmeticShiftRight
    default:
      throw DoryX86DecodeError.invalidEncoding(address: address, detail: "invalid shift group")
    }
  }

  private func x87BinaryOperation(
    group: UInt8,
    address: UInt64
  ) throws -> DoryX87BinaryOperation {
    switch group {
    case 0: .add
    case 1: .multiply
    case 4: .subtract
    case 5: .subtractReverse
    case 6: .divide
    case 7: .divideReverse
    default:
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "x87 group is not a binary arithmetic operation")
    }
  }

  private struct ModRMOperands {
    let rm: DoryX86Operand
    let reg: DoryX86Operand
    let group: UInt8
  }

  private func decodeModRM(
    cursor: inout Cursor,
    width: DoryX86OperandWidth,
    prefixes: DoryX86InstructionPrefixes,
    mode: DoryX86ExecutionMode
  ) throws -> ModRMOperands {
    let byte = try cursor.readByte()
    let modeBits = byte >> 6
    let regBits = (byte >> 3) & 7
    let rmBits = byte & 7
    let regOperand = registerOperand(
      Int(regBits),
      extensionBit: prefixes.rex?.r == true,
      width: width,
      rexPresent: prefixes.rex != nil
    )
    if modeBits == 3 {
      return ModRMOperands(
        rm: registerOperand(
          Int(rmBits),
          extensionBit: prefixes.rex?.b == true,
          width: width,
          rexPresent: prefixes.rex != nil
        ),
        reg: regOperand,
        group: regBits
      )
    }

    let addressWidth = addressWidth(mode: mode, prefixes: prefixes)
    var base: DoryX86GeneralRegister?
    var index: DoryX86GeneralRegister?
    var scale: UInt8 = 1
    var ripRelative = false
    var displacement: Int64 = 0
    if addressWidth == .word {
      switch rmBits {
      case 0: (base, index) = (.rbx, .rsi)
      case 1: (base, index) = (.rbx, .rdi)
      case 2: (base, index) = (.rbp, .rsi)
      case 3: (base, index) = (.rbp, .rdi)
      case 4: base = .rsi
      case 5: base = .rdi
      case 6 where modeBits == 0:
        displacement = Int64(try cursor.readUnsigned(byteCount: 2))
      case 6: base = .rbp
      default: base = .rbx
      }
      if modeBits == 1 { displacement = Int64(try cursor.readSigned(byteCount: 1)) }
      if modeBits == 2 { displacement = Int64(try cursor.readSigned(byteCount: 2)) }
    } else if rmBits == 4 {
      let sib = try cursor.readByte()
      scale = UInt8(1 << (sib >> 6))
      let indexBits = (sib >> 3) & 7
      let baseBits = sib & 7
      if indexBits != 4 || prefixes.rex?.x == true {
        index = register(Int(indexBits), extensionBit: prefixes.rex?.x == true)
      }
      // MOD=00/SIB.base=101 has no base even with REX.B (SDM Vol. 2A Table 2-5).
      if modeBits == 0, baseBits == 5 {
        displacement = Int64(try cursor.readSigned(byteCount: 4))
      } else {
        base = register(Int(baseBits), extensionBit: prefixes.rex?.b == true)
      }
    } else if modeBits == 0, rmBits == 5 {
      displacement = Int64(try cursor.readSigned(byteCount: 4))
      // REX.B does not select R13 here. In 64-bit mode 67 retains RIP-relative
      // addressing; the common effective-offset path truncates the sum to 32 bits.
      ripRelative = mode == .long64
    } else {
      base = register(Int(rmBits), extensionBit: prefixes.rex?.b == true)
    }
    if addressWidth != .word {
      if modeBits == 1 { displacement = Int64(try cursor.readSigned(byteCount: 1)) }
      if modeBits == 2 { displacement = Int64(try cursor.readSigned(byteCount: 4)) }
    }
    let defaultSegment: DoryX86SegmentRegister =
      base == .rbp || base == .rsp || base == .r12 || base == .r13 ? .ss : .ds
    let segment = segmentRegister(prefixes.segmentOverride) ?? defaultSegment
    return ModRMOperands(
      rm: .memory(
        .init(
          base: base,
          index: index,
          scale: scale,
          displacement: displacement,
          ripRelative: ripRelative,
          width: width,
          addressWidth: addressWidth,
          segment: segment,
          ignoresLegacySegmentBase: mode == .long64
        )),
      reg: regOperand,
      group: regBits
    )
  }

  private func addressWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    switch (mode, prefixes.addressSizeOverride) {
    case (.real16, false), (.protected16, false), (.protected32, true): .word
    case (.real16, true), (.protected16, true), (.protected32, false), (.long64, true):
      .doubleword
    case (.long64, false): .quadword
    }
  }

  private func segmentRegister(_ prefix: UInt8?) -> DoryX86SegmentRegister? {
    switch prefix {
    case 0x2E: .cs
    case 0x36: .ss
    case 0x3E: .ds
    case 0x26: .es
    case 0x64: .fs
    case 0x65: .gs
    default: nil
    }
  }

  private func segmentRegister(
    encoding: UInt8,
    address: UInt64,
    allowCode: Bool
  ) throws -> DoryX86SegmentRegister {
    let segment: DoryX86SegmentRegister =
      switch encoding {
      case 0: .es
      case 1: .cs
      case 2: .ss
      case 3: .ds
      case 4: .fs
      case 5: .gs
      default:
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "invalid segment-register encoding")
      }
    if segment == .cs, !allowCode {
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "MOV cannot load CS")
    }
    return segment
  }
}

private struct Cursor {
  let input: ArraySlice<UInt8>
  let address: UInt64
  var offset = 0

  var consumedBytes: [UInt8] { Array(input.prefix(offset)) }
  func peek() -> UInt8? {
    offset < 15 && offset < input.count ? input[input.startIndex + offset] : nil
  }

  mutating func readByte() throws -> UInt8 {
    // Once 15 instruction bytes are consumed, even an absent next byte is an
    // overlength encoding, not a request to fetch byte 16 (Intel SDM Vol. 2A §2.2).
    guard offset < 15 else { throw DoryX86DecodeError.instructionTooLong(address: address) }
    guard offset < input.count else { throw DoryX86DecodeError.truncated(address: address) }
    defer { offset += 1 }
    return input[input.startIndex + offset]
  }

  mutating func readUnsigned(byteCount: Int) throws -> UInt64 {
    var result: UInt64 = 0
    for index in 0..<byteCount { result |= UInt64(try readByte()) << UInt64(index * 8) }
    return result
  }

  mutating func readSigned(byteCount: Int) throws -> Int64 {
    let value = try readUnsigned(byteCount: byteCount)
    switch byteCount {
    case 1: return Int64(Int8(bitPattern: UInt8(value)))
    case 2: return Int64(Int16(bitPattern: UInt16(value)))
    case 4: return Int64(Int32(bitPattern: UInt32(value)))
    case 8: return Int64(bitPattern: value)
    default:
      throw DoryX86DecodeError.invalidEncoding(
        address: address, detail: "invalid signed immediate width")
    }
  }
}
