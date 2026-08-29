import DoryFSWorkerContracts
import Foundation

/// The exact request-memory ceilings that apply to one share after intersecting its bootstrap
/// authority with the worker-wide envelope. Long-lived HostFS resource limits remain worker-side;
/// these values are the complete VMM admission contract held through used-ring publication.
public struct DoryFSWorkerEffectiveAdmissionLimits: Equatable, Sendable {
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumInFlightRequests: Int
    public let maximumAggregateRequestBytes: Int
    public let maximumAggregateResponseBytes: Int

    init(
        worker: DoryFSWorkerLimits,
        share: DoryFSShareResourceLimits
    ) {
        maximumRequestBytes = min(
            worker.maximumRequestBytes,
            share.maximumAggregateRequestBytes
        )
        maximumResponseBytes = min(
            worker.maximumResponseBytes,
            share.maximumAggregateResponseBytes
        )
        maximumInFlightRequests = min(
            worker.maximumInFlightRequests,
            share.maximumInFlightRequests
        )
        maximumAggregateRequestBytes = min(
            worker.maximumAggregateRequestBytes,
            share.maximumAggregateRequestBytes
        )
        maximumAggregateResponseBytes = min(
            worker.maximumAggregateResponseBytes,
            share.maximumAggregateResponseBytes
        )
    }
}

struct DoryFSWorkerAdmissionShape: Equatable, Sendable {
    let requestBytes: Int
    let responseBytes: Int
}

struct DoryFSWorkerAdmissionWaiterID: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

enum DoryFSWorkerFrontendAdmissionResult: Sendable {
    case admitted(DoryFSWorkerAdmissionLease)
    case deferred
    case rejected(DoryFSWorkerBrokerError)
}

/// Completes a deferred frontend admission exactly once. A workspace terminal event must be
/// observable here: silently deleting a waiter would leave its virtqueue available forever while
/// the frontend continued to believe a capacity grant was pending.
enum DoryFSWorkerFrontendAdmissionResolution: Sendable {
    case granted(DoryFSWorkerAdmissionLease)
    case terminated(DoryFSWorkerBrokerError)
}

/// One workspace reservation. The authority owns the counters; both explicit release and deinit
/// are idempotent so a reset or abandoned deferred queue cannot strand workspace capacity.
final class DoryFSWorkerAdmissionLease: @unchecked Sendable {
    fileprivate let identifier: UUID
    fileprivate let shareCapabilityID: DoryFSShareCapabilityID
    let shape: DoryFSWorkerAdmissionShape
    fileprivate let authority: DoryFSWorkerWorkspaceAdmissionAuthority

    fileprivate init(
        identifier: UUID,
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape,
        authority: DoryFSWorkerWorkspaceAdmissionAuthority
    ) {
        self.identifier = identifier
        self.shareCapabilityID = shareCapabilityID
        self.shape = shape
        self.authority = authority
    }

    func release() {
        authority.release(identifier: identifier)
    }

    var isValid: Bool {
        authority.containsReservation(identifier: identifier)
    }

    deinit {
        release()
    }
}

struct DoryFSWorkerWorkspaceAdmissionSnapshot: Equatable, Sendable {
    let inFlightRequests: Int
    let peakInFlightRequests: Int
    let aggregateRequestBytes: Int
    let aggregateResponseBytes: Int
    let deferredWaiters: Int
}

/// Synchronous workspace-wide admission used before a virtqueue pop. Every broker created from one
/// bootstrap shares this authority. Capacity released by either share is reserved for eligible
/// waiters in FIFO order before their callbacks run, preventing direct kicks from stealing a fair
/// reschedule. A temporarily share-blocked waiter does not head-of-line block another share that is
/// eligible under the workspace envelope.
final class DoryFSWorkerWorkspaceAdmissionAuthority: @unchecked Sendable {
    private struct Usage {
        var inFlightRequests = 0
        var peakInFlightRequests = 0
        var aggregateRequestBytes = 0
        var aggregateResponseBytes = 0
    }

    private struct Reservation {
        let shareCapabilityID: DoryFSShareCapabilityID
        let shape: DoryFSWorkerAdmissionShape
    }

    private struct Waiter {
        let identifier: DoryFSWorkerAdmissionWaiterID
        let shareCapabilityID: DoryFSShareCapabilityID
        let shape: DoryFSWorkerAdmissionShape
        let onResolved: @Sendable (DoryFSWorkerFrontendAdmissionResolution) -> Void
    }

    private struct Delivery {
        let callback: @Sendable (DoryFSWorkerFrontendAdmissionResolution) -> Void
        let resolution: DoryFSWorkerFrontendAdmissionResolution
    }

    private let workerLimits: DoryFSWorkerLimits
    private let shareLimits: [DoryFSShareCapabilityID: DoryFSShareResourceLimits]
    private let lock = NSLock()
    private var workspaceUsage = Usage()
    private var shareUsage = [DoryFSShareCapabilityID: Usage]()
    private var reservations = [UUID: Reservation]()
    private var waiters = [Waiter]()
    private var waiterIDs = Set<DoryFSWorkerAdmissionWaiterID>()
    private var active = true

    init(
        workerLimits: DoryFSWorkerLimits,
        shareLimits: [DoryFSShareCapabilityID: DoryFSShareResourceLimits]
    ) {
        precondition(!shareLimits.isEmpty)
        self.workerLimits = workerLimits
        self.shareLimits = shareLimits
    }

    func effectiveLimits(
        for shareCapabilityID: DoryFSShareCapabilityID
    ) -> DoryFSWorkerEffectiveAdmissionLimits? {
        guard let share = shareLimits[shareCapabilityID] else { return nil }
        return DoryFSWorkerEffectiveAdmissionLimits(worker: workerLimits, share: share)
    }

    func resourceLimits(
        for shareCapabilityID: DoryFSShareCapabilityID
    ) -> DoryFSShareResourceLimits? {
        shareLimits[shareCapabilityID]
    }

    func request(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape,
        waiterID: DoryFSWorkerAdmissionWaiterID,
        onResolved: @escaping @Sendable (DoryFSWorkerFrontendAdmissionResolution) -> Void
    ) -> DoryFSWorkerFrontendAdmissionResult {
        var deliveries = [Delivery]()
        let result: DoryFSWorkerFrontendAdmissionResult = lock.withLock {
            guard active else { return .rejected(.invalidAdmissionAuthority) }
            if let rejection = permanentRejectionLocked(
                shareCapabilityID: shareCapabilityID,
                shape: shape
            ) {
                return .rejected(rejection)
            }
            if waiters.isEmpty, fitsLocked(
                shareCapabilityID: shareCapabilityID,
                shape: shape
            ) {
                return .admitted(reserveLocked(
                    shareCapabilityID: shareCapabilityID,
                    shape: shape
                ))
            }
            if waiterIDs.insert(waiterID).inserted {
                waiters.append(Waiter(
                    identifier: waiterID,
                    shareCapabilityID: shareCapabilityID,
                    shape: shape,
                    onResolved: onResolved
                ))
            }
            deliveries = grantEligibleWaitersLocked()
            return .deferred
        }
        deliver(deliveries)
        return result
    }

    func acquireImmediately(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> Result<DoryFSWorkerAdmissionLease, DoryFSWorkerBrokerError> {
        lock.withLock {
            guard active else { return .failure(.invalidAdmissionAuthority) }
            if let rejection = permanentRejectionLocked(
                shareCapabilityID: shareCapabilityID,
                shape: shape
            ) {
                return .failure(rejection)
            }
            guard fitsLocked(shareCapabilityID: shareCapabilityID, shape: shape) else {
                return .failure(saturationErrorLocked(
                    shareCapabilityID: shareCapabilityID,
                    shape: shape
                ))
            }
            return .success(reserveLocked(
                shareCapabilityID: shareCapabilityID,
                shape: shape
            ))
        }
    }

    func cancel(waiterID: DoryFSWorkerAdmissionWaiterID) {
        lock.withLock {
            guard waiterIDs.remove(waiterID) != nil else { return }
            waiters.removeAll { $0.identifier == waiterID }
        }
    }

    func invalidate(error: DoryFSWorkerBrokerError) {
        let deliveries: [Delivery] = lock.withLock {
            guard active else { return [] }
            active = false
            let deliveries = waiters.map {
                Delivery(callback: $0.onResolved, resolution: .terminated(error))
            }
            waiters.removeAll(keepingCapacity: false)
            waiterIDs.removeAll(keepingCapacity: false)
            reservations.removeAll(keepingCapacity: false)
            workspaceUsage = Usage()
            shareUsage.removeAll(keepingCapacity: false)
            return deliveries
        }
        deliver(deliveries)
    }

    func validates(
        _ lease: DoryFSWorkerAdmissionLease,
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> Bool {
        guard lease.authority === self,
              lease.shareCapabilityID == shareCapabilityID,
              lease.shape == shape else { return false }
        return lock.withLock {
            guard let reservation = reservations[lease.identifier] else { return false }
            return reservation.shareCapabilityID == shareCapabilityID
                && reservation.shape == shape
        }
    }

    func snapshot(
        for shareCapabilityID: DoryFSShareCapabilityID? = nil
    ) -> DoryFSWorkerWorkspaceAdmissionSnapshot {
        lock.withLock {
            let usage = shareCapabilityID.flatMap { shareUsage[$0] } ?? workspaceUsage
            let deferred = shareCapabilityID.map { capability in
                waiters.lazy.filter { $0.shareCapabilityID == capability }.count
            } ?? waiters.count
            return DoryFSWorkerWorkspaceAdmissionSnapshot(
                inFlightRequests: usage.inFlightRequests,
                peakInFlightRequests: usage.peakInFlightRequests,
                aggregateRequestBytes: usage.aggregateRequestBytes,
                aggregateResponseBytes: usage.aggregateResponseBytes,
                deferredWaiters: deferred
            )
        }
    }

    fileprivate func release(identifier: UUID) {
        let deliveries: [Delivery] = lock.withLock {
            guard let reservation = reservations.removeValue(forKey: identifier) else { return [] }
            releaseUsageLocked(
                &workspaceUsage,
                shape: reservation.shape
            )
            guard var usage = shareUsage[reservation.shareCapabilityID] else {
                preconditionFailure("missing filesystem share admission usage")
            }
            releaseUsageLocked(&usage, shape: reservation.shape)
            shareUsage[reservation.shareCapabilityID] = usage
            return grantEligibleWaitersLocked()
        }
        deliver(deliveries)
    }

    fileprivate func containsReservation(identifier: UUID) -> Bool {
        lock.withLock { active && reservations[identifier] != nil }
    }

    private func permanentRejectionLocked(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> DoryFSWorkerBrokerError? {
        guard let effective = effectiveLimits(for: shareCapabilityID) else {
            return .invalidAdmissionAuthority
        }
        guard shape.requestBytes >= 0,
              shape.requestBytes <= effective.maximumRequestBytes else {
            return .requestTooLarge(
                limit: effective.maximumRequestBytes,
                actual: shape.requestBytes
            )
        }
        guard shape.responseBytes >= 0,
              shape.responseBytes <= effective.maximumResponseBytes else {
            return .responseCapacityTooLarge(
                limit: effective.maximumResponseBytes,
                actual: shape.responseBytes
            )
        }
        return nil
    }

    private func fitsLocked(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> Bool {
        guard let effective = effectiveLimits(for: shareCapabilityID) else { return false }
        let share = shareUsage[shareCapabilityID] ?? Usage()
        return adding(shape.requestBytes, to: workspaceUsage.aggregateRequestBytes)
                .map { $0 <= workerLimits.maximumAggregateRequestBytes } == true
            && adding(shape.responseBytes, to: workspaceUsage.aggregateResponseBytes)
                .map { $0 <= workerLimits.maximumAggregateResponseBytes } == true
            && workspaceUsage.inFlightRequests < workerLimits.maximumInFlightRequests
            && adding(shape.requestBytes, to: share.aggregateRequestBytes)
                .map { $0 <= effective.maximumAggregateRequestBytes } == true
            && adding(shape.responseBytes, to: share.aggregateResponseBytes)
                .map { $0 <= effective.maximumAggregateResponseBytes } == true
            && share.inFlightRequests < effective.maximumInFlightRequests
    }

    private func saturationErrorLocked(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> DoryFSWorkerBrokerError {
        guard let effective = effectiveLimits(for: shareCapabilityID) else {
            return .invalidAdmissionAuthority
        }
        let share = shareUsage[shareCapabilityID] ?? Usage()
        if workspaceUsage.inFlightRequests >= workerLimits.maximumInFlightRequests
            || share.inFlightRequests >= effective.maximumInFlightRequests {
            return .inFlightLimit(limit: effective.maximumInFlightRequests)
        }
        let workspaceRequest = adding(
            shape.requestBytes,
            to: workspaceUsage.aggregateRequestBytes
        ) ?? Int.max
        let shareRequest = adding(shape.requestBytes, to: share.aggregateRequestBytes) ?? Int.max
        if workspaceRequest > workerLimits.maximumAggregateRequestBytes
            || shareRequest > effective.maximumAggregateRequestBytes {
            return .aggregateRequestLimit(
                limit: min(
                    workerLimits.maximumAggregateRequestBytes,
                    effective.maximumAggregateRequestBytes
                ),
                requested: max(workspaceRequest, shareRequest)
            )
        }
        let workspaceResponse = adding(
            shape.responseBytes,
            to: workspaceUsage.aggregateResponseBytes
        ) ?? Int.max
        let shareResponse = adding(shape.responseBytes, to: share.aggregateResponseBytes) ?? Int.max
        return .aggregateResponseLimit(
            limit: min(
                workerLimits.maximumAggregateResponseBytes,
                effective.maximumAggregateResponseBytes
            ),
            requested: max(workspaceResponse, shareResponse)
        )
    }

    private func reserveLocked(
        shareCapabilityID: DoryFSShareCapabilityID,
        shape: DoryFSWorkerAdmissionShape
    ) -> DoryFSWorkerAdmissionLease {
        precondition(fitsLocked(shareCapabilityID: shareCapabilityID, shape: shape))
        reserveUsageLocked(&workspaceUsage, shape: shape)
        var usage = shareUsage[shareCapabilityID] ?? Usage()
        reserveUsageLocked(&usage, shape: shape)
        shareUsage[shareCapabilityID] = usage
        let identifier = UUID()
        reservations[identifier] = Reservation(
            shareCapabilityID: shareCapabilityID,
            shape: shape
        )
        return DoryFSWorkerAdmissionLease(
            identifier: identifier,
            shareCapabilityID: shareCapabilityID,
            shape: shape,
            authority: self
        )
    }

    private func grantEligibleWaitersLocked() -> [Delivery] {
        guard active else { return [] }
        var deliveries = [Delivery]()
        while let index = waiters.firstIndex(where: {
            fitsLocked(shareCapabilityID: $0.shareCapabilityID, shape: $0.shape)
        }) {
            let waiter = waiters.remove(at: index)
            waiterIDs.remove(waiter.identifier)
            deliveries.append(Delivery(
                callback: waiter.onResolved,
                resolution: .granted(reserveLocked(
                    shareCapabilityID: waiter.shareCapabilityID,
                    shape: waiter.shape
                ))
            ))
        }
        return deliveries
    }

    private func deliver(_ deliveries: [Delivery]) {
        for delivery in deliveries {
            DispatchQueue.global(qos: .userInitiated).async {
                if case .granted(let lease) = delivery.resolution,
                   !lease.isValid {
                    return
                }
                delivery.callback(delivery.resolution)
            }
        }
    }

    private func reserveUsageLocked(
        _ usage: inout Usage,
        shape: DoryFSWorkerAdmissionShape
    ) {
        usage.inFlightRequests += 1
        usage.peakInFlightRequests = max(
            usage.peakInFlightRequests,
            usage.inFlightRequests
        )
        usage.aggregateRequestBytes += shape.requestBytes
        usage.aggregateResponseBytes += shape.responseBytes
    }

    private func releaseUsageLocked(
        _ usage: inout Usage,
        shape: DoryFSWorkerAdmissionShape
    ) {
        precondition(usage.inFlightRequests > 0)
        precondition(usage.aggregateRequestBytes >= shape.requestBytes)
        precondition(usage.aggregateResponseBytes >= shape.responseBytes)
        usage.inFlightRequests -= 1
        usage.aggregateRequestBytes -= shape.requestBytes
        usage.aggregateResponseBytes -= shape.responseBytes
    }

    private func adding(_ increment: Int, to value: Int) -> Int? {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return increment >= 0 && !overflow ? sum : nil
    }
}
