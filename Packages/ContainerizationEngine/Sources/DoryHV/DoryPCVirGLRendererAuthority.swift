import Darwin
import DoryMachinePC
import DoryOperations
import DoryRendererWorkerContracts
import DoryVirtio
import Foundation
import Metal

public enum DoryPCVirGLRendererAuthorityError: Error, Sendable, Equatable {
  case rendererUnavailable
  case unknownResource(UInt32)
  case duplicateResource(UInt32)
  case duplicateBacking(UInt32)
  case missingBacking(UInt32)
  case commandTimedOut
  case workerCommandFailed
  case producerFenceViolation
}

public final class DoryPCVirGLScanoutUpdate: @unchecked Sendable {
  public let flush: DoryVirtioGPUAcceleratedScanoutFlush
  public let workerGeneration: DoryRendererWorkerGeneration
  public let rendererResourceGeneration: UInt64
  public let pixelFormat: DoryRendererScanoutPixelFormat
  public let yOriginTop: Bool
  public let width: UInt32
  public let height: UInt32
  public let transport: VirtioGPUMetalScanoutTransport

  private let lock = NSLock()
  private let scanoutLifetime: DoryPCScanoutAccessLifetime<DoryRendererWorkerScanoutAuthority>
  private let recordHostSubmission: (@Sendable (Bool) -> Void)?
  private let recordPresentationCompletion: (@Sendable (UInt64) -> Void)?
  private var presentationCompletionRecorded = false
  private let isCurrentResource: @Sendable () -> Bool
  private let isCurrentGeneration: @Sendable () -> Bool

  init(
    flush: DoryVirtioGPUAcceleratedScanoutFlush,
    scanout: DoryRendererWorkerScanoutAuthority,
    release: @escaping @Sendable (DoryRendererWorkerScanoutAuthority) -> Void,
    recordHostSubmission: (@Sendable (Bool) -> Void)? = nil,
    recordPresentationCompletion: (@Sendable (UInt64) -> Void)? = nil,
    isCurrentResource: @escaping @Sendable () -> Bool,
    isCurrentGeneration: @escaping @Sendable () -> Bool
  ) {
    self.flush = flush
    self.workerGeneration = scanout.workerGeneration
    self.rendererResourceGeneration = scanout.resourceGeneration
    self.pixelFormat = scanout.pixelFormat
    self.width = scanout.width
    self.height = scanout.height
    switch scanout {
    case .sharedMemory(let value):
      self.yOriginTop = value.lease.yOriginTop
      self.transport = .sharedMemory
    case .sharedTexture(let value):
      self.yOriginTop = value.lease.yOriginTop
      self.transport = .sharedTexture
    }
    scanoutLifetime = .init(value: scanout, release: release)
    self.recordHostSubmission = recordHostSubmission
    self.recordPresentationCompletion = recordPresentationCompletion
    self.isCurrentResource = isCurrentResource
    self.isCurrentGeneration = isCurrentGeneration
  }

  /// Presentation consumers may be scheduled after the VirtIO command completed. Recheck the
  /// originating resource and device generation at that later boundary.
  public var isCurrent: Bool { isCurrentResource() }

  /// An in-flight frame may outlive resource unref, but it must not count as a successful
  /// presentation after its renderer device generation was reset.
  public var isGenerationCurrent: Bool { isCurrentGeneration() }

  deinit { retire() }

  public func withSharedMemory<T>(
    _ body: (DoryRendererScanoutLease, Int32) throws -> T
  ) throws -> T {
    try scanoutLifetime.withValue { scanout in
      guard case .sharedMemory(let value) = scanout,
        value.sharedMemoryDescriptor.fileDescriptor >= 0
      else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
      return try body(value.lease, value.sharedMemoryDescriptor.fileDescriptor)
    }
  }

  public func withSharedTextureHandle<T>(
    _ body: (MTLSharedTextureHandle) throws -> T
  ) throws -> T {
    try scanoutLifetime.withValue { scanout in
      guard case .sharedTexture(let value) = scanout else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      return try body(value.sharedTextureHandle)
    }
  }

  public func withSharedTextureAuthority<T>(
    _ body: (DoryRendererSharedTextureScanoutLease, MTLSharedTextureHandle) throws -> T
  ) throws -> T {
    try scanoutLifetime.withValue { scanout in
      guard case .sharedTexture(let value) = scanout else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      return try body(value.lease, value.sharedTextureHandle)
    }
  }

  public func retire() {
    scanoutLifetime.retire()
  }

  fileprivate func didResolveHostSubmission(accepted: Bool) {
    recordHostSubmission?(accepted)
  }

  /// A host submission is not a displayed frame. Record only the first successful Metal
  /// completion for this exact update, after its renderer device generation is still current.
  public func recordPresentationCompleted(completionID: UInt64) {
    guard completionID > 0, isGenerationCurrent else { return }
    let callback = lock.withLock { () -> (@Sendable (UInt64) -> Void)? in
      guard !presentationCompletionRecorded else { return nil }
      presentationCompletionRecorded = true
      return recordPresentationCompletion
    }
    callback?(completionID)
  }
}

final class DoryPCBlobArenaAccessLifetime: @unchecked Sendable {
  private let condition = NSCondition()
  private var activeAccesses = 0
  private var retired = false

  func withAccess<T>(_ body: () throws -> T) throws -> T {
    condition.lock()
    guard !retired else {
      condition.unlock()
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    activeAccesses += 1
    condition.unlock()
    defer {
      condition.lock()
      activeAccesses -= 1
      if activeAccesses == 0 { condition.broadcast() }
      condition.unlock()
    }
    return try body()
  }

  func retire() {
    condition.lock()
    retired = true
    while activeAccesses != 0 { condition.wait() }
    condition.unlock()
  }
}

/// DoryPC adapter for the already-qualified signed renderer worker.
///
/// VirGL2 resources use bounded staging allocations. A worker generation that also authenticates
/// Venus and its host-visible arena gains blob features only because DoryPC exposes that same arena
/// through a generation-bound aperture; no guest pointer crosses XPC in either mode.
public final class DoryPCVirGLRendererAuthority: DoryVirtioGPUAccelerationAuthority,
  @unchecked Sendable
{
  // Match the worker's finite resource table and cap guest-driven pending completions before
  // they can retain an unbounded number of callbacks and shared-region authorities in the VMM.
  private static let maximumResources = 65_536
  private static let maximumPendingFences = 4_096
  public let capabilities: DoryVirtioGPUAccelerationCapabilities
  private let resourceLimit: Int
  private let pendingFenceLimit: Int

  private struct ActiveLane: Sendable {
    let lane: DoryRendererWorkerVirtioCommandLane
    let deviceGeneration: UInt64
  }

  private static let initialRendererDeviceGeneration: UInt64 = 1

  private var lane: DoryRendererWorkerVirtioCommandLane
  private let workspaceID: UUID
  /// BAR4 size is frozen by the PC machine's firmware/PCI composition across worker replacement.
  private let hostVisibleArenaByteCount: UInt64?
  private let producerFenceContract: DoryRendererProducerFenceContract
  private let venusFenceVerifier: VirtioGPUStockFenceVerifier?
  private let onVenusFenceVerification:
    (@Sendable (UInt64, VirtioGPUStockFenceVerificationOutcome) -> Void)?
  private let scanoutSink: (@Sendable (DoryPCVirGLScanoutUpdate) -> Bool)?
  private let onGenerationRevoked: (@Sendable () -> Void)?
  private let onWorkerUnavailable: (@Sendable (UInt64) -> Void)?
  private let graphicsTraceContext: VirtioGPUGraphicsTraceContext?
  private let onGraphicsTrace: (@Sendable (VirtioGPUGraphicsTraceEvent) -> Void)?
  private let graphicsTraceLock = NSLock()
  private var graphicsTraceSequence: UInt64 = 0
  private var graphicsFrameSequence: UInt64 = 0
  private struct PendingFenceKey: Hashable {
    let deviceGeneration: UInt64
    let hostFenceID: UInt64
  }

  private struct PendingFence {
    let guest: DoryVirtioGPUFenceRequest
    let completion: @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  }

  private let lock = NSLock()
  private let commandTimeout: TimeInterval
  private var deviceGeneration: UInt64
  private var active = true
  private var resetGeneration: UInt64 = 0
  private var replacementAdmissionResetGeneration: UInt64?
  private var retiringGeneration = false
  private var admittedCommand = false
  private var nextHostFenceID: UInt64 = 1
  private var pendingFences: [PendingFenceKey: PendingFence] = [:]
  private var resourceGenerations: [UInt32: UInt64] = [:]
  private var resourceProducerContexts: [UInt32: Set<UInt32>] = [:]
  private var venusFenceViolationObserved = false
  private var pendingResourceCreations: Set<UInt32> = []
  private var backings: [UInt32: DoryPCVirGLBackingAuthority] = [:]
  /// Retained independently of the machine stop callback: renderer failure can arrive while
  /// the PC machine is still being assembled, before that callback has been installed.
  private var hostVisibleAperture: DoryPCHostVisibleGPUAperture?
  private struct ScanoutLeaseKey: Hashable {
    let resourceID: UInt32
    let resourceGeneration: UInt64
    let deviceGeneration: UInt64
  }
  /// The worker refuses RESOURCE_UNREF while a scanout lease is live. Keep this separate from
  /// guest command completion: host presentation may finish after RESOURCE_FLUSH has replied.
  private let scanoutLeaseCondition = NSCondition()
  private var pendingScanoutLeases: [ScanoutLeaseKey: Int] = [:]
  private struct BlobAccess {
    let identity: DoryVirtioGPUBlobIdentity
    let lifetime: DoryPCBlobArenaAccessLifetime
  }
  private var blobAccesses: [UInt32: BlobAccess] = [:]

  public init(
    lane: DoryRendererWorkerVirtioCommandLane,
    deviceGeneration: UInt64,
    commandTimeout: TimeInterval = 6,
    resourceLimit: Int = 65_536,
    pendingFenceLimit: Int = 4_096,
    scanoutSink: (@Sendable (DoryPCVirGLScanoutUpdate) -> Bool)? = nil,
    onGenerationRevoked: (@Sendable () -> Void)? = nil,
    onWorkerUnavailable: (@Sendable (UInt64) -> Void)? = nil,
    onVenusFenceVerification:
      (@Sendable (UInt64, VirtioGPUStockFenceVerificationOutcome) -> Void)? = nil,
    graphicsTraceContext: VirtioGPUGraphicsTraceContext? = nil,
    onGraphicsTrace: (@Sendable (VirtioGPUGraphicsTraceEvent) -> Void)? = nil
  ) throws {
    guard deviceGeneration != 0, commandTimeout > 0,
      (1...Self.maximumResources).contains(resourceLimit),
      (1...Self.maximumPendingFences).contains(pendingFenceLimit)
    else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let virgl = lane.authenticatedCapsets.filter { $0.id == 2 }
    guard !virgl.isEmpty else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let venus = lane.authenticatedCapsets.filter { $0.id == 4 }
    let venusEnabled =
      lane.producerFenceContract == .doryPCX8664LinuxVenusPrepareFBV1
    guard !venusEnabled || (!venus.isEmpty && lane.hostVisibleArena != nil
        && (onGenerationRevoked != nil || onWorkerUnavailable != nil)),
      venusEnabled || lane.hostVisibleArena == nil
    else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let features: DoryVirtioFeatures =
      !venusEnabled
      ? [.gpuVirgl, .gpuResourceUUID, .gpuContextInit]
      : [.gpuVirgl, .gpuResourceUUID, .gpuResourceBlob, .gpuContextInit]
    capabilities = try DoryVirtioGPUAccelerationCapabilities(
      features: features,
      capsets: (venusEnabled ? virgl + venus : virgl).map {
        .init(id: $0.id, maximumVersion: $0.maxVersion, data: $0.data)
      }
    )
    self.lane = lane
    self.workspaceID = lane.workspaceID
    self.hostVisibleArenaByteCount = lane.hostVisibleArena?.byteCount
    self.producerFenceContract = lane.producerFenceContract
    venusFenceVerifier = venusEnabled
      ? VirtioGPUStockFenceVerifier(workerGeneration: lane.workerGeneration.rawValue)
      : nil
    self.onVenusFenceVerification = onVenusFenceVerification
    self.deviceGeneration = deviceGeneration
    self.commandTimeout = commandTimeout
    self.resourceLimit = resourceLimit
    self.pendingFenceLimit = pendingFenceLimit
    self.scanoutSink = scanoutSink
    self.onGenerationRevoked = onGenerationRevoked
    self.onWorkerUnavailable = onWorkerUnavailable
    self.graphicsTraceContext = graphicsTraceContext
    self.onGraphicsTrace = onGraphicsTrace
    installCallbacks(on: lane)
  }

  /// Select the live worker without quiescing guest commands or retiring GPU resources. The
  /// lane and broker recheck the generation and consume the opaque dispatch permit once.
  public func requestQualificationRendererCrash(
    _ admission: DoryRendererCrashQualificationAdmission,
    acknowledgement: @escaping @Sendable (Bool, UInt32) -> Void,
    interrupted: @escaping @Sendable () -> Void
  ) throws {
    let currentLane = try lock.withLock {
      guard active, !retiringGeneration, !venusFenceViolationObserved,
        admission.authority.policy.isRendererCrashOnly,
        admission.permits(workspaceID: workspaceID, workerGeneration: lane.workerGeneration.rawValue)
      else { throw DoryRuntimeQualificationFaultError.unauthorized }
      return lane
    }
    try currentLane.requestQualificationCrash(
      admission, acknowledgement: acknowledgement, interrupted: interrupted
    )
  }

  public func makeHostVisibleAperture() throws -> DoryPCHostVisibleGPUAperture? {
    guard capabilities.features.contains(.gpuResourceBlob) else { return nil }
    return try lock.withLock {
      guard active, let arena = lane.hostVisibleArena,
        arena.byteCount == hostVisibleArenaByteCount else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      if let hostVisibleAperture { return hostVisibleAperture }
      let aperture = try DoryPCHostVisibleGPUAperture(byteCount: arena.byteCount)
      hostVisibleAperture = aperture
      return aperture
    }
  }

  private func installCallbacks(on lane: DoryRendererWorkerVirtioCommandLane) {
    lane.installCallbacks(
      fence: { [weak self] generation, contextID, ringIndex, hostFenceID in
        self?.completeFence(
          deviceGeneration: generation,
          contextID: contextID,
          ringIndex: ringIndex,
          hostFenceID: hostFenceID
        )
      },
      runtimeFailure: { [weak self] generation, _ in
        self?.terminateUnknownOutcome(deviceGeneration: generation)
      }
    )
  }

  public func installReplacementAfterReset(
    lane replacementLane: DoryRendererWorkerVirtioCommandLane,
    expectedResetGeneration: UInt64? = nil
  ) throws {
    let virgl = replacementLane.authenticatedCapsets.filter { $0.id == 2 }
    let venus = replacementLane.authenticatedCapsets.filter { $0.id == 4 }
    let venusEnabled =
      replacementLane.producerFenceContract == .doryPCX8664LinuxVenusPrepareFBV1
    guard replacementLane.workspaceID == workspaceID,
      replacementLane.producerFenceContract == producerFenceContract,
      replacementLane.hostVisibleArena?.byteCount == hostVisibleArenaByteCount,
      !venusEnabled || (!venus.isEmpty && replacementLane.hostVisibleArena != nil),
      venusEnabled || replacementLane.hostVisibleArena == nil
    else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let features: DoryVirtioFeatures =
      !venusEnabled
      ? [.gpuVirgl, .gpuResourceUUID, .gpuContextInit]
      : [.gpuVirgl, .gpuResourceUUID, .gpuResourceBlob, .gpuContextInit]
    let replacementCapabilities = try DoryVirtioGPUAccelerationCapabilities(
      features: features,
      capsets: (venusEnabled ? virgl + venus : virgl).map {
        .init(id: $0.id, maximumVersion: $0.maxVersion, data: $0.data)
      }
    )
    guard replacementCapabilities == capabilities else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    try lock.withLock {
      guard !active, !retiringGeneration, blobAccesses.isEmpty,
        !venusFenceViolationObserved, replacementAdmissionResetGeneration == resetGeneration,
        replacementAdmissionResetGeneration != nil,
        expectedResetGeneration == nil || expectedResetGeneration == resetGeneration,
        replacementLane !== lane,
        replacementLane.workerGeneration.rawValue > lane.workerGeneration.rawValue,
        lane.waitForRetirement(timeout: 0) else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      let successor = deviceGeneration &+ 1
      guard successor != 0,
        replacementLane.rebindPristineDeviceGeneration(
          from: Self.initialRendererDeviceGeneration, to: successor)
      else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
      pendingFences.removeAll(keepingCapacity: false)
      resourceGenerations.removeAll(keepingCapacity: false)
      resourceProducerContexts.removeAll(keepingCapacity: false)
      pendingResourceCreations.removeAll(keepingCapacity: false)
      backings.removeAll(keepingCapacity: false)
      installCallbacks(on: replacementLane)
      lane = replacementLane
      deviceGeneration = successor
      venusFenceVerifier?.beginWorkerGeneration(replacementLane.workerGeneration.rawValue)
      nextHostFenceID = 1
      admittedCommand = false
      replacementAdmissionResetGeneration = nil
      active = true
    }
  }

  public func reset() {
    let revoked = lock.withLock {
      () -> (
        lane: DoryRendererWorkerVirtioCommandLane, deviceGeneration: UInt64,
        pending: [PendingFence], blobAccesses: [DoryPCBlobArenaAccessLifetime],
        aperture: DoryPCHostVisibleGPUAperture?
      )? in
      // Even an already-failed worker must observe the guest's explicit reset. A terminal XPC
      // event alone never grants permission to install underneath live guest resources.
      precondition(resetGeneration < .max)
      resetGeneration += 1
      replacementAdmissionResetGeneration = nil
      guard active else {
        if !retiringGeneration, !venusFenceViolationObserved {
          replacementAdmissionResetGeneration = resetGeneration
        }
        return nil
      }
      let source = deviceGeneration
      let sourceLane = lane
      active = false
      let successor = deviceGeneration &+ 1
      if successor != 0, !admittedCommand,
        sourceLane.rebindPristineDeviceGeneration(from: source, to: successor)
      {
        deviceGeneration = successor
        active = true
        return nil
      }
      retiringGeneration = true
      let accesses = blobAccesses.values.map(\.lifetime)
      blobAccesses.removeAll(keepingCapacity: false)
      resourceGenerations.removeAll(keepingCapacity: false)
      resourceProducerContexts.removeAll(keepingCapacity: false)
      pendingResourceCreations.removeAll(keepingCapacity: false)
      backings.removeAll(keepingCapacity: false)
      return (
        sourceLane,
        source,
        takePendingFencesLocked(deviceGeneration: source),
        accesses,
        hostVisibleAperture
      )
    }
    if let revoked {
      revoked.aperture?.reset()
      discardScanoutLeases(deviceGeneration: revoked.deviceGeneration)
      for access in revoked.blobAccesses { access.retire() }
      for pending in revoked.pending { pending.completion(.outcomeUnknown) }
      revoked.lane.revoke(deviceGeneration: revoked.deviceGeneration)
      lock.withLock {
        retiringGeneration = false
        if !active, !venusFenceViolationObserved {
          replacementAdmissionResetGeneration = resetGeneration
        }
      }
    }
  }

  /// True when this exact authenticated worker generation remains usable for a replacement PC
  /// machine after the guest requested a reset. A non-pristine reset revokes the one-shot worker;
  /// the machine owner must obtain a fresh daemon-authenticated renderer bootstrap before it can
  /// advertise accelerated graphics again.
  public var canBackReplacementMachineAfterReset: Bool {
    lock.withLock { active && !venusFenceViolationObserved }
  }

  public var acceptsGuestCommands: Bool {
    lock.withLock { active && !retiringGeneration && !venusFenceViolationObserved }
  }

  public var currentResetGeneration: UInt64 { lock.withLock { resetGeneration } }

  public func reportWorkerPresentationFailure(workerGeneration: UInt64) {
    guard let generation = lock.withLock({ () -> UInt64? in
      guard active, lane.workerGeneration.rawValue == workerGeneration else { return nil }
      return deviceGeneration
    }) else { return }
    terminateUnknownOutcome(deviceGeneration: generation)
  }

  public func createContext(id: UInt32, capsetID: UInt32, name: String) throws {
    let admitted = try admit()
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.createContext(
        contextID: id,
        capsetID: capsetID,
        name: name,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
  }

  public func destroyContext(id: UInt32) throws {
    let admitted = try admit()
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.destroyContext(
        contextID: id,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration else { return }
      for resourceID in Array(resourceProducerContexts.keys) {
        resourceProducerContexts[resourceID]?.remove(id)
      }
    }
  }

  public func createResource3D(_ resource: DoryVirtioGPUResource3D) throws {
    let admitted = try admit()
    let payload = try DoryRendererResource3DCreatePayload(
      target: resource.target,
      format: resource.format,
      bind: resource.bind,
      width: resource.width,
      height: resource.height,
      depth: resource.depth,
      arraySize: resource.arraySize,
      lastLevel: resource.lastLevel,
      samples: resource.samples,
      flags: resource.flags
    )
    try reserveResourceCreation(resource.resourceID, admitted: admitted)
    defer { releaseResourceCreation(resource.resourceID, admitted: admitted) }
    let resourceGeneration: UInt64 = try wait(deviceGeneration: admitted.deviceGeneration) {
      completion in
      try admitted.lane.createResource3D(
        resourceID: resource.resourceID,
        payload: payload,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    try commitResourceCreation(
      resource.resourceID, resourceGeneration: resourceGeneration, admitted: admitted)
  }

  public func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    try attachBacking(
      resourceID: resourceID, entries: entries, memory: memory, admitted: admit())
  }

  public func attachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    try attachBacking(
      resourceID: resourceID, entries: entries, memory: memory,
      admitted: admitBlobIdentity(resourceID: resourceID, identity: identity))
  }

  private func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory,
    admitted: ActiveLane
  ) throws {
    let resourceGeneration = try generation(for: resourceID, admitted: admitted)
    guard lock.withLock({ backings[resourceID] == nil }) else {
      throw DoryPCVirGLRendererAuthorityError.duplicateBacking(resourceID)
    }
    let backing = try DoryPCVirGLBackingAuthority(
      entries: entries,
      memory: memory,
      maximumByteCount: admitted.lane.maximumReferencedBytes
    )
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.attachBacking(
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        regions: backing.regions,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    try lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      backings[resourceID] = backing
    }
  }

  public func detachBacking(resourceID: UInt32) throws {
    try detachBacking(resourceID: resourceID, admitted: admit())
  }

  public func detachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    try detachBacking(
      resourceID: resourceID,
      admitted: admitBlobIdentity(resourceID: resourceID, identity: identity))
  }

  private func detachBacking(resourceID: UInt32, admitted: ActiveLane) throws {
    let resourceGeneration = try generation(for: resourceID, admitted: admitted)
    guard lock.withLock({ backings[resourceID] != nil }) else {
      throw DoryPCVirGLRendererAuthorityError.missingBacking(resourceID)
    }
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.detachBacking(
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration else { return }
      backings.removeValue(forKey: resourceID)
    }
  }

  public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
    let admitted = try admit()
    let resourceGeneration = try generation(for: resourceID, admitted: admitted)
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.attachResource(
        contextID: contextID,
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration,
        resourceGenerations[resourceID] == resourceGeneration else { return }
      resourceProducerContexts[resourceID, default: []].insert(contextID)
    }
  }

  public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
    let admitted = try admit()
    let resourceGeneration = try generation(for: resourceID, admitted: admitted)
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.detachResource(
        contextID: contextID,
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration,
        resourceGenerations[resourceID] == resourceGeneration else { return }
      resourceProducerContexts[resourceID]?.remove(contextID)
    }
  }

  public func submit3D(contextID: UInt32, command: [UInt8]) throws {
    let admitted = try admit()
    let regions = try DoryRendererWorkerSharedRegionSet.immutableSubmit3D(
      bytes: command,
      maximumByteCount: DoryRendererWorkerLimits.production.maximumCommandBytes
    )
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.submit3D(
        contextID: contextID,
        regions: regions,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
  }

  public func submit3D(
    contextID: UInt32,
    command: [UInt8],
    fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws {
    let admitted = try admit()
    let regions = try DoryRendererWorkerSharedRegionSet.immutableSubmit3D(
      bytes: command,
      maximumByteCount: DoryRendererWorkerLimits.production.maximumCommandBytes
    )
    let hostFenceID = try reserveHostFence(
      deviceGeneration: admitted.deviceGeneration,
      guest: fence,
      completion: completion
    )
    do {
      try admitted.lane.submit3DThenCreateFence(
        contextID: contextID,
        regions: regions,
        ringIndex: fence.contextFence ? fence.ringIndex : 0,
        fenceID: hostFenceID,
        contextFence: fence.contextFence,
        deviceGeneration: admitted.deviceGeneration
      ) { [weak self] disposition in
        switch disposition {
        case .fenceArmed:
          return
        case .provenRejected:
          self?.finishFence(
            deviceGeneration: admitted.deviceGeneration,
            hostFenceID: hostFenceID,
            result: .rejected
          )
        case .outcomeUnknown:
          self?.finishFence(
            deviceGeneration: admitted.deviceGeneration,
            hostFenceID: hostFenceID,
            result: .outcomeUnknown
          )
        }
      }
    } catch {
      removeFence(deviceGeneration: admitted.deviceGeneration, hostFenceID: hostFenceID)
      throw error
    }
  }

  public func createFence(
    _ fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws {
    let admitted = try admit()
    let hostFenceID = try reserveHostFence(
      deviceGeneration: admitted.deviceGeneration,
      guest: fence,
      completion: completion
    )
    do {
      let fenceCompletion: DoryRendererWorkerVirtioCommandLane.Completion = { [weak self] result in
        guard case .failure = result else { return }
        self?.finishFence(
          deviceGeneration: admitted.deviceGeneration,
          hostFenceID: hostFenceID,
          result: .outcomeUnknown
        )
      }
      if fence.contextFence {
        try admitted.lane.createContextFence(
          contextID: fence.contextID,
          ringIndex: fence.ringIndex,
          fenceID: hostFenceID,
          deviceGeneration: admitted.deviceGeneration,
          completion: fenceCompletion
        )
      } else {
        try admitted.lane.createGlobalFence(
          fenceID: hostFenceID,
          deviceGeneration: admitted.deviceGeneration,
          completion: fenceCompletion
        )
      }
    } catch {
      removeFence(deviceGeneration: admitted.deviceGeneration, hostFenceID: hostFenceID)
      throw error
    }
  }

  public func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    let admitted = try admit()
    let (resourceGeneration, backing) = try generationAndBacking(
      for: transfer.resourceID,
      admitted: admitted
    )
    guard backing.entries == entries else {
      throw DoryPCVirGLRendererAuthorityError.missingBacking(transfer.resourceID)
    }
    try backing.withTransferLock {
      // Refresh the staging file before both transfer directions. A readback then copies only
      // the worker-changed bytes back to guest memory, so unrelated guest/DMA changes outside
      // the renderer output are not overwritten by the stale attach-time snapshot.
      // The guest must leave the transfer's output region untouched until completion. Bytes
      // the renderer leaves equal to the baseline already hold the requested output there.
      try backing.synchronizeFromGuest(memory)
      let readbackBaseline =
        transfer.direction == .fromHost
        ? backing.snapshotBytes()
        : nil
      let payload = try DoryRendererTransfer3DPayload(
        level: transfer.level,
        stride: transfer.stride,
        layerStride: transfer.layerStride,
        offset: transfer.offset,
        x: transfer.x,
        y: transfer.y,
        z: transfer.z,
        width: transfer.width,
        height: transfer.height,
        depth: transfer.depth
      )
      try wait(deviceGeneration: admitted.deviceGeneration) { completion in
        switch transfer.direction {
        case .toHost:
          try admitted.lane.transferToHost3D(
            resourceID: transfer.resourceID,
            resourceGeneration: resourceGeneration,
            contextID: transfer.contextID,
            payload: payload,
            deviceGeneration: admitted.deviceGeneration,
            completion: completion
          )
        case .fromHost:
          try admitted.lane.transferFromHost3D(
            resourceID: transfer.resourceID,
            resourceGeneration: resourceGeneration,
            contextID: transfer.contextID,
            payload: payload,
            deviceGeneration: admitted.deviceGeneration,
            completion: completion
          )
        }
      }
      if let readbackBaseline {
        try backing.synchronizeChangedBytesToGuest(
          memory,
          comparedTo: readbackBaseline
        )
      }
    }
  }

  public func flushResource(_ scanouts: [DoryVirtioGPUAcceleratedScanoutFlush]) throws {
    guard !scanouts.isEmpty, let scanoutSink else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let admitted = try admit()
    var updates: [DoryPCVirGLScanoutUpdate] = []
    var acceptedCount = 0
    updates.reserveCapacity(scanouts.count)
    do {
      for flush in scanouts {
        if flush.blobIdentity != nil, !capabilities.features.contains(.gpuResourceBlob) {
          throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        let resourceGeneration = try generation(for: flush.resourceID, admitted: admitted)
        if let identity = flush.blobIdentity {
          guard identity.workspaceID == admitted.lane.workspaceID,
            identity.resourceGeneration == resourceGeneration,
            identity.workerGeneration == admitted.lane.workerGeneration.rawValue,
            identity.deviceGeneration == admitted.deviceGeneration
          else { throw DoryVirtioGPUAccelerationError.generationRevoked }
        }
        guard flush.storageOffset <= UInt64(UInt32.max) else {
          throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        let stride = try resolvedStride(for: flush)
        let scanout = try waitScanout(deviceGeneration: admitted.deviceGeneration) { completion in
          try admitted.lane.acquireScanoutLease(
            resourceID: flush.resourceID,
            resourceGeneration: resourceGeneration,
            width: flush.resourceWidth,
            height: flush.resourceHeight,
            virglFormat: flush.virglFormat,
            stride: stride,
            storageOffset: UInt32(flush.storageOffset),
            deviceGeneration: admitted.deviceGeneration,
            completion: completion
          )
        }
        guard isCurrentResource(
          flush.resourceID,
          generation: resourceGeneration,
          admitted: admitted
        ) else {
          scanout.discardTransport()
          throw DoryVirtioGPUAccelerationError.generationRevoked
        }
        let leaseKey = ScanoutLeaseKey(
          resourceID: flush.resourceID,
          resourceGeneration: resourceGeneration,
          deviceGeneration: admitted.deviceGeneration
        )
        registerScanoutLease(leaseKey)
        let frameSequence = nextGraphicsFrameSequence()
        let update = DoryPCVirGLScanoutUpdate(
          flush: flush,
          scanout: scanout,
          release: { [weak self] scanout in
            guard let self else {
              scanout.discardTransport()
              return
            }
            self.releaseScanout(scanout, key: leaseKey, admitted: admitted)
          },
          recordHostSubmission: { [weak self] accepted in
            self?.recordGraphicsTrace(
              stage: accepted ? .hostSubmissionAccepted : .hostSubmissionRejected,
              workerGeneration: admitted.lane.workerGeneration.rawValue,
              resourceID: flush.resourceID,
              displayResourceGeneration: resourceGeneration,
              rendererResourceGeneration: scanout.resourceGeneration,
              deviceGeneration: admitted.deviceGeneration,
              frameSequence: frameSequence,
              scanoutID: flush.scanoutID,
              width: flush.resourceWidth,
              height: flush.resourceHeight,
              stride: stride,
              format: flush.virglFormat
            )
          },
          recordPresentationCompletion: { [weak self] completionID in
            guard self?.isCurrentGeneration(admitted: admitted) == true else { return }
            self?.recordGraphicsTrace(
              stage: .metalPresentationCompleted,
              workerGeneration: admitted.lane.workerGeneration.rawValue,
              resourceID: flush.resourceID,
              displayResourceGeneration: resourceGeneration,
              rendererResourceGeneration: scanout.resourceGeneration,
              deviceGeneration: admitted.deviceGeneration,
              frameSequence: frameSequence,
              metalCommandBufferCompletionID: completionID,
              scanoutID: flush.scanoutID,
              width: flush.resourceWidth,
              height: flush.resourceHeight,
              stride: stride,
              format: flush.virglFormat
            )
          },
          isCurrentResource: { [weak self] in
            self?.isCurrentResource(
              flush.resourceID,
              generation: resourceGeneration,
              admitted: admitted
            ) == true
          },
          isCurrentGeneration: { [weak self] in
            self?.isCurrentGeneration(admitted: admitted) == true
          }
        )
        recordGraphicsTrace(
          stage: .scanoutPublished,
          workerGeneration: admitted.lane.workerGeneration.rawValue,
          resourceID: flush.resourceID,
          displayResourceGeneration: resourceGeneration,
          rendererResourceGeneration: scanout.resourceGeneration,
          deviceGeneration: admitted.deviceGeneration,
          frameSequence: frameSequence,
          scanoutID: flush.scanoutID,
          width: flush.resourceWidth,
          height: flush.resourceHeight,
          stride: stride,
          format: flush.virglFormat
        )
        updates.append(update)
      }
      for update in updates {
        guard update.isCurrent else {
          throw DoryVirtioGPUAccelerationError.generationRevoked
        }
        let accepted = scanoutSink(update)
        update.didResolveHostSubmission(accepted: accepted)
        guard accepted else {
          throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        acceptedCount += 1
        guard update.isGenerationCurrent else {
          throw DoryVirtioGPUAccelerationError.generationRevoked
        }
      }
    } catch {
      // Accepted updates belong to the display until it retires them.
      for update in updates.dropFirst(acceptedCount) { update.retire() }
      throw error
    }
  }

  public func createBlob(
    _ resource: DoryVirtioGPUBlobResource,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioGPUBlobIdentity {
    guard capabilities.features.contains(.gpuResourceBlob) else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let admitted = try admit()
    guard admitted.lane.hostVisibleArena != nil,
      resource.resourceID != 0
    else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let payload = try DoryRendererBlobCreatePayload(
      blobMemory: resource.blobMemory,
      blobFlags: resource.blobFlags,
      blobID: resource.blobID,
      size: resource.size
    )
    try reserveResourceCreation(resource.resourceID, admitted: admitted)
    defer { releaseResourceCreation(resource.resourceID, admitted: admitted) }
    let backing: DoryPCVirGLBackingAuthority?
    let regions: DoryRendererWorkerSharedRegionSet
    if entries.isEmpty {
      backing = nil
      regions = .init(references: [], descriptors: [])
    } else {
      let created = try DoryPCVirGLBackingAuthority(
        entries: entries,
        memory: memory,
        maximumByteCount: admitted.lane.maximumReferencedBytes
      )
      backing = created
      regions = created.regions
    }
    let resourceGeneration: UInt64 = try wait(
      deviceGeneration: admitted.deviceGeneration
    ) { completion in
      try admitted.lane.createBlob(
        resourceID: resource.resourceID,
        contextID: resource.contextID,
        payload: payload,
        regions: regions,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    try commitResourceCreation(
      resource.resourceID, resourceGeneration: resourceGeneration, admitted: admitted,
      backing: backing,
      producerContextID: resource.contextID == 0 ? nil : resource.contextID)
    return .init(
      workspaceID: admitted.lane.workspaceID,
      resourceGeneration: resourceGeneration,
      workerGeneration: admitted.lane.workerGeneration.rawValue,
      deviceGeneration: admitted.deviceGeneration
    )
  }

  public func mapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    hostVisibleOffset: UInt64
  ) throws -> DoryVirtioGPUBlobMapping {
    guard capabilities.features.contains(.gpuResourceBlob) else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let admitted = try admitBlobIdentity(resourceID: resourceID, identity: identity)
    guard let arena = admitted.lane.hostVisibleArena else {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    let mapping: DoryRendererWorkerBlobMapping = try wait(
      deviceGeneration: admitted.deviceGeneration
    ) { completion in
      try admitted.lane.mapBlob(
        resourceID: resourceID,
        resourceGeneration: identity.resourceGeneration,
        hostVisibleOffset: hostVisibleOffset,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    let lease = mapping.lease
    guard lease.storage == .generationArena,
      mapping.sharedMemoryDescriptor == nil,
      lease.workerGeneration == admitted.lane.workerGeneration,
      lease.resourceID == resourceID,
      lease.resourceGeneration == identity.resourceGeneration,
      lease.arenaOffset == hostVisibleOffset,
      lease.declaredFileSize == arena.byteCount,
      arena.byteCount <= UInt64(Int.max),
      lease.mappingByteCount <= UInt64(Int.max),
      lease.arenaOffset <= arena.byteCount,
      lease.mappingByteCount <= arena.byteCount - lease.arenaOffset
    else {
      try? mapping.sharedMemoryDescriptor?.close()
      // The worker has already accepted MAP_BLOB. A malformed lease makes its backing lifetime
      // unknowable, so revoke this generation rather than return with an untracked worker map.
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    let accessLifetime = DoryPCBlobArenaAccessLifetime()
    let accessLock = NSLock()
    let memoryRegion = DoryVirtioGPUBlobMemoryRegion(
      byteCount: lease.mappingByteCount,
      read: { offset, byteCount in
        guard offset <= lease.mappingByteCount,
          UInt64(byteCount) <= lease.mappingByteCount - offset
        else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return try accessLifetime.withAccess {
          accessLock.withLock {
            Array(UnsafeRawBufferPointer(
              start: arena.baseAddress.advanced(by: Int(lease.arenaOffset + offset)),
              count: byteCount
            ))
          }
        }
      },
      write: { offset, bytes in
        guard offset <= lease.mappingByteCount,
          UInt64(bytes.count) <= lease.mappingByteCount - offset
        else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        try accessLifetime.withAccess {
          accessLock.withLock {
            bytes.withUnsafeBytes { source in
              guard let baseAddress = source.baseAddress else { return }
              arena.baseAddress.advanced(by: Int(lease.arenaOffset + offset)).copyMemory(
                from: baseAddress,
                byteCount: bytes.count
              )
            }
          }
        }
      },
      compareExchange: { offset, expected, desired, byteCount in
        guard [1, 2, 4, 8].contains(byteCount),
          offset <= lease.mappingByteCount,
          UInt64(byteCount) <= lease.mappingByteCount - offset
        else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
        return try accessLifetime.withAccess {
          accessLock.withLock {
            let address = arena.baseAddress.advanced(by: Int(lease.arenaOffset + offset))
              .assumingMemoryBound(to: UInt8.self)
            var observed: UInt64 = 0
            for index in 0..<byteCount {
              observed |= UInt64(address[index]) << UInt64(index * 8)
            }
            let mask = byteCount == 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
            if observed == expected & mask {
              for index in 0..<byteCount {
                address[index] = UInt8(truncatingIfNeeded: desired >> UInt64(index * 8))
              }
            }
            return observed
          }
        }
      }
    )
    let installed = lock.withLock { () -> Bool in
      guard active, deviceGeneration == admitted.deviceGeneration,
        resourceGenerations[resourceID] == identity.resourceGeneration,
        blobAccesses[resourceID] == nil
      else { return false }
      blobAccesses[resourceID] = .init(identity: identity, lifetime: accessLifetime)
      return true
    }
    guard installed else {
      accessLifetime.retire()
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    return .init(
      workspaceID: admitted.lane.workspaceID,
      resourceID: resourceID,
      resourceGeneration: identity.resourceGeneration,
      workerGeneration: lease.workerGeneration.rawValue,
      deviceGeneration: admitted.deviceGeneration,
      hostVisibleOffset: hostVisibleOffset,
      byteCount: lease.mappingByteCount,
      mapInfo: lease.mapInfo,
      memory: memoryRegion
    )
  }

  public func unmapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    beforeRendererUnmap: @escaping @Sendable () -> Bool
  ) throws {
    let admitted = try admitBlobIdentity(resourceID: resourceID, identity: identity)
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.unmapBlob(
        resourceID: resourceID,
        resourceGeneration: identity.resourceGeneration,
        deviceGeneration: admitted.deviceGeneration,
        beforeWorkerUnmap: { [weak self] in
          guard beforeRendererUnmap() else { return false }
          return self?.retireBlobAccess(
            resourceID: resourceID, identity: identity, admitted: admitted) == true
        },
        completion: completion
      )
    }
  }

  public func flushBlobResource(_ scanouts: [DoryVirtioGPUBlobScanoutFlush]) throws {
    guard capabilities.features.contains(.gpuResourceBlob) else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    guard let first = scanouts.first,
      scanouts.allSatisfy({ $0.resourceID == first.resourceID && $0.identity == first.identity }),
      let venusFenceVerifier
    else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
    let observation = try lock.withLock { () throws -> (
      generation: UInt64,
      contextID: UInt32,
      violation: VirtioGPUStockFenceVerificationOutcome?
    ) in
      guard active, !venusFenceViolationObserved,
        let contexts = resourceProducerContexts[first.resourceID],
        contexts.count == 1, let contextID = contexts.first,
        resourceGenerations[first.resourceID] == first.identity.resourceGeneration,
        first.identity.workspaceID == workspaceID,
        first.identity.workerGeneration == lane.workerGeneration.rawValue,
        first.identity.deviceGeneration == deviceGeneration
      else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
      let producerFencePending = pendingFences.values.contains {
        $0.guest.contextFence && $0.guest.contextID == contextID
      }
      // A pending producer fence is an immediate ordering failure. Clean flushes count only
      // after the renderer lease and the app presentation consumer both accept the frame.
      let violation: VirtioGPUStockFenceVerificationOutcome?
      if producerFencePending {
        _ = venusFenceVerifier.observeScanoutBlobFlush(
          resourceID: first.resourceID,
          resourceGeneration: first.identity.resourceGeneration,
          producerFencePending: true,
          workerGeneration: lane.workerGeneration.rawValue
        )
        // The verifier intentionally retains only the first bounded proof window. A later
        // ordering regression is still unsafe, even after that window reached `.verified`.
        violation = .violated
        venusFenceViolationObserved = true
      } else {
        violation = nil
      }
      return (deviceGeneration, contextID, violation)
    }
    if observation.violation == .violated {
      onVenusFenceVerification?(first.identity.workerGeneration, .violated)
      terminateUnknownOutcome(deviceGeneration: observation.generation)
      throw DoryPCVirGLRendererAuthorityError.producerFenceViolation
    }
    let accelerated = try scanouts.map { flush in
      let format: UInt32
      switch flush.format {
      case 1, 2: format = 1
      case 67, 68: format = 67
      default: throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      return DoryVirtioGPUAcceleratedScanoutFlush(
        scanoutID: flush.scanoutID,
        resourceID: flush.resourceID,
        sourceRectangle: flush.sourceRectangle,
        damagedRectangle: flush.damagedRectangle,
        resourceWidth: flush.width,
        resourceHeight: flush.height,
        virglFormat: format,
        stride: flush.stride,
        storageOffset: UInt64(flush.offset),
        blobIdentity: flush.identity
      )
    }
    try flushResource(accelerated)
    let outcome = lock.withLock { () -> VirtioGPUStockFenceVerificationOutcome? in
      guard active, !venusFenceViolationObserved,
        deviceGeneration == observation.generation,
        resourceGenerations[first.resourceID] == first.identity.resourceGeneration,
        resourceProducerContexts[first.resourceID] == [observation.contextID],
        lane.workerGeneration.rawValue == first.identity.workerGeneration
      else { return nil }
      return venusFenceVerifier.observeScanoutBlobFlush(
        resourceID: first.resourceID,
        resourceGeneration: first.identity.resourceGeneration,
        producerFencePending: false,
        workerGeneration: first.identity.workerGeneration
      )
    }
    if let outcome {
      onVenusFenceVerification?(first.identity.workerGeneration, outcome)
    }
  }

  public func unrefResource(resourceID: UInt32) throws {
    try unrefResource(
      resourceID: resourceID, expectedBlobIdentity: nil, admitted: admit())
  }

  public func unrefBlobResource(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    let admitted = try admitBlobIdentity(resourceID: resourceID, identity: identity)
    try unrefResource(
      resourceID: resourceID, expectedBlobIdentity: identity, admitted: admitted)
  }

  private func admitBlobIdentity(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws -> ActiveLane {
    let admitted: ActiveLane
    do { admitted = try admit() }
    catch { throw DoryVirtioGPUAccelerationError.generationRevoked }
    guard identity.workspaceID == admitted.lane.workspaceID,
      identity.deviceGeneration == admitted.deviceGeneration,
      identity.workerGeneration == admitted.lane.workerGeneration.rawValue,
      (try? generation(for: resourceID, admitted: admitted)) == identity.resourceGeneration
    else { throw DoryVirtioGPUAccelerationError.generationRevoked }
    return admitted
  }

  private func unrefResource(
    resourceID: UInt32,
    expectedBlobIdentity: DoryVirtioGPUBlobIdentity?,
    admitted: ActiveLane
  ) throws {
    let resourceGeneration = try generation(for: resourceID, admitted: admitted)
    if let expectedBlobIdentity {
      guard expectedBlobIdentity.workspaceID == admitted.lane.workspaceID,
        expectedBlobIdentity.deviceGeneration == admitted.deviceGeneration,
        expectedBlobIdentity.workerGeneration == admitted.lane.workerGeneration.rawValue,
        expectedBlobIdentity.resourceGeneration == resourceGeneration
      else { throw DoryVirtioGPUAccelerationError.generationRevoked }
    }
    let staleAccess = lock.withLock { () -> BlobAccess? in
      guard blobAccesses[resourceID]?.identity.workspaceID == admitted.lane.workspaceID,
        blobAccesses[resourceID]?.identity.resourceGeneration == resourceGeneration,
        deviceGeneration == admitted.deviceGeneration
      else { return nil }
      return blobAccesses[resourceID]
    }
    if let staleAccess {
      guard retireBlobAccess(
        resourceID: resourceID, identity: staleAccess.identity, admitted: admitted
      ) else { throw DoryVirtioGPUAccelerationError.generationRevoked }
    }
    try waitForScanoutLeaseRetirement(
      resourceID: resourceID,
      resourceGeneration: resourceGeneration,
      admitted: admitted
    )
    try wait(deviceGeneration: admitted.deviceGeneration) { completion in
      try admitted.lane.unrefResource(
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        deviceGeneration: admitted.deviceGeneration,
        completion: completion
      )
    }
    let committed = lock.withLock { () -> Bool in
      guard active, deviceGeneration == admitted.deviceGeneration,
        resourceGenerations[resourceID] == resourceGeneration
      else { return false }
      resourceGenerations.removeValue(forKey: resourceID)
      resourceProducerContexts.removeValue(forKey: resourceID)
      backings.removeValue(forKey: resourceID)
      return true
    }
    guard committed else {
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
  }

  private func registerScanoutLease(_ key: ScanoutLeaseKey) {
    scanoutLeaseCondition.withLock {
      pendingScanoutLeases[key, default: 0] += 1
    }
  }

  private func finishScanoutLease(_ key: ScanoutLeaseKey) {
    scanoutLeaseCondition.lock()
    if let count = pendingScanoutLeases[key] {
      if count == 1 {
        pendingScanoutLeases.removeValue(forKey: key)
      } else {
        pendingScanoutLeases[key] = count - 1
      }
      scanoutLeaseCondition.broadcast()
    }
    scanoutLeaseCondition.unlock()
  }

  private func discardScanoutLeases(deviceGeneration: UInt64) {
    scanoutLeaseCondition.lock()
    pendingScanoutLeases = pendingScanoutLeases.filter {
      $0.key.deviceGeneration != deviceGeneration
    }
    scanoutLeaseCondition.broadcast()
    scanoutLeaseCondition.unlock()
  }

  private func waitForScanoutLeaseRetirement(
    resourceID: UInt32,
    resourceGeneration: UInt64,
    admitted: ActiveLane
  ) throws {
    let key = ScanoutLeaseKey(
      resourceID: resourceID,
      resourceGeneration: resourceGeneration,
      deviceGeneration: admitted.deviceGeneration
    )
    let deadline = Date(timeIntervalSinceNow: commandTimeout)
    scanoutLeaseCondition.lock()
    while pendingScanoutLeases[key] != nil {
      if !scanoutLeaseCondition.wait(until: deadline) { break }
    }
    let timedOut = pendingScanoutLeases[key] != nil
    scanoutLeaseCondition.unlock()
    if timedOut {
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      throw DoryPCVirGLRendererAuthorityError.commandTimedOut
    }
    guard isCurrentGeneration(admitted: admitted) else {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
  }

  private func admit() throws -> ActiveLane {
    try lock.withLock {
      guard active, !venusFenceViolationObserved else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      admittedCommand = true
      return ActiveLane(lane: lane, deviceGeneration: deviceGeneration)
    }
  }

  private func reserveResourceCreation(_ resourceID: UInt32, admitted: ActiveLane) throws {
    try lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      guard resourceGenerations[resourceID] == nil,
        !pendingResourceCreations.contains(resourceID)
      else { throw DoryPCVirGLRendererAuthorityError.duplicateResource(resourceID) }
      guard resourceGenerations.count + pendingResourceCreations.count < resourceLimit
      else { throw DoryVirtioGPUAccelerationError.resourceLimitExceeded }
      pendingResourceCreations.insert(resourceID)
    }
  }

  private func releaseResourceCreation(_ resourceID: UInt32, admitted: ActiveLane) {
    lock.withLock {
      guard deviceGeneration == admitted.deviceGeneration else { return }
      pendingResourceCreations.remove(resourceID)
    }
  }

  private func commitResourceCreation(
    _ resourceID: UInt32,
    resourceGeneration: UInt64,
    admitted: ActiveLane,
    backing: DoryPCVirGLBackingAuthority? = nil,
    producerContextID: UInt32? = nil
  ) throws {
    let committed = lock.withLock { () -> Bool in
      guard active, deviceGeneration == admitted.deviceGeneration,
        pendingResourceCreations.contains(resourceID),
        resourceGenerations[resourceID] == nil,
        resourceGeneration != 0
      else { return false }
      resourceGenerations[resourceID] = resourceGeneration
      if let producerContextID {
        resourceProducerContexts[resourceID] = [producerContextID]
      }
      if let backing { backings[resourceID] = backing }
      pendingResourceCreations.remove(resourceID)
      return true
    }
    guard committed else {
      // The worker has accepted a resource which this authority cannot own. The same worker
      // generation must not remain usable with an untracked resource or a reused guest ID.
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
  }

  private func generation(for resourceID: UInt32, admitted: ActiveLane) throws -> UInt64 {
    guard
      let generation = lock.withLock({ () -> UInt64? in
        guard active, deviceGeneration == admitted.deviceGeneration else { return nil }
        return resourceGenerations[resourceID]
      })
    else {
      throw DoryPCVirGLRendererAuthorityError.unknownResource(resourceID)
    }
    return generation
  }

  private func isCurrentResource(
    _ resourceID: UInt32,
    generation: UInt64,
    admitted: ActiveLane
  ) -> Bool {
    lock.withLock {
      active && !venusFenceViolationObserved && deviceGeneration == admitted.deviceGeneration
        && admitted.lane.workspaceID == workspaceID
        && resourceGenerations[resourceID] == generation
    }
  }

  private func isCurrentGeneration(admitted: ActiveLane) -> Bool {
    lock.withLock {
      active && !venusFenceViolationObserved && deviceGeneration == admitted.deviceGeneration
        && admitted.lane.workspaceID == workspaceID
    }
  }

  private func retireBlobAccess(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    admitted: ActiveLane
  ) -> Bool {
    let access = lock.withLock { () -> DoryPCBlobArenaAccessLifetime? in
      guard active, deviceGeneration == admitted.deviceGeneration,
        blobAccesses[resourceID]?.identity == identity
      else { return nil }
      return blobAccesses[resourceID]?.lifetime
    }
    guard let access else { return false }
    access.retire()
    return lock.withLock {
      guard active, deviceGeneration == admitted.deviceGeneration,
        blobAccesses[resourceID]?.lifetime === access
      else { return false }
      blobAccesses.removeValue(forKey: resourceID)
      return true
    }
  }

  private func generationAndBacking(
    for resourceID: UInt32,
    admitted: ActiveLane
  ) throws -> (generation: UInt64, backing: DoryPCVirGLBackingAuthority) {
    guard
      let admitted = lock.withLock({ () -> (UInt64, DoryPCVirGLBackingAuthority)? in
        guard active, deviceGeneration == admitted.deviceGeneration,
          let generation = resourceGenerations[resourceID],
          let backing = backings[resourceID]
        else {
          return nil
        }
        return (generation, backing)
      })
    else {
      throw DoryPCVirGLRendererAuthorityError.missingBacking(resourceID)
    }
    return admitted
  }

  private func reserveHostFence(
    deviceGeneration: UInt64,
    guest: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) throws -> UInt64 {
    try lock.withLock {
      guard active, self.deviceGeneration == deviceGeneration else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      guard pendingFences.count < pendingFenceLimit else {
        throw DoryVirtioGPUAccelerationError.resourceLimitExceeded
      }
      // Private tokens are also the admission order. Never wrap or reuse one within a device
      // generation: a delayed worker callback must not acquire a later obligation's identity.
      guard nextHostFenceID < .max else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      let candidate = nextHostFenceID
      nextHostFenceID += 1
      let key = PendingFenceKey(
        deviceGeneration: deviceGeneration,
        hostFenceID: candidate
      )
      pendingFences[key] = PendingFence(
        guest: guest,
        completion: completion
      )
      return candidate
    }
  }

  private func completeFence(
    deviceGeneration: UInt64,
    contextID: UInt32,
    ringIndex: UInt32,
    hostFenceID: UInt64
  ) {
    let key = PendingFenceKey(
      deviceGeneration: deviceGeneration,
      hostFenceID: hostFenceID
    )
    let completed = lock.withLock { () -> [PendingFence] in
      guard active, self.deviceGeneration == deviceGeneration,
        let target = pendingFences[key]
      else { return [] }
      let matchesCallbackTimeline =
        target.guest.contextFence
        ? target.guest.contextID == contextID && target.guest.ringIndex == ringIndex
        : contextID == 0 && ringIndex == 0
      guard matchesCallbackTimeline else { return [] }
      let completedKeys: [PendingFenceKey]
      if target.guest.contextFence {
        completedKeys = pendingFences.compactMap { candidateKey, pending -> PendingFenceKey? in
          guard candidateKey.deviceGeneration == deviceGeneration,
            sameGuestTimeline(pending.guest, target.guest),
            candidateKey.hostFenceID <= key.hostFenceID
          else { return nil }
          return candidateKey
        }
      } else {
        completedKeys = [key]
      }
      // Guest IDs are opaque (including zero and wraparound). Only earlier host admissions on
      // this exact context/ring may coalesce; deliver them in that order outside the lock.
      return completedKeys.sorted { $0.hostFenceID < $1.hostFenceID }
        .compactMap { pendingFences.removeValue(forKey: $0) }
    }
    for pending in completed { pending.completion(.signaled) }
  }

  private func sameGuestTimeline(
    _ lhs: DoryVirtioGPUFenceRequest,
    _ rhs: DoryVirtioGPUFenceRequest
  ) -> Bool {
    guard lhs.contextFence == rhs.contextFence else { return false }
    return lhs.contextFence
      ? lhs.contextID == rhs.contextID && lhs.ringIndex == rhs.ringIndex
      : true
  }

  private func removeFence(deviceGeneration: UInt64, hostFenceID: UInt64) {
    let key = PendingFenceKey(
      deviceGeneration: deviceGeneration,
      hostFenceID: hostFenceID
    )
    _ = lock.withLock { pendingFences.removeValue(forKey: key) }
  }

  private func finishFence(
    deviceGeneration: UInt64,
    hostFenceID: UInt64,
    result: DoryVirtioGPUFenceCompletion
  ) {
    let key = PendingFenceKey(
      deviceGeneration: deviceGeneration,
      hostFenceID: hostFenceID
    )
    let pending = lock.withLock { pendingFences.removeValue(forKey: key) }
    pending?.completion(result)
  }

  private func takePendingFencesLocked(deviceGeneration: UInt64) -> [PendingFence] {
    let matches = pendingFences.filter { $0.key.deviceGeneration == deviceGeneration }
    for key in matches.keys { pendingFences.removeValue(forKey: key) }
    return Array(matches.values)
  }

  private func nextGraphicsFrameSequence() -> UInt64? {
    guard graphicsTraceContext != nil, onGraphicsTrace != nil else { return nil }
    return graphicsTraceLock.withLock {
      graphicsFrameSequence &+= 1
      return graphicsFrameSequence
    }
  }

  private func recordGraphicsTrace(
    stage: VirtioGPUGraphicsTraceEvent.Stage,
    workerGeneration: UInt64,
    resourceID: UInt32? = nil,
    displayResourceGeneration: UInt64? = nil,
    rendererResourceGeneration: UInt64? = nil,
    deviceGeneration: UInt64? = nil,
    frameSequence: UInt64? = nil,
    metalCommandBufferCompletionID: UInt64? = nil,
    scanoutID: UInt32? = nil,
    width: UInt32? = nil,
    height: UInt32? = nil,
    stride: UInt32? = nil,
    format: UInt32? = nil
  ) {
    guard let graphicsTraceContext, let onGraphicsTrace else { return }
    let event = graphicsTraceLock.withLock { () -> VirtioGPUGraphicsTraceEvent in
      graphicsTraceSequence &+= 1
      return VirtioGPUGraphicsTraceEvent(
        sequence: graphicsTraceSequence,
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
        context: VirtioGPUGraphicsTraceContext(
          machineID: graphicsTraceContext.machineID,
          operationID: graphicsTraceContext.operationID,
          workerGeneration: workerGeneration
        ),
        stage: stage,
        resourceID: resourceID,
        displayResourceGeneration: displayResourceGeneration,
        rendererResourceGeneration: rendererResourceGeneration,
        deviceGeneration: deviceGeneration,
        frameSequence: frameSequence,
        metalCommandBufferCompletionID: metalCommandBufferCompletionID,
        scanoutID: scanoutID,
        width: width,
        height: height,
        stride: stride,
        format: format
      )
    }
    onGraphicsTrace(event)
  }

  private func wait<T: Sendable>(
    deviceGeneration: UInt64,
    _ submit: (
      @escaping @Sendable (Result<T, DoryRendererWorkerVirtioCommandLaneError>) -> Void
    )
      throws -> Void
  ) throws -> T {
    let receipt = DoryPCSynchronousRendererReceipt<T>()
    do {
      try submit { receipt.complete($0) }
    } catch let error as DoryRendererWorkerVirtioCommandLaneError {
      throw classifiedCommandFailure(error, deviceGeneration: deviceGeneration)
    } catch {
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    guard let result = receipt.wait(timeout: commandTimeout) else {
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      throw DoryPCVirGLRendererAuthorityError.commandTimedOut
    }
    switch result {
    case .success(let value): return value
    case .failure(let error):
      throw classifiedCommandFailure(error, deviceGeneration: deviceGeneration)
    }
  }

  private func classifiedCommandFailure(
    _ error: DoryRendererWorkerVirtioCommandLaneError,
    deviceGeneration: UInt64
  ) -> any Error {
    guard error.provesNoRendererMutation else {
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      return DoryVirtioGPUAccelerationError.generationRevoked
    }
    if case .broker(.workerRejected(.resourceExhausted)) = error {
      return DoryVirtioGPUAccelerationError.resourceLimitExceeded
    }
    return DoryPCVirGLRendererAuthorityError.workerCommandFailed
  }

  private func waitScanout(
    deviceGeneration: UInt64,
    _ submit: (@escaping DoryRendererWorkerVirtioCommandLane.ScanoutCompletion) throws -> Void
  ) throws -> DoryRendererWorkerScanoutAuthority {
    let receipt = DoryPCSynchronousRendererReceipt<DoryRendererWorkerScanoutDisposition>()
    do {
      try submit { receipt.complete(.success($0)) }
    } catch let error as DoryRendererWorkerVirtioCommandLaneError {
      throw classifiedCommandFailure(error, deviceGeneration: deviceGeneration)
    } catch {
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    guard let result = receipt.wait(timeout: commandTimeout) else {
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      throw DoryPCVirGLRendererAuthorityError.commandTimedOut
    }
    switch result {
    case .success(.acquired(let scanout)): return scanout
    case .success(.provenRejected(let error)), .failure(let error):
      throw classifiedCommandFailure(error, deviceGeneration: deviceGeneration)
    case .success(.outcomeUnknown):
      terminateUnknownOutcome(deviceGeneration: deviceGeneration)
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
  }

  private func terminateUnknownOutcome(deviceGeneration failedGeneration: UInt64) {
    let revoked = lock.withLock {
      () -> (
        lane: DoryRendererWorkerVirtioCommandLane, pending: [PendingFence],
        blobAccesses: [DoryPCBlobArenaAccessLifetime],
        aperture: DoryPCHostVisibleGPUAperture?
      )? in
      guard active, deviceGeneration == failedGeneration else { return nil }
      let failedLane = lane
      active = false
      replacementAdmissionResetGeneration = nil
      retiringGeneration = true
      let accesses = blobAccesses.values.map(\.lifetime)
      blobAccesses.removeAll(keepingCapacity: false)
      resourceGenerations.removeAll(keepingCapacity: false)
      resourceProducerContexts.removeAll(keepingCapacity: false)
      pendingResourceCreations.removeAll(keepingCapacity: false)
      backings.removeAll(keepingCapacity: false)
      return (
        failedLane,
        takePendingFencesLocked(deviceGeneration: failedGeneration),
        accesses,
        hostVisibleAperture
      )
    }
    guard let revoked else { return }
    // No CPU or DMA alias may survive worker revocation, even if failure occurs before the
    // machine owner has installed its stop callback. reset() blocks until in-flight accesses
    // drain and prevents new resolutions before the worker can release its arena.
    revoked.aperture?.reset()
    discardScanoutLeases(deviceGeneration: failedGeneration)
    for access in revoked.blobAccesses { access.retire() }
    // Revocation cancels worker event sources without invoking their completion sinks.
    // Retire our guest-facing obligations before those callbacks become unreachable.
    for pending in revoked.pending { pending.completion(.outcomeUnknown) }
    revoked.lane.revoke(deviceGeneration: failedGeneration)
    lock.withLock { retiringGeneration = false }
    // Notify only after local retirement completes: an immediate guest reset must not race the
    // old generation's teardown. A renderer event carries no whole-VM stop authority.
    onWorkerUnavailable?(revoked.lane.workerGeneration.rawValue)
    onGenerationRevoked?()
  }

  private func resolvedStride(for flush: DoryVirtioGPUAcceleratedScanoutFlush) throws -> UInt32 {
    if flush.stride != 0 { return flush.stride }
    guard flush.virglFormat == 1 || flush.virglFormat == 67 else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let (stride, overflow) = flush.resourceWidth.multipliedReportingOverflow(by: 4)
    guard !overflow, stride != 0 else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    return stride
  }

  private func releaseScanout(
    _ scanout: DoryRendererWorkerScanoutAuthority,
    key: ScanoutLeaseKey,
    admitted: ActiveLane
  ) {
    let canRelease = lock.withLock {
      active && deviceGeneration == admitted.deviceGeneration
    }
    guard canRelease else {
      scanout.discardTransport()
      finishScanoutLease(key)
      return
    }
    do {
      let completion: DoryRendererWorkerVirtioCommandLane.Completion = { [weak self] result in
        guard let self else { return }
        if case .failure = result {
          self.terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
        }
        self.finishScanoutLease(key)
      }
      switch scanout {
      case .sharedMemory(let value):
        try admitted.lane.releaseScanoutLease(
          value.lease,
          deviceGeneration: admitted.deviceGeneration,
          completion: completion
        )
      case .sharedTexture(let value):
        try admitted.lane.releaseScanoutLease(
          value.lease,
          deviceGeneration: admitted.deviceGeneration,
          completion: completion
        )
      }
      scanout.discardTransport()
    } catch {
      scanout.discardTransport()
      terminateUnknownOutcome(deviceGeneration: admitted.deviceGeneration)
      finishScanoutLease(key)
    }
  }
}

private final class DoryPCSynchronousRendererReceipt<Value: Sendable>: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: Result<Value, DoryRendererWorkerVirtioCommandLaneError>?

  func complete(_ result: Result<Value, DoryRendererWorkerVirtioCommandLaneError>) {
    condition.lock()
    guard self.result == nil else {
      condition.unlock()
      return
    }
    self.result = result
    condition.broadcast()
    condition.unlock()
  }

  func wait(timeout: TimeInterval) -> Result<Value, DoryRendererWorkerVirtioCommandLaneError>? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    defer { condition.unlock() }
    while result == nil, condition.wait(until: deadline) {}
    return result
  }
}

private final class DoryPCVirGLBackingAuthority: @unchecked Sendable {
  let entries: [DoryVirtioGPUBackingEntry]
  let regions: DoryRendererWorkerSharedRegionSet

  private let transferLock = NSLock()
  private let mapping: UnsafeMutableRawPointer
  private let byteCount: Int
  private let descriptor: FileHandle

  init(
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory,
    maximumByteCount: UInt64
  ) throws {
    guard !entries.isEmpty else {
      throw DoryPCVirGLRendererAuthorityError.missingBacking(0)
    }
    let total = try entries.reduce(UInt64(0)) { partial, entry in
      let (sum, overflow) = partial.addingReportingOverflow(UInt64(entry.length))
      guard entry.length > 0, !overflow, sum <= UInt64(Int.max) else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      return sum
    }
    guard total <= maximumByteCount else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let templateURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("dory-pc-virgl.XXXXXX")
    var template = templateURL.path.utf8CString
    let fileDescriptor = template.withUnsafeMutableBufferPointer {
      mkstemp($0.baseAddress!)
    }
    guard fileDescriptor >= 0 else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    var mapped: UnsafeMutableRawPointer?
    do {
      let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
      guard descriptorFlags >= 0,
        fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
        ftruncate(fileDescriptor, off_t(total)) == 0,
        template.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0
      else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      mapped = mmap(nil, Int(total), PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
      guard mapped != MAP_FAILED, mapped != nil else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      var offset: UInt64 = 0
      var references: [DoryRendererSharedRegionReference] = []
      references.reserveCapacity(entries.count)
      for entry in entries {
        references.append(
          try .init(
            identity: .random(),
            descriptorIndex: 0,
            access: .readWrite,
            offset: offset,
            length: UInt64(entry.length),
            declaredFileSize: total
          ))
        offset += UInt64(entry.length)
      }
      offset = 0
      for entry in entries {
        let bytes = try memory.read(
          at: entry.guestAddress,
          byteCount: Int(entry.length)
        )
        guard bytes.count == Int(entry.length) else {
          throw DoryVirtioGPUError.invalidGuestMemoryResponse(
            expected: Int(entry.length), actual: bytes.count)
        }
        bytes.withUnsafeBytes { source in
          mapped!.advanced(by: Int(offset)).copyMemory(
            from: source.baseAddress!,
            byteCount: bytes.count
          )
        }
        offset += UInt64(bytes.count)
      }
      let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
      self.entries = entries
      self.mapping = mapped!
      self.byteCount = Int(total)
      self.descriptor = handle
      self.regions = .init(references: references, descriptors: [handle])
    } catch {
      if mapped != nil, mapped != MAP_FAILED { munmap(mapped, Int(total)) }
      close(fileDescriptor)
      _ = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
      throw error
    }
  }

  deinit { munmap(mapping, byteCount) }

  func withTransferLock<T>(_ body: () throws -> T) throws -> T {
    try transferLock.withLock(body)
  }

  func synchronizeFromGuest(_ memory: any DoryVirtioGuestMemory) throws {
    var offset = 0
    for entry in entries {
      let bytes = try memory.read(
        at: entry.guestAddress,
        byteCount: Int(entry.length)
      )
      guard bytes.count == Int(entry.length) else {
        throw DoryVirtioGPUError.invalidGuestMemoryResponse(
          expected: Int(entry.length), actual: bytes.count)
      }
      bytes.withUnsafeBytes { source in
        mapping.advanced(by: offset).copyMemory(
          from: source.baseAddress!,
          byteCount: bytes.count
        )
      }
      offset += bytes.count
    }
  }

  func snapshotBytes() -> [UInt8] {
    Array(UnsafeRawBufferPointer(start: mapping, count: byteCount))
  }

  func synchronizeChangedBytesToGuest(
    _ memory: any DoryVirtioGuestMemory,
    comparedTo baseline: [UInt8]
  ) throws {
    guard baseline.count == byteCount else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let current = UnsafeRawBufferPointer(start: mapping, count: byteCount)
    var entryBase = 0
    for entry in entries {
      let entryLength = Int(entry.length)
      defer { entryBase += entryLength }
      var runStart: Int?
      for entryOffset in 0..<entryLength {
        let absoluteOffset = entryBase + entryOffset
        if current[absoluteOffset] != baseline[absoluteOffset] {
          if runStart == nil { runStart = entryOffset }
          continue
        }
        if let start = runStart {
          try writeEntryRun(
            memory,
            entry: entry,
            entryBase: entryBase,
            entryOffset: start,
            byteCount: entryOffset - start
          )
          runStart = nil
        }
      }
      if let start = runStart {
        try writeEntryRun(
          memory,
          entry: entry,
          entryBase: entryBase,
          entryOffset: start,
          byteCount: entryLength - start
        )
      }
    }
  }

  private func writeEntryRun(
    _ memory: any DoryVirtioGuestMemory,
    entry: DoryVirtioGPUBackingEntry,
    entryBase: Int,
    entryOffset: Int,
    byteCount: Int
  ) throws {
    guard byteCount > 0,
      entryOffset >= 0,
      entryOffset <= Int(entry.length),
      byteCount <= Int(entry.length) - entryOffset,
      entry.guestAddress <= UInt64.max - UInt64(entryOffset)
    else {
      throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
    }
    let bytes = Array(
      UnsafeRawBufferPointer(
        start: mapping.advanced(by: entryBase + entryOffset),
        count: byteCount
      ))
    try memory.write(
      at: entry.guestAddress + UInt64(entryOffset),
      bytes: bytes
    )
  }
}
