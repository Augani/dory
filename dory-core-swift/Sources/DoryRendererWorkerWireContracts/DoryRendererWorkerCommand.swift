import Foundation

/// Allowlisted renderer mutations. The worker has no generic symbol invocation or method-name
/// entrypoint; every new foreign call requires a protocol versioned operation here.
public enum DoryRendererWorkerOperation: UInt16, Equatable, Sendable {
    case createContext = 1
    case destroyContext = 2
    case attachResource = 3
    case detachResource = 4
    case submit3D = 5
    /// Creates one classic VirGL resource from a bounded, C-layout-independent payload. Resource
    /// backing remains a separate descriptor-authorized operation, so no guest pointer crosses the
    /// worker boundary during creation.
    case createResource3D = 6
    case createBlob = 7
    case attachBacking = 8
    case detachBacking = 9
    case unrefResource = 10
    case mapBlob = 11
    case unmapBlob = 12
    case transferToHost3D = 13
    case transferFromHost3D = 14
    case acquireScanoutLease = 15
    case releaseScanoutLease = 16
    case createFence = 17
    case resetAfterDeviceQuiesce = 18
}

public struct DoryRendererSharedRegionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zero else {
            throw DoryRendererWorkerContractError.invalidSharedRegionIdentity
        }
        self.rawValue = rawValue
    }

    public static func random() -> Self {
        while true {
            if let identity = try? Self(rawValue: UUID()) { return identity }
        }
    }

    private static let zero = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

/// Access granted to one descriptor-backed region. Guest resource backing is read/write because
/// the foreign API can update guest-visible buffers. Submit streams are admitted as separate
/// immutable read-only snapshots so the guest cannot race command decoding after admission.
public enum DoryRendererSharedRegionAccess: UInt16, Equatable, Sendable {
    case readOnly = 1
    case readWrite = 2
}

/// One checked slice of one out-of-band shared-memory file descriptor. `declaredFileSize` is
/// compared to fstat by the receiver before mmap. Descriptor indexes are canonical and dense;
/// ordered discontiguous slices may intentionally share one descriptor, while distinct descriptor
/// indexes cannot alias the same file identity.
public struct DoryRendererSharedRegionReference: Equatable, Sendable {
    public let identity: DoryRendererSharedRegionID
    public let descriptorIndex: UInt16
    public let access: DoryRendererSharedRegionAccess
    public let offset: UInt64
    public let length: UInt64
    public let declaredFileSize: UInt64

    public init(
        identity: DoryRendererSharedRegionID,
        descriptorIndex: UInt16,
        access: DoryRendererSharedRegionAccess,
        offset: UInt64,
        length: UInt64,
        declaredFileSize: UInt64
    ) throws {
        guard length > 0,
              declaredFileSize > 0,
              offset <= declaredFileSize,
              length <= declaredFileSize - offset else {
            throw DoryRendererWorkerContractError.invalidSharedRegionBounds
        }
        self.identity = identity
        self.descriptorIndex = descriptorIndex
        self.access = access
        self.offset = offset
        self.length = length
        self.declaredFileSize = declaredFileSize
    }
}

/// One generation-bound renderer request. Fixed operation fields cover identity; operation payload
/// is a bounded, versioned C-layout-independent byte record decoded only by that operation. Raw
/// guest pointers never cross this boundary. In particular, submit3D command bytes live only in
/// one read-only descriptor-backed shared region; XPC Data carries control metadata, never the
/// command stream itself.
public struct DoryRendererWorkerCommand: Equatable, Sendable {
    public let generation: DoryRendererWorkerGeneration
    public let requestID: UInt64
    public let operation: DoryRendererWorkerOperation
    public let contextID: UInt32
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let deadlineUptimeNanoseconds: UInt64
    public let sharedRegions: [DoryRendererSharedRegionReference]
    public let payload: Data

    public init(
        generation: DoryRendererWorkerGeneration,
        requestID: UInt64,
        operation: DoryRendererWorkerOperation,
        contextID: UInt32 = 0,
        resourceID: UInt32 = 0,
        resourceGeneration: UInt64 = 0,
        deadlineUptimeNanoseconds: UInt64,
        sharedRegions: [DoryRendererSharedRegionReference] = [],
        payload: Data = Data(),
        limits: DoryRendererWorkerLimits = .production
    ) throws {
        guard requestID != 0 else {
            throw DoryRendererWorkerContractError.invalidRequestID
        }
        guard deadlineUptimeNanoseconds != 0 else {
            throw DoryRendererWorkerContractError.invalidDeadline
        }
        guard payload.count <= limits.maximumCommandBytes else {
            throw DoryRendererWorkerContractError.frameTooLarge(
                limit: limits.maximumCommandBytes,
                actual: payload.count
            )
        }
        guard sharedRegions.count <= limits.maximumSharedRegions else {
            throw DoryRendererWorkerContractError.invalidSharedRegionCount(
                limit: limits.maximumSharedRegions,
                actual: sharedRegions.count
            )
        }
        // Region order is the renderer iovec order and is therefore semantic. Multiple regions
        // may intentionally slice one descriptor (for example discontiguous guest-RAM entries),
        // so descriptor indexes identify authorities rather than array positions.
        let canonicalRegions = sharedRegions
        var identities = Set<DoryRendererSharedRegionID>()
        var descriptorMetadata = [UInt16: (
            access: DoryRendererSharedRegionAccess,
            declaredFileSize: UInt64
        )]()
        var referencedBytes: UInt64 = 0
        for region in canonicalRegions {
            guard identities.insert(region.identity).inserted else {
                throw DoryRendererWorkerContractError.duplicateSharedRegionIdentity
            }
            if let metadata = descriptorMetadata[region.descriptorIndex] {
                guard metadata.access == region.access,
                      metadata.declaredFileSize == region.declaredFileSize else {
                    throw DoryRendererWorkerContractError.invalidSharedRegionBounds
                }
            } else {
                descriptorMetadata[region.descriptorIndex] = (
                    region.access,
                    region.declaredFileSize
                )
            }
            let (sum, overflow) = referencedBytes.addingReportingOverflow(region.length)
            guard !overflow, sum <= limits.maximumReferencedBytes else {
                throw DoryRendererWorkerContractError.referencedBytesTooLarge(
                    limit: limits.maximumReferencedBytes,
                    actual: overflow ? UInt64.max : sum
                )
            }
            referencedBytes = sum
        }
        let descriptorCount = descriptorMetadata.count
        guard descriptorMetadata.keys.allSatisfy({ Int($0) < descriptorCount }) else {
            throw DoryRendererWorkerContractError.descriptorCountMismatch(
                expected: descriptorCount,
                actual: descriptorMetadata.keys.map { Int($0) + 1 }.max() ?? 0
            )
        }
        try Self.validateOperation(
            operation,
            contextID: contextID,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            regions: canonicalRegions,
            payload: payload
        )
        self.generation = generation
        self.requestID = requestID
        self.operation = operation
        self.contextID = contextID
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.sharedRegions = canonicalRegions
        self.payload = payload
    }

    public func validateOutOfBandDescriptorCount(_ actual: Int) throws {
        let expected = requiredOutOfBandDescriptorCount
        guard actual == expected else {
            throw DoryRendererWorkerContractError.descriptorCountMismatch(
                expected: expected,
                actual: actual
            )
        }
    }

    public var requiredOutOfBandDescriptorCount: Int {
        guard let maximumIndex = sharedRegions.map(\.descriptorIndex).max() else { return 0 }
        return Int(maximumIndex) + 1
    }

    private static func validateOperation(
        _ operation: DoryRendererWorkerOperation,
        contextID: UInt32,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        regions: [DoryRendererSharedRegionReference],
        payload: Data
    ) throws {
        let hasContext = contextID != 0
        let hasResource = resourceID != 0
        let hasResourceGeneration = resourceGeneration != 0
        let identityIsValid: Bool
        let expectedPayloadBytes: Int?
        let requiresPayload: Bool
        let permitsRegions: Bool
        switch operation {
        case .createContext:
            identityIsValid = hasContext && !hasResource && !hasResourceGeneration
            expectedPayloadBytes = nil
            requiresPayload = true
            permitsRegions = false
        case .destroyContext:
            identityIsValid = hasContext && !hasResource && !hasResourceGeneration
            expectedPayloadBytes = 0
            requiresPayload = false
            permitsRegions = false
        case .attachResource, .detachResource:
            identityIsValid = hasContext && hasResource && hasResourceGeneration
            expectedPayloadBytes = 0
            requiresPayload = false
            permitsRegions = false
        case .submit3D:
            identityIsValid = hasContext && !hasResource && !hasResourceGeneration
            expectedPayloadBytes = 0
            requiresPayload = false
            permitsRegions = true
        case .createResource3D:
            identityIsValid = !hasContext && hasResource && !hasResourceGeneration
            expectedPayloadBytes = DoryRendererResource3DCreatePayload.byteCount
            requiresPayload = true
            permitsRegions = false
        case .createBlob:
            identityIsValid = hasResource && !hasResourceGeneration
            expectedPayloadBytes = 24
            requiresPayload = true
            permitsRegions = true
        case .attachBacking:
            identityIsValid = !hasContext && hasResource && hasResourceGeneration
            expectedPayloadBytes = 0
            requiresPayload = false
            permitsRegions = true
        case .detachBacking, .unrefResource, .mapBlob, .unmapBlob:
            identityIsValid = !hasContext && hasResource && hasResourceGeneration
            expectedPayloadBytes = 0
            requiresPayload = false
            permitsRegions = false
        case .transferToHost3D, .transferFromHost3D:
            identityIsValid = hasResource && hasResourceGeneration
            expectedPayloadBytes = 44
            requiresPayload = true
            permitsRegions = true
        case .acquireScanoutLease:
            identityIsValid = !hasContext && hasResource && hasResourceGeneration
            expectedPayloadBytes = 32
            requiresPayload = true
            permitsRegions = false
        case .releaseScanoutLease:
            identityIsValid = !hasContext && hasResource && hasResourceGeneration
            expectedPayloadBytes = 16
            requiresPayload = true
            permitsRegions = false
        case .createFence:
            identityIsValid = !hasResource && !hasResourceGeneration
            expectedPayloadBytes = 16
            requiresPayload = true
            permitsRegions = false
        case .resetAfterDeviceQuiesce:
            identityIsValid = !hasContext && !hasResource && !hasResourceGeneration
            expectedPayloadBytes = 8
            requiresPayload = true
            permitsRegions = false
        }
        guard identityIsValid else {
            throw DoryRendererWorkerContractError.invalidOperationIdentity(operation: operation)
        }
        if let expectedPayloadBytes {
            guard payload.count == expectedPayloadBytes else {
                throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
            }
        } else if requiresPayload, payload.isEmpty {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
        guard permitsRegions || regions.isEmpty else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
        if permitsRegions {
            if operation == .submit3D {
                guard regions.count == 1,
                      regions[0].access == .readOnly,
                      regions[0].offset.isMultiple(of: 8),
                      regions[0].length.isMultiple(of: 4),
                      regions[0].length / 4 <= UInt64(Int32.max) else {
                    throw DoryRendererWorkerContractError.invalidOperationPayload(
                        operation: operation
                    )
                }
            } else if !regions.allSatisfy({ $0.access == .readWrite }) {
                throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
            }
            if operation == .attachBacking, regions.isEmpty {
                throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
            }
        }
        if operation == .createContext, payload.count > 68 {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
    }
}

public enum DoryRendererWorkerCommandCodec {
    public static let headerByteCount = 64
    public static let sharedRegionByteCount = 48
    private static let magic: [UInt8] = [0x44, 0x52, 0x43, 0x31] // "DRC1"
    /// Version two replaces the v1 UInt16 region count plus reserved word with one UInt32 count.
    /// The fixed header size and following payload-length offset intentionally remain unchanged.
    private static let version: UInt16 = 3

    public static func encode(
        _ command: DoryRendererWorkerCommand,
        limits: DoryRendererWorkerLimits = .production
    ) throws -> Data {
        let maximum = try maximumFrameBytes(limits: limits)
        let regionBytes = command.sharedRegions.count * sharedRegionByteCount
        let total = headerByteCount + regionBytes + command.payload.count
        guard total <= maximum, total <= Int(UInt32.max) else {
            throw DoryRendererWorkerContractError.frameTooLarge(limit: maximum, actual: total)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(total)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(headerByteCount))
        bytes.appendLE(UInt32(total))
        bytes.appendLE(command.operation.rawValue)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(command.generation.rawValue)
        bytes.appendLE(command.requestID)
        bytes.appendLE(command.contextID)
        bytes.appendLE(command.resourceID)
        bytes.appendLE(command.resourceGeneration)
        bytes.appendLE(command.deadlineUptimeNanoseconds)
        bytes.appendLE(UInt32(command.sharedRegions.count))
        bytes.appendLE(UInt32(command.payload.count))
        precondition(bytes.count == headerByteCount)
        for region in command.sharedRegions {
            bytes.append(contentsOf: region.identity.rawValue.doryRendererBytes)
            bytes.appendLE(region.descriptorIndex)
            bytes.appendLE(region.access.rawValue)
            bytes.appendLE(region.offset)
            bytes.appendLE(region.length)
            bytes.appendLE(region.declaredFileSize)
            bytes.appendLE(UInt32(0))
        }
        bytes.append(contentsOf: command.payload)
        precondition(bytes.count == total)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererWorkerCommand {
        guard data.count >= headerByteCount else {
            throw DoryRendererWorkerContractError.shortFrame(
                minimum: headerByteCount,
                actual: data.count
            )
        }
        let maximum = try maximumFrameBytes(limits: limits)
        guard data.count <= maximum else {
            throw DoryRendererWorkerContractError.frameTooLarge(limit: maximum, actual: data.count)
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else {
            throw DoryRendererWorkerContractError.invalidMagic
        }
        let receivedVersion = bytes.leUInt16(at: 4)
        guard receivedVersion == version else {
            throw DoryRendererWorkerContractError.unsupportedVersion(receivedVersion)
        }
        let headerLength = bytes.leUInt16(at: 6)
        guard headerLength == UInt16(headerByteCount) else {
            throw DoryRendererWorkerContractError.invalidHeaderLength(headerLength)
        }
        let declaredLength = bytes.leUInt32(at: 8)
        guard Int(declaredLength) == data.count else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        guard bytes.leUInt16(at: 14) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        let operationRaw = bytes.leUInt16(at: 12)
        guard let operation = DoryRendererWorkerOperation(rawValue: operationRaw) else {
            throw DoryRendererWorkerContractError.unknownOperation(operationRaw)
        }
        let regionCount = Int(bytes.leUInt32(at: 56))
        guard regionCount <= limits.maximumSharedRegions else {
            throw DoryRendererWorkerContractError.invalidSharedRegionCount(
                limit: limits.maximumSharedRegions,
                actual: regionCount
            )
        }
        let payloadLength = Int(bytes.leUInt32(at: 60))
        let (regionBytes, regionOverflow) = regionCount.multipliedReportingOverflow(
            by: sharedRegionByteCount
        )
        let (payloadOffset, headerOverflow) = headerByteCount.addingReportingOverflow(regionBytes)
        let (expectedLength, totalOverflow) = payloadOffset.addingReportingOverflow(payloadLength)
        guard !regionOverflow, !headerOverflow, !totalOverflow,
              expectedLength == data.count else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        var regions = [DoryRendererSharedRegionReference]()
        regions.reserveCapacity(regionCount)
        for index in 0..<regionCount {
            let base = headerByteCount + index * sharedRegionByteCount
            guard bytes.leUInt32(at: base + 44) == 0 else {
                throw DoryRendererWorkerContractError.nonzeroReservedField
            }
            guard let access = DoryRendererSharedRegionAccess(
                rawValue: bytes.leUInt16(at: base + 18)
            ) else {
                throw DoryRendererWorkerContractError.unknownFlags(
                    UInt32(bytes.leUInt16(at: base + 18))
                )
            }
            regions.append(try DoryRendererSharedRegionReference(
                identity: DoryRendererSharedRegionID(
                    rawValue: UUID(doryRendererBytes: bytes[base..<(base + 16)])
                ),
                descriptorIndex: bytes.leUInt16(at: base + 16),
                access: access,
                offset: bytes.leUInt64(at: base + 20),
                length: bytes.leUInt64(at: base + 28),
                declaredFileSize: bytes.leUInt64(at: base + 36)
            ))
        }
        let payload = payloadLength == 0
            ? Data()
            : Data(bytes[payloadOffset..<expectedLength])
        let decoded = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: bytes.leUInt64(at: 16)),
            requestID: bytes.leUInt64(at: 24),
            operation: operation,
            contextID: bytes.leUInt32(at: 32),
            resourceID: bytes.leUInt32(at: 36),
            resourceGeneration: bytes.leUInt64(at: 40),
            deadlineUptimeNanoseconds: bytes.leUInt64(at: 48),
            sharedRegions: regions,
            payload: payload,
            limits: limits
        )
        guard try encode(decoded, limits: limits) == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }

    private static func maximumFrameBytes(
        limits: DoryRendererWorkerLimits
    ) throws -> Int {
        let (regionBytes, regionOverflow) = limits.maximumSharedRegions.multipliedReportingOverflow(
            by: sharedRegionByteCount
        )
        let (headersAndRegions, headerOverflow) = headerByteCount.addingReportingOverflow(
            regionBytes
        )
        let (total, totalOverflow) = headersAndRegions.addingReportingOverflow(
            limits.maximumCommandBytes
        )
        guard !regionOverflow, !headerOverflow, !totalOverflow else {
            throw DoryRendererWorkerContractError.invalidLimits(field: "maximumFrameBytes")
        }
        return total
    }
}
