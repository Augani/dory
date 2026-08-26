import Foundation

/// Candidate-bound artifact graph. Source pins identify the reviewed source graph; these digests
/// bind the exact built bytes that are allowed to participate in one renderer generation.
public struct DoryRendererArtifactManifest: Equatable, Sendable {
    public let candidateInventory: DoryRendererArtifactDigest
    public let managedGuestKernel: DoryRendererArtifactDigest
    public let guestMesa: DoryRendererArtifactDigest
    public let rendererWorkerExecutable: DoryRendererArtifactDigest
    public let rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash

    public init(
        candidateInventory: DoryRendererArtifactDigest,
        managedGuestKernel: DoryRendererArtifactDigest,
        guestMesa: DoryRendererArtifactDigest,
        rendererWorkerExecutable: DoryRendererArtifactDigest,
        rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash
    ) {
        self.candidateInventory = candidateInventory
        self.managedGuestKernel = managedGuestKernel
        self.guestMesa = guestMesa
        self.rendererWorkerExecutable = rendererWorkerExecutable
        self.rendererWorkerCodeDirectoryHash = rendererWorkerCodeDirectoryHash
    }
}

/// Immutable authority for one workspace and one renderer process generation. There are no paths,
/// environment values, library names, or fallback modes in this envelope. The signed service owns
/// one successful bootstrap attempt for its complete process lifetime.
public struct DoryRendererWorkerBootstrap: Equatable, Sendable {
    public let workspaceID: DoryRendererWorkspaceID
    public let generation: DoryRendererWorkerGeneration
    public let sourceTuple: DoryRendererSourceTuple
    public let producerFenceContract: DoryRendererProducerFenceContract
    public let requestedCapabilities: DoryRendererRequestedCapabilities
    public let artifacts: DoryRendererArtifactManifest
    public let limits: DoryRendererWorkerLimits

    public init(
        workspaceID: DoryRendererWorkspaceID,
        generation: DoryRendererWorkerGeneration,
        sourceTuple: DoryRendererSourceTuple,
        producerFenceContract: DoryRendererProducerFenceContract,
        requestedCapabilities: DoryRendererRequestedCapabilities,
        artifacts: DoryRendererArtifactManifest,
        limits: DoryRendererWorkerLimits = .production
    ) throws {
        guard sourceTuple == .productionCandidate else {
            throw DoryRendererWorkerContractError.unsupportedSourceTuple(sourceTuple.rawValue)
        }
        guard producerFenceContract == .managedLinux61230PrepareFBV1 else {
            throw DoryRendererWorkerContractError.unsupportedProducerFenceContract(
                producerFenceContract.rawValue
            )
        }
        guard requestedCapabilities == .productionAcceleration else {
            throw DoryRendererWorkerContractError.incompleteAccelerationRequest
        }
        self.workspaceID = workspaceID
        self.generation = generation
        self.sourceTuple = sourceTuple
        self.producerFenceContract = producerFenceContract
        self.requestedCapabilities = requestedCapabilities
        self.artifacts = artifacts
        self.limits = limits
    }
}

/// Canonical fixed-width bootstrap. Exact width makes trailing-data and omitted-field attacks
/// impossible and lets the receiver reject the envelope before allocating command or scanout
/// resources.
public enum DoryRendererWorkerBootstrapCodec {
    public static let fixedByteCount = 228
    private static let magic: [UInt8] = [0x44, 0x52, 0x42, 0x33] // "DRB3"
    private static let version: UInt16 = 3

    public static func encode(_ bootstrap: DoryRendererWorkerBootstrap) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(fixedByteCount)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(fixedByteCount))
        bytes.appendLE(UInt32(fixedByteCount))
        bytes.appendLE(bootstrap.requestedCapabilities.rawValue)
        bytes.appendLE(bootstrap.producerFenceContract.rawValue)
        bytes.appendLE(bootstrap.sourceTuple.rawValue)
        bytes.appendLE(bootstrap.generation.rawValue)
        bytes.append(contentsOf: bootstrap.workspaceID.rawValue.doryRendererBytes)
        append(bootstrap.artifacts.candidateInventory, to: &bytes)
        append(bootstrap.artifacts.managedGuestKernel, to: &bytes)
        append(bootstrap.artifacts.guestMesa, to: &bytes)
        append(bootstrap.artifacts.rendererWorkerExecutable, to: &bytes)
        bytes.append(contentsOf: bootstrap.artifacts.rendererWorkerCodeDirectoryHash.bytes)
        bytes.appendLE(UInt32(bootstrap.limits.maximumCommandBytes))
        bytes.appendLE(UInt32(bootstrap.limits.maximumSharedRegions))
        bytes.appendLE(bootstrap.limits.maximumReferencedBytes)
        bytes.appendLE(UInt32(bootstrap.limits.maximumInFlightCommands))
        bytes.appendLE(UInt32(bootstrap.limits.maximumLiveScanoutLeases))
        bytes.appendLE(bootstrap.limits.maximumScanoutBytes)
        bytes.appendLE(UInt32(0))
        precondition(bytes.count == fixedByteCount)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> DoryRendererWorkerBootstrap {
        guard data.count >= 12 else {
            throw DoryRendererWorkerContractError.shortFrame(minimum: 12, actual: data.count)
        }
        guard data.count <= fixedByteCount else {
            throw DoryRendererWorkerContractError.frameTooLarge(
                limit: fixedByteCount,
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
        let headerLength = bytes.leUInt16(at: 6)
        guard headerLength == UInt16(fixedByteCount) else {
            throw DoryRendererWorkerContractError.invalidHeaderLength(headerLength)
        }
        let declaredLength = bytes.leUInt32(at: 8)
        guard Int(declaredLength) == data.count else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        guard data.count == fixedByteCount else {
            throw DoryRendererWorkerContractError.shortFrame(
                minimum: fixedByteCount,
                actual: data.count
            )
        }
        let requestedRaw = bytes.leUInt32(at: 12)
        guard requestedRaw & ~DoryRendererRequestedCapabilities.knownMask == 0 else {
            throw DoryRendererWorkerContractError.unknownFlags(requestedRaw)
        }
        guard bytes.leUInt32(at: 224) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }

        guard let producerFenceContract = DoryRendererProducerFenceContract(
            rawValue: bytes.leUInt16(at: 16)
        ) else {
            throw DoryRendererWorkerContractError.unsupportedProducerFenceContract(
                bytes.leUInt16(at: 16)
            )
        }
        guard let sourceTuple = DoryRendererSourceTuple(rawValue: bytes.leUInt16(at: 18)) else {
            throw DoryRendererWorkerContractError.unsupportedSourceTuple(bytes.leUInt16(at: 18))
        }
        let generation = try DoryRendererWorkerGeneration(rawValue: bytes.leUInt64(at: 20))
        let workspaceID = try DoryRendererWorkspaceID(
            rawValue: UUID(doryRendererBytes: bytes[28..<44])
        )
        let artifacts = try DoryRendererArtifactManifest(
            candidateInventory: digest(bytes, at: 44, field: "candidateInventory"),
            managedGuestKernel: digest(bytes, at: 76, field: "managedGuestKernel"),
            guestMesa: digest(bytes, at: 108, field: "guestMesa"),
            rendererWorkerExecutable: digest(
                bytes,
                at: 140,
                field: "rendererWorkerExecutable"
            ),
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                bytes: Data(bytes[172..<192]),
                field: "rendererWorkerCodeDirectoryHash"
            )
        )
        let limits = try DoryRendererWorkerLimits(
            maximumCommandBytes: Int(bytes.leUInt32(at: 192)),
            maximumSharedRegions: Int(bytes.leUInt32(at: 196)),
            maximumReferencedBytes: bytes.leUInt64(at: 200),
            maximumInFlightCommands: Int(bytes.leUInt32(at: 208)),
            maximumLiveScanoutLeases: Int(bytes.leUInt32(at: 212)),
            maximumScanoutBytes: bytes.leUInt64(at: 216)
        )
        let decoded = try DoryRendererWorkerBootstrap(
            workspaceID: workspaceID,
            generation: generation,
            sourceTuple: sourceTuple,
            producerFenceContract: producerFenceContract,
            requestedCapabilities: DoryRendererRequestedCapabilities(rawValue: requestedRaw),
            artifacts: artifacts,
            limits: limits
        )
        guard encode(decoded) == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }

    private static func append(
        _ digest: DoryRendererArtifactDigest,
        to bytes: inout [UInt8]
    ) {
        bytes.append(contentsOf: digest.bytes)
    }

    private static func digest(
        _ bytes: [UInt8],
        at offset: Int,
        field: String
    ) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(
            bytes: Data(bytes[offset..<(offset + DoryRendererArtifactDigest.byteCount)]),
            field: field
        )
    }
}
