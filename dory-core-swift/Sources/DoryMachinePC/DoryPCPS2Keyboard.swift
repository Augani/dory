import DoryDBTX86
import Foundation

/// Minimal AT-compatible i8042 keyboard controller. It deliberately models only the first PS/2
/// port used by firmware and ordinary boot loaders: status, command byte, keyboard ACK/reset and
/// bounded scan-code delivery. When the guest enables the standard i8042 translation bit, physical
/// set-2 input is translated into the set-1 stream consumed by the UEFI keyboard driver. Mouse and
/// controller self-test extensions remain absent.
public final class DoryPCPS2KeyboardController: @unchecked Sendable {
  public struct Snapshot: Sendable, Equatable {
    public let bytesPending: Int
    public let commandByte: UInt8
    public let keyboardScanCodeSet: UInt8
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
  private var expectingKeyboardArgument: KeyboardCommand?
  // The physical keyboard defaults to scan-code set 1. The UEFI driver may select set 2 while
  // enabling the controller's translation bit; in that case the guest-visible bytes remain set 1.
  private var keyboardScanCodeSet: UInt8 = 1
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
        keyboardScanCodeSet: keyboardScanCodeSet,
        dataReadCount: dataReadCount,
        statusReadCount: statusReadCount,
        dataWriteCount: dataWriteCount,
        commandWriteCount: commandWriteCount)
    }
  }

  /// Delivers scan bytes in the set currently negotiated by the guest keyboard driver.
  @discardableResult
  public func enqueueScanCodes(_ bytes: [UInt8]) -> Bool {
    let result = lock.withLock { () -> (Bool, (@Sendable (Bool) -> Void, Bool)?) in
      let translated = translateKeyboardScanCodesLocked(bytes)
      guard translated.count <= maximumQueuedBytes - output.count else { return (false, nil) }
      output.append(contentsOf: translated)
      return (true, interruptNotificationLocked())
    }
    notify(result.1)
    return result.0
  }

  /// Convenience for existing callers that explicitly target the set-1 test fixture.
  @discardableResult
  public func enqueueSet1ScanCodes(_ bytes: [UInt8]) -> Bool {
    enqueueScanCodes(bytes)
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
    let result = lock.withLock { () -> (UInt8, [(@Sendable (Bool) -> Void, Bool)]) in
      dataReadCount &+= 1
      guard !output.isEmpty else {
        return (0, interruptNotificationLocked().map { [$0] } ?? [])
      }

      let value = output.removeFirst()
      if !output.isEmpty, let interruptSink, interruptLevelLocked() {
        // The i8042 exposes one output-buffer byte at a time. Once the guest reads the current
        // byte, the next queued byte becomes visible and raises a new IRQ1 edge. Keeping the
        // line permanently asserted loses that edge on the legacy PIC and can strand a key
        // release or command response behind the first byte.
        return (value, [(interruptSink, false), (interruptSink, true)])
      }
      return (value, interruptNotificationLocked().map { [$0] } ?? [])
    }
    for notification in result.1 { notify(notification) }
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
      } else if let command = expectingKeyboardArgument {
        expectingKeyboardArgument = nil
        if command == .scanCodeSet, (1...3).contains(value) {
          keyboardScanCodeSet = value
        }
        output.append(0xFA)
      } else {
        switch value {
        case 0xFF:
          keyboardScanCodeSet = 1
          output.append(contentsOf: [0xFA, 0xAA])
        case 0xF0:
          expectingKeyboardArgument = .scanCodeSet
          output.append(0xFA)
        case 0xED:
          expectingKeyboardArgument = .leds
          output.append(0xFA)
        case 0xF3:
          expectingKeyboardArgument = .typematic
          output.append(0xFA)
        case 0xF4, 0xF5:
          output.append(0xFA)
        default: output.append(0xFA)
        }
      }
      return interruptNotificationLocked()
    }
    notify(notification)
  }

  private enum KeyboardCommand {
    case scanCodeSet
    case leds
    case typematic
  }

  private func translateKeyboardScanCodesLocked(_ bytes: [UInt8]) -> [UInt8] {
    // IBM PC-compatible controller command-byte bit 6 enables set-2-to-set-1 translation.
    // Do not transform explicit set-1 sources or configurations where the guest disabled it.
    guard keyboardScanCodeSet == 2, commandByte & 0x40 != 0 else { return bytes }
    let set2ToSet1: [UInt8: UInt8] = [
      0x5A: 0x1C, 0x29: 0x39, 0x24: 0x12, 0x21: 0x2E, 0x44: 0x18,
      0x31: 0x31, 0x1B: 0x1F, 0x4B: 0x26, 0x55: 0x0D, 0x2C: 0x14,
      0x35: 0x15, 0x12: 0x2A, 0x45: 0x0B, 0x41: 0x33, 0x16: 0x02,
      0x1E: 0x03, 0x2E: 0x06, 0x14: 0x1D, 0x22: 0x2D, 0x69: 0x4F,
    ]
    var translated: [UInt8] = []
    var extended = false
    var breakCode = false
    for byte in bytes {
      switch byte {
      case 0xE0:
        extended = true
      case 0xF0:
        breakCode = true
      default:
        guard let code = set2ToSet1[byte] else {
          // Preserve unmodelled input rather than corrupting it. Callers can still diagnose the
          // raw value, and translation coverage expands only with a verified mapping.
          translated.append(byte)
          extended = false
          breakCode = false
          continue
        }
        if extended { translated.append(0xE0) }
        translated.append(breakCode ? code | 0x80 : code)
        extended = false
        breakCode = false
      }
    }
    return translated
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
    guard let notification else { return }
    notification.0(notification.1)
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
