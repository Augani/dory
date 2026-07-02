import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct OpenRequest: Codable, Sendable {
    let url: String
    let cwd: String?
    let ts: Int
}

struct ForwardRequest: Codable, Sendable {
    let port: Int
    let ts: Int
    let ttlSec: Int?
}

enum HostBridge {
    static func decodeOpen(_ data: Data) -> OpenRequest? {
        guard data.count <= maxRequestBytes else { return nil }
        return try? JSONDecoder().decode(OpenRequest.self, from: data)
    }

    static func decodeForward(_ data: Data) -> ForwardRequest? {
        guard data.count <= maxRequestBytes else { return nil }
        return try? JSONDecoder().decode(ForwardRequest.self, from: data)
    }

    static let maxRequestBytes = 64 * 1024

    static func allowedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard url.host?.isEmpty == false else { return nil }
        return url
    }

    static func allowedForwardPort(_ port: Int) -> Bool {
        port >= 1024 && port <= 65535
    }

    static func resolvedTTL(_ ttlSec: Int?) -> Int {
        guard let ttlSec, ttlSec > 0 else { return 300 }
        return min(ttlSec, 3600)
    }

    static func consume(at url: URL) -> Data? {
        guard !url.lastPathComponent.hasSuffix(".tmp") else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= maxRequestBytes else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return data
    }
}

final class HostBridgeWatcher: @unchecked Sendable {
    private let bridgeRoot: URL
    private let forwarder: HostPortForwarder
    private let open: @Sendable (URL) -> Void
    private let lock = NSLock()
    private let scanQueue = DispatchQueue(label: "dev.dory.hostbridge.scan")
    private var sources: [String: [DispatchSourceFileSystemObject]] = [:]

    init(bridgeRoot: URL, forwarder: HostPortForwarder, open: @escaping @Sendable (URL) -> Void) {
        self.bridgeRoot = bridgeRoot
        self.forwarder = forwarder
        self.open = open
    }

    func startWatching(machine: String) {
        lock.lock()
        let already = sources[machine] != nil
        lock.unlock()
        guard !already else { return }
        let openDir = bridgeRoot.appendingPathComponent(machine).appendingPathComponent("open")
        let forwardDir = bridgeRoot.appendingPathComponent(machine).appendingPathComponent("forward")
        for dir in [openDir, forwardDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var made: [DispatchSourceFileSystemObject] = []
        for dir in [openDir, forwardDir] {
            let fd = Darwin.open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: scanQueue)
            source.setEventHandler { [weak self] in self?.performScan(machine: machine) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            made.append(source)
        }
        lock.lock(); sources[machine] = made; lock.unlock()
        scanOnce(machine: machine)
    }

    func stopWatching(machine: String) {
        lock.lock()
        let made = sources.removeValue(forKey: machine)
        lock.unlock()
        made?.forEach { $0.cancel() }
    }

    func watchedMachines() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(sources.keys)
    }

    func scanOnce(machine: String) {
        scanQueue.sync { performScan(machine: machine) }
    }

    private func performScan(machine: String) {
        let base = bridgeRoot.appendingPathComponent(machine)
        drainForward(base.appendingPathComponent("forward"), machine: machine)
        drainOpen(base.appendingPathComponent("open"))
    }

    private func drainForward(_ dir: URL, machine: String) {
        for file in files(in: dir) {
            guard let data = HostBridge.consume(at: file),
                  let req = HostBridge.decodeForward(data),
                  HostBridge.allowedForwardPort(req.port) else { continue }
            _ = forwarder.forwardLoopback(machine: machine, port: req.port, ttl: HostBridge.resolvedTTL(req.ttlSec))
        }
    }

    private func drainOpen(_ dir: URL) {
        for file in files(in: dir) {
            guard let data = HostBridge.consume(at: file),
                  let req = HostBridge.decodeOpen(data),
                  let url = HostBridge.allowedURL(req.url) else { continue }
            open(url)
        }
    }

    private func files(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
