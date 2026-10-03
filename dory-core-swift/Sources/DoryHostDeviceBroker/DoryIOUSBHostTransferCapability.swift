import DoryMachinePC
import DoryVMContracts
import Foundation

struct DoryIOUSBHostControlRequest: Sendable, Hashable {
  let requestType: UInt8
  let request: UInt8
  let value: UInt16
  let index: UInt16
  let length: UInt16
}

struct DoryIOUSBHostCompletion: Sendable, Hashable {
  let payload: [UInt8]
  let bytesTransferred: Int
}

enum DoryIOUSBHostOperationError: Error, Sendable, Equatable {
  case deadlineExpired
  case stalled
  case disconnected
  case unavailable
  case transactionFailed(Int32)
}

protocol DoryIOUSBHostOperating: AnyObject, Sendable {
  var connected: Bool { get }
  func setDisconnectHandler(_ handler: (@Sendable () -> Void)?)
  func sendControl(
    _ request: DoryIOUSBHostControlRequest,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion
  func sendData(
    type: DoryPCUSBTransferType,
    endpointAddress: UInt8,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion
  func configure(value: UInt8, deadline: ContinuousClock.Instant) throws
  func selectAlternateSetting(
    interface: UInt8,
    alternateSetting: UInt8,
    deadline: ContinuousClock.Instant
  ) throws
  func clearStall(endpointAddress: UInt8, deadline: ContinuousClock.Instant) throws
  func reset(deadline: ContinuousClock.Instant) throws
  func abortAll()
  func close()
}

/// Transfer policy shared by the public IOUSBHost adapter and deterministic unit-test transports.
/// All guest requests are serialized because configuration and alternate-setting changes invalidate
/// interface pipes process-wide for the captured physical device.
public final class DoryIOUSBHostTransferCapability: DoryHostUSBTransferCapability,
  DoryHostUSBRevocationNotifying, @unchecked Sendable
{
  typealias Reopener = @Sendable (ContinuousClock.Instant) -> (any DoryIOUSBHostOperating)?

  public let identityToken: DoryUSBPhysicalIdentityToken
  public let speed: DoryPCXHCIPortSpeed

  private let stateLock = NSLock()
  private let operationGate = DispatchSemaphore(value: 1)
  private let revocationQueue = DispatchQueue(label: "com.dory.host-usb.revocation")
  private let reopener: Reopener?
  private var backend: (any DoryIOUSBHostOperating)?
  private var backendGeneration = UUID()
  private var resetting = false
  private var closed = false
  private var revoked = false
  private var revocationHandler: (@Sendable () -> Void)?

  init(
    identityToken: DoryUSBPhysicalIdentityToken,
    speed: DoryPCXHCIPortSpeed,
    backend: any DoryIOUSBHostOperating,
    reopener: Reopener? = nil
  ) {
    self.identityToken = identityToken
    self.speed = speed
    self.backend = backend
    self.reopener = reopener
    installDisconnectHandler(on: backend, generation: backendGeneration)
  }

  public func setRevocationHandler(_ handler: (@Sendable () -> Void)?) {
    let notify = stateLock.withLock { () -> Bool in
      revocationHandler = closed || revoked ? nil : handler
      return (closed || revoked) && handler != nil
    }
    if notify, let handler { deliverRevocation(handler) }
  }

  public func perform(
    _ transfer: DoryPCUSBTransfer,
    deadline: ContinuousClock.Instant
  ) -> DoryPCUSBTransferResult {
    guard acquireOperation(before: deadline) else {
      return result(currentBackend() == nil ? .disconnected : .transactionError)
    }
    defer { operationGate.signal() }
    guard let backend = currentBackend(), backend.connected else { return result(.disconnected) }

    do {
      let completion: DoryIOUSBHostCompletion
      if transfer.type == .control {
        guard let setup = transfer.setup else { return result(.transactionError) }
        if try performStandardControlSideEffect(setup, backend: backend, deadline: deadline) {
          guard completionIsCurrent(backend, deadline: deadline) else {
            return result(currentBackend() == nil || !backend.connected ? .disconnected : .transactionError)
          }
          return result(.success)
        }
        completion = try backend.sendControl(
          .init(
            requestType: setup.requestType,
            request: setup.request,
            value: setup.value,
            index: setup.index,
            length: setup.length
          ),
          payload: Array(transfer.payload.prefix(Int(setup.length))),
          maximumResponseBytes: min(transfer.maximumResponseBytes, Int(setup.length)),
          deadline: deadline
        )
      } else {
        let address = transfer.endpoint | (transfer.direction == .in ? 0x80 : 0)
        completion = try backend.sendData(
          type: transfer.type,
          endpointAddress: address,
          payload: transfer.payload,
          maximumResponseBytes: transfer.maximumResponseBytes,
          deadline: deadline
        )
      }
      let expected: Int
      if let setup = transfer.setup {
        expected =
          transfer.direction == .in
          ? min(transfer.maximumResponseBytes, Int(setup.length))
          : min(transfer.payload.count, Int(setup.length))
      } else {
        expected =
          transfer.direction == .in ? transfer.maximumResponseBytes : transfer.payload.count
      }
      let payload = transfer.direction == .in ? completion.payload : []
      guard completionIsCurrent(backend, deadline: deadline) else {
        return result(currentBackend() == nil || !backend.connected ? .disconnected : .transactionError)
      }
      return result(
        completion.bytesTransferred < expected ? .shortPacket : .success,
        payload: payload
      )
    } catch let error as DoryIOUSBHostOperationError {
      return result(currentBackend() == nil || !backend.connected ? .disconnected : Self.status(for: error))
    } catch {
      return result(currentBackend() == nil || !backend.connected ? .disconnected : .transactionError)
    }
  }

  public func reset(deadline: ContinuousClock.Instant) -> Bool {
    guard acquireOperation(before: deadline) else { return false }
    defer { operationGate.signal() }
    guard let oldBackend = currentBackend() else { return false }
    let admitted = stateLock.withLock { () -> Bool in
      guard !closed, !revoked, backend === oldBackend else { return false }
      resetting = true
      return true
    }
    guard admitted else { return false }
    defer { stateLock.withLock { resetting = false } }
    do {
      try oldBackend.reset(deadline: deadline)
    } catch {
      revokeBackend(oldBackend)
      return false
    }
    guard ContinuousClock.now < deadline,
      stateLock.withLock({ !closed && !revoked && backend === oldBackend }) else { return false }
    guard let reopener else { return oldBackend.connected }
    // Transfer the old handle to this reset before closing it. A concurrent terminal close
    // revokes admission immediately but must not close the same platform handle a second time.
    let ownsOldBackend = stateLock.withLock { () -> Bool in
      guard !closed, !revoked, backend === oldBackend else { return false }
      backend = nil
      backendGeneration = UUID()
      return true
    }
    guard ownsOldBackend else { return false }
    oldBackend.setDisconnectHandler(nil)
    oldBackend.close()
    guard ContinuousClock.now < deadline, let replacement = reopener(deadline) else {
      return false
    }
    let generation = UUID()
    let installed = stateLock.withLock { () -> Bool in
      guard !closed, !revoked, ContinuousClock.now < deadline else { return false }
      backend = replacement
      backendGeneration = generation
      resetting = false
      return true
    }
    guard installed else {
      replacement.setDisconnectHandler(nil)
      replacement.abortAll()
      replacement.close()
      return false
    }
    installDisconnectHandler(on: replacement, generation: generation)
    return completionIsCurrent(replacement, deadline: deadline)
  }

  public func cancelAll() {
    // Revocation removes admission, not ownership of an outstanding platform call. Keep
    // cancellation available until close takes that retained handle for final retirement.
    stateLock.withLock { backend }?.abortAll()
  }

  public func close() {
    let old = stateLock.withLock { () -> (any DoryIOUSBHostOperating)? in
      closed = true
      let value = backend
      backend = nil
      revocationHandler = nil
      return value
    }
    old?.setDisconnectHandler(nil)
    old?.abortAll()
    operationGate.wait()
    old?.close()
    operationGate.signal()
  }

  private func performStandardControlSideEffect(
    _ setup: DoryPCUSBSetupPacket,
    backend: any DoryIOUSBHostOperating,
    deadline: ContinuousClock.Instant
  ) throws -> Bool {
    let standard = setup.requestType & 0x60 == 0
    let recipient = setup.requestType & 0x1f
    guard standard, setup.direction == .out else { return false }
    switch (setup.request, recipient) {
    case (9, 0):
      try backend.configure(value: UInt8(truncatingIfNeeded: setup.value), deadline: deadline)
      return true
    case (11, 1):
      try backend.selectAlternateSetting(
        interface: UInt8(truncatingIfNeeded: setup.index),
        alternateSetting: UInt8(truncatingIfNeeded: setup.value),
        deadline: deadline
      )
      return true
    case (1, 2) where setup.value == 0:
      try backend.clearStall(
        endpointAddress: UInt8(truncatingIfNeeded: setup.index), deadline: deadline)
      return true
    default:
      return false
    }
  }

  private func currentBackend() -> (any DoryIOUSBHostOperating)? {
    stateLock.withLock { !closed && !revoked ? backend : nil }
  }

  /// Waiting behind another platform call must consume this request's original deadline,
  /// rather than extending it by an unbounded lock acquisition. Terminal close still joins
  /// without a deadline so an unresponsive handle remains quarantined from another VM.
  private func acquireOperation(before deadline: ContinuousClock.Instant) -> Bool {
    while ContinuousClock.now < deadline {
      let remaining = ContinuousClock.now.duration(to: deadline)
      let slice = min(remaining, .milliseconds(50))
      let parts = slice.components
      let nanoseconds = max(0, Int(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000))
      if operationGate.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success {
        guard ContinuousClock.now < deadline else {
          operationGate.signal()
          return false
        }
        return true
      }
    }
    return false
  }

  private func completionIsCurrent(
    _ candidate: any DoryIOUSBHostOperating,
    deadline: ContinuousClock.Instant
  ) -> Bool {
    ContinuousClock.now < deadline && candidate.connected
      && stateLock.withLock { !closed && !revoked && backend === candidate }
  }

  private func installDisconnectHandler(
    on backend: any DoryIOUSBHostOperating,
    generation: UUID
  ) {
    backend.setDisconnectHandler { [weak self] in self?.backendDisconnected(generation: generation)
    }
  }

  private func backendDisconnected(generation: UUID) {
    let handler = stateLock.withLock { () -> (@Sendable () -> Void)? in
      guard backendGeneration == generation, !resetting, backend != nil,
        !closed, !revoked else { return nil }
      revoked = true
      let handler = revocationHandler
      revocationHandler = nil
      return handler
    }
    if let handler { deliverRevocation(handler) }
  }

  private func deliverRevocation(_ handler: @escaping @Sendable () -> Void) {
    // A platform transport may report disconnect synchronously inside sendData. Its callback
    // must be able to close this capability without recursively waiting on its own operation.
    if operationGate.wait(timeout: .now()) == .success {
      operationGate.signal()
      handler()
    } else {
      revocationQueue.async(execute: handler)
    }
  }

  private func revokeBackend(_ candidate: any DoryIOUSBHostOperating) {
    let ownsBackend = stateLock.withLock { () -> Bool in
      guard backend === candidate else { return false }
      backend = nil
      backendGeneration = UUID()
      return true
    }
    guard ownsBackend else { return }
    candidate.setDisconnectHandler(nil)
    candidate.abortAll()
    candidate.close()
  }

  private static func status(for error: DoryIOUSBHostOperationError) -> DoryPCUSBTransferStatus {
    switch error {
    case .stalled: .stalled
    case .disconnected: .disconnected
    case .unavailable: .notReady
    case .deadlineExpired, .transactionFailed: .transactionError
    }
  }

  private func result(
    _ status: DoryPCUSBTransferStatus,
    payload: [UInt8] = []
  ) -> DoryPCUSBTransferResult {
    try! .init(status: status, payload: payload)
  }

  deinit {
    close()
  }
}
