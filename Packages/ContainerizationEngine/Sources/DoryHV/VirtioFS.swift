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
    public var deviceFeatures: UInt64 { 0 }

    // Request processing must never run on the vCPU thread: a blocking pread inside the MMIO
    // queue-notify exit freezes the guest until every pending chain completes serially, collapsing
    // a deep request queue to effective depth 1. Instead each kick spawns a "drainer" on a
    // concurrent pool (unless the pool is already at capacity). A drainer loops popping chains and
    // running the FUSE handler, so a steady backlog keeps up to maxDrainers preads in flight while a
    // single request costs one dispatch. Completions publish out of order.
    private let workers = DispatchQueue(label: "dory-hv.virtiofs.worker", attributes: .concurrent)
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

    private func drain(transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[1]
        while true {
            let generation = drainLock.withLock { kickGeneration }
            while let chain = (transport.withQueueLock { (try? virtqueue.pop()) ?? nil }) {
                if process(chain: chain, virtqueue: virtqueue, transport: transport) {
                    transport.notifyUsed()
                }
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
        let response = server.handle(request: chain.readBytes())
        let written = chain.writeBytes(response)
        return transport.withQueueLock { (try? virtqueue.push(chain, written: written)) ?? false }
    }
}

extension VirtioFS: @unchecked Sendable {}
