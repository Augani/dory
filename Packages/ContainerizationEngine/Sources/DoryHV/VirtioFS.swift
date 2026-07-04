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
        let virtqueue = transport.queues[1]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let response = server.handle(request: chain.readBytes())
            let written = chain.writeBytes(response)
            let wants = (try? virtqueue.push(chain, written: written)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }
}
