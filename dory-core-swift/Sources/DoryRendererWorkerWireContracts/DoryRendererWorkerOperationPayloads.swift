import Foundation

/// C-layout-independent payload for `createContext`. Capset identity is selected explicitly; a
/// context cannot smuggle renderer authority or flags in the upper bits.
public struct DoryRendererContextCreatePayload: Equatable, Sendable {
    public static let maximumNameBytes = 64
    public let capsetID: UInt32
    public let name: String

    public init(capsetID: UInt32, name: String) throws {
        let nameBytes = Array(name.utf8)
        guard capsetID == 2 || capsetID == 4,
              !nameBytes.isEmpty,
              nameBytes.count <= Self.maximumNameBytes,
              !nameBytes.contains(0) else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createContext
            )
        }
        self.capsetID = capsetID
        self.name = name
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        bytes.appendLE(capsetID)
        bytes.append(contentsOf: name.utf8)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count > 4,
              let name = String(bytes: bytes[4...], encoding: .utf8) else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createContext
            )
        }
        let decoded = try Self(capsetID: bytes.leUInt32(at: 0), name: name)
        guard decoded.encoded == data else {
            throw DoryRendererWorkerContractError.nonCanonicalEncoding
        }
        return decoded
    }
}

/// Exact classic VirGL resource descriptor. The resource handle is carried by the command header,
/// and backing is attached separately through checked descriptor slices. This avoids copying a
/// foreign C aggregate over XPC and keeps resource memory authority independently revocable.
public struct DoryRendererResource3DCreatePayload: Equatable, Sendable {
    public static let byteCount = 40
    /// Gallium `PIPE_BUFFER` is target zero. Its `width` is a byte count rather than a texture
    /// dimension, so it is bounded by the negotiated referenced-memory authority instead of the
    /// renderer's per-dimension texture ceiling.
    public static let pipeBufferTarget: UInt32 = 0
    public static let maximumTextureDimension: UInt32 = 16_384

    public let target: UInt32
    public let format: UInt32
    public let bind: UInt32
    public let width: UInt32
    public let height: UInt32
    public let depth: UInt32
    public let arraySize: UInt32
    public let lastLevel: UInt32
    public let samples: UInt32
    public let flags: UInt32

    public init(
        target: UInt32,
        format: UInt32,
        bind: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        lastLevel: UInt32,
        samples: UInt32,
        flags: UInt32,
        maximumReferencedBytes: UInt64 = DoryRendererWorkerLimits.production
            .maximumReferencedBytes
    ) throws {
        let widthIsWithinTargetBound = target == Self.pipeBufferTarget
            ? UInt64(width) <= maximumReferencedBytes
            : width <= Self.maximumTextureDimension
        guard maximumReferencedBytes > 0,
              maximumReferencedBytes <= DoryRendererWorkerLimits.absoluteMaximumReferencedBytes,
              format != 0,
              width != 0, height != 0, depth != 0, arraySize != 0,
              widthIsWithinTargetBound,
              height <= Self.maximumTextureDimension,
              depth <= Self.maximumTextureDimension,
              arraySize <= Self.maximumTextureDimension,
              lastLevel <= 31, samples <= 64 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createResource3D
            )
        }
        self.target = target
        self.format = format
        self.bind = bind
        self.width = width
        self.height = height
        self.depth = depth
        self.arraySize = arraySize
        self.lastLevel = lastLevel
        self.samples = samples
        self.flags = flags
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        for value in [
            target, format, bind, width, height, depth, arraySize, lastLevel, samples, flags,
        ] {
            bytes.appendLE(value)
        }
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        maximumReferencedBytes: UInt64 = DoryRendererWorkerLimits.production
            .maximumReferencedBytes
    ) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createResource3D
            )
        }
        return try Self(
            target: bytes.leUInt32(at: 0),
            format: bytes.leUInt32(at: 4),
            bind: bytes.leUInt32(at: 8),
            width: bytes.leUInt32(at: 12),
            height: bytes.leUInt32(at: 16),
            depth: bytes.leUInt32(at: 20),
            arraySize: bytes.leUInt32(at: 24),
            lastLevel: bytes.leUInt32(at: 28),
            samples: bytes.leUInt32(at: 32),
            flags: bytes.leUInt32(at: 36),
            maximumReferencedBytes: maximumReferencedBytes
        )
    }
}

public struct DoryRendererBlobCreatePayload: Equatable, Sendable {
    public static let byteCount = 24
    private static let host3DMemory: UInt32 = 0x0002
    private static let mappableFlag: UInt32 = 0x0001
    public let blobMemory: UInt32
    public let blobFlags: UInt32
    public let blobID: UInt64
    public let size: UInt64

    public init(
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64
    ) throws {
        let supportedBlobID = blobID != 0 || (
            blobMemory == Self.host3DMemory && blobFlags == Self.mappableFlag
        )
        guard (1...4).contains(blobMemory),
              blobFlags & ~UInt32(0x0007) == 0,
              supportedBlobID,
              size != 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createBlob
            )
        }
        self.blobMemory = blobMemory
        self.blobFlags = blobFlags
        self.blobID = blobID
        self.size = size
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        bytes.appendLE(blobMemory)
        bytes.appendLE(blobFlags)
        bytes.appendLE(blobID)
        bytes.appendLE(size)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: .createBlob)
        }
        return try Self(
            blobMemory: bytes.leUInt32(at: 0),
            blobFlags: bytes.leUInt32(at: 4),
            blobID: bytes.leUInt64(at: 8),
            size: bytes.leUInt64(at: 16)
        )
    }
}

public struct DoryRendererTransfer3DPayload: Equatable, Sendable {
    public static let byteCount = 44
    public let level: UInt32
    public let stride: UInt32
    public let layerStride: UInt32
    public let offset: UInt64
    public let x: UInt32
    public let y: UInt32
    public let z: UInt32
    public let width: UInt32
    public let height: UInt32
    public let depth: UInt32

    public init(
        level: UInt32,
        stride: UInt32,
        layerStride: UInt32,
        offset: UInt64,
        x: UInt32,
        y: UInt32,
        z: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32
    ) throws {
        guard width != 0, height != 0, depth != 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .transferToHost3D
            )
        }
        self.level = level
        self.stride = stride
        self.layerStride = layerStride
        self.offset = offset
        self.x = x
        self.y = y
        self.z = z
        self.width = width
        self.height = height
        self.depth = depth
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        bytes.appendLE(level)
        bytes.appendLE(stride)
        bytes.appendLE(layerStride)
        bytes.appendLE(offset)
        for value in [x, y, z, width, height, depth] { bytes.appendLE(value) }
        return Data(bytes)
    }

    public static func decode(
        _ data: Data,
        operation: DoryRendererWorkerOperation
    ) throws -> Self {
        guard operation == .transferToHost3D || operation == .transferFromHost3D else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
        do {
            return try Self(
                level: bytes.leUInt32(at: 0),
                stride: bytes.leUInt32(at: 4),
                layerStride: bytes.leUInt32(at: 8),
                offset: bytes.leUInt64(at: 12),
                x: bytes.leUInt32(at: 20),
                y: bytes.leUInt32(at: 24),
                z: bytes.leUInt32(at: 28),
                width: bytes.leUInt32(at: 32),
                height: bytes.leUInt32(at: 36),
                depth: bytes.leUInt32(at: 40)
            )
        } catch {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: operation)
        }
    }
}

/// Linear scanout layout admitted only after the qualified guest's KMS producer wait has completed.
/// The VMM has already validated these values against SET_SCANOUT_BLOB and the exact resource
/// generation. The worker still bounds them independently against its recorded blob allocation,
/// exported SHM size, Metal alignment, and format allowlist before issuing a lease.
public struct DoryRendererScanoutAcquirePayload: Equatable, Sendable {
    public static let byteCount = 32
    public let width: UInt32
    public let height: UInt32
    public let virglFormat: UInt32
    public let stride: UInt32
    public let storageOffset: UInt32

    public init(
        width: UInt32,
        height: UInt32,
        virglFormat: UInt32,
        stride: UInt32,
        storageOffset: UInt32
    ) throws {
        guard width != 0, height != 0, width <= 16_384, height <= 16_384,
              virglFormat == 1 || virglFormat == 67,
              stride != 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .acquireScanoutLease
            )
        }
        self.width = width
        self.height = height
        self.virglFormat = virglFormat
        self.stride = stride
        self.storageOffset = storageOffset
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        for value in [width, height, virglFormat, stride, storageOffset, UInt32(0)] {
            bytes.appendLE(value)
        }
        bytes.appendLE(UInt64(0))
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .acquireScanoutLease
            )
        }
        guard bytes.leUInt32(at: 20) == 0,
              bytes.leUInt64(at: 24) == 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .acquireScanoutLease
            )
        }
        return try Self(
            width: bytes.leUInt32(at: 0),
            height: bytes.leUInt32(at: 4),
            virglFormat: bytes.leUInt32(at: 8),
            stride: bytes.leUInt32(at: 12),
            storageOffset: bytes.leUInt32(at: 16)
        )
    }
}

public struct DoryRendererFencePayload: Equatable, Sendable {
    public static let byteCount = 16
    /// The fence belongs to the renderer context/ring carried by the command. Without this bit,
    /// the fence is on the global ctx0 timeline.
    public static let contextTimeline: UInt32 = 1 << 0
    public static let knownFlags = contextTimeline
    public static let maximumRingIndex: UInt32 = 63

    public let flags: UInt32
    public let ringIndex: UInt32
    public let fenceID: UInt64

    public init(flags: UInt32, ringIndex: UInt32, fenceID: UInt64) throws {
        let isGlobalTimeline = flags == 0 && ringIndex == 0
        let isContextTimeline = flags == Self.contextTimeline
            && ringIndex <= Self.maximumRingIndex
        guard flags & ~Self.knownFlags == 0,
              isGlobalTimeline || isContextTimeline,
              fenceID != 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: .createFence)
        }
        self.flags = flags
        self.ringIndex = ringIndex
        self.fenceID = fenceID
    }

    public var isContextTimeline: Bool { flags == Self.contextTimeline }

    public var encoded: Data {
        var bytes = [UInt8]()
        bytes.appendLE(flags)
        bytes.appendLE(ringIndex)
        bytes.appendLE(fenceID)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(operation: .createFence)
        }
        return try Self(
            flags: bytes.leUInt32(at: 0),
            ringIndex: bytes.leUInt32(at: 4),
            fenceID: bytes.leUInt64(at: 8)
        )
    }
}

public struct DoryRendererResetPayload: Equatable, Sendable {
    public static let byteCount = 8
    public let successorGeneration: UInt64

    public init(successorGeneration: UInt64) throws {
        guard successorGeneration != 0 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .resetAfterDeviceQuiesce
            )
        }
        self.successorGeneration = successorGeneration
    }

    public var encoded: Data {
        var bytes = [UInt8]()
        bytes.appendLE(successorGeneration)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .resetAfterDeviceQuiesce
            )
        }
        return try Self(successorGeneration: bytes.leUInt64(at: 0))
    }
}

public extension DoryRendererScanoutReleaseToken {
    var commandPayload: Data {
        Swift.withUnsafeBytes(of: rawValue.uuid) { Data($0) }
    }

    static func decodeCommandPayload(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count == 16 else {
            throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .releaseScanoutLease
            )
        }
        return try Self(rawValue: UUID(doryRendererBytes: bytes[0..<16]))
    }
}
