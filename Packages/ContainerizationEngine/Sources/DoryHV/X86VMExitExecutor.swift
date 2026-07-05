import Dispatch

public enum X86VMExitAction: Equatable, Sendable {
    case advanceRIP(UInt32)
    case writeMSR(X86MSRWrite, advanceRIP: UInt32)
    case controlRegister(X86ControlRegisterExit)
    case invalidateTLB(advanceRIP: UInt32)
    case halted
    case eptViolation(X86EPTViolation)
    case eptMisconfiguration(guestPhysicalAddress: UInt64)
}

public struct X86MSRWrite: Equatable, Sendable {
    public let msr: UInt32
    public let value: UInt64
}

public enum X86VMExitExecutionError: Error, Equatable, CustomStringConvertible {
    case unsupportedMSR(UInt32)
    case unsupportedPIOWidth(Int)
    case unsupportedStringPIO
    case exceptionOrNMI(X86InterruptionExit)
    case fatalExit(reason: UInt32, name: String, qualification: UInt64, instructionError: UInt32)
    case unsupportedDiagnosticExit(X86DiagnosticVMExit)
    case unknownExit(reason: UInt32, qualification: UInt64)

    public var description: String {
        switch self {
        case .unsupportedMSR(let msr):
            "unsupported x86 MSR 0x\(String(msr, radix: 16))"
        case .unsupportedPIOWidth(let width):
            "unsupported x86 PIO width \(width)"
        case .unsupportedStringPIO:
            "x86 string PIO exits are not supported"
        case .exceptionOrNMI(let interruption):
            "x86 exception/NMI exit vector \(interruption.vector), type \(interruption.type), error \(interruption.errorCode.map { "0x\(String($0, radix: 16))" } ?? "none"), qualification 0x\(String(interruption.qualification, radix: 16))"
        case .fatalExit(let reason, let name, let qualification, let instructionError):
            "x86 fatal VM exit \(reason) (\(name)), qualification 0x\(String(qualification, radix: 16)), instruction error \(instructionError)"
        case .unsupportedDiagnosticExit(let exit):
            "unsupported x86 VM exit \(exit.reason) (\(exit.name)), qualification 0x\(String(exit.qualification, radix: 16)), instruction info 0x\(String(exit.vmxInstructionInfo, radix: 16)), GPA 0x\(String(exit.guestPhysicalAddress, radix: 16)), GLA 0x\(String(exit.guestLinearAddress, radix: 16))"
        case .unknownExit(let reason, let qualification):
            "unknown x86 VM exit reason \(reason), qualification 0x\(String(qualification, radix: 16))"
        }
    }
}

public struct X86VMExitExecutor {
    public var msrs: X86MSRPolicy
    public var readTSC: @Sendable () -> UInt64

    public init(
        msrs: X86MSRPolicy = X86MSRPolicy(),
        readTSC: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.msrs = msrs
        self.readTSC = readTSC
    }

    public mutating func execute(
        state: X86VMExitState,
        registers: inout X86RegisterState,
        pioBus: PIOBus
    ) throws -> X86VMExitAction {
        switch X86VMExitDecoder.decode(state) {
        case .exceptionOrNMI(let interruption):
            throw X86VMExitExecutionError.exceptionOrNMI(interruption)
        case .cpuid:
            executeCPUID(registers: &registers)
            return .advanceRIP(state.instructionLength)
        case .invalidateCache, .pause, .writeBackInvalidateCache:
            return .advanceRIP(state.instructionLength)
        case .invalidatePage:
            return .invalidateTLB(advanceRIP: state.instructionLength)
        case .readTSC:
            executeReadTSC(registers: &registers)
            return .advanceRIP(state.instructionLength)
        case .readTSCP:
            executeReadTSC(registers: &registers)
            if case .value(let tscAux) = msrs.read(X86MSRPolicy.ia32TSCAux) {
                registers.write(Self.rcx, value: tscAux & 0xFFFF_FFFF, width: 4)
            }
            return .advanceRIP(state.instructionLength)
        case .readMSR:
            try executeReadMSR(registers: &registers)
            return .advanceRIP(state.instructionLength)
        case .writeMSR:
            let write = try executeWriteMSR(registers: &registers)
            return .writeMSR(write, advanceRIP: state.instructionLength)
        case .controlRegister(let controlRegister):
            return .controlRegister(controlRegister)
        case .fatal(let fatal):
            throw X86VMExitExecutionError.fatalExit(
                reason: fatal.reason,
                name: fatal.name,
                qualification: fatal.qualification,
                instructionError: fatal.instructionError
            )
        case .diagnostic(let exit):
            throw X86VMExitExecutionError.unsupportedDiagnosticExit(exit)
        case .pio(let pio):
            try executePIO(pio, registers: &registers, pioBus: pioBus)
            return .advanceRIP(pio.instructionLength)
        case .halt:
            return .halted
        case .eptViolation(let violation):
            return .eptViolation(violation)
        case .eptMisconfiguration(let guestPhysicalAddress):
            return .eptMisconfiguration(guestPhysicalAddress: guestPhysicalAddress)
        case .unknown(let reason, let qualification):
            throw X86VMExitExecutionError.unknownExit(reason: reason, qualification: qualification)
        }
    }

    private func executeCPUID(registers: inout X86RegisterState) {
        let result = X86CPUIDPolicy.result(
            leaf: UInt32(truncatingIfNeeded: registers.read(Self.rax)),
            subleaf: UInt32(truncatingIfNeeded: registers.read(Self.rcx))
        )
        registers.write(Self.rax, value: UInt64(result.eax), width: 4)
        registers.write(Self.rbx, value: UInt64(result.ebx), width: 4)
        registers.write(Self.rcx, value: UInt64(result.ecx), width: 4)
        registers.write(Self.rdx, value: UInt64(result.edx), width: 4)
    }

    private func executeReadTSC(registers: inout X86RegisterState) {
        let tsc = readTSC()
        registers.write(Self.rax, value: tsc & 0xFFFF_FFFF, width: 4)
        registers.write(Self.rdx, value: tsc >> 32, width: 4)
    }

    private mutating func executeReadMSR(registers: inout X86RegisterState) throws {
        let msr = UInt32(truncatingIfNeeded: registers.read(Self.rcx))
        switch msrs.read(msr) {
        case .value(let value):
            registers.write(Self.rax, value: value & 0xFFFF_FFFF, width: 4)
            registers.write(Self.rdx, value: value >> 32, width: 4)
        case .unsupported:
            throw X86VMExitExecutionError.unsupportedMSR(msr)
        }
    }

    private mutating func executeWriteMSR(registers: inout X86RegisterState) throws -> X86MSRWrite {
        let msr = UInt32(truncatingIfNeeded: registers.read(Self.rcx))
        let value = (registers.read(Self.rdx) << 32) | (registers.read(Self.rax) & 0xFFFF_FFFF)
        switch msrs.write(msr, value: value) {
        case .value(let stored):
            return X86MSRWrite(msr: msr, value: stored)
        case .unsupported:
            throw X86VMExitExecutionError.unsupportedMSR(msr)
        }
    }

    private func executePIO(_ pio: X86PIOExit, registers: inout X86RegisterState, pioBus: PIOBus) throws {
        guard pio.width == 1 || pio.width == 2 || pio.width == 4 else {
            throw X86VMExitExecutionError.unsupportedPIOWidth(pio.width)
        }
        guard !pio.stringInstruction && !pio.repeatPrefix else {
            throw X86VMExitExecutionError.unsupportedStringPIO
        }
        switch pio.direction {
        case .input:
            registers.write(Self.rax, value: UInt64(pioBus.read(port: pio.port, width: pio.width)), width: pio.width)
        case .output:
            pioBus.write(port: pio.port, value: UInt32(truncatingIfNeeded: registers.read(Self.rax)), width: pio.width)
        }
    }

    private static let rax = 0
    private static let rcx = 1
    private static let rdx = 2
    private static let rbx = 3
}
