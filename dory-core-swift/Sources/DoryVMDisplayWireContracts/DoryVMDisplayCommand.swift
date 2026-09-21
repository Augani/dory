import Foundation

public enum DoryVMDisplayCommandKind: String, Codable, Sendable {
    case input
    case resize
    case topology
}

public enum DoryVMDisplayInputEndpoint: String, Codable, Sendable {
    case keyboard
    case absolutePointer
    case relativePointer
}

/// One evdev event without the terminating SYN_REPORT. The VM owner adds synchronization after
/// validating the whole frame against the selected endpoint.
public struct DoryVMDisplayInputEvent: Codable, Equatable, Sendable {
    public var type: UInt16
    public var code: UInt16
    public var value: Int32

    public init(type: UInt16, code: UInt16, value: Int32) {
        self.type = type
        self.code = code
        self.value = value
    }
}

/// One enabled connector in the runtime topology. Array order is the stable scanout ID, keeping
/// KMS connector identity deterministic across add/remove cycles without accepting sparse input.
public struct DoryVMDisplayTopologyEntry: Codable, Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var physicalWidthMillimeters: UInt16
    public var physicalHeightMillimeters: UInt16

    public init(
        width: UInt32,
        height: UInt32,
        physicalWidthMillimeters: UInt16,
        physicalHeightMillimeters: UInt16
    ) {
        self.width = width
        self.height = height
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
    }
}

/// A bounded app-to-runner command. One canonical envelope covers input and display modesets so
/// the broker can enforce identity and ordering without interpreting AppKit objects.
public struct DoryVMDisplayCommand: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1
    public static let maximumEncodedByteCount = 8_192
    public static let maximumInputEventCount = 64
    public static let maximumDimension: UInt32 = 16_384

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: String
    public var sequence: UInt64
    public var kind: DoryVMDisplayCommandKind
    public var inputEndpoint: DoryVMDisplayInputEndpoint?
    public var inputEvents: [DoryVMDisplayInputEvent]
    public var scanoutID: UInt32?
    public var width: UInt32?
    public var height: UInt32?
    public var physicalWidthMillimeters: UInt16?
    public var physicalHeightMillimeters: UInt16?
    public var topology: [DoryVMDisplayTopologyEntry]?

    public static func input(
        machineID: String,
        operationID: UUID,
        sequence: UInt64,
        endpoint: DoryVMDisplayInputEndpoint,
        events: [DoryVMDisplayInputEvent]
    ) throws -> Self {
        let command = Self(
            schemaVersion: schemaVersion,
            machineID: machineID,
            operationID: operationID.uuidString.lowercased(),
            sequence: sequence,
            kind: .input,
            inputEndpoint: endpoint,
            inputEvents: events,
            scanoutID: nil,
            width: nil,
            height: nil,
            physicalWidthMillimeters: nil,
            physicalHeightMillimeters: nil,
            topology: nil
        )
        try command.validate()
        return command
    }

    public static func resize(
        machineID: String,
        operationID: UUID,
        sequence: UInt64,
        scanoutID: UInt32,
        width: UInt32,
        height: UInt32,
        physicalWidthMillimeters: UInt16,
        physicalHeightMillimeters: UInt16
    ) throws -> Self {
        let command = Self(
            schemaVersion: schemaVersion,
            machineID: machineID,
            operationID: operationID.uuidString.lowercased(),
            sequence: sequence,
            kind: .resize,
            inputEndpoint: nil,
            inputEvents: [],
            scanoutID: scanoutID,
            width: width,
            height: height,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            topology: nil
        )
        try command.validate()
        return command
    }

    public static func topology(
        machineID: String,
        operationID: UUID,
        sequence: UInt64,
        displays: [DoryVMDisplayTopologyEntry]
    ) throws -> Self {
        let command = Self(
            schemaVersion: schemaVersion,
            machineID: machineID,
            operationID: operationID.uuidString.lowercased(),
            sequence: sequence,
            kind: .topology,
            inputEndpoint: nil,
            inputEvents: [],
            scanoutID: nil,
            width: nil,
            height: nil,
            physicalWidthMillimeters: nil,
            physicalHeightMillimeters: nil,
            topology: displays
        )
        try command.validate()
        return command
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              DoryVMDisplayValidation.validMachineID(machineID),
              let parsedOperationID = UUID(uuidString: operationID),
              parsedOperationID.uuidString.lowercased() == operationID,
              sequence > 0 else {
            throw DoryVMDisplayWireError.invalidCommand
        }

        switch kind {
        case .input:
            guard let inputEndpoint,
                  !inputEvents.isEmpty,
                  inputEvents.count <= Self.maximumInputEventCount,
                  scanoutID == nil,
                  width == nil,
                  height == nil,
                  physicalWidthMillimeters == nil,
                  physicalHeightMillimeters == nil,
                  topology == nil,
                  inputEvents.allSatisfy({ Self.valid($0, for: inputEndpoint) }) else {
                throw DoryVMDisplayWireError.invalidCommand
            }
        case .resize:
            guard inputEndpoint == nil,
                  inputEvents.isEmpty,
                  let scanoutID,
                  scanoutID < DoryVMDisplayFrame.maximumScanoutCount,
                  let width,
                  let height,
                  (1...Self.maximumDimension).contains(width),
                  (1...Self.maximumDimension).contains(height),
                  let physicalWidthMillimeters,
                  let physicalHeightMillimeters,
                  physicalWidthMillimeters > 0,
                  physicalHeightMillimeters > 0,
                  topology == nil else {
                throw DoryVMDisplayWireError.invalidCommand
            }
        case .topology:
            guard inputEndpoint == nil,
                  inputEvents.isEmpty,
                  scanoutID == nil,
                  width == nil,
                  height == nil,
                  physicalWidthMillimeters == nil,
                  physicalHeightMillimeters == nil,
                  let topology,
                  !topology.isEmpty,
                  topology.count <= Int(DoryVMDisplayFrame.maximumScanoutCount),
                  topology.allSatisfy({
                      (1...Self.maximumDimension).contains($0.width)
                          && (1...Self.maximumDimension).contains($0.height)
                          && $0.physicalWidthMillimeters > 0
                          && $0.physicalHeightMillimeters > 0
                  }) else {
                throw DoryVMDisplayWireError.invalidCommand
            }
        }
    }

    private static func valid(
        _ event: DoryVMDisplayInputEvent,
        for endpoint: DoryVMDisplayInputEndpoint
    ) -> Bool {
        switch event.type {
        case 1:
            let validCode: Bool
            switch endpoint {
            case .keyboard:
                validCode = (1...255).contains(event.code)
            case .absolutePointer, .relativePointer:
                validCode = (272...276).contains(event.code)
            }
            return validCode && (0...2).contains(event.value)
        case 2:
            guard endpoint != .keyboard else { return false }
            let validCodes: [UInt16] = endpoint == .relativePointer
                ? [0, 1, 6, 8, 11, 12]
                : [6, 8, 11, 12]
            return validCodes.contains(event.code)
        case 3:
            return endpoint == .absolutePointer
                && (event.code == 0 || event.code == 1)
                && (0...32_767).contains(event.value)
        default:
            return false
        }
    }
}

public enum DoryVMDisplayCommandCodec {
    public static func encode(_ command: DoryVMDisplayCommand) throws -> Data {
        try command.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(command)
        guard data.count <= DoryVMDisplayCommand.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.commandTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DoryVMDisplayCommand {
        guard data.count <= DoryVMDisplayCommand.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.commandTooLarge
        }
        let command = try JSONDecoder().decode(DoryVMDisplayCommand.self, from: data)
        try command.validate()
        guard try encode(command) == data else {
            throw DoryVMDisplayWireError.nonCanonicalEncoding
        }
        return command
    }
}
