import Foundation

/// Version 1 of the private, one-request-per-connection USB helper protocol shared by doryd and
/// the raw-HV engine. The codec owns both the semantic variants and their exact bounded JSON wire
/// shapes so neither process can silently widen or reinterpret the cross-process ABI.
public enum DoryUSBControlV1 {
    public static let maximumFrameBytes = 8 * 1024
    public static let maximumBusIDUTF8Bytes = 31
    public static let maximumFailureMessageUTF8Bytes = 3_000
    public static let usbipVsockPort: UInt32 = 1_025

    public enum Operation: String, Sendable, Equatable {
        case attach
        case detach
    }

    public enum OpenMode: String, Codable, CaseIterable, Sendable, Equatable {
        case userAuthorized
        case seize
        case capture
    }

    public enum FailureDisposition: String, Codable, CaseIterable, Sendable, Equatable {
        /// The requested mutation did not commit, or compensation established the prior state.
        case rejected
        /// The mutation may have committed and compensation could not establish a terminal state.
        case outcomeUnknown
    }

    public struct BusID: Sendable, Equatable, Hashable {
        public let rawValue: String

        public init(rawValue: String) throws {
            guard Self.isValid(rawValue) else {
                throw CodecError.invalidBusID
            }
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) throws {
            try self.init(rawValue: rawValue)
        }

        public static func isValid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard !bytes.isEmpty, bytes.count <= maximumBusIDUTF8Bytes else {
                return false
            }
            return bytes.allSatisfy { byte in
                (0x30...0x39).contains(byte)
                    || (0x41...0x5a).contains(byte)
                    || (0x61...0x7a).contains(byte)
                    || byte == 0x2d
                    || byte == 0x2e
                    || byte == 0x3a
                    || byte == 0x5f
            }
        }
    }

    public enum Request: Sendable, Equatable {
        case attach(busID: BusID, mode: OpenMode)
        case detach(busID: BusID)

        public var operation: Operation {
            switch self {
            case .attach: .attach
            case .detach: .detach
            }
        }

        public var busID: BusID {
            switch self {
            case .attach(let busID, _), .detach(let busID): busID
            }
        }
    }

    public struct Attachment: Sendable, Equatable {
        public let port: Int
        public let vsockPort: UInt32
        public let deviceID: UInt32
        public let speed: UInt32

        public init(
            port: Int,
            vsockPort: UInt32,
            deviceID: UInt32,
            speed: UInt32
        ) throws {
            guard (0...65_535).contains(port),
                  vsockPort == DoryUSBControlV1.usbipVsockPort,
                  deviceID != 0,
                  speed > 0 else {
                throw CodecError.invalidAttachment
            }
            self.port = port
            self.vsockPort = vsockPort
            self.deviceID = deviceID
            self.speed = speed
        }
    }

    public enum Response: Sendable, Equatable {
        case attachSuccess(Attachment)
        case detachSuccess
        case failure(disposition: FailureDisposition, error: String)
    }

    public enum CodecError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyFrame
        case frameTooLarge(actual: Int, maximum: Int)
        case malformedJSON
        case duplicateField(String)
        case unexpectedFields(expected: [String], actual: [String])
        case invalidRequestShape
        case invalidResponseShape
        case invalidBusID
        case invalidAttachment
        case invalidFailureMessage

        public var description: String {
            switch self {
            case .emptyFrame:
                "USB control frame is empty"
            case .frameTooLarge(let actual, let maximum):
                "USB control frame has \(actual) bytes; maximum is \(maximum)"
            case .malformedJSON:
                "USB control frame is not a strict top-level JSON object"
            case .duplicateField(let field):
                "USB control frame repeats field \(field)"
            case .unexpectedFields(let expected, let actual):
                "USB control fields are \(actual); expected \(expected)"
            case .invalidRequestShape:
                "USB control request has an invalid semantic shape"
            case .invalidResponseShape:
                "USB control response has an invalid semantic shape"
            case .invalidBusID:
                "USB control bus identifier is invalid"
            case .invalidAttachment:
                "USB control attachment metadata is invalid"
            case .invalidFailureMessage:
                "USB control failure text is not bounded printable ASCII"
            }
        }
    }

    public static func encodeRequest(_ request: Request) throws -> Data {
        let encoded: Data
        switch request {
        case .attach(let busID, let mode):
            encoded = try encodeJSON(AttachRequestWire(
                cmd: Operation.attach.rawValue,
                busid: busID.rawValue,
                mode: mode
            ))
        case .detach(let busID):
            encoded = try encodeJSON(DetachRequestWire(
                cmd: Operation.detach.rawValue,
                busid: busID.rawValue
            ))
        }
        return try validateFrameSize(encoded)
    }

    public static func decodeRequest(_ frame: Data) throws -> Request {
        try validateFrameSize(frame)
        let fields = try StrictTopLevelJSONObject.fields(in: frame)
        let discriminator: RequestDiscriminator = try decodeJSON(frame)
        switch discriminator.cmd {
        case Operation.attach.rawValue:
            try requireExactFields(fields, expected: attachRequestFields)
            let wire: AttachRequestWire = try decodeJSON(frame)
            guard wire.cmd == Operation.attach.rawValue else {
                throw CodecError.invalidRequestShape
            }
            return .attach(busID: try BusID(wire.busid), mode: wire.mode)
        case Operation.detach.rawValue:
            try requireExactFields(fields, expected: detachRequestFields)
            let wire: DetachRequestWire = try decodeJSON(frame)
            guard wire.cmd == Operation.detach.rawValue else {
                throw CodecError.invalidRequestShape
            }
            return .detach(busID: try BusID(wire.busid))
        default:
            throw CodecError.invalidRequestShape
        }
    }

    public static func encodeResponse(_ response: Response) throws -> Data {
        let encoded: Data
        switch response {
        case .attachSuccess(let attachment):
            encoded = try encodeJSON(AttachSuccessWire(
                ok: true,
                port: attachment.port,
                vsockPort: attachment.vsockPort,
                deviceID: attachment.deviceID,
                speed: attachment.speed
            ))
        case .detachSuccess:
            encoded = try encodeJSON(DetachSuccessWire(ok: true))
        case .failure(let disposition, let error):
            guard isValidFailureMessage(error) else {
                throw CodecError.invalidFailureMessage
            }
            encoded = try encodeJSON(FailureWire(
                ok: false,
                disposition: disposition,
                error: error
            ))
        }
        return try validateFrameSize(encoded)
    }

    public static func decodeResponse(_ frame: Data) throws -> Response {
        try validateFrameSize(frame)
        let fields = try StrictTopLevelJSONObject.fields(in: frame)
        let discriminator: ResponseDiscriminator = try decodeJSON(frame)
        if discriminator.ok {
            if fields == detachSuccessFields {
                let wire: DetachSuccessWire = try decodeJSON(frame)
                guard wire.ok else { throw CodecError.invalidResponseShape }
                return .detachSuccess
            }
            if fields == attachSuccessFields {
                let wire: AttachSuccessWire = try decodeJSON(frame)
                guard wire.ok else { throw CodecError.invalidResponseShape }
                return .attachSuccess(try Attachment(
                    port: wire.port,
                    vsockPort: wire.vsockPort,
                    deviceID: wire.deviceID,
                    speed: wire.speed
                ))
            }
            throw CodecError.invalidResponseShape
        }

        try requireExactFields(fields, expected: failureFields)
        let wire: FailureWire = try decodeJSON(frame)
        guard !wire.ok, isValidFailureMessage(wire.error) else {
            throw CodecError.invalidFailureMessage
        }
        return .failure(disposition: wire.disposition, error: wire.error)
    }

    /// Converts arbitrary diagnostics into the exact failure-text domain used on the wire.
    public static func sanitizedFailureMessage(_ message: String) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(min(message.unicodeScalars.count, maximumFailureMessageUTF8Bytes))
        for scalar in message.unicodeScalars {
            let value = scalar.value
            bytes.append((0x20...0x7e).contains(value) ? UInt8(value) : UInt8(ascii: "?"))
            if bytes.count == maximumFailureMessageUTF8Bytes { break }
        }
        if message.unicodeScalars.count > maximumFailureMessageUTF8Bytes,
           maximumFailureMessageUTF8Bytes >= 3 {
            bytes.replaceSubrange((maximumFailureMessageUTF8Bytes - 3)..., with: [0x2e, 0x2e, 0x2e])
        }
        if bytes.isEmpty {
            return "USB control operation failed"
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func isValidFailureMessage(_ message: String) -> Bool {
        let bytes = Array(message.utf8)
        return !bytes.isEmpty
            && bytes.count <= maximumFailureMessageUTF8Bytes
            && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }

    private static let attachRequestFields: Set<String> = ["cmd", "busid", "mode"]
    private static let detachRequestFields: Set<String> = ["cmd", "busid"]
    private static let attachSuccessFields: Set<String> = [
        "ok", "port", "vsockPort", "deviceID", "speed",
    ]
    private static let detachSuccessFields: Set<String> = ["ok"]
    private static let failureFields: Set<String> = ["ok", "disposition", "error"]

    private static func requireExactFields(
        _ actual: Set<String>,
        expected: Set<String>
    ) throws {
        guard actual == expected else {
            throw CodecError.unexpectedFields(
                expected: expected.sorted(),
                actual: actual.sorted()
            )
        }
    }

    @discardableResult
    private static func validateFrameSize(_ frame: Data) throws -> Data {
        guard !frame.isEmpty else { throw CodecError.emptyFrame }
        guard frame.count <= maximumFrameBytes else {
            throw CodecError.frameTooLarge(
                actual: frame.count,
                maximum: maximumFrameBytes
            )
        }
        return frame
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw CodecError.invalidResponseShape
        }
    }

    private static func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as CodecError {
            throw error
        } catch {
            throw CodecError.malformedJSON
        }
    }

    private struct RequestDiscriminator: Decodable { let cmd: String }
    private struct ResponseDiscriminator: Decodable { let ok: Bool }

    private struct AttachRequestWire: Codable {
        let cmd: String
        let busid: String
        let mode: OpenMode
    }

    private struct DetachRequestWire: Codable {
        let cmd: String
        let busid: String
    }

    private struct AttachSuccessWire: Codable {
        let ok: Bool
        let port: Int
        let vsockPort: UInt32
        let deviceID: UInt32
        let speed: UInt32
    }

    private struct DetachSuccessWire: Codable { let ok: Bool }

    private struct FailureWire: Codable {
        let ok: Bool
        let disposition: FailureDisposition
        let error: String
    }

    /// Extracts semantic top-level keys before Foundation decoding so duplicate keys cannot be
    /// collapsed with last-key-wins behavior. Protocol values are intentionally flat primitives.
    private enum StrictTopLevelJSONObject {
        static func fields(in data: Data) throws -> Set<String> {
            let bytes = Array(data)
            var index = 0
            skipWhitespace(bytes, index: &index)
            guard consume(0x7b, in: bytes, index: &index) else {
                throw CodecError.malformedJSON
            }
            skipWhitespace(bytes, index: &index)
            if consume(0x7d, in: bytes, index: &index) {
                skipWhitespace(bytes, index: &index)
                guard index == bytes.count else { throw CodecError.malformedJSON }
                return []
            }

            var fields = Set<String>()
            while true {
                skipWhitespace(bytes, index: &index)
                let field = try parseString(bytes, index: &index)
                guard fields.insert(field).inserted else {
                    throw CodecError.duplicateField(field)
                }
                skipWhitespace(bytes, index: &index)
                guard consume(0x3a, in: bytes, index: &index) else {
                    throw CodecError.malformedJSON
                }
                skipWhitespace(bytes, index: &index)
                try skipPrimitiveValue(bytes, index: &index)
                skipWhitespace(bytes, index: &index)
                if consume(0x2c, in: bytes, index: &index) { continue }
                guard consume(0x7d, in: bytes, index: &index) else {
                    throw CodecError.malformedJSON
                }
                skipWhitespace(bytes, index: &index)
                guard index == bytes.count else { throw CodecError.malformedJSON }
                return fields
            }
        }

        private static func parseString(
            _ bytes: [UInt8],
            index: inout Int
        ) throws -> String {
            let start = index
            guard consume(0x22, in: bytes, index: &index) else {
                throw CodecError.malformedJSON
            }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    let encoded = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
                        throw CodecError.malformedJSON
                    }
                    return value
                }
                guard byte >= 0x20 else { throw CodecError.malformedJSON }
                if byte == 0x5c {
                    guard index < bytes.count else { throw CodecError.malformedJSON }
                    let escaped = bytes[index]
                    index += 1
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count else {
                            throw CodecError.malformedJSON
                        }
                        index += 4
                    }
                }
            }
            throw CodecError.malformedJSON
        }

        private static func skipPrimitiveValue(
            _ bytes: [UInt8],
            index: inout Int
        ) throws {
            guard index < bytes.count else { throw CodecError.malformedJSON }
            if bytes[index] == 0x22 {
                _ = try parseString(bytes, index: &index)
                return
            }
            guard bytes[index] != 0x7b, bytes[index] != 0x5b else {
                throw CodecError.malformedJSON
            }
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x2c || byte == 0x7d || isWhitespace(byte) { break }
                index += 1
            }
            guard index > start else { throw CodecError.malformedJSON }
        }

        private static func skipWhitespace(_ bytes: [UInt8], index: inout Int) {
            while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
        }

        private static func consume(
            _ byte: UInt8,
            in bytes: [UInt8],
            index: inout Int
        ) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
