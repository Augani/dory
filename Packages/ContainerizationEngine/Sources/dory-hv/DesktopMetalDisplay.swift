import AppKit
import CoreFoundation
import Darwin
import DoryHV
import DoryRendererWorkerContracts
import Foundation
import Metal
import QuartzCore

/// `DesktopMode` enters `NSApplication.run()` from the executable's async `@MainActor` task.
/// That AppKit run loop remains live, but the enclosing dispatch-main task cannot return while the
/// VM is running, so another `DispatchQueue.main.async` block cannot begin. Publish UI work through
/// the main CFRunLoop source that AppKit actually drains instead of queueing behind the app loop.
enum DesktopAppRunLoop {
    static func perform(_ operation: @escaping @MainActor @Sendable () -> Void) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue as CFTypeRef) {
            MainActor.assumeIsolated { operation() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    static func perform(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + max(0, delay)
        ) {
            perform(operation)
        }
    }
}

/// Maps one window-local absolute pointer into the guest's deterministic horizontal scanout
/// layout. Virtio-input exposes one tablet for the whole desktop rather than one per connector.
final class DesktopPointerTopology: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [VirtioGPUScanoutSize]

    init(sizes: [VirtioGPUScanoutSize]) {
        self.sizes = sizes
    }

    func update(scanoutID: UInt32, width: UInt32, height: UInt32) {
        lock.withLock {
            let index = Int(scanoutID)
            guard sizes.indices.contains(index) else { return }
            sizes[index] = VirtioGPUScanoutSize(width: width, height: height)
        }
    }

    func normalizedPoint(
        scanoutID: UInt32,
        localX: CGFloat,
        localY: CGFloat
    ) -> CGPoint {
        lock.withLock {
            let index = Int(scanoutID)
            guard sizes.indices.contains(index), !sizes.isEmpty else {
                return CGPoint(
                    x: min(1, max(0, localX)),
                    y: min(1, max(0, localY))
                )
            }
            let totalWidth = sizes.reduce(UInt64(0)) { $0 + UInt64($1.width) }
            let totalHeight = sizes.map(\.height).max() ?? 1
            let originX = sizes[..<index].reduce(UInt64(0)) {
                $0 + UInt64($1.width)
            }
            let size = sizes[index]
            let boundedX = min(1, max(0, localX))
            let boundedY = min(1, max(0, localY))
            return CGPoint(
                x: (CGFloat(originX) + boundedX * CGFloat(size.width))
                    / CGFloat(max(1, totalWidth)),
                y: boundedY * CGFloat(size.height) / CGFloat(max(1, totalHeight))
            )
        }
    }
}

/// Maps a scanout rectangle into the Metal texture coordinates consumed by
/// `DesktopDisplayView`'s flipped AppKit surface.
///
/// The view and virtio-input tablet both use a top-left origin. A top-origin scanout therefore
/// needs increasing texture Y from the first row to the last row; swapping those endpoints here
/// vertically mirrors the visible desktop while pointer input continues to target the unmirrored
/// guest coordinate. Bottom-origin renderer textures require the opposite ordering.
enum DesktopScanoutTextureCoordinates {
    static func sourceUV(
        sourceRect: VirtioGPURect,
        backingWidth: UInt32,
        backingHeight: UInt32,
        yOriginTop: Bool
    ) -> SIMD4<Float> {
        let left = Float(sourceRect.x) / Float(backingWidth)
        let right = Float(sourceRect.x + sourceRect.width) / Float(backingWidth)
        let firstY = Float(sourceRect.y) / Float(backingHeight)
        let secondY = Float(sourceRect.y + sourceRect.height) / Float(backingHeight)
        return SIMD4<Float>(
            left,
            yOriginTop ? firstY : secondY,
            right,
            yOriginTop ? secondY : firstY
        )
    }
}

/// Measures the bounded producer-to-main-thread software presentation lane. Frame counters refer
/// to producer submissions; byte counters distinguish received payload, explicit mailbox copies,
/// display uploads, rejected/destroyed payload, and current backlog.
struct DesktopFrameMailboxMetrics: Equatable, Sendable {
    var presentedFrames: UInt64
    var droppedFrames: UInt64
    var budgetRejectedFrames: UInt64
    /// Immutable producer payload observed at the mailbox boundary, including rejected frames.
    var receivedFrameBytes: UInt64
    /// Bytes explicitly copied while normalizing stride or merging a software-frame backlog.
    var stagingCopyBytes: UInt64
    /// Bytes copied from sparse cells into tightly packed main-thread upload buffers.
    var drainCopyBytes: UInt64
    /// Texel payload submitted by successful CPU-to-display texture uploads.
    var uploadedFrameBytes: UInt64
    /// Producer payload rejected, destroyed, disabled, or unpresentable before a complete upload.
    var droppedFrameBytes: UInt64
    /// Retained payload/cell storage currently waiting for main-thread presentation.
    var pendingFrameBytes: UInt64
    /// Number of accepted producer updates represented by the current retained state.
    var pendingFrameDepth: UInt64

    init(
        presentedFrames: UInt64,
        droppedFrames: UInt64,
        budgetRejectedFrames: UInt64 = 0,
        receivedFrameBytes: UInt64 = 0,
        stagingCopyBytes: UInt64 = 0,
        drainCopyBytes: UInt64 = 0,
        uploadedFrameBytes: UInt64 = 0,
        droppedFrameBytes: UInt64 = 0,
        pendingFrameBytes: UInt64 = 0,
        pendingFrameDepth: UInt64 = 0
    ) {
        self.presentedFrames = presentedFrames
        self.droppedFrames = droppedFrames
        self.budgetRejectedFrames = budgetRejectedFrames
        self.receivedFrameBytes = receivedFrameBytes
        self.stagingCopyBytes = stagingCopyBytes
        self.drainCopyBytes = drainCopyBytes
        self.uploadedFrameBytes = uploadedFrameBytes
        self.droppedFrameBytes = droppedFrameBytes
        self.pendingFrameBytes = pendingFrameBytes
        self.pendingFrameDepth = pendingFrameDepth
    }
}

struct DesktopCPUPresentationBudgetMetrics: Equatable, Sendable {
    var residentBytes: Int
    var peakResidentBytes: Int
    var rejectedReservations: UInt64
}

/// One process-wide authority bounds retained software-frame payload and sparse accumulator cells
/// across every scanout mailbox. Per-mailbox limits remain useful for fairness, but cannot
/// substitute for this aggregate limit: Linux may bind one framebuffer to all 16 scanouts.
final class DesktopCPUPresentationBudget: @unchecked Sendable {
    static let processDefault = DesktopCPUPresentationBudget(
        maximumResidentBytes: 256 * 1_024 * 1_024
    )

    private let lock = NSLock()
    private let maximumResidentBytes: Int
    private var residentBytes = 0
    private var peakResidentBytes = 0
    private var rejectedReservations: UInt64 = 0

    init(maximumResidentBytes: Int) {
        self.maximumResidentBytes = max(1, maximumResidentBytes)
    }

    func replaceReservation(releasing oldBytes: Int, reserving newBytes: Int) -> Bool {
        lock.withLock {
            guard oldBytes >= 0, oldBytes <= residentBytes,
                  newBytes >= 0,
                  newBytes <= maximumResidentBytes - (residentBytes - oldBytes) else {
                rejectedReservations = Self.saturatingAdd(rejectedReservations, 1)
                return false
            }
            residentBytes = residentBytes - oldBytes + newBytes
            peakResidentBytes = max(peakResidentBytes, residentBytes)
            return true
        }
    }

    func release(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.withLock {
            precondition(byteCount <= residentBytes, "CPU presentation budget over-release")
            residentBytes -= byteCount
        }
    }

    var metrics: DesktopCPUPresentationBudgetMetrics {
        lock.withLock {
            DesktopCPUPresentationBudgetMetrics(
                residentBytes: residentBytes,
                peakResidentBytes: peakResidentBytes,
                rejectedReservations: rejectedReservations
            )
        }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }
}

/// Keeps process-wide presentation bytes reserved until the main-thread consumer has finished
/// with the drained `Data`. Moving bytes out of a mailbox must not make the shared budget appear
/// free while the display is still reading those same bytes.
private final class DesktopCPUPresentationDrainReservation: @unchecked Sendable {
    private let budget: DesktopCPUPresentationBudget
    private let byteCount: Int

    init(budget: DesktopCPUPresentationBudget, byteCount: Int) {
        self.budget = budget
        self.byteCount = byteCount
    }

    deinit {
        budget.release(byteCount)
    }
}

/// Stable guest resource identity shared by copied CPU frames and worker-issued Metal surfaces.
/// Resource IDs may be reused, so the ID alone is never sufficient for presentation lifetime.
struct DesktopScanoutResourceIdentity: Hashable, Sendable {
    var resourceID: UInt32
    var generation: UInt64

    init(resourceID: UInt32, generation: UInt64) {
        self.resourceID = resourceID
        self.generation = generation
    }

    init(frame: VirtioGPUScanoutFrame) {
        self.init(resourceID: frame.resourceID, generation: frame.resourceGeneration)
    }

    init(metalUpdate: VirtioGPUMetalScanoutUpdate) {
        self.init(
            resourceID: metalUpdate.resourceID,
            generation: metalUpdate.resourceGeneration
        )
    }
}

/// Pure presentation lifetime state. It remembers releases independently of the currently bound
/// scanout so a delayed update for a retired generation cannot become visible after its release.
struct DesktopScanoutResourceLifetime {
    private enum GenerationState {
        case active(UInt64)
        case released(through: UInt64)

        var generation: UInt64 {
            switch self {
            case .active(let generation), .released(let generation): generation
            }
        }
    }

    private var generations: [UInt32: GenerationState] = [:]
    private(set) var boundIdentity: DesktopScanoutResourceIdentity?

    func accepts(_ identity: DesktopScanoutResourceIdentity) -> Bool {
        guard let state = generations[identity.resourceID] else { return true }
        switch state {
        case .active(let generation):
            return identity.generation >= generation
        case .released(let throughGeneration):
            return identity.generation > throughGeneration
        }
    }

    @discardableResult
    mutating func bind(_ identity: DesktopScanoutResourceIdentity) -> Bool {
        guard accepts(identity) else { return false }
        generations[identity.resourceID] = .active(identity.generation)
        boundIdentity = identity
        return true
    }

    /// Returns true only when this release retired the currently displayed resource generation.
    @discardableResult
    mutating func release(resourceID: UInt32, throughGeneration: UInt64) -> Bool {
        if (generations[resourceID]?.generation ?? 0) <= throughGeneration {
            generations[resourceID] = .released(through: throughGeneration)
        }
        guard let binding = boundIdentity,
              binding.resourceID == resourceID,
              binding.generation <= throughGeneration else {
            return false
        }
        boundIdentity = nil
        return true
    }

    mutating func unbind() {
        boundIdentity = nil
    }
}

/// Preserves every accepted damage pixel without allocating a complete framebuffer in the
/// mailbox. The normal one-update case retains the producer's immutable `Data` and drains it
/// without a copy. Only a stalled main thread with multiple non-superseding updates activates a
/// sparse accumulator whose cells are derived from one host page. Dirty masks ensure that holes
/// between distant rectangles are never copied or uploaded as if they were valid pixels.
final class DesktopScanoutFrameCoalescer {
    enum AppendOutcome: Equatable {
        case accepted
        case invalid
        case budgetExceeded
    }

    fileprivate struct ResourceKey: Hashable {
        var resourceID: UInt32
        var resourceGeneration: UInt64
    }

    fileprivate struct TileKey: Hashable {
        var column: UInt32
        var row: UInt32
    }

    fileprivate struct Tile {
        var width: Int
        var height: Int
        var bytes: Data
        var dirtyRows: [UInt64]
        var dirtyPixelCount: Int
    }

    fileprivate final class TiledStorage {
        var tiles: [TileKey: Tile] = [:]
        var residentBytes = 0
        var dirtyPixelCount = 0
    }

    fileprivate enum Storage {
        case single(VirtioGPUScanoutFrame)
        case tiled(TiledStorage)
    }

    fileprivate struct Surface {
        var scanoutID: UInt32
        var format: UInt32
        var width: UInt32
        var height: UInt32
        var storage: Storage
        var inputFrameCount: UInt64
        var inputPayloadByteCount: UInt64

        var residentBytes: Int {
            switch storage {
            case .single(let frame): frame.bytes.count
            case .tiled(let tiled): tiled.residentBytes
            }
        }

        var uploadByteCount: Int {
            switch storage {
            case .single(let frame):
                Int(frame.dirtyRect.width) * Int(frame.dirtyRect.height) * 4
            case .tiled(let tiled):
                tiled.dirtyPixelCount * 4
            }
        }
    }

    struct Metrics: Equatable {
        var residentBytes: Int
        var peakResidentBytes: Int
        var pendingFrameDepth: UInt64
        var peakPendingFrameDepth: UInt64
        var stagingCopyBytes: UInt64
    }

    struct Removal: Equatable {
        var frameCount: UInt64
        var payloadByteCount: UInt64
    }

    struct Drain {
        struct Batch {
            var frameRange: Range<Int>
            var inputFrameCount: UInt64
            var inputPayloadByteCount: UInt64
        }

        var frames: [VirtioGPUScanoutFrame]
        var inputFrameCount: UInt64
        var outputByteCount: Int
        var copyByteCount: Int
        var hasMorePendingFrames: Bool
        var batches: [Batch]
        fileprivate var reservation: DesktopCPUPresentationDrainReservation?
    }

    struct PendingDrain {
        fileprivate var entries: [(ResourceKey, Surface)]
        fileprivate var inputFrameCount: UInt64
        fileprivate var outputByteCount: Int
        fileprivate var hasMorePendingFrames: Bool
        fileprivate var reservation: DesktopCPUPresentationDrainReservation?

        fileprivate func materialize() -> Drain {
            var frames = [VirtioGPUScanoutFrame]()
            var batches = [Drain.Batch]()
            var copyByteCount = 0
            for (key, surface) in entries {
                let start = frames.count
                switch surface.storage {
                case .single(let frame):
                    frames.append(frame)
                case .tiled(let tiled):
                    for rect in DesktopScanoutFrameCoalescer.dirtyRectangles(in: tiled) {
                        frames.append(DesktopScanoutFrameCoalescer.makeFrame(
                            key: key,
                            surface: surface,
                            tiled: tiled,
                            rect: rect
                        ))
                        copyByteCount += Int(rect.width) * Int(rect.height) * 4
                    }
                }
                batches.append(Drain.Batch(
                    frameRange: start..<frames.count,
                    inputFrameCount: surface.inputFrameCount,
                    inputPayloadByteCount: surface.inputPayloadByteCount
                ))
            }
            return Drain(
                frames: frames,
                inputFrameCount: inputFrameCount,
                outputByteCount: outputByteCount,
                copyByteCount: copyByteCount,
                hasMorePendingFrames: hasMorePendingFrames,
                batches: batches,
                reservation: reservation
            )
        }
    }

    private var surfaces: [ResourceKey: Surface] = [:]
    private var pendingOrder = [ResourceKey]()
    private let maximumSurfaceBytes: Int
    private let maximumAggregateSurfaceBytes: Int
    private let maximumDrainBytes: Int
    private let sharedBudget: DesktopCPUPresentationBudget
    private(set) var residentSurfaceBytes = 0
    private var peakResidentSurfaceBytes = 0
    private var pendingFrameDepth: UInt64 = 0
    private var peakPendingFrameDepth: UInt64 = 0
    private var stagingCopyByteCount: UInt64 = 0

    init(
        maximumSurfaceBytes: Int = 128 * 1_024 * 1_024,
        maximumAggregateSurfaceBytes: Int = 256 * 1_024 * 1_024,
        maximumDrainBytes: Int = 128 * 1_024 * 1_024,
        sharedBudget: DesktopCPUPresentationBudget? = nil
    ) {
        self.maximumSurfaceBytes = max(1, maximumSurfaceBytes)
        self.maximumAggregateSurfaceBytes = max(
            self.maximumSurfaceBytes,
            maximumAggregateSurfaceBytes
        )
        // Every admitted surface must be drainable. The aggregate ceiling may be larger, but one
        // main-thread delivery never materializes more copied output than this value.
        self.maximumDrainBytes = max(self.maximumSurfaceBytes, maximumDrainBytes)
        self.sharedBudget = sharedBudget ?? DesktopCPUPresentationBudget(
            maximumResidentBytes: self.maximumAggregateSurfaceBytes
        )
    }

    deinit {
        sharedBudget.release(residentSurfaceBytes)
    }

    func append(_ frame: VirtioGPUScanoutFrame) -> Bool {
        appendOutcome(frame) == .accepted
    }

    func appendOutcome(_ frame: VirtioGPUScanoutFrame) -> AppendOutcome {
        let sourceRowBytes = UInt64(frame.dirtyRect.width) * 4
        let requiredSourceBytes = UInt64(frame.stride) * UInt64(frame.dirtyRect.height)
        guard frame.width > 0, frame.height > 0,
              frame.dirtyRect.width > 0, frame.dirtyRect.height > 0,
              frame.dirtyRect.x <= frame.width,
              frame.dirtyRect.width <= frame.width - frame.dirtyRect.x,
              frame.dirtyRect.y <= frame.height,
              frame.dirtyRect.height <= frame.height - frame.dirtyRect.y,
              UInt64(frame.stride) >= sourceRowBytes,
              requiredSourceBytes <= UInt64(Int.max),
              UInt64(frame.bytes.count) == requiredSourceBytes else {
            return .invalid
        }
        guard let surfaceByteCount = Self.rgbaByteCount(
            width: frame.width,
            height: frame.height
        ), surfaceByteCount <= UInt64(Int.max),
              surfaceByteCount <= UInt64(maximumSurfaceBytes) else {
            return .budgetExceeded
        }

        let normalized = Self.normalized(frame)
        let key = ResourceKey(
            resourceID: frame.resourceID,
            resourceGeneration: frame.resourceGeneration
        )
        var surface = surfaces.removeValue(forKey: key)
        if let surface,
           surface.scanoutID != frame.scanoutID
            || surface.format != frame.format
            || surface.width != frame.width
            || surface.height != frame.height {
            surfaces[key] = surface
            return .invalid
        }

        let oldResidentBytes = surface?.residentBytes ?? 0
        let newResidentBytes: Int
        if let surface {
            switch surface.storage {
            case .single(let oldFrame):
                if Self.contains(normalized.frame.dirtyRect, oldFrame.dirtyRect) {
                    newResidentBytes = normalized.frame.bytes.count
                } else {
                    newResidentBytes = Self.tileStorageByteCount(
                        rects: [oldFrame.dirtyRect, normalized.frame.dirtyRect],
                        surfaceWidth: frame.width,
                        surfaceHeight: frame.height
                    )
                }
            case .tiled(let tiled):
                if Self.isFullSurface(normalized.frame.dirtyRect, width: frame.width, height: frame.height) {
                    newResidentBytes = normalized.frame.bytes.count
                } else {
                    newResidentBytes = tiled.residentBytes + Self.additionalTileStorageByteCount(
                        rect: normalized.frame.dirtyRect,
                        excluding: tiled.tiles.keys,
                        surfaceWidth: frame.width,
                        surfaceHeight: frame.height
                    )
                }
            }
        } else {
            newResidentBytes = normalized.frame.bytes.count
        }

        let residentWithoutOld = residentSurfaceBytes - oldResidentBytes
        guard newResidentBytes <= maximumAggregateSurfaceBytes - residentWithoutOld else {
            if let surface { surfaces[key] = surface }
            return .budgetExceeded
        }
        guard sharedBudget.replaceReservation(
            releasing: oldResidentBytes,
            reserving: newResidentBytes
        ) else {
            if let surface { surfaces[key] = surface }
            return .budgetExceeded
        }

        var additionalCopies = normalized.copyByteCount
        if var existing = surface {
            let nextInputFrameCount = Self.saturatingAdd(existing.inputFrameCount, 1)
            switch existing.storage {
            case .single(let oldFrame):
                if Self.contains(normalized.frame.dirtyRect, oldFrame.dirtyRect) {
                    existing.storage = .single(normalized.frame)
                } else {
                    let tiled = TiledStorage()
                    Self.apply(oldFrame, to: tiled, surfaceWidth: frame.width, surfaceHeight: frame.height)
                    Self.apply(
                        normalized.frame,
                        to: tiled,
                        surfaceWidth: frame.width,
                        surfaceHeight: frame.height
                    )
                    additionalCopies = Self.saturatingAdd(
                        additionalCopies,
                        UInt64(oldFrame.dirtyRect.width) * UInt64(oldFrame.dirtyRect.height) * 4
                    )
                    additionalCopies = Self.saturatingAdd(
                        additionalCopies,
                        UInt64(normalized.frame.dirtyRect.width)
                            * UInt64(normalized.frame.dirtyRect.height) * 4
                    )
                    existing.storage = .tiled(tiled)
                }
            case .tiled(let tiled):
                if Self.isFullSurface(
                    normalized.frame.dirtyRect,
                    width: frame.width,
                    height: frame.height
                ) {
                    existing.storage = .single(normalized.frame)
                } else {
                    Self.apply(
                        normalized.frame,
                        to: tiled,
                        surfaceWidth: frame.width,
                        surfaceHeight: frame.height
                    )
                    additionalCopies = Self.saturatingAdd(
                        additionalCopies,
                        UInt64(normalized.frame.dirtyRect.width)
                            * UInt64(normalized.frame.dirtyRect.height) * 4
                    )
                }
            }
            existing.inputFrameCount = nextInputFrameCount
            existing.inputPayloadByteCount = Self.saturatingAdd(
                existing.inputPayloadByteCount,
                UInt64(frame.bytes.count)
            )
            surface = existing
        } else {
            surface = Surface(
                scanoutID: frame.scanoutID,
                format: frame.format,
                width: frame.width,
                height: frame.height,
                storage: .single(normalized.frame),
                inputFrameCount: 1,
                inputPayloadByteCount: UInt64(frame.bytes.count)
            )
        }
        guard let surface else { preconditionFailure("accepted scanout update lost its surface") }
        residentSurfaceBytes = residentWithoutOld + surface.residentBytes
        peakResidentSurfaceBytes = max(peakResidentSurfaceBytes, residentSurfaceBytes)
        pendingFrameDepth = Self.saturatingAdd(pendingFrameDepth, 1)
        peakPendingFrameDepth = max(peakPendingFrameDepth, pendingFrameDepth)
        stagingCopyByteCount = Self.saturatingAdd(stagingCopyByteCount, additionalCopies)
        surfaces[key] = surface
        pendingOrder.removeAll { $0 == key }
        pendingOrder.append(key)
        return .accepted
    }

    func remove(resourceID: UInt32, throughGeneration: UInt64) -> UInt64 {
        removeOutcome(resourceID: resourceID, throughGeneration: throughGeneration).frameCount
    }

    func removeOutcome(resourceID: UInt32, throughGeneration: UInt64) -> Removal {
        let matching = surfaces.keys.filter {
            $0.resourceID == resourceID && $0.resourceGeneration <= throughGeneration
        }
        var removed: UInt64 = 0
        var removedPayloadBytes: UInt64 = 0
        for key in matching {
            let surface = surfaces.removeValue(forKey: key)
            if let surface {
                residentSurfaceBytes -= surface.residentBytes
                sharedBudget.release(surface.residentBytes)
                pendingFrameDepth = Self.saturatingSubtract(
                    pendingFrameDepth,
                    surface.inputFrameCount
                )
                removedPayloadBytes = Self.saturatingAdd(
                    removedPayloadBytes,
                    surface.inputPayloadByteCount
                )
            }
            removed = Self.saturatingAdd(
                removed,
                surface?.inputFrameCount ?? 0
            )
        }
        pendingOrder.removeAll {
            $0.resourceID == resourceID && $0.resourceGeneration <= throughGeneration
        }
        return Removal(frameCount: removed, payloadByteCount: removedPayloadBytes)
    }

    func discardPending() -> UInt64 {
        discardPendingOutcome().frameCount
    }

    func discardPendingOutcome() -> Removal {
        var discarded: UInt64 = 0
        var discardedPayloadBytes: UInt64 = 0
        for key in pendingOrder {
            guard let surface = surfaces.removeValue(forKey: key) else { continue }
            discarded = Self.saturatingAdd(discarded, surface.inputFrameCount)
            discardedPayloadBytes = Self.saturatingAdd(
                discardedPayloadBytes,
                surface.inputPayloadByteCount
            )
            residentSurfaceBytes -= surface.residentBytes
            sharedBudget.release(surface.residentBytes)
        }
        pendingFrameDepth = 0
        pendingOrder.removeAll(keepingCapacity: true)
        return Removal(frameCount: discarded, payloadByteCount: discardedPayloadBytes)
    }

    func drain() -> Drain {
        takeDrain().materialize()
    }

    func takeDrain() -> PendingDrain {
        var entries = [(ResourceKey, Surface)]()
        var inputFrameCount: UInt64 = 0
        var outputByteCount = 0
        var reservedByteCount = 0
        var remainingOrder = [ResourceKey]()
        for key in pendingOrder {
            guard let surface = surfaces[key] else { continue }
            guard surface.uploadByteCount <= maximumDrainBytes - outputByteCount else {
                remainingOrder.append(key)
                continue
            }
            guard let removed = surfaces.removeValue(forKey: key) else { continue }
            entries.append((key, removed))
            outputByteCount += removed.uploadByteCount
            inputFrameCount = Self.saturatingAdd(inputFrameCount, surface.inputFrameCount)
            reservedByteCount += removed.residentBytes
            residentSurfaceBytes -= removed.residentBytes
            pendingFrameDepth = Self.saturatingSubtract(
                pendingFrameDepth,
                removed.inputFrameCount
            )
        }
        pendingOrder = remainingOrder
        let reservation = reservedByteCount > 0
            ? DesktopCPUPresentationDrainReservation(
                budget: sharedBudget,
                byteCount: reservedByteCount
            )
            : nil
        return PendingDrain(
            entries: entries,
            inputFrameCount: inputFrameCount,
            outputByteCount: outputByteCount,
            hasMorePendingFrames: !remainingOrder.isEmpty,
            reservation: reservation
        )
    }

    var metrics: Metrics {
        Metrics(
            residentBytes: residentSurfaceBytes,
            peakResidentBytes: peakResidentSurfaceBytes,
            pendingFrameDepth: pendingFrameDepth,
            peakPendingFrameDepth: peakPendingFrameDepth,
            stagingCopyBytes: stagingCopyByteCount
        )
    }

    private static var tileEdge: UInt32 {
        let pagePixels = max(1, Int(HostPage.size) / 4)
        var edge = 1
        while edge < 64, (edge * 2) * (edge * 2) <= pagePixels { edge *= 2 }
        return UInt32(edge)
    }

    private static func normalized(
        _ frame: VirtioGPUScanoutFrame
    ) -> (frame: VirtioGPUScanoutFrame, copyByteCount: UInt64) {
        let tightStride = Int(frame.dirtyRect.width) * 4
        let tightByteCount = tightStride * Int(frame.dirtyRect.height)
        if Int(frame.stride) == tightStride, frame.bytes.count == tightByteCount {
            return (frame, 0)
        }
        var output = Data(count: tightByteCount)
        output.withUnsafeMutableBytes { destination in
            frame.bytes.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                for row in 0..<Int(frame.dirtyRect.height) {
                    destinationBase.advanced(by: row * tightStride).copyMemory(
                        from: sourceBase.advanced(by: row * Int(frame.stride)),
                        byteCount: tightStride
                    )
                }
            }
        }
        var normalized = frame
        normalized.stride = UInt32(tightStride)
        normalized.bytes = output
        return (normalized, UInt64(tightByteCount))
    }

    private static func contains(_ outer: VirtioGPURect, _ inner: VirtioGPURect) -> Bool {
        outer.x <= inner.x
            && outer.y <= inner.y
            && UInt64(outer.x) + UInt64(outer.width)
                >= UInt64(inner.x) + UInt64(inner.width)
            && UInt64(outer.y) + UInt64(outer.height)
                >= UInt64(inner.y) + UInt64(inner.height)
    }

    private static func isFullSurface(_ rect: VirtioGPURect, width: UInt32, height: UInt32) -> Bool {
        rect.x == 0 && rect.y == 0 && rect.width == width && rect.height == height
    }

    private static func tileKeys(for rect: VirtioGPURect) -> [TileKey] {
        let edge = tileEdge
        let lastColumn = (rect.x + rect.width - 1) / edge
        let lastRow = (rect.y + rect.height - 1) / edge
        var keys = [TileKey]()
        keys.reserveCapacity(
            Int(lastColumn - rect.x / edge + 1) * Int(lastRow - rect.y / edge + 1)
        )
        for row in rect.y / edge...lastRow {
            for column in rect.x / edge...lastColumn {
                keys.append(TileKey(column: column, row: row))
            }
        }
        return keys
    }

    private static func tileByteCount(
        key: TileKey,
        surfaceWidth: UInt32,
        surfaceHeight: UInt32
    ) -> Int {
        let originX = key.column * tileEdge
        let originY = key.row * tileEdge
        let width = min(tileEdge, surfaceWidth - originX)
        let height = min(tileEdge, surfaceHeight - originY)
        return Int(width) * Int(height) * 4
    }

    private static func tileStorageByteCount(
        rects: [VirtioGPURect],
        surfaceWidth: UInt32,
        surfaceHeight: UInt32
    ) -> Int {
        let keys = Set(rects.flatMap(tileKeys(for:)))
        return keys.reduce(0) {
            $0 + tileByteCount(key: $1, surfaceWidth: surfaceWidth, surfaceHeight: surfaceHeight)
        }
    }

    private static func additionalTileStorageByteCount(
        rect: VirtioGPURect,
        excluding existing: Dictionary<TileKey, Tile>.Keys,
        surfaceWidth: UInt32,
        surfaceHeight: UInt32
    ) -> Int {
        let existing = Set(existing)
        return tileKeys(for: rect).reduce(0) { total, key in
            total + (existing.contains(key) ? 0 : tileByteCount(
                key: key,
                surfaceWidth: surfaceWidth,
                surfaceHeight: surfaceHeight
            ))
        }
    }

    private static func apply(
        _ frame: VirtioGPUScanoutFrame,
        to tiled: TiledStorage,
        surfaceWidth: UInt32,
        surfaceHeight: UInt32
    ) {
        let edge = tileEdge
        frame.bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for key in tileKeys(for: frame.dirtyRect) {
                let originX = key.column * edge
                let originY = key.row * edge
                let tileWidth = Int(min(edge, surfaceWidth - originX))
                let tileHeight = Int(min(edge, surfaceHeight - originY))
                var tile = tiled.tiles.removeValue(forKey: key) ?? Tile(
                    width: tileWidth,
                    height: tileHeight,
                    bytes: Data(count: tileWidth * tileHeight * 4),
                    dirtyRows: [UInt64](repeating: 0, count: tileHeight),
                    dirtyPixelCount: 0
                )
                if tile.dirtyPixelCount == 0 { tiled.residentBytes += tile.bytes.count }

                let intersectionX = max(frame.dirtyRect.x, originX)
                let intersectionY = max(frame.dirtyRect.y, originY)
                let intersectionRight = min(
                    UInt64(frame.dirtyRect.x) + UInt64(frame.dirtyRect.width),
                    UInt64(originX) + UInt64(tileWidth)
                )
                let intersectionBottom = min(
                    UInt64(frame.dirtyRect.y) + UInt64(frame.dirtyRect.height),
                    UInt64(originY) + UInt64(tileHeight)
                )
                let copyWidth = Int(intersectionRight - UInt64(intersectionX))
                let copyHeight = Int(intersectionBottom - UInt64(intersectionY))
                let localX = Int(intersectionX - originX)
                let localY = Int(intersectionY - originY)
                let sourceX = Int(intersectionX - frame.dirtyRect.x)
                let sourceY = Int(intersectionY - frame.dirtyRect.y)
                let dirtyMask: UInt64 = copyWidth == 64
                    ? .max
                    : ((UInt64(1) << UInt64(copyWidth)) - 1) << UInt64(localX)

                tile.bytes.withUnsafeMutableBytes { destination in
                    guard let destinationBase = destination.baseAddress else { return }
                    for row in 0..<copyHeight {
                        let destinationOffset = ((localY + row) * tileWidth + localX) * 4
                        let sourceOffset = (sourceY + row) * Int(frame.stride) + sourceX * 4
                        destinationBase.advanced(by: destinationOffset).copyMemory(
                            from: sourceBase.advanced(by: sourceOffset),
                            byteCount: copyWidth * 4
                        )
                        let rowIndex = localY + row
                        let added = dirtyMask & ~tile.dirtyRows[rowIndex]
                        let addedPixels = added.nonzeroBitCount
                        tile.dirtyRows[rowIndex] |= dirtyMask
                        tile.dirtyPixelCount += addedPixels
                        tiled.dirtyPixelCount += addedPixels
                    }
                }
                tiled.tiles[key] = tile
            }
        }
    }

    private struct HorizontalSpan: Hashable {
        var x: UInt32
        var width: UInt32
    }

    private static func dirtyRectangles(in tiled: TiledStorage) -> [VirtioGPURect] {
        var spansByRow: [UInt32: [HorizontalSpan]] = [:]
        let sortedTiles = tiled.tiles.sorted {
            ($0.key.row, $0.key.column) < ($1.key.row, $1.key.column)
        }
        for (key, tile) in sortedTiles {
            for localY in 0..<tile.height {
                let mask = tile.dirtyRows[localY]
                guard mask != 0 else { continue }
                var bit = 0
                while bit < tile.width {
                    while bit < tile.width, mask & (UInt64(1) << UInt64(bit)) == 0 { bit += 1 }
                    guard bit < tile.width else { break }
                    let start = bit
                    while bit < tile.width, mask & (UInt64(1) << UInt64(bit)) != 0 { bit += 1 }
                    let globalY = key.row * tileEdge + UInt32(localY)
                    spansByRow[globalY, default: []].append(HorizontalSpan(
                        x: key.column * tileEdge + UInt32(start),
                        width: UInt32(bit - start)
                    ))
                }
            }
        }

        for y in spansByRow.keys {
            let sorted = spansByRow[y, default: []].sorted { $0.x < $1.x }
            var merged = [HorizontalSpan]()
            for span in sorted {
                if let last = merged.last, last.x + last.width == span.x {
                    merged[merged.count - 1].width += span.width
                } else {
                    merged.append(span)
                }
            }
            spansByRow[y] = merged
        }

        var rectangles = [VirtioGPURect]()
        var active: [HorizontalSpan: VirtioGPURect] = [:]
        var previousY: UInt32?
        for y in spansByRow.keys.sorted() {
            if let previousY, y != previousY + 1 {
                rectangles.append(contentsOf: active.values)
                active.removeAll(keepingCapacity: true)
            }
            let current = Set(spansByRow[y, default: []])
            for span in active.keys where !current.contains(span) {
                if let finished = active.removeValue(forKey: span) { rectangles.append(finished) }
            }
            for span in current {
                if active[span] != nil {
                    active[span]?.height += 1
                } else {
                    active[span] = VirtioGPURect(x: span.x, y: y, width: span.width, height: 1)
                }
            }
            previousY = y
        }
        rectangles.append(contentsOf: active.values)
        return rectangles.sorted {
            ($0.y, $0.x, $0.height, $0.width) < ($1.y, $1.x, $1.height, $1.width)
        }
    }

    private static func makeFrame(
        key: ResourceKey,
        surface: Surface,
        tiled: TiledStorage,
        rect: VirtioGPURect
    ) -> VirtioGPUScanoutFrame {
        let stride = Int(rect.width) * 4
        var output = Data(count: stride * Int(rect.height))
        output.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<Int(rect.height) {
                let globalY = rect.y + UInt32(row)
                var globalX = rect.x
                var destinationX = 0
                while globalX < rect.x + rect.width {
                    let key = TileKey(column: globalX / tileEdge, row: globalY / tileEdge)
                    guard let tile = tiled.tiles[key] else { preconditionFailure("missing dirty tile") }
                    let localX = Int(globalX % tileEdge)
                    let localY = Int(globalY % tileEdge)
                    let pixelCount = min(
                        tile.width - localX,
                        Int(rect.x + rect.width - globalX)
                    )
                    tile.bytes.withUnsafeBytes { source in
                        guard let sourceBase = source.baseAddress else { return }
                        let sourceOffset = (localY * tile.width + localX) * 4
                        destinationBase.advanced(by: row * stride + destinationX * 4).copyMemory(
                            from: sourceBase.advanced(by: sourceOffset),
                            byteCount: pixelCount * 4
                        )
                    }
                    globalX += UInt32(pixelCount)
                    destinationX += pixelCount
                }
            }
        }
        return VirtioGPUScanoutFrame(
            scanoutID: surface.scanoutID,
            resourceID: key.resourceID,
            resourceGeneration: key.resourceGeneration,
            format: surface.format,
            width: surface.width,
            height: surface.height,
            stride: UInt32(stride),
            dirtyRect: rect,
            bytes: output
        )
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }

    private static func saturatingSubtract(_ value: UInt64, _ decrement: UInt64) -> UInt64 {
        value >= decrement ? value - decrement : 0
    }

    private static func rgbaByteCount(width: UInt32, height: UInt32) -> UInt64? {
        let (pixels, pixelOverflow) = UInt64(width).multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? nil : bytes
    }
}

struct DesktopCPUFramePresentationResult {
    var presented: [Bool]
    var uploadedByteCount: UInt64
}

/// Tracks the evdev modifier keys already published to Linux. Physical keyboards normally emit
/// AppKit `flagsChanged` events, but accessibility and remote-input sources may encode a modifier
/// only in the following key event. Reconcile both forms so shifted characters never arrive as
/// their unmodified key while avoiding duplicate modifier presses for ordinary hardware input.
struct DesktopKeyboardModifierState: Sendable {
    enum Modifier: CaseIterable, Hashable, Sendable {
        case command
        case shift
        case capsLock
        case option
        case control

        var canonicalLinuxCode: UInt16 {
            switch self {
            case .command: 125
            case .shift: 42
            case .capsLock: 58
            case .option: 56
            case .control: 29
            }
        }
    }

    private var activeCodes: [Modifier: Set<UInt16>] = [:]

    mutating func reconcile(activeModifiers: Set<Modifier>) -> [VirtioInputEvent] {
        var events = [VirtioInputEvent]()
        for modifier in Modifier.allCases {
            let codes = activeCodes[modifier] ?? []
            if activeModifiers.contains(modifier) {
                guard codes.isEmpty else { continue }
                let code = modifier.canonicalLinuxCode
                activeCodes[modifier] = [code]
                events.append(VirtioInputEvent(type: 1, code: code, value: 1))
            } else {
                guard !codes.isEmpty else { continue }
                activeCodes[modifier] = nil
                events.append(contentsOf: codes.sorted().map {
                    VirtioInputEvent(type: 1, code: $0, value: 0)
                })
            }
        }
        return events
    }

    mutating func update(
        modifier: Modifier,
        linuxCode: UInt16,
        pressed: Bool
    ) -> [VirtioInputEvent] {
        var codes = activeCodes[modifier] ?? []
        let changed: Bool
        if pressed {
            changed = codes.insert(linuxCode).inserted
        } else {
            changed = codes.remove(linuxCode) != nil
        }
        activeCodes[modifier] = codes.isEmpty ? nil : codes
        guard changed else { return [] }
        return [VirtioInputEvent(type: 1, code: linuxCode, value: pressed ? 1 : 0)]
    }

    mutating func reset() {
        activeCodes.removeAll(keepingCapacity: true)
    }
}

/// One AppKit surface owns keyboard, pointer, cursor, resize, and scanout geometry semantics for
/// the qualified Metal display. Presentation subclasses implement only their resource boundary;
/// they cannot silently substitute another renderer when their own validation or device fails.
@MainActor
class DesktopDisplayView: NSView {
    private let keyboardInput: VirtioInput
    private let pointerInput: VirtioInput
    private let guestBackingScaleFactor: CGFloat
    let scanoutID: UInt32
    private let pointerTopology: DesktopPointerTopology?
    var scanoutSize = CGSize.zero
    private var guestCursor = NSCursor.arrow
    private var guestCursorUpdate: VirtioGPUCursorUpdate?
    private var tracking: NSTrackingArea?
    private var scrollAccumulator = VirtioInputScrollAccumulator()
    private var pressedKeyboardInput = VirtioInputPressedState()
    private var pressedPointerInput = VirtioInputPressedState()
    private var keyboardModifierState = DesktopKeyboardModifierState()
    private var resizeGeneration: UInt64 = 0
    var onDrawableSizeChange: ((UInt32, UInt32) -> Void)?
    var onMacShortcut: ((NSEvent) -> Bool)?

    init(
        frame: NSRect,
        keyboardInput: VirtioInput,
        pointerInput: VirtioInput,
        guestBackingScaleFactor: CGFloat,
        scanoutID: UInt32,
        pointerTopology: DesktopPointerTopology?
    ) {
        self.keyboardInput = keyboardInput
        self.pointerInput = pointerInput
        self.guestBackingScaleFactor = guestBackingScaleFactor
        self.scanoutID = scanoutID
        self.pointerTopology = pointerTopology
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawableSurfaceDidChange()
        needsDisplay = true
    }

    /// A dedicated guest display is often not the key macOS window yet (notably immediately after
    /// entering fullscreen). Activation and guest input delivery intentionally share that click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(replacement)
        tracking = replacement
        super.updateTrackingAreas()
    }

    /// Presentation hooks deliberately reject by default. A mismatched producer/view pairing is a
    /// terminal capability error at the mailbox instead of an ambient graphics fallback.
    @discardableResult
    func present(_ frames: [VirtioGPUScanoutFrame]) -> DesktopCPUFramePresentationResult {
        DesktopCPUFramePresentationResult(
            presented: [Bool](repeating: false, count: frames.count),
            uploadedByteCount: 0
        )
    }

    @discardableResult
    func present(_ update: VirtioGPUMetalScanoutUpdate) -> Bool { false }

    func release(resourceID: UInt32, throughGeneration: UInt64) {}
    func disable() {}
    func drawableSurfaceDidChange() {}

    func presentCursor(_ update: VirtioGPUCursorUpdate?) {
        guestCursorUpdate = update
        rebuildGuestCursor()
    }

    private func rebuildGuestCursor(pixelSize: CGSize? = nil) {
        guard let update = guestCursorUpdate else {
            guestCursor = Self.transparentCursor
            window?.invalidateCursorRects(for: self)
            return
        }
        let effectivePixelSize = pixelSize
            ?? (scanoutSize.width > 0 ? scanoutSize : CGSize(
                width: bounds.width * guestBackingScaleFactor,
                height: bounds.height * guestBackingScaleFactor
            ))
        let cursorScale = bounds.width > 0
            ? max(1, effectivePixelSize.width / bounds.width)
            : CGFloat(1)
        guestCursor = Self.makeCursor(update, scale: cursorScale) ?? Self.transparentCursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: guestCursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        drawableSurfaceDidChange()
        let guestPixelSize = CGSize(
            width: max(1, bounds.width * guestBackingScaleFactor),
            height: max(1, bounds.height * guestBackingScaleFactor)
        )
        if guestCursorUpdate != nil { rebuildGuestCursor(pixelSize: guestPixelSize) }
        let width = UInt32(clamping: max(1, Int(guestPixelSize.width.rounded())))
        let height = UInt32(clamping: max(1, Int(guestPixelSize.height.rounded())))
        resizeGeneration &+= 1
        let generation = resizeGeneration
        // AppKit reports every intermediate drag size. Debounce the guest modeset so Mutter/Xfce
        // receives the final Retina pixel size without reallocating scanout resources per event.
        DesktopAppRunLoop.perform(after: 0.12) { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.onDrawableSizeChange?(width, height)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if onMacShortcut?(event) == true { return }
        if event.modifierFlags.contains(.command),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           let code = Self.macCommandShortcutMap[character] {
            sendControlShortcut(keyCode: code)
            return
        }
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        let modifiers = keyboardModifierState.reconcile(
            activeModifiers: Self.activeModifiers(event.modifierFlags)
        )
        sendKeyboardTracked(modifiers + [
            VirtioInputEvent(type: 1, code: code, value: event.isARepeat ? 2 : 1)
        ])
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        sendKeyboardTracked([VirtioInputEvent(type: 1, code: code, value: 0)])
        let modifiers = keyboardModifierState.reconcile(
            activeModifiers: Self.activeModifiers(event.modifierFlags)
        )
        if !modifiers.isEmpty { sendKeyboardTracked(modifiers) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode),
              let modifier = Self.modifier(macKeyCode: event.keyCode),
              let flag = Self.modifierFlag(modifier) else {
            super.flagsChanged(with: event)
            return
        }
        let events = keyboardModifierState.update(
            modifier: modifier,
            linuxCode: code,
            pressed: event.modifierFlags.contains(flag)
        )
        if !events.isEmpty { sendKeyboardTracked(events) }
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event: event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func mouseDown(with event: NSEvent) { sendMouseButton(event, code: 272, pressed: true) }
    override func mouseUp(with event: NSEvent) { sendMouseButton(event, code: 272, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendMouseButton(event, code: 273, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendMouseButton(event, code: 273, pressed: false) }
    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, code: linuxOtherMouseButton(for: event.buttonNumber), pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, code: linuxOtherMouseButton(for: event.buttonNumber), pressed: false)
    }

    private func sendMouseButton(_ event: NSEvent, code: UInt16, pressed: Bool) {
        sendPointer(event: event, button: code, pressed: pressed)
    }

    private func linuxOtherMouseButton(for buttonNumber: Int) -> UInt16 {
        switch buttonNumber {
        case 2: 274  // BTN_MIDDLE
        case 3: 275  // BTN_SIDE
        default: 276 // BTN_EXTRA
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let events = scrollAccumulator.events(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        ).filter { $0.type != 2 || $0.code == 8 }
        if !events.isEmpty { sendPointerTracked(events) }
    }

    private func sendPointer(
        event: NSEvent,
        button: UInt16? = nil,
        pressed: Bool = false
    ) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let contentRect = scanoutContentRect(in: bounds.size)
        let normalizedX = min(1, max(0, (point.x - contentRect.minX) / max(1, contentRect.width)))
        let normalizedY = min(1, max(0, (point.y - contentRect.minY) / max(1, contentRect.height)))
        let guestPoint = pointerTopology?.normalizedPoint(
            scanoutID: scanoutID,
            localX: normalizedX,
            localY: normalizedY
        ) ?? CGPoint(x: normalizedX, y: normalizedY)
        var frame = [
            VirtioInputEvent(type: 3, code: 0, value: Int32((guestPoint.x * 32_767).rounded())),
            VirtioInputEvent(type: 3, code: 1, value: Int32((guestPoint.y * 32_767).rounded())),
        ]
        if let button {
            frame.append(VirtioInputEvent(type: 1, code: button, value: pressed ? 1 : 0))
        }
        sendPointerTracked(frame)
    }

    func releasePressedInput() {
        let keyboardReleases = pressedKeyboardInput.releaseFrame()
        let pointerReleases = pressedPointerInput.releaseFrame()
        keyboardModifierState.reset()
        scrollAccumulator = VirtioInputScrollAccumulator()
        if !keyboardReleases.isEmpty { keyboardInput.send(frame: keyboardReleases) }
        if !pointerReleases.isEmpty { pointerInput.send(frame: pointerReleases) }
    }

    private func sendKeyboardTracked(_ events: [VirtioInputEvent]) {
        for event in events { pressedKeyboardInput.record(event) }
        keyboardInput.send(frame: events)
    }

    private func sendPointerTracked(_ events: [VirtioInputEvent]) {
        for event in events { pressedPointerInput.record(event) }
        pointerInput.send(frame: events)
    }

    func scanoutContentRect(in targetSize: CGSize) -> CGRect {
        guard scanoutSize.width > 0, scanoutSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return CGRect(origin: .zero, size: targetSize)
        }
        let sourceAspect = scanoutSize.width / scanoutSize.height
        let targetAspect = targetSize.width / targetSize.height
        if targetAspect > sourceAspect {
            let width = targetSize.height * sourceAspect
            return CGRect(
                x: (targetSize.width - width) / 2,
                y: 0,
                width: width,
                height: targetSize.height
            )
        }
        let height = targetSize.width / sourceAspect
        return CGRect(
            x: 0,
            y: (targetSize.height - height) / 2,
            width: targetSize.width,
            height: height
        )
    }

    private static let transparentCursor: NSCursor = {
        let image = NSImage(
            size: NSSize(width: 1, height: 1),
            flipped: false,
            drawingHandler: { _ in true }
        )
        return NSCursor(image: image, hotSpot: .zero)
    }()

    private static func makeCursor(
        _ update: VirtioGPUCursorUpdate,
        scale: CGFloat
    ) -> NSCursor? {
        guard update.width > 0, update.height > 0,
              update.width <= 256, update.height <= 256,
              update.hotX < update.width, update.hotY < update.height,
              update.bytes.count == Int(update.width * update.height * 4),
              let provider = CGDataProvider(data: update.bytes as CFData),
              let image = CGImage(
                  width: Int(update.width),
                  height: Int(update.height),
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Int(update.width) * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                  )),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let cursorImage = NSImage(
            cgImage: image,
            size: NSSize(
                width: CGFloat(update.width) / scale,
                height: CGFloat(update.height) / scale
            )
        )
        return NSCursor(
            image: cursorImage,
            hotSpot: NSPoint(
                x: CGFloat(update.hotX) / scale,
                y: CGFloat(update.hotY) / scale
            )
        )
    }

    private static func modifier(macKeyCode: UInt16) -> DesktopKeyboardModifierState.Modifier? {
        switch macKeyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 57: .capsLock
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }

    private static func modifierFlag(
        _ modifier: DesktopKeyboardModifierState.Modifier
    ) -> NSEvent.ModifierFlags? {
        switch modifier {
        case .command: .command
        case .shift: .shift
        case .capsLock: .capsLock
        case .option: .option
        case .control: .control
        }
    }

    private static func activeModifiers(
        _ flags: NSEvent.ModifierFlags
    ) -> Set<DesktopKeyboardModifierState.Modifier> {
        Set(DesktopKeyboardModifierState.Modifier.allCases.filter {
            guard let flag = modifierFlag($0) else { return false }
            return flags.contains(flag)
        })
    }

    private static func linuxKeyCode(macKeyCode: UInt16) -> UInt16? { keyMap[macKeyCode] }

    private func sendControlShortcut(keyCode: UInt16) {
        keyboardInput.send(frame: [
            VirtioInputEvent(type: 1, code: 125, value: 0),
            VirtioInputEvent(type: 1, code: 126, value: 0),
            VirtioInputEvent(type: 1, code: 29, value: 1),
            VirtioInputEvent(type: 1, code: keyCode, value: 1),
            VirtioInputEvent(type: 1, code: keyCode, value: 0),
            VirtioInputEvent(type: 1, code: 29, value: 0),
        ])
    }

    private static let macCommandShortcutMap: [String: UInt16] = [
        "a": 30, "f": 33, "l": 38, "n": 49, "o": 24, "p": 25,
        "r": 19, "s": 31, "t": 20, "w": 17, "z": 44,
    ]

    private static let keyMap: [UInt16: UInt16] = [
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
        8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19, 16: 21,
        17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6, 24: 13,
        25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27, 31: 24, 32: 22,
        33: 26, 34: 23, 35: 25, 36: 28, 37: 38, 38: 36, 39: 40, 40: 37,
        41: 39, 42: 43, 43: 51, 44: 53, 45: 49, 46: 50, 47: 52, 48: 15,
        49: 57, 50: 41, 51: 14, 53: 1, 54: 126, 55: 125, 56: 42, 57: 58,
        58: 56, 59: 29, 60: 54, 61: 100, 62: 97,
        65: 83, 67: 55, 69: 78, 71: 69, 75: 98, 76: 96, 78: 74, 81: 117,
        82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71,
        91: 72, 92: 73,
        96: 63, 97: 64, 98: 65, 99: 61, 100: 66, 101: 67, 103: 87,
        109: 68, 111: 88, 114: 110, 115: 102, 116: 104, 117: 111, 118: 62,
        119: 107, 120: 60, 121: 109, 122: 59, 123: 105, 124: 106, 125: 108,
        126: 103,
    ]
}

final class DesktopFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let scanoutID: UInt32
    private let coalescer: DesktopScanoutFrameCoalescer
    private var pendingMetalUpdate: VirtioGPUMetalScanoutUpdate?
    /// Displaced authorities are retired synchronously by their producer callback rather than
    /// accumulated while AppKit is stalled. Delivery will not acknowledge any release until these
    /// bounded in-flight calls have returned.
    private var discardOperationsInFlight = 0
    private var pendingReleases = [VirtioGPUScanoutResourceRelease]()
    private var disabled = false
    private var deliveryScheduled = false
    private var presentedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var budgetRejectedFrameCount: UInt64 = 0
    private var receivedFrameByteCount: UInt64 = 0
    private var drainCopyByteCount: UInt64 = 0
    private var uploadedFrameByteCount: UInt64 = 0
    private var droppedFrameByteCount: UInt64 = 0
    private var workerScanoutProgressStages = Set<String>()
    nonisolated(unsafe) weak var view: DesktopDisplayView?

    init(
        scanoutID: UInt32 = 0,
        maximumCPUSurfaceBytes: Int = 128 * 1_024 * 1_024,
        maximumAggregateCPUSurfaceBytes: Int = 256 * 1_024 * 1_024,
        maximumInFlightCPUFrameBytes: Int = 128 * 1_024 * 1_024,
        sharedCPUPresentationBudget: DesktopCPUPresentationBudget = .processDefault
    ) {
        self.scanoutID = scanoutID
        self.coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: maximumCPUSurfaceBytes,
            maximumAggregateSurfaceBytes: maximumAggregateCPUSurfaceBytes,
            maximumDrainBytes: maximumInFlightCPUFrameBytes,
            sharedBudget: sharedCPUPresentationBudget
        )
    }

    func submit(_ frame: VirtioGPUScanoutFrame) {
        lock.lock()
        receivedFrameByteCount = Self.saturatingAdd(
            receivedFrameByteCount,
            UInt64(frame.bytes.count)
        )
        let outcome = frame.scanoutID == scanoutID
            ? coalescer.appendOutcome(frame)
            : .invalid
        guard outcome == .accepted else {
            droppedFrameCount = Self.saturatingAdd(droppedFrameCount, 1)
            droppedFrameByteCount = Self.saturatingAdd(
                droppedFrameByteCount,
                UInt64(frame.bytes.count)
            )
            if outcome == .budgetExceeded {
                budgetRejectedFrameCount = Self.saturatingAdd(budgetRejectedFrameCount, 1)
            }
            lock.unlock()
            return
        }
        disabled = false
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DesktopAppRunLoop.perform { [weak self] in
            self?.deliver()
        }
    }

    /// A worker update carries descriptor authority rather than frame bytes. Only one unpublished
    /// authority may wait for AppKit per scanout; replacement retires the displaced lease before
    /// any resource-release acknowledgement can overtake it.
    func submit(_ update: VirtioGPUMetalScanoutUpdate) {
        logWorkerScanoutProgress(stage: "mailbox-submit")
        lock.lock()
        guard update.scanoutID == scanoutID else {
            lock.unlock()
            update.rejectHostSubmission()
            update.presentation.discardWithoutPresentation()
            return
        }
        let displaced = pendingMetalUpdate
        if displaced != nil { discardOperationsInFlight += 1 }
        pendingMetalUpdate = update
        disabled = false
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if let displaced { retireDisplacedPresentation(displaced) }
        if shouldSchedule {
            logWorkerScanoutProgress(stage: "mailbox-delivery-scheduled")
            scheduleDelivery()
        }
    }

    /// Drop presentation storage only when the guest destroys the corresponding virtio-gpu
    /// resource. Direct scanout temporarily switches between application and compositor buffers;
    /// evicting an older compositor buffer merely because it was not recently visible makes its
    /// next partial update appear as a black or torn frame.
    func release(_ release: VirtioGPUScanoutResourceRelease) {
        lock.lock()
        let removal = coalescer.removeOutcome(
            resourceID: release.resourceID,
            throughGeneration: release.resourceGeneration
        )
        let displacedMetal: VirtioGPUMetalScanoutUpdate?
        if let update = pendingMetalUpdate,
           update.resourceID == release.resourceID,
           update.resourceGeneration <= release.resourceGeneration {
            pendingMetalUpdate = nil
            displacedMetal = update
            discardOperationsInFlight += 1
        } else {
            displacedMetal = nil
        }
        pendingReleases.append(release)
        droppedFrameCount = Self.saturatingAdd(
            droppedFrameCount,
            removal.frameCount
        )
        droppedFrameByteCount = Self.saturatingAdd(
            droppedFrameByteCount,
            removal.payloadByteCount
        )
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if let displacedMetal { retireDisplacedPresentation(displacedMetal) }
        if shouldSchedule { scheduleDelivery() }
    }

    func disable() {
        lock.lock()
        let discarded = coalescer.discardPendingOutcome()
        let displacedMetal = pendingMetalUpdate
        if displacedMetal != nil { discardOperationsInFlight += 1 }
        pendingMetalUpdate = nil
        disabled = true
        droppedFrameCount = Self.saturatingAdd(droppedFrameCount, discarded.frameCount)
        droppedFrameByteCount = Self.saturatingAdd(
            droppedFrameByteCount,
            discarded.payloadByteCount
        )
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if let displacedMetal { retireDisplacedPresentation(displacedMetal) }
        if shouldSchedule { scheduleDelivery() }
    }

    @MainActor
    func deliver() {
        lock.lock()
        guard discardOperationsInFlight == 0 else {
            // The final retiring producer schedules another delivery. Returning keeps AppKit
            // responsive and, critically, prevents a release acknowledgement from overtaking it.
            deliveryScheduled = false
            lock.unlock()
            return
        }
        let pendingDrain = coalescer.takeDrain()
        let metalUpdate = pendingMetalUpdate
        let releases = pendingReleases
        let shouldDisable = disabled
        pendingMetalUpdate = nil
        pendingReleases.removeAll(keepingCapacity: true)
        deliveryScheduled = false
        lock.unlock()
        if metalUpdate != nil {
            logWorkerScanoutProgress(stage: "mailbox-deliver")
        }
        // Sparse materialization can copy accumulated damage. Keep it off the producer lock so a
        // vCPU never waits behind main-thread row packing; the single-update path performs no work.
        let drain = pendingDrain.materialize()
        for release in releases {
            view?.release(
                resourceID: release.resourceID,
                throughGeneration: release.resourceGeneration
            )
            release.acknowledge(scanoutID: scanoutID)
        }
        if shouldDisable {
            view?.disable()
        }
        let frames = drain.frames
        let framePresentation: DesktopCPUFramePresentationResult
        if shouldDisable {
            framePresentation = DesktopCPUFramePresentationResult(
                presented: [Bool](repeating: false, count: frames.count),
                uploadedByteCount: 0
            )
        } else {
            framePresentation = view?.present(frames) ?? DesktopCPUFramePresentationResult(
                presented: [Bool](repeating: false, count: frames.count),
                uploadedByteCount: 0
            )
        }
        var presentedInputs: UInt64 = 0
        var droppedInputs: UInt64 = 0
        var droppedInputBytes: UInt64 = 0
        for batch in drain.batches {
            let complete = batch.frameRange.allSatisfy {
                framePresentation.presented.indices.contains($0)
                    && framePresentation.presented[$0]
            }
            if complete {
                presentedInputs = Self.saturatingAdd(
                    presentedInputs,
                    batch.inputFrameCount
                )
            } else {
                droppedInputs = Self.saturatingAdd(droppedInputs, batch.inputFrameCount)
                droppedInputBytes = Self.saturatingAdd(
                    droppedInputBytes,
                    batch.inputPayloadByteCount
                )
            }
        }
        let presentedMetal: Bool
        if shouldDisable {
            metalUpdate?.rejectHostSubmission()
            metalUpdate?.presentation.discardWithoutPresentation()
            presentedMetal = false
        } else if let metalUpdate {
            logWorkerScanoutProgress(stage: "view-present-enter")
            presentedMetal = view?.present(metalUpdate) == true
            logWorkerScanoutProgress(
                stage: presentedMetal ? "view-present-accepted" : "view-present-rejected"
            )
            if presentedMetal {
                metalUpdate.acceptHostSubmission()
            } else {
                metalUpdate.rejectHostSubmission()
                metalUpdate.presentation.discardWithoutPresentation()
            }
        } else {
            presentedMetal = false
        }
        lock.withLock {
            presentedFrameCount = Self.saturatingAdd(
                presentedFrameCount,
                presentedInputs
                    + (presentedMetal ? 1 : 0)
            )
            droppedFrameCount = Self.saturatingAdd(
                droppedFrameCount,
                droppedInputs
            )
            drainCopyByteCount = Self.saturatingAdd(
                drainCopyByteCount,
                UInt64(drain.copyByteCount)
            )
            uploadedFrameByteCount = Self.saturatingAdd(
                uploadedFrameByteCount,
                framePresentation.uploadedByteCount
            )
            droppedFrameByteCount = Self.saturatingAdd(
                droppedFrameByteCount,
                droppedInputBytes
            )
        }
        if drain.hasMorePendingFrames {
            lock.lock()
            let shouldSchedule = !deliveryScheduled
            if shouldSchedule { deliveryScheduled = true }
            lock.unlock()
            if shouldSchedule { scheduleDelivery() }
        }
    }

    var metrics: DesktopFrameMailboxMetrics {
        lock.withLock {
            let coalescerMetrics = coalescer.metrics
            return DesktopFrameMailboxMetrics(
                presentedFrames: presentedFrameCount,
                droppedFrames: droppedFrameCount,
                budgetRejectedFrames: budgetRejectedFrameCount,
                receivedFrameBytes: receivedFrameByteCount,
                stagingCopyBytes: coalescerMetrics.stagingCopyBytes,
                drainCopyBytes: drainCopyByteCount,
                uploadedFrameBytes: uploadedFrameByteCount,
                droppedFrameBytes: droppedFrameByteCount,
                pendingFrameBytes: UInt64(max(0, coalescerMetrics.residentBytes)),
                pendingFrameDepth: coalescerMetrics.pendingFrameDepth
            )
        }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }

    private func retireDisplacedPresentation(_ update: VirtioGPUMetalScanoutUpdate) {
        update.rejectHostSubmission()
        update.presentation.discardWithoutPresentation()
        finishDisplacedRetirement()
    }

    private func finishDisplacedRetirement() {
        lock.lock()
        discardOperationsInFlight -= 1
        let shouldSchedule = discardOperationsInFlight == 0 && !deliveryScheduled
        if shouldSchedule { deliveryScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleDelivery() }
    }

    private func scheduleDelivery() {
        DesktopAppRunLoop.perform { [weak self] in
            self?.deliver()
        }
    }

    private func logWorkerScanoutProgress(stage: String) {
        let firstOccurrence = lock.withLock {
            workerScanoutProgressStages.insert(stage).inserted
        }
        guard firstOccurrence else { return }
        FileHandle.standardError.write(Data(
            "dory-hv: Metal worker scanout progress scanout=\(scanoutID) stage=\(stage)\n".utf8
        ))
    }
}

/// Moves copied cursor-plane updates from a vCPU thread to AppKit without retaining the guest
/// resource or touching NSCursor off the main thread.
final class DesktopCursorMailbox: @unchecked Sendable {
    nonisolated(unsafe) weak var view: DesktopDisplayView?

    func submit(_ update: VirtioGPUCursorUpdate?) {
        DesktopAppRunLoop.perform { [weak self] in
            self?.view?.presentCursor(update)
        }
    }
}

enum DesktopMetalScanoutLayoutError: Error, Equatable {
    case identityMismatch
    case invalidGeometry
    case metalAlignmentMismatch
    case mappedLengthOverflow
}

/// Transport-independent identity and clipping validated before either a linear SHM texture or a
/// native shared Metal texture can enter the display. The renderer resource generation is kept
/// distinct from the VMM display generation: both must match the update that owns this lease.
struct DesktopMetalScanoutGeometry: Equatable {
    let resourceID: UInt32
    let rendererResourceGeneration: UInt64
    let pixelFormat: MTLPixelFormat
    let width: Int
    let height: Int
    let sourceRect: VirtioGPURect
    let dirtyRect: VirtioGPURect
    let yOriginTop: Bool

    init(
        presentation: VirtioGPUMetalScanoutPresentation,
        expectedScanoutID: UInt32,
        updateScanoutID: UInt32,
        updateResourceID: UInt32,
        updateResourceGeneration: UInt64,
        updateRendererResourceGeneration: UInt64,
        sourceRect: VirtioGPURect,
        dirtyRect: VirtioGPURect
    ) throws {
        guard updateScanoutID == expectedScanoutID,
              updateResourceID == presentation.resourceID,
              updateResourceGeneration != 0,
              updateRendererResourceGeneration == presentation.resourceGeneration else {
            throw DesktopMetalScanoutLayoutError.identityMismatch
        }
        guard DesktopMetalScanoutLayout.containsForCPU(
                sourceRect,
                width: presentation.width,
                height: presentation.height
              ),
              DesktopMetalScanoutLayout.containsForCPU(
                dirtyRect,
                width: sourceRect.width,
                height: sourceRect.height
              ),
              let width = Int(exactly: presentation.width),
              let height = Int(exactly: presentation.height) else {
            throw DesktopMetalScanoutLayoutError.invalidGeometry
        }
        let pixelFormat: MTLPixelFormat = switch presentation.pixelFormat {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba8Unorm: .rgba8Unorm
        }
        self.resourceID = presentation.resourceID
        self.rendererResourceGeneration = presentation.resourceGeneration
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
        self.dirtyRect = dirtyRect
        self.yOriginTop = presentation.yOriginTop
    }
}

/// Revalidates the authenticated worker lease against the concrete host Metal device. The worker
/// contract deliberately permits alignments used by more than one Metal family; publication is
/// accepted only when this device can reconstruct the exact linear texture without a copy.
struct DesktopMetalScanoutLayout: Equatable {
    let pixelFormat: MTLPixelFormat
    let width: Int
    let height: Int
    let stride: Int
    let storageOffset: Int
    let declaredFileSize: Int
    let mappedLength: Int
    let sourceRect: VirtioGPURect
    let dirtyRect: VirtioGPURect
    let yOriginTop: Bool

    init(
        lease: DoryRendererScanoutLease,
        geometry: DesktopMetalScanoutGeometry,
        minimumLinearTextureAlignment: Int,
        pageSize: Int,
        maximumBufferLength: Int
    ) throws {
        guard geometry.resourceID == lease.resourceID,
              geometry.rendererResourceGeneration == lease.resourceGeneration,
              geometry.width == Int(lease.width),
              geometry.height == Int(lease.height),
              geometry.yOriginTop == lease.yOriginTop,
              geometry.pixelFormat == Self.metalPixelFormat(lease.pixelFormat) else {
            throw DesktopMetalScanoutLayoutError.identityMismatch
        }
        guard minimumLinearTextureAlignment > 0,
              let metalAlignment = UInt32(exactly: minimumLinearTextureAlignment),
              pageSize > 0,
              pageSize.nonzeroBitCount == 1,
              lease.stride % metalAlignment == 0,
              lease.storageOffset % UInt64(minimumLinearTextureAlignment) == 0 else {
            throw DesktopMetalScanoutLayoutError.invalidGeometry
        }
        guard Int(exactly: lease.width) != nil,
              Int(exactly: lease.height) != nil,
              let stride = Int(exactly: lease.stride),
              let storageOffset = Int(exactly: lease.storageOffset),
              let declaredFileSize = Int(exactly: lease.declaredFileSize),
              declaredFileSize > 0 else {
            throw DesktopMetalScanoutLayoutError.mappedLengthOverflow
        }
        let remainder = declaredFileSize & (pageSize - 1)
        let padding = remainder == 0 ? 0 : pageSize - remainder
        let (mappedLength, overflow) = declaredFileSize.addingReportingOverflow(padding)
        guard !overflow, mappedLength > 0, mappedLength <= maximumBufferLength else {
            throw DesktopMetalScanoutLayoutError.mappedLengthOverflow
        }
        self.pixelFormat = geometry.pixelFormat
        self.width = geometry.width
        self.height = geometry.height
        self.stride = stride
        self.storageOffset = storageOffset
        self.declaredFileSize = declaredFileSize
        self.mappedLength = mappedLength
        self.sourceRect = geometry.sourceRect
        self.dirtyRect = geometry.dirtyRect
        self.yOriginTop = geometry.yOriginTop
    }

    static func containsForCPU(
        _ rect: VirtioGPURect,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        rect.width > 0
            && rect.height > 0
            && rect.x <= width
            && rect.width <= width - rect.x
            && rect.y <= height
            && rect.height <= height - rect.y
    }

    private static func metalPixelFormat(
        _ pixelFormat: DoryRendererScanoutPixelFormat
    ) -> MTLPixelFormat {
        switch pixelFormat {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba8Unorm: .rgba8Unorm
        }
    }
}

private final class DesktopMetalWorkerLeaseRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private let presentation: VirtioGPUMetalScanoutPresentation
    private var presented = false
    private var retired = false

    init(presentation: VirtioGPUMetalScanoutPresentation) {
        self.presentation = presentation
    }

    func markPresented() {
        lock.withLock {
            guard !retired else { return }
            presented = true
        }
    }

    /// Metal calls this only after its last buffer/texture reference has gone away. Unmapping
    /// first makes the worker release transition exactly follow GPU completion and local resource
    /// destruction, rather than merely following command submission.
    func releaseMapping(_ pointer: UnsafeMutableRawPointer, length: Int) {
        let outcome = lock.withLock { () -> Bool? in
            guard !retired else { return nil }
            retired = true
            return presented
        }
        guard let outcome else { return }
        _ = munmap(pointer, length)
        if outcome {
            presentation.finishPresentation()
        } else {
            presentation.discardWithoutPresentation()
        }
    }

    /// A native shared texture has no CPU mapping to tear down. Its wrapper calls this only after
    /// the command buffer releases its final local texture reference.
    func releaseImportedTexture() {
        let outcome = lock.withLock { () -> Bool? in
            guard !retired else { return nil }
            retired = true
            return presented
        }
        guard let outcome else { return }
        if outcome {
            presentation.finishPresentation()
        } else {
            presentation.discardWithoutPresentation()
        }
    }
}

private final class DesktopMetalWorkerScanout: @unchecked Sendable {
    private var retainedTexture: (any MTLTexture)?
    var texture: any MTLTexture {
        precondition(retainedTexture != nil, "retired Metal worker scanout texture")
        return retainedTexture!
    }
    private let buffer: (any MTLBuffer)?
    private let retirement: DesktopMetalWorkerLeaseRetirement
    private let retiresImportedTextureOnDeinit: Bool

    init(
        texture: any MTLTexture,
        buffer: (any MTLBuffer)?,
        retirement: DesktopMetalWorkerLeaseRetirement,
        retiresImportedTextureOnDeinit: Bool
    ) {
        self.retainedTexture = texture
        self.buffer = buffer
        self.retirement = retirement
        self.retiresImportedTextureOnDeinit = retiresImportedTextureOnDeinit
    }

    func markPresented() {
        retirement.markPresented()
        if retiresImportedTextureOnDeinit {
            retainedTexture = nil
            retirement.releaseImportedTexture()
        }
    }

    deinit {
        if retiresImportedTextureOnDeinit {
            retainedTexture = nil
            retirement.releaseImportedTexture()
        }
    }
}

enum DesktopMetalDisplayError: Error, CustomStringConvertible {
    case deviceUnavailable
    case commandQueueUnavailable
    case shaderCompilationFailed(String)
    case renderPipelineUnavailable(String)
    case samplerUnavailable

    var description: String {
        switch self {
        case .deviceUnavailable:
            "no Metal device is available for the desktop display"
        case .commandQueueUnavailable:
            "could not create the desktop Metal command queue"
        case .shaderCompilationFailed(let detail):
            "could not compile the desktop Metal display shader: \(detail)"
        case .renderPipelineUnavailable(let detail):
            "could not create the desktop Metal render pipeline: \(detail)"
        case .samplerUnavailable:
            "could not create the desktop Metal sampler"
        }
    }
}

/// The production display boundary for both damage-proportional CPU uploads and descriptor-backed
/// worker scanout. Worker pixels remain in their SHM mapping and are sampled directly by Metal;
/// no `Data`, IOSurface, or intermediate frame allocation exists on that path.
@MainActor
final class DesktopMetalView: DesktopDisplayView {
    private struct CPUTexture {
        let texture: any MTLTexture
        let identity: DesktopScanoutResourceIdentity
        let format: UInt32
        let width: UInt32
        let height: UInt32
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private var cpuTextures: [UInt32: CPUTexture] = [:]
    private var currentCPUTexture: CPUTexture?
    private var resourceLifetime = DesktopScanoutResourceLifetime()
    private var deviceFailed = false
    private var workerScanoutDiagnosticStages = Set<String>()
    var onDeviceFailure: (@Sendable (String) -> Void)?
    /// Fires only from a completed Metal command buffer for a worker-issued presentation. The
    /// worker update itself is published only after its producer fence signals.
    var onWorkerPresentationCompleted: (@Sendable (UInt64) -> Void)?

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    init(
        frame: NSRect,
        keyboardInput: VirtioInput,
        pointerInput: VirtioInput,
        guestBackingScaleFactor: CGFloat = 2,
        scanoutID: UInt32 = 0,
        pointerTopology: DesktopPointerTopology? = nil,
        device requestedDevice: (any MTLDevice)? = nil
    ) throws {
        guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice() else {
            throw DesktopMetalDisplayError.deviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw DesktopMetalDisplayError.commandQueueUnavailable
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw DesktopMetalDisplayError.shaderCompilationFailed(error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "doryDesktopVertex"),
              let fragment = library.makeFunction(name: "doryDesktopFragment") else {
            throw DesktopMetalDisplayError.shaderCompilationFailed("required functions missing")
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Dory desktop scanout"
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: any MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw DesktopMetalDisplayError.renderPipelineUnavailable(error.localizedDescription)
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw DesktopMetalDisplayError.samplerUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.sampler = sampler
        super.init(
            frame: frame,
            keyboardInput: keyboardInput,
            pointerInput: pointerInput,
            guestBackingScaleFactor: guestBackingScaleFactor,
            scanoutID: scanoutID,
            pointerTopology: pointerTopology
        )
        wantsLayer = true
        guard let metalLayer = layer as? CAMetalLayer else {
            throw DesktopMetalDisplayError.deviceUnavailable
        }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.presentsWithTransaction = false
        drawableSurfaceDidChange()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawableSurfaceDidChange() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width.rounded()),
            height: max(1, size.height.rounded())
        )
        metalLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }

    override func present(
        _ frames: [VirtioGPUScanoutFrame]
    ) -> DesktopCPUFramePresentationResult {
        guard !deviceFailed else {
            return DesktopCPUFramePresentationResult(
                presented: [Bool](repeating: false, count: frames.count),
                uploadedByteCount: 0
            )
        }
        var presented = [Bool]()
        presented.reserveCapacity(frames.count)
        var uploadedBytes: UInt64 = 0
        for frame in frames {
            let accepted = upload(frame)
            presented.append(accepted)
            if accepted {
                uploadedBytes = Self.saturatingAdd(
                    uploadedBytes,
                    UInt64(frame.dirtyRect.width) * UInt64(frame.dirtyRect.height) * 4
                )
            }
        }
        if presented.contains(true), let currentCPUTexture {
            let committed = render(
                texture: currentCPUTexture.texture,
                sourceRect: VirtioGPURect(
                    x: 0,
                    y: 0,
                    width: currentCPUTexture.width,
                    height: currentCPUTexture.height
                ),
                backingWidth: currentCPUTexture.width,
                backingHeight: currentCPUTexture.height,
                yOriginTop: true,
                workerScanout: nil
            )
            if !committed {
                presented = [Bool](repeating: false, count: presented.count)
            }
        }
        return DesktopCPUFramePresentationResult(
            presented: presented,
            uploadedByteCount: uploadedBytes
        )
    }

    override func present(_ update: VirtioGPUMetalScanoutUpdate) -> Bool {
        logWorkerScanoutProgress(stage: "view-present")
        guard !deviceFailed else {
            logWorkerScanoutRejection(stage: "device-failed")
            return false
        }
        let geometry: DesktopMetalScanoutGeometry
        do {
            geometry = try DesktopMetalScanoutGeometry(
                presentation: update.presentation,
                expectedScanoutID: scanoutID,
                updateScanoutID: update.scanoutID,
                updateResourceID: update.resourceID,
                updateResourceGeneration: update.resourceGeneration,
                updateRendererResourceGeneration: update.rendererResourceGeneration,
                sourceRect: update.sourceRect,
                dirtyRect: update.dirtyRect
            )
        } catch {
            logWorkerScanoutRejection(
                stage: "layout",
                detail: String(describing: error)
            )
            return false
        }
        logWorkerScanoutProgress(stage: "layout-validated")
        let identity = DesktopScanoutResourceIdentity(metalUpdate: update)
        guard resourceLifetime.accepts(identity) else {
            logWorkerScanoutRejection(stage: "resource-lifetime-admission")
            return false
        }
        let workerScanout: DesktopMetalWorkerScanout
        do {
            workerScanout = try importScanout(update: update, geometry: geometry)
        } catch {
            logWorkerScanoutRejection(
                stage: "worker-metal-import",
                detail: String(describing: error)
            )
            return false
        }
        logWorkerScanoutProgress(stage: "worker-metal-imported")
        guard resourceLifetime.bind(identity) else {
            logWorkerScanoutRejection(stage: "resource-lifetime-bind")
            return false
        }
        scanoutSize = CGSize(
            width: Int(update.sourceRect.width),
            height: Int(update.sourceRect.height)
        )
        guard render(
            texture: workerScanout.texture,
            sourceRect: update.sourceRect,
            backingWidth: update.presentation.width,
            backingHeight: update.presentation.height,
            yOriginTop: geometry.yOriginTop,
            workerScanout: workerScanout,
            completion: { [onWorkerPresentationCompleted] completed in
                guard completed else { return }
                onWorkerPresentationCompleted?(
                    update.presentation.workerGeneration.rawValue
                )
            }
        ) else {
            logWorkerScanoutRejection(stage: "render-submission")
            resourceLifetime.unbind()
            return false
        }
        logWorkerScanoutProgress(stage: "metal-command-buffer-committed")
        currentCPUTexture = nil
        return true
    }

    override func release(resourceID: UInt32, throughGeneration: UInt64) {
        if let texture = cpuTextures[resourceID],
           texture.identity.generation <= throughGeneration {
            cpuTextures.removeValue(forKey: resourceID)
        }
        if currentCPUTexture?.identity.resourceID == resourceID,
           let currentCPUTexture,
           currentCPUTexture.identity.generation <= throughGeneration {
            self.currentCPUTexture = nil
        }
        if resourceLifetime.release(
            resourceID: resourceID,
            throughGeneration: throughGeneration
        ) {
            currentCPUTexture = nil
        }
    }

    override func disable() {
        resourceLifetime.unbind()
        currentCPUTexture = nil
        _ = render(
            texture: nil,
            sourceRect: VirtioGPURect(x: 0, y: 0, width: 1, height: 1),
            backingWidth: 1,
            backingHeight: 1,
            yOriginTop: true,
            workerScanout: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let currentCPUTexture else { return }
        _ = render(
            texture: currentCPUTexture.texture,
            sourceRect: VirtioGPURect(
                x: 0,
                y: 0,
                width: currentCPUTexture.width,
                height: currentCPUTexture.height
            ),
            backingWidth: currentCPUTexture.width,
            backingHeight: currentCPUTexture.height,
            yOriginTop: true,
            workerScanout: nil
        )
    }

    private func upload(_ frame: VirtioGPUScanoutFrame) -> Bool {
        let identity = DesktopScanoutResourceIdentity(frame: frame)
        guard let pixelFormat = Self.pixelFormat(for: frame.format),
              frame.scanoutID == scanoutID,
              frame.width > 0, frame.height > 0,
              DesktopMetalScanoutLayout.containsForCPU(
                  frame.dirtyRect,
                  width: frame.width,
                  height: frame.height
              ),
              UInt64(frame.stride) >= UInt64(frame.dirtyRect.width) * 4,
              UInt64(frame.bytes.count)
                >= UInt64(frame.stride) * UInt64(frame.dirtyRect.height),
              resourceLifetime.accepts(identity) else {
            return false
        }
        var texture = cpuTextures[frame.resourceID]
        if texture?.identity != identity
            || texture?.width != frame.width
            || texture?.height != frame.height
            || texture?.format != frame.format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: Int(frame.width),
                height: Int(frame.height),
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let created = device.makeTexture(descriptor: descriptor) else { return false }
            texture = CPUTexture(
                texture: created,
                identity: identity,
                format: frame.format,
                width: frame.width,
                height: frame.height
            )
            cpuTextures[frame.resourceID] = texture
        }
        guard let texture else { return false }
        let region = MTLRegionMake2D(
            Int(frame.dirtyRect.x),
            Int(frame.dirtyRect.y),
            Int(frame.dirtyRect.width),
            Int(frame.dirtyRect.height)
        )
        frame.bytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: Int(frame.stride)
            )
        }
        guard resourceLifetime.bind(identity) else { return false }
        currentCPUTexture = texture
        scanoutSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        return true
    }

    private func importScanout(
        update: VirtioGPUMetalScanoutUpdate,
        geometry: DesktopMetalScanoutGeometry
    ) throws -> DesktopMetalWorkerScanout {
        switch update.presentation.transport {
        case .sharedMemory:
            return try update.presentation.withSharedMemoryScanout { lease, descriptor in
                let layout = try DesktopMetalScanoutLayout(
                    lease: lease,
                    geometry: geometry,
                    minimumLinearTextureAlignment: device.minimumLinearTextureAlignment(
                        for: geometry.pixelFormat
                    ),
                    pageSize: Int(getpagesize()),
                    maximumBufferLength: device.maxBufferLength
                )
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      status.st_size >= 0,
                      UInt64(status.st_size) == lease.declaredFileSize,
                      (status.st_mode & S_IFMT) == S_IFREG
                        || (status.st_mode & S_IFMT) == 0 else {
                    throw DesktopMetalScanoutLayoutError.invalidGeometry
                }
                guard let mapping = mmap(
                    nil,
                    layout.mappedLength,
                    PROT_READ,
                    MAP_SHARED,
                    descriptor,
                    0
                ), mapping != MAP_FAILED else {
                    throw DesktopMetalScanoutLayoutError.invalidGeometry
                }
                let retirement = DesktopMetalWorkerLeaseRetirement(
                    presentation: update.presentation
                )
                guard let buffer = device.makeBuffer(
                    bytesNoCopy: mapping,
                    length: layout.mappedLength,
                    options: [.storageModeShared, .hazardTrackingModeTracked],
                    deallocator: { pointer, length in
                        retirement.releaseMapping(pointer, length: length)
                    }
                ) else {
                    retirement.releaseMapping(mapping, length: layout.mappedLength)
                    throw DesktopMetalScanoutLayoutError.invalidGeometry
                }
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: layout.pixelFormat,
                    width: layout.width,
                    height: layout.height,
                    mipmapped: false
                )
                textureDescriptor.usage = [.shaderRead]
                textureDescriptor.storageMode = .shared
                guard let texture = buffer.makeTexture(
                    descriptor: textureDescriptor,
                    offset: layout.storageOffset,
                    bytesPerRow: layout.stride
                ) else {
                    throw DesktopMetalScanoutLayoutError.metalAlignmentMismatch
                }
                return DesktopMetalWorkerScanout(
                    texture: texture,
                    buffer: buffer,
                    retirement: retirement,
                    retiresImportedTextureOnDeinit: false
                )
            }
        case .sharedTexture:
            return try update.presentation.withSharedTextureHandle { handle in
                guard let texture = device.makeSharedTexture(handle: handle),
                      texture.device === device,
                      texture.textureType == .type2D,
                      texture.pixelFormat == geometry.pixelFormat,
                      texture.width == geometry.width,
                      texture.height == geometry.height,
                      texture.depth == 1,
                      texture.arrayLength == 1,
                      texture.mipmapLevelCount == 1,
                      texture.sampleCount == 1,
                      texture.storageMode == .private,
                      texture.usage.contains(.shaderRead) else {
                    throw DesktopMetalScanoutLayoutError.invalidGeometry
                }
                return DesktopMetalWorkerScanout(
                    texture: texture,
                    buffer: nil,
                    retirement: DesktopMetalWorkerLeaseRetirement(
                        presentation: update.presentation
                    ),
                    retiresImportedTextureOnDeinit: true
                )
            }
        }
    }

    private func render(
        texture: (any MTLTexture)?,
        sourceRect: VirtioGPURect,
        backingWidth: UInt32,
        backingHeight: UInt32,
        yOriginTop: Bool,
        workerScanout: DesktopMetalWorkerScanout?,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) -> Bool {
        guard !deviceFailed else {
            if workerScanout != nil {
                logWorkerScanoutRejection(stage: "render-device-failed")
            }
            return false
        }
        guard let metalLayer = layer as? CAMetalLayer else {
            if workerScanout != nil {
                logWorkerScanoutRejection(stage: "render-layer-unavailable")
            }
            return false
        }
        guard metalLayer.device === device else {
            if workerScanout != nil {
                logWorkerScanoutRejection(stage: "render-device-mismatch")
            }
            return false
        }
        guard let drawable = metalLayer.nextDrawable() else {
            if workerScanout != nil {
                let drawableSize = metalLayer.drawableSize
                logWorkerScanoutRejection(
                    stage: "render-drawable-unavailable",
                    detail: "window=\(window != nil) visible=\(window?.isVisible ?? false) "
                        + "bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
                        + "drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height))"
                )
            }
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            failDevice("Metal command buffer allocation failed")
            return false
        }
        commandBuffer.label = "Dory desktop present"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.025,
            green: 0.03,
            blue: 0.04,
            alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            failDevice("Metal render encoder allocation failed")
            return false
        }
        if let texture {
            let target = scanoutContentRect(in: metalLayer.drawableSize)
            encoder.setViewport(MTLViewport(
                originX: target.minX,
                originY: target.minY,
                width: target.width,
                height: target.height,
                znear: 0,
                zfar: 1
            ))
            var sourceUV = DesktopScanoutTextureCoordinates.sourceUV(
                sourceRect: sourceRect,
                backingWidth: backingWidth,
                backingHeight: backingHeight,
                yOriginTop: yOriginTop
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&sourceUV, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        let failureSink = onDeviceFailure
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status == .completed {
                workerScanout?.markPresented()
                completion?(true)
            } else if let failureSink {
                completion?(false)
                let reason = buffer.error?.localizedDescription
                    ?? "Metal presentation ended with status \(buffer.status.rawValue)"
                failureSink(reason)
            } else {
                completion?(false)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func logWorkerScanoutRejection(stage: String, detail: String = "") {
        let key = "failure:\(stage)"
        guard workerScanoutDiagnosticStages.insert(key).inserted else { return }
        let suffix = detail.isEmpty ? "" : " detail=\(detail)"
        FileHandle.standardError.write(Data(
            "dory-hv: Metal worker scanout rejected stage=\(stage)\(suffix)\n".utf8
        ))
    }

    private func logWorkerScanoutProgress(stage: String) {
        let key = "progress:\(stage)"
        guard workerScanoutDiagnosticStages.insert(key).inserted else { return }
        FileHandle.standardError.write(Data(
            "dory-hv: Metal worker scanout progress scanout=\(scanoutID) stage=\(stage)\n".utf8
        ))
    }

    private func failDevice(_ reason: String) {
        guard !deviceFailed else { return }
        deviceFailed = true
        resourceLifetime.unbind()
        currentCPUTexture = nil
        onDeviceFailure?(reason)
    }

    private static func pixelFormat(for virtioFormat: UInt32) -> MTLPixelFormat? {
        switch virtioFormat {
        case 1, 2: .bgra8Unorm
        case 3, 4, 67, 68, 121, 134: .rgba8Unorm
        default: nil
        }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DoryDesktopVertexOutput {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex DoryDesktopVertexOutput doryDesktopVertex(
        uint vertexID [[vertex_id]],
        constant float4 &sourceUV [[buffer(0)]]) {
        const float2 positions[6] = {
            float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
            float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
        };
        const float2 unitCoordinates[6] = {
            float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
            float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
        };
        DoryDesktopVertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        float2 unit = unitCoordinates[vertexID];
        output.textureCoordinate = float2(
            mix(sourceUV.x, sourceUV.z, unit.x),
            mix(sourceUV.y, sourceUV.w, unit.y));
        return output;
    }

    fragment half4 doryDesktopFragment(
        DoryDesktopVertexOutput input [[stage_in]],
        texture2d<half> source [[texture(0)]],
        sampler sourceSampler [[sampler(0)]]) {
        return source.sample(sourceSampler, input.textureCoordinate);
    }
    """
}
