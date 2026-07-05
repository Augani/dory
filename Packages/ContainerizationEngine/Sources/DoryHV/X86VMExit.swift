public struct X86VMExitState: Equatable, Sendable {
    public let reason: UInt32
    public let qualification: UInt64
    public let instructionLength: UInt32
    public let guestPhysicalAddress: UInt64
    public let guestLinearAddress: UInt64
    public let interruptionInfo: UInt32
    public let interruptionErrorCode: UInt32
    public let instructionError: UInt32
    public let vmxInstructionInfo: UInt32

    public init(
        reason: UInt32,
        qualification: UInt64 = 0,
        instructionLength: UInt32 = 0,
        guestPhysicalAddress: UInt64 = 0,
        guestLinearAddress: UInt64 = 0,
        interruptionInfo: UInt32 = 0,
        interruptionErrorCode: UInt32 = 0,
        instructionError: UInt32 = 0,
        vmxInstructionInfo: UInt32 = 0
    ) {
        self.reason = reason
        self.qualification = qualification
        self.instructionLength = instructionLength
        self.guestPhysicalAddress = guestPhysicalAddress
        self.guestLinearAddress = guestLinearAddress
        self.interruptionInfo = interruptionInfo
        self.interruptionErrorCode = interruptionErrorCode
        self.instructionError = instructionError
        self.vmxInstructionInfo = vmxInstructionInfo
    }
}

public enum X86VMExit: Equatable, Sendable {
    case exceptionOrNMI(X86InterruptionExit)
    case cpuid
    case halt
    case invalidateCache
    case invalidatePage
    case readTSC
    case readTSCP
    case pause
    case writeBackInvalidateCache
    case readMSR
    case writeMSR
    case controlRegister(X86ControlRegisterExit)
    case fatal(X86FatalVMExit)
    case diagnostic(X86DiagnosticVMExit)
    case pio(X86PIOExit)
    case eptViolation(X86EPTViolation)
    case eptMisconfiguration(guestPhysicalAddress: UInt64)
    case unknown(reason: UInt32, qualification: UInt64)
}

public struct X86FatalVMExit: Equatable, Sendable {
    public let reason: UInt32
    public let name: String
    public let qualification: UInt64
    public let instructionError: UInt32
}

public struct X86DiagnosticVMExit: Equatable, Sendable {
    public let reason: UInt32
    public let name: String
    public let qualification: UInt64
    public let instructionLength: UInt32
    public let guestPhysicalAddress: UInt64
    public let guestLinearAddress: UInt64
    public let vmxInstructionInfo: UInt32
    public let interruptionInfo: UInt32
}

public struct X86InterruptionExit: Equatable, Sendable {
    public enum InterruptionType: Equatable, Sendable {
        case externalInterrupt
        case nmi
        case hardwareException
        case softwareInterrupt
        case privilegedSoftwareException
        case softwareException
        case other(UInt8)
    }

    public let vector: UInt8
    public let type: InterruptionType
    public let errorCode: UInt32?
    public let valid: Bool
    public let qualification: UInt64
}

public struct X86ControlRegisterExit: Equatable, Sendable {
    public enum Access: Equatable, Sendable {
        case moveToCR
        case moveFromCR
        case clts
        case lmsw
    }

    public let controlRegister: UInt8
    public let access: Access
    public let register: Int
    public let lmswSourceData: UInt16
    public let instructionLength: UInt32
}

public struct X86PIOExit: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case input
        case output
    }

    public let direction: Direction
    public let width: Int
    public let port: UInt16
    public let stringInstruction: Bool
    public let repeatPrefix: Bool
    public let encodingIsDX: Bool
    public let instructionLength: UInt32
}

public struct X86EPTViolation: Equatable, Sendable {
    public let guestPhysicalAddress: UInt64
    public let guestLinearAddress: UInt64
    public let read: Bool
    public let write: Bool
    public let execute: Bool
    public let readable: Bool
    public let writable: Bool
    public let executable: Bool
    public let linearAddressValid: Bool
}

public enum X86VMExitDecoder {
    public static let reasonMask: UInt32 = 0xFFFF

    public static func decode(_ state: X86VMExitState) -> X86VMExit {
        switch state.reason & reasonMask {
        case 0:
            return .exceptionOrNMI(decodeInterruption(state))
        case 1:
            return diagnosticExit(state, name: "external interrupt")
        case 2:
            return fatalExit(state, name: "triple fault")
        case 3:
            return diagnosticExit(state, name: "INIT signal")
        case 4:
            return diagnosticExit(state, name: "startup IPI")
        case 7:
            return diagnosticExit(state, name: "interrupt-window")
        case 8:
            return diagnosticExit(state, name: "NMI-window")
        case 9:
            return diagnosticExit(state, name: "task switch")
        case 10:
            return .cpuid
        case 12:
            return .halt
        case 13:
            return .invalidateCache
        case 14:
            return .invalidatePage
        case 16:
            return .readTSC
        case 28:
            return .controlRegister(decodeControlRegister(
                qualification: state.qualification,
                instructionLength: state.instructionLength
            ))
        case 30:
            return .pio(decodePIO(qualification: state.qualification, instructionLength: state.instructionLength))
        case 31:
            return .readMSR
        case 32:
            return .writeMSR
        case 33:
            return fatalExit(state, name: "VM-entry failure due to invalid guest state")
        case 34:
            return fatalExit(state, name: "VM-entry failure due to MSR loading")
        case 40:
            return .pause
        case 41:
            return fatalExit(state, name: "VM-entry failure due to machine-check event")
        case 43:
            return diagnosticExit(state, name: "TPR below threshold")
        case 44:
            return diagnosticExit(state, name: "APIC access")
        case 45:
            return diagnosticExit(state, name: "virtualized EOI")
        case 46:
            return diagnosticExit(state, name: "GDTR/IDTR access")
        case 47:
            return diagnosticExit(state, name: "LDTR/TR access")
        case 48:
            return .eptViolation(decodeEPTViolation(state))
        case 49:
            return .eptMisconfiguration(guestPhysicalAddress: state.guestPhysicalAddress)
        case 51:
            return .readTSCP
        case 54:
            return .writeBackInvalidateCache
        case 56:
            return diagnosticExit(state, name: "APIC write")
        default:
            return .unknown(reason: state.reason & reasonMask, qualification: state.qualification)
        }
    }

    private static func decodeInterruption(_ state: X86VMExitState) -> X86InterruptionExit {
        let info = state.interruptionInfo
        let typeCode = UInt8((info >> 8) & 0b111)
        let type: X86InterruptionExit.InterruptionType
        switch typeCode {
        case 0:
            type = .externalInterrupt
        case 2:
            type = .nmi
        case 3:
            type = .hardwareException
        case 4:
            type = .softwareInterrupt
        case 5:
            type = .privilegedSoftwareException
        case 6:
            type = .softwareException
        default:
            type = .other(typeCode)
        }

        let errorCode = (info & (1 << 11)) != 0 ? state.interruptionErrorCode : nil
        return X86InterruptionExit(
            vector: UInt8(truncatingIfNeeded: info & 0xFF),
            type: type,
            errorCode: errorCode,
            valid: (info & (1 << 31)) != 0,
            qualification: state.qualification
        )
    }

    private static func fatalExit(_ state: X86VMExitState, name: String) -> X86VMExit {
        .fatal(X86FatalVMExit(
            reason: state.reason & reasonMask,
            name: name,
            qualification: state.qualification,
            instructionError: state.instructionError
        ))
    }

    private static func diagnosticExit(_ state: X86VMExitState, name: String) -> X86VMExit {
        .diagnostic(X86DiagnosticVMExit(
            reason: state.reason & reasonMask,
            name: name,
            qualification: state.qualification,
            instructionLength: state.instructionLength,
            guestPhysicalAddress: state.guestPhysicalAddress,
            guestLinearAddress: state.guestLinearAddress,
            vmxInstructionInfo: state.vmxInstructionInfo,
            interruptionInfo: state.interruptionInfo
        ))
    }

    private static func decodeControlRegister(
        qualification: UInt64,
        instructionLength: UInt32
    ) -> X86ControlRegisterExit {
        let access: X86ControlRegisterExit.Access
        switch (qualification >> 4) & 0b11 {
        case 0: access = .moveToCR
        case 1: access = .moveFromCR
        case 2: access = .clts
        default: access = .lmsw
        }

        return X86ControlRegisterExit(
            controlRegister: UInt8(truncatingIfNeeded: qualification & 0b1111),
            access: access,
            register: Int((qualification >> 8) & 0b1111),
            lmswSourceData: UInt16(truncatingIfNeeded: qualification >> 16),
            instructionLength: instructionLength
        )
    }

    private static func decodePIO(qualification: UInt64, instructionLength: UInt32) -> X86PIOExit {
        let sizeCode = Int(qualification & 0b111)
        let width: Int
        switch sizeCode {
        case 0: width = 1
        case 1: width = 2
        case 3: width = 4
        default: width = 0
        }
        return X86PIOExit(
            direction: ((qualification >> 3) & 1) == 1 ? .input : .output,
            width: width,
            port: UInt16(truncatingIfNeeded: qualification >> 16),
            stringInstruction: ((qualification >> 4) & 1) == 1,
            repeatPrefix: ((qualification >> 5) & 1) == 1,
            encodingIsDX: ((qualification >> 6) & 1) == 1,
            instructionLength: instructionLength
        )
    }

    private static func decodeEPTViolation(_ state: X86VMExitState) -> X86EPTViolation {
        let q = state.qualification
        return X86EPTViolation(
            guestPhysicalAddress: state.guestPhysicalAddress,
            guestLinearAddress: state.guestLinearAddress,
            read: q & (1 << 0) != 0,
            write: q & (1 << 1) != 0,
            execute: q & (1 << 2) != 0,
            readable: q & (1 << 3) != 0,
            writable: q & (1 << 4) != 0,
            executable: q & (1 << 5) != 0,
            linearAddressValid: q & (1 << 7) != 0
        )
    }
}
