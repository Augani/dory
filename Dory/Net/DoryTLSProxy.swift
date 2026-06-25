import Foundation
import Network
import Security
#if canImport(Darwin)
import Darwin
#endif

/// Terminates TLS for Dory's automatic local HTTPS using a `LocalCA`-issued identity, then routes by
/// `Host:` header to the container's loopback backend — so `https://myapp.dory.local` works with no
/// manual certs, mirroring OrbStack. Production binds :443 (a consent-gated privileged bind).
nonisolated final class DoryTLSProxy: @unchecked Sendable {
    private let identity: SecIdentity
    private let resolve: DoryReverseProxy.BackendResolver
    private let queue = DispatchQueue(label: "com.pythonxi.Dory.tls", attributes: .concurrent)
    private var listener: NWListener?

    init?(p12Path: String, password: String, resolve: @escaping DoryReverseProxy.BackendResolver) {
        guard let identity = Self.loadIdentity(p12Path: p12Path, password: password) else { return nil }
        self.identity = identity
        self.resolve = resolve
    }

    func start(port: UInt16) throws {
        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw ProxyError.identity }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        let params = NWParameters(tls: tlsOptions)
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ProxyError.identity }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if HTTPCodec.range(of: HTTPCodec.headerTerminator, in: accumulated) != nil {
                self.route(client, head: accumulated)
                return
            }
            if isComplete || error != nil || accumulated.count > 65_536 { client.cancel(); return }
            self.readHead(client, buffer: accumulated)
        }
    }

    private func route(_ client: NWConnection, head: Data) {
        guard let host = DoryReverseProxy.hostHeader(head), let backend = resolve(host) else {
            let body = "Dory: no container for that domain\n"
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
            return
        }
        // Relay to a raw fd upstream (the same path the plaintext reverse proxy uses), which
        // handles arbitrary response framing — including the chunked/keep-alive responses from the
        // Kubernetes API service proxy that an NWConnection→NWConnection pump dropped.
        guard let upstreamFD = HostPortForwarder.connectTCP(host: backend.host, port: backend.port) else {
            client.cancel(); return
        }
        let outgoing = backend.pathPrefix.isEmpty ? head : DoryReverseProxy.rewriteRequest(head, pathPrefix: backend.pathPrefix)
        _ = try? UnixSocketHTTP.writeAll(upstreamFD, outgoing)
        // Both pumps share the upstream fd. Closing it from one while the other still reads/writes
        // would risk operating on a reused descriptor, so a refcount closes it exactly once — after
        // both directions finish. The client→upstream pump only half-closes (SHUT_WR) at EOF.
        let upstream = FDOwner(upstreamFD)
        pumpUpstreamToClient(upstream, client)
        pumpClientToUpstream(client, upstream)
    }

    private func pumpUpstreamToClient(_ upstream: FDOwner, _ client: NWConnection) {
        Thread.detachNewThread {
            let fd = upstream.raw
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32 * 1024) }
                if count <= 0 { break }
                let chunk = Data(buffer[0..<count])
                let semaphore = DispatchSemaphore(value: 0)
                client.send(content: chunk, completion: .contentProcessed { _ in semaphore.signal() })
                semaphore.wait()
            }
            client.send(content: nil, completion: .contentProcessed { _ in client.cancel() })
            upstream.release()
        }
    }

    private func pumpClientToUpstream(_ client: NWConnection, _ upstream: FDOwner) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { _ = try? UnixSocketHTTP.writeAll(upstream.raw, data) }
            // Half-close and release on EOF/error — or if the proxy was torn down mid-stream, so the
            // refcount can still reach zero and close the fd rather than leaking it.
            guard let self, !(isComplete || error != nil) else {
                shutdown(upstream.raw, SHUT_WR); upstream.release(); return
            }
            self.pumpClientToUpstream(client, upstream)
        }
    }

    /// Refcounts a raw socket fd shared by the two relay pumps so it is closed exactly once, after
    /// both have released it — avoiding a use-after-close / fd-reuse race.
    private final class FDOwner: @unchecked Sendable {
        let raw: Int32
        private let lock = NSLock()
        private var refs = 2
        private var closed = false
        init(_ fd: Int32) { raw = fd }
        func release() {
            lock.lock()
            refs -= 1
            let shouldClose = refs <= 0 && !closed
            if shouldClose { closed = true }
            lock.unlock()
            if shouldClose { shutdown(raw, SHUT_RDWR); Darwin.close(raw) }
        }
    }

    private static func loadIdentity(p12Path: String, password: String) -> SecIdentity? {
        guard let data = FileManager.default.contents(atPath: p12Path) else { return nil }
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }

    enum ProxyError: Error, Sendable { case identity }
}
