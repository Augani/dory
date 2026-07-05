import Foundation

public enum X86MMIOAccess: Equatable, Sendable {
    case read(register: Int, width: Int, signExtend: Bool, destinationWidth: Int)
    case write(register: Int, width: Int)
    case writeImmediate(value: UInt64, width: Int)
}

public struct X86MMIOInstruction: Equatable, Sendable {
    public let access: X86MMIOAccess
    public let length: Int
}

public enum X86MMIODecodeError: Error, Equatable, CustomStringConvertible {
    case empty
    case truncated(String)
    case unsupportedPrefix(UInt8)
    case unsupportedOpcode([UInt8])
    case registerAddressing
    case unsupportedAddressSizeOverride
    case unsupportedModRM(String)

    public var description: String {
        switch self {
        case .empty: "empty instruction"
        case .truncated(let field): "truncated instruction while reading \(field)"
        case .unsupportedPrefix(let byte): String(format: "unsupported x86 prefix 0x%02x", byte)
        case .unsupportedOpcode(let bytes):
            "unsupported x86 opcode " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        case .registerAddressing: "instruction does not address MMIO memory"
        case .unsupportedAddressSizeOverride: "address-size override is not supported for x86 MMIO decode"
        case .unsupportedModRM(let reason): "unsupported ModRM/SIB form: \(reason)"
        }
    }
}

public enum X86MMIODecoder {
    public static func decode(_ bytes: [UInt8]) throws -> X86MMIOInstruction {
        guard !bytes.isEmpty else { throw X86MMIODecodeError.empty }
        var cursor = 0
        var rex: UInt8 = 0
        var operandSizeOverride = false

        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch byte {
            case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0xF0, 0xF2, 0xF3:
                cursor += 1
            case 0x66:
                operandSizeOverride = true
                cursor += 1
            case 0x67:
                throw X86MMIODecodeError.unsupportedAddressSizeOverride
            case 0x40...0x4F:
                rex = byte
                cursor += 1
            default:
                break
            }
            if cursor < bytes.count, !isPrefix(bytes[cursor]) { break }
        }

        let opcode = try readByte(bytes, &cursor, "opcode")
        if opcode == 0x0F {
            let second = try readByte(bytes, &cursor, "two-byte opcode")
            switch second {
            case 0xB6, 0xB7, 0xBE, 0xBF:
                let modRM = try readModRM(bytes, &cursor)
                try consumeMemoryAddress(bytes, &cursor, modRM: modRM)
                let width = (second == 0xB6 || second == 0xBE) ? 1 : 2
                let destinationWidth = (rex & 0b1000) != 0 ? 8 : (operandSizeOverride ? 2 : 4)
                return X86MMIOInstruction(
                    access: .read(register: registerField(modRM: modRM, rex: rex), width: width, signExtend: second == 0xBE || second == 0xBF, destinationWidth: destinationWidth),
                    length: cursor
                )
            default:
                throw X86MMIODecodeError.unsupportedOpcode([0x0F, second])
            }
        }

        switch opcode {
        case 0x88, 0x89:
            let modRM = try readModRM(bytes, &cursor)
            try consumeMemoryAddress(bytes, &cursor, modRM: modRM)
            return X86MMIOInstruction(
                access: .write(register: registerField(modRM: modRM, rex: rex), width: operandWidth(opcode: opcode, rex: rex, operandSizeOverride: operandSizeOverride)),
                length: cursor
            )
        case 0x8A, 0x8B:
            let modRM = try readModRM(bytes, &cursor)
            try consumeMemoryAddress(bytes, &cursor, modRM: modRM)
            let width = operandWidth(opcode: opcode, rex: rex, operandSizeOverride: operandSizeOverride)
            return X86MMIOInstruction(
                access: .read(register: registerField(modRM: modRM, rex: rex), width: width, signExtend: false, destinationWidth: width),
                length: cursor
            )
        case 0xC6, 0xC7:
            let modRM = try readModRM(bytes, &cursor)
            guard ((modRM >> 3) & 0b111) == 0 else {
                throw X86MMIODecodeError.unsupportedModRM("C6/C7 extension must be /0")
            }
            try consumeMemoryAddress(bytes, &cursor, modRM: modRM)
            let width = operandWidth(opcode: opcode, rex: rex, operandSizeOverride: operandSizeOverride)
            let immediateWidth = opcode == 0xC6 ? 1 : min(width, 4)
            let raw = try readImmediate(bytes, &cursor, width: immediateWidth)
            let value = width > immediateWidth ? signExtend(raw, fromWidth: immediateWidth) : raw
            return X86MMIOInstruction(access: .writeImmediate(value: value, width: width), length: cursor)
        default:
            throw X86MMIODecodeError.unsupportedOpcode([opcode])
        }
    }

    private static func isPrefix(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x40...0x4F:
            true
        default:
            false
        }
    }

    private static func readByte(_ bytes: [UInt8], _ cursor: inout Int, _ field: String) throws -> UInt8 {
        guard cursor < bytes.count else { throw X86MMIODecodeError.truncated(field) }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private static func readModRM(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt8 {
        try readByte(bytes, &cursor, "ModRM")
    }

    private static func consumeMemoryAddress(_ bytes: [UInt8], _ cursor: inout Int, modRM: UInt8) throws {
        let mod = (modRM >> 6) & 0b11
        let rm = modRM & 0b111
        guard mod != 0b11 else { throw X86MMIODecodeError.registerAddressing }

        if rm == 0b100 {
            let sib = try readByte(bytes, &cursor, "SIB")
            let base = sib & 0b111
            if mod == 0, base == 0b101 {
                try skip(bytes, &cursor, count: 4, field: "SIB displacement")
            }
        } else if mod == 0, rm == 0b101 {
            try skip(bytes, &cursor, count: 4, field: "displacement")
        }

        switch mod {
        case 0b00:
            break
        case 0b01:
            try skip(bytes, &cursor, count: 1, field: "8-bit displacement")
        case 0b10:
            try skip(bytes, &cursor, count: 4, field: "32-bit displacement")
        default:
            throw X86MMIODecodeError.unsupportedModRM("unexpected mod \(mod)")
        }
    }

    private static func skip(_ bytes: [UInt8], _ cursor: inout Int, count: Int, field: String) throws {
        guard cursor + count <= bytes.count else { throw X86MMIODecodeError.truncated(field) }
        cursor += count
    }

    private static func registerField(modRM: UInt8, rex: UInt8) -> Int {
        let high = (rex & 0b0100) == 0 ? 0 : 8
        return Int((modRM >> 3) & 0b111) + high
    }

    private static func operandWidth(opcode: UInt8, rex: UInt8, operandSizeOverride: Bool) -> Int {
        if opcode == 0x88 || opcode == 0x8A || opcode == 0xC6 { return 1 }
        if (rex & 0b1000) != 0 { return 8 }
        return operandSizeOverride ? 2 : 4
    }

    private static func readImmediate(_ bytes: [UInt8], _ cursor: inout Int, width: Int) throws -> UInt64 {
        guard cursor + width <= bytes.count else { throw X86MMIODecodeError.truncated("immediate") }
        var value: UInt64 = 0
        for i in 0..<width {
            value |= UInt64(bytes[cursor + i]) << UInt64(i * 8)
        }
        cursor += width
        return value
    }

    private static func signExtend(_ value: UInt64, fromWidth width: Int) -> UInt64 {
        guard width > 0, width < 8 else { return value }
        let bits = UInt64(width * 8)
        let signBit = UInt64(1) << (bits - 1)
        guard value & signBit != 0 else { return value }
        return value | ~((UInt64(1) << bits) - 1)
    }
}
