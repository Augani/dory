/// Bounded retry accounting for a stage-2 fault on a page that is already mapped.
///
/// A successfully restored page is safe to retry once. Repeated exits for a page that is
/// already mapped, however, cannot be repaired by mapping it again: they indicate a permission,
/// alignment, or Hypervisor.framework fault that must be surfaced to the guest instead of
/// spinning the vCPU forever. The owner supplies the vCPU index so concurrent CPUs never spend
/// one another's retry budget.
struct MappedPageFaultRetryBudget: Sendable {
    static let maximumRetries = 16

    private struct Episode: Sendable {
        let pageAddress: UInt64
        let instructionAddress: UInt64?
        let count: Int
    }

    // One currently retried instruction per vCPU, not one historical counter per RAM page.
    // The latter grows with guest RAM and incorrectly combines independent instructions.
    private var episodes = [Int: Episode]()
    var trackedEpisodeCount: Int { episodes.count }

    /// Records an already-mapped fault. Returns `true` while a retry remains; the next repeated
    /// fault returns `false` and clears its accounting entry for a future independent fault.
    mutating func retryAlreadyMapped(
        vcpuIndex: Int, physicalAddress: UInt64, instructionAddress: UInt64? = nil
    ) -> Bool {
        guard vcpuIndex >= 0 else { return false }
        let pageAddress = physicalAddress & ~(HostPage.size - 1)
        let previous = episodes[vcpuIndex]
        let sameInstruction = previous?.pageAddress == pageAddress
            && previous?.instructionAddress == instructionAddress
        let retryCount = (sameInstruction ? previous?.count ?? 0 : 0) + 1
        guard retryCount <= Self.maximumRetries else {
            episodes.removeValue(forKey: vcpuIndex)
            return false
        }
        episodes[vcpuIndex] = Episode(pageAddress: pageAddress, instructionAddress: instructionAddress, count: retryCount)
        return true
    }

    /// A restored page, a real MMIO fault, or a terminal guest fault establishes a new fault
    /// episode and must not inherit stale retry accounting.
    mutating func resolve(vcpuIndex: Int, physicalAddress: UInt64) {
        // Any resolved RAM/MMIO/guest-fault exit on this CPU ends its previous instruction's
        // episode. Other vCPUs keep their own accounting, regardless of the page resolved here.
        episodes.removeValue(forKey: vcpuIndex)
    }
}
