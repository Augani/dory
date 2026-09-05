/// PSCI CPU state for the flat MPIDR topology exported by the ARM machine. The machine's
/// team condition owns synchronization; this value never creates or destroys a vCPU.
struct ARMPSCICPUState {
    enum PowerState: Int64 {
        case on = 0
        case off = 1
        case onPending = 2
    }

    private(set) var states: [PowerState]

    init(cpuCount: Int) {
        precondition(cpuCount > 0 && cpuCount <= 256)
        states = Array(repeating: .off, count: cpuCount)
        states[0] = .on
    }

    func index(for target: UInt64) -> Int? {
        // PSCI takes affinity fields, not a raw MPIDR register. Reserved bits and nonzero
        // Aff1/Aff2/Aff3 cannot alias a CPU in our flat cluster.
        let affinityMask: UInt64 = 0xFF_00FF_FFFF
        guard target & ~affinityMask == 0 else { return nil }
        let affinity = target & affinityMask
        guard affinity < UInt64(states.count) else { return nil }
        return Int(affinity)
    }

    mutating func requestOn(target: UInt64, entry: UInt64, executableRanges: [Range<UInt64>]) -> Int64 {
        guard let index = index(for: target) else { return -2 }
        switch states[index] {
        case .on: return -4
        case .onPending: return -5
        case .off: break
        }
        guard entry.isMultiple(of: 4), executableRanges.contains(where: {
            $0.contains(entry) && $0.upperBound - entry >= 4
        }) else { return -9 }
        states[index] = .onPending
        return 0
    }

    mutating func completeOn(index: Int) {
        precondition(states[index] == .onPending)
        states[index] = .on
    }

    func affinityInfo(target: UInt64, lowestLevel: UInt32) -> Int64 {
        // PSCI 1.0 permits an implementation to support only affinity level zero.
        guard lowestLevel == 0, let index = index(for: target) else { return -2 }
        return states[index].rawValue
    }
}
