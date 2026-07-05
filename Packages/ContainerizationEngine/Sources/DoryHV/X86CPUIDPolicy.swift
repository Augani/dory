public struct X86CPUIDResult: Equatable, Sendable {
    public var eax: UInt32
    public var ebx: UInt32
    public var ecx: UInt32
    public var edx: UInt32

    public init(eax: UInt32 = 0, ebx: UInt32 = 0, ecx: UInt32 = 0, edx: UInt32 = 0) {
        self.eax = eax
        self.ebx = ebx
        self.ecx = ecx
        self.edx = edx
    }
}

public enum X86CPUIDPolicy {
    public static let maxBasicLeaf: UInt32 = 0x0000_0001
    public static let maxExtendedLeaf: UInt32 = 0x8000_0008
    public static let maxHypervisorLeaf: UInt32 = 0x4000_0000

    public static func result(leaf: UInt32, subleaf: UInt32 = 0) -> X86CPUIDResult {
        switch leaf {
        case 0x0000_0000:
            return X86CPUIDResult(
                eax: maxBasicLeaf,
                ebx: ascii("Genu"),
                ecx: ascii("ntel"),
                edx: ascii("ineI")
            )
        case 0x0000_0001:
            return X86CPUIDResult(
                eax: 0x0006_0A00,
                ebx: 8 << 8,
                ecx: (1 << 0) | (1 << 9) | (1 << 13) | (1 << 19) | (1 << 20) | (1 << 23) | (1 << 24) | (1 << 31),
                edx: (1 << 0) | (1 << 4) | (1 << 5) | (1 << 8) | (1 << 9) | (1 << 12) | (1 << 13) | (1 << 15) | (1 << 19) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 26)
            )
        case 0x4000_0000:
            return X86CPUIDResult(
                eax: maxHypervisorLeaf,
                ebx: ascii("Dory"),
                ecx: ascii("HV  "),
                edx: ascii("    ")
            )
        case 0x8000_0000:
            return X86CPUIDResult(eax: maxExtendedLeaf)
        case 0x8000_0001:
            return X86CPUIDResult(
                ecx: 1 << 0,
                edx: (1 << 11) | (1 << 20) | (1 << 27) | (1 << 29)
            )
        case 0x8000_0007:
            return X86CPUIDResult(edx: 1 << 8)
        case 0x8000_0008:
            return X86CPUIDResult(eax: 0x0000_3028)
        default:
            _ = subleaf
            return X86CPUIDResult()
        }
    }

    private static func ascii(_ value: String) -> UInt32 {
        let bytes = Array(value.utf8.prefix(4)) + Array(repeating: UInt8(ascii: " "), count: max(0, 4 - value.utf8.count))
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }
}

public enum X86MSRAccess: Equatable, Sendable {
    case value(UInt64)
    case unsupported(UInt32)
}

public struct X86MSRPolicy: Equatable, Sendable {
    public static let ia32TSC: UInt32 = 0x0000_0010
    public static let ia32APICBase: UInt32 = 0x0000_001B
    public static let ia32SysenterCS: UInt32 = 0x0000_0174
    public static let ia32SysenterESP: UInt32 = 0x0000_0175
    public static let ia32SysenterEIP: UInt32 = 0x0000_0176
    public static let ia32PAT: UInt32 = 0x0000_0277
    public static let ia32EFER: UInt32 = 0xC000_0080
    public static let ia32STAR: UInt32 = 0xC000_0081
    public static let ia32LSTAR: UInt32 = 0xC000_0082
    public static let ia32CSTAR: UInt32 = 0xC000_0083
    public static let ia32SFMASK: UInt32 = 0xC000_0084
    public static let ia32KernelGSBase: UInt32 = 0xC000_0102
    public static let ia32TSCAux: UInt32 = 0xC000_0103

    private var values: [UInt32: UInt64]

    public init() {
        self.values = [
            Self.ia32APICBase: 0xFEE0_0800,
            Self.ia32PAT: 0x0007_0406_0007_0406,
            Self.ia32EFER: 0,
            Self.ia32SysenterCS: 0,
            Self.ia32SysenterESP: 0,
            Self.ia32SysenterEIP: 0,
            Self.ia32STAR: 0,
            Self.ia32LSTAR: 0,
            Self.ia32CSTAR: 0,
            Self.ia32SFMASK: 0,
            Self.ia32KernelGSBase: 0,
            Self.ia32TSCAux: 0,
        ]
    }

    public func read(_ msr: UInt32) -> X86MSRAccess {
        if msr == Self.ia32TSC {
            return .value(0)
        }
        guard let value = values[msr] else {
            return .unsupported(msr)
        }
        return .value(value)
    }

    public mutating func write(_ msr: UInt32, value: UInt64) -> X86MSRAccess {
        switch msr {
        case Self.ia32TSC:
            return .value(value)
        case Self.ia32APICBase:
            let masked = value & 0xFFFF_FFFF_FFFF_FD00
            values[msr] = masked
            return .value(masked)
        case Self.ia32EFER:
            let masked = value & 0x0000_0D01
            values[msr] = masked
            return .value(masked)
        case Self.ia32PAT:
            values[msr] = value
            return .value(value)
        case Self.ia32SysenterCS, Self.ia32SysenterESP, Self.ia32SysenterEIP,
             Self.ia32STAR, Self.ia32LSTAR, Self.ia32CSTAR, Self.ia32SFMASK, Self.ia32KernelGSBase,
             Self.ia32TSCAux:
            values[msr] = value
            return .value(value)
        default:
            return .unsupported(msr)
        }
    }
}
