import Darwin
import Foundation

protocol DoryTCPUpstreamOwnership: AnyObject, Sendable {
    var isActive: Bool { get }
    func adoptUpstream(_ descriptor: Int32) -> Bool
    /// Only the nonblocking connect syscall crosses this admission gate, never its poll wait.
    func performConnect(_ operation: () -> Int32) -> Int32?
}

/// Cancellation shuts sockets down immediately, but only the last worker closes them. Closing
/// from a stop callback would let a still-unwinding read/write act on a reused descriptor number.
final class DoryTCPConnection: DoryTCPUpstreamOwnership, @unchecked Sendable {
    let id = UUID()
    let client: Int32
    private let lock = NSLock()
    private let onClose: @Sendable (UUID) -> Void
    private var upstream: Int32?
    private var cancelled = false
    private var closed = false
    private var workers = 1 // The accepted connection's header/connect worker.

    init(client: Int32, onClose: @escaping @Sendable (UUID) -> Void) {
        self.client = client
        self.onClose = onClose
        DoryTCP.configureNoSignal(client)
    }

    var isActive: Bool { lock.withLock { !cancelled && !closed } }

    func adoptUpstream(_ descriptor: Int32) -> Bool {
        lock.withLock {
            guard !cancelled, !closed, upstream == nil else { return false }
            DoryTCP.configureNoSignal(descriptor)
            upstream = descriptor
            return true
        }
    }

    func beginRelay() -> (client: Int32, upstream: Int32)? {
        lock.withLock {
            guard !cancelled, !closed, workers == 1, let upstream else { return nil }
            workers += 2
            return (client, upstream)
        }
    }

    func performConnect(_ operation: () -> Int32) -> Int32? {
        lock.withLock {
            guard !cancelled, !closed, upstream != nil else { return nil }
            return operation()
        }
    }

    func cancel() {
        lock.withLock {
            guard !closed, !cancelled else { return }
            cancelled = true
            shutdown(client, SHUT_RDWR)
            if let upstream { shutdown(upstream, SHUT_RDWR) }
        }
    }

    func clientPumpFinished() {
        lock.withLock {
            if !closed, let upstream { shutdown(upstream, SHUT_WR) }
        }
        workerFinished()
    }

    func upstreamPumpFinished() {
        cancel()
        workerFinished()
    }

    func workerFinished() {
        let finished = lock.withLock {
            precondition(workers > 0)
            workers -= 1
            guard workers == 0, !closed else { return false }
            closed = true
            shutdown(client, SHUT_RDWR)
            close(client)
            if let upstream {
                shutdown(upstream, SHUT_RDWR)
                close(upstream)
            }
            return true
        }
        if finished { onClose(id) }
    }
}

/// The accept worker owns the listener descriptor until it exits. Stop only shuts it down, so
/// rapid stop/start cannot reuse its number underneath an old accept call.
final class DoryTCPListener: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    var isActive: Bool { lock.withLock { !cancelled && !closed } }

    func cancel() {
        lock.withLock {
            guard !closed, !cancelled else { return }
            cancelled = true
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    func acceptWorkerFinished() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            close(descriptor)
        }
    }

    deinit { acceptWorkerFinished() }
}
