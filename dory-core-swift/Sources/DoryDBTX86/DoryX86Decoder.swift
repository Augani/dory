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
    var cursor = Cursor(input: input, address: address)
    var prefixes = DoryX86InstructionPrefixes()
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

    let opcode = try cursor.readByte()
    let width = operandWidth(mode: mode, prefixes: prefixes)
    let operation: DoryX86InstructionOperation
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
    case 0x9D:
      operation = .popFlags(width: stackWidth(mode: mode, prefixes: prefixes))
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
    case 0x50...0x57:
      let register = register(Int(opcode - 0x50), extensionBit: prefixes.rex?.b == true)
      operation = .push(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
    case 0x58...0x5F:
      let register = register(Int(opcode - 0x58), extensionBit: prefixes.rex?.b == true)
      operation = .pop(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
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
      case 4 where opcode == 0xFF: operation = .jumpIndirect(controlOperand)
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
    case 0xCF:
      operation = .interruptReturn
    case 0xCD:
      operation = .softwareInterrupt(vector: try cursor.readByte())
    case 0xE9:
      operation = .jump(
        relative: Int64(try cursor.readSigned(byteCount: width == .word ? 2 : 4)))
    case 0xEB:
      operation = .jump(relative: Int64(try cursor.readSigned(byteCount: 1)))
    case 0xEA:
      guard mode != .long64 else {
        throw DoryX86DecodeError.invalidEncoding(
          address: address, detail: "immediate far jump is invalid in 64-bit mode")
      }
      operation = .farJump(
        offset: try cursor.readUnsigned(byteCount: width == .word ? 2 : 4),
        selector: UInt16(try cursor.readUnsigned(byteCount: 2))
      )
    case 0x70...0x7F:
      operation = .conditionalJump(
        DoryX86Condition(rawValue: opcode - 0x70)!,
        relative: Int64(try cursor.readSigned(byteCount: 1))
      )
    case 0x0F:
      let second = try cursor.readByte()
      switch second {
      case 0x05:
        operation = .syscall
      case 0x06:
        operation = .clearTaskSwitched
      case 0x07:
        operation = .sysret
      case 0x20, 0x22:
        let operands = try decodeControlRegisterModRM(cursor: &cursor, prefixes: prefixes)
        operation =
          second == 0x20
          ? .readControlRegister(index: operands.control, destination: operands.general)
          : .writeControlRegister(index: operands.control, source: operands.general)
      case 0x30:
        operation = .writeModelSpecificRegister
      case 0x31:
        operation = .readTimestampCounter(includeAuxiliary: false)
      case 0x32:
        operation = .readModelSpecificRegister
      case 0x01:
        if cursor.peek() == 0xF8 {
          _ = try cursor.readByte()
          guard mode == .long64 else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address,
              detail: "SWAPGS requires 64-bit mode"
            )
          }
          operation = .swapGS
        } else if cursor.peek() == 0xF9 {
          _ = try cursor.readByte()
          operation = .readTimestampCounter(includeAuxiliary: true)
        } else {
          let operands = try decodeModRM(
            cursor: &cursor,
            width: .quadword,
            prefixes: prefixes,
            mode: mode
          )
          switch operands.group {
          case 4:
            operation = .machineStatusWord(
              load: false, operand: resizedOperand(operands.rm, to: .word))
          case 6:
            operation = .machineStatusWord(
              load: true, operand: resizedOperand(operands.rm, to: .word))
          case 0, 1, 2, 3, 7:
            guard case .memory(let memory) = operands.rm else {
              throw DoryX86DecodeError.invalidEncoding(
                address: address,
                detail: "0F 01 system-table instruction requires memory"
              )
            }
            switch operands.group {
            case 0: operation = .descriptorTable(.global, load: false, address: memory)
            case 1: operation = .descriptorTable(.interrupt, load: false, address: memory)
            case 2: operation = .descriptorTable(.global, load: true, address: memory)
            case 3: operation = .descriptorTable(.interrupt, load: true, address: memory)
            default: operation = .invalidatePage(memory)
            }
          default:
            throw DoryX86DecodeError.invalidEncoding(
              address: address,
              detail: "unsupported 0F 01 system instruction"
            )
          }
        }
      case 0xA2:
        operation = .cpuid
      case 0xAE:
        let modRM = try cursor.readByte()
        guard modRM >> 6 == 3, modRM & 7 == 0 else {
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "memory fence requires its fixed register encoding")
        }
        switch (modRM >> 3) & 7 {
        case 5: operation = .memoryFence(.load)
        case 6: operation = .memoryFence(.full)
        case 7: operation = .memoryFence(.store)
        default:
          throw DoryX86DecodeError.invalidEncoding(
            address: address, detail: "unsupported 0F AE group")
        }
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
          destination: resizedOperand(operands.reg, to: width),
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

  private func decodeControlRegisterModRM(
    cursor: inout Cursor,
    prefixes: DoryX86InstructionPrefixes
  ) throws -> (control: UInt8, general: DoryX86GeneralRegister) {
    let byte = try cursor.readByte()
    guard byte >> 6 == 3 else {
      throw DoryX86DecodeError.invalidEncoding(
        address: cursor.address,
        detail: "control-register MOV requires a register operand"
      )
    }
    let control = ((byte >> 3) & 7) | (prefixes.rex?.r == true ? 8 : 0)
    let general = register(Int(byte & 7), extensionBit: prefixes.rex?.b == true)
    return (control, general)
  }

  private func operandWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    if mode == .long64, prefixes.rex?.w == true { return .quadword }
    if prefixes.operandSizeOverride { return .word }
    return mode == .real16 ? .word : .doubleword
  }

  private func stackWidth(
    mode: DoryX86ExecutionMode,
    prefixes: DoryX86InstructionPrefixes
  ) -> DoryX86OperandWidth {
    if mode == .long64 { return prefixes.operandSizeOverride ? .word : .quadword }
    return operandWidth(mode: mode, prefixes: prefixes)
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
      if modeBits == 0, baseBits == 5, prefixes.rex?.b != true {
        displacement = Int64(try cursor.readSigned(byteCount: 4))
      } else {
        base = register(Int(baseBits), extensionBit: prefixes.rex?.b == true)
      }
    } else if modeBits == 0, rmBits == 5, prefixes.rex?.b != true {
      displacement = Int64(try cursor.readSigned(byteCount: 4))
      ripRelative = mode == .long64 && !prefixes.addressSizeOverride
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
    case (.real16, false), (.protected32, true): .word
    case (.real16, true), (.protected32, false), (.long64, true): .doubleword
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
  let input: [UInt8]
  let address: UInt64
  var offset = 0

  var consumedBytes: [UInt8] { Array(input.prefix(offset)) }
  func peek() -> UInt8? { offset < input.count ? input[offset] : nil }

  mutating func readByte() throws -> UInt8 {
    guard offset < input.count else { throw DoryX86DecodeError.truncated(address: address) }
    guard offset < 15 else { throw DoryX86DecodeError.instructionTooLong(address: address) }
    defer { offset += 1 }
    return input[offset]
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
