import Foundation

public enum DoryVirtioGPUFormat: UInt32, Sendable, Hashable {
  case b8g8r8a8UNorm = 1
  case b8g8r8x8UNorm = 2
  case a8r8g8b8UNorm = 3
  case x8r8g8b8UNorm = 4
  case r8g8b8a8UNorm = 67
  case x8b8g8r8UNorm = 68
  case a8b8g8r8UNorm = 121
  case r8g8b8x8UNorm = 134

  public var bytesPerPixel: Int { 4 }
}

public struct DoryVirtioGPURectangle: Sendable, Hashable {
  public let x: UInt32
  public let y: UInt32
  public let width: UInt32
  public let height: UInt32

  public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct DoryVirtioGPUScanout: Sendable, Hashable {
  public let id: UInt32
  public let rectangle: DoryVirtioGPURectangle
  public let enabled: Bool
  public let physicalWidthMillimeters: UInt16
  public let physicalHeightMillimeters: UInt16

  public init(
    id: UInt32,
    rectangle: DoryVirtioGPURectangle,
    enabled: Bool = true,
    physicalWidthMillimeters: UInt16? = nil,
    physicalHeightMillimeters: UInt16? = nil
  ) {
    self.id = id
    self.rectangle = rectangle
    self.enabled = enabled
    self.physicalWidthMillimeters = physicalWidthMillimeters
      ?? Self.fallbackPhysicalMillimeters(pixels: rectangle.width)
    self.physicalHeightMillimeters = physicalHeightMillimeters
      ?? Self.fallbackPhysicalMillimeters(pixels: rectangle.height)
  }

  public var displayMode: DoryVirtioGPUDisplayMode {
    .init(
      width: rectangle.width,
      height: rectangle.height,
      physicalWidthMillimeters: physicalWidthMillimeters,
      physicalHeightMillimeters: physicalHeightMillimeters
    )
  }

  private static func fallbackPhysicalMillimeters(pixels: UInt32) -> UInt16 {
    UInt16(clamping: max(1, Int((Double(pixels) * 25.4 / 160).rounded())))
  }
}

public struct DoryVirtioGPUDisplayMode: Sendable, Hashable {
  public let width: UInt32
  public let height: UInt32
  public let physicalWidthMillimeters: UInt16
  public let physicalHeightMillimeters: UInt16

  public init(
    width: UInt32,
    height: UInt32,
    physicalWidthMillimeters: UInt16,
    physicalHeightMillimeters: UInt16
  ) {
    self.width = width
    self.height = height
    self.physicalWidthMillimeters = physicalWidthMillimeters
    self.physicalHeightMillimeters = physicalHeightMillimeters
  }
}

public struct DoryVirtioGPUFrame: Sendable, Hashable {
  public let scanoutID: UInt32
  public let resourceID: UInt32
  public let resourceGeneration: UInt64
  public let scanoutRectangle: DoryVirtioGPURectangle
  public let damagedRectangle: DoryVirtioGPURectangle
  public let resourceWidth: UInt32
  public let resourceHeight: UInt32
  public let format: DoryVirtioGPUFormat
  public let pixels: [UInt8]

  public init(
    scanoutID: UInt32,
    resourceID: UInt32,
    resourceGeneration: UInt64,
    scanoutRectangle: DoryVirtioGPURectangle,
    damagedRectangle: DoryVirtioGPURectangle,
    resourceWidth: UInt32,
    resourceHeight: UInt32,
    format: DoryVirtioGPUFormat,
    pixels: [UInt8]
  ) {
    self.scanoutID = scanoutID
    self.resourceID = resourceID
    self.resourceGeneration = resourceGeneration
    self.scanoutRectangle = scanoutRectangle
    self.damagedRectangle = damagedRectangle
    self.resourceWidth = resourceWidth
    self.resourceHeight = resourceHeight
    self.format = format
    self.pixels = pixels
  }
}

public struct DoryVirtioGPUCursorUpdate: Sendable, Hashable {
  public let scanoutID: UInt32
  public let resourceID: UInt32
  public let x: UInt32
  public let y: UInt32
  public let hotX: UInt32
  public let hotY: UInt32
  public let bytes: [UInt8]

  public init(
    scanoutID: UInt32,
    resourceID: UInt32,
    x: UInt32,
    y: UInt32,
    hotX: UInt32,
    hotY: UInt32,
    bytes: [UInt8]
  ) {
    self.scanoutID = scanoutID
    self.resourceID = resourceID
    self.x = x
    self.y = y
    self.hotX = hotX
    self.hotY = hotY
    self.bytes = bytes
  }

  public static func hidden(scanoutID: UInt32) -> Self {
    .init(scanoutID: scanoutID, resourceID: 0, x: 0, y: 0, hotX: 0, hotY: 0, bytes: [])
  }
}

public struct DoryVirtioGPUCapset: Sendable, Hashable {
  public let id: UInt32
  public let maximumVersion: UInt32
  public let data: [UInt8]

  public init(id: UInt32, maximumVersion: UInt32, data: [UInt8]) {
    self.id = id
    self.maximumVersion = maximumVersion
    self.data = data
  }
}

public struct DoryVirtioGPUAccelerationCapabilities: Sendable, Hashable {
  public static let maximumCapsetBytes = 1 * 1024 * 1024

  public let features: DoryVirtioFeatures
  public let capsets: [DoryVirtioGPUCapset]

  public init(features: DoryVirtioFeatures, capsets: [DoryVirtioGPUCapset]) throws {
    let allowedFeatures: DoryVirtioFeatures = [
      .gpuVirgl, .gpuResourceUUID, .gpuResourceBlob, .gpuContextInit,
    ]
    guard !capsets.isEmpty,
      capsets.count <= 16,
      Set(capsets.map(\.id)).count == capsets.count,
      capsets.allSatisfy({ $0.id != 0 && !$0.data.isEmpty }),
      capsets.reduce(UInt64(0), { $0 + UInt64($1.data.count) }) <= UInt64(Self.maximumCapsetBytes),
      allowedFeatures.isSuperset(of: features),
      features.contains(.gpuVirgl)
    else { throw DoryVirtioGPUError.invalidAccelerationCapabilities }
    self.features = features
    self.capsets = capsets
  }
}

/// Generation-scoped renderer authority. Capability discovery is intentionally inseparable from
/// the authority that will execute accelerated commands; a software-only device never advertises
/// renderer features merely because renderer libraries happen to exist on the host.
public protocol DoryVirtioGPUAccelerationAuthority: AnyObject, Sendable {
  var capabilities: DoryVirtioGPUAccelerationCapabilities { get }
  var acceptsGuestCommands: Bool { get }
  func reset()
  func createContext(id: UInt32, capsetID: UInt32, name: String) throws
  func destroyContext(id: UInt32) throws
  func attachResource(contextID: UInt32, resourceID: UInt32) throws
  func detachResource(contextID: UInt32, resourceID: UInt32) throws
  func submit3D(contextID: UInt32, command: [UInt8]) throws
  func submit3D(
    contextID: UInt32,
    command: [UInt8],
    fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws
  func createFence(
    _ fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws
  func createResource3D(_ resource: DoryVirtioGPUResource3D) throws
  func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws
  func detachBacking(resourceID: UInt32) throws
  func attachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws
  func detachBlobBacking(resourceID: UInt32, identity: DoryVirtioGPUBlobIdentity) throws
  func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws
  func flushResource(_ scanouts: [DoryVirtioGPUAcceleratedScanoutFlush]) throws
  func unrefResource(resourceID: UInt32) throws
  func unrefBlobResource(resourceID: UInt32, identity: DoryVirtioGPUBlobIdentity) throws
  func createBlob(
    _ resource: DoryVirtioGPUBlobResource,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioGPUBlobIdentity
  func mapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    hostVisibleOffset: UInt64
  ) throws -> DoryVirtioGPUBlobMapping
  func unmapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    beforeRendererUnmap: @escaping @Sendable () -> Bool
  ) throws
  func flushBlobResource(_ scanouts: [DoryVirtioGPUBlobScanoutFlush]) throws
}

extension DoryVirtioGPUAccelerationAuthority {
  /// A blob command must not fall back to the ID-only 3D backing path. Authorities without an
  /// identity-aware implementation reject it rather than risking mutation after reset/ID reuse.
  public func attachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    throw DoryVirtioGPUAccelerationError.invalidBlobMapping
  }

  public func detachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    throw DoryVirtioGPUAccelerationError.invalidBlobMapping
  }
}

extension DoryVirtioFeatures {
  public static let gpuVirgl = Self(rawValue: 1 << 0)
  public static let gpuEDID = Self(rawValue: 1 << 1)
  public static let gpuResourceUUID = Self(rawValue: 1 << 2)
  public static let gpuResourceBlob = Self(rawValue: 1 << 3)
  public static let gpuContextInit = Self(rawValue: 1 << 4)
}

public protocol DoryVirtioGPUDisplaySink: AnyObject, Sendable {
  func present(_ frame: DoryVirtioGPUFrame)
  func presentCursor(_ update: DoryVirtioGPUCursorUpdate)
  func retireResource(resourceID: UInt32, resourceGeneration: UInt64)
}

extension DoryVirtioGPUDisplaySink {
  public func presentCursor(_ update: DoryVirtioGPUCursorUpdate) {}
  public func retireResource(resourceID: UInt32, resourceGeneration: UInt64) {}
}

public enum DoryVirtioGPUError: Error, Sendable, Equatable {
  case invalidScanoutCount(Int)
  case invalidDimensions(width: UInt32, height: UInt32)
  case invalidPhysicalDimensions(widthMillimeters: UInt16, heightMillimeters: UInt16)
  case invalidGuestMemoryResponse(expected: Int, actual: Int)
  case malformedRequest
  case invalidDescriptorDirection
  case requestTooLarge(UInt64)
  case guestAddressOverflow
  case invalidAccelerationCapabilities
}

public struct DoryVirtioGPUCommandRecord: Sendable, Hashable {
  public let sequenceNumber: UInt64
  public let queue: UInt16
  public let requestType: UInt32
  public let requestByteCount: Int
  public let responseType: UInt32?
  public let responseByteCount: Int?

  public init(
    sequenceNumber: UInt64,
    queue: UInt16,
    requestType: UInt32,
    requestByteCount: Int,
    responseType: UInt32?,
    responseByteCount: Int?
  ) {
    self.sequenceNumber = sequenceNumber
    self.queue = queue
    self.requestType = requestType
    self.requestByteCount = requestByteCount
    self.responseType = responseType
    self.responseByteCount = responseByteCount
  }
}

public struct DoryVirtioGPUCommandDiagnostics: Sendable, Hashable {
  public let completedCommandCount: UInt64
  public let failedCommandCount: UInt64
  public let resetCount: UInt64
  public let recentCommands: [DoryVirtioGPUCommandRecord]

  public init(
    completedCommandCount: UInt64,
    failedCommandCount: UInt64,
    resetCount: UInt64,
    recentCommands: [DoryVirtioGPUCommandRecord]
  ) {
    self.completedCommandCount = completedCommandCount
    self.failedCommandCount = failedCommandCount
    self.resetCount = resetCount
    self.recentCommands = recentCommands
  }
}

/// Transport-neutral VirtIO GPU 2D device. The core deliberately exposes only bounded software
/// resources; Metal presentation and PCI/MMIO transport live outside this module.
public final class DoryVirtioGPUDevice: @unchecked Sendable {
  public static let controlQueue: UInt16 = 0
  public static let cursorQueue: UInt16 = 1
  private static let maximumDiagnosticCommands = 64

  private enum Command: UInt32 {
    case getDisplayInfo = 0x0100
    case resourceCreate2D = 0x0101
    case resourceUnref = 0x0102
    case setScanout = 0x0103
    case resourceFlush = 0x0104
    case transferToHost2D = 0x0105
    case resourceAttachBacking = 0x0106
    case resourceDetachBacking = 0x0107
    case getCapsetInfo = 0x0108
    case getCapset = 0x0109
    case getEDID = 0x010A
    case resourceAssignUUID = 0x010B
    case resourceCreateBlob = 0x010C
    case setScanoutBlob = 0x010D
    case contextCreate = 0x0200
    case contextDestroy = 0x0201
    case contextAttachResource = 0x0202
    case contextDetachResource = 0x0203
    case resourceCreate3D = 0x0204
    case transferToHost3D = 0x0205
    case transferFromHost3D = 0x0206
    case submit3D = 0x0207
    case resourceMapBlob = 0x0208
    case resourceUnmapBlob = 0x0209
    case updateCursor = 0x0300
    case moveCursor = 0x0301
  }

  private enum Response: UInt32 {
    case okNoData = 0x1100
    case okDisplayInfo = 0x1101
    case okCapsetInfo = 0x1102
    case okCapset = 0x1103
    case okEDID = 0x1104
    case okResourceUUID = 0x1105
    case okMapInfo = 0x1106
    case errorUnspecified = 0x1200
    case errorOutOfMemory = 0x1201
    case errorInvalidScanout = 0x1202
    case errorInvalidResource = 0x1203
    case errorInvalidParameter = 0x1205
  }

  private struct Header {
    static let fenceFlag: UInt32 = 1
    static let infoRingIndexFlag: UInt32 = 2

    let flags: UInt32
    let fenceID: UInt64
    let contextID: UInt32
    let ringIndex: UInt8

    var hasFence: Bool { flags & Self.fenceFlag != 0 }
    var hasInfoRingIndex: Bool { flags & Self.infoRingIndexFlag != 0 }
  }

  private enum FenceHeaderAdmission {
    case none
    case invalid
    case admitted(DoryVirtioGPUFenceRequest)
  }

  private enum DeferredExecutionResult {
    case immediate([UInt8])
    case deferred
  }

  private struct Resource {
    let generation: UInt64
    let id: UInt32
    let format: DoryVirtioGPUFormat
    let width: UInt32
    let height: UInt32
    var backing: [DoryVirtioGPUBackingEntry] = []
    var pixels: [UInt8]
  }

  private struct RendererResource {
    let generation = UUID()
    let descriptor: DoryVirtioGPUResource3D
    var backing: [DoryVirtioGPUBackingEntry] = []
    var latestTransfer: DoryVirtioGPUTransfer3D?
  }

  private struct BlobResource {
    let descriptor: DoryVirtioGPUBlobResource
    let identity: DoryVirtioGPUBlobIdentity
    var entries: [DoryVirtioGPUBackingEntry]
    var mapping: DoryVirtioGPUBlobMapping?
  }

  private final class BlobUnmapAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false

    var localTeardownStarted: Bool { lock.withLock { invoked } }

    func retireLocalAlias(_ operation: () -> Bool) -> Bool {
      lock.withLock { invoked = true }
      return operation()
    }
  }

  private func reserveResourceCreate(
    _ id: UInt32, contextID: UInt32 = 0, blobBytes: UInt64 = 0
  ) -> CreationAdmission {
    lock.withLock {
      guard !isResetting else { return .rejected(.errorInvalidParameter) }
      guard contextID == 0 || rendererContexts.contains(contextID) else {
        return .rejected(.errorInvalidParameter)
      }
      guard resources[id] == nil, rendererResources[id] == nil,
        blobResources[id] == nil, pendingResourceCreates[id] == nil
      else { return .rejected(.errorInvalidResource) }
      guard resources.count + rendererResources.count + blobResources.count
        + pendingResourceCreates.count < maximumGPUResourceCount
      else { return .rejected(.errorOutOfMemory) }
      guard retainedBlobBytes <= maximumBlobResourceBytes,
        pendingBlobBytes <= maximumBlobResourceBytes - retainedBlobBytes,
        blobBytes <= maximumBlobResourceBytes - retainedBlobBytes - pendingBlobBytes
      else { return .rejected(.errorOutOfMemory) }
      let token = UUID()
      pendingResourceCreates[id] = token
      if blobBytes > 0 {
        pendingBlobResourceBytes[id] = blobBytes
        pendingBlobBytes += blobBytes
      }
      return .admitted(token: token, resetCount: resetCount)
    }
  }

  private func finishResourceCreate(_ id: UInt32, token: UUID) {
    lock.withLock { releaseResourceCreateReservationLocked(id, token: token) }
  }

  private func releaseResourceCreateReservationLocked(_ id: UInt32, token: UUID) {
    guard pendingResourceCreates[id] == token else { return }
    pendingResourceCreates.removeValue(forKey: id)
    if let bytes = pendingBlobResourceBytes.removeValue(forKey: id) {
      pendingBlobBytes -= bytes
    }
  }

  private func reserveContextCreate(_ id: UInt32) -> CreationAdmission {
    lock.withLock {
      guard !isResetting else { return .rejected(.errorInvalidParameter) }
      guard !rendererContexts.contains(id), pendingContextCreates[id] == nil else {
        return .rejected(.errorInvalidParameter)
      }
      guard rendererContexts.count + pendingContextCreates.count < maximumRendererContextCount
      else { return .rejected(.errorOutOfMemory) }
      let token = UUID()
      pendingContextCreates[id] = token
      return .admitted(token: token, resetCount: resetCount)
    }
  }

  private func finishContextCreate(_ id: UInt32, token: UUID) {
    lock.withLock {
      if pendingContextCreates[id] == token { pendingContextCreates.removeValue(forKey: id) }
    }
  }

  private func reserveContextMutation(_ id: UInt32) -> (token: UUID, resetCount: UInt64)? {
    lock.withLock {
      guard !isResetting, rendererContexts.contains(id), pendingContextMutations[id] == nil,
        pendingContextUses[id]?.isEmpty ?? true
      else { return nil }
      let token = UUID()
      pendingContextMutations[id] = token
      return (token, resetCount)
    }
  }

  private func finishContextMutation(_ id: UInt32, token: UUID) {
    lock.withLock {
      if pendingContextMutations[id] == token {
        pendingContextMutations.removeValue(forKey: id)
      }
    }
  }

  private func reserveContextUse(_ id: UInt32) -> (token: UUID, resetCount: UInt64)? {
    lock.withLock {
      guard !isResetting, rendererContexts.contains(id), pendingContextMutations[id] == nil
      else { return nil }
      let token = UUID()
      pendingContextUses[id, default: []].insert(token)
      return (token, resetCount)
    }
  }

  @discardableResult
  private func finishContextUse(
    _ id: UInt32, token: UUID, admittedResetCount: UInt64
  ) -> Bool {
    lock.withLock {
      guard pendingContextUses[id]?.remove(token) != nil else { return false }
      if pendingContextUses[id]?.isEmpty == true { pendingContextUses.removeValue(forKey: id) }
      return !isResetting && resetCount == admittedResetCount && rendererContexts.contains(id)
    }
  }

  private struct BlobScanoutBinding {
    let resourceID: UInt32
    let identity: DoryVirtioGPUBlobIdentity
    let rectangle: DoryVirtioGPURectangle
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let stride: UInt32
    let offset: UInt32
  }

  private struct ScanoutBinding {
    let resourceID: UInt32
    let rectangle: DoryVirtioGPURectangle
  }

  public let maximumResourceBytes: UInt64
  public let maximumSoftwareResourceBytes: UInt64
  public let maximumBackingEntries: Int
  public let maximumGPUResourceCount: Int
  public let maximumRendererContextCount: Int
  public let maximumBlobResourceBytes: UInt64

  private static let hardMaximumGPUResourceCount = 65_536
  private static let hardMaximumRendererContextCount = 4_096
  private static let hardMaximumBlobResourceBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

  private enum CreationAdmission {
    case admitted(token: UUID, resetCount: UInt64)
    case rejected(Response)
  }

  private let lock = NSCondition()
  private let scanoutCount: Int
  private let edidFeatureAvailable: Bool
  private var scanoutState: [DoryVirtioGPUScanout]
  private var pendingDisplayEvents: UInt32 = 0
  private weak var displaySink: (any DoryVirtioGPUDisplaySink)?
  private let accelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)?
  private let hostVisibleAperture: (any DoryVirtioGPUHostVisibleAperture)?
  private var resources: [UInt32: Resource] = [:]
  private var softwareResourceBytes: UInt64 = 0
  // Never reset this counter: an old frame or transfer may finish after the guest reuses an ID.
  private var nextSoftwareResourceGeneration: UInt64 = 1
  private var rendererResources: [UInt32: RendererResource] = [:]
  private var blobResources: [UInt32: BlobResource] = [:]
  private var retainedBlobBytes: UInt64 = 0
  private var pendingBlobBytes: UInt64 = 0
  private var pendingBlobResourceBytes: [UInt32: UInt64] = [:]
  /// Count in-flight worker creates before calling out, so concurrent commands cannot bypass
  /// the semantic device's resource/context quotas while the renderer is still responding.
  private var pendingResourceCreates: [UInt32: UUID] = [:]
  private var pendingContextCreates: [UInt32: UUID] = [:]
  private var pendingContextMutations: [UInt32: UUID] = [:]
  private var pendingContextUses: [UInt32: Set<UUID>] = [:]
  /// A worker map/unmap/unref must finish before another command can mutate the same blob.
  /// Tokens keep a late pre-reset completion from clearing a newer operation's reservation.
  private var pendingBlobOperations: [UInt32: UUID] = [:]
  private var rendererContexts: Set<UInt32> = []
  private var resourceUUIDs: [UInt32: [UInt8]] = [:]
  private var bindings: [UInt32: ScanoutBinding] = [:]
  private var blobBindings: [UInt32: BlobScanoutBinding] = [:]
  private var cursors: [UInt32: DoryVirtioGPUCursorUpdate] = [:]
  private var completedCommandCount: UInt64 = 0
  private var failedCommandCount: UInt64 = 0
  private var resetCount: UInt64 = 0
  private var isResetting = false
  private var resetOwnerThread: Thread?
  private var recentCommands: [DoryVirtioGPUCommandRecord] = []

  public init(
    scanouts: [DoryVirtioGPUScanout],
    maximumResourceBytes: UInt64 = 256 * 1024 * 1024,
    maximumSoftwareResourceBytes: UInt64 = 1024 * 1024 * 1024,
    maximumBackingEntries: Int = 65_536,
    maximumGPUResourceCount: Int = 65_536,
    maximumRendererContextCount: Int = 4_096,
    maximumBlobResourceBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
    displaySink: (any DoryVirtioGPUDisplaySink)? = nil,
    accelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)? = nil,
    hostVisibleAperture: (any DoryVirtioGPUHostVisibleAperture)? = nil
  ) throws {
    guard (1...16).contains(scanouts.count),
      Set(scanouts.map(\.id)).count == scanouts.count,
      scanouts.enumerated().allSatisfy({ UInt32($0.offset) == $0.element.id })
    else { throw DoryVirtioGPUError.invalidScanoutCount(scanouts.count) }
    if let invalid = scanouts.first(where: { !Self.valid($0.rectangle) })?.rectangle {
      throw DoryVirtioGPUError.invalidDimensions(
        width: invalid.width,
        height: invalid.height
      )
    }
    if let invalid = scanouts.first(where: {
      !(1...4_095).contains($0.physicalWidthMillimeters)
        || !(1...4_095).contains($0.physicalHeightMillimeters)
    }) {
      throw DoryVirtioGPUError.invalidPhysicalDimensions(
        widthMillimeters: invalid.physicalWidthMillimeters,
        heightMillimeters: invalid.physicalHeightMillimeters
      )
    }
    scanoutCount = scanouts.count
    edidFeatureAvailable = scanouts.contains(where: \.enabled)
    scanoutState = scanouts
    self.maximumResourceBytes = max(4, maximumResourceBytes)
    self.maximumSoftwareResourceBytes = max(4, maximumSoftwareResourceBytes)
    self.maximumBackingEntries = max(1, maximumBackingEntries)
    self.maximumGPUResourceCount = max(1, min(maximumGPUResourceCount, Self.hardMaximumGPUResourceCount))
    self.maximumRendererContextCount = max(
      1, min(maximumRendererContextCount, Self.hardMaximumRendererContextCount))
    self.maximumBlobResourceBytes = max(
      1, min(maximumBlobResourceBytes, Self.hardMaximumBlobResourceBytes))
    self.displaySink = displaySink
    self.accelerationAuthority = accelerationAuthority
    self.hostVisibleAperture = hostVisibleAperture
    if accelerationAuthority?.capabilities.features.contains(.gpuResourceBlob) == true {
      guard hostVisibleAperture != nil else {
        throw DoryVirtioGPUError.invalidAccelerationCapabilities
      }
    } else if hostVisibleAperture != nil {
      throw DoryVirtioGPUError.invalidAccelerationCapabilities
    }
  }

  public var offeredFeatures: DoryVirtioFeatures {
    let displayFeatures: DoryVirtioFeatures = edidFeatureAvailable ? [.gpuEDID] : []
    return displayFeatures.union(accelerationAuthority?.capabilities.features ?? [])
  }

  /// A replacement worker may arrive after the guest has negotiated fresh queues. Keep those
  /// descriptors unconsumed until its authority is active; capability discovery stays immutable.
  public var acceptsGuestCommands: Bool {
    lock.withLock { !isResetting } && (accelerationAuthority?.acceptsGuestCommands ?? true)
  }

  /// `events_read`, `events_clear`, `num_scanouts`, `num_capsets`.
  public var configuration: [UInt8] {
    let display = lock.withLock { (pendingDisplayEvents, scanoutCount) }
    return littleEndian(display.0) + littleEndian(UInt32(0))
      + littleEndian(UInt32(display.1))
      + littleEndian(UInt32(accelerationAuthority?.capabilities.capsets.count ?? 0))
  }

  public var scanouts: [DoryVirtioGPUScanout] { lock.withLock { scanoutState } }

  /// Bounded command history retained across device resets so a failed firmware or guest driver
  /// initialization can be diagnosed after it has returned the transport to reset state.
  public var commandDiagnostics: DoryVirtioGPUCommandDiagnostics {
    lock.withLock {
      .init(
        completedCommandCount: completedCommandCount,
        failedCommandCount: failedCommandCount,
        resetCount: resetCount,
        recentCommands: recentCommands
      )
    }
  }

  /// Publishes a new preferred mode. The PCI wrapper refreshes device configuration and raises the
  /// standard VIRTIO_GPU_EVENT_DISPLAY configuration interrupt when this returns true.
  @discardableResult
  public func updateScanoutSize(
    scanoutID: UInt32,
    width: UInt32,
    height: UInt32,
    physicalWidthMillimeters: UInt16? = nil,
    physicalHeightMillimeters: UInt16? = nil
  ) -> Bool {
    guard Self.valid(.init(x: 0, y: 0, width: width, height: height)) else { return false }
    return lock.withLock {
      let index = Int(scanoutID)
      guard scanoutState.indices.contains(index) else { return false }
      let current = scanoutState[index]
      let rectangle = DoryVirtioGPURectangle(
        x: current.rectangle.x,
        y: current.rectangle.y,
        width: width,
        height: height
      )
      let physicalWidth = physicalWidthMillimeters ?? current.physicalWidthMillimeters
      let physicalHeight = physicalHeightMillimeters ?? current.physicalHeightMillimeters
      guard (1...4_095).contains(physicalWidth), (1...4_095).contains(physicalHeight),
        current.rectangle != rectangle
          || current.physicalWidthMillimeters != physicalWidth
          || current.physicalHeightMillimeters != physicalHeight
      else { return false }
      scanoutState[index] = .init(
        id: current.id,
        rectangle: rectangle,
        enabled: current.enabled,
        physicalWidthMillimeters: physicalWidth,
        physicalHeightMillimeters: physicalHeight
      )
      pendingDisplayEvents |= 1
      return true
    }
  }

  /// Enables a contiguous set of connectors within the boot-time capacity. A removed connector
  /// loses its resource and cursor bindings before the guest receives the display-change event.
  @discardableResult
  public func updateScanoutTopology(_ activeModes: [DoryVirtioGPUDisplayMode]) -> Bool {
    guard !activeModes.isEmpty,
      activeModes.count <= scanoutCount,
      activeModes.allSatisfy({
        Self.valid(.init(x: 0, y: 0, width: $0.width, height: $0.height))
          && (1...4_095).contains($0.physicalWidthMillimeters)
          && (1...4_095).contains($0.physicalHeightMillimeters)
      })
    else { return false }
    let change = lock.withLock {
      () -> (disabled: [UInt32], sink: (any DoryVirtioGPUDisplaySink)?)? in
      var updated = scanoutState
      var disabled: [UInt32] = []
      for index in updated.indices {
        let current = updated[index]
        let enabled = index < activeModes.count
        let mode = enabled ? activeModes[index] : current.displayMode
        let rectangle = DoryVirtioGPURectangle(
          x: current.rectangle.x,
          y: current.rectangle.y,
          width: mode.width,
          height: mode.height
        )
        updated[index] = .init(
          id: current.id,
          rectangle: rectangle,
          enabled: enabled,
          physicalWidthMillimeters: mode.physicalWidthMillimeters,
          physicalHeightMillimeters: mode.physicalHeightMillimeters
        )
        if current.enabled && !enabled {
          disabled.append(current.id)
          bindings.removeValue(forKey: current.id)
          blobBindings.removeValue(forKey: current.id)
          cursors.removeValue(forKey: current.id)
        }
      }
      guard updated != scanoutState else { return nil }
      scanoutState = updated
      pendingDisplayEvents |= 1
      return (disabled, displaySink)
    }
    guard let change else { return false }
    for scanoutID in change.disabled {
      change.sink?.presentCursor(.hidden(scanoutID: scanoutID))
    }
    return true
  }

  /// Implements the write-only `events_clear` field in the VirtIO GPU device configuration.
  public func writeConfiguration(offset: Int, bytes: [UInt8]) {
    guard offset < 8, offset + bytes.count > 4 else { return }
    var cleared: UInt32 = 0
    for (index, byte) in bytes.enumerated() {
      let position = offset + index
      guard (4..<8).contains(position) else { continue }
      cleared |= UInt32(byte) << UInt32((position - 4) * 8)
    }
    lock.withLock { pendingDisplayEvents &= ~cleared }
  }

  public func connectDisplaySink(_ sink: (any DoryVirtioGPUDisplaySink)?) {
    lock.withLock { displaySink = sink }
  }

  public func reset() {
    lock.lock()
    while isResetting {
      // A display/renderer callback may synchronously request another reset on this thread.
      // The outer invocation owns its retirement barrier; waiting here would deadlock it.
      if resetOwnerThread === Thread.current {
        lock.unlock()
        return
      }
      lock.wait()
    }
    let hidden: ([UInt32], [(UInt32, UInt64)], (any DoryVirtioGPUDisplaySink)?) = {
      isResetting = true
      resetOwnerThread = Thread.current
      let hidden = Array(cursors.keys)
      let retired = resources.values.map { ($0.id, $0.generation) }
      resetCount &+= 1
      resources.removeAll(keepingCapacity: true)
      softwareResourceBytes = 0
      rendererResources.removeAll(keepingCapacity: true)
      blobResources.removeAll(keepingCapacity: true)
      retainedBlobBytes = 0
      pendingBlobBytes = 0
      pendingBlobResourceBytes.removeAll(keepingCapacity: true)
      pendingResourceCreates.removeAll(keepingCapacity: true)
      pendingContextCreates.removeAll(keepingCapacity: true)
      pendingContextMutations.removeAll(keepingCapacity: true)
      pendingContextUses.removeAll(keepingCapacity: true)
      pendingBlobOperations.removeAll(keepingCapacity: true)
      rendererContexts.removeAll(keepingCapacity: true)
      resourceUUIDs.removeAll(keepingCapacity: true)
      bindings.removeAll(keepingCapacity: true)
      blobBindings.removeAll(keepingCapacity: true)
      cursors.removeAll(keepingCapacity: true)
      pendingDisplayEvents = 0
      return (hidden, retired, displaySink)
    }()
    lock.unlock()
    for scanoutID in hidden.0 {
      hidden.2?.presentCursor(.hidden(scanoutID: scanoutID))
    }
    for (resourceID, generation) in hidden.1 {
      hidden.2?.retireResource(resourceID: resourceID, resourceGeneration: generation)
    }
    hostVisibleAperture?.reset()
    accelerationAuthority?.reset()
    lock.lock()
    isResetting = false
    resetOwnerThread = nil
    lock.broadcast()
    lock.unlock()
  }

  public func process(
    queue: UInt16,
    chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard queue == Self.controlQueue || queue == Self.cursorQueue else {
      throw DoryVirtioGPUError.malformedRequest
    }
    let readable = chain.descriptors.filter { !$0.deviceWillWrite }
    let writable = chain.descriptors.filter(\.deviceWillWrite)
    guard !readable.isEmpty, !writable.isEmpty,
      chain.descriptors.drop(while: { !$0.deviceWillWrite }).allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioGPUError.invalidDescriptorDirection }
    let request = try gather(readable, memory: memory)
    guard request.count >= 24 else { throw DoryVirtioGPUError.malformedRequest }
    let header = Header(
      flags: read32(request, 4),
      fenceID: read64(request, 8),
      contextID: read32(request, 16),
      ringIndex: request[20]
    )
    let requestType = read32(request, 0)
    let command = Command(rawValue: requestType)
    let cursorCommand = command == .updateCursor || command == .moveCursor
    // Preflight every writable response target before command execution so a malformed later
    // descriptor cannot let a command mutate device/renderer state or partially scatter an
    // earlier response before the request fails.
    try validateWritableTargets(writable, memory: memory)
    do {
      let responseBytes: [UInt8]
      if (queue == Self.cursorQueue) != cursorCommand {
        responseBytes = response(.errorInvalidParameter, header: header)
      } else {
        responseBytes = try executeWithRendererEpochGuard(
          command, request: request, header: header, memory: memory)
      }
      guard UInt64(responseBytes.count) <= chain.writableByteCount else {
        throw DoryVirtioGPUError.malformedRequest
      }
      try scatter(responseBytes, into: writable, memory: memory)
      recordCommand(
        queue: queue,
        requestType: requestType,
        requestByteCount: request.count,
        response: responseBytes
      )
      return UInt32(responseBytes.count)
    } catch {
      recordCommand(
        queue: queue,
        requestType: requestType,
        requestByteCount: request.count,
        response: nil
      )
      throw error
    }
  }

  public func processDeferred(
    queue: UInt16,
    chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory,
    completion: @escaping @Sendable ([UInt8]) -> Bool,
    terminalFailure: @escaping @Sendable () -> Bool = { false }
  ) throws {
    guard queue == Self.controlQueue || queue == Self.cursorQueue else {
      throw DoryVirtioGPUError.malformedRequest
    }
    let readable = chain.descriptors.filter { !$0.deviceWillWrite }
    let writable = chain.descriptors.filter(\.deviceWillWrite)
    guard !readable.isEmpty, !writable.isEmpty,
      chain.descriptors.drop(while: { !$0.deviceWillWrite }).allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioGPUError.invalidDescriptorDirection }
    let request = try gather(readable, memory: memory)
    guard request.count >= 24 else { throw DoryVirtioGPUError.malformedRequest }
    let header = Header(
      flags: read32(request, 4),
      fenceID: read64(request, 8),
      contextID: read32(request, 16),
      ringIndex: request[20]
    )
    let requestType = read32(request, 0)
    let command = Command(rawValue: requestType)
    let cursorCommand = command == .updateCursor || command == .moveCursor
    // Preflight writable response targets before scheduling any deferred command side effects
    // so an invalid later descriptor cannot let a deferred completion mutate state or partially
    // scatter a response.
    try validateWritableTargets(writable, memory: memory)
    let publish: @Sendable ([UInt8]) -> Bool = { [weak self] responseBytes in
      guard let self else { return false }
      let published = completion(responseBytes)
      self.recordCommand(
        queue: queue,
        requestType: requestType,
        requestByteCount: request.count,
        response: published ? responseBytes : nil
      )
      return published
    }
    do {
      let result: DeferredExecutionResult
      if (queue == Self.cursorQueue) != cursorCommand {
        result = .immediate(response(.errorInvalidParameter, header: header))
      } else {
        result = try executeDeferred(
          command,
          request: request,
          header: header,
          memory: memory,
          completion: publish,
          terminalFailure: terminalFailure
        )
      }
      if case .immediate(let responseBytes) = result {
        _ = publish(responseBytes)
      }
    } catch {
      recordCommand(
        queue: queue,
        requestType: requestType,
        requestByteCount: request.count,
        response: nil
      )
      throw error
    }
  }

  private func recordCommand(
    queue: UInt16,
    requestType: UInt32,
    requestByteCount: Int,
    response: [UInt8]?
  ) {
    let responseType = response.flatMap { bytes in
      bytes.count >= 4 ? read32(bytes, 0) : nil
    }
    lock.withLock {
      if response == nil {
        failedCommandCount &+= 1
      } else {
        completedCommandCount &+= 1
      }
      let sequenceNumber = completedCommandCount &+ failedCommandCount
      recentCommands.append(
        .init(
          sequenceNumber: sequenceNumber,
          queue: queue,
          requestType: requestType,
          requestByteCount: requestByteCount,
          responseType: responseType,
          responseByteCount: response?.count
        )
      )
      if recentCommands.count > Self.maximumDiagnosticCommands {
        recentCommands.removeFirst(recentCommands.count - Self.maximumDiagnosticCommands)
      }
    }
  }

  private func executeDeferred(
    _ command: Command?,
    request: [UInt8],
    header: Header,
    memory: any DoryVirtioGuestMemory,
    completion: @escaping @Sendable ([UInt8]) -> Bool,
    terminalFailure: @escaping @Sendable () -> Bool
  ) throws -> DeferredExecutionResult {
    let fenceAdmission = admitFence(header)
    if case .invalid = fenceAdmission {
      return .immediate(response(.errorInvalidParameter, header: header))
    }
    guard case .admitted(let fence) = fenceAdmission else {
      return .immediate(try executeWithRendererEpochGuard(
        command, request: request, header: header, memory: memory))
    }
    if command == .submit3D {
      guard request.count >= 32, header.contextID != 0,
        let accelerationAuthority
      else { return .immediate(response(.errorInvalidParameter, header: header)) }
      let byteCount = Int(read32(request, 24))
      guard byteCount > 0, byteCount.isMultiple(of: 4), request.count == 32 + byteCount else {
        return .immediate(response(.errorInvalidParameter, header: header))
      }
      guard let contextAdmission = reserveContextUse(header.contextID) else {
        return .immediate(response(.errorInvalidParameter, header: header))
      }
      let success = response(.okNoData, header: header)
      let failure = response(.errorInvalidParameter, header: header)
      do {
        try accelerationAuthority.submit3D(
          contextID: header.contextID,
          command: Array(request[32...]),
          fence: fence
        ) { disposition in
          let current = self.finishContextUse(
            header.contextID, token: contextAdmission.token,
            admittedResetCount: contextAdmission.resetCount)
          guard current else {
            _ = terminalFailure()
            return
          }
          switch disposition {
          case .signaled:
            _ = completion(success)
          case .rejected:
            _ = completion(failure)
          case .outcomeUnknown:
            _ = terminalFailure()
          }
        }
      } catch DoryVirtioGPUAccelerationError.resourceLimitExceeded {
        finishContextUse(
          header.contextID, token: contextAdmission.token,
          admittedResetCount: contextAdmission.resetCount)
        return .immediate(response(.errorOutOfMemory, header: header))
      } catch {
        finishContextUse(
          header.contextID, token: contextAdmission.token,
          admittedResetCount: contextAdmission.resetCount)
        return .immediate(failure)
      }
      return .deferred
    }
    let usesRenderer = commandUsesAcceleratedRenderer(command, request: request)
    let responseBytes = try executeWithRendererEpochGuard(
      command, request: request, header: header, memory: memory,
      usesRenderer: usesRenderer)
    guard usesRenderer, successful(responseBytes), let accelerationAuthority else {
      return .immediate(responseBytes)
    }
    let failure = response(.errorInvalidParameter, header: header)
    do {
      try accelerationAuthority.createFence(fence) { disposition in
        switch disposition {
        case .signaled:
          _ = completion(responseBytes)
        case .rejected:
          _ = completion(failure)
        case .outcomeUnknown:
          _ = terminalFailure()
        }
      }
    } catch {
      _ = terminalFailure()
      return .deferred
    }
    return .deferred
  }

  private func admitFence(_ header: Header) -> FenceHeaderAdmission {
    guard header.flags & ~(Header.fenceFlag | Header.infoRingIndexFlag) == 0 else {
      return .invalid
    }
    let hasFence = header.hasFence
    let hasInfoRing = header.hasInfoRingIndex
    if hasInfoRing, UInt32(header.ringIndex) > 63 { return .invalid }
    if !hasFence {
      return header.fenceID == 0 && (hasInfoRing || header.ringIndex == 0) ? .none : .invalid
    }
    if hasInfoRing {
      guard header.contextID != 0 else { return .invalid }
      return .admitted(
        .init(
          contextID: header.contextID,
          ringIndex: UInt32(header.ringIndex),
          fenceID: header.fenceID,
          contextFence: true
        ))
    }
    guard header.ringIndex == 0 else { return .invalid }
    return .admitted(
      .init(
        contextID: 0,
        ringIndex: 0,
        fenceID: header.fenceID,
        contextFence: false
      ))
  }

  private func successful(_ responseBytes: [UInt8]) -> Bool {
    responseBytes.count >= 4 && read32(responseBytes, 0) & 0xFF00 == 0x1100
  }

  private func executeWithRendererEpochGuard(
    _ command: Command?,
    request: [UInt8],
    header: Header,
    memory: any DoryVirtioGuestMemory,
    usesRenderer: Bool? = nil
  ) throws -> [UInt8] {
    let accelerated = usesRenderer ?? commandUsesAcceleratedRenderer(command, request: request)
    let admittedResetCount = lock.withLock { resetCount }
    let result = try execute(command, request: request, header: header, memory: memory)
    guard accelerated, successful(result),
      lock.withLock({ isResetting || resetCount != admittedResetCount })
    else { return result }
    // A command that crossed the worker while reset was in flight may have committed local
    // context/resource state after reset cleared it. Revoke rather than publish stale success.
    reset()
    return response(.errorInvalidParameter, header: header)
  }

  private func commandUsesAcceleratedRenderer(_ command: Command?, request: [UInt8]) -> Bool {
    guard let command else { return false }
    switch command {
    case .contextCreate, .contextDestroy, .contextAttachResource, .contextDetachResource,
      .resourceCreate3D, .resourceCreateBlob, .resourceMapBlob, .resourceUnmapBlob,
      .setScanoutBlob, .transferToHost3D, .transferFromHost3D, .submit3D:
      return true
    case .resourceAttachBacking, .resourceDetachBacking, .resourceUnref:
      guard request.count >= 28 else { return false }
      let resourceID = read32(request, 24)
      return lock.withLock {
        rendererResources[resourceID] != nil || blobResources[resourceID] != nil
      }
    case .resourceFlush:
      guard request.count >= 44 else { return false }
      let resourceID = read32(request, 40)
      return lock.withLock {
        rendererResources[resourceID] != nil || blobResources[resourceID] != nil
      }
    default:
      return false
    }
  }

  private func execute(
    _ command: Command?,
    request: [UInt8],
    header: Header,
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    guard let command else { return response(.errorUnspecified, header: header) }
    if lock.withLock({ isResetting }), commandUsesAcceleratedRenderer(command, request: request) {
      return response(.errorInvalidParameter, header: header)
    }
    switch command {
    case .getDisplayInfo:
      guard request.count == 24 else { return response(.errorInvalidParameter, header: header) }
      let scanouts = lock.withLock { scanoutState }
      var result = response(.okDisplayInfo, header: header)
      for index in 0..<16 {
        if index < scanouts.count {
          let scanout = scanouts[index]
          result += rectangleBytes(scanout.rectangle)
          result += littleEndian(UInt32(scanout.enabled ? 1 : 0))
          result += littleEndian(UInt32(0))
        } else {
          result += [UInt8](repeating: 0, count: 24)
        }
      }
      return result

    case .getEDID:
      guard request.count == 32, offeredFeatures.contains(.gpuEDID) else {
        return response(.errorInvalidParameter, header: header)
      }
      let scanoutID = read32(request, 24)
      guard let scanout = lock.withLock({
        scanoutState.indices.contains(Int(scanoutID)) ? scanoutState[Int(scanoutID)] : nil
      }) else { return response(.errorInvalidParameter, header: header) }
      let edid = DoryVirtioGPUSyntheticEDID.make(
        scanoutID: scanoutID,
        width: scanout.rectangle.width,
        height: scanout.rectangle.height,
        physicalWidthMillimeters: scanout.physicalWidthMillimeters,
        physicalHeightMillimeters: scanout.physicalHeightMillimeters
      )
      return response(.okEDID, header: header)
        + littleEndian(UInt32(edid.count)) + littleEndian(UInt32(0))
        + edid + [UInt8](repeating: 0, count: 1_024 - edid.count)

    case .getCapsetInfo:
      guard request.count == 32,
        let capabilities = accelerationAuthority?.capabilities
      else { return response(.errorInvalidParameter, header: header) }
      let index = Int(read32(request, 24))
      guard capabilities.capsets.indices.contains(index) else {
        return response(.errorInvalidParameter, header: header)
      }
      let capset = capabilities.capsets[index]
      return response(.okCapsetInfo, header: header)
        + littleEndian(capset.id)
        + littleEndian(capset.maximumVersion)
        + littleEndian(UInt32(capset.data.count))
        + littleEndian(UInt32(0))

    case .getCapset:
      guard request.count == 32,
        let capabilities = accelerationAuthority?.capabilities
      else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let version = read32(request, 28)
      guard let capset = capabilities.capsets.first(where: { $0.id == id }),
        version <= capset.maximumVersion
      else { return response(.errorInvalidParameter, header: header) }
      return response(.okCapset, header: header) + capset.data

    case .resourceAssignUUID:
      guard request.count == 32, offeredFeatures.contains(.gpuResourceUUID) else {
        return response(.errorInvalidParameter, header: header)
      }
      let resourceID = read32(request, 24)
      guard
        lock.withLock({
          resources[resourceID] != nil || rendererResources[resourceID] != nil
            || blobResources[resourceID] != nil
        })
      else { return response(.errorInvalidResource, header: header) }
      let uuid = lock.withLock { () -> [UInt8] in
        if let existing = resourceUUIDs[resourceID] { return existing }
        var value = UUID().uuid
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        resourceUUIDs[resourceID] = bytes
        return bytes
      }
      return response(.okResourceUUID, header: header) + uuid

    case .resourceCreate2D:
      guard request.count == 40 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let format = DoryVirtioGPUFormat(rawValue: read32(request, 28))
      let width = read32(request, 32)
      let height = read32(request, 36)
      guard id != 0, let format, Self.valid(width: width, height: height),
        let byteCount = resourceByteCount(width: width, height: height),
        byteCount <= maximumResourceBytes
      else { return response(.errorInvalidParameter, header: header) }
      let result = lock.withLock { () -> Response in
        guard resources[id] == nil, rendererResources[id] == nil,
          blobResources[id] == nil, pendingResourceCreates[id] == nil
        else { return .errorInvalidResource }
        guard resources.count + rendererResources.count + blobResources.count
            + pendingResourceCreates.count < maximumGPUResourceCount,
          byteCount <= maximumSoftwareResourceBytes,
          softwareResourceBytes <= maximumSoftwareResourceBytes - byteCount,
          nextSoftwareResourceGeneration < UInt64.max
        else { return .errorOutOfMemory }
        resources[id] = Resource(
          generation: nextSoftwareResourceGeneration,
          id: id,
          format: format,
          width: width,
          height: height,
          pixels: [UInt8](repeating: 0, count: Int(byteCount))
        )
        nextSoftwareResourceGeneration += 1
        softwareResourceBytes += byteCount
        return .okNoData
      }
      return response(result, header: header)

    case .resourceUnref:
      guard request.count == 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      // Map, unmap and unref all cross the renderer boundary. An unref must not destroy a blob
      // while a map is still committing (or roll back a newer map for the same numeric ID).
      guard let blobOperationToken = reserveBlobOperation(resourceID: id) else {
        return response(.errorInvalidResource, header: header)
      }
      defer { finishBlobOperation(resourceID: id, token: blobOperationToken) }
      let observed = lock.withLock {
        (
          rendererGeneration: rendererResources[id]?.generation,
          blobResource: blobResources[id],
          softwareGeneration: resources[id]?.generation,
          resetCount: resetCount
        )
      }
      let rendererResource = observed.rendererGeneration != nil
      let blobResource = observed.blobResource
      var unmappedBlob = false
      if let blobResource, blobResource.mapping != nil {
        guard let accelerationAuthority, let hostVisibleAperture else {
          return response(.errorInvalidResource, header: header)
        }
        let unmapAttempt = BlobUnmapAttempt()
        do {
          try accelerationAuthority.unmapBlob(
            resourceID: id,
            identity: blobResource.identity,
            beforeRendererUnmap: {
              unmapAttempt.retireLocalAlias {
                hostVisibleAperture.unmap(
                  resourceID: id,
                  identity: blobResource.identity
                )
              }
            }
          )
          unmappedBlob = true
        } catch {
          if unmapAttempt.localTeardownStarted
            || error as? DoryVirtioGPUAccelerationError == .generationRevoked
          { reset() }
          return response(.errorInvalidParameter, header: header)
        }
      }
      if rendererResource || blobResource != nil {
        let stillOwned = lock.withLock {
          !isResetting && resetCount == observed.resetCount
            && (blobResource == nil || blobResources[id]?.identity == blobResource?.identity)
            && rendererResources[id]?.generation == observed.rendererGeneration
        }
        guard stillOwned else {
          if unmappedBlob || blobResource != nil { reset() }
          return response(.errorInvalidResource, header: header)
        }
        do {
          if let blobResource {
            try accelerationAuthority?.unrefBlobResource(
              resourceID: id, identity: blobResource.identity)
          } else {
            try accelerationAuthority?.unrefResource(resourceID: id)
          }
        } catch {
          if unmappedBlob || blobResource != nil
            || error as? DoryVirtioGPUAccelerationError == .generationRevoked
          { reset() }
          return response(.errorInvalidParameter, header: header)
        }
      }
      let removed = lock.withLock {
        () -> (
          removed: Bool, stale: Bool, cursors: [UInt32],
          softwareGeneration: UInt64?, sink: (any DoryVirtioGPUDisplaySink)?
        ) in
        guard !isResetting, resetCount == observed.resetCount,
          resources[id]?.generation == observed.softwareGeneration,
          blobResource == nil || blobResources[id]?.identity == blobResource?.identity,
          rendererResources[id]?.generation == observed.rendererGeneration
        else { return (false, true, [], nil, nil) }
        let softwareResource = resources.removeValue(forKey: id)
        if let softwareResource {
          softwareResourceBytes -= UInt64(softwareResource.pixels.count)
        }
        let removedRenderer = rendererResources.removeValue(forKey: id)
        let removedBlob = blobResources.removeValue(forKey: id)
        if let removedBlob { retainedBlobBytes -= removedBlob.descriptor.size }
        let removed = softwareResource != nil || removedRenderer != nil || removedBlob != nil
        guard removed else { return (false, false, [], nil, nil) }
        resourceUUIDs.removeValue(forKey: id)
        bindings = bindings.filter { $0.value.resourceID != id }
        blobBindings = blobBindings.filter { $0.value.resourceID != id }
        let retiredCursors = cursors.compactMap { scanoutID, cursor in
          cursor.resourceID == id ? scanoutID : nil
        }
        for scanoutID in retiredCursors { cursors.removeValue(forKey: scanoutID) }
        return (true, false, retiredCursors, softwareResource?.generation, displaySink)
      }
      if removed.stale {
        reset()
        return response(.errorInvalidResource, header: header)
      }
      for scanoutID in removed.cursors {
        removed.sink?.presentCursor(.hidden(scanoutID: scanoutID))
      }
      if let generation = removed.softwareGeneration {
        removed.sink?.retireResource(resourceID: id, resourceGeneration: generation)
      }
      return response(removed.removed ? .okNoData : .errorInvalidResource, header: header)

    case .resourceCreateBlob:
      guard offeredFeatures.contains(.gpuResourceBlob), request.count >= 56,
        let accelerationAuthority, hostVisibleAperture != nil
      else { return response(.errorInvalidParameter, header: header) }
      let resource = DoryVirtioGPUBlobResource(
        resourceID: read32(request, 24),
        contextID: header.contextID,
        blobMemory: read32(request, 28),
        blobFlags: read32(request, 32),
        blobID: read64(request, 40),
        size: read64(request, 48)
      )
      let entryCount = Int(read32(request, 36))
      guard resource.resourceID != 0,
        (1...3).contains(resource.blobMemory),
        resource.blobFlags & ~UInt32(0x7) == 0,
        // Guest-only blobs use a scatterlist rather than a renderer object ID. Linux
        // sends blob_id=0 for them; zero is also the renderer-allocated HOST3D SHM case.
        resource.blobID != 0 || resource.blobMemory == 1
          || (resource.blobMemory == 2 && resource.blobFlags == 1),
        resource.size > 0, resource.size <= maximumResourceBytes,
        entryCount >= 0, entryCount <= maximumBackingEntries,
        request.count == 56 + entryCount * 16
      else { return response(.errorInvalidParameter, header: header) }
      var entries: [DoryVirtioGPUBackingEntry] = []
      entries.reserveCapacity(entryCount)
      var referencedBytes: UInt64 = 0
      for index in 0..<entryCount {
        let entryOffset = 56 + index * 16
        let guestAddress = read64(request, entryOffset)
        let length = read32(request, entryOffset + 8)
        let (addressEnd, addressOverflow) = guestAddress.addingReportingOverflow(UInt64(length))
        let (total, totalOverflow) = referencedBytes.addingReportingOverflow(UInt64(length))
        guard length > 0, !addressOverflow, addressEnd >= guestAddress, !totalOverflow,
          total <= maximumResourceBytes
        else { return response(.errorInvalidParameter, header: header) }
        do {
          try memory.validate(at: guestAddress, byteCount: Int(length), deviceWillWrite: false)
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
        entries.append(.init(guestAddress: guestAddress, length: length))
        referencedBytes = total
      }
      // HOST3D is renderer-owned and cannot import a guest scatterlist. GUEST requires
      // backing at creation; HOST3D_GUEST may begin without a shadow buffer or carry one.
      guard (resource.blobMemory != 2 || entries.isEmpty),
        (resource.blobMemory != 1 || !entries.isEmpty),
        (entries.isEmpty || referencedBytes >= resource.size)
      else { return response(.errorInvalidParameter, header: header) }
      let blobAdmission = reserveResourceCreate(
        resource.resourceID, contextID: header.contextID, blobBytes: resource.size)
      guard case let .admitted(resourceToken, admittedResetCount) = blobAdmission else {
        if case let .rejected(reason) = blobAdmission { return response(reason, header: header) }
        return response(.errorInvalidParameter, header: header)
      }
      defer { finishResourceCreate(resource.resourceID, token: resourceToken) }
      do {
        let identity = try accelerationAuthority.createBlob(
          resource,
          entries: entries,
          memory: memory
        )
        guard identity.workspaceID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
          identity.resourceGeneration != 0, identity.workerGeneration != 0,
          identity.deviceGeneration != 0
        else {
          reset()
          return response(.errorInvalidParameter, header: header)
        }
        let inserted = lock.withLock { () -> Bool in
          guard !isResetting, resetCount == admittedResetCount,
            pendingResourceCreates[resource.resourceID] == resourceToken,
            resources[resource.resourceID] == nil,
            rendererResources[resource.resourceID] == nil,
            blobResources[resource.resourceID] == nil
          else { return false }
          blobResources[resource.resourceID] = .init(
            descriptor: resource,
            identity: identity,
            entries: entries,
            mapping: nil
          )
          releaseResourceCreateReservationLocked(resource.resourceID, token: resourceToken)
          retainedBlobBytes += resource.size
          return true
        }
        guard inserted else {
          // The worker accepted a resource that no longer has a local owner. An ID-only unref
          // could destroy a newer resource after reset/reuse, so revoke this generation.
          reset()
          return response(.errorInvalidResource, header: header)
        }
      } catch DoryVirtioGPUAccelerationError.resourceLimitExceeded {
        return response(.errorOutOfMemory, header: header)
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .resourceMapBlob:
      guard request.count == 40, offeredFeatures.contains(.gpuResourceBlob),
        let accelerationAuthority, let hostVisibleAperture
      else { return response(.errorInvalidParameter, header: header) }
      let resourceID = read32(request, 24)
      let hostVisibleOffset = read64(request, 32)
      guard let operationToken = reserveBlobOperation(resourceID: resourceID) else {
        return response(.errorInvalidResource, header: header)
      }
      defer { finishBlobOperation(resourceID: resourceID, token: operationToken) }
      let observed = lock.withLock { (blobResources[resourceID], resetCount) }
      guard hostVisibleOffset.isMultiple(of: 4_096),
        let blob = observed.0,
        blob.descriptor.blobMemory == 2,
        blob.descriptor.blobFlags & 1 != 0,
        blob.mapping == nil,
        hostVisibleOffset <= hostVisibleAperture.byteCount,
        blob.descriptor.size <= hostVisibleAperture.byteCount - hostVisibleOffset
      else { return response(.errorInvalidResource, header: header) }
      let mapAdmissionGeneration = hostVisibleAperture.mapAdmissionGeneration
      var rendererMapped = false
      do {
        let mapping = try accelerationAuthority.mapBlob(
          resourceID: resourceID,
          identity: blob.identity,
          hostVisibleOffset: hostVisibleOffset
        )
        rendererMapped = true
        guard mapping.workspaceID == blob.identity.workspaceID,
          mapping.resourceID == resourceID,
          mapping.resourceGeneration == blob.identity.resourceGeneration,
          mapping.workerGeneration == blob.identity.workerGeneration,
          mapping.deviceGeneration == blob.identity.deviceGeneration,
          mapping.hostVisibleOffset == hostVisibleOffset,
          mapping.byteCount == blob.descriptor.size,
          mapping.memory.byteCount == mapping.byteCount,
          (0...3).contains(mapping.mapInfo),
          mapping.workerGeneration != 0, mapping.deviceGeneration != 0
        else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
        let installed = try lock.withLock { () throws -> Bool in
          guard var current = blobResources[resourceID],
            resetCount == observed.1,
            current.identity == blob.identity, current.mapping == nil
          else { return false }
          try hostVisibleAperture.map(
            mapping,
            expectedApertureGeneration: mapAdmissionGeneration
          )
          current.mapping = mapping
          blobResources[resourceID] = current
          return true
        }
        guard installed else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
        return response(.okMapInfo, header: header)
          + littleEndian(mapping.mapInfo) + littleEndian(UInt32(0))
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked {
          reset()
        }
        // A worker map has already acquired renderer-side backing, but the local aperture and
        // resource record commit together or not at all. If worker rollback cannot be proved,
        // revoke the whole device generation instead of keeping an untracked live mapping.
        if rendererMapped {
          do {
            try accelerationAuthority.unmapBlob(
              resourceID: resourceID,
              identity: blob.identity,
              beforeRendererUnmap: { true }
            )
          } catch {
            reset()
          }
        }
        return response(.errorInvalidParameter, header: header)
      }

    case .resourceUnmapBlob:
      guard request.count == 32, offeredFeatures.contains(.gpuResourceBlob),
        let accelerationAuthority, let hostVisibleAperture
      else { return response(.errorInvalidResource, header: header) }
      let resourceID = read32(request, 24)
      guard let operationToken = reserveBlobOperation(resourceID: resourceID) else {
        return response(.errorInvalidResource, header: header)
      }
      defer { finishBlobOperation(resourceID: resourceID, token: operationToken) }
      let observed = lock.withLock {
        (blobResources[resourceID], resetCount)
      }
      guard let blob = observed.0,
        blob.mapping != nil
      else { return response(.errorInvalidResource, header: header) }
      let unmapAttempt = BlobUnmapAttempt()
      do {
        try accelerationAuthority.unmapBlob(
          resourceID: resourceID,
          identity: blob.identity,
          beforeRendererUnmap: {
            unmapAttempt.retireLocalAlias {
              hostVisibleAperture.unmap(
                resourceID: resourceID,
                identity: blob.identity
              )
            }
          }
        )
        let cleared = lock.withLock { () -> Bool in
          guard var current = blobResources[resourceID],
            !isResetting, resetCount == observed.1,
            current.identity == blob.identity,
            let currentMapping = current.mapping,
            let retiredMapping = blob.mapping,
            currentMapping.memory === retiredMapping.memory
          else { return false }
          current.mapping = nil
          blobResources[resourceID] = current
          return true
        }
        guard cleared else {
          reset()
          return response(.errorInvalidResource, header: header)
        }
        return response(.okNoData, header: header)
      } catch {
        if unmapAttempt.localTeardownStarted
          || error as? DoryVirtioGPUAccelerationError == .generationRevoked
        { reset() }
        return response(.errorInvalidParameter, header: header)
      }

    case .resourceAttachBacking:
      guard request.count >= 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let entryCount = Int(read32(request, 28))
      guard entryCount > 0, entryCount <= maximumBackingEntries,
        request.count == 32 + entryCount * 16
      else { return response(.errorInvalidParameter, header: header) }
      var entries: [DoryVirtioGPUBackingEntry] = []
      entries.reserveCapacity(entryCount)
      var total: UInt64 = 0
      for index in 0..<entryCount {
        let offset = 32 + index * 16
        let address = read64(request, offset)
        let length = read32(request, offset + 8)
        let (end, addressOverflow) = address.addingReportingOverflow(UInt64(length))
        let (updated, totalOverflow) = total.addingReportingOverflow(UInt64(length))
        guard length > 0, !addressOverflow, end >= address, !totalOverflow,
          updated <= maximumResourceBytes
        else { return response(.errorInvalidParameter, header: header) }
        do {
          try memory.validate(at: address, byteCount: Int(length), deviceWillWrite: false)
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
        entries.append(.init(guestAddress: address, length: length))
        total = updated
      }
      if lock.withLock({ blobResources[id] != nil }) {
        guard let token = reserveBlobOperation(resourceID: id) else {
          return response(.errorInvalidResource, header: header)
        }
        defer { finishBlobOperation(resourceID: id, token: token) }
        let observed = lock.withLock { (blobResources[id], resetCount) }
        guard let blob = observed.0, blob.descriptor.blobMemory != 2,
          blob.entries.isEmpty, total >= blob.descriptor.size,
          let accelerationAuthority
        else { return response(.errorInvalidResource, header: header) }
        do {
          try accelerationAuthority.attachBlobBacking(
            resourceID: id, identity: blob.identity, entries: entries, memory: memory)
        } catch {
          if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
          return response(.errorInvalidParameter, header: header)
        }
        let attached = lock.withLock { () -> Bool in
          guard var current = blobResources[id], !isResetting,
            resetCount == observed.1, current.identity == blob.identity,
            current.entries.isEmpty
          else { return false }
          current.entries = entries
          blobResources[id] = current
          return true
        }
        if !attached { reset() }
        return response(attached ? .okNoData : .errorInvalidResource, header: header)
      }
      if lock.withLock({ rendererResources[id] != nil }) {
        guard let token = reserveBlobOperation(resourceID: id) else {
          return response(.errorInvalidResource, header: header)
        }
        defer { finishBlobOperation(resourceID: id, token: token) }
        let observed = lock.withLock { (rendererResources[id], resetCount) }
        guard let resource = observed.0, resource.backing.isEmpty,
          let accelerationAuthority
        else {
          return response(.errorInvalidResource, header: header)
        }
        do {
          try accelerationAuthority.attachBacking(
            resourceID: id,
            entries: entries,
            memory: memory
          )
        } catch {
          if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
          return response(.errorInvalidParameter, header: header)
        }
        let attached = lock.withLock { () -> Bool in
          guard !isResetting, resetCount == observed.1,
            var current = rendererResources[id],
            current.generation == resource.generation, current.backing.isEmpty
          else { return false }
          current.backing = entries
          rendererResources[id] = current
          return true
        }
        if !attached { reset() }
        return response(attached ? .okNoData : .errorInvalidResource, header: header)
      }
      let attached = lock.withLock { () -> Bool in
        guard var resource = resources[id], resource.backing.isEmpty,
          total >= UInt64(resource.pixels.count)
        else { return false }
        resource.backing = entries
        resources[id] = resource
        return true
      }
      return response(attached ? .okNoData : .errorInvalidResource, header: header)

    case .resourceDetachBacking:
      guard request.count == 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      if lock.withLock({ blobResources[id] != nil }) {
        guard let token = reserveBlobOperation(resourceID: id) else {
          return response(.errorInvalidResource, header: header)
        }
        defer { finishBlobOperation(resourceID: id, token: token) }
        let observed = lock.withLock { (blobResources[id], resetCount) }
        guard let blob = observed.0, blob.descriptor.blobMemory != 2,
          !blob.entries.isEmpty, let accelerationAuthority
        else { return response(.errorInvalidResource, header: header) }
        do {
          try accelerationAuthority.detachBlobBacking(
            resourceID: id, identity: blob.identity)
        } catch {
          if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
          return response(.errorInvalidParameter, header: header)
        }
        let detached = lock.withLock { () -> Bool in
          guard var current = blobResources[id], !isResetting,
            resetCount == observed.1, current.identity == blob.identity,
            !current.entries.isEmpty
          else { return false }
          current.entries = []
          blobResources[id] = current
          return true
        }
        if !detached { reset() }
        return response(detached ? .okNoData : .errorInvalidResource, header: header)
      }
      if lock.withLock({ rendererResources[id] != nil }) {
        guard let token = reserveBlobOperation(resourceID: id) else {
          return response(.errorInvalidResource, header: header)
        }
        defer { finishBlobOperation(resourceID: id, token: token) }
        let observed = lock.withLock { (rendererResources[id], resetCount) }
        guard let resource = observed.0, !resource.backing.isEmpty,
          let accelerationAuthority
        else { return response(.errorInvalidResource, header: header) }
        do {
          try accelerationAuthority.detachBacking(resourceID: id)
        } catch {
          if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
          return response(.errorInvalidParameter, header: header)
        }
        let detached = lock.withLock { () -> Bool in
          guard !isResetting, resetCount == observed.1,
            var current = rendererResources[id],
            current.generation == resource.generation,
            !current.backing.isEmpty
          else { return false }
          current.backing = []
          rendererResources[id] = current
          return true
        }
        if !detached { reset() }
        return response(detached ? .okNoData : .errorInvalidResource, header: header)
      }
      let detached = lock.withLock { () -> Bool in
        guard var resource = resources[id] else { return false }
        resource.backing = []
        resources[id] = resource
        return true
      }
      return response(detached ? .okNoData : .errorInvalidResource, header: header)

    case .transferToHost2D:
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let sourceOffset = read64(request, 40)
      let id = read32(request, 48)
      let transferred = try transfer(
        resourceID: id,
        rectangle: rectangle,
        sourceOffset: sourceOffset,
        memory: memory
      )
      return response(transferred ? .okNoData : .errorInvalidParameter, header: header)

    case .contextCreate:
      guard request.count == 96, header.contextID != 0,
        let accelerationAuthority
      else { return response(.errorInvalidParameter, header: header) }
      let nameLength = Int(read32(request, 24))
      let requestedCapset = read32(request, 28)
      guard nameLength <= 64, requestedCapset & ~UInt32(0xFF) == 0,
        let capsetID = resolvedCapsetID(
          requestedCapset,
          capabilities: accelerationAuthority.capabilities
        )
      else { return response(.errorInvalidParameter, header: header) }
      let rawName = request[32..<(32 + nameLength)].prefix { $0 != 0 }
      let name = rawName.isEmpty ? "virtio-gpu" : String(decoding: rawName, as: UTF8.self)
      let contextAdmission = reserveContextCreate(header.contextID)
      guard case let .admitted(contextToken, admittedResetCount) = contextAdmission else {
        if case let .rejected(reason) = contextAdmission { return response(reason, header: header) }
        return response(.errorInvalidParameter, header: header)
      }
      defer { finishContextCreate(header.contextID, token: contextToken) }
      do {
        try accelerationAuthority.createContext(
          id: header.contextID,
          capsetID: capsetID,
          name: name
        )
      } catch DoryVirtioGPUAccelerationError.resourceLimitExceeded {
        return response(.errorOutOfMemory, header: header)
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      let inserted = lock.withLock { () -> Bool in
        guard !isResetting, resetCount == admittedResetCount,
          pendingContextCreates[header.contextID] == contextToken,
          !rendererContexts.contains(header.contextID)
        else { return false }
        rendererContexts.insert(header.contextID)
        pendingContextCreates.removeValue(forKey: header.contextID)
        return true
      }
      guard inserted else {
        // The renderer accepted a context that cannot be owned locally after reset/race.
        reset()
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .contextDestroy:
      guard request.count == 24, header.contextID != 0,
        let accelerationAuthority,
        let contextAdmission = reserveContextMutation(header.contextID)
      else { return response(.errorInvalidParameter, header: header) }
      defer { finishContextMutation(header.contextID, token: contextAdmission.token) }
      do {
        try accelerationAuthority.destroyContext(id: header.contextID)
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
        return response(.errorInvalidParameter, header: header)
      }
      let destroyed = lock.withLock { () -> Bool in
        guard !isResetting, resetCount == contextAdmission.resetCount,
          pendingContextMutations[header.contextID] == contextAdmission.token,
          rendererContexts.contains(header.contextID)
        else { return false }
        rendererContexts.remove(header.contextID)
        pendingContextMutations.removeValue(forKey: header.contextID)
        return true
      }
      guard destroyed else {
        reset()
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .contextAttachResource, .contextDetachResource:
      guard request.count == 32, header.contextID != 0,
        let accelerationAuthority
      else { return response(.errorInvalidParameter, header: header) }
      let resourceID = read32(request, 24)
      guard let contextAdmission = reserveContextMutation(header.contextID) else {
        return response(.errorInvalidParameter, header: header)
      }
      defer { finishContextMutation(header.contextID, token: contextAdmission.token) }
      guard let resourceToken = reserveBlobOperation(resourceID: resourceID) else {
        return response(.errorInvalidResource, header: header)
      }
      defer { finishBlobOperation(resourceID: resourceID, token: resourceToken) }
      let observed = lock.withLock {
        (rendererResources[resourceID]?.generation, blobResources[resourceID]?.identity,
          resetCount)
      }
      guard observed.2 == contextAdmission.resetCount,
        observed.0 != nil || observed.1 != nil
      else {
        return response(.errorInvalidResource, header: header)
      }
      do {
        if command == .contextAttachResource {
          try accelerationAuthority.attachResource(
            contextID: header.contextID,
            resourceID: resourceID
          )
        } else {
          try accelerationAuthority.detachResource(
            contextID: header.contextID,
            resourceID: resourceID
          )
        }
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
        return response(.errorInvalidParameter, header: header)
      }
      let committed = lock.withLock { () -> Bool in
        !isResetting && resetCount == observed.2
          && pendingContextMutations[header.contextID] == contextAdmission.token
          && rendererContexts.contains(header.contextID)
          && pendingBlobOperations[resourceID] == resourceToken
          && rendererResources[resourceID]?.generation == observed.0
          && blobResources[resourceID]?.identity == observed.1
      }
      guard committed else {
        reset()
        return response(.errorInvalidResource, header: header)
      }
      return response(.okNoData, header: header)

    case .resourceCreate3D:
      guard request.count == 72, accelerationAuthority != nil else {
        return response(.errorInvalidParameter, header: header)
      }
      let resource = DoryVirtioGPUResource3D(
        resourceID: read32(request, 24),
        target: read32(request, 28),
        format: read32(request, 32),
        bind: read32(request, 36),
        width: read32(request, 40),
        height: read32(request, 44),
        depth: read32(request, 48),
        arraySize: read32(request, 52),
        lastLevel: read32(request, 56),
        samples: read32(request, 60),
        flags: read32(request, 64)
      )
      guard valid(resource) else { return response(.errorInvalidParameter, header: header) }
      let resourceAdmission = reserveResourceCreate(resource.resourceID)
      guard case let .admitted(resourceToken, admittedResetCount) = resourceAdmission else {
        if case let .rejected(reason) = resourceAdmission { return response(reason, header: header) }
        return response(.errorInvalidParameter, header: header)
      }
      defer { finishResourceCreate(resource.resourceID, token: resourceToken) }
      do {
        try accelerationAuthority?.createResource3D(resource)
      } catch DoryVirtioGPUAccelerationError.resourceLimitExceeded {
        return response(.errorOutOfMemory, header: header)
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      let inserted = lock.withLock { () -> Bool in
        guard !isResetting, resetCount == admittedResetCount,
          pendingResourceCreates[resource.resourceID] == resourceToken,
          resources[resource.resourceID] == nil,
          rendererResources[resource.resourceID] == nil,
          blobResources[resource.resourceID] == nil
        else { return false }
        rendererResources[resource.resourceID] = .init(descriptor: resource)
        releaseResourceCreateReservationLocked(resource.resourceID, token: resourceToken)
        return true
      }
      guard inserted else {
        reset()
        return response(.errorInvalidResource, header: header)
      }
      return response(.okNoData, header: header)

    case .transferToHost3D, .transferFromHost3D:
      guard request.count == 72, let accelerationAuthority else {
        return response(.errorInvalidParameter, header: header)
      }
      let resourceID = read32(request, 56)
      let transfer = DoryVirtioGPUTransfer3D(
        direction: command == .transferToHost3D ? .toHost : .fromHost,
        resourceID: resourceID,
        contextID: header.contextID,
        x: read32(request, 24),
        y: read32(request, 28),
        z: read32(request, 32),
        width: read32(request, 36),
        height: read32(request, 40),
        depth: read32(request, 44),
        offset: read64(request, 48),
        level: read32(request, 60),
        stride: read32(request, 64),
        layerStride: read32(request, 68)
      )
      guard transfer.width > 0, transfer.height > 0, transfer.depth > 0,
        let token = reserveBlobOperation(resourceID: resourceID)
      else { return response(.errorInvalidResource, header: header) }
      defer { finishBlobOperation(resourceID: resourceID, token: token) }
      let contextAdmission: (token: UUID, resetCount: UInt64)?
      if header.contextID == 0 {
        contextAdmission = nil
      } else {
        guard let reserved = reserveContextUse(header.contextID) else {
          return response(.errorInvalidResource, header: header)
        }
        contextAdmission = reserved
      }
      defer {
        if let contextAdmission {
          finishContextUse(
            header.contextID, token: contextAdmission.token,
            admittedResetCount: contextAdmission.resetCount)
        }
      }
      let observed = lock.withLock {
        (rendererResources[resourceID], resetCount,
          header.contextID == 0
            || (contextAdmission != nil
              && pendingContextUses[header.contextID]?.contains(contextAdmission!.token) == true))
      }
      guard let resource = observed.0, observed.2
      else { return response(.errorInvalidResource, header: header) }
      do {
        try accelerationAuthority.transfer3D(
          transfer, entries: resource.backing, memory: memory)
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
        return response(.errorInvalidParameter, header: header)
      }
      let transferred = lock.withLock { () -> Bool in
        guard !isResetting, resetCount == observed.1,
          header.contextID == 0
            || (contextAdmission != nil
              && pendingContextUses[header.contextID]?.contains(contextAdmission!.token) == true),
          var current = rendererResources[resourceID],
          current.generation == resource.generation
        else { return false }
        current.latestTransfer = transfer
        rendererResources[resourceID] = current
        return true
      }
      guard transferred else {
        reset()
        return response(.errorInvalidResource, header: header)
      }
      return response(.okNoData, header: header)

    case .submit3D:
      guard request.count >= 32, header.contextID != 0,
        let accelerationAuthority
      else { return response(.errorInvalidParameter, header: header) }
      let byteCount = Int(read32(request, 24))
      guard byteCount > 0, byteCount.isMultiple(of: 4), request.count == 32 + byteCount else {
        return response(.errorInvalidParameter, header: header)
      }
      guard let contextAdmission = reserveContextUse(header.contextID) else {
        return response(.errorInvalidParameter, header: header)
      }
      defer {
        finishContextUse(
          header.contextID, token: contextAdmission.token,
          admittedResetCount: contextAdmission.resetCount)
      }
      do {
        try accelerationAuthority.submit3D(
          contextID: header.contextID,
          command: Array(request[32...])
        )
      } catch {
        if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
        return response(.errorInvalidParameter, header: header)
      }
      let committed = lock.withLock {
        !isResetting && resetCount == contextAdmission.resetCount
          && rendererContexts.contains(header.contextID)
          && pendingContextUses[header.contextID]?.contains(contextAdmission.token) == true
      }
      guard committed else {
        reset()
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .setScanout:
      guard request.count == 48 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let scanoutID = read32(request, 40)
      let resourceID = read32(request, 44)
      guard Int(scanoutID) < scanoutCount else {
        return response(.errorInvalidScanout, header: header)
      }
      if resourceID == 0 {
        let sink = lock.withLock { () -> (any DoryVirtioGPUDisplaySink)? in
          bindings.removeValue(forKey: scanoutID)
          blobBindings.removeValue(forKey: scanoutID)
          cursors.removeValue(forKey: scanoutID)
          return displaySink
        }
        sink?.presentCursor(.hidden(scanoutID: scanoutID))
        return response(.okNoData, header: header)
      }
      let bound = lock.withLock { () -> Bool in
        if let resource = resources[resourceID] {
          guard contains(rectangle, in: resource) else { return false }
        } else if let resource = rendererResources[resourceID] {
          guard contains(rectangle, in: resource.descriptor) else { return false }
        } else {
          return false
        }
        bindings[scanoutID] = .init(resourceID: resourceID, rectangle: rectangle)
        blobBindings.removeValue(forKey: scanoutID)
        return true
      }
      return response(bound ? .okNoData : .errorInvalidResource, header: header)

    case .setScanoutBlob:
      guard request.count == 96, offeredFeatures.contains(.gpuResourceBlob) else {
        return response(.errorInvalidParameter, header: header)
      }
      let rectangle = readRectangle(request, 24)
      let scanoutID = read32(request, 40)
      let resourceID = read32(request, 44)
      guard Int(scanoutID) < scanoutCount else {
        return response(.errorInvalidScanout, header: header)
      }
      if resourceID == 0 {
        let sink = lock.withLock { () -> (any DoryVirtioGPUDisplaySink)? in
          bindings.removeValue(forKey: scanoutID)
          blobBindings.removeValue(forKey: scanoutID)
          cursors.removeValue(forKey: scanoutID)
          return displaySink
        }
        sink?.presentCursor(.hidden(scanoutID: scanoutID))
        return response(.okNoData, header: header)
      }
      let width = read32(request, 48)
      let height = read32(request, 52)
      let format = read32(request, 56)
      let stride = read32(request, 64)
      let storageOffset = read32(request, 80)
      let validPlanes =
        read32(request, 68) == 0 && read32(request, 72) == 0
        && read32(request, 76) == 0 && read32(request, 84) == 0
        && read32(request, 88) == 0 && read32(request, 92) == 0
      let bound = lock.withLock { () -> Bool in
        guard pendingBlobOperations[resourceID] == nil,
          let blob = blobResources[resourceID],
          Self.valid(width: width, height: height),
          Self.isSupportedRendererBlobScanoutFormat(format),
          Self.contains(rectangle, width: width, height: height),
          stride >= width * 4, validPlanes,
          Self.scanoutByteRangeIsValid(
            width: width,
            height: height,
            stride: stride,
            offset: storageOffset,
            resourceSize: blob.descriptor.size
          )
        else { return false }
        blobBindings[scanoutID] = .init(
          resourceID: resourceID,
          identity: blob.identity,
          rectangle: rectangle,
          width: width,
          height: height,
          format: format,
          stride: stride,
          offset: storageOffset
        )
        bindings.removeValue(forKey: scanoutID)
        return true
      }
      return response(bound ? .okNoData : .errorInvalidResource, header: header)

    case .resourceFlush:
      guard request.count == 48 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let resourceID = read32(request, 40)
      guard let operationToken = reserveBlobOperation(resourceID: resourceID) else {
        return response(.errorInvalidResource, header: header)
      }
      defer { finishBlobOperation(resourceID: resourceID, token: operationToken) }
      let invalidBlobRectangle = lock.withLock {
        blobBindings.values.contains { binding in
          binding.resourceID == resourceID
            && !Self.contains(rectangle, width: binding.width, height: binding.height)
        }
      }
      if invalidBlobRectangle {
        return response(.errorInvalidParameter, header: header)
      }
      if let blobFlushes = lock.withLock({ () -> [DoryVirtioGPUBlobScanoutFlush]? in
        guard let blob = blobResources[resourceID],
          blobBindings.values.allSatisfy({ binding in
            binding.resourceID != resourceID || binding.identity == blob.identity
          })
        else { return nil }
        return blobBindings.compactMap { scanoutID, binding in
          guard binding.resourceID == resourceID,
            Self.intersects(rectangle, binding.rectangle)
          else { return nil }
          return .init(
            scanoutID: scanoutID,
            resourceID: resourceID,
            identity: blob.identity,
            sourceRectangle: binding.rectangle,
            damagedRectangle: rectangle,
            width: binding.width,
            height: binding.height,
            format: binding.format,
            stride: binding.stride,
            offset: binding.offset
          )
        }
      }) {
        guard let accelerationAuthority else {
          return response(.errorInvalidResource, header: header)
        }
        do {
          if !blobFlushes.isEmpty {
            try accelerationAuthority.flushBlobResource(blobFlushes)
          }
        } catch {
          if error as? DoryVirtioGPUAccelerationError == .generationRevoked { reset() }
          return response(.errorInvalidParameter, header: header)
        }
        return response(.okNoData, header: header)
      }
      if let accelerated = lock.withLock({ () -> [DoryVirtioGPUAcceleratedScanoutFlush]? in
        guard let resource = rendererResources[resourceID],
          contains(rectangle, in: resource.descriptor)
        else { return nil }
        let transfer = resource.latestTransfer
        return bindings.compactMap { scanoutID, binding in
          guard binding.resourceID == resourceID else { return nil }
          return .init(
            scanoutID: scanoutID,
            resourceID: resourceID,
            sourceRectangle: binding.rectangle,
            damagedRectangle: rectangle,
            resourceWidth: resource.descriptor.width,
            resourceHeight: resource.descriptor.height,
            virglFormat: resource.descriptor.format,
            stride: transfer?.stride ?? 0,
            storageOffset: transfer?.offset ?? 0
          )
        }
      }) {
        guard let accelerationAuthority else {
          return response(.errorInvalidResource, header: header)
        }
        do {
          if !accelerated.isEmpty { try accelerationAuthority.flushResource(accelerated) }
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
        return response(.okNoData, header: header)
      }
      let flush = lock.withLock {
        () -> (Response?, [DoryVirtioGPUFrame], (any DoryVirtioGPUDisplaySink)?) in
        guard let resource = resources[resourceID], contains(rectangle, in: resource) else {
          return (
            resources[resourceID] == nil ? .errorInvalidResource : .errorInvalidParameter,
            [],
            displaySink
          )
        }
        let frames = bindings.compactMap { scanoutID, binding -> DoryVirtioGPUFrame? in
          guard binding.resourceID == resourceID else { return nil }
          return .init(
            scanoutID: scanoutID,
            resourceID: resourceID,
            resourceGeneration: resource.generation,
            scanoutRectangle: binding.rectangle,
            damagedRectangle: rectangle,
            resourceWidth: resource.width,
            resourceHeight: resource.height,
            format: resource.format,
            pixels: resource.pixels
          )
        }
        return (nil, frames, displaySink)
      }
      if let error = flush.0 { return response(error, header: header) }
      for frame in flush.1 { flush.2?.present(frame) }
      return response(.okNoData, header: header)

    case .updateCursor:
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let scanoutID = read32(request, 24)
      guard Int(scanoutID) < scanoutCount else {
        return response(.errorInvalidScanout, header: header)
      }
      let resourceID = read32(request, 40)
      let hotX = read32(request, 44)
      let hotY = read32(request, 48)
      let x = read32(request, 28)
      let y = read32(request, 32)
      let publication = lock.withLock {
        () -> (DoryVirtioGPUCursorUpdate?, (any DoryVirtioGPUDisplaySink)?) in
        if resourceID == 0 {
          cursors.removeValue(forKey: scanoutID)
          return (.hidden(scanoutID: scanoutID), displaySink)
        }
        guard let resource = resources[resourceID],
          resource.width == 64,
          resource.height == 64,
          resource.format == .b8g8r8a8UNorm || resource.format == .b8g8r8x8UNorm,
          hotX < 64, hotY < 64,
          resource.pixels.count == 64 * 64 * 4
        else { return (nil, nil) }
        let update = DoryVirtioGPUCursorUpdate(
          scanoutID: scanoutID,
          resourceID: resourceID,
          x: x,
          y: y,
          hotX: hotX,
          hotY: hotY,
          bytes: resource.pixels
        )
        cursors[scanoutID] = update
        return (update, displaySink)
      }
      guard let update = publication.0 else {
        return response(.errorInvalidResource, header: header)
      }
      publication.1?.presentCursor(update)
      return response(.okNoData, header: header)

    case .moveCursor:
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let scanoutID = read32(request, 24)
      guard Int(scanoutID) < scanoutCount else {
        return response(.errorInvalidScanout, header: header)
      }
      let x = read32(request, 28)
      let y = read32(request, 32)
      let publication = lock.withLock {
        () -> (DoryVirtioGPUCursorUpdate?, (any DoryVirtioGPUDisplaySink)?) in
        guard let prior = cursors[scanoutID] else { return (nil, nil) }
        let update = DoryVirtioGPUCursorUpdate(
          scanoutID: scanoutID,
          resourceID: prior.resourceID,
          x: x,
          y: y,
          hotX: prior.hotX,
          hotY: prior.hotY,
          bytes: prior.bytes
        )
        cursors[scanoutID] = update
        return (update, displaySink)
      }
      if let update = publication.0 { publication.1?.presentCursor(update) }
      return response(.okNoData, header: header)
    }
  }

  private func transfer(
    resourceID: UInt32,
    rectangle: DoryVirtioGPURectangle,
    sourceOffset: UInt64,
    memory: any DoryVirtioGuestMemory
  ) throws -> Bool {
    // Keep only identity and backing metadata while reading guest memory. Retaining the old
    // framebuffer here would force a full-sized copy on every partial transfer and allow an
    // in-flight transfer to overwrite a reused resource ID after unref or reset.
    let snapshot = lock.withLock {
      resources[resourceID].map { resource in
        (
          generation: resource.generation,
          width: resource.width,
          height: resource.height,
          format: resource.format,
          backing: resource.backing
        )
      }
    }
    guard let snapshot, !snapshot.backing.isEmpty,
      Self.contains(rectangle, width: snapshot.width, height: snapshot.height)
    else {
      return false
    }
    let rowBytes = UInt64(rectangle.width) * UInt64(snapshot.format.bytesPerPixel)
    let stride = UInt64(snapshot.width) * UInt64(snapshot.format.bytesPerPixel)
    let resourceBytes = stride * UInt64(snapshot.height)
    var transferred: [UInt8] = []
    transferred.reserveCapacity(Int(rowBytes * UInt64(rectangle.height)))
    for row in 0..<UInt64(rectangle.height) {
      let (rowStride, multiplyOverflow) = row.multipliedReportingOverflow(by: stride)
      let (logicalOffset, addOverflow) = sourceOffset.addingReportingOverflow(rowStride)
      guard !multiplyOverflow, !addOverflow,
        logicalOffset <= resourceBytes,
        rowBytes <= resourceBytes - logicalOffset
      else { return false }
      let bytes = try readBacking(
        snapshot.backing,
        offset: logicalOffset,
        byteCount: Int(rowBytes),
        memory: memory
      )
      transferred.append(contentsOf: bytes)
    }
    return lock.withLock {
      guard var current = resources.removeValue(forKey: resourceID) else { return false }
      guard current.generation == snapshot.generation,
        current.backing == snapshot.backing
      else {
        resources[resourceID] = current
        return false
      }
      for row in 0..<UInt64(rectangle.height) {
        let source = Int(row * rowBytes)
        let destination =
          (UInt64(rectangle.y) + row) * stride
          + UInt64(rectangle.x) * UInt64(current.format.bytesPerPixel)
        current.pixels.replaceSubrange(
          Int(destination)..<(Int(destination) + Int(rowBytes)),
          with: transferred[source..<(source + Int(rowBytes))]
        )
      }
      resources[resourceID] = current
      return true
    }
  }

  private func contains(
    _ rectangle: DoryVirtioGPURectangle,
    in resource: DoryVirtioGPUResource3D
  ) -> Bool {
    let (endX, overflowX) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (endY, overflowY) = rectangle.y.addingReportingOverflow(rectangle.height)
    return rectangle.width > 0 && rectangle.height > 0 && !overflowX && !overflowY
      && endX <= resource.width && endY <= resource.height
  }

  private func readBacking(
    _ entries: [DoryVirtioGPUBackingEntry],
    offset: UInt64,
    byteCount: Int,
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var skip = offset
    var remaining = byteCount
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    for entry in entries {
      if skip >= UInt64(entry.length) {
        skip -= UInt64(entry.length)
        continue
      }
      let available = UInt64(entry.length) - skip
      let count = min(remaining, Int(available))
      let (address, overflow) = entry.guestAddress.addingReportingOverflow(skip)
      guard !overflow else { throw DoryVirtioGPUError.guestAddressOverflow }
      let part = try memory.read(at: address, byteCount: count)
      guard part.count == count else {
        throw DoryVirtioGPUError.invalidGuestMemoryResponse(
          expected: count,
          actual: part.count
        )
      }
      result += part
      remaining -= count
      skip = 0
      if remaining == 0 { break }
    }
    guard remaining == 0 else { throw DoryVirtioGPUError.malformedRequest }
    return result
  }

  private func response(_ type: Response, header: Header) -> [UInt8] {
    let flags =
      header.hasFence
      ? header.flags & (Header.fenceFlag | Header.infoRingIndexFlag)
      : 0
    return littleEndian(type.rawValue) + littleEndian(flags) + littleEndian(header.fenceID)
      + littleEndian(header.contextID) + [header.ringIndex, 0, 0, 0]
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    guard descriptors.reduce(UInt64(0), { $0 + UInt64($1.length) }) <= maximumResourceBytes else {
      throw DoryVirtioGPUError.requestTooLarge(
        descriptors.reduce(UInt64(0), { $0 + UInt64($1.length) })
      )
    }
    var bytes: [UInt8] = []
    for descriptor in descriptors {
      let part = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
      guard part.count == Int(descriptor.length) else {
        throw DoryVirtioGPUError.malformedRequest
      }
      bytes += part
    }
    return bytes
  }

  private func scatter(
    _ bytes: [UInt8],
    into descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    var offset = 0
    for descriptor in descriptors where offset < bytes.count {
      let count = min(Int(descriptor.length), bytes.count - offset)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[offset..<(offset + count)])
      )
      offset += count
    }
    guard offset == bytes.count else { throw DoryVirtioGPUError.malformedRequest }
  }

  /// Validates every writable response target up front using the guest-memory validation
  /// contract, before command execution or deferred scheduling. Rejecting the offered
  /// writable chain here prevents a malformed later descriptor from letting a command
  /// mutate device/renderer state or partially scattering an earlier response.
  private func validateWritableTargets(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    for descriptor in descriptors {
      try memory.validate(
        at: descriptor.address,
        byteCount: Int(descriptor.length),
        deviceWillWrite: true
      )
    }
  }

  private func resourceByteCount(width: UInt32, height: UInt32) -> UInt64? {
    let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
    let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
    return overflow || byteOverflow ? nil : bytes
  }

  private static func valid(_ rectangle: DoryVirtioGPURectangle) -> Bool {
    let (_, xOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (_, yOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
    return !xOverflow && !yOverflow && valid(width: rectangle.width, height: rectangle.height)
  }

  private static func valid(width: UInt32, height: UInt32) -> Bool {
    width > 0 && height > 0 && width <= 16_384 && height <= 16_384
  }

  private static func contains(
    _ rectangle: DoryVirtioGPURectangle,
    width: UInt32,
    height: UInt32
  ) -> Bool {
    let (right, xOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (bottom, yOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
    return rectangle.width > 0 && rectangle.height > 0 && !xOverflow && !yOverflow
      && right <= width && bottom <= height
  }

  private static func intersects(
    _ lhs: DoryVirtioGPURectangle,
    _ rhs: DoryVirtioGPURectangle
  ) -> Bool {
    let (lhsRight, lhsXOverflow) = lhs.x.addingReportingOverflow(lhs.width)
    let (lhsBottom, lhsYOverflow) = lhs.y.addingReportingOverflow(lhs.height)
    let (rhsRight, rhsXOverflow) = rhs.x.addingReportingOverflow(rhs.width)
    let (rhsBottom, rhsYOverflow) = rhs.y.addingReportingOverflow(rhs.height)
    return lhs.width > 0 && lhs.height > 0 && rhs.width > 0 && rhs.height > 0
      && !lhsXOverflow && !lhsYOverflow && !rhsXOverflow && !rhsYOverflow
      && lhs.x < rhsRight && rhs.x < lhsRight && lhs.y < rhsBottom && rhs.y < lhsBottom
  }

  private static func isSupportedScanoutFormat(_ format: UInt32) -> Bool {
    [1, 2, 3, 4, 67, 68, 121, 134].contains(format)
  }

  private static func isSupportedRendererBlobScanoutFormat(_ format: UInt32) -> Bool {
    [1, 2, 67, 68].contains(format)
  }

  private static func scanoutByteRangeIsValid(
    width: UInt32,
    height: UInt32,
    stride: UInt32,
    offset: UInt32,
    resourceSize: UInt64
  ) -> Bool {
    guard width > 0, height > 0 else { return false }
    let (finalRow, rowOverflow) = UInt64(height - 1).multipliedReportingOverflow(
      by: UInt64(stride)
    )
    let (finalPixel, pixelOverflow) = UInt64(width).multipliedReportingOverflow(by: 4)
    guard !rowOverflow, !pixelOverflow, UInt64(offset) <= resourceSize,
      finalRow <= resourceSize - UInt64(offset)
    else { return false }
    return finalPixel <= resourceSize - UInt64(offset) - finalRow
  }

  private func valid(_ resource: DoryVirtioGPUResource3D) -> Bool {
    let widthIsValid =
      resource.target == 0
      ? resource.width > 0 && UInt64(resource.width) <= maximumResourceBytes
      : resource.width > 0 && resource.width <= 16_384
    return resource.resourceID != 0 && resource.format != 0 && widthIsValid
      && (1...16_384).contains(resource.height)
      && (1...16_384).contains(resource.depth)
      && (1...16_384).contains(resource.arraySize)
      && resource.lastLevel <= 31 && resource.samples <= 64
  }

  private func resolvedCapsetID(
    _ requested: UInt32,
    capabilities: DoryVirtioGPUAccelerationCapabilities
  ) -> UInt32? {
    let requestedID = requested & 0xFF
    if requestedID != 0 {
      return capabilities.capsets.contains(where: { $0.id == requestedID }) ? requestedID : nil
    }
    if capabilities.capsets.contains(where: { $0.id == 2 }) { return 2 }
    return capabilities.capsets.count == 1 ? capabilities.capsets[0].id : nil
  }

  private func contains(_ rectangle: DoryVirtioGPURectangle, in resource: Resource) -> Bool {
    guard rectangle.width > 0, rectangle.height > 0 else { return false }
    let (right, xOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (bottom, yOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
    return !xOverflow && !yOverflow && right <= resource.width && bottom <= resource.height
  }

  private func reserveBlobOperation(resourceID: UInt32) -> UUID? {
    lock.withLock {
      guard !isResetting, pendingBlobOperations[resourceID] == nil else { return nil }
      let token = UUID()
      pendingBlobOperations[resourceID] = token
      return token
    }
  }

  private func finishBlobOperation(resourceID: UInt32, token: UUID) {
    lock.withLock {
      guard pendingBlobOperations[resourceID] == token else { return }
      pendingBlobOperations.removeValue(forKey: resourceID)
    }
  }

  private func readRectangle(_ bytes: [UInt8], _ offset: Int) -> DoryVirtioGPURectangle {
    .init(
      x: read32(bytes, offset),
      y: read32(bytes, offset + 4),
      width: read32(bytes, offset + 8),
      height: read32(bytes, offset + 12)
    )
  }

  private func rectangleBytes(_ rectangle: DoryVirtioGPURectangle) -> [UInt8] {
    littleEndian(rectangle.x) + littleEndian(rectangle.y)
      + littleEndian(rectangle.width) + littleEndian(rectangle.height)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
