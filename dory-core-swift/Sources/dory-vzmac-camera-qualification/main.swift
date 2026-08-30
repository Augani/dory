@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private let expectedCameraName = "Dory Camera"
private let expectedWidth = 1_280
private let expectedHeight = 720
private let requiredFrames = 30
private let timeoutSeconds: Double = 15

private struct Receipt: Codable {
    var schema = "dory.phase0a.vzmac-camera-qualification@1"
    var status: String
    var cameraAuthorization: String
    var discoveredVideoDevices: [String]
    var selectedDeviceName: String? = nil
    var selectedDeviceUniqueID: String? = nil
    var frameCount: Int
    var widthPixels: Int? = nil
    var heightPixels: Int? = nil
    var pixelFormat: UInt32? = nil
    var firstFrameLatencyMilliseconds: Double? = nil
    var medianFrameIntervalMilliseconds: Double? = nil
    var p95FrameIntervalMilliseconds: Double? = nil
    var stoppedCleanly: Bool
    var blockers: [String]
}

private final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var presentationTimes: [Double] = []
    private var firstFrameLatency: Double?
    private var dimensions: CMVideoDimensions?
    private var subtype: FourCharCode?
    private var didSignal = false
    private let startTime = ProcessInfo.processInfo.systemUptime

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard presentationTimes.count < requiredFrames else { return }
        if firstFrameLatency == nil {
            firstFrameLatency = (ProcessInfo.processInfo.systemUptime - startTime) * 1_000
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        presentationTimes.append(presentationTime)
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            dimensions = CMVideoFormatDescriptionGetDimensions(format)
            subtype = CMFormatDescriptionGetMediaSubType(format)
        }
        if presentationTimes.count == requiredFrames, !didSignal {
            didSignal = true
            completed.signal()
        }
    }

    func wait() -> Bool {
        completed.wait(timeout: .now() + timeoutSeconds) == .success
    }

    func snapshot() -> (
        count: Int,
        dimensions: CMVideoDimensions?,
        subtype: FourCharCode?,
        firstFrameLatency: Double?,
        intervals: [Double]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            presentationTimes.count,
            dimensions,
            subtype,
            firstFrameLatency,
            zip(presentationTimes.dropFirst(), presentationTimes).map { ($0 - $1) * 1_000 }
        )
    }
}

private func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double? {
    guard !sortedValues.isEmpty else { return nil }
    let index = min(sortedValues.count - 1, Int(ceil(percentile * Double(sortedValues.count))) - 1)
    return sortedValues[max(0, index)]
}

private func cameraAuthorization() -> AVAuthorizationStatus {
    let current = AVCaptureDevice.authorizationStatus(for: .video)
    guard current == .notDetermined else { return current }
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 60)
    return AVCaptureDevice.authorizationStatus(for: .video)
}

private func write(_ receipt: Receipt, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(receipt) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
    exit(exitCode)
}

let authorization = cameraAuthorization()
let devices = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external],
    mediaType: .video,
    position: .unspecified
).devices
let names = devices.map(\.localizedName).sorted()
guard authorization == .authorized else {
    write(
        Receipt(
            status: "BLOCKED_CAMERA_PERMISSION",
            cameraAuthorization: String(describing: authorization),
            discoveredVideoDevices: names,
            frameCount: 0,
            stoppedCleanly: true,
            blockers: ["camera access is not authorized inside the macOS guest"]
        ),
        exitCode: 3
    )
}
guard let camera = devices.first(where: { $0.localizedName == expectedCameraName }) else {
    write(
        Receipt(
            status: "BLOCKED_DORY_CAMERA_NOT_VISIBLE",
            cameraAuthorization: "authorized",
            discoveredVideoDevices: names,
            frameCount: 0,
            stoppedCleanly: true,
            blockers: ["Dory Camera is not registered with CoreMediaIO in the macOS guest"]
        ),
        exitCode: 3
    )
}

let session = AVCaptureSession()
private let collector = FrameCollector()
do {
    let input = try AVCaptureDeviceInput(device: camera)
    guard session.canAddInput(input) else {
        throw NSError(domain: "DoryVZMacCameraQualification", code: 1)
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(
        collector,
        queue: DispatchQueue(label: "com.pythonxi.Dory.VZMacCameraQualification.frames")
    )
    guard session.canAddOutput(output) else {
        throw NSError(domain: "DoryVZMacCameraQualification", code: 2)
    }
    session.addOutput(output)
    session.startRunning()
    let completed = collector.wait()
    session.stopRunning()
    let snapshot = collector.snapshot()
    let intervals = snapshot.intervals.sorted()
    let dimensionsMatch = snapshot.dimensions?.width == Int32(expectedWidth)
        && snapshot.dimensions?.height == Int32(expectedHeight)
    let passed = completed && snapshot.count >= requiredFrames && dimensionsMatch
    write(
        Receipt(
            status: passed ? "PASS" : "BLOCKED_FRAME_QUALIFICATION",
            cameraAuthorization: "authorized",
            discoveredVideoDevices: names,
            selectedDeviceName: camera.localizedName,
            selectedDeviceUniqueID: camera.uniqueID,
            frameCount: snapshot.count,
            widthPixels: snapshot.dimensions.map { Int($0.width) },
            heightPixels: snapshot.dimensions.map { Int($0.height) },
            pixelFormat: snapshot.subtype,
            firstFrameLatencyMilliseconds: snapshot.firstFrameLatency,
            medianFrameIntervalMilliseconds: percentile(intervals, 0.5),
            p95FrameIntervalMilliseconds: percentile(intervals, 0.95),
            stoppedCleanly: !session.isRunning,
            blockers: passed ? [] : [
                "Dory Camera did not deliver 30 valid 1280x720 frames within 15 seconds"
            ]
        ),
        exitCode: passed ? EXIT_SUCCESS : 3
    )
} catch {
    if session.isRunning { session.stopRunning() }
    write(
        Receipt(
            status: "BLOCKED_CAPTURE_CONFIGURATION",
            cameraAuthorization: "authorized",
            discoveredVideoDevices: names,
            selectedDeviceName: camera.localizedName,
            selectedDeviceUniqueID: camera.uniqueID,
            frameCount: 0,
            stoppedCleanly: !session.isRunning,
            blockers: [String(describing: error)]
        ),
        exitCode: 3
    )
}
