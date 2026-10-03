import DoryHV
import DoryMachinePC
import DoryRendererWorkerWireContracts
import DoryVirtio
import DorydKit
import Foundation

/// Publishes AppKit's evdev frames into one DoryPC VirtIO-input function.
final class DoryPCDesktopInputSink: DesktopInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var device: DoryPCVirtioInputPCIDevice

    init(device: DoryPCVirtioInputPCIDevice) {
        self.device = device
    }

    func replaceDevice(_ device: DoryPCVirtioInputPCIDevice) {
        lock.withLock { self.device = device }
    }

    func send(frame events: [VirtioInputEvent]) {
        _ = submit(frame: events)
    }

    @discardableResult
    func submit(frame events: [VirtioInputEvent]) -> Bool {
        guard !events.isEmpty else { return false }
        let current: DoryPCVirtioInputPCIDevice = lock.withLock { self.device }
        return current.enqueueSynchronized(events.map {
            DoryVirtioInputEvent(
                type: $0.type,
                code: $0.code,
                value: UInt32(bitPattern: $0.value)
            )
        })
    }

    func releaseAllPressedKeys() {
        let current = lock.withLock { device }
        current.releaseAllPressedKeys()
    }
}

enum DesktopFrameContent {
    static func containsVisiblePixels(_ bytes: Data) -> Bool {
        let bytesPerPixel = 4
        guard bytes.count >= bytesPerPixel, bytes.count.isMultiple(of: bytesPerPixel) else {
            return false
        }
        let baseline = Array(bytes.prefix(bytesPerPixel))
        var index = bytesPerPixel
        while index < bytes.count {
            if bytes[index] != baseline[0]
                || bytes[index + 1] != baseline[1]
                || bytes[index + 2] != baseline[2]
                || bytes[index + 3] != baseline[3]
            {
                return true
            }
            index += bytesPerPixel
        }
        let nonzero = baseline.filter { $0 != 0 }
        return nonzero.count > 1 || nonzero.contains { $0 != 0xff }
    }
}

/// Converts DoryPC's complete transport-neutral resource snapshot into the bounded dirty-row
/// representation already consumed by the native Metal desktop mailbox.
struct DoryPCSoftwareDisplayMetrics: Equatable, Sendable {
    var receivedFrames: UInt64 = 0
    var visibleFrames: UInt64 = 0
    var receivedFrameBytes: UInt64 = 0
}

final class DoryPCSoftwareDisplaySink: DoryVirtioGPUDisplaySink, @unchecked Sendable {
    private struct ResourceIdentity: Equatable {
        let generation: UInt64
        let width: UInt32
        let height: UInt32
        let format: DoryVirtioGPUFormat
    }

    private let lock = NSLock()
    private let publishFrame: @Sendable (VirtioGPUScanoutFrame) -> Void
    private let releaseFrame: @Sendable (UInt32, UInt64) -> Void
    private let publishCursor: @Sendable (VirtioGPUCursorUpdate?) -> Void
    private let hideCursor: @Sendable (UInt32) -> Void
    private let onFirstFrame: @Sendable () -> Void
    private var identities = [UInt32: ResourceIdentity]()
    private var generations = [UInt32: UInt64]()
    private var invalidatedResources = Set<UInt32>()
    private var resourceAdmissionExhausted = false
    private static let maximumTrackedResourceIDs = 1_048_576
    private var deliveredVisibleFrame = false
    private var metricStorage = DoryPCSoftwareDisplayMetrics()

    init(
        mailbox: DesktopFrameMailbox,
        publishCursor: @escaping @Sendable (VirtioGPUCursorUpdate?) -> Void = { _ in },
        onFirstFrame: @escaping @Sendable () -> Void = {}
    ) {
        self.publishFrame = { frame in mailbox.submit(frame) }
        self.releaseFrame = { resourceID, resourceGeneration in
            mailbox.release(VirtioGPUScanoutResourceRelease(
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                scanoutCount: 1,
                completion: {}
            ))
        }
        self.publishCursor = publishCursor
        self.hideCursor = { _ in publishCursor(nil) }
        self.onFirstFrame = onFirstFrame
    }

    init(
        publishFrame: @escaping @Sendable (VirtioGPUScanoutFrame) -> Void,
        releaseFrame: @escaping @Sendable (UInt32, UInt64) -> Void = { _, _ in },
        publishCursor: @escaping @Sendable (VirtioGPUCursorUpdate?) -> Void = { _ in },
        hideCursor: (@Sendable (UInt32) -> Void)? = nil,
        onFirstFrame: @escaping @Sendable () -> Void = {}
    ) {
        self.publishFrame = publishFrame
        self.releaseFrame = releaseFrame
        self.publishCursor = publishCursor
        self.hideCursor = hideCursor ?? { _ in publishCursor(nil) }
        self.onFirstFrame = onFirstFrame
    }

    func presentCursor(_ update: DoryVirtioGPUCursorUpdate) {
        guard update.resourceID != 0 else {
            hideCursor(update.scanoutID)
            return
        }
        guard update.bytes.count == 64 * 64 * 4 else { return }
        publishCursor(VirtioGPUCursorUpdate(
            scanoutID: update.scanoutID,
            resourceID: update.resourceID,
            x: update.x,
            y: update.y,
            width: 64,
            height: 64,
            hotX: update.hotX,
            hotY: update.hotY,
            bytes: Data(update.bytes)
        ))
    }

    func present(_ frame: DoryVirtioGPUFrame) {
        guard let converted = convert(frame) else { return }
        publishFrame(converted)
        lock.withLock {
            metricStorage.receivedFrames = Self.saturatingAdd(metricStorage.receivedFrames, 1)
            metricStorage.receivedFrameBytes = Self.saturatingAdd(
                metricStorage.receivedFrameBytes,
                UInt64(converted.bytes.count)
            )
        }
    }

    /// A submitted frame is not evidence of a working host display. The mailbox calls this only
    /// after AppKit's display view accepts the CPU frame for Metal upload.
    func hostDidPresent(_ frame: VirtioGPUScanoutFrame) {
        hostDidPresent(
            resourceID: frame.resourceID,
            resourceGeneration: frame.resourceGeneration,
            visibleContent: Self.containsVisibleContent(frame.bytes)
        )
    }

    func hostDidPresent(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        visibleContent: Bool
    ) {
        guard visibleContent else { return }
        let shouldDeliver = lock.withLock { () -> Bool in
            guard generations[resourceID] == resourceGeneration,
                  !invalidatedResources.contains(resourceID) else { return false }
            metricStorage.visibleFrames = Self.saturatingAdd(metricStorage.visibleFrames, 1)
            guard !deliveredVisibleFrame else { return false }
            deliveredVisibleFrame = true
            return true
        }
        if shouldDeliver { onFirstFrame() }
    }

    /// A reset invalidates every old presentation, but the semantic GPU owns the next incarnation
    /// number. Do not synthesize a number from geometry or reuse an old frame's generation.
    func resetResources() {
        lock.withLock {
            invalidatedResources.formUnion(generations.keys)
        }
    }

    func retireResource(resourceID: UInt32, resourceGeneration: UInt64) {
        let shouldRelease = lock.withLock { () -> Bool in
            let current = generations[resourceID] ?? 0
            guard resourceGeneration >= current else { return false }
            if resourceGeneration == current,
               invalidatedResources.contains(resourceID) { return false }
            let hadPresentedFrame = generations[resourceID] != nil
            if generations[resourceID] == nil,
               generations.count >= Self.maximumTrackedResourceIDs {
                resourceAdmissionExhausted = true
                return hadPresentedFrame
            }
            generations[resourceID] = resourceGeneration
            invalidatedResources.insert(resourceID)
            return hadPresentedFrame
        }
        if shouldRelease { releaseFrame(resourceID, resourceGeneration) }
    }

    var metrics: DoryPCSoftwareDisplayMetrics { lock.withLock { metricStorage } }

    /// A modeset commonly flushes one uniformly cleared resource before firmware or a bootloader
    /// has drawn anything. Keep the startup presentation over that clear instead of turning a
    /// healthy translated boot into an unexplained blank window. Variation is visible regardless
    /// of channel order; a uniform pixel is visible when it contains color rather than only an
    /// opaque alpha/X byte.
    static func containsVisibleContent(_ bytes: Data) -> Bool {
        DesktopFrameContent.containsVisiblePixels(bytes)
    }

    func convert(_ frame: DoryVirtioGPUFrame) -> VirtioGPUScanoutFrame? {
        let bytesPerPixel = UInt64(frame.format.bytesPerPixel)
        let (resourceRowBytes, rowOverflow) = UInt64(frame.resourceWidth)
            .multipliedReportingOverflow(by: bytesPerPixel)
        let (resourceByteCount, resourceOverflow) = resourceRowBytes
            .multipliedReportingOverflow(by: UInt64(frame.resourceHeight))
        guard frame.resourceID != 0, frame.resourceGeneration > 0,
              frame.resourceWidth > 0,
              frame.resourceHeight > 0,
              !rowOverflow, !resourceOverflow,
              resourceByteCount <= UInt64(Int.max),
              UInt64(frame.pixels.count) == resourceByteCount else { return nil }

        let scanout = frame.scanoutRectangle
        let damage = frame.damagedRectangle
        guard let scanoutMaxX = Self.sum(scanout.x, scanout.width),
              let scanoutMaxY = Self.sum(scanout.y, scanout.height),
              let damageMaxX = Self.sum(damage.x, damage.width),
              let damageMaxY = Self.sum(damage.y, damage.height),
              scanout.width > 0,
              scanout.height > 0,
              scanoutMaxX <= frame.resourceWidth,
              scanoutMaxY <= frame.resourceHeight else { return nil }

        let left = max(scanout.x, damage.x)
        let top = max(scanout.y, damage.y)
        let right = min(scanoutMaxX, damageMaxX)
        let bottom = min(scanoutMaxY, damageMaxY)
        guard right > left, bottom > top else { return nil }

        // The relay retains a full surface, even when only a small dirty rectangle is sent.
        // Reject an oversized scanout before allocating a second dirty-frame copy.
        guard Self.canRelayScanout(
            width: scanout.width, height: scanout.height, bytesPerPixel: bytesPerPixel
        ) else {
            return nil
        }

        let dirtyWidth = right - left
        let dirtyHeight = bottom - top
        let (dirtyRowBytes, dirtyRowOverflow) = UInt64(dirtyWidth)
            .multipliedReportingOverflow(by: bytesPerPixel)
        let (outputByteCount, outputOverflow) = dirtyRowBytes
            .multipliedReportingOverflow(by: UInt64(dirtyHeight))
        guard !dirtyRowOverflow, !outputOverflow,
              dirtyRowBytes <= UInt64(UInt32.max),
              outputByteCount <= UInt64(Int.max) else {
            return nil
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(outputByteCount))
        for row in top..<bottom {
            let (rowStart, rowOffsetOverflow) = UInt64(row)
                .multipliedReportingOverflow(by: resourceRowBytes)
            let (columnStart, columnOffsetOverflow) = UInt64(left)
                .multipliedReportingOverflow(by: bytesPerPixel)
            let (offset, offsetOverflow) = rowStart.addingReportingOverflow(columnStart)
            let (end, endOverflow) = offset.addingReportingOverflow(dirtyRowBytes)
            guard !rowOffsetOverflow, !columnOffsetOverflow, !offsetOverflow, !endOverflow,
                  end <= UInt64(frame.pixels.count) else { return nil }
            bytes.append(contentsOf: frame.pixels[Int(offset)..<Int(end)])
        }

        let admitted = lock.withLock { () -> Bool in
            guard !resourceAdmissionExhausted else { return false }
            if generations[frame.resourceID] == nil,
               generations.count >= Self.maximumTrackedResourceIDs {
                resourceAdmissionExhausted = true
                return false
            }
            let current = generations[frame.resourceID] ?? 0
            guard frame.resourceGeneration >= current,
                  (!invalidatedResources.contains(frame.resourceID)
                    || frame.resourceGeneration > current) else { return false }
            let identity = ResourceIdentity(
                generation: frame.resourceGeneration,
                width: frame.resourceWidth,
                height: frame.resourceHeight,
                format: frame.format
            )
            if let previous = identities[frame.resourceID],
               previous.generation == identity.generation,
               previous != identity { return false }
            identities[frame.resourceID] = identity
            generations[frame.resourceID] = frame.resourceGeneration
            invalidatedResources.remove(frame.resourceID)
            return true
        }
        guard admitted else { return nil }
        return VirtioGPUScanoutFrame(
            scanoutID: frame.scanoutID,
            resourceID: frame.resourceID,
            resourceGeneration: frame.resourceGeneration,
            format: frame.format.rawValue,
            width: scanout.width,
            height: scanout.height,
            stride: UInt32(dirtyRowBytes),
            dirtyRect: VirtioGPURect(
                x: left - scanout.x,
                y: top - scanout.y,
                width: dirtyWidth,
                height: dirtyHeight
            ),
            bytes: bytes
        )
    }

    private static func sum(_ lhs: UInt32, _ rhs: UInt32) -> UInt32? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    static func canRelayScanout(
        width: UInt32, height: UInt32, bytesPerPixel: UInt64
    ) -> Bool {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return false }
        let (rowBytes, rowOverflow) = UInt64(width)
            .multipliedReportingOverflow(by: bytesPerPixel)
        let (surfaceBytes, surfaceOverflow) = rowBytes
            .multipliedReportingOverflow(by: UInt64(height))
        return !rowOverflow && !surfaceOverflow
            && surfaceBytes <= DoryRendererWorkerLimits.production.maximumScanoutBytes
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }
}

/// Publishes enough live DoryPC execution and display truth to diagnose a translated boot without
/// requiring guest tools or debugger attachment. The sampler observes only bounded counters; the
/// lifecycle server remains the authority for when and to whom a snapshot is disclosed.
final class DoryPCDeviceTelemetrySampler: @unchecked Sendable {
    struct Source: Sendable {
        let execution: DoryPCExecutionStatistics
        let graphics: DoryVirtioGPUCommandDiagnostics
        let display: DoryPCSoftwareDisplayMetrics?
    }

    private let machineID: String
    private let operationID: String
    private let source: @Sendable () -> Source
    private let lock = NSLock()
    private var sampleSequence: UInt64 = 0

    init(
        machineID: String,
        operationID: UUID,
        source: @escaping @Sendable () -> Source
    ) {
        self.machineID = machineID
        self.operationID = DoryOperationIdentity.canonical(operationID)
        self.source = source
    }

    func snapshot() -> DoryDeviceTelemetrySnapshot {
        let sequence = lock.withLock { () -> UInt64 in
            sampleSequence = sampleSequence == UInt64.max ? 1 : sampleSequence + 1
            return sampleSequence
        }
        let current = source()
        let execution = current.execution
        let totalInstructions = Self.saturatingSum([
            execution.interpreterInstructions,
            execution.baselineJITInstructions,
            execution.optimizingJITInstructions,
        ])
        let graphicsHealth: DoryDeviceTelemetryHealth =
            current.graphics.failedCommandCount == 0 ? .healthy : .degraded
        let displayMetrics: [DoryDeviceTelemetryMetric]
        if let display = current.display {
            displayMetrics = [
                .measured(.displayFrames, value: display.receivedFrames),
                .measured(.displayVisibleFrames, value: display.visibleFrames),
                .measured(.displayReceivedFrameBytes, value: display.receivedFrameBytes),
            ]
        } else {
            let reason = "headless launch has no presentation surface"
            displayMetrics = [
                .unavailable(.displayFrames, reason: reason),
                .unavailable(.displayVisibleFrames, reason: reason),
                .unavailable(.displayReceivedFrameBytes, reason: reason),
            ]
        }
        return DoryDeviceTelemetrySnapshot(
            machineID: machineID,
            operationID: operationID,
            backend: .doryHypervisor,
            sampleSequence: sequence,
            sampledAtUnixMilliseconds: UInt64(max(
                1,
                Int64(Date().timeIntervalSince1970 * 1_000)
            )),
            monotonicNanoseconds: max(1, DispatchTime.now().uptimeNanoseconds),
            devices: [
                DoryDeviceTelemetryDevice(
                    id: "dorypc-execution",
                    kind: .platform,
                    health: .healthy,
                    metrics: [
                        .measured(.guestInstructions, value: totalInstructions),
                        .measured(
                            .interpreterInstructions,
                            value: execution.interpreterInstructions
                        ),
                        .measured(
                            .baselineJITInstructions,
                            value: execution.baselineJITInstructions
                        ),
                        .measured(.baselineJITBlocks, value: execution.baselineJITBlocks),
                        .measured(
                            .optimizingJITInstructions,
                            value: execution.optimizingJITInstructions
                        ),
                        .measured(.optimizingJITBlocks, value: execution.optimizingJITBlocks),
                    ]
                ),
                DoryDeviceTelemetryDevice(
                    id: "dorypc-display-0",
                    kind: .graphics,
                    health: graphicsHealth,
                    metrics: [
                        .measured(
                            .graphicsCommands,
                            value: current.graphics.completedCommandCount
                        ),
                        .measured(
                            .graphicsCommandFailures,
                            value: current.graphics.failedCommandCount
                        ),
                        .measured(.deviceResets, value: current.graphics.resetCount),
                    ] + displayMetrics
                ),
            ]
        )
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { value, increment in
            let (sum, overflow) = value.addingReportingOverflow(increment)
            return overflow ? UInt64.max : sum
        }
    }
}
