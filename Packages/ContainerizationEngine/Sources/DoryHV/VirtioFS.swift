import Foundation

public enum VirtioFSError: Error, Equatable {
    case invalidTag(String)
    case invalidDaxWindow
}

public struct VirtioFSDaxConfiguration: Equatable, Sendable {
    public var guestBase: UInt64
    public var length: UInt64

    public init(guestBase: UInt64, length: UInt64 = DaxWindow.defaultSize) {
        self.guestBase = guestBase
        self.length = length
    }
}

public final class VirtioFS: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider {
    public static let tagByteCount = 36
    public static let notificationFeature: UInt64 = 1 << 0

    public let deviceID: UInt32 = 26
    public let queueCount = 2  // 0 = hiprio, 1 = request
    public let tag: String
    public let hostFS: HostFS
    public let daxConfiguration: VirtioFSDaxConfiguration?
    private let server: FuseServer
    private let stats: VirtioFSStats?
    private let inlineRequests: Bool
    public var deviceFeatures: UInt64 { 0 }

    // Small metadata-heavy workloads are latency-bound: dispatching every FUSE request to another
    // thread costs more than the host syscall. Inline processing is therefore the default, with an
    // environment opt-out for workloads that need the older worker-only behavior. The worker pool is
    // still used when inline mode is disabled and remains available for experimentation.
    private let workers = DispatchQueue(label: "dory-hv.virtiofs.worker", qos: .userInteractive, attributes: .concurrent)
    private let maxDrainers = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount))
    private let drainLock = NSLock()
    private var activeDrainers = 0
    private var kickGeneration = 0

    public init(tag: String, hostFS: HostFS, daxConfiguration: VirtioFSDaxConfiguration? = nil) throws {
        let bytes = Array(tag.utf8)
        guard !bytes.isEmpty, bytes.count < Self.tagByteCount else {
            throw VirtioFSError.invalidTag(tag)
        }
        if let daxConfiguration {
            guard daxConfiguration.guestBase.isMultiple(of: DaxWindow.pageSize),
                  daxConfiguration.length > 0,
                  daxConfiguration.length.isMultiple(of: DaxWindow.pageSize) else {
                throw VirtioFSError.invalidDaxWindow
            }
        }
        self.tag = tag
        self.hostFS = hostFS
        self.daxConfiguration = daxConfiguration
        self.stats = VirtioFSStats.fromEnvironment(tag: tag)
        self.inlineRequests = Self.inlineRequestsFromEnvironment()
        let daxWindow = try daxConfiguration.map {
            try DaxWindow(guestBase: $0.guestBase, length: $0.length, backend: FileBackedDaxMappingBackend())
        }
        self.server = FuseServer(hostFS: hostFS, daxWindow: daxWindow)
    }

    public var sharedMemoryRegions: [VirtioSharedMemoryRegion] {
        guard let daxConfiguration else { return [] }
        return [VirtioSharedMemoryRegion(id: 0, guestBase: daxConfiguration.guestBase, length: daxConfiguration.length)]
    }

    public var configSpace: [UInt8] {
        var data = [UInt8](repeating: 0, count: Self.tagByteCount)
        let tagBytes = Array(tag.utf8)
        data.replaceSubrange(0..<tagBytes.count, with: tagBytes)
        var requestQueues = UInt32(1).littleEndian
        withUnsafeBytes(of: &requestQueues) { data.append(contentsOf: $0) }
        return data
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 1 else { return }
        if inlineRequests {
            drainInline(transport: transport)
            return
        }
        // Spawn one more drainer unless the pool is already saturated; the drainer processes every
        // available chain, so a lone kick costs one drainer and a burst of concurrent readers keeps
        // up to maxDrainers of them busy. The vCPU thread returns from the exit immediately.
        let spawn: Bool = drainLock.withLock {
            kickGeneration &+= 1
            guard activeDrainers < maxDrainers else { return false }
            activeDrainers += 1
            return true
        }
        guard spawn else { return }
        workers.async { [self] in drain(transport: transport) }
    }

    private func drainInline(transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[1]
        var shouldNotify = false
        while let chain = (transport.withQueueLock { (try? virtqueue.pop()) ?? nil }) {
            if process(chain: chain, virtqueue: virtqueue, transport: transport) {
                shouldNotify = true
            }
        }
        if shouldNotify {
            transport.notifyUsed()
        }
    }

    private func drain(transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[1]
        while true {
            let generation = drainLock.withLock { kickGeneration }
            var shouldNotify = false
            while let chain = (transport.withQueueLock { (try? virtqueue.pop()) ?? nil }) {
                if process(chain: chain, virtqueue: virtqueue, transport: transport) {
                    shouldNotify = true
                }
            }
            if shouldNotify {
                transport.notifyUsed()
            }
            // Queue looks empty. Exit only if no kick landed while we were draining; otherwise a
            // chain may have arrived in the race window and we must sweep again. drainLock is never
            // held while taking the transport queue lock, so this cannot invert lock order.
            let exit: Bool = drainLock.withLock {
                guard kickGeneration == generation else { return false }
                activeDrainers -= 1
                return true
            }
            if exit { break }
        }
    }

    @discardableResult
    private func process(chain: VirtqueueChain, virtqueue: Virtqueue, transport: VirtioMMIOTransport) -> Bool {
        let request = chain.readBytes()
        var written = 0
        var decoded: (header: FuseInHeader, opcode: FuseOpcode)?
        if chain.hasWritableSegments,
           let header = try? FuseProtocol.decodeInHeader(request),
           header.length >= UInt32(FuseInHeader.byteCount), Int(header.length) <= request.count,
           let opcode = FuseOpcode(rawValue: header.opcode) {
            decoded = (header, opcode)
            stats?.record(opcode)
            if opcode == .lookup {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeLookupMissResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .getattr {
                written = server.writeGetattrResponse(header: header, writable: chain.writableSegments)
            } else if opcode == .read {
                // Zero-copy fast path: preadv the payload straight into the guest's read buffers.
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeReadResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .write {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeWriteResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .release || opcode == .releasedir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeReleaseResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .flush {
                written = server.writeEmptySuccessResponse(unique: header.unique, writable: chain.writableSegments)
            } else if opcode == .getxattr {
                written = server.writeGetXattrNoDataResponse(header: header, writable: chain.writableSegments)
            } else if opcode == .create {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeCreateResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .mkdir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeMkdirResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .unlink || opcode == .rmdir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeRemoveResponse(header: header, opcode: opcode, payload: payload, writable: chain.writableSegments)
            }
        }
        if written == 0 {
            if let decoded {
                written = chain.writeBytes(server.handle(header: decoded.header, opcode: decoded.opcode, request: request))
            } else {
                written = chain.writeBytes(server.handle(request: request))
            }
        }
        return transport.withQueueLock { (try? virtqueue.push(chain, written: written)) ?? false }
    }
}

private extension VirtioFS {
    static func inlineRequestsFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_INLINE"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }
}

private final class VirtioFSStats: @unchecked Sendable {
    private let tag: String
    private let lock = NSLock()
    private var counts: [FuseOpcode: Int] = [:]
    private var total = 0

    init(tag: String) {
        self.tag = tag
    }

    static func fromEnvironment(tag: String) -> VirtioFSStats? {
        let value = ProcessInfo.processInfo.environment["DORY_FUSE_STATS"] ?? ""
        guard ["1", "true", "yes", "on"].contains(value.lowercased()) else { return nil }
        FileHandle.standardError.write(Data("dory-hv: virtiofs stats enabled tag=\(tag)\n".utf8))
        return VirtioFSStats(tag: tag)
    }

    func record(_ opcode: FuseOpcode) {
        let snapshot: (Int, [FuseOpcode: Int])? = lock.withLock {
            total += 1
            counts[opcode, default: 0] += 1
            guard total <= 20 || total.isMultiple(of: 100) else { return nil }
            return (total, counts)
        }
        guard let snapshot else { return }
        let line = snapshot.1
            .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        FileHandle.standardError.write(Data("dory-hv: virtiofs stats tag=\(tag) total=\(snapshot.0) \(line)\n".utf8))
    }
}

extension VirtioFS: @unchecked Sendable {}
