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
}

/// Transport-neutral VirtIO feature and lifecycle state machine.
public final class DoryVirtioDeviceState: @unchecked Sendable {
  public let offeredFeatures: DoryVirtioFeatures

  private let lock = NSLock()
  private var driverFeatures: DoryVirtioFeatures = []
  private var status: DoryVirtioDeviceStatus = []
  private var configurationGeneration: UInt8 = 0
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

  public func markDeviceNeedsReset() {
    lock.withLock {
      status.insert(.deviceNeedsReset)
      configurationGeneration &+= 1
    }
  }

  public func configurationDidChange() {
    lock.withLock { configurationGeneration &+= 1 }
  }

  public func snapshot() -> DoryVirtioDeviceSnapshot {
    lock.withLock {
      .init(
        offeredFeatures: offeredFeatures,
        negotiatedFeatures: status.contains(.featuresOK) ? driverFeatures : [],
        status: status,
        configurationGeneration: configurationGeneration
      )
    }
  }
}
