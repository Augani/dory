import Foundation

public struct DoryRendererScanoutLeaseID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zero else {
            throw DoryRendererWorkerContractError.invalidScanoutIdentity
        }
        self.rawValue = rawValue
    }

    private static let zero = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

public struct DoryRendererScanoutReleaseToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) throws {
        guard rawValue != Self.zero else {
            throw DoryRendererWorkerContractError.invalidScanoutIdentity
        }
        self.rawValue = rawValue
    }

    private static let zero = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

/// Formats the outer display may reconstruct as a linear Metal texture. This deliberately excludes
/// a generic numeric virgl/Vulkan format: adding a format requires audited channel order, Metal
/// usage, and row-layout qualification on both sides.
public enum DoryRendererScanoutPixelFormat: UInt32, Equatable, Sendable {
    case bgra8Unorm = 1
    case rgba8Unorm = 2

    public var bytesPerPixel: UInt64 { 4 }
}

/// The authenticated managed guest waits the framebuffer writer before RESOURCE_FLUSH. The VMM
/// may claim this boundary only for the exact qualified kernel contract carried by its signed
/// bootstrap; unknown kernels never reach this private lease protocol.
public enum DoryRendererScanoutSynchronization: UInt16, Equatable, Sendable {
    case managedGuestProducerCompleteFlush = 2
}

/// Path-free, zero-copy authority to reconstruct one producer-complete SHM-backed Metal scanout.
/// The XPC reply carries exactly one descriptor: index 0 is the sealed shared-memory allocation.
/// No Objective-C/Metal pointer crosses process identity, and copying these bytes into a second
/// frame buffer does not satisfy this contract.
public struct DoryRendererScanoutLease: Equatable, Sendable {
    public let workerGeneration: DoryRendererWorkerGeneration
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let leaseID: DoryRendererScanoutLeaseID
    public let releaseToken: DoryRendererScanoutReleaseToken
    public let sharedRegionID: DoryRendererSharedRegionID
    public let sharedMemoryDescriptorIndex: UInt16
    public let synchronization: DoryRendererScanoutSynchronization
    public let pixelFormat: DoryRendererScanoutPixelFormat
    public let yOriginTop: Bool
    public let width: UInt32
    public let height: UInt32
    public let stride: UInt32
    public let rowAlignment: UInt32
    public let storageOffset: UInt64
    public let declaredFileSize: UInt64
    public let leaseByteCount: UInt64

    public init(
        workerGeneration: DoryRendererWorkerGeneration,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        leaseID: DoryRendererScanoutLeaseID,
        releaseToken: DoryRendererScanoutReleaseToken,
        sharedRegionID: DoryRendererSharedRegionID,
        sharedMemoryDescriptorIndex: UInt16,
        synchronization: DoryRendererScanoutSynchronization,
        pixelFormat: DoryRendererScanoutPixelFormat,
        yOriginTop: Bool,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        rowAlignment: UInt32,
        storageOffset: UInt64,
        declaredFileSize: UInt64,
        leaseByteCount: UInt64,
        limits: DoryRendererWorkerLimits = .production
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw DoryRendererWorkerContractError.invalidScanoutIdentity
        }
        guard sharedMemoryDescriptorIndex == 0 else {
            throw DoryRendererWorkerContractError.invalidScanoutDescriptorLayout
        }
        guard synchronization == .managedGuestProducerCompleteFlush else {
            throw DoryRendererWorkerContractError.invalidScanoutDescriptorLayout
        }
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              rowAlignment >= 4,
              rowAlignment <= 65_536,
              rowAlignment.nonzeroBitCount == 1 else {
            throw DoryRendererWorkerContractError.invalidScanoutGeometry
        }
        let (minimumRowBytes, rowOverflow) = UInt64(width).multipliedReportingOverflow(
            by: pixelFormat.bytesPerPixel
        )
        guard !rowOverflow,
              UInt64(stride) >= minimumRowBytes,
              stride % rowAlignment == 0,
              storageOffset % UInt64(rowAlignment) == 0,
              leaseByteCount > 0,
              leaseByteCount <= limits.maximumScanoutBytes else {
            if leaseByteCount > limits.maximumScanoutBytes {
                throw DoryRendererWorkerContractError.scanoutBytesTooLarge(
                    limit: limits.maximumScanoutBytes,
                    actual: leaseByteCount
                )
            }
            throw DoryRendererWorkerContractError.invalidScanoutGeometry
        }
        let (precedingRows, rowSpanOverflow) = UInt64(height - 1).multipliedReportingOverflow(
            by: UInt64(stride)
        )
        let (visibleBytes, visibleOverflow) = precedingRows.addingReportingOverflow(minimumRowBytes)
        guard !rowSpanOverflow, !visibleOverflow,
              visibleBytes <= leaseByteCount,
              storageOffset <= declaredFileSize,
              leaseByteCount <= declaredFileSize - storageOffset else {
            throw DoryRendererWorkerContractError.invalidScanoutGeometry
        }
        self.workerGeneration = workerGeneration
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.leaseID = leaseID
        self.releaseToken = releaseToken
        self.sharedRegionID = sharedRegionID
        self.sharedMemoryDescriptorIndex = sharedMemoryDescriptorIndex
        self.synchronization = synchronization
        self.pixelFormat = pixelFormat
        self.yOriginTop = yOriginTop
        self.width = width
        self.height = height
        self.stride = stride
        self.rowAlignment = rowAlignment
        self.storageOffset = storageOffset
        self.declaredFileSize = declaredFileSize
        self.leaseByteCount = leaseByteCount
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

public enum DoryRendererScanoutLeaseCodec {
    public static let fixedByteCount = 144
    private static let magic: [UInt8] = [0x44, 0x52, 0x4c, 0x31] // "DRL1"
    private static let version: UInt16 = 2
    private static let yOriginTopFlag: UInt32 = 1 << 0

    public static func encode(_ lease: DoryRendererScanoutLease) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(fixedByteCount)
        bytes.append(contentsOf: magic)
        bytes.appendLE(version)
        bytes.appendLE(UInt16(fixedByteCount))
        bytes.appendLE(UInt32(fixedByteCount))
        bytes.appendLE(lease.yOriginTop ? yOriginTopFlag : 0)
        bytes.appendLE(lease.workerGeneration.rawValue)
        bytes.appendLE(lease.resourceID)
        bytes.appendLE(lease.pixelFormat.rawValue)
        bytes.appendLE(lease.resourceGeneration)
        bytes.append(contentsOf: lease.leaseID.rawValue.doryRendererBytes)
        bytes.append(contentsOf: lease.releaseToken.rawValue.doryRendererBytes)
        bytes.append(contentsOf: lease.sharedRegionID.rawValue.doryRendererBytes)
        bytes.appendLE(lease.sharedMemoryDescriptorIndex)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(lease.synchronization.rawValue)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(lease.width)
        bytes.appendLE(lease.height)
        bytes.appendLE(lease.stride)
        bytes.appendLE(lease.rowAlignment)
        bytes.appendLE(lease.storageOffset)
        bytes.appendLE(lease.declaredFileSize)
        bytes.appendLE(lease.leaseByteCount)
        bytes.appendLE(UInt64(0))
        precondition(bytes.count == fixedByteCount)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererScanoutLease {
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
        let flags = bytes.leUInt32(at: 12)
        guard flags & ~yOriginTopFlag == 0 else {
            throw DoryRendererWorkerContractError.unknownFlags(flags)
        }
        guard bytes.leUInt16(at: 90) == 0,
              bytes.leUInt16(at: 94) == 0,
              bytes.leUInt64(at: 136) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        guard let format = DoryRendererScanoutPixelFormat(rawValue: bytes.leUInt32(at: 28)) else {
            throw DoryRendererWorkerContractError.invalidScanoutFormat(bytes.leUInt32(at: 28))
        }
        guard let synchronization = DoryRendererScanoutSynchronization(
            rawValue: bytes.leUInt16(at: 92)
        ) else {
            throw DoryRendererWorkerContractError.invalidScanoutDescriptorLayout
        }
        let decoded = try DoryRendererScanoutLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: bytes.leUInt64(at: 16)),
            resourceID: bytes.leUInt32(at: 24),
            resourceGeneration: bytes.leUInt64(at: 32),
            leaseID: DoryRendererScanoutLeaseID(
                rawValue: UUID(doryRendererBytes: bytes[40..<56])
            ),
            releaseToken: DoryRendererScanoutReleaseToken(
                rawValue: UUID(doryRendererBytes: bytes[56..<72])
            ),
            sharedRegionID: DoryRendererSharedRegionID(
                rawValue: UUID(doryRendererBytes: bytes[72..<88])
            ),
            sharedMemoryDescriptorIndex: bytes.leUInt16(at: 88),
            synchronization: synchronization,
            pixelFormat: format,
            yOriginTop: flags & yOriginTopFlag != 0,
            width: bytes.leUInt32(at: 96),
            height: bytes.leUInt32(at: 100),
            stride: bytes.leUInt32(at: 104),
            rowAlignment: bytes.leUInt32(at: 108),
            storageOffset: bytes.leUInt64(at: 112),
            declaredFileSize: bytes.leUInt64(at: 120),
            leaseByteCount: bytes.leUInt64(at: 128),
            limits: limits
        )
        guard encode(decoded) == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }
}
