import DoryDBTX86
import Foundation

public enum DoryPCPowerAction: Sendable, Hashable {
  case powerOff
  case reset
}

public struct DoryPCPowerControllerSnapshot: Sendable, Hashable {
  public let pm1Control: UInt16
  public let pendingAction: DoryPCPowerAction?
}

public final class DoryPCPowerController: @unchecked Sendable {
  public static let pm1EventPort: UInt16 = 0x600
  public static let pm1ControlPort: UInt16 = 0x604
  public static let pmTimerPort: UInt16 = 0x608
  public static let pmTimerFrequencyHz: UInt64 = 3_579_545
  // DoryPC's FADT leaves TMR_VAL_EXT clear: 24 counter bits in a 32-bit read.
  public static let pmTimerCounterMask: UInt32 = 0x00FF_FFFF
  public static let resetPort: UInt16 = 0xCF9
  public static let resetValue: UInt8 = 0x06
  public static let softOffSleepType: UInt16 = 5

  private let lock = NSLock()
  private var pm1Control: UInt16 = 0
  private var pm1Enable: UInt16 = 0
  private var pendingAction: DoryPCPowerAction?
  private var pmTimerCounter: UInt32 = 0

  public init() {}

  public func snapshot() -> DoryPCPowerControllerSnapshot {
    lock.withLock {
      .init(pm1Control: pm1Control, pendingAction: pendingAction)
    }
  }

  public func consumeRequestedAction() -> DoryPCPowerAction? {
    lock.withLock {
      defer { pendingAction = nil }
      return pendingAction
    }
  }

  /// Host lifecycle boundary used by the product runner after it has acknowledged the daemon's
  /// operation-bound shutdown request. Guest port writes and host requests converge on the same
  /// single-consumer action latch.
  public func request(_ action: DoryPCPowerAction) {
    lock.withLock { pendingAction = action }
  }

  fileprivate func readPM1Control() -> UInt16 {
    lock.withLock { pm1Control & ~(1 << 13) }
  }

  fileprivate func writePM1Control(_ value: UInt16) {
    lock.withLock {
      pm1Control = value & ~(1 << 13)
      let sleepType = (value >> 10) & 0x7
      if value & (1 << 13) != 0, sleepType == Self.softOffSleepType {
        pendingAction = .powerOff
      }
    }
  }

  fileprivate func readPM1Enable() -> UInt16 {
    lock.withLock { pm1Enable }
  }

  fileprivate func writePM1Enable(_ value: UInt16) {
    lock.withLock { pm1Enable = value }
  }

  fileprivate func readPMTimer() -> UInt32 {
    lock.withLock { pmTimerCounter }
  }

  /// Advances PM-timer oscillator ticks, not HPET ticks or instruction counts.
  /// ACPI 6.5 §4.8.3.3 specifies a free-running 3.579545 MHz counter.
  public func advancePMTimer(by ticks: UInt64) {
    lock.withLock {
      pmTimerCounter = (pmTimerCounter &+ UInt32(truncatingIfNeeded: ticks))
        & Self.pmTimerCounterMask
    }
  }

  fileprivate func writeReset(_ value: UInt8) {
    guard value == Self.resetValue else { return }
    lock.withLock { pendingAction = .reset }
  }
}

public final class DoryPCACPIPMEventPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort = DoryPCPowerController.pm1EventPort
  public let portCount: UInt16 = 4
  public let controller: DoryPCPowerController

  public init(controller: DoryPCPowerController) { self.controller = controller }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .word else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    switch portOffset {
    case 0: return UInt32(controller.readPM1Control())
    case 2: return UInt32(controller.readPM1Enable())
    default: return 0
    }
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .word else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    switch portOffset {
    case 0: controller.writePM1Control(UInt16(truncatingIfNeeded: value))
    case 2: controller.writePM1Enable(UInt16(truncatingIfNeeded: value))
    default: break
    }
  }
}

public final class DoryPCACPMPMTimerPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort = DoryPCPowerController.pmTimerPort
  public let portCount: UInt16 = 4
  public let controller: DoryPCPowerController

  public init(controller: DoryPCPowerController) { self.controller = controller }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard portOffset == 0, width == .doubleword else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    return controller.readPMTimer()
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    throw DoryPCPortIOError.unsupportedWidth(width)
  }
}

public final class DoryPCACPIPMControlPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort = DoryPCPowerController.pm1ControlPort
  public let portCount: UInt16 = 2
  public let controller: DoryPCPowerController

  public init(controller: DoryPCPowerController) { self.controller = controller }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard portOffset == 0, width == .word else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    return UInt32(controller.readPM1Control())
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard portOffset == 0, width == .word else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    controller.writePM1Control(UInt16(truncatingIfNeeded: value))
  }
}

public final class DoryPCResetControlPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort = DoryPCPowerController.resetPort
  public let portCount: UInt16 = 1
  public let controller: DoryPCPowerController

  public init(controller: DoryPCPowerController) { self.controller = controller }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard portOffset == 0, width == .byte else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    return 0
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard portOffset == 0, width == .byte else {
      throw DoryPCPortIOError.unsupportedWidth(width)
    }
    controller.writeReset(UInt8(truncatingIfNeeded: value))
  }
}
