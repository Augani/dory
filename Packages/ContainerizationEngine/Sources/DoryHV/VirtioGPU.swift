import Darwin
import DoryFSWorkerContracts
import DoryRendererWorkerContracts
import Dispatch
import Foundation
import Hypervisor
import Metal

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
    /// Guest-physical identity used to grant the same bytes to an isolated renderer worker.
    /// Synthetic host-only entries leave this nil and are never eligible for worker submission.
    public var guestAddress: UInt64?

    public init(
        pointer: UnsafeMutableRawPointer,
        length: Int,
        guestAddress: UInt64? = nil
    ) {
        self.pointer = pointer
        self.length = length
        self.guestAddress = guestAddress
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

/// VMM-local mapping of a worker-exported SHM blob. The descriptor and mmap lifetime remain bound
/// to one authenticated resource generation; neither a worker pointer nor a path crosses XPC.
private final class DoryRendererWorkerBlobMappingAuthority: @unchecked Sendable {
    let lease: DoryRendererBlobMappingLease
    let hostPointer: UnsafeMutableRawPointer
    let mappedByteCount: Int
    private let descriptor: FileHandle

    init(_ mapping: DoryRendererWorkerBlobMapping) throws {
        let roundedLength = mapping.lease.mappingByteCount
            .roundedUpToMultiple(of: HostPage.size)
        guard roundedLength > 0,
              roundedLength <= mapping.lease.declaredFileSize,
              roundedLength <= UInt64(Int.max) else {
            try? mapping.sharedMemoryDescriptor.close()
            throw VMError.invalidConfiguration("worker blob mapping exceeds SHM authority")
        }
        let pointer = mmap(
            nil,
            Int(roundedLength),
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            mapping.sharedMemoryDescriptor.fileDescriptor,
            0
        )
        guard pointer != MAP_FAILED, let pointer else {
            try? mapping.sharedMemoryDescriptor.close()
            throw VMError.outOfMemory("cannot map worker blob SHM: errno \(errno)")
        }
        self.lease = mapping.lease
        self.hostPointer = pointer
        self.mappedByteCount = Int(roundedLength)
        self.descriptor = mapping.sharedMemoryDescriptor
    }

    deinit {
        munmap(hostPointer, mappedByteCount)
        try? descriptor.close()
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

/// The preferred mode for one stable virtio-gpu scanout. Array order is the guest-visible
/// scanout identifier, so callers must preserve it for the lifetime of the device.
public struct VirtioGPUScanoutSize: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32

    public init(width: UInt32, height: UInt32) {
        self.width = min(16_384, max(1, width))
        self.height = min(16_384, max(1, height))
    }
}

/// One copied scanout update ready for a host display surface. `width` and `height` describe the
/// complete scanout, while `bytes` contains only `dirtyRect` rows at `stride` bytes per row. The
/// device never exposes guest pointers to the UI layer, and small browser repaints therefore avoid
/// copying the rest of a 4K framebuffer merely to update one damaged rectangle.
public struct VirtioGPUScanoutFrame: Sendable, Equatable {
    public var scanoutID: UInt32
    public var resourceID: UInt32
    public var resourceGeneration: UInt64
    public var format: UInt32
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var dirtyRect: VirtioGPURect
    public var bytes: Data

    public init(
        scanoutID: UInt32,
        resourceID: UInt32,
        resourceGeneration: UInt64 = 0,
        format: UInt32,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        dirtyRect: VirtioGPURect,
        bytes: Data
    ) {
        self.scanoutID = scanoutID
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.format = format
        self.width = width
        self.height = height
        self.stride = stride
        self.dirtyRect = dirtyRect
        self.bytes = bytes
    }
}

/// A renderer-owned OpenGL texture that can be displayed without copying its pixels through host
/// memory. The texture name is valid only in an OpenGL context that shares objects with the
/// renderer. `yOriginTop` is the renderer's authoritative orientation bit and must be preserved by
/// the display backend rather than inferred from the guest format.
public struct VirtioGPUTextureResource: Sendable, Equatable {
    public var textureID: UInt32
    public var format: UInt32
    public var width: UInt32
    public var height: UInt32
    public var yOriginTop: Bool

    public init(
        textureID: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32,
        yOriginTop: Bool
    ) {
        self.textureID = textureID
        self.format = format
        self.width = width
        self.height = height
        self.yOriginTop = yOriginTop
    }
}

/// A producer-completion boundary for a renderer-owned texture presentation.
///
/// `prepareConsumerForPresentation()` is invoked with the display's shared OpenGL context current.
/// A conforming renderer must enqueue a server-side wait for producer completion on that context
/// (without a CPU-wide finish) and return only after subsequent consumer reattachment and reads are
/// ordered behind it. A texture name by itself is deliberately not presentation authority:
/// `glFlush` only submits producer work and does not establish the required cross-context
/// completion dependency. Each synchronization object is a single-use authority: an
/// implementation must atomically choose either a successful consumer preparation or discard,
/// make repeated calls harmless, and destroy its completion primitive on the context that owns it.
public protocol VirtioGPUTexturePresentationSynchronization: AnyObject, Sendable {
    func prepareConsumerForPresentation() throws
    /// Retires an authority that was coalesced or rejected before the consumer wait was enqueued.
    /// This may be called from a producer/mailbox thread; implementations must schedule any
    /// context-bound fence destruction on an appropriate renderer context and make it idempotent.
    func discardWithoutPresentation()
}

/// Renderer-issued authority to present one shared texture after an explicit producer-completion
/// handoff. The synchronization object is intentionally opaque to the virtio device and AppKit
/// mailbox. This is the legacy in-process representation; the signed worker contract instead
/// exports either an owned SHM descriptor with immutable linear layout or a secure-coding
/// `MTLSharedTextureHandle`, plus a single-use release token and its qualified producer-completion
/// contract. A process-local GL/Metal texture name by itself is never cross-process authority.
public struct VirtioGPUTexturePresentation: Sendable {
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let texture: VirtioGPUTextureResource
    private let synchronization: any VirtioGPUTexturePresentationSynchronization

    public init(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        texture: VirtioGPUTextureResource,
        synchronization: any VirtioGPUTexturePresentationSynchronization
    ) {
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.texture = texture
        self.synchronization = synchronization
    }

    public func prepareConsumerForPresentation() throws {
        try synchronization.prepareConsumerForPresentation()
    }

    public func discardWithoutPresentation() {
        synchronization.discardWithoutPresentation()
    }
}

public enum VirtioGPUMetalScanoutPresentationError: Error, Equatable, Sendable {
    case retired
}

public enum VirtioGPUMetalScanoutTransport: Equatable, Sendable {
    case sharedMemory
    case sharedTexture
}

/// One consumer's authority to import a worker-issued scanout into Metal without copying pixels.
/// A Venus lease borrows one SHM descriptor; a VirGL2 lease borrows one secure-coding shared-texture
/// handle. The managed guest's producer-complete flush has already run before publication.
public final class VirtioGPUMetalScanoutPresentation: @unchecked Sendable {
    public let workerGeneration: DoryRendererWorkerGeneration
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let leaseID: DoryRendererScanoutLeaseID
    public let releaseToken: DoryRendererScanoutReleaseToken
    public let pixelFormat: DoryRendererScanoutPixelFormat
    public let yOriginTop: Bool
    public let width: UInt32
    public let height: UInt32
    public let transport: VirtioGPUMetalScanoutTransport

    private let consumerID: UInt32
    private let core: DoryRendererWorkerSharedScanoutCore
    private let lock = NSLock()
    private var retired = false

    fileprivate init(
        scanout: DoryRendererWorkerScanoutAuthority,
        consumerID: UInt32,
        core: DoryRendererWorkerSharedScanoutCore
    ) {
        switch scanout {
        case .sharedMemory(let value):
            transport = .sharedMemory
            workerGeneration = value.lease.workerGeneration
            resourceID = value.lease.resourceID
            resourceGeneration = value.lease.resourceGeneration
            leaseID = value.lease.leaseID
            releaseToken = value.lease.releaseToken
            pixelFormat = value.lease.pixelFormat
            yOriginTop = value.lease.yOriginTop
            width = value.lease.width
            height = value.lease.height
        case .sharedTexture(let value):
            transport = .sharedTexture
            workerGeneration = value.lease.workerGeneration
            resourceID = value.lease.resourceID
            resourceGeneration = value.lease.resourceGeneration
            leaseID = value.lease.leaseID
            releaseToken = value.lease.releaseToken
            pixelFormat = value.lease.pixelFormat
            yOriginTop = value.lease.yOriginTop
            width = value.lease.width
            height = value.lease.height
        }
        self.consumerID = consumerID
        self.core = core
    }

    public func withSharedMemoryScanout<T>(
        _ body: (DoryRendererScanoutLease, Int32) throws -> T
    ) throws -> T {
        let isRetired = lock.withLock { retired }
        guard !isRetired else { throw VirtioGPUMetalScanoutPresentationError.retired }
        return try core.withSharedMemoryScanout(
            consumerID: consumerID,
            body
        )
    }

    public func withSharedTextureHandle<T>(
        _ body: (MTLSharedTextureHandle) throws -> T
    ) throws -> T {
        let isRetired = lock.withLock { retired }
        guard !isRetired else { throw VirtioGPUMetalScanoutPresentationError.retired }
        return try core.withSharedTextureHandle(
            consumerID: consumerID,
            body
        )
    }

    /// Retires this display consumer after all Metal and mmap references have been destroyed.
    /// The worker release token is sent only after every consumer of the shared lease retires.
    public func finishPresentation() {
        retire()
    }

    /// Retires an update coalesced or rejected before presentation. This is intentionally the same
    /// exact lifetime transition as a successfully displayed update.
    public func discardWithoutPresentation() {
        retire()
    }

    deinit {
        retire()
    }

    private func retire() {
        let shouldRetire = lock.withLock { () -> Bool in
            guard !retired else { return false }
            retired = true
            return true
        }
        if shouldRetire { core.retireConsumer(consumerID) }
    }
}

/// Exactly-once acknowledgement that a worker update reached a committed host Metal command
/// buffer. Merely enqueueing an update in the AppKit mailbox is not sufficient: a following guest
/// modeset could otherwise retire the lease before the main thread imports it.
private final class VirtioGPUMetalScanoutHostSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func resolve(accepted: Bool) {
        let callback = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            let callback = completion
            completion = nil
            return callback
        }
        callback?(accepted)
    }

    deinit {
        resolve(accepted: false)
    }
}

/// One zero-copy Metal scanout update. `sourceRect` selects the guest scanout from the immutable
/// worker resource; `dirtyRect` is scanout-local damage and never carries frame bytes.
public struct VirtioGPUMetalScanoutUpdate: Sendable, Equatable {
    public let scanoutID: UInt32
    public let resourceID: UInt32
    /// VMM display-lifetime identity used to order SET_SCANOUT, release, and ID reuse.
    public let resourceGeneration: UInt64
    /// Independent authenticated worker identity returned by CREATE_BLOB and bound into the lease.
    public let rendererResourceGeneration: UInt64
    public let presentation: VirtioGPUMetalScanoutPresentation
    public let sourceRect: VirtioGPURect
    public let dirtyRect: VirtioGPURect
    private let hostSubmission: VirtioGPUMetalScanoutHostSubmission

    fileprivate init(
        scanoutID: UInt32,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        rendererResourceGeneration: UInt64,
        presentation: VirtioGPUMetalScanoutPresentation,
        sourceRect: VirtioGPURect,
        dirtyRect: VirtioGPURect,
        hostSubmission: VirtioGPUMetalScanoutHostSubmission
    ) {
        self.scanoutID = scanoutID
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.rendererResourceGeneration = rendererResourceGeneration
        self.presentation = presentation
        self.sourceRect = sourceRect
        self.dirtyRect = dirtyRect
        self.hostSubmission = hostSubmission
    }

    /// Completes the guest flush only after the display consumer has imported the lease and
    /// committed a Metal command buffer that retains it.
    public func acceptHostSubmission() {
        hostSubmission.resolve(accepted: true)
    }

    /// Fails the guest flush when the display consumer cannot commit the worker frame. The caller
    /// must also retire `presentation` after all local references have been destroyed.
    public func rejectHostSubmission() {
        hostSubmission.resolve(accepted: false)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scanoutID == rhs.scanoutID
            && lhs.resourceID == rhs.resourceID
            && lhs.resourceGeneration == rhs.resourceGeneration
            && lhs.rendererResourceGeneration == rhs.rendererResourceGeneration
            && lhs.presentation.leaseID == rhs.presentation.leaseID
            && lhs.sourceRect == rhs.sourceRect
            && lhs.dirtyRect == rhs.dirtyRect
    }
}

/// Joins one host-submission acknowledgement per scanout for a single RESOURCE_FLUSH. Multi-head
/// guests receive success only after every target has accepted the same worker lease generation.
private final class DoryRendererWorkerHostSubmissionGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var accepted = true
    private var completion: (@Sendable (Bool) -> Void)?

    init(count: Int, completion: @escaping @Sendable (Bool) -> Void) {
        precondition(count > 0)
        self.remaining = count
        self.completion = completion
    }

    func resolve(accepted: Bool) {
        let result = lock.withLock { () -> (
            (@Sendable (Bool) -> Void), Bool
        )? in
            guard remaining > 0 else { return nil }
            self.accepted = self.accepted && accepted
            remaining -= 1
            guard remaining == 0, let completion else { return nil }
            self.completion = nil
            return (completion, self.accepted)
        }
        if let result { result.0(result.1) }
    }
}

/// Shared core for one producer-complete worker lease. A resource may be bound to several guest
/// scanouts, so each update receives a distinct consumer handle while the underlying transport
/// authority and release token remain singular.
private final class DoryRendererWorkerSharedScanoutCore: @unchecked Sendable {
    typealias Release = @Sendable (DoryRendererWorkerScanoutAuthority) -> Void
    typealias Terminal = @Sendable (DoryRendererScanoutReleaseToken) -> Void

    private enum State {
        case ready
        case terminal
    }

    let releaseToken: DoryRendererScanoutReleaseToken

    private let lock = NSLock()
    private var state: State = .ready
    private var pendingConsumers: Set<UInt32>
    private var scanout: DoryRendererWorkerScanoutAuthority?
    private var release: Release?
    private var terminal: Terminal?

    init(
        scanout: DoryRendererWorkerScanoutAuthority,
        consumerCount: Int,
        release: @escaping Release,
        terminal: @escaping Terminal
    ) throws {
        guard consumerCount > 0, consumerCount <= 16 else {
            scanout.discardTransport()
            throw VMError.invalidConfiguration("invalid worker scanout consumer count")
        }
        self.releaseToken = scanout.releaseToken
        self.pendingConsumers = Set((0..<consumerCount).map(UInt32.init))
        self.scanout = scanout
        self.release = release
        self.terminal = terminal
    }

    func makePresentation(consumerID: UInt32) -> VirtioGPUMetalScanoutPresentation? {
        lock.withLock {
            guard case .ready = state, pendingConsumers.contains(consumerID) else { return nil }
            return VirtioGPUMetalScanoutPresentation(
                scanout: scanout!,
                consumerID: consumerID,
                core: self
            )
        }
    }

    func withSharedMemoryScanout<T>(
        consumerID: UInt32,
        _ body: (DoryRendererScanoutLease, Int32) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard case .ready = state,
              pendingConsumers.contains(consumerID),
              case .sharedMemory(let value)? = scanout,
              value.sharedMemoryDescriptor.fileDescriptor >= 0 else {
            throw VirtioGPUMetalScanoutPresentationError.retired
        }
        return try body(value.lease, value.sharedMemoryDescriptor.fileDescriptor)
    }

    func withSharedTextureHandle<T>(
        consumerID: UInt32,
        _ body: (MTLSharedTextureHandle) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard case .ready = state,
              pendingConsumers.contains(consumerID),
              case .sharedTexture(let value)? = scanout else {
            throw VirtioGPUMetalScanoutPresentationError.retired
        }
        return try body(value.sharedTextureHandle)
    }

    func retireConsumer(_ consumerID: UInt32) {
        let terminalAuthority = lock.withLock { () -> (
            DoryRendererWorkerScanoutAuthority?, Release?, Terminal?
        )? in
            guard case .ready = state,
                  pendingConsumers.remove(consumerID) != nil else { return nil }
            guard pendingConsumers.isEmpty else { return nil }
            state = .terminal
            let scanout = self.scanout
            self.scanout = nil
            let release = self.release
            self.release = nil
            let terminal = self.terminal
            self.terminal = nil
            return (scanout, release, terminal)
        }
        guard let terminalAuthority else { return }
        terminalAuthority.0?.discardTransport()
        terminalAuthority.2?(releaseToken)
        if let scanout = terminalAuthority.0 { terminalAuthority.1?(scanout) }
    }

    /// Discards every not-yet-published consumer while the worker generation remains valid.
    func retireWithoutPresentation() {
        let terminalAuthority = terminate(requestWorkerRelease: true)
        finish(terminalAuthority)
    }

    /// Revokes local transport authority without attempting a token release into an already-revoked worker
    /// generation. Used by reset, queue teardown, crash, and generation drift.
    func revoke() {
        let terminalAuthority = terminate(requestWorkerRelease: false)
        finish(terminalAuthority)
    }

    private func terminate(
        requestWorkerRelease: Bool
    ) -> (DoryRendererWorkerScanoutAuthority?, Release?, Terminal?)? {
        lock.withLock {
            guard case .terminal = state else {
                state = .terminal
                pendingConsumers.removeAll(keepingCapacity: false)
                let scanout = self.scanout
                self.scanout = nil
                let release = requestWorkerRelease ? self.release : nil
                self.release = nil
                let terminal = self.terminal
                self.terminal = nil
                return (scanout, release, terminal)
            }
            return nil
        }
    }

    private func finish(
        _ authority: (DoryRendererWorkerScanoutAuthority?, Release?, Terminal?)?
    ) {
        guard let authority else { return }
        authority.0?.discardTransport()
        authority.2?(releaseToken)
        if let scanout = authority.0 { authority.1?(scanout) }
    }
}

private final class DoryRendererWorkerWeakScanoutCore: @unchecked Sendable {
    weak var value: DoryRendererWorkerSharedScanoutCore?

    init(_ value: DoryRendererWorkerSharedScanoutCore) {
        self.value = value
    }
}

/// One direct renderer-texture presentation. `sourceRect` selects the guest scanout within the
/// backing texture; `dirtyRect` is scanout-local damage. Damage schedules a redraw only—the texture
/// remains the single authoritative surface and no partial framebuffer bytes are copied or queued.
public struct VirtioGPUScanoutTextureUpdate: Sendable, Equatable {
    public var scanoutID: UInt32
    public var presentation: VirtioGPUTexturePresentation
    public var sourceRect: VirtioGPURect
    public var dirtyRect: VirtioGPURect

    public var texture: VirtioGPUTextureResource { presentation.texture }
    public var resourceID: UInt32 { presentation.resourceID }
    public var resourceGeneration: UInt64 { presentation.resourceGeneration }

    public init(
        scanoutID: UInt32,
        presentation: VirtioGPUTexturePresentation,
        sourceRect: VirtioGPURect,
        dirtyRect: VirtioGPURect
    ) {
        self.scanoutID = scanoutID
        self.presentation = presentation
        self.sourceRect = sourceRect
        self.dirtyRect = dirtyRect
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scanoutID == rhs.scanoutID
            && lhs.resourceID == rhs.resourceID
            && lhs.resourceGeneration == rhs.resourceGeneration
            && lhs.texture == rhs.texture
            && lhs.sourceRect == rhs.sourceRect
            && lhs.dirtyRect == rhs.dirtyRect
    }
}

/// Acknowledged retirement of one guest resource generation from every configured scanout.
/// Renderer destruction is deferred until each scanout has detached any shared framebuffer
/// attachment and submitted that detach. Acknowledgements are keyed by scanout ID, making retries
/// idempotent and preventing one consumer from accidentally retiring another consumer's lease.
public final class VirtioGPUScanoutResourceRelease: @unchecked Sendable {
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let scanoutCount: UInt32

    private let lock = NSLock()
    private var pendingScanoutIDs: Set<UInt32>
    private var completion: (@Sendable () -> Void)?

    init(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        scanoutCount: UInt32,
        completion: @escaping @Sendable () -> Void
    ) {
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.scanoutCount = scanoutCount
        self.pendingScanoutIDs = Set(0..<scanoutCount)
        self.completion = completion
    }

    public func acknowledge(scanoutID: UInt32) {
        let completed: (@Sendable () -> Void)? = lock.withLock {
            guard pendingScanoutIDs.remove(scanoutID) != nil,
                  pendingScanoutIDs.isEmpty else {
                return nil
            }
            defer { completion = nil }
            return completion
        }
        completed?()
    }

    func acknowledgeAll() {
        let completed: (@Sendable () -> Void)? = lock.withLock {
            pendingScanoutIDs.removeAll()
            defer { completion = nil }
            return completion
        }
        completed?()
    }
}

public struct VirtioGPUStatistics: Equatable, Sendable {
    public var fences: UInt64
    public var fenceRegistrationFailures: UInt64
    public var fenceTimeouts: UInt64
    public var hasTimedOutPendingFence: Bool
    public var rendererDeviceLosses: UInt64
    public var hasLostRendererDevice: Bool
    public var queuePendingReadFailures: UInt64
    public var queuePopFailures: UInt64
    public var invalidDescriptorChains: UInt64
    public var oversizedRequests: UInt64
    public var insufficientResponseCapacity: UInt64
    public var queuePushFailures: UInt64
    public var revokedCompletions: UInt64
    public var undeliveredFenceCompletions: UInt64
    public var responseWriteFailures: UInt64
    public var fenceAdmissionRejections: UInt64
    public var queueRevokedFences: UInt64
    public var resetRevokedFences: UInt64
    public var rendererCommandUncertainties: UInt64
    public var revokedUncertainRendererCommands: UInt64
    public var rendererWorkerSnapshotCount: UInt64
    public var rendererWorkerSnapshotBytes: UInt64
    public var rendererWorkerSnapshotNanoseconds: UInt64
    public var rendererWorkerMaximumSnapshotNanoseconds: UInt64
    public var rendererWorkerQueuedCommands: Int
    public var rendererWorkerMaximumQueuedCommands: Int
    public var rendererWorkerRejectedAdmissions: UInt64
    public var rendererWorkerCompletedControlCommands: UInt64
    public var rendererWorkerCompletedResourceCommands: UInt64
    public var rendererWorkerCompletedSubmissions: UInt64
    public var rendererWorkerArmedFences: Int
    public var rendererWorkerCompletedFences: UInt64
    public var rendererWorkerScanoutCopyBytes: UInt64
    /// Guest-backing bytes copied into software scanout updates. This is separate from the worker
    /// accelerated path, whose scanout copy count is required to remain exactly zero.
    public var softwareScanoutCopiedBytes: UInt64

    public init(
        fences: UInt64,
        fenceRegistrationFailures: UInt64,
        fenceTimeouts: UInt64,
        hasTimedOutPendingFence: Bool,
        rendererDeviceLosses: UInt64 = 0,
        hasLostRendererDevice: Bool = false,
        queuePendingReadFailures: UInt64 = 0,
        queuePopFailures: UInt64 = 0,
        invalidDescriptorChains: UInt64 = 0,
        oversizedRequests: UInt64 = 0,
        insufficientResponseCapacity: UInt64 = 0,
        queuePushFailures: UInt64 = 0,
        revokedCompletions: UInt64 = 0,
        undeliveredFenceCompletions: UInt64 = 0,
        responseWriteFailures: UInt64 = 0,
        fenceAdmissionRejections: UInt64 = 0,
        queueRevokedFences: UInt64 = 0,
        resetRevokedFences: UInt64 = 0,
        rendererCommandUncertainties: UInt64 = 0,
        revokedUncertainRendererCommands: UInt64 = 0,
        rendererWorkerSnapshotCount: UInt64 = 0,
        rendererWorkerSnapshotBytes: UInt64 = 0,
        rendererWorkerSnapshotNanoseconds: UInt64 = 0,
        rendererWorkerMaximumSnapshotNanoseconds: UInt64 = 0,
        rendererWorkerQueuedCommands: Int = 0,
        rendererWorkerMaximumQueuedCommands: Int = 0,
        rendererWorkerRejectedAdmissions: UInt64 = 0,
        rendererWorkerCompletedControlCommands: UInt64 = 0,
        rendererWorkerCompletedResourceCommands: UInt64 = 0,
        rendererWorkerCompletedSubmissions: UInt64 = 0,
        rendererWorkerArmedFences: Int = 0,
        rendererWorkerCompletedFences: UInt64 = 0,
        rendererWorkerScanoutCopyBytes: UInt64 = 0,
        softwareScanoutCopiedBytes: UInt64 = 0
    ) {
        self.fences = fences
        self.fenceRegistrationFailures = fenceRegistrationFailures
        self.fenceTimeouts = fenceTimeouts
        self.hasTimedOutPendingFence = hasTimedOutPendingFence
        self.rendererDeviceLosses = rendererDeviceLosses
        self.hasLostRendererDevice = hasLostRendererDevice
        self.queuePendingReadFailures = queuePendingReadFailures
        self.queuePopFailures = queuePopFailures
        self.invalidDescriptorChains = invalidDescriptorChains
        self.oversizedRequests = oversizedRequests
        self.insufficientResponseCapacity = insufficientResponseCapacity
        self.queuePushFailures = queuePushFailures
        self.revokedCompletions = revokedCompletions
        self.undeliveredFenceCompletions = undeliveredFenceCompletions
        self.responseWriteFailures = responseWriteFailures
        self.fenceAdmissionRejections = fenceAdmissionRejections
        self.queueRevokedFences = queueRevokedFences
        self.resetRevokedFences = resetRevokedFences
        self.rendererCommandUncertainties = rendererCommandUncertainties
        self.revokedUncertainRendererCommands = revokedUncertainRendererCommands
        self.rendererWorkerSnapshotCount = rendererWorkerSnapshotCount
        self.rendererWorkerSnapshotBytes = rendererWorkerSnapshotBytes
        self.rendererWorkerSnapshotNanoseconds = rendererWorkerSnapshotNanoseconds
        self.rendererWorkerMaximumSnapshotNanoseconds =
            rendererWorkerMaximumSnapshotNanoseconds
        self.rendererWorkerQueuedCommands = rendererWorkerQueuedCommands
        self.rendererWorkerMaximumQueuedCommands = rendererWorkerMaximumQueuedCommands
        self.rendererWorkerRejectedAdmissions = rendererWorkerRejectedAdmissions
        self.rendererWorkerCompletedControlCommands =
            rendererWorkerCompletedControlCommands
        self.rendererWorkerCompletedResourceCommands =
            rendererWorkerCompletedResourceCommands
        self.rendererWorkerCompletedSubmissions = rendererWorkerCompletedSubmissions
        self.rendererWorkerArmedFences = rendererWorkerArmedFences
        self.rendererWorkerCompletedFences = rendererWorkerCompletedFences
        self.rendererWorkerScanoutCopyBytes = rendererWorkerScanoutCopyBytes
        self.softwareScanoutCopiedBytes = softwareScanoutCopiedBytes
    }
}

/// A renderer failure whose meaning is host-owned and therefore safe to publish as device-loss
/// telemetry. Ordinary renderer command errors are deliberately excluded: malformed guest 3D
/// commands must not be relabeled as a host GPU failure.
public enum VirtioGPURendererRuntimeFailure: Error, Equatable, Sendable {
    case deviceLost(String)
}

/// A renderer may report reset recovery only when every pre-reset context, resource, mapping, and
/// fence callback has been destroyed or made permanently unreachable before this call returns.
/// Returning `requiresRecreation` keeps the existing renderer object quarantined; the device will
/// reject further renderer-backed guest commands rather than pretend an in-place reset succeeded.
public enum VirtioGPURendererResetResult: Equatable, Sendable {
    case ready
    case requiresRecreation(String)
}

public enum VirtioGPURendererHealthFault: Error, Equatable, Sendable {
    case commandOutcomeUnknown(operation: String, detail: String)
    case fenceRegistrationFailed(String)
    case resetRequiresRecreation(String)
    case resetFailed(String)
    case resourceRetirementFailed(resourceID: UInt32, generation: UInt64, detail: String)
    case quiescenceTimedOut(epoch: UInt64)
}

public enum VirtioGPURendererLifecycleHealth: Equatable, Sendable {
    case notConfigured
    case ready(epoch: UInt64)
    case quiescing(epoch: UInt64)
    case failed(epoch: UInt64, fault: VirtioGPURendererHealthFault)
}

public enum VirtioGPUQuiescenceReason: Equatable, Sendable {
    case deviceReset
    case shutdown
}

public enum VirtioGPUQuiescenceOutcome: Equatable, Sendable {
    case completed
    case failed(VirtioGPURendererHealthFault)
}

/// Receipt for an asynchronous display/renderer quiescence boundary. MMIO reset waits on this
/// receipt before returning to the guest; process shutdown can request the same boundary without
/// blocking its caller and wait from an appropriate lifecycle queue.
public final class VirtioGPUQuiescence: @unchecked Sendable {
    public let epoch: UInt64
    public let reason: VirtioGPUQuiescenceReason

    private let condition = NSCondition()
    private var storedOutcome: VirtioGPUQuiescenceOutcome?

    init(epoch: UInt64, reason: VirtioGPUQuiescenceReason) {
        self.epoch = epoch
        self.reason = reason
    }

    public var outcome: VirtioGPUQuiescenceOutcome? {
        condition.lock()
        defer { condition.unlock() }
        return storedOutcome
    }

    public func wait(timeout: TimeInterval) -> VirtioGPUQuiescenceOutcome? {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while storedOutcome == nil, condition.wait(until: deadline) {}
        return storedOutcome
    }

    func complete(_ outcome: VirtioGPUQuiescenceOutcome) {
        condition.lock()
        guard storedOutcome == nil else {
            condition.unlock()
            return
        }
        storedOutcome = outcome
        condition.broadcast()
        condition.unlock()
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

public protocol VirtioGPURenderer: AnyObject, Sendable {
    var capsets: [VirtioGPUCapset] { get }
    /// True only when `makeScanoutPresentation` supplies a real producer-completion handoff.
    var supportsSynchronizedScanoutPresentation: Bool { get }
    var onRuntimeFailure: ((VirtioGPURendererRuntimeFailure) -> Void)? { get set }
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
    /// Returns a shared texture together with synchronization authority covering all producer work
    /// submitted before this call. Implementations must fail closed when they cannot identify the
    /// producer context or cannot create a completion primitive usable by the display context.
    func makeScanoutPresentation(
        resourceID: UInt32,
        resourceGeneration: UInt64
    ) throws -> VirtioGPUTexturePresentation
    /// Called only after every display release has been acknowledged and every device-tracked
    /// renderer resource has been unmapped/unreferenced. `.ready` is a strong epoch barrier: no
    /// fence callback or renderer state from the old guest epoch may become observable afterward.
    func resetAfterDeviceQuiesce() throws -> VirtioGPURendererResetResult
    /// Registers a fence that must call `onFenceSignaled` (possibly from another thread) once all
    /// GPU work submitted before it has completed. Context fences order per (context, ring); plain
    /// fences ride the global ctx0 timeline and signal as (0, 0, id).
    func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws
    var onFenceSignaled: ((_ contextID: UInt32, _ ringIndex: UInt32, _ fenceID: UInt64) -> Void)? { get set }
}

public extension VirtioGPURenderer {
    var supportsSynchronizedScanoutPresentation: Bool { false }

    func makeScanoutPresentation(
        resourceID: UInt32,
        resourceGeneration: UInt64
    ) throws -> VirtioGPUTexturePresentation {
        throw VirtioGPURendererCommandRejected(
            "renderer does not provide synchronized shared-texture presentation"
        )
    }

    func resetAfterDeviceQuiesce() throws -> VirtioGPURendererResetResult {
        .requiresRecreation("renderer does not implement recreate-safe in-place reset")
    }
}

extension VirtioGPUMemoryEntry: @unchecked Sendable {}

/// A renderer adapter may use this error only when it can prove that a command was rejected before
/// any renderer-visible mutation. Every other thrown error is conservatively classified as an
/// unknown outcome by `VirtioGPURendererCommandExecutor`.
public struct VirtioGPURendererCommandRejected: Error, Equatable, Sendable {
    public let detail: String

    public init(_ detail: String) {
        self.detail = detail
    }
}

enum VirtioGPURendererCommand: @unchecked Sendable {
    case createContext(id: UInt32, flags: UInt32, name: String)
    case destroyContext(id: UInt32)
    case attachResource(contextID: UInt32, resourceID: UInt32)
    case detachResource(contextID: UInt32, resourceID: UInt32)
    case submit3D(contextID: UInt32, command: [UInt8])
    case createResource3D(VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry])
    case createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64,
        entries: [VirtioGPUMemoryEntry]
    )
    case attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry])
    case detachBacking(resourceID: UInt32)
    case unrefResource(resourceID: UInt32)
    case mapBlob(resourceID: UInt32)
    case unmapBlob(resourceID: UInt32)
    case transferToHost3D(VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry])
    case transferFromHost3D(VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry])
    case makeScanoutPresentation(resourceID: UInt32, resourceGeneration: UInt64)
    case createFence(
        contextID: UInt32,
        ringIndex: UInt32,
        guestFenceID: UInt64,
        contextFence: Bool
    )
    case resetAfterDeviceQuiesce(successorGeneration: UInt64)

    var operation: String {
        switch self {
        case .createContext: "create-context"
        case .destroyContext: "destroy-context"
        case .attachResource: "attach-resource"
        case .detachResource: "detach-resource"
        case .submit3D: "submit-3d"
        case .createResource3D: "create-resource-3d"
        case .createBlob: "create-blob"
        case .attachBacking: "attach-backing"
        case .detachBacking: "detach-backing"
        case .unrefResource: "unref-resource"
        case .mapBlob: "map-blob"
        case .unmapBlob: "unmap-blob"
        case .transferToHost3D: "transfer-to-host-3d"
        case .transferFromHost3D: "transfer-from-host-3d"
        case .makeScanoutPresentation: "make-scanout-presentation"
        case .createFence: "create-fence"
        case .resetAfterDeviceQuiesce: "reset-after-device-quiesce"
        }
    }
}

enum VirtioGPURendererCommandValue: @unchecked Sendable {
    case none
    case blobMapping(VirtioGPUBlobMapping)
    case scanoutPresentation(VirtioGPUTexturePresentation)
    case reset(VirtioGPURendererResetResult)
}

enum VirtioGPURendererCommandRejection: Equatable, Sendable {
    case invalidInput(operation: String, detail: String)
    case staleGeneration(expected: UInt64, actual: UInt64)
    case admissionClosed(generation: UInt64)
    case renderer(operation: String, detail: String)
}

struct VirtioGPURendererCommandUncertainty: Equatable, Sendable {
    var operation: String
    var generation: UInt64
    var detail: String
    var runtimeFailure: VirtioGPURendererRuntimeFailure?
}

enum VirtioGPURendererCommandOutcome: @unchecked Sendable {
    case success(VirtioGPURendererCommandValue)
    case rejected(VirtioGPURendererCommandRejection)
    case outcomeUnknown(VirtioGPURendererCommandUncertainty)
}

enum VirtioGPURendererCommandPurpose: Sendable {
    case guest
    case retirement
}

enum VirtioGPURendererQuiescenceAdmission: Equatable, Sendable {
    case admitted(sourceGeneration: UInt64)
    case rejected(VirtioGPURendererCommandRejection)
}

/// The legacy in-process renderer serialization seam.
///
/// All device-to-renderer calls, including callback installation, pass through this executor. It
/// serializes one renderer generation, owns bounded copies of variable command metadata, assigns
/// non-reused host fence identities, and never guesses that a thrown adapter call was harmless.
/// It is retained only until the signed worker has equivalent operation coverage. Production
/// cutover must replace pointer-bearing commands with the typed renderer-worker envelopes,
/// descriptor-backed regions, SHM scanout leases, and producer-fence/release receipts; helper death
/// is an outcome-unknown generation. This executor and VirglRenderer must be deleted in the same
/// cutover that selects the qualified worker—never left as an accelerated fallback.
final class VirtioGPURendererCommandExecutor: @unchecked Sendable {
    private enum State {
        case active(UInt64)
        case revoked(UInt64)
        case uncertain(UInt64)
        case quiescing(source: UInt64, successor: UInt64)
    }

    private enum FenceRegistrationState {
        case registering(signalObserved: Bool)
        case registered
    }

    private struct FenceCallbackKey: Hashable {
        var contextID: UInt32
        var ringIndex: UInt32
        var hostFenceID: UInt64
    }

    private struct FenceRegistration {
        var generation: UInt64
        var guestContextID: UInt32
        var guestRingIndex: UInt32
        var guestFenceID: UInt64
        var state: FenceRegistrationState
    }

    let capsets: [VirtioGPUCapset]
    let supportsSynchronizedScanoutPresentation: Bool

    private let renderer: VirtioGPURenderer
    private let maximumCommandBytes: Int
    private let maximumMemoryEntries: Int
    private let maximumReferencedBytes: UInt64
    private let lock = NSRecursiveLock()
    private var state: State
    private var nextHostFenceID: UInt64 = 1
    private var fences = [FenceCallbackKey: FenceRegistration]()
    private var fenceSink: ((UInt64, UInt32, UInt32, UInt64) -> Void)?
    private var runtimeFailureSink: ((UInt64, VirtioGPURendererRuntimeFailure) -> Void)?

    init(
        renderer: VirtioGPURenderer,
        initialGeneration: UInt64 = 1,
        maximumCommandBytes: Int,
        maximumMemoryEntries: Int,
        maximumReferencedBytes: UInt64
    ) {
        self.renderer = renderer
        self.capsets = renderer.capsets.map {
            VirtioGPUCapset(id: $0.id, maxVersion: $0.maxVersion, data: Array($0.data))
        }
        self.supportsSynchronizedScanoutPresentation =
            renderer.supportsSynchronizedScanoutPresentation
        self.maximumCommandBytes = max(1, maximumCommandBytes)
        self.maximumMemoryEntries = max(1, maximumMemoryEntries)
        self.maximumReferencedBytes = max(1, maximumReferencedBytes)
        self.state = .active(initialGeneration == 0 ? 1 : initialGeneration)
        renderer.onFenceSignaled = { [weak self] contextID, ringIndex, fenceID in
            self?.receiveFence(contextID: contextID, ringIndex: ringIndex, hostFenceID: fenceID)
        }
        renderer.onRuntimeFailure = { [weak self] failure in
            self?.receiveRuntimeFailure(failure)
        }
    }

    func installCallbacks(
        fence: @escaping @Sendable (UInt64, UInt32, UInt32, UInt64) -> Void,
        runtimeFailure: @escaping @Sendable (UInt64, VirtioGPURendererRuntimeFailure) -> Void
    ) {
        lock.withLock {
            fenceSink = fence
            runtimeFailureSink = runtimeFailure
        }
    }

    func revokeActiveGeneration() {
        lock.withLock {
            switch state {
            case .active(let generation), .uncertain(let generation):
                state = .revoked(generation)
                fences.removeAll()
            case .revoked, .quiescing:
                break
            }
        }
    }

    func beginQuiescence(successorGeneration: UInt64) -> VirtioGPURendererQuiescenceAdmission {
        lock.withLock {
            let source: UInt64
            switch state {
            case .active(let generation), .revoked(let generation), .uncertain(let generation):
                source = generation
            case .quiescing(let generation, let existingSuccessor):
                guard existingSuccessor == successorGeneration else {
                    return .rejected(.admissionClosed(generation: generation))
                }
                return .admitted(sourceGeneration: generation)
            }
            guard successorGeneration != 0, successorGeneration != source else {
                return .rejected(.invalidInput(
                    operation: "begin-quiescence",
                    detail: "successor generation must be nonzero and distinct"
                ))
            }
            state = .quiescing(source: source, successor: successorGeneration)
            fences.removeAll()
            return .admitted(sourceGeneration: source)
        }
    }

    func execute(
        _ requestedCommand: VirtioGPURendererCommand,
        generation: UInt64,
        purpose: VirtioGPURendererCommandPurpose = .guest
    ) -> VirtioGPURendererCommandOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard let command = boundedCopy(of: requestedCommand) else {
            return .rejected(.invalidInput(
                operation: requestedCommand.operation,
                detail: "renderer command exceeds its configured input bound"
            ))
        }
        if case .resetAfterDeviceQuiesce(let successor) = command {
            return executeReset(
                generation: generation,
                successorGeneration: successor,
                operation: command.operation
            )
        }
        guard admits(generation: generation, purpose: purpose) else {
            return generationRejection(for: generation)
        }
        if case let .createFence(contextID, ringIndex, guestFenceID, contextFence) = command {
            return executeFence(
                generation: generation,
                contextID: contextID,
                ringIndex: ringIndex,
                guestFenceID: guestFenceID,
                contextFence: contextFence
            )
        }

        do {
            let value = try invoke(command)
            return .success(value)
        } catch let rejection as VirtioGPURendererCommandRejected {
            return .rejected(.renderer(
                operation: command.operation,
                detail: rejection.detail
            ))
        } catch {
            state = .uncertain(generation)
            fences.removeAll()
            return .outcomeUnknown(uncertainty(
                operation: command.operation,
                generation: generation,
                error: error
            ))
        }
    }

    private func admits(
        generation: UInt64,
        purpose: VirtioGPURendererCommandPurpose
    ) -> Bool {
        switch (state, purpose) {
        case (.active(let active), .guest),
             (.active(let active), .retirement),
             (.revoked(let active), .retirement),
             (.quiescing(let active, _), .retirement):
            return active == generation
        case (.revoked, .guest), (.uncertain, _), (.quiescing, .guest):
            return false
        }
    }

    private func generationRejection(for generation: UInt64) -> VirtioGPURendererCommandOutcome {
        let actual: UInt64
        switch state {
        case .active(let value):
            actual = value
        case .revoked(let value), .uncertain(let value):
            actual = value
        case .quiescing(let value, _):
            actual = value
        }
        return actual == generation
            ? .rejected(.admissionClosed(generation: generation))
            : .rejected(.staleGeneration(expected: actual, actual: generation))
    }

    private func executeReset(
        generation: UInt64,
        successorGeneration: UInt64,
        operation: String
    ) -> VirtioGPURendererCommandOutcome {
        guard case .quiescing(let source, let successor) = state,
              source == generation,
              successor == successorGeneration else {
            return generationRejection(for: generation)
        }
        do {
            let result = try renderer.resetAfterDeviceQuiesce()
            switch result {
            case .ready:
                state = .active(successorGeneration)
            case .requiresRecreation:
                state = .revoked(generation)
            }
            fences.removeAll()
            return .success(.reset(result))
        } catch let rejection as VirtioGPURendererCommandRejected {
            state = .revoked(generation)
            return .rejected(.renderer(operation: operation, detail: rejection.detail))
        } catch {
            state = .uncertain(generation)
            fences.removeAll()
            return .outcomeUnknown(uncertainty(
                operation: operation,
                generation: generation,
                error: error
            ))
        }
    }

    private func executeFence(
        generation: UInt64,
        contextID: UInt32,
        ringIndex: UInt32,
        guestFenceID: UInt64,
        contextFence: Bool
    ) -> VirtioGPURendererCommandOutcome {
        guard nextHostFenceID <= UInt64(UInt32.max) else {
            return .rejected(.invalidInput(
                operation: "create-fence",
                detail: "host fence identity space exhausted"
            ))
        }
        let hostFenceID = nextHostFenceID
        nextHostFenceID += 1
        let callbackKey = FenceCallbackKey(
            contextID: contextFence ? contextID : 0,
            ringIndex: contextFence ? ringIndex : 0,
            hostFenceID: hostFenceID
        )
        fences[callbackKey] = FenceRegistration(
            generation: generation,
            guestContextID: contextFence ? contextID : 0,
            guestRingIndex: contextFence ? ringIndex : 0,
            guestFenceID: guestFenceID,
            state: .registering(signalObserved: false)
        )

        do {
            try renderer.createFence(
                contextID: contextID,
                ringIndex: ringIndex,
                fenceID: hostFenceID,
                contextFence: contextFence
            )
        } catch let rejection as VirtioGPURendererCommandRejected {
            fences.removeValue(forKey: callbackKey)
            return .rejected(.renderer(operation: "create-fence", detail: rejection.detail))
        } catch {
            fences.removeValue(forKey: callbackKey)
            state = .uncertain(generation)
            return .outcomeUnknown(uncertainty(
                operation: "create-fence",
                generation: generation,
                error: error
            ))
        }

        if var registration = fences[callbackKey] {
            switch registration.state {
            case .registering(let signalObserved) where signalObserved:
                fences.removeValue(forKey: callbackKey)
                let sink = fenceSink
                // NSRecursiveLock permits a synchronous renderer callback to record completion.
                // Deliver only after registration itself has returned success.
                sink?(
                    registration.generation,
                    registration.guestContextID,
                    registration.guestRingIndex,
                    registration.guestFenceID
                )
            case .registering:
                registration.state = .registered
                fences[callbackKey] = registration
            case .registered:
                break
            }
        }
        return .success(.none)
    }

    private func receiveFence(contextID: UInt32, ringIndex: UInt32, hostFenceID: UInt64) {
        let sinkAndRegistration: (
            ((UInt64, UInt32, UInt32, UInt64) -> Void),
            FenceRegistration
        )? = lock.withLock {
            let key = FenceCallbackKey(
                contextID: contextID,
                ringIndex: ringIndex,
                hostFenceID: hostFenceID
            )
            guard var registration = fences[key] else { return nil }
            switch registration.state {
            case .registering:
                registration.state = .registering(signalObserved: true)
                fences[key] = registration
                return nil
            case .registered:
                guard case .active(let activeGeneration) = state,
                      activeGeneration == registration.generation,
                      let fenceSink else {
                    fences.removeValue(forKey: key)
                    return nil
                }
                fences.removeValue(forKey: key)
                return (fenceSink, registration)
            }
        }
        guard let (sink, registration) = sinkAndRegistration else { return }
        sink(
            registration.generation,
            registration.guestContextID,
            registration.guestRingIndex,
            registration.guestFenceID
        )
    }

    private func receiveRuntimeFailure(_ failure: VirtioGPURendererRuntimeFailure) {
        let sinkAndGeneration: (((UInt64, VirtioGPURendererRuntimeFailure) -> Void), UInt64)? =
            lock.withLock {
                guard case .active(let generation) = state, let runtimeFailureSink else {
                    return nil
                }
                return (runtimeFailureSink, generation)
            }
        guard let (sink, generation) = sinkAndGeneration else { return }
        sink(generation, failure)
    }

    private func invoke(_ command: VirtioGPURendererCommand) throws -> VirtioGPURendererCommandValue {
        switch command {
        case let .createContext(id, flags, name):
            try renderer.createContext(id: id, flags: flags, name: name)
        case .destroyContext(let id):
            try renderer.destroyContext(id: id)
        case let .attachResource(contextID, resourceID):
            try renderer.attachResource(contextID: contextID, resourceID: resourceID)
        case let .detachResource(contextID, resourceID):
            try renderer.detachResource(contextID: contextID, resourceID: resourceID)
        case let .submit3D(contextID, command):
            try renderer.submit3D(contextID: contextID, command: command)
        case let .createResource3D(resource, entries):
            try renderer.createResource3D(resource, entries: entries)
        case let .createBlob(resourceID, contextID, memory, flags, blobID, size, entries):
            try renderer.createBlob(
                resourceID: resourceID,
                contextID: contextID,
                blobMemory: memory,
                blobFlags: flags,
                blobID: blobID,
                size: size,
                entries: entries
            )
        case let .attachBacking(resourceID, entries):
            try renderer.attachBacking(resourceID: resourceID, entries: entries)
        case .detachBacking(let resourceID):
            try renderer.detachBacking(resourceID: resourceID)
        case .unrefResource(let resourceID):
            try renderer.unrefResource(resourceID: resourceID)
        case .mapBlob(let resourceID):
            return .blobMapping(try renderer.mapBlob(resourceID: resourceID))
        case .unmapBlob(let resourceID):
            try renderer.unmapBlob(resourceID: resourceID)
        case let .transferToHost3D(transfer, entries):
            try renderer.transferToHost3D(transfer, entries: entries)
        case let .transferFromHost3D(transfer, entries):
            try renderer.transferFromHost3D(transfer, entries: entries)
        case let .makeScanoutPresentation(resourceID, resourceGeneration):
            return .scanoutPresentation(try renderer.makeScanoutPresentation(
                resourceID: resourceID,
                resourceGeneration: resourceGeneration
            ))
        case .createFence, .resetAfterDeviceQuiesce:
            preconditionFailure("special renderer commands must use their lifecycle executor")
        }
        return .none
    }

    private func boundedCopy(
        of command: VirtioGPURendererCommand
    ) -> VirtioGPURendererCommand? {
        switch command {
        case let .createContext(id, flags, name):
            guard name.utf8.count <= 64 else { return nil }
            return .createContext(id: id, flags: flags, name: String(name))
        case let .submit3D(contextID, bytes):
            guard bytes.count <= maximumCommandBytes else { return nil }
            return .submit3D(contextID: contextID, command: Array(bytes))
        case let .createResource3D(resource, entries):
            guard let entries = boundedEntries(entries) else { return nil }
            return .createResource3D(resource, entries: entries)
        case let .createBlob(resourceID, contextID, memory, flags, blobID, size, entries):
            guard size <= maximumReferencedBytes,
                  let entries = boundedEntries(entries) else { return nil }
            return .createBlob(
                resourceID: resourceID,
                contextID: contextID,
                blobMemory: memory,
                blobFlags: flags,
                blobID: blobID,
                size: size,
                entries: entries
            )
        case let .attachBacking(resourceID, entries):
            guard let entries = boundedEntries(entries) else { return nil }
            return .attachBacking(resourceID: resourceID, entries: entries)
        case let .transferToHost3D(transfer, entries):
            guard transfer.box.count == 6,
                  let entries = boundedEntries(entries) else { return nil }
            var copied = transfer
            copied.box = Array(transfer.box)
            return .transferToHost3D(copied, entries: entries)
        case let .transferFromHost3D(transfer, entries):
            guard transfer.box.count == 6,
                  let entries = boundedEntries(entries) else { return nil }
            var copied = transfer
            copied.box = Array(transfer.box)
            return .transferFromHost3D(copied, entries: entries)
        default:
            return command
        }
    }

    private func boundedEntries(
        _ entries: [VirtioGPUMemoryEntry]
    ) -> [VirtioGPUMemoryEntry]? {
        guard entries.count <= maximumMemoryEntries else { return nil }
        var total: UInt64 = 0
        for entry in entries {
            guard entry.length > 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.length))
            guard !overflow, next <= maximumReferencedBytes else { return nil }
            total = next
        }
        return Array(entries)
    }

    private func uncertainty(
        operation: String,
        generation: UInt64,
        error: Error
    ) -> VirtioGPURendererCommandUncertainty {
        VirtioGPURendererCommandUncertainty(
            operation: operation,
            generation: generation,
            detail: String(describing: error),
            runtimeFailure: error as? VirtioGPURendererRuntimeFailure
        )
    }
}

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

/// Virtio-gpu device with an explicitly gated renderer authority.
///
/// A renderer authority is either the legacy in-process compatibility object or one already
/// authenticated signed-worker lane; two authorities fail closed. Worker capsets and device
/// features come only from its complete capability receipt, while all command and presentation
/// completion remains generation-bound to that lane.
public final class VirtioGPU: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider, @unchecked Sendable {
    public let deviceID: UInt32 = 16
    public let queueCount = 2
    public var deviceFeatures: UInt64 {
        guard rendererAuthorityIsConfigured,
              rendererCapabilitiesAreAdvertised else { return 0 }
        return configuredRendererDeviceFeatures
    }
    public let sharedMemoryRegions: [VirtioSharedMemoryRegion]

    private let scanoutCount: UInt32
    private let displayLock = NSLock()
    private var scanoutSizes: [VirtioGPUScanoutSize]
    private var pendingDisplayEvents: UInt32 = 0
    private let onScanoutFrame: (@Sendable (VirtioGPUScanoutFrame) -> Void)?
    private let onScanoutTexture: (@Sendable (VirtioGPUScanoutTextureUpdate) -> Void)?
    private let onMetalScanout: (@Sendable (VirtioGPUMetalScanoutUpdate) -> Void)?
    private let onScanoutResourceReleased: (@Sendable (VirtioGPUScanoutResourceRelease) -> Void)?
    private let onScanoutDisabled: (@Sendable (UInt32) -> Void)?
    private let onCursorUpdate: (@Sendable (VirtioGPUCursorUpdate?) -> Void)?
    private let onRendererWorkerFailure: (@Sendable (String) -> Void)?
    private let rendererExecutor: VirtioGPURendererCommandExecutor?
    private let rendererWorkerCandidate: DoryRendererWorkerVirtioCommandLane?
    private let configuredRendererDeviceFeatures: UInt64
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

    private struct CursorResourceSnapshot {
        var width: UInt32
        var height: UInt32
        var bytes: Data
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
    private var scanouts: [UInt32: ScanoutBinding] = [:]
    private var cursorResourceID: UInt32?
    private var commandFailureCounts: [UInt32: Int] = [:]
    private let traceResourceLifecycle: Bool
    private var resourceTraceSequence: UInt64 = 0
    /// The cursor virtqueue reads resources created and retired on the control virtqueue. VCPU
    /// kicks may arrive concurrently, so serialize command interpretation while leaving descriptor
    /// dequeue/completion and renderer fence delivery on their existing independent locks.
    private let commandLock = NSLock()
    private struct RendererWorkerSnapshotMetrics {
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        var nanoseconds: UInt64 = 0
        var maximumNanoseconds: UInt64 = 0
    }
    private let rendererWorkerMetricsLock = NSLock()
    private var rendererWorkerSnapshotMetrics = RendererWorkerSnapshotMetrics()
    private let rendererWorkerScanoutDiagnosticLock = NSLock()
    private var rendererWorkerScanoutDiagnosticStages = Set<String>()
    private let softwareScanoutMetricsLock = NSLock()
    private var softwareScanoutCopiedBytes: UInt64 = 0
    private let rendererWorkerPresentationLock = NSLock()
    private var rendererWorkerPendingScanouts = [
        DoryRendererScanoutReleaseToken: DoryRendererWorkerSharedScanoutCore
    ]()
    private var rendererWorkerLiveScanouts = [
        DoryRendererScanoutReleaseToken: DoryRendererWorkerWeakScanoutCore
    ]()
    private let rendererWorkerPresentationQueue = DispatchQueue(
        label: "dev.dory.gpu.renderer-worker-presentation",
        qos: .userInteractive
    )
    private let rendererWorkerResumeQueue = DispatchQueue(
        label: "dev.dory.gpu.renderer-worker-queue-resume",
        qos: .userInteractive
    )

    // Real fence signalling: a fenced command's descriptor is held here and completed only when the
    // renderer signals the fence (from its own thread), per the virtio-gpu contract — responding
    // immediately would tell the guest its GPU work finished before it did.
    private struct FenceKey: Hashable {
        var contextID: UInt32
        var ringIndex: UInt32
    }

    private struct PendingFence {
        var token: UInt64
        var fenceID: UInt64
        var epoch: UInt64
        var response: [UInt8]
        var chain: VirtqueueChain
        var createdAtMonotonicNanoseconds: UInt64
        var timeoutReported: Bool
    }

    private struct FenceRequest {
        var key: FenceKey
        var contextID: UInt32
        var ringIndex: UInt32
        var fenceID: UInt64
        var contextFence: Bool
    }

    private enum FenceAdmission {
        case notRequested
        case admitted(FenceRequest)
        case rejected
    }

    private enum FenceDeferralOutcome {
        case immediate
        case deferred
        /// The renderer accepted the command but could not establish its completion boundary.
        /// Keep the descriptor owned until reset rather than publishing a false completion.
        case outcomeUnknown
    }

    private struct RendererCommandOutcomeUnknownSignal: Error {
        var uncertainty: VirtioGPURendererCommandUncertainty
    }

    private enum CommandProcessingOutcome {
        case response([UInt8])
        /// The renderer may have committed the command. The descriptor remains device-owned until
        /// queue revocation/reset rather than receiving a fabricated success or rejection.
        case outcomeUnknown(VirtioGPURendererCommandUncertainty)
    }

    private enum QueueAdmissionRejection {
        case invalidDescriptorLayout
        case oversizedRequest
        case insufficientResponseCapacity
    }

    private enum QueueAdmissionOutcome {
        case admitted(request: [UInt8], writesResponse: Bool)
        case workerControl(WorkerControlAdmission)
        case workerCreateResource3D(WorkerCreateResource3DAdmission)
        case workerCreateBlob(WorkerCreateBlobAdmission)
        case workerAttachBacking(WorkerAttachBackingAdmission)
        case workerDetachBacking(WorkerDetachBackingAdmission)
        case workerTransfer(WorkerTransferAdmission)
        case workerUnref(WorkerUnrefAdmission)
        case workerMapBlob(WorkerMapBlobAdmission)
        case workerUnmapBlob(WorkerUnmapBlobAdmission)
        case workerFlushScanout(WorkerFlushScanoutAdmission)
        case workerSubmit(WorkerSubmitAdmission)
        case workerRejected(requestHeader: [UInt8])
        case rejected(QueueAdmissionRejection)
        case revoked
    }

    private struct WorkerSubmitAdmission: @unchecked Sendable {
        let requestHeader: [UInt8]
        let regions: DoryRendererWorkerSharedRegionSet
        let fence: FenceRequest?
    }

    private struct WorkerAttachBackingAdmission: @unchecked Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let resourceGeneration: UInt64
        let entries: [VirtioGPUMemoryEntry]
        let regions: DoryRendererWorkerSharedRegionSet
        let fence: FenceRequest?
    }

    private struct WorkerDetachBackingAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let resourceGeneration: UInt64
        let fence: FenceRequest?
    }

    private enum WorkerTransferDirection: Sendable {
        case toHost
        case fromHost
    }

    private struct WorkerTransferAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let resourceGeneration: UInt64
        let contextID: UInt32
        let payload: DoryRendererTransfer3DPayload
        let direction: WorkerTransferDirection
        let fence: FenceRequest?
    }

    private struct WorkerUnrefAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let workerResourceGeneration: UInt64
        let displayResourceGeneration: UInt64
        let fence: FenceRequest?
    }

    private struct WorkerCreateBlobAdmission: @unchecked Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let contextID: UInt32
        let payload: DoryRendererBlobCreatePayload
        let entries: [VirtioGPUMemoryEntry]
        let regions: DoryRendererWorkerSharedRegionSet
    }

    private enum WorkerCreatedResourceKind: Equatable, Sendable {
        case resource2D
        case resource3D
    }

    private struct WorkerCreateResource3DAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let payload: DoryRendererResource3DCreatePayload
        let kind: WorkerCreatedResourceKind
        let fence: FenceRequest?
    }

    private struct WorkerMapBlobAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let resourceGeneration: UInt64
        let hostVisibleOffset: UInt64
    }

    private struct WorkerUnmapBlobAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let resourceGeneration: UInt64
    }

    private struct WorkerFlushTarget: Sendable {
        let scanoutID: UInt32
        let sourceRect: VirtioGPURect
        let dirtyRect: VirtioGPURect
    }

    private struct WorkerScanoutSurface: Equatable, Sendable {
        let width: UInt32
        let height: UInt32
        let format: UInt32
        let stride: UInt32
        let offset: UInt32
    }

    private struct WorkerFlushScanoutAdmission: Sendable {
        let request: [UInt8]
        let resourceID: UInt32
        let workerResourceGeneration: UInt64
        let displayResourceGeneration: UInt64
        let surface: WorkerScanoutSurface?
        let targets: [WorkerFlushTarget]
        let fence: FenceRequest?
    }

    private enum WorkerControlOperation: Sendable {
        case createContext(name: String, capsetID: UInt32)
        case destroyContext
        case attachResource(resourceID: UInt32)
        case detachResource(resourceID: UInt32)
    }

    private struct WorkerControlAdmission: Sendable {
        let request: [UInt8]
        let contextID: UInt32
        let operation: WorkerControlOperation
    }

    private enum QueueCompletionOutcome {
        case published(wantsInterrupt: Bool)
        case revoked
        case failed
    }

    private enum QueueDrainOutcome {
        case drained(wantsInterrupt: Bool)
        case pendingReadFailed
        case popFailed(wantsInterrupt: Bool)
        case completionFailed(wantsInterrupt: Bool)
    }

    private enum TelemetryEvent {
        case queuePendingReadFailure
        case queuePopFailure
        case invalidDescriptorChain
        case oversizedRequest
        case insufficientResponseCapacity
        case queuePushFailure
        case revokedCompletion
        case undeliveredFenceCompletion
        case responseWriteFailure
        case fenceAdmissionRejection
        case queueRevokedFence
        case resetRevokedFence
        case rendererCommandUncertainty
        case revokedUncertainRendererCommand
    }

    private let fenceLock = NSLock()
    private var pendingFences: [FenceKey: [PendingFence]] = [:]
    /// Fence creation failed after the renderer command crossed its mutation boundary. These
    /// chains remain owned until queue revocation/reset, but are kept out of callback lookup so a
    /// late signal from an older fence can never fabricate their completion.
    private var uncertainFences = [PendingFence]()
    private var uncertainRendererCommandChains = [VirtqueueChain]()
    private weak var lastTransport: VirtioMMIOTransport?
    /// Never reset to zero. Fence callbacks may arrive after MMIO reset; the epoch is rechecked
    /// while holding the transport queue lock so a callback already in flight cannot publish into
    /// the replacement queue.
    private var lifecycleEpoch: UInt64 = 1
    private var nextFenceToken: UInt64 = 1
    private var pendingFenceCount = 0
    private var pendingFenceResponseBytes = 0
    /// QueueReady can revoke a descriptor while its renderer callback remains in flight. Because
    /// virglrenderer callbacks do not carry a queue generation, do not admit another renderer
    /// fence after such a revocation until the renderer's full reset barrier has completed.
    private var fenceAdmissionBlockedUntilDeviceReset = false
    private let fenceTimeoutNanoseconds: UInt64
    private var fenceCount: UInt64 = 0
    private var fenceRegistrationFailureCount: UInt64 = 0
    private var fenceTimeoutCount: UInt64 = 0
    private var rendererDeviceLossCount: UInt64 = 0
    private var rendererDeviceLossLatched = false
    private var queuePendingReadFailureCount: UInt64 = 0
    private var queuePopFailureCount: UInt64 = 0
    private var invalidDescriptorChainCount: UInt64 = 0
    private var oversizedRequestCount: UInt64 = 0
    private var insufficientResponseCapacityCount: UInt64 = 0
    private var queuePushFailureCount: UInt64 = 0
    private var revokedCompletionCount: UInt64 = 0
    private var undeliveredFenceCompletionCount: UInt64 = 0
    private var responseWriteFailureCount: UInt64 = 0
    private var fenceAdmissionRejectionCount: UInt64 = 0
    private var queueRevokedFenceCount: UInt64 = 0
    private var resetRevokedFenceCount: UInt64 = 0
    private var rendererCommandUncertaintyCount: UInt64 = 0
    private var revokedUncertainRendererCommandCount: UInt64 = 0
    private var resourceGenerations: [UInt32: UInt64] = [:]
    /// Exact worker generations returned by authenticated create replies. These are never derived
    /// from the independent display/resource lifetime generation above.
    private var rendererWorkerResourceGenerations: [UInt32: UInt64] = [:]
    /// Context/resource attachment ownership is committed only by authenticated worker replies.
    /// RESOURCE_FLUSH derives its context-timeline fence from this single authority and fails closed
    /// when a resource is attached to zero or multiple contexts.
    private var rendererWorkerResourceContextIDs: [UInt32: Set<UInt32>] = [:]
    /// Reserves IDs while create mutations are asynchronous so another vCPU kick cannot race a
    /// local 2D/blob allocation into the same guest resource identity.
    private var rendererWorkerPendingResourceIDs = Set<UInt32>()
    private var rendererWorkerPendingBackingResourceIDs = Set<UInt32>()
    private var rendererWorkerPendingMappingResourceIDs = Set<UInt32>()
    /// Unique ownership of the one worker command that currently holds controlq ordering. Device
    /// generation alone is not an identity: an older pipelined submit can complete while a newer
    /// state mutation is pending in the same generation. Only the exact claim may release the
    /// barrier after its used entry has been published.
    private struct RendererWorkerControlCommandClaim: Equatable, Sendable {
        let generation: UInt64
        let token: UInt64
    }
    private var rendererWorkerControlCommandClaim: RendererWorkerControlCommandClaim?
    private var nextRendererWorkerControlCommandToken: UInt64 = 1
    private var nextResourceGeneration: UInt64 = 1
    private let maximumTrackedResources: Int
    private let maximumControlRequestBytes: Int
    /// Raw guest scatter/gather descriptors admitted from the virtqueue. Losslessly adjacent
    /// entries are normalized, but ordinary Linux GEM/shmem pages can remain physically
    /// discontiguous. The resulting list is bounded by the authenticated worker contract and by
    /// independent request-byte and referenced-byte ceilings.
    private let maximumRawMemoryEntries: Int
    private let maximumMemoryEntries: Int
    private let maximumRendererReferencedBytes: UInt64
    private let maximumPendingFences: Int
    private let maximumPendingFenceResponseBytes: Int
    private let maximumCopiedScanoutSurfaceBytes: UInt64
    private let quiescenceTimeout: TimeInterval

    private struct ResourceRetirementKey: Hashable, Sendable {
        var resourceID: UInt32
        var generation: UInt64
    }

    private struct QuiescingResource: Sendable {
        var key: ResourceRetirementKey
        var requiresBlobUnmap: Bool
    }

    private struct ActiveQuiescence {
        var receipt: VirtioGPUQuiescence
        var rendererGeneration: UInt64
        var workerReboundForPristineDeviceReset: Bool
        var rendererResources: [QuiescingResource]
        var awaitingReleaseAcknowledgements: Set<ResourceRetirementKey>
        var priorRetirements: Set<ResourceRetirementKey>
        var cleanupScheduled: Bool
    }

    /// Resource IDs remain reserved after guest-visible unref/reset until every display has
    /// detached its generation and host destruction has completed. The same bound applies with no
    /// renderer, preventing an untrusted guest from growing mailbox release storage without limit.
    private let lifecycleLock = NSLock()
    private let rendererRetirementQueue = DispatchQueue(label: "dev.dory.gpu.resource-retirement")
    private var retiringResources: [UInt32: UInt64] = [:]
    private var activeQuiescence: ActiveQuiescence?
    private var rendererLifecycleHealthState: VirtioGPURendererLifecycleHealth
    private var acceptingGuestCommands = true
    private var createdContextIDs = Set<UInt32>()

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
        static let errorInvalidParameter: UInt32 = 0x1205
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
        var workerMapping: DoryRendererWorkerBlobMappingAuthority?
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
        scanoutSizes: [VirtioGPUScanoutSize]? = nil,
        renderer: VirtioGPURenderer? = nil,
        rendererWorkerCandidate: DoryRendererWorkerVirtioCommandLane? = nil,
        hostVisibleMemory: VirtioGPUHostVisibleMemory? = nil,
        traceResourceLifecycle: Bool = false,
        fenceTimeoutNanoseconds: UInt64 = 10_000_000_000,
        maximumTrackedResources: Int = 4_096,
        maximumControlRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumMemoryEntries: Int = DoryRendererWorkerLimits.production.maximumSharedRegions,
        maximumRendererReferencedBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
        maximumPendingFences: Int = 4_096,
        maximumPendingFenceResponseBytes: Int = 8 * 1_024 * 1_024,
        maximumCopiedScanoutSurfaceBytes: UInt64 = 128 * 1_024 * 1_024,
        quiescenceTimeout: TimeInterval = 5,
        onScanoutFrame: (@Sendable (VirtioGPUScanoutFrame) -> Void)? = nil,
        onScanoutTexture: (@Sendable (VirtioGPUScanoutTextureUpdate) -> Void)? = nil,
        onMetalScanout: (@Sendable (VirtioGPUMetalScanoutUpdate) -> Void)? = nil,
        onScanoutResourceReleased: (@Sendable (VirtioGPUScanoutResourceRelease) -> Void)? = nil,
        onScanoutDisabled: (@Sendable (UInt32) -> Void)? = nil,
        onCursorUpdate: (@Sendable (VirtioGPUCursorUpdate?) -> Void)? = nil,
        onRendererWorkerFailure: (@Sendable (String) -> Void)? = nil
    ) {
        let boundedScanoutSizes: [VirtioGPUScanoutSize]
        if let scanoutSizes {
            boundedScanoutSizes = Array(scanoutSizes.prefix(16))
        } else {
            boundedScanoutSizes = Array(
                repeating: VirtioGPUScanoutSize(
                    width: scanoutWidth,
                    height: scanoutHeight
                ),
                count: Int(min(scanoutCount, 16))
            )
        }
        let boundedScanoutCount = UInt32(boundedScanoutSizes.count)
        let boundedControlRequestBytes = min(
            64 * 1_024 * 1_024,
            max(96, maximumControlRequestBytes)
        )
        // A configuration carrying two independent renderer authorities is never partially
        // selected. It stays inert instead of guessing which process owns resource/fence state.
        let hasRendererAuthorityConflict = renderer != nil && rendererWorkerCandidate != nil
        let selectedWorkerCandidate = hasRendererAuthorityConflict
            ? nil
            : rendererWorkerCandidate
        let rendererRegionLimit = selectedWorkerCandidate?.maximumSharedRegions
            ?? DoryRendererWorkerLimits.production.maximumSharedRegions
        let boundedMemoryEntries = max(1, min(maximumMemoryEntries, rendererRegionLimit))
        let boundedRawMemoryEntries = max(
            1,
            min(
                DoryRendererWorkerLimits.absoluteMaximumSharedRegions,
                (boundedControlRequestBytes - 32) / 16
            )
        )
        let rendererReferencedByteLimit = selectedWorkerCandidate?.maximumReferencedBytes
            ?? DoryRendererWorkerLimits.absoluteMaximumReferencedBytes
        let boundedRendererReferencedBytes = max(
            1,
            min(maximumRendererReferencedBytes, rendererReferencedByteLimit)
        )
        let rendererExecutor = hasRendererAuthorityConflict ? nil : renderer.map {
            VirtioGPURendererCommandExecutor(
                renderer: $0,
                maximumCommandBytes: boundedControlRequestBytes,
                maximumMemoryEntries: boundedMemoryEntries,
                maximumReferencedBytes: boundedRendererReferencedBytes
            )
        }
        self.traceResourceLifecycle = traceResourceLifecycle
        self.fenceTimeoutNanoseconds = fenceTimeoutNanoseconds
        self.maximumTrackedResources = max(1, maximumTrackedResources)
        // The split-ring parser has a separate 64 MiB absolute chain ceiling. GPU commands are
        // intentionally tighter so one untrusted submit cannot force an allocation at that limit.
        // Ninety-six bytes keeps every fixed-size core command representable; variable command and
        // backing payloads remain available up to the explicit host policy bound.
        self.maximumControlRequestBytes = boundedControlRequestBytes
        self.maximumRawMemoryEntries = boundedRawMemoryEntries
        self.maximumMemoryEntries = boundedMemoryEntries
        self.maximumRendererReferencedBytes = boundedRendererReferencedBytes
        self.maximumPendingFences = max(1, maximumPendingFences)
        self.maximumPendingFenceResponseBytes = max(24, maximumPendingFenceResponseBytes)
        self.maximumCopiedScanoutSurfaceBytes = max(4, maximumCopiedScanoutSurfaceBytes)
        self.quiescenceTimeout = max(0.1, quiescenceTimeout)
        self.rendererExecutor = rendererExecutor
        self.rendererWorkerCandidate = selectedWorkerCandidate
        self.capsets = rendererExecutor?.capsets ?? selectedWorkerCandidate?.capsets ?? []
        let hasRendererAuthority = rendererExecutor != nil || selectedWorkerCandidate != nil
        self.rendererLifecycleHealthState = hasRendererAuthority
            ? .ready(epoch: 1)
            : .notConfigured
        self.configuredRendererDeviceFeatures = hasRendererAuthority
            ? Feature.virgl | Feature.resourceUUID | Feature.resourceBlob | Feature.contextInit
            : 0
        self.sharedMemoryRegions = [
            VirtioSharedMemoryRegion(id: 1, guestBase: hostMemoryBase, length: hostVisibleMemory?.length ?? hostMemorySize)
        ]
        self.scanoutCount = boundedScanoutCount
        self.scanoutSizes = boundedScanoutSizes
        self.hostVisibleMemory = hostVisibleMemory
        self.onScanoutFrame = onScanoutFrame
        self.onScanoutTexture = onScanoutTexture
        self.onMetalScanout = onMetalScanout
        self.onScanoutResourceReleased = onScanoutResourceReleased
        self.onScanoutDisabled = onScanoutDisabled
        self.onCursorUpdate = onCursorUpdate
        self.onRendererWorkerFailure = onRendererWorkerFailure
        rendererExecutor?.installCallbacks(
            fence: { [weak self] generation, contextID, ringIndex, fenceID in
                self?.fenceSignaled(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { [weak self] generation, failure in
                self?.recordRendererFailure(failure, generation: generation)
            }
        )
        selectedWorkerCandidate?.installCallbacks(
            fence: { [weak self] generation, contextID, ringIndex, fenceID in
                self?.fenceSignaled(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { [weak self] generation, error in
                self?.rendererWorkerCandidateFailed(
                    generation: generation,
                    error: error
                )
            }
        )
        if hasRendererAuthorityConflict {
            if let state = rendererWorkerCandidate?.snapshot().state {
                let generation: UInt64 = switch state {
                case .active(let value), .revoked(let value), .failed(let value): value
                }
                rendererWorkerCandidate?.revoke(deviceGeneration: generation)
            }
            FileHandle.standardError.write(Data(
                "dory-gpu: renderer authority conflict; acceleration remains disabled\n".utf8
            ))
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
        config.appendLE(rendererCapabilitiesAreAdvertised ? UInt32(capsets.count) : 0) // num_capsets
        return config
    }

    /// Publishes a new preferred scanout size and raises VIRTIO_GPU_EVENT_DISPLAY. The Linux DRM
    /// driver responds by re-reading GET_DISPLAY_INFO and issuing a real modeset, so the guest
    /// compositor renders at the Retina window's pixel dimensions instead of scaling one fixed
    /// framebuffer on the host.
    public func updateScanoutSize(
        scanoutID: UInt32,
        width: UInt32,
        height: UInt32,
        transport: VirtioMMIOTransport
    ) {
        let updated = VirtioGPUScanoutSize(width: width, height: height)
        displayLock.lock()
        let index = Int(scanoutID)
        let changed = scanoutSizes.indices.contains(index) && scanoutSizes[index] != updated
        if changed {
            scanoutSizes[index] = updated
            pendingDisplayEvents |= 1  // VIRTIO_GPU_EVENT_DISPLAY
        }
        displayLock.unlock()
        if changed { transport.notifyConfigChange() }
    }

    /// Source-compatible primary-scanout resize bridge.
    public func updateScanoutSize(
        width: UInt32,
        height: UInt32,
        transport: VirtioMMIOTransport
    ) {
        updateScanoutSize(
            scanoutID: 0,
            width: width,
            height: height,
            transport: transport
        )
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

    /// Clears one complete guest GPU epoch. Display disable is published before generation
    /// releases; renderer teardown begins only after every release acknowledgement. Callers that
    /// own process shutdown should retain and wait on the returned receipt before destroying the
    /// renderer or guest memory.
    @discardableResult
    public func quiesce(reason: VirtioGPUQuiescenceReason) -> VirtioGPUQuiescence {
        commandLock.lock()
        defer { commandLock.unlock() }

        if let existing = lifecycleLock.withLock({ activeQuiescence?.receipt }) {
            return existing
        }

        let localWorkerStateIsPristine = reason == .deviceReset
            && resources2D.isEmpty
            && resources3D.isEmpty
            && blobResources.isEmpty
            && resourceEntries.isEmpty
            && resourceUUIDs.isEmpty
            && resourceGenerations.isEmpty
            && rendererWorkerResourceGenerations.isEmpty
            && rendererWorkerResourceContextIDs.isEmpty
            && rendererWorkerPendingResourceIDs.isEmpty
            && rendererWorkerPendingBackingResourceIDs.isEmpty
            && rendererWorkerPendingMappingResourceIDs.isEmpty
            && rendererWorkerControlCommandClaim == nil
            && scanouts.isEmpty
            && cursorResourceID == nil
            && createdContextIDs.isEmpty
            && rendererWorkerPresentationLock.withLock {
                rendererWorkerPendingScanouts.isEmpty && rendererWorkerLiveScanouts.isEmpty
            }
        let (epoch, revokedWorkerGeneration, fenceStateIsPristine) = fenceLock.withLock {
            () -> (UInt64, UInt64, Bool) in
            let revokedWorkerGeneration = lifecycleEpoch
            let fenceStateIsPristine = pendingFenceCount == 0
                && uncertainFences.isEmpty
                && uncertainRendererCommandChains.isEmpty
                && lastTransport == nil
                && !fenceAdmissionBlockedUntilDeviceReset
            lifecycleEpoch &+= 1
            if lifecycleEpoch == 0 { lifecycleEpoch = 1 }
            recordTelemetryWhileLocked(
                .resetRevokedFence,
                count: UInt64(pendingFenceCount)
            )
            recordTelemetryWhileLocked(
                .revokedUncertainRendererCommand,
                count: UInt64(uncertainRendererCommandChains.count)
            )
            pendingFences.removeAll()
            uncertainFences.removeAll()
            uncertainRendererCommandChains.removeAll()
            pendingFenceCount = 0
            pendingFenceResponseBytes = 0
            lastTransport = nil
            fenceAdmissionBlockedUntilDeviceReset =
                rendererExecutor != nil || rendererWorkerCandidate != nil
            return (lifecycleEpoch, revokedWorkerGeneration, fenceStateIsPristine)
        }
        let workerReboundForPristineDeviceReset = localWorkerStateIsPristine
            && fenceStateIsPristine
            && rendererWorkerCandidate?.rebindPristineDeviceGeneration(
                from: revokedWorkerGeneration,
                to: epoch
            ) == true
        if !workerReboundForPristineDeviceReset {
            rendererWorkerCandidate?.revoke(deviceGeneration: revokedWorkerGeneration)
            revokeRendererWorkerScanouts()
        }
        rendererWorkerControlCommandClaim = nil

        let rendererGeneration: UInt64
        let executorAdmissionFault: VirtioGPURendererHealthFault?
        if let rendererExecutor {
            switch rendererExecutor.beginQuiescence(successorGeneration: epoch) {
            case .admitted(let sourceGeneration):
                rendererGeneration = sourceGeneration
                executorAdmissionFault = nil
            case .rejected(let rejection):
                rendererGeneration = epoch
                executorAdmissionFault = .resetFailed(
                    "renderer executor rejected quiescence: \(rejection)"
                )
            }
        } else {
            rendererGeneration = epoch
            executorAdmissionFault = nil
        }

        let resources = (resources2D.keys.map { resourceID in
            QuiescingResource(
                key: ResourceRetirementKey(
                    resourceID: resourceID,
                    generation: resourceGenerations[resourceID] ?? 0
                ),
                requiresBlobUnmap: false
            )
        } + resources3D.keys.map { resourceID in
            QuiescingResource(
                key: ResourceRetirementKey(
                    resourceID: resourceID,
                    generation: resourceGenerations[resourceID] ?? 0
                ),
                requiresBlobUnmap: false
            )
        } + blobResources.map { resourceID, blob in
            QuiescingResource(
                key: ResourceRetirementKey(
                    resourceID: resourceID,
                    generation: resourceGenerations[resourceID] ?? 0
                ),
                requiresBlobUnmap: blob.mapping?.requiresRendererUnmap == true
                    || blob.workerMapping != nil
            )
        }).sorted {
            if $0.key.resourceID != $1.key.resourceID {
                return $0.key.resourceID < $1.key.resourceID
            }
            return $0.key.generation < $1.key.generation
        }
        let receipt = VirtioGPUQuiescence(epoch: epoch, reason: reason)

        let existingFault: VirtioGPURendererHealthFault? = lifecycleLock.withLock {
            acceptingGuestCommands = false
            if let executorAdmissionFault {
                rendererLifecycleHealthState = .failed(
                    epoch: epoch,
                    fault: executorAdmissionFault
                )
                return executorAdmissionFault
            }
            if case .failed(_, let fault) = rendererLifecycleHealthState {
                for resource in resources {
                    retiringResources[resource.key.resourceID] = resource.key.generation
                }
                return fault
            }
            let prior = Set(retiringResources.map {
                ResourceRetirementKey(resourceID: $0.key, generation: $0.value)
            })
            for resource in resources {
                retiringResources[resource.key.resourceID] = resource.key.generation
            }
            activeQuiescence = ActiveQuiescence(
                receipt: receipt,
                rendererGeneration: rendererGeneration,
                workerReboundForPristineDeviceReset: workerReboundForPristineDeviceReset,
                rendererResources: resources,
                awaitingReleaseAcknowledgements: Set(resources.map(\.key)),
                priorRetirements: prior,
                cleanupScheduled: false
            )
            rendererLifecycleHealthState = rendererAuthorityIsConfigured
                ? .quiescing(epoch: epoch)
                : .notConfigured
            return nil
        }

        let blobResourceIDs = blobResources.keys.sorted()
        for resourceID in blobResourceIDs { hostVisibleMemory?.unmap(resourceID: resourceID) }
        resources2D.removeAll()
        resources3D.removeAll()
        blobResources.removeAll()
        resourceEntries.removeAll()
        resourceUUIDs.removeAll()
        resourceGenerations.removeAll()
        rendererWorkerResourceGenerations.removeAll()
        rendererWorkerResourceContextIDs.removeAll()
        rendererWorkerPendingResourceIDs.removeAll()
        rendererWorkerPendingBackingResourceIDs.removeAll()
        rendererWorkerPendingMappingResourceIDs.removeAll()
        rendererWorkerScanoutDiagnosticLock.withLock {
            rendererWorkerScanoutDiagnosticStages.removeAll()
        }
        scanouts.removeAll()
        cursorResourceID = nil
        createdContextIDs.removeAll()
        commandFailureCounts.removeAll()
        displayLock.withLock { pendingDisplayEvents = 0 }

        // A disable causes each mailbox to retire a queued direct presentation before the release
        // objects below can acknowledge renderer destruction.
        for scanoutID in 0..<scanoutCount { onScanoutDisabled?(scanoutID) }
        onCursorUpdate?(nil)

        if let existingFault {
            // The renderer is already quarantined, but displays still must detach every newly
            // discovered generation. Keep all IDs reserved permanently because no safe renderer
            // teardown/recreation boundary exists.
            for resource in resources {
                publishResourceRelease(
                    resourceID: resource.key.resourceID,
                    generation: resource.key.generation,
                    completion: {}
                )
            }
            receipt.complete(.failed(existingFault))
            return receipt
        }

        for resource in resources {
            publishResourceRelease(
                resourceID: resource.key.resourceID,
                generation: resource.key.generation
            ) { [self] in
                acknowledgeQuiescenceRelease(resource.key, epoch: epoch)
            }
        }
        scheduleQuiescenceCleanupIfReady()
        return receipt
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        let receipt = quiesce(reason: .deviceReset)
        guard receipt.wait(timeout: quiescenceTimeout) != nil else {
            let fault = VirtioGPURendererHealthFault.quiescenceTimedOut(epoch: receipt.epoch)
            failRendererLifecycle(fault, epoch: receipt.epoch)
            FileHandle.standardError.write(Data(
                "dory-gpu: MMIO reset quiescence timed out at epoch \(receipt.epoch)\n".utf8
            ))
            return
        }
    }

    public func queueStateChanged(
        queue: Int,
        ready: Bool,
        transport: VirtioMMIOTransport
    ) {
        guard queue == 0 else { return }
        commandLock.lock()
        defer { commandLock.unlock() }
        let workerSnapshot = rendererWorkerCandidate?.snapshot()
        let workerRequiresRevocation = rendererWorkerCandidate != nil && (
            !ready
                || rendererWorkerControlCommandClaim != nil
                || (workerSnapshot?.queuedCommands ?? 0) > 0
                || (workerSnapshot?.armedFences ?? 0) > 0
        )
        let revokedFenceGeneration = fenceLock.withLock { () -> UInt64? in
            guard workerRequiresRevocation
                    || pendingFenceCount > 0
                    || !uncertainRendererCommandChains.isEmpty else {
                return nil
            }
            let revokedGeneration = lifecycleEpoch
            recordTelemetryWhileLocked(
                .queueRevokedFence,
                count: UInt64(pendingFenceCount)
            )
            pendingFences.removeAll()
            uncertainFences.removeAll()
            recordTelemetryWhileLocked(
                .revokedUncertainRendererCommand,
                count: UInt64(uncertainRendererCommandChains.count)
            )
            uncertainRendererCommandChains.removeAll()
            pendingFenceCount = 0
            pendingFenceResponseBytes = 0
            lastTransport = nil
            lifecycleEpoch &+= 1
            if lifecycleEpoch == 0 { lifecycleEpoch = 1 }
            fenceAdmissionBlockedUntilDeviceReset = true
            return revokedGeneration
        }
        if let revokedFenceGeneration {
            if rendererWorkerControlCommandClaim?.generation == revokedFenceGeneration {
                rendererWorkerControlCommandClaim = nil
            }
            rendererExecutor?.revokeActiveGeneration()
            rendererWorkerCandidate?.revoke(deviceGeneration: revokedFenceGeneration)
            revokeRendererWorkerScanouts()
        }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 0 || queue == 1 else { return }
        let outcome = drainQueue(queue: queue, transport: transport)
        switch outcome {
        case .drained(let wantsInterrupt),
             .popFailed(let wantsInterrupt),
             .completionFailed(let wantsInterrupt):
            if wantsInterrupt { transport.notifyUsed() }
        case .pendingReadFailed:
            break
        }
    }

    private func drainQueue(
        queue: Int,
        transport: VirtioMMIOTransport
    ) -> QueueDrainOutcome {
        if queue == 0,
           rendererWorkerCandidate != nil,
           commandLock.withLock({
               rendererWorkerControlCommandClaim != nil
           }) {
            // The command at the head of the accepted worker stream still owns controlq ordering.
            // Unknown outcomes intentionally keep this barrier until the whole device is reset.
            return .drained(wantsInterrupt: false)
        }
        let virtqueue = transport.queues[queue]
        let pending: UInt16
        do {
            pending = try virtqueue.pendingCount()
        } catch {
            recordTelemetry(.queuePendingReadFailure)
            return .pendingReadFailed
        }

        // Process only the validated snapshot. Even if a future SMP guest publishes more work
        // while this kick is running, one notification can never monopolize the VCPU indefinitely.
        var wantsInterrupt = false
        for _ in 0..<Int(pending) {
            let chain: VirtqueueChain
            do {
                guard let next = try virtqueue.pop() else { break }
                chain = next
            } catch {
                // pop() consumes a malformed available head before descriptor resolution fails.
                // Stop this turn so a following kick can make bounded forward progress without
                // pretending the malformed head had a publishable completion.
                recordTelemetry(.queuePopFailure)
                return .popFailed(wantsInterrupt: wantsInterrupt)
            }

            let admission = admit(
                chain: chain,
                cursorQueue: queue == 1,
                transport: transport
            )
            switch admission {
            case .revoked:
                recordTelemetry(.revokedCompletion)
                return .completionFailed(wantsInterrupt: wantsInterrupt)
            case .rejected(let rejection):
                recordAdmissionRejection(rejection)
                switch publishCompletion(
                    chain: chain,
                    response: nil,
                    queue: virtqueue
                ) {
                case .published(let wants):
                    wantsInterrupt = wantsInterrupt || wants
                case .revoked, .failed:
                    return .completionFailed(wantsInterrupt: wantsInterrupt)
                }
            case .workerControl(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerControl(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    // Preserve guest control-queue order across the asynchronous process boundary.
                    // Completion schedules another bounded drain for descriptors already published
                    // in this kick; the vCPU itself never waits for XPC or GPU progress.
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerCreateResource3D(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerCreateResource3D(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerCreateBlob(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerCreateBlob(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerAttachBacking(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerAttachBacking(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerDetachBacking(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerDetachBacking(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerTransfer(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerTransfer(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerUnref(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerUnref(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerMapBlob(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerMapBlob(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerUnmapBlob(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerUnmapBlob(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerFlushScanout(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerFlushScanout(
                    admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    // A scanout flush is also a display ownership transition. Preserve exact
                    // control-queue order until the worker lease reaches a committed host Metal
                    // command buffer; otherwise a following modeset can retire it in the same
                    // kick before AppKit imports the frame.
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerSubmit(let admission):
                guard let claim = beginRendererWorkerControlCommand() else {
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
                if let immediate = startRendererWorkerSubmit(
                    admission,
                    chain: chain,
                    generation: claim.generation,
                    transport: transport
                ) {
                    switch immediate {
                    case .published(let wants):
                        completeRendererWorkerControlCommand(claim: claim)
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                } else {
                    // The lane preserves worker execution order and owns this descriptor until its
                    // reply/fence edge. Release only the cross-kick admission claim so Linux can
                    // keep the GPU fed with later immutable submissions.
                    completeRendererWorkerControlCommand(claim: claim)
                    return .drained(wantsInterrupt: wantsInterrupt)
                }
            case .workerRejected(let requestHeader):
                switch publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: requestHeader
                    ),
                    queue: virtqueue
                ) {
                case .published(let wants):
                    wantsInterrupt = wantsInterrupt || wants
                case .revoked, .failed:
                    return .completionFailed(wantsInterrupt: wantsInterrupt)
                }
            case .admitted(let request, let writesResponse):
                commandLock.lock()
                let fenceAdmission = queue == 0
                    ? prepareFenceAdmission(
                        request: request,
                        responseByteCount: maximumResponseByteCount(for: request),
                        transport: transport
                    )
                    : .notRequested
                let response: [UInt8]?
                let fenceOutcome: FenceDeferralOutcome
                if case .rejected = fenceAdmission {
                    recordTelemetry(.fenceAdmissionRejection)
                    response = responseHeader(
                        type: Response.errorInvalidParameter,
                        request: request
                    )
                    fenceOutcome = .immediate
                } else {
                    let processing = process(
                        request: request,
                        cursorQueue: queue == 1,
                        transport: transport
                    )
                    switch processing {
                    case .response(let completedResponse):
                        response = completedResponse
                        fenceOutcome = queue == 0
                            ? deferForFence(
                                admission: fenceAdmission,
                                response: completedResponse,
                                chain: chain,
                                transport: transport
                            )
                            : .immediate
                    case .outcomeUnknown:
                        fenceLock.withLock {
                            uncertainRendererCommandChains.append(chain)
                        }
                        response = nil
                        fenceOutcome = .outcomeUnknown
                    }
                }
                commandLock.unlock()

                switch fenceOutcome {
                case .deferred, .outcomeUnknown:
                    continue
                case .immediate:
                    switch publishCompletion(
                        chain: chain,
                        response: writesResponse ? response : nil,
                        queue: virtqueue
                    ) {
                    case .published(let wants):
                        wantsInterrupt = wantsInterrupt || wants
                    case .revoked, .failed:
                        return .completionFailed(wantsInterrupt: wantsInterrupt)
                    }
                }
            }
        }
        return .drained(wantsInterrupt: wantsInterrupt)
    }

    /// Claims the single worker-backed controlq stream at the current device generation. Kicks
    /// are serialized by VirtioMMIOTransport, while this authority remains held across the
    /// asynchronous worker exchange after the transport lock has been released.
    private func beginRendererWorkerControlCommand() -> RendererWorkerControlCommandClaim? {
        commandLock.withLock {
            guard rendererWorkerControlCommandClaim == nil else { return nil }
            let generation = fenceLock.withLock { lifecycleEpoch }
            let claim = RendererWorkerControlCommandClaim(
                generation: generation,
                token: nextRendererWorkerControlCommandToken
            )
            nextRendererWorkerControlCommandToken &+= 1
            if nextRendererWorkerControlCommandToken == 0 {
                nextRendererWorkerControlCommandToken = 1
            }
            rendererWorkerControlCommandClaim = claim
            return claim
        }
    }

    /// Releases only the exact command claim. A late completion from either a revoked generation
    /// or an older pipelined command in the active generation cannot open the queue.
    @discardableResult
    private func completeRendererWorkerControlCommand(
        claim: RendererWorkerControlCommandClaim
    ) -> Bool {
        commandLock.withLock {
            guard rendererWorkerControlCommandClaim == claim else { return false }
            rendererWorkerControlCommandClaim = nil
            return true
        }
    }

    private func admit(
        chain: VirtqueueChain,
        cursorQueue: Bool,
        transport: VirtioMMIOTransport
    ) -> QueueAdmissionOutcome {
        guard !chain.containsZeroLengthDescriptor else {
            return .rejected(.invalidDescriptorLayout)
        }
        return chain.withLeaseHeld { access in
            let segments = access.segments
            guard !segments.isEmpty else {
                return .rejected(.invalidDescriptorLayout)
            }
            var encounteredWritable = false
            for segment in segments {
                if segment.isDeviceWritable {
                    encounteredWritable = true
                } else if encounteredWritable {
                    // Virtio requests are a readable prefix followed by a writable suffix. Never
                    // normalize writable/readable/writable guest chains into a valid-looking pair.
                    return .rejected(.invalidDescriptorLayout)
                }
            }

            let readable = access.readableByteCount
            let maximum = cursorQueue ? 56 : maximumControlRequestBytes
            guard readable <= maximum else { return .rejected(.oversizedRequest) }
            guard cursorQueue ? readable == 56 : readable >= 24 else {
                return .rejected(.invalidDescriptorLayout)
            }

            if !cursorQueue, rendererWorkerCandidate != nil {
                let header = access.readBytes(maximum: 24)
                if header.count == 24 {
                    let command = header.leUInt32(at: 0)
                    let exactWorkerRequestBytes: Int? = switch command {
                    case Command.resourceCreate2D: 40
                    case Command.resourceUnref,
                         Command.resourceAssignUUID,
                         Command.resourceDetachBacking,
                         Command.ctxAttachResource,
                         Command.ctxDetachResource,
                         Command.resourceUnmapBlob: 32
                    case Command.ctxDestroy: 24
                    case Command.setScanout, Command.resourceFlush: 48
                    case Command.transferToHost2D: 56
                    case Command.ctxCreate, Command.setScanoutBlob: 96
                    case Command.resourceCreate3D,
                         Command.transferToHost3D,
                         Command.transferFromHost3D: 72
                    case Command.resourceMapBlob: 40
                    default: nil
                    }
                    if let exactWorkerRequestBytes, readable != exactWorkerRequestBytes {
                        return .workerRejected(requestHeader: header)
                    }
                    if (command == Command.resourceAttachBacking && readable < 32)
                        || (command == Command.resourceCreateBlob && readable < 56)
                        || (command == Command.submit3D && readable < 32) {
                        return .workerRejected(requestHeader: header)
                    }
                    if command == Command.resourceCreate2D {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        guard readable == 40 else {
                            return .workerRejected(requestHeader: header)
                        }
                        let request = access.readBytes(maximum: 40)
                        let resourceID = request.leUInt32(at: 24)
                        let format = request.leUInt32(at: 28)
                        let width = request.leUInt32(at: 32)
                        let height = request.leUInt32(at: 36)
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        guard request.count == 40,
                              hasValidFenceHeader,
                              request.leUInt32(at: 16) == 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              width > 0,
                              height > 0,
                              width <= 16_384,
                              height <= 16_384,
                              Self.isSupportedScanoutFormat(format),
                              let copiedByteCount = Self.rgbaByteCount(
                                width: width,
                                height: height
                              ),
                              copiedByteCount <= maximumCopiedScanoutSurfaceBytes,
                              let payload = try? DoryRendererResource3DCreatePayload(
                                target: 2,
                                format: format,
                                bind: (1 << 1) | (1 << 18),
                                width: width,
                                height: height,
                                depth: 1,
                                arraySize: 1,
                                lastLevel: 0,
                                samples: 0,
                                flags: 1,
                                maximumReferencedBytes: maximumRendererReferencedBytes
                              ) else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerCreateResource3D(WorkerCreateResource3DAdmission(
                            request: request,
                            resourceID: resourceID,
                            payload: payload,
                            kind: .resource2D,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    if command == Command.resourceCreate3D {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        guard readable == 72 else {
                            return .workerRejected(requestHeader: header)
                        }
                        let request = access.readBytes(maximum: 72)
                        let resourceID = request.leUInt32(at: 24)
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        guard request.count == 72,
                              hasValidFenceHeader,
                              request.leUInt32(at: 16) == 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              let payload = try? DoryRendererResource3DCreatePayload(
                                target: request.leUInt32(at: 28),
                                format: request.leUInt32(at: 32),
                                bind: request.leUInt32(at: 36),
                                width: request.leUInt32(at: 40),
                                height: request.leUInt32(at: 44),
                                depth: request.leUInt32(at: 48),
                                arraySize: request.leUInt32(at: 52),
                                lastLevel: request.leUInt32(at: 56),
                                samples: request.leUInt32(at: 60),
                                flags: request.leUInt32(at: 64),
                                maximumReferencedBytes: maximumRendererReferencedBytes
                              ) else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerCreateResource3D(WorkerCreateResource3DAdmission(
                            request: request,
                            resourceID: resourceID,
                            payload: payload,
                            kind: .resource3D,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    if command == Command.transferToHost3D
                        || command == Command.transferFromHost3D {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let request = access.readBytes(maximum: 72)
                        let resourceID = request.leUInt32(at: 56)
                        let contextID = request.leUInt32(at: 16)
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        let resourceGeneration = commandLock.withLock { () -> UInt64? in
                            guard resourceEntries[resourceID] != nil,
                                  contextID == 0 || createdContextIDs.contains(contextID) else {
                                return nil
                            }
                            return rendererWorkerResourceGenerations[resourceID]
                        }
                        guard request.count == 72,
                              hasValidFenceHeader,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              let resourceGeneration,
                              let payload = try? DoryRendererTransfer3DPayload(
                                level: request.leUInt32(at: 60),
                                stride: request.leUInt32(at: 64),
                                layerStride: request.leUInt32(at: 68),
                                offset: request.leUInt64(at: 48),
                                x: request.leUInt32(at: 24),
                                y: request.leUInt32(at: 28),
                                z: request.leUInt32(at: 32),
                                width: request.leUInt32(at: 36),
                                height: request.leUInt32(at: 40),
                                depth: request.leUInt32(at: 44)
                              ) else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerTransfer(WorkerTransferAdmission(
                            request: request,
                            resourceID: resourceID,
                            resourceGeneration: resourceGeneration,
                            contextID: contextID,
                            payload: payload,
                            direction: command == Command.transferToHost3D
                                ? .toHost
                                : .fromHost,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    if command == Command.ctxCreate || command == Command.ctxDestroy {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        guard header.leUInt32(at: 4) == 0,
                              header.leUInt32(at: 16) != 0 else {
                            return .workerRejected(requestHeader: header)
                        }
                        if command == Command.ctxDestroy {
                            guard readable == 24 else {
                                return .workerRejected(requestHeader: header)
                            }
                            return .workerControl(WorkerControlAdmission(
                                request: header,
                                contextID: header.leUInt32(at: 16),
                                operation: .destroyContext
                            ))
                        }

                        guard readable == 96 else {
                            return .workerRejected(requestHeader: header)
                        }
                        let request = access.readBytes(maximum: 96)
                        guard request.count == 96 else {
                            return .rejected(.invalidDescriptorLayout)
                        }
                        let nameLength = Int(request.leUInt32(at: 24))
                        let contextInit = request.leUInt32(at: 28)
                        let resolvedCapset = Self.rendererContextFlags(
                            requested: contextInit,
                            capsets: capsets
                        )
                        guard nameLength <= DoryRendererContextCreatePayload.maximumNameBytes,
                              contextInit & ~UInt32(0xff) == 0,
                              resolvedCapset == 2 || resolvedCapset == Capset.venus else {
                            return .workerRejected(requestHeader: request)
                        }
                        let rawName = request[32..<(32 + nameLength)].prefix { $0 != 0 }
                        let name = rawName.isEmpty
                            ? "virtio-gpu"
                            : String(decoding: rawName, as: UTF8.self)
                        guard !name.utf8.contains(0),
                              name.utf8.count
                                <= DoryRendererContextCreatePayload.maximumNameBytes else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerControl(WorkerControlAdmission(
                            request: request,
                            contextID: header.leUInt32(at: 16),
                            operation: .createContext(name: name, capsetID: resolvedCapset)
                        ))
                    }
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable == 48 {
                let request = access.readBytes(maximum: 48)
                if request.count == 48,
                   request.leUInt32(at: 0) == Command.resourceFlush {
                    guard access.hasWritableSegments,
                          access.writableByteCount >= 24 else {
                        return .rejected(.insufficientResponseCapacity)
                    }
                    let resourceID = request.leUInt32(at: 40)
                    let workerState = commandLock.withLock { () -> (
                        WorkerScanoutSurface?,
                        UInt64,
                        UInt64,
                        [WorkerFlushTarget]
                    )? in
                        guard let workerGeneration =
                                rendererWorkerResourceGenerations[resourceID],
                              let displayGeneration = resourceGenerations[resourceID],
                              let requestedRect = try? scanoutRect(from: request, at: 24) else {
                            return nil
                        }
                        var surface: WorkerScanoutSurface?
                        var targets = [WorkerFlushTarget]()
                        for (scanoutID, binding) in scanouts.sorted(by: { $0.key < $1.key }) {
                            guard binding.resourceID == resourceID else { continue }
                            guard let candidate = rendererWorkerScanoutSurface(
                                for: binding
                            ) else { return nil }
                            guard Self.contains(
                                rect: requestedRect,
                                width: candidate.width,
                                height: candidate.height
                            ), surface == nil || surface == candidate else {
                                return nil
                            }
                            surface = candidate
                            guard let dirty = Self.intersection(
                                requestedRect,
                                binding.rect
                            ) else { continue }
                            targets.append(WorkerFlushTarget(
                                scanoutID: scanoutID,
                                sourceRect: binding.rect,
                                dirtyRect: VirtioGPURect(
                                    x: dirty.x - binding.rect.x,
                                    y: dirty.y - binding.rect.y,
                                    width: dirty.width,
                                    height: dirty.height
                                )
                            ))
                        }
                        return (
                            surface,
                            workerGeneration,
                            displayGeneration,
                            targets
                        )
                    }
                    if let workerState {
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        let canonicalHeader = hasValidFenceHeader
                            && request.leUInt32(at: 16) == 0
                            && request[20..<24].allSatisfy({ $0 == 0 })
                            && resourceID != 0
                            && request.leUInt32(at: 44) == 0
                        guard canonicalHeader else {
                            logRendererWorkerScanoutFailure(
                                resourceID: resourceID,
                                stage: "flush-header",
                                detail: "targets=\(workerState.3.count)"
                            )
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerFlushScanout(WorkerFlushScanoutAdmission(
                            request: request,
                            resourceID: resourceID,
                            workerResourceGeneration: workerState.1,
                            displayResourceGeneration: workerState.2,
                            surface: workerState.0,
                            targets: workerState.3,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    // A non-worker 2D/blob flush continues through the established software path;
                    // malformed or stale worker resource identity fails closed here.
                    let rejectedWorkerRoute = commandLock.withLock { () -> (
                        rendererOwned: Bool,
                        detail: String
                    ) in
                        let rendererOwned = resources2D[resourceID] != nil
                            || resources3D[resourceID] != nil
                            || rendererWorkerResourceGenerations[resourceID] != nil
                        guard rendererOwned else { return (false, "") }
                        let requestedRect = try? scanoutRect(from: request, at: 24)
                        let rectDescription = requestedRect.map {
                            "\($0.x),\($0.y)/\($0.width)x\($0.height)"
                        } ?? "invalid"
                        let bindings = scanouts
                            .filter { $0.value.resourceID == resourceID }
                            .sorted { $0.key < $1.key }
                            .map { scanoutID, binding -> String in
                                switch binding.source {
                                case .resource2D:
                                    return "\(scanoutID):2d"
                                case .resource3D:
                                    return "\(scanoutID):3d"
                                case .blob(let format, let width, let height, let stride, let offset):
                                    return "\(scanoutID):blob/\(format)/\(width)x\(height)/"
                                        + "\(stride)/\(offset)"
                                }
                            }
                            .joined(separator: ",")
                        let detail = "blob=\(blobResources[resourceID] != nil) worker-generation="
                            + "\(rendererWorkerResourceGenerations[resourceID].map(String.init) ?? "missing")"
                            + " display-generation="
                            + "\(resourceGenerations[resourceID].map(String.init) ?? "missing")"
                            + " contexts=\((rendererWorkerResourceContextIDs[resourceID] ?? []).sorted())"
                            + " rect=\(rectDescription) bindings=[\(bindings)]"
                        return (true, detail)
                    }
                    if rejectedWorkerRoute.rendererOwned {
                        logRendererWorkerScanoutFailure(
                            resourceID: resourceID,
                            stage: "flush-state-missing",
                            detail: rejectedWorkerRoute.detail
                        )
                        return .workerRejected(requestHeader: request)
                    }
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable == 32 {
                let request = access.readBytes(maximum: 32)
                if request.count == 32 {
                    let command = request.leUInt32(at: 0)
                    if command == Command.resourceUnref {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let resourceID = request.leUInt32(at: 24)
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        let resourceState = commandLock.withLock { () -> (
                            workerGeneration: UInt64,
                            displayGeneration: UInt64
                        )? in
                            guard resources2D[resourceID] != nil
                                    || resources3D[resourceID] != nil
                                    || blobResources[resourceID] != nil,
                                  let workerGeneration =
                                    rendererWorkerResourceGenerations[resourceID],
                                  let displayGeneration = resourceGenerations[resourceID],
                                  rendererWorkerResourceContextIDs[resourceID]?.isEmpty
                                    != false,
                                  !rendererWorkerPendingResourceIDs.contains(resourceID),
                                  !rendererWorkerPendingBackingResourceIDs.contains(resourceID),
                                  !rendererWorkerPendingMappingResourceIDs.contains(resourceID),
                                  !isResourceRetiring(resourceID),
                                  blobResources[resourceID]?.guestMapped != true,
                                  blobResources[resourceID]?.workerMapping == nil else {
                                return nil
                            }
                            return (workerGeneration, displayGeneration)
                        }
                        guard hasValidFenceHeader,
                              request.leUInt32(at: 16) == 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              request.leUInt32(at: 28) == 0,
                              let resourceState else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerUnref(WorkerUnrefAdmission(
                            request: request,
                            resourceID: resourceID,
                            workerResourceGeneration: resourceState.workerGeneration,
                            displayResourceGeneration: resourceState.displayGeneration,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    if command == Command.resourceDetachBacking {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let resourceID = request.leUInt32(at: 24)
                        let flags = request.leUInt32(at: 4)
                        let fenceID = request.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        let resourceState = commandLock.withLock { () -> UInt64? in
                            guard resourceEntries[resourceID] != nil,
                                  rendererWorkerPendingBackingResourceIDs
                                    .contains(resourceID) == false else { return nil }
                            return rendererWorkerResourceGenerations[resourceID]
                        }
                        guard hasValidFenceHeader,
                              request.leUInt32(at: 16) == 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              request.leUInt32(at: 28) == 0,
                              let resourceState else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerDetachBacking(WorkerDetachBackingAdmission(
                            request: request,
                            resourceID: resourceID,
                            resourceGeneration: resourceState,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    if command == Command.ctxAttachResource
                        || command == Command.ctxDetachResource {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let contextID = request.leUInt32(at: 16)
                        let resourceID = request.leUInt32(at: 24)
                        guard request.leUInt32(at: 4) == 0,
                              request.leUInt64(at: 8) == 0,
                              contextID != 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              request.leUInt32(at: 28) == 0 else {
                            return .workerRejected(requestHeader: request)
                        }
                        let workerRouted = commandLock.withLock {
                            rendererWorkerResourceGenerations[resourceID] != nil
                        }
                        guard workerRouted else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerControl(WorkerControlAdmission(
                            request: request,
                            contextID: contextID,
                            operation: command == Command.ctxAttachResource
                                ? .attachResource(resourceID: resourceID)
                                : .detachResource(resourceID: resourceID)
                        ))
                    }
                    if command == Command.resourceUnmapBlob {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let resourceID = request.leUInt32(at: 24)
                        let resourceGeneration = commandLock.withLock {
                            rendererWorkerResourceGenerations[resourceID]
                        }
                        guard request.leUInt32(at: 4) == 0,
                              request.leUInt64(at: 8) == 0,
                              request.leUInt32(at: 16) == 0,
                              request[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              request.leUInt32(at: 28) == 0,
                              let resourceGeneration else {
                            return .workerRejected(requestHeader: request)
                        }
                        return .workerUnmapBlob(WorkerUnmapBlobAdmission(
                            request: request,
                            resourceID: resourceID,
                            resourceGeneration: resourceGeneration
                        ))
                    }
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable == 40 {
                let request = access.readBytes(maximum: 40)
                if request.count == 40,
                   request.leUInt32(at: 0) == Command.resourceMapBlob {
                    guard access.hasWritableSegments,
                          access.writableByteCount >= 32 else {
                        return .rejected(.insufficientResponseCapacity)
                    }
                    let resourceID = request.leUInt32(at: 24)
                    let resourceGeneration = commandLock.withLock {
                        rendererWorkerResourceGenerations[resourceID]
                    }
                    guard request.leUInt32(at: 4) == 0,
                          request.leUInt64(at: 8) == 0,
                          request.leUInt32(at: 16) == 0,
                          request[20..<24].allSatisfy({ $0 == 0 }),
                          resourceID != 0,
                          request.leUInt32(at: 28) == 0,
                          let resourceGeneration else {
                        return .workerRejected(requestHeader: request)
                    }
                    return .workerMapBlob(WorkerMapBlobAdmission(
                        request: request,
                        resourceID: resourceID,
                        resourceGeneration: resourceGeneration,
                        hostVisibleOffset: request.leUInt64(at: 32)
                    ))
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable == 56 {
                let request = access.readBytes(maximum: 56)
                if request.count == 56,
                   request.leUInt32(at: 0) == Command.transferToHost2D {
                    guard access.hasWritableSegments,
                          access.writableByteCount >= 24 else {
                        return .rejected(.insufficientResponseCapacity)
                    }
                    let resourceID = request.leUInt32(at: 48)
                    let workerState = commandLock.withLock { () -> (
                        resource: Resource2D,
                        generation: UInt64
                    )? in
                        guard let resource = resources2D[resourceID],
                              !resource.backing.isEmpty,
                              resourceEntries[resourceID] != nil,
                              let generation = rendererWorkerResourceGenerations[resourceID] else {
                            return nil
                        }
                        return (resource, generation)
                    }
                    let rect = try? scanoutRect(from: request, at: 24)
                    let offset = request.leUInt64(at: 40)
                    let flags = request.leUInt32(at: 4)
                    let fenceID = request.leUInt64(at: 8)
                    let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                        || (flags == HeaderFlag.fence && fenceID != 0)
                    guard hasValidFenceHeader,
                          request.leUInt32(at: 16) == 0,
                          request[20..<24].allSatisfy({ $0 == 0 }),
                          resourceID != 0,
                          request.leUInt32(at: 52) == 0,
                          let workerState,
                          let rect,
                          Self.contains(
                            rect: rect,
                            width: workerState.resource.width,
                            height: workerState.resource.height
                          ),
                          let resourceByteCount = Self.rgbaByteCount(
                            width: workerState.resource.width,
                            height: workerState.resource.height
                          ),
                          offset < resourceByteCount,
                          let payload = try? DoryRendererTransfer3DPayload(
                            level: 0,
                            stride: 0,
                            layerStride: 0,
                            offset: offset,
                            x: rect.x,
                            y: rect.y,
                            z: 0,
                            width: rect.width,
                            height: rect.height,
                            depth: 1
                          ) else {
                        return .workerRejected(requestHeader: request)
                    }
                    return .workerTransfer(WorkerTransferAdmission(
                        request: request,
                        resourceID: resourceID,
                        resourceGeneration: workerState.generation,
                        contextID: 0,
                        payload: payload,
                        direction: .toHost,
                        fence: flags == HeaderFlag.fence
                            ? FenceRequest(
                                key: FenceKey(contextID: 0, ringIndex: 0),
                                contextID: 0,
                                ringIndex: 0,
                                fenceID: fenceID,
                                contextFence: false
                            )
                            : nil
                    ))
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable >= 56 {
                let header = access.readBytes(maximum: 56)
                if header.count == 56,
                   header.leUInt32(at: 0) == Command.resourceCreateBlob {
                    guard access.hasWritableSegments,
                          access.writableByteCount >= 24 else {
                        return .rejected(.insufficientResponseCapacity)
                    }
                    let resourceID = header.leUInt32(at: 24)
                    let entryCount = Int(header.leUInt32(at: 36))
                    let (entryBytes, multiplyOverflow) = entryCount
                        .multipliedReportingOverflow(by: 16)
                    let (expectedBytes, addOverflow) = 56
                        .addingReportingOverflow(entryBytes)
                    guard header.leUInt32(at: 4) == 0,
                          header.leUInt64(at: 8) == 0,
                          header[20..<24].allSatisfy({ $0 == 0 }),
                          resourceID != 0,
                          entryCount <= maximumRawMemoryEntries,
                          !multiplyOverflow,
                          !addOverflow,
                          readable == expectedBytes,
                          let payload = try? DoryRendererBlobCreatePayload(
                            blobMemory: header.leUInt32(at: 28),
                            blobFlags: header.leUInt32(at: 32),
                            blobID: header.leUInt64(at: 40),
                            size: header.leUInt64(at: 48)
                          ),
                          payload.size <= maximumRendererReferencedBytes else {
                        return .workerRejected(requestHeader: header)
                    }
                    let request = access.readBytes(maximum: expectedBytes)
                    guard request.count == expectedBytes,
                          let entries = try? memoryEntries(
                            from: request,
                            count: UInt32(entryCount),
                            offset: 56,
                            transport: transport
                          ) else {
                        return .rejected(.invalidDescriptorLayout)
                    }
                    var referencedBytes: UInt64 = 0
                    for entry in entries {
                        let (sum, overflow) = referencedBytes.addingReportingOverflow(
                            UInt64(entry.length)
                        )
                        guard !overflow, sum <= maximumRendererReferencedBytes else {
                            return .workerRejected(requestHeader: header)
                        }
                        referencedBytes = sum
                    }
                    let regions: DoryRendererWorkerSharedRegionSet
                    if entries.isEmpty {
                        regions = DoryRendererWorkerSharedRegionSet(
                            references: [],
                            descriptors: []
                        )
                    } else {
                        guard let guestBacking = try? DoryRendererWorkerSharedRegionSet
                            .guestBacking(entries: entries, transport: transport) else {
                            return .rejected(.invalidDescriptorLayout)
                        }
                        regions = guestBacking
                    }
                    return .workerCreateBlob(WorkerCreateBlobAdmission(
                        request: request,
                        resourceID: resourceID,
                        contextID: header.leUInt32(at: 16),
                        payload: payload,
                        entries: entries,
                        regions: regions
                    ))
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable >= 32 {
                let header = access.readBytes(maximum: 32)
                if header.count == 32,
                   header.leUInt32(at: 0) == Command.resourceAttachBacking {
                    let resourceID = header.leUInt32(at: 24)
                    let workerResourceGeneration = commandLock.withLock {
                        rendererWorkerResourceGenerations[resourceID]
                    }
                    if let workerResourceGeneration {
                        guard access.hasWritableSegments,
                              access.writableByteCount >= 24 else {
                            return .rejected(.insufficientResponseCapacity)
                        }
                        let entryCount = Int(header.leUInt32(at: 28))
                        let (entryBytes, multiplyOverflow) = entryCount
                            .multipliedReportingOverflow(by: 16)
                        let (expectedBytes, addOverflow) = 32
                            .addingReportingOverflow(entryBytes)
                        let flags = header.leUInt32(at: 4)
                        let fenceID = header.leUInt64(at: 8)
                        let hasValidFenceHeader = (flags == 0 && fenceID == 0)
                            || (flags == HeaderFlag.fence && fenceID != 0)
                        guard hasValidFenceHeader,
                              header.leUInt32(at: 16) == 0,
                              header[20..<24].allSatisfy({ $0 == 0 }),
                              resourceID != 0,
                              entryCount > 0,
                              entryCount <= maximumRawMemoryEntries,
                              !multiplyOverflow,
                              !addOverflow,
                              readable == expectedBytes else {
                            return .workerRejected(requestHeader: header)
                        }
                        let request = access.readBytes(maximum: expectedBytes)
                        guard request.count == expectedBytes,
                              let entries = try? memoryEntries(
                                from: request,
                                count: UInt32(entryCount),
                                offset: 32,
                                transport: transport
                              ),
                              !entries.isEmpty else {
                            return .rejected(.invalidDescriptorLayout)
                        }
                        var referencedBytes: UInt64 = 0
                        for entry in entries {
                            let (sum, overflow) = referencedBytes.addingReportingOverflow(
                                UInt64(entry.length)
                            )
                            guard !overflow, sum <= maximumRendererReferencedBytes else {
                                return .workerRejected(requestHeader: header)
                            }
                            referencedBytes = sum
                        }
                        guard let regions = try? DoryRendererWorkerSharedRegionSet.guestBacking(
                            entries: entries,
                            transport: transport
                        ) else {
                            return .rejected(.invalidDescriptorLayout)
                        }
                        return .workerAttachBacking(WorkerAttachBackingAdmission(
                            request: request,
                            resourceID: resourceID,
                            resourceGeneration: workerResourceGeneration,
                            entries: entries,
                            regions: regions,
                            fence: flags == HeaderFlag.fence
                                ? FenceRequest(
                                    key: FenceKey(contextID: 0, ringIndex: 0),
                                    contextID: 0,
                                    ringIndex: 0,
                                    fenceID: fenceID,
                                    contextFence: false
                                )
                                : nil
                        ))
                    }
                    return .workerRejected(requestHeader: header)
                }
            }

            if !cursorQueue, rendererWorkerCandidate != nil, readable >= 32 {
                let header = access.readBytes(maximum: 32)
                if header.count == 32, header.leUInt32(at: 0) == Command.submit3D {
                    guard access.hasWritableSegments,
                          access.writableByteCount >= 24 else {
                        return .rejected(.insufficientResponseCapacity)
                    }
                    let flags = header.leUInt32(at: 4)
                    let hasFence = flags & HeaderFlag.fence != 0
                    let hasContextTimeline = flags & HeaderFlag.infoRingIndex != 0
                    let fenceID = header.leUInt64(at: 8)
                    let contextID = header.leUInt32(at: 16)
                    let ringIndex = UInt32(header[20])
                    let hasCanonicalRing = !hasContextTimeline
                        || ringIndex <= DoryRendererFencePayload.maximumRingIndex
                    let hasCanonicalFencePair = hasFence
                        ? fenceID != 0 && (hasContextTimeline || ringIndex == 0)
                        : fenceID == 0 && (hasContextTimeline || ringIndex == 0)
                    guard flags & ~(HeaderFlag.fence | HeaderFlag.infoRingIndex) == 0,
                          hasCanonicalRing,
                          hasCanonicalFencePair,
                          contextID != 0,
                          header[21..<24].allSatisfy({ $0 == 0 }),
                          header.leUInt32(at: 28) == 0 else {
                        return .workerRejected(requestHeader: header)
                    }
                    let commandByteCount = Int(header.leUInt32(at: 24))
                    let (end, overflow) = 32.addingReportingOverflow(commandByteCount)
                    guard !overflow, end == readable else {
                        return .workerRejected(requestHeader: header)
                    }
                    let regions: DoryRendererWorkerSharedRegionSet
                    let snapshotStarted = DispatchTime.now().uptimeNanoseconds
                    do {
                        regions = try DoryRendererWorkerSharedRegionSet.immutableSubmit3D(
                            from: access,
                            readableOffset: 32,
                            byteCount: commandByteCount,
                            maximumByteCount: maximumControlRequestBytes - 32
                        )
                    } catch {
                        return .rejected(.invalidDescriptorLayout)
                    }
                    let snapshotFinished = DispatchTime.now().uptimeNanoseconds
                    let snapshotNanoseconds = snapshotFinished >= snapshotStarted
                        ? snapshotFinished - snapshotStarted
                        : 0
                    rendererWorkerMetricsLock.withLock {
                        rendererWorkerSnapshotMetrics.count = Self.saturatingAdd(
                            rendererWorkerSnapshotMetrics.count,
                            1
                        )
                        rendererWorkerSnapshotMetrics.bytes = Self.saturatingAdd(
                            rendererWorkerSnapshotMetrics.bytes,
                            UInt64(commandByteCount)
                        )
                        rendererWorkerSnapshotMetrics.nanoseconds = Self.saturatingAdd(
                            rendererWorkerSnapshotMetrics.nanoseconds,
                            snapshotNanoseconds
                        )
                        rendererWorkerSnapshotMetrics.maximumNanoseconds = max(
                            rendererWorkerSnapshotMetrics.maximumNanoseconds,
                            snapshotNanoseconds
                        )
                    }
                    let fence = hasFence ? FenceRequest(
                        key: hasContextTimeline
                            ? FenceKey(contextID: contextID, ringIndex: ringIndex)
                            : FenceKey(contextID: 0, ringIndex: 0),
                        contextID: contextID,
                        ringIndex: hasContextTimeline ? ringIndex : 0,
                        fenceID: fenceID,
                        contextFence: hasContextTimeline
                    ) : nil
                    return .workerSubmit(WorkerSubmitAdmission(
                        requestHeader: header,
                        regions: regions,
                        fence: fence
                    ))
                }
            }
            let request = access.readBytes(maximum: maximum)
            guard request.count == readable else {
                return .rejected(.invalidDescriptorLayout)
            }

            if cursorQueue {
                // Linux's cursor fast path supplies only the outbound 56-byte command. Accept an
                // optional response suffix for other conforming drivers, but never require one.
                guard !access.hasWritableSegments || access.writableByteCount >= 24 else {
                    return .rejected(.insufficientResponseCapacity)
                }
                return .admitted(
                    request: request,
                    writesResponse: access.hasWritableSegments
                )
            }

            guard access.hasWritableSegments,
                  access.writableByteCount >= maximumResponseByteCount(for: request) else {
                return .rejected(.insufficientResponseCapacity)
            }
            return .admitted(request: request, writesResponse: true)
        } ?? .revoked
    }

    private func maximumResponseByteCount(for request: [UInt8]) -> Int {
        guard request.count >= 4 else { return 24 }
        switch request.leUInt32(at: 0) {
        case Command.getDisplayInfo:
            return 24 + 16 * 24
        case Command.getCapsetInfo, Command.resourceAssignUUID:
            return 40
        case Command.resourceMapBlob:
            return 32
        case Command.getCapset:
            guard request.count >= 32 else { return 24 }
            guard rendererCapabilitiesAreAdvertised else { return 24 }
            let id = request.leUInt32(at: 24)
            let version = request.leUInt32(at: 28)
            guard let capset = capsets.first(where: {
                $0.id == id && version <= $0.maxVersion
            }) else { return 24 }
            let (total, overflow) = 24.addingReportingOverflow(capset.data.count)
            return overflow ? Int.max : total
        default:
            return 24
        }
    }

    private func prepareFenceAdmission(
        request: [UInt8],
        responseByteCount: Int,
        transport: VirtioMMIOTransport
    ) -> FenceAdmission {
        guard rendererExecutor != nil, request.count >= 24 else { return .notRequested }
        let flags = request.leUInt32(at: 4)
        guard flags & HeaderFlag.fence != 0 else { return .notRequested }
        let fenceID = request.leUInt64(at: 8)
        let contextID = request.leUInt32(at: 16)
        let ringIndex = UInt32(request[20])
        let contextFence = flags & HeaderFlag.infoRingIndex != 0
        let key = contextFence
            ? FenceKey(contextID: contextID, ringIndex: ringIndex)
            : FenceKey(contextID: 0, ringIndex: 0)
        return fenceLock.withLock {
            guard !fenceAdmissionBlockedUntilDeviceReset,
                  pendingFenceCount < maximumPendingFences,
                  responseByteCount <= maximumPendingFenceResponseBytes,
                  pendingFenceResponseBytes
                    <= maximumPendingFenceResponseBytes - responseByteCount,
                  lastTransport == nil || lastTransport === transport else {
                return .rejected
            }
            return .admitted(FenceRequest(
                key: key,
                contextID: contextID,
                ringIndex: ringIndex,
                fenceID: fenceID,
                contextFence: contextFence
            ))
        }
    }

    /// Holds a successfully processed fenced command until the renderer signals its timeline.
    /// Presentation itself follows RESOURCE_FLUSH and shares the renderer texture; it does not
    /// perform a separate readback operation that needs fence coupling.
    private func deferForFence(
        admission: FenceAdmission,
        response: [UInt8],
        chain: VirtqueueChain,
        transport: VirtioMMIOTransport
    ) -> FenceDeferralOutcome {
        guard let rendererExecutor,
              case .admitted(let fence) = admission,
              response.count >= 4,
              response.leUInt32(at: 0) & 0xFF00 == 0x1100 else {
            return .immediate
        }
        // Publish the waiter before creating the renderer fence. With a fast host GPU (and in
        // particular after a synchronizing readback), virglrenderer may invoke its completion
        // callback from createFence itself or immediately on another thread. Registering after
        // createFence loses that edge forever and stalls the guest compositor on its first frame.
        let waiter = fenceLock.withLock { () -> PendingFence in
            let token = nextFenceToken
            nextFenceToken &+= 1
            if nextFenceToken == 0 { nextFenceToken = 1 }
            let pending = PendingFence(
                token: token,
                fenceID: fence.fenceID,
                epoch: lifecycleEpoch,
                response: response,
                chain: chain,
                createdAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                timeoutReported: false
            )
            pendingFences[fence.key, default: []].append(pending)
            pendingFenceCount += 1
            pendingFenceResponseBytes += response.count
            lastTransport = transport
            return pending
        }
        let fenceOutcome = rendererExecutor.execute(
            .createFence(
                contextID: fence.contextID,
                ringIndex: fence.ringIndex,
                guestFenceID: fence.fenceID,
                contextFence: fence.contextFence
            ),
            generation: waiter.epoch
        )
        switch fenceOutcome {
        case .success(.none):
            fenceLock.withLock {
                fenceCount = Self.saturatingAdd(fenceCount, 1)
            }
            return .deferred
        case .success:
            preconditionFailure("create-fence returned an invalid executor payload")
        case .rejected(let rejection):
            let detail = "renderer fence rejected after command commit: \(rejection)"
            fenceLock.withLock {
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
                if var waiting = pendingFences[fence.key],
                   let index = waiting.firstIndex(where: { $0.token == waiter.token }) {
                    uncertainFences.append(waiting.remove(at: index))
                    pendingFences[fence.key] = waiting.isEmpty ? nil : waiting
                }
                fenceRegistrationFailureCount = Self.saturatingAdd(
                    fenceRegistrationFailureCount,
                    1
                )
                fenceAdmissionBlockedUntilDeviceReset = true
            }
            failRendererLifecycle(
                .fenceRegistrationFailed(detail),
                epoch: waiter.epoch
            )
            return .outcomeUnknown
        case .outcomeUnknown(let uncertainty):
            fenceLock.withLock {
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
                if var waiting = pendingFences[fence.key],
                   let index = waiting.firstIndex(where: { $0.token == waiter.token }) {
                    uncertainFences.append(waiting.remove(at: index))
                    pendingFences[fence.key] = waiting.isEmpty ? nil : waiting
                }
                fenceRegistrationFailureCount = Self.saturatingAdd(
                    fenceRegistrationFailureCount,
                    1
                )
                fenceAdmissionBlockedUntilDeviceReset = true
                if let failure = uncertainty.runtimeFailure {
                    recordRendererFailureWhileLocked(failure)
                }
            }
            // The command may already be executing in the renderer. There is no safe successful
            // or error completion without a fence, so retain this exact descriptor for reset and
            // quarantine new renderer-backed work rather than fabricating completion.
            failRendererLifecycle(
                .fenceRegistrationFailed(uncertainty.detail),
                epoch: waiter.epoch
            )
            return .outcomeUnknown
        }
    }

    private func startRendererWorkerControl(
        _ admission: WorkerControlAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let completion: DoryRendererWorkerVirtioCommandLane.Completion = {
            [weak self, weak transport] result in
            guard let self, let transport else { return }
            self.finishRendererWorkerControl(
                result,
                admission: admission,
                chain: chain,
                claim: claim,
                transport: transport
            )
        }
        do {
            switch admission.operation {
            case .createContext(let name, let capsetID):
                try rendererWorkerCandidate.createContext(
                    contextID: admission.contextID,
                    capsetID: capsetID,
                    name: name,
                    deviceGeneration: generation,
                    completion: completion
                )
            case .destroyContext:
                try rendererWorkerCandidate.destroyContext(
                    contextID: admission.contextID,
                    deviceGeneration: generation,
                    completion: completion
                )
            case .attachResource(let resourceID):
                guard let resourceGeneration = commandLock.withLock({
                    rendererWorkerResourceGenerations[resourceID]
                }) else {
                    throw DoryRendererWorkerVirtioCommandLaneError.invalidSubmitRegions
                }
                try rendererWorkerCandidate.attachResource(
                    contextID: admission.contextID,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    deviceGeneration: generation,
                    completion: completion
                )
            case .detachResource(let resourceID):
                guard let resourceGeneration = commandLock.withLock({
                    rendererWorkerResourceGenerations[resourceID]
                }) else {
                    throw DoryRendererWorkerVirtioCommandLaneError.invalidSubmitRegions
                }
                try rendererWorkerCandidate.detachResource(
                    contextID: admission.contextID,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    deviceGeneration: generation,
                    completion: completion
                )
            }
        } catch {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        return nil
    }

    private func finishRendererWorkerControl(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerControlAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration else { return false }
                switch admission.operation {
                case .createContext(let name, let capsetID):
                    createdContextIDs.insert(admission.contextID)
                    traceResourceEvent(
                        "worker-context-create",
                        contextID: admission.contextID,
                        detail: "name=\(name) capset=\(capsetID)"
                    )
                case .destroyContext:
                    createdContextIDs.remove(admission.contextID)
                    for resourceID in Array(rendererWorkerResourceContextIDs.keys) {
                        rendererWorkerResourceContextIDs[resourceID]?.remove(
                            admission.contextID
                        )
                        if rendererWorkerResourceContextIDs[resourceID]?.isEmpty == true {
                            rendererWorkerResourceContextIDs.removeValue(forKey: resourceID)
                        }
                    }
                    traceResourceEvent(
                        "worker-context-destroy",
                        contextID: admission.contextID
                    )
                case .attachResource(let resourceID):
                    guard rendererWorkerResourceGenerations[resourceID] != nil else {
                        return false
                    }
                    rendererWorkerResourceContextIDs[resourceID, default: []].insert(
                        admission.contextID
                    )
                    traceResourceEvent(
                        "worker-attach",
                        contextID: admission.contextID,
                        resourceID: resourceID
                    )
                case .detachResource(let resourceID):
                    rendererWorkerResourceContextIDs[resourceID]?.remove(admission.contextID)
                    if rendererWorkerResourceContextIDs[resourceID]?.isEmpty == true {
                        rendererWorkerResourceContextIDs.removeValue(forKey: resourceID)
                    }
                    traceResourceEvent(
                        "worker-detach",
                        contextID: admission.contextID,
                        resourceID: resourceID
                    )
                }
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure(let error) where error.provesNoRendererMutation:
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
    }

    private func startRendererWorkerCreateResource3D(
        _ admission: WorkerCreateResource3DAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard canAdmitResource(admission.resourceID) else { return false }
            return rendererWorkerPendingResourceIDs.insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            _ = commandLock.withLock {
                rendererWorkerPendingResourceIDs.remove(admission.resourceID)
            }
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.createResource3D(
                resourceID: admission.resourceID,
                payload: admission.payload,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerCreateResource3D(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingResourceIDs.remove(admission.resourceID)
                }
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        } catch {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
        return nil
    }

    private func finishRendererWorkerCreateResource3D(
        _ result: Result<UInt64, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerCreateResource3DAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success(let workerResourceGeneration):
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerPendingResourceIDs.remove(admission.resourceID) != nil else {
                    return false
                }
                switch admission.kind {
                case .resource2D:
                    resources2D[admission.resourceID] = Resource2D(
                        format: admission.payload.format,
                        width: admission.payload.width,
                        height: admission.payload.height
                    )
                case .resource3D:
                    resources3D[admission.resourceID] = Resource3D(
                        format: admission.payload.format,
                        width: admission.payload.width,
                        height: admission.payload.height
                    )
                }
                rendererWorkerResourceGenerations[admission.resourceID] =
                    workerResourceGeneration
                registerResourceGeneration(admission.resourceID)
                traceResourceEvent(
                    admission.kind == .resource2D
                        ? "worker-create-2d"
                        : "worker-create-3d",
                    resourceID: admission.resourceID,
                    detail: "worker-generation=\(workerResourceGeneration)"
                )
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            if let fence = admission.fence, let pendingFence {
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
            } else {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(type: Response.okNoData, request: admission.request),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            }
        case .failure(let error) where error.provesNoRendererMutation:
            _ = commandLock.withLock {
                rendererWorkerPendingResourceIDs.remove(admission.resourceID)
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
    }

    private func startRendererWorkerCreateBlob(
        _ admission: WorkerCreateBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        defer {
            for descriptor in admission.regions.descriptors { try? descriptor.close() }
        }
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard canAdmitResource(admission.resourceID) else { return false }
            return rendererWorkerPendingResourceIDs.insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.createBlob(
                resourceID: admission.resourceID,
                contextID: admission.contextID,
                payload: admission.payload,
                regions: admission.regions,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerCreateBlob(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingResourceIDs.remove(admission.resourceID)
                }
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        } catch {
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
        return nil
    }

    private func finishRendererWorkerCreateBlob(
        _ result: Result<UInt64, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerCreateBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success(let workerResourceGeneration):
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerPendingResourceIDs.remove(admission.resourceID) != nil else {
                    return false
                }
                blobResources[admission.resourceID] = BlobResource(
                    memory: admission.payload.blobMemory,
                    size: admission.payload.size,
                    mapping: nil,
                    workerMapping: nil
                )
                resourceEntries[admission.resourceID] = admission.entries
                rendererWorkerResourceGenerations[admission.resourceID] =
                    workerResourceGeneration
                registerResourceGeneration(admission.resourceID)
                traceResourceEvent(
                    "worker-create-blob",
                    contextID: admission.contextID,
                    resourceID: admission.resourceID,
                    detail: "worker-generation=\(workerResourceGeneration) "
                        + "size=\(admission.payload.size)"
                )
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure(let error) where error.provesNoRendererMutation:
            _ = commandLock.withLock {
                rendererWorkerPendingResourceIDs.remove(admission.resourceID)
            }
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
    }

    private func startRendererWorkerAttachBacking(
        _ admission: WorkerAttachBackingAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        defer {
            for descriptor in admission.regions.descriptors { try? descriptor.close() }
        }
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration,
                  resourceEntries[admission.resourceID] == nil else { return false }
            return rendererWorkerPendingBackingResourceIDs
                .insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            _ = commandLock.withLock {
                rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
            }
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.attachBacking(
                resourceID: admission.resourceID,
                resourceGeneration: admission.resourceGeneration,
                regions: admission.regions,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerAttachBacking(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
                }
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        } catch {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
        return nil
    }

    private func finishRendererWorkerAttachBacking(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerAttachBackingAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerResourceGenerations[admission.resourceID]
                        == admission.resourceGeneration,
                      rendererWorkerPendingBackingResourceIDs
                        .remove(admission.resourceID) != nil else { return false }
                resourceEntries[admission.resourceID] = admission.entries
                if var resource2D = resources2D[admission.resourceID] {
                    resource2D.backing = admission.entries
                    resources2D[admission.resourceID] = resource2D
                }
                traceResourceEvent(
                    "worker-attach-backing",
                    resourceID: admission.resourceID,
                    detail: "entries=\(admission.entries.count)"
                )
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            if let fence = admission.fence, let pendingFence {
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
            } else {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(type: Response.okNoData, request: admission.request),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            }
        case .failure(let error) where error.provesNoRendererMutation:
            _ = commandLock.withLock {
                rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            // The worker may retain the guest-memory authority. Preserve the reservation and chain
            // until reset so detach/unref cannot race unknown foreign backing ownership.
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
    }

    private func startRendererWorkerDetachBacking(
        _ admission: WorkerDetachBackingAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration,
                  resourceEntries[admission.resourceID] != nil else { return false }
            return rendererWorkerPendingBackingResourceIDs
                .insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            _ = commandLock.withLock {
                rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
            }
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.detachBacking(
                resourceID: admission.resourceID,
                resourceGeneration: admission.resourceGeneration,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerDetachBacking(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
                }
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        } catch {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
        return nil
    }

    private func finishRendererWorkerDetachBacking(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerDetachBackingAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerResourceGenerations[admission.resourceID]
                        == admission.resourceGeneration,
                      rendererWorkerPendingBackingResourceIDs
                        .remove(admission.resourceID) != nil else { return false }
                resourceEntries.removeValue(forKey: admission.resourceID)
                if var resource2D = resources2D[admission.resourceID] {
                    resource2D.backing = []
                    resources2D[admission.resourceID] = resource2D
                }
                traceResourceEvent(
                    "worker-detach-backing",
                    resourceID: admission.resourceID
                )
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            if let fence = admission.fence, let pendingFence {
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
            } else {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(type: Response.okNoData, request: admission.request),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            }
        case .failure(let error) where error.provesNoRendererMutation:
            _ = commandLock.withLock {
                rendererWorkerPendingBackingResourceIDs.remove(admission.resourceID)
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            // Foreign backing ownership may have changed. Keep both the local reservation and the
            // guest descriptor owned until reset establishes a new renderer generation.
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
    }

    private func startRendererWorkerTransfer(
        _ admission: WorkerTransferAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate,
              commandLock.withLock({
                rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration
              }) else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let completion: DoryRendererWorkerVirtioCommandLane.Completion = {
            [weak self, weak transport] result in
            guard let self, let transport else { return }
            self.finishRendererWorkerTransfer(
                result,
                admission: admission,
                chain: chain,
                claim: claim,
                pendingFence: pendingFence,
                transport: transport
            )
        }
        do {
            switch admission.direction {
            case .toHost:
                try rendererWorkerCandidate.transferToHost3D(
                    resourceID: admission.resourceID,
                    resourceGeneration: admission.resourceGeneration,
                    contextID: admission.contextID,
                    payload: admission.payload,
                    deviceGeneration: generation,
                    completion: completion
                )
            case .fromHost:
                try rendererWorkerCandidate.transferFromHost3D(
                    resourceID: admission.resourceID,
                    resourceGeneration: admission.resourceGeneration,
                    contextID: admission.contextID,
                    payload: admission.payload,
                    deviceGeneration: generation,
                    completion: completion
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        } catch {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
        return nil
    }

    private func finishRendererWorkerTransfer(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerTransferAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let current = commandLock.withLock {
                rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration
                    && fenceLock.withLock { lifecycleEpoch == generation }
            }
            guard current else {
                recordTelemetry(.revokedCompletion)
                return
            }
            if let fence = admission.fence, let pendingFence {
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
            } else {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(type: Response.okNoData, request: admission.request),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            }
        case .failure(let error) where error.provesNoRendererMutation:
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
    }

    private func startRendererWorkerUnref(
        _ admission: WorkerUnrefAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard rendererWorkerCandidate != nil else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }

        let retirementReserved = commandLock.withLock { () -> Bool in
            let isCurrentGeneration = fenceLock.withLock {
                lifecycleEpoch == generation
            }
            guard isCurrentGeneration,
                  rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.workerResourceGeneration,
                  resourceGenerations[admission.resourceID]
                    == admission.displayResourceGeneration,
                  rendererWorkerResourceContextIDs[admission.resourceID]?.isEmpty != false,
                  !rendererWorkerPendingResourceIDs.contains(admission.resourceID),
                  !rendererWorkerPendingBackingResourceIDs.contains(admission.resourceID),
                  !rendererWorkerPendingMappingResourceIDs.contains(admission.resourceID),
                  lifecycleLock.withLock({ () -> Bool in
                    guard retiringResources[admission.resourceID] == nil else { return false }
                    retiringResources[admission.resourceID] = admission.displayResourceGeneration
                    return true
                  }) else { return false }
            traceResourceEvent(
                "worker-unref-release-begin",
                resourceID: admission.resourceID,
                detail: "worker-generation=\(admission.workerResourceGeneration)"
            )
            return true
        }
        guard retirementReserved else {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        // Keep the guest-visible bindings intact while the exact display generation drains. The
        // worker cannot unref with a live lease, but a proven pre-mutation rejection must leave
        // local state recoverable; destructive binding removal therefore waits for worker ACK.
        publishResourceRelease(
            resourceID: admission.resourceID,
            generation: admission.displayResourceGeneration
        ) { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.submitRendererWorkerUnrefAfterRelease(
                admission,
                chain: chain,
                claim: claim,
                pendingFence: pendingFence,
                transport: transport
            )
        }
        return nil
    }

    private func submitRendererWorkerUnrefAfterRelease(
        _ admission: WorkerUnrefAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        guard let rendererWorkerCandidate,
              commandLock.withLock({
                rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.workerResourceGeneration
                    && resourceGenerations[admission.resourceID]
                        == admission.displayResourceGeneration
                    && lifecycleLock.withLock {
                        retiringResources[admission.resourceID]
                            == admission.displayResourceGeneration
                    }
                    && fenceLock.withLock { lifecycleEpoch == generation }
              }) else {
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
            return
        }
        do {
            try rendererWorkerCandidate.unrefResource(
                resourceID: admission.resourceID,
                resourceGeneration: admission.workerResourceGeneration,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerUnref(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            finishRendererWorkerUnref(
                .failure(error),
                admission: admission,
                chain: chain,
                claim: claim,
                pendingFence: pendingFence,
                transport: transport
            )
        } catch {
            finishRendererWorkerUnref(
                .failure(.unexpectedWorkerReply),
                admission: admission,
                chain: chain,
                claim: claim,
                pendingFence: pendingFence,
                transport: transport
            )
        }
    }

    private func finishRendererWorkerUnref(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerUnrefAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let removedState = commandLock.withLock { () -> (
                cursor: Bool,
                scanoutIDs: [UInt32]
            )? in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerResourceGenerations[admission.resourceID]
                        == admission.workerResourceGeneration,
                      resourceGenerations[admission.resourceID]
                        == admission.displayResourceGeneration,
                      lifecycleLock.withLock({
                        retiringResources[admission.resourceID]
                            == admission.displayResourceGeneration
                      }) else { return nil }
                resources2D.removeValue(forKey: admission.resourceID)
                resources3D.removeValue(forKey: admission.resourceID)
                blobResources.removeValue(forKey: admission.resourceID)
                resourceEntries.removeValue(forKey: admission.resourceID)
                resourceUUIDs.removeValue(forKey: admission.resourceID)
                resourceGenerations.removeValue(forKey: admission.resourceID)
                rendererWorkerResourceGenerations.removeValue(forKey: admission.resourceID)
                rendererWorkerResourceContextIDs.removeValue(forKey: admission.resourceID)
                let removedCursor = cursorResourceID == admission.resourceID
                if removedCursor { cursorResourceID = nil }
                let scanoutIDs = scanouts.compactMap { scanoutID, binding in
                    binding.resourceID == admission.resourceID ? scanoutID : nil
                }
                scanouts = scanouts.filter { $0.value.resourceID != admission.resourceID }
                hostVisibleMemory?.unmap(resourceID: admission.resourceID)
                lifecycleLock.withLock {
                    if retiringResources[admission.resourceID]
                        == admission.displayResourceGeneration {
                        retiringResources.removeValue(forKey: admission.resourceID)
                    }
                }
                traceResourceEvent(
                    "worker-unref-complete",
                    resourceID: admission.resourceID,
                    detail: "worker-generation=\(admission.workerResourceGeneration)"
                )
                return (removedCursor, scanoutIDs)
            }
            guard let removedState else {
                recordTelemetry(.revokedCompletion)
                return
            }
            if removedState.cursor { onCursorUpdate?(nil) }
            for scanoutID in removedState.scanoutIDs.sorted() {
                onScanoutDisabled?(scanoutID)
            }
            scheduleQuiescenceCleanupIfReady()
            if let fence = admission.fence, let pendingFence {
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
            } else {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(type: Response.okNoData, request: admission.request),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            }
        case .failure(let error) where error.provesNoRendererMutation:
            lifecycleLock.withLock {
                if retiringResources[admission.resourceID]
                    == admission.displayResourceGeneration {
                    retiringResources.removeValue(forKey: admission.resourceID)
                }
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
    }

    private func startRendererWorkerMapBlob(
        _ admission: WorkerMapBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate,
              hostVisibleMemory != nil else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration,
                  let blob = blobResources[admission.resourceID],
                  blob.mapping == nil,
                  blob.workerMapping == nil,
                  !blob.guestMapped else { return false }
            return rendererWorkerPendingMappingResourceIDs
                .insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.mapBlob(
                resourceID: admission.resourceID,
                resourceGeneration: admission.resourceGeneration,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerMapBlob(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingMappingResourceIDs.remove(admission.resourceID)
                }
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        } catch {
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
        return nil
    }

    private func finishRendererWorkerMapBlob(
        _ result: Result<
            DoryRendererWorkerBlobMapping,
            DoryRendererWorkerVirtioCommandLaneError
        >,
        admission: WorkerMapBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success(let mapping):
            let mapInfo = mapping.lease.mapInfo
            let committed: Bool
            do {
                committed = try commandLock.withLock { () throws -> Bool in
                    let isCurrentGeneration = fenceLock.withLock {
                        lifecycleEpoch == generation
                    }
                    guard isCurrentGeneration,
                          rendererWorkerResourceGenerations[admission.resourceID]
                            == admission.resourceGeneration,
                          let blob = blobResources[admission.resourceID],
                          blob.size == mapping.lease.mappingByteCount,
                          rendererWorkerPendingMappingResourceIDs
                            .contains(admission.resourceID),
                          let hostVisibleMemory else {
                        try? mapping.sharedMemoryDescriptor.close()
                        return false
                    }
                    let authority = try DoryRendererWorkerBlobMappingAuthority(mapping)
                    try hostVisibleMemory.map(
                        resourceID: admission.resourceID,
                        hostPointer: authority.hostPointer,
                        offset: admission.hostVisibleOffset,
                        size: authority.lease.mappingByteCount
                    )
                    guard var updated = blobResources[admission.resourceID] else {
                        hostVisibleMemory.unmap(resourceID: admission.resourceID)
                        return false
                    }
                    updated.workerMapping = authority
                    updated.guestMapped = true
                    blobResources[admission.resourceID] = updated
                    rendererWorkerPendingMappingResourceIDs.remove(admission.resourceID)
                    traceResourceEvent(
                        "worker-map-blob",
                        resourceID: admission.resourceID,
                        detail: "offset=\(admission.hostVisibleOffset) "
                            + "size=\(authority.lease.mappingByteCount)"
                    )
                    return true
                }
            } catch {
                fenceLock.withLock {
                    guard lifecycleEpoch == generation else { return }
                    uncertainRendererCommandChains.append(chain)
                    fenceAdmissionBlockedUntilDeviceReset = true
                    recordTelemetryWhileLocked(.rendererCommandUncertainty)
                }
                return
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            var response = responseHeader(
                type: Response.okMapInfo,
                request: admission.request
            )
            response.appendLE(mapInfo)
            response.appendLE(UInt32(0))
            publishRendererWorkerCompletion(
                chain: chain,
                response: response,
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure(let error) where error.provesNoRendererMutation:
            _ = commandLock.withLock {
                rendererWorkerPendingMappingResourceIDs.remove(admission.resourceID)
            }
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure:
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
    }

    private func startRendererWorkerUnmapBlob(
        _ admission: WorkerUnmapBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate,
              hostVisibleMemory != nil else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let reserved = commandLock.withLock { () -> Bool in
            guard rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.resourceGeneration,
                  let blob = blobResources[admission.resourceID],
                  blob.workerMapping != nil,
                  blob.guestMapped else { return false }
            return rendererWorkerPendingMappingResourceIDs
                .insert(admission.resourceID).inserted
        }
        guard reserved else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        do {
            try rendererWorkerCandidate.unmapBlob(
                resourceID: admission.resourceID,
                resourceGeneration: admission.resourceGeneration,
                deviceGeneration: generation,
                beforeWorkerUnmap: { [weak self] in
                    self?.tearDownRendererWorkerBlobMapping(
                        resourceID: admission.resourceID,
                        resourceGeneration: admission.resourceGeneration,
                        deviceGeneration: generation
                    ) ?? false
                }
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerUnmapBlob(
                    result,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    transport: transport
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation {
                _ = commandLock.withLock {
                    rendererWorkerPendingMappingResourceIDs.remove(admission.resourceID)
                }
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        } catch {
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
        return nil
    }

    /// Called only from the worker's serialized lane. The local guest mapping and every VMM-held
    /// descriptor/mmap authority are gone before the lane can encode or send UNMAP_BLOB.
    private func tearDownRendererWorkerBlobMapping(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64
    ) -> Bool {
        commandLock.withLock {
            let isCurrentGeneration = fenceLock.withLock {
                lifecycleEpoch == deviceGeneration
            }
            guard isCurrentGeneration,
                  rendererWorkerResourceGenerations[resourceID] == resourceGeneration,
                  rendererWorkerPendingMappingResourceIDs.contains(resourceID),
                  let hostVisibleMemory,
                  var blob = blobResources[resourceID],
                  blob.workerMapping != nil,
                  blob.guestMapped else { return false }
            hostVisibleMemory.unmap(resourceID: resourceID)
            blob.guestMapped = false
            blob.workerMapping = nil
            blobResources[resourceID] = blob
            traceResourceEvent(
                "worker-unmap-blob-local-teardown",
                resourceID: resourceID,
                detail: "worker-generation=\(resourceGeneration)"
            )
            return true
        }
    }

    private func finishRendererWorkerUnmapBlob(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        admission: WorkerUnmapBlobAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch result {
        case .success:
            let committed = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerResourceGenerations[admission.resourceID]
                        == admission.resourceGeneration,
                      let blob = blobResources[admission.resourceID],
                      blob.workerMapping == nil,
                      !blob.guestMapped,
                      rendererWorkerPendingMappingResourceIDs
                        .remove(admission.resourceID) != nil else { return false }
                traceResourceEvent(
                    "worker-unmap-blob",
                    resourceID: admission.resourceID,
                    detail: "worker-generation=\(admission.resourceGeneration)"
                )
                return true
            }
            guard committed else {
                recordTelemetry(.revokedCompletion)
                return
            }
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .failure(let error) where error.provesNoRendererMutation:
            // A pre-teardown rejection is recoverable. Once local authority was removed, even a
            // proven worker rejection leaves a cross-process lifetime split and must wait for reset.
            let localMappingIsIntact = commandLock.withLock { () -> Bool in
                let isCurrentGeneration = fenceLock.withLock {
                    lifecycleEpoch == generation
                }
                guard isCurrentGeneration,
                      rendererWorkerResourceGenerations[admission.resourceID]
                        == admission.resourceGeneration,
                      let blob = blobResources[admission.resourceID],
                      blob.workerMapping != nil,
                      blob.guestMapped else { return false }
                return rendererWorkerPendingMappingResourceIDs
                    .remove(admission.resourceID) != nil
            }
            if localMappingIsIntact {
                publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
                return
            }
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        case .failure:
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
    }

    /// Acquires one descriptor-backed scanout lease after the qualified guest's producer-complete
    /// RESOURCE_FLUSH. Metal import and command-buffer submission remain asynchronous and off the
    /// vCPU, but the guest chain is not acknowledged until every target has accepted that command
    /// buffer. This prevents a following modeset from overtaking the frame's host ownership.
    private func startRendererWorkerFlushScanout(
        _ admission: WorkerFlushScanoutAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        let generation = claim.generation
        guard let rendererWorkerCandidate else {
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "missing-candidate"
            )
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let remainsCurrent = commandLock.withLock {
            rendererWorkerResourceGenerations[admission.resourceID]
                == admission.workerResourceGeneration
                && resourceGenerations[admission.resourceID]
                    == admission.displayResourceGeneration
        }
        guard remainsCurrent else {
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "stale-resource-identity"
            )
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        let pendingFence = admission.fence.flatMap {
            reserveRendererWorkerFence(
                $0,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                chain: chain,
                generation: generation,
                transport: transport
            )
        }
        if admission.fence != nil, pendingFence == nil {
            recordTelemetry(.fenceAdmissionRejection)
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        guard !admission.targets.isEmpty else {
            if let fence = admission.fence, let pendingFence {
                // A flush of a worker resource that is not currently scanned out has no host
                // presentation stage. Its global fence is the complete ordered boundary.
                startRendererWorkerGlobalFenceAfterMutation(
                    fence,
                    pending: pendingFence,
                    claim: claim,
                    generation: generation,
                    transport: transport
                )
                return nil
            }
            return publishCompletion(
                chain: chain,
                response: responseHeader(type: Response.okNoData, request: admission.request),
                queue: transport.queues[0]
            )
        }
        guard let surface = admission.surface else {
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "missing-surface"
            )
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }
        guard onMetalScanout != nil else {
            // The accelerated candidate is never allowed to silently fall back through the legacy
            // CGL/OpenGL presentation callback. Until the Metal consumer is connected, fail closed.
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "missing-metal-consumer"
            )
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                queue: transport.queues[0]
            )
        }

        do {
            logRendererWorkerScanoutProgress(
                resourceID: admission.resourceID,
                stage: "acquire-submitting"
            )
            try rendererWorkerCandidate.acquireScanoutLease(
                resourceID: admission.resourceID,
                resourceGeneration: admission.workerResourceGeneration,
                width: surface.width,
                height: surface.height,
                virglFormat: surface.format,
                stride: surface.stride,
                storageOffset: surface.offset,
                deviceGeneration: generation
            ) { [weak self, weak transport] disposition in
                guard let self, let transport else {
                    if case .acquired(let scanout) = disposition {
                        scanout.discardTransport()
                    }
                    return
                }
                let dispositionStage = switch disposition {
                case .acquired: "acquire-callback-acquired"
                case .provenRejected: "acquire-callback-proven-rejected"
                case .outcomeUnknown: "acquire-callback-outcome-unknown"
                }
                self.logRendererWorkerScanoutProgress(
                    resourceID: admission.resourceID,
                    stage: dispositionStage
                )
                self.finishRendererWorkerFlushScanout(
                    disposition,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
            logRendererWorkerScanoutProgress(
                resourceID: admission.resourceID,
                stage: "acquire-enqueued"
            )
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "lane-admission",
                detail: String(describing: error)
            )
            if error.provesNoRendererMutation {
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    queue: transport.queues[0]
                )
            }
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        } catch {
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "lane-admission-unexpected",
                detail: String(describing: error)
            )
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        }
        return nil
    }

    private func finishRendererWorkerFlushScanout(
        _ disposition: DoryRendererWorkerScanoutDisposition,
        admission: WorkerFlushScanoutAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        switch disposition {
        case .provenRejected(let error):
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "worker-proven-rejection",
                detail: String(describing: error)
            )
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: false
            )
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.request
                ),
                generation: generation,
                controlClaim: claim,
                transport: transport
            )
        case .outcomeUnknown(let error):
            logRendererWorkerScanoutFailure(
                resourceID: admission.resourceID,
                stage: "worker-outcome-unknown",
                detail: String(describing: error)
            )
            abandonRendererWorkerMutationFence(
                admission.fence,
                pending: pendingFence,
                outcomeUnknown: true
            )
            if pendingFence == nil {
                retainUnknownRendererWorkerChain(chain, generation: generation)
            }
        case .acquired(let scanout):
            logRendererWorkerScanoutProgress(
                resourceID: admission.resourceID,
                stage: "lease-acquired"
            )
            let expectedPixelFormat: DoryRendererScanoutPixelFormat? = switch admission.surface?.format {
            case 1: .bgra8Unorm
            case 67: .rgba8Unorm
            default: nil
            }
            guard let surface = admission.surface,
                  let expectedPixelFormat,
                  scanout.width == surface.width,
                  scanout.height == surface.height,
                  scanout.pixelFormat == expectedPixelFormat,
                  Self.rendererWorkerScanoutTransportMatches(
                    scanout,
                    surface: surface
                  ) else {
                let expected = admission.surface.map {
                    "\($0.width)x\($0.height)/\($0.format)/\($0.stride)/\($0.offset)"
                } ?? "missing"
                let actual = Self.rendererWorkerScanoutDescription(scanout)
                logRendererWorkerScanoutFailure(
                    resourceID: admission.resourceID,
                    stage: "lease-layout-mismatch",
                    detail: "expected=\(expected) actual=\(actual)"
                )
                scanout.discardTransport()
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: true
                )
                if pendingFence == nil {
                    retainUnknownRendererWorkerChain(chain, generation: generation)
                }
                quarantineRendererWorkerGeneration(
                    generation,
                    error: .unexpectedWorkerReply
                )
                return
            }
            let core: DoryRendererWorkerSharedScanoutCore
            do {
                core = try DoryRendererWorkerSharedScanoutCore(
                    scanout: scanout,
                    consumerCount: admission.targets.count,
                    release: { [weak self] scanout in
                        self?.releaseRendererWorkerScanoutLease(
                            scanout,
                            generation: generation,
                            attempt: 0
                        )
                    },
                    terminal: { [weak self] token in
                        self?.removeRendererWorkerScanout(token)
                    }
                )
            } catch {
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: true
                )
                if pendingFence == nil {
                    retainUnknownRendererWorkerChain(chain, generation: generation)
                }
                quarantineRendererWorkerGeneration(
                    generation,
                    error: .unexpectedWorkerReply
                )
                return
            }
            let registered = rendererWorkerPresentationLock.withLock { () -> Bool in
                let token = scanout.releaseToken
                guard rendererWorkerPendingScanouts[token] == nil else { return false }
                if let live = rendererWorkerLiveScanouts[token] {
                    guard live.value == nil else { return false }
                    rendererWorkerLiveScanouts.removeValue(forKey: token)
                }
                rendererWorkerPendingScanouts[token] = core
                return true
            }
            guard registered else {
                core.revoke()
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: true
                )
                if pendingFence == nil {
                    retainUnknownRendererWorkerChain(chain, generation: generation)
                }
                quarantineRendererWorkerGeneration(
                    generation,
                    error: .unexpectedWorkerReply
                )
                return
            }
            logRendererWorkerScanoutProgress(
                resourceID: admission.resourceID,
                stage: "lease-registered"
            )
            rendererWorkerPresentationQueue.async { [weak self] in
                self?.logRendererWorkerScanoutProgress(
                    resourceID: admission.resourceID,
                    stage: "presentation-queue-entered"
                )
                self?.publishRendererWorkerScanout(
                    core,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
        }
    }

    private func publishRendererWorkerScanout(
        _ core: DoryRendererWorkerSharedScanoutCore,
        admission: WorkerFlushScanoutAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        logRendererWorkerScanoutProgress(
            resourceID: admission.resourceID,
            stage: "publication-begin"
        )
        let updates = commandLock.withLock { () -> [VirtioGPUMetalScanoutUpdate]? in
            let isCurrentGeneration = fenceLock.withLock {
                lifecycleEpoch == generation
            }
            guard isCurrentGeneration,
                  rendererWorkerResourceGenerations[admission.resourceID]
                    == admission.workerResourceGeneration,
                  resourceGenerations[admission.resourceID]
                    == admission.displayResourceGeneration,
                  admission.targets.allSatisfy({ target in
                    guard let binding = scanouts[target.scanoutID],
                          binding.resourceID == admission.resourceID,
                          binding.rect == target.sourceRect,
                          admission.surface == rendererWorkerScanoutSurface(
                            for: binding
                          ) else { return false }
                    return true
                  }) else { return nil }

            var presentations = [VirtioGPUMetalScanoutPresentation]()
            presentations.reserveCapacity(admission.targets.count)
            for index in admission.targets.indices {
                guard let presentation = core.makePresentation(consumerID: UInt32(index)) else {
                    return nil
                }
                presentations.append(presentation)
            }

            let movedToLive = rendererWorkerPresentationLock.withLock { () -> Bool in
                let token = core.releaseToken
                guard rendererWorkerPendingScanouts[token] === core else { return false }
                rendererWorkerPendingScanouts.removeValue(forKey: token)
                rendererWorkerLiveScanouts[token] = DoryRendererWorkerWeakScanoutCore(core)
                return true
            }
            guard movedToLive else { return nil }

            let submissionGroup = DoryRendererWorkerHostSubmissionGroup(
                count: admission.targets.count
            ) { [weak self, weak transport] accepted in
                guard let self, let transport else { return }
                self.finishRendererWorkerHostSubmission(
                    accepted: accepted,
                    core: core,
                    admission: admission,
                    chain: chain,
                    claim: claim,
                    pendingFence: pendingFence,
                    transport: transport
                )
            }
            var updates = [VirtioGPUMetalScanoutUpdate]()
            updates.reserveCapacity(admission.targets.count)
            for (index, target) in admission.targets.enumerated() {
                updates.append(VirtioGPUMetalScanoutUpdate(
                    scanoutID: target.scanoutID,
                    resourceID: admission.resourceID,
                    resourceGeneration: admission.displayResourceGeneration,
                    rendererResourceGeneration: admission.workerResourceGeneration,
                    presentation: presentations[index],
                    sourceRect: target.sourceRect,
                    dirtyRect: target.dirtyRect,
                    hostSubmission: VirtioGPUMetalScanoutHostSubmission { accepted in
                        submissionGroup.resolve(accepted: accepted)
                    }
                ))
            }
            return updates
        }
        guard let updates, let onMetalScanout else {
            let current = fenceLock.withLock { lifecycleEpoch == generation }
            if current {
                core.retireWithoutPresentation()
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                logRendererWorkerScanoutFailure(
                    resourceID: admission.resourceID,
                    stage: "host-publication-rejected"
                )
                _ = publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            } else {
                core.revoke()
            }
            return
        }
        // The command claim serializes a following SET_SCANOUT until host submission resolves.
        // Invoke the external mailbox only after the state snapshot and pending→live transition
        // have released commandLock; a synchronous accept/reject may reenter queue completion.
        for update in updates {
            logRendererWorkerScanoutProgress(
                resourceID: admission.resourceID,
                stage: "mailbox-submitting"
            )
            onMetalScanout(update)
        }
    }

    private func finishRendererWorkerHostSubmission(
        accepted: Bool,
        core: DoryRendererWorkerSharedScanoutCore,
        admission: WorkerFlushScanoutAdmission,
        chain: VirtqueueChain,
        claim: RendererWorkerControlCommandClaim,
        pendingFence: PendingFence?,
        transport: VirtioMMIOTransport
    ) {
        let generation = claim.generation
        logRendererWorkerScanoutProgress(
            resourceID: admission.resourceID,
            stage: accepted ? "host-submission-accepted" : "host-submission-rejected"
        )
        guard accepted else {
            let current = fenceLock.withLock { lifecycleEpoch == generation }
            if current {
                core.retireWithoutPresentation()
                abandonRendererWorkerMutationFence(
                    admission.fence,
                    pending: pendingFence,
                    outcomeUnknown: false
                )
                logRendererWorkerScanoutFailure(
                    resourceID: admission.resourceID,
                    stage: "metal-command-buffer-rejected"
                )
                _ = publishRendererWorkerCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.request
                    ),
                    generation: generation,
                    controlClaim: claim,
                    transport: transport
                )
            } else {
                core.revoke()
            }
            return
        }

        if let fence = admission.fence {
            guard let pendingFence else {
                core.retireWithoutPresentation()
                retainUnknownRendererWorkerChain(chain, generation: generation)
                quarantineRendererWorkerGeneration(
                    generation,
                    error: .unexpectedWorkerReply
                )
                return
            }
            // RESOURCE_FLUSH is complete only once the Metal consumer has committed its host
            // submission. Export the renderer's global fence strictly after that acceptance; the
            // pending guest response remains owned until the descriptor signals.
            startRendererWorkerGlobalFenceAfterMutation(
                fence,
                pending: pendingFence,
                claim: claim,
                generation: generation,
                transport: transport
            )
            return
        }

        let completed = publishRendererWorkerCompletion(
            chain: chain,
            response: responseHeader(type: Response.okNoData, request: admission.request),
            generation: generation,
            controlClaim: claim,
            transport: transport
        )
        guard !completed else { return }
        let current = fenceLock.withLock { lifecycleEpoch == generation }
        if current {
            core.retireWithoutPresentation()
        } else {
            core.revoke()
        }
    }

    private func releaseRendererWorkerScanoutLease(
        _ scanout: DoryRendererWorkerScanoutAuthority,
        generation: UInt64,
        attempt: Int
    ) {
        guard fenceLock.withLock({ lifecycleEpoch == generation }),
              let rendererWorkerCandidate else { return }
        do {
            let completion: DoryRendererWorkerVirtioCommandLane.Completion = { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    break
                case .failure(let error)
                    where error.provesNoRendererMutation && attempt == 0:
                    self.rendererWorkerPresentationQueue.async { [weak self] in
                        self?.releaseRendererWorkerScanoutLease(
                            scanout,
                            generation: generation,
                            attempt: 1
                        )
                    }
                case .failure(let error):
                    self.quarantineRendererWorkerGeneration(generation, error: error)
                }
            }
            switch scanout {
            case .sharedMemory(let value):
                try rendererWorkerCandidate.releaseScanoutLease(
                    value.lease,
                    deviceGeneration: generation,
                    completion: completion
                )
            case .sharedTexture(let value):
                try rendererWorkerCandidate.releaseScanoutLease(
                    value.lease,
                    deviceGeneration: generation,
                    completion: completion
                )
            }
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            if error.provesNoRendererMutation && attempt == 0 {
                rendererWorkerPresentationQueue.async { [weak self] in
                    self?.releaseRendererWorkerScanoutLease(
                        scanout,
                        generation: generation,
                        attempt: 1
                    )
                }
            } else {
                quarantineRendererWorkerGeneration(generation, error: error)
            }
        } catch {
            quarantineRendererWorkerGeneration(generation, error: .unexpectedWorkerReply)
        }
    }

    private func removeRendererWorkerScanout(
        _ token: DoryRendererScanoutReleaseToken
    ) {
        rendererWorkerPresentationLock.withLock {
            rendererWorkerPendingScanouts.removeValue(forKey: token)
            rendererWorkerLiveScanouts.removeValue(forKey: token)
        }
    }

    private func revokeRendererWorkerScanouts() {
        let cores = rendererWorkerPresentationLock.withLock { () -> [
            DoryRendererWorkerSharedScanoutCore
        ] in
            var unique = [ObjectIdentifier: DoryRendererWorkerSharedScanoutCore]()
            for core in rendererWorkerPendingScanouts.values {
                unique[ObjectIdentifier(core)] = core
            }
            for weakCore in rendererWorkerLiveScanouts.values {
                if let core = weakCore.value { unique[ObjectIdentifier(core)] = core }
            }
            rendererWorkerPendingScanouts.removeAll(keepingCapacity: false)
            rendererWorkerLiveScanouts.removeAll(keepingCapacity: false)
            return Array(unique.values)
        }
        for core in cores { core.revoke() }
    }

    private func retainUnknownRendererWorkerChain(
        _ chain: VirtqueueChain,
        generation: UInt64
    ) {
        fenceLock.withLock {
            guard lifecycleEpoch == generation else { return }
            uncertainRendererCommandChains.append(chain)
            fenceAdmissionBlockedUntilDeviceReset = true
            recordTelemetryWhileLocked(.rendererCommandUncertainty)
        }
    }

    private func quarantineRendererWorkerGeneration(
        _ generation: UInt64,
        error: DoryRendererWorkerVirtioCommandLaneError
    ) {
        guard fenceLock.withLock({ lifecycleEpoch == generation }) else { return }
        rendererWorkerCandidate?.revoke(deviceGeneration: generation)
        revokeRendererWorkerScanouts()
        rendererWorkerCandidateFailed(generation: generation, error: error)
    }

    /// Transfers a previously snapshotted submit authority to the signed-worker lane and returns
    /// immediately after bounded local admission. A nil result means the exact descriptor chain
    /// is now owned by an asynchronous submit/fence completion path.
    private func startRendererWorkerSubmit(
        _ admission: WorkerSubmitAdmission,
        chain: VirtqueueChain,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> QueueCompletionOutcome? {
        defer {
            for descriptor in admission.regions.descriptors { try? descriptor.close() }
        }
        guard let rendererWorkerCandidate else {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.requestHeader
                ),
                queue: transport.queues[0]
            )
        }
        let successResponse = responseHeader(
            type: Response.okNoData,
            request: admission.requestHeader
        )

        if let fence = admission.fence {
            guard let pending = reserveRendererWorkerFence(
                fence,
                response: successResponse,
                chain: chain,
                generation: generation,
                transport: transport
            ) else {
                recordTelemetry(.fenceAdmissionRejection)
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.requestHeader
                    ),
                    queue: transport.queues[0]
                )
            }
            do {
                try rendererWorkerCandidate.submit3DThenCreateFence(
                    contextID: fence.contextID,
                    regions: admission.regions,
                    ringIndex: fence.ringIndex,
                    fenceID: fence.fenceID,
                    contextFence: fence.contextFence,
                    deviceGeneration: generation
                ) { [weak self, weak transport] disposition in
                    guard let self, let transport else { return }
                    self.finishRendererWorkerFencedSubmit(
                        disposition,
                        fence: fence,
                        pending: pending,
                        requestHeader: admission.requestHeader,
                        transport: transport
                    )
                }
            } catch {
                _ = removeRendererWorkerFence(
                    fence,
                    token: pending.token,
                    makeUncertain: false
                )
                return publishCompletion(
                    chain: chain,
                    response: responseHeader(
                        type: Response.errorInvalidParameter,
                        request: admission.requestHeader
                    ),
                    queue: transport.queues[0]
                )
            }
            return nil
        }

        do {
            try rendererWorkerCandidate.submit3D(
                contextID: admission.requestHeader.leUInt32(at: 16),
                regions: admission.regions,
                deviceGeneration: generation
            ) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                self.finishRendererWorkerUnfencedSubmit(
                    result,
                    chain: chain,
                    generation: generation,
                    requestHeader: admission.requestHeader,
                    transport: transport
                )
            }
        } catch {
            return publishCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: admission.requestHeader
                ),
                queue: transport.queues[0]
            )
        }
        return nil
    }

    private func reserveRendererWorkerFence(
        _ fence: FenceRequest,
        response: [UInt8],
        chain: VirtqueueChain,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> PendingFence? {
        return fenceLock.withLock {
            let fenceIDIsUnique = !pendingFences.values.joined().contains {
                $0.fenceID == fence.fenceID && $0.epoch == generation
            } && !uncertainFences.contains {
                $0.fenceID == fence.fenceID && $0.epoch == generation
            }
            guard lifecycleEpoch == generation,
                  (!fence.contextFence || fence.contextID != 0),
                  fence.contextFence || (
                    fence.key == FenceKey(contextID: 0, ringIndex: 0)
                        && fence.ringIndex == 0
                  ),
                  fence.fenceID != 0,
                  fenceIDIsUnique,
                  !fenceAdmissionBlockedUntilDeviceReset,
                  pendingFenceCount < maximumPendingFences,
                  response.count <= maximumPendingFenceResponseBytes,
                  pendingFenceResponseBytes
                    <= maximumPendingFenceResponseBytes - response.count,
                  lastTransport == nil || lastTransport === transport else {
                return nil
            }
            let token = nextFenceToken
            nextFenceToken &+= 1
            if nextFenceToken == 0 { nextFenceToken = 1 }
            let pending = PendingFence(
                token: token,
                fenceID: fence.fenceID,
                epoch: generation,
                response: response,
                chain: chain,
                createdAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                timeoutReported: false
            )
            pendingFences[fence.key, default: []].append(pending)
            pendingFenceCount += 1
            pendingFenceResponseBytes += response.count
            lastTransport = transport
            return pending
        }
    }

    /// Completes the second stage of an ordinary fenced control command. The mutation has already
    /// been authenticated by the worker; only an exported global fence may release the guest
    /// response. Any failure from this point is therefore outcome-unknown for the compound command.
    private func startRendererWorkerGlobalFenceAfterMutation(
        _ fence: FenceRequest,
        pending: PendingFence,
        claim: RendererWorkerControlCommandClaim,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        guard let rendererWorkerCandidate else {
            _ = removeRendererWorkerFence(fence, token: pending.token, makeUncertain: true)
            return
        }
        let completion: DoryRendererWorkerVirtioCommandLane.Completion = {
            [weak self, weak transport] result in
            guard let self, let transport else { return }
            switch result {
            case .success:
                self.fenceLock.withLock {
                    self.fenceCount = Self.saturatingAdd(self.fenceCount, 1)
                }
                let released = transport.withQueueLock {
                    self.fenceLock.withLock { self.lifecycleEpoch == generation }
                        && self.completeRendererWorkerControlCommand(claim: claim)
                }
                if released { self.scheduleRendererWorkerQueueResume(transport) }
            case .failure(let error):
                _ = self.removeRendererWorkerFence(
                    fence,
                    token: pending.token,
                    makeUncertain: true
                )
                self.quarantineRendererWorkerGeneration(generation, error: error)
            }
        }
        do {
            try rendererWorkerCandidate.createGlobalFence(
                fenceID: fence.fenceID,
                deviceGeneration: generation,
                completion: completion
            )
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            _ = removeRendererWorkerFence(fence, token: pending.token, makeUncertain: true)
            quarantineRendererWorkerGeneration(generation, error: error)
        } catch {
            _ = removeRendererWorkerFence(fence, token: pending.token, makeUncertain: true)
            quarantineRendererWorkerGeneration(generation, error: .unexpectedWorkerReply)
        }
    }

    private func abandonRendererWorkerMutationFence(
        _ fence: FenceRequest?,
        pending: PendingFence?,
        outcomeUnknown: Bool
    ) {
        guard let fence, let pending else { return }
        _ = removeRendererWorkerFence(
            fence,
            token: pending.token,
            makeUncertain: outcomeUnknown
        )
    }

    @discardableResult
    private func removeRendererWorkerFence(
        _ fence: FenceRequest,
        token: UInt64,
        makeUncertain: Bool
    ) -> PendingFence? {
        fenceLock.withLock {
            guard var waiting = pendingFences[fence.key],
                  let index = waiting.firstIndex(where: { $0.token == token }) else {
                return nil
            }
            let removed = waiting.remove(at: index)
            pendingFences[fence.key] = waiting.isEmpty ? nil : waiting
            if makeUncertain {
                uncertainFences.append(removed)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            } else {
                pendingFenceCount = max(0, pendingFenceCount - 1)
                pendingFenceResponseBytes = max(
                    0,
                    pendingFenceResponseBytes - removed.response.count
                )
                if pendingFenceCount == 0 { lastTransport = nil }
            }
            return removed
        }
    }

    private func finishRendererWorkerFencedSubmit(
        _ disposition: DoryRendererWorkerVirtioSubmissionDisposition,
        fence: FenceRequest,
        pending: PendingFence,
        requestHeader: [UInt8],
        transport: VirtioMMIOTransport
    ) {
        switch disposition {
        case .fenceArmed:
            // The pending chain remains owned until the completion descriptor becomes readable.
            fenceLock.withLock {
                fenceCount = Self.saturatingAdd(fenceCount, 1)
            }
            scheduleRendererWorkerQueueResume(transport)
            return
        case .provenRejected:
            guard removeRendererWorkerFence(
                fence,
                token: pending.token,
                makeUncertain: false
            ) != nil else { return }
            publishRendererWorkerCompletion(
                chain: pending.chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: requestHeader
                ),
                generation: pending.epoch,
                transport: transport
            )
        case .outcomeUnknown:
            _ = removeRendererWorkerFence(
                fence,
                token: pending.token,
                makeUncertain: true
            )
        }
    }

    private func finishRendererWorkerUnfencedSubmit(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>,
        chain: VirtqueueChain,
        generation: UInt64,
        requestHeader: [UInt8],
        transport: VirtioMMIOTransport
    ) {
        switch result {
        case .success:
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(type: Response.okNoData, request: requestHeader),
                generation: generation,
                transport: transport
            )
        case .failure(let error) where error.provesNoRendererMutation:
            publishRendererWorkerCompletion(
                chain: chain,
                response: responseHeader(
                    type: Response.errorInvalidParameter,
                    request: requestHeader
                ),
                generation: generation,
                transport: transport
            )
        case .failure:
            fenceLock.withLock {
                guard lifecycleEpoch == generation else { return }
                uncertainRendererCommandChains.append(chain)
                fenceAdmissionBlockedUntilDeviceReset = true
                recordTelemetryWhileLocked(.rendererCommandUncertainty)
            }
        }
    }

    @discardableResult
    private func publishRendererWorkerCompletion(
        chain: VirtqueueChain,
        response: [UInt8],
        generation: UInt64,
        controlClaim: RendererWorkerControlCommandClaim? = nil,
        transport: VirtioMMIOTransport
    ) -> Bool {
        let shouldResume = transport.withQueueLock { () -> Bool in
            let isCurrentGeneration = fenceLock.withLock {
                lifecycleEpoch == generation
            }
            guard isCurrentGeneration else {
                recordTelemetry(.revokedCompletion)
                return false
            }
            switch publishCompletion(
                chain: chain,
                response: response,
                queue: transport.queues[0]
            ) {
            case .published(let wantsInterrupt):
                if let controlClaim {
                    // The queue lock excludes a new kick between used publication and release.
                    // Token equality excludes completions from older pipelined work in this epoch.
                    completeRendererWorkerControlCommand(claim: controlClaim)
                }
                if wantsInterrupt { transport.notifyUsed() }
                return true
            case .revoked:
                return false
            case .failed:
                recordTelemetry(.undeliveredFenceCompletion)
                return false
            }
        }
        // A stale completion must not kick a replacement queue generation. Only a completion that
        // published its used entry may continue draining descriptors already available behind it.
        if shouldResume {
            scheduleRendererWorkerQueueResume(transport)
        }
        return shouldResume
    }

    private func scheduleRendererWorkerQueueResume(_ transport: VirtioMMIOTransport) {
        rendererWorkerResumeQueue.async { [weak self, weak transport] in
            guard let self, let transport else { return }
            transport.withQueueLock {
                self.handleKick(queue: 0, transport: transport)
            }
        }
    }

    private func rendererWorkerCandidateFailed(
        generation: UInt64,
        error: DoryRendererWorkerVirtioCommandLaneError
    ) {
        let affected = fenceLock.withLock { () -> Int in
            guard lifecycleEpoch == generation else { return 0 }
            var count = 0
            for key in Array(pendingFences.keys) {
                guard var waiting = pendingFences[key] else { continue }
                let uncertain = waiting.filter { $0.epoch == generation }
                waiting.removeAll { $0.epoch == generation }
                pendingFences[key] = waiting.isEmpty ? nil : waiting
                uncertainFences.append(contentsOf: uncertain)
                count += uncertain.count
            }
            fenceAdmissionBlockedUntilDeviceReset = true
            recordTelemetryWhileLocked(
                .rendererCommandUncertainty,
                count: UInt64(max(1, count))
            )
            return count
        }
        failRendererLifecycle(
            .commandOutcomeUnknown(
                operation: "renderer-worker",
                detail: String(describing: error)
            ),
            epoch: generation
        )
        FileHandle.standardError.write(Data((
            "dory-gpu: renderer worker generation \(generation) failed; "
                + "retained \(affected) uncertain fenced chains: \(error)\n"
        ).utf8))
        onRendererWorkerFailure?(
            "generation \(generation) failed: \(String(describing: error))"
        )
    }

    public var statistics: VirtioGPUStatistics {
        let worker = rendererWorkerCandidate?.snapshot()
        let snapshots = rendererWorkerMetricsLock.withLock {
            rendererWorkerSnapshotMetrics
        }
        let softwareCopies = softwareScanoutMetricsLock.withLock {
            softwareScanoutCopiedBytes
        }
        return fenceLock.withLock {
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
            for index in uncertainFences.indices {
                if !uncertainFences[index].timeoutReported {
                    let started = uncertainFences[index].createdAtMonotonicNanoseconds
                    let age = now >= started ? now - started : 0
                    if age >= fenceTimeoutNanoseconds {
                        uncertainFences[index].timeoutReported = true
                        newlyTimedOut = Self.saturatingAdd(newlyTimedOut, 1)
                    }
                }
                hasTimedOutPendingFence = hasTimedOutPendingFence
                    || uncertainFences[index].timeoutReported
            }
            fenceTimeoutCount = Self.saturatingAdd(fenceTimeoutCount, newlyTimedOut)
            return VirtioGPUStatistics(
                fences: fenceCount,
                fenceRegistrationFailures: fenceRegistrationFailureCount,
                fenceTimeouts: fenceTimeoutCount,
                hasTimedOutPendingFence: hasTimedOutPendingFence,
                rendererDeviceLosses: rendererDeviceLossCount,
                hasLostRendererDevice: rendererDeviceLossLatched,
                queuePendingReadFailures: queuePendingReadFailureCount,
                queuePopFailures: queuePopFailureCount,
                invalidDescriptorChains: invalidDescriptorChainCount,
                oversizedRequests: oversizedRequestCount,
                insufficientResponseCapacity: insufficientResponseCapacityCount,
                queuePushFailures: queuePushFailureCount,
                revokedCompletions: revokedCompletionCount,
                undeliveredFenceCompletions: undeliveredFenceCompletionCount,
                responseWriteFailures: responseWriteFailureCount,
                fenceAdmissionRejections: fenceAdmissionRejectionCount,
                queueRevokedFences: queueRevokedFenceCount,
                resetRevokedFences: resetRevokedFenceCount,
                rendererCommandUncertainties: rendererCommandUncertaintyCount,
                revokedUncertainRendererCommands: revokedUncertainRendererCommandCount,
                rendererWorkerSnapshotCount: snapshots.count,
                rendererWorkerSnapshotBytes: snapshots.bytes,
                rendererWorkerSnapshotNanoseconds: snapshots.nanoseconds,
                rendererWorkerMaximumSnapshotNanoseconds: snapshots.maximumNanoseconds,
                rendererWorkerQueuedCommands: worker?.queuedCommands ?? 0,
                rendererWorkerMaximumQueuedCommands:
                    worker?.maximumObservedQueuedCommands ?? 0,
                rendererWorkerRejectedAdmissions: worker?.rejectedAdmissions ?? 0,
                rendererWorkerCompletedControlCommands:
                    worker?.completedControlCommands ?? 0,
                rendererWorkerCompletedResourceCommands:
                    worker?.completedResourceCommands ?? 0,
                rendererWorkerCompletedSubmissions: worker?.completedSubmissions ?? 0,
                rendererWorkerArmedFences: worker?.armedFences ?? 0,
                rendererWorkerCompletedFences: worker?.completedFences ?? 0,
                // The accelerated presentation contract has no copied-frame operation.
                rendererWorkerScanoutCopyBytes: 0,
                softwareScanoutCopiedBytes: softwareCopies
            )
        }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }

    private func recordAdmissionRejection(_ rejection: QueueAdmissionRejection) {
        switch rejection {
        case .invalidDescriptorLayout:
            recordTelemetry(.invalidDescriptorChain)
        case .oversizedRequest:
            recordTelemetry(.oversizedRequest)
        case .insufficientResponseCapacity:
            recordTelemetry(.insufficientResponseCapacity)
        }
    }

    private func recordTelemetry(_ event: TelemetryEvent, count: UInt64 = 1) {
        fenceLock.withLock { recordTelemetryWhileLocked(event, count: count) }
    }

    private func recordTelemetryWhileLocked(
        _ event: TelemetryEvent,
        count: UInt64 = 1
    ) {
        switch event {
        case .queuePendingReadFailure:
            queuePendingReadFailureCount = Self.saturatingAdd(
                queuePendingReadFailureCount,
                count
            )
        case .queuePopFailure:
            queuePopFailureCount = Self.saturatingAdd(queuePopFailureCount, count)
        case .invalidDescriptorChain:
            invalidDescriptorChainCount = Self.saturatingAdd(
                invalidDescriptorChainCount,
                count
            )
        case .oversizedRequest:
            oversizedRequestCount = Self.saturatingAdd(oversizedRequestCount, count)
        case .insufficientResponseCapacity:
            insufficientResponseCapacityCount = Self.saturatingAdd(
                insufficientResponseCapacityCount,
                count
            )
        case .queuePushFailure:
            queuePushFailureCount = Self.saturatingAdd(queuePushFailureCount, count)
        case .revokedCompletion:
            revokedCompletionCount = Self.saturatingAdd(revokedCompletionCount, count)
        case .undeliveredFenceCompletion:
            undeliveredFenceCompletionCount = Self.saturatingAdd(
                undeliveredFenceCompletionCount,
                count
            )
        case .responseWriteFailure:
            responseWriteFailureCount = Self.saturatingAdd(
                responseWriteFailureCount,
                count
            )
        case .fenceAdmissionRejection:
            fenceAdmissionRejectionCount = Self.saturatingAdd(
                fenceAdmissionRejectionCount,
                count
            )
        case .queueRevokedFence:
            queueRevokedFenceCount = Self.saturatingAdd(queueRevokedFenceCount, count)
        case .resetRevokedFence:
            resetRevokedFenceCount = Self.saturatingAdd(resetRevokedFenceCount, count)
        case .rendererCommandUncertainty:
            rendererCommandUncertaintyCount = Self.saturatingAdd(
                rendererCommandUncertaintyCount,
                count
            )
        case .revokedUncertainRendererCommand:
            revokedUncertainRendererCommandCount = Self.saturatingAdd(
                revokedUncertainRendererCommandCount,
                count
            )
        }
    }

    private func publishCompletion(
        chain: VirtqueueChain,
        response: [UInt8]?,
        queue: Virtqueue
    ) -> QueueCompletionOutcome {
        if let response {
            let wroteResponse = chain.withLeaseHeld { access -> Bool in
                guard access.writableByteCount >= response.count else { return false }
                return access.writeBytes(response) == response.count
            }
            guard let wroteResponse else {
                recordTelemetry(.revokedCompletion)
                return .revoked
            }
            guard wroteResponse else {
                recordTelemetry(.responseWriteFailure)
                return .failed
            }
        }
        do {
            switch try queue.pushOutcome(chain, written: response?.count ?? 0) {
            case .published(let wantsInterrupt):
                return .published(wantsInterrupt: wantsInterrupt)
            case .revoked:
                recordTelemetry(.revokedCompletion)
                return .revoked
            }
        } catch {
            recordTelemetry(.queuePushFailure)
            return .failed
        }
    }

    /// Renderer-thread entry: completes the signaled fence and every earlier admission on its
    /// timeline. Registration order is the authority: guest 64-bit ids may wrap or be
    /// non-monotonic, and the global renderer callback uses an unrelated 32-bit host token.
    private func fenceSignaled(
        generation: UInt64,
        contextID: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64
    ) {
        let key = FenceKey(contextID: contextID, ringIndex: ringIndex)
        fenceLock.lock()
        var completed = [PendingFence]()
        if var waiting = pendingFences[key] {
            if let target = waiting.firstIndex(where: {
                $0.epoch == generation && $0.fenceID == fenceID
            }) {
                var survivors = [PendingFence]()
                survivors.reserveCapacity(waiting.count)
                for (index, pending) in waiting.enumerated() {
                    if index <= target && pending.epoch == generation {
                        completed.append(pending)
                    } else {
                        survivors.append(pending)
                    }
                }
                waiting = survivors
            }
            pendingFences[key] = waiting.isEmpty ? nil : waiting
        }
        let transport = lastTransport
        pendingFenceCount = max(0, pendingFenceCount - completed.count)
        let completedResponseBytes = completed.reduce(into: 0) { total, pending in
            total += pending.response.count
        }
        pendingFenceResponseBytes = max(
            0,
            pendingFenceResponseBytes - completedResponseBytes
        )
        if transport == nil, !completed.isEmpty {
            recordTelemetryWhileLocked(
                .revokedCompletion,
                count: UInt64(completed.count)
            )
        }
        fenceLock.unlock()
        guard !completed.isEmpty, let transport else { return }
        transport.withQueueLock {
            // Reset is serialized by this same transport lock. Recheck the lifecycle only after
            // acquiring it: a callback may have removed its waiter, then blocked here while reset
            // cleared and reconfigured the queue.
            let lifecycle = fenceLock.withLock { (lifecycleEpoch, lastTransport === transport) }
            guard lifecycle.1 else {
                recordTelemetry(.revokedCompletion, count: UInt64(completed.count))
                return
            }
            let staleCount = completed.lazy.filter { $0.epoch != lifecycle.0 }.count
            if staleCount > 0 {
                recordTelemetry(.revokedCompletion, count: UInt64(staleCount))
            }
            completed.removeAll { $0.epoch != lifecycle.0 }
            guard !completed.isEmpty else { return }
            var interrupt = false
            completionLoop: for (index, pending) in completed.enumerated() {
                switch publishCompletion(
                    chain: pending.chain,
                    response: pending.response,
                    queue: transport.queues[0]
                ) {
                case .published(let wants):
                    interrupt = interrupt || wants
                case .revoked:
                    let remaining = completed.count - index - 1
                    if remaining > 0 {
                        recordTelemetry(.revokedCompletion, count: UInt64(remaining))
                    }
                    break completionLoop
                case .failed:
                    recordTelemetry(
                        .undeliveredFenceCompletion,
                        count: UInt64(completed.count - index)
                    )
                    break completionLoop
                }
            }
            if interrupt {
                transport.notifyUsed()
            }
        }
        fenceLock.withLock {
            if pendingFenceCount == 0, lastTransport === transport {
                lastTransport = nil
            }
        }
    }

    private func registerResourceGeneration(_ resourceID: UInt32) {
        resourceGenerations[resourceID] = nextResourceGeneration
        nextResourceGeneration &+= 1
        if nextResourceGeneration == 0 { nextResourceGeneration = 1 }
    }

    public var rendererLifecycleHealth: VirtioGPURendererLifecycleHealth {
        lifecycleLock.withLock { rendererLifecycleHealthState }
    }

    private func isResourceRetiring(_ resourceID: UInt32) -> Bool {
        lifecycleLock.withLock { retiringResources[resourceID] != nil }
    }

    private func canAdmitResource(_ resourceID: UInt32) -> Bool {
        guard resources2D[resourceID] == nil,
              resources3D[resourceID] == nil,
              blobResources[resourceID] == nil,
              !rendererWorkerPendingResourceIDs.contains(resourceID) else { return false }
        return lifecycleLock.withLock {
            retiringResources[resourceID] == nil
                && resources2D.count + resources3D.count + blobResources.count
                    + retiringResources.count < maximumTrackedResources
        }
    }

    private func beginResourceRetirement(
        resourceID: UInt32,
        generation: UInt64,
        requiresBlobUnmap: Bool,
        rendererGeneration: UInt64
    ) {
        let inserted = lifecycleLock.withLock { () -> Bool in
            guard retiringResources[resourceID] == nil else { return false }
            retiringResources[resourceID] = generation
            return true
        }
        guard inserted else {
            FileHandle.standardError.write(Data(
                "dory-gpu: duplicate renderer retirement resource=\(resourceID) generation=\(generation)\n".utf8
            ))
            return
        }

        publishResourceRelease(
            resourceID: resourceID,
            generation: generation
        ) { [self] in
            rendererRetirementQueue.async { [self] in
                do {
                    if requiresBlobUnmap, rendererExecutor != nil {
                        _ = try executeRendererCommand(
                            .unmapBlob(resourceID: resourceID),
                            generation: rendererGeneration,
                            purpose: .retirement
                        )
                    }
                    if rendererExecutor != nil {
                        _ = try executeRendererCommand(
                            .unrefResource(resourceID: resourceID),
                            generation: rendererGeneration,
                            purpose: .retirement
                        )
                    }
                    lifecycleLock.withLock {
                        if retiringResources[resourceID] == generation {
                            retiringResources.removeValue(forKey: resourceID)
                        }
                    }
                    scheduleQuiescenceCleanupIfReady()
                } catch {
                    let fault = VirtioGPURendererHealthFault.resourceRetirementFailed(
                        resourceID: resourceID,
                        generation: generation,
                        detail: String(describing: error)
                    )
                    failRendererLifecycle(fault)
                    FileHandle.standardError.write(Data((
                        "dory-gpu: renderer retirement failed resource=\(resourceID) "
                            + "generation=\(generation): \(error)\n"
                    ).utf8))
                }
            }
        }
    }

    private func scheduleQuiescenceCleanupIfReady() {
        let epoch: UInt64? = lifecycleLock.withLock {
            guard var active = activeQuiescence,
                  !active.cleanupScheduled,
                  active.awaitingReleaseAcknowledgements.isEmpty,
                  active.priorRetirements.allSatisfy({ key in
                      retiringResources[key.resourceID] != key.generation
                  }) else { return nil }
            active.cleanupScheduled = true
            activeQuiescence = active
            return active.receipt.epoch
        }
        guard let epoch else { return }
        rendererRetirementQueue.async { [self] in
            finishQuiescence(epoch: epoch)
        }
    }

    private func acknowledgeQuiescenceRelease(
        _ key: ResourceRetirementKey,
        epoch: UInt64
    ) {
        lifecycleLock.withLock {
            guard var active = activeQuiescence, active.receipt.epoch == epoch else { return }
            active.awaitingReleaseAcknowledgements.remove(key)
            activeQuiescence = active
        }
        scheduleQuiescenceCleanupIfReady()
    }

    private func finishQuiescence(epoch: UInt64) {
        guard let active = lifecycleLock.withLock({
            activeQuiescence?.receipt.epoch == epoch ? activeQuiescence : nil
        }) else { return }

        var firstFault: VirtioGPURendererHealthFault?
        for resource in active.rendererResources.sorted(by: {
            ($0.key.resourceID, $0.key.generation) < ($1.key.resourceID, $1.key.generation)
        }) {
            do {
                if resource.requiresBlobUnmap, rendererExecutor != nil {
                    _ = try executeRendererCommand(
                        .unmapBlob(resourceID: resource.key.resourceID),
                        generation: active.rendererGeneration,
                        purpose: .retirement
                    )
                }
                if rendererExecutor != nil {
                    _ = try executeRendererCommand(
                        .unrefResource(resourceID: resource.key.resourceID),
                        generation: active.rendererGeneration,
                        purpose: .retirement
                    )
                }
                lifecycleLock.withLock {
                    if retiringResources[resource.key.resourceID] == resource.key.generation {
                        retiringResources.removeValue(forKey: resource.key.resourceID)
                    }
                }
            } catch {
                if firstFault == nil {
                    firstFault = .resourceRetirementFailed(
                        resourceID: resource.key.resourceID,
                        generation: resource.key.generation,
                        detail: String(describing: error)
                    )
                }
            }
        }
        if let firstFault {
            failRendererLifecycle(firstFault, epoch: epoch)
            return
        }

        if rendererExecutor != nil {
            do {
                let reset = try executeRendererCommand(
                    .resetAfterDeviceQuiesce(successorGeneration: epoch),
                    generation: active.rendererGeneration,
                    purpose: .retirement
                )
                guard case .reset(let result) = reset else {
                    preconditionFailure("renderer reset returned an invalid executor payload")
                }
                if case .requiresRecreation(let detail) = result {
                    failRendererLifecycle(.resetRequiresRecreation(detail), epoch: epoch)
                    return
                }
            } catch let signal as RendererCommandOutcomeUnknownSignal {
                failRendererLifecycle(
                    .resetFailed(signal.uncertainty.detail),
                    epoch: epoch
                )
                return
            } catch {
                failRendererLifecycle(.resetFailed(String(describing: error)), epoch: epoch)
                return
            }
        }

        let workerCannotResumeAfterReset = active.receipt.reason == .deviceReset
            && rendererWorkerCandidate != nil
            && !active.workerReboundForPristineDeviceReset
        if active.receipt.reason == .deviceReset, !workerCannotResumeAfterReset {
            fenceLock.withLock {
                // resetAfterDeviceQuiesce() is the renderer-owned barrier that makes every old
                // callback permanently unreachable. Only this boundary can safely reopen fenced
                // admission after a QueueReady revocation or fence-registration uncertainty.
                fenceAdmissionBlockedUntilDeviceReset = false
            }
        }

        let receipt: VirtioGPUQuiescence? = lifecycleLock.withLock {
            guard activeQuiescence?.receipt.epoch == epoch else { return nil }
            let receipt = activeQuiescence?.receipt
            activeQuiescence = nil
            let workerIsReady = active.receipt.reason == .deviceReset
                && active.workerReboundForPristineDeviceReset
            rendererLifecycleHealthState = rendererExecutor != nil || workerIsReady
                ? .ready(epoch: epoch)
                : .notConfigured
            acceptingGuestCommands = active.receipt.reason == .deviceReset
                && !workerCannotResumeAfterReset
            return receipt
        }
        receipt?.complete(.completed)
        if workerCannotResumeAfterReset {
            onRendererWorkerFailure?(
                "virtio-gpu device reset revoked the one-shot renderer generation"
            )
        }
    }

    private func failRendererLifecycle(
        _ fault: VirtioGPURendererHealthFault,
        epoch requestedEpoch: UInt64? = nil
    ) {
        let currentEpoch = fenceLock.withLock { lifecycleEpoch }
        let epoch = requestedEpoch ?? currentEpoch
        let receipt: VirtioGPUQuiescence? = lifecycleLock.withLock {
            rendererLifecycleHealthState = !rendererAuthorityIsConfigured
                ? .notConfigured
                : .failed(epoch: epoch, fault: fault)
            acceptingGuestCommands = false
            guard activeQuiescence?.receipt.epoch == epoch else { return nil }
            let receipt = activeQuiescence?.receipt
            activeQuiescence = nil
            return receipt
        }
        receipt?.complete(.failed(fault))
    }

    private func publishResourceRelease(
        resourceID: UInt32,
        generation: UInt64,
        completion: @escaping @Sendable () -> Void
    ) {
        let release = VirtioGPUScanoutResourceRelease(
            resourceID: resourceID,
            resourceGeneration: generation,
            scanoutCount: scanoutCount,
            completion: completion
        )
        if let onScanoutResourceReleased {
            onScanoutResourceReleased(release)
            if scanoutCount == 0 { release.acknowledgeAll() }
        } else {
            release.acknowledgeAll()
        }
    }

    private func process(
        request: [UInt8],
        cursorQueue: Bool,
        transport: VirtioMMIOTransport
    ) -> CommandProcessingOutcome {
        do {
            return .response(try processResponse(
                request: request,
                cursorQueue: cursorQueue,
                transport: transport
            ))
        } catch let signal as RendererCommandOutcomeUnknownSignal {
            return .outcomeUnknown(signal.uncertainty)
        } catch {
            logCommandFailure(request: request, error: error)
            return .response(responseHeader(
                type: Response.errorInvalidParameter,
                request: request
            ))
        }
    }

    private func processResponse(
        request: [UInt8],
        cursorQueue: Bool,
        transport: VirtioMMIOTransport
    ) throws -> [UInt8] {
        guard request.count >= 4 else {
            return responseHeader(type: Response.errorUnspecified, request: request)
        }

        let command = request.leUInt32(at: 0)
        let acceptsCommand = lifecycleLock.withLock { acceptingGuestCommands }
        if !acceptsCommand,
           command != Command.getDisplayInfo,
           command != Command.getCapsetInfo,
           command != Command.getCapset {
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
        if cursorQueue {
            return try cursorCommand(command, request: request)
        }

        if rendererAuthorityIsConfigured,
           command != Command.getDisplayInfo,
           command != Command.getCapsetInfo,
           command != Command.getCapset,
           !rendererLifecycleIsReady {
            let health = rendererLifecycleHealth
            let error = VMError.invalidConfiguration(
                "virtio-gpu renderer lifecycle is not ready: \(health)"
            )
            logCommandFailure(request: request, error: error)
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }

        switch command {
        case Command.getDisplayInfo:
            displayLock.lock()
            let sizes = scanoutSizes
            displayLock.unlock()
            var response = responseHeader(type: Response.okDisplayInfo, request: request)
            for index in 0..<16 {
                let size = sizes.indices.contains(index) ? sizes[index] : nil
                response.appendLE(UInt32(0))
                response.appendLE(UInt32(0))
                response.appendLE(size?.width ?? 0)
                response.appendLE(size?.height ?? 0)
                response.appendLE(size == nil ? UInt32(0) : UInt32(1))
                response.appendLE(UInt32(0))
            }
            return response
        case Command.resourceCreate2D:
            return try scanoutCommand(request: request) {
                try requireLength(request, 40)
                let resourceID = request.leUInt32(at: 24)
                let format = request.leUInt32(at: 28)
                let width = request.leUInt32(at: 32)
                let height = request.leUInt32(at: 36)
                guard resourceID != 0,
                      canAdmitResource(resourceID),
                      width > 0, height > 0,
                      width <= 16_384, height <= 16_384,
                      Self.isSupportedScanoutFormat(format),
                      let copiedByteCount = Self.rgbaByteCount(width: width, height: height),
                      copiedByteCount <= maximumCopiedScanoutSurfaceBytes else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu 2D resource")
                }
                // VirGL clients may use a RESOURCE_CREATE_2D allocation as a texture after
                // attaching it to a renderer context. Keep the renderer's global resource table in
                // lockstep with the device-side scanout table, matching QEMU's virgl path. Without
                // this registration virgl_renderer_ctx_attach_resource silently ignores the ID and
                // a later sampler-view creation fails as an illegal resource.
                if rendererExecutor != nil {
                    _ = try executeRendererCommand(.createResource3D(
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
                    ))
                }
                resources2D[resourceID] = Resource2D(
                    format: format,
                    width: width,
                    height: height
                )
                registerResourceGeneration(resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.setScanout:
            return try scanoutCommand(request: request) {
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
                    if let previous, case .blob = previous.source, rendererExecutor != nil {
                        try releaseBlobMappingIfUnused(resourceID: previous.resourceID)
                    }
                    onScanoutDisabled?(scanoutID)
                    return responseHeader(type: Response.okNoData, request: request)
                }
                let rect = try scanoutRect(from: request, at: 24)
                let source: ScanoutBinding.Source
                var preparedPresentation: VirtioGPUTexturePresentation?
                defer {
                    // Until ownership is transferred to `publishBoundScanout`, every error path
                    // must explicitly retire the producer-completion authority.
                    preparedPresentation?.discardWithoutPresentation()
                }
                let resourceWidth: UInt32
                let resourceHeight: UInt32
                if let resource = resources2D[resourceID] {
                    source = .resource2D
                    resourceWidth = resource.width
                    resourceHeight = resource.height
                    if rendererWorkerCandidate != nil {
                        guard rendererWorkerResourceGenerations[resourceID] != nil,
                              Self.rendererWorkerScanoutFormat(resource.format) != nil,
                              onMetalScanout != nil else {
                            throw VMError.invalidConfiguration(
                                "virtio-gpu renderer worker scanout is unavailable"
                            )
                        }
                    }
                } else if let resource = resources3D[resourceID] {
                    source = .resource3D
                    resourceWidth = resource.width
                    resourceHeight = resource.height
                    if rendererWorkerCandidate != nil {
                        guard rendererWorkerResourceGenerations[resourceID] != nil,
                              Self.rendererWorkerScanoutFormat(resource.format) != nil,
                              onMetalScanout != nil else {
                            throw VMError.invalidConfiguration(
                                "virtio-gpu renderer worker scanout is unavailable"
                            )
                        }
                    } else {
                        guard rendererExecutor != nil,
                              let generation = resourceGenerations[resourceID] else {
                            throw VMError.invalidConfiguration(
                                "virtio-gpu renderer is unavailable"
                            )
                        }
                        let result = try executeRendererCommand(.makeScanoutPresentation(
                            resourceID: resourceID,
                            resourceGeneration: generation
                        ))
                        guard case .scanoutPresentation(let presentation) = result else {
                            preconditionFailure(
                                "make-scanout-presentation returned an invalid payload"
                            )
                        }
                        let texture = presentation.texture
                        guard presentation.resourceID == resourceID,
                              presentation.resourceGeneration == generation,
                              texture.textureID != 0,
                              texture.format == resource.format,
                              texture.width == resource.width,
                              texture.height == resource.height else {
                            presentation.discardWithoutPresentation()
                            throw VMError.invalidConfiguration(
                                "virtio-gpu renderer returned inconsistent scanout texture authority"
                            )
                        }
                        preparedPresentation = presentation
                    }
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
                if let previous, case .blob = previous.source, rendererExecutor != nil {
                    try releaseBlobMappingIfUnused(resourceID: previous.resourceID)
                }
                if rendererWorkerCandidate != nil,
                   rendererWorkerResourceGenerations[resourceID] != nil {
                    // Worker-backed 2D and VirGL2 resources become visible only after
                    // RESOURCE_FLUSH acquires a producer-complete native Metal texture lease.
                    // SET_SCANOUT records geometry but must retain the last completed frame until
                    // that flush arrives. Treating this transient binding change like the
                    // resource_id=0 disable above makes compositors that rotate scanout buffers
                    // flash the host clear color between every SET_SCANOUT and RESOURCE_FLUSH.
                    return responseHeader(type: Response.okNoData, request: request)
                }
                let presentationToPublish = preparedPresentation
                preparedPresentation = nil
                try publishBoundScanout(
                    scanoutID: scanoutID,
                    preparedPresentation: presentationToPublish
                )
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferToHost2D:
            return try scanoutCommand(request: request) {
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
            return try scanoutCommand(request: request) {
                try requireLength(request, 48)
                let rect = try scanoutRect(from: request, at: 24)
                let resourceID = request.leUInt32(at: 40)
                if let resource = resources2D[resourceID] {
                    guard Self.contains(rect: rect, width: resource.width, height: resource.height) else {
                        throw VMError.invalidConfiguration("invalid virtio-gpu resource flush")
                    }
                    try publishScanoutFrames(
                        resourceID: resourceID,
                        resource: resource,
                        dirtyRect: rect
                    )
                } else if let resource = resources3D[resourceID] {
                    guard Self.contains(rect: rect, width: resource.width, height: resource.height) else {
                        throw VMError.invalidConfiguration("invalid virtio-gpu 3D resource flush")
                    }
                    guard rendererExecutor != nil else {
                        throw VMError.invalidConfiguration("virtio-gpu renderer is unavailable")
                    }
                    try publishRendererDamage(resourceID: resourceID, dirtyRect: rect)
                } else {
                    guard let blob = blobResources[resourceID] else {
                        throw VMError.invalidConfiguration("invalid virtio-gpu resource flush")
                    }
                    try publishBlobScanoutFrames(
                        resourceID: resourceID,
                        blob: blob,
                        dirtyRect: rect
                    )
                }
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.getCapsetInfo:
            return capsetInfoResponse(request: request)
        case Command.getCapset:
            return capsetResponse(request: request)
        case Command.resourceAssignUUID:
            return try scanoutCommand(request: request) {
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
            return try scanoutCommand(request: request) {
                guard request.count >= 96 else { throw VMError.unexpectedExit("short virtio-gpu ctx_create") }
                let contextID = request.leUInt32(at: 16)
                let nameLength = min(Int(request.leUInt32(at: 24)), 64)
                let contextInit = request.leUInt32(at: 28)
                let nameBytes = request[32..<(32 + nameLength)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                _ = try executeRendererCommand(.createContext(
                    id: contextID,
                    flags: Self.rendererContextFlags(requested: contextInit, capsets: capsets),
                    name: name
                ))
                createdContextIDs.insert(contextID)
                traceResourceEvent("context-create", contextID: contextID, detail: "name=\(name) init=0x\(String(contextInit, radix: 16))")
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDestroy:
            return try scanoutCommand(request: request) {
                let contextID = request.leUInt32(at: 16)
                _ = try executeRendererCommand(.destroyContext(id: contextID))
                createdContextIDs.remove(contextID)
                traceResourceEvent("context-destroy", contextID: contextID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxAttachResource:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let contextID = request.leUInt32(at: 16)
                let resourceID = request.leUInt32(at: 24)
                traceResourceEvent("attach-begin", contextID: contextID, resourceID: resourceID)
                if rendererWorkerCandidate != nil,
                   rendererWorkerResourceGenerations[resourceID] == nil {
                    guard createdContextIDs.contains(contextID),
                          resources2D[resourceID] != nil else {
                        throw VMError.invalidConfiguration(
                            "invalid local virtio-gpu context attachment"
                        )
                    }
                    traceResourceEvent(
                        "attach-end",
                        contextID: contextID,
                        resourceID: resourceID,
                        detail: "authority=local-2d"
                    )
                    return responseHeader(type: Response.okNoData, request: request)
                }
                _ = try executeRendererCommand(.attachResource(
                    contextID: contextID,
                    resourceID: resourceID
                ))
                traceResourceEvent("attach-end", contextID: contextID, resourceID: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.ctxDetachResource:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let contextID = request.leUInt32(at: 16)
                let resourceID = request.leUInt32(at: 24)
                if rendererWorkerCandidate != nil,
                   rendererWorkerResourceGenerations[resourceID] == nil {
                    guard createdContextIDs.contains(contextID),
                          resources2D[resourceID] != nil else {
                        throw VMError.invalidConfiguration(
                            "invalid local virtio-gpu context detachment"
                        )
                    }
                    traceResourceEvent(
                        "detach",
                        contextID: contextID,
                        resourceID: resourceID,
                        detail: "authority=local-2d"
                    )
                    return responseHeader(type: Response.okNoData, request: request)
                }
                _ = try executeRendererCommand(.detachResource(
                    contextID: contextID,
                    resourceID: resourceID
                ))
                traceResourceEvent("detach", contextID: contextID, resourceID: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.submit3D:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let size = Int(request.leUInt32(at: 24))
                let (end, overflow) = 32.addingReportingOverflow(size)
                guard !overflow, end <= request.count else {
                    throw VMError.unexpectedExit("short virtio-gpu submit_3d")
                }
                _ = try executeRendererCommand(.submit3D(
                    contextID: request.leUInt32(at: 16),
                    command: Array(request[32..<end])
                ))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreate3D:
            return try scanoutCommand(request: request) {
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
                      canAdmitResource(resource.resourceID) else {
                    throw VMError.invalidConfiguration("invalid virtio-gpu 3D resource")
                }
                _ = try executeRendererCommand(.createResource3D(
                    resource,
                    entries: resourceEntries[resource.resourceID] ?? []
                ))
                resources3D[resource.resourceID] = Resource3D(
                    format: resource.format,
                    width: resource.width,
                    height: resource.height
                )
                registerResourceGeneration(resource.resourceID)
                traceResourceEvent("create-3d", contextID: request.leUInt32(at: 16), resourceID: resource.resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceAttachBacking:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                let entries = try memoryEntries(from: request, count: request.leUInt32(at: 28), offset: 32, transport: transport)
                if var resource = resources2D[resourceID] {
                    if rendererExecutor != nil {
                        _ = try executeRendererCommand(.attachBacking(
                            resourceID: resourceID,
                            entries: entries
                        ))
                    }
                    resource.backing = entries
                    resources2D[resourceID] = resource
                    return responseHeader(type: Response.okNoData, request: request)
                }
                resourceEntries[resourceID] = entries
                _ = try executeRendererCommand(.attachBacking(
                    resourceID: resourceID,
                    entries: entries
                ))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceDetachBacking:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                if cursorResourceID == resourceID {
                    cursorResourceID = nil
                    onCursorUpdate?(nil)
                }
                if var resource = resources2D[resourceID] {
                    if rendererExecutor != nil {
                        _ = try executeRendererCommand(.detachBacking(resourceID: resourceID))
                    }
                    resource.backing = []
                    resources2D[resourceID] = resource
                    return responseHeader(type: Response.okNoData, request: request)
                }
                _ = try executeRendererCommand(.detachBacking(resourceID: resourceID))
                resourceEntries.removeValue(forKey: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceCreateBlob:
            return try scanoutCommand(request: request) {
                try requireLength(request, 56)
                let resourceID = request.leUInt32(at: 24)
                let size = request.leUInt64(at: 48)
                let resourceAvailable = canAdmitResource(resourceID)
                guard resourceID != 0,
                      size > 0,
                      size <= UInt64(Int.max),
                      size <= maximumRendererReferencedBytes,
                      resourceAvailable else {
                    throw VMError.invalidConfiguration(
                        "invalid virtio-gpu blob resource "
                            + "(id=\(resourceID) size=\(size) "
                            + "available=\(resourceAvailable))"
                    )
                }
                let entries = try memoryEntries(from: request, count: request.leUInt32(at: 36), offset: 56, transport: transport)
                _ = try executeRendererCommand(.createBlob(
                    resourceID: resourceID,
                    contextID: request.leUInt32(at: 16),
                    blobMemory: request.leUInt32(at: 28),
                    blobFlags: request.leUInt32(at: 32),
                    blobID: request.leUInt64(at: 40),
                    size: size,
                    entries: entries
                ))
                resourceEntries[resourceID] = entries
                blobResources[resourceID] = BlobResource(
                    memory: request.leUInt32(at: 28),
                    size: size,
                    mapping: nil,
                    workerMapping: nil
                )
                registerResourceGeneration(resourceID)
                traceResourceEvent(
                    "create-blob",
                    contextID: request.leUInt32(at: 16),
                    resourceID: resourceID,
                    detail: "memory=\(request.leUInt32(at: 28)) blob=\(request.leUInt64(at: 40)) size=\(size)"
                )
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceMapBlob:
            return try scanoutCommand(request: request) {
                try requireLength(request, 40)
                let resourceID = request.leUInt32(at: 24)
                let offset = request.leUInt64(at: 32)
                guard let blob = blobResources[resourceID], let hostVisibleMemory else {
                    FileHandle.standardError.write(Data("dory-gpu: mapBlob res=\(resourceID) missing blob/window\n".utf8))
                    throw VMError.invalidConfiguration("virtio-gpu blob map without host-visible window")
                }
                // virglrenderer owns the blob's host memory; ask it to map, then expose that pointer to
                // the guest by hv_vm_mapping it into the window at the requested offset.
                let mapping = try ensureBlobMapping(resourceID: resourceID)
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
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                hostVisibleMemory?.unmap(resourceID: resourceID)
                guard var blob = blobResources[resourceID] else {
                    throw VMError.invalidConfiguration("virtio-gpu unmap of unknown blob")
                }
                blob.guestMapped = false
                blobResources[resourceID] = blob
                try releaseBlobMappingIfUnused(resourceID: resourceID)
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.resourceUnref:
            return try scanoutCommand(request: request) {
                try requireLength(request, 32)
                let resourceID = request.leUInt32(at: 24)
                let generation = resourceGenerations[resourceID] ?? 0
                let removed2D = resources2D.removeValue(forKey: resourceID)
                let removed3D = resources3D.removeValue(forKey: resourceID)
                let removedBlob = blobResources.removeValue(forKey: resourceID)
                guard removed2D != nil || removed3D != nil || removedBlob != nil else {
                    throw VMError.invalidConfiguration(
                        "virtio-gpu unref of unknown or retiring resource \(resourceID)"
                    )
                }
                if cursorResourceID == resourceID {
                    cursorResourceID = nil
                    onCursorUpdate?(nil)
                }
                resourceUUIDs.removeValue(forKey: resourceID)
                traceResourceEvent("unref-begin", contextID: request.leUInt32(at: 16), resourceID: resourceID)
                hostVisibleMemory?.unmap(resourceID: resourceID)
                scanouts = scanouts.filter { $0.value.resourceID != resourceID }
                resourceEntries.removeValue(forKey: resourceID)
                resourceGenerations.removeValue(forKey: resourceID)
                beginResourceRetirement(
                    resourceID: resourceID,
                    generation: generation,
                    requiresBlobUnmap: removedBlob?.mapping?.requiresRendererUnmap == true,
                    rendererGeneration: fenceLock.withLock { lifecycleEpoch }
                )
                let kind = removed2D != nil ? "2d" : (removed3D != nil ? "3d" : "blob")
                traceResourceEvent("unref-guest-retired", resourceID: resourceID, detail: "kind=\(kind)")
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferToHost3D:
            return try scanoutCommand(request: request) {
                let transfer = try transfer3D(from: request)
                _ = try executeRendererCommand(.transferToHost3D(
                    transfer,
                    entries: resourceEntries[transfer.resourceID] ?? []
                ))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.transferFromHost3D:
            return try scanoutCommand(request: request) {
                let transfer = try transfer3D(from: request)
                _ = try executeRendererCommand(.transferFromHost3D(
                    transfer,
                    entries: resourceEntries[transfer.resourceID] ?? []
                ))
                return responseHeader(type: Response.okNoData, request: request)
            }
        case Command.setScanoutBlob:
            return try scanoutCommand(request: request) {
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
                    if let previous, case .blob = previous.source, rendererExecutor != nil {
                        try releaseBlobMappingIfUnused(resourceID: previous.resourceID)
                    }
                    onScanoutDisabled?(scanoutID)
                    return responseHeader(type: Response.okNoData, request: request)
                }
                let rect = try scanoutRect(from: request, at: 24)
                let workerBacked = rendererWorkerResourceGenerations[resourceID] != nil
                guard let blob = blobResources[resourceID],
                      width > 0, height > 0,
                      width <= 16_384, height <= 16_384,
                      Self.isSupportedScanoutFormat(format),
                      !workerBacked || Self.rendererWorkerScanoutFormat(format) != nil,
                      !workerBacked || onMetalScanout != nil,
                      Self.contains(rect: rect, width: width, height: height),
                      stride >= width * 4,
                      let copiedByteCount = Self.rgbaByteCount(width: width, height: height),
                      copiedByteCount <= maximumCopiedScanoutSurfaceBytes,
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
                   rendererExecutor != nil {
                    try releaseBlobMappingIfUnused(resourceID: previous.resourceID)
                }
                if workerBacked {
                    // The producer is renderer-owned HOST3D SHM. SET_SCANOUT_BLOB establishes
                    // geometry only; RESOURCE_FLUSH acquires the exact worker layout plus its
                    // context-timeline fence before any Metal consumer can observe the bytes.
                    onScanoutDisabled?(scanoutID)
                    return responseHeader(type: Response.okNoData, request: request)
                }
                try publishBlobScanoutFrames(
                    resourceID: resourceID,
                    blob: blob,
                    dirtyRect: rect
                )
                return responseHeader(type: Response.okNoData, request: request)
            }
        default:
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    private func capsetInfoResponse(request: [UInt8]) -> [UInt8] {
        guard request.count >= 32 else { return responseHeader(type: Response.errorInvalidParameter, request: request) }
        guard rendererCapabilitiesAreAdvertised else {
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
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
        guard rendererCapabilitiesAreAdvertised else {
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
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

    private func executeRendererCommand(
        _ command: VirtioGPURendererCommand,
        generation explicitGeneration: UInt64? = nil,
        purpose: VirtioGPURendererCommandPurpose = .guest
    ) throws -> VirtioGPURendererCommandValue {
        guard let rendererExecutor else {
            throw VMError.invalidConfiguration("virtio-gpu renderer is unavailable")
        }
        let generation = explicitGeneration ?? fenceLock.withLock { lifecycleEpoch }
        switch rendererExecutor.execute(
            command,
            generation: generation,
            purpose: purpose
        ) {
        case .success(let value):
            return value
        case .rejected(let rejection):
            throw VirtioGPURendererCommandRejected(String(describing: rejection))
        case .outcomeUnknown(let uncertainty):
            recordTelemetry(.rendererCommandUncertainty)
            if let failure = uncertainty.runtimeFailure {
                recordRendererFailure(failure, generation: uncertainty.generation)
            }
            failRendererLifecycle(
                .commandOutcomeUnknown(
                    operation: uncertainty.operation,
                    detail: uncertainty.detail
                ),
                epoch: uncertainty.generation
            )
            throw RendererCommandOutcomeUnknownSignal(uncertainty: uncertainty)
        }
    }

    private var rendererLifecycleIsReady: Bool {
        lifecycleLock.withLock {
            if case .ready = rendererLifecycleHealthState { return true }
            return !rendererAuthorityIsConfigured
        }
    }

    private var rendererAuthorityIsConfigured: Bool {
        rendererExecutor != nil || rendererWorkerCandidate != nil
    }

    /// Feature and capset discovery is guest-visible state, so it must close with command
    /// admission. In particular, successful shutdown and a renderer that requires recreation are
    /// both quarantined rather than masquerading as a newly usable renderer epoch.
    private var rendererCapabilitiesAreAdvertised: Bool {
        lifecycleLock.withLock {
            guard acceptingGuestCommands else { return false }
            if case .ready = rendererLifecycleHealthState { return true }
            return false
        }
    }

    private func scanoutCommand(
        request: [UInt8],
        _ body: () throws -> [UInt8]
    ) throws -> [UInt8] {
        do {
            return try body()
        } catch let signal as RendererCommandOutcomeUnknownSignal {
            throw signal
        } catch {
            recordRendererFailure(error)
            logCommandFailure(request: request, error: error)
            return responseHeader(type: Response.errorInvalidParameter, request: request)
        }
    }

    private func recordRendererFailure(
        _ error: Error,
        generation: UInt64? = nil
    ) {
        if let generation,
           fenceLock.withLock({ lifecycleEpoch != generation }) {
            return
        }
        fenceLock.withLock { recordRendererFailureWhileLocked(error) }
    }

    private func recordRendererFailureWhileLocked(_ error: Error) {
        guard let failure = error as? VirtioGPURendererRuntimeFailure,
              case .deviceLost = failure,
              !rendererDeviceLossLatched else { return }
        rendererDeviceLossLatched = true
        rendererDeviceLossCount = Self.saturatingAdd(rendererDeviceLossCount, 1)
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

    /// A malformed compositor can repeat RESOURCE_FLUSH indefinitely. Keep the exact failure
    /// boundary needed for physical qualification while emitting at most one line per resource
    /// and stage for the current device generation.
    private func logRendererWorkerScanoutFailure(
        resourceID: UInt32,
        stage: String,
        detail: String = ""
    ) {
        let key = "\(resourceID):\(stage)"
        let firstOccurrence = rendererWorkerScanoutDiagnosticLock.withLock {
            rendererWorkerScanoutDiagnosticStages.insert(key).inserted
        }
        guard firstOccurrence else { return }
        let suffix = detail.isEmpty ? "" : " detail=\(detail)"
        FileHandle.standardError.write(Data(
            "dory-gpu: worker scanout resource=\(resourceID) stage=\(stage)\(suffix)\n".utf8
        ))
    }

    /// Physical qualification crosses the renderer lane, its presentation queue, AppKit, and
    /// Metal. Emit each ownership handoff once per resource and device generation so a stalled
    /// frame has an exact last-known stage without turning the production frame loop into logging.
    private func logRendererWorkerScanoutProgress(
        resourceID: UInt32,
        stage: String
    ) {
        let key = "progress:\(resourceID):\(stage)"
        let firstOccurrence = rendererWorkerScanoutDiagnosticLock.withLock {
            rendererWorkerScanoutDiagnosticStages.insert(key).inserted
        }
        guard firstOccurrence else { return }
        FileHandle.standardError.write(Data(
            "dory-gpu: worker scanout progress resource=\(resourceID) stage=\(stage)\n".utf8
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

    /// Alpha and X variants have identical byte/channel layout. The KMS wire format describes
    /// whether scanout consumes the high byte, while Venus reports the Vulkan resource's alpha
    /// format. Normalize only that semantic padding bit before authenticating the renderer-owned
    /// allocation; every other virtio format remains outside the zero-copy Metal contract.
    private static func rendererWorkerScanoutFormat(_ format: UInt32) -> UInt32? {
        switch format {
        case 1, 2: 1
        case 67, 68: 67
        default: nil
        }
    }

    /// Resolves the one renderer request layout accepted for a bound worker resource. VirGL2
    /// resource3D scanout is a tightly packed native texture; Venus HOST3D blob scanout retains
    /// its authenticated linear layout. Admission and post-XPC publication both use this exact
    /// projection so they cannot disagree about the surface being presented.
    private func rendererWorkerScanoutSurface(
        for binding: ScanoutBinding
    ) -> WorkerScanoutSurface? {
        switch binding.source {
        case .resource2D:
            guard rendererWorkerResourceGenerations[binding.resourceID] != nil,
                  let resource = resources2D[binding.resourceID],
                  let format = Self.rendererWorkerScanoutFormat(resource.format) else {
                return nil
            }
            let (stride, overflow) = resource.width.multipliedReportingOverflow(by: 4)
            guard !overflow else { return nil }
            return WorkerScanoutSurface(
                width: resource.width,
                height: resource.height,
                format: format,
                stride: stride,
                offset: 0
            )
        case .resource3D:
            guard let resource = resources3D[binding.resourceID],
                  let format = Self.rendererWorkerScanoutFormat(resource.format) else {
                return nil
            }
            let (stride, overflow) = resource.width.multipliedReportingOverflow(by: 4)
            guard !overflow else { return nil }
            return WorkerScanoutSurface(
                width: resource.width,
                height: resource.height,
                format: format,
                stride: stride,
                offset: 0
            )
        case .blob(let format, let width, let height, let stride, let offset):
            guard let rendererFormat = Self.rendererWorkerScanoutFormat(format) else {
                return nil
            }
            return WorkerScanoutSurface(
                width: width,
                height: height,
                format: rendererFormat,
                stride: stride,
                offset: offset
            )
        }
    }

    private static func rendererWorkerScanoutTransportMatches(
        _ scanout: DoryRendererWorkerScanoutAuthority,
        surface: WorkerScanoutSurface
    ) -> Bool {
        switch scanout {
        case .sharedMemory(let value):
            return value.lease.stride == surface.stride
                && value.lease.storageOffset == UInt64(surface.offset)
        case .sharedTexture:
            let (expectedStride, overflow) = surface.width.multipliedReportingOverflow(by: 4)
            return !overflow && surface.stride == expectedStride && surface.offset == 0
        }
    }

    private static func rendererWorkerScanoutDescription(
        _ scanout: DoryRendererWorkerScanoutAuthority
    ) -> String {
        switch scanout {
        case .sharedMemory(let value):
            return "shm/\(value.lease.width)x\(value.lease.height)/"
                + "\(value.lease.pixelFormat.rawValue)/\(value.lease.stride)/"
                + "\(value.lease.storageOffset)"
        case .sharedTexture(let value):
            return "metal/\(value.lease.width)x\(value.lease.height)/"
                + "\(value.lease.pixelFormat.rawValue)"
        }
    }

    private static func rgbaByteCount(width: UInt32, height: UInt32) -> UInt64? {
        let (pixels, pixelOverflow) = UInt64(width).multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? nil : bytes
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

    private func cursorCommand(_ command: UInt32, request: [UInt8]) throws -> [UInt8] {
        try scanoutCommand(request: request) {
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
            let resource = try copiedCursorResource(resourceID: resourceID)
            let hotX = request.leUInt32(at: 44)
            let hotY = request.leUInt32(at: 48)
            guard hotX < resource.width, hotY < resource.height else {
                throw VMError.invalidConfiguration("virtio-gpu cursor hotspot is outside the image")
            }
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
                bytes: resource.bytes
            ))
            return responseHeader(type: Response.okNoData, request: request)
        }
    }

    private func copiedCursorResource(resourceID: UInt32) throws -> CursorResourceSnapshot {
        if let resource = resources2D[resourceID] {
            try validateCursorResource(
                format: resource.format,
                width: resource.width,
                height: resource.height
            )
            return CursorResourceSnapshot(
                width: resource.width,
                height: resource.height,
                bytes: try copiedBytes(for: resource)
            )
        }

        if rendererWorkerResourceGenerations[resourceID] != nil,
           resources3D[resourceID] != nil {
            // A private worker Metal texture is not CPU-readable authority. Until an explicit
            // asynchronous worker readback contract exists, fail the cursor update instead of
            // acknowledging a stale or fabricated local copy.
            throw VMError.invalidConfiguration(
                "virtio-gpu worker 3D cursor requires authenticated readback"
            )
        }

        guard let resource = resources3D[resourceID], rendererExecutor != nil else {
            throw VMError.invalidConfiguration(
                "virtio-gpu cursor references an unknown resource"
            )
        }
        try validateCursorResource(
            format: resource.format,
            width: resource.width,
            height: resource.height
        )
        let stride = UInt64(resource.width) * 4
        let byteCount = stride * UInt64(resource.height)
        guard stride <= UInt64(UInt32.max), byteCount <= UInt64(Int.max) else {
            throw VMError.invalidConfiguration("virtio-gpu cursor resource is too large")
        }
        var pixels = Data(count: Int(byteCount))
        try pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw VMError.invalidConfiguration("virtio-gpu 3D cursor has no storage")
            }
            _ = try executeRendererCommand(.transferFromHost3D(
                VirtioGPUTransfer3D(
                    resourceID: resourceID,
                    contextID: 0,
                    level: 0,
                    stride: UInt32(stride),
                    layerStride: 0,
                    offset: 0,
                    box: [0, 0, 0, resource.width, resource.height, 1]
                ),
                entries: [VirtioGPUMemoryEntry(pointer: baseAddress, length: bytes.count)]
            ))
        }
        return CursorResourceSnapshot(
            width: resource.width,
            height: resource.height,
            bytes: pixels
        )
    }

    private func validateCursorResource(format: UInt32, width: UInt32, height: UInt32) throws {
        // Linux normally advertises ARGB8888 for the cursor plane, but accelerated Mutter creates
        // the 64x64 VirGL cursor resource as B8G8R8X8 and still writes ARGB cursor payload bytes.
        // QEMU's VirGL cursor path intentionally copies that payload without format conversion.
        guard format == 1 || format == 2,
              width > 0, height > 0,
              width <= 256, height <= 256 else {
            throw VMError.invalidConfiguration(
                "virtio-gpu cursor requires a bounded BGRA/BGRX resource "
                    + "(format=\(format) size=\(width)x\(height))"
            )
        }
    }

    /// Cursor snapshots are explicitly bounded to 256×256 and require a complete image. Display
    /// damage does not use this full-resource helper; it is extracted directly below.
    private func copiedBytes(for resource: Resource2D) throws -> Data {
        guard let byteCount = Self.rgbaByteCount(
            width: resource.width,
            height: resource.height
        ), byteCount <= UInt64(Int.max) else {
            throw VMError.invalidConfiguration("virtio-gpu 2D backing is too large")
        }
        return try copyBackingRange(
            entries: resource.backing,
            offset: 0,
            count: Int(byteCount)
        )
    }

    /// Publishes one copied frame at a time. Returning an array here would keep every full-damage
    /// scanout copy alive until the batch completed (up to 16 × the per-frame ceiling).
    private func publishScanoutFrames(
        resourceID: UInt32,
        resource: Resource2D,
        dirtyRect: VirtioGPURect
    ) throws {
        guard let onScanoutFrame else { return }
        guard let requiredResourceBytes = Self.rgbaByteCount(
            width: resource.width,
            height: resource.height
        ), Self.backingCovers(
            resource.backing,
            byteCount: requiredResourceBytes
        ) else {
            throw VMError.invalidConfiguration("virtio-gpu 2D backing is incomplete")
        }
        let sourceStride = UInt64(resource.width) * 4
        for (scanoutID, binding) in scanouts.sorted(by: { $0.key < $1.key })
        where binding.resourceID == resourceID {
            guard case .resource2D = binding.source else { continue }
            guard let dirty = Self.intersection(dirtyRect, binding.rect) else { continue }
            let outputStride = Int(dirty.width) * 4
            var pixels = Data(capacity: outputStride * Int(dirty.height))
            for row in 0..<UInt64(dirty.height) {
                let sourceOffset = (UInt64(dirty.y) + row) * sourceStride
                    + UInt64(dirty.x) * 4
                pixels.append(try copyBackingRange(
                    entries: resource.backing,
                    offset: sourceOffset,
                    count: outputStride
                ))
            }
            softwareScanoutMetricsLock.withLock {
                softwareScanoutCopiedBytes = Self.saturatingAdd(
                    softwareScanoutCopiedBytes,
                    UInt64(pixels.count)
                )
            }
            onScanoutFrame(VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                resourceGeneration: resourceGenerations[resourceID] ?? 0,
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
    }

    private static func backingCovers(
        _ entries: [VirtioGPUMemoryEntry],
        byteCount: UInt64
    ) -> Bool {
        var total: UInt64 = 0
        for entry in entries {
            guard entry.length >= 0 else { return false }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.length))
            guard !overflow else { return false }
            total = next
            if total >= byteCount { return true }
        }
        return byteCount == 0
    }

    /// Blob scanouts are likewise streamed so the renderer/guest backing plus one output frame is
    /// the producer's maximum live copy, independent of the number of scanouts.
    private func publishBlobScanoutFrames(
        resourceID: UInt32,
        blob: BlobResource,
        dirtyRect: VirtioGPURect
    ) throws {
        let bindings = scanouts.sorted(by: { $0.key < $1.key }).compactMap {
            (scanoutID, binding) -> (UInt32, ScanoutBinding, UInt32, UInt32, UInt32, UInt32, UInt32)? in
            guard binding.resourceID == resourceID,
                  case let .blob(format, width, height, stride, offset) = binding.source else {
                return nil
            }
            return (scanoutID, binding, format, width, height, stride, offset)
        }
        guard !bindings.isEmpty else { return }

        let guestEntries = blob.memory == 1 ? (resourceEntries[resourceID] ?? []) : []
        let mapping: VirtioGPUBlobMapping?
        if guestEntries.isEmpty {
            guard rendererExecutor != nil else {
                throw VMError.invalidConfiguration("virtio-gpu blob scanout has no accessible backing")
            }
            mapping = try ensureBlobMapping(resourceID: resourceID)
        } else {
            mapping = nil
        }

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
            onScanoutFrame?(VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                resourceGeneration: resourceGenerations[resourceID] ?? 0,
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
    }

    /// Mirrors QEMU's VirGL scanout contract: bind the renderer's shared texture once, then treat
    /// RESOURCE_FLUSH as a redraw notification. No renderer readback, host framebuffer copy, or
    /// second GPU upload occurs on the accelerated path.
    private func publishBoundScanout(
        scanoutID: UInt32,
        preparedPresentation: VirtioGPUTexturePresentation? = nil
    ) throws {
        guard let binding = scanouts[scanoutID] else {
            preparedPresentation?.discardWithoutPresentation()
            return
        }
        switch binding.source {
        case .resource2D:
            preparedPresentation?.discardWithoutPresentation()
            guard let resource = resources2D[binding.resourceID] else {
                throw VMError.invalidConfiguration("virtio-gpu 2D scanout resource disappeared")
            }
            try publishScanoutFrames(
                resourceID: binding.resourceID,
                resource: resource,
                dirtyRect: binding.rect
            )
        case .resource3D:
            var ownedPresentation = preparedPresentation
            do {
                guard rendererExecutor != nil,
                      let generation = resourceGenerations[binding.resourceID] else {
                    throw VMError.invalidConfiguration(
                        "virtio-gpu 3D scanout generation disappeared"
                    )
                }
                if ownedPresentation == nil {
                    let result = try executeRendererCommand(.makeScanoutPresentation(
                        resourceID: binding.resourceID,
                        resourceGeneration: generation
                    ))
                    guard case .scanoutPresentation(let presentation) = result else {
                        preconditionFailure("make-scanout-presentation returned an invalid payload")
                    }
                    ownedPresentation = presentation
                }
                guard let presentation = ownedPresentation,
                      presentation.resourceID == binding.resourceID,
                      presentation.resourceGeneration == generation else {
                    throw VMError.invalidConfiguration(
                        "virtio-gpu renderer returned mismatched presentation identity"
                    )
                }
                let update = VirtioGPUScanoutTextureUpdate(
                    scanoutID: scanoutID,
                    presentation: presentation,
                    sourceRect: binding.rect,
                    dirtyRect: VirtioGPURect(
                        x: 0,
                        y: 0,
                        width: binding.rect.width,
                        height: binding.rect.height
                    )
                )
                // `publishTextureUpdate` now owns the authority and either hands it to the
                // mailbox or explicitly discards it when no consumer is configured.
                ownedPresentation = nil
                publishTextureUpdate(update)
            } catch {
                ownedPresentation?.discardWithoutPresentation()
                throw error
            }
        case .blob:
            preparedPresentation?.discardWithoutPresentation()
            guard let blob = blobResources[binding.resourceID] else {
                throw VMError.invalidConfiguration("virtio-gpu blob scanout resource disappeared")
            }
            try publishBlobScanoutFrames(
                resourceID: binding.resourceID,
                blob: blob,
                dirtyRect: binding.rect
            )
        }
    }

    private func publishRendererDamage(resourceID: UInt32, dirtyRect: VirtioGPURect) throws {
        guard rendererExecutor != nil,
              let generation = resourceGenerations[resourceID] else { return }
        let targets = scanouts.sorted(by: { $0.key < $1.key }).compactMap {
            (scanoutID, binding) -> (UInt32, ScanoutBinding, VirtioGPURect)? in
            guard binding.resourceID == resourceID,
                  case .resource3D = binding.source,
                  let damaged = Self.intersection(dirtyRect, binding.rect) else {
                return nil
            }
            return (scanoutID, binding, damaged)
        }
        // Acquire every producer-completion authority before publishing any update. A renderer
        // failure must leave all scanouts on their previous coherent frame, not partially advance a
        // multi-display resource.
        var updates = [VirtioGPUScanoutTextureUpdate]()
        do {
            for (scanoutID, binding, damaged) in targets {
                let result = try executeRendererCommand(.makeScanoutPresentation(
                    resourceID: resourceID,
                    resourceGeneration: generation
                ))
                guard case .scanoutPresentation(let presentation) = result else {
                    preconditionFailure("make-scanout-presentation returned an invalid payload")
                }
                guard presentation.resourceID == resourceID,
                      presentation.resourceGeneration == generation else {
                    presentation.discardWithoutPresentation()
                    throw VMError.invalidConfiguration(
                        "virtio-gpu renderer returned mismatched presentation identity"
                    )
                }
                updates.append(VirtioGPUScanoutTextureUpdate(
                    scanoutID: scanoutID,
                    presentation: presentation,
                    sourceRect: binding.rect,
                    dirtyRect: VirtioGPURect(
                        x: damaged.x - binding.rect.x,
                        y: damaged.y - binding.rect.y,
                        width: damaged.width,
                        height: damaged.height
                    )
                ))
            }
        } catch {
            // Multi-scanout publication is transactional. If acquisition N fails, retire every
            // already-acquired authority and publish none of the new generation's damage.
            for update in updates {
                update.presentation.discardWithoutPresentation()
            }
            throw error
        }
        for update in updates {
            publishTextureUpdate(update)
        }
    }

    private func publishTextureUpdate(_ update: VirtioGPUScanoutTextureUpdate) {
        if let onScanoutTexture {
            onScanoutTexture(update)
        } else {
            update.presentation.discardWithoutPresentation()
        }
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
        resourceID: UInt32
    ) throws -> VirtioGPUBlobMapping {
        guard var blob = blobResources[resourceID] else {
            throw VMError.invalidConfiguration("virtio-gpu map of unknown blob")
        }
        if let mapping = blob.mapping { return mapping }
        let result = try executeRendererCommand(.mapBlob(resourceID: resourceID))
        guard case .blobMapping(let mapping) = result else {
            preconditionFailure("map-blob returned an invalid executor payload")
        }
        blob.mapping = mapping
        blobResources[resourceID] = blob
        return mapping
    }

    /// Linux creates an implicit default context for primary-node clients before userspace can issue
    /// VIRTGPU_CONTEXT_INIT. The standard default is VirGL2 when it is advertised; a renderer offering
    /// one capset has an unambiguous default. Resolving zero here also prevents the kernel from retrying
    /// an unsupported legacy context when only one non-VirGL capset is advertised.
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
        resourceID: UInt32
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
            _ = try executeRendererCommand(.unmapBlob(resourceID: resourceID))
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
        guard total <= maximumRawMemoryEntries else {
            throw VMError.invalidConfiguration(
                "virtio-gpu raw memory entry limit exceeded: \(total) > \(maximumRawMemoryEntries)"
            )
        }
        let (entryBytes, multiplyOverflow) = total.multipliedReportingOverflow(by: 16)
        let (end, addOverflow) = offset.addingReportingOverflow(entryBytes)
        guard !multiplyOverflow, !addOverflow, offset >= 0, end <= request.count else {
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
            entries.append(VirtioGPUMemoryEntry(
                pointer: pointer,
                length: Int(length),
                guestAddress: guestAddress
            ))
        }
        return try Self.coalescedMemoryEntries(
            entries,
            maximumEntries: maximumMemoryEntries
        )
    }

    /// Virtio-gpu guests commonly describe a single compositor buffer as one entry per guest page.
    /// Guest RAM is one descriptor-backed object in Dory, so adjacent guest addresses whose host
    /// pointers are also adjacent are the same renderer iovec and may be joined losslessly. Real
    /// Linux shmem allocations are often physically discontiguous; those entries remain distinct
    /// and retain their exact byte ordering up to the authenticated worker's explicit limit.
    static func coalescedMemoryEntries(
        _ entries: [VirtioGPUMemoryEntry],
        maximumEntries: Int
    ) throws -> [VirtioGPUMemoryEntry] {
        let limit = max(1, maximumEntries)
        var result = [VirtioGPUMemoryEntry]()
        result.reserveCapacity(min(entries.count, limit))
        for entry in entries {
            guard entry.length > 0, let guestAddress = entry.guestAddress else {
                throw VMError.invalidConfiguration("virtio-gpu memory entry is invalid")
            }
            if var previous = result.last,
               let previousGuestAddress = previous.guestAddress {
                let (previousGuestEnd, addressOverflow) = previousGuestAddress
                    .addingReportingOverflow(UInt64(previous.length))
                if !addressOverflow,
                   previousGuestEnd == guestAddress,
                   previous.pointer.advanced(by: previous.length) == entry.pointer {
                    let (combinedLength, lengthOverflow) = previous.length
                        .addingReportingOverflow(entry.length)
                    guard !lengthOverflow else {
                        throw VMError.invalidConfiguration(
                            "virtio-gpu memory entry length overflow"
                        )
                    }
                    previous.length = combinedLength
                    result[result.count - 1] = previous
                    continue
                }
            }
            guard result.count < limit else {
                throw VMError.invalidConfiguration(
                    "virtio-gpu normalized memory entry limit exceeded: more than \(limit)"
                )
            }
            result.append(entry)
        }
        return result
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
