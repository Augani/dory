import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import DoryCameraBridgeContracts
import DoryMacGuestCamera
import Foundation
import ImageIO
import IOKit.audio
import OSLog

public enum DoryCameraExtensionConstants {
    public static let localizedName = "Dory Camera"
    public static let model = "Dory VZMac Camera Bridge"
    public static let width = 1_280
    public static let height = 720
    public static let framesPerSecond = 30
    public static let deviceID = UUID(uuidString: "B78816B4-E2FB-4D78-9439-11D29A97B160")!
    public static let streamID = UUID(uuidString: "271415FA-53C5-48E3-9642-E6802F9E1737")!
}

public enum DoryCameraPixelBufferError: Error, Sendable {
    case invalidJPEG
    case wrongDimensions(Int, Int)
    case allocationFailed(CVReturn)
    case missingBaseAddress
    case contextCreationFailed
}

public enum DoryCameraJPEGPixelBufferDecoder {
    public static func decode(_ frame: DoryCameraBridgeV1.JPEGFrame) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DoryCameraPixelBufferError.invalidJPEG
        }
        guard image.width == Int(frame.widthPixels), image.height == Int(frame.heightPixels) else {
            throw DoryCameraPixelBufferError.wrongDimensions(image.width, image.height)
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw DoryCameraPixelBufferError.allocationFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DoryCameraPixelBufferError.missingBaseAddress
        }
        guard let context = CGContext(
            data: baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw DoryCameraPixelBufferError.contextCreationFailed
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelBuffer
    }
}

public final class DoryCameraDeviceSource: NSObject,
    CMIOExtensionDeviceSource, @unchecked Sendable
{
    public private(set) var device: CMIOExtensionDevice!
    private var streamSource: DoryCameraStreamSource!
    private var videoDescription: CMFormatDescription!
    private let stateLock = NSLock()
    private let streamQueue = DispatchQueue(label: "com.dory.guest.camera.stream", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.pythonxi.Dory.GuestCamera", category: "stream")
    private var client: DoryMacGuestCameraClient?
    private var streamingClients = 0
    private var generation: UInt64 = 0

    public override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: DoryCameraExtensionConstants.localizedName,
            deviceID: DoryCameraExtensionConstants.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        let dimensions = CMVideoDimensions(
            width: Int32(DoryCameraExtensionConstants.width),
            height: Int32(DoryCameraExtensionConstants.height)
        )
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dimensions.width,
            height: dimensions.height,
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )
        let duration = CMTime(
            value: 1,
            timescale: Int32(DoryCameraExtensionConstants.framesPerSecond)
        )
        let format = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: duration,
            minFrameDuration: duration,
            validFrameDurations: nil
        )
        streamSource = DoryCameraStreamSource(
            streamID: DoryCameraExtensionConstants.streamID,
            streamFormat: format,
            device: device
        )
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Dory Camera could not add its source stream: \(error)")
        }
    }

    public var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    public func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = DoryCameraExtensionConstants.model
        }
        return result
    }

    public func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() throws {
        stateLock.lock()
        streamingClients += 1
        guard streamingClients == 1 else {
            stateLock.unlock()
            return
        }
        generation &+= 1
        let activeGeneration = generation
        let client = DoryMacGuestCameraClient()
        self.client = client
        stateLock.unlock()
        do {
            try client.connect(
                widthPixels: UInt32(DoryCameraExtensionConstants.width),
                heightPixels: UInt32(DoryCameraExtensionConstants.height),
                maximumFramesPerSecond: UInt32(DoryCameraExtensionConstants.framesPerSecond)
            )
        } catch {
            stateLock.lock()
            streamingClients = 0
            self.client = nil
            stateLock.unlock()
            throw error
        }
        streamQueue.async { [weak self, client] in
            self?.forwardFrames(from: client, generation: activeGeneration)
        }
    }

    func stopStreaming() {
        stateLock.lock()
        guard streamingClients > 0 else {
            stateLock.unlock()
            return
        }
        streamingClients -= 1
        guard streamingClients == 0 else {
            stateLock.unlock()
            return
        }
        generation &+= 1
        let client = self.client
        self.client = nil
        stateLock.unlock()
        client?.stop()
    }

    private func forwardFrames(from client: DoryMacGuestCameraClient, generation: UInt64) {
        while isActive(client: client, generation: generation) {
            do {
                let frame = try client.nextFrame()
                guard isActive(client: client, generation: generation) else { break }
                let pixelBuffer = try DoryCameraJPEGPixelBufferDecoder.decode(frame)
                var timing = CMSampleTimingInfo(
                    duration: CMTime(
                        value: 1,
                        timescale: Int32(DoryCameraExtensionConstants.framesPerSecond)
                    ),
                    presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                    decodeTimeStamp: .invalid
                )
                var sampleBuffer: CMSampleBuffer?
                let status = CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: videoDescription,
                    sampleTiming: &timing,
                    sampleBufferOut: &sampleBuffer
                )
                if status == noErr, let sampleBuffer {
                    streamSource.stream.send(
                        sampleBuffer,
                        discontinuity: [],
                        hostTimeInNanoseconds: frame.hostPresentationTimeNanoseconds
                    )
                }
            } catch {
                logger.error("Dory Camera frame forwarding stopped: \(String(describing: error), privacy: .public)")
                break
            }
        }
        client.stop()
    }

    private func isActive(client: DoryMacGuestCameraClient, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamingClients > 0 && self.client === client && self.generation == generation
    }
}

public final class DoryCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    public private(set) var stream: CMIOExtensionStream!
    public let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: DoryCameraExtensionConstants.localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    public var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    public var activeFormatIndex = 0
    public var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    public func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(
                value: 1,
                timescale: Int32(DoryCameraExtensionConstants.framesPerSecond)
            )
        }
        return result
    }

    public func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index == 0 {
            activeFormatIndex = index
        }
    }

    public func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    public func startStream() throws {
        guard let source = device.source as? DoryCameraDeviceSource else { return }
        try source.startStreaming()
    }

    public func stopStream() throws {
        guard let source = device.source as? DoryCameraDeviceSource else { return }
        source.stopStreaming()
    }
}

public final class DoryCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    public private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DoryCameraDeviceSource!

    public init(clientQueue: DispatchQueue? = nil) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DoryCameraDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Dory Camera could not publish its device: \(error)")
        }
    }

    public func connect(to client: CMIOExtensionClient) throws {}
    public func disconnect(from client: CMIOExtensionClient) {}
    public var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    public func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Dory" }
        return result
    }

    public func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
