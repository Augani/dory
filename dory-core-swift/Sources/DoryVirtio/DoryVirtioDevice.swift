import Foundation

public struct DoryVirtioFeatures: OptionSet, Sendable, Hashable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) { self.rawValue = rawValue }

  public static let indirectDescriptors = Self(rawValue: 1 << 28)
  public static let eventIndex = Self(rawValue: 1 << 29)
  public static let version1 = Self(rawValue: 1 << 32)
  public static let accessPlatform = Self(rawValue: 1 << 33)
  public static let packedRing = Self(rawValue: 1 << 34)
}

public struct DoryVirtioDeviceStatus: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let acknowledge = Self(rawValue: 1)
  public static let driver = Self(rawValue: 2)
  public static let driverOK = Self(rawValue: 4)
  public static let featuresOK = Self(rawValue: 8)
  public static let deviceNeedsReset = Self(rawValue: 64)
  public static let failed = Self(rawValue: 128)
}

public struct DoryVirtioDeviceSnapshot: Sendable, Hashable {
  public let offeredFeatures: DoryVirtioFeatures
  public let negotiatedFeatures: DoryVirtioFeatures
  public let status: DoryVirtioDeviceStatus
  public let configurationGeneration: UInt8
  public let lifecycleEpoch: UInt64
}

/// Transport-neutral VirtIO feature and lifecycle state machine.
public final class DoryVirtioDeviceState: @unchecked Sendable {
  public let offeredFeatures: DoryVirtioFeatures

  private let lock = NSLock()
  private var driverFeatures: DoryVirtioFeatures = []
  private var status: DoryVirtioDeviceStatus = []
  private var configurationGeneration: UInt8 = 0
  private var lifecycleEpoch: UInt64 = 0
  private let onReset: @Sendable () -> Void

  public init(
    offeredFeatures: DoryVirtioFeatures,
    onReset: @escaping @Sendable () -> Void = {}
  ) {
    self.offeredFeatures = offeredFeatures.union(.version1)
    self.onReset = onReset
  }

  public func writeDriverFeatures(page: UInt32, value: UInt32) {
    guard page < 2 else { return }
    lock.withLock {
      guard !status.contains(.featuresOK) else { return }
      let shift = UInt64(page * 32)
      let mask = UInt64(UInt32.max) << shift
      driverFeatures = .init(rawValue: (driverFeatures.rawValue & ~mask) | (UInt64(value) << shift))
    }
  }

  public func readDeviceFeatures(page: UInt32) -> UInt32 {
    guard page < 2 else { return 0 }
    return UInt32(truncatingIfNeeded: offeredFeatures.rawValue >> UInt64(page * 32))
  }

  /// Applies the cumulative VirtIO status byte. Writing zero is the only legal way to clear state.
  public func writeStatus(_ requested: DoryVirtioDeviceStatus) {
    let reset = lock.withLock {
      guard !requested.isEmpty else {
        driverFeatures = []
        status = []
        configurationGeneration &+= 1
        // New lifecycle identity. Checked add traps on exhaustion instead of
        // reusing an old epoch (fail closed, never wraps).
        lifecycleEpoch += 1
        return true
      }
      let driverWritable: DoryVirtioDeviceStatus = [
        .acknowledge, .driver, .driverOK, .featuresOK, .failed,
      ]
      var accepted = status.union(requested.intersection(driverWritable))
      if accepted.contains(.driver), !accepted.contains(.acknowledge) {
        accepted.remove([.driver, .featuresOK, .driverOK])
      }
      if requested.contains(.featuresOK) {
        let prerequisites: DoryVirtioDeviceStatus = [.acknowledge, .driver]
        if !accepted.isSuperset(of: prerequisites)
          || !offeredFeatures.isSuperset(of: driverFeatures)
          || !driverFeatures.contains(.version1)
        {
          accepted.remove(.featuresOK)
        }
      }
      if requested.contains(.driverOK), !accepted.contains(.featuresOK) {
        accepted.remove(.driverOK)
      }
      status = accepted
      return false
    }
    if reset { onReset() }
  }

  /// Marks the device as requiring reset and reports whether this call performed
  /// the transition. Repeated marks are intentionally inert so callers do not
  /// manufacture extra configuration-change side effects after the terminal
  /// state is already visible to the driver.
  @discardableResult
  public func markDeviceNeedsReset() -> Bool {
    lock.withLock {
      guard !status.contains(.deviceNeedsReset) else { return false }
      status.insert(.deviceNeedsReset)
      configurationGeneration &+= 1
      return true
    }
  }

  /// Conditionally marks the device as requiring reset only when
  /// `expectedLifecycleEpoch` still identifies the current lifecycle. The epoch
  /// advances only on a zero-status reset, so ordinary `configurationDidChange()`
  /// calls and NEEDS_RESET marking never invalidate a current-lifecycle capture.
  /// The comparison and the NEEDS_RESET transition occur atomically under the
  /// state lock. A zero-status reset that linearizes after the caller captured
  /// the epoch causes this to return false without touching the fresh
  /// lifecycle, so stale direct/deferred terminal failures cannot poison a
  /// newly reset device. Returns true only when this call performed the transition.
  @discardableResult
  public func markDeviceNeedsReset(expectedLifecycleEpoch: UInt64) -> Bool {
    lock.withLock {
      guard lifecycleEpoch == expectedLifecycleEpoch else { return false }
      guard !status.contains(.deviceNeedsReset) else { return false }
      status.insert(.deviceNeedsReset)
      configurationGeneration &+= 1
      return true
    }
  }

  public func configurationDidChange() {
    lock.withLock { configurationGeneration &+= 1 }
  }

  public func snapshot() -> DoryVirtioDeviceSnapshot {
    lock.withLock {
      snapshotLocked()
    }
  }

  /// Executes `body` while the lifecycle lock is held, supplying a coherent
  /// snapshot. A concurrent `markDeviceNeedsReset()` linearizes either before
  /// the lease (work observes NEEDS_RESET) or after it completes, never
  /// between the operational check and guest-memory DMA. The body must not
  /// call `snapshot()`, `markDeviceNeedsReset()`, or any other lifecycle
  /// method: the lock is non-reentrant. Propagate failures as throws and mark
  /// the device only after the lease is released.
  public func withLockedSnapshot<T>(_ body: (DoryVirtioDeviceSnapshot) throws -> T) rethrows
    -> T
  {
    lock.lock()
    defer { lock.unlock() }
    return try body(snapshotLocked())
  }

  private func snapshotLocked() -> DoryVirtioDeviceSnapshot {
    .init(
      offeredFeatures: offeredFeatures,
      negotiatedFeatures: status.contains(.featuresOK) ? driverFeatures : [],
      status: status,
      configurationGeneration: configurationGeneration,
      lifecycleEpoch: lifecycleEpoch
    )
  }
}

// P2-14 item 7 — Balloon/memory-pressure behavior:
//
// A virtio-balloon device is NOT implemented in ABI v1. The plan requires that
// balloon/memory-pressure behavior be added only with an exact ownership protocol
// that never reclaims pages while CPU, DMA, or GPU leases still reference them.
// Until a page-ownership protocol coordinates with the guest memory manager,
// renderer worker mappings, and filesystem worker mappings, no balloon device
// is exposed. This is a deliberate gap, not an oversight.
