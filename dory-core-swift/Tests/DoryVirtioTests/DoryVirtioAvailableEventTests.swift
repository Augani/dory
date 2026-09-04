import DoryVirtio
import Testing

// VirtIO 1.2 sections 2.7.10 and 2.7.13, with the driver's notification
// decision from Linux v6.18.35 virtio_ring.h/virtqueue_kick_prepare_split.
// https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html
@Suite struct DoryVirtioAvailableEventTests {
  @Test func eventThresholdRequestsEachSuccessiveEntryAcrossIndexWrap() throws {
    let memory = AvailableEventMemory()
    let queue = try makeQueue(memory)
    var index: UInt16 = 0
    var allKicks = true
    var allCompletions = true
    var thresholds: [UInt16] = []
    // Reach the architectural wrap through real pops/completions, with one
    // outstanding one-byte buffer and constant bounded memory, no test hook.
    for iteration in 0..<65_538 {
      let next = index &+ 1
      memory.put16(0, at: 0x204 + Int(index % 2) * 2)
      memory.put16(next, at: 0x202)
      memory.put16(index, at: 0x208) // Driver asks for this completion.
      let event = memory.get16(at: 0x314)
      allKicks = allKicks && (next &- event &- 1) < (next &- index)
      guard let chain = try queue.popAvailable(memory: memory, allowIndirectDescriptors: false,
        eventIndexNegotiated: true) else {
        Issue.record("Available buffer disappeared at iteration \(iteration)")
        return
      }
      let notify = try queue.complete(chain, bytesWritten: 1, memory: memory, eventIndexNegotiated: true)
      allCompletions = allCompletions && notify && memory.get16(at: 0x302) == next
      if iteration >= 65_534 { thresholds.append(memory.get16(at: 0x314)) }
      index = next
    }
    #expect(allKicks && allCompletions)
    #expect(thresholds == [65_535, 0, 1, 2])
    #expect(queue.snapshot().lastAvailableIndex == 2 && queue.snapshot().lastUsedIndex == 2)
    #expect(queue.snapshot().outstandingHeads.isEmpty)
    #expect(memory.get16(at: 0x300) == 0)
  }

  @Test func idleRearmRechecksWorkPublishedAtTheNotificationBarrier() throws {
    let memory = AvailableEventMemory()
    let queue = try makeQueue(memory)
    // Model stale suppression while the device has no current work. The
    // producer publishes between the empty observation and final idle check.
    memory.put16(0xFFFF, at: 0x314)
    memory.onNextSynchronization = {
      memory.put16(0, at: 0x204)
      memory.put16(1, at: 0x202)
    }
    let chain = try #require(try queue.popAvailable(memory: memory, allowIndirectDescriptors: false,
      eventIndexNegotiated: true))
    #expect(chain.headIndex == 0 && queue.snapshot().lastAvailableIndex == 1)
    #expect(memory.get16(at: 0x314) == 1)
    #expect(try queue.complete(chain, bytesWritten: 1, memory: memory, eventIndexNegotiated: true))
    #expect(try queue.popAvailable(memory: memory, allowIndirectDescriptors: false,
      eventIndexNegotiated: true) == nil)
    #expect(memory.get16(at: 0x314) == 1 && memory.get16(at: 0x302) == 1)
  }

  @Test func eventWriteFailureDoesNotConsumeHeadOrPublishPartialNotificationState() throws {
    for available: UInt16 in [0, 1] {
      let memory = AvailableEventMemory()
      let queue = try makeQueue(memory)
      memory.put16(available, at: 0x202)
      memory.put16(0xABCD, at: 0x300)
      memory.put16(0x1234, at: 0x314)
      memory.rejectEventWrites = true
      let before = queue.snapshot()
      #expect(throws: AvailableEventMemory.Error.denied) {
        try queue.popAvailable(memory: memory, allowIndirectDescriptors: false, eventIndexNegotiated: true)
      }
      #expect(queue.snapshot() == before)
      #expect(memory.get16(at: 0x300) == 0xABCD && memory.get16(at: 0x314) == 0x1234)
      #expect(memory.writeCount == 0 && memory.synchronizations == 0)
    }
  }

  @Test func eventIndexDisabledNeverAccessesTheOptionalUsedRingTail() throws {
    let memory = AvailableEventMemory()
    let queue = try makeQueue(memory)
    memory.put16(0x4321, at: 0x314)
    memory.rejectEventWrites = true
    for index: UInt16 in 0..<3 {
      memory.put16(0, at: 0x204 + Int(index % 2) * 2)
      memory.put16(index + 1, at: 0x202)
      let chain = try #require(try queue.popAvailable(memory: memory, allowIndirectDescriptors: false))
      #expect(try queue.complete(chain, bytesWritten: 1, memory: memory, eventIndexNegotiated: false))
    }
    #expect(try queue.popAvailable(memory: memory, allowIndirectDescriptors: false) == nil)
    #expect(memory.get16(at: 0x314) == 0x4321 && memory.get16(at: 0x302) == 3)
    #expect(memory.eventAccesses == 0)
  }

  private func makeQueue(_ memory: AvailableEventMemory) throws -> DoryVirtioSplitQueue {
    let queue = DoryVirtioSplitQueue(maximumSize: 2)
    try queue.configure(size: 2, descriptorAddress: 0x100, driverAddress: 0x200,
      deviceAddress: 0x300, enabled: true)
    // Descriptor 0: one writable byte at 0x400, no NEXT. The other descriptor
    // is unused and the driver reuses head zero only after each completion.
    memory.put64(0x400, at: 0x100)
    memory.put32(1, at: 0x108)
    memory.put16(2, at: 0x10C)
    return queue
  }
}

private final class AvailableEventMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  enum Error: Swift.Error, Equatable { case denied }
  private var bytes = [UInt8](repeating: 0, count: 0x800)
  var rejectEventWrites = false
  var onNextSynchronization: (() -> Void)?
  private(set) var writeCount = 0
  private(set) var synchronizations = 0
  private(set) var eventAccesses = 0

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validate(at: address, byteCount: byteCount, deviceWillWrite: false)
    return Array(bytes[Int(address)..<(Int(address) + byteCount)])
  }
  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    guard byteCount >= 0, address <= UInt64(bytes.count), UInt64(byteCount) <= UInt64(bytes.count) - address
      else { throw Error.denied }
    if address <= 0x315 && address + UInt64(byteCount) > 0x314 {
      eventAccesses += 1
      if rejectEventWrites && deviceWillWrite { throw Error.denied }
    }
  }
  func write(at address: UInt64, bytes source: [UInt8]) throws {
    try validate(at: address, byteCount: source.count, deviceWillWrite: true)
    bytes.replaceSubrange(Int(address)..<(Int(address) + source.count), with: source)
    writeCount += 1
  }
  func synchronize() {
    synchronizations += 1
    let callback = onNextSynchronization
    onNextSynchronization = nil
    callback?()
  }
  func put16(_ value: UInt16, at offset: Int) { put(value, at: offset) }
  func put32(_ value: UInt32, at offset: Int) { put(value, at: offset) }
  func put64(_ value: UInt64, at offset: Int) { put(value, at: offset) }
  func get16(at offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
  private func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
