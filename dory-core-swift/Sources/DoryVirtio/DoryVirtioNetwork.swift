import Foundation

extension DoryVirtioFeatures {
  public static let networkMTU = Self(rawValue: 1 << 3)
  public static let networkMACAddress = Self(rawValue: 1 << 5)
  public static let networkStatus = Self(rawValue: 1 << 16)
}

public protocol DoryVirtioNetworkBackend: AnyObject, Sendable {
  func transmit(frame: [UInt8]) throws
  func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void)
}

public enum DoryVirtioNetworkError: Error, Sendable, Equatable {
  case invalidMACAddress([UInt8])
  case invalidMTU(UInt16)
  case invalidDescriptorDirection
  case malformedHeader
  case invalidFrameLength(Int)
  case receiveBufferTooSmall(required: UInt64, available: UInt64)
  case noReceivedFrame
}

/// Transport-neutral two-queue VirtIO network device with bounded host ingress and no implicit
/// offloads. Queue 0 receives complete Ethernet frames; queue 1 transmits them.
public final class DoryVirtioNetworkDevice: @unchecked Sendable {
  public static let headerSize = 10
  public static let receiveQueue: UInt16 = 0
  public static let transmitQueue: UInt16 = 1

  public let backend: any DoryVirtioNetworkBackend
  public let macAddress: [UInt8]
  public let mtu: UInt16
  public let maximumPendingReceiveFrames: Int

  private let lock = NSLock()
  private var pendingReceiveFrames: [[UInt8]] = []
  private var receiveReadySink: (@Sendable () -> Void)?
  private var linkUp = true
  private var droppedReceiveFrames = 0

  public init(
    backend: any DoryVirtioNetworkBackend,
    macAddress: [UInt8],
    mtu: UInt16 = 1500,
    maximumPendingReceiveFrames: Int = 1024
  ) throws {
    guard macAddress.count == 6,
      macAddress[0] & 1 == 0,
      macAddress.contains(where: { $0 != 0 })
    else { throw DoryVirtioNetworkError.invalidMACAddress(macAddress) }
    guard (1280...9000).contains(mtu) else {
      throw DoryVirtioNetworkError.invalidMTU(mtu)
    }
    precondition(maximumPendingReceiveFrames > 0)
    self.backend = backend
    self.macAddress = macAddress
    self.mtu = mtu
    self.maximumPendingReceiveFrames = maximumPendingReceiveFrames
    backend.connectReceiveSink { [weak self] frame in self?.receive(frame: frame) }
  }

  public var offeredFeatures: DoryVirtioFeatures {
    [.networkMTU, .networkMACAddress, .networkStatus]
  }

  public var configuration: [UInt8] {
    let status: UInt16 = lock.withLock { linkUp ? 1 : 0 }
    return macAddress + littleEndian(status) + [0, 0] + littleEndian(mtu)
  }

  public var canReceive: Bool { lock.withLock { !pendingReceiveFrames.isEmpty } }
  public var pendingReceiveCount: Int { lock.withLock { pendingReceiveFrames.count } }
  public var droppedReceiveCount: Int { lock.withLock { droppedReceiveFrames } }

  public func connectReceiveReadySink(_ sink: @escaping @Sendable () -> Void) {
    let ready = lock.withLock {
      receiveReadySink = sink
      return !pendingReceiveFrames.isEmpty
    }
    if ready { sink() }
  }

  public func setLinkUp(_ isUp: Bool) -> Bool {
    lock.withLock {
      guard linkUp != isUp else { return false }
      linkUp = isUp
      return true
    }
  }

  @discardableResult
  public func receive(frame: [UInt8]) -> Bool {
    guard validFrameLength(frame.count) else {
      lock.withLock { droppedReceiveFrames += 1 }
      return false
    }
    let delivery: (Bool, (@Sendable () -> Void)?) = lock.withLock {
      guard linkUp, pendingReceiveFrames.count < maximumPendingReceiveFrames else {
        droppedReceiveFrames += 1
        return (false, nil)
      }
      pendingReceiveFrames.append(frame)
      return (true, receiveReadySink)
    }
    delivery.1?()
    return delivery.0
  }

  public func processTransmit(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard !chain.descriptors.isEmpty,
      chain.writableByteCount == 0,
      chain.descriptors.allSatisfy({ !$0.deviceWillWrite })
    else { throw DoryVirtioNetworkError.invalidDescriptorDirection }
    let bytes = try gather(chain.descriptors, memory: memory)
    guard bytes.count >= Self.headerSize,
      bytes.prefix(Self.headerSize).allSatisfy({ $0 == 0 })
    else { throw DoryVirtioNetworkError.malformedHeader }
    let frame = Array(bytes.dropFirst(Self.headerSize))
    guard validFrameLength(frame.count) else {
      throw DoryVirtioNetworkError.invalidFrameLength(frame.count)
    }
    try backend.transmit(frame: frame)
    return 0
  }

  public func processReceive(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard !chain.descriptors.isEmpty,
      chain.readableByteCount == 0,
      chain.descriptors.allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioNetworkError.invalidDescriptorDirection }
    guard let frame = lock.withLock({ pendingReceiveFrames.first }) else {
      throw DoryVirtioNetworkError.noReceivedFrame
    }
    let required = UInt64(Self.headerSize + frame.count)
    guard chain.writableByteCount >= required else {
      throw DoryVirtioNetworkError.receiveBufferTooSmall(
        required: required,
        available: chain.writableByteCount
      )
    }
    for descriptor in chain.descriptors {
      try memory.validate(
        at: descriptor.address,
        byteCount: Int(descriptor.length),
        deviceWillWrite: true
      )
    }
    try scatter(
      [UInt8](repeating: 0, count: Self.headerSize) + frame, into: chain.descriptors, memory: memory
    )
    lock.withLock {
      if pendingReceiveFrames.first == frame { pendingReceiveFrames.removeFirst() }
    }
    return UInt32(required)
  }

  private func validFrameLength(_ count: Int) -> Bool {
    (14...Int(mtu) + 18).contains(count)
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(descriptors.reduce(0) { $0 + Int($1.length) })
    for descriptor in descriptors {
      let bytes = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
      guard bytes.count == Int(descriptor.length) else {
        throw DoryVirtioNetworkError.invalidFrameLength(bytes.count)
      }
      result += bytes
    }
    return result
  }

  private func scatter(
    _ bytes: [UInt8],
    into descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    var sourceOffset = 0
    for descriptor in descriptors where sourceOffset < bytes.count {
      let count = min(Int(descriptor.length), bytes.count - sourceOffset)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[sourceOffset..<(sourceOffset + count)])
      )
      sourceOffset += count
    }
  }
}

public final class DoryVirtioInMemoryNetworkBackend: DoryVirtioNetworkBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var receiveSink: (@Sendable ([UInt8]) -> Void)?
  private var transmitted: [[UInt8]] = []

  public init() {}

  public var transmittedFrames: [[UInt8]] { lock.withLock { transmitted } }

  public func transmit(frame: [UInt8]) throws {
    lock.withLock { transmitted.append(frame) }
  }

  public func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
    lock.withLock { receiveSink = sink }
  }

  public func injectReceivedFrame(_ frame: [UInt8]) {
    let sink = lock.withLock { receiveSink }
    sink?(frame)
  }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
