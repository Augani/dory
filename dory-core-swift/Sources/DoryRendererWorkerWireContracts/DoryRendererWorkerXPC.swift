import Darwin
import Foundation

/// Cross-process descriptor policy shared by the renderer worker and its broker. Darwin POSIX
/// SHM descriptors report permission bits without an `S_IF*` object type, while an unlinked
/// temporary file reports `S_IFREG`; both provide the same bounded mmap authority after the
/// remaining descriptor checks succeed.
public enum DoryRendererSharedMemoryDescriptorPolicy {
    public static func accepts(mode: mode_t) -> Bool {
        let objectType = mode & S_IFMT
        let hasPrivateReadWriteMode = (mode & 0o600) == 0o600
            && (mode & 0o077) == 0
        return hasPrivateReadWriteMode && (objectType == 0 || objectType == S_IFREG)
    }
}

public enum DoryRendererWorkerRPCFailureCode: UInt16, Equatable, Sendable {
    case invalidEnvelope = 1
    case bootstrapRejected = 2
    case bootstrapAlreadyAttempted = 3
    case bootstrapRequired = 4
    case capabilityUnavailable = 5
    case staleGeneration = 6
    case deadlineExpired = 7
    case resourceExhausted = 8
    case commandRejected = 9
    case outcomeUnknown = 10
    case protocolViolation = 11
    case internalFailure = 12
    case bootstrapArtifactAuthorityFailed = 13
    case bootstrapRendererInitializationFailed = 14
    case bootstrapVenusCapabilityFailed = 15
    case bootstrapVenusContextFailed = 16
    case bootstrapSharedMemoryExportFailed = 17
    case bootstrapFenceExportFailed = 18
    case bootstrapCapabilityReceiptFailed = 19
    case bootstrapVirgl2CapabilityFailed = 20
    case bootstrapVirgl2ContextFailed = 21
}

/// Non-sensitive activation stage returned when the signed renderer worker rejects bootstrap.
/// The wire result deliberately excludes paths, digests, foreign-library messages, and errno;
/// callers learn only which sealed stage failed so packaging and GPU integration remain
/// diagnosable without widening renderer authority.
public enum DoryRendererWorkerBootstrapRejectionReason: Equatable, Sendable {
    case artifactAuthority
    case rendererInitialization
    case venusCapability
    case venusContext
    case virgl2Capability
    case virgl2Context
    case sharedMemoryExport
    case fenceExport
    case capabilityReceipt
}

public extension DoryRendererWorkerRPCFailureCode {
    var bootstrapRejectionReason: DoryRendererWorkerBootstrapRejectionReason? {
        switch self {
        case .bootstrapArtifactAuthorityFailed:
            .artifactAuthority
        case .bootstrapRendererInitializationFailed:
            .rendererInitialization
        case .bootstrapVenusCapabilityFailed:
            .venusCapability
        case .bootstrapVenusContextFailed:
            .venusContext
        case .bootstrapVirgl2CapabilityFailed:
            .virgl2Capability
        case .bootstrapVirgl2ContextFailed:
            .virgl2Context
        case .bootstrapSharedMemoryExportFailed:
            .sharedMemoryExport
        case .bootstrapFenceExportFailed:
            .fenceExport
        case .bootstrapCapabilityReceiptFailed:
            .capabilityReceipt
        default:
            nil
        }
    }
}

public enum DoryRendererWorkerRPCResult: Equatable, Sendable {
    case success(payload: Data, descriptorCount: UInt16)
    case failure(DoryRendererWorkerRPCFailureCode)
}

public enum DoryRendererWorkerRPCResultCodec {
    public static let headerByteCount = 20
    public static let absoluteMaximumPayloadBytes =
        DoryRendererWorkerLimits.absoluteMaximumCommandBytes
    private static let magic: [UInt8] = [0x44, 0x52, 0x58, 0x31] // "DRX1"
    private static let version: UInt16 = 1
    private static let successDisposition: UInt8 = 1
    private static let failureDisposition: UInt8 = 2

    public static func encode(
        _ result: DoryRendererWorkerRPCResult,
        maximumPayloadBytes: Int = absoluteMaximumPayloadBytes
    ) throws -> Data {
        try validateMaximum(maximumPayloadBytes)
        let disposition: UInt8
        let failureCode: UInt16
        let descriptorCount: UInt16
        let payload: Data
        switch result {
        case let .success(bytes, count):
            disposition = successDisposition
            failureCode = 0
            descriptorCount = count
            payload = bytes
        case .failure(let code):
            disposition = failureDisposition
            failureCode = code.rawValue
            descriptorCount = 0
            payload = Data()
        }
        guard payload.count <= maximumPayloadBytes,
              payload.count <= Int(UInt32.max) else {
            throw DoryRendererWorkerContractError.frameTooLarge(
                limit: maximumPayloadBytes,
                actual: payload.count
            )
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerByteCount + payload.count)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.append(disposition)
        bytes.append(0)
        bytes.appendLE(failureCode)
        bytes.appendLE(descriptorCount)
        bytes.appendLE(UInt32(payload.count))
        bytes.appendLE(UInt32(0))
        precondition(bytes.count == headerByteCount)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        maximumPayloadBytes: Int = absoluteMaximumPayloadBytes
    ) throws -> DoryRendererWorkerRPCResult {
        try validateMaximum(maximumPayloadBytes)
        let maximumFrameBytes = headerByteCount + maximumPayloadBytes
        guard data.count >= headerByteCount else {
            throw DoryRendererWorkerContractError.shortFrame(
                minimum: headerByteCount,
                actual: data.count
            )
        }
        guard data.count <= maximumFrameBytes else {
            throw DoryRendererWorkerContractError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: data.count
            )
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else {
            throw DoryRendererWorkerContractError.invalidMagic
        }
        let receivedVersion = bytes.leUInt16(at: 4)
        guard receivedVersion == version else {
            throw DoryRendererWorkerContractError.unsupportedVersion(receivedVersion)
        }
        guard bytes[7] == 0, bytes.leUInt32(at: 16) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        let payloadLength = Int(bytes.leUInt32(at: 12))
        guard headerByteCount + payloadLength == data.count else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: UInt32(headerByteCount + payloadLength),
                actual: data.count
            )
        }
        let failureCode = bytes.leUInt16(at: 8)
        let descriptorCount = bytes.leUInt16(at: 10)
        let payload = payloadLength == 0 ? Data() : Data(bytes[headerByteCount...])
        switch bytes[6] {
        case successDisposition:
            guard failureCode == 0 else {
                throw DoryRendererWorkerContractError.nonCanonicalEncoding
            }
            return .success(payload: payload, descriptorCount: descriptorCount)
        case failureDisposition:
            guard payload.isEmpty, descriptorCount == 0,
                  let code = DoryRendererWorkerRPCFailureCode(rawValue: failureCode) else {
                throw DoryRendererWorkerContractError.nonCanonicalEncoding
            }
            return .failure(code)
        default:
            throw DoryRendererWorkerContractError.unknownFlags(UInt32(bytes[6]))
        }
    }

    private static func validateMaximum(_ maximumPayloadBytes: Int) throws {
        guard maximumPayloadBytes >= 0,
              maximumPayloadBytes <= absoluteMaximumPayloadBytes else {
            throw DoryRendererWorkerContractError.frameTooLarge(
                limit: absoluteMaximumPayloadBytes,
                actual: maximumPayloadBytes
            )
        }
    }
}
