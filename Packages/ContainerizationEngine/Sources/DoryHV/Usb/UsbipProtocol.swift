import Foundation

public enum UsbipProtocolError: Error, Equatable {
    case shortFrame
    case invalidFrameLength(expected: Int, actual: Int)
    case invalidString
    case invalidVersion(UInt16)
    case unexpectedOpCode(UInt16)
    case nonzeroOperationStatus(UInt32)
    case unknownOperation(UInt32)
    case unknownDirection(UInt32)
    case unexpectedOperation(expected: UsbipOperation, actual: UsbipOperation)
    case invalidEndpoint(UInt32)
    case invalidDeviceID(UInt32)
    case unexpectedDeviceID(expected: UInt32, actual: UInt32)
    case invalidSequenceNumber(UInt32)
    case invalidStartFrame(UInt32)
    case invalidInterval(UInt32)
    case invalidSetup
    case nonzeroReservedField
    case unsupportedIsochronous(UInt32)
    case transferBufferTooLarge(UInt32)
    case unknownTransferFlags(UInt32)
    case transferDirectionFlagMismatch(flags: UInt32, direction: UsbipDirection)
    case unsupportedTransferFlags(UInt32)
}

public enum UsbipOperation: UInt32, Sendable {
    case cmdSubmit = 0x0000_0001
    case cmdUnlink = 0x0000_0002
    case retSubmit = 0x0000_0003
    case retUnlink = 0x0000_0004
}

public enum UsbipDirection: UInt32, Sendable {
    case out = 0
    case `in` = 1
}

/// Stable USB/IP UAPI flag values. Allocation/DMA flags describe the sending kernel's buffer
/// bookkeeping and have no remote semantic on Dory's copied buffers; they are accepted explicitly.
/// Flags whose wire-visible behavior Dory cannot reproduce are rejected by `inspectHeader`.
public enum UsbipTransferFlag {
    public static let shortNotOK: UInt32 = 0x0000_0001
    public static let isoAsSoonAsPossible: UInt32 = 0x0000_0002
    public static let noTransferDMAMap: UInt32 = 0x0000_0004
    public static let zeroPacket: UInt32 = 0x0000_0040
    public static let noInterrupt: UInt32 = 0x0000_0080
    public static let freeBuffer: UInt32 = 0x0000_0100
    public static let directionIn: UInt32 = 0x0000_0200
    public static let dmaMapSingle: UInt32 = 0x0001_0000
    public static let dmaMapPage: UInt32 = 0x0002_0000
    public static let dmaMapScatterGather: UInt32 = 0x0004_0000
    public static let mapLocal: UInt32 = 0x0008_0000
    public static let setupMapSingle: UInt32 = 0x0010_0000
    public static let setupMapLocal: UInt32 = 0x0020_0000
    public static let dmaScatterGatherCombined: UInt32 = 0x0040_0000
    public static let alignedTemporaryBuffer: UInt32 = 0x0080_0000

    /// Safe to ignore after the stream copied setup/data into Dory-owned memory.
    public static let senderMemoryManagement: UInt32 = noTransferDMAMap
        | freeBuffer
        | dmaMapSingle
        | dmaMapPage
        | dmaMapScatterGather
        | mapLocal
        | setupMapSingle
        | setupMapLocal
        | dmaScatterGatherCombined
        | alignedTemporaryBuffer

    /// A host-controller interrupt scheduling hint; Dory completes synchronously and preserves the
    /// completion result, so accepting it does not change guest-visible transfer semantics.
    public static let senderSchedulingHints: UInt32 = noInterrupt

    public static let known: UInt32 = shortNotOK
        | isoAsSoonAsPossible
        | senderMemoryManagement
        | zeroPacket
        | senderSchedulingHints
        | directionIn
}

public enum UsbipOpCode: UInt16, Sendable {
    case reqImport = 0x8003
    case repImport = 0x0003
}

public struct UsbipOperationHeader: Equatable, Sendable {
    public static let byteCount = 8
    public static let version: UInt16 = 0x0111

    public var version: UInt16
    public var code: UInt16
    public var status: UInt32

    public init(version: UInt16 = Self.version, code: UInt16, status: UInt32 = 0) {
        self.version = version
        self.code = code
        self.status = status
    }

    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= Self.byteCount else { throw UsbipProtocolError.shortFrame }
        self.init(version: bytes.beUInt16(at: 0), code: bytes.beUInt16(at: 2), status: bytes.beUInt32(at: 4))
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendBE(version)
        bytes.appendBE(code)
        bytes.appendBE(status)
        return bytes
    }
}

public struct UsbipDeviceDescriptor: Codable, Equatable, Sendable {
    public static let byteCount = 312

    public var path: String
    public var busID: String
    public var busNumber: UInt32
    public var deviceNumber: UInt32
    public var speed: UInt32
    public var vendorID: UInt16
    public var productID: UInt16
    public var bcdDevice: UInt16
    public var deviceClass: UInt8
    public var deviceSubClass: UInt8
    public var deviceProtocol: UInt8
    public var configurationValue: UInt8
    public var configurationCount: UInt8
    public var interfaceCount: UInt8

    public init(
        path: String,
        busID: String,
        busNumber: UInt32,
        deviceNumber: UInt32,
        speed: UInt32,
        vendorID: UInt16,
        productID: UInt16,
        bcdDevice: UInt16,
        deviceClass: UInt8,
        deviceSubClass: UInt8,
        deviceProtocol: UInt8,
        configurationValue: UInt8,
        configurationCount: UInt8,
        interfaceCount: UInt8
    ) {
        self.path = path
        self.busID = busID
        self.busNumber = busNumber
        self.deviceNumber = deviceNumber
        self.speed = speed
        self.vendorID = vendorID
        self.productID = productID
        self.bcdDevice = bcdDevice
        self.deviceClass = deviceClass
        self.deviceSubClass = deviceSubClass
        self.deviceProtocol = deviceProtocol
        self.configurationValue = configurationValue
        self.configurationCount = configurationCount
        self.interfaceCount = interfaceCount
    }

    public init(decoding bytes: [UInt8]) throws {
        try bytes.requireExactCount(Self.byteCount)
        self.init(
            path: try bytes.cString(at: 0, length: 256),
            busID: try bytes.cString(at: 256, length: 32),
            busNumber: bytes.beUInt32(at: 288),
            deviceNumber: bytes.beUInt32(at: 292),
            speed: bytes.beUInt32(at: 296),
            vendorID: bytes.beUInt16(at: 300),
            productID: bytes.beUInt16(at: 302),
            bcdDevice: bytes.beUInt16(at: 304),
            deviceClass: bytes[306],
            deviceSubClass: bytes[307],
            deviceProtocol: bytes[308],
            configurationValue: bytes[309],
            configurationCount: bytes[310],
            interfaceCount: bytes[311]
        )
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendCString(path, width: 256)
        bytes.appendCString(busID, width: 32)
        bytes.appendBE(busNumber)
        bytes.appendBE(deviceNumber)
        bytes.appendBE(speed)
        bytes.appendBE(vendorID)
        bytes.appendBE(productID)
        bytes.appendBE(bcdDevice)
        bytes.append(deviceClass)
        bytes.append(deviceSubClass)
        bytes.append(deviceProtocol)
        bytes.append(configurationValue)
        bytes.append(configurationCount)
        bytes.append(interfaceCount)
        return bytes
    }
}

public struct UsbipImportRequest: Equatable, Sendable {
    public static let byteCount = 40

    public var busID: String

    public init(busID: String) {
        self.busID = busID
    }

    public init(decoding bytes: [UInt8]) throws {
        try bytes.requireExactCount(Self.byteCount)
        let header = try UsbipOperationHeader(decoding: bytes)
        guard header.version == UsbipOperationHeader.version else {
            throw UsbipProtocolError.invalidVersion(header.version)
        }
        guard header.code == UsbipOpCode.reqImport.rawValue else {
            throw UsbipProtocolError.unexpectedOpCode(header.code)
        }
        guard header.status == 0 else {
            throw UsbipProtocolError.nonzeroOperationStatus(header.status)
        }
        let busID = try bytes.cString(at: 8, length: 32)
        guard Self.isValidBusID(busID) else { throw UsbipProtocolError.invalidString }
        self.init(busID: busID)
    }

    public func encoded() -> [UInt8] {
        var bytes = UsbipOperationHeader(code: UsbipOpCode.reqImport.rawValue).encoded()
        bytes.appendCString(busID, width: 32)
        return bytes
    }

    /// Canonical USB/IP bus-ID grammar shared by the guest import and local control boundaries.
    static func isValidBusID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count < 32 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a)
                || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x2e
                || $0 == 0x3a || $0 == 0x5f
        }
    }
}

public struct UsbipImportReply: Equatable, Sendable {
    public var status: UInt32
    public var device: UsbipDeviceDescriptor?

    public init(status: UInt32, device: UsbipDeviceDescriptor?) {
        self.status = status
        self.device = device
    }

    public func encoded() -> [UInt8] {
        var bytes = UsbipOperationHeader(code: UsbipOpCode.repImport.rawValue, status: status).encoded()
        if status == 0, let device {
            bytes.append(contentsOf: device.encoded())
        }
        return bytes
    }
}

public struct UsbipHeaderBasic: Equatable, Sendable {
    public static let byteCount = 20

    public var command: UsbipOperation
    public var sequenceNumber: UInt32
    public var deviceID: UInt32
    public var direction: UsbipDirection
    public var endpoint: UInt32

    public init(command: UsbipOperation, sequenceNumber: UInt32, deviceID: UInt32, direction: UsbipDirection, endpoint: UInt32) {
        self.command = command
        self.sequenceNumber = sequenceNumber
        self.deviceID = deviceID
        self.direction = direction
        self.endpoint = endpoint
    }

    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= Self.byteCount else { throw UsbipProtocolError.shortFrame }
        let rawOperation = bytes.beUInt32(at: 0)
        guard let operation = UsbipOperation(rawValue: rawOperation) else {
            throw UsbipProtocolError.unknownOperation(rawOperation)
        }
        let sequenceNumber = bytes.beUInt32(at: 4)
        guard sequenceNumber != 0 else {
            throw UsbipProtocolError.invalidSequenceNumber(sequenceNumber)
        }
        let deviceID = bytes.beUInt32(at: 8)
        let rawDirection = bytes.beUInt32(at: 12)
        guard let direction = UsbipDirection(rawValue: rawDirection) else {
            throw UsbipProtocolError.unknownDirection(rawDirection)
        }
        let endpoint = bytes.beUInt32(at: 16)
        guard endpoint <= 15 else { throw UsbipProtocolError.invalidEndpoint(endpoint) }
        switch operation {
        case .cmdSubmit, .cmdUnlink:
            guard deviceID != 0 else { throw UsbipProtocolError.invalidDeviceID(deviceID) }
        case .retSubmit, .retUnlink:
            guard deviceID == 0 else { throw UsbipProtocolError.invalidDeviceID(deviceID) }
            guard direction == .out, endpoint == 0 else {
                throw UsbipProtocolError.invalidEndpoint(endpoint)
            }
        }
        self.init(
            command: operation,
            sequenceNumber: sequenceNumber,
            deviceID: deviceID,
            direction: direction,
            endpoint: endpoint
        )
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendBE(command.rawValue)
        bytes.appendBE(sequenceNumber)
        bytes.appendBE(deviceID)
        bytes.appendBE(direction.rawValue)
        bytes.appendBE(endpoint)
        return bytes
    }
}

public struct UsbipSubmitCommand: Equatable, Sendable {
    public static let headerByteCount = 48
    public static let maxTransferBytes: UInt32 = 4 * 1024 * 1024

    public struct HeaderMetadata: Equatable, Sendable {
        public var header: UsbipHeaderBasic
        public var transferFlags: UInt32
        public var transferBufferLength: UInt32
        public var startFrame: UInt32
        public var numberOfPackets: UInt32
        public var interval: UInt32
        public var setup: [UInt8]

        public var isIsochronous: Bool {
            // Linux's protocol document reserves -1 for non-iso, while its current
            // usbip_pack_cmd_submit() copies the non-iso URB value (0) verbatim.
            // Both are canonical Linux peer encodings; every positive packet count is iso.
            numberOfPackets != 0 && numberOfPackets != UInt32.max
        }

        public var outPayloadByteCount: Int {
            header.direction == .out ? Int(transferBufferLength) : 0
        }
    }

    public var header: UsbipHeaderBasic
    public var transferFlags: UInt32
    public var transferBufferLength: UInt32
    public var startFrame: UInt32
    public var numberOfPackets: UInt32
    public var interval: UInt32
    public var setup: [UInt8]
    public var transferBuffer: [UInt8]

    public init(header: UsbipHeaderBasic, transferFlags: UInt32, transferBufferLength: UInt32, startFrame: UInt32, numberOfPackets: UInt32, interval: UInt32, setup: [UInt8], transferBuffer: [UInt8]) {
        self.header = header
        self.transferFlags = transferFlags
        self.transferBufferLength = transferBufferLength
        self.startFrame = startFrame
        self.numberOfPackets = numberOfPackets
        self.interval = interval
        self.setup = Array(setup.prefix(8)) + Array(repeating: 0, count: max(0, 8 - setup.count))
        self.transferBuffer = transferBuffer
    }

    public init(decoding bytes: [UInt8]) throws {
        let metadata = try Self.inspectHeader(bytes)
        guard !metadata.isIsochronous else {
            throw UsbipProtocolError.unsupportedIsochronous(metadata.numberOfPackets)
        }
        let expectedByteCount = Self.headerByteCount + metadata.outPayloadByteCount
        try bytes.requireExactCount(expectedByteCount)
        self.init(
            header: metadata.header,
            transferFlags: metadata.transferFlags,
            transferBufferLength: metadata.transferBufferLength,
            startFrame: metadata.startFrame,
            numberOfPackets: metadata.numberOfPackets,
            interval: metadata.interval,
            setup: metadata.setup,
            transferBuffer: Array(bytes[48..<expectedByteCount])
        )
    }

    /// Parses and validates only the fixed command header. The bridge uses this before reading an
    /// OUT payload so an oversized or unsupported isochronous request cannot cause payload
    /// allocation or host I/O.
    public static func inspectHeader(_ bytes: [UInt8]) throws -> HeaderMetadata {
        guard bytes.count >= Self.headerByteCount else { throw UsbipProtocolError.shortFrame }
        let header = try UsbipHeaderBasic(decoding: bytes)
        guard header.command == .cmdSubmit else {
            throw UsbipProtocolError.unexpectedOperation(expected: .cmdSubmit, actual: header.command)
        }
        let transferFlags = bytes.beUInt32(at: 20)
        try validateTransferFlags(transferFlags, direction: header.direction)
        let transferLength = bytes.beUInt32(at: 24)
        guard transferLength <= Self.maxTransferBytes else {
            throw UsbipProtocolError.transferBufferTooLarge(transferLength)
        }
        let startFrame = bytes.beUInt32(at: 28)
        let numberOfPackets = bytes.beUInt32(at: 32)
        let isIsochronous = numberOfPackets != 0 && numberOfPackets != UInt32.max
        guard isIsochronous || startFrame == 0 || startFrame == UInt32.max else {
            throw UsbipProtocolError.invalidStartFrame(startFrame)
        }
        let interval = bytes.beUInt32(at: 36)
        guard interval <= UInt32(UInt8.max) else {
            throw UsbipProtocolError.invalidInterval(interval)
        }
        let setup = Array(bytes[40..<48])
        if header.endpoint == 0 {
            let setupDirection: UsbipDirection = setup[0] & 0x80 == 0 ? .out : .in
            let setupLength = UInt32(setup[6]) | (UInt32(setup[7]) << 8)
            guard setupDirection == header.direction, setupLength == transferLength else {
                throw UsbipProtocolError.invalidSetup
            }
        } else if setup.contains(where: { $0 != 0 }) {
            throw UsbipProtocolError.invalidSetup
        }
        return HeaderMetadata(
            header: header,
            transferFlags: transferFlags,
            transferBufferLength: transferLength,
            startFrame: startFrame,
            numberOfPackets: numberOfPackets,
            interval: interval,
            setup: setup
        )
    }

    public static func validateTransferFlags(
        _ flags: UInt32,
        direction: UsbipDirection
    ) throws {
        let unknown = flags & ~UsbipTransferFlag.known
        guard unknown == 0 else { throw UsbipProtocolError.unknownTransferFlags(unknown) }
        let flagSaysIn = flags & UsbipTransferFlag.directionIn != 0
        guard flagSaysIn == (direction == .in) else {
            throw UsbipProtocolError.transferDirectionFlagMismatch(
                flags: flags,
                direction: direction
            )
        }
        let unsupported = flags
            & (UsbipTransferFlag.isoAsSoonAsPossible | UsbipTransferFlag.zeroPacket)
        guard unsupported == 0 else {
            throw UsbipProtocolError.unsupportedTransferFlags(unsupported)
        }
        guard direction == .in || flags & UsbipTransferFlag.shortNotOK == 0 else {
            throw UsbipProtocolError.unsupportedTransferFlags(
                flags & UsbipTransferFlag.shortNotOK
            )
        }
    }

    public func encoded() -> [UInt8] {
        var bytes = header.encoded()
        bytes.appendBE(transferFlags)
        bytes.appendBE(transferBufferLength)
        bytes.appendBE(startFrame)
        bytes.appendBE(numberOfPackets)
        bytes.appendBE(interval)
        bytes.append(contentsOf: setup.prefix(8))
        if header.direction == .out {
            bytes.append(contentsOf: transferBuffer)
        }
        return bytes
    }
}

public struct UsbipSubmitReply: Equatable, Sendable {
    public static let headerByteCount = 48

    public var header: UsbipHeaderBasic
    public var status: Int32
    public var actualLength: UInt32
    public var startFrame: UInt32
    public var numberOfPackets: UInt32
    public var errorCount: UInt32
    public var transferBuffer: [UInt8]

    public init(header: UsbipHeaderBasic, status: Int32, actualLength: UInt32, startFrame: UInt32 = 0, numberOfPackets: UInt32 = 0xffff_ffff, errorCount: UInt32 = 0, transferBuffer: [UInt8] = []) {
        self.header = header
        self.status = status
        self.actualLength = actualLength
        self.startFrame = startFrame
        self.numberOfPackets = numberOfPackets
        self.errorCount = errorCount
        self.transferBuffer = transferBuffer
    }

    public func encoded() -> [UInt8] {
        var bytes = header.encoded()
        bytes.appendBE(UInt32(bitPattern: status))
        bytes.appendBE(actualLength)
        bytes.appendBE(startFrame)
        bytes.appendBE(numberOfPackets)
        bytes.appendBE(errorCount)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        // Server response headers keep direction zero; payload presence is driven by the transfer result.
        if !transferBuffer.isEmpty {
            bytes.append(contentsOf: transferBuffer.prefix(Int(actualLength)))
        }
        return bytes
    }
}

public struct UsbipUnlinkCommand: Equatable, Sendable {
    public static let byteCount = 48

    public var header: UsbipHeaderBasic
    public var unlinkSequenceNumber: UInt32

    public init(header: UsbipHeaderBasic, unlinkSequenceNumber: UInt32) {
        self.header = header
        self.unlinkSequenceNumber = unlinkSequenceNumber
    }

    public init(decoding bytes: [UInt8]) throws {
        try bytes.requireExactCount(Self.byteCount)
        let header = try UsbipHeaderBasic(decoding: bytes)
        guard header.command == .cmdUnlink else {
            throw UsbipProtocolError.unexpectedOperation(expected: .cmdUnlink, actual: header.command)
        }
        guard header.direction == .out, header.endpoint == 0 else {
            throw UsbipProtocolError.invalidEndpoint(header.endpoint)
        }
        let unlinkSequenceNumber = bytes.beUInt32(at: 20)
        guard unlinkSequenceNumber != 0, unlinkSequenceNumber != header.sequenceNumber else {
            throw UsbipProtocolError.invalidSequenceNumber(unlinkSequenceNumber)
        }
        guard bytes[24..<Self.byteCount].allSatisfy({ $0 == 0 }) else {
            throw UsbipProtocolError.nonzeroReservedField
        }
        self.init(header: header, unlinkSequenceNumber: unlinkSequenceNumber)
    }

    public func encoded() -> [UInt8] {
        var bytes = header.encoded()
        bytes.appendBE(unlinkSequenceNumber)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 24))
        return bytes
    }
}

public struct UsbipUnlinkReply: Equatable, Sendable {
    public static let byteCount = 48

    public var header: UsbipHeaderBasic
    public var status: Int32

    public init(header: UsbipHeaderBasic, status: Int32) {
        self.header = header
        self.status = status
    }

    public func encoded() -> [UInt8] {
        var bytes = header.encoded()
        bytes.appendBE(UInt32(bitPattern: status))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 24))
        return bytes
    }
}

private extension Array where Element == UInt8 {
    func requireExactCount(_ expected: Int) throws {
        guard count >= expected else { throw UsbipProtocolError.shortFrame }
        guard count == expected else {
            throw UsbipProtocolError.invalidFrameLength(expected: expected, actual: count)
        }
    }

    mutating func appendBE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendCString(_ value: String, width: Int) {
        let bytes = Array(value.utf8.prefix(Swift.max(0, width - 1)))
        append(contentsOf: bytes)
        append(0)
        append(contentsOf: [UInt8](repeating: 0, count: Swift.max(0, width - bytes.count - 1)))
    }

    func beUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func beUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func cString(at offset: Int, length: Int) throws -> String {
        let end = offset + length
        guard count >= end else { throw UsbipProtocolError.shortFrame }
        let slice = self[offset..<end]
        guard let terminator = slice.firstIndex(of: 0) else {
            throw UsbipProtocolError.invalidString
        }
        guard slice[terminator..<end].allSatisfy({ $0 == 0 }) else {
            throw UsbipProtocolError.invalidString
        }
        let stringBytes = slice[..<terminator]
        guard let string = String(bytes: stringBytes, encoding: .utf8) else {
            throw UsbipProtocolError.invalidString
        }
        guard string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw UsbipProtocolError.invalidString
        }
        return string
    }
}
