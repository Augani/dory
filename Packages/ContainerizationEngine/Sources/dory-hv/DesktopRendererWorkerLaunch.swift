import CryptoKit
import Darwin
import DoryHV
import DoryOperations
import DoryRendererWorkerContracts
import DorydKit
import Foundation

enum DesktopRendererWorkerLaunchError: Error, Equatable, CustomStringConvertible {
  case unexpectedBootstrapAuthority
  case missingBootstrapAuthority
  case invalidBootstrapDescriptor
  case invalidBootstrapObject
  case bootstrapReadFailed
  case bootstrapChangedDuringRead
  case bootstrapDigestMismatch
  case bootstrapWorkspaceMismatch
  case managedKernelDigestMismatch
  case bootstrapQualificationUnavailable
  case bootstrapQualificationMismatch
  case synchronizedPresentationTimedOut
  case synchronizedPresentationFailed(String)
  case retirementIdentityMismatch

  var description: String {
    switch self {
    case .unexpectedBootstrapAuthority:
      "renderer bootstrap authority is forbidden for this graphics level"
    case .missingBootstrapAuthority:
      "hardware-accelerated 3D is missing its renderer bootstrap authority"
    case .invalidBootstrapDescriptor:
      "renderer bootstrap did not arrive in the fixed inherited descriptor slot"
    case .invalidBootstrapObject:
      "renderer bootstrap is not the exact private anonymous read-only object"
    case .bootstrapReadFailed:
      "renderer bootstrap changed or ended during its exact descriptor read"
    case .bootstrapChangedDuringRead:
      "renderer bootstrap object identity changed during its exact descriptor read"
    case .bootstrapDigestMismatch:
      "renderer bootstrap failed exact SHA-256 validation"
    case .bootstrapWorkspaceMismatch:
      "renderer bootstrap belongs to another machine launch workspace"
    case .managedKernelDigestMismatch:
      "renderer producer-fence authority does not bind the admitted guest kernel"
    case .bootstrapQualificationUnavailable:
      "packaged renderer bootstrap qualification is unavailable or untrusted"
    case .bootstrapQualificationMismatch:
      "live renderer capabilities do not match the packaged bootstrap qualification"
    case .synchronizedPresentationTimedOut:
      "the guest did not complete a synchronized worker-backed Metal presentation"
    case .synchronizedPresentationFailed(let reason):
      "synchronized worker-backed Metal presentation failed: \(reason)"
    case .retirementIdentityMismatch:
      "renderer retirement does not identify the exact admitted worker process"
    }
  }
}

/// Thread-safe one-shot bridge between Metal's completion callback and the background readiness
/// publisher. It is deliberately separate from immutable launch receipts so tests and production
/// cannot accidentally satisfy live readiness with a digest alone.
final class DesktopRendererWorkerLiveReadinessGate: @unchecked Sendable {
  private enum State {
    case waiting
    case presented
    case published
    case failed(String)
  }

  private let expectedWorkerGeneration: UInt64
  private let condition = NSCondition()
  private var state: State = .waiting

  init(expectedWorkerGeneration: UInt64) {
    precondition(expectedWorkerGeneration != 0)
    self.expectedWorkerGeneration = expectedWorkerGeneration
  }

  func record(workerGeneration receivedGeneration: UInt64) {
    condition.lock()
    defer { condition.unlock() }
    guard case .waiting = state else { return }
    guard receivedGeneration == expectedWorkerGeneration else {
      state = .failed(
        "worker generation drift (expected \(expectedWorkerGeneration), got "
          + "\(receivedGeneration))"
      )
      condition.broadcast()
      return
    }
    state = .presented
    condition.broadcast()
  }

  func fail(_ reason: String) {
    condition.lock()
    defer { condition.unlock() }
    switch state {
    case .waiting, .presented:
      state = .failed(reason)
      condition.broadcast()
    case .published, .failed:
      return
    }
  }

  func wait(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    condition.lock()
    defer { condition.unlock() }
    while case .waiting = state {
      guard condition.wait(until: deadline) else {
        state = .failed("presentation deadline expired")
        throw DesktopRendererWorkerLaunchError.synchronizedPresentationTimedOut
      }
    }
    switch state {
    case .presented, .published:
      return
    case .failed(let reason):
      throw DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(reason)
    case .waiting:
      preconditionFailure("renderer readiness wait escaped while still waiting")
    }
  }

  /// Linearizes the live frame edge with handoff publication. A worker failure that wins this
  /// lock prevents publication; once this transition wins, the synchronized frame was live at
  /// the exact logical readiness boundary. Later worker loss revokes graphics observations and
  /// requests an isolated GPU reset; it does not authorize rebooting the running VM.
  func claimForPublication() throws {
    condition.lock()
    defer { condition.unlock() }
    switch state {
    case .presented:
      state = .published
    case .published:
      return
    case .failed(let reason):
      throw DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(reason)
    case .waiting:
      throw DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(
        "no synchronized presentation is ready for publication"
      )
    }
  }
}

final class DesktopRendererWorkerReplacementProvider: @unchecked Sendable {
  private let path: String
  private let token: String
  private let machineID: String
  private let operationID: UUID
  private let resolvedPlanSHA256: String
  private let planRevision: UInt64
  private let graphics: DoryGraphicsAccelerationLevel
  private let producerFenceContract: DoryRendererProducerFenceContract

  init(path: String, token: String, envelope: DoryPCRuntimeLaunchEnvelope) {
    self.path = path
    self.token = token
    self.machineID = envelope.machineID
    self.operationID = envelope.operationID
    self.resolvedPlanSHA256 = envelope.resolvedPlanSHA256
    self.planRevision = envelope.planRevision
    self.graphics = envelope.graphics
    self.producerFenceContract =
      envelope.rendererProducerFenceContract
      ?? .doryPCX8664LinuxVirGL2PrepareFBV1
  }

  init(path: String, token: String, envelope: RuntimeLaunchEnvelope) {
    self.path = path
    self.token = token
    self.machineID = envelope.machineID
    self.operationID = envelope.operationID
    self.resolvedPlanSHA256 = envelope.resolvedPlanSHA256
    self.planRevision = envelope.planRevision
    self.graphics = envelope.graphics
    self.producerFenceContract = .stockLinux613RuntimeVerifiedV1
  }

  func prepareReplacement(after launch: DesktopRendererWorkerLaunch) async throws
    -> DesktopRendererWorkerLaunch
  {
    // The daemon handoff admits a new foreign memory consumer. It cannot run until the exact old
    // process has retired; an interrupted XPC connection or a local lane revoke is not that proof.
    _ = try await launch.retire(reason: "renderer generation replacement")
    try Task.checkCancellation()
    let previousGeneration = launch.workerGeneration.rawValue
    let requestedGeneration = previousGeneration &+ 1
    guard requestedGeneration > previousGeneration else {
      throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
    }
    let handoff = try DoryRendererGenerationHandoffClient.request(
      path: path,
      request: DoryRendererGenerationHandoffRequest(
        token: token,
        machineID: machineID,
        operationID: DoryOperationIdentity.canonical(operationID),
        resolvedPlanSHA256: resolvedPlanSHA256,
        planRevision: planRevision,
        previousRendererGeneration: previousGeneration,
        requestedRendererGeneration: requestedGeneration
      )
    )
    guard let descriptor = handoff.takeBootstrapDescriptor() else {
      throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
    }
    guard let byteCount = handoff.response.bootstrapByteCount,
      let sha256 = handoff.response.bootstrapSHA256
    else {
      Darwin.close(descriptor)
      throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
    }
    let authority = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
      name: RuntimeLaunchEnvelope.rendererBootstrapSlotName,
      descriptor: descriptor,
      access: .readOnly,
      byteCount: byteCount,
      contentSHA256: sha256
    )
    guard
      let launch = try await DesktopRendererWorkerLaunch.prepare(
        resolvedGraphics: graphics,
        rendererBootstrapAuthority: authority,
        exactManagedKernelSHA256: nil,
        requiredWorkspaceID: operationID,
        requiredBootstrapDescriptor: descriptor,
        requiredProducerFenceContract: producerFenceContract
      )
    else {
      throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
    }
    return launch
  }
}

/// One authenticated renderer generation prepared before any machine or vCPU starts.
///
/// The two SHA-256 values are durable launch-authority evidence. They do not claim that a frame
/// reached the display. `waitForFirstSynchronizedPresentation` is the separate live gate that
/// closes only after the worker producer fence and Metal command buffer both complete.
final class DesktopRendererWorkerLaunch: @unchecked Sendable {
  typealias Connector = @Sendable (Data) async throws -> DoryRendererWorkerBroker
  typealias QualificationProvider =
    @Sendable () throws
    -> DoryVerifiedRendererBootstrapQualification

  static let initialDeviceGeneration: UInt64 = 1
  static let bootstrapReadByteCount = DoryRendererWorkerBootstrapCodec.fixedByteCount

  let broker: DoryRendererWorkerBroker
  let commandLane: DoryRendererWorkerVirtioCommandLane
  let workerGeneration: DoryRendererWorkerGeneration
  let rendererWorkerReceiptSHA256: String
  let qualifiedProducerFenceAuthoritySHA256: String

  private let readinessGate: DesktopRendererWorkerLiveReadinessGate
  private let retirement = DesktopRendererWorkerRetirement<DoryRendererWorkerRetirementReceipt>()

  private init(
    broker: DoryRendererWorkerBroker,
    commandLane: DoryRendererWorkerVirtioCommandLane,
    rendererWorkerReceiptSHA256: String,
    qualifiedProducerFenceAuthoritySHA256: String
  ) {
    self.broker = broker
    self.commandLane = commandLane
    self.workerGeneration = broker.bootstrap.generation
    self.readinessGate = DesktopRendererWorkerLiveReadinessGate(
      expectedWorkerGeneration: broker.bootstrap.generation.rawValue
    )
    self.rendererWorkerReceiptSHA256 = rendererWorkerReceiptSHA256
    self.qualifiedProducerFenceAuthoritySHA256 =
      qualifiedProducerFenceAuthoritySHA256
  }

  deinit {
    teardown(reason: "renderer launch authority released")
  }

  /// Consumes only the caller's admitted renderer-bootstrap descriptor for hardware-accelerated
  /// 3D. Other resolved graphics levels must not carry or start a renderer worker, even if a
  /// stale daemon accidentally leaves the slot open.
  static func prepare(
    resolvedGraphics: DoryGraphicsAccelerationLevel?,
    rendererBootstrapAuthority: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot?,
    exactManagedKernelSHA256: String?,
    requiredWorkspaceID: UUID?,
    requiredBootstrapDescriptor: Int32 = RuntimeLaunchEnvelope.rendererBootstrapDescriptor,
    requiredProducerFenceContract: DoryRendererProducerFenceContract =
      .managedLinux612106PrepareFBV1,
    connector: @escaping Connector = { bytes in
      try await DoryRendererWorkerBroker.connect(exactBootstrapBytes: bytes)
    },
    qualificationProvider: QualificationProvider? = nil
  ) async throws -> DesktopRendererWorkerLaunch? {
    guard resolvedGraphics == .hardwareAccelerated3D else {
      guard rendererBootstrapAuthority == nil else {
        if let descriptor = rendererBootstrapAuthority?.descriptor, descriptor >= 3 {
          Darwin.close(descriptor)
        }
        throw DesktopRendererWorkerLaunchError.unexpectedBootstrapAuthority
      }
      return nil
    }
    guard let authority = rendererBootstrapAuthority else {
      throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
    }

    let exactBytes = try readAndConsumeBootstrap(
      authority,
      requiredDescriptor: requiredBootstrapDescriptor
    )
    let bootstrap = try DoryRendererWorkerBootstrapCodec.decode(exactBytes)
    if let requiredWorkspaceID, bootstrap.workspaceID.rawValue != requiredWorkspaceID {
      throw DesktopRendererWorkerLaunchError.bootstrapWorkspaceMismatch
    }
    guard bootstrap.producerFenceContract == requiredProducerFenceContract else {
      throw DesktopRendererWorkerLaunchError.bootstrapQualificationMismatch
    }
    if let exactManagedKernelSHA256 {
      guard let managedGuestKernel = bootstrap.artifacts.managedGuestKernel,
        hexadecimal(managedGuestKernel.bytes)
          == exactManagedKernelSHA256
      else {
        throw DesktopRendererWorkerLaunchError.managedKernelDigestMismatch
      }
    } else {
      guard
        requiredProducerFenceContract
          == .doryPCX8664LinuxVirGL2PrepareFBV1
          || requiredProducerFenceContract
            == .doryPCX8664LinuxVenusPrepareFBV1
          || requiredProducerFenceContract
            == .stockLinux613RuntimeVerifiedV1
      else {
        throw DesktopRendererWorkerLaunchError.missingBootstrapAuthority
      }
    }

    let broker = try await connector(exactBytes)
    do {
      guard broker.bootstrap == bootstrap,
        broker.capabilityReceipt.isAdmissible(for: bootstrap),
        broker.capabilityReceipt.producerFenceContract
          == bootstrap.producerFenceContract
      else {
        throw DoryRendererWorkerBrokerError.incompleteCapabilityReceipt
      }
      let qualification: DoryVerifiedRendererBootstrapQualification
      do {
        if let qualificationProvider {
          qualification = try qualificationProvider()
        } else {
          qualification =
            try DoryVerifiedRendererBootstrapQualification
            .loadRuntimeCandidate(
              producerFenceContract: requiredProducerFenceContract
            )
        }
      } catch {
        throw DesktopRendererWorkerLaunchError
          .bootstrapQualificationUnavailable
      }
      try verifyLiveQualification(
        bootstrap: bootstrap,
        receipt: broker.capabilityReceipt,
        qualification: qualification
      )
      let lane = try DoryRendererWorkerVirtioCommandLane(
        broker: broker,
        deviceGeneration: initialDeviceGeneration
      )
      let receiptBytes = DoryRendererCapabilityReceiptCodec.encode(
        broker.capabilityReceipt
      )
      return DesktopRendererWorkerLaunch(
        broker: broker,
        commandLane: lane,
        rendererWorkerReceiptSHA256: sha256(receiptBytes),
        qualifiedProducerFenceAuthoritySHA256:
          qualifiedProducerFenceAuthoritySHA256(for: bootstrap)
      )
    } catch {
      let preparationError = error
      // A connected but rejected bootstrap still owns a real helper. Join exact shutdown before
      // abandoning its launch authority; unknown shutdown must remain a typed retirement failure.
      _ = try await broker.retire()
      throw preparationError
    }
  }

  /// A build-time bootstrap is not permission to skip live initialization. The runner compares
  /// every stable capability fact returned by this new worker generation before it creates the
  /// virtio command lane. Workspace and generation remain live-only and are already bound by
  /// `DoryRendererCapabilityReceiptCodec.decode(accepting:)`; the managed kernel is also compared
  /// with the packaged candidate receipt because it supplies producer-fence authority.
  static func verifyLiveQualification(
    bootstrap: DoryRendererWorkerBootstrap,
    receipt: DoryRendererCapabilityReceipt,
    qualification: DoryVerifiedRendererBootstrapQualification
  ) throws {
    guard
      qualification.authorizes(
        bootstrap: bootstrap,
        liveReceipt: receipt
      )
    else {
      throw DesktopRendererWorkerLaunchError
        .bootstrapQualificationMismatch
    }
  }

  /// Called only by the Metal command-buffer completion edge. The worker core publishes an
  /// update only after its producer fence signals, so this exact-generation signal proves both
  /// halves of the live synchronized presentation boundary.
  func recordSynchronizedPresentation(workerGeneration receivedGeneration: UInt64) {
    readinessGate.record(workerGeneration: receivedGeneration)
  }

  func failSynchronizedPresentation(_ reason: String) {
    readinessGate.fail(reason)
  }

  func waitForFirstSynchronizedPresentation(timeout: TimeInterval) throws {
    try readinessGate.wait(timeout: timeout)
  }

  func claimSynchronizedPresentationForPublication() throws {
    try readinessGate.claimForPublication()
  }

  func teardown(reason: String = "renderer launch teardown") {
    _ = beginRetirement(reason: reason)
  }

  /// Joins the same bounded exact-process retirement requested by synchronous teardown. Callers
  /// must await this off the guest transport/register locks before releasing backing authority or
  /// asking the daemon to admit a successor. A failed wait is never proof; a later join requires
  /// positive exact-process evidence before it can recover from that failure.
  func retire(reason: String = "renderer launch retirement") async throws
    -> DoryRendererWorkerRetirementReceipt
  {
    // Positive process exit does not itself cancel local fences or revoke readiness. Always close
    // those admission gates before taking the nonblocking late-proof shortcut.
    let retirementTask = beginRetirement(reason: reason)
    let receipt: DoryRendererWorkerRetirementReceipt
    if let confirmed = broker.waitForRetirement(timeout: 0) {
      // A bounded wait may have timed out before the kernel later proved exact process exit.
      // That positive evidence is still usable; an old failed wait alone never is.
      receipt = confirmed
    } else {
      receipt = try await retirementTask.value
    }
    guard receipt.workspaceID == broker.bootstrap.workspaceID.rawValue,
      receipt.workerGeneration == workerGeneration,
      receipt.processIdentifier > 0 else {
      throw DesktopRendererWorkerLaunchError.retirementIdentityMismatch
    }
    return receipt
  }

  func waitForRetirement(reason: String) async throws {
    _ = try await teardownAndWait(reason: reason)
  }

  func teardownAndWait(reason: String = "renderer launch teardown") async throws
    -> DoryRendererWorkerRetirementReceipt
  {
    try await retire(reason: reason)
  }

  private func beginRetirement(reason: String)
    -> Task<DoryRendererWorkerRetirementReceipt, any Error>
  {
    failSynchronizedPresentation(reason)
    commandLane.invalidateForRetirement()
    return retirement.start { [broker] in
      try await broker.retire()
    }
  }

  static func qualifiedProducerFenceAuthoritySHA256(
    for bootstrap: DoryRendererWorkerBootstrap
  ) -> String {
    var authority = Data("dory.renderer.qualified-producer-fence-authority.v1\0".utf8)
    var contract = bootstrap.producerFenceContract.rawValue.littleEndian
    withUnsafeBytes(of: &contract) { authority.append(contentsOf: $0) }
    if bootstrap.producerFenceContract == .managedLinux612106PrepareFBV1 {
      guard let managedGuestKernel = bootstrap.artifacts.managedGuestKernel else {
        preconditionFailure("managed producer-fence contract has no kernel authority")
      }
      authority.append(managedGuestKernel.bytes)
    }
    return sha256(authority)
  }

  /// The descriptor parameter exists so the exact object reader can be exercised without
  /// stealing process-global FD6 in a parallel test runner and so alternate launch envelopes can
  /// bind their own fixed inherited slot. The default remains the desktop FD6 contract.
  static func readAndConsumeBootstrap(
    _ authority: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot,
    requiredDescriptor: Int32 = RuntimeLaunchEnvelope.rendererBootstrapDescriptor
  ) throws -> Data {
    let descriptor = authority.descriptor
    guard descriptor >= 3 else {
      throw DesktopRendererWorkerLaunchError.invalidBootstrapDescriptor
    }
    defer { Darwin.close(descriptor) }
    guard authority.name == RuntimeLaunchEnvelope.rendererBootstrapSlotName,
      descriptor == requiredDescriptor,
      authority.access == .readOnly,
      authority.byteCount == UInt64(bootstrapReadByteCount),
      authority.logicalDeviceID == nil,
      let expectedSHA256 = authority.contentSHA256,
      isLowercaseSHA256(expectedSHA256)
    else {
      throw DesktopRendererWorkerLaunchError.invalidBootstrapDescriptor
    }

    let accessFlags = fcntl(descriptor, F_GETFL)
    var before = stat()
    guard accessFlags >= 0,
      accessFlags & O_ACCMODE == O_RDONLY,
      fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(),
      before.st_nlink == 0,
      before.st_size == off_t(bootstrapReadByteCount),
      before.st_mode & 0o077 == 0
    else {
      throw DesktopRendererWorkerLaunchError.invalidBootstrapObject
    }

    var data = Data(count: bootstrapReadByteCount)
    try data.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else {
        throw DesktopRendererWorkerLaunchError.bootstrapReadFailed
      }
      var offset = 0
      while offset < raw.count {
        let result = pread(
          descriptor,
          base.advanced(by: offset),
          raw.count - offset,
          off_t(offset)
        )
        if result > 0 {
          offset += result
        } else if result < 0, errno == EINTR {
          continue
        } else {
          throw DesktopRendererWorkerLaunchError.bootstrapReadFailed
        }
      }
    }

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw DesktopRendererWorkerLaunchError.bootstrapChangedDuringRead
    }
    guard sha256(data) == expectedSHA256 else {
      throw DesktopRendererWorkerLaunchError.bootstrapDigestMismatch
    }
    return data
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hexadecimal(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}

/// One exact launch owns one terminal result. Cancelling a waiter cannot cancel the shared worker
/// retirement, and repeated teardown cannot turn an unknown/failed result into false success.
final class DesktopRendererWorkerRetirement<Receipt: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Receipt, any Error>?

  func start(_ operation: @escaping @Sendable () async throws -> Receipt)
    -> Task<Receipt, any Error>
  {
    lock.withLock {
      if let task { return task }
      // NSApplication.run can occupy the main actor for the controller lifetime. Retirement must
      // execute independently rather than queueing behind that run-loop task.
      let started = Task.detached(priority: .userInitiated, operation: operation)
      task = started
      return started
    }
  }
}
