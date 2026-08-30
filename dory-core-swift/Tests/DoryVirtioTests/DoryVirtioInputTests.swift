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
