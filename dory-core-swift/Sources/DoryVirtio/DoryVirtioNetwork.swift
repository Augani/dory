import Foundation

extension DoryVirtioFeatures {
  public static let networkMTU = Self(rawValue: 1 << 3)
  public static let networkMACAddress = Self(rawValue: 1 << 5)
  public static let networkStatus = Self(rawValue: 1 << 16)
}

public protocol DoryVirtioNetworkBackend: AnyObject, Sendable {
  func transmit(frame: [UInt8]) throws
  func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void)
  /// Permanent backend retirement must revoke the device before its guest memory can be freed.
  func connectStopSink(_ sink: @escaping @Sendable () -> Void)
}

public extension DoryVirtioNetworkBackend {
  func connectStopSink(_ sink: @escaping @Sendable () -> Void) {}
}

public enum DoryVirtioNetworkError: Error, Sendable, Equatable {
  case invalidMACAddress([UInt8])
  case invalidMTU(UInt16)
  case invalidDescriptorDirection
  case malformedHeader
  case invalidFrameLength(Int)
  case receiveBufferTooSmall(required: UInt64, available: UInt64)
  case noReceivedFrame
  case deviceStopped
  case linkDown
}

/// Modern two-queue VirtIO network device with bounded host ingress and no implicit offloads.
/// Queue 0 receives complete Ethernet frames; queue 1 transmits them. The current PCI adapter
/// requires VERSION_1; the shorter legacy interface is not implemented.
public final class DoryVirtioNetworkDevice: @unchecked Sendable {
  // VirtIO 1.2 §5.1.6 includes num_buffers even without MRG_RXBUF. Only the legacy
  // interface (§5.1.6.1) omits those two bytes when merged receive buffers are disabled.
  public static let headerSize = 12
  public static let receiveQueue: UInt16 = 0
  public static let transmitQueue: UInt16 = 1

  public let backend: any DoryVirtioNetworkBackend
  public let macAddress: [UInt8]
  public let mtu: UInt16
  public let maximumPendingReceiveFrames: Int

  private let lock = NSLock()
  private let publicationLock = NSLock()
  private let notificationLock = NSRecursiveLock()
  private var pendingReceiveFrames: [[UInt8]] = []
  private var receiveReadySink: (@Sendable () -> Void)?
  private var retirementSink: (@Sendable () -> Void)?
  private var linkUp = true
  private var droppedReceiveFrames = 0
  private var receiveEpoch = UUID()
  private var stopped = false

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
    backend.connectStopSink { [weak self] in self?.stop() }
  }

  public var offeredFeatures: DoryVirtioFeatures {
    [.networkMTU, .networkMACAddress, .networkStatus]
  }

  public var configuration: [UInt8] {
    let status: UInt16 = lock.withLock { linkUp ? 1 : 0 }
    return macAddress + littleEndian(status) + [0, 0] + littleEndian(mtu)
  }

  public var canReceive: Bool { lock.withLock { !stopped && linkUp && !pendingReceiveFrames.isEmpty } }
  public var isStopped: Bool { lock.withLock { stopped } }
  public var pendingReceiveCount: Int { lock.withLock { pendingReceiveFrames.count } }
  public var droppedReceiveCount: Int { lock.withLock { droppedReceiveFrames } }

  public func connectReceiveReadySink(_ sink: @escaping @Sendable () -> Void) {
    notificationLock.withLock {
      let epoch = lock.withLock {
        guard !stopped else { return Optional<UUID>.none }
        receiveReadySink = sink
        return pendingReceiveFrames.isEmpty ? nil : receiveEpoch
      }
      if let epoch { notifyReceiveReady(sink, epoch: epoch) }
    }
  }

  /// A transport uses this to revoke its lifecycle lease and join used-ring completion, which
  /// occurs after semantic payload processing returns. The callback runs outside device locks.
  public func connectRetirementSink(_ sink: @escaping @Sendable () -> Void) {
    let alreadyStopped = lock.withLock {
      retirementSink = sink
      return stopped
    }
    if alreadyStopped { sink() }
  }

  public func setLinkUp(_ isUp: Bool) -> Bool {
    let changed = lock.withLock {
      guard !stopped, linkUp != isUp else { return false }
      linkUp = isUp
      if !isUp {
        receiveEpoch = UUID()
        pendingReceiveFrames.removeAll(keepingCapacity: true)
      }
      return true
    }
    if changed, !isUp {
      notificationLock.withLock {}
      publicationLock.withLock {}
    }
    return changed
  }

  /// Drops queued host ingress so a pre-reset frame cannot be delivered after the receive queue
  /// has been reset and renegotiated. Link state, immutable configuration, the backend
  /// connection, and diagnostic counters are preserved.
  public func reset() {
    lock.withLock {
      receiveEpoch = UUID()
      pendingReceiveFrames.removeAll(keepingCapacity: true)
    }
    // An already-selected packet may finish, but reset cannot return before its DMA is joined.
    notificationLock.withLock {}
    publicationLock.withLock {}
  }

  public func stop() {
    let retiringTransport = lock.withLock {
      stopped = true
      linkUp = false
      receiveEpoch = UUID()
      pendingReceiveFrames.removeAll(keepingCapacity: true)
      receiveReadySink = nil
      return retirementSink
    }
    // Every caller joins, including callers racing the first stop owner.
    notificationLock.withLock {}
    publicationLock.withLock {}
    retiringTransport?()
  }

  @discardableResult
  public func receive(frame: [UInt8]) -> Bool {
    guard validFrameLength(frame.count) else {
      lock.withLock { droppedReceiveFrames += 1 }
      return false
    }
    let delivery: (Bool, UUID, (@Sendable () -> Void)?) = lock.withLock {
      guard !stopped, linkUp, pendingReceiveFrames.count < maximumPendingReceiveFrames else {
        droppedReceiveFrames += 1
        return (false, receiveEpoch, nil)
      }
      pendingReceiveFrames.append(frame)
      return (true, receiveEpoch, receiveReadySink)
    }
    if let sink = delivery.2 { notifyReceiveReady(sink, epoch: delivery.1) }
    return delivery.0
  }

  private func notifyReceiveReady(_ sink: @Sendable () -> Void, epoch: UUID) {
    notificationLock.withLock {
      guard lock.withLock({ !stopped && linkUp && receiveEpoch == epoch }) else { return }
      sink()
    }
  }

  public func processTransmit(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    publicationLock.lock()
    defer { publicationLock.unlock() }
    try requireLiveLink()
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
    publicationLock.lock()
    defer { publicationLock.unlock() }
    try requireLiveLink()
    guard !chain.descriptors.isEmpty,
      chain.readableByteCount == 0,
      chain.descriptors.allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioNetworkError.invalidDescriptorDirection }
    guard let selection = lock.withLock({ pendingReceiveFrames.first.map { (receiveEpoch, $0) } }) else {
      throw DoryVirtioNetworkError.noReceivedFrame
    }
    let frame = selection.1
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
    var header = [UInt8](repeating: 0, count: Self.headerSize)
    // §5.1.6.4.1 requires one used buffer when MRG_RXBUF was not negotiated. The
    // single available descriptor chain can still scatter that buffer across elements.
    header[10] = 1
    try scatter(header + frame, into: chain.descriptors, memory: memory)
    lock.withLock {
      if receiveEpoch == selection.0, pendingReceiveFrames.first == frame {
        pendingReceiveFrames.removeFirst()
      }
    }
    return UInt32(required)
  }

  private func validFrameLength(_ count: Int) -> Bool {
    (14...Int(mtu) + 18).contains(count)
  }

  private func requireLiveLink() throws {
    try lock.withLock {
      guard !stopped else { throw DoryVirtioNetworkError.deviceStopped }
      guard linkUp else { throw DoryVirtioNetworkError.linkDown }
    }
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var result: [UInt8] = []
    let maximumBytes = Self.headerSize + Int(mtu) + 18
    var totalBytes = 0
    for descriptor in descriptors {
      guard UInt64(descriptor.length) <= UInt64(maximumBytes - totalBytes) else {
        throw DoryVirtioNetworkError.invalidFrameLength(Int(clamping: UInt64(totalBytes) + UInt64(descriptor.length)))
      }
      totalBytes += Int(descriptor.length)
    }
    result.reserveCapacity(totalBytes)
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
