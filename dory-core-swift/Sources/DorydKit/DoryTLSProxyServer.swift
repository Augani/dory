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
    private let identityStorage: DoryTLSIdentityStorage
    private let router: DomainRouter
    private let connectionBudget: DoryConnectionBudget
    private let lifecycleLock = NSRecursiveLock()
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var listener: NWListener?
    private var listenerState: TLSListenerState?
    private var listenerGeneration: UUID?
    private var activeConnections: [UUID: ActiveTLSConnection] = [:]
    private var activePort: UInt16 = 0
    private let queue = DispatchQueue(label: "dev.dory.doryd.tls-proxy")
    private let queueKey = DispatchSpecificKey<Bool>()

    public init(
        port: UInt16,
        p12Path: String,
        password: String,
        router: DomainRouter = DomainRouter(),
        routes: [DomainRoute] = [],
        maximumConnections: Int = 256
    ) throws {
        guard let identityStorage = Self.loadIdentity(p12Path: p12Path, password: password) else {
            throw DoryTLSProxyServerError.identity(p12Path)
        }
        self.requestedPort = port
        self.identityStorage = identityStorage
        self.router = router
        self.routes = routes
        self.connectionBudget = DoryConnectionBudget(limit: maximumConnections)
        queue.setSpecific(key: queueKey, value: true)
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
        var revoked: [ActiveTLSConnection] = []
        for (identifier, var active) in activeConnections {
            guard !active.revoked, let hostname = active.hostname, let route = active.route,
                  routeLocked(for: hostname) != route else { continue }
            active.revoked = true
            activeConnections[identifier] = active
            revoked.append(active)
        }
        lock.unlock()
        for active in revoked { active.upstream?.cancel(); active.connection.cancel() }
    }

    public func currentRoutes() -> [DomainRoute] {
        lock.lock()
        defer { lock.unlock() }
        return routes
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identityStorage.identity) else {
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
        let generation = UUID()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let self, let listener {
                    self.lock.lock()
                    if self.listener === listener, self.listenerGeneration == generation {
                        self.activePort = listener.port?.rawValue ?? self.requestedPort
                    }
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
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.accept(connection, listener: listener, generation: generation)
        }

        lock.lock()
        self.listener = listener
        self.listenerState = startState
        self.listenerGeneration = generation
        self.activePort = requestedPort
        lock.unlock()
        listener.start(queue: queue)

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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        let current = listener
        let currentState = listenerState
        let connections = Array(activeConnections.values)
        listener = nil
        listenerState = nil
        listenerGeneration = nil
        activeConnections.removeAll()
        activePort = 0
        lock.unlock()
        current?.cancel()
        for active in connections {
            active.upstream?.cancel()
            active.connection.cancel()
        }
        if current != nil, DispatchQueue.getSpecific(key: queueKey) != true {
            _ = currentState?.waitUntilCancelled()
        }
    }

    private func accept(_ client: NWConnection, listener: NWListener, generation: UUID) {
        guard let lease = connectionBudget.tryAcquire() else {
            client.cancel()
            return
        }
        let identifier = UUID()
        lock.lock()
        guard self.listener === listener, listenerGeneration == generation else {
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
        client.stateUpdateHandler = { [weak self, lease] state in
            withExtendedLifetime(lease) {
                switch state {
                case .failed, .cancelled:
                    self?.finishConnection(identifier)
                default:
                    break
                }
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.cancelIfAwaitingHeader(identifier)
        }
        readHead(client, identifier: identifier, lease: lease, buffer: Data())
    }

    private func readHead(_ client: NWConnection, identifier: UUID,
                          lease: DoryConnectionLease, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            defer { withExtendedLifetime(lease) {} }
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
                self.route(client, identifier: identifier, head: accumulated)
                return
            }
            if isComplete || error != nil || accumulated.count > 65_536 {
                client.cancel()
                return
            }
            self.readHead(client, identifier: identifier, lease: lease, buffer: accumulated)
        }
    }

    private func markHeaderReceived(_ identifier: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeConnections[identifier], !active.revoked else { return false }
        active.awaitingHeader = false
        activeConnections[identifier] = active
        return true
    }

    private func cancelIfAwaitingHeader(_ identifier: UUID) {
        lock.lock()
        let connection = activeConnections[identifier].flatMap {
            $0.awaitingHeader ? $0.connection : nil
        }
        lock.unlock()
        connection?.cancel()
    }

    private func finishConnection(_ identifier: UUID) {
        lock.lock()
        let active = activeConnections.removeValue(forKey: identifier)
        lock.unlock()
        // A relay's worker-held owner also retains the lease until both pumps have unwound.
        active?.upstream?.cancel()
    }

    private func route(_ client: NWConnection, identifier: UUID, head: Data) {
        let selected: (DomainRoute, DoryConnectionLease)? = lock.withLock {
            guard var active = activeConnections[identifier], !active.revoked,
                  let host = DoryHTTPProxyServer.hostHeader(head),
                  let route = routeLocked(for: host) else { return nil }
            active.hostname = DomainRouter.normalize(host)
            active.route = route
            activeConnections[identifier] = active
            return (route, active.lease)
        }
        guard let (route, lease) = selected else {
            writeBadGateway(client, body: "Dory: no backend for that domain\n")
            return
        }
        // Connect/write must not block the serial Network.framework cancellation queue. This
        // worker retains its budget even if stop removes the accepted connection meanwhile.
        Thread.detachNewThread { [weak self, client, lease] in
            guard let self else { client.cancel(); return }
            self.connectAndRelay(client, identifier: identifier, route: route, head: head, lease: lease)
        }
    }

    private func connectAndRelay(_ client: NWConnection, identifier: UUID,
                                 route: DomainRoute, head: Data, lease: DoryConnectionLease) {
        guard lock.withLock({
            activeConnections[identifier]?.lease === lease && activeConnections[identifier]?.revoked == false
        }) else { return }
        let request = route.pathPrefix.isEmpty ? head : DoryHTTPProxyServer.rewriteRequest(head, pathPrefix: route.pathPrefix)
        let upstream = TLSUpstreamOwner(lease: lease)
        let admitted = lock.withLock {
            guard var active = activeConnections[identifier], !active.revoked, active.lease === lease,
                  let hostname = active.hostname, routeLocked(for: hostname) == route else { return false }
            active.upstream = upstream
            activeConnections[identifier] = active
            return true
        }
        guard admitted else { upstream.closeNow(); client.cancel(); return }
        guard let upstreamFD = DoryTCP.connect(host: route.address, port: route.port,
                                               connection: upstream) else {
            upstream.closeNow()
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        DoryTCP.configureRelayTimeout(upstreamFD)
        guard upstream.isActive, (try? DoryTCP.writeAll(upstream.raw, request)) != nil else {
            upstream.closeNow()
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        pumpUpstreamToClient(upstream, client)
        pumpClientToUpstream(client, upstream)
    }

    private func routeLocked(for host: String) -> DomainRoute? {
        let normalized = DomainRouter.normalize(host)
        return routes.compactMap { route -> (specificity: Int, route: DomainRoute)? in
            let hostname = DomainRouter.normalize(route.hostname)
            guard let specificity = DomainRouter.matchSpecificity(pattern: hostname, hostname: normalized),
                  router.owns(hostname)
                    || DoryHTTPProxyServer.isLoopbackHost(hostname)
                    || DomainRouter.isValidHostnamePattern(hostname),
                  IPv4Address(route.address) != nil else {
                return nil
            }
            return (specificity, route)
        }.max { $0.specificity < $1.specificity }?.route
    }

    private func writeBadGateway(_ client: NWConnection, body: String) {
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    private func pumpUpstreamToClient(_ upstream: TLSUpstreamOwner, _ client: NWConnection) {
        Thread.detachNewThread {
            let fd = upstream.raw
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while upstream.isActive {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32 * 1024) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                guard upstream.isActive else { break }
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

    private func pumpClientToUpstream(_ client: NWConnection, _ upstream: TLSUpstreamOwner) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard upstream.isActive else { upstream.release(); return }
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

    static func loadIdentity(
        p12Path: String,
        password: String,
        forceTemporaryKeychain: Bool = false
    ) -> DoryTLSIdentityStorage? {
        guard let data = FileManager.default.contents(atPath: p12Path) else { return nil }
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
        ]
        var temporaryKeychain: SecKeychain?
        var temporaryKeychainPath: String?
        if #available(macOS 15.0, *), !forceTemporaryKeychain {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            let path = NSTemporaryDirectory() + "dory-tls-\(getpid())-\(UUID().uuidString).keychain-db"
            let keychainPassword = UUID().uuidString
            var keychain: SecKeychain?
            let status = keychainPassword.utf8CString.withUnsafeBytes { bytes in
                SecKeychainCreate(
                    path,
                    UInt32(max(0, bytes.count - 1)),
                    bytes.baseAddress,
                    false,
                    nil,
                    &keychain
                )
            }
            guard status == errSecSuccess, let keychain else {
                if let keychain {
                    SecKeychainDelete(keychain)
                }
                try? FileManager.default.removeItem(atPath: path)
                return nil
            }
            temporaryKeychain = keychain
            temporaryKeychainPath = path
            options[kSecImportExportKeychain as String] = keychain
        }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
            if let temporaryKeychain {
                SecKeychainDelete(temporaryKeychain)
            }
            if let temporaryKeychainPath {
                try? FileManager.default.removeItem(atPath: temporaryKeychainPath)
            }
            return nil
        }
        // Safe: the CFTypeID guard above proves this is a SecIdentity.
        return DoryTLSIdentityStorage(
            identity: identity as! SecIdentity,
            temporaryKeychain: temporaryKeychain,
            temporaryKeychainPath: temporaryKeychainPath
        )
    }

    deinit {
        stop()
    }
}

final class DoryTLSIdentityStorage: @unchecked Sendable {
    let identity: SecIdentity
    let temporaryKeychainPath: String?
    private let temporaryKeychain: SecKeychain?

    init(
        identity: SecIdentity,
        temporaryKeychain: SecKeychain?,
        temporaryKeychainPath: String?
    ) {
        self.identity = identity
        self.temporaryKeychain = temporaryKeychain
        self.temporaryKeychainPath = temporaryKeychainPath
    }

    deinit {
        if let temporaryKeychain {
            SecKeychainDelete(temporaryKeychain)
        }
        if let temporaryKeychainPath {
            try? FileManager.default.removeItem(atPath: temporaryKeychainPath)
        }
    }
}

private struct ActiveTLSConnection {
    var connection: NWConnection
    var lease: DoryConnectionLease
    var awaitingHeader: Bool
    var revoked = false
    var hostname: String?
    var route: DomainRoute?
    var upstream: TLSUpstreamOwner?
}

/// Stop shuts down immediately; only joined pump ownership closes the descriptor. The strong
/// lease remains charged while a header/connect worker or either relay callback can still run.
private final class TLSUpstreamOwner: DoryTCPUpstreamOwnership, @unchecked Sendable {
    private var descriptor: Int32?
    private let lease: DoryConnectionLease
    private let lock = NSLock()
    private var refs = 2
    private var cancelled = false
    private var closed = false

    init(lease: DoryConnectionLease) { self.lease = lease }
    var raw: Int32 { lock.withLock { descriptor! } }
    var isActive: Bool { lock.withLock { !cancelled && !closed } }

    func adoptUpstream(_ descriptor: Int32) -> Bool {
        lock.withLock {
            guard !cancelled, !closed, self.descriptor == nil else { return false }
            self.descriptor = descriptor
            return true
        }
    }

    func performConnect(_ operation: () -> Int32) -> Int32? {
        lock.withLock {
            guard !cancelled, !closed, descriptor != nil else { return nil }
            return operation()
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled, !closed else { return }
            cancelled = true
            if let descriptor { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func release() {
        lock.withLock {
            guard !closed else { return }
            precondition(refs > 0)
            refs -= 1
            if refs == 0 { closeLocked() }
        }
    }

    // Used only before pump handoff (or by deinit once no worker references remain).
    func closeNow() { lock.withLock { if !closed { closeLocked() } } }
    private func closeLocked() {
        closed = true
        if let descriptor {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }
    deinit { closeNow() }
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
