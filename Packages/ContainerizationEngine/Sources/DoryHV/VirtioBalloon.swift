import Darwin
import Foundation

/// virtio-balloon with free page reporting (VIRTIO_BALLOON_F_REPORTING): the guest batches ranges
/// of free pages onto the reporting queue and this device hands them straight back to macOS with
/// madvise. This is the mechanism Virtualization.framework lacks, and the reason dory-hv exists:
/// the host footprint tracks what the guest is actually using instead of its high-water mark.
public final class VirtioBalloon: VirtioDeviceBackend {
    public let deviceID: UInt32 = 5
    public let queueCount = 3  // inflate, deflate, reporting
    public var deviceFeatures: UInt64 { 1 << 5 }  // VIRTIO_BALLOON_F_REPORTING

    private let memory: GuestMemory
    private let log: (String) -> Void
    public private(set) var reclaimedBytes: UInt64 = 0
    public private(set) var reportEvents: UInt64 = 0
    private var advice: Int32?

    private static let hostPageSize: UInt64 = HostPage.size
    private static let madvZero: Int32 = 11  // MADV_ZERO: release physical pages, zero-fill refault

    public init(memory: GuestMemory, log: @escaping (String) -> Void = { _ in }) {
        self.memory = memory
        self.log = log
    }

    public var configSpace: [UInt8] {
        // num_pages = 0 (no inflation requested), actual = 0.
        [UInt8](repeating: 0, count: 8)
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[queue]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            if queue == 2 {
                reclaim(chain: chain)
            }
            // Inflate and deflate chains complete as no-ops: the ceiling is enforced by RAM size
            // and reporting handles elasticity, so the classic balloon stays parked at zero.
            let wants = (try? virtqueue.push(chain, written: 0)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    /// Every segment of a reporting chain IS a run of free guest pages. Stage-2 mappings pin the
    /// backing pages, so each range is unmapped from the guest and only then marked reusable;
    /// GuestMemory.releaseRange does both. The guest tolerates zero-filled refaults on reported
    /// pages by contract, and the RAM-fault path in the run loop remaps blocks on first touch.
    private func reclaim(chain: VirtqueueChain) {
        let hostBase = UInt64(UInt(bitPattern: memory.hostBase))
        for segment in chain.segments {
            let start = UInt64(UInt(bitPattern: segment.pointer))
            let end = start + UInt64(segment.length)
            let alignedStart = (start + Self.hostPageSize - 1) & ~(Self.hostPageSize - 1)
            let alignedEnd = end & ~(Self.hostPageSize - 1)
            guard alignedEnd > alignedStart else { continue }
            let guestAddress = memory.guestBase + (alignedStart - hostBase)
            if memory.releaseRange(guestAddress: guestAddress, length: alignedEnd - alignedStart) {
                reclaimedBytes &+= alignedEnd - alignedStart
            }
        }
        reportEvents &+= 1
        if reportEvents <= 30 || reportEvents % 64 == 0 {
            log("balloon: report #\(reportEvents), \(chain.segments.count) ranges, total \(reclaimedBytes >> 20) MiB reclaimed")
        }
    }
}
