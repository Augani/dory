import DoryHV
import DoryMachinePC
import DoryVirtio
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
        let shouldDeliver = lock.withLock { () -> Bool in
            guard !deliveredVisibleFrame,
                  Self.containsVisibleContent(converted.bytes) else { return false }
            deliveredVisibleFrame = true
            return true
        }
        if shouldDeliver { onFirstFrame() }
    }

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
}
