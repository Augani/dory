import DoryHV
import DoryMachinePC
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
        guard !events.isEmpty else { return }
        let current: DoryPCVirtioInputPCIDevice = lock.withLock { self.device }
        _ = current.enqueueSynchronized(events.map {
            DoryVirtioInputEvent(
                type: $0.type,
                code: $0.code,
                value: UInt32(bitPattern: $0.value)
            )
        })
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
        let width: UInt32
        let height: UInt32
        let format: DoryVirtioGPUFormat
    }

    private let lock = NSLock()
    private let mailbox: DesktopFrameMailbox
    private let onFirstFrame: @Sendable () -> Void
    private var identities = [UInt32: ResourceIdentity]()
    private var generations = [UInt32: UInt64]()
    private var deliveredVisibleFrame = false
    private var metricStorage = DoryPCSoftwareDisplayMetrics()

    init(
        mailbox: DesktopFrameMailbox,
        onFirstFrame: @escaping @Sendable () -> Void = {}
    ) {
        self.mailbox = mailbox
        self.onFirstFrame = onFirstFrame
    }

    func present(_ frame: DoryVirtioGPUFrame) {
        guard let converted = convert(frame) else { return }
        mailbox.submit(converted)
        let visible = Self.containsVisibleContent(converted.bytes)
        let shouldDeliver = lock.withLock { () -> Bool in
            metricStorage.receivedFrames = Self.saturatingAdd(metricStorage.receivedFrames, 1)
            metricStorage.receivedFrameBytes = Self.saturatingAdd(
                metricStorage.receivedFrameBytes,
                UInt64(converted.bytes.count)
            )
            if visible {
                metricStorage.visibleFrames = Self.saturatingAdd(metricStorage.visibleFrames, 1)
            }
            guard !deliveredVisibleFrame, visible else { return false }
            deliveredVisibleFrame = true
            return true
        }
        if shouldDeliver { onFirstFrame() }
    }

    var metrics: DoryPCSoftwareDisplayMetrics { lock.withLock { metricStorage } }

    /// A modeset commonly flushes one uniformly cleared resource before firmware or a bootloader
    /// has drawn anything. Keep the startup presentation over that clear instead of turning a
    /// healthy translated boot into an unexplained blank window. Variation is visible regardless
    /// of channel order; a uniform pixel is visible when it contains color rather than only an
    /// opaque alpha/X byte.
    static func containsVisibleContent(_ bytes: Data) -> Bool {
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

    func convert(_ frame: DoryVirtioGPUFrame) -> VirtioGPUScanoutFrame? {
        let bytesPerPixel = UInt64(frame.format.bytesPerPixel)
        let resourceRowBytes = UInt64(frame.resourceWidth) * bytesPerPixel
        let resourceByteCount = resourceRowBytes * UInt64(frame.resourceHeight)
        guard frame.resourceWidth > 0,
              frame.resourceHeight > 0,
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

        let dirtyWidth = right - left
        let dirtyHeight = bottom - top
        let dirtyRowBytes = UInt64(dirtyWidth) * bytesPerPixel
        let outputByteCount = dirtyRowBytes * UInt64(dirtyHeight)
        guard dirtyRowBytes <= UInt64(UInt32.max), outputByteCount <= UInt64(Int.max) else {
            return nil
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(outputByteCount))
        for row in top..<bottom {
            let offset = UInt64(row) * resourceRowBytes + UInt64(left) * bytesPerPixel
            let end = offset + dirtyRowBytes
            guard end <= UInt64(frame.pixels.count) else { return nil }
            bytes.append(contentsOf: frame.pixels[Int(offset)..<Int(end)])
        }

        let identity = ResourceIdentity(
            width: frame.resourceWidth,
            height: frame.resourceHeight,
            format: frame.format
        )
        let generation = lock.withLock { () -> UInt64 in
            if identities[frame.resourceID] != identity {
                identities[frame.resourceID] = identity
                let next = (generations[frame.resourceID] ?? 0) &+ 1
                generations[frame.resourceID] = next == 0 ? 1 : next
            }
            return generations[frame.resourceID] ?? 1
        }
        return VirtioGPUScanoutFrame(
            scanoutID: frame.scanoutID,
            resourceID: frame.resourceID,
            resourceGeneration: generation,
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
