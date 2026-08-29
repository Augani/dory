import Foundation

/// Cross-process native Metal scanout authority. The accompanying XPC reply carries exactly one
/// `MTLSharedTextureHandle` and no file descriptor. Keeping this binary identity separate from the
/// Foundation/XPC transport object lets doryd attest the renderer tuple without importing Metal.
public struct DoryRendererSharedTextureScanoutLease: Equatable, Sendable {
    public let workerGeneration: DoryRendererWorkerGeneration
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let leaseID: DoryRendererScanoutLeaseID
    public let releaseToken: DoryRendererScanoutReleaseToken
    public let synchronization: DoryRendererScanoutSynchronization
    public let pixelFormat: DoryRendererScanoutPixelFormat
    public let yOriginTop: Bool
    public let width: UInt32
    public let height: UInt32

    public init(
        workerGeneration: DoryRendererWorkerGeneration,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        leaseID: DoryRendererScanoutLeaseID,
        releaseToken: DoryRendererScanoutReleaseToken,
        synchronization: DoryRendererScanoutSynchronization,
        pixelFormat: DoryRendererScanoutPixelFormat,
        yOriginTop: Bool,
        width: UInt32,
        height: UInt32,
        limits: DoryRendererWorkerLimits = .production
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw DoryRendererWorkerContractError.invalidScanoutIdentity
        }
        guard synchronization == .managedGuestProducerCompleteFlush,
              width > 0, height > 0,
              width <= 16_384, height <= 16_384 else {
            throw DoryRendererWorkerContractError.invalidScanoutGeometry
        }
        let (pixels, pixelOverflow) = UInt64(width).multipliedReportingOverflow(
            by: UInt64(height)
        )
        let (visibleBytes, byteOverflow) = pixels.multipliedReportingOverflow(
            by: pixelFormat.bytesPerPixel
        )
        guard !pixelOverflow, !byteOverflow,
              visibleBytes > 0,
              visibleBytes <= limits.maximumScanoutBytes else {
            if !pixelOverflow, !byteOverflow,
               visibleBytes > limits.maximumScanoutBytes {
                throw DoryRendererWorkerContractError.scanoutBytesTooLarge(
                    limit: limits.maximumScanoutBytes,
                    actual: visibleBytes
                )
            }
            throw DoryRendererWorkerContractError.invalidScanoutGeometry
        }
        self.workerGeneration = workerGeneration
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.leaseID = leaseID
        self.releaseToken = releaseToken
        self.synchronization = synchronization
        self.pixelFormat = pixelFormat
        self.yOriginTop = yOriginTop
        self.width = width
        self.height = height
    }
}

public enum DoryRendererSharedTextureScanoutLeaseCodec {
    public static let fixedByteCount = 96
    private static let magic: [UInt8] = [0x44, 0x52, 0x54, 0x31] // "DRT1"
    private static let version: UInt16 = 1
    private static let yOriginTopFlag: UInt32 = 1 << 0

    public static func encode(_ lease: DoryRendererSharedTextureScanoutLease) -> Data {
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
        bytes.appendLE(lease.synchronization.rawValue)
        bytes.appendLE(UInt16(0))
        bytes.appendLE(lease.width)
        bytes.appendLE(lease.height)
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt64(0))
        precondition(bytes.count == fixedByteCount)
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererSharedTextureScanoutLease {
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
        guard bytes.leUInt16(at: 6) == UInt16(fixedByteCount) else {
            throw DoryRendererWorkerContractError.invalidHeaderLength(bytes.leUInt16(at: 6))
        }
        guard bytes.leUInt32(at: 8) == UInt32(data.count) else {
            throw DoryRendererWorkerContractError.frameLengthMismatch(
                declared: bytes.leUInt32(at: 8),
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
        guard bytes.leUInt16(at: 74) == 0,
              bytes.leUInt32(at: 84) == 0,
              bytes.leUInt64(at: 88) == 0 else {
            throw DoryRendererWorkerContractError.nonzeroReservedField
        }
        guard let pixelFormat = DoryRendererScanoutPixelFormat(
            rawValue: bytes.leUInt32(at: 28)
        ), let synchronization = DoryRendererScanoutSynchronization(
            rawValue: bytes.leUInt16(at: 72)
        ) else {
            throw DoryRendererWorkerContractError.invalidScanoutDescriptorLayout
        }
        return try DoryRendererSharedTextureScanoutLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: bytes.leUInt64(at: 16)),
            resourceID: bytes.leUInt32(at: 24),
            resourceGeneration: bytes.leUInt64(at: 32),
            leaseID: DoryRendererScanoutLeaseID(
                rawValue: UUID(doryRendererBytes: bytes[40..<56])
            ),
            releaseToken: DoryRendererScanoutReleaseToken(
                rawValue: UUID(doryRendererBytes: bytes[56..<72])
            ),
            synchronization: synchronization,
            pixelFormat: pixelFormat,
            yOriginTop: flags & yOriginTopFlag != 0,
            width: bytes.leUInt32(at: 76),
            height: bytes.leUInt32(at: 80),
            limits: limits
        )
    }
}
