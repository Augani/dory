import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioNetworkTests {
  @Test func transmitsAndReceivesScatterGatherEthernetFrames() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let device = try DoryVirtioNetworkDevice(
      backend: backend,
      macAddress: [0x02, 0, 0, 0, 0, 1],
      mtu: 1500
    )
    let memory = NetworkGuestMemory(byteCount: 0x1000)
    let frame = ethernetFrame(payloadByte: 0x5A, count: 64)
    memory.put([UInt8](repeating: 0, count: 10) + Array(frame.prefix(20)), at: 0x100)
    memory.put(Array(frame.dropFirst(20)), at: 0x200)

    let transmit = chain([
      descriptor(0x100, 30, writable: false),
      descriptor(0x200, UInt32(frame.count - 20), writable: false),
    ])
    #expect(try device.processTransmit(transmit, memory: memory) == 0)
    #expect(backend.transmittedFrames == [frame])

    backend.injectReceivedFrame(frame)
    let receive = chain([
      descriptor(0x400, 32, writable: true),
      descriptor(0x500, 128, writable: true),
    ])
    #expect(try device.processReceive(receive, memory: memory) == UInt32(10 + frame.count))
    #expect(try memory.read(at: 0x400, byteCount: 10) == [UInt8](repeating: 0, count: 10))
    let firstFramePart = try memory.read(at: 0x40A, byteCount: 22)
    let secondFramePart = try memory.read(at: 0x500, byteCount: frame.count - 22)
    #expect(firstFramePart + secondFramePart == frame)
    #expect(device.pendingReceiveCount == 0)
  }

  @Test func boundsIngressAndRejectsOffloadsAndUndersizedReceiveBuffers() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let device = try DoryVirtioNetworkDevice(
      backend: backend,
      macAddress: [0x02, 1, 2, 3, 4, 5],
      maximumPendingReceiveFrames: 1
    )
    let memory = NetworkGuestMemory(byteCount: 0x1000)
    let frame = ethernetFrame(payloadByte: 1, count: 60)
    #expect(device.receive(frame: frame))
    #expect(!device.receive(frame: frame))
    #expect(device.droppedReceiveCount == 1)

    #expect(throws: DoryVirtioNetworkError.receiveBufferTooSmall(required: 70, available: 69)) {
      try device.processReceive(
        chain([descriptor(0x100, 69, writable: true)]),
        memory: memory
      )
    }
    #expect(device.pendingReceiveCount == 1)

    memory.put([1] + [UInt8](repeating: 0, count: 9) + frame, at: 0x200)
    #expect(throws: DoryVirtioNetworkError.malformedHeader) {
      try device.processTransmit(
        chain([descriptor(0x200, UInt32(10 + frame.count), writable: false)]),
        memory: memory
      )
    }
    #expect(backend.transmittedFrames.isEmpty)
  }

  private func descriptor(
    _ address: UInt64,
    _ length: UInt32,
    writable: Bool
  ) -> DoryVirtioDescriptor {
    .init(address: address, length: length, flags: writable ? 2 : 0, next: 0)
  }

  private func chain(_ descriptors: [DoryVirtioDescriptor]) -> DoryVirtioDescriptorChain {
    .init(
      headIndex: 0,
      descriptors: descriptors,
      readableByteCount: descriptors.filter { !$0.deviceWillWrite }.reduce(0) {
        $0 + UInt64($1.length)
      },
      writableByteCount: descriptors.filter(\.deviceWillWrite).reduce(0) {
        $0 + UInt64($1.length)
      }
    )
  }

  private func ethernetFrame(payloadByte: UInt8, count: Int) -> [UInt8] {
    precondition(count >= 14)
    return [
      0x02, 0, 0, 0, 0, 1,
      0x02, 0, 0, 0, 0, 2,
      0x08, 0x00,
    ] + [UInt8](repeating: payloadByte, count: count - 14)
  }
}

private final class NetworkGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
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
    try lock.withLock {
      self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes)
    }
  }

  func synchronize() {}

  func put(_ value: [UInt8], at address: UInt64) {
    lock.withLock {
      bytes.replaceSubrange(Int(address)..<(Int(address) + value.count), with: value)
    }
  }

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioNetworkError.invalidFrameLength(count) }
    return Int(address)..<(Int(address) + count)
  }
}
