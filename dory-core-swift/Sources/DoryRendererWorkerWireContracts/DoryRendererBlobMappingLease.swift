import Foundation

/// Descriptor-backed authority for mapping a renderer blob in the VMM process. The worker never
/// returns a host pointer: the broker mmaps descriptor zero locally, binds that address to guest
/// memory, and tears it down before sending the generation-bound `unmapBlob` command.
public struct DoryRendererBlobMappingLease: Equatable, Sendable {
    public let workerGeneration: DoryRendererWorkerGeneration
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let sharedRegionID: DoryRendererSharedRegionID
    public let descriptorIndex: UInt16
    public let mapInfo: UInt32
    public let declaredFileSize: UInt64
    public let mappingByteCount: UInt64

    public init(
        workerGeneration: DoryRendererWorkerGeneration,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        sharedRegionID: DoryRendererSharedRegionID,
        descriptorIndex: UInt16,
        mapInfo: UInt32,
        declaredFileSize: UInt64,
        mappingByteCount: UInt64,
        limits: DoryRendererWorkerLimits = .production
    ) throws {
        guard resourceID != 0, resourceGeneration != 0,
              descriptorIndex == 0,
              (1...3).contains(mapInfo),
              declaredFileSize != 0,
              mappingByteCount != 0,
              mappingByteCount <= declaredFileSize,
              mappingByteCount <= limits.maximumReferencedBytes else {
            throw DoryRendererWorkerContractError.invalidSharedRegionBounds
        }
        self.workerGeneration = workerGeneration
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.sharedRegionID = sharedRegionID
        self.descriptorIndex = descriptorIndex
        self.mapInfo = mapInfo
        self.declaredFileSize = declaredFileSize
        self.mappingByteCount = mappingByteCount
    }

    public func validateOutOfBandDescriptorCount(_ actual: Int) throws {
        guard actual == 1 else {
            throw DoryRendererWorkerContractError.descriptorCountMismatch(
                expected: 1,
                actual: actual
            )
        }
    }
}

public enum DoryRendererBlobMappingLeaseCodec {
    public static let fixedByteCount = 80
    private static let magic: [UInt8] = [0x44, 0x52, 0x4d, 0x31] // "DRM1"
    private static let version: UInt16 = 1

    public static func encode(_ lease: DoryRendererBlobMappingLease) -> Data {
        var bytes = [UInt8]()
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(fixedByteCount))
        bytes.appendLE(UInt32(fixedByteCount))
        bytes.appendLE(lease.workerGeneration.rawValue)
        bytes.appendLE(lease.resourceID)
        bytes.appendLE(lease.mapInfo)
        bytes.appendLE(lease.resourceGeneration)
        bytes.append(contentsOf: lease.sharedRegionID.rawValue.doryRendererBytes)
        bytes.appendLE(lease.descriptorIndex)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(lease.declaredFileSize)
        bytes.appendLE(lease.mappingByteCount)
        bytes.appendLE(UInt64(0))
        precondition(bytes.count == fixedByteCount)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererBlobMappingLease {
        guard data.count == fixedByteCount else {
            if data.count > fixedByteCount {
                throw DoryRendererWorkerContractError.frameTooLarge(
                    limit: fixedByteCount,
                    actual: data.count
                )
            }
            throw DoryRendererWorkerContractError.shortFrame(
                minimum: fixedByteCount,
                actual: data.count
            )
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else {
            throw DoryRendererWorkerContractError.invalidMagic
        }
        guard bytes.leUInt16(at: 4) == version else {
            throw DoryRendererWorkerContractError.unsupportedVersion(bytes.leUInt16(at: 4))
        }
        guard bytes.leUInt16(at: 6) == UInt16(fixedByteCount) else {
            throw DoryRendererWorkerContractError.invalidHeaderLength(bytes.leUInt16(at: 6))
        }
        guard bytes.leUInt32(at: 8) == UInt32(fixedByteCount) else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: bytes.leUInt32(at: 8),
                actual: data.count
            )
        }
        guard bytes.leUInt16(at: 54) == 0, bytes.leUInt64(at: 72) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        let decoded = try DoryRendererBlobMappingLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: bytes.leUInt64(at: 12)),
            resourceID: bytes.leUInt32(at: 20),
            resourceGeneration: bytes.leUInt64(at: 28),
            sharedRegionID: DoryRendererSharedRegionID(
                rawValue: UUID(doryRendererBytes: bytes[36..<52])
            ),
            descriptorIndex: bytes.leUInt16(at: 52),
            mapInfo: bytes.leUInt32(at: 24),
            declaredFileSize: bytes.leUInt64(at: 56),
            mappingByteCount: bytes.leUInt64(at: 64),
            limits: limits
        )
        guard encode(decoded) == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }
}
