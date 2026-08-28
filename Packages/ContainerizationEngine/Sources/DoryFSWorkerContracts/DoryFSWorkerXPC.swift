import Foundation

/// Runner-private XPC identity. The service is embedded in `DoryHVRunner.app`; callers must use
/// this name from that runner's private service namespace rather than searching the outer app.
public enum DoryFSWorkerXPC {
    public static let serviceName = "com.pythonxi.Dory.HVRunner.FSWorker"
}

/// The complete Objective-C/XPC surface. Control data remains an exact bounded binary envelope.
/// Bootstrap additionally transfers a bounded array of already-open directory descriptors; no
/// host path, Swift object graph, `Codable` value, or `NSError` crosses the boundary.
@objc(DoryFSWorkerXPCProtocol)
public protocol DoryFSWorkerXPCProtocol: NSObjectProtocol {
    func bootstrap(
        _ request: Data,
        rootDescriptors: [FileHandle],
        withReply reply: @escaping (Data) -> Void
    )
    func exchange(_ frame: Data, withReply reply: @escaping (Data) -> Void)
    func sendOneWay(_ frame: Data)
    func activateCoherence(withReply reply: @escaping (Data) -> Void)
    func coherenceStatus(withReply reply: @escaping (Data) -> Void)
}

/// Reverse runner interface used only for worker-local host-edit coherence. The worker sends one
/// exact generation/capability-scoped batch and retains those exact bytes until the runner replies
/// with a matching acknowledgement. No Foundation path or object graph crosses this method.
@objc(DoryFSWorkerCoherenceSinkXPCProtocol)
public protocol DoryFSWorkerCoherenceSinkXPCProtocol: NSObjectProtocol {
    func deliverCoherence(
        _ frame: Data,
        withReply reply: @escaping (Data) -> Void
    )
}

/// Constructs the single transport interface used by both peers. The descriptor allowlist is
/// explicit so bootstrap cannot widen into arbitrary secure-coded object authority.
public enum DoryFSWorkerXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: DoryFSWorkerXPCProtocol.self)
        let descriptorClasses = NSSet(
            objects: NSArray.self,
            FileHandle.self
        ) as! Set<AnyHashable>
        interface.setClasses(
            descriptorClasses,
            for: #selector(
                DoryFSWorkerXPCProtocol.bootstrap(_:rootDescriptors:withReply:)
            ),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }


    public static func makeCoherenceSink() -> NSXPCInterface {
        NSXPCInterface(with: DoryFSWorkerCoherenceSinkXPCProtocol.self)
    }
}

public enum DoryFSWorkerRPCFailureCode: UInt16, Equatable, Sendable {
    case invalidEnvelope = 1
    case bootstrapRejected = 2
    case bootstrapAlreadyAttempted = 3
    case bootstrapRequired = 4
    case staleGeneration = 5
    case unknownShare = 6
    case deadlineExpired = 7
    case resourceExhausted = 8
    case duplicateRequest = 9
    case shuttingDown = 10
    case protocolViolation = 11
    case internalFailure = 12
    case bootstrapDescriptorTransferFailed = 13
    case bootstrapRootOpenFailed = 16
    case bootstrapRootIdentityMismatch = 17
}

/// Non-sensitive stage returned when a worker rejects bootstrap authority. The wire result never
/// includes a host path, capability identifier, descriptor number, inode, or errno; it exposes only
/// the stage needed to diagnose packaging and sandbox integration without weakening the boundary.
public enum DoryFSWorkerBootstrapRejectionReason: Equatable, Sendable {
    case descriptorTransfer
    case rootOpen
    case rootIdentity
}

public extension DoryFSWorkerRPCFailureCode {
    var bootstrapRejectionReason: DoryFSWorkerBootstrapRejectionReason? {
        switch self {
        case .bootstrapDescriptorTransferFailed:
            .descriptorTransfer
        case .bootstrapRootOpenFailed:
            .rootOpen
        case .bootstrapRootIdentityMismatch:
            .rootIdentity
        default:
            nil
        }
    }
}

public enum DoryFSWorkerRPCResult: Equatable, Sendable {
    case success(Data)
    case failure(DoryFSWorkerRPCFailureCode)
}

public enum DoryFSWorkerRPCResultError: Error, Equatable, Sendable {
    case frameTooLarge(limit: Int, actual: Int)
    case shortFrame(minimum: Int, actual: Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownDisposition(UInt8)
    case unknownFailureCode(UInt16)
    case nonzeroReservedField
    case unexpectedFailureCode(UInt16)
    case unexpectedPayload
    case payloadLengthMismatch(declared: UInt32, actual: Int)
}

/// Exact outer result envelope used by bootstrap and request/reply RPCs. Inner bootstrap/FUSE
/// frames keep their own independent magic and size validation, so an adapter can never mistake a
/// malformed worker result for an authenticated service reply.
public enum DoryFSWorkerRPCResultCodec {
    public static let headerByteCount = 16
    public static let absoluteMaximumPayloadBytes =
        DoryFSWorkerBootstrapCodec.absoluteMaximumBootstrapBytes

    private static let magic: [UInt8] = [0x44, 0x46, 0x52, 0x31] // "DFR1"
    private static let version: UInt16 = 1
    private static let successDisposition: UInt8 = 1
    private static let failureDisposition: UInt8 = 2

    public static func encode(
        _ result: DoryFSWorkerRPCResult,
        maximumPayloadBytes: Int = absoluteMaximumPayloadBytes
    ) throws -> Data {
        try validateMaximum(maximumPayloadBytes)
        let disposition: UInt8
        let failureCode: UInt16
        let payload: Data
        switch result {
        case .success(let bytes):
            disposition = successDisposition
            failureCode = 0
            payload = bytes
        case .failure(let code):
            disposition = failureDisposition
            failureCode = code.rawValue
            payload = Data()
        }
        guard payload.count <= maximumPayloadBytes,
              payload.count <= Int(UInt32.max) else {
            throw DoryFSWorkerRPCResultError.frameTooLarge(
                limit: maximumPayloadBytes,
                actual: payload.count
            )
        }
        var header = [UInt8]()
        header.reserveCapacity(headerByteCount)
        header.append(contentsOf: magic)
        header.appendLE(version)
        header.append(disposition)
        header.append(0)
        header.appendLE(failureCode)
        header.appendLE(UInt16(0))
        header.appendLE(UInt32(payload.count))
        precondition(header.count == headerByteCount)

        // The inner service frame may be close to one MiB. Stage only this fixed header and append
        // the inner Data directly into one pre-sized outer allocation.
        var data = Data(capacity: headerByteCount + payload.count)
        data.append(contentsOf: header)
        data.append(payload)
        return data
    }

    public static func decode(
        _ data: Data,
        maximumPayloadBytes: Int = absoluteMaximumPayloadBytes
    ) throws -> DoryFSWorkerRPCResult {
        try validateMaximum(maximumPayloadBytes)
        let maximumFrameBytes = headerByteCount + maximumPayloadBytes
        guard data.count <= maximumFrameBytes else {
            throw DoryFSWorkerRPCResultError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: data.count
            )
        }
        guard data.count >= headerByteCount else {
            throw DoryFSWorkerRPCResultError.shortFrame(
                minimum: headerByteCount,
                actual: data.count
            )
        }
        let header = [UInt8](data.prefix(headerByteCount))
        guard Array(header[0..<4]) == magic else {
            throw DoryFSWorkerRPCResultError.invalidMagic
        }
        let receivedVersion = header.leUInt16(at: 4)
        guard receivedVersion == version else {
            throw DoryFSWorkerRPCResultError.unsupportedVersion(receivedVersion)
        }
        guard header[7] == 0, header.leUInt16(at: 10) == 0 else {
            throw DoryFSWorkerRPCResultError.nonzeroReservedField
        }
        let payloadLength = header.leUInt32(at: 12)
        let actualPayloadLength = data.count - headerByteCount
        guard UInt64(payloadLength) == UInt64(actualPayloadLength) else {
            throw DoryFSWorkerRPCResultError.payloadLengthMismatch(
                declared: payloadLength,
                actual: actualPayloadLength
            )
        }
        let failureCode = header.leUInt16(at: 8)
        let payloadStart = data.index(data.startIndex, offsetBy: headerByteCount)
        let payload = data[payloadStart..<data.endIndex]
        switch header[6] {
        case successDisposition:
            guard failureCode == 0 else {
                throw DoryFSWorkerRPCResultError.unexpectedFailureCode(failureCode)
            }
            return .success(payload)
        case failureDisposition:
            guard payload.isEmpty else {
                throw DoryFSWorkerRPCResultError.unexpectedPayload
            }
            guard let code = DoryFSWorkerRPCFailureCode(rawValue: failureCode) else {
                throw DoryFSWorkerRPCResultError.unknownFailureCode(failureCode)
            }
            return .failure(code)
        default:
            throw DoryFSWorkerRPCResultError.unknownDisposition(header[6])
        }
    }

    private static func validateMaximum(_ maximumPayloadBytes: Int) throws {
        guard maximumPayloadBytes >= 0,
              maximumPayloadBytes <= absoluteMaximumPayloadBytes else {
            throw DoryFSWorkerRPCResultError.frameTooLarge(
                limit: absoluteMaximumPayloadBytes,
                actual: maximumPayloadBytes
            )
        }
    }
}
