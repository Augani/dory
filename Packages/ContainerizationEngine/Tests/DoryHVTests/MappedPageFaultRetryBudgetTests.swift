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
}
