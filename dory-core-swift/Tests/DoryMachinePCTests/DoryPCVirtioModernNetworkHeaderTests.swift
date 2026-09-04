import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

/// Literal wire expectations from VirtIO 1.2 §5.1.6, §5.1.6.1 and §5.1.6.4.1:
/// https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html
/// VERSION_1 always uses twelve bytes; RX num_buffers is one without MRG_RXBUF.
/// The tests negotiate PCI features and submit split rings, rather than invoking
/// the core packet methods directly or deriving lengths from their constants.
@Suite struct DoryPCVirtioModernNetworkHeaderTests {
  @Test func negotiatedTransmitPreservesEntireEthernetFrameAcrossHeaderSplit() throws {
    let fixture = try Fixture(queue: 1)
    let frame = frame()
    try fixture.memory.write(at: 0x4000, bytes: [UInt8](repeating: 0, count: 11))
    try fixture.memory.write(at: 0x5000, bytes: [0] + frame)
    try fixture.post([(0x4000, 11), (0x5000, 1025)], writable: false)

    try fixture.notify()

    #expect(fixture.backend.transmittedFrames == [frame])
    #expect(try fixture.memory.read(at: 0x3002, byteCount: 2) == [1, 0])
    // TX writes no payload, so the used element's length is zero.
    #expect(try fixture.memory.read(at: 0x3004, byteCount: 8) == [UInt8](repeating: 0, count: 8))
    #expect(try fixture.network.readBAR(offset: 0x14, byteCount: 1) == [15])
  }

  @Test func negotiatedReceiveIncludesOneBufferAndExactUsedLengthAcrossHeaderSplit() throws {
    let fixture = try Fixture(queue: 0)
    let frame = frame()
    try fixture.memory.write(at: 0x4000, bytes: [UInt8](repeating: 0xA5, count: 12))
    try fixture.memory.write(at: 0x5000, bytes: [UInt8](repeating: 0xA5, count: 1026))
    try fixture.post([(0x4000, 11), (0x5000, 1025)], writable: true)
    try fixture.notify()
    #expect(try fixture.memory.read(at: 0x3002, byteCount: 2) == [0, 0])

    fixture.backend.injectReceivedFrame(frame)

    #expect(try fixture.memory.read(at: 0x4000, byteCount: 12) == [UInt8](repeating: 0, count: 10) + [1, 0xA5])
    #expect(try fixture.memory.read(at: 0x5000, byteCount: 1026) == [0] + frame + [0xA5])
    #expect(try fixture.memory.read(at: 0x3002, byteCount: 2) == [1, 0])
    // One descriptor chain completed, with 12 + 1024 bytes, not one completion
    // per scatter element. 1036 is 0x040c in the little-endian used ring.
    #expect(try fixture.memory.read(at: 0x3004, byteCount: 8) == [0, 0, 0, 0, 12, 4, 0, 0])
    #expect(fixture.network.networkDevice.pendingReceiveCount == 0)
    #expect(fixture.network.networkDevice.droppedReceiveCount == 0)
  }

  @Test func negotiatedReceiveRejectsLegacySizedBufferBeforeWritingPayload() throws {
    let fixture = try Fixture(queue: 0)
    let sentinel = [UInt8](repeating: 0xA5, count: 1034)
    try fixture.memory.write(at: 0x4000, bytes: sentinel)
    try fixture.post([(0x4000, 1034)], writable: true)
    try fixture.notify()

    fixture.backend.injectReceivedFrame(frame())

    #expect(try fixture.memory.read(at: 0x4000, byteCount: 1034) == sentinel)
    #expect(try fixture.memory.read(at: 0x3000, byteCount: 12) == [UInt8](repeating: 0, count: 12))
    #expect(try fixture.network.readBAR(offset: 0x14, byteCount: 1) == [15 | 64])
    #expect(fixture.network.networkDevice.pendingReceiveCount == 1)
    #expect(fixture.network.networkDevice.droppedReceiveCount == 0)
  }

  @Test func malformedModernTransmitDoesNotReachBackendOrCompleteUsedRing() throws {
    let frame = frame()
    let cases: [[UInt8]] = [
      [UInt8](repeating: 0, count: 10), // Truncated modern header.
      [UInt8](repeating: 0, count: 10) + [1, 0] + frame, // TX num_buffers must be zero.
      [UInt8](repeating: 0, count: 10) + Array(frame.prefix(14)),
    ]
    // The last case is a minimum Ethernet header with the stale ten-byte format:
    // modern framing leaves fewer than fourteen bytes. Longer legacy-shaped data
    // is not guessed from its payload; there is no content-based format heuristic.
    for bytes in cases {
      let fixture = try Fixture(queue: 1)
      try fixture.memory.write(at: 0x4000, bytes: bytes)
      try fixture.post([(0x4000, UInt32(bytes.count))], writable: false)

      try fixture.notify()

      #expect(fixture.backend.transmittedFrames.isEmpty)
      #expect(try fixture.memory.read(at: 0x4000, byteCount: bytes.count) == bytes)
      #expect(try fixture.memory.read(at: 0x3000, byteCount: 12) == [UInt8](repeating: 0, count: 12))
      #expect(try fixture.network.readBAR(offset: 0x14, byteCount: 1) == [15 | 64])
    }
  }

  private func frame() -> [UInt8] {
    [2, 0xD0, 0x52, 0, 0, 2, 2, 0xD0, 0x52, 0, 0, 1, 0x88, 0xB5]
      + (0..<1010).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 >> 8)) }
  }

  private struct Fixture {
    let memory = ModernNetworkMemory()
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network: DoryPCVirtioNetworkPCIDevice
    let queue: UInt16

    init(queue: UInt16) throws {
      self.queue = queue
      network = try .init(address: .init(bus: 0, device: 4, function: 0),
        initialBARAddress: 0xD000_2000, backend: backend, macAddress: [2, 0xD0, 0x52, 0, 0, 1])
      network.connectGuestMemory(memory)
      try network.writeBAR(offset: 0x14, bytes: [1])
      try network.writeBAR(offset: 0x14, bytes: [3])
      // Negotiate VERSION_1 and only MTU/MAC/status. MRG_RXBUF remains absent.
      try network.writeBAR(offset: 0x00, bytes: le(UInt32(1)))
      #expect(try network.readBAR(offset: 0x04, byteCount: 4) == [1, 0, 0, 0])
      try network.writeBAR(offset: 0x08, bytes: le(UInt32(0)))
      try network.writeBAR(offset: 0x0C, bytes: le(UInt32(0x1_0028)))
      try network.writeBAR(offset: 0x08, bytes: le(UInt32(1)))
      try network.writeBAR(offset: 0x0C, bytes: le(UInt32(1)))
      try network.writeBAR(offset: 0x14, bytes: [11])
      #expect(try network.readBAR(offset: 0x14, byteCount: 1) == [11])
      try network.writeBAR(offset: 0x16, bytes: le(queue))
      try network.writeBAR(offset: 0x18, bytes: le(UInt16(8)))
      try network.writeBAR(offset: 0x20, bytes: le(UInt64(0x1000)))
      try network.writeBAR(offset: 0x28, bytes: le(UInt64(0x2000)))
      try network.writeBAR(offset: 0x30, bytes: le(UInt64(0x3000)))
      try network.writeBAR(offset: 0x1C, bytes: le(UInt16(1)))
      try network.writeBAR(offset: 0x14, bytes: [15])
      #expect(try network.readBAR(offset: 0x14, byteCount: 1) == [15])
    }

    func post(_ buffers: [(UInt64, UInt32)], writable: Bool) throws {
      for (index, buffer) in buffers.enumerated() {
        let hasNext = index + 1 < buffers.count
        let flags: UInt16 = (writable ? 2 : 0) | (hasNext ? 1 : 0)
        try memory.write(at: 0x1000 + UInt64(index * 16),
          bytes: le(buffer.0) + le(buffer.1) + le(flags) + le(UInt16(hasNext ? index + 1 : 0)))
      }
      try memory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])
    }

    func notify() throws {
      try network.writeBAR(offset: 0x100 + UInt64(queue) * 4, bytes: le(queue))
    }
  }
}

private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private final class ModernNetworkMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = [UInt8](repeating: 0, count: 64 << 10)

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

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioNetworkError.invalidFrameLength(count) }
    return Int(address)..<(Int(address) + count)
  }
}
