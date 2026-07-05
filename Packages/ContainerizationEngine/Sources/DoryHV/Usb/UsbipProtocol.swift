import Foundation

public enum UsbipProtocolError: Error, Equatable {
    case shortFrame
    case invalidString
    case transferBufferTooLarge(UInt32)
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
        guard bytes.count >= Self.byteCount else { throw UsbipProtocolError.shortFrame }
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
        guard bytes.count >= Self.byteCount else { throw UsbipProtocolError.shortFrame }
        let header = try UsbipOperationHeader(decoding: bytes)
        guard header.code == UsbipOpCode.reqImport.rawValue else { throw UsbipProtocolError.shortFrame }
        self.init(busID: try bytes.cString(at: 8, length: 32))
    }

    public func encoded() -> [UInt8] {
        var bytes = UsbipOperationHeader(code: UsbipOpCode.reqImport.rawValue).encoded()
        bytes.appendCString(busID, width: 32)
        return bytes
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
        self.init(
            command: UsbipOperation(rawValue: bytes.beUInt32(at: 0)) ?? .cmdSubmit,
            sequenceNumber: bytes.beUInt32(at: 4),
            deviceID: bytes.beUInt32(at: 8),
            direction: UsbipDirection(rawValue: bytes.beUInt32(at: 12)) ?? .out,
            endpoint: bytes.beUInt32(at: 16)
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
        guard bytes.count >= Self.headerByteCount else { throw UsbipProtocolError.shortFrame }
        let header = try UsbipHeaderBasic(decoding: bytes)
        let rawTransferLength = bytes.beUInt32(at: 24)
        guard rawTransferLength <= Self.maxTransferBytes else {
            throw UsbipProtocolError.transferBufferTooLarge(rawTransferLength)
        }
        let transferLength = Int(rawTransferLength)
        let payloadLength = header.direction == .out ? transferLength : 0
        guard bytes.count >= Self.headerByteCount + payloadLength else { throw UsbipProtocolError.shortFrame }
        self.init(
            header: header,
            transferFlags: bytes.beUInt32(at: 20),
            transferBufferLength: UInt32(transferLength),
            startFrame: bytes.beUInt32(at: 28),
            numberOfPackets: bytes.beUInt32(at: 32),
            interval: bytes.beUInt32(at: 36),
            setup: Array(bytes[40..<48]),
            transferBuffer: Array(bytes[48..<(48 + payloadLength)])
        )
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
        guard bytes.count >= Self.byteCount else { throw UsbipProtocolError.shortFrame }
        self.init(header: try UsbipHeaderBasic(decoding: bytes), unlinkSequenceNumber: bytes.beUInt32(at: 20))
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
        let stringBytes = slice.prefix { $0 != 0 }
        guard let string = String(bytes: stringBytes, encoding: .utf8) else {
            throw UsbipProtocolError.invalidString
        }
        return string
    }
}
