/// Bounded retry accounting for a stage-2 fault on a page that is already mapped.
///
/// A successfully restored page is safe to retry once. Repeated exits for a page that is
/// already mapped, however, cannot be repaired by mapping it again: they indicate a permission,
/// alignment, or Hypervisor.framework fault that must be surfaced to the guest instead of
/// spinning the vCPU forever. The owner supplies the vCPU index so concurrent CPUs never spend
/// one another's retry budget.
struct MappedPageFaultRetryBudget: Sendable {
    static let maximumRetries = 16

    private struct Key: Hashable, Sendable {
        let vcpuIndex: Int
        let pageAddress: UInt64
    }

    private var counts = [Key: Int]()

    /// Records an already-mapped fault. Returns `true` while a retry remains; the next repeated
    /// fault returns `false` and clears its accounting entry for a future independent fault.
    mutating func retryAlreadyMapped(vcpuIndex: Int, physicalAddress: UInt64) -> Bool {
        let key = Key(
            vcpuIndex: vcpuIndex,
            pageAddress: physicalAddress & ~(HostPage.size - 1)
        )
        let retryCount = (counts[key] ?? 0) + 1
        guard retryCount <= Self.maximumRetries else {
            counts.removeValue(forKey: key)
            return false
        }
        counts[key] = retryCount
        return true
    }

    /// A restored page, a real MMIO fault, or a terminal guest fault establishes a new fault
    /// episode and must not inherit stale retry accounting.
    mutating func resolve(vcpuIndex: Int, physicalAddress: UInt64) {
        counts.removeValue(forKey: Key(
            vcpuIndex: vcpuIndex,
            pageAddress: physicalAddress & ~(HostPage.size - 1)
        ))
    }
}
