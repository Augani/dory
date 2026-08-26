import Darwin
import Foundation

protocol BoundedGuestVsockSession: AnyObject, Sendable {
    func run()
    func requestStop()
}

protocol BoundedHostSocketConnectContext: AnyObject, Sendable {
    func claimPendingDescriptor(_ descriptor: Int32) -> Bool
    func releasePendingDescriptor(_ descriptor: Int32)
    var shouldCancelConnect: Bool { get }
}

/// A bounded connector can also be exercised outside a bridge session (for validation and focused
/// tests). There is no external cancellation in that case, but the same monotonic deadline remains
/// mandatory and the connector remains the sole descriptor owner until it returns success.
final class UncancelledHostSocketConnectContext: BoundedHostSocketConnectContext,
    @unchecked Sendable
{
    func claimPendingDescriptor(_ descriptor: Int32) -> Bool { true }
    func releasePendingDescriptor(_ descriptor: Int32) {}
    var shouldCancelConnect: Bool { false }
}

/// One bounded lifecycle for services initiated by an untrusted guest vsock request.
///
/// Registrations are published all-or-nothing after a one-shot attach reservation. Listener
/// callbacks hold this object weakly; the lifecycle owns only idempotent unregister closures and
/// admitted sessions, so neither VirtioVsock nor a registration token can retain the bridge.
final class BoundedGuestVsockServiceLifecycle: @unchecked Sendable {
    private static let maximumStopWait: TimeInterval = 5

    private let lock = NSLock()
    private let attachmentCompletion = DispatchGroup()
    private let sessionCompletion = DispatchGroup()
    private let endpointLabel: String
    private let log: @Sendable (String) -> Void
    private var attachmentReserved = false
    private var attachmentCompleted = false
    private var terminal = false
    private var unregisterActions = [@Sendable () -> Void]()
    private var sessionReservations = Set<UUID>()
    private var sessions = [UUID: any BoundedGuestVsockSession]()
    private var admissionSnapshotProvider:
        (@Sendable () -> VirtioVsockServiceAdmissionSnapshot?)?

    init(
        endpointLabel: String,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.endpointLabel = endpointLabel
        self.log = log
    }

    func beginAttachment(to vsock: VirtioVsock) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal,
              !attachmentReserved,
              !attachmentCompleted,
              unregisterActions.isEmpty else {
            throw VMError.invalidConfiguration(
                "\(endpointLabel) is already attached, attaching, or stopped"
            )
        }
        admissionSnapshotProvider = { [weak vsock] in
            vsock?.serviceAdmissionSnapshot
        }
        attachmentReserved = true
        attachmentCompletion.enter()
    }

    /// Commits already-created listener registrations. Returns false only when a concurrent stop
    /// won; in that case every registration is closed before attachment completion is published.
    func commitAttachment(
        unregister: [@Sendable () -> Void]
    ) -> Bool {
        lock.lock()
        guard attachmentReserved, unregisterActions.isEmpty else {
            let shouldLeave = attachmentReserved
            attachmentReserved = false
            lock.unlock()
            for action in unregister { action() }
            if shouldLeave { attachmentCompletion.leave() }
            return false
        }
        attachmentReserved = false
        if terminal {
            lock.unlock()
            for action in unregister { action() }
            attachmentCompletion.leave()
            return false
        }
        attachmentCompleted = true
        unregisterActions = unregister
        lock.unlock()
        attachmentCompletion.leave()
        return true
    }

    func cancelAttachment(unregister: [@Sendable () -> Void]) {
        for action in unregister { action() }
        let shouldLeave: Bool
        lock.lock()
        shouldLeave = attachmentReserved
        attachmentReserved = false
        lock.unlock()
        if shouldLeave { attachmentCompletion.leave() }
    }

    func admit(
        _ connection: VsockConnection,
        makeSession: (
            _ connection: VsockConnection,
            _ completion: @escaping @Sendable () -> Void
        ) -> any BoundedGuestVsockSession
    ) {
        guard let token = reserveSession() else {
            connection.close()
            return
        }
        let session = makeSession(connection) { [self] in
            finishSession(token: token)
        }
        let admitted = publishSession(session, token: token)
        if admitted,
           let ownedConnection = connection as? ServiceOwnedVsockConnection,
           !ownedConnection.replaceServiceStopAction({ session.requestStop() }) {
            // Reset/quiesce won after transport admission but before the service owner published.
            session.requestStop()
        } else if !admitted {
            session.requestStop()
        }
        Thread.detachNewThread { session.run() }
    }

    func stop(timeout: TimeInterval = 1) {
        let boundedTimeout = timeout.isFinite
            ? min(max(0, timeout), Self.maximumStopWait)
            : 1
        let registrations: [@Sendable () -> Void]
        let activeSessions: [any BoundedGuestVsockSession]
        lock.lock()
        terminal = true
        registrations = unregisterActions
        unregisterActions.removeAll()
        activeSessions = Array(sessions.values)
        lock.unlock()

        // Unregister first so no new callback can start after the session snapshot. A callback
        // already in flight sees terminal admission and closes its connection exactly once.
        for unregister in registrations { unregister() }
        for session in activeSessions { session.requestStop() }

        let deadline = DispatchTime.now() + boundedTimeout
        let attachmentFinished = attachmentCompletion.wait(timeout: deadline) == .success
        let sessionsFinished = sessionCompletion.wait(timeout: deadline) == .success
        if !attachmentFinished || !sessionsFinished {
            log(
                "\(endpointLabel) teardown did not drain within \(boundedTimeout) seconds"
            )
        }
    }

    var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionReservations.count + sessions.count
    }

    var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot? {
        lock.lock()
        let provider = admissionSnapshotProvider
        lock.unlock()
        guard let provider else { return nil }
        return provider()
    }

    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    deinit {
        stop()
    }

    private func reserveSession() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return nil }
        let token = UUID()
        sessionReservations.insert(token)
        sessionCompletion.enter()
        return token
    }

    private func publishSession(
        _ session: any BoundedGuestVsockSession,
        token: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionReservations.remove(token) != nil else { return false }
        sessions[token] = session
        return !terminal
    }

    private func finishSession(token: UUID) {
        let owned: Bool
        lock.lock()
        owned = sessions.removeValue(forKey: token) != nil
        lock.unlock()
        if owned { sessionCompletion.leave() }
    }
}

/// Connects one admitted guest stream to a host socket, then delegates the established stream to
/// RelaySession. The connector borrows this object to publish its pending descriptor before any
/// nonblocking connect/poll; stop may shutdown it, but the connector remains its sole close owner
/// until ownership transfers to RelaySession.
final class GuestVsockHostSocketRelaySession: BoundedGuestVsockSession,
    BoundedHostSocketConnectContext,
    @unchecked Sendable
{
    typealias Connector = @Sendable (GuestVsockHostSocketRelaySession) -> Int32?

    private let lock = NSLock()
    private let guestConnection: VsockConnection
    private let connector: Connector
    private var completion: (@Sendable () -> Void)?
    private var pendingDescriptor: Int32?
    private var relay: VsockUnixRelay.RelaySession?
    private var started = false
    private var stopRequested = false
    private var finished = false

    init(
        connection: VsockConnection,
        connector: @escaping Connector,
        completion: @escaping @Sendable () -> Void
    ) {
        self.guestConnection = connection
        self.connector = connector
        self.completion = completion
    }

    func run() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        let shouldConnect = !stopRequested
        lock.unlock()
        guard shouldConnect, let descriptor = connector(self) else {
            finish()
            return
        }

        let relay = VsockUnixRelay.RelaySession(
            client: descriptor,
            connection: guestConnection
        )
        lock.lock()
        guard pendingDescriptor == descriptor else {
            lock.unlock()
            relay.discardBeforeStart()
            finish()
            return
        }
        pendingDescriptor = nil
        self.relay = relay
        let shouldRelay = !stopRequested
        lock.unlock()

        if shouldRelay {
            relay.run()
        } else {
            relay.discardBeforeStart()
        }
        finish()
    }

    func requestStop() {
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        stopRequested = true
        if let pendingDescriptor {
            // Connector remains close owner. The short poll quantum below provides the bounded wake
            // even on Darwin sockets for which shutdown-before-connect returns ENOTCONN.
            _ = shutdown(pendingDescriptor, SHUT_RDWR)
        }
        relay?.requestStop()
        guestConnection.close()
        lock.unlock()
    }

    func claimPendingDescriptor(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopRequested, pendingDescriptor == nil, relay == nil else { return false }
        pendingDescriptor = descriptor
        return true
    }

    func releasePendingDescriptor(_ descriptor: Int32) {
        lock.lock()
        if pendingDescriptor == descriptor { pendingDescriptor = nil }
        lock.unlock()
    }

    var shouldCancelConnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func finish() {
        let orphanedDescriptor: Int32?
        let callback: (@Sendable () -> Void)?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        orphanedDescriptor = pendingDescriptor
        pendingDescriptor = nil
        relay = nil
        callback = completion
        completion = nil
        guestConnection.close()
        if let orphanedDescriptor { close(orphanedDescriptor) }
        lock.unlock()
        callback?()
    }
}

enum BoundedHostSocketConnector {
    private static let connectPollQuantumMilliseconds: Int32 = 50
    private static let maximumConnectTimeout: TimeInterval = 30

    static func connect(
        domain: Int32,
        timeout: TimeInterval,
        context: any BoundedHostSocketConnectContext,
        initiate: (Int32) -> Int32,
        verify: (Int32) -> Bool = { _ in true }
    ) -> Int32? {
        let descriptor = socket(domain, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let originalFlags = fcntl(descriptor, F_GETFL)
        var noSigpipe: Int32 = 1
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(
                  descriptor,
                  SOL_SOCKET,
                  SO_NOSIGPIPE,
                  &noSigpipe,
                  socklen_t(MemoryLayout<Int32>.size)
              ) == 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0,
              context.claimPendingDescriptor(descriptor) else {
            close(descriptor)
            return nil
        }

        var transferred = false
        defer {
            if !transferred {
                context.releasePendingDescriptor(descriptor)
                close(descriptor)
            }
        }

        let connected = initiate(descriptor)
        if connected != 0 {
            guard errno == EINPROGRESS else { return nil }
            let boundedTimeout = timeout.isFinite
                ? min(max(0, timeout), maximumConnectTimeout)
                : 0
            let deadline = ProcessInfo.processInfo.systemUptime + boundedTimeout
            while true {
                guard !context.shouldCancelConnect else { return nil }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                let milliseconds = min(
                    connectPollQuantumMilliseconds,
                    max(1, Int32(ceil(remaining * 1_000)))
                )
                var readiness = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let result = poll(&readiness, 1, milliseconds)
                if result == 0 { continue }
                if result < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if readiness.revents & Int16(POLLNVAL) != 0 { return nil }
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                ) == 0, socketError == 0 else {
                    return nil
                }
                break
            }
        }
        guard !context.shouldCancelConnect,
              verify(descriptor),
              fcntl(descriptor, F_SETFL, originalFlags) == 0 else {
            return nil
        }
        transferred = true
        return descriptor
    }
}
