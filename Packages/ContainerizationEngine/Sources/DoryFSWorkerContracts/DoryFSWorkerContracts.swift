import Foundation

/// Versioned, Foundation-only values that may cross the private DoryFS worker channel. The XPC
/// adapter transports one encoded `Data` value per call; neither side relies on Swift object
/// layout, `Codable` key handling, or guest-controlled host paths.
public enum DoryFSWorkerProtocol {
    public static let version: UInt16 = 1
}

public enum DoryFSWorkerContractError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidCapabilityID
    case invalidRequestID
    case invalidCorrelationID
    case invalidDeadline
    case invalidLimits(field: String)
    case frameTooLarge(limit: Int, actual: Int)
    case shortFrame(minimum: Int, actual: Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownFrameKind(UInt8)
    case unknownOpcodeClass(UInt8)
    case unknownReplyDisposition(UInt8)
    case unknownRejectionCode(UInt16)
    case nonzeroReservedField
    case payloadLengthMismatch(declared: UInt32, actual: Int)
    case unexpectedField(frame: String, field: String)
}

public struct DoryFSWorkerGeneration: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) throws {
        guard rawValue != 0 else { throw DoryFSWorkerContractError.invalidGeneration }
        self.rawValue = rawValue
    }
}

public struct DoryFSShareCapabilityID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zeroUUID else {
            throw DoryFSWorkerContractError.invalidCapabilityID
        }
        self.rawValue = rawValue
    }

    public static func random() -> Self {
        // UUID() cannot produce the all-zero sentinel in practice. Retain the loop so the type's
        // invariant remains unconditional rather than probabilistic.
        while true {
            if let value = try? Self(rawValue: UUID()) { return value }
        }
    }

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

public enum DoryFSWorkerOpcodeClass: UInt8, Equatable, Sendable {
    /// Connection setup and non-filesystem control work.
    case control = 1
    /// Namespace/attribute work that does not modify host state.
    case metadata = 2
    /// File or directory payload transfer.
    case data = 3
    /// Any operation that may change namespace, data, attributes, mappings, or locks.
    case mutation = 4
    /// Priority cancellation control; adapters must not queue it behind normal blocking work.
    case interrupt = 5
}

public enum DoryFSWorkerRejectionCode: UInt16, Equatable, Sendable {
    case invalidRequest = 1
    case staleGeneration = 2
    case unknownShare = 3
    case deadlineExpired = 4
    case resourceExhausted = 5
    case shuttingDown = 6
    case internalFailure = 7
    /// This FUSE connection accepted DESTROY and no longer admits filesystem work. The worker
    /// generation remains fail-stop; callers must not reinterpret this as a reconnect invitation.
    case connectionTeardown = 8
}

/// Immutable launch-envelope bounds. A future worker receives the same values at bootstrap; the
/// broker enforces them before IPC and the worker must independently enforce them after decoding.
public struct DoryFSWorkerLimits: Equatable, Sendable {
    public static let absoluteMaximumFrameBytes = 2 * 1_024 * 1_024

    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumFrameBytes: Int
    public let maximumInFlightRequests: Int
    public let maximumAggregateRequestBytes: Int
    public let maximumAggregateResponseBytes: Int
    public let maximumOperationNanoseconds: UInt64
    public let maximumDrainNanoseconds: UInt64

    public init(
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        maximumFrameBytes: Int,
        maximumInFlightRequests: Int,
        maximumAggregateRequestBytes: Int,
        maximumAggregateResponseBytes: Int,
        maximumOperationNanoseconds: UInt64,
        maximumDrainNanoseconds: UInt64
    ) throws {
        guard maximumRequestBytes > 0 else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumRequestBytes")
        }
        guard maximumResponseBytes >= 0 else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumResponseBytes")
        }
        guard maximumFrameBytes >= DoryFSWorkerFrameCodec.headerByteCount,
              maximumFrameBytes <= Self.absoluteMaximumFrameBytes else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumFrameBytes")
        }
        let largestPayload = max(maximumRequestBytes, maximumResponseBytes)
        guard largestPayload <= maximumFrameBytes - DoryFSWorkerFrameCodec.headerByteCount else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumFrameBytes")
        }
        guard maximumInFlightRequests > 0 else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumInFlightRequests")
        }
        guard maximumAggregateRequestBytes >= maximumRequestBytes else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumAggregateRequestBytes")
        }
        guard maximumAggregateResponseBytes >= maximumResponseBytes else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumAggregateResponseBytes")
        }
        guard maximumOperationNanoseconds > 0 else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumOperationNanoseconds")
        }
        guard maximumDrainNanoseconds > 0 else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumDrainNanoseconds")
        }
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumInFlightRequests = maximumInFlightRequests
        self.maximumAggregateRequestBytes = maximumAggregateRequestBytes
        self.maximumAggregateResponseBytes = maximumAggregateResponseBytes
        self.maximumOperationNanoseconds = maximumOperationNanoseconds
        self.maximumDrainNanoseconds = maximumDrainNanoseconds
    }

    /// Matches the current one-MiB FUSE payload negotiation while limiting aggregate mailbox
    /// reservations to eight maximum-sized requests/replies and at most 32 small concurrent calls.
    public static let production: Self = try! Self(
        maximumRequestBytes: 40 + 1 * 1_024 * 1_024,
        maximumResponseBytes: 16 + 1 * 1_024 * 1_024,
        maximumFrameBytes: 1_024 * 1_024 + 128,
        maximumInFlightRequests: 32,
        maximumAggregateRequestBytes: 8 * (40 + 1 * 1_024 * 1_024),
        maximumAggregateResponseBytes: 8 * (16 + 1 * 1_024 * 1_024),
        maximumOperationNanoseconds: 30_000_000_000,
        maximumDrainNanoseconds: 5_000_000_000
    )
}

public struct DoryFSWorkerRequest: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let requestID: UInt64
    public let correlationID: UInt64
    public let opcodeClass: DoryFSWorkerOpcodeClass
    public let responseCapacity: UInt32
    public let deadlineUptimeNanoseconds: UInt64
    public let payload: Data

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        requestID: UInt64,
        correlationID: UInt64,
        opcodeClass: DoryFSWorkerOpcodeClass,
        responseCapacity: UInt32,
        deadlineUptimeNanoseconds: UInt64,
        payload: Data
    ) throws {
        guard requestID != 0 else { throw DoryFSWorkerContractError.invalidRequestID }
        guard correlationID != 0 else { throw DoryFSWorkerContractError.invalidCorrelationID }
        guard deadlineUptimeNanoseconds != 0 else {
            throw DoryFSWorkerContractError.invalidDeadline
        }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.requestID = requestID
        self.correlationID = correlationID
        self.opcodeClass = opcodeClass
        self.responseCapacity = responseCapacity
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.payload = payload
    }
}

public struct DoryFSWorkerInterrupt: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let targetRequestID: UInt64
    public let targetCorrelationID: UInt64
    public let deadlineUptimeNanoseconds: UInt64

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        targetRequestID: UInt64,
        targetCorrelationID: UInt64,
        deadlineUptimeNanoseconds: UInt64
    ) throws {
        guard targetRequestID != 0 else { throw DoryFSWorkerContractError.invalidRequestID }
        guard targetCorrelationID != 0 else {
            throw DoryFSWorkerContractError.invalidCorrelationID
        }
        guard deadlineUptimeNanoseconds != 0 else {
            throw DoryFSWorkerContractError.invalidDeadline
        }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.targetRequestID = targetRequestID
        self.targetCorrelationID = targetCorrelationID
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }
}

public struct DoryFSWorkerDrain: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let deadlineUptimeNanoseconds: UInt64

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        deadlineUptimeNanoseconds: UInt64
    ) throws {
        guard deadlineUptimeNanoseconds != 0 else {
            throw DoryFSWorkerContractError.invalidDeadline
        }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }
}

public struct DoryFSWorkerInvalidation: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID
    ) {
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
    }
}

/// Completes the second phase of one worker execution after the VMM has either published the
/// response into the exact leased virtqueue chain or proved that publication did not happen.
///
/// The worker retains any FUSE lookup/handle grants until this acknowledgement arrives. A
/// `.discardPublication` acknowledgement rolls those grants back; connection loss before either
/// acknowledgement is fail-stop for the worker generation.
public struct DoryFSWorkerPublication: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let requestID: UInt64
    public let correlationID: UInt64

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        requestID: UInt64,
        correlationID: UInt64
    ) throws {
        guard requestID != 0 else { throw DoryFSWorkerContractError.invalidRequestID }
        guard correlationID != 0 else { throw DoryFSWorkerContractError.invalidCorrelationID }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.requestID = requestID
        self.correlationID = correlationID
    }
}

public enum DoryFSWorkerReplyOutcome: Equatable, Sendable {
    case completed(Data)
    case rejected(DoryFSWorkerRejectionCode)
}

public struct DoryFSWorkerReply: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let requestID: UInt64
    public let correlationID: UInt64
    public let outcome: DoryFSWorkerReplyOutcome

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        requestID: UInt64,
        correlationID: UInt64,
        outcome: DoryFSWorkerReplyOutcome
    ) throws {
        guard requestID != 0 else { throw DoryFSWorkerContractError.invalidRequestID }
        guard correlationID != 0 else { throw DoryFSWorkerContractError.invalidCorrelationID }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.requestID = requestID
        self.correlationID = correlationID
        self.outcome = outcome
    }
}

public struct DoryFSWorkerDrained: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID
    ) {
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
    }
}

public enum DoryFSWorkerClientFrame: Equatable, Sendable {
    case execute(DoryFSWorkerRequest)
    case interrupt(DoryFSWorkerInterrupt)
    case drain(DoryFSWorkerDrain)
    case invalidate(DoryFSWorkerInvalidation)
    case commitPublication(DoryFSWorkerPublication)
    case discardPublication(DoryFSWorkerPublication)
}

public enum DoryFSWorkerServiceFrame: Equatable, Sendable {
    case reply(DoryFSWorkerReply)
    case drained(DoryFSWorkerDrained)
}

/// Exact version-1 binary framing. All integer fields are little endian, every reserved bit must be
/// zero, and the declared payload must consume the complete frame. This avoids last-key-wins and
/// unknown-field behavior at the future XPC boundary.
public enum DoryFSWorkerFrameCodec {
    public static let headerByteCount = 72

    private static let magic: [UInt8] = [0x44, 0x46, 0x53, 0x31] // "DFS1"

    private enum Kind: UInt8 {
        case execute = 1
        case interrupt = 2
        case drain = 3
        case invalidate = 4
        case reply = 5
        case drained = 6
        case commitPublication = 7
        case discardPublication = 8
    }

    public static func encode(
        _ frame: DoryFSWorkerClientFrame,
        maximumFrameBytes: Int
    ) throws -> Data {
        switch frame {
        case .execute(let request):
            return try encodeFrame(
                kind: .execute,
                generation: request.generation,
                capability: request.shareCapabilityID,
                requestID: request.requestID,
                correlationID: request.correlationID,
                deadline: request.deadlineUptimeNanoseconds,
                responseCapacity: request.responseCapacity,
                opcodeClass: request.opcodeClass.rawValue,
                disposition: 0,
                rejection: 0,
                payload: request.payload,
                maximumFrameBytes: maximumFrameBytes
            )
        case .interrupt(let interrupt):
            return try encodeFrame(
                kind: .interrupt,
                generation: interrupt.generation,
                capability: interrupt.shareCapabilityID,
                requestID: interrupt.targetRequestID,
                correlationID: interrupt.targetCorrelationID,
                deadline: interrupt.deadlineUptimeNanoseconds,
                responseCapacity: 0,
                opcodeClass: 0,
                disposition: 0,
                rejection: 0,
                payload: Data(),
                maximumFrameBytes: maximumFrameBytes
            )
        case .drain(let drain):
            return try encodeFrame(
                kind: .drain,
                generation: drain.generation,
                capability: drain.shareCapabilityID,
                requestID: 0,
                correlationID: 0,
                deadline: drain.deadlineUptimeNanoseconds,
                responseCapacity: 0,
                opcodeClass: 0,
                disposition: 0,
                rejection: 0,
                payload: Data(),
                maximumFrameBytes: maximumFrameBytes
            )
        case .invalidate(let invalidation):
            return try encodeFrame(
                kind: .invalidate,
                generation: invalidation.generation,
                capability: invalidation.shareCapabilityID,
                requestID: 0,
                correlationID: 0,
                deadline: 0,
                responseCapacity: 0,
                opcodeClass: 0,
                disposition: 0,
                rejection: 0,
                payload: Data(),
                maximumFrameBytes: maximumFrameBytes
            )
        case .commitPublication(let publication):
            return try encodePublication(
                publication,
                kind: .commitPublication,
                maximumFrameBytes: maximumFrameBytes
            )
        case .discardPublication(let publication):
            return try encodePublication(
                publication,
                kind: .discardPublication,
                maximumFrameBytes: maximumFrameBytes
            )
        }
    }

    public static func encode(
        _ frame: DoryFSWorkerServiceFrame,
        maximumFrameBytes: Int
    ) throws -> Data {
        switch frame {
        case .reply(let reply):
            let disposition: UInt8
            let rejection: UInt16
            let payload: Data
            switch reply.outcome {
            case .completed(let bytes):
                disposition = 1
                rejection = 0
                payload = bytes
            case .rejected(let code):
                disposition = 2
                rejection = code.rawValue
                payload = Data()
            }
            return try encodeFrame(
                kind: .reply,
                generation: reply.generation,
                capability: reply.shareCapabilityID,
                requestID: reply.requestID,
                correlationID: reply.correlationID,
                deadline: 0,
                responseCapacity: 0,
                opcodeClass: 0,
                disposition: disposition,
                rejection: rejection,
                payload: payload,
                maximumFrameBytes: maximumFrameBytes
            )
        case .drained(let drained):
            return try encodeFrame(
                kind: .drained,
                generation: drained.generation,
                capability: drained.shareCapabilityID,
                requestID: 0,
                correlationID: 0,
                deadline: 0,
                responseCapacity: 0,
                opcodeClass: 0,
                disposition: 0,
                rejection: 0,
                payload: Data(),
                maximumFrameBytes: maximumFrameBytes
            )
        }
    }

    public static func decodeClientFrame(
        _ data: Data,
        maximumFrameBytes: Int
    ) throws -> DoryFSWorkerClientFrame {
        let decoded = try decodeFrame(data, maximumFrameBytes: maximumFrameBytes)
        switch decoded.kind {
        case .execute:
            guard decoded.disposition == 0, decoded.rejection == 0 else {
                throw DoryFSWorkerContractError.unexpectedField(frame: "execute", field: "disposition")
            }
            guard let opcodeClass = DoryFSWorkerOpcodeClass(rawValue: decoded.opcodeClass) else {
                throw DoryFSWorkerContractError.unknownOpcodeClass(decoded.opcodeClass)
            }
            return .execute(try DoryFSWorkerRequest(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability,
                requestID: decoded.requestID,
                correlationID: decoded.correlationID,
                opcodeClass: opcodeClass,
                responseCapacity: decoded.responseCapacity,
                deadlineUptimeNanoseconds: decoded.deadline,
                payload: decoded.payload
            ))
        case .interrupt:
            try requireZero(decoded.responseCapacity, frame: "interrupt", field: "responseCapacity")
            try requireZero(decoded.opcodeClass, frame: "interrupt", field: "opcodeClass")
            try requireZero(decoded.disposition, frame: "interrupt", field: "disposition")
            try requireZero(decoded.rejection, frame: "interrupt", field: "rejection")
            try requireEmpty(decoded.payload, frame: "interrupt")
            return .interrupt(try DoryFSWorkerInterrupt(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability,
                targetRequestID: decoded.requestID,
                targetCorrelationID: decoded.correlationID,
                deadlineUptimeNanoseconds: decoded.deadline
            ))
        case .drain:
            try requireControlFieldsZero(decoded, frame: "drain", permitDeadline: true)
            return .drain(try DoryFSWorkerDrain(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability,
                deadlineUptimeNanoseconds: decoded.deadline
            ))
        case .invalidate:
            try requireControlFieldsZero(decoded, frame: "invalidate", permitDeadline: false)
            return .invalidate(DoryFSWorkerInvalidation(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability
            ))
        case .commitPublication:
            return .commitPublication(try decodePublication(decoded, frame: "commitPublication"))
        case .discardPublication:
            return .discardPublication(try decodePublication(decoded, frame: "discardPublication"))
        case .reply, .drained:
            throw DoryFSWorkerContractError.unexpectedField(frame: "client", field: "kind")
        }
    }

    public static func decodeServiceFrame(
        _ data: Data,
        maximumFrameBytes: Int
    ) throws -> DoryFSWorkerServiceFrame {
        let decoded = try decodeFrame(data, maximumFrameBytes: maximumFrameBytes)
        switch decoded.kind {
        case .reply:
            try requireZero(decoded.deadline, frame: "reply", field: "deadline")
            try requireZero(decoded.responseCapacity, frame: "reply", field: "responseCapacity")
            try requireZero(decoded.opcodeClass, frame: "reply", field: "opcodeClass")
            let outcome: DoryFSWorkerReplyOutcome
            switch decoded.disposition {
            case 1:
                try requireZero(decoded.rejection, frame: "reply", field: "rejection")
                outcome = .completed(decoded.payload)
            case 2:
                try requireEmpty(decoded.payload, frame: "reply")
                guard let rejection = DoryFSWorkerRejectionCode(rawValue: decoded.rejection) else {
                    throw DoryFSWorkerContractError.unknownRejectionCode(decoded.rejection)
                }
                outcome = .rejected(rejection)
            default:
                throw DoryFSWorkerContractError.unknownReplyDisposition(decoded.disposition)
            }
            return .reply(try DoryFSWorkerReply(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability,
                requestID: decoded.requestID,
                correlationID: decoded.correlationID,
                outcome: outcome
            ))
        case .drained:
            try requireControlFieldsZero(decoded, frame: "drained", permitDeadline: false)
            return .drained(DoryFSWorkerDrained(
                generation: decoded.generation,
                shareCapabilityID: decoded.capability
            ))
        case .execute, .interrupt, .drain, .invalidate,
             .commitPublication, .discardPublication:
            throw DoryFSWorkerContractError.unexpectedField(frame: "service", field: "kind")
        }
    }

    private static func encodePublication(
        _ publication: DoryFSWorkerPublication,
        kind: Kind,
        maximumFrameBytes: Int
    ) throws -> Data {
        try encodeFrame(
            kind: kind,
            generation: publication.generation,
            capability: publication.shareCapabilityID,
            requestID: publication.requestID,
            correlationID: publication.correlationID,
            deadline: 0,
            responseCapacity: 0,
            opcodeClass: 0,
            disposition: 0,
            rejection: 0,
            payload: Data(),
            maximumFrameBytes: maximumFrameBytes
        )
    }

    private static func decodePublication(
        _ decoded: DecodedFrame,
        frame: String
    ) throws -> DoryFSWorkerPublication {
        try requireZero(decoded.deadline, frame: frame, field: "deadline")
        try requireZero(decoded.responseCapacity, frame: frame, field: "responseCapacity")
        try requireZero(decoded.opcodeClass, frame: frame, field: "opcodeClass")
        try requireZero(decoded.disposition, frame: frame, field: "disposition")
        try requireZero(decoded.rejection, frame: frame, field: "rejection")
        try requireEmpty(decoded.payload, frame: frame)
        return try DoryFSWorkerPublication(
            generation: decoded.generation,
            shareCapabilityID: decoded.capability,
            requestID: decoded.requestID,
            correlationID: decoded.correlationID
        )
    }

    private struct DecodedFrame {
        let kind: Kind
        let generation: DoryFSWorkerGeneration
        let capability: DoryFSShareCapabilityID
        let requestID: UInt64
        let correlationID: UInt64
        let deadline: UInt64
        let responseCapacity: UInt32
        let opcodeClass: UInt8
        let disposition: UInt8
        let rejection: UInt16
        let payload: Data
    }

    private static func encodeFrame(
        kind: Kind,
        generation: DoryFSWorkerGeneration,
        capability: DoryFSShareCapabilityID,
        requestID: UInt64,
        correlationID: UInt64,
        deadline: UInt64,
        responseCapacity: UInt32,
        opcodeClass: UInt8,
        disposition: UInt8,
        rejection: UInt16,
        payload: Data,
        maximumFrameBytes: Int
    ) throws -> Data {
        try validateMaximumFrameBytes(maximumFrameBytes)
        guard payload.count <= Int(UInt32.max) else {
            throw DoryFSWorkerContractError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: Int.max
            )
        }
        let (frameSize, overflow) = headerByteCount.addingReportingOverflow(payload.count)
        guard !overflow, frameSize <= maximumFrameBytes else {
            throw DoryFSWorkerContractError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: overflow ? Int.max : frameSize
            )
        }
        var header = [UInt8]()
        header.reserveCapacity(headerByteCount)
        header.append(contentsOf: magic)
        append(DoryFSWorkerProtocol.version, to: &header)
        header.append(kind.rawValue)
        header.append(0) // flags
        append(generation.rawValue, to: &header)
        append(capability.rawValue, to: &header)
        append(requestID, to: &header)
        append(correlationID, to: &header)
        append(deadline, to: &header)
        append(responseCapacity, to: &header)
        append(UInt32(payload.count), to: &header)
        header.append(opcodeClass)
        header.append(disposition)
        append(rejection, to: &header)
        append(UInt32(0), to: &header) // reserved
        precondition(header.count == headerByteCount)

        // Keep the fixed header as the only byte-array staging. Building a payload-sized Array and
        // then converting that Array into Data duplicated every large FUSE frame before XPC.
        var data = Data(capacity: frameSize)
        data.append(contentsOf: header)
        data.append(payload)
        return data
    }

    private static func decodeFrame(
        _ data: Data,
        maximumFrameBytes: Int
    ) throws -> DecodedFrame {
        try validateMaximumFrameBytes(maximumFrameBytes)
        guard data.count <= maximumFrameBytes else {
            throw DoryFSWorkerContractError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: data.count
            )
        }
        guard data.count >= headerByteCount else {
            throw DoryFSWorkerContractError.shortFrame(
                minimum: headerByteCount,
                actual: data.count
            )
        }
        // Decode only the fixed header. The payload remains a bounded Data slice over the received
        // frame and can cross the nested RPC/frame decoder without another full-frame allocation.
        let header = [UInt8](data.prefix(headerByteCount))
        guard Array(header[0..<4]) == magic else {
            throw DoryFSWorkerContractError.invalidMagic
        }
        let version = readUInt16(header, at: 4)
        guard version == DoryFSWorkerProtocol.version else {
            throw DoryFSWorkerContractError.unsupportedVersion(version)
        }
        guard let kind = Kind(rawValue: header[6]) else {
            throw DoryFSWorkerContractError.unknownFrameKind(header[6])
        }
        guard header[7] == 0, readUInt32(header, at: 68) == 0 else {
            throw DoryFSWorkerContractError.nonzeroReservedField
        }
        let payloadLength = readUInt32(header, at: 60)
        let actualPayloadLength = data.count - headerByteCount
        guard UInt64(payloadLength) == UInt64(actualPayloadLength) else {
            throw DoryFSWorkerContractError.payloadLengthMismatch(
                declared: payloadLength,
                actual: actualPayloadLength
            )
        }
        let payloadStart = data.index(data.startIndex, offsetBy: headerByteCount)
        return DecodedFrame(
            kind: kind,
            generation: try DoryFSWorkerGeneration(rawValue: readUInt64(header, at: 8)),
            capability: try DoryFSShareCapabilityID(rawValue: readUUID(header, at: 16)),
            requestID: readUInt64(header, at: 32),
            correlationID: readUInt64(header, at: 40),
            deadline: readUInt64(header, at: 48),
            responseCapacity: readUInt32(header, at: 56),
            opcodeClass: header[64],
            disposition: header[65],
            rejection: readUInt16(header, at: 66),
            payload: data[payloadStart..<data.endIndex]
        )
    }

    private static func validateMaximumFrameBytes(_ value: Int) throws {
        guard value >= headerByteCount,
              value <= DoryFSWorkerLimits.absoluteMaximumFrameBytes else {
            throw DoryFSWorkerContractError.invalidLimits(field: "maximumFrameBytes")
        }
    }

    private static func requireControlFieldsZero(
        _ decoded: DecodedFrame,
        frame: String,
        permitDeadline: Bool
    ) throws {
        try requireZero(decoded.requestID, frame: frame, field: "requestID")
        try requireZero(decoded.correlationID, frame: frame, field: "correlationID")
        if !permitDeadline {
            try requireZero(decoded.deadline, frame: frame, field: "deadline")
        }
        try requireZero(decoded.responseCapacity, frame: frame, field: "responseCapacity")
        try requireZero(decoded.opcodeClass, frame: frame, field: "opcodeClass")
        try requireZero(decoded.disposition, frame: frame, field: "disposition")
        try requireZero(decoded.rejection, frame: frame, field: "rejection")
        try requireEmpty(decoded.payload, frame: frame)
    }

    private static func requireZero<T: BinaryInteger>(
        _ value: T,
        frame: String,
        field: String
    ) throws {
        guard value == 0 else {
            throw DoryFSWorkerContractError.unexpectedField(frame: frame, field: field)
        }
    }

    private static func requireEmpty(_ data: Data, frame: String) throws {
        guard data.isEmpty else {
            throw DoryFSWorkerContractError.unexpectedField(frame: frame, field: "payload")
        }
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func append(_ value: UUID, to bytes: inout [UInt8]) {
        let raw = value.uuid
        bytes.append(contentsOf: [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15,
        ])
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func readUUID(_ bytes: [UInt8], at offset: Int) -> UUID {
        UUID(uuid: (
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
            bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
            bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
            bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
        ))
    }
}
