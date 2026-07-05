import Testing
@testable import DoryHV

@Suite struct X86CPUIDPolicyTests {
    @Test func basicLeafReportsGenuineIntelVendorAndMaxLeaf() {
        let result = X86CPUIDPolicy.result(leaf: 0)

        #expect(result.eax == X86CPUIDPolicy.maxBasicLeaf)
        #expect(vendorString(result) == "GenuineIntel")
    }

    @Test func featureLeafAdvertisesLinuxBootEssentialsWithoutXsave() {
        let result = X86CPUIDPolicy.result(leaf: 1)

        #expect(result.edx & (1 << 0) != 0)   // FPU
        #expect(result.edx & (1 << 4) != 0)   // TSC
        #expect(result.edx & (1 << 5) != 0)   // MSR
        #expect(result.edx & (1 << 9) != 0)   // APIC
        #expect(result.edx & (1 << 25) != 0)  // SSE
        #expect(result.edx & (1 << 26) != 0)  // SSE2
        #expect(result.ecx & (1 << 24) != 0)  // TSC deadline timer
        #expect(result.ecx & (1 << 31) != 0)  // hypervisor present
        #expect(result.ecx & (1 << 26) == 0)  // XSAVE is not advertised before XCR0 setup exists
        #expect(result.ecx & (1 << 27) == 0)  // OSXSAVE follows XSAVE
    }

    @Test func hypervisorLeafIdentifiesDoryHV() {
        let result = X86CPUIDPolicy.result(leaf: 0x4000_0000)

        #expect(result.eax == X86CPUIDPolicy.maxHypervisorLeaf)
        #expect(registerString([result.ebx, result.ecx, result.edx]) == "DoryHV      ")
    }

    @Test func extendedLeavesAdvertiseLongModeAndAddressWidths() {
        let max = X86CPUIDPolicy.result(leaf: 0x8000_0000)
        let features = X86CPUIDPolicy.result(leaf: 0x8000_0001)
        let power = X86CPUIDPolicy.result(leaf: 0x8000_0007)
        let widths = X86CPUIDPolicy.result(leaf: 0x8000_0008)

        #expect(max.eax == X86CPUIDPolicy.maxExtendedLeaf)
        #expect(features.edx & (1 << 11) != 0)  // SYSCALL/SYSRET
        #expect(features.edx & (1 << 20) != 0)  // NX
        #expect(features.edx & (1 << 29) != 0)  // Long mode
        #expect(power.edx & (1 << 8) != 0)       // invariant TSC
        #expect(widths.eax & 0xFF == 40)
        #expect((widths.eax >> 8) & 0xFF == 48)
    }

    @Test func unknownLeavesReturnZeros() {
        #expect(X86CPUIDPolicy.result(leaf: 0xDEAD_BEEF) == X86CPUIDResult())
    }

    private func vendorString(_ result: X86CPUIDResult) -> String {
        registerString([result.ebx, result.edx, result.ecx])
    }

    private func registerString(_ registers: [UInt32]) -> String {
        let bytes = registers.flatMap { register in
            [
                UInt8(register & 0xFF),
                UInt8((register >> 8) & 0xFF),
                UInt8((register >> 16) & 0xFF),
                UInt8((register >> 24) & 0xFF),
            ]
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@Suite struct X86MSRPolicyTests {
    @Test func defaultReadsCoverLinuxBootMSRs() {
        let policy = X86MSRPolicy()

        #expect(policy.read(X86MSRPolicy.ia32TSC) == .value(0))
        #expect(policy.read(X86MSRPolicy.ia32APICBase) == .value(0xFEE0_0800))
        #expect(policy.read(X86MSRPolicy.ia32PAT) == .value(0x0007_0406_0007_0406))
        #expect(policy.read(X86MSRPolicy.ia32EFER) == .value(0))
        #expect(policy.read(X86MSRPolicy.ia32LSTAR) == .value(0))
        #expect(policy.read(X86MSRPolicy.ia32TSCAux) == .value(0))
    }

    @Test func eferWriteKeepsOnlySupportedControlBits() {
        var policy = X86MSRPolicy()

        #expect(policy.write(X86MSRPolicy.ia32EFER, value: UInt64.max) == .value(0x0D01))
        #expect(policy.read(X86MSRPolicy.ia32EFER) == .value(0x0D01))
    }

    @Test func apicBaseWriteMasksReservedBits() {
        var policy = X86MSRPolicy()

        #expect(policy.write(X86MSRPolicy.ia32APICBase, value: 0xFEE0_0BFF) == .value(0xFEE0_0900))
        #expect(policy.read(X86MSRPolicy.ia32APICBase) == .value(0xFEE0_0900))
    }

    @Test func syscallAndPatMSRsRoundTrip() {
        var policy = X86MSRPolicy()

        #expect(policy.write(X86MSRPolicy.ia32STAR, value: 0x0013_0008_0000_0000) == .value(0x0013_0008_0000_0000))
        #expect(policy.write(X86MSRPolicy.ia32LSTAR, value: 0xFFFF_8000_0000_1234) == .value(0xFFFF_8000_0000_1234))
        #expect(policy.write(X86MSRPolicy.ia32SFMASK, value: 0x47700) == .value(0x47700))
        #expect(policy.write(X86MSRPolicy.ia32PAT, value: 0x0707_0606_0404_0000) == .value(0x0707_0606_0404_0000))
        #expect(policy.write(X86MSRPolicy.ia32TSCAux, value: 0x1234_5678) == .value(0x1234_5678))
        #expect(policy.read(X86MSRPolicy.ia32STAR) == .value(0x0013_0008_0000_0000))
        #expect(policy.read(X86MSRPolicy.ia32LSTAR) == .value(0xFFFF_8000_0000_1234))
        #expect(policy.read(X86MSRPolicy.ia32SFMASK) == .value(0x47700))
        #expect(policy.read(X86MSRPolicy.ia32PAT) == .value(0x0707_0606_0404_0000))
        #expect(policy.read(X86MSRPolicy.ia32TSCAux) == .value(0x1234_5678))
    }

    @Test func unsupportedMSRsAreExplicit() {
        var policy = X86MSRPolicy()

        #expect(policy.read(0x1234) == .unsupported(0x1234))
        #expect(policy.write(0x1234, value: 1) == .unsupported(0x1234))
    }
}
