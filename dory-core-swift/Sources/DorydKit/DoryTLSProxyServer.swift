import Darwin
import Foundation
import Network
import Security

public enum DoryTLSProxyServerError: Error, Sendable, CustomStringConvertible {
    case identity(String)
    case invalidPort(UInt16)

    public var description: String {
        switch self {
        case let .identity(path):
            return "could not load TLS identity from \(path)"
        case let .invalidPort(port):
            return "invalid TLS proxy port: \(port)"
        }
    }
}

public final class DoryTLSProxyServer: @unchecked Sendable {
    private let requestedPort: UInt16
    private let identity: SecIdentity
    private let router: DomainRouter
    private let connectionBudget: DoryConnectionBudget
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var listener: NWListener?
    private var listenerState: TLSListenerState?
    private var activeConnections: [ObjectIdentifier: ActiveTLSConnection] = [:]
    private var activePort: UInt16 = 0
    private let queue = DispatchQueue(label: "dev.dory.doryd.tls-proxy")

    public init(
        port: UInt16,
        p12Path: String,
        password: String,
        router: DomainRouter = DomainRouter(),
        routes: [DomainRoute] = [],
        maximumConnections: Int = 256
    ) throws {
        guard let identity = Self.loadIdentity(p12Path: p12Path, password: password) else {
            throw DoryTLSProxyServerError.identity(p12Path)
        }
        self.requestedPort = port
        self.identity = identity
        self.router = router
        self.routes = routes
        self.connectionBudget = DoryConnectionBudget(limit: maximumConnections)
    }

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return activePort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    var activeConnectionCount: Int {
        connectionBudget.activeCount
    }

    public func updateRoutes(_ routes: [DomainRoute]) {
        lock.lock()
        self.routes = routes
        lock.unlock()
    }

    public func currentRoutes() -> [DomainRoute] {
        lock.lock()
        defer { lock.unlock() }
        return routes
    }

    public func start() throws {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw DoryTLSProxyServerError.identity("SecIdentity")
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw DoryTLSProxyServerError.invalidPort(requestedPort)
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        let ready = DispatchSemaphore(value: 0)
        let startState = TLSListenerState(ready: ready)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let self, let listener {
                    self.lock.lock()
                    self.activePort = listener.port?.rawValue ?? self.requestedPort
                    self.lock.unlock()
                }
                startState.signal()
            case let .failed(error):
                startState.signal(error: error)
            case .cancelled:
                startState.signalCancelled()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        self.listenerState = startState
        self.activePort = requestedPort
        lock.unlock()

        if ready.wait(timeout: .now() + 5) == .timedOut {
            stop()
            throw DoryTLSProxyServerError.invalidPort(requestedPort)
        }
        if let startError = startState.error {
            stop()
            throw startError
        }
    }

    public func stop() {
        lock.lock()
        let current = listener
        let currentState = listenerState
        let connections = Array(activeConnections.values)
        listener = nil
        listenerState = nil
        activeConnections.removeAll()
        activePort = 0
        lock.unlock()
        current?.cancel()
        for active in connections {
            active.lease.release()
            active.connection.cancel()
        }
        if current != nil {
            _ = currentState?.waitUntilCancelled()
        }
    }

    private func accept(_ client: NWConnection) {
        guard let lease = connectionBudget.tryAcquire() else {
            client.cancel()
            return
        }
        let identifier = ObjectIdentifier(client)
        lock.lock()
        guard listener != nil else {
            lock.unlock()
            lease.release()
            client.cancel()
            return
        }
        activeConnections[identifier] = ActiveTLSConnection(
            connection: client,
            lease: lease,
            awaitingHeader: true
        )
        lock.unlock()
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finishConnection(identifier)
            default:
                break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.cancelIfAwaitingHeader(identifier)
        }
        readHead(client, identifier: identifier, buffer: Data())
    }

    private func readHead(_ client: NWConnection, identifier: ObjectIdentifier, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                client.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if accumulated.range(of: Data([13, 10, 13, 10])) != nil {
                guard self.markHeaderReceived(identifier) else {
                    client.cancel()
                    return
                }
                self.route(client, head: accumulated)
                return
            }
            if isComplete || error != nil || accumulated.count > 65_536 {
                client.cancel()
                return
            }
            self.readHead(client, identifier: identifier, buffer: accumulated)
        }
    }

    private func markHeaderReceived(_ identifier: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeConnections[identifier] else { return false }
        active.awaitingHeader = false
        activeConnections[identifier] = active
        return true
    }

    private func cancelIfAwaitingHeader(_ identifier: ObjectIdentifier) {
        lock.lock()
        let connection = activeConnections[identifier].flatMap {
            $0.awaitingHeader ? $0.connection : nil
        }
        lock.unlock()
        connection?.cancel()
    }

    private func finishConnection(_ identifier: ObjectIdentifier) {
        lock.lock()
        let active = activeConnections.removeValue(forKey: identifier)
        lock.unlock()
        active?.lease.release()
    }

    private func route(_ client: NWConnection, head: Data) {
        guard let host = DoryHTTPProxyServer.hostHeader(head), let route = route(for: host) else {
            writeBadGateway(client, body: "Dory: no backend for that domain\n")
            return
        }
        let request = route.pathPrefix.isEmpty ? head : DoryHTTPProxyServer.rewriteRequest(head, pathPrefix: route.pathPrefix)
        guard let upstreamFD = DoryTCP.connect(host: route.address, port: route.port) else {
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        DoryTCP.configureRelayTimeout(upstreamFD)
        // Own the fd before the first write so a failed write cannot leak it.
        let upstream = FDOwner(upstreamFD)
        guard (try? DoryTCP.writeAll(upstream.raw, request)) != nil else {
            upstream.closeNow()
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        pumpUpstreamToClient(upstream, client)
        pumpClientToUpstream(client, upstream)
    }

    private func route(for host: String) -> DomainRoute? {
        let normalized = DomainRouter.normalize(host)
        lock.lock()
        let currentRoutes = routes
        lock.unlock()
        return currentRoutes.first { route in
            let hostname = DomainRouter.normalize(route.hostname)
            return hostname == normalized
                && (router.owns(hostname) || DoryHTTPProxyServer.isLoopbackHost(hostname))
                && IPv4Address(route.address) != nil
        }
    }

    private func writeBadGateway(_ client: NWConnection, body: String) {
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    private func pumpUpstreamToClient(_ upstream: FDOwner, _ client: NWConnection) {
        Thread.detachNewThread {
            let fd = upstream.raw
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32 * 1024) }
                if count <= 0 { break }
                let chunk = Data(buffer[0..<count])
                let sent = DispatchSemaphore(value: 0)
                client.send(content: chunk, completion: .contentProcessed { _ in
                    sent.signal()
                })
                if sent.wait(timeout: .now() + 300) == .timedOut {
                    client.cancel()
                    break
                }
            }
            client.send(content: nil, completion: .contentProcessed { _ in
                client.cancel()
            })
            upstream.release()
        }
    }

    private func pumpClientToUpstream(_ client: NWConnection, _ upstream: FDOwner) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                _ = try? DoryTCP.writeAll(upstream.raw, data)
            }
            guard let self, !(isComplete || error != nil) else {
                shutdown(upstream.raw, SHUT_WR)
                upstream.release()
                return
            }
            self.pumpClientToUpstream(client, upstream)
        }
    }

    private static func loadIdentity(p12Path: String, password: String) -> SecIdentity? {
        guard let data = FileManager.default.contents(atPath: p12Path) else { return nil }
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
            return nil
        }
        // Safe: the CFTypeID guard above proves this is a SecIdentity.
        return (identity as! SecIdentity)
    }

    private final class FDOwner: @unchecked Sendable {
        let raw: Int32
        private let lock = NSLock()
        private var refs = 2
        private var closed = false

        init(_ raw: Int32) {
            self.raw = raw
        }

        func release() {
            lock.lock()
            refs -= 1
            let shouldClose = refs <= 0 && !closed
            if shouldClose {
                closed = true
            }
            lock.unlock()
            if shouldClose {
                shutdown(raw, SHUT_RDWR)
                close(raw)
            }
        }

        func closeNow() {
            lock.lock()
            let shouldClose = !closed
            closed = true
            refs = 0
            lock.unlock()
            if shouldClose {
                shutdown(raw, SHUT_RDWR)
                close(raw)
            }
        }
    }

    deinit {
        stop()
    }
}

private struct ActiveTLSConnection {
    var connection: NWConnection
    var lease: DoryConnectionLease
    var awaitingHeader: Bool
}

private final class TLSListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private let ready: DispatchSemaphore
    private let cancelled = DispatchSemaphore(value: 0)
    private var didSignal = false
    private var didCancel = false
    private var storedError: Error?

    init(ready: DispatchSemaphore) {
        self.ready = ready
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func signal(error: Error? = nil) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        let shouldSignal = !didSignal
        if shouldSignal {
            didSignal = true
        }
        lock.unlock()
        if shouldSignal {
            ready.signal()
        }
    }

    func signalCancelled() {
        lock.lock()
        let shouldSignal = !didCancel
        if shouldSignal {
            didCancel = true
        }
        lock.unlock()
        if shouldSignal {
            cancelled.signal()
        }
    }

    func waitUntilCancelled() -> Bool {
        lock.lock()
        let alreadyCancelled = didCancel
        lock.unlock()
        if alreadyCancelled { return true }
        return cancelled.wait(timeout: .now() + 5) == .success
    }
}
