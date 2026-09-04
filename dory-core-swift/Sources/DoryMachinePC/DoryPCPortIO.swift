import DoryDBTX86
import Foundation

public enum DoryPCPortIOError: Error, Sendable, Equatable {
  case sealed
  case invalidRange(base: UInt16, count: UInt16)
  case overlappingRange(base: UInt16, count: UInt16)
  case unsupportedWidth(DoryX86OperandWidth)
}

public protocol DoryPCPortIODevice: AnyObject, Sendable {
  var basePort: UInt16 { get }
  var portCount: UInt16 { get }
  func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32
  func write(portOffset: UInt16, value: UInt32, width: DoryX86OperandWidth) throws
}

public final class DoryPCPortIOBus: DoryX86IOBus, @unchecked Sendable {
  private struct Mapping {
    let lowerBound: UInt32
    let upperBound: UInt32
    let device: any DoryPCPortIODevice
  }

  private let lock = NSLock()
  private var mappings: [Mapping] = []
  private var isSealed = false

  public init() {}

  public func attach(_ device: any DoryPCPortIODevice) throws {
    try lock.withLock {
      guard !isSealed else { throw DoryPCPortIOError.sealed }
      let lower = UInt32(device.basePort)
      let upper = lower + UInt32(device.portCount)
      guard device.portCount > 0, upper <= 0x1_0000 else {
        throw DoryPCPortIOError.invalidRange(base: device.basePort, count: device.portCount)
      }
      guard !mappings.contains(where: { lower < $0.upperBound && $0.lowerBound < upper }) else {
        throw DoryPCPortIOError.overlappingRange(
          base: device.basePort,
          count: device.portCount
        )
      }
      mappings.append(.init(lowerBound: lower, upperBound: upper, device: device))
      mappings.sort { $0.lowerBound < $1.lowerBound }
    }
  }

  public func seal() { lock.withLock { isSealed = true } }

  public func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard let resolved = resolve(port: port, width: width) else {
      // An unclaimed PC I/O cycle reads as an open bus. Optional-device probes rely on this to
      // discover absence; turning it into a CPU fault makes ordinary firmware enumeration fatal.
      return switch width {
      case .byte: 0xFF
      case .word: 0xFFFF
      case .doubleword, .quadword: 0xFFFF_FFFF
      }
    }
    return try resolved.device.read(portOffset: resolved.offset, width: width)
  }

  public func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    // Writes to an unclaimed PC I/O port are discarded, matching an absent ISA/legacy device.
    guard let resolved = resolve(port: port, width: width) else { return }
    try resolved.device.write(portOffset: resolved.offset, value: value, width: width)
  }

  private func resolve(
    port: UInt16,
    width: DoryX86OperandWidth
  ) -> (device: any DoryPCPortIODevice, offset: UInt16)? {
    let lower = UInt32(port)
    let upper = lower + UInt32(width.byteCount)
    return lock.withLock {
      guard upper <= 0x1_0000,
        let mapping = mappings.first(where: {
          lower >= $0.lowerBound && upper <= $0.upperBound
        })
      else {
        return nil
      }
      return (mapping.device, UInt16(lower - mapping.lowerBound))
    }
  }
}

public final class DoryPCUART16550: DoryPCPortIODevice, @unchecked Sendable {
  private typealias InterruptNotification = (sink: @Sendable (Bool) -> Void, level: Bool)

  public let basePort: UInt16
  public let portCount: UInt16 = 8
  public let queueCapacity: Int

  private let lock = NSLock()
  private var interruptEnable: UInt8 = 0
  private var fifoControl: UInt8 = 0
  private var lineControl: UInt8 = 0
  private var modemControl: UInt8 = 0
  private var scratch: UInt8 = 0
  private var divisorLow: UInt8 = 0x0C
  private var divisorHigh: UInt8 = 0
  private var received: [UInt8] = []
  private var transmitted: [UInt8] = []
  // Transmission completes synchronously into the bounded host capture queue.
  // THRE is separately latched: an IIR acknowledgment must not retrigger merely
  // because LSR still reports an empty transmitter.
  private var transmitEmptyInterruptPending = true
  private var droppedReceivedByteCount = 0
  private var droppedTransmittedByteCount = 0
  private var interruptSink: (@Sendable (Bool) -> Void)?
  private var lastInterruptLevel = false

  public init(basePort: UInt16 = 0x3F8, queueCapacity: Int = 64 * 1024) {
    self.basePort = basePort
    self.queueCapacity = max(1, queueCapacity)
  }

  public func enqueueReceivedBytes(_ bytes: [UInt8]) {
    let notification = lock.withLock {
      let available = max(0, queueCapacity - received.count)
      received.append(contentsOf: bytes.prefix(available))
      droppedReceivedByteCount += max(0, bytes.count - available)
      return interruptNotificationLocked()
    }
    notify(notification)
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

  public func drainTransmittedBytes(maximumCount: Int = .max) -> [UInt8] {
    lock.withLock {
      let count = min(max(0, maximumCount), transmitted.count)
      let result = Array(transmitted.prefix(count))
      transmitted.removeFirst(count)
      return result
    }
  }

  public var dropCounts: (received: Int, transmitted: Int) {
    lock.withLock { (droppedReceivedByteCount, droppedTransmittedByteCount) }
  }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    let (value, notification) = lock.withLock {
      let value = readByte(portOffset)
      return (value, interruptNotificationLocked())
    }
    notify(notification)
    return UInt32(value)
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    let (clearedNotification, notification) = lock.withLock {
      var clearedNotification: InterruptNotification?
      if portOffset == 0, !divisorLatchEnabled {
        // Writing THR acknowledges its interrupt. Preserve this falling edge
        // before immediate completion raises the next one, including for a
        // driver that services THRE without first reading IIR.
        transmitEmptyInterruptPending = false
        clearedNotification = interruptNotificationLocked()
      }
      writeByte(portOffset, UInt8(truncatingIfNeeded: value))
      return (clearedNotification, interruptNotificationLocked())
    }
    notify(clearedNotification)
    notify(notification)
  }

  private var divisorLatchEnabled: Bool { lineControl & 0x80 != 0 }

  private func readByte(_ offset: UInt16) -> UInt8 {
    switch offset {
    case 0 where divisorLatchEnabled: return divisorLow
    case 0 where received.isEmpty: return 0
    case 0: return received.removeFirst()
    case 1 where divisorLatchEnabled: return divisorHigh
    case 1: return interruptEnable
    case 2:
      // TI TL16C550D Table 5: receive data has priority over THRE; reading IIR
      // acknowledges THRE only when THRE is the reported interrupt source.
      if interruptEnable & 1 != 0, !received.isEmpty { return 0x04 }
      if interruptEnable & 2 != 0, transmitEmptyInterruptPending {
        transmitEmptyInterruptPending = false
        return 0x02
      }
      return 0x01
    case 3: return lineControl
    case 4: return modemControl
    case 5: return 0x60 | (received.isEmpty ? 0 : 0x01)
    case 6: return 0xB0
    case 7: return scratch
    default: return 0xFF
    }
  }

  private func writeByte(_ offset: UInt16, _ value: UInt8) {
    switch offset {
    case 0 where divisorLatchEnabled: divisorLow = value
    case 0:
      if transmitted.count < queueCapacity {
        transmitted.append(value)
      } else {
        droppedTransmittedByteCount += 1
      }
      transmitEmptyInterruptPending = true
    case 1 where divisorLatchEnabled: divisorHigh = value
    case 1:
      if value & 2 != 0, interruptEnable & 2 == 0 {
        transmitEmptyInterruptPending = true
      }
      interruptEnable = value & 0x0F
    case 2: fifoControl = value
    case 3: lineControl = value
    case 4: modemControl = value
    case 7: scratch = value
    default: break
    }
  }

  private func interruptLevelLocked() -> Bool {
    (interruptEnable & 1 != 0 && !received.isEmpty)
      || (interruptEnable & 2 != 0 && transmitEmptyInterruptPending)
  }

  private func interruptNotificationLocked() -> InterruptNotification? {
    let level = interruptLevelLocked()
    guard level != lastInterruptLevel else { return nil }
    lastInterruptLevel = level
    return interruptSink.map { ($0, level) }
  }

  private func notify(_ notification: InterruptNotification?) {
    if let notification { notification.sink(notification.level) }
  }
}
