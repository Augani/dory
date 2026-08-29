import Darwin
import Foundation

/// Supplies already-compressed MJPEG frames to the virtual UVC transport. The runner owns the
/// permission-sensitive macOS capture implementation; this USB layer remains deterministic and
/// independently testable.
public protocol DoryUVCCameraFrameSource: Sendable {
    func nextJPEGFrame(width: Int, height: Int, timeout: TimeInterval) -> Data?
    func stop()
}

public enum DoryVirtualUVCCamera {
    public static let busID = "255-1"
    public static let busNumber: UInt32 = 255
    public static let deviceNumber: UInt32 = 1
    public static let deviceID = (busNumber << 16) | deviceNumber
    public static let speedHigh: UInt32 = 3

    public static func descriptor() -> UsbipDeviceDescriptor {
        UsbipDeviceDescriptor(
            path: "/dory/virtual/camera/0",
            busID: busID,
            busNumber: busNumber,
            deviceNumber: deviceNumber,
            speed: speedHigh,
            vendorID: 0xD0F1,
            productID: 0xCA01,
            bcdDevice: 0x0100,
            deviceClass: 0xEF,
            deviceSubClass: 0x02,
            deviceProtocol: 0x01,
            configurationValue: 1,
            configurationCount: 1,
            interfaceCount: 2
        )
    }
}

/// A bounded USB 2.0 Video Class 1.1 camera. It exposes one bulk MJPEG endpoint so USB/IP never
/// needs to reinterpret or emulate isochronous scheduling. Linux binds its upstream `uvcvideo`
/// driver and presents the device through the normal V4L2 API.
public final class DoryVirtualUVCCameraBackend: HostUsbBackend, @unchecked Sendable {
    private enum StandardRequest {
        static let getStatus: UInt8 = 0x00
        static let clearFeature: UInt8 = 0x01
        static let getDescriptor: UInt8 = 0x06
        static let getConfiguration: UInt8 = 0x08
        static let setConfiguration: UInt8 = 0x09
        static let getInterface: UInt8 = 0x0A
        static let setInterface: UInt8 = 0x0B
    }

    private enum UVCRequest {
        static let setCurrent: UInt8 = 0x01
        static let getCurrent: UInt8 = 0x81
        static let getMinimum: UInt8 = 0x82
        static let getMaximum: UInt8 = 0x83
        static let getResolution: UInt8 = 0x84
        static let getLength: UInt8 = 0x85
        static let getInfo: UInt8 = 0x86
        static let getDefault: UInt8 = 0x87
    }

    private struct StreamControl {
        // UVC 1.1 probe/commit controls are 34 bytes. Returning the 26-byte UVC 1.0 shape while
        // advertising bcdUVC 1.10 makes mainline uvcvideo reject enumeration as a short control
        // transfer.
        static let byteCount = 34
        static let defaultFrameInterval: UInt32 = 333_333
        static let maximumPayloadBytes: UInt32 = 16 * 1_024
        static let clockFrequency: UInt32 = 48_000_000

        var formatIndex: UInt8 = 1
        var frameIndex: UInt8 = 2
        var frameInterval: UInt32 = defaultFrameInterval

        init() {}

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= Self.byteCount,
                  bytes[2] == 1,
                  (1...2).contains(bytes[3]) else { return nil }
            let interval = Self.leUInt32(bytes, at: 4)
            guard interval >= 333_333, interval <= 1_000_000 else { return nil }
            formatIndex = bytes[2]
            frameIndex = bytes[3]
            frameInterval = interval
        }

        var encoded: [UInt8] {
            let dimensions = dimensions
            let maximumFrameBytes = UInt32(dimensions.0 * dimensions.1 * 2)
            var bytes = [UInt8](repeating: 0, count: Self.byteCount)
            // bmHint: dwFrameInterval is fixed by the host.
            Self.putLE(UInt16(1), into: &bytes, at: 0)
            bytes[2] = formatIndex
            bytes[3] = frameIndex
            Self.putLE(frameInterval, into: &bytes, at: 4)
            Self.putLE(maximumFrameBytes, into: &bytes, at: 18)
            Self.putLE(Self.maximumPayloadBytes, into: &bytes, at: 22)
            Self.putLE(Self.clockFrequency, into: &bytes, at: 26)
            return bytes
        }

        var dimensions: (Int, Int) {
            frameIndex == 1 ? (640, 480) : (1_280, 720)
        }

        private static func leUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        private static func putLE<T: FixedWidthInteger>(
            _ value: T,
            into bytes: inout [UInt8],
            at offset: Int
        ) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { raw in
                bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
            }
        }
    }

    private let frameSource: any DoryUVCCameraFrameSource
    private let state = NSLock()
    private var configured = false
    private var streamingAlternateSetting: UInt8 = 0
    private var probe = StreamControl()
    private var commit = StreamControl()
    private var activeFrame = Data()
    private var activeFrameOffset = 0
    private var frameIdentifier: UInt8 = 0
    private var stopped = false

    public init(frameSource: any DoryUVCCameraFrameSource) {
        self.frameSource = frameSource
    }

    public func control(
        _ setup: HostUsbControlSetup,
        payload: [UInt8],
        direction: UsbipDirection,
        timeout: TimeInterval
    ) throws -> HostUsbTransferResult {
        let requestClass = setup.requestType & 0x60
        switch requestClass {
        case 0x00:
            return try standardControl(setup, direction: direction)
        case 0x20:
            return try videoClassControl(setup, payload: payload, direction: direction)
        default:
            throw HostUsbTransferError.failed(errno: EPIPE)
        }
    }

    public func transfer(
        endpointAddress: UInt8,
        payload: [UInt8],
        expectedLength: UInt32,
        direction: UsbipDirection,
        kind: HostUsbTransferKind,
        timeout: TimeInterval
    ) throws -> HostUsbTransferResult {
        guard endpointAddress == 0x81,
              direction == .in,
              kind == .bulk,
              expectedLength > 2,
              expectedLength <= UsbipSubmitCommand.maxTransferBytes else {
            throw HostUsbTransferError.endpointNotFound(endpointAddress)
        }

        state.lock()
        guard !stopped, configured, streamingAlternateSetting == 0 else {
            state.unlock()
            throw HostUsbTransferError.failed(errno: EPIPE)
        }
        let needsFrame = activeFrameOffset >= activeFrame.count
        let frameDimensions = commit.dimensions
        state.unlock()

        if needsFrame {
            let boundedTimeout = max(0.001, min(timeout, 1.0))
            guard let frame = frameSource.nextJPEGFrame(
                width: frameDimensions.0,
                height: frameDimensions.1,
                timeout: boundedTimeout
            ),
                  !frame.isEmpty,
                  frame.count <= 1_280 * 720 * 2 else {
                return HostUsbTransferResult(status: 0, actualLength: 0)
            }
            state.lock()
            guard !stopped else {
                state.unlock()
                throw HostUsbTransferError.failed(errno: ENODEV)
            }
            if activeFrameOffset >= activeFrame.count {
                activeFrame = frame
                activeFrameOffset = 0
            }
            state.unlock()
        }

        state.lock()
        defer { state.unlock() }
        guard !stopped, activeFrameOffset < activeFrame.count else {
            throw HostUsbTransferError.failed(errno: ENODEV)
        }
        let payloadCapacity = Int(expectedLength) - 2
        let remaining = activeFrame.count - activeFrameOffset
        let amount = min(payloadCapacity, remaining)
        let reachesEnd = amount == remaining
        var result = [UInt8](repeating: 0, count: 2 + amount)
        result[0] = 2
        // EOH | EOF (when applicable) | FID.
        result[1] = 0x80 | (reachesEnd ? 0x02 : 0) | frameIdentifier
        result.replaceSubrange(
            2..<result.count,
            with: activeFrame[activeFrameOffset..<(activeFrameOffset + amount)]
        )
        activeFrameOffset += amount
        if reachesEnd {
            activeFrame.removeAll(keepingCapacity: true)
            activeFrameOffset = 0
            frameIdentifier ^= 1
        }
        return HostUsbTransferResult(
            status: 0,
            actualLength: UInt32(result.count),
            data: result
        )
    }

    public func abort(endpointAddress: UInt8?) throws {
        guard endpointAddress == nil || endpointAddress == 0 || endpointAddress == 0x81 else {
            throw HostUsbTransferError.endpointNotFound(endpointAddress ?? 0)
        }
        if endpointAddress == nil {
            state.lock()
            let shouldStop = !stopped
            stopped = true
            activeFrame.removeAll()
            activeFrameOffset = 0
            state.unlock()
            if shouldStop { frameSource.stop() }
        }
    }

    private func standardControl(
        _ setup: HostUsbControlSetup,
        direction: UsbipDirection
    ) throws -> HostUsbTransferResult {
        switch (setup.request, direction) {
        case (StandardRequest.getDescriptor, .in):
            let descriptorType = UInt8(setup.value >> 8)
            let descriptorIndex = UInt8(setup.value & 0xFF)
            let bytes: [UInt8]
            switch descriptorType {
            case 0x01: bytes = Self.deviceDescriptor
            case 0x02: bytes = Self.configurationDescriptor
            case 0x03: bytes = try Self.stringDescriptor(index: descriptorIndex)
            default: throw HostUsbTransferError.failed(errno: EPIPE)
            }
            return Self.inputResult(bytes, length: setup.length)
        case (StandardRequest.setConfiguration, .out):
            guard setup.value == 0 || setup.value == 1 else {
                throw HostUsbTransferError.failed(errno: EINVAL)
            }
            state.withLock {
                configured = setup.value == 1
                if !configured { streamingAlternateSetting = 0 }
            }
            return HostUsbTransferResult(status: 0, actualLength: 0)
        case (StandardRequest.getConfiguration, .in):
            let value: UInt8 = state.withLock { configured ? 1 : 0 }
            return Self.inputResult([value], length: setup.length)
        case (StandardRequest.setInterface, .out):
            guard setup.index == 1, setup.value == 0 else {
                throw HostUsbTransferError.failed(errno: EINVAL)
            }
            state.withLock { streamingAlternateSetting = 0 }
            return HostUsbTransferResult(status: 0, actualLength: 0)
        case (StandardRequest.getInterface, .in):
            guard setup.index <= 1 else { throw HostUsbTransferError.failed(errno: EINVAL) }
            let alternate: UInt8 = setup.index == 1
                ? state.withLock { streamingAlternateSetting } : 0
            return Self.inputResult([alternate], length: setup.length)
        case (StandardRequest.getStatus, .in):
            return Self.inputResult([0, 0], length: setup.length)
        case (StandardRequest.clearFeature, .out):
            return HostUsbTransferResult(status: 0, actualLength: 0)
        default:
            throw HostUsbTransferError.failed(errno: EPIPE)
        }
    }

    private func videoClassControl(
        _ setup: HostUsbControlSetup,
        payload: [UInt8],
        direction: UsbipDirection
    ) throws -> HostUsbTransferResult {
        let selector = UInt8(setup.value >> 8)
        let interface = UInt8(setup.index & 0xFF)
        guard interface == 1, selector == 1 || selector == 2 else {
            throw HostUsbTransferError.failed(errno: EPIPE)
        }
        switch (setup.request, direction) {
        case (UVCRequest.setCurrent, .out):
            guard let value = StreamControl(payload) else {
                throw HostUsbTransferError.failed(errno: EINVAL)
            }
            state.withLock {
                if selector == 1 { probe = value } else { commit = value }
            }
            return HostUsbTransferResult(
                status: 0,
                actualLength: UInt32(min(payload.count, Int(setup.length)))
            )
        case (UVCRequest.getCurrent, .in):
            let value = state.withLock { selector == 1 ? probe : commit }
            return Self.inputResult(value.encoded, length: setup.length)
        case (UVCRequest.getMinimum, .in), (UVCRequest.getResolution, .in),
             (UVCRequest.getDefault, .in):
            return Self.inputResult(StreamControl().encoded, length: setup.length)
        case (UVCRequest.getMaximum, .in):
            var maximum = StreamControl()
            maximum.frameIndex = 2
            maximum.frameInterval = 1_000_000
            return Self.inputResult(maximum.encoded, length: setup.length)
        case (UVCRequest.getLength, .in):
            return Self.inputResult([UInt8(StreamControl.byteCount), 0], length: setup.length)
        case (UVCRequest.getInfo, .in):
            // GET and SET are both implemented.
            return Self.inputResult([0x03], length: setup.length)
        default:
            throw HostUsbTransferError.failed(errno: EPIPE)
        }
    }

    private static func inputResult(_ bytes: [UInt8], length: UInt16) -> HostUsbTransferResult {
        let result = Array(bytes.prefix(Int(length)))
        return HostUsbTransferResult(
            status: 0,
            actualLength: UInt32(result.count),
            data: result
        )
    }

    private static func stringDescriptor(index: UInt8) throws -> [UInt8] {
        if index == 0 { return [4, 3, 0x09, 0x04] }
        let value: String
        switch index {
        case 1: value = "Dory"
        case 2: value = "Dory Camera"
        case 3: value = "DORY-CAMERA-1"
        default: throw HostUsbTransferError.failed(errno: EPIPE)
        }
        var bytes: [UInt8] = [UInt8(2 + value.utf16.count * 2), 3]
        for scalar in value.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: scalar))
            bytes.append(UInt8(truncatingIfNeeded: scalar >> 8))
        }
        return bytes
    }

    private static let deviceDescriptor: [UInt8] = [
        18, 0x01, 0x00, 0x02, 0xEF, 0x02, 0x01, 64,
        0xF1, 0xD0, 0x01, 0xCA, 0x00, 0x01, 1, 2, 3, 1,
    ]

    private static let configurationDescriptor: [UInt8] = {
        var bytes: [UInt8] = [
            // Configuration and Video IAD.
            9, 0x02, 186, 0, 2, 1, 0, 0x80, 250,
            8, 0x0B, 0, 2, 0x0E, 0x03, 0x00, 2,
            // VideoControl interface.
            9, 0x04, 0, 0, 0, 0x0E, 0x01, 0x00, 0,
            13, 0x24, 0x01, 0x10, 0x01, 53, 0,
            0x00, 0x6C, 0xDC, 0x02, 1, 1,
            // Camera input terminal.
            18, 0x24, 0x02, 1, 0x01, 0x02, 0, 0,
            0, 0, 0, 0, 0, 0, 3, 0, 0, 0,
            // Processing unit and USB streaming output terminal.
            13, 0x24, 0x05, 2, 1, 0, 0, 3, 0, 0, 0, 0, 0,
            9, 0x24, 0x03, 3, 0x01, 0x01, 0, 2, 0,
            // A bulk UVC stream has one alternate setting and its endpoint lives on setting 0.
            // Linux uses `num_altsetting == 1` to select its bulk decoder.
            9, 0x04, 1, 0, 1, 0x0E, 0x02, 0x00, 0,
            14, 0x24, 0x01, 1, 91, 0, 0x81, 0, 3, 0, 0, 0, 1, 0,
            11, 0x24, 0x06, 1, 2, 0, 2, 0, 0, 0, 0,
        ]
        func appendFrame(index: UInt8, width: UInt16, height: UInt16) {
            let pixels = UInt32(width) * UInt32(height)
            let minimumBitRate = pixels * 8 * 5
            let maximumBitRate = pixels * 16 * 30
            let maximumFrameBytes = pixels * 2
            bytes.append(contentsOf: [30, 0x24, 0x07, index, 0])
            appendLE(width, to: &bytes)
            appendLE(height, to: &bytes)
            appendLE(minimumBitRate, to: &bytes)
            appendLE(maximumBitRate, to: &bytes)
            appendLE(maximumFrameBytes, to: &bytes)
            appendLE(UInt32(333_333), to: &bytes)
            bytes.append(1)
            appendLE(UInt32(333_333), to: &bytes)
        }
        appendFrame(index: 1, width: 640, height: 480)
        appendFrame(index: 2, width: 1_280, height: 720)
        bytes.append(contentsOf: [6, 0x24, 0x0D, 1, 1, 4])
        bytes.append(contentsOf: [7, 0x05, 0x81, 0x02, 0x00, 0x02, 0])
        precondition(bytes.count == 186)
        return bytes
    }()

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
