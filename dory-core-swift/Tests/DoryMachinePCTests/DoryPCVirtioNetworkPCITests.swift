@testable import DoryMachinePC
import DoryDBTX86
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
    try machine.load(kernel: receiveTestKernel(), commandLine: "x")
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
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))

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
    try machine.load(kernel: receiveTestKernel(), commandLine: "x")
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
    // Drain the stale host wake after reset; it must not publish an old frame.
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)
    // A freshly injected frame is still delivered normally after reset, proving receive
    // behavior is intact and only the stale pre-reset ingress was dropped.
    let freshFrame = ethernetFrame(count: 60)
    backend.injectReceivedFrame(freshFrame)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(try machine.physicalMemory.read(at: 0x400C, byteCount: freshFrame.count) == freshFrame)
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT, .optimizingJIT], [false, true])
  func hostReceiveOnTrackedRingIsDeferredToSoleWorker(
    tier: DoryPCExecutionTier, arrivalDuringExecution: Bool
  ) throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network = try DoryPCVirtioNetworkPCIDevice(
      address: .init(bus: 0, device: 4, function: 0), initialBARAddress: 0xD000_2000,
      backend: backend, macAddress: [2, 0xD0, 0x52, 0, 0, 1])
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [network], executionTier: tier, optimizingJITWarmupDispatches: 0)
    try machine.load(kernel: receiveTestKernel(), commandLine: "x")
    try network.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(0)))
    try network.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1 << 29)))
    try network.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
    try network.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1)))
    try network.writeBAR(offset: 0x14, bytes: [15])
    try network.writeBAR(offset: 0x16, bytes: [0, 0])
    try network.writeBAR(offset: 0x18, bytes: [8, 0])
    try network.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
    try network.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
    try network.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
    try network.writeBAR(offset: 0x1C, bytes: [1, 0])
    try machine.physicalMemory.write(at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(2048)) + [2, 0, 0, 0])
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])
    // Linux can recycle a former page-table page for a ring. Keep production DMA admission:
    // EVENT_IDX's two-byte avail_event and used completion must be published by the sole worker.
    machine.physicalMemory.trackPageTablePage(containing: 0x3000)
    machine.physicalMemory.trackPageTablePage(containing: 0x4000)
    let frame = ethernetFrame(count: 64)
    let hostReturned = DispatchSemaphore(value: 0)
    if arrivalDuringExecution {
      let firstExecution = NetworkReceiveTrigger()
      machine.observeWorkers { event in
        guard case .executing = event,
          firstExecution.claim() else { return }
        Thread.detachNewThread {
          backend.injectReceivedFrame(frame)
          hostReturned.signal()
        }
        // Host ingress must return while this worker is still inside the observed execution
        // boundary. Its new pending-work edge then interrupts the interpreter/native batch.
        #expect(hostReturned.wait(timeout: .now() + 2) == .success)
      }
    } else {
      Thread.detachNewThread {
        backend.injectReceivedFrame(frame)
        hostReturned.signal()
      }
      try #require(hostReturned.wait(timeout: .now() + 2) == .success)
    }
    #expect(network.transport.lastQueueFailure == nil)
    #expect(network.networkDevice.pendingReceiveCount == (arrivalDuringExecution ? 0 : 1))
    #expect(try machine.physicalMemory.read(at: 0x3002, byteCount: 2) == [0, 0])
    #expect(try machine.physicalMemory.read(at: 0x4000, byteCount: 76) == [UInt8](repeating: 0, count: 76))

    let budget: UInt64 = arrivalDuringExecution ? 8193 : 1
    #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))

    #expect(try machine.physicalMemory.read(at: 0x3002, byteCount: 2) == [1, 0])
    #expect(try machine.physicalMemory.read(at: 0x3044, byteCount: 2) == [1, 0])
    #expect(try machine.physicalMemory.read(at: 0x400C, byteCount: frame.count) == frame)
    #expect(network.networkDevice.pendingReceiveCount == 0)
    #expect(network.transport.lastQueueFailure == nil)
    #expect(!network.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    let invalidation = machine.translationInvalidationDiagnostics
    #expect(invalidation.requiredGenerations[0] > 0)
    #expect(invalidation.requiredGenerations == invalidation.acknowledgedGenerations)

    // A frame queued just before stop must not acquire DMA authority at a later worker boundary.
    backend.injectReceivedFrame(frame)
    network.networkDevice.stop()
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(try machine.physicalMemory.read(at: 0x3002, byteCount: 2) == [1, 0])
    #expect(network.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
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

  private func receiveTestKernel() -> Data {
    let code: [UInt8] = [0xEB, 0xFE]
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + code.count)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt16(64), to: &data, at: 52)
    write(UInt32(5), to: &data, at: 0x44)
    write(UInt64(0x10_0000), to: &data, at: 0x50)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeHeader(
      to: &data,
      at: 0x40,
      type: 1,
      fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000,
      size: UInt64(code.count)
    )
    writeHeader(
      to: &data,
      at: 0x78,
      type: 4,
      fileOffset: 0x180,
      physicalAddress: 0,
      size: 20
    )
    write(UInt32(4), to: &data, at: 0x180)
    write(UInt32(4), to: &data, at: 0x184)
    write(UInt32(0x12), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(UInt32(0x10_0000), to: &data, at: 0x190)
    data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
    return data
  }

  private func writeHeader(
    to data: inout Data,
    at offset: Int,
    type: UInt32,
    fileOffset: UInt64,
    physicalAddress: UInt64,
    size: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 24)
    write(size, to: &data, at: offset + 32)
    write(size, to: &data, at: offset + 40)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
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

private final class NetworkReceiveTrigger: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false

  func claim() -> Bool {
    lock.withLock {
      guard !fired else { return false }
      fired = true
      return true
    }
  }
}
