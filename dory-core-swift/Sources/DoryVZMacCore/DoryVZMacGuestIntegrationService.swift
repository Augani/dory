import Darwin
import CryptoKit
import DoryMacGuestIntegrationWire
import Foundation
import Virtualization

public struct DoryVZMacGuestIntegrationSnapshot: Sendable, Equatable {
  public enum State: String, Sendable, Equatable { case disconnected, handshaking, healthy }
  public let state: State
  public let runtimeGeneration: UInt64
  public let guestToolsVersion: String?
  public let guestToolsBuild: String?
  public let guestOSVersion: String?
  public let grantedCapabilities: [DoryMacGuestIntegrationWire.Capability]
  public let lastHealthAt: Date?
  public let guestTimeUnixMilliseconds: UInt64?
  public let lastErrorCode: String?
}

public enum DoryVZMacGuestIntegrationError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case unavailable
  case busy
  case denied
  case expired
  case outcomeUnknown

  public var description: String {
    switch self {
    case .unavailable: "Mac Guest Tools is unavailable"
    case .busy: "Mac Guest Tools is busy"
    case .denied: "Mac Guest Tools denied the request"
    case .expired: "Mac Guest Tools did not complete the request before its deadline"
    case .outcomeUnknown:
      "Mac Guest Tools disconnected after the action was sent; it may already have completed"
    }
  }
}

/// Serialized by the service lock. Listener revocation cannot make an accepted worker lose
/// its cleanup ownership, and a stale worker can never retire a successor's connection.
struct DoryVZMacGuestIntegrationConnectionAuthority {
  private var registration: UUID?
  private var connection: UUID?

  var hasConnection: Bool { connection != nil }
  var currentIdentity: UUID? { connection }
  mutating func install() throws {
    guard registration == nil, connection == nil else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    registration = UUID()
  }
  mutating func removeRegistration() { registration = nil }
  mutating func accept() -> UUID? {
    guard registration != nil, connection == nil else { return nil }
    let identity = UUID()
    connection = identity
    return identity
  }
  func owns(_ identity: UUID) -> Bool { connection == identity }
  func permits(_ identity: UUID) -> Bool { registration != nil && owns(identity) }
  @discardableResult mutating func finish(_ identity: UUID) -> Bool {
    guard owns(identity) else { return false }
    connection = nil
    return true
  }
}

/// A VM-local, unprivileged Guest Tools channel. The listener is installed only on the selected
/// VZVirtualMachine's socket device. Even a guest process that impersonates the app can receive
/// only explicitly granted user-session actions. No host file, shell, camera or clipboard
/// authority is inferred from a hello string; clipboard reads require a separate VM policy grant.
public final class DoryVZMacGuestIntegrationService: NSObject,
  VZVirtioSocketListenerDelegate, @unchecked Sendable
{
  private let grants: [DoryMacGuestIntegrationWire.Capability]

  private final class PendingOpenURL: @unchecked Sendable {
    let body: Data
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
    var dispatched = false

    init(body: Data) {
      self.body = body
    }
  }

  private final class PendingClipboardRead: @unchecked Sendable {
    let capability: DoryMacGuestIntegrationWire.Capability
    let requestBody: Data?
    var continuation: CheckedContinuation<Data, Error>?
    var cancelled = false
    var dispatched = false

    init(capability: DoryMacGuestIntegrationWire.Capability, requestBody: Data? = nil) {
      self.capability = capability
      self.requestBody = requestBody
    }
  }

  private final class PendingClipboardWrite: @unchecked Sendable {
    let capability: DoryMacGuestIntegrationWire.Capability
    let body: Data
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
    var dispatched = false

    init(capability: DoryMacGuestIntegrationWire.Capability, body: Data) {
      self.capability = capability
      self.body = body
    }
  }

  private final class PendingFilePush: @unchecked Sendable {
    let url: URL
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
    var dispatched = false
    var commitDispatched = false

    init(url: URL) { self.url = url }
  }

  private final class PendingFilePull: @unchecked Sendable {
    let offer: DoryMacGuestIntegrationWire.FilePullOffer
    let destination: URL
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
    var dispatched = false
    var publicationStarted = false

    init(offer: DoryMacGuestIntegrationWire.FilePullOffer, destination: URL) {
      self.offer = offer
      self.destination = destination
    }
  }

  private let machineID: String
  private let runtimeGeneration: UInt64
  private let log: @Sendable (String) -> Void
  private let registrationLock = NSLock()
  private let lock = NSLock()
  private var workerGroup = DispatchGroup()
  private let sleepSignal = DispatchSemaphore(value: 0)
  private var socketDevice: VZVirtioSocketDevice?
  private var listener: VZVirtioSocketListener?
  private var activeDescriptor: Int32?
  private var connectionAuthority = DoryVZMacGuestIntegrationConnectionAuthority()
  private var acceptingConnection: Bool { connectionAuthority.hasConnection }
  private var pendingOpenURL: PendingOpenURL?
  private var pendingClipboardRead: PendingClipboardRead?
  private var pendingClipboardWrite: PendingClipboardWrite?
  private var pendingFilePush: PendingFilePush?
  private var pendingFilePull: PendingFilePull?
  private var snapshotStorage: DoryVZMacGuestIntegrationSnapshot

  public var snapshot: DoryVZMacGuestIntegrationSnapshot {
    lock.withLock { snapshotStorage }
  }

  /// A reconnect replaces this nonce even when the VM's runtime generation is unchanged.
  /// Identity is not a clipboard grant: callers must independently check policy and focus.
  public var clipboardSessionIdentity: UUID? {
    lock.withLock {
      guard listener != nil, activeDescriptor != nil, snapshotStorage.state == .healthy,
        let identity = connectionAuthority.currentIdentity,
        connectionAuthority.permits(identity) else { return nil }
      return identity
    }
  }

  static func interruptedActionError(dispatched: Bool) -> DoryVZMacGuestIntegrationError {
    dispatched ? .outcomeUnknown : .unavailable
  }

  /// Does not block the caller's actor while AppKit in the selected guest opens the URL.
  /// The channel admits one command at a time and rejects disconnected or older tools.
  public func openURL(_ url: URL) async throws {
    let command = try DoryMacGuestIntegrationWire.OpenURLRequest(url: url.absoluteString)
    let body = try DoryMacGuestIntegrationWire.encodeOpenURLRequest(command)
    let pending = PendingOpenURL(body: body)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = lock.withLock { () -> (any Error)? in
          guard !pending.cancelled else { return CancellationError() }
          guard listener != nil, acceptingConnection,
            snapshotStorage.state == .healthy,
            snapshotStorage.grantedCapabilities.contains(.openURL)
          else { return DoryVZMacGuestIntegrationError.unavailable }
          guard pendingOpenURL == nil, pendingClipboardRead == nil,
            pendingClipboardWrite == nil, pendingFilePush == nil,
            pendingFilePull == nil else {
            return DoryVZMacGuestIntegrationError.busy
          }
          pending.continuation = continuation
          pendingOpenURL = pending
          return nil
        }
        if let result {
          continuation.resume(throwing: result)
        } else {
          sleepSignal.signal()
        }
      }
    } onCancel: {
      let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
        pending.cancelled = true
        guard pendingOpenURL === pending else { return (nil, false) }
        pendingOpenURL = nil
        // A sent request cannot be recalled by removing its continuation. Tear down this
        // one-VM session so Guest Tools can suppress a not-yet-started AppKit action.
        if pending.dispatched, let activeDescriptor {
          _ = shutdown(activeDescriptor, SHUT_RDWR)
        }
        defer { pending.continuation = nil }
        return (pending.continuation, pending.dispatched)
      }
      result.0?.resume(throwing: result.1
        ? DoryVZMacGuestIntegrationError.outcomeUnknown : CancellationError())
      sleepSignal.signal()
    }
  }

  /// The URL must come from a user-selected host file. The selected VM receives bytes and a
  /// display name only; it cannot request host paths or initiate a host-file read itself.
  public func sendFileToGuest(at url: URL) async throws {
    let pending = PendingFilePush(url: url)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = lock.withLock { () -> (any Error)? in
          guard !pending.cancelled else { return CancellationError() }
          guard listener != nil, acceptingConnection,
            snapshotStorage.state == .healthy,
            snapshotStorage.grantedCapabilities.contains(.filePush)
          else { return DoryVZMacGuestIntegrationError.unavailable }
          guard pendingOpenURL == nil, pendingClipboardRead == nil,
            pendingClipboardWrite == nil, pendingFilePush == nil,
            pendingFilePull == nil
          else { return DoryVZMacGuestIntegrationError.busy }
          pending.continuation = continuation
          pendingFilePush = pending
          return nil
        }
        if let result { continuation.resume(throwing: result) }
        else { sleepSignal.signal() }
      }
    } onCancel: {
      let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
        pending.cancelled = true
        guard pendingFilePush === pending else { return (nil, false) }
        pendingFilePush = nil
        if pending.dispatched, let activeDescriptor {
          _ = shutdown(activeDescriptor, SHUT_RDWR)
        }
        defer { pending.continuation = nil }
        return (pending.continuation, pending.commitDispatched)
      }
      result.0?.resume(throwing: result.1
        ? DoryVZMacGuestIntegrationError.outcomeUnknown : CancellationError())
      sleepSignal.signal()
    }
  }

  /// A one-shot, bounded user action. The caller decides whether to place the returned text on
  /// the host pasteboard; the VM service itself never reads or writes the host pasteboard.
  public func readClipboardText() async throws -> String {
    let body = try await readClipboardBody(capability: .clipboardTextRead)
    return try DoryMacGuestIntegrationWire.decodeClipboardTextResponse(body).text
  }

  /// The app owns the host pasteboard. The service returns only a validated, bounded PNG from
  /// this VM's currently authenticated Guest Tools session.
  public func readClipboardPNG() async throws -> Data {
    let body = try await readClipboardBody(capability: .clipboardImageRead)
    try DoryMacGuestIntegrationWire.validateClipboardPNG(body)
    return body
  }

  public func fileOfferedByGuest() async throws -> DoryMacGuestIntegrationWire.FilePullOffer {
    let command = try DoryMacGuestIntegrationWire.FilePullRequest(phase: .metadata)
    let body = try await readClipboardBody(
      capability: .filePull,
      requestBody: DoryMacGuestIntegrationWire.encodeFilePullBody(command)
    )
    let offer = try DoryMacGuestIntegrationWire.decodeFilePullBody(
      body, as: DoryMacGuestIntegrationWire.FilePullOffer.self
    )
    try offer.validate()
    return offer
  }

  /// Saves only the offer selected in Guest Tools, to a host URL chosen with NSSavePanel.
  /// An interrupted transfer never replaces the selected destination.
  public func receiveFileFromGuest(
    _ offer: DoryMacGuestIntegrationWire.FilePullOffer, to destination: URL
  ) async throws {
    try offer.validate()
    guard destination.isFileURL else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let pending = PendingFilePull(offer: offer, destination: destination)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = lock.withLock { () -> (any Error)? in
          guard !pending.cancelled else { return CancellationError() }
          guard listener != nil, acceptingConnection,
            snapshotStorage.state == .healthy,
            snapshotStorage.grantedCapabilities.contains(.filePull)
          else { return DoryVZMacGuestIntegrationError.unavailable }
          guard pendingOpenURL == nil, pendingClipboardRead == nil,
            pendingClipboardWrite == nil, pendingFilePush == nil,
            pendingFilePull == nil
          else { return DoryVZMacGuestIntegrationError.busy }
          pending.continuation = continuation
          pendingFilePull = pending
          return nil
        }
        if let result { continuation.resume(throwing: result) }
        else { sleepSignal.signal() }
      }
    } onCancel: {
      let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
        pending.cancelled = true
        guard pendingFilePull === pending else { return (nil, false) }
        pendingFilePull = nil
        if pending.dispatched, let activeDescriptor {
          _ = shutdown(activeDescriptor, SHUT_RDWR)
        }
        defer { pending.continuation = nil }
        return (pending.continuation, pending.publicationStarted)
      }
      result.0?.resume(throwing: result.1
        ? DoryVZMacGuestIntegrationError.outcomeUnknown : CancellationError())
      sleepSignal.signal()
    }
  }

  private func readClipboardBody(
    capability: DoryMacGuestIntegrationWire.Capability,
    requestBody: Data? = nil
  ) async throws -> Data {
    let pending = PendingClipboardRead(capability: capability, requestBody: requestBody)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = lock.withLock { () -> (any Error)? in
          guard !pending.cancelled else { return CancellationError() }
          guard listener != nil, acceptingConnection,
            snapshotStorage.state == .healthy,
            snapshotStorage.grantedCapabilities.contains(capability)
          else { return DoryVZMacGuestIntegrationError.unavailable }
          guard pendingOpenURL == nil, pendingClipboardRead == nil,
            pendingClipboardWrite == nil, pendingFilePush == nil,
            pendingFilePull == nil else {
            return DoryVZMacGuestIntegrationError.busy
          }
          pending.continuation = continuation
          pendingClipboardRead = pending
          return nil
        }
        if let result {
          continuation.resume(throwing: result)
        } else {
          sleepSignal.signal()
        }
      }
    } onCancel: {
      let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
        pending.cancelled = true
        guard pendingClipboardRead === pending else { return nil }
        pendingClipboardRead = nil
        if pending.dispatched, let activeDescriptor {
          _ = shutdown(activeDescriptor, SHUT_RDWR)
        }
        defer { pending.continuation = nil }
        return pending.continuation
      }
      continuation?.resume(throwing: CancellationError())
      sleepSignal.signal()
    }
  }

  /// One explicit host-to-guest paste action. The VM policy must grant this direction and the
  /// selected Guest Tools session must still be healthy when the request is dispatched.
  public func writeClipboardText(_ text: String) async throws {
    let command = try DoryMacGuestIntegrationWire.ClipboardTextWriteRequest(text: text)
    let body = try DoryMacGuestIntegrationWire.encodeClipboardTextWriteRequest(command)
    try await writeClipboardBody(capability: .clipboardTextWrite, body: body)
  }

  public func writeClipboardPNG(_ png: Data) async throws {
    try DoryMacGuestIntegrationWire.validateClipboardPNG(png)
    try await writeClipboardBody(capability: .clipboardImageWrite, body: png)
  }

  private func writeClipboardBody(
    capability: DoryMacGuestIntegrationWire.Capability,
    body: Data
  ) async throws {
    let pending = PendingClipboardWrite(capability: capability, body: body)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = lock.withLock { () -> (any Error)? in
          guard !pending.cancelled else { return CancellationError() }
          guard listener != nil, acceptingConnection,
            snapshotStorage.state == .healthy,
            snapshotStorage.grantedCapabilities.contains(capability)
          else { return DoryVZMacGuestIntegrationError.unavailable }
          guard pendingOpenURL == nil, pendingClipboardRead == nil,
            pendingClipboardWrite == nil, pendingFilePush == nil,
            pendingFilePull == nil else {
            return DoryVZMacGuestIntegrationError.busy
          }
          pending.continuation = continuation
          pendingClipboardWrite = pending
          return nil
        }
        if let result {
          continuation.resume(throwing: result)
        } else {
          sleepSignal.signal()
        }
      }
    } onCancel: {
      let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
        pending.cancelled = true
        guard pendingClipboardWrite === pending else { return (nil, false) }
        pendingClipboardWrite = nil
        if pending.dispatched, let activeDescriptor {
          _ = shutdown(activeDescriptor, SHUT_RDWR)
        }
        defer { pending.continuation = nil }
        return (pending.continuation, pending.dispatched)
      }
      result.0?.resume(throwing: result.1
        ? DoryVZMacGuestIntegrationError.outcomeUnknown : CancellationError())
      sleepSignal.signal()
    }
  }

  public init(
    machineID: String,
    runtimeGeneration: UInt64 = UInt64.random(in: 1...UInt64.max),
    allowClipboardTextRead: Bool = false,
    allowClipboardTextWrite: Bool = false,
    allowClipboardImageRead: Bool = false,
    allowClipboardImageWrite: Bool = false,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) throws {
    // Validate the same identifier shape the shared wire contract requires before any VZ
    // listener is installed. The selected bundle supplies this identity, not the guest.
    _ = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: runtimeGeneration, challengeNonce: UUID()
    )
    self.machineID = machineID
    self.runtimeGeneration = runtimeGeneration
    grants = DoryMacGuestIntegrationWire.implementedCapabilitiesV2.filter {
      switch $0 {
      case .clipboardTextRead: allowClipboardTextRead
      case .clipboardTextWrite: allowClipboardTextWrite
      case .clipboardImageRead: allowClipboardImageRead
      case .clipboardImageWrite: allowClipboardImageWrite
      default: true
      }
    }
    self.log = log
    snapshotStorage = .init(
      state: .disconnected, runtimeGeneration: runtimeGeneration,
      guestToolsVersion: nil, guestToolsBuild: nil, guestOSVersion: nil,
      grantedCapabilities: [], lastHealthAt: nil, guestTimeUnixMilliseconds: nil,
      lastErrorCode: nil
    )
  }

  public func install(on socketDevice: VZVirtioSocketDevice) throws {
    let listener = VZVirtioSocketListener()
    listener.delegate = self
    try registrationLock.withLock {
      try lock.withLock {
        guard self.listener == nil, !acceptingConnection else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        try connectionAuthority.install()
        // Each listener registration owns its join receipt. A later reinstall must not add a
        // successor's worker to a remove() that is already waiting for the retired listener.
        workerGroup = DispatchGroup()
        self.listener = listener
        self.socketDevice = socketDevice
      }
      socketDevice.setSocketListener(listener, forPort: DoryMacGuestIntegrationWire.port)
    }
  }

  public func remove() {
    var cancelled: CheckedContinuation<Void, Error>?
    var cancelledOpenURLError: DoryVZMacGuestIntegrationError = .unavailable
    var cancelledClipboardRead: CheckedContinuation<Data, Error>?
    var cancelledClipboardWrite: CheckedContinuation<Void, Error>?
    var cancelledClipboardWriteError: DoryVZMacGuestIntegrationError = .unavailable
    var cancelledFilePush: CheckedContinuation<Void, Error>?
    var cancelledFilePushError: DoryVZMacGuestIntegrationError = .unavailable
    var cancelledFilePull: CheckedContinuation<Void, Error>?
    var cancelledFilePullError: DoryVZMacGuestIntegrationError = .unavailable
    let retiringWorkerGroup = registrationLock.withLock { () -> DispatchGroup in
      lock.lock()
      let device = socketDevice
      let retiringWorkerGroup = workerGroup
      socketDevice = nil
      listener = nil
      connectionAuthority.removeRegistration()
      if let activeDescriptor { _ = shutdown(activeDescriptor, SHUT_RDWR) }
      cancelled = pendingOpenURL?.continuation
      cancelledOpenURLError = Self.interruptedActionError(
        dispatched: pendingOpenURL?.dispatched == true)
      pendingOpenURL?.continuation = nil
      pendingOpenURL = nil
      cancelledClipboardRead = pendingClipboardRead?.continuation
      pendingClipboardRead?.continuation = nil
      pendingClipboardRead = nil
      cancelledClipboardWrite = pendingClipboardWrite?.continuation
      cancelledClipboardWriteError = Self.interruptedActionError(
        dispatched: pendingClipboardWrite?.dispatched == true)
      pendingClipboardWrite?.continuation = nil
      pendingClipboardWrite = nil
      cancelledFilePush = pendingFilePush?.continuation
      cancelledFilePushError = Self.interruptedActionError(
        dispatched: pendingFilePush?.commitDispatched == true)
      pendingFilePush?.continuation = nil
      pendingFilePush = nil
      cancelledFilePull = pendingFilePull?.continuation
      cancelledFilePullError = Self.interruptedActionError(
        dispatched: pendingFilePull?.publicationStarted == true)
      pendingFilePull?.continuation = nil
      pendingFilePull = nil
      snapshotStorage = disconnectedSnapshot()
      lock.unlock()
      device?.removeSocketListener(forPort: DoryMacGuestIntegrationWire.port)
      return retiringWorkerGroup
    }
    cancelled?.resume(throwing: cancelledOpenURLError)
    cancelledClipboardRead?.resume(throwing: DoryVZMacGuestIntegrationError.unavailable)
    cancelledClipboardWrite?.resume(throwing: cancelledClipboardWriteError)
    cancelledFilePush?.resume(throwing: cancelledFilePushError)
    cancelledFilePull?.resume(throwing: cancelledFilePullError)
    sleepSignal.signal()
    guard retiringWorkerGroup.wait(timeout: .now() + 15) == .success else {
      // A wedged guest-tools connection must not crash the VM process or prevent disk and
      // lifecycle recovery. The worker closure retains this service until it exits, while the
      // listener is gone and the descriptor has been shut down. No new guest authority can be
      // acquired after this point; report the missed deadline for qualification diagnostics.
      lock.withLock {
        if workerGroup === retiringWorkerGroup, listener == nil {
          snapshotStorage = disconnectedSnapshot(errorCode: "teardown-timeout")
        }
      }
      log("Dory VZMac Guest Tools worker exceeded its 15-second teardown budget")
      return
    }
  }

  public func listener(
    _ listener: VZVirtioSocketListener,
    shouldAcceptNewConnection connection: VZVirtioSocketConnection,
    from socketDevice: VZVirtioSocketDevice
  ) -> Bool {
    let admission = lock.withLock { () -> (UUID, DispatchGroup)? in
      guard self.listener === listener, self.socketDevice === socketDevice,
        let identity = connectionAuthority.accept() else { return nil }
      let workerGroup = self.workerGroup
      workerGroup.enter()
      snapshotStorage = .init(
        state: .handshaking, runtimeGeneration: runtimeGeneration,
        guestToolsVersion: nil, guestToolsBuild: nil, guestOSVersion: nil,
        grantedCapabilities: [], lastHealthAt: nil, guestTimeUnixMilliseconds: nil,
        lastErrorCode: nil
      )
      return (identity, workerGroup)
    }
    guard let (connectionID, workerGroup) = admission else { return false }
    let box = ConnectionBox(connection)
    DispatchQueue.global(qos: .utility).async { [self, box] in
      defer {
        box.connection.close()
        workerGroup.leave()
      }
      var errorCode: String?
      do {
        try serve(box.connection, connectionID: connectionID)
      } catch {
        log("Dory VZMac Guest Tools session ended: \(error)")
        errorCode = Self.errorCode(for: error)
      }
      let continuations = lock.withLock { () -> PendingRequestContinuations? in
        guard connectionAuthority.owns(connectionID) else { return nil }
        // Capture only this connection's pending work before publishing reconnect admission.
        // Resuming continuations outside the lock cannot cancel work admitted by its successor.
        let continuations = takePendingRequestsLocked()
        connectionAuthority.finish(connectionID)
        snapshotStorage = disconnectedSnapshot(
          errorCode: self.listener == nil
            ? (snapshotStorage.lastErrorCode == "teardown-timeout" ? "teardown-timeout" : nil)
            : errorCode
        )
        return continuations
      }
      if let continuations { resumeFailedRequests(continuations) }
    }
    return true
  }

  private func serve(_ connection: VZVirtioSocketConnection, connectionID: UUID) throws {
    let descriptor = dup(connection.fileDescriptor)
    guard descriptor >= 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
    let admitted = lock.withLock { () -> Bool in
      guard listener != nil, connectionAuthority.permits(connectionID) else { return false }
      activeDescriptor = descriptor
      return true
    }
    guard admitted else {
      close(descriptor)
      return
    }
    defer {
      lock.lock()
      if connectionAuthority.owns(connectionID), activeDescriptor == descriptor { activeDescriptor = nil }
      lock.unlock()
      _ = shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
    }
    try Self.configureSocket(descriptor)
    let sessionID = UUID()
    let nonce = UUID()
    let challenge = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: runtimeGeneration, challengeNonce: nonce
    )
    try DoryMacGuestIntegrationWire.writeFrame(challenge, to: descriptor)
    let reply = try DoryMacGuestIntegrationWire.readFrame(from: descriptor)
    guard reply.kind == .hello, reply.sessionID == sessionID,
      reply.machineID == machineID, reply.runtimeGeneration == runtimeGeneration,
      reply.challengeNonce == nonce, let hello = reply.hello else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    try hello.validate()
    let grants = self.grants.filter { hello.offeredCapabilities.contains($0) }
    guard grants.contains(.health) else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    try DoryMacGuestIntegrationWire.writeFrame(
      DoryMacGuestIntegrationWire.Envelope(
        kind: .open, sessionID: sessionID, machineID: machineID,
        runtimeGeneration: runtimeGeneration, grantedCapabilities: grants
      ),
      to: descriptor
    )

    var requestID: UInt64 = 1
    while lock.withLock({ connectionAuthority.permits(connectionID) && activeDescriptor == descriptor }) {
      let request = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: sessionID, machineID: machineID,
        runtimeGeneration: runtimeGeneration, requestID: requestID,
        capability: .health, timeoutMilliseconds: 5_000
      )
      let startedAt = DispatchTime.now().uptimeNanoseconds
      let deadline = startedAt + 5_000_000_000
      try DoryMacGuestIntegrationWire.writeFrame(
        request, to: descriptor, deadlineUptimeNanoseconds: deadline
      )
      let response = try DoryMacGuestIntegrationWire.readFrame(
        from: descriptor, deadlineUptimeNanoseconds: deadline
      )
      guard response.kind == .response, response.sessionID == sessionID,
        response.machineID == machineID,
        response.runtimeGeneration == runtimeGeneration,
        response.requestID == requestID, response.capability == .health,
        response.status == .success,
        !request.isExpired(
          receivedAtUptimeNanoseconds: startedAt,
          nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ),
        let body = response.body else {
        throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
      }
      let report = try JSONDecoder().decode(DoryMacGuestIntegrationWire.HealthReport.self, from: body)
      try report.validate()
      guard report.bundleIdentifier == hello.bundleIdentifier,
        report.toolsVersion == hello.toolsVersion,
        report.toolsBuild == hello.toolsBuild else {
        throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
      }
      try lock.withLock {
        guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor else {
          throw DoryMacGuestIntegrationWire.WireError.connectionClosed
        }
        snapshotStorage = .init(
          state: .healthy, runtimeGeneration: runtimeGeneration,
          guestToolsVersion: hello.toolsVersion,
          guestToolsBuild: hello.toolsBuild,
          guestOSVersion: report.guestOSVersion,
          grantedCapabilities: grants,
          lastHealthAt: Date(),
          guestTimeUnixMilliseconds: nil,
          lastErrorCode: nil
        )
      }
      guard requestID < .max else { break }
      requestID += 1
      if grants.contains(.guestTime) {
        let timeRequest = try DoryMacGuestIntegrationWire.Envelope(
          kind: .request, sessionID: sessionID, machineID: machineID,
          runtimeGeneration: runtimeGeneration, requestID: requestID,
          capability: .guestTime, timeoutMilliseconds: 5_000
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt + 5_000_000_000
        try DoryMacGuestIntegrationWire.writeFrame(
          timeRequest, to: descriptor, deadlineUptimeNanoseconds: deadline
        )
        let timeResponse = try DoryMacGuestIntegrationWire.readFrame(
          from: descriptor, deadlineUptimeNanoseconds: deadline
        )
        guard timeResponse.kind == .response,
          timeResponse.sessionID == sessionID,
          timeResponse.machineID == machineID,
          timeResponse.runtimeGeneration == runtimeGeneration,
          timeResponse.requestID == requestID,
          timeResponse.capability == .guestTime,
          timeResponse.status == .success,
          !timeRequest.isExpired(
            receivedAtUptimeNanoseconds: startedAt,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
          ),
          let body = timeResponse.body,
          (1...20).contains(body.count),
          let value = String(data: body, encoding: .utf8),
          let guestTime = UInt64(value), guestTime > 0,
          String(guestTime) == value
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        try lock.withLock {
          guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor else {
            throw DoryMacGuestIntegrationWire.WireError.connectionClosed
          }
          snapshotStorage = .init(
            state: .healthy, runtimeGeneration: runtimeGeneration,
            guestToolsVersion: hello.toolsVersion,
            guestToolsBuild: hello.toolsBuild,
            guestOSVersion: report.guestOSVersion,
            grantedCapabilities: grants,
            lastHealthAt: snapshotStorage.lastHealthAt,
            guestTimeUnixMilliseconds: guestTime,
            lastErrorCode: nil
          )
        }
        guard requestID < .max else { break }
        requestID += 1
      }
      if let pending = lock.withLock({ pendingOpenURL }), grants.contains(.openURL) {
        guard requestID < .max else { break }
        let openRequest = try DoryMacGuestIntegrationWire.Envelope(
          kind: .request, sessionID: sessionID, machineID: machineID,
          runtimeGeneration: runtimeGeneration, requestID: requestID,
          capability: .openURL, timeoutMilliseconds: 5_000, body: pending.body
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt + 5_000_000_000
        // Cancellation before dispatch must not turn a stale queued request into a guest action.
        guard lock.withLock({ () -> Bool in
          guard pendingOpenURL === pending && !pending.cancelled else { return false }
          pending.dispatched = true
          return true
        }) else {
          continue
        }
        try DoryMacGuestIntegrationWire.writeFrame(
          openRequest, to: descriptor, deadlineUptimeNanoseconds: deadline
        )
        let openResponse = try DoryMacGuestIntegrationWire.readFrame(
          from: descriptor, deadlineUptimeNanoseconds: deadline
        )
        guard openResponse.kind == .response,
          openResponse.sessionID == sessionID,
          openResponse.machineID == machineID,
          openResponse.runtimeGeneration == runtimeGeneration,
          openResponse.requestID == requestID,
          openResponse.capability == .openURL,
          openResponse.body == nil,
          !openRequest.isExpired(
            receivedAtUptimeNanoseconds: startedAt,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
          ),
          let status = openResponse.status
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        switch status {
        case .success: finishPendingOpenURL(pending, result: .success(()))
        case .expired: finishPendingOpenURL(pending, result: .failure(
          DoryVZMacGuestIntegrationError.outcomeUnknown
        ))
        default: finishPendingOpenURL(pending, result: .failure(
          DoryVZMacGuestIntegrationError.denied
        ))
        }
        requestID += 1
      }
      if let pending = lock.withLock({ pendingClipboardRead }),
        grants.contains(pending.capability) {
        guard requestID < .max else { break }
        let timeoutMilliseconds: UInt32 = pending.capability == .clipboardImageRead
          ? 10_000 : 5_000
        let readRequest = try DoryMacGuestIntegrationWire.Envelope(
          kind: .request, sessionID: sessionID, machineID: machineID,
          runtimeGeneration: runtimeGeneration, requestID: requestID,
          capability: pending.capability, timeoutMilliseconds: timeoutMilliseconds,
          body: pending.requestBody
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt + UInt64(timeoutMilliseconds) * 1_000_000
        guard lock.withLock({ () -> Bool in
          guard pendingClipboardRead === pending && !pending.cancelled else { return false }
          pending.dispatched = true
          return true
        }) else {
          continue
        }
        try DoryMacGuestIntegrationWire.writeFrame(
          readRequest, to: descriptor, deadlineUptimeNanoseconds: deadline
        )
        let readResponse = try DoryMacGuestIntegrationWire.readFrame(
          from: descriptor, deadlineUptimeNanoseconds: deadline
        )
        guard readResponse.kind == .response,
          readResponse.sessionID == sessionID,
          readResponse.machineID == machineID,
          readResponse.runtimeGeneration == runtimeGeneration,
          readResponse.requestID == requestID,
          readResponse.capability == pending.capability,
          !readRequest.isExpired(
            receivedAtUptimeNanoseconds: startedAt,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
          ),
          let status = readResponse.status
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        switch status {
        case .success:
          guard let body = readResponse.body else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          if pending.capability == .clipboardTextRead {
            _ = try DoryMacGuestIntegrationWire.decodeClipboardTextResponse(body)
          } else if pending.capability == .clipboardImageRead {
            try DoryMacGuestIntegrationWire.validateClipboardPNG(body)
          } else if pending.capability == .filePull {
            let offer = try DoryMacGuestIntegrationWire.decodeFilePullBody(
              body, as: DoryMacGuestIntegrationWire.FilePullOffer.self
            )
            try offer.validate()
          } else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          finishPendingClipboardRead(pending, result: .success(body))
        case .expired:
          guard readResponse.body == nil else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          finishPendingClipboardRead(pending, result: .failure(
            DoryVZMacGuestIntegrationError.expired
          ))
        default:
          guard readResponse.body == nil else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          finishPendingClipboardRead(pending, result: .failure(
            DoryVZMacGuestIntegrationError.denied
          ))
        }
        requestID += 1
      }
      if let pending = lock.withLock({ pendingClipboardWrite }),
        grants.contains(pending.capability) {
        guard requestID < .max else { break }
        let timeoutMilliseconds: UInt32 = pending.capability == .clipboardImageWrite
          ? 10_000 : 5_000
        let writeRequest = try DoryMacGuestIntegrationWire.Envelope(
          kind: .request, sessionID: sessionID, machineID: machineID,
          runtimeGeneration: runtimeGeneration, requestID: requestID,
          capability: pending.capability, timeoutMilliseconds: timeoutMilliseconds,
          body: pending.body
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt + UInt64(timeoutMilliseconds) * 1_000_000
        guard lock.withLock({ () -> Bool in
          guard pendingClipboardWrite === pending && !pending.cancelled else { return false }
          pending.dispatched = true
          return true
        }) else {
          continue
        }
        try DoryMacGuestIntegrationWire.writeFrame(
          writeRequest, to: descriptor, deadlineUptimeNanoseconds: deadline
        )
        let writeResponse = try DoryMacGuestIntegrationWire.readFrame(
          from: descriptor, deadlineUptimeNanoseconds: deadline
        )
        guard writeResponse.kind == .response,
          writeResponse.sessionID == sessionID,
          writeResponse.machineID == machineID,
          writeResponse.runtimeGeneration == runtimeGeneration,
          writeResponse.requestID == requestID,
          writeResponse.capability == pending.capability,
          writeResponse.body == nil,
          !writeRequest.isExpired(
            receivedAtUptimeNanoseconds: startedAt,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
          ),
          let status = writeResponse.status
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        switch status {
        case .success: finishPendingClipboardWrite(pending, result: .success(()))
        case .expired: finishPendingClipboardWrite(pending, result: .failure(
          DoryVZMacGuestIntegrationError.outcomeUnknown
        ))
        default: finishPendingClipboardWrite(pending, result: .failure(
          DoryVZMacGuestIntegrationError.denied
        ))
        }
        requestID += 1
      }
      if let pending = lock.withLock({ pendingFilePush }), grants.contains(.filePush) {
        guard lock.withLock({ () -> Bool in
          guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor,
            pendingFilePush === pending && !pending.cancelled else { return false }
          pending.dispatched = true
          return true
        }) else { continue }
        do {
          try transferFile(
            pending, descriptor: descriptor, connectionID: connectionID,
            sessionID: sessionID, requestID: &requestID
          )
          finishPendingFilePush(pending, result: .success(()))
        } catch {
          let commitDispatched = lock.withLock { pending.commitDispatched }
          finishPendingFilePush(
            pending,
            result: .failure(commitDispatched
              ? DoryVZMacGuestIntegrationError.outcomeUnknown : error)
          )
          // A partial transfer is session-bound. Disconnect so the guest discards its staging
          // file before any subsequent user action is admitted.
          throw error
        }
      }
      if let pending = lock.withLock({ pendingFilePull }), grants.contains(.filePull) {
        guard lock.withLock({ () -> Bool in
          guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor,
            pendingFilePull === pending && !pending.cancelled else { return false }
          pending.dispatched = true
          return true
        }) else { continue }
        do {
          try transferGuestFile(
            pending, descriptor: descriptor, connectionID: connectionID,
            sessionID: sessionID, requestID: &requestID
          )
          finishPendingFilePull(pending, result: .success(()))
        } catch {
          let publicationStarted = lock.withLock { pending.publicationStarted }
          finishPendingFilePull(
            pending,
            result: .failure(publicationStarted
              ? DoryVZMacGuestIntegrationError.outcomeUnknown : error)
          )
          throw error
        }
      }
      // One active request at a time bounds memory and makes replay detection unambiguous.
      _ = sleepSignal.wait(timeout: .now() + 5)
    }
  }

  private func transferFile(
    _ pending: PendingFilePush, descriptor: Int32, connectionID: UUID, sessionID: UUID,
    requestID: inout UInt64
  ) throws {
    let scoped = pending.url.startAccessingSecurityScopedResource()
    defer { if scoped { pending.url.stopAccessingSecurityScopedResource() } }
    let source = try FileHandle(forReadingFrom: pending.url)
    defer { try? source.close() }
    var metadata = stat()
    guard fstat(source.fileDescriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_size >= 0,
      UInt64(metadata.st_size) <= DoryMacGuestIntegrationWire.maximumFileBytes
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    let byteCount = UInt64(metadata.st_size)
    let transferID = UUID()
    let begin = try DoryMacGuestIntegrationWire.FilePushRequest(
      phase: .begin, transferID: transferID,
      name: pending.url.lastPathComponent, byteCount: byteCount
    )
    try exchangeFilePush(
      begin, pending: pending, descriptor: descriptor, connectionID: connectionID,
      sessionID: sessionID, requestID: &requestID
    )
    var offset: UInt64 = 0
    var digest = SHA256()
    while offset < byteCount {
      guard lock.withLock({ connectionAuthority.permits(connectionID)
        && activeDescriptor == descriptor && pendingFilePush === pending && !pending.cancelled }) else {
        throw CancellationError()
      }
      let count = Int(min(
        UInt64(DoryMacGuestIntegrationWire.maximumFileChunkBytes), byteCount - offset
      ))
      var data = Data()
      while data.count < count {
        guard let part = try source.read(upToCount: count - data.count), !part.isEmpty else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        data.append(part)
      }
      let chunk = try DoryMacGuestIntegrationWire.FilePushRequest(
        phase: .chunk, transferID: transferID, offset: offset, chunk: data
      )
      try exchangeFilePush(
        chunk, pending: pending, descriptor: descriptor, connectionID: connectionID,
        sessionID: sessionID, requestID: &requestID
      )
      digest.update(data: data)
      offset += UInt64(count)
    }
    guard (try source.read(upToCount: 1) ?? Data()).isEmpty,
      fstat(source.fileDescriptor, &metadata) == 0,
      metadata.st_size >= 0, UInt64(metadata.st_size) == byteCount
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
    let commit = try DoryMacGuestIntegrationWire.FilePushRequest(
      phase: .commit, transferID: transferID, sha256: checksum
    )
    try exchangeFilePush(
      commit, pending: pending, descriptor: descriptor, connectionID: connectionID,
      sessionID: sessionID, requestID: &requestID
    )
  }

  private func exchangeFilePush(
    _ command: DoryMacGuestIntegrationWire.FilePushRequest,
    pending: PendingFilePush, descriptor: Int32, connectionID: UUID,
    sessionID: UUID, requestID: inout UInt64
  ) throws {
    guard requestID < .max else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let body = try DoryMacGuestIntegrationWire.encodeFilePushRequest(command)
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: runtimeGeneration, requestID: requestID,
      capability: .filePush, timeoutMilliseconds: 10_000, body: body
    )
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: startedAt)
    let deadline = admission.deadlineUptimeNanoseconds
    guard lock.withLock({ () -> Bool in
      guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor,
        snapshotStorage.grantedCapabilities.contains(.filePush),
        pendingFilePush === pending, !pending.cancelled else { return false }
      if command.phase == .commit { pending.commitDispatched = true }
      return true
    }) else { throw CancellationError() }
    try DoryMacGuestIntegrationWire.writeFrame(
      request, to: descriptor, deadlineUptimeNanoseconds: deadline
    )
    let response = try DoryMacGuestIntegrationWire.readFrame(
      from: descriptor, deadlineUptimeNanoseconds: deadline
    )
    guard response.kind == .response, response.sessionID == sessionID,
      response.machineID == machineID,
      response.runtimeGeneration == runtimeGeneration,
      response.requestID == requestID, response.capability == .filePush,
      response.status == .success, response.body == nil,
      !request.isExpired(
        receivedAtUptimeNanoseconds: startedAt,
        nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
      )
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    guard lock.withLock({ connectionAuthority.permits(connectionID)
      && activeDescriptor == descriptor && pendingFilePush === pending && !pending.cancelled }) else {
      throw CancellationError()
    }
    requestID += 1
  }

  private func transferGuestFile(
    _ pending: PendingFilePull, descriptor: Int32, connectionID: UUID, sessionID: UUID,
    requestID: inout UInt64
  ) throws {
    let scoped = pending.destination.startAccessingSecurityScopedResource()
    defer { if scoped { pending.destination.stopAccessingSecurityScopedResource() } }
    let publication = try DoryVZMacGuestFilePublication(destination: pending.destination)
    let output = publication.output
    var offset: UInt64 = 0
    var digest = SHA256()
    while offset < pending.offer.byteCount {
      guard lock.withLock({ connectionAuthority.permits(connectionID)
        && activeDescriptor == descriptor && pendingFilePull === pending && !pending.cancelled }) else {
        throw CancellationError()
      }
      let command = try DoryMacGuestIntegrationWire.FilePullRequest(
        phase: .chunk, offerID: pending.offer.offerID, offset: offset
      )
      let response = try exchangeFilePull(
        command, pending: pending, descriptor: descriptor, connectionID: connectionID,
        sessionID: sessionID, requestID: &requestID
      )
      let count = Int(min(
        UInt64(DoryMacGuestIntegrationWire.maximumFileChunkBytes),
        pending.offer.byteCount - offset
      ))
      guard let body = response.body, body.count == count else {
        throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
      }
      try output.write(contentsOf: body)
      digest.update(data: body)
      offset += UInt64(body.count)
    }
    let finish = try DoryMacGuestIntegrationWire.FilePullRequest(
      phase: .finish, offerID: pending.offer.offerID
    )
    let response = try exchangeFilePull(
      finish, pending: pending, descriptor: descriptor, connectionID: connectionID,
      sessionID: sessionID, requestID: &requestID)
    guard let body = response.body else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    let receivedDigest = try DoryMacGuestIntegrationWire.decodeFilePullBody(
      body, as: DoryMacGuestIntegrationWire.FilePullDigest.self
    )
    try receivedDigest.validate()
    let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard receivedDigest.sha256 == checksum else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    var admission = response.admission
    try publication.publish { mutation in
      try lock.withLock {
        guard connectionAuthority.permits(connectionID), activeDescriptor == descriptor,
          snapshotStorage.grantedCapabilities.contains(.filePull),
          pendingFilePull === pending, !pending.cancelled else { throw CancellationError() }
        // A valid finish response can precede peer shutdown while preparation flushes. Local
        // connection ownership alone cannot authorize publication after that terminal event.
        guard Self.peerPermitsPublication(descriptor) else {
          throw DoryMacGuestIntegrationWire.WireError.connectionClosed
        }
        guard admission.begin(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) else {
          throw DoryVZMacGuestIntegrationError.expired
        }
        pending.publicationStarted = true
        try mutation()
      }
    }
  }

  private struct FilePullResponse {
    let body: Data?
    let admission: DoryMacGuestIntegrationWire.UserActionAdmission
  }

  private func exchangeFilePull(
    _ command: DoryMacGuestIntegrationWire.FilePullRequest,
    pending: PendingFilePull, descriptor: Int32, connectionID: UUID,
    sessionID: UUID, requestID: inout UInt64
  ) throws -> FilePullResponse {
    guard requestID < .max else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let body = try DoryMacGuestIntegrationWire.encodeFilePullBody(command)
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: runtimeGeneration, requestID: requestID,
      capability: .filePull, timeoutMilliseconds: 10_000, body: body
    )
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: startedAt)
    let deadline = admission.deadlineUptimeNanoseconds
    guard lock.withLock({ connectionAuthority.permits(connectionID)
      && activeDescriptor == descriptor && snapshotStorage.grantedCapabilities.contains(.filePull)
      && pendingFilePull === pending && !pending.cancelled }) else { throw CancellationError() }
    try DoryMacGuestIntegrationWire.writeFrame(
      request, to: descriptor, deadlineUptimeNanoseconds: deadline
    )
    let response = try DoryMacGuestIntegrationWire.readFrame(
      from: descriptor, deadlineUptimeNanoseconds: deadline
    )
    guard response.kind == .response, response.sessionID == sessionID,
      response.machineID == machineID,
      response.runtimeGeneration == runtimeGeneration,
      response.requestID == requestID, response.capability == .filePull,
      response.status == .success,
      !request.isExpired(
        receivedAtUptimeNanoseconds: startedAt,
        nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
      )
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    guard lock.withLock({ connectionAuthority.permits(connectionID)
      && activeDescriptor == descriptor && pendingFilePull === pending && !pending.cancelled }) else {
      throw CancellationError()
    }
    requestID += 1
    return FilePullResponse(body: response.body, admission: admission)
  }

  private func finishPendingOpenURL(
    _ pending: PendingOpenURL, result: Result<Void, Error>
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard pendingOpenURL === pending else { return nil }
      pendingOpenURL = nil
      defer { pending.continuation = nil }
      return pending.continuation
    }
    continuation?.resume(with: result)
  }

  private func finishPendingClipboardRead(
    _ pending: PendingClipboardRead, result: Result<Data, Error>
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
      guard pendingClipboardRead === pending else { return nil }
      pendingClipboardRead = nil
      defer { pending.continuation = nil }
      return pending.continuation
    }
    continuation?.resume(with: result)
  }

  private func finishPendingClipboardWrite(
    _ pending: PendingClipboardWrite, result: Result<Void, Error>
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard pendingClipboardWrite === pending else { return nil }
      pendingClipboardWrite = nil
      defer { pending.continuation = nil }
      return pending.continuation
    }
    continuation?.resume(with: result)
  }

  private func finishPendingFilePush(
    _ pending: PendingFilePush, result: Result<Void, Error>
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard pendingFilePush === pending else { return nil }
      pendingFilePush = nil
      defer { pending.continuation = nil }
      return pending.continuation
    }
    continuation?.resume(with: result)
  }

  private func finishPendingFilePull(
    _ pending: PendingFilePull, result: Result<Void, Error>
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard pendingFilePull === pending else { return nil }
      pendingFilePull = nil
      defer { pending.continuation = nil }
      return pending.continuation
    }
    continuation?.resume(with: result)
  }

  private typealias PendingRequestContinuations = (
      CheckedContinuation<Void, Error>?, CheckedContinuation<Data, Error>?,
      CheckedContinuation<Void, Error>?, CheckedContinuation<Void, Error>?,
      CheckedContinuation<Void, Error>?, Bool, Bool, Bool, Bool
  )

  /// Called only with the service lock held, before releasing connection ownership.
  private func takePendingRequestsLocked() -> PendingRequestContinuations {
      let openURL = pendingOpenURL?.continuation
      let openURLDispatched = pendingOpenURL?.dispatched == true
      let clipboardRead = pendingClipboardRead?.continuation
      let clipboardWrite = pendingClipboardWrite?.continuation
      let clipboardWriteDispatched = pendingClipboardWrite?.dispatched == true
      let filePush = pendingFilePush?.continuation
      let fileCommitDispatched = pendingFilePush?.commitDispatched == true
      let filePull = pendingFilePull?.continuation
      let filePublicationStarted = pendingFilePull?.publicationStarted == true
      pendingOpenURL?.continuation = nil
      pendingOpenURL = nil
      pendingClipboardRead?.continuation = nil
      pendingClipboardRead = nil
      pendingClipboardWrite?.continuation = nil
      pendingClipboardWrite = nil
      pendingFilePush?.continuation = nil
      pendingFilePush = nil
      pendingFilePull?.continuation = nil
      pendingFilePull = nil
      return (
        openURL, clipboardRead, clipboardWrite, filePush, filePull,
        openURLDispatched, clipboardWriteDispatched, fileCommitDispatched,
        filePublicationStarted
      )
  }

  private func resumeFailedRequests(_ continuations: PendingRequestContinuations) {
    continuations.0?.resume(throwing: Self.interruptedActionError(
      dispatched: continuations.5))
    continuations.1?.resume(throwing: DoryVZMacGuestIntegrationError.unavailable)
    continuations.2?.resume(throwing: Self.interruptedActionError(
      dispatched: continuations.6))
    continuations.3?.resume(throwing: Self.interruptedActionError(
      dispatched: continuations.7))
    continuations.4?.resume(throwing: Self.interruptedActionError(
      dispatched: continuations.8))
  }

  private func disconnectedSnapshot(
    errorCode: String? = nil
  ) -> DoryVZMacGuestIntegrationSnapshot {
    .init(
      state: .disconnected, runtimeGeneration: runtimeGeneration,
      guestToolsVersion: nil, guestToolsBuild: nil, guestOSVersion: nil,
      grantedCapabilities: [], lastHealthAt: nil, guestTimeUnixMilliseconds: nil,
      lastErrorCode: errorCode
    )
  }

  /// Called with exact connection ownership held immediately before publication. A quiet
  /// live socket is the only permitted state: EOF/HUP/ERR/NVAL, unexpected readable protocol
  /// bytes and any poll failure (including EINTR) all fail closed without consuming bytes.
  static func peerPermitsPublication(
    _ descriptor: Int32,
    pollPeer: (inout pollfd) -> Int32 = { peer in Darwin.poll(&peer, 1, 0) }
  ) -> Bool {
    guard descriptor >= 0 else { return false }
    var peer = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    return pollPeer(&peer) == 0 && peer.revents == 0
  }

  private static func errorCode(for error: Error) -> String {
    guard let wire = error as? DoryMacGuestIntegrationWire.WireError else {
      return "invalid-health"
    }
    switch wire {
    case .invalidEnvelope, .nonCanonicalFrame: return "protocol-rejected"
    case .invalidFrameLength: return "invalid-frame"
    case .connectionClosed: return "disconnected"
    case .ioFailure(ETIMEDOUT): return "timeout"
    case .ioFailure: return "transport-error"
    }
  }

  private static func configureSocket(_ descriptor: Int32) throws {
    var noSignal: Int32 = 1
    guard setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else { throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      guard setsockopt(
        descriptor, SOL_SOCKET, option, &timeout,
        socklen_t(MemoryLayout<timeval>.size)
      ) == 0 else { throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno) }
    }
  }

  deinit { remove() }

  private final class ConnectionBox: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    init(_ connection: VZVirtioSocketConnection) { self.connection = connection }
  }
}
