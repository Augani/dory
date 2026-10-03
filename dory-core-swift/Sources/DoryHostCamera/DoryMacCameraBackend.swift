@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

public enum DoryMacCameraError: Error, Sendable, CustomStringConvertible {
    case permissionDenied
    case permissionRestricted
    case permissionTimedOut
    case unavailable
    case selectedDeviceUnavailable
    case deviceInUse
    case leaseFailed
    case inputCreationFailed(String)
    case cannotAttachInput
    case cannotAttachOutput
    case startFailed
    case unsupportedDimensions(Int, Int)
    case frameTimedOut

    public var description: String {
        switch self {
        case .permissionDenied:
            "Mac camera access is denied. Enable Dory Desktop in System Settings > Privacy & Security > Camera, or disable Camera for this desktop."
        case .permissionRestricted:
            "Mac camera access is restricted by system policy. Disable Camera for this desktop or ask the Mac administrator to allow it."
        case .permissionTimedOut:
            "Mac camera permission was not resolved in time. Try again and answer the macOS permission prompt, or disable Camera for this desktop."
        case .unavailable:
            "No usable Mac camera is available. Connect or enable a camera, or disable Camera for this desktop."
        case .selectedDeviceUnavailable:
            "The camera selected for this desktop is no longer available. Reconnect that camera or choose a different one; Dory will not switch to another camera automatically."
        case .deviceInUse:
            "The selected Mac camera is already shared with another Dory desktop. Stop that camera stream or desktop before trying again."
        case .leaseFailed:
            "Dory could not reserve the selected Mac camera safely. Check the camera lease directory and retry."
        case .inputCreationFailed(let detail):
            "The selected Mac camera could not be opened: \(detail)"
        case .cannotAttachInput:
            "The Mac camera input could not be attached to the capture session."
        case .cannotAttachOutput:
            "The Mac camera output could not be attached to the capture session."
        case .startFailed:
            "The Mac camera capture session did not start."
        case .unsupportedDimensions(let width, let height):
            "The requested Mac camera frame size is unsupported: \(width)x\(height)."
        case .frameTimedOut:
            "The Mac camera opened but did not deliver a frame before the deadline."
        }
    }
}

public struct DoryMacCameraIdentity: Sendable, Equatable {
    public let localizedName: String
    public let modelID: String
    public let uniqueID: String
}

/// Permission-aware AVFoundation source shared by Dory's guest camera transports. Capture and JPEG
/// conversion run off the AppKit thread. The physical camera starts lazily on the first guest video
/// read and stops after the guest stream goes idle, matching the privacy lifecycle of a local camera
/// instead of holding the device for the VM's whole lifetime.
public final class DoryMacCameraBackend: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let condition = NSCondition()
    private let preparationLock = NSLock()
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
    private let authorizationStatus: @Sendable () -> AVAuthorizationStatus
    public let selectedDeviceUniqueID: String?
    private var cameraLease: DoryMacCameraLease?
    private var latestJPEG: Data?
    private var generation: UInt64 = 0
    private var deliveredGeneration: UInt64 = 0
    private var requestedWidth = 1_280
    private var requestedHeight = 720
    private var idleGeneration: UInt64 = 0
    private var waitingConsumers = 0
    private var prepared = false
    private var cameraIdentity: DoryMacCameraIdentity?
    private var captureRunning = false
    private var observedSampleBuffer = false
    private var loggedEncodingFailure = false
    private var stopped = false

    public convenience init(
        selectedDeviceUniqueID: String? = nil,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            selectedDeviceUniqueID: selectedDeviceUniqueID,
            log: log,
            authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) }
        )
    }

    init(
        selectedDeviceUniqueID: String?,
        log: @escaping @Sendable (String) -> Void,
        authorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus
    ) {
        self.selectedDeviceUniqueID = selectedDeviceUniqueID
        self.log = log
        self.authorizationStatus = authorizationStatus
        super.init()
    }

    /// Only physical built-in, external, and Continuity cameras are candidates. A guest camera
    /// extension or another virtual source must not be recursively captured by the host.
    public static func availableCaptureDevices() -> [DoryMacCameraIdentity] {
        eligibleDevices().map {
            DoryMacCameraIdentity(
                localizedName: $0.localizedName,
                modelID: $0.modelID,
                uniqueID: $0.uniqueID
            )
        }
    }

    private static func eligibleDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Reserve an explicitly granted camera for the complete VM lifetime, before any guest can
    /// request a frame. No TCC prompt or capture session is started by this reservation.
    public func reserveSelectedDevice() throws {
        guard let selectedDeviceUniqueID,
              !selectedDeviceUniqueID.isEmpty,
              selectedDeviceUniqueID.utf8.count <= 512,
              selectedDeviceUniqueID.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            throw DoryMacCameraError.selectedDeviceUnavailable
        }
        preparationLock.lock()
        defer { preparationLock.unlock() }
        try reserve(deviceUniqueID: selectedDeviceUniqueID)
    }

    private func reserve(deviceUniqueID: String) throws {
        condition.lock()
        let alreadyReserved = cameraLease != nil
        let mayReserve = !stopped
        condition.unlock()
        guard mayReserve else { throw DoryMacCameraError.startFailed }
        if alreadyReserved { return }
        let lease: DoryMacCameraLease
        do {
            lease = try DoryMacCameraLease(deviceUniqueID: deviceUniqueID)
        } catch DoryMacCameraLeaseError.deviceBusy {
            throw DoryMacCameraError.deviceInUse
        } catch {
            throw DoryMacCameraError.leaseFailed
        }
        condition.lock()
        guard !stopped else {
            condition.unlock()
            lease.release()
            throw DoryMacCameraError.startFailed
        }
        cameraLease = lease
        condition.unlock()
    }

    @discardableResult
    public func prepareAndAuthorize(permissionTimeout: TimeInterval = 60) throws
        -> DoryMacCameraIdentity
    {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        condition.lock()
        if let cameraIdentity {
            condition.unlock()
            // TCC grants are mutable. A prepared capture graph is not authority to keep
            // streaming after the user revokes this helper's camera permission.
            try requireCurrentAuthorization()
            return cameraIdentity
        }
        let mayPrepare = !stopped
        condition.unlock()
        guard mayPrepare else { throw DoryMacCameraError.startFailed }

        try Self.requireAuthorization(timeout: permissionTimeout)
        let device: AVCaptureDevice
        if let selectedDeviceUniqueID {
            guard let selected = Self.eligibleDevices().first(where: {
                $0.uniqueID == selectedDeviceUniqueID
            }) else { throw DoryMacCameraError.selectedDeviceUnavailable }
            device = selected
        } else {
            guard let selected = AVCaptureDevice.default(for: .video) else {
                throw DoryMacCameraError.unavailable
            }
            device = selected
        }
        try reserve(deviceUniqueID: device.uniqueID)
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
        let identity = DoryMacCameraIdentity(
            localizedName: device.localizedName,
            modelID: device.modelID,
            uniqueID: device.uniqueID
        )
        condition.lock()
        cameraIdentity = identity
        condition.unlock()
        log("Dory camera: host capture ready (\(device.localizedName))")
        return identity
    }

    public func nextJPEGFrame(width: Int, height: Int, timeout: TimeInterval) -> Data? {
        try? nextJPEGFrameOrThrow(width: width, height: height, timeout: timeout)
    }

    public func nextJPEGFrameOrThrow(
        width: Int,
        height: Int,
        timeout: TimeInterval
    ) throws -> Data {
        guard (width == 640 && height == 480) || (width == 1_280 && height == 720) else {
            throw DoryMacCameraError.unsupportedDimensions(width, height)
        }
        _ = try prepareAndAuthorize()
        try requireCurrentAuthorization()

        // Register demand before startRunning(). Some cameras emit their first buffers while that
        // blocking call is still returning; the delegate must not discard those cold-start frames.
        condition.lock()
        guard !stopped else {
            condition.unlock()
            throw DoryMacCameraError.startFailed
        }
        if requestedWidth != width || requestedHeight != height {
            requestedWidth = width
            requestedHeight = height
            latestJPEG = nil
            deliveredGeneration = generation
        }
        waitingConsumers += 1
        condition.unlock()

        guard ensureCaptureRunning() else {
            finishWaitingForFrame()
            throw DoryMacCameraError.startFailed
        }

        let deadline = Date().addingTimeInterval(max(0.001, min(timeout, 15)))
        defer { finishWaitingForFrame() }
        while true {
            // TCC can be revoked without another AVFoundation callback. Poll the grant at a
            // bounded interval even if the camera stops delivering samples after revocation.
            try requireCurrentAuthorization()
            condition.lock()
            let jpeg: Data?
            let running = !stopped && captureRunning
            if running, generation != deliveredGeneration {
                deliveredGeneration = generation
                jpeg = latestJPEG
            } else {
                jpeg = nil
                if running {
                    _ = condition.wait(
                        until: min(deadline, Date().addingTimeInterval(0.25))
                    )
                }
            }
            condition.unlock()
            if let jpeg {
                // Never return a JPEG obtained under a grant that was revoked while waiting.
                try requireCurrentAuthorization()
                return jpeg
            }
            guard running, Date() < deadline else { throw DoryMacCameraError.frameTimedOut }
        }
    }

    public func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        let lease = cameraLease
        cameraLease = nil
        prepared = false
        cameraIdentity = nil
        captureRunning = false
        idleGeneration &+= 1
        latestJPEG = nil
        condition.broadcast()
        condition.unlock()
        output.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
        }
        lease?.release()
        log("Dory camera: host capture stopped")
    }

    /// A live permission check for previously prepared sessions. The first authorization prompt
    /// remains in `requireAuthorization`; once a session exists, a missing grant is revocation,
    /// not permission to prompt again from a guest frame request.
    func requireCurrentAuthorization() throws {
        let error: DoryMacCameraError
        switch authorizationStatus() {
        case .authorized:
            return
        case .denied, .notDetermined:
            error = .permissionDenied
        case .restricted:
            error = .permissionRestricted
        @unknown default:
            error = .permissionRestricted
        }
        stop()
        throw error
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        condition.lock()
        let shouldEncode = captureRunning && !stopped && waitingConsumers > 0
        let shouldLogFirstSample = captureRunning && !stopped && !observedSampleBuffer
        if shouldLogFirstSample { observedSampleBuffer = true }
        let targetWidth = requestedWidth
        let targetHeight = requestedHeight
        condition.unlock()
        if shouldLogFirstSample {
            log("Dory camera: host capture delivered its first sample buffer")
        }
        guard shouldEncode else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logEncodingFailureOnce("the first camera sample did not contain an image buffer")
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
            logEncodingFailureOnce("the camera sample could not be encoded as a bounded JPEG")
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
            observedSampleBuffer = false
            loggedEncodingFailure = false
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
                log("Dory camera: host capture started")
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
                self.log("Dory camera: host capture released after guest stream idle")
            }
        }
    }

    private func finishWaitingForFrame() {
        condition.lock()
        waitingConsumers = max(0, waitingConsumers - 1)
        idleGeneration &+= 1
        let idleToken = idleGeneration
        let shouldScheduleIdleRelease = waitingConsumers == 0 && !stopped
        condition.unlock()
        if shouldScheduleIdleRelease {
            scheduleIdleRelease(token: idleToken)
        }
    }

    private func logEncodingFailureOnce(_ detail: String) {
        condition.lock()
        let shouldLog = !loggedEncodingFailure
        loggedEncodingFailure = true
        condition.unlock()
        if shouldLog { log("Dory camera: \(detail)") }
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
