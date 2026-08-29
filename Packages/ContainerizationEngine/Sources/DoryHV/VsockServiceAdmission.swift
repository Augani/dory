import Foundation

/// Stable service identities for every host resource reachable through the VM's vsock device.
///
/// The identity is intentionally not a guest-selected port number. A malicious or compromised
/// peer must not be able to manufacture new accounting buckets and evade a per-service ceiling.
public enum VirtioVsockService: String, CaseIterable, Hashable, Sendable {
    /// Short-lived host RPCs to the guest agent, including USB capability/mutation calls.
    case agentRPC
    /// The private host Unix socket that exposes the guest agent control endpoint.
    case agentSocket
    /// The private dataplane socket whose authenticated preamble selects a guest port.
    case agentForward
    case docker
    case fileEvents
    case hostAI
    case sshAgent
    case shell
    case usbip
}

public enum VirtioVsockServiceAdmissionConfigurationError: Error, Equatable, Sendable {
    case invalidAggregateLimit(Int)
    case invalidDefaultServiceLimit(Int)
    case invalidServiceLimit(service: VirtioVsockService, limit: Int)
    case serviceLimitExceedsAggregate(service: VirtioVsockService, limit: Int, aggregate: Int)
}

/// Immutable capacity policy shared by every service on one vsock device.
public struct VirtioVsockServiceAdmissionLimits: Equatable, Sendable {
    public static let hardenedDefault = VirtioVsockServiceAdmissionLimits(
        maximumSessionsTotal: 64,
        defaultMaximumSessionsPerService: 16,
        serviceOverrides: [
            .agentRPC: 8,
            .fileEvents: 8,
            .sshAgent: 8,
            .shell: 8,
            .usbip: 8,
        ],
        validated: ()
    )

    public let maximumSessionsTotal: Int
    public let defaultMaximumSessionsPerService: Int
    public let serviceOverrides: [VirtioVsockService: Int]

    public init(
        maximumSessionsTotal: Int,
        defaultMaximumSessionsPerService: Int,
        serviceOverrides: [VirtioVsockService: Int] = [:]
    ) throws {
        guard (1...256).contains(maximumSessionsTotal) else {
            throw VirtioVsockServiceAdmissionConfigurationError.invalidAggregateLimit(
                maximumSessionsTotal
            )
        }
        guard (1...maximumSessionsTotal).contains(defaultMaximumSessionsPerService) else {
            throw VirtioVsockServiceAdmissionConfigurationError.invalidDefaultServiceLimit(
                defaultMaximumSessionsPerService
            )
        }
        for (service, limit) in serviceOverrides {
            guard limit > 0 else {
                throw VirtioVsockServiceAdmissionConfigurationError.invalidServiceLimit(
                    service: service,
                    limit: limit
                )
            }
            guard limit <= maximumSessionsTotal else {
                throw VirtioVsockServiceAdmissionConfigurationError.serviceLimitExceedsAggregate(
                    service: service,
                    limit: limit,
                    aggregate: maximumSessionsTotal
                )
            }
        }
        self.init(
            maximumSessionsTotal: maximumSessionsTotal,
            defaultMaximumSessionsPerService: defaultMaximumSessionsPerService,
            serviceOverrides: serviceOverrides,
            validated: ()
        )
    }

    public func maximumSessions(for service: VirtioVsockService) -> Int {
        serviceOverrides[service] ?? defaultMaximumSessionsPerService
    }

    private init(
        maximumSessionsTotal: Int,
        defaultMaximumSessionsPerService: Int,
        serviceOverrides: [VirtioVsockService: Int],
        validated: Void
    ) {
        self.maximumSessionsTotal = maximumSessionsTotal
        self.defaultMaximumSessionsPerService = defaultMaximumSessionsPerService
        self.serviceOverrides = serviceOverrides
    }
}

/// Typed refusal returned before a host fd, relay thread, or guest connection is admitted.
public enum VirtioVsockServiceAdmissionError: Error, Equatable, Sendable {
    case serviceCapacityReached(service: VirtioVsockService, limit: Int)
    case aggregateCapacityReached(limit: Int)
    case deviceResetting
    case deviceQuiesced
    case lifecycleRevoked(service: VirtioVsockService)
}

/// Observable admission state. Counts include reservations that have passed policy but have not yet
/// published their stop callback, so the snapshot never understates resources already committed.
public struct VirtioVsockServiceAdmissionSnapshot: Equatable, Sendable {
    public let activeSessionsTotal: Int
    public let activeSessionsByService: [VirtioVsockService: Int]
    public let serviceCapacityRejections: [VirtioVsockService: UInt64]
    public let aggregateCapacityRejections: UInt64
    public let resettingRejections: UInt64
    public let quiescedRejections: UInt64
    public let resetRevocations: UInt64
    public let terminalRevocations: UInt64
    public let latePublicationRejections: UInt64
    public let completedSessions: UInt64
    public let generation: UInt64
    public let isResetting: Bool
    public let isQuiesced: Bool
}

/// A two-phase reservation prevents reset, stop, or a concurrent cap crossing from publishing an
/// unowned late session. It is internal because production callers must use the service-labelled
/// listener/connect APIs on VirtioVsock rather than manually handling admission tokens.
struct VirtioVsockServiceReservation: Sendable {
    fileprivate let id: UUID
    fileprivate let service: VirtioVsockService
    fileprivate let generation: UInt64
}

/// Exact ownership of one published service session. Close/deinit is idempotent and generation
/// checked; reset may revoke the authority first, in which case a late close is harmless.
final class VirtioVsockServiceLease: @unchecked Sendable {
    private let lock = NSLock()
    private weak var authority: VirtioVsockServiceAdmissionAuthority?
    private var id: UUID?
    private let generation: UInt64

    fileprivate init(
        authority: VirtioVsockServiceAdmissionAuthority,
        id: UUID,
        generation: UInt64
    ) {
        self.authority = authority
        self.id = id
        self.generation = generation
    }

    func close() {
        lock.lock()
        let ownedID = id
        id = nil
        let authority = authority
        self.authority = nil
        lock.unlock()
        if let ownedID {
            authority?.release(id: ownedID, generation: generation)
        }
    }

    /// Replaces the provisional transport-close callback with the owning service session's stronger
    /// stop action. False means reset/quiesce already revoked the generation.
    func replaceStopAction(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard let id else {
            lock.unlock()
            return false
        }
        let authority = authority
        lock.unlock()
        return authority?.replaceStopAction(
            id: id,
            generation: generation,
            action: action
        ) ?? false
    }

    deinit {
        close()
    }
}

/// Per-VM authority shared by guest-initiated listeners, host-initiated connections, and the local
/// Unix relay frontends. It owns no service object, only bounded reservations and idempotent stop
/// callbacks; bridge lifecycles remain responsible for unregistering listeners and draining work.
final class VirtioVsockServiceAdmissionAuthority: @unchecked Sendable {
    private enum Phase {
        case active
        case resetting
        case quiesced
    }

    private struct ReservationRecord {
        let service: VirtioVsockService
        let generation: UInt64
    }

    private struct SessionRecord {
        let service: VirtioVsockService
        let generation: UInt64
        var requestStop: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let limits: VirtioVsockServiceAdmissionLimits
    private var phase: Phase = .active
    private var generation: UInt64 = 1
    private var reservations = [UUID: ReservationRecord]()
    private var sessions = [UUID: SessionRecord]()
    private var serviceCapacityRejections = [VirtioVsockService: UInt64]()
    private var aggregateCapacityRejections: UInt64 = 0
    private var resettingRejections: UInt64 = 0
    private var quiescedRejections: UInt64 = 0
    private var resetRevocations: UInt64 = 0
    private var terminalRevocations: UInt64 = 0
    private var latePublicationRejections: UInt64 = 0
    private var completedSessions: UInt64 = 0

    init(limits: VirtioVsockServiceAdmissionLimits) {
        self.limits = limits
    }

    func reserve(_ service: VirtioVsockService) throws -> VirtioVsockServiceReservation {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .active:
            break
        case .resetting:
            increment(&resettingRejections)
            throw VirtioVsockServiceAdmissionError.deviceResetting
        case .quiesced:
            increment(&quiescedRejections)
            throw VirtioVsockServiceAdmissionError.deviceQuiesced
        }

        let activeTotal = reservations.count + sessions.count
        guard activeTotal < limits.maximumSessionsTotal else {
            increment(&aggregateCapacityRejections)
            throw VirtioVsockServiceAdmissionError.aggregateCapacityReached(
                limit: limits.maximumSessionsTotal
            )
        }
        let serviceTotal = countLocked(service: service)
        let serviceLimit = limits.maximumSessions(for: service)
        guard serviceTotal < serviceLimit else {
            var count = serviceCapacityRejections[service] ?? 0
            increment(&count)
            serviceCapacityRejections[service] = count
            throw VirtioVsockServiceAdmissionError.serviceCapacityReached(
                service: service,
                limit: serviceLimit
            )
        }
        let id = UUID()
        reservations[id] = ReservationRecord(service: service, generation: generation)
        return VirtioVsockServiceReservation(
            id: id,
            service: service,
            generation: generation
        )
    }

    func cancel(_ reservation: VirtioVsockServiceReservation) {
        lock.lock()
        if reservations[reservation.id]?.generation == reservation.generation,
           reservations[reservation.id]?.service == reservation.service {
            reservations.removeValue(forKey: reservation.id)
        }
        lock.unlock()
    }

    func publish(
        _ reservation: VirtioVsockServiceReservation,
        requestStop: @escaping @Sendable () -> Void
    ) -> VirtioVsockServiceLease? {
        lock.lock()
        guard case .active = phase,
              generation == reservation.generation,
              let record = reservations.removeValue(forKey: reservation.id),
              record.generation == reservation.generation,
              record.service == reservation.service else {
            // Remove an exact stale reservation if reset has not already done so.
            if reservations[reservation.id]?.generation == reservation.generation {
                reservations.removeValue(forKey: reservation.id)
            }
            increment(&latePublicationRejections)
            lock.unlock()
            return nil
        }
        sessions[reservation.id] = SessionRecord(
            service: reservation.service,
            generation: reservation.generation,
            requestStop: requestStop
        )
        lock.unlock()
        return VirtioVsockServiceLease(
            authority: self,
            id: reservation.id,
            generation: reservation.generation
        )
    }

    func beginReset() {
        revoke(terminal: false)
    }

    func finishReset() {
        lock.lock()
        if case .resetting = phase { phase = .active }
        lock.unlock()
    }

    func quiesce() {
        revoke(terminal: true)
    }

    var snapshot: VirtioVsockServiceAdmissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var activeByService = [VirtioVsockService: Int]()
        for record in reservations.values {
            activeByService[record.service, default: 0] += 1
        }
        for record in sessions.values {
            activeByService[record.service, default: 0] += 1
        }
        return VirtioVsockServiceAdmissionSnapshot(
            activeSessionsTotal: reservations.count + sessions.count,
            activeSessionsByService: activeByService,
            serviceCapacityRejections: serviceCapacityRejections,
            aggregateCapacityRejections: aggregateCapacityRejections,
            resettingRejections: resettingRejections,
            quiescedRejections: quiescedRejections,
            resetRevocations: resetRevocations,
            terminalRevocations: terminalRevocations,
            latePublicationRejections: latePublicationRejections,
            completedSessions: completedSessions,
            generation: generation,
            isResetting: {
                if case .resetting = phase { return true }
                return false
            }(),
            isQuiesced: {
                if case .quiesced = phase { return true }
                return false
            }()
        )
    }

    fileprivate func release(id: UUID, generation: UInt64) {
        lock.lock()
        if sessions[id]?.generation == generation {
            sessions.removeValue(forKey: id)
            increment(&completedSessions)
        }
        lock.unlock()
    }

    fileprivate func replaceStopAction(
        id: UUID,
        generation: UInt64,
        action: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var record = sessions[id], record.generation == generation else {
            return false
        }
        record.requestStop = action
        sessions[id] = record
        return true
    }

    private func revoke(terminal: Bool) {
        let stopActions: [@Sendable () -> Void]
        lock.lock()
        if case .quiesced = phase {
            lock.unlock()
            return
        }
        phase = terminal ? .quiesced : .resetting
        generation &+= 1
        if generation == 0 { generation = 1 }
        let revokedCount = UInt64(reservations.count + sessions.count)
        if terminal {
            addClamped(revokedCount, to: &terminalRevocations)
        } else {
            addClamped(revokedCount, to: &resetRevocations)
        }
        stopActions = sessions.values.map(\.requestStop)
        reservations.removeAll(keepingCapacity: true)
        sessions.removeAll(keepingCapacity: true)
        lock.unlock()

        // Never execute a service callback while holding admission state: every callback is allowed
        // to close a VsockConnection, which re-enters the device's transport lifecycle.
        for requestStop in stopActions { requestStop() }
    }

    private func countLocked(service: VirtioVsockService) -> Int {
        reservations.values.reduce(0) { $0 + ($1.service == service ? 1 : 0) }
            + sessions.values.reduce(0) { $0 + ($1.service == service ? 1 : 0) }
    }

    private func increment(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }

    private func addClamped(_ amount: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        value = overflow ? UInt64.max : sum
    }
}

/// Holds a service lease for exactly as long as its underlying transport stream remains owned.
/// Reset/quiesce closes the underlying stream via the authority's stop callback; a late wrapper
/// close is harmless because the lease generation has already been revoked.
final class ServiceOwnedVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: VsockConnection?
    private var lease: VirtioVsockServiceLease?

    init(connection: VsockConnection, lease: VirtioVsockServiceLease) {
        self.connection = connection
        self.lease = lease
    }

    var isPeerClosed: Bool {
        let connection = currentConnection
        let closed = connection?.isPeerClosed ?? true
        if closed { releaseLease() }
        return closed
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let connection = currentConnection else { return 0 }
        let count = try connection.read(into: buffer)
        if count == 0, connection.isPeerClosed { releaseLease() }
        return count
    }

    func write(_ bytes: [UInt8]) throws {
        guard let connection = currentConnection else {
            throw VsockConnectionWriteError.connectionClosed
        }
        do {
            try connection.write(bytes)
        } catch {
            if connection.isPeerClosed { releaseLease() }
            throw error
        }
    }

    func write(_ bytes: [UInt8], timeoutNanoseconds: UInt64?) throws {
        guard let connection = currentConnection else {
            throw VsockConnectionWriteError.connectionClosed
        }
        do {
            try connection.write(bytes, timeoutNanoseconds: timeoutNanoseconds)
        } catch {
            if connection.isPeerClosed { releaseLease() }
            throw error
        }
    }

    func waitForReadable(timeoutNanoseconds: UInt64?) -> Bool {
        guard let connection = currentConnection else { return true }
        let ready = connection.waitForReadable(timeoutNanoseconds: timeoutNanoseconds)
        if connection.isPeerClosed { releaseLease() }
        return ready
    }

    func shutdownSend() {
        currentConnection?.shutdownSend()
    }

    func close() {
        let ownedConnection: VsockConnection?
        let ownedLease: VirtioVsockServiceLease?
        lock.lock()
        ownedConnection = connection
        ownedLease = lease
        connection = nil
        lease = nil
        lock.unlock()
        ownedConnection?.close()
        ownedLease?.close()
    }

    func replaceServiceStopAction(
        _ action: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        let lease = lease
        lock.unlock()
        return lease?.replaceStopAction(action) ?? false
    }

    deinit {
        close()
    }

    private var currentConnection: VsockConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    private func releaseLease() {
        lock.lock()
        let ownedLease = lease
        lease = nil
        lock.unlock()
        ownedLease?.close()
    }
}
