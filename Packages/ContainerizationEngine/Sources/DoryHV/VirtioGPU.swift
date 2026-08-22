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
/// hv_vm_map'd into the guest window), its size, the guest-facing cache map info, and whether the
/// renderer API created map state which must later be explicitly released.
public struct VirtioGPUBlobMapping {
    public var hostPointer: UnsafeMutableRawPointer
    public var size: UInt64
    public var mapInfo: UInt32
    public var requiresRendererUnmap: Bool

    public init(
        hostPointer: UnsafeMutableRawPointer,
        size: UInt64,
        mapInfo: UInt32,
        requiresRendererUnmap: Bool = true
    ) {
        self.hostPointer = hostPointer
        self.size = size
        self.mapInfo = mapInfo
        self.requiresRendererUnmap = requiresRendererUnmap
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

public struct VirtioGPURect: Sendable, Equatable {
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32

    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One copied scanout update ready for a host display surface. `width` and `height` describe the
/// complete scanout, while `bytes` contains only `dirtyRect` rows at `stride` bytes per row. The
/// device never exposes guest pointers to the UI layer, and small browser repaints therefore avoid
/// copying the rest of a 4K framebuffer merely to update one damaged rectangle.
public struct VirtioGPUScanoutFrame: Sendable, Equatable {
    public var scanoutID: UInt32
    public var resourceID: UInt32
    public var format: UInt32
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var dirtyRect: VirtioGPURect
    public var bytes: Data

    public init(
        scanoutID: UInt32,
        resourceID: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        dirtyRect: VirtioGPURect,
        bytes: Data
    ) {
        self.scanoutID = scanoutID
        self.resourceID = resourceID
        self.format = format
        self.width = width
        self.height = height
        self.stride = stride
        self.dirtyRect = dirtyRect
        self.bytes = bytes
    }
}

public struct VirtioGPUStatistics: Equatable, Sendable {
    public var fences: UInt64
    public var fenceRegistrationFailures: UInt64
    public var fenceTimeouts: UInt64
    public var hasTimedOutPendingFence: Bool

    public init(
        fences: UInt64,
        fenceRegistrationFailures: UInt64,
        fenceTimeouts: UInt64,
        hasTimedOutPendingFence: Bool
    ) {
        self.fences = fences
        self.fenceRegistrationFailures = fenceRegistrationFailures
        self.fenceTimeouts = fenceTimeouts
        self.hasTimedOutPendingFence = hasTimedOutPendingFence
    }
}

/// A copied guest cursor plane ready for the host window. Cursor bytes are never exposed through
/// guest-owned pointers: the device snapshots the complete 32-bit BGRA resource at the
/// UPDATE_CURSOR command boundary and carries the guest hotspot with it.
public struct VirtioGPUCursorUpdate: Sendable, Equatable {
    public var scanoutID: UInt32
    public var resourceID: UInt32
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32
    public var hotX: UInt32
    public var hotY: UInt32
    public var bytes: Data

    public init(
        scanoutID: UInt32,
        resourceID: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        hotX: UInt32,
        hotY: UInt32,
        bytes: Data
    ) {
        self.scanoutID = scanoutID
        self.resourceID = resourceID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.hotX = hotX
        self.hotY = hotY
        self.bytes = bytes
    }
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
public final class VirtioGPU: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider, @unchecked Sendable {
    public let deviceID: UInt32 = 16
    public let queueCount = 2
    public let deviceFeatures: UInt64
    public let sharedMemoryRegions: [VirtioSharedMemoryRegion]

    private let scanoutCount: UInt32
    private let displayLock = NSLock()
    private var scanoutWidth: UInt32
    private var scanoutHeight: UInt32
    private var pendingDisplayEvents: UInt32 = 0
    private let onScanoutFrame: (@Sendable (VirtioGPUScanoutFrame) -> Void)?
    private let onScanoutResourceReleased: (@Sendable (UInt32) -> Void)?
    private let onCursorUpdate: (@Sendable (VirtioGPUCursorUpdate?) -> Void)?
    private let renderer: VirtioGPURenderer?
    private let capsets: [VirtioGPUCapset]
    private let hostVisibleMemory: VirtioGPUHostVisibleMemory?
    private var resourceEntries: [UInt32: [VirtioGPUMemoryEntry]] = [:]
    private var blobResources: [UInt32: BlobResource] = [:]
    /// UUIDs back VIRTIO_GPU_F_RESOURCE_UUID, which Linux exposes as the cross-device DRM
    /// capability required by Mesa Venus before it will create a Vulkan instance. Keep an assigned
    /// UUID stable for the lifetime of each renderer resource; the value is an opaque identity to
    /// the guest and does not imply a host dma-buf export on macOS.
    private var resourceUUIDs: [UInt32: [UInt8]] = [:]

    private struct Resource2D {
        var format: UInt32
        var width: UInt32
        var height: UInt32
        var backing: [VirtioGPUMemoryEntry] = []
    }

    private struct Resource3D {
        var format: UInt32
        var width: UInt32
        var height: UInt32
    }

    private struct ScanoutBinding {
        enum Source {
            case resource2D
            case resource3D
            case blob(format: UInt32, width: UInt32, height: UInt32, stride: UInt32, offset: UInt32)
        }

        var resourceID: UInt32
        var rect: VirtioGPURect
        var source: Source
    }

    private var resources2D: [UInt32: Resource2D] = [:]
    private var resources3D: [UInt32: Resource3D] = [:]
    private var published3DResources: Set<UInt32> = []
    /// Keep one full-resource readback allocation per renderer resource. A partial renderer
    /// transfer writes its first pixel at `offset` and then advances by `stride`; the source box's
    /// x/y coordinates are not implicitly added to the destination address. Supplying the matching
    /// full-resource offset lets later scanout extraction use ordinary resource coordinates.
    private var rendererReadbackBuffers: [UInt32: Data] = [:]
    private var scanouts: [UInt32: ScanoutBinding] = [:]
    private var cursorResourceID: UInt32?
    private var commandFailureCounts: [UInt32: Int] = [:]
    private let traceResourceLifecycle: Bool
    private var resourceTraceSequence: UInt64 = 0
    /// The cursor virtqueue reads resources created and retired on the control virtqueue. VCPU
    /// kicks may arrive concurrently, so serialize command interpretation while leaving descriptor
    /// dequeue/completion and renderer fence delivery on their existing independent locks.
    private let commandLock = NSLock()

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
        var createdAtMonotonicNanoseconds: UInt64
        var timeoutReported: Bool
    }

    private let fenceLock = NSLock()
    private var pendingFences: [FenceKey: [PendingFence]] = [:]
    private weak var lastTransport: VirtioMMIOTransport?
    private let fenceTimeoutNanoseconds: UInt64
    private var fenceCount: UInt64 = 0
    private var fenceRegistrationFailureCount: UInt64 = 0
    private var fenceTimeoutCount: UInt64 = 0

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
        static let resourceAssignUUID: UInt32 = 0x010B
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
        static let okResourceUUID: UInt32 = 0x1105
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
        var memory: UInt32
        var size: UInt64
        var mapping: VirtioGPUBlobMapping?
        var guestMapped = false
    }

    /// - Parameters:
    ///   - hostMemoryBase: Guest physical base of the virtio-gpu host-visible memory window.
    ///   - hostMemorySize: Size of the host-visible memory window reported through virtio-mmio.
    public init(
        hostMemoryBase: UInt64,
        hostMemorySize: UInt64 = 256 * 1024 * 1024,
        scanoutCount: UInt32 = 0,
        scanoutWidth: UInt32 = 1_280,
        scanoutHeight: UInt32 = 800,
        renderer: VirtioGPURenderer? = nil,
        hostVisibleMemory: VirtioGPUHostVisibleMemory? = nil,
        traceResourceLifecycle: Bool = ProcessInfo.processInfo.environment["DORY_GPU_TRACE_RESOURCES"] == "1",
        fenceTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onScanoutFrame: (@Sendable (VirtioGPUScanoutFrame) -> Void)? = nil,
        onScanoutResourceReleased: (@Sendable (UInt32) -> Void)? = nil,
        onCursorUpdate: (@Sendable (VirtioGPUCursorUpdate?) -> Void)? = nil
    ) {
        let boundedScanoutCount = min(scanoutCount, 16)
        self.renderer = renderer
        self.capsets = renderer?.capsets ?? []
        self.traceResourceLifecycle = traceResourceLifecycle
        self.fenceTimeoutNanoseconds = fenceTimeoutNanoseconds
        self.deviceFeatures = renderer == nil
            ? 0
            : Feature.virgl | Feature.resourceUUID | Feature.resourceBlob | Feature.contextInit
        self.sharedMemoryRegions = [
            VirtioSharedMemoryRegion(id: 1, guestBase: hostMemoryBase, length: hostVisibleMemory?.length ?? hostMemorySize)
        ]
        self.scanoutCount = boundedScanoutCount
        self.scanoutWidth = max(1, scanoutWidth)
        self.scanoutHeight = max(1, scanoutHeight)
        self.hostVisibleMemory = hostVisibleMemory
        self.onScanoutFrame = onScanoutFrame
        self.onScanoutResourceReleased = onScanoutResourceReleased
        self.onCursorUpdate = onCursorUpdate
        renderer?.onFenceSignaled = { [weak self] contextID, ringIndex, fenceID in
            self?.fenceSignaled(contextID: contextID, ringIndex: ringIndex, fenceID: fenceID)
        }
    }

    public var configSpace: [UInt8] {
        displayLock.lock()
        let events = pendingDisplayEvents
        let count = scanoutCount
        displayLock.unlock()
        var config = [UInt8]()
        config.appendLE(events)        // events_read
        config.appendLE(UInt32(0))     // events_clear
        config.appendLE(count)         // num_scanouts
        config.appendLE(UInt32(capsets.count))   // num_capsets
        return config
    }

    /// Publishes a new preferred scanout size and raises VIRTIO_GPU_EVENT_DISPLAY. The Linux DRM
    /// driver responds by re-reading GET_DISPLAY_INFO and issuing a real modeset, so the guest
    /// compositor renders at the Retina window's pixel dimensions instead of scaling one fixed
    /// framebuffer on the host.
    public func updateScanoutSize(
        width: UInt32,
        height: UInt32,
        transport: VirtioMMIOTransport
    ) {
        let boundedWidth = min(16_384, max(1, width))
        let boundedHeight = min(16_384, max(1, height))
        displayLock.lock()
        let changed = scanoutWidth != boundedWidth || scanoutHeight != boundedHeight
        if changed {
            scanoutWidth = boundedWidth
            scanoutHeight = boundedHeight
            pendingDisplayEvents |= 1  // VIRTIO_GPU_EVENT_DISPLAY
        }
        displayLock.unlock()
        if changed { transport.notifyConfigChange() }
    }

    public func writeConfig(offset: UInt64, value: UInt64, width: Int) {
        guard width > 0, width <= 8, offset < 8, offset + UInt64(width) > 4 else { return }
        var cleared: UInt32 = 0
        for byte in 0..<width {
            let position = Int(offset) + byte
            guard (4..<8).contains(position) else { continue }
            cleared |= UInt32((value >> UInt64(byte * 8)) & 0xFF) << UInt32((position - 4) * 8)
        }
        displayLock.lock()
        pendingDisplayEvents &= ~cleared
        displayLock.unlock()
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
            commandLock.lock()
            let response = process(
                request: request,
                cursorQueue: queue == 1,
                transport: transport
            )
            commandLock.unlock()
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
        // ctx0 fences signal without context/ring coordinates, so they queue under (0, 0).
        let key = contextFence
            ? FenceKey(contextID: contextID, ringIndex: ringIndex)
            : FenceKey(contextID: 0, ringIndex: 0)
        // Publish the waiter before creating the renderer fence. With a fast host GPU (and in
        // particular after a synchronizing readback), virglrenderer may invoke its completion
        // callback from createFence itself or immediately on another thread. Registering after
        // createFence loses that edge forever and stalls the guest compositor on its first frame.
        fenceLock.lock()
        pendingFences[key, default: []].append(PendingFence(
            fenceID: fenceID,
            response: response,
            chain: chain,
            createdAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            timeoutReported: false
        ))
        fenceLock.unlock()
        do {
            try renderer.createFence(
                contextID: contextID,
                ringIndex: ringIndex,
                fenceID: fenceID,
                contextFence: contextFence
            )
        } catch {
            fenceLock.lock()
            if var waiting = pendingFences[key] {
                waiting.removeAll { $0.fenceID == fenceID }
                pendingFences[key] = waiting.isEmpty ? nil : waiting
            }
            fenceRegistrationFailureCount = Self.saturatingAdd(
                fenceRegistrationFailureCount,
                1
            )
            fenceLock.unlock()
            return false
        }
        fenceLock.withLock {
            fenceCount = Self.saturatingAdd(fenceCount, 1)
        }
        return true
    }

    public var statistics: VirtioGPUStatistics {
        fenceLock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            var newlyTimedOut: UInt64 = 0
            var hasTimedOutPendingFence = false
            for key in Array(pendingFences.keys) {
                guard var waiting = pendingFences[key] else { continue }
                for index in waiting.indices {
                    if !waiting[index].timeoutReported {
                        let started = waiting[index].createdAtMonotonicNanoseconds
                        let age = now >= started ? now - started : 0
                        if age >= fenceTimeoutNanoseconds {
                            waiting[index].timeoutReported = true
                            newlyTimedOut = Self.saturatingAdd(newlyTimedOut, 1)
                        }
                    }
                    hasTimedOutPendingFence =
                        hasTimedOutPendingFence || waiting[index].timeoutReported
                }
                pendingFences[key] = waiting
            }
            fenceTimeoutCount = Self.saturatingAdd(fenceTimeoutCount, newlyTimedOut)
            return VirtioGPUStatistics(
                fences: fenceCount,
                fenceRegistrationFailures: fenceRegistrationFailureCount,
                fenceTimeouts: fenceTimeoutCount,
                hasTimedOutPendingFence: hasTimedOutPendingFence
            )
        }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
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
            return cursorCommand(command, request: request)
        }

        switch command {
        case Command.getDisplayInfo:
            displayLock.lock()
            let width = scanoutWidth
            let height = scanoutHeight
            let count = scanoutCount
            displayLock.unlock()
            var response = responseHeader(type: Response.okDisplayInfo, request: request)
            for index in 0..<16 {
                response.appendLE(UInt32(0))
                response.appendLE(UInt32(0))
                response.appendLE(index < count ? width : 0)
                response.appendLE(index < count ? height : 0)
                response.appendLE(index < count ? UInt32(1) : 0)
                response.appendLE(UInt32(0))
            }
            return response
        case Command.resourceCreate2D:
            return scanoutCommand(request: request) {
                try requireLength(request, 40)
                let resourceID = request.leUInt32(at: 24)
                let format = request.leUInt32(at: 28)
                let width = request.leUInt32(at: 32)
                let height = request.leUInt32(at: 36)
                guard resourceID != 0,
                      resources2D[resourceID] == nil,
                      resources3D[resourceID] == nil,
                      blobResources[resourceID] == nil,
                      width > 0, height > 0,
                      width <= 16_384, height <= 16_384,
                      Self.isSupportedScanoutFormat(format),
                      UInt64(width) * UInt64(height) * 4 <= UInt64(Int.max) else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu 2D resource")
                }
                // VirGL clients may use a RESOURCE_CREATE_2D allocation as a texture after
                // attaching it to a renderer context. Keep the renderer's global resource table in
                // lockstep with the device-side scanout table, matching QEMU's virgl path. Without
                // this registration virgl_renderer_ctx_attach_resource silently ignores the ID and
                // a later sampler-view creation fails as an illegal resource.
                if let renderer {
                    try renderer.createResource3D(
                        VirtioGPUResourceCreate3D(
                            resourceID: resourceID,
                            target: 2,
                            format: format,
                            bind: 1 << 1,
                            width: width,
                            height: height,
                            depth: 1,
                            arraySize: 1,
                            lastLevel: 0,
                            samples: 0,
                            flags: 1
                        ),
                        entries: []
                    )
                }
                resources2D[resourceID] = Resource2D(
                    format: format,
                    width: width,
                    height: height
                )
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.setScanout:
            return scanoutCommand(request: request) {
                try requireLength(request, 48)
                let scanoutID = request.leUInt32(at: 40)
                let resourceID = request.leUInt32(at: 44)
                guard scanoutID < scanoutCount else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu scanout id")
                }
                // Linux disables a scanout with resource_id=0 while changing modes. The rectangle
                // is ignored by the protocol in that case and is commonly all zeroes, so do not
                // reject the legitimate disable before inspecting the resource id.
                if resourceID == 0 {
                    let previous = scanouts.removeValue(forKey: scanoutID)
                    if let previous, case .blob = previous.source, let renderer {
                        try releaseBlobMappingIfUnused(resourceID: previous.resourceID, renderer: renderer)
                    }
                    return responseHeader(type: Response.okNoData, request: request)
                }
                let rect = try scanoutRect(from: request, at: 24)
                let source: ScanoutBinding.Source
                let resourceWidth: UInt32
                let resourceHeight: UInt32
                if let resource = resources2D[resourceID] {
                    source = .resource2D
                    resourceWidth = resource.width
                    resourceHeight = resource.height
                } else if let resource = resources3D[resourceID] {
                    source = .resource3D
                    resourceWidth = resource.width
                    resourceHeight = resource.height
                } else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu scanout resource")
                }
                guard Self.contains(rect: rect, width: resourceWidth, height: resourceHeight) else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu scanout rectangle")
                }
                let previous = scanouts.updateValue(
                    ScanoutBinding(
                        resourceID: resourceID,
                        rect: rect,
                        source: source
                    ),
                    forKey: scanoutID
                )
                if let previous, case .blob = previous.source, let renderer {
                    try releaseBlobMappingIfUnused(resourceID: previous.resourceID, renderer: renderer)
                }
                // A compositor may render and flush its next buffer before atomically binding it
                // to the KMS scanout (notably when returning from a fullscreen/direct-scanout
                // surface). A host display that only observes flushes would then keep showing the
                // old application buffer forever. Publish the newly bound resource immediately;
                // renderer readback waits for outstanding producer work before copying it.
                let frames: [VirtioGPUScanoutFrame]
                switch source {
                case .resource2D:
                    guard let resource = resources2D[resourceID] else {
                        throw VMError.invalidConfiguration("virtio-gpu 2D scanout resource disappeared")
                    }
                    frames = try scanoutFrames(resourceID: resourceID, resource: resource, dirtyRect: rect)
                case .resource3D:
                    guard let renderer, let resource = resources3D[resourceID] else {
                        throw VMError.invalidConfiguration("virtio-gpu renderer is unavailable")
                    }
                    frames = try rendererScanoutFrames(
                        resourceID: resourceID,
                        resource: resource,
                        dirtyRect: rect,
                        renderer: renderer
                    )
                case .blob:
                    frames = []
                }
                for frame in frames { onScanoutFrame?(frame) }
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferToHost2D:
            return scanoutCommand(request: request) {
                try requireLength(request, 56)
                let rect = try scanoutRect(from: request, at: 24)
                let offset = request.leUInt64(at: 40)
                let resourceID = request.leUInt32(at: 48)
                guard let resource = resources2D[resourceID],
                      Self.contains(rect: rect, width: resource.width, height: resource.height),
                      offset < UInt64(resource.width) * UInt64(resource.height) * 4 else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu 2D transfer")
                }
                // Guest backing is directly mapped into this process. The later RESOURCE_FLUSH is
                // the ownership boundary at which Dory copies a coherent frame for the host UI.
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceFlush:
            return scanoutCommand(request: request) {
                try requireLength(request, 48)
                let rect = try scanoutRect(from: request, at: 24)
                let resourceID = request.leUInt32(at: 40)
                if let resource = resources2D[resourceID] {
                    guard Self.contains(rect: rect, width: resource.width, height: resource.height) else {
                        throw VMError.invalidConfiguration("invalid virtio-gpu resource flush")
                    }
                    let frames = try scanoutFrames(resourceID: resourceID, resource: resource, dirtyRect: rect)
                    for frame in frames {
                        onScanoutFrame?(frame)
                    }
                    return responseHeader(type: Response.okNoData, request: request)
                }
                if let resource = resources3D[resourceID] {
                    guard Self.contains(rect: rect, width: resource.width, height: resource.height) else {
                        throw VMError.invalidConfiguration("invalid virtio-gpu 3D resource flush")
                    }
                    guard let renderer else {
                        throw VMError.invalidConfiguration("virtio-gpu renderer is unavailable")
                    }
                    let frames = try rendererScanoutFrames(
                        resourceID: resourceID,
                        resource: resource,
                        dirtyRect: rect,
                        renderer: renderer
                    )
                    for frame in frames {
                        onScanoutFrame?(frame)
                    }
                    return responseHeader(type: Response.okNoData, request: request)
                }
                guard let blob = blobResources[resourceID] else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu resource flush")
                }
                let frames = try blobScanoutFrames(resourceID: resourceID, blob: blob, dirtyRect: rect)
                for frame in frames {
                    onScanoutFrame?(frame)
                }
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.getCapsetInfo:
            return capsetInfoResponse(request: request)
        case Command.getCapset:
            return capsetResponse(request: request)
        case Command.resourceAssignUUID:
            return scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                guard resources2D[resourceID] != nil
                        || resources3D[resourceID] != nil
                        || blobResources[resourceID] != nil else {
                    throw VMError.invalidConfiguration("virtio-gpu UUID request for unknown resource")
                }
                let uuid = resourceUUIDs[resourceID] ?? Self.makeResourceUUID()
                resourceUUIDs[resourceID] = uuid
                var response = responseHeader(type: Response.okResourceUUID, request: request)
                response.append(contentsOf: uuid)
                return response
            }
        case Command.ctxCreate:
            return rendererCommand(request: request) { renderer in
                guard request.count >= 96 else { throw VMError.unexpectedExit("short virtio-gpu ctx_create") }
                let contextID = request.leUInt32(at: 16)
                let nameLength = min(Int(request.leUInt32(at: 24)), 64)
                let contextInit = request.leUInt32(at: 28)
                let nameBytes = request[32..<(32 + nameLength)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                try renderer.createContext(
                    id: contextID,
                    flags: Self.rendererContextFlags(requested: contextInit, capsets: renderer.capsets),
                    name: name
                )
                traceResourceEvent("context-create", contextID: contextID, detail: "name=\(name) init=0x\(String(contextInit, radix: 16))")
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDestroy:
            return rendererCommand(request: request) { renderer in
                let contextID = request.leUInt32(at: 16)
                try renderer.destroyContext(id: contextID)
                traceResourceEvent("context-destroy", contextID: contextID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxAttachResource:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let contextID = request.leUInt32(at: 16)
                let resourceID = request.leUInt32(at: 24)
                traceResourceEvent("attach-begin", contextID: contextID, resourceID: resourceID)
                try renderer.attachResource(contextID: contextID, resourceID: resourceID)
                traceResourceEvent("attach-end", contextID: contextID, resourceID: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDetachResource:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 32)
                let contextID = request.leUInt32(at: 16)
                let resourceID = request.leUInt32(at: 24)
                try renderer.detachResource(contextID: contextID, resourceID: resourceID)
                traceResourceEvent("detach", contextID: contextID, resourceID: resourceID)
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
                guard resource.resourceID != 0,
                      resources2D[resource.resourceID] == nil,
                      resources3D[resource.resourceID] == nil,
                      blobResources[resource.resourceID] == nil else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu 3D resource")
                }
                try renderer.createResource3D(resource, entries: resourceEntries[resource.resourceID] ?? [])
                resources3D[resource.resourceID] = Resource3D(
                    format: resource.format,
                    width: resource.width,
                    height: resource.height
                )
                traceResourceEvent("create-3d", contextID: request.leUInt32(at: 16), resourceID: resource.resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceAttachBacking:
            return scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                let entries = try memoryEntries(from: request, count: request.leUInt32(at: 28), offset: 32, transport: transport)
                if var resource = resources2D[resourceID] {
                    if let renderer {
                        try renderer.attachBacking(resourceID: resourceID, entries: entries)
                    }
                    resource.backing = entries
                    resources2D[resourceID] = resource
                    return responseHeader(type: Response.okNoData, request: request)
                }
                resourceEntries[resourceID] = entries
                try rendererCommandThrowing { renderer in
                    try renderer.attachBacking(resourceID: resourceID, entries: entries)
                }
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceDetachBacking:
            return scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                if cursorResourceID == resourceID {
                    cursorResourceID = nil
                    onCursorUpdate?(nil)
                }
                if var resource = resources2D[resourceID] {
                    if let renderer {
                        try renderer.detachBacking(resourceID: resourceID)
                    }
                    resource.backing = []
                    resources2D[resourceID] = resource
                    return responseHeader(type: Response.okNoData, request: request)
                }
                try rendererCommandThrowing { renderer in
                    try renderer.detachBacking(resourceID: resourceID)
                }
                resourceEntries.removeValue(forKey: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreateBlob:
            return rendererCommand(request: request) { renderer in
                try requireLength(request, 56)
                let resourceID = request.leUInt32(at: 24)
                let size = request.leUInt64(at: 48)
                guard resourceID != 0,
                      size > 0,
                      size <= UInt64(Int.max),
                      resources2D[resourceID] == nil,
                      resources3D[resourceID] == nil,
                      blobResources[resourceID] == nil else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu blob resource")
                }
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
                blobResources[resourceID] = BlobResource(
                    memory: request.leUInt32(at: 28),
                    size: size,
                    mapping: nil
                )
                traceResourceEvent(
                    "create-blob",
                    contextID: request.leUInt32(at: 16),
                    resourceID: resourceID,
                    detail: "memory=\(request.leUInt32(at: 28)) blob=\(request.leUInt64(at: 40)) size=\(size)"
                )
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
                let mapping = try ensureBlobMapping(resourceID: resourceID, renderer: renderer)
                try hostVisibleMemory.map(
                    resourceID: resourceID,
                    hostPointer: mapping.hostPointer,
                    offset: offset,
                    size: mapping.size != 0 ? mapping.size : blob.size
                )
                if var updated = blobResources[resourceID] {
                    updated.guestMapped = true
                    blobResources[resourceID] = updated
                }
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
                guard var blob = blobResources[resourceID] else {
                    throw VMError.invalidConfiguration("virtio-gpu unmap of unknown blob")
                }
                blob.guestMapped = false
                blobResources[resourceID] = blob
                try releaseBlobMappingIfUnused(resourceID: resourceID, renderer: renderer)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceUnref:
            return scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                if cursorResourceID == resourceID {
                    cursorResourceID = nil
                    onCursorUpdate?(nil)
                }
                resourceUUIDs.removeValue(forKey: resourceID)
                traceResourceEvent("unref-begin", contextID: request.leUInt32(at: 16), resourceID: resourceID)
                if resources2D.removeValue(forKey: resourceID) != nil {
                    if let renderer {
                        try renderer.unrefResource(resourceID: resourceID)
                    }
                    scanouts = scanouts.filter { $0.value.resourceID != resourceID }
                    onScanoutResourceReleased?(resourceID)
                    traceResourceEvent("unref-end", resourceID: resourceID, detail: "kind=2d")
                    return responseHeader(type: Response.okNoData, request: request)
                }
                hostVisibleMemory?.unmap(resourceID: resourceID)
                try rendererCommandThrowing { renderer in
                    if blobResources[resourceID]?.mapping?.requiresRendererUnmap == true {
                        try renderer.unmapBlob(resourceID: resourceID)
                    }
                    try renderer.unrefResource(resourceID: resourceID)
                }
                scanouts = scanouts.filter { $0.value.resourceID != resourceID }
                resourceEntries.removeValue(forKey: resourceID)
                resources3D.removeValue(forKey: resourceID)
                published3DResources.remove(resourceID)
                rendererReadbackBuffers.removeValue(forKey: resourceID)
                blobResources.removeValue(forKey: resourceID)
                onScanoutResourceReleased?(resourceID)
                traceResourceEvent("unref-end", resourceID: resourceID, detail: "kind=renderer")
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
        case Command.setScanoutBlob:
            return scanoutCommand(request: request) {
                try requireLength(request, 96)
                let scanoutID = request.leUInt32(at: 40)
                let resourceID = request.leUInt32(at: 44)
                let width = request.leUInt32(at: 48)
                let height = request.leUInt32(at: 52)
                let format = request.leUInt32(at: 56)
                let stride = request.leUInt32(at: 64)
                let offset = request.leUInt32(at: 80)
                guard scanoutID < scanoutCount else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu blob scanout id")
                }
                if resourceID == 0 {
                    let previous = scanouts.removeValue(forKey: scanoutID)
                    if let previous, case .blob = previous.source, let renderer {
                        try releaseBlobMappingIfUnused(resourceID: previous.resourceID, renderer: renderer)
                    }
                    return responseHeader(type: Response.okNoData, request: request)
                }
                let rect = try scanoutRect(from: request, at: 24)
                guard let blob = blobResources[resourceID],
                      width > 0, height > 0,
                      width <= 16_384, height <= 16_384,
                      Self.isSupportedScanoutFormat(format),
                      Self.contains(rect: rect, width: width, height: height),
                      stride >= width * 4,
                      request.leUInt32(at: 68) == 0,
                      request.leUInt32(at: 72) == 0,
                      request.leUInt32(at: 76) == 0,
                      request.leUInt32(at: 84) == 0,
                      request.leUInt32(at: 88) == 0,
                      request.leUInt32(at: 92) == 0,
                      Self.scanoutByteRangeIsValid(
                        width: width,
                        height: height,
                        stride: stride,
                        offset: offset,
                        resourceSize: blob.size
                      ) else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu blob scanout resource")
                }
                let previous = scanouts.updateValue(
                    ScanoutBinding(
                        resourceID: resourceID,
                        rect: rect,
                        source: .blob(
                            format: format,
                            width: width,
                            height: height,
                            stride: stride,
                            offset: offset
                        )
                    ),
                    forKey: scanoutID
                )
                if let previous,
                   previous.resourceID != resourceID,
                   case .blob = previous.source,
                   let renderer {
                    try releaseBlobMappingIfUnused(resourceID: previous.resourceID, renderer: renderer)
                }
                for frame in try blobScanoutFrames(resourceID: resourceID, blob: blob, dirtyRect: rect) {
                    onScanoutFrame?(frame)
                }
                return responseHeader(type: Response.okNoData, request: request)
            }
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
            logCommandFailure(request: request, error: error)
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    private func rendererCommandThrowing(
        _ body: (VirtioGPURenderer) throws -> Void
    ) throws {
        guard let renderer else {
            throw VMError.invalidConfiguration("virtio-gpu renderer is unavailable")
        }
        try body(renderer)
    }

    private func scanoutCommand(
        request: [UInt8],
        _ body: () throws -> [UInt8]
    ) -> [UInt8] {
        do {
            return try body()
        } catch {
            logCommandFailure(request: request, error: error)
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    /// Linux may retry a failed renderer command many times per second. Preserve the status and
    /// identifying fields needed for diagnosis without flooding the VM's serial log.
    private func logCommandFailure(request: [UInt8], error: Error) {
        guard request.count >= 4 else { return }
        let command = request.leUInt32(at: 0)
        let count = commandFailureCounts[command, default: 0] + 1
        commandFailureCounts[command] = count
        guard count <= 3 else { return }
        let contextID = request.count >= 20 ? request.leUInt32(at: 16) : 0
        let detail: String
        if command == Command.submit3D {
            let size = request.count >= 28 ? request.leUInt32(at: 24) : 0
            detail = "bytes=\(size)"
        } else {
            let resourceID = request.count >= 28 ? request.leUInt32(at: 24) : 0
            detail = "resource=\(resourceID)"
        }
        FileHandle.standardError.write(Data(
            "dory-gpu: command=0x\(String(command, radix: 16)) context=\(contextID) \(detail) failed: \(error)\n".utf8
        ))
    }

    private func traceResourceEvent(
        _ event: String,
        contextID: UInt32 = 0,
        resourceID: UInt32? = nil,
        detail: String = ""
    ) {
        guard traceResourceLifecycle else { return }
        resourceTraceSequence &+= 1
        let resource = resourceID.map(String.init) ?? "-"
        let kind: String
        if let resourceID {
            if resources2D[resourceID] != nil { kind = "2d" }
            else if resources3D[resourceID] != nil { kind = "3d" }
            else if blobResources[resourceID] != nil { kind = "blob" }
            else { kind = "missing" }
        } else {
            kind = "-"
        }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        FileHandle.standardError.write(Data(
            "dory-gpu-trace: seq=\(resourceTraceSequence) event=\(event) context=\(contextID) resource=\(resource) kind=\(kind)\(suffix)\n".utf8
        ))
    }

    private func scanoutRect(from request: [UInt8], at offset: Int) throws -> VirtioGPURect {
        try requireLength(request, offset + 16)
        let rect = VirtioGPURect(
            x: request.leUInt32(at: offset),
            y: request.leUInt32(at: offset + 4),
            width: request.leUInt32(at: offset + 8),
            height: request.leUInt32(at: offset + 12)
        )
        guard rect.width > 0, rect.height > 0 else {
            throw VMError.invalidConfiguration("empty virtio-gpu rectangle")
        }
        return rect
    }

    private static func contains(rect: VirtioGPURect, width: UInt32, height: UInt32) -> Bool {
        rect.x <= width && rect.width <= width - rect.x
            && rect.y <= height && rect.height <= height - rect.y
    }

    private static func intersection(_ lhs: VirtioGPURect, _ rhs: VirtioGPURect) -> VirtioGPURect? {
        let left = max(UInt64(lhs.x), UInt64(rhs.x))
        let top = max(UInt64(lhs.y), UInt64(rhs.y))
        let right = min(UInt64(lhs.x) + UInt64(lhs.width), UInt64(rhs.x) + UInt64(rhs.width))
        let bottom = min(UInt64(lhs.y) + UInt64(lhs.height), UInt64(rhs.y) + UInt64(rhs.height))
        guard right > left, bottom > top else { return nil }
        return VirtioGPURect(
            x: UInt32(left),
            y: UInt32(top),
            width: UInt32(right - left),
            height: UInt32(bottom - top)
        )
    }

    private static func isSupportedScanoutFormat(_ format: UInt32) -> Bool {
        // All formats below are the 32-bit virtio-gpu formats accepted by Linux's DRM helper.
        // The host presentation layer retains the format so it can select the matching Metal
        // swizzle instead of rewriting every pixel in this transport thread.
        [1, 2, 3, 4, 67, 68, 121, 134].contains(format)
    }

    private static func scanoutByteRangeIsValid(
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        offset: UInt32,
        resourceSize: UInt64
    ) -> Bool {
        guard width > 0, height > 0 else { return false }
        let finalRow = UInt64(height - 1) * UInt64(stride)
        let finalPixel = UInt64(width) * 4
        return UInt64(offset) <= resourceSize
            && finalRow <= resourceSize - UInt64(offset)
            && finalPixel <= resourceSize - UInt64(offset) - finalRow
    }

    private func cursorCommand(_ command: UInt32, request: [UInt8]) -> [UInt8] {
        scanoutCommand(request: request) {
            guard command == Command.updateCursor || command == Command.moveCursor else {
                throw VMError.invalidConfiguration("unsupported virtio-gpu cursor command")
            }
            try requireLength(request, 56)
            let scanoutID = request.leUInt32(at: 24)
            guard scanoutID < scanoutCount else {
                throw VMError.invalidConfiguration("invalid virtio-gpu cursor scanout")
            }
            if command == Command.moveCursor {
                return responseHeader(type: Response.okNoData, request: request)
            }

            let resourceID = request.leUInt32(at: 40)
            if resourceID == 0 {
                cursorResourceID = nil
                onCursorUpdate?(nil)
                return responseHeader(type: Response.okNoData, request: request)
            }
            guard let resource = resources2D[resourceID],
                  resource.format == 1,
                  resource.width > 0, resource.height > 0,
                  resource.width <= 256, resource.height <= 256 else {
                throw VMError.invalidConfiguration(
                    "virtio-gpu cursor requires a bounded B8G8R8A8 2D resource"
                )
            }
            let hotX = request.leUInt32(at: 44)
            let hotY = request.leUInt32(at: 48)
            guard hotX < resource.width, hotY < resource.height else {
                throw VMError.invalidConfiguration("virtio-gpu cursor hotspot is outside the image")
            }
            let pixels = try copiedBytes(for: resource)
            cursorResourceID = resourceID
            onCursorUpdate?(VirtioGPUCursorUpdate(
                scanoutID: scanoutID,
                resourceID: resourceID,
                x: request.leUInt32(at: 28),
                y: request.leUInt32(at: 32),
                width: resource.width,
                height: resource.height,
                hotX: hotX,
                hotY: hotY,
                bytes: pixels
            ))
            return responseHeader(type: Response.okNoData, request: request)
        }
    }

    private func copiedBytes(for resource: Resource2D) throws -> Data {
        let resourceByteCount = Int(UInt64(resource.width) * UInt64(resource.height) * 4)
        var source = Data(capacity: resourceByteCount)
        for entry in resource.backing where source.count < resourceByteCount {
            let count = min(entry.length, resourceByteCount - source.count)
            source.append(entry.pointer.assumingMemoryBound(to: UInt8.self), count: count)
        }
        guard source.count == resourceByteCount else {
            throw VMError.invalidConfiguration("virtio-gpu 2D backing is incomplete")
        }
        return source
    }

    private func scanoutFrames(
        resourceID: UInt32,
        resource: Resource2D,
        dirtyRect: VirtioGPURect
    ) throws -> [VirtioGPUScanoutFrame] {
        let source = try copiedBytes(for: resource)

        let sourceStride = Int(resource.width) * 4
        var frames = [VirtioGPUScanoutFrame]()
        for (scanoutID, binding) in scanouts.sorted(by: { $0.key < $1.key })
        where binding.resourceID == resourceID {
            guard case .resource2D = binding.source else { continue }
            guard let dirty = Self.intersection(dirtyRect, binding.rect) else { continue }
            let outputStride = Int(dirty.width) * 4
            var pixels = Data(capacity: outputStride * Int(dirty.height))
            for row in 0..<Int(dirty.height) {
                let sourceOffset = (Int(dirty.y) + row) * sourceStride + Int(dirty.x) * 4
                pixels.append(source.subdata(in: sourceOffset..<(sourceOffset + outputStride)))
            }
            frames.append(VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                format: resource.format,
                width: binding.rect.width,
                height: binding.rect.height,
                stride: UInt32(outputStride),
                dirtyRect: VirtioGPURect(
                    x: dirty.x - binding.rect.x,
                    y: dirty.y - binding.rect.y,
                    width: dirty.width,
                    height: dirty.height
                ),
                bytes: pixels
            ))
        }
        return frames
    }

    private func blobScanoutFrames(
        resourceID: UInt32,
        blob: BlobResource,
        dirtyRect: VirtioGPURect
    ) throws -> [VirtioGPUScanoutFrame] {
        let bindings = scanouts.sorted(by: { $0.key < $1.key }).compactMap {
            (scanoutID, binding) -> (UInt32, ScanoutBinding, UInt32, UInt32, UInt32, UInt32, UInt32)? in
            guard binding.resourceID == resourceID,
                  case let .blob(format, width, height, stride, offset) = binding.source else {
                return nil
            }
            return (scanoutID, binding, format, width, height, stride, offset)
        }
        guard !bindings.isEmpty else { return [] }

        let guestEntries = blob.memory == 1 ? (resourceEntries[resourceID] ?? []) : []
        let mapping: VirtioGPUBlobMapping?
        if guestEntries.isEmpty {
            guard let renderer else {
                throw VMError.invalidConfiguration("virtio-gpu blob scanout has no accessible backing")
            }
            mapping = try ensureBlobMapping(resourceID: resourceID, renderer: renderer)
        } else {
            mapping = nil
        }

        var frames = [VirtioGPUScanoutFrame]()
        for (scanoutID, binding, format, width, height, stride, offset) in bindings {
            guard Self.contains(rect: dirtyRect, width: width, height: height) else {
                throw VMError.invalidConfiguration("virtio-gpu blob damage exceeds framebuffer")
            }
            guard let dirty = Self.intersection(dirtyRect, binding.rect) else { continue }
            let outputStride = Int(dirty.width) * 4
            var pixels = Data(capacity: outputStride * Int(dirty.height))
            for row in 0..<UInt64(dirty.height) {
                let sourceOffset = UInt64(offset)
                    + (UInt64(dirty.y) + row) * UInt64(stride)
                    + UInt64(dirty.x) * 4
                if let mapping {
                    let mappingSize = mapping.size == 0 ? blob.size : mapping.size
                    guard UInt64(outputStride) <= mappingSize,
                          sourceOffset <= mappingSize - UInt64(outputStride),
                          sourceOffset <= UInt64(Int.max) else {
                        throw VMError.invalidConfiguration("virtio-gpu blob mapping is smaller than its scanout")
                    }
                    pixels.append(
                        mapping.hostPointer.advanced(by: Int(sourceOffset)).assumingMemoryBound(to: UInt8.self),
                        count: outputStride
                    )
                } else {
                    pixels.append(try copyBackingRange(
                        entries: guestEntries,
                        offset: sourceOffset,
                        count: outputStride
                    ))
                }
            }
            frames.append(VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                format: format,
                width: binding.rect.width,
                height: binding.rect.height,
                stride: UInt32(outputStride),
                dirtyRect: VirtioGPURect(
                    x: dirty.x - binding.rect.x,
                    y: dirty.y - binding.rect.y,
                    width: dirty.width,
                    height: dirty.height
                ),
                bytes: pixels
            ))
        }
        return frames
    }

    /// VirGL render targets live in the host OpenGL context rather than guest RAM. Mutter rotates
    /// multiple scanout resources and reports damage relative to each individual resource, so the
    /// host keeps a Metal texture per resource. Publish the first image in full to initialize that
    /// texture, then read and publish only the changed rectangle on subsequent flushes.
    private func rendererScanoutFrames(
        resourceID: UInt32,
        resource: Resource3D,
        dirtyRect: VirtioGPURect,
        renderer: VirtioGPURenderer
    ) throws -> [VirtioGPUScanoutFrame] {
        let publishFullResource = !published3DResources.contains(resourceID)
        var frames = [VirtioGPUScanoutFrame]()
        for (scanoutID, binding) in scanouts.sorted(by: { $0.key < $1.key })
        where binding.resourceID == resourceID {
            guard case .resource3D = binding.source else { continue }
            guard let damaged = Self.intersection(dirtyRect, binding.rect) else { continue }
            let readRect = publishFullResource ? binding.rect : damaged
            let resourceStride = UInt64(resource.width) * 4
            let resourceByteCount = resourceStride * UInt64(resource.height)
            let readbackOffset = UInt64(readRect.y) * resourceStride + UInt64(readRect.x) * 4
            let outputStride = UInt64(readRect.width) * 4
            let outputByteCount = outputStride * UInt64(readRect.height)
            guard resourceStride <= UInt64(UInt32.max),
                  resourceByteCount <= UInt64(Int.max),
                  outputStride <= UInt64(UInt32.max),
                  outputByteCount <= UInt64(Int.max) else {
                throw VMError.invalidConfiguration("virtio-gpu 3D scanout is too large")
            }
            var readback = rendererReadbackBuffers[resourceID]
                ?? Data(count: Int(resourceByteCount))
            if readback.count != Int(resourceByteCount) {
                readback = Data(count: Int(resourceByteCount))
            }
            try readback.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw VMError.invalidConfiguration("virtio-gpu 3D scanout has no storage")
                }
                try renderer.transferFromHost3D(
                    VirtioGPUTransfer3D(
                        resourceID: resourceID,
                        contextID: 0,
                        level: 0,
                        stride: UInt32(resourceStride),
                        layerStride: 0,
                        offset: readbackOffset,
                        box: [readRect.x, readRect.y, 0, readRect.width, readRect.height, 1]
                    ),
                    entries: [VirtioGPUMemoryEntry(pointer: baseAddress, length: bytes.count)]
                )
            }
            rendererReadbackBuffers[resourceID] = readback

            var pixels = Data(count: Int(outputByteCount))
            pixels.withUnsafeMutableBytes { destination in
                readback.withUnsafeBytes { source in
                    guard let destinationBase = destination.baseAddress,
                          let sourceBase = source.baseAddress else { return }
                    let rowBytes = Int(outputStride)
                    for row in 0..<Int(readRect.height) {
                        let sourceOffset = Int(UInt64(readRect.y + UInt32(row)) * resourceStride)
                            + Int(UInt64(readRect.x) * 4)
                        destinationBase.advanced(by: row * rowBytes).copyMemory(
                            from: sourceBase.advanced(by: sourceOffset),
                            byteCount: rowBytes
                        )
                    }
                }
            }
            frames.append(VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                format: resource.format,
                width: binding.rect.width,
                height: binding.rect.height,
                stride: UInt32(outputStride),
                dirtyRect: VirtioGPURect(
                    x: readRect.x - binding.rect.x,
                    y: readRect.y - binding.rect.y,
                    width: readRect.width,
                    height: readRect.height
                ),
                bytes: pixels
            ))
        }
        if !frames.isEmpty { published3DResources.insert(resourceID) }
        return frames
    }

    private func copyBackingRange(
        entries: [VirtioGPUMemoryEntry],
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else {
            throw VMError.invalidConfiguration("invalid virtio-gpu backing range")
        }
        var skip = offset
        var remaining = count
        var bytes = Data(capacity: count)
        for entry in entries where remaining > 0 {
            let entryLength = UInt64(entry.length)
            if skip >= entryLength {
                skip -= entryLength
                continue
            }
            let entryOffset = Int(skip)
            let available = entry.length - entryOffset
            let copied = min(available, remaining)
            bytes.append(
                entry.pointer.advanced(by: entryOffset).assumingMemoryBound(to: UInt8.self),
                count: copied
            )
            remaining -= copied
            skip = 0
        }
        guard remaining == 0 else {
            throw VMError.invalidConfiguration("virtio-gpu scanout backing is incomplete")
        }
        return bytes
    }

    private func ensureBlobMapping(
        resourceID: UInt32,
        renderer: VirtioGPURenderer
    ) throws -> VirtioGPUBlobMapping {
        guard var blob = blobResources[resourceID] else {
            throw VMError.invalidConfiguration("virtio-gpu map of unknown blob")
        }
        if let mapping = blob.mapping { return mapping }
        let mapping = try renderer.mapBlob(resourceID: resourceID)
        blob.mapping = mapping
        blobResources[resourceID] = blob
        return mapping
    }

    /// Linux creates an implicit default context for primary-node clients before userspace can issue
    /// VIRTGPU_CONTEXT_INIT. The standard default is VirGL2 when it is advertised; a renderer offering
    /// one capset has an unambiguous default. Resolving zero here also prevents the kernel from retrying
    /// an unsupported legacy context on a Venus-only GPU.
    static func rendererContextFlags(requested: UInt32, capsets: [VirtioGPUCapset]) -> UInt32 {
        let requestedCapset = requested & 0xff
        if requestedCapset == 0 {
            if capsets.contains(where: { $0.id == 2 }) {
                return 2
            }
            if capsets.count == 1 {
                return capsets[0].id & 0xff
            }
        }
        return requestedCapset
    }

    private static func makeResourceUUID() -> [UInt8] {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private func releaseBlobMappingIfUnused(
        resourceID: UInt32,
        renderer: VirtioGPURenderer
    ) throws {
        guard var blob = blobResources[resourceID],
              let mapping = blob.mapping,
              !blob.guestMapped,
              !scanouts.values.contains(where: { binding in
                  guard binding.resourceID == resourceID else { return false }
                  if case .blob = binding.source { return true }
                  return false
              }) else {
            return
        }
        if mapping.requiresRendererUnmap {
            try renderer.unmapBlob(resourceID: resourceID)
        }
        blob.mapping = nil
        blobResources[resourceID] = blob
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
