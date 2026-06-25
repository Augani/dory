import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Host-based reverse proxy for Dory's container domains. Reads the `Host:` header of an incoming
/// request, resolves `<name>.dory.local` to a backend the host can already reach (the loopback
/// port the `HostPortForwarder` exposes for that container), and splices the connection through —
/// so `http://myapp.dory.local` reaches the container with no port number, the way OrbStack does.
///
/// HTTP is validated end to end here. Production binds :80 (and :443 with a `LocalCA` identity for
/// automatic HTTPS); those privileged binds are the consent-gated system change.
nonisolated struct ProxyBackend: Sendable {
    var host: String
    var port: Int
    /// When non-empty, the request path is rewritten to `prefix + originalPath` before forwarding —
    /// used to route `*.k8s.dory.local` through the Kubernetes API server's service proxy.
    var pathPrefix: String = ""
}

nonisolated final class DoryReverseProxy: @unchecked Sendable {
    typealias BackendResolver = @Sendable (String) -> ProxyBackend?

    private let resolve: BackendResolver
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    init(resolve: @escaping BackendResolver) { self.resolve = resolve }

    func start(httpPort: UInt16) throws {
        guard let fd = HostPortForwarder.listenLoopback(port: Int(httpPort)) else {
            throw ProxyError.bind("http :\(httpPort)")
        }
        lock.lock(); listenFD = fd; running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock(); running = false; let fd = listenFD; listenFD = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning() {
            let client = accept(fd, nil, nil)
            if client < 0 { if isRunning() { continue } else { break } }
            Thread.detachNewThread { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<64 {
            if HTTPCodec.range(of: HTTPCodec.headerTerminator, in: buffer) != nil { break }
            if buffer.count > 65_536 { break }
            let count = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress, 16 * 1024) }
            if count <= 0 { break }
            buffer.append(contentsOf: bytes[0..<count])
        }
        guard let host = Self.hostHeader(buffer), let backend = resolve(host) else {
            let body = "Dory: no container for that domain\n"
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            try? UnixSocketHTTP.writeAll(client, Data(response.utf8))
            shutdown(client, SHUT_RDWR); Darwin.close(client)
            return
        }
        guard let upstream = HostPortForwarder.connectTCP(host: backend.host, port: backend.port) else {
            shutdown(client, SHUT_RDWR); Darwin.close(client)
            return
        }
        let outgoing = backend.pathPrefix.isEmpty ? buffer : Self.rewriteRequest(buffer, pathPrefix: backend.pathPrefix)
        guard (try? UnixSocketHTTP.writeAll(upstream, outgoing)) != nil else {
            shutdown(upstream, SHUT_RDWR); Darwin.close(upstream)
            shutdown(client, SHUT_RDWR); Darwin.close(client)
            return
        }
        UnixSocketHTTP.bidirectionalCopy(client: client, upstream: upstream)
    }

    /// Rewrite the request line's path to `pathPrefix + originalPath`, leaving headers and body
    /// intact — used to dispatch a domain request through the Kubernetes API server's service proxy.
    nonisolated static func rewriteRequest(_ data: Data, pathPrefix: String) -> Data {
        guard let headerRange = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: data) else { return data }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        let rest = data.subdata(in: headerRange.lowerBound..<data.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        let parts = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return data }
        let path = String(parts[1])
        lines[0] = "\(parts[0]) \(pathPrefix)\(path) \(parts[2])"
        var result = Data(lines.joined(separator: "\r\n").utf8)
        result.append(rest)
        return result
    }

    /// Extract the lowercased host (without port) from raw request header bytes.
    nonisolated static func hostHeader(_ data: Data) -> String? {
        guard let range = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: data),
              let text = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            return value.split(separator: ":").first.map(String.init) ?? value
        }
        return nil
    }

    nonisolated enum ProxyError: Error, Sendable { case bind(String) }
}

/// Live, thread-safe map of Dory domains → their backends. `<name>.dory.local` resolves to the
/// loopback port that reaches the container; `<svc>.<ns>.k8s.dory.local` resolves through the
/// Kubernetes API service proxy. Updated by the reconcilers; read by the proxies per connection.
nonisolated final class DomainTable: @unchecked Sendable {
    private let lock = NSLock()
    private var containerMap: [String: ProxyBackend] = [:]
    private var kubeMap: [String: ProxyBackend] = [:]

    func replaceContainers(_ entries: [String: Int]) {
        lock.lock(); containerMap = entries.mapValues { ProxyBackend(host: "127.0.0.1", port: $0) }; lock.unlock()
    }

    func replaceKube(_ entries: [String: ProxyBackend]) {
        lock.lock(); kubeMap = entries; lock.unlock()
    }

    func backend(for host: String) -> ProxyBackend? {
        lock.lock(); defer { lock.unlock() }
        let key = host.lowercased()
        return containerMap[key] ?? kubeMap[key]
    }
}
