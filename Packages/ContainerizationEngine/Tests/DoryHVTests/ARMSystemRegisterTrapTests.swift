import Testing
@testable import DoryHV

@Suite struct ARMSystemRegisterTrapTests {
    @Test func decodesISSFieldsFromEC18Syndrome() {
        let syndrome = ARMSystemRegisterTrap.syndrome(
            op0: 2, op1: 0, crn: 0, crm: 2, op2: 2, registerIndex: 7, isRead: true)
        let trap = ARMSystemRegisterTrap(syndrome: syndrome)
        #expect(trap.op0 == 2)
        #expect(trap.op1 == 0)
        #expect(trap.crn == 0)
        #expect(trap.crm == 2)
        #expect(trap.op2 == 2)
        #expect(trap.registerIndex == 7)
        #expect(trap.isRead)
        #expect(syndrome >> 26 == 0x18)
    }

    @Test func debugAndTraceEncodingsAreReadAsZeroWriteIgnore() {
        let cases: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
            (2, 0, 0, 2, 2),  // MDSCR_EL1
            (2, 0, 0, 2, 0),  // MDCCINT_EL1
            (2, 0, 0, 0, 4),  // DBGBVR0_EL1
            (2, 0, 0, 0, 5),  // DBGBCR0_EL1
            (2, 0, 0, 15, 6),  // DBGWVR15_EL1
            (2, 0, 0, 15, 7),  // DBGWCR15_EL1
            (2, 0, 1, 0, 4),  // OSLAR_EL1
            (2, 0, 1, 1, 4),  // OSLSR_EL1
            (2, 0, 7, 14, 6),  // DBGAUTHSTATUS_EL1
        ]
        for encoding in cases {
            let read = ARMSystemRegisterTrap(
                syndrome: ARMSystemRegisterTrap.syndrome(
                    op0: encoding.0, op1: encoding.1, crn: encoding.2, crm: encoding.3,
                    op2: encoding.4, isRead: true))
            let write = ARMSystemRegisterTrap(
                syndrome: ARMSystemRegisterTrap.syndrome(
                    op0: encoding.0, op1: encoding.1, crn: encoding.2, crm: encoding.3,
                    op2: encoding.4, isRead: false))
            let writeOnly = encoding.2 == 1 && encoding.3 == 0
            let readOnly = (encoding.2 == 1 && encoding.3 == 1) || encoding.2 == 7
            #expect(read.disposition == (writeOnly ? .undefined : .readAsZeroWriteIgnore))
            #expect(write.disposition == (readOnly ? .undefined : .readAsZeroWriteIgnore))
            #expect(read.isDebugOrTrace)
        }
    }

    @Test func pmuEncodingsAreReadAsZeroWriteIgnore() {
        let cases: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
            (3, 3, 9, 12, 0),  // PMCR_EL0
            (3, 3, 9, 12, 1),  // PMCNTENSET_EL0
            (3, 3, 9, 14, 0),  // PMUSERENR_EL0
            (3, 0, 9, 14, 1),  // PMINTENSET_EL1
            (3, 3, 14, 8, 0),  // PMEVCNTR0_EL0
            (3, 3, 14, 15, 7),  // PMEVTYPER / PMCCFILTR space
        ]
        for encoding in cases {
            let trap = ARMSystemRegisterTrap(
                syndrome: ARMSystemRegisterTrap.syndrome(
                    op0: encoding.0, op1: encoding.1, crn: encoding.2, crm: encoding.3,
                    op2: encoding.4, isRead: true))
            #expect(trap.disposition == .readAsZeroWriteIgnore)
            #expect(trap.isPerformanceMonitor)
        }
    }

    @Test func idRegistersAndGenericTimersStayUndefined() {
        let cases: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
            (2, 7, 15, 15, 7), // Unallocated debug-space encoding.
            (3, 0, 9, 0, 0),   // Not a PMU register merely because CRn is 9.
            (3, 3, 9, 13, 7),  // Reserved hole in PMU space.
            (3, 0, 0, 0, 0),  // MIDR_EL1
            (3, 0, 0, 5, 0),  // ID_AA64DFR0_EL1
            (3, 0, 0, 4, 0),  // ID_AA64PFR0_EL1
            (3, 3, 14, 0, 0),  // CNTFRQ_EL0
            (3, 3, 14, 0, 1),  // CNTPCT_EL0
            (3, 3, 14, 0, 2),  // CNTVCT_EL0
            (3, 3, 14, 2, 0),  // CNTP_TVAL_EL0
            (3, 0, 2, 0, 2),  // TCR_EL1
            (3, 0, 12, 0, 0),  // VBAR_EL1
        ]
        for encoding in cases {
            let trap = ARMSystemRegisterTrap(
                syndrome: ARMSystemRegisterTrap.syndrome(
                    op0: encoding.0, op1: encoding.1, crn: encoding.2, crm: encoding.3,
                    op2: encoding.4, isRead: true))
            #expect(trap.disposition == .undefined, "\(trap.encodingDescription) must not RAZ/WI")
            #expect(!trap.isPerformanceMonitor)
            #expect(!trap.isDebugOrTrace)
        }
    }

    @Test func undefinedEntryPreservesFlagsAndAppliesExceptionPolicy() {
        let old: UInt64 = 0xA000_0000 | (1 << 24) | (1 << 23) | (1 << 21) | (1 << 20) | (1 << 12) | (3 << 10)
        #expect(ARMUndefinedInstructionEntry.pstate(cpsr: old, sctlr: 0, hasMTE: false) == 0xA140_03C5)
        #expect(ARMUndefinedInstructionEntry.pstate(cpsr: 0, sctlr: 1 << 23, hasMTE: false) == 0x3C5)
        #expect(ARMUndefinedInstructionEntry.pstate(cpsr: 1 << 22, sctlr: 1 << 23, hasMTE: false) == 0x0040_03C5)
        #expect(ARMUndefinedInstructionEntry.pstate(cpsr: 0, sctlr: 1 << 44, hasMTE: true) == 0x0240_13C5)
        #expect(ARMUndefinedInstructionEntry.vectorOffset(cpsr: 0) == 0x400)
        #expect(ARMUndefinedInstructionEntry.vectorOffset(cpsr: 4) == 0)
        #expect(ARMUndefinedInstructionEntry.vectorOffset(cpsr: 5) == 0x200)
        #expect(ARMUndefinedInstructionEntry.vectorOffset(cpsr: 0x10) == 0x600)
    }

    @Test func sanitizerClearsDebugTracePMUAndSPEFromHostDFR0() {
        let host = UInt64.max
        let sanitized = ARMGuestDebugPMUIdentity.sanitizedDFR0(from: host)
        #expect(sanitized == 0)
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR0(from: 1 << 60) == 0)
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR1(from: host) == 0)
        #expect(ARMGuestDebugPMUIdentity.advertisesNoDebugOrPMU(dfr0: sanitized, dfr1: 0))
        #expect(!ARMGuestDebugPMUIdentity.advertisesNoDebugOrPMU(dfr0: host, dfr1: 0))
        #expect(!ARMGuestDebugPMUIdentity.advertisesNoDebugOrPMU(dfr0: 0, dfr1: 1))
        let debugOnly = UInt64(0x6)  // DebugVer v8
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR0(from: debugOnly) == 0)
        let pmuOnly = UInt64(1) << 8
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR0(from: pmuOnly) == 0)
        let speOnly = UInt64(1) << 32
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR0(from: speOnly) == 0)
        let wrpAndCtx = (UInt64(3) << 20) | (UInt64(1) << 28)
        #expect(ARMGuestDebugPMUIdentity.sanitizedDFR0(from: wrpAndCtx) == 0)
    }
}
