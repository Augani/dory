import CoreGraphics
import DoryHostDeviceBroker
import DoryHV
import DoryMachinePC
import DoryVirtio
import DoryVMContracts
import Foundation
import ImageIO
import Testing
@testable import dory_hv

@Suite struct DoryPCDesktopAdapterTests {
    @Test func physicalUSBLeaseSurvivesResetAndRevokesTheRootPort() async throws {
        let token = DoryUSBPhysicalIdentityToken(
            rawValue: String(repeating: "a", count: 64)
        )!
        let descriptor = UsbipDeviceDescriptor(
            path: "test-device",
            busID: "3-2",
            busNumber: 3,
            deviceNumber: 2,
            speed: 5,
            vendorID: 0x2e8a,
            productID: 0x0003,
            bcdDevice: 0x0100,
            deviceClass: 0xff,
            deviceSubClass: 0,
            deviceProtocol: 0,
            configurationValue: 1,
            configurationCount: 1,
            interfaceCount: 1
        )
        let candidate = HostUsbDeviceCandidate(
            descriptor: descriptor,
            identityToken: token,
            captureDecision: .allowed
        )
        let capability = RecordingPCUSBTransferCapability(identityToken: token)
        let broker = DoryHostUSBLeaseBroker()
        let lease = try broker.acquire(
            machineID: "machine-a",
            identityToken: token,
            family: .developerHardware,
            admission: .init(userSelected: true),
            capability: capability
        )
        let initial = try DoryPCXHCIController()
        let handler = DoryPCUSBControlHandler(
            controller: initial,
            machineID: "machine-a",
            broker: broker,
            lookupCandidate: { _ in candidate },
            openLease: { _, _ in lease }
        )

        let attachment = try await handler.attach(
            busID: "3-2",
            expectedIdentity: token,
            mode: .userAuthorized
        )
        #expect(attachment.port == 2)
        #expect(try initial.portState(2).connected)
        #expect(try initial.portState(2).speed == .superSpeed)

        let replacement = try DoryPCXHCIController()
        try handler.replaceController(replacement)
        #expect(try replacement.portState(2).connected)

        lease.surpriseRemove()
        #expect(try !replacement.portState(2).connected)
        #expect(broker.activeLeaseCount(machineID: "machine-a") == 0)
        #expect(capability.closeCount == 1)
    }

    @Test func macAudioAdapterPacesAndMapsDoryPCStreams() throws {
        let host = RecordingPCMacAudioHost()
        let adapter = DoryPCMacAudioBackend(log: { _ in }, host: host)
        let output = DoryVirtioSoundPCMParameters(
            bufferBytes: 16_384,
            periodBytes: 4_096,
            channels: 2,
            format: .signed16,
            rate: .hz96000
        )
        try adapter.configure(streamID: 0, direction: .output, parameters: output)
        try adapter.prepare(streamID: 0)
        try adapter.start(streamID: 0)
        try adapter.play(streamID: 0, pcmBytes: [UInt8](repeating: 7, count: 4_096))
        #expect(host.sampleRate == 96_000)
        #expect(host.playedByteCount == 4_096)

        let input = DoryVirtioSoundPCMParameters(
            bufferBytes: 16_384,
            periodBytes: 4_096,
            channels: 1,
            format: .signed16,
            rate: .hz48000
        )
        try adapter.configure(streamID: 1, direction: .input, parameters: input)
        try adapter.prepare(streamID: 1)
        try adapter.start(streamID: 1)
        #expect(try adapter.capture(streamID: 1, byteCount: 64)
            == [UInt8](repeating: 0x55, count: 64))
        try adapter.release(streamID: 0)
        try adapter.release(streamID: 1)
    }

    @Test func macAudioAdapterRejectsFormatsItsCoreAudioPathCannotRepresent() {
        let adapter = DoryPCMacAudioBackend(
            log: { _ in },
            host: RecordingPCMacAudioHost()
        )
        #expect(throws: DoryPCMacAudioError.unsupportedFormat) {
            try adapter.configure(
                streamID: 0,
                direction: .output,
                parameters: DoryVirtioSoundPCMParameters(
                    bufferBytes: 16_384,
                    periodBytes: 4_096,
                    channels: 2,
                    format: .float32,
                    rate: .hz48000
                )
            )
        }
    }

    @Test func cameraBridgeConvertsJPEGToExactYUY2Frame() throws {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255]
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            return try #require(context.makeImage())
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let converted = try #require(DoryPCCameraBridge.yuy2(
            jpeg: data as Data,
            width: 2,
            height: 1
        ))
        #expect(converted.count == 4)
        #expect(abs(Int(converted[0]) - 82) <= 8)
        #expect(abs(Int(converted[1]) - 90) <= 8)
        #expect(abs(Int(converted[2]) - 82) <= 8)
        #expect(abs(Int(converted[3]) - 240) <= 8)
    }

    @Test func softwareFrameConversionClipsDamageAndCopiesExactRows() throws {
        let mailbox = DesktopFrameMailbox(scanoutID: 0)
        let sink = DoryPCSoftwareDisplaySink(mailbox: mailbox)
        let pixels = Array(UInt8(0)..<UInt8(48))
        let converted = try #require(sink.convert(DoryVirtioGPUFrame(
            scanoutID: 0,
            resourceID: 9,
            scanoutRectangle: .init(x: 1, y: 1, width: 3, height: 2),
            damagedRectangle: .init(x: 2, y: 0, width: 3, height: 3),
            resourceWidth: 4,
            resourceHeight: 3,
            format: .b8g8r8a8UNorm,
            pixels: pixels
        )))

        #expect(converted.width == 3)
        #expect(converted.height == 2)
        #expect(converted.stride == 8)
        #expect(converted.dirtyRect == .init(x: 1, y: 0, width: 2, height: 2))
        #expect(converted.bytes == Data(pixels[24..<32] + pixels[40..<48]))
    }

    @Test func softwareFrameGenerationAdvancesOnlyWhenResourceIdentityChanges() throws {
        let sink = DoryPCSoftwareDisplaySink(mailbox: DesktopFrameMailbox(scanoutID: 0))
        func frame(width: UInt32, height: UInt32) -> DoryVirtioGPUFrame {
            DoryVirtioGPUFrame(
                scanoutID: 0,
                resourceID: 7,
                scanoutRectangle: .init(x: 0, y: 0, width: width, height: height),
                damagedRectangle: .init(x: 0, y: 0, width: width, height: height),
                resourceWidth: width,
                resourceHeight: height,
                format: .b8g8r8a8UNorm,
                pixels: [UInt8](repeating: 0, count: Int(width * height * 4))
            )
        }

        let first = try #require(sink.convert(frame(width: 2, height: 2)))
        let second = try #require(sink.convert(frame(width: 2, height: 2)))
        let replacement = try #require(sink.convert(frame(width: 3, height: 2)))
        #expect(first.resourceGeneration == second.resourceGeneration)
        #expect(replacement.resourceGeneration == first.resourceGeneration + 1)
    }

    @Test func softwareFrameConversionRejectsTruncatedResources() {
        let sink = DoryPCSoftwareDisplaySink(mailbox: DesktopFrameMailbox(scanoutID: 0))
        let frame = DoryVirtioGPUFrame(
            scanoutID: 0,
            resourceID: 1,
            scanoutRectangle: .init(x: 0, y: 0, width: 2, height: 2),
            damagedRectangle: .init(x: 0, y: 0, width: 2, height: 2),
            resourceWidth: 2,
            resourceHeight: 2,
            format: .b8g8r8a8UNorm,
            pixels: [UInt8](repeating: 0, count: 15)
        )
        #expect(sink.convert(frame) == nil)
    }
}

private final class RecordingPCUSBTransferCapability: DoryHostUSBTransferCapability,
    @unchecked Sendable
{
    let identityToken: DoryUSBPhysicalIdentityToken
    let speed: DoryPCXHCIPortSpeed = .superSpeed
    private let lock = NSLock()
    private var closes = 0

    init(identityToken: DoryUSBPhysicalIdentityToken) {
        self.identityToken = identityToken
    }

    var closeCount: Int { lock.withLock { closes } }

    func perform(
        _ transfer: DoryPCUSBTransfer,
        deadline: ContinuousClock.Instant
    ) -> DoryPCUSBTransferResult {
        try! .init(status: .success)
    }

    func reset(deadline: ContinuousClock.Instant) -> Bool { true }
    func cancelAll() {}
    func close() { lock.withLock { closes += 1 } }
}

private final class RecordingPCMacAudioHost: VirtioSoundHost, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSampleRate: Double?
    private var recordedPlayedByteCount = 0

    var sampleRate: Double? { lock.withLock { recordedSampleRate } }
    var playedByteCount: Int { lock.withLock { recordedPlayedByteCount } }

    func configure(
        streamID: Int,
        direction: VirtioSoundDirection,
        parameters: VirtioSoundPCMParameters
    ) -> Bool {
        lock.withLock { recordedSampleRate = parameters.sampleRate }
        return true
    }
    func prepare(streamID: Int, direction: VirtioSoundDirection) -> Bool { true }
    func start(streamID: Int, direction: VirtioSoundDirection) -> Bool { true }
    func stop(streamID: Int, direction: VirtioSoundDirection) -> Bool { true }
    func release(streamID: Int, direction: VirtioSoundDirection) {}
    func enqueuePlayback(
        _ data: Data,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Bool, UInt32) -> Void
    ) -> Bool {
        lock.withLock { recordedPlayedByteCount += data.count }
        completion(true, 0)
        return true
    }
    func requestCapture(
        byteCount: Int,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Data?, UInt32) -> Void
    ) -> Bool {
        completion(Data(repeating: 0x55, count: byteCount), 0)
        return true
    }
    func reset() {}
}
