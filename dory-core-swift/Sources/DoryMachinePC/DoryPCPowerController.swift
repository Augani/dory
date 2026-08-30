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
  public static let pm1ControlPort: UInt16 = 0x604
  public static let resetPort: UInt16 = 0xCF9
  public static let resetValue: UInt8 = 0x06
  public static let softOffSleepType: UInt16 = 5

  private let lock = NSLock()
  private var pm1Control: UInt16 = 0
  private var pendingAction: DoryPCPowerAction?

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

  fileprivate func writeReset(_ value: UInt8) {
    guard value == Self.resetValue else { return }
    lock.withLock { pendingAction = .reset }
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
