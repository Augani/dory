/// A memory-mapped device the guest reaches through stage-2 data aborts.
public protocol MMIODevice: AnyObject {
    var baseAddress: UInt64 { get }
    var size: UInt64 { get }
    func read(offset: UInt64, width: Int) -> UInt64
    func write(offset: UInt64, value: UInt64, width: Int)
}

/// Routes guest data aborts to the owning device by physical address.
public final class MMIOBus {
    private struct Region {
        let baseAddress: UInt64
        let lastAddress: UInt64
        let device: MMIODevice

        @inline(__always)
        func contains(_ address: UInt64) -> Bool {
            address >= baseAddress && address <= lastAddress
        }
    }

    /// Device attachment is a boot-time operation. `seal()` makes that topology immutable before
    /// vCPU threads begin reading it concurrently.
    private var regions: [Region] = []
    private var isSealed = false

    public init() {}

    public func attach(_ device: MMIODevice) {
        precondition(!isSealed, "MMIO devices must be attached before the bus is sealed")
        precondition(device.size > 0, "MMIO device windows must not be empty")
        let (lastAddress, overflow) = device.baseAddress.addingReportingOverflow(device.size - 1)
        precondition(!overflow, "MMIO device window must fit in the physical address space")

        let insertionIndex = firstRegionIndex(startingAtOrAfter: device.baseAddress)
        if insertionIndex > 0 {
            precondition(
                regions[insertionIndex - 1].lastAddress < device.baseAddress,
                "MMIO device windows must not overlap"
            )
        }
        if insertionIndex < regions.count {
            precondition(
                lastAddress < regions[insertionIndex].baseAddress,
                "MMIO device windows must not overlap"
            )
        }
        regions.insert(
            Region(baseAddress: device.baseAddress, lastAddress: lastAddress, device: device),
            at: insertionIndex
        )
    }

    /// Freezes the cold-path topology before concurrent vCPU execution starts.
    public func seal() {
        isSealed = true
    }

    @inline(__always)
    public func device(for address: UInt64) -> (MMIODevice, UInt64)? {
        guard let region = region(containing: address) else { return nil }
        return (region.device, address - region.baseAddress)
    }

    /// The vCPU-local cache makes repeated accesses to one device O(1), while cache misses use a
    /// binary search over the immutable region table instead of scanning every attached device.
    @inline(__always)
    func device(
        for address: UInt64,
        cache: inout MMIORouteCache
    ) -> (MMIODevice, UInt64)? {
        precondition(isSealed, "MMIO cached lookup requires a sealed bus")
        if let device = cache.device,
           address >= cache.baseAddress,
           address <= cache.lastAddress {
            return (device, address - cache.baseAddress)
        }
        guard let region = region(containing: address) else {
            cache.clear()
            return nil
        }
        cache.baseAddress = region.baseAddress
        cache.lastAddress = region.lastAddress
        cache.device = region.device
        return (region.device, address - region.baseAddress)
    }

    @inline(__always)
    private func region(containing address: UInt64) -> Region? {
        let insertionIndex = firstRegionIndex(startingAtOrAfter: address)
        if insertionIndex < regions.count, regions[insertionIndex].baseAddress == address {
            return regions[insertionIndex]
        }
        guard insertionIndex > 0 else { return nil }
        let candidate = regions[insertionIndex - 1]
        return candidate.contains(address) ? candidate : nil
    }

    @inline(__always)
    private func firstRegionIndex(startingAtOrAfter address: UInt64) -> Int {
        var lowerBound = 0
        var upperBound = regions.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if regions[midpoint].baseAddress < address {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }
}

/// One instance lives on each vCPU stack, so the common repeated-device path needs no lock or
/// shared mutable cache state.
struct MMIORouteCache {
    fileprivate var baseAddress: UInt64 = 0
    fileprivate var lastAddress: UInt64 = 0
    fileprivate var device: MMIODevice?

    fileprivate mutating func clear() {
        device = nil
    }
}

/// Fields of an EC=0x24 (data abort from a lower EL) syndrome, valid when ISV is set.
public struct DataAbortInfo {
    public let isValid: Bool
    public let width: Int
    public let registerIndex: Int
    public let isWrite: Bool
    public let signExtend: Bool
    public let sixtyFourBit: Bool

    public init(syndrome: UInt64) {
        self.isValid = (syndrome >> 24) & 1 == 1
        self.width = 1 << Int((syndrome >> 22) & 0b11)
        self.signExtend = (syndrome >> 21) & 1 == 1
        self.registerIndex = Int((syndrome >> 16) & 0x1F)
        self.sixtyFourBit = (syndrome >> 15) & 1 == 1
        self.isWrite = (syndrome >> 6) & 1 == 1
    }
}
