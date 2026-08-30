@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import DoryHostCamera
import Foundation
import ImageIO
import Security

enum DoryMacCameraQualificationError: Error, CustomStringConvertible {
    case invalidArguments
    case unsignedBundle(String)
    case missingUsageDescription
    case missingCameraEntitlement
    case authorizationNotGranted
    case frameTimedOut(Int)
    case invalidJPEG(Int)
    case wrongDimensions(Int, Int, Int)
    case emptyExecutable

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: dory-hv camera-qualify [--frames 1...900] [--timeout-sec 1...120]"
        case .unsignedBundle(let identifier):
            "camera qualification requires the signed DoryHVRunner app bundle, got \(identifier)"
        case .missingUsageDescription:
            "DoryHVRunner is missing NSCameraUsageDescription"
        case .missingCameraEntitlement:
            "DoryHVRunner is missing com.apple.security.device.camera"
        case .authorizationNotGranted:
            "macOS did not grant camera authorization to DoryHVRunner"
        case .frameTimedOut(let index):
            "physical camera frame \(index) timed out"
        case .invalidJPEG(let index):
            "physical camera frame \(index) was not a decodable JPEG"
        case .wrongDimensions(let index, let width, let height):
            "physical camera frame \(index) was \(width)x\(height), expected 1280x720"
        case .emptyExecutable:
            "DoryHVRunner has no readable executable for receipt binding"
        }
    }
}

enum DoryMacCameraQualificationCommand {
    private static let identity = "dory.host-camera-qualification@1"
    private static let bundleIdentifier = "com.pythonxi.Dory.HVRunner"
    private static let width = 1_280
    private static let height = 720

    private struct Receipt: Encodable {
        let schemaVersion: UInt32
        let qualificationIdentity: String
        let bundleIdentifier: String
        let executableSHA256: String
        let usageDescriptionSHA256: String
        let cameraEntitlementPresent: Bool
        let hostModel: String
        let hostOSVersion: String
        let hostOSBuild: String
        let authorizationStatus: String
        let cameraLocalizedName: String
        let cameraModelID: String
        let cameraUniqueIDSHA256: String
        let widthPixels: Int
        let heightPixels: Int
        let capturedFrameCount: Int
        let jpegByteCount: UInt64
        let jpegStreamSHA256: String
        let captureDurationNanoseconds: UInt64
        let minimumDeliveryNanoseconds: UInt64
        let medianDeliveryNanoseconds: UInt64
        let p95DeliveryNanoseconds: UInt64
        let maximumDeliveryNanoseconds: UInt64
        let qualificationStartedAt: String
        let qualificationCompletedAt: String
        let stoppedAfterCapture: Bool
    }

    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try parse(arguments)
        guard Bundle.main.bundleIdentifier == bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else {
            throw DoryMacCameraQualificationError.unsignedBundle(
                Bundle.main.bundleIdentifier ?? "unbundled executable"
            )
        }
        guard let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSCameraUsageDescription"
        ) as? String, !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoryMacCameraQualificationError.missingUsageDescription
        }
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.device.camera" as CFString,
                nil
              ) as? Bool == true else {
            throw DoryMacCameraQualificationError.missingCameraEntitlement
        }

        let startedAt = Date()
        let startedUptime = DispatchTime.now().uptimeNanoseconds
        let backend = DoryMacCameraBackend { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        var stopped = false
        defer {
            if !stopped { backend.stop() }
        }
        let camera = try backend.prepareAndAuthorize(
            permissionTimeout: TimeInterval(options.permissionTimeoutSeconds)
        )
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw DoryMacCameraQualificationError.authorizationNotGranted
        }

        var streamHasher = SHA256()
        var totalBytes: UInt64 = 0
        var deliveryNanoseconds = [UInt64]()
        deliveryNanoseconds.reserveCapacity(options.frameCount)
        for index in 1...options.frameCount {
            let frameStarted = DispatchTime.now().uptimeNanoseconds
            guard let jpeg = backend.nextJPEGFrame(
                width: width,
                height: height,
                timeout: 2
            ) else {
                throw DoryMacCameraQualificationError.frameTimedOut(index)
            }
            let frameCompleted = DispatchTime.now().uptimeNanoseconds
            let dimensions = try jpegDimensions(jpeg, index: index)
            guard dimensions.width == width, dimensions.height == height else {
                throw DoryMacCameraQualificationError.wrongDimensions(
                    index,
                    dimensions.width,
                    dimensions.height
                )
            }
            deliveryNanoseconds.append(frameCompleted &- frameStarted)
            totalBytes &+= UInt64(jpeg.count)
            streamHasher.update(data: jpeg)
        }
        backend.stop()
        stopped = true
        let completedUptime = DispatchTime.now().uptimeNanoseconds
        let completedAt = Date()
        let sortedDelivery = deliveryNanoseconds.sorted()
        let receipt = Receipt(
            schemaVersion: 1,
            qualificationIdentity: identity,
            bundleIdentifier: bundleIdentifier,
            executableSHA256: try executableSHA256(),
            usageDescriptionSHA256: sha256(Data(usageDescription.utf8)),
            cameraEntitlementPresent: true,
            hostModel: sysctlString("hw.model"),
            hostOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hostOSBuild: sysctlString("kern.osversion"),
            authorizationStatus: "authorized",
            cameraLocalizedName: camera.localizedName,
            cameraModelID: camera.modelID,
            cameraUniqueIDSHA256: sha256(Data(camera.uniqueID.utf8)),
            widthPixels: width,
            heightPixels: height,
            capturedFrameCount: options.frameCount,
            jpegByteCount: totalBytes,
            jpegStreamSHA256: streamHasher.finalize().hexString,
            captureDurationNanoseconds: completedUptime &- startedUptime,
            minimumDeliveryNanoseconds: sortedDelivery[0],
            medianDeliveryNanoseconds: percentile(sortedDelivery, numerator: 50),
            p95DeliveryNanoseconds: percentile(sortedDelivery, numerator: 95),
            maximumDeliveryNanoseconds: sortedDelivery[sortedDelivery.count - 1],
            qualificationStartedAt: timestamp(startedAt),
            qualificationCompletedAt: timestamp(completedAt),
            stoppedAfterCapture: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(receipt))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct Options {
        var frameCount = 60
        var permissionTimeoutSeconds = 60
    }

    private static func parse(_ arguments: ArraySlice<String>) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--frames":
                guard let value = iterator.next().flatMap(Int.init), (1...900).contains(value) else {
                    throw DoryMacCameraQualificationError.invalidArguments
                }
                options.frameCount = value
            case "--timeout-sec":
                guard let value = iterator.next().flatMap(Int.init), (1...120).contains(value) else {
                    throw DoryMacCameraQualificationError.invalidArguments
                }
                options.permissionTimeoutSeconds = value
            default:
                throw DoryMacCameraQualificationError.invalidArguments
            }
        }
        return options
    }

    private static func jpegDimensions(_ data: Data, index: Int) throws
        -> (width: Int, height: Int)
    {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw DoryMacCameraQualificationError.invalidJPEG(index)
        }
        return (width, height)
    }

    private static func percentile(_ sorted: [UInt64], numerator: Int) -> UInt64 {
        let rank = max(1, (sorted.count * numerator + 99) / 100)
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    private static func executableSHA256() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw DoryMacCameraQualificationError.emptyExecutable
        }
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var readAny = false
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            readAny = true
            hasher.update(data: chunk)
        }
        guard readAny else { throw DoryMacCameraQualificationError.emptyExecutable }
        return hasher.finalize().hexString
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
