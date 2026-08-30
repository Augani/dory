import Foundation

public enum DoryPCUSBTransferType: UInt8, Codable, CaseIterable, Sendable, Hashable {
  case control
  case isochronous
  case bulk
  case interrupt
}

public enum DoryPCUSBTransferDirection: UInt8, Codable, Sendable, Hashable {
  case out
  case `in`
}

public struct DoryPCUSBSetupPacket: Codable, Sendable, Hashable {
  public let requestType: UInt8
  public let request: UInt8
  public let value: UInt16
  public let index: UInt16
  public let length: UInt16

  public init(bytes: [UInt8]) throws {
    guard bytes.count == 8 else { throw DoryPCUSBDeviceError.invalidSetupPacket }
    requestType = bytes[0]
    request = bytes[1]
    value = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
    index = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
    length = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
  }

  public var direction: DoryPCUSBTransferDirection {
    requestType & 0x80 == 0 ? .out : .in
  }
}

public struct DoryPCUSBTransfer: Sendable, Hashable {
  public let type: DoryPCUSBTransferType
  public let direction: DoryPCUSBTransferDirection
  public let endpoint: UInt8
  public let setup: DoryPCUSBSetupPacket?
  public let payload: [UInt8]
  public let maximumResponseBytes: Int

  public init(
    type: DoryPCUSBTransferType,
    direction: DoryPCUSBTransferDirection,
    endpoint: UInt8,
    setup: DoryPCUSBSetupPacket? = nil,
    payload: [UInt8] = [],
    maximumResponseBytes: Int = 0
  ) throws {
    guard endpoint < 16, payload.count <= DoryPCUSBDeviceLimits.maximumTransferBytes,
      (0...DoryPCUSBDeviceLimits.maximumTransferBytes).contains(maximumResponseBytes),
      type == .control || setup == nil,
      type != .control || endpoint == 0 && setup != nil
    else { throw DoryPCUSBDeviceError.invalidTransfer }
    self.type = type
    self.direction = direction
    self.endpoint = endpoint
    self.setup = setup
    self.payload = payload
    self.maximumResponseBytes = maximumResponseBytes
  }
}

public enum DoryPCUSBTransferStatus: UInt8, Codable, Sendable, Hashable {
  case success
  case shortPacket
  case stalled
  case transactionError
  case disconnected
}

public struct DoryPCUSBTransferResult: Sendable, Hashable {
  public let status: DoryPCUSBTransferStatus
  public let payload: [UInt8]

  public init(status: DoryPCUSBTransferStatus, payload: [UInt8] = []) throws {
    guard payload.count <= DoryPCUSBDeviceLimits.maximumTransferBytes else {
      throw DoryPCUSBDeviceError.invalidTransfer
    }
    self.status = status
    self.payload = payload
  }
}

public enum DoryPCUSBDeviceLimits {
  public static let maximumTransferBytes = 16 * 1024 * 1024
  public static let maximumOutstandingTransfers = 1_024
}

public enum DoryPCUSBDeviceError: Error, Sendable, Equatable {
  case invalidSetupPacket
  case invalidTransfer
}

/// Capability handed to xHCI only after host policy has authorized a virtual or physical device.
/// Implementations must bound their own latency and may not expose ambient host USB authority.
public protocol DoryPCUSBDevice: AnyObject, Sendable {
  var speed: DoryPCXHCIPortSpeed { get }
  func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult
  func reset()
  func cancelAll()
}

public final class DoryPCUSBRecordingDevice: DoryPCUSBDevice, @unchecked Sendable {
  public let speed: DoryPCXHCIPortSpeed
  private let lock = NSLock()
  private var queuedResults: [DoryPCUSBTransferResult]
  private var recordedTransfers: [DoryPCUSBTransfer] = []
  private var resetCountStorage = 0
  private var cancellationCountStorage = 0

  public init(
    speed: DoryPCXHCIPortSpeed = .high,
    queuedResults: [DoryPCUSBTransferResult] = []
  ) {
    self.speed = speed
    self.queuedResults = queuedResults
  }

  public var transfers: [DoryPCUSBTransfer] { lock.withLock { recordedTransfers } }
  public var resetCount: Int { lock.withLock { resetCountStorage } }
  public var cancellationCount: Int { lock.withLock { cancellationCountStorage } }

  public func enqueue(_ result: DoryPCUSBTransferResult) {
    lock.withLock { queuedResults.append(result) }
  }

  public func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult {
    lock.withLock {
      recordedTransfers.append(transfer)
      if !queuedResults.isEmpty { return queuedResults.removeFirst() }
      return try! .init(status: .success)
    }
  }

  public func reset() { lock.withLock { resetCountStorage += 1 } }

  public func cancelAll() { lock.withLock { cancellationCountStorage += 1 } }
}
