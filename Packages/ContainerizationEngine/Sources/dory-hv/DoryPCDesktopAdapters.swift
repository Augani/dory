import DoryHV
import DoryMachinePC
import DoryVirtio
import Foundation

/// Publishes AppKit's evdev frames into one DoryPC VirtIO-input function.
final class DoryPCDesktopInputSink: DesktopInputSink, @unchecked Sendable {
    private let device: DoryPCVirtioInputPCIDevice

    init(device: DoryPCVirtioInputPCIDevice) {
        self.device = device
    }

    func send(frame events: [VirtioInputEvent]) {
        guard !events.isEmpty else { return }
        _ = device.enqueueSynchronized(events.map {
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
        onFirstFrame()
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
