import DoryMachinePC
import DoryVMContracts
import Foundation
import Testing
@testable import DoryHostDeviceBroker

struct DoryIOUSBHostCapabilityLifetimeTests {
  @Test func closeDuringResetCannotInstallAReplacementOrDoubleCloseTheOldHandle() throws {
    let original = Backend()
    original.blockReset = true
    let replacement = Backend()
    let capability = makeCapability(original) { _ in replacement }
    let resetResult = Value<Bool>()
    let resetFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      resetResult.set(capability.reset(deadline: .now.advanced(by: .seconds(2))))
      resetFinished.signal()
    }
    #expect(original.resetEntered.wait(timeout: .now() + 1) == .success)
    let closeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { capability.close(); closeFinished.signal() }
    #expect(original.abortEntered.wait(timeout: .now() + 1) == .success)
    original.releaseReset.signal()
    #expect(resetFinished.wait(timeout: .now() + 1) == .success)
    #expect(closeFinished.wait(timeout: .now() + 1) == .success)
    #expect(resetResult.get() == false)
    #expect(original.closeCount == 1)
    #expect(replacement.closeCount == 0)
    #expect(capability.perform(try transfer(), deadline: .now.advanced(by: .seconds(1))).status == .disconnected)
  }

  @Test func closeDuringReopenClosesTheUnadmittedReplacement() throws {
    let original = Backend()
    let replacement = Backend()
    let reopenEntered = DispatchSemaphore(value: 0)
    let releaseReopen = DispatchSemaphore(value: 0)
    let capability = makeCapability(original) { _ in
      reopenEntered.signal()
      _ = releaseReopen.wait(timeout: .now() + 2)
      return replacement
    }
    let resetResult = Value<Bool>()
    let resetFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      resetResult.set(capability.reset(deadline: .now.advanced(by: .seconds(2))))
      resetFinished.signal()
    }
    #expect(reopenEntered.wait(timeout: .now() + 1) == .success)
    let closeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { capability.close(); closeFinished.signal() }
    // Late handler registration observes terminal revocation before close finishes joining reset.
    let revoked = DispatchSemaphore(value: 0)
    var observedTerminalClose = false
    for _ in 0..<100 {
      capability.setRevocationHandler { revoked.signal() }
      if revoked.wait(timeout: .now() + .milliseconds(10)) == .success {
        observedTerminalClose = true
        break
      }
    }
    #expect(observedTerminalClose)
    releaseReopen.signal()
    #expect(resetFinished.wait(timeout: .now() + 1) == .success)
    #expect(closeFinished.wait(timeout: .now() + 1) == .success)
    #expect(resetResult.get() == false)
    #expect(original.closeCount == 1)
    #expect(replacement.closeCount == 1)
    #expect(capability.perform(try transfer(), deadline: .now.advanced(by: .seconds(1))).status == .disconnected)
  }

  @Test func queuedTransferAndResetUseTheirOriginalDeadline() throws {
    let backend = Backend()
    backend.blockData = true
    let capability = makeCapability(backend)
    let first = try transfer()
    let firstFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = capability.perform(first, deadline: .now.advanced(by: .seconds(2)))
      firstFinished.signal()
    }
    #expect(backend.dataEntered.wait(timeout: .now() + 1) == .success)
    let clock = ContinuousClock()
    let started = clock.now
    #expect(capability.perform(first, deadline: started.advanced(by: .milliseconds(20))).status == .transactionError)
    #expect(!capability.reset(deadline: clock.now.advanced(by: .milliseconds(20))))
    #expect(started.duration(to: clock.now) < .seconds(1))
    #expect(backend.dataCount == 1)
    #expect(backend.resetCount == 0)
    backend.releaseData.signal()
    #expect(firstFinished.wait(timeout: .now() + 1) == .success)
    capability.close()
  }

  @Test func completionAfterTerminalCloseCannotPublishGuestPayload() throws {
    let backend = Backend()
    backend.blockData = true
    let capability = makeCapability(backend)
    let request = try transfer()
    let result = Value<DoryPCUSBTransferResult>()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      result.set(capability.perform(request, deadline: .now.advanced(by: .seconds(2))))
      finished.signal()
    }
    #expect(backend.dataEntered.wait(timeout: .now() + 1) == .success)
    let closeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { capability.close(); closeFinished.signal() }
    #expect(backend.abortEntered.wait(timeout: .now() + 1) == .success)
    backend.releaseData.signal()
    #expect(finished.wait(timeout: .now() + 1) == .success)
    #expect(closeFinished.wait(timeout: .now() + 1) == .success)
    #expect(result.get()?.status == .disconnected)
    #expect(result.get()?.payload.isEmpty == true)
    #expect(backend.closeCount == 1)
  }

  @Test func removalBeforeHandlerRegistrationIsNotLostAndDuplicateCallbacksAreIgnored() {
    let backend = Backend()
    let capability = makeCapability(backend)
    backend.disconnect()
    let notifications = Counter()
    capability.setRevocationHandler { notifications.increment() }
    backend.disconnect()
    #expect(notifications.count == 1)
    capability.close()
  }

  @Test func oldBackendCallbackCannotRevokeAnInstalledReplacement() {
    let original = Backend()
    let replacement = Backend()
    let capability = makeCapability(original) { _ in replacement }
    let oldCallback = original.callback
    let notifications = Counter()
    capability.setRevocationHandler { notifications.increment() }
    #expect(capability.reset(deadline: .now.advanced(by: .seconds(1))))
    oldCallback?()
    #expect(notifications.count == 0)
    replacement.disconnect()
    #expect(notifications.count == 1)
    capability.close()
  }

  @Test func resetMayReplaceItsOwnTransientlyDisconnectedHandle() {
    let original = Backend()
    original.disconnectDuringReset = true
    let replacement = Backend()
    let capability = makeCapability(original) { _ in replacement }
    let notifications = Counter()
    capability.setRevocationHandler { notifications.increment() }
    #expect(capability.reset(deadline: .now.advanced(by: .seconds(1))))
    #expect(original.closeCount == 1)
    #expect(replacement.connected)
    #expect(notifications.count == 0)
    capability.close()
    #expect(replacement.closeCount == 1)
  }

  @Test func synchronousRemovalCallbackCanCloseWithoutReenteringTheOperationGate() throws {
    let backend = Backend()
    backend.disconnectDuringData = true
    let capability = makeCapability(backend)
    let revoked = DispatchSemaphore(value: 0)
    capability.setRevocationHandler { capability.close(); revoked.signal() }
    #expect(capability.perform(try transfer(), deadline: .now.advanced(by: .seconds(1))).status == .disconnected)
    #expect(revoked.wait(timeout: .now() + 1) == .success)
    #expect(backend.closeCount == 1)
  }

  @Test func revokedAdmissionStillCancelsAnOutstandingPlatformOperation() throws {
    let backend = Backend()
    backend.blockData = true
    let capability = makeCapability(backend)
    capability.setRevocationHandler { capability.cancelAll() }
    let request = try transfer()
    let result = Value<DoryPCUSBTransferResult>()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      result.set(capability.perform(request, deadline: .now.advanced(by: .seconds(2))))
      finished.signal()
    }
    #expect(backend.dataEntered.wait(timeout: .now() + 1) == .success)
    backend.disconnect()
    #expect(backend.abortEntered.wait(timeout: .now() + 1) == .success)
    backend.releaseData.signal()
    #expect(finished.wait(timeout: .now() + 1) == .success)
    #expect(result.get()?.status == .disconnected)
    #expect(result.get()?.payload.isEmpty == true)
    capability.close()
    #expect(backend.closeCount == 1)
  }

  private func makeCapability(
    _ backend: Backend,
    reopener: DoryIOUSBHostTransferCapability.Reopener? = nil
  ) -> DoryIOUSBHostTransferCapability {
    .init(identityToken: .init(rawValue: String(repeating: "e", count: 64))!, speed: .high,
          backend: backend, reopener: reopener)
  }

  private func transfer() throws -> DoryPCUSBTransfer {
    try .init(type: .bulk, direction: .in, endpoint: 1, maximumResponseBytes: 4)
  }

  private final class Value<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func get() -> T? { lock.withLock { value } }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
  }

  private final class Backend: DoryIOUSBHostOperating, @unchecked Sendable {
    let resetEntered = DispatchSemaphore(value: 0)
    let releaseReset = DispatchSemaphore(value: 0)
    let dataEntered = DispatchSemaphore(value: 0)
    let releaseData = DispatchSemaphore(value: 0)
    let abortEntered = DispatchSemaphore(value: 0)
    var blockReset = false
    var blockData = false
    var disconnectDuringData = false
    var disconnectDuringReset = false
    private let lock = NSLock()
    private var active = true
    private var closeTotal = 0
    private var dataTotal = 0
    private var resetTotal = 0
    private var handler: (@Sendable () -> Void)?
    var connected: Bool { lock.withLock { active } }
    var closeCount: Int { lock.withLock { closeTotal } }
    var dataCount: Int { lock.withLock { dataTotal } }
    var resetCount: Int { lock.withLock { resetTotal } }
    var callback: (@Sendable () -> Void)? { lock.withLock { handler } }
    func setDisconnectHandler(_ value: (@Sendable () -> Void)?) { lock.withLock { handler = value } }
    func sendControl(_ request: DoryIOUSBHostControlRequest, payload: [UInt8],
                     maximumResponseBytes: Int, deadline: ContinuousClock.Instant) throws -> DoryIOUSBHostCompletion {
      .init(payload: [], bytesTransferred: 0)
    }
    func sendData(type: DoryPCUSBTransferType, endpointAddress: UInt8, payload: [UInt8],
                  maximumResponseBytes: Int, deadline: ContinuousClock.Instant) throws -> DoryIOUSBHostCompletion {
      lock.withLock { dataTotal += 1 }
      dataEntered.signal()
      if blockData { _ = releaseData.wait(timeout: .now() + 2) }
      if disconnectDuringData { disconnect() }
      return .init(payload: [1, 2, 3, 4], bytesTransferred: 4)
    }
    func configure(value: UInt8, deadline: ContinuousClock.Instant) throws {}
    func selectAlternateSetting(interface: UInt8, alternateSetting: UInt8, deadline: ContinuousClock.Instant) throws {}
    func clearStall(endpointAddress: UInt8, deadline: ContinuousClock.Instant) throws {}
    func reset(deadline: ContinuousClock.Instant) throws {
      lock.withLock { resetTotal += 1 }
      resetEntered.signal()
      if blockReset { _ = releaseReset.wait(timeout: .now() + 2) }
      if disconnectDuringReset { disconnect() }
    }
    func abortAll() { abortEntered.signal() }
    func close() { lock.withLock { active = false; closeTotal += 1 } }
    func disconnect() {
      let notification = lock.withLock { () -> (@Sendable () -> Void)? in
        active = false
        return handler
      }
      notification?()
    }
  }
}
