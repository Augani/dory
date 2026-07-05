import Testing
@testable import DoryHV

@Suite struct X86VMExitTests {
    @Test func decodesControlExits() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 10)) == .cpuid)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 12)) == .halt)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 13)) == .invalidateCache)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 14)) == .invalidatePage)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 16)) == .readTSC)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 31)) == .readMSR)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 32)) == .writeMSR)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 40)) == .pause)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 51)) == .readTSCP)
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 54)) == .writeBackInvalidateCache)
    }

    @Test func masksHighExitReasonFlags() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 0x8000_000A)) == .cpuid)
    }

    @Test func decodesFatalBootDiagnosticExits() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 2,
            qualification: 0x1234
        )) == .fatal(X86FatalVMExit(
            reason: 2,
            name: "triple fault",
            qualification: 0x1234,
            instructionError: 0
        )))

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 33,
            qualification: 0x5678,
            instructionError: 7
        )) == .fatal(X86FatalVMExit(
            reason: 33,
            name: "VM-entry failure due to invalid guest state",
            qualification: 0x5678,
            instructionError: 7
        )))
    }

    @Test func decodesNamedDiagnosticExits() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 1,
            qualification: 0x1234,
            instructionLength: 2,
            guestPhysicalAddress: 0xFEE0_0030,
            guestLinearAddress: 0xFFFF_8000_FEE0_0030,
            interruptionInfo: 0x8000_0020,
            vmxInstructionInfo: 0xABCD
        )) == .diagnostic(X86DiagnosticVMExit(
            reason: 1,
            name: "external interrupt",
            qualification: 0x1234,
            instructionLength: 2,
            guestPhysicalAddress: 0xFEE0_0030,
            guestLinearAddress: 0xFFFF_8000_FEE0_0030,
            vmxInstructionInfo: 0xABCD,
            interruptionInfo: 0x8000_0020
        )))

        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 3)) == .diagnostic(named(reason: 3, "INIT signal")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 4)) == .diagnostic(named(reason: 4, "startup IPI")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 7)) == .diagnostic(named(reason: 7, "interrupt-window")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 8)) == .diagnostic(named(reason: 8, "NMI-window")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 9)) == .diagnostic(named(reason: 9, "task switch")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 43)) == .diagnostic(named(reason: 43, "TPR below threshold")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 44)) == .diagnostic(named(reason: 44, "APIC access")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 45)) == .diagnostic(named(reason: 45, "virtualized EOI")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 46)) == .diagnostic(named(reason: 46, "GDTR/IDTR access")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 47)) == .diagnostic(named(reason: 47, "LDTR/TR access")))
        #expect(X86VMExitDecoder.decode(X86VMExitState(reason: 56)) == .diagnostic(named(reason: 56, "APIC write")))
    }

    @Test func decodesExceptionExitWithErrorCode() {
        let info = UInt32(14) | (UInt32(3) << 8) | (1 << 11) | (1 << 31)

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 0,
            qualification: 0xCAFE,
            interruptionInfo: info,
            interruptionErrorCode: 0x15
        )) == .exceptionOrNMI(X86InterruptionExit(
            vector: 14,
            type: .hardwareException,
            errorCode: 0x15,
            valid: true,
            qualification: 0xCAFE
        )))
    }

    @Test func decodesNMIExitWithoutErrorCode() {
        let info = UInt32(2) | (UInt32(2) << 8) | (1 << 31)

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 0,
            interruptionInfo: info,
            interruptionErrorCode: 0xFFFF
        )) == .exceptionOrNMI(X86InterruptionExit(
            vector: 2,
            type: .nmi,
            errorCode: nil,
            valid: true,
            qualification: 0
        )))
    }

    @Test func decodesMoveToControlRegisterExit() {
        let qualification = UInt64(3) | (UInt64(0) << 4) | (UInt64(2) << 8)

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 28,
            qualification: qualification,
            instructionLength: 3
        )) == .controlRegister(X86ControlRegisterExit(
            controlRegister: 3,
            access: .moveToCR,
            register: 2,
            lmswSourceData: 0,
            instructionLength: 3
        )))
    }

    @Test func decodesMoveFromControlRegisterExit() {
        let qualification = UInt64(0) | (UInt64(1) << 4) | (UInt64(8) << 8)

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 28,
            qualification: qualification,
            instructionLength: 3
        )) == .controlRegister(X86ControlRegisterExit(
            controlRegister: 0,
            access: .moveFromCR,
            register: 8,
            lmswSourceData: 0,
            instructionLength: 3
        )))
    }

    @Test func decodesCLTSAndLMSWControlRegisterExits() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 28,
            qualification: UInt64(2) << 4,
            instructionLength: 2
        )) == .controlRegister(X86ControlRegisterExit(
            controlRegister: 0,
            access: .clts,
            register: 0,
            lmswSourceData: 0,
            instructionLength: 2
        )))

        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 28,
            qualification: (UInt64(3) << 4) | (UInt64(0xB) << 16),
            instructionLength: 3
        )) == .controlRegister(X86ControlRegisterExit(
            controlRegister: 0,
            access: .lmsw,
            register: 0,
            lmswSourceData: 0xB,
            instructionLength: 3
        )))
    }

    @Test func decodesImmediatePortOutput() {
        let qualification = UInt64(0) | (UInt64(0x3F8) << 16)
        let exit = X86VMExitDecoder.decode(X86VMExitState(
            reason: 30,
            qualification: qualification,
            instructionLength: 1
        ))

        #expect(exit == .pio(X86PIOExit(
            direction: .output,
            width: 1,
            port: 0x3F8,
            stringInstruction: false,
            repeatPrefix: false,
            encodingIsDX: false,
            instructionLength: 1
        )))
    }

    @Test func decodesDXPortInputWithRepeatStringFlags() {
        var qualification: UInt64 = 0
        qualification |= 3               // 4-byte access
        qualification |= 1 << 3          // input
        qualification |= 1 << 4          // string
        qualification |= 1 << 5          // rep
        qualification |= 1 << 6          // DX encoding
        qualification |= UInt64(0x0CF8) << 16

        let exit = X86VMExitDecoder.decode(X86VMExitState(
            reason: 30,
            qualification: qualification,
            instructionLength: 2
        ))

        #expect(exit == .pio(X86PIOExit(
            direction: .input,
            width: 4,
            port: 0x0CF8,
            stringInstruction: true,
            repeatPrefix: true,
            encodingIsDX: true,
            instructionLength: 2
        )))
    }

    @Test func decodesWordPIOWidth() {
        let exit = X86VMExitDecoder.decode(X86VMExitState(
            reason: 30,
            qualification: 1 | (UInt64(0x70) << 16),
            instructionLength: 2
        ))

        if case .pio(let pio) = exit {
            #expect(pio.width == 2)
            #expect(pio.port == 0x70)
        } else {
            Issue.record("expected PIO exit")
        }
    }

    @Test func unsupportedPIOWidthIsZero() {
        let exit = X86VMExitDecoder.decode(X86VMExitState(
            reason: 30,
            qualification: 2 | (UInt64(0x80) << 16),
            instructionLength: 1
        ))

        if case .pio(let pio) = exit {
            #expect(pio.width == 0)
        } else {
            Issue.record("expected PIO exit")
        }
    }

    @Test func decodesEPTViolationAccessAndPermissionBits() {
        let exit = X86VMExitDecoder.decode(X86VMExitState(
            reason: 48,
            qualification: (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7),
            instructionLength: 4,
            guestPhysicalAddress: 0xD000_0000,
            guestLinearAddress: 0xFFFF_8000_D000_0000
        ))

        #expect(exit == .eptViolation(X86EPTViolation(
            guestPhysicalAddress: 0xD000_0000,
            guestLinearAddress: 0xFFFF_8000_D000_0000,
            read: false,
            write: true,
            execute: false,
            readable: true,
            writable: false,
            executable: true,
            linearAddressValid: true
        )))
    }

    @Test func decodesEPTMisconfiguration() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 49,
            guestPhysicalAddress: 0xDEAD_BEEF
        )) == .eptMisconfiguration(guestPhysicalAddress: 0xDEAD_BEEF))
    }

    @Test func unknownExitCarriesReasonAndQualification() {
        #expect(X86VMExitDecoder.decode(X86VMExitState(
            reason: 68,
            qualification: 0x1234
        )) == .unknown(reason: 68, qualification: 0x1234))
    }

    private func named(reason: UInt32, _ name: String) -> X86DiagnosticVMExit {
        X86DiagnosticVMExit(
            reason: reason,
            name: name,
            qualification: 0,
            instructionLength: 0,
            guestPhysicalAddress: 0,
            guestLinearAddress: 0,
            vmxInstructionInfo: 0,
            interruptionInfo: 0
        )
    }
}
