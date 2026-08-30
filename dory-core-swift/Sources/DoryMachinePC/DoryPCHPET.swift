import DoryDBTX86
import Foundation

public struct DoryPCHPETTimerSnapshot: Sendable, Hashable {
  public let configuration: UInt64
  public let comparator: UInt64
  public let period: UInt64
  public let armed: Bool
}

public struct DoryPCHPETSnapshot: Sendable, Hashable {
  public let enabled: Bool
  public let legacyReplacement: Bool
  public let mainCounter: UInt64
  public let interruptStatus: UInt64
  public let timers: [DoryPCHPETTimerSnapshot]
}

public struct DoryPCHPETInterruptDeadline: Sendable, Hashable {
  public let timer: Int
  public let route: Int
  public let ticks: UInt64

  public init(timer: Int, route: Int, ticks: UInt64) {
    self.timer = timer
    self.route = route
    self.ticks = ticks
  }
}

/// DoryPC-v1 high precision event timer at the PC-standard 0xFED0_0000 address.
public final class DoryPCHPET: DoryPCMMIODevice, @unchecked Sendable {
  public static let femtosecondsPerTick: UInt32 = 100_000_000

  private struct Timer {
    var configuration: UInt64 = 0
    var comparator: UInt64 = 0
    var period: UInt64 = 0
    var armed = false
  }

  private struct Notification {
    let timer: Int
    let route: Int
    let asserted: Bool
  }

  public let baseAddress: UInt64
  public let byteCount: UInt64 = 0x400
  public let timerCount: Int

  private let lock = NSLock()
  private let interruptSink: @Sendable (_ timer: Int, _ route: Int, _ asserted: Bool) -> Void
  private var generalConfiguration: UInt64 = 0
  private var interruptStatus: UInt64 = 0
  private var mainCounter: UInt64 = 0
  private var timers: [Timer]

  public init(
    baseAddress: UInt64 = DoryPCV1ABI.hpetBase,
    timerCount: Int = 3,
    interruptSink: @escaping @Sendable (_ timer: Int, _ route: Int, _ asserted: Bool) -> Void = {
      _, _, _ in
    }
  ) {
    precondition((3...32).contains(timerCount))
    self.baseAddress = baseAddress
    self.timerCount = timerCount
    self.interruptSink = interruptSink
    timers = .init(repeating: .init(), count: timerCount)
  }

  public func advance(by ticks: UInt64) {
    guard ticks > 0 else { return }
    let notifications: [Notification] = lock.withLock {
      guard generalConfiguration & 1 != 0 else { return [] }
      let oldCounter = mainCounter
      mainCounter &+= ticks
      var notifications: [Notification] = []
      for index in timers.indices where timers[index].armed {
        guard expired(timers[index].comparator, after: oldCounter, through: mainCounter) else {
          continue
        }
        interruptStatus |= UInt64(1) << UInt64(index)
        let route = interruptRouteLocked(timer: index)
        if timers[index].configuration & (1 << 2) != 0 {
          if timers[index].configuration & (1 << 1) != 0 {
            notifications.append(.init(timer: index, route: route, asserted: true))
          } else {
            notifications.append(.init(timer: index, route: route, asserted: true))
            notifications.append(.init(timer: index, route: route, asserted: false))
          }
        }
        if timers[index].configuration & (1 << 3) != 0, timers[index].period > 0 {
          repeat {
            timers[index].comparator &+= timers[index].period
          } while expired(
            timers[index].comparator,
            after: oldCounter,
            through: mainCounter
          )
        } else {
          timers[index].armed = false
        }
      }
      return notifications
    }
    notify(notifications)
  }

  public func ticksUntilNextInterrupt() -> UInt64? {
    lock.withLock {
      guard generalConfiguration & 1 != 0 else { return nil }
      let enabledPending = timers.indices.contains { index in
        interruptStatus & (UInt64(1) << UInt64(index)) != 0
          && timers[index].configuration & (1 << 2) != 0
      }
      if enabledPending { return 0 }
      return timers.indices.compactMap { index -> UInt64? in
        guard timers[index].armed, timers[index].configuration & (1 << 2) != 0 else {
          return nil
        }
        return timers[index].comparator &- mainCounter
      }.min()
    }
  }

  /// Returns independently routable future timer expirations. Pending status is excluded because
  /// advancing time cannot make an already asserted but blocked interrupt deliverable.
  public func interruptDeadlines() -> [DoryPCHPETInterruptDeadline] {
    lock.withLock {
      guard generalConfiguration & 1 != 0 else { return [] }
      return timers.indices.compactMap { index in
        guard timers[index].armed, timers[index].configuration & (1 << 2) != 0 else {
          return nil
        }
        let ticks = timers[index].comparator &- mainCounter
        guard ticks > 0 else { return nil }
        return .init(timer: index, route: interruptRouteLocked(timer: index), ticks: ticks)
      }
    }
  }

  public func snapshot() -> DoryPCHPETSnapshot {
    lock.withLock {
      .init(
        enabled: generalConfiguration & 1 != 0,
        legacyReplacement: generalConfiguration & 2 != 0,
        mainCounter: mainCounter,
        interruptStatus: interruptStatus,
        timers: timers.map {
          .init(
            configuration: visibleTimerConfiguration($0.configuration),
            comparator: $0.comparator,
            period: $0.period,
            armed: $0.armed
          )
        }
      )
    }
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try validateAccess(offset: offset, byteCount: byteCount, write: false)
    let value = lock.withLock { registerValueLocked(at: offset & ~7) }
    let shift = Int(offset & 7) * 8
    return littleEndian(value >> UInt64(shift), byteCount: byteCount)
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    try validateAccess(offset: offset, byteCount: bytes.count, write: true)
    let notifications = lock.withLock {
      writeLocked(offset: offset, bytes: bytes)
    }
    notify(notifications)
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    try validateAccess(offset: offset, byteCount: byteCount, write: true)
  }

  private func writeLocked(offset: UInt64, bytes: [UInt8]) -> [Notification] {
    let register = offset & ~7
    let merged = merge(
      old: registerValueLocked(at: register),
      value: uint64(bytes),
      byteOffset: Int(offset & 7),
      byteCount: bytes.count
    )
    switch register {
    case 0x10:
      generalConfiguration = merged & 3
    case 0x20:
      let cleared = interruptStatus & merged
      interruptStatus &= ~merged
      return timers.indices.compactMap { index in
        guard cleared & (UInt64(1) << UInt64(index)) != 0,
          timers[index].configuration & (1 << 1) != 0
        else { return nil }
        return .init(timer: index, route: interruptRouteLocked(timer: index), asserted: false)
      }
    case 0xF0:
      mainCounter = merged
    default:
      guard let (timerIndex, timerRegister) = timerRegister(register) else { return [] }
      if timerRegister == 0 {
        let writableMask: UInt64 =
          (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 8)
          | (0x1F << 9)
        timers[timerIndex].configuration = merged & writableMask
      } else {
        let value =
          timers[timerIndex].configuration & (1 << 8) != 0
          ? UInt64(UInt32(truncatingIfNeeded: merged)) : merged
        if timers[timerIndex].configuration & (1 << 3) != 0 {
          timers[timerIndex].period = value
          timers[timerIndex].comparator = mainCounter &+ value
          timers[timerIndex].configuration &= ~(1 << 6)
        } else {
          timers[timerIndex].comparator = value
        }
        timers[timerIndex].armed = true
      }
    }
    return []
  }

  private func registerValueLocked(at offset: UInt64) -> UInt64 {
    switch offset {
    case 0x00:
      return UInt64(1)
        | UInt64(timerCount - 1) << 8
        | UInt64(1) << 13
        | UInt64(1) << 15
        | UInt64(0xD0D0) << 16
        | UInt64(Self.femtosecondsPerTick) << 32
    case 0x10: return generalConfiguration
    case 0x20: return interruptStatus
    case 0xF0: return mainCounter
    default:
      guard let (timerIndex, timerRegister) = timerRegister(offset) else { return 0 }
      return timerRegister == 0
        ? visibleTimerConfiguration(timers[timerIndex].configuration)
        : timers[timerIndex].comparator
    }
  }

  private func visibleTimerConfiguration(_ writable: UInt64) -> UInt64 {
    let routeCapability = UInt64(0x00FF_FFFC) << 32
    return writable | (1 << 4) | (1 << 5) | routeCapability
  }

  private func timerRegister(_ offset: UInt64) -> (index: Int, register: UInt64)? {
    guard offset >= 0x100 else { return nil }
    let relative = offset - 0x100
    let index = Int(relative / 0x20)
    let timerOffset = relative % 0x20
    guard timers.indices.contains(index), timerOffset == 0 || timerOffset == 8 else { return nil }
    return (index, timerOffset)
  }

  private func interruptRouteLocked(timer index: Int) -> Int {
    if generalConfiguration & 2 != 0, index < 2 { return index == 0 ? 0 : 8 }
    return Int((timers[index].configuration >> 9) & 0x1F)
  }

  private func expired(_ deadline: UInt64, after old: UInt64, through new: UInt64) -> Bool {
    if new >= old { return deadline > old && deadline <= new }
    return deadline > old || deadline <= new
  }

  private func validateAccess(offset: UInt64, byteCount: Int, write: Bool) throws {
    guard byteCount == 4 || byteCount == 8, offset % 4 == 0,
      offset <= self.byteCount, UInt64(byteCount) <= self.byteCount - offset,
      byteCount != 8 || offset % 8 == 0
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
  }

  private func merge(
    old: UInt64,
    value: UInt64,
    byteOffset: Int,
    byteCount: Int
  ) -> UInt64 {
    let shift = UInt64(byteOffset * 8)
    let mask = byteCount == 8 ? UInt64.max : ((UInt64(1) << UInt64(byteCount * 8)) - 1) << shift
    return (old & ~mask) | ((value << shift) & mask)
  }

  private func littleEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func uint64(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }

  private func notify(_ notifications: [Notification]) {
    for notification in notifications {
      interruptSink(notification.timer, notification.route, notification.asserted)
    }
  }
}
