@testable import DoryHV
import Testing

@Suite struct MappedPageFaultRetryBudgetTests {
    @Test func retriesExactlyTheBoundThenEscalates() {
        var budget = MappedPageFaultRetryBudget()
        for _ in 0..<MappedPageFaultRetryBudget.maximumRetries {
            let didAllow = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1234)
            #expect(didAllow)
        }
        let didEscalate = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1234)
        #expect(!didEscalate)

        // Escalation clears the episode so a later, independent fault is not poisoned.
        let didRestart = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1234)
        #expect(didRestart)
    }

    @Test func retryEpisodesArePerCPUAndPageAndRestoreClearsOnlyThatEpisode() {
        var budget = MappedPageFaultRetryBudget()
        for _ in 0..<MappedPageFaultRetryBudget.maximumRetries {
            let didAllow = budget.retryAlreadyMapped(vcpuIndex: 2, physicalAddress: 0x8000_1000)
            #expect(didAllow)
        }
        budget.resolve(vcpuIndex: 2, physicalAddress: 0x8000_1FFF)
        let didRestart = budget.retryAlreadyMapped(vcpuIndex: 2, physicalAddress: 0x8000_1000)
        #expect(didRestart)

        for _ in 0..<MappedPageFaultRetryBudget.maximumRetries {
            let didAllow = budget.retryAlreadyMapped(vcpuIndex: 2, physicalAddress: 0x8000_5000)
            #expect(didAllow)
        }
        let otherCPUAllowed = budget.retryAlreadyMapped(vcpuIndex: 3, physicalAddress: 0x8000_5000)
        let exhausted = budget.retryAlreadyMapped(vcpuIndex: 2, physicalAddress: 0x8000_5000)
        #expect(otherCPUAllowed)
        #expect(!exhausted)
    }

    @Test func differentInstructionsOnOnePageDoNotInheritRetries() {
        var budget = MappedPageFaultRetryBudget()
        for _ in 0..<MappedPageFaultRetryBudget.maximumRetries {
            let allowed = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
            #expect(allowed)
        }
        let independent = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4004)
        #expect(independent)
        for _ in 1..<MappedPageFaultRetryBudget.maximumRetries {
            let allowed = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4004)
            #expect(allowed)
        }
        let exhausted = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4004)
        #expect(!exhausted)
        #expect(budget.trackedEpisodeCount == 0)
    }

    @Test func visitingManyPagesKeepsOnlyOneCurrentEpisodePerCPU() {
        var budget = MappedPageFaultRetryBudget()
        for page in 0..<10_000 {
            let allowed = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: UInt64(page) * HostPage.size, instructionAddress: 0x4000)
            #expect(allowed)
        }
        #expect(budget.trackedEpisodeCount == 1)
        let otherCPUAllowed = budget.retryAlreadyMapped(vcpuIndex: 1, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
        #expect(otherCPUAllowed)
        #expect(budget.trackedEpisodeCount == 2)
        budget.resolve(vcpuIndex: 1, physicalAddress: 0x8000_1000)
        #expect(budget.trackedEpisodeCount == 1)
    }

    @Test func successfulMMIOExitEndsTheCurrentInstructionEpisodeOnlyOnItsCPU() {
        var budget = MappedPageFaultRetryBudget()
        for _ in 0..<MappedPageFaultRetryBudget.maximumRetries {
            let first = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
            let second = budget.retryAlreadyMapped(vcpuIndex: 1, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
            #expect(first && second)
        }
        budget.resolve(vcpuIndex: 0, physicalAddress: 0x0900_0000)
        let independent = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
        let exhausted = budget.retryAlreadyMapped(vcpuIndex: 1, physicalAddress: 0x8000_1000, instructionAddress: 0x4000)
        #expect(independent && !exhausted)
    }
}
