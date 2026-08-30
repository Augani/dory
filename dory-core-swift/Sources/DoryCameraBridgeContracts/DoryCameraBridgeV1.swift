import Foundation

/// Versioned, bounded framing used between a Dory VZMac host runner and the guest camera relay.
/// Multi-byte integers are big-endian so a future non-Swift guest implementation has one ABI.
public enum DoryCameraBridgeV1 {
    public static let vsockPort: UInt32 = 1_030
    public static let magic: UInt32 = 0x4443_414D // "DCAM"
    public static let version: UInt16 = 1
    public static let headerByteCount = 24
    public static let maximumJPEGBytes = 4 * 1_024 * 1_024
    public static let maximumPayloadBytes = maximumJPEGBytes + 24
    public static let maximumBufferedBytes = maximumPayloadBytes + headerByteCount

    public enum MessageKind: UInt16, Sendable, Equatable {
        case start = 1
        case frame = 2
        case stop = 3
        case error = 4
    }

    public struct Message: Sendable, Equatable {
        public let kind: MessageKind
        public let sequence: UInt64
        public let payload: Data

        public init(kind: MessageKind, sequence: UInt64, payload: Data = Data()) throws {
            guard payload.count <= maximumPayloadBytes else {
                throw ProtocolError.payloadTooLarge(payload.count)
            }
            self.kind = kind
            self.sequence = sequence
            self.payload = payload
        }
    }

    public struct StartRequest: Sendable, Equatable {
        public let widthPixels: UInt32
        public let heightPixels: UInt32
        public let maximumFramesPerSecond: UInt32

        public init(widthPixels: UInt32, heightPixels: UInt32, maximumFramesPerSecond: UInt32) throws {
            guard Self.supportedDimensions.contains([widthPixels, heightPixels]) else {
                throw ProtocolError.unsupportedDimensions(widthPixels, heightPixels)
            }
            guard (1...60).contains(maximumFramesPerSecond) else {
                throw ProtocolError.invalidFrameRate(maximumFramesPerSecond)
            }
            self.widthPixels = widthPixels
            self.heightPixels = heightPixels
            self.maximumFramesPerSecond = maximumFramesPerSecond
        }

        public func encode() -> Data {
            var data = Data()
            data.appendBigEndian(widthPixels)
            data.appendBigEndian(heightPixels)
            data.appendBigEndian(maximumFramesPerSecond)
            return data
        }

        public static func decode(_ data: Data) throws -> Self {
            guard data.count == 12 else { throw ProtocolError.invalidStartPayload }
            return try Self(
                widthPixels: data.uint32(at: 0),
                heightPixels: data.uint32(at: 4),
                maximumFramesPerSecond: data.uint32(at: 8)
            )
        }

        fileprivate static let supportedDimensions: Set<[UInt32]> = [[640, 480], [1_280, 720]]
    }

    public struct JPEGFrame: Sendable, Equatable {
        public let widthPixels: UInt32
        public let heightPixels: UInt32
        public let hostPresentationTimeNanoseconds: UInt64
        public let jpeg: Data

        public init(
            widthPixels: UInt32,
            heightPixels: UInt32,
            hostPresentationTimeNanoseconds: UInt64,
            jpeg: Data
        ) throws {
            guard StartRequest.supportedDimensions.contains([widthPixels, heightPixels]) else {
                throw ProtocolError.unsupportedDimensions(widthPixels, heightPixels)
            }
            guard !jpeg.isEmpty, jpeg.count <= maximumJPEGBytes else {
                throw ProtocolError.invalidJPEGLength(jpeg.count)
            }
            self.widthPixels = widthPixels
            self.heightPixels = heightPixels
            self.hostPresentationTimeNanoseconds = hostPresentationTimeNanoseconds
            self.jpeg = jpeg
        }

        public func encode() -> Data {
            var data = Data()
            data.appendBigEndian(widthPixels)
            data.appendBigEndian(heightPixels)
            data.appendBigEndian(hostPresentationTimeNanoseconds)
            data.appendBigEndian(UInt32(jpeg.count))
            data.append(jpeg)
            return data
        }

        public static func decode(_ data: Data) throws -> Self {
            guard data.count >= 20 else { throw ProtocolError.invalidFramePayload }
            let jpegLength = Int(data.uint32(at: 16))
            guard jpegLength > 0, jpegLength <= maximumJPEGBytes,
                  data.count == 20 + jpegLength else {
                throw ProtocolError.invalidJPEGLength(jpegLength)
            }
            return try Self(
                widthPixels: data.uint32(at: 0),
                heightPixels: data.uint32(at: 4),
                hostPresentationTimeNanoseconds: data.uint64(at: 8),
                jpeg: data.subdata(in: 20..<data.count)
            )
        }
    }

    public enum ProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalidMagic(UInt32)
        case unsupportedVersion(UInt16)
        case unknownMessageKind(UInt16)
        case payloadTooLarge(Int)
        case bufferLimitExceeded(Int)
        case unexpectedSequence(expected: UInt64, actual: UInt64)
        case invalidStartPayload
        case invalidFramePayload
        case unsupportedDimensions(UInt32, UInt32)
        case invalidFrameRate(UInt32)
        case invalidJPEGLength(Int)

        public var description: String {
            switch self {
            case .invalidMagic(let value): "invalid camera bridge magic: \(value)"
            case .unsupportedVersion(let value): "unsupported camera bridge version: \(value)"
            case .unknownMessageKind(let value): "unknown camera bridge message kind: \(value)"
            case .payloadTooLarge(let count): "camera bridge payload exceeds the limit: \(count) bytes"
            case .bufferLimitExceeded(let count): "camera bridge receive buffer exceeds the limit: \(count) bytes"
            case .unexpectedSequence(let expected, let actual):
                "camera bridge sequence mismatch: expected \(expected), got \(actual)"
            case .invalidStartPayload: "invalid camera bridge start payload"
            case .invalidFramePayload: "invalid camera bridge frame payload"
            case .unsupportedDimensions(let width, let height):
                "unsupported camera dimensions: \(width)x\(height)"
            case .invalidFrameRate(let value): "invalid camera frame rate: \(value)"
            case .invalidJPEGLength(let count): "invalid camera JPEG length: \(count) bytes"
            }
        }
    }

    public static func encode(_ message: Message) -> Data {
        var data = Data()
        data.reserveCapacity(headerByteCount + message.payload.count)
        data.appendBigEndian(magic)
        data.appendBigEndian(version)
        data.appendBigEndian(message.kind.rawValue)
        data.appendBigEndian(UInt32(message.payload.count))
        data.appendBigEndian(message.sequence)
        data.appendBigEndian(UInt32(0))
        data.append(message.payload)
        return data
    }

    public struct Decoder: Sendable {
        private var buffer = Data()
        private var expectedSequence: UInt64

        public init(firstExpectedSequence: UInt64 = 0) {
            expectedSequence = firstExpectedSequence
        }

        public mutating func append(_ bytes: Data) throws -> [Message] {
            guard buffer.count <= maximumBufferedBytes - bytes.count else {
                throw ProtocolError.bufferLimitExceeded(buffer.count + bytes.count)
            }
            buffer.append(bytes)
            var messages: [Message] = []
            while buffer.count >= headerByteCount {
                let receivedMagic = buffer.uint32(at: 0)
                guard receivedMagic == magic else { throw ProtocolError.invalidMagic(receivedMagic) }
                let receivedVersion = buffer.uint16(at: 4)
                guard receivedVersion == version else {
                    throw ProtocolError.unsupportedVersion(receivedVersion)
                }
                let rawKind = buffer.uint16(at: 6)
                guard let kind = MessageKind(rawValue: rawKind) else {
                    throw ProtocolError.unknownMessageKind(rawKind)
                }
                let payloadCount = Int(buffer.uint32(at: 8))
                guard payloadCount <= maximumPayloadBytes else {
                    throw ProtocolError.payloadTooLarge(payloadCount)
                }
                let frameByteCount = headerByteCount + payloadCount
                guard buffer.count >= frameByteCount else { break }
                let sequence = buffer.uint64(at: 12)
                guard sequence == expectedSequence else {
                    throw ProtocolError.unexpectedSequence(
                        expected: expectedSequence,
                        actual: sequence
                    )
                }
                let payload = buffer.subdata(in: headerByteCount..<frameByteCount)
                messages.append(try Message(kind: kind, sequence: sequence, payload: payload))
                expectedSequence &+= 1
                buffer.removeSubrange(0..<frameByteCount)
            }
            return messages
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) }
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(self[offset + $1]) }
    }
}
