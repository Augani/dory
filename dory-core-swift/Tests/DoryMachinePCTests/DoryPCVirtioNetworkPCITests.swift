import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioNetworkPCITests {
  @Test func hostFrameWakesPostedReceiveQueueAndRaisesMSI() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network = try DoryPCVirtioNetworkPCIDevice(
      address: .init(bus: 0, device: 4, function: 0),
      initialBARAddress: 0xD000_2000,
      backend: backend,
      macAddress: [0x02, 0xD0, 0x52, 0, 0, 1]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [network]
    )
    try network.writeConfiguration(offset: 4, bytes: [2, 0])
    try network.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try network.writeConfiguration(offset: 0x5C, bytes: [0x76, 0])
    try network.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar: UInt64 = 0xD000_2000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(2048))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)

    let frame = ethernetFrame(count: 64)
    backend.injectReceivedFrame(frame)

    #expect(
      try machine.physicalMemory.read(at: 0x4000, byteCount: 12) == [UInt8](repeating: 0, count: 10) + [1, 0]
    )
    #expect(try machine.physicalMemory.read(at: 0x400C, byteCount: frame.count) == frame)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 76)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x76))
    #expect(read16(try network.readConfiguration(offset: 2, byteCount: 2)) == 0x1041)

    let generation = try machine.physicalMemory.read(at: bar + 0x15, byteCount: 1)[0]
    #expect(network.setLinkUp(false))
    #expect(try machine.physicalMemory.read(at: bar + 0x306, byteCount: 2) == [0, 0])
    #expect(try machine.physicalMemory.read(at: bar + 0x15, byteCount: 1)[0] == generation &+ 1)
    #expect(try machine.physicalMemory.read(at: bar + 0x200, byteCount: 1)[0] & 2 == 2)
  }

  @Test func resetDropsPendingHostIngressBeforeRenegotiation() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network = try DoryPCVirtioNetworkPCIDevice(
      address: .init(bus: 0, device: 5, function: 0),
      initialBARAddress: 0xD000_3000,
      backend: backend,
      macAddress: [0x02, 0xD0, 0x52, 0, 0, 2]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [network]
    )
    try network.writeConfiguration(offset: 4, bytes: [2, 0])
    try network.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try network.writeConfiguration(offset: 0x5C, bytes: [0x76, 0])
    try network.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar: UInt64 = 0xD000_3000
    // Negotiate VERSION_1 and bring the device to DRIVER_OK with queue 0 enabled but no
    // available receive descriptors, so an injected host frame stays pending.
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    let staleFrame = ethernetFrame(count: 64)
    backend.injectReceivedFrame(staleFrame)
    #expect(network.networkDevice.pendingReceiveCount == 1)

    // Trigger the real PCI virtio reset path: writing status 0 resets the device and queues,
    // and the transport onReset callback must drop the pending host ingress.
    try write8(machine, bar + 0x14, 0x00)
    #expect(network.networkDevice.pendingReceiveCount == 0)

    // Re-negotiate and re-enable queue 0, then post a receive descriptor and kick. The stale
    // frame must not be delivered: the used ring stays empty and the descriptor buffer untouched.
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(2048))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0])
    try write16(machine, bar + 0x100, 0)

    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)
    #expect(
      try machine.physicalMemory.read(at: 0x4000, byteCount: 12 + staleFrame.count)
        == [UInt8](repeating: 0, count: 12 + staleFrame.count)
    )
    // A freshly injected frame is still delivered normally after reset, proving receive
    // behavior is intact and only the stale pre-reset ingress was dropped.
    let freshFrame = ethernetFrame(count: 60)
    backend.injectReceivedFrame(freshFrame)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(try machine.physicalMemory.read(at: 0x400C, byteCount: freshFrame.count) == freshFrame)
  }

  @Test func retirementJoinsTransmitUsedRingCompletionBeforeReturning() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network = try DoryPCVirtioNetworkPCIDevice(
      address: .init(bus: 0, device: 4, function: 0), initialBARAddress: 0xD000_2000,
      backend: backend, macAddress: [0x02, 1, 2, 3, 4, 5]
    )
    let memory = NetworkCompletionBlockingMemory()
    network.connectGuestMemory(memory)
    let transport = network.transport
    try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
    try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1)))
    try transport.writeBAR(offset: 0x14, bytes: [0x0F])
    try transport.writeBAR(offset: 0x16, bytes: littleEndian(UInt16(1)))
    try transport.writeBAR(offset: 0x18, bytes: littleEndian(UInt16(8)))
    try transport.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
    try transport.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
    try transport.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
    try transport.writeBAR(offset: 0x1C, bytes: littleEndian(UInt16(1)))
    let frame = ethernetFrame(count: 64)
    try memory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(12 + frame.count))
        + littleEndian(UInt16(0)) + littleEndian(UInt16(0))
    )
    try memory.write(at: 0x4000, bytes: [UInt8](repeating: 0, count: 12) + frame)
    try memory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])
    let transmitted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { transport.processQueue(1); transmitted.signal() }
    defer { memory.release.signal() }
    #expect(memory.entered.wait(timeout: .now() + 1) == .success)
    #expect(backend.transmittedFrames == [frame])
    let retired = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { network.networkDevice.stop(); retired.signal() }
    #expect(retired.wait(timeout: .now() + 0.02) == .timedOut)
    memory.release.signal()
    #expect(transmitted.wait(timeout: .now() + 1) == .success)
    #expect(retired.wait(timeout: .now() + 1) == .success)
    #expect(read16(try memory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try transport.readBAR(offset: 0x306, byteCount: 2) == [0, 0])
  }

  private func ethernetFrame(count: Int) -> [UInt8] {
    [
      0x02, 0xD0, 0x52, 0, 0, 1,
      0x02, 0xD0, 0x52, 0, 0, 2,
      0x08, 0x00,
    ] + [UInt8](repeating: 0xCC, count: count - 14)
  }

  private func write8(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt8
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: [value])
  }

  private func write16(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt16
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write32(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt32
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write64(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt64
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }
}

private final class NetworkCompletionBlockingMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = [UInt8](repeating: 0, count: 0x10_000)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validate(at: address, byteCount: byteCount, deviceWillWrite: false)
    return lock.withLock { Array(bytes[Int(address)..<(Int(address) + byteCount)]) }
  }
  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    guard byteCount >= 0, address <= UInt64(bytes.count),
      UInt64(byteCount) <= UInt64(bytes.count) - address else {
      throw DoryVirtioNetworkError.invalidFrameLength(byteCount)
    }
  }
  func write(at address: UInt64, bytes value: [UInt8]) throws {
    try validate(at: address, byteCount: value.count, deviceWillWrite: true)
    if address == 0x3004 {
      entered.signal()
      guard release.wait(timeout: .now() + 2) == .success else {
        throw DoryVirtioNetworkError.malformedHeader
      }
    }
    lock.withLock { bytes.replaceSubrange(Int(address)..<(Int(address) + value.count), with: value) }
  }
  func synchronize() {}
}

private func read16(_ bytes: [UInt8]) -> UInt16 {
  UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func read32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
