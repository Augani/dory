import Foundation

/// Stable identities for the runner-private renderer service. Both sides must pin the audit-token
/// code identity before exchanging any authority; a PID, service-name lookup, or inherited
/// environment is never peer authentication.
public enum DoryRendererWorkerIdentity {
    public static let serviceName = "com.pythonxi.Dory.HVRunner.RendererWorker"
    public static let workerBundleIdentifier = serviceName
    public static let runnerBundleIdentifier = "com.pythonxi.Dory.HVRunner"
    public static let developmentTeamIdentifier = "864H636QW4"

    public static let workerCodeSigningRequirement =
        #"anchor apple generic and identifier "com.pythonxi.Dory.HVRunner.RendererWorker" and certificate leaf[subject.OU] = "864H636QW4""#
    public static let runnerCodeSigningRequirement =
        #"anchor apple generic and identifier "com.pythonxi.Dory.HVRunner" and certificate leaf[subject.OU] = "864H636QW4""#

    /// Exact peer requirement for the already-selected renderer-worker code generation. The
    /// service name is only endpoint discovery; this requirement is the audit-token authority.
    public static func exactWorkerCodeSigningRequirement(
        codeDirectoryHash: DoryCodeDirectoryHash
    ) -> String {
        workerCodeSigningRequirement
            + " and cdhash H\"\(codeDirectoryHash.lowercaseHexadecimal)\""
    }

    /// Exact live requirement used to admit a newly spawned runner before it executes user code.
    public static func exactRunnerCodeSigningRequirement(
        codeDirectoryHash: DoryCodeDirectoryHash
    ) -> String {
        runnerCodeSigningRequirement
            + " and cdhash H\"\(codeDirectoryHash.lowercaseHexadecimal)\""
    }
}

public enum DoryRendererWorkerContractError: Error, Equatable, Sendable {
    case invalidWorkspaceIdentity
    case invalidGeneration
    case invalidDigest(field: String)
    case invalidCodeDirectoryHash(field: String)
    case unsupportedSourceTuple(UInt16)
    case unsupportedProducerFenceContract(UInt16)
    case incompleteAccelerationRequest
    case invalidLimits(field: String)
    case shortFrame(minimum: Int, actual: Int)
    case frameTooLarge(limit: Int, actual: Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidHeaderLength(UInt16)
    case frameLengthMismatch(declared: UInt32, actual: Int)
    case unknownFlags(UInt32)
    case nonzeroReservedField
    case nonCanonicalEncoding
    case invalidRequestID
    case invalidDeadline
    case unknownOperation(UInt16)
    case invalidOperationIdentity(operation: DoryRendererWorkerOperation)
    case invalidOperationPayload(operation: DoryRendererWorkerOperation)
    case invalidSharedRegionCount(limit: Int, actual: Int)
    case invalidSharedRegionIdentity
    case duplicateSharedRegionIdentity
    case invalidSharedRegionBounds
    case referencedBytesTooLarge(limit: UInt64, actual: UInt64)
    case descriptorCountMismatch(expected: Int, actual: Int)
    case invalidCapsetCount(limit: Int, actual: Int)
    case invalidCapsetID(UInt32)
    case invalidCapsetVersion(id: UInt32, maximumVersion: UInt32)
    case duplicateCapsetID(UInt32)
    case invalidCapsetSize(limit: Int, actual: Int)
    case incompleteCapabilityReceipt
    case invalidScanoutIdentity
    case invalidScanoutGeometry
    case invalidScanoutFormat(UInt32)
    case invalidScanoutDescriptorLayout
    case scanoutBytesTooLarge(limit: UInt64, actual: UInt64)
}

/// The 20-byte CodeDirectory hash used by macOS code requirements and audit-token-bound peer
/// authentication. This is deliberately not a file SHA-256: it identifies one signed running
/// slice, including the CodeDirectory's sealed special slots.
public struct DoryCodeDirectoryHash: Hashable, Sendable {
    public static let byteCount = 20
    public let bytes: Data

    public init(bytes: Data, field: String = "codeDirectoryHash") throws {
        guard bytes.count == Self.byteCount,
              bytes.contains(where: { $0 != 0 }) else {
            throw DoryRendererWorkerContractError.invalidCodeDirectoryHash(field: field)
        }
        self.bytes = bytes
    }

    public init(
        lowercaseHexadecimal: String,
        field: String = "codeDirectoryHash"
    ) throws {
        guard lowercaseHexadecimal.utf8.count == Self.byteCount * 2,
              lowercaseHexadecimal.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw DoryRendererWorkerContractError.invalidCodeDirectoryHash(field: field)
        }
        var decoded = Data(capacity: Self.byteCount)
        var index = lowercaseHexadecimal.startIndex
        for _ in 0..<Self.byteCount {
            let next = lowercaseHexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHexadecimal[index..<next], radix: 16) else {
                throw DoryRendererWorkerContractError.invalidCodeDirectoryHash(field: field)
            }
            decoded.append(byte)
            index = next
        }
        try self.init(bytes: decoded, field: field)
    }

    public var lowercaseHexadecimal: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DoryRendererWorkspaceID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zero else {
            throw DoryRendererWorkerContractError.invalidWorkspaceIdentity
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

public struct DoryRendererWorkerGeneration: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) throws {
        guard rawValue != 0 else {
            throw DoryRendererWorkerContractError.invalidGeneration
        }
        self.rawValue = rawValue
    }
}

/// Exact SHA-256 digest used for candidate-bound artifacts and capset bytes. An all-zero value is
/// rejected because it is the natural value of an uninitialized launch envelope.
public struct DoryRendererArtifactDigest: Hashable, Sendable {
    public static let byteCount = 32
    public let bytes: Data

    public init(bytes: Data, field: String = "digest") throws {
        guard bytes.count == Self.byteCount,
              bytes.contains(where: { $0 != 0 }) else {
            throw DoryRendererWorkerContractError.invalidDigest(field: field)
        }
        self.bytes = bytes
    }

    public init(lowercaseSHA256: String, field: String = "digest") throws {
        guard lowercaseSHA256.utf8.count == Self.byteCount * 2,
              lowercaseSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw DoryRendererWorkerContractError.invalidDigest(field: field)
        }
        var decoded = Data(capacity: Self.byteCount)
        var index = lowercaseSHA256.startIndex
        for _ in 0..<Self.byteCount {
            let next = lowercaseSHA256.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseSHA256[index..<next], radix: 16) else {
                throw DoryRendererWorkerContractError.invalidDigest(field: field)
            }
            decoded.append(byte)
            index = next
        }
        try self.init(bytes: decoded, field: field)
    }

    public var lowercaseSHA256: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The source tuple is a protocol version, not caller-provided component paths or revisions. A
/// different source graph requires a new case plus qualification; it cannot masquerade as this one
/// by supplying strings over XPC.
public enum DoryRendererSourceTuple: UInt16, Sendable {
    case doryVenusStatic20260823 = 2
    case doryDualMetal20260826 = 3

    public static let productionCandidate = Self.doryDualMetal20260826
    public static let virglrendererRevision = "65cc14eb896f121ffc5130ce04815a923a03c41d"
    public static let guestMesaRevision = "79bc850d884a1307356ff61c017e58901b90c7e2"
    public static let guestMesaTree = "585b6604e6ef58585cfc44f7b4d5eab172ddfbbd"
    public static let guestMesaSourceDateEpoch: UInt64 = 1_767_751_301
    public static let guestMesaBuildInputSHA256 =
        "19a55684e03b26053f504982ebbbd85f31d198bcaeb307239689fd11189f17e9"
    public static let guestMesaRuntimeSHA256 =
        "fa12e2bef9855dd382c3cd7f1dcd434f65302fc13471ae06367179f1ad37124c"
    public static let moltenVKRevision = "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384"
    /// SHA-256 of the canonical checked-in production tuple definition. A source enum alone is
    /// insufficient once exact build policy, transitive sources, and compatibility patches are
    /// part of release identity.
    public static let productionDefinitionSHA256 =
        "6f537361d165cbe75b04e98ce56c6e878060119c2aca112fa88ceba936092bba"
}

/// Guest-side authority that makes RESOURCE_FLUSH producer-complete. Unknown kernels may not claim
/// this proof merely because they negotiate the same virtio-gpu features.
public enum DoryRendererProducerFenceContract: UInt16, Sendable {
    case managedLinux612106PrepareFBV1 = 1
}

public struct DoryRendererRequestedCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let virgl2 = Self(rawValue: 1 << 0)
    public static let venus = Self(rawValue: 1 << 1)
    /// Venus HOST3D resources are exported as authenticated linear SHM and sampled in place.
    public static let sharedMemoryMetalScanout = Self(rawValue: 1 << 2)
    public static let synchronizedLeaseRelease = Self(rawValue: 1 << 3)
    /// VirGL2 scanout resources cross XPC only as private `MTLSharedTextureHandle` authority.
    public static let sharedTextureMetalScanout = Self(rawValue: 1 << 4)
    public static let productionAcceleration: Self = [
        .virgl2,
        .venus,
        .sharedMemoryMetalScanout,
        .synchronizedLeaseRelease,
        .sharedTextureMetalScanout,
    ]

    static let knownMask = productionAcceleration.rawValue
}

public struct DoryRendererWorkerLimits: Equatable, Sendable {
    public static let absoluteMaximumCommandBytes = 16 * 1_024 * 1_024
    /// Command protocol v2 carries the region count as a UInt32. The absolute ceiling covers the
    /// complete 1 GiB contract scanout as independently fragmented 4 KiB pages; production uses
    /// the same derivation for its tighter 512 MiB scanout policy below. Referenced-byte and frame
    /// byte limits remain independent, so increasing the iovec count does not grant more memory.
    public static let absoluteMaximumSharedRegions = 262_144
    public static let productionMaximumSharedRegions = 131_072
    public static let absoluteMaximumReferencedBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    public static let absoluteMaximumInFlightCommands = 1_024
    public static let absoluteMaximumLiveScanoutLeases = 256
    public static let absoluteMaximumScanoutBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024

    public let maximumCommandBytes: Int
    public let maximumSharedRegions: Int
    public let maximumReferencedBytes: UInt64
    public let maximumInFlightCommands: Int
    public let maximumLiveScanoutLeases: Int
    public let maximumScanoutBytes: UInt64

    public init(
        maximumCommandBytes: Int,
        maximumSharedRegions: Int,
        maximumReferencedBytes: UInt64,
        maximumInFlightCommands: Int,
        maximumLiveScanoutLeases: Int,
        maximumScanoutBytes: UInt64
    ) throws {
        try Self.require(
            maximumCommandBytes,
            atMost: Self.absoluteMaximumCommandBytes,
            field: "maximumCommandBytes"
        )
        try Self.require(
            maximumSharedRegions,
            atMost: Self.absoluteMaximumSharedRegions,
            field: "maximumSharedRegions"
        )
        guard maximumReferencedBytes > 0,
              maximumReferencedBytes <= Self.absoluteMaximumReferencedBytes else {
            throw DoryRendererWorkerContractError.invalidLimits(
                field: "maximumReferencedBytes"
            )
        }
        try Self.require(
            maximumInFlightCommands,
            atMost: Self.absoluteMaximumInFlightCommands,
            field: "maximumInFlightCommands"
        )
        try Self.require(
            maximumLiveScanoutLeases,
            atMost: Self.absoluteMaximumLiveScanoutLeases,
            field: "maximumLiveScanoutLeases"
        )
        guard maximumScanoutBytes > 0,
              maximumScanoutBytes <= Self.absoluteMaximumScanoutBytes else {
            throw DoryRendererWorkerContractError.invalidLimits(field: "maximumScanoutBytes")
        }
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumSharedRegions = maximumSharedRegions
        self.maximumReferencedBytes = maximumReferencedBytes
        self.maximumInFlightCommands = maximumInFlightCommands
        self.maximumLiveScanoutLeases = maximumLiveScanoutLeases
        self.maximumScanoutBytes = maximumScanoutBytes
    }

    public static let production = try! Self(
        maximumCommandBytes: absoluteMaximumCommandBytes,
        maximumSharedRegions: productionMaximumSharedRegions,
        maximumReferencedBytes: absoluteMaximumReferencedBytes,
        maximumInFlightCommands: 256,
        maximumLiveScanoutLeases: 64,
        maximumScanoutBytes: 512 * 1_024 * 1_024
    )

    private static func require(_ value: Int, atMost maximum: Int, field: String) throws {
        guard value > 0, value <= maximum else {
            throw DoryRendererWorkerContractError.invalidLimits(field: field)
        }
    }
}
