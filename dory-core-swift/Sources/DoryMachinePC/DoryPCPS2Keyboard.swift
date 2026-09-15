import DoryDBTX86
import Foundation

/// Minimal AT-compatible i8042 keyboard controller. It deliberately models only the first PS/2
/// port used by firmware and ordinary boot loaders: status, command byte, keyboard ACK/reset and
/// bounded set-1 scan-code delivery. Mouse and controller self-test extensions remain absent.
public final class DoryPCPS2KeyboardController: @unchecked Sendable {
  public struct Snapshot: Sendable, Equatable {
    public let bytesPending: Int
    public let commandByte: UInt8
    public let dataReadCount: UInt64
    public let statusReadCount: UInt64
    public let dataWriteCount: UInt64
    public let commandWriteCount: UInt64
  }

  private let lock = NSLock()
  private let maximumQueuedBytes: Int
  private var output: [UInt8] = []
  private var commandByte: UInt8 = 0x01
  private var expectingCommandByte = false
  private var interruptSink: (@Sendable (Bool) -> Void)?
  private var lastInterruptLevel = false
  private var dataReadCount: UInt64 = 0
  private var statusReadCount: UInt64 = 0
  private var dataWriteCount: UInt64 = 0
  private var commandWriteCount: UInt64 = 0

  public init(maximumQueuedBytes: Int = 1024) {
    self.maximumQueuedBytes = max(1, maximumQueuedBytes)
  }

  public var hasPendingByte: Bool { lock.withLock { !output.isEmpty } }

  public func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        bytesPending: output.count,
        commandByte: commandByte,
        dataReadCount: dataReadCount,
        statusReadCount: statusReadCount,
        dataWriteCount: dataWriteCount,
        commandWriteCount: commandWriteCount)
    }
  }

  @discardableResult
  public func enqueueSet1ScanCodes(_ bytes: [UInt8]) -> Bool {
    let result = lock.withLock { () -> (Bool, (@Sendable (Bool) -> Void, Bool)?) in
      guard bytes.count <= maximumQueuedBytes - output.count else { return (false, nil) }
      output.append(contentsOf: bytes)
      return (true, interruptNotificationLocked())
    }
    notify(result.1)
    return result.0
  }

  public func connectInterruptSink(_ sink: @escaping @Sendable (Bool) -> Void) {
    let level = lock.withLock {
      interruptSink = sink
      let level = interruptLevelLocked()
      lastInterruptLevel = level
      return level
    }
    sink(level)
  }

  fileprivate func readData() -> UInt8 {
    let result = lock.withLock {
      dataReadCount &+= 1
      let value = output.isEmpty ? UInt8(0) : output.removeFirst()
      return (value, interruptNotificationLocked())
    }
    notify(result.1)
    return result.0
  }

  fileprivate func readStatus() -> UInt8 {
    lock.withLock {
      statusReadCount &+= 1
      return (output.isEmpty ? 0 : 1) | 0x04
    }
  }

  fileprivate func writeData(_ value: UInt8) {
    let notification = lock.withLock {
      dataWriteCount &+= 1
      if expectingCommandByte {
        commandByte = value
        expectingCommandByte = false
      } else {
        switch value {
        case 0xFF: output.append(contentsOf: [0xFA, 0xAA])
        case 0xF4, 0xF5, 0xF0: output.append(0xFA)
        default: output.append(0xFA)
        }
      }
      return interruptNotificationLocked()
    }
    notify(notification)
  }

  fileprivate func writeCommand(_ value: UInt8) {
    let notification = lock.withLock {
      commandWriteCount &+= 1
      switch value {
      case 0x20: output.append(commandByte)
      case 0x60: expectingCommandByte = true
      case 0xAA: output.append(0x55)
      case 0xAB: output.append(0x00)
      case 0xAD: commandByte |= 0x10
      case 0xAE: commandByte &= ~0x10
      default: break
      }
      return interruptNotificationLocked()
    }
    notify(notification)
  }

  private func interruptLevelLocked() -> Bool {
    !output.isEmpty && commandByte & 0x01 != 0 && commandByte & 0x10 == 0
  }

  private func interruptNotificationLocked() -> (@Sendable (Bool) -> Void, Bool)? {
    let level = interruptLevelLocked()
    guard level != lastInterruptLevel else { return nil }
    lastInterruptLevel = level
    return interruptSink.map { ($0, level) }
  }

  private func notify(_ notification: (@Sendable (Bool) -> Void, Bool)?) {
    notification?.0(notification!.1)
  }
}

public final class DoryPCPS2KeyboardDataPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16 = 0x60
  public let portCount: UInt16 = 1
  private let controller: DoryPCPS2KeyboardController
  public init(controller: DoryPCPS2KeyboardController) { self.controller = controller }
  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard portOffset == 0, width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    return UInt32(controller.readData())
  }
  public func write(portOffset: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    guard portOffset == 0, width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    controller.writeData(UInt8(truncatingIfNeeded: value))
  }
}

public final class DoryPCPS2KeyboardStatusPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16 = 0x64
  public let portCount: UInt16 = 1
  private let controller: DoryPCPS2KeyboardController
  public init(controller: DoryPCPS2KeyboardController) { self.controller = controller }
  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard portOffset == 0, width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    return UInt32(controller.readStatus())
  }
  public func write(portOffset: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    guard portOffset == 0, width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    controller.writeCommand(UInt8(truncatingIfNeeded: value))
  }
}
