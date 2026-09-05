import Testing
@testable import DoryHV

struct ARMPSCICPUStateTests {
    private let ram: [Range<UInt64>] = [0x4000_0000..<0x8000_0000]

    @Test func startupDistinguishesOffPendingAndOn() {
        var state = ARMPSCICPUState(cpuCount: 2)
        #expect(state.affinityInfo(target: 0, lowestLevel: 0) == 0)
        #expect(state.requestOn(target: 0, entry: 0x4000_0000, executableRanges: ram) == -4)
        #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
        #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == 0)
        #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 2)
        #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == -5)
        state.completeOn(index: 1)
        #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 0)
        #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == -4)
    }

    @Test func invalidAffinitiesCannotAliasRealCPUs() {
        var state = ARMPSCICPUState(cpuCount: 2)
        for target in [UInt64(2), 0x101, 0x10001, 0x1_0000_0001, 0x8000_0001, UInt64.max] {
            #expect(state.requestOn(target: target, entry: 0x4000_0000, executableRanges: ram) == -2)
            #expect(state.affinityInfo(target: target, lowestLevel: 0) == -2)
        }
        #expect(state.affinityInfo(target: 0, lowestLevel: 1) == -2)
        #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
        #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == 0)
    }

    @Test func invalidEntryDoesNotConsumeCPUStart() {
        var state = ARMPSCICPUState(cpuCount: 2)
        for entry in [UInt64(0), 0x4000_0001, 0x8000_0000, UInt64.max] {
            #expect(state.requestOn(target: 1, entry: entry, executableRanges: ram) == -9)
            #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
        }
        #expect(state.requestOn(target: 1, entry: 0x7FFF_FFFC, executableRanges: ram) == 0)
    }

    @Test func firmwareEntryRequiresExecutableFirmwareMapping() {
        var state = ARMPSCICPUState(cpuCount: 2)
        #expect(state.requestOn(target: 1, entry: 0x1000, executableRanges: ram) == -9)
        #expect(state.requestOn(target: 1, entry: 0x1000, executableRanges: [0..<0x4000000] + ram) == 0)
    }
}
