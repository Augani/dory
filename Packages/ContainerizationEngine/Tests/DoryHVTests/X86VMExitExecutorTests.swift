import Testing
@testable import DoryHV

@Suite struct X86VMExitExecutorTests {
    private final class StubPIO: PIODevice {
        let basePort: UInt16
        let portCount: UInt16
        var readValue: UInt32
        var writes: [(offset: UInt16, value: UInt32, width: Int)] = []

        init(basePort: UInt16, portCount: UInt16 = 8, readValue: UInt32 = 0) {
            self.basePort = basePort
            self.portCount = portCount
            self.readValue = readValue
        }

        func read(portOffset: UInt16, width: Int) -> UInt32 {
            readValue
        }

        func write(portOffset: UInt16, value: UInt32, width: Int) {
            writes.append((portOffset, value, width))
        }
    }

    @Test func cpuidWritesResultRegistersAndAdvances() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(0, value: 0, width: 8)
        registers.write(1, value: 0xFFFF_FFFF_FFFF_FFFF, width: 8)

        let action = try executor.execute(
            state: X86VMExitState(reason: 10, instructionLength: 2),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .advanceRIP(2))
        #expect(registers.read(0) == UInt64(X86CPUIDPolicy.maxBasicLeaf))
        #expect(registers.read(3) == 0x756E_6547)
        #expect(registers.read(2) == 0x4965_6E69)
        #expect(registers.read(1) == 0x6C65_746E)
    }

    @Test func readMSRWritesEAXAndEDXAndAdvances() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(1, value: UInt64(X86MSRPolicy.ia32PAT), width: 4)

        let action = try executor.execute(
            state: X86VMExitState(reason: 31, instructionLength: 2),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .advanceRIP(2))
        #expect(registers.read(0) == 0x0007_0406)
        #expect(registers.read(2) == 0x0007_0406)
    }

    @Test func writeMSRCombinesEDXEAXAndStoresMaskedValue() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(1, value: UInt64(X86MSRPolicy.ia32EFER), width: 4)
        registers.write(0, value: 0xFFFF_FFFF, width: 4)
        registers.write(2, value: 0xFFFF_FFFF, width: 4)

        let action = try executor.execute(
            state: X86VMExitState(reason: 32, instructionLength: 2),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .writeMSR(X86MSRWrite(msr: X86MSRPolicy.ia32EFER, value: 0x0D01), advanceRIP: 2))
        #expect(executor.msrs.read(X86MSRPolicy.ia32EFER) == .value(0x0D01))
    }

    @Test func readTSCWritesEDXEAXAndAdvances() throws {
        var executor = X86VMExitExecutor(readTSC: { 0x1234_5678_9ABC_DEF0 })
        var registers = X86RegisterState()
        registers.write(0, value: UInt64.max, width: 8)
        registers.write(2, value: UInt64.max, width: 8)

        let action = try executor.execute(
            state: X86VMExitState(reason: 16, instructionLength: 2),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .advanceRIP(2))
        #expect(registers.read(0) == 0x9ABC_DEF0)
        #expect(registers.read(2) == 0x1234_5678)
    }

    @Test func readTSCPWritesTSCAndAuxAndAdvances() throws {
        var msrs = X86MSRPolicy()
        #expect(msrs.write(X86MSRPolicy.ia32TSCAux, value: 0xCAFE_BABE) == .value(0xCAFE_BABE))
        var executor = X86VMExitExecutor(msrs: msrs, readTSC: { 0x0000_0001_0000_0002 })
        var registers = X86RegisterState()

        let action = try executor.execute(
            state: X86VMExitState(reason: 51, instructionLength: 3),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .advanceRIP(3))
        #expect(registers.read(0) == 0x0000_0002)
        #expect(registers.read(2) == 0x0000_0001)
        #expect(registers.read(1) == 0xCAFE_BABE)
    }

    @Test func unsupportedMSRThrows() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(1, value: 0x1234, width: 4)

        #expect(throws: X86VMExitExecutionError.unsupportedMSR(0x1234)) {
            _ = try executor.execute(
                state: X86VMExitState(reason: 31, instructionLength: 2),
                registers: &registers,
                pioBus: PIOBus()
            )
        }
    }

    @Test func pioOutputWritesALToBusAndAdvances() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(0, value: 0x1234_5678, width: 8)
        let bus = PIOBus()
        let device = StubPIO(basePort: 0x3F8)
        bus.attach(device)

        let action = try executor.execute(
            state: X86VMExitState(reason: 30, qualification: UInt64(0x3F8) << 16, instructionLength: 1),
            registers: &registers,
            pioBus: bus
        )

        #expect(action == .advanceRIP(1))
        #expect(device.writes.count == 1)
        #expect(device.writes.first?.offset == 0)
        #expect(device.writes.first?.value == 0x1234_5678)
        #expect(device.writes.first?.width == 1)
    }

    @Test func pioInputWritesOnlyRequestedRegisterWidth() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        registers.write(0, value: 0xAAAA_BBBB_CCCC_DDDD, width: 8)
        let bus = PIOBus()
        bus.attach(StubPIO(basePort: 0x70, readValue: 0x1234))

        let action = try executor.execute(
            state: X86VMExitState(reason: 30, qualification: 1 | (1 << 3) | (UInt64(0x70) << 16), instructionLength: 2),
            registers: &registers,
            pioBus: bus
        )

        #expect(action == .advanceRIP(2))
        #expect(registers.read(0) == 0xAAAA_BBBB_CCCC_1234)
    }

    @Test func stringPIOThrowsBeforeBusAccess() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        let bus = PIOBus()
        let device = StubPIO(basePort: 0x3F8)
        bus.attach(device)

        #expect(throws: X86VMExitExecutionError.unsupportedStringPIO) {
            _ = try executor.execute(
                state: X86VMExitState(reason: 30, qualification: (1 << 4) | (UInt64(0x3F8) << 16), instructionLength: 1),
                registers: &registers,
                pioBus: bus
            )
        }
        #expect(device.writes.isEmpty)
    }

    @Test func haltReturnsHaltedWithoutAdvancing() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        let action = try executor.execute(
            state: X86VMExitState(reason: 12, instructionLength: 1),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .halted)
    }

    @Test func cacheAndPauseExitsAdvance() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        let invd = try executor.execute(
            state: X86VMExitState(reason: 13, instructionLength: 2),
            registers: &registers,
            pioBus: PIOBus()
        )
        let pause = try executor.execute(
            state: X86VMExitState(reason: 40, instructionLength: 1),
            registers: &registers,
            pioBus: PIOBus()
        )
        let wbinvd = try executor.execute(
            state: X86VMExitState(reason: 54, instructionLength: 3),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(invd == .advanceRIP(2))
        #expect(pause == .advanceRIP(1))
        #expect(wbinvd == .advanceRIP(3))
    }

    @Test func invlpgRequestsTLBInvalidationAndAdvances() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        let action = try executor.execute(
            state: X86VMExitState(reason: 14, instructionLength: 3),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .invalidateTLB(advanceRIP: 3))
    }

    @Test func controlRegisterExitIsReturnedForMachineHandling() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        let action = try executor.execute(
            state: X86VMExitState(
                reason: 28,
                qualification: UInt64(3) | (UInt64(2) << 8),
                instructionLength: 3
            ),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .controlRegister(X86ControlRegisterExit(
            controlRegister: 3,
            access: .moveToCR,
            register: 2,
            lmswSourceData: 0,
            instructionLength: 3
        )))
    }

    @Test func eptViolationIsReturnedForMMIOPath() throws {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        let action = try executor.execute(
            state: X86VMExitState(
                reason: 48,
                qualification: (1 << 1) | (1 << 7),
                guestPhysicalAddress: 0xD000_0000,
                guestLinearAddress: 0xFFFF_8000_D000_0000
            ),
            registers: &registers,
            pioBus: PIOBus()
        )

        #expect(action == .eptViolation(X86EPTViolation(
            guestPhysicalAddress: 0xD000_0000,
            guestLinearAddress: 0xFFFF_8000_D000_0000,
            read: false,
            write: true,
            execute: false,
            readable: false,
            writable: false,
            executable: false,
            linearAddressValid: true
        )))
    }

    @Test func unknownExitThrows() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        #expect(throws: X86VMExitExecutionError.unknownExit(reason: 68, qualification: 0x1234)) {
            _ = try executor.execute(
                state: X86VMExitState(reason: 68, qualification: 0x1234),
                registers: &registers,
                pioBus: PIOBus()
            )
        }
    }

    @Test func exceptionExitThrowsStructuredDiagnostic() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        let interruption = X86InterruptionExit(
            vector: 14,
            type: .hardwareException,
            errorCode: 0x15,
            valid: true,
            qualification: 0xCAFE
        )

        #expect(throws: X86VMExitExecutionError.exceptionOrNMI(interruption)) {
            _ = try executor.execute(
                state: X86VMExitState(
                    reason: 0,
                    qualification: 0xCAFE,
                    interruptionInfo: UInt32(14) | (UInt32(3) << 8) | (1 << 11) | (1 << 31),
                    interruptionErrorCode: 0x15
                ),
                registers: &registers,
                pioBus: PIOBus()
            )
        }
    }

    @Test func fatalExitThrowsNamedDiagnostic() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()

        #expect(throws: X86VMExitExecutionError.fatalExit(
            reason: 33,
            name: "VM-entry failure due to invalid guest state",
            qualification: 0x4321,
            instructionError: 9
        )) {
            _ = try executor.execute(
                state: X86VMExitState(reason: 33, qualification: 0x4321, instructionError: 9),
                registers: &registers,
                pioBus: PIOBus()
            )
        }
    }

    @Test func namedDiagnosticExitThrowsStructuredUnsupportedError() {
        var executor = X86VMExitExecutor()
        var registers = X86RegisterState()
        let diagnostic = X86DiagnosticVMExit(
            reason: 46,
            name: "GDTR/IDTR access",
            qualification: 0x1234,
            instructionLength: 3,
            guestPhysicalAddress: 0x1000,
            guestLinearAddress: 0xFFFF_8000_0000_1000,
            vmxInstructionInfo: 0xABCD,
            interruptionInfo: 0
        )

        #expect(throws: X86VMExitExecutionError.unsupportedDiagnosticExit(diagnostic)) {
            _ = try executor.execute(
                state: X86VMExitState(
                    reason: 46,
                    qualification: 0x1234,
                    instructionLength: 3,
                    guestPhysicalAddress: 0x1000,
                    guestLinearAddress: 0xFFFF_8000_0000_1000,
                    vmxInstructionInfo: 0xABCD
                ),
                registers: &registers,
                pioBus: PIOBus()
            )
        }
    }
}
