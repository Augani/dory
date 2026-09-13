import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioInputTests {
  @Test func publishesKeyboardAndAbsolutePointerCapabilities() throws {
    let keyboard = try DoryVirtioInputDevice(descriptor: .keyboard())
    let name = keyboard.configuration(select: 0x01, subselect: 0)
    #expect(
      String(decoding: name[8..<(8 + Int(name[2]))], as: UTF8.self) == "Dory Virtual Keyboard")
    let keyBits = keyboard.configuration(select: 0x11, subselect: 1)
    #expect(keyBits[2] == 32)
    #expect(keyBits[8 + 30] & (1 << 2) != 0)

    let tablet = try DoryVirtioInputDevice(descriptor: .absolutePointer())
    let propertyBits = tablet.configuration(select: 0x10, subselect: 0)
    #expect(propertyBits[8] & 2 != 0)
    let absoluteX = tablet.configuration(select: 0x12, subselect: 0)
    #expect(read32(absoluteX, 8) == 0)
    #expect(read32(absoluteX, 12) == 32_767)
  }

  @Test func deliversSynchronizedHostEventsIntoPostedBuffers() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    let memory = InputGuestMemory(byteCount: 0x1000)
    #expect(device.enqueueSynchronized([.init(type: 1, code: 30, value: 1)]))
    #expect(device.pendingEventCount == 2)

    let first = try device.processEvent(writableChain(at: 0x100), memory: memory)
    #expect(first == 8)
    #expect(try memory.read(at: 0x100, byteCount: 8) == event(type: 1, code: 30, value: 1))
    _ = try device.processEvent(writableChain(at: 0x200), memory: memory)
    #expect(try memory.read(at: 0x200, byteCount: 8) == event(type: 0, code: 0, value: 0))
    #expect(!device.hasPendingEvent)
  }

  // P2-14: preflight must validate every output descriptor before the first
  // guest write. A valid early segment followed by an invalid later segment
  // must throw without writing any event bytes, and the pending event must
  // remain queued so a later valid chain can deliver it.
  @Test func preflightRejectsInvalidLaterSegmentWithoutPartialWrite() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    let memory = InputGuestMemory(byteCount: 0x1000)
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))
    #expect(device.hasPendingEvent)

    // First segment is valid and large enough to receive partial event bytes
    // if scatter ran; the second segment is out of bounds and must be caught
    // by preflight before any write occurs.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x100, length: 4, flags: 2, next: 0),
        .init(address: 0x2000, length: 8, flags: 2, next: 0),
      ],
      readableByteCount: 0,
      writableByteCount: 12
    )
    #expect(throws: DoryVirtioInputError.self) {
      try device.processEvent(chain, memory: memory)
    }
    // No partial event bytes reached the valid first segment.
    #expect(try memory.read(at: 0x100, byteCount: 4) == [0, 0, 0, 0])
    // The event stays pending for a later valid retry.
    #expect(device.hasPendingEvent)

    let written = try device.processEvent(writableChain(at: 0x100), memory: memory)
    #expect(written == 8)
    #expect(try memory.read(at: 0x100, byteCount: 8) == event(type: 1, code: 30, value: 1))
    #expect(!device.hasPendingEvent)
  }

  // P2-14: a fully valid split descriptor chain still delivers the event across
  // segments and dequeues only after the write succeeds.
  @Test func deliversEventAcrossValidSplitDescriptorChain() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    let memory = InputGuestMemory(byteCount: 0x1000)
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))

    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x100, length: 4, flags: 2, next: 0),
        .init(address: 0x104, length: 4, flags: 2, next: 0),
      ],
      readableByteCount: 0,
      writableByteCount: 8
    )
    let written = try device.processEvent(chain, memory: memory)
    #expect(written == 8)
    #expect(try memory.read(at: 0x100, byteCount: 8) == event(type: 1, code: 30, value: 1))
    #expect(!device.hasPendingEvent)
  }

  @Test func forwardsGuestStatusEventsAndBoundsHostIngress() throws {
    let sink = InputStatusSink()
    let device = try DoryVirtioInputDevice(
      descriptor: .keyboard(),
      maximumPendingEvents: 2,
      statusSink: sink
    )
    #expect(device.enqueue([.init(type: 1, code: 1, value: 1)]))
    #expect(!device.enqueue([.init(type: 1, code: 2, value: 1), .synchronize]))
    #expect(device.droppedEventCount == 2)

    let memory = InputGuestMemory(byteCount: 0x1000)
    memory.put(event(type: 0x11, code: 0, value: 1), at: 0x300)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [.init(address: 0x300, length: 8, flags: 0, next: 0)],
      readableByteCount: 8,
      writableByteCount: 0
    )
    #expect(try device.processStatus(chain, memory: memory) == 0)
    #expect(sink.events == [.init(type: 0x11, code: 0, value: 1)])
  }

  // P2-15: relative pointer motion and wheel events are delivered through the same
  // transport-neutral event pipeline. REL_X (0), REL_Y (1), REL_HWHEEL (6), and
  // REL_WHEEL (8) are advertised in the relative pointer descriptor.
  @Test func deliversRelativePointerMotionAndWheelEvents() throws {
    let device = try DoryVirtioInputDevice(descriptor: .relativePointer())
    let memory = InputGuestMemory(byteCount: 0x1000)

    // Verify the relative pointer advertises REL_X, REL_Y, REL_HWHEEL, REL_WHEEL.
    let relBits = device.configuration(select: 0x11, subselect: 2)
    // Payload starts at offset 8; bitmap covers bits 0-8 (2 bytes).
    #expect(relBits[2] == 2)  // payload size
    #expect(relBits[8] & 1 != 0)  // REL_X (bit 0)
    #expect(relBits[8] & (1 << 1) != 0)  // REL_Y (bit 1)
    #expect(relBits[8] & (1 << 6) != 0)  // REL_HWHEEL (bit 6)
    #expect(relBits[9] & 1 != 0)  // REL_WHEEL (bit 8)

    // Deliver motion + wheel events.
    #expect(device.enqueueSynchronized([
      .init(type: 2, code: 0, value: 10),   // REL_X = 10
      .init(type: 2, code: 1, value: UInt32(bitPattern: -5)),   // REL_Y = -5
      .init(type: 2, code: 8, value: 1),    // REL_WHEEL = 1
    ]))
    #expect(device.pendingEventCount == 4)  // 3 events + SYN

    let first = try device.processEvent(writableChain(at: 0x100), memory: memory)
    #expect(first == 8)
    #expect(try memory.read(at: 0x100, byteCount: 8) == event(type: 2, code: 0, value: 10))
  }

  // P2-15: focus loss must synthesize a release + SYN for every pressed key.
  @Test func releasesPressedKeysOnFocusLoss() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    let memory = InputGuestMemory(byteCount: 0x1000)
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))
    #expect(device.pressedKeyCount == 1)

    // Focus loss enqueues one release for code 30 plus exactly one SYN.
    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 0)
    #expect(device.pendingEventCount == 3)  // key-down + release + SYN

    // First pending event is the original key-down.
    _ = try device.processEvent(writableChain(at: 0x100), memory: memory)
    #expect(try memory.read(at: 0x100, byteCount: 8) == event(type: 1, code: 30, value: 1))

    // Second is the synthesized release (value 0).
    _ = try device.processEvent(writableChain(at: 0x200), memory: memory)
    #expect(try memory.read(at: 0x200, byteCount: 8) == event(type: 1, code: 30, value: 0))

    // Third is the SYN.
    _ = try device.processEvent(writableChain(at: 0x300), memory: memory)
    #expect(try memory.read(at: 0x300, byteCount: 8) == event(type: 0, code: 0, value: 0))
    #expect(!device.hasPendingEvent)
  }

  // P2-15: autorepeat must not duplicate the pressed-key ledger or releases.
  @Test func autorepeatDoesNotDuplicateFocusLossReleases() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))   // key-down
    #expect(device.enqueue([.init(type: 1, code: 30, value: 2)]))  // autorepeat
    #expect(device.pressedKeyCount == 1)  // autorepeat does not add a second entry

    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 0)
    // key-down + autorepeat + one release + one SYN
    #expect(device.pendingEventCount == 4)
  }

  // P2-15: with no keys pressed, focus loss is a no-op that enqueues nothing.
  @Test func focusLossWithNoPressedKeysIsNoOp() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    #expect(device.pressedKeyCount == 0)
    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 0)
    #expect(device.pendingEventCount == 0)
    #expect(!device.hasPendingEvent)
  }

  // P2-15: queue exhaustion must retain the ledger so a later call can retry.
  @Test func focusLossRetriesAfterCapacityFailure() throws {
    let device = try DoryVirtioInputDevice(
      descriptor: .keyboard(),
      maximumPendingEvents: 2
    )
    let memory = InputGuestMemory(byteCount: 0x1000)
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))
    #expect(device.pressedKeyCount == 1)
    #expect(device.pendingEventCount == 1)

    // Release batch needs 2 slots (release + SYN) but only 1 is free.
    #expect(!device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 1)  // ledger retained
    #expect(device.pendingEventCount == 1)  // nothing enqueued

    // Drain the key-down to free capacity, then retry successfully.
    _ = try device.processEvent(writableChain(at: 0x100), memory: memory)
    #expect(device.pendingEventCount == 0)
    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 0)
    #expect(device.pendingEventCount == 2)  // release + SYN

    _ = try device.processEvent(writableChain(at: 0x200), memory: memory)
    #expect(try memory.read(at: 0x200, byteCount: 8) == event(type: 1, code: 30, value: 0))
    _ = try device.processEvent(writableChain(at: 0x300), memory: memory)
    #expect(try memory.read(at: 0x300, byteCount: 8) == event(type: 0, code: 0, value: 0))
    #expect(!device.hasPendingEvent)
  }

  // P2-15: releases are emitted in ascending code order for deterministic output.
  @Test func focusLossReleasesKeysInAscendingOrder() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    let memory = InputGuestMemory(byteCount: 0x1000)
    // Press keys out of order.
    #expect(device.enqueue([
      .init(type: 1, code: 42, value: 1),
      .init(type: 1, code: 1, value: 1),
      .init(type: 1, code: 30, value: 1),
    ]))
    #expect(device.pressedKeyCount == 3)

    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pressedKeyCount == 0)
    // 3 key-downs + 3 releases + 1 SYN
    #expect(device.pendingEventCount == 7)

    // Skip the three key-downs.
    for address in [UInt64(0x100), 0x200, 0x300] {
      _ = try device.processEvent(writableChain(at: address), memory: memory)
    }
    // Releases should arrive ascending: 1, 30, 42.
    _ = try device.processEvent(writableChain(at: 0x400), memory: memory)
    #expect(try memory.read(at: 0x400, byteCount: 8) == event(type: 1, code: 1, value: 0))
    _ = try device.processEvent(writableChain(at: 0x500), memory: memory)
    #expect(try memory.read(at: 0x500, byteCount: 8) == event(type: 1, code: 30, value: 0))
    _ = try device.processEvent(writableChain(at: 0x600), memory: memory)
    #expect(try memory.read(at: 0x600, byteCount: 8) == event(type: 1, code: 42, value: 0))
    _ = try device.processEvent(writableChain(at: 0x700), memory: memory)
    #expect(try memory.read(at: 0x700, byteCount: 8) == event(type: 0, code: 0, value: 0))
    #expect(!device.hasPendingEvent)
  }

  // P2-15: reset clears both queued events and pressed-key state.
  @Test func resetClearsPressedKeyLedger() throws {
    let device = try DoryVirtioInputDevice(descriptor: .keyboard())
    #expect(device.enqueue([.init(type: 1, code: 30, value: 1)]))
    #expect(device.pressedKeyCount == 1)
    #expect(device.pendingEventCount == 1)

    device.reset()
    #expect(device.pressedKeyCount == 0)
    #expect(device.pendingEventCount == 0)

    // After reset, focus loss is a no-op (ledger was cleared).
    #expect(device.releasePressedKeysForFocusLoss())
    #expect(device.pendingEventCount == 0)
  }

  private func writableChain(at address: UInt64) -> DoryVirtioDescriptorChain {
    .init(
      headIndex: 0,
      descriptors: [.init(address: address, length: 8, flags: 2, next: 0)],
      readableByteCount: 0,
      writableByteCount: 8
    )
  }

  private func event(type: UInt16, code: UInt16, value: UInt32) -> [UInt8] {
    littleEndian(type) + littleEndian(code) + littleEndian(value)
  }
}

private final class InputStatusSink: DoryVirtioInputStatusSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DoryVirtioInputEvent] = []
  var events: [DoryVirtioInputEvent] { lock.withLock { storage } }
  func inputDeviceDidReceiveStatus(_ event: DoryVirtioInputEvent) {
    lock.withLock { storage.append(event) }
  }
}

private final class InputGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]

  init(byteCount: Int) { bytes = .init(repeating: 0, count: byteCount) }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try checked(address, byteCount)]) }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    _ = try lock.withLock { try checked(address, byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try lock.withLock { self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes) }
  }

  func synchronize() {}

  func put(_ value: [UInt8], at address: UInt64) {
    lock.withLock {
      bytes.replaceSubrange(Int(address)..<(Int(address) + value.count), with: value)
    }
  }

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioInputError.malformedStatus }
    return Int(address)..<(Int(address) + count)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
