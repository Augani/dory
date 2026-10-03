import DoryHostDeviceBroker
import DoryMachinePC
import DoryVMContracts
import Foundation
import Testing

@Suite struct DoryHostUSBLeaseBrokerTests {
  @Test func requiresSelectionAndProtectsCriticalDevicesAndMountedStorage() throws {
    let broker = DoryHostUSBLeaseBroker()
    let token = identityToken("a")
    let capability = RecordingCapability(identityToken: token)

    #expect(throws: DoryHostUSBLeaseError.userSelectionRequired) {
      try broker.acquire(
        machineID: "machine-a",
        identityToken: token,
        family: .camera,
        admission: .init(userSelected: false),
        capability: capability
      )
    }
    #expect(throws: DoryHostUSBLeaseError.hostCriticalDevice(.keyboard)) {
      try broker.acquire(
        machineID: "machine-a",
        identityToken: token,
        family: .keyboard,
        admission: .init(userSelected: true),
        capability: capability
      )
    }
    #expect(throws: DoryHostUSBLeaseError.writableStorageMounted) {
      try broker.acquire(
        machineID: "machine-a",
        identityToken: token,
        family: .storage,
        admission: .init(userSelected: true),
        capability: capability
      )
    }
  }

  @Test func enforcesStableIdentityExclusiveOwnershipAndMachineLimits() throws {
    let broker = DoryHostUSBLeaseBroker(maximumLeasesPerMachine: 1)
    let firstToken = identityToken("a")
    let secondToken = identityToken("b")
    let first = RecordingCapability(identityToken: firstToken)
    let second = RecordingCapability(identityToken: secondToken)
    let lease = try broker.acquire(
      machineID: "machine-a",
      identityToken: firstToken,
      family: .camera,
      admission: .init(userSelected: true),
      capability: first
    )

    #expect(broker.activeLeaseOwner(for: firstToken) == "machine-a")
    #expect(throws: DoryHostUSBLeaseError.deviceBusy(ownerMachineID: "machine-a")) {
      try broker.acquire(
        machineID: "machine-b",
        identityToken: firstToken,
        family: .camera,
        admission: .init(userSelected: true),
        capability: first
      )
    }
    #expect(throws: DoryHostUSBLeaseError.machineLeaseLimit(maximum: 1)) {
      try broker.acquire(
        machineID: "machine-a",
        identityToken: secondToken,
        family: .serialAdapter,
        admission: .init(userSelected: true),
        capability: second
      )
    }

    lease.release()
    #expect(broker.activeLeaseOwner(for: firstToken) == nil)
    #expect(first.cancelCount == 1)
    #expect(first.closeCount == 1)
  }

  @Test func forwardsBoundedTransfersAndFailsClosedAfterRevocation() throws {
    let token = identityToken("c")
    let capability = RecordingCapability(
      identityToken: token,
      result: try .init(status: .success, payload: [1, 2, 3])
    )
    let broker = DoryHostUSBLeaseBroker(transferTimeout: .milliseconds(250))
    let lease = try broker.acquire(
      machineID: "machine-c",
      identityToken: token,
      family: .developerHardware,
      admission: .init(userSelected: true),
      capability: capability
    )
    let transfer = try DoryPCUSBTransfer(
      type: .bulk,
      direction: .in,
      endpoint: 1,
      maximumResponseBytes: 8
    )

    #expect(lease.perform(transfer).payload == [1, 2, 3])
    #expect(capability.transfers == [transfer])
    #expect(capability.observedFutureDeadline)
    lease.surpriseRemove()
    #expect(lease.perform(transfer).status == .disconnected)
    #expect(!lease.isActive)
    #expect(broker.activeLeaseCount(machineID: "machine-c") == 0)
  }

  @Test func physicalLeaseRejectsIsochronousTransfersWithoutHostIO() throws {
    let token = identityToken("9")
    let capability = RecordingCapability(identityToken: token)
    let lease = try DoryHostUSBLeaseBroker().acquire(
      machineID: "machine-iso",
      identityToken: token,
      family: .serialAdapter,
      admission: .init(userSelected: true),
      capability: capability
    )
    defer { lease.release() }
    let transfer = try DoryPCUSBTransfer(
      type: .isochronous,
      direction: .in,
      endpoint: 1,
      maximumResponseBytes: 64
    )

    #expect(lease.perform(transfer).status == .stalled)
    #expect(capability.transfers.isEmpty)
  }

  @Test func resetFailureRevokesTheLease() throws {
    let token = identityToken("d")
    let capability = RecordingCapability(identityToken: token, resetResult: false)
    let broker = DoryHostUSBLeaseBroker()
    let lease = try broker.acquire(
      machineID: "machine-d",
      identityToken: token,
      family: .gameController,
      admission: .init(userSelected: true),
      capability: capability
    )

    lease.reset()
    #expect(!lease.isActive)
    #expect(capability.resetCount == 1)
    #expect(capability.closeCount == 1)
  }

  @Test func revocationNotificationIsExactlyOnceAndLateRegistrationIsNotLost() throws {
    let token = identityToken("e")
    let capability = RecordingCapability(identityToken: token)
    let broker = DoryHostUSBLeaseBroker()
    let lease = try broker.acquire(
      machineID: "machine-e",
      identityToken: token,
      family: .developerHardware,
      admission: .init(userSelected: true),
      capability: capability
    )
    lease.surpriseRemove()

    let notifications = LockedCounter()
    lease.setRevocationHandler { notifications.increment() }
    lease.surpriseRemove()
    #expect(notifications.value == 1)
  }

  @Test func revocationQuarantinesPhysicalLeaseUntilBlockedTransferReturns() throws {
    let token = identityToken("f")
    let capability = BlockingCapability(identityToken: token)
    let broker = DoryHostUSBLeaseBroker(transferTimeout: .milliseconds(50))
    let lease = try broker.acquire(
      machineID: "machine-f", identityToken: token, family: .developerHardware,
      admission: .init(userSelected: true), capability: capability
    )
    let transfer = try DoryPCUSBTransfer(
      type: .bulk, direction: .in, endpoint: 1, maximumResponseBytes: 8
    )
    let finished = DispatchSemaphore(value: 0)
    let result = LockedTransferResult()
    DispatchQueue.global().async {
      result.value = lease.perform(transfer)
      finished.signal()
    }
    #expect(capability.entered.wait(timeout: .now() + 1) == .success)
    lease.release()
    #expect(!lease.isActive)
    #expect(!lease.isRetired)
    #expect(!lease.waitForRetirement(timeout: 0))
    #expect(capability.closeCount == 0)
    #expect(broker.activeLeaseOwner(for: token) == "machine-f")
    #expect(throws: DoryHostUSBLeaseError.deviceBusy(ownerMachineID: "machine-f")) {
      try broker.acquire(
        machineID: "machine-g", identityToken: token, family: .developerHardware,
        admission: .init(userSelected: true), capability: capability
      )
    }
    capability.release.signal()
    #expect(finished.wait(timeout: .now() + 1) == .success)
    #expect(result.value?.status == .disconnected)
    #expect(capability.closeCount == 1)
    #expect(lease.waitForRetirement(timeout: 0))
    #expect(broker.activeLeaseOwner(for: token) == nil)
  }

  @Test func revocationWaitsForInFlightPlatformResetBeforeClosing() throws {
    let token = identityToken("b")
    let capability = BlockingCapability(identityToken: token, blockReset: true)
    let broker = DoryHostUSBLeaseBroker()
    let lease = try broker.acquire(
      machineID: "machine-g", identityToken: token, family: .serialAdapter,
      admission: .init(userSelected: true), capability: capability
    )
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      lease.reset()
      finished.signal()
    }
    #expect(capability.resetEntered.wait(timeout: .now() + 1) == .success)
    lease.release()
    #expect(!lease.isRetired)
    #expect(capability.closeCount == 0)
    #expect(broker.activeLeaseOwner(for: token) == "machine-g")
    capability.releaseReset.signal()
    #expect(finished.wait(timeout: .now() + 1) == .success)
    #expect(capability.closeCount == 1)
    #expect(lease.isRetired)
    #expect(broker.activeLeaseOwner(for: token) == nil)
  }
}

private final class LockedTransferResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: DoryPCUSBTransferResult?
  var value: DoryPCUSBTransferResult? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class BlockingCapability: DoryHostUSBTransferCapability, @unchecked Sendable {
  let identityToken: DoryUSBPhysicalIdentityToken
  let speed: DoryPCXHCIPortSpeed = .high
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let resetEntered = DispatchSemaphore(value: 0)
  let releaseReset = DispatchSemaphore(value: 0)
  private let blockReset: Bool
  private let lock = NSLock()
  private var closes = 0

  init(identityToken: DoryUSBPhysicalIdentityToken, blockReset: Bool = false) {
    self.identityToken = identityToken
    self.blockReset = blockReset
  }
  var closeCount: Int { lock.withLock { closes } }

  func perform(
    _ transfer: DoryPCUSBTransfer, deadline: ContinuousClock.Instant
  ) -> DoryPCUSBTransferResult {
    entered.signal()
    _ = release.wait(timeout: .now() + 2)
    return try! .init(status: .success)
  }
  func reset(deadline: ContinuousClock.Instant) -> Bool {
    if blockReset {
      resetEntered.signal()
      _ = releaseReset.wait(timeout: .now() + 2)
    }
    return true
  }
  func cancelAll() {}
  func close() { lock.withLock { closes += 1 } }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class RecordingCapability: DoryHostUSBTransferCapability, @unchecked Sendable {
  let identityToken: DoryUSBPhysicalIdentityToken
  let speed: DoryPCXHCIPortSpeed = .high
  private let lock = NSLock()
  private let response: DoryPCUSBTransferResult
  private let resetResult: Bool
  private var recordedTransfers: [DoryPCUSBTransfer] = []
  private var futureDeadline = false
  private var resets = 0
  private var cancellations = 0
  private var closes = 0

  init(
    identityToken: DoryUSBPhysicalIdentityToken,
    result: DoryPCUSBTransferResult = try! .init(status: .success),
    resetResult: Bool = true
  ) {
    self.identityToken = identityToken
    response = result
    self.resetResult = resetResult
  }

  var transfers: [DoryPCUSBTransfer] { lock.withLock { recordedTransfers } }
  var observedFutureDeadline: Bool { lock.withLock { futureDeadline } }
  var resetCount: Int { lock.withLock { resets } }
  var cancelCount: Int { lock.withLock { cancellations } }
  var closeCount: Int { lock.withLock { closes } }

  func perform(
    _ transfer: DoryPCUSBTransfer,
    deadline: ContinuousClock.Instant
  ) -> DoryPCUSBTransferResult {
    lock.withLock {
      recordedTransfers.append(transfer)
      futureDeadline = deadline > .now
      return response
    }
  }

  func reset(deadline: ContinuousClock.Instant) -> Bool {
    lock.withLock {
      resets += 1
      futureDeadline = deadline > .now
      return resetResult
    }
  }

  func cancelAll() { lock.withLock { cancellations += 1 } }
  func close() { lock.withLock { closes += 1 } }
}

private func identityToken(_ character: Character) -> DoryUSBPhysicalIdentityToken {
  DoryUSBPhysicalIdentityToken(rawValue: String(repeating: character, count: 64))!
}
