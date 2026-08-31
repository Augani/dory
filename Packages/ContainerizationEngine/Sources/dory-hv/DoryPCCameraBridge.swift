import CoreGraphics
import DoryHostCamera
import DoryMachinePC
import Foundation
import ImageIO

/// Connects the separately authorized Mac camera source to DoryPC's standards-based USB UVC
/// function. Linux sees an ordinary xHCI camera and therefore needs no Dory-specific camera driver.
final class DoryPCCameraBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "dev.dory.dory-hv.dorypc.camera",
        qos: .userInitiated
    )
    private let backend: DoryMacCameraBackend
    private let device: DoryPCUSBUVCDevice
    private var requestInFlight = false
    private var stopped = false

    init(
        width: UInt16 = 1_280,
        height: UInt16 = 720,
        framesPerSecond: UInt32 = 30,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        backend = DoryMacCameraBackend(log: log)
        device = try DoryPCUSBUVCDevice(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
        )
        _ = try backend.prepareAndAuthorize()
        device.setFrameDemandHandler { [weak self] in self?.requestFrame() }
    }

    func attach(to controller: DoryPCXHCIController, port: Int = 1) throws {
        try controller.connect(port: port, device: device)
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        device.setFrameDemandHandler(nil)
        device.cancelAll()
        backend.stop()
    }

    deinit { stop() }

    private func requestFrame() {
        let shouldRequest = lock.withLock { () -> Bool in
            guard !stopped, !requestInFlight else { return false }
            requestInFlight = true
            return true
        }
        guard shouldRequest else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.requestInFlight = false } }
            guard let jpeg = self.backend.nextJPEGFrame(
                width: Int(self.device.width),
                height: Int(self.device.height),
                timeout: 2
            ), let frame = Self.yuy2(
                jpeg: jpeg,
                width: Int(self.device.width),
                height: Int(self.device.height)
            ), !self.lock.withLock({ self.stopped }) else { return }
            try? self.device.enqueueNewestYUY2Frame(frame)
        }
    }

    static func yuy2(jpeg: Data, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, width.isMultiple(of: 2),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let rowBytes = width * 4
        var rgba = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var output = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 2) {
                let first = y * rowBytes + x * 4
                let second = first + 4
                let r0 = Int(rgba[first])
                let g0 = Int(rgba[first + 1])
                let b0 = Int(rgba[first + 2])
                let r1 = Int(rgba[second])
                let g1 = Int(rgba[second + 1])
                let b1 = Int(rgba[second + 2])
                let destination = (y * width + x) * 2
                output[destination] = clamp(((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16)
                output[destination + 1] = clamp(
                    (((-38 * (r0 + r1) - 74 * (g0 + g1) + 112 * (b0 + b1) + 256) >> 9) + 128)
                )
                output[destination + 2] = clamp(((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16)
                output[destination + 3] = clamp(
                    (((112 * (r0 + r1) - 94 * (g0 + g1) - 18 * (b0 + b1) + 256) >> 9) + 128)
                )
            }
        }
        return output
    }

    private static func clamp(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }
}
