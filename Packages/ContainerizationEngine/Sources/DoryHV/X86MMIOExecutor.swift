public struct X86RegisterState: Equatable, Sendable {
    private var values: [UInt64]

    public init(values: [UInt64] = Array(repeating: 0, count: 16)) {
        precondition(values.count == 16, "x86 register state requires 16 general-purpose registers")
        self.values = values
    }

    public func read(_ register: Int) -> UInt64 {
        guard (0..<values.count).contains(register) else { return 0 }
        return values[register]
    }

    public mutating func write(_ register: Int, value: UInt64, width: Int) {
        guard (0..<values.count).contains(register) else { return }
        switch width {
        case 1:
            values[register] = (values[register] & ~0xFF) | (value & 0xFF)
        case 2:
            values[register] = (values[register] & ~0xFFFF) | (value & 0xFFFF)
        case 4:
            values[register] = value & 0xFFFF_FFFF
        case 8:
            values[register] = value
        default:
            break
        }
    }
}

public enum X86MMIOExecutionError: Error, Equatable, CustomStringConvertible {
    case unmappedPhysicalAddress(UInt64)

    public var description: String {
        switch self {
        case .unmappedPhysicalAddress(let address):
            "x86 MMIO access to unmapped physical address 0x\(String(address, radix: 16))"
        }
    }
}

public enum X86MMIOExecutor {
    @discardableResult
    public static func execute(
        instruction: X86MMIOInstruction,
        physicalAddress: UInt64,
        bus: MMIOBus,
        registers: inout X86RegisterState
    ) throws -> Int {
        guard let (device, offset) = bus.device(for: physicalAddress) else {
            throw X86MMIOExecutionError.unmappedPhysicalAddress(physicalAddress)
        }

        switch instruction.access {
        case .read(let register, let width, let signExtend, let destinationWidth):
            let raw = device.read(offset: offset, width: width)
            let value = signExtend ? signExtendValue(raw, sourceWidth: width, destinationWidth: destinationWidth) : mask(raw, width: width)
            registers.write(register, value: value, width: destinationWidth)
        case .write(let register, let width):
            device.write(offset: offset, value: registers.read(register) & maskForWidth(width), width: width)
        case .writeImmediate(let value, let width):
            device.write(offset: offset, value: value & maskForWidth(width), width: width)
        }
        return instruction.length
    }

    private static func mask(_ value: UInt64, width: Int) -> UInt64 {
        value & maskForWidth(width)
    }

    private static func maskForWidth(_ width: Int) -> UInt64 {
        switch width {
        case 1: 0xFF
        case 2: 0xFFFF
        case 4: 0xFFFF_FFFF
        default: UInt64.max
        }
    }

    private static func signExtendValue(_ value: UInt64, sourceWidth: Int, destinationWidth: Int) -> UInt64 {
        let sourceBits = sourceWidth * 8
        let signBit = UInt64(1) << UInt64(sourceBits - 1)
        var extended = value & maskForWidth(sourceWidth)
        if extended & signBit != 0 {
            extended |= ~maskForWidth(sourceWidth)
        }
        return extended & maskForWidth(destinationWidth)
    }
}
