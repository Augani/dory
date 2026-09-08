/// AArch64 MSR/MRS trap (ESR_EL2 EC 0x18).
///
/// ISS layout is ARM ARM D13.2.37: Op0[21:20], Op2[19:17], Op1[16:14], CRn[13:10],
/// Rt[9:5], CRm[4:1], Direction[0] (1 = MRS / read).
public struct ARMSystemRegisterTrap: Equatable, Sendable {
    public enum Disposition: String, Equatable, Sendable {
        /// Architecturally acceptable for unimplemented debug/trace/PMU: read zero, ignore writes.
        case readAsZeroWriteIgnore
        /// Encoding is not part of the unimplemented-debug/PMU set. The guest must see UNDEFINED,
        /// not a successful zero read that advertises a register we do not implement.
        case undefined
    }

    public let op0: UInt8
    public let op1: UInt8
    public let crn: UInt8
    public let crm: UInt8
    public let op2: UInt8
    public let registerIndex: Int
    public let isRead: Bool

    public init(syndrome: UInt64) {
        self.op0 = UInt8((syndrome >> 20) & 0b11)
        self.op2 = UInt8((syndrome >> 17) & 0b111)
        self.op1 = UInt8((syndrome >> 14) & 0b111)
        self.crn = UInt8((syndrome >> 10) & 0b1111)
        self.registerIndex = Int((syndrome >> 5) & 0x1F)
        self.crm = UInt8((syndrome >> 1) & 0b1111)
        self.isRead = syndrome & 1 == 1
    }

    public var encodingDescription: String {
        "op0=\(op0) op1=\(op1) crn=\(crn) crm=\(crm) op2=\(op2)"
    }

    /// Only explicitly recognized debug/PMU encodings receive the compatibility RAZ/WI
    /// policy. Reserved encodings and unsupported trace extensions are not registers. Generic timers, ID registers, and other encodings stay UNDEFINED so a
    /// trap cannot silently invent feature state.
    public var disposition: Disposition {
        if isDebugOrTrace {
            if crn == 1, crm == 0, isRead { return .undefined } // OSLAR is write-only.
            if (crn == 1 && crm == 1) || (crn == 7 && crm == 14) {
                return isRead ? .readAsZeroWriteIgnore : .undefined
            }
            return .readAsZeroWriteIgnore
        }
        if isPerformanceMonitor {
            return .readAsZeroWriteIgnore
        }
        return .undefined
    }

    public var isDebugOrTrace: Bool {
        guard op0 == 2, op1 == 0 else { return false }
        if crn == 0 {
            return op2 >= 4 || (crm == 2 && (op2 == 0 || op2 == 2))
        }
        if crn == 1, op2 == 4 {
            return crm == 0 || crm == 1 || crm == 3 || crm == 4
        }
        return crn == 7 && op2 == 6 && (crm == 8 || crm == 9 || crm == 14)
    }

    public var isPerformanceMonitor: Bool {
        if op0 != 3 { return false }
        // PMCR_EL0, PMCNTEN*, PMINTEN*, PMUSERENR, PMCCNTR, PMXEV* live in CRn=9.
        if crn == 9 {
            if op1 == 0 { return crm == 14 && (op2 == 1 || op2 == 2) }
            guard op1 == 3 else { return false }
            switch crm {
            case 12: return op2 <= 6
            case 13: return op2 <= 2
            case 14: return op2 == 0 || op2 == 3
            default: return false
            }
        }
        // PMEVCNTRn_EL0 / PMEVTYPERn_EL0 / PMCCFILTR_EL0 occupy CRn=14, CRm>=8.
        // CRn=14 CRm 0-3 is the generic timer (CNTPCT/CNTVCT/CNTP_*) and must not RAZ/WI.
        if crn == 14, op1 == 3, crm >= 8 { return true }
        return false
    }

    /// Builds an EC 0x18 ESR with the ISS fields above. Tests use this; production
    /// consumes Hypervisor.framework's syndrome.
    public static func syndrome(
        op0: UInt8,
        op1: UInt8,
        crn: UInt8,
        crm: UInt8,
        op2: UInt8,
        registerIndex: Int = 0,
        isRead: Bool
    ) -> UInt64 {
        var value = UInt64(0x18) << 26
        value |= UInt64(op0 & 0b11) << 20
        value |= UInt64(op2 & 0b111) << 17
        value |= UInt64(op1 & 0b111) << 14
        value |= UInt64(crn & 0b1111) << 10
        value |= UInt64(registerIndex & 0x1F) << 5
        value |= UInt64(crm & 0b1111) << 1
        if isRead { value |= 1 }
        return value
    }
}

/// Guest ID_AA64DFR0/DFR1 bits that must not be advertised while debug/PMU traps are RAZ/WI.
public enum ARMGuestDebugPMUIdentity: Sendable {
    /// Hide all debug, trace and profiling fields, including newer upper-half extensions.
    public static let dfr0UnimplementedMask: UInt64 = UInt64.max

    public static func sanitizedDFR0(from host: UInt64) -> UInt64 {
        host & ~dfr0UnimplementedMask
    }

    public static func sanitizedDFR1(from host: UInt64) -> UInt64 {
        0
    }

    public static func advertisesNoDebugOrPMU(dfr0: UInt64, dfr1: UInt64) -> Bool {
        (dfr0 & dfr0UnimplementedMask) == 0 && dfr1 == 0
    }
}

/// AArch64 synchronous exception entry to EL1 (Arm TakeException semantics).
/// Keep NZCV/DIT/PAN, apply SCTLR's PAN/SSBS policy, and clear UAO/SS/IL/BTYPE.
public enum ARMUndefinedInstructionEntry {
    public static func vectorOffset(cpsr: UInt64) -> UInt64 {
        switch cpsr & 0x1F {
        case 0: return 0x400 // EL0 A64
        case 4: return 0 // EL1t
        case 5: return 0x200 // EL1h
        default: return 0x600 // Lower EL A32
        }
    }

    public static func pstate(cpsr: UInt64, sctlr: UInt64, hasMTE: Bool) -> UInt64 {
        var result = (cpsr & (0xF000_0000 | (1 << 24) | (1 << 22))) | 0x3C5
        if sctlr & (1 << 23) == 0 { result |= 1 << 22 } // !SPAN sets PAN.
        if sctlr & (1 << 44) != 0 { result |= 1 << 12 } // DSSBS sets SSBS.
        if hasMTE { result |= 1 << 25 } // Disable tag checks on entry.
        return result
    }
}
