import DoryRendererWorkerWireContracts
import Foundation

public enum DoryVMDisplayWireError: Error, Equatable, Sendable {
    case invalidMachineID
    case invalidOperationID
    case invalidFrameIdentity
    case invalidRectangle
    case invalidTransportAuthority
    case invalidCommand
    case frameTooLarge
    case commandTooLarge
    case cursorTooLarge
    case invalidCursor
    case nonCanonicalEncoding
}

public enum DoryVMDisplayFrameTransport: String, Codable, Sendable {
    case cpuCopy
    case sharedMemory
    case sharedTexture
}

/// Descriptor-backed snapshot used before a guest renderer owns the scanout (UEFI, GRUB, and
/// early kernel modesetting). Unlike renderer leases, this transport makes no producer-fence or
/// zero-copy claim; the runner has already copied a coherent full surface into the descriptor.
public struct DoryVMDisplayCPUFrameLease: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var leaseID: UUID
    public var releaseToken: UUID
    public var pixelFormat: UInt32
    public var yOriginTop: Bool
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var declaredFileSize: UInt64

    public init(
        leaseID: UUID,
        releaseToken: UUID,
        pixelFormat: UInt32,
        yOriginTop: Bool,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        declaredFileSize: UInt64
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.leaseID = leaseID
        self.releaseToken = releaseToken
        self.pixelFormat = pixelFormat
        self.yOriginTop = yOriginTop
        self.width = width
        self.height = height
        self.stride = stride
        self.declaredFileSize = declaredFileSize
        try validate()
    }

    public func validate() throws {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let (minimumRowBytes, rowOverflow) = UInt64(width).multipliedReportingOverflow(by: 4)
        let (requiredBytes, surfaceOverflow) = UInt64(stride).multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard schemaVersion == Self.schemaVersion,
              leaseID != zero, releaseToken != zero, leaseID != releaseToken,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              DoryRendererScanoutPixelFormat(rawValue: pixelFormat) != nil,
              !rowOverflow, !surfaceOverflow,
              UInt64(stride) >= minimumRowBytes,
              stride % 4 == 0,
              requiredBytes == declaredFileSize,
              declaredFileSize > 0,
              declaredFileSize <= DoryRendererWorkerLimits.production.maximumScanoutBytes else {
            throw DoryVMDisplayWireError.invalidTransportAuthority
        }
    }
}

public enum DoryVMDisplayCPUFrameLeaseCodec {
    public static func encode(_ lease: DoryVMDisplayCPUFrameLease) throws -> Data {
        try lease.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(lease)
    }

    public static func decode(_ data: Data) throws -> DoryVMDisplayCPUFrameLease {
        let lease = try JSONDecoder().decode(DoryVMDisplayCPUFrameLease.self, from: data)
        try lease.validate()
        guard try encode(lease) == data else {
            throw DoryVMDisplayWireError.nonCanonicalEncoding
        }
        return lease
    }
}

public struct DoryVMDisplayRect: Codable, Equatable, Sendable {
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32

    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate func validate(withinWidth surfaceWidth: UInt32, height surfaceHeight: UInt32) throws {
        let (maxX, overflowX) = x.addingReportingOverflow(width)
        let (maxY, overflowY) = y.addingReportingOverflow(height)
        guard width > 0, height > 0, !overflowX, !overflowY,
              maxX <= surfaceWidth, maxY <= surfaceHeight else {
            throw DoryVMDisplayWireError.invalidRectangle
        }
    }
}

/// One producer-complete scanout lease relayed from the VM owner to the app-owned display.
/// `leasePayload` is the existing canonical renderer lease; pixels remain out-of-band in either
/// one shared-memory descriptor or one `MTLSharedTextureHandle`.
public struct DoryVMDisplayFrame: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1
    public static let maximumEncodedByteCount = 4_096
    public static let maximumScanoutCount: UInt32 = 16

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: String
    public var scanoutID: UInt32
    public var sequence: UInt64
    public var displayResourceGeneration: UInt64
    public var transport: DoryVMDisplayFrameTransport
    public var leasePayload: Data
    public var sourceRect: DoryVMDisplayRect
    public var dirtyRect: DoryVMDisplayRect

    public init(
        machineID: String,
        operationID: UUID,
        scanoutID: UInt32,
        sequence: UInt64,
        displayResourceGeneration: UInt64,
        transport: DoryVMDisplayFrameTransport,
        leasePayload: Data,
        sourceRect: DoryVMDisplayRect,
        dirtyRect: DoryVMDisplayRect
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.machineID = machineID
        self.operationID = operationID.uuidString.lowercased()
        self.scanoutID = scanoutID
        self.sequence = sequence
        self.displayResourceGeneration = displayResourceGeneration
        self.transport = transport
        self.leasePayload = leasePayload
        self.sourceRect = sourceRect
        self.dirtyRect = dirtyRect
        try validate()
    }

    public var leaseID: DoryRendererScanoutLeaseID {
        get throws {
            switch transport {
            case .cpuCopy:
                try DoryRendererScanoutLeaseID(
                    rawValue: DoryVMDisplayCPUFrameLeaseCodec.decode(leasePayload).leaseID
                )
            case .sharedMemory:
                try DoryRendererScanoutLeaseCodec.decode(leasePayload).leaseID
            case .sharedTexture:
                try DoryRendererSharedTextureScanoutLeaseCodec.decode(leasePayload).leaseID
            }
        }
    }

    public var releaseToken: DoryRendererScanoutReleaseToken {
        get throws {
            switch transport {
            case .cpuCopy:
                try DoryRendererScanoutReleaseToken(
                    rawValue: DoryVMDisplayCPUFrameLeaseCodec.decode(leasePayload).releaseToken
                )
            case .sharedMemory:
                try DoryRendererScanoutLeaseCodec.decode(leasePayload).releaseToken
            case .sharedTexture:
                try DoryRendererSharedTextureScanoutLeaseCodec.decode(leasePayload).releaseToken
            }
        }
    }

    public func validate(descriptorCount: Int, hasSharedTextureHandle: Bool) throws {
        try validate()
        switch transport {
        case .cpuCopy:
            guard descriptorCount == 1, !hasSharedTextureHandle else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
        case .sharedMemory:
            guard descriptorCount == 1, !hasSharedTextureHandle else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
        case .sharedTexture:
            guard descriptorCount == 0, hasSharedTextureHandle else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
        }
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              DoryVMDisplayValidation.validMachineID(machineID) else {
            throw DoryVMDisplayWireError.invalidMachineID
        }
        guard let parsedOperationID = UUID(uuidString: operationID),
              parsedOperationID.uuidString.lowercased() == operationID else {
            throw DoryVMDisplayWireError.invalidOperationID
        }
        guard scanoutID < Self.maximumScanoutCount, sequence > 0,
              displayResourceGeneration > 0 else {
            throw DoryVMDisplayWireError.invalidFrameIdentity
        }

        let workerGeneration: UInt64
        let resourceID: UInt32
        let rendererResourceGeneration: UInt64
        let width: UInt32
        let height: UInt32
        do {
            switch transport {
            case .cpuCopy:
                let lease = try DoryVMDisplayCPUFrameLeaseCodec.decode(leasePayload)
                workerGeneration = 1
                resourceID = 1
                rendererResourceGeneration = 1
                width = lease.width
                height = lease.height
            case .sharedMemory:
                let lease = try DoryRendererScanoutLeaseCodec.decode(leasePayload)
                workerGeneration = lease.workerGeneration.rawValue
                resourceID = lease.resourceID
                rendererResourceGeneration = lease.resourceGeneration
                width = lease.width
                height = lease.height
            case .sharedTexture:
                let lease = try DoryRendererSharedTextureScanoutLeaseCodec.decode(leasePayload)
                workerGeneration = lease.workerGeneration.rawValue
                resourceID = lease.resourceID
                rendererResourceGeneration = lease.resourceGeneration
                width = lease.width
                height = lease.height
            }
        } catch {
            throw DoryVMDisplayWireError.invalidTransportAuthority
        }
        guard workerGeneration > 0, resourceID > 0, rendererResourceGeneration > 0 else {
            throw DoryVMDisplayWireError.invalidFrameIdentity
        }
        try sourceRect.validate(withinWidth: width, height: height)
        try dirtyRect.validate(withinWidth: sourceRect.width, height: sourceRect.height)
    }

}

enum DoryVMDisplayValidation {
    static func validMachineID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.first?.isASCII == true,
              value.first?.isLetter == true || value.first?.isNumber == true else {
            return false
        }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        }
    }
}

public enum DoryVMDisplayFrameCodec {
    public static func encode(_ frame: DoryVMDisplayFrame) throws -> Data {
        try frame.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frame)
        guard data.count <= DoryVMDisplayFrame.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.frameTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DoryVMDisplayFrame {
        guard data.count <= DoryVMDisplayFrame.maximumEncodedByteCount else {
            throw DoryVMDisplayWireError.frameTooLarge
        }
        let frame = try JSONDecoder().decode(DoryVMDisplayFrame.self, from: data)
        try frame.validate()
        guard try encode(frame) == data else {
            throw DoryVMDisplayWireError.nonCanonicalEncoding
        }
        return frame
    }
}
