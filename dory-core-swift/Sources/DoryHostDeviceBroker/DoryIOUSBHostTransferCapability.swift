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
  private let operationLock = NSLock()
  private let reopener: Reopener?
  private var backend: (any DoryIOUSBHostOperating)?
  private var backendGeneration = UUID()
  private var resetting = false
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
    stateLock.withLock { revocationHandler = handler }
  }

  public func perform(
    _ transfer: DoryPCUSBTransfer,
    deadline: ContinuousClock.Instant
  ) -> DoryPCUSBTransferResult {
    operationLock.lock()
    defer { operationLock.unlock() }
    guard ContinuousClock.now < deadline, let backend = currentBackend(), backend.connected else {
      return result(
        backend == nil || !(backend?.connected ?? false) ? .disconnected : .transactionError)
    }

    do {
      let completion: DoryIOUSBHostCompletion
      if transfer.type == .control {
        guard let setup = transfer.setup else { return result(.transactionError) }
        if try performStandardControlSideEffect(setup, backend: backend, deadline: deadline) {
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
      return result(
        completion.bytesTransferred < expected ? .shortPacket : .success,
        payload: payload
      )
    } catch let error as DoryIOUSBHostOperationError {
      return result(Self.status(for: error))
    } catch {
      return result(.transactionError)
    }
  }

  public func reset(deadline: ContinuousClock.Instant) -> Bool {
    operationLock.lock()
    defer { operationLock.unlock() }
    guard ContinuousClock.now < deadline, let oldBackend = currentBackend() else { return false }
    stateLock.withLock { resetting = true }
    defer { stateLock.withLock { resetting = false } }
    do {
      try oldBackend.reset(deadline: deadline)
    } catch {
      revokeBackend(oldBackend)
      return false
    }
    guard let reopener else { return oldBackend.connected }
    oldBackend.setDisconnectHandler(nil)
    oldBackend.close()
    guard ContinuousClock.now < deadline, let replacement = reopener(deadline) else {
      stateLock.withLock { backend = nil }
      return false
    }
    let generation = UUID()
    stateLock.withLock {
      backend = replacement
      backendGeneration = generation
    }
    installDisconnectHandler(on: replacement, generation: generation)
    return replacement.connected
  }

  public func cancelAll() {
    currentBackend()?.abortAll()
  }

  public func close() {
    let old = stateLock.withLock { () -> (any DoryIOUSBHostOperating)? in
      let value = backend
      backend = nil
      revocationHandler = nil
      return value
    }
    old?.setDisconnectHandler(nil)
    old?.abortAll()
    operationLock.withLock { old?.close() }
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
    stateLock.withLock { backend }
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
      guard backendGeneration == generation, !resetting, backend != nil else { return nil }
      return revocationHandler
    }
    handler?()
  }

  private func revokeBackend(_ candidate: any DoryIOUSBHostOperating) {
    candidate.setDisconnectHandler(nil)
    candidate.abortAll()
    candidate.close()
    stateLock.withLock {
      if backend === candidate { backend = nil }
    }
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
