import Foundation

/// Validation failures for the one-workspace worker bootstrap. The bootstrap is an authority
/// envelope rather than a persistence format, so version 1 rejects every unknown flag, reserved
/// byte, non-canonical ordering, and trailing byte.
public enum DoryFSWorkerBootstrapError: Error, Equatable, Sendable {
    case invalidWorkspaceIdentity
    case invalidPinnedRootIdentity(field: String)
    case invalidWorkerLimits(field: String)
    case invalidShareResourceLimits(field: String)
    case incompatibleShareLimit(field: String)
    case invalidShareCount(limit: Int, actual: Int)
    case duplicateShareCapabilityID
    case invalidBookmarkSize(limit: Int, actual: Int)
    case invalidComponent(String)
    case tooManyComponents(limit: Int, actual: Int)
    case componentBytesTooLarge(limit: Int, actual: Int)
    case duplicateComponent(String)
    case overlappingComponent(String)
    case bootstrapTooLarge(limit: Int, actual: Int)
    case shortBootstrap(minimum: Int, actual: Int)
    case invalidBootstrapMagic
    case unsupportedBootstrapVersion(UInt16)
    case bootstrapLengthMismatch(declared: UInt32, actual: Int)
    case truncatedField(String)
    case invalidShareRecordLength(UInt32)
    case shareRecordLengthMismatch(declared: UInt32, consumed: Int)
    case invalidShareFlags(UInt16)
    case nonzeroReservedField
    case nonCanonicalEncoding
    case invalidReceiptShareCount(limit: Int, actual: Int)
}

/// Daemon-owned identity of the one workspace authorized in a worker process. The all-zero UUID is
/// permanently reserved so an uninitialized launch envelope can never be mistaken for authority.
public struct DoryFSWorkerWorkspaceID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zeroUUID else {
            throw DoryFSWorkerBootstrapError.invalidWorkspaceIdentity
        }
        self.rawValue = rawValue
    }

    public static func random() -> Self {
        while true {
            if let value = try? Self(rawValue: UUID()) { return value }
        }
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

/// Descriptor identity sealed by the daemon before bootstrap and compared by the worker after it
/// resolves the opaque bookmark. Generation may legitimately be zero on filesystems that do not
/// expose one; device and inode may not be zero sentinels.
public struct DoryFSPinnedRootIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let generation: UInt64

    public init(device: UInt64, inode: UInt64, generation: UInt64) throws {
        guard device != 0 else {
            throw DoryFSWorkerBootstrapError.invalidPinnedRootIdentity(field: "device")
        }
        guard inode != 0 else {
            throw DoryFSWorkerBootstrapError.invalidPinnedRootIdentity(field: "inode")
        }
        self.device = device
        self.inode = inode
        self.generation = generation
    }
}

/// Guest-visible ownership policy. UID and GID zero are valid and deliberately have no sentinel
/// meaning: a Linux root-owned view is a normal policy choice, not missing configuration.
public struct DoryFSGuestIdentityPolicy: Equatable, Sendable {
    public let uid: UInt32
    public let gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }
}

/// Per-share ceilings enforced in addition to the workspace-wide worker limits. These values
/// cover admission memory and every long-lived HostFS resource class, including descriptor
/// headroom that must remain unavailable to guest work.
public struct DoryFSShareResourceLimits: Equatable, Sendable {
    public static let absoluteMaximumInFlightRequests = 4_096
    public static let absoluteMaximumAggregateBytes = 8 * 1_024 * 1_024 * 1_024
    public static let absoluteMaximumLiveNonRootNodes = 1_048_576
    public static let absoluteMaximumFileHandles = 262_144
    public static let absoluteMaximumDirectoryHandles = 65_536
    public static let absoluteMaximumDirectoryCursorEntries = 4_194_304
    public static let absoluteMaximumDirectoryCursorNameBytes = 512 * 1_024 * 1_024
    public static let absoluteMaximumAdvisoryLockOwners = 65_536
    public static let absoluteMaximumPendingBlockingLocks = 65_536
    public static let absoluteMaximumReservedFileDescriptorHeadroom = 65_536

    public let maximumInFlightRequests: Int
    public let maximumAggregateRequestBytes: Int
    public let maximumAggregateResponseBytes: Int
    public let maximumLiveNonRootNodes: Int
    public let maximumFileHandles: Int
    public let maximumDirectoryHandles: Int
    public let maximumDirectoryCursorEntries: Int
    public let maximumDirectoryCursorNameBytes: Int
    public let maximumAdvisoryLockOwners: Int
    public let maximumPendingBlockingLocks: Int
    public let reservedFileDescriptorHeadroom: Int

    public init(
        maximumInFlightRequests: Int,
        maximumAggregateRequestBytes: Int,
        maximumAggregateResponseBytes: Int,
        maximumLiveNonRootNodes: Int,
        maximumFileHandles: Int,
        maximumDirectoryHandles: Int,
        maximumDirectoryCursorEntries: Int,
        maximumDirectoryCursorNameBytes: Int,
        maximumAdvisoryLockOwners: Int,
        maximumPendingBlockingLocks: Int,
        reservedFileDescriptorHeadroom: Int
    ) throws {
        try Self.require(
            maximumInFlightRequests,
            atMost: Self.absoluteMaximumInFlightRequests,
            field: "maximumInFlightRequests"
        )
        try Self.require(
            maximumAggregateRequestBytes,
            atMost: Self.absoluteMaximumAggregateBytes,
            field: "maximumAggregateRequestBytes"
        )
        try Self.require(
            maximumAggregateResponseBytes,
            atMost: Self.absoluteMaximumAggregateBytes,
            field: "maximumAggregateResponseBytes"
        )
        try Self.require(
            maximumLiveNonRootNodes,
            atMost: Self.absoluteMaximumLiveNonRootNodes,
            field: "maximumLiveNonRootNodes"
        )
        try Self.require(
            maximumFileHandles,
            atMost: Self.absoluteMaximumFileHandles,
            field: "maximumFileHandles"
        )
        try Self.require(
            maximumDirectoryHandles,
            atMost: Self.absoluteMaximumDirectoryHandles,
            field: "maximumDirectoryHandles"
        )
        try Self.require(
            maximumDirectoryCursorEntries,
            atMost: Self.absoluteMaximumDirectoryCursorEntries,
            field: "maximumDirectoryCursorEntries"
        )
        try Self.require(
            maximumDirectoryCursorNameBytes,
            atMost: Self.absoluteMaximumDirectoryCursorNameBytes,
            field: "maximumDirectoryCursorNameBytes"
        )
        try Self.require(
            maximumAdvisoryLockOwners,
            atMost: Self.absoluteMaximumAdvisoryLockOwners,
            field: "maximumAdvisoryLockOwners"
        )
        try Self.require(
            maximumPendingBlockingLocks,
            atMost: Self.absoluteMaximumPendingBlockingLocks,
            field: "maximumPendingBlockingLocks"
        )
        try Self.require(
            reservedFileDescriptorHeadroom,
            atMost: Self.absoluteMaximumReservedFileDescriptorHeadroom,
            field: "reservedFileDescriptorHeadroom"
        )
        self.maximumInFlightRequests = maximumInFlightRequests
        self.maximumAggregateRequestBytes = maximumAggregateRequestBytes
        self.maximumAggregateResponseBytes = maximumAggregateResponseBytes
        self.maximumLiveNonRootNodes = maximumLiveNonRootNodes
        self.maximumFileHandles = maximumFileHandles
        self.maximumDirectoryHandles = maximumDirectoryHandles
        self.maximumDirectoryCursorEntries = maximumDirectoryCursorEntries
        self.maximumDirectoryCursorNameBytes = maximumDirectoryCursorNameBytes
        self.maximumAdvisoryLockOwners = maximumAdvisoryLockOwners
        self.maximumPendingBlockingLocks = maximumPendingBlockingLocks
        self.reservedFileDescriptorHeadroom = reservedFileDescriptorHeadroom
    }

    /// Matches the current production HostFS ceilings while leaving explicit non-guest descriptor
    /// capacity for the worker channel, bookmark roots, event streams, and supervisor plumbing.
    public static let production: Self = try! Self(
        maximumInFlightRequests: 32,
        maximumAggregateRequestBytes: 8 * (40 + 1 * 1_024 * 1_024),
        maximumAggregateResponseBytes: 8 * (16 + 1 * 1_024 * 1_024),
        maximumLiveNonRootNodes: 65_536,
        maximumFileHandles: 16_384,
        maximumDirectoryHandles: 4_096,
        maximumDirectoryCursorEntries: 262_144,
        maximumDirectoryCursorNameBytes: 32 * 1_024 * 1_024,
        maximumAdvisoryLockOwners: 4_096,
        maximumPendingBlockingLocks: 1_024,
        reservedFileDescriptorHeadroom: 256
    )

    private static func require(_ value: Int, atMost limit: Int, field: String) throws {
        guard value > 0, value <= limit else {
            throw DoryFSWorkerBootstrapError.invalidShareResourceLimits(field: field)
        }
    }
}

/// Complete immutable authority for one share. There is intentionally no host path or guest mount
/// path: the worker resolves only `securityScopedBookmark`, verifies `expectedRootIdentity`, and
/// labels subsequent traffic solely by `capabilityID`.
public struct DoryFSShareBootstrapAuthority: Equatable, Sendable {
    public let capabilityID: DoryFSShareCapabilityID
    public let expectedRootIdentity: DoryFSPinnedRootIdentity
    public let readOnly: Bool
    public let guestIdentity: DoryFSGuestIdentityPolicy
    public let resourceLimits: DoryFSShareResourceLimits
    public let securityScopedBookmark: Data
    public let hiddenComponents: [String]
    public let rootHiddenComponents: [String]

    public init(
        capabilityID: DoryFSShareCapabilityID,
        expectedRootIdentity: DoryFSPinnedRootIdentity,
        readOnly: Bool,
        guestIdentity: DoryFSGuestIdentityPolicy,
        resourceLimits: DoryFSShareResourceLimits,
        securityScopedBookmark: Data,
        hiddenComponents: [String] = [],
        rootHiddenComponents: [String] = []
    ) throws {
        guard !securityScopedBookmark.isEmpty,
              securityScopedBookmark.count <= DoryFSWorkerBootstrapCodec.maximumBookmarkBytes else {
            throw DoryFSWorkerBootstrapError.invalidBookmarkSize(
                limit: DoryFSWorkerBootstrapCodec.maximumBookmarkBytes,
                actual: securityScopedBookmark.count
            )
        }
        let hidden = try Self.canonicalComponents(hiddenComponents)
        let rootHidden = try Self.canonicalComponents(rootHiddenComponents)
        let hiddenSet = Set(hidden)
        if let overlap = rootHidden.first(where: hiddenSet.contains) {
            throw DoryFSWorkerBootstrapError.overlappingComponent(overlap)
        }
        let encodedComponentBytes = Self.encodedByteCount(hidden)
            + Self.encodedByteCount(rootHidden)
        guard encodedComponentBytes <= DoryFSWorkerBootstrapCodec.maximumComponentBytesPerShare else {
            throw DoryFSWorkerBootstrapError.componentBytesTooLarge(
                limit: DoryFSWorkerBootstrapCodec.maximumComponentBytesPerShare,
                actual: encodedComponentBytes
            )
        }
        self.capabilityID = capabilityID
        self.expectedRootIdentity = expectedRootIdentity
        self.readOnly = readOnly
        self.guestIdentity = guestIdentity
        self.resourceLimits = resourceLimits
        self.securityScopedBookmark = securityScopedBookmark
        self.hiddenComponents = hidden
        self.rootHiddenComponents = rootHidden
    }

    private static func canonicalComponents(_ source: [String]) throws -> [String] {
        guard source.count <= DoryFSWorkerBootstrapCodec.maximumComponentsPerList else {
            throw DoryFSWorkerBootstrapError.tooManyComponents(
                limit: DoryFSWorkerBootstrapCodec.maximumComponentsPerList,
                actual: source.count
            )
        }
        var seen = Set<String>()
        var result = [String]()
        result.reserveCapacity(source.count)
        for component in source {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.utf8.contains(0),
                  component.utf8.count <= DoryFSWorkerBootstrapCodec.maximumComponentBytes else {
                throw DoryFSWorkerBootstrapError.invalidComponent(component)
            }
            // HostFS compares hidden names case-insensitively. Normalize at the authority boundary
            // so visually equivalent/case-variant entries have one exact wire spelling.
            let canonical = component
                .precomposedStringWithCanonicalMapping
                .lowercased()
                .precomposedStringWithCanonicalMapping
            guard !canonical.isEmpty,
                  canonical.utf8.count <= DoryFSWorkerBootstrapCodec.maximumComponentBytes else {
                throw DoryFSWorkerBootstrapError.invalidComponent(component)
            }
            guard seen.insert(canonical).inserted else {
                throw DoryFSWorkerBootstrapError.duplicateComponent(canonical)
            }
            result.append(canonical)
        }
        return result.sorted(by: Self.utf8Precedes)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func encodedByteCount(_ values: [String]) -> Int {
        values.reduce(into: 0) { total, value in
            total += 2 + value.utf8.count
        }
    }
}

/// A complete, immutable one-workspace launch envelope. Construction canonicalizes share order;
/// binary decoding additionally requires that the received bytes were already canonical.
public struct DoryFSWorkerBootstrap: Equatable, Sendable {
    public let workspaceID: DoryFSWorkerWorkspaceID
    public let generation: DoryFSWorkerGeneration
    public let workerLimits: DoryFSWorkerLimits
    public let shares: [DoryFSShareBootstrapAuthority]

    public init(
        workspaceID: DoryFSWorkerWorkspaceID,
        generation: DoryFSWorkerGeneration,
        workerLimits: DoryFSWorkerLimits,
        shares: [DoryFSShareBootstrapAuthority]
    ) throws {
        guard (1...DoryFSWorkerBootstrapCodec.maximumShares).contains(shares.count) else {
            throw DoryFSWorkerBootstrapError.invalidShareCount(
                limit: DoryFSWorkerBootstrapCodec.maximumShares,
                actual: shares.count
            )
        }
        try DoryFSWorkerBootstrapCodec.validate(workerLimits: workerLimits)
        var capabilities = Set<DoryFSShareCapabilityID>()
        for share in shares {
            guard capabilities.insert(share.capabilityID).inserted else {
                throw DoryFSWorkerBootstrapError.duplicateShareCapabilityID
            }
            guard share.resourceLimits.maximumInFlightRequests
                    <= workerLimits.maximumInFlightRequests else {
                throw DoryFSWorkerBootstrapError.incompatibleShareLimit(
                    field: "maximumInFlightRequests"
                )
            }
            guard share.resourceLimits.maximumAggregateRequestBytes
                    <= workerLimits.maximumAggregateRequestBytes else {
                throw DoryFSWorkerBootstrapError.incompatibleShareLimit(
                    field: "maximumAggregateRequestBytes"
                )
            }
            guard share.resourceLimits.maximumAggregateResponseBytes
                    <= workerLimits.maximumAggregateResponseBytes else {
                throw DoryFSWorkerBootstrapError.incompatibleShareLimit(
                    field: "maximumAggregateResponseBytes"
                )
            }
        }
        // Reject an oversized authority set before the encoder allocates and copies its opaque
        // bookmarks. Per-share limits alone would otherwise permit a bounded but much larger
        // intermediate buffer than the version-1 wire envelope.
        _ = try DoryFSWorkerBootstrapCodec.encodedBootstrapByteCount(shares: shares)
        self.workspaceID = workspaceID
        self.generation = generation
        self.workerLimits = workerLimits
        self.shares = shares.sorted {
            Self.uuidBytes($0.capabilityID.rawValue)
                .lexicographicallyPrecedes(Self.uuidBytes($1.capabilityID.rawValue))
        }
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        let raw = value.uuid
        return [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15,
        ]
    }
}

/// Exact receipt returned only after the worker has accepted every share authority. Process IDs
/// are deliberately absent: they are supervisor telemetry, not authorization or receipt identity.
public struct DoryFSWorkerBootstrapReceipt: Equatable, Sendable {
    public let workspaceID: DoryFSWorkerWorkspaceID
    public let generation: DoryFSWorkerGeneration
    public let acceptedShareCount: UInt16

    public init(
        workspaceID: DoryFSWorkerWorkspaceID,
        generation: DoryFSWorkerGeneration,
        acceptedShareCount: UInt16
    ) throws {
        guard (1...DoryFSWorkerBootstrapCodec.maximumShares).contains(Int(acceptedShareCount)) else {
            throw DoryFSWorkerBootstrapError.invalidReceiptShareCount(
                limit: DoryFSWorkerBootstrapCodec.maximumShares,
                actual: Int(acceptedShareCount)
            )
        }
        self.workspaceID = workspaceID
        self.generation = generation
        self.acceptedShareCount = acceptedShareCount
    }

    public init(accepting bootstrap: DoryFSWorkerBootstrap) {
        self.workspaceID = bootstrap.workspaceID
        self.generation = bootstrap.generation
        self.acceptedShareCount = UInt16(bootstrap.shares.count)
    }
}

/// Exact little-endian version-1 bootstrap and receipt codec. This is intentionally independent
/// of `Codable`, property lists, keyed archives, and Swift object layout.
public enum DoryFSWorkerBootstrapCodec {
    public static let version: UInt16 = 1
    public static let bootstrapHeaderByteCount = 88
    public static let shareRecordHeaderByteCount = 128
    public static let receiptByteCount = 40
    public static let maximumShares = 64
    public static let maximumBookmarkBytes = 256 * 1_024
    public static let maximumComponentsPerList = 256
    public static let maximumComponentBytes = 255
    public static let maximumComponentBytesPerShare = 128 * 1_024
    public static let absoluteMaximumBootstrapBytes = 4 * 1_024 * 1_024

    private static let bootstrapMagic: [UInt8] = [0x44, 0x46, 0x53, 0x42] // DFSB
    private static let receiptMagic: [UInt8] = [0x44, 0x46, 0x53, 0x52] // DFSR
    private static let absoluteMaximumOperationNanoseconds: UInt64 = 3_600_000_000_000

    public static func encode(_ bootstrap: DoryFSWorkerBootstrap) throws -> Data {
        try validate(workerLimits: bootstrap.workerLimits)
        let encodedByteCount = try encodedBootstrapByteCount(shares: bootstrap.shares)
        var writer = BootstrapWriter(reservingCapacity: encodedByteCount)
        writer.append(bootstrapMagic)
        writer.append(version)
        writer.append(UInt16(0)) // flags
        let totalLengthOffset = writer.count
        writer.append(UInt32(0))
        writer.append(UInt16(bootstrap.shares.count))
        writer.append(UInt16(0)) // reserved
        writer.append(bootstrap.workspaceID.rawValue)
        writer.append(bootstrap.generation.rawValue)
        append(bootstrap.workerLimits, to: &writer)
        precondition(writer.count == bootstrapHeaderByteCount)
        for share in bootstrap.shares {
            try append(share, to: &writer)
        }
        precondition(writer.count == encodedByteCount)
        writer.replaceUInt32(at: totalLengthOffset, with: UInt32(writer.count))
        return writer.data
    }

    public static func decode(_ data: Data) throws -> DoryFSWorkerBootstrap {
        guard data.count <= absoluteMaximumBootstrapBytes else {
            throw DoryFSWorkerBootstrapError.bootstrapTooLarge(
                limit: absoluteMaximumBootstrapBytes,
                actual: data.count
            )
        }
        guard data.count >= bootstrapHeaderByteCount else {
            throw DoryFSWorkerBootstrapError.shortBootstrap(
                minimum: bootstrapHeaderByteCount,
                actual: data.count
            )
        }
        var reader = BootstrapReader(data: data)
        guard try reader.readBytes(count: 4, field: "magic") == bootstrapMagic else {
            throw DoryFSWorkerBootstrapError.invalidBootstrapMagic
        }
        let decodedVersion = try reader.readUInt16(field: "version")
        guard decodedVersion == version else {
            throw DoryFSWorkerBootstrapError.unsupportedBootstrapVersion(decodedVersion)
        }
        guard try reader.readUInt16(field: "flags") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let declaredLength = try reader.readUInt32(field: "totalLength")
        guard Int(declaredLength) == data.count else {
            throw DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        let shareCount = Int(try reader.readUInt16(field: "shareCount"))
        guard (1...maximumShares).contains(shareCount) else {
            throw DoryFSWorkerBootstrapError.invalidShareCount(
                limit: maximumShares,
                actual: shareCount
            )
        }
        guard try reader.readUInt16(field: "reserved") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let workspaceID = try DoryFSWorkerWorkspaceID(
            rawValue: reader.readUUID(field: "workspaceID")
        )
        let generation = try DoryFSWorkerGeneration(
            rawValue: reader.readUInt64(field: "generation")
        )
        let workerLimits = try readWorkerLimits(from: &reader)
        var shares = [DoryFSShareBootstrapAuthority]()
        shares.reserveCapacity(shareCount)
        for index in 0..<shareCount {
            shares.append(try readShare(from: &reader, index: index))
        }
        guard reader.isAtEnd else {
            throw DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
                declared: declaredLength,
                actual: reader.offset
            )
        }
        let bootstrap = try DoryFSWorkerBootstrap(
            workspaceID: workspaceID,
            generation: generation,
            workerLimits: workerLimits,
            shares: shares
        )
        guard try encode(bootstrap) == data else {
            throw DoryFSWorkerBootstrapError.nonCanonicalEncoding
        }
        return bootstrap
    }

    public static func encode(_ receipt: DoryFSWorkerBootstrapReceipt) -> Data {
        var writer = BootstrapWriter()
        writer.append(receiptMagic)
        writer.append(version)
        writer.append(UInt16(0)) // flags
        writer.append(UInt32(receiptByteCount))
        writer.append(receipt.acceptedShareCount)
        writer.append(UInt16(0)) // reserved
        writer.append(receipt.workspaceID.rawValue)
        writer.append(receipt.generation.rawValue)
        precondition(writer.count == receiptByteCount)
        return writer.data
    }

    public static func decodeReceipt(_ data: Data) throws -> DoryFSWorkerBootstrapReceipt {
        guard data.count >= receiptByteCount else {
            throw DoryFSWorkerBootstrapError.shortBootstrap(
                minimum: receiptByteCount,
                actual: data.count
            )
        }
        guard data.count <= receiptByteCount else {
            throw DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
                declared: UInt32(receiptByteCount),
                actual: data.count
            )
        }
        var reader = BootstrapReader(data: data)
        guard try reader.readBytes(count: 4, field: "receiptMagic") == receiptMagic else {
            throw DoryFSWorkerBootstrapError.invalidBootstrapMagic
        }
        let decodedVersion = try reader.readUInt16(field: "receiptVersion")
        guard decodedVersion == version else {
            throw DoryFSWorkerBootstrapError.unsupportedBootstrapVersion(decodedVersion)
        }
        guard try reader.readUInt16(field: "receiptFlags") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let declaredLength = try reader.readUInt32(field: "receiptLength")
        guard declaredLength == UInt32(receiptByteCount) else {
            throw DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        let shareCount = try reader.readUInt16(field: "receiptShareCount")
        guard try reader.readUInt16(field: "receiptReserved") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let receipt = try DoryFSWorkerBootstrapReceipt(
            workspaceID: DoryFSWorkerWorkspaceID(
                rawValue: reader.readUUID(field: "receiptWorkspaceID")
            ),
            generation: DoryFSWorkerGeneration(
                rawValue: reader.readUInt64(field: "receiptGeneration")
            ),
            acceptedShareCount: shareCount
        )
        guard reader.isAtEnd, encode(receipt) == data else {
            throw DoryFSWorkerBootstrapError.nonCanonicalEncoding
        }
        return receipt
    }

    static func validate(workerLimits: DoryFSWorkerLimits) throws {
        guard workerLimits.maximumRequestBytes <= Int(UInt32.max) else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumRequestBytes"
            )
        }
        guard workerLimits.maximumResponseBytes <= Int(UInt32.max) else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumResponseBytes"
            )
        }
        guard workerLimits.maximumFrameBytes <= Int(UInt32.max) else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(field: "maximumFrameBytes")
        }
        guard workerLimits.maximumInFlightRequests
                <= DoryFSShareResourceLimits.absoluteMaximumInFlightRequests else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumInFlightRequests"
            )
        }
        guard workerLimits.maximumAggregateRequestBytes
                <= DoryFSShareResourceLimits.absoluteMaximumAggregateBytes else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumAggregateRequestBytes"
            )
        }
        guard workerLimits.maximumAggregateResponseBytes
                <= DoryFSShareResourceLimits.absoluteMaximumAggregateBytes else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumAggregateResponseBytes"
            )
        }
        guard workerLimits.maximumOperationNanoseconds
                <= absoluteMaximumOperationNanoseconds else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumOperationNanoseconds"
            )
        }
        guard workerLimits.maximumDrainNanoseconds
                <= absoluteMaximumOperationNanoseconds else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(
                field: "maximumDrainNanoseconds"
            )
        }
    }

    fileprivate static func encodedBootstrapByteCount(
        shares: [DoryFSShareBootstrapAuthority]
    ) throws -> Int {
        var total = bootstrapHeaderByteCount
        for share in shares {
            let componentBytes = encodedComponentBytes(share.hiddenComponents)
                + encodedComponentBytes(share.rootHiddenComponents)
            let (recordPayload, payloadOverflow) = share.securityScopedBookmark.count
                .addingReportingOverflow(componentBytes)
            let (recordBytes, recordOverflow) = shareRecordHeaderByteCount
                .addingReportingOverflow(recordPayload)
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(recordBytes)
            guard !payloadOverflow, !recordOverflow, !totalOverflow,
                  nextTotal <= absoluteMaximumBootstrapBytes else {
                throw DoryFSWorkerBootstrapError.bootstrapTooLarge(
                    limit: absoluteMaximumBootstrapBytes,
                    actual: payloadOverflow || recordOverflow || totalOverflow
                        ? Int.max
                        : nextTotal
                )
            }
            total = nextTotal
        }
        return total
    }

    private static func append(_ limits: DoryFSWorkerLimits, to writer: inout BootstrapWriter) {
        writer.append(UInt32(limits.maximumRequestBytes))
        writer.append(UInt32(limits.maximumResponseBytes))
        writer.append(UInt32(limits.maximumFrameBytes))
        writer.append(UInt32(limits.maximumInFlightRequests))
        writer.append(UInt64(limits.maximumAggregateRequestBytes))
        writer.append(UInt64(limits.maximumAggregateResponseBytes))
        writer.append(limits.maximumOperationNanoseconds)
        writer.append(limits.maximumDrainNanoseconds)
    }

    private static func append(
        _ share: DoryFSShareBootstrapAuthority,
        to writer: inout BootstrapWriter
    ) throws {
        let recordStart = writer.count
        writer.append(UInt32(0))
        writer.append(UInt16(share.readOnly ? 1 : 0))
        writer.append(UInt16(0)) // reserved
        writer.append(share.capabilityID.rawValue)
        writer.append(share.expectedRootIdentity.device)
        writer.append(share.expectedRootIdentity.inode)
        writer.append(share.expectedRootIdentity.generation)
        writer.append(share.guestIdentity.uid)
        writer.append(share.guestIdentity.gid)
        let limits = share.resourceLimits
        writer.append(UInt32(limits.maximumInFlightRequests))
        writer.append(UInt64(limits.maximumAggregateRequestBytes))
        writer.append(UInt64(limits.maximumAggregateResponseBytes))
        writer.append(UInt32(limits.maximumLiveNonRootNodes))
        writer.append(UInt32(limits.maximumFileHandles))
        writer.append(UInt32(limits.maximumDirectoryHandles))
        writer.append(UInt32(limits.maximumDirectoryCursorEntries))
        writer.append(UInt64(limits.maximumDirectoryCursorNameBytes))
        writer.append(UInt32(limits.maximumAdvisoryLockOwners))
        writer.append(UInt32(limits.maximumPendingBlockingLocks))
        writer.append(UInt32(limits.reservedFileDescriptorHeadroom))
        writer.append(UInt32(share.securityScopedBookmark.count))
        writer.append(UInt16(share.hiddenComponents.count))
        writer.append(UInt16(share.rootHiddenComponents.count))
        let componentByteCount = encodedComponentBytes(share.hiddenComponents)
            + encodedComponentBytes(share.rootHiddenComponents)
        writer.append(UInt32(componentByteCount))
        writer.append(UInt32(0)) // reserved
        precondition(writer.count - recordStart == shareRecordHeaderByteCount)
        writer.append(Array(share.securityScopedBookmark))
        for component in share.hiddenComponents + share.rootHiddenComponents {
            let bytes = Array(component.utf8)
            writer.append(UInt16(bytes.count))
            writer.append(bytes)
        }
        let recordLength = writer.count - recordStart
        guard recordLength <= Int(UInt32.max) else {
            throw DoryFSWorkerBootstrapError.bootstrapTooLarge(
                limit: absoluteMaximumBootstrapBytes,
                actual: writer.count
            )
        }
        writer.replaceUInt32(at: recordStart, with: UInt32(recordLength))
    }

    private static func readWorkerLimits(
        from reader: inout BootstrapReader
    ) throws -> DoryFSWorkerLimits {
        let request = try reader.readUInt32(field: "maximumRequestBytes")
        let response = try reader.readUInt32(field: "maximumResponseBytes")
        let frame = try reader.readUInt32(field: "maximumFrameBytes")
        let inFlight = try reader.readUInt32(field: "maximumInFlightRequests")
        let aggregateRequest = try reader.readUInt64(field: "maximumAggregateRequestBytes")
        let aggregateResponse = try reader.readUInt64(field: "maximumAggregateResponseBytes")
        let operation = try reader.readUInt64(field: "maximumOperationNanoseconds")
        let drain = try reader.readUInt64(field: "maximumDrainNanoseconds")
        guard aggregateRequest <= UInt64(Int.max), aggregateResponse <= UInt64(Int.max) else {
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(field: "aggregateBytes")
        }
        do {
            let limits = try DoryFSWorkerLimits(
                maximumRequestBytes: Int(request),
                maximumResponseBytes: Int(response),
                maximumFrameBytes: Int(frame),
                maximumInFlightRequests: Int(inFlight),
                maximumAggregateRequestBytes: Int(aggregateRequest),
                maximumAggregateResponseBytes: Int(aggregateResponse),
                maximumOperationNanoseconds: operation,
                maximumDrainNanoseconds: drain
            )
            try validate(workerLimits: limits)
            return limits
        } catch let error as DoryFSWorkerBootstrapError {
            throw error
        } catch let error as DoryFSWorkerContractError {
            if case .invalidLimits(let field) = error {
                throw DoryFSWorkerBootstrapError.invalidWorkerLimits(field: field)
            }
            throw DoryFSWorkerBootstrapError.invalidWorkerLimits(field: "unknown")
        }
    }

    private static func readShare(
        from reader: inout BootstrapReader,
        index: Int
    ) throws -> DoryFSShareBootstrapAuthority {
        let recordStart = reader.offset
        let recordLength = try reader.readUInt32(field: "share[\(index)].recordLength")
        guard recordLength >= UInt32(shareRecordHeaderByteCount),
              Int(recordLength) <= reader.remaining + 4 else {
            throw DoryFSWorkerBootstrapError.invalidShareRecordLength(recordLength)
        }
        let recordEnd = recordStart + Int(recordLength)
        reader.pushLimit(recordEnd)
        defer { reader.popLimit() }
        let flags = try reader.readUInt16(field: "share[\(index)].flags")
        guard flags & ~UInt16(1) == 0 else {
            throw DoryFSWorkerBootstrapError.invalidShareFlags(flags)
        }
        guard try reader.readUInt16(field: "share[\(index)].reserved") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let capability = try DoryFSShareCapabilityID(
            rawValue: reader.readUUID(field: "share[\(index)].capabilityID")
        )
        let root = try DoryFSPinnedRootIdentity(
            device: reader.readUInt64(field: "share[\(index)].device"),
            inode: reader.readUInt64(field: "share[\(index)].inode"),
            generation: reader.readUInt64(field: "share[\(index)].rootGeneration")
        )
        let guest = DoryFSGuestIdentityPolicy(
            uid: try reader.readUInt32(field: "share[\(index)].guestUID"),
            gid: try reader.readUInt32(field: "share[\(index)].guestGID")
        )
        let limits = try readShareLimits(from: &reader, index: index)
        let bookmarkLength = Int(
            try reader.readUInt32(field: "share[\(index)].bookmarkLength")
        )
        guard (1...maximumBookmarkBytes).contains(bookmarkLength) else {
            throw DoryFSWorkerBootstrapError.invalidBookmarkSize(
                limit: maximumBookmarkBytes,
                actual: bookmarkLength
            )
        }
        let hiddenCount = Int(
            try reader.readUInt16(field: "share[\(index)].hiddenCount")
        )
        let rootHiddenCount = Int(
            try reader.readUInt16(field: "share[\(index)].rootHiddenCount")
        )
        guard hiddenCount <= maximumComponentsPerList else {
            throw DoryFSWorkerBootstrapError.tooManyComponents(
                limit: maximumComponentsPerList,
                actual: hiddenCount
            )
        }
        guard rootHiddenCount <= maximumComponentsPerList else {
            throw DoryFSWorkerBootstrapError.tooManyComponents(
                limit: maximumComponentsPerList,
                actual: rootHiddenCount
            )
        }
        let declaredComponentBytes = Int(
            try reader.readUInt32(field: "share[\(index)].componentBytes")
        )
        guard declaredComponentBytes <= maximumComponentBytesPerShare else {
            throw DoryFSWorkerBootstrapError.componentBytesTooLarge(
                limit: maximumComponentBytesPerShare,
                actual: declaredComponentBytes
            )
        }
        guard try reader.readUInt32(field: "share[\(index)].reserved2") == 0 else {
            throw DoryFSWorkerBootstrapError.nonzeroReservedField
        }
        let bookmark = Data(
            try reader.readBytes(count: bookmarkLength, field: "share[\(index)].bookmark")
        )
        let componentStart = reader.offset
        let hidden = try readComponents(count: hiddenCount, from: &reader, index: index)
        let rootHidden = try readComponents(
            count: rootHiddenCount,
            from: &reader,
            index: index
        )
        let consumedComponentBytes = reader.offset - componentStart
        guard consumedComponentBytes == declaredComponentBytes,
              reader.offset == recordEnd else {
            throw DoryFSWorkerBootstrapError.shareRecordLengthMismatch(
                declared: recordLength,
                consumed: reader.offset - recordStart
            )
        }
        return try DoryFSShareBootstrapAuthority(
            capabilityID: capability,
            expectedRootIdentity: root,
            readOnly: flags & 1 == 1,
            guestIdentity: guest,
            resourceLimits: limits,
            securityScopedBookmark: bookmark,
            hiddenComponents: hidden,
            rootHiddenComponents: rootHidden
        )
    }

    private static func readShareLimits(
        from reader: inout BootstrapReader,
        index: Int
    ) throws -> DoryFSShareResourceLimits {
        let inFlight = try reader.readUInt32(field: "share[\(index)].maximumInFlightRequests")
        let aggregateRequest = try reader.readUInt64(
            field: "share[\(index)].maximumAggregateRequestBytes"
        )
        let aggregateResponse = try reader.readUInt64(
            field: "share[\(index)].maximumAggregateResponseBytes"
        )
        let nodes = try reader.readUInt32(field: "share[\(index)].maximumLiveNonRootNodes")
        let fileHandles = try reader.readUInt32(field: "share[\(index)].maximumFileHandles")
        let directoryHandles = try reader.readUInt32(
            field: "share[\(index)].maximumDirectoryHandles"
        )
        let cursorEntries = try reader.readUInt32(
            field: "share[\(index)].maximumDirectoryCursorEntries"
        )
        let cursorNameBytes = try reader.readUInt64(
            field: "share[\(index)].maximumDirectoryCursorNameBytes"
        )
        let lockOwners = try reader.readUInt32(
            field: "share[\(index)].maximumAdvisoryLockOwners"
        )
        let blockingLocks = try reader.readUInt32(
            field: "share[\(index)].maximumPendingBlockingLocks"
        )
        let descriptorHeadroom = try reader.readUInt32(
            field: "share[\(index)].reservedFileDescriptorHeadroom"
        )
        let values = [aggregateRequest, aggregateResponse, cursorNameBytes]
        guard values.allSatisfy({ $0 <= UInt64(Int.max) }) else {
            throw DoryFSWorkerBootstrapError.invalidShareResourceLimits(
                field: "wideInteger"
            )
        }
        return try DoryFSShareResourceLimits(
            maximumInFlightRequests: Int(inFlight),
            maximumAggregateRequestBytes: Int(aggregateRequest),
            maximumAggregateResponseBytes: Int(aggregateResponse),
            maximumLiveNonRootNodes: Int(nodes),
            maximumFileHandles: Int(fileHandles),
            maximumDirectoryHandles: Int(directoryHandles),
            maximumDirectoryCursorEntries: Int(cursorEntries),
            maximumDirectoryCursorNameBytes: Int(cursorNameBytes),
            maximumAdvisoryLockOwners: Int(lockOwners),
            maximumPendingBlockingLocks: Int(blockingLocks),
            reservedFileDescriptorHeadroom: Int(descriptorHeadroom)
        )
    }

    private static func readComponents(
        count: Int,
        from reader: inout BootstrapReader,
        index: Int
    ) throws -> [String] {
        var result = [String]()
        result.reserveCapacity(count)
        for componentIndex in 0..<count {
            let length = Int(try reader.readUInt16(
                field: "share[\(index)].component[\(componentIndex)].length"
            ))
            guard (1...maximumComponentBytes).contains(length) else {
                throw DoryFSWorkerBootstrapError.invalidComponent("<length \(length)>")
            }
            let bytes = try reader.readBytes(
                count: length,
                field: "share[\(index)].component[\(componentIndex)]"
            )
            guard let component = String(bytes: bytes, encoding: .utf8) else {
                throw DoryFSWorkerBootstrapError.invalidComponent("<invalid UTF-8>")
            }
            result.append(component)
        }
        return result
    }

    private static func encodedComponentBytes(_ values: [String]) -> Int {
        values.reduce(into: 0) { total, value in total += 2 + value.utf8.count }
    }
}

private struct BootstrapWriter {
    private(set) var bytes: [UInt8]

    init(reservingCapacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(reservingCapacity)
    }

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }

    mutating func append(_ values: [UInt8]) {
        bytes.append(contentsOf: values)
    }

    mutating func append(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ value: UUID) {
        let raw = value.uuid
        append([
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15,
        ])
    }

    mutating func replaceUInt32(at offset: Int, with value: UInt32) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }
}

private struct BootstrapReader {
    private let bytes: [UInt8]
    private var limits: [Int]
    private(set) var offset = 0

    init(data: Data) {
        self.bytes = [UInt8](data)
        self.limits = [data.count]
    }

    var remaining: Int { limits.last! - offset }
    var isAtEnd: Bool { offset == limits.last! }

    mutating func pushLimit(_ value: Int) {
        precondition(value >= offset && value <= limits.last!)
        limits.append(value)
    }

    mutating func popLimit() {
        precondition(limits.count > 1)
        limits.removeLast()
    }

    mutating func readBytes(count: Int, field: String) throws -> [UInt8] {
        guard count >= 0, count <= remaining else {
            throw DoryFSWorkerBootstrapError.truncatedField(field)
        }
        let start = offset
        offset += count
        return Array(bytes[start..<offset])
    }

    mutating func readUInt16(field: String) throws -> UInt16 {
        let value = try readBytes(count: 2, field: field)
        return UInt16(value[0]) | (UInt16(value[1]) << 8)
    }

    mutating func readUInt32(field: String) throws -> UInt32 {
        let value = try readBytes(count: 4, field: field)
        var result: UInt32 = 0
        for index in 0..<4 {
            result |= UInt32(value[index]) << UInt32(index * 8)
        }
        return result
    }

    mutating func readUInt64(field: String) throws -> UInt64 {
        let value = try readBytes(count: 8, field: field)
        var result: UInt64 = 0
        for index in 0..<8 {
            result |= UInt64(value[index]) << UInt64(index * 8)
        }
        return result
    }

    mutating func readUUID(field: String) throws -> UUID {
        let value = try readBytes(count: 16, field: field)
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}
