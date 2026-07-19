import Darwin
import Foundation

public enum LoopbackTCPForwarderError: Error, Sendable, CustomStringConvertible {
    case invalidPort(UInt16)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .invalidPort(port):
            return "invalid loopback TCP forward port: \(port)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public struct LoopbackTCPForwardReconcileResult: Sendable, Equatable {
    public var active: [PrivilegedTCPForward]
    public var failures: [UInt16: String]

    public init(active: [PrivilegedTCPForward], failures: [UInt16: String]) {
        self.active = active
        self.failures = failures
    }
}

/// Owns wildcard TCP listeners while accepting traffic only from loopback peers.
///
/// Current macOS permits an unprivileged process to bind a low TCP port on wildcard IPv4/IPv6,
/// while a low-port bind to a specific address such as 127.0.0.1 still requires root. Binding the
/// wildcard and rejecting non-loopback peers immediately gives Dory a stable standard-port path
/// without depending on PF rules that Internet Sharing may replace.
public final class LoopbackTCPForwarderSet: @unchecked Sendable {
    private let mutationLock = NSLock()
    private let lock = NSLock()
    private var forwarders: [UInt16: LoopbackTCPForwarder] = [:]

    public init() {}

    @discardableResult
    public func reconcile(_ desired: [PrivilegedTCPForward]) -> LoopbackTCPForwardReconcileResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var targets: [UInt16: UInt16] = [:]
        for forward in desired where forward.listenPort > 0 && forward.targetPort > 0 {
            targets[forward.listenPort] = forward.targetPort
        }

        lock.lock()
        let removed = forwarders.keys.filter { targets[$0] == nil }
        let removedForwarders = removed.compactMap { forwarders.removeValue(forKey: $0) }
        let existing = forwarders
        lock.unlock()
        for forwarder in removedForwarders {
            forwarder.stop()
        }

        var failures: [UInt16: String] = [:]
        for listenPort in targets.keys.sorted() {
            guard let targetPort = targets[listenPort] else { continue }
            if let forwarder = existing[listenPort] {
                forwarder.updateTargetPort(targetPort)
                continue
            }

            let forwarder = LoopbackTCPForwarder(
                listenPort: listenPort,
                targetPort: targetPort
            )
            do {
                try forwarder.start()
                lock.lock()
                if forwarders[listenPort] == nil {
                    forwarders[listenPort] = forwarder
                    lock.unlock()
                } else {
                    lock.unlock()
                    forwarder.stop()
                }
            } catch {
                failures[listenPort] = "\(error)"
            }
        }

        return LoopbackTCPForwardReconcileResult(active: current, failures: failures)
    }

    public var current: [PrivilegedTCPForward] {
        lock.lock()
        let values = forwarders.values.map {
            PrivilegedTCPForward(listenPort: $0.listenPort, targetPort: $0.targetPort)
        }
        lock.unlock()
        return values.sorted { lhs, rhs in
            if lhs.listenPort == rhs.listenPort { return lhs.targetPort < rhs.targetPort }
            return lhs.listenPort < rhs.listenPort
        }
    }

    public func stop() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        lock.lock()
        let active = Array(forwarders.values)
        forwarders.removeAll()
        lock.unlock()
        for forwarder in active {
            forwarder.stop()
        }
    }

    deinit {
        stop()
    }
}

final class LoopbackTCPForwarder: @unchecked Sendable {
    let listenPort: UInt16
    private let lock = NSLock()
    private let connectionBudget: DoryConnectionBudget
    private var currentTargetPort: UInt16
    private var listenerFDs: Set<Int32> = []

    init(listenPort: UInt16, targetPort: UInt16, maximumConnections: Int = 256) {
        self.listenPort = listenPort
        self.currentTargetPort = targetPort
        self.connectionBudget = DoryConnectionBudget(limit: maximumConnections)
    }

    var targetPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return currentTargetPort
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !listenerFDs.isEmpty
    }

    func updateTargetPort(_ port: UInt16) {
        guard port > 0 else { return }
        lock.lock()
        currentTargetPort = port
        lock.unlock()
    }

    func start() throws {
        guard listenPort > 0, targetPort > 0 else {
            throw LoopbackTCPForwarderError.invalidPort(listenPort)
        }
        lock.lock()
        guard listenerFDs.isEmpty else {
            lock.unlock()
            return
        }
        lock.unlock()

        var opened: [Int32] = []
        do {
            let ipv4 = try Self.makeIPv4Listener(port: listenPort)
            opened.append(ipv4)
            let ipv6 = try Self.makeIPv6Listener(port: listenPort)
            opened.append(ipv6)

            lock.lock()
            listenerFDs = Set(opened)
            lock.unlock()
            for descriptor in opened {
                Thread.detachNewThread { [weak self] in
                    self?.acceptLoop(descriptor)
                }
            }
        } catch {
            for descriptor in opened {
                shutdown(descriptor, SHUT_RDWR)
                close(descriptor)
            }
            throw error
        }
    }

    func stop() {
        lock.lock()
        let descriptors = Array(listenerFDs)
        listenerFDs.removeAll()
        lock.unlock()
        for descriptor in descriptors {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private func acceptLoop(_ listenerFD: Int32) {
        while true {
            lock.lock()
            let running = listenerFDs.contains(listenerFD)
            lock.unlock()
            guard running else { return }

            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    accept(listenerFD, raw, &peerLength)
                }
            }
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK:
                    continue
                case EMFILE, ENFILE:
                    usleep(50_000)
                    continue
                default:
                    return
                }
            }
            guard Self.isLoopbackPeer(peer, length: peerLength),
                  let lease = connectionBudget.tryAcquire() else {
                shutdown(client, SHUT_RDWR)
                close(client)
                continue
            }
            Thread.detachNewThread { [weak self, lease] in
                guard let self else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    lease.release()
                    return
                }
                self.connectAndRelay(client, lease: lease)
            }
        }
    }

    private func connectAndRelay(_ client: Int32, lease: DoryConnectionLease) {
        guard let upstream = DoryTCP.connect(host: "127.0.0.1", port: targetPort) else {
            shutdown(client, SHUT_RDWR)
            close(client)
            lease.release()
            return
        }
        DoryTCP.configureRelayTimeout(client)
        DoryTCP.configureRelayTimeout(upstream)
        DoryTCP.bidirectionalCopy(
            client: client,
            upstream: upstream,
            onClose: { lease.release() }
        )
    }

    static func isLoopbackAddress(_ value: String) -> Bool {
        let unscoped = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        var ipv4 = in_addr()
        if inet_pton(AF_INET, unscoped, &ipv4) == 1 {
            return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, unscoped, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { raw in
            let bytes = Array(raw)
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
                return true
            }
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
            return mapped && bytes[12] == 127
        }
    }

    private static func isLoopbackPeer(_ peer: sockaddr_storage, length: socklen_t) -> Bool {
        var peer = peer
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getnameinfo(
                    raw,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard result == 0 else { return false }
        let numericHost = String(
            decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return isLoopbackAddress(numericHost)
    }

    private static func makeIPv4Listener(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackTCPForwarderError.syscall("socket(AF_INET)", errno)
        }
        do {
            try configureListener(descriptor)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                throw LoopbackTCPForwarderError.syscall("bind(0.0.0.0:\(port))", errno)
            }
            guard listen(descriptor, 64) == 0 else {
                throw LoopbackTCPForwarderError.syscall("listen(0.0.0.0:\(port))", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func makeIPv6Listener(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackTCPForwarderError.syscall("socket(AF_INET6)", errno)
        }
        do {
            try configureListener(descriptor)
            var yes: Int32 = 1
            guard setsockopt(
                descriptor,
                IPPROTO_IPV6,
                IPV6_V6ONLY,
                &yes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw LoopbackTCPForwarderError.syscall("setsockopt(IPV6_V6ONLY)", errno)
            }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bound == 0 else {
                throw LoopbackTCPForwarderError.syscall("bind([::]:\(port))", errno)
            }
            guard listen(descriptor, 64) == 0 else {
                throw LoopbackTCPForwarderError.syscall("listen([::]:\(port))", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func configureListener(_ descriptor: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw LoopbackTCPForwarderError.syscall("setsockopt(SO_REUSEADDR)", errno)
        }
    }

    deinit {
        stop()
    }
}
