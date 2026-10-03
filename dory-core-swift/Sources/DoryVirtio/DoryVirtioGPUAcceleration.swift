import Foundation

public struct DoryVirtioGPUBackingEntry: Sendable, Hashable {
  public let guestAddress: UInt64
  public let length: UInt32

  public init(guestAddress: UInt64, length: UInt32) {
    self.guestAddress = guestAddress
    self.length = length
  }
}

/// Renderer-owned bytes that may be exposed through a guest host-visible aperture. The closures
/// deliberately keep foreign pointers out of the transport-neutral GPU model while preserving a
/// single shared backing for the renderer, guest CPU, translated helpers, and device DMA.
public final class DoryVirtioGPUBlobMemoryRegion: @unchecked Sendable {
  /// Host-authorized access, independent of the guest's cache-mode MAP_BLOB reply. Keep this
  /// immutable for the entire mapping lifetime so preflight and actual CPU/DMA access agree.
  public enum Access: Sendable, Equatable {
    case readOnly
    case readWrite
  }

  public let byteCount: UInt64
  public let access: Access

  private let reader: @Sendable (UInt64, Int) throws -> [UInt8]
  private let writer: @Sendable (UInt64, [UInt8]) throws -> Void
  private let atomicCompareExchange: (@Sendable (UInt64, UInt64, UInt64, Int) throws -> UInt64)?
  private let synchronizer: @Sendable () -> Void

  public init(
    byteCount: UInt64,
    access: Access = .readWrite,
    read: @escaping @Sendable (UInt64, Int) throws -> [UInt8],
    write: @escaping @Sendable (UInt64, [UInt8]) throws -> Void,
    compareExchange: (@Sendable (UInt64, UInt64, UInt64, Int) throws -> UInt64)? = nil,
    synchronize: @escaping @Sendable () -> Void = {}
  ) {
    precondition(byteCount > 0)
    self.byteCount = byteCount
    self.access = access
    reader = read
    writer = write
    atomicCompareExchange = compareExchange
    synchronizer = synchronize
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount > 0, offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    let bytes = try reader(offset, byteCount)
    // The renderer callback is a trust boundary. A short reply silently zero-extends scalar
    // reads; an oversized reply can make the PC scalar path shift beyond 64 bits.
    guard bytes.count == byteCount else {
      throw DoryVirtioGPUAccelerationError.invalidBlobMapping
    }
    return bytes
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    guard access == .readWrite,
      !bytes.isEmpty, offset <= byteCount, UInt64(bytes.count) <= byteCount - offset
    else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    try writer(offset, bytes)
  }

  public func synchronize() { synchronizer() }

  /// An optional backing-owned atomic operation. A caller must not synthesize this from separate
  /// read/write closures: another vCPU or DMA access could interleave between them.
  public func compareExchange(
    offset: UInt64, expected: UInt64, desired: UInt64, byteCount: Int
  ) throws -> UInt64? {
    guard access == .readWrite,
      [1, 2, 4, 8].contains(byteCount), offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    let observed = try atomicCompareExchange?(offset, expected, desired, byteCount)
    if let observed, byteCount < 8,
      observed >> UInt64(byteCount * 8) != 0
    {
      throw DoryVirtioGPUAccelerationError.invalidBlobMapping
    }
    return observed
  }
}

public struct DoryVirtioGPUBlobResource: Sendable, Hashable {
  public let resourceID: UInt32
  public let contextID: UInt32
  public let blobMemory: UInt32
  public let blobFlags: UInt32
  public let blobID: UInt64
  public let size: UInt64

  public init(
    resourceID: UInt32,
    contextID: UInt32,
    blobMemory: UInt32,
    blobFlags: UInt32,
    blobID: UInt64,
    size: UInt64
  ) {
    self.resourceID = resourceID
    self.contextID = contextID
    self.blobMemory = blobMemory
    self.blobFlags = blobFlags
    self.blobID = blobID
    self.size = size
  }
}

/// The exact renderer-owned blob incarnation. Resource generations alone may restart when a
/// worker is replaced, and numeric generations can repeat in another machine launch. Every
/// mutating blob operation therefore carries the authenticated launch workspace as well.
public struct DoryVirtioGPUBlobIdentity: Sendable, Hashable {
  public let workspaceID: UUID
  public let resourceGeneration: UInt64
  public let workerGeneration: UInt64
  public let deviceGeneration: UInt64

  public init(
    workspaceID: UUID,
    resourceGeneration: UInt64,
    workerGeneration: UInt64,
    deviceGeneration: UInt64
  ) {
    self.workspaceID = workspaceID
    self.resourceGeneration = resourceGeneration
    self.workerGeneration = workerGeneration
    self.deviceGeneration = deviceGeneration
  }
}

public struct DoryVirtioGPUBlobMapping: @unchecked Sendable {
  public let workspaceID: UUID
  public let resourceID: UInt32
  public let resourceGeneration: UInt64
  public let workerGeneration: UInt64
  public let deviceGeneration: UInt64
  public let hostVisibleOffset: UInt64
  public let byteCount: UInt64
  public let mapInfo: UInt32
  public let memory: DoryVirtioGPUBlobMemoryRegion

  public init(
    workspaceID: UUID,
    resourceID: UInt32,
    resourceGeneration: UInt64,
    workerGeneration: UInt64,
    deviceGeneration: UInt64,
    hostVisibleOffset: UInt64,
    byteCount: UInt64,
    mapInfo: UInt32,
    memory: DoryVirtioGPUBlobMemoryRegion
  ) {
    self.workspaceID = workspaceID
    self.resourceID = resourceID
    self.resourceGeneration = resourceGeneration
    self.workerGeneration = workerGeneration
    self.deviceGeneration = deviceGeneration
    self.hostVisibleOffset = hostVisibleOffset
    self.byteCount = byteCount
    self.mapInfo = mapInfo
    self.memory = memory
  }
}

public struct DoryVirtioGPUBlobScanoutFlush: Sendable, Hashable {
  public let scanoutID: UInt32
  public let resourceID: UInt32
  public let identity: DoryVirtioGPUBlobIdentity
  public let sourceRectangle: DoryVirtioGPURectangle
  public let damagedRectangle: DoryVirtioGPURectangle
  public let width: UInt32
  public let height: UInt32
  public let format: UInt32
  public let stride: UInt32
  public let offset: UInt32

  public init(
    scanoutID: UInt32,
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    sourceRectangle: DoryVirtioGPURectangle,
    damagedRectangle: DoryVirtioGPURectangle,
    width: UInt32,
    height: UInt32,
    format: UInt32,
    stride: UInt32,
    offset: UInt32
  ) {
    self.scanoutID = scanoutID
    self.resourceID = resourceID
    self.identity = identity
    self.sourceRectangle = sourceRectangle
    self.damagedRectangle = damagedRectangle
    self.width = width
    self.height = height
    self.format = format
    self.stride = stride
    self.offset = offset
  }
}

/// Guest-visible mapping owner. `map` must install atomically (a throw leaves no alias for that
/// resource), reject holes and overlaps, and `unmap` must retire before returning. Reset revokes
/// every alias in one operation. Atomic installation lets the GPU roll back an accepted worker map
/// without accidentally removing a previously admitted local mapping.
public protocol DoryVirtioGPUHostVisibleAperture: AnyObject, Sendable {
  var regionID: UInt8 { get }
  var byteCount: UInt64 { get }
  /// Changes whenever a CPU/DMA route captured before map, unmap, or reset must be rejected.
  var apertureGeneration: UInt64 { get }
  /// Changes on reset or BAR relocation, not when an unrelated blob maps or unmaps. A worker
  /// MAP_BLOB reply can therefore commit alongside other independent blob operations, while a
  /// reply from before revocation can never install a new guest-visible alias.
  var mapAdmissionGeneration: UInt64 { get }
  /// Compare the captured map-admission epoch and install under one lock. A map reply arriving
  /// after reset must never become guest-visible before the GPU notices its resource vanished.
  func map(
    _ mapping: DoryVirtioGPUBlobMapping,
    expectedApertureGeneration: UInt64
  ) throws
  func unmap(resourceID: UInt32, identity: DoryVirtioGPUBlobIdentity) -> Bool
  func reset()
}

extension DoryVirtioGPUHostVisibleAperture {
  public var mapAdmissionGeneration: UInt64 { apertureGeneration }

  public func map(_ mapping: DoryVirtioGPUBlobMapping) throws {
    try map(mapping, expectedApertureGeneration: mapAdmissionGeneration)
  }
}

public struct DoryVirtioGPUResource3D: Sendable, Hashable {
  public let resourceID: UInt32
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
    resourceID: UInt32,
    target: UInt32,
    format: UInt32,
    bind: UInt32,
    width: UInt32,
    height: UInt32,
    depth: UInt32,
    arraySize: UInt32,
    lastLevel: UInt32,
    samples: UInt32,
    flags: UInt32
  ) {
    self.resourceID = resourceID
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
}

public struct DoryVirtioGPUTransfer3D: Sendable, Hashable {
  public enum Direction: Sendable, Hashable {
    case toHost
    case fromHost
  }

  public let direction: Direction
  public let resourceID: UInt32
  public let contextID: UInt32
  public let x: UInt32
  public let y: UInt32
  public let z: UInt32
  public let width: UInt32
  public let height: UInt32
  public let depth: UInt32
  public let offset: UInt64
  public let level: UInt32
  public let stride: UInt32
  public let layerStride: UInt32

  public init(
    direction: Direction,
    resourceID: UInt32,
    contextID: UInt32,
    x: UInt32,
    y: UInt32,
    z: UInt32,
    width: UInt32,
    height: UInt32,
    depth: UInt32,
    offset: UInt64,
    level: UInt32,
    stride: UInt32,
    layerStride: UInt32
  ) {
    self.direction = direction
    self.resourceID = resourceID
    self.contextID = contextID
    self.x = x
    self.y = y
    self.z = z
    self.width = width
    self.height = height
    self.depth = depth
    self.offset = offset
    self.level = level
    self.stride = stride
    self.layerStride = layerStride
  }
}

public struct DoryVirtioGPUFenceRequest: Sendable, Hashable {
  public let contextID: UInt32
  public let ringIndex: UInt32
  public let fenceID: UInt64
  public let contextFence: Bool

  public init(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) {
    self.contextID = contextID
    self.ringIndex = ringIndex
    self.fenceID = fenceID
    self.contextFence = contextFence
  }
}

public enum DoryVirtioGPUFenceCompletion: Sendable, Equatable {
  case signaled
  case rejected
  case outcomeUnknown
}

public struct DoryVirtioGPUAcceleratedScanoutFlush: Sendable, Hashable {
  public let scanoutID: UInt32
  public let resourceID: UInt32
  public let blobIdentity: DoryVirtioGPUBlobIdentity?
  public let sourceRectangle: DoryVirtioGPURectangle
  public let damagedRectangle: DoryVirtioGPURectangle
  public let resourceWidth: UInt32
  public let resourceHeight: UInt32
  public let virglFormat: UInt32
  public let stride: UInt32
  public let storageOffset: UInt64

  public init(
    scanoutID: UInt32,
    resourceID: UInt32,
    sourceRectangle: DoryVirtioGPURectangle,
    damagedRectangle: DoryVirtioGPURectangle,
    resourceWidth: UInt32,
    resourceHeight: UInt32,
    virglFormat: UInt32,
    stride: UInt32,
    storageOffset: UInt64,
    blobIdentity: DoryVirtioGPUBlobIdentity? = nil
  ) {
    self.scanoutID = scanoutID
    self.resourceID = resourceID
    self.blobIdentity = blobIdentity
    self.sourceRectangle = sourceRectangle
    self.damagedRectangle = damagedRectangle
    self.resourceWidth = resourceWidth
    self.resourceHeight = resourceHeight
    self.virglFormat = virglFormat
    self.stride = stride
    self.storageOffset = storageOffset
  }
}

public enum DoryVirtioGPUAccelerationError: Error, Sendable, Equatable {
  case unsupportedOperation
  case invalidBlobMapping
  /// A per-VM renderer quota was reached before a new resource or fence was admitted.
  case resourceLimitExceeded
  /// The renderer authority has revoked the worker generation; the guest-visible device must
  /// retire all local aliases and resources before processing another accelerated command.
  case generationRevoked
}

extension DoryVirtioGPUAccelerationAuthority {
  public var acceptsGuestCommands: Bool { true }

  public func createContext(id: UInt32, capsetID: UInt32, name: String) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func destroyContext(id: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func submit3D(contextID: UInt32, command: [UInt8]) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func submit3D(
    contextID: UInt32,
    command: [UInt8],
    fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func createFence(
    _ fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func createResource3D(_ resource: DoryVirtioGPUResource3D) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func detachBacking(resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func flushResource(_ scanouts: [DoryVirtioGPUAcceleratedScanoutFlush]) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func unrefResource(resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func unrefBlobResource(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func createBlob(
    _ resource: DoryVirtioGPUBlobResource,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioGPUBlobIdentity {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func mapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    hostVisibleOffset: UInt64
  ) throws -> DoryVirtioGPUBlobMapping {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func unmapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    beforeRendererUnmap: @escaping @Sendable () -> Bool
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func flushBlobResource(_ scanouts: [DoryVirtioGPUBlobScanoutFlush]) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }
}
