@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import DoryHV
import Foundation
import ImageIO

enum DoryMacCameraError: Error, CustomStringConvertible {
    case permissionDenied
    case permissionRestricted
    case permissionTimedOut
    case unavailable
    case inputCreationFailed(String)
    case cannotAttachInput
    case cannotAttachOutput
    case startFailed

    var description: String {
        switch self {
        case .permissionDenied:
            "Mac camera access is denied. Enable Dory Desktop in System Settings > Privacy & Security > Camera, or disable Camera for this desktop."
        case .permissionRestricted:
            "Mac camera access is restricted by system policy. Disable Camera for this desktop or ask the Mac administrator to allow it."
        case .permissionTimedOut:
            "Mac camera permission was not resolved in time. Try again and answer the macOS permission prompt, or disable Camera for this desktop."
        case .unavailable:
            "No usable Mac camera is available. Connect or enable a camera, or disable Camera for this desktop."
        case .inputCreationFailed(let detail):
            "The selected Mac camera could not be opened: \(detail)"
        case .cannotAttachInput:
            "The Mac camera input could not be attached to the capture session."
        case .cannotAttachOutput:
            "The Mac camera output could not be attached to the capture session."
        case .startFailed:
            "The Mac camera capture session did not start."
        }
    }
}

/// Permission-aware AVFoundation source for the standard UVC device exported to Linux. Capture and
/// JPEG conversion run off the AppKit thread. The physical camera starts lazily on the first guest
/// video read and stops after the guest stream goes idle, matching the privacy lifecycle of a local
/// camera instead of holding the device for the VM's whole lifetime.
final class DoryMacCameraBackend: NSObject, DoryUVCCameraFrameSource,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let condition = NSCondition()
    private let captureQueue = DispatchQueue(
        label: "com.dory.desktop.camera.capture",
        qos: .userInitiated
    )
    // AVCaptureSession start/stop and graph mutation are blocking operations. Keep them on one
    // serial queue so a VM teardown can never race a still-configuring camera session.
    private let sessionQueue = DispatchQueue(
        label: "com.dory.desktop.camera.session",
        qos: .userInitiated
    )
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let log: @Sendable (String) -> Void
    private var latestJPEG: Data?
    private var generation: UInt64 = 0
    private var deliveredGeneration: UInt64 = 0
    private var requestedWidth = 1_280
    private var requestedHeight = 720
    private var idleGeneration: UInt64 = 0
    private var waitingConsumers = 0
    private var prepared = false
    private var captureRunning = false
    private var stopped = false

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        super.init()
    }

    func prepareAndAuthorize(permissionTimeout: TimeInterval = 60) throws {
        try Self.requireAuthorization(timeout: permissionTimeout)
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw DoryMacCameraError.unavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw DoryMacCameraError.inputCreationFailed(String(describing: error))
        }

        try sessionQueue.sync {
            condition.lock()
            let mayPrepare = !stopped
            condition.unlock()
            guard mayPrepare else { throw DoryMacCameraError.startFailed }
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw DoryMacCameraError.cannotAttachInput
            }
            session.addInput(input)
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                throw DoryMacCameraError.cannotAttachOutput
            }
            session.addOutput(output)
            session.commitConfiguration()

            condition.lock()
            guard !stopped else {
                condition.unlock()
                throw DoryMacCameraError.startFailed
            }
            prepared = true
            condition.broadcast()
            condition.unlock()
        }
        log("dory-hv desktop: Dory UVC Camera ready (\(device.localizedName))")
    }

    func nextJPEGFrame(width: Int, height: Int, timeout: TimeInterval) -> Data? {
        guard (width == 640 && height == 480) || (width == 1_280 && height == 720) else {
            return nil
        }
        guard ensureCaptureRunning() else { return nil }
        let deadline = Date().addingTimeInterval(max(0.001, min(timeout, 2)))
        condition.lock()
        guard captureRunning, !stopped else {
            condition.unlock()
            return nil
        }
        if requestedWidth != width || requestedHeight != height {
            requestedWidth = width
            requestedHeight = height
            latestJPEG = nil
            deliveredGeneration = generation
        }
        waitingConsumers += 1
        defer {
            waitingConsumers -= 1
            idleGeneration &+= 1
            let idleToken = idleGeneration
            let shouldScheduleIdleRelease = waitingConsumers == 0 && !stopped
            condition.unlock()
            if shouldScheduleIdleRelease {
                scheduleIdleRelease(token: idleToken)
            }
        }
        while !stopped, captureRunning, generation == deliveredGeneration {
            guard condition.wait(until: deadline) else { return nil }
        }
        guard !stopped, captureRunning,
              generation != deliveredGeneration, let latestJPEG else { return nil }
        deliveredGeneration = generation
        return latestJPEG
    }

    func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        prepared = false
        captureRunning = false
        idleGeneration &+= 1
        latestJPEG = nil
        condition.broadcast()
        condition.unlock()
        output.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
        }
        log("dory-hv desktop: Mac camera stopped")
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        condition.lock()
        let shouldEncode = captureRunning && !stopped && waitingConsumers > 0
        let targetWidth = requestedWidth
        let targetHeight = requestedHeight
        condition.unlock()
        guard shouldEncode, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let image = Self.centerCroppedImage(
            CIImage(cvPixelBuffer: pixelBuffer),
            width: targetWidth,
            height: targetHeight
        )
        guard let jpeg = imageContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [
                CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                ): 0.82,
            ]
        ), !jpeg.isEmpty, jpeg.count <= 1_280 * 720 * 2 else {
            return
        }
        condition.lock()
        if !stopped {
            latestJPEG = jpeg
            generation &+= 1
            condition.broadcast()
        }
        condition.unlock()
    }

    private static func centerCroppedImage(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        let sourceExtent = image.extent
        let scale = max(targetWidth / sourceExtent.width, targetHeight / sourceExtent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: scaled.extent.midX - targetWidth / 2,
            y: scaled.extent.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        return scaled.cropped(to: crop).transformed(
            by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        )
    }

    deinit {
        stop()
    }

    private func ensureCaptureRunning() -> Bool {
        sessionQueue.sync {
            condition.lock()
            guard prepared, !stopped else {
                condition.unlock()
                return false
            }
            if captureRunning {
                condition.unlock()
                return true
            }
            latestJPEG = nil
            deliveredGeneration = generation
            condition.unlock()

            session.startRunning()
            let didStart = session.isRunning

            condition.lock()
            if stopped {
                condition.unlock()
                if session.isRunning { session.stopRunning() }
                return false
            }
            captureRunning = didStart
            condition.broadcast()
            condition.unlock()
            if didStart {
                log("dory-hv desktop: Mac camera capture started")
            }
            return didStart
        }
    }

    private func scheduleIdleRelease(token: UInt64) {
        sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            let shouldRelease = !self.stopped
                && self.captureRunning
                && self.waitingConsumers == 0
                && self.idleGeneration == token
            if shouldRelease {
                self.captureRunning = false
                self.latestJPEG = nil
                self.deliveredGeneration = self.generation
                self.condition.broadcast()
            }
            self.condition.unlock()
            if shouldRelease, self.session.isRunning {
                self.session.stopRunning()
                self.log("dory-hv desktop: Mac camera capture released after guest stream idle")
            }
        }
    }

    private static func requireAuthorization(timeout: TimeInterval) throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .denied:
            throw DoryMacCameraError.permissionDenied
        case .restricted:
            throw DoryMacCameraError.permissionRestricted
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let result = LockedCameraAuthorization()
            AVCaptureDevice.requestAccess(for: .video) { granted in
                result.set(granted)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + max(1, min(timeout, 120))) == .success else {
                throw DoryMacCameraError.permissionTimedOut
            }
            guard result.value else { throw DoryMacCameraError.permissionDenied }
        @unknown default:
            throw DoryMacCameraError.permissionRestricted
        }
    }
}

private final class LockedCameraAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func set(_ value: Bool) {
        lock.lock()
        granted = value
        lock.unlock()
    }
}
