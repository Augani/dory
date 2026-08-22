import Darwin
import Foundation

/// A fail-closed view of gvproxy's TCP/UDP registry. Unix infrastructure forwards are ignored;
/// malformed IP-forward rows reject the entire observation so reconciliation never acts on a
/// partial registry.
public struct ResolvedPortForwardRegistry: Sendable {
    private struct Entry: Sendable, Hashable {
        var `protocol`: PublishedPortForwardProtocol
        var local: Endpoint
        var remote: Endpoint

        func matches(_ forward: PublishedPortForward) -> Bool {
            `protocol` == forward.protocol
                && local.matches(host: forward.localHost, port: forward.localPort)
                && remote.matches(host: forward.guestHost, port: forward.guestPort)
        }

        func occupiesLocalEndpoint(of forward: PublishedPortForward) -> Bool {
            `protocol` == forward.protocol
                && local.matches(host: forward.localHost, port: forward.localPort)
        }
    }

    private struct Endpoint: Sendable, Hashable {
        var host: String
        var port: Int

        init?(_ rawValue: String) {
            let value: Substring
            if let scheme = rawValue.range(of: "://") {
                value = rawValue[scheme.upperBound...]
            } else {
                value = rawValue[...]
            }
            let host: Substring
            let portText: Substring
            if value.first == "[" {
                guard let closingBracket = value.firstIndex(of: "]"),
                      value.index(after: closingBracket) < value.endIndex,
                      value[value.index(after: closingBracket)] == ":" else {
                    return nil
                }
                host = value[...closingBracket]
                portText = value[value.index(closingBracket, offsetBy: 2)...]
            } else {
                guard let separator = value.lastIndex(of: ":") else { return nil }
                host = value[..<separator]
                portText = value[value.index(after: separator)...]
            }
            guard !host.isEmpty,
                  let port = Int(portText),
                  (1...65_535).contains(port) else {
                return nil
            }
            self.host = String(host)
            self.port = port
            guard isIPAddress else { return nil }
        }

        func matches(host candidate: String, port candidatePort: Int) -> Bool {
            port == candidatePort && normalized(host) == normalized(candidate)
        }

        private func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        }

        private var isIPAddress: Bool {
            let value = normalized(host)
            var ipv4 = in_addr()
            if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
            var ipv6 = in6_addr()
            return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
        }
    }

    private struct DecodedEntry: Decodable {
        var local: String
        var remote: String
        var `protocol`: String
    }

    private var entries: Set<Entry>

    public static func decode(_ data: Data) -> ResolvedPortForwardRegistry? {
        guard let decoded = try? JSONDecoder().decode([DecodedEntry].self, from: data) else {
            return nil
        }
        var entries: Set<Entry> = []
        for entry in decoded {
            guard let transport = PublishedPortForwardProtocol(
                rawValue: entry.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) else {
                // gvproxy stores Dory's Unix shutdown channel in the same registry.
                continue
            }
            guard let local = Endpoint(entry.local), let remote = Endpoint(entry.remote) else {
                return nil
            }
            entries.insert(Entry(protocol: transport, local: local, remote: remote))
        }
        return ResolvedPortForwardRegistry(entries: entries)
    }

    public func contains(_ forward: PublishedPortForward) -> Bool {
        entries.contains { $0.matches(forward) }
    }

    public func conflicts(with forward: PublishedPortForward) -> Bool {
        entries.contains {
            $0.occupiesLocalEndpoint(of: forward) && !$0.matches(forward)
        }
    }
}

public struct ResolvedPortForwardReconciliation: Sendable, Equatable {
    public var toUnexpose: Set<PublishedPortForward>
    public var toExpose: Set<PublishedPortForward>
    public var missing: Set<PublishedPortForward>

    public init(
        desired: Set<PublishedPortForward>,
        registry: ResolvedPortForwardRegistry
    ) {
        missing = Set(desired.filter { !registry.contains($0) })
        toUnexpose = Set(desired.filter { registry.conflicts(with: $0) })
        toExpose = missing.union(toUnexpose)
    }
}

/// Periodically proves and repairs only the exact forwards pinned by the resolved launch. It never
/// adopts or removes unrelated registry entries. A conflicting local key is released only because
/// the same resolved contract owns that protocol/address/port tuple.
public final class ResolvedPortForwardReconciler: @unchecked Sendable {
    public typealias RegistryProvider = @Sendable () -> ResolvedPortForwardRegistry?
    public typealias Mutation = @Sendable (PublishedPortForward) -> Bool

    private let desired: Set<PublishedPortForward>
    private let registryProvider: RegistryProvider
    private let exposeProvider: Mutation
    private let unexposeProvider: Mutation
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.dory.resolved-port-forward-reconciler")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let timer: any DispatchSourceTimer
    private let lock = NSLock()
    private var activated = false
    private var cancelled = false
    private var lastHealthy = true

    public convenience init(
        desired: Set<PublishedPortForward>,
        apiSocketPath: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            desired: desired,
            registryProvider: {
                guard let data = Self.curlData(
                    unixSocketPath: apiSocketPath,
                    URL: "http://gvproxy/services/forwarder/all"
                ) else { return nil }
                return ResolvedPortForwardRegistry.decode(data)
            },
            exposeProvider: { forward in
                Self.post(
                    forward,
                    operation: "expose",
                    apiSocketPath: apiSocketPath
                )
            },
            unexposeProvider: { forward in
                Self.post(
                    forward,
                    operation: "unexpose",
                    apiSocketPath: apiSocketPath
                )
            },
            log: log
        )
    }

    public init(
        desired: Set<PublishedPortForward>,
        registryProvider: @escaping RegistryProvider,
        exposeProvider: @escaping Mutation,
        unexposeProvider: @escaping Mutation,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.desired = desired
        self.registryProvider = registryProvider
        self.exposeProvider = exposeProvider
        self.unexposeProvider = unexposeProvider
        self.log = log
        queue.setSpecific(key: queueKey, value: 1)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.reconcileAndReport()
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !activated, !cancelled, !desired.isEmpty else { return }
        activated = true
        timer.resume()
    }

    public func stop() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        timer.setEventHandler {}
        if !activated {
            activated = true
            timer.resume()
        }
        cancelled = true
        timer.cancel()
        lock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    deinit {
        stop()
    }

    @discardableResult
    public func reconcileNow() -> Bool {
        queue.sync { reconcile() }
    }

    private func reconcileAndReport() {
        let healthy = reconcile()
        if healthy != lastHealthy {
            lastHealthy = healthy
            log(healthy
                ? "resolved port forwards recovered"
                : "resolved port-forward reconciliation is waiting to recover")
        }
    }

    private func reconcile() -> Bool {
        guard !desired.isEmpty else { return true }
        guard let registry = registryProvider() else { return false }
        let plan = ResolvedPortForwardReconciliation(desired: desired, registry: registry)
        for forward in plan.toUnexpose where !unexposeProvider(forward) {
            return false
        }
        for forward in plan.toExpose where !exposeProvider(forward) {
            return false
        }
        guard let verified = registryProvider() else { return false }
        return desired.allSatisfy { verified.contains($0) && !verified.conflicts(with: $0) }
    }

    private static func curlData(unixSocketPath: String, URL: String) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = Foundation.URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--connect-timeout", "1", "--max-time", "2",
            "--unix-socket", unixSocketPath,
            URL,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func post(
        _ forward: PublishedPortForward,
        operation: String,
        apiSocketPath: String
    ) -> Bool {
        var body = [
            "local": forward.localEndpoint,
            "protocol": forward.protocol.rawValue,
        ]
        if operation == "expose" { body["remote"] = forward.remoteEndpoint }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: data, encoding: .utf8) else {
            return false
        }
        let process = Process()
        process.executableURL = Foundation.URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--connect-timeout", "1", "--max-time", "2",
            "--unix-socket", apiSocketPath,
            "--request", "POST",
            "--data-binary", bodyString,
            "http://gvproxy/services/forwarder/\(operation)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
