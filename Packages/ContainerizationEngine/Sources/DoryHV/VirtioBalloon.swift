import Foundation
import Synchronization

public struct VirtioBalloonStatistics: Equatable, Sendable {
    public var reportRequests: UInt64
    public var reportRejected: UInt64
    public var reportBytes: UInt64
    public var reclaimedBytes: UInt64
    public var releaseFailures: UInt64
    public var classicRequests: UInt64
    public var invalidClassicRequests: UInt64
    public var queueFaults: UInt64
    public var boundedDrainStops: UInt64
    public var workerTurns: UInt64
    public var workerYields: UInt64
    public var coalescedWorkerRequests: UInt64
    public var revokedWorkerTurns: UInt64
    public var reportProcessingNanoseconds: UInt64
    public var maximumReportProcessingNanoseconds: UInt64
}

struct VirtioBalloonLimits: Equatable, Sendable {
    /// Linux's page-reporting core currently submits at most 32 scatterlist entries, normally one
    /// pageblock (2 MiB on a 4 KiB-page arm64 kernel) per entry. Matching that 64 MiB transaction
    /// ceiling bounds host reclaim work without fragmenting a conforming Linux report.
    static let production = VirtioBalloonLimits(
        maximumReportRanges: 32,
        maximumReportBytes: 64 * 1_024 * 1_024,
        // A reporting chain can itself cover 64 MiB. One chain per worker turn bounds latency and
        // lets notifications for the other compacted queues enter between large reports.
        maximumChainsPerWorkerTurn: 1
    )

    let maximumReportRanges: Int
    let maximumReportBytes: Int
    let maximumChainsPerWorkerTurn: Int

    init(
        maximumReportRanges: Int,
        maximumReportBytes: Int,
        maximumChainsPerWorkerTurn: Int
    ) {
        precondition(maximumReportRanges > 0)
        precondition(maximumReportBytes >= Int(HostPage.size))
        precondition(maximumChainsPerWorkerTurn > 0)
        precondition(maximumChainsPerWorkerTurn <= Int(Virtqueue.maximumSize))
        self.maximumReportRanges = maximumReportRanges
        self.maximumReportBytes = maximumReportBytes
        self.maximumChainsPerWorkerTurn = maximumChainsPerWorkerTurn
    }
}

/// virtio-balloon with VIRTIO_BALLOON_F_PAGE_REPORTING. Linux offers isolated free pages as
/// device-writable scatter/gather buffers, waits for the used-ring acknowledgement, and then may
/// reuse them. Dory validates the complete report before any host-memory mutation, releases only
/// fully covered host pages, and acknowledges the report even when macOS elects not to reclaim a
/// particular range (the feature is an optimization, not guest memory ownership transfer).
public final class VirtioBalloon: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 5
    // On virtio-mmio, Linux compacts optional named queues. With only PAGE_REPORTING negotiated,
    // physical queue 2 is reporting_vq after inflateq and deflateq.
    public let queueCount = 3
    public var deviceFeatures: UInt64 { 1 << 5 }  // VIRTIO_BALLOON_F_PAGE_REPORTING
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged

    private final class WeakTransportReference: @unchecked Sendable {
        weak var value: VirtioMMIOTransport?

        init(_ value: VirtioMMIOTransport) {
            self.value = value
        }
    }

    private struct QueueWorkerState {
        var generation: UInt64 = 1
        var scheduled = false
        var kickPending = false
    }

    private struct WorkerState {
        var transport: WeakTransportReference?
        var queues = Array(repeating: QueueWorkerState(), count: 3)
    }

    private enum PreparedWork {
        case empty
        case completed(wantsInterrupt: Bool)
        case report(
            chain: VirtqueueChain,
            ranges: [GuestRange],
            reportedBytes: Int
        )
        case fault
        case stale
    }

    private enum ReportCompletion {
        case published(wantsInterrupt: Bool)
        case fault
        case stale
    }

    private struct GuestRange: Equatable, Sendable {
        var address: UInt64
        var length: UInt64

        var end: UInt64 { address + length }
    }

    private enum ReportAdmission {
        case accepted(ranges: [GuestRange], reportedBytes: Int)
        case invalid
        case revoked
    }

    private let memory: GuestMemory
    private let limits: VirtioBalloonLimits
    private let releaseRange: @Sendable (UInt64, UInt64) -> GuestMemoryReleaseResult
    private let log: @Sendable (String) -> Void
    private let submitWork: (@escaping @Sendable () -> Void) -> Void
    private let workerStateLock = NSLock()
    // Device reset and queue reconfiguration hold the transport lock before entering this fence.
    // A worker never waits for the transport lock while holding the fence, which prevents a
    // reset/worker lock cycle while still forbidding reclaim from starting after revocation.
    private let lifecycleFence = NSLock()
    private var workerState = WorkerState()
    private let reportRequests = Atomic<UInt64>(0)
    private let reportRejected = Atomic<UInt64>(0)
    private let reportBytes = Atomic<UInt64>(0)
    private let reclaimedByteCount = Atomic<UInt64>(0)
    private let releaseFailures = Atomic<UInt64>(0)
    private let classicRequests = Atomic<UInt64>(0)
    private let invalidClassicRequests = Atomic<UInt64>(0)
    private let queueFaults = Atomic<UInt64>(0)
    private let boundedDrainStops = Atomic<UInt64>(0)
    private let workerTurns = Atomic<UInt64>(0)
    private let workerYields = Atomic<UInt64>(0)
    private let coalescedWorkerRequests = Atomic<UInt64>(0)
    private let revokedWorkerTurns = Atomic<UInt64>(0)
    private let reportProcessingNanoseconds = Atomic<UInt64>(0)
    private let maximumReportProcessingNanoseconds = Mutex<UInt64>(0)

    public convenience init(
        memory: GuestMemory,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let worker = DispatchQueue(
            label: "dev.dory.virtio-balloon",
            qos: .utility
        )
        self.init(
            memory: memory,
            limits: .production,
            releaseRange: { [memory] address, length in
                memory.releaseRange(guestAddress: address, length: length)
            },
            log: log,
            submitWork: { operation in worker.async(execute: operation) }
        )
    }

    init(
        memory: GuestMemory,
        limits: VirtioBalloonLimits,
        releaseRange: @escaping @Sendable (UInt64, UInt64) -> GuestMemoryReleaseResult,
        log: @escaping @Sendable (String) -> Void = { _ in },
        submitWork: @escaping (@escaping @Sendable () -> Void) -> Void = { operation in
            operation()
        }
    ) {
        self.memory = memory
        self.limits = limits
        self.releaseRange = releaseRange
        self.log = log
        self.submitWork = submitWork
    }

    public var configSpace: [UInt8] {
        // num_pages = 0 (classic inflation is parked), actual = 0.
        [UInt8](repeating: 0, count: 8)
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard transport.queues.indices.contains(queue), queue < queueCount else { return }
        let generation = workerStateLock.withLock { () -> UInt64? in
            if let reference = workerState.transport {
                if let existing = reference.value {
                    guard existing === transport else {
                        queueFaults.wrappingAdd(1, ordering: .relaxed)
                        return nil
                    }
                } else {
                    // A backend is normally owned by exactly one transport. If a synthetic caller
                    // outlives that transport, revoke every orphaned scheduled turn before binding
                    // a replacement so its kick cannot be coalesced into a dead worker task.
                    for index in workerState.queues.indices {
                        advanceWorkerGenerationLocked(queue: index)
                    }
                    workerState.transport = WeakTransportReference(transport)
                }
            } else {
                workerState.transport = WeakTransportReference(transport)
            }
            if workerState.queues[queue].scheduled {
                workerState.queues[queue].kickPending = true
                coalescedWorkerRequests.wrappingAdd(1, ordering: .relaxed)
                return nil
            }
            workerState.queues[queue].scheduled = true
            return workerState.queues[queue].generation
        }
        guard let generation else { return }
        submitWorkerTurn(queue: queue, generation: generation, transport: transport)
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        revokeWorker(queue: nil, transport: transport)
    }

    public func queueStateChanged(
        queue: Int,
        ready: Bool,
        transport: VirtioMMIOTransport
    ) {
        _ = ready
        guard (0..<queueCount).contains(queue) else { return }
        revokeWorker(queue: queue, transport: transport)
    }

    private func advanceWorkerGenerationLocked(queue: Int) {
        workerState.queues[queue].generation &+= 1
        if workerState.queues[queue].generation == 0 {
            workerState.queues[queue].generation = 1
        }
        workerState.queues[queue].scheduled = false
        workerState.queues[queue].kickPending = false
    }

    private func submitWorkerTurn(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        submitWork { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.runWorkerTurn(
                queue: queue,
                generation: generation,
                transport: transport
            )
        }
    }

    private func runWorkerTurn(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        guard isCurrentWorker(queue: queue, generation: generation, transport: transport) else {
            revokedWorkerTurns.wrappingAdd(1, ordering: .relaxed)
            return
        }
        workerTurns.wrappingAdd(1, ordering: .relaxed)
        var handled = 0
        var wantsInterrupt = false
        var stoppedOnFault = false

        while handled < limits.maximumChainsPerWorkerTurn {
            switch prepareWork(queue: queue, generation: generation, transport: transport) {
            case .empty:
                finishWorkerTurn(
                    queue: queue,
                    generation: generation,
                    transport: transport,
                    wantsInterrupt: wantsInterrupt,
                    knownPendingWork: false
                )
                return
            case let .completed(interrupt):
                handled += 1
                wantsInterrupt = wantsInterrupt || interrupt
            case let .report(chain, ranges, reportedBytes):
                handled += 1
                switch completeReport(
                    chain,
                    ranges: ranges,
                    reportedBytes: reportedBytes,
                    queue: queue,
                    generation: generation,
                    transport: transport
                ) {
                case let .published(interrupt):
                    wantsInterrupt = wantsInterrupt || interrupt
                case .fault:
                    stoppedOnFault = true
                case .stale:
                    revokedWorkerTurns.wrappingAdd(1, ordering: .relaxed)
                    return
                }
            case .fault:
                stoppedOnFault = true
            case .stale:
                revokedWorkerTurns.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if stoppedOnFault { break }
        }

        let pending = stoppedOnFault ? false : pendingWork(
            queue: queue,
            generation: generation,
            transport: transport
        )
        if pending {
            boundedDrainStops.wrappingAdd(1, ordering: .relaxed)
        }
        finishWorkerTurn(
            queue: queue,
            generation: generation,
            transport: transport,
            wantsInterrupt: wantsInterrupt,
            knownPendingWork: pending
        )
    }

    private func prepareWork(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> PreparedWork {
        transport.withQueueLock {
            guard isCurrentWorker(
                queue: queue,
                generation: generation,
                transport: transport
            ) else { return .stale }
            let virtqueue = transport.queues[queue]
            let chain: VirtqueueChain
            do {
                guard let next = try virtqueue.pop() else { return .empty }
                chain = next
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }

            if queue == 2 {
                switch admitReport(chain) {
                case .invalid:
                    reportRejected.wrappingAdd(1, ordering: .relaxed)
                case .revoked:
                    queueFaults.wrappingAdd(1, ordering: .relaxed)
                    return .fault
                case let .accepted(ranges, reportedBytes):
                    return .report(
                        chain: chain,
                        ranges: ranges,
                        reportedBytes: reportedBytes
                    )
                }
            } else {
                processClassicRequest(chain)
            }

            do {
                return .completed(wantsInterrupt: try virtqueue.push(chain, written: 0))
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }
        }
    }

    private func completeReport(
        _ chain: VirtqueueChain,
        ranges: [GuestRange],
        reportedBytes: Int,
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> ReportCompletion {
        let startedAt = Self.monotonicNanoseconds()
        lifecycleFence.lock()
        guard isCurrentWorker(
            queue: queue,
            generation: generation,
            transport: transport
        ) else {
            lifecycleFence.unlock()
            return .stale
        }
        processAcceptedReport(ranges: ranges, reportedBytes: reportedBytes)
        lifecycleFence.unlock()

        let elapsed = Self.monotonicNanoseconds() &- startedAt
        reportProcessingNanoseconds.wrappingAdd(elapsed, ordering: .relaxed)
        maximumReportProcessingNanoseconds.withLock { maximum in
            maximum = max(maximum, elapsed)
        }

        return transport.withQueueLock {
            guard isCurrentWorker(
                queue: queue,
                generation: generation,
                transport: transport
            ) else { return .stale }
            do {
                return .published(wantsInterrupt: try transport.queues[queue].push(
                    chain,
                    written: 0
                ))
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }
        }
    }

    private func pendingWork(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        transport.withQueueLock {
            guard isCurrentWorker(
                queue: queue,
                generation: generation,
                transport: transport
            ) else { return false }
            do {
                return try transport.queues[queue].pendingCount() > 0
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return false
            }
        }
    }

    private func finishWorkerTurn(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport,
        wantsInterrupt: Bool,
        knownPendingWork: Bool
    ) {
        if wantsInterrupt {
            transport.withQueueLock {
                if isCurrentWorker(
                    queue: queue,
                    generation: generation,
                    transport: transport
                ) {
                    transport.notifyUsed()
                }
            }
        }

        let shouldContinue = workerStateLock.withLock { () -> Bool in
            guard isCurrentWorkerLocked(
                queue: queue,
                generation: generation,
                transport: transport
            ) else { return false }
            let pending = knownPendingWork || workerState.queues[queue].kickPending
            workerState.queues[queue].kickPending = false
            if !pending {
                workerState.queues[queue].scheduled = false
            }
            return pending
        }
        if shouldContinue {
            workerYields.wrappingAdd(1, ordering: .relaxed)
            submitWorkerTurn(queue: queue, generation: generation, transport: transport)
        }
    }

    private func revokeWorker(
        queue: Int?,
        transport: VirtioMMIOTransport
    ) {
        lifecycleFence.lock()
        workerStateLock.withLock {
            if let existing = workerState.transport?.value, existing !== transport {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if workerState.transport == nil {
                workerState.transport = WeakTransportReference(transport)
            }
            let indices = queue.map { [$0] } ?? Array(workerState.queues.indices)
            for index in indices {
                advanceWorkerGenerationLocked(queue: index)
            }
        }
        lifecycleFence.unlock()
    }

    private func isCurrentWorker(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        workerStateLock.withLock {
            isCurrentWorkerLocked(
                queue: queue,
                generation: generation,
                transport: transport
            )
        }
    }

    private func isCurrentWorkerLocked(
        queue: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        workerState.queues.indices.contains(queue)
            && workerState.transport?.value === transport
            && workerState.queues[queue].generation == generation
            && workerState.queues[queue].scheduled
    }

    private func processClassicRequest(_ chain: VirtqueueChain) {
        classicRequests.wrappingAdd(1, ordering: .relaxed)
        let valid = chain.withLeaseHeld { access in
            // inflateq/deflateq contain a device-readable array of 32-bit balloon PFNs. Dory's
            // target is zero, so valid unsolicited arrays are acknowledged as no-ops.
            !chain.containsZeroLengthDescriptor
                && access.readableSegmentCount > 0
                && access.writableSegmentCount == 0
                && access.readableByteCount > 0
                && access.readableByteCount % MemoryLayout<UInt32>.size == 0
                && access.readableByteCount <= 256 * MemoryLayout<UInt32>.size
        } ?? false
        if !valid {
            invalidClassicRequests.wrappingAdd(1, ordering: .relaxed)
        }
    }

    private func processAcceptedReport(ranges: [GuestRange], reportedBytes: Int) {
        let event = reportRequests.wrappingAdd(1, ordering: .relaxed).newValue
        reportBytes.wrappingAdd(UInt64(reportedBytes), ordering: .relaxed)
        var reclaimedThisReport: UInt64 = 0
        for range in ranges {
            let result = releaseRange(range.address, range.length)
            if result.hostMemoryWasReclaimed {
                reclaimedThisReport &+= range.length
            } else {
                releaseFailures.wrappingAdd(1, ordering: .relaxed)
            }
        }
        if reclaimedThisReport > 0 {
            reclaimedByteCount.wrappingAdd(reclaimedThisReport, ordering: .relaxed)
        }
        if event <= 30 || event % 64 == 0 {
            let total = reclaimedByteCount.load(ordering: .relaxed)
            log(
                "balloon: report #\(event), \(ranges.count) ranges, "
                    + "\(reportedBytes >> 20) MiB reported, \(total >> 20) MiB reclaimed"
            )
        }
    }

    private static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func admitReport(_ chain: VirtqueueChain) -> ReportAdmission {
        chain.withLeaseHeld { access -> ReportAdmission in
            guard !chain.containsZeroLengthDescriptor,
                  access.readableSegmentCount == 0,
                  access.writableSegmentCount > 0,
                  access.writableSegmentCount <= limits.maximumReportRanges,
                  access.writableByteCount > 0,
                  access.writableByteCount <= limits.maximumReportBytes else {
                return .invalid
            }

            let hostBase = UInt64(UInt(bitPattern: memory.hostBase))
            let (hostEnd, hostEndOverflow) = hostBase.addingReportingOverflow(memory.size)
            guard !hostEndOverflow else { return .invalid }

            var staged = [GuestRange]()
            staged.reserveCapacity(access.writableSegmentCount)
            for segment in access.segments {
                guard segment.isDeviceWritable, segment.length > 0 else { return .invalid }
                let start = UInt64(UInt(bitPattern: segment.pointer))
                let (end, endOverflow) = start.addingReportingOverflow(UInt64(segment.length))
                guard !endOverflow, start >= hostBase, end <= hostEnd else { return .invalid }

                let guestStart = memory.guestBase + (start - hostBase)
                let (guestEnd, guestEndOverflow) = guestStart.addingReportingOverflow(
                    UInt64(segment.length)
                )
                guard !guestEndOverflow else { return .invalid }
                let alignedStart = Self.roundUpToHostPage(guestStart)
                let alignedEnd = guestEnd & ~(HostPage.size - 1)
                if let alignedStart, alignedEnd > alignedStart {
                    staged.append(GuestRange(
                        address: alignedStart,
                        length: alignedEnd - alignedStart
                    ))
                }
            }
            return .accepted(
                ranges: Self.mergeOverlappingRanges(staged),
                reportedBytes: access.writableByteCount
            )
        } ?? .revoked
    }

    private static func roundUpToHostPage(_ value: UInt64) -> UInt64? {
        let (adjusted, overflow) = value.addingReportingOverflow(HostPage.size - 1)
        guard !overflow else { return nil }
        return adjusted & ~(HostPage.size - 1)
    }

    private static func mergeOverlappingRanges(_ input: [GuestRange]) -> [GuestRange] {
        let sorted = input.sorted {
            if $0.address == $1.address { return $0.length < $1.length }
            return $0.address < $1.address
        }
        var result = [GuestRange]()
        result.reserveCapacity(sorted.count)
        for range in sorted {
            guard var last = result.last else {
                result.append(range)
                continue
            }
            if range.address <= last.end {
                let end = max(last.end, range.end)
                last.length = end - last.address
                result[result.count - 1] = last
            } else {
                result.append(range)
            }
        }
        return result
    }

    public var statistics: VirtioBalloonStatistics {
        VirtioBalloonStatistics(
            reportRequests: reportRequests.load(ordering: .relaxed),
            reportRejected: reportRejected.load(ordering: .relaxed),
            reportBytes: reportBytes.load(ordering: .relaxed),
            reclaimedBytes: reclaimedByteCount.load(ordering: .relaxed),
            releaseFailures: releaseFailures.load(ordering: .relaxed),
            classicRequests: classicRequests.load(ordering: .relaxed),
            invalidClassicRequests: invalidClassicRequests.load(ordering: .relaxed),
            queueFaults: queueFaults.load(ordering: .relaxed),
            boundedDrainStops: boundedDrainStops.load(ordering: .relaxed),
            workerTurns: workerTurns.load(ordering: .relaxed),
            workerYields: workerYields.load(ordering: .relaxed),
            coalescedWorkerRequests: coalescedWorkerRequests.load(ordering: .relaxed),
            revokedWorkerTurns: revokedWorkerTurns.load(ordering: .relaxed),
            reportProcessingNanoseconds: reportProcessingNanoseconds.load(ordering: .relaxed),
            maximumReportProcessingNanoseconds: maximumReportProcessingNanoseconds.withLock { $0 }
        )
    }

    /// Compatibility snapshots for existing telemetry callers. New code should consume
    /// `statistics` so failures and rejected reports are not mistaken for successful reclaim.
    public var reclaimedBytes: UInt64 { statistics.reclaimedBytes }
    public var reportEvents: UInt64 { statistics.reportRequests }
}
