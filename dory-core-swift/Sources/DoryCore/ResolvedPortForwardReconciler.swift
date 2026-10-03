import Darwin
import DoryOperations
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

    private struct LocalKey: Hashable {
        var `protocol`: PublishedPortForwardProtocol
        var endpoint: Endpoint
    }

    private struct Endpoint: Sendable, Hashable {
        var host: String
        var port: Int
        private var addressIdentity: String

        init?(_ rawValue: String) {
            guard rawValue.utf8.count <= 256, !rawValue.utf8.contains(0),
                  !rawValue.contains("://") else { return nil }
            let value = rawValue[...]
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
                guard !host.contains(":") else { return nil }
                portText = value[value.index(after: separator)...]
            }
            guard !host.isEmpty,
                  let port = Int(portText),
                  (1...65_535).contains(port), String(port) == String(portText) else {
                return nil
            }
            guard let identity = Self.canonicalIPAddress(String(host)) else { return nil }
            // IP rows use bare host:port with bracketed IPv6. These restrictions make rebuilding
            // this exact endpoint lossless; gvproxy's mutation key is its original local string.
            self.host = String(host)
            self.port = port
            addressIdentity = identity
        }

        func matches(host candidate: String, port candidatePort: Int) -> Bool {
            port == candidatePort && addressIdentity == Self.canonicalIPAddress(candidate)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.port == rhs.port && lhs.addressIdentity == rhs.addressIdentity
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(port)
            hasher.combine(addressIdentity)
        }

        private static func canonicalIPAddress(_ host: String) -> String? {
            // Darwin's inet_pton may accept scope suffixes; C strings also truncate embedded NUL.
            // Neither is part of the resolved VM endpoint vocabulary or safe identity evidence.
            guard !host.utf8.contains(0), !host.contains("%") else { return nil }
            let value: String
            if host.hasPrefix("[") && host.hasSuffix("]") {
                value = String(host.dropFirst().dropLast())
            } else {
                value = host
            }
            var ipv4 = in_addr()
            if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
                return "ipv4:" + withUnsafeBytes(of: ipv4) { $0.map { String($0, radix: 16) }.joined(separator: ".") }
            }
            var ipv6 = in6_addr()
            guard value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
            return "ipv6:" + withUnsafeBytes(of: ipv6) { $0.map { String($0, radix: 16) }.joined(separator: ".") }
        }
    }

    private struct DecodedEntry: Decodable {
        var local: String
        var remote: String
        var `protocol`: String
    }

    private var entries: Set<Entry>

    public static func decode(_ data: Data) -> ResolvedPortForwardRegistry? {
        guard data.count <= 1_048_576,
              let decoded = try? JSONDecoder().decode([DecodedEntry].self, from: data),
              decoded.count <= 1_024 else {
            return nil
        }
        var entries: Set<Entry> = []
        var localOwners = [LocalKey: Entry]()
        for entry in decoded {
            let transportName = entry.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // gvproxy stores Dory's Unix shutdown channel in the same registry. Unknown IP
            // transports must reject observation rather than masquerade as that infrastructure.
            if transportName == "unix" { continue }
            guard let transport = PublishedPortForwardProtocol(rawValue: transportName) else { return nil }
            guard let local = Endpoint(entry.local), let remote = Endpoint(entry.remote) else {
                return nil
            }
            let parsed = Entry(protocol: transport, local: local, remote: remote)
            let key = LocalKey(protocol: transport, endpoint: local)
            if let previous = localOwners[key], previous != parsed { return nil }
            localOwners[key] = parsed
            entries.insert(parsed)
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

    fileprivate func occupyingForward(of forward: PublishedPortForward) -> PublishedPortForward? {
        guard let entry = entries.first(where: { $0.occupiesLocalEndpoint(of: forward) }) else { return nil }
        return PublishedPortForward(
            protocol: entry.protocol, publishedPort: forward.publishedPort,
            localHost: entry.local.host, localPort: entry.local.port,
            guestHost: entry.remote.host, guestPort: entry.remote.port)
    }

    fileprivate static func admits(_ desired: Set<PublishedPortForward>) -> Bool {
        guard desired.count <= DoryVMPortForward.maximumCount else { return false }
        var keys = Set<LocalKey>()
        for forward in desired {
            guard let local = Endpoint(forward.localEndpoint),
                  Endpoint(forward.remoteEndpoint) != nil,
                  keys.insert(LocalKey(protocol: forward.protocol, endpoint: local)).inserted else {
                return false
            }
        }
        return true
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

/// A backend-neutral, point-in-time view of the exact host listeners owned by a resolved launch.
/// Failure counts are monotonic for the lifetime of the helper so daemon telemetry can distinguish
/// an initial repair from a repeatedly unhealthy listener after sleep or a network transition.
public struct ResolvedPortForwardHealthSnapshot: Sendable, Equatable {
    public var configuredForwards: UInt64
    public var activeForwards: UInt64
    public var failedReconciliations: UInt64
    public var healthy: Bool

    public init(
        configuredForwards: UInt64,
        activeForwards: UInt64,
        failedReconciliations: UInt64,
        healthy: Bool
    ) {
        self.configuredForwards = configuredForwards
        self.activeForwards = activeForwards
        self.failedReconciliations = failedReconciliations
        self.healthy = healthy
    }

    public var isValid: Bool {
        activeForwards <= configuredForwards
            && (healthy == (activeForwards == configuredForwards))
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
    private var lastHealthy: Bool
    private var activeForwards: UInt64
    private var failedReconciliations: UInt64 = 0

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
        self.lastHealthy = desired.isEmpty
        self.activeForwards = 0
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
        if !cancelled {
            timer.setEventHandler {}
            if !activated {
                activated = true
                timer.resume()
            }
            cancelled = true
            activeForwards = 0
            lastHealthy = desired.isEmpty
            timer.cancel()
        }
        lock.unlock()
        // Every external caller joins admitted registry/mutation work, not just the first owner.
        // A provider calling stop reentrantly already owns this queue and must not self-join.
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    deinit {
        stop()
    }

    @discardableResult
    public func reconcileNow() -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return reconcileAndReport() }
        return queue.sync { reconcileAndReport() }
    }

    public func healthSnapshot() -> ResolvedPortForwardHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ResolvedPortForwardHealthSnapshot(
            configuredForwards: UInt64(desired.count),
            activeForwards: activeForwards,
            failedReconciliations: failedReconciliations,
            healthy: lastHealthy
        )
    }

    public var isStopped: Bool { lock.withLock { cancelled } }

    @discardableResult
    private func reconcileAndReport() -> Bool {
        guard isActive else { return false }
        let result = reconcile()
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        let healthChanged = result.healthy != lastHealthy
        lastHealthy = result.healthy
        activeForwards = UInt64(result.activeCount)
        if !result.healthy, failedReconciliations < UInt64.max {
            failedReconciliations += 1
        }
        lock.unlock()
        if healthChanged {
            log(result.healthy
                ? "resolved port forwards recovered"
                : "resolved port-forward reconciliation is waiting to recover")
        }
        return result.healthy
    }

    private func reconcile() -> (healthy: Bool, activeCount: Int) {
        guard !desired.isEmpty else { return (true, 0) }
        guard isActive, ResolvedPortForwardRegistry.admits(desired) else { return (false, 0) }
        guard let registry = registryProvider() else { return (false, 0) }
        let plan = ResolvedPortForwardReconciliation(desired: desired, registry: registry)
        var retired = [PublishedPortForward]()
        var exposed = [PublishedPortForward]()
        for forward in ordered(plan.toUnexpose) {
            guard isActive else { return (false, 0) }
            guard let previous = registry.occupyingForward(of: forward) else { return (false, 0) }
            // The actual row preserves gvproxy's string key as well as its old target for undo.
            retired.append(previous)
            guard unexposeProvider(previous) else {
                return recoverTransaction(original: registry, retired: retired, exposed: exposed)
            }
        }
        for forward in ordered(plan.toExpose) {
            guard isActive else { return (false, 0) }
            // Track attempts too: a timeout can report failure after the helper installed it.
            exposed.append(forward)
            guard exposeProvider(forward) else {
                return recoverTransaction(original: registry, retired: retired, exposed: exposed)
            }
        }
        guard isActive else { return (false, 0) }
        guard let verified = registryProvider() else { return (false, 0) }
        let activeCount = exactActiveCount(in: verified)
        if activeCount != desired.count {
            return recoverTransaction(original: registry, retired: retired, exposed: exposed, observed: verified)
        }
        return (activeCount == desired.count, activeCount)
    }

    private func recoverTransaction(
        original: ResolvedPortForwardRegistry,
        retired: [PublishedPortForward],
        exposed: [PublishedPortForward],
        observed: ResolvedPortForwardRegistry? = nil
    ) -> (healthy: Bool, activeCount: Int) {
        guard isActive, var current = observed ?? registryProvider() else { return (false, 0) }
        // An RPC acknowledgement may be lost after mutation. Only a full exact observation can
        // commit that unknown result; otherwise undo every new listener owned by this attempt.
        if exactActiveCount(in: current) == desired.count { return (true, desired.count) }
        for forward in exposed.reversed() {
            guard isActive else { return (false, 0) }
            if !original.contains(forward), current.contains(forward),
               let actual = current.occupyingForward(of: forward) {
                _ = unexposeProvider(actual)
                guard isActive, let verified = registryProvider() else { return (false, 0) }
                current = verified
            }
        }
        for previous in retired.reversed() {
            guard isActive else { return (false, 0) }
            // Do not overwrite a concurrently changed target or a different bind scope. Restore
            // the prior exact mapping only once its original local tuple is provably unoccupied.
            if current.occupyingForward(of: previous) == nil {
                _ = exposeProvider(previous)
                guard isActive, let verified = registryProvider() else { return (false, 0) }
                current = verified
            }
        }
        let activeCount = exactActiveCount(in: current)
        return (activeCount == desired.count, activeCount)
    }

    private func ordered(_ forwards: Set<PublishedPortForward>) -> [PublishedPortForward] {
        forwards.sorted {
            if $0.protocol != $1.protocol { return $0.protocol.rawValue < $1.protocol.rawValue }
            if $0.localHost != $1.localHost { return $0.localHost < $1.localHost }
            return $0.localPort < $1.localPort
        }
    }

    private var isActive: Bool { lock.withLock { !cancelled } }

    private func exactActiveCount(in registry: ResolvedPortForwardRegistry) -> Int {
        desired.reduce(into: 0) { count, forward in
            if registry.contains(forward), !registry.conflicts(with: forward) {
                count += 1
            }
        }
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
