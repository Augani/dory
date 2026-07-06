import Darwin
import Foundation
import Hypervisor

public struct VirtioGPUCapset: Sendable, Equatable {
    public var id: UInt32
    public var maxVersion: UInt32
    public var data: [UInt8]

    public init(id: UInt32, maxVersion: UInt32, data: [UInt8]) {
        self.id = id
        self.maxVersion = maxVersion
        self.data = data
    }
}

public struct VirtioGPUMemoryEntry {
    public var pointer: UnsafeMutableRawPointer
    public var length: Int

    public init(pointer: UnsafeMutableRawPointer, length: Int) {
        self.pointer = pointer
        self.length = length
    }
}

/// A host-visible blob mapping produced by the renderer: the host pointer virglrenderer owns (to be
/// hv_vm_map'd into the guest window), its size, and the guest-facing cache map info.
public struct VirtioGPUBlobMapping {
    public var hostPointer: UnsafeMutableRawPointer
    public var size: UInt64
    public var mapInfo: UInt32

    public init(hostPointer: UnsafeMutableRawPointer, size: UInt64, mapInfo: UInt32) {
        self.hostPointer = hostPointer
        self.size = size
        self.mapInfo = mapInfo
    }
}

public struct VirtioGPUResourceCreate3D {
    public var resourceID: UInt32
    public var target: UInt32
    public var format: UInt32
    public var bind: UInt32
    public var width: UInt32
    public var height: UInt32
    public var depth: UInt32
    public var arraySize: UInt32
    public var lastLevel: UInt32
    public var samples: UInt32
    public var flags: UInt32
}

public struct VirtioGPUTransfer3D {
    public var resourceID: UInt32
    public var contextID: UInt32
    public var level: UInt32
    public var stride: UInt32
    public var layerStride: UInt32
    public var offset: UInt64
    public var box: [UInt32]
}

public protocol VirtioGPURenderer: AnyObject {
    var capsets: [VirtioGPUCapset] { get }
    func createContext(id: UInt32, flags: UInt32, name: String) throws
    func destroyContext(id: UInt32) throws
    func attachResource(contextID: UInt32, resourceID: UInt32) throws
    func detachResource(contextID: UInt32, resourceID: UInt32) throws
    func submit3D(contextID: UInt32, command: [UInt8]) throws
    func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws
    func createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64,
        entries: [VirtioGPUMemoryEntry]
    ) throws
    func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws
    func detachBacking(resourceID: UInt32) throws
    func unrefResource(resourceID: UInt32) throws
    func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping
    func unmapBlob(resourceID: UInt32) throws
    func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws
    func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws
    /// Registers a fence that must call `onFenceSignaled` (possibly from another thread) once all
    /// GPU work submitted before it has completed. Context fences order per (context, ring); plain
    /// fences ride the global ctx0 timeline and signal as (0, 0, id).
    func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws
    var onFenceSignaled: ((_ contextID: UInt32, _ ringIndex: UInt32, _ fenceID: UInt64) -> Void)? { get set }
}

extension VirtioGPUMemoryEntry: @unchecked Sendable {}

/// The guest-physical window into which host-visible Venus blobs are mapped. Unlike a normal RAM
/// region this is NOT pre-backed: virglrenderer owns each blob's host memory (a Metal-backed,
/// page-aligned allocation), so on `resource_map` we hv_vm_map that renderer-owned pointer into the
/// window at the guest-requested offset — the same zero-copy model libkrun/krunkit use on macOS.
/// Pre-mapping the whole window would make per-blob hv_vm_map fail (the GPA is already mapped).
public final class VirtioGPUHostVisibleMemory: @unchecked Sendable {
    public let guestBase: UInt64
    public let length: UInt64

    private let lock = NSLock()
    private var mappings: [UInt32: (offset: UInt64, size: UInt64)] = [:]

    public init(guestBase: UInt64, length: UInt64 = 256 * 1024 * 1024) throws {
        guard length > 0,
              guestBase.isMultiple(of: HostPage.size),
              length.isMultiple(of: HostPage.size),
              length <= UInt64(Int.max) else {
            throw VMError.invalidConfiguration("invalid virtio-gpu host-visible memory window")
        }
        self.guestBase = guestBase
        self.length = length
    }

    deinit {
        lock.lock()
        for (_, mapping) in mappings {
            _ = hv_vm_unmap(guestBase + mapping.offset, Int(mapping.size))
        }
        lock.unlock()
    }

    /// hv_vm_map the renderer-owned `hostPointer` into the window at `offset`. `hostPointer` stays
    /// owned by virglrenderer and must never be munmap'd here — it is released via resource_unmap.
    public func map(resourceID: UInt32, hostPointer: UnsafeMutableRawPointer, offset: UInt64, size: UInt64) throws {
        let mapSize = size.roundedUpToMultiple(of: HostPage.size)
        guard offset.isMultiple(of: HostPage.size),
              mapSize > 0, offset <= length, mapSize <= length - offset else {
            throw VMError.guestMemoryFault(address: guestBase + offset, count: size)
        }
        lock.lock()
        defer { lock.unlock() }
        if let previous = mappings.removeValue(forKey: resourceID) {
            _ = hv_vm_unmap(guestBase + previous.offset, Int(previous.size))
        }
        try hvCheck(
            hv_vm_map(hostPointer, guestBase + offset, Int(mapSize), hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE)),
            "virtio-gpu host-visible blob hv_vm_map"
        )
        mappings[resourceID] = (offset, mapSize)
    }

    public func unmap(resourceID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let mapping = mappings.removeValue(forKey: resourceID) {
            _ = hv_vm_unmap(guestBase + mapping.offset, Int(mapping.size))
        }
    }
}

private extension UInt64 {
    func roundedUpToMultiple(of alignment: UInt64) -> UInt64 {
        guard alignment > 0 else { return self }
        let remainder = self % alignment
        return remainder == 0 ? self : self + (alignment - remainder)
    }
}

/// Experimental virtio-gpu device.
///
/// Bootstrap mode keeps the Linux driver bring-up surface deliberately inert. Venus mode advertises
/// the Linux UAPI feature bits only when a host renderer is supplied, then forwards blob/context
/// commands to that renderer.
public final class VirtioGPU: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider {
    public let deviceID: UInt32 = 16
    public let queueCount = 2
    public let deviceFeatures: UInt64
    public let sharedMemoryRegions: [VirtioSharedMemoryRegion]

    private let scanoutCount: UInt32
    private let renderer: VirtioGPURenderer?
    private let capsets: [VirtioGPUCapset]
    private let hostVisibleMemory: VirtioGPUHostVisibleMemory?
    private var resourceEntries: [UInt32: [VirtioGPUMemoryEntry]] = [:]
    private var blobResources: [UInt32: BlobResource] = [:]

    // Real fence signalling: a fenced command's descriptor is held here and completed only when the
    // renderer signals the fence (from its own thread), per the virtio-gpu contract — responding
    // immediately would tell the guest its GPU work finished before it did.
    private struct FenceKey: Hashable {
        var contextID: UInt32
        var ringIndex: UInt32
    }

    private struct PendingFence {
        var fenceID: UInt64
        var response: [UInt8]
        var chain: VirtqueueChain
    }

    private let fenceLock = NSLock()
    private var pendingFences: [FenceKey: [PendingFence]] = [:]
    private weak var lastTransport: VirtioMMIOTransport?

    private enum HeaderFlag {
        static let fence: UInt32 = 1 << 0
        static let infoRingIndex: UInt32 = 1 << 1
    }

    private enum Command {
        static let getDisplayInfo: UInt32 = 0x0100
        static let resourceCreate2D: UInt32 = 0x0101
        static let resourceUnref: UInt32 = 0x0102
        static let setScanout: UInt32 = 0x0103
        static let resourceFlush: UInt32 = 0x0104
        static let transferToHost2D: UInt32 = 0x0105
        static let resourceAttachBacking: UInt32 = 0x0106
        static let resourceDetachBacking: UInt32 = 0x0107
        static let getCapsetInfo: UInt32 = 0x0108
        static let getCapset: UInt32 = 0x0109
        static let resourceCreateBlob: UInt32 = 0x010C
        static let setScanoutBlob: UInt32 = 0x010D
        static let ctxCreate: UInt32 = 0x0200
        static let ctxDestroy: UInt32 = 0x0201
        static let ctxAttachResource: UInt32 = 0x0202
        static let ctxDetachResource: UInt32 = 0x0203
        static let resourceCreate3D: UInt32 = 0x0204
        static let transferToHost3D: UInt32 = 0x0205
        static let transferFromHost3D: UInt32 = 0x0206
        static let submit3D: UInt32 = 0x0207
        static let resourceMapBlob: UInt32 = 0x0208
        static let resourceUnmapBlob: UInt32 = 0x0209
        static let updateCursor: UInt32 = 0x0300
        static let moveCursor: UInt32 = 0x0301
    }

    private enum Response {
        static let okNoData: UInt32 = 0x1100
        static let okDisplayInfo: UInt32 = 0x1101
        static let okCapsetInfo: UInt32 = 0x1102
        static let okCapset: UInt32 = 0x1103
        static let okMapInfo: UInt32 = 0x1106
        static let errorUnspecified: UInt32 = 0x1200
        static let errorInvalidParameter: UInt32 = 0x1202
    }

    private enum Feature {
        static let virgl: UInt64 = 1 << 0
        static let resourceUUID: UInt64 = 1 << 2
        static let resourceBlob: UInt64 = 1 << 3
        static let contextInit: UInt64 = 1 << 4
    }

    private enum Capset {
        static let venus: UInt32 = 4
    }

    private struct BlobResource {
        var size: UInt64
    }

    /// - Parameters:
    ///   - hostMemoryBase: Guest physical base of the virtio-gpu host-visible memory window.
    ///   - hostMemorySize: Size of the host-visible memory window reported through virtio-mmio.
    public init(
        hostMemoryBase: UInt64,
        hostMemorySize: UInt64 = 256 * 1024 * 1024,
        scanoutCount: UInt32 = 0,
        renderer: VirtioGPURenderer? = nil,
        hostVisibleMemory: VirtioGPUHostVisibleMemory? = nil
    ) {
        self.renderer = renderer
        self.capsets = renderer?.capsets ?? []
        self.deviceFeatures = renderer == nil
            ? 0
            : Feature.virgl | Feature.resourceUUID | Feature.resourceBlob | Feature.contextInit
        self.sharedMemoryRegions = [
            VirtioSharedMemoryRegion(id: 1, guestBase: hostMemoryBase, length: hostVisibleMemory?.length ?? hostMemorySize)
        ]
        self.scanoutCount = scanoutCount
        self.hostVisibleMemory = hostVisibleMemory
        renderer?.onFenceSignaled = { [weak self] contextID, ringIndex, fenceID in
            self?.fenceSignaled(contextID: contextID, ringIndex: ringIndex, fenceID: fenceID)
        }
    }

    public var configSpace: [UInt8] {
        var config = [UInt8]()
        config.appendLE(UInt32(0))     // events_read
        config.appendLE(UInt32(0))     // events_clear
        config.appendLE(scanoutCount)  // num_scanouts
        config.appendLE(UInt32(capsets.count))   // num_capsets
        return config
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 0 || queue == 1 else { return }
        fenceLock.lock()
        lastTransport = transport
        fenceLock.unlock()
        let virtqueue = transport.queues[queue]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let request = chain.readBytes()
            let response = process(request: request, cursorQueue: queue == 1, transport: transport)
            if queue == 0, deferForFence(request: request, response: response, chain: chain) {
                continue
            }
            let written = chain.writeBytes(response)
            let wants = (try? virtqueue.push(chain, written: written)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    /// Holds a successfully processed, fenced command's descriptor until the renderer signals the
    /// fence. Returns false (respond immediately) for unfenced commands, errors — whose response
    /// still carries the fence id, which the guest treats as the signal — and fence-registration
    /// failures, so a broken fence path degrades to the old eager completion instead of hanging.
    private func deferForFence(request: [UInt8], response: [UInt8], chain: VirtqueueChain) -> Bool {
        guard let renderer, request.count >= 24, response.count >= 4 else { return false }
        let flags = request.leUInt32(at: 4)
        guard flags & HeaderFlag.fence != 0 else { return false }
        guard response.leUInt32(at: 0) & 0xFF00 == 0x1100 else { return false }
        let fenceID = request.leUInt64(at: 8)
        let contextID = request.leUInt32(at: 16)
        let ringIndex = UInt32(request[20])
        let contextFence = flags & HeaderFlag.infoRingIndex != 0
        do {
            try renderer.createFence(contextID: contextID, ringIndex: ringIndex, fenceID: fenceID, contextFence: contextFence)
        } catch {
            return false
        }
        // ctx0 fences signal without context/ring coordinates, so they queue under (0, 0).
        let key = contextFence
            ? FenceKey(contextID: contextID, ringIndex: ringIndex)
            : FenceKey(contextID: 0, ringIndex: 0)
        fenceLock.lock()
        pendingFences[key, default: []].append(PendingFence(fenceID: fenceID, response: response, chain: chain))
        fenceLock.unlock()
        return true
    }

    /// Renderer-thread entry: completes every pending descriptor on the signaled timeline whose
    /// fence id is covered (fences signal in creation order within a ring).
    private func fenceSignaled(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64) {
        let key = FenceKey(contextID: contextID, ringIndex: ringIndex)
        fenceLock.lock()
        var completed = [PendingFence]()
        if var waiting = pendingFences[key] {
            // The legacy ctx0 API carries 32-bit ids on the callback; compare within that width.
            let signaled: (PendingFence) -> Bool = key == FenceKey(contextID: 0, ringIndex: 0)
                ? { UInt32(truncatingIfNeeded: $0.fenceID) <= UInt32(truncatingIfNeeded: fenceID) }
                : { $0.fenceID <= fenceID }
            completed = waiting.filter(signaled)
            waiting.removeAll(where: signaled)
            pendingFences[key] = waiting.isEmpty ? nil : waiting
        }
        let transport = lastTransport
        fenceLock.unlock()
        guard !completed.isEmpty, let transport else { return }
        transport.withQueueLock {
            var interrupt = false
            for pending in completed {
                let written = pending.chain.writeBytes(pending.response)
                let wants = (try? transport.queues[0].push(pending.chain, written: written)) ?? false
                interrupt = interrupt || wants
            }
            if interrupt {
                transport.notifyUsed()
            }
        }
    }

    private func process(request: [UInt8], cursorQueue: Bool, transport: VirtioMMIOTransport) -> [UInt8] {
        guard request.count >= 4 else {
            return responseHeader(type: Response.errorUnspecified, request: request)
        }

        let command = request.leUInt32(at: 0)
        if cursorQueue {
            switch command {
            case Command.updateCursor, Command.moveCursor:
                return responseHeader(type: Response.okNoData, request: request)
            default:
                return responseHeader(type: Response.errorInvalidParameter, request: request)
            }
        }

        switch command {
        case Command.getDisplayInfo:
            var response = responseHeader(type: Response.okDisplayInfo, request: request)
            response.append(contentsOf: repeatElement(UInt8(0), count: 16 * 24))
            return response
        case Command.getCapsetInfo:
            return capsetInfoResponse(request: request)
        case Command.getCapset:
            return capsetResponse(request: request)
        case Command.ctxCreate:
            return rendererCommand(request: request) { renderer in
                guard request.count >= 96 else { throw VMError.unexpectedExit("short virtio-gpu ctx_create") }
                let contextID = request.leUInt32(at: 16)
                let nameLength = min(Int(request.leUInt32(at: 24)), 64)
                let contextInit = request.leUInt32(at: 28)
                let nameBytes = request[32..<(32 + nameLength)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                try renderer.createContext(id: contextID, flags: contextInit & 0xff, name: name)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDestroy:
            return rendererCommand(request: request) { renderer in
                try renderer.destroyContext(id: request.leUInt32(at: 16))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxAttachResource:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                try renderer.attachResource(contextID: request.leUInt32(at: 16), resourceID: request.leUInt32(at: 24))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDetachResource:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                try renderer.detachResource(contextID: request.leUInt32(at: 16), resourceID: request.leUInt32(at: 24))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.submit3D:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let size = Int(request.leUInt32(at: 24))
                guard request.count >= 32 + size else { throw VMError.unexpectedExit("short virtio-gpu submit_3d") }
                try renderer.submit3D(contextID: request.leUInt32(at: 16), command: Array(request[32..<(32 + size)]))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreate3D:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 72)
                let resource = VirtioGPUResourceCreate3D(
                    resourceID: request.leUInt32(at: 24),
                    target: request.leUInt32(at: 28),
                    format: request.leUInt32(at: 32),
                    bind: request.leUInt32(at: 36),
                    width: request.leUInt32(at: 40),
                    height: request.leUInt32(at: 44),
                    depth: request.leUInt32(at: 48),
                    arraySize: request.leUInt32(at: 52),
                    lastLevel: request.leUInt32(at: 56),
                    samples: request.leUInt32(at: 60),
                    flags: request.leUInt32(at: 64)
                )
                try renderer.createResource3D(resource, entries: resourceEntries[resource.resourceID] ?? [])
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceAttachBacking:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                let entries = try memoryEntries(from: request, count: request.leUInt32(at: 28), offset: 32, transport: transport)
                resourceEntries[resourceID] = entries
                try renderer.attachBacking(resourceID: resourceID, entries: entries)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceDetachBacking:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                try renderer.detachBacking(resourceID: resourceID)
                resourceEntries.removeValue(forKey: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreateBlob:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 56)
                let resourceID = request.leUInt32(at: 24)
                let size = request.leUInt64(at: 48)
                let entries = try memoryEntries(from: request, count: request.leUInt32(at: 36), offset: 56, transport: transport)
                try renderer.createBlob(
                    resourceID: resourceID,
                    contextID: request.leUInt32(at: 16),
                    blobMemory: request.leUInt32(at: 28),
                    blobFlags: request.leUInt32(at: 32),
                    blobID: request.leUInt64(at: 40),
                    size: size,
                    entries: entries
                )
                resourceEntries[resourceID] = entries
                blobResources[resourceID] = BlobResource(size: size)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceMapBlob:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 40)
                let resourceID = request.leUInt32(at: 24)
                let offset = request.leUInt64(at: 32)
                guard let blob = blobResources[resourceID], let hostVisibleMemory else {
                    FileHandle.standardError.write(Data("dory-gpu: mapBlob res=\(resourceID) missing blob/window\n".utf8))
                    throw VMError.invalidConfiguration("virtio-gpu blob map without host-visible window")
                }
                // virglrenderer owns the blob's host memory; ask it to map, then expose that pointer to
                // the guest by hv_vm_mapping it into the window at the requested offset.
                let mapping = try renderer.mapBlob(resourceID: resourceID)
                try hostVisibleMemory.map(
                    resourceID: resourceID,
                    hostPointer: mapping.hostPointer,
                    offset: offset,
                    size: mapping.size != 0 ? mapping.size : blob.size
                )
                var response = responseHeader(type: Response.okMapInfo, request: request)
                response.appendLE(mapping.mapInfo)
                response.appendLE(UInt32(0))
                return response
            }
        case Command.resourceUnmapBlob:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                hostVisibleMemory?.unmap(resourceID: resourceID)
                try renderer.unmapBlob(resourceID: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceUnref:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                hostVisibleMemory?.unmap(resourceID: resourceID)
                try renderer.unrefResource(resourceID: resourceID)
                resourceEntries.removeValue(forKey: resourceID)
                blobResources.removeValue(forKey: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferToHost3D:
            return rendererCommand(request: request) { renderer in
                let transfer = try transfer3D(from: request)
                try renderer.transferToHost3D(transfer, entries: resourceEntries[transfer.resourceID] ?? [])
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferFromHost3D:
            return rendererCommand(request: request) { renderer in
                let transfer = try transfer3D(from: request)
                try renderer.transferFromHost3D(transfer, entries: resourceEntries[transfer.resourceID] ?? [])
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreate2D, Command.setScanout, Command.resourceFlush,
             Command.transferToHost2D, Command.setScanoutBlob:
            return responseHeader(type: Response.okNoData, request: request)
        default:
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    private func capsetInfoResponse(request: [UInt8]) -> [UInt8] {
        guard request.count >= 32 else { return responseHeader(type: Response.errorInvalidParameter, request: request) }
        let index = Int(request.leUInt32(at: 24))
        guard index < capsets.count else { return responseHeader(type: Response.errorInvalidParameter, request: request) }
        let capset = capsets[index]
        var response = responseHeader(type: Response.okCapsetInfo, request: request)
        response.appendLE(capset.id)
        response.appendLE(capset.maxVersion)
        response.appendLE(UInt32(capset.data.count))
        response.appendLE(UInt32(0))
        return response
    }

    private func capsetResponse(request: [UInt8]) -> [UInt8] {
        guard request.count >= 32 else { return responseHeader(type: Response.errorInvalidParameter, request: request) }
        let id = request.leUInt32(at: 24)
        let version = request.leUInt32(at: 28)
        guard let capset = capsets.first(where: { $0.id == id }),
              version <= capset.maxVersion else {
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
        var response = responseHeader(type: Response.okCapset, request: request)
        response.append(contentsOf: capset.data)
        return response
    }

    private func rendererCommand(
        request: [UInt8],
        _ body: (VirtioGPURenderer) throws -> [UInt8]
    ) -> [UInt8] {
        guard let renderer else { return responseHeader(type: Response.errorInvalidParameter, request: request) }
        do {
            return try body(renderer)
        } catch {
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    private func memoryEntries(
        from request: [UInt8],
        count: UInt32,
        offset: Int,
        transport: VirtioMMIOTransport
    ) throws -> [VirtioGPUMemoryEntry] {
        let total = Int(count)
        guard request.count >= offset + total * 16 else {
            throw VMError.unexpectedExit("short virtio-gpu memory entry list")
        }
        var entries = [VirtioGPUMemoryEntry]()
        entries.reserveCapacity(total)
        for index in 0..<total {
            let base = offset + index * 16
            let guestAddress = request.leUInt64(at: base)
            let length = request.leUInt32(at: base + 8)
            guard length > 0 else { continue }
            let pointer = try transport.hostPointer(at: guestAddress, count: UInt64(length))
            entries.append(VirtioGPUMemoryEntry(pointer: pointer, length: Int(length)))
        }
        return entries
    }

    private func transfer3D(from request: [UInt8]) throws -> VirtioGPUTransfer3D {
        try requireLength(request, 72)
        return VirtioGPUTransfer3D(
            resourceID: request.leUInt32(at: 56),
            contextID: request.leUInt32(at: 16),
            level: request.leUInt32(at: 60),
            stride: request.leUInt32(at: 64),
            layerStride: request.leUInt32(at: 68),
            offset: request.leUInt64(at: 48),
            box: [
                request.leUInt32(at: 24),
                request.leUInt32(at: 28),
                request.leUInt32(at: 32),
                request.leUInt32(at: 36),
                request.leUInt32(at: 40),
                request.leUInt32(at: 44),
            ]
        )
    }

    private func responseHeader(type: UInt32, request: [UInt8]) -> [UInt8] {
        var response = [UInt8]()
        response.appendLE(type)
        // Echo the fence flags: a response completing a fenced command must carry FLAG_FENCE (and
        // the ring flag) alongside the fence id below, or the guest never treats the fence as done.
        let requestFlags = request.count >= 8 ? request.leUInt32(at: 4) : 0
        response.appendLE(requestFlags & (HeaderFlag.fence | HeaderFlag.infoRingIndex))
        response.appendLE(request.count >= 16 ? request.leUInt64(at: 8) : UInt64(0))
        response.appendLE(request.count >= 20 ? request.leUInt32(at: 16) : UInt32(0))
        response.append(request.count >= 21 ? request[20] : UInt8(0))
        response.append(contentsOf: [0, 0, 0])
        return response
    }

    private func requireLength(_ bytes: [UInt8], _ length: Int) throws {
        guard bytes.count >= length else {
            throw VMError.unexpectedExit("short virtio-gpu command")
        }
    }
}
