import Foundation

public enum DoryPCUSBHIDProfile: String, Codable, Sendable, Hashable {
  case keyboard
  case mouse
}

public enum DoryPCUSBHIDError: Error, Sendable, Equatable {
  case invalidReportLength(expected: Int, actual: Int)
  case queueFull(maximum: Int)
}

/// USB HID 1.11 boot devices for firmware and stock Linux input paths.
public final class DoryPCUSBHIDDevice: DoryPCUSBDevice, DoryPCUSBTransferReadyNotifying,
  @unchecked Sendable
{
  public let speed: DoryPCXHCIPortSpeed = .high
  public let profile: DoryPCUSBHIDProfile
  public let maximumQueuedReports: Int

  private let lock = NSLock()
  private var reports: [[UInt8]] = []
  private var configuration: UInt8 = 0
  private var idleRate: UInt8 = 0
  private var bootProtocol = true
  private var transferReadyHandler: (@Sendable () -> Void)?

  public init(profile: DoryPCUSBHIDProfile, maximumQueuedReports: Int = 1_024) {
    precondition(maximumQueuedReports > 0)
    self.profile = profile
    self.maximumQueuedReports = maximumQueuedReports
  }

  public var reportByteCount: Int { profile == .keyboard ? 8 : 4 }

  public func enqueue(report: [UInt8]) throws {
    guard report.count == reportByteCount else {
      throw DoryPCUSBHIDError.invalidReportLength(
        expected: reportByteCount,
        actual: report.count
      )
    }
    let handler = try lock.withLock {
      guard reports.count < maximumQueuedReports else {
        throw DoryPCUSBHIDError.queueFull(maximum: maximumQueuedReports)
      }
      reports.append(report)
      return transferReadyHandler
    }
    handler?()
  }

  public func setTransferReadyHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock { transferReadyHandler = handler }
  }

  public func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult {
    if transfer.type == .interrupt, transfer.direction == .in, transfer.endpoint == 1 {
      return lock.withLock {
        guard !reports.isEmpty else { return result(.notReady) }
        return result(.success, Array(reports.removeFirst().prefix(transfer.maximumResponseBytes)))
      }
    }
    guard transfer.type == .control, let setup = transfer.setup else { return result(.stalled) }
    if setup.requestType & 0x60 == 0 {
      return standardControl(setup)
    }
    return hidControl(setup)
  }

  public func reset() {
    lock.withLock {
      configuration = 0
      idleRate = 0
      bootProtocol = true
      reports.removeAll(keepingCapacity: true)
    }
  }

  public func cancelAll() { lock.withLock { reports.removeAll(keepingCapacity: true) } }

  private func standardControl(_ setup: DoryPCUSBSetupPacket) -> DoryPCUSBTransferResult {
    switch setup.request {
    case 6 where setup.direction == .in:
      let descriptorType = UInt8(setup.value >> 8)
      let descriptorIndex = UInt8(truncatingIfNeeded: setup.value)
      let descriptor: [UInt8]?
      switch descriptorType {
      case 1: descriptor = deviceDescriptor
      case 2: descriptor = configurationDescriptor
      case 3: descriptor = stringDescriptor(index: descriptorIndex)
      case 0x21: descriptor = hidDescriptor
      case 0x22: descriptor = reportDescriptor
      default: descriptor = nil
      }
      guard let descriptor else { return result(.stalled) }
      return result(.success, Array(descriptor.prefix(Int(setup.length))))
    case 8 where setup.direction == .in:
      return lock.withLock { result(.success, [configuration]) }
    case 9 where setup.direction == .out:
      let value = UInt8(truncatingIfNeeded: setup.value)
      guard value <= 1 else { return result(.stalled) }
      lock.withLock { configuration = value }
      return result(.success)
    case 5 where setup.direction == .out:
      return result(.success)
    default:
      return result(.stalled)
    }
  }

  private func hidControl(_ setup: DoryPCUSBSetupPacket) -> DoryPCUSBTransferResult {
    switch setup.request {
    case 2 where setup.direction == .in:
      return lock.withLock { result(.success, [idleRate]) }
    case 3 where setup.direction == .in:
      return lock.withLock { result(.success, [bootProtocol ? 0 : 1]) }
    case 10 where setup.direction == .out:
      lock.withLock { idleRate = UInt8(setup.value >> 8) }
      return result(.success)
    case 11 where setup.direction == .out:
      guard setup.value <= 1 else { return result(.stalled) }
      lock.withLock { bootProtocol = setup.value == 0 }
      return result(.success)
    default:
      return result(.stalled)
    }
  }

  private var deviceDescriptor: [UInt8] {
    [
      18, 1, 0x00, 0x02, 0, 0, 0, 64,
      0xF4, 0x1A, profile == .keyboard ? 0x01 : 0x02, 0x12,
      0x00, 0x01, 1, 2, 3, 1,
    ]
  }

  private var configurationDescriptor: [UInt8] {
    let endpointSize = UInt16(reportByteCount)
    return [
      9, 2, 34, 0, 1, 1, 0, 0xA0, 25,
      9, 4, 0, 0, 1, 3, 1, profile == .keyboard ? 1 : 2, 0,
    ] + hidDescriptor + [
      7, 5, 0x81, 3, UInt8(truncatingIfNeeded: endpointSize),
      UInt8(truncatingIfNeeded: endpointSize >> 8), 10,
    ]
  }

  private var hidDescriptor: [UInt8] {
    let length = UInt16(reportDescriptor.count)
    return [
      9, 0x21, 0x11, 0x01, 0, 1, 0x22,
      UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
    ]
  }

  private var reportDescriptor: [UInt8] {
    switch profile {
    case .keyboard:
      return [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07,
        0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01,
        0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
        0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07,
        0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
      ]
    case .mouse:
      return [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01,
        0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
        0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0xC0, 0xC0,
      ]
    }
  }

  private func stringDescriptor(index: UInt8) -> [UInt8]? {
    if index == 0 { return [4, 3, 0x09, 0x04] }
    let value: String
    switch index {
    case 1: value = "Dory"
    case 2: value = profile == .keyboard ? "Dory USB Keyboard" : "Dory USB Mouse"
    case 3: value = profile == .keyboard ? "DORY-HID-KBD" : "DORY-HID-MOUSE"
    default: return nil
    }
    let payload = value.utf16.flatMap {
      [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
    }
    return [UInt8(payload.count + 2), 3] + payload
  }

  private func result(
    _ status: DoryPCUSBTransferStatus,
    _ payload: [UInt8] = []
  ) -> DoryPCUSBTransferResult {
    try! .init(status: status, payload: payload)
  }
}
