import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Maps `127.0.0.1:<port>` on the host to a container's published port inside Dory's shared VM, so
/// services are reachable at `localhost` — the way OrbStack and Docker Desktop behave — even though
/// the shared VM actually publishes them on its own IP.
///
/// Two transports, chosen automatically:
///   • Direct TCP to the VM's IP — efficient, used once macOS Local Network access is granted (the
///     same one-time prompt OrbStack triggers).
///   • An exec bridge (`container exec -i <engine> nc 127.0.0.1 <port>`) that tunnels through the
///     runtime's vsock channel — works out of the box with no local-network permission, and is the
///     automatic fallback when the direct connection is blocked.
final class HostPortForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [Int: Listener] = [:]
    private var loopbackListeners: [String: Listener] = [:]
    private var loopbackTimers: [String: DispatchSourceTimer] = [:]
    private var targetHost: String
    private let containerBinary: String?
    private let engineName: String
    private var preferExecBridge = false

    init(targetHost: String, containerBinary: String? = nil, engineName: String = "") {
        self.targetHost = targetHost
        self.containerBinary = containerBinary
        self.engineName = engineName
    }

    func updateTarget(_ host: String) {
        lock.lock()
        let changed = host != targetHost
        targetHost = host
        let active = changed ? Set(listeners.keys) : []
        lock.unlock()
        guard changed else { return }
        for port in active { stop(port: port) }
        sync(ports: active)
    }

    func sync(ports desired: Set<Int>) {
        lock.lock()
        let current = Set(listeners.keys)
        let host = targetHost
        lock.unlock()
        for port in desired.subtracting(current) { start(port: port, host: host) }
        for port in current.subtracting(desired) { stop(port: port) }
    }

    func stopAll() {
        lock.lock(); let ports = Array(listeners.keys); let loopKeys = Array(loopbackListeners.keys); lock.unlock()
        for port in ports { stop(port: port) }
        for key in loopKeys {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let port = Int(parts[1]) { teardownLoopback(machine: parts[0], port: port) }
        }
    }

    func forwardLoopback(machine: String, port: Int, ttl: Int) -> Bool {
        let key = "\(machine):\(port)"
        lock.lock()
        if loopbackListeners[key] != nil { lock.unlock(); return true }
        lock.unlock()
        guard let fd = Self.listenLoopback(port: port) else { return false }
        let engine = engineName
        let binary = containerBinary
        let listener = Listener(listenFD: fd) { client in
            Self.execBridgeInto(client: client, port: port, containerName: engine, binary: binary)
        }
        lock.lock()
        loopbackListeners[key] = listener
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .seconds(ttl))
        timer.setEventHandler { [weak self] in self?.teardownLoopback(machine: machine, port: port) }
        loopbackTimers[key] = timer
        timer.resume()
        lock.unlock()
        listener.run()
        return true
    }

    func teardownLoopback(machine: String, port: Int) {
        let key = "\(machine):\(port)"
        lock.lock()
        let listener = loopbackListeners.removeValue(forKey: key)
        let timer = loopbackTimers.removeValue(forKey: key)
        lock.unlock()
        timer?.cancel()
        listener?.stop()
    }

    func teardownLoopback(forMachine machine: String) {
        let prefix = "\(machine):"
        lock.lock()
        let keys = loopbackListeners.keys.filter { $0.hasPrefix(prefix) }
        lock.unlock()
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let port = Int(parts[1]) { teardownLoopback(machine: parts[0], port: port) }
        }
    }

    func activeLoopbackKeys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(loopbackListeners.keys)
    }

    private func start(port: Int, host: String) {
        guard let fd = Self.listenLoopback(port: port) else { return }
        let listener = Listener(listenFD: fd) { [weak self] client in
            self?.handle(client: client, port: port, host: host)
        }
        lock.lock(); listeners[port] = listener; lock.unlock()
        listener.run()
    }

    private func stop(port: Int) {
        lock.lock(); let listener = listeners.removeValue(forKey: port); lock.unlock()
        listener?.stop()
    }

    private func handle(client: Int32, port: Int, host: String) {
        Thread.detachNewThread { [self] in
            lock.lock(); let useExec = preferExecBridge; lock.unlock()
            if !useExec, let upstream = Self.connectTCP(host: host, port: port) {
                UnixSocketHTTP.bidirectionalCopy(client: client, upstream: upstream)
                return
            }
            // Direct connection blocked (typically macOS Local Network privacy) — commit to the
            // exec bridge for subsequent connections too.
            lock.lock(); preferExecBridge = true; lock.unlock()
            execBridge(client: client, port: port)
        }
    }

    private func execBridge(client: Int32, port: Int) {
        guard let binary = containerBinary, !engineName.isEmpty else {
            shutdown(client, SHUT_RDWR); Darwin.close(client); return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["exec", "-i", engineName, "nc", "127.0.0.1", String(port)]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { shutdown(client, SHUT_RDWR); Darwin.close(client); return }

        let inFD = stdin.fileHandleForWriting.fileDescriptor
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            Self.pump(from: client, to: inFD)
            try? stdin.fileHandleForWriting.close()
            group.leave()
        }
        Self.pump(from: outFD, to: client)
        group.wait()
        if process.isRunning { process.terminate() }
        shutdown(client, SHUT_RDWR); Darwin.close(client)
    }

    nonisolated static func execBridgeInto(client: Int32, port: Int, containerName: String, binary: String?) {
        guard let binary, !containerName.isEmpty else { shutdown(client, SHUT_RDWR); Darwin.close(client); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["exec", "-i", containerName, "nc", "127.0.0.1", String(port)]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { shutdown(client, SHUT_RDWR); Darwin.close(client); return }
        let inFD = stdin.fileHandleForWriting.fileDescriptor
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            pump(from: client, to: inFD)
            try? stdin.fileHandleForWriting.close()
            group.leave()
        }
        pump(from: outFD, to: client)
        group.wait()
        if process.isRunning { process.terminate() }
        shutdown(client, SHUT_RDWR); Darwin.close(client)
    }

    private final class Listener: @unchecked Sendable {
        let listenFD: Int32
        private let onConnect: @Sendable (Int32) -> Void
        private let lock = NSLock()
        private var running = true

        init(listenFD: Int32, onConnect: @escaping @Sendable (Int32) -> Void) {
            self.listenFD = listenFD; self.onConnect = onConnect
        }

        func run() {
            Thread.detachNewThread { [self] in
                while isRunning() {
                    let client = accept(listenFD, nil, nil)
                    if client < 0 { if isRunning() { continue } else { break } }
                    onConnect(client)
                }
            }
        }

        func stop() {
            lock.lock(); running = false; lock.unlock()
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }

        private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    }

    nonisolated static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, 32 * 1024) }
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress!.advanced(by: offset), count - offset) }
                if written <= 0 { break }
                offset += written
            }
            if offset < count { break }
        }
    }

    nonisolated static func listenLoopback(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    nonisolated static func connectTCP(host: String, port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        return fd
    }
}
