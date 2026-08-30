import DoryMachinePC
import DoryVMContracts
import Foundation

public enum DoryHostUSBDeviceFamily: String, Codable, CaseIterable, Sendable, Hashable {
  case keyboard
  case pointingDevice
  case bootStorage
  case securityDevice
  case camera
  case audio
  case storage
  case smartCard
  case serialAdapter
  case gameController
  case developerHardware
  case other

  var isHostCritical: Bool {
    switch self {
    case .keyboard, .pointingDevice, .bootStorage, .securityDevice: true
    default: false
    }
  }
}

public struct DoryHostUSBAdmission: Sendable, Hashable {
  public let userSelected: Bool
  public let hostStorageUnmounted: Bool
  public let explicitlyReviewedCriticalDevice: Bool

  public init(
    userSelected: Bool,
    hostStorageUnmounted: Bool = false,
    explicitlyReviewedCriticalDevice: Bool = false
  ) {
    self.userSelected = userSelected
    self.hostStorageUnmounted = hostStorageUnmounted
    self.explicitlyReviewedCriticalDevice = explicitlyReviewedCriticalDevice
  }
}

public enum DoryHostUSBLeaseError: Error, Sendable, Equatable {
  case invalidMachineID
  case userSelectionRequired
  case hostCriticalDevice(DoryHostUSBDeviceFamily)
  case writableStorageMounted
  case identityMismatch
  case deviceBusy(ownerMachineID: String)
  case machineLeaseLimit(maximum: Int)
}

/// An already-authorized host transport. Implementations own the platform API and must honor the
/// supplied absolute deadline; the VM receives only this bounded object, never enumeration or
/// ambient IOKit authority.
public protocol DoryHostUSBTransferCapability: AnyObject, Sendable {
  var identityToken: DoryUSBPhysicalIdentityToken { get }
  var speed: DoryPCXHCIPortSpeed { get }
  func perform(
    _ transfer: DoryPCUSBTransfer,
    deadline: ContinuousClock.Instant
  ) -> DoryPCUSBTransferResult
  func reset(deadline: ContinuousClock.Instant) -> Bool
  func cancelAll()
  func close()
}

public final class DoryHostUSBLeaseDevice: DoryPCUSBDevice, @unchecked Sendable {
  public let leaseID: UUID
  public let machineID: String
  public let identityToken: DoryUSBPhysicalIdentityToken
  public let family: DoryHostUSBDeviceFamily
  public let speed: DoryPCXHCIPortSpeed

  private let condition = NSCondition()
  private let capability: any DoryHostUSBTransferCapability
  private let transferTimeout: Duration
  private let maximumOutstandingTransfers: Int
  private let releaseHandler: @Sendable (UUID, DoryUSBPhysicalIdentityToken, String) -> Void
  private var active = true
  private var outstandingTransfers = 0
  private var released = false

  fileprivate init(
    leaseID: UUID,
    machineID: String,
    identityToken: DoryUSBPhysicalIdentityToken,
    family: DoryHostUSBDeviceFamily,
    capability: any DoryHostUSBTransferCapability,
    transferTimeout: Duration,
    maximumOutstandingTransfers: Int,
    releaseHandler: @escaping @Sendable (UUID, DoryUSBPhysicalIdentityToken, String) -> Void
  ) {
    self.leaseID = leaseID
    self.machineID = machineID
    self.identityToken = identityToken
    self.family = family
    speed = capability.speed
    self.capability = capability
    self.transferTimeout = transferTimeout
    self.maximumOutstandingTransfers = maximumOutstandingTransfers
    self.releaseHandler = releaseHandler
  }

  public var isActive: Bool {
    condition.withLock { active }
  }

  public func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult {
    let admitted = condition.withLock {
      guard active, outstandingTransfers < maximumOutstandingTransfers else { return false }
      outstandingTransfers += 1
      return true
    }
    guard admitted else {
      return result(condition.withLock { active } ? .notReady : .disconnected)
    }
    let response = capability.perform(
      transfer,
      deadline: ContinuousClock.now.advanced(by: transferTimeout)
    )
    let remainsActive = condition.withLock {
      outstandingTransfers -= 1
      condition.broadcast()
      return active
    }
    return remainsActive ? response : result(.disconnected)
  }

  public func reset() {
    let admitted = condition.withLock { active }
    guard admitted else { return }
    if !capability.reset(deadline: ContinuousClock.now.advanced(by: transferTimeout)) {
      revoke()
    }
  }

  public func cancelAll() {
    let admitted = condition.withLock { active }
    if admitted { capability.cancelAll() }
  }

  public func release() {
    revoke()
  }

  public func surpriseRemove() {
    revoke()
  }

  private func revoke() {
    let shouldClose = condition.withLock {
      guard active else { return false }
      active = false
      return true
    }
    guard shouldClose else { return }
    capability.cancelAll()
    let deadline = Date().addingTimeInterval(1)
    condition.lock()
    while outstandingTransfers > 0, condition.wait(until: deadline) {}
    let notify = !released
    released = true
    condition.unlock()
    capability.close()
    if notify { releaseHandler(leaseID, identityToken, machineID) }
  }

  deinit {
    revoke()
  }

  private func result(_ status: DoryPCUSBTransferStatus) -> DoryPCUSBTransferResult {
    try! .init(status: status)
  }
}

public final class DoryHostUSBLeaseBroker: @unchecked Sendable {
  private struct LeaseRecord {
    let leaseID: UUID
    let machineID: String
  }

  public let maximumLeasesPerMachine: Int
  public let maximumOutstandingTransfersPerLease: Int
  public let transferTimeout: Duration

  private let lock = NSLock()
  private var leases: [DoryUSBPhysicalIdentityToken: LeaseRecord] = [:]

  public init(
    maximumLeasesPerMachine: Int = 16,
    maximumOutstandingTransfersPerLease: Int = 1_024,
    transferTimeout: Duration = .seconds(5)
  ) {
    precondition(maximumLeasesPerMachine > 0)
    precondition(
      (1...DoryPCUSBDeviceLimits.maximumOutstandingTransfers).contains(
        maximumOutstandingTransfersPerLease
      )
    )
    self.maximumLeasesPerMachine = maximumLeasesPerMachine
    self.maximumOutstandingTransfersPerLease = maximumOutstandingTransfersPerLease
    self.transferTimeout = transferTimeout
  }

  public func acquire(
    machineID: String,
    identityToken: DoryUSBPhysicalIdentityToken,
    family: DoryHostUSBDeviceFamily,
    admission: DoryHostUSBAdmission,
    capability: any DoryHostUSBTransferCapability
  ) throws -> DoryHostUSBLeaseDevice {
    guard Self.validMachineID(machineID) else { throw DoryHostUSBLeaseError.invalidMachineID }
    guard admission.userSelected else { throw DoryHostUSBLeaseError.userSelectionRequired }
    guard !family.isHostCritical || admission.explicitlyReviewedCriticalDevice else {
      throw DoryHostUSBLeaseError.hostCriticalDevice(family)
    }
    guard family != .storage || admission.hostStorageUnmounted else {
      throw DoryHostUSBLeaseError.writableStorageMounted
    }
    guard capability.identityToken == identityToken else {
      throw DoryHostUSBLeaseError.identityMismatch
    }
    let leaseID = UUID()
    try lock.withLock {
      if let existing = leases[identityToken] {
        throw DoryHostUSBLeaseError.deviceBusy(ownerMachineID: existing.machineID)
      }
      let machineLeaseCount = leases.values.count { $0.machineID == machineID }
      guard machineLeaseCount < maximumLeasesPerMachine else {
        throw DoryHostUSBLeaseError.machineLeaseLimit(maximum: maximumLeasesPerMachine)
      }
      leases[identityToken] = .init(leaseID: leaseID, machineID: machineID)
    }
    return DoryHostUSBLeaseDevice(
      leaseID: leaseID,
      machineID: machineID,
      identityToken: identityToken,
      family: family,
      capability: capability,
      transferTimeout: transferTimeout,
      maximumOutstandingTransfers: maximumOutstandingTransfersPerLease
    ) { [weak self] releasedID, releasedToken, releasedMachine in
      self?.release(leaseID: releasedID, identityToken: releasedToken, machineID: releasedMachine)
    }
  }

  public func activeLeaseOwner(for identityToken: DoryUSBPhysicalIdentityToken) -> String? {
    lock.withLock { leases[identityToken]?.machineID }
  }

  public func activeLeaseCount(machineID: String) -> Int {
    lock.withLock { leases.values.count { $0.machineID == machineID } }
  }

  private func release(
    leaseID: UUID,
    identityToken: DoryUSBPhysicalIdentityToken,
    machineID: String
  ) {
    lock.withLock {
      guard let lease = leases[identityToken], lease.leaseID == leaseID,
        lease.machineID == machineID
      else { return }
      _ = leases.removeValue(forKey: identityToken)
    }
  }

  private static func validMachineID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= 128 && !bytes.contains(0)
  }
}
