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
      operation = .noOperation
    case 0xF4:
      operation = .halt
    case 0xFA:
      operation = .setInterruptsEnabled(false)
    case 0xFB:
      operation = .setInterruptsEnabled(true)
    case 0x50...0x57:
      let register = register(Int(opcode - 0x50), extensionBit: prefixes.rex?.b == true)
      operation = .push(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
    case 0x58...0x5F:
      let register = register(Int(opcode - 0x58), extensionBit: prefixes.rex?.b == true)
      operation = .pop(.register(register, width: stackWidth(mode: mode, prefixes: prefixes)))
    case 0xB8...0xBF:
      let register = register(Int(opcode - 0xB8), extensionBit: prefixes.rex?.b == true)
      let immediate = try cursor.readUnsigned(byteCount: width.byteCount)
      operation = .move(
        destination: .register(register, width: width),
        source: .immediate(immediate, width: width)
      )
    case 0x89, 0x8B, 0x8D, 0x01, 0x03, 0x09, 0x0B, 0x21, 0x23,
      0x29, 0x2B, 0x31, 0x33, 0x39, 0x3B, 0x85:
      let operands = try decodeModRM(cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
      switch opcode {
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
      case 0x01: operation = .alu(.add, destination: operands.rm, source: operands.reg)
      case 0x03: operation = .alu(.add, destination: operands.reg, source: operands.rm)
      case 0x09: operation = .alu(.or, destination: operands.rm, source: operands.reg)
      case 0x0B: operation = .alu(.or, destination: operands.reg, source: operands.rm)
      case 0x21: operation = .alu(.and, destination: operands.rm, source: operands.reg)
      case 0x23: operation = .alu(.and, destination: operands.reg, source: operands.rm)
      case 0x29: operation = .alu(.subtract, destination: operands.rm, source: operands.reg)
      case 0x2B: operation = .alu(.subtract, destination: operands.reg, source: operands.rm)
      case 0x31: operation = .alu(.xor, destination: operands.rm, source: operands.reg)
      case 0x33: operation = .alu(.xor, destination: operands.reg, source: operands.rm)
      case 0x39: operation = .alu(.compare, destination: operands.rm, source: operands.reg)
      case 0x3B: operation = .alu(.compare, destination: operands.reg, source: operands.rm)
      default: operation = .alu(.test, destination: operands.rm, source: operands.reg)
      }
    case 0xC7:
      let operands = try decodeModRM(cursor: &cursor, width: width, prefixes: prefixes, mode: mode)
      guard operands.group == 0 else {
        throw DoryX86DecodeError.invalidEncoding(address: address, detail: "C7 group must be /0")
      }
      let encodedWidth: DoryX86OperandWidth = width == .quadword ? .doubleword : width
      let raw = try cursor.readUnsigned(byteCount: encodedWidth.byteCount)
      let immediate =
        width == .quadword
        ? UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: raw)))
        : raw
      operation = .move(
        destination: operands.rm,
        source: .immediate(immediate, width: width)
      )
    case 0xE8:
      operation = .call(relative: Int64(try cursor.readSigned(byteCount: 4)))
    case 0xC3:
      operation = .return
    case 0xE9:
      operation = .jump(relative: Int64(try cursor.readSigned(byteCount: 4)))
    case 0xEB:
      operation = .jump(relative: Int64(try cursor.readSigned(byteCount: 1)))
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
          guard operands.group == 7, case .memory(let memory) = operands.rm else {
            throw DoryX86DecodeError.invalidEncoding(
              address: address,
              detail: "unsupported 0F 01 system instruction"
            )
          }
          operation = .invalidatePage(memory)
        }
      case 0xA2:
        operation = .cpuid
      case 0x80...0x8F:
        operation = .conditionalJump(
          DoryX86Condition(rawValue: second - 0x80)!,
          relative: Int64(try cursor.readSigned(byteCount: 4))
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
    guard cursor.offset <= 15 else { throw DoryX86DecodeError.instructionTooLong(address: address) }
    return DoryX86DecodedInstruction(
      address: address,
      bytes: cursor.consumedBytes,
      prefixes: prefixes,
      operation: operation
    )
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
    let reg = register(Int(regBits), extensionBit: prefixes.rex?.r == true)
    let registerOperand = DoryX86Operand.register(reg, width: width)
    if modeBits == 3 {
      return ModRMOperands(
        rm: .register(register(Int(rmBits), extensionBit: prefixes.rex?.b == true), width: width),
        reg: registerOperand,
        group: regBits
      )
    }

    guard mode != .real16 else {
      throw DoryX86DecodeError.invalidEncoding(
        address: cursor.address,
        detail: "16-bit ModRM memory addressing is not implemented"
      )
    }
    var base: DoryX86GeneralRegister?
    var index: DoryX86GeneralRegister?
    var scale: UInt8 = 1
    var ripRelative = false
    var displacement: Int64 = 0
    if rmBits == 4 {
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
    if modeBits == 1 { displacement = Int64(try cursor.readSigned(byteCount: 1)) }
    if modeBits == 2 { displacement = Int64(try cursor.readSigned(byteCount: 4)) }
    return ModRMOperands(
      rm: .memory(
        .init(
          base: base,
          index: index,
          scale: scale,
          displacement: displacement,
          ripRelative: ripRelative,
          width: width
        )),
      reg: registerOperand,
      group: regBits
    )
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
