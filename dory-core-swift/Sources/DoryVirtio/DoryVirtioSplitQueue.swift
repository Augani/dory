import Foundation

public protocol DoryVirtioGuestMemory: Sendable {
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8]
  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws
  func write(at address: UInt64, bytes: [UInt8]) throws
  func synchronize()
}

public enum DoryVirtioQueueError: Error, Sendable, Equatable {
  case invalidQueueSize(Int)
  case invalidQueueAlignment(descriptor: UInt64, driver: UInt64, device: UInt64)
  case unconfigured
  case invalidMemoryResponse(expected: Int, actual: Int)
  case availableIndexAdvancedTooFar(delta: UInt16, queueSize: UInt16)
  case invalidDescriptorIndex(UInt16)
  case descriptorCycle(UInt16)
  case descriptorAddressOverflow(address: UInt64, length: UInt32)
  case guestAddressOverflow(address: UInt64, offset: UInt64)
  case descriptorBudgetExceeded(UInt64)
  case invalidIndirectDescriptor(UInt16)
  case duplicateCompletion(UInt16)
  case invalidCompletionLength(UInt32)
}

public struct DoryVirtioDescriptor: Sendable, Hashable {
  public static let nextFlag: UInt16 = 1
  public static let writeFlag: UInt16 = 2
  public static let indirectFlag: UInt16 = 4

  public let address: UInt64
  public let length: UInt32
  public let flags: UInt16
  public let next: UInt16

  public init(address: UInt64, length: UInt32, flags: UInt16, next: UInt16) {
    self.address = address
    self.length = length
    self.flags = flags
    self.next = next
  }

  public var deviceWillWrite: Bool { flags & Self.writeFlag != 0 }
}

public struct DoryVirtioDescriptorChain: Sendable, Hashable {
  public let headIndex: UInt16
  public let descriptors: [DoryVirtioDescriptor]
  public let readableByteCount: UInt64
  public let writableByteCount: UInt64

  public init(
    headIndex: UInt16,
    descriptors: [DoryVirtioDescriptor],
    readableByteCount: UInt64,
    writableByteCount: UInt64
  ) {
    self.headIndex = headIndex
    self.descriptors = descriptors
    self.readableByteCount = readableByteCount
    self.writableByteCount = writableByteCount
  }
}

public struct DoryVirtioSplitQueueSnapshot: Sendable, Hashable {
  public let size: UInt16
  public let descriptorAddress: UInt64
  public let driverAddress: UInt64
  public let deviceAddress: UInt64
  public let enabled: Bool
  public let lastAvailableIndex: UInt16
  public let lastUsedIndex: UInt16
  public let outstandingHeads: Set<UInt16>
}

/// Host side of a hostile split virtqueue. It validates the full chain before exposing a request.
public final class DoryVirtioSplitQueue: @unchecked Sendable {
  private struct Configuration {
    var size: UInt16 = 0
    var descriptorAddress: UInt64 = 0
    var driverAddress: UInt64 = 0
    var deviceAddress: UInt64 = 0
    var enabled = false
  }

  public let maximumSize: UInt16
  public let maximumChainBytes: UInt64

  private let lock = NSLock()
  private var configuration = Configuration()
  private var lastAvailableIndex: UInt16 = 0
  private var lastUsedIndex: UInt16 = 0
  private var outstandingHeads: Set<UInt16> = []

  public init(maximumSize: UInt16 = 256, maximumChainBytes: UInt64 = 64 * 1024 * 1024) {
    precondition(maximumSize > 0 && maximumSize.nonzeroBitCount == 1)
    self.maximumSize = maximumSize
    self.maximumChainBytes = maximumChainBytes
  }

  public func configure(
    size: UInt16,
    descriptorAddress: UInt64,
    driverAddress: UInt64,
    deviceAddress: UInt64,
    enabled: Bool
  ) throws {
    guard size > 0, size <= maximumSize, size.nonzeroBitCount == 1 else {
      throw DoryVirtioQueueError.invalidQueueSize(Int(size))
    }
    guard descriptorAddress % 16 == 0, driverAddress % 2 == 0, deviceAddress % 4 == 0 else {
      throw DoryVirtioQueueError.invalidQueueAlignment(
        descriptor: descriptorAddress,
        driver: driverAddress,
        device: deviceAddress
      )
    }
    lock.withLock {
      configuration = .init(
        size: size,
        descriptorAddress: descriptorAddress,
        driverAddress: driverAddress,
        deviceAddress: deviceAddress,
        enabled: enabled
      )
      lastAvailableIndex = 0
      lastUsedIndex = 0
      outstandingHeads = []
    }
  }

  public func reset() {
    lock.withLock {
      configuration = .init()
      lastAvailableIndex = 0
      lastUsedIndex = 0
      outstandingHeads = []
    }
  }

  /// Initialize or re-arm a negotiated EVENT_IDX queue without consuming a
  /// buffer. The caller must recheck/drain available work after the barrier.
  public func requestAvailableNotification(memory: any DoryVirtioGuestMemory) throws {
    try lock.withLock {
      try armAvailableNotification(lastAvailableIndex,
        configuration: activeConfigurationLocked(), memory: memory)
    }
  }

  public func popAvailable(
    memory: any DoryVirtioGuestMemory,
    allowIndirectDescriptors: Bool,
    eventIndexNegotiated: Bool = false
  ) throws -> DoryVirtioDescriptorChain? {
    try lock.withLock {
      let configuration = try activeConfigurationLocked()
      let availableIndexAddress = try checkedAddress(configuration.driverAddress, adding: 2)
      var availableIndex = try readUInt16(memory, at: availableIndexAddress)
      if eventIndexNegotiated, availableIndex == lastAvailableIndex {
        // A driver can add work while notifications are suppressed. Publish the
        // next index we need, then recheck after a barrier before becoming idle.
        try armAvailableNotification(lastAvailableIndex, configuration: configuration, memory: memory)
        availableIndex = try readUInt16(memory, at: availableIndexAddress)
      }
      let delta = availableIndex &- lastAvailableIndex
      guard delta > 0 else { return nil }
      guard delta <= configuration.size else {
        throw DoryVirtioQueueError.availableIndexAdvancedTooFar(
          delta: delta,
          queueSize: configuration.size
        )
      }
      let slot = UInt64(lastAvailableIndex % configuration.size)
      let ringOffset = 4 + slot * 2
      let head = try readUInt16(
        memory,
        at: try checkedAddress(configuration.driverAddress, adding: ringOffset)
      )
      let chain = try parseChain(
        head: head,
        tableAddress: configuration.descriptorAddress,
        tableCount: configuration.size,
        memory: memory,
        allowIndirectDescriptors: allowIndirectDescriptors,
        indirect: false
      )
      let nextAvailableIndex = lastAvailableIndex &+ 1
      if eventIndexNegotiated {
        try armAvailableNotification(nextAvailableIndex, configuration: configuration, memory: memory)
      }
      lastAvailableIndex = nextAvailableIndex
      outstandingHeads.insert(head)
      return .init(
        headIndex: head,
        descriptors: chain,
        readableByteCount: chain.filter { !$0.deviceWillWrite }.reduce(0) {
          $0 + UInt64($1.length)
        },
        writableByteCount: chain.filter(\.deviceWillWrite).reduce(0) {
          $0 + UInt64($1.length)
        }
      )
    }
  }

  /// VirtIO 1.2 section 2.7.10: avail_event belongs to the device, at the end
  /// of the used ring. Leaving it at zero suppresses every sequential kick
  /// after the first until the 16-bit index wraps. Request the very next entry;
  /// this transport does not poll guest queues while idle.
  private func armAvailableNotification(
    _ index: UInt16,
    configuration: Configuration,
    memory: any DoryVirtioGuestMemory
  ) throws {
    let eventAddress = try checkedAddress(
      configuration.deviceAddress, adding: 4 + UInt64(configuration.size) * 8)
    try memory.validate(at: configuration.deviceAddress, byteCount: 2, deviceWillWrite: true)
    try memory.validate(at: eventAddress, byteCount: 2, deviceWillWrite: true)
    try memory.write(at: configuration.deviceAddress, bytes: [0, 0])
    try memory.write(at: eventAddress, bytes: littleEndian(index))
    memory.synchronize()
  }

  /// Publishes a used element and returns whether the driver requested an interrupt.
  public func complete(
    _ chain: DoryVirtioDescriptorChain,
    bytesWritten: UInt32,
    memory: any DoryVirtioGuestMemory,
    eventIndexNegotiated: Bool
  ) throws -> Bool {
    try lock.withLock {
      let configuration = try activeConfigurationLocked()
      guard outstandingHeads.contains(chain.headIndex) else {
        throw DoryVirtioQueueError.duplicateCompletion(chain.headIndex)
      }
      guard UInt64(bytesWritten) <= chain.writableByteCount else {
        throw DoryVirtioQueueError.invalidCompletionLength(bytesWritten)
      }
      let oldUsedIndex = lastUsedIndex
      let newUsedIndex = lastUsedIndex &+ 1
      let slot = UInt64(oldUsedIndex % configuration.size)
      let elementAddress = try checkedAddress(
        configuration.deviceAddress,
        adding: 4 + slot * 8
      )
      let usedIndexAddress = try checkedAddress(configuration.deviceAddress, adding: 2)
      let notifyDriver: Bool
      if eventIndexNegotiated {
        let usedEventAddress = try checkedAddress(
          configuration.driverAddress,
          adding: 4 + UInt64(configuration.size) * 2
        )
        let event = try readUInt16(memory, at: usedEventAddress)
        notifyDriver = (newUsedIndex &- event &- 1) < (newUsedIndex &- oldUsedIndex)
      } else {
        let availableFlags = try readUInt16(memory, at: configuration.driverAddress)
        notifyDriver = availableFlags & 1 == 0
      }
      try memory.validate(at: elementAddress, byteCount: 8, deviceWillWrite: true)
      try memory.validate(at: usedIndexAddress, byteCount: 2, deviceWillWrite: true)
      try memory.write(
        at: elementAddress,
        bytes: littleEndian(UInt32(chain.headIndex)) + littleEndian(bytesWritten)
      )
      memory.synchronize()
      try memory.write(at: usedIndexAddress, bytes: littleEndian(newUsedIndex))
      memory.synchronize()
      lastUsedIndex = newUsedIndex
      outstandingHeads.remove(chain.headIndex)
      return notifyDriver
    }
  }

  public func snapshot() -> DoryVirtioSplitQueueSnapshot {
    lock.withLock {
      .init(
        size: configuration.size,
        descriptorAddress: configuration.descriptorAddress,
        driverAddress: configuration.driverAddress,
        deviceAddress: configuration.deviceAddress,
        enabled: configuration.enabled,
        lastAvailableIndex: lastAvailableIndex,
        lastUsedIndex: lastUsedIndex,
        outstandingHeads: outstandingHeads
      )
    }
  }

  private func parseChain(
    head: UInt16,
    tableAddress: UInt64,
    tableCount: UInt16,
    memory: any DoryVirtioGuestMemory,
    allowIndirectDescriptors: Bool,
    indirect: Bool
  ) throws -> [DoryVirtioDescriptor] {
    guard head < tableCount else { throw DoryVirtioQueueError.invalidDescriptorIndex(head) }
    var descriptors: [DoryVirtioDescriptor] = []
    var visited: Set<UInt16> = []
    var index = head
    var totalBytes: UInt64 = 0
    while true {
      guard index < tableCount else { throw DoryVirtioQueueError.invalidDescriptorIndex(index) }
      guard visited.insert(index).inserted else {
        throw DoryVirtioQueueError.descriptorCycle(index)
      }
      let descriptor = try readDescriptor(
        memory,
        at: try checkedAddress(tableAddress, adding: UInt64(index) * 16)
      )
      if descriptor.flags & DoryVirtioDescriptor.indirectFlag != 0 {
        guard allowIndirectDescriptors, !indirect,
          descriptor.flags & DoryVirtioDescriptor.nextFlag == 0,
          descriptor.length > 0,
          descriptor.length % 16 == 0,
          descriptor.length / 16 <= UInt32(maximumSize)
        else { throw DoryVirtioQueueError.invalidIndirectDescriptor(index) }
        return try parseChain(
          head: 0,
          tableAddress: descriptor.address,
          tableCount: UInt16(descriptor.length / 16),
          memory: memory,
          allowIndirectDescriptors: false,
          indirect: true
        )
      }
      let (_, overflow) = descriptor.address.addingReportingOverflow(UInt64(descriptor.length))
      guard !overflow else {
        throw DoryVirtioQueueError.descriptorAddressOverflow(
          address: descriptor.address,
          length: descriptor.length
        )
      }
      let (updatedTotal, totalOverflow) = totalBytes.addingReportingOverflow(
        UInt64(descriptor.length)
      )
      guard !totalOverflow, updatedTotal <= maximumChainBytes else {
        let reported = totalOverflow ? UInt64.max : updatedTotal
        throw DoryVirtioQueueError.descriptorBudgetExceeded(reported)
      }
      totalBytes = updatedTotal
      try memory.validate(
        at: descriptor.address,
        byteCount: Int(descriptor.length),
        deviceWillWrite: descriptor.deviceWillWrite
      )
      descriptors.append(descriptor)
      guard descriptor.flags & DoryVirtioDescriptor.nextFlag != 0 else { return descriptors }
      index = descriptor.next
      guard descriptors.count < Int(tableCount) else {
        throw DoryVirtioQueueError.descriptorCycle(index)
      }
    }
  }

  private func activeConfigurationLocked() throws -> Configuration {
    guard configuration.enabled else { throw DoryVirtioQueueError.unconfigured }
    return configuration
  }

  private func readDescriptor(
    _ memory: any DoryVirtioGuestMemory,
    at address: UInt64
  ) throws -> DoryVirtioDescriptor {
    let bytes = try exactRead(memory, at: address, byteCount: 16)
    return .init(
      address: uint64(bytes, at: 0),
      length: uint32(bytes, at: 8),
      flags: uint16(bytes, at: 12),
      next: uint16(bytes, at: 14)
    )
  }

  private func readUInt16(_ memory: any DoryVirtioGuestMemory, at address: UInt64) throws -> UInt16
  {
    uint16(try exactRead(memory, at: address, byteCount: 2), at: 0)
  }

  private func exactRead(
    _ memory: any DoryVirtioGuestMemory,
    at address: UInt64,
    byteCount: Int
  ) throws -> [UInt8] {
    let bytes = try memory.read(at: address, byteCount: byteCount)
    guard bytes.count == byteCount else {
      throw DoryVirtioQueueError.invalidMemoryResponse(expected: byteCount, actual: bytes.count)
    }
    return bytes
  }

  private func checkedAddress(_ address: UInt64, adding offset: UInt64) throws -> UInt64 {
    let (result, overflow) = address.addingReportingOverflow(offset)
    guard !overflow else {
      throw DoryVirtioQueueError.guestAddressOverflow(address: address, offset: offset)
    }
    return result
  }
}

private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
  UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
