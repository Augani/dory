import Foundation

/// A copied virtio-gpu cursor-plane update. Cursor pixels are intentionally copied rather than
/// leased: the payload is small, bounded, and must remain usable after the guest cursor resource
/// changes. A hidden update is explicit so the app never keeps a stale cursor after reset.
public struct DoryVMDisplayCursor: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1
    public static let maximumDimension: UInt32 = 256
    public static let maximumEncodedByteCount = 400_000

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: String
    public var scanoutID: UInt32
    public var sequence: UInt64
    public var visible: Bool
    public var resourceID: UInt32
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32
    public var hotX: UInt32
    public var hotY: UInt32
    public var bytes: Data

    public static func visible(
        machineID: String,
        operationID: UUID,
        scanoutID: UInt32,
        sequence: UInt64,
        resourceID: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        hotX: UInt32,
        hotY: UInt32,
        bytes: Data
    ) throws -> Self {
        let cursor = Self(
            schemaVersion: schemaVersion,
            machineID: machineID,
            operationID: operationID.uuidString.lowercased(),
            scanoutID: scanoutID,
            sequence: sequence,
            visible: true,
            resourceID: resourceID,
            x: x,
            y: y,
            width: width,
            height: height,
            hotX: hotX,
            hotY: hotY,
            bytes: bytes
        )
        try cursor.validate()
        return cursor
    }

    public static func hidden(
        machineID: String,
        operationID: UUID,
        scanoutID: UInt32,
        sequence: UInt64
    ) throws -> Self {
        let cursor = Self(
            schemaVersion: schemaVersion,
            machineID: machineID,
            operationID: operationID.uuidString.lowercased(),
            scanoutID: scanoutID,
            sequence: sequence,
            visible: false,
            resourceID: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            hotX: 0,
            hotY: 0,
            bytes: Data()
        )
        try cursor.validate()
        return cursor
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              DoryVMDisplayValidation.validMachineID(machineID),
              let parsedOperationID = UUID(uuidString: operationID),
              parsedOperationID.uuidString.lowercased() == operationID,
              scanoutID < DoryVMDisplayFrame.maximumScanoutCount,
              sequence > 0 else {
            throw DoryVMDisplayWireError.invalidCursor
        }
        if visible {
            let (pixelCount, pixelOverflow) = UInt64(width).multipliedReportingOverflow(
                by: UInt64(height)
            )
            let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            guard resourceID > 0,
                  !pixelOverflow,
                  !byteOverflow,
                  (1...Self.maximumDimension).contains(width),
                  (1...Self.maximumDimension).contains(height),
                  hotX < width,
                  hotY < height,
                  byteCount == UInt64(bytes.count) else {
                throw DoryVMDisplayWireError.invalidCursor
            }
        } else {
            guard resourceID == 0, x == 0, y == 0,
                  width == 0, height == 0, hotX == 0, hotY == 0,
                  bytes.isEmpty else {
                throw DoryVMDisplayWireError.invalidCursor
            }
        }
    }
}

public enum DoryVMDisplayCursorCodec {
    public static func encode(_ cursor: DoryVMDisplayCursor) throws -> Data {
        try cursor.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        guard data.count <= DoryVMDisplayCursor.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.cursorTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DoryVMDisplayCursor {
        guard data.count <= DoryVMDisplayCursor.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.cursorTooLarge
        }
        let cursor = try JSONDecoder().decode(DoryVMDisplayCursor.self, from: data)
        try cursor.validate()
        guard try encode(cursor) == data else {
            throw DoryVMDisplayWireError.nonCanonicalEncoding
        }
        return cursor
    }
}
