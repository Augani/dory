import Foundation

/// One reverse invalidation planned by the filesystem worker from its pinned HostFS namespace.
/// The wire value contains only Linux FUSE identities and individual entry names; it never carries
/// a host path, share tag, descriptor, or guest-controlled authority selector.
public enum DoryFSWorkerCoherenceInvalidation: Equatable, Sendable {
    case inode(nodeID: UInt64, offset: Int64, length: Int64)
    case entry(parentNodeID: UInt64, name: String, flags: UInt32)
    case delete(parentNodeID: UInt64, childNodeID: UInt64, name: String)
}

/// A retained, replayable host-edit operation for exactly one worker generation and share
/// capability. The worker must retain the exact encoded bytes until it receives a matching ACK.
public struct DoryFSWorkerCoherenceBatch: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let batchID: UInt64
    public let invalidations: [DoryFSWorkerCoherenceInvalidation]
    /// Canonical paths relative to this capability's pinned root. The runner alone maps them onto
    /// the corresponding guest mount; an absolute host or guest path cannot cross this contract.
    public let nudgeRelativePaths: [String]

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        batchID: UInt64,
        invalidations: [DoryFSWorkerCoherenceInvalidation],
        nudgeRelativePaths: [String]
    ) throws {
        guard batchID != 0 else { throw DoryFSWorkerCoherenceCodecError.invalidBatchID }
        guard !invalidations.isEmpty || !nudgeRelativePaths.isEmpty else {
            throw DoryFSWorkerCoherenceCodecError.emptyBatch
        }
        guard invalidations.count <= DoryFSWorkerCoherenceCodec.maximumInvalidations else {
            throw DoryFSWorkerCoherenceCodecError.tooManyInvalidations(
                limit: DoryFSWorkerCoherenceCodec.maximumInvalidations,
                actual: invalidations.count
            )
        }
        guard nudgeRelativePaths.count <= DoryFSWorkerCoherenceCodec.maximumNudgePaths else {
            throw DoryFSWorkerCoherenceCodecError.tooManyNudgePaths(
                limit: DoryFSWorkerCoherenceCodec.maximumNudgePaths,
                actual: nudgeRelativePaths.count
            )
        }
        var previousInvalidationKey: String?
        for invalidation in invalidations {
            switch invalidation {
            case .inode(let nodeID, let offset, let length):
                guard nodeID != 0 else {
                    throw DoryFSWorkerCoherenceCodecError.invalidNodeID
                }
                guard (offset == -1 && length == 0) || (offset == 0 && length == -1) else {
                    throw DoryFSWorkerCoherenceCodecError.invalidInvalidationRange
                }
            case .entry(let parentNodeID, let name, let flags):
                guard parentNodeID != 0 else {
                    throw DoryFSWorkerCoherenceCodecError.invalidNodeID
                }
                guard flags == 0 else {
                    throw DoryFSWorkerCoherenceCodecError.invalidEntryFlags(flags)
                }
                try DoryFSWorkerCoherenceCodec.validateEntryName(name)
            case .delete(let parentNodeID, let childNodeID, let name):
                guard parentNodeID != 0, childNodeID != 0 else {
                    throw DoryFSWorkerCoherenceCodecError.invalidNodeID
                }
                try DoryFSWorkerCoherenceCodec.validateEntryName(name)
            }
            let key = DoryFSWorkerCoherenceCodec.canonicalKey(for: invalidation)
            guard previousInvalidationKey.map({ $0 < key }) ?? true else {
                throw previousInvalidationKey == key
                    ? DoryFSWorkerCoherenceCodecError.duplicateInvalidation
                    : DoryFSWorkerCoherenceCodecError.nonCanonicalOrdering
            }
            previousInvalidationKey = key
        }
        var previousNudgePath: String?
        for path in nudgeRelativePaths {
            try DoryFSWorkerCoherenceCodec.validateRelativePath(path)
            guard previousNudgePath.map({ $0 < path }) ?? true else {
                throw previousNudgePath == path
                    ? DoryFSWorkerCoherenceCodecError.duplicateNudgePath
                    : DoryFSWorkerCoherenceCodecError.nonCanonicalOrdering
            }
            previousNudgePath = path
        }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.batchID = batchID
        self.invalidations = invalidations
        self.nudgeRelativePaths = nudgeRelativePaths
    }
}

public struct DoryFSWorkerCoherenceAcknowledgement: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let shareCapabilityID: DoryFSShareCapabilityID
    public let batchID: UInt64

    public init(
        generation: DoryFSWorkerGeneration,
        shareCapabilityID: DoryFSShareCapabilityID,
        batchID: UInt64
    ) throws {
        guard batchID != 0 else { throw DoryFSWorkerCoherenceCodecError.invalidBatchID }
        self.generation = generation
        self.shareCapabilityID = shareCapabilityID
        self.batchID = batchID
    }

    public init(accepting batch: DoryFSWorkerCoherenceBatch) throws {
        try self.init(
            generation: batch.generation,
            shareCapabilityID: batch.shareCapabilityID,
            batchID: batch.batchID
        )
    }
}

/// Bounded, path-free worker observation state used by the runner's five-second resource report.
/// Counts describe only capabilities and queues; capability UUIDs, tags, and host paths never
/// enter telemetry.
public struct DoryFSWorkerCoherenceStatus: Equatable, Sendable {
    public let generation: DoryFSWorkerGeneration
    public let running: Bool
    public let configuredShareCount: UInt32
    public let invalidationOnlyShareCount: UInt32
    public let watcherNudgeShareCount: UInt32
    public let requiredObservationShareCount: UInt32
    public let observedRequiredShareCount: UInt32
    public let observationStreamCount: UInt32
    public let pendingEventCount: UInt32
    public let pendingEventLimit: UInt32
    public let receivedEventCount: UInt64
    public let deliveredBatchCount: UInt64
    public let failedBatchCount: UInt64
    public let eventLossCount: UInt64

    public init(
        generation: DoryFSWorkerGeneration,
        running: Bool,
        configuredShareCount: UInt32,
        invalidationOnlyShareCount: UInt32,
        watcherNudgeShareCount: UInt32,
        requiredObservationShareCount: UInt32,
        observedRequiredShareCount: UInt32,
        observationStreamCount: UInt32,
        pendingEventCount: UInt32,
        pendingEventLimit: UInt32,
        receivedEventCount: UInt64,
        deliveredBatchCount: UInt64,
        failedBatchCount: UInt64,
        eventLossCount: UInt64
    ) throws {
        guard configuredShareCount <= UInt32(DoryFSWorkerBootstrapCodec.maximumShares),
              UInt64(invalidationOnlyShareCount) + UInt64(watcherNudgeShareCount)
                == UInt64(configuredShareCount),
              requiredObservationShareCount <= configuredShareCount,
              observedRequiredShareCount <= requiredObservationShareCount,
              observationStreamCount >= observedRequiredShareCount,
              pendingEventCount <= pendingEventLimit,
              pendingEventLimit <= 1_048_576 else {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidCounts
        }
        self.generation = generation
        self.running = running
        self.configuredShareCount = configuredShareCount
        self.invalidationOnlyShareCount = invalidationOnlyShareCount
        self.watcherNudgeShareCount = watcherNudgeShareCount
        self.requiredObservationShareCount = requiredObservationShareCount
        self.observedRequiredShareCount = observedRequiredShareCount
        self.observationStreamCount = observationStreamCount
        self.pendingEventCount = pendingEventCount
        self.pendingEventLimit = pendingEventLimit
        self.receivedEventCount = receivedEventCount
        self.deliveredBatchCount = deliveredBatchCount
        self.failedBatchCount = failedBatchCount
        self.eventLossCount = eventLossCount
    }
}

public enum DoryFSWorkerCoherenceStatusCodecError: Error, Equatable, Sendable {
    case invalidLength
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidFlags(UInt16)
    case nonzeroReservedField
    case invalidGeneration
    case invalidCounts
    case nonCanonicalEncoding
}

public enum DoryFSWorkerCoherenceStatusCodec {
    public static let byteCount = 96
    private static let magic: [UInt8] = [0x44, 0x46, 0x43, 0x53] // DFCS
    private static let version: UInt16 = 1

    public static func encode(_ status: DoryFSWorkerCoherenceStatus) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(status.running ? 1 : 0))
        bytes.appendLE(UInt32(byteCount))
        bytes.appendLE(UInt32(0))
        bytes.appendLE(status.generation.rawValue)
        bytes.appendLE(status.configuredShareCount)
        bytes.appendLE(status.invalidationOnlyShareCount)
        bytes.appendLE(status.watcherNudgeShareCount)
        bytes.appendLE(status.requiredObservationShareCount)
        bytes.appendLE(status.observedRequiredShareCount)
        bytes.appendLE(status.observationStreamCount)
        bytes.appendLE(status.pendingEventCount)
        bytes.appendLE(status.pendingEventLimit)
        bytes.appendLE(status.receivedEventCount)
        bytes.appendLE(status.deliveredBatchCount)
        bytes.appendLE(status.failedBatchCount)
        bytes.appendLE(status.eventLossCount)
        bytes.appendLE(UInt64(0))
        precondition(bytes.count == byteCount)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> DoryFSWorkerCoherenceStatus {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount,
              bytes.leUInt32(at: 8) == UInt32(byteCount) else {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidLength
        }
        guard Array(bytes[0..<4]) == magic else {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidMagic
        }
        guard bytes.leUInt16(at: 4) == version else {
            throw DoryFSWorkerCoherenceStatusCodecError.unsupportedVersion(
                bytes.leUInt16(at: 4)
            )
        }
        let flags = bytes.leUInt16(at: 6)
        guard flags & ~UInt16(1) == 0 else {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidFlags(flags)
        }
        guard bytes.leUInt32(at: 12) == 0, bytes.leUInt64(at: 88) == 0 else {
            throw DoryFSWorkerCoherenceStatusCodecError.nonzeroReservedField
        }
        guard let generation = try? DoryFSWorkerGeneration(
            rawValue: bytes.leUInt64(at: 16)
        ) else {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidGeneration
        }
        let status: DoryFSWorkerCoherenceStatus
        do {
            status = try DoryFSWorkerCoherenceStatus(
                generation: generation,
                running: flags & 1 == 1,
                configuredShareCount: bytes.leUInt32(at: 24),
                invalidationOnlyShareCount: bytes.leUInt32(at: 28),
                watcherNudgeShareCount: bytes.leUInt32(at: 32),
                requiredObservationShareCount: bytes.leUInt32(at: 36),
                observedRequiredShareCount: bytes.leUInt32(at: 40),
                observationStreamCount: bytes.leUInt32(at: 44),
                pendingEventCount: bytes.leUInt32(at: 48),
                pendingEventLimit: bytes.leUInt32(at: 52),
                receivedEventCount: bytes.leUInt64(at: 56),
                deliveredBatchCount: bytes.leUInt64(at: 64),
                failedBatchCount: bytes.leUInt64(at: 72),
                eventLossCount: bytes.leUInt64(at: 80)
            )
        } catch {
            throw DoryFSWorkerCoherenceStatusCodecError.invalidCounts
        }
        guard encode(status) == data else {
            throw DoryFSWorkerCoherenceStatusCodecError.nonCanonicalEncoding
        }
        return status
    }
}

public enum DoryFSWorkerCoherenceCodecError: Error, Equatable, Sendable {
    case frameTooLarge(limit: Int, actual: Int)
    case shortFrame(minimum: Int, actual: Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownFrameKind(UInt8)
    case nonzeroReservedField
    case frameLengthMismatch(declared: UInt32, actual: Int)
    case invalidGeneration
    case invalidCapabilityID
    case invalidBatchID
    case invalidNodeID
    case invalidInvalidationRange
    case invalidEntryFlags(UInt32)
    case duplicateInvalidation
    case duplicateNudgePath
    case nonCanonicalOrdering
    case emptyBatch
    case tooManyInvalidations(limit: Int, actual: Int)
    case tooManyNudgePaths(limit: Int, actual: Int)
    case invalidInvalidationKind(UInt8)
    case invalidEntryName(String)
    case invalidRelativePath(String)
    case truncatedField(String)
    case trailingBytes
    case nonCanonicalEncoding
}

/// Exact bounded binary framing for worker-to-runner coherence and runner-to-worker ACKs.
/// Unknown kinds, flags, reserved bytes, non-canonical strings, and trailing bytes fail closed.
public enum DoryFSWorkerCoherenceCodec {
    public static let maximumFrameBytes = 256 * 1_024
    public static let maximumInvalidations = 1_024
    public static let maximumNudgePaths = 512
    public static let maximumEntryNameBytes = 255
    public static let maximumRelativePathBytes = 4_095

    private static let version: UInt16 = 1
    private static let batchMagic: [UInt8] = [0x44, 0x46, 0x43, 0x31] // DFC1
    private static let acknowledgementMagic: [UInt8] = [0x44, 0x46, 0x43, 0x41] // DFCA
    private static let batchKind: UInt8 = 1
    private static let acknowledgementKind: UInt8 = 2
    private static let batchHeaderBytes = 64
    private static let invalidationHeaderBytes = 32
    private static let acknowledgementBytes = 48

    public static func encode(_ batch: DoryFSWorkerCoherenceBatch) throws -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(min(maximumFrameBytes, batchHeaderBytes + batch.invalidations.count * 32))
        bytes.append(contentsOf: batchMagic)
        bytes.appendLE(version)
        bytes.append(batchKind)
        bytes.append(0)
        bytes.appendLE(UInt32(0)) // patched after the complete bounded frame is assembled
        bytes.appendLE(UInt32(0))
        bytes.appendLE(batch.generation.rawValue)
        append(batch.shareCapabilityID.rawValue, to: &bytes)
        bytes.appendLE(batch.batchID)
        bytes.appendLE(UInt32(batch.invalidations.count))
        bytes.appendLE(UInt32(batch.nudgeRelativePaths.count))
        bytes.appendLE(UInt64(0))
        precondition(bytes.count == batchHeaderBytes)

        for invalidation in batch.invalidations {
            switch invalidation {
            case .inode(let nodeID, let offset, let length):
                appendInvalidationHeader(
                    kind: 1,
                    nameByteCount: 0,
                    first: nodeID,
                    second: UInt64(bitPattern: offset),
                    third: UInt64(bitPattern: length),
                    to: &bytes
                )
            case .entry(let parentNodeID, let name, let flags):
                try validateEntryName(name)
                let nameBytes = Array(name.utf8)
                appendInvalidationHeader(
                    kind: 2,
                    nameByteCount: nameBytes.count,
                    first: parentNodeID,
                    second: 0,
                    third: UInt64(flags),
                    to: &bytes
                )
                bytes.append(contentsOf: nameBytes)
            case .delete(let parentNodeID, let childNodeID, let name):
                try validateEntryName(name)
                let nameBytes = Array(name.utf8)
                appendInvalidationHeader(
                    kind: 3,
                    nameByteCount: nameBytes.count,
                    first: parentNodeID,
                    second: childNodeID,
                    third: 0,
                    to: &bytes
                )
                bytes.append(contentsOf: nameBytes)
            }
            guard bytes.count <= maximumFrameBytes else {
                throw DoryFSWorkerCoherenceCodecError.frameTooLarge(
                    limit: maximumFrameBytes,
                    actual: bytes.count
                )
            }
        }
        for path in batch.nudgeRelativePaths {
            try validateRelativePath(path)
            let pathBytes = Array(path.utf8)
            bytes.appendLE(UInt32(pathBytes.count))
            bytes.append(contentsOf: pathBytes)
            guard bytes.count <= maximumFrameBytes else {
                throw DoryFSWorkerCoherenceCodecError.frameTooLarge(
                    limit: maximumFrameBytes,
                    actual: bytes.count
                )
            }
        }
        guard let length = UInt32(exactly: bytes.count) else {
            throw DoryFSWorkerCoherenceCodecError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: bytes.count
            )
        }
        patchUInt32(length, at: 8, in: &bytes)
        return Data(bytes)
    }

    public static func decodeBatch(_ data: Data) throws -> DoryFSWorkerCoherenceBatch {
        let bytes = [UInt8](data)
        guard bytes.count <= maximumFrameBytes else {
            throw DoryFSWorkerCoherenceCodecError.frameTooLarge(
                limit: maximumFrameBytes,
                actual: bytes.count
            )
        }
        guard bytes.count >= batchHeaderBytes else {
            throw DoryFSWorkerCoherenceCodecError.shortFrame(
                minimum: batchHeaderBytes,
                actual: bytes.count
            )
        }
        guard Array(bytes[0..<4]) == batchMagic else {
            throw DoryFSWorkerCoherenceCodecError.invalidMagic
        }
        guard bytes.leUInt16(at: 4) == version else {
            throw DoryFSWorkerCoherenceCodecError.unsupportedVersion(bytes.leUInt16(at: 4))
        }
        guard bytes[6] == batchKind else {
            throw DoryFSWorkerCoherenceCodecError.unknownFrameKind(bytes[6])
        }
        guard bytes[7] == 0, bytes.leUInt32(at: 12) == 0, bytes.leUInt64(at: 56) == 0 else {
            throw DoryFSWorkerCoherenceCodecError.nonzeroReservedField
        }
        let declaredLength = bytes.leUInt32(at: 8)
        guard UInt64(declaredLength) == UInt64(bytes.count) else {
            throw DoryFSWorkerCoherenceCodecError.frameLengthMismatch(
                declared: declaredLength,
                actual: bytes.count
            )
        }
        guard let generation = try? DoryFSWorkerGeneration(rawValue: bytes.leUInt64(at: 16)) else {
            throw DoryFSWorkerCoherenceCodecError.invalidGeneration
        }
        guard let capability = try? DoryFSShareCapabilityID(rawValue: readUUID(bytes, at: 24)) else {
            throw DoryFSWorkerCoherenceCodecError.invalidCapabilityID
        }
        let batchID = bytes.leUInt64(at: 40)
        guard batchID != 0 else { throw DoryFSWorkerCoherenceCodecError.invalidBatchID }
        let invalidationCount = Int(bytes.leUInt32(at: 48))
        let nudgeCount = Int(bytes.leUInt32(at: 52))
        guard invalidationCount <= maximumInvalidations else {
            throw DoryFSWorkerCoherenceCodecError.tooManyInvalidations(
                limit: maximumInvalidations,
                actual: invalidationCount
            )
        }
        guard nudgeCount <= maximumNudgePaths else {
            throw DoryFSWorkerCoherenceCodecError.tooManyNudgePaths(
                limit: maximumNudgePaths,
                actual: nudgeCount
            )
        }

        var cursor = batchHeaderBytes
        var invalidations = [DoryFSWorkerCoherenceInvalidation]()
        invalidations.reserveCapacity(invalidationCount)
        for _ in 0..<invalidationCount {
            guard cursor + invalidationHeaderBytes <= bytes.count else {
                throw DoryFSWorkerCoherenceCodecError.truncatedField("invalidation")
            }
            let kind = bytes[cursor]
            guard bytes[cursor + 1] == 0,
                  bytes.leUInt16(at: cursor + 2) == 0 else {
                throw DoryFSWorkerCoherenceCodecError.nonzeroReservedField
            }
            let nameLength = Int(bytes.leUInt32(at: cursor + 4))
            let first = bytes.leUInt64(at: cursor + 8)
            let second = bytes.leUInt64(at: cursor + 16)
            let third = bytes.leUInt64(at: cursor + 24)
            cursor += invalidationHeaderBytes
            guard cursor + nameLength <= bytes.count else {
                throw DoryFSWorkerCoherenceCodecError.truncatedField("invalidation.name")
            }
            let nameBytes = Array(bytes[cursor..<(cursor + nameLength)])
            cursor += nameLength
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw DoryFSWorkerCoherenceCodecError.invalidEntryName("<invalid UTF-8>")
            }
            switch kind {
            case 1:
                guard nameLength == 0, first != 0 else {
                    throw DoryFSWorkerCoherenceCodecError.nonCanonicalEncoding
                }
                invalidations.append(.inode(
                    nodeID: first,
                    offset: Int64(bitPattern: second),
                    length: Int64(bitPattern: third)
                ))
            case 2:
                guard first != 0, second == 0, third <= UInt64(UInt32.max) else {
                    throw DoryFSWorkerCoherenceCodecError.nonCanonicalEncoding
                }
                try validateEntryName(name)
                invalidations.append(.entry(
                    parentNodeID: first,
                    name: name,
                    flags: UInt32(third)
                ))
            case 3:
                guard first != 0, second != 0, third == 0 else {
                    throw DoryFSWorkerCoherenceCodecError.nonCanonicalEncoding
                }
                try validateEntryName(name)
                invalidations.append(.delete(
                    parentNodeID: first,
                    childNodeID: second,
                    name: name
                ))
            default:
                throw DoryFSWorkerCoherenceCodecError.invalidInvalidationKind(kind)
            }
        }

        var nudges = [String]()
        nudges.reserveCapacity(nudgeCount)
        for _ in 0..<nudgeCount {
            guard cursor + 4 <= bytes.count else {
                throw DoryFSWorkerCoherenceCodecError.truncatedField("nudge.length")
            }
            let length = Int(bytes.leUInt32(at: cursor))
            cursor += 4
            guard cursor + length <= bytes.count else {
                throw DoryFSWorkerCoherenceCodecError.truncatedField("nudge.path")
            }
            let pathBytes = Array(bytes[cursor..<(cursor + length)])
            cursor += length
            guard let path = String(bytes: pathBytes, encoding: .utf8) else {
                throw DoryFSWorkerCoherenceCodecError.invalidRelativePath("<invalid UTF-8>")
            }
            try validateRelativePath(path)
            nudges.append(path)
        }
        guard cursor == bytes.count else { throw DoryFSWorkerCoherenceCodecError.trailingBytes }
        let batch = try DoryFSWorkerCoherenceBatch(
            generation: generation,
            shareCapabilityID: capability,
            batchID: batchID,
            invalidations: invalidations,
            nudgeRelativePaths: nudges
        )
        guard try encode(batch) == data else {
            throw DoryFSWorkerCoherenceCodecError.nonCanonicalEncoding
        }
        return batch
    }

    public static func encode(
        _ acknowledgement: DoryFSWorkerCoherenceAcknowledgement
    ) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(acknowledgementBytes)
        bytes.append(contentsOf: acknowledgementMagic)
        bytes.appendLE(version)
        bytes.append(acknowledgementKind)
        bytes.append(0)
        bytes.appendLE(UInt32(acknowledgementBytes))
        bytes.appendLE(UInt32(0))
        bytes.appendLE(acknowledgement.generation.rawValue)
        append(acknowledgement.shareCapabilityID.rawValue, to: &bytes)
        bytes.appendLE(acknowledgement.batchID)
        precondition(bytes.count == acknowledgementBytes)
        return Data(bytes)
    }

    public static func decodeAcknowledgement(
        _ data: Data
    ) throws -> DoryFSWorkerCoherenceAcknowledgement {
        let bytes = [UInt8](data)
        guard bytes.count == acknowledgementBytes else {
            throw DoryFSWorkerCoherenceCodecError.frameLengthMismatch(
                declared: bytes.count >= 12 ? bytes.leUInt32(at: 8) : 0,
                actual: bytes.count
            )
        }
        guard Array(bytes[0..<4]) == acknowledgementMagic else {
            throw DoryFSWorkerCoherenceCodecError.invalidMagic
        }
        guard bytes.leUInt16(at: 4) == version else {
            throw DoryFSWorkerCoherenceCodecError.unsupportedVersion(bytes.leUInt16(at: 4))
        }
        guard bytes[6] == acknowledgementKind else {
            throw DoryFSWorkerCoherenceCodecError.unknownFrameKind(bytes[6])
        }
        guard bytes[7] == 0,
              bytes.leUInt32(at: 8) == UInt32(acknowledgementBytes),
              bytes.leUInt32(at: 12) == 0 else {
            throw DoryFSWorkerCoherenceCodecError.nonzeroReservedField
        }
        guard let generation = try? DoryFSWorkerGeneration(rawValue: bytes.leUInt64(at: 16)) else {
            throw DoryFSWorkerCoherenceCodecError.invalidGeneration
        }
        guard let capability = try? DoryFSShareCapabilityID(rawValue: readUUID(bytes, at: 24)) else {
            throw DoryFSWorkerCoherenceCodecError.invalidCapabilityID
        }
        return try DoryFSWorkerCoherenceAcknowledgement(
            generation: generation,
            shareCapabilityID: capability,
            batchID: bytes.leUInt64(at: 40)
        )
    }

    static func validateEntryName(_ name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty,
              bytes.count <= maximumEntryNameBytes,
              name == name.precomposedStringWithCanonicalMapping,
              name != ".", name != "..",
              !bytes.contains(0), !bytes.contains(UInt8(ascii: "/")) else {
            throw DoryFSWorkerCoherenceCodecError.invalidEntryName(name)
        }
    }

    static func validateRelativePath(_ path: String) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumRelativePathBytes,
              path == path.precomposedStringWithCanonicalMapping,
              !path.hasPrefix("/"), !path.hasSuffix("/"),
              !bytes.contains(0) else {
            throw DoryFSWorkerCoherenceCodecError.invalidRelativePath(path)
        }
        if path.isEmpty { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DoryFSWorkerCoherenceCodecError.invalidRelativePath(path)
        }
    }

    static func canonicalKey(
        for invalidation: DoryFSWorkerCoherenceInvalidation
    ) -> String {
        switch invalidation {
        case .inode(let nodeID, _, _):
            "i:\(nodeID)"
        case .entry(let parentNodeID, let name, _):
            "e:\(parentNodeID):\(name)"
        case .delete(let parentNodeID, let childNodeID, let name):
            "d:\(parentNodeID):\(childNodeID):\(name)"
        }
    }

    private static func appendInvalidationHeader(
        kind: UInt8,
        nameByteCount: Int,
        first: UInt64,
        second: UInt64,
        third: UInt64,
        to bytes: inout [UInt8]
    ) {
        bytes.append(kind)
        bytes.append(0)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(UInt32(nameByteCount))
        bytes.appendLE(first)
        bytes.appendLE(second)
        bytes.appendLE(third)
    }

    private static func append(_ value: UUID, to bytes: inout [UInt8]) {
        let raw = value.uuid
        bytes.append(contentsOf: [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15,
        ])
    }

    private static func readUUID(_ bytes: [UInt8], at offset: Int) -> UUID {
        UUID(uuid: (
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
            bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
            bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
            bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
        ))
    }

    private static func patchUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }
}

/// End-to-end timing budget for worker-to-runner coherence and guest watcher notification. The
/// guest listener starts only after Linux has mounted and prepared its data disk, so an explicit
/// zero-path probe owns a bounded cold-start window. Real deliveries retain the short fail-stop
/// deadline and never nest that cold-start retry inside reverse XPC.
public enum DoryFSWorkerCoherenceTiming {
    public static let guestWatcherAttemptNanoseconds: UInt64 = 2_000_000_000
    public static let guestWatcherStartupGraceNanoseconds: UInt64 = 30_000_000_000
    public static let guestWatcherRetryDelayNanoseconds: UInt64 = 50_000_000
    public static let guestWatcherMaximumRetryDelayNanoseconds: UInt64 = 250_000_000
    public static let preparationRequestNanoseconds: UInt64 = 5_000_000_000

    /// A steady-state reverse delivery can consume the one-second virtiofs invalidation budget and
    /// the two-second guest-watcher budget. Keep scheduler headroom outside both inner deadlines.
    public static let reverseExchangeNanoseconds: UInt64 = 4_000_000_000

    /// Activation drains every retained share before workload readiness. A total budget prevents a
    /// pathological number of slow shares from turning startup into an unbounded XPC transaction.
    public static let activationCatchupNanoseconds: UInt64 = 40_000_000_000

    /// The outer request contains the catch-up budget plus one already-started reverse exchange.
    public static let activationRequestNanoseconds: UInt64 = 45_000_000_000
}
