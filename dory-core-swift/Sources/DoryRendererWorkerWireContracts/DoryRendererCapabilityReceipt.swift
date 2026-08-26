import CryptoKit
import Foundation

public struct DoryRendererWorkerFeatures: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let virgl2 = Self(rawValue: 1 << 0)
    public static let venus = Self(rawValue: 1 << 1)
    /// Venus HOST3D resources are reconstructed as zero-copy linear Metal textures over SHM.
    public static let sharedMemoryMetalScanout = Self(rawValue: 1 << 2)
    public static let rendererFenceDescriptor = Self(rawValue: 1 << 3)
    public static let singleUseLeaseRelease = Self(rawValue: 1 << 4)
    public static let isolatedSignedWorker = Self(rawValue: 1 << 5)
    public static let deviceLossFailStop = Self(rawValue: 1 << 6)
    public static let managedProducerFenceAccepted = Self(rawValue: 1 << 7)
    /// Venus scanout bytes remain in descriptor-backed shared memory and become a Metal texture
    /// lease; a readback/copy/upload presentation fallback is not this capability.
    public static let zeroCopyDescriptorBackedScanout = Self(rawValue: 1 << 8)
    /// Submit/fence operations return after bounded enqueue. GPU completion is delivered by the
    /// producer-fence descriptor and never synchronously waited on the XPC request executor.
    public static let asynchronousGPUCompletion = Self(rawValue: 1 << 9)
    /// VirGL2 scanout is a private shareable Metal texture imported by handle. No OpenGL object
    /// name, IOSurface, readback, CPU mapping, or upload is accepted as this capability.
    public static let zeroCopySharedTextureMetalScanout = Self(rawValue: 1 << 10)

    public static let productionAcceleration: Self = [
        .virgl2,
        .venus,
        .sharedMemoryMetalScanout,
        .rendererFenceDescriptor,
        .singleUseLeaseRelease,
        .isolatedSignedWorker,
        .deviceLossFailStop,
        .managedProducerFenceAccepted,
        .zeroCopyDescriptorBackedScanout,
        .asynchronousGPUCompletion,
        .zeroCopySharedTextureMetalScanout,
    ]

    static let knownMask = productionAcceleration.rawValue
}

public struct DoryRendererCapsetAttestation: Equatable, Sendable {
    public static let maximumCapsetBytes = 16 * 1_024 * 1_024
    public let id: UInt32
    public let maximumVersion: UInt32
    /// Exact bytes returned to the guest by GET_CAPSET. A digest-only receipt cannot safely
    /// advertise acceleration because the VMM would need a second, unauthenticated byte source.
    public let data: Data
    public let digest: DoryRendererArtifactDigest

    public var byteCount: Int { data.count }

    public init(
        id: UInt32,
        maximumVersion: UInt32,
        data: Data
    ) throws {
        guard id == 2 || id == 4 else {
            throw DoryRendererWorkerContractError.invalidCapsetID(id)
        }
        // virglrenderer exposes Venus at outer version zero; VirGL2 has a positive outer protocol
        // version. Protocol versions for Venus live inside `virgl_renderer_capset_venus`.
        guard (id == 4 && maximumVersion == 0) || (id == 2 && maximumVersion > 0) else {
            throw DoryRendererWorkerContractError.invalidCapsetVersion(
                id: id,
                maximumVersion: maximumVersion
            )
        }
        guard !data.isEmpty,
              data.count <= Self.maximumCapsetBytes else {
            throw DoryRendererWorkerContractError.invalidCapsetSize(
                limit: Self.maximumCapsetBytes,
                actual: data.count
            )
        }
        self.id = id
        self.maximumVersion = maximumVersion
        self.data = data
        self.digest = try DoryRendererArtifactDigest(
            bytes: Data(SHA256.hash(data: data)),
            field: "capset-\(id)"
        )
    }
}

/// Bootstrap receipt and the only authority from which a caller may advertise acceleration. An
/// incomplete receipt is useful diagnostic evidence, but `productionAccelerationIsAdmissible`
/// remains false and the requested capability must fail instead of silently becoming software.
public struct DoryRendererCapabilityReceipt: Equatable, Sendable {
    public static let maximumCapsets = 2
    public let workspaceID: DoryRendererWorkspaceID
    public let generation: DoryRendererWorkerGeneration
    public let sourceTuple: DoryRendererSourceTuple
    public let producerFenceContract: DoryRendererProducerFenceContract
    public let candidateInventory: DoryRendererArtifactDigest
    public let rendererWorkerExecutable: DoryRendererArtifactDigest
    public let features: DoryRendererWorkerFeatures
    public let capsets: [DoryRendererCapsetAttestation]

    public var productionAccelerationIsAdmissible: Bool {
        features == .productionAcceleration
            && capsets.map(\.id) == [2, 4]
    }

    public init(
        accepting bootstrap: DoryRendererWorkerBootstrap,
        features: DoryRendererWorkerFeatures,
        capsets: [DoryRendererCapsetAttestation]
    ) throws {
        guard features.rawValue & ~DoryRendererWorkerFeatures.knownMask == 0 else {
            throw DoryRendererWorkerContractError.unknownFlags(
                UInt32(truncatingIfNeeded: features.rawValue)
            )
        }
        guard capsets.count <= Self.maximumCapsets else {
            throw DoryRendererWorkerContractError.invalidCapsetCount(
                limit: Self.maximumCapsets,
                actual: capsets.count
            )
        }
        let canonicalCapsets = capsets.sorted { $0.id < $1.id }
        var capsetIDs = Set<UInt32>()
        for capset in canonicalCapsets {
            guard capsetIDs.insert(capset.id).inserted else {
                throw DoryRendererWorkerContractError.duplicateCapsetID(capset.id)
            }
        }
        self.workspaceID = bootstrap.workspaceID
        self.generation = bootstrap.generation
        self.sourceTuple = bootstrap.sourceTuple
        self.producerFenceContract = bootstrap.producerFenceContract
        self.candidateInventory = bootstrap.artifacts.candidateInventory
        self.rendererWorkerExecutable = bootstrap.artifacts.rendererWorkerExecutable
        self.features = features
        self.capsets = canonicalCapsets
    }
}

public enum DoryRendererCapabilityReceiptCodec {
    public static let headerByteCount = 120
    public static let capsetHeaderByteCount = 48
    public static let maximumFrameBytes = headerByteCount
        + DoryRendererCapabilityReceipt.maximumCapsets
            * (capsetHeaderByteCount + DoryRendererCapsetAttestation.maximumCapsetBytes)
    private static let magic: [UInt8] = [0x44, 0x52, 0x52, 0x31] // "DRR1"
    private static let version: UInt16 = 4

    public static func encode(_ receipt: DoryRendererCapabilityReceipt) -> Data {
        let total = headerByteCount + receipt.capsets.reduce(0) {
            $0 + capsetHeaderByteCount + $1.data.count
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(total)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(headerByteCount))
        bytes.appendLE(UInt32(total))
        bytes.appendLE(receipt.features.rawValue)
        bytes.appendLE(receipt.sourceTuple.rawValue)
        bytes.appendLE(receipt.producerFenceContract.rawValue)
        bytes.appendLE(receipt.generation.rawValue)
        bytes.append(contentsOf: receipt.workspaceID.rawValue.doryRendererBytes)
        bytes.append(contentsOf: receipt.candidateInventory.bytes)
        bytes.append(contentsOf: receipt.rendererWorkerExecutable.bytes)
        bytes.appendLE(UInt16(receipt.capsets.count))
        bytes.appendLE(UInt16(0))
        bytes.appendLE(UInt32(0))
        precondition(bytes.count == headerByteCount)
        for capset in receipt.capsets {
            bytes.appendLE(capset.id)
            bytes.appendLE(capset.maximumVersion)
            bytes.appendLE(UInt32(capset.byteCount))
            bytes.appendLE(UInt32(0))
            bytes.append(contentsOf: capset.digest.bytes)
            bytes.append(contentsOf: capset.data)
        }
        precondition(bytes.count == total)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        accepting bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
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
        guard bytes.leUInt16(at: 114) == 0,
              bytes.leUInt32(at: 116) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        let featureRaw = bytes.leUInt64(at: 12)
        guard featureRaw & ~DoryRendererWorkerFeatures.knownMask == 0 else {
            throw DoryRendererWorkerContractError.unknownFlags(UInt32(truncatingIfNeeded: featureRaw))
        }
        let capsetCount = Int(bytes.leUInt16(at: 112))
        guard capsetCount <= DoryRendererCapabilityReceipt.maximumCapsets else {
            throw DoryRendererWorkerContractError.invalidCapsetCount(
                limit: DoryRendererCapabilityReceipt.maximumCapsets,
                actual: capsetCount
            )
        }
        guard bytes.leUInt16(at: 20) == bootstrap.sourceTuple.rawValue,
              bytes.leUInt16(at: 22) == bootstrap.producerFenceContract.rawValue,
              bytes.leUInt64(at: 24) == bootstrap.generation.rawValue,
              UUID(doryRendererBytes: bytes[32..<48]) == bootstrap.workspaceID.rawValue,
              Data(bytes[48..<80]) == bootstrap.artifacts.candidateInventory.bytes,
              Data(bytes[80..<112]) == bootstrap.artifacts.rendererWorkerExecutable.bytes else {
            throw DoryRendererWorkerContractError.incompleteCapabilityReceipt
        }
        var capsets = [DoryRendererCapsetAttestation]()
        capsets.reserveCapacity(capsetCount)
        var base = headerByteCount
        for _ in 0..<capsetCount {
            guard base <= bytes.count,
                  capsetHeaderByteCount <= bytes.count - base else {
                throw DoryRendererWorkerContractError.shortFrame(
                    minimum: base + capsetHeaderByteCount,
                    actual: bytes.count
                )
            }
            guard bytes.leUInt32(at: base + 12) == 0 else {
                throw DoryRendererWorkerContractError.nonzeroReservedField
            }
            let byteCount = Int(bytes.leUInt32(at: base + 8))
            guard byteCount > 0,
                  byteCount <= DoryRendererCapsetAttestation.maximumCapsetBytes,
                  byteCount <= bytes.count - base - capsetHeaderByteCount else {
                throw DoryRendererWorkerContractError.invalidCapsetSize(
                    limit: DoryRendererCapsetAttestation.maximumCapsetBytes,
                    actual: byteCount
                )
            }
            let payloadStart = base + capsetHeaderByteCount
            let payloadEnd = payloadStart + byteCount
            let capset = try DoryRendererCapsetAttestation(
                id: bytes.leUInt32(at: base),
                maximumVersion: bytes.leUInt32(at: base + 4),
                data: Data(bytes[payloadStart..<payloadEnd])
            )
            guard capset.digest.bytes == Data(bytes[(base + 16)..<(base + 48)]) else {
                throw DoryRendererWorkerContractError.incompleteCapabilityReceipt
            }
            capsets.append(capset)
            base = payloadEnd
        }
        guard base == bytes.count else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: declaredLength,
                actual: data.count
            )
        }
        let decoded = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: DoryRendererWorkerFeatures(rawValue: featureRaw),
            capsets: capsets
        )
        guard encode(decoded) == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }
}
