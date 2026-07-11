import Darwin
import Testing
@testable import DoryHV

struct HostFileDescriptorLimitTests {
    @Test func desiredSoftLimitCapsTheRequestedIncrease() {
        #expect(HostFileDescriptorLimit.desiredSoftLimit(
            current: 256,
            hard: 1_000_000
        ) == 262_144)
    }

    @Test func desiredSoftLimitRespectsALowerHardLimit() {
        #expect(HostFileDescriptorLimit.desiredSoftLimit(
            current: 256,
            hard: 8_192
        ) == 8_192)
    }

    @Test func desiredSoftLimitNeverLowersAnExistingHigherLimit() {
        #expect(HostFileDescriptorLimit.desiredSoftLimit(
            current: 1_048_575,
            hard: 2_000_000
        ) == 1_048_575)
    }
}
