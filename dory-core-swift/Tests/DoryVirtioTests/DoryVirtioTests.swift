import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioDeviceTests {
  @Test func negotiatesOnlyOfferedFeaturesAndEnforcesStatusOrder() {
    let resets = LockedCounter()
    let device = DoryVirtioDeviceState(
      offeredFeatures: [.indirectDescriptors, .eventIndex],
      onReset: { resets.increment() }
    )

    device.writeDriverFeatures(page: 0, value: UInt32(1 << 28) | UInt32(1 << 29))
    device.writeDriverFeatures(page: 1, value: 1)
    device.writeStatus([.acknowledge, .driver, .featuresOK, .driverOK])
    #expect(device.snapshot().status.contains(.driverOK))
    #expect(device.snapshot().negotiatedFeatures.contains(.version1))
    device.writeDriverFeatures(page: 0, value: 0)
    #expect(device.snapshot().negotiatedFeatures.contains(.indirectDescriptors))

    device.writeStatus([])
    #expect(device.snapshot().status.isEmpty)
    #expect(resets.value == 1)

    device.writeDriverFeatures(page: 1, value: UInt32(1 | 1 << 2))
    device.writeStatus([.acknowledge, .driver, .featuresOK, .driverOK])
    #expect(!device.snapshot().status.contains(.featuresOK))
    #expect(!device.snapshot().status.contains(.driverOK))
  }
}

@Suite struct DoryVirtioSplitQueueTests {
  @Test func validatesPopsAndCompletesAReadableWritableChain() throws {
    let memory = TestVirtioMemory(byteCount: 0x4000)
    let queue = DoryVirtioSplitQueue(maximumSize: 8)
    try queue.configure(
      size: 8,
      descriptorAddress: 0x100,
      driverAddress: 0x200,
      deviceAddress: 0x300,
      enabled: true
    )
    memory.writeDescriptor(at: 0x100, address: 0x1000, length: 16, flags: 1, next: 1)
    memory.writeDescriptor(at: 0x110, address: 0x2000, length: 32, flags: 2, next: 0)
    memory.put(UInt16(0), at: 0x204)
    memory.put(UInt16(1), at: 0x202)

    let availableChain = try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    let chain = try #require(availableChain)
    #expect(chain.headIndex == 0)
    #expect(chain.readableByteCount == 16)
    #expect(chain.writableByteCount == 32)
    #expect(queue.snapshot().outstandingHeads == [0])

    #expect(
      try queue.complete(chain, bytesWritten: 12, memory: memory, eventIndexNegotiated: false))
    #expect(memory.get(UInt32.self, at: 0x304) == 0)
    #expect(memory.get(UInt32.self, at: 0x308) == 12)
    #expect(memory.get(UInt16.self, at: 0x302) == 1)
    #expect(memory.synchronizationCount == 2)
  }

  @Test func rejectsCyclesOutOfRangeHeadsAndExcessAvailability() throws {
    let memory = TestVirtioMemory(byteCount: 0x1000)
    let queue = DoryVirtioSplitQueue(maximumSize: 8)
    try queue.configure(
      size: 2,
      descriptorAddress: 0x100,
      driverAddress: 0x200,
      deviceAddress: 0x300,
      enabled: true
    )
    memory.writeDescriptor(at: 0x100, address: 0x400, length: 1, flags: 1, next: 0)
    memory.put(UInt16(0), at: 0x204)
    memory.put(UInt16(1), at: 0x202)
    #expect(throws: DoryVirtioQueueError.descriptorCycle(0)) {
      try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    }

    memory.put(UInt16(3), at: 0x202)
    #expect(throws: DoryVirtioQueueError.availableIndexAdvancedTooFar(delta: 3, queueSize: 2)) {
      try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    }
  }

  @Test func parsesNegotiatedIndirectTablesAndCapsTotalBytes() throws {
    let memory = TestVirtioMemory(byteCount: 0x4000)
    let queue = DoryVirtioSplitQueue(maximumSize: 8, maximumChainBytes: 32)
    try queue.configure(
      size: 8,
      descriptorAddress: 0x100,
      driverAddress: 0x200,
      deviceAddress: 0x300,
      enabled: true
    )
    memory.writeDescriptor(at: 0x100, address: 0x500, length: 32, flags: 4, next: 0)
    memory.writeDescriptor(at: 0x500, address: 0x1000, length: 16, flags: 1, next: 1)
    memory.writeDescriptor(at: 0x510, address: 0x2000, length: 16, flags: 2, next: 0)
    memory.put(UInt16(0), at: 0x204)
    memory.put(UInt16(1), at: 0x202)

    let availableChain = try queue.popAvailable(memory: memory, allowIndirectDescriptors: true)
    let chain = try #require(availableChain)
    #expect(chain.descriptors.count == 2)

    queue.reset()
    try queue.configure(
      size: 8,
      descriptorAddress: 0x100,
      driverAddress: 0x200,
      deviceAddress: 0x300,
      enabled: true
    )
    memory.writeDescriptor(at: 0x500, address: 0x1000, length: 17, flags: 1, next: 1)
    memory.put(UInt16(1), at: 0x202)
    #expect(throws: DoryVirtioQueueError.descriptorBudgetExceeded(33)) {
      try queue.popAvailable(memory: memory, allowIndirectDescriptors: true)
    }
  }

  @Test func honorsLegacyAndEventIndexInterruptSuppression() throws {
    let memory = TestVirtioMemory(byteCount: 0x1000)
    let queue = DoryVirtioSplitQueue(maximumSize: 8)
    try queue.configure(
      size: 2,
      descriptorAddress: 0x100,
      driverAddress: 0x200,
      deviceAddress: 0x300,
      enabled: true
    )
    memory.writeDescriptor(at: 0x100, address: 0x400, length: 1, flags: 2, next: 0)
    memory.put(UInt16(1), at: 0x200)
    memory.put(UInt16(0), at: 0x204)
    memory.put(UInt16(1), at: 0x202)
    let firstAvailable = try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    let first = try #require(firstAvailable)
    let notifyFirst = try queue.complete(
      first,
      bytesWritten: 1,
      memory: memory,
      eventIndexNegotiated: false
    )
    #expect(!notifyFirst)

    memory.put(UInt16(0), at: 0x200)
    memory.put(UInt16(1), at: 0x208)
    memory.put(UInt16(0), at: 0x206)
    memory.put(UInt16(2), at: 0x202)
    let secondAvailable = try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    let second = try #require(secondAvailable)
    #expect(try queue.complete(second, bytesWritten: 1, memory: memory, eventIndexNegotiated: true))
  }

  @Test func rejectsMisalignedAndOverflowingQueueAddresses() throws {
    let queue = DoryVirtioSplitQueue(maximumSize: 8)
    #expect(
      throws: DoryVirtioQueueError.invalidQueueAlignment(
        descriptor: 1,
        driver: 2,
        device: 4
      )
    ) {
      try queue.configure(
        size: 2,
        descriptorAddress: 1,
        driverAddress: 2,
        deviceAddress: 4,
        enabled: true
      )
    }

    try queue.configure(
      size: 2,
      descriptorAddress: 0,
      driverAddress: UInt64.max - 1,
      deviceAddress: 0,
      enabled: true
    )
    let memory = TestVirtioMemory(byteCount: 0x1000)
    #expect(
      throws: DoryVirtioQueueError.guestAddressOverflow(
        address: UInt64.max - 1,
        offset: 2
      )
    ) {
      try queue.popAvailable(memory: memory, allowIndirectDescriptors: false)
    }
  }
}

private final class TestVirtioMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]
  private var syncCount = 0

  init(byteCount: Int) { bytes = .init(repeating: 0, count: byteCount) }

  var synchronizationCount: Int { lock.withLock { syncCount } }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock {
      let range = try checkedRange(address, byteCount)
      return Array(bytes[range])
    }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    _ = try lock.withLock { try checkedRange(address, byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try lock.withLock {
      let range = try checkedRange(address, bytes.count)
      self.bytes.replaceSubrange(range, with: bytes)
    }
  }

  func synchronize() { lock.withLock { syncCount += 1 } }

  func put<T: FixedWidthInteger>(_ value: T, at address: UInt64) {
    lock.withLock {
      for index in 0..<MemoryLayout<T>.size {
        bytes[Int(address) + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
      }
    }
  }

  func get<T: FixedWidthInteger>(_ type: T.Type, at address: UInt64) -> T {
    lock.withLock {
      (0..<MemoryLayout<T>.size).reduce(0) {
        $0 | T(bytes[Int(address) + $1]) << T($1 * 8)
      }
    }
  }

  func writeDescriptor(
    at address: UInt64,
    address guestAddress: UInt64,
    length: UInt32,
    flags: UInt16,
    next: UInt16
  ) {
    put(guestAddress, at: address)
    put(length, at: address + 8)
    put(flags, at: address + 12)
    put(next, at: address + 14)
  }

  private func checkedRange(_ address: UInt64, _ byteCount: Int) throws -> Range<Int> {
    guard byteCount >= 0, address <= UInt64(bytes.count),
      UInt64(byteCount) <= UInt64(bytes.count) - address
    else {
      throw TestMemoryError.outOfRange
    }
    return Int(address)..<(Int(address) + byteCount)
  }
}

private enum TestMemoryError: Error { case outOfRange }

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int { lock.withLock { storage } }
  func increment() { lock.withLock { storage += 1 } }
}
