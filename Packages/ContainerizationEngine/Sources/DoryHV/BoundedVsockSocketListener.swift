import Darwin
import Foundation

/// One owned Unix listener with bounded, cancel-safe unix-to-vsock sessions.
///
/// Attachment is one-shot and reserved before any pathname mutation. Every accepted descriptor
/// consumes admission capacity before its optional protocol preparation starts; preparation and
/// established relay use the same `RelaySession`, so stop can wake either phase without transferring
/// descriptor-close authority between threads.
final class BoundedVsockSocketListener: @unchecked Sendable {
    private static let maximumStopWait: TimeInterval = 5

    private let socketPath: String
    private let mode: mode_t?
    private let endpointLabel: String
    private let log: @Sendable (String) -> Void
    private let lifetime: Lifetime
    private let admissionLock = NSLock()
    private var admissionSnapshotProvider:
        (@Sendable () -> VirtioVsockServiceAdmissionSnapshot?)?

    init(
        socketPath: String,
        mode: mode_t?,
        endpointLabel: String,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.socketPath = socketPath
        self.mode = mode
        self.endpointLabel = endpointLabel
        self.log = log
        self.lifetime = Lifetime()
    }

    func attach(
        to vsock: VirtioVsock,
        service: VirtioVsockService,
        prepareConnection: @escaping @Sendable (Int32) -> VsockConnection?
    ) throws {
        // Reserve before makeOwnedListener's stale-path unlink. Repeat/concurrent/post-stop attach
        // therefore fails without mutating a currently published endpoint.
        guard lifetime.reserveAttachment() else {
            throw VMError.invalidConfiguration(
                "\(endpointLabel) listener is already attached, attaching, or stopped"
            )
        }
        admissionLock.lock()
        admissionSnapshotProvider = { [weak vsock] in
            vsock?.serviceAdmissionSnapshot
        }
        admissionLock.unlock()
        var reservationActive = true
        do {
            let listener = try VsockUnixRelay.makeOwnedListener(
                socketPath: socketPath,
                mode: mode
            )
            guard VsockUnixRelay.makeNonBlocking(listener.descriptor) else {
                let code = errno
                VsockUnixRelay.retireOwnedListener(listener, socketPath: socketPath)
                throw UnixSocketListenerError.systemCall(
                    operation: "make nonblocking",
                    path: socketPath,
                    code: code
                )
            }
            let publication = lifetime.publishListener(listener)
            reservationActive = false
            switch publication {
            case .serving:
                break
            case .stopped:
                lifetime.finishListener(listener, socketPath: socketPath)
                throw VMError.invalidConfiguration(
                    "\(endpointLabel) listener was stopped while attaching"
                )
            case .rejected:
                VsockUnixRelay.retireOwnedListener(listener, socketPath: socketPath)
                throw VMError.invalidConfiguration(
                    "\(endpointLabel) listener publication was rejected"
                )
            }

            let path = socketPath
            let label = endpointLabel
            let logger = log
            let state = lifetime
            Thread.detachNewThread {
                defer { state.finishListener(listener, socketPath: path) }
                while true {
                    guard !state.isStopping else { break }
                    var readiness = pollfd(
                        fd: listener.descriptor,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    let pollResult = poll(&readiness, 1, 100)
                    if pollResult == 0 { continue }
                    if pollResult < 0 {
                        if errno == EINTR { continue }
                        if !state.isStopping {
                            logger("\(label) listener poll failed on \(path): errno \(errno)")
                        }
                        break
                    }
                    guard !state.isStopping else { break }
                    if readiness.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 {
                        if !state.isStopping {
                            logger("\(label) listener became unavailable on \(path)")
                        }
                        break
                    }
                    guard readiness.revents & Int16(POLLIN) != 0 else { continue }

                    let client = accept(listener.descriptor, nil, nil)
                    guard client >= 0 else {
                        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                            continue
                        }
                        if !state.isStopping {
                            logger("\(label) accept failed on \(path): errno \(errno)")
                        }
                        break
                    }
                    guard !state.isStopping else {
                        close(client)
                        break
                    }
                    guard Self.configureAcceptedClient(client) else {
                        close(client)
                        continue
                    }
                    guard let token = state.reserveSession() else {
                        close(client)
                        continue
                    }
                    let serviceReservation: VirtioVsockServiceReservation
                    do {
                        serviceReservation = try vsock.reserveServiceSession(service)
                    } catch {
                        state.cancelSessionReservation(token: token)
                        close(client)
                        logger("\(label) rejected \(service.rawValue) session: \(error)")
                        continue
                    }
                    let session = VsockUnixRelay.RelaySession(
                        client: client,
                        prepareConnection: prepareConnection,
                        completion: { [state] in state.finishSession(token: token) }
                    )
                    guard state.publishSession(session, token: token) else {
                        vsock.cancelServiceSession(serviceReservation)
                        session.discardBeforeStart()
                        continue
                    }
                    guard let serviceLease = vsock.publishServiceSession(
                        serviceReservation,
                        requestStop: { session.requestStop() }
                    ) else {
                        session.discardBeforeStart()
                        continue
                    }
                    guard state.bindServiceLease(serviceLease, token: token) else {
                        serviceLease.close()
                        session.discardBeforeStart()
                        continue
                    }
                    Thread.detachNewThread { session.run() }
                }
            }
        } catch {
            if reservationActive { lifetime.cancelAttachmentReservation() }
            throw error
        }
    }

    func stop(timeout: TimeInterval = 1) {
        let boundedTimeout = timeout.isFinite
            ? min(max(0, timeout), Self.maximumStopWait)
            : 1
        guard lifetime.stop(timeout: boundedTimeout) else {
            log(
                "\(endpointLabel) teardown did not drain within "
                    + "\(boundedTimeout) seconds on \(socketPath)"
            )
            return
        }
    }

    var activeSessionCount: Int { lifetime.activeSessionCount }
    var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot? {
        admissionLock.lock()
        let provider = admissionSnapshotProvider
        admissionLock.unlock()
        guard let provider else { return nil }
        return provider()
    }

    deinit {
        stop()
    }

    private static func configureAcceptedClient(_ descriptor: Int32) -> Bool {
        let statusFlags = fcntl(descriptor, F_GETFL)
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags & ~O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            return false
        }
        var noSigpipe: Int32 = 1
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    private final class Lifetime: @unchecked Sendable {
        enum ListenerPublication {
            case serving
            case stopped
            case rejected
        }

        private let lock = NSLock()
        private let listenerCompletion = DispatchGroup()
        private let sessionCompletion = DispatchGroup()
        private var attachmentReserved = false
        private var listener: VsockUnixRelay.OwnedListener?
        private var terminal = false
        private var sessionReservations = Set<UUID>()
        private struct SessionRecord {
            let relay: VsockUnixRelay.RelaySession
            var serviceLease: VirtioVsockServiceLease?
        }
        private var sessions = [UUID: SessionRecord]()

        var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminal
        }

        var activeSessionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return sessionReservations.count + sessions.count
        }

        func reserveAttachment() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminal, !attachmentReserved, listener == nil else { return false }
            attachmentReserved = true
            listenerCompletion.enter()
            return true
        }

        func cancelAttachmentReservation() {
            let shouldLeave: Bool
            lock.lock()
            shouldLeave = attachmentReserved
            attachmentReserved = false
            lock.unlock()
            if shouldLeave { listenerCompletion.leave() }
        }

        func publishListener(
            _ listener: VsockUnixRelay.OwnedListener
        ) -> ListenerPublication {
            lock.lock()
            guard attachmentReserved, self.listener == nil else {
                let shouldLeave = attachmentReserved
                attachmentReserved = false
                lock.unlock()
                if shouldLeave { listenerCompletion.leave() }
                return .rejected
            }
            attachmentReserved = false
            self.listener = listener
            let publication: ListenerPublication = terminal ? .stopped : .serving
            lock.unlock()
            return publication
        }

        func finishListener(
            _ listener: VsockUnixRelay.OwnedListener,
            socketPath: String
        ) {
            let owned: Bool
            let activeSessions: [VsockUnixRelay.RelaySession]
            lock.lock()
            owned = self.listener?.descriptor == listener.descriptor
                && self.listener?.pathIdentity == listener.pathIdentity
            if owned { self.listener = nil }
            terminal = true
            activeSessions = sessions.values.map(\.relay)
            lock.unlock()
            guard owned else { return }

            // Retire pathname ownership before publishing listener completion. A successor can bind
            // immediately after stop returns without a stale cleanup deleting its socket.
            VsockUnixRelay.retireOwnedListener(listener, socketPath: socketPath)
            for session in activeSessions { session.requestStop() }
            listenerCompletion.leave()
        }

        func reserveSession() -> UUID? {
            lock.lock()
            defer { lock.unlock() }
            guard !terminal else { return nil }
            let token = UUID()
            sessionReservations.insert(token)
            sessionCompletion.enter()
            return token
        }

        func cancelSessionReservation(token: UUID) {
            let owned: Bool
            lock.lock()
            owned = sessionReservations.remove(token) != nil
            lock.unlock()
            if owned { sessionCompletion.leave() }
        }

        func publishSession(
            _ session: VsockUnixRelay.RelaySession,
            token: UUID
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard sessionReservations.remove(token) != nil else { return false }
            sessions[token] = SessionRecord(relay: session, serviceLease: nil)
            return !terminal
        }

        func bindServiceLease(
            _ lease: VirtioVsockServiceLease,
            token: UUID
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var record = sessions[token], record.serviceLease == nil else {
                return false
            }
            record.serviceLease = lease
            sessions[token] = record
            return true
        }

        func finishSession(token: UUID) {
            let record: SessionRecord?
            lock.lock()
            record = sessions.removeValue(forKey: token)
            lock.unlock()
            if let record {
                record.serviceLease?.close()
                sessionCompletion.leave()
            }
        }

        func stop(timeout: TimeInterval) -> Bool {
            let activeSessions: [VsockUnixRelay.RelaySession]
            lock.lock()
            terminal = true
            if let listener {
                // Wake poll without closing; the listener thread remains the sole descriptor closer.
                _ = shutdown(listener.descriptor, SHUT_RDWR)
            }
            activeSessions = sessions.values.map(\.relay)
            lock.unlock()
            for session in activeSessions { session.requestStop() }

            let deadline = DispatchTime.now() + timeout
            let listenerFinished = listenerCompletion.wait(timeout: deadline) == .success
            let sessionsFinished = sessionCompletion.wait(timeout: deadline) == .success
            return listenerFinished && sessionsFinished
        }
    }
}
