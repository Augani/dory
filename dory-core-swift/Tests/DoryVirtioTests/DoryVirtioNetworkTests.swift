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
    memory.put([UInt8](repeating: 0, count: 12) + Array(frame.prefix(20)), at: 0x100)
    memory.put(Array(frame.dropFirst(20)), at: 0x200)

    let transmit = chain([
      descriptor(0x100, 32, writable: false),
      descriptor(0x200, UInt32(frame.count - 20), writable: false),
    ])
    #expect(try device.processTransmit(transmit, memory: memory) == 0)
    #expect(backend.transmittedFrames == [frame])

    backend.injectReceivedFrame(frame)
    let receive = chain([
      descriptor(0x400, 32, writable: true),
      descriptor(0x500, 128, writable: true),
    ])
    #expect(try device.processReceive(receive, memory: memory) == UInt32(12 + frame.count))
    #expect(try memory.read(at: 0x400, byteCount: 12) == [UInt8](repeating: 0, count: 10) + [1, 0])
    let firstFramePart = try memory.read(at: 0x40C, byteCount: 20)
    let secondFramePart = try memory.read(at: 0x500, byteCount: frame.count - 20)
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

    #expect(throws: DoryVirtioNetworkError.receiveBufferTooSmall(required: 72, available: 71)) {
      try device.processReceive(
        chain([descriptor(0x100, 71, writable: true)]),
        memory: memory
      )
    }
    #expect(device.pendingReceiveCount == 1)

    memory.put([1] + [UInt8](repeating: 0, count: 11) + frame, at: 0x200)
    #expect(throws: DoryVirtioNetworkError.malformedHeader) {
      try device.processTransmit(
        chain([descriptor(0x200, UInt32(12 + frame.count), writable: false)]),
        memory: memory
      )
    }
    #expect(backend.transmittedFrames.isEmpty)
  }

  @Test func resetDropsPendingReceiveFramesWithoutDeliveringThem() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let device = try DoryVirtioNetworkDevice(
      backend: backend,
      macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let memory = NetworkGuestMemory(byteCount: 0x1000)
    let frame = ethernetFrame(payloadByte: 0x77, count: 64)
    #expect(device.receive(frame: frame))
    #expect(device.pendingReceiveCount == 1)
    #expect(device.canReceive)

    device.reset()

    #expect(device.pendingReceiveCount == 0)
    #expect(!device.canReceive)
    #expect(throws: DoryVirtioNetworkError.noReceivedFrame) {
      try device.processReceive(
        chain([descriptor(0x100, 128, writable: true)]),
        memory: memory
      )
    }
    // Link state and diagnostic history are preserved across reset.
    #expect(device.droppedReceiveCount == 0)
    let statusBytes = device.configuration
    #expect(statusBytes[6] == 1)
  }

  @Test func oversizedTransmitIsRejectedBeforeAnyGuestMemoryRead() throws {
    let device = try DoryVirtioNetworkDevice(
      backend: DoryVirtioInMemoryNetworkBackend(), macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let memory = NetworkAccessCountingMemory()
    #expect(throws: DoryVirtioNetworkError.invalidFrameLength(Int(UInt32.max))) {
      try device.processTransmit(
        chain([descriptor(0, UInt32.max, writable: false)]), memory: memory
      )
    }
    #expect(memory.accessCount == 0)
  }

  @Test func resetJoinsSelectedDMAAndDoesNotConsumeIdenticalSuccessorFrame() throws {
    let device = try DoryVirtioNetworkDevice(
      backend: DoryVirtioInMemoryNetworkBackend(), macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let frame = ethernetFrame(payloadByte: 0x42, count: 64)
    let memory = NetworkBlockingWriteMemory()
    let receiveChain = chain([descriptor(0, 128, writable: true)])
    #expect(device.receive(frame: frame))
    let receiveFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? device.processReceive(receiveChain, memory: memory)
      receiveFinished.signal()
    }
    defer { memory.release.signal() }
    #expect(memory.entered.wait(timeout: .now() + 1) == .success)
    let resetFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      device.reset()
      resetFinished.signal()
    }
    let deadline = Date().addingTimeInterval(1)
    while device.pendingReceiveCount != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    #expect(device.pendingReceiveCount == 0)
    #expect(resetFinished.wait(timeout: .now() + 0.02) == .timedOut)
    #expect(device.receive(frame: frame))
    memory.release.signal()
    #expect(receiveFinished.wait(timeout: .now() + 1) == .success)
    #expect(resetFinished.wait(timeout: .now() + 1) == .success)
    #expect(device.pendingReceiveCount == 1)
  }

  @Test func everyStopCallerJoinsDMAAndPermanentRetirementRejectsLateWork() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let device = try DoryVirtioNetworkDevice(
      backend: backend, macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let memory = NetworkBlockingWriteMemory()
    let receiveChain = chain([descriptor(0, 128, writable: true)])
    #expect(device.receive(frame: ethernetFrame(payloadByte: 1, count: 64)))
    let receiveFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? device.processReceive(receiveChain, memory: memory)
      receiveFinished.signal()
    }
    defer { memory.release.signal() }
    #expect(memory.entered.wait(timeout: .now() + 1) == .success)
    let stopFinished = DispatchSemaphore(value: 0)
    for _ in 0..<2 {
      DispatchQueue.global().async { device.stop(); stopFinished.signal() }
    }
    let deadline = Date().addingTimeInterval(1)
    while !device.isStopped, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    #expect(device.isStopped)
    #expect(stopFinished.wait(timeout: .now() + 0.02) == .timedOut)
    memory.release.signal()
    #expect(receiveFinished.wait(timeout: .now() + 1) == .success)
    #expect(stopFinished.wait(timeout: .now() + 1) == .success)
    #expect(stopFinished.wait(timeout: .now() + 1) == .success)

    backend.injectReceivedFrame(ethernetFrame(payloadByte: 2, count: 64))
    #expect(!device.setLinkUp(true))
    device.reset()
    #expect(device.pendingReceiveCount == 0)
    #expect(device.configuration[6] == 0)
    let inaccessible = NetworkAccessCountingMemory()
    #expect(throws: DoryVirtioNetworkError.deviceStopped) {
      try device.processReceive(receiveChain, memory: inaccessible)
    }
    #expect(throws: DoryVirtioNetworkError.deviceStopped) {
      try device.processTransmit(chain([descriptor(0, 64, writable: false)]), memory: inaccessible)
    }
    #expect(inaccessible.accessCount == 0)
  }

  @Test func linkLossPurgesIngressAndRejectsTransmitBeforeMemoryAccess() throws {
    let device = try DoryVirtioNetworkDevice(
      backend: DoryVirtioInMemoryNetworkBackend(), macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    #expect(device.receive(frame: ethernetFrame(payloadByte: 1, count: 64)))
    #expect(device.setLinkUp(false))
    #expect(device.pendingReceiveCount == 0)
    #expect(!device.receive(frame: ethernetFrame(payloadByte: 2, count: 64)))
    let memory = NetworkAccessCountingMemory()
    #expect(throws: DoryVirtioNetworkError.linkDown) {
      try device.processTransmit(chain([descriptor(0, 64, writable: false)]), memory: memory)
    }
    #expect(memory.accessCount == 0)
    #expect(device.setLinkUp(true))
    #expect(device.receive(frame: ethernetFrame(payloadByte: 3, count: 64)))
  }

  @Test func stopJoinsReceiveReadyNotificationAndRejectsLateCallback() throws {
    let device = try DoryVirtioNetworkDevice(
      backend: DoryVirtioInMemoryNetworkBackend(), macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let receiveFinished = DispatchSemaphore(value: 0)
    device.connectReceiveReadySink {
      entered.signal()
      #expect(release.wait(timeout: .now() + 2) == .success)
    }
    let frame = ethernetFrame(payloadByte: 1, count: 64)
    DispatchQueue.global().async {
      _ = device.receive(frame: frame)
      receiveFinished.signal()
    }
    defer { release.signal() }
    #expect(entered.wait(timeout: .now() + 1) == .success)
    let stopped = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { device.stop(); stopped.signal() }
    #expect(stopped.wait(timeout: .now() + 0.02) == .timedOut)
    release.signal()
    #expect(receiveFinished.wait(timeout: .now() + 1) == .success)
    #expect(stopped.wait(timeout: .now() + 1) == .success)
    #expect(!device.receive(frame: frame))
    #expect(entered.wait(timeout: .now() + 0.02) == .timedOut)
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

private final class NetworkAccessCountingMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var accesses = 0
  var accessCount: Int { lock.withLock { accesses } }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    lock.withLock { accesses += 1 }
    throw DoryVirtioNetworkError.malformedHeader
  }
  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    lock.withLock { accesses += 1 }
  }
  func write(at address: UInt64, bytes: [UInt8]) throws { lock.withLock { accesses += 1 } }
  func synchronize() {}
}

private final class NetworkBlockingWriteMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] { [] }
  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {}
  func write(at address: UInt64, bytes: [UInt8]) throws {
    entered.signal()
    guard release.wait(timeout: .now() + 2) == .success else {
      throw DoryVirtioNetworkError.malformedHeader
    }
  }
  func synchronize() {}
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
